#!/usr/bin/env bash
# Smoke test for scripts/hooks/check-push-target.sh.
#
# Root cause: this hook is wired as a pre-commit-configured
# `stages: [pre-push]` entry. pre-commit's own hook-impl drains ALL of git's
# pre-push stdin before invoking any configured hook and exposes the pushed
# ref only via PRE_COMMIT_* env vars — so the hook's stdin is ALWAYS empty
# under that shape, and the old `while read` loop silently exited 0 on every
# push, including a direct push to main (the incident this ticket was filed
# from — confirmed against the real pre-commit dispatch chain: see the
# repro commands in the PR body). Empty stdin is normal there; it is not
# evidence nothing is being pushed.
#
# Covers:
#   1. Raw ref-stream stdin naming main -> BLOCKED (positive control).
#   2. Raw ref-stream stdin naming a feature branch -> PASS (negative control).
#   3. Raw ref-stream stdin naming master -> BLOCKED (is_main_ref covers both).
#   4. Multi-ref raw stdin with main as the SECOND line -> BLOCKED.
#   5. THE BUG: pre-commit-configured shape (PRE_COMMIT=1, empty stdin,
#      PRE_COMMIT_REMOTE_BRANCH=refs/heads/main) -> BLOCKED. Red on the
#      pre-fix script (exit 0 / silent pass), green after the fix.
#   6. Same shape, feature branch -> PASS.
#   7. Empty stdin with NO env at all (a genuine no-op push, e.g. the branch
#      is already up to date, outside pre-commit) -> PASS, not fail-closed.
#   8. PRE_COMMIT=1 but PRE_COMMIT_REMOTE_BRANCH unset (pre-commit's env
#      contract did not hold) -> fail CLOSED.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/check-push-target.sh"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }

expect_blocked() {
    local label="$1" out rc
    shift
    out=$("$@" 2>&1) && rc=0 || rc=$?
    if [ "$rc" -eq 0 ]; then
        fail "$label: push must be BLOCKED" "hook exited 0; output: $out"
    else
        case "$out" in
            *"not allowed"*|*"refusing"*) pass "$label" ;;
            *) fail "$label: blocked but without an explanatory message" "output: $out" ;;
        esac
    fi
}

expect_pass() {
    local label="$1" out rc
    shift
    out=$("$@" 2>&1) && rc=0 || rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "$label"
    else
        fail "$label: push must PASS" "hook exited $rc; output: $out"
    fi
}

# run_raw REF_LINES — feed a raw git pre-push ref stream to the hook on stdin.
# shellcheck disable=SC2329,SC2317  # invoked indirectly via expect_blocked/expect_pass "$@"
run_raw() {
    printf '%s' "$1" | bash "$HOOK"
}

# Test 1/2/3: raw ref-stream stdin (a real .git/hooks/pre-push, the
# pre-push.legacy migration hook, or a direct invocation) -----------------

echo "TEST: raw stdin naming refs/heads/main -> BLOCKED"
expect_blocked "raw stdin, push to main" \
    run_raw "refs/heads/main abc refs/heads/main def
"

echo "TEST: raw stdin naming a feature branch -> PASS"
expect_pass "raw stdin, push to feature branch" \
    run_raw "refs/heads/feat/x abc refs/heads/feat/x def
"

echo "TEST: raw stdin naming refs/heads/master -> BLOCKED"
expect_blocked "raw stdin, push to master" \
    run_raw "refs/heads/master abc refs/heads/master def
"

echo "TEST: multi-ref raw stdin, main is the SECOND line -> BLOCKED"
expect_blocked "raw stdin, multi-ref push with main second" \
    run_raw "refs/heads/feat/x abc refs/heads/feat/x def
refs/heads/main abc refs/heads/main def
"

# Test 5/6: the actual bug shape — pre-commit-configured dispatch ----------

echo "TEST: pre-commit-configured shape (PRE_COMMIT=1, empty stdin, PRE_COMMIT_REMOTE_BRANCH=main) -> BLOCKED"
expect_blocked "configured shape, push to main (HIMMEL-2371 regression)" \
    env PRE_COMMIT=1 PRE_COMMIT_REMOTE_BRANCH=refs/heads/main bash "$HOOK" </dev/null

echo "TEST: pre-commit-configured shape, feature branch -> PASS"
expect_pass "configured shape, push to feature branch" \
    env PRE_COMMIT=1 PRE_COMMIT_REMOTE_BRANCH=refs/heads/feat/x bash "$HOOK" </dev/null

# Test 7: genuinely empty stdin outside pre-commit (no-op push) -----------

echo "TEST: empty stdin, no env at all (no-op push, not through pre-commit) -> PASS"
expect_pass "empty stdin, no pre-commit env" \
    bash "$HOOK" </dev/null

# Test 8: PRE_COMMIT=1 but pre-commit's env contract did not hold ---------

echo "TEST: PRE_COMMIT=1 with no PRE_COMMIT_REMOTE_BRANCH -> fail CLOSED"
expect_blocked "PRE_COMMIT=1, PRE_COMMIT_REMOTE_BRANCH unset" \
    env PRE_COMMIT=1 bash "$HOOK" </dev/null

# Test 9-: branch-name rule for NEW branches ------------------
# A new branch must be type/slug, handover/<TICKET>-<slug> or claude/*. An
# existing remote branch (non-zero remote sha) is never judged retroactively,
# and a delete push is never judged.
ZERO=0000000000000000000000000000000000000000
SHA=1111111111111111111111111111111111111111

expect_blocked_name() {
    local label="$1" out rc
    shift
    out=$("$@" 2>&1) && rc=0 || rc=$?
    case "$out" in
        *"branch name"*)
            if [ "$rc" -ne 0 ]; then pass "$label"; else fail "$label: exit 0" "output: $out"; fi ;;
        *) fail "$label: not blocked on branch name" "rc=$rc output: $out" ;;
    esac
}

echo "TEST: new branches with a valid name -> PASS"
for b in feat/x fix/himmel-5308-foo chore/a.b_c docs/y refactor/z test/t handover/HIMMEL-12-wrap claude/himmel-1-abc123; do
    expect_pass "new branch $b" \
        run_raw "refs/heads/$b $SHA refs/heads/$b $ZERO
"
done

echo "TEST: new branch with an invalid name -> BLOCKED"
for b in wip-stuff bugfix/x feature/x fix/ fix/a/b handover/foo Fix/x; do
    expect_blocked_name "new branch $b" \
        run_raw "refs/heads/$b $SHA refs/heads/$b $ZERO
"
done

echo "TEST: SHA-256 repo (64-zero remote oid) new invalid branch -> BLOCKED"
ZERO64=0000000000000000000000000000000000000000000000000000000000000000
SHA64=1111111111111111111111111111111111111111111111111111111111111111
expect_blocked_name "sha256 new branch wip-stuff" \
    run_raw "refs/heads/wip-stuff $SHA64 refs/heads/wip-stuff $ZERO64
"

echo "TEST: SHA-256 repo delete push of a legacy name -> PASS"
expect_pass "sha256 delete legacy branch" \
    run_raw "(delete) $ZERO64 refs/heads/wip-stuff $SHA64
"

echo "TEST: existing branch with a legacy name -> PASS (never retroactive)"
expect_pass "existing legacy branch" \
    run_raw "refs/heads/wip-stuff $SHA refs/heads/wip-stuff $SHA
"

echo "TEST: delete push of a legacy name -> PASS"
expect_pass "delete legacy branch" \
    run_raw "(delete) $ZERO refs/heads/wip-stuff $SHA
"

echo "TEST: tag push -> PASS"
expect_pass "new tag" \
    run_raw "refs/tags/v1.2 $SHA refs/tags/v1.2 $ZERO
"

echo "TEST: BRANCH_NAME_OK=1 single-run bypass -> PASS"
expect_pass "bypass" \
    env BRANCH_NAME_OK=1 bash "$HOOK" <<REFS
refs/heads/wip-stuff $SHA refs/heads/wip-stuff $ZERO
REFS

echo "TEST: BRANCH_NAME_OK=1 never bypasses the main refusal -> BLOCKED"
expect_blocked "bypass + main" \
    env BRANCH_NAME_OK=1 bash "$HOOK" <<REFS
refs/heads/wip-stuff $SHA refs/heads/main $ZERO
REFS

# pre-commit hides the remote sha, so an invalid name is confirmed against the
# remote itself (a local remote-tracking ref can be missing or stale).
RT=$(mktemp -d) || exit 1
trap 'rm -rf "$RT"' EXIT
git init -q --bare "$RT/remote.git"
git init -q "$RT/work"
git -C "$RT/work" -c user.name=t -c user.email=t@t.invalid commit -q --allow-empty -m seed
git -C "$RT/work" push -q "$RT/remote.git" HEAD:refs/heads/legacy-stuff

echo "TEST: pre-commit shape, invalid name absent on the remote -> BLOCKED"
expect_blocked_name "configured shape, new invalid branch" \
    env PRE_COMMIT=1 PRE_COMMIT_REMOTE_NAME="$RT/remote.git" PRE_COMMIT_REMOTE_BRANCH=refs/heads/wip-stuff bash "$HOOK" </dev/null

echo "TEST: pre-commit shape, invalid name already on the remote -> PASS (never retroactive)"
expect_pass "configured shape, existing legacy branch" \
    env PRE_COMMIT=1 PRE_COMMIT_REMOTE_NAME="$RT/remote.git" PRE_COMMIT_REMOTE_BRANCH=refs/heads/legacy-stuff bash "$HOOK" </dev/null

echo "TEST: pre-commit shape, remote unreachable -> PASS (fail open)"
expect_pass "configured shape, unreachable remote" \
    env PRE_COMMIT=1 PRE_COMMIT_REMOTE_NAME="$RT/nosuch.git" PRE_COMMIT_REMOTE_BRANCH=refs/heads/wip-stuff bash "$HOOK" </dev/null

echo "TEST: pre-commit shape, new valid branch -> PASS"
expect_pass "configured shape, new valid branch" \
    env PRE_COMMIT=1 PRE_COMMIT_REMOTE_NAME="$RT/remote.git" PRE_COMMIT_REMOTE_BRANCH=refs/heads/fix/x bash "$HOOK" </dev/null

# a remote whose pushurl differs from its fetch url. The new-ref
# probe must ask the address the push goes to, not the one it is fetched from.
git init -q --bare "$RT/fetch.git"
git init -q --bare "$RT/push.git"
git -C "$RT/work" push -q "$RT/fetch.git" HEAD:refs/heads/only-fetch
git -C "$RT/work" push -q "$RT/push.git" HEAD:refs/heads/only-push
git init -q "$RT/clone"
git -C "$RT/clone" remote add split "$RT/fetch.git"
git -C "$RT/clone" config remote.split.pushurl "$RT/push.git"

# run_split BRANCH — the pre-commit shape, run from the clone with the split remote.
# shellcheck disable=SC2329,SC2317  # invoked indirectly via expect_blocked_name/expect_pass "$@"
run_split() {
    (cd "$RT/clone" && env PRE_COMMIT=1 PRE_COMMIT_REMOTE_NAME=split PRE_COMMIT_REMOTE_BRANCH="refs/heads/$1" bash "$HOOK" </dev/null)
}

# run_split_url BRANCH — same, with git's own push destination exported.
# shellcheck disable=SC2329,SC2317  # invoked indirectly via expect_pass "$@"
run_split_url() {
    (cd "$RT/clone" && env PRE_COMMIT=1 PRE_COMMIT_REMOTE_NAME=split PRE_COMMIT_REMOTE_URL="$RT/push.git" PRE_COMMIT_REMOTE_BRANCH="refs/heads/$1" bash "$HOOK" </dev/null)
}

echo "TEST: pushurl differs, invalid name exists only on the push address -> PASS (never retroactive)"
expect_pass "split remote, branch exists on the push address" \
    run_split only-push

echo "TEST: pushurl differs, invalid name exists only on the fetch address -> BLOCKED (new where it is pushed)"
expect_blocked_name "split remote, branch absent on the push address" \
    run_split only-fetch

echo "TEST: git's own push destination wins over the remote's configured urls"
git -C "$RT/clone" config remote.split.pushurl "$RT/fetch.git"
expect_pass "PRE_COMMIT_REMOTE_URL names the push address, branch exists there" \
    run_split_url only-push

echo "TEST: no pushurl set -> falls back to the remote itself"
git -C "$RT/clone" config --unset remote.split.pushurl
expect_pass "split remote without pushurl, branch on the fetch address" \
    run_split only-fetch

# Summary ------------------------------------------------------------

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
