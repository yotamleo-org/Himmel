#!/usr/bin/env bash
# Smoke test for scripts/cleanup/codex-sweep-cadence.sh.
#
# Single daily task (HIMMEL-CodexOrphanSweep) fires a runner .bat that runs
# scripts/cleanup/sweep-codex-orphans.ps1 -Kill then scripts/codex/
# reap-mcp-fleet.ps1 -Kill via a resolved pwsh/powershell. This suite keeps the
# malformed-input rc-1 path and the POSIX rc-2 refusal path: pure-unit /
# platform-detect checks (they short-circuit before any schtasks call).
set -euo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone.
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/codex-sweep-cadence.sh"

PASS=0
FAIL=0
TMP_ROOT=""

# shellcheck disable=SC2329,SC2317
cleanup() {
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }
assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if grepq "$haystack" -F -- "$needle"; then pass "$name"; else fail "$name" "missing: $needle"; fi
}
assert_not_contains() {
    local name="$1" needle="$2" haystack="$3"
    if grepq "$haystack" -F -- "$needle"; then fail "$name" "unexpected: $needle"; else pass "$name"; fi
}
assert_rc() {
    local name="$1" want="$2" got="$3"
    if [ "$got" = "$want" ]; then pass "$name"; else fail "$name" "expected rc=$want, got rc=$got"; fi
}
assert_registry() {
    local name="$1" expression="$2"
    if jq -e "$expression" "$HIMMEL_OBSERVABILITY_CONFIG" >/dev/null 2>&1; then pass "$name"; else fail "$name" "registry assertion failed: $expression"; fi
}
summary() {
    echo
    echo "===================================="
    echo "test summary: $PASS passed, $FAIL failed"
    echo "===================================="
    [ "$FAIL" -gt 0 ] && exit 1 || exit 0
}

TMP_ROOT=$(mktemp -d)

REAL_BASH="$(command -v bash)"

export HOME="$TMP_ROOT/home"
export HIMMEL_OBSERVABILITY_CONFIG="$TMP_ROOT/observability.json"
mkdir -p "$HOME"

# ============================================================================
# Pure / platform-detect suite: --time validation happens BEFORE the platform
# gate (T4), and the platform gate itself is the very first schtasks-touching
# decision (T5).
# ============================================================================

echo "TEST: malformed --time rejected before the platform gate (T4)"
rc=0; out=$(env HOME="$HOME" "$REAL_BASH" "$SCRIPT" arm --time 23:5 2>&1) || rc=$?
assert_rc "malformed --time -> rc 1 (all platforms)" 1 "$rc"
assert_contains "malformed --time message" "--time" "$out"

echo "TEST: --time with no value -> rc 1, usage message, not a raw bash shift error (FIX 3 / coderabbit-1)"
rc=0; out=$(env HOME="$HOME" "$REAL_BASH" "$SCRIPT" arm --time 2>&1) || rc=$?
assert_rc "arm --time (missing value) -> rc 1" 1 "$rc"
assert_contains "arm --time (missing value) message" "--time requires a value" "$out"
assert_not_contains "arm --time (missing value) is not a raw bash shift error" "shift count" "$out"

echo "TEST: non-Windows platform refused Windows-only (T5)"
rc=0; out=$(env HOME="$HOME" OSTYPE=linux-gnu "$REAL_BASH" "$SCRIPT" arm 2>&1) || rc=$?
assert_rc "POSIX platform -> rc 2" 2 "$rc"
assert_contains "POSIX platform message" "Windows-only" "$out"
rc=0; out=$(env HOME="$HOME" OSTYPE=darwin20 "$REAL_BASH" "$SCRIPT" arm 2>&1) || rc=$?
assert_rc "macOS platform -> rc 2" 2 "$rc"

echo "TEST: usage errors"
rc=0; out=$(env HOME="$HOME" "$REAL_BASH" "$SCRIPT" 2>&1) || rc=$?
assert_rc "no subcommand -> rc 1" 1 "$rc"
rc=0; out=$(env HOME="$HOME" "$REAL_BASH" "$SCRIPT" frobnicate 2>&1) || rc=$?
assert_rc "unknown subcommand -> rc 1" 1 "$rc"

echo "TEST: --time is arm-only -> rc 1 on status/disarm (even well-formed)"
rc=0; out=$(env HOME="$HOME" "$REAL_BASH" "$SCRIPT" status --time 09:00 2>&1) || rc=$?
assert_rc "status --time -> rc 1" 1 "$rc"
assert_contains "status --time message" "--time is arm-only" "$out"
rc=0; out=$(env HOME="$HOME" "$REAL_BASH" "$SCRIPT" disarm --time 09:00 2>&1) || rc=$?
assert_rc "disarm --time -> rc 1" 1 "$rc"
assert_contains "disarm --time message" "--time is arm-only" "$out"

summary
