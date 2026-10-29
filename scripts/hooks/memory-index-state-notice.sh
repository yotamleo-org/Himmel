#!/usr/bin/env bash
# memory-index-state-notice.sh — SessionStart hook: report when the auto-memory
# index MEMORY.md violates the form rules guard-memory-capture.sh enforces.
#
# WHY A STATE CHECK. guard-memory-capture.sh is a PreToolUse guard on
# Edit|Write|MultiEdit|NotebookEdit: it inspects a proposed Write/Edit PAYLOAD.
# Auto-mode tells agents to make file changes with sed, heredocs or short
# scripts, so the default way of working never reaches it — MEMORY.md grew from
# 74 to 134 pointer lines against a ceiling of 60 while the guard logged
# line-ceiling DENIES for the writes it could see. A Bash command line is opaque
# (a heredoc, a `sed -i`, a script that writes three calls later), so gating
# Bash would be leaky and noisy. The invariant is about the FILE, not about how
# it was written, so this reads the file.
#
# WHY SESSIONSTART. That is the moment the harm lands: the always-loaded index
# crowds every session's context, and past the harness load limit (the first 200
# lines or 25 KB) its newest routing lines are not loaded at all. Reporting there
# costs one file read per session and reaches the next session after the write,
# whichever tool made it. The 60-line ceiling is himmel's routing rule, not that
# load limit; the notice reports both, plus topic files over MEMORY_TOPIC_MAX.
#
# WHAT IT IS NOT. An advisory: it DETECTS and REPORTS the violated invariant, it
# does not prevent the write and does not repair the file. The PreToolUse guard
# stays as the earlier, preventive layer where it applies. Residual gap: a
# non-Write/Edit writer is still free to break the ceiling within a session; it
# is caught at the next session start, not at the write.
#
# SILENT ON THE HEALTHY PATH — every line a SessionStart hook emits is paid for
# in every session forever. Output only when a rule is broken.
#
# FAILS OPEN, ALWAYS. This runs on every session on the machine, including
# chiefs and workers; a memory advisory that could block a session from
# starting would be a far worse failure than the ceiling being exceeded. No
# `set -e`, every step is guarded, and the only exit is 0. A missing or
# unreadable MEMORY.md, no git, no awk, a garbage env knob: silent, session
# starts. (Contrast the guard, which fails closed because it is a fence.)
#
# CHEAP. One `git rev-parse` (skipped when MEMDIR is set), one awk pass over
# at most the first 256 KiB of MEMORY.md and one top-level `find` of the memory
# dir (no recursion).
#
# Same rules, same knobs, same defaults as the guard: MEMORY_LINE_CEIL (60),
# MEMORY_LINE_MAX (200), MEMORY_TOPIC_MAX (8192). The load limit has its own
# knobs, MEMORY_LOAD_LINES (200) and MEMORY_BUDGET_BYTES (24400, as the audit).
# Whole-file, not diff-scoped like the guard: a state
# report about a legacy over-length line SHOULD keep ringing until the file is
# fixed — that is the point, and it fires nothing but text.
#
# MEMDIR override (also the test seam) mirrors scripts/memory/audit-memory-capture.sh.
set -uo pipefail
export LC_ALL=C   # byte locale; chars are counted explicitly below (see the guard)

LINE_MAX="${MEMORY_LINE_MAX:-200}"
LINE_CEIL="${MEMORY_LINE_CEIL:-60}"
TOPIC_MAX="${MEMORY_TOPIC_MAX:-8192}"
LOAD_LINES="${MEMORY_LOAD_LINES:-200}"
BUDGET="${MEMORY_BUDGET_BYTES:-24400}"
case "$LINE_MAX$LINE_CEIL$TOPIC_MAX$LOAD_LINES$BUDGET" in ''|*[!0-9]*) exit 0 ;; esac  # garbage knob: stay silent, never fail
# All-digit is not enough: `[ "$n" -gt "$LINE_CEIL" ]` below prints "integer
# expected" to stderr past the shell's integer range. Clamp — a ceiling that
# large is "never exceeded" — so the healthy path stays silent on stderr too.
[ "${#LINE_CEIL}" -le 9 ] || LINE_CEIL=999999999
[ "${#TOPIC_MAX}" -le 9 ] || TOPIC_MAX=999999999
[ "${#LOAD_LINES}" -le 9 ] || LOAD_LINES=999999999
[ "${#BUDGET}" -le 9 ] || BUDGET=999999999

if [ -z "${MEMDIR:-}" ]; then
    # Memory lives under the PRIMARY checkout's project slug, not a worktree's:
    # --git-common-dir points every worktree back at the shared .git dir.
    gcd="$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || exit 0
    [ -n "$gcd" ] || exit 0
    slug="$(printf '%s' "$(dirname "$gcd")" | sed 's/[^A-Za-z0-9]/-/g')"
    MEMDIR="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/projects/$slug/memory"
fi
idx="$MEMDIR/MEMORY.md"
[ -f "$idx" ] && [ -r "$idx" ] || exit 0

# `- ` pointer lines, exactly the guard's definition; CRLF stripped first so a
# CRLF index does not read 1 char longer; continuation bytes dropped so the
# length is characters, not bytes. Prints: <pointers> <n-too-long> <first line numbers…>
res="$(head -c 262144 "$idx" 2>/dev/null | awk -v m="$LINE_MAX" '
    { sub(/\r$/, "") }
    /^- / {
        n++
        s = $0; gsub(/[\200-\277]/, "", s)
        if (length(s) > m) { k++; if (k <= 5) l = l " " NR }
    }
    END { print n + 0, k + 0 l }' 2>/dev/null)" || exit 0
[ -n "$res" ] || exit 0
# shellcheck disable=SC2086  # word-splitting the three awk fields is the point
set -- $res
n="${1:-0}"; k="${2:-0}"; shift 2 2>/dev/null || true
lines="$*"
case "$n$k" in ''|*[!0-9]*) exit 0 ;; esac

over_ceil=0; [ "$n" -gt "$LINE_CEIL" ] && over_ceil=1

# The harness loads only the first 200 lines / 25 KB of the index: a different
# (and harder) limit than himmel's 60-line routing ceiling.
idx_lines="$(head -c 262144 "$idx" 2>/dev/null | awk 'END{print NR+0}')"; idx_bytes="$(head -c 262144 "$idx" 2>/dev/null | wc -c | tr -d ' ')"  # swallow-ok: a non-numeric count resets to 0 on the next line; the notice fails open
case "$idx_lines$idx_bytes" in ''|*[!0-9]*) idx_lines=0; idx_bytes=0 ;; esac
over_load=0; { [ "$idx_lines" -gt "$LOAD_LINES" ] || [ "$idx_bytes" -gt "$BUDGET" ]; } 2>/dev/null && over_load=1

# One top-level listing: topic files (*.md other than the index) past the cap.
topics="$(find -H "$MEMDIR" -maxdepth 1 -type f -name '*.md' ! -name MEMORY.md -size +"$TOPIC_MAX"c 2>/dev/null | sort)"  # swallow-ok: a failed listing reads as no oversized topic files; the notice fails open
n_topic=0; [ -n "$topics" ] && n_topic="$(printf '%s\n' "$topics" | awk 'END{print NR+0}')"
case "$n_topic" in ''|*[!0-9]*) n_topic=0 ;; esac

[ "$over_ceil" -eq 1 ] || [ "$k" -gt 0 ] || [ "$over_load" -eq 1 ] || [ "$n_topic" -gt 0 ] || exit 0

printf '<system-reminder>\n'
printf 'The auto-memory store (MEMORY.md index and topic files) breaks its size rules (state check):\n'
if [ "$over_ceil" -eq 1 ]; then
    printf -- '- line-ceiling: %s pointer lines (ceiling %s). That ceiling is himmel'"'"'s routing rule (one routing line per theme), not the harness load limit: it keeps the index small enough to route.\n' "$n" "$LINE_CEIL"
fi
if [ "$over_load" -eq 1 ]; then
    printf -- '- load-limit: MEMORY.md is %s lines / %s bytes, past the notice threshold of %s lines / %s bytes; the harness loads only about the first 200 lines or 25 KB of an index, so lines past that are not loaded.\n' "$idx_lines" "$idx_bytes" "$LOAD_LINES" "$BUDGET"
fi
if [ "$k" -gt 0 ]; then
    printf -- '- line-too-long: %s pointer line(s) exceed %s chars (line%s %s).\n' "$k" "$LINE_MAX" "$([ "$k" -gt 1 ] && printf s)" "$lines"
fi
if [ "$n_topic" -gt 0 ]; then
    printf -- '- topic-cap: %s topic file(s) over %s bytes (%s). A keyword match reads the whole file; split each into a hub plus sub-files of at most about 5 KB (himmel-ops:memory-compound).\n' "$n_topic" "$TOPIC_MAX" "$(printf '%s\n' "$topics" | head -5 | while IFS= read -r t; do printf '%s ' "$(basename "$t")"; done)"
fi
printf '\nfile: %s\n' "$idx"
printf 'guard-memory-capture.sh only sees Write/Edit; a heredoc, sed or script write reaches the file unseen, so this reads the files itself.\n'
printf 'Tell the operator in your first reply.'
if [ "$over_ceil" -eq 1 ] || [ "$k" -gt 0 ] || [ "$over_load" -eq 1 ]; then
    printf ' Do NOT append more index lines; evict facts to their theme topic files (himmel-ops:memory-compound).'
fi
printf '\n'
printf '</system-reminder>\n'
exit 0
