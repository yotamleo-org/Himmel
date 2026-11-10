#!/usr/bin/env bash
# read-clamp.sh — PreToolUse hook (matchers "Read|Grep" and "Bash"): denies a
# whole-file Read/cat/sed/head of a file over HIMMEL_READ_CLAMP_LINES lines,
# and denies a repeated Read of the exact same (path, offset, limit) by the same
# agent of an unchanged file it already read successfully, inside a
# chief-spawned worker-impl session.
#
# WHY: measured over 12 merged-PR workers, repeated Reads of the same
# file cost ~4.5% of a PR's token bill and whole-file reads ~2.2% (6.7%
# together, the #2/#3 levers). The instructional layer
# (preface read-range sentence, #692) already exists; this is the structural
# step (root CLAUDE.md "second drift -> hook").
#
# Scope: HIMMEL_CONSOLE_LEG=1 only (headed-arm-worker.sh's launcher export) --
# never gates a chief or an interactive session.
#
# Platform guard: bash-only -- worker-impl sessions run under the
# .claude/settings.json Bash launcher (Linux/macOS).
#
# Workflow nudge, not a security fence (scripts/hooks/CLAUDE.md "Fail-open vs
# fail-closed"): this hook saves tokens, it does not protect anything, so it
# fails OPEN on anything it cannot parse or record -- missing jq, malformed
# stdin, an unrecognised Bash shape, or a runtime dir it cannot create.
#
# State: himmel-read-clamp/v2 (scripts/hooks/lib/read-clamp-state.sh). This
# hook only writes a PENDING record per tool_use_id; record-read-clamp.sh
# (PostToolUse Read) consumes the range after a complete, unchanged successful
# Read, and read-clamp-failure.sh (PostToolUseFailure Read) drops it. So a
# failed, denied or interrupted Read never blocks its own retry, another agent
# keeps its own reads, and an edited file is readable again. A missing or
# uncreatable runtime dir, an unhashable file (over 1 MiB, binary, image, PDF,
# notebook), an extra Read argument (pages, allow_large) or a malformed
# identity skips duplicate tracking -- this hook never fails closed on its own
# infrastructure.
#
# Bypass: set HIMMEL_READ_CLAMP_OK=1 in the shell that launched the worker to
# allow one session past the clamp (e.g. re-reading a file after an external
# edit invalidated the recorded range). Logged to stderr each time it fires.
#
# Hook I/O: JSON on stdin. exit 0 = allow, exit 2 = deny (stderr message,
# same convention as block-read-secrets.sh / block-worker-askuserquestion.sh).
set -uo pipefail

[ "${HIMMEL_CONSOLE_LEG:-0}" = "1" ] || exit 0

if [ "${HIMMEL_READ_CLAMP_OK:-0}" = "1" ]; then
    echo "read-clamp: HIMMEL_READ_CLAMP_OK=1 -- bypassing the read clamp for this call" >&2
    exit 0
fi

command -v jq >/dev/null 2>&1 || exit 0

input=$(cat) || exit 0
[ -n "$input" ] || exit 0

_rc_dir="${BASH_SOURCE[0]%/*}"
[ "$_rc_dir" != "${BASH_SOURCE[0]}" ] || _rc_dir=.
# shellcheck source=scripts/hooks/lib/read-clamp-state.sh
# shellcheck disable=SC1091
{ [ -r "$_rc_dir/lib/read-clamp-state.sh" ] && . "$_rc_dir/lib/read-clamp-state.sh"; } 2>/dev/null || exit 0

# 2000 = the Read tool's own page size: a file that fits one ordinary Read is not clamped.
LIMIT_LINES="${HIMMEL_READ_CLAMP_LINES:-2000}"

# SOH (not tab): bash's `read` treats tab as an IFS-whitespace class char and
# COLLAPSES consecutive tab delimiters, silently shifting empty offset/limit
# fields into the next column. block-read-secrets.sh hits the same hazard and
# uses the same fix.
SOH=$'\001'
row=$(jq -r --arg sep "$SOH" '
    def chk: if contains($sep) then error("delimiter-collision") else . end;
    ((.tool_name // "")|tostring|chk) + $sep +
    ((.tool_input.file_path // "")|tostring|chk) + $sep +
    ((.tool_input.offset // "")|tostring|chk) + $sep +
    ((.tool_input.limit // "")|tostring|chk) + $sep +
    ((.tool_input.command // "")|tostring|chk) + $sep +
    ((.session_id // "")|tostring|chk) + $sep +
    ((.tool_use_id // "")|tostring|chk) + $sep +
    (.agent_id|type) + $sep +
    ((.agent_id // "")|tostring|chk) + $sep +
    ((.tool_input // {}) | if type == "object" then (keys - ["file_path","offset","limit"] | length | tostring) else "x" end)
' <<<"$input" 2>/dev/null) || exit 0
[ -n "$row" ] || exit 0

# Split by parameter expansion, NOT `IFS="$SOH" read`: bash 3.2 (macOS
# /bin/bash) never splits on \001 -- CTLESC is its internal quote byte -- so
# `read` returned the whole row in $tool and every gate below silently allowed.
# block-read-secrets.sh splits the same way.
#
# Under a UTF-8 locale each `%%`/`#` pattern match re-decodes the multibyte
# command (688 ms at 45 KB). The delimiter is ASCII and a UTF-8
# sequence never contains an ASCII byte, so the split runs byte-wise under a
# function-local LC_ALL=C. The head comes from `%%` (a left
# to right scan that stops at the first SOH) and the rest by offset: `#*SOH`
# tries every prefix length and is quadratic in the head even under C.
split_row() {
    local LC_ALL=C head
    head="${row%%"$SOH"*}"; tool=$head; row="${row:${#head}+1}"
    head="${row%%"$SOH"*}"; fp=$head; row="${row:${#head}+1}"
    head="${row%%"$SOH"*}"; offset=$head; row="${row:${#head}+1}"
    head="${row%%"$SOH"*}"; limit=$head; row="${row:${#head}+1}"
    head="${row%%"$SOH"*}"; cmd=$head; row="${row:${#head}+1}"
    head="${row%%"$SOH"*}"; session_id=$head; row="${row:${#head}+1}"
    head="${row%%"$SOH"*}"; tool_use_id=$head; row="${row:${#head}+1}"
    head="${row%%"$SOH"*}"; agent_type=$head; row="${row:${#head}+1}"
    head="${row%%"$SOH"*}"; agent_id=$head; extra_args="${row:${#head}+1}"
}
split_row

# file_line_count: prints a file's line count, or nothing (and fails) if the
# file cannot be read -- callers must allow on failure, never deny on a guess.
file_line_count() {
    [ -f "$1" ] || return 1  # regular files only -- wc on a FIFO/device can block indefinitely (HIMMEL-2993 CR)
    wc -l < "$1" 2>/dev/null  # fail-open-ok: an unreadable-but-regular file returns empty/rc!=0 here, and the caller's `|| exit 0` already treats that as allow -- documented fail-open (never deny on a guess)
}

# clamp_deny: the one deny message both the Read whole-file path and the Bash
# shapes share. It names the exact offset/limit pages that cover the file (the
# first 8, then the continuation step) so every lane retries in one step and
# none treats the denial as a stop.
clamp_deny() {  # $1 = path, $2 = line count
    local pages="" off=1 n=0
    while [ "$off" -le "$2" ] && [ "$n" -lt 8 ]; do
        pages="${pages:+$pages; }offset=$off limit=${LIMIT_LINES}"
        off=$((off + LIMIT_LINES))
        n=$((n + 1))
    done
    [ "$off" -le "$2" ] && pages="$pages; then offset=$off limit=${LIMIT_LINES} and so on up to line $2"
    echo "⛔ read-clamp: $1 has $2 lines (> ${LIMIT_LINES}); read it in pages, not whole: offset=<n> limit=<m>. Retry: Read file_path=$1 offset=1 limit=${LIMIT_LINES}. Pages: $pages" >&2
    exit 2
}

# strip_quotes: strips one matching pair of surrounding quotes from a captured
# Bash target -- `cat "/path.txt"` otherwise checks a filename that literally
# includes the quote characters, which never exists and silently bypasses the
# clamp.
strip_quotes() {
    local t="$1"
    case "$t" in
        \"*\") t="${t#\"}"; t="${t%\"}" ;;
        \'*\') t="${t#\'}"; t="${t%\'}" ;;
    esac
    printf '%s\n' "$t"
}

case "$tool" in
    Read)
        [ -n "$fp" ] || exit 0
        [ -r "$fp" ] || exit 0  # a nonexistent or unreadable file may be fixed before a retry: no state, allow
        # No session or no runtime dir: allow outright, size clamp included, as before.
        [ -n "$session_id" ] || exit 0
        mkdir -p "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/himmel-read-clamp" 2>/dev/null || exit 0

        # Duplicate tracking: only a plain text Read (no extra argument) of a
        # hashable file, by a well-formed actor, with a tool_use_id to pair on.
        track=0 key="" chash=""
        if [ "$extra_args" = 0 ] && ! rc_extension_native "$fp" \
            && rc_state_init "$session_id" "$agent_type" "$agent_id"; then
            key=$(rc_key "$fp" "$offset" "$limit") && chash=$(rc_content_hash "$fp") && track=1
        fi

        if [ "$track" = 1 ] && stamp=$(rc_done_lookup "$key" "$chash"); then
            echo "⛔ read-clamp: already read this exact range at ${stamp} and the file is unchanged since; refer to that earlier result, or read the range you need or a different range" >&2
            exit 2
        fi

        if [ -z "$offset" ] && [ -z "$limit" ]; then
            lines=$(file_line_count "$fp") || exit 0
            [ -n "$lines" ] || exit 0
            if [ "$lines" -gt "$LIMIT_LINES" ] 2>/dev/null; then
                clamp_deny "$fp" "$lines"
            fi
        fi

        [ "$track" = 1 ] && rc_pending_add "$tool_use_id" "$key" "$chash"
        exit 0
        ;;

    Bash)
        [ -n "$cmd" ] || exit 0
        trimmed="$(printf '%s' "$cmd" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

        target=""
        if [[ "$trimmed" =~ ^cat[[:space:]]+([^[:space:]\;\|\&\<\>]+)$ ]]; then
            target="${BASH_REMATCH[1]}"
        elif [[ "$trimmed" =~ ^sed[[:space:]]+-n[[:space:]]+\'?1,\$p\'?[[:space:]]+([^[:space:]\;\|\&\<\>]+)$ ]]; then
            target="${BASH_REMATCH[1]}"
        elif [[ "$trimmed" =~ ^head[[:space:]]+-n[[:space:]]+([0-9]+)[[:space:]]+([^[:space:]\;\|\&\<\>]+)$ ]]; then
            n="${BASH_REMATCH[1]}"
            if [ "$n" -gt "$LIMIT_LINES" ] 2>/dev/null; then
                target="${BASH_REMATCH[2]}"
            fi
        fi

        [ -n "$target" ] || exit 0
        target=$(strip_quotes "$target")
        [ -n "$target" ] || exit 0
        lines=$(file_line_count "$target") || exit 0
        [ -n "$lines" ] || exit 0
        if [ "$lines" -gt "$LIMIT_LINES" ] 2>/dev/null; then
            clamp_deny "$target" "$lines"
        fi
        ;;

    *)
        exit 0
        ;;
esac

exit 0
