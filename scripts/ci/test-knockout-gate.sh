#!/usr/bin/env bash
# Regression suite for knockout-gate.sh. All commits and worktrees belong to
# throwaway repositories; the optional script path is the RED control.
# shellcheck disable=SC2016
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="${1:-$ROOT/scripts/ci/knockout-gate.sh}"
T="$(mktemp -d "${TMPDIR:-/tmp}/knockout-test.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" GIT_CONFIG_GLOBAL="$T/home/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX GIT_IMPLICIT_WORK_TREE GIT_GRAFT_FILE GIT_REPLACE_REF_BASE GIT_SHALLOW_FILE GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
mkdir -p "$HOME"
fails=0
rows=0
bad() { printf 'FAIL - %s\n' "$1" >&2; fails=$((fails + 1)); }
ok() { printf 'ok - %s\n' "$1"; }
w() { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"; }
commit() { git add -A && git -c core.hooksPath=/dev/null commit -qm "$1"; }
new_repo() {
    rows=$((rows + 1))
    R="$T/repo-$rows"
    git init -q "$R" || exit 1
    cd "$R" || exit 1
    git config user.name test
    git config user.email test@example.invalid
    git config commit.gpgsign false
    mkdir -p scripts/cr .github/workflows
    cp "$ROOT/scripts/cr/impacted-suites.sh" "$ROOT/scripts/cr/anchor-handoff.sh" scripts/cr/ || exit 1
    # Real CI configuration, not an invented runner map: the JS row exercises
    # the environment's node:test runner via the real selector's --runner.
    cp "$ROOT/.github/workflows/ci.yml" .github/workflows/ci.yml || exit 1
    w value.txt broken
    commit base || exit 1
    BASE=$(git rev-parse HEAD)
    mkdir -p "$R/tmp"
}
verdict() {
    local name="$1" want="$2" reason="$3" rc=0 before after
    before=$(git status --porcelain --untracked-files=no)
    TMPDIR="$R/tmp" bash "$GATE" "$BASE..HEAD" > "$R/output" 2>&1 || rc=$?
    if [ "$rc" -eq "$want" ] && grep -Fq -- "$reason" "$R/output"; then
        ok "$name: exit $want ($reason)"
    else
        bad "$name: expected exit $want ($reason), got $rc: $(< "$R/output")"
    fi
    after=$(git status --porcelain --untracked-files=no)
    if [ "$before" = "$after" ] && [ "$(< value.txt)" = "${VALUE:-fixed}" ]; then
        ok "$name: real checkout unchanged"
    else
        bad "$name: real checkout changed"
    fi
    if [ -z "$(find "$R/tmp" -mindepth 1 -print)" ] && [ "$(git worktree list --porcelain | grep -c '^worktree ')" -eq 1 ]; then
        ok "$name: scratch directory and worktree removed"
    else
        bad "$name: scratch directory or worktree leaked"
    fi
}

# Removing the actual knockout (or returning success unconditionally) must
# reject these expectations, while preserving the tests must expose the fix.
new_repo
w value.txt fixed
w test-value.sh 'exit 0 # value.txt is deliberately not tested'
commit vacuous
verdict vacuous 1 all-green

new_repo
w value.txt fixed
w test-value.sh '[ "$(cat value.txt)" = fixed ]'
commit genuine
verdict genuine-fix 0 detected

new_repo
w value.txt fixed
commit uncovered
verdict zero-suites 1 no-suites

new_repo
w test-only.sh 'exit 0'
commit tests-only
VALUE=broken verdict test-only 0 not-applicable

new_repo
w value.txt fixed
w added.txt present
w test-added.sh '[ -f added.txt ]'
commit added
verdict added-file 0 detected

new_repo
w obsolete.txt present
commit with-obsolete
BASE=$(git rev-parse HEAD)
w value.txt fixed
rm obsolete.txt
w test-deleted.sh '[ ! -f obsolete.txt ]'
commit deleted
verdict deleted-file 0 detected

new_repo
w value.txt fixed
w scripts/hooks/value.test.mjs 'import { readFileSync } from "node:fs";
import { strict as assert } from "node:assert";
import { test } from "node:test";
test("fix", () => assert.equal(readFileSync("value.txt", "utf8").trim(), "fixed"));'
commit node-suite
verdict real-ci-node-runner 0 detected

# An already-red suite is not evidence that reverting the fix broke it.
new_repo
w value.txt fixed
w test-already-red.sh 'exit 1 # value.txt'
commit already-red
verdict already-red 1 baseline-red

# Runtime errors can also return 1; they must not masquerade as a detection.
new_repo
w value.txt fixed
w scripts/hooks/runtime.test.mjs 'import "./missing-runtime.mjs"; // value.txt'
commit missing-runtime
verdict missing-runtime 1 baseline-red

new_repo
w __tests__/expected.txt broken
commit root-fixture-base
BASE=$(git rev-parse HEAD)
w value.txt fixed
w __tests__/expected.txt fixed
w __tests__/test-root.sh '[ "$(cat value.txt)" = "$(cat __tests__/expected.txt)" ]'
commit root-tests
verdict root-tests 0 detected

new_repo
w value.txt fixed
# The suite runs under timeout, so TERM goes to every ancestor that is the gate
# (its suite subshell shares the gate's command line).
w test-signal.sh "p=\$PPID
while [ \"\$p\" -gt 1 ]; do
    case \"\$(ps -o args= -p \"\$p\")\" in *'$GATE'*) kill -TERM \"\$p\" ;; esac
    p=\$(ps -o ppid= -p \"\$p\" | tr -d ' ')
done
exit 0 # value.txt"
commit interrupted
verdict interrupt 143 'changed value.txt'

# A knocked-out hang must be killed at the cap and count as detection; a hang
# at baseline is not evidence. SUITE_TIMEOUT keeps both rows fast.
new_repo
w value.txt fixed
w test-hang.sh '[ "$(cat value.txt)" = fixed ] || sleep 60'
commit knockout-hang
start=$SECONDS
SUITE_TIMEOUT=2 verdict knockout-hang 0 detected
if [ $((SECONDS - start)) -lt 30 ]; then ok 'knockout-hang: gate returned within the deadline'; else bad 'knockout-hang: gate outlived the deadline'; fi

new_repo
w value.txt fixed
w test-baseline-hang.sh 'sleep 60 # value.txt'
commit baseline-hang
start=$SECONDS
SUITE_TIMEOUT=2 verdict baseline-hang 1 baseline-red
if [ $((SECONDS - start)) -lt 30 ]; then ok 'baseline-hang: gate returned within the deadline'; else bad 'baseline-hang: gate outlived the deadline'; fi

rc=0
bash "$GATE" > "$T/usage" 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then ok 'usage: exit 2'; else bad "usage: expected 2, got $rc"; fi
printf '%s cases; %s failed\n' "$rows" "$fails"
[ "$fails" -eq 0 ]
