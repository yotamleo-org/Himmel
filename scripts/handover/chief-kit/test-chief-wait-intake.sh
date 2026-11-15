#!/usr/bin/env bash
# shellcheck disable=SC2016  # single-quoted stub bodies expand at run time
# The waiter arms ONE release-manager intake pass (a WAKE rm-intake, never a launch) once INTAKE has
# stood above 0 for more than 6 h while capacity=UNDERFILLED; a pass already running arms nothing. The
# create-cap-hit token and the CAPPED flag are gone from the review wake.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WAIT="${CHIEF_WAIT:-$HERE/chief-wait.sh}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
contains() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (no '$3' in '$2')" ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/chief-wait-intake-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$WORK"' EXIT

STUB="$WORK/stub"; mkdir -p "$STUB"
printf '#!/usr/bin/env bash\ncat "$STUB/tick.line"\n' > "$STUB/tick.sh"
printf '#!/usr/bin/env bash\necho PROCEED\n' > "$STUB/bank.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/off.sh"
printf '#!/usr/bin/env bash\nexit 2\n' > "$STUB/budget-off.sh"
printf '#!/usr/bin/env bash\ncat "$STUB/state.json"\n' > "$STUB/rmstate.sh"
export STUB CHIEF_WAIT_TICK="$STUB/tick.sh" CHIEF_WAIT_USAGE="$STUB/bank.sh" CHIEF_WAIT_BUDGET="$STUB/budget-off.sh"
export WAIT_SWEEP_CMD="$STUB/off.sh" WAIT_FOCUS_CMD="$STUB/off.sh" CHIEF_WAIT_DISPATCH="$STUB/off.sh"
export CHIEF_WAIT_ORPHAN="$STUB/off.sh" CHIEF_WAIT_RMLEASE="$STUB/rmstate.sh"
export CHIEF_WAIT_INTERVAL=1 CHIEF_WAIT_POLL_SEC=0.2 CHIEF_WAIT_FAIL_WAKE=1000
export CHIEF_WAIT_RMLEASE_SAMPLE_MIN=0 CHIEF_WAIT_INTAKE_SAMPLE_MIN=0
export CHIEF_WAIT_INTAKE_ARM_HOURS=6 CHIEF_WAIT_INTAKE_REWAKE_MIN=360  # an inherited bound must not move the 5 h / 7 h fixtures
export HIMMEL_DENIAL_ACK_DIR="$WORK/acks"

mkdir -p "$WORK/in/consoles"
inbox="$WORK/in/consoles/c.md"; : > "$inbox"
chief="$WORK/chief.md"
marker="$inbox.wait.intake"
tick() { # <capacity> <INTAKE field or empty>
    printf 'TICK 03:00 hb=1m workers=N1:FREE livestate=ok procs=2 models=x ceiling=ok atq=0 suites=0alive/0dead prs=#10 bank=5h8/wk15/codex=? fill=40 tails=N1:? inbox=none tick=UNKNOWN fleet=3/15 capacity=%s gql=4000/04:00 orphans=none nonces=ok legset=ok board=ok denials=none or=skip%s\n' "$1" "${2:+ $2}" > "$STUB/tick.line"
}
reset() { # the underfill marker keeps the pool probe quiet, so only the intake wake can end the wait
    rm -f "$inbox".wait*; touch "$inbox.wait.underfill"
    printf '%s\n' '# chief' 'release: v1.1.3' > "$chief"
    printf '{"release":"v1.1.3","status":"OK","lease":null}\n' > "$STUB/state.json"
}
seed() { printf '%s\n0\n' "$(( $(date +%s) - $1 * 3600 ))" > "$marker"; }  # INTAKE first seen <h> hours ago
lease_held() { # a live holder (this shell's pid) and a fresh acquire, so the stale-lease wake stays quiet too
    printf '{"release":"v1.1.3","status":"OK","lease":{"release":"v1.1.3","epoch":7,"owner_session":"rm-1","owner_doc":"-","acquired":"%s","released":false,"prev_epoch":0,"owner_pid":%s,"owner_host":"%s"}}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" "$$" "$(uname -n)" > "$STUB/state.json"
}
run_waiter() {
    bash "$WAIT" "$inbox" --doc "$chief" > "$1" 2>/dev/null &
    local wp=$! n=0
    while [ "$n" -lt "$2" ] && kill -0 "$wp" 2>/dev/null; do sleep 0.1; n=$((n+1)); done
    if kill -0 "$wp" 2>/dev/null; then kill "$wp" 2>/dev/null; wait "$wp" 2>/dev/null; return 1; fi  # still waiting: no wake
    local rc=0
    wait "$wp" 2>/dev/null || rc=$?
    [ "$rc" -eq 0 ] || { fail "the waiter exited rc=$rc without a wake (a crash, not a quiet sample): $1"; return 1; }
}

# the 7 h fixture arms once, naming the rm-run command
reset; tick UNDERFILLED:3 INTAKE=48; seed 7
if run_waiter "$WORK/a1.out" 60; then pass 'INTAKE above 0 for 7 h while UNDERFILLED wakes the waiter'; else fail 'the 7 h INTAKE fixture armed nothing'; fi
contains 'the wake names the count and the age' "$(head -n 1 "$WORK/a1.out")" 'WAKE rm-intake INTAKE=48 since=7h'
contains 'the next line names the rm-run command' "$(sed -n 2p "$WORK/a1.out")" 'release rm-run v1.1.3 --doc'
# one at a time: the wake is stamped, so the same streak arms nothing again
if run_waiter "$WORK/a2.out" 30; then fail "a second wake in the same streak armed again: $(head -n 1 "$WORK/a2.out")"; else pass 'a second wake inside the re-wake window arms nothing'; fi

# a leading-zero bound is decimal, not an arithmetic error
reset; tick UNDERFILLED:3 INTAKE=48; seed 9
if CHIEF_WAIT_INTAKE_ARM_HOURS=08 run_waiter "$WORK/z1.out" 60; then pass 'CHIEF_WAIT_INTAKE_ARM_HOURS=08 reads as 8 h and arms at 9 h'; else fail 'a leading-zero bound armed nothing'; fi

# negative control: 5 h is under the bound
reset; tick UNDERFILLED:3 INTAKE=48; seed 5
if run_waiter "$WORK/b1.out" 30; then fail "5 h of INTAKE armed: $(head -n 1 "$WORK/b1.out")"; else pass 'INTAKE above 0 for 5 h arms nothing'; fi

# single-run guard: a held rm lease arms nothing
reset; tick UNDERFILLED:3 INTAKE=48; seed 7; lease_held
if run_waiter "$WORK/c1.out" 30; then fail "a pass already running armed another: $(head -n 1 "$WORK/c1.out")"; else pass 'a held rm lease arms nothing'; fi
reset; tick UNDERFILLED:3 INTAKE=48; seed 7; printf 'not json\n' > "$STUB/state.json"
if run_waiter "$WORK/c2.out" 30; then fail "an unreadable lease armed: $(head -n 1 "$WORK/c2.out")"; else pass 'an unreadable lease arms nothing'; fi

# only when UNDERFILLED
reset; tick ok INTAKE=48; seed 7
if run_waiter "$WORK/d1.out" 30; then fail "a full fleet armed: $(head -n 1 "$WORK/d1.out")"; else pass 'capacity=ok arms nothing even past 6 h'; fi

# the clock: first sight starts it, INTAKE back at 0 clears it
reset; tick UNDERFILLED:3 INTAKE=48
run_waiter "$WORK/e1.out" 30 >/dev/null
if [ -s "$marker" ] && [ "$(sed -n 1p "$marker")" -ge "$(( $(date +%s) - 60 ))" ]; then pass 'the first sight of INTAKE starts the clock at now'; else fail 'no clock after the first INTAKE sample'; fi
tick UNDERFILLED:3 ''
run_waiter "$WORK/e2.out" 30 >/dev/null
if [ -e "$marker" ]; then fail 'INTAKE back at 0 left the clock'; else pass 'INTAKE back at 0 clears the clock'; fi

# no create-cap-hit token, no CAPPED flag read in the review wake
reset; tick ok ''; sed -i 's/ denials=none/ review=2026-11-06:2h:80:0:0:-:CAPPED denials=none/' "$STUB/tick.line"  # gnu-ok: Linux-only kit
if run_waiter "$WORK/f1.out" 30; then fail "a CAPPED-only review woke: $(head -n 1 "$WORK/f1.out")"; else pass 'a review that only carries CAPPED wakes nothing'; fi
if grep -n 'create-cap-hit\|CAPPED' "$WAIT" >/dev/null 2>&1; then fail 'chief-wait.sh still names CAPPED or create-cap-hit'; else pass 'chief-wait.sh no longer names CAPPED or create-cap-hit'; fi

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
