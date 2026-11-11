#!/usr/bin/env bash
# record-read-clamp.sh — PostToolUse hook (matcher "Read"): the success half of
# read-clamp.sh's duplicate-Read lifecycle (state: scripts/hooks/lib/read-clamp-state.sh).
# It consumes the pending record read-clamp.sh wrote for this tool_use_id, and
# marks the range read only when the result is a complete text range of a file
# whose content hash still matches the pre-read hash:
#   - type "text" with a file object carrying startLine/numLines/totalLines;
#   - startLine is the requested offset (1 when none);
#   - not truncatedByTokenCap (a whole-file read the runtime auto-paginated);
#   - a ranged read returned its whole limit or reached the end of the file;
#     a whole-file read returned every line.
# Anything partial, ambiguous or of another shape is dropped unconsumed.
#
# Scope and bypass mirror read-clamp.sh (HIMMEL_CONSOLE_LEG=1 only;
# HIMMEL_READ_CLAMP_OK=1 skips). Workflow nudge: fails OPEN and silent on
# anything it cannot parse or record, and never prints a decision.
#
# Platform guard: bash-only, like read-clamp.sh. bash 3.2-safe.
set -uo pipefail

[ "${HIMMEL_CONSOLE_LEG:-0}" = "1" ] || exit 0
[ "${HIMMEL_READ_CLAMP_OK:-0}" = "1" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

input=$(cat) || exit 0
[ -n "$input" ] || exit 0

_rc_dir="${BASH_SOURCE[0]%/*}"
[ "$_rc_dir" != "${BASH_SOURCE[0]}" ] || _rc_dir=.
# shellcheck source=scripts/hooks/lib/read-clamp-state.sh
# shellcheck disable=SC1091
{ [ -r "$_rc_dir/lib/read-clamp-state.sh" ] && . "$_rc_dir/lib/read-clamp-state.sh"; } 2>/dev/null || exit 0

# One tab-separated line; every field is a plain token or "-", never empty.
row=$(jq -r '
    def tok: if type == "string" and test("^[A-Za-z0-9._:-]{1,128}$") then . else "-" end;
    def int: if type == "number" and . >= 0 and . == floor then tostring else "-" end;
    (.tool_input // {}) as $ti | (.tool_response // {}) as $r
    | ($r.file // {}) as $f
    | [(.tool_name // "" | tostring), (.session_id | tok), (.tool_use_id | tok),
       (.agent_id | type), (.agent_id | tok),
       ($ti.file_path // "-" | tostring), ($ti.offset // "" | if . == "" then "-" else int end),
       ($ti.limit // "" | if . == "" then "-" else int end),
       ($r | if type == "object" then (.type // "-" | tostring) else "-" end),
       ($f | if type == "object" then (.startLine | int) else "-" end),
       ($f | if type == "object" then (.numLines | int) else "-" end),
       ($f | if type == "object" then (.totalLines | int) else "-" end),
       ($f | if type == "object" and .truncatedByTokenCap == true then "1" else "0" end)]
    | map(if . == "" then "-" else . end) | join("\t")' <<<"$input" 2>/dev/null) || exit 0

IFS=$'\t' read -r tool sid tid atype aid fp off lim rtype start num total trunc <<EOF
$row
EOF
[ "$tool" = "Read" ] || exit 0
[ "$tid" != "-" ] && [ "$sid" != "-" ] || exit 0
[ "$atype" = null ] && aid=""
rc_state_init "$sid" "$atype" "$aid" || exit 0
rec=$(rc_pending_take "$tid") || exit 0
key="${rec%%$'\t'*}"; chash="${rec#*$'\t'}"

[ "$rtype" = text ] && [ "$trunc" = 0 ] || exit 0
case "$start$num$total" in *-*) exit 0 ;; esac
want_start=1
[ "$off" != "-" ] && [ "$off" -gt 0 ] && want_start=$off
[ "$start" -eq "$want_start" ] || exit 0
last=$((start + num - 1))
if [ "$lim" != "-" ]; then
    [ "$num" -eq "$lim" ] || [ "$last" -ge "$total" ] || exit 0
else
    [ "$last" -ge "$total" ] || exit 0
fi

[ "$fp" != "-" ] || exit 0
now_hash=$(rc_content_hash "$fp") || exit 0
[ "$now_hash" = "$chash" ] || exit 0
[ "$key" = "$(rc_key "$fp" "$([ "$off" = - ] || printf '%s' "$off")" "$([ "$lim" = - ] || printf '%s' "$lim")")" ] || exit 0
rc_done_add "$key" "$chash"
exit 0
