#!/usr/bin/env bash
# queue-prune.sh — Apply orphan-pr-check.sh --stale-report to a chief doc: drop the dead `queue:` segments and
# the Done `pool-disposition:` lines, keeping a byte copy of each.
#
#   queue-prune.sh --doc CHIEF_DOC             print the pruned `queue:` line, then each pool line it would drop
#   queue-prune.sh --doc CHIEF_DOC --apply     also rewrite the doc
#   queue-prune.sh --drop-segments FILE        stdin `queue:` value to stdout without the listed head segments
#
# It runs a fresh `orphan-pr-check.sh --stale-report` (no cache). A released pool line (hold target gone, subject
# still open) is never in that report, so it is never dropped. --apply first compares the doc's `input=` (through
# `--stale-report --input-only`) with the report's: a doc whose `queue:` line or any `pool-disposition:` line changed
# in between exits 4 and nothing is written. It then appends the dropped text, byte for byte, to
# <doc dir>/specs/history/chief-live-state-<doc stem>.md under `# Live state pruned by queue-prune.sh from <stem> at
# <UTC minute>`, and replaces the doc by a temp file and rename, keeping its mode.
# Seam (tests): QUEUE_PRUNE_PRE_APPLY_HOOK, a shell command run between the report and the re-read, with the doc
# path in QUEUE_PRUNE_DOC.
#
# --drop-segments FILE: each head segment (the `queue:` value before its first `||`, split on `|`) that byte-equals
# a listed segment is removed; the kept ones are rejoined with `|`, leading and trailing blanks trimmed, the tail
# appended after one blank (alone when the head is empty), and the value reads `none` only when both are empty.
# FILE is one segment per line, or a whole --stale-report output, of which only the `DEAD-QUEUE<TAB>` lines name a
# segment.
#
# stderr, on success, is one line: `queue-prune: dead-queue=<n> done-pool=<n>[:<KEY>,...][ history=<path>]`.
# Exit: 0 done or nothing to do; 1 no doc, no Live state `queue:` line, or the doc could not be replaced; 2 usage;
# 3 --stale-report unavailable;
# 4 the doc changed under it; 5 the history write failed.
# PLATFORM GUARD: the chief kit is Linux-only.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() { echo "usage: queue-prune.sh --doc CHIEF_DOC [--apply] | --drop-segments FILE" >&2; exit 2; }

doc=""; apply=0; dropf=""; have_drop=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --doc) doc="${2:-}"; shift 2 || usage ;;
        --apply) apply=1; shift ;;
        --drop-segments) dropf="${2:-}"; have_drop=1; shift 2 || usage ;;
        *) usage ;;
    esac
done
if [ "$have_drop" -eq 1 ]; then
    [ -n "$dropf" ] && [ -z "$doc" ] && [ "$apply" -eq 0 ] || usage
    [ -r "$dropf" ] || { echo "queue-prune: cannot read $dropf" >&2; exit 1; }
else
    [ -n "$doc" ] || usage
    [ -f "$doc" ] || { echo "queue-prune: no doc $doc" >&2; exit 1; }
fi

export QP_DOC="$doc" QP_APPLY="$apply" QP_DROP="$dropf" QP_OPC="$HERE/orphan-pr-check.sh"
IFS= read -r -d '' py <<'PY'
import os, re, subprocess, sys, time

def rd(path):
    with open(path, 'rb') as f:
        return f.read().decode('utf-8', 'surrogateescape')

def out(text, stream=None):
    (stream or sys.stdout).buffer.write(text.encode('utf-8', 'surrogateescape'))

def drop_segments(value, dead):
    t = value.find('||')
    head, tail = (value[:t], value[t:]) if t >= 0 else (value, '')
    kept = [s for s in head.split('|') if s not in dead]
    res = '|'.join(kept).strip(' \t')
    if tail:
        res = (res + ' ' if res else '') + tail
    return res if res else 'none'

DEAD_TAG = 'DEAD-QUEUE\t'
REPORT_TAGS = (DEAD_TAG, 'DONE-POOL\t', 'dead-queue=', 'done-pool=', 'input=')

def dead_from_file(path):
    lines = rd(path).split('\n')
    if lines and lines[-1] == '':
        lines.pop()
    if any(l.startswith(REPORT_TAGS) for l in lines):
        return set(l[len(DEAD_TAG):] for l in lines if l.startswith(DEAD_TAG))
    return set(l for l in lines if l != '')

if os.environ['QP_DROP']:
    try:
        dead = dead_from_file(os.environ['QP_DROP'])
    except OSError as e:
        print('queue-prune: cannot read %s: %s' % (os.environ['QP_DROP'], e), file=sys.stderr)
        sys.exit(1)
    lines = rd('/dev/stdin').split('\n')
    if lines and lines[-1] == '':
        lines.pop()
    for line in lines:
        out(drop_segments(line, dead) + '\n')
    sys.exit(0)

doc, apply_mode, opc = os.environ['QP_DOC'], os.environ['QP_APPLY'] == '1', os.environ['QP_OPC']

def locate(lines):
    qi, pools, s, qdone, live = None, [], False, False, False
    for i, l in enumerate(lines):
        if l.startswith('## '):
            live = (l == '## Live state')
            if s:
                qdone = True
            elif live:
                s = True
        elif s and not qdone and qi is None and l.startswith('queue:'):
            qi = i
        if live and l.startswith('pool-disposition:'):
            pools.append(i)
    return qi, pools

def opc_run(args):
    p = subprocess.run(['bash', opc, '--doc', doc] + args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return p.returncode, p.stdout.decode('utf-8', 'surrogateescape'), p.stderr.decode('utf-8', 'surrogateescape')

def plan(text, dead, pool_keys):
    lines = text.split('\n')
    qi, pools = locate(lines)
    m = re.match(r'^(queue:[ \t]*)(.*)$', lines[qi], re.S)
    prefix, value = m.group(1), m.group(2)
    t = value.find('||')
    head = value[:t] if t >= 0 else value
    gone_segs = [s for s in head.split('|') if s in dead]
    lines[qi] = prefix + drop_segments(value, dead)
    gone_pools, drop_idx = [], set()
    for i in pools:
        if lines[i] in pool_keys:
            gone_pools.append((pool_keys[lines[i]], lines[i]))
            drop_idx.add(i)
    kept = [l for i, l in enumerate(lines) if i not in drop_idx]
    return '\n'.join(kept), lines[qi], gone_segs, gone_pools

def summary(n_dead, gone_pools, history=''):
    pool = '0' if not gone_pools else '%d:%s' % (len(gone_pools), ','.join(k for k, _ in gone_pools))
    return 'queue-prune: dead-queue=%d done-pool=%s%s\n' % (n_dead, pool, (' history=' + history) if history else '')

text = rd(doc)
if locate(text.split('\n'))[0] is None:
    print('queue-prune: no queue: line in the Live state of %s' % doc, file=sys.stderr)
    sys.exit(1)

rc, rep, rerr = opc_run(['--stale-report'])
if rc != 0:
    out(rerr, sys.stderr)
    print('queue-prune: --stale-report is unavailable (exit %d); nothing changed' % rc, file=sys.stderr)
    sys.exit(3)
dead, pool_keys, judged = set(), {}, ''
for l in rep.split('\n'):
    if l.startswith(DEAD_TAG):
        dead.add(l[len(DEAD_TAG):])
    elif l.startswith('DONE-POOL\t'):
        parts = l.split('\t', 2)
        if len(parts) == 3:
            pool_keys[parts[2]] = parts[1]
    elif l.startswith('input='):
        judged = l

new_text, new_q, gone_segs, gone_pools = plan(text, dead, pool_keys)

def show():
    out(new_q + '\n')
    for _, line in gone_pools:
        out(line + '\n')

if not apply_mode:
    show()
    out(summary(len(gone_segs), gone_pools), sys.stderr)
    sys.exit(0)

if not gone_segs and not gone_pools:
    show()
    out(summary(0, []), sys.stderr)
    sys.exit(0)

hook = os.environ.get('QUEUE_PRUNE_PRE_APPLY_HOOK')
if hook:
    subprocess.run(['bash', '-c', hook], env=dict(os.environ, QUEUE_PRUNE_DOC=doc), stdin=subprocess.DEVNULL)

before = rd(doc)
rc, now, _ = opc_run(['--stale-report', '--input-only'])
if rc != 0:
    print('queue-prune: could not re-read the doc (exit %d); nothing changed' % rc, file=sys.stderr)
    sys.exit(3)
if now.strip() != judged.strip() or not judged:
    print('queue-prune: the doc changed under the report; nothing written. Re-run.', file=sys.stderr)
    sys.exit(4)
text = rd(doc)
if text != before:
    print('queue-prune: the doc changed while it was being checked; nothing written. Re-run.', file=sys.stderr)
    sys.exit(4)
new_text, new_q, gone_segs, gone_pools = plan(text, dead, pool_keys)

stem = os.path.basename(doc)
stem = stem[:-3] if stem.endswith('.md') else stem
hdir = os.path.join(os.path.dirname(os.path.abspath(doc)), 'specs', 'history')
hfile = os.path.join(hdir, 'chief-live-state-%s.md' % stem)
entry = '# Live state pruned by queue-prune.sh from %s at %s\n\n' % (stem, time.strftime('%Y-%m-%dT%H:%MZ', time.gmtime()))
if gone_segs:
    entry += 'dead queue segments (the head of the queue: line, one per line):\n' + ''.join(s + '\n' for s in gone_segs)
if gone_pools:
    entry += 'done pool lines:\n' + ''.join(l + '\n' for _, l in gone_pools)
try:
    os.makedirs(hdir, exist_ok=True)
    sep = '\n' if os.path.exists(hfile) and os.path.getsize(hfile) > 0 else ''
    with open(hfile, 'ab') as f:
        f.write((sep + entry).encode('utf-8', 'surrogateescape'))
except OSError as e:
    print('queue-prune: could not write the history file %s: %s; the doc is unchanged' % (hfile, e), file=sys.stderr)
    sys.exit(5)

tmp = doc + '.prune.%d' % os.getpid()
try:
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    os.fchmod(fd, os.stat(doc).st_mode & 0o7777)
    with os.fdopen(fd, 'w', encoding='utf-8', errors='surrogateescape', newline='') as f:
        f.write(new_text)
    os.replace(tmp, doc)
except OSError as e:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    print('queue-prune: could not replace %s: %s' % (doc, e), file=sys.stderr)
    sys.exit(1)

show()
out(summary(len(gone_segs), gone_pools, hfile), sys.stderr)
PY
exec python3 -I -c "$py"
