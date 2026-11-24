#!/usr/bin/env bash
# Platform guard (posix-bash): POSIX bash 3.2+.
#
# test-check-new-ticket-ids.sh — tests for scripts/lint/check-new-ticket-ids.sh.
#
# Each case builds a throwaway git repo that carries the gate, then stages or commits one
# change. The tracker key is spelled in two pieces so this file never carries one itself.
#
# Exit: 0 all passed, 1 any failed. bash 3.2-safe.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
GATE="$SELF_DIR/check-new-ticket-ids.sh"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/new-ticket-id-gate.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT

if [ ! -f "$GATE" ]; then
    echo "FAIL: $GATE does not exist yet (RED)"
    exit 1
fi

KEY="HIM""MEL-123"
KEY2="LU""NA-45"
KEY3="SAL""US-6"
N=0
mkrepo() {
    N=$((N + 1)); R="$T/r$N"
    mkdir -p "$R/scripts/lint" "$R/docs" "$R/scripts/tests" "$R/fixtures"
    cp "$GATE" "$R/scripts/lint/"
    git -C "$R" init -q -b main
    git -C "$R" config user.email t@example.invalid
    git -C "$R" config user.name t
    printf 'first line\nan old note about %s stays\nlast line\n' "$KEY" > "$R/docs/a.md"
    printf 'plain\n' > "$R/scripts/tests/test-x.sh"
    git -C "$R" add -A
    git -C "$R" commit -q -m base
}
gate() { OUT="$(cd "$R" && bash scripts/lint/check-new-ticket-ids.sh "$@" 2>&1)"; RC=$?; }
has() { case "$OUT" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
stage() { git -C "$R" add -A; gate --staged; }
want() {
    if [ "$RC" -eq "$2" ]; then pass "$1"; else fail "$1 -> rc=$RC, wanted $2: $OUT"; fi
}

echo "== 1. an added key in a doc is refused with path:line =="
mkrepo
printf 'new line about %s here\n' "$KEY" >> "$R/docs/a.md"
stage
if [ "$RC" -eq 1 ] && has "docs/a.md:4: ticket id: new line about $KEY here"; then pass "doc key refused with path:line"; else fail "doc key -> rc=$RC: $OUT"; fi

echo "== 2. no allow list: a test file, a fixture, a changelog and a data file all refuse =="
mkrepo
printf 'echo %s\n' "$KEY" >> "$R/scripts/tests/test-x.sh"; stage; want "test file refused" 1
mkrepo
printf 'row %s\n' "$KEY" > "$R/fixtures/data.txt"; stage; want "fixture refused" 1
mkrepo
printf 'entry %s\n' "$KEY" > "$R/CHANGELOG.md"; stage; want "changelog refused" 1
mkrepo
printf '{"ticket": "%s"}\n' "$KEY" > "$R/docs/x.json"; stage; want "json refused" 1

echo "== 3. all three prefixes are keys =="
mkrepo
printf 'a %s\n' "$KEY2" >> "$R/docs/a.md"; stage; want "second prefix refused" 1
mkrepo
printf 'a %s\n' "$KEY3" >> "$R/docs/a.md"; stage; want "third prefix refused" 1

echo "== 4. only added lines are judged =="
mkrepo
printf 'another plain line\n' >> "$R/docs/a.md"; stage; want "a line next to an old key passes" 0
mkrepo
printf 'first line\nlast line\n' > "$R/docs/a.md"; stage; want "removing a key passes" 0
mkrepo
git -C "$R" mv docs/a.md docs/b.md; stage; want "renaming a file that holds an old key passes" 0
mkrepo
rm "$R/docs/a.md"; stage; want "deleting a file passes" 0

echo "== 5. strings that are not keys pass =="
mkrepo
printf 'XHIM%sMEL-123 and HIM%sMEL- and him%smel-123 and %s\n' "" "" "" "ABC-123" >> "$R/docs/a.md"
stage; want "near misses pass" 0

echo "== 6. a key in an added file name is refused =="
mkrepo
printf 'plain\n' > "$R/docs/pr-$KEY.json"; stage
if [ "$RC" -eq 1 ] && has "docs/pr-$KEY.json: ticket id in the file name"; then pass "file name key refused"; else fail "file name -> rc=$RC: $OUT"; fi
mkrepo
git -C "$R" mv docs/a.md "docs/a-$KEY.md"; stage; want "renaming to a key name refused" 1

echo "== 7. a line that starts like a diff header is still judged as content =="
mkrepo
printf '++ %s\n' "$KEY" >> "$R/docs/a.md"; stage
if [ "$RC" -eq 1 ] && has "docs/a.md:4:"; then pass "line starting with plus signs judged"; else fail "plus-led line -> rc=$RC: $OUT"; fi

echo "== 8. every finding is listed =="
mkrepo
printf 'x %s\n' "$KEY" >> "$R/docs/a.md"
printf 'y %s\n' "$KEY2" > "$R/docs/b.md"
stage
if [ "$RC" -eq 1 ] && has "docs/a.md:4:" && has "docs/b.md:1:"; then pass "two files listed"; else fail "two files -> rc=$RC: $OUT"; fi

echo "== 9. a binary file is skipped =="
mkrepo
printf '\000\001 %s \000\n' "$KEY" > "$R/docs/blob.bin"; stage; want "binary skipped" 0

echo "== 10. --range judges the commits between base and tip =="
mkrepo
base="$(git -C "$R" rev-parse HEAD)"
printf 'z %s\n' "$KEY" >> "$R/docs/a.md"
git -C "$R" commit -q -am "add key"
gate --range "$base"
if [ "$RC" -eq 1 ] && has "docs/a.md:4:"; then pass "range refused"; else fail "range -> rc=$RC: $OUT"; fi
printf 'clean\n' >> "$R/docs/a.md"
git -C "$R" commit -q -am "clean"
tip_clean="$(git -C "$R" rev-parse HEAD)"
gate --range "$tip_clean" --tip HEAD; want "empty range passes" 0
gate --range "$base" --tip "$base"; want "base to itself passes" 0

echo "== 11. cannot evaluate is exit 2, never a pass =="
mkrepo
gate --range no-such-ref; want "unknown base" 2
gate; want "no mode" 2
gate --staged --range x; want "two modes" 2
gate --tip main --staged; want "tip with staged" 2
OUT="$(cd "$T" && bash "$R/scripts/lint/check-new-ticket-ids.sh" --staged 2>&1)"; RC=$?; want "outside a work tree" 2

echo "== 12. a clean change passes =="
mkrepo
printf 'nothing to see\n' >> "$R/docs/a.md"; stage; want "clean change" 0

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
