#!/usr/bin/env bash
# scripts/eval/test-chief-wake-classes.sh - hermetic suite for chief-wake-classes.py.
# Fixture: scripts/eval/fixtures/chief-wake-classes/ - one chief of 2026-10-19 (letter A) with five wakes,
# a second chief (B) that --exclude drops, and a non-chief title that is ignored. Every request costs 250
# (100 input + 1000 cache_read x 0.1 + 10 output x 5). Known wakes:
#   operator text (1 request) | worker READY + go.sh (2 requests, escalate) | worker LIVE (1, relay-only)
#   bg leg-event.sh notification (1, relay-only) | console-wait.sh notification, WAKE tick + Agent (3, escalate;
#   the repeated message id counts once).
# No model call, no bank.
#  1. class rows print the known wake, request and eq counts;
#  2. kind rows print the known per-kind counts, the waiter kind read from its output file;
#  3. --exclude and the title match pick the consoles; no match exits 2.
#
# check() evals its condition, so the single quotes are deliberate.
# shellcheck disable=SC2016,SC2034
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
CW="$HERE/chief-wake-classes.py"
FX="$HERE/fixtures/chief-wake-classes"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/chief-wake-classes-test.XXXXXX")" || { echo "test-chief-wake-classes: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
cw() { WORKER_SESSION_BURN_W_INPUT=1 WORKER_SESSION_BURN_W_CACHE_READ=0.1 WORKER_SESSION_BURN_W_CACHE_CREATE=1.25 WORKER_SESSION_BURN_W_OUTPUT=5 python3 "$CW" --dir "$TMP/fx" "$@"; }

if ! { mkdir "$TMP/fx" && cp "$FX"/* "$TMP/fx/" && sed "s|@FX@|$TMP/fx|" "$FX/console-a.jsonl" >"$TMP/fx/console-a.jsonl"; }; then
  echo "test-chief-wake-classes: fixture copy failed" >&2; exit 1
fi

echo "1. class rows"
cw --date 2026-10-19 --exclude B >"$TMP/a.out" 2>"$TMP/a.err"; rc=$?
check "exits 0" '[ "$rc" = 0 ]'
check "one console, A" 'grep -qx "consoles=1 A" "$TMP/a.out"'
check "operator: 1 wake, 1 request, 250" 'grep -qx "CLASS operator wakes=1 pct_wakes=20.0 reqs=1 eq=250 pct_eq=12.5" "$TMP/a.out"'
check "machine-relay-only: 2 wakes, 2 requests, 500" 'grep -qx "CLASS machine-relay-only wakes=2 pct_wakes=40.0 reqs=2 eq=500 pct_eq=25.0" "$TMP/a.out"'
check "machine-escalate: 2 wakes, 5 requests, 1250" 'grep -qx "CLASS machine-escalate wakes=2 pct_wakes=40.0 reqs=5 eq=1250 pct_eq=62.5" "$TMP/a.out"'
check "escalate split: 3 judgement-or-think requests 750, 2 mechanical 500" 'grep -qx "CLASS esc-judgement-or-think wakes=0 pct_wakes=0.0 reqs=3 eq=750 pct_eq=37.5" "$TMP/a.out" && grep -qx "CLASS esc-mechanical wakes=0 pct_wakes=0.0 reqs=2 eq=500 pct_eq=25.0" "$TMP/a.out"'
check "ALL: 5 wakes, 8 requests, 2000" 'grep -qx "CLASS ALL wakes=5 pct_wakes=100.0 reqs=8 eq=2000 pct_eq=100.0" "$TMP/a.out"'

echo "2. kind rows"
check "waiter kind comes from the output file: waiter:tick, 3 requests, 750, escalate, mech 250" 'grep -qx "KIND waiter:tick wakes=1 reqs=3 eq=750 escalate=1 relay_eq=0 mech_eq=250" "$TMP/a.out"'
check "worker-READY: 2 requests, 500, escalate, mech 250" 'grep -qx "KIND worker-READY wakes=1 reqs=2 eq=500 escalate=1 relay_eq=0 mech_eq=250" "$TMP/a.out"'
check "bg:leg-event.sh is relay-only" 'grep -qx "KIND bg:leg-event.sh wakes=1 reqs=1 eq=250 escalate=0 relay_eq=250 mech_eq=0" "$TMP/a.out"'
check "worker-other is relay-only" 'grep -qx "KIND worker-other wakes=1 reqs=1 eq=250 escalate=0 relay_eq=250 mech_eq=0" "$TMP/a.out"'

echo "3. console selection"
cw --date 2026-10-19 >"$TMP/b.out" 2>&1
check "without --exclude both consoles count (B adds a wake)" 'grep -qx "consoles=2 A,B" "$TMP/b.out" && grep -q "^CLASS ALL wakes=6 " "$TMP/b.out"'
cw --date 2026-10-20 >"$TMP/c.out" 2>"$TMP/c.err"; rc=$?
check "no console on the date exits 2 with a message" '[ "$rc" = 2 ] && grep -q "no consoles" "$TMP/c.err"'
mkdir "$TMP/empty" && printf '%s\n' '{"type":"custom-title","customTitle":"HIMMEL-nextleg-2026-10-19Z-roadmap-console"}' >"$TMP/empty/z.jsonl"
python3 "$CW" --dir "$TMP/empty" --date 2026-10-19 >"$TMP/e.out" 2>"$TMP/e.err"; rc=$?
check "a console with no wakes prints zero rows, not a ZeroDivisionError" '[ "$rc" = 0 ] && grep -qx "CLASS ALL wakes=0 pct_wakes=0.0 reqs=0 eq=0 pct_eq=0.0" "$TMP/e.out"'
python3 "$CW" --dir "$TMP/nope" --date 2026-10-19 >"$TMP/d.out" 2>"$TMP/d.err"; rc=$?
check "an unreadable dir exits 2" '[ "$rc" = 2 ]'

echo
echo "chief-wake-classes: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
