#!/usr/bin/env bash
# priority-prune.sh — Drop the closed keys from a console doc's `priority:` line.
# The line only shrinks as keys ship, so a stale line keeps the pool LOW; this
# prints the line with every closed key removed and the rest in its order.
#
#   priority-prune.sh --doc CONSOLE_DOC [--mirror DIR]           print the pruned line
#   priority-prune.sh --doc CONSOLE_DOC [--mirror DIR] --count   print <closed>/<total>
#   priority-prune.sh --doc CONSOLE_DOC [--mirror DIR] --apply   also rewrite the line
#
# The line is the first `priority:` line in the doc's `## Live state`, read
# with next-dispatchable.sh's tokenizer (read_priority_line): keep the two in
# step. Closed = statusCategory Done in the Jira mirror (Done, Closed, wont do,
# wont fix, In Public); a key missing from the mirror is open. A closed key
# goes with its attached `(...)` note unless the note holds an open key; an
# emptied `|` group goes; prose with no key (`rest of v1.1.3`) is an
# instruction and stays; a line with nothing left reads `none`. The dropped
# keys are named on stderr. Pruning is not re-ranking, but the console runs
# --apply only with an operator OK and logs a `PRIORITY-PRUNE: <keys>` Results
# bullet (console.sh next accepts it for a line pruned to none).
#
# Exit: 0 printed; 1 no doc, mirror or Live state priority: line; 2 usage.
# PLATFORM GUARD: no .ps1 twin, by design — the console kit is Linux-only.
set -u

doc=""; mirror="${NEXT_DISPATCH_MIRROR:-${HOME:-/tmp}/.himmel/state/jira-mirror/HIMMEL}"; mode=print
while [ "$#" -gt 0 ]; do
    case "$1" in
        --doc) doc="${2:-}"; shift 2 || exit 2 ;;
        --mirror) mirror="${2:-}"; shift 2 || exit 2 ;;
        --count) mode=count; shift ;;
        --apply) mode=apply; shift ;;
        *) echo "usage: priority-prune.sh --doc CONSOLE_DOC [--mirror DIR] [--count|--apply]" >&2; exit 2 ;;
    esac
done
[ -n "$doc" ] || { echo "usage: priority-prune.sh --doc CONSOLE_DOC [--mirror DIR] [--count|--apply]" >&2; exit 2; }
[ -f "$doc" ] || { echo "priority-prune: no doc $doc" >&2; exit 1; }
[ -d "$mirror" ] || { echo "priority-prune: no Jira mirror $mirror" >&2; exit 1; }

export PP_DOC="$doc" PP_MIRROR="$mirror" PP_MODE="$mode"
exec python3 -I - <<'PY'
import os, re, sys

doc, mirror, mode = os.environ['PP_DOC'], os.environ['PP_MIRROR'], os.environ['PP_MODE']
TOK = re.compile(r'([(\[])|([)\]])|(\+)|(?<![\w.-])(HIMMEL-)?(\d{3,5})(?![\w-]|\.\d)(\s*\(CLOUD\))?')
LINE = re.compile(r'^(\s*(?:[-*]\s+)?(?:\*\*)?priority:(?:\*\*)?\s*)(.*)$')

text = open(doc, encoding='utf-8', errors='replace').read()
lines = text.split('\n')
at, in_state = None, False
for n, line in enumerate(lines):
    if line.startswith('## '):
        in_state = line.strip() == '## Live state'
    if in_state and LINE.match(line):
        at = n
        break
if at is None:
    print('priority-prune: no priority: line in the Live state of %s' % doc, file=sys.stderr)
    sys.exit(1)
prefix, body = LINE.match(lines[at]).groups()

def closed(key):
    try:
        head = open(os.path.join(mirror, key + '.md'), encoding='utf-8', errors='replace').read(4096)
    except OSError:
        return False
    m = re.search(r'^statusCategory: "?([^"\n]*)"?$', head, re.M)
    return bool(m) and m.group(1).strip() == 'Done'

# keys: [key, start, end, top-level, (group start, group end) or None, inner keys]
keys, depth, plus, owner = [], 0, False, None
for t in TOK.finditer(body):
    if t.group(1):
        if depth == 0:
            owner = keys[-1] if keys and keys[-1][3] and keys[-1][2] == t.start() else None
            group_start = t.start()
        depth += 1
    elif t.group(2):
        depth, plus = max(depth - 1, 0), False
        if depth == 0 and owner is not None:
            owner[4] = (group_start, t.end())
            owner = None
    elif t.group(3):
        plus = plus or depth > 0
    elif depth == 0 or plus or t.group(4):
        k = [ 'HIMMEL-' + t.group(5), t.start(), t.end(), depth == 0, None, []]
        keys.append(k)
        if depth > 0 and owner is not None:
            owner[5].append(k)

state = {}
for k in keys:
    if k[0] not in state:
        state[k[0]] = closed(k[0])
total, shut = len(state), sum(state.values())
if mode == 'count':
    print('%d/%d' % (shut, total))
    sys.exit(0)

spans = []
for k in keys:
    if not state[k[0]]:
        continue
    if k[4] and not any(not state[i[0]] for i in k[5]):
        spans.append((k[1], k[4][1]))
    else:
        spans.append((k[1], k[2]))
out = body
for s, e in sorted(spans, reverse=True):
    if any(s >= s2 and e <= e2 and (s, e) != (s2, e2) for s2, e2 in spans):
        continue
    out = out[:s] + out[e:]
out = re.sub(r'([(\[])\s*\+?\s*([)\]])', '', out)
out = re.sub(r'\+\s*(?=[)\]])', '', out)
out = re.sub(r'([(\[]\+?)\s+', r'\1', out)
out = re.sub(r'\s+([)\]])', r'\1', out)
out = re.sub(r'\s+', ' ', out)
groups = [g.strip() for g in out.split('|')]
out = ' | '.join(g for g in groups if g) or 'none'

gone = []
for k in keys:
    if state[k[0]] and k[0].split('-')[1] not in gone:
        gone.append(k[0].split('-')[1])
print('priority-prune: dropped %d: %s' % (len(gone), ' '.join(gone)), file=sys.stderr)
new = prefix + out
print(new)
if mode == 'apply' and new != lines[at]:
    lines[at] = new
    tmp = doc + '.prune.%d' % os.getpid()
    with open(tmp, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines))
    os.replace(tmp, doc)
PY
