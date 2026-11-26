#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/measurements/gh-core-per-token.sh"
passes=0
fails=0
ok() { echo "ok - $1"; passes=$((passes + 1)); }
bad() { echo "FAIL - $1" >&2; [ $# -lt 2 ] || printf '    %s\n' "$2" >&2; fails=$((fails + 1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ghct-test.XXXXXX")" || { echo "FAIL - mktemp -d failed" >&2; exit 1; }
if [ -z "$TMP" ] || [ ! -d "$TMP" ]; then echo "FAIL - no temp dir" >&2; exit 1; fi
trap 'rm -rf "$TMP"' EXIT

mkstub() {
    printf '#!/usr/bin/env bash\nprintf '"'"'{"resources":{"core":{"limit":5000,"used":%s,"remaining":%s,"reset":%s}}}\\n'"'"'\n' "$2" "$((5000 - $2))" "$3" > "$1"
    chmod +x "$1"
}
mkstub "$TMP/main-ok" 1200 1700003600
mkstub "$TMP/read-ok" 340 1700003600
printf '#!/usr/bin/env bash\necho "HTTP 401" >&2\nexit 1\n' > "$TMP/read-bad"; chmod +x "$TMP/read-bad"

LOG1="$TMP/sample.log"
GHCT_MAIN_CMD="$TMP/main-ok" GHCT_READ_CMD="$TMP/read-ok" GHCT_NOW=1700000000 bash "$SCRIPT" sample --log "$LOG1"
rc=$?
want=$(printf '1700000000\tmain\t1200\t5000\t1700003600\n1700000000\tread\t340\t5000\t1700003600')
if [ "$rc" -eq 0 ] && [ "$(cat "$LOG1" 2>/dev/null)" = "$want" ]; then ok "sample writes one row per token"
else bad "sample writes one row per token" "rc=$rc log=$(cat "$LOG1" 2>/dev/null)"; fi

LOG="$TMP/fixture.log"
{
  printf '1000\tmain\t100\t5000\t4000\n'
  printf '1000\tread\t10\t5000\t4000\n'
  printf '1300\tmain\t160\t5000\t4000\n'
  printf '1300\tread\t30\t5000\t4000\n'
  printf '1600\tmain\t250\t5000\t4000\n'
  printf '1600\tread\t70\t5000\t4000\n'
} > "$LOG"
EXPECT=$(printf '%s\n' \
  "token	samples	seconds	calls	calls/hour" \
  "main	3	600	150	900.0" \
  "read	3	600	60	360.0")

got=$(bash "$SCRIPT" report --log "$LOG")
if [ "$got" = "$EXPECT" ]; then ok "report gives core calls an hour per token"
else bad "report gives core calls an hour per token" "$got"; fi

LOGR="$TMP/reset.log"
{
  printf '1000\tmain\t4900\t5000\t4000\n'
  printf '1300\tmain\t4990\t5000\t4000\n'
  printf '1600\tmain\t20\t5000\t7600\n'
  printf '1900\tmain\t80\t5000\t7600\n'
} > "$LOGR"
got=$(bash "$SCRIPT" report --log "$LOGR")
want=$(printf '%s\n' "token	samples	seconds	calls	calls/hour" "main	4	600	150	900.0")
if [ "$got" = "$want" ]; then ok "report leaves a reset-crossing interval out"
else bad "report leaves a reset-crossing interval out" "$got"; fi

LOGD="$TMP/dropped.log"
grep -v '^1300	main' "$LOG" > "$LOGD"
got=$(bash "$SCRIPT" report --log "$LOGD")
if [ "$got" != "$EXPECT" ]; then ok "RED control: a dropped sample changes the table"
else bad "RED control: a dropped sample changes the table" "$got"; fi

got=$(bash "$SCRIPT" report --log "$LOG" --from 1000 --to 1300)
want=$(printf '%s\n' "token	samples	seconds	calls	calls/hour" "main	2	300	60	720.0" "read	2	300	20	240.0")
if [ "$got" = "$want" ]; then ok "report --from/--to counts only the window"
else bad "report --from/--to counts only the window" "$got"; fi

LOG6="$TMP/bad.log"
GHCT_MAIN_CMD="$TMP/main-ok" GHCT_READ_CMD="$TMP/read-bad" GHCT_NOW=1700000000 bash "$SCRIPT" sample --log "$LOG6" 2>"$TMP/bad.err"
rc=$?
want=$(printf '1700000000\tmain\t1200\t5000\t1700003600')
if [ "$rc" -eq 1 ] && [ "$(cat "$LOG6" 2>/dev/null)" = "$want" ] && grep -q 'read' "$TMP/bad.err"; then ok "an unreadable token writes no row, keeps the other, exits 1"
else bad "an unreadable token writes no row, keeps the other, exits 1" "rc=$rc log=$(cat "$LOG6" 2>/dev/null) err=$(cat "$TMP/bad.err")"; fi

LOG7="$TMP/loop.log"
printf '%s\n' '#!/usr/bin/env bash' "echo \"\$1\" >> \"$TMP/slept\"" > "$TMP/sleep-stub"; chmod +x "$TMP/sleep-stub"
GHCT_MAIN_CMD="$TMP/main-ok" GHCT_READ_CMD="$TMP/read-ok" GHCT_SLEEP_CMD="$TMP/sleep-stub" GHCT_NOW=1700000000 \
    bash "$SCRIPT" loop --log "$LOG7" --interval 300 --samples 3
rc=$?
rows=$(wc -l < "$LOG7" 2>/dev/null | tr -d ' ')
slept=$(tr '\n' ' ' < "$TMP/slept" 2>/dev/null)
if [ "$rc" -eq 0 ] && [ "$rows" = 6 ] && [ "$slept" = "300 300 " ]; then ok "loop takes N samples with the sleep seam between them"
else bad "loop takes N samples with the sleep seam between them" "rc=$rc rows=$rows slept=$slept"; fi

GHCT_MAIN_CMD="$TMP/main-ok" GHCT_READ_CMD="$TMP/read-ok" GHCT_NOW=1700000000 bash "$SCRIPT" sample --log "$TMP/no-such-dir/x.log" 2>"$TMP/w.err"
rc=$?
if [ "$rc" -eq 1 ] && grep -q 'cannot write' "$TMP/w.err"; then ok "an unwritable log exits 1 and says so"
else bad "an unwritable log exits 1 and says so" "rc=$rc err=$(cat "$TMP/w.err")"; fi

echo "passes=$passes fails=$fails"
[ "$fails" -eq 0 ]
