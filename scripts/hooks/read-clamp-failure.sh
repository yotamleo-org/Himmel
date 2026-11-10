#!/usr/bin/env bash
# read-clamp-failure.sh — PostToolUseFailure hook (matcher "Read"): the failure
# half of read-clamp.sh's duplicate-Read lifecycle (state:
# scripts/hooks/lib/read-clamp-state.sh).
#
# 1. Drops the pending record read-clamp.sh wrote for this tool_use_id, so a
#    failed or interrupted Read never consumes its range: the identical retry
#    stays allowed.
# 2. On the native oversize error ("File content (N tokens) exceeds maximum
#    allowed tokens (M)") it names a smaller, line-aligned native Read from the
#    attempted offset: limit = attempted lines x M / N x 0.9 with the counts the
#    error reports (the runtime's own limit, so CLAUDE_CODE_FILE_READ_MAX_OUTPUT_TOKENS
#    is honoured through it; a measured count with no limit falls back to that
#    variable), else half the attempted lines. A single line that cannot fit
#    gets a byte preview through Bash, which block-read-secrets.sh still
#    fences, labelled as bytes and as no Read for Edit/Write's read-before-write
#    check. This is recovery guidance (additionalContext), never a permission
#    decision, and adds no size limit of its own: native token limits stay native.
#
# Scope and bypass mirror read-clamp.sh (HIMMEL_CONSOLE_LEG=1 only;
# HIMMEL_READ_CLAMP_OK=1 skips). Workflow nudge: fails OPEN and silent.
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

row=$(jq -r '
    def tok: if type == "string" and test("^[A-Za-z0-9._:-]{1,128}$") then . else "-" end;
    def int: if type == "number" and . >= 1 and . == floor then tostring else "-" end;
    (.tool_input // {}) as $ti
    | (.error // "" | if type == "string" then . else "" end) as $e
    | ($e | capture("File content \\((?<n>[0-9]+) tokens\\) exceeds maximum allowed tokens \\((?<m>[0-9]+)\\)")? // {}) as $c
    | [(.tool_name // "" | tostring), (.session_id | tok), (.tool_use_id | tok), (.agent_id | type), (.agent_id | tok),
       (if ($e | test("exceeds maximum allowed tokens")) then "over" else "-" end),
       ($c.n // "-"), ($c.m // "-"), ($ti.offset // "" | if . == "" then "-" else int end),
       ($ti.limit // "" | if . == "" then "-" else int end)]
    | join("\t")' <<<"$input" 2>/dev/null) || exit 0
fp=$(jq -r '.tool_input.file_path // empty | strings' <<<"$input" 2>/dev/null) || exit 0  # swallow-ok: no path means no guidance

IFS=$'\t' read -r tool sid tid atype aid over n m off lim <<EOF
$row
EOF
[ "$tool" = "Read" ] || exit 0
[ "$atype" = null ] && aid=""
if [ "$tid" != "-" ] && rc_state_init "$sid" "$atype" "$aid"; then
    rc_pending_take "$tid" >/dev/null 2>&1
fi

[ "$over" = over ] && [ -n "$fp" ] || exit 0
start=1
[ "$off" != "-" ] && start=$off
if [ "$lim" != "-" ]; then
    tried=$lim
else
    total=$( { [ -f "$fp" ] && wc -l < "$fp"; } 2>/dev/null | tr -d ' ')  # swallow-ok: an uncountable file falls back to the native 2000-line page; fail-open-ok: guidance only, never a decision
    case "$total" in ''|*[!0-9]*) tried=2000 ;; *) tried=$((total - start + 1)); [ "$tried" -le 2000 ] || tried=2000 ;; esac
fi
[ "$tried" -ge 1 ] || tried=1
if [ "$m" = "-" ] && [ "$n" != "-" ]; then
    case "${CLAUDE_CODE_FILE_READ_MAX_OUTPUT_TOKENS:-}" in ''|*[!0-9]*) ;; *) m=$CLAUDE_CODE_FILE_READ_MAX_OUTPUT_TOKENS ;; esac
fi
if [ "$n" != "-" ] && [ "$m" != "-" ] && [ "$n" -gt 0 ]; then
    new=$(( tried * m * 9 / (n * 10) ))
    why="the error measured $n tokens against a $m-token limit"
else
    new=$(( tried / 2 ))
    why="the error gave no measured count, so half the attempted $tried lines"
fi

if [ "$tried" -gt 1 ] && [ "$new" -ge 1 ]; then
    msg="read-clamp-failure: that Read of $tried lines from line $start was too large ($why). Retry with a smaller native Read: Read file_path=$fp offset=$start limit=$new, then continue from offset=$((start + new)). Narrow further on another oversize error."
else
    bytes=50000
    [ "$m" != "-" ] && bytes=$((m * 2))
    msg="read-clamp-failure: line $start of $fp alone exceeds the native Read limit ($why). Last resort: a byte preview through Bash, still behind block-read-secrets.sh: sed -n '${start}p' $fp | cut -b 1-$bytes. It shows bytes, not characters (a cut can split a UTF-8 character), and it is NOT a Read: it does not satisfy Edit/Write's read-before-write check on this file."
fi
jq -nc --arg ctx "$msg" '{hookSpecificOutput:{hookEventName:"PostToolUseFailure",additionalContext:$ctx}}' 2>/dev/null
exit 0
