#!/usr/bin/env bash
# trust-owner-sample.sh - the owner sampler of the 24-hour trust run (plan section 7 of the 24-hour trust run plan, sampler 1).
# READ-ONLY: it prints one JSON row per started ticket and writes nothing (no Jira, status, version,
# launch, ledger or doc).
#
#   trust-owner-sample.sh [--mirror DIR] [--bucket DIR] [--config-dir DIR]... [--now ISO]
#
# A started ticket is one the Jira mirror lists In Progress, In Review or IN CI. Row:
#   {ts, key, status, owner_kind, owner, proof, mirror_age_s, stale}
# owner_kind, the first that holds (a ticket's owner is only what is live, an open PR alone is not one):
#   worker    a fleet-manifest row whose doc names the ticket (attempt keys or the doc's own HIMMEL-<n> prefix) and
#             whose session id is proven by a live pid (session-pid.sh pid_proven_by_id: a recycled pid fails)
#   t3        that fleet row is bound to a T3 thread (`fleet-manifest.sh t3 set`; a `pending` thread binds nothing)
#   cloud     cloud-sessions.tsv holds a row for the ticket launched in the last 48 h
#   peer      that fleet row is of lane `peer` (the peer session's own row)
#   chief-go  a chief doc (*chief*.md in the bucket) carries a READY bullet naming the ticket: the PR waits for that
#             chief's go
#   UNOWNED   none of the above
# mirror_age_s is the age of the mirror's last sync (.cursor.json lastSync beside or above the mirror dir, else the
# newest ticket file); stale is true past 15 minutes: a stale sample counts neither for nor against a sentence.
#
# An unreadable source prints `UNKNOWN <what>` (mirror, manifests, cloud-sessions, sessions) and exits 3 with no
# row at all, never a partial list that would call a held ticket UNOWNED. Exit 2 usage.
#
# Defaults: --mirror the jira mirror dir; --bucket the handover bucket (handover_root, user_slug and the primary checkout name) (the fleet manifests,
# chief docs and cloud-sessions.tsv live there); --config-dir ~/.claude and ~/.claude-codex (the sessions/<pid>.json
# registries; at least one must be readable). Test seam: CLAUDE_SESSIONS_PROC (the /proc the pid proof reads).
#
# The pid proof runs in two cheap steps, since a station keeps a thousand manifests and a few dozen live sessions:
# first the sessions a live pid proves (pid_proven_by_id: a recycled pid fails), then only the manifest docs that
# name one of those session ids (doc_session_ids).
#
# PLATFORM GUARD: the chief kit is Linux-only (the pid proof reads /proc). Needs jq and python3.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=session-pid.sh
. "$HERE/session-pid.sh"

usage() {
    printf 'usage: trust-owner-sample.sh [--mirror DIR] [--bucket DIR] [--config-dir DIR]... [--now ISO]\n' >&2
    exit 2
}

default_bucket() {
    # shellcheck source=../../lib/load-dotenv.sh
    . "$HERE/../../lib/load-dotenv.sh" || return 1
    # shellcheck source=../../lib/user-slug.sh
    . "$HERE/../../lib/user-slug.sh" || return 1
    # shellcheck source=../../lib/handover-path.sh
    . "$HERE/../../lib/handover-path.sh" || return 1
    local primary root slug
    primary="$(_load_dotenv_primary_for "$HERE/../../..")" || return 1
    load_dotenv --root "$primary" HANDOVER_DIR USER_SLUG || return 1
    root="$(handover_root)" || return 1
    slug="$(cd "$HERE/../../.." && user_slug)" || return 1
    printf '%s/%s/%s\n' "$root" "$slug" "$(basename "$primary")"
}

mirror=""
bucket=""
now=""
cfgs=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --mirror) [ "$#" -ge 2 ] || usage; mirror="$2"; shift 2 ;;
        --bucket) [ "$#" -ge 2 ] || usage; bucket="$2"; shift 2 ;;
        --config-dir) [ "$#" -ge 2 ] || usage; cfgs+=("$2"); shift 2 ;;
        --now) [ "$#" -ge 2 ] || usage; now="$2"; shift 2 ;;
        *) usage ;;
    esac
done
if [ -z "$mirror" ]; then
    # shellcheck source=../../lib/jira-project.sh
    . "$HERE/../../lib/jira-project.sh"
    mirror="$(jira_mirror_dir)"
fi
[ -n "$bucket" ] || bucket="$(default_bucket)" || bucket=""
[ "${#cfgs[@]}" -gt 0 ] || cfgs=("$HOME/.claude" "$HOME/.claude-codex")
[ -n "$now" ] || now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"  # gnu-ok: chief kit is Linux-only

unknown=()
ls "$mirror"/*.md >/dev/null 2>&1 || unknown+=("mirror")
manifests=()
for m in "$bucket"/*.fleet.json; do
    [ -f "$m" ] && manifests+=("$m")
done
docs=""
if [ "${#manifests[@]}" -eq 0 ]; then
    unknown+=("manifests")
else
    docs="$(jq -r 'if ((.workers // .legs) | type) == "array" then (.workers // .legs)[] | .doc? // empty else error("rows") end' "${manifests[@]}" 2>/dev/null | sort -u)" || unknown+=("manifests")  # swallow-ok: a jq failure is the UNKNOWN manifests answer
fi
[ -r "$bucket/cloud-sessions.tsv" ] || unknown+=("cloud-sessions")
sess_ok=0
for c in "${cfgs[@]}"; do
    [ -d "$c/sessions" ] && [ -r "$c/sessions" ] && sess_ok=1
done
[ "$sess_ok" -eq 1 ] || unknown+=("sessions")
if [ "${#unknown[@]}" -gt 0 ]; then
    for u in "${unknown[@]}"; do printf 'UNKNOWN %s\n' "$u"; done
    exit 3
fi

proven=""
for c in "${cfgs[@]}"; do
    [ -d "$c/sessions" ] || continue
    for sf in "$c/sessions"/*.json; do
        [ -f "$sf" ] || continue
        pid="$(basename "$sf" .json)"
        case "$pid" in '' | *[!0-9]*) continue ;; esac
        sid="$(jq -r '.sessionId // empty' "$sf" 2>/dev/null)" || continue  # swallow-ok: a session file that is not JSON proves nothing
        [ -n "$sid" ] || continue
        if pid_proven_by_id "$pid" "$sid" "$c" 2>/dev/null; then
            proven="$proven$sid $pid
"
        fi
    done
done
proofs=""
if [ -n "$proven" ] && [ -n "$docs" ]; then
    pargs=()
    while IFS= read -r sid; do
        [ -n "$sid" ] && pargs+=(-e "$sid")
    done <<EOF
$(printf '%s' "$proven" | cut -d' ' -f1)
EOF
    hits="$(printf '%s\n' "$docs" | tr '\n' '\0' | xargs -0 grep -l -F "${pargs[@]}" -- 2>/dev/null)" || :  # swallow-ok: xargs exits 123 when a grep batch found no match or met a gone doc; the matches are on stdout
    while IFS= read -r doc; do
        [ -n "$doc" ] || continue
        ids="$(doc_session_ids "$doc" 2>/dev/null)" || continue  # swallow-ok: a doc with no readable session ids owns nothing
        while IFS= read -r sid; do
            [ -n "$sid" ] || continue
            pid="$(printf '%s' "$proven" | awk -v s="$sid" '$1 == s { print $2; exit }')"
            if [ -n "$pid" ]; then
                proofs="$proofs$doc	$pid
"
                break
            fi
        done <<EOF
$ids
EOF
    done <<EOF
$hits
EOF
fi

read -r -d '' PY <<'PYEOF' || true  # swallow-ok: read -d '' exits 1 at the end of the heredoc
import datetime, glob, json, os, re, sys

IN_WORK = ('In Progress', 'In Review', 'IN CI')
STALE_AFTER = 15 * 60
CLOUD_LIVE = 48 * 3600
KEY = re.compile(r'[A-Z][A-Z0-9_]*-\d+')
DOC_KEY = re.compile(r'^[A-Z][A-Z0-9_]*-\d+(?![\w])')


def utc(s):
    return datetime.datetime.fromisoformat(s.replace('Z', '+00:00')).astimezone(datetime.timezone.utc)


now = utc(os.environ['SO_NOW'])
mirror, bucket = os.environ['SO_MIRROR'], os.environ['SO_BUCKET']

# mirror: started tickets and the age of its last sync
started = {}
newest = 0.0
for f in glob.glob(os.path.join(mirror, '*.md')):
    newest = max(newest, os.path.getmtime(f))
    status = None
    with open(f, encoding='utf-8') as fh:
        lines = fh.read().split('\n')
    if lines and lines[0] == '---':
        for ln in lines[1:]:
            if ln == '---':
                break
            m = re.match(r'status:\s*"?([^"]*?)"?\s*$', ln)
            if m:
                status = m.group(1)
    key = os.path.basename(f)[:-3]
    if status in IN_WORK and KEY.fullmatch(key):
        started[key] = status
synced = None
for c in (os.path.join(mirror, '.cursor.json'), os.path.join(mirror, '..', '.cursor.json')):
    try:
        with open(c, encoding='utf-8') as fh:
            synced = utc(json.load(fh)['lastSync'])
        break
    except (OSError, ValueError, KeyError):
        continue
if synced is None:
    synced = datetime.datetime.fromtimestamp(newest, datetime.timezone.utc)
age = max(0, int((now - synced).total_seconds()))

# owners: key -> list of (rank, kind, owner, proof)
RANK = {'worker': 0, 't3': 1, 'cloud': 2, 'peer': 3, 'chief-go': 4}
owners = {}


def own(key, kind, owner, proof):
    owners.setdefault(key, []).append((RANK[kind], kind, owner, proof))


proven = {}
for ln in os.environ['SO_PROOFS'].split('\n'):
    if '\t' in ln:
        d, pid = ln.split('\t', 1)
        proven[d] = pid
for mf in sorted(glob.glob(os.path.join(bucket, '*.fleet.json'))):
    with open(mf, encoding='utf-8') as fh:
        mdoc = json.load(fh)
    rows = mdoc.get('workers') or mdoc.get('legs') or []
    for w in rows:
        doc = w.get('doc') or ''
        keys = set((w.get('attempt') or {}).get('keys') or [])
        m = DOC_KEY.match(os.path.basename(doc))
        if m:
            keys.add(m.group(0))
        label = w.get('label') or os.path.basename(doc)
        thread = w.get('t3_thread')
        for k in keys:
            if doc in proven:
                own(k, 'worker', label, 'pid %s proven by the doc session id' % proven[doc])
            if thread and thread != 'pending':
                own(k, 't3', thread, 'fleet row %s t3_kind=%s' % (os.path.basename(mf), w.get('t3_kind') or '-'))
            if w.get('lane') == 'peer':
                own(k, 'peer', label, 'fleet row %s lane=peer' % os.path.basename(mf))

with open(os.path.join(bucket, 'cloud-sessions.tsv'), encoding='utf-8') as fh:
    for ln in fh.read().split('\n'):
        cols = ln.split('\t')
        if len(cols) < 3 or not KEY.fullmatch(cols[1]):
            continue
        try:
            launched = datetime.datetime.fromisoformat(cols[0]).astimezone(datetime.timezone.utc)
        except ValueError:
            continue
        if 0 <= (now - launched).total_seconds() <= CLOUD_LIVE:
            own(cols[1], 'cloud', cols[2], 'cloud-sessions.tsv row of %s' % cols[0])

READY = re.compile(r'^\s*-\s+(?:\d{1,2}:\d{2}Z?\s+)?READY\b')
for cd in sorted(glob.glob(os.path.join(bucket, '*chief*.md'))):
    with open(cd, encoding='utf-8') as fh:
        for n, ln in enumerate(fh.read().split('\n'), 1):
            if READY.match(ln):
                for k in set(KEY.findall(ln)):
                    own(k, 'chief-go', os.path.basename(cd), 'READY bullet at line %d' % n)


def order(k):
    p, _, n = k.rpartition('-')
    return (p, int(n))


ts = now.strftime('%Y-%m-%dT%H:%M:%SZ')
for key in sorted(started, key=order):
    hit = sorted(owners.get(key, []))
    if hit:
        _, kind, owner, proof = hit[0]
    else:
        kind, owner, proof = 'UNOWNED', None, 'no live worker, t3 thread, cloud session, peer or READY bullet'
    print(json.dumps(dict(ts=ts, key=key, status=started[key], owner_kind=kind, owner=owner, proof=proof,
                          mirror_age_s=age, stale=age > STALE_AFTER)))
PYEOF

SO_NOW="$now" SO_MIRROR="$mirror" SO_BUCKET="$bucket" SO_PROOFS="$proofs" python3 -I -c "$PY" || {
    printf 'UNKNOWN sampler-error\n'
    exit 3
}
