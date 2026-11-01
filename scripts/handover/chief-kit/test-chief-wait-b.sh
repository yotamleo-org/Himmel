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
# Second half of the chief-wait suite: the (vmrun) cases onward. The first
# half is test-chief-wait.sh (cases up to (y4)).
#
# Run: bash scripts/handover/chief-kit/test-chief-wait-b.sh
set -u
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
[ -f "$STUB/tick.rc" ] && exit "$(cat "$STUB/tick.rc")"
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
# Nor does any test run the real status sweep or read a real FOCUS state: both seams answer nothing.
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/sweep-off.sh"
export WAIT_SWEEP_CMD="$STUB/sweep-off.sh" WAIT_FOCUS_CMD="$STUB/sweep-off.sh"

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
# wait_exit <pid>: wait at most ~8 s for the waiter to exit; sets rc to its
# exit code or "running". Not a $(...) helper: `wait` must run in the shell
# that started the waiter.
wait_exit() {
    n=0
    while [ "$n" -lt 80 ]; do
        if ! kill -0 "$1" 2>/dev/null; then wait "$1"; rc=$?; return; fi
        sleep 0.1; n=$((n + 1))
    done
    rc=running
}
new_inbox() { mkdir -p "$WORK/$1/consoles"; : > "$WORK/$1/consoles/c.md"; printf '%s' "$WORK/$1/consoles/c.md"; }
start() { # <inbox> <outfile> [tick args...]
    local inbox="$1" out="$2"; shift 2
    bash "$WAIT" "$inbox" "$@" > "$out" 2>"$out.err" &
    WPID=$!
}

# tracker_line is shared with the (w) block that stays in test-chief-wait.sh.
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
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

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
[ "$rc" = running ] && { kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; }

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
[ "$rc" = running ] && { kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; }

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
    kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
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
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

reset_stub
I="$(new_inbox pk2)"
start "$I" "$WORK/pk2.out" --workers "N1.md"
wait_hb "$I" || fail "(pk2) no baseline heartbeat"
tick_line "N1:FRESH" "ok"
parked_line N1:6m
wait_exit "$WPID"
check "(pk2) a leg joining the parked set ends the wait" "0" "$rc"
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
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# a worker LEAVING the parked set (the field disappears) wakes too
reset_stub
parked_line N1:6m
I="$(new_inbox pk3)"
start "$I" "$WORK/pk3.out" --workers "N1.md"
wait_hb "$I" || fail "(pk3) no baseline heartbeat"
tick_line "N1:FRESH" "ok"
sed 's# parked=[^ ]*##' "$STUB/tick.line" > "$STUB/tick.line.tmp" && mv "$STUB/tick.line.tmp" "$STUB/tick.line"
wait_exit "$WPID"
check "(pk3) a leg leaving the parked set ends the wait" "0" "$rc"
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
printf '{"schema":1,"legs":[{"doc":"/x/HIMMEL-1-N1-a.md","label":"N1"}]}\n' > "$M"
start "$I" "$WORK/m3748.out" --workers-from "$M"
wait_hb "$I" || fail "(m3748) no baseline heartbeat"
# The stub tick ignores the manifest, so its line moves first: a sample
# between the two writes sees a changed key under the OLD worker set (pending,
# not yet a wake), and the next one sees the new worker set and re-baselines.
tick_line "N1:FRESH,N2:FRESH" "ok"
printf '{"schema":1,"legs":[{"doc":"/x/HIMMEL-1-N1-a.md","label":"N1"},{"doc":"/x/HIMMEL-2-N2-b.md","label":"N2"}]}\n' > "$M"
sleep 2
wait_exit "$WPID"
check "(m3748) a dispatch through the manifest does not wake the console" "running" "$rc"
check "(m3748) and prints nothing" "" "$(cat "$WORK/m3748.out")"
# A remove + re-add reorders the manifest, and tick prints workers in manifest
# order: the same set in a new order is the chief's own act too.
tick_line "N2:FRESH,N1:FRESH" "ok"
printf '{"schema":1,"legs":[{"doc":"/x/HIMMEL-2-N2-b.md","label":"N2"},{"doc":"/x/HIMMEL-1-N1-a.md","label":"N1"}]}\n' > "$M"
sleep 2
wait_exit "$WPID"
check "(m3748) a reorder through the manifest does not wake the console" "running" "$rc"
check "(m3748) and still prints nothing" "" "$(cat "$WORK/m3748.out")"
tick_line "N2:FREE,N1:FRESH" "ok"
wait_exit "$WPID"
check "(m3748) a real change on the new leg set still wakes (rc 0)" "0" "$rc"
check "(m3748) naming legs" "WAKE tick changed=workers usage=PROCEED" "$(head -n1 "$WORK/m3748.out")"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

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
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
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
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

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
check "(a6292) and the tick line names the leg and marker" "1" "$(grep -c 'acts=N1:BLOCKED#2' "$WORK/a6292.out")"

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
check "(u4959) the wake carries the dispatchable list" "yes" "$(grep -q '^LOCAL HIMMEL-9001' "$WORK/u4959.out" && echo yes)"
timeout 4 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/u4959b.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(u4959) the re-arm in the same streak does not wake again" "" "$(cat "$WORK/u4959b.out")"
check "(u4959) and is still waiting (rc 124)" "124" "$rc"
under_line "ok"
timeout 3 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/u4959c.out" 2>/dev/null  # gnu-ok: Linux-only kit; pipefail-ok: none set
under_line "UNDERFILLED:5"
start "$I" "$WORK/u4959d.out" --workers "N1.md"
wait_exit "$WPID"
check "(u4959) a new streak after capacity returned to ok wakes again" "WAKE underfilled capacity=UNDERFILLED:5 pool=?" "$(head -n1 "$WORK/u4959d.out")"
reset_stub
I="$(new_inbox u4959u)"
under_line "unknown"
timeout 3 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/u4959e.out" 2>/dev/null  # gnu-ok: Linux-only kit; pipefail-ok: none set
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
check "(6478) an empty priority pool prints the version backlog from a second pass" "1" "$(grep -c '^LOCAL.HIMMEL-9002' "$WORK/u6478.out")"
check "(6478) the second pass keeps --top and --workers-from but drops --priority-pool-only" "args=--top 7 --workers-from $WORK/u4959-fleet.json" "$(grep -o 'args=.*' "$WORK/u6478.out")"
printf '#!/usr/bin/env bash\nprintf "ARGS %%s\\n" "$*"\n' > "$STUB/dispatch.sh"

# --- (u5542) unowned-prs=: the first sight of an open PR with no live
# owner wakes the waiter once, a PR that joins the set wakes it, the same set wakes
# again only after CHIEF_WAIT_UNOWNED_REWAKE_MIN, and the marker clears once the
# field has read none twice. The field is not in the action key, so its growing
# age never wakes by itself. RED control (chief-wait.sh before this change): none
# of these woke ("running"). ------------------------------------------------------
unowned_line() { sed -e "s/ unowned-prs=[^ ]*//" -e "s/ bank=/ unowned-prs=$1 bank=/" "$STUB/tick.line" > "$STUB/tick.line.tmp" && mv "$STUB/tick.line.tmp" "$STUB/tick.line"; }
reset_stub
unowned_line "#2575:120m"
I="$(new_inbox y)"
start "$I" "$WORK/y.out" --workers "N1.md"
wait_exit "$WPID"
check "(u5542) a PR with no live owner wakes on first sight" "0" "$rc"
check "(u5542) the wake names the PR and its age" "WAKE unowned-prs #2575:120m" "$(head -n1 "$WORK/y.out")"

start "$I" "$WORK/y2.out" --workers "N1.md"
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
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

reset_stub
I="$(new_inbox y5)"
start "$I" "$WORK/y5.out" --workers "N1.md"
wait_hb "$I" || fail "(u5542-5) no baseline heartbeat"
wait_exit "$WPID"
check "(u5542-5) a tick line with no unowned-prs= field is still a valid sample" "running" "$rc"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

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
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

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
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

reset_stub
I="$(new_inbox w7811c)"
start "$I" "$WORK/w7811c.out" --workers "N1.md"
wait_hb "$I" || fail "(7811-3) no baseline heartbeat"
wait_exit "$WPID"
check "(7811-3) a tick line with no unwatched= is no wake" "running" "$rc"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

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
timeout 3 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/ts1b.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(ts2) the re-arm inside the same streak stays quiet" "" "$(cat "$WORK/ts1b.out")"
check "(ts2) and is still waiting (rc 124)" "124" "$rc"
reset_stub; tracker_line STALE:5m
I="$(new_inbox ts3)"
timeout 3 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/ts3.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(ts3) a tracker first seen STALE does not re-wake yet" "" "$(cat "$WORK/ts3.out")"
check "(ts3) but the streak is recorded" "present" "$([ -e "$I.wait.trackerstale" ] && echo present)"
reset_stub; tracker_line ok
timeout 3 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/ts4.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
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
timeout 3 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/bs1b.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(bs2) the re-arm inside the same streak stays quiet" "" "$(cat "$WORK/bs1b.out")"
check "(bs2) and is still waiting (rc 124)" "124" "$rc"
reset_stub; tick_line "N1:FRESH" "STALE:1m"
I="$(new_inbox bs3)"
timeout 3 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/bs3.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(bs3) a board first seen STALE does not re-wake yet" "" "$(cat "$WORK/bs3.out")"
check "(bs3) but the streak is recorded" "present" "$([ -e "$I.wait.boardstale" ] && echo present)"
reset_stub
timeout 3 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/bs4.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
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
timeout 4 bash "$WAIT" "$I" --doc "$CD" --workers "N1.md" > "$WORK/pc1.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(pc1) a wrapped predecessor is closed through close-wrapped-worker --chief, once" "--chief $WORK/pc1/AS.md" "$(cat "$STUB/close.calls")"
check "(pc1) the close logs a Results bullet in the console doc" "1" "$(tail -n +4 "$CD" | grep -c 'predecessor.*AS.*closed')"
check "(pc1) a closed predecessor is not a wake (still waiting, rc 124)" "124" "$rc"
reset_stub
CD="$(pc_console pc2 6)"; I="$(new_inbox pc2)"; printf '6\n0\n' > "$STUB/close.rcs"
timeout 6 bash "$WAIT" "$I" --doc "$CD" --workers "N1.md" > "$WORK/pc2.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(pc2) exit 6 (live subtree) retries on the next sample, then closes" "2" "$(wc -l < "$STUB/close.calls" | tr -d ' ')"
check "(pc2) a retryable refusal wakes nothing" "" "$(cat "$WORK/pc2.out")"
reset_stub
CD="$(pc_console pc3 5)"; I="$(new_inbox pc3)"
start "$I" "$WORK/pc3.out" --doc "$CD" --workers "N1.md"
wait_exit "$WPID"
check "(pc3) any other refusal wakes the console (rc 0)" "0" "$rc"
check "(pc3) the wake is WAKE predecessor-open" "WAKE predecessor-open rc=5" "$(head -n1 "$WORK/pc3.out")"
timeout 4 bash "$WAIT" "$I" --doc "$CD" --workers "N1.md" > "$WORK/pc3b.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(pc3) it wakes once: the re-arm is quiet" "" "$(cat "$WORK/pc3b.out")"
reset_stub
CD="$(pc_console pc4 3)"; I="$(new_inbox pc4)"; printf '3\n4\n' > "$STUB/close.rcs"
timeout 6 bash "$WAIT" "$I" --doc "$CD" --workers "N1.md" > "$WORK/pc4.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(pc4) a held-lock or not-WRAPPED predecessor is asked, then left alone: no wake" "" "$(cat "$WORK/pc4.out")"
check "(pc4) and nothing is logged" "0" "$(tail -n +4 "$CD" | grep -c 'predecessor')"
check "(pc4) and it is retried (the predecessor may wrap later)" "yes" "$([ "$(wc -l < "$STUB/close.calls" | tr -d ' ')" -ge 2 ] && echo yes)"
reset_stub
mkdir -p "$WORK/pc5"; printf '# AT — CHIEF — successor to none — first console of the chain\n\n## Results (newest at the bottom)\n' > "$WORK/pc5/AT.md"
: > "$STUB/close.calls"; I="$(new_inbox pc5)"
timeout 3 bash "$WAIT" "$I" --doc "$WORK/pc5/AT.md" --workers "N1.md" > "$WORK/pc5.out" 2>/dev/null
check "(pc5) a console with no predecessor doc closes nothing" "0" "$(wc -l < "$STUB/close.calls" | tr -d ' ')"
reset_stub
CD="$(pc_console pc6 5)"; I="$(new_inbox pc6)"
echo "close-wrapped-worker: refusing - 10 live session(s) matched leg names [x] (need exactly 1)" > "$STUB/close.msg"
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
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
reset_stub
CD="$(pc_console pc8 0)"; I="$(new_inbox pc8)"
CHIEF_WAIT_CLOSE="$STUB/close.sleep.sh" CHIEF_WAIT_CLOSE_TIMEOUT=1 CHIEF_WAIT_CLOSE_HANGS=2 start "$I" "$WORK/pc8.out" --doc "$CD" --workers "N1.md"
n=0
while [ "$n" -lt 300 ] && kill -0 "$WPID" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
check "(pc8) a close that hangs every sample wakes after CHIEF_WAIT_CLOSE_HANGS in a row" "WAKE predecessor-open rc=124" "$(head -n1 "$WORK/pc8.out")"
check "(pc8) and it is marked woke, so it wakes once" "woke:$WORK/pc8/AS.md" "$(cat "$I.wait.predecessor" 2>/dev/null)"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
unset CHIEF_WAIT_CLOSE

# --- (su) --succession: the successor's one wake -----------------------------
# The tracker is stubbed (CHIEF_WAIT_TRACKER): it prints $STUB/su.out. The waiter
# itself only reads the COMPLETE / INCOMPLETE line and the clock.
reset_stub
# shellcheck disable=SC2016  # the stub body expands when the stub runs
printf '#!/usr/bin/env bash\ncat "$STUB/su.out"\n' > "$STUB/su-tracker.sh"
SUCD="$WORK/su-chief.md"; : > "$SUCD"
export CHIEF_WAIT_TRACKER="$STUB/su-tracker.sh" CHIEF_WAIT_SUCCESSION_SEC=1
printf 'N1 quoted-back\nN2 quoted-back\nCOMPLETE 2/2\nbash append-results.sh doc "LIVE - done"\n' > "$STUB/su.out"
I="$(new_inbox su1)"
start "$I" "$WORK/su1.out" --doc "$SUCD" --succession S2 --workers "N1.md"
wait_exit "$WPID"
check "(su1) every leg quoted back wakes once, rc 0" "0" "$rc"
check "(su1) the wake names the tally" "WAKE succession complete 2/2" "$(head -n1 "$WORK/su1.out")"
check "(su1) the block carries the printed LIVE command" "yes" "$(grep -q '^bash append-results.sh' "$WORK/su1.out" && echo yes)"
check "(su1) the exit reason is logged" "yes" "$(grep -q 'exit=wake-succession' "$I.wait" && echo yes)"

printf 'N1 quoted-back\nN2 missing\nINCOMPLETE 1/2 (waiting on: N2)\n' > "$STUB/su.out"
I="$(new_inbox su2)"
timeout 4 bash "$WAIT" "$I" --doc "$SUCD" --succession S2 --silent-min 5 --workers "N1.md" > "$WORK/su2.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(su2) a short tally inside the silent window stays quiet" "" "$(cat "$WORK/su2.out")"
check "(su2) and keeps waiting (rc 124)" "124" "$rc"

I="$(new_inbox su3)"
start "$I" "$WORK/su3.out" --doc "$SUCD" --succession S2 --silent-min 0 --workers "N1.md"
wait_exit "$WPID"
check "(su3) a tally silent past --silent-min wakes once, rc 0" "0" "$rc"
check "(su3) the partial wake names k/n and the window" "WAKE succession partial 1/2 silent 0 min" "$(head -n1 "$WORK/su3.out")"
check "(su3) the block names the leg still out" "yes" "$(grep -q 'waiting on: N2' "$WORK/su3.out" && echo yes)"

printf 'tracker blew up\n' > "$STUB/su.out"
I="$(new_inbox su3b)"
start "$I" "$WORK/su3b.out" --doc "$SUCD" --succession S2 --silent-min 0 --workers "N1.md"
wait_exit "$WPID"
check "(su3b) a tracker with no summary still wakes at the silence limit" "WAKE succession partial tracker-error silent 0 min" "$(head -n1 "$WORK/su3b.out")"

I="$(new_inbox su4)"
bash "$WAIT" "$I" --succession S2 >/dev/null 2>&1; rc=$?
check "(su4) --succession without --doc is a usage error (rc 2)" "2" "$rc"
bash "$WAIT" "$I" --doc "$SUCD" --succession 'bad name' >/dev/null 2>&1; rc=$?
check "(su4) a --succession that is not a session name is a usage error (rc 2)" "2" "$rc"
bash "$WAIT" "$I" --doc "$SUCD" --succession >/dev/null 2>&1; rc=$?
check "(su4) a trailing --succession with no value is a usage error (rc 2)" "2" "$rc"
bash "$WAIT" "$I" --doc "$SUCD" --succession S2 --silent-min >/dev/null 2>&1; rc=$?
check "(su4) a trailing --silent-min with no value is a usage error (rc 2)" "2" "$rc"
bash "$WAIT" "$I" --doc "$SUCD" --succession --silent-min 5 >/dev/null 2>&1; rc=$?
check "(su4) --succession followed by a flag is a usage error (rc 2)" "2" "$rc"

# a COMPLETE wake leaves a woke-record: a re-arm with the same --succession stays quiet
printf 'N1 quoted-back\nN2 quoted-back\nCOMPLETE 2/2\nbash append-results.sh doc "LIVE - done"\n' > "$STUB/su.out"
I="$(new_inbox su5)"
start "$I" "$WORK/su5a.out" --doc "$SUCD" --succession S2 --workers "N1.md"
wait_exit "$WPID"
check "(su5) first arm wakes once, rc 0" "0" "$rc"
timeout 4 bash "$WAIT" "$I" --doc "$SUCD" --succession S2 --workers "N1.md" > "$WORK/su5b.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(su5) a re-arm with the same --succession does not re-wake at once" "124" "$rc"
check "(su5) and prints no second wake" "" "$(cat "$WORK/su5b.out")"
unset CHIEF_WAIT_TRACKER CHIEF_WAIT_SUCCESSION_SEC

# --- (rol) <inbox>.relay-on-live: the outgoing chief's one wake ------------------
# Lock status and relay-batch are stubbed; the waiter reads only the lock rc (11 = held fresh).
reset_stub
# shellcheck disable=SC2016  # the stub bodies expand when the stub runs
printf '#!/usr/bin/env bash\nexit "$(cat "$STUB/rol.rc")"\n' > "$STUB/rol-lock.sh"
# shellcheck disable=SC2016  # as above
printf '#!/usr/bin/env bash\necho "SENDMESSAGE to=N1 :: relay to $3"\necho "RELAYED 1 of 1"\n' > "$STUB/rol-relay.sh"
export CHIEF_WAIT_LOCK_STATUS="$STUB/rol-lock.sh" CHIEF_WAIT_RELAY="$STUB/rol-relay.sh" CHIEF_WAIT_SUCCESSION_SEC=1
ROLD="$WORK/rol-chief.md"; : > "$ROLD"
echo 0 > "$STUB/rol.rc"
I="$(new_inbox rol1)"
printf 'S2\n%s\n' "$WORK/rol-succ.md" > "$I.relay-on-live"
timeout 4 bash "$WAIT" "$I" --doc "$ROLD" --workers "N1.md" > "$WORK/rol1.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(rol1) a successor with no held lock yields no wake (rc 124)" "124" "$rc"
check "(rol1) and the marker stays for the next sample" "yes" "$([ -s "$I.relay-on-live" ] && echo yes)"

echo 11 > "$STUB/rol.rc"
touch "$I.handover"
start "$I" "$WORK/rol2.out" --doc "$ROLD" --workers "N1.md"
wait_exit "$WPID"
check "(rol2) a held successor lock wakes once in handover mode, rc 0" "0" "$rc"
check "(rol2) the wake names the successor" "WAKE relay-on-live successor=S2" "$(head -n1 "$WORK/rol2.out")"
check "(rol2) the block carries the relay lines" "yes" "$(grep -q '^SENDMESSAGE to=N1' "$WORK/rol2.out" && echo yes)"
check "(rol2) the block ends with the RELAYED line, after the SENDMESSAGE lines it counts" "RELAYED 1 of 1" "$(tail -n1 "$WORK/rol2.out")"
check "(rol2) and it is printed once" "1" "$(grep -c '^RELAYED ' "$WORK/rol2.out")"
check "(rol2) the marker is consumed" "no" "$([ -e "$I.relay-on-live" ] && echo yes || echo no)"
check "(rol2) the exit reason is logged" "yes" "$(grep -q 'exit=wake-relay-on-live' "$I.wait" && echo yes)"

# a failing relay-batch wakes once with its rc and consumes the marker (no resend)
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUB/rol-relay.sh"
I="$(new_inbox rol3)"
printf 'S2\n%s\n' "$WORK/rol-succ.md" > "$I.relay-on-live"
timeout 4 bash "$WAIT" "$I" --doc "$ROLD" --workers "N1.md" > "$WORK/rol3.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(rol3) a failing relay still wakes once, rc 0" "0" "$rc"
check "(rol3) the wake carries the relay rc" "WAKE relay-on-live successor=S2 relay-failed rc=1" "$(head -n1 "$WORK/rol3.out")"
check "(rol3) and the marker is consumed, so nothing is resent" "no" "$([ -e "$I.relay-on-live" ] && echo yes || echo no)"
unset CHIEF_WAIT_LOCK_STATUS CHIEF_WAIT_RELAY CHIEF_WAIT_SUCCESSION_SEC

# --- (k) usage ---------------------------------------------------------------
bash "$WAIT" >/dev/null 2>&1; rc=$?
check "(k) no inbox argument is a usage error (rc 2)" "2" "$rc"

# --- (hb): chief-budget.sh HANDOVER wakes the chief once per streak ------
# Needs --doc (the chief's name is the doc basename, passed as --title). A
# marker <inbox>.wait.budget outlives the waiter; verdict OK clears it.
cat > "$STUB/budget.sh" <<'EOF'
#!/usr/bin/env bash
case "$*" in *--resolve*) printf 'x\n' >> "$STUB/budget.resolves"; printf '%s\n' "$STUB/budget.transcript"; exit 0 ;; esac
printf '%s %s\n' "$*" "$CONTEXT_FILL_TRANSCRIPT" >> "$STUB/budget.calls"
cat "$STUB/budget.out"; exit "$(cat "$STUB/budget.rc")"
EOF
export CHIEF_WAIT_BUDGET="$STUB/budget.sh"
printf 'budget turns=151 cache_read=12.0M verdict=HANDOVER\n' > "$STUB/budget.out"; printf '3\n' > "$STUB/budget.rc"
reset_stub; : > "$STUB/budget.calls"; I="$(new_inbox hb1)"
start "$I" "$WORK/hb1.out" --doc "$WORK/hb1/consoles/HB.md" --workers "N1.md"
wait_exit "$WPID"
check "(hb1) HANDOVER wakes with the budget line" "WAKE handover-budget budget turns=151 cache_read=12.0M verdict=HANDOVER" "$(head -n1 "$WORK/hb1.out")"
check "(hb1) and the waiter exits 0" "0" "$rc"
check "(hb1) the console is named by the doc basename and the resolved transcript is passed" "--title HB $STUB/budget.transcript" "$(head -n1 "$STUB/budget.calls")"
timeout 3 bash "$WAIT" "$I" --doc "$WORK/hb1/consoles/HB.md" --workers "N1.md" > "$WORK/hb1b.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(hb2) the re-arm inside the same streak stays quiet" "" "$(cat "$WORK/hb1b.out")"
printf 'budget turns=3 cache_read=0.1M verdict=OK\n' > "$STUB/budget.out"; printf '0\n' > "$STUB/budget.rc"
timeout 3 bash "$WAIT" "$I" --doc "$WORK/hb1/consoles/HB.md" --workers "N1.md" > "$WORK/hb1s.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(hb3s) verdict OK with no fill measured (stale snapshot) leaves the streak marker" "present:124:" "$([ -e "$I.wait.budget" ] && echo present):$rc:$(cat "$WORK/hb1s.out")"
printf 'budget turns=3 cache_read=0.1M fill=10%% verdict=OK\n' > "$STUB/budget.out"
rm -f "$STUB/budget.resolves"; : > "$STUB/budget.calls"
timeout 3 bash "$WAIT" "$I" --doc "$WORK/hb1/consoles/HB.md" --workers "N1.md" > "$WORK/hb1c.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(hb3) verdict OK with a measured fill clears the streak marker" "absent" "$([ -e "$I.wait.budget" ] && echo present || echo absent)"
check "(hb3b) the transcript is resolved once per run, not per sample" "1:ok" "$(wc -l < "$STUB/budget.resolves" | tr -d ' '):$([ "$(wc -l < "$STUB/budget.calls")" -ge 2 ] && echo ok || echo few-samples)"
printf '2\n' > "$STUB/budget.rc"; : > "$I.wait.budget"
timeout 3 bash "$WAIT" "$I" --doc "$WORK/hb1/consoles/HB.md" --workers "N1.md" > "$WORK/hb1d.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(hb4) an unreadable transcript (rc 2) neither wakes nor clears the marker" "present:" "$([ -e "$I.wait.budget" ] && echo present):$(cat "$WORK/hb1d.out")"
rm -f "$I.wait.budget"
timeout 3 bash "$WAIT" "$I" --doc "$WORK/hb1/consoles/HB.md" --workers "N1.md" > "$WORK/hb1e.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(hb4b) rc 2 with no marker: no wake, no marker, the waiter ran to its timeout" "124:absent:" "$rc:$([ -e "$I.wait.budget" ] && echo present || echo absent):$(cat "$WORK/hb1e.out")"
printf '#!/usr/bin/env bash\ncase "$*" in *--resolve*) echo /x; exit 0 ;; esac\nexec sleep 30\n' > "$STUB/budget.hang.sh"
reset_stub; I="$(new_inbox hb6)"
CHIEF_WAIT_BUDGET="$STUB/budget.hang.sh" CHIEF_WAIT_BUDGET_TIMEOUT=1 start "$I" "$WORK/hb6.out" --doc "$WORK/hb1/consoles/HB.md" --workers "N1.md"
sleep 0.5
printf -- '- 03:45 [telegram from=1 chat=2] hello\n' >> "$I"
n=0
while [ "$n" -lt 100 ] && kill -0 "$WPID" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
check "(hb6) a hung budget read is killed at CHIEF_WAIT_BUDGET_TIMEOUT: the Telegram line still wakes within 10 s" "WAKE telegram" "$(head -n1 "$WORK/hb6.out")"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
printf '#!/usr/bin/env bash\nexec sleep 30\n' > "$STUB/budget.hangresolve.sh"
reset_stub; I="$(new_inbox hb6b)"
CHIEF_WAIT_BUDGET="$STUB/budget.hangresolve.sh" CHIEF_WAIT_BUDGET_TIMEOUT=1 start "$I" "$WORK/hb6b.out" --doc "$WORK/hb1/consoles/HB.md" --workers "N1.md"
sleep 0.5
printf -- '- 03:45 [telegram from=1 chat=2] hello\n' >> "$I"
n=0
while [ "$n" -lt 100 ] && kill -0 "$WPID" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
check "(hb6b) a hung --resolve is killed at CHIEF_WAIT_BUDGET_TIMEOUT: the Telegram line still wakes within 10 s" "WAKE telegram" "$(head -n1 "$WORK/hb6b.out")"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
printf '3\n' > "$STUB/budget.rc"; : > "$STUB/budget.calls"; I="$(new_inbox hb5)"
timeout 3 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/hb5.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(hb5) without --doc the budget is not read and nothing wakes" "0:" "$(wc -l < "$STUB/budget.calls" | tr -d ' '):$(cat "$WORK/hb5.out")"

# --- (hc): the chief doc naming, --workers-from, the repeat wake and an unresolved title ---
# A HANDOVER wake the chief missed is sent again once the marker is older than
# CHIEF_WAIT_BUDGET_REPEAT_MIN (default 30) minutes while the verdict stays HANDOVER.
HC="HIMMEL-nextleg-2026-10-25FX-roadmap-chief"
printf 'budget turns=60 cache_read=9.0M fill=50%% verdict=HANDOVER\n' > "$STUB/budget.out"; printf '3\n' > "$STUB/budget.rc"
reset_stub; : > "$STUB/budget.calls"; I="$(new_inbox hc1)"
start "$I" "$WORK/hc1.out" --doc "$WORK/hc1/consoles/$HC.md" --workers "N1.md"
wait_exit "$WPID"
check "(hc1) the chief doc naming wakes with exactly one WAKE handover-budget line" "1:WAKE handover-budget budget turns=60 cache_read=9.0M fill=50% verdict=HANDOVER" "$(grep -c '^WAKE handover-budget ' "$WORK/hc1.out"):$(head -n1 "$WORK/hc1.out")"
check "(hc1) the title is the chief doc basename" "--title $HC $STUB/budget.transcript" "$(head -n1 "$STUB/budget.calls")"
reset_stub; : > "$STUB/budget.calls"; I="$(new_inbox hc2)"
start "$I" "$WORK/hc2.out" --doc "$WORK/hc2/consoles/$HC.md" --workers-from "$WORK/hc2-fleet.json"
wait_exit "$WPID"
check "(hc2) --workers-from with --doc still runs the budget wake" "WAKE handover-budget budget turns=60 cache_read=9.0M fill=50% verdict=HANDOVER" "$(head -n1 "$WORK/hc2.out")"
reset_stub; I="$(new_inbox hr1)"
: > "$I.wait.budget"; touch -d '31 minutes ago' "$I.wait.budget"  # gnu-ok: Linux-only kit
start "$I" "$WORK/hr1.out" --doc "$WORK/hr1/consoles/$HC.md" --workers "N1.md"
wait_exit "$WPID"
check "(hr1) a marker older than 30 min with the verdict still HANDOVER wakes again, marked as a repeat" "WAKE handover-budget repeat budget turns=60 cache_read=9.0M fill=50% verdict=HANDOVER" "$(head -n1 "$WORK/hr1.out")"
timeout 3 bash "$WAIT" "$I" --doc "$WORK/hr1/consoles/$HC.md" --workers "N1.md" > "$WORK/hr1q.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(hr1) the repeat renews the marker, so the next re-arm stays quiet and runs to its timeout" "quiet:124:" "$([ "$(( $(date +%s) - $(stat -c %Y "$I.wait.budget") ))" -lt 60 ] && echo quiet):$rc:$(cat "$WORK/hr1q.out")"  # gnu-ok: Linux-only kit
reset_stub; I="$(new_inbox hr2)"
: > "$I.wait.budget"; touch -d '5 minutes ago' "$I.wait.budget"  # gnu-ok: Linux-only kit
timeout 3 bash "$WAIT" "$I" --doc "$WORK/hr2/consoles/$HC.md" --workers "N1.md" > "$WORK/hr2.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(hr2) a marker younger than 30 min stays quiet" "124:" "$rc:$(cat "$WORK/hr2.out")"
reset_stub; I="$(new_inbox hr3)"
: > "$I.wait.budget"; touch -d '5 minutes ago' "$I.wait.budget"  # gnu-ok: Linux-only kit
CHIEF_WAIT_BUDGET_REPEAT_MIN=2 start "$I" "$WORK/hr3.out" --doc "$WORK/hr3/consoles/$HC.md" --workers "N1.md"
wait_exit "$WPID"
check "(hr3) CHIEF_WAIT_BUDGET_REPEAT_MIN sets the interval" "WAKE handover-budget repeat budget turns=60 cache_read=9.0M fill=50% verdict=HANDOVER" "$(head -n1 "$WORK/hr3.out")"
reset_stub; I="$(new_inbox hr4)"
: > "$I.wait.budget"; touch -d '31 minutes ago' "$I.wait.budget"  # gnu-ok: Linux-only kit
CHIEF_WAIT_BUDGET_REPEAT_MIN=08 start "$I" "$WORK/hr4.out" --doc "$WORK/hr4/consoles/$HC.md" --workers "N1.md"
wait_exit "$WPID"
check "(hr4) a leading-zero CHIEF_WAIT_BUDGET_REPEAT_MIN reads as decimal" "WAKE handover-budget repeat budget turns=60 cache_read=9.0M fill=50% verdict=HANDOVER" "$(head -n1 "$WORK/hr4.out")"
reset_stub; I="$(new_inbox hr5)"
: > "$I.wait.budget"; touch -d '5 minutes ago' "$I.wait.budget"  # gnu-ok: Linux-only kit
CHIEF_WAIT_BUDGET_REPEAT_MIN=00 timeout 3 bash "$WAIT" "$I" --doc "$WORK/hr5/consoles/$HC.md" --workers "N1.md" > "$WORK/hr5.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(hr5) a zero CHIEF_WAIT_BUDGET_REPEAT_MIN falls back to 30, so a fresh marker stays quiet" "124:" "$rc:$(cat "$WORK/hr5.out")"
reset_stub; I="$(new_inbox hr6)"
: > "$I.wait.budget"; touch -d '5 minutes ago' "$I.wait.budget"  # gnu-ok: Linux-only kit
CHIEF_WAIT_BUDGET_REPEAT_MIN=153722867280912931 timeout 3 bash "$WAIT" "$I" --doc "$WORK/hr6/consoles/$HC.md" --workers "N1.md" > "$WORK/hr6.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(hr6) an overflowing CHIEF_WAIT_BUDGET_REPEAT_MIN falls back to 30, so a fresh marker stays quiet" "124:" "$rc:$(cat "$WORK/hr6.out")"
printf '#!/usr/bin/env bash\ncase "$*" in *--resolve*) exit 2 ;; esac\nexit 0\n' > "$STUB/budget.nores.sh"
reset_stub; I="$(new_inbox hf1)"
CHIEF_WAIT_BUDGET="$STUB/budget.nores.sh" timeout 3 bash "$WAIT" "$I" --doc "$WORK/hf1/consoles/$HC.md" --workers "N1.md" > "$WORK/hf1.out" 2> "$WORK/hf1.err"; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(hf1) an unresolvable title says why on stderr, once per run, and wakes nothing" "1:124:" "$(grep -c "budget not measured: cannot resolve the transcript of $HC" "$WORK/hf1.err"):$rc:$(cat "$WORK/hf1.out")"
export CHIEF_WAIT_BUDGET="$STUB/budget-off.sh"

# --- (sw): the status sweep runs every WAIT_SWEEP_SEC with --doc, bounded, and wakes only when
# it moved a ticket or its failure signature is new; the same pass wakes once per FAILED or stale-DIRTY
# FOCUS state. The stamp <inbox>.wait.sweep outlives the waiter; no stamp means the first sweep is an
# interval away.
cat > "$STUB/sweep.sh" <<'EOF'
#!/usr/bin/env bash
printf 'sweep budget=%s\n' "${TICKET_STATUS_SWEEP_BUDGET:-}" >> "$STUB/sweep.calls"
cat "$STUB/sweep.out"; exit 0
EOF
cat > "$STUB/focus.sh" <<'EOF'
#!/usr/bin/env bash
printf 'focus %s\n' "$*" >> "$STUB/focus.calls"
case "$*" in *--status) ;; *) [ -e "$STUB/focus.sleep" ] && sleep "$(cat "$STUB/focus.sleep")" ;; esac
cat "$STUB/focus.out"; exit 0
EOF
export WAIT_SWEEP_CMD="$STUB/sweep.sh" WAIT_FOCUS_CMD="$STUB/focus.sh" WAIT_SWEEP_SEC=60
SWDOC="$WORK/hb1/consoles/HB.md"
printf 'status-sweep: keys=3 served=3 moved=1 miss=0 funnel=1 sig= wake=0\n' > "$STUB/sweep.out"; printf 'focus=ok\n' > "$STUB/focus.out"
reset_stub; : > "$STUB/sweep.calls"; I="$(new_inbox sw1)"; echo $(( $(date +%s) - 1000 )) > "$I.wait.sweep"
HOUSEKEEPING_DIGEST_SECS=0 start "$I" "$WORK/sw1.out" --doc "$SWDOC" --workers "N1.md"
wait_exit "$WPID"
check "(sw1) a due sweep that moved a ticket wakes with its line" "WAKE status-sweep status-sweep: keys=3 served=3 moved=1 miss=0 funnel=1 sig= wake=0" "$(head -n1 "$WORK/sw1.out")"
check "(sw1) and the waiter exits 0" "0" "$rc"
check "(sw1b) the sweep runs under a budget below its 60 s bound" "sweep budget=50" "$(head -n1 "$STUB/sweep.calls")"
check "(sw1c) the stamp was refreshed" "fresh" "$([ $(( $(date +%s) - $(cat "$I.wait.sweep") )) -lt 30 ] && echo fresh || echo old)"
printf 'status-sweep: keys=3 served=3 moved=0 miss=0 funnel=0 sig= wake=0\n' > "$STUB/sweep.out"
reset_stub; : > "$STUB/sweep.calls"; I="$(new_inbox sw2)"; echo $(( $(date +%s) - 1000 )) > "$I.wait.sweep"
timeout 3 bash "$WAIT" "$I" --doc "$SWDOC" --workers "N1.md" > "$WORK/sw2.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(sw2) a sweep that moved nothing and has no new failure wakes nothing" "124:" "$rc:$(cat "$WORK/sw2.out")"
check "(sw2b) and it ran once, not every sample" "1" "$(wc -l < "$STUB/sweep.calls" | tr -d ' ')"
printf 'status-sweep: keys=3 served=3 moved=0 miss=1 funnel=1 sig=get:x wake=1\n' > "$STUB/sweep.out"
reset_stub; I="$(new_inbox sw3)"; echo $(( $(date +%s) - 1000 )) > "$I.wait.sweep"
HOUSEKEEPING_DIGEST_SECS=0 start "$I" "$WORK/sw3.out" --doc "$SWDOC" --workers "N1.md"
wait_exit "$WPID"
check "(sw3) a new failure signature (wake=1) wakes" "WAKE status-sweep status-sweep: keys=3 served=3 moved=0 miss=1 funnel=1 sig=get:x wake=1" "$(head -n1 "$WORK/sw3.out")"
printf 'status-sweep: keys=3 served=3 moved=0 miss=1 funnel=1 sig=get:x wake=0\n' > "$STUB/sweep.out"
reset_stub; : > "$STUB/sweep.calls"; I="$(new_inbox sw4)"; date +%s > "$I.wait.sweep"
timeout 3 bash "$WAIT" "$I" --doc "$SWDOC" --workers "N1.md" > "$WORK/sw4.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(sw4) a standing failure (wake=0) and a recent stamp: no sweep, no wake" "0:" "$(wc -l < "$STUB/sweep.calls" | tr -d ' '):$(cat "$WORK/sw4.out")"
reset_stub; : > "$STUB/sweep.calls"; I="$(new_inbox sw5)"
timeout 3 bash "$WAIT" "$I" --doc "$SWDOC" --workers "N1.md" > "$WORK/sw5.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(sw5) with no stamp the first sweep waits one interval: not run, stamp created" "0:present" "$(wc -l < "$STUB/sweep.calls" | tr -d ' '):$([ -s "$I.wait.sweep" ] && echo present || echo absent)"
reset_stub; : > "$STUB/sweep.calls"; I="$(new_inbox sw6)"; echo $(( $(date +%s) - 1000 )) > "$I.wait.sweep"
timeout 3 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/sw6.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(sw6) without --doc the sweep does not run" "0" "$(wc -l < "$STUB/sweep.calls" | tr -d ' ')"
printf '#!/usr/bin/env bash\nexec sleep 30\n' > "$STUB/sweep.hang.sh"
reset_stub; I="$(new_inbox sw7)"; echo $(( $(date +%s) - 1000 )) > "$I.wait.sweep"
WAIT_SWEEP_CMD="$STUB/sweep.hang.sh" WAIT_SWEEP_TIMEOUT=1 start "$I" "$WORK/sw7.out" --doc "$SWDOC" --workers "N1.md"
sleep 0.5
printf -- '- 03:45 [telegram from=1 chat=2] hello\n' >> "$I"
n=0
while [ "$n" -lt 100 ] && kill -0 "$WPID" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
check "(sw7) a hung sweep is killed at WAIT_SWEEP_TIMEOUT: the Telegram line still wakes within 10 s" "WAKE telegram" "$(head -n1 "$WORK/sw7.out")"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
printf 'status-sweep: keys=3 served=3 moved=0 miss=0 funnel=0 sig= wake=0\n' > "$STUB/sweep.out"
printf 'focus=FAILED:render\n' > "$STUB/focus.out"
reset_stub; : > "$STUB/focus.calls"; I="$(new_inbox sw8)"; echo $(( $(date +%s) - 1000 )) > "$I.wait.sweep"
start "$I" "$WORK/sw8.out" --doc "$SWDOC" --workers "N1.md"
wait_exit "$WPID"
check "(sw8) a FAILED focus refresh wakes with its stage" "WAKE focus FAILED:render" "$(head -n1 "$WORK/sw8.out")"
check "(sw8b) and the status is read for the console doc" "focus --doc $SWDOC --status" "$(head -n1 "$STUB/focus.calls")"
echo $(( $(date +%s) - 1000 )) > "$I.wait.sweep"
timeout 3 bash "$WAIT" "$I" --doc "$SWDOC" --workers "N1.md" > "$WORK/sw8c.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(sw8c) the same FAILED state does not wake twice" "124:" "$rc:$(cat "$WORK/sw8c.out")"
printf 'focus=ok\n' > "$STUB/focus.out"; echo $(( $(date +%s) - 1000 )) > "$I.wait.sweep"
timeout 3 bash "$WAIT" "$I" --doc "$SWDOC" --workers "N1.md" > "$WORK/sw8d.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(sw8d) a focus back to ok clears the marker" "absent" "$([ -e "$I.wait.focus" ] && echo present || echo absent)"
printf 'focus=DIRTY:9m\n' > "$STUB/focus.out"
reset_stub; I="$(new_inbox sw9)"; echo $(( $(date +%s) - 1000 )) > "$I.wait.sweep"
timeout 3 bash "$WAIT" "$I" --doc "$SWDOC" --workers "N1.md" > "$WORK/sw9.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(sw9) DIRTY for under 10 minutes does not wake" "124:" "$rc:$(cat "$WORK/sw9.out")"
printf 'focus=DIRTY:12m\n' > "$STUB/focus.out"
reset_stub; I="$(new_inbox sw10)"; echo $(( $(date +%s) - 1000 )) > "$I.wait.sweep"
start "$I" "$WORK/sw10.out" --doc "$SWDOC" --workers "N1.md"
wait_exit "$WPID"
check "(sw10) DIRTY for 10 minutes or more wakes" "WAKE focus DIRTY:12m" "$(head -n1 "$WORK/sw10.out")"
printf 'focus=DIRTY:27m\n' > "$STUB/focus.out"; echo $(( $(date +%s) - 1000 )) > "$I.wait.sweep"
timeout 3 bash "$WAIT" "$I" --doc "$SWDOC" --workers "N1.md" > "$WORK/sw10b.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(sw10b) the same DIRTY state, older, does not wake twice" "124:" "$rc:$(cat "$WORK/sw10b.out")"
printf 'focus=DIRTY:unknown\n' > "$STUB/focus.out"
reset_stub; I="$(new_inbox sw11)"; echo $(( $(date +%s) - 1000 )) > "$I.wait.sweep"
start "$I" "$WORK/sw11.out" --doc "$SWDOC" --workers "N1.md"
wait_exit "$WPID"
check "(sw11) DIRTY with no readable age wakes" "WAKE focus DIRTY:unknown" "$(head -n1 "$WORK/sw11.out")"
# (fr) each tick starts one background refresh of a DIRTY or FAILED page (a status write marked it),
# none while an earlier one runs, and wakes nothing; a recent sweep stamp keeps the sweep out of it
launches() { grep -cx "focus --doc $SWDOC" "$STUB/focus.calls"; }
fr_run() { # <inbox name> [--doc] - three seconds of waiting, about three ticks
    reset_stub; : > "$STUB/focus.calls"; I="$(new_inbox "$1")"; date +%s > "$I.wait.sweep"
    [ -z "${FR_PID:-}" ] || printf '%s\n' "$FR_PID" > "$I.wait.focus-pid"
    if [ "${2:-}" = --doc ]; then
        timeout 3 bash "$WAIT" "$I" --doc "$SWDOC" --workers "N1.md" > "$WORK/$1.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
    else
        timeout 3 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/$1.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
    fi
    sleep 0.3
}
printf 'focus=DIRTY:0m\n' > "$STUB/focus.out"
fr_run fr1 --doc
check "(fr1) a DIRTY page starts a background refresh for the console doc" "yes" "$([ "$(launches)" -ge 1 ] && echo yes || echo no)"
check "(fr1b) and wakes nothing" "124:" "$rc:$(cat "$WORK/fr1.out")"
printf 'focus=FAILED:sweep:gh\n' > "$STUB/focus.out"
fr_run fr2 --doc
check "(fr2) a FAILED page is retried by a background refresh" "yes" "$([ "$(launches)" -ge 1 ] && echo yes || echo no)"
printf 'focus=ok\n' > "$STUB/focus.out"
fr_run fr3 --doc
check "(fr3) an ok page starts no refresh" "0" "$(launches)"
printf 'focus=skip\n' > "$STUB/focus.out"
fr_run fr4 --doc
check "(fr4) a doc with no focus version starts no refresh" "0" "$(launches)"
printf 'focus=DIRTY:0m\n' > "$STUB/focus.out"
fr_run fr5
check "(fr5) without --doc no refresh starts" "0" "$(wc -l < "$STUB/focus.calls" | tr -d ' ')"
echo 4 > "$STUB/focus.sleep"
fr_run fr6 --doc
check "(fr6) a refresh still running is left alone: one start over three ticks" "1" "$(launches)"
fpid="$(cat "$I.wait.focus-pid" 2>/dev/null)"
[ -n "$fpid" ] && kill -- "-$fpid" 2>/dev/null
rm -f "$STUB/focus.sleep"
printf 'focus=DIRTY:0m\n' > "$STUB/focus.out"
sleep 30 & stray=$!
FR_PID=$stray fr_run fr7 --doc
kill "$stray" 2>/dev/null
check "(fr7) a pid file naming an unrelated process does not hold the refresh back" "yes" "$([ "$(launches)" -ge 1 ] && echo yes || echo no)"
bash -c 'sleep 30; :' "$WAIT_FOCUS_CMD" --doc "$WORK/other-chief.md" & stray=$!
FR_PID=$stray fr_run fr8 --doc
kill "$stray" 2>/dev/null
check "(fr8) a refresh still running for another doc does not hold this doc's refresh back" "yes" "$([ "$(launches)" -ge 1 ] && echo yes || echo no)"
export WAIT_SWEEP_CMD="$STUB/sweep-off.sh" WAIT_FOCUS_CMD="$STUB/sweep-off.sh"
unset WAIT_SWEEP_SEC

# --- (st) stall= wakes once per NEW conflict/no-ci token; ci-slow/idle are report-only,
# a token leaving the set and an unchanged set never wake, absence is a valid sample
# RED control (chief-wait.sh before this change): the new token never woke.
stall_line() { sed -E "s# stall=[^ ]*##; s#  *denials=none# stall=$1 denials=none#" "$STUB/tick.line" > "$STUB/tick.line.tmp" && mv "$STUB/tick.line.tmp" "$STUB/tick.line"; }
reset_stub
I="$(new_inbox st)"
start "$I" "$WORK/st.out" --workers "N1.md"
wait_hb "$I" || fail "(st) no baseline heartbeat"
tick_line "N1:FRESH" "ok"
stall_line 2887:conflict
wait_exit "$WPID"
check "(st) a new conflict stall ends the wait" "0" "$rc"
check "(st) the wake names stall" "WAKE tick changed=stall usage=PROCEED" "$(head -n1 "$WORK/st.out")"

reset_stub
tick_line "N1:FRESH" "ok"
stall_line 2887:conflict
I="$(new_inbox st2)"
start "$I" "$WORK/st2.out" --workers "N1.md"
wait_hb "$I" || fail "(st2) no baseline heartbeat"
stall_line 2887:conflict
wait_exit "$WPID"
check "(st2) an unchanged stall does not wake" "running" "$rc"
stall_line 2887:conflict,2869:ci-slow,9004:idle
wait_exit "$WPID"
check "(st2) a new ci-slow/idle token alone does not wake" "running" "$rc"
stall_line 2869:ci-slow
wait_exit "$WPID"
check "(st2) a stall resolving does not wake" "running" "$rc"
stall_line 9003:no-ci,2869:ci-slow
wait_exit "$WPID"
check "(st2) a new no-ci token wakes" "0" "$rc"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# a probe outage (stall=?) keeps the saved set: the same conflict coming back is not new
reset_stub
tick_line "N1:FRESH" "ok"
stall_line 2887:conflict
I="$(new_inbox st4)"
start "$I" "$WORK/st4.out" --workers "N1.md"
wait_hb "$I" || fail "(st4) no baseline heartbeat"
stall_line '?'
wait_exit "$WPID"
check "(st4) a probe outage alone does not wake" "running" "$rc"
wait_exit "$WPID"
check "(st4) a second outage sample does not wake" "running" "$rc"
stall_line 2887:conflict
wait_exit "$WPID"
check "(st4) the same conflict returning after the outage does not wake" "running" "$rc"
stall_line 2887:conflict,9003:no-ci
wait_exit "$WPID"
check "(st4) a genuinely new token after the outage still wakes" "0" "$rc"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

reset_stub
I="$(new_inbox st3)"
start "$I" "$WORK/st3.out" --workers "N1.md"
wait_hb "$I" || fail "(st3) no baseline heartbeat"
wait_exit "$WPID"
check "(st3) a tick line with no stall= field is still a valid sample" "running" "$rc"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# --- (od5) the tick fields say workers=, workerset= and usage=; the waiter reads
# workers= and the old legs= alike, and a token that only ends in workers= is not
# the field. RED control (chief-wait.sh before the rename): a tick line carrying
# workers= has no legs= field, so every sample fails and nothing wakes.
od5_line() { # <workers value> [max_workers value]
    sed -e "s/ legs=[^ ]*/ workers=$1/" -e 's/ legset=/ workerset=/' -e 's/ bank=/ usage=/' \
        -e "s/ fill=/${2:+ max_workers=$2} fill=/" "$STUB/tick.line" > "$STUB/tick.line.tmp" && mv "$STUB/tick.line.tmp" "$STUB/tick.line"
}
reset_stub
od5_line "N1:FRESH"
I="$(new_inbox od5a)"
start "$I" "$WORK/od5a.out" --workers "N1.md"
wait_hb "$I" || fail "(od5a) no baseline heartbeat on a workers= tick line"
tick_line "N1:FRESH" "ok"; od5_line "N1:STALE"
wait_exit "$WPID"
check "(od5a) a workers= change wakes the chief (rc 0)" "0" "$rc"
check "(od5a) naming workers" "WAKE tick changed=workers usage=PROCEED" "$(head -n1 "$WORK/od5a.out")"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

reset_stub
I="$(new_inbox od5b)"
start "$I" "$WORK/od5b.out" --workers "N1.md"
wait_hb "$I" || fail "(od5b) no baseline heartbeat on a legs= tick line"
tick_line "N1:STALE" "ok"
wait_exit "$WPID"
check "(od5b) an old legs= change still wakes the chief (rc 0)" "0" "$rc"
check "(od5b) under the new field name" "WAKE tick changed=workers usage=PROCEED" "$(head -n1 "$WORK/od5b.out")"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

reset_stub
od5_line "N1:FRESH" 1
I="$(new_inbox od5c)"
start "$I" "$WORK/od5c.out" --workers "N1.md"
wait_hb "$I" || fail "(od5c) no baseline heartbeat"
tick_line "N1:FRESH" "ok"; od5_line "N1:FRESH" 2
sleep 2
tick_line "N1:FRESH" "ok"; od5_line "N1:FRESH" 3
wait_exit "$WPID"
check "(od5c) a max_workers= change alone does not wake" "running" "$rc"
# The tick moving from the old names to the new ones with the same values is no change.
tick_line "N1:FRESH" "ok"
wait_exit "$WPID"
check "(od5c) nor does a tick line going back to legs= with the same value" "running" "$rc"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# A baseline an older waiter saved under legs=/legset=/bank= is the same key, not a change.
reset_stub
I="$(new_inbox od5d)"
start "$I" "$WORK/od5d.out" --workers "N1.md"
wait_hb "$I" || fail "(od5d) no baseline heartbeat"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
sed -i -e '2s/workers=/legs=/' -e '2s/workerset=/legset=/' -e '2s/usage=/bank=/' "$I.wait.state"  # gnu-ok: Linux-only kit
check "(od5d) the saved key now carries the old names" "1" "$(sed -n 2p "$I.wait.state" | grep -c 'legs=.*legset=.*bank=')"
: > "$I.wait"
start "$I" "$WORK/od5d.out" --workers "N1.md"
wait_hb "$I" || fail "(od5d) no heartbeat after the restart"
sleep 2
wait_exit "$WPID"
check "(od5d) a restart over an old-names baseline does not wake" "running" "$rc"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# --- (dp) dispatch= wakes once per NEW late/idle/orphan run; the elapsed time,
# job counts and a stale-head flag never wake, a run leaving the set does not, dispatch=? keeps the saved set
# RED control (chief-wait.sh before this change): the flagged run never woke.
dispatch_line() { sed -E "s# dispatch=[^ ]*##; s#  *denials=none# dispatch=$1 denials=none#" "$STUB/tick.line" > "$STUB/tick.line.tmp" && mv "$STUB/tick.line.tmp" "$STUB/tick.line"; }
reset_stub
I="$(new_inbox dp)"
start "$I" "$WORK/dp.out" --workers "N1.md"
wait_hb "$I" || fail "(dp) no baseline heartbeat"
tick_line "N1:FRESH" "ok"
dispatch_line 4001:N61:102/120m:3/9@1111111:late
wait_exit "$WPID"
check "(dp) a new late run ends the wait" "0" "$rc"
check "(dp) the wake names dispatch" "WAKE tick changed=dispatch usage=PROCEED" "$(head -n1 "$WORK/dp.out")"

reset_stub
tick_line "N1:FRESH" "ok"
dispatch_line 4001:N61:102/120m:3/9@1111111:late
I="$(new_inbox dp2)"
start "$I" "$WORK/dp2.out" --workers "N1.md"
wait_hb "$I" || fail "(dp2) no baseline heartbeat"
dispatch_line 4001:N61:103/120m:4/9@1111111:late
wait_exit "$WPID"
check "(dp2) a flagged run's elapsed time and job counts moving does not wake" "running" "$rc"
dispatch_line 4001:N61:104/120m:4/9@1111111:late:stale-head,4002:N61:5/120m:1/9@2222222:stale-head
wait_exit "$WPID"
check "(dp2) a stale-head flag and an unflagged run alone do not wake" "running" "$rc"
dispatch_line 4002:N61:6/120m:1/9@2222222
wait_exit "$WPID"
check "(dp2) the flagged run finishing does not wake" "running" "$rc"
dispatch_line 4003:N333:5/120m:1/9@3333333:orphan
wait_exit "$WPID"
check "(dp2) a new orphan run wakes" "0" "$rc"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

reset_stub
tick_line "N1:FRESH" "ok"
dispatch_line 4001:N61:102/120m:3/9@1111111:late
I="$(new_inbox dp3)"
start "$I" "$WORK/dp3.out" --workers "N1.md"
wait_hb "$I" || fail "(dp3) no baseline heartbeat"
dispatch_line '?'
wait_exit "$WPID"
check "(dp3) an unreadable runs list alone does not wake" "running" "$rc"
dispatch_line 4001:N61:105/120m:3/9@1111111:late
wait_exit "$WPID"
check "(dp3) the same late run returning after the outage does not wake" "running" "$rc"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

reset_stub
tick_line "N1:FRESH" "ok"
dispatch_line 4001:N61:102/120m:3/9@1111111:late:idle
I="$(new_inbox dp4)"
start "$I" "$WORK/dp4.out" --workers "N1.md"
wait_hb "$I" || fail "(dp4) no baseline heartbeat"
dispatch_line 4001:N61:103/120m:3/9@1111111:late
wait_exit "$WPID"
check "(dp4) a run dropping one of its flags does not wake" "running" "$rc"
dispatch_line 4001:N61:104/120m:3/9@1111111:late:orphan
wait_exit "$WPID"
check "(dp4) the same run gaining a new flag wakes" "0" "$rc"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# --- (7849) doctor=<id>,...: a WARN/FAIL check id new to the waiter's marker wakes it once
# and names only the new ids; an unchanged set never re-wakes, however old the marker; a set
# that shrinks wakes nothing; doctor=? keeps the marker. RED control (chief-wait.sh before this
# change): none woke.
doctor_line() { sed -e 's/ doctor=[^ ]*//' ${1:+-e "s/\$/ doctor=$1/"} "$STUB/tick.line" > "$STUB/tick.line.tmp" && mv "$STUB/tick.line.tmp" "$STUB/tick.line"; }
reset_stub
doctor_line "C16-hooks,C77-bridge-stale"
I="$(new_inbox w7849)"
start "$I" "$WORK/w7849.out" --workers "N1.md"
wait_exit "$WPID"
check "(7849) a new doctor WARN set wakes on first sight" "0" "$rc"
check "(7849) the wake names the doctor ids" "WAKE doctor C16-hooks,C77-bridge-stale" "$(head -n1 "$WORK/w7849.out")"

start "$I" "$WORK/w7849b.out" --workers "N1.md"
wait_hb "$I" || fail "(7849-2) no baseline heartbeat"
wait_exit "$WPID"
check "(7849-2) the same set does not wake again" "running" "$rc"
touch -d '5 hours ago' "$I.wait.doctor"
wait_exit "$WPID"
check "(7849-2) nor after the marker is hours old" "running" "$rc"
doctor_line "C16-hooks,C35-other,C77-bridge-stale"
wait_exit "$WPID"
check "(7849-3) a set gaining a member wakes naming only the new id" "WAKE doctor C35-other" "$(head -n1 "$WORK/w7849b.out")"

doctor_line "C35-other"
start "$I" "$WORK/w7849c.out" --workers "N1.md"
wait_hb "$I" || fail "(7849-4) no baseline heartbeat"
wait_exit "$WPID"
check "(7849-4) a set that only shrinks wakes nothing" "running" "$rc"
doctor_line "C16-hooks,C35-other"
wait_exit "$WPID"
check "(7849-4) an id that left and rejoins is new again" "WAKE doctor C16-hooks" "$(head -n1 "$WORK/w7849c.out")"

doctor_line "?"
start "$I" "$WORK/w7849d.out" --workers "N1.md"
wait_hb "$I" || fail "(7849-5) no baseline heartbeat"
sleep 2
check "(7849-5) doctor=? keeps the marker" "present" "$([ -e "$I.wait.doctor" ] && echo present)"
check "(7849-5) and wakes nothing" "" "$(head -n1 "$WORK/w7849d.out")"
doctor_line ""
n=0
while [ "$n" -lt 50 ] && [ -e "$I.wait.doctor" ]; do sleep 0.1; n=$((n + 1)); done
check "(7849-6) a tick line with no doctor= clears the marker" "" "$([ -e "$I.wait.doctor" ] && echo present)"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# an option-shaped first argument is refused before any path is derived from it
mkdir -p "$WORK/kopt"
(cd "$WORK/kopt" && bash "$WAIT" --help >"$WORK/kopt.out" 2>&1); rc=$?
check "(k) an option-shaped inbox argument is a usage error (rc 2)" "2" "$rc"
check "(k) and it writes no stray file into the cwd" "" "$(ls -A "$WORK/kopt")"
check "(k) and it prints the usage text" "yes" "$(grep -q '^usage: chief-wait.sh' "$WORK/kopt.out" && echo yes)"
# control: an absolute inbox path still starts the waiter
reset_stub
I="$(new_inbox kctl)"
timeout 3 bash "$WAIT" "$I" --workers "N1.md" >/dev/null 2>&1; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(k) an absolute inbox path still starts the waiter (rc 124)" "124" "$rc"

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
