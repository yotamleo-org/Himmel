#!/usr/bin/env bash
# Tests for scripts/lib/canon-path.sh.
# Usage: bash scripts/lib/test-canon-path.sh
# Hermetic: a symlinked directory stands in for macOS /var -> /private/var.
# Platform guard: POSIX bash 3.2+.
set -uo pipefail

LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=canon-path.sh
# shellcheck disable=SC1091
. "$LIB_DIR/canon-path.sh"

FAILED=0
assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "PASS $label"
    else
        echo "FAIL $label — expected '$expected', got '$actual'"
        FAILED=$((FAILED + 1))
    fi
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/canon-path.XXXXXX") || { echo "FAIL could not create temp dir"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
# Physical root first: the assertions compare against it.
REAL=$(cd "$TMP" && pwd -P)
mkdir -p "$REAL/real/sub" "$REAL/real/with space"
ln -s "$REAL/real" "$REAL/link"

# Precondition: the raw spelling really differs from the physical one, or the
# cases below could pass on an identity function.
RAW_SPELLING="$REAL/link/sub"; PHYS_SPELLING="$REAL/real/sub"
assert_eq "precondition: the symlink spelling is not the physical path" "differs" \
    "$([ "$RAW_SPELLING" != "$PHYS_SPELLING" ] && echo differs || echo same)"

# T1: a symlinked prefix resolves to the physical path.
assert_eq "T1 symlinked prefix -> physical" "$REAL/real/sub" "$(canon_path "$REAL/link/sub")"

# T2: a doubled slash (macOS TMPDIR ends in "/") normalises.
assert_eq "T2 doubled slash -> single" "$REAL/real/sub" "$(canon_path "$REAL/link//sub")"

# T3: a space in the path survives.
assert_eq "T3 space in path" "$REAL/real/with space" "$(canon_path "$REAL/link/with space")"

# T4: a missing directory and an empty argument both fail and print nothing.
out=$(canon_path "$REAL/nope"); rc=$?
assert_eq "T4a missing dir -> rc=1, no output" "1|" "$rc|$out"
out=$(canon_path ""); rc=$?
assert_eq "T4b empty arg -> rc=1, no output" "1|" "$rc|$out"

# T8: partial keeps a not-yet-created tail, resolving only the existing head.
assert_eq "T8 partial: existing head canonicalised, missing tail kept" \
    "$REAL/real/sub/cr-pending/t7-wt" "$(canon_path_partial "$REAL/link/sub/cr-pending/t7-wt")"
assert_eq "T8b partial on an existing path == native" "$REAL/real/sub" "$(canon_path_partial "$REAL/link/sub")"

# T9: a newline inside a path component round-trips (the main-ref-transaction case).
NL="$REAL/real"/$'weird\nname'
mkdir -p "$NL"
[ "$(canon_path "$REAL/link"/$'weird\nname')" = "$NL" ] && got=ok || got=mangled
assert_eq "T9 newline in a path component survives" "ok" "$got"

# T10: a relative path with no existing ancestor fails instead of looping.
out=$(canon_path_partial "no-such-relative/dir"); rc=$?
assert_eq "T10 partial with no existing ancestor -> rc=1" "1|" "$rc|$out"

if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
fi
echo "$FAILED FAILED"
exit 1
