#!/usr/bin/env bash
# test-check-operator-voice.sh — tests for scripts/lint/check-operator-voice.sh.
# Exit: 0 all passed, 1 any failed. bash 3.2-safe.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
LINT="$SELF_DIR/check-operator-voice.sh"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

if [ ! -f "$LINT" ]; then
    echo "FAIL: $LINT does not exist yet (RED)"
    exit 1
fi

T="$(mktemp -d "${TMPDIR:-/tmp}/operator-voice.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT

run() { OUT="$(bash "$LINT" "$@" 2>&1)"; RC=$?; }
has() { case "$OUT" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
put() { printf '%s\n' "$2" > "$T/$1"; }

put brief.md '# Chief reply style

6. Give time in concrete units ("about 15 min"), never "a bit of work".'
run "$T/brief.md"
if [ "$RC" -eq 1 ] && has "brief.md:3"; then pass "about 15 min -> 1 with file:line"; else fail "about 15 min exit $RC: $OUT"; fi

put poller.ts '    await reply("bouncing the poller, back in a moment");'
run "$T/poller.ts"
if [ "$RC" -eq 1 ] && has "poller.ts:1"; then pass "back in a moment -> 1"; else fail "back in a moment exit $RC: $OUT"; fi

put multi.ts '    await reply(
      "bouncing the poller, back in a moment",
    );
    const after = "back in a moment";'
run "$T/multi.ts"
if [ "$RC" -eq 1 ] && has "multi.ts:2" && ! has "multi.ts:4"; then pass "multiline send call -> 1, later line not scanned"; else fail "multiline exit $RC: $OUT"; fi

put paren.ts '    await reply(
      "done :)",
      "back in a moment",
    );'
run "$T/paren.ts"
if [ "$RC" -eq 1 ] && has "paren.ts:3"; then pass "a ) inside a string does not end the send call"; else fail "paren in string exit $RC: $OUT"; fi

for phrase in "The ask expires in 6 h; ready in 15 minutes" "ready in 15 minutes" "ETA for the fix: tonight" "the rerun will take a while" "I hand over shortly" "answer in a few minutes" "relaunch all 9, about 10 min" "Token, about 2 min: open the page"; do
    put one.md "$phrase"
    run "$T/one.md"
    if [ "$RC" -eq 1 ]; then pass "estimate -> 1: $phrase"; else fail "estimate not caught ($RC): $phrase"; fi
done

put measured.md 'The run took 50 min.
A file ask waited 30 min: a worker wants a file.
The suite ran for about 6 min on the station.
The ask expires in 6 h; send the code within 5 minutes.'
run "$T/measured.md"
if [ "$RC" -eq 0 ]; then pass "measured past duration -> 0"; else fail "measured exit $RC: $OUT"; fi

put comment.ts '// ~16h wedge seen once; the watchdog restarts it
const GAP_MS = 3000;'
run "$T/comment.ts"
if [ "$RC" -eq 0 ]; then pass "non-send .ts line -> 0"; else fail "comment exit $RC: $OUT"; fi

put rule.md '8. No time estimates: no "in about 15 min", no ETA, no "shortly".'
run "$T/rule.md"
if [ "$RC" -eq 0 ]; then pass "rule statement -> 0"; else fail "rule line exit $RC: $OUT"; fi

run "$T/absent.md"
if [ "$RC" -eq 2 ]; then pass "missing file -> 2"; else fail "missing file exit $RC: $OUT"; fi

OUT="$(bash "$LINT" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then pass "the real operator-bound set passes"; else fail "real set exit $RC: $OUT"; fi

echo "check-operator-voice: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
