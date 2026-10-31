#!/usr/bin/env bash
# scripts/handover/chief-kit/test-ready-check.sh — suite for ready-check.sh
# `gh` is a PATH stub (contract requirement — not GH_CMD, even
# though the script also honors that override); `jq` and `git` are real.
#
# Covers: usage (arg count / bad PR / bad sha), one all-green PR, and one
# failing case per check (1..6).
#
# Platform guard: POSIX bash 3.2+.
# shellcheck disable=SC2015  # A && B || C is intentional in check()/contains(), as in test-go.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/ready-check.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/ready-check-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd)"
fails=0
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }
check()    { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains() { grepq "$2" -F -e "$3" && echo "ok - $1" || { echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)); }; }
notcontains() { grepq "$2" -F -e "$3" && { echo "FAIL - $1: output contains [$3]"; fails=$((fails+1)); } || echo "ok - $1"; }

SHA=0123456789abcdef0123456789abcdef01234567
PR=77
NWO=acme/repo

# ── a throwaway git repo, since check 4 resolves the ledger via
# `git rev-parse --git-common-dir` from the caller's cwd ──────────────────
REPO="$tmp/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name tester
git -C "$REPO" commit -q --allow-empty -m "chore: init"
LEDGER="$REPO/.git/cr-critic-scores.jsonl"

# ── gh PATH stub ─────────────────────────────────────────────────────────
mkdir -p "$tmp/bin"
GH_LOG="$tmp/gh.log"
export GH_PR_SNAPSHOT_CACHE_DIR="$tmp/snapshot-cache"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
args="$*"
case "$args" in
    "repo view --json owner,name"*)
        [ -z "${STUB_DEFAULT_BRANCH_FAIL:-}" ] || { printf '%s\n' "${STUB_NWO:-acme/repo}"; exit 0; }
        printf '%s main\n' "${STUB_NWO:-acme/repo}" ;;
    *"--json headRefOid,mergeStateStatus"*)
        printf '%s %s\n' "${STUB_HEAD:-}" "${STUB_MSS:-CLEAN}" ;;
    *"--json headRefOid --jq"*)
        printf '%s\n' "${STUB_HEAD:-}" ;;
    *"--json statusCheckRollup"*)
        printf '%s' "${STUB_ROLLUP:-[]}" ;;
    *"--json commits"*)
        printf '%s' "${STUB_COMMITS:-[]}" ;;
    *"--json body"*)
        printf '%b' "${STUB_BODY:-}${STUB_RED:-}" ;;
    *"--json title"*)
        printf '%s' "${STUB_PR_TITLE:-feat(x): [HIMMEL-100] thing}" ;;
    *"--json headRefName"*)
        printf '%s' "${STUB_PR_BRANCH-feat/himmel-100-thing}" ;;
    *"--json author"*)
        printf '%s\n' "${STUB_AUTHOR:-yotamleo}" ;;
    *"contents/scripts/ci/ci-trust-paths.txt"*)
        [ -z "${STUB_TRUST_LIST_FAIL:-}" ] || { echo "boom" >&2; exit 1; }
        cat "$STUB_TRUST_LIST_FILE" ;;
    "api repos/"*"/pulls/"*"/files --paginate"*)
        printf '%s\n' "${STUB_FILES:-README.md}" | while IFS= read -r f; do printf '%s\t\n' "$f"; done ;;
    "api repos/"*"/pulls/"*"changed_files"*)
        printf '%s|%s\n' "${STUB_HEAD:-}" "$(printf '%s\n' "${STUB_FILES:-README.md}" | wc -l | tr -d ' ')" ;;
    'api repos/'*'/pulls/'*) printf '%s\n' "${STUB_HEAD:-}" ;;
    *'p77:pullRequest'*)
        [ -z "${STUB_SNAPSHOT_FAIL:-}" ] || exit 1
        jq -n --arg h "$STUB_HEAD" --arg m "${STUB_MSS:-CLEAN}" \
            --argjson rollup "${STUB_ROLLUP:-[]}" --argjson commits "${STUB_COMMITS:-[]}" \
            --arg merges "${STUB_MERGE_OIDS:-}" --argjson u "${STUB_UNRESOLVED:-0}" \
            --arg body "$(printf '%b' "${STUB_BODY:-}${STUB_RED:-}")" '
            {data:{repository:{p77:{number:77,headRefOid:$h,headRefName:env.STUB_PR_BRANCH,mergeStateStatus:$m,reviewDecision:null,body:$body,
                commits:{nodes:[$commits[] | . as $commit | {commit:(. + {oid:(.oid // $h),parents:{totalCount:(if (($merges|split("\n")) | index($commit.oid // "")) != null then 2 else 1 end)}})}],pageInfo:{hasNextPage:false,endCursor:null}},
                reviewThreads:{nodes:[range($u)|{isResolved:false}],pageInfo:{hasNextPage:false,endCursor:null}},
                statusCheckRollup:{contexts:{nodes:[$rollup[] | . + {__typename:(if has("conclusion") then "CheckRun" else "StatusContext" end)} | if has("workflowName") then . + {checkSuite:{workflowRun:{workflow:{name:.workflowName}}}} else . end],pageInfo:{hasNextPage:false,endCursor:null}}}
            }}}}' ;;
    *"commits(first:100)"*)
        printf '%s\n' "${STUB_MERGE_OIDS:-}" ;;
    *"api graphql"*)
        printf '%s %s %s\n' "${STUB_UNRESOLVED:-0}" "false" "null" ;;
    *"api --paginate"*"/files"*'select(.status'*)
        # run the script's own --jq filter over a files array, so the status filter is really exercised
        printf '%s\n' "${STUB_FILE_STATUS:-}" | jq -R -n '[inputs | select(length > 0) | split(" ") | {status: .[0], filename: .[1]}]' \
            | jq -r "${args#*--jq }" ;;
    "api -H Accept: application/vnd.github.raw repos/"*"/contents/"*)
        f="${args#*/contents/}"; f="${f%%\?ref=*}"
        [ -f "${STUB_WF_DIR:-/nonexistent}/${f##*/}" ] || exit 1
        cat "$STUB_WF_DIR/${f##*/}" ;;
    "run list"*)
        [ -z "${STUB_RUNS_FAIL:-}" ] || exit 1
        w="${args#*--workflow }"; w="${w%% *}"
        case "$args" in *"--branch main "*) w="$w.main" ;; *"--branch ${STUB_PR_BRANCH:-@}"*) w="$w.pr-branch" ;; *"--branch "*) w="$w.other-branch" ;; esac
        f="${args#*--json }"; f="${f%% *}"
        if [ -f "${STUB_RUNS_DIR:-/nonexistent}/$w.json" ]; then jq -c --arg f "$f" '($f | split(",")) as $k | map(with_entries(select(.key as $n | $k | index($n))))' "$STUB_RUNS_DIR/$w.json"; else printf '[]'; fi ;;
    "run view "*)
        [ -z "${STUB_RUNS_FAIL:-}" ] || exit 1
        id="${args#run view }"; id="${id%% *}"
        case "$args" in *" --log"*)
            if [ -f "${STUB_RUNS_DIR:-/nonexistent}/log-$id.txt" ]; then cat "$STUB_RUNS_DIR/log-$id.txt"; exit 0; else exit 1; fi ;;
        esac
        if [ -f "${STUB_RUNS_DIR:-/nonexistent}/jobs-$id.json" ]; then cat "$STUB_RUNS_DIR/jobs-$id.json"; else exit 1; fi ;;
    *"api --paginate"*"/files"*"previous_filename"*)
        [ -z "${STUB_RENAMES_FAIL:-}" ] || exit 1
        # STUB_RENAMES lines "new old": run the script's own --jq filter over a files array
        printf '%s\n' "${STUB_RENAMES:-}" | jq -R -n '[inputs | select(length > 0) | split(" ") | {filename: .[0], previous_filename: .[1]}]' \
            | jq -r "${args#*--jq }" ;;
    *"api --paginate"*"/files"*".patch"*)
        # the diff of one file: STUB_WF_PATCH_FILE is its `patch` field, absent = unavailable
        [ -f "${STUB_WF_PATCH_FILE:-/nonexistent}" ] || exit 1
        cat "$STUB_WF_PATCH_FILE" ;;
    *"api --paginate"*"/files"*"filename"*)
        [ -n "${STUB_FILES_FAIL:-}" ] && exit 1
        printf '%s\n' "${STUB_FILES:-README.md}"
        [ -z "${STUB_FILES_PARTIAL:-}" ] || exit 1  # a --paginate that died after its first page
        ;;
    *)
        echo "gh-stub: unhandled args: $args" >&2
        exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/gh"

# ── jira stub (JIRA_CMD): `get KEY [--json]` reads STUB_JIRA_DB lines
# "KEY<TAB>Status<TAB>Labels<TAB>Description"; an absent key is the real CLI's HTTP 404, STUB_JIRA_DOWN=1 is an outage ────
cat > "$tmp/bin/jira-stub" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "links" ]; then
    [ -n "${STUB_LINKS_FAIL:-}" ] && { echo "jira: links $2 failed: connect ECONNREFUSED" >&2; exit 1; }
    # STUB_LINKS_DB lines "KEY<TAB>KEY": one issue link; prints the real CLI's `links` row shape for each one touching $2
    awk -F'\t' -v k="$2" '$1 == k || $2 == k { printf "%d\tRelates\tinward=%s\toutward=%s\t%s relates to %s\n", NR, $1, $2, $1, $2 }' "${STUB_LINKS_DB:-/dev/null}"
    exit 0
fi
[ "$1" = "get" ] || { echo "jira-stub: unhandled: $*" >&2; exit 1; }
[ -n "${STUB_JIRA_DOWN:-}" ] && { echo "jira: get $2 failed: connect ECONNREFUSED" >&2; exit 1; }
kc=$(printf '%s' "$2" | sed -E 's/-0+([0-9])/-\1/')
st=$(awk -F'\t' -v k="$kc" '$1 == k { print $2 }' "${STUB_JIRA_DB:-/dev/null}")
lb=$(awk -F'\t' -v k="$kc" '$1 == k { print $3 }' "${STUB_JIRA_DB:-/dev/null}")
desc=$(awk -F'\t' -v k="$kc" '$1 == k { print $4 }' "${STUB_JIRA_DB:-/dev/null}")
if [ -z "$st" ]; then
    echo "jira: get $2 failed: HTTP 404: Issue does not exist or you do not have permission to see it." >&2
    exit 1
fi
[ "$st" = "MALFORMED" ] && { printf 'garbage with no tabs\n'; exit 0; }
[ "$st" = "BLANK" ] && st=""
if [ "${3:-}" = "--json" ]; then
    jq -n --arg k "$kc" --arg st "$st" --arg lb "$lb" --arg d "$desc" \
        '{key:$k,fields:{status:{name:$st},labels:($lb | split(", ") | map(select(length > 0))),description:$d}}'
    exit 0
fi
printf '%s\tTask\t%s\tsummary\n' "$2" "$st"
[ -z "$desc" ] || printf '%s\n' "$desc"
[ -z "$lb" ] || printf 'Labels: %s\n' "$lb"
STUB
chmod +x "$tmp/bin/jira-stub"
# ── trust-path fixtures: the REAL trust list, served as the default branch's; an
# anchor repo (carrying the real go-gate.sh) whose origin is at the same commit,
# so a trust-path hit passes trust_path_check's anchor-is-current test offline ──
TRUST_LIST_FILE="$HERE/../../ci/ci-trust-paths.txt"
TP_ANCHOR="$tmp/tp-anchor"
git init -q --bare "$tmp/tp-origin.git"
git init -q "$TP_ANCHOR"
mkdir -p "$TP_ANCHOR/scripts/lib"
cp "$HERE/../../lib/go-gate.sh" "$TP_ANCHOR/scripts/lib/go-gate.sh"
git -C "$TP_ANCHOR" add -A
git -C "$TP_ANCHOR" -c user.name=t -c user.email=t@t commit -q -m init
git -C "$TP_ANCHOR" remote add origin "$tmp/tp-origin.git"
git -C "$TP_ANCHOR" push -q origin HEAD:refs/heads/main 2>/dev/null
git -C "$tmp/tp-origin.git" symbolic-ref HEAD refs/heads/main
export GH_LOG
PATH="$tmp/bin:$PATH"
export PATH

# ── shared green defaults ───────────────────────────────────────────────
GREEN_ROLLUP='[{"name":"build","status":"COMPLETED","conclusion":"SUCCESS"},{"context":"legacy-ci","state":"SUCCESS"}]'
GREEN_COMMITS='[{"messageHeadline":"feat(x): [HIMMEL-1] add thing","messageBody":"Platforms tested: linux\nSecurity reviewed: manual"},{"messageHeadline":"fix(x): [HIMMEL-2] tweak","messageBody":""}]'
GREEN_FILES="scripts/x/run.sh"
GREEN_BODY='## Summary\nthing\n\n## Ticket coverage\n- ask one: done\n- ask two: done\n\n## Test plan\nx\n'
# (check 13) every stubbed body ends with a RED-then-GREEN line unless a row sets STUB_RED to blank
GREEN_RED='\nRED then GREEN: the new row failed before the change and passes after it\n'
JIRA_DB="$tmp/jira.db"
printf 'HIMMEL-50\tTo Do\nHIMMEL-51\tDone\nHIMMEL-52\tClosed\nHIMMEL-53\tWon'"'"'t Do\nHIMMEL-54\tBLANK\nHIMMEL-55\tMALFORMED\nHIMMEL-100\tTo Do\tresidual\nHIMMEL-200\tTo Do\nHIMMEL-201\tTo Do\tresidual, class-x\nHIMMEL-202\tTo Do\tresidual-depth-1\nHIMMEL-203\tTo Do\t\tLabels: residual\n' > "$JIRA_DB"

seed_ledger_ok() {
    printf '{"kind":"avail","ts":"2026-01-01T00:00:00Z","branch":"b","head":"%s","model":"codex","status":"ok"}\n' "$SHA" > "$LEDGER"
}
seed_ledger_missing() {
    printf '{"kind":"avail","ts":"2026-01-01T00:00:00Z","branch":"b","head":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef","model":"codex","status":"ok"}\n' > "$LEDGER"
}

# seed_deferral <KEY> [head]: a CR finding at head (default $SHA) deferred to KEY, the row check 7 matches against the body
seed_deferral() {
    printf '{"kind":"finding","ts":"2026-01-01T00:00:01Z","branch":"%s","head":"%s","model":"codex","finding_id":"codex-%s","severity":"sug","verdict":"deferred","deferred_to":"%s","fu_class":"polish","reason":"out of scope","artifact":"diff","perspective":"off"}\n' "${SEED_BRANCH:-b}" "${2:-$SHA}" "$1" "$1" >> "$LEDGER"
}

run() {
    local cache="${RUN_CACHE:-}"
    [ -n "$cache" ] || cache=$(mktemp -d "$tmp/cache.XXXXXX") || return 1
    (cd "$REPO" && env -u TICKET_ID_PATTERN \
        JIRA_PROJECT_KEY=HIMMEL \
        STUB_NWO="$NWO" \
        STUB_HEAD="${STUB_HEAD:-$SHA}" STUB_MSS="${STUB_MSS:-CLEAN}" \
        STUB_ROLLUP="${STUB_ROLLUP:-$GREEN_ROLLUP}" \
        STUB_UNRESOLVED="${STUB_UNRESOLVED:-0}" \
        STUB_COMMITS="${STUB_COMMITS:-$GREEN_COMMITS}" \
        STUB_MERGE_OIDS="${STUB_MERGE_OIDS:-}" \
        STUB_FILES="${STUB_FILES:-$GREEN_FILES}" \
        STUB_FILES_FAIL="${STUB_FILES_FAIL:-}" STUB_FILES_PARTIAL="${STUB_FILES_PARTIAL:-}" \
        STUB_RENAMES="${STUB_RENAMES:-}" STUB_RENAMES_FAIL="${STUB_RENAMES_FAIL:-}" \
        STUB_FILE_STATUS="${STUB_FILE_STATUS:-}" STUB_WF_DIR="${STUB_WF_DIR:-}" \
        STUB_RUNS_DIR="${STUB_RUNS_DIR:-}" STUB_RUNS_FAIL="${STUB_RUNS_FAIL:-}" STUB_WF_PATCH_FILE="${STUB_WF_PATCH_FILE:-}" \
        STUB_AUTHOR="${STUB_AUTHOR:-}" STUB_BODY="${STUB_BODY-$GREEN_BODY}" STUB_RED="${STUB_RED-$GREEN_RED}" STUB_PR_TITLE="${STUB_PR_TITLE:-}" STUB_PR_BRANCH="${STUB_PR_BRANCH-feat/himmel-100-thing}" \
        JIRA_CMD="$tmp/bin/jira-stub" STUB_JIRA_DB="$JIRA_DB" STUB_JIRA_DOWN="${STUB_JIRA_DOWN:-}" STUB_LINKS_DB="${STUB_LINKS_DB:-}" STUB_LINKS_FAIL="${STUB_LINKS_FAIL:-}" \
        PATH="$PATH" GH_LOG="$GH_LOG" GH_PR_SNAPSHOT_CACHE_DIR="$cache" \
        STUB_SNAPSHOT_FAIL="${STUB_SNAPSHOT_FAIL:-}" \
        STUB_TRUST_LIST_FILE="$TRUST_LIST_FILE" STUB_TRUST_LIST_FAIL="${STUB_TRUST_LIST_FAIL:-}" \
        STUB_DEFAULT_BRANCH_FAIL="${STUB_DEFAULT_BRANCH_FAIL:-}" \
        READY_CHECK_ANCHOR="${READY_CHECK_ANCHOR:-$TP_ANCHOR}" \
        bash "$SCRIPT" "$PR" "$SHA")
}

reset_stubs() {
    unset STUB_TRUST_LIST_FAIL STUB_DEFAULT_BRANCH_FAIL
    unset STUB_HEAD STUB_MSS STUB_ROLLUP STUB_UNRESOLVED STUB_COMMITS STUB_MERGE_OIDS STUB_FILES STUB_FILES_FAIL STUB_FILES_PARTIAL STUB_RENAMES STUB_RENAMES_FAIL STUB_BODY STUB_RED STUB_JIRA_DOWN STUB_LINKS_DB STUB_LINKS_FAIL STUB_SNAPSHOT_FAIL STUB_FILE_STATUS STUB_WF_DIR STUB_WF_PATCH_FILE STUB_RUNS_DIR STUB_RUNS_FAIL STUB_PR_TITLE STUB_PR_BRANCH STUB_AUTHOR
    seed_ledger_ok
}

# --- usage -------------------------------------------------------------
for args in "" "77" "77 $SHA extra" "x1 $SHA" "077 $SHA" "77 ${SHA%?}" "77 ${SHA}0" \
            "77 0123456789ABCDEF0123456789abcdef01234567" "77 g123456789abcdef0123456789abcdef01234567"; do
  rc=0
  # shellcheck disable=SC2086  # word-splitting the args string IS the point
  bash "$SCRIPT" $args >/dev/null 2>&1 || rc=$?
  check "usage: [$args] -> exit 2" "$rc" "2"
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

# --- 5e. check 5 reads ONLY the first commit --------------
# A docs-only first commit with the trailers on a LATER commit (what a PR-body
# or follow-up-commit "recovery" amounts to) must still FAIL: the stuck-playbook
# recovery is a recut, not a trailer added after the fact.
reset_stubs
STUB_COMMITS='[{"messageHeadline":"docs: [HIMMEL-1] note","messageBody":""},{"messageHeadline":"fix(x): [HIMMEL-2] code","messageBody":"Platforms tested: linux\nSecurity reviewed: manual"}]'
rc=0; out="$(run)" || rc=$?
check "later-commit-trailers: exit 1" "$rc" "1"
contains "later-commit-trailers: check 5 fails (platforms)" "$out" "missing 'Platforms tested:'"
contains "later-commit-trailers: check 5 fails (security)" "$out" "missing 'Security reviewed:'"

# --- 6. check 6 fails: a commit subject with no ticket ID ---------------
reset_stubs
STUB_COMMITS='[{"messageHeadline":"feat(x): [HIMMEL-1] add thing","messageBody":"Platforms tested: linux\nSecurity reviewed: manual"},{"messageHeadline":"fix(x): tweak with no ticket","messageBody":""}]'
rc=0; out="$(run)" || rc=$?
check "missing-ticket: exit 1" "$rc" "1"
contains "missing-ticket: check 6 fails" "$out" "[FAIL] 6."
contains "missing-ticket: names the offending subject" "$out" "tweak with no ticket"

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

# --- 7b. `--only 7 <pr>` runs just the coverage check, so a worker
# lints its own PR body before READY with item 7's exact logic (no second copy).
run7() {
    (cd "$REPO" && env -u TICKET_ID_PATTERN \
        JIRA_PROJECT_KEY=HIMMEL STUB_NWO="$NWO" \
        STUB_BODY="${STUB_BODY-$GREEN_BODY}" STUB_HEAD="${STUB_HEAD:-$SHA}" \
        STUB_PR_BRANCH="${STUB_PR_BRANCH-feat/himmel-100-thing}" \
        JIRA_CMD="$tmp/bin/jira-stub" STUB_JIRA_DB="$JIRA_DB" STUB_LINKS_DB="${STUB_LINKS_DB:-}" \
        PATH="$PATH" GH_LOG="$GH_LOG" \
        bash "$SCRIPT" --only 7 "$PR")
}

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

# the full run prints the same shape message on the same failure
reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done pending verification\n'
rc=0; out="$(run)" || rc=$?
contains "full run trailing text: prints the accepted shape" "$out" "- <ask>: done"

rc=0; out="$(cd "$REPO" && bash "$SCRIPT" --only 6 "$PR" 2>&1)" || rc=$?
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

# seed_descendant <reviewed head> [branch]: the avail row clear-review-marker writes for a tip it cleared as a trivial descendant of a reviewed head
seed_descendant() {
    printf '{"kind":"avail","ts":"2026-01-01T00:00:02Z","branch":"%s","head":"%s","model":"claude","status":"ok","detail":"trivial-descendant of reviewed head %s (HIMMEL-5856)"}\n' "${2:-${SEED_BRANCH:-b}}" "$SHA" "$1" >> "$LEDGER"
}
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

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
printf '{"kind":"finding","ts":"t","branch":"%s","head":"%s","model":"codex","finding_id":"codex-9","severity":"sug","verdict":"agreed","artifact":"diff","perspective":"off"}\n{"kind":"amend","ts":"t","branch":"other","target_head":"%s","finding_id":"codex-9","artifact":"diff","perspective":"off","set":{"verdict":"deferred","deferred_to":"HIMMEL-50","fu_class":"polish"}}\n' "$SEED_BRANCH" "$REVHEAD" "$REVHEAD" >> "$LEDGER"
seed_descendant "$REVHEAD"
rc=0; out="$(run)" || rc=$?
check "descendant: an amend of another branch does not defer a finding at the reviewed head: exit 1" "$rc" "1"

# --- carry: a deferral at an earlier reviewed head counts at a later head when a
# clean full round (an ok critic avail row, no finding row) ran there after it ---
# seed_clean [branch] [model]: a critic's ok avail row at the PR head, a full round that found nothing
seed_clean() {
    printf '{"kind":"avail","ts":"2026-01-01T00:00:03Z","branch":"%s","head":"%s","model":"%s","status":"%s","artifact":"diff","perspective":"off"}\n' "${1:-$SEED_BRANCH}" "$SHA" "${2-codex}" "${3:-ok}" >> "$LEDGER"
}

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50 "$REVHEAD"; seed_clean
rc=0; out="$(run)" || rc=$?
check "carry: a deferral at an earlier head counts after a clean round at the PR head: exit 0" "$rc" "0"
contains "carry: clean round: check 7 passes" "$out" "[PASS] 7."

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n'
seed_deferral HIMMEL-50 "$REVHEAD"; seed_clean
rc=0; out="$(run)" || rc=$?
check "carry: a carried deferral absent from the body: exit 1" "$rc" "1"
contains "carry: absent from body: names the key" "$out" "HIMMEL-50 is deferred in the CR ledger"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50 "$REVHEAD"
rc=0; out="$(run)" || rc=$?
check "carry: no round at the PR head, the earlier deferral does not carry: exit 1" "$rc" "1"
contains "carry: no round: names the key" "$out" "HIMMEL-50 is deferred in the body but has no deferred_to row"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50 "$REVHEAD"; seed_clean "" claude
rc=0; out="$(run)" || rc=$?
check "carry: a claude (non-critic) row is not a clean round: exit 1" "$rc" "1"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50 "$REVHEAD"; seed_clean "" codex unavailable
rc=0; out="$(run)" || rc=$?
check "carry: an unavailable critic row is not a clean round: exit 1" "$rc" "1"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50 "$REVHEAD"; seed_clean "" ""
rc=0; out="$(run)" || rc=$?
check "carry: an empty-model row is not a clean round: exit 1" "$rc" "1"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50 "$REVHEAD"; seed_clean "" claude-floor
rc=0; out="$(run)" || rc=$?
check "carry: a claude-floor row is not a clean round: exit 1" "$rc" "1"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50 "$REVHEAD"; seed_clean "" codex-adv
rc=0; out="$(run)" || rc=$?
check "carry: a codex-adv row is not a clean round: exit 1" "$rc" "1"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50 "$REVHEAD"; seed_clean other
rc=0; out="$(run)" || rc=$?
check "carry: a clean round of another branch does not carry: exit 1" "$rc" "1"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_clean; seed_deferral HIMMEL-50 "$REVHEAD"
rc=0; out="$(run)" || rc=$?
check "carry: a round written before the deferral does not carry it: exit 1" "$rc" "1"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
SEED_BRANCH=other seed_deferral HIMMEL-50 "$REVHEAD"; seed_clean
rc=0; out="$(run)" || rc=$?
check "carry: a deferral of another branch does not carry: exit 1" "$rc" "1"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50 "$REVHEAD"
printf '{"kind":"finding","ts":"2026-01-01T00:00:04Z","branch":"%s","head":"%s","model":"codex","finding_id":"codex-HIMMEL-50","severity":"sug","verdict":"agreed","artifact":"diff","perspective":"off"}\n' "$SEED_BRANCH" "$SHA" >> "$LEDGER"
seed_clean
rc=0; out="$(run)" || rc=$?
check "carry: a finding re-raised at the PR head blocks the carry: exit 1" "$rc" "1"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50 "$REVHEAD"
printf '{"kind":"finding","ts":"2026-01-01T00:00:04Z","branch":"%s","head":"%s","model":"codex","finding_id":"codex-other","severity":"sug","verdict":"fixed","artifact":"diff","perspective":"off"}\n' "$SEED_BRANCH" "$SHA" >> "$LEDGER"
seed_clean
rc=0; out="$(run)" || rc=$?
check "carry: any finding row at the PR head makes the round not clean: exit 1" "$rc" "1"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50 "$REVHEAD"
printf '{"kind":"amend","ts":"2026-01-01T00:00:04Z","branch":"%s","target_head":"%s","finding_id":"codex-HIMMEL-50","artifact":"diff","perspective":"off","set":{"verdict":"fixed"}}\n' "$SEED_BRANCH" "$REVHEAD" >> "$LEDGER"
seed_clean
rc=0; out="$(run)" || rc=$?
check "carry: a deferral later amended to fixed does not carry: exit 1" "$rc" "1"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
MIDHEAD=1234567812345678123456781234567812345678
seed_deferral HIMMEL-50 "$REVHEAD"
printf '{"kind":"finding","ts":"2026-01-01T00:00:04Z","branch":"%s","head":"%s","model":"codex","finding_id":"codex-HIMMEL-50","severity":"sug","verdict":"agreed","artifact":"diff","perspective":"off"}\n' "$SEED_BRANCH" "$MIDHEAD" >> "$LEDGER"
seed_clean
rc=0; out="$(run)" || rc=$?
check "carry: a finding re-raised at an intermediate head blocks the earlier deferral: exit 1" "$rc" "1"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50 "$REVHEAD"; seed_deferral HIMMEL-50 "$MIDHEAD"; seed_clean
rc=0; out="$(run)" || rc=$?
check "carry: a deferral recorded again at a later head carries from that row: exit 0" "$rc" "0"
unset SEED_BRANCH

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n'
printf '{"kind":"finding","ts":"t","branch":"b","head":"%s","model":"codex","finding_id":"codex-9","severity":"sug","verdict":"agreed","artifact":"diff","perspective":"off"}\n{"kind":"amend","ts":"t","branch":"b","target_head":"%s","finding_id":"codex-9","artifact":"diff","perspective":"off","set":{"verdict":"deferred","deferred_to":"HIMMEL-50","fu_class":"polish"}}\n' "$SHA" "$SHA" >> "$LEDGER"
rc=0; out="$(run)" || rc=$?
check "ledger: a deferral made by an amend row is read: exit 1 (absent from body)" "$rc" "1"
contains "ledger: amend deferral: names the key" "$out" "HIMMEL-50 is deferred in the CR ledger"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n'
seed_deferral HIMMEL-50
printf '{"kind":"amend","ts":"t","branch":"b","target_head":"%s","finding_id":"codex-HIMMEL-50","artifact":"diff","perspective":"off","set":{"verdict":"fixed"}}\n' "$SHA" >> "$LEDGER"
rc=0; out="$(run)" || rc=$?
check "ledger: a deferral later amended to fixed is not a deferral: exit 0" "$rc" "0"

OLDHEAD=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
printf '{"kind":"finding","ts":"t","branch":"b","head":"%s","model":"codex","finding_id":"codex-9","severity":"sug","verdict":"agreed","artifact":"diff","perspective":"off"}\n{"kind":"amend","ts":"t","branch":"b","target_head":"%s","finding_id":"codex-9","artifact":"diff","perspective":"off","set":{"head":"%s"}}\n{"kind":"amend","ts":"t","branch":"b","target_head":"%s","finding_id":"codex-9","artifact":"diff","perspective":"off","set":{"verdict":"deferred","deferred_to":"HIMMEL-50","fu_class":"polish"}}\n' "$OLDHEAD" "$OLDHEAD" "$SHA" "$OLDHEAD" >> "$LEDGER"
rc=0; out="$(run)" || rc=$?
check "ledger: a deferral on a finding an amend moved to the PR head counts: exit 0" "$rc" "0"
contains "ledger: moved deferral: check 7 passes" "$out" "[PASS] 7."

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n'
printf '{"kind":"finding","ts":"t","branch":"b","head":"%s","model":"codex","finding_id":"codex-9","severity":"sug","verdict":"agreed","artifact":"diff","perspective":"off"}\n{"kind":"amend","ts":"t","branch":"b","target_head":"%s","finding_id":"codex-9","artifact":"diff","perspective":"off","set":{"head":"%s"}}\n{"kind":"amend","ts":"t","branch":"b","target_head":"%s","finding_id":"codex-9","artifact":"diff","perspective":"off","set":{"verdict":"deferred","deferred_to":"HIMMEL-50","fu_class":"polish"}}\n' "$OLDHEAD" "$OLDHEAD" "$SHA" "$OLDHEAD" >> "$LEDGER"
rc=0; out="$(run)" || rc=$?
check "ledger: a moved deferral absent from the body: exit 1" "$rc" "1"
contains "ledger: moved deferral absent from body: names the key" "$out" "HIMMEL-50 is deferred in the CR ledger"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50
printf '{"kind":"amend","ts":"t","branch":"b","target_head":"%s","finding_id":"codex-HIMMEL-50","artifact":"diff","perspective":"off","set":{"verdict":"fixed"}}\n' "$SHA" >> "$LEDGER"
seed_deferral HIMMEL-50
rc=0; out="$(run)" || rc=$?
check "ledger: an amend does not reach a finding row written after it: exit 0" "$rc" "0"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n'
seed_deferral HIMMEL-50 "$OLDHEAD"
printf '{"kind":"amend","ts":"t","branch":"b","target_head":"%s","finding_id":"codex-HIMMEL-50","artifact":"diff","perspective":"off","set":{"head":"%s"}}\n' "$OLDHEAD" "$SHA" >> "$LEDGER"
printf '{"kind":"finding","ts":"t","branch":"b","head":"%s","model":"codex","finding_id":"codex-HIMMEL-50","severity":"sug","verdict":"fixed","artifact":"diff","perspective":"off"}\n' "$OLDHEAD" >> "$LEDGER"
rc=0; out="$(run)" || rc=$?
check "ledger: a replacement row at the original head supersedes the moved finding: exit 0" "$rc" "0"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n'
seed_deferral HIMMEL-50
printf '{"kind":"amend","ts":"t","branch":"b","target_head":"%s","finding_id":"codex-HIMMEL-50","artifact":"diff","perspective":"off","set":{"head":"%s"}}\n' "$SHA" "$OLDHEAD" >> "$LEDGER"
rc=0; out="$(run)" || rc=$?
check "ledger: a deferral an amend moved off the PR head is not a deferral there: exit 0" "$rc" "0"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n'
printf 'not json\n' >> "$LEDGER"
rc=0; out="$(run)" || rc=$?
check "ledger: a malformed ledger line is skipped: exit 0" "$rc" "0"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n'
seed_deferral HIMMEL-50
rc=0; out="$(run7)" || rc=$?
check "only 7: a ledger deferral absent from the body fails: exit 1" "$rc" "1"
contains "only 7: ledger deferral: names the key" "$out" "HIMMEL-50 is deferred in the CR ledger"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50
rc=0; out="$(run7)" || rc=$?
check "only 7: matching sets pass: exit 0" "$rc" "0"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-100\n'
seed_deferral HIMMEL-100
printf 'HIMMEL-100\tHIMMEL-1\n' > "$tmp/links.db"; STUB_LINKS_DB="$tmp/links.db"
rc=0; out="$(run)" || rc=$?
check "self: a deferral to the PR's own ticket is refused though its links name it: exit 1" "$rc" "1"
contains "self: names the own ticket" "$out" "HIMMEL-100 is the PR's own ticket"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-0100\n'
seed_deferral HIMMEL-0100
rc=0; out="$(run)" || rc=$?
check "self: a zero-padded spelling of the own ticket is refused though it carries the residual label: exit 1" "$rc" "1"
contains "self: padded spelling is read as Jira's canonical key" "$out" "HIMMEL-100 is the PR's own ticket"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-050\n'
seed_deferral HIMMEL-50
rc=0; out="$(run)" || rc=$?
check "canonical key: a zero-padded spelling of a good target matches its ledger row: exit 0" "$rc" "0"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-201\n'
seed_deferral HIMMEL-201
STUB_PR_BRANCH='feat/himmel-201-thing'
rc=0; out="$(run)" || rc=$?
check "self: a residual-labelled own ticket is no deferral target either: exit 1" "$rc" "1"
contains "self: residual-labelled own ticket: names it" "$out" "HIMMEL-201 is the PR's own ticket"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n- ask two: deferred -> HIMMEL-200\n'
seed_deferral HIMMEL-200
STUB_LINKS_FAIL=1
rc=0; out="$(run)" || rc=$?
check "links: a failed links lookup fails: exit 1" "$rc" "1"
contains "links: failed lookup: reads UNKNOWN" "$out" "HIMMEL-200 UNKNOWN (jira links failed for HIMMEL-100)"
notcontains "links: failed lookup: is not blamed on a raw create" "$out" "raw jira create"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n'
chmod 000 "$LEDGER"
if [ -r "$LEDGER" ]; then
    echo "SKIP ledger: an unreadable ledger fails (still readable here, e.g. root)"
else
    rc=0; out="$(run)" || rc=$?
    check "ledger: an unreadable ledger fails check 7: exit 1" "$rc" "1"
    contains "ledger: unreadable: names the cause" "$out" "the CR ledger could not be read"
fi
chmod 600 "$LEDGER"

# --- chain: a deferral carries along a chain of trivial-descendant rows, each naming the reviewed head before it ---
# chain_head <n>: a distinct 40-hex head
chain_head() { printf '%040x' "$1"; }
# seed_hop <head> <reviewed head>: the avail row of a tip cleared as a trivial descendant of <reviewed head>
seed_hop() {
    printf '{"kind":"avail","ts":"2026-01-01T00:00:02Z","branch":"%s","head":"%s","model":"claude","status":"ok","detail":"trivial-descendant of reviewed head %s (HIMMEL-5856)"}\n' "$SEED_BRANCH" "$1" "$2" >> "$LEDGER"
}
# seed_clean_at <head>: a critic's ok avail row at <head>, a full round that found nothing
seed_clean_at() {
    printf '{"kind":"avail","ts":"2026-01-01T00:00:03Z","branch":"%s","head":"%s","model":"codex","status":"ok","artifact":"diff","perspective":"off"}\n' "$SEED_BRANCH" "$1" >> "$LEDGER"
}
CH_B=$(chain_head 11); CH_C=$(chain_head 12)
SEED_BRANCH=feat/himmel-100-thing

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50 "$REVHEAD"; seed_clean_at "$CH_B"; seed_hop "$CH_C" "$CH_B"; seed_hop "$SHA" "$CH_C"
rc=0; out="$(run)" || rc=$?
check "chain: a deferral carries through two trivial descendants of a cleanly reviewed head: exit 0" "$rc" "0"
contains "chain: two hops: check 7 passes" "$out" "[PASS] 7."

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50 "$REVHEAD"; seed_clean_at "$CH_B"; seed_hop "$CH_C" "$CH_B"; seed_hop "$SHA" "$CH_C"
printf '{"kind":"finding","ts":"2026-01-01T00:00:04Z","branch":"%s","head":"%s","model":"codex","finding_id":"codex-HIMMEL-50","severity":"sug","verdict":"agreed","artifact":"diff","perspective":"off"}\n' "$SEED_BRANCH" "$CH_C" >> "$LEDGER"
rc=0; out="$(run)" || rc=$?
check "chain: a finding re-raised at a middle head of the chain stops the carry: exit 1" "$rc" "1"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50 "$REVHEAD"; seed_hop "$CH_B" "$REVHEAD"; seed_hop "$CH_C" "$CH_B"; seed_hop "$SHA" "$CH_C"
printf '{"kind":"finding","ts":"2026-01-01T00:00:04Z","branch":"%s","head":"%s","model":"codex","finding_id":"codex-HIMMEL-50","severity":"sug","verdict":"agreed","artifact":"diff","perspective":"off"}\n' "$SEED_BRANCH" "$CH_B" >> "$LEDGER"
rc=0; out="$(run)" || rc=$?
check "chain: a deferral inside the chain that a later head re-raised does not count: exit 1" "$rc" "1"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50 "$REVHEAD"; seed_hop "$CH_B" "$REVHEAD"; seed_hop "$CH_C" "$CH_B"; seed_hop "$SHA" "$CH_C"
rc=0; out="$(run)" || rc=$?
check "chain: a deferral at the far end of the chain counts: exit 0" "$rc" "0"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50 "$REVHEAD"; seed_hop "$CH_B" "$REVHEAD"; seed_hop "$CH_C" "$CH_B"; seed_hop "$SHA" "$CH_C"
seed_deferral HIMMEL-50 "$(chain_head 77)"
rc=0; out="$(run)" || rc=$?
check "chain: the same finding recorded again at a head outside the chain does not cancel the chain's deferral: exit 0" "$rc" "0"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50 "$REVHEAD"; seed_hop "$CH_C" "$CH_B"; seed_hop "$SHA" "$CH_C"
rc=0; out="$(run)" || rc=$?
check "chain: no clean round at any head of the chain, the deferral does not carry: exit 1" "$rc" "1"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
seed_deferral HIMMEL-50 "$REVHEAD"; seed_clean_at "$CH_B"; seed_hop "$CH_C" "$CH_B"; seed_hop "$CH_B" "$SHA"; seed_hop "$SHA" "$CH_C"
rc=0; out="$(run)" || rc=$?
check "chain: a cycle among the descendant rows ends and the carry still holds: exit 0" "$rc" "0"

# --- terminal: a chain-head finding that is already handled (fixed, deferred or disproved) no longer makes the chain "raised" ---
# seed_judge <verdict> [deferred_to]: the judge's finding at the reviewed head $CH_B of the chain
seed_judge() {
    printf '{"kind":"finding","ts":"2026-01-01T00:00:01Z","branch":"%s","head":"%s","model":"judge","finding_id":"IF-j4130-2-G1","severity":"imp","verdict":"%s","deferred_to":"%s","fu_class":"polish","reason":"judged","artifact":"diff","perspective":"off"}\n' "$SEED_BRANCH" "$CH_B" "$1" "${2:-}" >> "$LEDGER"
}
# seed_judge_amend <verdict> [deferred_to]: a later amend of that finding
seed_judge_amend() {
    printf '{"kind":"amend","ts":"2026-01-01T00:00:02Z","branch":"%s","target_head":"%s","finding_id":"IF-j4130-2-G1","artifact":"diff","perspective":"off","set":{"verdict":"%s","deferred_to":"%s"}}\n' "$SEED_BRANCH" "$CH_B" "$1" "${2:-}" >> "$LEDGER"
}
# the shape under test: an earlier-head deferral, a judge finding at the reviewed head, a trivial descendant of it, a clean codex round at the PR head after both
pr4130_shape() {
    reset_stubs
    STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
    seed_deferral HIMMEL-50 "$REVHEAD"
}

pr4130_shape
seed_judge deferred HIMMEL-201; seed_hop "$SHA" "$CH_B"; seed_clean_at "$SHA"
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n- ask two: deferred -> HIMMEL-201\n'
rc=0; out="$(run)" || rc=$?
check "terminal: a deferred judge finding at the reviewed head does not block the earlier deferral's carry: exit 0" "$rc" "0"
contains "terminal: deferred judge finding: check 7 passes" "$out" "[PASS] 7."

pr4130_shape
seed_judge disproved; seed_hop "$SHA" "$CH_B"; seed_clean_at "$SHA"
rc=0; out="$(run)" || rc=$?
check "terminal: a disproved judge finding at the reviewed head does not block the carry: exit 0" "$rc" "0"

pr4130_shape
seed_judge agreed; seed_judge_amend deferred HIMMEL-201; seed_hop "$SHA" "$CH_B"; seed_clean_at "$SHA"
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n- ask two: deferred -> HIMMEL-201\n'
rc=0; out="$(run)" || rc=$?
check "terminal: a judge finding deferred by a later amend does not block the carry: exit 0" "$rc" "0"

pr4130_shape
seed_judge agreed; seed_hop "$SHA" "$CH_B"; seed_clean_at "$SHA"
rc=0; out="$(run)" || rc=$?
check "terminal: an open judge finding at the reviewed head still blocks the carry: exit 1" "$rc" "1"
contains "terminal: open judge finding: names the key" "$out" "HIMMEL-50 is deferred in the body but has no deferred_to row"

pr4130_shape
seed_judge agreed; seed_judge_amend agreed; seed_hop "$SHA" "$CH_B"; seed_clean_at "$SHA"
rc=0; out="$(run)" || rc=$?
check "terminal: an amend that leaves the judge finding open still blocks the carry: exit 1" "$rc" "1"

pr4130_shape
seed_judge deferred HIMMEL-201; seed_judge_amend agreed; seed_hop "$SHA" "$CH_B"; seed_clean_at "$SHA"
rc=0; out="$(run)" || rc=$?
check "terminal: a deferred judge finding later amended back to open blocks the carry: exit 1" "$rc" "1"

pr4130_shape
seed_judge deferred HIMMEL-201; seed_hop "$SHA" "$CH_B"; seed_clean_at "$SHA"
printf '{"kind":"finding","ts":"2026-01-01T00:00:04Z","branch":"%s","head":"%s","model":"codex","finding_id":"codex-open","severity":"sug","verdict":"agreed","artifact":"diff","perspective":"off"}\n' "$SEED_BRANCH" "$CH_B" >> "$LEDGER"
rc=0; out="$(run)" || rc=$?
check "terminal: a terminal judge finding beside an open one at the chain still blocks the carry: exit 1" "$rc" "1"

# a fixed finding carries only when a clean round was written after its last row or amend
pr4130_shape
seed_judge agreed; seed_judge_amend fixed; seed_hop "$SHA" "$CH_B"; seed_clean_at "$SHA"
rc=0; out="$(run)" || rc=$?
check "terminal: a judge finding fixed by an amend, then a clean round at the PR head, carries: exit 0" "$rc" "0"
contains "terminal: fixed then clean: check 7 passes" "$out" "[PASS] 7."

pr4130_shape
seed_judge agreed; seed_clean_at "$SHA"; seed_judge_amend fixed; seed_hop "$SHA" "$CH_B"
rc=0; out="$(run)" || rc=$?
check "terminal: a clean round written before the fixing amend does not carry: exit 1" "$rc" "1"

pr4130_shape
seed_clean_at "$SHA"; seed_judge fixed; seed_hop "$SHA" "$CH_B"
rc=0; out="$(run)" || rc=$?
check "terminal: a clean round written before the fixed finding row does not carry: exit 1" "$rc" "1"

pr4130_shape
seed_judge fixed; seed_hop "$SHA" "$CH_B"
rc=0; out="$(run)" || rc=$?
check "terminal: a fixed judge finding with no clean round after it does not carry: exit 1" "$rc" "1"

pr4130_shape
printf '{"kind":"finding","ts":"2026-01-01T00:00:01Z","branch":"%s","head":"%s","model":"judge","finding_id":"IF-j4130-2-G1","severity":"imp","verdict":"deferred","deferred_to":"HIMMEL-201","fu_class":"polish","reason":"judged","artifact":"diff","perspective":"off"}\n' "$SEED_BRANCH" "$SHA" >> "$LEDGER"
seed_hop "$SHA" "$CH_B"; seed_clean_at "$SHA"
rc=0; out="$(run)" || rc=$?
check "terminal: a handled finding AT the PR head still blocks the carry: exit 1" "$rc" "1"

# a finding row recorded again for the same identity is judged by its later row alone
pr4130_shape
seed_judge agreed; seed_judge fixed; seed_hop "$SHA" "$CH_B"; seed_clean_at "$SHA"
rc=0; out="$(run)" || rc=$?
check "terminal: an open finding row replaced by a later fixed row of the same identity carries: exit 0" "$rc" "0"

pr4130_shape
seed_judge fixed; seed_judge agreed; seed_hop "$SHA" "$CH_B"; seed_clean_at "$SHA"
rc=0; out="$(run)" || rc=$?
check "terminal: a fixed finding row replaced by a later open row of the same identity blocks: exit 1" "$rc" "1"

# the clean round must have reviewed the handled code: its head is the finding's head or a descendant of it
# seed_judge_at <head> <verdict>: the judge's finding at <head>
seed_judge_at() {
    printf '{"kind":"finding","ts":"2026-01-01T00:00:01Z","branch":"%s","head":"%s","model":"judge","finding_id":"IF-j4130-2-G1","severity":"imp","verdict":"%s","reason":"judged","artifact":"diff","perspective":"off"}\n' "$SEED_BRANCH" "$1" "$2" >> "$LEDGER"
}

pr4130_shape
seed_judge_at "$CH_C" fixed; seed_hop "$CH_C" "$CH_B"; seed_hop "$SHA" "$CH_C"; seed_clean_at "$CH_B"
rc=0; out="$(run)" || rc=$?
check "terminal: a clean round at an ANCESTOR of the fixed finding's head does not carry: exit 1" "$rc" "1"

pr4130_shape
seed_judge_at "$CH_C" fixed; seed_hop "$CH_C" "$CH_B"; seed_hop "$SHA" "$CH_C"; seed_clean_at "$CH_C"
rc=0; out="$(run)" || rc=$?
check "terminal: a clean round at the fixed finding's own head carries: exit 0" "$rc" "0"

pr4130_shape
seed_judge_at "$CH_C" fixed; seed_hop "$CH_C" "$CH_B"; seed_hop "$SHA" "$CH_C"; seed_clean_at "$SHA"
rc=0; out="$(run)" || rc=$?
check "terminal: a clean round at a descendant of the fixed finding's head carries: exit 0" "$rc" "0"

# a chain of N hops: the clean round sits N hops before the PR head
chain_of() {
    local n="$1" i prev
    reset_stubs
    STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50\n'
    seed_deferral HIMMEL-50 "$REVHEAD"; seed_clean_at "$(chain_head 100)"
    prev=$(chain_head 100)
    for ((i = 1; i < n; i++)); do seed_hop "$(chain_head $((100 + i)))" "$prev"; prev=$(chain_head $((100 + i))); done
    seed_hop "$SHA" "$prev"
}
chain_of 10
rc=0; out="$(run)" || rc=$?
check "chain: ten hops from the PR head still carry: exit 0" "$rc" "0"
chain_of 11
rc=0; out="$(run)" || rc=$?
check "chain: eleven hops from the PR head are past the cap: exit 1" "$rc" "1"

# --- 8. TICKET_ID_PATTERN / JIRA_PROJECT_KEY must resolve from
# ready-check.sh's OWN checkout, never the caller's CWD repo. Fixture mirrors
# test-bank-preflight-dotenv-root.sh: a scratch "own checkout" (this script +
# scripts/lib/load-dotenv.sh, laid out at the same relative depth, plus a
# fixture .env carrying JIRA_PROJECT_KEY) is run with CWD at $REPO — a git
# repo with no .env of its own — and neither var exported by the caller.
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
own="$tmp/own-checkout"
mkdir -p "$own/scripts/handover/chief-kit" "$own/scripts/lib"
cp "$SCRIPT" "$own/scripts/handover/chief-kit/ready-check.sh"
cp "$REPO_ROOT/scripts/lib/load-dotenv.sh" "$own/scripts/lib/load-dotenv.sh"
cp "$REPO_ROOT/scripts/lib/gh-pr-snapshot.sh" "$own/scripts/lib/gh-pr-snapshot.sh"
cp "$REPO_ROOT/scripts/lib/go-gate.sh" "$own/scripts/lib/go-gate.sh"
printf 'JIRA_PROJECT_KEY=HIMMEL\n' > "$own/.env"

reset_stubs
STUB_COMMITS="$GREEN_COMMITS"
rc=0
out="$(cd "$REPO" && env -u TICKET_ID_PATTERN -u JIRA_PROJECT_KEY \
    STUB_NWO="$NWO" STUB_HEAD="$SHA" STUB_MSS=CLEAN \
    STUB_ROLLUP="$GREEN_ROLLUP" STUB_UNRESOLVED=0 \
    STUB_COMMITS="$STUB_COMMITS" STUB_FILES="$GREEN_FILES" \
    STUB_BODY="$GREEN_BODY" STUB_RED="$GREEN_RED" JIRA_CMD="$tmp/bin/jira-stub" STUB_JIRA_DB="$JIRA_DB" \
    STUB_TRUST_LIST_FILE="$TRUST_LIST_FILE" \
    PATH="$PATH" GH_LOG="$GH_LOG" \
    bash "$own/scripts/handover/chief-kit/ready-check.sh" "$PR" "$SHA")" || rc=$?
check "own-checkout .env: exit 0" "$rc" "0"
contains "own-checkout .env: check 6 (ticket ID) passes" "$out" "[PASS] 6."

# --- 9. a PR that changes a plugin bumps that plugin's version above the
# CURRENT origin/main's; a bump with no other plugin change is
# refused; a release cut (a PR that changes the root VERSION file) raises every
# plugin it touches above main. Two PRs can raise a plugin to the same version
# with different content and mergeStateStatus stays CLEAN, so check 1 cannot
# see it. Fixture: a
# bare origin; WORK builds history and pushes each PR head to refs/pull/77/head;
# CLONE (what run() cds into) is cloned BEFORE main moves, so its origin/main is
# stale and has none of the PR objects — check 9 must fetch both.
PLUG=marketplace/plugins/demo
ORIGIN="$tmp/origin.git"
WORK="$tmp/work"
CLONE="$tmp/clone"
git init -q --bare "$ORIGIN"
git init -q -b main "$WORK"
git -C "$WORK" config user.email t@example.com
git -C "$WORK" config user.name tester
git -C "$WORK" remote add origin "$ORIGIN"
write_plugin() {  # <version> <content>
    mkdir -p "$WORK/$PLUG/.claude-plugin"
    printf '{"name":"demo","version":"%s"}\n' "$1" > "$WORK/$PLUG/.claude-plugin/plugin.json"
    printf '%s\n' "$2" > "$WORK/$PLUG/body.txt"
    git -C "$WORK" add -A
    git -C "$WORK" commit -q -m "$3"
}
printf '1.0.0\n' > "$WORK/VERSION"
mkdir -p "$WORK/marketplace/.claude-plugin"
printf '{"plugins":[{"name":"demo","source":"./plugins/demo"}]}\n' > "$WORK/marketplace/.claude-plugin/marketplace.json"
write_plugin 0.4.70 base "chore: base"
git -C "$WORK" push -q origin main
BASE_OID=$(git -C "$WORK" rev-parse HEAD)
git clone -q "$ORIGIN" "$CLONE"
pr_head() {  # <version> <content> [release] -> commit on a branch off the base, pushed as the PR head
    git -C "$WORK" checkout -q -B pr "$BASE_OID"
    [ -z "${3:-}" ] || printf '1.1.0\n' > "$WORK/VERSION"
    write_plugin "$1" "$2" "fix: pr"
    git -C "$WORK" rev-parse HEAD
}
PR_SAME=$(pr_head 0.4.71 from-pr)
PR_UNBUMPED=$(pr_head 0.4.70 from-pr)
PR_REL_SAME=$(pr_head 0.4.71 from-pr release)
PR_REL_AHEAD=$(pr_head 0.4.72 from-pr release)
PR_PRE=$(pr_head 0.4.71-alpha from-pr release)
PR_NEW_BUMP=$(pr_head 0.4.72 from-pr)
git -C "$WORK" checkout -q -B pr "$BASE_OID"
write_plugin 0.4.72 base "chore: pr bumps only the manifest"
PR_BUMP_ONLY=$(git -C "$WORK" rev-parse HEAD)
git -C "$WORK" checkout -q -B pr "$BASE_OID"
git -C "$WORK" rm -rq "$PLUG"
git -C "$WORK" commit -q -m "fix: pr removes the plugin, still listed"
PR_DEL_LISTED=$(git -C "$WORK" rev-parse HEAD)
printf '{"plugins":[]}\n' > "$WORK/marketplace/.claude-plugin/marketplace.json"
git -C "$WORK" add -A
git -C "$WORK" commit -q -m "fix: pr removes the plugin"
PR_DEL=$(git -C "$WORK" rev-parse HEAD)
git -C "$WORK" checkout -q -B pr "$BASE_OID"
git -C "$WORK" rm -q "$PLUG/.claude-plugin/plugin.json"
git -C "$WORK" commit -q -m "fix: pr drops only the manifest"
PR_MANIFEST_DEL=$(git -C "$WORK" rev-parse HEAD)
pr_head 0.4.72 from-pr release >/dev/null
git -C "$WORK" rm -q "$PLUG/.claude-plugin/plugin.json"
git -C "$WORK" commit -q -m "fix: release cut drops only the manifest"
PR_REL_MANIFEST_DEL=$(git -C "$WORK" rev-parse HEAD)
# a second plugin whose manifest on main carries no version (unreadable there)
BADP=marketplace/plugins/bad
pr_head 0.4.72 from-pr release >/dev/null
mkdir -p "$WORK/$BADP/.claude-plugin"
printf '{"name":"bad","version":"1.0.0"}\n' > "$WORK/$BADP/.claude-plugin/plugin.json"
git -C "$WORK" add -A
git -C "$WORK" commit -q -m "fix: pr touches bad"
PR_BAD=$(git -C "$WORK" rev-parse HEAD)
git -C "$WORK" checkout -q -B pr "$BASE_OID"
mkdir -p "$WORK/$BADP/.claude-plugin"
printf '{"name":"bad","version":"1.0.0"}\n' > "$WORK/$BADP/.claude-plugin/plugin.json"
printf 'x\n' > "$WORK/$BADP/body.txt"
git -C "$WORK" add -A
git -C "$WORK" commit -q -m "fix: pr introduces bad (not a release)"
PR_BAD_NEW=$(git -C "$WORK" rev-parse HEAD)
git -C "$WORK" checkout -q main
write_plugin 0.4.71 from-main "feat: main shipped 0.4.71"
mkdir -p "$WORK/$BADP/.claude-plugin"
printf '{"name":"bad"}\n' > "$WORK/$BADP/.claude-plugin/plugin.json"
git -C "$WORK" add -A
git -C "$WORK" commit -q -m "feat: main bad manifest"
git -C "$WORK" push -q origin main

run_bump() {  # <pr head> <files> -> sets rc/out
    git -C "$WORK" push -q -f origin "$1:refs/pull/$PR/head"
    local keep_sha="$SHA" keep_repo="$REPO" keep_ledger="$LEDGER"
    SHA="$1"; REPO="$CLONE"; LEDGER="$CLONE/.git/cr-critic-scores.jsonl"
    reset_stubs
    STUB_FILES="$2"
    rc=0; out="$(run)" || rc=$?
    SHA="$keep_sha"; REPO="$keep_repo"; LEDGER="$keep_ledger"
}

# A PR that changes a plugin bumps that plugin's version above the
# CURRENT origin/main's. Main moved the plugin to 0.4.71 after this PR branched.
# RED: the PR edits the plugin and leaves the version alone.
run_bump "$PR_UNBUMPED" "$PLUG/body.txt"
check "plugin edit, version untouched: exit 1" "$rc" "1"
contains "plugin edit, version untouched: check 9 fails" "$out" "[FAIL] 9."
contains "plugin edit, version untouched: names the plugin" "$out" "demo"

# Bumped to the version main already ships: two contents under one version.
run_bump "$PR_SAME" "$PLUG/body.txt"
check "plugin edit bumped to main's version: exit 1" "$rc" "1"
contains "plugin edit bumped to main's version: check 9 fails" "$out" "[FAIL] 9."
contains "plugin edit bumped to main's version: names the plugin" "$out" "demo"
contains "plugin edit bumped to main's version: says why" "$out" "bump above main"

# DoD: a plugin file changed AND the version bumped above main passes.
run_bump "$PR_NEW_BUMP" "$PLUG/body.txt"
contains "plugin edit bumped above main: check 9 passes" "$out" "[PASS] 9. every plugin the PR changes is bumped above current origin/main"
notcontains "plugin edit bumped above main: no check fails" "$out" "[FAIL]"

# A plugin the PR introduces but main now ships is judged against main too (here
# main's manifest carries no readable version, so the check fails closed).
run_bump "$PR_BAD_NEW" "$BADP/.claude-plugin/plugin.json"
check "new plugin main already ships: exit 1" "$rc" "1"
contains "new plugin main already ships: check 9 fails" "$out" "[FAIL] 9."

# DoD: a bump with no other file change in the plugin is refused.
run_bump "$PR_BUMP_ONLY" "$PLUG/.claude-plugin/plugin.json"
check "bump with no plugin change: exit 1" "$rc" "1"
contains "bump with no plugin change: check 9 fails" "$out" "[FAIL] 9."
contains "bump with no plugin change: says why" "$out" "no other file of demo changed"

run_bump "$PR_REL_SAME" "$PLUG/body.txt"
check "release cut same-version-as-main: exit 1" "$rc" "1"
contains "release cut same-version-as-main: check 9 fails" "$out" "[FAIL] 9."
contains "release cut same-version-as-main: names the plugin" "$out" "demo"

run_bump "$PR_REL_AHEAD" "$PLUG/body.txt"
contains "release cut ahead of main: check 9 passes" "$out" "[PASS] 9."
notcontains "release cut ahead of main: no check fails" "$out" "[FAIL]"

run_bump "$PR_PRE" "$PLUG/body.txt"
check "prerelease PR version: exit 1" "$rc" "1"
contains "prerelease PR version: check 9 fails" "$out" "[FAIL] 9."

run_bump "$PR_BAD" "$BADP/.claude-plugin/plugin.json"
check "unreadable main manifest: exit 1" "$rc" "1"
contains "unreadable main manifest: check 9 fails" "$out" "[FAIL] 9."

run_bump "$PR_DEL" "$PLUG/body.txt"
contains "plugin removed by the PR: check 9 passes" "$out" "[PASS] 9."

# Only a whole removal needs no version: a dropped manifest with the plugin's
# files left, or a removed plugin marketplace.json still lists, fails, as
# check-plugin-drift.sh --bump-required does.
run_bump "$PR_MANIFEST_DEL" "$PLUG/.claude-plugin/plugin.json"
check "manifest dropped, plugin files left: exit 1" "$rc" "1"
contains "manifest dropped, plugin files left: check 9 fails" "$out" "[FAIL] 9."
run_bump "$PR_REL_MANIFEST_DEL" "$PLUG/.claude-plugin/plugin.json"
check "release cut drops the manifest, plugin files left: exit 1" "$rc" "1"
contains "release cut drops the manifest, plugin files left: check 9 fails" "$out" "[FAIL] 9."
run_bump "$PR_DEL_LISTED" "$PLUG/body.txt"
check "plugin removed but still listed in marketplace.json: exit 1" "$rc" "1"
contains "plugin removed but still listed in marketplace.json: check 9 fails" "$out" "[FAIL] 9."

run_bump "$PR_SAME" "README.md"
contains "no plugin touched: check 9 passes" "$out" "[PASS] 9."

# --- 10. a PR that changes a GitHub Actions workflow needs a
# completed, successful workflow_dispatch run AT ITS HEAD. ci.yml has no push
# trigger, so the dispatch run is the only pre-merge test of the non-PR path.
# Fixtures are copied from the real environment: the workflow bodies are this
# repo's own .github/workflows files at HEAD, the run row is the shape
# `gh run list --workflow ci.yml --event workflow_dispatch --json
# databaseId,status,conclusion,headSha,event,workflowName` printed.
WF_REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
WFDIR="$tmp/wf"; RUNDIR="$tmp/runs"
mkdir -p "$WFDIR" "$RUNDIR"
git -C "$WF_REPO_ROOT" show HEAD:.github/workflows/ci.yml > "$WFDIR/ci.yml"
git -C "$WF_REPO_ROOT" show HEAD:.github/workflows/pr-title-lint.yml > "$WFDIR/pr-title-lint.yml"
git -C "$WF_REPO_ROOT" show HEAD:.github/workflows/ci-image.yml > "$WFDIR/ci-image.yml"
cp "$WFDIR/pr-title-lint.yml" "$WFDIR/new-thing.yml"
real_run() {  # <status> <conclusion> <headSha>
    printf '[{"conclusion":"%s","databaseId":38329960360,"event":"workflow_dispatch","headSha":"%s","status":"%s","workflowName":"CI"}]' "$2" "$3" "$1"
}
wf_run() {  # <files> [removed] -> rc/out
    reset_stubs
    STUB_FILES="$1"; STUB_FILE_STATUS="${2:-}"; STUB_WF_DIR="$WFDIR"; STUB_RUNS_DIR="$RUNDIR"
    rc=0; out="$(run)" || rc=$?
}

wf_run ".github/workflows/ci.yml"
check "workflow PR, no dispatch run: exit 1" "$rc" "1"
contains "workflow PR, no dispatch run: check 10 fails" "$out" "[FAIL] 10."
contains "workflow PR, no dispatch run: prints the dispatch command" "$out" "gh workflow run ci.yml --ref"

real_run completed success "$SHA" > "$RUNDIR/ci.yml.json"
wf_run ".github/workflows/ci.yml"
check "workflow PR, green dispatch at head: exit 0" "$rc" "0"
contains "workflow PR, green dispatch at head: check 10 passes" "$out" "[PASS] 10."

real_run completed success 915c81d1b19ee5df69793f327037e912a944957e > "$RUNDIR/ci.yml.json"
wf_run ".github/workflows/ci.yml"
check "workflow PR, dispatch at an OLDER sha: exit 1" "$rc" "1"
contains "workflow PR, dispatch at an OLDER sha: check 10 fails" "$out" "[FAIL] 10."

real_run completed failure "$SHA" > "$RUNDIR/ci.yml.json"
wf_run ".github/workflows/ci.yml"
check "workflow PR, failed dispatch at head: exit 1" "$rc" "1"
contains "workflow PR, failed dispatch at head: check 10 fails" "$out" "[FAIL] 10."

# A failed dispatch run passes as PRE-EXISTING only when every failed job of it
# also failed in main's latest scheduled/push run of the same workflow.
jobs_json() {  # <failed job name>... -> a `gh run view --json jobs` body
    local j
    printf '{"jobs":['
    for j in "$@"; do
        printf '{"name":"%s","conclusion":"failure"},' "$j"
    done
    printf '{"name":"lint","conclusion":"success"}]}'
}
main_run() {  # <event> <conclusion> <id>
    printf '[{"conclusion":"%s","databaseId":%s,"event":"%s","headSha":"deadbeef","status":"completed"}]' "$2" "$3" "$1"
}
printf '[{"conclusion":"failure","databaseId":111,"event":"workflow_dispatch","headSha":"%s","status":"completed"}]' "$SHA" > "$RUNDIR/ci.yml.json"
jobs_json "shell-unit (4/8)" "shell-unit (5/8)" > "$RUNDIR/jobs-111.json"
main_run schedule failure 222 > "$RUNDIR/ci.yml.main.json"
jobs_json "shell-unit (3/8)" "shell-unit (4/8)" "shell-unit (5/8)" > "$RUNDIR/jobs-222.json"
wf_run ".github/workflows/ci.yml"
check "dispatch fails only on suites already red on main: exit 0" "$rc" "0"
contains "dispatch fails only on suites already red on main: check 10 passes" "$out" "[PASS] 10."
contains "dispatch fails only on suites already red on main: PRE-EXISTING line" "$out" "PRE-EXISTING"
contains "dispatch fails only on suites already red on main: names the suites" "$out" "shell-unit (4/8), shell-unit (5/8)"
contains "dispatch fails only on suites already red on main: names both runs" "$out" "run 111"

jobs_json "shell-unit (4/8)" "shell-unit (6/8)" > "$RUNDIR/jobs-111.json"
wf_run ".github/workflows/ci.yml"
check "dispatch adds a new failing suite: exit 1" "$rc" "1"
contains "dispatch adds a new failing suite: check 10 fails" "$out" "[FAIL] 10."
contains "dispatch adds a new failing suite: names the new suite" "$out" "shell-unit (6/8)"
notcontains "dispatch adds a new failing suite: no PRE-EXISTING pass" "$out" "PRE-EXISTING"

printf '{"jobs":[{"name":"shell-unit (4/8)","conclusion":"failure"},{"name":"os-verify","conclusion":"timed_out"}]}' > "$RUNDIR/jobs-111.json"
wf_run ".github/workflows/ci.yml"
check "dispatch adds a new timed-out job: exit 1" "$rc" "1"
contains "dispatch adds a new timed-out job: names it" "$out" "os-verify"

jobs_json "shell-unit (4/8)" > "$RUNDIR/jobs-111.json"
main_run push success 222 > "$RUNDIR/ci.yml.main.json"
wf_run ".github/workflows/ci.yml"
check "main's latest run is green: failed dispatch still fails: exit 1" "$rc" "1"
rm -f "$RUNDIR/ci.yml.main.json"
wf_run ".github/workflows/ci.yml"
check "no main run to compare: failed dispatch still fails: exit 1" "$rc" "1"
main_run pull_request failure 222 > "$RUNDIR/ci.yml.main.json"
wf_run ".github/workflows/ci.yml"
check "main's only run is not scheduled/push: failed dispatch still fails: exit 1" "$rc" "1"
# Main's baseline counts only failure/timed_out jobs: a job main cancelled (a sibling red) never ran, so
# it must not excuse the same job failing on the PR.
printf '[{"conclusion":"failure","databaseId":111,"event":"workflow_dispatch","headSha":"%s","status":"completed"}]' "$SHA" > "$RUNDIR/ci.yml.json"
main_run schedule failure 222 > "$RUNDIR/ci.yml.main.json"
jobs_json "shell-unit (4/8)" "shell-unit (5/8)" > "$RUNDIR/jobs-111.json"
printf '{"jobs":[{"name":"shell-unit (4/8)","conclusion":"failure"},{"name":"shell-unit (5/8)","conclusion":"cancelled"}]}' > "$RUNDIR/jobs-222.json"
wf_run ".github/workflows/ci.yml"
check "main job cancelled, same job failed on the PR: exit 1" "$rc" "1"
contains "main job cancelled, same job failed on the PR: names the job" "$out" "shell-unit (5/8)"
notcontains "main job cancelled, same job failed on the PR: no PRE-EXISTING pass" "$out" "PRE-EXISTING"
printf '{"jobs":[{"name":"shell-unit (4/8)","conclusion":"timed_out"},{"name":"shell-unit (5/8)","conclusion":"failure"}]}' > "$RUNDIR/jobs-222.json"
wf_run ".github/workflows/ci.yml"
check "main job timed_out counts as red on main: exit 0" "$rc" "0"
contains "main job timed_out counts as red on main: PRE-EXISTING line" "$out" "PRE-EXISTING"

jobs_json "shell-unit (4/8)" > "$RUNDIR/jobs-222.json"
printf '{"jobs":[]}' > "$RUNDIR/jobs-111.json"
wf_run ".github/workflows/ci.yml"
check "PR run has no failed jobs in the read: exit 1" "$rc" "1"
printf 'not json' > "$RUNDIR/jobs-111.json"
wf_run ".github/workflows/ci.yml"
check "PR jobs read is unparsable: exit 1" "$rc" "1"
rm -f "$RUNDIR/jobs-111.json"
wf_run ".github/workflows/ci.yml"
check "PR jobs read fails: exit 1" "$rc" "1"
jobs_json "shell-unit (4/8)" > "$RUNDIR/jobs-111.json"
rm -f "$RUNDIR/jobs-222.json"
wf_run ".github/workflows/ci.yml"
check "main jobs read fails: exit 1" "$rc" "1"
contains "main jobs read fails: says so" "$out" "cannot read the failed jobs of main run 222"

jobs_json "shell-unit (4/8)" > "$RUNDIR/jobs-222.json"
main_run schedule timed_out 222 > "$RUNDIR/ci.yml.main.json"
wf_run ".github/workflows/ci.yml"
check "main's latest run timed out on the same suite: exit 0" "$rc" "0"
contains "main's latest run timed out on the same suite: PRE-EXISTING line" "$out" "PRE-EXISTING"
main_run schedule failure 222 > "$RUNDIR/ci.yml.main.json"
printf '[{"conclusion":"success","databaseId":333,"event":"push","headSha":"deadbeef","status":"completed"},{"conclusion":"failure","databaseId":222,"event":"schedule","headSha":"deadbeef","status":"completed"}]' > "$RUNDIR/ci.yml.main.json"
wf_run ".github/workflows/ci.yml"
check "main's newest run is green, an older one red: exit 1" "$rc" "1"
notcontains "main's newest run is green, an older one red: no PRE-EXISTING pass" "$out" "PRE-EXISTING"
rm -f "$RUNDIR/ci.yml.main.json" "$RUNDIR"/jobs-*.json

# A re-shard moves a suite that is already red on main to another job, so the job-name
# comparison reads it as new red. When it fails a job, the failed SUITES in the runs' logs
# (`<job>\t<step>\t<ts> [FAIL] <suite> (rc=..)`, the runner's own line) are compared instead: every
# new job must show failed suites, and all of them must also have failed somewhere on main. Names
# are the real case: main schedule run 40457809286 shard 3 vs PR 4197 dispatch run 40824556047 shard 8.
TT=scripts/lib/test-timeout-bin.sh
TTY=scripts/lib/test-other.sh
log_fail() {  # <job> <suite>... -> run-log lines for the failed suites of one job
    local j="$1" s
    shift
    for s in "$@"; do
        printf '%s\tRun suites\t2026-10-29T10:00:00.1234567Z [FAIL] %s (rc=1, 3s)\n' "$j" "$s"
        printf '%s\tRun suites\t2026-10-29T10:00:00.2234567Z     [FAIL] %s (indented tail echo)\n' "$j" "$s.echo"
    done
}
printf '[{"conclusion":"failure","databaseId":111,"event":"workflow_dispatch","headSha":"%s","status":"completed"}]' "$SHA" > "$RUNDIR/ci.yml.json"
main_run schedule failure 222 > "$RUNDIR/ci.yml.main.json"
jobs_json "macos / shell (8)" > "$RUNDIR/jobs-111.json"
jobs_json "macos / shell (3)" > "$RUNDIR/jobs-222.json"
log_fail "macos / shell (8)" "$TT" > "$RUNDIR/log-111.txt"
log_fail "macos / shell (3)" "$TT" > "$RUNDIR/log-222.txt"
wf_run ".github/workflows/ci.yml"
check "suite moved to another shard, red on main: exit 0" "$rc" "0"
contains "suite moved to another shard, red on main: check 10 passes" "$out" "[PASS] 10."
contains "suite moved to another shard, red on main: PRE-EXISTING line" "$out" "PRE-EXISTING"
contains "suite moved to another shard, red on main: names the suite" "$out" "$TT"
notcontains "suite moved to another shard: an indented echo is not a failed suite" "$out" "$TT.echo"

log_fail "macos / shell (8)" "$TT" "$TTY" > "$RUNDIR/log-111.txt"
wf_run ".github/workflows/ci.yml"
check "moved shard also fails a suite main does not: exit 1" "$rc" "1"
contains "moved shard also fails a suite main does not: check 10 fails" "$out" "[FAIL] 10."
contains "moved shard also fails a suite main does not: names the new suite" "$out" "$TTY"
notcontains "moved shard also fails a suite main does not: no PRE-EXISTING pass" "$out" "PRE-EXISTING"

rm -f "$RUNDIR/log-111.txt"
wf_run ".github/workflows/ci.yml"
check "PR run log unreadable: exit 1" "$rc" "1"
contains "PR run log unreadable: check 10 fails" "$out" "[FAIL] 10."
notcontains "PR run log unreadable: no PRE-EXISTING pass" "$out" "PRE-EXISTING"
log_fail "macos / shell (8)" "$TT" > "$RUNDIR/log-111.txt"
rm -f "$RUNDIR/log-222.txt"
wf_run ".github/workflows/ci.yml"
check "main run log unreadable: exit 1" "$rc" "1"
notcontains "main run log unreadable: no PRE-EXISTING pass" "$out" "PRE-EXISTING"
log_fail "macos / shell (3)" "$TT" > "$RUNDIR/log-222.txt"
printf 'macos / shell (8)\tRun suites\t2026-10-29T10:00:00.1Z setup failed, no suite ran\n' > "$RUNDIR/log-111.txt"
wf_run ".github/workflows/ci.yml"
check "new job's log names no failed suite: exit 1" "$rc" "1"
notcontains "new job's log names no failed suite: no PRE-EXISTING pass" "$out" "PRE-EXISTING"

# one job moved shard, another is red for a reason no suite line explains: the second keeps the FAIL
jobs_json "macos / shell (8)" "macos / shell (5)" > "$RUNDIR/jobs-111.json"
log_fail "macos / shell (8)" "$TT" > "$RUNDIR/log-111.txt"
wf_run ".github/workflows/ci.yml"
check "one moved job, one job with no failed suite in its log: exit 1" "$rc" "1"
notcontains "one moved job, one job with no failed suite in its log: no PRE-EXISTING pass" "$out" "PRE-EXISTING"

# the job-name comparison stays first: same job names on both runs pass with no log at all
jobs_json "macos / shell (3)" > "$RUNDIR/jobs-111.json"
rm -f "$RUNDIR/log-111.txt" "$RUNDIR/log-222.txt"
wf_run ".github/workflows/ci.yml"
check "same job red on both runs, no logs: exit 0 (job-name check first)" "$rc" "0"
contains "same job red on both runs, no logs: PRE-EXISTING line" "$out" "PRE-EXISTING"
rm -f "$RUNDIR/ci.yml.main.json" "$RUNDIR/ci.yml.json" "$RUNDIR"/jobs-*.json "$RUNDIR"/log-111.txt "$RUNDIR"/log-222.txt

# A merge-forward head carries no dispatch run of its own; its proof is a PRE-EXISTING-red dispatch
# run at an ANCESTOR commit on the PR branch, accepted only when every file the PR changes is the
# same blob at that ancestor and at the head. The run row is the shape `gh run list --workflow
# macos-cadence.yml --event workflow_dispatch --branch <pr branch> --json
# databaseId,status,conclusion,headSha,headBranch` printed for PR 3662 (headSha swapped for the
# fixture's ancestor); the job names are that run's real failed jobs.
ANC_WF=.github/workflows/macos-cadence.yml
ANC_PRFILE=scripts/pr-file.sh
ANC_OLD=scripts/old-name.sh
ANC_NEW=scripts/new-name.sh
ANC_BRANCH=fix/himmel-7245-macos-bsd-tools
git -C "$WF_REPO_ROOT" show HEAD:"$ANC_WF" > "$WFDIR/macos-cadence.yml"
anc_blob() { printf '%s\n' "$1" | git -C "$REPO" hash-object -w --stdin; }
anc_commit() {  # <parent|-> <workflow blob> <pr file blob> <main file blob> [<renamed-from blob> [<renamed-to blob>]] -> commit sha
    local idx="$tmp/anc.idx" tree
    rm -f "$idx"
    GIT_INDEX_FILE="$idx" git -C "$REPO" update-index --add --cacheinfo "100644,$2,$ANC_WF" --cacheinfo "100644,$3,$ANC_PRFILE" --cacheinfo "100644,$4,main-only.txt"
    [ -z "${5:-}" ] || GIT_INDEX_FILE="$idx" git -C "$REPO" update-index --add --cacheinfo "100644,$5,$ANC_OLD"
    [ -z "${6:-}" ] || GIT_INDEX_FILE="$idx" git -C "$REPO" update-index --add --cacheinfo "100644,$6,$ANC_NEW"
    tree=$(GIT_INDEX_FILE="$idx" git -C "$REPO" write-tree)
    if [ "$1" = - ]; then git -C "$REPO" commit-tree "$tree" -m "chore: fixture"; else git -C "$REPO" commit-tree "$tree" -p "$1" -m "chore: fixture"; fi
}
B_WF=$(anc_blob workflow-v1); B_WF2=$(anc_blob workflow-v2); B_PR1=$(anc_blob pr-file-v1); B_PR2=$(anc_blob pr-file-v2)
B_MAIN1=$(anc_blob main-v1); B_MAIN2=$(anc_blob main-v2)
ANC_BASE=$(anc_commit - "$B_WF" "$B_PR1" "$B_MAIN1")
ANC_COMMIT=$(anc_commit "$ANC_BASE" "$B_WF2" "$B_PR2" "$B_MAIN1")
ANC_HEAD_OK=$(anc_commit "$ANC_COMMIT" "$B_WF2" "$B_PR2" "$B_MAIN2")
ANC_HEAD_WF=$(anc_commit "$ANC_COMMIT" "$B_WF" "$B_PR2" "$B_MAIN2")
ANC_HEAD_PR=$(anc_commit "$ANC_COMMIT" "$B_WF2" "$B_PR1" "$B_MAIN2")
ANC_SIDE=$(anc_commit "$ANC_BASE" "$B_WF2" "$B_PR2" "$B_MAIN2")
# the PR renames old-name.sh to new-name.sh: a copy at the ancestor that the head deletes, and a rename done before the ancestor
B_OLD=$(anc_blob old-name-v1)
ANC_COPY=$(anc_commit "$ANC_BASE" "$B_WF2" "$B_PR2" "$B_MAIN1" "$B_OLD" "$B_OLD")
ANC_COPY_HEAD=$(anc_commit "$ANC_COPY" "$B_WF2" "$B_PR2" "$B_MAIN2" "" "$B_OLD")
ANC_MOVED=$(anc_commit "$ANC_BASE" "$B_WF2" "$B_PR2" "$B_MAIN1" "" "$B_OLD")
ANC_MOVED_HEAD=$(anc_commit "$ANC_MOVED" "$B_WF2" "$B_PR2" "$B_MAIN2" "" "$B_OLD")
anc_row() {  # <run id> <headSha> <headBranch> [<event>] -> a gh run list body
    printf '[{"conclusion":"failure","databaseId":%s,"event":"%s","headBranch":"%s","headSha":"%s","status":"completed"}]' "$1" "${4:-workflow_dispatch}" "$3" "$2"
}
anc_run() {  # <head commit> [rename] -> rc/out, the PR changing the workflow and a script (and renaming one when asked)
    ANC_REAL_SHA="$SHA"; SHA="$1"
    reset_stubs
    STUB_FILES="$ANC_WF
$ANC_PRFILE"; STUB_WF_DIR="$WFDIR"; STUB_RUNS_DIR="$RUNDIR"; STUB_PR_BRANCH="$ANC_BRANCH"
    if [ -n "${2:-}" ]; then STUB_FILES="$STUB_FILES
$ANC_NEW"; STUB_RENAMES="$ANC_NEW $ANC_OLD"; fi
    rc=0; out="$(run)" || rc=$?
    SHA="$ANC_REAL_SHA"
}
rm -f "$RUNDIR"/*.json
anc_row 40073661474 "$ANC_COMMIT" "$ANC_BRANCH" > "$RUNDIR/macos-cadence.yml.pr-branch.json"
jobs_json "macos-cadence / shell (macos-latest, 6)" "macos-cadence / shell (macos-latest, 3)" > "$RUNDIR/jobs-40073661474.json"
main_run schedule failure 39908051399 > "$RUNDIR/macos-cadence.yml.main.json"
jobs_json "macos-cadence / shell (macos-latest, 6)" "macos-cadence / shell (macos-latest, 3)" "macos-cadence / shell (macos-latest, 4)" > "$RUNDIR/jobs-39908051399.json"
anc_run "$ANC_HEAD_OK"
check "merge-forward head, pre-existing-red dispatch at the ancestor: exit 0" "$rc" "0"
contains "merge-forward head, pre-existing-red dispatch at the ancestor: check 10 passes" "$out" "[PASS] 10."
contains "merge-forward head, pre-existing-red dispatch at the ancestor: PRE-EXISTING line" "$out" "PRE-EXISTING"
contains "merge-forward head, pre-existing-red dispatch at the ancestor: names the ancestor" "$out" "$ANC_COMMIT"
contains "merge-forward head, pre-existing-red dispatch at the ancestor: names the run id" "$out" "40073661474"
anc_run "$ANC_HEAD_WF"
check "workflow file changed after the ancestor: exit 1" "$rc" "1"
contains "workflow file changed after the ancestor: check 10 fails" "$out" "[FAIL] 10."
notcontains "workflow file changed after the ancestor: no PRE-EXISTING pass" "$out" "PRE-EXISTING"
anc_run "$ANC_HEAD_PR"
check "another PR file changed after the ancestor: exit 1" "$rc" "1"
contains "another PR file changed after the ancestor: check 10 fails" "$out" "[FAIL] 10."
notcontains "another PR file changed after the ancestor: no PRE-EXISTING pass" "$out" "PRE-EXISTING"
anc_row 40073661474 "$ANC_SIDE" "$ANC_BRANCH" > "$RUNDIR/macos-cadence.yml.pr-branch.json"
anc_run "$ANC_HEAD_OK"
check "dispatch commit is not an ancestor of the head: exit 1" "$rc" "1"
contains "dispatch commit is not an ancestor of the head: check 10 fails" "$out" "[FAIL] 10."
notcontains "dispatch commit is not an ancestor of the head: no PRE-EXISTING pass" "$out" "PRE-EXISTING"
anc_row 40073661474 "$ANC_COMMIT" "$ANC_BRANCH" > "$RUNDIR/macos-cadence.yml.pr-branch.json"
real_run in_progress "" "$ANC_HEAD_OK" > "$RUNDIR/macos-cadence.yml.json"
anc_run "$ANC_HEAD_OK"
check "head has its own dispatch run still running: exit 1" "$rc" "1"
contains "head has its own dispatch run still running: check 10 fails" "$out" "[FAIL] 10."
notcontains "head has its own dispatch run still running: no PRE-EXISTING pass" "$out" "PRE-EXISTING"
real_run completed cancelled "$ANC_HEAD_OK" > "$RUNDIR/macos-cadence.yml.json"
anc_run "$ANC_HEAD_OK"
check "head has its own cancelled dispatch run: exit 1" "$rc" "1"
rm -f "$RUNDIR/macos-cadence.yml.json"
anc_row 40073661474 "$ANC_COMMIT" some-other/branch > "$RUNDIR/macos-cadence.yml.pr-branch.json"
anc_run "$ANC_HEAD_OK"
check "dispatch run is on another branch: exit 1" "$rc" "1"
contains "dispatch run is on another branch: check 10 fails" "$out" "[FAIL] 10."
notcontains "dispatch run is on another branch: no PRE-EXISTING pass" "$out" "PRE-EXISTING"
anc_row 40073661474 "$ANC_COMMIT" "$ANC_BRANCH" > "$RUNDIR/macos-cadence.yml.pr-branch.json"
jobs_json "macos-cadence / shell (macos-latest, 6)" "macos-cadence / shell (macos-latest, 9)" > "$RUNDIR/jobs-40073661474.json"
anc_run "$ANC_HEAD_OK"
check "ancestor dispatch fails a suite not red on main: exit 1" "$rc" "1"
contains "ancestor dispatch fails a suite not red on main: check 10 fails" "$out" "[FAIL] 10."
contains "ancestor dispatch fails a suite not red on main: names the run and main's run" "$out" "run 40073661474 failed on suites not red on main run 39908051399"
notcontains "ancestor dispatch fails a suite not red on main: no PRE-EXISTING pass" "$out" "PRE-EXISTING"
jobs_json "macos-cadence / shell (macos-latest, 6)" "macos-cadence / shell (macos-latest, 3)" > "$RUNDIR/jobs-40073661474.json"
anc_row 40073661474 "$ANC_COMMIT" "$ANC_BRANCH" push > "$RUNDIR/macos-cadence.yml.pr-branch.json"
anc_run "$ANC_HEAD_OK"
check "ancestor run is not a workflow_dispatch run: exit 1" "$rc" "1"
notcontains "ancestor run is not a workflow_dispatch run: no PRE-EXISTING pass" "$out" "PRE-EXISTING"
anc_row 40073661474 "$ANC_COPY" "$ANC_BRANCH" > "$RUNDIR/macos-cadence.yml.pr-branch.json"
anc_run "$ANC_COPY_HEAD" rename
check "renamed file was a copy at the ancestor, old path deleted at the head: exit 1" "$rc" "1"
contains "renamed file was a copy at the ancestor, old path deleted at the head: check 10 fails" "$out" "[FAIL] 10."
contains "renamed file was a copy at the ancestor, old path deleted at the head: names the old path" "$out" "$ANC_OLD"
notcontains "renamed file was a copy at the ancestor, old path deleted at the head: no PRE-EXISTING pass" "$out" "PRE-EXISTING"
anc_row 40073661474 "$ANC_MOVED" "$ANC_BRANCH" > "$RUNDIR/macos-cadence.yml.pr-branch.json"
anc_run "$ANC_MOVED_HEAD" rename
check "rename already done at the ancestor: exit 0" "$rc" "0"
contains "rename already done at the ancestor: PRE-EXISTING line" "$out" "PRE-EXISTING"
anc_row 40073661474 "$ANC_COPY" "$ANC_BRANCH" > "$RUNDIR/macos-cadence.yml.pr-branch.json"
ANC_REAL_SHA="$SHA"; SHA="$ANC_COPY_HEAD"; reset_stubs
STUB_FILES="$ANC_WF
$ANC_PRFILE"; STUB_WF_DIR="$WFDIR"; STUB_RUNS_DIR="$RUNDIR"; STUB_PR_BRANCH="$ANC_BRANCH"; STUB_RENAMES_FAIL=1
rc=0; out="$(run)" || rc=$?; SHA="$ANC_REAL_SHA"
check "renamed-from paths cannot be read: exit 1" "$rc" "1"
notcontains "renamed-from paths cannot be read: no PRE-EXISTING pass" "$out" "PRE-EXISTING"
anc_row 40073661474 "$ANC_COMMIT" "$ANC_BRANCH" > "$RUNDIR/macos-cadence.yml.pr-branch.json"
ANC_REAL_SHA="$SHA"; SHA="$ANC_HEAD_OK"; reset_stubs
STUB_FILES="$ANC_WF
$ANC_PRFILE"; STUB_WF_DIR="$WFDIR"; STUB_RUNS_DIR="$RUNDIR"; STUB_PR_BRANCH="$ANC_BRANCH"; STUB_FILES_PARTIAL=1
rc=0; out="$(run)" || rc=$?; SHA="$ANC_REAL_SHA"
check "PR file list dies mid-pagination: exit 1" "$rc" "1"
contains "PR file list dies mid-pagination: says the file list cannot be read" "$out" "cannot read PR files"
notcontains "PR file list dies mid-pagination: no PRE-EXISTING pass" "$out" "PRE-EXISTING"

# A merge-forward that edits ANOTHER hunk of a file the PR changes moves that file's blob,
# yet the PR's own patch to it is the same. History: M0 (main) <- PR1 (the dispatch commit, edits line 3)
# and M0 <- M1 (main edits line 28); the head merges M1 into PR1. origin/main is M1.
anc_merge() {  # <tree: workflow blob> <pr file blob> <main file blob> <parent 1> <parent 2> -> a merge commit
    local c
    c=$(anc_commit - "$1" "$2" "$3")
    git -C "$REPO" commit-tree "$c^{tree}" -p "$4" -p "$5" -m "Merge fixture"
}
P0=$(seq 1 30 | sed 's/^/line /')
B_P0=$(anc_blob "$P0")
B_PPR=$(anc_blob "$(printf '%s\n' "$P0" | sed '3s/.*/line 3 pr/')")
B_PMAIN=$(anc_blob "$(printf '%s\n' "$P0" | sed '28s/.*/line 28 main/')")
B_PBOTH=$(anc_blob "$(printf '%s\n' "$P0" | sed -e '3s/.*/line 3 pr/' -e '28s/.*/line 28 main/')")
B_PEDIT=$(anc_blob "$(printf '%s\n' "$P0" | sed -e '3s/.*/line 3 pr, edited after the dispatch/' -e '28s/.*/line 28 main/')")
HP_M0=$(anc_commit - "$B_WF" "$B_P0" "$B_MAIN1")
HP_PR1=$(anc_commit "$HP_M0" "$B_WF2" "$B_PPR" "$B_MAIN1")
HP_M1=$(anc_commit "$HP_M0" "$B_WF" "$B_PMAIN" "$B_MAIN2")
HP_HEAD=$(anc_merge "$B_WF2" "$B_PBOTH" "$B_MAIN2" "$HP_PR1" "$HP_M1")
HP_HEAD_EDIT=$(anc_commit "$HP_HEAD" "$B_WF2" "$B_PEDIT" "$B_MAIN2")
B_PWS=$(anc_blob "$(printf '%s\n' "$P0" | sed -e '3s/.*/line  3 pr/' -e '28s/.*/line 28 main/')")
HP_HEAD_WS=$(anc_commit "$HP_HEAD" "$B_WF2" "$B_PWS" "$B_MAIN2")
B_PDIGIT=$(anc_blob "$(printf '%s\n' "$P0" | sed -e '3s/.*/line 5 pr/' -e '28s/.*/line 28 main/')")
HP_HEAD_DIGIT=$(anc_commit "$HP_HEAD" "$B_WF2" "$B_PDIGIT" "$B_MAIN2")
HP_ORPHAN=$(anc_commit - "$B_WF" "$B_P0" "$B_MAIN2")
ANC_ORIGIN="$tmp/anc-origin.git"
git init -q --bare "$ANC_ORIGIN"
git -C "$REPO" remote add origin "$ANC_ORIGIN"
anc_main() { git -C "$REPO" push -q -f origin "$1:refs/heads/main"; }  # <commit> -> origin/main
anc_row 40073661474 "$HP_PR1" "$ANC_BRANCH" > "$RUNDIR/macos-cadence.yml.pr-branch.json"
anc_main "$HP_M1"
anc_run "$HP_HEAD"
check "merge-forward edits another hunk of a PR file: exit 0" "$rc" "0"
contains "merge-forward edits another hunk of a PR file: check 10 passes" "$out" "[PASS] 10."
contains "merge-forward edits another hunk of a PR file: PRE-EXISTING line" "$out" "PRE-EXISTING"
contains "merge-forward edits another hunk of a PR file: names the ancestor" "$out" "$HP_PR1"
anc_run "$HP_HEAD_EDIT"
check "the PR's own hunk edited after the dispatch: exit 1" "$rc" "1"
contains "the PR's own hunk edited after the dispatch: check 10 fails" "$out" "[FAIL] 10."
notcontains "the PR's own hunk edited after the dispatch: no PRE-EXISTING pass" "$out" "PRE-EXISTING"
anc_run "$HP_HEAD_WS"
check "the PR's own hunk changed only in whitespace after the dispatch: exit 1" "$rc" "1"
contains "the PR's own hunk changed only in whitespace after the dispatch: check 10 fails" "$out" "[FAIL] 10."
notcontains "the PR's own hunk changed only in whitespace after the dispatch: no PRE-EXISTING pass" "$out" "PRE-EXISTING"
git -C "$REPO" config diff.lossy.textconv "sed s/[0-9]//g"
printf '%s diff=lossy\n' "$ANC_PRFILE" > "$REPO/.gitattributes"
anc_run "$HP_HEAD_DIGIT"
rm -f "$REPO/.gitattributes"
git -C "$REPO" config --unset diff.lossy.textconv
check "a textconv driver hides the PR's own edit after the dispatch: exit 1" "$rc" "1"
contains "a textconv driver hides the PR's own edit after the dispatch: check 10 fails" "$out" "[FAIL] 10."
notcontains "a textconv driver hides the PR's own edit after the dispatch: no PRE-EXISTING pass" "$out" "PRE-EXISTING"
anc_main "$HP_ORPHAN"
anc_run "$HP_HEAD"
check "no merge-base with origin/main: exit 1" "$rc" "1"
contains "no merge-base with origin/main: check 10 fails" "$out" "[FAIL] 10."
notcontains "no merge-base with origin/main: no PRE-EXISTING pass" "$out" "PRE-EXISTING"
git -C "$REPO" remote remove origin
anc_run "$HP_HEAD"
check "origin/main cannot be fetched: exit 1" "$rc" "1"
notcontains "origin/main cannot be fetched: no PRE-EXISTING pass" "$out" "PRE-EXISTING"
rm -f "$RUNDIR"/*.json

real_run in_progress "" "$SHA" > "$RUNDIR/ci.yml.json"
wf_run ".github/workflows/ci.yml"
check "workflow PR, dispatch still running: exit 1" "$rc" "1"
contains "workflow PR, dispatch still running: check 10 fails" "$out" "[FAIL] 10."

real_run completed success "$SHA" > "$RUNDIR/ci.yml.json"
reset_stubs; STUB_FILES=".github/workflows/ci.yml"; STUB_WF_DIR="$WFDIR"; STUB_RUNS_DIR="$RUNDIR"; STUB_RUNS_FAIL=1
rc=0; out="$(run)" || rc=$?
check "workflow PR, run list errors: exit 1 (fail closed)" "$rc" "1"
contains "workflow PR, run list errors: check 10 fails" "$out" "[FAIL] 10."

# --- 10b. macos-cadence: a dispatch run that names its suites (run-name
# "macos-cadence suites: <paths>") passes on per-suite [PASS] lines even when the
# whole run is red. Log lines are copied from the real macos-cadence dispatch
# run 39993677203 (shard 4): `gh run view --log` prints
# `<job>\t<step>\t<timestamp> [PASS] <suite> (<n>s)`.
git -C "$WF_REPO_ROOT" show HEAD:.github/workflows/macos-cadence.yml > "$WFDIR/macos-cadence.yml"
MAC_A="marketplace/plugins/handover/scripts/test-skill-e2e.sh"
MAC_B="marketplace/plugins/obsidian-triage/tests/test-dedup-sweep.sh"
MAC_F="marketplace/plugins/himmel-ops/scripts/test-ticket-standard-check.sh"
TAB="$(printf '\t')"
cat > "$RUNDIR/log-501.txt" <<LOG
macos-cadence / shell (macos-latest, 4)${TAB}UNKNOWN STEP${TAB}2026-10-23T19:04:00.9019890Z [PASS] $MAC_A (1s)
macos-cadence / shell (macos-latest, 4)${TAB}UNKNOWN STEP${TAB}2026-10-23T19:04:10.4993560Z [FAIL] $MAC_F (rc=1, 2s)
macos-cadence / shell (macos-latest, 4)${TAB}UNKNOWN STEP${TAB}2026-10-23T19:04:14.6497350Z [PASS] $MAC_B (1s)
LOG
mac_run() {  # <conclusion> <displayTitle> <headSha> [id]
    printf '[{"conclusion":"%s","databaseId":%s,"displayTitle":"%s","event":"workflow_dispatch","headSha":"%s","status":"completed"}]' "$1" "${4:-501}" "$2" "$3"
}
mac_wf_run() {  # [extra changed files, newline-separated] [the workflow's patch file] -> rc/out
    reset_stubs
    STUB_FILES=".github/workflows/macos-cadence.yml${1:+
$1}"; STUB_FILE_STATUS=""; STUB_WF_DIR="$WFDIR"; STUB_RUNS_DIR="$RUNDIR"; STUB_WF_PATCH_FILE="${2:-$RUNDIR/wiring.patch}"
    rc=0; out="$(run)" || rc=$?
}
# the `patch` field of the real macos-cadence.yml diff this PR makes: the suites wiring and nothing else
cat > "$RUNDIR/wiring.patch" <<'PATCH'
@@ -19,8 +19,24 @@ name: "CI (os:macos cadence)"
 # and both jobs are skipped for any PR without it. A PR run never records
 # breakages (the record belongs to main). Dispatch (needs this file on main):
 #   gh workflow run macos-cadence.yml --ref main
+#
+# A fix PR proves only ITS suites. Dispatch with `suites` set (space-
+# separated repo-relative test-*.sh paths) and ONE runner runs just those via
+# run-shell-tests.sh --only-list, in minutes instead of the 8-shard hour-plus run:
+#   gh workflow run macos-cadence.yml --ref <branch> -f suites="<path> <path>"
+# The run-name carries the list, and ready-check.sh item 10 accepts the run when
+# the log shows [PASS] for every named suite (however red the rest). Empty
+# `suites` = the unchanged full cadence. A filtered run records no breakage
+# metric: its partial suite set would read the unlisted suites as fixed.
+run-name: "${{ inputs.suites != '' && format('macos-cadence suites: {0}', inputs.suites) || 'CI (os:macos cadence)' }}"
 on:
   workflow_dispatch:
+    inputs:
+      suites:
+        description: 'Space-separated repo-relative suite paths; set = run only these on one runner'
+        required: false
+        default: ''
+        type: string
   pull_request:
     types: [labeled, synchronize]
   schedule:
@@ -47,7 +63,8 @@ jobs:
         # `/8` in the run step and `--shards-expected 8` in `summary` are three
         # spellings of one number and must agree (pinned by
         # test-macos-cadence-workflow.sh).
-        shard: [1, 2, 3, 4, 5, 6, 7, 8]
+        # A `suites` dispatch needs one runner, not eight.
+        shard: ${{ fromJSON(inputs.suites == '' && '[1, 2, 3, 4, 5, 6, 7, 8]' || '[1]') }}
     runs-on: ${{ matrix.os }}
     # No continue-on-error: a red macOS shard reddens THIS run and nothing else.
     # The cap only bounds a hung suite.
@@ -65,11 +82,26 @@ jobs:
         run: python -m pip install --disable-pip-version-check --require-hashes -r .github/ci-image/requirements-ci.txt
       # SUITE_TIER_MODE=all: the whole corpus, extended tier included -- the
       # coverage the nightly's macOS workers had.
+      # A `suites` dispatch: the input reaches the shell through SUITES (never
+      # interpolated into the script), each word is checked to be a plain
+      # repo-relative path, and --only-list runs just those suites.
       - id: tests
-        run: bash scripts/ci/run-shell-tests.sh --shard ${{ matrix.shard }}/8 .
+        run: |
+          if [ -n "$SUITES" ]; then
+            set -f
+            printf '%s\n' $SUITES > macos-suites.txt
+            if grep -qvE '^[A-Za-z0-9_./-]+$' macos-suites.txt || grep -q '\.\.' macos-suites.txt; then
+              echo "::error::suites must be plain repo-relative paths"
+              exit 2
+            fi
+            bash scripts/ci/run-shell-tests.sh --only-list macos-suites.txt .
+          else
+            bash scripts/ci/run-shell-tests.sh --shard ${{ matrix.shard }}/8 .
+          fi
         env:
           FAIL_LOG_DIR: failed-suite-logs
           SUITE_TIER_MODE: all
+          SUITES: ${{ inputs.suites }}
       # Even when the run step above went red: this is the per-shard input to
       # the breakage metric. Skipped when setup died before the tests ran, so
       # `summary` sees a missing report (infra_suspect), not an empty one.
@@ -119,7 +151,7 @@ jobs:
     steps:
       - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
       - name: Record breakages against the previous cadence run
-        if: github.event_name != 'pull_request'
+        if: github.event_name != 'pull_request' && inputs.suites == ''
         # shell: bash = `bash -e -o pipefail`: without it the step's status is
         # tee's and a die inside `record` (rc 2) would go green.
         shell: bash
@@ -150,7 +182,7 @@ jobs:
             --shards-expected 8 --failed-dir failed-artifacts $prev \
             --out record.json | tee -a "$GITHUB_STEP_SUMMARY"
       - name: Upload breakage record
-        if: always() && github.event_name != 'pull_request'
+        if: always() && github.event_name != 'pull_request' && inputs.suites == ''
         uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2
         with:
           name: macos-breakage-record
PATCH

mac_run failure "macos-cadence suites: $MAC_A $MAC_B" "$SHA" > "$RUNDIR/macos-cadence.yml.json"
mac_wf_run
check "macos-cadence suites run, red overall, named suites PASS: exit 0" "$rc" "0"
contains "macos-cadence suites run: check 10 passes" "$out" "[PASS] 10."
contains "macos-cadence suites run: prints per-suite evidence for a" "$out" "PASS $MAC_A"
contains "macos-cadence suites run: prints per-suite evidence for b" "$out" "PASS $MAC_B"
contains "macos-cadence suites run: names the run" "$out" "501"

mac_run failure "macos-cadence suites: $MAC_A $MAC_F" "$SHA" > "$RUNDIR/macos-cadence.yml.json"
mac_wf_run
check "macos-cadence suites run, a named suite FAILED: exit 1" "$rc" "1"
contains "macos-cadence suites run, named suite failed: check 10 fails" "$out" "[FAIL] 10."
contains "macos-cadence suites run, named suite failed: names it" "$out" "$MAC_F"

mac_run failure "macos-cadence suites: $MAC_A marketplace/plugins/x/test-absent.sh" "$SHA" > "$RUNDIR/macos-cadence.yml.json"
mac_wf_run
check "macos-cadence suites run, a named suite MISSING from the log: exit 1" "$rc" "1"
contains "macos-cadence suites run, named suite missing: names it" "$out" "test-absent.sh"

mac_run failure "CI (os:macos cadence)" "$SHA" > "$RUNDIR/macos-cadence.yml.json"
mac_wf_run
check "macos-cadence unfiltered red run: still exit 1" "$rc" "1"

mac_run failure "macos-cadence suites: $MAC_A" 915c81d1b19ee5df69793f327037e912a944957e > "$RUNDIR/macos-cadence.yml.json"
mac_wf_run
check "macos-cadence suites run at an OLDER sha: exit 1" "$rc" "1"

mac_run failure "macos-cadence suites: $MAC_A" "$SHA" 502 > "$RUNDIR/macos-cadence.yml.json"
mac_wf_run
check "macos-cadence suites run, log unreadable: exit 1 (fail closed)" "$rc" "1"

mac_run failure "macos-cadence suites: " "$SHA" > "$RUNDIR/macos-cadence.yml.json"
mac_wf_run
check "macos-cadence suites run naming nothing: exit 1" "$rc" "1"

mac_run failure "macos-cadence suites: ${MAC_A}x" "$SHA" > "$RUNDIR/macos-cadence.yml.json"
mac_wf_run
check "macos-cadence suites run, name only a prefix of a logged suite: exit 1" "$rc" "1"

# run-shell-tests.sh forwards the last 100 lines of a FAILED suite indented by four spaces, so a
# failed suite can print a PASS line of its own; only the runner's unindented line is proof.
cat > "$RUNDIR/log-503.txt" <<LOG
macos-cadence / shell (macos-latest, 4)${TAB}UNKNOWN STEP${TAB}2026-10-23T19:04:00.9019890Z [PASS] $MAC_A (1s)
macos-cadence / shell (macos-latest, 4)${TAB}UNKNOWN STEP${TAB}2026-10-23T19:04:10.4993560Z [FAIL] $MAC_F (rc=1, 2s)
macos-cadence / shell (macos-latest, 4)${TAB}UNKNOWN STEP${TAB}2026-10-23T19:04:10.4993570Z ----- last 100 lines -----
macos-cadence / shell (macos-latest, 4)${TAB}UNKNOWN STEP${TAB}2026-10-23T19:04:10.4993580Z     [PASS] $MAC_F (1s)
macos-cadence / shell (macos-latest, 4)${TAB}UNKNOWN STEP${TAB}2026-10-23T19:04:10.4993590Z     2026-10-23T19:04:00.0000000Z [PASS] $MAC_F (1s)
LOG
mac_run failure "macos-cadence suites: $MAC_A $MAC_F" "$SHA" 503 > "$RUNDIR/macos-cadence.yml.json"
mac_wf_run
check "macos-cadence suites run, a failed suite ECHOED a PASS line: exit 1" "$rc" "1"
contains "macos-cadence suites run, echoed PASS line: names the failed suite" "$out" "$MAC_F"

# A green run is judged per suite too: --only-list exits 0 when a named path matched no suite.
cat > "$RUNDIR/log-504.txt" <<LOG
macos-cadence / shell (macos-latest, 4)${TAB}UNKNOWN STEP${TAB}2026-10-23T19:04:00.9019890Z [PASS] $MAC_A (1s)
LOG
mac_run success "macos-cadence suites: $MAC_A marketplace/plugins/x/test-absent.sh" "$SHA" 504 > "$RUNDIR/macos-cadence.yml.json"
mac_wf_run
check "macos-cadence GREEN suites run, a named suite never ran: exit 1" "$rc" "1"
contains "macos-cadence GREEN suites run, a named suite never ran: names it" "$out" "test-absent.sh"
mac_run success "macos-cadence suites: $MAC_A" "$SHA" 504 > "$RUNDIR/macos-cadence.yml.json"
mac_wf_run
check "macos-cadence GREEN suites run, every named suite PASS: exit 0" "$rc" "0"
contains "macos-cadence GREEN suites run: prints per-suite evidence" "$out" "PASS $MAC_A"

# A named suite must be a whole `[PASS] <suite> (` line, not the front of a longer logged name.
cat > "$RUNDIR/log-506.txt" <<LOG
macos-cadence / shell (macos-latest, 4)${TAB}UNKNOWN STEP${TAB}2026-10-23T19:04:00.9019890Z [PASS] ${MAC_A}x (1s)
LOG
mac_run failure "macos-cadence suites: $MAC_A" "$SHA" 506 > "$RUNDIR/macos-cadence.yml.json"
mac_wf_run
check "macos-cadence suites run, the log only has a longer name that starts with the named one: exit 1" "$rc" "1"

# The named suites must cover every suite the PR changes: one unrelated green suite proves nothing
# about a changed suite that never ran.
mac_run failure "macos-cadence suites: $MAC_A $MAC_B" "$SHA" > "$RUNDIR/macos-cadence.yml.json"
mac_wf_run "scripts/ci/test-unnamed-suite.sh"
check "macos-cadence suites run does not name a suite the PR changes: exit 1" "$rc" "1"
contains "macos-cadence suites run, changed suite not named: check 10 fails" "$out" "[FAIL] 10."
contains "macos-cadence suites run, changed suite not named: names it" "$out" "test-unnamed-suite.sh"
cat > "$RUNDIR/log-507.txt" <<LOG
macos-cadence / shell (macos-latest, 1)${TAB}UNKNOWN STEP${TAB}2026-10-23T19:04:00.9019890Z [PASS] scripts/ci/test-unnamed-suite.sh (1s)
LOG
mac_run failure "macos-cadence suites: $MAC_A scripts/ci/test-unnamed-suite.sh" "$SHA" 507 > "$RUNDIR/macos-cadence.yml.json"
cat "$RUNDIR/log-501.txt" >> "$RUNDIR/log-507.txt"
mac_wf_run "scripts/ci/test-unnamed-suite.sh"
check "macos-cadence suites run names the suite the PR changes: exit 0" "$rc" "0"
mac_run failure "macos-cadence suites: $MAC_A $MAC_B" "$SHA" > "$RUNDIR/macos-cadence.yml.json"
mac_wf_run "docs/internals/testing.md"
check "macos-cadence suites run, the PR changes a file that is no suite: exit 0" "$rc" "0"

# The route is only for a workflow diff that is the suites wiring: any other edit needs an unfiltered dispatch.
{ cat "$RUNDIR/wiring.patch"; printf '+  permissions: write-all\n'; } > "$RUNDIR/broad-added.patch"
{ cat "$RUNDIR/wiring.patch"; printf -- '-    timeout-minutes: 120\n'; } > "$RUNDIR/broad-removed.patch"
sed -e "s/^+        if: github.event_name != 'pull_request' && inputs.suites == ''/+        if: true \&\& inputs.suites == ''/" "$RUNDIR/wiring.patch" > "$RUNDIR/broad-changed.patch"
mac_wf_run "" "$RUNDIR/broad-added.patch"
check "macos-cadence suites run, workflow diff adds a line beyond the wiring: exit 1" "$rc" "1"
contains "macos-cadence suites run, workflow diff beyond the wiring: check 10 fails" "$out" "[FAIL] 10."
contains "macos-cadence suites run, workflow diff beyond the wiring: names the line" "$out" "permissions: write-all"
mac_wf_run "" "$RUNDIR/broad-removed.patch"
check "macos-cadence suites run, workflow diff removes a line beyond the wiring: exit 1" "$rc" "1"
contains "macos-cadence suites run, workflow diff removes a line: names it" "$out" "timeout-minutes: 120"
{ cat "$RUNDIR/wiring.patch"; printf '+  permissions: write-all # suites\n'; } > "$RUNDIR/broad-tagged.patch"
mac_wf_run "" "$RUNDIR/broad-tagged.patch"
check "macos-cadence suites run, an unrelated added line that merely mentions suites: exit 1" "$rc" "1"
contains "macos-cadence suites run, an unrelated line that mentions suites: names the line" "$out" "permissions: write-all # suites"
{ cat "$RUNDIR/wiring.patch"; printf -- '-    some-removed-key: that mentions suites\n'; } > "$RUNDIR/broad-removed-tagged.patch"
mac_wf_run "" "$RUNDIR/broad-removed-tagged.patch"
check "macos-cadence suites run, an unrelated removed line that merely mentions suites: exit 1" "$rc" "1"
mac_wf_run "" "$RUNDIR/broad-changed.patch"
check "macos-cadence suites run, an if: line rewritten beyond the suites clause: exit 1" "$rc" "1"
mac_wf_run "" "$RUNDIR/nonexistent.patch"
check "macos-cadence suites run, the workflow diff cannot be read: exit 1 (fail closed)" "$rc" "1"
: > "$RUNDIR/empty.patch"
mac_wf_run "" "$RUNDIR/empty.patch"
check "macos-cadence suites run, the workflow diff is empty (too large for the API): exit 1" "$rc" "1"
# the refusal is final: main's red shard 1 does not make a suites run PRE-EXISTING
main_run schedule failure 222 > "$RUNDIR/macos-cadence.yml.main.json"
jobs_json "macos-cadence / shell (macos-latest, 1)" > "$RUNDIR/jobs-222.json"
jobs_json "macos-cadence / shell (macos-latest, 1)" > "$RUNDIR/jobs-501.json"
mac_run failure "macos-cadence suites: $MAC_A" "$SHA" > "$RUNDIR/macos-cadence.yml.json"
mac_wf_run "" "$RUNDIR/broad-added.patch"
check "macos-cadence suites run refused for its workflow diff, main red on shard 1: exit 1" "$rc" "1"
notcontains "macos-cadence suites run refused for its workflow diff: no PRE-EXISTING pass" "$out" "PRE-EXISTING"
contains "macos-cadence suites run refused, no full run beside it: keeps the refusal's reason" "$out" "changes more than the suites wiring"
# the refusal is final for the suites run only: a separate full dispatch run at the head is still judged
# against main on its own, and a suites run is never the run that gets judged that way
printf '[{"conclusion":"failure","databaseId":501,"displayTitle":"macos-cadence suites: %s","event":"workflow_dispatch","headSha":"%s","status":"completed"},{"conclusion":"failure","databaseId":601,"displayTitle":"CI (os:macos cadence)","event":"workflow_dispatch","headSha":"%s","status":"completed"}]' "$MAC_A" "$SHA" "$SHA" > "$RUNDIR/macos-cadence.yml.json"
jobs_json "macos-cadence / shell (macos-latest, 8)" > "$RUNDIR/jobs-601.json"
jobs_json "macos-cadence / shell (macos-latest, 3)" > "$RUNDIR/jobs-222.json"
log_fail "macos-cadence / shell (macos-latest, 8)" "$TT" > "$RUNDIR/log-601.txt"
log_fail "macos-cadence / shell (macos-latest, 3)" "$TT" > "$RUNDIR/log-222.txt"
mac_wf_run "" "$RUNDIR/broad-added.patch"
check "refused suites run beside a full run red only where main is: exit 0" "$rc" "0"
contains "refused suites run beside a full run red only where main is: check 10 passes" "$out" "[PASS] 10."
contains "refused suites run beside a full run red only where main is: PRE-EXISTING line" "$out" "PRE-EXISTING"
contains "refused suites run beside a full run red only where main is: judges the full run" "$out" "run 601"
contains "refused suites run beside a full run red only where main is: names the suite" "$out" "$TT"
log_fail "macos-cadence / shell (macos-latest, 8)" "$TT" "$TTY" > "$RUNDIR/log-601.txt"
mac_wf_run "" "$RUNDIR/broad-added.patch"
check "refused suites run beside a full run with a new failed suite: exit 1" "$rc" "1"
contains "refused suites run beside a full run with a new failed suite: check 10 fails" "$out" "[FAIL] 10."
contains "refused suites run beside a full run with a new failed suite: names the new suite" "$out" "$TTY"
notcontains "refused suites run beside a full run with a new failed suite: no PRE-EXISTING pass" "$out" "PRE-EXISTING"
rm -f "$RUNDIR/macos-cadence.yml.main.json" "$RUNDIR"/jobs-*.json "$RUNDIR"/log-601.txt "$RUNDIR"/log-222.txt

mac_run failure "macos-cadence suites: $MAC_A" "$SHA" > "$RUNDIR/ci.yml.json"
wf_run ".github/workflows/ci.yml"
check "a suites-titled red run of ANOTHER workflow gets no per-suite pass: exit 1" "$rc" "1"
rm -f "$RUNDIR/macos-cadence.yml.json" "$RUNDIR"/log-*.txt "$RUNDIR/ci.yml.json" "$RUNDIR"/*.patch

: > "$GH_LOG"
wf_run "scripts/handover/chief-kit/ready-check.sh"
check "non-workflow PR: exit 0" "$rc" "0"
contains "non-workflow PR: check 10 not applicable" "$out" "[PASS] 10."
notcontains "non-workflow PR: no run list issued" "$(cat "$GH_LOG")" "run list"

wf_run ".github/workflows/new-thing.yml"
check "workflow with no workflow_dispatch trigger: exit 1" "$rc" "1"
contains "workflow with no workflow_dispatch trigger: check 10 fails" "$out" "[FAIL] 10."
contains "workflow with no workflow_dispatch trigger: names the missing trigger" "$out" "no workflow_dispatch trigger"

wf_run ".github/workflows/pr-title-lint.yml"
check "exempted workflow without a trigger: exit 0" "$rc" "0"
contains "exempted workflow without a trigger: check 10 passes" "$out" "[PASS] 10."

wf_run ".github/workflows/ci-image.yml"
check "exempted workflow with a trigger, no dispatch run: exit 0" "$rc" "0"
contains "exempted workflow with a trigger, no dispatch run: check 10 passes" "$out" "[PASS] 10."

# Not on the list, though its name matches an entry as a regex: a skipped
# branch dispatch still fails.
cp "$WFDIR/ci-image.yml" "$WFDIR/ci.image.yml"
real_run completed skipped "$SHA" > "$RUNDIR/ci.image.yml.json"
wf_run ".github/workflows/ci.image.yml"
check "unlisted workflow with a trigger, skipped dispatch at head: exit 1" "$rc" "1"
contains "unlisted workflow with a trigger, skipped dispatch at head: check 10 fails" "$out" "[FAIL] 10."
contains "unlisted workflow with a trigger, skipped dispatch at head: fails on the run, not the trigger" "$out" "ci.image.yml has no completed successful workflow_dispatch run"

wf_run ".github/workflows/ci.yml" "removed .github/workflows/ci.yml"
contains "workflow deleted by the PR: check 10 passes" "$out" "[PASS] 10."

# A workflow the PR ADDS (or renames to) is not on the default branch, and GitHub
# only dispatches a workflow that exists there, so it cannot be dispatched yet.
rm -f "$RUNDIR"/*.json
cp "$WFDIR/ci.yml" "$WFDIR/brand-new.yml"
UNW_REAL_SHA="$SHA"
SHA=$(git -C "$REPO" rev-parse HEAD)  # check 11 now reads the head even when nothing judgeable is added
wf_run ".github/workflows/brand-new.yml" "added .github/workflows/brand-new.yml"
SHA="$UNW_REAL_SHA"
check "workflow added by the PR: exit 0" "$rc" "0"
contains "workflow added by the PR: check 10 passes" "$out" "[PASS] 10."
wf_run ".github/workflows/brand-new.yml" "renamed .github/workflows/brand-new.yml"
contains "workflow renamed by the PR: check 10 passes" "$out" "[PASS] 10."
wf_run ".github/workflows/brand-new.yml" "modified .github/workflows/brand-new.yml"
check "workflow modified (not added) still needs a dispatch run: exit 1" "$rc" "1"

# --- 11. a PR that ADDS a hook/script/skill/suite nothing reaches ---
# Each scenario commits into the throwaway REPO on top of a base that carries the
# real hook-wiring list; SHA is that commit, so the item reads its tree.
UNW_REAL_SHA="$SHA"
mkdir -p "$REPO/scripts/testing" "$REPO/scripts/hooks" "$REPO/.claude" "$REPO/.github/workflows"
cp "$HERE/../../testing/check-unwired-hooks.sh" "$REPO/scripts/testing/"
mkdir -p "$REPO/scripts/ci" && cp "$HERE/../../ci/run-shell-tests.sh" "$REPO/scripts/ci/"
printf '{}\n' > "$REPO/.claude/settings.json"
printf '# allowlist\n' > "$REPO/scripts/testing/unwired-hooks-allowlist.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m "chore: base for check 11"
UNW_BASE=$(git -C "$REPO" rev-parse HEAD)

# unw_run <added path>... — files are created empty-ish, committed, judged as status A
unw_run() {
    git -C "$REPO" checkout -q --detach "$UNW_BASE" && git -C "$REPO" clean -fdq
    local f st=""
    for f in "$@"; do
        mkdir -p "$REPO/${f%/*}"
        [ -f "$REPO/$f" ] || printf '#!/usr/bin/env bash\n' > "$REPO/$f"
        st="$st"$'added '"$f"$'\n'
    done
    mkdir -p "$REPO/.github/workflows" "$REPO/scripts/tools" "$REPO/scripts/lib"
    [ -z "${UNW_EXTRA:-}" ] || eval "$UNW_EXTRA"
    git -C "$REPO" add -A && git -C "$REPO" commit -q -m "feat: [HIMMEL-1] scenario"
    SHA=$(git -C "$REPO" rev-parse HEAD)
    seed_ledger_ok
    reset_stubs
    STUB_HEAD="$SHA"; STUB_FILES="$(printf '%s\n' "$@")"; STUB_FILE_STATUS="${st%$'\n'}"
    rc=0; out="$(run)" || rc=$?
    SHA="$UNW_REAL_SHA"
}

# RED: the hook is added and no wiring file names it
UNW_EXTRA=''
unw_run scripts/hooks/new-hook.sh
check "unwired hook: exit 1" "$rc" "1"
contains "unwired hook: check 11 fails" "$out" "[FAIL] 11."
contains "unwired hook: names the file" "$out" "scripts/hooks/new-hook.sh"

# the same hook, wired in a file of the WIRING list in the same diff
UNW_EXTRA="printf '{\"hooks\":\"scripts/hooks/new-hook.sh\"}\n' > \"\$REPO/.claude/settings.json\""
unw_run scripts/hooks/new-hook.sh
check "wired hook: exit 0" "$rc" "0"
contains "wired hook: check 11 passes" "$out" "[PASS] 11."

# a hook-name in a prefixed basename is not a registration
UNW_EXTRA="printf '{\"hooks\":\"scripts/hooks/not-new-hook.sh\"}\n' > \"\$REPO/.claude/settings.json\""
unw_run scripts/hooks/new-hook.sh
contains "hook wiring is whole-basename: check 11 fails" "$out" "[FAIL] 11."

# an explicitly allowlisted hook
UNW_EXTRA="printf 'new-hook.sh|ships unwired on purpose\n' >> \"\$REPO/scripts/testing/unwired-hooks-allowlist.txt\""
unw_run scripts/hooks/new-hook.sh
contains "allowlisted hook: check 11 passes" "$out" "[PASS] 11."

# scripts: unreferenced fails; a CI job naming it passes; a library sourced by it passes
UNW_EXTRA=''
unw_run scripts/tools/lonely.sh
contains "unreferenced script: check 11 fails" "$out" "[FAIL] 11."
UNW_EXTRA="printf 'run: bash scripts/tools/job.sh\n' > \"\$REPO/.github/workflows/ci.yml\""
unw_run scripts/tools/job.sh
contains "script named by a CI job: check 11 passes" "$out" "[PASS] 11."
UNW_EXTRA="printf 'run: bash scripts/tools/job.sh\n' > \"\$REPO/.github/workflows/ci.yml\"; printf 'source scripts/lib/helper-lib.sh\n' > \"\$REPO/scripts/tools/job.sh\""
unw_run scripts/tools/job.sh scripts/lib/helper-lib.sh
contains "library sourced by a wired script: check 11 passes" "$out" "[PASS] 11."
UNW_EXTRA="printf 'source scripts/lib/helper-lib.sh\n' > \"\$REPO/scripts/tools/job.sh\""
unw_run scripts/tools/job.sh scripts/lib/helper-lib.sh
contains "library sourced by an unwired script: check 11 fails" "$out" "[FAIL] 11."
contains "library sourced by an unwired script: names the library" "$out" "scripts/lib/helper-lib.sh"
UNW_EXTRA=''
unw_run scripts/tools/fixtures/sample.sh
contains "fixture path is standalone by design: check 11 passes" "$out" "[PASS] 11."

# skills and suites
unw_run .claude/skills/demo/SKILL.md
contains "skill under .claude/skills: check 11 passes" "$out" "[PASS] 11."
unw_run docs/demo/SKILL.md
contains "skill in an undiscovered directory: check 11 fails" "$out" "[FAIL] 11."
unw_run tests/test-lonely.sh
contains "suite outside the runner's scan roots: check 11 fails (run-shell-tests.sh never finds it)" "$out" "[FAIL] 11."
unw_run scripts/tools/test-found.sh
contains "suite under a scan root: check 11 passes" "$out" "[PASS] 11."

# test helpers: reached by the suite that uses them, but a plain script a suite alone names is not
UNW_EXTRA="mkdir -p \"\$REPO/scripts/cfg/tests\"; printf 'node stub-jira.js\n' > \"\$REPO/scripts/cfg/tests/test-cfg.sh\""
unw_run scripts/cfg/tests/stub-jira.js
contains "tests/ stub named by its suite: check 11 passes" "$out" "[PASS] 11."
UNW_EXTRA="printf 'source testlib-pass.sh\n' > \"\$REPO/scripts/tools/test-found.sh\""
unw_run scripts/tools/testlib-pass.sh
contains "testlib helper named by its suite: check 11 passes" "$out" "[PASS] 11."
UNW_EXTRA="mkdir -p \"\$REPO/scripts/g\"; printf 'python3 g-cases/a.py\n' > \"\$REPO/scripts/g/test-g.sh\""
unw_run scripts/g/g-cases/a.py
contains "-cases/ helper named by its suite: check 11 passes" "$out" "[PASS] 11."
UNW_EXTRA="printf 'bash lonely.sh\n' > \"\$REPO/scripts/tools/test-found.sh\""
unw_run scripts/tools/lonely.sh
contains "plain script named only by a suite: check 11 fails" "$out" "[FAIL] 11."
UNW_EXTRA="mkdir -p \"\$REPO/scripts/cfg/tests\""
unw_run scripts/cfg/tests/stub-orphan.js
contains "tests/ stub nothing names: check 11 fails" "$out" "[FAIL] 11."
UNW_EXTRA=''
unw_run scripts/cfg/tests/orphan.test.ts
contains "node/bun test file nothing runs: check 11 fails" "$out" "[FAIL] 11."
UNW_EXTRA="printf 'run: bun test scripts/cfg --dots\n' > \"\$REPO/.github/workflows/ci.yml\""
unw_run scripts/cfg/tests/ran.test.ts
contains "test file under a dir a CI job runs bun test on: check 11 passes" "$out" "[PASS] 11."
UNW_EXTRA="printf 'run: node --test \"scripts/cfg/tests/**/*.test.mjs\"\n' > \"\$REPO/.github/workflows/ci.yml\""
unw_run scripts/cfg/tests/globbed.test.mjs
contains "test file under a quoted-glob node --test job dir: check 11 passes" "$out" "[PASS] 11."
UNW_EXTRA="printf 'run: bun test scripts/other --dots\n' > \"\$REPO/.github/workflows/ci.yml\""
unw_run scripts/cfg/x.test.ts
contains "test file beside a dir a CI job runs bun test on: check 11 fails" "$out" "[FAIL] 11."
UNW_EXTRA="printf 'run: bun test scripts/cfg/tests/deep\n' > \"\$REPO/.github/workflows/ci.yml\""
unw_run scripts/cfg/y.test.ts
contains "test file above the dir a CI job runs bun test on: check 11 fails" "$out" "[FAIL] 11."

# a package.json "test" script wires a file only when its runner's discovery reaches it
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"bun test src\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/a.test.ts
contains "pkg test script scoped to src: file outside it fails" "$out" "[FAIL] 11."
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"bun test tests --dots\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/a.test.ts
contains "pkg test script scoped to tests: file under it passes" "$out" "[PASS] 11."
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"bun test\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/a.test.ts
contains "bare bun test script: file passes" "$out" "[PASS] 11."
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"bun test tests/a*.test.ts\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/abc.test.ts
contains "glob arg with a partial segment: a matching file passes" "$out" "[PASS] 11."
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"bun test .\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/a.test.ts
contains "bun test . discovers the whole package: passes" "$out" "[PASS] 11."
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"npm run build && bun test\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/a.test.ts
contains "compound test script: only the runner's own words narrow it" "$out" "[PASS] 11."
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"echo hi\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/a.test.ts
contains "pkg test script with no test runner: file fails" "$out" "[FAIL] 11."
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"node --test\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/a.test.ts
contains "node --test never discovers a .ts file: fails" "$out" "[FAIL] 11."
unw_run scripts/cfg/tests/a.test.mjs
contains "node --test discovers a .mjs file: passes" "$out" "[PASS] 11."

# a referencer counts only when it is itself wired
UNW_EXTRA="printf 'bun test scripts/cfg/x.test.ts\n' > \"\$REPO/scripts/tools/lonely.sh\""
unw_run scripts/cfg/x.test.ts scripts/tools/lonely.sh
contains "test file named only by an unwired added script: names the test" "$out" "scripts/cfg/x.test.ts"
UNW_EXTRA="printf 'run: bash scripts/tools/job.sh\n' > \"\$REPO/.github/workflows/ci.yml\"; printf 'bun test scripts/cfg/x.test.ts\n' > \"\$REPO/scripts/tools/job.sh\""
unw_run scripts/cfg/x.test.ts scripts/tools/job.sh
contains "test file named by a wired added script: check 11 passes" "$out" "[PASS] 11."

# scripts/hooks/<subdir>/ files are libraries judged by a wired sourcing hook
UNW_EXTRA=''
unw_run scripts/hooks/lib/newlib.sh
contains "hook library nothing sources: check 11 fails" "$out" "[FAIL] 11."
UNW_EXTRA="printf '{\"hooks\":\"scripts/hooks/new-hook.sh\"}\n' > \"\$REPO/.claude/settings.json\"; printf 'source lib/newlib.sh\n' > \"\$REPO/scripts/hooks/new-hook.sh\""
unw_run scripts/hooks/new-hook.sh scripts/hooks/lib/newlib.sh
contains "hook library sourced by a wired hook: check 11 passes" "$out" "[PASS] 11."
UNW_EXTRA="printf 'source lib/newlib.sh\n' > \"\$REPO/scripts/hooks/new-hook.sh\""
unw_run scripts/hooks/new-hook.sh scripts/hooks/lib/newlib.sh
contains "hook library sourced by an unwired hook: names the library" "$out" "scripts/hooks/lib/newlib.sh"

# precision: each of these is a false wired verdict
# a generic extensionless import (./index) of some OTHER module does not wire an added index.ts
UNW_EXTRA="mkdir -p \"\$REPO/scripts/cfg/src\"; printf \"import x from './index'\\n\" > \"\$REPO/scripts/cfg/other.ts\""
unw_run scripts/cfg/src/index.ts
contains "generic index.ts imported as some other ./index: check 11 fails" "$out" "[FAIL] 11."
UNW_EXTRA="mkdir -p \"\$REPO/scripts/cfg/src\"; printf \"import x from './src/index'\\n\" > \"\$REPO/scripts/cfg/other.ts\""
unw_run scripts/cfg/src/index.ts
contains "generic index.ts imported through its own directory: check 11 passes" "$out" "[PASS] 11."
UNW_EXTRA="printf \"import x from './index'\\n\" > \"\$REPO/scripts/cfg/src/consumer.ts\""
unw_run scripts/cfg/src/index.ts
contains "generic index.ts imported as ./index by a sibling: check 11 passes" "$out" "[PASS] 11."
UNW_EXTRA="printf \"import x from '../index'\\n\" > \"\$REPO/scripts/cfg/src/consumer.ts\""
unw_run scripts/cfg/src/index.ts
contains "a sibling's ../index is the parent's index, not this one: check 11 fails" "$out" "[FAIL] 11."
UNW_EXTRA="mkdir -p \"\$REPO/scripts/cfg/tests\"; printf \"import x from './utils'\\n\" > \"\$REPO/scripts/cfg/tests/a.test.ts\""
unw_run scripts/cfg/tests/utils.ts
contains "test helper utils.ts imported as ./utils by its test: check 11 passes" "$out" "[PASS] 11."
UNW_EXTRA="mkdir -p \"\$REPO/scripts/cfg/a.b\";printf \"import x from './aXb/index'\\n\" > \"\$REPO/scripts/cfg/other.ts\""
unw_run scripts/cfg/a.b/index.ts
contains "directory dot is literal: aXb/index does not wire a.b/index.ts" "$out" "[FAIL] 11."

# cd X && node build.js is not a test runner in a CI job
UNW_EXTRA="printf 'run: cd scripts/cfg && node build.js\n' > \"\$REPO/.github/workflows/ci.yml\""
unw_run scripts/cfg/a.test.ts
contains "cd dir then node build.js is not a test runner: check 11 fails" "$out" "[FAIL] 11."
UNW_EXTRA="printf 'run: cd scripts/cfg && bun test\n' > \"\$REPO/.github/workflows/ci.yml\""
unw_run scripts/cfg/a.test.ts
contains "cd dir then bun test is a test runner: check 11 passes" "$out" "[PASS] 11."

# a doc added in the same PR does not wire a script; a doc already in the tree does
UNW_EXTRA="mkdir -p \"\$REPO/docs\"; printf 'run bash scripts/tools/docd.sh\n' > \"\$REPO/docs/run-docd.md\""
unw_run scripts/tools/docd.sh docs/run-docd.md
contains "script named only by a doc added in the same PR: check 11 fails" "$out" "[FAIL] 11."
unw_run scripts/tools/docd.sh
contains "script named by a doc already in the tree: check 11 passes" "$out" "[PASS] 11."

# a test script that merely echoes a runner name runs nothing
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"echo bun test\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/a.test.ts
contains "echo bun test is not a runner: file fails" "$out" "[FAIL] 11."

# a glob arg is matched against the file name, not just its directory
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"bun test tests/a*.test.ts\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/zzz.test.ts
contains "glob arg a*.test.ts does not match zzz.test.ts: file fails" "$out" "[FAIL] 11."

# a wired referencer's dot is literal: a.b.sh is not the pending file aXb.sh
UNW_EXTRA="printf 'run: bash scripts/tools/a.b.sh\\n' > \"\$REPO/.github/workflows/ci.yml\"; printf 'bash target.sh\\n' > \"\$REPO/scripts/tools/a.b.sh\""
unw_run scripts/tools/target.sh scripts/tools/aXb.sh
notcontains "wired referencer a.b.sh is not mistaken for the pending aXb.sh" "$out" "UNWIRED scripts/tools/target.sh"
UNW_EXTRA=''

# referencer, glob and runner corners
# a fixture file naming a script is sample data, not wiring
UNW_EXTRA="mkdir -p \"\$REPO/scripts/tools/fixtures\"; printf 'bash scripts/tools/fxd.sh\n' > \"\$REPO/scripts/tools/fixtures/run.txt\""
unw_run scripts/tools/fxd.sh
contains "script named only by a fixtures/ file: check 11 fails" "$out" "[FAIL] 11."
UNW_EXTRA="mkdir -p \"\$REPO/scripts/tools/fixtures\"; printf 'bash scripts/tools/fxd.sh\n' > \"\$REPO/scripts/tools/fixtures/run.txt\"; printf 'run: bash scripts/tools/fxd.sh\n' > \"\$REPO/.github/workflows/ci.yml\""
unw_run scripts/tools/fxd.sh
contains "script named by a fixtures/ file AND a CI job: check 11 passes" "$out" "[PASS] 11."

# a brace glob arg is expanded: only its alternatives reach the file
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"bun test tests/{a,b}.test.ts\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/zzz.test.ts
contains "brace glob {a,b}.test.ts does not reach zzz.test.ts: file fails" "$out" "[FAIL] 11."
unw_run scripts/cfg/tests/b.test.ts
contains "brace glob {a,b}.test.ts reaches b.test.ts: file passes" "$out" "[PASS] 11."
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"bun test {src,tests}/a.test.ts\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/a.test.ts
contains "brace glob in the directory part: a file under an alternative passes" "$out" "[PASS] 11."

UNW_EXTRA="printf '{\"scripts\":{\"test\":\"bun test {,src/}tests\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/a.test.ts
contains "brace glob with an empty alternative: the empty one still matches" "$out" "[PASS] 11."
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"bun test tests/a{,x}.test.ts\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/a.test.ts
contains "brace glob with an empty alternative inside a name: a.test.ts matches" "$out" "[PASS] 11."

# node --import tsx --test is a test runner that loads a TS transform
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"node --import tsx --test\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/a.test.ts
contains "node --import tsx --test discovers a .ts file: passes" "$out" "[PASS] 11."
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"node --import=tsx --test tests\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/a.test.ts
contains "node --import=tsx --test tests: file under it passes" "$out" "[PASS] 11."
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"node --import tsx --test src\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/a.test.ts
contains "node --import tsx --test src: file outside it fails" "$out" "[FAIL] 11."
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"node --import tsx build.js\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/a.test.ts
contains "node --import tsx build.js is not a test runner: file fails" "$out" "[FAIL] 11."

UNW_EXTRA="printf '{\"scripts\":{\"test\":\"node --test tests --test-name-pattern=foo\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/other/z.test.mjs
contains "a later --test-name-pattern flag does not drop the tests path: outside file fails" "$out" "[FAIL] 11."

# mutation pins: the TS-transform markers in the test script
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"node --test --experimental-strip-types\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/a.test.ts
contains "node --test with strip-types discovers a .ts file: passes" "$out" "[PASS] 11."
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"node --test --import tsimp\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/a.test.ts
contains "node --test with --import discovers a .ts file: passes" "$out" "[PASS] 11."
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"node --test --loader ts-node\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/a.test.ts
contains "node --test with --loader discovers a .ts file: passes" "$out" "[PASS] 11."
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"node --require tsx/cjs --test\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/a.test.ts
contains "node --test with only a tsx marker discovers a .ts file: passes" "$out" "[PASS] 11."
# a flag takes the next word only when it is a valued flag; --test after a script is its argument
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"node --no-warnings build.js --test\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/a.test.mjs
contains "node --no-warnings build.js --test is not a test runner: file fails" "$out" "[FAIL] 11."
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"node --no-warnings --test\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/a.test.mjs
contains "node --no-warnings --test is a runner: file passes" "$out" "[PASS] 11."
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"node -r ./setup.js --test\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/a.test.mjs
contains "node -r ./setup.js --test is a runner: file passes" "$out" "[PASS] 11."

# mutation pins: hook-library referencer branches
UNW_EXTRA="printf 'source h.sh\n' > \"\$REPO/scripts/hooks/test-hk.sh\""
unw_run scripts/hooks/test-hk.sh scripts/hooks/tests/h.sh
contains "hook lib in tests/ named by its wired suite: check 11 passes" "$out" "[PASS] 11."
unw_run scripts/hooks/test-hk.sh scripts/hooks/sub/h.sh
contains "hook lib outside a test dir named only by a suite: check 11 fails" "$out" "[FAIL] 11."
UNW_EXTRA="printf '{\"hooks\":\"scripts/hooks/new-hook.sh\"}\n' > \"\$REPO/.claude/settings.json\"; printf 'source lib/a.sh\n' > \"\$REPO/scripts/hooks/new-hook.sh\"; printf 'source b.sh\n' > \"\$REPO/scripts/hooks/lib/a.sh\""
unw_run scripts/hooks/new-hook.sh scripts/hooks/lib/a.sh scripts/hooks/lib/b.sh
contains "hook lib sourced by a lib a wired hook sources: check 11 passes" "$out" "[PASS] 11."
UNW_EXTRA="printf 'source b.sh\n' > \"\$REPO/scripts/hooks/lib/a.sh\""
unw_run scripts/hooks/lib/a.sh scripts/hooks/lib/b.sh
contains "hook lib sourced only by an unwired added lib: check 11 fails" "$out" "[FAIL] 11."
UNW_EXTRA="printf 'source b.sh\n' > \"\$REPO/scripts/hooks/lib/old.sh\""
unw_run scripts/hooks/lib/b.sh
contains "hook lib sourced by a lib already in the tree: check 11 passes" "$out" "[PASS] 11."

# mutation pins: a non-generic TS stem is matched as an extensionless import
UNW_EXTRA="mkdir -p \"\$REPO/scripts/cfg/src\"; printf \"import x from './sector.js'\\n\" > \"\$REPO/scripts/cfg/src/consumer.ts\""
unw_run scripts/cfg/src/sector.ts
contains "non-generic sector.ts imported as ./sector.js: check 11 passes" "$out" "[PASS] 11."
UNW_EXTRA="mkdir -p \"\$REPO/scripts/cfg/src\"; printf \"import x from './sector'\\n\" > \"\$REPO/scripts/cfg/src/consumer.ts\""
unw_run scripts/cfg/src/sector.ts
contains "non-generic sector.ts imported as ./sector: check 11 passes" "$out" "[PASS] 11."
UNW_EXTRA="mkdir -p \"\$REPO/scripts/cfg/src\"; printf \"import x from './sectors'\\n\" > \"\$REPO/scripts/cfg/src/consumer.ts\""
unw_run scripts/cfg/src/sector.ts
contains "non-generic sector.ts is not wired by ./sectors: check 11 fails" "$out" "[FAIL] 11."
UNW_EXTRA=''

# an unreadable ref exits 2 even when the only file is an extensionless executable
rc=0; out=$(cd "$REPO" && bash "$HERE/../../testing/check-added-unwired.sh" 0000000000000000000000000000000000000000 scripts/tools/runme 2>&1) || rc=$?
check "unreadable ref with an extensionless file: exit 2" "$rc" "2"
UNW_EXTRA=''

# existing debt is never judged: the same unwired hook, status modified
git -C "$REPO" checkout -q --detach "$UNW_BASE" && git -C "$REPO" clean -fdq
mkdir -p "$REPO/scripts/hooks" && printf '#!/usr/bin/env bash\n' > "$REPO/scripts/hooks/old-hook.sh"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m "feat: [HIMMEL-1] touch old hook"
SHA=$(git -C "$REPO" rev-parse HEAD); seed_ledger_ok; reset_stubs
STUB_HEAD="$SHA"; STUB_FILES="scripts/hooks/old-hook.sh"; STUB_FILE_STATUS="modified scripts/hooks/old-hook.sh"
rc=0; out="$(run)" || rc=$?
SHA="$UNW_REAL_SHA"
contains "modified (not added) unwired hook is not judged: check 11 passes" "$out" "[PASS] 11."
reset_stubs

# --- 12. computed TRUST-PATH line: from the PR diff against the default
# branch's list, never from any READY text ---------------------------------------
reset_stubs
rc=0; out="$(run)" || rc=$?
check "trust: docs/script-only diff exit 0" "$rc" "0"
contains "trust: a non-trust diff prints no" "$out" "TRUST-PATH: no"
notcontains "trust: a non-trust diff never prints yes" "$out" "TRUST-PATH: yes"
trust_line_pos=$(printf '%s\n' "$out" | grep -n '^TRUST-PATH:' | cut -d: -f1)
verdict_pos=$(printf '%s\n' "$out" | grep -n '^READY-CHECK ' | cut -d: -f1)
check "trust: the line comes before the verdict" "$((trust_line_pos < verdict_pos))" "1"

reset_stubs
STUB_FILES="scripts/lib/fixtures/anything.txt"
rc=0; out="$(run)" || rc=$?
contains "trust: scripts/lib/fixtures diff (PR 2475 shape) prints yes" "$out" "TRUST-PATH: yes"
notcontains "trust: fixtures diff never prints no" "$out" "TRUST-PATH: no"
contains "trust: a yes line is not a failure of the check" "$out" "[PASS] 12."

reset_stubs
STUB_FILES="scripts/lib/env-alias.sh"
STUB_BODY='## Ticket coverage\n- ask: done\n\nTRUST PATH: none touched\n'
rc=0; out="$(run)" || rc=$?
contains "trust: scripts/lib/env-alias.sh diff (PR 2885 shape) prints yes whatever the body claims" "$out" "TRUST-PATH: yes"

reset_stubs
STUB_FILES="scripts/handover/chief-kit/cr-disposition.sh"
rc=0; out="$(run)" || rc=$?
contains "trust: cr-disposition.sh (go.sh signs and decides exit 9 through it) prints yes" "$out" "TRUST-PATH: yes"

for hook_suite in scripts/hooks/test-block-read-secrets.sh scripts/hooks/test-guard-pr-check-literal.sh \
    scripts/hooks/test-cadence-deny-background.sh scripts/hooks/test-auto-approve-safe-bash.sh \
    scripts/hooks/test-check-commit-msg.sh scripts/hooks/test-check-security-reviewed.sh; do
    reset_stubs
    STUB_FILES="$hook_suite"
    rc=0; out="$(run)" || rc=$?
    check "trust: $hook_suite exit 0" "$rc" "0"
    contains "trust: $hook_suite requires judge" "$out" "TRUST-PATH: yes"
done
for nontrust_suite in scripts/guardrails/test-lib.sh scripts/hooks/test-auto-arm-on-cap.sh; do
    reset_stubs
    STUB_FILES="$nontrust_suite"
    rc=0; out="$(run)" || rc=$?
    contains "trust: $nontrust_suite stays outside policy" "$out" "TRUST-PATH: no"
done

reset_stubs
STUB_TRUST_LIST_FAIL=1
rc=0; out="$(run)" || rc=$?
check "trust: unreadable list exits 1" "$rc" "1"
contains "trust: unreadable list fails check 12" "$out" "[FAIL] 12."
notcontains "trust: unreadable list never prints no" "$out" "TRUST-PATH: no"
contains "trust: unreadable list ends in FAIL" "$out" "READY-CHECK FAIL"

reset_stubs
STUB_DEFAULT_BRANCH_FAIL=1
rc=0; out="$(run)" || rc=$?
check "trust: unresolvable default branch exits 1" "$rc" "1"
contains "trust: unresolvable default branch fails check 12" "$out" "[FAIL] 12."
notcontains "trust: unresolvable default branch never prints no" "$out" "TRUST-PATH: no"

# --only 7 stays a coverage-only lint: no trust check
reset_stubs
rc=0; out=$(cd "$REPO" && STUB_BODY="$GREEN_BODY" STUB_TRUST_LIST_FILE="$TRUST_LIST_FILE" JIRA_CMD="$tmp/bin/jira-stub" STUB_JIRA_DB="$JIRA_DB" JIRA_PROJECT_KEY=HIMMEL STUB_HEAD="$SHA" bash "$SCRIPT" --only 7 "$PR" 2>&1) || rc=$?
notcontains "trust: --only 7 prints no TRUST-PATH line" "$out" "TRUST-PATH:"
reset_stubs

# --- Dependabot dependency-only PRs ------------------------
# Fixture copied from the real PR 3861 (numpy 2.5.3 to 2.5.4, 9d87a279): author
# app/dependabot, one file, Dependabot's own body with no Ticket coverage. The
# commit subject carries the standing key the dependabot.yml prefix now writes.
DEP_BRANCH="dependabot/pip/marketplace/plugins/obsidian-triage/tools/numpy-2.5.4"
DEP_FILES="marketplace/plugins/obsidian-triage/tools/requirements-whisper.txt"
DEP_COMMITS='[{"messageHeadline":"chore(deps): [HIMMEL-7588] Bump numpy in /marketplace/plugins/obsidian-triage/tools","messageBody":"Bumps [numpy](https://github.com/numpy/numpy) from 2.5.3 to 2.5.4.\n- [Release notes](https://github.com/numpy/numpy/releases)\n\nSigned-off-by: dependabot[bot] <support@github.com>"}]'
# shellcheck disable=SC2016  # the backticks are Dependabot's literal body text
DEP_BODY='Bumps [numpy](https://github.com/numpy/numpy) from 2.5.3 to 2.5.4.\n\nDependabot will resolve any conflicts with this PR as long as you dont alter it yourself. You can also trigger a rebase manually by commenting `@dependabot rebase`.\n'
seed_dependabot_go() {
    printf '{"kind":"dependabot-go","ts":"2026-10-25T00:00:00Z","branch":"%s","head":"%s","status":"ok","source":"judge:q1/verdict","pr":%s}\n' "${1:-$DEP_BRANCH}" "${2:-$SHA}" "${3:-77}" > "$LEDGER"
}
# The PR files sit under a marketplace plugin, so check 9 reads git: run from the
# bare-origin CLONE with a real PR head (the plugin version is left alone).
DEP_KEEP_SHA="$SHA"; DEP_KEEP_REPO="$REPO"; DEP_KEEP_LEDGER="$LEDGER"
git -C "$WORK" push -q -f origin "$PR_UNBUMPED:refs/pull/$PR/head"
SHA="$PR_UNBUMPED"; REPO="$CLONE"; LEDGER="$CLONE/.git/cr-critic-scores.jsonl"
dep_fixture() {
    reset_stubs
    STUB_AUTHOR="app/dependabot" STUB_PR_BRANCH="$DEP_BRANCH" STUB_FILES="$DEP_FILES"
    STUB_COMMITS="$DEP_COMMITS" STUB_BODY="$DEP_BODY"
    seed_dependabot_go
}

dep_fixture
rc=0; out="$(run)" || rc=$?
check "dependabot: dependency-only PR exits 0" "$rc" "0"
contains "dependabot: row 4 accepts the dependabot-go row" "$out" "[PASS] 4."
contains "dependabot: row 6 passes on the standing key" "$out" "[PASS] 6."
contains "dependabot: row 7 takes a generated Ticket coverage" "$out" "[PASS] 7. ticket coverage: generated"
contains "dependabot: READY-CHECK PASS" "$out" "READY-CHECK PASS"
notcontains "dependabot: no FAIL row" "$out" "[FAIL]"

# a dependabot-go row for another head or another branch is no review
dep_fixture; seed_dependabot_go "$DEP_BRANCH" deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
rc=0; out="$(run)" || rc=$?
contains "dependabot: a dependabot-go row for another head fails row 4" "$out" "[FAIL] 4."
dep_fixture; seed_dependabot_go "some/other-branch"
rc=0; out="$(run)" || rc=$?
contains "dependabot: a dependabot-go row for another branch fails row 4" "$out" "[FAIL] 4."
dep_fixture; seed_dependabot_go "$DEP_BRANCH" "$SHA" 78
rc=0; out="$(run)" || rc=$?
contains "dependabot: a dependabot-go row for another PR fails row 4" "$out" "[FAIL] 4."
dep_fixture; seed_dependabot_go "$DEP_BRANCH" "$SHA" '"77"'
rc=0; out="$(run)" || rc=$?
contains "dependabot: a dependabot-go row with a string pr fails row 4" "$out" "[FAIL] 4."

# one non-manifest file and the generated coverage is refused
dep_fixture; STUB_FILES="$DEP_FILES
scripts/x/run.sh"
rc=0; out="$(run)" || rc=$?
check "dependabot: a non-manifest file exits 1" "$rc" "1"
contains "dependabot: a non-manifest file fails row 7" "$out" "[FAIL] 7."

# a manifest outside the allowlist of file names (a workflow) is refused
dep_fixture; STUB_FILES=".github/workflows/ci.yml"
rc=0; out="$(run)" || rc=$?
contains "dependabot: a workflow file fails row 7" "$out" "[FAIL] 7."

# a rename out of a non-manifest into a manifest name is refused (the old name counts)
dep_fixture; STUB_RENAMES="$DEP_FILES scripts/hooks/guard.sh"
rc=0; out="$(run)" || rc=$?
check "dependabot: a rename out of a non-manifest exits 1" "$rc" "1"
contains "dependabot: a rename out of a non-manifest fails row 7" "$out" "[FAIL] 7."

# an unreadable rename list is not a dependency-only PR
dep_fixture; STUB_RENAMES_FAIL=1
rc=0; out="$(run)" || rc=$?
contains "dependabot: an unreadable rename list fails row 7" "$out" "[FAIL] 7."

# RED control: a human PR with the same files and no ticket ID still fails rows 6 and 7
dep_fixture; STUB_AUTHOR="yotamleo"; STUB_COMMITS='[{"messageHeadline":"chore(deps): Bump numpy","messageBody":""}]'
rc=0; out="$(run)" || rc=$?
check "dependabot control: human PR exits 1" "$rc" "1"
contains "dependabot control: human PR fails row 6" "$out" "[FAIL] 6."
contains "dependabot control: human PR fails row 7" "$out" "[FAIL] 7."

# a Dependabot PR without the standing key still fails row 6 (3861 as it stands today)
dep_fixture; STUB_COMMITS='[{"messageHeadline":"chore(deps): Bump numpy in /marketplace/plugins/obsidian-triage/tools","messageBody":""}]'
rc=0; out="$(run)" || rc=$?
contains "dependabot: a subject without a key still fails row 6" "$out" "[FAIL] 6."

# an existing Ticket coverage section is judged as written, not replaced
dep_fixture; STUB_BODY='## Ticket coverage\n- bump numpy: deferred -> HIMMEL-51\n'
rc=0; out="$(run)" || rc=$?
contains "dependabot: an own coverage section is still validated" "$out" "[FAIL] 7."

# a dependency-only Dependabot PR has no RED line to name (row 13)
dep_fixture; STUB_RED=
rc=0; out="$(run)" || rc=$?
contains "red-line: a Dependabot dependency-only PR is exempt from row 13" "$out" "[PASS] 13."
dep_fixture; STUB_RED=; STUB_FILES="$DEP_FILES
scripts/x/run.sh"
rc=0; out="$(run)" || rc=$?
contains "red-line: a Dependabot PR that also changes code is not exempt" "$out" "[FAIL] 13."
unset STUB_AUTHOR STUB_PR_BRANCH STUB_FILES STUB_COMMITS STUB_BODY
SHA="$DEP_KEEP_SHA"; REPO="$DEP_KEEP_REPO"; LEDGER="$DEP_KEEP_LEDGER"
reset_stubs

# --- 13. a code PR names a RED-then-GREEN line -------------
reset_stubs
rc=0; out="$(run)" || rc=$?
check "red-line: a code PR with a RED then GREEN line exits 0" "$rc" "0"
contains "red-line: the RED then GREEN line passes row 13" "$out" "[PASS] 13."

reset_stubs; STUB_RED=
rc=0; out="$(run)" || rc=$?
check "red-line: a code PR with no RED line exits 1" "$rc" "1"
contains "red-line: a code PR with no RED line fails row 13" "$out" "[FAIL] 13."
contains "red-line: the failure says what to write" "$out" "RED then GREEN"

reset_stubs; STUB_RED='\nGREEN first, then RED\n'
rc=0; out="$(run)" || rc=$?
contains "red-line: GREEN before RED is not a RED-then-GREEN line" "$out" "[FAIL] 13."

reset_stubs; STUB_RED='\nthe shared fixture is restored and greener\n'
rc=0; out="$(run)" || rc=$?
contains "red-line: RED and GREEN inside other words are not a line" "$out" "[FAIL] 13."

reset_stubs; STUB_RED='\nRED \xe2\x86\x92 GREEN: test-x.sh row 4\n'
rc=0; out="$(run)" || rc=$?
contains "red-line: RED arrow GREEN on one line passes row 13" "$out" "[PASS] 13."

reset_stubs; STUB_RED=; STUB_FILES="docs/handover/running-a-chief.md"
STUB_COMMITS='[{"messageHeadline":"docs: [HIMMEL-1] note","messageBody":""}]'
rc=0; out="$(run)" || rc=$?
check "red-line: a doc-only PR with no RED line exits 0" "$rc" "0"
contains "red-line: a doc-only PR is exempt from row 13" "$out" "[PASS] 13."

reset_stubs; STUB_RED=; STUB_FILES="scripts/telegram/README.md"
STUB_COMMITS='[{"messageHeadline":"docs: [HIMMEL-1] note","messageBody":""}]'
rc=0; out="$(run)" || rc=$?
contains "red-line: markdown under scripts/ is doc-only too" "$out" "[PASS] 13."

reset_stubs; STUB_RED=; STUB_FILES="docs/a.md
scripts/x/run.sh"
rc=0; out="$(run)" || rc=$?
contains "red-line: one code file among docs makes the PR a code PR" "$out" "[FAIL] 13."

reset_stubs; STUB_RED=; STUB_FILES_FAIL=1
rc=0; out="$(run)" || rc=$?
contains "red-line: unreadable PR files fail row 13 closed" "$out" "[FAIL] 13."

# --only 7 stays a coverage-only lint: row 13 is not part of it
rc=0; out=$(cd "$REPO" && STUB_BODY="$GREEN_BODY" STUB_RED="" STUB_TRUST_LIST_FILE="$TRUST_LIST_FILE" JIRA_CMD="$tmp/bin/jira-stub" STUB_JIRA_DB="$JIRA_DB" JIRA_PROJECT_KEY=HIMMEL STUB_HEAD="$SHA" bash "$SCRIPT" --only 7 "$PR" 2>&1) || rc=$?
notcontains "red-line: --only 7 does not run row 13" "$out" "13."

echo "---"
if [ "$fails" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
else
    echo "$fails FAILED"
    exit 1
fi
