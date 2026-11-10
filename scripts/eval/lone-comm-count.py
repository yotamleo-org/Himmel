#!/usr/bin/env python3
"""scripts/eval/lone-comm-count.py - report-only count of lone comm calls per session.

Read-only, deterministic, no model call. Only tool names and tool inputs are read; no hook, no gate.

  lone-comm-count.py SESSION.jsonl [SESSION.jsonl ...]
  lone-comm-count.py --dir DIR [--hours N]        (default 24; DIR is searched recursively)

A turn is one assistant message id (its records are merged; <synthetic> is skipped). A turn is LONE when its
tool calls are exactly one comm tool and nothing else: an append-results.sh Bash bullet, a SendMessage with a
message, an himmel-bus send (the MCP tool or `bus send`). Each lone turn takes its `marker()` class; the SAFETY classes (GO, NO-GO, token-quoting rulings, SUCCESSION
quote-backs, RETASK/REDIRECT/EXPANSION/HALT) are counted apart and are never batchable.
With --dir, only turns whose timestamp is inside the window count, and only files modified inside it are read;
file arguments count every record.

Output: a TSV (session, turns, lone_batchable, bullet, message, bus, lone_safety) with its header, one
`CLASS<TAB><marker><TAB>batchable|safety<TAB><n>` row per class, and one `TOTAL ...` line.

ponytail: marker classes are the audit's regexes, so a LIVE bullet whose first 400 chars say "new chief" counts
as SUCCESSION (safety); that undercounts batchable. Upgrade path = hand-label a sample.

Exit: 0 ok, 2 usage error or no session files.
"""

import argparse
import collections
import json
import os
import re
import shlex
import sys
import time

MARK = (r'(READY|FINDING|BLOCKED|JUDGE-REQUEST|LIVE|WRAPPED|MERGED|RESOLVED|CONSULT|MAIN-RED|ORPHAN|ACK|HALTED|'
        r'CHECKPOINT|PARKED-USAGE|RESUMED|NO-GO|GO|RELAYED|HALT|WRAP|RETASK|REDIRECT|EXPANSION)')
MARK_RE = re.compile(r'^[\s\-*#>`|]*(?:\d\d:\d\d\s*)?' + MARK + r'\b')
MARK_ANY_RE = re.compile(r'(?<![\w-])(READY|FINDING|BLOCKED|JUDGE-REQUEST|WRAPPED|MERGED|RESOLVED|CONSULT|MAIN-RED|'
                         r'ORPHAN|HALTED|RETASK|REDIRECT|EXPANSION|HALT)(?![\w-])')
SUCC_RE = re.compile(r'SUCCESSION|succession relay|your chief is now|chief is now|replaces .{0,80}chief|new chief', re.I)
GO_RE = re.compile(r'\bGO\s+(?:PR\s*)?#?\d{3,5}\b|\bGO file\b|\.go\b')
NOGO_RE = re.compile(r'\bNO-GO\b')
TOKEN_RE = re.compile(r'\b[A-Z]{1,3}-N\d+[a-z]?-[0-9a-f]{8}\b')
NUDGE_RE = re.compile(r'\b(nudge|still alive|are you|status\?|heartbeat|no bullet|no LIVE|please report)\b', re.I)

PUNCT = set(';&|<>()')
SAFETY = {'GO', 'NO-GO', 'token-quoting', 'SUCCESSION', 'RETASK', 'REDIRECT', 'EXPANSION', 'HALT'}


def marker(body):
    h = (body or '')[:400]
    if SUCC_RE.search(h):
        return 'SUCCESSION'
    m = MARK_RE.match(h)
    if m:
        return m.group(1)
    if NOGO_RE.search(h[:160]):
        return 'NO-GO'
    if GO_RE.search(h[:160]):
        return 'GO'
    m = MARK_ANY_RE.search(h[:200])
    if m:
        return m.group(1)
    if TOKEN_RE.search((body or '')[:2000]):
        return 'token-quoting'
    if NUDGE_RE.search(h[:200]):
        return 'nudge'
    return 'prose'


def classify(body):
    """The marker class, except that a safety signal anywhere in the text wins over a leading marker."""
    head = (body or '')[:400]
    if SUCC_RE.search(head):
        return 'SUCCESSION'
    if NOGO_RE.search(head[:160]):
        return 'NO-GO'
    if GO_RE.search(head[:160]):
        return 'GO'
    if TOKEN_RE.search((body or '')[:2000]):
        return 'token-quoting'
    return marker(body)


def simple_command(cmd):
    """The argv of a Bash command that is one plain command, or None (chained, piped, or not parseable)."""
    lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    lex.commenters = ''
    try:
        toks = list(lex)
    except ValueError:
        return None
    if toks and toks[0] == 'bash':
        toks = toks[1:]
    if not toks or any(set(t) <= PUNCT for t in toks):
        return None
    return toks


def comm(name, inp):
    """(kind, text) when this tool use is a comm act, else None."""
    i = inp if isinstance(inp, dict) else {}
    if name == 'SendMessage':
        msg = i.get('message')
        if isinstance(msg, str) and msg:
            return 'message', msg
        return None
    if name == 'mcp__himmel-bus__send':
        return 'bus', str(i.get('b') or '')
    if name == 'Bash':
        toks = simple_command(i.get('command') or '')
        if not toks:
            return None
        if toks[0].endswith('append-results.sh') and len(toks) == 3:
            return 'bullet', toks[2].lstrip('$')
        if os.path.basename(toks[0]) == 'bus' and toks[1:2] == ['send']:
            return 'bus', ' '.join(toks[2:])
    return None


def count_file(path, since):
    """-> (turns, Counter of (kind, marker, safety?)) for one session file."""
    turns = {}
    try:
        fh = open(path, errors='replace')
    except OSError:
        return 0, collections.Counter()
    with fh:
        for line in fh:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if not isinstance(d, dict) or d.get('type') != 'assistant':
                continue
            m = d.get('message') or {}
            mid = m.get('id')
            if not mid or m.get('model') == '<synthetic>':
                continue
            if since and (d.get('timestamp') or '')[:19] < since:
                continue
            tools = turns.setdefault(mid, {})
            for b in m.get('content') or []:
                if isinstance(b, dict) and b.get('type') == 'tool_use':
                    tools[b.get('id') or len(tools)] = (b.get('name'), b.get('input'))
    rows = collections.Counter()
    for tools in turns.values():
        if len(tools) != 1:
            continue
        (name, inp), = tools.values()
        c = comm(name, inp)
        if c:
            mk = classify(c[1])
            rows[(c[0], mk, mk in SAFETY)] += 1
    return len(turns), rows


def main():
    ap = argparse.ArgumentParser(description='count lone comm calls per session (report-only)')
    ap.add_argument('files', nargs='*')
    ap.add_argument('--dir')
    ap.add_argument('--hours', type=float, default=24)
    a = ap.parse_args()
    files, since = list(a.files), ''
    if a.dir:
        cutoff = time.time() - a.hours * 3600
        since = time.strftime('%Y-%m-%dT%H:%M:%S', time.gmtime(cutoff))
        for root, _, names in os.walk(os.path.expanduser(a.dir)):
            for n in names:
                p = os.path.join(root, n)
                try:
                    if n.endswith('.jsonl') and os.path.getmtime(p) >= cutoff:
                        files.append(p)
                except OSError:
                    pass
    if not files:
        print('lone-comm-count: no session files', file=sys.stderr)
        return 2
    out, classes = [], collections.Counter()
    for p in sorted(files):
        turns, rows = count_file(p, since)
        if not turns:
            continue
        kinds = collections.Counter()
        safe = 0
        for (kind, mk, is_safe), n in rows.items():
            if is_safe:
                safe += n
                classes[(mk, 'safety')] += n
            else:
                kinds[kind] += n
                classes[(mk, 'batchable')] += n
        out.append((os.path.basename(p)[:-6] if p.endswith('.jsonl') else os.path.basename(p), turns,
                    kinds['bullet'] + kinds['message'] + kinds['bus'], kinds['bullet'], kinds['message'],
                    kinds['bus'], safe))
    out.sort(key=lambda r: (-r[2], r[0]))
    print('session\tturns\tlone_batchable\tbullet\tmessage\tbus\tlone_safety')
    for r in out:
        print('\t'.join(str(x) for x in r))
    for (mk, cls), n in sorted(classes.items(), key=lambda kv: (-kv[1], kv[0])):
        print(f'CLASS\t{mk}\t{cls}\t{n}')
    t = [sum(r[i] for r in out) for i in range(1, 7)]
    print(f'TOTAL sessions={len(out)} turns={t[0]} lone_batchable={t[1]} bullet={t[2]} message={t[3]} bus={t[4]} '
          f'lone_safety={t[5]}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
