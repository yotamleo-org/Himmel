#!/usr/bin/env bash
# scripts/ci/tier-replay.sh — replays the SUITE_TIER_MODE=pr selector over real
# history and fails when it would drop a suite that must run (the F3 rule).
#
# Fixtures (scripts/ci/fixtures/tier-replay/):
#   catches.tsv  the 64 live CATCH events of the shard test-value audit; a row whose
#                suite is - was caught by a non-shard job, so no tier can drop it.
#   manifests/   the selection header (every line up to `shard`) of 30 real PR
#                runs, copied from their shell-unit-manifest-ubuntu-latest-shard1
#                artifacts and named by run id.
#
# The selector is the runner itself: SUITE_TIER_MODE=pr run-shell-tests.sh --list
# over this checkout gives the tier floor T, every listed suite that is neither
# [SKIP]ped "tier:" nor a local row. A local row an earlier rule skips first stays
# out of T: that rule (the off-Linux skip list) does not hold on every host.
# A manifest's pr-mode selection is T plus its impacted `suite` lines, or every
# suite under `mode full`. A catch suite or a trust-owned suite (test-suite-tiers.sh
# --lint's own rule, over every tracked suite) outside a selection fails the replay.
#
# Usage: bash scripts/ci/tier-replay.sh [--tiers <suite-tiers.tsv>]
#
# Exit codes: 0 — every catch and trust-owned suite is selected; 1 — one is not
# (each named); 2 — usage error, a fixture count is off, or the runner failed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIX="$ROOT/scripts/ci/fixtures/tier-replay"
tiers="$ROOT/scripts/ci/suite-tiers.tsv"
case "$#:${1:-}" in
  0:) ;;
  2:--tiers) tiers="$2" ;;
  *) echo "usage: $0 [--tiers <suite-tiers.tsv>]" >&2; exit 2 ;;
esac
case "$tiers" in /*) ;; *) tiers="$PWD/$tiers" ;; esac
[ -r "$tiers" ] || { echo "tier-replay: cannot read $tiers" >&2; exit 2; }

# shellcheck source=../lib/prim.sh
. "$ROOT/scripts/lib/prim.sh" || exit 2
tmp=$(tmpdir) || exit 2
trap 'rm -rf "$tmp"' EXIT

n_catch=$(grep -vc '^#' "$FIX/catches.tsv")
n_man=$(find "$FIX/manifests" -name '*.txt' | wc -l | tr -d ' ')
if [ "$n_catch" != 64 ] || [ "$n_man" != 30 ]; then
  echo "tier-replay: the fixture holds $n_catch catches and $n_man manifests, want 64 and 30" >&2
  exit 2
fi

if ! (cd "$ROOT" && SUITE_TIER_MODE=pr SUITE_TIERS_TSV="$tiers" bash scripts/ci/run-shell-tests.sh --list) > "$tmp/plan" 2>&1; then
  echo "tier-replay: the runner's pr-mode --list failed:" >&2
  tail -n 20 "$tmp/plan" >&2
  exit 2
fi
# `[RUN ] <suite>` and `[SKIP] <suite> — <reason>`, the suite spelled under the scan root.
awk '/^\[RUN \] / {print $3} /^\[SKIP\] / {print $2}' "$tmp/plan" | sed 's#^\./##' | sort -u > "$tmp/all"
awk -F'\t' '!/^#/ && $2 == "local" {print $1}' "$tiers" | sort -u > "$tmp/local"
awk '/^\[RUN \] / {print $3} /^\[SKIP\] / && !/ — tier: / {print $2}' "$tmp/plan" | sed 's#^\./##' | sort -u \
  | comm -23 - "$tmp/local" > "$tmp/T"

git -C "$ROOT" ls-files | awk -F/ '$NF ~ /^test-.*\.sh$/ {print $0 "\tlocal\tx"}' > "$tmp/all-local.tsv"
bash "$ROOT/scripts/ci/test-suite-tiers.sh" --lint --tiers "$tmp/all-local.tsv" \
  | sed -n 's/^FAIL trust-path suite is local: //p' | sort -u > "$tmp/trust"
awk -F'\t' '!/^#/ && $4 != "-" {print $4}' "$FIX/catches.tsv" | sort -u > "$tmp/catch"
if [ ! -s "$tmp/T" ] || [ ! -s "$tmp/trust" ] || [ ! -s "$tmp/catch" ]; then
  echo "tier-replay: an empty set (tier floor $(wc -l < "$tmp/T"), trust-owned $(wc -l < "$tmp/trust"), catch $(wc -l < "$tmp/catch")) — refusing a vacuous pass" >&2
  exit 2
fi
sort -u "$tmp/catch" "$tmp/trust" > "$tmp/must"

misses=0
miss() { # <selection> <label>
  local s
  while IFS= read -r s; do
    if grep -qxF "$s" "$tmp/catch"; then
      echo "MISS $2: catch suite not selected: $s"
    else
      echo "MISS $2: trust-owned suite not selected: $s"
    fi
    misses=$((misses + 1))
  done < <(comm -23 "$tmp/must" "$1")
}

miss "$tmp/T" "tier floor"
printf '%-12s %-9s %8s %8s\n' run mode today pr-mode
for m in "$FIX"/manifests/*.txt; do
  run=$(basename "$m" .txt)
  mode=$(sed -n 's/^mode //p' "$m")
  sed -n 's/^suite //p' "$m" | sort -u > "$tmp/S"
  case "$mode" in
    full) cp "$tmp/all" "$tmp/sel"; today=$(wc -l < "$tmp/all") ;;
    impacted) sort -u "$tmp/T" "$tmp/S" > "$tmp/sel"; today=$(wc -l < "$tmp/S") ;;
    *) echo "tier-replay: $m has no mode line" >&2; exit 2 ;;
  esac
  printf '%-12s %-9s %8s %8s\n' "$run" "$mode" "$today" "$(wc -l < "$tmp/sel")"
  miss "$tmp/sel" "run $run"
done

if [ "$misses" -gt 0 ]; then
  echo "tier-replay: FAIL — $misses selection miss(es)"
  exit 1
fi
printf 'tier-replay: PASS — %s catches (%s shard suites), %s trust-owned suites, %s manifests; tier floor %s of %s suites\n' \
  "$n_catch" "$(wc -l < "$tmp/catch" | tr -d ' ')" "$(wc -l < "$tmp/trust" | tr -d ' ')" "$n_man" \
  "$(wc -l < "$tmp/T" | tr -d ' ')" "$(wc -l < "$tmp/all" | tr -d ' ')"
