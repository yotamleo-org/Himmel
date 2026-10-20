#!/usr/bin/env bash
# test-ci-guardrail.sh — Hermetic tests for ci-guardrail.sh: one fires-once /
# quiet-below-the-line row per threshold, the real 10-19 19Z and 10-15 replays, the re-arm
# cycle, and the fetch path (budget gate, slice assembly, cache). No network: gh is never
# called; the fetch rows drive a stub standing in for ci-metrics.sh --slice.
#
# PLATFORM GUARD: no .ps1 twin, by design. The console kit is Linux-only.
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

# --- runs/h: 150 in one clock hour is the line, 151 is over
RUN_H='{id: ., name: "PR Title Lint", event: "pull_request", status: "completed", conclusion: "success", head_branch: "b\(. % 40)", head_sha: "s\(.)", run_attempt: 1,
        created_at: "2026-10-20T10:\(. % 60 | tostring | if length < 2 then "0" + . else . end):00Z", run_started_at: "2026-10-20T10:00:00Z", updated_at: "2026-10-20T10:59:59Z"}'
gen "$RUN_H" 150 > "$W/h150.json"; gen "$RUN_H" 151 > "$W/h151.json"
fresh; out="$(run "$W/h150.json")"
contains 'runs/h at 150 reads ok' "$out" 'ciguard=ok'
not_contains 'runs/h at 150 raises no alert' "$out" 'ALERT'
fresh; out="$(run "$W/h151.json")"
contains 'runs/h at 151 fires once' "$out" 'ALERT runs-h=151>150'
contains 'runs/h at 151 reads OVER' "$out" 'ciguard=OVER:runs-h'

# --- runs/day: 1500 in a rolling 24 h is the line, 1501 is over (never more than 100 in one hour)
RUN_D='{id: ., name: "PR Title Lint", event: "pull_request", status: "completed", conclusion: "success", head_branch: "b\(. % 40)", head_sha: "s\(.)", run_attempt: 1,
        created_at: (1792494000 - 86000 + . * 57 | todate), run_started_at: (1792494000 - 86000 + . * 57 | todate), updated_at: (1792494000 - 86000 + . * 57 | todate)}'
gen "$RUN_D" 1500 > "$W/d1500.json"; gen "$RUN_D" 1501 > "$W/d1501.json"
fresh; out="$(run "$W/d1500.json" "$W/state" 2026-10-20T11:00:00Z)"
contains 'runs/day at 1500 reads ok' "$out" 'ciguard=ok'
fresh; out="$(run "$W/d1501.json" "$W/state" 2026-10-20T11:00:00Z)"
contains 'runs/day at 1501 fires once' "$out" 'ALERT runs-day=1501>1500'

# --- cancels per 10 min: 30 is the line, 31 is over
CANC='{id: ., name: "CI", event: "pull_request", status: "completed", conclusion: "cancelled", head_branch: "b\(.)", head_sha: "s\(.)", run_attempt: 1,
       created_at: "2026-10-20T11:00:00Z", run_started_at: "2026-10-20T11:00:00Z", updated_at: "2026-10-20T11:20:\(. % 60 | tostring | if length < 2 then "0" + . else . end)Z"}'
gen "$CANC" 30 > "$W/c30.json"; gen "$CANC" 31 > "$W/c31.json"
fresh; out="$(run "$W/c30.json")"
contains 'cancels at 30 per 10 min reads ok' "$out" 'ciguard=ok'
fresh; out="$(run "$W/c31.json")"
contains 'cancels at 31 per 10 min fires once' "$out" 'ALERT cancels-10m=31>30'

# --- reruns/h: 10 is the line, 11 is over
RERUN='{id: ., name: "CI", event: "pull_request", status: "completed", conclusion: "success", head_branch: "b\(.)", head_sha: "s\(.)", run_attempt: 2,
        created_at: "2026-10-20T10:00:00Z", run_started_at: "2026-10-20T10:\(. % 60 | tostring | if length < 2 then "0" + . else . end):00Z", updated_at: "2026-10-20T10:59:00Z"}'
gen "$RERUN" 10 > "$W/r10.json"; gen "$RERUN" 11 > "$W/r11.json"
fresh; out="$(run "$W/r10.json")"
contains 'reruns at 10 per hour reads ok' "$out" 'ciguard=ok'
fresh; out="$(run "$W/r11.json")"
contains 'reruns at 11 per hour fires once' "$out" 'ALERT reruns-h=11>10'

# --- CI runs per branch per day: 10 is the line (the 10-15 data tops out at 9), 11 is over.
# Only the CI workflow counts, main never does, and a run older than 24 h is outside the day.
BR='{id: ., name: "CI", event: "pull_request", status: "completed", conclusion: "success", head_branch: "feat/x", head_sha: "s\(.)", run_attempt: 1,
     created_at: "2026-10-20T0\(. % 10):00:00Z", run_started_at: "2026-10-20T00:00:00Z", updated_at: "2026-10-20T09:59:00Z"}'
gen "$BR" 10 > "$W/b10.json"; gen "$BR" 11 > "$W/b11.json"
fresh; out="$(run "$W/b10.json")"
contains 'a branch at 10 CI runs reads ok' "$out" 'ciguard=ok'
fresh; out="$(run "$W/b11.json")"
contains 'a branch at 11 CI runs fires once' "$out" 'ALERT branch-day=11>10 (feat/x)'
jq 'map(.head_branch = "main")' "$W/b11.json" > "$W/b11-main.json"
fresh; out="$(run "$W/b11-main.json")"
contains 'main never counts as a busy branch' "$out" 'ciguard=ok'
jq 'map(.name = "PR Title Lint")' "$W/b11.json" > "$W/b11-gate.json"
fresh; out="$(run "$W/b11-gate.json")"
contains 'a gate workflow never counts as a CI run' "$out" 'ciguard=ok'
jq 'map(.created_at = "2026-10-18T01:00:00Z" | .updated_at = "2026-10-18T01:01:00Z")' "$W/b11.json" > "$W/b11-old.json"
fresh; out="$(run "$W/b11-old.json")"
contains 'runs older than 24 h are outside the day' "$out" 'ciguard=ok'

# --- the real replays (runs copied from the GitHub API for those windows)
gzip -dc "$FIX/runs-2026-10-19-19Z.json.gz" > "$W/r1019.json"
gzip -dc "$FIX/runs-2026-10-15.json.gz" > "$W/r1015.json"
fresh; out="$(run "$W/r1019.json" "$W/state" 2026-10-19T20:05:00Z)"
contains 'the 10-19 19Z replay (262 runs) fires the runs/h alert' "$out" 'ALERT runs-h=262>150 (2026-10-19T19:00:00Z)'
fresh; out="$(run "$W/r1015.json" "$W/state" 2026-10-16T00:00:00Z)"
contains 'the 10-15 replay stays quiet' "$out" 'ciguard=ok'
not_contains 'the 10-15 replay raises no alert' "$out" 'ALERT'

# --- alert once per crossing, re-arm below the line
fresh
out1="$(run "$W/h151.json")"; out2="$(run "$W/h151.json")"
contains 'the first read of a crossing alerts' "$out1" 'ALERT runs-h=151>150'
not_contains 'the second read of the same crossing stays silent' "$out2" 'ALERT'
contains 'the second read still shows the state' "$out2" 'ciguard=OVER:runs-h'
out3="$(run "$W/h150.json")"
contains 'a read below the line clears the state' "$out3" 'ciguard=ok'
out4="$(run "$W/h151.json")"
contains 'the next crossing alerts again (re-armed)' "$out4" 'ALERT runs-h=151>150'

# --- unknown never changes the state
fresh
run "$W/h151.json" >/dev/null
out="$(run "$W/missing.json")"
contains 'an unreadable runs file reads unknown' "$out" 'ciguard=unknown'
out="$(run "$W/h151.json")"
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
contains 'the live fetch assembles slices and alerts' "$out" 'ALERT runs-h=1'
n="$(wc -l < "$W/slice-calls" | tr -d '[:space:]')"
[ "$n" = 4 ] && pass 'the live fetch reads four 6 h slices' || fail "slice calls = $n, want 4"
out="$(live "$W/budget-ok.sh")"
n="$(wc -l < "$W/slice-calls" | tr -d '[:space:]')"
[ "$n" = 4 ] && pass 'a second read inside the cache TTL spends no new slice call' || fail "slice calls after cached read = $n, want 4"
not_contains 'the cached read does not alert twice' "$out" 'ALERT'

if [ "$fails" -eq 0 ]; then
    printf '%s\n' 'PASS - test-ci-guardrail.sh'
    exit 0
fi
printf 'FAIL - test-ci-guardrail.sh (%s failure(s))\n' "$fails"
exit 1
