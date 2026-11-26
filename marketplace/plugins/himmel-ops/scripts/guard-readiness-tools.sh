#!/usr/bin/env bash
# guard-readiness-tools.sh - PreToolUse hook: the readiness role's tool allow-list (C0s cycle 3).
#
# In a READINESS CONTEXT this allows exactly two tool names, mcp__readiness__inspect and mcp__readiness__act, on a valid
# envelope, and denies everything else: a native tool (Bash, Read, Write, Edit, ...), any other MCP server, any name
# that differs by case, prefix, suffix or whitespace, an empty, non-JSON, multi-value or NUL-carrying payload, a payload
# whose tool_name is missing or not a string, a payload over 256 KiB, and any failure of the guard itself.
#
# READINESS CONTEXT: the environment variable HIMMEL_READINESS is exactly 1 (the value the signed supervisor/delivery
# protocol uses). Anything else - unset, empty, 0, yes, "1 ", 01 - is the GENERIC context: this hook exits 0 at once,
# reads nothing, prints nothing and has no effect, the existing protocol for a marker-gated guard (guard-judge-writes.sh).
# WIRING: headed-arm-worker.sh sets HIMMEL_READINESS=1 for the readiness role only and scrubs an inherited value from every
# other launch. The himmel-ops plugin's hooks.json runs this project copy through the runner's lone `--optional
# --fail-closed-when HIMMEL_READINESS=1` protocol: with the marker a missing script fails closed, without it the hook is
# silent. WORKER_SESSION_PROFILE_READINESS (worker-claude-launcher.sh) is a different, launcher-side variable that selects the
# readiness argv; it is not this hook's marker.
#
# This hook judges ONLY the tool name and the envelope shape. It never looks at tool_input beyond requiring a valid
# JSON document, so ActRequest semantics stay the adapter's job and no new tool is granted here. No credential, lease
# token, config or file is read or written; the only external program is jq.
#
# PROTOCOL (the existing PreToolUse hook protocol, as guard-judge-writes.sh):
#   allow : exit 0, no output.
#   deny  : exit 2; stdout is one JSON line {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":
#           "deny","permissionDecisionReason":"readiness tool-deny: <code> (<detail>) - ..."}}; stderr stays empty. The
#           reason is a fixed string, never an echo of the payload. <code> is one of
#             oversize-input  more than 262144 bytes on stdin (only 262145 are ever read, so an endless stream is bounded)
#             bad-envelope    empty, whitespace-only, non-JSON, more or less than one JSON value, a NUL byte, an unreadable
#                             stdin, a top-level value that is not an object, or tool_name absent / not a JSON string
#             not-allowed     a valid envelope whose tool_name is a string other than the two exact names
#             guard-failure   jq missing or crashing, an unknown jq verdict, or any unexpected exit of this script
#
# FAIL CLOSED: from the readiness gate on, the only path to exit 0 is the single allow verdict; one trap turns any other
# exit, and a HUP/INT/QUIT/TERM, into guard-failure with exit 2. Direct tests of that cover a missing, crashing, silent
# and lying jq, an unreadable stdin and a TERM while blocked reading stdin. A guard that stalls is bounded by the runner, not
# by this script: the lone `--optional --fail-closed-when HIMMEL_READINESS=1` delivery gives it a 12 s deadline
# (RUN_HOOK_LONE_GUARD_TIMEOUT_MS), under the 15 s host timeout hooks.json registers, and returns exit 2. What the host does
# after it kills a PreToolUse hook is NOT claimed here (SIGKILL cannot be trapped); that is an owed real-session run.
#
# BYPASS: none. This is a security fence; there is no per-call or per-session switch. A session that is not the readiness
# role simply does not carry HIMMEL_READINESS=1.
#
# RESIDUALS (deliberate, disclosed): jq is the JSON parser, so the guard accepts what jq accepts beyond strict RFC 8259 -
# a UTF-8 BOM, NaN/Infinity and leading-zero number literals, invalid UTF-8 outside tool_name, and the LAST of two
# duplicate keys (the same choice JSON.parse makes). None changes which tool_name is judged, and a payload the harness
# did not serialise is outside this guard's threat model. The environment of this process is trusted (launcher/supervisor
# owned). The bounded read uses bash's read -n/-d '' and was exercised on bash 5.3 only, not on a 3.2 binary.
#
# The himmel-ops plugin carries a byte-identical copy (marketplace/plugins/himmel-ops/scripts/) that sources nothing;
# test-guard-readiness-tools.sh pins the identity. hooks.json runs the project copy, because the readiness session starts in
# the launcher's checkout (headed-arm.sh changes into the checkout and opens the session there).
set -uo pipefail

# Generic context: the existing protocol, silent and effect-free.
[ "${HIMMEL_READINESS-}" = 1 ] || exit 0
trap '' PIPE

LC_ALL=C # bytes, not characters, for the size bound below
MAX_BYTES=262144
GUARD_DONE=0

deny() { # deny <code> <detail>: the one deny path (fixed reason text, stdout JSON, exit 2)
    GUARD_DONE=1
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"readiness tool-deny: %s (%s) - the readiness role may call only mcp__readiness__inspect and mcp__readiness__act"}}\n' "$1" "$2" 2>/dev/null # swallow-ok: a closed stdout must not change the exit code
    exit 2
}
trap '[ "$GUARD_DONE" = 1 ] || deny guard-failure "the guard exited or was signalled unexpectedly"' EXIT HUP INT QUIT TERM

command -v jq >/dev/null 2>&1 || deny guard-failure "jq is not on PATH"

# At most MAX_BYTES+1 bytes are read. read -d '' returns 0 only when it stopped on a NUL byte or on the byte limit
# (anything else is EOF or a read error, rc 1), so a short read with rc 0 is a NUL and a full-length read is oversize.
input=""
IFS= read -r -d '' -n $((MAX_BYTES + 1)) input 2>/dev/null # swallow-ok: EOF and a read error both leave input short and are judged below
read_rc=$?
if [ "${#input}" -gt "$MAX_BYTES" ]; then
    deny oversize-input "stdin is over $MAX_BYTES bytes"
elif [ "$read_rc" -eq 0 ]; then
    deny bad-envelope "stdin holds a NUL byte"
fi

# jq compares the name itself, so no shell step (command substitution strips trailing newlines) can change it.
verdict=$(printf '%s' "$input" 2>/dev/null | jq -esj '
    if length == 1 and (.[0] | type) == "object" and (.[0].tool_name | type) == "string"
    then (if (.[0].tool_name | IN("mcp__readiness__inspect", "mcp__readiness__act")) then "allow" else "name" end)
    else empty end' 2>/dev/null) # swallow-ok: jq's status and verdict are classified right below
jq_rc=$?
case "$jq_rc:$verdict" in
    0:allow)
        GUARD_DONE=1
        exit 0
        ;;
    0:name) deny not-allowed "tool_name is not one of the two readiness tools" ;;
    2: | 4: | 5:) deny bad-envelope "stdin is not exactly one JSON object with a string tool_name" ;;
    *) deny guard-failure "the JSON check failed or returned an unknown verdict" ;;
esac
