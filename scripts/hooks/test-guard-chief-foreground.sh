#!/usr/bin/env bash
# Tests for scripts/hooks/guard-chief-foreground.sh.
#
# Usage: bash scripts/hooks/test-guard-chief-foreground.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/guard-chief-foreground.sh"
LIST="$SCRIPT_DIR/../handover/chief-kit/long-running.txt"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/himmel-chief-fg.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

# NUL-delimited argv fixtures for the session-name seam (scripts/lib/session-name.sh)
printf 'claude\0-n\0N-chief\0' > "$TMP/cmdline-chief"
printf 'claude\0-n\0N2262-HIMMEL-5821-worker\0' > "$TMP/cmdline-worker"
printf 'claude\0-n\0N-roadmap-chief\0' > "$TMP/cmdline-chief"

ok()  { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }

# run_hook <console:yes|no> <command> <background:true|false|absent> [extra env...]
# Prints "<rc>|<stdout+stderr>".
run_hook() {
    local chief="$1" cmd="$2" bg="$3" payload out rc
    shift 3
    case "$bg" in
        true)   payload=$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c,run_in_background:true}}') ;;
        false)  payload=$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c,run_in_background:false}}') ;;
        *)      payload=$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}') ;;
    esac
    if [ "$chief" = yes ]; then
        out=$(printf '%s' "$payload" | env HIMMEL_CONSOLE_DOC=/x/N-chief.md CLAUDE_PID=1 SESSION_NAME_CMDLINE_FILE="$TMP/cmdline-chief" CHIEF_FG_LIST="$LIST" "$@" bash "$HOOK" 2>&1)
    else
        out=$(printf '%s' "$payload" | env -u HIMMEL_CONSOLE_DOC CHIEF_FG_LIST="$LIST" "$@" bash "$HOOK" 2>&1)
    fi
    rc=$?
    printf '%s|%s' "$rc" "$out"
}

expect() {
    local label="$1" want_rc="$2" got="$3" needle="${4:-}"
    local rc="${got%%|*}" body="${got#*|}"
    if [ "$rc" != "$want_rc" ]; then
        bad "$label — expected rc=$want_rc, got rc=$rc: $body"
        return
    fi
    if [ -n "$needle" ] && ! grep -qF -- "$needle" <<< "$body"; then
        bad "$label — output lacks '$needle': $body"
        return
    fi
    ok "$label (rc=$rc)"
}

[ -f "$HOOK" ] || { bad "hook present: $HOOK"; echo "$pass passed, $fail failed"; exit 1; }
[ -f "$LIST" ] || { bad "list present: $LIST"; echo "$pass passed, $fail failed"; exit 1; }

K="bash scripts/handover/chief-kit"

# --- the headline DoD rows
expect "chief, foreground wrap-merged.sh: denied" 2 \
    "$(run_hook yes "$K/wrap-merged.sh --pr 12" absent)" "run_in_background"
expect "chief, foreground wrap-merged.sh: deny names the script" 2 \
    "$(run_hook yes "$K/wrap-merged.sh --pr 12" absent)" "wrap-merged.sh"
expect "chief, explicit run_in_background=false: denied" 2 \
    "$(run_hook yes "$K/wrap-merged.sh --pr 12" false)" "run_in_background"
expect "chief, wrap-merged.sh with run_in_background=true: allowed" 0 \
    "$(run_hook yes "$K/wrap-merged.sh --pr 12" true)"
expect "worker (no HIMMEL_CONSOLE_DOC), foreground wrap-merged.sh: allowed" 0 \
    "$(run_hook no "$K/wrap-merged.sh --pr 12" absent)"

# a worker launched from the chief inherits HIMMEL_CONSOLE_DOC; only the session name tells them apart
payload_worker=$(jq -nc --arg c "$K/ready-check.sh --only 7 12" '{tool_name:"Bash",tool_input:{command:$c}}')
out=$(printf '%s' "$payload_worker" | env HIMMEL_CONSOLE_DOC=/x/N-chief.md CLAUDE_PID=1 SESSION_NAME_CMDLINE_FILE="$TMP/cmdline-worker" CHIEF_FG_LIST="$LIST" bash "$HOOK" 2>&1); rc=$?
expect "worker session name with inherited HIMMEL_CONSOLE_DOC, foreground ready-check.sh: allowed" 0 "$rc|$out"
out=$(printf '%s' "$payload_worker" | env -u CLAUDE_PID HIMMEL_CONSOLE_DOC=/x/N-chief.md CHIEF_FG_LIST="$LIST" bash "$HOOK" 2>&1); rc=$?
expect "unresolvable session name: fails open" 0 "$rc|$out"
# a session named *-chief is a chief exactly as a *-console one is
payload_wrap=$(jq -nc --arg c "$K/wrap-merged.sh --pr 12" '{tool_name:"Bash",tool_input:{command:$c}}')
out=$(printf '%s' "$payload_wrap" | env HIMMEL_CONSOLE_DOC=/x/N-roadmap-chief.md CLAUDE_PID=1 SESSION_NAME_CMDLINE_FILE="$TMP/cmdline-chief" CHIEF_FG_LIST="$LIST" bash "$HOOK" 2>&1); rc=$?
expect "chief-named session, foreground wrap-merged.sh: denied like a chief" 2 "$rc|$out" "run_in_background"

# --- the short scripts stay foreground
for s in append-results.sh go.sh write-verdict.sh fleet-manifest.sh; do
    expect "chief, foreground $s: allowed" 0 "$(run_hook yes "$K/$s x" absent)"
    if grep -qxF "$s" "$LIST"; then bad "list must not name $s"; else ok "list omits $s"; fi
done

# --- invocation shapes
expect "chief, absolute path via bash: denied" 2 \
    "$(run_hook yes "bash /repo/scripts/handover/chief-kit/close-wrapped-worker.sh worker" absent)"
expect "chief, node script (board.mjs): denied" 2 \
    "$(run_hook yes "node scripts/handover/chief-kit/board.mjs" absent)"
expect "chief, direct path execution: denied" 2 \
    "$(run_hook yes "scripts/handover/chief-kit/ready-check.sh 12 abc" absent)"
expect "chief, chained after another command: denied" 2 \
    "$(run_hook yes "cd /x && bash scripts/handover/chief-kit/verdict-go.sh a b" absent)"

# --- a mention is not a run
expect "chief, git grep naming a listed script: allowed" 0 \
    "$(run_hook yes "git grep -n wrap-merged.sh -- scripts" absent)"
expect "chief, grep with an interpreter-named argument: allowed" 0 \
    "$(run_hook yes "grep bash scripts/handover/chief-kit/ready-check.sh" absent)"
expect "chief, longer name sharing a prefix: allowed" 0 \
    "$(run_hook yes "$K/wrap-merged.sh.bak" absent)"
expect "chief, unrelated command: allowed" 0 "$(run_hook yes "ls -la" absent)"

# --- bounded foreground: `timeout <=90` as the outermost command
expect "chief, timeout 90 ready-check.sh: allowed" 0 \
    "$(run_hook yes "timeout 90 $K/ready-check.sh 12 abc" absent)"
expect "chief, timeout 90 node board.mjs: allowed" 0 \
    "$(run_hook yes "timeout 90 node scripts/handover/chief-kit/board.mjs" absent)"
expect "chief, timeout 90s: allowed" 0 \
    "$(run_hook yes "timeout 90s $K/verdict-go.sh a b" absent)"
expect "chief, timeout 1.5m: allowed" 0 \
    "$(run_hook yes "timeout 1.5m $K/verdict-go.sh a b" absent)"
expect "chief, timeout 600: denied" 2 \
    "$(run_hook yes "timeout 600 $K/ready-check.sh 12 abc" absent)" "run_in_background"
expect "chief, timeout 91: denied" 2 \
    "$(run_hook yes "timeout 91 $K/ready-check.sh 12 abc" absent)"
expect "chief, timeout 0 (no limit): denied" 2 \
    "$(run_hook yes "timeout 0 $K/ready-check.sh 12 abc" absent)"
expect "chief, timeout 2m: denied" 2 \
    "$(run_hook yes "timeout 2m $K/ready-check.sh 12 abc" absent)"
expect "chief, timeout 90 chief-wait.sh (unbounded waiter): denied" 2 \
    "$(run_hook yes "timeout 90 $K/chief-wait.sh --doc x" absent)"
expect "chief, timeout 90 console-wait.sh (the old waiter name): denied" 2 \
    "$(run_hook yes "timeout 90 $K/console-wait.sh --doc x" absent)"
expect "chief, timeout 90 run-suite.sh (suite): denied" 2 \
    "$(run_hook yes "timeout 90 $K/run-suite.sh x" absent)"
expect "chief, timeout -k 999 90: denied" 2 \
    "$(run_hook yes "timeout -k 999 90 $K/ready-check.sh 12 abc" absent)"
expect "chief, timeout not outermost (chained before): denied" 2 \
    "$(run_hook yes "true; timeout 90 $K/ready-check.sh 12 abc" absent)"
expect "chief, timeout 90 then a chained command: denied" 2 \
    "$(run_hook yes "timeout 90 $K/ready-check.sh 12 abc; sleep 600" absent)"
expect "chief, timeout 90 piped: denied" 2 \
    "$(run_hook yes "timeout 90 $K/ready-check.sh 12 abc | cat" absent)"
expect "chief, timeout 90 with command substitution: denied" 2 \
    "$(run_hook yes "timeout 90 $K/ready-check.sh \$(sleep 600)" absent)"
expect "chief, wrapper after timeout (nohup): denied" 2 \
    "$(run_hook yes "timeout 90 nohup $K/ready-check.sh 12 abc" absent)"

# Any token after timeout is a timeout argument, so a timeout around a grep that names the script is denied too (accepted false deny).
expect "chief, timeout 30 grep naming ready-check.sh (accepted false deny): denied" 2 \
    "$(run_hook yes "timeout 30 grep -n x $K/ready-check.sh" absent)"
expect "chief, timeout \"\$T\" (variable duration): denied" 2 \
    "$(run_hook yes "timeout \"\$T\" $K/ready-check.sh 12 abc" absent)"
expect "chief, timeout inf: denied" 2 \
    "$(run_hook yes "timeout inf $K/ready-check.sh 12 abc" absent)"
expect "chief, timeout 1e9 (exponent): denied" 2 \
    "$(run_hook yes "timeout 1e9 $K/ready-check.sh 12 abc" absent)"
expect "chief, timeout +600 (signed): denied" 2 \
    "$(run_hook yes "timeout +600 $K/ready-check.sh 12 abc" absent)"
expect "chief, timeout -s kill 0 (lowercase signal, no limit): denied" 2 \
    "$(run_hook yes "timeout -s kill 0 $K/ready-check.sh 12 abc" absent)"
expect "chief, timeout '0' (quoted duration): denied" 2 \
    "$(run_hook yes "timeout '0' $K/ready-check.sh 12 abc" absent)"
expect "chief, timeout \"600\" (double-quoted duration): denied" 2 \
    "$(run_hook yes "timeout \"600\" $K/ready-check.sh 12 abc" absent)"
expect "chief, timeout --signal=term 600: denied" 2 \
    "$(run_hook yes "timeout --signal=term 600 $K/ready-check.sh 12 abc" absent)"
expect "chief, timeout -sKILL 600 (attached signal): denied" 2 \
    "$(run_hook yes "timeout -sKILL 600 $K/ready-check.sh 12 abc" absent)"
expect "chief, timeout --signal term 600 (separate value): denied" 2 \
    "$(run_hook yes "timeout --signal term 600 $K/ready-check.sh 12 abc" absent)"
expect "chief, timeout -s KILL 600 (signal word before the bound): denied" 2 \
    "$(run_hook yes "timeout -s KILL 600 $K/ready-check.sh 12 abc" absent)"

# --- not a Bash call / unusable payload: fail open
nonbash=$(jq -nc '{tool_name:"Edit",tool_input:{file_path:"/x/wrap-merged.sh"}}')
out=$(printf '%s' "$nonbash" | env HIMMEL_CONSOLE_DOC=/x/N-chief.md CHIEF_FG_LIST="$LIST" bash "$HOOK" 2>&1); rc=$?
expect "chief, non-Bash tool: allowed" 0 "$rc|$out"
out=$(printf '%s' 'not json' | env HIMMEL_CONSOLE_DOC=/x/N-chief.md CHIEF_FG_LIST="$LIST" bash "$HOOK" 2>&1); rc=$?
expect "chief, unparseable payload: fails open" 0 "$rc|$out"

# --- the list seam reads CHIEF_FG_LIST, and its old name CONSOLE_FG_LIST still works
printf 'alt-only.sh\n' > "$TMP/alt-list.txt"
expect "chief, CHIEF_FG_LIST names an alternate list: its script is denied" 2 \
    "$(run_hook yes "bash alt-only.sh" absent CHIEF_FG_LIST="$TMP/alt-list.txt")" "alt-only.sh"
expect "chief, old name CONSOLE_FG_LIST alone still selects the list" 2 \
    "$(run_hook yes "bash alt-only.sh" absent CHIEF_FG_LIST= CONSOLE_FG_LIST="$TMP/alt-list.txt")" "alt-only.sh"
expect "chief, CHIEF_FG_LIST wins over CONSOLE_FG_LIST" 0 \
    "$(run_hook yes "bash alt-only.sh" absent CHIEF_FG_LIST="$LIST" CONSOLE_FG_LIST="$TMP/alt-list.txt")"

# --- documented bypass
expect "chief, CONSOLE_FG_OK=1 in the launching shell: allowed" 0 \
    "$(run_hook yes "$K/wrap-merged.sh --pr 12" absent CONSOLE_FG_OK=1)" ""
expect "chief, CHIEF_FG_OK=1 in the launching shell: allowed" 0 \
    "$(run_hook yes "$K/wrap-merged.sh --pr 12" absent CHIEF_FG_OK=1)" ""
expect "chief, a per-call CHIEF_FG_OK=1 prefix does not lift the guard" 2 \
    "$(run_hook yes "CHIEF_FG_OK=1 $K/wrap-merged.sh --pr 12" absent)" "run_in_background"
expect "chief, an empty VAR= prefix does not hide the script" 2 \
    "$(run_hook yes "FOO= $K/wrap-merged.sh --pr 12" absent)" "run_in_background"
expect "chief, CHIEF_FG_OK=0 with CONSOLE_FG_OK=1 in the launching shell: denied" 2 \
    "$(run_hook yes "$K/wrap-merged.sh --pr 12" absent CHIEF_FG_OK=0 CONSOLE_FG_OK=1)" "run_in_background"
expect "chief, CHIEF_FG_OK=1 with CONSOLE_FG_OK=0 in the launching shell: denied" 2 \
    "$(run_hook yes "$K/wrap-merged.sh --pr 12" absent CHIEF_FG_OK=1 CONSOLE_FG_OK=0)" "run_in_background"
expect "chief, deny names CHIEF_FG_OK as the bypass" 2 \
    "$(run_hook yes "$K/wrap-merged.sh --pr 12" absent)" "CHIEF_FG_OK=1"

# --- data file shape: every non-comment line is a kit script that exists
bad_rows=0
while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    if [ ! -f "$SCRIPT_DIR/../handover/chief-kit/$line" ]; then
        bad "list names a missing script: $line"; bad_rows=$((bad_rows + 1))
    fi
done < "$LIST"
[ "$bad_rows" -eq 0 ] && ok "every list row is an existing kit script"

for s in wrap-merged.sh close-wrapped-leg.sh close-wrapped-worker.sh ready-check.sh verdict-go.sh action-zero.sh board.mjs; do
    if grep -qxF "$s" "$LIST"; then ok "list names $s"; else bad "list lacks the ticket's named script $s"; fi
done

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
