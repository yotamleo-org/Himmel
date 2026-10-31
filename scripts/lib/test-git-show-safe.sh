#!/usr/bin/env bash
# Unit test for scripts/lib/git-show-safe.sh. Exit 0 if all pass.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/git-show-safe.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/git-show-safe.sh"

_fail=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s: %s\n' "$1" "$2"; _fail=$((_fail+1)); }

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/git-show-safe.XXXXXX") || { echo "cannot create temporary directory" >&2; exit 1; }
# shellcheck disable=SC2329,SC2317  # invoked via the EXIT trap
cleanup() { rm -rf "$TMP_ROOT" 2>/dev/null || true; }
trap cleanup EXIT

REPO="$TMP_ROOT/repo"
git init -q "$REPO"
git -C "$REPO" config user.email t@t.t
git -C "$REPO" config user.name t
mkdir -p "$REPO/scripts/sub"
printf 'hello world\n' > "$REPO/scripts/sub/file.txt"
( cd "$REPO" && git add -A && git commit -q -m "seed" )
SHA=$(git -C "$REPO" rev-parse HEAD)

echo "TEST: git_show_safe returns exact blob content on a real ref:path"
got=$(cd "$REPO" && git_show_safe "$SHA" "scripts/sub/file.txt")
rc=$?
if [ "$rc" -eq 0 ] && [ "$got" = "hello world" ]; then
    pass "existing ref:path"
else
    fail "existing ref:path" "rc=$rc got='$got'"
fi

echo "TEST: git_show_safe fails loud (nonzero rc, non-empty stderr, empty stdout) on a missing path"
out=$(cd "$REPO" && git_show_safe "$SHA" "scripts/sub/does-not-exist.txt" 2>"$TMP_ROOT/err")
rc=$?
errtxt=$(cat "$TMP_ROOT/err")
if [ "$rc" -ne 0 ] && [ -z "$out" ] && [ -n "$errtxt" ]; then
    pass "missing path: rc=$rc, stdout empty, stderr non-empty"
else
    fail "missing path" "rc=$rc out='$out' err='$errtxt'"
fi

echo "TEST: git_show_safe's rc matches the underlying git show rc (never silently swallowed)"
( cd "$REPO" && git show "$SHA:scripts/sub/does-not-exist.txt" >/dev/null 2>&1 )
plain_rc=$?
if [ "$rc" -eq "$plain_rc" ]; then
    pass "rc propagation ($rc)"
else
    fail "rc propagation" "git_show_safe rc=$rc plain git rc=$plain_rc"
fi

if [ "$_fail" -eq 0 ]; then echo "OK"; exit 0; else echo "FAIL: $_fail"; exit 1; fi
