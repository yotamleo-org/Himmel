#!/usr/bin/env bash
# Tests for scripts/hooks/guard-console-foreground.sh.
#
# Usage: bash scripts/hooks/test-guard-console-foreground.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/guard-console-foreground.sh"
LIST="$SCRIPT_DIR/../handover/console-kit/long-running.txt"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/himmel-console-fg.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

# NUL-delimited argv fixtures for the session-name seam (scripts/lib/session-name.sh)
printf 'claude\0-n\0N-console\0' > "$TMP/cmdline-console"
printf 'claude\0-n\0N2262-HIMMEL-5821-leg\0' > "$TMP/cmdline-leg"

ok()  { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }

# run_hook <console:yes|no> <command> <background:true|false|absent> [extra env...]
# Prints "<rc>|<stdout+stderr>".
run_hook() {
    local console="$1" cmd="$2" bg="$3" payload out rc
    shift 3
    case "$bg" in
        true)   payload=$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c,run_in_background:true}}') ;;
        false)  payload=$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c,run_in_background:false}}') ;;
        *)      payload=$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}') ;;
    esac
    if [ "$console" = yes ]; then
        out=$(printf '%s' "$payload" | env HIMMEL_CONSOLE_DOC=/x/N-console.md CLAUDE_PID=1 SESSION_NAME_CMDLINE_FILE="$TMP/cmdline-console" CONSOLE_FG_LIST="$LIST" "$@" bash "$HOOK" 2>&1)
    else
        out=$(printf '%s' "$payload" | env -u HIMMEL_CONSOLE_DOC CONSOLE_FG_LIST="$LIST" "$@" bash "$HOOK" 2>&1)
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

K="bash scripts/handover/console-kit"

# --- the headline DoD rows
expect "console, foreground wrap-merged.sh: denied" 2 \
    "$(run_hook yes "$K/wrap-merged.sh --pr 12" absent)" "run_in_background"
expect "console, foreground wrap-merged.sh: deny names the script" 2 \
    "$(run_hook yes "$K/wrap-merged.sh --pr 12" absent)" "wrap-merged.sh"
expect "console, explicit run_in_background=false: denied" 2 \
    "$(run_hook yes "$K/wrap-merged.sh --pr 12" false)" "run_in_background"
expect "console, wrap-merged.sh with run_in_background=true: allowed" 0 \
    "$(run_hook yes "$K/wrap-merged.sh --pr 12" true)"
expect "leg (no HIMMEL_CONSOLE_DOC), foreground wrap-merged.sh: allowed" 0 \
    "$(run_hook no "$K/wrap-merged.sh --pr 12" absent)"

# a leg launched from the console inherits HIMMEL_CONSOLE_DOC; only the session name tells them apart
payload_leg=$(jq -nc --arg c "$K/ready-check.sh --only 7 12" '{tool_name:"Bash",tool_input:{command:$c}}')
out=$(printf '%s' "$payload_leg" | env HIMMEL_CONSOLE_DOC=/x/N-console.md CLAUDE_PID=1 SESSION_NAME_CMDLINE_FILE="$TMP/cmdline-leg" CONSOLE_FG_LIST="$LIST" bash "$HOOK" 2>&1); rc=$?
expect "leg session name with inherited HIMMEL_CONSOLE_DOC, foreground ready-check.sh: allowed" 0 "$rc|$out"
out=$(printf '%s' "$payload_leg" | env -u CLAUDE_PID HIMMEL_CONSOLE_DOC=/x/N-console.md CONSOLE_FG_LIST="$LIST" bash "$HOOK" 2>&1); rc=$?
expect "unresolvable session name: fails open" 0 "$rc|$out"

# --- the short scripts stay foreground
for s in append-results.sh go.sh write-verdict.sh fleet-manifest.sh; do
    expect "console, foreground $s: allowed" 0 "$(run_hook yes "$K/$s x" absent)"
    if grep -qxF "$s" "$LIST"; then bad "list must not name $s"; else ok "list omits $s"; fi
done

# --- invocation shapes
expect "console, absolute path via bash: denied" 2 \
    "$(run_hook yes "bash /repo/scripts/handover/console-kit/close-wrapped-leg.sh leg" absent)"
expect "console, node script (board.mjs): denied" 2 \
    "$(run_hook yes "node scripts/handover/console-kit/board.mjs" absent)"
expect "console, direct path execution: denied" 2 \
    "$(run_hook yes "scripts/handover/console-kit/ready-check.sh 12 abc" absent)"
expect "console, chained after another command: denied" 2 \
    "$(run_hook yes "cd /x && bash scripts/handover/console-kit/verdict-go.sh a b" absent)"

# --- a mention is not a run
expect "console, git grep naming a listed script: allowed" 0 \
    "$(run_hook yes "git grep -n wrap-merged.sh -- scripts" absent)"
expect "console, longer name sharing a prefix: allowed" 0 \
    "$(run_hook yes "$K/wrap-merged.sh.bak" absent)"
expect "console, unrelated command: allowed" 0 "$(run_hook yes "ls -la" absent)"

# --- not a Bash call / unusable payload: fail open
nonbash=$(jq -nc '{tool_name:"Edit",tool_input:{file_path:"/x/wrap-merged.sh"}}')
out=$(printf '%s' "$nonbash" | env HIMMEL_CONSOLE_DOC=/x/N-console.md CONSOLE_FG_LIST="$LIST" bash "$HOOK" 2>&1); rc=$?
expect "console, non-Bash tool: allowed" 0 "$rc|$out"
out=$(printf '%s' 'not json' | env HIMMEL_CONSOLE_DOC=/x/N-console.md CONSOLE_FG_LIST="$LIST" bash "$HOOK" 2>&1); rc=$?
expect "console, unparseable payload: fails open" 0 "$rc|$out"

# --- documented bypass
expect "console, CONSOLE_FG_OK=1 in the launching shell: allowed" 0 \
    "$(run_hook yes "$K/wrap-merged.sh --pr 12" absent CONSOLE_FG_OK=1)" ""

# --- data file shape: every non-comment line is a kit script that exists
bad_rows=0
while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    if [ ! -f "$SCRIPT_DIR/../handover/console-kit/$line" ]; then
        bad "list names a missing script: $line"; bad_rows=$((bad_rows + 1))
    fi
done < "$LIST"
[ "$bad_rows" -eq 0 ] && ok "every list row is an existing kit script"

for s in wrap-merged.sh close-wrapped-leg.sh ready-check.sh verdict-go.sh action-zero.sh board.mjs; do
    if grep -qxF "$s" "$LIST"; then ok "list names $s"; else bad "list lacks the ticket's named script $s"; fi
done

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
