#!/usr/bin/env python3
"""scripts/eval/fold-vs-keep/fvk.py - the fold-vs-keep eval's parser and scorer (HIMMEL-7330).

One recurring subagent class at a time, a KEEP arm (what runs today) is compared with a
FOLD arm (a cheaper tier, inline in the parent, or a script) on frozen golden tasks, each
run several times; the decision reads the tasks that flip, not the mean.

  fvk.py brief      <transcript.jsonl>                  the first user prompt (a task's brief)
  fvk.py summarize  <stream.jsonl|transcript.jsonl> [--class C] [--outcome O]
                                                        one JSON run summary on stdout; --outcome
                                                        records a historic run's verdict as given
  fvk.py publisher  --tasks FILE [--projects DIR]       the publisher class's run rows (observational)
  fvk.py score      --tasks DIR --key FILE --runs DIR [--publisher-rows FILE]
                    [--inline-cost-eq N] [--json OUT]   the report tables

cost_eq = input + 1.25 x cache-write + 0.1 x cache-read + 5 x output (the leg-burn weights),
usage rows deduped by message id. A run's outcome:
  judge      the first GO / NO-GO of the reply; correct when it equals the key's truth
  vm         the first PROOF: PASS|FAIL line; correct when it equals the key's truth
  publisher  the page went live by the end of the attempt (a publish tool result that
             is not a refusal); correct when it did
A run that touched a leak path (LEAK_PATTERNS in a tool input, less its class's NOT_A_LEAK) or ended in an error is
unscored. Per task and arm, pass = correct runs / scored runs. A task flips WORSE when the
fold arm's pass is below the keep arm's, BETTER when above. Decision per class:
  fold         >= MIN_TASKS tasks scored in both arms and no task flips worse
  keep         some task flips worse
  inconclusive fewer scored tasks than MIN_TASKS
Exit: 0 done; 2 refused input. Stdlib only; no network, no model call.
"""
import argparse
import glob
import json
import os
import re
import sys
from datetime import datetime

W_IN, W_CC, W_CR, W_OUT = 1.0, 1.25, 0.1, 5.0
MIN_TASKS = 10
LEAK_PATTERNS = [
    r"verdicts/",
    r"\bgh\s",
    r"adjudication",
    r"judge-accuracy",
    r"/Documents/github/himmel",
    r"/Documents/luna",
    r"\.claude/projects",
    r"\.himmel/state",
]
# A vm task's own repo is the primary checkout: the child bundles the PR head from it.
NOT_A_LEAK = {"vm": {r"/Documents/github/himmel"}}
VERDICT_RE = re.compile(r"\b(NO-GO|GO)\b")
PROOF_RE = re.compile(r"^\W*PROOF:\s*(PASS|FAIL)\b", re.M)
REFUSAL_RE = re.compile(r"refused|denied|deleted", re.I)
REFUSED_RE = re.compile(r"^(PreToolUse:\S+ hook error|Permission to use \S+|Claude requested permissions|<tool_use_error>)")


def die(msg):
    print("fvk: " + msg, file=sys.stderr)
    sys.exit(2)


def _ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


def _text(content):
    if isinstance(content, str):
        return content
    return " ".join(b.get("text", "") for b in content or [] if isinstance(b, dict) and b.get("type") == "text")


def cost_eq(u):
    return (u.get("input_tokens", 0) * W_IN + u.get("cache_creation_input_tokens", 0) * W_CC
            + u.get("cache_read_input_tokens", 0) * W_CR + u.get("output_tokens", 0) * W_OUT)


def read_events(path):
    out = []
    with open(path) as fh:
        for line in fh:
            try:
                out.append(json.loads(line))
            except ValueError:
                continue
    return out


def brief_of(events):
    for d in events:
        if d.get("type") == "user":
            return _text(d["message"]["content"])
    return ""


def tool_inputs(events):
    """(name, input json) of every tool call that ran. Only a refused call (a hook or
    permission denial, an invalid input) read nothing; one that ran and exited nonzero may have."""
    refused = set()
    for d in events:
        if d.get("type") == "user" and isinstance(d["message"].get("content"), list):
            refused |= {b.get("tool_use_id") for b in d["message"]["content"]
                        if isinstance(b, dict) and b.get("type") == "tool_result" and b.get("is_error")
                        and REFUSED_RE.search(_text(b.get("content")))}
    for d in events:
        if d.get("type") == "assistant":
            for b in d["message"].get("content", []):
                if b.get("type") == "tool_use" and b.get("id") not in refused:
                    yield b.get("name", ""), json.dumps(b.get("input"))


def leaks(events):
    """LEAK_PATTERNS hits in the input of a tool call that ran."""
    hits = []
    for name, inp in tool_inputs(events):
        if name == "SubagentHandback":
            continue
        for pat in LEAK_PATTERNS:
            if re.search(pat, inp):
                hits.append("%s:%s" % (name, pat))
    return sorted(set(hits))


def outcome_of(cls, text):
    if cls == "judge":
        first = next((l for l in (text or "").splitlines() if l.strip()), "")
        m = VERDICT_RE.search(first) or VERDICT_RE.search(text or "")
        return m.group(1) if m else None
    if cls == "vm":
        m = PROOF_RE.search(text or "")
        return m.group(1) if m else None
    return None


def summarize(path, cls):
    """One run: a claude -p stream-json file (its `result` event carries usage and the reply)
    or a historic subagent transcript (usage summed over deduped messages)."""
    ev = read_events(path)
    res = [d for d in ev if d.get("type") == "result"]
    s = {"file": path, "leaks": leaks(ev), "error": False}
    if res:
        r = res[-1]
        s.update(cost_eq=round(cost_eq(r.get("usage") or {})), wall_s=round((r.get("duration_ms") or 0) / 1000),
                 turns=r.get("num_turns"), cost_usd=r.get("total_cost_usd"), reply=r.get("result") or "",
                 error=bool(r.get("is_error")) or r.get("subtype") not in (None, "success"))
    else:
        msgs, ts, reply = {}, [], ""
        for d in ev:
            if d.get("timestamp"):
                ts.append(_ts(d["timestamp"]))
            if d.get("type") == "assistant":
                if d["message"].get("usage"):
                    msgs[d["message"].get("id")] = d["message"]["usage"]
                t = _text(d["message"].get("content"))
                if t.strip():
                    reply = t
                for b in d["message"].get("content") or []:
                    if b.get("type") == "tool_use" and b.get("name") == "SubagentHandback":
                        reply = (b.get("input") or {}).get("message", reply)
        s.update(cost_eq=round(sum(cost_eq(u) for u in msgs.values())),
                 wall_s=round(max(ts) - min(ts)) if len(ts) > 1 else 0, turns=len(msgs), cost_usd=None,
                 reply=reply, error=not msgs or any(d.get("type") == "system" and d.get("subtype") == "init" for d in ev))
    s["outcome"] = outcome_of(cls, s["reply"])
    s["reply"] = s["reply"][:400]
    return s


def publish_results(events):
    """[(page, ok)] for every Artifact publish call in a transcript, in order."""
    calls, out = {}, []
    for d in events:
        if d.get("type") == "assistant":
            for b in d["message"].get("content", []):
                inp = b.get("input") or {}
                if b.get("type") == "tool_use" and b.get("name") == "Artifact" and inp.get("action") == "publish":
                    calls[b["id"]] = os.path.basename(inp.get("file_path", ""))
        if d.get("type") == "user" and isinstance(d["message"].get("content"), list):
            for b in d["message"]["content"]:
                if isinstance(b, dict) and b.get("type") == "tool_result" and b.get("tool_use_id") in calls:
                    t = b.get("content")
                    t = t if isinstance(t, str) else _text(t)
                    out.append((calls[b["tool_use_id"]], not (b.get("is_error") or REFUSAL_RE.search(t[:300]))))
    return out


def publisher_rows(tasks, projects):
    """Run rows for the publisher class. A subagent run is one child transcript (all its
    publishes, by page). An inline run is one (session, page) attempt in a console
    transcript: the publishes of that page until the first success, or to the end."""
    rows = []
    for t in tasks["tasks"]:
        page = t["page"]
        for rel in t.get("subagent", []):
            p = os.path.join(projects, rel)
            if not os.path.exists(p):
                rows.append(dict(cls="publisher", task=t["id"], arm="keep", file=p, error=True, outcome=None))
                continue
            ev = read_events(p)
            pubs = [ok for pg, ok in publish_results(ev) if pg == page]
            s = summarize(p, "publisher")
            rows.append(dict(cls="publisher", task=t["id"], arm="keep", file=p, error=False,
                             outcome="live" if any(pubs) else "not-live", attempts=len(pubs),
                             cost_eq=s["cost_eq"], wall_s=s["wall_s"], leaks=[]))
        for rel in t.get("inline", []):
            p = os.path.join(projects, rel["file"])
            if not os.path.exists(p):
                rows.append(dict(cls="publisher", task=t["id"], arm="fold", file=p, error=True, outcome=None))
                continue
            pubs = [ok for pg, ok in publish_results(read_events(p)) if pg == page]
            first = rel.get("first", 0)
            att = pubs[first:first + rel.get("attempts", len(pubs))]
            rows.append(dict(cls="publisher", task=t["id"], arm="fold", file=p, error=not att,
                             outcome="live" if any(att) else "not-live", attempts=len(att),
                             cost_eq=None, wall_s=None, leaks=[]))
    return rows


def load_runs(runs_dir, cls, key):
    rows = []
    for p in sorted(glob.glob(os.path.join(runs_dir, cls, "*", "*", "*.summary.json"))):
        s = json.load(open(p))
        task, arm = p.split(os.sep)[-3], p.split(os.sep)[-2]
        s.update(cls=cls, task=task, arm=arm)
        rows.append(s)
    return rows


def correct(row, truth):
    leaked = [l for l in row.get("leaks") or [] if l.split(":", 1)[-1] not in NOT_A_LEAK.get(row["cls"], ())]
    if row.get("error") or leaked or row.get("outcome") is None:
        return None
    if row["cls"] == "publisher":
        return row["outcome"] == "live"
    return row["outcome"] == truth


def score_class(cls, rows, key, arms, inline_cost=None):
    tasks = sorted({r["task"] for r in rows})
    per_task, flips = [], {"worse": [], "better": []}
    cost = {"keep": [], "fold": []}
    wall = {"keep": [], "fold": []}
    scored_both = 0
    for t in tasks:
        truth = key.get(cls, {}).get(t, {}).get("truth")
        cell = {}
        for arm in ("keep", "fold"):
            rs = [r for r in rows if r["task"] == t and r["arm"] == arm]
            cs = [correct(r, truth) for r in rs]
            sc = [c for c in cs if c is not None]
            cell[arm] = dict(runs=len(rs), scored=len(sc), ok=sum(sc), outcomes=[r.get("outcome") or "-" for r in rs],
                             unscored=[os.path.basename(r.get("file", "")) for r, c in zip(rs, cs) if c is None],
                             cost_eq=[r.get("cost_eq") for r in rs], wall_s=[r.get("wall_s") for r in rs])
            for r in rs:
                if r.get("cost_eq") is not None:
                    cost[arm].append(r["cost_eq"])
                elif arm == "fold" and inline_cost is not None:
                    cost[arm].append(inline_cost)
                if r.get("wall_s") is not None:
                    wall[arm].append(r["wall_s"])
        flip = ""
        k, f = cell["keep"], cell["fold"]
        if k["scored"] and f["scored"]:
            scored_both += 1
            pk, pf = k["ok"] / k["scored"], f["ok"] / f["scored"]
            flip = "worse" if pf < pk else ("better" if pf > pk else "")
            if flip:
                flips[flip].append(t)
        per_task.append(dict(task=t, truth=truth, keep=k, fold=f, flip=flip))
    mean = lambda xs: round(sum(xs) / len(xs)) if xs else None
    if scored_both < MIN_TASKS:
        decision = "inconclusive"
    elif flips["worse"]:
        decision = "keep"
    else:
        decision = "fold"
    return dict(cls=cls, arms=arms, tasks=len(tasks), scored_both=scored_both,
                runs={a: sum(p[a]["runs"] for p in per_task) for a in ("keep", "fold")},
                flips=flips, cost_eq_mean=dict(keep=mean(cost["keep"]), fold=mean(cost["fold"])),
                wall_s_mean=dict(keep=mean(wall["keep"]), fold=mean(wall["fold"])),
                decision=decision, per_task=per_task)


def render(results):
    lines = ["| class | keep arm | fold arm | tasks scored | runs keep/fold | flips worse | flips better "
             "| cost-eq/run keep | cost-eq/run fold | wall s keep | wall s fold | decision |",
             "|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for r in results:
        lines.append("| %s | %s | %s | %d/%d | %d/%d | %s | %s | %s | %s | %s | %s | %s |" % (
            r["cls"], r["arms"]["keep"], r["arms"]["fold"], r["scored_both"], r["tasks"],
            r["runs"]["keep"], r["runs"]["fold"], ", ".join(r["flips"]["worse"]) or "none",
            ", ".join(r["flips"]["better"]) or "none", r["cost_eq_mean"]["keep"], r["cost_eq_mean"]["fold"],
            r["wall_s_mean"]["keep"], r["wall_s_mean"]["fold"], r["decision"]))
    for r in results:
        lines += ["", "### %s: per task" % r["cls"], "",
                  "| task | truth | keep outcomes | keep ok | fold outcomes | fold ok | flip |", "|---|---|---|---|---|---|---|"]
        for p in r["per_task"]:
            lines.append("| %s | %s | %s | %d/%d | %s | %d/%d | %s |" % (
                p["task"], p["truth"] or "live", " ".join(p["keep"]["outcomes"]), p["keep"]["ok"], p["keep"]["scored"],
                " ".join(p["fold"]["outcomes"]), p["fold"]["ok"], p["fold"]["scored"], p["flip"] or "-"))
    return "\n".join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(prog="fvk.py")
    sub = ap.add_subparsers(dest="op", required=True)
    b = sub.add_parser("brief"); b.add_argument("file")
    s = sub.add_parser("summarize"); s.add_argument("file"); s.add_argument("--class", dest="cls", default="judge")
    s.add_argument("--outcome")
    p = sub.add_parser("publisher"); p.add_argument("--tasks", required=True)
    p.add_argument("--projects", default=os.path.expanduser("~/.claude/projects"))
    c = sub.add_parser("score"); c.add_argument("--tasks", required=True); c.add_argument("--key", required=True)
    c.add_argument("--runs", required=True); c.add_argument("--publisher-rows")
    c.add_argument("--inline-cost-eq", type=float); c.add_argument("--json")
    a = ap.parse_args(argv)
    if a.op in ("brief", "summarize"):
        a.file = os.path.expanduser(a.file)
    if a.op in ("brief", "summarize") and not os.path.isfile(a.file):
        die("not a file: %s" % a.file)
    if a.op == "brief":
        print(brief_of(read_events(a.file)))
    elif a.op == "summarize":
        s = summarize(a.file, a.cls)
        if a.outcome:
            s["outcome"] = a.outcome
        print(json.dumps(s, indent=1))
    elif a.op == "publisher":
        print(json.dumps(publisher_rows(json.load(open(a.tasks)), a.projects), indent=1))
    else:
        if not os.path.isfile(a.key) or not os.path.isdir(a.tasks):
            die("--key must be a file and --tasks a dir")
        key = json.load(open(a.key))
        results = []
        for cls in ("judge", "publisher", "vm"):
            tf = os.path.join(a.tasks, cls + ".json")
            if not os.path.isfile(tf):
                continue
            arms = json.load(open(tf))["arms"]
            if cls == "publisher":
                if not a.publisher_rows:
                    continue
                rows = json.load(open(a.publisher_rows))
            else:
                rows = load_runs(a.runs, cls, key)
            if rows:
                results.append(score_class(cls, rows, key, arms, a.inline_cost_eq if cls == "publisher" else None))
        print(render(results))
        if a.json:
            json.dump(results, open(a.json, "w"), indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
