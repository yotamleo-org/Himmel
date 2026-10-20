#!/usr/bin/env bash
# scripts/eval/ci-metrics.sh - CI baseline from GitHub Actions data.
#
# Read-only against the GitHub API for one repo: the REST runs list (6 h slices,
# the list caps at 1000 per query) plus GraphQL WorkflowRun -> checkSuite ->
# checkRuns for the jobs, 100 runs per query. Prints a markdown baseline: queue
# wait and run time per workflow / trigger / job name, the conclusion mix,
# runner-minutes burned by cancelled runs split by inferred cause, jobs per PR
# push, and the PEAK concurrent in_progress jobs per hour reconstructed from job
# start/end intervals.
#
# Usage: ci-metrics.sh [--days N | --hours N] [--repo OWNER/NAME] [--top N] [--hourly]
#                      [--cap-check] [--keep DIR] [--cache DIR] [--data-dir DIR] [--now ISO8601]
#   --days N      window length in days, fractions allowed (default 7)
#   --hours N     window length in hours instead (fractions allowed)
#   --cap-check   instead of the baseline, print the per-minute running count and queued
#                 jobs over the window and a PASS / FAIL / INCONCLUSIVE verdict on the
#                 runner ceiling (plan section 1.2): PASS = some minute runs
#                 more than 60 jobs and no 10-minute stretch has jobs queued while running <= 60;
#                 FAIL = running sits flat at exactly 20, 40 or 60 for 10 minutes while jobs
#                 are queued and never exceeds 60; INCONCLUSIVE = anything else (usually demand
#                 never reached 60: re-run after the next busy window, never create load).
#                 Queued counts only jobs whose own created_at was read from REST (runs holding
#                 a cancelled job) and jobs still waiting at the window end: a lower bound.
#   --top N       rows in the per-job-name table (default 30)
#   --hourly      print every hour of the peak table, not the top 10
#   --keep DIR    save the fetched runs.json + jobs.json there
#   --cache DIR   reuse/store each GraphQL chunk there, so a re-run never re-fetches
#                 (a cached chunk keeps the state it had when fetched)
#   --data-dir D  analyse a saved/recorded dataset instead of calling the API
#   --now ISO     fixed clock (tests); still-running jobs end at this instant
# Exit: 0 ok, 1 --cap-check verdict FAIL, 2 usage, 3 API/rate-limit problem.
#
# Pacing: calls run one at a time, 1 s apart, and back off 60 s on a 403/429 (the
# account shares one secondary rate limit with every other session). That makes a
# cold 7-day run far slower than 5 minutes; --cache makes a re-run free, and a
# 3-day window is the practical snapshot.
#
# Why GraphQL for jobs: REST needs one /runs/{id}/jobs call per run, ~7000 a week
# here against a 5000/hour quota shared with every other session; GraphQL is
# ~70 calls. GraphQL cannot give a job's steps (HTTP 502 even at 10 runs per
# query), and a job cancelled while queued reports started_at = created_at with
# no steps, so for each run holding a cancelled job one REST /runs/{id}/jobs call
# reads every job's step count and created_at. A cancelled job never ran if it has 0
# steps or (without a REST answer) started_at equals created_at within 1 s; it gets
# no runner time, queue wait or concurrency interval. A skipped job is never queued
# either. A run whose REST call fails is warned about and judged by the started_at
# rule alone; the baseline counts those jobs (a gated job cancelled while queued can look
# like it ran there, since GraphQL gives only the run's created_at).
# The price of GraphQL: a job's created_at is not exposed, so queue wait is
# measured from the RUN's creation unless REST gave the job's own created_at (runs
# holding a cancelled job). That is exact for jobs with no `needs` and
# overstates a job gated behind others (its wait includes the upstream jobs'
# run time). Only the latest attempt of a re-run is visible.
# ponytail: queue wait of gated jobs outside REST-read runs includes upstream time,
# upgrade path = REST /runs/{id}/jobs?filter=all for every run when exact job created_at matters.
#
# Guardrail rates (plan section 1.3) come from the runs list: runs per hour and per
# rolling 24 h, cancels per rolling 10 min (by updated_at), reruns per hour (attempt
# above 1, by run_started_at), runs per branch per day; each against its alert line.
#
# Cancel cause is INFERRED, not read: the API does not say who cancelled a run.
# "superseded" = a newer run of the same workflow + branch + trigger was created
# between this run's creation and 2 minutes after its last update (the
# concurrency cancel-in-progress signature); anything else is "no newer run
# (manual or other)". ponytail: heuristic, upgrade path = the audit-log API
# (org-only) if the repo ever moves under an organization.
# The per-run /timing endpoint is not called: for a user-owned public repo it
# returns {"billable":{}} with no run_duration_ms, so job intervals are the
# source of truth for runner time.
set -u

SELF="${BASH_SOURCE[0]}"
SLICE_SECS=21600
JOBS_CHUNK=100
PAR=1
PACE="${CI_METRICS_PACE:-1}"

die() { echo "ci-metrics: $2" >&2; exit "$1"; }

# Hidden workers (run one at a time, PACE s apart: the account shares one secondary
# rate limit with every other session). Each retries 3x, backing off 60 s on a rate limit.
# --slice <repo> <out> <idx> <from> <to>: the runs created in one 6 h slice.
if [ "${1:-}" = "--slice" ]; then
  repo="$2"; out="$3"; idx="$4"; a="$5"; b="$6"
  for _try in 1 2 3; do
    if gh api "repos/$repo/actions/runs?created=$a..$b&per_page=100" --paginate --slurp 2>/dev/null \
      | jq -c '[.[].workflow_runs[]]' > "$out/slice.$idx.tmp" && [ -s "$out/slice.$idx.tmp" ]; then
      mv "$out/slice.$idx.tmp" "$out/slice.$idx.json"; sleep "$PACE"; exit 0
    fi
    sleep 60
  done
  echo "ci-metrics: runs fetch failed for $a..$b" >&2; exit 1
fi
# --runjobs <repo> <run id> <out>: REST jobs of one run, reduced to each job's step count and created_at.
if [ "${1:-}" = "--runjobs" ]; then
  repo="$2"; rid="$3"; out="$4"
  if [ -n "${CI_METRICS_CACHE:-}" ] && [ -f "$CI_METRICS_CACHE/rj.$rid.ndjson" ]; then
    cp "$CI_METRICS_CACHE/rj.$rid.ndjson" "$out.ndjson"; exit 0
  fi
  for _try in 1 2 3; do
    if gh api "repos/$repo/actions/runs/$rid/jobs?per_page=100" 2> "$out.err" > "$out.raw" \
      && jq -c --argjson r "$rid" '.jobs[] | {run_id: $r, name, created_at, steps: (.steps | length)}' "$out.raw" > "$out.tmp"; then
      mv "$out.tmp" "$out.ndjson"
      if [ -n "${CI_METRICS_CACHE:-}" ]; then cp "$out.ndjson" "$CI_METRICS_CACHE/rj.$rid.ndjson"; fi
      sleep "$PACE"; exit 0
    fi
    if grep -qiE 'rate limit|HTTP 403|HTTP 429' "$out.err" "$out.raw" 2>/dev/null; then sleep 60; else sleep 10; fi
  done
  # One run that will not answer must not sink the dataset: its cancelled jobs fall back to the started_at rule.
  echo "ci-metrics: WARN run jobs fetch failed for run $rid ($(head -c 100 "$out.err")); its cancelled jobs are judged by started_at alone" >&2
  : > "$out.ndjson"; exit 0
fi
# --gql jobs <ids-file> <out>: the jobs of <=100 runs.
if [ "${1:-}" = "--gql" ]; then
  mode="$2"; idsf="$3"; out="$4"
  key="$mode.$(md5sum < "$idsf" | cut -c1-32)"
  if [ -n "${CI_METRICS_CACHE:-}" ] && [ -s "$CI_METRICS_CACHE/$key.ndjson" ]; then
    cp "$CI_METRICS_CACHE/$key.ndjson" "$out.ndjson"; exit 0
  fi
  set --
  while IFS= read -r nid; do set -- "$@" -f "ids[]=$nid"; done < "$idsf"
  # shellcheck disable=SC2016  # GraphQL/jq text, $ is not shell
  q='query($ids:[ID!]!){ nodes(ids:$ids){ ... on WorkflowRun { databaseId createdAt checkSuite{ checkRuns(first:100){ totalCount nodes{ name status conclusion startedAt completedAt } } } } } }'
  # shellcheck disable=SC2016  # jq program, $ is not shell
  f='.data.nodes[] | . as $r | .checkSuite.checkRuns | (if .totalCount > 100 then error("more than 100 jobs in one run") else . end)
     | .nodes[] | {run_id: $r.databaseId, name, status: (.status | ascii_downcase), conclusion: (if .conclusion == null then null else (.conclusion | ascii_downcase) end),
                   created_at: $r.createdAt, started_at: .startedAt, completed_at: .completedAt}'
  for _try in 1 2 3; do
    # A null node = a run GraphQL could not resolve: the dataset would silently lose its jobs.
    if gh api graphql -f query="$q" "$@" 2> "$out.err" > "$out.raw" \
      && jq -e '.errors == null and (.data.nodes | all(. != null))' "$out.raw" >/dev/null \
      && jq -c "$f" "$out.raw" > "$out.tmp"; then
      mv "$out.tmp" "$out.ndjson"
      if [ -n "${CI_METRICS_CACHE:-}" ]; then cp "$out.ndjson" "$CI_METRICS_CACHE/$key.ndjson"; fi
      sleep "$PACE"; exit 0
    fi
    if grep -qiE 'rate limit|HTTP 403|HTTP 429' "$out.err" "$out.raw" 2>/dev/null; then sleep 60; else sleep 10; fi
  done
  echo "ci-metrics: graphql $mode fetch failed for $idsf: $(head -c 300 "$out.err") $(head -c 300 "$out.raw")" >&2; exit 1
fi


DAYS=""; HOURS=""; REPO="yotamleo-org/Himmel"; TOP=30; HOURLY=0; CAPCHECK=0; KEEP=""; DATA=""; NOW=""; CACHE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --days) [ $# -ge 2 ] || die 2 "--days needs a value"; DAYS="$2"; shift 2;;
    --hours) [ $# -ge 2 ] || die 2 "--hours needs a value"; HOURS="$2"; shift 2;;
    --repo) [ $# -ge 2 ] || die 2 "--repo needs a value"; REPO="$2"; shift 2;;
    --top) [ $# -ge 2 ] || die 2 "--top needs a value"; TOP="$2"; shift 2;;
    --keep) [ $# -ge 2 ] || die 2 "--keep needs a value"; KEEP="$2"; shift 2;;
    --cache) [ $# -ge 2 ] || die 2 "--cache needs a value"; CACHE="$2"; shift 2;;
    --data-dir) [ $# -ge 2 ] || die 2 "--data-dir needs a value"; DATA="$2"; shift 2;;
    --now) [ $# -ge 2 ] || die 2 "--now needs a value"; NOW="$2"; shift 2;;
    --hourly) HOURLY=1; shift;;
    --cap-check) CAPCHECK=1; shift;;
    -h|--help) sed -n '2,/^set -u/p' "$SELF" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0;;
    *) die 2 "unknown argument: $1";;
  esac
done
[ -z "$DAYS" ] || [ -z "$HOURS" ] || die 2 "--days and --hours are exclusive"
# num <flag> <value>: a positive decimal in canonical form (.5 -> 0.5, 08 -> 8), safe for jq --argjson on any jq.
num() {
  case "$2" in ''|*[!0-9.]*|.|*.*.*) die 2 "$1 must be a positive number, got '$2'";; esac
  awk -v d="$2" 'BEGIN { exit !(d + 0 > 0 && d + 0 < 1e9) }' || die 2 "$1 must be positive and below 1e9, got '$2'"
  awk -v d="$2" 'BEGIN { printf "%.10g", d + 0 }'
}
if [ -n "$HOURS" ]; then
  HOURS=$(num --hours "$HOURS") || exit 2
  DAYS=$(awk -v h="$HOURS" 'BEGIN { printf "%.10g", h / 24 }'); WINDOW_LABEL="$HOURS hours"
else
  DAYS=$(num --days "${DAYS:-7}") || exit 2; WINDOW_LABEL="$DAYS days"
fi
case "$TOP" in ''|*[!0-9]*) die 2 "--top must be an integer";; esac
TOP=$((10#$TOP))
command -v jq >/dev/null 2>&1 || die 3 "jq is required"

if [ -n "$NOW" ]; then
  NOW_EPOCH=$(jq -rn --arg n "$NOW" '$n|fromdateiso8601') || die 2 "--now must be ISO 8601 (YYYY-MM-DDTHH:MM:SSZ)"
else
  NOW_EPOCH=$(date -u +%s)
fi
if [ -n "$HOURS" ]; then
  START_EPOCH=$(awk -v n="$NOW_EPOCH" -v h="$HOURS" 'BEGIN { printf "%d", n - h * 3600 }')
else
  START_EPOCH=$(awk -v n="$NOW_EPOCH" -v d="$DAYS" 'BEGIN { printf "%d", n - d * 86400 }')
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ci-metrics.XXXXXX")" || die 3 "mktemp -d failed"
trap 'rm -rf "$WORK"' EXIT

if [ -n "$DATA" ]; then
  [ -f "$DATA/runs.json" ] && [ -f "$DATA/jobs.json" ] || die 2 "--data-dir needs runs.json and jobs.json"
  RUNS="$DATA/runs.json"; JOBS="$DATA/jobs.json"
else
  command -v gh >/dev/null 2>&1 || die 3 "gh is required"
  RUNS="$WORK/runs.json"; JOBS="$WORK/jobs.json"
  mkdir -p "$WORK/slices" "$WORK/jobs" "$WORK/steps"
  if [ -n "$CACHE" ]; then mkdir -p "$CACHE" || die 3 "cannot create cache dir"; export CI_METRICS_CACHE="$CACHE"; fi
  # created=a..b is capped at 1000 results per query, hence the 6 h slices.
  s=$START_EPOCH; idx=0
  while [ "$s" -lt "$NOW_EPOCH" ]; do
    e=$((s + SLICE_SECS)); [ "$e" -gt "$NOW_EPOCH" ] && e=$NOW_EPOCH
    idx=$((idx + 1))
    echo "$idx $(jq -rn --argjson x "$s" '$x|todate') $(jq -rn --argjson x "$e" '$x|todate')"
    s=$e
  done > "$WORK/slices.txt"
  xargs -P "$PAR" -L 1 bash "$SELF" --slice "$REPO" "$WORK/slices" < "$WORK/slices.txt" || die 3 "runs fetch failed"
  for f in "$WORK"/slices/slice.*.json; do
    [ "$(jq 'length' "$f")" -ge 1000 ] && echo "ci-metrics: WARN a 6 h slice returned 1000 runs (API cap): window is truncated" >&2
  done
  jq -s 'add|unique_by(.id)|map({id,node_id,name,event,status,conclusion,created_at,run_started_at,updated_at,head_sha,head_branch,run_attempt,pull_requests:[.pull_requests[]?|{number}]})|sort_by(.created_at)' \
    "$WORK"/slices/slice.*.json > "$RUNS" || die 3 "could not assemble runs"
  jq -r '.[].node_id' "$RUNS" > "$WORK/nodes.txt"
  split -l "$JOBS_CHUNK" "$WORK/nodes.txt" "$WORK/jobs/c."
  # An empty window leaves no chunk file, and the glob would stay literal.
  if [ -s "$WORK/nodes.txt" ]; then
    for c in "$WORK"/jobs/c.??; do echo "$c"; done \
      | xargs -P "$PAR" -I{} bash "$SELF" --gql jobs {} {}.out || die 3 "graphql jobs fetch failed"
    cat "$WORK"/jobs/c.??.out.ndjson | jq -s '.' > "$JOBS"
  else
    echo '[]' > "$JOBS"
  fi
  # A job cancelled while still queued reports started_at = created_at and a later
  # completed_at, i.e. fake runner time. Only a cancelled job can look like that, so
  # step counts (0 = never ran on a runner) and each job's own created_at come from one
  # REST jobs call per run holding one (GraphQL steps{} times out with 502 at any useful
  # batch size). A job found there is marked rest: true.
  jq -r '[.[] | select(.conclusion == "cancelled") | .run_id] | unique | .[]' "$JOBS" > "$WORK/cids.txt"
  if [ -s "$WORK/cids.txt" ]; then
    xargs -P "$PAR" -I{} bash "$SELF" --runjobs "$REPO" {} "$WORK/steps/r.{}" < "$WORK/cids.txt" || die 3 "run jobs fetch failed"
    cat "$WORK"/steps/r.*.ndjson | jq -s '.' > "$WORK/steps.json"
    jq --slurpfile st "$WORK/steps.json" '($st[0] | map({key: "\(.run_id)|\(.name)", value: .}) | from_entries) as $S
      | map(. as $j | $S["\(.run_id)|\(.name)"] as $x
          | if $x == null then $j
            else $j + {rest: true, created_at: ($x.created_at // $j.created_at)}
                 + (if $j.conclusion == "cancelled" then {ran: ($x.steps > 0)} else {} end) end)' "$JOBS" > "$WORK/jobs2.json" || die 3 "could not merge step counts"
    mv "$WORK/jobs2.json" "$JOBS" || die 3 "could not merge step counts"
  fi
  if [ -n "$KEEP" ]; then mkdir -p "$KEEP" && cp "$RUNS" "$KEEP/runs.json" && cp "$JOBS" "$KEEP/jobs.json"; fi
fi

jq -rn --slurpfile runs "$RUNS" --slurpfile jobs "$JOBS" \
  --argjson now "$NOW_EPOCH" --argjson start "$START_EPOCH" --argjson days "$DAYS" \
  --arg repo "$REPO" --argjson top "$TOP" --argjson hourly "$HOURLY" --argjson cap "$CAPCHECK" --arg wl "$WINDOW_LABEL" '
def t: fromdateiso8601;
def m1($s): ((($s * 10 / 60) + 0.5) | floor) as $x | "\($x / 10 | floor).\($x % 10)";
def pct($p): if length == 0 then null else sort | .[((($p * length) | ceil) - 1) | if . < 0 then 0 else . end] end;
def sec: if . == null then "-" else tostring end;
def esc: gsub("\\|"; "\\|");
def share($a; $b): if $b == 0 then "0.0%" else (($a * 1000 / $b + 0.5) | floor) as $x | "\($x / 10 | floor).\($x % 10)%" end;
# Largest number of sorted epoch times $a inside any rolling window of $w seconds (two pointers).
def maxwin($a; $w):
  reduce range(0; $a | length) as $i ({lo: 0, n: 0}; .lo = (.lo | until(. >= $i or $a[.] > $a[$i] - $w; . + 1)) | .n = ([.n, $i - .lo + 1] | max)) | .n;
# Per-hour counts of sorted epoch times: the busiest {h, n}.
def busiest: group_by(. / 3600 | floor) | map({h: (.[0] / 3600 | floor), n: length}) | max_by(.n) // {h: 0, n: 0};
# Longest run of equal non-null keys in an array.
def streak: reduce .[] as $k ({cur: 0, prev: null, best: 0};
    if $k == null then .cur = 0 | .prev = null
    else (if $k == .prev then .cur += 1 else .cur = 1 end) | .prev = $k | .best = ([.best, .cur] | max) end) | .best;
def gr($metric; $v; $line): "| \($metric) | \($v) | \($line) |";

($runs[0]) as $R
| ($R | INDEX(.id | tostring)) as $RI
| ($jobs[0] | map(
    . as $j | $RI[$j.run_id | tostring] as $r
    | ($j.started_at != null) as $hs
    # never ran: REST said 0 steps, or (no REST answer) started_at == created_at within 1 s
    | (($j.conclusion == "cancelled")
        and (if $j.ran != null then $j.ran == false
             else ($hs | not) or (((($j.started_at | t) - ($j.created_at | t)) | fabs) <= 1) end)) as $never
    # a skipped job carries its skip time as started_at, not a runner pick-up
    | ($hs and ($j.status == "completed" or $j.status == "in_progress") and ($never | not)
        and $j.conclusion != "skipped" and (($j.started_at | t) <= $now)) as $began
    | (if $began then ([(($j.completed_at // ($now | todate)) | t), $now] | min) else null end) as $e
    | . + {
        wf: $r.name, ev: $r.event, rconc: $r.conclusion, sha: $r.head_sha,
        never: $never, started: $began, e: $e,
        q: (if $began then (($j.started_at | t) - ($j.created_at | t)) else null end),
        r: (if $began and $j.completed_at != null then ([0, ($e - ($j.started_at | t))] | max) else null end),
        rs: (if $began then ([0, ($e - ($j.started_at | t))] | max) else 0 end)
      })) as $J

# ---- cancel cause per cancelled run (inferred, see header) ----
| ($R | group_by([.name, .head_branch, .event])
    | map(. as $g | $g[] | select(.conclusion == "cancelled") as $c
        | {id: $c.id, wf: $c.name, cause:
            (if ($g | any(.created_at > $c.created_at and (.created_at | t) <= (($c.updated_at | t) + 120))) then "superseded" else "no newer run (manual or other)" end)})
    | flatten) as $C
| ($J | group_by(.run_id) | map({key: (.[0].run_id | tostring), value: (map(.rs) | add)}) | from_entries) as $RS
| ($C | map(. + {rs: ($RS[.id | tostring] // 0)})) as $CR

# ---- generic job stats ----
| def stats: {
    jobs: length,
    ok: (map(select(.conclusion == "success")) | length),
    fail: (map(select(.conclusion == "failure")) | length),
    canc: (map(select(.conclusion == "cancelled")) | length),
    q: ([.[].q | numbers]), r: ([.[].r | numbers]),
    rs: (map(.rs) | add // 0),
    crs: (map(select(.rconc == "cancelled") | .rs) | add // 0)
  } | . + {other: (.jobs - .ok - .fail - .canc)};
  def row($k; $runs): stats as $s
    | "| \($k | esc) | \($runs) | \($s.jobs) | \($s.ok) | \($s.fail) | \($s.canc) | \($s.other) | \($s.q | pct(0.5) | sec) | \($s.q | pct(0.9) | sec) | \($s.r | pct(0.5) | sec) | \($s.r | pct(0.9) | sec) | \(m1($s.rs)) | \(m1($s.crs)) |";
  def hdr($k): "| \($k) | runs | jobs | ok | fail | cancelled | other | queue p50 s | queue p90 s | run p50 s | run p90 s | runner-min | runner-min in cancelled runs |",
               "|---|---|---|---|---|---|---|---|---|---|---|---|---|";
  def byrun(rk; jk): ($J | group_by(jk) | map({key: (.[0] | jk | tostring), value: .}) | from_entries) as $G
    | ($R | group_by(rk) | map({k: (.[0] | rk), n: length, jobs: ($G[.[0] | rk | tostring] // [])})) | sort_by(-(.jobs | map(.rs) | add // 0));

# ---- peak concurrency ----
($J | map(select(.started) | {s: (.started_at | t), e: .e} | select(.e > .s))) as $iv
| ([$iv[] | {t: .s, d: 1}, {t: .e, d: -1}] | sort_by([.t, .d]) | group_by(.t / 3600 | floor)) as $ev
| (if ($ev | length) == 0 then [] else
    ($ev[0][0].t / 3600 | floor) as $h0 | ($ev[-1][0].t / 3600 | floor) as $h1
    | ($ev | map({key: (.[0].t / 3600 | floor | tostring), value: .}) | from_entries) as $EH
    | reduce range($h0; $h1 + 1) as $h ({cur: 0, out: []};
        (.cur) as $carry
        | ($EH[$h | tostring] // []) as $he
        # jobs ending exactly on the hour boundary are not running in this hour
        | ($he | map(select(.t == $h * 3600 and .d == -1))) as $bend
        | ($carry - ($bend | length)) as $p0
        | (reduce ($he - $bend)[] as $e ({c: $p0, p: $p0}; .c += $e.d | .p = ([.p, .c] | max))) as $x
        | .cur = $x.c | .out += [{h: ($h * 3600 | todate), n: $x.p}])
    | .out end) as $PK
| ($PK | map(.n) | max // 0) as $peak

# ---- jobs per PR push ----
| ($J | map(select(.ev == "pull_request")) | group_by(.sha) | map({key: .[0].sha, value: length}) | from_entries) as $JS
| ($R | map(select(.event == "pull_request")) | group_by(.head_sha)
    | map({sha: .[0].head_sha, canc: (any(.[]; .conclusion == "cancelled")), jobs: ($JS[.[0].head_sha] // 0)})) as $PUSH
| ($PUSH | map(.jobs) | sort) as $PJ

# ---- queue backlog ----
| ($J | map(select(.status == "queued" or .status == "waiting" or .status == "pending" or .status == "requested"))) as $wait
| ($J | map(select(.never)) | length) as $preran
| ($J | map(select(.conclusion == "cancelled" and .rest != true)) | length) as $norest
| ($R | map(select(.status == "queued" or .status == "pending" or .status == "waiting")) | length) as $openruns

# ---- guardrail rates (plan section 1.3) ----
| ($R | map(.created_at | t) | sort) as $RT
| ($RT | busiest) as $RHM
| ($RT | group_by(. / 3600 | floor) | map({key: (.[0] / 3600 | floor | tostring), value: length}) | from_entries) as $RHC
| ([range(($start / 3600 | floor); ($now / 3600 | floor) + 1) | $RHC[tostring] // 0] | pct(0.9)) as $RHP90
| maxwin($RT; 86400) as $R24
| ($R | map(select(.conclusion == "cancelled") | .updated_at | t) | sort) as $CT
| maxwin($CT; 600) as $C10
| ($R | map(select((.run_attempt // 1) > 1) | (.run_started_at // .created_at) | t) | sort | busiest) as $RRH
| ($R | group_by([.head_branch, (.created_at | t / 86400 | floor)])
    | map({b: .[0].head_branch, d: (.[0].created_at | t / 86400 | floor | . * 86400 | todate | .[:10]), n: length})) as $BD
| ($BD | max_by(.n) // {b: "-", d: "-", n: 0}) as $BDM
| def flag($v; $line): if $v > $line then "OVER" else "OK" end;
  def hrat($x): if $x.n == 0 then "0" else "\($x.n) (\($x.h * 3600 | todate))" end;
  ([ "## Guardrail rates",
     "",
     "Alert lines are the plan section 1.3 guardrails. Reruns count only runs whose latest attempt is above 1 (earlier attempts are not visible).",
     "",
     "| metric | value | line | status |",
     "|---|---|---|---|",
     "\(gr("runs per hour, max"; hrat($RHM); 150)) \(flag($RHM.n; 150)) |",
     "\(gr("runs per hour, p90"; $RHP90 | sec; "-")) - |",
     "\(gr("runs per rolling 24 h, max"; $R24; 1500)) \(flag($R24; 1500)) |",
     "\(gr("cancels per rolling 10 min, max"; $C10; 30)) \(flag($C10; 30)) |",
     "\(gr("reruns per hour, max"; hrat($RRH); 10)) \(flag($RRH.n; 10)) |",
     "\(gr("runs per branch per day, max"; (if $BDM.n == 0 then "0" else "\($BDM.n) (\($BDM.b) \($BDM.d))" end); 6)) \(flag($BDM.n; 6)) |",
     "\(gr("branch-days over 6 runs"; ($BD | map(select(.n > 6)) | length); "-")) - |"
  ]) as $GR

# ---- cap check (plan section 1.2): per-minute running and queued against the 60-runner ceiling ----
| ((($now - $start) / 60) | floor) as $nm
| def mi($x): ((($x - $start) / 60) | ceil) | if . < 0 then 0 elif . > $nm then $nm else . end;
  def perminute($iv): (reduce $iv[] as $x ([range(0; $nm + 1) | 0]; mi($x.s) as $a | mi($x.e) as $b | if $a < $b then .[$a] += 1 | .[$b] -= 1 else . end))
    | . as $D | reduce range(0; $nm) as $i ({c: 0, a: []}; .c += $D[$i] | .a += [.c]) | .a;
  ($J | map(select(.started) | {s: (.started_at | t), e: .e} | select(.e > .s)) | perminute(.)) as $RUN
| ($J | map(select(.conclusion != "skipped")
      | if .never then (if .rest == true and .completed_at != null then {s: (.created_at | t), e: ([(.completed_at | t), $now] | min)} else empty end)
        elif .started and .rest == true then {s: (.created_at | t), e: (.started_at | t)}
        elif (.started | not) and .started_at == null and (.status | IN("queued", "waiting", "pending", "requested")) then {s: (.created_at | t), e: $now}
        else empty end
      | select(.e > .s)) | perminute(.)) as $QUE
| ($RUN | max // 0) as $maxrun
| ([range(0; $nm) | $RUN[.] + $QUE[.]] | max // 0) as $maxdem
| ([range(0; $nm) | if $QUE[.] > 0 and $RUN[.] <= 60 then "q" else null end] | streak) as $sq
| ([range(0; $nm) | if $QUE[.] > 0 and ($RUN[.] | IN(20, 40, 60)) then $RUN[.] else null end] | streak) as $sf
| (if $sf >= 10 and $maxrun <= 60 then ["FAIL", "running sat flat at the ceiling for \($sf) min with jobs queued"]
   elif $maxrun > 60 and $sq < 10 then ["PASS", "\($maxrun) jobs ran in one minute and no observed 10-minute stretch has jobs queued while running <= 60 (the queue is a lower bound, see the window note)"]
   elif $maxdem <= 60 then ["INCONCLUSIVE", "demand (running + queued) never exceeded 60 (max \($maxdem)); re-run after the next busy window, never create load"]
   elif $maxrun <= 60 then ["INCONCLUSIVE", "demand reached \($maxdem) but running was never flat at 20, 40 or 60 for 10 minutes while jobs queued"]
   else ["INCONCLUSIVE", "running reached \($maxrun) but jobs stayed queued for \($sq) min while running <= 60"] end) as $V
| ([ "# CI cap check - \($repo)",
     "",
     "Window: \($start | todate) .. \($now | todate) (\($wl)). Running = jobs that ran with started <= minute < completed. Queued = jobs with created <= minute < started, counted only for jobs whose own created_at came from REST (runs holding a cancelled job) and jobs still waiting at the window end: a lower bound.",
     "",
     "Verdict: \($V[0]) - \($V[1])",
     "",
     "| metric | value |",
     "|---|---|",
     "| minutes in window | \($nm) |",
     "| max running | \($maxrun) |",
     "| max demand (running + queued) | \($maxdem) |",
     "| minutes with running > 60 | \([range(0; $nm) | select($RUN[.] > 60)] | length) |",
     "| longest stretch queued while running <= 60 (min) | \($sq) |",
     "| longest stretch queued while running flat at 20, 40 or 60 (min) | \($sf) |",
     "",
     "## Per minute (minutes with a running or queued job)",
     "",
     "| minute (UTC) | running | queued |",
     "|---|---|---|",
     ([range(0; $nm) | select($RUN[.] > 0 or $QUE[.] > 0) | "| \($start + 60 * . | todate) | \($RUN[.]) | \($QUE[.]) |"][])
  ]) as $CAP

| if $cap == 1 then $CAP[] else (
  "# CI metrics baseline - \($repo)",
  "",
  "Window: \($start | todate) .. \($now | todate) (\($wl)). Source: GitHub API (runs list + check runs), read-only, latest attempt of each run.",
  "",
  "## Headline",
  "",
  "| metric | value |",
  "|---|---|",
  "| runs | \($R | length) |",
  "| jobs | \($J | length) |",
  "| cancelled runs | \($CR | length) |",
  "| runner-min total | \(m1($J | map(.rs) | add // 0)) |",
  "| runner-min in cancelled runs | \(m1($CR | map(.rs) | add // 0)) |",
  "| cancelled share of runner-min | \(share($CR | map(.rs) | add // 0; $J | map(.rs) | add // 0)) |",
  "| job queue wait p50 / p90 / max (s) | \($J | [.[].q | numbers] | "\(pct(0.5) | sec) / \(pct(0.9) | sec) / \(max // "-")") |",
  "| jobs cancelled before a runner took them | \($preran) |",
  "| cancelled jobs judged without a REST answer | \($norest) |",
  "| jobs still waiting for a runner at window end | \($wait | length) |",
  "| runs still queued or pending | \($openruns) |",
  "| peak concurrent in_progress jobs | \($peak) |",
  "| hours with peak >= 20 / >= 40 | \($PK | map(select(.n >= 20)) | length) / \($PK | map(select(.n >= 40)) | length) of \($PK | length) |",
  "",
  "## Per workflow",
  "",
  hdr("workflow"),
  (byrun(.name; .wf)[] | . as $g | ($g.jobs | row($g.k; $g.n))),
  "",
  "## Per trigger",
  "",
  hdr("trigger"),
  (byrun(.event; .ev)[] | . as $g | ($g.jobs | row($g.k; $g.n))),
  "",
  "## Per job name (top \($top) by runner-min)",
  "",
  hdr("job"),
  ($J | group_by(.name) | map({k: .[0].name, jobs: ., n: (map(.run_id) | unique | length)}) | sort_by(-(.jobs | map(.rs) | add // 0)) | .[:$top][] | . as $g | ($g.jobs | row($g.k; $g.n))),
  "",
  "## Cancelled runs by inferred cause",
  "",
  "| cause | runs | runner-min |",
  "|---|---|---|",
  (["superseded", "no newer run (manual or other)"][] as $c
    | "| \($c) | \($CR | map(select(.cause == $c)) | length) | \(m1($CR | map(select(.cause == $c) | .rs) | add // 0)) |"),
  "",
  "## Jobs per PR push",
  "",
  "| metric | value |",
  "|---|---|",
  "| pull_request pushes (distinct head sha) | \($PUSH | length) |",
  "| jobs per push mean | \(if ($PJ | length) == 0 then "-" else (($PJ | add) * 10 / ($PJ | length) + 0.5 | floor) as $x | "\($x / 10 | floor).\($x % 10)" end) |",
  "| jobs per push median | \($PJ | pct(0.5) | sec) |",
  "| jobs per push max | \($PJ | max // "-") |",
  "| pushes with a cancelled run | \($PUSH | map(select(.canc)) | length) |",
  "",
  "## Peak concurrent in_progress jobs per hour",
  "",
  "Reconstructed from job started_at / completed_at; a still-running job ends at the window end. Highest \(if $hourly == 1 then "all" else "10" end) hours:",
  "",
  "| hour (UTC) | peak in_progress |",
  "|---|---|",
  (($PK | if $hourly == 1 then . else sort_by(-.n) | .[:10] end)[] | "| \(.h) | \(.n) |"),
  "",
  $GR[]
) end
' > "$WORK/report.txt" || die 3 "analysis failed"
cat "$WORK/report.txt"
if [ "$CAPCHECK" -eq 1 ] && grep -q '^Verdict: FAIL' "$WORK/report.txt"; then exit 1; fi
exit 0
