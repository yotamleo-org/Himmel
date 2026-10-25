#!/usr/bin/env python3
"""scripts/eval/escapes.py - bugs found after merge, per critic and per judge (HIMMEL-7517).

A merged PR has escaped review when a later signal says it shipped a bug:

  revert       sure       a PR titled "Revert ..." or "revert(...)" names it in its title (#n), as
                          "Reverts [owner/repo]#n", or as "This reverts commit <merge sha>"; a PR or commit it
                          cites only as context is not named
  caused-by    sure       a Bug ticket in the Jira mirror created after the merge carries `caused-by: #n` (how
                          a red main run bisected to a PR is recorded)
  fix-forward  plausible  a PR titled "fix..." names it (#n) in its title or body and merged after it;
                          a fix often names an earlier PR only as context, so this is never a sure escape

escapes counts PRs with a sure signal, escapes_plausible PRs with any signal; a PR counts once however
many signals it has. Per critic (a CR-ledger critic that reviewed the PR's branch by its merge: an `ok` avail row or a
finding, labelled as cr_ledger_eval.py labels it; keys critic.<critic>.*) and per judge (the model of each
GO verdict record on the PR at its merged head and before its merge, console GOs left out; keys judge.<model>.*): prs, escapes, escapes_plausible
and escape_rate.

  escapes.py --prs FILE [--cr-ledger P] [--mirror DIR] [--verdicts DIR] [--until TS] [--record] [--ledger P]

--prs is `gh pr list --state merged --limit 5000 --json number,title,body,mergedAt,headRefName,headRefOid,mergeCommit`.
--until cuts the sample as of TS: PRs merged after it, Bugs created after it and CR-ledger rows after it
are left out.
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
REVERTS_PR = re.compile(r"\breverts?\s+(?:[\w.-]+/[\w.-]+)?#(\d+)", re.I)
REVERTS_SHA = re.compile(r"\breverts?\s+(?:commit\s+)?`?([0-9a-f]{7,40})\b", re.I)


def signals(prs, bugs):
    """{pr: {(kind, level), ...}} for every merged PR a later signal points at."""
    merged = {p["number"]: p for p in prs if p.get("mergedAt")}
    by_sha = {(p.get("mergeCommit") or {}).get("oid") or "": n for n, p in merged.items()}
    out = collections.defaultdict(set)
    count = collections.Counter()
    for n, p in merged.items():
        title = p.get("title") or ""
        text = title + "\n" + (p.get("body") or "")
        if REVERT.match(title):
            named = {int(x) for x in judge_accuracy.CITE.findall(title) + REVERTS_PR.findall(text)}
            for sha in REVERTS_SHA.findall(text):
                named |= {t for s, t in by_sha.items() if s and s.startswith(sha.lower())}
            kind, level = "revert", "S"
        elif FIX.match(title):
            named = {int(x) for x in judge_accuracy.CITE.findall(text)}
            kind, level = "fix-forward", "P"
        else:
            continue
        for t in {t for t in named if t != n and t in merged and merged[t]["mergedAt"] < p["mergedAt"]}:
            out[t].add((kind, level))
            count[kind] += 1
    for b in bugs:
        t = merged.get(int(b["caused_by"])) if b["caused_by"] and b["caused_by"].isdigit() else None
        if t and (not b["created"] or b["created"] > judge_accuracy.when(t["mergedAt"])):
            out[t["number"]].add(("caused-by", "S"))
            count["caused-by"] += 1
    return merged, out, count


def reviewers(rows):
    """{branch: {critic: [row time, ...]}} from ok avail rows and findings; an undated row's time is None."""
    by = collections.defaultdict(lambda: collections.defaultdict(list))
    for r in rows:
        if r.get("kind") == "avail" and r.get("status") == "ok" and r.get("model"):
            rm = r.get("responding_model")
            critic = r["model"] + ":" + rm if rm else r["model"]
            by[r.get("branch") or ""][critic].append(judge_accuracy.when(r.get("ts") or ""))
    for f in cr_ledger_eval.fold(rows):
        by[f["branch"]][f["critic"]].append(judge_accuracy.when(f["ts"]))
    return by


def reviewed_before(rev, p):
    """The critics with a row on the PR's branch at or before its merge (an undated row counts)."""
    cut = judge_accuracy.when(p["mergedAt"])
    return {c for c, ts in rev.get(p.get("headRefName") or "", {}).items() if any(t is None or t <= cut for t in ts)}


def judges(recs, merged):
    """{pr: {judge model, ...}} from the GO verdict records at the merged head before the merge, console GOs left out."""
    by = collections.defaultdict(set)
    for r in recs:
        p = merged.get(r["pr"])
        if r["verdict"] != "GO" or r["console"] or not p or r["head"] != p.get("headRefOid"):
            continue
        if r["at"] and r["at"] <= judge_accuracy.when(p["mergedAt"]):
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


def build(prs, rows, bugs, recs, until=None):
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
    m["reviewed"] = 0
    for n, p in merged.items():
        critics = reviewed_before(rev, p)
        m["reviewed"] += bool(critics)
        for c in critics:
            per[c].append(n)
    for c in sorted(per):
        tally(m, ci, "critic." + c + ".", per[c], sig)
    if recs is not None:
        per = collections.defaultdict(list)
        for n, models in judges(recs, merged).items():
            for j in models:
                per[j].append(n)
        for j in sorted(per):
            tally(m, ci, "judge." + j + ".", per[j], sig)
    return eval_runs.make_row(EVAL_ID, SOURCE, {"escapes_v": 1, "judges": recs is not None, "until": until}, m, n=len(merged),
                              ci=ci, ci_level=0.95 if ci else None, ci_method="wilson" if ci else None)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--prs", required=True)
    ap.add_argument("--cr-ledger")
    ap.add_argument("--mirror", default=judge_accuracy.MIRROR)
    ap.add_argument("--verdicts")
    ap.add_argument("--until")
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
    rows, _ = cr_ledger_eval.load(a.cr_ledger or cr_ledger_eval.default_ledger(), a.until)
    if a.until:
        cut = judge_accuracy.when(a.until)
        prs = [p for p in prs if p.get("mergedAt") and judge_accuracy.when(p["mergedAt"]) <= cut]
        bugs = [b for b in bugs if not b["created"] or b["created"] <= cut]
    row = build(prs, rows, bugs, recs, a.until)
    if a.record:
        eval_runs.append_safe(row, a.ledger, who=EVAL_ID)
    else:
        print(json.dumps(row, indent=1, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
