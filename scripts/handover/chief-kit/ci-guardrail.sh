#!/usr/bin/env bash
# scripts/handover/chief-kit/ci-guardrail.sh
#
# CI guardrail monitor for the chief tick: is the fleet at a real GitHub Actions limit
# (operator decision 850: 500 concurrent jobs is the only limit; plan section 1.3, decision 80)?
#   ciguard=ok | ciguard=OVER:<metric>[,<metric>...] | ciguard=unknown
#   ALERT <metric>=<value>><line> (<where>)      one per NEW crossing, after the first line
#   INFO <metric>=<value> (<where>)              one per information row, after the ALERT lines
# Only two metrics can read OVER, both read from scripts/eval/ci-metrics.sh: concurrent-jobs
# (running + queued jobs now, line 500) and gh-refusal (a run that ended startup_failure in
# the last 2 h, line 0). The old run-count rows (runs-h 150, runs-day 1500, cancels-10m 30,
# reruns-h 10, branch-day 10) are our own reference points, not a GitHub limit: they print as
# INFO and never read OVER, never print an ALERT, never hold a dispatch or a rerun.
# An ALERT prints once per crossing; the metric re-arms on the first read at or below its
# line. unknown (no runs file, budget too low, a fetch failure, an unparseable report)
# neither raises nor clears anything and exits 0, so a tick is never blocked by it.
#
# Usage: ci-guardrail.sh [--runs FILE] [--jobs FILE] [--now ISO8601] [--state-dir DIR]
#   --runs FILE      read a runs.json (the ci-metrics.sh shape) instead of fetching; replays
#                    (a replay keeps its state in a throwaway dir unless --state-dir is given)
#   --jobs FILE      the jobs.json for that replay (default an empty list: no concurrency seen)
#   --now ISO        fixed clock (tests, replays); default the current time
#   --state-dir DIR  alerted set + runs cache (default $TICK_STATE_DIR, else ~/.himmel/state)
# Env: CIGUARD_METRICS (ci-metrics.sh), CIGUARD_BUDGET (api-budget.sh), CIGUARD_REPO (owner/repo),
#   CIGUARD_MIN_REMAINING (REST calls that must be left before a fetch, default 1500),
#   CIGUARD_TTL_MIN (minutes a fetched runs list is reused, default 10),
#   CIGUARD_SLICE_TIMEOUT (seconds per 6 h slice read, default 25).
#
# The fetch reads the last 24 h as four 6 h slices through `ci-metrics.sh --slice`, after
# api-budget.sh says the shared REST bucket can afford it, then the jobs of the runs still
# open (queued, waiting or in progress) through `ci-metrics.sh --gql jobs`: one call per 100
# open runs. ci-metrics.sh then reports the guardrail table twice from that one list: over
# the last 2 h (concurrent jobs, refusals, runs/h, cancels, reruns) and over 24 h (runs/day).
# concurrent-jobs counts the jobs of the runs open now plus any queued job the report can see,
# so it is a lower bound of the real demand: a completed run's jobs are not fetched.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${REPO:-$(cd "$HERE/../../.." && pwd)}"
METRICS="${CIGUARD_METRICS:-$ROOT/scripts/eval/ci-metrics.sh}"
BUDGET="${CIGUARD_BUDGET:-$ROOT/scripts/ci/api-budget.sh}"
BRANCH_REF=10
MIN_REMAINING="${CIGUARD_MIN_REMAINING:-1500}"
TTL_MIN="${CIGUARD_TTL_MIN:-10}"
SLICE_TIMEOUT="${CIGUARD_SLICE_TIMEOUT:-25}"
case "$MIN_REMAINING" in ''|*[!0-9]*) MIN_REMAINING=1500 ;; esac
case "$TTL_MIN" in ''|*[!0-9]*) TTL_MIN=10 ;; esac
case "$SLICE_TIMEOUT" in ''|*[!0-9]*) SLICE_TIMEOUT=25 ;; esac

RUNS="" ; JOBS="" ; NOW_ISO="" ; STATE_DIR="${TICK_STATE_DIR:-$HOME/.himmel/state}" ; STATE_GIVEN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --runs) [ $# -ge 2 ] || { echo "ci-guardrail: --runs needs a value" >&2; exit 2; }; RUNS="$2"; shift 2 ;;
    --jobs) [ $# -ge 2 ] || { echo "ci-guardrail: --jobs needs a value" >&2; exit 2; }; JOBS="$2"; shift 2 ;;
    --now) [ $# -ge 2 ] || { echo "ci-guardrail: --now needs a value" >&2; exit 2; }; NOW_ISO="$2"; shift 2 ;;
    --state-dir) [ $# -ge 2 ] || { echo "ci-guardrail: --state-dir needs a value" >&2; exit 2; }; STATE_DIR="$2"; STATE_GIVEN=1; shift 2 ;;
    *) echo "usage: ci-guardrail.sh [--runs FILE] [--jobs FILE] [--now ISO8601] [--state-dir DIR]" >&2; exit 2 ;;
  esac
done

unknown() { echo "ciguard=unknown"; exit 0; }
command -v jq >/dev/null 2>&1 || unknown
[ -f "$METRICS" ] || unknown

if [ -n "$NOW_ISO" ]; then
  NOW="$(jq -rn --arg n "$NOW_ISO" '$n | fromdateiso8601' 2>/dev/null)" || unknown  # swallow-ok: a bad --now reads unknown on this line
else
  NOW="$(date -u +%s)"
fi
case "$NOW" in ''|*[!0-9]*) unknown ;; esac
NOW_ISO="$(jq -rn --argjson n "$NOW" '$n | todate')"

# shellcheck source=../../lib/prim.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/prim.sh" || unknown
# shellcheck source=../../lib/git-clean.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/git-clean.sh" || unknown
# shellcheck source=../../lib/timeout-bin.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/timeout-bin.sh" 2>/dev/null  # swallow-ok: no timeout binary leaves _TIMEOUT_BIN empty, the slice read then runs unbounded

WORK="$(tmpdir)" || unknown
trap 'rm -rf "$WORK"' EXIT
# a replay without its own --state-dir must not read or move the live alerted set
[ -z "$RUNS" ] || [ "$STATE_GIVEN" = 1 ] || STATE_DIR="$WORK/state"
mkdir -p "$STATE_DIR" 2>/dev/null || true  # swallow-ok: an unwritable state dir only costs the once-per-crossing memory

# fetch_runs <out> <jobs-out>: the last 24 h of runs as a ci-metrics.sh runs.json, and the jobs of
# the runs still open as a jobs.json, or non-zero.
fetch_runs() {
  local out="$1" jobs_out="$2" remaining slug url i a b c
  remaining="$(bash "$BUDGET" 2>/dev/null | sed -n 's#^gh-api: remaining=\([0-9][0-9]*\)/.*#\1#p')"  # swallow-ok: no parsable remaining count returns 1 on the next line
  case "$remaining" in ''|*[!0-9]*) return 1 ;; esac
  [ "$remaining" -ge "$MIN_REMAINING" ] || return 1
  slug="${CIGUARD_REPO:-}"
  if [ -z "$slug" ]; then
    url="$(git_clean -C "$ROOT" remote get-url origin 2>/dev/null)" || return 1  # swallow-ok: a failed lookup returns 1, the read is unknown
    slug="$(printf '%s' "$url" | sed -E 's#^.*[:/]([^/:]+/[^/]+)$#\1#; s#\.git$##')"
  fi
  [ -n "$slug" ] || return 1
  mkdir -p "$WORK/slices"
  for i in 1 2 3 4; do
    a="$(jq -rn --argjson n "$NOW" --argjson i "$i" '$n - 86400 + ($i - 1) * 21600 | todate')"
    b="$(jq -rn --argjson n "$NOW" --argjson i "$i" '$n - 86400 + $i * 21600 | todate')"
    ${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" -k 2 "$SLICE_TIMEOUT"} bash "$METRICS" --slice "$slug" "$WORK/slices" "$i" "$a" "$b" >/dev/null 2>&1 || return 1
  done
  jq -s 'add | unique_by(.id)
         | map({id, node_id, name, event, status, conclusion, created_at, run_started_at, updated_at, head_sha, head_branch, run_attempt})
         | sort_by(.created_at)' "$WORK"/slices/slice.*.json > "$out" 2>/dev/null || return 1
  # the jobs of the runs still open: the running + queued side of the concurrent-jobs line
  mkdir -p "$WORK/jobs"
  jq -r '.[] | select(.status != "completed") | .node_id // empty' "$out" > "$WORK/jobs/open.txt" 2>/dev/null || return 1
  if [ -s "$WORK/jobs/open.txt" ]; then
    split -l 100 "$WORK/jobs/open.txt" "$WORK/jobs/c." || return 1
    for c in "$WORK"/jobs/c.??; do
      ${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" -k 2 "$SLICE_TIMEOUT"} bash "$METRICS" --gql jobs "$c" "$c.out" >/dev/null 2>&1 || return 1
    done
    cat "$WORK"/jobs/c.??.out.ndjson | jq -s '.' > "$jobs_out" 2>/dev/null || return 1
  else
    echo '[]' > "$jobs_out"
  fi
}

if [ -z "$RUNS" ]; then
  cache="$STATE_DIR/tick-ciguard-runs.json"
  jcache="$STATE_DIR/tick-ciguard-jobs.json"
  if [ -s "$cache" ] && [ -s "$jcache" ] && [ -n "$(find "$cache" -mmin "-$TTL_MIN" 2>/dev/null)" ]; then  # swallow-ok: a failed find reads as a stale cache and refetches
    RUNS="$cache"; JOBS="$jcache"
  else
    fetch_runs "$WORK/runs.json" "$WORK/jobs.json" && [ -s "$WORK/runs.json" ] && [ -s "$WORK/jobs.json" ] || unknown
    cp "$WORK/runs.json" "$cache" 2>/dev/null || true
    cp "$WORK/jobs.json" "$jcache" 2>/dev/null || true
    RUNS="$WORK/runs.json"; JOBS="$WORK/jobs.json"
  fi
fi
[ -f "$RUNS" ] || unknown
jq -e 'type == "array"' "$RUNS" >/dev/null 2>&1 || unknown
if [ -n "$JOBS" ]; then
  [ -f "$JOBS" ] || unknown
  jq -e 'type == "array"' "$JOBS" >/dev/null 2>&1 || unknown
fi

# ci-metrics.sh wants a jobs file next to the runs: the concurrent-jobs row reads it.
mkdir -p "$WORK/data"
cp "$RUNS" "$WORK/data/runs.json"
if [ -n "$JOBS" ]; then cp "$JOBS" "$WORK/data/jobs.json"; else echo '[]' > "$WORK/data/jobs.json"; fi
report2="$(bash "$METRICS" --data-dir "$WORK/data" --now "$NOW_ISO" --hours 2 2>/dev/null)" || unknown  # swallow-ok: a failed report reads unknown
report24="$(bash "$METRICS" --data-dir "$WORK/data" --now "$NOW_ISO" --hours 24 2>/dev/null)" || unknown  # swallow-ok: a failed report reads unknown

# row <report> <label>: "<count>\t<where>\t<status>\t<line>" from the guardrail table.
row() {
  printf '%s\n' "$1" | awk -F'|' -v l="$2" '
    { k = $2; gsub(/^ +| +$/, "", k) }
    k == l {
      v = $3; gsub(/^ +| +$/, "", v)
      split(v, p, " "); c = p[1]; w = substr(v, length(c) + 2); gsub(/^\(|\)$/, "", w); if (w == "") w = "-"
      ln = $4; gsub(/ /, "", ln); st = $5; gsub(/ /, "", st)
      printf "%s\t%s\t%s\t%s\n", c, w, st, ln; exit
    }'
}

rows=""
add_row() { # <metric> <report> <label> <gate|info>
  local r
  r="$(row "$2" "$3")"
  [ -n "$r" ] || unknown
  if [ "$4" = gate ]; then
    # a row that parses but is not "<count> <where> OK|OVER <line>" must not read as below the line
    printf '%s\n' "$r" | awk -F'\t' '$1 ~ /^[0-9]+$/ && ($3 == "OK" || $3 == "OVER") && $4 ~ /^[0-9]+$/ { ok = 1 } END { exit !ok }' || unknown
  else
    # an information row is never OVER, whatever the report says: only its count must parse
    printf '%s\n' "$r" | awk -F'\t' '$1 ~ /^[0-9]+$/ { ok = 1 } END { exit !ok }' || unknown
    r="$(printf '%s\n' "$r" | awk -F'\t' 'BEGIN { OFS = "\t" } { $3 = "info"; print }')"
  fi
  rows="$rows$1"$'\t'"$r"$'\n'
}
# decision 850: the two rows that can read OVER
add_row concurrent-jobs "$report2" "concurrent jobs, now (running + queued)" gate
add_row gh-refusal "$report2" "GitHub refusals (startup_failure runs)" gate
# our own old run-count reference points: information only
add_row runs-h "$report2" "runs per hour, max" info
add_row runs-day "$report24" "runs per rolling 24 h, max" info
add_row cancels-10m "$report2" "cancels per rolling 10 min, max" info
add_row reruns-h "$report2" "reruns per hour, max" info

b="$(jq -r --argjson now "$NOW" '
      map(select(.name == "CI" and .head_branch != "main" and (.created_at | fromdateiso8601) > $now - 86400 and (.created_at | fromdateiso8601) <= $now))
      | group_by(.head_branch) | map({b: .[0].head_branch, n: length}) | max_by(.n) // {b: "-", n: 0}
      | "\(.n)\t\(.b)"' "$RUNS" 2>/dev/null)" || unknown
bn="${b%%$'\t'*}"; bb="${b#*$'\t'}"
case "$bn" in ''|*[!0-9]*) unknown ;; esac
rows="${rows}branch-day"$'\t'"$bn"$'\t'"$bb"$'\t'"info"$'\t'"$BRANCH_REF"$'\n'

state="$STATE_DIR/tick-ciguard-state"
alerted="$(cat "$state" 2>/dev/null)" || alerted=""  # swallow-ok: no state file means nothing has alerted yet
over="" ; alerts="" ; keep="" ; infos=""
while IFS=$'\t' read -r metric count where status line; do
  [ -n "$metric" ] || continue
  # a tab is IFS whitespace, so an empty "where" is carried as "-"
  [ "$where" != - ] || where=""
  if [ "$status" = info ]; then
    infos="$infos""INFO $metric=$count${where:+ ($where)}"$'\n'
  elif [ "$status" = OVER ]; then
    over="${over:+$over,}$metric"
    keep="$keep$metric"$'\n'
    case $'\n'"$alerted"$'\n' in
      *$'\n'"$metric"$'\n'*) ;;
      *) alerts="$alerts""ALERT $metric=$count>$line${where:+ ($where)}"$'\n' ;;
    esac
  fi
done <<< "$rows"
printf '%s' "$keep" > "$state" 2>/dev/null || true

if [ -n "$over" ]; then echo "ciguard=OVER:$over"; else echo "ciguard=ok"; fi
printf '%s' "$alerts"
printf '%s' "$infos"
exit 0
