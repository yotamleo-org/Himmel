#!/usr/bin/env bash
# scripts/ci/ledger-drift.sh — does scripts/ci/suite-durations.tsv still balance
# the shell-unit shards against what CI measured lately?
#
# Reads the per-suite seconds from the last <runs> green main ci.yml runs, packs
# those suites into <shards> bins with the committed ledger the way
# run-shell-tests.sh --shard does (longest ledger duration first, ties by path,
# each suite to the lightest bin, ties to the lowest index; a suite the ledger
# lacks costs the ledger's median; durations floored at 1s), then sums the
# MEASURED seconds per bin. Prints
#   slowest/floor   slowest bin over max(total/shards, longest single suite):
#                   the best any split could do
#   max/min         slowest bin over fastest bin
# and exits 1 when slowest/floor passes <threshold> (default 1.3).
#
# Usage: ledger-drift.sh [--logs <dir>] [--ledger <file>] [--shards <n>]
#                        [--threshold <x>] [--runs <k>]
#   --logs <dir>  read every <dir>/*.log (gh run view --log output) instead of
#                 fetching: the test's input. Without it the last <k> green
#                 main ci.yml runs are fetched with gh (GH_TOKEN, and -R from
#                 $GITHUB_REPOSITORY when set).
#   --shards <n>  default 8, the shard count of a main-branch run (ci.yml).
#   --runs <k>    default 3.
# Exit: 0 balanced, 1 drift, 2 no usable input or a usage error.
#
# Platform guard: bash + awk; Linux CI is the only caller.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
logs=""
ledger="$here/suite-durations.tsv"
shards=8
threshold=1.3
runs=3

usage() { echo "usage: ledger-drift.sh [--logs <dir>] [--ledger <file>] [--shards <n>] [--threshold <x>] [--runs <k>]" >&2; exit 2; }
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || usage
  case "$1" in
    --logs) logs="$2" ;;
    --ledger) ledger="$2" ;;
    --shards) shards="$2" ;;
    --threshold) threshold="$2" ;;
    --runs) runs="$2" ;;
    *) usage ;;
  esac
  shift 2
done
case "$shards" in ''|*[!0-9]*|0*) usage ;; esac
case "$runs" in ''|*[!0-9]*|0*) usage ;; esac
case "$threshold" in ''|*[!0-9.]*|.|*.*.*) usage ;; esac
[ -r "$ledger" ] || { echo "ledger-drift: ledger $ledger is not readable" >&2; exit 2; }

# shellcheck source=../lib/prim.sh
# shellcheck disable=SC1091
. "$here/../lib/prim.sh"
tmp=$(tmpdir) || exit 2
trap 'rm -rf "$tmp"' EXIT

if [ -z "$logs" ]; then
  logs="$tmp/logs"
  mkdir -p "$logs"
  repo_args=()
  [ -n "${GITHUB_REPOSITORY:-}" ] && repo_args=(-R "$GITHUB_REPOSITORY")
  ids=$(gh run list "${repo_args[@]}" --workflow ci.yml --branch main --status success \
    --limit "$runs" --json databaseId --jq '.[].databaseId') || { echo "ledger-drift: gh run list failed" >&2; exit 2; }
  for id in $ids; do
    gh run view "${repo_args[@]}" "$id" --log > "$logs/run-$id.log" || { echo "ledger-drift: gh run view $id failed" >&2; exit 2; }
  done
fi

# Per log, a suite's seconds (the last line wins, a rerun overwrites); across
# logs, the mean — what the ledger's own refresh does. Only the shell-unit-shard
# job's lines count: the same log carries other jobs' output.
LC_ALL=C awk -F'\t' -v shards="$shards" -v threshold="$threshold" -v ledger="$ledger" '
  BEGIN {
    while ((getline line < ledger) > 0) {
      if (line ~ /^[[:space:]]*#/) continue
      split(line, f, "\t")
      if (f[1] != "" && f[2] ~ /^[0-9]+$/) { cost[f[1]] = f[2] + 0; vals[++nv] = f[2] + 0 }
    }
    close(ledger)
    for (i = 2; i <= nv; i++) { v = vals[i]; j = i - 1; while (j >= 1 && vals[j] > v) { vals[j + 1] = vals[j]; j-- }; vals[j + 1] = v }
    med = (nv > 0) ? vals[int((nv + 1) / 2)] : 1
    if (med < 1) med = 1
  }
  FNR == 1 { nlogs++ }
  $1 ~ /^shell-unit-shard \(ubuntu-latest, / && match($0, /\[(PASS|FAIL)\] [^ ]+ \([0-9]+s\)/) {
    s = substr($0, RSTART, RLENGTH)
    sub(/^\[(PASS|FAIL)\] /, "", s)
    path = s; sub(/ \(.*$/, "", path)
    sec = s; sub(/^.* \(/, "", sec); sub(/s\)$/, "", sec)
    seen[FILENAME SUBSEP path] = sec + 0
    if (!(path in known)) { known[path] = 1; order[++m] = path }
    logsof[path] = 1
  }
  END {
    if (m == 0) { print "ledger-drift: no [PASS]/[FAIL] suite timings from shell-unit-shard in the logs" > "/dev/stderr"; exit 2 }
    for (k in seen) { split(k, p, SUBSEP); sum[p[2]] += seen[k]; cnt[p[2]]++ }
    # the pack: cost desc (zero-padded so a string sort orders it), path asc
    n = 0
    for (i = 1; i <= m; i++) {
      path = order[i]
      c = (path in cost) ? cost[path] : med
      if (c < 1) c = 1
      key[++n] = sprintf("%010d\t%s", 1000000000 - c, path)
    }
    # insertion sort: ~1000 rows, and no gawk-only asort
    for (i = 2; i <= n; i++) { v = key[i]; j = i - 1; while (j >= 1 && key[j] > v) { key[j + 1] = key[j]; j-- }; key[j + 1] = v }
    for (b = 0; b < shards; b++) { plan[b] = 0; real[b] = 0 }
    total = 0; longest = 0
    for (i = 1; i <= n; i++) {
      split(key[i], kf, "\t")
      path = kf[2]
      c = 1000000000 - (kf[1] + 0)
      best = 0
      for (b = 1; b < shards; b++) if (plan[b] < plan[best]) best = b
      plan[best] += c
      meas = sum[path] / cnt[path]
      real[best] += meas
      total += meas
      if (meas > longest) longest = meas
    }
    slowest = 0; fastest = real[0]
    for (b = 0; b < shards; b++) { if (real[b] > slowest) slowest = real[b]; if (real[b] < fastest) fastest = real[b] }
    floor = total / shards; if (longest > floor) floor = longest
    r_floor = (floor > 0) ? slowest / floor : 0
    r_minmax = (fastest > 0) ? slowest / fastest : 0
    printf "ledger-drift: logs=%d suites=%d shards=%d slowest=%.0fs fastest=%.0fs floor=%.0fs\n", nlogs, m, shards, slowest, fastest, floor
    printf "ledger-drift: slowest/floor=%.3f max/min=%.3f threshold=%s\n", r_floor, r_minmax, threshold
    if (r_floor > threshold + 0) { print "ledger-drift: DRIFT — refresh scripts/ci/suite-durations.tsv (REFRESH recipe in its header)"; exit 1 }
    print "ledger-drift: OK"
  }
' "$logs"/*.log
