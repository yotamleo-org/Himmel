#!/usr/bin/env python3
"""scripts/eval/leg-digest/pdd_share.py - the proof-first (PDD) share of merged PRs.

A PR is proof-first when both hold:
  1. its ticket's DoD and Proof existed before the PR's first commit: the ticket (Jira mirror) has a DoD
     section and a Proof section, and was created before the first commit's authored time;
  2. its body shows a RED line, and a GREEN line after it.
The row is one eval-runs row, eval "pdd-share": the share with its 95 % Wilson range over the n PRs that could
be read, plus the two halves on their own. It reads existing data only: no model call.

  pdd_share.py [--prs FILE] [--limit N] [--mirror DIR] [--ledger P] [--min-n N] [--record]

--prs is `gh pr list --state merged --json number,title,body,commits` output; without it the script asks gh for
the last --limit (100) merged PRs. A PR whose title names no ticket, or whose ticket is not in the mirror, is
counted in meta.skipped and left out of n. Fewer than --min-n (50) readable PRs makes the row "partial" and the
exit code 3. Without --record the row is printed, not appended.
Mirror: $HIMMEL_JIRA_MIRROR, else ~/.himmel/state/jira-mirror/<JIRA_PROJECT_KEY or HIMMEL>.
Ledger: $HIMMEL_EVAL_RUNS_LEDGER, else ~/.himmel/eval-runs.jsonl.
"""
import argparse
import json
import math
import os
import re
import subprocess
import sys
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
import eval_runs  # noqa: E402

PDD_SCHEMA = 1
TICKET_RE = re.compile(r"\b(?:HIMMEL|LUNA)-\d+\b")
FRONT_RE = re.compile(r'^created:\s*"([^"]+)"', re.M)
# A section is a heading line (bare or markdown) with something under it.
DOD_RE = re.compile(r"^[ \t]*(?:#+[ \t]*)?(?:DoD|Definition of Done)[ \t]*:?[ \t]*\n[ \t]*\S", re.M | re.I)
PROOF_RE = re.compile(r"^[ \t]*(?:#+[ \t]*)?Proof[ \t]*:?[ \t]*\n[ \t]*\S", re.M | re.I)
RED_RE = re.compile(r"\bRED\b")
GREEN_RE = re.compile(r"\b(?:GREEN|[Gg]reen)\b")
CR_BLOCK = "<!-- This is an auto-generated comment"


def wilson(k, n, z=1.959964):
    p = k / n
    den = 1 + z * z / n
    mid = (p + z * z / (2 * n)) / den
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / den
    return {"lo": round(max(0.0, mid - half), 4), "hi": round(min(1.0, mid + half), 4)}


def parse_ts(s):
    """A UTC-comparable datetime from Jira's `2026-10-22T22:58:04.539+0200` or GitHub's `...Z`; None if unreadable."""
    if not isinstance(s, str):
        return None
    for fmt in ("%Y-%m-%dT%H:%M:%S.%f%z", "%Y-%m-%dT%H:%M:%S%z"):
        try:
            return datetime.strptime(s.replace("Z", "+0000"), fmt)
        except ValueError:
            continue
    return None


def default_mirror():
    if os.environ.get("HIMMEL_JIRA_MIRROR"):
        return os.environ["HIMMEL_JIRA_MIRROR"]
    return os.path.expanduser("~/.himmel/state/jira-mirror/" + (os.environ.get("JIRA_PROJECT_KEY") or "HIMMEL"))


def ticket_proof_ts(mirror, key):
    """(found, ts): the mirror holds `key`, and when its DoD and Proof existed (None when it lacks either section).
    ponytail: the mirror keeps no description history, so the ticket's created time stands for it - a section
    added after creation reads as early; upgrade by reading the Jira changelog for the description field."""
    try:
        with open(os.path.join(mirror, key + ".md"), encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError:
        return False, None
    m = FRONT_RE.search(text)
    created = parse_ts(m.group(1)) if m else None
    body = text.split("\n## Comments", 1)[0]
    return True, (created if created and DOD_RE.search(body) and PROOF_RE.search(body) else None)


def first_commit_ts(pr):
    ts = [t for t in (parse_ts(c.get("authoredDate")) for c in pr.get("commits") or [] if isinstance(c, dict)) if t]
    return min(ts) if ts else None


def red_then_green(body):
    body = (body or "").split(CR_BLOCK, 1)[0]
    m = RED_RE.search(body)
    return bool(m and GREEN_RE.search(body, m.end()))


def read_pr(pr, mirror):
    """('skip', reason) or ('ok', ticket_first, red_green)."""
    m = TICKET_RE.search(pr.get("title") or "")
    if not m:
        return "skip", "no_ticket"
    found, proof_ts = ticket_proof_ts(mirror, m.group(0))
    first = first_commit_ts(pr)
    if not found:
        return "skip", "not_in_mirror"
    if first is None:
        return "skip", "no_commits"
    return "ok", bool(proof_ts and proof_ts < first), red_then_green(pr.get("body"))


def build(prs, mirror, min_n):
    skipped, rows = {}, []
    for pr in prs:
        r = read_pr(pr, mirror)
        if r[0] == "skip":
            skipped[r[1]] = skipped.get(r[1], 0) + 1
        else:
            rows.append(r[1:])
    n = len(rows)
    m, ci = {}, {}
    if n:
        for key, k in (("pdd", sum(a and b for a, b in rows)), ("ticket_first", sum(a for a, _ in rows)),
                       ("red_green", sum(b for _, b in rows))):
            m[key + ".pct"], m[key + ".k"], m[key + ".n"] = round(k / n, 4), k, n
            ci[key + ".pct"] = wilson(k, n)
    return eval_runs.make_row("pdd-share", "scripts/eval/leg-digest/pdd_share.py",
                              {"pdd_v": PDD_SCHEMA, "prs": len(prs), "min_n": min_n}, m, n=n, ci=ci,
                              ci_level=0.95, ci_method="wilson", status="ok" if n >= min_n else "partial",
                              meta={"skipped": skipped, "prs_seen": len(prs),
                                    "def": "ticket DoD and Proof before the first commit, and a RED line then a GREEN line in the PR body"})


def gh_json(*args):
    return json.loads(subprocess.run(["gh", *args], capture_output=True, text=True, timeout=120, check=True).stdout)


def fetch(limit):
    """The last `limit` merged PRs. One list call, then one view per PR for its commits: asking the list for
    commits and their authors together passes GitHub's GraphQL node limit above ~50 PRs."""
    prs = gh_json("pr", "list", "--state", "merged", "--limit", str(limit), "--json", "number,title,body")
    for pr in prs:
        try:
            pr["commits"] = gh_json("pr", "view", str(pr["number"]), "--json", "commits")["commits"]
        except (ValueError, KeyError, subprocess.SubprocessError):
            pr["commits"] = []  # counted as skipped:no_commits
    return prs


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--prs")
    ap.add_argument("--limit", type=int, default=100)
    ap.add_argument("--mirror", default=default_mirror())
    ap.add_argument("--ledger")
    ap.add_argument("--min-n", type=int, default=50)
    ap.add_argument("--record", action="store_true")
    a = ap.parse_args(argv)
    try:
        if a.prs:
            with open(a.prs, encoding="utf-8") as fh:
                prs = json.load(fh)
        else:
            prs = fetch(a.limit)
    except (OSError, ValueError, subprocess.SubprocessError) as e:
        sys.stderr.write("pdd_share: cannot read the merged PRs (%s)\n" % type(e).__name__)
        return 1
    if not isinstance(prs, list):
        sys.stderr.write("pdd_share: the PR list is not a JSON array\n")
        return 1
    row = build(prs, a.mirror, a.min_n)
    if not row["metrics"]:
        sys.stderr.write("pdd_share: no readable PR in %d (mirror %s)\n" % (len(prs), a.mirror))
        return 1
    if a.record:
        eval_runs.append_row(row, eval_runs.ledger_path(a.ledger))
    else:
        print(json.dumps(row, indent=1, sort_keys=True))
    return 0 if row["status"] == "ok" else 3


if __name__ == "__main__":
    sys.exit(main())
