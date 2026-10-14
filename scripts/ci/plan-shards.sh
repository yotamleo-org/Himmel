#!/usr/bin/env bash
# scripts/ci/plan-shards.sh — which shell-unit shards of <n> have a
# suite to run under the current selection env. Prints GITHUB_OUTPUT lines:
#   shards=[1,3]          JSON list for the shard job's matrix
#   absent_shards=2 4     the others, for shard-manifest-verify.sh --absent-ok
#
# Usage: plan-shards.sh <n> [<scan root>]      (root defaults .)
#
# One shard-has-work.sh probe per shard, run in parallel (each only lists, it
# executes no suite). FAIL-CLOSED per shard: a probe that fails, prints nothing
# or prints anything but `has_work=false` leaves the shard in the list. And a
# shard wrongly left out is still caught downstream: the aggregator's manifest
# accounting demands every selected suite ran exactly once.
#
# Platform guard: bash 3.2+; Linux CI is the only caller.
set -uo pipefail

n="${1:-}"
root="${2:-.}"
case "$n" in ''|*[!0-9]*|0*) echo "usage: plan-shards.sh <n> [<root>]" >&2; exit 2 ;; esac
here="$(cd "$(dirname "$0")" && pwd)"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/plan-shards.XXXXXX") || exit 2
trap 'rm -rf "$tmp"' EXIT

k=1
while [ "$k" -le "$n" ]; do
  ( bash "$here/shard-has-work.sh" "$k/$n" "$root" > "$tmp/$k.out" 2>/dev/null; echo $? > "$tmp/$k.rc" ) &
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
printf 'shards=[%s]\nabsent_shards=%s\n' "$list" "$absent"
