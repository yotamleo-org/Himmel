#!/usr/bin/env bash
# Test for scripts/handover/cache-health-line.py: the morning-report cache line
# read from cache-health metrics.json + history.jsonl.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINE="$SCRIPT_DIR/cache-health-line.py"
PASS=0
FAIL=0
TMP_ROOT=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP_ROOT"' EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }
assert_contains() {
    if grep -qF -- "$2" <<< "$3"; then pass "$1"; else fail "$1" "missing: $2 in: $3"; fi
}
assert_not_contains() {
    local rc=0
    grep -qF -- "$2" <<< "$3" || rc=$?
    case "$rc" in
        0) fail "$1" "unexpected: $2 in: $3" ;;
        1) pass "$1" ;;
        *) fail "$1" "grep error rc=$rc" ;;
    esac
}

NOW=1760000000
DAY=86400

# mk_state DIR GEN_AT — metrics.json generated at GEN_AT, empty history.
mk_state() {
    mkdir -p "$1"
    printf '{"schema":1,"generated_at":%s,"overall":{"hit_pct":96.0},"roles":{}}\n' "$2" > "$1/metrics.json"
    : > "$1/history.jsonl"
}
# add_day DIR DAYS_AGO OVERALL CHIEF WORKER SUBAGENT — one history row for that day.
add_day() {
    printf '{"ts":%s,"overall":%s,"roles":{"console":%s,"worker":%s,"subagent":%s,"bridge":null,"other":null}}\n' \
        "$((NOW - $2 * DAY - 3600))" "$3" "$4" "$5" "$6" >> "$1/history.jsonl"
}
run_line() { python3 -I "$LINE" --state-dir "$1" --now "$NOW" 2>&1 || true; }

echo "TEST: missing metrics.json"
OUT=$(run_line "$TMP_ROOT/nope")
assert_contains "missing: explicit unmonitored" "cache: unmonitored (metrics missing)" "$OUT"

echo "TEST: stale metrics.json (>26h)"
mk_state "$TMP_ROOT/stale" $((NOW - 27 * 3600))
OUT=$(run_line "$TMP_ROOT/stale")
assert_contains "stale: explicit unmonitored" "cache: unmonitored (metrics stale)" "$OUT"

echo "TEST: unreadable metrics.json"
mkdir -p "$TMP_ROOT/bad"; echo '{not json' > "$TMP_ROOT/bad/metrics.json"
OUT=$(run_line "$TMP_ROOT/bad")
assert_contains "invalid: explicit unmonitored" "cache: unmonitored (metrics invalid)" "$OUT"

echo "TEST: NaN generated_at is not a fresh pass"
mkdir -p "$TMP_ROOT/nan"; echo '{"schema":1,"generated_at":NaN,"overall":{"hit_pct":96.0}}' > "$TMP_ROOT/nan/metrics.json"
OUT=$(run_line "$TMP_ROOT/nan")
assert_contains "nan: explicit unmonitored" "cache: unmonitored (metrics invalid)" "$OUT"

echo "TEST: future-dated history rows are ignored"
mk_state "$TMP_ROOT/future" $((NOW - 3600))
add_day "$TMP_ROOT/future" 0 98.0 99.0 97.0 90.0
add_day "$TMP_ROOT/future" -3 10.0 10.0 10.0 10.0
OUT=$(run_line "$TMP_ROOT/future")
assert_contains "future: only past row counted" "cache: 7d read ratio 98.0%" "$OUT"

echo "TEST: present, no baseline yet"
mk_state "$TMP_ROOT/fresh" $((NOW - 3600))
for d in 0 1 2; do add_day "$TMP_ROOT/fresh" "$d" 98.0 99.0 97.0 90.0; done
OUT=$(run_line "$TMP_ROOT/fresh")
assert_contains "fresh: 7d ratio" "cache: 7d read ratio 98.0%" "$OUT"
assert_contains "fresh: per kind console" "console 99.0%" "$OUT"
assert_contains "fresh: per kind worker" "worker 97.0%" "$OUT"
assert_contains "fresh: per kind subagent" "subagent 90.0%" "$OUT"
assert_contains "fresh: no baseline" "no baseline yet" "$OUT"
assert_not_contains "fresh: null kinds omitted" "bridge" "$OUT"
# a history row written before the rename keeps the old role key: it reads as worker while legacy names are on
mk_state "$TMP_ROOT/oldkey" $((NOW - 3600))
printf '{"ts":%s,"overall":98.0,"roles":{"console":99.0,"leg":97.0,"subagent":90.0,"bridge":null,"other":null}}\n' "$((NOW - 3600))" >> "$TMP_ROOT/oldkey/history.jsonl"
OUT=$(run_line "$TMP_ROOT/oldkey")
assert_contains "old role key reads as worker" "worker 97.0%" "$OUT"
OUT=$(HIMMEL_LEGACY_NAMES=0 run_line "$TMP_ROOT/oldkey")
assert_not_contains "old role key is ignored with legacy names off" "worker 97.0%" "$OUT"
if [ "$(wc -l <<< "$OUT")" -eq 1 ]; then pass "fresh: exactly one line"; else fail "fresh: exactly one line" "$OUT"; fi

echo "TEST: baseline healthy"
mk_state "$TMP_ROOT/ok" $((NOW - 3600))
for d in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do add_day "$TMP_ROOT/ok" "$d" 98.0 99.0 97.0 95.0; done
OUT=$(run_line "$TMP_ROOT/ok")
assert_contains "ok: baseline shown" "baseline 98.0% (14d median)" "$OUT"
assert_not_contains "ok: no flag" "below baseline" "$OUT"

echo "TEST: below baseline 3 consecutive days"
mk_state "$TMP_ROOT/low" $((NOW - 3600))
for d in 3 4 5 6 7 8 9 10 11 12 13 14 15; do add_day "$TMP_ROOT/low" "$d" 98.0 99.0 97.0 95.0; done
for d in 0 1 2; do add_day "$TMP_ROOT/low" "$d" 90.0 99.0 97.0 95.0; done
OUT=$(run_line "$TMP_ROOT/low")
assert_contains "low: flagged" "below baseline 3d" "$OUT"
assert_contains "low: flag names overall" "overall" "$OUT"

echo "TEST: below baseline only 2 days is not flagged"
mk_state "$TMP_ROOT/two" $((NOW - 3600))
for d in 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do add_day "$TMP_ROOT/two" "$d" 98.0 99.0 97.0 95.0; done
for d in 0 1; do add_day "$TMP_ROOT/two" "$d" 90.0 99.0 97.0 95.0; done
OUT=$(run_line "$TMP_ROOT/two")
assert_not_contains "two: no flag" "below baseline" "$OUT"

echo
echo "test summary: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
