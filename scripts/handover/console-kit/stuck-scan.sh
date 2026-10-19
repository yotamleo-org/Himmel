#!/usr/bin/env bash
# stuck-scan.sh — names In Progress / In Review / IN CI tickets that nobody
# holds, and records a disposition for each one. READ-ONLY apart from `dispose`.
#
#   stuck-scan.sh [--mirror DIR] [--version V] [--min N] [--repo owner/name]
#   stuck-scan.sh dispose <KEY> RESUME <leg> | BLOCKED-BY <ref> | OPERATOR <ask> | PARKED <reason>
#
# Scan: joins the Jira mirror (one <KEY>.md per issue), the live leg sessions
# (`pgrep -af 'claude .*-n HIMMEL-'`) and the open PRs (`gh pr list`). A ticket
# in an in-work status, last updated more than --min minutes ago (default 30),
# held by neither a live leg (session name HIMMEL-<n>-N...) nor an open PR
# (key in its title or head branch) prints one line:
#   STUCK <key> <status> <age>            age is Nm, Nh or Nd
#   BLOCKED-BY <key> <ref>                its LATEST comment carries a line
#                                         `DISPOSITION (...): BLOCKED-BY <ref>`
#                                         and <ref> (a PR number or a ticket key)
#                                         is still open
# A BLOCKED-BY whose ref merged or closed is STUCK again, so a dependency-held
# ticket is re-flagged once its blocker moves. A ref that is a ticket the mirror
# does not know counts as closed (never hides work). --version V keeps only
# tickets whose fixVersions lists V.
#
# dispose posts `DISPOSITION (<date>): <VERB> <arg>` on the ticket through the
# jira CLI (a --comment-file body). It does not transition the ticket.
#
# Exit: 0 (also when nothing is stuck); 3 when gh or the process table cannot be
# read, with `STUCK-UNKNOWN <what> failed` on stdout, never a silent empty list;
# 2 usage.
#
# Test seams: STUCK_SCAN_NOW (ISO-8601 clock), STUCK_SCAN_MIRROR,
# STUCK_SCAN_JIRA_CMD (command run as `<cmd> comment <KEY> --comment-file <f>`).
#
# ponytail: an OPERATOR / PARKED / RESUME disposition does not silence the scan,
# only the comment's own timestamp resets the --min clock; upgrade: honour them
# until their ref or leg changes.
# PLATFORM GUARD: no .ps1 twin, by design — the console kit is Linux-only. needs
# gh, python3, and node for dispose.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    printf 'usage: stuck-scan.sh [--mirror DIR] [--version V] [--min N] [--repo owner/name]\n       stuck-scan.sh dispose <KEY> RESUME <leg> | BLOCKED-BY <ref> | OPERATOR <ask> | PARKED <reason>\n' >&2
    exit 2
}

if [ "${1:-}" = dispose ]; then
    shift
    [ "$#" -ge 3 ] || usage
    key="$1"; verb="$2"; shift 2
    printf '%s\n' "$key" | grep -Eq '^[A-Z]+-[0-9]+$' || usage
    case "$verb" in RESUME | BLOCKED-BY | OPERATOR | PARKED) ;; *) usage ;; esac
    if [ -z "${STUCK_SCAN_JIRA_CMD:-}" ]; then
        primary="$(dirname "$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir)")"
        STUCK_SCAN_JIRA_CMD="node $primary/scripts/jira/dist/index.js"
    fi
    body="$(mktemp "${TMPDIR:-/tmp}/stuck-scan-dispose.XXXXXX")" || exit 1
    trap 'rm -f "$body"' EXIT
    printf 'DISPOSITION (%s): %s %s\n' "$(date +%Y-%m-%d)" "$verb" "$*" > "$body"  # gnu-ok: console kit is Linux-only
    # shellcheck disable=SC2086  # the command word-splits on purpose
    JIRA_PROJECT_KEY="${JIRA_PROJECT_KEY:-${key%%-*}}" $STUCK_SCAN_JIRA_CMD comment "$key" --comment-file "$body"
    exit $?
fi

mirror="${STUCK_SCAN_MIRROR:-${HOME:-/tmp}/.himmel/state/jira-mirror/HIMMEL}"
version=""
min=30
repo=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --mirror) [ "$#" -ge 2 ] || usage; mirror="$2"; shift 2 ;;
        --version) [ "$#" -ge 2 ] || usage; version="$2"; shift 2 ;;
        --min) [ "$#" -ge 2 ] || usage; min="$2"; shift 2 ;;
        --repo) [ "$#" -ge 2 ] || usage; repo="$2"; shift 2 ;;
        *) usage ;;
    esac
done
case "$min" in '' | *[!0-9]*) usage ;; esac
[ -d "$mirror" ] || { printf 'STUCK-UNKNOWN mirror missing\n'; exit 3; }

prs="$(gh pr list ${repo:+--repo "$repo"} --state open --limit 200 --json number,title,headRefName 2>/dev/null)" || { printf 'STUCK-UNKNOWN gh failed\n'; exit 3; }  # swallow-ok: a gh failure exits 3 as STUCK-UNKNOWN on this line
# pgrep exits 1 on no match, which is a valid empty answer; only rc >= 2 is a failure
alive="$(pgrep -af 'claude .*-n HIMMEL-' 2>/dev/null)"  # swallow-ok: rc is checked on the next line
[ "$?" -le 1 ] || { printf 'STUCK-UNKNOWN pgrep failed\n'; exit 3; }

SS_MIRROR="$mirror" SS_VERSION="$version" SS_MIN="$min" SS_PRS="$prs" SS_ALIVE="$alive" SS_NOW="${STUCK_SCAN_NOW:-}" python3 - <<'PY'
import datetime, glob, json, os, re

IN_WORK = {'In Progress', 'In Review', 'IN CI'}
CLOSED = {'Done', 'Closed', 'wont do', 'wont fix', 'In Public'}


def ts(s):
    s = re.sub(r'([+-]\d\d)(\d\d)$', r'\1:\2', s.strip().replace('Z', '+00:00'))
    return datetime.datetime.fromisoformat(s)


now = ts(os.environ['SS_NOW']) if os.environ['SS_NOW'] else datetime.datetime.now(datetime.timezone.utc)
prs = json.loads(os.environ['SS_PRS'] or '[]')
alive = os.environ['SS_ALIVE']
open_prs = {str(p['number']) for p in prs}
pr_text = ' '.join(p['title'] + ' ' + p['headRefName'] for p in prs).upper()

issues = {}
for path in glob.glob(os.path.join(os.environ['SS_MIRROR'], '*.md')):
    text = open(path, encoding='utf-8', errors='replace').read()
    head = text.split('\n---', 1)[0]
    field = lambda n: (re.search(r'^%s:\s*(.*)$' % n, head, re.M) or [None, ''])[1].strip().strip('"')
    key = field('key')
    if not key:
        continue
    comments = text.split('\n## Comments', 1)[1] if '\n## Comments' in text else ''
    blocks = re.split(r'^### ', comments, flags=re.M)[1:]
    issues[key] = {'key': key, 'status': field('status'), 'updated': field('updated'),
                   'versions': re.findall(r'"([^"]+)"', field('fixVersions')),
                   'last': blocks[-1] if blocks else ''}


def age(minutes):
    if minutes < 60:
        return '%dm' % minutes
    if minutes < 48 * 60:
        return '%dh' % (minutes // 60)
    return '%dd' % (minutes // (24 * 60))


def ref_open(ref):
    if ref.isdigit():
        return ref in open_prs
    other = issues.get(ref)
    return bool(other) and other['status'] not in CLOSED


for key in sorted(issues, key=lambda k: int(k.rsplit('-', 1)[1])):
    i = issues[key]
    if i['status'] not in IN_WORK or not i['updated']:
        continue
    if os.environ['SS_VERSION'] and os.environ['SS_VERSION'] not in i['versions']:
        continue
    minutes = int((now - ts(i['updated'])).total_seconds() // 60)
    if minutes <= int(os.environ['SS_MIN']):
        continue
    num = key.rsplit('-', 1)[1]
    if re.search(r'\b%s-N\d' % re.escape(key), alive) or re.search(r'\b%s\b' % re.escape(key.upper()), pr_text):
        continue
    m = re.search(r'^\s*DISPOSITION \([^)]*\):\s*BLOCKED-BY\s+(?:PR\s*#?|#)?(HIMMEL-\d+|\d+)\b', i['last'], re.M)
    if m and ref_open(m.group(1)):
        print('BLOCKED-BY %s %s' % (key, m.group(1)))
    else:
        print('STUCK %s %s %s' % (key, i['status'], age(minutes)))
PY
