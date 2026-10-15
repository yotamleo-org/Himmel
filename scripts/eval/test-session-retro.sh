#!/usr/bin/env bash
# scripts/eval/test-session-retro.sh - hermetic suite for session-retro.py.
# Fixture rows are real leg-failures rows (scripts/eval/fixtures/session-retro-ledger.jsonl).
# Never ~/.himmel. No model call, no bank.
#  1. classes rank by distinct sessions, then count, and name example legs;
#  2. --days/--now bound the window by row ts (rows before the cutoff drop out);
#  3. trajectory metrics (traj/*) are not stalls and are excluded unless asked for;
#  4. --top caps the list; the ledger is read-only; a missing ledger exits 2.
#
# check() evals its condition, so the single quotes are deliberate.
# shellcheck disable=SC2016,SC2034
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SR="$HERE/session-retro.py"
FX="$HERE/fixtures/session-retro-ledger.jsonl"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/session-retro-test.XXXXXX")" || { echo "test-session-retro: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
sr() { python3 "$SR" --ledger "$FX" "$@"; }

echo "1. ranking and example legs"
sr --now 2026-10-09T00:00:00Z >"$TMP/all.out" 2>"$TMP/all.err"; rc=$?
check "exits 0" '[ "$rc" = 0 ]'
check "the most-recurring class is first, with 3 sessions, 9 occurrences" 'sed -n 2p "$TMP/all.out" | grep -qE "^1[[:space:]]+3[[:space:]]+9[[:space:]]+denied/guard-pr-check-literal"'
check "example legs are named" 'sed -n 2p "$TMP/all.out" | grep -q "N1375"'
check "ties on sessions break on count (quiet-run 2 sessions / 4 before single-session classes)" 'sed -n 3p "$TMP/all.out" | grep -qE "denied/require-quiet-run"'

echo "2. window"
sr --now 2026-10-14T01:20:00Z >"$TMP/win.out" 2>&1
check "rows before the cutoff drop out (guard-pr-check-literal falls to 1 session)" 'grep -qE "^[0-9]+[[:space:]]+1[[:space:]]+4[[:space:]]+denied/guard-pr-check-literal" "$TMP/win.out"'
sr --now 2026-10-14T01:20:00Z --days 30 >"$TMP/wide.out" 2>&1
check "control: a wider window brings them back" 'grep -qE "^1[[:space:]]+3[[:space:]]+9[[:space:]]+denied/guard-pr-check-literal" "$TMP/wide.out"'

echo "3. trajectory metrics"
check "traj/* is absent by default" '! grep -q "traj/" "$TMP/all.out"'
sr --now 2026-10-09T00:00:00Z --include-traj >"$TMP/traj.out" 2>&1
check "control: --include-traj lists it" 'grep -q "traj/red-before-green" "$TMP/traj.out"'

echo "4. cap, read-only, missing ledger"
sr --now 2026-10-09T00:00:00Z --top 1 >"$TMP/top1.out" 2>&1
check "--top 1 prints one class row after the header" '[ "$(grep -c "^[0-9]" "$TMP/top1.out")" = 1 ]'
digest() { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"; }
BEFORE="$(digest "$FX")"
sr --now 2026-10-09T00:00:00Z >/dev/null 2>&1
AFTER="$(digest "$FX")"
check "the ledger is unchanged" '[ -n "$BEFORE" ] && [ "$AFTER" = "$BEFORE" ]'
printf '%s\n' '{"ts":null,"session":"s","class":"c","count":1}' '{"ts":"2026-10-08T00:00:00","session":"s","class":"c","count":1}' '{"ts":"2026-10-08T00:00:00Z","session":null,"class":["x"],"count":1}' >"$TMP/bad.jsonl"
python3 "$SR" --ledger "$TMP/bad.jsonl" --now 2026-10-09T00:00:00Z >"$TMP/bad.out" 2>&1; brc=$?
check "a null or timezone-less ts is skipped or read, never a crash" '[ "$brc" = 0 ] && grep -q "skipped=2" "$TMP/bad.out" && grep -q "rows=1 " "$TMP/bad.out"'
python3 "$SR" --ledger "$TMP/none.jsonl" >"$TMP/miss.out" 2>&1; mrc=$?
check "a missing ledger exits 2 with a message" '[ "$mrc" = 2 ] && grep -q "cannot read" "$TMP/miss.out"'

printf '%s\n' '{"ts":"2026-10-08T00:00:00Z","session":"s","class":"c","leg":{"x":1},"count":1}' >"$TMP/leg.jsonl"
python3 "$SR" --ledger "$TMP/leg.jsonl" --now 2026-10-09T00:00:00Z >"$TMP/leg.out" 2>&1; lrc=$?
check "a non-string leg is skipped, not a crash" '[ "$lrc" = 0 ] && grep -q "skipped=1" "$TMP/leg.out"'
python3 "$SR" --ledger "$FX" --now not-a-date >"$TMP/now.out" 2>&1; nrc=$?
check "an invalid --now is a usage error (exit 2)" '[ "$nrc" = 2 ]'
python3 "$SR" --ledger "$FX" --top -1 >"$TMP/neg.out" 2>&1; trc=$?
check "a non-positive --top is a usage error (exit 2)" '[ "$trc" = 2 ]'

printf '%s\n' '{"ts":"2026-10-08T00:00:00Z","session":"s","class":"c","leg":"N1","count":1}' '{"ts":"2026-10-08T00:00:01Z","session":"s","class":"c","leg":"N2","count":10}' >"$TMP/legs.jsonl"
python3 "$SR" --ledger "$TMP/legs.jsonl" --now 2026-10-09T00:00:00Z >"$TMP/legs.out" 2>&1
check "example legs rank by leg occurrences within one session" 'grep -qE "c[[:space:]]+N2,N1$" "$TMP/legs.out"'
python3 "$SR" --ledger "$TMP/legs.jsonl" --now 2026-10-09T02:00:00+02:00 >"$TMP/off.out" 2>&1
check "an offset --now is shown as the UTC instant" 'grep -q ".. 2026-10-09T00:00Z" "$TMP/off.out"'
python3 "$SR" --ledger "$FX" --days -1 >"$TMP/days.out" 2>&1; drc=$?
check "a non-positive --days is a usage error (exit 2)" '[ "$drc" = 2 ]'

echo "test-session-retro: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
