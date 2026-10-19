#!/usr/bin/env bash
# Smoke test for scripts/ci/shell-extended-nightly-issue.sh.
# Uses DRY_RUN=1 so no gh, no auth, no network — asserts the issue-state
# decisions per shell-unit outcome from the emitted DRY: gh command lines.
set -uo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline (this file runs under `set -o pipefail`, where a
# pipe into `grep -q` can report a successful match as failed via SIGPIPE).
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/ci/shell-extended-nightly-issue.sh"
fails=0
ok() { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

has()   { if grepq "$2" "$1"; then ok "$3"; else bad "$3; out: $2"; fi; }
hasnt() { if grepq "$2" "$1"; then bad "$3; out: $2"; else ok "$3"; fi; }

RUN_URL="https://github.com/yotamleo/Himmel/actions/runs/0"

# 1. Syntax.
if bash -n "$SCRIPT"; then ok "syntax (bash -n)"; else bad "syntax"; fi

# 2. Bad args -> usage exit 2.
bash "$SCRIPT" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then ok "no args -> exit 2"; else bad "no args exit=$rc (expected 2)"; fi

# 3. Red (rc=1), no existing issue -> create (never edit/close).
out="$(DRY_RUN=1 DRY_RUN_OPEN_ISSUE="" bash "$SCRIPT" 1 "$RUN_URL" 2>&1)"
has 'DRY: gh issue create' "$out" "red/no-issue -> creates"
has 'DRY: gh label create' "$out" "red ensures marker label exists"
hasnt 'gh issue edit' "$out" "red/no-issue does not edit"
hasnt 'gh issue close' "$out" "red never closes"

# 4. Red, existing issue #7 -> edit + comment, never create.
out="$(DRY_RUN=1 DRY_RUN_OPEN_ISSUE="7" bash "$SCRIPT" 1 "$RUN_URL" 2>&1)"
has 'DRY: gh issue edit 7' "$out" "red/existing -> edits #7 (refresh in place)"
has 'DRY: gh issue comment 7' "$out" "red/existing -> adds still-red comment"
hasnt 'gh issue create' "$out" "red/existing never creates a duplicate"

# 5. Green (rc=0), existing issue #7 -> comment + close.
out="$(DRY_RUN=1 DRY_RUN_OPEN_ISSUE="7" bash "$SCRIPT" 0 "$RUN_URL" 2>&1)"
has 'DRY: gh issue close 7' "$out" "green/existing -> closes #7"
hasnt 'gh issue create' "$out" "green never creates"

# 6. Green, no existing issue -> nothing.
out="$(DRY_RUN=1 DRY_RUN_OPEN_ISSUE="" bash "$SCRIPT" 0 "$RUN_URL" 2>&1)"
hasnt 'DRY: gh issue ' "$out" "green/no-issue -> no gh issue mutation"

# 7. Lookup failure (gh issue list errored) must NOT be treated as "no issue".
out="$(DRY_RUN=1 DRY_RUN_LOOKUP_FAIL=1 bash "$SCRIPT" 1 "$RUN_URL" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ]; then ok "red + lookup-failure -> exit 1 (bail)"; else bad "red + lookup-failure exit=$rc (expected 1)"; fi
hasnt 'DRY: gh issue create' "$out" "red + lookup-failure never creates (no duplicate)"
out="$(DRY_RUN=1 DRY_RUN_LOOKUP_FAIL=1 bash "$SCRIPT" 0 "$RUN_URL" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ]; then ok "green + lookup-failure -> exit 1 (propagate)"; else bad "green + lookup-failure exit=$rc (expected 1)"; fi
hasnt 'DRY: gh issue close' "$out" "green + lookup-failure never closes blindly"

# 8. Classify the red before filing. Fixtures are the real API payloads of
# schedule run 39029239710 (shard 4 cancelled, none failed) and the schedule
# run list that held a newer green nightly.
FX="$ROOT/scripts/ci/fixtures/nightly-reporter"
JOBS_CANCELLED="$FX/jobs-cancelled-shard.json"
RUNS="$FX/runs-newer-green.json"
JOBS_FAILED="$(mktemp "${TMPDIR:-/tmp}/nightly-jobs-failed.XXXXXX")" || exit 1
sed 's/"cancelled"/"failure"/' "$JOBS_CANCELLED" > "$JOBS_FAILED" || exit 1
JOBS_TIMEDOUT="$(mktemp "${TMPDIR:-/tmp}/nightly-jobs-timedout.XXXXXX")" || exit 1
sed '0,/"success"/s/"success"/"timed_out"/' "$JOBS_CANCELLED" > "$JOBS_TIMEDOUT" || exit 1
OLD_RUN="2026-10-17T11:34:47Z"
NEWEST_RUN="2026-10-19T01:00:00Z"

# cancelled-only shards, no existing issue -> no issue opened
out="$(DRY_RUN=1 DRY_RUN_OPEN_ISSUE="" DRY_RUN_JOBS_FILE="$JOBS_CANCELLED" DRY_RUN_RUNS_FILE="$RUNS" DRY_RUN_CREATED_AT="$NEWEST_RUN" bash "$SCRIPT" 1 "$RUN_URL" 2>&1)"; rc=$?
hasnt 'DRY: gh issue ' "$out" "cancelled-only shards open no issue"
hasnt 'DRY: gh label create' "$out" "cancelled-only shards touch no label"
has 'inconclusive' "$out" "cancelled-only shards log an inconclusive note"
if [ "$rc" -eq 0 ]; then ok "cancelled-only shards -> exit 0"; else bad "cancelled-only exit=$rc (expected 0)"; fi

# cancelled-only shards, issue already open -> not refreshed
out="$(DRY_RUN=1 DRY_RUN_OPEN_ISSUE="7" DRY_RUN_JOBS_FILE="$JOBS_CANCELLED" DRY_RUN_RUNS_FILE="$RUNS" DRY_RUN_CREATED_AT="$NEWEST_RUN" bash "$SCRIPT" 1 "$RUN_URL" 2>&1)"
hasnt 'DRY: gh issue ' "$out" "cancelled-only shards do not refresh an open issue"

# a failed shard on the newest run stays red
out="$(DRY_RUN=1 DRY_RUN_OPEN_ISSUE="" DRY_RUN_JOBS_FILE="$JOBS_FAILED" DRY_RUN_RUNS_FILE="$RUNS" DRY_RUN_CREATED_AT="$NEWEST_RUN" bash "$SCRIPT" 1 "$RUN_URL" 2>&1)"
has 'DRY: gh issue create' "$out" "failed shard on the newest run still opens the issue"

# older run finishing after a newer green nightly -> no red
out="$(DRY_RUN=1 DRY_RUN_OPEN_ISSUE="" DRY_RUN_JOBS_FILE="$JOBS_FAILED" DRY_RUN_RUNS_FILE="$RUNS" DRY_RUN_CREATED_AT="$OLD_RUN" bash "$SCRIPT" 1 "$RUN_URL" 2>&1)"; rc=$?
hasnt 'DRY: gh issue ' "$out" "red superseded by a newer green nightly opens no issue"
has 'superseded' "$out" "superseded red logs a note"
if [ "$rc" -eq 0 ]; then ok "superseded red -> exit 0"; else bad "superseded exit=$rc (expected 0)"; fi
# a timed-out shard beside a cancelled one is a real red, not inconclusive
out="$(DRY_RUN=1 DRY_RUN_OPEN_ISSUE="" DRY_RUN_JOBS_FILE="$JOBS_TIMEDOUT" DRY_RUN_RUNS_FILE="$RUNS" DRY_RUN_CREATED_AT="$NEWEST_RUN" bash "$SCRIPT" 1 "$RUN_URL" 2>&1)"
has 'DRY: gh issue create' "$out" "timed-out shard plus cancelled shard still opens the issue"
rm -f "$JOBS_FAILED" "$JOBS_TIMEDOUT"

echo ""
if [ "$fails" -ne 0 ]; then echo "$fails check(s) failed."; exit 1; fi
echo "all checks passed."
