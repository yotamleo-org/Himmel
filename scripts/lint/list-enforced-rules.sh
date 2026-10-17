#!/usr/bin/env bash
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+ with jq.
#
# list-enforced-rules.sh — print the enforced-rule table: every hook the project
# hook config wires (name, event, matcher) and every pre-commit gate (id, stage).
# Read-only. A rule line tagged `[enforced: <name>]` must name a row of this table
# (scripts/lint/check-rule-tags.sh), so the table is the one list of what the
# harness enforces and the prose carries only the rules it does not.
#
# A hook "name" is the basename, without extension, of each script under scripts/
# that a hook command runs; the dispatcher and node launcher are plumbing, not rules.
#
# Usage:
#   list-enforced-rules.sh [--settings <file>] [--precommit <file>] [--names]
#     --names   print only the distinct names, one per line (the lint's input)
# Exit: 0 ok · 2 cannot evaluate (missing or malformed config; fail-closed)
# ponytail: a pre-commit hook's `stages:` is read only as an inline list on one line,
# upgrade to a YAML parser if a config ever uses the block form.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
SETTINGS="$REPO_ROOT/.claude/settings"".json"
PRECOMMIT="$REPO_ROOT/.pre-commit-config.yaml"
NAMES_ONLY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --settings)  [ $# -ge 2 ] || { echo "list-enforced-rules: --settings needs a file" >&2; exit 2; }; SETTINGS="$2"; shift 2 ;;
        --precommit) [ $# -ge 2 ] || { echo "list-enforced-rules: --precommit needs a file" >&2; exit 2; }; PRECOMMIT="$2"; shift 2 ;;
        --names)     NAMES_ONLY=1; shift ;;
        *) echo "usage: list-enforced-rules.sh [--settings <file>] [--precommit <file>] [--names]" >&2; exit 2 ;;
    esac
done

[ -f "$SETTINGS" ] || { echo "list-enforced-rules: no such file: $SETTINGS" >&2; exit 2; }
[ -f "$PRECOMMIT" ] || { echo "list-enforced-rules: no such file: $PRECOMMIT" >&2; exit 2; }

# name<TAB>event<TAB>matcher, in config order, first sighting of a (name,event,matcher) kept.
hook_rows="$(jq -r '
    (.hooks // {}) | to_entries[] | .key as $ev
    | .value[] | (.matcher // "*") as $m
    | .hooks[].command
    | [scan("scripts/[A-Za-z0-9_./-]+\\.(?:sh|mjs|ts)")]
    | map(select(test("run-node\\.sh$") | not))
    | .[]
    | sub("^.*/"; "") | sub("\\.[a-z]+$"; "")
    | [., $ev, $m] | @tsv' "$SETTINGS" 2>/dev/null)" \
    || { echo "list-enforced-rules: cannot parse $SETTINGS" >&2; exit 2; }
hook_rows="$(printf '%s\n' "$hook_rows" | awk 'NF && !seen[$0]++')"

gate_rows="$(LC_ALL=C awk '
    function flush(   n, i, parts) {
        if (id == "") return
        n = split(stages, parts, /[ ,]+/)
        for (i = 1; i <= n; i++) if (parts[i] != "") print id "\t" parts[i] "\t-"
        id = ""
    }
    /^[[:space:]]*-[[:space:]]+id:[[:space:]]*/ {
        flush(); id = $0; sub(/^[[:space:]]*-[[:space:]]+id:[[:space:]]*/, "", id); sub(/[[:space:]]+$/, "", id)
        stages = "pre-commit"; next
    }
    id != "" && /^[[:space:]]+stages:[[:space:]]*\[/ {
        s = $0; sub(/^[^[]*\[/, "", s); sub(/\].*$/, "", s); stages = s
    }
    END { flush() }' "$PRECOMMIT")" \
    || { echo "list-enforced-rules: cannot parse $PRECOMMIT" >&2; exit 2; }

rows="$(printf '%s\n%s\n' "$hook_rows" "$gate_rows" | awk 'NF')"

if [ "$NAMES_ONLY" -eq 1 ]; then
    printf '%s\n' "$rows" | cut -f1 | awk '!seen[$0]++'
    exit 0
fi

echo '| name | event | matcher |'
echo '|---|---|---|'
printf '%s\n' "$rows" | awk -F'\t' '{ printf "| %s | %s | %s |\n", $1, $2, $3 }'
