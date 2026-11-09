#!/usr/bin/env bash
# scripts/one-shot/no-markers.sh - no tracked file carries a ponytail marker.
# A one-shot removal check, run by hand: never a suite, a hook or a CI step.
#
# Usage:
#   no-markers.sh                                  scan this checkout
#   no-markers.sh --removed <base> --draft <tsv>   count the markers a branch removed
#
# The scan fails naming each tracked file that holds the marker token (any
# case), skipping files under a whole-file row of scripts/lint/ticket-ref-allow.tsv
# (ticket-refs.awk mode exempt) and the paths listed in
# scripts/ledger/held-paths.txt (one path per line, `# PR <n>` beside it).
# --removed counts the token on removed lines minus added lines of
# `git diff -U0 <base>...HEAD`, skipping the same whole-file rows, and fails
# unless that equals the draft's row count.
# Exit: 0 clean; 1 a marker found or a count differs; 2 usage or cannot evaluate.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
AWKF="$HERE/../lint/ticket-refs.awk"
LIST="$HERE/../lint/ticket-ref-allow.tsv"
TOK="pony""tail:"

die() { echo "no-markers: $*" >&2; exit 2; }

exempt() { # paths on stdin -> those under a whole-file allow row
    LC_ALL=C awk -f "$AWKF" -v allow="$LIST" -v mode=exempt
}

scan_repo() {
    local top files ex held bad=0 f
    top="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not a git checkout"
    files="$(git -C "$top" grep -Iil -F -e "$TOK")"
    case "$?" in
        0) ;;
        1) echo "no-markers: PASS, no tracked file carries a marker"; return 0 ;;
        *) die "git grep failed, cannot evaluate" ;;
    esac
    ex="$(printf '%s\n' "$files" | exempt)" || die "ticket-refs.awk exempt mode failed"
    held=""
    [ -f "$top/scripts/ledger/held-paths.txt" ] && held="$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$top/scripts/ledger/held-paths.txt")"
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        printf '%s\n' "$ex" | grep -qxF -- "$f" && continue
        [ -n "$held" ] && printf '%s\n' "$held" | grep -qxF -- "$f" && continue
        echo "MARKER $f"; bad=1
    done <<EOF
$files
EOF
    if [ "$bad" -eq 1 ]; then
        echo "no-markers: FAIL, record each ceiling with scripts/ledger/ceiling-add.sh add and delete the marker" >&2
        return 1
    fi
    echo "no-markers: PASS, only whole-file rows and held paths carry a marker"
}

count_removed() { # count_removed <base> <draft>
    local base="$1" draft="$2" diff ex counts rem add rows net
    [ -r "$draft" ] || die "cannot read draft $draft"
    diff="$(git diff -U0 --text --no-color --no-ext-diff --no-renames "$base...HEAD")" || die "git diff $base...HEAD failed"
    ex="$(printf '%s\n' "$diff" | sed -n 's|^diff --git a/.* b/||p' | exempt)" || die "ticket-refs.awk exempt mode failed"
    counts="$(printf '%s\n' "$diff" | LC_ALL=C awk -v ex="$ex" '
        BEGIN { n = split(ex, e, "\n"); for (i = 1; i <= n; i++) if (e[i] != "") skip[e[i]] = 1 }
        /^diff --git / { p = $0; sub(/^diff --git a\/.* b\//, "", p); next }
        /^(\+\+\+|---) / { next }
        /^[-+]/ {
            if (p in skip) next
            s = tolower(substr($0, 2)); k = 0
            while ((i = index(s, "pony" "tail:")) > 0) { k++; s = substr(s, i + 1) }
            if (substr($0, 1, 1) == "-") r += k; else a += k
        }
        END { printf "%d %d\n", r, a }')"
    rem="${counts% *}"; add="${counts#* }"
    rows="$(awk -F '\t' 'NR == 1 && $1 == "file" { next } $0 != "" { n++ } END { print n + 0 }' "$draft")"
    net=$((rem - add))
    if [ "$net" -eq "$rows" ]; then
        echo "removed: $net markers (removed $rem, added $add), draft rows $rows: PASS"
        return 0
    fi
    echo "removed: $net markers (removed $rem, added $add), draft rows $rows: FAIL"
    return 1
}

for f in "$AWKF" "$LIST"; do [ -r "$f" ] || die "cannot read $f"; done
case "${1:-}" in
    "") scan_repo ;;
    --removed)
        [ "$#" -eq 4 ] && [ "$3" = --draft ] || die "usage: --removed <base> --draft <draft.tsv>"
        count_removed "$2" "$4" ;;
    *) die "usage: no-markers.sh [--removed <base> --draft <draft.tsv>]" ;;
esac
