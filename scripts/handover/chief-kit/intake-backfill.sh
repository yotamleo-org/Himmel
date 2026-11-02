#!/usr/bin/env bash
# intake-backfill.sh: the one-time backfill of open tickets that carry no fixVersion. It reads the Jira
# mirror and PRINTS a proposed version for each one; it files nothing and writes nothing.
#
# USAGE  intake-backfill.sh [--mirror DIR] [--commands --release R] [--batch N]
#   --mirror DIR  the mirror directory (default: $NEXT_DISPATCH_MIRROR or ~/.himmel/state/jira-mirror/HIMMEL);
#                 DIR.versions.tsv beside it lists the versions (name, released, date, archived)
#   --commands    print label and reasoned INTAKE commands for at most 20 keys; never execute them
#   --release R   the chief's declared release identifier (required for commands; never guessed from a version)
#   --batch N     one-based command batch (default 1). Keep the same mirror snapshot for stable offsets;
#                 drain one batch through the tick's RM before filing the next. No guard override.
#
# Output: `<KEY>\t<proposed>\t<basis>` rows (proposed is an open version or `backlog`), then `# counts` lines:
# the total, the count per proposed version, the count per basis and the open tickets that already carry a
# proposed-<v> label (no longer skipped: a label does not prove an INTAKE was queued). Open means statusCategory To Do or In Progress; a
# Sub-task is skipped (it follows its parent). The current version is the first open one in the versions file.
#
# Basis, first match wins:
#   proposed-label     an existing proposed-<v> for an open version or backlog       -> v
#   scope-label        carries scope-<v> for an open version v                      -> v
#   operator-directed  carries the operator-directed label                           -> current
#   high-bug           a Bug at High or Highest                                      -> current
#   in-progress        already being worked                                          -> current
#   low-label          backlog, unscheduled, residual*, stale, needs-standard, fu-*, cr-deferred -> backlog
#   sector-active      High or Highest, and its sector has an open ticket in the current version -> current
#   no-signal          none of the above                                             -> backlog
# ponytail: a fixed rule table over labels and sector; upgrade to a ranking from the roadmap fields once the
# operator has read a first batch of proposals.
set -u

mirror="${NEXT_DISPATCH_MIRROR:-${HOME:-/tmp}/.himmel/state/jira-mirror/HIMMEL}"
commands=0
release=""
batch=1
while [ $# -gt 0 ]; do
    case "$1" in
        --mirror) [ $# -ge 2 ] || { echo "usage: intake-backfill.sh [--mirror DIR] [--commands --release R] [--batch N]" >&2; exit 2; }; mirror="$2"; shift 2 ;;
        --commands) commands=1; shift ;;
        --release) [ $# -ge 2 ] || exit 2; release="$2"; shift 2 ;;
        --batch) [ $# -ge 2 ] || exit 2; batch="$2"; shift 2 ;;
        *) echo "usage: intake-backfill.sh [--mirror DIR] [--commands --release R] [--batch N]" >&2; exit 2 ;;
    esac
done
[ -d "$mirror" ] || { echo "intake-backfill: no mirror directory at $mirror" >&2; exit 1; }

IB_MIRROR="$mirror" IB_COMMANDS="$commands" IB_RELEASE="$release" IB_BATCH="$batch" python3 -I - <<'PY'
import glob, json, os, re, shlex, sys

mirror = os.environ['IB_MIRROR'].rstrip('/')
release = os.environ['IB_RELEASE']
if os.environ['IB_COMMANDS'] == '1' and not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', release):
    sys.exit('intake-backfill: --commands requires --release <declared release>, not a guessed version')
if not re.fullmatch(r'[1-9][0-9]*', os.environ['IB_BATCH']):
    sys.exit('intake-backfill: --batch must be a positive integer')
batch = int(os.environ['IB_BATCH'])
open_versions = []
try:
    for line in open(mirror + '.versions.tsv'):
        if not line.strip():
            continue
        f = line.rstrip('\n').split('\t')
        # a row that is not name, released, date, archived with true/false flags must not read as an open version
        if len(f) < 2 or not f[0] or f[1] not in ('true', 'false') or (len(f) >= 4 and f[3] not in ('true', 'false')):
            sys.exit('intake-backfill: malformed row in %s.versions.tsv: %r' % (mirror, line.rstrip('\n')))
        if not f[0].startswith('zz-') and f[1] != 'true' and (len(f) < 4 or f[3] != 'true'):
            open_versions.append(f[0])
except OSError as e:
    # without the versions there is no current version, and every ticket would be proposed to the backlog
    sys.exit('intake-backfill: cannot read %s.versions.tsv: %s' % (mirror, e.strerror))
current = open_versions[0] if open_versions else None
if os.environ['IB_COMMANDS'] == '1' and current is None:
    sys.exit('intake-backfill: no open version, so there is no release to file the INTAKE requests into; --commands needs one')

def field(text, name):
    m = re.search(r'^%s: (.*)$' % name, text, re.M)
    return m.group(1).strip() if m else ''

def unq(v):
    v = v.strip()
    return v[1:-1] if len(v) >= 2 and v[0] == '"' and v[-1] == '"' else v

tickets = []
for path in glob.glob(mirror + '/*.md'):
    try:
        head = open(path).read(6000).split('\n---', 2)[0]
    except OSError as e:
        sys.exit('intake-backfill: cannot read %s: %s' % (path, e.strerror))
    key = unq(field(head, 'key'))
    if not re.fullmatch(r'[A-Z]+-\d+', key):
        continue
    try:
        labels = json.loads(field(head, 'labels') or '[]')
        fixv = json.loads(field(head, 'fixVersions') or '[]')
    except ValueError:
        sys.exit('intake-backfill: cannot parse the labels or fixVersions of %s' % path)
    tickets.append({'key': key, 'type': unq(field(head, 'type')), 'cat': unq(field(head, 'statusCategory')),
                    'prio': unq(field(head, 'priority')), 'labels': labels, 'ver': fixv, 'sector': unq(field(head, 'sector'))})

is_open = lambda t: t['cat'] in ('To Do', 'In Progress')
active = {t['sector'] for t in tickets if current and current in t['ver'] and is_open(t) and t['sector'] and t['sector'] != 'null'}
LOW = re.compile(r'^(backlog|unscheduled|residual.*|stale|needs-standard|fu-.*|cr-deferred)$')

rows, skipped = [], 0
for t in sorted((t for t in tickets if is_open(t) and not t['ver'] and t['type'] != 'Sub-task'), key=lambda t: int(t['key'].split('-')[1])):
    ls = t['labels']
    # A label is not queue provenance. Reprint its reasoned request; the CLI deduplicates
    # a matching pending key/verb/destination, including one already claimed by the RM.
    proposed = [l[9:] for l in ls if l.startswith('proposed-') and l[9:] in [*open_versions, 'backlog']]
    scoped = [l[6:] for l in ls if l.startswith('scope-') and l[6:] in open_versions]
    low = [l for l in ls if LOW.match(l)]
    if proposed:
        r = (proposed[0], 'proposed-label')
    elif scoped:
        r = (scoped[0], 'scope-label')
    elif 'operator-directed' in ls:
        r = (current or 'backlog', 'operator-directed')
    elif t['type'] == 'Bug' and t['prio'] in ('High', 'Highest'):
        r = (current or 'backlog', 'high-bug')
    elif t['cat'] == 'In Progress':
        r = (current or 'backlog', 'in-progress')
    elif low:
        r = ('backlog', 'low-label')
    elif t['sector'] in active and t['prio'] in ('High', 'Highest'):
        r = (current or 'backlog', 'sector-active')
    else:
        r = ('backlog', 'no-signal')
    rows.append((t['key'], r[0], r[1]))

for k, v, b in rows:
    print('%s\t%s\t%s' % (k, v, b))
by_ver, by_basis = {}, {}
for _, v, b in rows:
    by_ver[v] = by_ver.get(v, 0) + 1
    by_basis[b] = by_basis.get(b, 0) + 1
fmt = lambda d: ' '.join('%s=%d' % kv for kv in sorted(d.items()))
print('# counts total=%d already-proposed-skipped=%d current=%s' % (len(rows), skipped, current or 'none'))
print('# counts by proposed: %s' % (fmt(by_ver) or 'none'))
print('# counts by basis: %s' % (fmt(by_basis) or 'none'))
if os.environ['IB_COMMANDS'] == '1':
    # The RM admits at most 20 current-version moves per run. Print one bounded batch,
    # not an executable loop or an override; the chief waits for it to drain before the next.
    print('# commands batch=%d/%d max-keys=20; drain this batch before filing the next; keep this mirror snapshot for stable offsets' % (batch, max(1, (len(rows) + 19) // 20)))
    for k, v, b in rows[(batch - 1) * 20:batch * 20]:
        print('jira edit %s --add-labels %s' % (k, shlex.quote('proposed-' + v)))
        print('jira release request %s --verb INTAKE --key %s --to %s --why "backfill: %s"' % (shlex.quote(release), k, shlex.quote(v), b))
PY
