#!/usr/bin/env python3
"""scripts/eval/retrieval-eval/stale-sessions.py - the staleness session arms, one answer-ab.py process per served pair.

  stale-sessions.py --plan PLAN.json --max-usd 18 [--arms hybrid-rerank] [--model M]

PLAN.json is {"pairs": [{"pair": pair.json, "questions": bank.jsonl, "repo": R, "out": DIR}, ...]}, run in
order. Each pair.json names one served index (its state, served_url, doc_count) and the pair's second commit.
A process gets --index-state and --pair from that file, --rev at the second commit (the tree is current and
only the index is stale), QMD_URL at the served URL, and --pool and --n at the bank's count of questions
with a gold file.

--max-usd binds the whole plan, not one process: each process is given what is still unspent, the cost_usd
of every row already written under the other pairs' out dirs, and the plan stops once nothing is left.
Exit: 0 every process complete, 1 a process stopped or errored or the budget ran out, 2 or 64 a process
refused or was misused (the plan stops there).
Seams: STALE_SESSIONS_AB (the answer-ab.py to run). answer-ab.py makes the billed calls and refuses
without HIMMEL_BILLED_OK=1.
"""
import argparse
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def load_json(path):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError) as e:
        raise SystemExit("stale-sessions: cannot read %s: %s" % (path, e))


def gold_count(path):
    n = 0
    with open(path) as fh:
        for line in fh:
            try:
                if json.loads(line).get("gold"):
                    n += 1
            except ValueError:
                continue
    return n


def spent(out):
    total = 0.0
    path = os.path.join(out, "results.jsonl")
    if not os.path.isfile(path):
        return total
    with open(path) as fh:
        for line in fh:
            try:
                total += float(json.loads(line).get("cost_usd") or 0.0)
            except (ValueError, TypeError, AttributeError):
                continue
    return total


def main(argv=None):
    p = argparse.ArgumentParser(prog="stale-sessions.py")
    p.add_argument("--plan", required=True)
    p.add_argument("--max-usd", type=float, required=True)
    p.add_argument("--arms", default="hybrid-rerank")
    p.add_argument("--model")
    a = p.parse_args(argv)
    entries = load_json(a.plan).get("pairs") or []
    if not entries:
        raise SystemExit("stale-sessions: %s names no pair" % a.plan)
    ab = os.environ.get("STALE_SESSIONS_AB", os.path.join(HERE, "answer-ab.py"))
    failed = False
    for i, e in enumerate(entries):
        left = a.max_usd - sum(spent(o["out"]) for j, o in enumerate(entries) if j != i)
        if left <= 0:
            print("STOPPED: the %s budget is spent before pair %d of %d" % (a.max_usd, i + 1, len(entries)), file=sys.stderr)
            return 1
        pair = load_json(e["pair"])
        n = gold_count(e["questions"])
        cmd = [sys.executable, "-I", ab, "run", "--questions", e["questions"], "--repo", e["repo"], "--out", e["out"],
               "--arms", a.arms, "--pair", e["pair"], "--index-state", pair["state"], "--rev", pair["second"],
               "--pool", str(n), "--n", str(n), "--max-usd", "%.4f" % left]
        if a.model:
            cmd += ["--model", a.model]
        rc = subprocess.run(cmd, env=dict(os.environ, QMD_URL=pair["served_url"])).returncode
        if rc in (2, 64):
            return rc
        failed = failed or rc != 0
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
