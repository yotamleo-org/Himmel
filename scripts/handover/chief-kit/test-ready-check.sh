#!/usr/bin/env bash
# scripts/handover/chief-kit/test-ready-check.sh — suite for ready-check.sh
# `gh` is a PATH stub (contract requirement — not GH_CMD, even
# though the script also honors that override); `jq` and `git` are real.
#
# Covers: usage (arg count / bad PR / bad sha), one all-green PR, and one
# failing case per check (1..6).
#
# Platform guard: POSIX bash 3.2+.
# shellcheck disable=SC2015,SC2034,SC2153,SC2154
set -uo pipefail
# shellcheck source=tests/testlib-ready-check.sh
. "$(cd "$(dirname "$0")" && pwd)/tests/testlib-ready-check.sh"

# --- usage -------------------------------------------------------------
for args in "" "77" "77 $SHA extra" "x1 $SHA" "077 $SHA" "77 ${SHA%?}" "77 ${SHA}0" \
            "77 0123456789ABCDEF0123456789abcdef01234567" "77 g123456789abcdef0123456789abcdef01234567"; do
  rc=0
  # shellcheck disable=SC2086  # word-splitting the args string IS the point
  bash "$SCRIPT" $args >/dev/null 2>&1 || rc=$?
  check "usage: [$args] -> exit 2" "$rc" "2"
done

# a usage error names where to run it and the expected arguments
for args in "" "77 ${SHA%?}"; do
  # shellcheck disable=SC2086  # word-splitting the args string IS the point
  uout="$(bash "$SCRIPT" $args 2>&1)" || true
  contains "usage [$args]: says it runs from any directory" "$uout" "from any directory"
  contains "usage [$args]: quotes the real primary checkout's script path, no cd" "$uout" "from any directory: bash '$test_primary/scripts/handover/chief-kit/ready-check.sh' <pr-number> <full-40-hex-head-sha>"
done

# --- 0. all-green PR: exit 0, READY-CHECK PASS, all six PASS lines ------
reset_stubs
: > "$GH_LOG"
rc=0; out="$(run)" || rc=$?
gql_calls=$(grep -Ec '^(repo view|pr view|api graphql)' "$GH_LOG")
check "green: at most two GraphQL calls" "$((gql_calls <= 2))" "1"
check "green: exit 0" "$rc" "0"
contains "green: overall verdict" "$out" "READY-CHECK PASS"
contains "green: check 1 passes" "$out" "[PASS] 1."
contains "green: check 2 passes" "$out" "[PASS] 2."
contains "green: check 3 passes" "$out" "[PASS] 3."
contains "green: check 4 passes" "$out" "[PASS] 4."
contains "green: check 5 passes" "$out" "[PASS] 5."
contains "green: check 6 passes" "$out" "[PASS] 6."
contains "green: names the diff read as the chief's job" "$out" "stays the chief's own judgement"

# An unreadable shared snapshot must fail every dependent check, not just head.
reset_stubs
STUB_SNAPSHOT_FAIL=1
rc=0; out="$(run)" || rc=$?
check "unreadable snapshot: exit 1" "$rc" "1"
for item in 1 2 3 5 6 7; do
    contains "unreadable snapshot: check $item fails" "$out" "[FAIL] $item."
done

# --- 1a. check 1 fails: head mismatch -----------------------------------
reset_stubs
STUB_HEAD=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
rc=0; out="$(run)" || rc=$?
check "head-mismatch: exit 1" "$rc" "1"
contains "head-mismatch: check 1 fails" "$out" "[FAIL] 1."
contains "head-mismatch: overall verdict" "$out" "READY-CHECK FAIL"

# --- 1b. check 1 fails: mergeStateStatus not CLEAN ----------------------
reset_stubs
STUB_MSS=DIRTY
rc=0; out="$(run)" || rc=$?
check "dirty-merge: exit 1" "$rc" "1"
contains "dirty-merge: check 1 fails" "$out" "[FAIL] 1."

# --- 1c. check 1 fails: a head behind main says what to do --------------
reset_stubs
STUB_MSS=BEHIND
rc=0; out="$(run)" || rc=$?
check "behind-main: exit 1 (verdict unchanged)" "$rc" "1"
contains "behind-main: check 1 still fails" "$out" "[FAIL] 1."
contains "behind-main: says merge origin/main into the branch" "$out" "git merge origin/main"
contains "behind-main: says to re-run at the new head" "$out" "re-run with the new head sha"
contains "behind-main: says nothing to do when CLEAN and the head matches" "$out" "nothing to do when mergeStateStatus is CLEAN and the head matches"

# --- 12a. check 12 fails: a stale anchor says to run from the primary checkout ---
reset_stubs
STALE_ANCHOR="$tmp/tp-stale"
git clone -q "$TP_ANCHOR" "$STALE_ANCHOR"
git -C "$TP_ANCHOR" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "newer"
STUB_FILES="scripts/handover/chief-kit/ready-check.sh"
rc=0; out="$(READY_CHECK_ANCHOR="$STALE_ANCHOR" run)" || rc=$?
check "stale-anchor: exit 1" "$rc" "1"
contains "stale-anchor: check 12 refuses" "$out" "[FAIL] 12."
contains "stale-anchor: names the cause" "$out" "behind origin"
contains "stale-anchor: says to pull the primary checkout" "$out" "pull the primary checkout"
notcontains "stale-anchor: never sends the worker out of its worktree" "$out" "not from a worktree"
notcontains "stale-anchor: the refusal prints no TRUST-PATH line" "$out" "TRUST-PATH:"

# --- 12b-12d. check 12 run from a linked worktree, READY_CHECK_ANCHOR unset ---
WT_PRIM="$tmp/wt-prim"; WT_LINKED="$tmp/wt-linked"
git init -q --bare "$tmp/wt-origin.git"
git init -q "$WT_PRIM"
mkdir -p "$WT_PRIM/scripts/lib"
cp "$HERE/../../lib/go-gate.sh" "$WT_PRIM/scripts/lib/go-gate.sh"
git -C "$WT_PRIM" add -A
git -C "$WT_PRIM" -c user.name=t -c user.email=t@t commit -q -m init
git -C "$WT_PRIM" remote add origin "$tmp/wt-origin.git"
git -C "$WT_PRIM" push -q origin HEAD:refs/heads/main 2>/dev/null
git -C "$tmp/wt-origin.git" symbolic-ref HEAD refs/heads/main
git -C "$WT_PRIM" worktree add -q -b wt-branch "$WT_LINKED"
git -C "$WT_PRIM" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "main moved"
git -C "$WT_PRIM" push -q origin HEAD:refs/heads/main 2>/dev/null
mkdir -p "$WT_LINKED/scripts/handover/chief-kit"
cp "$SCRIPT" "$WT_LINKED/scripts/handover/chief-kit/ready-check.sh"
rm -rf "$WT_LINKED/scripts/lib"
cp -R "$HERE/../../lib" "$WT_LINKED/scripts/lib"
wt_run() { READY_CHECK_ANCHOR="" RUN_CWD="$WT_LINKED" RUN_SCRIPT=scripts/handover/chief-kit/ready-check.sh run; }

reset_stubs
STUB_FILES="scripts/handover/chief-kit/ready-check.sh"
out="$(wt_run)" || true
contains "worktree-run: a trust-path hit passes check 12 against the current primary" "$out" "[PASS] 12. trust path: hit scripts/handover/chief-kit/ready-check.sh"
contains "worktree-run: a trust-path hit prints TRUST-PATH: yes" "$out" "TRUST-PATH: yes"
notcontains "worktree-run: check 12 does not refuse the worktree run" "$out" "[FAIL] 12."

reset_stubs
out="$(wt_run)" || true
contains "worktree-run control: a file off the list passes check 12" "$out" "[PASS] 12. trust path: none"
contains "worktree-run control: prints TRUST-PATH: no" "$out" "TRUST-PATH: no"

reset_stubs
STUB_FILES="scripts/handover/chief-kit/ready-check.sh"
wt_ahead=$(git -C "$WT_PRIM" -c user.name=t -c user.email=t@t commit-tree "HEAD^{tree}" -p HEAD -m "origin moved past the primary")
git -C "$WT_PRIM" push -q origin "$wt_ahead:refs/heads/main" 2>/dev/null
out="$(wt_run)" || true
contains "worktree-run stale primary: check 12 still refuses" "$out" "[FAIL] 12."
contains "worktree-run stale primary: names the primary as the stale anchor" "$out" "the anchor $(cd "$WT_PRIM" && pwd -P) is behind origin"
notcontains "worktree-run stale primary: the refusal prints no TRUST-PATH line" "$out" "TRUST-PATH:"

# --- 2. check 2 fails: a red check in the rollup ------------------------
reset_stubs
STUB_ROLLUP='[{"name":"build","status":"COMPLETED","conclusion":"FAILURE"}]'
rc=0; out="$(run)" || rc=$?
check "red-check: exit 1" "$rc" "1"
contains "red-check: check 2 fails" "$out" "[FAIL] 2."
contains "red-check: names the offender" "$out" "build=COMPLETED/FAILURE"

# --- 2b. check 2 fails: empty rollup (CI not registered yet) ------------
reset_stubs
STUB_ROLLUP='[]'
rc=0; out="$(run)" || rc=$?
check "empty-rollup: exit 1" "$rc" "1"
contains "empty-rollup: check 2 fails" "$out" "[FAIL] 2. statusCheckRollup: no checks reported yet"

# --- 2c. same check name CANCELLED earlier, SUCCESS later —
# item 2 must PASS (judge the LATEST run per check identity, not any row) --
reset_stubs
STUB_ROLLUP='[{"name":"pr-title-lint","status":"COMPLETED","conclusion":"CANCELLED","startedAt":"2026-01-01T08:15:00Z","completedAt":"2026-01-01T08:19:58Z"},{"name":"pr-title-lint","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-01-01T08:24:00Z","completedAt":"2026-01-01T08:26:47Z"}]'
rc=0; out="$(run)" || rc=$?
check "superseded-cancelled: exit 0" "$rc" "0"
contains "superseded-cancelled: check 2 passes on the later SUCCESS run" "$out" "[PASS] 2."

# --- 2d. control: same name SUCCESS earlier, CANCELLED later — the later
# run still governs, so item 2 FAILs ----------------------------------------
reset_stubs
STUB_ROLLUP='[{"name":"pr-title-lint","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-01-01T08:10:00Z","completedAt":"2026-01-01T08:12:00Z"},{"name":"pr-title-lint","status":"COMPLETED","conclusion":"CANCELLED","startedAt":"2026-01-01T08:20:00Z","completedAt":"2026-01-01T08:22:00Z"}]'
rc=0; out="$(run)" || rc=$?
check "later-cancelled: exit 1" "$rc" "1"
contains "later-cancelled: check 2 fails on the later run" "$out" "[FAIL] 2."
contains "later-cancelled: names the latest run's detail" "$out" "pr-title-lint=COMPLETED/CANCELLED"

# --- 2e. control: two DIFFERENT check names, one FAILURE — each keeps its
# own verdict; grouping must not merge unrelated names ----------------------
reset_stubs
STUB_ROLLUP='[{"name":"build","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"lint","status":"COMPLETED","conclusion":"FAILURE"}]'
rc=0; out="$(run)" || rc=$?
check "two-names-one-failure: exit 1" "$rc" "1"
contains "two-names-one-failure: check 2 fails" "$out" "[FAIL] 2."
contains "two-names-one-failure: names only the failing check" "$out" "lint=COMPLETED/FAILURE"

CRB_OK='{"name":"build","status":"COMPLETED","conclusion":"SUCCESS"}'
CRB_PEND='{"context":"CodeRabbit","state":"PENDING"}'
CRB_PROG='{"context":"CodeRabbit","state":"IN_PROGRESS"}'
for crb_row in "PENDING:$CRB_PEND" "IN_PROGRESS:$CRB_PROG"; do
    crb_name="${crb_row%%:*}"; crb_json="${crb_row#*:}"
    reset_stubs
    STUB_MSS=UNSTABLE
    STUB_ROLLUP="[$CRB_OK,$crb_json]"
    rc=0; out="$(STUB_CR_STATE=pending STUB_CR_DESC='Review in progress' run)" || rc=$?
    contains "cr-$crb_name: item 1 passes" "$out" "[PASS] 1."
    contains "cr-$crb_name: item 2 passes" "$out" "[PASS] 2."
    contains "cr-$crb_name: a WARN names CodeRabbit" "$out" "[WARN] 2. CodeRabbit"
    notcontains "cr-$crb_name: no FAIL on item 1 or 2" "$out" "[FAIL] 2."
    reset_stubs
    STUB_MSS=UNSTABLE
    STUB_ROLLUP="[$CRB_OK,$crb_json]"
    rc=0; out="$(STUB_CR_STATUSES='[{"context":"CodeRabbit","state":"pending","description":"Review in progress","created_at":"2026-11-02T18:44:07Z","creator":{"id":1,"login":"someone","type":"User"}}]' run)" || rc=$?
    contains "cr-$crb_name spoof: item 2 still fails" "$out" "[FAIL] 2."
    contains "cr-$crb_name spoof: item 1 still fails" "$out" "[FAIL] 1."
    reset_stubs
    STUB_MSS=UNSTABLE
    STUB_ROLLUP="[$CRB_OK,$crb_json]"
    out="$(run)" || true
    contains "cr-$crb_name unreadable statuses: item 2 still fails" "$out" "[FAIL] 2."
    reset_stubs
    STUB_MSS=UNSTABLE
    STUB_ROLLUP="[$CRB_OK,{\"name\":\"lint\",\"status\":\"IN_PROGRESS\",\"conclusion\":null},$crb_json]"
    out="$(STUB_CR_STATE=pending STUB_CR_DESC='Review in progress' run)" || true
    contains "cr-$crb_name + other pending: item 2 fails" "$out" "[FAIL] 2."
    contains "cr-$crb_name + other pending: names the other check" "$out" "lint="
    contains "cr-$crb_name + other pending: item 1 fails" "$out" "[FAIL] 1."
done
reset_stubs
STUB_MSS=UNSTABLE
STUB_ROLLUP="[$CRB_OK,{\"name\":\"lint\",\"status\":\"IN_PROGRESS\",\"conclusion\":null}]"
out="$(run)" || true
contains "other-pending alone: item 2 fails" "$out" "[FAIL] 2."
contains "other-pending alone: item 1 fails" "$out" "[FAIL] 1."
reset_stubs
STUB_MSS=UNSTABLE
STUB_ROLLUP="[$CRB_OK,{\"context\":\"CodeRabbit\",\"state\":\"FAILURE\"}]"
out="$(STUB_CR_STATE=failure STUB_CR_DESC='Review failed' run)" || true
contains "cr FAILURE control: item 2 fails" "$out" "[FAIL] 2."
contains "cr FAILURE control: names CodeRabbit" "$out" "CodeRabbit=FAILURE"
reset_stubs
STUB_MSS=UNSTABLE
STUB_ROLLUP="[$CRB_PEND]"
out="$(STUB_CR_STATE=pending STUB_CR_DESC='Review in progress' run)" || true
contains "cr-only rollup: item 2 fails as no checks" "$out" "[FAIL] 2. statusCheckRollup: no checks reported yet"
reset_stubs
STUB_MSS=UNSTABLE
STUB_ROLLUP="[$CRB_OK,{\"context\":\"ci/other\",\"state\":\"PENDING\"},$CRB_PEND]"
out="$(STUB_CR_STATE=pending STUB_CR_DESC='Review in progress' run)" || true
contains "name guard: item 1 fails with a pending non-CodeRabbit context" "$out" "[FAIL] 1."
contains "name guard: item 2 fails" "$out" "[FAIL] 2."
contains "name guard: names ci/other" "$out" "ci/other=PENDING"
reset_stubs
STUB_MSS=UNSTABLE
STUB_ROLLUP="[$CRB_OK,$CRB_PEND]"
crb_t0=$SECONDS
out="$(STUB_CR_SLEEP=1 STUB_CR_STATE=pending STUB_CR_DESC='Review in progress' run)" || true
crb_dt=$((SECONDS - crb_t0))
contains "deadline: a stalled confirmation fails item 2 closed" "$out" "[FAIL] 2."
notcontains "deadline: a stalled confirmation prints no CodeRabbit WARN" "$out" "[WARN] 2. CodeRabbit"
check "deadline: both stalled status reads are cut at 20 s each, run took ${crb_dt}s, under 50" "$((crb_dt < 50))" "1"

# --- 2f. non-gating contexts: the exact-match list in scripts/lib/non-gating-contexts.txt.
# Only the listed status context in ERROR: row 2 passes and names it ----------
SNYK_ERR='{"context":"security/snyk (yotamleo)","state":"ERROR","createdAt":"2026-01-01T08:10:00Z"}'
BUILD_OK='{"name":"build","status":"COMPLETED","conclusion":"SUCCESS"}'
BUILD_RED='{"name":"build","status":"COMPLETED","conclusion":"FAILURE"}'
reset_stubs
STUB_ROLLUP="[$BUILD_OK,$SNYK_ERR]"
rc=0; out="$(run)" || rc=$?
check "nongating-error-only: exit 0" "$rc" "0"
contains "nongating-error-only: check 2 passes" "$out" "[PASS] 2."
contains "nongating-error-only: check 2 names the skipped context" "$out" "security/snyk (yotamleo)=ERROR"

# UNSTABLE with only the listed context failing: row 1 passes ----------------
reset_stubs
STUB_MSS=UNSTABLE
STUB_ROLLUP="[$BUILD_OK,$SNYK_ERR]"
rc=0; out="$(run)" || rc=$?
check "nongating-unstable: exit 0" "$rc" "0"
contains "nongating-unstable: check 1 passes" "$out" "[PASS] 1."
contains "nongating-unstable: check 1 names the context" "$out" "security/snyk (yotamleo)"

# An unlisted failure still fails, with or without the listed one ------------
reset_stubs
STUB_ROLLUP="[$BUILD_RED,$SNYK_ERR]"
rc=0; out="$(run)" || rc=$?
check "nongating-plus-unlisted-red: exit 1" "$rc" "1"
contains "nongating-plus-unlisted-red: check 2 fails" "$out" "[FAIL] 2."
contains "nongating-plus-unlisted-red: names the unlisted offender" "$out" "build=COMPLETED/FAILURE"
fail2="$(printf '%s\n' "$out" | grep -F '[FAIL] 2.' || true)"
contains "nongating-plus-unlisted-red: the check 2 line was extracted" "$fail2" "[FAIL] 2."
notcontains "nongating-plus-unlisted-red: the listed context is not an offender" "$fail2" "security/snyk"

# A CheckRun that shares the listed name is a different check and still gates --
SNYK_CHECKRUN='{"name":"security/snyk (yotamleo)","status":"COMPLETED","conclusion":"FAILURE"}'
reset_stubs
STUB_ROLLUP="[$BUILD_OK,$SNYK_CHECKRUN]"
rc=0; out="$(run)" || rc=$?
check "nongating-checkrun-same-name: exit 1" "$rc" "1"
contains "nongating-checkrun-same-name: check 2 fails" "$out" "[FAIL] 2."
contains "nongating-checkrun-same-name: names the check run" "$out" "security/snyk (yotamleo)=COMPLETED/FAILURE"

# UNSTABLE with an unlisted failure fails row 1 ------------------------------
reset_stubs
STUB_MSS=UNSTABLE
STUB_ROLLUP="[$BUILD_RED,$SNYK_ERR]"
rc=0; out="$(run)" || rc=$?
check "unstable-unlisted-red: exit 1" "$rc" "1"
contains "unstable-unlisted-red: check 1 fails" "$out" "[FAIL] 1."

# UNSTABLE with nothing non-green to explain it fails row 1 ------------------
reset_stubs
STUB_MSS=UNSTABLE
STUB_ROLLUP="[$BUILD_OK]"
rc=0; out="$(run)" || rc=$?
check "unstable-all-green: exit 1" "$rc" "1"
contains "unstable-all-green: check 1 fails" "$out" "[FAIL] 1."

# Exact match only: a longer or shorter name is a normal check ---------------
for ctx in 'security/snyk (yotamleo) extra' 'security/snyk' 'x security/snyk (yotamleo)'; do
    reset_stubs
    STUB_MSS=UNSTABLE
    STUB_ROLLUP="[$BUILD_OK,{\"context\":\"$ctx\",\"state\":\"ERROR\"}]"
    rc=0; out="$(run)" || rc=$?
    check "lookalike [$ctx]: exit 1" "$rc" "1"
    contains "lookalike [$ctx]: check 1 fails" "$out" "[FAIL] 1."
    contains "lookalike [$ctx]: check 2 fails" "$out" "[FAIL] 2."
done

# The listed context alone proves nothing: no real check, no pass ------------
reset_stubs
STUB_ROLLUP="[$SNYK_ERR]"
rc=0; out="$(run)" || rc=$?
check "nongating-only-rollup: exit 1" "$rc" "1"
contains "nongating-only-rollup: check 2 fails" "$out" "[FAIL] 2."

# --- 2f. control: same name in two different workflows, one FAILURE — a
# different workflowName means a different identity, so the earlier failing
# workflow's run must not be superseded by the other workflow's later
# success (a grouping-by-name-only bug would hide this) ---------------------
reset_stubs
STUB_ROLLUP='[{"name":"test","workflowName":"CI-B","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-01-01T08:00:00Z","completedAt":"2026-01-01T08:02:00Z"},{"name":"test","workflowName":"CI-A","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-01-01T08:05:00Z","completedAt":"2026-01-01T08:07:00Z"}]'
rc=0; out="$(run)" || rc=$?
check "same-name-two-workflows: exit 1" "$rc" "1"
contains "same-name-two-workflows: check 2 fails" "$out" "[FAIL] 2."
contains "same-name-two-workflows: names the failing workflow's run" "$out" "test=COMPLETED/FAILURE"

# --- 2g. control: an in-progress later run after an earlier SUCCESS — the
# later, unfinished run governs, so item 2 FAILs ----------------------------
reset_stubs
STUB_ROLLUP='[{"name":"pr-title-lint","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-01-01T08:10:00Z","completedAt":"2026-01-01T08:12:00Z"},{"name":"pr-title-lint","status":"IN_PROGRESS","conclusion":null,"startedAt":"2026-01-01T08:20:00Z"}]'
rc=0; out="$(run)" || rc=$?
check "later-in-progress: exit 1" "$rc" "1"
contains "later-in-progress: check 2 fails on the still-running later run" "$out" "[FAIL] 2."
contains "later-in-progress: names the in-progress run" "$out" "pr-title-lint=IN_PROGRESS/null"

# --- 2h. control: a later QUEUED run (no startedAt/completedAt at all) after
# an earlier timestamped SUCCESS — a run that has not started yet has no
# timestamp to lose a max_by comparison with, so it must still govern and
# item 2 FAILs (an untimed later run must not lose to an
# earlier timestamped one) --------------------------------------------------
reset_stubs
STUB_ROLLUP='[{"name":"pr-title-lint","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-01-01T08:10:00Z","completedAt":"2026-01-01T08:12:00Z"},{"name":"pr-title-lint","status":"QUEUED","conclusion":null}]'
rc=0; out="$(run)" || rc=$?
check "later-queued-untimed: exit 1" "$rc" "1"
contains "later-queued-untimed: check 2 fails on the still-queued later run" "$out" "[FAIL] 2."
contains "later-queued-untimed: names the queued run" "$out" "pr-title-lint=QUEUED/null"

# --- 2i. superseded runs: a green fresh run clears an old run's rows that
# the fresh run never re-reports. The rows are PR 4277's real rollup at
# head 212754674539 (CI runs 41005958845 and 41057072476 failed lint, 41059698017
# is green; fail-fast-lint only runs when lint fails, so the green run reports no
# row under that name). Repo slug rewritten to acme/repo. ----------------------
R4277='[{"completedAt":"2026-10-30T05:02:41Z","conclusion":"SUCCESS","detailsUrl":"https://github.com/acme/repo/actions/runs/41005958845/job/123900901871","name":"plan","startedAt":"2026-10-30T05:00:31Z","status":"COMPLETED","workflowName":"CI"},{"completedAt":"2026-10-30T12:42:09Z","conclusion":"SUCCESS","detailsUrl":"https://github.com/acme/repo/actions/runs/41057072476/job/124067191535","name":"plan","startedAt":"2026-10-30T12:40:12Z","status":"COMPLETED","workflowName":"CI"},{"completedAt":"2026-10-30T13:03:12Z","conclusion":"SUCCESS","detailsUrl":"https://github.com/acme/repo/actions/runs/41059698017/job/124076049152","name":"plan","startedAt":"2026-10-30T13:00:38Z","status":"COMPLETED","workflowName":"CI"},{"completedAt":"2026-10-30T05:12:41Z","conclusion":"FAILURE","detailsUrl":"https://github.com/acme/repo/actions/runs/41005958845/job/123900901660","name":"lint","startedAt":"2026-10-30T05:00:32Z","status":"COMPLETED","workflowName":"CI"},{"completedAt":"2026-10-30T12:55:10Z","conclusion":"FAILURE","detailsUrl":"https://github.com/acme/repo/actions/runs/41057072476/job/124067191570","name":"lint","startedAt":"2026-10-30T12:40:13Z","status":"COMPLETED","workflowName":"CI"},{"completedAt":"2026-10-30T13:15:56Z","conclusion":"SUCCESS","detailsUrl":"https://github.com/acme/repo/actions/runs/41059698017/job/124076049669","name":"lint","startedAt":"2026-10-30T13:00:39Z","status":"COMPLETED","workflowName":"CI"},{"completedAt":"2026-10-30T05:12:46Z","conclusion":"CANCELLED","detailsUrl":"https://github.com/acme/repo/actions/runs/41005958845/job/123904504863","name":"fail-fast-lint","startedAt":"2026-10-30T05:12:43Z","status":"COMPLETED","workflowName":"CI"},{"completedAt":"2026-10-30T12:55:16Z","conclusion":"CANCELLED","detailsUrl":"https://github.com/acme/repo/actions/runs/41057072476/job/124073676920","name":"fail-fast-lint","startedAt":"2026-10-30T12:55:12Z","status":"COMPLETED","workflowName":"CI"},{"completedAt":"2026-10-30T05:14:09Z","conclusion":"CANCELLED","detailsUrl":"https://github.com/acme/repo/actions/runs/41005958845/job/123904939618","name":"(!(github.event_name == '\''pull_request'\'' && github.event.action == '\''labeled'\'') || (github.event.label.name == (vars.CI_GO_LABEL || '\''ci:go'\'') && vars.CI_GO_GATE == '\''on'\'')) && '\''fail-fast-shell-unit-shard'\'' || '\''fail-fast-shell-unit-shard (deferred)'\''","startedAt":"2026-10-30T05:14:09Z","status":"COMPLETED","workflowName":"CI"},{"completedAt":"2026-10-30T12:56:15Z","conclusion":"CANCELLED","detailsUrl":"https://github.com/acme/repo/actions/runs/41057072476/job/124074152290","name":"(!(github.event_name == '\''pull_request'\'' && github.event.action == '\''labeled'\'') || (github.event.label.name == (vars.CI_GO_LABEL || '\''ci:go'\'') && vars.CI_GO_GATE == '\''on'\'')) && '\''fail-fast-shell-unit-shard'\'' || '\''fail-fast-shell-unit-shard (deferred)'\''","startedAt":"2026-10-30T12:56:16Z","status":"COMPLETED","workflowName":"CI"},{"completedAt":"2026-10-30T13:23:40Z","conclusion":"SKIPPED","detailsUrl":"https://github.com/acme/repo/actions/runs/41059698017/job/124086698085","name":"(!(github.event_name == '\''pull_request'\'' && github.event.action == '\''labeled'\'') || (github.event.label.name == (vars.CI_GO_LABEL || '\''ci:go'\'') && vars.CI_GO_GATE == '\''on'\'')) && '\''fail-fast-shell-unit-shard'\'' || '\''fail-fast-shell-unit-shard (deferred)'\''","startedAt":"2026-10-30T13:23:41Z","status":"COMPLETED","workflowName":"CI"},{"completedAt":"2026-10-30T05:14:22Z","conclusion":"FAILURE","detailsUrl":"https://github.com/acme/repo/actions/runs/41005958845/job/123904938080","name":"shell-unit (ubuntu-latest)","startedAt":"2026-10-30T05:14:10Z","status":"COMPLETED","workflowName":"CI"},{"completedAt":"2026-10-30T12:56:29Z","conclusion":"FAILURE","detailsUrl":"https://github.com/acme/repo/actions/runs/41057072476/job/124074150849","name":"shell-unit (ubuntu-latest)","startedAt":"2026-10-30T12:56:17Z","status":"COMPLETED","workflowName":"CI"},{"completedAt":"2026-10-30T13:25:17Z","conclusion":"SUCCESS","detailsUrl":"https://github.com/acme/repo/actions/runs/41059698017/job/124086694892","name":"shell-unit (ubuntu-latest)","startedAt":"2026-10-30T13:23:42Z","status":"COMPLETED","workflowName":"CI"}]'
FFL='fail-fast-lint=COMPLETED/CANCELLED'
reset_stubs
STUB_ROLLUP="$R4277"
rc=0; out="$(run)" || rc=$?
check "4277-real-rollup: exit 0" "$rc" "0"
contains "4277-real-rollup: check 2 passes" "$out" "[PASS] 2."
# the snapshot query must ask for each CheckRun's detailsUrl, or the run id is never readable
contains "4277-real-rollup: the snapshot query requests detailsUrl" "$(cat "$GH_LOG")" "completedAt detailsUrl checkSuite"

# a newer run that is wholly skipped (the ci:go label) supersedes nothing
reset_stubs
STUB_ROLLUP="$(jq -c 'map(if (.detailsUrl | contains("/runs/41059698017/")) then .conclusion = "SKIPPED" else . end)' <<< "$R4277")"
rc=0; out="$(run)" || rc=$?
check "newer-run-wholly-skipped: exit 1" "$rc" "1"
contains "newer-run-wholly-skipped: the old cancelled fail-fast row stays judged" "$out" "$FFL"

# a newer run still in progress supersedes nothing
reset_stubs
STUB_ROLLUP="$(jq -c 'map(if (.detailsUrl | contains("/runs/41059698017/")) and .name == "lint" then .status = "IN_PROGRESS" | .conclusion = "" else . end)' <<< "$R4277")"
rc=0; out="$(run)" || rc=$?
check "newer-run-in-progress: exit 1" "$rc" "1"
contains "newer-run-in-progress: the old cancelled fail-fast row stays judged" "$out" "$FFL"

# a newer run that failed supersedes nothing
reset_stubs
STUB_ROLLUP="$(jq -c 'map(if (.detailsUrl | contains("/runs/41059698017/")) and .name == "plan" then .conclusion = "FAILURE" else . end)' <<< "$R4277")"
rc=0; out="$(run)" || rc=$?
check "newer-run-failed: exit 1" "$rc" "1"
contains "newer-run-failed: the old cancelled fail-fast row stays judged" "$out" "$FFL"

# a row with no readable run id stays judged
reset_stubs
STUB_ROLLUP="$(jq -c 'map(if .name == "fail-fast-lint" then del(.detailsUrl) else . end)' <<< "$R4277")"
rc=0; out="$(run)" || rc=$?
check "row-without-run-id: exit 1" "$rc" "1"
contains "row-without-run-id: the cancelled fail-fast row stays judged" "$out" "$FFL"

# a newer green run of ANOTHER workflow supersedes nothing
reset_stubs
STUB_ROLLUP="$(jq -c 'map(if (.detailsUrl | contains("/runs/41059698017/")) then .workflowName = "Other" else . end)' <<< "$R4277")"
rc=0; out="$(run)" || rc=$?
check "newer-run-other-workflow: exit 1" "$rc" "1"
contains "newer-run-other-workflow: the old cancelled fail-fast row stays judged" "$out" "$FFL"

# only a COMPLETED/CANCELLED row is dropped: a re-run of a LOWER run id (later
# startedAt, lower id) that is still running or failed must not hide behind the
# higher run id's green rows
reset_stubs
STUB_ROLLUP="$(jq -c 'map(if (.detailsUrl | contains("/runs/41005958845/")) and .name == "plan" then .startedAt = "2026-10-30T14:00:00Z" | .status = "IN_PROGRESS" | .conclusion = "" else . end)' <<< "$R4277")"
rc=0; out="$(run)" || rc=$?
check "lower-run-rerun-in-progress: exit 1" "$rc" "1"
contains "lower-run-rerun-in-progress: the running row stays judged" "$out" "plan=IN_PROGRESS"
reset_stubs
STUB_ROLLUP="$(jq -c 'map(if (.detailsUrl | contains("/runs/41005958845/")) and .name == "plan" then .startedAt = "2026-10-30T14:00:00Z" | .conclusion = "FAILURE" else . end)' <<< "$R4277")"
rc=0; out="$(run)" || rc=$?
check "lower-run-rerun-failure: exit 1" "$rc" "1"
contains "lower-run-rerun-failure: the failed row stays judged" "$out" "plan=COMPLETED/FAILURE"

# a green newer run with a narrower job set (it never re-reports lint) leaves the
# older run's FAILURE row judged
reset_stubs
STUB_ROLLUP="$(jq -c 'map(select((.detailsUrl | contains("/runs/41059698017/")) and .name == "lint" | not))' <<< "$R4277")"
rc=0; out="$(run)" || rc=$?
check "newer-run-narrower-job-set: exit 1" "$rc" "1"
contains "newer-run-narrower-job-set: the older failed lint row stays judged" "$out" "lint=COMPLETED/FAILURE"

# a detailsUrl that is not an actions job URL carries no run id: the row stays judged
reset_stubs
STUB_ROLLUP="$(jq -c 'map(if .name == "fail-fast-lint" then .detailsUrl = "https://github.com/acme/repo/actions/runs/abc/job/1" else . end)' <<< "$R4277")"
rc=0; out="$(run)" || rc=$?
check "malformed-details-url: exit 1" "$rc" "1"
contains "malformed-details-url: the cancelled fail-fast row stays judged" "$out" "$FFL"

# --- 3. check 3 fails: unresolved review threads > 0 --------------------
reset_stubs
STUB_UNRESOLVED=2
rc=0; out="$(run)" || rc=$?
check "unresolved-threads: exit 1" "$rc" "1"
contains "unresolved-threads: check 3 fails" "$out" "[FAIL] 3. unresolved review threads = 2"

# --- 3 fresh. the decision reads the PR live, never a same-head cached snapshot ---
reset_stubs
RUN_CACHE=$(mktemp -d "$tmp/cache.XXXXXX") || exit 1
STUB_UNRESOLVED=1
rc=0; run >/dev/null 2>&1 || rc=$?
check "stale-cache-thread-resolved: warm-up exit 1" "$rc" "1"
check "stale-cache-thread-resolved: warm-up cached 1 thread" "$(jq -s -r '.[0].value.reviewThreads.nodes | length' "$RUN_CACHE"/*-"$PR".json 2>/dev/null)" "1"
STUB_UNRESOLVED=0
rc=0; out="$(run)" || rc=$?
check "stale-cache-thread-resolved: exit 0" "$rc" "0"
contains "stale-cache-thread-resolved: check 3 passes" "$out" "[PASS] 3."
reset_stubs
RUN_CACHE=$(mktemp -d "$tmp/cache.XXXXXX") || exit 1
rc=0; run >/dev/null 2>&1 || rc=$?
check "stale-cache-thread-opened: warm-up exit 0" "$rc" "0"
check "stale-cache-thread-opened: warm-up cached 0 threads" "$(jq -s -r '.[0].value.reviewThreads.nodes | length' "$RUN_CACHE"/*-"$PR".json 2>/dev/null)" "0"
STUB_UNRESOLVED=1
rc=0; out="$(run)" || rc=$?
check "stale-cache-thread-opened: exit 1" "$rc" "1"
contains "stale-cache-thread-opened: check 3 fails" "$out" "[FAIL] 3. unresolved review threads = 1"
RUN_CACHE=

# --- 4. check 4 fails: no ledger row for this head ----------------------
reset_stubs
seed_ledger_missing
rc=0; out="$(run)" || rc=$?
check "no-ledger-row: exit 1" "$rc" "1"
contains "no-ledger-row: check 4 fails" "$out" "[FAIL] 4."
seed_ledger_ok

# A session-authored ok row is not evidence that a critic reviewed the head.
reset_stubs
saved_sha="$SHA"
SHA=$(git -C "$REPO" rev-parse HEAD)
for model in claude claude-floor codex-adv; do
    : > "$LEDGER"
    (cd "$REPO" && CR_LEDGER="$LEDGER" bash "$HERE/../../cr/ledger-append.sh" avail \
        --branch b --head "$SHA" --model "$model" --status ok) || exit 1
    rc=0; out="$(run)" || rc=$?
    check "$model session-avail: exit 1" "$rc" "1"
    contains "$model session-avail: check 4 fails" "$out" "[FAIL] 4."
done
SHA="$saved_sha"

for kind in finding score usage; do
    printf '{"kind":"%s","head":"%s","model":"codex","status":"ok"}\n' "$kind" "$SHA" > "$LEDGER"
    rc=0; out="$(run)" || rc=$?
    check "$kind-ok: exit 1" "$rc" "1"
    contains "$kind-ok: check 4 fails" "$out" "[FAIL] 4."
done

for kind in evidence judge-go; do
    for row_branch in feat/himmel-100-thing other-branch ''; do
        printf '{"kind":"%s","branch":"%s","head":"%s","status":"ok"}\n' "$kind" "$row_branch" "$SHA" > "$LEDGER"
        rc=0; out="$(run)" || rc=$?
        if [ "$row_branch" = feat/himmel-100-thing ]; then
            check "$kind own-branch: exit 0" "$rc" "0"
            contains "$kind own-branch: check 4 passes" "$out" "[PASS] 4."
        else
            check "$kind wrong-or-missing-branch: exit 1" "$rc" "1"
            contains "$kind wrong-or-missing-branch: check 4 fails" "$out" "[FAIL] 4."
        fi
    done
    printf '{"kind":"%s","branch":"feat/himmel-100-thing","head":"%s","status":"ok"}\n' "$kind" "$SHA" > "$LEDGER"
    STUB_PR_BRANCH=''
    rc=0; out="$(run)" || rc=$?
    check "$kind unreadable-branch: exit 1" "$rc" "1"
    contains "$kind unreadable-branch: check 4 fails" "$out" "[FAIL] 4."
    unset STUB_PR_BRANCH
done

# --- 4b. check 4 takes the audit row a signed judge GO leaves:
# kind=judge-go, status ok, source=judge:<qid>/<name>, at the exact head.
reset_stubs
printf '{"kind":"judge-go","ts":"2026-01-01T00:00:00Z","branch":"feat/himmel-100-thing","head":"%s","status":"ok","source":"judge:q1/judge"}\n' "$SHA" > "$LEDGER"
rc=0; out="$(run)" || rc=$?
check "judge-go-row: exit 0" "$rc" "0"
contains "judge-go-row: check 4 passes" "$out" "[PASS] 4. CR ledger: 1 row(s) for $SHA with status=ok"

# --- 4c. a judge-go row at a DIFFERENT head buys nothing -----------------
printf '{"kind":"judge-go","ts":"2026-01-01T00:00:00Z","branch":"b","head":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef","status":"ok","source":"judge:q1/judge"}\n' > "$LEDGER"
rc=0; out="$(run)" || rc=$?
check "judge-go-other-head: exit 1" "$rc" "1"
contains "judge-go-other-head: check 4 fails" "$out" "[FAIL] 4."

rc_reviewed=1111111111111111111111111111111111111111
carry_row() { printf '{"kind":"avail","branch":"%s","head":"%s","model":"claude","status":"ok","detail":"trivial-descendant of reviewed head %s (carried by clear-cr-marker)"}\n' "$1" "$SHA" "$rc_reviewed"; }
{ printf '{"kind":"avail","head":"%s","model":"codex","status":"ok"}\n' "$rc_reviewed"; carry_row feat/himmel-100-thing; } > "$LEDGER"
rc=0; out="$(run)" || rc=$?
check "carry-row: exit 0" "$rc" "0"
contains "carry-row: check 4 passes" "$out" "[PASS] 4."
carry_row feat/himmel-100-thing > "$LEDGER"
rc=0; out="$(run)" || rc=$?
check "carry-row-unreviewed: exit 1" "$rc" "1"
contains "carry-row-unreviewed: check 4 fails" "$out" "[FAIL] 4."
{ printf '{"kind":"avail","head":"%s","model":"codex","status":"ok"}\n' "$rc_reviewed"; carry_row other-branch; } > "$LEDGER"
rc=0; out="$(run)" || rc=$?
check "carry-row-other-branch: exit 1" "$rc" "1"
contains "carry-row-other-branch: check 4 fails" "$out" "[FAIL] 4."
seed_ledger_ok

# --- 4d. Guards for the rows the docs-audit lane leaves: its critic's row passes,
# no record or an unavailable critic fails.
reset_stubs
: > "$LEDGER"
(cd "$REPO" && CR_LEDGER="$LEDGER" bash "$HERE/../../cr/ledger-append.sh" avail \
    --branch feat/himmel-100-thing --head "$SHA" --model claude --status ok) || exit 1
(cd "$REPO" && CR_LEDGER="$LEDGER" bash "$HERE/../../cr/ledger-append.sh" avail \
    --branch feat/himmel-100-thing --head "$SHA" --model codex --status ok) || exit 1
rc=0; out="$(run)" || rc=$?
check "docs-audit critic-row: exit 0" "$rc" "0"
contains "docs-audit critic-row: check 4 passes" "$out" "[PASS] 4."

: > "$LEDGER"
rc=0; out="$(run)" || rc=$?
check "no-review-record: exit 1" "$rc" "1"
contains "no-review-record: check 4 fails" "$out" "[FAIL] 4."

# The critic out of quota leaves only the inline audit and an unavailable row.
(cd "$REPO" && CR_LEDGER="$LEDGER" bash "$HERE/../../cr/ledger-append.sh" avail \
    --branch feat/himmel-100-thing --head "$SHA" --model claude --status ok) || exit 1
(cd "$REPO" && CR_LEDGER="$LEDGER" bash "$HERE/../../cr/ledger-append.sh" avail \
    --branch feat/himmel-100-thing --head "$SHA" --model codex --status unavailable --reason rate-limit) || exit 1
rc=0; out="$(run)" || rc=$?
check "docs-audit critic-unavailable: exit 1" "$rc" "1"
contains "docs-audit critic-unavailable: check 4 fails" "$out" "[FAIL] 4."
seed_ledger_ok

# --- 5a. check 5 fails: sensitive files, no Platforms tested trailer ----
reset_stubs
STUB_COMMITS='[{"messageHeadline":"feat(x): [HIMMEL-1] add thing","messageBody":"Security reviewed: manual"},{"messageHeadline":"fix(x): [HIMMEL-2] tweak","messageBody":""}]'
rc=0; out="$(run)" || rc=$?
check "missing-platforms: exit 1" "$rc" "1"
contains "missing-platforms: check 5 fails" "$out" "missing 'Platforms tested:'"

# --- 5b. check 5 fails: non-docs files, no Security reviewed trailer ----
reset_stubs
STUB_COMMITS='[{"messageHeadline":"feat(x): [HIMMEL-1] add thing","messageBody":"Platforms tested: linux"},{"messageHeadline":"fix(x): [HIMMEL-2] tweak","messageBody":""}]'
rc=0; out="$(run)" || rc=$?
check "missing-security: exit 1" "$rc" "1"
contains "missing-security: check 5 fails" "$out" "missing 'Security reviewed:'"

# --- 5c. docs-only PR needs neither trailer ------------------------------
reset_stubs
STUB_FILES="docs/handover/running-a-chief.md"
STUB_COMMITS='[{"messageHeadline":"docs: [HIMMEL-1] note","messageBody":""}]'
rc=0; out="$(run)" || rc=$?
check "docs-only: exit 0" "$rc" "0"
contains "docs-only: check 5 passes" "$out" "[PASS] 5."

# --- 5c2. Markdown/text under scripts/ needs no Platforms ---
reset_stubs
STUB_FILES="scripts/telegram/README.md"
STUB_COMMITS='[{"messageHeadline":"docs: [HIMMEL-1] note","messageBody":""}]'
rc=0; out="$(run)" || rc=$?
check "scripts-readme-only: exit 0" "$rc" "0"
contains "scripts-readme-only: check 5 passes" "$out" "[PASS] 5."
contains "scripts-readme-only: platforms not needed" "$out" "Platforms tested (needed=0)"

reset_stubs
STUB_FILES="scripts/x/run.sh"
STUB_COMMITS='[{"messageHeadline":"fix(x): [HIMMEL-1] tweak","messageBody":"Security reviewed: manual"}]'
rc=0; out="$(run)" || rc=$?
check "scripts-sh-only: exit 1" "$rc" "1"
contains "scripts-sh-only: check 5 fails" "$out" "missing 'Platforms tested:'"

reset_stubs
STUB_FILES="scripts/telegram/README.md
scripts/x/run.sh"
STUB_COMMITS='[{"messageHeadline":"fix(x): [HIMMEL-1] tweak","messageBody":"Security reviewed: manual"}]'
rc=0; out="$(run)" || rc=$?
check "scripts-mixed: exit 1" "$rc" "1"
contains "scripts-mixed: check 5 fails" "$out" "missing 'Platforms tested:'"

# --- 5d. check 5 fails: PR files unreadable (API call failed) -----------
reset_stubs
STUB_FILES_FAIL=1
rc=0; out="$(run)" || rc=$?
check "files-unreadable: exit 1" "$rc" "1"
contains "files-unreadable: check 5 fails" "$out" "[FAIL] 5. cannot read PR files"

reset_stubs
STUB_COMMITS='[{"messageHeadline":"docs: [HIMMEL-1] note","messageBody":""},{"messageHeadline":"fix(x): [HIMMEL-2] code","messageBody":"Platforms tested: linux\nSecurity reviewed: manual"}]'
rc=0; out="$(run)" || rc=$?
check "later-commit-trailers: exit 0" "$rc" "0"
contains "later-commit-trailers: check 5 passes" "$out" "[PASS] 5."

reset_stubs
STUB_COMMITS='[{"messageHeadline":"docs: [HIMMEL-1] note","messageBody":""},{"messageHeadline":"fix(x): [HIMMEL-2] code","messageBody":""}]'
rc=0; out="$(run)" || rc=$?
check "no-trailer-anywhere: exit 1" "$rc" "1"
contains "no-trailer-anywhere: check 5 fails" "$out" "[FAIL] 5."
contains "no-trailer-anywhere: names platforms" "$out" "missing 'Platforms tested:'"
contains "no-trailer-anywhere: names security" "$out" "missing 'Security reviewed:'"

reset_stubs
M5=5555555555555555555555555555555555555555
L5=6666666666666666666666666666666666666666
STUB_MERGE_OIDS="$M5"
STUB_COMMITS='[{"oid":"'"$M5"'","messageHeadline":"chore(x): [HIMMEL-1] merge main","messageBody":"Platforms tested: linux\nSecurity reviewed: manual"},{"oid":"'"$L5"'","messageHeadline":"fix(x): [HIMMEL-2] tweak","messageBody":""}]'
rc=0; out="$(run)" || rc=$?
check "merge-only-trailer: exit 1" "$rc" "1"
contains "merge-only-trailer: check 5 fails" "$out" "[FAIL] 5."


reset_stubs
STUB_COMMITS='[{"messageHeadline":"docs: [HIMMEL-1] note","messageBody":"Platforms tested: Linux\nSecurity reviewed: Manual — x"},{"messageHeadline":"fix(x): [HIMMEL-2] code","messageBody":""}]'
rc=0; out="$(run)" || rc=$?
check "mixed-case-trailers: exit 0" "$rc" "0"
contains "mixed-case-trailers: check 5 passes" "$out" "[PASS] 5."

reset_stubs
STUB_COMMITS='[{"messageHeadline":"feat(x): [HIMMEL-1] add thing","messageBody":"Platforms tested: linux\nSecurity reviewed: outbound write is one PR comment"},{"messageHeadline":"fix(x): [HIMMEL-2] tweak","messageBody":"Security reviewed: ad-hoc — reason"}]'
rc=0; out="$(run)" || rc=$?
check "split-verdict-security: exit 0" "$rc" "0"
contains "split-verdict-security: check 5 passes" "$out" "[PASS] 5."

reset_stubs
STUB_COMMITS='[{"messageHeadline":"feat(x): [HIMMEL-1] add thing","messageBody":"Platforms tested: yes\nSecurity reviewed: ad-hoc — reason"},{"messageHeadline":"fix(x): [HIMMEL-2] tweak","messageBody":"Platforms tested: linux"}]'
rc=0; out="$(run)" || rc=$?
check "split-verdict-platforms: exit 0" "$rc" "0"
contains "split-verdict-platforms: check 5 passes" "$out" "[PASS] 5."

reset_stubs
I1=7777777777777777777777777777777777777777
I2=8888888888888888888888888888888888888888
I3=9999999999999999999999999999999999999999
STUB_MERGE_OIDS="$I2"
STUB_COMMITS='[{"oid":"'"$I1"'","messageHeadline":"feat(x): [HIMMEL-1] add thing","messageBody":"Platforms tested: linux\nSecurity reviewed: outbound write is one PR comment"},{"oid":"'"$I2"'","messageHeadline":"chore(x): [HIMMEL-1] merge main","messageBody":"Security reviewed: ad-hoc — reason"},{"oid":"'"$I3"'","messageHeadline":"fix(x): [HIMMEL-2] tweak","messageBody":""}]'
rc=0; out="$(run)" || rc=$?
check "incident-shape: exit 1" "$rc" "1"
contains "incident-shape: check 5 names security" "$out" "missing 'Security reviewed:'"

# --- 6. check 6 fails: a commit subject with no ticket ID ---------------
reset_stubs
STUB_COMMITS='[{"messageHeadline":"feat(x): [HIMMEL-1] add thing","messageBody":"Platforms tested: linux\nSecurity reviewed: manual"},{"messageHeadline":"fix(x): tweak with no ticket","messageBody":""}]'
rc=0; out="$(run)" || rc=$?
check "missing-ticket: exit 1" "$rc" "1"
contains "missing-ticket: check 6 fails" "$out" "[FAIL] 6."
contains "missing-ticket: names the offending subject" "$out" "tweak with no ticket"

reset_stubs
STUB_COMMITS='[{"messageHeadline":"feat(x): add a long subject that runs past the seventy character mark…","messageBody":"… and ends with (HIMMEL-1)\n\nPlatforms tested: linux\nSecurity reviewed: manual"}]'
rc=0; out="$(run)" || rc=$?
contains "truncated-subject: ticket in body remainder passes check 6" "$out" "[PASS] 6."

STUB_COMMITS='[{"messageHeadline":"feat(x): add a long subject that runs past the seventy character mark…","messageBody":"… and ends with no id at all\n\nPlatforms tested: linux\nSecurity reviewed: manual"}]'
rc=0; out="$(run)" || rc=$?
contains "truncated-subject: no ticket anywhere fails check 6" "$out" "[FAIL] 6."
contains "truncated-subject: FAIL names the rebuilt subject" "$out" "mark and ends with no id at all"

STUB_COMMITS='[{"messageHeadline":"feat(x): add a long subject that runs past the seventy character mark…","messageBody":""}]'
rc=0; out="$(run)" || rc=$?
contains "truncated-subject: empty body still fails check 6, never a silent pass" "$out" "[FAIL] 6."

STUB_COMMITS='[{"messageHeadline":"feat(x): a genuine subject that really ends in an ellipsis…","messageBody":"see (HIMMEL-1) in the body\n\nPlatforms tested: linux\nSecurity reviewed: manual"}]'
rc=0; out="$(run)" || rc=$?
contains "truncated-subject: a body without the continuation marker is not joined" "$out" "[FAIL] 6."

# --- 6b. a merge commit (>1 parent) is exempt from check 6,
# even though its subject carries no ticket ID -------------------------
reset_stubs
MERGE_OID=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
STUB_FILES="docs/handover/running-a-chief.md"
STUB_COMMITS='[{"oid":"'"$MERGE_OID"'","messageHeadline":"Merge remote-tracking branch '"'"'origin/main'"'"' into fix/x","messageBody":""},{"oid":"111111111111111111111111111111111111111a","messageHeadline":"fix(x): [HIMMEL-1] tweak","messageBody":""}]'
rc=0; out="$(run)" || rc=$?
check "merge-commit unexempt (no STUB_MERGE_OIDS): exit 1" "$rc" "1"
contains "merge-commit unexempt: check 6 fails at base" "$out" "[FAIL] 6."

STUB_MERGE_OIDS="$MERGE_OID"
rc=0; out="$(run)" || rc=$?
check "merge-commit exempt: exit 0" "$rc" "0"
contains "merge-commit exempt: check 6 passes" "$out" "[PASS] 6."

# --- 6c. an unticketed NON-merge commit still fails check 6 even when a
# merge commit is present elsewhere in the range ------------------------
reset_stubs
STUB_MERGE_OIDS="$MERGE_OID"
STUB_COMMITS='[{"oid":"'"$MERGE_OID"'","messageHeadline":"Merge remote-tracking branch '"'"'origin/main'"'"' into fix/x","messageBody":""},{"oid":"111111111111111111111111111111111111111a","messageHeadline":"fix(x): tweak with no ticket","messageBody":"Platforms tested: linux\nSecurity reviewed: manual"}]'
rc=0; out="$(run)" || rc=$?
check "merge-plus-unticketed: exit 1" "$rc" "1"
contains "merge-plus-unticketed: check 6 fails" "$out" "[FAIL] 6."
contains "merge-plus-unticketed: names the offending subject, not the merge" "$out" "tweak with no ticket"

# --- 6d. an EXTERNAL PR author's unkeyed commits pass check 6
# when the PR title is keyed (the squash lands the title); internal, bot,
# unkeyed-title and unreadable-input cases keep the FAIL -----------------
EXT_ALLOW="$tmp/ticket-id-internal-authors.txt"
printf '# test allowlist\nyotamleo\n' > "$EXT_ALLOW"
export TICKET_ID_INTERNAL_AUTHORS_FILE="$EXT_ALLOW"
EXT_COMMITS='[{"oid":"111111111111111111111111111111111111111a","messageHeadline":"fix(hooks): [SCRUM-1] [#4078] one","messageBody":"Platforms tested: linux\nSecurity reviewed: manual"},{"oid":"222222222222222222222222222222222222222b","messageHeadline":"fix(hooks): [SCRUM-1] [#4078] two","messageBody":""},{"oid":"333333333333333333333333333333333333333c","messageHeadline":"test(hooks): [SCRUM-1] [#4079] three","messageBody":""}]'

# (i) the 4100-shaped fixture: external author, unkeyed commits, keyed title
reset_stubs
STUB_AUTHOR=Goomal STUB_PR_TITLE='fix(hooks): [HIMMEL-100] thing' STUB_COMMITS="$EXT_COMMITS"
rc=0; out="$(run)" || rc=$?
contains "external-author keyed title: check 6 passes" "$out" "[PASS] 6."
contains "external-author keyed title: exemption line is not silent" "$out" "external contributor and the PR title carries a ticket ID"
contains "external-author keyed title: names the author" "$out" "PR author Goomal"

# (ii) same author and commits, UNKEYED title: the title is what lands
STUB_PR_TITLE='fix(hooks): a title with no ticket'
rc=0; out="$(run)" || rc=$?
contains "external-author unkeyed title: check 6 fails" "$out" "[FAIL] 6."

# (iii) the worker row: internal author, unkeyed commit, keyed title
STUB_AUTHOR=yotamleo STUB_PR_TITLE='fix(hooks): [HIMMEL-100] thing'
rc=0; out="$(run)" || rc=$?
contains "internal-author keyed title: check 6 fails" "$out" "[FAIL] 6."
contains "internal-author keyed title: names the subject" "$out" "[#4078] one"

# (iv) external author, a merge commit plus keyed commits: still passes
MERGE_OID=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
STUB_AUTHOR=Goomal STUB_MERGE_OIDS="$MERGE_OID"
STUB_COMMITS='[{"oid":"'"$MERGE_OID"'","messageHeadline":"Merge remote-tracking branch '"'"'origin/main'"'"' into fix/x","messageBody":"Platforms tested: linux\nSecurity reviewed: manual"},{"oid":"111111111111111111111111111111111111111a","messageHeadline":"fix(x): [HIMMEL-1] tweak","messageBody":""}]'
rc=0; out="$(run)" || rc=$?
contains "external-author merge + keyed: check 6 passes" "$out" "[PASS] 6. every commit subject carries a ticket ID"

# (v) fail closed: empty author, unreadable allowlist
STUB_COMMITS="$EXT_COMMITS"; unset STUB_MERGE_OIDS
rc=0; out="$(STUB_AUTHOR_EMPTY=1 run)" || rc=$?
contains "empty author: check 6 fails closed" "$out" "[FAIL] 6."
rc=0; out="$(TICKET_ID_INTERNAL_AUTHORS_FILE="$tmp/no-such-allowlist" run)" || rc=$?
contains "unreadable allowlist: check 6 fails closed" "$out" "[FAIL] 6."

# (vi) a bot author never takes the exemption
STUB_AUTHOR=dependabot
rc=0; out="$(run)" || rc=$?
contains "bot author: check 6 fails" "$out" "[FAIL] 6."
STUB_AUTHOR=app/dependabot
rc=0; out="$(run)" || rc=$?
contains "app/ bot author: check 6 fails" "$out" "[FAIL] 6."
unset TICKET_ID_INTERNAL_AUTHORS_FILE

# --- 7. ticket coverage. The PR body needs a `## Ticket coverage`
# section, one line per ask, each `done` or `deferred → <KEY>`; a deferred key
# must exist and be open. A Jira error reads UNKNOWN, never PASS. ------------
reset_stubs
rc=0; out="$(run)" || rc=$?
contains "coverage all-done: check 7 passes" "$out" "[PASS] 7."

reset_stubs
STUB_BODY='## Summary\nthing\n'
rc=0; out="$(run)" || rc=$?
check "coverage missing section: exit 1" "$rc" "1"
contains "coverage missing section: check 7 fails" "$out" "[FAIL] 7."

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n- ask two: deferred -> HIMMEL-99999\n'
rc=0; out="$(run)" || rc=$?
check "coverage deferred to nonexistent key: exit 1" "$rc" "1"
contains "coverage nonexistent key: check 7 fails" "$out" "[FAIL] 7."
contains "coverage nonexistent key: names the key" "$out" "HIMMEL-99999"

for st in 51 52 53; do
    reset_stubs
    STUB_BODY='## Ticket coverage\n- ask one: done\n- ask two: deferred \xe2\x86\x92 HIMMEL-'"$st"'\n'
    seed_deferral "HIMMEL-$st"
    rc=0; out="$(run)" || rc=$?
    check "coverage deferred to closed key HIMMEL-$st: exit 1" "$rc" "1"
    contains "coverage closed key HIMMEL-$st: check 7 fails" "$out" "[FAIL] 7."
    contains "coverage closed key HIMMEL-$st: names the closed status" "$out" "HIMMEL-$st already"
done

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n- ask two: deferred \xe2\x86\x92 HIMMEL-50\n'
seed_deferral HIMMEL-50
rc=0; out="$(run)" || rc=$?
check "coverage deferred to open key: exit 0" "$rc" "0"
contains "coverage open key: check 7 passes" "$out" "[PASS] 7."

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n- ask two: deferred -> HIMMEL-200\n'
rc=0; out="$(run)" || rc=$?
check "coverage deferred to a raw-created newer ticket: exit 1" "$rc" "1"
contains "coverage raw-created ticket: check 7 fails" "$out" "[FAIL] 7."
contains "coverage raw-created ticket: names the key and the residual verb" "$out" "HIMMEL-200 was made by a raw jira create"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n- ask two: deferred -> HIMMEL-201\n'
seed_deferral HIMMEL-201
rc=0; out="$(run)" || rc=$?
check "coverage deferred to a residual-labelled newer ticket: exit 0" "$rc" "0"
contains "coverage residual-labelled ticket: check 7 passes" "$out" "[PASS] 7."

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n- ask two: deferred -> HIMMEL-202\n'
seed_deferral HIMMEL-202
rc=0; out="$(run)" || rc=$?
check "coverage deferred to a residual-depth-only label: exit 1" "$rc" "1"
contains "coverage residual-depth-only label: names the raw-create refusal" "$out" "HIMMEL-202 was made by a raw jira create"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n- ask two: deferred -> HIMMEL-200\n'
STUB_PR_BRANCH='feat/himmel-300-later-ticket'
seed_deferral HIMMEL-200
rc=0; out="$(run)" || rc=$?
check "coverage deferred to a ticket older than the PR's own: exit 0" "$rc" "0"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n- ask two: deferred -> HIMMEL-200\n'
STUB_PR_TITLE='feat(x): [HIMMEL-300] a title that names a newer key'
rc=0; out="$(run)" || rc=$?
check "coverage: a PR title naming a newer key does not make an older raw ticket pass: exit 1" "$rc" "1"
contains "coverage title key ignored: names the raw-create refusal" "$out" "HIMMEL-200 was made by a raw jira create"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n- ask two: deferred -> HIMMEL-200\n'
STUB_PR_TITLE='feat(x): [HIMMEL-300] a title that names a newer key'
STUB_PR_BRANCH=''
seed_deferral HIMMEL-200
rc=0; out="$(run)" || rc=$?
check "coverage: an empty branch name leaves no own key, only the residual label passes: exit 1" "$rc" "1"
contains "coverage empty branch: names the raw-create refusal" "$out" "HIMMEL-200 was made by a raw jira create"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n- ask two: deferred -> HIMMEL-203\n'
rc=0; out="$(run)" || rc=$?
check "coverage: a description line reading 'Labels: residual' is not the label: exit 1" "$rc" "1"
contains "coverage fake label line: names the raw-create refusal" "$out" "HIMMEL-203 was made by a raw jira create"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n- ask two: deferred -> HIMMEL-50\n'
STUB_JIRA_DOWN=1
rc=0; out="$(run)" || rc=$?
check "coverage jira unreachable: exit 1" "$rc" "1"
contains "coverage jira unreachable: reads UNKNOWN" "$out" "UNKNOWN"
case "$out" in *"[PASS] 7."*) echo "FAIL - coverage jira unreachable: must not PASS"; fails=$((fails+1)) ;; *) echo "ok - coverage jira unreachable: no PASS" ;; esac

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n- ask two: maybe later\n'
rc=0; out="$(run)" || rc=$?
check "coverage unmarked line: exit 1" "$rc" "1"
contains "coverage unmarked line: check 7 fails" "$out" "[FAIL] 7."

reset_stubs
STUB_BODY='## Ticket coverage\n'
rc=0; out="$(run)" || rc=$?
check "coverage empty section: exit 1" "$rc" "1"

# `done` must be the line's terminal disposition, not a substring
reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: not done\n'
rc=0; out="$(run)" || rc=$?
check "coverage 'not done': exit 1" "$rc" "1"
contains "coverage 'not done': check 7 fails" "$out" "[FAIL] 7."

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done pending verification\n'
rc=0; out="$(run)" || rc=$?
check "coverage 'done pending verification': exit 1" "$rc" "1"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done.\n- ask two: **done**\n'
rc=0; out="$(run)" || rc=$?
check "coverage 'done.' / bold done: exit 0" "$rc" "0"

# a successful jira get with a blank status is UNKNOWN, never open
reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-54\n'
rc=0; out="$(run)" || rc=$?
check "coverage blank jira status: exit 1" "$rc" "1"
contains "coverage blank jira status: reads UNKNOWN" "$out" "UNKNOWN"

# a deferral must also END the line, and a delimiter-free jira reply is not a status
reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50 pending verification\n'
seed_deferral HIMMEL-50
rc=0; out="$(run)" || rc=$?
check "coverage deferral with trailing prose: exit 1" "$rc" "1"
contains "coverage deferral with trailing prose: names the unmarked line" "$out" "unmarked line"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50.\n- ask two: deferred \xe2\x86\x92 **HIMMEL-50**\n'
seed_deferral HIMMEL-50
rc=0; out="$(run)" || rc=$?
check "coverage deferral with trailing punctuation/bold: exit 0" "$rc" "0"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-55\n'
rc=0; out="$(run)" || rc=$?
check "coverage malformed jira reply: exit 1" "$rc" "1"
contains "coverage malformed jira reply: reads UNKNOWN" "$out" "UNKNOWN"


reset_stubs
rc=0; out="$(run7)" || rc=$?
check "only 7 clean body: exit 0" "$rc" "0"
contains "only 7 clean body: check 7 passes" "$out" "[PASS] 7."
contains "only 7 clean body: says PASS" "$out" "COVERAGE-LINT PASS"
notcontains "only 7 clean body: runs no other check" "$out" "[PASS] 1."

# checks 1-6 must not gate it: a head the stub does not know is irrelevant here
reset_stubs
STUB_HEAD=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef STUB_UNRESOLVED=3
rc=0; out="$(run7)" || rc=$?
check "only 7 ignores items 1-6: exit 0" "$rc" "0"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n- ask two: done pending verification\n- ask three: deferred -> HIMMEL-50 (see thread)\n'
rc=0; out="$(run7)" || rc=$?
check "only 7 trailing text: exit 1" "$rc" "1"
contains "only 7 trailing text: names the failing line" "$out" "ask two: done pending verification"
contains "only 7 trailing text: names the second failing line" "$out" "ask three: deferred -> HIMMEL-50 (see thread)"
contains "only 7 trailing text: prints the done shape" "$out" "- <ask>: done"
contains "only 7 trailing text: prints the deferred shape" "$out" "- <ask>: deferred → HIMMEL-<n>"
contains "only 7 trailing text: says marker LAST" "$out" "marker LAST"
contains "only 7 trailing text: says FAIL" "$out" "COVERAGE-LINT FAIL"

# --- 7c. (slice S4a of the in-progress drift fixes) `- <ask>: owed → chief|operator by YYYY-MM-DD` is a third accepted shape. Item 7 holds no owed
# grammar: it pipes each owed line alone to the anchor's scripts/lib/pr_remainder.py and checks only the window, today to today
# plus 14 days. Every row pins TICKET_STATUS_NOW to one epoch computed here, and every date derives from it.
O_READER="$(cd "$(dirname "$SCRIPT")/../../.." && pwd)/scripts/lib/pr_remainder.py"
o_ar='\xe2\x86\x92'
o_body() { printf '## Ticket coverage\\n- ask one: done\\n- %s\\n' "$1"; }
# the BSD `date` shim (copied from test-status-drift.sh): -d is refused, -j -f '%Y-%m-%d' rolls the day over, -r <epoch> and every other form go to the real date
o_bsdpath=$PATH
if date -u -d 2026-01-01 +%s >/dev/null 2>&1; then # gnu-ok: the probe itself, the shim below needs a GNU date
    mkdir -p "$tmp/bsd"
    cat >"$tmp/bsd/date" <<'EOS'
#!/usr/bin/env bash
real=$BSD_SHIM_REAL_DATE
orig=("$@")
j=0 r="" v="" out="" fmt="" str=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -d) echo "date: illegal option -- d" >&2; exit 1 ;;
        -j) j=1; shift ;;
        -f) fmt=${2:-}; str=${3:-}; shift 3 ;;
        -r) r=${2:-}; shift 2 ;;
        -v*) v=${1#-v-}; v=${v%d}; shift ;;
        +*) out=$1; shift ;;
        *) shift ;;
    esac
done
if [ "$j" = 1 ]; then
    case "$fmt" in
        %Y-%m-%d)
            base=$("$real" -u -d "${str:0:7}-01" +%s) || exit 1
            e=$((base + (10#${str:8:2} - 1) * 86400)) ;;
        *) e=$("$real" -u -d "$str" +%s) || exit 1 ;;
    esac
    exec "$real" -u -d "@$e" "$out"
fi
[ -z "$r" ] || exec "$real" -u -d "@$r" "$out"
[ -z "$v" ] || exec "$real" -u -d "$v days ago" "$out"
exec "$real" "${orig[@]}"
EOS
    chmod +x "$tmp/bsd/date"
    BSD_SHIM_REAL_DATE=$(command -v date)
    export BSD_SHIM_REAL_DATE
    o_bsdpath="$tmp/bsd:$PATH"
fi
o7() { # <name> <exit> <body-line> [PATH]: one owed line through --only 7 with the clock pinned
    reset_stubs
    STUB_BODY="$(o_body "$3")"
    rc=0; out="$(TICKET_STATUS_NOW=${O_NOW_ROW:-$O_NOW} PATH="${4:-$PATH}" run7)" || rc=$?
    check "$1: exit $2" "$rc" "$2"
    if [ "$2" = 0 ]; then contains "$1: says PASS" "$out" "COVERAGE-LINT PASS"; else contains "$1: says FAIL" "$out" "COVERAGE-LINT FAIL"; fi
}
o7 "9561 S4a 7c: an owed line to the operator two days out passes" 0 "live proof: owed $o_ar operator by $(o_day 2)"
o7 "9561 S4a 7c: an owed line passes under the BSD date shim (the control)" 0 "live proof: owed $o_ar operator by $(o_day 2)" "$o_bsdpath"
o7 "9561 S4a 7c: a -> arrow, chief and today itself pass" 0 "x: owed -> chief by $(o_day 0)"
o7 "9561 S4a 7c: the day 14 days out passes" 0 "x: owed $o_ar chief by $(o_day 14)"
o7 "9561 S4a 7c: a who other than chief or operator fails" 1 "x: owed $o_ar bob by $(o_day 2)"
o7 "9561 S4a 7c: no date fails" 1 "x: owed $o_ar chief"
o7 "9561 S4a 7c: an impossible month fails" 1 "x: owed $o_ar chief by 2026-13-40"
o7 "9561 S4a 7c: 2026-02-30 fails" 1 "x: owed $o_ar chief by 2026-02-30"
o7 "9561 S4a 7c: 2026-02-30 fails under the BSD date shim" 1 "x: owed $o_ar chief by 2026-02-30" "$o_bsdpath"
o7 "9561 S4a 7c: yesterday fails" 1 "x: owed $o_ar chief by $(o_day -1)"
o7 "9561 S4a 7c: 15 days out fails" 1 "x: owed $o_ar chief by $(o_day 15)"
o7 "9561 S4a 7c: 15 days out fails under the BSD date shim" 1 "x: owed $o_ar chief by $(o_day 15)" "$o_bsdpath"
contains "9561 S4a 7c: a failing owed line prints the owed shape" "$out" "owed → chief|operator|proof by YYYY-MM-DD"
# item 7 never reads TICKET_STATUS_AWAIT_MAX: the window is a fixed 14 days
TICKET_STATUS_AWAIT_MAX=7d o7 "9561 S4a 7c: AWAIT_MAX=7d does not shrink the window (10 days out passes)" 0 "x: owed $o_ar chief by $(o_day 10)"
TICKET_STATUS_AWAIT_MAX=30d o7 "9561 S4a 7c: AWAIT_MAX=30d does not widen the window (15 days out fails)" 1 "x: owed $o_ar chief by $(o_day 15)"
# the seam: the clock 20 days back makes real today + 2 more than 14 days out
O_NOW_ROW=$((O_NOW - 20 * 86400)) o7 "9561 S4a 7c: item 7 reads TICKET_STATUS_NOW, not the wall clock" 1 "x: owed $o_ar chief by $(o_day 2)"
O_NOW_ROW=$((O_NOW - 20 * 86400)) o7 "9561 S4a 7c: the seam row's control: a date inside the seam window passes" 0 "x: owed $o_ar chief by $(o_day -19)"
O_NOW_ROW="0$O_NOW" o7 "9561 S4a 7c: a clock with a leading zero is read as decimal, so a date 20 days out still fails" 1 "x: owed $o_ar chief by $(o_day 20)"
O_NOW_ROW="0$O_NOW" o7 "9561 S4a 7c: a clock with a leading zero is read as decimal, so a date 2 days out passes" 0 "x: owed $o_ar chief by $(o_day 2)"
# a date that prints no epoch leaves item 7 no clock: it fails closed instead of skipping the check
mkdir -p "$tmp/nodate"
printf '#!/usr/bin/env bash\ncase "$*" in *+%%s*) exit 0 ;; esac\nexec %s "$@"\n' "$(command -v date)" > "$tmp/nodate/date"
chmod +x "$tmp/nodate/date"
O_NOW_ROW=x o7 "9561 S4a 7c: a date that prints no epoch fails item 7 closed" 1 "x: owed $o_ar chief by $(o_day 2)" "$tmp/nodate:$PATH"
contains "9561 S4a 7c: the no-epoch failure says the window cannot be computed" "$out" "cannot compute the owed window"
# agreement (spec S5-1): item 7 decides an owed line's shape only by what the reader says of that line alone
o_d=$(o_day 3)
for o_pair in "owed $o_ar operator by $o_d|operator" "owed -> operator by $o_d|operator" "owed  $o_ar  operator  by  $o_d|operator" \
    "owed $o_ar\\toperator by $o_d|operator" "OWED $o_ar Operator By $o_d|operator" "Owed->chief by $o_d|chief"; do
    o_line=${o_pair%|*}; o_who=${o_pair##*|}
    o7 "9561 S4a 7c agree: item 7 accepts '$o_line'" 0 "x: $o_line"
    o_ans=$(printf '%b' "$(o_body "$o_line")" | python3 -I "$O_READER" HIMMEL-100)
    case "$o_ans" in owed$'\t'"$o_who"$'\t'"$o_d"$'\t'*) o_said=ok ;; *) o_said="$o_ans" ;; esac
    check "9561 S4a 7c agree: the reader reads '$o_line' as owed<TAB>$o_who<TAB>$o_d" "$o_said" ok
done
for o_pair in "owed $o_ar bob by $o_d|remaining" "owed $o_ar chief by 2026-02-30|remaining" "owed chief by $o_d|none"; do
    o_line=${o_pair%|*}; o_kind=${o_pair##*|}
    o7 "9561 S4a 7c agree: item 7 refuses '$o_line'" 1 "x: $o_line"
    o_ans=$(printf '%b' "$(o_body "$o_line")" | python3 -I "$O_READER" HIMMEL-100)
    case "$o_ans" in "$o_kind"|"$o_kind"$'\t'*) o_said=ok ;; *) o_said="$o_ans" ;; esac
    check "9561 S4a 7c agree: the reader reads '$o_line' as $o_kind, never owed" "$o_said" ok
done

o7raw() { # <name> <exit> <body escapes>: a whole body, one line a section the awk cuts away from the owed line
    reset_stubs
    STUB_BODY="$3"
    rc=0; out="$(TICKET_STATUS_NOW=$O_NOW run7)" || rc=$?
    check "$1: exit $2" "$rc" "$2"
    if [ "$2" = 0 ]; then contains "$1: says PASS" "$out" "COVERAGE-LINT PASS"; else contains "$1: says FAIL" "$out" "COVERAGE-LINT FAIL"; fi
}
o7raw "9561 S4a 7c: an owed line in a second coverage section is window-checked (2099 fails)" 1 "## Ticket coverage\\n- ask one: done\\n## Notes\\nx\\n## Ticket coverage\\n- b: owed $o_ar chief by 2099-01-01\\n"
o7raw "9561 S4a 7c: an owed line behind a form feed is window-checked (2099 fails)" 1 "## Ticket coverage\\n- ask one: done\\n## Notes\\n## x\\f## Ticket coverage\\f- b: owed $o_ar chief by 2099-01-01\\n"
o7raw "9561 S4a 7c: a second coverage section's owed line inside the window passes" 0 "## Ticket coverage\\n- ask one: done\\n## Notes\\nx\\n## Ticket coverage\\n- b: owed $o_ar chief by $(o_day 2)\\n"
o7raw "9561 S4a 7c: a second-section deferral to the branch's own key does not hide a 2000 owed line" 1 "## Ticket coverage\\n- ask one: owed $o_ar chief by $(o_day 2)\\n## Notes\\n## Ticket coverage\\n- y: deferred $o_ar HIMMEL-100\\n- z: owed $o_ar chief by 2000-01-01\\n"

o_cnt() { printf '%s' "$out" | grep -oF -e "$1" | wc -l | tr -d ' '; }
o_d2=$(o_day 2); o_d30=$(o_day 30); o_d31=$(o_day 31); o_past=$(o_day -3)
o_judge="## Ticket coverage\\n- a: done\\n- sign the spec: owed $o_ar chief by $o_d2\\n"
o7raw "10656 R1: a + proof line 30 days out beside an in-window chief line fails" 1 "${o_judge}+ run the live proof: owed $o_ar proof by $o_d30\\n"
contains "10656 R1: names the 30-day date" "$out" "owed date $o_d30 is outside the window"
contains "10656 R1: names the 30-day line" "$out" "run the live proof"
o7raw "10656 R2: a second section's proof line 30 days out beside an in-window chief line fails" 1 "${o_judge}## Notes\\nx\\n## Ticket coverage\\n- run the live proof: owed $o_ar proof by $o_d30\\n"
contains "10656 R2: names the 30-day line" "$out" "owed date $o_d30 is outside the window"
o7raw "10656 R3: the judge's body, a past-dated + proof line, fails" 1 "${o_judge}+ run the live proof: owed $o_ar proof by $o_past\\n"
contains "10656 R3: names the past date" "$out" "owed date $o_past is outside the window"
o7raw "10656 R4: an owed line after an indented heading is window-checked" 1 "## Ticket coverage\\n- a: done\\n  ## Notes\\n- x: owed $o_ar proof by $o_d30\\n"
contains "10656 R4: names the 30-day line" "$out" "owed date $o_d30 is outside the window"
o7raw "10656 R5: the judge's body with its chief line 30 days out fails" 1 "## Ticket coverage\\n- a: done\\n- sign the spec: owed $o_ar chief by $o_d30\\n+ run the live proof: owed $o_ar proof by $o_past\\n"
check "10656 R5: the 30-day line is reported once" "$(o_cnt "owed date $o_d30 is outside")" "1"
check "10656 R5: the past line is reported once" "$(o_cnt "owed date $o_past is outside")" "1"
o7raw "10656 R6: two owed lines with tabs in their asks fail" 1 "## Ticket coverage\\n- a: done\\n- a\\tb: owed $o_ar proof by $o_d30\\n- c\\t\\td: owed $o_ar proof by $o_d31\\n"
check "10656 R6: the 30-day line is reported once" "$(o_cnt "owed date $o_d30 is outside")" "1"
check "10656 R6: the 31-day line is reported once" "$(o_cnt "owed date $o_d31 is outside")" "1"
o_long=$(printf 'l%.0s' $(seq 1 170))
o7raw "10656 R7: an owed line over 160 characters with a tab in its ask fails" 1 "## Ticket coverage\\n- a: done\\n- long\\t$o_long: owed $o_ar proof by $o_d30\\n"
check "10656 R7: the long line is reported once" "$(o_cnt "owed date $o_d30 is outside")" "1"
o7raw "10656 E1: a + done line passes" 0 "## Ticket coverage\\n- a: done\\n+ x: done\\n"
o7raw "10656 E2: a + not done line fails as unmarked" 1 "## Ticket coverage\\n- a: done\\n+ x: not done\\n"
contains "10656 E2: names the unmarked line" "$out" "unmarked line: + x: not done"
o7raw "10656 E3: a + deferral to a Done key fails" 1 "## Ticket coverage\\n- a: done\\n+ x: deferred $o_ar HIMMEL-51\\n"
contains "10656 E3: names the Done key" "$out" "HIMMEL-51 already Done"
o7raw "10656 F1a: a body whose only owed line is invalid fails on that line alone" 1 "## Ticket coverage\\n- a: done\\n- x: owed $o_ar bob by $o_d2\\n"
contains "10656 F1a: says the owed line is not accepted" "$out" "owed line is not accepted"
notcontains "10656 F1a: no whole-body read failure" "$out" "cannot read the body's owed line"
o7raw "10656 F1b: owed prose outside the coverage section passes" 0 "## Summary\\nowed $o_ar chief by 2000-01-01\\n\\n## Ticket coverage\\n- a: done\\n"

# the full run prints the same shape message on the same failure
reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done pending verification\n'
rc=0; out="$(run)" || rc=$?
contains "full run trailing text: prints the accepted shape" "$out" "- <ask>: done"

rc=0; out="$(cd "$REPO" && HIMMEL_REPO="$REPO" bash "$SCRIPT" --only 6 "$PR" 2>&1)" || rc=$?
check "only 6 refused: exit 2" "$rc" "2"

# --- 7c. the CR ledger's deferred_to rows for the PR head must agree with the
# body's coverage deferrals, and a deferral target the PR's own ticket links to
# is accepted without a residual label. ------------------------------------
reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n- ask two: deferred -> HIMMEL-200\n'
seed_deferral HIMMEL-200
printf 'HIMMEL-100\tHIMMEL-200\n' > "$tmp/links.db"; STUB_LINKS_DB="$tmp/links.db"
rc=0; out="$(run)" || rc=$?
check "links: a linked, higher-numbered, unlabelled target passes: exit 0" "$rc" "0"
contains "links: linked target: check 7 passes" "$out" "[PASS] 7."

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n- ask two: deferred -> HIMMEL-200\n'
seed_deferral HIMMEL-200
printf 'HIMMEL-200\tHIMMEL-100\n' > "$tmp/links.db"; STUB_LINKS_DB="$tmp/links.db"
rc=0; out="$(run)" || rc=$?
check "links: the link counts in the other direction: exit 0" "$rc" "0"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n- ask two: deferred -> HIMMEL-200\n'
seed_deferral HIMMEL-200
rc=0; out="$(run)" || rc=$?
check "links: an unlinked, higher-numbered, unlabelled target is still refused: exit 1" "$rc" "1"
contains "links: unlinked target: names the raw-create refusal" "$out" "HIMMEL-200 was made by a raw jira create"
contains "links: unlinked target: hint offers linking a plain ticket" "$out" "jira link HIMMEL-100 HIMMEL-200"
contains "links: unlinked target: hint names only the filed classes" "$out" "--fu-class escape|hardening"
notcontains "links: unlinked target: hint no longer offers --fu-class <c>" "$out" "--fu-class <c>"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n- ask two: deferred -> HIMMEL-200\n'
seed_deferral HIMMEL-200
printf 'HIMMEL-300\tHIMMEL-200\n' > "$tmp/links.db"; STUB_LINKS_DB="$tmp/links.db"
rc=0; out="$(run)" || rc=$?
check "links: a link from some other ticket does not count: exit 1" "$rc" "1"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n- ask two: deferred -> HIMMEL-200\n'
seed_deferral HIMMEL-200
printf 'HIMMEL-100\tHIMMEL-2000\n' > "$tmp/links.db"; STUB_LINKS_DB="$tmp/links.db"
rc=0; out="$(run)" || rc=$?
check "links: a link to a key sharing the target's prefix does not count: exit 1" "$rc" "1"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n- ask two: deferred -> HIMMEL-51\n'
seed_deferral HIMMEL-51
printf 'HIMMEL-100\tHIMMEL-51\n' > "$tmp/links.db"; STUB_LINKS_DB="$tmp/links.db"
rc=0; out="$(run)" || rc=$?
check "links: a linked but Done target is still refused: exit 1" "$rc" "1"
contains "links: linked Done target: names the status" "$out" "HIMMEL-51 already Done"

s2() {
    reset_stubs
    STUB_BODY="$3"
    if [ "$4" != - ]; then printf '%b' "$4" > "$tmp/links.db"; STUB_LINKS_DB="$tmp/links.db"; fi
    [ "$5" = - ] || seed_deferral "$5"
    STUB_LINKS_FAIL="${6:-}"
    rc=0; out="$(run)" || rc=$?
    check "$1: exit $2" "$rc" "$2"
}
s2 "10657 G1: an open unlabelled key linked from the PR's ticket needs no ledger row" 0 '## Ticket coverage\n- a: done\n- b: deferred -> HIMMEL-200\n' 'HIMMEL-100\tHIMMEL-200\n' -
contains "10657 G1: check 7 passes" "$out" "[PASS] 7."
s2 "10657 G2: an open residual key linked from the PR's ticket needs no ledger row" 0 '## Ticket coverage\n- a: done\n- b: deferred -> HIMMEL-201\n' 'HIMMEL-100\tHIMMEL-201\n' -
contains "10657 G2: check 7 passes" "$out" "[PASS] 7."
s2 "10657 G3: an open older key linked from the PR's ticket needs no ledger row" 0 '## Ticket coverage\n- a: done\n- b: deferred -> HIMMEL-50\n' 'HIMMEL-100\tHIMMEL-50\n' -
contains "10657 G3: check 7 passes" "$out" "[PASS] 7."
s2 "10657 C1: a linked Done key fails" 1 '## Ticket coverage\n- a: done\n- b: deferred -> HIMMEL-51\n' 'HIMMEL-100\tHIMMEL-51\n' -
contains "10657 C1: names the status" "$out" "HIMMEL-51 already Done"
notcontains "10657 C1: no second message" "$out" "has no deferred_to row"
s2 "10657 C2: an unlinked unlabelled newer key fails" 1 '## Ticket coverage\n- a: done\n- b: deferred -> HIMMEL-200\n' - -
contains "10657 C2: names the raw-create refusal" "$out" "HIMMEL-200 was made by a raw jira create"
notcontains "10657 C2: no second message" "$out" "has no deferred_to row"
s2 "10657 C3: the PR's own key fails" 1 '## Ticket coverage\n- a: done\n- b: deferred -> HIMMEL-100\n' 'HIMMEL-100\tHIMMEL-100\n' -
contains "10657 C3: names the own ticket" "$out" "HIMMEL-100 is the PR's own ticket"
notcontains "10657 C3: no second message" "$out" "has no deferred_to row"
s2 "10657 C4: an unlinked older key with no ledger row fails" 1 '## Ticket coverage\n- a: done\n- b: deferred -> HIMMEL-50\n' - -
contains "10657 C4: names the missing row" "$out" "HIMMEL-50 is deferred in the body but has no deferred_to row"
s2 "10657 C5: a links failure for an older key with no ledger row fails closed" 1 '## Ticket coverage\n- a: done\n- b: deferred -> HIMMEL-50\n' - - 1
contains "10657 C5: says UNKNOWN" "$out" "HIMMEL-50 UNKNOWN (jira links failed for HIMMEL-100"
check "10657 C5: the UNKNOWN is printed once" "$(o_cnt "HIMMEL-50 UNKNOWN (jira links failed")" "1"
notcontains "10657 C5: no missing-row message" "$out" "HIMMEL-50 is deferred in the body"
s2 "10657 C6: a non-strict deferral to a linked key fails as unmarked" 1 '## Ticket coverage\n- a: done\n- b: deferred -> HIMMEL-200 (later)\n' 'HIMMEL-100\tHIMMEL-200\n' -
contains "10657 C6: names the unmarked line" "$out" "unmarked line: - b: deferred -> HIMMEL-200 (later)"
s2 "10657 C7: an unlinked residual key with no ledger row fails" 1 '## Ticket coverage\n- a: done\n- b: deferred -> HIMMEL-201\n' - -
contains "10657 C7: names the missing row" "$out" "HIMMEL-201 is deferred in the body but has no deferred_to row"
contains "10657 C7: names the link to make" "$out" "jira link HIMMEL-100 HIMMEL-201"
s2 "10657 C8: a links failure for a newer key with no ledger row fails" 1 '## Ticket coverage\n- a: done\n- b: deferred -> HIMMEL-200\n' - - 1
check "10657 C8: the UNKNOWN is printed once" "$(o_cnt "HIMMEL-200 UNKNOWN (jira links failed")" "1"
s2_n=$(o_cnt "HIMMEL-200 is deferred in the body")
check "10657 C8: no missing-row message" "$s2_n" "0"
s2 "10657 O1: a ledger-backed older key passes with links failing" 0 '## Ticket coverage\n- a: done\n- b: deferred -> HIMMEL-50\n' - HIMMEL-50 1
contains "10657 O1: check 7 passes" "$out" "[PASS] 7."
s2 "10657 O2: an older key on two lines with no ledger row fails" 1 '## Ticket coverage\n- a: deferred -> HIMMEL-50\n- b: deferred -> HIMMEL-50\n' - -
s2_n=$(o_cnt "HIMMEL-50 is deferred in the body")
check "10657 O2: the missing row is reported once" "$s2_n" "1"
cat > "$tmp/jira-count" <<EOS
#!/usr/bin/env bash
printf '%s %s\n' "\$1" "\${2:-}" >> "$tmp/jira-calls.log"
exec "$tmp/bin/jira-stub" "\$@"
EOS
chmod +x "$tmp/jira-count"
: > "$tmp/jira-calls.log"
RUN_JIRA_CMD="$tmp/jira-count" s2 "10657 L1: a linked newer key on two lines passes" 0 '## Ticket coverage\n- a: deferred -> HIMMEL-200\n- b: deferred -> HIMMEL-200\n' 'HIMMEL-100\tHIMMEL-200\n' -
check "10657 L1: one links call per line and none more" "$(grep -c '^links ' "$tmp/jira-calls.log")" "2"
: > "$tmp/jira-calls.log"
RUN_JIRA_CMD="$tmp/jira-count" s2 "10657 L2: a linked older key on two lines passes" 0 '## Ticket coverage\n- a: deferred -> HIMMEL-50\n- b: deferred -> HIMMEL-50\n' 'HIMMEL-100\tHIMMEL-50\n' -
check "10657 L2: one links call for the key" "$(grep -c '^links ' "$tmp/jira-calls.log")" "1"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n- ask two: done\n'
seed_deferral HIMMEL-50
rc=0; out="$(run)" || rc=$?
check "ledger: a ledger deferral absent from the body: exit 1" "$rc" "1"
contains "ledger: absent from body: names the key" "$out" "HIMMEL-50 is deferred in the CR ledger"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n- ask two: deferred -> HIMMEL-50\n'
rc=0; out="$(run)" || rc=$?
check "ledger: a body deferral with no ledger row: exit 1" "$rc" "1"
contains "ledger: no row: names the key" "$out" "HIMMEL-50 is deferred in the body but has no deferred_to row"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n- ask two: deferred -> HIMMEL-201\n- ask three: deferred -> HIMMEL-50\n- ask four: done\n'
seed_deferral HIMMEL-201; seed_deferral HIMMEL-50
rc=0; out="$(run)" || rc=$?
check "ledger: matching sets pass: exit 0" "$rc" "0"
contains "ledger: matching sets: check 7 passes" "$out" "[PASS] 7."

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50 deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
rc=0; out="$(run)" || rc=$?
check "ledger: a deferral recorded at another head does not count: exit 1" "$rc" "1"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50 "${SHA:0:12}"
rc=0; out="$(run)" || rc=$?
check "ledger: an abbreviated head spelling matches: exit 0" "$rc" "0"

REVHEAD=cafebabecafebabecafebabecafebabecafebabe
SEED_BRANCH=feat/himmel-100-thing

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50 "$REVHEAD"; seed_descendant "$REVHEAD"
rc=0; out="$(run)" || rc=$?
check "descendant: a deferral at the reviewed head counts at a trivial-descendant PR head: exit 0" "$rc" "0"
contains "descendant: reviewed-head deferral: check 7 passes" "$out" "[PASS] 7."

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n'
seed_deferral HIMMEL-50 "$REVHEAD"; seed_descendant "$REVHEAD"
rc=0; out="$(run)" || rc=$?
check "descendant: a reviewed-head deferral absent from the body: exit 1" "$rc" "1"
contains "descendant: absent from body: names the key" "$out" "HIMMEL-50 is deferred in the CR ledger"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50 "$REVHEAD"; seed_descendant "$REVHEAD" other
rc=0; out="$(run)" || rc=$?
check "descendant: a descendant row of another branch does not reach the deferral: exit 1" "$rc" "1"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
SEED_BRANCH=b seed_deferral HIMMEL-50 "$REVHEAD"; SEED_BRANCH=b seed_descendant "$REVHEAD"
rc=0; out="$(run)" || rc=$?
check "descendant: a descendant row of a branch other than the PR's does not count, though the finding shares it: exit 1" "$rc" "1"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
SEED_BRANCH=other seed_deferral HIMMEL-50 "$REVHEAD"; seed_descendant "$REVHEAD"
rc=0; out="$(run)" || rc=$?
check "descendant: a finding of another branch at the reviewed head does not count through the PR branch's row: exit 1" "$rc" "1"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50 deadbeefdeadbeefdeadbeefdeadbeefdeadbeef; seed_descendant "$REVHEAD"
rc=0; out="$(run)" || rc=$?
check "descendant: a deferral at a head the descendant row does not name does not count: exit 1" "$rc" "1"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50 "$REVHEAD"
rc=0; out="$(run)" || rc=$?
check "descendant: no trivial-descendant row, the reviewed-head deferral does not count: exit 1" "$rc" "1"
contains "descendant: no row: names the key" "$out" "HIMMEL-50 is deferred in the body but has no deferred_to row"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
printf '{"kind":"finding","ts":"t","branch":"%s","head":"%s","model":"codex","finding_id":"codex-9","severity":"sug","verdict":"agreed","artifact":"diff","perspective":"off"}\n{"kind":"amend","ts":"t","branch":"%s","target_head":"%s","finding_id":"codex-9","artifact":"diff","perspective":"off","set":{"verdict":"deferred","deferred_to":"HIMMEL-50","fu_class":"polish"}}\n' "$SEED_BRANCH" "$REVHEAD" "$SEED_BRANCH" "$REVHEAD" >> "$LEDGER"
seed_descendant "$REVHEAD"
rc=0; out="$(run)" || rc=$?
check "descendant: an amend-made deferral at the reviewed head counts: exit 0" "$rc" "0"

TS_ROOT="$tmp/ts-handovers"; TS_CACHE="$tmp/ts-cache"
TS_STEM="HIMMEL-100-N100-thing-2026-11-24"
TS_DOC="$TS_ROOT/u/himmel/$TS_STEM.md"; TS_LOG="$TS_CACHE/launch-logs/$TS_STEM.log"
mkdir -p "$TS_ROOT/u/himmel" "$TS_CACHE/launch-logs"
ts_fixture() {
    printf '# brief\n\n## Results (newest at the bottom)\n- 10:00 LIVE — started\n' > "$TS_DOC"
    printf 'headed-arm-worker: profile=worker-impl lane=native model=m role=worker session=%s launched=2026-11-24T10:00:00Z\n' "$TS_STEM" > "$TS_LOG"
}
cat > "$tmp/bin/jira-comments-stub" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "comments" ] && [ "${3:-}" = "--json" ]; then
    [ -z "${STUB_COMMENTS_FAIL:-}" ] || { echo "jira: comments HIMMEL-100 failed: HTTP 500" >&2; exit 1; }
    printf '%s' "${STUB_COMMENTS:-[]}"
    exit 0
fi
exec "$STUB_JIRA_BASE" "$@"
STUB
chmod +x "$tmp/bin/jira-comments-stub"
ts_run() {
    rc=0
    out="$(
        export HANDOVER_DIR="$TS_ROOT" HIMMELCTL_CACHE_DIR="$TS_CACHE" STUB_JIRA_BASE="$tmp/bin/jira-stub" STUB_COMMENTS="$1" STUB_COMMENTS_FAIL="${TS_FAIL:-}"
        RUN_JIRA_CMD="$tmp/bin/jira-comments-stub" run
    )" || rc=$?
}
TS_NEW='[{"id":"10001","created":"2026-11-24T12:30:00.000+0100","author":"Yotam","body":"steer: widen the Writes"}]'
TS_OLD='[{"id":"10002","created":"2026-11-24T10:30:00.000+0100","author":"Yotam","body":"older steer"}]'
TS_MACHINE='[{"id":"10003","created":"2026-11-24T12:30:00.000+0100","author":"Yotam","body":"WORKER N100 (live)\nPRs: none"},{"id":"10004","created":"2026-11-24T12:31:00.000+0100","author":"Yotam","body":"[release-ruling R-1] RULING audit copy"}]'

reset_stubs; ts_fixture
ts_run "$TS_NEW"
check "21: a comment newer than the launch with no TICKET-SEEN line: exit 1" "$rc" "1"
contains "21: it names the comment id" "$out" "[FAIL] 21."
contains "21: it quotes the comment" "$out" "steer: widen the Writes"
contains "21: it names the doc to put the line in" "$out" "$TS_DOC"

reset_stubs; ts_fixture
printf -- '- 12:00 LIVE — TICKET-SEEN 10001 widened Writes\n' >> "$TS_DOC"
ts_run "$TS_NEW"
check "21: the same comment with its TICKET-SEEN line: exit 0" "$rc" "0"
contains "21: the same comment with its TICKET-SEEN line passes" "$out" "[PASS] 21."

reset_stubs; ts_fixture
ts_run '[{"id":"10005","created":"2026-11-24T12:30:00.000+0100","author":"","body":"steer without an author"}]'
contains "21: a comment with no author still prints its text, not a shifted field" "$out" "by unknown at 2026-11-24T12:30:00.000+0100"
contains "21: a comment with no author keeps its quoted text" "$out" "\"steer without an author\""

reset_stubs; ts_fixture
printf -- '- 12:00 LIVE — TICKET-SEEN 99999 some other comment\n' >> "$TS_DOC"
ts_run "$TS_NEW"
check "21: a TICKET-SEEN line for another id does not acknowledge it: exit 1" "$rc" "1"

reset_stubs; ts_fixture
ts_run "$TS_OLD"
check "21: a comment older than the launch needs no line: exit 0" "$rc" "0"
contains "21: a comment older than the launch passes" "$out" "[PASS] 21."

reset_stubs; ts_fixture
ts_run "$TS_MACHINE"
check "21: a worker status comment and a release-ruling audit copy need no line: exit 0" "$rc" "0"

reset_stubs; ts_fixture; rm -f "$TS_LOG"
ts_run "$TS_NEW"
check "21: no launch record says so and does not fail on that alone: exit 0" "$rc" "0"
contains "21: no launch record is a WARN naming it" "$out" "[WARN] 21."
contains "21: no launch record is named" "$out" "no launch record"

reset_stubs; ts_fixture; rm -f "$TS_DOC"
ts_run "$TS_NEW"
check "21: no worker doc says so and does not fail on that alone: exit 0" "$rc" "0"
contains "21: no worker doc is a WARN naming it" "$out" "no worker handover doc"

reset_stubs; ts_fixture
STUB_PR_TITLE="chore: a title with no key"
ts_run "$TS_NEW"
contains "21: no ticket key in the title says so" "$out" "[WARN] 21. ticket comments not checked"
notcontains "21: no ticket key in the title never fails check 21" "$out" "[FAIL] 21."

reset_stubs; ts_fixture
TS_FAIL=1 ts_run "$TS_NEW"
check "21: an unreadable comment list does not fail the run on its own: exit 0" "$rc" "0"
contains "21: an unreadable comment list is a WARN" "$out" "[WARN] 21."

reset_stubs; ts_fixture
RUN_MODE=only7 ts_run "$TS_NEW"
check "21: --only 7 runs it too, so a worker sees it before READY: exit 1" "$rc" "1"
contains "21: --only 7 prints the FAIL" "$out" "[FAIL] 21."
contains "21: --only 7 ends COVERAGE-LINT FAIL" "$out" "COVERAGE-LINT FAIL"
reset_stubs; ts_fixture
printf -- '- 12:00 LIVE — TICKET-SEEN 10001 widened Writes\n' >> "$TS_DOC"
RUN_MODE=only7 ts_run "$TS_NEW"
check "21: --only 7 with the TICKET-SEEN line: exit 0" "$rc" "0"
contains "21: --only 7 with the TICKET-SEEN line ends COVERAGE-LINT PASS" "$out" "COVERAGE-LINT PASS"
unset RUN_MODE


echo "---"
if [ "$fails" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
else
    echo "$fails FAILED"
    exit 1
fi
