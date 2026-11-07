#!/usr/bin/env bash
# selector: tree-scan
# scripts/ci/test-ledger-drift.sh — scripts/ci/ledger-drift.sh: packs the suite
# seconds measured in recent green main shell-unit runs with a duration ledger
# and flags the ledger when the slowest shard passes 1.3x the floor.
#
# The fixture runs under scripts/ci/fixtures/ledger-drift/ are copied from the
# real `gh run view --log` output of green main ci.yml runs 39886837066,
# 39918454994 and 39927689757 (shell-unit-shard 1..8, every suite that took
# >= 10s, minus the three whose names hold the word the ws5 T13(b) shipped-source
# scan reads as a service). stale-ledger.tsv is the committed scripts/ci/suite-durations.tsv as
# it stood before its 2026-10-02 refresh (git show 011d8fe2d^); the
# matching-ledger.tsv is the mean of the three runs.
#
#   LD1  a stale ledger  -> exit 1, DRIFT, the ratio printed above 1.3
#   LD2  a matching ledger -> exit 0, OK, the ratio printed at or below 1.3
#   LD3  --threshold moves the verdict on the same data (RED control for LD2)
#   LD4  a log dir with no [PASS] lines, or a missing ledger -> exit 2
#   LD5  lines from other jobs in a log are not counted
#   LD5d a [FLAKE] line counts like a [PASS] line
#   LD5q a [QUARANTINE] line counts like a [PASS] line
#   LD6  the workflow runs it on a schedule, never on pull_request or push
#   LD8  --no-row lists suites missing a tier or duration row, a no-row suite at tier pr
#   LD8b --no-row with an unreadable tier file -> exit 2, no count
#   LD9  the cadence run prints the list and keeps its verdict
#   LD10 the REFRESH recipe in the ledger's header harvests a suite with no row
#
# Platform guard: bash-only; Linux CI is the caller.
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
mkdir -p "$SUITE_LOCK_SANDBOX/empty" || fail "LD4: cannot create the empty log dir"
printf 'lint\tUNKNOWN STEP\t2026-10-23T09:31:30.0000000Z nothing here\n' > "$SUITE_LOCK_SANDBOX/empty/run-1.log" || fail "LD4: cannot write the no-timings log"
[ -s "$SUITE_LOCK_SANDBOX/empty/run-1.log" ] || fail "LD4: the no-timings log is empty, so exit 2 would prove nothing"
bash "$LD" --logs "$SUITE_LOCK_SANDBOX/empty" --ledger "$FX/matching-ledger.tsv" > /dev/null 2>&1; rc_a=$?
bash "$LD" --logs "$FX" --ledger "$SUITE_LOCK_SANDBOX/no-such-ledger.tsv" > /dev/null 2>&1; rc_b=$?
if [ "$rc_a" -eq 2 ] && [ "$rc_b" -eq 2 ]; then
  pass "LD4: a log with no suite timings and a missing ledger both exit 2"
else
  fail "LD4: expected rc 2 twice; no-timings rc=$rc_a missing-ledger rc=$rc_b"
fi

echo "== LD5: only shell-unit-shard lines count =="
mkdir -p "$SUITE_LOCK_SANDBOX/mixed" || fail "LD5: cannot create the mixed log dir"
cp "$FX"/run-*.log "$SUITE_LOCK_SANDBOX/mixed/" || fail "LD5: cannot copy the fixture logs"
printf 'lanes-and-trust-suites\tUNKNOWN STEP\t2026-10-23T09:31:30.0000000Z [PASS] scripts/ci/test-not-a-shard-job.sh (9000s)\n' >> "$SUITE_LOCK_SANDBOX/mixed/run-39927689757.log" || fail "LD5: cannot append the other-job line"
out_m=$(bash "$LD" --logs "$SUITE_LOCK_SANDBOX/mixed" --ledger "$FX/matching-ledger.tsv" 2>&1); rc_m=$?
out_c=$(bash "$LD" --logs "$FX" --ledger "$FX/matching-ledger.tsv" 2>&1)
if [ "$rc_m" -eq 0 ] && [ "$out_m" = "$out_c" ]; then
  pass "LD5: a 9000s line from another job changes nothing"
else
  fail "LD5: another job's line moved the result; rc=$rc_m out: $out_m"
fi

echo "== LD5b: a non-Linux shard's lines are not counted =="
cp "$FX"/run-*.log "$SUITE_LOCK_SANDBOX/mixed/" || fail "LD5b: cannot copy the fixture logs"
printf 'shell-unit-shard (macos-latest, 1)\tUNKNOWN STEP\t2026-10-23T09:31:30.0000000Z [PASS] scripts/ci/test-not-linux.sh (9000s)\n' >> "$SUITE_LOCK_SANDBOX/mixed/run-39927689757.log" || fail "LD5b: cannot append the macos line"
out_o=$(bash "$LD" --logs "$SUITE_LOCK_SANDBOX/mixed" --ledger "$FX/matching-ledger.tsv" 2>&1); rc_o=$?
if [ "$rc_o" -eq 0 ] && [ "$out_o" = "$out_c" ]; then
  pass "LD5b: a 9000s macos shard line changes nothing"
else
  fail "LD5b: a macos shard line moved the result; rc=$rc_o out: $out_o"
fi

echo "== LD5c: no awk integer constant past 2^31 (mawk clamps %d there) =="
big_constants() {
  grep -nE '(^|[^0-9.])[0-9]{10,}([^0-9]|$)' "$1" | grep -vE '^[0-9]+:[[:space:]]*#' | awk -F: '{ n = $0; sub(/^[0-9]+:/, "", n); while (match(n, /[0-9]{10,}/)) { if (substr(n, RSTART, RLENGTH) + 0 > 2147483647) print $1 ": " substr(n, RSTART, RLENGTH); n = substr(n, RSTART + RLENGTH) } }'
}
printf 'key = sprintf("%%012d", 999999999999 - c)\nok = 1000000000 - c\n' > "$SUITE_LOCK_SANDBOX/planted.sh" || fail "LD5c: cannot write the planted file"
planted=$(big_constants "$SUITE_LOCK_SANDBOX/planted.sh")
big=$(big_constants "$LD")
if [ -z "$planted" ]; then
  fail "LD5c: the scan missed a planted 999999999999, so it proves nothing"
elif [ -z "$big" ]; then
  pass "LD5c: the scan flags a planted 999999999999; ledger-drift.sh holds no integer constant above 2147483647"
else
  fail "LD5c: constants past 2^31 in ledger-drift.sh: $big"
fi

echo "== LD5d: a suite that passed on retry ([FLAKE]) is counted =="
cp "$FX"/run-*.log "$SUITE_LOCK_SANDBOX/mixed/" || fail "LD5d: cannot copy the fixture logs"
printf 'shell-unit-shard (ubuntu-latest, 1)\tUNKNOWN STEP\t2026-10-23T09:31:30.0000000Z [FLAKE] scripts/ci/test-flaky-fixture.sh (first run rc=1, passed on retry, 90s)\n' >> "$SUITE_LOCK_SANDBOX/mixed/run-39927689757.log" || fail "LD5d: cannot append the FLAKE line"
out_f=$(bash "$LD" --logs "$SUITE_LOCK_SANDBOX/mixed" --ledger "$FX/matching-ledger.tsv" 2>&1)
n_c=$(sed -n 's/.* suites=\([0-9]*\) .*/\1/p' <<< "$out_c")
n_f=$(sed -n 's/.* suites=\([0-9]*\) .*/\1/p' <<< "$out_f")
if [ -n "$n_c" ] && [ -n "$n_f" ] && [ "$n_f" -eq $((n_c + 1)) ]; then
  pass "LD5d: a [FLAKE] line adds its suite ($n_c -> $n_f)"
else
  fail "LD5d: expected one more suite from a [FLAKE] line; clean=$n_c with-flake=$n_f"
fi

echo "== LD5q: a failing quarantined suite ([QUARANTINE]) is counted =="
# The line is copied verbatim from shell-unit-shard (ubuntu-latest, 12) of PR run 41169906564: a quarantine
# suite that fails is retried once and this line carries the seconds of the last attempt.
mkdir -p "$SUITE_LOCK_SANDBOX/quar" || fail "LD5q: cannot create the quarantine dir"
cp "$FX"/run-*.log "$SUITE_LOCK_SANDBOX/quar/" || fail "LD5q: cannot copy the fixture logs"
printf 'shell-unit-shard (ubuntu-latest, 1)\tRun bash scripts/ci/home-canary.sh --shard 12/20 .\t2026-10-31T05:07:48.7271309Z [QUARANTINE] scripts/handover/chief-kit/test-chief-wait-b.sh (rc=1, 499s) — tier quarantine, not failing the run\n' >> "$SUITE_LOCK_SANDBOX/quar/run-39927689757.log" || fail "LD5q: cannot append the QUARANTINE line"
out_q=$(bash "$LD" --logs "$SUITE_LOCK_SANDBOX/quar" --ledger "$FX/matching-ledger.tsv" 2>&1)
n_q=$(sed -n 's/.* suites=\([0-9]*\) .*/\1/p' <<< "$out_q")
if [ -n "$n_c" ] && [ -n "$n_q" ] && [ "$n_q" -eq $((n_c + 1)) ]; then
  pass "LD5q: a [QUARANTINE] line adds its suite ($n_c -> $n_q)"
else
  fail "LD5q: expected one more suite from a [QUARANTINE] line; clean=$n_c with-quarantine=$n_q"
fi
# The seconds count, not only the suite: alone in a log, its 499 s is the slowest (and only) shard.
mkdir -p "$SUITE_LOCK_SANDBOX/quar1" || fail "LD5q: cannot create the one-suite dir"
tail -n 1 "$SUITE_LOCK_SANDBOX/quar/run-39927689757.log" > "$SUITE_LOCK_SANDBOX/quar1/run-1.log" || fail "LD5q: cannot write the one-suite log"
out_q1=$(bash "$LD" --logs "$SUITE_LOCK_SANDBOX/quar1" --ledger "$FX/matching-ledger.tsv" --shards 1 2>&1); rc_q1=$?
if [ "$rc_q1" -eq 0 ] && grepq "$out_q1" -F 'suites=1 shards=1 slowest=499s'; then
  pass "LD5q: a lone [QUARANTINE] line is measured at its 499 s"
else
  fail "LD5q: expected suites=1 shards=1 slowest=499s from a lone [QUARANTINE] line with rc 0; rc=$rc_q1 got: $out_q1"
fi

echo "== LD6: the workflow is scheduled and never runs on a PR or a push =="
# comments dropped, so a trigger or the script path named only in one never counts
wf_ok() {
  local body
  body=$(grep -vE '^[[:space:]]*#' "$1" | sed 's/[[:space:]]#.*$//') || return 1
  grep -qE '^[[:space:]]*schedule:' <<< "$body" && grep -qE '^[[:space:]]*workflow_dispatch:' <<< "$body" \
    && ! grep -qE '^[[:space:]]*(pull_request|pull_request_target|push):' <<< "$body" \
    && grep -qE 'bash scripts/ci/ledger-drift\.sh' <<< "$body"
}
mkdir -p "$SUITE_LOCK_SANDBOX/wf" || fail "LD6: cannot create the workflow mutant dir"
awk '/^  schedule:/ { print "    pull_request:" } { print }' "$WF" > "$SUITE_LOCK_SANDBOX/wf/pr-indented.yml" || fail "LD6: cannot write the pr-indented mutant"
sed 's/bash scripts\/ci\/ledger-drift\.sh/true # bash scripts\/ci\/ledger-drift.sh/' "$WF" > "$SUITE_LOCK_SANDBOX/wf/path-in-comment.yml" || fail "LD6: cannot write the path-in-comment mutant"
if [ -f "$WF" ] && wf_ok "$WF" && ! wf_ok "$SUITE_LOCK_SANDBOX/wf/pr-indented.yml" && ! wf_ok "$SUITE_LOCK_SANDBOX/wf/path-in-comment.yml"; then
  pass "LD6: ledger-drift.yml has schedule + workflow_dispatch, no pull_request/push, runs ledger-drift.sh; both mutants rejected"
else
  fail "LD6: .github/workflows/ledger-drift.yml missing, not schedule/dispatch-only, does not run ledger-drift.sh, or a mutant (indented pull_request, path only in a comment) passed"
fi

echo "== LD7: no ledger row is above 900s, 75% of the 1200s cap the longest suites get (1350s for test-review-panel.sh, 75% of its 1800s cap) =="
# A suite near the cap is killed with no assertion failing as soon as a loaded
# runner is slower than the ledger run. The control row is the real line from
# green main run 40030573258 (shell-unit-shard 3): [PASS] scripts/test-adopt.sh (969s).
LD7_CEILING=900
# test-review-panel.sh has a 1800s cap in run-shell-tests.sh (60 real case repos,
# measured 1295s in CI), so the same 75% rule puts its ceiling at 1350s. It is the
# only suite with a higher ceiling.
LD7_PANEL_SUITE=scripts/eval/review-panel/test-review-panel.sh
LD7_PANEL_CEILING=1350
ledger_over_ceiling() {
  awk -F'\t' -v ceil="$LD7_CEILING" -v psuite="$LD7_PANEL_SUITE" -v pceil="$LD7_PANEL_CEILING" '/^[[:space:]]*(#|$)/ { next } { c = ($1 == psuite) ? pceil : ceil } $2 + 0 > c { print $1 "\t" $2; bad = 1 } END { exit bad }' "$1"
}
printf 'scripts/test-adopt.sh\t969\n' > "$SUITE_LOCK_SANDBOX/over-ceiling.tsv" || fail "LD7: cannot write the control ledger"
printf '%s\t1351\n' "$LD7_PANEL_SUITE" > "$SUITE_LOCK_SANDBOX/over-panel.tsv" || fail "LD7: cannot write the review-panel control ledger"
printf 'scripts/test-adopt.sh\t1295\n' > "$SUITE_LOCK_SANDBOX/other-1295.tsv" || fail "LD7: cannot write the other-suite control ledger"
if ledger_over_ceiling "$SUITE_LOCK_SANDBOX/over-ceiling.tsv" >/dev/null; then
  fail "LD7: the control ledger (test-adopt.sh at 969s) was accepted"
elif ledger_over_ceiling "$SUITE_LOCK_SANDBOX/over-panel.tsv" >/dev/null; then
  fail "LD7: the control ledger (test-review-panel.sh at 1351s) was accepted"
elif ledger_over_ceiling "$SUITE_LOCK_SANDBOX/other-1295.tsv" >/dev/null; then
  fail "LD7: the control ledger (another suite at 1295s) was accepted"
elif over=$(ledger_over_ceiling "$SRC_ROOT/scripts/ci/suite-durations.tsv"); then
  pass "LD7: the three control rows are refused and the committed ledger has no row above its ceiling (${LD7_CEILING}s, ${LD7_PANEL_CEILING}s for review-panel)"
else
  fail "LD7: committed ledger rows above ${LD7_CEILING}s: $over"
fi

echo "== LD8: --no-row lists the suites a list does not name =="
NR="$SUITE_LOCK_SANDBOX/no-row"
mkdir -p "$NR" || fail "LD8: cannot make the fixture dir"
printf 'scripts/x/%s\n' test-both.sh test-no-tier.sh test-no-dur.sh test-neither.sh helper.sh > "$NR/tracked"
printf '# fixture tiers\nscripts/x/test-both.sh\tlocal\tx\nscripts/x/test-no-dur.sh\tlocal\tx\n' > "$NR/tiers.tsv"
printf '# fixture ledger\nscripts/x/test-both.sh\t10\nscripts/x/test-no-tier.sh\t30\n' > "$NR/ledger.tsv"
out=$(bash "$LD" --no-row --ledger "$NR/ledger.tsv" --tiers "$NR/tiers.tsv" --tracked "$NR/tracked" 2>&1); rc=$?
if [ "$rc" -eq 0 ] \
   && grepq "$out" -x 'ledger-drift: no-row scripts/x/test-no-tier.sh tier=pr tier-row=no duration-row=yes seconds=30' \
   && grepq "$out" -x 'ledger-drift: no-row scripts/x/test-no-dur.sh tier=local tier-row=yes duration-row=no seconds=10' \
   && grepq "$out" -x 'ledger-drift: no-row scripts/x/test-neither.sh tier=pr tier-row=no duration-row=no seconds=10' \
   && grepq "$out" -x 'ledger-drift: no-row count=3 no-tier-row=2 no-duration-row=2 untiered-seconds=40' \
   && ! grepq "$out" -F 'test-both.sh' && ! grepq "$out" -F 'helper.sh'; then
  pass "LD8: --no-row lists three suites, a no-row suite at tier pr, with the untiered cost"
else
  fail "LD8: rc=$rc out: $out"
fi

echo "== LD8b: --no-row refuses to count from an unreadable tier file =="
out=$(bash "$LD" --no-row --ledger "$NR/ledger.tsv" --tiers "$NR/absent.tsv" --tracked "$NR/tracked" 2>&1); rc=$?
if [ "$rc" -eq 2 ] && ! grepq "$out" -F 'count='; then
  pass "LD8b: unreadable tier file -> rc 2, no count"
else
  fail "LD8b: rc=$rc out: $out"
fi

echo "== LD9: the cadence run prints the list and keeps its verdict =="
for pair in "stale-ledger.tsv:1:DRIFT" "matching-ledger.tsv:0:OK"; do
  f=${pair%%:*}; v=${pair##*:}; want=${pair#*:}; want=${want%%:*}
  out=$(bash "$LD" --logs "$FX" --ledger "$FX/$f" --tiers "$NR/tiers.tsv" --tracked "$NR/tracked" 2>&1); rc=$?
  if [ "$rc" -eq "$want" ] && grepq "$out" -F "$v" && grepq "$out" -E '^ledger-drift: no-row count=[0-9]+ ' \
     && grepq "$out" -F 'no-row scripts/x/test-neither.sh tier=pr'; then
    pass "LD9: $f -> rc $want, $v, and the no-row list"
  else
    fail "LD9: $f: want rc $want, $v and the list; rc=$rc out: $out"
  fi
done
out=$(bash "$LD" --logs "$FX" --ledger "$FX/matching-ledger.tsv" --tiers "$NR/absent.tsv" --tracked "$NR/tracked" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" -F 'ledger-drift: OK'; then
  pass "LD9: a list that cannot be computed leaves the drift verdict alone"
else
  fail "LD9: unreadable tier file changed the verdict: rc=$rc out: $out"
fi

echo "== LD10: the REFRESH recipe harvests a suite with no row =="
# The sed expression is read out of the ledger's own header, so the row follows the recipe.
recipe=$(sed -n "s/^#     | sed -nE '\(.*\)' \\\\\$/\1/p" "$SRC_ROOT/scripts/ci/suite-durations.tsv")
printf 'shell-unit-shard (ubuntu-latest, 1)\trun\t2026-11-07T00:00:00Z [PASS] scripts/x/test-neither.sh (7s)\n' > "$NR/run.log"
harvest=$(sed -nE "$recipe" "$NR/run.log")
if [ -n "$recipe" ] && [ "$harvest" = "$(printf 'scripts/x/test-neither.sh\t7')" ]; then
  pass "LD10: the recipe adds a row for a suite the ledger does not name"
else
  fail "LD10: recipe '$recipe' harvested '$harvest'"
fi

rst_tally
