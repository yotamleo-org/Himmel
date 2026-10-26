#!/usr/bin/env python3
"""summarize.py -- turn a graphify-ab sweep dir into runs.jsonl and a report
(HIMMEL-5317).

    summarize.py ingest DIR [--transcripts ROOT]   raw/*.json -> DIR/runs.jsonl
    summarize.py report DIR [--seed N]             runs.jsonl -> markdown on stdout

Per-run cost is in input-token equivalents of one Sonnet-class price ratio:
  input + 1.25*cache_creation + 0.1*cache_read + 5*output
(cache_read weighted x0.1 as the brief asks; output priced 5x input). Raw token
fields and the CLI's own total_cost_usd are kept next to it as a cross-check.

Tool calls are counted from the run's session transcript when it can be found
under ROOT (default ~/.claude/projects); an arm-B run whose transcript shows a
graphify call is flagged `contaminated` and excluded from the arm means.
"""
import glob
import json
import os
import random
import re
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import truth as T  # noqa: E402

# A tool call that really uses the graph: the CLI, the worker wrapper, or its output
# dir. A bare mention of 'graphify' (e.g. grepping for graphify-bin.sh) is not use.
GRAPH_USE = re.compile(r"(?:leg|worker)-graph\.sh|graphify-out|(^|[^-\w/.])graphify\s+(query|explain|path)\b")


def task_rules():
    with open(T.TASKS) as f:
        return {t["id"]: t["truth"] for t in json.load(f)["tasks"]}


def weighted(u):
    return (u.get("input_tokens", 0) + 1.25 * u.get("cache_creation_input_tokens", 0)
            + 0.1 * u.get("cache_read_input_tokens", 0) + 5 * u.get("output_tokens", 0))


def transcript_calls(root, cwd, sid):
    slug = re.sub(r"[^A-Za-z0-9]", "-", cwd)
    path = os.path.join(root, slug, sid + ".jsonl")
    if not os.path.isfile(path):
        return None, None
    calls = graphify = 0
    with open(path) as f:
        for line in f:
            try:
                msg = json.loads(line).get("message") or {}
            except ValueError:
                continue
            content = msg.get("content")
            if msg.get("role") != "assistant" or not isinstance(content, list):
                continue
            for b in content:
                if isinstance(b, dict) and b.get("type") == "tool_use":
                    calls += 1
                    inp = b.get("input")
                    cmd = inp.get("command") if isinstance(inp, dict) else None
                    if b.get("name") == "Bash" and isinstance(cmd, str) and GRAPH_USE.search(cmd):
                        graphify += 1
    return calls, graphify


def ingest(out, root):
    rules = task_rules()
    rev = T.base_sha()
    truths = {r: T.RULES[r](rev) for r in set(rules.values())}
    rows = []
    for f in sorted(glob.glob(os.path.join(out, "raw", "*.json"))):
        tag = os.path.basename(f)[:-5]
        task, arm, rep = tag.rsplit(".", 2)
        row = {"tag": tag, "task": task, "arm": arm, "rep": int(rep[1:]), "ok": False}
        try:
            with open(f) as fh:
                d = json.load(fh)
        except (ValueError, OSError):
            row["error"] = "unparseable-json"
            rows.append(row)
            continue
        u = d.get("usage") or {}
        meta = open(f[:-5] + ".meta").read().split() if os.path.isfile(f[:-5] + ".meta") else ["?", "0"]
        sc = T.score(truths[rules[task]], d.get("result") or "")
        calls, gcalls = transcript_calls(root, os.path.join(out, "checkout"), d.get("session_id", ""))
        row.update({
            "ok": not d.get("is_error", False) and meta[0] == "0", "rc": meta[0], "wall_s": float(meta[1]),
            "input_tokens": u.get("input_tokens", 0), "output_tokens": u.get("output_tokens", 0),
            "cache_creation": u.get("cache_creation_input_tokens", 0),
            "cache_read": u.get("cache_read_input_tokens", 0),
            "weighted_tokens": weighted(u), "cost_usd": d.get("total_cost_usd"),
            "num_turns": d.get("num_turns"), "tool_calls": calls, "graphify_calls": gcalls,
            "contaminated": bool(arm == "B" and gcalls), "unused_graph": bool(arm == "A" and gcalls == 0),
            **{k: sc[k] for k in ("correct", "parsed", "precision", "recall")},
        })
        rows.append(row)
    with open(os.path.join(out, "runs.jsonl"), "w") as fh:
        for r in rows:
            fh.write(json.dumps(r) + "\n")
    return rows


def mean(xs):
    return statistics.fmean(xs) if xs else float("nan")


def spread(xs):
    return (min(xs), max(xs)) if xs else (float("nan"), float("nan"))


def boot_delta(by_task, key, rng, n=5000):
    """Bootstrap 95% CI of mean(A) - mean(B), resampling reps within each task
    and weighting tasks equally. by_task: {task: {"A": [...], "B": [...]}}."""
    tasks = [t for t, v in by_task.items() if v["A"] and v["B"]]
    if not tasks:
        return None
    pt = mean([mean(by_task[t]["A"]) - mean(by_task[t]["B"]) for t in tasks])
    ds = []
    for _ in range(n):
        per = []
        for t in tasks:
            a, b = by_task[t]["A"], by_task[t]["B"]
            per.append(mean([rng.choice(a) for _ in a]) - mean([rng.choice(b) for _ in b]))
        ds.append(mean(per))
    ds.sort()
    return pt, ds[int(0.025 * n)], ds[int(0.975 * n) - 1]


def fmt(x):
    return "%.0f" % x if abs(x) >= 100 else "%.2f" % x


def report(out, seed):
    rows = [json.loads(l) for l in open(os.path.join(out, "runs.jsonl"))]
    rng = random.Random(seed)
    usable = [r for r in rows if r.get("ok") and not r.get("contaminated")]
    tasks = sorted({r["task"] for r in rows})
    lines = ["# graphify A/B report", "",
             "runs ingested: %d, usable (ok, arm B uncontaminated): %d" % (len(rows), len(usable)),
             "contaminated B runs: %d; A runs that never called graphify: %d"
             % (sum(1 for r in rows if r.get("contaminated")), sum(1 for r in rows if r.get("unused_graph"))),
             "runs with no transcript (graph use unverified): %d" % sum(1 for r in usable if r.get("graphify_calls") is None), ""]
    metrics = [("weighted_tokens", "weighted tokens"), ("tool_calls", "tool calls"),
               ("wall_s", "wall s"), ("cost_usd", "cost USD"), ("correct", "correct")]
    lines += ["## Per task (mean [min..max] over reps)", "",
              "| task | metric | A | B | n A/B |", "|---|---|---|---|---|"]
    for t in tasks:
        for key, label in metrics:
            cells = []
            for arm in "AB":
                xs = [float(r[key]) for r in usable if r["task"] == t and r["arm"] == arm and r.get(key) is not None]
                lo, hi = spread(xs)
                cells.append("%s [%s..%s]" % (fmt(mean(xs)), fmt(lo), fmt(hi)) if xs else "n/a")
            na = sum(1 for r in usable if r["task"] == t and r["arm"] == "A")
            nb = sum(1 for r in usable if r["task"] == t and r["arm"] == "B")
            lines.append("| %s | %s | %s | %s | %d/%d |" % (t, label, cells[0], cells[1], na, nb))
    lines += ["", "## Overall delta A - B (tasks weighted equally, bootstrap 95% CI)", "",
              "| metric | A mean | B mean | delta | 95% CI | rel |", "|---|---|---|---|---|---|"]
    verdict_inputs = {}
    for key, label in metrics:
        by_task = {t: {"A": [], "B": []} for t in tasks}
        for r in usable:
            if r.get(key) is not None:
                by_task[r["task"]][r["arm"]].append(float(r[key]))
        full = [t for t in tasks if by_task[t]["A"] and by_task[t]["B"]]
        am = mean([mean(by_task[t]["A"]) for t in full])
        bm = mean([mean(by_task[t]["B"]) for t in full])
        bd = boot_delta(by_task, key, rng)
        if bd is None:
            lines.append("| %s | n/a | n/a | n/a | n/a | n/a |" % label)
            continue
        pt, lo, hi = bd
        rel = pt / bm if bm else float("nan")
        verdict_inputs[key] = (pt, lo, hi, rel)
        lines.append("| %s | %s | %s | %s | [%s, %s] | %+.0f%% |" % (label, fmt(am), fmt(bm), fmt(pt), fmt(lo), fmt(hi), rel * 100))
    a_runs = [r for r in usable if r["arm"] == "A"]
    unused = sum(1 for r in a_runs if r.get("unused_graph"))
    unverified = sum(1 for r in usable if r.get("graphify_calls") is None)
    lines += ["", "## Verdict", "", verdict(verdict_inputs, unused, len(a_runs), unverified)]
    return "\n".join(lines)


def verdict(v, unused=0, a_runs=0, unverified=0):
    """KEEP-AND-PUSH: A's cost CI is wholly below 0 or its correctness CI wholly
    above 0, and neither gets worse. DROP: A is worse-or-equal on both with CIs
    that do not favour it. Otherwise NEUTRAL. When the model ignored the graph in
    at least half of the arm-A runs the arms did not differ in treatment, so the
    result is NEUTRAL with that stated, never KEEP or DROP."""
    if "weighted_tokens" not in v or "correct" not in v:
        return "VERDICT: INCONCLUSIVE (missing metrics)"
    if unverified:
        return ("VERDICT: INCONCLUSIVE (%d usable runs have no transcript, so graph use is unverified "
                "and arm contamination cannot be ruled out)" % unverified)
    if a_runs and unused * 2 >= a_runs:
        return ("VERDICT: NEUTRAL (arm A never exercised the treatment: graph unused in %d/%d runs, "
                "so this sweep cannot show a benefit or a cost of graphify)" % (unused, a_runs))
    _, clo, chi, crel = v["weighted_tokens"]
    _, qlo, qhi, _ = v["correct"]
    cheaper = chi < 0
    pricier = clo > 0
    better = qlo > 0
    worse = qhi < 0
    if (cheaper and not worse) or (better and not pricier):
        return "VERDICT: KEEP-AND-PUSH (cost delta %+.0f%% rel, CI [%s, %s]; correct CI [%s, %s])" % (crel * 100, fmt(clo), fmt(chi), fmt(qlo), fmt(qhi))
    if not cheaper and not better:
        return "VERDICT: DROP (A is not cheaper and not more correct: cost CI [%s, %s], correct CI [%s, %s])" % (fmt(clo), fmt(chi), fmt(qlo), fmt(qhi))
    return "VERDICT: NEUTRAL (cost CI [%s, %s], correct CI [%s, %s])" % (fmt(clo), fmt(chi), fmt(qlo), fmt(qhi))


def main(argv):
    if len(argv) < 2 or argv[0] not in ("ingest", "report"):
        print(__doc__, file=sys.stderr)
        return 2
    out = argv[1]
    if argv[0] == "ingest":
        root = os.path.expanduser("~/.claude/projects")
        if "--transcripts" in argv:
            root = argv[argv.index("--transcripts") + 1]
        rows = ingest(out, root)
        print(json.dumps({"runs": len(rows)}))
        return 0
    seed = int(argv[argv.index("--seed") + 1]) if "--seed" in argv else 5317
    print(report(out, seed))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
