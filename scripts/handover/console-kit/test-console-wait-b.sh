#!/usr/bin/env bash
# test-console-wait.sh — Exercises console-wait.sh, the console's
# one event waiter: silent while nothing changes, exits with exactly one WAKE
# block on a Telegram inbox line or a confirmed change of the tick's action
# key. tick.sh and the bank verdict are stubbed (CONSOLE_WAIT_TICK /
# CONSOLE_WAIT_BANK), so no gh, lock or bank read happens here. bash 3.2-safe.
#
# CONSOLE_WAIT overrides the script under test (the RED control: today's
# Monitor-arm shape, which runs tick.sh on every arm, fails the idle cases).
#
# Linux-only: console-wait.sh has no .ps1 twin by design; this suite uses GNU
# timeout and touch -d, so run-shell-tests.sh skips it off-Linux.
#
# Second half of the console-wait suite: the (vmrun) cases onward. The first
# half is test-console-wait.sh (cases up to (y4)).
#
# Run: bash scripts/handover/console-kit/test-console-wait-b.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WAIT="${CONSOLE_WAIT:-$HERE/console-wait.sh}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/console-wait-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
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
export CONSOLE_WAIT_TICK="$STUB/tick.sh" CONSOLE_WAIT_BANK="$STUB/bank.sh"
export CONSOLE_WAIT_INTERVAL=1 CONSOLE_WAIT_POLL_SEC=0.2
# A failure streak wakes only in (f4); elsewhere a failed sample is just "not a change".
export CONSOLE_WAIT_FAIL_WAKE=1000
# a denials rise pages the operator. The suite owns the sender and
# the record dir (never a real Telegram send, never ~/.himmel/state): the stub
# appends each page text to $STUB/pages. CONSOLE_WAIT_PAGE_TIMEOUT is kept short
# so the hung-sender case (p6) finishes fast.
cat > "$STUB/page.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$STUB/pages"
exit 0
EOF
chmod +x "$STUB/page.sh"  # the sender seam is exec'd directly, not run via bash
export CONSOLE_WAIT_PAGE_CMD="$STUB/page.sh" CONSOLE_WAIT_PAGE_TIMEOUT=2
export HIMMEL_DENIAL_ACK_DIR="$WORK/acks"
# No test reads the real transcripts: the budget seam answers "unreadable" (exit 2) until (hb).
cat > "$STUB/budget-off.sh" <<'EOF'
#!/usr/bin/env bash
exit 2
EOF
export CONSOLE_WAIT_BUDGET="$STUB/budget-off.sh"

# tick_line <legs> <board> [hb] [prs] [or] [fails]: a tick line whose action fields are set.
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

# tracker_line is shared with the (w) block that stays in test-console-wait.sh.
tracker_line() { sed "s/ denials=none/ tracker=$1 denials=none/" "$STUB/tick.line" > "$STUB/tick.line.tmp" && mv "$STUB/tick.line.tmp" "$STUB/tick.line"; }

# --- (v) vmrun= wakes only on a class move TO DEAD / STUCK / DISAGREE; the
# busy count moving, a move back to ok/off and an absent field never wake. ----
vmrun_line() { sed "s#  *denials=none# vmrun=$1 denials=none#" "$STUB/tick.line" > "$STUB/tick.line.tmp" && mv "$STUB/tick.line.tmp" "$STUB/tick.line"; }
reset_stub
vmrun_line ok:2/2,busy=0
I="$(new_inbox vm)"
start "$I" "$WORK/vm.out" --legs "N1.md"
wait_hb "$I" || fail "(vm) no baseline heartbeat"
tick_line "N1:FRESH" "ok"
vmrun_line ok:2/2,busy=2
wait_exit "$WPID"
check "(vm) a busy-count move alone does not wake" "running" "$rc"
tick_line "N1:FRESH" "ok"
vmrun_line DEAD
wait_exit "$WPID"
check "(vm) a vmrun move to DEAD ends the wait" "0" "$rc"
check "(vm) the wake names vmrun" "WAKE tick changed=vmrun bank=PROCEED" "$(head -n1 "$WORK/vm.out")"

reset_stub
vmrun_line DEAD
I="$(new_inbox vm2)"
start "$I" "$WORK/vm2.out" --legs "N1.md"
wait_hb "$I" || fail "(vm2) no baseline heartbeat"
tick_line "N1:FRESH" "ok"
vmrun_line ok:1/2,busy=0
wait_exit "$WPID"
check "(vm2) a vmrun move back to ok alone does not wake" "running" "$rc"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

reset_stub
vmrun_line ok:2/2,busy=0
I="$(new_inbox vm3)"
start "$I" "$WORK/vm3.out" --legs "N1.md"
wait_hb "$I" || fail "(vm3) no baseline heartbeat"
tick_line "N1:FRESH" "ok"
vmrun_line DISAGREE:2/2,online=0
wait_exit "$WPID"
check "(vm3) a vmrun move to DISAGREE ends the wait" "0" "$rc"
check "(vm3) the DISAGREE wake names vmrun" "WAKE tick changed=vmrun bank=PROCEED" "$(head -n1 "$WORK/vm3.out")"
[ "$rc" = running ] && { kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; }

reset_stub
vmrun_line ok:2/2,busy=0
I="$(new_inbox vm3b)"
start "$I" "$WORK/vm3b.out" --legs "N1.md"
wait_hb "$I" || fail "(vm3b) no baseline heartbeat"
tick_line "N1:FRESH" "ok"
vmrun_line DISAGREE:2/2,online=1
wait_exit "$WPID"
check "(vm3b) a vmrun move to a partial-outage DISAGREE ends the wait" "0" "$rc"
check "(vm3b) the partial-outage DISAGREE wake names vmrun" "WAKE tick changed=vmrun bank=PROCEED" "$(head -n1 "$WORK/vm3b.out")"
[ "$rc" = running ] && { kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; }

for recovery in ok:2/2,busy=0 off FAILING; do
    reset_stub
    vmrun_line DISAGREE:2/2,online=0
    I="$(new_inbox "vm-recover-$recovery")"
    start "$I" "$WORK/vm-recover.out" --legs "N1.md"
    wait_hb "$I" || fail "(vm-recover) no baseline heartbeat"
    tick_line "N1:FRESH" "ok"
    vmrun_line "$recovery"
    wait_exit "$WPID"
    check "(vm-recover) DISAGREE to $recovery alone does not wake" "running" "$rc"
    check "(vm-recover) DISAGREE to $recovery emits nothing" "" "$(cat "$WORK/vm-recover.out")"
    kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
done

# --- (pk) parked= wakes when a leg joins the parked set; the growing age alone
# never wakes; a tick line with no parked= field stays a valid sample. ---------
parked_line() { sed "s#  *denials=none# parked=$1 denials=none#" "$STUB/tick.line" > "$STUB/tick.line.tmp" && mv "$STUB/tick.line.tmp" "$STUB/tick.line"; }
reset_stub
parked_line N1:6m
I="$(new_inbox pk)"
start "$I" "$WORK/pk.out" --legs "N1.md"
wait_hb "$I" || fail "(pk) no baseline heartbeat"
tick_line "N1:FRESH" "ok"
parked_line N1:9m
wait_exit "$WPID"
check "(pk) the age growing alone does not wake" "running" "$rc"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

reset_stub
I="$(new_inbox pk2)"
start "$I" "$WORK/pk2.out" --legs "N1.md"
wait_hb "$I" || fail "(pk2) no baseline heartbeat"
tick_line "N1:FRESH" "ok"
parked_line N1:6m
wait_exit "$WPID"
check "(pk2) a leg joining the parked set ends the wait" "0" "$rc"
check "(pk2) the wake names parked" "WAKE tick changed=parked bank=PROCEED" "$(head -n1 "$WORK/pk2.out")"

# the same legs parked in a different order is not a membership change
reset_stub
parked_line N1:6m,N2:7m
I="$(new_inbox pk4)"
start "$I" "$WORK/pk4.out" --legs "N1.md"
wait_hb "$I" || fail "(pk4) no baseline heartbeat"
tick_line "N1:FRESH" "ok"
parked_line N2:7m,N1:6m
wait_exit "$WPID"
check "(pk4) a reordered parked set does not wake" "running" "$rc"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# a leg LEAVING the parked set (the field disappears) wakes too
reset_stub
parked_line N1:6m
I="$(new_inbox pk3)"
start "$I" "$WORK/pk3.out" --legs "N1.md"
wait_hb "$I" || fail "(pk3) no baseline heartbeat"
tick_line "N1:FRESH" "ok"
sed 's# parked=[^ ]*##' "$STUB/tick.line" > "$STUB/tick.line.tmp" && mv "$STUB/tick.line.tmp" "$STUB/tick.line"
wait_exit "$WPID"
check "(pk3) a leg leaving the parked set ends the wait" "0" "$rc"
check "(pk3) the wake names parked" "WAKE tick changed=parked bank=PROCEED" "$(head -n1 "$WORK/pk3.out")"

# --- (m3748) a leg-set change made through --legs-from is a silent baseline --
# with --legs-from the argv never changes, so the waiter folds the
# manifest's leg list into its args hash each sample. A dispatch (manifest add)
# that moves legs=/tails= is the console's own act -- a silent baseline, the
# same as a restart with new --legs -- while a real change on the same leg set
# still wakes. RED control (console-wait.sh before this change): the dispatch
# below woke with changed=legs.
reset_stub
I="$(new_inbox m3748)"
M="$WORK/m3748/console.fleet.json"
printf '{"schema":1,"legs":[{"doc":"/x/HIMMEL-1-N1-a.md","label":"N1"}]}\n' > "$M"
start "$I" "$WORK/m3748.out" --legs-from "$M"
wait_hb "$I" || fail "(m3748) no baseline heartbeat"
# The stub tick ignores the manifest, so its line moves first: a sample
# between the two writes sees a changed key under the OLD leg set (pending,
# not yet a wake), and the next one sees the new leg set and re-baselines.
tick_line "N1:FRESH,N2:FRESH" "ok"
printf '{"schema":1,"legs":[{"doc":"/x/HIMMEL-1-N1-a.md","label":"N1"},{"doc":"/x/HIMMEL-2-N2-b.md","label":"N2"}]}\n' > "$M"
sleep 2
wait_exit "$WPID"
check "(m3748) a dispatch through the manifest does not wake the console" "running" "$rc"
check "(m3748) and prints nothing" "" "$(cat "$WORK/m3748.out")"
# A remove + re-add reorders the manifest, and tick prints legs in manifest
# order: the same set in a new order is the console's own act too.
tick_line "N2:FRESH,N1:FRESH" "ok"
printf '{"schema":1,"legs":[{"doc":"/x/HIMMEL-2-N2-b.md","label":"N2"},{"doc":"/x/HIMMEL-1-N1-a.md","label":"N1"}]}\n' > "$M"
sleep 2
wait_exit "$WPID"
check "(m3748) a reorder through the manifest does not wake the console" "running" "$rc"
check "(m3748) and still prints nothing" "" "$(cat "$WORK/m3748.out")"
tick_line "N2:FREE,N1:FRESH" "ok"
wait_exit "$WPID"
check "(m3748) a real change on the new leg set still wakes (rc 0)" "0" "$rc"
check "(m3748) naming legs" "WAKE tick changed=legs bank=PROCEED" "$(head -n1 "$WORK/m3748.out")"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# --- (l4568) a READY tail turning READY!stale (30 min, no GO file) is a wake
reset_stub
sed 's/ tails=N1:LIVE/ tails=N1:READY/' "$STUB/tick.line" > "$STUB/tick.line.tmp" && mv "$STUB/tick.line.tmp" "$STUB/tick.line"
I="$(new_inbox l4568)"
start "$I" "$WORK/l4568.out" --legs "N1.md"
wait_hb "$I" || fail "(l4568) no baseline heartbeat"
sed 's/ tails=N1:READY/ tails=N1:READY!stale/' "$STUB/tick.line" > "$STUB/tick.line.tmp" && mv "$STUB/tick.line.tmp" "$STUB/tick.line"
wait_exit "$WPID"
check "(l4568) a READY going stale wakes the console (rc 0)" "0" "$rc"
check "(l4568) the wake names tails" "WAKE tick changed=tails bank=PROCEED" "$(head -n1 "$WORK/l4568.out")"

# --- acts= moving (a new READY, a second BLOCKED) wakes, though tails= did not move
# RED control (pre-fix console-wait.sh): acts= is not in the key, so the waiter stays asleep.
reset_stub
sed 's/ tails=N1:LIVE/ tails=N1:LIVE acts=N1:READY#1/' "$STUB/tick.line" > "$STUB/tick.line.tmp" && mv "$STUB/tick.line.tmp" "$STUB/tick.line"
I="$(new_inbox a6292)"
start "$I" "$WORK/a6292.out" --legs "N1.md"
wait_hb "$I" || fail "(a6292) no baseline heartbeat"
sed 's/ acts=N1:READY#1/ acts=N1:BLOCKED#2/' "$STUB/tick.line" > "$STUB/tick.line.tmp" && mv "$STUB/tick.line.tmp" "$STUB/tick.line"
wait_exit "$WPID"
check "(a6292) a new actionable bullet wakes the console (rc 0)" "0" "$rc"
check "(a6292) the wake names acts" "WAKE tick changed=acts bank=PROCEED" "$(head -n1 "$WORK/a6292.out")"
check "(a6292) and the tick line names the leg and marker" "1" "$(grep -c 'acts=N1:BLOCKED#2' "$WORK/a6292.out")"

# --- (u4959) a sustained capacity=UNDERFILLED wakes, once per streak
# tick.sh already folds TICK_UNDERFILL_MIN into capacity=; the waiter wakes on the
# first UNDERFILLED sample, prints the dispatchable list (stubbed here), and a
# re-arm during the same streak stays quiet until capacity returns to ok.
cat > "$STUB/dispatch.sh" <<'EOF2'
#!/usr/bin/env bash
printf 'LOCAL HIMMEL-9001 stub-ticket\n'
EOF2
export CONSOLE_WAIT_DISPATCH="$STUB/dispatch.sh"
under_line() { sed "s/ capacity=[^ ]*/ capacity=$1/" "$STUB/tick.line" > "$STUB/tick.line.tmp" && mv "$STUB/tick.line.tmp" "$STUB/tick.line"; }
reset_stub
I="$(new_inbox u4959)"
start "$I" "$WORK/u4959.out" --legs "N1.md"
wait_hb "$I" || fail "(u4959) no baseline heartbeat"
under_line "UNDERFILLED:12"
wait_exit "$WPID"
check "(u4959) a sustained UNDERFILLED capacity wakes the console (rc 0)" "0" "$rc"
check "(u4959) the wake names the slack" "WAKE underfilled capacity=UNDERFILLED:12" "$(head -n1 "$WORK/u4959.out")"
check "(u4959) the wake carries the dispatchable list" "yes" "$(grep -q '^LOCAL HIMMEL-9001' "$WORK/u4959.out" && echo yes)"
timeout 4 bash "$WAIT" "$I" --legs "N1.md" > "$WORK/u4959b.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(u4959) the re-arm in the same streak does not wake again" "" "$(cat "$WORK/u4959b.out")"
check "(u4959) and is still waiting (rc 124)" "124" "$rc"
under_line "ok"
timeout 3 bash "$WAIT" "$I" --legs "N1.md" > "$WORK/u4959c.out" 2>/dev/null  # gnu-ok: Linux-only kit; pipefail-ok: none set
under_line "UNDERFILLED:5"
start "$I" "$WORK/u4959d.out" --legs "N1.md"
wait_exit "$WPID"
check "(u4959) a new streak after capacity returned to ok wakes again" "WAKE underfilled capacity=UNDERFILLED:5" "$(head -n1 "$WORK/u4959d.out")"
reset_stub
I="$(new_inbox u4959u)"
under_line "unknown"
timeout 3 bash "$WAIT" "$I" --legs "N1.md" > "$WORK/u4959e.out" 2>/dev/null  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(u4959) capacity=unknown (failed census) never wakes" "" "$(cat "$WORK/u4959e.out")"

# the manifest reaches the dispatch command, so live legs' files join the collision check
printf '#!/usr/bin/env bash\nprintf "ARGS %%s\\n" "$*"\n' > "$STUB/dispatch.sh"
reset_stub
I="$(new_inbox u4959m)"
start "$I" "$WORK/u4959m.out" --legs-from "$WORK/u4959-fleet.json"
wait_hb "$I" || fail "(u4959) no baseline heartbeat (manifest)"
under_line "UNDERFILLED:7"
wait_exit "$WPID"
check "(u4959) the dispatch command receives the slack as --top, then --legs-from" "ARGS --priority-pool-only --top 7 --legs-from $WORK/u4959-fleet.json" "$(grep '^ARGS' "$WORK/u4959m.out")"
reset_stub
I="$(new_inbox u4959d)"
printf '# console\n' > "$WORK/u4959-console.md"
start "$I" "$WORK/u4959n.out" --doc "$WORK/u4959-console.md" --legs-from "$WORK/u4959-fleet.json"
wait_hb "$I" || fail "(u4959) no baseline heartbeat (doc)"
under_line "UNDERFILLED:7"
wait_exit "$WPID"
check "(u4959) the dispatch command receives the console doc for the priority line" "ARGS --priority-pool-only --top 7 --doc $WORK/u4959-console.md --legs-from $WORK/u4959-fleet.json" "$(grep '^ARGS' "$WORK/u4959n.out")"

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
start "$I" "$WORK/u6478.out" --legs-from "$WORK/u4959-fleet.json"
wait_hb "$I" || fail "(6478) no baseline heartbeat"
under_line "UNDERFILLED:7"
wait_exit "$WPID"
check "(6478) an empty priority pool still prints POOL-EMPTY" "1" "$(grep -c '^POOL-EMPTY' "$WORK/u6478.out")"
check "(6478) an empty priority pool prints the version backlog from a second pass" "1" "$(grep -c '^LOCAL.HIMMEL-9002' "$WORK/u6478.out")"
check "(6478) the second pass keeps --top and --legs-from but drops --priority-pool-only" "args=--top 7 --legs-from $WORK/u4959-fleet.json" "$(grep -o 'args=.*' "$WORK/u6478.out")"
printf '#!/usr/bin/env bash\nprintf "ARGS %%s\\n" "$*"\n' > "$STUB/dispatch.sh"

# --- (u5542) unowned-prs=: the first sight of an open PR with no live
# owner wakes the waiter once, a PR that joins the set wakes it, the same set wakes
# again only after CONSOLE_WAIT_UNOWNED_REWAKE_MIN, and the marker clears once the
# field has read none twice. The field is not in the action key, so its growing
# age never wakes by itself. RED control (console-wait.sh before this change): none
# of these woke ("running"). ------------------------------------------------------
unowned_line() { sed -e "s/ unowned-prs=[^ ]*//" -e "s/ bank=/ unowned-prs=$1 bank=/" "$STUB/tick.line" > "$STUB/tick.line.tmp" && mv "$STUB/tick.line.tmp" "$STUB/tick.line"; }
reset_stub
unowned_line "#2575:120m"
I="$(new_inbox y)"
start "$I" "$WORK/y.out" --legs "N1.md"
wait_exit "$WPID"
check "(u5542) a PR with no live owner wakes on first sight" "0" "$rc"
check "(u5542) the wake names the PR and its age" "WAKE unowned-prs #2575:120m" "$(head -n1 "$WORK/y.out")"

start "$I" "$WORK/y2.out" --legs "N1.md"
wait_hb "$I" || fail "(u5542-2) no baseline heartbeat"
unowned_line "#2575:121m"
wait_exit "$WPID"
check "(u5542-2) the same PR, older, does not wake again inside the re-wake window" "running" "$rc"
touch -d '2 hours ago' "$I.wait.unowned"
wait_exit "$WPID"
check "(u5542-2) the same PR wakes again after the re-wake window" "0" "$rc"
check "(u5542-2) the re-wake names the PR" "WAKE unowned-prs #2575:121m" "$(head -n1 "$WORK/y2.out")"

start "$I" "$WORK/y3.out" --legs "N1.md"
wait_hb "$I" || fail "(u5542-3) no baseline heartbeat"
unowned_line "#2575:130m,#2600:15m"
wait_exit "$WPID"
check "(u5542-3) a PR joining the unowned set wakes at once" "WAKE unowned-prs #2575:130m,#2600:15m" "$(head -n1 "$WORK/y3.out")"

unowned_line "none"
start "$I" "$WORK/y4.out" --legs "N1.md"
wait_hb "$I" || fail "(u5542-4) no baseline heartbeat"
n=0
while [ "$n" -lt 50 ] && [ -e "$I.wait.unowned" ]; do sleep 0.1; n=$((n + 1)); done
check "(u5542-4) unowned-prs=none twice clears the marker" "" "$([ -e "$I.wait.unowned" ] && echo present)"
unowned_line "#2575:140m"
wait_exit "$WPID"
check "(u5542-4) a PR that turns unowned again wakes at once" "WAKE unowned-prs #2575:140m" "$(head -n1 "$WORK/y4.out")"

unowned_line "#2575:150m,#2600:25m"
start "$I" "$WORK/y6.out" --legs "N1.md"
wait_hb "$I" || fail "(u5542-6) no baseline heartbeat"
wait_exit "$WPID"
unowned_line "#2575:151m"
start "$I" "$WORK/y6b.out" --legs "N1.md"
wait_hb "$I" || fail "(u5542-6) no second baseline heartbeat"
sleep 1
unowned_line "#2575:152m,#2600:26m"
wait_exit "$WPID"
check "(u5542-6) a PR that leaves and rejoins a non-empty set wakes at once" "WAKE unowned-prs #2575:152m,#2600:26m" "$(head -n1 "$WORK/y6b.out")"

unowned_line "#2575:160m"
start "$I" "$WORK/y7.out" --legs "N1.md"
wait_hb "$I" || fail "(u5542-7) no baseline heartbeat"
wait_exit "$WPID"
unowned_line "?"
start "$I" "$WORK/y7b.out" --legs "N1.md"
wait_hb "$I" || fail "(u5542-7) no second baseline heartbeat"
sleep 1
check "(u5542-7) unowned-prs=? neither clears the marker nor wakes" "present" "$([ -e "$I.wait.unowned" ] && echo present)"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

reset_stub
I="$(new_inbox y5)"
start "$I" "$WORK/y5.out" --legs "N1.md"
wait_hb "$I" || fail "(u5542-5) no baseline heartbeat"
wait_exit "$WPID"
check "(u5542-5) a tick line with no unowned-prs= field is still a valid sample" "running" "$rc"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# --- (ts): a tracker that STAYS stale re-wakes once per streak ---
# tracker= class changes wake once (w); after the first STALE the class never moves
# again, so a console that did not act stayed unwoken for hours. The marker
# <inbox>.wait.trackerstale holds the epoch the streak was first seen; it wakes once
# past CONSOLE_WAIT_TRACKER_STALE_MIN (default 30) and clears when tracker leaves STALE.
reset_stub; tracker_line STALE:3h
I="$(new_inbox ts1)"
printf '%s\n' "$(( $(date +%s) - 2400 ))" > "$I.wait.trackerstale"
start "$I" "$WORK/ts1.out" --legs "N1.md"
wait_exit "$WPID"
check "(ts1) a tracker STALE for 40 min wakes (rc 0)" "0" "$rc"
check "(ts1) the wake names tracker-stale" "WAKE tracker-stale tracker=STALE:3h" "$(head -n1 "$WORK/ts1.out")"
timeout 3 bash "$WAIT" "$I" --legs "N1.md" > "$WORK/ts1b.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(ts2) the re-arm inside the same streak stays quiet" "" "$(cat "$WORK/ts1b.out")"
check "(ts2) and is still waiting (rc 124)" "124" "$rc"
reset_stub; tracker_line STALE:5m
I="$(new_inbox ts3)"
timeout 3 bash "$WAIT" "$I" --legs "N1.md" > "$WORK/ts3.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(ts3) a tracker first seen STALE does not re-wake yet" "" "$(cat "$WORK/ts3.out")"
check "(ts3) but the streak is recorded" "present" "$([ -e "$I.wait.trackerstale" ] && echo present)"
reset_stub; tracker_line ok
timeout 3 bash "$WAIT" "$I" --legs "N1.md" > "$WORK/ts4.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(ts4) tracker back to ok clears the streak marker" "absent" "$([ -e "$I.wait.trackerstale" ] && echo present || echo absent)"

reset_stub; tracker_line STALE:3h
I="$(new_inbox ts5)"
printf '%s\n' "$(( $(date +%s) - 2400 ))" > "$I.wait.trackerstale"
CONSOLE_WAIT_TRACKER_STALE_MIN=08 start "$I" "$WORK/ts5.out" --legs "N1.md"
wait_exit "$WPID"
check "(ts5) a leading-zero threshold (08) is decimal, not an octal error" "WAKE tracker-stale tracker=STALE:3h" "$(head -n1 "$WORK/ts5.out")"

# --- (pc): the waiter closes a wrapped predecessor console -------
# The console doc's first line names its predecessor (`successor to <doc>.md`). The
# waiter runs close-wrapped-leg.sh --console on it once, logs a Results bullet; exit
# 6/7 retry on the next sample; an unfinished predecessor (3 lock held, 4 not WRAPPED)
# is left alone; any other refusal wakes the console once (WAKE predecessor-open).
cat > "$STUB/close.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB/close.calls"
n="$(wc -l < "$STUB/close.calls" | tr -d ' ')"
rc="$(sed -n "${n}p" "$STUB/close.rcs" 2>/dev/null)"; [ -n "$rc" ] || rc="$(tail -n 1 "$STUB/close.rcs")"
[ -z "$rc" ] || [ "$rc" -eq 0 ] || { [ -f "$STUB/close.msg" ] && cat "$STUB/close.msg" >&2 || echo "close-wrapped-leg: refusing - stub rc $rc" >&2; }
exit "${rc:-0}"
EOF
export CONSOLE_WAIT_CLOSE="$STUB/close.sh"
pc_console() { # <dir name>: fixture console doc naming predecessor AS.md; prints the console doc path
    mkdir -p "$WORK/$1"
    printf '# AT — CONSOLE — successor to AS.md (fill signal 45 %%)\n\n## Results (newest at the bottom)\n\n- 10:00 LIVE AT\n' > "$WORK/$1/AT.md"
    printf '# AS\n\n## Results (newest at the bottom)\n\n- 09:00 WRAPPED\n' > "$WORK/$1/AS.md"
    : > "$STUB/close.calls"; printf '%s\n' "$2" > "$STUB/close.rcs"
    printf '%s' "$WORK/$1/AT.md"
}
reset_stub
CD="$(pc_console pc1 0)"; I="$(new_inbox pc1)"
timeout 4 bash "$WAIT" "$I" --doc "$CD" --legs "N1.md" > "$WORK/pc1.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(pc1) a wrapped predecessor is closed through close-wrapped-leg --console, once" "--console $WORK/pc1/AS.md" "$(cat "$STUB/close.calls")"
check "(pc1) the close logs a Results bullet in the console doc" "1" "$(tail -n +4 "$CD" | grep -c 'predecessor.*AS.*closed')"
check "(pc1) a closed predecessor is not a wake (still waiting, rc 124)" "124" "$rc"
reset_stub
CD="$(pc_console pc2 6)"; I="$(new_inbox pc2)"; printf '6\n0\n' > "$STUB/close.rcs"
timeout 6 bash "$WAIT" "$I" --doc "$CD" --legs "N1.md" > "$WORK/pc2.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(pc2) exit 6 (live subtree) retries on the next sample, then closes" "2" "$(wc -l < "$STUB/close.calls" | tr -d ' ')"
check "(pc2) a retryable refusal wakes nothing" "" "$(cat "$WORK/pc2.out")"
reset_stub
CD="$(pc_console pc3 5)"; I="$(new_inbox pc3)"
start "$I" "$WORK/pc3.out" --doc "$CD" --legs "N1.md"
wait_exit "$WPID"
check "(pc3) any other refusal wakes the console (rc 0)" "0" "$rc"
check "(pc3) the wake is WAKE predecessor-open" "WAKE predecessor-open rc=5" "$(head -n1 "$WORK/pc3.out")"
timeout 4 bash "$WAIT" "$I" --doc "$CD" --legs "N1.md" > "$WORK/pc3b.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(pc3) it wakes once: the re-arm is quiet" "" "$(cat "$WORK/pc3b.out")"
reset_stub
CD="$(pc_console pc4 3)"; I="$(new_inbox pc4)"; printf '3\n4\n' > "$STUB/close.rcs"
timeout 6 bash "$WAIT" "$I" --doc "$CD" --legs "N1.md" > "$WORK/pc4.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(pc4) a held-lock or not-WRAPPED predecessor is asked, then left alone: no wake" "" "$(cat "$WORK/pc4.out")"
check "(pc4) and nothing is logged" "0" "$(tail -n +4 "$CD" | grep -c 'predecessor')"
check "(pc4) and it is retried (the predecessor may wrap later)" "yes" "$([ "$(wc -l < "$STUB/close.calls" | tr -d ' ')" -ge 2 ] && echo yes)"
reset_stub
mkdir -p "$WORK/pc5"; printf '# AT — CONSOLE — successor to none — first console of the chain\n\n## Results (newest at the bottom)\n' > "$WORK/pc5/AT.md"
: > "$STUB/close.calls"; I="$(new_inbox pc5)"
timeout 3 bash "$WAIT" "$I" --doc "$WORK/pc5/AT.md" --legs "N1.md" > "$WORK/pc5.out" 2>/dev/null
check "(pc5) a console with no predecessor doc closes nothing" "0" "$(wc -l < "$STUB/close.calls" | tr -d ' ')"
reset_stub
CD="$(pc_console pc6 5)"; I="$(new_inbox pc6)"
echo "close-wrapped-leg: refusing - 10 live session(s) matched leg names [x] (need exactly 1)" > "$STUB/close.msg"
start "$I" "$WORK/pc6.out" --doc "$CD" --legs "N1.md"
wait_exit "$WPID"
rm -f "$STUB/close.msg"
check "(pc6) 10 live sessions is not 0: the ambiguous refusal wakes" "WAKE predecessor-open rc=5" "$(head -n1 "$WORK/pc6.out")"
reset_stub
CD="$(pc_console pc7 0)"; I="$(new_inbox pc7)"
printf '#!/usr/bin/env bash\nexec sleep 30\n' > "$STUB/close.sleep.sh"; chmod +x "$STUB/close.sleep.sh"
CONSOLE_WAIT_CLOSE="$STUB/close.sleep.sh" CONSOLE_WAIT_CLOSE_TIMEOUT=1 start "$I" "$WORK/pc7.out" --doc "$CD" --legs "N1.md"
sleep 0.5
printf -- '- 03:45 [telegram from=1 chat=2] hello\n' >> "$I"
n=0
while [ "$n" -lt 100 ] && kill -0 "$WPID" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
check "(pc7) a hung close is killed at CONSOLE_WAIT_CLOSE_TIMEOUT: the Telegram line still wakes within 10 s" "WAKE telegram" "$(head -n1 "$WORK/pc7.out")"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
reset_stub
CD="$(pc_console pc8 0)"; I="$(new_inbox pc8)"
CONSOLE_WAIT_CLOSE="$STUB/close.sleep.sh" CONSOLE_WAIT_CLOSE_TIMEOUT=1 CONSOLE_WAIT_CLOSE_HANGS=2 start "$I" "$WORK/pc8.out" --doc "$CD" --legs "N1.md"
n=0
while [ "$n" -lt 300 ] && kill -0 "$WPID" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
check "(pc8) a close that hangs every sample wakes after CONSOLE_WAIT_CLOSE_HANGS in a row" "WAKE predecessor-open rc=124" "$(head -n1 "$WORK/pc8.out")"
check "(pc8) and it is marked woke, so it wakes once" "woke:$WORK/pc8/AS.md" "$(cat "$I.wait.predecessor" 2>/dev/null)"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
unset CONSOLE_WAIT_CLOSE

# --- (su) --succession: the successor's one wake -----------------------------
# The tracker is stubbed (CONSOLE_WAIT_TRACKER): it prints $STUB/su.out. The waiter
# itself only reads the COMPLETE / INCOMPLETE line and the clock.
reset_stub
# shellcheck disable=SC2016  # the stub body expands when the stub runs
printf '#!/usr/bin/env bash\ncat "$STUB/su.out"\n' > "$STUB/su-tracker.sh"
SUCD="$WORK/su-console.md"; : > "$SUCD"
export CONSOLE_WAIT_TRACKER="$STUB/su-tracker.sh" CONSOLE_WAIT_SUCCESSION_SEC=1
printf 'N1 quoted-back\nN2 quoted-back\nCOMPLETE 2/2\nbash append-results.sh doc "LIVE - done"\n' > "$STUB/su.out"
I="$(new_inbox su1)"
start "$I" "$WORK/su1.out" --doc "$SUCD" --succession S2 --legs "N1.md"
wait_exit "$WPID"
check "(su1) every leg quoted back wakes once, rc 0" "0" "$rc"
check "(su1) the wake names the tally" "WAKE succession complete 2/2" "$(head -n1 "$WORK/su1.out")"
check "(su1) the block carries the printed LIVE command" "yes" "$(grep -q '^bash append-results.sh' "$WORK/su1.out" && echo yes)"
check "(su1) the exit reason is logged" "yes" "$(grep -q 'exit=wake-succession' "$I.wait" && echo yes)"

printf 'N1 quoted-back\nN2 missing\nINCOMPLETE 1/2 (waiting on: N2)\n' > "$STUB/su.out"
I="$(new_inbox su2)"
timeout 4 bash "$WAIT" "$I" --doc "$SUCD" --succession S2 --silent-min 5 --legs "N1.md" > "$WORK/su2.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(su2) a short tally inside the silent window stays quiet" "" "$(cat "$WORK/su2.out")"
check "(su2) and keeps waiting (rc 124)" "124" "$rc"

I="$(new_inbox su3)"
start "$I" "$WORK/su3.out" --doc "$SUCD" --succession S2 --silent-min 0 --legs "N1.md"
wait_exit "$WPID"
check "(su3) a tally silent past --silent-min wakes once, rc 0" "0" "$rc"
check "(su3) the partial wake names k/n and the window" "WAKE succession partial 1/2 silent 0 min" "$(head -n1 "$WORK/su3.out")"
check "(su3) the block names the leg still out" "yes" "$(grep -q 'waiting on: N2' "$WORK/su3.out" && echo yes)"

printf 'tracker blew up\n' > "$STUB/su.out"
I="$(new_inbox su3b)"
start "$I" "$WORK/su3b.out" --doc "$SUCD" --succession S2 --silent-min 0 --legs "N1.md"
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
start "$I" "$WORK/su5a.out" --doc "$SUCD" --succession S2 --legs "N1.md"
wait_exit "$WPID"
check "(su5) first arm wakes once, rc 0" "0" "$rc"
timeout 4 bash "$WAIT" "$I" --doc "$SUCD" --succession S2 --legs "N1.md" > "$WORK/su5b.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(su5) a re-arm with the same --succession does not re-wake at once" "124" "$rc"
check "(su5) and prints no second wake" "" "$(cat "$WORK/su5b.out")"
unset CONSOLE_WAIT_TRACKER CONSOLE_WAIT_SUCCESSION_SEC

# --- (rol) <inbox>.relay-on-live: the outgoing console's one wake ------------------
# Lock status and relay-batch are stubbed; the waiter reads only the lock rc (11 = held fresh).
reset_stub
# shellcheck disable=SC2016  # the stub bodies expand when the stub runs
printf '#!/usr/bin/env bash\nexit "$(cat "$STUB/rol.rc")"\n' > "$STUB/rol-lock.sh"
# shellcheck disable=SC2016  # as above
printf '#!/usr/bin/env bash\necho "SENDMESSAGE to=N1 :: relay to $3"\n' > "$STUB/rol-relay.sh"
export CONSOLE_WAIT_LOCK_STATUS="$STUB/rol-lock.sh" CONSOLE_WAIT_RELAY="$STUB/rol-relay.sh" CONSOLE_WAIT_SUCCESSION_SEC=1
ROLD="$WORK/rol-console.md"; : > "$ROLD"
echo 0 > "$STUB/rol.rc"
I="$(new_inbox rol1)"
printf 'S2\n%s\n' "$WORK/rol-succ.md" > "$I.relay-on-live"
timeout 4 bash "$WAIT" "$I" --doc "$ROLD" --legs "N1.md" > "$WORK/rol1.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(rol1) a successor with no held lock yields no wake (rc 124)" "124" "$rc"
check "(rol1) and the marker stays for the next sample" "yes" "$([ -s "$I.relay-on-live" ] && echo yes)"

echo 11 > "$STUB/rol.rc"
touch "$I.handover"
start "$I" "$WORK/rol2.out" --doc "$ROLD" --legs "N1.md"
wait_exit "$WPID"
check "(rol2) a held successor lock wakes once in handover mode, rc 0" "0" "$rc"
check "(rol2) the wake names the successor" "WAKE relay-on-live successor=S2" "$(head -n1 "$WORK/rol2.out")"
check "(rol2) the block carries the relay lines" "yes" "$(grep -q '^SENDMESSAGE to=N1' "$WORK/rol2.out" && echo yes)"
check "(rol2) the marker is consumed" "no" "$([ -e "$I.relay-on-live" ] && echo yes || echo no)"
check "(rol2) the exit reason is logged" "yes" "$(grep -q 'exit=wake-relay-on-live' "$I.wait" && echo yes)"

# a failing relay-batch wakes once with its rc and consumes the marker (no resend)
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUB/rol-relay.sh"
I="$(new_inbox rol3)"
printf 'S2\n%s\n' "$WORK/rol-succ.md" > "$I.relay-on-live"
timeout 4 bash "$WAIT" "$I" --doc "$ROLD" --legs "N1.md" > "$WORK/rol3.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(rol3) a failing relay still wakes once, rc 0" "0" "$rc"
check "(rol3) the wake carries the relay rc" "WAKE relay-on-live successor=S2 relay-failed rc=1" "$(head -n1 "$WORK/rol3.out")"
check "(rol3) and the marker is consumed, so nothing is resent" "no" "$([ -e "$I.relay-on-live" ] && echo yes || echo no)"
unset CONSOLE_WAIT_LOCK_STATUS CONSOLE_WAIT_RELAY CONSOLE_WAIT_SUCCESSION_SEC

# --- (k) usage ---------------------------------------------------------------
bash "$WAIT" >/dev/null 2>&1; rc=$?
check "(k) no inbox argument is a usage error (rc 2)" "2" "$rc"

# --- (hb): console-budget.sh HANDOVER wakes the console once per streak ------
# Needs --doc (the console's name is the doc basename, passed as --title). A
# marker <inbox>.wait.budget outlives the waiter; verdict OK clears it.
cat > "$STUB/budget.sh" <<'EOF'
#!/usr/bin/env bash
case "$*" in *--resolve*) printf 'x\n' >> "$STUB/budget.resolves"; printf '%s\n' "$STUB/budget.transcript"; exit 0 ;; esac
printf '%s %s\n' "$*" "$CONTEXT_FILL_TRANSCRIPT" >> "$STUB/budget.calls"
cat "$STUB/budget.out"; exit "$(cat "$STUB/budget.rc")"
EOF
export CONSOLE_WAIT_BUDGET="$STUB/budget.sh"
printf 'budget turns=151 cache_read=12.0M verdict=HANDOVER\n' > "$STUB/budget.out"; printf '3\n' > "$STUB/budget.rc"
reset_stub; : > "$STUB/budget.calls"; I="$(new_inbox hb1)"
start "$I" "$WORK/hb1.out" --doc "$WORK/hb1/consoles/HB.md" --legs "N1.md"
wait_exit "$WPID"
check "(hb1) HANDOVER wakes with the budget line" "WAKE handover-budget budget turns=151 cache_read=12.0M verdict=HANDOVER" "$(head -n1 "$WORK/hb1.out")"
check "(hb1) and the waiter exits 0" "0" "$rc"
check "(hb1) the console is named by the doc basename and the resolved transcript is passed" "--title HB $STUB/budget.transcript" "$(head -n1 "$STUB/budget.calls")"
timeout 3 bash "$WAIT" "$I" --doc "$WORK/hb1/consoles/HB.md" --legs "N1.md" > "$WORK/hb1b.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(hb2) the re-arm inside the same streak stays quiet" "" "$(cat "$WORK/hb1b.out")"
printf 'budget turns=3 cache_read=0.1M verdict=OK\n' > "$STUB/budget.out"; printf '0\n' > "$STUB/budget.rc"
rm -f "$STUB/budget.resolves"; : > "$STUB/budget.calls"
timeout 3 bash "$WAIT" "$I" --doc "$WORK/hb1/consoles/HB.md" --legs "N1.md" > "$WORK/hb1c.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(hb3) verdict OK clears the streak marker" "absent" "$([ -e "$I.wait.budget" ] && echo present || echo absent)"
check "(hb3b) the transcript is resolved once per run, not per sample" "1:ok" "$(wc -l < "$STUB/budget.resolves" | tr -d ' '):$([ "$(wc -l < "$STUB/budget.calls")" -ge 2 ] && echo ok || echo few-samples)"
printf '2\n' > "$STUB/budget.rc"; : > "$I.wait.budget"
timeout 3 bash "$WAIT" "$I" --doc "$WORK/hb1/consoles/HB.md" --legs "N1.md" > "$WORK/hb1d.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(hb4) an unreadable transcript (rc 2) neither wakes nor clears the marker" "present:" "$([ -e "$I.wait.budget" ] && echo present):$(cat "$WORK/hb1d.out")"
rm -f "$I.wait.budget"
timeout 3 bash "$WAIT" "$I" --doc "$WORK/hb1/consoles/HB.md" --legs "N1.md" > "$WORK/hb1e.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(hb4b) rc 2 with no marker: no wake, no marker, the waiter ran to its timeout" "124:absent:" "$rc:$([ -e "$I.wait.budget" ] && echo present || echo absent):$(cat "$WORK/hb1e.out")"
printf '#!/usr/bin/env bash\ncase "$*" in *--resolve*) echo /x; exit 0 ;; esac\nexec sleep 30\n' > "$STUB/budget.hang.sh"
reset_stub; I="$(new_inbox hb6)"
CONSOLE_WAIT_BUDGET="$STUB/budget.hang.sh" CONSOLE_WAIT_BUDGET_TIMEOUT=1 start "$I" "$WORK/hb6.out" --doc "$WORK/hb1/consoles/HB.md" --legs "N1.md"
sleep 0.5
printf -- '- 03:45 [telegram from=1 chat=2] hello\n' >> "$I"
n=0
while [ "$n" -lt 100 ] && kill -0 "$WPID" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
check "(hb6) a hung budget read is killed at CONSOLE_WAIT_BUDGET_TIMEOUT: the Telegram line still wakes within 10 s" "WAKE telegram" "$(head -n1 "$WORK/hb6.out")"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
printf '#!/usr/bin/env bash\nexec sleep 30\n' > "$STUB/budget.hangresolve.sh"
reset_stub; I="$(new_inbox hb6b)"
CONSOLE_WAIT_BUDGET="$STUB/budget.hangresolve.sh" CONSOLE_WAIT_BUDGET_TIMEOUT=1 start "$I" "$WORK/hb6b.out" --doc "$WORK/hb1/consoles/HB.md" --legs "N1.md"
sleep 0.5
printf -- '- 03:45 [telegram from=1 chat=2] hello\n' >> "$I"
n=0
while [ "$n" -lt 100 ] && kill -0 "$WPID" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
check "(hb6b) a hung --resolve is killed at CONSOLE_WAIT_BUDGET_TIMEOUT: the Telegram line still wakes within 10 s" "WAKE telegram" "$(head -n1 "$WORK/hb6b.out")"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
printf '3\n' > "$STUB/budget.rc"; : > "$STUB/budget.calls"; I="$(new_inbox hb5)"
timeout 3 bash "$WAIT" "$I" --legs "N1.md" > "$WORK/hb5.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(hb5) without --doc the budget is not read and nothing wakes" "0:" "$(wc -l < "$STUB/budget.calls" | tr -d ' '):$(cat "$WORK/hb5.out")"
export CONSOLE_WAIT_BUDGET="$STUB/budget-off.sh"

# --- (st) stall= wakes once per NEW conflict/no-ci token; ci-slow/idle are report-only,
# a token leaving the set and an unchanged set never wake, absence is a valid sample
# RED control (console-wait.sh before this change): the new token never woke.
stall_line() { sed -E "s# stall=[^ ]*##; s#  *denials=none# stall=$1 denials=none#" "$STUB/tick.line" > "$STUB/tick.line.tmp" && mv "$STUB/tick.line.tmp" "$STUB/tick.line"; }
reset_stub
I="$(new_inbox st)"
start "$I" "$WORK/st.out" --legs "N1.md"
wait_hb "$I" || fail "(st) no baseline heartbeat"
tick_line "N1:FRESH" "ok"
stall_line 2887:conflict
wait_exit "$WPID"
check "(st) a new conflict stall ends the wait" "0" "$rc"
check "(st) the wake names stall" "WAKE tick changed=stall bank=PROCEED" "$(head -n1 "$WORK/st.out")"

reset_stub
tick_line "N1:FRESH" "ok"
stall_line 2887:conflict
I="$(new_inbox st2)"
start "$I" "$WORK/st2.out" --legs "N1.md"
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
start "$I" "$WORK/st4.out" --legs "N1.md"
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
start "$I" "$WORK/st3.out" --legs "N1.md"
wait_hb "$I" || fail "(st3) no baseline heartbeat"
wait_exit "$WPID"
check "(st3) a tick line with no stall= field is still a valid sample" "running" "$rc"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# an option-shaped first argument is refused before any path is derived from it
mkdir -p "$WORK/kopt"
(cd "$WORK/kopt" && bash "$WAIT" --help >"$WORK/kopt.out" 2>&1); rc=$?
check "(k) an option-shaped inbox argument is a usage error (rc 2)" "2" "$rc"
check "(k) and it writes no stray file into the cwd" "" "$(ls -A "$WORK/kopt")"
check "(k) and it prints the usage text" "yes" "$(grep -q '^usage: console-wait.sh' "$WORK/kopt.out" && echo yes)"
# control: an absolute inbox path still starts the waiter
reset_stub
I="$(new_inbox kctl)"
timeout 3 bash "$WAIT" "$I" --legs "N1.md" >/dev/null 2>&1; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(k) an absolute inbox path still starts the waiter (rc 124)" "124" "$rc"

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
