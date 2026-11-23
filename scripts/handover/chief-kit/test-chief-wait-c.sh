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
# Second part of the chief-wait suite: the (a) to (p) cases. The split is
# described in test-chief-wait.sh.
#
# Run: bash scripts/handover/chief-kit/test-chief-wait-c.sh
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

WORK="$(mktemp -d "${TMPDIR:-/tmp}/chief-wait-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$WORK"' EXIT

STUB="$WORK/stub"
mkdir -p "$STUB"
cat > "$STUB/tick.sh" <<'EOF'
#!/usr/bin/env bash
[ -f "$STUB/tick.rc" ] && exit "$(cat "$STUB/tick.rc")"
if [ -f "$STUB/tick.burn" ]; then i=0; while [ "$i" -lt 300000 ]; do i=$((i + 1)); done; fi
# tick.sleep: a slow tick (seconds), as a real gh-bound tick can be.
[ -f "$STUB/tick.sleep" ] && sleep "$(cat "$STUB/tick.sleep")"
# tick.ignoreterm: a hung tick that ignores SIGTERM (timeout needs -k).
if [ -f "$STUB/tick.ignoreterm" ]; then trap '' TERM; sleep 20; exit 0; fi
# tick.failafter: prints its line, then fails (a tick that dies mid-run).
if [ -f "$STUB/tick.failafter" ]; then cat "$STUB/tick.line"; exit 1; fi
if [ -f "$STUB/tick.hook" ]; then bash "$STUB/tick.hook"; rm -f "$STUB/tick.hook"; fi
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
export CHIEF_WAIT_DISPATCH="$STUB/no-dispatch.sh"
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
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/sweep-off.sh"
export WAIT_SWEEP_CMD="$STUB/sweep-off.sh" WAIT_FOCUS_CMD="$STUB/sweep-off.sh"

tick_line() {
    printf 'TICK 03:00 hb=%s workers=%s livestate=ok procs=2 models=x ceiling=ok atq=0 suites=0alive/0dead prs=%s bank=5h8/wk15/codex=? fill=40 tails=N1:LIVE inbox=none tick=UNKNOWN fleet=3/15 capacity=ok gql=4000/04:00 orphans=none nonces=ok legset=ok board=%s denials=none or=%s fails=%s\n' \
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

cat > "$STUB/ql.sh" <<'EOF'
#!/usr/bin/env bash
if [ -s "$STUB/ql.out" ]; then cat "$STUB/ql.out"; else echo 'sweep: no held locks'; fi
EOF
export HOLDS_QUEUE_LOCK="$STUB/ql.sh"
ql_live() { local k; : > "$STUB/ql.out"; for k in "$@"; do printf 'slug=u__himmel__%s-F1-case-2026-11-22 session=s host=h age=5s status=OK\n' "$k" >> "$STUB/ql.out"; done; }
ql_live HIMMEL-9942 PROJ-9942 PROJ-9012
cat > "$STUB/pagek.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s\n' "${2-}" "$1" >> "$STUB/pagek"
exit 0
EOF
chmod +x "$STUB/pagek.sh"
pk_kinds() { cut -d'|' -f1 "$STUB/pagek" 2>/dev/null | paste -sd, -; }
pk_n() { if [ -f "$STUB/pagek" ]; then grep -c . "$STUB/pagek" || true; else echo 0; fi; }

reset_stub
I="$(new_inbox a)"
timeout -k 5 4 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/a.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(a) an idle window with no event emits nothing" "" "$(cat "$WORK/a.out")"
check "(a) an idle waiter is still waiting when the window closes (rc 124)" "124" "$rc"
check "(a) the idle waiter wrote a heartbeat" "yes" "$(grep -q '^hb=[0-9]* pid=[0-9]* ' "$I.wait" && echo yes)"

timeout -k 5 3 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/a2.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(a2) a re-arm with nothing changed emits nothing" "" "$(cat "$WORK/a2.out")"
check "(a2) and is still waiting when the window closes (rc 124)" "124" "$rc"

reset_stub
I="$(new_inbox b)"
start "$I" "$WORK/b.out" --workers "N1.md"
wait_hb "$I" || fail "(b) no baseline heartbeat"
tick_line "N1:FREE" "ok"
wait_exit "$WPID"
check "(b) a worker going FREE ends the wait with rc 0" "0" "$rc"
check "(b) the wake names the changed field" "WAKE tick changed=workers usage=PROCEED" "$(head -n1 "$WORK/b.out")"
check "(b) the wake carries the tick line" "yes" "$(sed -n 2p "$WORK/b.out" | grep -q '^TICK .*workers=N1:FREE' && echo yes)"  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(b) exactly one wake block (2 lines)" "2" "$(wc -l < "$WORK/b.out" | tr -d ' ')"
check "(b) the exit reason is logged" "yes" "$(grep -q 'exit=wake-tick' "$I.wait" && echo yes)"
timeout -k 5 3 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/b2.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(b) the re-arm after the wake does not wake again for the same change" "" "$(cat "$WORK/b2.out")"
check "(b) the re-arm is still waiting when the window closes (rc 124)" "124" "$rc"

reset_stub
I="$(new_inbox hm)"
printf 'DEMO-nextleg-B\n' > "$I.handover"
# shellcheck disable=SC2016  # $STUB is meant to expand in the generated stub, not here
printf '#!/usr/bin/env bash\ntouch "%s/hm.ticked"\ncat "$STUB/tick.line"\n' "$WORK" > "$STUB/tick-count.sh"
CHIEF_WAIT_TICK="$STUB/tick-count.sh" start "$I" "$WORK/hm.out" --workers "N1.md"
sleep 1.5
tick_line "N1:FREE" "ok"
sleep 2
check "(hm) handover mode never runs a tick" "no" "$([ -e "$WORK/hm.ticked" ] && echo yes || echo no)"
check "(hm) a tick-field change does not wake a handover-mode waiter" "running" "$(kill -0 "$WPID" 2>/dev/null && echo running || echo exited)"
printf -- '- 03:50 [telegram from=1 chat=2] still here\n' >> "$I"
wait_exit "$WPID"
check "(hm) Telegram still wakes a handover-mode waiter" "$(printf 'WAKE telegram\n- 03:50 [telegram from=1 chat=2] still here')" "$(cat "$WORK/hm.out")"

reset_stub
I="$(new_inbox hs)"
printf 'DEMO-nextleg-B\n' > "$I.handover"
touch -d '3 hours ago' "$I.handover"  # gnu-ok: Linux-only kit
# shellcheck disable=SC2016  # $STUB is meant to expand in the generated stub, not here
printf '#!/usr/bin/env bash\ntouch "%s/hs.ticked"\ncat "$STUB/tick.line"\n' "$WORK" > "$STUB/tick-count.sh"
CHIEF_WAIT_TICK="$STUB/tick-count.sh" CHIEF_WAIT_INTERVAL=1 start "$I" "$WORK/hs.out" --workers "N1.md"
sleep 3
check "(hs) a stale handover marker does not suppress ticks" "yes" "$([ -e "$WORK/hs.ticked" ] && echo yes || echo no)"
kill "$WPID" 2>/dev/null

reset_stub
printf '#!/usr/bin/env bash\nexit 11\n' > "$STUB/hr-lock.sh"
printf '#!/usr/bin/env bash\necho "SENDMESSAGE to=N1 :: relay"\necho "RELAYED 1 of 1"\n' > "$STUB/hr-relay.sh"
HRD="$WORK/hr-chief.md"; : > "$HRD"
I="$(new_inbox hr)"
printf 'S2\n%s\n' "$WORK/hr-succ.md" > "$I.relay-on-live"
touch "$I.handover"
CHIEF_WAIT_LOCK_STATUS="$STUB/hr-lock.sh" CHIEF_WAIT_RELAY="$STUB/hr-relay.sh" CHIEF_WAIT_SUCCESSION_SEC=1 start "$I" "$WORK/hr.out" --doc "$HRD" --workers "N1.md"
wait_exit "$WPID"
check "(hr) the relay wake still names the successor" "WAKE relay-on-live successor=S2" "$(head -n1 "$WORK/hr.out")"
check "(hr) control: the relay line is sent and RELAYED stays the last line" "RELAYED 1 of 1" "$(tail -n1 "$WORK/hr.out")"
check "(hr) control: the wake is printed once" "1" "$(grep -c '^WAKE ' "$WORK/hr.out")"
check "(hr) the block's second line says: re-arm once, read nothing, wrap on LIVE, stop" "1" "$(sed -n 2p "$WORK/hr.out" | grep -c '^AFTER RELAYED: re-arm this waiter once.*read nothing.*LIVE.*chief.sh wrap.*stop')"
check "(hr) and it names the bounded resume" "1" "$(sed -n 2p "$WORK/hr.out" | grep -c 'resumes after CHIEF_WAIT_HANDOVER_MIN minutes')"

reset_stub
I="$(new_inbox hr2)"
printf 'S2\n' > "$I.handover"
touch -d '3 hours ago' "$I.handover"  # gnu-ok: Linux-only kit
start "$I" "$WORK/hr2.out" --workers "N1.md"
wait_hb "$I" || fail "(hr2) no baseline heartbeat"
tick_line "N1:FREE" "ok"
wait_exit "$WPID"
check "(hr2) a re-armed waiter whose handover marker is stale wakes on a tick change" "WAKE tick changed=workers usage=PROCEED" "$(head -n1 "$WORK/hr2.out")"

reset_stub
I="$(new_inbox hso)"
# shellcheck disable=SC2016  # $STUB is meant to expand in the generated stub, not here
printf '#!/usr/bin/env bash\ntouch "%s/hso.ticked"\ncat "$STUB/tick.line"\n' "$WORK" > "$STUB/tick-old.sh"
CONSOLE_WAIT_TICK="$STUB/tick-old.sh" bash "$WAIT" "$I" --workers "N1.md" > "$WORK/hso.out" 2>"$WORK/hso.out.err" &
WPID=$!
wait_hb "$I" || fail "(hso) no baseline heartbeat"
check "(hso) the retired CONSOLE_WAIT_TICK is never run" "no" "$([ -e "$WORK/hso.ticked" ] && echo yes || echo no)"
kill "$WPID" 2>/dev/null

reset_stub
I="$(new_inbox b3724)"
start "$I" "$WORK/b3724.out" --workers "N1.md"
wait_hb "$I" || fail "(b3724) no baseline heartbeat"
sed -i 's/denials=none/denials=N1:1:SHIP-STEP/' "$STUB/tick.line"  # gnu-ok: Linux-only kit
wait_exit "$WPID"
check "(b3724) a denials= class change ends the wait with rc 0" "0" "$rc"
check "(b3724) the wake names denials" "WAKE tick changed=denials usage=PROCEED" "$(head -n1 "$WORK/b3724.out")"

denials_expiry() {
    reset_stub
    sed -i "s/denials=none/denials=$2/" "$STUB/tick.line"  # gnu-ok: Linux-only kit
    I="$(new_inbox "$1")"
    start "$I" "$WORK/$1.out" --workers "N1.md"
    wait_hb "$I" || fail "($1) no baseline heartbeat"
    sed -i "s/denials=$2/denials=$3/" "$STUB/tick.line"  # gnu-ok: Linux-only kit
    wait_exit "$WPID"
}
denials_expiry b3724x1 'N1:1:SHIP-STEP' none
check "(b3724x) a denial aging out to none does not wake" "running" "$rc"
stop_waiter "$WPID"
denials_expiry b3724x2 'N1:2:REPEAT' 'N1:1'
check "(b3724x) a count falling as one row expires does not wake" "running" "$rc"
stop_waiter "$WPID"
denials_expiry b3724x3 'N1:1' 'N1:2:REPEAT'
check "(b3724x) a count rising still wakes" "0" "$rc"
check "(b3724x) and names denials" "WAKE tick changed=denials usage=PROCEED" "$(head -n1 "$WORK/b3724x3.out")"
[ "$rc" = running ] && { stop_waiter "$WPID"; }
denials_expiry b3724x4 'N1:1' 'N1:1,N2:1'
check "(b3724x) a second worker's denial wakes" "0" "$rc"
[ "$rc" = running ] && { stop_waiter "$WPID"; }
reset_stub
sed -i 's/denials=none/denials=N1:1/' "$STUB/tick.line"  # gnu-ok: Linux-only kit
I="$(new_inbox b3724x5)"
start "$I" "$WORK/b3724x5.out" --workers "N1.md"
wait_hb "$I" || fail "(b3724x5) no baseline heartbeat"
sed -i 's/denials=N1:1/denials=none/' "$STUB/tick.line"  # gnu-ok: Linux-only kit
sleep 3.5
check "(b3724x) the waiter is still waiting after the expiry" "yes" "$(kill -0 "$WPID" 2>/dev/null && echo yes)"
sed -i 's/denials=none/denials=N1:1/' "$STUB/tick.line"  # gnu-ok: Linux-only kit
wait_exit "$WPID"
check "(b3724x) a fresh denial after an expiry wakes again" "0" "$rc"
[ "$rc" = running ] && { stop_waiter "$WPID"; }

reset_stub
tick_line "N1:FRESH" "STALE:5m" "1m" '#10' '7.50:key-limit_remaining'
I="$(new_inbox c)"
start "$I" "$WORK/c.out" --workers "N1.md"
wait_hb "$I" || fail "(c) no baseline heartbeat"
tick_line "N1:FRESH" "STALE:9m" "7m" '#10' '0.00:key-limit_remaining'
wait_exit "$WPID"
check "(c) heartbeat, board age or exhausted OpenRouter credit does not wake" "running" "$rc"
stop_waiter "$WPID"
check "(c) a TERM is logged as the exit reason" "yes" "$(grep -q 'exit=signal-TERM' "$I.wait" && echo yes)"

reset_stub
I="$(new_inbox c4670)"
start "$I" "$WORK/c4670.out" --workers "N1.md"
wait_hb "$I" || fail "(c4670) no baseline heartbeat"
tick_line "N1:FRESH" "ok" "1m" '#10' 'skip' '3/2@denied/guard-a*2!1'
wait_exit "$WPID"
check "(c4670) a fails= change does not wake" "running" "$rc"
[ "$rc" = running ] && { stop_waiter "$WPID"; }

reset_stub
I="$(new_inbox d)"
start "$I" "$WORK/d.out" --workers "N1.md"
wait_hb "$I" || fail "(d) no baseline heartbeat"
sed 's/prs=#10/prs=none/' "$STUB/tick.line" > "$STUB/tick.blip"
wait_exit "$WPID"
check "(d) a change seen on one sample only does not wake" "running" "$rc"
stop_waiter "$WPID"

reset_stub
I="$(new_inbox d2)"
HOUSEKEEPING_DIGEST_SECS=0 start "$I" "$WORK/d2.out" --workers "N1.md"
wait_hb "$I" || fail "(d2) no baseline heartbeat"
printf '0\n' > "$STUB/tick.churn"
wait_exit "$WPID"
check "(d2) a key that differs from the saved one on every sample wakes" "0" "$rc"
check "(d2) the wake names prs" "WAKE tick changed=prs usage=PROCEED" "$(head -n1 "$WORK/d2.out")"
[ "$rc" = running ] && { stop_waiter "$WPID"; }

reset_stub
I="$(new_inbox e)"
start "$I" "$WORK/e.out" --workers "N1.md"
wait_hb "$I" || fail "(e) no baseline heartbeat"
printf 'SKIPPED-BANK\n' > "$STUB/bank"
wait_exit "$WPID"
check "(e) a bank verdict change ends the wait" "0" "$rc"
check "(e) the wake names bank and carries the new verdict" "WAKE tick changed=usage usage=SKIPPED-BANK" "$(head -n1 "$WORK/e.out")"

reset_stub
I="$(new_inbox f)"
start "$I" "$WORK/f.out" --workers "N1.md"
wait_hb "$I" || fail "(f) no baseline heartbeat"
printf '1\n' > "$STUB/tick.rc"
wait_exit "$WPID"
check "(f) a failing tick.sh does not wake" "running" "$rc"
check "(f) the heartbeat records the failed tick" "yes" "$(grep -q 'tick=fail' "$I.wait" && echo yes)"
stop_waiter "$WPID"

reset_stub
I="$(new_inbox f2)"
start "$I" "$WORK/f2.out" --workers "N1.md"
wait_hb "$I" || fail "(f2) no baseline heartbeat"
: > "$STUB/bank"
wait_exit "$WPID"
check "(f2) an empty bank read does not wake" "running" "$rc"
check "(f2) the heartbeat records the failed sample" "yes" "$(grep -q 'tick=fail' "$I.wait" && echo yes)"
stop_waiter "$WPID"

reset_stub
I="$(new_inbox f3)"
start "$I" "$WORK/f3.out" --workers "N1.md"
wait_hb "$I" || fail "(f3) no baseline heartbeat"
printf 'Traceback: boom\n' > "$STUB/bank"
wait_exit "$WPID"
check "(f3) a non-token bank line does not wake" "running" "$rc"
stop_waiter "$WPID"

reset_stub
I="$(new_inbox f4)"
HOUSEKEEPING_DIGEST_SECS=0 CHIEF_WAIT_FAIL_WAKE=3 start "$I" "$WORK/f4.out" --workers "N1.md"
wait_hb "$I" || fail "(f4) no baseline heartbeat"
printf '1\n' > "$STUB/tick.rc"
wait_exit "$WPID"
check "(f4) a streak of failed samples ends the wait" "0" "$rc"
[ "$rc" = running ] && { stop_waiter "$WPID"; }
check "(f4) the wake names the failure streak and the failing step" "WAKE tick-fail samples=3 step=tick-exit:1" "$(head -n1 "$WORK/f4.out")"
HOUSEKEEPING_DIGEST_SECS=0 CHIEF_WAIT_FAIL_WAKE=3 timeout -k 5 6 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/f4b.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(f4) the re-arm during the same streak runs silent" "124" "$rc"
check "(f4) the re-arm during the same streak prints nothing" "" "$(cat "$WORK/f4b.out")"
rm -f "$STUB/tick.rc"
HOUSEKEEPING_DIGEST_SECS=0 CHIEF_WAIT_FAIL_WAKE=3 timeout -k 5 3 bash "$WAIT" "$I" --workers "N1.md" >/dev/null 2>&1  # gnu-ok: Linux-only kit; pipefail-ok: none set
printf '1\n' > "$STUB/tick.rc"
HOUSEKEEPING_DIGEST_SECS=0 CHIEF_WAIT_FAIL_WAKE=3 timeout -k 5 8 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/f4c.out" 2>/dev/null  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(f4) a new streak after a success wakes again" "WAKE tick-fail samples=3 step=tick-exit:1" "$(head -n1 "$WORK/f4c.out")"

reset_stub
I="$(new_inbox d1)"
CHIEF_WAIT_FAIL_WAKE=2 start "$I" "$WORK/d1.out" --workers "N1.md"
wait_hb "$I" || fail "(8934) no baseline heartbeat"
printf '1\n' > "$STUB/tick.rc"
sleep 4
stop_waiter "$WPID"
check "(8934) a tick-fail streak does not wake, it joins the digest" "0:1" "$(grep -c '^WAKE ' "$WORK/d1.out"):$(grep -c '^tick-fail samples=2 step=tick-exit:1' "$I.wait.housekeeping" 2>/dev/null)"

reset_stub
sed -i 's/ bank=/ unowned-prs=#2575:12m bank=/' "$STUB/tick.line"  # gnu-ok: Linux-only kit
I="$(new_inbox d2)"
timeout -k 5 4 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/d2.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit
check "(8934) the first sight of a young unowned PR does not wake, it joins the digest" "124:0:1" "$rc:$(grep -c '^WAKE ' "$WORK/d2.out"):$(grep -c '^unowned-prs #2575:12m' "$I.wait.housekeeping" 2>/dev/null)"

reset_stub
sed -i 's/ bank=/ unowned-prs=#4946:70m,#4891:957m,#4999:5m bank=/' "$STUB/tick.line"  # gnu-ok: Linux-only kit
I="$(new_inbox u1)"
timeout -k 5 6 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/u1.out" 2>/dev/null; rc=$?
check "(9599) an unowned PR older than 30 m wakes, exit 0" "0" "$rc"
check "(9599) the wake names each aged PR and not the young one" "WAKE unowned-pr 4946,4891" "$(head -n1 "$WORK/u1.out")"
timeout -k 5 4 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/u2.out" 2>/dev/null; rc=$?
check "(9599) the same aged set does not re-wake inside the window" "124:0" "$rc:$(grep -c '^WAKE unowned-pr' "$WORK/u2.out")"
sed -i 's/unowned-prs=[^ ]* bank=/unowned-prs=#4999:5m bank=/' "$STUB/tick.line"  # gnu-ok: Linux-only kit
timeout -k 5 4 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/u3.out" 2>/dev/null
check "(9599) a sample with no aged PR clears the aged marker" "no" "$([ -e "$I.wait.unowned-aged" ] && echo yes || echo no)"

reset_stub
I="$(new_inbox d3)"
start "$I" "$WORK/d3.out" --workers "N1.md"
wait_hb "$I" || fail "(8934) no baseline heartbeat"
sed -i 's/prs=#10/prs=#10,#11/' "$STUB/tick.line"  # gnu-ok: Linux-only kit
sleep 4
stop_waiter "$WPID"
check "(8934) a prs-only tick change does not wake, it joins the digest" "0:1" "$(grep -c '^WAKE ' "$WORK/d3.out"):$(grep -c '^tick changed=prs ' "$I.wait.housekeeping" 2>/dev/null)"

reset_stub
I="$(new_inbox d4)"
printf '%s\n' 'tick-fail samples=3 step=tick-timeout:120s' 'unowned-prs #2575:120m TICK 03:00 payload' 'tick changed=prs usage=PROCEED' 'board-stale board=STALE:2h' > "$I.wait.housekeeping"
date +%s > "$I.wait.housekeeping.since"
start "$I" "$WORK/d4.out" --workers "N1.md"
wait_hb "$I" || fail "(8934) no baseline heartbeat"
printf -- '- 03:10 [telegram from=1 chat=2] hello\n' >> "$I"
wait_exit "$WPID"
check "(8934) the telegram wake is first and carries the three look-only lines" "WAKE telegram:1:1:1" "$(head -n1 "$WORK/d4.out"):$(grep -c 'tick-fail samples=3 step=tick-timeout:120s' "$WORK/d4.out"):$(grep -c 'unowned-prs #2575:120m' "$WORK/d4.out"):$(grep -c 'tick changed=prs' "$WORK/d4.out")"
check "(8934) the carried lines leave the buffer, board-stale stays" "board-stale board=STALE:2h" "$(cat "$I.wait.housekeeping")"

reset_stub
I="$(new_inbox d5)"
start "$I" "$WORK/d5.out" --workers "N1.md"
wait_hb "$I" || fail "(8934) no baseline heartbeat"
sed -i 's/tails=N1:LIVE/tails=N1:BLOCKED/' "$STUB/tick.line"  # gnu-ok: Linux-only kit
wait_exit "$WPID"
check "(8934) a BLOCKED event wakes at once with the digest on" "0:WAKE tick changed=tails" "$rc:$(head -n1 "$WORK/d5.out" | cut -d' ' -f1-3)"
reset_stub
I="$(new_inbox d6)"
start "$I" "$WORK/d6.out" --workers "N1.md"
wait_hb "$I" || fail "(8934) no baseline heartbeat"
sed -i 's/tails=N1:LIVE/tails=N1:READY/' "$STUB/tick.line"  # gnu-ok: Linux-only kit
wait_exit "$WPID"
check "(8934) a READY event wakes at once with the digest on" "0:WAKE tick changed=tails" "$rc:$(head -n1 "$WORK/d6.out" | cut -d' ' -f1-3)"
reset_stub
I="$(new_inbox d7)"
start "$I" "$WORK/d7.out" --workers "N1.md"
wait_hb "$I" || fail "(8934) no baseline heartbeat"
printf -- '- 03:11 [telegram from=1 chat=2] urgent\n' >> "$I"
wait_exit "$WPID"
check "(8934) a Telegram line wakes at once with the digest on" "0:WAKE telegram" "$rc:$(head -n1 "$WORK/d7.out")"

reset_stub
I="$(new_inbox d8)"
printf '%s\n' 'tick-fail samples=3 step=tick-timeout:120s' > "$I.wait.housekeeping"
date +%s > "$I.wait.housekeeping.since"
printf '%s\n' 'N9 wrapped -' > "$I.wait.digest"
bash "$WAIT" "$I" --workers "N1.md" > /dev/full 2> "$WORK/d8.err" &
WPID=$!
wait_hb "$I" || fail "(8934) no baseline heartbeat"
sed -i 's/tails=N1:LIVE/tails=N1:BLOCKED/' "$STUB/tick.line"  # gnu-ok: Linux-only kit
wait_exit "$WPID"
check "(8934) a failed write keeps the look-only line and the digest queued" "1:1" "$(grep -c '^tick-fail samples=3' "$I.wait.housekeeping" 2>/dev/null):$(grep -c '^N9 wrapped' "$I.wait.digest" 2>/dev/null)"

reset_stub
I="$(new_inbox g)"
start "$I" "$WORK/g.out" --workers "N1.md"
wait_hb "$I" || fail "(g) no baseline heartbeat"
printf -- '- 03:10 [telegram from=1 chat=2] hello\n' >> "$I"
wait_exit "$WPID"
check "(g) an inbox line ends the wait with rc 0" "0" "$rc"
check "(g) the wake is a telegram block with the line" "$(printf 'WAKE telegram\n- 03:10 [telegram from=1 chat=2] hello')" "$(cat "$WORK/g.out")"
timeout -k 5 3 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/g2.out" 2>/dev/null  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(g) a re-arm does not replay a delivered line" "" "$(cat "$WORK/g2.out")"

printf -- '- 03:20 [telegram from=1 chat=2] queued\n' >> "$I"
timeout -k 5 3 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/h.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(h) a line queued between arms is delivered by the next arm" "$(printf 'WAKE telegram\n- 03:20 [telegram from=1 chat=2] queued')" "$(cat "$WORK/h.out")"
check "(h) and the arm exits 0" "0" "$rc"

reset_stub
I="$(new_inbox i)"
start "$I" "$WORK/i.out" --workers "N1.md"
wait_hb "$I" || fail "(i) no baseline heartbeat"
bash "$WAIT" "$I" --workers "N1.md" > "$WORK/i2.out" 2>&1; rc=$?
check "(i) a second waiter on a live one is refused with rc 3" "3" "$rc"
check "(i) the refusal names the live pid" "yes" "$(grep -q "pid $WPID" "$WORK/i2.out" && echo yes)"
stop_waiter "$WPID"

reset_stub
I="$(new_inbox j)"
timeout -k 5 2 bash "$WAIT" "$I" --workers "N1.md" >/dev/null 2>&1; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(j) the first arm ran until the timeout" "124" "$rc"
base1="$(cat "$I.wait.state" 2>/dev/null)"
tick_line "N1:FRESH,N2:FRESH" "ok"
timeout -k 5 3 bash "$WAIT" "$I" --workers "N1.md N2.md" > "$WORK/j.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(j) the re-arm ran until the timeout" "124" "$rc"
check "(j) a re-arm with a new worker set re-baselines instead of waking" "" "$(cat "$WORK/j.out")"
base2="$(cat "$I.wait.state" 2>/dev/null)"
if [ -n "$base1" ] && [ -n "$base2" ] && [ "$base1" != "$base2" ]; then pass "(j) the saved baseline moved to the new worker set"; else fail "(j) the saved baseline moved to the new worker set (was '$base1' now '$base2')"; fi

reset_stub
I="$(new_inbox l)"
start "$I" "$WORK/l.out" --workers "N1.md"
wait_hb "$I" || fail "(l) no baseline heartbeat"
tick_line "N1:FREE" "ok"; : > "$STUB/tick.failafter"
sleep 3.5
check "(l) a failing tick's TICK line does not wake" "" "$(cat "$WORK/l.out")"
check "(l) the failing tick is recorded as tick=fail" "yes" "$(grep -q 'tick=fail' "$I.wait" && echo yes)"
stop_waiter "$WPID"

reset_stub
printf '3\n' > "$STUB/tick.sleep"
I="$(new_inbox m)"
start "$I" "$WORK/m.out" --workers "N1.md"
sleep 1
check "(m) a waiter mid-sample already shows state=sampling" "yes" "$(grep -q 'state=sampling' "$I.wait" 2>/dev/null && echo yes)"
bash "$WAIT" "$I" --workers "N1.md" > "$WORK/m2.out" 2>&1; rc=$?
check "(m) a second waiter during the first sample is refused (rc 3)" "3" "$rc"
stop_waiter "$WPID"

reset_stub
I="$(new_inbox n)"
start "$I" "$WORK/n.out" --workers "N1.md"
wait_hb "$I" || fail "(n) no baseline heartbeat"
printf -- '- 03:30 [telegram from=1 chat=2] half' >> "$I"
sleep 1
check "(n) a partial line does not wake" "" "$(cat "$WORK/n.out")"
printf ' done\n' >> "$I"
wait_exit "$WPID"
check "(n) completing the line wakes with it whole" "$(printf 'WAKE telegram\n- 03:30 [telegram from=1 chat=2] half done')" "$(cat "$WORK/n.out")"

reset_stub
: > "$STUB/tick.ignoreterm"
I="$(new_inbox o)"
CHIEF_WAIT_TICK_TIMEOUT=1 start "$I" "$WORK/o.out" --workers "N1.md"
sleep 2
printf -- '- 03:40 [telegram from=1 chat=2] hello\n' >> "$I"
n=0
while [ "$n" -lt 150 ] && kill -0 "$WPID" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
check "(o) the line is delivered within 15 s despite a TERM-ignoring tick" "WAKE telegram" "$(head -n1 "$WORK/o.out")"
stop_waiter "$WPID"

reset_stub
I="$(new_inbox p)"
bash "$WAIT" "$I" --workers "N1.md" > "$WORK/p1.out" 2>&1 &
P1=$!
bash "$WAIT" "$I" --workers "N1.md" > "$WORK/p2.out" 2>&1 &
P2=$!
sleep 2
alive=0
kill -0 "$P1" 2>/dev/null && alive=$((alive + 1))
kill -0 "$P2" 2>/dev/null && alive=$((alive + 1))
check "(p) exactly one of two simultaneous waiters is still running" "1" "$alive"
stop_waiter "$P1"; stop_waiter "$P2"

reset_stub
I="$WORK/q/consoles/c.md"
start "$I" "$WORK/q.out" --workers "N1.md"
wait_hb "$I" || fail "(q) no baseline heartbeat when consoles/ was absent"
check "(q) the waiter created the inbox" "yes" "$([ -f "$I" ] && echo yes)"
stop_waiter "$WPID"

reset_stub
I="$(new_inbox r)"
HOUSEKEEPING_DIGEST_SECS=0 CHIEF_WAIT_FAIL_WAKE=2 start "$I" "$WORK/r.out" --workers "N1.md"
wait_hb "$I" || fail "(r) no baseline heartbeat"
sed 's/ tails=N1:LIVE//' "$STUB/tick.line" > "$STUB/tick.line.tmp" && mv "$STUB/tick.line.tmp" "$STUB/tick.line"
wait_exit "$WPID"
check "(r) a streak of malformed samples ends the wait" "0" "$rc"
check "(r) the wake is tick-fail, never a changed key from an empty field, naming the field" "WAKE tick-fail samples=2 step=missing-field:tails" "$(head -n1 "$WORK/r.out")"
[ "$rc" = running ] && { stop_waiter "$WPID"; }

# shellcheck disable=SC2016 # literal grep pattern, not a shell expansion
check "(s) no in-place '> \"\$key_file\"' write remains (must go through .tmp + mv)" "0" \
    "$(grep -cF '> "$key_file"' "$HERE/chief-wait.sh")"

reset_stub
tick_line "N1:FRESH" "STALE:5m"
I="$(new_inbox t)"
start "$I" "$WORK/t.out" --workers "N1.md"
wait_hb "$I" || fail "(t) no baseline heartbeat"
tick_line "N1:FRESH" "ok"
wait_exit "$WPID"
check "(t) a board move to ok alone does not wake" "running" "$rc"
check "(t) the saved key still moved to board=ok" "yes" "$(grep -q 'board=ok' "$I.wait.state" && echo yes)"
stop_waiter "$WPID"

reset_stub
I="$(new_inbox u)"
HOUSEKEEPING_DIGEST_SECS=0 start "$I" "$WORK/u.out" --workers "N1.md"
wait_hb "$I" || fail "(u) no baseline heartbeat"
tick_line "N1:FRESH" "STALE:3m"
wait_exit "$WPID"
check "(u) a board move to STALE ends the wait" "0" "$rc"
check "(u) the wake names board" "WAKE tick changed=board usage=PROCEED" "$(head -n1 "$WORK/u.out")"

reset_stub
tick_line "N1:FRESH" "STALE:5m"
I="$(new_inbox v)"
HOUSEKEEPING_DIGEST_SECS=0 start "$I" "$WORK/v.out" --workers "N1.md"
wait_hb "$I" || fail "(v) no baseline heartbeat"
tick_line "N1:FRESH" "ok" "1m" "#99"
wait_exit "$WPID"
check "(v) board-to-ok combined with a prs change still wakes" "0" "$rc"
check "(v) the wake names only prs, not board" "WAKE tick changed=prs usage=PROCEED" "$(head -n1 "$WORK/v.out")"

P_NOPROC="$WORK/p-noproc"; mkdir -p "$P_NOPROC"; export CHIEF_WAIT_PROC="$P_NOPROC"
denials_rise() {
    reset_stub; rm -f "$STUB/pages"; rm -rf "$HIMMEL_DENIAL_ACK_DIR"
    sed -i "s/denials=none/denials=$2/" "$STUB/tick.line"  # gnu-ok: Linux-only kit
    I="$(new_inbox "$1")"
    start "$I" "$WORK/$1.out" --workers "N1.md"
    wait_hb "$I" || fail "($1) no baseline heartbeat"
    sed -i "s/denials=$2/denials=$3/" "$STUB/tick.line"  # gnu-ok: Linux-only kit
    wait_exit "$WPID"
}
pages_n() { if [ -f "$STUB/pages" ]; then wc -l < "$STUB/pages" | tr -d ' '; else echo 0; fi; }

denials_rise p1 none 'N1:1:SHIP-STEP'
check "(p1) a SHIP-STEP appearing wakes" "0" "$rc"
check "(p1) and pages exactly once" "1" "$(pages_n)"
check "(p1) the page is exactly worker, count and class" "DENIAL-PAGE N1 SHIP-STEP x1 - a classifier denial parked this worker. Review it, then: ack-denial.sh N1" "$(head -n1 "$STUB/pages" 2>/dev/null)"
check "(p1) a page record is written for the refusal check" "SHIP-STEP" "$(sed -n 's/^class=//p' "$HIMMEL_DENIAL_ACK_DIR/N1.page" 2>/dev/null)"
check "(p1) the wake block is still exactly the tick wake (2 lines)" "2" "$(wc -l < "$WORK/p1.out" | tr -d ' ')"

denials_rise p2 none 'N1:3:PAUSE-RISK'
check "(p2) a PAUSE-RISK appearing pages once" "1" "$(pages_n)"
check "(p2) naming the class" "yes" "$(grep -q 'PAUSE-RISK x3' "$STUB/pages" && echo yes)"

denials_rise p3 none 'N1:2:REPEAT'
check "(p3) a REPEAT is a wake but not a page" "0" "$(pages_n)"
check "(p3) and writes no page record" "no" "$([ -e "$HIMMEL_DENIAL_ACK_DIR/N1.page" ] && echo yes || echo no)"

denials_rise p4 'N1:3:PAUSE-RISK' 'N1:1:SHIP-STEP'
check "(p4) a class rising to SHIP-STEP pages" "1" "$(pages_n)"

denials_rise p5 'N1:1:SHIP-STEP' 'N1:2:SHIP-STEP'
check "(p5) a count rise inside the same class wakes" "0" "$rc"
check "(p5) but does not page again" "0" "$(pages_n)"

denials_rise p5b 'N1:1:SHIP-STEP' none
check "(p5b) a denial expiring out is neither wake nor page" "0" "$(pages_n)"
[ "$rc" = running ] && { stop_waiter "$WPID"; }

denials_rise p5c 'N1:1' 'N1:1,N2:1:SHIP-STEP'
check "(p5c) a second worker's SHIP-STEP pages under its own label" "DENIAL-PAGE N2 SHIP-STEP x1 - a classifier denial parked this worker. Review it, then: ack-denial.sh N2" "$(head -n1 "$STUB/pages" 2>/dev/null)"

RCPROC="$WORK/rc-proc"; rm -rf "$RCPROC"; mkdir -p "$RCPROC/7001" "$RCPROC/7002" "$WORK/rc-wt/worktrees/N1" "$WORK/rc-wt/worktrees/N2"
ln -s "$WORK/rc-wt/worktrees/N1" "$RCPROC/7001/cwd"
printf 'claude\0--remote-control\0HIMMEL-8320-n1-session\0--model\0x\0-n\0HIMMEL-8320-n1-session\0load doc and continue\0' > "$RCPROC/7001/cmdline"
ln -s "$WORK/rc-wt/worktrees/N2" "$RCPROC/7002/cwd"
printf 'claude\0--model\0x\0-n\0HIMMEL-8320-n2-session\0load doc and continue\0' > "$RCPROC/7002/cmdline"
export CHIEF_WAIT_PROC="$RCPROC"
denials_rise p5e none 'N1:1:SHIP-STEP'
check "(p5e) a native worker with Remote Control: the page names its session" "DENIAL-PAGE N1 SHIP-STEP x1 - a classifier denial parked this worker. Open the Remote Control session HIMMEL-8320-n1-session in the Claude app and answer there, or review it and: ack-denial.sh N1" "$(head -n1 "$STUB/pages" 2>/dev/null)"
denials_rise p5f none 'N2:1:SHIP-STEP'
check "(p5f) a worker without Remote Control keeps the plain page" "DENIAL-PAGE N2 SHIP-STEP x1 - a classifier denial parked this worker. Review it, then: ack-denial.sh N2" "$(head -n1 "$STUB/pages" 2>/dev/null)"
export CHIEF_WAIT_PROC="$P_NOPROC"

rm -f "$STUB/pagek"; SAVE_PAGE_CMD="$CHIEF_WAIT_PAGE_CMD"; export CHIEF_WAIT_PAGE_CMD="$STUB/pagek.sh"
denials_rise k5 none 'N1:1:SHIP-STEP'
export CHIEF_WAIT_PAGE_CMD="$SAVE_PAGE_CMD"
check "(R3.2) DENIAL-PAGE passes its kind denial-page" "denial-page" "$(pk_kinds)"
if [ "$(id -u)" != 0 ]; then
    mkdir -p "$WORK/ro" && chmod 555 "$WORK/ro"
    rm -f "$STUB/pagek"; SAVE_ACK_DIR="$HIMMEL_DENIAL_ACK_DIR"; export HIMMEL_DENIAL_ACK_DIR="$WORK/ro/acks"; export CHIEF_WAIT_PAGE_CMD="$STUB/pagek.sh"
    denials_rise k6 none 'N1:1:SHIP-STEP'
    export CHIEF_WAIT_PAGE_CMD="$SAVE_PAGE_CMD"; export HIMMEL_DENIAL_ACK_DIR="$SAVE_ACK_DIR"
    check "(R3.2) a denial whose page record cannot be written still pages, unclassified so it escalates" "1:" "$(pk_n):$(pk_kinds)"
    chmod 755 "$WORK/ro"
fi

denials_rise p5d none 'N1:1:SHIP-STEP'
timeout -k 5 3 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/p5d2.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(p5d) the re-arm keeps waiting until the timeout cuts it off (124)" "124" "$rc"
check "(p5d) the re-arm after a paged wake is silent" "" "$(cat "$WORK/p5d2.out")"
check "(p5d) and does not page the same rise again" "1" "$(pages_n)"

cat > "$STUB/page-fail.sh" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
chmod +x "$STUB/page-fail.sh"
CHIEF_WAIT_PAGE_CMD="$STUB/page-fail.sh" denials_rise p6a none 'N1:1:SHIP-STEP'
check "(p6) a failing sender still wakes with rc 0" "0" "$rc"
check "(p6) and the wake block is intact" "WAKE tick changed=denials usage=PROCEED" "$(head -n1 "$WORK/p6a.out")"
check "(p6) and the page record is written even though the send failed" "SHIP-STEP" "$(sed -n 's/^class=//p' "$HIMMEL_DENIAL_ACK_DIR/N1.page" 2>/dev/null)"
cat > "$STUB/page-hang.sh" <<'EOF'
#!/usr/bin/env bash
sleep 30
EOF
chmod +x "$STUB/page-hang.sh"
CHIEF_WAIT_PAGE_CMD="$STUB/page-hang.sh" denials_rise p6b none 'N1:1:SHIP-STEP'
check "(p6) a hung sender is cut off by the page timeout and the wake still lands" "0" "$rc"

cat > "$STUB/page-hang-log.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$(dirname "$0")/hang-calls"
sleep 30
EOF
chmod +x "$STUB/page-hang-log.sh"
rm -f "$STUB/hang-calls"
CHIEF_WAIT_PAGE_CMD="$STUB/page-hang-log.sh" denials_rise p6d 'N1:1' 'N1:1:SHIP-STEP,N2:1:SHIP-STEP'
check "(p6d) two hung sends still wake with rc 0" "0" "$rc"
check "(p6d) only one send is attempted inside the shared budget" "1" "$(wc -l < "$STUB/hang-calls" 2>/dev/null | tr -d ' ')"
check "(p6d) and both workers still get a page record" "N1 N2" "$(for k in N1 N2; do [ -f "$HIMMEL_DENIAL_ACK_DIR/$k.page" ] && printf '%s ' "$k"; done | sed 's/ $//')"

mkdir -p "$WORK/ro" && chmod 500 "$WORK/ro"
HIMMEL_DENIAL_ACK_DIR="$WORK/ro/sub" denials_rise p6c none 'N1:1:SHIP-STEP'
check "(p6) an unwritable record dir still wakes with rc 0" "0" "$rc"
chmod 700 "$WORK/ro"
unset CHIEF_WAIT_PROC

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
