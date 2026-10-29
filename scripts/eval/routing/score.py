#!/usr/bin/env python3
"""scripts/eval/routing/score.py - score which skill, command, agent or MCP tool a model
picks for a request (HIMMEL-8088): exact, near and false-pick rates, open and sealed, with
Wilson 95% intervals; one row per run into the eval-runs ledger (scripts/eval/lib/eval_runs.py).

  score.py lint  --listing JSON [--cases DIR]
  score.py score --listing JSON --outputs DIR [--cases DIR] [--only a,b] [--model M] [--json OUT]
                 [--table OUT] [--ledger PATH | --no-ledger] [--meta-json J]

Inputs. cases/open.jsonl and cases/sealed.jsonl hold one case per line: id, split (the
file's half), request, context, expect (a listed name, or "none" when no entry should be
used), near (listed names that count as a near pick) and source (where the case was mined).
--listing is `listing.mjs --json`: the names a pick is checked against, its sha and tokens.
<outputs>/<id>.json is the JSON result envelope run.sh kept for that case; its result
text carries {"pick": "<name>" | "none"}.

Outcome per case: exact (the expected pick, or none when none was expected), near (a listed
near name), miss (none when an entry was expected), false (any other pick, an unlisted name
included). A case with no envelope, an error envelope or no parsable pick is unscored.
accuracy = exact / scored, and near_rate, miss_rate and false_pick_rate likewise.

Split (eval_feedback.py, HIMMEL-7519). Every metric is also reported per half as
open.<metric> and sealed.<metric>. Tuning reads the open half only; the sealed half only
decides keep or revert. The results JSON and table show a sealed case by id, pick and
outcome only, never its request or expected pick.

Exit: 0 scored / lint clean; 1 lint problems; 2 refused input. Stdlib only; no model call.
"""
import argparse
import hashlib
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
import eval_runs  # noqa: E402
from wilson import wilson  # noqa: E402

EVAL_ID = "routing"
SOURCE = "scripts/eval/routing/score.py"
HALVES = ("open", "sealed")
FIELDS = ("id", "split", "request", "context", "expect", "near", "source")
MIN_CASES = 40
PICK_RE = re.compile(r'\{\s*"pick"\s*:\s*"([^"]*)"\s*\}')


def load_cases(cases_dir):
    cases = []
    for half in HALVES:
        with open(os.path.join(cases_dir, half + ".jsonl"), encoding="utf-8") as fh:
            for i, line in enumerate(fh, 1):
                if line.strip():
                    c = json.loads(line)
                    c["_file"] = "%s.jsonl:%d" % (half, i)
                    c["_half"] = half
                    cases.append(c)
    return cases


def load_listing(path):
    with open(path, encoding="utf-8") as fh:
        listing = json.load(fh)
    return listing, {e["name"] for e in listing["entries"]}


def lint(cases, names):
    problems, seen = [], set()
    for c in cases:
        where = c["_file"]
        missing = [f for f in FIELDS if f not in c]
        if missing:
            problems.append("%s: missing %s" % (where, ", ".join(missing)))
            continue
        if c["id"] in seen:
            problems.append("%s: duplicate id %s" % (where, c["id"]))
        seen.add(c["id"])
        if c["split"] != c["_half"]:
            problems.append("%s: split %r in the %s file" % (where, c["split"], c["_half"]))
        if c["expect"] != "none" and c["expect"] not in names:
            problems.append("%s: expect %r is not a listed name" % (where, c["expect"]))
        for n in c["near"]:
            if n not in names or n == c["expect"]:
                problems.append("%s: near %r is not a listed name other than expect" % (where, n))
        if not c["request"].strip() or not c["source"].strip():
            problems.append("%s: empty request or source" % where)
    sealed = sum(c["_half"] == "sealed" for c in cases)
    if len(cases) < MIN_CASES:
        problems.append("%d cases, need at least %d" % (len(cases), MIN_CASES))
    elif not 0.4 <= sealed / len(cases) <= 0.6:
        problems.append("split is %d sealed of %d, want about half" % (sealed, len(cases)))
    return problems


def read_pick(path):
    """(pick, cost_usd, why-unscored)."""
    try:
        with open(path, encoding="utf-8") as fh:
            env = json.load(fh)
    except (OSError, ValueError):
        return None, 0.0, "no envelope"
    cost = float(env.get("total_cost_usd") or 0.0)
    if env.get("is_error") or env.get("subtype") not in (None, "success"):
        return None, cost, "error envelope: %s" % env.get("subtype")
    m = PICK_RE.findall(str(env.get("result") or ""))
    if not m:
        return None, cost, "no pick in the result"
    return m[-1].strip().lstrip("/"), cost, None


def outcome(case, pick):
    if pick == case["expect"]:
        return "exact"
    if pick in case["near"]:
        return "near"
    if pick == "none":
        return "miss"
    return "false"


def ratio(k, n):
    return round(k / n, 4) if n else None


def score(cases, names, outputs):
    rows, unscored, cost = {}, [], 0.0
    for c in cases:
        pick, usd, why = read_pick(os.path.join(outputs, c["id"] + ".json"))
        cost += usd
        if why:
            unscored.append({"id": c["id"], "why": why})
            continue
        rows[c["id"]] = {"split": c["split"], "pick": pick, "outcome": outcome(c, pick),
                         "unlisted": pick != "none" and pick not in names}
    metrics, ci = {}, {}
    for prefix, members in (("", rows), *(("%s." % h, {k: r for k, r in rows.items() if r["split"] == h})
                                          for h in HALVES)):
        n = len(members)
        metrics[prefix + "n"] = n
        for name, want in (("accuracy", "exact"), ("near_rate", "near"),
                           ("miss_rate", "miss"), ("false_pick_rate", "false")):
            k = sum(r["outcome"] == want for r in members.values())
            metrics[prefix + name] = ratio(k, n)
            b = wilson(k, n)
            if b and name in ("accuracy", "false_pick_rate"):
                ci[prefix + name] = b
        metrics[prefix + "unlisted_picks"] = sum(r["unlisted"] for r in members.values())
    metrics["unscored"] = len(unscored)
    metrics["cost_usd"] = round(cost, 4)
    status = "inconclusive" if not rows else "partial" if unscored else "ok"
    return {"status": status, "metrics": metrics, "ci": ci, "rows": rows, "unscored": unscored}


def case_set_hash(cases_dir):
    h = hashlib.sha256()
    for half in HALVES:
        h.update(eval_runs.file_sha256(os.path.join(cases_dir, half + ".jsonl")).encode())
    return h.hexdigest()[:16]


def public_rows(cases, res):
    """Per-case rows for the results file: a sealed case shows id, pick and outcome only."""
    out = []
    for c in cases:
        r = res["rows"].get(c["id"])
        row = {"id": c["id"], "split": c["split"], "pick": r["pick"] if r else None,
               "outcome": r["outcome"] if r else "unscored"}
        if c["split"] == "open":
            row.update(request=c["request"], expect=c["expect"])
        out.append(row)
    return out


def table(model, rows):
    out = ["| id | split | expect | pick | outcome |", "|---|---|---|---|---|"]
    for r in rows:
        out.append("| %s | %s | %s | %s | %s |" % (r["id"], r["split"], r.get("expect", "(sealed)"),
                                                  r["pick"] or "-", r["outcome"]))
    return "routing %s, per case\n\n%s\n" % (model or "?", "\n".join(out))


def report(model, res):
    m = res["metrics"]

    def f(x):
        return "  -  " if x is None else "%.2f" % x
    out = ["routing %s: scored %d, unscored %d, cost $%.4f, status=%s"
           % (model or "?", m["n"], m["unscored"], m["cost_usd"], res["status"])]
    out.append("%-7s %-9s %-6s %-6s %-6s %s" % ("half", "accuracy", "near", "miss", "false", "n"))
    for prefix, label in (("", "all"), ("open.", "open"), ("sealed.", "sealed")):
        out.append("%-7s %-9s %-6s %-6s %-6s %d" % (label, f(m[prefix + "accuracy"]), f(m[prefix + "near_rate"]),
                                                   f(m[prefix + "miss_rate"]), f(m[prefix + "false_pick_rate"]),
                                                   m[prefix + "n"]))
    for u in res["unscored"]:
        out.append("UNSCORED %s: %s" % (u["id"], u["why"]))
    return "\n".join(out)


def main(argv=None):
    ap = argparse.ArgumentParser(prog="score.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    pl = sub.add_parser("lint")
    ps = sub.add_parser("score")
    for p in (pl, ps):
        p.add_argument("--cases", default=os.path.join(HERE, "cases"))
        p.add_argument("--listing", required=True)
    ps.add_argument("--outputs", required=True)
    ps.add_argument("--only", default="", help="score these case ids (default: every case)")
    ps.add_argument("--model")
    ps.add_argument("--json")
    ps.add_argument("--table")
    ps.add_argument("--ledger")
    ps.add_argument("--no-ledger", action="store_true")
    ps.add_argument("--meta-json", default="{}")
    a = ap.parse_args(argv)
    try:
        cases = load_cases(a.cases)
        listing, names = load_listing(a.listing)
        meta = json.loads(getattr(a, "meta_json", "{}"))
        if not isinstance(meta, dict):
            raise ValueError("--meta-json must be an object")
    except (OSError, ValueError, KeyError) as e:
        print("score.py: %s" % e, file=sys.stderr)
        return 2

    problems = lint(cases, names)
    if a.cmd == "lint":
        for p in problems:
            print("lint: %s" % p, file=sys.stderr)
        print("routing lint: %d open, %d sealed, %d problem(s)" % (
            sum(c["_half"] == "open" for c in cases), sum(c["_half"] == "sealed" for c in cases), len(problems)))
        return 1 if problems else 0
    if problems:
        print("score.py: the cases do not lint (%s); run score.py lint" % problems[0], file=sys.stderr)
        return 2

    only = [x for x in a.only.split(",") if x]
    unknown = sorted(set(only) - {c["id"] for c in cases})
    if unknown:
        print("score.py: --only names unknown cases: %s" % ",".join(unknown), file=sys.stderr)
        return 2
    ran = [c for c in cases if not only or c["id"] in only]
    res = score(ran, names, a.outputs)
    print(report(a.model, res))
    rows = public_rows(ran, res)
    if a.json:
        doc = {"eval": EVAL_ID, "model": a.model, "status": res["status"], "case_set": case_set_hash(a.cases),
               "listing": {"sha": listing.get("sha"), "tokens": listing.get("tokens")},
               "metrics": res["metrics"], "ci": res["ci"], "cases": rows, "unscored": res["unscored"]}
        with open(a.json, "w", encoding="utf-8") as fh:
            json.dump(doc, fh, indent=2, sort_keys=True)
            fh.write("\n")
    if a.table:
        with open(a.table, "w", encoding="utf-8") as fh:
            fh.write(table(a.model, rows))
    if not a.no_ledger:
        config = {"case_set": case_set_hash(a.cases), "listing_sha": listing.get("sha"),
                  "cases": sorted(c["id"] for c in ran)}
        per_case = {cid: {"exact": int(r["outcome"] == "exact"), "false_pick": int(r["outcome"] == "false")}
                    for cid, r in res["rows"].items()}
        row = eval_runs.make_row(EVAL_ID, SOURCE, config, res["metrics"], n=res["metrics"]["n"], model=a.model,
                                 status=res["status"], ci=res["ci"], ci_level=0.95 if res["ci"] else None,
                                 ci_method="wilson" if res["ci"] else None, cases=per_case or None,
                                 artifact=os.path.abspath(a.outputs), meta=dict(meta, unscored=res["unscored"]),
                                 repo=HERE)
        eval_runs.append_safe(row, a.ledger, who="routing")
    return 0


if __name__ == "__main__":
    sys.exit(main())
