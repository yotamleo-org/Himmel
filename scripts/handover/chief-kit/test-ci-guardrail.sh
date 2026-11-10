#!/usr/bin/env bash
# test-ci-guardrail.sh — Hermetic tests for ci-guardrail.sh: one fires-once /
# quiet-below-the-line row per threshold, the real 10-19 19Z and 10-15 replays, the re-arm
# cycle, and the fetch path (budget gate, slice assembly, cache). No network: gh is never
# called; the fetch rows drive a stub standing in for ci-metrics.sh --slice.
#
# PLATFORM GUARD: The chief kit is Linux-only.
# shellcheck disable=SC2015  # `[ cond ] && pass || fail`: pass() cannot fail, so A && B || C is if-then-else here
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/ci-guardrail.sh"
FIX="$HERE/ci-guardrail-fixtures"
METRICS="$HERE/../../eval/ci-metrics.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/ci-guardrail-test.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
fails=0

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
contains() {
    case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3' in '$2')" ;; esac
}
not_contains() {
    case "$2" in *"$3"*) fail "$1 (found '$3' in '$2')" ;; *) pass "$1" ;; esac
}

export CI_METRICS_PACE=0
export CIGUARD_METRICS="$METRICS"
NOW=2026-10-20T11:30:00Z

# gen <jq program producing runs from range index .> <count> : a runs.json on stdout.
# Every row carries the fields ci-metrics.sh reads from a real run record.
gen() {
    jq -n --argjson n "$2" "[range(0; \$n) | $1]"
}
# run <runs.json> [state-dir]: one guardrail read with a private state dir per scenario.
run() {
    bash "$SUT" --runs "$1" --now "${3:-$NOW}" --state-dir "${2:-$W/state}" 2>&1
}
fresh() { rm -rf "$W/state"; }

# Operator decision 850: the only real limits are 500 concurrent jobs and a GitHub refusal.
# jobs fixtures: <n> queued jobs of run 1, all waiting since 11:25 (the clock is 11:30).
JOBQ='{run_id: 1, name: "job\(.)", status: "queued", conclusion: null, created_at: "2026-10-20T11:25:00Z", started_at: null, completed_at: null}'
RUN_1='{id: 1, name: "CI", event: "pull_request", status: "in_progress", conclusion: null, head_branch: "b", head_sha: "s", run_attempt: 1,
        created_at: "2026-10-20T11:20:00Z", run_started_at: "2026-10-20T11:20:00Z", updated_at: "2026-10-20T11:25:00Z"}'
gen "$RUN_1" 1 > "$W/one-run.json"
gen "$JOBQ" 500 > "$W/q500.json"; gen "$JOBQ" 501 > "$W/q501.json"
# runj <jobs.json> [state-dir] [now]: one read of one open run holding those jobs.
runj() {
    bash "$SUT" --runs "$W/one-run.json" --jobs "$1" --now "${3:-$NOW}" --state-dir "${2:-$W/state}" 2>&1
}

# --- runs/h: 150 in one clock hour is the line, 151 is over
RUN_H='{id: ., name: "PR Title Lint", event: "pull_request", status: "completed", conclusion: "success", head_branch: "b\(. % 40)", head_sha: "s\(.)", run_attempt: 1,
        created_at: "2026-10-20T10:\(. % 60 | tostring | if length < 2 then "0" + . else . end):00Z", run_started_at: "2026-10-20T10:00:00Z", updated_at: "2026-10-20T10:59:59Z"}'
gen "$RUN_H" 150 > "$W/h150.json"; gen "$RUN_H" 151 > "$W/h151.json"
fresh; out="$(run "$W/h150.json")"
contains 'runs/h at 150 reads ok' "$out" 'ciguard=ok'
not_contains 'runs/h at 150 raises no alert' "$out" 'ALERT'
fresh; out="$(run "$W/h151.json")"
contains 'runs/h at 151 (past our old line) reads ok' "$out" 'ciguard=ok'
not_contains 'runs/h at 151 raises no alert' "$out" 'ALERT'
contains 'runs/h at 151 prints as info' "$out" 'INFO runs-h=151'

# --- runs/day: 1500 in a rolling 24 h is the line, 1501 is over (never more than 100 in one hour)
RUN_D='{id: ., name: "PR Title Lint", event: "pull_request", status: "completed", conclusion: "success", head_branch: "b\(. % 40)", head_sha: "s\(.)", run_attempt: 1,
        created_at: (1792494000 - 86000 + . * 57 | todate), run_started_at: (1792494000 - 86000 + . * 57 | todate), updated_at: (1792494000 - 86000 + . * 57 | todate)}'
gen "$RUN_D" 1500 > "$W/d1500.json"; gen "$RUN_D" 1501 > "$W/d1501.json"
fresh; out="$(run "$W/d1500.json" "$W/state" 2026-10-20T11:00:00Z)"
contains 'runs/day at 1500 reads ok' "$out" 'ciguard=ok'
fresh; out="$(run "$W/d1501.json" "$W/state" 2026-10-20T11:00:00Z)"
contains 'runs/day at 1501 reads ok' "$out" 'ciguard=ok'
not_contains 'runs/day at 1501 raises no alert' "$out" 'ALERT'
contains 'runs/day at 1501 prints as info' "$out" 'INFO runs-day=1501'

# --- cancels per 10 min: 30 is the line, 31 is over
CANC='{id: ., name: "CI", event: "pull_request", status: "completed", conclusion: "cancelled", head_branch: "b\(.)", head_sha: "s\(.)", run_attempt: 1,
       created_at: "2026-10-20T11:00:00Z", run_started_at: "2026-10-20T11:00:00Z", updated_at: "2026-10-20T11:20:\(. % 60 | tostring | if length < 2 then "0" + . else . end)Z"}'
gen "$CANC" 30 > "$W/c30.json"; gen "$CANC" 31 > "$W/c31.json"
fresh; out="$(run "$W/c30.json")"
contains 'cancels at 30 per 10 min reads ok' "$out" 'ciguard=ok'
fresh; out="$(run "$W/c31.json")"
contains 'cancels at 31 per 10 min reads ok' "$out" 'ciguard=ok'
not_contains 'cancels at 31 per 10 min raises no alert' "$out" 'ALERT'
contains 'cancels at 31 per 10 min prints as info' "$out" 'INFO cancels-10m=31'

# --- reruns/h: 10 is the line, 11 is over
RERUN='{id: ., name: "CI", event: "pull_request", status: "completed", conclusion: "success", head_branch: "b\(.)", head_sha: "s\(.)", run_attempt: 2,
        created_at: "2026-10-20T10:00:00Z", run_started_at: "2026-10-20T10:\(. % 60 | tostring | if length < 2 then "0" + . else . end):00Z", updated_at: "2026-10-20T10:59:00Z"}'
gen "$RERUN" 10 > "$W/r10.json"; gen "$RERUN" 11 > "$W/r11.json"
fresh; out="$(run "$W/r10.json")"
contains 'reruns at 10 per hour reads ok' "$out" 'ciguard=ok'
fresh; out="$(run "$W/r11.json")"
contains 'reruns at 11 per hour reads ok' "$out" 'ciguard=ok'
not_contains 'reruns at 11 per hour raises no alert' "$out" 'ALERT'
contains 'reruns at 11 per hour prints as info' "$out" 'INFO reruns-h=11'

# --- CI runs per branch per day: 10 is the line (the 10-15 data tops out at 9), 11 is over.
# Only the CI workflow counts, main never does, and a run older than 24 h is outside the day.
BR='{id: ., name: "CI", event: "pull_request", status: "completed", conclusion: "success", head_branch: "feat/x", head_sha: "s\(.)", run_attempt: 1,
     created_at: "2026-10-20T0\(. % 10):00:00Z", run_started_at: "2026-10-20T00:00:00Z", updated_at: "2026-10-20T09:59:00Z"}'
gen "$BR" 10 > "$W/b10.json"; gen "$BR" 11 > "$W/b11.json"
fresh; out="$(run "$W/b10.json")"
contains 'a branch at 10 CI runs reads ok' "$out" 'ciguard=ok'
contains 'a branch at 10 CI runs prints its count as info' "$out" 'INFO branch-day=10 (feat/x)'
fresh; out="$(run "$W/b11.json")"
contains 'a branch at 11 CI runs reads ok (our own old line, not a GitHub limit)' "$out" 'ciguard=ok'
not_contains 'a branch at 11 CI runs raises no alert' "$out" 'ALERT'
contains 'a branch at 11 CI runs prints as info' "$out" 'INFO branch-day=11 (feat/x)'
jq 'map(.head_branch = "main")' "$W/b11.json" > "$W/b11-main.json"
fresh; out="$(run "$W/b11-main.json")"
contains 'main never counts as a busy branch' "$out" 'INFO branch-day=0'
jq 'map(.name = "PR Title Lint")' "$W/b11.json" > "$W/b11-gate.json"
fresh; out="$(run "$W/b11-gate.json")"
contains 'a gate workflow never counts as a CI run' "$out" 'INFO branch-day=0'
jq 'map(.created_at = "2026-10-18T01:00:00Z" | .updated_at = "2026-10-18T01:01:00Z")' "$W/b11.json" > "$W/b11-old.json"
fresh; out="$(run "$W/b11-old.json")"
contains 'runs older than 24 h are outside the day' "$out" 'INFO branch-day=0'
fresh; out="$(run "$W/b11.json" "$W/state" 2026-10-19T12:00:00Z)"
contains 'runs created after the clock are outside the day' "$out" 'INFO branch-day=0'

# --- a report row that does not parse is unknown, never below the line
cat > "$W/metrics-garble.sh" <<STUB
#!/usr/bin/env bash
bash "$METRICS" "\$@" | sed 's/| *OVER *|\$/| ??? |/'
STUB
fresh; runj "$W/q501.json" >/dev/null
out="$(CIGUARD_METRICS="$W/metrics-garble.sh" runj "$W/q501.json")"
contains 'a garbled status column reads unknown' "$out" 'ciguard=unknown'
out="$(runj "$W/q501.json")"
not_contains 'a garbled read left the alerted state alone' "$out" 'ALERT'

# --- the real replays (runs copied from the GitHub API for those windows)
gzip -dc "$FIX/runs-2026-10-19-19Z.json.gz" > "$W/r1019.json"
gzip -dc "$FIX/runs-2026-10-15.json.gz" > "$W/r1015.json"
fresh; out="$(run "$W/r1019.json" "$W/state" 2026-10-19T20:05:00Z)"
contains 'the 10-19 19Z replay (262 runs in an hour) reads ok: our old run-count line is not a GitHub limit' "$out" 'ciguard=ok'
contains 'the 10-19 19Z replay still prints its 262 runs as info' "$out" 'INFO runs-h=262 (2026-10-19T19:00:00Z)'
not_contains 'the 10-19 19Z replay raises no alert' "$out" 'ALERT'
fresh; out="$(run "$W/r1019.json" "$W/state" 2026-10-19T16:00:00Z)"
contains 'the 10-19 data holds one real startup_failure run (15:14Z): a read at 16:00Z reads OVER' "$out" 'ciguard=OVER:gh-refusal'
fresh; out="$(run "$W/r1015.json" "$W/state" 2026-10-16T00:00:00Z)"
contains 'the 10-15 replay stays quiet' "$out" 'ciguard=ok'
not_contains 'the 10-15 replay raises no alert' "$out" 'ALERT'

# --- alert once per crossing, re-arm below the line
fresh
out1="$(runj "$W/q501.json")"; out2="$(runj "$W/q501.json")"
contains 'the first read of a crossing alerts' "$out1" 'ALERT concurrent-jobs=501>500'
not_contains 'the second read of the same crossing stays silent' "$out2" 'ALERT'
contains 'the second read still shows the state' "$out2" 'ciguard=OVER:concurrent-jobs'
out3="$(runj "$W/q500.json")"
contains 'a read below the line clears the state' "$out3" 'ciguard=ok'
out4="$(runj "$W/q501.json")"
contains 'the next crossing alerts again (re-armed)' "$out4" 'ALERT concurrent-jobs=501>500'

# --- a replay with no --state-dir of its own leaves the live state alone
mkdir -p "$W/live"
out="$(TICK_STATE_DIR="$W/live" bash "$SUT" --runs "$W/one-run.json" --jobs "$W/q501.json" --now "$NOW" 2>&1)"
contains 'a replay without --state-dir still alerts' "$out" 'ALERT concurrent-jobs=501>500'
[ ! -e "$W/live/tick-ciguard-state" ] && pass 'a replay without --state-dir writes no live state' || fail 'a replay wrote the live state file'
printf '%s\n' 'cancels' > "$W/live/tick-ciguard-state"
out="$(TICK_STATE_DIR="$W/live" bash "$SUT" --runs "$W/one-run.json" --jobs "$W/q501.json" --now "$NOW" 2>&1)"
contains 'a replay alerts whatever the live state holds' "$out" 'ALERT concurrent-jobs=501>500'
[ "$(cat "$W/live/tick-ciguard-state" 2>/dev/null)" = cancels ] && pass 'a replay leaves an existing live state file as it was' || fail 'a replay rewrote or removed the live state file'

# --- unknown never changes the state
fresh
runj "$W/q501.json" >/dev/null
out="$(run "$W/missing.json")"
contains 'an unreadable runs file reads unknown' "$out" 'ciguard=unknown'
out="$(bash "$SUT" --runs "$W/one-run.json" --jobs "$W/missing-jobs.json" --now "$NOW" --state-dir "$W/state" 2>&1)"
contains 'an unreadable jobs file reads unknown' "$out" 'ciguard=unknown'
out="$(runj "$W/q501.json")"
not_contains 'unknown left the alerted state alone' "$out" 'ALERT'

# --- fetch path: a stub stands in for ci-metrics.sh --slice, everything else runs the real script
cat > "$W/metrics-stub.sh" <<STUB
#!/usr/bin/env bash
if [ "\${1:-}" = "--slice" ]; then
    printf 'x\n' >> "$W/slice-calls"
    cp "$W/h151.json" "\$3/slice.\$4.json"
    exit 0
fi
exec bash "$METRICS" "\$@"
STUB
cat > "$W/budget-ok.sh" <<'STUB'
#!/usr/bin/env bash
echo 'gh-api: remaining=4000/5000 reset=12:00Z graphql=4000/5000'
STUB
cat > "$W/budget-low.sh" <<'STUB'
#!/usr/bin/env bash
echo 'gh-api: remaining=10/5000 reset=12:00Z graphql=4000/5000'
STUB
live() {
    CIGUARD_METRICS="$W/metrics-stub.sh" CIGUARD_BUDGET="$1" CIGUARD_REPO=o/r bash "$SUT" --now "$NOW" --state-dir "$W/state" 2>&1
}
fresh; : > "$W/slice-calls"
out="$(live "$W/budget-low.sh")"
contains 'a low REST budget reads unknown' "$out" 'ciguard=unknown'
[ ! -s "$W/slice-calls" ] && pass 'a low REST budget spends no slice call' || fail 'a low REST budget still fetched'
fresh; : > "$W/slice-calls"
out="$(live "$W/budget-ok.sh")"
contains 'the live fetch assembles slices and prints the count as info' "$out" 'INFO runs-h=151'
n="$(wc -l < "$W/slice-calls" | tr -d '[:space:]')"
[ "$n" = 4 ] && pass 'the live fetch reads four 6 h slices' || fail "slice calls = $n, want 4"
out="$(live "$W/budget-ok.sh")"
n="$(wc -l < "$W/slice-calls" | tr -d '[:space:]')"
[ "$n" = 4 ] && pass 'a second read inside the cache TTL spends no new slice call' || fail "slice calls after cached read = $n, want 4"
contains 'the cached read still prints the info row' "$out" 'INFO runs-h=151'
[ ! -s "$W/gql-calls" ] && pass 'completed runs only: the live fetch spends no jobs call' || fail 'a read with no open run still fetched jobs'

# --- fetch path with an open run: its jobs come from one --gql jobs call and feed the concurrent-jobs line
gen "$RUN_1 | .node_id = \"WFR_1\"" 1 > "$W/open-run.json"
jq -nc '[range(0; 501)] | .[] | {run_id: 1, name: "job\(.)", status: "queued", conclusion: null, created_at: "2026-10-20T11:25:00Z", started_at: null, completed_at: null}' > "$W/jobs501.ndjson"
cat > "$W/metrics-gql-stub.sh" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
    --slice) cp "$W/open-run.json" "\$3/slice.\$4.json"; exit 0 ;;
    --gql) printf 'x\n' >> "$W/gql-calls"; cp "$W/jobs501.ndjson" "\$4.ndjson"; exit 0 ;;
esac
exec bash "$METRICS" "\$@"
STUB
livej() {
    CIGUARD_METRICS="$W/metrics-gql-stub.sh" CIGUARD_BUDGET="$W/budget-ok.sh" CIGUARD_REPO=o/r bash "$SUT" --now "$NOW" --state-dir "$W/state" 2>&1
}
fresh; : > "$W/gql-calls"
out="$(livej)"
contains 'the jobs of an open run feed the concurrent-jobs line' "$out" 'ALERT concurrent-jobs=501>500'
n="$(wc -l < "$W/gql-calls" | tr -d '[:space:]')"
[ "$n" = 1 ] && pass 'one open run costs one jobs call' || fail "jobs calls = $n, want 1"
out="$(livej)"
n="$(wc -l < "$W/gql-calls" | tr -d '[:space:]')"
[ "$n" = 1 ] && pass 'a read inside the cache TTL spends no new jobs call' || fail "jobs calls after cached read = $n, want 1"
contains 'the cached read still shows concurrent-jobs OVER' "$out" 'ciguard=OVER:concurrent-jobs'
not_contains 'the cached read does not alert twice' "$out" 'ALERT'
cat > "$W/metrics-gql-fail.sh" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
    --slice) cp "$W/open-run.json" "\$3/slice.\$4.json"; exit 0 ;;
    --gql) exit 1 ;;
esac
exec bash "$METRICS" "\$@"
STUB
fresh
out="$(CIGUARD_METRICS="$W/metrics-gql-fail.sh" CIGUARD_BUDGET="$W/budget-ok.sh" CIGUARD_REPO=o/r bash "$SUT" --now "$NOW" --state-dir "$W/state" 2>&1)"
contains 'a failed jobs call reads unknown, never ok' "$out" 'ciguard=unknown'

# --- decision 850: 200 runs in one hour is our own old run-count line, never a hold.
gen "$RUN_H" 200 > "$W/h200.json"
fresh; out="$(run "$W/h200.json")"
contains '200 runs in one hour reads ok under decision 850' "$out" 'ciguard=ok'
not_contains '200 runs in one hour raises no ALERT' "$out" 'ALERT'
contains '200 runs in one hour still prints its count as info' "$out" 'INFO runs-h=200'
# negative control: 500 concurrent jobs is the line, 501 is over
fresh; out="$(runj "$W/q500.json")"
contains '500 concurrent jobs reads ok (the line is 500)' "$out" 'ciguard=ok'
fresh; out="$(runj "$W/q501.json")"
contains '501 queued concurrent jobs reads OVER' "$out" 'ciguard=OVER:concurrent-jobs'
contains '501 queued concurrent jobs fires once' "$out" 'ALERT concurrent-jobs=501>500'
# negative control: a GitHub refusal in the run data reads OVER
jq 'map(.conclusion = "startup_failure")' "$W/one-run.json" > "$W/refused.json"
fresh; out="$(run "$W/refused.json")"
contains 'a startup_failure run (GitHub refusing to start it) reads OVER' "$out" 'ciguard=OVER:gh-refusal'
contains 'a GitHub refusal fires once' "$out" 'ALERT gh-refusal=1>0'

if [ "$fails" -eq 0 ]; then
    printf '%s\n' 'PASS - test-ci-guardrail.sh'
    exit 0
fi
printf 'FAIL - test-ci-guardrail.sh (%s failure(s))\n' "$fails"
exit 1
