#!/usr/bin/env bash
# scripts/lib/commit-class.sh — conventional-commit subject classifier.
# Factored from scripts/gen-changelog.sh so the changelog generator and the
# doc-freshness detector classify commit subjects identically.
# cc_classify <subject> → echoes one of: feat | fix | changed | other
cc_classify() {
    case "$1" in
        feat:*|feat\(*) printf 'feat' ;;
        fix:*|fix\(*)   printf 'fix' ;;
        chore:*|chore\(*|refactor:*|refactor\(*|docs:*|docs\(*|test:*|test\(*)
                        printf 'changed' ;;
        *)              printf 'other' ;;
    esac
}

# Ticket-key pattern, case-insensitive (callers pass `grep -i`): the HIMMEL or
# LUNA prefix, a dash, a number, and optional slash-joined numbers. One
# definition for the changelog strip and the release notes' LEAK_RE.
# shellcheck disable=SC2034  # read by the scripts that source this file
CC_KEY_RE='(HIMMEL|LUNA)-[0-9]+(/[0-9]+)*'
# The same pattern spelled with bracket classes for `sed -E`, which has no
# portable case-insensitive flag (BSD sed).
CC_KEY_RE_SED='([Hh][Ii][Mm][Mm][Ee][Ll]|[Ll][Uu][Nn][Aa])-[0-9]+(/[0-9]+)*'

# cc_strip_keys — a filter: reads subjects on stdin, writes each with no ticket
# key and no trailing `(#n)`: bracket tags and scope or parenthesis groups
# holding only keys go first, then bare keys, then trailing PR numbers (one
# or several). Mid-text `#n` stays.
# ponytail: a key inside prose strands its words, as in "(deferred from )",
# upgrade path a by-hand reword.
cc_strip_keys() {
    local k="$CC_KEY_RE_SED"
    sed -E \
        -e "s~ *\\[ *$k( *[,;] *$k)* *\\]~~g" \
        -e "s~ *\\( *$k( *[,;] *$k)* *\\)~~g" \
        -e "s~ *$k~~g" \
        -e 's/( *\(#[0-9]+\))+ *$//' \
        -e 's/  +/ /g' \
        -e 's/ +$//'
}
