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
for marker in PARKED-USAGE PARKED-BANK; do
    printf -- '- 10:00 LIVE — started\n- 10:10 WRAPPED — ended\n- 10:20 %s — usage limit\n' "$marker" > "$tmp/worker.md"
    check "$marker is the newest marker after WRAPPED" "$(ts_marker_newest "$tmp/worker.md")" PARKED-USAGE
    check "$marker reports a parked worker, not wrapped" "$(ts_worker_state "$tmp/worker.md")" parked
done

printf -- '- 10:30 SUCCESSION accepted: next-chief replaces prior-chief\n' >> "$tmp/worker.md"
check "SUCCESSION after parking remains the newest marker" "$(ts_marker_newest "$tmp/worker.md")" SUCCESSION
check "SUCCESSION after parking resumes a live worker" "$(ts_worker_state "$tmp/worker.md")" live

if [ "$fails" -eq 0 ]; then
    echo "PASS - test-ticket-status.sh"
else
    echo "FAIL - test-ticket-status.sh: $fails failure(s)"
    exit 1
fi
