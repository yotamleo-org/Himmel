#!/usr/bin/env bash
# scripts/eval/leg-digest/test-pdd-share.sh - hermetic suite for the proof-first (PDD) share reader.
# A fixture Jira mirror and a fixture merged-PR list under fixtures/pdd/; scratch ledger only, never ~/.himmel.
# No model call, no network, no bank.
#  1. each PR is judged on its two halves: ticket DoD and Proof before the first commit, RED then GREEN in the body;
#  2. a PR with no ticket, a ticket outside the mirror, or no commits is skipped, not counted as a miss;
#  3. the row carries n, the share with a Wilson range, and is partial below --min-n;
#  4. --record appends one valid eval-runs row.
#
# check() evals its condition, so the single quotes are deliberate.
# shellcheck disable=SC2016,SC2034
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PDD="$HERE/pdd_share.py"
EVR="$HERE/../lib/eval_runs.py"
FX="$HERE/fixtures/pdd"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pdd-share-test.XXXXXX")" || { echo "test-pdd-share: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export HIMMEL_EVAL_RUNS_LEDGER="$TMP/never-eval.jsonl"
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
pdd() { python3 -I "$PDD" --prs "$FX/prs.json" --mirror "$FX/mirror" "$@"; }

echo "1. the halves, per PR"
pdd --min-n 5 >"$TMP/row.json" 2>"$TMP/row.err"; RC=$?
check "eight readable PRs, exit 0 when n reaches --min-n" '[ "$RC" = 0 ] && jq -e ".n == 8 and .eval == \"pdd-share\" and .status == \"ok\"" "$TMP/row.json" >/dev/null'
check "two PRs are proof-first (one with blank lines under its headings): DoD and Proof before the first commit, RED then GREEN" 'jq -e ".metrics | .[\"pdd.k\"] == 2 and .[\"pdd.n\"] == 8" "$TMP/row.json" >/dev/null'
check "five tickets had DoD and Proof first (not the no-Proof ticket, not the late ticket, not the empty-DoD ticket)" 'jq -e ".metrics[\"ticket_first.k\"] == 5" "$TMP/row.json" >/dev/null'
check "five bodies show RED then GREEN (not GREEN-first, not only in the CodeRabbit block, not GREEN-only)" 'jq -e ".metrics[\"red_green.k\"] == 5" "$TMP/row.json" >/dev/null'

echo "2. skipped PRs"
check "no ticket, ticket outside the mirror and no commits are named in meta.skipped" 'jq -e ".meta.skipped == {\"no_ticket\": 1, \"not_in_mirror\": 1, \"no_commits\": 1} and .meta.prs_seen == 11" "$TMP/row.json" >/dev/null'

jq '. + [(.[0] | .number = 99 | .commits = null)]' "$FX/prs.json" >"$TMP/unreadable.json"
python3 -I "$PDD" --prs "$TMP/unreadable.json" --mirror "$FX/mirror" --min-n 5 >"$TMP/unreadable.out" 2>/dev/null; RC=$?
check "a PR whose commit lookup failed is named, and makes the row partial with exit 3 even above --min-n" '[ "$RC" = 3 ] && jq -e ".status == \"partial\" and .n == 8 and .meta.skipped.commits_unreadable == 1" "$TMP/unreadable.out" >/dev/null'

echo "3. the row"
check "the share has a 95 % Wilson range around it" 'jq -e ".ci_method == \"wilson\" and .ci_level == 0.95 and .ci[\"pdd.pct\"].lo <= .metrics[\"pdd.pct\"] and .metrics[\"pdd.pct\"] <= .ci[\"pdd.pct\"].hi and .ci[\"pdd.pct\"].hi < 1" "$TMP/row.json" >/dev/null'
pdd >"$TMP/small.json" 2>/dev/null; RC=$?
check "below the default --min-n 50 the row is partial and the exit code is 3" '[ "$RC" = 3 ] && jq -e ".status == \"partial\" and .n == 8" "$TMP/small.json" >/dev/null'
echo '[]' >"$TMP/none.json"
python3 -I "$PDD" --prs "$TMP/none.json" --mirror "$FX/mirror" >/dev/null 2>&1; RC=$?
check "no readable PR exits 1 with no row" '[ "$RC" = 1 ]'
python3 -I "$PDD" --prs "$TMP/missing.json" --mirror "$FX/mirror" >/dev/null 2>&1; RC=$?
check "an unreadable PR list exits 1" '[ "$RC" = 1 ]'

echo "4. --record"
pdd --min-n 5 --record --ledger "$TMP/led.jsonl" >/dev/null 2>&1; REC=$?
check "--record appends exactly one row and exits 0" '[ "$REC" = 0 ] && [ "$(grep -c . "$TMP/led.jsonl")" = 1 ]'
check "the recorded row validates" 'python3 "$EVR" validate "$TMP/led.jsonl" >/dev/null'
check "the live ledger was never touched" '[ ! -e "$TMP/never-eval.jsonl" ]'

echo "test-pdd-share: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
