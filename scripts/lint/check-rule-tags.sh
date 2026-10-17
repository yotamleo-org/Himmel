#!/usr/bin/env bash
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
#
# check-rule-tags.sh — every rule line of the always-loaded prose says whether the
# harness enforces it. A rule line is a column-0 bullet (`- `, `* `; numbered items are procedure steps) outside
# a code fence and outside the upstream-owned `## graphify` section; the item runs to
# the first blank line, the next column-0 item or the next heading, and its LAST line
# must end with one of:
#   [enforced: <name>]   <name> is a row of the generated table
#                        (scripts/lint/list-enforced-rules.sh --names)
#   [prose]              nothing enforces it: the escalation backlog
# Why: an agent cannot tell a hard rule from a soft one, and an operator cannot prune
# prose safely; the tag makes both answers a grep. Doctrine: docs/internals/context-architecture.md.
# ponytail: only list items are rule lines, so a rule written as a plain paragraph is not
# seen; upgrade to a per-section marker if paragraph rules start to appear in the tagged files.
#
# Usage:
#   check-rule-tags.sh [--enforced-list <file>] [<file>...]
#     no files            the tagged set: CLAUDE.md, docs/handover/leg-preface.md,
#                         docs/handover/console-template.md
#     --enforced-list     newline-separated names instead of the generated ones (tests)
# Exit: 0 clean · 1 findings (file:line: text) · 2 cannot evaluate (fail-closed)

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
LIST=""
FILES=()

while [ $# -gt 0 ]; do
    case "$1" in
        --enforced-list) [ $# -ge 2 ] || { echo "check-rule-tags: --enforced-list needs a file" >&2; exit 2; }; LIST="$2"; shift 2 ;;
        -*) echo "usage: check-rule-tags.sh [--enforced-list <file>] [<file>...]" >&2; exit 2 ;;
        *) FILES+=("$1"); shift ;;
    esac
done

if [ "${#FILES[@]}" -eq 0 ]; then
    FILES=("$REPO_ROOT/CLAUDE.md" "$REPO_ROOT/docs/handover/leg-preface.md" "$REPO_ROOT/docs/handover/console-template.md")
fi
for f in "${FILES[@]}"; do
    [ -f "$f" ] || { echo "check-rule-tags: no such file: $f" >&2; exit 2; }
done

names="$(mktemp "${TMPDIR:-/tmp}/rule-tags-names.XXXXXX")" || { echo "check-rule-tags: mktemp failed" >&2; exit 2; }
trap 'rm -f "$names"' EXIT
if [ -n "$LIST" ]; then
    [ -f "$LIST" ] || { echo "check-rule-tags: no such file: $LIST" >&2; exit 2; }
    cp "$LIST" "$names"
else
    bash "$SELF_DIR/list-enforced-rules.sh" --names > "$names" || { echo "check-rule-tags: cannot generate the enforced list" >&2; exit 2; }
fi

fail=0
for f in "${FILES[@]}"; do
    out="$(LC_ALL=C awk -v file="$f" -v namesfile="$names" '
        BEGIN { while ((getline n < namesfile) > 0) known[n] = 1 }
        function check(   tag, name) {
            if (start == 0) return
            if (last !~ /\[(prose|enforced:[^]]*)\][[:space:]]*$/) {
                printf "%s:%d: rule line has no [enforced: <name>] or [prose] tag: %s\n", file, start, first; bad = 1
            } else if (match(last, /\[enforced:[^]]*\][[:space:]]*$/)) {
                tag = substr(last, RSTART, RLENGTH); name = tag
                sub(/^\[enforced:[[:space:]]*/, "", name); sub(/\][[:space:]]*$/, "", name)
                if (name == "") { printf "%s:%d: empty [enforced: ] tag: %s\n", file, start, first; bad = 1 }
                else if (!(name in known)) { printf "%s:%d: [enforced: %s] is not a row of the enforced-rule table\n", file, start, name; bad = 1 }
            }
            start = 0
        }
        /^```/ { check(); fence = !fence; next }
        fence { next }
        /^#+[[:space:]]/ {
            check()
            skip = ($0 ~ /^[[:space:]]*## graphify[[:space:]]*$/) ? 1 : (skip && $0 !~ /^## /) ? skip : 0
            next
        }
        skip { next }
        /^[[:space:]]*$/ { check(); next }
        /^[-*][[:space:]]/ { check(); start = NR; first = substr($0, 1, 70); last = $0; next }
        start { last = $0 }
        END { check(); exit bad }
    ' "$f")" || fail=1
    [ -z "$out" ] || printf '%s\n' "$out"
done

exit "$fail"
