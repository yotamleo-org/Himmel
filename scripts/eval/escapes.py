#!/usr/bin/env python3
"""scripts/eval/escapes.py - bugs found after merge, per critic and per judge (HIMMEL-7517).

A merged PR has escaped review when a later signal says it shipped a bug:

  revert       sure       a PR titled "Revert ..." or "revert(...)" names it (#n) or its merge commit
  caused-by    sure       a Bug ticket in the Jira mirror carries `caused-by: #n` (how a red main run
                          bisected to a PR is recorded)
  fix-forward  plausible  a PR titled "fix..." names it (#n) in its title or body and merged after it;
                          a fix often names an earlier PR only as context, so this is never a sure escape

escapes counts PRs with a sure signal, escapes_plausible PRs with any signal; a PR counts once however
many signals it has. Per critic (a CR-ledger critic that reviewed the PR's branch: an `ok` avail row or a
finding, labelled as cr_ledger_eval.py labels it; keys critic.<critic>.*) and per judge (the model of each
GO verdict record on the PR, console GOs left out; keys judge.<model>.*): prs, escapes, escapes_plausible
and escape_rate.

  escapes.py --prs FILE [--cr-ledger P] [--mirror DIR] [--verdicts DIR] [--record] [--ledger P]

--prs is `gh pr list --state merged --limit 5000 --json number,title,body,mergedAt,headRefName,mergeCommit`.
Without --verdicts there are no judge numbers. Without --record the eval-runs row is printed, not appended.
A PR merged recently has had less time to show an escape, so its rate reads low.
Exit 0 done; 2 refused input. Stdlib only; no network, no model call.
"""
import argparse
import collections
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "lib"))
sys.path.insert(0, os.path.join(HERE, "cr-ledger"))
sys.path.insert(0, os.path.join(HERE, "judge-accuracy"))
import cr_ledger_eval  # noqa: E402
import eval_runs  # noqa: E402
import judge_accuracy  # noqa: E402

EVAL_ID = "escapes"
SOURCE = "scripts/eval/escapes.py"
REVERT = re.compile(r"^\s*revert\b", re.I)
FIX = re.compile(r"^\s*fix[(!:]")
REVERTS_SHA = re.compile(r"reverts commit ([0-9a-f]{7,40})", re.I)


def signals(prs, bugs):
    """{pr: {(kind, level), ...}} for every merged PR a later signal points at."""
    merged = {p["number"]: p for p in prs if p.get("mergedAt")}
    by_sha = {(p.get("mergeCommit") or {}).get("oid") or "": n for n, p in merged.items()}
    out = collections.defaultdict(set)
    count = collections.Counter()
    for n, p in merged.items():
        text = (p.get("title") or "") + "\n" + (p.get("body") or "")
        named = {int(x) for x in judge_accuracy.CITE.findall(text)}
        named = {t for t in named if t != n and t in merged and merged[t]["mergedAt"] < p["mergedAt"]}
        if REVERT.match(p.get("title") or ""):
            for sha in REVERTS_SHA.findall(text):
                named |= {t for s, t in by_sha.items() if s and s.startswith(sha.lower()) and t != n}
            kind, level = "revert", "S"
        elif FIX.match(p.get("title") or ""):
            kind, level = "fix-forward", "P"
        else:
            continue
        for t in named:
            out[t].add((kind, level))
            count[kind] += 1
    for b in bugs:
        if b["caused_by"] and b["caused_by"].isdigit() and int(b["caused_by"]) in merged:
            out[int(b["caused_by"])].add(("caused-by", "S"))
            count["caused-by"] += 1
    return merged, out, count


def reviewers(rows):
    """{branch: {critic, ...}} from ok avail rows and findings."""
    by = collections.defaultdict(set)
    for r in rows:
        if r.get("kind") == "avail" and r.get("status") == "ok" and r.get("model"):
            rm = r.get("responding_model")
            by[r.get("branch") or ""].add(r["model"] + ":" + rm if rm else r["model"])
    for f in cr_ledger_eval.fold(rows):
        by[f["branch"]].add(f["critic"])
    return by


def judges(recs):
    """{pr: {judge model, ...}} from the GO verdict records, console GOs left out."""
    by = collections.defaultdict(set)
    for r in recs:
        if r["verdict"] == "GO" and r["pr"] is not None and not r["console"]:
            by[r["pr"]].add(r["model"] or "unknown")
    return by


def tally(m, ci, prefix, prs, sig):
    k = sum(1 for n in prs if any(lv == "S" for _, lv in sig.get(n, ())))
    m[prefix + "prs"] = len(prs)
    m[prefix + "escapes"] = k
    m[prefix + "escapes_plausible"] = sum(1 for n in prs if sig.get(n))
    m[prefix + "escape_rate"] = round(k / len(prs), 4) if prs else None
    b = judge_accuracy.wilson(k, len(prs))
    if b:
        ci[prefix + "escape_rate"] = b


def build(prs, rows, bugs, recs):
    merged, sig, count = signals(prs, bugs)
    m, ci = {"merged": len(merged)}, {}
    m["escapes"] = sum(1 for n in merged if any(lv == "S" for _, lv in sig.get(n, ())))
    m["escapes_plausible"] = sum(1 for n in merged if sig.get(n))
    m["escape_rate"] = round(m["escapes"] / len(merged), 4) if merged else None
    m["escape_rate_plausible"] = round(m["escapes_plausible"] / len(merged), 4) if merged else None
    b = judge_accuracy.wilson(m["escapes"], len(merged))
    if b:
        ci["escape_rate"] = b
    for kind in ("revert", "fix-forward", "caused-by"):
        m["signal." + kind] = count[kind]
    rev = reviewers(rows)
    per = collections.defaultdict(list)
    for n, p in merged.items():
        for c in rev.get(p.get("headRefName") or "", ()):
            per[c].append(n)
    m["reviewed"] = sum(1 for p in merged.values() if rev.get(p.get("headRefName") or ""))
    for c in sorted(per):
        tally(m, ci, "critic." + c + ".", per[c], sig)
    if recs is not None:
        per = collections.defaultdict(list)
        for n, models in judges(recs).items():
            if n in merged:
                for j in models:
                    per[j].append(n)
        for j in sorted(per):
            tally(m, ci, "judge." + j + ".", per[j], sig)
    return eval_runs.make_row(EVAL_ID, SOURCE, {"escapes_v": 1, "judges": recs is not None}, m, n=len(merged),
                              ci=ci, ci_level=0.95 if ci else None, ci_method="wilson" if ci else None)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--prs", required=True)
    ap.add_argument("--cr-ledger")
    ap.add_argument("--mirror", default=judge_accuracy.MIRROR)
    ap.add_argument("--verdicts")
    ap.add_argument("--record", action="store_true")
    ap.add_argument("--ledger")
    a = ap.parse_args(argv)
    try:
        prs = judge_accuracy.load_json(a.prs, "--prs")
        bugs = judge_accuracy.load_bugs(a.mirror)
        recs = judge_accuracy.load_verdicts(a.verdicts)[0] if a.verdicts else None
    except ValueError as e:
        print("escapes: refused: %s" % e, file=sys.stderr)
        return 2
    rows, _ = cr_ledger_eval.load(a.cr_ledger or cr_ledger_eval.default_ledger(), None)
    row = build(prs, rows, bugs, recs)
    if a.record:
        eval_runs.append_safe(row, a.ledger, who=EVAL_ID)
    else:
        print(json.dumps(row, indent=1, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
