#!/usr/bin/env bash
# scripts/ci/queue-latency.sh
#
# Read-only counts for the console tick: are GitHub Actions jobs waiting?
#   ci-queue: jobs_in_progress=N/500 macos=M/5 queued=Q oldest_wait=Xm
# The plan figure is report-only, never a dispatch gate. At most 32 live runs
# are sampled; sampled=true labels lower bounds. Observed waiting remains
# parseable by tick; a partial no-wait sample reads unknown during a storm.
# Any API error or unreadable body prints `ci-queue: unknown` and exits 0.
#
# Usage: queue-latency.sh [-R owner/repo]   (default: parsed from `origin`)
set -uo pipefail

# GitHub Enterprise standard hosted runners: 500 concurrent jobs
# (https://docs.github.com/en/actions/reference/limits). The org plan was
# confirmed through the org API. CI_MAX_JOBS overrides the reporting figure;
# its source is logged on stderr, preserving the stdout counts protocol.
cap_source=default:github-enterprise
[ "${CI_MAX_JOBS+x}" != x ] || cap_source=env:CI_MAX_JOBS
CI_MAX_JOBS="${CI_MAX_JOBS-500}"
valid_cap=1
case "$CI_MAX_JOBS" in
  ''|*[!0-9]*) valid_cap=0 ;;
  *[1-9]*) ;;
  *) valid_cap=0 ;;
esac
if [ "$valid_cap" -eq 0 ]; then
  echo "ci-queue: invalid CI_MAX_JOBS; using default 500" >&2
  CI_MAX_JOBS=500
  cap_source=default:github-enterprise
fi
echo "ci-queue: CI_MAX_JOBS=$CI_MAX_JOBS (source=$cap_source)" >&2
CI_MAX_MACOS=5

unknown() { echo "ci-queue: unknown"; exit 0; }

# shellcheck source=../lib/prim.sh
. "$(cd "$(dirname "$0")" && pwd)/../lib/prim.sh" || unknown

REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    -R) [ $# -ge 2 ] || { echo "usage: queue-latency.sh [-R owner/repo]" >&2; exit 2; }
        REPO="$2"; shift 2 ;;
    *) echo "usage: queue-latency.sh [-R owner/repo]" >&2; exit 2 ;;
  esac
done
if [ -z "$REPO" ]; then
  url="$(git remote get-url origin 2>/dev/null)" || unknown
  REPO="$(printf '%s' "$url" | sed -E 's#^.*[:/]([^/:]+/[^/]+)$#\1#; s#\.git$##')"
fi
[ -n "$REPO" ] || unknown

# shellcheck source=../lib/timeout-bin.sh
. "$(dirname "$0")/../lib/timeout-bin.sh" 2>/dev/null
# No timeout binary means no bounded read is possible.
[ -n "$_TIMEOUT_BIN" ] || unknown
GH_READ_SCRIPT="$(dirname "$0")/../lib/gh-read.sh"
gh_api() { "$_TIMEOUT_BIN" -k 1 5 bash "$GH_READ_SCRIPT" api "$@" 2>/dev/null; }

# The leading "#ok" row proves the body held a workflow_runs array, so a valid
# empty listing (no runs) is told apart from an empty or unparseable body.
RUNS_JQ='.workflow_runs | if type == "array" then "#ok", (.[] | [.id, .status, (.created_at | fromdateiso8601)] | @tsv) else error("workflow_runs is not an array") end'
# A run with more jobs than one page holds would undercount; read it as unknown.
JOBS_JQ='if (.jobs | type) != "array" then error("jobs is not an array")
         elif (.total_count // 0) > (.jobs | length) then error("jobs listing truncated")
         else . end
         | [ ([.jobs[] | select(.status=="in_progress")] | length),
           ([.jobs[] | select(.status=="in_progress" and ((.labels // []) | join(",") | test("macos")))] | length),
           ([.jobs[] | select(.status=="queued")] | length),
           ([.jobs[] | select(.status=="queued") | .created_at | fromdateiso8601] | min // 0) ] | @tsv'

# A run reports status=queued while any one of its jobs waits, even with other
# jobs running, so list every live status, paged past the first 100 runs.
runs=""
for st in in_progress queued pending; do
  listing="$(gh_api "repos/$REPO/actions/runs?status=$st&per_page=100" --paginate --jq "$RUNS_JQ")" || unknown
  case "$listing" in "#ok"*) ;; *) unknown ;; esac
  runs="$runs"$'\n'"$listing"
done
# In-progress first; dedupe by id (a run can appear in more than one list).
runs="$(printf '%s\n' "$runs" | awk 'NF && $1 !~ /^#/ && !seen[$1]++')"

# At 400 live runs: at most 6 listing pages + 32 jobs reads = 38 REST calls
# normally, 76 with gh-read's refused-token retry; at 20 probes/hour this is
# 760 normally, 1520 worst-case. Counts beyond the sample are lower bounds,
# explicitly labelled so exact-count readers can reject them.
MAX_RUNS=32
sampled=""
run_count="$(printf '%s\n' "$runs" | awk 'NF { n++ } END { print n+0 }')"
if [ "$run_count" -gt "$MAX_RUNS" ]; then
  runs="$(printf '%s\n' "$runs" | awk -v max="$MAX_RUNS" 'NR <= max')"
  sampled=" sampled=true"
fi

# Three 5s listing commands and two 5s jobs batches (plus 1s kill grace each)
# bound API waiting to 30s, inside the tick's default 45s probe timeout.
# A failed or empty read leaves no result file, which reads as unknown.
JOBS_TMP="$(tmpdir)" || unknown
trap 'rm -rf "$JOBS_TMP"' EXIT
JOBS_PAR=16
n=0
while IFS=$'\t' read -r id status created; do
  [ -n "$id" ] || continue
  (
    line="$(gh_api "repos/$REPO/actions/runs/$id/jobs?per_page=100" --jq "$JOBS_JQ")" && [ -n "$line" ] &&
      printf '%s\t%s\t%s\n' "$status" "$created" "$line" > "$JOBS_TMP/$id"
  ) &
  n=$((n + 1))
  [ $((n % JOBS_PAR)) -eq 0 ] && wait
done <<< "$runs"
wait

now="$(date +%s)"
ip=0; mac=0; q=0; oldest=0
while IFS=$'\t' read -r id status created; do
  [ -n "$id" ] || continue
  [ -s "$JOBS_TMP/$id" ] || unknown
  IFS=$'\t' read -r _ _ jip jmac jq_ jold < "$JOBS_TMP/$id"
  ip=$((ip + jip)); mac=$((mac + jmac)); q=$((q + jq_))
  cand="$jold"
  # A queued or pending run with no live jobs yet is still waiting; count it once.
  if { [ "$status" = "queued" ] || [ "$status" = "pending" ]; } && [ $((jip + jq_)) -eq 0 ]; then
    q=$((q + 1)); cand="$created"
  fi
  if [ "${cand:-0}" -gt 0 ] && { [ "$oldest" -eq 0 ] || [ "$cand" -lt "$oldest" ]; }; then oldest="$cand"; fi
done <<< "$runs"

wait_min=0
[ "$oldest" -gt 0 ] && wait_min=$(( (now - oldest) / 60 ))
[ "$wait_min" -lt 0 ] && wait_min=0
# Observed waiting proves contention even in a partial sample. Keep those
# counts parseable by tick with sampled=true on a separate metadata line.
# A partial no-wait sample cannot establish an idle queue and stays unknown.
if [ -n "$sampled" ] && { [ "$q" -gt 0 ] || [ "$wait_min" -gt 0 ]; }; then
  sampled=$'\nci-queue: sampled=true'
fi
echo "ci-queue: jobs_in_progress=$ip/$CI_MAX_JOBS macos=$mac/$CI_MAX_MACOS queued=$q oldest_wait=${wait_min}m$sampled"
