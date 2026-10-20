#!/usr/bin/env bash
# scripts/handover/console-kit/ci-guardrail.sh
#
# CI guardrail monitor for the console tick: are the fleet's GitHub Actions
# runs starting to look abusive (plan section 1.3, operator decision 80)?
#   ciguard=ok | ciguard=OVER:<metric>[,<metric>...] | ciguard=unknown
#   ALERT <metric>=<value>><line> (<where>)      one per NEW crossing, after the first line
# Metrics and lines: runs-h 150, runs-day 1500, cancels-10m 30, reruns-h 10 (read from
# scripts/eval/ci-metrics.sh, which owns those four lines), branch-day 10 (counted here).
# An ALERT prints once per crossing; the metric re-arms on the first read at or below its
# line. unknown (no runs file, budget too low, a fetch failure, an unparseable report)
# neither raises nor clears anything and exits 0, so a tick is never blocked by it.
#
# Usage: ci-guardrail.sh [--runs FILE] [--now ISO8601] [--state-dir DIR]
#   --runs FILE      read a runs.json (the ci-metrics.sh shape) instead of fetching; replays
#   --now ISO        fixed clock (tests, replays); default the current time
#   --state-dir DIR  alerted set + runs cache (default $TICK_STATE_DIR, else ~/.himmel/state)
# Env: CIGUARD_METRICS (ci-metrics.sh), CIGUARD_BUDGET (api-budget.sh), CIGUARD_REPO (owner/repo),
#   CIGUARD_MIN_REMAINING (REST calls that must be left before a fetch, default 1500),
#   CIGUARD_TTL_MIN (minutes a fetched runs list is reused, default 10),
#   CIGUARD_SLICE_TIMEOUT (seconds per 6 h slice read, default 25).
#
# The fetch reads the last 24 h as four 6 h slices through `ci-metrics.sh --slice`, after
# api-budget.sh says the shared REST bucket can afford it. ci-metrics.sh then reports the
# guardrail table twice from that one list: over the last 2 h (runs/h, cancels, reruns)
# and over 24 h (runs/day).
# ponytail: runs/h and reruns/h are ci-metrics.sh clock-hour buckets, so a burst alerts when
# its hour completes (up to an hour late) and a crossing stays OVER while it is inside the
# 2 h window; upgrade path = a rolling-hour rate in ci-metrics.sh.
# ponytail: branch-day is CI-workflow runs on a non-main branch in the trailing 24 h; the
# line is 10 because the real 10-15 day peaks at 9 (a line of 6 fires on a quiet day).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${REPO:-$(cd "$HERE/../../.." && pwd)}"
METRICS="${CIGUARD_METRICS:-$ROOT/scripts/eval/ci-metrics.sh}"
BUDGET="${CIGUARD_BUDGET:-$ROOT/scripts/ci/api-budget.sh}"
BRANCH_LINE=10
MIN_REMAINING="${CIGUARD_MIN_REMAINING:-1500}"
TTL_MIN="${CIGUARD_TTL_MIN:-10}"
SLICE_TIMEOUT="${CIGUARD_SLICE_TIMEOUT:-25}"
case "$MIN_REMAINING" in ''|*[!0-9]*) MIN_REMAINING=1500 ;; esac
case "$TTL_MIN" in ''|*[!0-9]*) TTL_MIN=10 ;; esac
case "$SLICE_TIMEOUT" in ''|*[!0-9]*) SLICE_TIMEOUT=25 ;; esac

RUNS="" ; NOW_ISO="" ; STATE_DIR="${TICK_STATE_DIR:-$HOME/.himmel/state}"
while [ $# -gt 0 ]; do
  case "$1" in
    --runs) [ $# -ge 2 ] || { echo "ci-guardrail: --runs needs a value" >&2; exit 2; }; RUNS="$2"; shift 2 ;;
    --now) [ $# -ge 2 ] || { echo "ci-guardrail: --now needs a value" >&2; exit 2; }; NOW_ISO="$2"; shift 2 ;;
    --state-dir) [ $# -ge 2 ] || { echo "ci-guardrail: --state-dir needs a value" >&2; exit 2; }; STATE_DIR="$2"; shift 2 ;;
    *) echo "usage: ci-guardrail.sh [--runs FILE] [--now ISO8601] [--state-dir DIR]" >&2; exit 2 ;;
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
mkdir -p "$STATE_DIR" 2>/dev/null || true  # swallow-ok: an unwritable state dir only costs the once-per-crossing memory

# fetch_runs <out>: the last 24 h of runs as a ci-metrics.sh runs.json, or non-zero.
fetch_runs() {
  local out="$1" remaining slug url i a b
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
         | map({id, name, event, status, conclusion, created_at, run_started_at, updated_at, head_sha, head_branch, run_attempt})
         | sort_by(.created_at)' "$WORK"/slices/slice.*.json > "$out" 2>/dev/null
}

if [ -z "$RUNS" ]; then
  cache="$STATE_DIR/tick-ciguard-runs.json"
  if [ -s "$cache" ] && [ -n "$(find "$cache" -mmin "-$TTL_MIN" 2>/dev/null)" ]; then  # swallow-ok: a failed find reads as a stale cache and refetches
    RUNS="$cache"
  else
    fetch_runs "$WORK/runs.json" && [ -s "$WORK/runs.json" ] || unknown
    cp "$WORK/runs.json" "$cache" 2>/dev/null || true
    RUNS="$WORK/runs.json"
  fi
fi
[ -f "$RUNS" ] || unknown
jq -e 'type == "array"' "$RUNS" >/dev/null 2>&1 || unknown

# ci-metrics.sh wants a jobs file next to the runs; the guardrail table never reads it.
mkdir -p "$WORK/data"
cp "$RUNS" "$WORK/data/runs.json"
echo '[]' > "$WORK/data/jobs.json"
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
add_row() { # <metric> <report> <label>
  local r
  r="$(row "$2" "$3")"
  [ -n "$r" ] || unknown
  # a row that parses but is not "<count> <where> OK|OVER <line>" must not read as below the line
  printf '%s\n' "$r" | awk -F'\t' '$1 ~ /^[0-9]+$/ && ($3 == "OK" || $3 == "OVER") && $4 ~ /^[0-9]+$/ { ok = 1 } END { exit !ok }' || unknown
  rows="$rows$1"$'\t'"$r"$'\n'
}
add_row runs-h "$report2" "runs per hour, max"
add_row runs-day "$report24" "runs per rolling 24 h, max"
add_row cancels-10m "$report2" "cancels per rolling 10 min, max"
add_row reruns-h "$report2" "reruns per hour, max"

b="$(jq -r --argjson now "$NOW" '
      map(select(.name == "CI" and .head_branch != "main" and (.created_at | fromdateiso8601) > $now - 86400 and (.created_at | fromdateiso8601) <= $now))
      | group_by(.head_branch) | map({b: .[0].head_branch, n: length}) | max_by(.n) // {b: "-", n: 0}
      | "\(.n)\t\(.b)"' "$RUNS" 2>/dev/null)" || unknown
bn="${b%%$'\t'*}"; bb="${b#*$'\t'}"
case "$bn" in ''|*[!0-9]*) unknown ;; esac
bstatus=OK; [ "$bn" -le "$BRANCH_LINE" ] || bstatus=OVER
rows="${rows}branch-day"$'\t'"$bn"$'\t'"$bb"$'\t'"$bstatus"$'\t'"$BRANCH_LINE"$'\n'

state="$STATE_DIR/tick-ciguard-state"
alerted="$(cat "$state" 2>/dev/null)" || alerted=""  # swallow-ok: no state file means nothing has alerted yet
over="" ; alerts="" ; keep=""
while IFS=$'\t' read -r metric count where status line; do
  [ -n "$metric" ] || continue
  # a tab is IFS whitespace, so an empty "where" is carried as "-"
  [ "$where" != - ] || where=""
  if [ "$status" = OVER ]; then
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
exit 0
