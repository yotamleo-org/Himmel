#!/usr/bin/env bash
# scripts/eval/test-ci-metrics.sh - suite for scripts/eval/ci-metrics.sh
# No live API: fixtures/ci-metrics/ is a recording of the real
# yotamleo/Himmel data (runs list + GraphQL checkRuns + the REST step count of
# cancelled jobs, as the script fetches it, trimmed to the fields it reads),
# taken 2026-10-14 17:24Z. It holds every run of one PR branch (CI runs cancelled
# by newer pushes, a green CI run, title-lint and review-gate runs) plus one
# cancelled scheduled CI run with no newer sibling. Fixture clock:
# --now 2026-10-14T12:00:00Z --days 3.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/ci-metrics.sh"
FIX="$HERE/fixtures/ci-metrics"
NOW="2026-10-14T12:00:00Z"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ci-metrics-test.XXXXXX")" || { echo "test-ci-metrics: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) pass "$1";; *) fail "$1: '$3' not in '$2'";; esac; }

OUT=$(bash "$SCRIPT" --data-dir "$FIX" --days 3 --now "$NOW" 2>&1); RC=$?
eq "fixture run: exit code" "$RC" "0"

# Totals below were summed from the fixture JSON with a separate jq program.
has "headline: runs" "$OUT" "| runs | 19 |"
has "headline: jobs" "$OUT" "| jobs | 173 |"
has "headline: cancelled runs" "$OUT" "| cancelled runs | 5 |"
has "headline: runner-min total" "$OUT" "| runner-min total | 550.5 |"
# 89 cancelled jobs report a start time but never got a runner (0 steps): they
# must not count as runner time, queue wait or concurrency.
has "headline: jobs cancelled before a runner" "$OUT" "| jobs cancelled before a runner took them | 89 |"
has "headline: runner-min burned by cancelled runs" "$OUT" "| runner-min in cancelled runs | 277.2 |"
# Counting the never-ran jobs as running puts this at 40+; the real figure is 8.
has "headline: peak concurrent in_progress jobs" "$OUT" "| peak concurrent in_progress jobs | 8 |"
has "headline: no hour reaches the 20-runner cap" "$OUT" "| hours with peak >= 20 / >= 40 | 0 / 0 of 29 |"

has "cause: four CI runs superseded by newer pushes" "$OUT" "| superseded | 4 | 0.7 |"
has "cause: the scheduled run has no newer run" "$OUT" "| no newer run (manual or other) | 1 | 276.5 |"

has "per-workflow table lists CI" "$OUT" "| CI | 5 | 160 |"
has "per-trigger table lists pull_request" "$OUT" "| pull_request | 14 | 137 |"
has "per-job table lists the shard job" "$OUT" "| shell-unit-shard (ubuntu-latest, 6) | 5 | 5 |"

has "jobs per push: distinct pull_request pushes" "$OUT" "| pull_request pushes (distinct head sha) | 4 |"
has "jobs per push: max" "$OUT" "| jobs per push max | 36 |"
has "peak table: busiest hour" "$OUT" "| 2026-10-13T05:00:00Z | 8 |"

# Cancel cause is inferred from the run set: keep only runs created up to the
# last cancelled pull_request run and nothing supersedes it any more.
LAST=$(jq -r '[.[] | select(.conclusion == "cancelled" and .event == "pull_request") | .created_at] | max' "$FIX/runs.json")
jq --arg c "$LAST" '[.[] | select(.created_at <= $c)]' "$FIX/runs.json" > "$TMP/runs.json"
cp "$FIX/jobs.json" "$TMP/jobs.json"
OUT2=$(bash "$SCRIPT" --data-dir "$TMP" --days 3 --now "$NOW" 2>&1)
has "cause: newest cancelled PR run is no-newer-run" "$OUT2" "| no newer run (manual or other) | 1 | 0.4 |"
has "cause: earlier cancelled PR runs stay superseded" "$OUT2" "| superseded | 3 | 0.3 |"

bash "$SCRIPT" --data-dir "$TMP" --days nope >/dev/null 2>&1; eq "bad --days exits 2" "$?" "2"
bash "$SCRIPT" --bogus >/dev/null 2>&1; eq "unknown flag exits 2" "$?" "2"
bash "$SCRIPT" --data-dir "$TMP/missing" --days 1 >/dev/null 2>&1; eq "--data-dir without runs.json and jobs.json exits 2" "$?" "2"

# ---- job-record measurement ----
# mk <dir> <jobs-json>: one CI pull_request run created 10:00:00Z on branch b, holding the given jobs.
mk() {
  mkdir -p "$1"
  echo '[{"id":1,"node_id":"WFR_1","name":"CI","event":"pull_request","status":"completed","conclusion":"success","created_at":"2026-10-20T10:00:00Z","run_started_at":"2026-10-20T10:00:00Z","updated_at":"2026-10-20T10:00:00Z","head_sha":"aaa","head_branch":"b","run_attempt":1,"pull_requests":[]}]' > "$1/runs.json"
  echo "$2" > "$1/jobs.json"
}
# jb <name> <conclusion> <created> <started> <completed>: a job of run 1 (times are 2026-10-20 HH:MM:SS).
jb() { printf '{"run_id":1,"name":"%s","status":"completed","conclusion":"%s","created_at":"2026-10-20T%sZ","started_at":"2026-10-20T%sZ","completed_at":"2026-10-20T%sZ"}' "$1" "$2" "$3" "$4" "$5"; }
M20=(--now 2026-10-20T12:00:00Z --days 1)

# A cancelled job whose started_at equals its created_at (+-1 s) never ran: no runner time, no queue wait.
mk "$TMP/never" "[$(jb a success 10:00:00 10:00:10 10:10:10),$(jb b cancelled 10:00:00 10:00:00 10:20:00),$(jb b2 cancelled 10:00:00 10:00:01 10:20:00),$(jb e cancelled 10:00:00 10:00:30 10:01:30)]"
O=$(bash "$SCRIPT" --data-dir "$TMP/never" "${M20[@]}" 2>&1)
has "never-ran: runner-min counts only jobs that ran" "$O" "| runner-min total | 11.0 |"
has "never-ran: queue wait counts only jobs that ran" "$O" "| job queue wait p50 / p90 / max (s) | 10 / 30 / 30 |"
has "never-ran: two cancelled-in-queue jobs reported" "$O" "| jobs cancelled before a runner took them | 2 |"
has "never-ran: cancelled jobs without a REST answer are counted" "$O" "| cancelled jobs judged without a REST answer | 3 |"

# A skipped job is never queued: its started_at is its skip time, not a runner pick-up.
mk "$TMP/skip" "[$(jb a success 10:00:00 10:00:10 10:10:10),$(jb s skipped 10:00:00 10:05:00 10:05:00)]"
O=$(bash "$SCRIPT" --data-dir "$TMP/skip" "${M20[@]}" 2>&1)
has "skipped job: no queue wait" "$O" "| job queue wait p50 / p90 / max (s) | 10 / 10 / 10 |"

# A job still running past --now is cut at --now.
mk "$TMP/cap" "[$(jb x success 10:00:00 10:00:00 11:00:00)]"
O=$(bash "$SCRIPT" --data-dir "$TMP/cap" --now 2026-10-20T10:30:00Z --days 1 2>&1)
has "now cap: runner-min stops at --now" "$O" "| runner-min total | 30.0 |"

# An interval ending exactly on the hour does not count in the next hour.
mk "$TMP/hour" "[$(jb x success 10:00:00 10:00:00 11:00:00)]"
O=$(bash "$SCRIPT" --data-dir "$TMP/hour" "${M20[@]}" --hourly 2>&1)
has "hour boundary: the starting hour counts the job" "$O" "| 2026-10-20T10:00:00Z | 1 |"
has "hour boundary: the next hour does not" "$O" "| 2026-10-20T11:00:00Z | 0 |"
# Several jobs ending together on the hour boundary leave only the survivors in the next hour.
mk "$TMP/hour3" "[$(jb x success 10:00:00 10:00:00 11:00:00),$(jb y success 10:00:00 10:00:00 11:00:00),$(jb z success 10:00:00 10:00:00 11:00:00),$(jb w success 10:00:00 10:00:00 11:30:00)]"
O=$(bash "$SCRIPT" --data-dir "$TMP/hour3" "${M20[@]}" --hourly 2>&1)
has "hour boundary: three endings at once leave one in the next hour" "$O" "| 2026-10-20T11:00:00Z | 1 |"

# --days and --top accept .5 and 08 (not valid JSON numbers as typed).
O=$(bash "$SCRIPT" --data-dir "$TMP/hour" --now 2026-10-20T12:00:00Z --days .5 2>&1); eq "--days .5 exits 0" "$?" "0"
has "--days .5 is read as 0.5" "$O" "(0.5 days)"
O=$(bash "$SCRIPT" --data-dir "$TMP/hour" --now 2026-10-20T12:00:00Z --days 08 2>&1); eq "--days 08 exits 0" "$?" "0"
has "--days 08 is read as 8" "$O" "(8 days)"
bash "$SCRIPT" --data-dir "$TMP/hour" "${M20[@]}" --top 08 >/dev/null 2>&1; eq "--top 08 exits 0" "$?" "0"

# Guardrail rates: 12 runs of branch b1 in hour 10 (4 cancelled within 3 min, 2 reruns) and 3 of b2 in hour 11.
mkdir -p "$TMP/guard"
jq -n '
  def hhmm($i): ($i | tostring | if length < 2 then "0" + . else . end);
  [range(0; 12) as $i | ("2026-10-20T10:\(hhmm($i)):00Z") as $c
    | {id: (100 + $i), node_id: "n\($i)", name: "CI", event: "push", status: "completed",
       conclusion: (if $i < 4 then "cancelled" else "success" end), created_at: $c, run_started_at: $c,
       updated_at: (if $i < 4 then ["2026-10-20T10:05:00Z", "2026-10-20T10:05:30Z", "2026-10-20T10:06:00Z", "2026-10-20T10:07:00Z"][$i] else $c end),
       head_sha: "s\($i)", head_branch: "b1", run_attempt: (if $i == 8 or $i == 9 then 2 else 1 end), pull_requests: []}]
  + [range(0; 3) as $i | ("2026-10-20T11:\(hhmm($i)):00Z") as $c
    | {id: (200 + $i), node_id: "m\($i)", name: "CI", event: "push", status: "completed", conclusion: "success",
       created_at: $c, run_started_at: $c, updated_at: $c, head_sha: "t\($i)", head_branch: "b2", run_attempt: 1, pull_requests: []}]' > "$TMP/guard/runs.json"
echo '[]' > "$TMP/guard/jobs.json"
O=$(bash "$SCRIPT" --data-dir "$TMP/guard" "${M20[@]}" 2>&1)
has "guardrail: runs per hour" "$O" "| runs per hour, max | 12 (2026-10-20T10:00:00Z) | 150 | OK |"
has "guardrail: runs per rolling 24 h" "$O" "| runs per rolling 24 h, max | 15 | 1500 | OK |"
has "guardrail: cancels per rolling 10 min" "$O" "| cancels per rolling 10 min, max | 4 | 30 | OK |"
has "guardrail: reruns per hour" "$O" "| reruns per hour, max | 2 (2026-10-20T10:00:00Z) | 10 | OK |"
has "guardrail: runs per branch per day" "$O" "| runs per branch per day, max | 12 (b1 2026-10-20) | 6 | OVER |"
has "guardrail: branch-days over the line" "$O" "| branch-days over 6 runs | 1 | - | - |"

# --cap-check: per-minute running / queued and a verdict on the 60-runner ceiling.
# capjobs <running> <queued>: <running> jobs run 10:00-10:30 (created 09:59:50), <queued> wait from 10:00 to 10:30 (REST created_at).
capjobs() {
  jq -n --argjson n "$1" --argjson q "$2" '
    [range(0; $n) as $i | {run_id: 1, name: "r\($i)", status: "completed", conclusion: "success", created_at: "2026-10-20T09:59:50Z", started_at: "2026-10-20T10:00:00Z", completed_at: "2026-10-20T10:30:00Z", rest: true}]
    + [range(0; $q) as $i | {run_id: 1, name: "q\($i)", status: "completed", conclusion: "success", created_at: "2026-10-20T10:00:00Z", started_at: "2026-10-20T10:30:00Z", completed_at: "2026-10-20T10:40:00Z", rest: true}]'
}
CAP=(--cap-check --hours 1 --now 2026-10-20T11:00:00Z)
mk "$TMP/cap-pass" "$(capjobs 65 0)"
O=$(bash "$SCRIPT" --data-dir "$TMP/cap-pass" "${CAP[@]}" 2>&1); RC=$?
has "cap-check PASS: verdict" "$O" "Verdict: PASS"
has "cap-check PASS: says the queue evidence is a lower bound" "$O" "queue is a lower bound"
has "cap-check PASS: per-minute row" "$O" "| 2026-10-20T10:00:00Z | 65 | 0 |"
eq "cap-check PASS: exit 0" "$RC" "0"
mk "$TMP/cap-fail" "$(capjobs 60 10)"
O=$(bash "$SCRIPT" --data-dir "$TMP/cap-fail" "${CAP[@]}" 2>&1); RC=$?
has "cap-check FAIL: verdict" "$O" "Verdict: FAIL"
has "cap-check FAIL: per-minute row" "$O" "| 2026-10-20T10:00:00Z | 60 | 10 |"
eq "cap-check FAIL: exit 1" "$RC" "1"
# Jobs cancelled while queued waited for a runner until the cancel: that wait is cap-check demand.
mk "$TMP/cap-cq" "$(jq -n --argjson r "$(capjobs 60 0)" '$r + [range(0; 10) as $i | {run_id: 1, name: "c\($i)", status: "completed", conclusion: "cancelled", created_at: "2026-10-20T10:00:00Z", started_at: "2026-10-20T10:00:00Z", completed_at: "2026-10-20T10:30:00Z", rest: true, ran: false}]')"
O=$(bash "$SCRIPT" --data-dir "$TMP/cap-cq" "${CAP[@]}" 2>&1); RC=$?
has "cap-check FAIL: jobs cancelled while queued count as queued demand" "$O" "| 2026-10-20T10:00:00Z | 60 | 10 |"
eq "cap-check FAIL with cancelled-while-queued jobs: exit 1" "$RC" "1"
mk "$TMP/cap-inc" "$(capjobs 10 0)"
O=$(bash "$SCRIPT" --data-dir "$TMP/cap-inc" "${CAP[@]}" 2>&1); RC=$?
has "cap-check INCONCLUSIVE: verdict" "$O" "Verdict: INCONCLUSIVE"
eq "cap-check INCONCLUSIVE: exit 0" "$RC" "0"
bash "$SCRIPT" --data-dir "$TMP/cap-inc" --days 1 --hours 1 >/dev/null 2>&1; eq "--days with --hours exits 2" "$?" "2"

# ---- fetch path against a fake gh: the REST/GraphQL shapes are recordings of CI run 39374772228 ----
LIVE="$HERE/fixtures/ci-metrics-live"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$*" in
  "api graphql"*) if [ -n "${GH_GQL:-}" ]; then cat "$GH_GQL"; else echo "GRAPHQL CALLED" >&2; exit 1; fi;;
  *"/actions/runs/"*"/jobs"*) cat "$GH_REST_JOBS";;
  *"/actions/runs?"*) cat "$GH_RUNS";;
  *) exit 1;;
esac
GH
chmod +x "$TMP/bin/gh"
export CI_METRICS_PACE=0

# An empty window must not dispatch the unmatched chunk glob to GraphQL.
echo '[{"workflow_runs":[]}]' > "$TMP/empty-runs.json"
: > "$TMP/gh-empty.log"
O=$(PATH="$TMP/bin:$PATH" GH_LOG="$TMP/gh-empty.log" GH_RUNS="$TMP/empty-runs.json" bash "$SCRIPT" --days 1 --now 2026-10-20T12:00:00Z 2>&1); RC=$?
eq "empty window: exit code" "$RC" "0"
has "empty window: zero runs" "$O" "| runs | 0 |"
eq "empty window: no GraphQL call" "$(grep -c graphql "$TMP/gh-empty.log")" "0"
has "default repo is the org slug" "$(cat "$TMP/gh-empty.log")" "repos/yotamleo-org/Himmel/actions/runs?"

: > "$TMP/gh-live.log"
O=$(PATH="$TMP/bin:$PATH" GH_LOG="$TMP/gh-live.log" GH_RUNS="$LIVE/runs-page.json" GH_GQL="$LIVE/graphql.json" GH_REST_JOBS="$LIVE/rest-jobs.json" \
  bash "$SCRIPT" --days 0.04 --now 2026-10-20T05:45:00Z 2>&1); RC=$?
eq "live run: exit code" "$RC" "0"
has "live run: GraphQL asked for the run's node id" "$(cat "$TMP/gh-live.log")" "ids[]=WFR_kwLOS8WKNM8AAAAJKutYBA"
has "live run: REST jobs read for the cancelled run" "$(cat "$TMP/gh-live.log")" "repos/yotamleo-org/Himmel/actions/runs/39374772228/jobs"
has "live run: 50 jobs" "$O" "| jobs | 50 |"
# 20 jobs ran (REST steps); the 5 cancelled with started == created never did; 25 were skipped.
has "live run: runner-min from the 20 jobs that ran (2298 s)" "$O" "| runner-min total | 38.3 |"
has "live run: queue wait from the job's own created_at" "$O" "| job queue wait p50 / p90 / max (s) | 2 / 2 / 2 |"
has "live run: 5 cancelled-in-queue jobs" "$O" "| jobs cancelled before a runner took them | 5 |"

echo "ci-metrics: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
