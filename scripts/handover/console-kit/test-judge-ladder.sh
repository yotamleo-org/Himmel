#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2181  # A && B || C and $? checks are intentional in the pass/fail reporting lines
# test-judge-ladder.sh — judge-ladder.sh: tier order, the per-seat convening budget, and the
# break-glass finding classes. Every path is a fixture. JUDGE_LADDER overrides the script under
# test (the RED control: a missing script fails every row). bash 3.2-safe.
#
# Run: bash scripts/quiet-run.sh suite -- bash scripts/handover/console-kit/test-judge-ladder.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${JUDGE_LADDER:-$HERE/judge-ladder.sh}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3')" ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/judge-ladder-test.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
export JUDGE_LADDER_STATE="$WORK/state"
export JUDGE_LADDER_NOW=1000000
export JUDGE_LADDER_FABLE_CAP=1 JUDGE_LADDER_OPUS_CAP=2 JUDGE_LADDER_SONNET_CAP=3

run() { bash "$SUT" "$@" 2>&1; }

out="$(run next-tier sonnet)"; has "sonnet escalates to opus" "$out" "opus"
out="$(run next-tier opus)"; has "opus escalates to fable" "$out" "fable"
out="$(run next-tier fable)"; has "fable escalates to the operator" "$out" "operator"
run next-tier haiku >/dev/null; [ "$?" = 2 ] && pass "an unknown tier is refused (rc 2)" || fail "unknown tier not refused"

run convene seatA fable >/dev/null; [ "$?" = 0 ] && pass "first fable convening within cap is allowed" || fail "first fable refused"
out="$(run convene seatA fable)"; rc=$?
[ "$rc" = 3 ] && pass "second fable convening in the window is refused (rc 3)" || fail "fable cap not enforced (rc=$rc)"
has "the refusal says budget" "$out" "budget"
run convene seatB fable >/dev/null; [ "$?" = 0 ] && pass "the budget is per seat" || fail "seatB shared seatA's budget"

JUDGE_LADDER_NOW=$((1000000 + 7200)) run convene seatA fable >/dev/null
[ "$?" = 0 ] && pass "the budget frees after the window" || fail "window did not roll"

run convene seatC sonnet >/dev/null; run convene seatC sonnet >/dev/null; run convene seatC sonnet >/dev/null
run convene seatC sonnet >/dev/null; [ "$?" = 3 ] && pass "sonnet cap enforced" || fail "sonnet cap not enforced"

JUDGE_LADDER_FABLE_CAP=abc run convene seatD fable >/dev/null
[ "$?" = 2 ] && pass "a non-numeric cap is refused, not read as unlimited" || fail "non-numeric cap accepted"

mkdir "$WORK/state.lock"
out="$(JUDGE_LADDER_STATE="$WORK/state" run convene seatE sonnet)"; rc=$?
rmdir "$WORK/state.lock"
[ "$rc" = 3 ] && pass "a held state lock refuses the convening (rc 3)" || fail "held lock did not refuse (rc=$rc)"

out="$(run breakglass guard-no-fire)"; rc=$?
[ "$rc" = 0 ] && has "a guard that did not fire reaches the operator" "$out" "operator" || fail "breakglass guard-no-fire rc=$rc"
out="$(run breakglass invariant-regression)"; has "an invariant regression reaches the operator" "$out" "operator"
run breakglass style-nit >/dev/null; [ "$?" = 2 ] && pass "an ordinary finding class does not break glass" || fail "style-nit broke glass"

[ "$fails" = 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
