#!/usr/bin/env bash
# Tests for scripts/lib/gate-repo-resolver.sh.
# Usage: bash scripts/lib/test-gate-repo-resolver.sh
# Hermetic: a primary repo with a linked worktree carrying a copy of the lib, a decoy
# repo and a directory outside any repo stand in for a chief's checkout and cwd.
# Platform guard: POSIX bash 3.2+.
# shellcheck disable=SC2016  # the bash -c bodies expand their own "$1", not this shell's
set -uo pipefail

LIB_DIR="$(cd "$(dirname "$0")" && pwd)"

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

TMP=$(mktemp -d "${TMPDIR:-/tmp}/gate-repo-resolver.XXXXXX") || { echo "FAIL could not create temp dir"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)

# shellcheck source=git-clean.sh
# shellcheck disable=SC1091
. "$LIB_DIR/git-clean.sh" || { echo "FAIL could not load git-clean.sh"; exit 1; }
PRIM="$TMP/prim"; LINKED="$TMP/linked"; DECOY="$TMP/decoy"; NOWHERE="$TMP/nowhere"; LOOSE="$TMP/loose"
mkdir -p "$NOWHERE" "$LOOSE/scripts/lib"
for r in "$PRIM" "$DECOY"; do
    git_clean init -q "$r"
    git_clean -C "$r" -c user.email=t@example.com -c user.name=tester commit -q --allow-empty -m "chore: init"
done
git_clean -C "$PRIM" worktree add -q --detach "$LINKED"
mkdir -p "$LINKED/scripts/lib"
for d in "$LINKED/scripts/lib" "$LOOSE/scripts/lib"; do
    cp "$LIB_DIR/gate-repo-resolver.sh" "$LIB_DIR/git-clean.sh" "$d/" 2>/dev/null || true
done
: > "$TMP/a-file"

resolve() {
    local cwd="$1" lib="$2" out err rc=0
    shift 2
    out=$(cd "$cwd" && env "$@" bash -c '. "$1" || exit 9; gate_repo_dir t "; T1" " - T2"' _ "$lib" 2>"$TMP/err") || rc=$?
    err=$(cat "$TMP/err")
    printf '%s|%s|%s' "$rc" "$out" "$err"
}
LIB="$LINKED/scripts/lib/gate-repo-resolver.sh"

assert_eq "G1 unset HIMMEL_REPO from outside any repo -> the primary checkout of the lib's tree" \
    "0|$PRIM|" "$(resolve "$NOWHERE" "$LIB" -u HIMMEL_REPO)"
assert_eq "G2 unset HIMMEL_REPO from a decoy repo -> the primary checkout, never the decoy" \
    "0|$PRIM|" "$(resolve "$DECOY" "$LIB" -u HIMMEL_REPO)"
assert_eq "G3 an inherited GIT_DIR naming the decoy does not pick the checkout" \
    "0|$PRIM|" "$(resolve "$DECOY" "$LIB" -u HIMMEL_REPO GIT_DIR="$DECOY/.git" GIT_WORK_TREE="$DECOY")"
assert_eq "G4 an empty HIMMEL_REPO reads as unset" \
    "0|$PRIM|" "$(resolve "$DECOY" "$LIB" HIMMEL_REPO=)"
assert_eq "G5 an absolute HIMMEL_REPO is the gated checkout as given, from any cwd" \
    "0|$DECOY|" "$(resolve "$NOWHERE" "$LIB" HIMMEL_REPO="$DECOY")"
assert_eq "G6 a relative HIMMEL_REPO is refused with rc 1, one line ending in the first tail, nothing printed" \
    "1||t: HIMMEL_REPO (decoy) is not an absolute path - refusing to let it pick the gated checkout; T1" \
    "$(resolve "$TMP" "$LIB" HIMMEL_REPO=decoy)"
assert_eq "G7 an absolute HIMMEL_REPO that is not a directory is refused with the second tail" \
    "1||t: the gated checkout HIMMEL_REPO ($TMP/a-file) is not a directory - T2" \
    "$(resolve "$NOWHERE" "$LIB" HIMMEL_REPO="$TMP/a-file")"
assert_eq "G8 a missing HIMMEL_REPO directory is refused the same way" \
    "1||t: the gated checkout HIMMEL_REPO ($TMP/gone) is not a directory - T2" \
    "$(resolve "$NOWHERE" "$LIB" HIMMEL_REPO="$TMP/gone")"
assert_eq "G9 a lib tree outside git falls back to that tree's root, not the cwd" \
    "0|$LOOSE|" "$(resolve "$DECOY" "$LOOSE/scripts/lib/gate-repo-resolver.sh" -u HIMMEL_REPO)"
out=$(cd "$LINKED" && env -u HIMMEL_REPO bash -c '. scripts/lib/gate-repo-resolver.sh || exit 9; cd "$1" && gate_repo_dir t "" ""' _ "$DECOY" 2>&1); rc=$?
assert_eq "G10 a lib sourced by a relative path still resolves its own tree after a cd" "0|$PRIM" "$rc|$out"
rm -f "$LOOSE/scripts/lib/git-clean.sh"
out=$(cd "$NOWHERE" && bash -c '. "$1" 2>/dev/null || exit 9; gate_repo_dir t "" ""' _ "$LOOSE/scripts/lib/gate-repo-resolver.sh"); rc=$?
assert_eq "G11 without git-clean.sh beside it the lib fails to load (exit 9), never resolves unscrubbed" "9|" "$rc|$out"

if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
fi
echo "$FAILED FAILED"
exit 1
