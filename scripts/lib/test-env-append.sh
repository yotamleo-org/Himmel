#!/usr/bin/env bash
# Tests for scripts/lib/env-append.sh and the two .env writers that use it
# (set-env-var.sh, set-handover-dir.sh): a key appended to a .env whose last
# line has no trailing newline must land on its own line.
set -uo pipefail

LIB="$(cd "$(dirname "$0")" && pwd)"
SET_ENV="$LIB/set-env-var.sh"
SET_HDIR="$LIB/../handover/set-handover-dir.sh"

FAILED=0
assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then echo "PASS $label"
    else echo "FAIL $label — expected '$expected', got '$actual'"; FAILED=$((FAILED + 1)); fi
}

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

# T1: set-env-var.sh onto a file with no trailing newline.
E="$TMP/a.env"
printf 'A=1' > "$E"
bash "$SET_ENV" B 2 --env-file "$E" >/dev/null 2>&1
assert_eq "T1 set-env-var separate lines" "A=1|B=2" "$(paste -sd'|' "$E")"

# T2: set-handover-dir.sh onto a file with no trailing newline.
mkdir -p "$TMP/h"
H="$(cd "$TMP/h" && pwd)"
E="$TMP/b.env"
printf 'A=1' > "$E"
bash "$SET_HDIR" "$TMP/h" --env-file "$E" >/dev/null 2>&1
assert_eq "T2 set-handover-dir separate lines" "A=1|HANDOVER_DIR=$H" "$(paste -sd'|' "$E")"

# T3: a file that already ends in a newline gains no blank line.
E="$TMP/c.env"
printf 'A=1\n' > "$E"
bash "$SET_ENV" B 2 --env-file "$E" >/dev/null 2>&1
assert_eq "T3 no blank line" "A=1|B=2" "$(paste -sd'|' "$E")"

# T4: an empty file gains no leading blank line.
E="$TMP/d.env"
: > "$E"
bash "$SET_ENV" B 2 --env-file "$E" >/dev/null 2>&1
assert_eq "T4 empty file" "B=2" "$(paste -sd'|' "$E")"

echo
if [ "$FAILED" -eq 0 ]; then echo "All env-append tests passed."
else echo "$FAILED env-append test(s) failed."; exit 1; fi
