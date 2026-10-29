#!/usr/bin/env bash
# PostToolUse Bash hook: re-check the auto-memory MEMORY.md line
# rule after a Bash command that names it.
#
# guard-memory-capture.sh only sees Write/Edit payloads; a heredoc, `sed -i`,
# `tee` or `printf >>` reaches the index unseen, and an over-long routing line
# was only caught a session later by the SessionStart state check.
# A Bash command line is opaque, so this reads the FILE after the call, with
# the same rule the guard uses (memory-line-check.sh, one definition).
#
# It also reports a topic file the command names that is over MEMORY_TOPIC_MAX
# (8192): the PreToolUse guard never sees a heredoc write to one either.
#
# Cheap: exits 0 at once unless the command text names a memory file. A WORKFLOW
# NUDGE, not a fence: it fails open on its own infrastructure errors (no jq,
# unparseable payload, unreadable file). It warns (exit 2 -> stderr reaches the
# model) because PostToolUse cannot undo the write; the remedy is to fix the
# named line in place with the Edit tool, which the PreToolUse guard checks.
#
# Whole-file, not diff-scoped: it names every over-long line, so a legacy line
# keeps ringing until fixed. Bypass: MEMORY_CAPTURE_OK=1 in the launching shell
# (same as the guard).
set -uo pipefail

payload="$(cat)"   # drain stdin before any early exit (no SIGPIPE on the writer)
[ "${MEMORY_CAPTURE_OK:-0}" = "1" ] && exit 0
case "$payload" in */memory/*.md*) ;; *) exit 0 ;; esac
command -v jq >/dev/null 2>&1 || exit 0
[ "$(printf '%s' "$payload" | jq -r '.tool_name // ""' 2>/dev/null)" = "Bash" ] || exit 0
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null)" || exit 0

here="$(cd "$(dirname "$0")" && pwd)"
LINE_MAX="${MEMORY_LINE_MAX:-200}"
TOPIC_MAX="${MEMORY_TOPIC_MAX:-8192}"
bad=""
big=""
# Every absolute auto-memory .md path the command names (a `~` or `$HOME`
# spelling expands to one in the shell, so only the literal path is matched here
# plus the two common home spellings, resolved below).
# Read line by line (an unquoted $(...) would glob a `*` in the command text) and
# dedupe, so a command naming one path 5000 times checks it once.
paths="$(printf '%s' "$cmd" | grep -oE '[^[:space:]"'"'"'=<>|;&()]*/\.claude/projects/[^[:space:]"'"'"'/]+/memory/[^[:space:]"'"'"'/]+\.md' | sort -u)"
while IFS= read -r p; do
    [ -n "$p" ] || continue
    # shellcheck disable=SC2088,SC2016  # literal command TEXT, deliberately unexpanded
    case "$p" in
        '~/'*) p="${HOME:-}/${p#\~/}" ;;
        '$HOME/'*) p="${HOME:-}/${p#\$HOME/}" ;;
        '${HOME}/'*) p="${HOME:-}/${p#\$\{HOME\}/}" ;;
    esac
    [ -r "$p" ] || continue
    if [ "$(basename "$p")" != MEMORY.md ]; then
        sz="$(wc -c 2>/dev/null < "$p" | tr -d ' ')"  # swallow-ok: an unsized file is skipped by the digit check below (workflow nudge, fails open)
        case "$sz" in ''|*[!0-9]*) continue ;; esac
        [ "$sz" -gt "$TOPIC_MAX" ] 2>/dev/null && big="$big$p: ${sz}B
"
        continue
    fi
    nums="$(bash "$here/memory-line-check.sh" < "$p" 2>/dev/null)" && continue
    [ -n "$nums" ] || continue
    bad="$bad$p: line $(printf '%s' "$nums" | tr '\n' ' ')
"
done <<EOF
$paths
EOF
[ -n "$bad" ] || [ -n "$big" ] || exit 0

{
    if [ -n "$bad" ]; then
        printf 'MEMORY INDEX LINE TOO LONG: a Bash write left MEMORY.md with a routing line over %s chars.\n' "$LINE_MAX"
        printf '%s' "$bad"
        printf 'The index routes; it does not store. Move the fact into its theme topic file and shorten the line\n'
        printf 'in place with the Edit tool (guard-memory-capture.sh checks that path). Bypass: MEMORY_CAPTURE_OK=1 in the launching shell.\n'
    fi
    if [ -n "$big" ]; then
        printf 'MEMORY TOPIC FILE OVER THE CAP (topic-cap): a topic file the command names is over %s bytes.\n' "$TOPIC_MAX"
        printf '%s' "$big"
        printf 'Split the theme with himmel-ops:memory-compound into a hub plus sub-files of at most about 5 KB; mid-task, add the\n'
        printf 'new fact to a new sub-file linked from its hub (a link line in the hub file, not a new index line).\n'
    fi
} >&2
exit 2
