#!/usr/bin/env bash
# scripts/handover/test-arm-resume-1879-b.sh — part 2 of the 1879 family of
# test-arm-resume.sh, dispatched via the `--only` seam: section "1879-lapse",
# the last three target-lapse scenarios (1879j, 1999a, 1999b). Each waits for
# the real clock to cross a minute, so the family is split across two suites
# to fit a CI shard. Part 1 is test-arm-resume-1879.sh.
#
# Same tier as part 1: SUITE_TIER_DEFAULT `extended` in run-shell-tests.sh.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
exec bash test-arm-resume.sh --only "1879-lapse"
