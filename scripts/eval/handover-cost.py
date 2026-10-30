#!/usr/bin/env python3
"""scripts/eval/handover-cost.py - re-derive the HIMMEL-6491 per-handover price from session JSONLs (HIMMEL-6501).

Read-only, deterministic, no model call. Reads every *.jsonl directly under --dir (default:
~/.claude/projects/-home-overlord-Documents-github-himmel). Only token counts and tool names
are read.

  handover-cost.py [--dir D] [--name-re RE] [--since ISO8601] [--workers-after ISO8601]

Chiefs are the sessions whose `agent-name` matches --name-re (default -roadmap-(console|chief)$),
ordered by first record; each consecutive pair is one handover P -> S. A turn is a de-duplicated
assistant message id. Price table (input-equivalent tokens, mirrors scripts/lanes/lib/burn-weights.sh,
same WORKER_SESSION_BURN_W_* overrides): input 1, cache_read 0.1, cache_creation 1.25, output 5.

Pieces per handover (turns/cost):
  prep   P's turns from its last `chief.sh next` call up to S's first turn
  relay  P's turns from S's first turn on (relay + wrap)
  az     S's turns up to P's last turn (successor ACTION ZERO + wait)
  worker    per non-chief session that received a SUCCESSION message naming P at or after P's last
         `chief.sh next` (no upper bound: a relay drained after P wrapped is the normal case),
         as a user message, a queued_command attachment or a himmel-bus record (a hook_additional_context
         attachment), never a compaction summary or a tool result: the turns after the delivery up to and
         including the one that says `SUCCESSION accepted`, at most 4. --workers-after drops workers whose first record is
         earlier than the cutoff (count only workers launched after the fast path merged).

gross = every turn in the four pieces (the HIMMEL-6491 method, an upper bound: overlap turns include work
that would have happened anyway). net = only the turns that touch the handover machinery (their tool
input or text names chief.sh, action-zero, chief-wait (or console-wait), live-state, HANDOFF, SUCCESSION, RELAYED,
ListAgents or succession.md).
Mechanical columns (not priced): p_after_s = P's turns from S's first turn on; s_to_marker = S's
turns up to and including its first `append-results.sh` call ("-" when S made none).

ponytail: net is a name-match on handover scripts, upgrade path = hand-label a sample and compare.

Output: one `HANDOVER P->S prep=t/cost relay=t/cost az=t/cost worker=t/cost workers=n p_after_s=a
s_to_marker=m gross=G net=N` row per pair, then `MEAN n=<pairs> ...` (integer means; workers is the
mean workers per handover to one decimal; s_to_marker over the pairs that have one) and a `workers_skipped_before_cutoff=<n>` line.

Exit: 0 ok, 2 usage error (argparse, including an invalid --name-re), unreadable dir, fewer than two chiefs
or no measurable handover (the message says which).
"""

import argparse
import glob
import json
import os
import re
import sys
from datetime import datetime, timezone

W_IN = float(os.environ.get("WORKER_SESSION_BURN_W_INPUT", "1"))
W_CR = float(os.environ.get("WORKER_SESSION_BURN_W_CACHE_READ", "0.1"))
W_CC = float(os.environ.get("WORKER_SESSION_BURN_W_CACHE_CREATE", "1.25"))
W_OUT = float(os.environ.get("WORKER_SESSION_BURN_W_OUTPUT", "5"))
DEFAULT_DIR = "~/.claude/projects/-home-overlord-Documents-github-himmel"
WORKER_SESSION_TURN_CAP = 4
NEXT_RE = re.compile(r'(?:console|chief)\.sh(?:\\"|")?\s+next\b')
MARKER_RE = re.compile(r"\bbash\s+\S*append-results\.sh")
MECH_RE = re.compile(
    r"(?:console|chief)\.sh|action-zero|(?:console|chief)-wait|live-state|HANDOFF|SUCCESSION|RELAYED|ListAgents|succession\.md"
)
PIECES = ("prep", "relay", "az", "worker")


def parse_ts(s):
    d = datetime.fromisoformat(s.replace("Z", "+00:00"))
    return d if d.tzinfo else d.replace(tzinfo=timezone.utc)


def iso_arg(s):
    try:
        return parse_ts(s)
    except ValueError:
        raise argparse.ArgumentTypeError("not an ISO 8601 timestamp: %r" % s)


def regex_arg(s):
    try:
        re.compile(s)
    except re.error as e:
        raise argparse.ArgumentTypeError("not a valid regular expression: %r (%s)" % (s, e))
    return s


def turn_text(msg):
    """Tool names, tool inputs and text of one assistant message, as one string."""
    out = []
    for b in msg.get("content") or []:
        if not isinstance(b, dict):
            continue
        if b.get("type") == "text":
            out.append(str(b.get("text", "")))
        elif b.get("type") == "tool_use":
            out.append(str(b.get("name", "")))
            out.append(json.dumps(b.get("input", {})))
    return "\n".join(out)


def load(path):
    """-> dict(name, first, turns=[(ts, cost, mech, nxt, accepted, marker)], deliveries=[ts])"""
    name = first = None
    turns = {}
    deliveries = []
    for line in open(path, encoding="utf-8", errors="replace"):
        try:
            d = json.loads(line)
            ts = parse_ts(d["timestamp"]) if d.get("timestamp") else None
        except (ValueError, TypeError, AttributeError):
            continue
        if not isinstance(d, dict):
            continue
        if ts and not first:
            first = ts
        t = d.get("type")
        if t == "agent-name":
            name = d.get("agentName") or name
        elif ts and (t == "user" or (t == "attachment" and (d.get("attachment") or {}).get("type")
                                                  in ("queued_command", "hook_additional_context"))):
            att = d.get("attachment") or {}
            content = (d.get("message") or {}).get("content") if t == "user" else None
            # a compaction summary or a tool result can quote a relay; neither delivers one
            if d.get("isCompactSummary") or (isinstance(content, list) and any(
                    isinstance(b, dict) and b.get("type") == "tool_result" for b in content)):
                continue
            body = json.dumps(d.get("message", "") if t == "user" else (att.get("prompt") or att.get("content", "")))
            if "SUCCESSION" in body:
                deliveries.append((ts, body))
        elif t == "assistant" and ts and not d.get("isSidechain"):
            msg = d.get("message") or {}
            u = msg.get("usage")
            if not u or not msg.get("id"):
                continue
            text = turn_text(msg)
            cost = (u.get("input_tokens", 0) * W_IN + u.get("cache_read_input_tokens", 0) * W_CR
                    + u.get("cache_creation_input_tokens", 0) * W_CC + u.get("output_tokens", 0) * W_OUT)
            # one message id spans several records (one per content block): keep the first ts, the
            # last usage, and every flag any block raised
            called = any(isinstance(b, dict) and b.get("type") == "tool_use"
                         and MARKER_RE.search(json.dumps(b.get("input", {}))) for b in msg.get("content") or [])
            prev = turns.get(msg["id"], (ts, 0, False, False, False, False))
            turns[msg["id"]] = (prev[0], cost, prev[2] or bool(MECH_RE.search(text)),
                                prev[3] or bool(NEXT_RE.search(text)),
                                prev[4] or "SUCCESSION accepted" in text,
                                prev[5] or called)
    return {"name": name, "first": first, "turns": sorted(turns.values(), key=lambda x: x[0]),
            "deliveries": sorted(deliveries, key=lambda x: x[0])}


def piece(turns):
    return (len(turns), sum(t[1] for t in turns), sum(t[1] for t in turns if t[2]))


def handover(p, s, workers, workers_after):
    p_next = [t[0] for t in p["turns"] if t[3]]
    p_last = p["turns"][-1][0] if p["turns"] else None
    if not p_next or not p_last or not s["turns"]:
        return None
    nxt, s_first = p_next[-1], s["turns"][0][0]
    out = {
        "prep": piece([t for t in p["turns"] if nxt <= t[0] < s_first]),
        "relay": piece([t for t in p["turns"] if t[0] >= s_first]),
        "az": piece([t for t in s["turns"] if t[0] <= p_last]),
    }
    worker_turns, nworkers, skipped = [], 0, 0
    for lg in workers:
        got = [x[0] for x in lg["deliveries"] if nxt <= x[0] and p["name"] in x[1]]
        if not got:
            continue
        if workers_after and (not lg["first"] or lg["first"] < workers_after):
            skipped += 1
            continue
        after = [t for t in lg["turns"] if t[0] > got[0]]
        taken = []
        for t in after[:WORKER_SESSION_TURN_CAP]:
            taken.append(t)
            if t[4]:
                break
        worker_turns.extend(taken)
        nworkers += 1
    marked = [i for i, t in enumerate(s["turns"]) if t[5]]
    out["p_after_s"] = out["relay"][0]
    out["s_to_marker"] = marked[0] + 1 if marked else None
    out["worker"] = piece(worker_turns)
    out["workers"] = nworkers
    out["skipped"] = skipped
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--dir", default=DEFAULT_DIR)
    ap.add_argument("--name-re", type=regex_arg, default=r"-roadmap-(console|chief)$")
    ap.add_argument("--since", type=iso_arg)
    ap.add_argument("--workers-after", type=iso_arg)
    a = ap.parse_args(argv)

    d = os.path.expanduser(a.dir)
    if not os.path.isdir(d):
        print("handover-cost: cannot read %s: not a directory" % d, file=sys.stderr)
        return 2
    name_re = re.compile(a.name_re)
    chiefs, workers = [], []
    for path in sorted(glob.glob(os.path.join(d, "*.jsonl"))):
        s = load(path)
        if not s["name"] or not s["first"]:
            continue
        (chiefs if name_re.search(s["name"]) else workers).append(s)
    chiefs = sorted([c for c in chiefs if not a.since or c["first"] >= a.since], key=lambda c: c["first"])
    if len(chiefs) < 2:
        print("handover-cost: fewer than two chiefs matching %r in %s" % (a.name_re, d), file=sys.stderr)
        return 2

    rows = []
    for p, s in zip(chiefs, chiefs[1:]):
        h = handover(p, s, workers, a.workers_after)
        if not h:
            continue
        gross = sum(h[k][1] for k in PIECES)
        net = sum(h[k][2] for k in PIECES)
        rows.append((h, gross, net))
        print("HANDOVER %s->%s %s workers=%d p_after_s=%d s_to_marker=%s gross=%d net=%d" % (
            p["name"], s["name"],
            " ".join("%s=%d/%d" % (k, h[k][0], round(h[k][1])) for k in PIECES), h["workers"], h["p_after_s"],
            "-" if h["s_to_marker"] is None else h["s_to_marker"], round(gross), round(net)))
    n = len(rows)
    if not n:
        print("handover-cost: no measurable handover among %d chiefs in %s "
              "(each pair needs a chief.sh next call and assistant turns)" % (len(chiefs), d), file=sys.stderr)
        return 2
    if n:
        mean = lambda xs: round(sum(xs) / n)
        marked = [r[0]["s_to_marker"] for r in rows if r[0]["s_to_marker"] is not None]
        print("MEAN n=%d %s workers=%.1f p_after_s=%d s_to_marker=%s gross=%d net=%d" % (
            n, " ".join("%s=%d/%d" % (k, mean([r[0][k][0] for r in rows]), mean([r[0][k][1] for r in rows]))
                        for k in PIECES),
            sum(r[0]["workers"] for r in rows) / n, mean([r[0]["p_after_s"] for r in rows]), round(sum(marked) / len(marked)) if marked else "-",
            mean([r[1] for r in rows]), mean([r[2] for r in rows])))
    print("workers_skipped_before_cutoff=%d" % sum(r[0]["skipped"] for r in rows))
    return 0


if __name__ == "__main__":
    sys.exit(main())
