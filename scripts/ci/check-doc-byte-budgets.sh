#!/usr/bin/env bash
# The byte budgets on committed docs that are paid on every turn.
#
# One owner for the three plain byte counts: the two suites that held them
# (test-gen-briefs.sh, test-pr-check-pair.sh) and the merge-time static
# re-check in merge-on-green.sh all call this script, so the number lives here
# and nowhere else. The root is this script's own ../.., so a copy inside a
# merge result measures that merge result.
#
# Usage: check-doc-byte-budgets.sh [<repo-relative path>...]
#   no argument: every row; with paths: those rows only.
# Exit: 0 all within budget · 1 any over · 2 any row cannot be measured
# (missing, a link, a link in its directory, no such row); 2 wins over 1.
# Reads no environment variable; CDPATH is neutralised for the root lookup.
set -uo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd -P)" || { echo "doc-byte-budgets: cannot resolve the repo root" >&2; exit 2; }

ROWS=$(cat <<'EOF'
docs/handover/worker-preface.md 13500
docs/handover/chief-template.md 19000
.claude/commands/pr-check.md 10239
EOF
)

worst=0
note() { if [ "$1" -gt "$worst" ]; then worst="$1"; fi; }

check_row() {
    local path="$1" max="$2" file="$ROOT/$1" dir n
    if [ -L "$file" ]; then
        echo "doc-byte-budgets: $path is a symlink, not measured"; return 2
    fi
    if [ ! -f "$file" ]; then
        echo "doc-byte-budgets: $path is missing or not a regular file, not measured"; return 2
    fi
    dir="$(CDPATH='' cd -- "$(dirname -- "$file")" && pwd -P)"
    if [ "$dir" != "$ROOT/$(dirname -- "$path")" ]; then
        echo "doc-byte-budgets: $path sits under a symlinked directory, not measured"; return 2
    fi
    n="$(wc -c < "$file")"; n=${n//[!0-9]/}
    if [ "$n" -le "$max" ]; then
        echo "doc-byte-budgets: ok $path $n <= $max"; return 0
    fi
    echo "doc-byte-budgets: $path is $n bytes, over its ${max}-byte budget (+$((n - max)))"; return 1
}

row_max() {
    local p m
    while read -r p m; do
        if [ "$p" = "$1" ]; then echo "$m"; return 0; fi
    done <<< "$ROWS"
}

if [ "$#" -eq 0 ]; then
    while read -r p m; do
        rc=0; check_row "$p" "$m" || rc=$?
        note "$rc"
    done <<< "$ROWS"
else
    for arg in "$@"; do
        m="$(row_max "$arg")"
        if [ -z "$m" ]; then
            echo "doc-byte-budgets: $arg has no budget row, not measured"; note 2; continue
        fi
        rc=0; check_row "$arg" "$m" || rc=$?
        note "$rc"
    done
fi

exit "$worst"
