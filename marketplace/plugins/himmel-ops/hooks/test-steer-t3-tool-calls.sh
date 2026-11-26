#!/usr/bin/env bash
# test-steer-t3-tool-calls.sh — suite for the PreToolUse T3 call steer. The suite is the spec.
#
# The behaviour rows run the INSTALLED hooks.json command with CLAUDE_PLUGIN_ROOT on
# this plugin dir, so a hook that is not wired (or wired to the wrong matcher)
# fails the refusal rows. The t3 CLI is a stub the hook reads through T3_STEER_BIN.
#
# Usage: bash marketplace/plugins/himmel-ops/hooks/test-steer-t3-tool-calls.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$HERE/.." && pwd)"
FAILED=0

TMP="$(mktemp -d "${TMPDIR:-/tmp}/steer-t3.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

matcher=$(jq -r '.hooks.PreToolUse[] | select(any(.hooks[]; .command | contains("steer-t3-tool-calls.sh"))) | .matcher' "$PLUGIN_DIR/hooks/hooks.json")
plugin_cmd=$(jq -r '.hooks.PreToolUse[] | select(any(.hooks[]; .command | contains("steer-t3-tool-calls.sh"))) | .hooks[].command' "$PLUGIN_DIR/hooks/hooks.json")

STUB="$TMP/t3"
cat >"$STUB" <<'EOF'
#!/bin/sh
[ ! -e "$STUB_DIR/list.fail" ] || exit 1
cat "$STUB_DIR/list.json"
EOF
chmod +x "$STUB"
cat >"$TMP/list.json" <<'EOF'
[{"threadId":"t-run","title":"running one","status":"running","settled":false},
 {"threadId":"t-idle","title":"idle one","status":"idle","settled":false},
 {"threadId":"t-done","title":"done one","status":"completed","settled":true}]
EOF

wait_payload() {
    jq -n --argjson ids "$1" '{session_id:"s-steer",hook_event_name:"PreToolUse",cwd:"/",tool_name:"mcp__t3-code__t3_background_wait",tool_input:{taskIds:$ids}}'
}
send_payload() {
    jq -n --arg id "$1" --arg m "$2" '{session_id:"s-steer",hook_event_name:"PreToolUse",cwd:"/",tool_name:"mcp__t3-code__t3_thread_send",tool_input:({threadId:$id,message:"hi"} + (if $m == "" then {} else {mode:$m} end))}'
}

run_case() {
    ERR=$(printf '%s' "$1" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PLUGIN_DIR" \
        STUB_DIR="$TMP" T3_STEER_BYPASS=0 T3_STEER_BIN="$STUB" T3_STEER_PROJECT="$TMP" ${2:+"$2"} \
        sh -c "${plugin_cmd:-exit 0}" 2>&1 >/dev/null)
    RC=$?
}

assert_eq() {
    if [ "$3" = "$2" ]; then echo "PASS $1 ($3)"; else echo "FAIL $1 - expected $2, got $3"; FAILED=$((FAILED + 1)); fi
}
assert_contains() {
    case "$3" in
        *"$2"*) echo "PASS $1" ;;
        *) echo "FAIL $1 - did not contain: $2"; echo "  got: $3"; FAILED=$((FAILED + 1)) ;;
    esac
}
allowed() { assert_eq "$1: exit 0" 0 "$RC"; if [ -z "$ERR" ]; then echo "PASS $1: no text"; else echo "FAIL $1: expected no text, got: $ERR"; FAILED=$((FAILED + 1)); fi; }
refused() { assert_eq "$1: refused (exit 2)" 2 "$RC"; assert_contains "$1: names the right call" "$2" "$ERR"; }

assert_eq "wired: one PreToolUse command" 1 "$(printf '%s' "$plugin_cmd" | grep -c steer-t3-tool-calls.sh)"
for t in mcp__t3-code__t3_background_wait mcp__t3-code__t3_thread_send; do
    if grep -Eq "^(${matcher})\$" <<<"$t"; then echo "PASS matcher covers $t"; else echo "FAIL matcher covers $t"; FAILED=$((FAILED + 1)); fi
done
for t in mcp__t3-code__t3_thread_list mcp__t3-code__t3_thread_launch Bash; do
    if grep -Eq "^(${matcher})\$" <<<"$t"; then echo "FAIL matcher leaves $t alone"; FAILED=$((FAILED + 1)); else echo "PASS matcher leaves $t alone"; fi
done

run_case "$(wait_payload '["b001oqmbs"]')"
allowed "a background Bash id passes"

run_case "$(wait_payload '["b001oqmbs","b0304abax"]')"
allowed "two running ids pass"

run_case "$(wait_payload '["a839ea3b49cc59393"]')"
refused "an Agent id" "its result arrives as a message"
assert_contains "an Agent id: quotes the id" '"a839ea3b49cc59393"' "$ERR"

run_case "$(wait_payload '["PLACEHOLDER"]')"
refused "a PLACEHOLDER" "run_in_background"

run_case "$(wait_payload '["b001oqmbs","a839ea3b49cc59393"]')"
refused "one good id beside an Agent id" "its result arrives as a message"

run_case "$(wait_payload '[""]')"
refused "an empty id" "run_in_background"

run_case "$(wait_payload '[12]')"
refused "a non-string id" "run_in_background"

run_case "$(jq -n '{tool_name:"mcp__t3-code__t3_background_wait",tool_input:{}}')"
allowed "no taskIds: the tool's own error stands"

run_case "$(send_payload t-run steer)"
allowed "steer on a running thread passes"

run_case "$(send_payload t-idle steer)"
refused "steer on an idle thread" "no mode"
assert_contains "steer on an idle thread: names the thread state" "t-idle is idle" "$ERR"

run_case "$(send_payload t-done steer)"
refused "steer on a settled thread" "no mode"

run_case "$(send_payload t-idle "")"
allowed "a send with no mode to an idle thread passes"

run_case "$(send_payload t-idle restart)"
allowed "mode restart to an idle thread passes"

run_case "$(send_payload t-unknown steer)"
allowed "steer on a thread not in the list passes (fail open)"

: >"$TMP/list.fail"
run_case "$(send_payload t-idle steer)"
allowed "a failing t3 CLI passes (fail open)"
rm -f "$TMP/list.fail"

printf 'not json' >"$TMP/list.json"
run_case "$(send_payload t-idle steer)"
allowed "an unreadable thread list passes (fail open)"

cat >"$TMP/list.json" <<'EOF'
[{"threadId":"t-idle","title":"idle one","status":"idle","settled":false},
 {"threadId":"t-new","title":"new status","status":"warming","settled":false}]
EOF
run_case "$(send_payload t-idle steer)"
refused "steer on an idle thread, valid list again" "no mode"

run_case "$(send_payload t-idle steer)" "T3_STEER_BIN=$TMP/missing"
allowed "a missing t3 CLI passes (fail open)"

run_case "$(send_payload t-new steer)"
allowed "a status the hook does not know passes (fail open)"

run_case "$(wait_payload '["b001oqmbs\n"]')"
refused "an id with a trailing newline" "run_in_background"

run_case "$(send_payload t-idle steer)" "T3_STEER_BYPASS=1"
allowed "T3_STEER_BYPASS=1 passes a refused steer"

run_case "$(wait_payload '["a839ea3b49cc59393"]')" "T3_STEER_BYPASS=1"
allowed "T3_STEER_BYPASS=1 passes a refused wait"

run_case 'not json at all'
allowed "garbage input passes (fail open)"

run_case "$(jq -n '{tool_name:"mcp__t3-code__t3_thread_list",tool_input:{}}')"
allowed "another T3 tool passes"

if [ "$FAILED" -eq 0 ]; then echo "ALL PASS"; else echo "$FAILED FAILED"; exit 1; fi
