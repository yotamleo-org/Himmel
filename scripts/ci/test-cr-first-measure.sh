#!/usr/bin/env bash
# Test for scripts/ci/cr-first-measure.sh.
# The bundle fixture is two real merged PRs (#3222, #3215) as the script's own
# --dump wrote them from the live API; the expected counts below were read off
# the raw API by hand, not from the script.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/ci/cr-first-measure.sh"
FIXTURE="$ROOT/scripts/ci/fixtures/cr-first-measure-bundle.jsonl"

fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }
has() { if printf '%s\n' "$3" | grep -qF -- "$2"; then ok "$1"; else bad "$1: want '$2' in: $3"; fi; }

if bash -n "$SCRIPT"; then ok "syntax (bash -n)"; else bad "syntax"; fi

out="$(bash "$SCRIPT" --bundle "$FIXTURE" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then ok "rc 0 on the real bundle"; else bad "rc $rc: $out"; fi

# PR 3222: 86eaf8614 (no CodeRabbit status) and 5e6893ec0 (2 actionable)
# cancelled by 823fe53c7 (review completed, clean).
has "3222 rows" "pr=3222 runs=3 superseded=2 cr_superseded=1" "$out"
# PR 3215: dd15c7b5e (4 actionable) superseded, bb5bd4b7b (skip only) ran to
# success then superseded, 8747f73f3 (2 actionable) superseded, 4b5974964 and
# 965a4d4cf rate-limited and superseded, 4da391134 rate-limited, final.
has "3215 rows" "pr=3215 runs=6 superseded=5 cr_superseded=2" "$out"
has "totals" "cr-first: prs=2 runs=9 superseded=7 cr_superseded=3" "$out"
has "head states" "cr-first: heads=9 flagged=3 clean=1 skipped=1 rate_limited=3 absent=1" "$out"
# push-to-review minutes: 1.0 (823f), 13.9 (dd15), 14.3 (8747), 32.0 (5e68).
has "latency" "cr-first: review_latency_min n=4 median=13.9 p90=32.0" "$out"
# Job counts and minutes cross-checked with a separate Python reading of the
# same bundle. 5e6893ec0's run sat queued and was cancelled before any job
# started, so PR 3222 burned 0 jobs on its flagged head.
has "3222 burn" "pr=3222 runs=3 superseded=2 cr_superseded=1 cr_superseded_jobs=0 cr_superseded_min=0.0" "$out"
has "burn" "cr-first: cr_superseded_jobs=110 cr_superseded_min=871.8 superseded_jobs=179 superseded_min=1591.5 total_jobs=261 total_min=2483.2 jobs_per_pr=130.5" "$out"

out="$(bash "$SCRIPT" --bogus 2>&1)"; rc=$?
if [ "$rc" -eq 2 ]; then ok "unknown flag is a usage error"; else bad "unknown flag rc $rc: $out"; fi

[ "$fails" -eq 0 ] && { echo "PASS: test-cr-first-measure"; exit 0; }
echo "FAIL: test-cr-first-measure ($fails)" >&2
exit 1
