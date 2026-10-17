#!/usr/bin/env bash
# test-result.sh — tests for scripts/lib/result.sh (tri-state ok/fail/unknown).
# Exit: 0 all passed, 1 any failed. bash 3.2-safe.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
LIB="$SELF_DIR/result.sh"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }
check() { # <label> <got> <want>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 -> got '$2', want '$3'"; fi
}

if [ ! -f "$LIB" ]; then
    echo "FAIL: $LIB does not exist yet (RED)"
    exit 1
fi
# shellcheck source=result.sh
. "$LIB"

run_or_unknown true; rc=$?
check "exit 0 -> rc 0" "$rc" "0"
check "exit 0 -> state ok" "$RESULT_STATE" "ok"

run_or_unknown false; rc=$?
check "exit 1 -> rc 1" "$rc" "1"
check "exit 1 -> state fail" "$RESULT_STATE" "fail"

run_or_unknown bash -c 'exit 2'; rc=$?
check "exit 2 -> rc 2" "$rc" "2"
check "exit 2 -> state unknown" "$RESULT_STATE" "unknown"

run_or_unknown this-command-does-not-exist-6016 2>/dev/null; rc=$?
check "missing command (127) -> unknown" "$RESULT_STATE" "unknown"
check "missing command keeps rc 2" "$rc" "2"

run_or_unknown bash -c 'exit 124'
check "timeout-shaped exit 124 -> unknown" "$RESULT_STATE" "unknown"

run_or_unknown printf 'a\nb\n'
check "stdout captured in RESULT_OUT" "$RESULT_OUT" "$(printf 'a\nb')"
run_or_unknown bash -c 'exit 2'
check "RESULT_OUT cleared by the next run" "$RESULT_OUT" ""
check "RESULT_RC holds the real exit code" "$RESULT_RC" "2"

# unknown is never rendered as OK
run_or_unknown bash -c 'exit 2'
check "render unknown" "$(result_render)" "UNKNOWN"
run_or_unknown true;  check "render ok" "$(result_render)" "OK"
run_or_unknown false; check "render fail" "$(result_render)" "FAIL"

# require_ok
require_ok "probe" true 2>/dev/null; check "require_ok ok -> 0" "$?" "0"
require_ok "probe" false 2>/dev/null; check "require_ok fail -> 1" "$?" "1"
require_ok "probe" bash -c 'exit 2' 2>/dev/null; check "require_ok unknown -> 2" "$?" "2"
msg="$(require_ok "reg-read" bash -c 'exit 2' 2>&1)"
case "$msg" in *"reg-read"*UNKNOWN*) pass "require_ok names label and UNKNOWN on stderr" ;; *) fail "require_ok stderr: $msg" ;; esac
msg="$(require_ok "reg-read" true 2>&1)"
check "require_ok ok is silent" "$msg" ""

echo "test-result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
