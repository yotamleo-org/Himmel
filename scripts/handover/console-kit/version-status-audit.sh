#!/usr/bin/env bash
# version-status-audit.sh — Fails loudly when a ticket's status and fixVersion
# disagree. READ-ONLY: it prints rows, it never writes to Jira (the console
# resets each RESET row to To Do with a reason comment by hand).
#
#   version-status-audit.sh [--mirror DIR] [--legs-from MANIFEST] [--owners "KEY ..."]
#
# Source: the Jira mirror (one <KEY>.md per issue) and its HIMMEL.versions.tsv.
# The active version is the earliest unreleased, unarchived one (natural order;
# zz- throwaways ignored). Started = In Progress, In Review or IN CI. A class:
#   LATER-VERSION       started, and every unreleased fixVersion is after the active one
#   RELEASED-NOT-DONE   every fixVersion is released and the status category is not Done
#   NO-VERSION          a Task, Story or Bug with no fixVersion is started (Epics exempt)
#
# Ownership: a LATER-VERSION or NO-VERSION row held by a live leg (--legs-from
# manifest, leg doc not WRAPPED, or --owners) or an open PR (gh title or head
# branch names the key) is OWNED and not to be reset; the console moves it into
# the active version. A RELEASED-NOT-DONE row is always RESET.
#
# Output, one row per ticket, tab-separated:
#   <CLASS> <KEY> <status> <fixVersion|-> <owner|none> <RESET|OWNED>
# then `vmismatch=<rows>`. When the open-PR read fails, `open PRs unknown` is
# printed first, so no row is silently trusted as unowned.
#
# Env (tests): VSA_GH_CMD replaces `gh`.
#
# Exit: 0 no RESET row; 1 at least one RESET row; 2 usage; 3 nothing audited
# (mirror unreadable or empty, versions file missing).
# PLATFORM GUARD: no .ps1 twin, by design — the console kit is Linux-only.
set -u
mirror="${HOME:-/tmp}/.himmel/state/jira-mirror/HIMMEL"; legs_from="${LEGS_FROM:-}"; owners=""
while [ $# -gt 0 ]; do
    case "$1" in
        --mirror) mirror="${2:-}"; shift 2 || exit 2 ;;
        --legs-from) legs_from="${2:-}"; shift 2 || exit 2 ;;
        --owners) owners="${2:-}"; shift 2 || exit 2 ;;
        *) echo 'usage: version-status-audit.sh [--mirror DIR] [--legs-from MANIFEST] [--owners "KEY ..."]' >&2; exit 2 ;;
    esac
done
export VSA_MIRROR="$mirror" VSA_LEGS_FROM="$legs_from" VSA_OWNERS="$owners"

exec python3 -I - <<'PY'
import json, os, re, subprocess, sys

mirror = os.environ['VSA_MIRROR']
STARTED = {'in progress', 'in review', 'in ci'}

def fm_val(fm, name):
    m = re.search(r'^%s: (.*)$' % re.escape(name), fm, re.M)
    return m.group(1).strip().strip('"') if m else ''

try:
    names = sorted(n for n in os.listdir(mirror) if re.match(r'^[A-Z]+-\d+\.md$', n))
except OSError as e:
    print('version-status-audit: mirror unreadable (%s)' % e, file=sys.stderr); sys.exit(3)
if not names:
    print('version-status-audit: no tickets in %s' % mirror, file=sys.stderr); sys.exit(3)

def nat(v): return [int(x) if x.isdigit() else x for x in re.split(r'(\d+)', v)]
unreleased, released = [], set()
vf = mirror.rstrip('/') + '.versions.tsv'
if not os.path.exists(vf):
    print('version-status-audit: versions file missing (%s)' % vf, file=sys.stderr); sys.exit(3)
for line in open(vf, encoding='utf-8', errors='replace'):
    p = line.rstrip('\n').split('\t')
    if len(p) < 2 or p[0].startswith('zz-'):
        continue
    if p[1].strip() == 'true':
        released.add(p[0])
    elif p[1].strip() == 'false' and not (len(p) > 3 and p[3].strip() == 'true'):
        unreleased.append(p[0])
unreleased.sort(key=nat)
active = unreleased[0] if unreleased else None  # None: no LATER-VERSION row can exist

# owners: live legs and open PRs
owner = {}
for k in os.environ.get('VSA_OWNERS', '').split():
    owner.setdefault(k, 'leg:' + k)
legs_from = os.environ.get('VSA_LEGS_FROM', '')
MARKER_RE = re.compile(r'^- \d{1,2}:\d{2} (LIVE|FINDING|RESOLVED|READY|BLOCKED|HALTED|WRAPPED|PARKED-BANK|RESUMED)\b')
if legs_from and os.path.isfile(legs_from):
    try:
        for leg in json.load(open(legs_from)).get('legs', []):
            doc = leg.get('doc', '')
            try:
                lines = open(doc, encoding='utf-8', errors='replace').read().splitlines()
            except OSError:
                lines = []
            marks = [m.group(1) for m in (MARKER_RE.match(l) for l in lines) if m]
            if marks and marks[-1] == 'WRAPPED':
                continue
            for k in re.findall(r'[A-Z]+-\d+', os.path.basename(doc)):
                owner.setdefault(k, 'leg:%s' % leg.get('label', '?'))
    except (OSError, ValueError):
        pass
gh = os.environ.get('VSA_GH_CMD', 'gh')
try:
    out = subprocess.run([gh, 'pr', 'list', '--repo', 'yotamleo/Himmel', '--state', 'open', '--limit', '200', '--json', 'number,title,headRefName',
                          '--jq', '.[] | [.number, .title, .headRefName] | @tsv'],
                         capture_output=True, text=True, timeout=60, check=True).stdout
    for line in out.splitlines():
        num = line.split('\t', 1)[0]
        for k in re.findall(r'[A-Za-z]+-\d+', line.split('\t', 1)[-1]):
            owner.setdefault(k.upper(), 'PR:' + num)
except (OSError, subprocess.SubprocessError):
    print('version-status-audit: open PRs unknown (gh read failed); OWNED rows may be missing')

rows = []
for n in names:
    m = re.match(r'^---\n(.*?)\n---\n', open(os.path.join(mirror, n), encoding='utf-8', errors='replace').read(), re.S)
    if not m:
        continue
    fm = m.group(1)
    key, typ, status = fm_val(fm, 'key'), fm_val(fm, 'type'), fm_val(fm, 'status')
    done = fm_val(fm, 'statusCategory').lower() == 'done'
    vers = re.findall(r'"([^"]+)"', fm_val(fm, 'fixVersions'))
    started = status.lower() in STARTED
    open_vers = [v for v in vers if v in unreleased]
    cls = None
    if open_vers:
        if started and active and all(nat(v) > nat(active) for v in open_vers):
            cls = 'LATER-VERSION'
    elif vers and all(v in released for v in vers):
        if not done:
            cls = 'RELEASED-NOT-DONE'
    elif not vers and started and typ in ('Task', 'Story', 'Bug'):
        cls = 'NO-VERSION'
    if cls:
        own = owner.get(key) if cls != 'RELEASED-NOT-DONE' else None
        rows.append((cls, key, status, ','.join(vers) or '-', own or 'none', 'OWNED' if own else 'RESET'))

rows.sort(key=lambda r: (r[0], int(r[1].split('-')[1])))
for r in rows:
    print('\t'.join(r))
print('vmismatch=%d' % len(rows))
sys.exit(1 if any(r[5] == 'RESET' for r in rows) else 0)
PY
