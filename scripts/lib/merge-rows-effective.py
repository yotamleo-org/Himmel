#!/usr/bin/env python3
"""The status-events log with every unproven pre-merge row left out.

merge-on-green.sh writes a merge row (event=merge, result=pending, stage=pre-merge) BEFORE it calls the
merge, so a run killed right after GitHub merges still leaves the record. The same row also stays behind
when the PR never merged. A reader of the merge rows therefore reads this filter's output, not the raw log:

  - a pre-merge row followed by a result=not-merged row of the same pr and head is dropped (the run said so);
  - a pre-merge row followed by any other merge row of the same pr and head is kept (that row is written only
    once GitHub reported the PR MERGED; a stage=pre-merge row of a retry does not count);
  - a pre-merge row with nothing after it is kept only when GitHub says the PR is MERGED at that head. A PR
    that is open, closed, or unreadable is not a merge: the row is dropped.

Every other line, parseable or not, passes through unchanged and in order. The rows carry no repository, so the
GitHub read resolves the PR in the current directory's repository; MERGE_ROWS_GH replaces `gh` (the test seam).
Usage: merge-rows-effective.py [<status-events.jsonl>]   (stdin when no file)
"""
import json
import os
import shlex
import subprocess
import sys


def is_merge(r):
    return isinstance(r, dict) and r.get('event') == 'merge'


def is_pre_merge(r):
    return is_merge(r) and r.get('stage') == 'pre-merge' and r.get('result') == 'pending'


def merged_on_github(pr, head, cache):
    if (pr, head) in cache:
        return cache[(pr, head)]
    ok = False
    try:
        cmd = shlex.split(os.environ.get('MERGE_ROWS_GH') or 'gh') + [
            'pr', 'view', pr, '--json', 'state,headRefOid', '--jq', '"\\(.state) \\(.headRefOid)"']
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
        if out.returncode == 0:
            parts = out.stdout.split()
            ok = len(parts) == 2 and parts[0] == 'MERGED' and (not head or parts[1] == head)
        else:
            print('merge-rows-effective: warn: PR %s unreadable on GitHub; its pre-merge row is not counted' % pr, file=sys.stderr)
    except (OSError, subprocess.SubprocessError):
        print('merge-rows-effective: warn: PR %s unreadable on GitHub; its pre-merge row is not counted' % pr, file=sys.stderr)
    cache[(pr, head)] = ok
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
            pr, head = str(r.get('pr', '')), str(r.get('head', ''))
            later = next((x for x in rows[i + 1:] if is_merge(x) and not is_pre_merge(x)
                          and str(x.get('pr', '')) == pr and str(x.get('head', '')) == head), None)
            if later is not None:
                keep = later.get('result') != 'not-merged'
            else:
                keep = merged_on_github(pr, head, cache) if pr.isdigit() else False
            if not keep:
                continue
        out.append(lines[i])
    sys.stdout.write(''.join(ln + '\n' for ln in out))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
