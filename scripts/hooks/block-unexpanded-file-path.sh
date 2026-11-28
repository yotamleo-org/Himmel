#!/usr/bin/env bash
# block-unexpanded-file-path.sh -- PreToolUse, first in every file-tool chain (Edit|Write|MultiEdit|NotebookEdit,
# Read|Grep, and the Antigravity edit_file, write_file and read_file chains), and a must-run chain member.
#
# Claude Code rewrites a file_path or notebook_path (trim, ~ expansion, normalisation) before the hooks see it only
# when it is at most 4096 UTF-16 units, and a call from another harness gets no rewrite at all. A raw path then
# reaches the guards behind this one, while the tool still trims and expands it before it writes or reads. This guard
# denies every present file_path and notebook_path that is not a string, is over MAX_FILE_PATH_BYTES UTF-8 bytes, or
# is not in the form the tools leave unchanged: a leading ~, a first or last character from the JavaScript trim()
# set (25 code points), a U+0000, a //, or a . or .. segment. A relative path in form and a trailing / are allowed.
# A security fence: no jq, an unparseable payload or no verdict denies.
# Bypass (single run, operator only, set in the launching shell): UNEXPANDED_FILE_PATH_OK=1.
[ "${UNEXPANDED_FILE_PATH_OK:-0}" = "1" ] && exit 0
set -uo pipefail

MAX_FILE_PATH_BYTES=4096

BYPASS='Bypass (single run, operator only, set in his own launching shell): UNEXPANDED_FILE_PATH_OK=1. It also turns off the raw-path protection of every file guard behind this one.'

deny() {
    local msg="block-unexpanded-file-path: $1 $BYPASS"
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$msg"
    printf '%s\n' "$msg" >&2
    exit 2
}

command -v jq >/dev/null 2>&1 || deny "jq is not on PATH, so the file path cannot be read."

verdicts=$(jq -r --argjson max "$MAX_FILE_PATH_BYTES" '
    def edge: "[\u0009-\u000d    -     　﻿]";
    def verdict:
        if type != "string" then "type"
        elif utf8bytelength > $max then "long"
        elif (explode | any(. == 0)) then "form"
        elif test("\\A(~|" + edge + ")") or test(edge + "\\z") then "form"
        elif contains("//") then "form"
        elif (split("/") | any(. == "." or . == "..")) then "form"
        else "ok" end;
    (.tool_input | if type == "object" then . else {} end) as $ti
    | [ "file_path", "notebook_path" | select(. as $k | $ti | has($k)) | $ti[.] ]
    | if length == 0 then "none" else .[] | verdict end
') || deny "the hook payload cannot be parsed, so the file path cannot be read."

[ -n "$verdicts" ] || deny "the path check printed no verdict, so the file path cannot be read."

while IFS= read -r v; do
    case "$v" in
        ok | none) ;;
        long) deny "the file path is over $MAX_FILE_PATH_BYTES bytes. The CLI hands such a path to hooks unexpanded, so no guard can check what would be written. Use a shorter path." ;;
        form) deny "the file path is not in the form the tools leave unchanged, so the guards behind this one would judge another path than the one the tool touches. Send the path with no leading ~, no leading or trailing whitespace, no NUL, and no ., .. or empty segments, or send the absolute path." ;;
        type) deny "a file_path or notebook_path is not a string, so it cannot be checked." ;;
        *) deny "the path check printed no verdict, so the file path cannot be read." ;;
    esac
done <<EOF
$verdicts
EOF
exit 0
