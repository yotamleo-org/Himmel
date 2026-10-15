#!/usr/bin/env bash
# Suite for scripts/hooks/install-single-writer-floor.sh.
#
# Fixture: a bare file:// remote plus a `.single-writer` clone (the shape of
# luna and the handover state repos). Proves, with the refusal output
# captured:
#   1. BEFORE install a force push to main and a delete of main both succeed
#      (the defect: no floor at all).
#   2. AFTER install both are refused with the floor's message; a plain
#      fast-forward push to main and a feature-branch push still go through
#      (the repo commits straight to main by design).
#   3. The installer is idempotent, refuses a non-.single-writer repo, and
#      never overwrites a foreign pre-push hook without saying so.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$SCRIPT_DIR/install-single-writer-floor.sh"
# shellcheck source=../lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/fixture-tempdir.sh"

# A hook-invoking parent (pre-commit, pre-push) leaks GIT_DIR and friends.
# shellcheck source=../lib/git-clean.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/git-clean.sh"
git_env_scrub
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

PASS=0; FAIL=0; TMP_ROOT=""
# shellcheck disable=SC2329,SC2317
cleanup() {
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then rm -rf "$TMP_ROOT" 2>/dev/null || true; fi
}
trap cleanup EXIT
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; [ $# -ge 2 ] && printf '    %s\n' "$2"; FAIL=$((FAIL+1)); }
assert_rc() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want rc=$2 got rc=$3"; fi; }
# check NAME CMD... -- pass if CMD succeeds, fail otherwise (no A && B || C).
check() { local n="$1"; shift; if "$@"; then pass "$n"; else fail "$n"; fi; }
assert_nonzero() { if [ "$2" != "0" ]; then pass "$1"; else fail "$1" "want nonzero rc, got 0"; fi; }
assert_contains() {
    case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "missing: $2 -- in: $3" ;; esac
}

TMP_ROOT=$(fixture_mktemp_dir) || exit 1

# new_fixture NAME -- bare remote + .single-writer clone with 2 commits on main
# and a second clone ("other") used to create divergent history for force pushes.
new_fixture() {
    local n="$1"
    git init -q --bare -b main "$TMP_ROOT/$n.git"
    # A bare repo refuses to delete its checked-out branch by default; the
    # defect under test is the CLIENT floor, so let the server allow it.
    git -C "$TMP_ROOT/$n.git" config receive.denyDeleteCurrent ignore
    git clone -q "file://$TMP_ROOT/$n.git" "$TMP_ROOT/$n" 2>/dev/null
    git -C "$TMP_ROOT/$n" checkout -q -b main
    : > "$TMP_ROOT/$n/.single-writer"
    echo 1 > "$TMP_ROOT/$n/a.txt"
    git -C "$TMP_ROOT/$n" add a.txt
    git -C "$TMP_ROOT/$n" commit -q -m one
    echo 2 > "$TMP_ROOT/$n/a.txt"
    git -C "$TMP_ROOT/$n" commit -q -am two
    git -C "$TMP_ROOT/$n" push -q origin main 2>/dev/null
}

# diverge REPO -- rewrite main's tip locally so a push of it is non-fast-forward.
diverge() {
    git -C "$1" reset -q --hard HEAD~1
    echo diverged > "$1/b.txt"
    git -C "$1" add b.txt
    git -C "$1" commit -q -m diverged
}

# ---------------------------------------------------------------- RED rows
echo "== before install: no floor =="
new_fixture red
diverge "$TMP_ROOT/red"
out=$(git -C "$TMP_ROOT/red" push --force origin main 2>&1); rc=$?
assert_rc "RED: force push to main succeeds with no floor" 0 "$rc"
out=$(git -C "$TMP_ROOT/red" push origin :main 2>&1); rc=$?
assert_rc "RED: delete of main succeeds with no floor" 0 "$rc"

# ---------------------------------------------------------------- install
echo "== installer =="
new_fixture a
if [ ! -f "$INSTALLER" ]; then
    fail "installer exists" "$INSTALLER missing"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi
out=$(bash "$INSTALLER" "$TMP_ROOT/a" 2>&1); rc=$?
assert_rc "install into .single-writer repo exits 0" 0 "$rc"
hook="$TMP_ROOT/a/.git/hooks/pre-push"
check "pre-push hook installed and executable" test -x "$hook"
check "reference-transaction hook installed" test -x "$TMP_ROOT/a/.git/hooks/reference-transaction"

echo "== after install: floor refuses =="
before=$(git -C "$TMP_ROOT/a" ls-remote origin refs/heads/main)
diverge "$TMP_ROOT/a"
out=$(git -C "$TMP_ROOT/a" push --force origin main 2>&1); rc=$?
echo "    force-push output: $out" | head -5
assert_nonzero "force push to main is refused" "$rc"
assert_contains "force-push refusal names the cause" "Force-push to 'main' is not allowed" "$out"
out=$(git -C "$TMP_ROOT/a" push origin :main 2>&1); rc=$?
echo "    delete output: $out" | head -5
assert_nonzero "delete of main is refused" "$rc"
assert_contains "delete refusal names the cause" "Deleting 'main'" "$out"
after=$(git -C "$TMP_ROOT/a" ls-remote origin refs/heads/main)
check "remote main ref was readable before the pushes" test -n "$before"
check "remote main untouched by refused pushes" test "$before" = "$after"

echo "== after install: legitimate pushes still work =="
git -C "$TMP_ROOT/a" reset -q --hard "origin/main" 2>/dev/null || git -C "$TMP_ROOT/a" reset -q --hard HEAD
git -C "$TMP_ROOT/a" fetch -q origin 2>/dev/null
git -C "$TMP_ROOT/a" reset -q --hard origin/main
echo three > "$TMP_ROOT/a/c.txt"; git -C "$TMP_ROOT/a" add c.txt
git -C "$TMP_ROOT/a" commit -q -m three; rc=$?
assert_rc "fixture commit for the fast-forward push succeeds" 0 "$rc"
tip=$(git -C "$TMP_ROOT/a" rev-parse HEAD)
out=$(git -C "$TMP_ROOT/a" push origin main 2>&1); rc=$?
check "fast-forward push advanced remote main to the new commit" test "$(git -C "$TMP_ROOT/a" ls-remote origin refs/heads/main | cut -f1)" = "$tip"
assert_rc "fast-forward push to main still allowed (single-writer)" 0 "$rc"
git -C "$TMP_ROOT/a" branch feat/x
out=$(git -C "$TMP_ROOT/a" push origin feat/x 2>&1); rc=$?
assert_rc "feature-branch push still allowed" 0 "$rc"
out=$(git -C "$TMP_ROOT/a" push origin :feat/x 2>&1); rc=$?
assert_rc "delete of a non-main branch still allowed" 0 "$rc"

echo "== missing target fails closed =="
git -C "$TMP_ROOT/a" config --local himmel-single-writer-floor.target "$TMP_ROOT/gone.sh"
out=$(git -C "$TMP_ROOT/a" push origin feat/x 2>&1); rc=$?
assert_nonzero "push is refused when the floor target is missing" "$rc"
assert_contains "missing-target refusal says so" "REFUSING this push" "$out"
out=$(bash "$INSTALLER" "$TMP_ROOT/a" 2>&1); rc=$?
assert_rc "re-install repairs the recorded target" 0 "$rc"
out=$(git -C "$TMP_ROOT/a" push origin feat/x 2>&1); rc=$?
assert_rc "push works again after the repair" 0 "$rc"

echo "== idempotence =="
sum1=$(cksum < "$hook")
out=$(bash "$INSTALLER" "$TMP_ROOT/a" 2>&1); rc=$?
assert_rc "re-install exits 0" 0 "$rc"
sum2=$(cksum < "$hook")
check "re-install leaves hook bytes identical" test "$sum1" = "$sum2"

echo "== refusals =="
git init -q "$TMP_ROOT/plain"
out=$(bash "$INSTALLER" "$TMP_ROOT/plain" 2>&1); rc=$?
assert_nonzero "repo without .single-writer is refused" "$rc"
assert_contains "non-single-writer refusal says why" ".single-writer" "$out"
check "nothing installed into the refused repo" test ! -e "$TMP_ROOT/plain/.git/hooks/pre-push"

new_fixture foreign
printf '#!/bin/sh\n# someone else'"'"'s hook\nexit 0\n' > "$TMP_ROOT/foreign/.git/hooks/pre-push"
chmod +x "$TMP_ROOT/foreign/.git/hooks/pre-push"
cs_before=$(cksum < "$TMP_ROOT/foreign/.git/hooks/pre-push")
out=$(bash "$INSTALLER" "$TMP_ROOT/foreign" 2>&1); rc=$?
assert_nonzero "foreign pre-push hook is not overwritten (rc)" "$rc"
assert_contains "foreign-hook refusal says so" "refusing to overwrite" "$out"
cs_after=$(cksum < "$TMP_ROOT/foreign/.git/hooks/pre-push")
check "foreign hook bytes untouched" test "$cs_before" = "$cs_after"

new_fixture hp
git -C "$TMP_ROOT/hp" config core.hooksPath "$TMP_ROOT/elsewhere"
out=$(bash "$INSTALLER" "$TMP_ROOT/hp" 2>&1); rc=$?
assert_nonzero "core.hooksPath set is refused" "$rc"
assert_contains "hooksPath refusal says why" "core.hooksPath" "$out"

new_fixture hpe
git -C "$TMP_ROOT/hpe" config core.hooksPath ""
out=$(bash "$INSTALLER" "$TMP_ROOT/hpe" 2>&1); rc=$?
assert_nonzero "empty core.hooksPath is refused" "$rc"
assert_contains "empty hooksPath refusal says why" "core.hooksPath" "$out"

echo "== floor check fails closed when its lib is missing =="
mkdir -p "$TMP_ROOT/nolib/hooks" "$TMP_ROOT/nolib/guardrails"
cp "$SCRIPT_DIR/check-single-writer-push-floor.sh" "$TMP_ROOT/nolib/hooks/"
out=$(printf 'refs/heads/main 0000000000000000000000000000000000000000 refs/heads/main 1111111111111111111111111111111111111111\n' \
    | bash "$TMP_ROOT/nolib/hooks/check-single-writer-push-floor.sh" 2>&1); rc=$?
assert_nonzero "missing guardrails lib refuses the push" "$rc"
assert_contains "missing-lib refusal says so" "REFUSING this push" "$out"

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
