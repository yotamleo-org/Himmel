#!/usr/bin/env python3
"""Tag an Important finding on code older than the PR.

Reads the panel's merged findings on stdin, writes them on stdout, and runs at
rounds 2 and 3 only: at any other round the text passes through unchanged and
nothing is written to the ledger.

For each Important bullet cited as [file:line], git blame places that line at
HEAD. If the blamed commit is an ancestor of the diff base, the line predates
the PR: the bullet gets the tag [pre-existing] and an amend row sets the ledger
field pre_existing=true. `review-round.sh defer` reads that field, never the
bullet's text. If the blamed commit belongs to an earlier round of the PR (an
ancestor of --from, the last round's head), the line is outside this round's
delta and the bullet gets the informational tag [outside-delta], with no amend.
Anything else is left as it is.

A line's age says when it was written, not whether this round's change broke
it. So a line the critic was shown is never tagged: it is never tagged when it
sits inside any hunk of the reviewed diff (--from..HEAD, else the base...HEAD
diff), its context lines (the repository's own diff context, as the critic's
plain git diff reads it) and the neighbours of a deletion-only hunk included. When git cannot say what the diff showed, nothing is tagged.

Never tagged: a Critical (it always blocks), a Suggestion, a [context] finding
(cited outside the reviewed diff on purpose: the critic claims the change
breaks that line), or a citation that is not [file:line]. A tag the model wrote
itself is stripped from every bullet: the tags are ours alone. If the amend is
refused, the bullet stays untagged and keeps blocking.

git does the parsing: `git blame --porcelain -L n,n` has a fixed shape for one
requested line and only the `@@` header lines of `git diff` are read, so no
diff text and no shell text is interpreted.

Usage: critic-pre-existing-tag.py --round N --head SHA --db-sha SHA --branch B
           [--from SHA] [--ledger-append PATH] < findings > tagged
"""
import argparse
import os
import re
import subprocess
import sys

SECTION = re.compile(r"^## (Critical Issues|Important Issues|Suggestions) \(\d+ found\)\s*$")
BULLET = re.compile(r"^- \[([^\[\]]+)\]: ")
CITE = re.compile(r"\[([^\[\]]+):(\d+)\]\s*$")
OWN_TAGS = re.compile(r"(?:\[(?:pre-existing|outside-delta)\]\s*)+$")
CONTEXT = re.compile(r"\[context\]\s*$")
FULL_SHA = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")
AMEND_REASON = "critic-pre-existing-tag.py: git blame places the cited line before the PR"


# The variables that point git at another repository are dropped for every child
# (git and ledger-append.sh), so the caller's environment cannot redirect them.
# git-env-ok: CHILD_ENV drops the repository-redirecting GIT_* variables for every child process
SCRUB = ("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY",
         "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_PREFIX", "GIT_IMPLICIT_WORK_TREE", "GIT_GRAFT_FILE",
         "GIT_REPLACE_REF_BASE", "GIT_SHALLOW_FILE", "GIT_CONFIG", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT")
CHILD_ENV = {k: v for k, v in os.environ.items() if k not in SCRUB}


def run(cmd):
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                          errors="surrogateescape", check=False, env=CHILD_ENV)


def blame(head, path, line):
    """The commit git blame gives one line at head, or None."""
    r = run(["git", "blame", "--porcelain", "-L", "%d,%d" % (line, line), head, "--", path])
    if r.returncode != 0:
        return None
    sha = r.stdout.split("\n", 1)[0].split(" ", 1)[0]
    return sha if FULL_SHA.match(sha) else None


def is_ancestor(commit, other):
    return run(["git", "merge-base", "--is-ancestor", commit, other]).returncode == 0


HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")
_shown = {}


def outside_shown_diff(args, path, line):
    """True only when git says the reviewed diff did not show this line.

    The reviewed diff is --from..HEAD when there is a start point, else the
    base...HEAD diff, read with the repository's own context setting, like the
    critic's. Any
    hunk range on the new side counts as shown, context lines included; a hunk
    with no new-side lines (a deletion at the very edge) shows the line beside
    it. If git fails, the line counts as shown, so nothing is tagged.
    """
    if path not in _shown:
        spec = "%s..%s" % (args.from_sha, args.head) if args.from_sha else "%s...%s" % (args.db_sha, args.head)
        r = run(["git", "--literal-pathspecs", "diff", "--no-color", "--no-ext-diff", "--no-renames",
                 spec, "--", path])
        ranges = None
        if r.returncode == 0:
            ranges = []
            for row in r.stdout.split("\n"):
                m = HUNK.match(row)
                if m:
                    start, count = int(m.group(1)), int(m.group(2) if m.group(2) is not None else 1)
                    ranges.append((start, start + count - 1 if count else start + 1))
        _shown[path] = ranges
    ranges = _shown[path]
    return ranges is not None and not any(a <= line <= b for a, b in ranges)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("--round", required=True, type=int)
    ap.add_argument("--head", required=True)
    ap.add_argument("--db-sha", required=True)
    ap.add_argument("--branch", required=True)
    ap.add_argument("--from", dest="from_sha", default="")
    ap.add_argument("--ledger-append", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "ledger-append.sh"))
    args = ap.parse_args()

    text = sys.stdin.buffer.read().decode("utf-8", "surrogateescape")
    if args.round not in (2, 3):
        sys.stdout.buffer.write(text.encode("utf-8", "surrogateescape"))
        return 0

    out = []
    section = None
    for line in text.split("\n"):
        m = SECTION.match(line)
        if m:
            section = m.group(1)
            out.append(line)
            continue
        if line.startswith("## "):
            section = None
        b = BULLET.match(line)
        c = CITE.search(line) if b else None
        if not (b and c):
            out.append(line)
            continue
        cite = line[c.start():]
        body = line[:c.start()].rstrip()
        stripped = OWN_TAGS.sub("", body).rstrip()
        if stripped != body:
            body = stripped
            line = body + " " + cite
        if section == "Important Issues" and not CONTEXT.search(body):
            path, n = c.group(1), int(c.group(2))
            commit = blame(args.head, path, n) if n > 0 and outside_shown_diff(args, path, n) else None
            if commit and is_ancestor(commit, args.db_sha):
                r = subprocess.run(["bash", args.ledger_append, "amend", "--branch", args.branch, "--head", args.head,
                                    "--id", b.group(1), "--set", "pre_existing=true", "--reason", AMEND_REASON],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False, env=CHILD_ENV)
                if r.returncode == 0:
                    line = body + " [pre-existing] " + cite
                else:
                    sys.stderr.write("critic-pre-existing-tag: the ledger refused the pre_existing amend for %s (rc=%d); "
                                     "the finding stays untagged\n" % (b.group(1), r.returncode))
            elif commit and args.from_sha and is_ancestor(commit, args.from_sha):
                line = body + " [outside-delta] " + cite
        out.append(line)
    sys.stdout.buffer.write("\n".join(out).encode("utf-8", "surrogateescape"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
