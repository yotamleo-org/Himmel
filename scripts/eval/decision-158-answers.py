#!/usr/bin/env python3
"""scripts/eval/decision-158-answers.py - the five decision-158 questions as answer rows (HIMMEL-7385).

One eval-runs row (eval "decision-158") holds, per question, a percentage with its 95 % Wilson range, the
sample behind it and the same number measured at an earlier cut (before), so the review page can say
"X % (likely between A % and B %), was Y % before". It reads existing data only: no model call, no network.

  q1  test-first record      share of agent sessions that ran a failing test before the implementation
                             (sessions with no test run are left out, not counted as misses)
  q2  unsorted refusals      share of hook and gate refusals the classifier leaves unclear
  q3  judge model and effort share of judge verdicts written by the most used judge model
  q4  CodeRabbit sample      share of CodeRabbit's adjudicated findings that were right
  q5  Claude as 3rd reviewer share of the Claude critic's adjudicated findings that were right

  decision-158-answers.py [--ledger P] [--cr-ledger P] [--cut TS] [--record]

--cut (default 2026-10-22T00:00:00Z, the evals open-questions audit) splits before from after. Without
--record the row is printed, not appended. Ledger: $HIMMEL_EVAL_RUNS_LEDGER, else ~/.himmel/eval-runs.jsonl;
CR ledger: $CR_LEDGER, else <git common dir>/cr-critic-scores.jsonl.
"""
import argparse
import json
import math
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "lib"))
import eval_runs  # noqa: E402

CUT = "2026-10-22T00:00:00Z"
CR_EVAL = os.path.join(HERE, "cr-ledger", "cr_ledger_eval.py")


def wilson(k, n, z=1.959964):
    p = k / n
    den = 1 + z * z / n
    mid = (p + z * z / (2 * n)) / den
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / den
    return {"lo": round(max(0.0, mid - half), 4), "hi": round(min(1.0, mid + half), 4)}


def put(m, ci, key, k, n):
    """pct, k, n and its range under key; nothing when there is no sample."""
    if not n:
        return
    m[key + ".pct"], m[key + ".k"], m[key + ".n"] = round(k / n, 4), k, n
    ci[key + ".pct"] = wilson(k, n)


def q1(rows, cut, m, ci, notes):
    seen = [(r["ts"], r["metrics"].get("red_before_green")) for r in rows if r["eval"] == "leg-trajectory"]
    seen = [(t, 1 if v in (1, True) else 0) for t, v in seen if v is not None]
    put(m, ci, "q1", sum(v for t, v in seen), len(seen))
    early = [v for t, v in seen if t < cut]
    put(m, ci, "q1.before", sum(early), len(early))
    notes["q1"] = "every session that ran a test; the before figure stops at the cut"


def q2(rows, cut, m, ci, notes):
    fr = [r for r in rows if r["eval"] == "friction" and r["status"] in ("ok", "partial")]
    if fr:
        put(m, ci, "q2", fr[-1]["metrics"].get("unclear", 0), fr[-1]["metrics"].get("refusals", 0))
    old = [r for r in fr if r["ts"] <= cut]
    if old and old[-1] is not fr[-1]:
        put(m, ci, "q2.before", old[-1]["metrics"].get("unclear", 0), old[-1]["metrics"].get("refusals", 0))
    notes["q2"] = "refusals in the newest 7 day window; the before figure is the last window at or before the cut"


def q3(rows, cut, m, ci, notes):
    ja = [r for r in rows if r["eval"] == "judge-accuracy" and r["status"] in ("ok", "partial")]
    if ja:
        per = {k[6:-2]: v for k, v in ja[-1]["metrics"].items() if k.startswith("model.") and k.endswith(".n")}
        per.pop("unknown", None)
        if per:
            top = max(per, key=per.get)
            put(m, ci, "q3", per[top], sum(per.values()))
            notes["q3"] = "verdicts by %s; watching cannot compare judge models, a designed replay can" % top


def cr(path, until, critic):
    cmd = [sys.executable, "-I", CR_EVAL, "--json"] + (["--ledger", path] if path else []) + (["--until", until] if until else [])
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=120, check=True).stdout
        return json.loads(out)["critics"].get(critic) or {}
    except (subprocess.SubprocessError, ValueError, KeyError) as e:
        sys.stderr.write("decision-158-answers: %s measurement unavailable (%s)\n" % (critic, type(e).__name__))
        return {}


def q45(cr_ledger, cut, m, ci, notes):
    for q, critic in (("q4", "coderabbit"), ("q5", "claude:claude-opus-5-5")):
        for tag, until in (("", None), (".before", cut)):
            c = cr(cr_ledger, until, critic)
            put(m, ci, q + tag, c.get("agreed", 0), c.get("agreed", 0) + c.get("disproved", 0))
        notes[q] = "adjudicated findings (agreed or disproved) of %s; the before figure stops at the cut" % critic


def build(rows, cr_ledger, cut):
    m, ci, notes = {}, {}, {}
    for fn in (q1, q2, q3):
        fn(rows, cut, m, ci, notes)
    q45(cr_ledger, cut, m, ci, notes)
    n = sum(v for k, v in m.items() if k.endswith(".n") and ".before" not in k)
    return eval_runs.make_row("decision-158", "scripts/eval/decision-158-answers.py",
                              {"answers_v": 1, "cut": cut}, m, n=n, ci=ci, ci_level=0.95, ci_method="wilson",
                              meta={"cut": cut, "notes": notes})


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--ledger")
    ap.add_argument("--cr-ledger", default=os.environ.get("CR_LEDGER"))
    ap.add_argument("--cut", default=CUT)
    ap.add_argument("--record", action="store_true")
    a = ap.parse_args(argv)
    path = eval_runs.ledger_path(a.ledger)
    rows = eval_runs.read_rows(path) if os.path.exists(path) else []
    row = build(rows, a.cr_ledger, a.cut)
    if not row["metrics"]:
        sys.stderr.write("decision-158-answers: no data for any question in %s\n" % path)
        return 1
    if a.record:
        eval_runs.append_row(row, path)
    else:
        print(json.dumps(row, indent=1, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
