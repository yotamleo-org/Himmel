#!/usr/bin/env python3
"""chain-render.py (HIMMEL-7709, slice 3 of HIMMEL-7701): render focus-chains.json from the chain graph.

Behind the chain_render flag (scripts/lib/flags.tsv; off by default). Off: prints one line and writes nothing,
so a hand-kept focus-chains.json stays as it is. On: the file is overwritten from the graph, so a hand edit does
not survive a render.

USAGE
    chain-render.py --graph graph.json --chain "NAME=HIMMEL-1,HIMMEL-2,..." [--chain ...] --out focus-chains.json
        [--mirror DIR]

--graph is the output of `chain-graph.py --json`. Each --chain names a chain and lists its tickets. A step's
`wave` is its depth over the hard edges (H1, H2) among the chain's tickets: wave 0 has no open hard predecessor,
and every step of one wave can run at once. Soft edges (S1, S2) and independent pairs do not order anything. Steps
are listed by wave, then ticket number, which is the order tracker.py prints them in. The file is the
`[{name, steps: [{key, wave}]}]` shape of tracker.py --chains-file; a step carries no hand state, because the
tracker derives it from the Jira mirror on every render.

A ticket that is Done in the mirror (tracker.py's buckets 'done' and 'wont', which share SHIPPED with this file) is not a
step and does not hold its successors, so a closed ticket is never rendered as next. The tickets of a hard cycle share one wave after every step that is not stuck,
and whatever waits on them comes after; they are never dropped.
A ticket missing from the mirror stays a step (the tracker shows it unknown).

--mirror defaults to $NEXT_DISPATCH_MIRROR or ~/.himmel/state/jira-mirror/HIMMEL. Exit 0 rendered or flag off;
2 on an unreadable graph, mirror, bad arguments or a failed write (nothing is written).

The file is written through tempfile.mkstemp in the --out directory and os.replace, never a fixed <out>.tmp, so a path
planted beside it is not followed; the temp file takes the existing output's mode (0666 minus the umask when there is none); on an
OSError the temp file is removed and the exit is 2.
"""
import argparse
import json
import os
import re
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'lib'))
from flags import himmel_flag, FlagError  # noqa: E402

KEY_RE = re.compile(r'HIMMEL-(\d+)$')
HARD = ('H1', 'H2')
# tracker.py SHIPPED, the same set: a null, missing or empty resolution reads '' there and here
SHIPPED = ('', 'done', 'fixed')


def is_done(mirror, key):
    """'done' (shipped), 'wont' (closed with another resolution) or None (open, or not in the mirror)."""
    try:
        txt = open(os.path.join(mirror, key + '.md'), encoding='utf-8', errors='replace').read()
    except FileNotFoundError:
        return None  # not in the mirror: a step, the tracker shows it unknown
    fm = txt.split('---', 2)[1] if txt.count('---') >= 2 else ''
    f = dict(l.split(':', 1) for l in fm.splitlines() if ':' in l and not l.startswith(' '))
    if f.get('statusCategory', '').strip().strip('"') != 'Done':
        return None
    try:
        res = json.loads(f.get('resolution', 'null'))
    except ValueError:
        res = None
    return 'done' if (res if isinstance(res, str) else '').strip().lower() in SHIPPED else 'wont'


def waves(keys, edges):
    """{key: wave} over the hard edges among keys (an edge is (from, to))."""
    pred = {k: {a for a, b in edges if b == k and a != k} for k in keys}
    wave, left = {}, set(keys)
    while left:
        ready = {k for k in left if pred[k] <= set(wave)}
        if ready:
            for k in ready:
                wave[k] = 1 + max((wave[p] for p in pred[k]), default=-1)
            left -= ready
            continue
        # stuck: every step waits on another. The cycles with no predecessor outside themselves share the next wave
        # and their successors keep waiting on them.
        anc = {k: ancestors(k, pred, left) for k in left}
        core = {k for k in left if anc[k] and all(k in anc[j] for j in anc[k])}
        last = 1 + max(wave.values(), default=-1)
        for k in core:
            wave[k] = last
        left -= core
    return wave


def ancestors(k, pred, within):
    """Every step in `within` that k waits on, directly or through others."""
    seen, todo = set(), [k]
    while todo:
        for p in pred[todo.pop()] & within:
            if p not in seen:
                seen.add(p)
                todo.append(p)
    return seen


def render(graph, chains, mirror):
    key_of = {n['id']: n['key'] for n in graph['nodes'] if n.get('key')}
    hard = [(key_of[e['from']], key_of[e['to']]) for e in graph['edges']
            if e['kind'] in HARD and e['from'] in key_of and e['to'] in key_of]
    out = []
    for name, keys in chains:
        open_keys = [k for k in keys if not is_done(mirror, k)]
        w = waves(open_keys, [(a, b) for a, b in hard if a in open_keys and b in open_keys])
        order = sorted(open_keys, key=lambda k: (w[k], int(KEY_RE.match(k).group(1))))
        out.append({'name': name, 'steps': [{'key': k, 'wave': w[k]} for k in order]})
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--graph', required=True)
    ap.add_argument('--chain', action='append', required=True, metavar='NAME=KEY,KEY,...')
    ap.add_argument('--out', required=True)
    ap.add_argument('--mirror', default=os.environ.get('NEXT_DISPATCH_MIRROR')
                    or os.path.join(os.path.expanduser('~'), '.himmel', 'state', 'jira-mirror', 'HIMMEL'))
    a = ap.parse_args()
    try:
        if not himmel_flag('chain_render'):
            print('chain-render: chain_render is off; %s left as it is' % a.out)
            return 0
    except FlagError as e:
        print('chain-render: %s' % e, file=sys.stderr)
        return 2
    chains = []
    for c in a.chain:
        name, _, ks = c.partition('=')
        keys = [k.strip() for k in ks.split(',') if k.strip()]
        if not name.strip() or not keys or not all(KEY_RE.match(k) for k in keys):
            print('chain-render: bad --chain %r (want NAME=HIMMEL-n,HIMMEL-m,...)' % c, file=sys.stderr)
            return 2
        chains.append((name.strip(), keys))
    if not os.path.isdir(a.mirror):
        print('chain-render: the mirror %s is not a directory' % a.mirror, file=sys.stderr)
        return 2
    try:
        graph = json.load(open(a.graph, encoding='utf-8'))
        res = render(graph, chains, a.mirror)
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as e:
        print('chain-render: cannot read the graph %s or the mirror %s (%s)' % (a.graph, a.mirror, e), file=sys.stderr)
        return 2
    tmp = None
    try:
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(a.out)), prefix=os.path.basename(a.out) + '.', suffix='.tmp')
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            json.dump(res, f, indent=1)
            f.write('\n')
        try:
            mode = os.stat(a.out).st_mode & 0o777
        except FileNotFoundError:
            mask = os.umask(0)
            os.umask(mask)
            mode = 0o666 & ~mask
        os.chmod(tmp, mode)
        os.replace(tmp, a.out)
    except OSError as e:
        if tmp:
            try:
                os.remove(tmp)
            except OSError:
                pass
        print('chain-render: cannot write %s (%s)' % (a.out, e), file=sys.stderr)
        return 2
    print('chain-render: wrote %d chain(s), %d step(s) to %s' % (len(res), sum(len(c['steps']) for c in res), a.out))
    return 0


if __name__ == '__main__':
    sys.exit(main())
