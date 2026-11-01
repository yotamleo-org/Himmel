#!/usr/bin/env python3
"""scripts/eval/chief-wake-classes.py - chief wake classes for one date's chiefs (HIMMEL-6541, HIMMEL-2975 plan Appendix A).

Read-only, deterministic, no model call. Only token counts, tool names and tool inputs are read.

  chief-wake-classes.py --date YYYY-MM-DD [--exclude A,AB] [--dir D]

Chiefs are the transcripts titled HIMMEL-nextleg-<date><LETTERS>-roadmap-(console|chief); --exclude drops live
ones by letter. A wake is a user record that is not all tool_result; its episode is every request until the next
wake. Cost (eq) per request, de-duplicated by message id, is the handover-cost.py price (no second table).
A wake is `escalate` when any of its tools carries a judgement marker (an Agent dispatch; go.sh, verdict-go.sh,
write-verdict.sh, headed-arm-leg.sh; a Jira create/comment/transition/edit/link; a SendMessage with a RETASK
token or a ruling word; a Write/Edit to a brief, worker, RESUME, evidence or verdict path), else `relay-only`.
Operator-facing wakes (operator text, session-load, local commands, WAKE telegram) are not machine wakes.

ponytail: the judgement regex is broad, so relay-only is a lower bound; upgrade path = hand-label a sample.

Output: `consoles=<n> <letters>`, then one `CLASS <name> wakes= pct_wakes= reqs= eq= pct_eq=` row per class
(operator, machine-relay-only, machine-escalate, esc-judgement-or-think, esc-mechanical, ALL), then one
`KIND <kind> wakes= reqs= eq= escalate= relay_eq= mech_eq=` row per wake kind, largest eq first. eq is the raw
input-equivalent token count (divide by 1e6 for the plan's tables).

Exit: 0 ok, 2 usage error, unreadable dir or no matching console.
"""

import argparse
import collections
import glob
import importlib.util
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_DIR = "~/.claude/projects/-home-overlord-Documents-github-himmel"


def sibling(file, name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, file))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


cli = sibling("chief-load-inventory.py", "chief_load_inventory")
hc = sibling("handover-cost.py", "handover_cost")

JUDGE_BASH = re.compile(r"\bgo\.sh\b|verdict-go\.sh|write-verdict\.sh|headed-arm-leg\.sh|"
                        r"jira/dist/index\.js\s+(create|comment|transition|edit|link)")
RULING = re.compile(r"\b(GO|HOLD|NO-GO|ruling|concur|approved|defer|narrow|halt)\b", re.I)
TOKEN = re.compile(r"\b[A-Z]{1,3}-N\d+-[0-9a-f]{6,}")
JUDGE_PATH = re.compile(r"brief|RESUME|evidence|verdict|-worker|/N\d+", re.I)
SCRIPT = re.compile(r"(console-wait\.sh|chief-wait\.sh|worker-event\.sh|close-wrapped-leg\.sh|wrap-merged\.sh|"
                    r"ready-check\.sh|check-ci\.sh|verdict-go\.sh|board\.mjs|action-zero\.sh|headed-arm-leg\.sh|"
                    r"gen-briefs\.py|merge-on-green\.sh|relay-batch\.sh|tick\.sh|ops-run\.sh|run-suite\.sh|"
                    r"console\.sh|chief\.sh)")
OPERATOR_KINDS = ("operator", "session-load", "local-command", "session-start",
                  "operator-directed-session", "waiter:telegram")


def price(u):
    return (u.get("input_tokens", 0) * hc.W_IN + u.get("cache_read_input_tokens", 0) * hc.W_CR
            + u.get("cache_creation_input_tokens", 0) * hc.W_CC + u.get("output_tokens", 0) * hc.W_OUT)


def wake_kind(txt):
    tr = cli.classify_trigger(txt)
    if tr != "task-notification":
        return tr
    m = re.search(r"<summary>(.*?)</summary>", txt, re.S)
    s = SCRIPT.search(m.group(1) if m else txt)
    name = s.group(1) if s else "bg-other"
    if name in ("console-wait.sh", "chief-wait.sh"):
        of = re.search(r"<output-file>(.*?)</output-file>", txt)
        kind = "unknown"
        try:
            with open(of.group(1), encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    if line.startswith("WAKE "):
                        kind = line.split()[1]
                        break
        except (AttributeError, OSError, IndexError):
            pass
        return "waiter:" + kind
    return "bg:" + name


def judgement(tools):
    for name, inp in tools:
        if name == "Agent":
            return True
        if name == "Bash" and JUDGE_BASH.search(inp.get("command", "")):
            return True
        if name == "SendMessage":
            msg = inp.get("message", "")
            if TOKEN.search(msg) or RULING.search(msg):
                return True
        if name in ("Write", "Edit") and JUDGE_PATH.search(inp.get("file_path", "")):
            return True
    return False


def episodes(path):
    eps, cur, seen = [], None, set()
    for line in open(path, encoding="utf-8", errors="replace"):
        try:
            d = json.loads(line)
        except ValueError:
            continue
        if d.get("type") == "user":
            txt = cli.user_text(d["message"])
            if txt is None:
                continue
            cur = {"kind": wake_kind(txt), "eq": 0.0, "req": 0, "tools": [], "reqs": []}
            eps.append(cur)
        elif d.get("type") == "assistant" and cur is not None:
            msg = d["message"]
            mid = msg.get("id") or d.get("uuid")
            tools = [(x["name"], x.get("input", {})) for x in msg.get("content", []) if x.get("type") == "tool_use"]
            cur["tools"] += tools
            if mid not in seen:
                seen.add(mid)
                p = price(msg.get("usage", {}))
                cur["eq"] += p
                cur["req"] += 1
                cur["reqs"].append([p, tools])
            elif cur["reqs"]:
                cur["reqs"][-1][1] = cur["reqs"][-1][1] + tools
    return eps


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--dir", default=DEFAULT_DIR)
    ap.add_argument("--date", required=True)
    ap.add_argument("--exclude", default="")
    a = ap.parse_args(argv)

    d = os.path.expanduser(a.dir)
    if not os.path.isdir(d):
        print("chief-wake-classes: cannot read %s: not a directory" % d, file=sys.stderr)
        return 2
    exclude = set(x for x in a.exclude.split(",") if x)
    title_re = re.compile(r"HIMMEL-nextleg-%s([A-Z]+)-roadmap-(?:console|chief)" % re.escape(a.date))
    rows = []
    for path in sorted(glob.glob(os.path.join(d, "*.jsonl"))):
        title = cli.title_of(path)
        m = title and title_re.fullmatch(title)
        if not m or m.group(1) in exclude:
            continue
        rows.append((m.group(1), episodes(path)))
    if not rows:
        print("chief-wake-classes: no consoles for %s in %s" % (a.date, d), file=sys.stderr)
        return 2

    tot = collections.defaultdict(lambda: [0, 0, 0.0])            # class -> wakes, reqs, eq
    kinds = collections.defaultdict(lambda: [0, 0, 0.0, 0, 0.0])  # kind -> wakes, reqs, eq, escalate, relay eq
    mech = collections.Counter()
    for _, eps in rows:
        for e in eps:
            machine = e["kind"] not in OPERATOR_KINDS
            esc = judgement(e["tools"])
            cls = "operator" if not machine else ("machine-escalate" if esc else "machine-relay-only")
            for k in (cls, "ALL"):
                t = tot[k]
                t[0] += 1
                t[1] += e["req"]
                t[2] += e["eq"]
            kk = kinds[e["kind"]]
            kk[0] += 1
            kk[1] += e["req"]
            kk[2] += e["eq"]
            kk[3] += esc
            kk[4] += 0 if esc else e["eq"]
            if cls == "machine-escalate":
                for p, tl in e["reqs"]:
                    sub = "esc-judgement-or-think" if (not tl or judgement(tl)) else "esc-mechanical"
                    t = tot[sub]
                    t[1] += 1
                    t[2] += p
                    if sub == "esc-mechanical":
                        mech[e["kind"]] += p
    A = tot["ALL"]
    print("consoles=%d %s" % (len(rows), ",".join(sorted((n for n, _ in rows), key=lambda s: (len(s), s)))))
    for k in ("operator", "machine-relay-only", "machine-escalate", "esc-judgement-or-think", "esc-mechanical", "ALL"):
        t = tot[k]
        print("CLASS %s wakes=%d pct_wakes=%.1f reqs=%d eq=%d pct_eq=%.1f" % (
            k, t[0], 100 * t[0] / A[0] if A[0] else 0.0, t[1], round(t[2]), 100 * t[2] / A[2] if A[2] else 0.0))
    for k, v in sorted(kinds.items(), key=lambda kv: (-kv[1][2], kv[0])):
        print("KIND %s wakes=%d reqs=%d eq=%d escalate=%d relay_eq=%d mech_eq=%d" % (
            k, v[0], v[1], round(v[2]), v[3], round(v[4]), round(mech[k])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
