#!/usr/bin/env bash
# scripts/ci/test-check-run-timelines.sh -- recorded GitHub check-run timelines
# through the merge consumers.
#
# scripts/ci/check-run-timelines/testdata/<incident>/ holds the REAL gh api responses for
# the head of one incident PR (check-runs?filter=all and ?filter=latest, the
# combined status, trimmed to the fields the consumers read, every row as
# GitHub returned it) and pr.json: the head, plus the mergeStateStatus the
# incident ticket records (its `source` field quotes the ticket). ONE gh stub
# serves those files to the real consumers; the verdict of each is asserted
# against the recorded mergeStateStatus: a consumer is green exactly when
# GitHub said CLEAN. A workflow-text pin cannot model event semantics (a
# cancelled run, a re-run, an Expected check); a recorded timeline can.
#
# Usage: bash scripts/ci/test-check-run-timelines.sh [--check-ci SCRIPT]
#   --check-ci SCRIPT   run the check-ci.sh consumer from SCRIPT (a parent
#                       commit's copy: the RED control for the 3473 incident).
# Exit: 0 all cases passed; 1 at least one failed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CORPUS="$ROOT/scripts/ci/check-run-timelines/testdata"
CHECK_CI="$ROOT/scripts/check-ci.sh"
# shellcheck source=../lib/timeout-bin.sh
. "$ROOT/scripts/lib/timeout-bin.sh"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --check-ci) CHECK_CI="$2"; shift 2 ;;
        *) echo "usage: $0 [--check-ci SCRIPT]" >&2; exit 64 ;;
    esac
done

fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/check-run-timelines.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN" "$TMP/home"

# The one gh stub. It answers from $CASE (a copy of one incident dir plus the
# rules file) and applies the caller's own --jq with real jq, so each consumer
# parses exactly the bytes GitHub sent. A call it does not recognise fails loud.
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CASE/calls"
jqexpr=""; prev=""
for a in "$@"; do
    [ "$prev" = "--jq" ] && jqexpr="$a"
    prev="$a"
done
emit() { if [ -n "$jqexpr" ]; then jq -r "$jqexpr" "$1"; else cat "$1"; fi; }
headers() { printf 'HTTP/2.0 200 OK\r\nEtag: "recorded"\r\n\r\n'; }
case " $* " in
    *' rate_limit '*) echo "5000 9999999999 5000 9999999999"; exit 0 ;;
    *' graphql '*)
        case "$*" in
            *statusCheckRollup*)
                jq -n --slurpfile pr "$CASE/pr.json" --slurpfile runs "$CASE/check-runs-all.json" '
                    $pr[0] as $p
                    | {data: {repository: {("p\($p.number)"): ($p + {
                        body: "", state: "OPEN", title: "recorded", headRefName: "recorded", isDraft: false, mergedAt: null,
                        commits: {nodes: [{commit: {oid: $p.headRefOid, messageHeadline: "recorded", messageBody: null, parents: {totalCount: 1}}}],
                                  pageInfo: {hasNextPage: false, endCursor: null}},
                        reviewThreads: {nodes: [], pageInfo: {hasNextPage: false, endCursor: null}},
                        statusCheckRollup: {contexts: {nodes: [$runs[0].check_runs[] | {__typename: "CheckRun", name: .name,
                                status: (.status | ascii_upcase),
                                conclusion: (.conclusion | if . == null then null else ascii_upcase end),
                                startedAt: .started_at, completedAt: .completed_at,
                                checkSuite: {workflowRun: {workflow: {name: null}}}}],
                            pageInfo: {hasNextPage: false, endCursor: null}}}})}}}' > "$CASE/snapshot.json"
                cat "$CASE/snapshot.json"; exit 0 ;;
        esac
        echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}' > "$CASE/threads.json"
        emit "$CASE/threads.json"; exit 0 ;;
    *'/actions/runs/'[0-9]*'/jobs'*) emit "$CASE/jobs-$(printf '%s' "$*" | sed -n 's|.*/actions/runs/\([0-9]*\)/jobs.*|\1|p').json"; exit 0 ;;
    *'/actions/runs/'[0-9]*)
        emit "$CASE/run-$(printf '%s' "$*" | sed -n 's|.*/actions/runs/\([0-9]*\).*|\1|p').json"; exit 0 ;;
    *'/check-runs/'[0-9]*'/annotations'*)
        emit "$CASE/annotations-$(printf '%s' "$*" | sed -n 's|.*/check-runs/\([0-9]*\)/annotations.*|\1|p').json"; exit 0 ;;
    *' issue list '*) echo 2999; exit 0 ;;
    *' issue view '*)
        printf '<!-- main-red-run: 1 -->\n<!-- main-red-failed: shell-unit (ubuntu-latest) -->\n'; exit 0 ;;
    *' issue '*) exit 0 ;;
    *' repo view '*)
        echo '{"owner":{"login":"octo"},"name":"demo","defaultBranchRef":{"name":"main"}}' > "$CASE/repo.json"
        emit "$CASE/repo.json"; exit 0 ;;
    *'/pulls/'[0-9]*)
        jq '{head: {sha: .headRefOid}}' "$CASE/pr.json" > "$CASE/pull.json"
        emit "$CASE/pull.json"; exit 0 ;;
    *'/rules/branches/'*) emit "$CASE/rules.json"; exit 0 ;;
    *'/protection/required_status_checks'*) echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
    *'/check-runs?'*)
        f="$CASE/check-runs-all.json"
        case "$*" in *filter=latest*) f="$CASE/check-runs-latest.json" ;; esac
        case " $* " in *' --include '*) headers ;; esac
        emit "$f"; exit 0 ;;
    *'/status?'*)
        case " $* " in *' --include '*) headers ;; esac
        emit "$CASE/status.json"; exit 0 ;;
esac
if [ "$1 $2" = "pr checks" ]; then
    # What `gh pr checks` derives from GitHub's rollup (the latest run per check
    # suite): the read path of check-ci.sh before it took mergeStateStatus.
    jq '[.check_runs[] | {name, bucket: (if .status != "completed" then "pending"
        elif .conclusion == "success" then "pass" elif .conclusion == "skipped" or .conclusion == "neutral" then "skipping"
        elif .conclusion == "cancelled" then "cancel" else "fail" end)}]' "$CASE/check-runs-latest.json" > "$CASE/pr-checks.json"
    case " $* " in
        *' --json '*) emit "$CASE/pr-checks.json" ;;
        *) [ "$(jq '[.[] | select(.bucket == "fail")] | length' "$CASE/pr-checks.json")" -eq 0 ] ;;
    esac
    exit $?
fi
if [ "$1 $2" = "pr view" ]; then
    jq '. + {url: "https://github.com/octo/demo/pull/\(.number)", title: "recorded", author: {login: "octocat", is_bot: false}, files: [{path: "README.md"}], changedFiles: 1}' "$CASE/pr.json" > "$CASE/pr-view.json"
    emit "$CASE/pr-view.json"; exit 0
fi
echo "check-run-timelines stub: unserved gh call: $*" >&2
exit 1
STUB
chmod +x "$BIN/gh"

# new_case <incident dir> -- fresh $CASE holding that incident's recorded files.
new_case() {
    CASE="$(mktemp -d "$TMP/case.XXXXXX")" || exit 1; export CASE
    cp "$CORPUS/$1"/*.json "$CASE/"
    : > "$CASE/calls"
}

# run_check_ci -- the real check-ci.sh against the current $CASE.
run_check_ci() {
    local of="$CASE/out" ef="$CASE/err"
    PATH="$BIN:$PATH" HOME="$TMP/home" GH_REPO=octo/demo \
        CR_APP=0 CHECK_CI_POLL_INTERVAL=0 CHECK_CI_SETTLE=0 CHECK_CI_SLEEP_CMD=: \
        CHECK_CI_CACHE_DIR="$CASE/cache" GH_BUDGET_JITTER_MAX=0 \
        HIMMEL_TEST_FIXTURE=1 HIMMEL_CONSOLE_LEG=0 MERGE_BLOCK_ALERT_DIR="$CASE/alerts" \
        MERGE_BLOCK_ALERT_CMD=true \
        ${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" -k 5 120} bash "$CHECK_CI" --grace 0 "$(jq -r .number "$CASE/pr.json")" >"$of" 2>"$ef"
    RC=$?
    OUT=$(cat "$of"); ERR=$(cat "$ef")
}

# green_iff_clean <label> -- the consumer's verdict equals GitHub's: exit 0 when
# the recorded mergeStateStatus is CLEAN, non-zero otherwise.
green_iff_clean() {
    local want rec
    rec=$(jq -r .mergeStateStatus "$CASE/pr.json")
    if [ "$rec" = CLEAN ]; then want=0; else want=nonzero; fi
    if { [ "$want" = 0 ] && [ "$RC" -eq 0 ]; } || { [ "$want" = nonzero ] && [ "$RC" -ne 0 ]; }; then
        ok "$1: recorded mergeStateStatus=$rec, verdict rc=$RC"
    else
        bad "$1: recorded mergeStateStatus=$rec but verdict rc=$RC; stderr: $ERR"
    fi
}

# run_ready_check -- the real ready-check.sh (items 1-3 read the PR snapshot)
# against the current $CASE.
run_ready_check() {
    local of="$CASE/rc-out" sha
    sha=$(jq -r .headRefOid "$CASE/pr.json")
    PATH="$BIN:$PATH" HOME="$TMP/home" GH_CMD="$BIN/gh" GH_PR_SNAPSHOT_CACHE_DIR="$CASE/snap" \
        ${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" -k 5 120} bash "$ROOT/scripts/handover/console-kit/ready-check.sh" \
        "$(jq -r .number "$CASE/pr.json")" "$sha" >"$of" 2>"$CASE/rc-err" </dev/null
    RC_OUT=$(cat "$of")
}

# line_of <n> -- ready-check's verdict line for item <n>.
line_of() { printf '%s\n' "$RC_OUT" | grep -E "^\[(PASS|FAIL)\] $1\. " | head -n 1; }

# want_rc <incident> -- the exit code check-ci.sh gives today.
want_rc() {
    case "$1" in
        3473-*) echo 6 ;;
        3434-*) echo 0 ;;
        3588-*) echo 6 ;;
        3690-*) echo 0 ;;
        3788-*) echo 1 ;;
        6562-*) echo 1 ;;
        *) echo "?" ;;
    esac
}

# want_item2 <incident> -- ready-check item 2 (latest run per check name).
want_item2() {
    case "$1" in
        3473-*|3434-*|3690-*|3588-*) echo PASS ;;
        3788-*|6562-*) echo FAIL ;;
        *) echo "?" ;;
    esac
}

for dir in "$CORPUS"/[0-9]*/; do
    inc="$(basename "$dir")"

    new_case "$inc"
    run_check_ci
    green_iff_clean "check-ci $inc"
    w=$(want_rc "$inc")
    if [ "$RC" = "$w" ]; then ok "check-ci $inc: exit code $RC"; else bad "check-ci $inc: exit code $RC, want $w; stderr: $ERR"; fi

    new_case "$inc"
    run_ready_check
    rec=$(jq -r .mergeStateStatus "$CASE/pr.json")
    l1=$(line_of 1)
    case "$rec:$l1" in
        CLEAN:"[PASS] 1. "*|BLOCKED:"[FAIL] 1. "*) ok "ready-check $inc: item 1 follows recorded mergeStateStatus=$rec" ;;
        *) bad "ready-check $inc: recorded mergeStateStatus=$rec but item 1 says: $l1" ;;
    esac
    l2=$(line_of 2)
    w2=$(want_item2 "$inc")
    case "$l2" in
        "[$w2] 2. "*) ok "ready-check $inc: item 2 $w2" ;;
        *) bad "ready-check $inc: item 2 want $w2, got: $l2" ;;
    esac
done

# The sweep-red reporter: schedule run 39029239710 was cancelled
# by an operator (its shard 4 annotation says so, no job failed red) and the
# newer schedule run 39032362864 went green. Neither may open, refresh or close
# the main-red issue; a stub issue 2999 is open, so any mutation shows in calls.
run_sweep() {
    new_case sweep-6122
    PATH="$BIN:$PATH" HOME="$TMP/home" GITHUB_REPOSITORY=octo/demo \
        ${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" -k 5 60} bash "$ROOT/scripts/ci/main-sweep-red-issue.sh" "$1" >"$CASE/out" 2>"$CASE/err" </dev/null
    RC=$?
    OUT=$(cat "$CASE/out"); ERR=$(cat "$CASE/err")
}
run_sweep 39029239710
mut=$(grep -c -E '^issue (edit|comment|create|close|reopen)|^label create' "$CASE/calls")
if [ "$RC" -eq 0 ] && [ "$mut" -eq 0 ] && grep -q 'nothing to report' <<< "$OUT"; then
    ok "sweep-red run 39029239710 (cancelled by the operator, no job red): no issue mutation"
else
    bad "sweep-red run 39029239710: rc=$RC, $mut issue mutation(s); out: $OUT; err: $ERR"
fi
run_sweep 39032362864
if [ "$RC" -eq 0 ] && grep -q '^issue close 2999' "$CASE/calls" && ! grep -q '^issue create' "$CASE/calls"; then
    ok "sweep-red run 39032362864 (newer schedule run, success): closes the recorded red issue, opens none"
else
    bad "sweep-red run 39032362864: rc=$RC; calls: $(grep '^issue' "$CASE/calls" | tr '\n' ';'); err: $ERR"
fi

# lint-required-check-cancel.sh: the real workflow text of two incidents is
# flagged, every current workflow is clean, and a mutated current workflow is
# flagged (so a clean run is not a lint that finds no provider).
LINT="$ROOT/scripts/ci/lint-required-check-cancel.sh"
RULES="$CORPUS/rules-main.json"
if python3 -I -c 'import yaml' 2>/dev/null; then
    lint_out=$(bash "$LINT" --required "$RULES" "$CORPUS/lint/3588-pr1226-codeowner-review-gate.yml.txt" 2>&1); lint_rc=$?
    if [ "$lint_rc" -eq 1 ] && grep -q ': cancel: ' <<< "$lint_out"; then
        ok "lint flags the HIMMEL-3588 workflow (cancel-in-progress on the required codeowner-review-gate)"
    else
        bad "lint on the HIMMEL-3588 workflow: rc=$lint_rc, out: $lint_out"
    fi
    lint_out=$(bash "$LINT" --required "$RULES" "$CORPUS/lint/6562-pr3194-codeowner-review-gate.yml.txt" 2>&1); lint_rc=$?
    if [ "$lint_rc" -eq 1 ] && grep -q ': shared: ' <<< "$lint_out"; then
        ok "lint flags the HIMMEL-6562 workflow (review event shares the pull_request group)"
    else
        bad "lint on the HIMMEL-6562 workflow: rc=$lint_rc, out: $lint_out"
    fi
    lint_out=$(bash "$LINT" --required "$RULES" "$ROOT"/.github/workflows/*.yml 2>&1); lint_rc=$?
    if [ "$lint_rc" -eq 0 ]; then ok "lint: every current workflow is clean"; else bad "lint on current workflows: rc=$lint_rc, out: $lint_out"; fi
    bash "$LINT" "$ROOT/.github/workflows/ci.yml" >/dev/null 2>&1; lint_rc=$?
    if [ "$lint_rc" -eq 2 ]; then ok "lint: a call without --required is a usage error (rc 2)"; else bad "lint usage: rc=$lint_rc, want 2"; fi
    bash "$LINT" --required "$TMP/no-such-rules" "$ROOT/.github/workflows/ci.yml" >/dev/null 2>&1; lint_rc=$?
    if [ "$lint_rc" -eq 2 ]; then ok "lint: an unreadable required file is rc 2"; else bad "lint unreadable required: rc=$lint_rc, want 2"; fi
    for wf in ci codeowner-review-gate; do
        sed 's/^\( *cancel-in-progress:\).*/\1 true/' "$ROOT/.github/workflows/$wf.yml" > "$TMP/mutant-$wf.yml"
        lint_out=$(bash "$LINT" --required "$RULES" "$TMP/mutant-$wf.yml" 2>&1); lint_rc=$?
        if [ "$lint_rc" -eq 1 ]; then ok "lint control: $wf.yml with cancel-in-progress: true is flagged"; else bad "lint control $wf.yml: rc=$lint_rc, out: $lint_out"; fi
    done
else
    echo "skip - lint rows need python3 with PyYAML (the CI image carries it)"
fi

[ "$fails" -eq 0 ] || { echo "$fails case(s) failed" >&2; exit 1; }
echo "all cases passed"
