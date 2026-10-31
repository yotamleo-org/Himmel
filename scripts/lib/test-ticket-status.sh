#!/usr/bin/env bash
# A parked marker after WRAPPED must keep the worker parked, in either spelling.
# Platform guard: POSIX bash 3.2+.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/ticket-status.sh
# shellcheck disable=SC1091
. "$HERE/ticket-status.sh"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/ticket-status-test.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
fails=0
check() {
    if [ "$2" = "$3" ]; then
        echo "ok - $1"
    else
        echo "FAIL - $1: expected [$3] got [$2]"
        fails=$((fails + 1))
    fi
}

# The lock is fresh; the fixture never touches the station's real queue locks.
printf '#!/usr/bin/env bash\nexit 11\n' > "$tmp/lock.sh"
chmod +x "$tmp/lock.sh"
export TICKET_STATUS_QUEUE_LOCK="$tmp/lock.sh"
export QUEUE_LOCK_IDLE_WARN_SECONDS=2700
for marker in PARKED-USAGE PARKED-BANK; do
    printf -- '- 10:00 LIVE — started\n- 10:10 WRAPPED — ended\n- 10:20 %s — usage limit\n' "$marker" > "$tmp/worker.md"
    check "$marker is the newest marker after WRAPPED" "$(ts_marker_newest "$tmp/worker.md")" PARKED-USAGE
    check "$marker reports a parked worker, not wrapped" "$(ts_worker_state "$tmp/worker.md")" parked
    _ts_worker_state "$tmp/worker.md"
    check "$marker still reads its held lock" "$TS_LOCK_HELD" yes
done

printf -- '- 10:30 SUCCESSION accepted: next-chief replaces prior-chief\n' >> "$tmp/worker.md"
check "SUCCESSION after parking remains the newest marker" "$(ts_marker_newest "$tmp/worker.md")" SUCCESSION
check "SUCCESSION after parking resumes a live worker" "$(ts_worker_state "$tmp/worker.md")" live

printf -- '- 10:00 WRAPPED\n- PARKED-USAGE — usage limit\n' > "$tmp/worker.md"
check "untimestamped parked bullet overrides WRAPPED" "$(ts_marker_newest "$tmp/worker.md")" PARKED-USAGE
printf -- '- 10:00 WRAPPED\n- 10:20 **PARKED-USAGE** — usage limit\n' > "$tmp/worker.md"
check "bold parked bullet overrides WRAPPED" "$(ts_marker_newest "$tmp/worker.md")" PARKED-USAGE

# A wrapped primary owner cannot end a ticket still held by a parked second doc.
export TICKET_STATUS_STATE_DIR="$tmp/state" TS_SNAPSHOT_DIR="$tmp/snap" TS_EVENT=sweep
mkdir -p "$TICKET_STATUS_STATE_DIR/workers" "$TS_SNAPSHOT_DIR"
printf 'HIMMEL-9001\tTask\tIn Progress\n' > "$TS_SNAPSHOT_DIR/jira.tsv"
printf '[]\n' > "$TS_SNAPSHOT_DIR/prs.json"
printf -- '- 10:00 WRAPPED — primary ended\n' > "$tmp/owner.md"
for marker in PARKED-USAGE PARKED-BANK; do
    printf -- '- 10:00 LIVE\n- 10:20 %s — usage limit\n' "$marker" > "$tmp/parked.md"
    jq -nc --arg doc "$tmp/owner.md" --arg other "$tmp/parked.md" \
        '{doc:$doc,docs:[$doc,$other],prs:{}}' > "$TICKET_STATUS_STATE_DIR/workers/HIMMEL-9001.json"
    ts_derive HIMMEL-9001
    check "$marker second owner keeps the ticket In Progress" "$TS_WORKER_STATE/$TS_RULE/$TS_DERIVED" 'parked/D5/In Progress'
    check "$marker second owner is recorded as the lock holder" "$TS_OWNER_DOC" "$tmp/parked.md"
done

if [ "$fails" -eq 0 ]; then
    echo "PASS - test-ticket-status.sh"
else
    echo "FAIL - test-ticket-status.sh: $fails failure(s)"
    exit 1
fi
