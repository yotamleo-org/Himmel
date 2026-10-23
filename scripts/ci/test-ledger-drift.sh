#!/usr/bin/env bash
# selector: tree-scan
# scripts/ci/test-ledger-drift.sh — scripts/ci/ledger-drift.sh: packs the suite
# seconds measured in recent green main shell-unit runs with a duration ledger
# and flags the ledger when the slowest shard passes 1.3x the floor.
#
# The fixture runs under scripts/ci/fixtures/ledger-drift/ are copied from the
# real `gh run view --log` output of green main ci.yml runs 39886837066,
# 39918454994 and 39927689757 (shell-unit-shard 1..8, every suite that took
# >= 10s). stale-ledger.tsv is the committed scripts/ci/suite-durations.tsv as
# it stood before its 2026-10-02 refresh (git show 011d8fe2d^); the
# matching-ledger.tsv is the mean of the three runs.
#
#   LD1  a stale ledger  -> exit 1, DRIFT, the ratio printed above 1.3
#   LD2  a matching ledger -> exit 0, OK, the ratio printed at or below 1.3
#   LD3  --threshold moves the verdict on the same data (RED control for LD2)
#   LD4  a log dir with no [PASS] lines, or a missing ledger -> exit 2
#   LD5  lines from other jobs in a log are not counted
#   LD6  the workflow runs it on a schedule, never on pull_request or push
#
# Platform guard: bash-only, no .ps1 twin; Linux CI is the caller.
#
# Usage: bash scripts/ci/test-ledger-drift.sh
# Exit codes: 0 — all cases passed; 1 — at least one failed.
set -uo pipefail

# shellcheck source=run-shell-tests-fixture.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/run-shell-tests-fixture.sh"

SRC_ROOT="$(cd "$RST_FIXTURE_DIR/../.." && pwd)"
LD="$SRC_ROOT/scripts/ci/ledger-drift.sh"
FX="$RST_FIXTURE_DIR/fixtures/ledger-drift"
WF="$SRC_ROOT/.github/workflows/ledger-drift.yml"

if [ ! -f "$LD" ]; then
  fail "missing scripts/ci/ledger-drift.sh"
  rst_tally
fi

echo "== LD1: a stale ledger flags drift =="
out=$(bash "$LD" --logs "$FX" --ledger "$FX/stale-ledger.tsv" 2>&1); rc=$?
ratio=$(sed -n 's/.*slowest\/floor=\([0-9.]*\).*/\1/p' <<< "$out")
if [ "$rc" -eq 1 ] && grepq "$out" -F 'DRIFT' && [ -n "$ratio" ] && awk -v r="$ratio" 'BEGIN { exit !(r > 1.3) }'; then
  pass "LD1: stale ledger -> rc 1, DRIFT, slowest/floor=$ratio"
else
  fail "LD1: expected rc 1, DRIFT and slowest/floor above 1.3; rc=$rc out: $out"
fi

echo "== LD2: a matching ledger is clean =="
out=$(bash "$LD" --logs "$FX" --ledger "$FX/matching-ledger.tsv" 2>&1); rc=$?
ratio2=$(sed -n 's/.*slowest\/floor=\([0-9.]*\).*/\1/p' <<< "$out")
if [ "$rc" -eq 0 ] && grepq "$out" -F 'OK' && [ -n "$ratio2" ] && awk -v r="$ratio2" 'BEGIN { exit !(r <= 1.3) }' \
   && grepq "$out" 'max/min=[0-9.]'; then
  pass "LD2: matching ledger -> rc 0, OK, slowest/floor=$ratio2, max/min printed"
else
  fail "LD2: expected rc 0, OK, slowest/floor at most 1.3 and a max/min; rc=$rc out: $out"
fi

echo "== LD3: the threshold decides =="
out=$(bash "$LD" --logs "$FX" --ledger "$FX/matching-ledger.tsv" --threshold 1.0 2>&1); rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" -F 'DRIFT'; then
  pass "LD3: the clean ledger flags at --threshold 1.0 (ratio $ratio2)"
else
  fail "LD3: expected rc 1 and DRIFT at --threshold 1.0; rc=$rc out: $out"
fi

echo "== LD4: no usable input is an error, not a pass =="
mkdir -p "$SUITE_LOCK_SANDBOX/empty"
printf 'lint\tUNKNOWN STEP\t2026-10-23T09:31:30.0000000Z nothing here\n' > "$SUITE_LOCK_SANDBOX/empty/run-1.log"
bash "$LD" --logs "$SUITE_LOCK_SANDBOX/empty" --ledger "$FX/matching-ledger.tsv" > /dev/null 2>&1; rc_a=$?
bash "$LD" --logs "$FX" --ledger "$SUITE_LOCK_SANDBOX/no-such-ledger.tsv" > /dev/null 2>&1; rc_b=$?
if [ "$rc_a" -eq 2 ] && [ "$rc_b" -eq 2 ]; then
  pass "LD4: a log with no suite timings and a missing ledger both exit 2"
else
  fail "LD4: expected rc 2 twice; no-timings rc=$rc_a missing-ledger rc=$rc_b"
fi

echo "== LD5: only shell-unit-shard lines count =="
mkdir -p "$SUITE_LOCK_SANDBOX/mixed"
cp "$FX"/run-*.log "$SUITE_LOCK_SANDBOX/mixed/"
printf 'lanes-and-trust-suites\tUNKNOWN STEP\t2026-10-23T09:31:30.0000000Z [PASS] scripts/ci/test-not-a-shard-job.sh (9000s)\n' >> "$SUITE_LOCK_SANDBOX/mixed/run-39927689757.log"
out_m=$(bash "$LD" --logs "$SUITE_LOCK_SANDBOX/mixed" --ledger "$FX/matching-ledger.tsv" 2>&1); rc_m=$?
out_c=$(bash "$LD" --logs "$FX" --ledger "$FX/matching-ledger.tsv" 2>&1)
if [ "$rc_m" -eq 0 ] && [ "$out_m" = "$out_c" ]; then
  pass "LD5: a 9000s line from another job changes nothing"
else
  fail "LD5: another job's line moved the result; rc=$rc_m out: $out_m"
fi

echo "== LD5b: a non-Linux shard's lines are not counted =="
cp "$FX"/run-*.log "$SUITE_LOCK_SANDBOX/mixed/"
printf 'shell-unit-shard (macos-latest, 1)\tUNKNOWN STEP\t2026-10-23T09:31:30.0000000Z [PASS] scripts/ci/test-not-linux.sh (9000s)\n' >> "$SUITE_LOCK_SANDBOX/mixed/run-39927689757.log"
out_o=$(bash "$LD" --logs "$SUITE_LOCK_SANDBOX/mixed" --ledger "$FX/matching-ledger.tsv" 2>&1); rc_o=$?
if [ "$rc_o" -eq 0 ] && [ "$out_o" = "$out_c" ]; then
  pass "LD5b: a 9000s macos shard line changes nothing"
else
  fail "LD5b: a macos shard line moved the result; rc=$rc_o out: $out_o"
fi

echo "== LD5c: no awk integer constant past 2^31 (mawk clamps %d there) =="
big=$(grep -nE '(^|[^0-9.])[0-9]{10,}([^0-9]|$)' "$LD" | grep -vE '^[0-9]+:[[:space:]]*#' | awk -F: '{ n = $0; sub(/^[0-9]+:/, "", n); while (match(n, /[0-9]{10,}/)) { if (substr(n, RSTART, RLENGTH) + 0 > 2147483647) print $1 ": " substr(n, RSTART, RLENGTH); n = substr(n, RSTART + RLENGTH) } }')
if [ -z "$big" ]; then
  pass "LD5c: ledger-drift.sh holds no integer constant above 2147483647"
else
  fail "LD5c: constants past 2^31 in ledger-drift.sh: $big"
fi

echo "== LD6: the workflow is scheduled and never runs on a PR or a push =="
if [ -f "$WF" ] \
   && grep -qE '^  schedule:' "$WF" && grep -qE '^  workflow_dispatch:' "$WF" \
   && ! grep -qE '^  (pull_request|pull_request_target|push):' "$WF" \
   && grep -qF 'scripts/ci/ledger-drift.sh' "$WF"; then
  pass "LD6: ledger-drift.yml has schedule + workflow_dispatch, no pull_request/push, runs ledger-drift.sh"
else
  fail "LD6: .github/workflows/ledger-drift.yml missing, or not schedule/dispatch-only, or does not run ledger-drift.sh"
fi

rst_tally
