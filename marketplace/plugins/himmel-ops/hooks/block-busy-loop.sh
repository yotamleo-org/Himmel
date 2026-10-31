#!/usr/bin/env bash
# block-busy-loop.sh — PreToolUse hook (matcher "Bash").
#
# Denies a sleepless busy loop: a `while`/`until ...; do :; done` (or
# `do true; done`) loop whose body does nothing, so it spins a core at 100 %
# CPU until something else ends it. The deny names the replacement: a
# `sleep N` in the body, or a pid wait.
#
# Delivered by the himmel-ops PLUGIN lane so it fires in every repo, not only
# a himmel checkout. It sources nothing and its message names no repo script,
# because an adopter repo has neither. This file is the only copy of the rule.
#
# A `;` inside a quoted span is blanked before matching, so a loop head such
# as `while [ "$x" != ";" ]` is still read as one head.
#
# ponytail: the match is textual over the whole command, so a heredoc body or
# a quoted string that holds a whole busy loop is refused too, and a
# backslash-escaped quote can shift the quoted spans; a real shell tokenizer
# would tell data from code if that ever bites.
#
# Hook I/O: the tool-call JSON on stdin. Exit 0 allows; exit 2 denies, and
# stderr is shown to Claude. Each deny appends one JSONL row (ts, session_id,
# decision, loop, body) to BUSY_LOOP_LOG (default
# ~/.claude/busy-loop-guard/denials.jsonl), best-effort.
#
# Fail OPEN (exit 0) on anything it cannot evaluate (no jq, unparseable JSON,
# a non-Bash tool): a workflow nudge, not a security fence.
#
# Bypass: BUSY_LOOP_BYPASS=1 in the shell that launched the agent (session-
# sticky; a per-call prefix does not reach the hook). bash 3.2-safe.
set -uo pipefail

[ "${BUSY_LOOP_BYPASS:-0}" = "1" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

input=$(cat 2>/dev/null) || exit 0
fields=$(jq -r '(.tool_name // "") + "\n" + (.session_id // "") + "\n" + (.tool_input.command // "")' <<<"$input" 2>/dev/null) || exit 0
tool=${fields%%$'\n'*}
rest=${fields#*$'\n'}
session=${rest%%$'\n'*}
cmd=${rest#*$'\n'}

[ "$tool" = "Bash" ] || exit 0

QUOTED_RE="^([^'\"]*)('[^']*'|\"[^\"]*\")(.*)$"
text=""
rest=$cmd
while [[ $rest =~ $QUOTED_RE ]]; do
    span=${BASH_REMATCH[2]}
    text+=${BASH_REMATCH[1]}${span//;/ }
    rest=${BASH_REMATCH[3]}
done
text+=$rest

BUSY_LOOP_RE='(^|[^[:alnum:]_-])(while|until)[[:space:]][^;]*[;[:space:]]+do[[:space:]]+(:|true)[[:space:];]*done([^[:alnum:]_]|$)'
[[ $text =~ $BUSY_LOOP_RE ]] || exit 0
loop=${BASH_REMATCH[2]}
body=${BASH_REMATCH[3]}

log=${BUSY_LOOP_LOG:-${HOME:-}/.claude/busy-loop-guard/denials.jsonl}
if mkdir -p "$(dirname "$log")" 2>/dev/null; then
    jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg session_id "$session" \
        --arg loop "$loop" --arg body "$body" \
        '{ts: $ts, session_id: $session_id, decision: "deny", loop: $loop, body: $body}' \
        >>"$log" 2>/dev/null || true
fi

{
    printf 'busy-loop guard: sleepless busy loop refused.\n\n'
    printf 'A %s loop whose body is only "%s" spins a core at 100%% CPU. Put a\n' "$loop" "$body"
    printf '"sleep N" in the body, or wait on a pid: tail --pid=<pid> -f /dev/null\n\n'
    printf 'Bypass: BUSY_LOOP_BYPASS=1 <launching shell>; a per-call prefix does not work.\n'
} >&2
exit 2
