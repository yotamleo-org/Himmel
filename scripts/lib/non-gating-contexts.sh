#!/usr/bin/env bash
# non-gating-contexts.sh — the exact-match list of status contexts the merge
# gates skip (ready-check rows 1 and 2, check-ci.sh), read from
# non-gating-contexts.txt beside this file.
#
# Sourced, never executed. bash 3.2-safe.
#
#   ngc_json                  the listed names as a JSON array ("[]" when the
#                             file is unreadable: nothing is non-gating then)
#   ngc_drop_rows             stdin "<bucket>\t<name>[\t...]" rows, listed
#                             names removed (stdin unchanged when the list is
#                             unreadable)
#
# A name matches only when the whole context equals a line of the file.

_NGC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_NGC_FILE="$_NGC_DIR/non-gating-contexts.txt"

ngc_json() {
    if [ -r "$_NGC_FILE" ] && jq -Rn '[inputs | select(length > 0 and (startswith("#") | not))]' "$_NGC_FILE" 2>/dev/null; then
        return 0
    fi
    echo '[]'
}

ngc_drop_rows() {
    if [ ! -r "$_NGC_FILE" ]; then cat; return; fi
    awk -F'\t' '
        FILENAME == ARGV[1] { if ($0 != "" && substr($0, 1, 1) != "#") skip[$0] = 1; next }
        !($2 in skip)
    ' "$_NGC_FILE" -
}
