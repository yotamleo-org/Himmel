#!/usr/bin/env bash
# scripts/eval/test-profile-openings.sh - hermetic suite for profile-openings.py.
# Fixture launch logs and transcripts under a scratch dir; never ~/.claude or ~/.himmel. No model call.
#  1. a launch joins its transcript by session_id, else by session name, and sizes the first real request;
#  2. launches outside the window, profile=none, composed lists and disagreeing duplicates are left out;
#  3. n of 3 or more gives the median rounded up to 1000; fewer gives no budget;
#  4. --record appends one valid eval-runs row per profile; without it nothing is written.
#
# check() evals its condition, so the single quotes are deliberate.
# shellcheck disable=SC2016,SC2034
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
RD="$HERE/profile-openings.py"
EVR="$HERE/lib/eval_runs.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/profile-openings-test.XXXXXX")" || { echo "test-profile-openings: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export HIMMEL_EVAL_RUNS_LEDGER="$TMP/never-eval.jsonl"
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

LOGS="$TMP/logs"; PROJ="$TMP/projects/-fx"; mkdir -p "$LOGS" "$PROJ"
NOW=2026-10-25T12:00:00Z
IN=2026-10-24T10:00:00Z
OUT=2026-09-01T10:00:00Z

# asst <input> <creation> <read> [model] [sidechain]: one assistant transcript line stamped $TS
TS=2026-10-24T10:05:00.123Z
asst() { printf '{"type":"assistant","isSidechain":%s,"timestamp":"%s","message":{"model":"%s","usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s,"output_tokens":9}}}\n' "${5:-false}" "$TS" "${4:-claude-x}" "$1" "$2" "$3"; }
# transcript <uuid> <title> <input> <creation> <read>: title row, a user row, then the first request, then a bigger one
transcript() {
  { printf '{"type":"custom-title","customTitle":"%s","sessionId":"%s"}\n{"type":"user","message":{"content":"hi"}}\n' "$2" "$1"
    asst "$3" "$4" "$5"; asst 1 1 900000; } >"$PROJ/$1.jsonl"
}
# launch <name> <profile> <launched> [session_id]: one launch line
launch() { printf 'headed-arm-leg: profile=%s lane=native model=m role=leg session=%s%s launched=%s\n' "$2" "$1" "${4:+ session_id=$4}" "$3" >>"$LOGS/$1.log"; }

U1=aaaaaaaa-0000-4000-8000-000000000001
U2=aaaaaaaa-0000-4000-8000-000000000002
U3=aaaaaaaa-0000-4000-8000-000000000003
U4=aaaaaaaa-0000-4000-8000-000000000004
U5=aaaaaaaa-0000-4000-8000-000000000005
U6=aaaaaaaa-0000-4000-8000-000000000006
U7=aaaaaaaa-0000-4000-8000-000000000007
U8=aaaaaaaa-0000-4000-8000-000000000008
U9=aaaaaaaa-0000-4000-8000-000000000009

# three leg-impl: one by id (10+20000+30000 = 50010), two by name (60000 and 52001): median 52001, max 60000
transcript $U1 other-title 10 20000 30000;  launch leg-a leg-impl $IN $U1
transcript $U2 leg-b 100 9900 50000;        launch leg-b leg-impl $IN
transcript $U3 leg-c 2001 0 50000;          launch leg-c leg-impl $IN
# the first assistant row is synthetic (zero usage) and a sidechain row: the real first request is 40000
{ printf '{"type":"custom-title","customTitle":"leg-d","sessionId":"%s"}\n' $U4
  asst 0 0 0 "<synthetic>"; asst 77777 0 0 claude-x true; asst 40000 0 0; } >"$PROJ/$U4.jsonl"; launch leg-d lane-impl $IN
# n of 2 only
transcript $U5 leg-e 1000 0 30000; launch leg-e lane-review $IN
transcript $U6 leg-f 1000 0 31000; launch leg-f lane-review $IN
# left out: profile=none, composed list, outside the window, disagreeing duplicate lines
transcript $U7 leg-g 5 5 5;  launch leg-g none $IN
transcript $U8 leg-h 5 5 5;  launch leg-h design,design-motion $IN
transcript $U9 leg-i 5 5 5;  launch leg-i leg-impl $OUT
transcript aaaaaaaa-0000-4000-8000-00000000000a leg-j 5 5 5; launch leg-j leg-impl $IN; launch leg-j judge $IN
# a launch with no transcript
launch leg-k leg-impl $IN
# an older same-name transcript (first request before the launch), still modified inside the window: not counted
TS=2026-10-20T08:00:00.000Z transcript aaaaaaaa-0000-4000-8000-00000000000c leg-m 888888 0 0; launch leg-m leg-impl $IN
# a launch that recorded a session_id whose transcript is missing, beside an older same-name transcript: not borrowed
transcript aaaaaaaa-0000-4000-8000-00000000000b leg-l 999999 0 0; launch leg-l leg-impl $IN aaaaaaaa-0000-4000-8000-0000000000ff

J="$TMP/out.json"
python3 -I "$RD" --launch-logs "$LOGS" --projects "$TMP/projects" --now $NOW --json >"$J" 2>"$TMP/err" || bad "the reader exits 0: $(head -c 300 "$TMP/err")"

echo "1. the join and the opening size"
check "leg-impl has n 3: by id, by name, by name" '[ "$(jq -r ".[] | select(.profile==\"leg-impl\") | .n" "$J")" = 3 ]'
check "the opening is input + creation + read of the first request, not the later one" '[ "$(jq -r ".[] | select(.profile==\"leg-impl\") | .min" "$J")" = 50010 ]'
check "a recorded session_id with no transcript does not fall back to a same-name transcript" '[ "$(jq -r ".[] | select(.profile==\"leg-impl\") | .n" "$J")" = 3 ] && [ "$(jq -r ".[] | select(.profile==\"leg-impl\") | .max" "$J")" != 999999 ]'
check "a same-name transcript that opened before the launch is not counted" '[ "$(jq -r ".[] | select(.profile==\"leg-impl\") | .n" "$J")" = 3 ] && [ "$(jq -r ".[] | select(.profile==\"leg-impl\") | .max" "$J")" != 888888 ]'
check "a synthetic and a sidechain row are skipped" '[ "$(jq -r ".[] | select(.profile==\"lane-impl\") | .median" "$J")" = 40000 ]'

echo "2. what is left out"
check "no none, composed or out-of-window profile row" '[ "$(jq -r "[.[].profile] | sort | join(\",\")" "$J")" = "lane-impl,lane-review,leg-impl" ]'
check "the out-of-window, none, composed and disagreeing launches add nothing to leg-impl" '[ "$(jq -r ".[] | select(.profile==\"leg-impl\") | .max" "$J")" = 60000 ]'

echo "3. the budget"
check "n of 3: the median 52001 rounds up to 53000" '[ "$(jq -r ".[] | select(.profile==\"leg-impl\") | .median" "$J")" = 52001 ] && [ "$(jq -r ".[] | select(.profile==\"leg-impl\") | .budget" "$J")" = 53000 ]'
check "n of 2: no budget" '[ "$(jq -r ".[] | select(.profile==\"lane-review\") | .budget" "$J")" = null ] && [ "$(jq -r ".[] | select(.profile==\"lane-review\") | .n" "$J")" = 2 ]'
check "--min-n 1 gives the 1-sample profile a budget rounded up to 1000" '[ "$(python3 -I "$RD" --launch-logs "$LOGS" --projects "$TMP/projects" --now $NOW --min-n 1 --json | jq -r ".[] | select(.profile==\"lane-impl\") | .budget")" = 40000 ]'
check "the text table names keep for n under the minimum" 'python3 -I "$RD" --launch-logs "$LOGS" --projects "$TMP/projects" --now $NOW | grep -q "lane-review.*keep (n<3)"'

echo "4. --record"
check "no ledger without --record" '[ ! -e "$HIMMEL_EVAL_RUNS_LEDGER" ]'
python3 -I "$RD" --launch-logs "$LOGS" --projects "$TMP/projects" --now $NOW --record >/dev/null 2>&1 || bad "--record exits 0"
check "one row per profile" '[ "$(grep -c . "$HIMMEL_EVAL_RUNS_LEDGER")" = 3 ]'
check "the ledger validates" 'python3 "$EVR" validate "$HIMMEL_EVAL_RUNS_LEDGER" >/dev/null'
check "the leg-impl row carries the median and n" 'jq -e "select(.eval==\"profile-opening\" and .config.profile==\"leg-impl\") | .n == 3 and .metrics.median_tokens == 52001 and .metrics.budget_tokens == 53000 and .status == \"ok\"" "$HIMMEL_EVAL_RUNS_LEDGER" >/dev/null'

echo "profile-openings: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
