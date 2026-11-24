#!/usr/bin/env bash
# test-chief-wait-budget.sh — Exercises chief-wait.sh's WAKE budget-recovered: a usage
# verdict that flips from a refusing word (SKIPPED-BANK, SKIPPED-FLEET, BANK-STALE,
# BANK-UNKNOWN) to PROCEED wakes the chief exactly once and runs the fleet nudge once.
# tick.sh, the usage verdict and the nudge are stubbed (CHIEF_WAIT_TICK / CHIEF_WAIT_USAGE /
# CHIEF_WAIT_NUDGE), so no gh, lock, bank read or bus send happens here. bash 3.2-safe.
#
# CHIEF_WAIT overrides the script under test (the RED control).
#
# Run: bash scripts/handover/chief-kit/test-chief-wait-budget.sh
set -u
[ "$(uname -s)" = Linux ] || { echo "SKIP: chief-wait.sh is Linux-only"; exit 0; }
HERE="$(cd "$(dirname "$0")" && pwd)"
WAIT="${CHIEF_WAIT:-$HERE/chief-wait.sh}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/chief-wait-budget-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$WORK"' EXIT

STUB="$WORK/stub"
mkdir -p "$STUB"
# shellcheck disable=SC2016  # $STUB, $* and $1 expand in the stubs, not here
{
    printf '#!/usr/bin/env bash\ncat "$STUB/tick.line"\n' > "$STUB/tick.sh"
    printf '#!/usr/bin/env bash\ncat "$STUB/bank"\n' > "$STUB/bank.sh"
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$STUB/nudge.calls"\necho "BUS-NUDGE N1 ok"\necho "NUDGED 1 of 1"\n' > "$STUB/nudge.sh"
    printf '#!/usr/bin/env bash\nexit 2\n' > "$STUB/budget-off.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/sweep-off.sh"
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" >> "$STUB/pages"\nexit 0\n' > "$STUB/page.sh"
}
chmod +x "$STUB"/*.sh
export STUB
export CHIEF_WAIT_TICK="$STUB/tick.sh" CHIEF_WAIT_USAGE="$STUB/bank.sh" CHIEF_WAIT_NUDGE="$STUB/nudge.sh"
export CHIEF_WAIT_INTERVAL=1 CHIEF_WAIT_POLL_SEC=0.2
export CHIEF_WAIT_DISPATCH="$STUB/no-dispatch.sh"
export CHIEF_WAIT_FAIL_WAKE=1000
export CHIEF_WAIT_PAGE_CMD="$STUB/page.sh" CHIEF_WAIT_PAGE_TIMEOUT=2
export HIMMEL_DENIAL_ACK_DIR="$WORK/acks"
export CHIEF_WAIT_BUDGET="$STUB/budget-off.sh"
export WAIT_SWEEP_CMD="$STUB/sweep-off.sh" WAIT_FOCUS_CMD="$STUB/sweep-off.sh"

printf 'TICK 03:00 hb=1m workers=N1:FRESH livestate=ok procs=2 models=x ceiling=ok atq=0 suites=0alive/0dead prs=#10 bank=5h8/wk15/codex=? fill=40 tails=N1:LIVE inbox=none tick=UNKNOWN fleet=3/15 capacity=ok gql=4000/04:00 orphans=none nonces=ok legset=ok board=ok denials=none or=skip fails=none\n' > "$STUB/tick.line"
MANIFEST="$WORK/chief.fleet.json"
printf '{"schema":1,"workers":[]}\n' > "$MANIFEST"
bank() { printf '%s\n' "$1" > "$STUB/bank"; }

wait_hb() {
    n=0
    while [ "$n" -lt 50 ]; do
        grep -q 'key=[0-9a-f]' "$1.wait" 2>/dev/null && return 0
        sleep 0.1; n=$((n + 1))
    done
    return 1
}
wait_exit() {
    n=0
    while [ "$n" -lt 80 ]; do
        if ! kill -0 "$1" 2>/dev/null; then wait "$1"; rc=$?; return; fi
        sleep 0.1; n=$((n + 1))
    done
    rc=running
}
new_inbox() { mkdir -p "$WORK/$1/consoles"; : > "$WORK/$1/consoles/c.md"; printf '%s' "$WORK/$1/consoles/c.md"; }
start() {
    local inbox="$1" out="$2"; shift 2
    bash "$WAIT" "$inbox" "$@" > "$out" 2>"$out.err" &
    WPID=$!
}
stop_waiter() {
    kill "$1" 2>/dev/null
    local n=0
    while kill -0 "$1" 2>/dev/null && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
    kill -KILL "$1" 2>/dev/null
    wait "$1" 2>/dev/null
}
count() { grep -c -- "$1" "$2" 2>/dev/null || true; }
quiet() { timeout -k 5 4 bash "$WAIT" "$1" --workers-from "$MANIFEST" > "$2" 2>/dev/null; check "$3: the waiter runs until its timeout" "124" "$?"; }  # gnu-ok: Linux-only kit

: > "$STUB/nudge.calls"
bank SKIPPED-BANK
I="$(new_inbox r1)"
start "$I" "$WORK/r1.out" --workers-from "$MANIFEST"
wait_hb "$I" || fail "(r1) no baseline heartbeat"
bank PROCEED
wait_exit "$WPID"
[ "$rc" = running ] && stop_waiter "$WPID"
check "(r1) the flip to PROCEED ends the wait" "0" "$rc"
check "(r1) the wake names the old verdict and the new one" "WAKE budget-recovered from=SKIPPED-BANK usage=PROCEED" "$(head -n1 "$WORK/r1.out")"
check "(r1) exactly one budget-recovered wake in the run" "1" "$(count '^WAKE budget-recovered' "$WORK/r1.out")"
check "(r1) the flip is one wake, not a second generic usage wake" "1" "$(count '^WAKE ' "$WORK/r1.out")"
check "(r1) the nudge runs once, on the fleet manifest" "$MANIFEST" "$(cat "$STUB/nudge.calls")"
check "(r1) the nudge's per-worker lines are printed under the wake" "BUS-NUDGE N1 ok" "$(sed -n 2p "$WORK/r1.out")"
quiet "$I" "$WORK/r1b.out" "(r1b)"
check "(r1) a second poll at PROCEED wakes nothing" "" "$(cat "$WORK/r1b.out")"
check "(r1) the second poll runs no nudge" "1" "$(grep -c . "$STUB/nudge.calls")"

: > "$STUB/nudge.calls"
bank PROCEED
I="$(new_inbox r2)"
quiet "$I" "$WORK/r2.out" "(r2)"
check "(r2) a first sample at PROCEED wakes nothing" "" "$(cat "$WORK/r2.out")"
check "(r2) the word is remembered" "PROCEED" "$(cat "$I.wait.usage" 2>/dev/null)"

bank SKIPPED-BANK
I="$(new_inbox r3)"
start "$I" "$WORK/r3.out" --workers-from "$MANIFEST"
wait_hb "$I" || fail "(r3) no baseline heartbeat"
bank garbled
sleep 2.5
check "(r3) a failed read leaves the remembered word" "SKIPPED-BANK" "$(cat "$I.wait.usage" 2>/dev/null)"
bank PROCEED
wait_exit "$WPID"
[ "$rc" = running ] && stop_waiter "$WPID"
check "(r3) PROCEED after the failed read wakes" "WAKE budget-recovered from=SKIPPED-BANK usage=PROCEED" "$(head -n1 "$WORK/r3.out")"

bank PROCEED
I="$(new_inbox r4)"
start "$I" "$WORK/r4.out" --workers-from "$MANIFEST"
wait_hb "$I" || fail "(r4) no baseline heartbeat"
bank SKIPPED-BANK
wait_exit "$WPID"
[ "$rc" = running ] && stop_waiter "$WPID"
check "(r4) PROCEED to SKIPPED-BANK wakes no budget-recovered" "0" "$(count '^WAKE budget-recovered' "$WORK/r4.out")"
check "(r4) the generic usage wake still fires" "WAKE tick changed=usage usage=SKIPPED-BANK" "$(head -n1 "$WORK/r4.out")"

for word in SKIPPED-FLEET BANK-STALE BANK-UNKNOWN; do
    : > "$STUB/nudge.calls"
    bank "$word"
    I="$(new_inbox "r5-$word")"
    start "$I" "$WORK/r5-$word.out" --workers-from "$MANIFEST"
    wait_hb "$I" || fail "(r5) $word: no baseline heartbeat"
    bank PROCEED
    wait_exit "$WPID"
    [ "$rc" = running ] && stop_waiter "$WPID"
    if [ "$word" = SKIPPED-FLEET ]; then
        check "(r5) $word to PROCEED wakes budget-recovered" "WAKE budget-recovered from=$word usage=PROCEED" "$(head -n1 "$WORK/r5-$word.out")"
    else
        check "(r5) an undecided $word then PROCEED wakes no budget-recovered" "0" "$(count '^WAKE budget-recovered' "$WORK/r5-$word.out")"
        check "(r5) an undecided $word then PROCEED nudges nobody" "0" "$(grep -c . "$STUB/nudge.calls")"
    fi
done

: > "$STUB/nudge.calls"
bank PROCEED
I="$(new_inbox r7)"
start "$I" "$WORK/r7a.out" --workers-from "$MANIFEST"
wait_hb "$I" || fail "(r7) no baseline heartbeat"
bank BANK-UNKNOWN
wait_exit "$WPID"
[ "$rc" = running ] && stop_waiter "$WPID"
check "(r7) BANK-UNKNOWN leaves the saved PROCEED" "PROCEED" "$(cat "$I.wait.usage" 2>/dev/null)"
bank PROCEED
start "$I" "$WORK/r7b.out" --workers-from "$MANIFEST"
wait_exit "$WPID"
[ "$rc" = running ] && stop_waiter "$WPID"
check "(r7) PROCEED, BANK-UNKNOWN, PROCEED wakes no budget-recovered" "0" "$(cat "$WORK/r7a.out" "$WORK/r7b.out" | grep -c '^WAKE budget-recovered')"
check "(r7) PROCEED, BANK-UNKNOWN, PROCEED nudges nobody" "0" "$(grep -c . "$STUB/nudge.calls")"

: > "$STUB/nudge.calls"
bank SKIPPED-BANK
I="$(new_inbox r8)"
start "$I" "$WORK/r8a.out" --workers-from "$MANIFEST"
wait_hb "$I" || fail "(r8) no baseline heartbeat"
bank BANK-STALE
wait_exit "$WPID"
[ "$rc" = running ] && stop_waiter "$WPID"
check "(r8) BANK-STALE leaves the saved SKIPPED-BANK" "SKIPPED-BANK" "$(cat "$I.wait.usage" 2>/dev/null)"
bank PROCEED
start "$I" "$WORK/r8b.out" --workers-from "$MANIFEST"
wait_exit "$WPID"
[ "$rc" = running ] && stop_waiter "$WPID"
check "(r8) SKIPPED-BANK, BANK-STALE, PROCEED wakes once from SKIPPED-BANK" "WAKE budget-recovered from=SKIPPED-BANK usage=PROCEED" "$(cat "$WORK/r8a.out" "$WORK/r8b.out" | grep '^WAKE budget-recovered')"
check "(r8) the nudge runs once" "1" "$(grep -c . "$STUB/nudge.calls")"

bank SKIPPED-BANK
I="$(new_inbox r6)"
quiet "$I" "$WORK/r6.out" "(r6)"
quiet "$I" "$WORK/r6b.out" "(r6b)"
check "(r6) SKIPPED-BANK held across two runs wakes nothing" "" "$(cat "$WORK/r6.out" "$WORK/r6b.out")"

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
