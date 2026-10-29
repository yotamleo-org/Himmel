#!/usr/bin/env python3
"""Lint and score a design-review eval run (HIMMEL-8085).

usage: score.py lint  --set <dir>
       score.py score --set <dir> --outputs <dir> [--ledger <path> | --no-ledger] [--label <name>]

<set> holds fixtures/case-NN.md (plus case-NN.parent.md for a plan) and
key/labels.json. <outputs>/<case>/ holds review.md and meta.json, written by run.sh.

A BAD case is a hit when one Critical or Important finding is on one of the
case's expected dimensions AND its block names one of the case's anchors (the
planted change). paired = a hit the GOOD twin does not also carry. A GOOD case
is a false alarm when it carries a Critical or Important finding on dims 9-13
(false_alarm_any: on any dim). Only cases with an output dir are scored;
paired is null when the twin did not run. A case with no SUMMARY line is no-answer: a miss
on a BAD case, left out of the false-alarm count on a GOOD one.

Writes <outputs>/results.jsonl (one row per case, then one summary row), prints
the table, and appends one eval-runs ledger row unless --no-ledger.
Exit: 0 scored or lint clean; 1 lint problems; 2 usage or unreadable input;
3 the key canary appears in an answer (the reviewer saw the key).
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

EVAL_ID = "design-review"
SOURCE = "scripts/eval/design-review/score.py"
CLASSES = ["trace", "rollback", "dod", "cheaper", "conflict", "scope"]
GATING = ("Critical", "Important")
DESIGN_DIMS = set(range(9, 14))
HINTS = re.compile(r"\b(planted|plants?|seeded|injected|canary|twin|deliberate(ly)? (broken|wrong))\b", re.I)
FINDING = re.compile(r"^\s*FINDING \[(dr-\d+)\] dim=(\d+) sev=(Critical|Important|Suggestion)\b", re.M)
SUMMARY = re.compile(r"^\s*SUMMARY findings=\d+", re.M)


def load_key(set_dir):
    with open(os.path.join(set_dir, "key", "labels.json"), encoding="utf-8") as f:
        return json.load(f)


def sha256(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def lint(set_dir):
    key = load_key(set_dir)
    problems = []
    fx = os.path.join(set_dir, "fixtures")
    for cid, c in sorted(key["cases"].items()):
        p = os.path.join(fx, cid + ".md")
        if not os.path.isfile(p):
            problems.append("%s: no fixture" % cid)
            continue
        if sha256(p) != c["sha256"]:
            problems.append("%s: fixture sha256 differs from the key" % cid)
        if os.path.isfile(os.path.join(fx, cid + ".parent.md")) != bool(c.get("parent")):
            problems.append("%s: parent file presence differs from the key" % cid)
        text = open(p, encoding="utf-8").read()
        m = HINTS.search(text)
        if m:
            problems.append("%s: hint word %r" % (cid, m.group(0)))
        if key["canary"] in text:
            problems.append("%s: carries the key canary" % cid)
        if c["verdict"] == "bad" and (c["class"] not in CLASSES or not c["dims"] or not c["anchors"]):
            problems.append("%s: a bad case needs a known class, dims and anchors" % cid)
        if c["verdict"] == "bad" and key["cases"].get(c.get("twin") or "", {}).get("verdict") != "good":
            problems.append("%s: its twin is not a good case" % cid)
    extra = sorted(set(n.split(".")[0] for n in os.listdir(fx)) - set(key["cases"])) if os.path.isdir(fx) else []
    problems += ["%s: fixture not in the key" % e for e in extra]
    return problems, key


def parse(text):
    """Finding dicts: id, dim, sev, and the block text (lower case) up to the next FINDING or SUMMARY."""
    heads = list(FINDING.finditer(text))
    out = []
    for i, m in enumerate(heads):
        end = heads[i + 1].start() if i + 1 < len(heads) else len(text)
        s = SUMMARY.search(text, m.end(), end)
        block = text[m.start():s.start() if s else end]
        out.append({"id": m.group(1), "dim": int(m.group(2)), "sev": m.group(3), "block": block.lower()})
    return out


def matches(f, c):
    return f["sev"] in GATING and f["dim"] in c["dims"] and any(a in f["block"] for a in c["anchors"])


def ratio(k, n):
    return round(k / n, 4) if n else None


def score(set_dir, outputs):
    key = load_key(set_dir)
    cases = key["cases"]
    canary = key["canary"]
    per = {}
    leaks = []
    ran = [cid for cid in sorted(cases) if os.path.isdir(os.path.join(outputs, cid))]
    if not ran:
        raise ValueError("no case output dir under %s" % outputs)
    for cid in ran:
        d = os.path.join(outputs, cid)
        review = os.path.join(d, "review.md")
        text = open(review, encoding="utf-8").read() if os.path.isfile(review) else ""
        meta = {}
        if os.path.isfile(os.path.join(d, "meta.json")):
            with open(os.path.join(d, "meta.json"), encoding="utf-8") as f:
                meta = json.load(f)
        if canary in text:
            leaks.append(cid)
        per[cid] = {"text": text, "meta": meta, "answered": bool(SUMMARY.search(text)), "findings": parse(text)}

    rows = []
    for cid in ran:
        c, p = cases[cid], per[cid]
        gate = [f for f in p["findings"] if f["sev"] in GATING]
        row = {"case": cid, "split": c["split"], "expected": c["verdict"], "class": c["class"],
               "dims_expected": c["dims"], "status": "ok" if p["answered"] else "no-answer",
               "findings": [{"id": f["id"], "dim": f["dim"], "sev": f["sev"]} for f in p["findings"]],
               "fixture_sha256": c["sha256"], "cost_usd": p["meta"].get("cost_usd"),
               "rc": p["meta"].get("rc"), "turns": p["meta"].get("turns")}
        if c["verdict"] == "bad":
            hit = p["answered"] and any(matches(f, c) for f in p["findings"])
            twin = per.get(c["twin"])
            row.update(hit=hit,
                       hit_dim=p["answered"] and any(f["dim"] in c["dims"] for f in gate),
                       hit_anchor=p["answered"] and any(any(a in f["block"] for a in c["anchors"]) for f in gate),
                       paired=None if twin is None else hit and not any(matches(f, c) for f in twin["findings"]))
        else:
            row.update(false_alarm=p["answered"] and any(f["dim"] in DESIGN_DIMS for f in gate),
                       false_alarm_any=p["answered"] and bool(gate))
        rows.append(row)

    metrics, ci = {}, {}

    def put(name, k, n):
        metrics[name] = ratio(k, n)
        b = wilson(k, n)
        if b:
            ci[name] = b

    for prefix, sel in (("", lambda r: True), ("open.", lambda r: r["split"] == "open"),
                        ("sealed.", lambda r: r["split"] == "sealed")):
        bad = [r for r in rows if r["expected"] == "bad" and sel(r)]
        good = [r for r in rows if r["expected"] == "good" and r["status"] == "ok" and sel(r)]
        put(prefix + "recall", sum(r["hit"] for r in bad), len(bad))
        pairs = [r for r in bad if r["paired"] is not None]
        put(prefix + "paired_recall", sum(r["paired"] for r in pairs), len(pairs))
        put(prefix + "false_alarm", sum(r["false_alarm"] for r in good), len(good))
        if not prefix:
            put("recall_dim", sum(r["hit_dim"] for r in bad), len(bad))
            put("recall_anchor", sum(r["hit_anchor"] for r in bad), len(bad))
            put("false_alarm_any", sum(r["false_alarm_any"] for r in good), len(good))
    for cls in CLASSES:
        sub = [r for r in rows if r["class"] == cls]
        if sub:
            metrics["class.%s.recall" % cls] = ratio(sum(r["hit"] for r in sub), len(sub))
            metrics["class.%s.n" % cls] = len(sub)
    costs = [r["cost_usd"] for r in rows if isinstance(r["cost_usd"], (int, float))]
    metrics.update(cases=len(rows), no_answer=sum(r["status"] != "ok" for r in rows), leaked=len(leaks),
                   cost_usd=round(sum(costs), 4) if costs else None,
                   cost_per_case=round(sum(costs) / len(costs), 4) if costs else None)
    status = "inconclusive" if leaks else ("partial" if metrics["no_answer"] else "ok")
    return {"rows": rows, "metrics": metrics, "ci": ci, "status": status, "leaks": leaks,
            "set_sha256": key["set_sha256"]}


def report(res, label):
    m = res["metrics"]

    def fmt(x):
        return "  -  " if x is None else "%.2f" % x
    out = ["design-review %s: %d cases, no-answer=%d, leaked=%d, status=%s, cost $%s"
           % (label, m["cases"], m["no_answer"], m["leaked"], res["status"], m["cost_usd"])]
    for cid in res["leaks"]:
        out.append("LEAK %s: its answer carries the key canary - the reviewer saw the key" % cid)
    out.append("%-15s %-6s %-6s %-6s" % ("metric", "all", "open", "sealed"))
    for name in ("recall", "paired_recall", "false_alarm"):
        ci = res["ci"].get(name)
        band = " [%.2f, %.2f]" % (ci["lo"], ci["hi"]) if ci else ""
        out.append("%-15s %-6s %-6s %-6s%s" % (name, fmt(m.get(name)), fmt(m.get("open." + name)),
                                              fmt(m.get("sealed." + name)), band))
    out.append("recall_dim %s, recall_anchor %s, false_alarm_any %s" % (
        fmt(m.get("recall_dim")), fmt(m.get("recall_anchor")), fmt(m.get("false_alarm_any"))))
    out.append("by class: " + "; ".join("%s %s (n=%d)" % (c, fmt(m.get("class.%s.recall" % c)), m["class.%s.n" % c])
                                        for c in CLASSES if "class.%s.n" % c in m))
    out.append("%-8s %-5s %-9s %-4s %-5s %-6s %s" % ("case", "exp", "class", "ok", "hit", "cost", "findings (dim/sev)"))
    for r in res["rows"]:
        got = r.get("hit", r.get("false_alarm"))
        out.append("%-8s %-5s %-9s %-4s %-5s %-6s %s" % (
            r["case"], r["expected"], r["class"] or "-", "y" if r["status"] == "ok" else "n",
            ("FA" if got else "-") if r["expected"] == "good" else ("HIT" if got else "miss"),
            "-" if r["cost_usd"] is None else "%.2f" % r["cost_usd"],
            " ".join("%d/%s" % (f["dim"], f["sev"][0]) for f in r["findings"]) or "none"))
    return "\n".join(out)


def main(argv=None):
    ap = argparse.ArgumentParser(prog="score.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    pl = sub.add_parser("lint")
    ps = sub.add_parser("score")
    for p in (pl, ps):
        p.add_argument("--set", required=True)
    ps.add_argument("--outputs", required=True)
    ps.add_argument("--ledger")
    ps.add_argument("--no-ledger", action="store_true")
    ps.add_argument("--label", default="baseline")
    a = ap.parse_args(argv)
    try:
        if a.cmd == "lint":
            problems, key = lint(a.set)
            for p in problems:
                print("lint: %s" % p, file=sys.stderr)
            bad = sum(c["verdict"] == "bad" for c in key["cases"].values())
            print("design-review lint: %d bad, %d good, %d problem(s)" % (bad, len(key["cases"]) - bad, len(problems)))
            return 1 if problems else 0
        res = score(a.set, a.outputs)
        with open(os.path.join(a.outputs, "run.json"), encoding="utf-8") as f:
            run = json.load(f)
    except (OSError, ValueError, KeyError) as e:
        print("score.py: %s" % e, file=sys.stderr)
        return 2
    print(report(res, a.label))
    common = {"run_id": run["run_id"], "label": a.label, "model": run["model"], "effort": run["effort"],
              "charter": run["charter"], "charter_sha256": run["charter_sha256"], "set_sha256": res["set_sha256"]}
    with open(os.path.join(a.outputs, "results.jsonl"), "w", encoding="utf-8") as f:
        for r in res["rows"]:
            f.write(json.dumps(dict(common, kind="case", **r), sort_keys=True) + "\n")
        f.write(json.dumps(dict(common, kind="summary", status=res["status"], metrics=res["metrics"], ci=res["ci"]),
                           sort_keys=True) + "\n")
    if not a.no_ledger:
        config = {"fixture_set": res["set_sha256"][:16], "charter_sha256": run["charter_sha256"][:16],
                  "label": a.label, "effort": run["effort"], "cap_usd": run.get("cap_usd"),
                  "classes": CLASSES, "gating": list(GATING)}
        cases = {r["case"]: {"hit": int(r["hit"])} if "hit" in r else {"false_alarm": int(r["false_alarm"])}
                 for r in res["rows"]}
        row = eval_runs.make_row(EVAL_ID, SOURCE, config, res["metrics"], n=res["metrics"]["cases"],
                                 model=run["model"], lane="api", status=res["status"], run_id=run["run_id"],
                                 ci=res["ci"], ci_level=0.95 if res["ci"] else None,
                                 ci_method="wilson" if res["ci"] else None, cases=cases,
                                 artifact=os.path.abspath(os.path.join(a.outputs, "results.jsonl")),
                                 meta={"effort": run["effort"], "leaks": res["leaks"]}, repo=HERE)
        eval_runs.append_safe(row, a.ledger, who="design-review")
    return 3 if res["leaks"] else 0


if __name__ == "__main__":
    sys.exit(main())
