#!/usr/bin/env bash
#   check-no-absent-search-tools.sh           scan the agent files and hook scripts, from the repo root
#   check-no-absent-search-tools.sh FILE...   scan these files (*.md as an agent file, anything else as a hook script)
#
# Agent file: the `tools:` line of its frontmatter lists Grep or Glob as a tool.
# Hook script: a non-comment line says to use, try or search with the Grep or Glob tool.
# Exit: 0 clean, 1 a hit, 2 cannot evaluate (a named file is unreadable, or the repo scan finds no file).
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"

HOOKS_FIXED_ELSEWHERE='block-subagent-release-operator.sh'

HOOK_SAYS='(use|using|try|trying|with|via)[[:space:]]+(the[[:space:]]+)?(Grep|Glob)[[:space:]]+tool'

hits=0

scan_agent() {
    local file=$1 tools listed
    [ -r "$file" ] || { echo "check-no-absent-search-tools: cannot read: $file" >&2; exit 2; }
    tools=$(awk 'NR == 1 { if ($0 != "---") exit; next } /^---[[:space:]]*$/ { exit } /^tools:/ { print; exit }' "$file") ||
        { echo "check-no-absent-search-tools: awk failed on: $file" >&2; exit 2; }
    listed=$(printf '%s\n' "${tools#tools:}" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -x -E 'Grep|Glob')
    if [ -n "$listed" ]; then
        echo "HIT $file: tools line lists the Grep or Glob tool, which sessions here do not load: $tools"
        hits=$((hits + 1))
    fi
}

scan_hook() {
    local file=$1 found
    [ -r "$file" ] || { echo "check-no-absent-search-tools: cannot read: $file" >&2; exit 2; }
    found=$(grep -n -i -E "$HOOK_SAYS" "$file" | grep -v -E '^[0-9]+:[[:space:]]*#')
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        echo "HIT $file:${line%%:*}: refusal text names the Grep or Glob tool, which sessions here do not load"
        hits=$((hits + 1))
    done <<<"$found"
}

if [ "$#" -gt 0 ]; then
    for f in "$@"; do
        case "$f" in
            *.md) scan_agent "$f" ;;
            *) scan_hook "$f" ;;
        esac
    done
else
    cd "$root" || exit 2
    agents=0 hooksn=0
    for f in .claude/agents/*.md marketplace/plugins/*/agents/*.md; do
        [ -f "$f" ] || continue
        agents=$((agents + 1))
        scan_agent "$f"
    done
    for f in scripts/hooks/*.sh marketplace/plugins/*/hooks/*.sh; do
        [ -f "$f" ] || continue
        case "${f##*/}" in test-*) continue ;; esac
        case " $HOOKS_FIXED_ELSEWHERE " in *" ${f##*/} "*) continue ;; esac
        hooksn=$((hooksn + 1))
        scan_hook "$f"
    done
    if [ "$agents" -eq 0 ] || [ "$hooksn" -eq 0 ]; then
        echo "check-no-absent-search-tools: found $agents agent files and $hooksn hook scripts; cannot evaluate" >&2
        exit 2
    fi
fi

if [ "$hits" -gt 0 ]; then
    echo "check-no-absent-search-tools: $hits hit(s); name grep, git grep, find with -maxdepth or git ls-files through Bash instead" >&2
    exit 1
fi
echo "check-no-absent-search-tools: clean"
exit 0
