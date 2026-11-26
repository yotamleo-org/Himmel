#!/usr/bin/env bash
# test-chief-load-report.sh - chief-load-report.py on fixture rows only, never a live record.
# The seven-shift fixture is the chief-split review's shifts DB to DH (fit-r2.out): workers mean,
# hours, context at the first waiter arm and the peak context.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
R="$HERE/chief-load-report.py"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/chief-load-report.XXXXXX")" || exit 1
trap 'rm -rf "$tmp"' EXIT
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); fi; }

row() {
    printf '{"schema":1,"shift":"%s","workers_mean":%s,"hours":%s,"ctx_start":%s,"ctx_end":%s,"reason":"%s"}\n' "$@"
}
B="$tmp/bucket"; mkdir -p "$B"
{
    row DB 13.0 1.388 87643 459446 fill
    row DC 18.0 1.079 106082 463487 fill
    row DD 20.0 0.736 97623 420825 fill
    row DE 21.5 1.609 99554 458597 fill
    row DF 19.0 0.864 106580 437931 fill
    row DG 17.0 0.955 102888 449391 fill
    row DH 23.5 0.953 95539 480011 operator-asked
} > "$B/chief-load.jsonl"

out="$(python3 "$R" "$B")"; rc=$?
check "the report on the seven review shifts exits 0" "$rc" "0"
check "the report prints about 17,400 tokens per live worker-hour" "$(printf '%s\n' "$out" | grep -c '^tokens per live worker-hour: 17,442$')" "1"
check "the report prints the start-up context" "$(printf '%s\n' "$out" | grep -c '^start-up context (median at the first waiter arm): 99,554$')" "1"
check "the report prints 1.08 h at 18.7 workers" "$(printf '%s\n' "$out" | grep -c '^T(18.7) = 1.08 h')" "1"
check "the report prints one line per shift with its handover reason" "$(printf '%s\n' "$out" | grep -c '^shift D[B-H] .* reason ')" "7"
check "the report carries the last shift's reason" "$(printf '%s\n' "$out" | grep -c '^shift DH .* reason operator-asked$')" "1"

out="$(python3 "$R" "$B/chief-load.jsonl" --last 2)"
check "--last 2 prints the last two shifts" "$(printf '%s\n' "$out" | grep '^shift ' | cut -d' ' -f2 | tr '\n' ' ')" "DG DH "
check "--last 2 pools only those two shifts" "$(printf '%s\n' "$out" | grep -c '^shifts 2 of 2,')" "1"

out="$(python3 "$R" "$B" --workers 40)"
check "--workers sets N for T(N)" "$(printf '%s\n' "$out" | grep -c '^T(40.0) = 0.51 h')" "1"

printf '{"schema":1,"shift":"DX","workers_mean":20,"hours":null,"ctx_start":null,"ctx_end":400000,"reason":"unstated"}\n' >> "$B/chief-load.jsonl"
out="$(python3 "$R" "$B" --last 8)"
check "a row missing a field is listed with dashes" "$(printf '%s\n' "$out" | grep -c '^shift DX workers 20.0 hours - start - end 400000 per-worker-hour - reason unstated$')" "1"
check "a row missing a field is left out of the pooled figures" "$(printf '%s\n' "$out" | grep -c '^shifts 7 of 8,')" "1"

rc=0; python3 "$R" "$tmp/none" >/dev/null 2>&1 || rc=$?
check "a missing record exits 2" "$rc" "2"
printf '{"schema":1,"shift":"DY","workers_mean":0,"hours":1,"ctx_start":1,"ctx_end":2}\n' > "$tmp/empty.jsonl"
rc=0; python3 "$R" "$tmp/empty.jsonl" >/dev/null 2>&1 || rc=$?
check "a record with no usable row exits 3" "$rc" "3"

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
