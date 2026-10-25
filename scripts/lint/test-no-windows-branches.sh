#!/usr/bin/env bash
# test-no-windows-branches.sh — ratchet on Windows scheduler code in the live tree.
#
# Windows support is dropped. Every tracked file outside archive/, docs/ and
# *.md / *.html that names schtasks must be listed in windows-branch-baseline.txt.
# The baseline only shrinks: a file that is not listed fails, and so does a listed
# file that no longer names schtasks (the stale row must go with the code).
#   1. a planted file that is not in the baseline   -> scan exits 1, path named
#   2. a baseline row whose file no longer matches  -> scan exits 1, row named
#   3. hits under archive/, docs/, *.md and *.html  -> scan exits 0
#   4. the real tree against the committed baseline -> scan exits 0
#
# Exit: 0 all passed, 1 any failed. bash 3.2-safe.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO="$(cd "$SELF_DIR/../.." && pwd)"
BASELINE="$SELF_DIR/windows-branch-baseline.txt"
SELF_REL="scripts/lint/test-no-windows-branches.sh"
BASE_REL="scripts/lint/windows-branch-baseline.txt"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

# scan <root> <baseline>: prints one line per offence, exits 1 on any.
scan() {
    local root="$1" base="$2" hits listed rc=0 f
    [ -f "$base" ] || { echo "missing baseline: $base"; return 2; }
    hits="$(git -C "$root" grep -il schtasks -- . ':!archive' ':!docs' ':!*.md' ':!*.html' ":!$SELF_REL" ":!$BASE_REL" | LC_ALL=C sort)"
    listed="$(grep -v '^#' "$base" | grep -v '^$' | LC_ALL=C sort)"
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        grep -qxF -- "$f" <<< "$listed" && continue
        echo "new Windows scheduler code (not in the baseline): $f"; rc=1
    done <<EOF
$hits
EOF
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        grep -qxF -- "$f" <<< "$hits" && continue
        echo "stale baseline row (file no longer names schtasks): $f"; rc=1
    done <<EOF
$listed
EOF
    return "$rc"
}

T="$(mktemp -d "${TMPDIR:-/tmp}/no-windows-branches.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT

mkrepo() {
    rm -rf "$T/r"; mkdir -p "$T/r/scripts" "$T/r/archive" "$T/r/docs"
    git -C "$T/r" init -q
    printf 'schtasks /query\n' > "$T/r/scripts/kept.sh"
    printf 'scripts/kept.sh\n' > "$T/base.txt"
}
# git grep reads only tracked files, so an untracked fixture would pass vacuously.
commit() {
    if ! { git -C "$T/r" add -A && git -C "$T/r" -c user.name=t -c user.email=t@t commit -qm fixture; }; then
        echo "FAIL: fixture commit failed" >&2; exit 1
    fi
}

echo "case 1: planted file not in the baseline"
mkrepo
printf 'if is_windows; then schtasks /create /tn X; fi\n' > "$T/r/scripts/planted.sh"
commit
out="$(scan "$T/r" "$T/base.txt")"; rc=$?
if [ "$rc" -eq 1 ] && grep -qF 'scripts/planted.sh' <<< "$out"; then pass "planted file fails, named"
else fail "planted file should exit 1 naming it (rc=$rc, out=$out)"; fi

echo "case 2: stale baseline row"
mkrepo
commit
printf 'scripts/gone.sh\n' >> "$T/base.txt"
out="$(scan "$T/r" "$T/base.txt")"; rc=$?
if [ "$rc" -eq 1 ] && grep -qF 'stale baseline row (file no longer names schtasks): scripts/gone.sh' <<< "$out"; then pass "stale row fails, named"
else fail "stale row should exit 1 naming it (rc=$rc, out=$out)"; fi

echo "case 3: archive/, docs/, *.md and *.html are out of scope"
mkrepo
printf 'schtasks /create\n' > "$T/r/archive/old.sh"
printf 'schtasks /create\n' > "$T/r/docs/page.sh"
printf 'schtasks /create\n' > "$T/r/scripts/notes.md"
printf 'schtasks /create\n' > "$T/r/scripts/page.html"
commit
out="$(scan "$T/r" "$T/base.txt")"; rc=$?
if [ "$rc" -eq 0 ]; then pass "excluded paths pass"
else fail "excluded paths should exit 0 (rc=$rc, out=$out)"; fi

echo "case 4: the real tree against the committed baseline"
out="$(scan "$REPO" "$BASELINE")"; rc=$?
if [ "$rc" -eq 0 ]; then pass "real tree matches the baseline"
else fail "real tree vs baseline (rc=$rc):
$out"; fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
