#!/usr/bin/env bash
# approval-grant-request.sh — PermissionDenied hook: file one grant request with the root
# afk-sudo helper for a Bash call the permission classifier refused.
#
# It pipes the refused command's exact bytes (jq -j of tool_input.command) to
#
#   sudo -n /usr/local/libexec/himmel/afk-sudo grant-request --session=S --cwd=D --why=R
#
# Root then binds every file the command names, runs the never-remote floor (a secret read
# is refused before any notice), freezes the record and sends the operator the full command
# through the root-only notice bot. Nothing here reads or forwards the classifier-denial log
# (log-classifier-denial.sh's input_head / reason_tag never leave the host); the notice is
# built from root's frozen record. The operator's `NONCE CODE` reply is the only way a grant
# is written; approval-grant-check.sh then lets the byte-identical retry through once.
#
# Off unless the station opted in: no marker directory (helper not installed) means no sudo
# call at all, and the helper refuses every request while grant.enabled is false.
#
# This is an OBSERVABILITY-STYLE TAP, same contract as log-classifier-denial.sh on the same
# event: it never blocks, delays or asks on a tool call, prints nothing, and exits 0 on every
# path. The helper caps requests (one pending at a time, max_per_hour).
#
# Test seam: AFK_GRANT_DIR names the marker directory.
#
# bash 3.2-compatible.
set -uo pipefail
trap 'exit 0' EXIT

HELPER=/usr/local/libexec/himmel/afk-sudo
MARKS="${AFK_GRANT_DIR:-/var/lib/himmel/afk-grants}"

[ -d "$MARKS" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

input=''
IFS= read -r -d '' input 2>/dev/null || true  # swallow-ok: read -d '' ends at EOF with rc 1
[ -n "$input" ] || exit 0

tool=$(jq -r '.tool_name // ""' <<<"$input" 2>/dev/null) || exit 0  # swallow-ok: fail-open tap, no request on error
[ "$tool" = Bash ] || exit 0
has=$(jq -r '.tool_input.command | type == "string" and length > 0' <<<"$input" 2>/dev/null) || exit 0  # swallow-ok: fail-open tap
[ "$has" = true ] || exit 0
session=$(jq -r '.session_id // ""' <<<"$input" 2>/dev/null) || exit 0  # swallow-ok: fail-open tap
cwd=$(jq -r '.cwd // ""' <<<"$input" 2>/dev/null) || exit 0  # swallow-ok: fail-open tap
reason=$(jq -r '.reason // ""' <<<"$input" 2>/dev/null) || exit 0  # swallow-ok: fail-open tap
[ -n "$session" ] && [ -n "$cwd" ] || exit 0

jq -j '.tool_input.command' <<<"$input" 2>/dev/null |
    sudo -n "$HELPER" grant-request --session="$session" --cwd="$cwd" --why="$reason" >/dev/null 2>&1
exit 0
