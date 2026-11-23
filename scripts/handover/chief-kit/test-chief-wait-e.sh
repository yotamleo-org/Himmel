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
# Fifth part of the chief-wait suite: the (su) cases onward. The split is
# described in test-chief-wait.sh.
#
# Run: bash scripts/handover/chief-kit/test-chief-wait-e.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WAIT="${CHIEF_WAIT:-$HERE/chief-wait.sh}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() {
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
export CHIEF_WAIT_FAIL_WAKE=1000
cat > "$STUB/page.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$STUB/pages"
exit 0
EOF
chmod +x "$STUB/page.sh"
export CHIEF_WAIT_PAGE_CMD="$STUB/page.sh" CHIEF_WAIT_PAGE_TIMEOUT=2
export HIMMEL_DENIAL_ACK_DIR="$WORK/acks"
cat > "$STUB/budget-off.sh" <<'EOF'
#!/usr/bin/env bash
exit 2
EOF
export CHIEF_WAIT_BUDGET="$STUB/budget-off.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/orphan-off.sh"
export CHIEF_WAIT_ORPHAN="$STUB/orphan-off.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/sweep-off.sh"
export WAIT_SWEEP_CMD="$STUB/sweep-off.sh" WAIT_FOCUS_CMD="$STUB/sweep-off.sh"
export CHIEF_WAIT_DISPATCH="$STUB/no-dispatch.sh"
DISPATCH_SEAM_AT_START="${CHIEF_WAIT_DISPATCH:-}"

tick_line() {
    printf 'TICK 03:00 hb=%s legs=%s livestate=ok procs=2 models=x ceiling=ok atq=0 suites=0alive/0dead prs=%s bank=5h8/wk15/codex=? fill=40 tails=N1:LIVE inbox=none tick=UNKNOWN fleet=3/15 capacity=ok gql=4000/04:00 orphans=none nonces=ok legset=ok board=%s denials=none or=%s fails=%s\n' \
        "${3:-1m}" "$1" "${4:-#10}" "$2" "${5:-skip}" "${6:-none}" > "$STUB/tick.line"
}
reset_stub() { rm -f "$STUB/tick.rc" "$STUB/tick.blip" "$STUB/tick.churn" "$STUB/tick.sleep" "$STUB/tick.failafter" "$STUB/tick.ignoreterm"; tick_line "N1:FRESH" "ok"; printf 'PROCEED\n' > "$STUB/bank"; }

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
start() {
    local inbox="$1" out="$2"; shift 2
    bash "$WAIT" "$inbox" "$@" > "$out" 2>"$out.err" &
    WPID=$!
}


printf '#!/usr/bin/env bash\nprintf "ARGS %%s\\n" "$*"\n' > "$STUB/dispatch.sh"
export CHIEF_WAIT_DISPATCH="$STUB/dispatch.sh"

reset_stub
# shellcheck disable=SC2016  # the stub body expands when the stub runs
printf '#!/usr/bin/env bash\ncat "$STUB/su.out"\n' > "$STUB/su-tracker.sh"
SUCD="$WORK/su-chief.md"; : > "$SUCD"
export CHIEF_WAIT_TRACKER="$STUB/su-tracker.sh" CHIEF_WAIT_SUCCESSION_SEC=1
printf 'N1 quoted-back\nN2 quoted-back\nCOMPLETE 2/2\nbash append-results.sh doc "LIVE - done"\n' > "$STUB/su.out"
I="$(new_inbox su1)"
start "$I" "$WORK/su1.out" --doc "$SUCD" --succession S2 --workers "N1.md"
wait_exit "$WPID"
check "(su1) every worker quoted back wakes once, rc 0" "0" "$rc"
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
check "(su3) the block names the worker still out" "yes" "$(grep -q 'waiting on: N2' "$WORK/su3.out" && echo yes)"

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

printf 'N1 quoted-back\nN2 quoted-back\nCOMPLETE 2/2\nbash append-results.sh doc "LIVE - done"\n' > "$STUB/su.out"
I="$(new_inbox su5)"
start "$I" "$WORK/su5a.out" --doc "$SUCD" --succession S2 --workers "N1.md"
wait_exit "$WPID"
check "(su5) first arm wakes once, rc 0" "0" "$rc"
timeout 4 bash "$WAIT" "$I" --doc "$SUCD" --succession S2 --workers "N1.md" > "$WORK/su5b.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(su5) a re-arm with the same --succession does not re-wake at once" "124" "$rc"
check "(su5) and prints no second wake" "" "$(cat "$WORK/su5b.out")"
unset CHIEF_WAIT_TRACKER CHIEF_WAIT_SUCCESSION_SEC

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

printf '#!/usr/bin/env bash\nexit 1\n' > "$STUB/rol-relay.sh"
I="$(new_inbox rol3)"
printf 'S2\n%s\n' "$WORK/rol-succ.md" > "$I.relay-on-live"
timeout 4 bash "$WAIT" "$I" --doc "$ROLD" --workers "N1.md" > "$WORK/rol3.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(rol3) a failing relay still wakes once, rc 0" "0" "$rc"
check "(rol3) the wake carries the relay rc" "WAKE relay-on-live successor=S2 relay-failed rc=1" "$(head -n1 "$WORK/rol3.out")"
check "(rol3) and the marker is consumed, so nothing is resent" "no" "$([ -e "$I.relay-on-live" ] && echo yes || echo no)"
unset CHIEF_WAIT_LOCK_STATUS CHIEF_WAIT_RELAY CHIEF_WAIT_SUCCESSION_SEC

bash "$WAIT" >/dev/null 2>&1; rc=$?
check "(k) no inbox argument is a usage error (rc 2)" "2" "$rc"

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
printf 'focus=FAILED:drift:budget\n' > "$STUB/focus.out"; echo $(( $(date +%s) - 1000 )) > "$I.wait.sweep"
timeout 3 bash "$WAIT" "$I" --doc "$SWDOC" --workers "N1.md" > "$WORK/sw8e.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(sw8e) the same failure under another stage name does not wake again" "124:" "$rc:$(cat "$WORK/sw8e.out")"
printf 'focus=FAILED:timeout\n' > "$STUB/focus.out"; echo $(( $(date +%s) - 1000 )) > "$I.wait.sweep"
timeout 3 bash "$WAIT" "$I" --doc "$SWDOC" --workers "N1.md" > "$WORK/sw8f.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(sw8f) a stage that flips between timeout and drift:budget wakes the chief once" "124:" "$rc:$(cat "$WORK/sw8f.out")"
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
launches() { grep -cx "focus --doc $SWDOC" "$STUB/focus.calls"; }
fr_run() {
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

od5_line() {
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
tick_line "N1:FRESH" "ok"
wait_exit "$WPID"
check "(od5c) nor does a tick line going back to legs= with the same value" "running" "$rc"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

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

mkdir -p "$WORK/kopt"
(cd "$WORK/kopt" && bash "$WAIT" --help >"$WORK/kopt.out" 2>&1); rc=$?
check "(k) an option-shaped inbox argument is a usage error (rc 2)" "2" "$rc"
check "(k) and it writes no stray file into the cwd" "" "$(ls -A "$WORK/kopt")"
check "(k) and it prints the usage text" "yes" "$(grep -q '^usage: chief-wait.sh' "$WORK/kopt.out" && echo yes)"
reset_stub
I="$(new_inbox kctl)"
timeout 3 bash "$WAIT" "$I" --workers "N1.md" >/dev/null 2>&1; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(k) an absolute inbox path still starts the waiter (rc 124)" "124" "$rc"

reset_stub
: > "$STUB/tick.strict"; rm -f "$STUB/tick.args"
I="$(new_inbox ws1)"
start "$I" "$WORK/ws1.out" --since prev-arm --receipt r1 --workers "N1.md"
wait_hb "$I" || fail "(ws1) no baseline heartbeat: the tick failed on a waiter flag"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
check "(ws1) --since and --receipt reach no tick sample" "" "$(grep -e '--since' -e '--receipt' -e 'prev-arm' "$STUB/tick.args")"
check "(ws1) the tick still got the other flags" "yes" "$(grep -q -e '--workers N1.md' "$STUB/tick.args" && echo yes)"
check "(ws1) no tick-usage or tick-fail wake printed" "" "$(cat "$WORK/ws1.out")"
timeout 3 bash "$WAIT" "$I" --since >/dev/null 2>&1; rc=$?  # gnu-ok: Linux-only kit
check "(ws1) a trailing --since with no value is a usage error (rc 2)" "2" "$rc"
timeout 3 bash "$WAIT" "$I" --receipt >/dev/null 2>&1; rc=$?  # gnu-ok: Linux-only kit
check "(ws1) a trailing --receipt with no value is a usage error (rc 2)" "2" "$rc"

reset_stub
rm -f "$STUB/tick.strict"
printf '#!/usr/bin/env bash\necho "tick.sh: unknown flag --bogus" >&2\necho "second stderr line" >&2\nexit 2\n' > "$STUB/tick-usage.sh"
I="$(new_inbox ws2)"
CHIEF_WAIT_TICK="$STUB/tick-usage.sh" start "$I" "$WORK/ws2.out" --workers "N1.md"
wait_exit "$WPID"
check "(ws2) a tick exit 2 ends the wait at once, rc 0" "0" "$rc"
[ "$rc" = running ] && { kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; }
check "(ws2) the wake names tick-usage and tick's first stderr line" "WAKE tick-usage rc=2 tick.sh: unknown flag --bogus" "$(head -n1 "$WORK/ws2.out")"
check "(ws2) only the first stderr line is carried" "" "$(grep 'second stderr line' "$WORK/ws2.out")"
printf '#!/usr/bin/env bash\nsleep 25\n' > "$STUB/focus-stall.sh"
I="$(new_inbox ws2b)"
WAIT_FOCUS_CMD="$STUB/focus-stall.sh" CHIEF_WAIT_TICK="$STUB/tick-usage.sh" timeout 10 bash "$WAIT" "$I" --doc "$SUCD" --workers "N1.md" > "$WORK/ws2b.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit
check "(ws2b) the usage wake is not held behind a stalled focus status check (rc 0, not 124)" "0" "$rc"
check "(ws2b) and carries the tick's first stderr line" "WAKE tick-usage rc=2 tick.sh: unknown flag --bogus" "$(head -n1 "$WORK/ws2b.out")"

printf '#!/usr/bin/env bash\necho "boom" >&2\nexit 1\n' > "$STUB/tick-exit1.sh"
I="$(new_inbox ws3)"
CHIEF_WAIT_TICK="$STUB/tick-exit1.sh" start "$I" "$WORK/ws3.out" --workers "N1.md"
wait_exit "$WPID"
check "(ws3) a tick exit 1 does not wake (CHIEF_WAIT_FAIL_WAKE not reached)" "running" "$rc"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
check "(ws3) and prints no tick-usage line" "" "$(grep 'tick-usage' "$WORK/ws3.out")"

reset_stub
rm -f "$STUB/tick.args"
printf 'N1 quoted-back\nN2 missing\nINCOMPLETE 1/2 (waiting on: N2)\n' > "$STUB/su.out"
I="$(new_inbox ws4)"
CHIEF_WAIT_TRACKER="$STUB/su-tracker.sh" CHIEF_WAIT_SUCCESSION_SEC=1 start "$I" "$WORK/ws4.out" --since prev-arm --doc "$SUCD" --succession S2 --silent-min 0 --workers "N1.md"
wait_exit "$WPID"
check "(ws4) --succession still wakes with --since beside it" "WAKE succession partial 1/2 silent 0 min" "$(head -n1 "$WORK/ws4.out")"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

ws5_run() {
    local label="$1"; shift
    rm -f "$STUB/tick.args"
    I="$(new_inbox "ws5-$label")"
    CHIEF_WAIT_TRACKER="$STUB/su-tracker.sh" CHIEF_WAIT_SUCCESSION_SEC=1 start "$I" "$WORK/ws5-$label.out" "$@" --doc "$SUCD" --succession S2 --silent-min 5 --workers "N1.md"
    wait_hb "$I" || fail "(ws5 $label) no baseline heartbeat"
    kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
    check "(ws5 $label) a tick sample ran with the other flags" "yes" "$(grep -q -e '--workers N1.md' "$STUB/tick.args" 2>/dev/null && echo yes)"
    check "(ws5 $label) and got none of --succession, --silent-min, --since" "" "$(grep -e '--succession' -e '--silent-min' -e '--since' "$STUB/tick.args")"
}
ws5_run with-since --since prev-arm
ws5_run no-since

case "$DISPATCH_SEAM_AT_START" in "$STUB"/*) seam_at_start=stub ;; *) seam_at_start="$DISPATCH_SEAM_AT_START" ;; esac
check "(hermetic) the dispatch seam named a stub from the first case" "stub" "$seam_at_start"
case "${CHIEF_WAIT_DISPATCH:-}" in "$STUB"/*) seam_now=stub ;; *) seam_now="${CHIEF_WAIT_DISPATCH:-}" ;; esac
check "(hermetic) and still names a stub at the end" "stub" "$seam_now"
check "(hermetic) no waiter output carries live pool=<n>/<n>/<n>/<n> data" "" "$(grep -rEl 'pool=[0-9]+/[0-9]+/[0-9]+/[0-9]+' "$WORK" 2>/dev/null)"

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
