#!/usr/bin/env bash
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
#
# check-history-comments.sh — refuse NEW code comments that narrate history.
# Agents copy the comments they read, so a ticket-citing or
# review-round comment spreads; the rule is in docs/internals/ponytail-convention.md
# ("Code comments"). Only ADDED lines are judged, so the ~20k existing lines never
# trip it.
#
# A flagged line is an added comment (first non-blank chars `#` or `//`, shebang
# excluded) in a code file, matching one of:
#   a Jira key               (skipped on a `ponytail:` line, the one sanctioned place)
#   a review-fix note, a bot-review round, "round <n>", a judge qid (j + 4 digits + letter)
# Scope: .sh .bash .zsh .ps1 .psm1 .py .js .mjs .cjs .ts .tsx .mts .cts; paths with a
# fixtures/ or *-fixtures/ segment, vendored trees and generated output are skipped.
# ponytail: only whole-line comments are seen, so a trailing comment after code slips through (a
# trailing `#` is indistinguishable from a shell string without a parser); upgrade to a
# per-language tokenizer if trailing history comments start to appear.
#
# Usage:
#   check-history-comments.sh --staged        # git diff --cached (pre-commit)
#   check-history-comments.sh --range <base>  # git diff <base> HEAD (CI, a PR range)
#   check-history-comments.sh --diff <file>   # a unified diff on disk (tests)
# Exit: 0 clean · 1 findings (path:line: text) · 2 cannot evaluate (fail-closed)

set -uo pipefail

usage() { echo "usage: check-history-comments.sh --staged | --range <base> | --diff <file>" >&2; exit 2; }
[ $# -ge 1 ] || usage

DIFF="$(mktemp "${TMPDIR:-/tmp}/check-history-comments.XXXXXX")" || { echo "check-history-comments: mktemp failed" >&2; exit 2; }
trap 'rm -f "$DIFF" "$DIFF.out"' EXIT
case "$1" in
    --staged) base=HEAD
              # during a merge, only lines our side adds relative to the merged-in parent are new
              git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 && base=MERGE_HEAD
              git diff --cached "$base" -U0 --text --no-color --no-ext-diff --no-renames --diff-filter=ACMR > "$DIFF" || { echo "check-history-comments: git diff failed" >&2; exit 2; } ;;
    --range)  [ $# -eq 2 ] || usage
              git diff -U0 --text --no-color --no-ext-diff --no-renames --diff-filter=ACMR "$2" HEAD > "$DIFF" || { echo "check-history-comments: git diff failed" >&2; exit 2; } ;;
    --diff)   [ $# -eq 2 ] && [ -f "$2" ] || usage
              cp "$2" "$DIFF" ;;
    *)        usage ;;
esac

awk '
function in_scope(p) {
    if (p !~ /\.(sh|bash|zsh|ps1|psm1|py|js|mjs|cjs|ts|tsx|mts|cts)$/) return 0
    if (p ~ /(^|\/)[^\/]*fixtures?\//) return 0
    if (p ~ /^(graphify-out|node_modules)\// || p ~ /(^|\/)node_modules\//) return 0
    if (p ~ /^marketplace\/plugins\/claude-hud\// || p ~ /^marketplace\/plugins\/lean-skills\/skills\//) return 0
    if (p ~ /\.obsidian\/plugins\//) return 0
    return 1
}
function why(t,   l) {
    l = tolower(t)
    if (t ~ /HIMMEL-[0-9]+/ && t !~ /(#|\/\/)[ \t]*ponytail:/) return "ticket id"
    if (l ~ /(^|[^a-z0-9])cr fix/) return "CR fix"
    if (l ~ /coderabbit round/) return "CodeRabbit round"
    if (l ~ /(^|[^a-z0-9])round [0-9]+/) return "review round"
    if (l ~ /(^|[^a-z0-9])j[0-9][0-9][0-9][0-9][a-z]([^a-z0-9]|$)/) return "judge qid"
    return ""
}
/^\+\+\+ / { path = substr($0, 7); if ($0 == "+++ /dev/null") path = ""; scope = (path != "" && in_scope(path)); next }
/^@@ / {
    n = $0; sub(/^@@ -[0-9,]+ \+/, "", n); sub(/[ ,].*/, "", n); ln = n + 0; next
}
/^\+/ {
    if (scope) {
        t = substr($0, 2)
        s = t; sub(/^[ \t]+/, "", s)
        if ((s ~ /^#/ && s !~ /^#!/) || s ~ /^\/\//) {
            r = why(s)
            if (r != "") { printf "%s:%d: %s: %s\n", path, ln, r, s; bad = 1 }
        }
    }
    ln++
    next
}
END { exit bad ? 1 : 0 }
' "$DIFF" > "$DIFF.out"
rc=$?
if [ "$rc" -eq 1 ]; then
    cat "$DIFF.out"
    echo "check-history-comments: a code comment states a why the code cannot show; ticket IDs, review rounds, CR fixes and judge qids belong in git and Jira." >&2
    echo "  Delete the history, or fix the workaround in code. Policy: docs/internals/ponytail-convention.md (Code comments)." >&2
elif [ "$rc" -ne 0 ]; then
    echo "check-history-comments: awk failed (rc=$rc)" >&2
    rc=2
fi
rm -f "$DIFF.out"
exit "$rc"
