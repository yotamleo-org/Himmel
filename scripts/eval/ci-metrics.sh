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
# Usage: ci-metrics.sh [--days N] [--repo OWNER/NAME] [--top N] [--hourly]
#                      [--keep DIR] [--cache DIR] [--data-dir DIR] [--now ISO8601]
#   --days N      window length in days, fractions allowed (default 7)
#   --top N       rows in the per-job-name table (default 30)
#   --hourly      print every hour of the peak table, not the top 10
#   --keep DIR    save the fetched runs.json + jobs.json there
#   --cache DIR   reuse/store each GraphQL chunk there, so a re-run never re-fetches
#                 (a cached chunk keeps the state it had when fetched)
#   --data-dir D  analyse a saved/recorded dataset instead of calling the API
#   --now ISO     fixed clock (tests); still-running jobs end at this instant
# Exit: 0 ok, 2 usage, 3 API/rate-limit problem.
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
# reads the step counts; a cancelled job with 0 steps never took a runner and gets
# no runner time, queue wait or concurrency interval. A run whose REST call fails
# is warned about and its cancelled jobs are counted as having run.
# The price of GraphQL: a job's created_at is not exposed, so queue wait is
# measured from the RUN's creation. That is exact for jobs with no `needs` and
# overstates a job gated behind others (its wait includes the upstream jobs'
# run time). Only the latest attempt of a re-run is visible.
# ponytail: queue wait of gated jobs includes upstream time, upgrade path =
# REST /runs/{id}/jobs?filter=all for a narrow window when exact job created_at matters.
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
PACE=1

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
# --runjobs <repo> <run id> <out>: REST jobs of one run, reduced to the step count of each cancelled job.
if [ "${1:-}" = "--runjobs" ]; then
  repo="$2"; rid="$3"; out="$4"
  if [ -n "${CI_METRICS_CACHE:-}" ] && [ -f "$CI_METRICS_CACHE/steps.$rid.ndjson" ]; then
    cp "$CI_METRICS_CACHE/steps.$rid.ndjson" "$out.ndjson"; exit 0
  fi
  for _try in 1 2 3; do
    if gh api "repos/$repo/actions/runs/$rid/jobs?per_page=100" 2> "$out.err" > "$out.raw" \
      && jq -c --argjson r "$rid" '.jobs[] | select(.conclusion == "cancelled") | {run_id: $r, name, steps: (.steps | length)}' "$out.raw" > "$out.tmp"; then
      mv "$out.tmp" "$out.ndjson"
      if [ -n "${CI_METRICS_CACHE:-}" ]; then cp "$out.ndjson" "$CI_METRICS_CACHE/steps.$rid.ndjson"; fi
      sleep "$PACE"; exit 0
    fi
    if grep -qiE 'rate limit|HTTP 403|HTTP 429' "$out.err" "$out.raw" 2>/dev/null; then sleep 60; else sleep 10; fi
  done
  # One run that will not answer must not sink the dataset: its cancelled jobs keep ran=true.
  echo "ci-metrics: WARN run jobs fetch failed for run $rid ($(head -c 100 "$out.err")); its cancelled jobs count as ran" >&2
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


DAYS=7; REPO="yotamleo/Himmel"; TOP=30; HOURLY=0; KEEP=""; DATA=""; NOW=""; CACHE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --days) [ $# -ge 2 ] || die 2 "--days needs a value"; DAYS="$2"; shift 2;;
    --repo) [ $# -ge 2 ] || die 2 "--repo needs a value"; REPO="$2"; shift 2;;
    --top) [ $# -ge 2 ] || die 2 "--top needs a value"; TOP="$2"; shift 2;;
    --keep) [ $# -ge 2 ] || die 2 "--keep needs a value"; KEEP="$2"; shift 2;;
    --cache) [ $# -ge 2 ] || die 2 "--cache needs a value"; CACHE="$2"; shift 2;;
    --data-dir) [ $# -ge 2 ] || die 2 "--data-dir needs a value"; DATA="$2"; shift 2;;
    --now) [ $# -ge 2 ] || die 2 "--now needs a value"; NOW="$2"; shift 2;;
    --hourly) HOURLY=1; shift;;
    -h|--help) sed -n '2,/^set -u/p' "$SELF" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0;;
    *) die 2 "unknown argument: $1";;
  esac
done
case "$DAYS" in ''|*[!0-9.]*|.|*.*.*) die 2 "--days must be a positive number, got '$DAYS'";; esac
awk -v d="$DAYS" 'BEGIN { exit !(d + 0 > 0) }' || die 2 "--days must be positive"
case "$TOP" in ''|*[!0-9]*) die 2 "--top must be an integer";; esac
command -v jq >/dev/null 2>&1 || die 3 "jq is required"

if [ -n "$NOW" ]; then
  NOW_EPOCH=$(jq -rn --arg n "$NOW" '$n|fromdateiso8601') || die 2 "--now must be ISO 8601 (YYYY-MM-DDTHH:MM:SSZ)"
else
  NOW_EPOCH=$(date -u +%s)
fi
START_EPOCH=$(awk -v n="$NOW_EPOCH" -v d="$DAYS" 'BEGIN { printf "%d", n - d * 86400 }')

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
  for c in "$WORK"/jobs/c.??; do echo "$c"; done \
    | xargs -P "$PAR" -I{} bash "$SELF" --gql jobs {} {}.out || die 3 "graphql jobs fetch failed"
  cat "$WORK"/jobs/c.??.out.ndjson | jq -s '.' > "$JOBS"
  # A job cancelled while still queued reports started_at = created_at and a later
  # completed_at, i.e. fake runner time. Only a cancelled job can look like that, so
  # step counts (0 = never ran on a runner) come from one REST jobs call per run holding
  # one (GraphQL steps{} times out with 502 at any useful batch size).
  jq -r '[.[] | select(.conclusion == "cancelled") | .run_id] | unique | .[]' "$JOBS" > "$WORK/cids.txt"
  if [ -s "$WORK/cids.txt" ]; then
    xargs -P "$PAR" -I{} bash "$SELF" --runjobs "$REPO" {} "$WORK/steps/r.{}" < "$WORK/cids.txt" || die 3 "run jobs fetch failed"
    cat "$WORK"/steps/r.*.ndjson | jq -s '.' > "$WORK/steps.json"
    jq --slurpfile st "$WORK/steps.json" '($st[0] | map({key: "\(.run_id)|\(.name)", value: .steps}) | from_entries) as $S
      | map(. + {ran: (if .conclusion == "cancelled" and (($S["\(.run_id)|\(.name)"]) // 1) == 0 then false else true end)})' "$JOBS" > "$WORK/jobs2.json" || die 3 "could not merge step counts"
    mv "$WORK/jobs2.json" "$JOBS" || die 3 "could not merge step counts"
  fi
  if [ -n "$KEEP" ]; then mkdir -p "$KEEP" && cp "$RUNS" "$KEEP/runs.json" && cp "$JOBS" "$KEEP/jobs.json"; fi
fi

jq -rn --slurpfile runs "$RUNS" --slurpfile jobs "$JOBS" \
  --argjson now "$NOW_EPOCH" --argjson start "$START_EPOCH" --argjson days "$DAYS" \
  --arg repo "$REPO" --argjson top "$TOP" --argjson hourly "$HOURLY" '
def t: fromdateiso8601;
def m1($s): ((($s * 10 / 60) + 0.5) | floor) as $x | "\($x / 10 | floor).\($x % 10)";
def pct($p): if length == 0 then null else sort | .[((($p * length) | ceil) - 1) | if . < 0 then 0 else . end] end;
def sec: if . == null then "-" else tostring end;
def esc: gsub("\\|"; "\\|");
def share($a; $b): if $b == 0 then "0.0%" else (($a * 1000 / $b + 0.5) | floor) as $x | "\($x / 10 | floor).\($x % 10)%" end;

($runs[0]) as $R
| ($R | INDEX(.id | tostring)) as $RI
| ($jobs[0] | map(
    . as $j | $RI[$j.run_id | tostring] as $r
    | (($j.status == "completed" or $j.status == "in_progress") and ($j.ran != false)) as $began
    | . + {
        wf: $r.name, ev: $r.event, rconc: $r.conclusion, sha: $r.head_sha,
        started: ($began and $j.started_at != null),
        q: (if $began and $j.started_at != null then (($j.started_at | t) - ($j.created_at | t)) else null end),
        r: (if $began and $j.started_at != null and $j.completed_at != null then ([0, (($j.completed_at | t) - ($j.started_at | t))] | max) else null end),
        rs: (if $began and $j.started_at != null then ([0, ((($j.completed_at // ($now | todate)) | t) - ($j.started_at | t))] | max) else 0 end)
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
($J | map(select(.started) | {s: (.started_at | t), e: ((.completed_at // ($now | todate)) | t)} | select(.e > .s))) as $iv
| ([$iv[] | {t: .s, d: 1}, {t: .e, d: -1}] | sort_by([.t, .d]) | group_by(.t / 3600 | floor)) as $ev
| (if ($ev | length) == 0 then [] else
    ($ev[0][0].t / 3600 | floor) as $h0 | ($ev[-1][0].t / 3600 | floor) as $h1
    | ($ev | map({key: (.[0].t / 3600 | floor | tostring), value: .}) | from_entries) as $EH
    | reduce range($h0; $h1 + 1) as $h ({cur: 0, out: []};
        (.cur) as $carry
        | (reduce ($EH[$h | tostring] // [])[] as $e ({c: $carry, p: $carry}; .c += $e.d | .p = ([.p, .c] | max))) as $x
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
| ($J | map(select(.ran == false)) | length) as $preran
| ($R | map(select(.status == "queued" or .status == "pending" or .status == "waiting")) | length) as $openruns

| "# CI metrics baseline - \($repo)",
  "",
  "Window: \($start | todate) .. \($now | todate) (\($days) days). Source: GitHub API (runs list + check runs), read-only, latest attempt of each run.",
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
  (($PK | if $hourly == 1 then . else sort_by(-.n) | .[:10] end)[] | "| \(.h) | \(.n) |")
' || die 3 "analysis failed"
