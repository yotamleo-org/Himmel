#!/usr/bin/env bash
# trust-reach-sample.sh - the reach sampler of the 24-hour trust run (plan section 7 of the 24-hour trust run plan, sampler 4).
# READ-ONLY: it prints one JSON row per item that reached the operator and writes nothing (no Jira, status,
# version, launch, ledger or doc).
#
#   trust-reach-sample.sh [--bridge DIR] [--bucket DIR] [--since ISO] [--now ISO]
#
# Row: {ts, source, kind, class}, in time order, window [--since, --now) (--since defaults to one hour before --now).
#   route.log   every escalate line of <bridge>/route.log with a destination (`<ts> <kind> escalate <dest> ...`; the
#               chat id or `operator`): source route.log, its kind, its class from the table below. monitor, silent
#               and every other line reports nothing.
#   delivered   every `- [HH:MM[Z] ]DELIVERED <key> msg=<id> chat=<id>` receipt in a chief doc of the bucket
#               (*chief*.md): an owed send (a --receipt-only send never reaches route.log, so the
#               receipt is its proof). The receipt carries a clock time only: the date is the one in the doc's name,
#               one day on each time the clock goes back from one bullet to the next; a time with no Z is the
#               station's local time. Kind delivered, class UNCLASSIFIED (the receipt does not name what was asked).
#               An owed send that also wrote route.log appears in both sources; the record joins them by hand.
#   inbound.jsonl  the operator's own messages (<bridge>/inbound.jsonl and inbound.jsonl.1), TIME ONLY: the text,
#               caption and sender are never carried. Kind operator-message, class operator-own: listed beside the
#               reach rows, not one of them.
# Class table (kind to class), the only classification there is; a kind not in it is UNCLASSIFIED:
#   operator-step   the alert asks for a step only the operator can do: hold-ask-operator, hold-ask-stuck,
#                   merge-blocked, token-in-output, config-audit, recover-failed, monitor-chat-down, bypass-ask
# (confirm-the-cut, allow-live-spend and move-a-ticket-out have no kind of their own: they are chief questions, so
# a chief-ask or chief-reply row is UNCLASSIFIED and the record sorts it by hand.)
#
# Phone approval prompt: the root afk-sudo helper files a grant ask and sends it through its own notice bot; the
# station keeps only 0-byte markers under /var/lib/himmel/afk-grants, so that source was NOT SEEN, and this
# script says so on stderr every run. The asks the bridge itself sends (bypass-ask, afk-grant-expired) are route.log lines.
#
# An unreadable source prints `UNKNOWN <what>` (route-log, inbound, bucket, chief-doc-date) and exits 3 with no
# row, never a list that may have lost an item. Exit 2 usage.
#
# Defaults: --bridge ${BRIDGE_ROOT:-~/.claude/handover/bridge}; --bucket the handover bucket (handover_root, user_slug and the primary checkout name).
#
# PLATFORM GUARD: the chief kit is Linux-only. Needs python3.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    printf 'usage: trust-reach-sample.sh [--bridge DIR] [--bucket DIR] [--since ISO] [--now ISO]\n' >&2
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

bridge="${BRIDGE_ROOT:-$HOME/.claude/handover/bridge}"
bucket=""
since=""
now=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --bridge) [ "$#" -ge 2 ] || usage; bridge="$2"; shift 2 ;;
        --bucket) [ "$#" -ge 2 ] || usage; bucket="$2"; shift 2 ;;
        --since) [ "$#" -ge 2 ] || usage; since="$2"; shift 2 ;;
        --now) [ "$#" -ge 2 ] || usage; now="$2"; shift 2 ;;
        *) usage ;;
    esac
done
[ -n "$bucket" ] || bucket="$(default_bucket)" || bucket=""
[ -n "$now" ] || now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"  # gnu-ok: chief kit is Linux-only

printf 'NOTE phone-approval-prompt: source not seen (the afk-sudo grant ask goes through the root notice bot and leaves only 0-byte markers); bypass-ask and afk-grant-expired lines of route.log are read\n' >&2

unknown=()
{ [ -f "$bridge/route.log" ] && [ -r "$bridge/route.log" ]; } || unknown+=("route-log")
{ [ -f "$bridge/inbound.jsonl" ] && [ -r "$bridge/inbound.jsonl" ]; } || unknown+=("inbound")
{ [ -d "$bucket" ] && [ -r "$bucket" ]; } || unknown+=("bucket")
if [ "${#unknown[@]}" -gt 0 ]; then
    for u in "${unknown[@]}"; do printf 'UNKNOWN %s\n' "$u"; done
    exit 3
fi

read -r -d '' PY <<'PYEOF' || true  # swallow-ok: read -d '' exits 1 at the end of the heredoc
import datetime, glob, json, os, re, sys

CLASS = {
    'hold-ask-operator': 'operator-step', 'hold-ask-stuck': 'operator-step', 'merge-blocked': 'operator-step',
    'token-in-output': 'operator-step', 'config-audit': 'operator-step', 'recover-failed': 'operator-step',
    'monitor-chat-down': 'operator-step', 'bypass-ask': 'operator-step',
}


def utc(s):
    return datetime.datetime.fromisoformat(str(s).replace('Z', '+00:00')).astimezone(datetime.timezone.utc)


now = utc(os.environ['TRS_NOW'])
since = utc(os.environ['TRS_SINCE']) if os.environ['TRS_SINCE'] else now - datetime.timedelta(hours=1)
bridge, bucket = os.environ['TRS_BRIDGE'], os.environ['TRS_BUCKET']
rows = []


def add(ts, source, kind, cls):
    if since <= ts < now:
        rows.append((ts, dict(ts=ts.strftime('%Y-%m-%dT%H:%M:%SZ'), source=source, kind=kind, **{'class': cls})))


with open(os.path.join(bridge, 'route.log'), encoding='utf-8') as fh:
    for ln in fh:
        f = ln.split()
        if len(f) < 4 or f[2] != 'escalate' or f[3] == 'none':
            continue
        try:
            ts = utc(f[0])
        except ValueError:
            continue
        add(ts, 'route.log', f[1], CLASS.get(f[1], 'UNCLASSIFIED'))

for name in ('inbound.jsonl', 'inbound.jsonl.1'):
    path = os.path.join(bridge, name)
    if not os.path.isfile(path):
        continue
    with open(path, encoding='utf-8') as fh:
        for ln in fh:
            try:
                t = json.loads(ln).get('ts')
                if isinstance(t, (int, float)):
                    ts = datetime.datetime.fromtimestamp(t / 1000 if t > 1e11 else t, datetime.timezone.utc)
                else:
                    ts = utc(t)
            except (ValueError, AttributeError, TypeError):
                continue
            add(ts, 'inbound.jsonl', 'operator-message', 'operator-own')

CLOCK = re.compile(r'^\s*-\s+(\d{1,2}):(\d{2})(Z?)(?=\s)')
RECEIPT = re.compile(r'\sDELIVERED\s+\S+\s+msg=\d+\s+chat=-?\d+')
for doc in sorted(glob.glob(os.path.join(bucket, '*chief*.md'))):
    with open(doc, encoding='utf-8', errors='replace') as fh:
        lines = fh.read().split('\n')
    if not any(RECEIPT.search(ln) for ln in lines):
        continue
    m = re.search(r'(\d{4}-\d{2}-\d{2})', os.path.basename(doc))
    if not m:
        print('UNKNOWN chief-doc-date')
        sys.exit(3)
    day = datetime.date.fromisoformat(m.group(1))
    prev = -1
    for ln in lines:
        c = CLOCK.match(ln)
        if not c:
            continue
        minutes = int(c.group(1)) * 60 + int(c.group(2))
        if minutes < prev:
            day += datetime.timedelta(days=1)
        prev = minutes
        if not RECEIPT.search(ln):
            continue
        naive = datetime.datetime.combine(day, datetime.time(int(c.group(1)), int(c.group(2))))
        ts = naive.replace(tzinfo=datetime.timezone.utc) if c.group(3) else naive.astimezone(datetime.timezone.utc)
        add(ts, 'delivered', 'delivered', 'UNCLASSIFIED')

for _, row in sorted(rows, key=lambda r: r[0]):
    print(json.dumps(row))
PYEOF

TRS_NOW="$now" TRS_SINCE="$since" TRS_BRIDGE="$bridge" TRS_BUCKET="$bucket" python3 -I -c "$PY" || {
    rc=$?
    [ "$rc" -eq 3 ] || printf 'UNKNOWN sampler-error\n'
    exit 3
}
