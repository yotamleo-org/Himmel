#!/usr/bin/env bash
# test-block-busy-loop.sh — suite for the PreToolUse sleepless busy-loop deny.
# The suite is the spec.
#
# Every case runs the INSTALLED hooks.json command with CLAUDE_PLUGIN_ROOT on
# this plugin dir, so a wiring that points at $CLAUDE_PROJECT_DIR/scripts/hooks/
# (an --optional no-op outside himmel) reads as allow and fails the deny rows.
#
# Usage: bash marketplace/plugins/himmel-ops/hooks/test-block-busy-loop.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$HERE/.." && pwd)"
HIMMEL_ROOT="$(cd "$HERE/../../../.." && pwd)"
FAILED=0

TMP="$(mktemp -d "${TMPDIR:-/tmp}/busy-loop.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT
git init -q "$TMP/repo"
LOG="$TMP/deny.jsonl"

plugin_cmd=$(jq -r '.hooks.PreToolUse[].hooks[].command | select(contains("block-busy-loop.sh"))' "$PLUGIN_DIR/hooks/hooks.json")

j_bash() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)"; }

# run_case <payload> <project dir> [VAR=value]: sets RC and ERR.
run_case() {
    rm -f "$LOG"
    ERR=$(cd "$2" && printf '%s' "$1" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
        CLAUDE_PROJECT_DIR="$2" BUSY_LOOP_LOG="$LOG" ${3:+"$3"} \
        sh -c "${plugin_cmd:-exit 0}" 2>&1 >/dev/null)
    RC=$?
}

assert_eq() {
    if [ "$3" = "$2" ]; then
        echo "PASS $1 ($3)"
    else
        echo "FAIL $1 - expected $2, got $3"
        FAILED=$((FAILED + 1))
    fi
}

assert_contains() {
    case "$3" in
        *"$2"*) echo "PASS $1" ;;
        *) echo "FAIL $1 - message did not contain: $2"
           echo "  got: $3"
           FAILED=$((FAILED + 1)) ;;
    esac
}

rows() { wc -l <"$LOG" 2>/dev/null | tr -d ' '; }

# An adopter repo (not himmel) gets the guard from the plugin.
busy_payload='{"session_id":"s-busy","tool_name":"Bash","tool_input":{"command":"until [ -f /tmp/x ]; do :; done"}}'
run_case "$busy_payload" "$TMP/repo"
assert_eq "adopter: busy loop denied" 2 "$RC"
assert_contains "adopter: deny names sleep" "sleep" "$ERR"
case "$ERR" in
    *scripts/*|*quiet-run*|*QUIET_RUN*)
        echo "FAIL adopter: deny names a himmel script: $ERR"
        FAILED=$((FAILED + 1)) ;;
    *) echo "PASS adopter: deny names no himmel script" ;;
esac
n=$(jq -c 'select(.session_id == "s-busy" and .decision == "deny" and .loop == "until" and .body == ":")' "$LOG" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "adopter: one JSONL row with the session_id" 1 "$n"
run_case "$(j_bash "until pgrep -f clear-review-marker.sh && false; do :; done")" "$TMP/repo"
assert_eq "deny: do : loop" 2 "$RC"
run_case "$(j_bash "while true; do true; done")" "$TMP/repo"
assert_eq "deny: do true loop" 2 "$RC"
run_case "$(j_bash "while kill -0 1234; do sleep 2; done")" "$TMP/repo"
assert_eq "allow: sleep in the body" 0 "$RC"
run_case "$(j_bash "for x in a b; do :; done")" "$TMP/repo"
assert_eq "allow: finite for do :" 0 "$RC"
[ -e "$LOG" ] && present=yes || present=no
assert_eq "allow writes no row" no "$present"
run_case "$busy_payload" "$TMP/repo" BUSY_LOOP_BYPASS=1
assert_eq "bypass BUSY_LOOP_BYPASS=1" 0 "$RC"

# A himmel session: the project chain's require-quiet-run.sh leaves the busy
# loop alone and the plugin hook refuses it, one deny and one JSONL row.
quiet_run="$HIMMEL_ROOT/scripts/hooks/require-quiet-run.sh"
if [ -f "$quiet_run" ]; then
    printf '%s' "$busy_payload" | bash "$quiet_run" >/dev/null 2>&1
    assert_eq "himmel chain: require-quiet-run.sh allows the busy loop" 0 "$?"
    run_case "$busy_payload" "$HIMMEL_ROOT"
    assert_eq "himmel chain: plugin hook denies" 2 "$RC"
    assert_eq "himmel chain: one JSONL row" 1 "$(rows)"
else
    echo "SKIP himmel chain: no require-quiet-run.sh at $quiet_run"
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "All block-busy-loop.sh cases passed."
    exit 0
fi
echo "$FAILED case(s) failed."
exit 1
