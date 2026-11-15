#!/usr/bin/env bash
# shellcheck disable=SC2016  # single-quoted stub bodies expand at run time
# test-chief-wait-owed-stale.sh — the waiter wakes the chief once when a keyless
# ticket row of the owed ledger goes stale (tick.sh's `ACTION owed-stale=<n>:<ids>`
# line), and stays quiet when only the age moves, the count falls, or the field
# is absent. tick.sh and the bank verdict are stubbed, so no ledger, gh or bank
# read happens here. The other owed wake (owed-undelivered) is test-chief-wait-owed.sh.
#
# Linux-only: chief-wait.sh uses GNU timeout, so run-shell-tests.sh skips it off-Linux.
#
# Run: bash scripts/handover/chief-kit/test-chief-wait-owed-stale.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WAIT="${CHIEF_WAIT:-$HERE/chief-wait.sh}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/chief-wait-owed-stale-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$WORK"' EXIT

STUB="$WORK/stub"; mkdir -p "$STUB"
printf '#!/usr/bin/env bash\ncat "$STUB/tick.line"\n' > "$STUB/tick.sh"
printf '#!/usr/bin/env bash\necho PROCEED\n' > "$STUB/bank.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/off.sh"
printf '#!/usr/bin/env bash\nexit 2\n' > "$STUB/budget-off.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/page.sh"
chmod +x "$STUB/page.sh"
export STUB CHIEF_WAIT_TICK="$STUB/tick.sh" CHIEF_WAIT_USAGE="$STUB/bank.sh" CHIEF_WAIT_BUDGET="$STUB/budget-off.sh"
export WAIT_SWEEP_CMD="$STUB/off.sh" WAIT_FOCUS_CMD="$STUB/off.sh" CHIEF_WAIT_DISPATCH="$STUB/off.sh" CHIEF_WAIT_ORPHAN="$STUB/off.sh"
export CHIEF_WAIT_PAGE_CMD="$STUB/page.sh" CHIEF_WAIT_PAGE_TIMEOUT=2
export CHIEF_WAIT_INTERVAL=1 CHIEF_WAIT_POLL_SEC=0.2 CHIEF_WAIT_FAIL_WAKE=1000
export HIMMEL_DENIAL_ACK_DIR="$WORK/acks"

# set_tick <owed= value or ""> <ACTION owed-stale= value or "">: the tick line the stub serves.
set_tick() {
    local owed="" action=""
    [ -z "$1" ] || owed=" owed=$1"
    [ -z "$2" ] || action="ACTION owed-stale=$2: a ticket you owe has no key after 4h: file it, then close the row"
    printf 'TICK 03:00 hb=1m workers=N1:FRESH livestate=ok procs=2 models=x ceiling=ok atq=0 suites=0alive/0dead prs=#10 bank=5h8/wk15/codex=? fill=40 tails=N1:LIVE inbox=none tick=UNKNOWN fleet=3/15 capacity=ok gql=4000/04:00 orphans=none nonces=ok legset=ok board=ok%s denials=none or=skip\n' "$owed" > "$STUB/tick.line"
    [ -z "$action" ] || printf '%s\n' "$action" >> "$STUB/tick.line"
}

wait_hb() { # <inbox>: block until the waiter has taken its baseline key, at most ~5 s
    local n=0
    while [ "$n" -lt 50 ]; do
        grep -q 'key=[0-9a-f]' "$1.wait" 2>/dev/null && return 0
        sleep 0.1; n=$((n + 1))
    done
    return 1
}
wait_exit() { # <pid>: at most ~6 s; sets rc to the waiter's exit code or "running"
    local n=0
    while [ "$n" -lt 60 ]; do
        if ! kill -0 "$1" 2>/dev/null; then wait "$1"; rc=$?; return; fi
        sleep 0.1; n=$((n + 1))
    done
    rc=running
}
new_inbox() { mkdir -p "$WORK/$1/consoles"; : > "$WORK/$1/consoles/c.md"; printf '%s' "$WORK/$1/consoles/c.md"; }
start() { # <inbox> <outfile>
    bash "$WAIT" "$1" --workers "N1.md" > "$2" 2>"$2.err" &
    WPID=$!
}
stop() { kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; }

# (a) a keyless ticket row going stale wakes once, named owed
set_tick "" ""
I="$(new_inbox a)"; start "$I" "$WORK/a.out"
wait_hb "$I" || fail "(a) no baseline heartbeat"
set_tick 1:5h 1:o1
wait_exit "$WPID"
check "(a) a row going stale ends the wait" "0" "$rc"
check "(a) the wake names owed" "WAKE tick changed=owed usage=PROCEED" "$(head -n1 "$WORK/a.out")"
stop

# (b) the same value with only the age changed wakes nothing
set_tick 1:5h 1:o1
I="$(new_inbox b)"; start "$I" "$WORK/b.out"
wait_hb "$I" || fail "(b) no baseline heartbeat"
set_tick 1:6h 1:o1
wait_exit "$WPID"
check "(b) an age moving alone does not wake" "running" "$rc"
set_tick 1:7h 1:o1
wait_exit "$WPID"
check "(b) nor does it on the next sample" "running" "$rc"
stop

# (c) the row closed with a key: the field goes absent, nothing wakes, and it stays quiet
set_tick 1:5h 1:o1
I="$(new_inbox c)"; start "$I" "$WORK/c.out"
wait_hb "$I" || fail "(c) no baseline heartbeat"
set_tick "" ""
wait_exit "$WPID"
check "(c) the row closing does not wake" "running" "$rc"
check "(c) the saved key dropped owed" "0" "$(grep -c 'owed=' "$I.wait.state" 2>/dev/null)"
wait_exit "$WPID"
check "(c) and nothing wakes afterwards" "running" "$rc"
stop

# (c2) the stale count falling from two to one does not wake
set_tick 2:6h 2:o1,o2
I="$(new_inbox c2)"; start "$I" "$WORK/c2.out"
wait_hb "$I" || fail "(c2) no baseline heartbeat"
set_tick 1:6h 1:o2
wait_exit "$WPID"
check "(c2) a lower stale count does not wake" "running" "$rc"
stop

# (e) a second row going stale (the count rising) wakes again
set_tick 1:5h 1:o1
I="$(new_inbox e)"; start "$I" "$WORK/e.out"
wait_hb "$I" || fail "(e) no baseline heartbeat"
set_tick 2:6h 2:o1,o2
wait_exit "$WPID"
check "(e) a higher stale count wakes" "0" "$rc"
check "(e) the wake names owed" "WAKE tick changed=owed usage=PROCEED" "$(head -n1 "$WORK/e.out")"
stop

# (f) a row that is open but not stale (no ACTION line) wakes nothing
set_tick "" ""
I="$(new_inbox f)"; start "$I" "$WORK/f.out"
wait_hb "$I" || fail "(f) no baseline heartbeat"
set_tick 1:12m ""
wait_exit "$WPID"
check "(f) an open row that is not stale does not wake" "running" "$rc"
set_tick 3:50m ""
wait_exit "$WPID"
check "(f) nor does a higher open count" "running" "$rc"
stop

# (g) owed=? (an unreadable ledger) keeps the saved value: the blip and the return are no change
set_tick 1:5h 1:o1
I="$(new_inbox g)"; start "$I" "$WORK/g.out"
wait_hb "$I" || fail "(g) no baseline heartbeat"
set_tick '?' ""
wait_exit "$WPID"
check "(g) an unreadable ledger does not wake" "running" "$rc"
set_tick 1:5h 1:o1
wait_exit "$WPID"
check "(g) the same stale row returning after the blip does not wake" "running" "$rc"
stop

# (d) negative control: a tick line with no owed= field is a good sample, not a failed one
set_tick "" ""
I="$(new_inbox d)"; start "$I" "$WORK/d.out"
check "(d) a tick line with no owed= field takes a baseline" "0" "$(wait_hb "$I"; echo $?)"
wait_exit "$WPID"
check "(d) and the waiter keeps waiting" "running" "$rc"
check "(d) the sample is not a failed one" "0" "$(grep -c 'tick-fail\|missing-field' "$I.wait" "$WORK/d.out" "$WORK/d.out.err" 2>/dev/null | awk -F: '{s += $NF} END {print s + 0}')"
stop

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed"; exit 1
