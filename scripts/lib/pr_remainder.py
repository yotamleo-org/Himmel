#!/usr/bin/env python3
"""The ONE reader of a partial-merge PR's remainder.

next-dispatchable.sh, merge-on-green.sh (both run this file as a script) and gen-briefs.py's Already merged block
(imports it) all call it, so the three never disagree about what a PR body leaves undone. merge-on-green.sh runs it from
the anchor's scripts/lib, never from the branch under review: the answer decides a merge.

A remainder is a `Remaining:` line, or a `deferred -> <KEY>` line under `## Ticket coverage` (the form ready-check.sh makes
workers write; `->` and the arrow are both read). A deferred line hands its work to another ticket only in ready-check.sh's
own grammar: the key comes right after the arrow and nothing but punctuation follows it. Any other deferred line stays
remaining work on the ticket.

CLI: `pr_remainder.py KEY[,KEY...]` with the PR body on stdin prints ONE answer line:
  none
  remaining<TAB>text
  handed-off<TAB>KEY, KEY<TAB>text
  owed<TAB>who<TAB>YYYY-MM-DD<TAB>text
The own keys are the ticket's own: a deferred line naming one is not a hand-off. Exit 0 with the line; any other exit is no answer.
"""
import datetime
import re
import sys

REMAINING_RE = re.compile(r'^[ \t]*remaining:[ \t]*(.*\S)', re.I | re.M)
HEADING_RE = re.compile(r'^(#{1,6})(?:[ \t]+\S|[ \t]*$)')
COVERAGE_HEAD_RE = re.compile(r'^#{2}[ \t]+ticket coverage[ \t]*$', re.I)
DEFERRED_RE = re.compile(r'\bdeferred[ \t]*(?:→|->)', re.I)
# ready-check.sh check 7: the key follows the arrow and ends the line, up to punctuation
HANDOFF_RE = re.compile(r'\bdeferred[ \t]*(?:→|->)[^A-Za-z0-9]*([A-Za-z][A-Za-z0-9]*-[0-9]+)[^A-Za-z0-9]*$', re.I)
OWED_ANY_RE = re.compile(r'\bowed[ \t]*(?:→|->)', re.I)
OWED_RE = re.compile(r'\bowed[ \t]*(?:→|->)[ \t]*(chief|operator)[ \t]+by[ \t]+(\d{4}-\d{2}-\d{2})[^A-Za-z0-9]*$', re.I)


def pr_remainder(body, own_keys=()):
    """Returns (kind, handed_keys, text):
      ('none', [], '')                no remainder recorded in either form
      ('remaining', [], text)         the remainder stays on the ticket
      ('handed-off', [keys], text)    no Remaining: line, and every deferred line names one other ticket
      ('owed', [who, date], text)     no Remaining: line, and an owed line (the earliest date) beats a hand-off"""
    own = {k.upper() for k in own_keys}
    remaining = [m.strip() for m in REMAINING_RE.findall(body)]
    deferred, handed, whole = [], [], True
    owed, owed_bad = [], []
    in_coverage = False
    for raw in body.splitlines():
        line = raw.strip()
        heading = HEADING_RE.match(line)
        if heading:
            # the coverage section runs to the next heading of level two or higher; a `###` inside it stays in scope
            if COVERAGE_HEAD_RE.match(line):
                in_coverage = True
            elif len(heading.group(1)) <= 2:
                in_coverage = False
            continue
        if not in_coverage:
            continue
        if not DEFERRED_RE.search(line) and OWED_ANY_RE.search(line):
            text = re.sub(r'^[-*+][ \t]+', '', line)
            m = OWED_RE.search(line)
            try:
                if not m:
                    raise ValueError('not the owed grammar')
                datetime.date.fromisoformat(m.group(2))
                owed.append((m.group(2), m.group(1).lower(), text))
            except ValueError:
                owed_bad.append(text)
            continue
        if not DEFERRED_RE.search(line):
            continue
        deferred.append(re.sub(r'^[-*+][ \t]+', '', line))
        m = HANDOFF_RE.search(line)
        key = m.group(1).upper() if m else None
        if key is None or key in own:
            whole = False
        elif key not in handed:
            handed.append(key)
    if not remaining and not deferred and not owed and not owed_bad:
        return ('none', [], '')
    if not remaining and not owed_bad and owed:
        due, who, line = min(owed, key=lambda o: o[0])  # min keeps the first of equal dates
        return ('owed', [who, due], re.sub(r'[\t\r\n]+', ' ', line))
    text = re.sub(r'[\t\r\n]+', ' ', '; '.join(p for p in (' '.join(remaining), '; '.join(deferred + owed_bad)) if p))  # the answer line is tab-separated
    if not remaining and not owed_bad and whole:
        return ('handed-off', handed, text)
    return ('remaining', [], text)


def main(argv):
    if len(argv) != 2:
        print('usage: pr_remainder.py KEY[,KEY...]  (PR body on stdin)', file=sys.stderr)
        return 2
    body = sys.stdin.buffer.read().decode('utf-8', 'replace')
    kind, handed, text = pr_remainder(body, [k for k in argv[1].split(',') if k])
    out = kind if kind == 'none' else '\t'.join([kind] + ([', '.join(handed)] if kind == 'handed-off' else handed if kind == 'owed' else []) + [text])
    sys.stdout.buffer.write((out + '\n').encode('utf-8'))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
