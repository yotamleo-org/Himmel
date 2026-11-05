#!/usr/bin/env bash
# Platform guard (posix-bash): POSIX bash 3.2+.
#
# check-history-comments.sh — refuse NEW ticket keys in tracked text and NEW history comments in code.
# Agents copy the lines they read, so a ticket-citing or review-round line spreads; the
# rule is in docs/internals/ponytail-convention.md ("Code comments"). Only ADDED lines
# are judged, so the existing lines never trip it.
#
# One classifier (ticket-refs.awk) and one rule list (ticket-ref-allow.tsv) sit beside
# this script and decide every line; the key pattern lives only in the list's `key` row.
#   an added line carrying a key, in any text file, is refused unless a rule row covers
#   it; in a test file a key is data except on a comment line and in four citation shapes
#   an added whole-line comment in a code file (the extensions are is_code() in
#   ticket-refs.awk) that is a review-fix note, a bot-review round, "round <n>" or a
#   judge qid (j + 4 digits + letter) is refused; docs and YAML are not judged for these
# Binary files (index blob `-text`) are skipped; the diff keeps --text so a .gitattributes
# `-diff` entry cannot hide an added text line. history-ok and ticket-ok markers do not exist.
# ponytail: test citations are refused in four shapes (G1-G4) only, so a key in another
# row-name shape passes as data; upgrade path: the follow-up ticket for a test row-name
# helper that rejects keys.
# ponytail: a block comment or docstring whose opener lies outside the hunk is not seen, so
# a diff that only extends one counts 0; upgrade path: the follow-up ticket that reads
# comment state from the tip blob over each hunk's line range.
#
# Usage:
#   check-history-comments.sh --staged                       # git diff --cached (pre-commit)
#   check-history-comments.sh --range <base> [--tip <ref>]   # git diff <base> <tip>, tip defaults to HEAD (CI)
#   check-history-comments.sh --diff <file>                  # a unified diff on disk (tests)
#   add --count-comments to print one integer, the added comment lines in code files
# Exit: 0 clean · 1 findings (path:line: <reason>: <text>) · 2 cannot evaluate (fail-closed):
# the classifier or the rule list is missing or unreadable, or git/awk failed

set -uo pipefail

usage() { echo "usage: check-history-comments.sh --staged | --range <base> [--tip <ref>] | --diff <file> [--count-comments]" >&2; exit 2; }
[ $# -ge 1 ] || usage

here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
classifier="$here/ticket-refs.awk"
rules="$here/ticket-ref-allow.tsv"

mode="" arg="" tip="HEAD" count=0
while [ $# -gt 0 ]; do
    case "$1" in
        --staged) [ -z "$mode" ] || usage; mode="staged"; shift ;;
        --range)  [ $# -ge 2 ] && [ -z "$mode" ] || usage; mode="range"; arg="$2"; shift 2 ;;
        --diff)   [ $# -ge 2 ] && [ -z "$mode" ] && [ -f "$2" ] || usage; mode="diff"; arg="$2"; shift 2 ;;
        --tip)    [ $# -ge 2 ] || usage; tip="$2"; shift 2 ;;
        --count-comments) count=1; shift ;;
        *)        usage ;;
    esac
done
[ -n "$mode" ] || usage
if [ "$tip" != "HEAD" ] && [ "$mode" != "range" ]; then usage; fi

for f in "$classifier" "$rules"; do
    [ -r "$f" ] || { echo "check-history-comments: cannot read $f, cannot evaluate" >&2; exit 2; }
done

DIFF="$(mktemp "${TMPDIR:-/tmp}/check-history-comments.XXXXXX")" || { echo "check-history-comments: mktemp failed" >&2; exit 2; }
BIN="$DIFF.bin"
trap 'rm -f "$DIFF" "$DIFF.out" "$BIN"' EXIT
: > "$BIN"
case "$mode" in
    staged) base=HEAD
            # during a merge, only lines our side adds relative to the merged-in parent are new
            git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 && base=MERGE_HEAD
            git diff --cached "$base" -U0 --text --no-color --no-ext-diff --find-renames --diff-filter=ACMRT > "$DIFF" || { echo "check-history-comments: git diff failed" >&2; exit 2; } ;;
    range)  git diff -U0 --text --no-color --no-ext-diff --find-renames --diff-filter=ACMRT "$arg" "$tip" > "$DIFF" || { echo "check-history-comments: git diff failed" >&2; exit 2; } ;;
    diff)   cp "$arg" "$DIFF" ;;
esac

# Binary by content, not by attribute: the index blob git reports as -text.
if [ "$mode" != "diff" ]; then
    git -c core.quotePath=false ls-files --eol 2>/dev/null | awk -F'\t' 'index($1, "i/-text") == 1 { print $2 }' > "$BIN" \
        || { echo "check-history-comments: git ls-files failed" >&2; exit 2; }
fi

if [ "$count" -eq 1 ]; then
    LC_ALL=C awk -f "$classifier" -v allow="$rules" -v mode=count -v binlist="$BIN" "$DIFF" > "$DIFF.out"
    rc=$?
    if [ "$rc" -ne 0 ]; then echo "check-history-comments: awk failed (rc=$rc)" >&2; exit 2; fi
    cat "$DIFF.out"
    exit 0
fi

LC_ALL=C awk -f "$classifier" -v allow="$rules" -v mode=diff -v binlist="$BIN" "$DIFF" > "$DIFF.out"
rc=$?
if [ "$rc" -eq 1 ]; then
    cat "$DIFF.out"
    echo "check-history-comments: a ticket key in added text, or a review round, CR fix or judge qid in a code comment, belongs in git and Jira." >&2
    echo "  Write the reason in words; the key belongs in the commit message and PR title. A key a program reads needs a row in scripts/lint/ticket-ref-allow.tsv." >&2
    echo "  Policy: docs/internals/ponytail-convention.md (Code comments)." >&2
elif [ "$rc" -ne 0 ]; then
    echo "check-history-comments: awk failed (rc=$rc)" >&2
    rc=2
fi
exit "$rc"
