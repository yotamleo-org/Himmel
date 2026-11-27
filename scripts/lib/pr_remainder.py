#!/usr/bin/env python3
"""The ONE reader of a partial-merge PR's remainder.

next-dispatchable.sh, merge-on-green.sh (both run this file as a script) and gen-briefs.py's Already merged block
(imports it) all call it, so the three never disagree about what a PR body leaves undone. merge-on-green.sh runs it from
the anchor's scripts/lib, never from the branch under review: the answer decides a merge.

A remainder is a `Remaining:` line, or a `deferred -> <KEY>` line under `## Ticket coverage` (the form ready-check.sh makes
workers write; `->` and the arrow are both read). A deferred line hands its work to another ticket only in ready-check.sh's
own grammar: the key comes right after the arrow and nothing but punctuation follows it. Any other deferred line stays
remaining work on the ticket.

CLI: `pr_remainder.py [--units] KEY[,KEY...]` with the PR body on stdin prints ONE answer line:
  none
  remaining<TAB>text
  handed-off<TAB>KEY, KEY<TAB>text
  owed<TAB>who<TAB>YYYY-MM-DD<TAB>text
The own keys are the ticket's own: a deferred line naming one is not a hand-off. Exit 0 with the line; any other exit is no answer.
With --units every kind carries two more fields, `nowrite=<0|1>` and `chief-owed=<text¦text>` (pr_remainder_units).
With --full-units it prints one UTF-8 JSON line instead, `{"schema": 1, "answer": {...}}`, the answer holding exactly the
FULL_FIELDS of pr_remainder_units (each owed_lines row exactly OWED_FIELDS): next-dispatchable.sh reads every unit from it.
An owed line owed to chief or operator is selected before any proof line; the earliest date wins within that pool.
"""
import datetime
import json
import re
import sys

ANSWER_KINDS = ('none', 'remaining', 'handed-off', 'owed')
OWED_ACTORS = ('chief', 'operator', 'proof')
FULL_FIELDS = ('kind', 'handed', 'text', 'nowrite', 'chief_owed', 'chief_invalid', 'owed_lines')
OWED_FIELDS = ('who', 'due', 'text', 'ask')

REMAINING_RE = re.compile(r'^[ \t]*remaining:[ \t]*(.*\S)', re.I | re.M)
HEADING_RE = re.compile(r'^(#{1,6})(?:[ \t]+\S|[ \t]*$)')
COVERAGE_HEAD_RE = re.compile(r'^#{2}[ \t]+ticket coverage[ \t]*$', re.I)
DEFERRED_RE = re.compile(r'\bdeferred[ \t]*(?:→|->)', re.I)
# ready-check.sh check 7: the key follows the arrow and ends the line, up to punctuation
HANDOFF_RE = re.compile(r'\bdeferred[ \t]*(?:→|->)[^A-Za-z0-9]*([A-Za-z][A-Za-z0-9]*-[0-9]+)[^A-Za-z0-9]*$', re.I)
LIST_RE = re.compile(r'^(?:[-*+]|[0-9]+[.)])[ \t]')
MARK_RE = re.compile(r'^(?:[-*+]|[0-9]+[.)])[ \t]+')  # the same marker grammar as LIST_RE, stripped once
OWED_ANY_RE =re.compile(r'\bowed[ \t]*(?:→|->)', re.I)
OWED_RE = re.compile(r'\bowed[ \t]*(?:→|->)[ \t]*(' + '|'.join(OWED_ACTORS) + r')[ \t]+by[ \t]+(\d{4}-\d{2}-\d{2})[^A-Za-z0-9]*$', re.I)
CHIEF_ONLY_RE = re.compile(r'^(?:sign (?:the |a )?(?:spec|GO|release)|(?:chief )?signature|release operator step|station step (?:a |the )?worker is refused)[ .:;-]*$', re.I)
NO_WRITE_RE = re.compile(r'(?<![\w-])no (?:code(?! path)|repo(?:sitory)? (?:write|change|edit)s?)\b|(?<![\w-])chief-run\b|\bstate repo\b', re.I)
SLICE_LABEL_RE = re.compile(r'[ \t]*S\d+[A-Za-z]?\b')


def slices(line):
    out, depth, start = [], 0, 0
    for n, c in enumerate(line):
        if c == '(':
            depth += 1
        elif c == ')':
            depth = max(0, depth - 1)
        elif c in ',;' and depth == 0 and SLICE_LABEL_RE.match(line, n + 1):
            out.append(line[start:n])
            start = n + 1
    out.append(line[start:])
    return [s.strip() for s in out if s.strip()]


def pr_remainder(body, own_keys=()):
    a = pr_remainder_units(body, own_keys)
    return (a['kind'], a['handed'], a['text'])


def pr_remainder_units(body, own_keys=()):
    """pr_remainder's answer as a dict ('kind', 'handed', 'text'), plus:
      'nowrite'     at least one work unit, and every one matches NO_WRITE_RE; a work unit is a slice of a `Remaining:`
                    line, a deferred line that stays on this ticket, or a malformed owed line
      'chief_owed'  the text of every valid owed line whose who is chief, in body order
    pr_remainder's (kind, handed_keys, text):
      ('none', [], '')                no remainder recorded in either form
      ('remaining', [], text)         the remainder stays on the ticket
      ('handed-off', [keys], text)    no Remaining: line, and every deferred line names one other ticket
      ('owed', [who, date], text)     no Remaining: line, and an owed line beats a hand-off: the earliest chief or
                                      operator line, else the earliest proof line"""
    body = body.replace('\r', '')
    own = {k.upper() for k in own_keys}
    remaining = [m.strip() for m in REMAINING_RE.findall(body)]
    deferred, handed, whole = [], [], True
    staying = []
    owed, owed_bad = [], []
    in_coverage = False
    owed_open = False
    for raw in body.splitlines():
        line = raw.strip()
        heading = HEADING_RE.match(line)
        if raw.startswith('#'):
            owed_open = False
        if heading:
            # the coverage section runs to the next heading of level two or higher; a `###` inside it stays in scope
            if COVERAGE_HEAD_RE.match(line):
                in_coverage = owed_open = True
            elif len(heading.group(1)) <= 2:
                in_coverage = False
            continue
        if not in_coverage:
            continue
        if not DEFERRED_RE.search(line) and OWED_ANY_RE.search(line):
            text = MARK_RE.sub('', line, count=1)
            m = OWED_RE.search(line)
            try:
                if not (owed_open and LIST_RE.match(line)):
                    raise ValueError('not a list line before the first heading')
                if not m:
                    raise ValueError('not the owed grammar')
                datetime.date.fromisoformat(m.group(2))
                owed.append((m.group(2), m.group(1).lower(), re.sub(r'[\t\r\n]+', ' ', text)))
            except ValueError:
                owed_bad.append(text)
            continue
        if not DEFERRED_RE.search(line):
            continue
        deferred.append(MARK_RE.sub('', line, count=1))
        m = HANDOFF_RE.search(line)
        key = m.group(1).upper() if m else None
        if key is None or key in own:
            whole = False
            staying.append(deferred[-1])
        elif key not in handed:
            handed.append(key)
    units = [s for r in remaining for s in slices(r)] + staying + owed_bad
    chief = [re.sub(r'[\t\r\n]+', ' ', t) for _, who, t in owed if who == 'chief']
    nonproof = [o for o in owed if o[1] != 'proof']
    extra = {'nowrite': (bool(units) and all(NO_WRITE_RE.search(u) for u in units)) or
                        (not units and bool(owed) and not nonproof),
             'chief_owed': chief,
             'chief_invalid': [t for t in chief if not CHIEF_ONLY_RE.search(OWED_RE.sub('', t))],
             'owed_lines': [{'who': who, 'due': due, 'text': text,
                             'ask': OWED_RE.sub('', text).rstrip(' \t:')} for due, who, text in owed]}
    if not remaining and not deferred and not owed and not owed_bad:
        return dict(kind='none', handed=[], text='', **extra)
    if not remaining and not owed_bad and whole and owed:  # a deferred line that stays on this ticket is remaining work, and beats an owed step
        due, who, line = min(nonproof or owed, key=lambda o: o[0])  # min keeps the first of equal dates
        return dict(kind='owed', handed=[who, due], text=re.sub(r'[\t\r\n]+', ' ', line), **extra)
    text = re.sub(r'[\t\r\n]+', ' ', '; '.join(p for p in (' '.join(remaining), '; '.join(deferred + owed_bad + [o[2] for o in owed])) if p))  # the answer line is tab-separated
    if not remaining and not owed_bad and whole:
        return dict(kind='handed-off', handed=handed, text=text, **extra)
    return dict(kind='remaining', handed=[], text=text, **extra)


DONE_ITEM_RE = re.compile(r':[ \t]*done[ \t.]*$', re.I)


def _blocks(body):
    """[in_coverage, is_list_item, text] for every list item and paragraph, its continuation lines joined"""
    out, cur, in_coverage = [], None, False
    for raw in body.replace('\r', '').splitlines():
        line = raw.strip()
        heading = HEADING_RE.match(line)
        if heading or not line:
            cur = None
            if heading and COVERAGE_HEAD_RE.match(line):
                in_coverage = True
            elif heading and len(heading.group(1)) <= 2:
                in_coverage = False
            continue
        item = bool(LIST_RE.match(line))
        if cur is None or item or REMAINING_RE.match(line):
            cur = [in_coverage, item, line]
            out.append(cur)
        else:
            cur[2] += ' ' + line
    return out


def coverage_done(body, key):
    """True when at least one ## Ticket coverage item names `key`, every such item ends `: done`, and no `Remaining:`,
    deferred or owed text in the body names it."""
    named = re.compile(r'(?<![\w-])' + re.escape(key) + r'(?![\w-])')
    done = False
    for in_coverage, item, text in _blocks(body):
        if not named.search(text):
            continue
        if REMAINING_RE.match(text) or DEFERRED_RE.search(text) or OWED_ANY_RE.search(text):
            return False
        if in_coverage and item:
            if not DONE_ITEM_RE.search(text):
                return False
            done = True
    return done


def live_answers(answers):
    """The live answers of a ticket's partial PRs, given in merge order: a clear answer (any kind but none) supersedes every
    older PR that records none, and a PR newer than it that records none is still a question. A newer hand-off or owed
    step also supersedes an older `remaining` answer."""
    clear = max((n for n, a in enumerate(answers) if a['kind'] != 'none'), default=-1)
    handed = clear >= 0 and answers[clear]['kind'] in ('handed-off', 'owed')
    return [a for n, a in enumerate(answers) if n >= clear or (a['kind'] != 'none' and not (handed and a['kind'] == 'remaining'))]


def main(argv):
    if argv[1:2] in (['--owed-lines'], ['--chief-invalid']):
        a = pr_remainder_units(sys.stdin.buffer.read().decode('utf-8', 'replace'), argv[2:])
        if argv[1] == '--chief-invalid':
            for text in a['chief_invalid']:
                print('chief-only step required; use owed → proof or Remaining: for code\t' + text)
        else:
            for line in a['owed_lines']:
                print('\t'.join(line[f] for f in ('who', 'due', 'ask', 'text')))
        return 0
    units = argv[1:2] in (['--units'], ['--full-units'])
    if len(argv) != 2 + units:
        print('usage: pr_remainder.py [--units|--full-units] KEY[,KEY...]  (PR body on stdin)', file=sys.stderr)
        return 2
    body = sys.stdin.buffer.read().decode('utf-8', 'replace')
    a = pr_remainder_units(body, [k for k in argv[-1].split(',') if k])
    if argv[1] == '--full-units':
        sys.stdout.buffer.write((json.dumps({'schema': 1, 'answer': {f: a[f] for f in FULL_FIELDS}}, ensure_ascii=False) + '\n').encode('utf-8'))
        return 0
    kind, handed, text = a['kind'], a['handed'], a['text']
    out = kind if kind == 'none' else '\t'.join([kind] + ([', '.join(handed)] if kind == 'handed-off' else handed if kind == 'owed' else []) + [text])
    if units:
        out += '\tnowrite=%d\tchief-owed=%s' % (a['nowrite'], '¦'.join(a['chief_owed']))
    sys.stdout.buffer.write((out + '\n').encode('utf-8'))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
