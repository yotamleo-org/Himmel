#!/usr/bin/env bash
# steer-t3-tool-calls.sh — PreToolUse hook (matcher mcp__t3-code__t3_background_wait
# and mcp__t3-code__t3_thread_send): refuses the two commonest wrong T3 calls
# and names the right one. The rules: docs/internals/t3-tool-call-rules.md.
#
#   t3_background_wait  taskIds entries must be background Bash or Monitor task ids
#                       (`b` plus lowercase letters and digits, as the tool that
#                       started the task printed). An Agent id (`a` plus hex), a
#                       placeholder or any other string is refused: the right
#                       call for a subagent is to wait for its result message.
#   t3_thread_send      mode "steer" needs a thread whose turn is running. The
#                       target's status is read with `t3 thread list --json`; a
#                       thread that is listed and not running is refused: the
#                       right call is the same send with no mode (it queues, or
#                       starts a turn on an idle thread, and unsettles it).
#
# Delivered by the himmel-ops PLUGIN lane only. Self-contained: sources nothing.
#
# Fail OPEN (exit 0) on anything it cannot evaluate: no jq, unparseable input,
# a missing or failing t3 CLI, a thread that is not in the list, an unknown
# shape. It is a workflow nudge, not a security fence.
#
# Hook I/O: the tool-call JSON on stdin. Exit 0 allows; exit 2 refuses and
# stderr is shown to Claude.
#
# Env seams: T3_STEER_BIN (default $HOME/.t3/bin/t3), T3_STEER_PROJECT (default
# the payload cwd's git top-level).
# Bypass: T3_STEER_BYPASS=1 in the shell that launched the agent (session-sticky;
# a per-call prefix does not reach the hook).
#
# Bash 3.2-compatible.
set -uo pipefail

[ "${T3_STEER_BYPASS:-0}" = "1" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

input=$(cat 2>/dev/null) || exit 0
tool=$(printf '%s' "$input" | jq -r '.tool_name // "" | if type == "string" then . else "" end' 2>/dev/null) || exit 0

deny() {
    printf 'BLOCKED: steer-t3-tool-calls: %s\nRules: docs/internals/t3-tool-call-rules.md. Bypass (operator only): relaunch from a shell with T3_STEER_BYPASS=1.\n' "$1" >&2
    exit 2
}

case "$tool" in
    mcp__t3-code__t3_background_wait)
        bad=$(printf '%s' "$input" | jq -r '
            (.tool_input // {}) | if type == "object" then .taskIds else null end
            | if type == "array" then .[] else empty end
            | select((type == "string" and test("^b[a-z0-9]{6,}$")) | not) | tojson' 2>/dev/null) || exit 0
        [ -n "$bad" ] || exit 0
        list=$(printf '%s' "$bad" | awk 'NR > 1 { printf ", " } { printf "%s", $0 }')
        deny "t3_background_wait takes the id of a running background Bash command or Monitor (it starts with b, e.g. b001oqmbs), and these are not: ${list}. An Agent id (starts with a) or a placeholder never works here. To wait on a subagent, end your turn and its result arrives as a message; to wait on a command, start it with Bash run_in_background (or Monitor) and pass the id that call printed."
        ;;
    mcp__t3-code__t3_thread_send)
        mode=$(printf '%s' "$input" | jq -r '.tool_input | if type == "object" then .mode else null end | if type == "string" then . else "" end' 2>/dev/null) || exit 0
        [ "$mode" = "steer" ] || exit 0
        tid=$(printf '%s' "$input" | jq -r '.tool_input.threadId | if type == "string" then . else "" end' 2>/dev/null) || exit 0
        [ -n "$tid" ] || exit 0
        bin="${T3_STEER_BIN:-${HOME:-/nonexistent}/.t3/bin/t3}"
        [ -x "$bin" ] || exit 0
        project="${T3_STEER_PROJECT:-}"
        if [ -z "$project" ]; then
            cwd=$(printf '%s' "$input" | jq -r '.cwd // "" | if type == "string" then . else "" end' 2>/dev/null) || exit 0
            [ -n "$cwd" ] || cwd=$PWD
            project=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || exit 0
        fi
        if command -v timeout >/dev/null 2>&1; then
            list=$(timeout -k 1 8 "$bin" thread list --json --project "$project" 2>/dev/null) || exit 0 # gnu-ok: the thread list is read-only; without timeout it runs unbounded
        else
            list=$("$bin" thread list --json --project "$project" 2>/dev/null) || exit 0
        fi
        status=$(printf '%s' "$list" | jq -r --arg id "$tid" '
            if type == "array" then ([.[] | select(.threadId == $id)] | first | .status // empty | if type == "string" then . else empty end) else empty end' 2>/dev/null) || exit 0
        [ -n "$status" ] || exit 0
        case "$status" in running | starting | active) exit 0 ;; esac
        deny "t3_thread_send with mode \"steer\" needs a thread whose turn is running, and thread ${tid} is ${status}. Send the same message with no mode: it starts a turn on an idle thread (and unsettles it) or queues behind a running one."
        ;;
esac
exit 0
