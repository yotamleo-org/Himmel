#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2012  # A && B || C is the pass/fail reporting idiom; ls only counts fixture files
# test-read-clamp-failure.sh — read-clamp-failure.sh (PostToolUseFailure Read): a
# failed or interrupted Read drops its pending record so the identical retry is
# allowed, and the native oversize error gets a line-aligned smaller native Read
# as guidance (additionalContext, never a permission decision). Fixture payloads
# only; state lives under a temp XDG_RUNTIME_DIR. bash 3.2-safe.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PRE="$HERE/read-clamp.sh"
POST="$HERE/record-read-clamp.sh"
FAILH="${READ_CLAMP_FAILURE:-$HERE/read-clamp-failure.sh}"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

FAILED=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }
has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3' in: $2)" ;; esac; }
lacks() { case "$2" in *"$3"*) fail "$1 (found '$3')" ;; *) pass "$1" ;; esac; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/read-clamp-failure.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT
RT="$WORK/xdg"; mkdir -p "$RT"
F="$WORK/long.txt"; seq 1 3000 > "$F"
ONE="$WORK/oneline.txt"; head -c 300000 /dev/zero | tr '\0' 'a' > "$ONE"; echo >> "$ONE"

pre_json() { # <session> <tid> <path> [offset limit]
    jq -cn --arg s "$1" --arg t "$2" --arg p "$3" --arg o "${4:-}" --arg l "${5:-}" '
        {tool_name:"Read", session_id:$s, tool_use_id:$t,
         tool_input:({file_path:$p} + (if $o != "" then {offset:($o|tonumber)} else {} end)
                     + (if $l != "" then {limit:($l|tonumber)} else {} end))}'
}
fail_json() { # <session> <tid> <path> <offset> <limit> <error> [is_interrupt]
    jq -cn --arg s "$1" --arg t "$2" --arg p "$3" --arg o "$4" --arg l "$5" --arg e "$6" --arg i "${7:-false}" '
        {tool_name:"Read", hook_event_name:"PostToolUseFailure", session_id:$s, tool_use_id:$t,
         tool_input:({file_path:$p} + (if $o != "" then {offset:($o|tonumber)} else {} end)
                     + (if $l != "" then {limit:($l|tonumber)} else {} end)),
         error:$e, is_interrupt:($i == "true")}'
}
run() { # <hook> <json> [env...] -> rc; stdout in $WORK/out
    local h="$1" j="$2"; shift 2
    printf '%s\n' "$j" > "$WORK/in.json"
    env XDG_RUNTIME_DIR="$RT" HIMMEL_CONSOLE_LEG=1 HIMMEL_READ_CLAMP_LINES=5000 "$@" bash "$h" < "$WORK/in.json" >"$WORK/out" 2>"$WORK/err"
    echo $?
}
ctx() { jq -r '.hookSpecificOutput.additionalContext // empty' "$WORK/out" 2>/dev/null; }
decision() { jq -r '.hookSpecificOutput.permissionDecision // .decision // empty' "$WORK/out" 2>/dev/null; }
OVER='File content (61234 tokens) exceeds maximum allowed tokens (25000). Use offset and limit parameters to read specific portions of the file, or search for specific content instead of reading the whole file.'

echo "=== read-clamp-failure.sh ==="
[ -f "$FAILH" ] && pass "the failure hook exists" || fail "no failure hook at $FAILH"

# A failed Read never consumes its range: the identical retry is allowed.
run "$PRE" "$(pre_json s1 t1 "$F" 1 2000)" >/dev/null
run "$FAILH" "$(fail_json s1 t1 "$F" 1 2000 "$OVER")" >/dev/null
run "$POST" "$(jq -cn --arg p "$F" '{tool_name:"Read",session_id:"s1",tool_use_id:"t1",tool_input:{file_path:$p,offset:1,limit:2000},tool_response:{type:"text",file:{filePath:$p,content:"x",startLine:1,numLines:2000,totalLines:3000}}}')" >/dev/null
[ "$(run "$PRE" "$(pre_json s1 t2 "$F" 1 2000)")" = 0 ] && pass "after a failure the identical retry is allowed (a late Post finds no pending record)" || fail "retry after failure denied: $(cat "$WORK/err")"
run "$PRE" "$(pre_json s2 t1 "$F" 1 10)" >/dev/null
run "$FAILH" "$(fail_json s2 t1 "$F" 1 10 "Interrupted by user" true)" >/dev/null
[ "$(run "$PRE" "$(pre_json s2 t2 "$F" 1 10)")" = 0 ] && pass "an interrupted Read never consumes its range" || fail "retry after interrupt denied"

# Oversize guidance: a line-aligned smaller native Read from the reported counts.
rc=$(run "$FAILH" "$(fail_json s3 t1 "$F" 1 2000 "$OVER")")
[ "$rc" = 0 ] && pass "the failure hook exits 0" || fail "rc=$rc"
c="$(ctx)"
[ -z "$(decision)" ] && pass "no permission decision, guidance only" || fail "decision: $(decision)"
[ "$(jq -r '.hookSpecificOutput.hookEventName // empty' "$WORK/out")" = PostToolUseFailure ] && pass "the event name is PostToolUseFailure" || fail "event: $(cat "$WORK/out")"
has "guidance names a smaller native Read from the attempted offset" "$c" "Read file_path=$F offset=1 limit=734"
has "guidance names where to continue" "$c" "offset=735"
has "guidance names the measured counts" "$c" "61234 tokens against a 25000-token limit"
lacks "guidance invents no hard byte limit" "$c" "16 KiB"
rc=$(run "$FAILH" "$(fail_json s3 t2 "$F" 1001 "" "$OVER")")
has "a Read with no limit uses the native 2000-line page from its offset" "$(ctx)" "offset=1001 limit=734"
OVERM='File content (90000 tokens) exceeds maximum allowed tokens (40000). Use offset and limit parameters.'
run "$FAILH" "$(fail_json s3 t3 "$F" 1 1000 "$OVERM")" >/dev/null
has "a runtime limit other than 25k is honoured from the error" "$(ctx)" "limit=400"
run "$FAILH" "$(fail_json s3 t4 "$F" 1 1000 'File content exceeds maximum allowed tokens. Use offset and limit parameters.')" >/dev/null
has "no measured count: halve the attempted lines" "$(ctx)" "limit=500"
run "$FAILH" "$(fail_json s3 t5 "$F" 1 1000 'File content exceeds maximum allowed tokens.')" CLAUDE_CODE_FILE_READ_MAX_OUTPUT_TOKENS=12000 >/dev/null
has "no counts in the error: still halve, env read only as context" "$(ctx)" "limit=500"

# One line that cannot fit: a secret-fenced byte preview as the labelled last resort.
run "$FAILH" "$(fail_json s4 t1 "$ONE" 1 1 'File content (80000 tokens) exceeds maximum allowed tokens (25000).')" >/dev/null
c="$(ctx)"
has "a single over-limit line names a byte preview" "$c" "sed -n '1p'"
has "the preview is labelled bytes, not characters" "$c" "bytes"
has "the preview says it is no Read for Edit/Write" "$c" "read-before-write"
lacks "the preview is not offered as a native Read" "$c" "Read file_path=$ONE offset=1 limit="

# Other failures and shapes: silent.
run "$FAILH" "$(fail_json s5 t1 "$F" 1 10 'File does not exist.')" >/dev/null
[ ! -s "$WORK/out" ] && pass "another error prints nothing" || fail "stdout on another error: $(cat "$WORK/out")"
run "$FAILH" '{"tool_name":"Bash","tool_use_id":"t","session_id":"s","error":"x"}' >/dev/null
[ ! -s "$WORK/out" ] && pass "another tool prints nothing" || fail "stdout for Bash: $(cat "$WORK/out")"
[ "$(run "$FAILH" '{not json')" = 0 ] && [ ! -s "$WORK/out" ] && pass "malformed stdin fails open, silent" || fail "malformed stdin"
printf '%s\n' "$(fail_json s6 t1 "$F" 1 2000 "$OVER")" > "$WORK/gate.json"
[ "$(env XDG_RUNTIME_DIR="$RT" HIMMEL_CONSOLE_LEG=0 bash "$FAILH" < "$WORK/gate.json" 2>/dev/null | wc -c | tr -d ' ')" = 0 ] && pass "gate off: no guidance" || fail "gate off printed guidance"

echo "==============================="
[ "$FAILED" -eq 0 ] && { echo "All cases passed."; exit 0; }
echo "$FAILED case(s) failed."; exit 1
