#!/usr/bin/env bash
# scripts/eval/test-ci-metrics.sh - suite for scripts/eval/ci-metrics.sh
# No live API: fixtures/ci-metrics/ is a recording of the real
# yotamleo/Himmel data (runs list + GraphQL checkRuns + the REST step count of
# cancelled jobs, as the script fetches it, trimmed to the fields it reads),
# taken 2026-10-14 17:24Z. It holds every run of one PR branch (CI runs cancelled
# by newer pushes, a green CI run, title-lint and review-gate runs) plus one
# cancelled scheduled CI run with no newer sibling. Fixture clock:
# --now 2026-10-14T12:00:00Z --days 3.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/ci-metrics.sh"
FIX="$HERE/fixtures/ci-metrics"
NOW="2026-10-14T12:00:00Z"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ci-metrics-test.XXXXXX")" || { echo "test-ci-metrics: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) pass "$1";; *) fail "$1: '$3' not in '$2'";; esac; }

OUT=$(bash "$SCRIPT" --data-dir "$FIX" --days 3 --now "$NOW" 2>&1); RC=$?
eq "fixture run: exit code" "$RC" "0"

# Totals below were summed from the fixture JSON with a separate jq program.
has "headline: runs" "$OUT" "| runs | 19 |"
has "headline: jobs" "$OUT" "| jobs | 173 |"
has "headline: cancelled runs" "$OUT" "| cancelled runs | 5 |"
has "headline: runner-min total" "$OUT" "| runner-min total | 550.5 |"
# 89 cancelled jobs report a start time but never got a runner (0 steps): they
# must not count as runner time, queue wait or concurrency.
has "headline: jobs cancelled before a runner" "$OUT" "| jobs cancelled before a runner took them | 89 |"
has "headline: runner-min burned by cancelled runs" "$OUT" "| runner-min in cancelled runs | 277.2 |"
# Counting the never-ran jobs as running puts this at 40+; the real figure is 8.
has "headline: peak concurrent in_progress jobs" "$OUT" "| peak concurrent in_progress jobs | 8 |"
has "headline: no hour reaches the 20-runner cap" "$OUT" "| hours with peak >= 20 / >= 40 | 0 / 0 of 29 |"

has "cause: four CI runs superseded by newer pushes" "$OUT" "| superseded | 4 | 0.7 |"
has "cause: the scheduled run has no newer run" "$OUT" "| no newer run (manual or other) | 1 | 276.5 |"

has "per-workflow table lists CI" "$OUT" "| CI | 5 | 160 |"
has "per-trigger table lists pull_request" "$OUT" "| pull_request | 14 | 137 |"
has "per-job table lists the shard job" "$OUT" "| shell-unit-shard (ubuntu-latest, 6) | 5 | 5 |"

has "jobs per push: distinct pull_request pushes" "$OUT" "| pull_request pushes (distinct head sha) | 4 |"
has "jobs per push: max" "$OUT" "| jobs per push max | 36 |"
has "peak table: busiest hour" "$OUT" "| 2026-10-13T05:00:00Z | 8 |"

# Cancel cause is inferred from the run set: keep only runs created up to the
# last cancelled pull_request run and nothing supersedes it any more.
LAST=$(jq -r '[.[] | select(.conclusion == "cancelled" and .event == "pull_request") | .created_at] | max' "$FIX/runs.json")
jq --arg c "$LAST" '[.[] | select(.created_at <= $c)]' "$FIX/runs.json" > "$TMP/runs.json"
cp "$FIX/jobs.json" "$TMP/jobs.json"
OUT2=$(bash "$SCRIPT" --data-dir "$TMP" --days 3 --now "$NOW" 2>&1)
has "cause: newest cancelled PR run is no-newer-run" "$OUT2" "| no newer run (manual or other) | 1 | 0.4 |"
has "cause: earlier cancelled PR runs stay superseded" "$OUT2" "| superseded | 3 | 0.3 |"

bash "$SCRIPT" --data-dir "$TMP" --days nope >/dev/null 2>&1; eq "bad --days exits 2" "$?" "2"
bash "$SCRIPT" --bogus >/dev/null 2>&1; eq "unknown flag exits 2" "$?" "2"
bash "$SCRIPT" --data-dir "$TMP/missing" --days 1 >/dev/null 2>&1; eq "--data-dir without runs.json and jobs.json exits 2" "$?" "2"

echo "ci-metrics: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
