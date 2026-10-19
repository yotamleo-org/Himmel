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
VALUE=broken verdict test-only 3 not-applicable

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
# The suite runs under timeout, so TERM goes to the contiguous run of ancestors
# whose command line begins with the gate's (its suite subshell shares it) and
# stops at the first other process, so the test and its launcher survive.
w test-signal.sh "p=\$PPID
seen=0
while [ \"\$p\" -gt 1 ]; do
    case \"\$(ps -o args= -p \"\$p\")\" in
        'bash $GATE '*) seen=1; pids=\"\$p \$pids\" ;;
        *) [ \"\$seen\" -eq 1 ] && break ;;
    esac
    p=\$(ps -o ppid= -p \"\$p\" | tr -d ' ')
done
# Outermost first: the gate must be signalled before its subshell exits.
kill -TERM \$pids
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

# A JS suite runs in a fresh scratch tree with no node_modules. Its deps must be
# installed lockfile-pinned first; a bare npx would fetch unpinned packages.
# PATH stubs keep both rows offline: npx fails unless npm ci ran.
mkdir -p "$T/stubs"
w "$T/stubs/npm" '#!/usr/bin/env bash
case " $* " in *" ci "*"--ignore-scripts"*) ;; *) exit 97 ;; esac
[ -z "${KO_NPM_FAIL:-}" ] || exit 1
mkdir -p node_modules'
w "$T/stubs/npx" '#!/usr/bin/env bash
[ -d node_modules ] || { echo "bare npx: no installed deps" >&2; exit 99; }
[ "$(cat ../../value.txt)" = fixed ]'
chmod +x "$T/stubs/npm" "$T/stubs/npx"

new_repo
w scripts/jira/package.json '{"name":"j"}'
w scripts/jira/package-lock.json '{"lockfileVersion":3}'
commit js-base
BASE=$(git rev-parse HEAD)
w value.txt fixed
w scripts/jira/value.test.ts '// value.txt'
commit js-deps
PATH="$T/stubs:$PATH" verdict js-suite-deps 0 detected

new_repo
w scripts/jira/package.json '{"name":"j"}'
w scripts/jira/package-lock.json '{"lockfileVersion":3}'
commit js-base
BASE=$(git rev-parse HEAD)
w value.txt fixed
w scripts/jira/value.test.ts '// value.txt'
commit js-install-fails
KO_NPM_FAIL=1 PATH="$T/stubs:$PATH" verdict js-install-fails 1 deps-install-failed

# An all-zero cap would disable the timeout, so it is refused like a bare 0.
new_repo
w value.txt fixed
w test-value.sh '[ "$(cat value.txt)" = fixed ]'
commit zero-cap
SUITE_TIMEOUT=00 verdict zero-cap 1 'bad SUITE_TIMEOUT'

# A suite must see EOF on stdin: the suite list is the gate's loop input, so a
# suite that drains stdin would otherwise swallow every suite after it.
new_repo
w value.txt fixed
w test-a-drain.sh 'cat > /dev/null # value.txt'
w test-b-value.sh '[ "$(cat value.txt)" = fixed ]'
commit stdin-drain
verdict stdin-closed 0 detected

# timeout failing (125) or a missing runner (126/127) is not evidence, in either
# phase. The stub passes the baseline through and fails only the knockout run
# (value.txt restored to broken), or both phases when KO_ALWAYS is set.
mkdir -p "$T/tstub"
w "$T/tstub/timeout" "#!/usr/bin/env bash
if [ -n \"\${KO_ALWAYS:-}\" ] || [ \"\$(cat value.txt)\" != fixed ]; then exit \"\$KO_RC\"; fi
exec $(command -v timeout) \"\$@\""
chmod +x "$T/tstub/timeout"
for code in 125 126 127; do
    new_repo
    w value.txt fixed
    w test-value.sh '[ "$(cat value.txt)" = fixed ]'
    commit "runner-$code"
    KO_RC=$code PATH="$T/tstub:$PATH" verdict "knockout-exit-$code" 1 "runner-unavailable"
done
new_repo
w value.txt fixed
w test-value.sh '[ "$(cat value.txt)" = fixed ]'
commit baseline-runner-125
KO_ALWAYS=1 KO_RC=125 PATH="$T/tstub:$PATH" verdict baseline-exit-125 1 "runner-unavailable"

# SUITE_TIMEOUTS caps one named suite below the global cap.
new_repo
w value.txt fixed
w test-hang.sh '[ "$(cat value.txt)" = fixed ] || sleep 60'
commit per-suite-cap
start=$SECONDS
SUITE_TIMEOUT=60 SUITE_TIMEOUTS="test-hang.sh=2" verdict per-suite-cap 0 detected
if [ $((SECONDS - start)) -lt 30 ]; then ok 'per-suite-cap: override applied'; else bad 'per-suite-cap: global cap used'; fi

new_repo
w value.txt fixed
w test-value.sh '[ "$(cat value.txt)" = fixed ]'
commit bad-per-suite-cap
SUITE_TIMEOUTS="test-value.sh=0" verdict bad-per-suite-cap 1 'bad SUITE_TIMEOUTS'

rc=0
bash "$GATE" > "$T/usage" 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then ok 'usage: exit 2'; else bad "usage: expected 2, got $rc"; fi
printf '%s cases; %s failed\n' "$rows" "$fails"
[ "$fails" -eq 0 ]
