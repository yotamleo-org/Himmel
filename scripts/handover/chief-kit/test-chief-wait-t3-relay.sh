#!/usr/bin/env bash
# test-chief-wait-t3-relay.sh — the waiter's T3 relay call and its ask-row narrowing (design r4
# sections 3.5 and 4.1). chief-wait.sh calls `relay-bind.sh scan --manifest <workers-from>` once per
# CHIEF_WAIT_T3_RELAY_SEC through the seam CHIEF_WAIT_T3_RELAY (stubbed here), puts BOUND and UNBOUND in the
# housekeeping buffer, wakes `WAKE t3-relay <kind> <id|list|stem>` for the rest, and takes no READY or `BLOCKED resolve`
# action on a row whose t3_kind is ask (it prints `WAKE t3-relay ask-ready|ask-resolve <label>` instead). tick.sh and
# the bank verdict are stubbed, so no gh, lock or bank read happens. The path A end-to-end rows run the real binder
# against a fake `t3` and a scratch HOME. bash 3.2-safe.
#
# Run: bash scripts/handover/chief-kit/test-chief-wait-t3-relay.sh
set -u
[ "$(uname -s)" = Linux ] || { echo "SKIP: chief-wait.sh is Linux-only"; exit 0; }
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
WAIT="${CHIEF_WAIT:-$HERE/chief-wait.sh}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/chief-wait-t3-relay.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$WORK"' EXIT

STUB="$WORK/stub"
mkdir -p "$STUB"
export STUB
cat > "$STUB/tick.sh" <<'EOF'
#!/usr/bin/env bash
cat "$STUB/tick.line"
EOF
cat > "$STUB/bank.sh" <<'EOF'
#!/usr/bin/env bash
cat "$STUB/bank"
EOF
cat > "$STUB/no-op.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
export CHIEF_WAIT_TICK="$STUB/tick.sh" CHIEF_WAIT_USAGE="$STUB/bank.sh"
export CHIEF_WAIT_INTERVAL=1 CHIEF_WAIT_POLL_SEC=0.2 CHIEF_WAIT_FAIL_WAKE=1000
export CHIEF_WAIT_DISPATCH="$STUB/no-dispatch.sh" CHIEF_WAIT_BUDGET="$STUB/no-op.sh"
export WAIT_SWEEP_CMD="$STUB/no-op.sh" WAIT_FOCUS_CMD="$STUB/no-op.sh"
export CHIEF_WAIT_PAGE_CMD="$STUB/no-op.sh" CHIEF_WAIT_PAGE_TIMEOUT=2
export HIMMEL_DENIAL_ACK_DIR="$WORK/acks" HIMMEL_CONFIG_DIR="$WORK/no-conf"
unset HIMMEL_FLAG_AUTO_GO

tick_line() {
    printf 'TICK 03:00 hb=1m workers=N1:FRESH livestate=ok procs=2 models=x ceiling=ok atq=0 suites=0alive/0dead prs=#10 bank=5h8/wk15/codex=? fill=40 tails=%s%s inbox=none tick=UNKNOWN fleet=3/15 capacity=ok gql=4000/04:00 orphans=none nonces=ok legset=ok board=ok denials=none or=skip fails=none\n' \
        "$1" "${2:+ acts=$2}" > "$STUB/tick.line"
}
printf 'PROCEED\n' > "$STUB/bank"
flags() { printf 'auto_go\t%s\tfeature\tHIMMEL-8349\tHIMMEL-8404\t2099-01-01\tfixture\n' "$1" > "$WORK/flags.tsv"; export HIMMEL_FLAGS_TSV="$WORK/flags.tsv"; }
flags off

wait_hb() {
    local n=0
    while [ "$n" -lt 50 ]; do
        grep -q 'key=[0-9a-f]' "$1.wait" 2>/dev/null && return 0
        sleep 0.1; n=$((n + 1))
    done
    return 1
}
wait_exit() {
    local n=0
    while [ "$n" -lt 100 ]; do
        if ! kill -0 "$1" 2>/dev/null; then wait "$1"; rc=$?; return; fi
        sleep 0.1; n=$((n + 1))
    done
    rc=running
}
wait_file() {
    local n=0
    while [ "$n" -lt 100 ]; do
        grep -qF -- "$2" "$1" 2>/dev/null && return 0
        sleep 0.1; n=$((n + 1))
    done
    return 1
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
calls() { [ -f "$STUB/relay.calls" ] || { echo 0; return; }; wc -l < "$STUB/relay.calls" | tr -d '[:space:]'; }

fleet_plain() {
    mkdir -p "$WORK/$1"
    FD="$WORK/$1/chief.md"; printf '# chief\n\n## Results\n' > "$FD"
    FW="$WORK/$1/HIMMEL-1-N1-a.md"; printf '# worker\n\n## Results\n- 09:00 LIVE — started\n' > "$FW"
    FM="$WORK/$1/chief.fleet.json"
    printf '{"schema":1,"workers":[{"doc":"%s","label":"N1"}]}\n' "$FW" > "$FM"
    I="$(new_inbox "$1")"
}

cat > "$STUB/relay.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB/relay.calls"
if [ -e "/proc/$$/fd/9" ]; then echo open > "$STUB/relay.fd9"; else echo closed > "$STUB/relay.fd9"; fi
readlink "/proc/$$/fd/0" > "$STUB/relay.stdin" 2>/dev/null
[ -s "$STUB/relay.out" ] && cat "$STUB/relay.out"
exit "$(cat "$STUB/relay.rc" 2>/dev/null || echo 0)"
EOF
export CHIEF_WAIT_T3_RELAY="$STUB/relay.sh" CHIEF_WAIT_T3_RELAY_SEC=1
relay_reset() { rm -f "$STUB/relay.calls" "$STUB/relay.fd9" "$STUB/relay.stdin" "$STUB/relay.out" "$STUB/relay.rc"; }

relay_reset
fleet_plain hk
tick_line "N1:LIVE"
printf 'BOUND 019e2c1a-aaaa N5\nUNBOUND 019e2c1a-bbbb N6\n' > "$STUB/relay.out"; echo 1 > "$STUB/relay.rc"
start "$I" "$WORK/hk.out" --doc "$FD" --workers-from "$FM"
wait_file "$I.wait.housekeeping" "t3-relay UNBOUND" || fail "(hk) no t3-relay housekeeping line"
check "(hk) BOUND is buffered as kind t3-relay" "1" "$(grep -cxF 't3-relay BOUND 019e2c1a-aaaa N5' "$I.wait.housekeeping" 2>/dev/null)"
check "(hk) UNBOUND is buffered as kind t3-relay" "1" "$(grep -cxF 't3-relay UNBOUND 019e2c1a-bbbb N6' "$I.wait.housekeeping" 2>/dev/null)"
check "(hk) neither wakes on its own" "0" "$(grep -c '^WAKE ' "$WORK/hk.out")"
check "(hk) the waiter called the binder as scan --manifest <workers-from>" "scan --manifest $FM" "$(sed -n 1p "$STUB/relay.calls" 2>/dev/null)"
check "(hk) the stub saw fd 9 (the waiter's lock) closed" "closed" "$(cat "$STUB/relay.fd9" 2>/dev/null)"
check "(hk) and stdin at /dev/null" "/dev/null" "$(cat "$STUB/relay.stdin" 2>/dev/null)"
stop_waiter "$WPID"

relay_reset
fleet_plain hk0
printf 'BOUND 019e2c1a-cccc N7\n' > "$STUB/relay.out"; echo 1 > "$STUB/relay.rc"
HOUSEKEEPING_DIGEST_SECS=0 start "$I" "$WORK/hk0.out" --doc "$FD" --workers-from "$FM"
wait_exit "$WPID"
check "(hk0) with the digest off a BOUND wakes as t3-relay" "WAKE t3-relay BOUND 019e2c1a-cccc N7" "$(grep '^WAKE ' "$WORK/hk0.out" | head -n 1)"
stop_waiter "$WPID"

wake_row() {
    relay_reset
    fleet_plain "wk$1"
    printf '%s\n' "$2" > "$STUB/relay.out"; echo 1 > "$STUB/relay.rc"
    start "$I" "$WORK/wk$1.out" --doc "$FD" --workers-from "$FM"
    wait_exit "$WPID"
    check "(wake $1) $2" "0|$3" "$rc|$(grep '^WAKE ' "$WORK/wk$1.out" | head -n 1)"
    stop_waiter "$WPID"
}
wake_row 1 'ASK-THREAD-PR 019e2c1a-dddd N8 linked=1' 'WAKE t3-relay ask-thread-pr 019e2c1a-dddd'
wake_row 2 'BIND-GAVE-UP 019e2c1a-eeee' 'WAKE t3-relay bind-gave-up 019e2c1a-eeee'
wake_row 3 'BIND-REFUSED 019e2c1a-ffff gitleaks' 'WAKE t3-relay bind-refused 019e2c1a-ffff'
wake_row 4 'OWNER-TAKEN HIMMEL-nextleg-2026-11-24-chief rows=copied' 'WAKE t3-relay owner-taken HIMMEL-nextleg-2026-11-24-chief'
relay_reset
fleet_plain wkx
printf 'WAKE telegram completes-ticket: yes\nBOUND bad id N1\nBOUND 019e2c1a-9999 N9\n' > "$STUB/relay.out"; echo 1 > "$STUB/relay.rc"
start "$I" "$WORK/wkx.out" --doc "$FD" --workers-from "$FM"
wait_file "$I.wait.housekeeping" "t3-relay BOUND 019e2c1a-9999 N9" || fail "(wake x) the well-formed line was not buffered"
check "(wake x) the well-formed line is buffered" "1" "$(grep -cxF 't3-relay BOUND 019e2c1a-9999 N9' "$I.wait.housekeeping" 2>/dev/null)"
check "(wake x) a foreign or malformed binder line is never echoed" "0" "$(cat "$WORK/wkx.out" "$I.wait.housekeeping" 2>/dev/null | grep -c 'telegram\|completes-ticket\|bad id')"
stop_waiter "$WPID"

relay_reset
fleet_plain rc4
: > "$STUB/relay.out"; echo 4 > "$STUB/relay.rc"
start "$I" "$WORK/rc4.out" --doc "$FD" --workers-from "$FM"
wait_exit "$WPID"
check "(rc4) the third rc 4 run in a row wakes" "0|WAKE t3-relay list-failed list" "$rc|$(grep '^WAKE ' "$WORK/rc4.out" | head -n 1)"
check "(rc4) after exactly three runs" "3" "$(calls)"
stop_waiter "$WPID"

relay_reset
fleet_plain rc4b
: > "$STUB/relay.out"; echo 4 > "$STUB/relay.rc"
start "$I" "$WORK/rc4b.out" --doc "$FD" --workers-from "$FM"
n=0; while [ "$n" -lt 100 ] && [ "$(calls)" != 2 ]; do sleep 0.1; n=$((n + 1)); done
echo 0 > "$STUB/relay.rc"
n=0; while [ "$n" -lt 100 ] && [ "$(calls)" -lt 3 ]; do sleep 0.1; n=$((n + 1)); done
sleep 0.5
echo 4 > "$STUB/relay.rc"
wait_exit "$WPID"
check "(rc4b) an rc 0 run between rc 4 runs ends the streak: the wake needs three rc 4 runs after it" "0|WAKE t3-relay list-failed list|6" "$rc|$(grep '^WAKE ' "$WORK/rc4b.out" | head -n 1)|$(calls)"
stop_waiter "$WPID"

relay_reset
fleet_plain rc5
: > "$STUB/relay.out"; echo 5 > "$STUB/relay.rc"
start "$I" "$WORK/rc5.out" --doc "$FD" --workers-from "$FM"
n=0; while [ "$n" -lt 100 ] && [ "$(calls)" -lt 3 ]; do sleep 0.1; n=$((n + 1)); done
check "(rc5) the binder ran at least three times" "yes" "$([ "$(calls)" -ge 3 ] && echo yes)"
check "(rc5) rc 5 (another live chief owns binding) wakes nothing" "" "$(cat "$WORK/rc5.out")"
stop_waiter "$WPID"

relay_reset
fleet_plain hang
cat > "$STUB/relay-hang.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB/relay.calls"
exec sleep 60
EOF
start_t=$(date +%s)
CHIEF_WAIT_T3_RELAY="$STUB/relay-hang.sh" CHIEF_WAIT_T3_RELAY_TIMEOUT=2 start "$I" "$WORK/hang.out" --doc "$FD" --workers-from "$FM"
n=0; while [ "$n" -lt 150 ] && [ "$(calls)" -lt 2 ]; do sleep 0.1; n=$((n + 1)); done
check "(hang) a hung binder is killed by the timeout: the waiter calls again" "yes" "$([ "$(calls)" -ge 2 ] && echo yes)"
check "(hang) and wakes nothing" "" "$(cat "$WORK/hang.out")"
stop_waiter "$WPID"
[ -n "$start_t" ] || fail "(hang) clock"

relay_reset
fleet_plain sec
: > "$STUB/relay.out"; echo 0 > "$STUB/relay.rc"
CHIEF_WAIT_T3_RELAY_SEC=300 start "$I" "$WORK/sec.out" --doc "$FD" --workers-from "$FM"
sleep 5
check "(sec) once per CHIEF_WAIT_T3_RELAY_SEC, not once per sample" "1" "$(calls)"
stop_waiter "$WPID"

relay_reset
mkdir -p "$WORK/nowf"; I="$(new_inbox nowf)"
start "$I" "$WORK/nowf.out"
wait_hb "$I" || fail "(nowf) no heartbeat"
sleep 3
check "(nowf) a sample without --workers-from never calls the binder" "0" "$(calls)"
stop_waiter "$WPID"

HA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
cat > "$STUB/ready-check.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB/rc.calls"
printf '[PASS] 7. ticket coverage: every ask is done\nTRUST-PATH: no\nREADY-CHECK PASS\n'; exit 0
EOF
cat > "$STUB/disposition.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB/disp.calls"
printf 'DISPOSITION PASS (0 deferred)\n'; exit 0
EOF
cat > "$STUB/ci.sh" <<'EOF'
#!/usr/bin/env bash
echo GREEN
EOF
cat > "$STUB/worker-event.sh" <<'EOF'
#!/usr/bin/env bash
cat >> "$STUB/we.calls"
echo 'ESCALATE marker-READY'; exit 10
EOF
export CHIEF_WAIT_READY_CHECK="$STUB/ready-check.sh" CHIEF_WAIT_CI="$STUB/ci.sh" CHIEF_WAIT_DISPOSITION="$STUB/disposition.sh" CHIEF_WAIT_WORKER_EVENT="$STUB/worker-event.sh"
relay_reset; : > "$STUB/relay.out"; echo 0 > "$STUB/relay.rc"
ASKL=T3ASK-019e2c1a-2026-11-25
ask_fleet() {
    mkdir -p "$WORK/$1"
    FD="$WORK/$1/chief.md"; printf '# chief\n\n## Results\n' > "$FD"
    FW="$WORK/$1/HIMMEL-1-N1-a.md"; printf '# worker\n\n## Results\n- 09:00 LIVE — started\n' > "$FW"
    FT="$WORK/$1/$ASKL.md"; printf '# T3ASK\n\n## Results\n' > "$FT"
    FM="$WORK/$1/chief.fleet.json"
    if [ "$2" = ask ]; then
        printf '{"schema":1,"workers":[{"doc":"%s","label":"N1"},{"doc":"%s","label":"%s","lane":"t3","lockless":true,"t3_thread":"019e2c1a-1111","t3_kind":"ask","t3_notice":"sent"}]}\n' "$FW" "$FT" "$ASKL" > "$FM"
    else
        printf '{"schema":1,"workers":[{"doc":"%s","label":"N1"},{"doc":"%s","label":"%s","lane":"t3","lockless":true,"t3_thread":"019e2c1a-1111","t3_notice":"sent"}]}\n' "$FW" "$FT" "$ASKL" > "$FM"
    fi
    I="$(new_inbox "$1")"
    rm -f "$STUB/we.calls" "$STUB/rc.calls" "$STUB/disp.calls"
}
ask_run() {
    ask_fleet "$1" "$2"
    tick_line "N1:LIVE,$ASKL:LIVE"
    start "$I" "$WORK/$1.out" --doc "$FD" --workers-from "$FM"
    wait_hb "$I" || fail "($1) no baseline heartbeat"
    printf -- '%s\n' "$3" >> "$FT"
    tick_line "N1:LIVE,$ASKL:${4:-READY}" "$ASKL:${4:-READY}#1"
    wait_exit "$WPID"
}
for mode in off on; do
    flags "$mode"
    ask_run "ar-$mode" ask "- 09:10 READY 5999 $HA GREEN"
    check "(ask-ready $mode) a READY on an ask row prints WAKE t3-relay ask-ready" "0|WAKE t3-relay ask-ready $ASKL" "$rc|$(grep '^WAKE ' "$WORK/ar-$mode.out" | head -n 1)"
    check "(ask-ready $mode) no worker-ready line" "0" "$(grep -c '^WAKE worker-ready' "$WORK/ar-$mode.out")"
    check "(ask-ready $mode) no ready line" "0" "$(grep -c '^WAKE ready ' "$WORK/ar-$mode.out")"
    check "(ask-ready $mode) worker-event (and so auto-go) was not called" "" "$(cat "$STUB/we.calls" 2>/dev/null)"
    check "(ask-ready $mode) ready-check was not called" "" "$(cat "$STUB/rc.calls" 2>/dev/null)"
    check "(ask-ready $mode) cr-disposition was not called" "" "$(cat "$STUB/disp.calls" 2>/dev/null)"
    stop_waiter "$WPID"
    start "$I" "$WORK/ar-$mode-again.out" --doc "$FD" --workers-from "$FM"
    sleep 3
    check "(ask-ready $mode) once per bullet: a re-arm wakes nothing" "" "$(grep '^WAKE ' "$WORK/ar-$mode-again.out")"
    stop_waiter "$WPID"
    ask_run "as-$mode" ask '- 09:20 BLOCKED resolve 5999 PRRT_kwDOabc123' BLOCKED
    check "(ask-resolve $mode) a BLOCKED resolve on an ask row prints WAKE t3-relay ask-resolve" "0|WAKE t3-relay ask-resolve $ASKL" "$rc|$(grep '^WAKE ' "$WORK/as-$mode.out" | head -n 1)"
    check "(ask-resolve $mode) and no WAKE resolve" "0" "$(grep -c '^WAKE resolve' "$WORK/as-$mode.out")"
    stop_waiter "$WPID"
done
flags on
ask_run ctl-on none "- 09:10 READY 5999 $HA GREEN"
check "(control on) a READY on a plain t3 row reaches worker-event" "yes" "$(grep -q "READY 5999 $HA GREEN $ASKL" "$STUB/we.calls" 2>/dev/null && echo yes)"
stop_waiter "$WPID"
flags off
ask_run ctl-off none "- 09:10 READY 5999 $HA GREEN"
check "(control off) a READY on a plain t3 row wakes ready" "1" "$(grep -c '^WAKE ready 5999 ' "$WORK/ctl-off.out")"
check "(control off) and ran ready-check" "--observe 5999 $HA" "$(cat "$STUB/rc.calls" 2>/dev/null)"
stop_waiter "$WPID"
ask_run ask-q ask "- 09:30 LIVE QUESTION which file holds the rule?" LIVE
check "(ask-q) a LIVE QUESTION on an ask row still wakes worker-request" "1" "$(grep -cx "WAKE worker-request $ASKL" "$WORK/ask-q.out")"
stop_waiter "$WPID"

export HIMMEL_FLAGS_TSV="$WORK/flags.tsv"; flags on
mkdir -p "$WORK/home/.himmel" "$WORK/pa"
printf '{"t3":{"relay_instances":["claudeAgent_worker-impl"]}}\n' > "$WORK/home/.himmel/config.json"
PAD="$WORK/pa/chief.md"; printf '# chief\n\n## Results\n' > "$PAD"
PAM="$WORK/pa/chief.fleet.json"; printf '{"schema":1,"workers":[]}\n' > "$PAM"
PA_OUT="$(HOME="$WORK/home" bash "$ROOT/scripts/t3/relay-bind.sh" prepare --manifest "$PAM" --ticket PROJ-7 --label N40 --slug waiter-s3 --writes scripts/a.sh)"
PA_DOC="$(printf '%s\n' "$PA_OUT" | sed -n 's/^DOC //p')"
check "(pathA) prepare writes the doc named <KEY>-N<k>-t3-<slug>-<date>.md in the manifest's directory" "1" "$(printf '%s\n' "$PA_DOC" | grep -c "^$WORK/pa/PROJ-7-N40-t3-waiter-s3-20[0-9-]*\.md$")"
check "(pathA) the row is lane t3, lockless, t3_thread pending" "t3 true pending N40" "$(jq -r '.workers[0] | "\(.lane) \(.lockless) \(.t3_thread) \(.label)"' "$PAM")"
check "(pathA) the brief's command block holds no greater-than character" "0" "$(printf '%s\n' "$PA_OUT" | grep -c '>')"
HOME="$WORK/home" bash "$ROOT/scripts/t3/relay-bind.sh" attach --manifest "$PAM" --doc "$PA_DOC" --thread 019e2c1a-a001
check "(pathA) attach sets the threadId" "019e2c1a-a001" "$(jq -r '.workers[0].t3_thread' "$PAM")"
PA_HEAD=abababababababababababababababababababab
bash "$HERE/append-results.sh" "$PA_DOC" "LIVE — the thread started" > /dev/null
bash "$HERE/append-results.sh" "$PA_DOC" "READY 5999 $PA_HEAD GREEN" > /dev/null
check "(pathA) the doc's newest bullet is the READY" "1" "$(tail -n 1 "$PA_DOC" | grep -c "READY 5999 $PA_HEAD GREEN")"
relay_reset; : > "$STUB/relay.out"; echo 0 > "$STUB/relay.rc"
export CHIEF_WAIT_WORKER_EVENT="$STUB/we-handled.sh"
cat > "$STUB/we-handled.sh" <<'EOF'
#!/usr/bin/env bash
cat >> "$STUB/we.calls"
echo 'HANDLED auto-go GO written'; exit 0
EOF
rm -f "$STUB/we.calls"
tick_line "N40:READY" "N40:READY#1"
PAI="$(new_inbox pa)"
start "$PAI" "$WORK/pa-ready.out" --doc "$PAD" --workers-from "$PAM"
wait_exit "$WPID"
check "(pathA) a READY written by the thread wakes worker-ready with its PR and head" "0|WAKE worker-ready N40 pr=5999 head=$PA_HEAD" "$rc|$(grep '^WAKE ' "$WORK/pa-ready.out" | head -n 1)"
stop_waiter "$WPID"
bash "$HERE/append-results.sh" "$PA_DOC" "BLOCKED — CI is red" > /dev/null
tick_line "N40:BLOCKED" "N40:BLOCKED#1"
PAI="$(new_inbox pa2)"
start "$PAI" "$WORK/pa-blocked.out" --doc "$PAD" --workers-from "$PAM"
wait_exit "$WPID"
check "(pathA) a BLOCKED wakes worker-blocked" "0|WAKE worker-blocked N40" "$rc|$(grep '^WAKE ' "$WORK/pa-blocked.out" | head -n 1)"
stop_waiter "$WPID"
bash "$HERE/append-results.sh" "$PA_DOC" "FINDING — a question about scope" > /dev/null
tick_line "N40:FINDING" "N40:FINDING#1"
PAI="$(new_inbox pa3)"
start "$PAI" "$WORK/pa-finding.out" --doc "$PAD" --workers-from "$PAM"
wait_exit "$WPID"
check "(pathA) a FINDING wakes worker-finding" "0|WAKE worker-finding N40" "$rc|$(grep '^WAKE ' "$WORK/pa-finding.out" | head -n 1)"
stop_waiter "$WPID"
unset CHIEF_WAIT_WORKER_EVENT

mkdir -p "$WORK/ag/handovers"
AGC="$WORK/ag/chief.md"; printf '# chief\n\n## Live state\n\nqueue: none\n\n## Results\n' > "$AGC"
AGF="$WORK/ag/chief.fleet.json"
printf '{"schema":1,"workers":[{"doc":"%s","label":"N40","lane":"t3","lockless":true,"t3_thread":"019e2c1a-a001"}]}\n' "$PA_DOC" > "$AGF"
AG_OUT="$(env -u HIMMEL_CONSOLE_LEG -u HIMMEL_CONSOLE_RELAY -u CHIEF_SESSION_NAME HANDOVER_DIR="$WORK/ag/handovers" bash "$HERE/auto-go.sh" --doc "$AGC" --fleet "$AGF" --worker N40 --dry-run 5999 "$PA_HEAD" 2>&1)"; AG_RC=$?
check "(auto-go) a lane t3 READY is escalated (rc 10): the chief merges for it" "10|1" "$AG_RC|$(printf '%s\n' "$AG_OUT" | grep -c '^ESCALATE auto-go 1 worker N40 is lane t3, not native')"
check "(auto-go) and no GO file is written" "0" "$(find "$WORK/ag" -name 'GO*' -type f 2>/dev/null | wc -l | tr -d '[:space:]')"

flags off
relay_reset; : > "$STUB/relay.out"; echo 0 > "$STUB/relay.rc"
ask_fleet pb ask
tick_line "N1:LIVE,$ASKL:?"
HOUSEKEEPING_DIGEST_SECS=0 start "$I" "$WORK/pb1.out" --doc "$FD" --workers-from "$FM"
wait_hb "$I" || fail "(pathB) no baseline heartbeat"
printf -- '- 09:30 LIVE QUESTION which file holds the rule?\n' >> "$FT"
tick_line "N1:LIVE,$ASKL:LIVE" "$ASKL:LIVE#1"
wait_exit "$WPID"
check "(pathB first) the first wake is the tick change, with tails in its field list" "0|1" "$rc|$(grep -c '^WAKE tick changed=.*tails' "$WORK/pb1.out")"
check "(pathB first) the exit carries WAKE worker-request, after the tick change" "WAKE tick|WAKE worker-request" "$(grep '^WAKE ' "$WORK/pb1.out" | awk '{ print $1 " " $2 }' | paste -sd'|' -)"
check "(pathB first) and no other WAKE worker- line" "0" "$(grep '^WAKE worker-' "$WORK/pb1.out" | grep -vc "^WAKE worker-request $ASKL\$")"
stop_waiter "$WPID"
printf -- '- 09:40 LIVE QUESTION and a second one?\n' >> "$FT"
start "$I" "$WORK/pb2.out" --doc "$FD" --workers-from "$FM"
wait_exit "$WPID"
check "(pathB second) the next run, token saved, prints exactly WAKE worker-request" "0|WAKE worker-request $ASKL" "$rc|$(grep '^WAKE ' "$WORK/pb2.out")"
stop_waiter "$WPID"

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
