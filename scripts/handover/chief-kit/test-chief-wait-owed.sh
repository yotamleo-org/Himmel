#!/usr/bin/env bash
# test-chief-wait-owed.sh — chief-wait.sh `WAKE owed-undelivered <keys>`: an
# `OWED <key>` bullet in the --doc chief doc with no `DELIVERED <key> msg=<id>` receipt
# wakes the chief once it is older than CHIEF_WAIT_OWED_SEC (default 300), once; the
# receipt chief-route.ts writes clears it. tick.sh, the bank verdict and every side
# helper are stubbed: nothing here touches a real chief or Telegram.
#
# Linux-only (GNU timeout/find): run-shell-tests.sh skips it off-Linux.
# Run: bash scripts/handover/chief-kit/test-chief-wait-owed.sh
# shellcheck disable=SC2016  # single-quoted stub bodies expand at run time
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WAIT="${CHIEF_WAIT:-$HERE/chief-wait.sh}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
contains() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (no '$3' in '$2')" ;; esac; }
lacks() { case "$2" in *"$3"*) fail "$1 ('$3' in '$2')" ;; *) pass "$1" ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/chief-wait-owed-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$WORK"' EXIT

STUB="$WORK/stub"; mkdir -p "$STUB"
printf '#!/usr/bin/env bash\ncat "$STUB/tick.line"\n' > "$STUB/tick.sh"
printf '#!/usr/bin/env bash\necho PROCEED\n' > "$STUB/bank.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/off.sh"
printf '#!/usr/bin/env bash\nexit 2\n' > "$STUB/budget-off.sh"
export STUB CHIEF_WAIT_TICK="$STUB/tick.sh" CHIEF_WAIT_USAGE="$STUB/bank.sh" CHIEF_WAIT_BUDGET="$STUB/budget-off.sh"
export WAIT_SWEEP_CMD="$STUB/off.sh" WAIT_FOCUS_CMD="$STUB/off.sh" CHIEF_WAIT_DISPATCH="$STUB/off.sh"
export CHIEF_WAIT_INTERVAL=1 CHIEF_WAIT_POLL_SEC=0.2 CHIEF_WAIT_FAIL_WAKE=1000
export HIMMEL_DENIAL_ACK_DIR="$WORK/acks"
printf 'TICK 03:00 hb=1m workers=N1:FREE livestate=ok procs=2 models=x ceiling=ok atq=0 suites=0alive/0dead prs=#10 bank=5h8/wk15/codex=? fill=40 tails=N1:? inbox=none tick=UNKNOWN fleet=3/15 capacity=ok gql=4000/04:00 orphans=none nonces=ok legset=ok board=ok denials=none or=skip\n' > "$STUB/tick.line"

mkdir -p "$WORK/in/consoles"
inbox="$WORK/in/consoles/c.md"; : > "$inbox"
chief="$WORK/chief.md"
reset() { rm -f "$inbox".wait*; printf '%s\n' '# chief' > "$chief"; }
# run_waiter <outfile> <ticks>: true when the waiter woke (exited) within <ticks> x 0.1 s
run_waiter() {
    bash "$WAIT" "$inbox" --doc "$chief" > "$1" 2>/dev/null &
    local wp=$! n=0
    while [ "$n" -lt "$2" ] && kill -0 "$wp" 2>/dev/null; do sleep 0.1; n=$((n+1)); done
    if kill -0 "$wp" 2>/dev/null; then kill "$wp" 2>/dev/null; wait "$wp" 2>/dev/null; return 1; fi
    wait "$wp" 2>/dev/null; return 0
}

reset
printf '%s\n' '- 10:00 OWED sig-9608 sign the 9608 spec' >> "$chief"
if CHIEF_WAIT_OWED_SEC=0 run_waiter "$WORK/o1.out" 60; then pass 'an OWED item with no receipt wakes the waiter'; else fail 'an OWED item with no receipt did not wake the waiter'; fi
contains 'the wake names the key: WAKE owed-undelivered sig-9608' "$(cat "$WORK/o1.out")" 'WAKE owed-undelivered sig-9608'
if CHIEF_WAIT_OWED_SEC=0 run_waiter "$WORK/o2.out" 30; then fail "the same OWED item woke twice: $(cat "$WORK/o2.out")"; else pass 'the same OWED item does not wake again'; fi

reset
printf '%s\n' '- 10:00 OWED sig-9609 sign the other spec' >> "$chief"
if run_waiter "$WORK/o3.out" 30; then fail "an OWED item younger than the 300 s default woke: $(cat "$WORK/o3.out")"; else pass 'an OWED item younger than 5 minutes does not wake'; fi
printf 'sig-9609 %s 0\n' "$(( $(date +%s) - 400 ))" > "$inbox.wait.owed"
if run_waiter "$WORK/o4.out" 60; then pass 'an OWED item first seen 400 s ago wakes at the default window'; else fail 'an aged OWED item did not wake'; fi
contains 'the aged wake names it' "$(cat "$WORK/o4.out")" 'WAKE owed-undelivered sig-9609'

reset
printf '%s\n' '- 10:00 OWED sig-9610 sign it' '- 10:01 DELIVERED sig-9610 msg=555 chat=1' >> "$chief"
if CHIEF_WAIT_OWED_SEC=0 run_waiter "$WORK/o5.out" 30; then fail "a receipted item woke: $(cat "$WORK/o5.out")"; else pass 'an OWED item with a DELIVERED receipt does not wake'; fi

reset
printf '%s\n' '- 10:00 OWED sig-9611 sign it' '- 10:01 DELIVERED sig-9612 msg=556 chat=1' >> "$chief"
if CHIEF_WAIT_OWED_SEC=0 run_waiter "$WORK/o6.out" 60; then pass "another key's receipt does not clear this item"; else fail "another key's receipt cleared sig-9611"; fi
contains 'only the unreceipted key is named' "$(cat "$WORK/o6.out")" 'WAKE owed-undelivered sig-9611'

reset
printf '%s\n' '- 10:00 OWED sig-9613 sign it' >> "$chief"
if CHIEF_WAIT_OWED_SEC=0 run_waiter "$WORK/o7.out" 60 && grep -q '^sig-9613 ' "$inbox.wait.owed"; then pass 'the first sight wakes and puts the key in the marker'; else fail 'the first sight neither woke nor marked sig-9613'; fi
printf '%s\n' '- 10:05 DELIVERED sig-9613 msg=557 chat=1' >> "$chief"
CHIEF_WAIT_OWED_SEC=0 run_waiter "$WORK/o8.out" 30 > /dev/null
if [ -e "$inbox.wait.owed" ] && grep -q '^sig-9613 ' "$inbox.wait.owed"; then fail 'a receipted key stayed in the marker'; else pass 'a receipt clears the key from the marker'; fi

reset
printf '%s\n' '- 10:00 OWED a-b sign it' '- 10:00 OWED a-bc sign that' '- 10:01 DELIVERED a-bc msg=558 chat=1' >> "$chief"
if CHIEF_WAIT_OWED_SEC=0 run_waiter "$WORK/o9.out" 60; then pass 'a-b is still owed when only a-bc was delivered'; else fail 'the a-bc receipt cleared a-b (prefix match)'; fi
lacks 'a-bc is not named' "$(head -n 1 "$WORK/o9.out")" 'a-bc'

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed"; exit 1
