#!/usr/bin/env bash
# test-model-replay.sh — hermetic coverage for scripts/vm/lib/model-replay.sh.
# A fake "model" (a counter-bumping command) stands in for the live call, so no
# bank is spent: the cases prove the second run makes zero model calls and that
# a changed input, a tampered recording or replay-only with no recording each
# do the right thing.
#
# Usage: bash scripts/vm/test-model-replay.sh
# shellcheck disable=SC2329  # the fake models are invoked indirectly by replay_run
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/scripts/vm/lib/model-replay.sh"
[ -f "$LIB" ] || { echo "FAIL: $LIB not found" >&2; exit 1; }
# shellcheck source=lib/model-replay.sh
. "$LIB"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/test-model-replay.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

FAILED=0
pass() { echo "PASS $1"; }
fail_case() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

CACHE="$WORK/cache"
CALLS="$WORK/calls"
ART="$WORK/out/artifact.txt"
PROMPT="$WORK/prompt.txt"
: > "$CALLS"
printf 'write OK\n' > "$PROMPT"

# The fake model: one line per call, writes the artifact.
fake_model() { echo x >> "$CALLS"; mkdir -p "$(dirname "$ART")"; printf 'OK\n' > "$ART"; }
calls() { wc -l < "$CALLS" | tr -d ' '; }

KEY1="$(replay_key haiku "$PROMPT")"

# --- T1: first run records (one model call) ---------------------------------
replay_run "$CACHE" "$KEY1" "$ART" -- fake_model
if [ "$REPLAY_MODE_USED" = record ] && [ "$(calls)" = 1 ] && [ "$(cat "$ART")" = OK ]; then pass "T1 first run records with one model call"; else fail_case "T1 mode=$REPLAY_MODE_USED calls=$(calls)"; fi

# --- T2: second run replays, zero model calls, artifact restored ------------
rm -f "$ART"
replay_run "$CACHE" "$KEY1" "$ART" -- fake_model
if [ "$REPLAY_MODE_USED" = replay ] && [ "$(calls)" = 1 ] && [ "$(cat "$ART")" = OK ]; then pass "T2 second run replays with no model call"; else fail_case "T2 mode=$REPLAY_MODE_USED calls=$(calls)"; fi

# --- T3: a changed prompt changes the key and re-records --------------------
printf 'write OK twice\n' > "$PROMPT"
KEY2="$(replay_key haiku "$PROMPT")"
replay_run "$CACHE" "$KEY2" "$ART" -- fake_model
if [ "$KEY1" != "$KEY2" ] && [ "$REPLAY_MODE_USED" = record ] && [ "$(calls)" = 2 ]; then pass "T3 changed input re-records"; else fail_case "T3 keys-equal=$([ "$KEY1" = "$KEY2" ] && echo yes || echo no) mode=$REPLAY_MODE_USED calls=$(calls)"; fi

# --- T4: a different model changes the key ----------------------------------
if [ "$(replay_key opus "$PROMPT")" != "$KEY2" ]; then pass "T4 model is part of the key"; else fail_case "T4 model not in key"; fi

# --- T5: a tampered recording is not replayed -------------------------------
printf 'TAMPERED\n' > "$CACHE/$KEY2/artifact"
replay_run "$CACHE" "$KEY2" "$ART" -- fake_model
if [ "$REPLAY_MODE_USED" = record ] && [ "$(calls)" = 3 ] && [ "$(cat "$ART")" = OK ]; then pass "T5 tampered recording re-records"; else fail_case "T5 mode=$REPLAY_MODE_USED calls=$(calls)"; fi

# --- T6: replay-only with no recording refuses and spends nothing -----------
KEY3="$(replay_key haiku "$PROMPT" "$WORK/cache/$KEY2/artifact")"
HIMMEL_REPLAY_MODE=replay-only replay_run "$CACHE" "$KEY3" "$ART" -- fake_model
rc=$?
if [ "$rc" = 4 ] && [ "$(calls)" = 3 ]; then pass "T6 replay-only without a recording refuses (rc 4), no call"; else fail_case "T6 rc=$rc calls=$(calls)"; fi

# --- T7: a failing model command records nothing ----------------------------
KEY4="$(replay_key haiku "$PROMPT" "$PROMPT")"
bad_model() { echo x >> "$CALLS"; return 7; }
replay_run "$CACHE" "$KEY4" "$ART" -- bad_model
rc=$?
if [ "$rc" = 7 ] && [ ! -e "$CACHE/$KEY4/artifact.sha256" ]; then pass "T7 failed model run is not recorded"; else fail_case "T7 rc=$rc"; fi

# --- T8: a model run that writes no artifact is not recorded ----------------
KEY5="$(replay_key haiku "$PROMPT" "$PROMPT" "$PROMPT")"
silent_model() { echo x >> "$CALLS"; rm -f "$ART"; }
replay_run "$CACHE" "$KEY5" "$ART" -- silent_model
rc=$?
if [ "$rc" = 5 ] && [ ! -e "$CACHE/$KEY5/artifact.sha256" ]; then pass "T8 missing artifact is not recorded (rc 5)"; else fail_case "T8 rc=$rc"; fi

# --- T9: replay_key refuses a missing input file ----------------------------
replay_key haiku "$WORK/nope" >/dev/null 2>&1
if [ "$?" = 2 ]; then pass "T9 missing key input refuses (rc 2)"; else fail_case "T9 missing input accepted"; fi

# --- T10: replay_valid agrees with replay_run (valid, then tampered) -------
replay_valid "$CACHE" "$KEY2" || fail_case "T10 a fresh recording reads invalid"
printf 'TAMPERED\n' > "$CACHE/$KEY2/artifact"
if replay_valid "$CACHE" "$KEY2"; then fail_case "T10 a tampered recording reads valid"; else pass "T10 replay_valid rejects a tampered recording"; fi

echo
if [ "$FAILED" -eq 0 ]; then echo "test-model-replay: ALL PASS"; exit 0; fi
echo "test-model-replay: $FAILED FAILED" >&2
exit 1
