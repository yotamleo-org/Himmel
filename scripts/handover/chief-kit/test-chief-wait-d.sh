#!/usr/bin/env bash
# test-chief-wait-d.sh — Exercises chief-wait.sh, the chief's
# one event waiter: silent while nothing changes, exits with exactly one WAKE
# block on a Telegram inbox line or a confirmed change of the tick's action
# key. tick.sh and the bank verdict are stubbed (CHIEF_WAIT_TICK /
# CHIEF_WAIT_USAGE), so no gh, lock or bank read happens here. bash 3.2-safe.
#
# CHIEF_WAIT overrides the script under test (the RED
# control: today's Monitor-arm shape, which runs tick.sh on every arm, fails the
# idle cases).
#
# Run: bash scripts/handover/chief-kit/test-chief-wait-d.sh
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

tracker_line() { sed "s/ denials=none/ tracker=$1 denials=none/" "$STUB/tick.line" > "$STUB/tick.line.tmp" && mv "$STUB/tick.line.tmp" "$STUB/tick.line"; }
reset_stub
tracker_line ok
I="$(new_inbox w)"
start "$I" "$WORK/w.out" --workers "N1.md"
wait_hb "$I" || fail "(w) no baseline heartbeat"
tick_line "N1:FRESH" "ok"
tracker_line STALE:3h
wait_exit "$WPID"
check "(w) a tracker move to STALE ends the wait" "0" "$rc"
check "(w) the wake names tracker" "WAKE tick changed=tracker usage=PROCEED" "$(head -n1 "$WORK/w.out")"

reset_stub
tick_line "N1:FRESH" "ok"
tracker_line STALE:3h
I="$(new_inbox w2)"
start "$I" "$WORK/w2.out" --workers "N1.md"
wait_hb "$I" || fail "(w2) no baseline heartbeat"
tick_line "N1:FRESH" "ok"
tracker_line ok
wait_exit "$WPID"
check "(w2) a tracker move to ok alone does not wake" "running" "$rc"
check "(w2) the saved key still moved to tracker=ok" "yes" "$(grep -q 'tracker=ok' "$I.wait.state" && echo yes)"
stop_waiter "$WPID"

reset_stub
I="$(new_inbox w3)"
start "$I" "$WORK/w3.out" --workers "N1.md"
wait_hb "$I" || fail "(w3) no baseline heartbeat"
wait_exit "$WPID"
check "(w3) a tick line with no tracker= field is still a valid sample" "running" "$rc"
stop_waiter "$WPID"

orph_line() { sed "s/ denials=none/ orphans-wip=$1 denials=none/" "$STUB/tick.line" > "$STUB/tick.line.tmp" && mv "$STUB/tick.line.tmp" "$STUB/tick.line"; }
reset_stub
orph_line 0
I="$(new_inbox w4)"
start "$I" "$WORK/w4.out" --workers "N1.md"
wait_hb "$I" || fail "(w4) no baseline heartbeat"
tick_line "N1:FRESH" "ok"
orph_line 1:HIMMEL-9
wait_exit "$WPID"
check "(w4) an orphans-wip change ends the wait" "0" "$rc"
check "(w4) the wake names orphans-wip" "WAKE tick changed=orphans-wip usage=PROCEED" "$(head -n1 "$WORK/w4.out")"

vault_line() { sed "s/ denials=none/ vault=$1 denials=none/" "$STUB/tick.line" > "$STUB/tick.line.tmp" && mv "$STUB/tick.line.tmp" "$STUB/tick.line"; }
reset_stub
vault_line ok
I="$(new_inbox x)"
start "$I" "$WORK/x.out" --workers "N1.md"
wait_hb "$I" || fail "(x) no baseline heartbeat"
tick_line "N1:FRESH" "ok"
vault_line STALL:25m,3
wait_exit "$WPID"
check "(x) a vault move to STALL ends the wait" "0" "$rc"
check "(x) the wake names vault" "WAKE tick changed=vault usage=PROCEED" "$(head -n1 "$WORK/x.out")"
check "(x) the wake names the reproduce command" "yes" "$(grep -q 'git -C .* hook run pre-commit' "$WORK/x.out" && echo yes)"

reset_stub
tick_line "N1:FRESH" "ok"
vault_line STALL:25m,3
I="$(new_inbox x2)"
start "$I" "$WORK/x2.out" --workers "N1.md"
wait_hb "$I" || fail "(x2) no baseline heartbeat"
tick_line "N1:FRESH" "ok"
vault_line STALL:2h,90
wait_exit "$WPID"
check "(x2) a STALL age/count change alone does not wake" "running" "$rc"
tick_line "N1:FRESH" "ok"
vault_line ok
wait_exit "$WPID"
check "(x2) a vault move back to ok alone does not wake" "running" "$rc"
check "(x2) the saved key still moved to vault=ok" "yes" "$(grep -q 'vault=ok' "$I.wait.state" && echo yes)"
stop_waiter "$WPID"

reset_stub
vault_line ok
I="$(new_inbox x3)"
start "$I" "$WORK/x3.out" --workers "N1.md"
wait_hb "$I" || fail "(x3) no baseline heartbeat"
tick_line "N1:FRESH" "ok"
vault_line PUSH-LAG:3h
wait_exit "$WPID"
check "(x3) a vault move to PUSH-LAG wakes" "WAKE tick changed=vault usage=PROCEED" "$(head -n1 "$WORK/x3.out")"

reset_stub
vault_line ok
I="$(new_inbox x4)"
start "$I" "$WORK/x4.out" --workers "N1.md"
wait_hb "$I" || fail "(x4) no baseline heartbeat"
tick_line "N1:FRESH" "ok"
vault_line unknown
wait_exit "$WPID"
check "(x4) a vault move to unknown does not wake" "running" "$rc"
stop_waiter "$WPID"

reset_stub
I="$(new_inbox x5)"
start "$I" "$WORK/x5.out" --workers "N1.md"
wait_hb "$I" || fail "(x5) no baseline heartbeat"
wait_exit "$WPID"
check "(x5) a tick line with no vault= field is still a valid sample" "running" "$rc"
stop_waiter "$WPID"

cloud_line() { sed "s#  *denials=none# cloud=$1 denials=none#" "$STUB/tick.line" > "$STUB/tick.line.tmp" && mv "$STUB/tick.line.tmp" "$STUB/tick.line"; }
reset_stub
cloud_line ok
I="$(new_inbox y)"
start "$I" "$WORK/y.out" --workers "N1.md"
wait_hb "$I" || fail "(y) no baseline heartbeat"
tick_line "N1:FRESH" "ok"
cloud_line STALL:HIMMEL-5077,HIMMEL-4655,HIMMEL-4686
wait_exit "$WPID"
check "(y) a cloud move to STALL ends the wait" "0" "$rc"
check "(y) the wake names cloud" "WAKE tick changed=cloud usage=PROCEED" "$(head -n1 "$WORK/y.out")"

reset_stub
tick_line "N1:FRESH" "ok"
cloud_line STALL:HIMMEL-5077,HIMMEL-4655,HIMMEL-4686
I="$(new_inbox y2)"
start "$I" "$WORK/y2.out" --workers "N1.md"
wait_hb "$I" || fail "(y2) no baseline heartbeat"
tick_line "N1:FRESH" "ok"
cloud_line STALL:HIMMEL-4686
wait_exit "$WPID"
check "(y2) a STALL ticket-list change alone does not wake" "running" "$rc"
tick_line "N1:FRESH" "ok"
cloud_line ok
wait_exit "$WPID"
check "(y2) a cloud move back to ok alone does not wake" "running" "$rc"
check "(y2) the saved key still moved to cloud=ok" "yes" "$(grep -q 'cloud=ok' "$I.wait.state" && echo yes)"
stop_waiter "$WPID"

reset_stub
cloud_line ok
I="$(new_inbox y3)"
start "$I" "$WORK/y3.out" --workers "N1.md"
wait_hb "$I" || fail "(y3) no baseline heartbeat"
tick_line "N1:FRESH" "ok"
cloud_line skip
wait_exit "$WPID"
check "(y3) a cloud move to skip does not wake" "running" "$rc"
stop_waiter "$WPID"

reset_stub
I="$(new_inbox y4)"
start "$I" "$WORK/y4.out" --workers "N1.md"
wait_hb "$I" || fail "(y4) no baseline heartbeat"
wait_exit "$WPID"
check "(y4) a tick line with no cloud= field is still a valid sample" "running" "$rc"
stop_waiter "$WPID"

reset_stub
mkdir -p "$WORK/sec/.himmel" "$WORK/sec/consoles"
printf 'SECRET-HMAC-KEY\n' > "$WORK/sec/.himmel/go-hmac.key"
timeout -k 5 5 bash "$WAIT" "$WORK/sec/.himmel/go-hmac.key" --workers "N1.md" > "$WORK/sec.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit
check "(sec) a secret-shaped inbox path is refused" "2" "$rc"
check "(sec) the refused secret is never printed" "0" "$(grep -c SECRET "$WORK/sec.out")"
ln -s "$WORK/sec/.himmel/go-hmac.key" "$WORK/sec/consoles/c.md"
timeout -k 5 5 bash "$WAIT" "$WORK/sec/consoles/c.md" --workers "N1.md" > "$WORK/sec-ln.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit
check "(sec) a consoles/ symlink onto a secret is refused" "2" "$rc"
check "(sec) the symlinked secret is never printed" "0" "$(grep -c SECRET "$WORK/sec-ln.out")"
I="$(new_inbox sec-swap)"
start "$I" "$WORK/sec-swap.out" --workers "N1.md"
wait_hb "$I" || fail "(sec) no baseline heartbeat"
rm -f "$I"; ln -s "$WORK/sec/.himmel/go-hmac.key" "$I"
wait_exit "$WPID"
check "(sec) an inbox swapped for a secret link mid-wait ends the wait" "1" "$rc"
check "(sec) the swapped-in secret is never printed" "0" "$(grep -c SECRET "$WORK/sec-swap.out")"
stop_waiter "$WPID"

cat > "$STUB/ready-check.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB/rc.calls"
printf '%s\n' "$PWD" >> "$STUB/rc.cwd"
cat "$STUB/rc.out"; exit "$(cat "$STUB/rc.rc")"
EOF
cat > "$STUB/ci.sh" <<'EOF'
#!/usr/bin/env bash
cat "$STUB/ci.out"
EOF
cat > "$STUB/disposition.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB/disp.calls"
printf '%s\n' "$PWD" >> "$STUB/disp.cwd"
cat "$STUB/disp.out"; exit "$(cat "$STUB/disp.rc")"
EOF
cat > "$STUB/worker-event.sh" <<'EOF'
#!/usr/bin/env bash
cat >> "$STUB/we.calls"
echo 'ESCALATE marker-READY'; exit 10
EOF
export CHIEF_WAIT_READY_CHECK="$STUB/ready-check.sh" CHIEF_WAIT_CI="$STUB/ci.sh" CHIEF_WAIT_DISPOSITION="$STUB/disposition.sh"
export CHIEF_WAIT_WORKER_EVENT="$STUB/worker-event.sh"
rm -f "$STUB/we.calls"
REAL_TIMEOUT="$(command -v timeout)"; export REAL_TIMEOUT  # gnu-ok: Linux-only kit
mkdir -p "$STUB/bin"
cat > "$STUB/bin/timeout" <<'EOF'
#!/usr/bin/env bash
case " $* " in *ready-check.sh*) printf '%s\n' "$3" >> "$STUB/timeout-bounds" ;; esac
exec "$REAL_TIMEOUT" "$@"
EOF
chmod +x "$STUB/bin/timeout"
rm -f "$STUB/timeout-bounds"
SAVED_PATH="$PATH"; export PATH="$STUB/bin:$PATH"
printf 'auto_go\toff\tfeature\tHIMMEL-8349\tHIMMEL-8404\t2099-01-01\tfixture\n' > "$WORK/flags.tsv"
export HIMMEL_FLAGS_TSV="$WORK/flags.tsv" HIMMEL_CONFIG_DIR="$WORK/no-conf"
unset HIMMEL_FLAG_AUTO_GO
HA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; HB=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
ready_stubs_pass() {
    rm -f "$STUB/rc.calls" "$STUB/disp.calls"
    printf '[PASS] 1. head\n[PASS] 7. ticket coverage: every ask is done\nnote MH-N1-0123abcd seen\nTRUST-PATH: no\nREADY-CHECK PASS\n' > "$STUB/rc.out"; echo 0 > "$STUB/rc.rc"
    printf 'GREEN\n' > "$STUB/ci.out"
    printf 'DISPOSITION PASS (0 deferred Critical/Important finding(s) on b dispositioned)\n' > "$STUB/disp.out"; echo 0 > "$STUB/disp.rc"
}
ready_tick() {
    tick_line "N1:FRESH" "ok"
    sed -i "s/ tails=N1:LIVE/ tails=$1${2:+ acts=$2}/" "$STUB/tick.line"  # gnu-ok: Linux-only kit
}
reset_stub
ready_stubs_pass
mkdir -p "$WORK/rdy/consoles"; I="$WORK/rdy/consoles/c.md"; : > "$I"
RD="$WORK/rdy/chief.md"; printf '# chief\n' > "$RD"
RL="$WORK/rdy/HIMMEL-1-N1-a.md"; printf '# worker\n\n## Results\n- 09:00 LIVE — started\n' > "$RL"
RM="$WORK/rdy/chief.fleet.json"; printf '{"schema":1,"workers":[{"doc":"%s","label":"N1"}]}\n' "$RL" > "$RM"
ready_tick "N1:LIVE"
start "$I" "$WORK/rdy.out" --doc "$RD" --workers-from "$RM"
wait_hb "$I" || fail "(rdy) no baseline heartbeat"
printf -- '- 10:00 READY 2566 %s GREEN\n' "$HA" >> "$RL"
ready_tick "N1:READY" "N1:READY#1"
wait_exit "$WPID"
check "(rdy) a READY bullet ends the wait" "0" "$rc"
check "(rdy) one pre-checked WAKE ready" "WAKE ready 2566 $HA ready-check=PASS ci=GREEN coverage=PASS disposition=ok out=$I.wait.ready-2566" "$(head -n 1 "$WORK/rdy.out")"
check "(rdy) exactly one WAKE line" "1" "$(grep -c '^WAKE ' "$WORK/rdy.out")"
check "(rdy) the READY reached worker-event once, for its dry run" "N1 READY 2566 $HA GREEN" "$(cat "$STUB/we.calls" 2>/dev/null)"
check "(rdy) ready-check ran once on the PR and head, as a warn-only read (--observe: no GO is written)" "--observe 2566 $HA" "$(cat "$STUB/rc.calls" 2>/dev/null)"
check "(rdy) ready-check runs under a bound past item 19's 105 s" "above" "$(awk '{ print ($1 > 105) ? "above" : "at-or-below" }' "$STUB/timeout-bounds" 2>/dev/null | head -n 1)"
check "(rdy) cr-disposition check ran read-only with the computed trust path" "check 2566 $HA --trust-path no" "$(cat "$STUB/disp.calls" 2>/dev/null)"
check "(rdy) the out file keeps the ready-check output" "yes" "$(grep -q 'READY-CHECK PASS' "$I.wait.ready-2566" 2>/dev/null && echo yes)"
check "(rdy) no token in the payload or the out file" "0" "$(cat "$WORK/rdy.out" "$I.wait.ready-2566" 2>/dev/null | grep -c 'MH-N1-0123abcd')"
ready_stubs_pass
printf -- '- 10:05 READY 2566 %s GREEN\n' "$HA" >> "$RL"
ready_tick "N1:READY" "N1:READY#2"
start "$I" "$WORK/rdy-same.out" --doc "$RD" --workers-from "$RM"
wait_hb "$I" || fail "(rdy) no re-arm heartbeat"
sleep 3
check "(rdy) the same (PR, head) twice is one wake" "" "$(cat "$WORK/rdy-same.out")"
check "(rdy) and is not re-checked" "" "$(cat "$STUB/rc.calls" 2>/dev/null)"
printf '[FAIL] 7. ticket coverage: no section\nTRUST-PATH: yes\nREADY-CHECK FAIL\n' > "$STUB/rc.out"; echo 1 > "$STUB/rc.rc"
printf 'RED\n' > "$STUB/ci.out"
printf '[OPEN] crit f1@x: deferred\n[OPEN] imp f2@x: deferred\nDISPOSITION FAIL (2 of 2 open Critical/Important finding(s) on b)\n' > "$STUB/disp.out"; echo 1 > "$STUB/disp.rc"
printf -- '- 10:20 READY 2566 %s GREEN\n' "$HB" >> "$RL"
ready_tick "N1:READY" "N1:READY#3"
wait_exit "$WPID"
check "(rdy) a new head wakes again" "0" "$rc"
check "(rdy) with each failed verdict" "WAKE ready 2566 $HB ready-check=FAIL ci=RED coverage=FAIL disposition=open:2 out=$I.wait.ready-2566" "$(head -n 1 "$WORK/rdy-same.out")"
check "(rdy) the trust path reaches cr-disposition" "check 2566 $HB --trust-path yes" "$(cat "$STUB/disp.calls" 2>/dev/null)"
ready_stubs_pass
HC=cccccccccccccccccccccccccccccccccccccccc
printf -- '- 10:30 READY 2566 %s\n' "$HC" >> "$RL"
ready_tick "N1:READY" "N1:READY#4"
start "$I" "$WORK/rdy-nog.out" --doc "$RD" --workers-from "$RM"
wait_exit "$WPID"
check "(rdy) a READY without GREEN is no ready wake" "" "$(grep '^WAKE ready' "$WORK/rdy-nog.out")"
check "(rdy) and runs no check" "" "$(cat "$STUB/rc.calls" 2>/dev/null)"
ready_stubs_pass
mkdir -p "$WORK/rdytxt/consoles"; I2="$WORK/rdytxt/consoles/c.md"; : > "$I2"
RD2="$WORK/rdytxt/chief.md"; printf '# chief\n' > "$RD2"
RL2="$WORK/rdytxt/HIMMEL-1-N1-a.md"; printf '# worker\n\n## Results\n- 09:00 LIVE — started\n' > "$RL2"
RM2="$WORK/rdytxt/chief.fleet.json"; printf '{"schema":1,"workers":[{"doc":"%s","label":"N1"}]}\n' "$RL2" > "$RM2"
ready_tick "N1:LIVE"
start "$I2" "$WORK/rdytxt.out" --doc "$RD2" --workers-from "$RM2"
wait_hb "$I2" || fail "(rdy-txt) no baseline heartbeat"
# shellcheck disable=SC2016  # the backticks are literal bullet text
printf -- '- 10:00 READY 2577 %s GREEN — trust path: no; rows `suite-tiers.tsv` added\n' "$HA" >> "$RL2"
ready_tick "N1:READY" "N1:READY#1"
wait_exit "$WPID"
# shellcheck disable=SC2016  # the backticks are literal bullet text
check "(rdy-txt) the out file carries the READY bullet" "1" "$(grep -cF -- 'rows `suite-tiers.tsv` added' "$I2.wait.ready-2577" 2>/dev/null)"
check "(rdy-txt) waiter.md names the bullet in the out file" "1" "$(grep -c 'holds the READY bullet' "$HERE/../../../docs/handover/chief-sections/waiter.md")"
stop_waiter "$WPID"
ready_stubs_pass
rm -f "$STUB/rc.cwd" "$STUB/disp.cwd" "$STUB/gh.calls"
GATED="$WORK/gated"; DECOY="$WORK/decoy"
if ! { git init -q "$GATED" && git -C "$GATED" remote add origin https://github.com/o/x.git; }; then
    echo "FAIL: (rdy-cwd) gated fixture setup" >&2; exit 1
fi
if ! { git init -q "$DECOY" && git -C "$DECOY" remote add origin https://github.com/other/luna.git; }; then
    echo "FAIL: (rdy-cwd) decoy fixture setup" >&2; exit 1
fi
mkdir -p "$STUB/ghbin"
cat > "$STUB/ghbin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s\n' "$PWD" "$*" >> "$STUB/gh.calls"
printf 'pass\n'
EOF
chmod +x "$STUB/ghbin/gh"
mkdir -p "$WORK/rdycwd/consoles"; I3="$WORK/rdycwd/consoles/c.md"; : > "$I3"
RD3="$WORK/rdycwd/chief.md"; printf '# chief\n' > "$RD3"
RL3="$WORK/rdycwd/HIMMEL-1-N1-a.md"; printf '# worker\n\n## Results\n- 09:00 LIVE — started\n' > "$RL3"
RM3="$WORK/rdycwd/chief.fleet.json"; printf '{"schema":1,"workers":[{"doc":"%s","label":"N1"}]}\n' "$RL3" > "$RM3"
ready_tick "N1:LIVE"
unset CHIEF_WAIT_CI
cd "$DECOY" || fail "(rdy-cwd) cd decoy"
HIMMEL_REPO="$GATED" PATH="$STUB/ghbin:$PATH" start "$I3" "$WORK/rdycwd.out" --doc "$RD3" --workers-from "$RM3"
cd "$HERE" || fail "(rdy-cwd) cd back"
wait_hb "$I3" || fail "(rdy-cwd) no baseline heartbeat"
printf -- '- 10:00 READY 2588 %s GREEN\n' "$HA" >> "$RL3"
ready_tick "N1:READY" "N1:READY#1"
wait_exit "$WPID"
check "(rdy-cwd) the READY wakes with CI read GREEN" "WAKE ready 2588 $HA ready-check=PASS ci=GREEN coverage=PASS disposition=ok out=$I3.wait.ready-2588" "$(head -n 1 "$WORK/rdycwd.out")"
check "(rdy-cwd) ready-check ran in HIMMEL_REPO" "$GATED" "$(cat "$STUB/rc.cwd" 2>/dev/null)"
check "(rdy-cwd) cr-disposition ran in HIMMEL_REPO" "$GATED" "$(cat "$STUB/disp.cwd" 2>/dev/null)"
check "(rdy-cwd) the CI read names HIMMEL_REPO's repo, from HIMMEL_REPO" "1" "$(grep -c "^$GATED|pr checks 2588 -R o/x " "$STUB/gh.calls" 2>/dev/null)"
export CHIEF_WAIT_CI="$STUB/ci.sh"
stop_waiter "$WPID"
unset CHIEF_WAIT_READY_CHECK CHIEF_WAIT_CI CHIEF_WAIT_DISPOSITION CHIEF_WAIT_WORKER_EVENT
export PATH="$SAVED_PATH"

cat > "$STUB/we-handled.sh" <<'EOF'
#!/usr/bin/env bash
cat >> "$STUB/we.calls"
echo 'HANDLED auto-go GO written'; exit 0
EOF
export CHIEF_WAIT_WORKER_EVENT="$STUB/we-handled.sh"
printf 'auto_go\ton\tfeature\tHIMMEL-8349\tHIMMEL-8404\t2099-01-01\tfixture\n' > "$WORK/flags-on.tsv"
export HIMMEL_FLAGS_TSV="$WORK/flags-on.tsv"
WH1=e986d98126ac4084da609e1a72c7d246b162e2f7; WH2=63f07d5c872225fe0ed7d1442a68ae6745c8261e
WL1=HIMMEL-10357-F10357a-operator-items-2026-11-21; WL2=HIMMEL-10348-F10348a-owed-message-once-2026-11-21
WL3=HIMMEL-10575-F10575a-waiter-since-flag-2026-11-21-RESUME
wr_fleet() {
    mkdir -p "$WORK/$1"
    WD="$WORK/$1/chief.md"; printf '# chief\n\n## Results\n' > "$WD"
    WD1="$WORK/$1/$WL1.md"; printf '# worker\n\n## Results\n- 21:05 LIVE — PR 5666 open\n- 21:26 READY 5666 %s GREEN\n' "$WH1" > "$WD1"
    WD2="$WORK/$1/$WL2.md"; printf '# worker\n\n## Results\n- 21:40 LIVE — PR 5669 open\n- 21:58 READY 5669 %s GREEN — CI green\n' "$WH2" > "$WD2"
    WD3="$WORK/$1/$WL3.md"; printf '# worker\n\n## Results\n- 21:50 LIVE — started\n' > "$WD3"
    WM="$WORK/$1/chief.fleet.json"
    printf '{"schema":1,"workers":[{"doc":"%s","label":"%s"},{"doc":"%s","label":"%s"},{"doc":"%s","label":"%s"}]}\n' \
        "$WD3" "$WL3" "$WD1" "$WL1" "$WD2" "$WL2" > "$WM"
}
wr_tick() {
    tick_line "N1:FRESH" "ok"
    sed -i "s/ tails=N1:LIVE/ tails=$1 acts=$2/" "$STUB/tick.line"  # gnu-ok: Linux-only kit
    [ -z "${3:-}" ] || sed -i "s| or=| ready-mismatch=$3 or=|" "$STUB/tick.line"  # gnu-ok: Linux-only kit
}
wr_stop() { stop_waiter "$WPID"; }
reset_stub
rm -f "$STUB/we.calls"
wr_fleet wr
I="$(new_inbox wr)"
wr_tick "$WL3:LIVE,$WL1:READY,$WL2:READY" "$WL1:READY#2,$WL2:READY#1" "2/27,nogo=0/27,ALERT,partial"
start "$I" "$WORK/wr1.out" --doc "$WD" --workers-from "$WM"
wait_exit "$WPID"
check "(wr1) the 22:04 tick replay wakes the chief" "0" "$rc"
check "(wr1) one WAKE worker-ready per READY head" "WAKE worker-ready $WL1 pr=5666 head=$WH1|WAKE worker-ready $WL2 pr=5669 head=$WH2" "$(grep '^WAKE ' "$WORK/wr1.out" | paste -sd'|' -)"
check "(wr1) the tick line follows" "1" "$(grep -c '^TICK ' "$WORK/wr1.out")"
check "(wr1) the payload carries no bullet text" "0" "$(grep -c 'CI green' "$WORK/wr1.out")"
wr_stop
start "$I" "$WORK/wr2.out" --doc "$WD" --workers-from "$WM"
wait_exit "$WPID"
check "(wr2) a ready-mismatch ALERT wakes the chief" "WAKE ready-mismatch 2/27,nogo=0/27,ALERT,partial" "$(head -n 1 "$WORK/wr2.out")"
wr_stop
start "$I" "$WORK/wr3.out" --doc "$WD" --workers-from "$WM"
wait_exit "$WPID"
check "(wr3) a re-arm on the same heads and the same ALERT wakes nothing" "running|" "$rc|$(cat "$WORK/wr3.out")"
wr_tick "$WL3:LIVE,$WL1:READY,$WL2:READY" "$WL1:READY#2,$WL2:READY#1" "3/28,nogo=0/28,ALERT"
wait_exit "$WPID"
check "(wr4) a rise of the flagged count under ALERT wakes again" "WAKE ready-mismatch 3/28,nogo=0/28,ALERT" "$(head -n 1 "$WORK/wr3.out")"
wr_tick "$WL3:LIVE,$WL1:READY,$WL2:READY" "$WL1:READY#2,$WL2:READY#1"
wr_stop
I2="$(new_inbox wr-succ)"
start "$I2" "$WORK/wr5.out" --doc "$WD" --workers-from "$WM"
wait_exit "$WPID"
check "(wr5) a READY written before the succession wakes the successor once per head" "WAKE worker-ready $WL1 pr=5666 head=$WH1|WAKE worker-ready $WL2 pr=5669 head=$WH2" "$(grep '^WAKE ' "$WORK/wr5.out" | paste -sd'|' -)"
wr_stop
start "$I2" "$WORK/wr6.out" --doc "$WD" --workers-from "$WM"
wait_hb "$I2" || fail "(wr6) no re-arm heartbeat"
printf -- '- 22:54 READY 5666 %s GREEN\n' "$WH1" >> "$WD1"
wr_tick "$WL3:LIVE,$WL1:READY,$WL2:READY" "$WL1:READY#3,$WL2:READY#1"
wait_exit "$WPID"
check "(wr6) a repeat READY of a woken head wakes nothing" "running|" "$rc|$(grep '^WAKE ' "$WORK/wr6.out")"
check "(wr6) and is still handed to worker-event once" "$(printf 'READY 5666 %s GREEN %s' "$WH1" "$WL1")" "$(cat "$STUB/we.calls" 2>/dev/null)"
stop_waiter "$WPID"
mkdir -p "$WORK/wrb"
WD="$WORK/wrb/chief.md"; printf '# chief\n\n## Results\n' > "$WD"
WB="$WORK/wrb/HIMMEL-10570-F10570a-cr-learnings-2026-11-21.md"
printf '# worker\n\n## Results\n- 19:00 LIVE — started\n- 19:30 BLOCKED — PR 5656 CI red\n' > "$WB"
WM="$WORK/wrb/chief.fleet.json"; printf '{"schema":1,"workers":[{"doc":"%s","label":"N7"}]}\n' "$WB" > "$WM"
wr_tick "N7:BLOCKED" "N7:BLOCKED#1"
wr_stop
I="$(new_inbox wrb)"
start "$I" "$WORK/wr7.out" --doc "$WD" --workers-from "$WM"
wait_exit "$WPID"
check "(wr7) a BLOCKED present at the baseline wakes the chief" "0|WAKE worker-blocked N7" "$rc|$(grep '^WAKE ' "$WORK/wr7.out")"
wr_stop
start "$I" "$WORK/wr8.out" --doc "$WD" --workers-from "$WM"
wait_exit "$WPID"
check "(wr8) and only once" "running|" "$rc|$(cat "$WORK/wr8.out")"
wr_tick "N7:FINDING" "N7:FINDING#1"; mv "$STUB/tick.line" "$STUB/tick.next"; wr_tick "N7:BLOCKED" "N7:BLOCKED#1"
printf -- '- 20:00 RESOLVED — ruling received\n- 20:10 FINDING — a question\n' > "$STUB/tick.add"
printf 'cat "%s" >> "%s"\nmv "%s" "%s"\n' "$STUB/tick.add" "$WB" "$STUB/tick.next" "$STUB/tick.line" > "$STUB/tick.hook.new"
mv "$STUB/tick.hook.new" "$STUB/tick.hook"
wait_exit "$WPID"
check "(wr9) a new FINDING wakes as a tick change" "WAKE tick changed=tails,acts usage=PROCEED" "$(head -n 1 "$WORK/wr8.out")"
wr_stop
start "$I" "$WORK/wr10.out" --doc "$WD" --workers-from "$WM"
wait_exit "$WPID"
check "(wr10) and a re-arm does not wake for it again" "running|" "$rc|$(cat "$WORK/wr10.out")"
stop_waiter "$WPID"
cat > "$STUB/we-refuse.sh" <<'EOF'
#!/usr/bin/env bash
cat >> "$STUB/we.calls"
echo 'auto-go: step lock-failed rc=3 held'; exit 10
EOF
export CHIEF_WAIT_WORKER_EVENT="$STUB/we-refuse.sh"
WH3=dddddddddddddddddddddddddddddddddddddddd
mkdir -p "$WORK/wrr"
WD="$WORK/wrr/chief.md"; printf '# chief\n\n## Results\n' > "$WD"
WR="$WORK/wrr/HIMMEL-8-N8-a.md"; printf '# worker\n\n## Results\n- 09:00 LIVE — started\n' > "$WR"
WM="$WORK/wrr/chief.fleet.json"; printf '{"schema":1,"workers":[{"doc":"%s","label":"N8"}]}\n' "$WR" > "$WM"
wr_tick "N8:LIVE" "N8:LIVE#1"
I="$(new_inbox wrr)"
start "$I" "$WORK/wr11.out" --doc "$WD" --workers-from "$WM"
wait_hb "$I" || fail "(wr11) no baseline heartbeat"
wr_tick "N8:FINDING" "N8:FINDING#1"; mv "$STUB/tick.line" "$STUB/tick.next"; wr_tick "N8:LIVE" "N8:LIVE#1"
printf -- '- 09:10 FINDING — a question\n' >> "$WR"
printf 'printf -- "- 09:11 READY 2599 %s GREEN\\n" >> "%s"\nmv "%s" "%s"\n' "$WH3" "$WR" "$STUB/tick.next" "$STUB/tick.line" > "$STUB/tick.hook.new"
mv "$STUB/tick.hook.new" "$STUB/tick.hook"
wait_exit "$WPID"
check "(wr11) the FINDING wakes as a tick change" "WAKE tick changed=tails,acts usage=PROCEED" "$(head -n 1 "$WORK/wr11.out")"
wr_tick "N8:READY" "N8:READY#1"
start "$I" "$WORK/wr12.out" --doc "$WD" --workers-from "$WM"
wait_exit "$WPID"
check "(wr12) a READY written while that tick ran is not taken as named: its tails move still wakes" "WAKE tick changed=tails,acts usage=PROCEED" "$(head -n 1 "$WORK/wr12.out")"
wr_stop
export CHIEF_WAIT_WORKER_EVENT="$STUB/we-handled.sh"
wr_ready_fleet() {
    mkdir -p "$WORK/$1"
    WD="$WORK/$1/chief.md"; printf '# chief\n\n## Results\n' > "$WD"
    WR="$WORK/$1/HIMMEL-9-$2-a.md"; printf '# worker\n\n## Results\n- 09:00 LIVE — started\n' > "$WR"
    WM="$WORK/$1/chief.fleet.json"; printf '{"schema":1,"workers":[{"doc":"%s","label":"%s"}]}\n' "$WR" "$2" > "$WM"
    wr_tick "$2:LIVE" "$2:LIVE#1"
    I="$(new_inbox "$1")"
    rm -f "$STUB/we.calls"
}
wr_ready_hook() {
    wr_tick "$1:READY" "$1:READY#1"; mv "$STUB/tick.line" "$STUB/tick.next"; wr_tick "$1:LIVE" "$1:LIVE#1"
    printf '%s' "$2" > "$STUB/tick.add"
    printf 'cat "%s" >> "%s"\nmv "%s" "%s"\n' "$STUB/tick.add" "$WR" "$STUB/tick.next" "$STUB/tick.line" > "$STUB/tick.hook.new"
    mv "$STUB/tick.hook.new" "$STUB/tick.hook"
}
WH4=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee; WH5=ffffffffffffffffffffffffffffffffffffffff; WH6=abababababababababababababababababababab
wr_ready_fleet wrh N9
start "$I" "$WORK/wr13.out" --doc "$WD" --workers-from "$WM"
wait_hb "$I" || fail "(wr13) no baseline heartbeat"
wr_ready_hook N9 "$(printf -- '- 09:10 READY 2600 %s GREEN' "$WH4")"$'\n'
wait_exit "$WPID"
check "(wr13) a READY auto-go handled is handed to worker-event" "N9 READY 2600 $WH4 GREEN" "$(cat "$STUB/we.calls" 2>/dev/null)"
check "(wr13) and wakes no worker-ready" "0" "$(grep -c '^WAKE worker-ready' "$WORK/wr13.out")"
wr_stop
start "$I" "$WORK/wr14.out" --doc "$WD" --workers-from "$WM"
wait_exit "$WPID"
check "(wr14) nor on a re-arm" "0" "$(grep -c '^WAKE worker-ready' "$WORK/wr14.out")"
wr_stop
wr_ready_fleet wrab N10
start "$I" "$WORK/wr15.out" --doc "$WD" --workers-from "$WM"
wait_hb "$I" || fail "(wr15) no baseline heartbeat"
wr_ready_hook N10 "$(printf -- '- 09:10 READY 2601 %s GREEN\n- 09:11 READY 2601 %s GREEN' "$WH5" "$WH6")"$'\n'
wait_exit "$WPID"
check "(wr15) two READYs in one sample are each handed to worker-event, oldest first" "N10 READY 2601 $WH5 GREEN|N10 READY 2601 $WH6 GREEN" "$(paste -sd'|' "$STUB/we.calls" 2>/dev/null)"
check "(wr15) and the one the relay still holds wakes no worker-ready" "0" "$(grep -c '^WAKE worker-ready' "$WORK/wr15.out")"
wr_stop
export HIMMEL_FLAGS_TSV="$WORK/flags.tsv"
unset CHIEF_WAIT_WORKER_EVENT

cat > "$STUB/cadence-cause.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s run=%s %s https://github.com/x/y/actions/runs/%s cause: build / Run tests\n' "$1" "$2" "$3" "$2"
EOF
chmod +x "$STUB/cadence-cause.sh"
export CHIEF_WAIT_CADENCE="$STUB/cadence-cause.sh"
cd_tick() {
    tick_line "N1:FRESH" "ok"
    sed -i "s/ denials=none/ cadence=$1 denials=none/" "$STUB/tick.line"  # gnu-ok: Linux-only kit
}
cd_alive() { sleep 3; if kill -0 "$WPID" 2>/dev/null; then echo running; else echo exited; fi; }
reset_stub
cd_base='ci:success:3h:101,macos-cadence:failure:2d:106:RED'
cd_tick "$cd_base"
I="$(new_inbox cd1)"
start "$I" "$WORK/cd1.out"
wait_hb "$I" || fail "(cd1) no baseline heartbeat"
check "(cd1) a standing red at the first sample is a baseline, no wake" "running" "$(cd_alive)"
cd_tick 'ci:success:3h:101,macos-cadence:failure:3h:201:RED'
wait_exit "$WPID"
check "(cd2) a new red run ends the wait" "0" "$rc"
check "(cd2) the wake names the workflow, run, conclusion, link and cause" "WAKE cadence macos-cadence run=201 RED https://github.com/x/y/actions/runs/201 cause: build / Run tests" "$(head -n1 "$WORK/cd1.out")"
check "(cd2) exactly one cadence line" "1" "$(grep -c '^WAKE cadence' "$WORK/cd1.out")"
start "$I" "$WORK/cd3.out"
wait_hb "$I" || fail "(cd3) no baseline heartbeat"
check "(cd3) a re-armed waiter wakes nothing for the same run id" "running" "$(cd_alive)"
cd_tick 'ci:success:3h:101,macos-cadence:failure:4h:201:RED'
check "(cd3) the same run id a tick later still wakes nothing" "running" "$(cd_alive)"
cd_tick 'ci:success:3h:101,pages:skipped:4h:301:SKIP'
wait_exit "$WPID"
check "(cd4) a wrongly skipped run wakes" "WAKE cadence pages run=301 SKIP" "$(head -n1 "$WORK/cd3.out" | cut -d' ' -f1-5)"
reset_stub
cd_tick 'ci:success:3h:101,snyk-weekly:success:3d:401'
I="$(new_inbox cd5)"
start "$I" "$WORK/cd5.out"
wait_hb "$I" || fail "(cd5) no baseline heartbeat"
cd_tick 'ci:success:3h:102,snyk-weekly:success:3d:402'
check "(cd5) a new unflagged run, a correct skip, wakes nothing" "running" "$(cd_alive)"
cd_tick '?'
check "(cd6) cadence=? wakes nothing and the waiter survives" "running" "$(cd_alive)"
cd_tick 'ci:success:3h:102,fork-drift:success:40h:501:MISSED'
wait_exit "$WPID"
check "(cd7) a missed schedule wakes" "WAKE cadence fork-drift run=501 MISSED" "$(head -n1 "$WORK/cd5.out" | cut -d' ' -f1-5)"
stop_waiter "$WPID"
reset_stub
cd_tick 'ci:success:3h:101,pages:running:1m:601'
I="$(new_inbox cd8)"
start "$I" "$WORK/cd8.out"
wait_hb "$I" || fail "(cd8) no baseline heartbeat"
cd_tick 'ci:success:3h:101,pages:failure:5m:601:RED'
wait_exit "$WPID"
check "(cd8) a run in flight at the baseline that concludes red wakes" "WAKE cadence pages run=601 RED" "$(head -n1 "$WORK/cd8.out" | cut -d' ' -f1-5)"
stop_waiter "$WPID"
unset CHIEF_WAIT_CADENCE

rv_tick() {
    tick_line "N1:FRESH" "ok"
    sed -i "s/ denials=none/ review=$1 denials=none/" "$STUB/tick.line"  # gnu-ok: Linux-only kit
}
reset_stub
rv_tick '2026-11-05:3h:100:1:0:-'
I="$(new_inbox rv1)"
start "$I" "$WORK/rv1.out"
wait_hb "$I" || fail "(rv1) no baseline heartbeat"
check "(rv1) a review with only a 1-count class wakes nothing" "running" "$(cd_alive)"
rv_tick '2026-11-05:3h:100:2:0:-'
check "(rv1) more 1-count classes still wake nothing" "running" "$(cd_alive)"
rv_tick '2026-11-05:3h:100:2:1:-'
wait_exit "$WPID"
check "(rv2) a new class with 5+ failures wakes" "WAKE review 2026-11-05 new-classes-5+=1" "$(head -n1 "$WORK/rv1.out")"
check "(rv2) the tick line follows" "1" "$(grep -c '^TICK ' "$WORK/rv1.out")"
start "$I" "$WORK/rv3.out"
wait_hb "$I" || fail "(rv3) no baseline heartbeat"
check "(rv3) a re-armed waiter wakes nothing for the same review day" "running" "$(cd_alive)"
rv_tick '2026-11-05:5h:100:2:1:HIMMEL-9256+HIMMEL-9257'
check "(rv3) the same day with more reasons still wakes nothing" "running" "$(cd_alive)"
rv_tick '2026-11-06:2h:80:0:0:HIMMEL-9300'
wait_exit "$WPID"
check "(rv4) the next review day wakes on a filed ticket" "WAKE review 2026-11-06 filed=HIMMEL-9300" "$(head -n1 "$WORK/rv3.out")"
reset_stub
rv_tick '2026-11-06:2h:80:0:0:-:CAPPED'
I="$(new_inbox rv5)"
start "$I" "$WORK/rv5.out"
wait_hb "$I" || fail "(rv5) no baseline heartbeat"
check "(rv5) a review that only carries the old CAPPED flag wakes nothing" "running" "$(cd_alive)"
reset_stub
rv_tick '2026-11-04:30h:100:0:0:-:STALE'
I="$(new_inbox rv6)"
start "$I" "$WORK/rv6.out"
wait_exit "$WPID"
check "(rv6) a stale review wakes" "WAKE review 2026-11-04 STALE (no review for 26 h, last 2026-11-04, age 30h)" "$(head -n1 "$WORK/rv6.out")"
start "$I" "$WORK/rv7.out"
wait_hb "$I" || fail "(rv7) no baseline heartbeat"
check "(rv7) a re-armed waiter wakes nothing for the same stale date" "running" "$(cd_alive)"
rv_tick 'none'
check "(rv8) review=none wakes nothing and the waiter survives" "running" "$(cd_alive)"
stop_waiter "$WPID"

GRC=0; GRO="$(HIMMEL_REPO=rel bash "$WAIT" 2>&1)" || GRC=$?
check "(gr1) a relative HIMMEL_REPO is refused rc 2 with the exact refusal" "2|chief-wait: HIMMEL_REPO (rel) is not an absolute path - refusing to let it pick the gated checkout" "$GRC|$GRO"
GRC=0; GRO="$(HIMMEL_REPO="$WORK/gone" bash "$WAIT" 2>&1)" || GRC=$?
check "(gr2) a HIMMEL_REPO that is not a directory is refused rc 2 with the exact refusal" "2|chief-wait: the gated checkout HIMMEL_REPO ($WORK/gone) is not a directory" "$GRC|$GRO"
GK="$WORK/grkit"
if ! { mkdir -p "$GK/scripts/handover/chief-kit" "$GK/scripts/cr" "$GK/scripts/lib" \
    && cp "$HERE/chief-wait.sh" "$GK/scripts/handover/chief-kit/chief-wait.sh" \
    && cp -R "$HERE/../../cr/." "$GK/scripts/cr/" \
    && cp -R "$HERE/../../lib/." "$GK/scripts/lib/" \
    && rm -f "$GK/scripts/lib/gate-repo-resolver.sh" \
    && [ ! -e "$GK/scripts/lib/gate-repo-resolver.sh" ]; }; then
    echo "FAIL: (gr3) fixture setup" >&2; exit 1
fi
GRC=0; GRO="$(env -u HIMMEL_REPO bash "$GK/scripts/handover/chief-kit/chief-wait.sh" 2>&1)" || GRC=$?
GRO=${GRO##*$'\n'}
check "(gr3) a kit with no resolver lib refuses rc 2 naming the lib" "2|chief-wait: cannot load scripts/lib/gate-repo-resolver.sh; nothing waited" "$GRC|$GRO"

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
