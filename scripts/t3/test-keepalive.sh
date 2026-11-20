#!/usr/bin/env bash
# scripts/t3/test-keepalive.sh - fixture suite for keepalive.sh.
set -u
unset T3_KEEPALIVE_CHECK_EVERY HIMMEL_T3_CHIEF_TITLES
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
KA="$HERE/keepalive.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/t3ka-test.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
expect_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got: $2)"; fi; }
expect_in() { if grep -q -- "$2" "$3"; then ok "$1"; else bad "$1 (missing: $2)"; fi; }

cat > "$T/t3" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "thread list") cat "$STUB_LIST" ;;
  "thread send") echo "$*" >> "$STUB_LOG"; cat > /dev/null ;;
esac
STUB
chmod +x "$T/t3"
NOW="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
cat > "$T/list.json" <<JSON
[{"threadId":"t1","title":"Manage T3 Code Sync","status":"idle","settled":true,"settledAt":"$NOW"}]
JSON
export T3_SEND_BIN="$T/t3" T3_SEND_PROJECT="$T" STUB_LIST="$T/list.json" STUB_LOG="$T/log"
export T3_KEEPALIVE_POLL=1

W="$T/sub/cochief.wake"
( sleep 2; printf 'go look at PR 9\n' > "$W" ) &
bash "$KA" --wake-file "$W" --max-seconds 20 >"$T/out" 2>&1; rc=$?
wait
expect_eq "wake exits 0" "$rc" 0
expect_in "wake prints WOKEN" "^WOKEN 20" "$T/out"
expect_in "wake prints file contents" "^go look at PR 9$" "$T/out"
expect_eq "wake file removed" "$([ -e "$W" ] && echo present || echo gone)" gone

bash "$KA" --wake-file "$T/never.wake" --max-seconds 2 >"$T/out" 2>&1; rc=$?
expect_eq "timeout exits 0" "$rc" 0
expect_in "timeout prints KEEPALIVE-EXPIRED re-arm" "^KEEPALIVE-EXPIRED 20.* re-arm$" "$T/out"

: > "$T/log"
T3_KEEPALIVE_CHECK_EVERY=2 bash "$KA" --wake-file "$T/never.wake" --max-seconds 4 >"$T/out" 2>&1
expect_in "periodic check prints findings" "^SETTLED t1 Manage T3 Code Sync " "$T/out"
expect_in "periodic check wakes the settled thread" "^thread send t1 -$" "$T/log"

W3="$T/oct.wake"
( sleep 2; printf 'octal ok\n' > "$W3" ) &
T3_KEEPALIVE_CHECK_EVERY=08 bash "$KA" --wake-file "$W3" --max-seconds 20 >"$T/out" 2>&1; rc=$?
wait
expect_eq "leading-zero check-every exits 0" "$rc" 0
expect_in "leading-zero check-every prints WOKEN" "^WOKEN 20" "$T/out"

bash "$KA" --bogus >"$T/out" 2>&1; rc=$?
expect_eq "bad flag exits 2" "$rc" 2
bash "$KA" --max-seconds x >"$T/out" 2>&1; rc=$?
expect_eq "non-numeric max exits 2" "$rc" 2
env T3_KEEPALIVE_POLL='' bash "$KA" --wake-file "$T/never.wake" --max-seconds 2 >"$T/out" 2>&1; rc=$?
expect_eq "empty poll exits 2" "$rc" 2

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
