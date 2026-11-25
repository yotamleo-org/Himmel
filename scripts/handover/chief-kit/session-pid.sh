#!/usr/bin/env bash
# scripts/handover/chief-kit/session-pid.sh - sourced library: the one pid proof
# and the one session-id reader of the handover kit.
# Platform guard: Linux bash 3.2+ (depends on /proc, same guard as
# close-wrapped-worker.sh, which wraps the pid proof).
#
#   pid_proven_by_id <pid> <newline-separated ids> <config dir> [<sessions dir>]
#       rc 0 when sessions/<pid>.json under the config dir names one of the ids and its
#       recorded procStart equals the pid's /proc start time (a recycled pid fails the
#       second half); rc 1 otherwise. The optional fourth argument replaces
#       <config dir>/sessions as the directory holding <pid>.json.
#   doc_session_ids <doc>
#       the ids of the doc's `session_ids:` front-matter line, one per line. Only a
#       well-formed UUID (8-4-4-4-12 hex, lower- or uppercase) is kept; a malformed
#       id is dropped, never returned. rc 1 when the doc is unreadable or has no
#       front matter, else 0 (no ids is an empty output, rc 0).
#
# The caller supplies the config dir: this file reads no credential file and no
# per-process variable block.

proc_start_time() { sed -E 's/^.*\) //' "$1" | awk '{print $20}'; }

pid_proven_by_id() {
    local pid="$1" ids="${2-}" cfg="${3-}" sdir="${4-}" proc="${CLAUDE_SESSIONS_PROC:-/proc}" f rec sid ps st
    [ -n "$ids" ] || return 1
    f="${sdir:-$cfg/sessions}/$pid.json"
    [ -r "$f" ] || return 1
    rec=$(jq -r '[.sessionId // "", (.procStart // "" | tostring)] | join(" ")' "$f") || return 1
    sid="${rec%% *}"; ps="${rec#* }"
    [ -n "$sid" ] && [ -n "$ps" ] && [ -r "$proc/$pid/stat" ] || return 1
    grep -qxF -- "$sid" <<< "$ids" || return 1
    st=$(proc_start_time "$proc/$pid/stat")
    [ "$st" = "$ps" ]
}

doc_session_ids() {
    local d="$1" first
    IFS= read -r first < "$d" || return 1
    [ "$first" = "---" ] || return 1
    awk 'NR == 1 { next } /^---$/ { exit } { print }' "$d" | sed -n 's/^session_ids: *//p' | tr ',' '\n' | tr -d ' ' | grep -E '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'
    return 0
}
