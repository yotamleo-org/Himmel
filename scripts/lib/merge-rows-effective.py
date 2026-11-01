#!/usr/bin/env python3
"""The status-events log with every unproven pre-merge row left out.

merge-on-green.sh writes a merge row (event=merge, result=pending, stage=pre-merge) BEFORE it calls the
merge, so a run killed right after GitHub merges still leaves the record. The same row also stays behind
when the PR never merged. A reader of the merge rows therefore reads this filter's output, not the raw log:

  - a pre-merge row followed by a result=not-merged row of the same key, pr and head is dropped (the run said so);
  - a pre-merge row followed by any other merge row of the same key, pr and head is kept (that row is written only
    once GitHub reported the PR MERGED; a stage=pre-merge row of a retry does not count);
  - a pre-merge row with nothing after it is kept only when GitHub says the PR is MERGED at that head. A PR
    that is open, closed, or unreadable is not a merge: the row is dropped.

Every other line, parseable or not, passes through unchanged and in order. The GitHub read names the row's repo
(--repo) when the row carries one, else resolves the PR in the current directory's repository; all reads of one
run share a 45 s budget. MERGE_ROWS_GH replaces `gh` (the test seam).
Usage: merge-rows-effective.py [<status-events.jsonl>]   (stdin when no file)
"""
import json
import os
import shlex
import re
import subprocess
import sys
import time


def is_merge(r):
    return isinstance(r, dict) and r.get('event') == 'merge'


def is_pre_merge(r):
    return is_merge(r) and r.get('stage') == 'pre-merge' and r.get('result') == 'pending'


REPO_RE = re.compile(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')
BUDGET_SECS = float(os.environ.get('MERGE_ROWS_BUDGET_SECS') or 45)  # all GitHub reads of one run together; a row left unasked past it is not counted
DEADLINE = time.monotonic() + BUDGET_SECS


def merged_on_github(pr, head, repo, cache):
    if (pr, head, repo) in cache:
        return cache[(pr, head, repo)]
    ok = False
    left = DEADLINE - time.monotonic()
    if left <= 0:
        print('merge-rows-effective: warn: GitHub read budget spent; PR %s is not counted' % pr, file=sys.stderr)
        cache[(pr, head, repo)] = ok
        return ok
    try:
        cmd = shlex.split(os.environ.get('MERGE_ROWS_GH') or 'gh') + [
            'pr', 'view', pr, '--json', 'state,headRefOid', '--jq', '"\\(.state) \\(.headRefOid)"']
        if REPO_RE.match(repo):
            cmd += ['--repo', repo]
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=min(20, left))
        if out.returncode == 0:
            parts = out.stdout.split()
            ok = len(parts) == 2 and parts[0] == 'MERGED' and (not head or parts[1] == head)
        else:
            print('merge-rows-effective: warn: PR %s unreadable on GitHub; its pre-merge row is not counted' % pr, file=sys.stderr)
    except (OSError, subprocess.SubprocessError):
        print('merge-rows-effective: warn: PR %s unreadable on GitHub; its pre-merge row is not counted' % pr, file=sys.stderr)
    cache[(pr, head, repo)] = ok
    return ok


def main(argv):
    if len(argv) > 2:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        text = open(argv[1]).read() if len(argv) == 2 else sys.stdin.read()
    except OSError as e:
        print('merge-rows-effective: %s' % (e.strerror or e), file=sys.stderr)
        return 1
    lines = text.splitlines()
    rows = []
    for ln in lines:
        try:
            rows.append(json.loads(ln))
        except ValueError:
            rows.append(None)
    cache = {}
    out = []
    for i, r in enumerate(rows):
        if is_pre_merge(r):
            key, pr, head, repo = (str(r.get(f, '')) for f in ('key', 'pr', 'head', 'repo'))
            later = next((x for x in rows[i + 1:] if is_merge(x) and not is_pre_merge(x) and str(x.get('key', '')) == key
                          and str(x.get('pr', '')) == pr and str(x.get('head', '')) == head), None)
            if later is not None:
                keep = later.get('result') != 'not-merged'
            else:
                keep = merged_on_github(pr, head, repo, cache) if pr.isdigit() else False
            if not keep:
                continue
        out.append(lines[i])
    sys.stdout.write(''.join(ln + '\n' for ln in out))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
