#!/usr/bin/env bash
# check-taught-search-forms.sh — every search command himmel TEACHES must be a form
# that runs. A bare `qmd query|search|vsearch` is refused by block-bare-qmd-query.sh, and a bare
# `graphify query|explain|path` failed 35 of 58 times from a worktree (the wrapper
# `bash scripts/graphify/worker-graph.sh` resolves the graph there). A session that copies a taught
# form that gets refused falls back to searching by hand.
#
#   check-taught-search-forms.sh            scan the taught files (list below), from the repo root
#   check-taught-search-forms.sh FILE...    scan these files whole (the test plants a bare form this way)
#
# A line is a hit when `qmd` is followed by query|search|vsearch, or `graphify` by query|explain|path,
# as a command (not as part of a path, an MCP tool name or a `qmd_bounded` call inside a sourced script).
# A deliberate mention of the refused form carries the marker `taught-form-ok` on the same line.
# In CLAUDE.md the `## graphify` section is installer-owned (docs/token-economy.md) and is not scanned;
# himmel's own rules above it name the wrapper and win where they differ.
# Exit: 0 clean, 1 a bare taught form, 2 cannot evaluate (a listed file is missing or unreadable, or a file
# or its line filter yields no line to scan).
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"

# file[|line-filter]: a line filter limits a hook script to its user-facing message lines, since the
# rest of a hook is code and comments that quote the forms it refuses.
# ponytail: the judge brief template and the two judge agent files join this list when the judge search
# commands are rewritten (held for the blind-vs-context judge eval); until then
# they still teach the bare graph form.
TAUGHT='CLAUDE.md
docs/token-economy.md
docs/handover/chief-template.md
docs/handover/running-a-chief.md
docs/handover/worker-brief-template.md
marketplace/plugins/qmd/skills/qmd/SKILL.md
scripts/hooks/retrieval-nudge.sh|Retrieval nudge:
scripts/hooks/block-graphify-egress.sh|for read-only queries use:'

BARE='(^|[^A-Za-z0-9_./-])(qmd[[:space:]]+(query|search|vsearch)|graphify[[:space:]]+(query|explain|path))([^A-Za-z0-9_-]|$)'

# an MCP tool name, and the qmd_bounded call of a sourced script (qmd is its argument there, not the program)
EXEMPT='mcp__[A-Za-z0-9_]*|qmd_bounded[[:space:]]+[0-9]+[[:space:]]+qmd[[:space:]]+(query|search|vsearch)'

hits=0

# scan FILE FILTER — print a hit per line of FILE (filter: only lines holding it; empty: all lines)
scan() {
    local file=$1 filter=$2 body
    [ -f "$file" ] || { echo "check-taught-search-forms: no such file: $file" >&2; exit 2; }
    body=$(cat "$file") || { echo "check-taught-search-forms: cannot read: $file" >&2; exit 2; }
    case "${file##*/}" in
        CLAUDE.md)
            # the installer's own boundary rule: a line that is exactly `## graphify` up to the next column-zero `## `
            body=$(printf '%s\n' "$body" | awk '/^## graphify[[:space:]]*$/ { skip = 1; next } /^## / { skip = 0 } !skip')
            ;;
    esac
    # the shell reads `qmd \<newline> query` as one command, so join continuations before matching
    body=$(printf '%s\n' "$body" | awk '{ if (sub(/\\$/, "")) { buf = buf $0; next } print buf $0; buf = "" } END { if (buf != "") print buf }')
    local line seen=0
    while IFS= read -r line; do
        [ -z "$filter" ] || [[ $line == *"$filter"* ]] || continue
        [ -n "$line" ] || continue
        seen=$((seen + 1))
        [[ $line == *taught-form-ok* ]] && continue
        # drop the exempt tokens, not the whole line: a bare form beside an MCP tool name still hits
        while [[ $line =~ $EXEMPT ]]; do line=${line/"${BASH_REMATCH[0]}"/}; done
        if [[ $line =~ $BARE ]]; then
            printf '%s: a bare taught search form: %s\n' "$file" "${line:0:160}"
            hits=$((hits + 1))
        fi
    done <<<"$body"
    # a filter that matches no line, or an empty body, scanned nothing: that is no clean pass
    [ "$seen" -gt 0 ] || { echo "check-taught-search-forms: scanned no line of $file${filter:+ (filter: $filter)}" >&2; exit 2; }
}

if [ "$#" -gt 0 ]; then
    for f in "$@"; do scan "$f" ""; done
else
    cd "$root" || exit 2
    while IFS= read -r spec; do
        [ -n "$spec" ] || continue
        filter=""
        case "$spec" in *'|'*) filter=${spec#*|} ;; esac
        scan "${spec%%|*}" "$filter"
    done <<<"$TAUGHT"
fi

if [ "$hits" -gt 0 ]; then
    echo "check-taught-search-forms: $hits bare form(s). Teach 'bash scripts/lib/qmd-bounded.sh query -c NAME \"<question>\"' and 'bash scripts/graphify/worker-graph.sh query|explain|path \"<x>\"', or mark a deliberate mention with taught-form-ok." >&2
    exit 1
fi
exit 0
