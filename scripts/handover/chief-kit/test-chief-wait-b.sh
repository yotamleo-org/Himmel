#!/usr/bin/env bash
# test-chief-wait.sh — Exercises chief-wait.sh, the chief's
# one event waiter: silent while nothing changes, exits with exactly one WAKE
# block on a Telegram inbox line or a confirmed change of the tick's action
# key. tick.sh and the bank verdict are stubbed (CHIEF_WAIT_TICK /
# CHIEF_WAIT_USAGE), so no gh, lock or bank read happens here. bash 3.2-safe.
#
# CHIEF_WAIT overrides the script under test (the RED
# control: today's Monitor-arm shape, which runs tick.sh on every arm, fails the
# idle cases).
#
# Linux-only: this suite uses GNU
# timeout and touch -d, so run-shell-tests.sh skips it off-Linux.
#
# Fourth part of the chief-wait suite: the (vmrun) to (cs) cases. The split is
# described in test-chief-wait.sh.
#
# Run: bash scripts/handover/chief-kit/test-chief-wait-b.sh
set -u
KP=HIMMEL
HERE="$(cd "$(dirname "$0")" && pwd)"
WAIT="${CHIEF_WAIT:-$HERE/chief-wait.sh}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/chief-wait-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$WORK"' EXIT

STUB="$WORK/stub"
mkdir -p "$STUB"
cat > "$STUB/tick.sh" <<'EOF'
#!/usr/bin/env bash
printf x >> "$STUB/ticks"
printf '%s\n' "$*" >> "$STUB/tick.args"
[ -f "$STUB/tick.rc" ] && exit "$(cat "$STUB/tick.rc")"
if [ -f "$STUB/tick.strict" ]; then
    for a in "$@"; do case "$a" in --since|--receipt) echo "tick.sh: unknown flag $a" >&2; echo "second stderr line" >&2; exit 2 ;; esac; done
fi
# tick.sleep: a slow tick (seconds), as a real gh-bound tick can be.
[ -f "$STUB/tick.sleep" ] && sleep "$(cat "$STUB/tick.sleep")"
# tick.ignoreterm: a hung tick that ignores SIGTERM (timeout needs -k).
if [ -f "$STUB/tick.ignoreterm" ]; then trap '' TERM; sleep 20; exit 0; fi
# tick.failafter: prints its line, then fails (a tick that dies mid-run).
if [ -f "$STUB/tick.failafter" ]; then cat "$STUB/tick.line"; exit 1; fi
# tick.blip: served for exactly one sample, then gone.
if [ -f "$STUB/tick.blip" ]; then cat "$STUB/tick.blip"; rm -f "$STUB/tick.blip"; exit 0; fi
# tick.churn: every sample serves a new prs= value (a busy repo's PR set).
if [ -f "$STUB/tick.churn" ]; then
    n=$(( $(cat "$STUB/tick.churn") + 1 )); printf '%s\n' "$n" > "$STUB/tick.churn"
    sed "s/prs=[^ ]*/prs=#$n/" "$STUB/tick.line"; exit 0
fi
cat "$STUB/tick.line"
EOF
cat > "$STUB/bank.sh" <<'EOF'
#!/usr/bin/env bash
cat "$STUB/bank"
EOF
export STUB
export CHIEF_WAIT_TICK="$STUB/tick.sh" CHIEF_WAIT_USAGE="$STUB/bank.sh"
export CHIEF_WAIT_INTERVAL=1 CHIEF_WAIT_POLL_SEC=0.2
# A failure streak wakes only in (f4); elsewhere a failed sample is just "not a change".
export CHIEF_WAIT_FAIL_WAKE=1000
# a denials rise pages the operator. The suite owns the sender and
# the record dir (never a real Telegram send, never ~/.himmel/state): the stub
# appends each page text to $STUB/pages. CHIEF_WAIT_PAGE_TIMEOUT is kept short
# so the hung-sender case (p6) finishes fast.
cat > "$STUB/page.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$STUB/pages"
exit 0
EOF
chmod +x "$STUB/page.sh"  # the sender seam is exec'd directly, not run via bash
export CHIEF_WAIT_PAGE_CMD="$STUB/page.sh" CHIEF_WAIT_PAGE_TIMEOUT=2
export HIMMEL_DENIAL_ACK_DIR="$WORK/acks"
# No test reads the real transcripts: the budget seam answers "unreadable" (exit 2) until (hb).
cat > "$STUB/budget-off.sh" <<'EOF'
#!/usr/bin/env bash
exit 2
EOF
export CHIEF_WAIT_BUDGET="$STUB/budget-off.sh"
# the underfilled orphan-pr check reads gh; a clean no-op keeps these cases off the real one
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/orphan-off.sh"
export CHIEF_WAIT_ORPHAN="$STUB/orphan-off.sh"
# Nor does any test run the real status sweep or read a real FOCUS state: both seams answer nothing.
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/sweep-off.sh"
export WAIT_SWEEP_CMD="$STUB/sweep-off.sh" WAIT_FOCUS_CMD="$STUB/sweep-off.sh"
export CHIEF_WAIT_DISPATCH="$STUB/no-dispatch.sh"

# tick_line <workers> <board> [hb] [prs] [or] [fails]: a tick line whose action fields are set.
tick_line() {
    printf 'TICK 03:00 hb=%s legs=%s livestate=ok procs=2 models=x ceiling=ok atq=0 suites=0alive/0dead prs=%s bank=5h8/wk15/codex=? fill=40 tails=N1:LIVE inbox=none tick=UNKNOWN fleet=3/15 capacity=ok gql=4000/04:00 orphans=none nonces=ok legset=ok board=%s denials=none or=%s fails=%s\n' \
        "${3:-1m}" "$1" "${4:-#10}" "$2" "${5:-skip}" "${6:-none}" > "$STUB/tick.line"
}
reset_stub() { rm -f "$STUB/tick.rc" "$STUB/tick.blip" "$STUB/tick.churn" "$STUB/tick.sleep" "$STUB/tick.failafter" "$STUB/tick.ignoreterm"; tick_line "N1:FRESH" "ok"; printf 'PROCEED\n' > "$STUB/bank"; }

# wait_hb <inbox>: block until the waiter has taken its baseline (heartbeat
# carries a key), at most ~5 s.
wait_hb() {
    n=0
    while [ "$n" -lt 50 ]; do
        grep -q 'key=[0-9a-f]' "$1.wait" 2>/dev/null && return 0
        sleep 0.1; n=$((n + 1))
    done
    return 1
}
SAMPLES_AFTER_CHANGE=4
NO_SAMPLE_CUTOFF_TICKS=80
STALL_CAP_TICKS=300
# Not a $(...) helper: `wait` must run in the shell that started the waiter.
wait_exit() {
    local want="${2:-$SAMPLES_AFTER_CHANGE}" base seen
    base=$(wc -c < "$STUB/ticks" 2>/dev/null) || base=0
    n=0
    while [ "$n" -lt "$STALL_CAP_TICKS" ]; do
        if ! kill -0 "$1" 2>/dev/null; then wait "$1"; rc=$?; return; fi
        seen=$(( $(wc -c < "$STUB/ticks" 2>/dev/null || echo 0) - base ))
        [ "$seen" -ge "$want" ] && break
        [ "$n" -ge "$NO_SAMPLE_CUTOFF_TICKS" ] && [ "$seen" -eq 0 ] && break
        sleep 0.1; n=$((n + 1))
    done
    kill -0 "$1" 2>/dev/null || { wait "$1"; rc=$?; return; }
    rc=running
}
new_inbox() { mkdir -p "$WORK/$1/consoles"; : > "$WORK/$1/consoles/c.md"; printf '%s' "$WORK/$1/consoles/c.md"; }
start() { # <inbox> <outfile> [tick args...]
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

reset_stub
I="$(new_inbox wx)"
start "$I" "$WORK/wx.out" --workers "N1.md"
wait_hb "$I" || fail "(wx) no baseline heartbeat"
wx0=$(wc -c < "$STUB/ticks")
wait_exit "$WPID"
wx1=$(wc -c < "$STUB/ticks")
check "(wx) a waiter with nothing to wake for is still running" "running" "$rc"
check "(wx) and the quiet window took 4 to 5 samples" "yes" "$([ $((wx1 - wx0)) -ge 4 ] && [ $((wx1 - wx0)) -le 5 ] && echo yes || echo "no: $((wx1 - wx0))")"
stop_waiter "$WPID"

# tracker_line is shared with the (w) block in test-chief-wait-d.sh.
tracker_line() { sed "s/ denials=none/ tracker=$1 denials=none/" "$STUB/tick.line" > "$STUB/tick.line.tmp" && mv "$STUB/tick.line.tmp" "$STUB/tick.line"; }

# --- (v) vmrun= wakes only on a class move TO DEAD / STUCK / DISAGREE; the
# busy count moving, a move back to ok/off and an absent field never wake. ----
vmrun_line() { sed "s#  *denials=none# vmrun=$1 denials=none#" "$STUB/tick.line" > "$STUB/tick.line.tmp" && mv "$STUB/tick.line.tmp" "$STUB/tick.line"; }
reset_stub
vmrun_line ok:2/2,busy=0
I="$(new_inbox vm)"
start "$I" "$WORK/vm.out" --workers "N1.md"
wait_hb "$I" || fail "(vm) no baseline heartbeat"
tick_line "N1:FRESH" "ok"
vmrun_line ok:2/2,busy=2
wait_exit "$WPID"
check "(vm) a busy-count move alone does not wake" "running" "$rc"
tick_line "N1:FRESH" "ok"
vmrun_line DEAD
wait_exit "$WPID"
check "(vm) a vmrun move to DEAD ends the wait" "0" "$rc"
check "(vm) the wake names vmrun" "WAKE tick changed=vmrun usage=PROCEED" "$(head -n1 "$WORK/vm.out")"

reset_stub
vmrun_line DEAD
I="$(new_inbox vm2)"
start "$I" "$WORK/vm2.out" --workers "N1.md"
wait_hb "$I" || fail "(vm2) no baseline heartbeat"
tick_line "N1:FRESH" "ok"
vmrun_line ok:1/2,busy=0
wait_exit "$WPID"
check "(vm2) a vmrun move back to ok alone does not wake" "running" "$rc"
stop_waiter "$WPID"

reset_stub
vmrun_line ok:2/2,busy=0
I="$(new_inbox vm3)"
start "$I" "$WORK/vm3.out" --workers "N1.md"
wait_hb "$I" || fail "(vm3) no baseline heartbeat"
tick_line "N1:FRESH" "ok"
vmrun_line DISAGREE:2/2,online=0
wait_exit "$WPID"
check "(vm3) a vmrun move to DISAGREE ends the wait" "0" "$rc"
check "(vm3) the DISAGREE wake names vmrun" "WAKE tick changed=vmrun usage=PROCEED" "$(head -n1 "$WORK/vm3.out")"
[ "$rc" = running ] && { stop_waiter "$WPID"; }

reset_stub
vmrun_line ok:2/2,busy=0
I="$(new_inbox vm3b)"
start "$I" "$WORK/vm3b.out" --workers "N1.md"
wait_hb "$I" || fail "(vm3b) no baseline heartbeat"
tick_line "N1:FRESH" "ok"
vmrun_line DISAGREE:2/2,online=1
wait_exit "$WPID"
check "(vm3b) a vmrun move to a partial-outage DISAGREE ends the wait" "0" "$rc"
check "(vm3b) the partial-outage DISAGREE wake names vmrun" "WAKE tick changed=vmrun usage=PROCEED" "$(head -n1 "$WORK/vm3b.out")"
[ "$rc" = running ] && { stop_waiter "$WPID"; }

for recovery in ok:2/2,busy=0 off FAILING; do
    reset_stub
    vmrun_line DISAGREE:2/2,online=0
    I="$(new_inbox "vm-recover-$recovery")"
    start "$I" "$WORK/vm-recover.out" --workers "N1.md"
    wait_hb "$I" || fail "(vm-recover) no baseline heartbeat"
    tick_line "N1:FRESH" "ok"
    vmrun_line "$recovery"
    wait_exit "$WPID"
    check "(vm-recover) DISAGREE to $recovery alone does not wake" "running" "$rc"
    check "(vm-recover) DISAGREE to $recovery emits nothing" "" "$(cat "$WORK/vm-recover.out")"
    stop_waiter "$WPID"
done

# --- (pk) parked= wakes when a worker joins the parked set; the growing age alone
# never wakes; a tick line with no parked= field stays a valid sample. ---------
parked_line() { sed "s#  *denials=none# parked=$1 denials=none#" "$STUB/tick.line" > "$STUB/tick.line.tmp" && mv "$STUB/tick.line.tmp" "$STUB/tick.line"; }
reset_stub
parked_line N1:6m
I="$(new_inbox pk)"
start "$I" "$WORK/pk.out" --workers "N1.md"
wait_hb "$I" || fail "(pk) no baseline heartbeat"
tick_line "N1:FRESH" "ok"
parked_line N1:9m
wait_exit "$WPID"
check "(pk) the age growing alone does not wake" "running" "$rc"
stop_waiter "$WPID"

reset_stub
I="$(new_inbox pk2)"
start "$I" "$WORK/pk2.out" --workers "N1.md"
wait_hb "$I" || fail "(pk2) no baseline heartbeat"
tick_line "N1:FRESH" "ok"
parked_line N1:6m
wait_exit "$WPID"
check "(pk2) a worker joining the parked set ends the wait" "0" "$rc"
check "(pk2) the wake names parked" "WAKE tick changed=parked usage=PROCEED" "$(head -n1 "$WORK/pk2.out")"

# the same workers parked in a different order is not a membership change
reset_stub
parked_line N1:6m,N2:7m
I="$(new_inbox pk4)"
start "$I" "$WORK/pk4.out" --workers "N1.md"
wait_hb "$I" || fail "(pk4) no baseline heartbeat"
tick_line "N1:FRESH" "ok"
parked_line N2:7m,N1:6m
wait_exit "$WPID"
check "(pk4) a reordered parked set does not wake" "running" "$rc"
stop_waiter "$WPID"

# a worker LEAVING the parked set (the field disappears) wakes too
reset_stub
parked_line N1:6m
I="$(new_inbox pk3)"
start "$I" "$WORK/pk3.out" --workers "N1.md"
wait_hb "$I" || fail "(pk3) no baseline heartbeat"
tick_line "N1:FRESH" "ok"
sed 's# parked=[^ ]*##' "$STUB/tick.line" > "$STUB/tick.line.tmp" && mv "$STUB/tick.line.tmp" "$STUB/tick.line"
wait_exit "$WPID"
check "(pk3) a worker leaving the parked set ends the wait" "0" "$rc"
check "(pk3) the wake names parked" "WAKE tick changed=parked usage=PROCEED" "$(head -n1 "$WORK/pk3.out")"

# --- (m3748) a worker-set change made through --workers-from is a silent baseline --
# with --workers-from the argv never changes, so the waiter folds the
# manifest's worker list into its args hash each sample. A dispatch (manifest add)
# that moves workers=/tails= is the chief's own act -- a silent baseline, the
# same as a restart with new --workers -- while a real change on the same worker set
# still wakes. RED control (chief-wait.sh before this change): the dispatch
# below woke with changed=workers.
reset_stub
I="$(new_inbox m3748)"
M="$WORK/m3748/console.fleet.json"
printf '{"schema":1,"workers":[{"doc":"/x/HIMMEL-1-N1-a.md","label":"N1"}]}\n' > "$M"
start "$I" "$WORK/m3748.out" --workers-from "$M"
wait_hb "$I" || fail "(m3748) no baseline heartbeat"
# The stub tick ignores the manifest, so its line moves first: a sample
# between the two writes sees a changed key under the OLD worker set (pending,
# not yet a wake), and the next one sees the new worker set and re-baselines.
tick_line "N1:FRESH,N2:FRESH" "ok"
printf '{"schema":1,"workers":[{"doc":"/x/HIMMEL-1-N1-a.md","label":"N1"},{"doc":"/x/HIMMEL-2-N2-b.md","label":"N2"}]}\n' > "$M"
sleep 2
wait_exit "$WPID"
check "(m3748) a dispatch through the manifest does not wake the console" "running" "$rc"
check "(m3748) and prints nothing" "" "$(cat "$WORK/m3748.out")"
# A remove + re-add reorders the manifest, and tick prints workers in manifest
# order: the same set in a new order is the chief's own act too.
tick_line "N2:FRESH,N1:FRESH" "ok"
printf '{"schema":1,"workers":[{"doc":"/x/HIMMEL-2-N2-b.md","label":"N2"},{"doc":"/x/HIMMEL-1-N1-a.md","label":"N1"}]}\n' > "$M"
sleep 2
wait_exit "$WPID"
check "(m3748) a reorder through the manifest does not wake the console" "running" "$rc"
check "(m3748) and still prints nothing" "" "$(cat "$WORK/m3748.out")"
tick_line "N2:FREE,N1:FRESH" "ok"
wait_exit "$WPID"
check "(m3748) a real change on the new worker set still wakes (rc 0)" "0" "$rc"
check "(m3748) naming workers" "WAKE tick changed=workers usage=PROCEED" "$(head -n1 "$WORK/m3748.out")"
stop_waiter "$WPID"

# --- (m1a) the same manifest dispatch with a `workers` array reads like the old `legs` one;
# with HIMMEL_LEGACY_NAMES=0 an old `legs` manifest yields no worker list, so the dispatch wakes.
reset_stub
I="$(new_inbox m1aw)"
M="$WORK/m1aw/console.fleet.json"
printf '{"schema":1,"workers":[{"doc":"/x/HIMMEL-1-N1-a.md","label":"N1"}]}\n' > "$M"
start "$I" "$WORK/m1aw.out" --workers-from "$M"
wait_hb "$I" || fail "(m1a) no baseline heartbeat on a workers manifest"
tick_line "N1:FRESH,N2:FRESH" "ok"
printf '{"schema":1,"workers":[{"doc":"/x/HIMMEL-1-N1-a.md","label":"N1"},{"doc":"/x/HIMMEL-2-N2-b.md","label":"N2"}]}\n' > "$M"
sleep 2
wait_exit "$WPID"
check "(m1a) a dispatch through a workers manifest does not wake the console" "running" "$rc"
check "(m1a) a workers manifest dispatch prints nothing" "" "$(cat "$WORK/m1aw.out")"
tick_line "N2:FREE,N1:FRESH" "ok"
wait_exit "$WPID"
check "(m1a) a real change on a workers manifest still wakes (rc 0)" "0" "$rc"
check "(m1a) and names workers" "WAKE tick changed=workers usage=PROCEED" "$(head -n1 "$WORK/m1aw.out")"
stop_waiter "$WPID"
reset_stub
I="$(new_inbox m1aoff)"
M="$WORK/m1aoff/console.fleet.json"
printf '{"schema":1,"legs":[{"doc":"/x/HIMMEL-1-N1-a.md","label":"N1"}]}\n' > "$M"
HIMMEL_LEGACY_NAMES=0 start "$I" "$WORK/m1aoff.out" --workers-from "$M"
wait_hb "$I" || fail "(m1a) no baseline heartbeat with the switch off"
tick_line "N1:FRESH,N2:FRESH" "ok"
printf '{"schema":1,"legs":[{"doc":"/x/HIMMEL-1-N1-a.md","label":"N1"},{"doc":"/x/HIMMEL-2-N2-b.md","label":"N2"}]}\n' > "$M"
wait_exit "$WPID"
check "(m1a) with HIMMEL_LEGACY_NAMES=0 an old legs manifest is not read, so the dispatch wakes (rc 0)" "0" "$rc"
stop_waiter "$WPID"

# --- (l4568) a READY tail turning READY!stale (30 min, no GO file) is a wake
reset_stub
sed 's/ tails=N1:LIVE/ tails=N1:READY/' "$STUB/tick.line" > "$STUB/tick.line.tmp" && mv "$STUB/tick.line.tmp" "$STUB/tick.line"
I="$(new_inbox l4568)"
start "$I" "$WORK/l4568.out" --workers "N1.md"
wait_hb "$I" || fail "(l4568) no baseline heartbeat"
sed 's/ tails=N1:READY/ tails=N1:READY!stale/' "$STUB/tick.line" > "$STUB/tick.line.tmp" && mv "$STUB/tick.line.tmp" "$STUB/tick.line"
wait_exit "$WPID"
check "(l4568) a READY going stale wakes the console (rc 0)" "0" "$rc"
check "(l4568) the wake names tails" "WAKE tick changed=tails usage=PROCEED" "$(head -n1 "$WORK/l4568.out")"

# --- acts= moving (a new READY, a second BLOCKED) wakes, though tails= did not move
# RED control (pre-fix chief-wait.sh): acts= is not in the key, so the waiter stays asleep.
reset_stub
sed 's/ tails=N1:LIVE/ tails=N1:LIVE acts=N1:READY#1/' "$STUB/tick.line" > "$STUB/tick.line.tmp" && mv "$STUB/tick.line.tmp" "$STUB/tick.line"
I="$(new_inbox a6292)"
start "$I" "$WORK/a6292.out" --workers "N1.md"
wait_hb "$I" || fail "(a6292) no baseline heartbeat"
sed 's/ acts=N1:READY#1/ acts=N1:BLOCKED#2/' "$STUB/tick.line" > "$STUB/tick.line.tmp" && mv "$STUB/tick.line.tmp" "$STUB/tick.line"
wait_exit "$WPID"
check "(a6292) a new actionable bullet wakes the console (rc 0)" "0" "$rc"
check "(a6292) the wake names acts" "WAKE tick changed=acts usage=PROCEED" "$(head -n1 "$WORK/a6292.out")"
check "(a6292) and the tick line names the worker and marker" "1" "$(grep -c 'acts=N1:BLOCKED#2' "$WORK/a6292.out")"

# --- (u4959) a sustained capacity=UNDERFILLED wakes, once per streak
# tick.sh already folds TICK_UNDERFILL_MIN into capacity=; the waiter wakes on the
# first UNDERFILLED sample, prints the dispatchable list (stubbed here), and a
# re-arm during the same streak stays quiet until capacity returns to ok.
cat > "$STUB/dispatch.sh" <<'EOF2'
#!/usr/bin/env bash
printf 'LOCAL HIMMEL-9001 stub-ticket\n'
EOF2
export CHIEF_WAIT_DISPATCH="$STUB/dispatch.sh"
under_line() { sed "s/ capacity=[^ ]*/ capacity=$1/" "$STUB/tick.line" > "$STUB/tick.line.tmp" && mv "$STUB/tick.line.tmp" "$STUB/tick.line"; }
reset_stub
I="$(new_inbox u4959)"
start "$I" "$WORK/u4959.out" --workers "N1.md"
wait_hb "$I" || fail "(u4959) no baseline heartbeat"
under_line "UNDERFILLED:12"
wait_exit "$WPID"
check "(u4959) a sustained UNDERFILLED capacity wakes the console (rc 0)" "0" "$rc"
check "(u4959) the wake names the slack" "WAKE underfilled capacity=UNDERFILLED:12 pool=?" "$(head -n1 "$WORK/u4959.out")"
check "(u4959) the wake carries the dispatchable list" "yes" "$(grep -q "^LOCAL $KP-9001" "$WORK/u4959.out" && echo yes)"
timeout -k 5 4 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/u4959b.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(u4959) the re-arm in the same streak does not wake again" "" "$(cat "$WORK/u4959b.out")"
check "(u4959) and is still waiting (rc 124)" "124" "$rc"
under_line "ok"
timeout -k 5 3 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/u4959c.out" 2>/dev/null  # gnu-ok: Linux-only kit; pipefail-ok: none set
under_line "UNDERFILLED:5"
start "$I" "$WORK/u4959d.out" --workers "N1.md"
wait_exit "$WPID"
check "(u4959) a new streak after capacity returned to ok wakes again" "WAKE underfilled capacity=UNDERFILLED:5 pool=?" "$(head -n1 "$WORK/u4959d.out")"
reset_stub
I="$(new_inbox u4959u)"
under_line "unknown"
timeout -k 5 3 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/u4959e.out" 2>/dev/null  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(u4959) capacity=unknown (failed census) never wakes" "" "$(cat "$WORK/u4959e.out")"

# the manifest reaches the dispatch command, so live workers' files join the collision check
printf '#!/usr/bin/env bash\nprintf "ARGS %%s\\n" "$*"\n' > "$STUB/dispatch.sh"
reset_stub
I="$(new_inbox u4959m)"
start "$I" "$WORK/u4959m.out" --workers-from "$WORK/u4959-fleet.json"
wait_hb "$I" || fail "(u4959) no baseline heartbeat (manifest)"
under_line "UNDERFILLED:7"
wait_exit "$WPID"
check "(u4959) the dispatch command receives the slack as --top, then --workers-from" "ARGS --priority-pool-only --dispositions --top 7 --workers-from $WORK/u4959-fleet.json" "$(grep '^ARGS' "$WORK/u4959m.out")"
reset_stub
I="$(new_inbox u4959d)"
printf '# console\n' > "$WORK/u4959-chief.md"
start "$I" "$WORK/u4959n.out" --doc "$WORK/u4959-chief.md" --workers-from "$WORK/u4959-fleet.json"
wait_hb "$I" || fail "(u4959) no baseline heartbeat (doc)"
under_line "UNDERFILLED:7"
wait_exit "$WPID"
check "(u4959) the dispatch command receives the console doc for the priority line" "ARGS --priority-pool-only --dispositions --top 7 --doc $WORK/u4959-chief.md --workers-from $WORK/u4959-fleet.json" "$(grep '^ARGS' "$WORK/u4959n.out")"

# --- (6478) an empty priority pool falls through to the version backlog: a second pass without --priority-pool-only
cat > "$STUB/dispatch.sh" <<'EOF2'
#!/usr/bin/env bash
case " $* " in
    *" --priority-pool-only "*) printf '# pool=0/7,LOW\nPOOL-EMPTY\n' ;;
    *) printf 'LOCAL\tHIMMEL-9002\tbacklog-ticket args=%s\n' "$*" ;;
esac
EOF2
reset_stub
I="$(new_inbox u6478)"
start "$I" "$WORK/u6478.out" --workers-from "$WORK/u4959-fleet.json"
wait_hb "$I" || fail "(6478) no baseline heartbeat"
under_line "UNDERFILLED:7"
wait_exit "$WPID"
check "(6478) an empty priority pool still prints POOL-EMPTY" "1" "$(grep -c '^POOL-EMPTY' "$WORK/u6478.out")"
check "(6478) an empty priority pool prints the version backlog from a second pass" "1" "$(grep -c "^LOCAL.$KP-9002" "$WORK/u6478.out")"
check "(6478) the second pass keeps --top and --workers-from but drops --priority-pool-only" "args=--top 7 --workers-from $WORK/u4959-fleet.json" "$(grep -o 'args=.*' "$WORK/u6478.out")"
printf '#!/usr/bin/env bash\nprintf "ARGS %%s\\n" "$*"\n' > "$STUB/dispatch.sh"

# --- (u5542) unowned-prs=: the first sight of an open PR with no live
# owner wakes the waiter once, a PR that joins the set wakes it, the same set wakes
# again only after CHIEF_WAIT_UNOWNED_REWAKE_MIN, and the marker clears once the
# field has read none twice. The field is not in the action key, so its growing
# age never wakes by itself. RED control (chief-wait.sh before this change): none
# of these woke ("running"). ------------------------------------------------------
unowned_line() { sed -e "s/ unowned-prs=[^ ]*//" -e "s/ bank=/ unowned-prs=$1 bank=/" "$STUB/tick.line" > "$STUB/tick.line.tmp" && mv "$STUB/tick.line.tmp" "$STUB/tick.line"; }
export HOUSEKEEPING_DIGEST_SECS=0  # 8934: these rows prove the marker logic on the unbatched path; the digest rows are in test-chief-wait.sh and test-chief-wait-pool.sh
reset_stub
unowned_line "#2575:120m"
I="$(new_inbox y)"
start "$I" "$WORK/y.out" --workers "N1.md"
wait_exit "$WPID"
check "(u5542) a PR with no live owner wakes on first sight" "0" "$rc"
check "(u5542) the wake names the PR and its age" "WAKE unowned-prs #2575:120m" "$(head -n1 "$WORK/y.out")"

HOUSEKEEPING_DIGEST_SECS=0 start "$I" "$WORK/y2.out" --workers "N1.md"  # 8197: with the digest on, a same-set re-wake joins the digest (test-chief-wait-pool.sh)
wait_hb "$I" || fail "(u5542-2) no baseline heartbeat"
unowned_line "#2575:121m"
wait_exit "$WPID"
check "(u5542-2) the same PR, older, does not wake again inside the re-wake window" "running" "$rc"
touch -d '2 hours ago' "$I.wait.unowned"
wait_exit "$WPID"
check "(u5542-2) the same PR wakes again after the re-wake window" "0" "$rc"
check "(u5542-2) the re-wake names the PR" "WAKE unowned-prs #2575:121m" "$(head -n1 "$WORK/y2.out")"

start "$I" "$WORK/y3.out" --workers "N1.md"
wait_hb "$I" || fail "(u5542-3) no baseline heartbeat"
unowned_line "#2575:130m,#2600:15m"
wait_exit "$WPID"
check "(u5542-3) a PR joining the unowned set wakes at once" "WAKE unowned-prs #2575:130m,#2600:15m" "$(head -n1 "$WORK/y3.out")"

unowned_line "none"
start "$I" "$WORK/y4.out" --workers "N1.md"
wait_hb "$I" || fail "(u5542-4) no baseline heartbeat"
n=0
while [ "$n" -lt 50 ] && [ -e "$I.wait.unowned" ]; do sleep 0.1; n=$((n + 1)); done
check "(u5542-4) unowned-prs=none twice clears the marker" "" "$([ -e "$I.wait.unowned" ] && echo present)"
unowned_line "#2575:140m"
wait_exit "$WPID"
check "(u5542-4) a PR that turns unowned again wakes at once" "WAKE unowned-prs #2575:140m" "$(head -n1 "$WORK/y4.out")"

unowned_line "#2575:150m,#2600:25m"
start "$I" "$WORK/y6.out" --workers "N1.md"
wait_hb "$I" || fail "(u5542-6) no baseline heartbeat"
wait_exit "$WPID"
unowned_line "#2575:151m"
start "$I" "$WORK/y6b.out" --workers "N1.md"
wait_hb "$I" || fail "(u5542-6) no second baseline heartbeat"
sleep 1
unowned_line "#2575:152m,#2600:26m"
wait_exit "$WPID"
check "(u5542-6) a PR that leaves and rejoins a non-empty set wakes at once" "WAKE unowned-prs #2575:152m,#2600:26m" "$(head -n1 "$WORK/y6b.out")"

unowned_line "#2575:160m"
start "$I" "$WORK/y7.out" --workers "N1.md"
wait_hb "$I" || fail "(u5542-7) no baseline heartbeat"
wait_exit "$WPID"
unowned_line "?"
start "$I" "$WORK/y7b.out" --workers "N1.md"
wait_hb "$I" || fail "(u5542-7) no second baseline heartbeat"
sleep 1
check "(u5542-7) unowned-prs=? neither clears the marker nor wakes" "present" "$([ -e "$I.wait.unowned" ] && echo present)"
stop_waiter "$WPID"

reset_stub
I="$(new_inbox y5)"
start "$I" "$WORK/y5.out" --workers "N1.md"
wait_hb "$I" || fail "(u5542-5) no baseline heartbeat"
wait_exit "$WPID"
check "(u5542-5) a tick line with no unowned-prs= field is still a valid sample" "running" "$rc"
stop_waiter "$WPID"
unset HOUSEKEEPING_DIGEST_SECS

# --- (7811) procs=...,unwatched=: a live worker the manifest does not list wakes the
# waiter once on first sight, again when another joins, and again only after
# CHIEF_WAIT_UNWATCHED_REWAKE_MIN. RED control (chief-wait.sh before this change): none woke.
unwatched_line() { sed -e "s/ procs=[^ ]*/ procs=$1/" "$STUB/tick.line" > "$STUB/tick.line.tmp" && mv "$STUB/tick.line.tmp" "$STUB/tick.line"; }
reset_stub
unwatched_line "1,unwatched=N302+N303"
I="$(new_inbox w7811)"
start "$I" "$WORK/w7811.out" --workers "N1.md"
wait_exit "$WPID"
check "(7811) a live worker outside the manifest wakes on first sight" "0" "$rc"
check "(7811) the wake names the unwatched labels" "WAKE unwatched N302+N303" "$(head -n1 "$WORK/w7811.out")"

start "$I" "$WORK/w7811b.out" --workers "N1.md"
wait_hb "$I" || fail "(7811-2) no baseline heartbeat"
wait_exit "$WPID"
check "(7811-2) the same set does not wake again inside the re-wake window" "running" "$rc"
unwatched_line "1,unwatched=N302+N303+N304"
wait_exit "$WPID"
check "(7811-2) another unwatched worker joining wakes at once" "WAKE unwatched N302+N303+N304" "$(head -n1 "$WORK/w7811b.out")"

start "$I" "$WORK/w7811d.out" --workers "N1.md"
wait_hb "$I" || fail "(7811-4) no baseline heartbeat"
wait_exit "$WPID"
check "(7811-4) the same set is quiet before the re-wake window ends" "running" "$rc"
touch -d '2 hours ago' "$I.wait.unwatched"
wait_exit "$WPID"
check "(7811-4) the same set wakes again after the re-wake window" "0" "$rc"
check "(7811-4) the re-wake names the labels" "WAKE unwatched N302+N303+N304" "$(head -n1 "$WORK/w7811d.out")"

unwatched_line "1"
start "$I" "$WORK/w7811e.out" --workers "N1.md"
wait_hb "$I" || fail "(7811-5) no baseline heartbeat"
n=0
while [ "$n" -lt 50 ] && [ -e "$I.wait.unwatched" ]; do sleep 0.1; n=$((n + 1)); done
check "(7811-5) a tick line that drops unwatched= clears the marker" "" "$([ -e "$I.wait.unwatched" ] && echo present)"
stop_waiter "$WPID"

# a failed census (procs=unknown) carries no unwatched= and must not clear the marker
unwatched_line "1,unwatched=N302+N303"
I="$(new_inbox w7811g)"
start "$I" "$WORK/w7811g.out" --workers "N1.md"
wait_exit "$WPID"
unwatched_line "unknown"
start "$I" "$WORK/w7811h.out" --workers "N1.md"
wait_hb "$I" || fail "(7811-6) no baseline heartbeat"
n=0
while [ "$n" -lt 30 ] && [ ! -e "$I.wait.unwatched" ]; do sleep 0.1; n=$((n + 1)); done
sleep 3
check "(7811-6) procs=unknown keeps the unwatched marker" "present" "$([ -e "$I.wait.unwatched" ] && echo present)"
stop_waiter "$WPID"

reset_stub
I="$(new_inbox w7811c)"
start "$I" "$WORK/w7811c.out" --workers "N1.md"
wait_hb "$I" || fail "(7811-3) no baseline heartbeat"
wait_exit "$WPID"
check "(7811-3) a tick line with no unwatched= is no wake" "running" "$rc"
stop_waiter "$WPID"

# --- (ts): a tracker that STAYS stale re-wakes once per streak ---
# tracker= class changes wake once (w); after the first STALE the class never moves
# again, so a chief that did not act stayed unwoken for hours. The marker
# <inbox>.wait.trackerstale holds the epoch the streak was first seen; it wakes once
# past CHIEF_WAIT_TRACKER_STALE_MIN (default 30) and clears when tracker leaves STALE.
reset_stub; tracker_line STALE:3h
I="$(new_inbox ts1)"
printf '%s\n' "$(( $(date +%s) - 2400 ))" > "$I.wait.trackerstale"
start "$I" "$WORK/ts1.out" --workers "N1.md"
wait_exit "$WPID"
check "(ts1) a tracker STALE for 40 min wakes (rc 0)" "0" "$rc"
check "(ts1) the wake names tracker-stale" "WAKE tracker-stale tracker=STALE:3h" "$(head -n1 "$WORK/ts1.out")"
timeout -k 5 3 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/ts1b.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(ts2) the re-arm inside the same streak stays quiet" "" "$(cat "$WORK/ts1b.out")"
check "(ts2) and is still waiting (rc 124)" "124" "$rc"
reset_stub; tracker_line STALE:5m
I="$(new_inbox ts3)"
timeout -k 5 3 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/ts3.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(ts3) a tracker first seen STALE does not re-wake yet" "" "$(cat "$WORK/ts3.out")"
check "(ts3) but the streak is recorded" "present" "$([ -e "$I.wait.trackerstale" ] && echo present)"
reset_stub; tracker_line ok
timeout -k 5 3 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/ts4.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(ts4) tracker back to ok clears the streak marker" "absent" "$([ -e "$I.wait.trackerstale" ] && echo present || echo absent)"

reset_stub; tracker_line STALE:3h
I="$(new_inbox ts5)"
printf '%s\n' "$(( $(date +%s) - 2400 ))" > "$I.wait.trackerstale"
CHIEF_WAIT_TRACKER_STALE_MIN=08 start "$I" "$WORK/ts5.out" --workers "N1.md"
wait_exit "$WPID"
check "(ts5) a leading-zero threshold (08) is decimal, not an octal error" "WAKE tracker-stale tracker=STALE:3h" "$(head -n1 "$WORK/ts5.out")"

# --- (bs): a board that STAYS stale re-wakes once per streak, like (ts) ---
# <inbox>.wait.boardstale holds the epoch the streak was first seen; it wakes once
# past CHIEF_WAIT_BOARD_STALE_MIN (default 10) and clears when board leaves STALE.
reset_stub; tick_line "N1:FRESH" "STALE:2h"
I="$(new_inbox bs1)"
printf '%s\n' "$(( $(date +%s) - 900 ))" > "$I.wait.boardstale"
HOUSEKEEPING_DIGEST_SECS=0 start "$I" "$WORK/bs1.out" --workers "N1.md"
wait_exit "$WPID"
check "(bs1) a board STALE for 15 min wakes (rc 0)" "0" "$rc"
check "(bs1) the wake names board-stale" "WAKE board-stale board=STALE:2h" "$(head -n1 "$WORK/bs1.out")"
timeout -k 5 3 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/bs1b.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(bs2) the re-arm inside the same streak stays quiet" "" "$(cat "$WORK/bs1b.out")"
check "(bs2) and is still waiting (rc 124)" "124" "$rc"
reset_stub; tick_line "N1:FRESH" "STALE:1m"
I="$(new_inbox bs3)"
timeout -k 5 3 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/bs3.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(bs3) a board first seen STALE does not re-wake yet" "" "$(cat "$WORK/bs3.out")"
check "(bs3) but the streak is recorded" "present" "$([ -e "$I.wait.boardstale" ] && echo present)"
reset_stub
timeout -k 5 3 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/bs4.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(bs4) board back to ok clears the streak marker" "absent" "$([ -e "$I.wait.boardstale" ] && echo present || echo absent)"

# --- (pc): the waiter closes a wrapped predecessor chief -------
# The chief doc's first line names its predecessor (`successor to <doc>.md`). The
# waiter runs close-wrapped-worker.sh --chief on it once, logs a Results bullet; exit
# 6/7 retry on the next sample; an unfinished predecessor (3 lock held, 4 not WRAPPED)
# is left alone; any other refusal wakes the chief once (WAKE predecessor-open).
cat > "$STUB/close.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB/close.calls"
n="$(wc -l < "$STUB/close.calls" | tr -d ' ')"
rc="$(sed -n "${n}p" "$STUB/close.rcs" 2>/dev/null)"; [ -n "$rc" ] || rc="$(tail -n 1 "$STUB/close.rcs")"
[ -z "$rc" ] || [ "$rc" -eq 0 ] || { [ -f "$STUB/close.msg" ] && cat "$STUB/close.msg" >&2 || echo "close-wrapped-worker: refusing - stub rc $rc" >&2; }
exit "${rc:-0}"
EOF
export CHIEF_WAIT_CLOSE="$STUB/close.sh"
pc_console() { # <dir name>: fixture console doc naming predecessor AS.md; prints the console doc path
    mkdir -p "$WORK/$1"
    printf '# AT — CHIEF — successor to AS.md (fill signal 45 %%)\n\n## Results (newest at the bottom)\n\n- 10:00 LIVE AT\n' > "$WORK/$1/AT.md"
    printf '# AS\n\n## Results (newest at the bottom)\n\n- 09:00 WRAPPED\n' > "$WORK/$1/AS.md"
    : > "$STUB/close.calls"; printf '%s\n' "$2" > "$STUB/close.rcs"
    printf '%s' "$WORK/$1/AT.md"
}
reset_stub
CD="$(pc_console pc1 0)"; I="$(new_inbox pc1)"
timeout -k 5 4 bash "$WAIT" "$I" --doc "$CD" --workers "N1.md" > "$WORK/pc1.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(pc1) a wrapped predecessor is closed through close-wrapped-worker --chief, once" "--chief $WORK/pc1/AS.md" "$(cat "$STUB/close.calls")"
check "(pc1) the close logs a Results bullet in the console doc" "1" "$(tail -n +4 "$CD" | grep -c 'predecessor.*AS.*closed')"
check "(pc1) a closed predecessor is not a wake (still waiting, rc 124)" "124" "$rc"
reset_stub
CD="$(pc_console pc2 6)"; I="$(new_inbox pc2)"; printf '6\n0\n' > "$STUB/close.rcs"
timeout -k 5 6 bash "$WAIT" "$I" --doc "$CD" --workers "N1.md" > "$WORK/pc2.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(pc2) exit 6 (live subtree) retries on the next sample, then closes" "2" "$(wc -l < "$STUB/close.calls" | tr -d ' ')"
check "(pc2) a retryable refusal wakes nothing" "" "$(cat "$WORK/pc2.out")"
reset_stub
CD="$(pc_console pc3 5)"; I="$(new_inbox pc3)"
start "$I" "$WORK/pc3.out" --doc "$CD" --workers "N1.md"
wait_exit "$WPID"
check "(pc3) any other refusal wakes the console (rc 0)" "0" "$rc"
check "(pc3) the wake is WAKE predecessor-open" "WAKE predecessor-open rc=5" "$(head -n1 "$WORK/pc3.out")"
timeout -k 5 4 bash "$WAIT" "$I" --doc "$CD" --workers "N1.md" > "$WORK/pc3b.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(pc3) it wakes once: the re-arm is quiet" "" "$(cat "$WORK/pc3b.out")"
reset_stub
CD="$(pc_console pc4 3)"; I="$(new_inbox pc4)"; printf '3\n4\n' > "$STUB/close.rcs"
timeout -k 5 6 bash "$WAIT" "$I" --doc "$CD" --workers "N1.md" > "$WORK/pc4.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(pc4) a held-lock or not-WRAPPED predecessor is asked, then left alone: no wake" "" "$(cat "$WORK/pc4.out")"
check "(pc4) and nothing is logged" "0" "$(tail -n +4 "$CD" | grep -c 'predecessor')"
check "(pc4) and it is retried (the predecessor may wrap later)" "yes" "$([ "$(wc -l < "$STUB/close.calls" | tr -d ' ')" -ge 2 ] && echo yes)"
reset_stub
mkdir -p "$WORK/pc5"; printf '# AT — CHIEF — successor to none — first console of the chain\n\n## Results (newest at the bottom)\n' > "$WORK/pc5/AT.md"
: > "$STUB/close.calls"; I="$(new_inbox pc5)"
timeout -k 5 3 bash "$WAIT" "$I" --doc "$WORK/pc5/AT.md" --workers "N1.md" > "$WORK/pc5.out" 2>/dev/null
check "(pc5) a console with no predecessor doc closes nothing" "0" "$(wc -l < "$STUB/close.calls" | tr -d ' ')"
reset_stub
CD="$(pc_console pc6 5)"; I="$(new_inbox pc6)"
echo "close-wrapped-worker: refusing - 10 live session(s) matched worker names [x] (need exactly 1)" > "$STUB/close.msg"
start "$I" "$WORK/pc6.out" --doc "$CD" --workers "N1.md"
wait_exit "$WPID"
rm -f "$STUB/close.msg"
check "(pc6) 10 live sessions is not 0: the ambiguous refusal wakes" "WAKE predecessor-open rc=5" "$(head -n1 "$WORK/pc6.out")"
reset_stub
CD="$(pc_console pc7 0)"; I="$(new_inbox pc7)"
printf '#!/usr/bin/env bash\nexec sleep 30\n' > "$STUB/close.sleep.sh"; chmod +x "$STUB/close.sleep.sh"
CHIEF_WAIT_CLOSE="$STUB/close.sleep.sh" CHIEF_WAIT_CLOSE_TIMEOUT=1 start "$I" "$WORK/pc7.out" --doc "$CD" --workers "N1.md"
sleep 0.5
printf -- '- 03:45 [telegram from=1 chat=2] hello\n' >> "$I"
n=0
while [ "$n" -lt 100 ] && kill -0 "$WPID" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
check "(pc7) a hung close is killed at CHIEF_WAIT_CLOSE_TIMEOUT: the Telegram line still wakes within 10 s" "WAKE telegram" "$(head -n1 "$WORK/pc7.out")"
stop_waiter "$WPID"
reset_stub
CD="$(pc_console pc8 0)"; I="$(new_inbox pc8)"
CHIEF_WAIT_CLOSE="$STUB/close.sleep.sh" CHIEF_WAIT_CLOSE_TIMEOUT=1 CHIEF_WAIT_CLOSE_HANGS=2 start "$I" "$WORK/pc8.out" --doc "$CD" --workers "N1.md"
n=0
while [ "$n" -lt 300 ] && kill -0 "$WPID" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
check "(pc8) a close that hangs every sample wakes after CHIEF_WAIT_CLOSE_HANGS in a row" "WAKE predecessor-open rc=124" "$(head -n1 "$WORK/pc8.out")"
check "(pc8) and it is marked woke, so it wakes once" "woke:$WORK/pc8/AS.md" "$(cat "$I.wait.predecessor" 2>/dev/null)"
stop_waiter "$WPID"
reset_stub; tick_line "N1:FRESH" "STALE:2h"
CD="$(pc_console pc9 0)"; I="$(new_inbox pc9)"
printf '%s\n' "$(( $(date +%s) - 900 ))" > "$I.wait.boardstale"
HOUSEKEEPING_DIGEST_SECS=0 start "$I" "$WORK/pc9.out" --doc "$CD" --workers "N1.md"
wait_exit "$WPID"
stop_waiter "$WPID"
check "(pc9) a board-stale wake and a closable predecessor in one sample: the predecessor is closed" "--chief $WORK/pc9/AS.md" "$(cat "$STUB/close.calls")"
check "(pc9) and the board-stale wake still fires in that sample" "WAKE board-stale board=STALE:2h" "$(head -n1 "$WORK/pc9.out")"
check "(pc9) and the close is logged" "1" "$(tail -n +4 "$CD" | grep -c 'predecessor.*AS.*closed')"

cat > "$STUB/close-doc.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB/close.calls"
for a in "$@"; do d="$a"; done
[ ! -f "$STUB/sleep.$(basename "$d" .md)" ] || exec sleep 30
rc="$(cat "$STUB/rc.$(basename "$d" .md)" 2>/dev/null)"
[ -z "$rc" ] || [ "$rc" -eq 0 ] || { [ -f "$STUB/close.msg" ] && cat "$STUB/close.msg" >&2 || echo "close-wrapped-worker: refusing - stub rc $rc" >&2; }
exit "${rc:-0}"
EOF
cat > "$STUB/pgrep.sh" <<'EOF'
#!/usr/bin/env bash
ls "$CLAUDE_SESSIONS_PROC"
EOF
chmod +x "$STUB/pgrep.sh"
sw_session() {
    mkdir -p "$SWPROC/$1"; printf 'claude\0-n\0%s\0--model\0opus\0' "$2" > "$SWPROC/$1/cmdline"
}
sw_doc() {
    printf '%s\n\n## Results (newest at the bottom)\n\n- 09:00 LIVE x\n- 09:30 %s x\n' "$3" "$4" > "$WORK/$1/$2.md"
    touch -d "${5:-10 minutes ago}" "$WORK/$1/$2.md"
}
SWPROC="$WORK/sw-proc"
export CHIEF_WAIT_SWEEP_MIN=5 CHIEF_WAIT_SWEEP_MAX=4
reset_stub; rm -f "$STUB"/rc.*
CD="$(pc_console cs1 0)"; I="$(new_inbox cs1)"
sw_doc cs1 AS '# AS — CHIEF — successor to AR.md (fill signal 45 %)' WRAPPED
sw_doc cs1 AR '# AR — CHIEF — successor to AQ.md (fill signal 45 %)' WRAPPED
sw_doc cs1 W1 '# HIMMEL-1 — a worker not in the manifest — worker W1' WRAPPED
sw_doc cs1 H1 '# HIMMEL-2 — a wrapped worker whose lock is held — worker H1' WRAPPED
sw_doc cs1 L1 '# HIMMEL-3 — a working worker — worker L1' LIVE
sw_doc cs1 Y1 '# HIMMEL-4 — a worker that wrapped a moment ago — worker Y1' WRAPPED now
echo 3 > "$STUB/rc.H1"
rm -rf "$SWPROC"; sw_session 101 AT; sw_session 102 AR; sw_session 103 W1-r2; sw_session 104 H1; sw_session 105 L1; sw_session 106 Y1
CLAUDE_SESSIONS_PROC="$SWPROC" CLAUDE_SESSIONS_PGREP="$STUB/pgrep.sh" CHIEF_WAIT_CLOSE="$STUB/close-doc.sh" \
    timeout -k 5 4 bash "$WAIT" "$I" --doc "$CD" --workers "N1.md" > "$WORK/cs1.out" 2>/dev/null; rc=$?
check "(cs1) the grand-predecessor chief (two links back) is closed through --chief, once" "1" "$(grep -cxF -- "--chief $WORK/cs1/AR.md" "$STUB/close.calls")"
check "(cs1) a WRAPPED worker not in the manifest is closed through the worker path" "yes" "$(grep -qxF -- "$WORK/cs1/W1.md" "$STUB/close.calls" && echo yes)"
check "(cs1) the named predecessor is still closed through --chief" "yes" "$(grep -qxF -- "--chief $WORK/cs1/AS.md" "$STUB/close.calls" && echo yes)"
check "(cs1) a held-lock doc is asked (rc 3)" "yes" "$(grep -qxF -- "$WORK/cs1/H1.md" "$STUB/close.calls" && echo yes)"
check "(cs1) and left alone: no marker for it, its neighbour W1 marked closed" "closed:$WORK/cs1/W1.md|" "$(grep -xF "closed:$WORK/cs1/W1.md" "$I.wait.predecessor")|$(grep -F "$WORK/cs1/H1.md" "$I.wait.predecessor")"
check "(cs1) a not-WRAPPED doc is never asked (its WRAPPED neighbours were)" "0" "$(grep -c 'L1' "$STUB/close.calls")"
check "(cs1) a doc that wrapped inside CHIEF_WAIT_SWEEP_MIN is not asked yet" "0" "$(grep -c 'Y1' "$STUB/close.calls")"
check "(cs1) the waiter's own console doc is never asked" "0" "$(grep -c 'AT.md' "$STUB/close.calls")"
check "(cs1) each close logs one Results bullet (AS, AR, W1), the held doc none" "3|0" "$(tail -n +4 "$CD" | grep -c 'closed its window')|$(tail -n +4 "$CD" | grep -c 'H1')"
check "(cs1) a sweep close is not a wake (still waiting, rc 124)" "124" "$rc"
reset_stub; rm -f "$STUB"/rc.*
mkdir -p "$WORK/cs2"; printf '# AT — CHIEF — successor to none — first console of the chain\n\n## Results (newest at the bottom)\n\n- 10:00 LIVE AT\n' > "$WORK/cs2/AT.md"
sw_doc cs2 W1 '# HIMMEL-1 — worker W1' WRAPPED
: > "$STUB/close.calls"; echo 5 > "$STUB/rc.W1"
echo "close-wrapped-worker: refusing - 2 live session(s) matched worker names [W1] (need exactly 1)" > "$STUB/close.msg"
rm -rf "$SWPROC"; sw_session 201 AT; sw_session 202 W1
I="$(new_inbox cs2)"
CLAUDE_SESSIONS_PROC="$SWPROC" CLAUDE_SESSIONS_PGREP="$STUB/pgrep.sh" CHIEF_WAIT_CLOSE="$STUB/close-doc.sh" \
    start "$I" "$WORK/cs2.out" --doc "$WORK/cs2/AT.md" --workers "N1.md"
wait_exit "$WPID"
stop_waiter "$WPID"
check "(cs2) an unexpected refusal on a swept doc wakes the chief (rc 0)" "0" "$rc"
check "(cs2) the wake is WAKE predecessor-open" "WAKE predecessor-open rc=5" "$(head -n1 "$WORK/cs2.out")"
CLAUDE_SESSIONS_PROC="$SWPROC" CLAUDE_SESSIONS_PGREP="$STUB/pgrep.sh" CHIEF_WAIT_CLOSE="$STUB/close-doc.sh" \
    timeout -k 5 4 bash "$WAIT" "$I" --doc "$WORK/cs2/AT.md" --workers "N1.md" > "$WORK/cs2b.out" 2>/dev/null; rc=$?
rm -f "$STUB/close.msg"
check "(cs2) it wakes once: the re-arm is quiet and asks it no more" "|1" "$(cat "$WORK/cs2b.out")|$(wc -l < "$STUB/close.calls" | tr -d ' ')"
reset_stub; rm -f "$STUB"/rc.*
mkdir -p "$WORK/cs3"; printf '# AT — CHIEF — successor to none — first console of the chain\n\n## Results (newest at the bottom)\n\n- 10:00 LIVE AT\n' > "$WORK/cs3/AT.md"
sw_doc cs3 H1 '# HIMMEL-2 — worker H1' WRAPPED
sw_doc cs3 H2 '# HIMMEL-3 — worker H2' WRAPPED
sw_doc cs3 W1 '# HIMMEL-1 — worker W1' WRAPPED
: > "$STUB/close.calls"; echo 3 > "$STUB/rc.H1"; echo 6 > "$STUB/rc.H2"
rm -rf "$SWPROC"; sw_session 301 H1; sw_session 302 H2; sw_session 303 W1
I="$(new_inbox cs3)"
CLAUDE_SESSIONS_PROC="$SWPROC" CLAUDE_SESSIONS_PGREP="$STUB/pgrep.sh" CHIEF_WAIT_CLOSE="$STUB/close-doc.sh" CHIEF_WAIT_SWEEP_MAX=1 \
    timeout -k 5 8 bash "$WAIT" "$I" --doc "$WORK/cs3/AT.md" --workers "N1.md" > "$WORK/cs3.out" 2>/dev/null; rc=$?
check "(cs3) refusals ahead in the census never starve a later candidate past CHIEF_WAIT_SWEEP_MAX" "yes" "$(grep -qxF -- "$WORK/cs3/W1.md" "$STUB/close.calls" && echo yes)"
check "(cs3) and the refused ones are still retried, more than once each" "yes|yes" "$([ "$(grep -cxF -- "$WORK/cs3/H1.md" "$STUB/close.calls")" -ge 2 ] && echo yes)|$([ "$(grep -cxF -- "$WORK/cs3/H2.md" "$STUB/close.calls")" -ge 2 ] && echo yes)"
reset_stub; rm -f "$STUB"/rc.* "$STUB"/sleep.*
mkdir -p "$WORK/cs4"; printf '# AT — CHIEF — successor to none — first console of the chain\n\n## Results (newest at the bottom)\n\n- 10:00 LIVE AT\n' > "$WORK/cs4/AT.md"
sw_doc cs4 G1 '# HIMMEL-1 — worker G1' WRAPPED
sw_doc cs4 G2 '# HIMMEL-2 — worker G2' WRAPPED
: > "$STUB/close.calls"; : > "$STUB/sleep.G1"; : > "$STUB/sleep.G2"
rm -rf "$SWPROC"; sw_session 401 G1; sw_session 402 G2
I="$(new_inbox cs4)"
CLAUDE_SESSIONS_PROC="$SWPROC" CLAUDE_SESSIONS_PGREP="$STUB/pgrep.sh" CHIEF_WAIT_CLOSE="$STUB/close-doc.sh" CHIEF_WAIT_SWEEP_MAX=1 CHIEF_WAIT_CLOSE_TIMEOUT=1 CHIEF_WAIT_CLOSE_HANGS=2 \
    start "$I" "$WORK/cs4.out" --doc "$WORK/cs4/AT.md" --workers "N1.md"
n=0
while [ "$n" -lt 300 ] && kill -0 "$WPID" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
stop_waiter "$WPID"
rm -f "$STUB"/sleep.*
check "(cs4) a hung close the rotation skips for a sample keeps its streak: two hangs in a row on it still wake" "WAKE predecessor-open rc=124" "$(head -n1 "$WORK/cs4.out")"
reset_stub; rm -f "$STUB"/rc.*
mkdir -p "$WORK/cs5"
sw_doc cs5 AT '# AT — CHIEF — successor to none — first console of the chain' WRAPPED
sw_doc cs5 W1 '# HIMMEL-1 — worker W1' WRAPPED
: > "$STUB/close.calls"
rm -rf "$SWPROC"; sw_session 501 AT; sw_session 502 W1
I="$(new_inbox cs5)"
CLAUDE_SESSIONS_PROC="$SWPROC" CLAUDE_SESSIONS_PGREP="$STUB/pgrep.sh" CHIEF_WAIT_CLOSE="$STUB/close-doc.sh" \
    timeout -k 5 4 bash "$WAIT" "$I" --doc "$WORK/cs5/AT.md" --workers "N1.md" > "$WORK/cs5.out" 2>/dev/null
check "(cs5) the waiter's own doc, WRAPPED and old with a live session of its name, is never asked; its neighbour W1 is" "0|yes" "$(grep -c 'AT.md' "$STUB/close.calls")|$(grep -qxF -- "$WORK/cs5/W1.md" "$STUB/close.calls" && echo yes)"
: > "$STUB/close.calls"; sw_doc cs5 AT '# AT — CHIEF — successor to none — first console of the chain' WRAPPED
I="$(new_inbox cs5b)"
(cd "$WORK/cs5" && CLAUDE_SESSIONS_PROC="$SWPROC" CLAUDE_SESSIONS_PGREP="$STUB/pgrep.sh" CHIEF_WAIT_CLOSE="$STUB/close-doc.sh" \
    timeout -k 5 4 bash "$WAIT" "$I" --doc AT.md --workers "N1.md" > "$WORK/cs5b.out" 2>/dev/null)
check "(cs5b) a relative --doc still excludes the waiter's own doc; its neighbour W1 is asked" "0|yes" "$(grep -c 'AT.md' "$STUB/close.calls")|$(grep -q 'W1.md$' "$STUB/close.calls" && echo yes)"
reset_stub; rm -f "$STUB"/rc.*
cat > "$STUB/close-tick.sh" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do d="$a"; done
printf '%s %s\n' "$(wc -c < "$STUB/ticks" 2>/dev/null || echo 0)" "$d" >> "$STUB/close.calls"
exit 3
EOF
mkdir -p "$WORK/cs6"; printf '# AT — CHIEF — successor to none — first console of the chain\n\n## Results (newest at the bottom)\n\n- 10:00 LIVE AT\n' > "$WORK/cs6/AT.md"
sw_doc cs6 H1 '# HIMMEL-1 — worker H1' WRAPPED
sw_doc cs6 H2 '# HIMMEL-2 — worker H2' WRAPPED
: > "$STUB/close.calls"
rm -rf "$SWPROC"; sw_session 601 H1; sw_session 602 H2
I="$(new_inbox cs6)"
CLAUDE_SESSIONS_PROC="$SWPROC" CLAUDE_SESSIONS_PGREP="$STUB/pgrep.sh" CHIEF_WAIT_CLOSE="$STUB/close-tick.sh" CHIEF_WAIT_SWEEP_MAX=1 \
    timeout -k 5 5 bash "$WAIT" "$I" --doc "$WORK/cs6/AT.md" --workers "N1.md" > "$WORK/cs6.out" 2>/dev/null
check "(cs6) CHIEF_WAIT_SWEEP_MAX=1 asks one doc per sample over several samples" "yes|" "$([ "$(wc -l < "$STUB/close.calls" | tr -d ' ')" -ge 2 ] && echo yes)|$(awk '{ print $1 }' "$STUB/close.calls" | sort | uniq -d)"
reset_stub; rm -f "$STUB"/rc.*
cat > "$STUB/close-hb.sh" <<'EOF'
#!/usr/bin/env bash
hb="$(sed -n 's/^hb=\([0-9]*\).*/\1/p' "$CS_HB")"
printf '%s\n' "$(( $(date +%s) - ${hb:-0} ))" >> "$STUB/hb.ages"
sleep 3
exit 3
EOF
mkdir -p "$WORK/cs7"; printf '# AT — CHIEF — successor to none — first console of the chain\n\n## Results (newest at the bottom)\n\n- 10:00 LIVE AT\n' > "$WORK/cs7/AT.md"
sw_doc cs7 H1 '# HIMMEL-1 — worker H1' WRAPPED
sw_doc cs7 H2 '# HIMMEL-2 — worker H2' WRAPPED
: > "$STUB/hb.ages"
rm -rf "$SWPROC"; sw_session 701 H1; sw_session 702 H2
I="$(new_inbox cs7)"
CS_HB="$I.wait" CLAUDE_SESSIONS_PROC="$SWPROC" CLAUDE_SESSIONS_PGREP="$STUB/pgrep.sh" CHIEF_WAIT_CLOSE="$STUB/close-hb.sh" \
    timeout -k 5 9 bash "$WAIT" "$I" --doc "$WORK/cs7/AT.md" --workers "N1.md" > "$WORK/cs7.out" 2>/dev/null
check "(cs7) the heartbeat is fresh before every close, also after a slow one in the same sample" "yes|0" "$([ "$(wc -l < "$STUB/hb.ages" | tr -d ' ')" -ge 2 ] && echo yes)|$(awk '$1 > 1' "$STUB/hb.ages" | wc -l | tr -d ' ')"
reset_stub; rm -f "$STUB"/rc.*
printf '#!/usr/bin/env bash\necho "CLOSED-ALREADY: W1 has no live session under [W1]; nothing to signal"\n' > "$STUB/close-gone.sh"
mkdir -p "$WORK/cs8"; printf '# AT — CHIEF — successor to none — first console of the chain\n\n## Results (newest at the bottom)\n\n- 10:00 LIVE AT\n' > "$WORK/cs8/AT.md"
sw_doc cs8 W1 '# HIMMEL-1 — worker W1' WRAPPED
rm -rf "$SWPROC"; sw_session 801 W1
I="$(new_inbox cs8)"
CLAUDE_SESSIONS_PROC="$SWPROC" CLAUDE_SESSIONS_PGREP="$STUB/pgrep.sh" CHIEF_WAIT_CLOSE="$STUB/close-gone.sh" \
    timeout -k 5 4 bash "$WAIT" "$I" --doc "$WORK/cs8/AT.md" --workers "N1.md" > "$WORK/cs8.out" 2>/dev/null
check "(cs8) a CLOSED-ALREADY answer is marked gone and logs no 'closed its window' bullet" "gone:$WORK/cs8/W1.md|0" "$(cat "$I.wait.predecessor" 2>/dev/null)|$(grep -c 'closed its window' "$WORK/cs8/AT.md")"
reset_stub; rm -f "$STUB"/rc.*
mkdir -p "$WORK/cs9"; printf '# AT — CHIEF — successor to none — first console of the chain\n\n## Results (newest at the bottom)\n\n- 10:00 LIVE AT\n' > "$WORK/cs9/AT.md"
sw_doc cs9 T-9-N9-task-2026-11-20 '# T-9 — a dated doc run under its undated session name — worker N9' WRAPPED
: > "$STUB/close.calls"
rm -rf "$SWPROC"; sw_session 901 T-9-N9-task
I="$(new_inbox cs9)"
CLAUDE_SESSIONS_PROC="$SWPROC" CLAUDE_SESSIONS_PGREP="$STUB/pgrep.sh" CHIEF_WAIT_CLOSE="$STUB/close-doc.sh" \
    timeout -k 5 4 bash "$WAIT" "$I" --doc "$WORK/cs9/AT.md" --workers "N1.md" > "$WORK/cs9.out" 2>/dev/null
check "(cs9) a dated doc under its undated session name is found and closed" "$WORK/cs9/T-9-N9-task-2026-11-20.md" "$(cat "$STUB/close.calls")"
unset CHIEF_WAIT_CLOSE CHIEF_WAIT_SWEEP_MIN CHIEF_WAIT_SWEEP_MAX

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
