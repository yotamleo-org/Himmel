#!/usr/bin/env bash
# scripts/lib/test-worker-tail-status.sh -- suite for worker_terminal_tail, the one rule that says
# whether a worker's newest status marker plus its queue-lock state mean the worker is finished.
#
# Rows: the truth table (WRAPPED finished; HALTED finished only with the lock free; every other
# marker, and an empty tail, never finished), then the real doc shapes the rule is read from
# (worker_tail_status on a doc that ends WRAPPED then HALTED).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$HERE/worker-tail-status.sh"

W="$(mktemp -d "${TMPDIR:-/tmp}/wts-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$W"' EXIT
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); fi; }

term() { bash -c '. "$1" && worker_terminal_tail "$2" "$3"' _ "$HELPER" "$1" "$2" >/dev/null 2>&1; echo $?; }

check "WRAPPED, lock free: finished" "$(term WRAPPED free)" 0
check "WRAPPED, lock held: finished (the worker wrote its own wrap)" "$(term WRAPPED held)" 0
check "HALTED, lock free: finished" "$(term HALTED free)" 0
check "HALTED, lock held: not finished" "$(term HALTED held)" 1
for m in LIVE READY BLOCKED FINDING RESOLVED RESUMED PARKED-USAGE ''; do
    check "[$m], lock free: not finished" "$(term "$m" free)" 1
done
check "HALTED with an unknown lock state: not finished" "$(term HALTED maybe)" 1

DOC="$W/doc.md"
printf '# t\n\n## Results\n\n- 09:00 LIVE - go\n- 10:00 WRAPPED - done\n- 10:30 HALTED - fleet pause\n' > "$DOC"
tail_marker="$(bash -c '. "$1" && worker_tail_status "$2"' _ "$HELPER" "$DOC")"
check "WRAPPED then HALTED doc reads HALTED" "$tail_marker" HALTED
check "that doc's tail with the lock free is finished" "$(term "$tail_marker" free)" 0
check "that doc's tail with the lock held is not finished" "$(term "$tail_marker" held)" 1

[ "$fails" -eq 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "all ok"
