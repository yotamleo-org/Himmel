#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2034,SC2153,SC2154
set -uo pipefail
# shellcheck source=tests/testlib-ready-check.sh
. "$(cd "$(dirname "$0")" && pwd)/tests/testlib-ready-check.sh"

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
git -C "$WF_REPO_ROOT" show HEAD:.github/workflows/macos-cadence.yml > "$WFDIR/macos-cadence.yml"
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
# shellcheck disable=SC2016  # the step name is the literal script line, $SUITES unexpanded
SUITE_STEP='Run if [ -n "$SUITES" ]; then'
jobs_json() {  # <job>[|<conclusion>[|<failed step>...]]... -> a `gh run view --json jobs` body
    local j
    for j in "$@"; do printf '%s\n' "$j"; done | jq -R -s -c --arg d "$SUITE_STEP" '
        {jobs: ([split("\n")[] | select(length > 0) | split("|")
            | (if (.[1] // "") == "" then "failure" else .[1] end) as $c
            | {name: .[0], conclusion: $c, steps: ((if length > 2 then .[2:] else [$d] end) | map({name: ., conclusion: $c}))}]
          + [{name: "lint", conclusion: "success", steps: [{name: "Run lint", conclusion: "success"}]}])}'
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

jobs_json "macos / shell (3)" > "$RUNDIR/jobs-111.json"
rm -f "$RUNDIR/log-111.txt" "$RUNDIR/log-222.txt"
wf_run ".github/workflows/ci.yml"
check "A-R2 same job red on both runs, no logs: exit 1" "$rc" "1"
contains "A-R2 same job red on both runs, no logs: UNRESOLVED, the PR log first" "$out" "UNRESOLVED: the log of run 111 cannot be read"
notcontains "A-R2 same job red on both runs, no logs: no PRE-EXISTING pass" "$out" "PRE-EXISTING"
rm -f "$RUNDIR/ci.yml.main.json" "$RUNDIR/ci.yml.json" "$RUNDIR"/jobs-*.json "$RUNDIR"/log-111.txt "$RUNDIR"/log-222.txt

MC=.github/workflows/macos-cadence.yml
J2="macos-cadence / shell (macos-latest, 2)"; J3="macos-cadence / shell (macos-latest, 3)"
J4="macos-cadence / shell (macos-latest, 4)"; J8="macos-cadence / shell (macos-latest, 8)"
JS="macos-cadence / summary"; JS_STEP="macOS jobs must have passed"
SA=scripts/lib/test-a.sh; SB=scripts/lib/test-b.sh
no_suite_log() {  # <job>... -> run-log lines that name no failed suite
    local j
    for j in "$@"; do printf '%s\tRun suites\t2026-10-29T10:00:00.1Z all suites ran\n' "$j"; done
}
printf '[{"conclusion":"failure","databaseId":111,"event":"workflow_dispatch","headSha":"%s","status":"completed"}]' "$SHA" > "$RUNDIR/macos-cadence.yml.json"
main_run schedule failure 222 > "$RUNDIR/macos-cadence.yml.main.json"

jobs_json "$J4" > "$RUNDIR/jobs-111.json"; jobs_json "$J4" > "$RUNDIR/jobs-222.json"
log_fail "$J4" "$SA" > "$RUNDIR/log-111.txt"; log_fail "$J4" "$SA" > "$RUNDIR/log-222.txt"
wf_run "$MC"
check "A-C1 same job, same suite red on both runs: exit 0" "$rc" "0"
contains "A-C1 same job, same suite red on both runs: PRE-EXISTING line" "$out" "PRE-EXISTING"
contains "A-C1 same job, same suite red on both runs: the note names the suite" "$out" "failed only on suites already red on main (schedule run 222): $SA"
contains "A-C1 same job, same suite red on both runs: the note names the job" "$out" "failed job(s): $J4"

log_fail "$J4" "$SB" > "$RUNDIR/log-111.txt"
wf_run "$MC"
check "A-R1 same job, another suite on the PR: exit 1" "$rc" "1"
contains "A-R1 same job, another suite on the PR: check 10 fails" "$out" "[FAIL] 10."
contains "A-R1 same job, another suite on the PR: names suite B and its job" "$out" "failed on suites not red on main run 222: $SB ($J4)"
notcontains "A-R1 same job, another suite on the PR: no PRE-EXISTING pass" "$out" "PRE-EXISTING"

jobs_json os-verify > "$RUNDIR/jobs-111.json"; jobs_json os-verify > "$RUNDIR/jobs-222.json"
no_suite_log os-verify > "$RUNDIR/log-111.txt"; no_suite_log os-verify > "$RUNDIR/log-222.txt"
wf_run "$MC"
check "A-R3 a job red on both runs whose logs name no suite: exit 1" "$rc" "1"
contains "A-R3 a job red on both runs whose logs name no suite: UNRESOLVED names it" "$out" "UNRESOLVED: run 111 job(s) the logs do not explain: os-verify (no failed suite)"

jobs_json "$J4||$SUITE_STEP|List failed suites (breakage metric input)" > "$RUNDIR/jobs-111.json"; jobs_json "$J4" > "$RUNDIR/jobs-222.json"
log_fail "$J4" "$SA" > "$RUNDIR/log-111.txt"; log_fail "$J4" "$SA" > "$RUNDIR/log-222.txt"
wf_run "$MC"
check "A-R4 a suite job with another failed step: exit 1" "$rc" "1"
contains "A-R4 a suite job with another failed step: UNRESOLVED names the step" "$out" "$J4 (failed step List failed suites (breakage metric input))"

jobs_json "$J2|cancelled" > "$RUNDIR/jobs-111.json"; jobs_json "$J2" > "$RUNDIR/jobs-222.json"
log_fail "$J2" "$SA" > "$RUNDIR/log-111.txt"; log_fail "$J2" "$SA" > "$RUNDIR/log-222.txt"
wf_run "$MC"
check "A-R5 a shard cancelled at its job timeout (main run 45947899080 shard 2), its suite red on main: exit 1" "$rc" "1"
contains "A-R5 a shard cancelled at its job timeout: UNRESOLVED names the conclusion" "$out" "$J2 (cancelled)"
jobs_json "$J2|timed_out" > "$RUNDIR/jobs-111.json"
wf_run "$MC"
check "A-R5b a shard timed_out, its suite red on main: exit 1" "$rc" "1"
contains "A-R5b a shard timed_out: UNRESOLVED names the conclusion" "$out" "$J2 (timed_out)"

jobs_json "$JS||$JS_STEP" > "$RUNDIR/jobs-111.json"; jobs_json "$JS||$JS_STEP" > "$RUNDIR/jobs-222.json"
no_suite_log "$JS" > "$RUNDIR/log-111.txt"; no_suite_log "$JS" > "$RUNDIR/log-222.txt"
wf_run "$MC"
check "A-R6 only the derived summary job red on both runs: exit 1" "$rc" "1"
contains "A-R6 only the derived summary job red on both runs: UNRESOLVED" "$out" "UNRESOLVED: run 111 failed only derived job(s) ($JS), which name no suite"

jobs_json "$J8" "$JS||Record breakages against the previous cadence run" > "$RUNDIR/jobs-111.json"; jobs_json "$J3" "$JS||$JS_STEP" > "$RUNDIR/jobs-222.json"
{ log_fail "$J8" "$TT"; no_suite_log "$JS"; } > "$RUNDIR/log-111.txt"; { log_fail "$J3" "$TT"; no_suite_log "$JS"; } > "$RUNDIR/log-222.txt"
wf_run "$MC"
check "A-R7 the summary job red on another step: exit 1" "$rc" "1"
contains "A-R7 the summary job red on another step: names the step" "$out" "$JS (derived: failed step Record breakages"
jobs_json "$J8" "$JS||$JS_STEP" > "$RUNDIR/jobs-111.json"; jobs_json "$J3" > "$RUNDIR/jobs-222.json"
wf_run "$MC"
check "A-R8 the summary job red where main's summary is green: exit 1" "$rc" "1"
contains "A-R8 the summary job red where main's summary is green: UNRESOLVED names it" "$out" "UNRESOLVED: run 111 job(s) the logs do not explain: $JS (derived: main's $JS not red)"

jobs_json "$J4" os-verify > "$RUNDIR/jobs-111.json"; jobs_json "$J4" os-verify > "$RUNDIR/jobs-222.json"
{ log_fail "$J4" "$SB"; no_suite_log os-verify; } > "$RUNDIR/log-111.txt"; { log_fail "$J4" "$SA"; no_suite_log os-verify; } > "$RUNDIR/log-222.txt"
wf_run "$MC"
check "A-R9 a new suite and a job no log explains: exit 1" "$rc" "1"
contains "A-R9 a new suite and a job no log explains: both, the suite part first" "$out" "failed on suites not red on main run 222: $SB ($J4); UNRESOLVED: run 111 job(s) the logs do not explain: os-verify (no failed suite)"

jobs_json "$J4" > "$RUNDIR/jobs-111.json"; jobs_json "$J4" > "$RUNDIR/jobs-222.json"
log_fail "$J4" "$SA" | awk 'BEGIN { FS = OFS = "\t" } { $2 = "UNKNOWN STEP"; print }' > "$RUNDIR/log-111.txt"
cp "$RUNDIR/log-111.txt" "$RUNDIR/log-222.txt"
wf_run "$MC"
check "A-R10 every log line's step column is UNKNOWN STEP: exit 0" "$rc" "0"
contains "A-R10 every log line's step column is UNKNOWN STEP: the note names the suite" "$out" "failed only on suites already red on main (schedule run 222): $SA"

log_fail "$J4" "$SA" > "$RUNDIR/log-222.txt"
log_fail "$J4" "marketplace/plugins/x/$SA" > "$RUNDIR/log-111.txt"
wf_run "$MC"
check "A-R11 the PR's suite only ends with main's suite: exit 1" "$rc" "1"
contains "A-R11 the PR's suite only ends with main's suite: names the PR's suite" "$out" "failed on suites not red on main run 222: marketplace/plugins/x/$SA ($J4)"
log_fail "$J4" scripts/lib/test-aXsh > "$RUNDIR/log-111.txt"
wf_run "$MC"
check "A-R13 the PR's suite matches main's suite only as a pattern: exit 1" "$rc" "1"
contains "A-R13 the PR's suite matches main's suite only as a pattern: names the PR's suite" "$out" "failed on suites not red on main run 222: scripts/lib/test-aXsh ($J4)"

log_fail "$J4" "$SA" > "$RUNDIR/log-111.txt"
printf '{"jobs":[{"name":"%s","conclusion":"failure"}]}' "$J4" > "$RUNDIR/jobs-111.json"
wf_run "$MC"
check "A-R12 a failed job whose JSON has no steps: exit 1" "$rc" "1"
contains "A-R12 a failed job whose JSON has no steps: UNRESOLVED" "$out" "$J4 (steps unreadable)"
printf '{"jobs":[{"name":"%s","conclusion":"failure","steps":[]}]}' "$J4" > "$RUNDIR/jobs-111.json"
wf_run "$MC"
check "A-R14 a suite job with no failed step: exit 1" "$rc" "1"
contains "A-R14 a suite job with no failed step: UNRESOLVED" "$out" "$J4 (no failed step)"
jobs_json "$J4" "$JS||$JS_STEP" > "$RUNDIR/jobs-222.json"
jq -n -c --arg a "$J4" --arg s "$SUITE_STEP" --arg b "$JS" '{jobs: [{name: $a, conclusion: "failure", steps: [{name: $s, conclusion: "failure"}]}, {name: $b, conclusion: "failure", steps: []}]}' > "$RUNDIR/jobs-111.json"
{ log_fail "$J4" "$SA"; no_suite_log "$JS"; } > "$RUNDIR/log-111.txt"; { log_fail "$J4" "$SA"; no_suite_log "$JS"; } > "$RUNDIR/log-222.txt"
wf_run "$MC"
check "A-R14 a summary job with no failed step: exit 1" "$rc" "1"
contains "A-R14 a summary job with no failed step: UNRESOLVED" "$out" "$JS (no failed step)"
rm -f "$RUNDIR/macos-cadence.yml.main.json" "$RUNDIR/macos-cadence.yml.json" "$RUNDIR"/jobs-*.json "$RUNDIR"/log-111.txt "$RUNDIR"/log-222.txt

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
git -C "$REPO" remote set-url origin "$ANC_ORIGIN"
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
git -C "$REPO" remote add origin "$tmp/repo-origin.git"  # the default origin, for check 19 in the rows below
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
notcontains "non-workflow PR: no run list issued" "$(gh_log)" "run list"

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


echo "---"
if [ "$fails" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
else
    echo "$fails FAILED"
    exit 1
fi
