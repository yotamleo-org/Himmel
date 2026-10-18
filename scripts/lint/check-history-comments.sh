#!/usr/bin/env bash
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
#
# check-history-comments.sh — refuse NEW history comments and ticket ids in output.
# Agents copy the comments they read, so a ticket-citing or
# review-round comment spreads; the rule is in docs/internals/ponytail-convention.md
# ("Code comments"). Only ADDED lines are judged, so the ~20k existing lines never
# trip it.
#
# A flagged line is an added comment (first non-blank chars `#` or `//`, shebang
# excluded) in a code file, matching one of:
#   a Jira key               (skipped on a `ponytail:` line, the one sanctioned place)
#   a review-fix note, a bot-review round, "round <n>", a judge qid (j + 4 digits + letter)
# Added output calls carrying a Jira key are also refused (shell echo/printf/die/warn/say,
# JS/TS console.log/error/warn and process.stdout/stderr.write, Python print/sys.stderr.write).
# Output in test files and lines carrying ponytail: are exempt; history-ok is not supported.
# Scope: .sh .bash .zsh .ps1 .psm1 .py .js .mjs .cjs .ts .tsx .mts .cts; paths with a
# fixtures/ or *-fixtures/ segment, archive/, vendored trees and generated output are skipped.
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
    --diff)   if [ $# -ne 2 ] || [ ! -f "$2" ]; then usage; fi
              cp "$2" "$DIFF" ;;
    *)        usage ;;
esac

awk '
function in_scope(p) {
    if (p !~ /\.(sh|bash|zsh|ps1|psm1|py|js|mjs|cjs|ts|tsx|mts|cts)$/) return 0
    if (p ~ /^archive\//) return 0
    if (p ~ /(^|\/)[^\/]*fixtures?\//) return 0
    if (p ~ /^(graphify-out|node_modules)\// || p ~ /(^|\/)node_modules\//) return 0
    if (p ~ /^marketplace\/plugins\/claude-hud\// || p ~ /^marketplace\/plugins\/lean-skills\/skills\//) return 0
    if (p ~ /\.obsidian\/plugins\//) return 0
    return 1
}
function output_call(p, s,   i, c, q, code, single) {
    if (p ~ /(^|\/)(tests?|__tests__)\// || p ~ /(^|\/)test[-_][^\/]+$/ || p ~ /\.(test|spec)\.[^.]+$/) return 0
    single = sprintf("%c", 39)
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\\" && q != single) { i++; code = code " "; continue }
        if (q != "") {
            if (c == q) q = ""
            continue
        }
        if (c == single || c == "\"" || (c == "`" && p ~ /\.(js|mjs|cjs|ts|tsx|mts|cts)$/)) {
            q = c; code = code " "; continue
        }
        code = code c
    }
    if (p ~ /\.(sh|bash|zsh)$/)
        return code ~ /(^|[;&|(){}])[ \t]*((then|do|else)[ \t]+)?([0-9]*>&[0-9]+[ \t]*)?(echo|printf|die|warn|say)[ \t]+/
    if (p ~ /\.(js|mjs|cjs|ts|tsx|mts|cts)$/)
        return code ~ /(^|[;{}])[ \t]*(console\.(log|error|warn)|process\.(stdout|stderr)\.write)[ \t]*\(/
    if (p ~ /\.py$/)
        return code ~ /(^|[;:])[ \t]*(print|sys\.stderr\.write)[ \t]*\(/
    return 0
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
        r = ""
        if ((s ~ /^#/ && s !~ /^#!/) || s ~ /^\/\//) r = why(s)
        else if (output_call(path, s) && s ~ /HIMMEL-[0-9]+/ && s !~ /ponytail:/) r = "ticket id"
        if (r != "") { printf "%s:%d: %s: %s\n", path, ln, r, s; bad = 1 }
    }
    ln++
    next
}
END { exit bad ? 1 : 0 }
' "$DIFF" > "$DIFF.out"
rc=$?
if [ "$rc" -eq 1 ]; then
    cat "$DIFF.out"
    echo "check-history-comments: ticket IDs in output, and ticket IDs, review rounds, CR fixes and judge qids in comments belong in git and Jira." >&2
    echo "  Delete the history, or fix the workaround in code. Policy: docs/internals/ponytail-convention.md (Code comments)." >&2
elif [ "$rc" -ne 0 ]; then
    echo "check-history-comments: awk failed (rc=$rc)" >&2
    rc=2
fi
rm -f "$DIFF.out"
exit "$rc"
