#!/usr/bin/env bash
# scripts/handover/console-kit/focus-chains-links.sh - write the step order of the
# console's focus-chains.json as Jira Blocks links, so the dispatcher reads the
# chains from Jira instead of a file only the console keeps.
#
# Usage: focus-chains-links.sh <focus-chains.json> [--mirror DIR] [--chain N]... [--apply]
#
# Each pair of consecutive steps in a chain is one proposed link: step i blocks
# step i+1. The default is a DRY RUN: one TSV row per pair, nothing written:
#   chain  blocker  blocked  state  note
# state is one of
#   new         neither side of the mirror shows the link: --apply writes it
#   linked      the mirror already shows blocker blocks blocked
#   reversed    the mirror shows the opposite link, or an earlier chain proposes it:
#               never written (it would make a cycle)
#   cycle       blocked already reaches blocker over the mirror's blocks links and
#               the new or linked rows above: never written
#   closed      a side is Done (statusCategory): nothing to order
#   unknown     a key has no mirror file
# A pair repeated in a later chain is listed once, its chain column naming every
# chain that proposes it (0,2); --apply writes it when any of them is picked.
# The last line counts the rows by state.
#
# --apply writes the `new` rows of the chains named by --chain (index in the file,
# repeatable; --apply without one is refused, so the console picks which chains are
# real orderings, not groups). Each write is `jira link <blocker> --blocks <blocked>`,
# which itself reads the issue back after the POST; then every written pair is read
# back once more with `jira links <blocker>` and printed `readback <A> blocks <B> ok`
# or `MISSING` (`FAILED: <error>` when the links call itself fails). Exit: 0 dry run or every write read back; 1 a write or a read-back
# failed; 2 usage.
#
# Test seam (env): FCL_JIRA (an executable standing in for the jira CLI).
# Platform guard: POSIX bash 3.2+, needs python3; no .ps1 twin by design (shell-only harness).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/git-clean.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/git-clean.sh"
git_env_scrub
usage() { echo "usage: focus-chains-links.sh <focus-chains.json> [--mirror DIR] [--chain N]... [--apply]" >&2; exit 2; }
[ "$#" -ge 1 ] || usage
chains="$1"; shift
mirror="${NEXT_DISPATCH_MIRROR:-${HOME:-/tmp}/.himmel/state/jira-mirror/HIMMEL}"
apply=0; picked=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --mirror) [ "$#" -ge 2 ] || usage; mirror="$2"; shift 2 ;;
        --chain) [ "$#" -ge 2 ] || usage; case "$2" in ''|*[!0-9]*) usage ;; esac; picked="$picked $2"; shift 2 ;;
        --apply) apply=1; shift ;;
        *) usage ;;
    esac
done
[ -f "$chains" ] || { echo "focus-chains-links: no such file: $chains" >&2; exit 2; }
if [ "$apply" -eq 1 ] && [ -z "$picked" ]; then
    echo "focus-chains-links: --apply needs --chain N for every chain to write (dry-run first)" >&2; exit 2
fi

rows="$(FCL_CHAINS="$chains" FCL_MIRROR="$mirror" python3 - <<'PY'
import json, os, re, sys
chains = json.load(open(os.environ['FCL_CHAINS'], encoding='utf-8'))
mirror = os.environ['FCL_MIRROR']
cache = {}
def issue(key):
    if key not in cache:
        try:
            txt = open(os.path.join(mirror, key + '.md'), encoding='utf-8', errors='replace').read()
        except OSError:
            cache[key] = None
            return None
        fm = txt.split('\n---', 1)[0]
        def lst(name):
            m = re.search(r'^\s+%s: \[(.*)\]\s*$' % name, fm, re.M)
            return set(re.findall(r'[A-Z]+-\d+', m.group(1))) if m else set()
        cat = re.search(r'^statusCategory: "?([^"\n]*)"?', fm, re.M)
        cache[key] = {'done': bool(cat) and cat.group(1) == 'Done', 'blocks': lst('blocks'), 'blocked_by': lst('blocked_by')}
    return cache[key]
seen = {}
rows = []
edges = {}
def reaches(src, dst):
    # src reaches dst over the mirror's blocks links plus the new or linked pairs so far
    stack, done = [src], set()
    while stack:
        x = stack.pop()
        if x == dst:
            return True
        if x in done:
            continue
        done.add(x)
        ix = issue(x)
        stack.extend((ix['blocks'] if ix else set()) | edges.get(x, set()))
    return False
for n, ch in enumerate(chains):
    keys = [s.get('key') for s in ch.get('steps', []) if s.get('key')]
    for a, b in zip(keys, keys[1:]):
        if a == b:
            continue
        if (a, b) in seen:
            if n not in rows[seen[(a, b)]][0]:
                rows[seen[(a, b)]][0].append(n)
            continue
        seen[(a, b)] = len(rows)
        ia, ib = issue(a), issue(b)
        if (b, a) in seen:
            state, note = 'reversed', 'chain %d proposes %s blocks %s' % (rows[seen[(b, a)]][0][0], b, a)
        elif ia is None or ib is None:
            state, note = 'unknown', 'not in mirror: ' + ' '.join(k for k, i in ((a, ia), (b, ib)) if i is None)
        elif b in ia['blocks'] or a in ib['blocked_by']:
            state, note = 'linked', ''
        elif b in ia['blocked_by'] or a in ib['blocks']:
            state, note = 'reversed', '%s already blocks %s' % (b, a)
        elif reaches(b, a):
            state, note = 'cycle', '%s already reaches %s' % (b, a)
        elif ia['done'] or ib['done']:
            state, note = 'closed', 'Done: ' + ' '.join(k for k, i in ((a, ia), (b, ib)) if i['done'])
        else:
            state, note = 'new', ''
        if state in ('new', 'linked'):
            edges.setdefault(a, set()).add(b)
        rows.append([[n], a, b, state, note or (ch.get('name') or '')[:60]])
counts = {}
for r in rows:
    counts[r[3]] = counts.get(r[3], 0) + 1
    print('\t'.join([','.join(str(c) for c in r[0])] + r[1:]))
print('# pairs: %d (%s)' % (len(rows), ', '.join('%s %d' % kv for kv in sorted(counts.items())) or 'none'))
PY
)" || { echo "focus-chains-links: cannot read $chains" >&2; exit 2; }
printf 'chain\tblocker\tblocked\tstate\tnote\n%s\n' "$rows"
[ "$apply" -eq 1 ] || exit 0

if [ -n "${FCL_JIRA:-}" ]; then
    jira=("$FCL_JIRA")
else
    # swallow-ok: no git checkout leaves anchor empty, and the jira call then fails by name
    anchor="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || anchor=""
    jira=(node "${anchor%/.git}/scripts/jira/dist/index.js")
fi
export JIRA_PROJECT_KEY="${JIRA_PROJECT_KEY:-HIMMEL}"
rc=0; written=""
while IFS="$(printf '\t')" read -r n a b state _; do
    [ "$state" = new ] || continue
    hit=0
    for c in ${n//,/ }; do case " $picked " in *" $c "*) hit=1 ;; esac; done
    [ "$hit" -eq 1 ] || continue
    if out="$("${jira[@]}" link "$a" --blocks "$b" 2>&1)"; then
        echo "write $a blocks $b: $out"
        written="$written $a:$b"
    else
        echo "write $a blocks $b FAILED: $out"; rc=1
    fi
done <<EOF
$rows
EOF
for pair in $written; do
    a="${pair%%:*}"; b="${pair#*:}"
    if ! got="$("${jira[@]}" links "$a" 2>&1)"; then
        echo "readback $a blocks $b FAILED: $got"; rc=1
    elif grep -Eq "^[0-9]+	Blocks	inward=$a	outward=$b	" <<< "$got"; then
        echo "readback $a blocks $b ok"
    else
        echo "readback $a blocks $b MISSING"; rc=1
    fi
done
exit "$rc"
