#!/usr/bin/env bash
# trust-slot-sample.sh - the slot sampler of the 24-hour trust run (plan section 7 of the 24-hour trust run plan, sampler 2).
# READ-ONLY: it prints one JSON row per sample and writes nothing (no Jira, status, version, launch, ledger or doc).
#
#   trust-slot-sample.sh [--workers-from MANIFEST] [--doc CHIEF_DOC] [--launch-refusals FILE] [--since ISO] [--now ISO]
#
# Row: {ts, cap, live, free, fleet_reason, listed, started, refused, silent}
#   cap, live   the `total=<live>/<cap>` of the FLEET line usage-preflight.sh prints; free = max(cap - live, 0)
#   fleet_reason  null when the preflight's last line is PROCEED, else that line (a budget hold or dispatch pause:
#               a stated reason for every ticket at this sample)
#   listed      every ticket `next-dispatchable.sh --why --dispositions` marks `# disposition <KEY> listed ...`
#   started     listed tickets with an `attempt-started` row in launch-refusals.jsonl from --since to --now
#   refused     [{key, reason}] for each listed ticket with an `outcome: refused` row in that window
#   silent      listed tickets that neither started nor were refused, when a slot is free and no fleet reason
#               holds: the ones the sample calls unfilled
# --since defaults to 15 minutes before --now (the sample period): pass the previous sample's time.
#
# An unreadable source prints `UNKNOWN <what>` (fleet, dispatcher, launch-refusals) and exits 3, never a row built
# on a guess. The fleet is unread when the preflight exits non-zero (it always exits 0) or prints no FLEET line.
# The dispatcher is unread when it exits non-zero, prints a quota-pause or gh-stall line (no rows
# at all), or says its open PRs or live workers are unknown. Exit 2 usage.
#
# Seams: TRUST_SLOT_PREFLIGHT_CMD (a script run with bash in place of scripts/lib/usage-preflight.sh),
# TRUST_SLOT_DISPATCH_CMD (in place of next-dispatchable.sh), HIMMEL_LAUNCH_REFUSALS (default
# ~/.himmel/launch-refusals.jsonl).
#
# PLATFORM GUARD: the chief kit is Linux-only. Needs python3.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    printf 'usage: trust-slot-sample.sh [--workers-from MANIFEST] [--doc CHIEF_DOC] [--launch-refusals FILE] [--since ISO] [--now ISO]\n' >&2
    exit 2
}

dispatch_args=()
refusals="${HIMMEL_LAUNCH_REFUSALS:-$HOME/.himmel/launch-refusals.jsonl}"
since=""
now=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --workers-from) [ "$#" -ge 2 ] || usage; dispatch_args+=(--workers-from "$2"); shift 2 ;;
        --doc) [ "$#" -ge 2 ] || usage; dispatch_args+=(--doc "$2"); shift 2 ;;
        --launch-refusals) [ "$#" -ge 2 ] || usage; refusals="$2"; shift 2 ;;
        --since) [ "$#" -ge 2 ] || usage; since="$2"; shift 2 ;;
        --now) [ "$#" -ge 2 ] || usage; now="$2"; shift 2 ;;
        *) usage ;;
    esac
done
[ -n "$now" ] || now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"  # gnu-ok: chief kit is Linux-only

preflight="${TRUST_SLOT_PREFLIGHT_CMD:-$HERE/../../lib/usage-preflight.sh}"
dispatch="${TRUST_SLOT_DISPATCH_CMD:-$HERE/next-dispatchable.sh}"

unknown=()
pf_rc=0
pf_out="$(bash "$preflight" 2>&1)" || pf_rc=$?
[ "$pf_rc" -eq 0 ] || unknown+=("fleet")
fleet="$(printf '%s\n' "$pf_out" | sed -n -E 's/.*FLEET .*total=([0-9]+)\/([0-9]+).*/\1 \2/p' | tail -n 1)"
[ -n "$fleet" ] || { [ "$pf_rc" -ne 0 ] || unknown+=("fleet"); }
verdict="$(printf '%s\n' "$pf_out" | sed '/^[[:space:]]*$/d' | tail -n 1)"

dp_rc=0
dp_out="$(bash "$dispatch" --why --dispositions ${dispatch_args[@]+"${dispatch_args[@]}"} 2>/dev/null)" || dp_rc=$?  # swallow-ok: the rc is kept in dp_rc and read on the next line
if grep -q -E '^# (quota-pause|gh-stall)|open PRs unknown|live workers unknown' <<< "$dp_out" || [ "$dp_rc" -ne 0 ]; then
    unknown+=("dispatcher")
fi
[ -r "$refusals" ] || unknown+=("launch-refusals")

if [ "${#unknown[@]}" -gt 0 ]; then
    for u in "${unknown[@]}"; do printf 'UNKNOWN %s\n' "$u"; done
    exit 3
fi

read -r -d '' PY <<'PYEOF' || true  # swallow-ok: read -d '' exits 1 at the end of the heredoc
import datetime, json, os, re, sys

KEY = re.compile(r'^[A-Z][A-Z0-9_]*-\d+')


def utc(s):
    return datetime.datetime.fromisoformat(s.replace('Z', '+00:00')).astimezone(datetime.timezone.utc)


now = utc(os.environ['TS_NOW'])
since = utc(os.environ['TS_SINCE']) if os.environ['TS_SINCE'] else now - datetime.timedelta(minutes=15)
live, cap = (int(x) for x in os.environ['TS_FLEET'].split())
free = max(cap - live, 0)
verdict = os.environ['TS_VERDICT']
fleet_reason = None if verdict == 'PROCEED' else verdict

listed = []
for ln in os.environ['TS_DISPATCH'].split('\n'):
    m = re.match(r'^# disposition (\S+) listed\b', ln)
    if m and m.group(1) not in listed:
        listed.append(m.group(1))

started, refused = [], []
with open(os.environ['TS_REFUSALS'], encoding='utf-8') as fh:
    for ln in fh:
        try:
            r = json.loads(ln)
            ts = utc(r['ts'])
        except (ValueError, KeyError, TypeError):
            continue
        if not isinstance(r, dict) or not (since <= ts < now):
            continue
        m = KEY.match(str(r.get('name') or os.path.basename(str(r.get('doc') or ''))))
        if not m or m.group(0) not in listed:
            continue
        key = m.group(0)
        if r.get('outcome') == 'attempt-started' and key not in started:
            started.append(key)
        elif r.get('outcome') == 'refused':
            refused.append(dict(key=key, reason=r.get('reason') or r.get('cause') or ''))

silent = []
if free > 0 and fleet_reason is None:
    refused_keys = set(r['key'] for r in refused)
    silent = [k for k in listed if k not in started and k not in refused_keys]

print(json.dumps(dict(ts=now.strftime('%Y-%m-%dT%H:%M:%SZ'), cap=cap, live=live, free=free, fleet_reason=fleet_reason,
                      listed=listed, started=started, refused=refused, silent=silent)))
PYEOF

TS_NOW="$now" TS_SINCE="$since" TS_FLEET="$fleet" TS_VERDICT="$verdict" TS_DISPATCH="$dp_out" TS_REFUSALS="$refusals" \
    python3 -I -c "$PY" || {
    printf 'UNKNOWN sampler-error\n'
    exit 3
}
