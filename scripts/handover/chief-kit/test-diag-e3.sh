#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2015,SC2012,SC2329,SC2016,SC2153,SC2154
set -uo pipefail
# shellcheck source=tests/testlib-ready-check.sh
. "$(cd "$(dirname "$0")" && pwd)/tests/testlib-ready-check.sh"

jira_db_bug_rows
S17_REAL="$HERE/../../cr/impacted-suites.sh"
S17R="$tmp/s17-repo"
S17_A=scripts/test-s17-a.sh
S17_B=scripts/test-s17-b.sh
S17_JS=scripts/lib/s17.test.mjs
git init -q --bare "$tmp/s17-origin.git"
git init -q "$S17R"
git -C "$S17R" config user.email t@example.com
git -C "$S17R" config user.name tester
mkdir -p "$S17R/scripts/lib"
printf 'v1\n' > "$S17R/scripts/lib/s17-lib.sh"
printf 'v1\n' > "$S17R/scripts/lib/s17-dep.mjs"
printf '#!/usr/bin/env bash\n. scripts/lib/s17-lib.sh\n' > "$S17R/$S17_A"
printf '#!/usr/bin/env bash\n. scripts/lib/s17-lib.sh\n' > "$S17R/$S17_B"
printf "import './s17-dep.mjs';\n" > "$S17R/$S17_JS"
git -C "$S17R" add -A
git -C "$S17R" commit -q -m "chore: base"
git -C "$S17R" remote add origin "$tmp/s17-origin.git"
git -C "$S17R" push -q origin HEAD:refs/heads/main
S17_BASE=$(git -C "$S17R" rev-parse HEAD)
printf 'v2\n' > "$S17R/scripts/lib/s17-lib.sh"
git -C "$S17R" commit -q -am "feat(x): [HIMMEL-1] change the lib"
S17_H1=$(git -C "$S17R" rev-parse HEAD)
git -C "$S17R" checkout -q "$S17_BASE"
printf 'v2\n' > "$S17R/scripts/lib/s17-dep.mjs"
git -C "$S17R" commit -q -am "build(deps): bump the dep"
S17_HJS=$(git -C "$S17R" rev-parse HEAD)
git -C "$S17R" checkout -q --orphan s17-orphan
git -C "$S17R" commit -q -m "chore: unrelated history"
S17_ORPHAN=$(git -C "$S17R" rev-parse HEAD)
git -C "$S17R" checkout -q "$S17_BASE"
printf 'v2\n' > "$S17R/scripts/lib/s17-lib.sh"
printf 'v3\n' > "$S17R/scripts/lib/s17-dep.mjs"
git -C "$S17R" commit -q -am "feat(x): [HIMMEL-1] change the lib and the dep"
S17_HMIX=$(git -C "$S17R" rev-parse HEAD)
git -C "$S17R" checkout -q "$S17_H1"
s17_agg() {
    local c="$2"
    [ "$c" = null ] || c="\"$c\""
    printf '{"name":"%s","workflowName":"CI","status":"%s","conclusion":%s,"startedAt":"%s","completedAt":"%s","detailsUrl":"https://github.com/acme/repo/actions/runs/%s/job/9%s"}' \
        "${5:-shell-unit (ubuntu-latest)}" "$1" "$c" "$3" "$3" "$4" "$4"
}
S17_GREEN="[{\"name\":\"build\",\"status\":\"COMPLETED\",\"conclusion\":\"SUCCESS\"},$(s17_agg COMPLETED SUCCESS 2026-11-05T01:00:00Z 555)]"
s17_man() {
    local d="$1/shell-unit-manifest-ubuntu-latest-shard1"
    shift
    mkdir -p "$d"
    { printf 'head 1111111111111111111111111111111111111111\nmode impacted\nshard 1/1\n'; printf '%s\n' "$@"; } > "$d/manifest-shard1.txt"
}
S17_MAN_AB="$tmp/s17-man-ab"; s17_man "$S17_MAN_AB" "ran 0 $S17_A" "ran 0 $S17_B"
S17_MAN_ASKIPB="$tmp/s17-man-askipb"; s17_man "$S17_MAN_ASKIPB" "ran 0 $S17_A" "skip $S17_B"
S17_MAN_A="$tmp/s17-man-a"; s17_man "$S17_MAN_A" "ran 0 $S17_A"
S17_MAN_NEAR="$tmp/s17-man-near"; s17_man "$S17_MAN_NEAR" "ran 0 $S17_A" "ran 00 $S17_B" "ran 10 $S17_B" "ran 0 $S17_B.bak"
s17_at() {
    local keep_sha="$SHA" keep_repo="$REPO" keep_ledger="$LEDGER"
    SHA="$1"; REPO="$S17R"; LEDGER="$S17R/.git/cr-critic-scores.jsonl"
    seed_ledger_ok
    if [ -n "${S17_LP:-}${S17_RS:-}" ]; then
        printf '{"kind":"impacted","ts":"2026-11-05T00:00:00Z","source":"pr-check","branch":"%s","head":"%s","pr":%s,"status":"ok","impacted_n":2,"unverdicted_n":0,"skip_n":0,"rc":0,"local_pass":%s,"ruled_skip":%s}\n' \
            "${S17_ROW_BRANCH:-${STUB_PR_BRANCH:-feat/himmel-100-thing}}" "$SHA" "${S17_ROW_PR:-77}" "${S17_LP:-[]}" "${S17_RS:-[]}" >> "$LEDGER"
    fi
    if [ -n "${S17_RUNBOOK_CMD:-}" ]; then
        s17_rb=$( cd "$S17R" && bash -c "$S17_RUNBOOK_CMD" 2>&1 ) || echo "s17_at: the runbook command failed: $s17_rb"
    fi
    : > "$GH_LOG"
    rc=0; out="$(STUB_IMPACTED_REAL="$S17_REAL" STUB_ROLLUP="${S17_ROLLUP-$S17_GREEN}" run)" || rc=$?
    SHA="$keep_sha"; REPO="$keep_repo"; LEDGER="$keep_ledger"
}
line17() { printf '%s\n' "$1" | grep -F '] 19. ' || true; }
s17_clear() { unset S17_RUNBOOK_CMD S17_LP S17_RS S17_ROW_BRANCH S17_ROW_PR S17_ROLLUP STUB_MANIFEST_DIR STUB_DL_FAIL STUB_DL_SLEEP STUB_RUN_SLEEP STUB_RUN_HEAD_SHA STUB_RUN_CONC READY_CHECK_ITEM19_BOUND STUB_JS_MANIFEST_DIR STUB_JS_DL_FAIL STUB_JOBS STUB_JOBS_FAIL; reset_stubs; }

echo "=== env"
uname -a
echo "_TIMEOUT_BIN=$_TIMEOUT_BIN"

xt_wrap="$tmp/xt-wrap.sh"
printf '#!/usr/bin/env bash\nPS4="+ \\$SECONDS \\${BASH_SOURCE##*/}:\\$LINENO "\nexport PS4\nexec bash -x %q "$@"\n' "$SCRIPT" > "$xt_wrap"
chmod +x "$xt_wrap"
xt_sum() {
    awk '{ if (/^\+/ && $2 != last) { print substr($0, 1, 170); last = $2 } } END { print "lines: " NR }' "$1"
}

echo "=== impacted-suites.sh timing (5 runs)"
for _ in 1 2 3 4 5; do
    t0=$SECONDS
    (cd "$S17R" && bash "$S17_REAL" "$S17_BASE..$S17_H1" > /dev/null 2>&1)
    echo "impacted $((SECONDS - t0))s"
done

echo "=== green run, xtrace by second"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"
{ _READY_CHECK_ARMED=1 RUN_SCRIPT="$xt_wrap" s17_at "$S17_H1"; } 2> "$tmp/xt-green.err"
echo "rc=$rc"
xt_sum "$tmp/xt-green.err"

r4_once() {
    reset_stubs
    r4_shared="$tmp/lock-cache-r4-$1"; mkdir -p "$r4_shared"
    r4_mark="$tmp/r4-holder-$1.pid"; rm -f "$r4_mark"
    REAL_TIMEOUT="$_TIMEOUT_BIN"
    r4_t0=$SECONDS
    rc=0
    out="$(STUB_MSS=UNKNOWN STUB_HOLD_MARK="$r4_mark" STUB_HOLD_TIMEOUT="$REAL_TIMEOUT" STUB_HOLD_LIB="$HERE/../../lib/gh-pr-snapshot.sh" RUN_CACHE="$r4_shared" run)" || rc=$?
    echo "R4 $1 rc=$rc elapsed=$((SECONDS - r4_t0))s"
    r4_hpid=$(cat "$r4_mark" 2>/dev/null) || r4_hpid=""
    [ -z "$r4_hpid" ] || kill "$r4_hpid" 2>/dev/null
}
echo "=== R4 replica, plain"
r4_once plain
echo "=== R4 replica, xtrace by second (no wrapper)"
{ _READY_CHECK_ARMED=1 RUN_SCRIPT="$xt_wrap" r4_once xt; } 2> "$tmp/xt-r4.err"
xt_sum "$tmp/xt-r4.err"

echo "FAIL - diag3 (intentional, to keep the log)"
exit 1
