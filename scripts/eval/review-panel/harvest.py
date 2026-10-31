#!/usr/bin/env python3
"""scripts/eval/review-panel/harvest.py - candidate review escapes for the reviewer eval (HIMMEL-8426 RL2).

Lists merged PRs whose bug the review panel let through, from four sources, one JSON line each:

  revert / caused-by  sure       scripts/eval/escapes.py signals (a revert names the PR; a Bug carries caused-by)
  fix-forward         plausible  escapes.py: a fix PR names it - often only as context, so a human checks it
  judge-no-go         sure       a non-procedural judge NO-GO verdict: the judge caught what review passed
  deferred-escape     sure       a Jira mirror ticket labelled deferred-escape (its PR from `caused-by: #n`)

Fields: signal, level (sure | plausible), pr, ticket (the [KEY] of the PR title), head (the escaped head: the
PR's merge-time head, or the NO-GO head), base (the merge commit's first parent, null when this clone lacks it),
fix (the fixing PR's merge commit, or for a NO-GO the PR's merged head) and fix_pr. It builds no case: RL3
curates the candidates into fixtures.

  harvest.py --prs FILE [--mirror DIR] [--verdicts DIR] [--repo R] [--since D]

--prs is `gh pr list --state merged --limit 5000 --json number,title,body,mergedAt,headRefOid,mergeCommit`.
--since keeps candidates whose PR merged (or NO-GO was written) at or after D. A missing --mirror leaves out
caused-by and deferred-escape. Read-only, local: no network, no model call. Exit 0 done; 2 refused input.
"""
import argparse
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
sys.path.insert(0, os.path.join(HERE, "..", "judge-accuracy"))
import escapes  # noqa: E402
import judge_accuracy as ja  # noqa: E402

KEY = re.compile(r"\[([A-Z][A-Z0-9]+-\d+)\]")
CAUSED_BY_PR = re.compile(r"caused-by:\s*#(\d+)\b", re.I)
LEVEL = {"S": "sure", "P": "plausible"}


def merge_oid(p):
    return (p.get("mergeCommit") or {}).get("oid") if p else None


def first_parent(repo, oid):
    if not oid:
        return None
    r = subprocess.run(["git", "-C", repo, "rev-parse", "--verify", "-q", oid + "^1"], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None


def ticket(p):
    m = KEY.search((p or {}).get("title") or "")
    return m.group(1) if m else None


def deferred_marks(mirror):
    """[(ticket key, pr or None)] for every mirror ticket labelled deferred-escape."""
    out = []
    for f in sorted(os.listdir(mirror)):
        if not f.endswith(".md"):
            continue
        text = open(os.path.join(mirror, f), encoding="utf-8", errors="replace").read()
        try:
            labels = json.loads(ja.header(text, "labels") or "[]")
        except ValueError:
            labels = []
        if "deferred-escape" in labels:
            m = CAUSED_BY_PR.search(text.split("\n---\n", 1)[-1])
            out.append((os.path.splitext(f)[0], int(m.group(1)) if m else None))
    return out


def harvest(prs, bugs, recs, marks, repo, since=None):
    merged, sig, _ = escapes.signals(prs, bugs)
    fixers = [p for p in merged.values() if escapes.REVERT.match(p.get("title") or "") or escapes.FIX.match(p.get("title") or "")]

    def row(signal, level, pr, head, fix, fix_pr, tkt=None):
        p = merged.get(pr)
        return {"signal": signal, "level": level, "pr": pr, "ticket": tkt or ticket(p), "head": head,
                "base": first_parent(repo, merge_oid(p)), "fix": fix, "fix_pr": fix_pr}

    out = []
    for t, kinds in sorted(sig.items()):
        p = merged[t]
        for kind, level in sorted(kinds):
            if kind == "caused-by":
                keys = [b["key"] for b in bugs if b["caused_by"] == str(t)]
                fx = next((f for f in merged.values() for k in keys if "[%s]" % k in (f.get("title") or "")), None)
                out.append(row(kind, LEVEL[level], t, p.get("headRefOid"), merge_oid(fx), fx and fx["number"]))
                continue
            # The fixer is the revert / fix PR whose own signal, alone with this PR, points at it.
            fx = next((f for f in fixers if f["number"] != t and
                       (kind, level) in escapes.signals([p, f], [])[1].get(t, set())), None)
            out.append(row(kind, LEVEL[level], t, p.get("headRefOid"), merge_oid(fx), fx and fx["number"]))
    for r in recs or []:
        if r["verdict"] == "NO-GO" and not r["procedural"] and r["pr"]:
            p = merged.get(r["pr"])
            out.append(dict(row("judge-no-go", "sure", r["pr"], r["head"], p and p.get("headRefOid"), None),
                            at=r["at"].isoformat() if r["at"] else None))
    for key, pr in marks:
        p = merged.get(pr)
        out.append(row("deferred-escape", "sure", pr, p and p.get("headRefOid"), None, None, key))
    if since:
        cut = ja.when(since)

        def recent(c):
            if c.get("at"):
                return ja.when(c["at"]) >= cut
            p = merged.get(c["pr"])
            return not p or ja.when(p["mergedAt"]) >= cut
        out = [c for c in out if recent(c)]
    for c in out:
        c.pop("at", None)
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--prs", required=True)
    ap.add_argument("--mirror", default=ja.MIRROR)
    ap.add_argument("--verdicts")
    ap.add_argument("--repo", default=HERE)
    ap.add_argument("--since")
    a = ap.parse_args(argv)
    try:
        prs = ja.load_json(a.prs, "--prs")
        bugs, marks = [], []
        if os.path.isdir(a.mirror):
            bugs, marks = ja.load_bugs(a.mirror), deferred_marks(a.mirror)
        else:
            print("harvest: no Jira mirror at %s: caused-by and deferred-escape left out" % a.mirror, file=sys.stderr)
        recs = ja.load_verdicts(a.verdicts)[0] if a.verdicts else []
    except ValueError as e:
        print("harvest: refused: %s" % e, file=sys.stderr)
        return 2
    for c in harvest(prs, bugs, recs, marks, a.repo, a.since):
        print(json.dumps(c, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
