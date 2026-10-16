#!/usr/bin/env bash
# retrieval-nudge.sh — PostToolUse advisory.
#
# WHY: legs are told to use leg-graph.sh and qmd, yet most never called either
# while running several grep/find sweeps each. Prose drifted twice, so this is
# the structural reminder: once a session has run 5 broad search sweeps and
# made NO qmd or graphify call, emit ONE additionalContext line, once per session.
#
# ADVISORY ONLY. Never a deny, never a block, always exit 0: an exact-symbol
# grep stays the right tool, so the nudge only reminds. Fail OPEN on every
# infrastructure problem (no jq, bad JSON, unwritable state dir).
# Applies to legs, consoles and judges alike; none is exempt.
#
# Sweep = Grep/Glob tool call, or a Bash call with a segment that is `grep -r`,
# `rg`, `git grep`, `git log -S`, or a `find` carrying a match predicate (a bare
# `find DIR -type d` listing is not a search). Retrieval = any mcp__qmd__ tool,
# qmd-bounded.sh / `qmd query|search|get…`, or graphify / leg-graph.sh
# query|explain|path. A retrieval call stops the nudge for the session.
#
# State: per-session files under $RETRIEVAL_NUDGE_DIR (default
# ${TMPDIR:-/tmp}/himmel-retrieval-nudge-<uid>): <sid>.n (sweep count),
# <sid>.stop (retrieval seen or nudge already sent).
set -uo pipefail

THRESHOLD="${RETRIEVAL_NUDGE_THRESHOLD:-5}"
case "$THRESHOLD" in ''|*[!0-9]*) THRESHOLD=5 ;; esac

command -v jq >/dev/null 2>&1 || exit 0
input="$(cat 2>/dev/null)" || exit 0
[ -n "$input" ] || exit 0

fields="$(printf '%s' "$input" | jq -r '[.session_id // "", .tool_name // "", (.tool_input.command // "" | tostring | .[0:4000] | gsub("\n"; "\u0001"))] | join("\u0002")' 2>/dev/null)" || exit 0
sid="${fields%%$'\002'*}"
rest="${fields#*$'\002'}"
tool="${rest%%$'\002'*}"
cmd="${rest#*$'\002'}"
cmd="${cmd//$'\001'/$'\n'}"
sid="${sid//[!A-Za-z0-9_-]/_}"
[ -n "$sid" ] || exit 0

DIR="${RETRIEVAL_NUDGE_DIR:-${TMPDIR:-/tmp}/himmel-retrieval-nudge-$(id -u)}"
mkdir -p "$DIR" 2>/dev/null || exit 0
[ -e "$DIR/$sid.stop" ] && exit 0

kind=""   # retrieval | sweep
case "$tool" in
    mcp__qmd__*) kind=retrieval ;;
    Grep|Glob) kind=sweep ;;
    Bash)
        # Quoted text (commit messages, echo args) is not a command: blank it,
        # then split on command separators.
        flat="$(printf '%s' "$cmd" | sed -E "s/'[^']*'/Q/g; s/\"([^\"\\\\]|\\\\.)*\"/Q/g" | tr ';|&' '\n')"
        while IFS= read -r seg; do
            seg="$(printf '%s' "$seg" | sed -E 's/^[[:space:]]+//; s/^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)+//; s/^((timeout[[:space:]]+[^[:space:]]+|rtk([[:space:]]+proxy)?|env|command|bash|sh)[[:space:]]+)+//')"
            if printf '%s' "$seg" | grep -Eq '(^|/)qmd-bounded\.sh([[:space:]]|$)|^qmd[[:space:]]+(-[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+)*(query|search|vsearch|get|multi-get)([[:space:]]|$)|(^|/)graphify[[:space:]]+(query|explain|path)([[:space:]]|$)|(^|/)leg-graph\.sh[[:space:]]+(query|explain|path)([[:space:]]|$)'; then
                kind=retrieval
                break
            elif printf '%s' "$seg" | grep -Eq '^(grep[[:space:]]+(-[A-Za-z]*[rR][A-Za-z]*|--recursive)([[:space:]]|$)|rg([[:space:]]|$)|git[[:space:]]+grep([[:space:]]|$)|git[[:space:]]+log[[:space:]]+([^[:space:]]+[[:space:]]+)*-S)'; then
                kind=sweep
            elif printf '%s' "$seg" | grep -Eq '^find[[:space:]]' && printf '%s' "$seg" | grep -Eq '[[:space:]]-(name|iname|path|ipath|regex|iregex|exec|newer)([[:space:]]|$)'; then
                kind=sweep
            fi
        done <<<"$flat"
        ;;
esac

case "$kind" in
    retrieval) : >"$DIR/$sid.stop" 2>/dev/null; exit 0 ;;
    sweep) ;;
    *) exit 0 ;;
esac

n=0
[ -r "$DIR/$sid.n" ] && n="$(cat "$DIR/$sid.n" 2>/dev/null)"
case "$n" in ''|*[!0-9]*) n=0 ;; esac
n=$((n + 1))
printf '%s\n' "$n" >"$DIR/$sid.n" 2>/dev/null || exit 0
[ "$n" -ge "$THRESHOLD" ] || exit 0

: >"$DIR/$sid.stop" 2>/dev/null || exit 0
ctx="Retrieval nudge: $n search sweeps this session (grep/rg/git grep/find/Grep/Glob) and no qmd or graphify call. For structure or who-calls/who-imports questions try: bash scripts/graphify/leg-graph.sh explain \"<concept>\" (or query \"<question>\"). For history, decisions or cross-repo content try: bash scripts/lib/qmd-bounded.sh query -c NAME \"<question>\". An exact-symbol grep is still fine, and a miss from either tool is unproven: confirm with grep/git. This reminder appears once per session."
jq -nc --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c}}' 2>/dev/null
exit 0
