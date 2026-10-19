#!/usr/bin/env bash
# scripts/eval/test-handover-cost.sh - hermetic suite for handover-cost.py.
# Fixture: scripts/eval/fixtures/handover-cost/ (two consoles P -> S, a new and an old leg),
# every turn costs 250 (100 input + 1000 cache_read x 0.1 + 10 output x 5). No model call, no bank.
#  1. the P -> S pair prints a known turn count and cost per piece (prep, relay, action zero, leg);
#  2. net counts only the turns that touch the handover scripts, gross counts them all;
#  3. --legs-after drops legs launched before the cutoff (F-L9);
#  4. a repeated message id is one turn; an empty or missing dir exits 2.
#
# check() evals its condition, so the single quotes are deliberate.
# shellcheck disable=SC2016,SC2034
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
HC="$HERE/handover-cost.py"
FX="$HERE/fixtures/handover-cost"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/handover-cost-test.XXXXXX")" || { echo "test-handover-cost: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
hc() { python3 "$HC" --dir "$FX" "$@"; }
row() { grep -E "^HANDOVER " "$1" | head -1; }

echo "1. per-piece counts, legs launched after 09:30"
hc --legs-after 2026-10-19T09:30:00Z >"$TMP/a.out" 2>"$TMP/a.err"; rc=$?
check "exits 0" '[ "$rc" = 0 ]'
check "names the pair" 'row "$TMP/a.out" | grep -q "HIMMEL-nextleg-2026-10-19A-roadmap-console->HIMMEL-nextleg-2026-10-19B-roadmap-console"'
check "prep is 2 turns, 500" 'row "$TMP/a.out" | grep -q " prep=2/500 "'
check "relay+wrap is 3 turns, 750 (the repeated message id counts once)" 'row "$TMP/a.out" | grep -q " relay=3/750 "'
check "action zero is 4 turns, 1000 (the turn after the predecessor wrapped is out)" 'row "$TMP/a.out" | grep -q " az=4/1000 "'
check "leg relay is 2 turns, 500 from the one leg" 'row "$TMP/a.out" | grep -q " leg=2/500 legs=1 "'
check "gross is 2750" 'row "$TMP/a.out" | grep -q " gross=2750 "'

echo "2. net"
check "net is 2000 (only the handover-script turns)" 'row "$TMP/a.out" | grep -q " net=2000$"'
check "the MEAN line repeats the single pair" 'grep -qE "^MEAN n=1 .* gross=2750 net=2000$" "$TMP/a.out"'

echo "3. leg cutoff"
hc >"$TMP/b.out" 2>&1
check "control: with no cutoff the old leg counts too (5 turns, 2 legs)" 'row "$TMP/b.out" | grep -q " leg=5/1250 legs=2 "'
check "with the cutoff the old leg is reported skipped" 'grep -q "legs_skipped_before_cutoff=1" "$TMP/a.out"'

echo "4. errors"
mkdir "$TMP/empty"
python3 "$HC" --dir "$TMP/empty" >"$TMP/e.out" 2>&1; erc=$?
check "a dir with no console exits 2 with a message" '[ "$erc" = 2 ] && grep -q "fewer than two consoles" "$TMP/e.out"'
python3 "$HC" --dir "$TMP/none" >"$TMP/m.out" 2>&1; mrc=$?
check "a missing dir exits 2" '[ "$mrc" = 2 ]'
python3 "$HC" --dir "$FX" --legs-after not-a-date >"$TMP/d.out" 2>&1; drc=$?
check "an invalid --legs-after is a usage error (exit 2)" '[ "$drc" = 2 ]'

echo "handover-cost: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
