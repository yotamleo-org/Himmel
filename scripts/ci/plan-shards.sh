#!/usr/bin/env bash
# scripts/ci/plan-shards.sh — how many shell-unit shards, out of at most <n>,
# the current selection needs, and which of them have a suite to run. Prints
# GITHUB_OUTPUT lines:
#   shards=[1,3]          JSON list for the shard job's matrix
#   absent_shards=2 4     the others, for shard-manifest-verify.sh --absent-ok
#   shard_total=4         the N every shard runs as --shard <k>/N
#
# Usage: plan-shards.sh <n> [<scan root>] [-- <runner args>]   (root defaults .)
#
# Sizing: one run-shell-tests.sh --list (the runner args pass through, e.g.
# --impacted <range>) gives the selected suites; the duration ledger the
# runner bin-packs with gives their cost. The same LPT pack is simulated for
# every N in 1..n and the smallest N whose longest shard fits in
# max(TARGET_S, longest shard at n) wins: a small selection takes few runners,
# a large one keeps all n. LPT places the first N suites in N distinct shards,
# so every one of the N shards has work.
#
# FAIL-CLOSED: a --list that fails or lacks its summary footer, or a ledger
# with no valid duration to size a non-empty selection by, falls back to
# N = n and one shard-has-work.sh probe per shard, run in parallel, each asked
# under the same runner args as the --list that failed. A probe
# that fails, prints nothing or prints anything but `has_work=false` leaves
# the shard in the list. A shard wrongly left out is still caught downstream:
# the aggregator's manifest accounting demands every selected suite ran once.
#
# Platform guard: bash 3.2+; Linux CI is the only caller.
set -uo pipefail

# The lint and leak-classes jobs take ~11-12 min on a PR, so a shard finishing
# inside 10 min does not lengthen the run.
TARGET_S=600

n="${1:-}"
case "$n" in ''|*[!0-9]*|0*) echo "usage: plan-shards.sh <n> [<root>] [-- <runner args>] (n is CI_MAX_SHARDS: a positive integer)" >&2; exit 2 ;; esac
# A cap past MAX_SHARDS is clamped, not refused: a refusal sends the plan job to 8 legs.
# 64 keeps the shard matrix well inside GitHub's 256-job matrix limit, which the
# other matrices share.
MAX_SHARDS=64
if [ "${#n}" -gt 3 ] || [ "$n" -gt "$MAX_SHARDS" ]; then
  echo "plan-shards.sh: CI_MAX_SHARDS=$n exceeds the cap of $MAX_SHARDS; planning at $MAX_SHARDS" >&2
  n=$MAX_SHARDS
fi
shift
root=.
if [ "$#" -gt 0 ] && [ "$1" != "--" ]; then root="$1"; shift; fi
[ "${1:-}" = "--" ] && shift
here="$(cd "$(dirname "$0")" && pwd)"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/plan-shards.XXXXXX") || exit 2
trap 'rm -rf "$tmp"' EXIT

ledger="${SUITE_DURATIONS:-$here/suite-durations.tsv}"
[ -r "$ledger" ] || ledger=/dev/null
total=""
if bash "$here/run-shell-tests.sh" --list "$@" "$root" > "$tmp/list" 2>/dev/null \
   && grep -q '^== Summary ==$' "$tmp/list"; then
  sed -n 's/^\[RUN \] //p' "$tmp/list" > "$tmp/suites"
  total=$(LC_ALL=C awk -F'\t' -v n="$n" -v target="$TARGET_S" '
    phase == 1 {
      if ($1 !~ /^[[:space:]]*#/ && $1 != "" && $2 ~ /^[0-9]+$/) { dur[$1] = $2 + 0; vals[++nv] = $2 + 0 }
      next
    }
    { suite[++m] = $0 }
    END {
      for (i = 2; i <= nv; i++) { v = vals[i]; j = i - 1; while (j >= 1 && vals[j] > v) { vals[j + 1] = vals[j]; j-- }; vals[j + 1] = v }
      med = (nv > 0) ? vals[int((nv + 1) / 2)] : 1
      if (med < 1) med = 1
      for (i = 1; i <= m; i++) { d = (suite[i] in dur) ? dur[suite[i]] : med; c[i] = (d < 1) ? 1 : d }
      for (i = 2; i <= m; i++) { v = c[i]; j = i - 1; while (j >= 1 && c[j] < v) { c[j + 1] = c[j]; j-- }; c[j + 1] = v }
      if (m == 0) { print 0; exit }
      if (nv == 0) exit
      for (k = 1; k <= n; k++) {
        for (b = 0; b < k; b++) load[b] = 0
        for (i = 1; i <= m; i++) { best = 0; for (b = 1; b < k; b++) if (load[b] < load[best]) best = b; load[best] += c[i] }
        span[k] = 0
        for (b = 0; b < k; b++) if (load[b] > span[k]) span[k] = load[b]
      }
      limit = (span[n] > target) ? span[n] : target
      for (k = 1; k <= n; k++) if (span[k] <= limit) { r = (k < m) ? k : m; print r; exit }
    }
  ' phase=1 "$ledger" phase=2 "$tmp/suites")
fi

case "$total" in
  0) printf 'shards=[]\nabsent_shards=1\nshard_total=1\n'; exit 0 ;;
  [1-9]*)
    list="" k=1
    while [ "$k" -le "$total" ]; do list="${list:+$list,}$k"; k=$((k + 1)); done
    printf 'shards=[%s]\nabsent_shards=\nshard_total=%s\n' "$list" "$total"
    exit 0 ;;
esac

k=1
while [ "$k" -le "$n" ]; do
  if [ "$#" -gt 0 ]; then
    ( bash "$here/shard-has-work.sh" "$k/$n" "$root" -- "$@" > "$tmp/$k.out" 2>/dev/null; echo $? > "$tmp/$k.rc" ) &
  else
    ( bash "$here/shard-has-work.sh" "$k/$n" "$root" > "$tmp/$k.out" 2>/dev/null; echo $? > "$tmp/$k.rc" ) &
  fi
  k=$((k + 1))
done
wait

list="" absent=""
k=1
while [ "$k" -le "$n" ]; do
  if [ "$(cat "$tmp/$k.rc" 2>/dev/null)" = "0" ] && [ "$(cat "$tmp/$k.out" 2>/dev/null)" = "has_work=false" ]; then
    absent="${absent:+$absent }$k"
  else
    list="${list:+$list,}$k"
  fi
  k=$((k + 1))
done
printf 'shards=[%s]\nabsent_shards=%s\nshard_total=%s\n' "$list" "$absent" "$n"
