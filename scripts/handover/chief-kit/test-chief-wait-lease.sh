#!/usr/bin/env bash
# shellcheck disable=SC2016  # single-quoted stub bodies expand at run time
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WAIT="${CHIEF_WAIT:-$HERE/chief-wait.sh}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
contains() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (no '$3' in '$2')" ;; esac; }
lacks() { case "$2" in *"$3"*) fail "$1 ('$3' in '$2')" ;; *) pass "$1" ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/chief-wait-lease-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$WORK"' EXIT

STUB="$WORK/stub"; mkdir -p "$STUB"
printf '#!/usr/bin/env bash\ncat "$STUB/tick.line"\n' > "$STUB/tick.sh"
printf '#!/usr/bin/env bash\necho PROCEED\n' > "$STUB/bank.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/off.sh"
printf '#!/usr/bin/env bash\nexit 2\n' > "$STUB/budget-off.sh"
# the stub state reader: `<release> --json` prints $STUB/state.json and exits with $STUB/state.rc
printf '#!/usr/bin/env bash\ncat "$STUB/state.json"\nexit "$(cat "$STUB/state.rc")"\n' > "$STUB/rmstate.sh"
export STUB CHIEF_WAIT_TICK="$STUB/tick.sh" CHIEF_WAIT_USAGE="$STUB/bank.sh" CHIEF_WAIT_BUDGET="$STUB/budget-off.sh"
export WAIT_SWEEP_CMD="$STUB/off.sh" WAIT_FOCUS_CMD="$STUB/off.sh" CHIEF_WAIT_DISPATCH="$STUB/off.sh"
export CHIEF_WAIT_ORPHAN="$STUB/off.sh" CHIEF_WAIT_RMLEASE="$STUB/rmstate.sh"
export CHIEF_WAIT_INTERVAL=1 CHIEF_WAIT_POLL_SEC=0.2 CHIEF_WAIT_FAIL_WAKE=1000
export CHIEF_WAIT_RMLEASE_SAMPLE_MIN=0
export HIMMEL_DENIAL_ACK_DIR="$WORK/acks"
printf 'TICK 03:00 hb=1m workers=N1:FREE livestate=ok procs=2 models=x ceiling=ok atq=0 suites=0alive/0dead prs=#10 bank=5h8/wk15/codex=? fill=40 tails=N1:? inbox=none tick=UNKNOWN fleet=3/15 capacity=ok gql=4000/04:00 orphans=none nonces=ok legset=ok board=ok denials=none or=skip\n' > "$STUB/tick.line"

mkdir -p "$WORK/in/consoles"
inbox="$WORK/in/consoles/c.md"; : > "$inbox"
chief="$WORK/chief.md"
rmdoc="$WORK/rm-run-doc.md"
HOST="$(uname -n)"
reset() { rm -f "$inbox".wait* "$rmdoc"; printf '%s\n' '# chief' 'release: v1.1.3' > "$chief"; echo 0 > "$STUB/state.rc"; }
iso_ago() { date -u -d "$1 minutes ago" +%Y-%m-%dT%H:%M:%SZ; }  # gnu-ok: Linux-only kit
# state_json <epoch> <released true|false> <owner doc> <acquired minutes ago> [pid]
state_json() {
    local pid=''
    [ -z "${5:-}" ] || pid=",\"owner_pid\":$5,\"owner_host\":\"$HOST\""
    printf '{"release":"v1.1.3","status":"OK","lease":{"release":"v1.1.3","epoch":%s,"owner_session":"rm-1","owner_doc":"%s","acquired":"%s","released":%s,"prev_epoch":0%s},"requests":{"open":[],"claimed":[],"oldest_open":null}}\n' \
        "$1" "$3" "$(iso_ago "$4")" "$2" "$pid" > "$STUB/state.json"
}
run_waiter() {
    bash "$WAIT" "$inbox" --doc "$chief" > "$1" 2>/dev/null &
    local wp=$! n=0
    while [ "$n" -lt "$2" ] && kill -0 "$wp" 2>/dev/null; do sleep 0.1; n=$((n+1)); done
    if kill -0 "$wp" 2>/dev/null; then kill "$wp" 2>/dev/null; wait "$wp" 2>/dev/null; return 1; fi
    wait "$wp" 2>/dev/null
}

# 1. a held lease whose run doc is gone wakes once and names the epoch, the age and the takeover command
reset
state_json 411 false "$rmdoc" 600
if run_waiter "$WORK/l1.out" 60; then pass 'a held lease with a missing run doc wakes the waiter'; else fail 'a held lease with a missing run doc did not wake the waiter'; fi
contains 'the wake names the epoch and the age' "$(head -n 1 "$WORK/l1.out")" 'WAKE rm-lease-stale 411 600m'
contains 'the next line names the takeover command' "$(sed -n 2p "$WORK/l1.out")" 'release operator takeover v1.1.3 --epoch 411 --doc'

# 2. the same epoch does not wake again inside the re-wake interval
if run_waiter "$WORK/l2.out" 30; then fail "the same epoch woke twice: $(cat "$WORK/l2.out")"; else pass 'the same epoch is not re-woken inside the interval'; fi

# 3. a new epoch wakes at once
state_json 412 false "$rmdoc" 600
if run_waiter "$WORK/l3.out" 60; then pass 'a new stale epoch wakes at once'; else fail 'a new stale epoch did not wake'; fi
contains 'it names the new epoch' "$(head -n 1 "$WORK/l3.out")" 'WAKE rm-lease-stale 412'

# 4. the re-wake interval wakes the same epoch again once it has passed
if CHIEF_WAIT_RMLEASE_REWAKE_MIN=0 run_waiter "$WORK/l4.out" 60; then pass 'the same epoch wakes again once the re-wake interval has passed'; else fail 'the same epoch never re-woke at interval 0'; fi

# 5. a fresh lease with a fresh run doc does not wake
reset
: > "$rmdoc"
state_json 413 false "$rmdoc" 2
if run_waiter "$WORK/l5.out" 30; then fail "a fresh lease woke: $(cat "$WORK/l5.out")"; else pass 'a fresh lease with a fresh run doc does not wake'; fi

# 6. an old run doc with no live pid wakes; the age is the doc's
reset
: > "$rmdoc"; touch -d '2 hours ago' "$rmdoc"  # gnu-ok: Linux-only kit
state_json 414 false "$rmdoc" 130
if run_waiter "$WORK/l6.out" 60; then pass 'a run doc older than the window with no pid wakes'; else fail 'an old run doc with no pid did not wake'; fi
contains 'the old-doc wake names the epoch' "$(head -n 1 "$WORK/l6.out")" 'WAKE rm-lease-stale 414'

# 7. a live pid never wakes, even with the run doc gone
reset
state_json 415 false "$rmdoc" 600 "$$"
if run_waiter "$WORK/l7.out" 30; then fail "a live pid woke: $(cat "$WORK/l7.out")"; else pass 'a lease whose pid is alive does not wake'; fi

# 8. a released lease clears the marker
reset
state_json 416 false "$rmdoc" 600
run_waiter "$WORK/l8a.out" 60 > /dev/null
if grep -q 416 "$inbox.wait.rmlease" 2>/dev/null; then pass 'a wake puts the epoch in the marker'; else fail 'a wake left no marker'; fi
state_json 416 true "$rmdoc" 600
run_waiter "$WORK/l8b.out" 30 > /dev/null
if [ -e "$inbox.wait.rmlease" ]; then fail 'a released lease left the marker'; else pass 'a released lease clears the marker'; fi

# 9. a takeover (a new epoch held by a live run doc) clears the marker
reset
state_json 417 false "$rmdoc" 600
run_waiter "$WORK/l9a.out" 60 > /dev/null
: > "$rmdoc"
state_json 418 false "$rmdoc" 1
run_waiter "$WORK/l9b.out" 30 > /dev/null
if [ -e "$inbox.wait.rmlease" ]; then fail 'a taken-over lease left the marker'; else pass 'a taken-over lease clears the marker'; fi

# 10. an unreadable state answer wakes nobody, is never read as stale and keeps the marker
reset
state_json 419 false "$rmdoc" 600
run_waiter "$WORK/l10a.out" 60 > /dev/null
echo 1 > "$STUB/state.rc"
if run_waiter "$WORK/l10b.out" 30; then fail "a failed state read woke: $(cat "$WORK/l10b.out")"; else pass 'a failed state read does not wake'; fi
echo 0 > "$STUB/state.rc"
printf 'not json\n' > "$STUB/state.json"
if run_waiter "$WORK/l10c.out" 30; then fail "an unparseable state woke: $(cat "$WORK/l10c.out")"; else pass 'an unparseable state does not wake'; fi
if grep -q 419 "$inbox.wait.rmlease" 2>/dev/null; then pass 'an unreadable answer keeps the marker (not an all-clear)'; else fail 'an unreadable answer cleared the marker'; fi

# 11. a doc with no release: line reads no lease
reset
printf '%s\n' '# chief' > "$chief"
state_json 420 false "$rmdoc" 600
if run_waiter "$WORK/l11.out" 30; then fail "a doc with no release: line woke: $(cat "$WORK/l11.out")"; else pass 'a doc with no release: line never reads the lease'; fi
lacks 'and prints no lease wake' "$(cat "$WORK/l11.out")" 'rm-lease-stale'

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
exit 1
