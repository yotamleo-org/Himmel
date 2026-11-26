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
# Run: bash scripts/handover/chief-kit/test-chief-wait.sh
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
# No row here reads the pool (test-chief-wait-pool.sh does): an absent dispatcher makes the
# probe a no-op, never a next-dispatchable.sh run over the real mirror.
export CHIEF_WAIT_DISPATCH="$STUB/no-dispatch.sh"
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
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/sweep-off.sh"
export WAIT_SWEEP_CMD="$STUB/sweep-off.sh" WAIT_FOCUS_CMD="$STUB/sweep-off.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUB/size-off.sh"
export CHIEF_WAIT_SIZE="$STUB/size-off.sh"

# tick_line <workers> <board> [hb] [prs] [or] [fails]: a tick line whose action fields are set.
tick_line() {
    printf 'TICK 03:00 hb=%s workers=%s livestate=ok procs=2 models=x ceiling=ok atq=0 suites=0alive/0dead prs=%s bank=5h8/wk15/codex=? fill=40 tails=N1:LIVE inbox=none tick=UNKNOWN fleet=3/15 capacity=ok gql=4000/04:00 orphans=none nonces=ok legset=ok board=%s denials=none or=%s fails=%s\n' \
        "${3:-1m}" "$1" "${4:-#10}" "$2" "${5:-skip}" "${6:-none}" > "$STUB/tick.line"
}
reset_stub() { rm -f "$STUB/tick.rc" "$STUB/tick.blip" "$STUB/tick.churn" "$STUB/tick.sleep" "$STUB/tick.failafter" "$STUB/tick.ignoreterm"; tick_line "N1:FRESH" "ok"; printf 'PROCEED\n' > "$STUB/bank"; }

# wait_hb <inbox>: block until the waiter has taken its baseline (heartbeat
# carries a key), at most ~60 s; it returns at once when the waiter itself is gone.
wait_hb() {
    n=0
    while [ "$n" -lt 600 ]; do
        grep -q 'key=[0-9a-f]' "$1.wait" 2>/dev/null && return 0
        kill -0 "$WPID" 2>/dev/null || { grep -q 'key=[0-9a-f]' "$1.wait" 2>/dev/null; return; }
        sleep 0.1; n=$((n + 1))
    done
    return 1
}
# wait_exit <pid>: wait at most ~8 s for the waiter to exit; sets rc to its
# exit code or "running". Not a $(...) helper: `wait` must run in the shell
# that started the waiter.
wait_exit() { wait_exit_for "$1" 80; }
wait_exit_for() {
    local max_tenths="$2"
    n=0
    while [ "$n" -lt "$max_tenths" ]; do
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
stop_waiter() {
    kill "$1" 2>/dev/null
    local n=0
    while kill -0 "$1" 2>/dev/null && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
    kill -KILL "$1" 2>/dev/null
    wait "$1" 2>/dev/null
}

# --- (ws) a silent worker wakes the chief once and the operator is alerted ---
# A held worker is silent when its bus waker is capped (wakerstate=<w>:capped: the same unread
# mail was typed --max-wakes times) and its doc has had no write for CHIEF_WAIT_WORKER_SILENT_MIN
# minutes, or when a --succession tally names it still out. Every fleet below is a sandbox under
# $WORK: a chief doc with a Results heading, one worker doc aged with touch, a one-worker manifest,
# and the suite's page stub (never a real Telegram send). RED control (chief-wait.sh before this
# change): no WAKE worker-silent line, no page and no chief-doc bullet.
# Run only these rows with --worker-silent-only.
ws_fleet() { # <case> <age of the worker doc's last write, as touch -d reads it>: sets I, WD, WL, WM
    mkdir -p "$WORK/$1/consoles"; I="$WORK/$1/consoles/c.md"; : > "$I"
    WD="$WORK/$1/chief.md"; printf '# chief\n\n## Results\n' > "$WD"
    WL="$WORK/$1/HIMMEL-1-N1-a.md"; printf '# worker\n\n## Results\n- 09:00 LIVE — started\n' > "$WL"
    touch -d "$2" "$WL"  # gnu-ok: Linux-only kit
    WM="$WORK/$1/chief.fleet.json"; printf '{"schema":1,"workers":[{"doc":"%s","label":"N1"}]}\n' "$WL" > "$WM"
    rm -f "$STUB/pages"
}
ws_tick() { # [wakerstate value]: the standing tick line, a held worker with no bus edge
    tick_line "N1:FRESH" "ok"
    sed -i "s/ denials=none/ busedge=MISSING:N1${1:+ wakerstate=$1} denials=none/" "$STUB/tick.line"  # gnu-ok: Linux-only kit
}
ws_pages() { cat "$STUB/pages" 2>/dev/null | grep -c . || true; }  # pipefail-ok: none set; a missing file counts 0
ws_bullets() { grep -c '^- [0-9:]* WORKER-SILENT N1 signal=capped-waker' "$WD" 2>/dev/null || true; }
cat > "$STUB/silent-act.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB/silent-act.log"
[ ! -f "$STUB/silent-act.rc" ] || exit "$(cat "$STUB/silent-act.rc")"
if [ -f "$STUB/silent-act.next" ]; then cat "$STUB/silent-act.next"; rm -f "$STUB/silent-act.next"; exit 0; fi
echo "SILENT-ACT N1 done"
EOF
export CHIEF_WAIT_SILENT_ACT="$STUB/silent-act.sh"
rm -f "$STUB/silent-act.log"
ws_acts() { grep -c . "$STUB/silent-act.log" 2>/dev/null || true; }
reset_stub

tl_line() {
    local inbox="$1" n=0; shift
    start "$inbox" "$WORK/tl.out" "$@"
    while [ "$n" -lt 80 ] && ! grep -q . "$inbox.wait.ticklog" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
    stop_waiter "$WPID"
    head -n 1 "$inbox.wait.ticklog" 2>/dev/null || true  # swallow-ok: no log file is the RED reading, shown by the row's check
}
TL_RE='^start=[0-9]+ wall=[0-9]+\.[0-9]+ cpu=[0-9]+\.[0-9]+ rc=%s timedout=%s$'
tl_match() {
    # shellcheck disable=SC2059  # TL_RE is the format
    printf '%s\n' "$1" | grep -Eq "$(printf "$TL_RE" "$2" "$3")" && echo match || echo "no-match:$1"
}
reset_stub
I="$(new_inbox tl1)"
TL1="$(tl_line "$I" --workers "N1.md")"
check "(tl1) a tick that finishes logs rc=0 timedout=0 with start, wall and cpu" "match" "$(tl_match "$TL1" 0 0)"
check "(tl1) its count over 24 h is zero ticks timed out (negative control)" "ticks=1 tick-timeouts=0 window=24h" "$(bash "$WAIT" --tick-timeouts "$I" 2>&1)"
reset_stub
printf '5\n' > "$STUB/tick.sleep"
I="$(new_inbox tl2)"
export CHIEF_WAIT_TICK_TIMEOUT=1
TL2="$(tl_line "$I" --workers "N1.md")"
unset CHIEF_WAIT_TICK_TIMEOUT
check "(tl2) a tick that outlives the limit logs rc=124 timedout=1" "match" "$(tl_match "$TL2" 124 1)"
check "(tl2) wall is at least the 1 s limit" "yes" "$(printf '%s\n' "$TL2" | sed -n 's/.* wall=\([0-9]*\)\..*/\1/p' | awk '{ print ($1 >= 1) ? "yes" : "no" }')"
check "(tl2) its count over 24 h is one tick timed out" "ticks=1 tick-timeouts=1 window=24h" "$(bash "$WAIT" --tick-timeouts "$I" 2>&1)"
reset_stub
printf '1\n' > "$STUB/tick.rc"
I="$(new_inbox tl3)"
TL3="$(tl_line "$I" --workers "N1.md")"
check "(tl3) a tick that fails logs its rc with timedout=0" "match" "$(tl_match "$TL3" 1 0)"
check "(tl3) a failed tick is not a timed-out one in the count" "ticks=1 tick-timeouts=0 window=24h" "$(bash "$WAIT" --tick-timeouts "$I" 2>&1)"
reset_stub
: > "$STUB/tick.burn"
I="$(new_inbox tl6)"
TL6="$(tl_line "$I" --workers "N1.md")"
rm -f "$STUB/tick.burn"
check "(tl6) a tick that spends CPU logs it, children included, whatever the locale's decimal mark" "yes" "$(printf '%s\n' "$TL6" | sed -n 's/.* cpu=\([0-9.]*\) .*/\1/p' | LC_ALL=C awk '{ print ($1 >= 0.05) ? "yes" : "no" }')"
reset_stub
I="$(new_inbox tl4)"
NOW="$(date +%s)"
printf 'start=%s wall=120.50 cpu=3.10 rc=124 timedout=1\nstart=%s wall=1.00 cpu=0.50 rc=0 timedout=0\nstart=%s wall=120.01 cpu=2.00 rc=137 timedout=1\nstart=%s wall=120.00 cpu=2.00 rc=124 timedout=1\n' \
    "$((NOW - 3600))" "$((NOW - 60))" "$((NOW - 86400 + 600))" "$((NOW - 86400 - 600))" > "$I.wait.ticklog"
check "(tl4) the count takes the timed-out ticks of the last 24 h only" "ticks=3 tick-timeouts=2 window=24h" "$(bash "$WAIT" --tick-timeouts "$I" 2>&1)"
I="$(new_inbox tl5)"
check "(tl5) no log reads zero ticks, zero timed out" "ticks=0 tick-timeouts=0 window=24h" "$(bash "$WAIT" --tick-timeouts "$I" 2>&1)"
if [ "${1:-}" = --ticklog-only ]; then
    printf '\n%d failure(s)\n' "$fails"
    [ "$fails" -eq 0 ]; exit $?
fi
ws_fleet ws1 "2 hours ago"
ws_tick "N1:capped"
printf 'SILENT-ACT N1 stub-ran\n' > "$STUB/silent-act.next"
CHIEF_WAIT_WORKER_SILENT_MIN=30 start "$I" "$WORK/ws1.out" --doc "$WD" --workers-from "$WM"
wait_exit "$WPID"
check "(ws1) a capped waker on a doc quiet past the bound ends the wait" "0" "$rc"
check "(ws1) the wake names the worker and the signal" "WAKE worker-silent N1 signal=capped-waker" "$(head -n1 "$WORK/ws1.out" | cut -d' ' -f1-4)"
check "(ws1) exactly one worker-silent line for the worker" "1" "$(grep -c '^WAKE worker-silent' "$WORK/ws1.out")"
check "(ws1) the tick line follows it" "1" "$(grep -c '^TICK ' "$WORK/ws1.out")"
check "(ws1) the operator alert went out once" "1" "$(ws_pages)"
check "(ws1) and names the worker and the signal" "1" "$(grep -c 'WORKER-SILENT N1 signal=capped-waker' "$STUB/pages" 2>/dev/null)"
check "(ws1) the chief doc got one bullet naming the action" "1" "$(ws_bullets)"
check "(ws1) the exit reason is logged" "yes" "$(grep -q 'exit=wake-worker-silent' "$I.wait" && echo yes)"
check "(ws1) the acting helper ran once for the worker, with its signal and silent minutes" "1" "$(grep -cE -- "--doc $WD --fleet $WM --bucket $WORK/ws1 --chief chief --signal capped-waker N1 1[12][0-9]$" "$STUB/silent-act.log" 2>/dev/null || true)"
check "(ws1) its result line follows the wake line" "SILENT-ACT N1 stub-ran" "$(sed -n 2p "$WORK/ws1.out")"
if [ "$rc" = running ]; then stop_waiter "$WPID"; fi
# the state is unchanged: a re-arm repeats neither the wake, the page nor the bullet
CHIEF_WAIT_WORKER_SILENT_MIN=30 timeout -k 5 3 bash "$WAIT" "$I" --doc "$WD" --workers-from "$WM" > "$WORK/ws2.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(ws2) a re-arm on an unchanged silent worker keeps waiting" "124" "$rc"
check "(ws2) and prints no worker-silent line" "0" "$(grep -c 'worker-silent' "$WORK/ws2.out")"
check "(ws2) and pages nothing more" "1" "$(ws_pages)"
check "(ws2) and writes no second bullet" "1" "$(ws_bullets)"
check "(ws2) and asks the acting helper again, which has nothing to do" "yes" "$([ "$(ws_acts)" -ge 2 ] && echo yes)"
printf 'SILENT-ACT N1 relaunched DEMO-RESUME\n' > "$STUB/silent-act.next"
CHIEF_WAIT_WORKER_SILENT_MIN=30 start "$I" "$WORK/ws2c.out" --doc "$WD" --workers-from "$WM"
wait_exit "$WPID"
check "(ws2c) a keyed worker the helper later relaunches wakes the chief with a WAKE line" "WAKE worker-silent N1 signal=capped-waker" "$(head -n1 "$WORK/ws2c.out" | cut -d' ' -f1-4)"
check "(ws2c) and the helper's result rides under it" "SILENT-ACT N1 relaunched DEMO-RESUME" "$(sed -n 2p "$WORK/ws2c.out")"
check "(ws2c) with no second page" "1" "$(ws_pages)"
if [ "$rc" = running ]; then stop_waiter "$WPID"; fi
printf '2\n' > "$STUB/silent-act.rc"
CHIEF_WAIT_WORKER_SILENT_MIN=30 start "$I" "$WORK/ws2d.out" --doc "$WD" --workers-from "$WM"
wait_exit "$WPID"
check "(ws2d) a helper that exits non-zero wakes the chief with a WAKE line" "WAKE worker-silent N1 signal=capped-waker" "$(head -n1 "$WORK/ws2d.out" | cut -d' ' -f1-4)"
check "(ws2d) and names the failure under it" "SILENT-ACT N1 helper-failed rc=2" "$(sed -n 2p "$WORK/ws2d.out")"
if [ "$rc" = running ]; then stop_waiter "$WPID"; fi
CHIEF_WAIT_WORKER_SILENT_MIN=30 timeout -k 5 3 bash "$WAIT" "$I" --doc "$WD" --workers-from "$WM" > "$WORK/ws2e.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(ws2e) the same failure is named once per doc write: a re-arm keeps waiting" "124" "$rc"
rm -f "$STUB/silent-act.rc"
# the worker wrote, then went quiet again: the state moved, so it is a new silence
touch -d "90 minutes ago" "$WL"  # gnu-ok: Linux-only kit
CHIEF_WAIT_WORKER_SILENT_MIN=30 start "$I" "$WORK/ws2b.out" --doc "$WD" --workers-from "$WM"
wait_exit "$WPID"
check "(ws2b) a worker that wrote and went quiet again wakes again" "WAKE worker-silent N1 signal=capped-waker" "$(head -n1 "$WORK/ws2b.out" | cut -d' ' -f1-4)"
check "(ws2b) with a second alert" "2" "$(ws_pages)"
if [ "$rc" = running ]; then stop_waiter "$WPID"; fi

# negative: a Results bullet inside the bound keeps the worker out of the silent set
reset_stub
ws_acts_before="$(ws_acts)"
ws_fleet ws3 "1 minute ago"
ws_tick "N1:capped"
CHIEF_WAIT_WORKER_SILENT_MIN=30 timeout -k 5 3 bash "$WAIT" "$I" --doc "$WD" --workers-from "$WM" > "$WORK/ws3.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(ws3) a fresh bullet inside the bound keeps waiting" "124" "$rc"
check "(ws3) and prints no worker-silent wake" "0" "$(grep -c 'worker-silent' "$WORK/ws3.out")"
check "(ws3) and sends no alert" "0" "$(ws_pages)"
# negative: a quiet doc with a waker that is not capped is a worker waiting, not a silent one
reset_stub
ws_fleet ws4 "2 hours ago"
ws_tick
CHIEF_WAIT_WORKER_SILENT_MIN=30 timeout -k 5 3 bash "$WAIT" "$I" --doc "$WD" --workers-from "$WM" > "$WORK/ws4.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(ws4) a quiet doc with no capped waker keeps waiting" "124" "$rc"
check "(ws4) and prints no worker-silent wake" "0" "$(grep -c 'worker-silent' "$WORK/ws4.out")"
check "(ws3, ws4) a worker kept out of the silent set never reaches the acting helper" "$ws_acts_before" "$(ws_acts)"
# the bound is a named, overridable value: 20 quiet minutes sit inside the default and outside a 10-minute bound
reset_stub
ws_fleet ws5 "20 minutes ago"
ws_tick "N1:capped"
timeout -k 5 3 bash "$WAIT" "$I" --doc "$WD" --workers-from "$WM" > "$WORK/ws5a.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(ws5) 20 quiet minutes are inside the default bound" "0" "$(grep -c 'worker-silent' "$WORK/ws5a.out")"
CHIEF_WAIT_WORKER_SILENT_MIN=10 start "$I" "$WORK/ws5b.out" --doc "$WD" --workers-from "$WM"
wait_exit "$WPID"
check "(ws5) CHIEF_WAIT_WORKER_SILENT_MIN=10 makes them a silent worker" "WAKE worker-silent N1 signal=capped-waker" "$(head -n1 "$WORK/ws5b.out" | cut -d' ' -f1-4)"
if [ "$rc" = running ]; then stop_waiter "$WPID"; fi
# a succession partial that names the worker is the second signal, with no waker or age needed
reset_stub
ws_fleet ws6 "1 minute ago"
ws_tick
# shellcheck disable=SC2016  # the stub body expands when the stub runs
printf '#!/usr/bin/env bash\ncat "$STUB/ws-succ.out"\n' > "$STUB/ws-tracker.sh"
printf 'N1 missing\nINCOMPLETE 0/1 (waiting on: N1)\n' > "$STUB/ws-succ.out"
printf '#!/usr/bin/env bash\nexit 11\n' > "$STUB/ws-lock.sh"
CHIEF_WAIT_LOCK_STATUS="$STUB/ws-lock.sh" CHIEF_WAIT_TRACKER="$STUB/ws-tracker.sh" CHIEF_WAIT_SUCCESSION_SEC=1 start "$I" "$WORK/ws6.out" --doc "$WD" --succession S2 --silent-min 0 --workers-from "$WM"
wait_exit "$WPID"
check "(ws6) the partial wake still comes first" "WAKE succession partial 0/1 silent 0 min" "$(head -n1 "$WORK/ws6.out")"
check "(ws6) the worker it names gets one worker-silent line" "1" "$(grep -c '^WAKE worker-silent N1 signal=succession-partial' "$WORK/ws6.out")"
check "(ws6) and one operator alert" "1" "$(ws_pages)"
check "(ws6) a succession-partial worker reaches the acting helper with its signal" "1" "$(grep -c -- '--signal succession-partial N1 ' "$STUB/silent-act.log" 2>/dev/null || true)"
if [ "$rc" = running ]; then stop_waiter "$WPID"; fi
rm -f "$STUB/pages"

# --- (sp) a succession partial pages only a worker that is live ---
# sp_run <case> <waiting labels, space separated> <labels whose doc holds a lock>...: runs one tally
sp_run() {
    local c="$1" labels="$2" l first=1 h lockless; shift 2
    mkdir -p "$WORK/$c/consoles"; I="$WORK/$c/consoles/c.md"; : > "$I"
    WD="$WORK/$c/chief.md"; printf '# chief\n\n## Results\n' > "$WD"
    WM="$WORK/$c/chief.fleet.json"
    : > "$STUB/sp-held"
    printf '{"schema":1,"workers":[' > "$WM"
    for l in $labels; do
        [ "$l" != "${SP_NOROW:-}" ] || continue
        printf '# worker\n\n## Results\n- 09:00 LIVE — started\n' > "$WORK/$c/$l.md"
        [ "$first" -eq 1 ] || printf ',' >> "$WM"
        first=0
        lockless=""; [ "$l" != "${SP_LOCKLESS:-}" ] || lockless=',"lockless":true'
        if [ "$l" = "${SP_NODOC:-}" ]; then
            printf '{"label":"%s"%s}' "$l" "$lockless" >> "$WM"
        else
            printf '{"doc":"%s/%s.md","label":"%s"%s}' "$WORK/$c" "$l" "$l" "$lockless" >> "$WM"
        fi
    done
    [ -z "${SP_ROW2:-}" ] || printf ',{"doc":"%s/%s-b.md","label":"%s"}' "$WORK/$c" "$SP_ROW2" "$SP_ROW2" >> "$WM"
    printf ']}\n' >> "$WM"
    for h in "$@"; do printf '%s\n' "$WORK/$c/$h.md" >> "$STUB/sp-held"; done
    # shellcheck disable=SC2016  # the stub bodies expand when the stubs run
    printf '#!/usr/bin/env bash\ngrep -qxF -- "$2" "$STUB/sp-held" && exit %s\nexit 0\n' "${SP_RC:-11}" > "$STUB/sp-lock.sh"
    printf 'INCOMPLETE 11/18 (waiting on: %s)\n' "$(printf '%s' "$labels" | tr ' ' ',')" > "$STUB/sp-succ.out"
    # shellcheck disable=SC2016
    printf '#!/usr/bin/env bash\ncat "$STUB/sp-succ.out"\n' > "$STUB/sp-tracker.sh"
    reset_stub; ws_tick
    rm -f "$STUB/pages"
    CHIEF_WAIT_TRACKER="$STUB/sp-tracker.sh" CHIEF_WAIT_LOCK_STATUS="$STUB/sp-lock.sh" CHIEF_WAIT_SUCCESSION_SEC=1 start "$I" "$WORK/$c.out" --doc "$WD" --succession S2 --silent-min 0 --workers-from "$WM"
    wait_exit "$WPID"
    if [ "$rc" = running ]; then stop_waiter "$WPID"; fi
}
sp_silent_lines() { grep -c '^WAKE worker-silent' "$WORK/$1.out" || true; }  # pipefail-ok: none set
sp_bullets() { grep -c '^- [0-9:]* WORKER-SILENT' "$WD" || true; }  # pipefail-ok: none set
sp_run sp1 "N5004b"
check "(sp1) the partial wake still comes first" "WAKE succession partial 11/18 silent 0 min" "$(head -n1 "$WORK/sp1.out")"
check "(sp1) a closed worker with no lock prints no worker-silent line" "0" "$(sp_silent_lines sp1)"
check "(sp1) and writes no WORKER-SILENT bullet" "0" "$(sp_bullets)"
check "(sp1) and sends no page" "0" "$(ws_pages)"
sp_run sp2 "N5054"
check "(sp2) a never-launched worker prints no worker-silent line" "0" "$(sp_silent_lines sp2)"
check "(sp2) and writes no WORKER-SILENT bullet" "0" "$(sp_bullets)"
check "(sp2) and sends no page" "0" "$(ws_pages)"
sp_run sp3 "N5017 N5017c" N5017
check "(sp3) a worker answered on another row's doc prints no worker-silent line for itself" "0" "$(grep -c '^WAKE worker-silent N5017c' "$WORK/sp3.out" || true)"  # pipefail-ok: none set
check "(sp3) and is not paged" "0" "$(grep -c 'WORKER-SILENT N5017c' "$STUB/pages" 2>/dev/null || true)"  # pipefail-ok: none set
check "(sp3) and gets no bullet" "0" "$(grep -c 'WORKER-SILENT N5017c' "$WD" || true)"  # pipefail-ok: none set
check "(sp3) the held N5017 row still pages" "1" "$(grep -c '^WAKE worker-silent N5017 ' "$WORK/sp3.out" || true)"  # pipefail-ok: none set
sp_run sp4 "N7001" N7001
check "(sp4) a live worker with no quote-back prints one worker-silent line" "1" "$(grep -c '^WAKE worker-silent N7001 signal=succession-partial' "$WORK/sp4.out" || true)"  # pipefail-ok: none set
check "(sp4) writes one WORKER-SILENT bullet" "1" "$(sp_bullets)"
check "(sp4) and sends one page" "1" "$(ws_pages)"
sp_run sp5 "N5004b N4992c N5017b N4992d N5046b N5054 N5017c N7001" N7001
check "(sp5) a mixed tally prints worker-silent for the live worker only" "WAKE worker-silent N7001 signal=succession-partial" "$(grep '^WAKE worker-silent' "$WORK/sp5.out" | head -n1)"
check "(sp5) exactly one worker-silent line" "1" "$(sp_silent_lines sp5)"
check "(sp5) and exactly one page" "1" "$(ws_pages)"
SP_ROW2=N5017 sp_run sp6 "N5017" N5017-b
check "(sp6) a worker whose relaunch row holds a lock still pages" "1" "$(sp_silent_lines sp6)"
SP_LOCKLESS=N8001 sp_run sp7 "N8001"
check "(sp7) a lockless row proves nothing, so the worker pages once" "1" "$(sp_silent_lines sp7)"
check "(sp7) and sends one page" "1" "$(ws_pages)"
SP_RC=12 sp_run sp8 "N8002" N8002
check "(sp8) a lock status of 12 (stale) is not free, so the worker pages once" "1" "$(sp_silent_lines sp8)"
SP_RC=1 sp_run sp9 "N8003" N8003
check "(sp9) a lock status of 1 (could not read) is not free, so the worker pages once" "1" "$(sp_silent_lines sp9)"
SP_NOROW=N8004 sp_run sp10 "N8004"
check "(sp10) a label with no manifest row proves nothing, so it pages once" "1" "$(sp_silent_lines sp10)"
SP_NODOC=N8005 sp_run sp11 "N8005"
check "(sp11) a row with no doc proves nothing, so the worker pages once" "1" "$(sp_silent_lines sp11)"
rm -f "$STUB/pages"
if [ "${1:-}" = --worker-silent-only ]; then
    printf '\n%d failure(s)\n' "$fails"
    [ "$fails" -eq 0 ]; exit $?
fi

# A missing ceiling key loses the alarm; saving it must also suppress a re-arm.
reset_stub
I="$(new_inbox wt-ceiling)"
start "$I" "$WORK/wt-ceiling.out" --workers "N1.md"
wait_hb "$I" || fail "(wt-ceiling) no baseline heartbeat"
sed -i 's/ denials=none/ wt-ceiling=72\/100 denials=none/' "$STUB/tick.line"  # gnu-ok: Linux-only kit
wait_exit "$WPID"
check "(wt-ceiling) reaching the alarm ends the wait" "0" "$rc"
check "(wt-ceiling) the wake names the ceiling" "WAKE tick changed=wt-ceiling usage=PROCEED" "$(head -n1 "$WORK/wt-ceiling.out")"
if [ "$rc" = running ]; then stop_waiter "$WPID"; fi
timeout -k 5 3 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/wt-ceiling-rearm.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit
check "(wt-ceiling) an unchanged alarm keeps waiting" "124" "$rc"
check "(wt-ceiling) an unchanged alarm does not re-wake" "" "$(cat "$WORK/wt-ceiling-rearm.out")"
# residual-cap=<version>:<n> (a version past the residual soft cap) is in the key whole: it appearing
# or its value moving wakes once, an unchanged value stays silent on a re-arm, and its going away is no wake.
reset_stub
I="$(new_inbox cap-field)"
start "$I" "$WORK/cap-field.out" --workers "N1.md"
wait_hb "$I" || fail "(cap) no baseline heartbeat"
sed -i 's/ denials=none/ residual-cap=v1.1.3:16 denials=none/' "$STUB/tick.line"  # gnu-ok: Linux-only kit
wait_exit "$WPID"
check "(cap) a version crossing the soft cap ends the wait" "0" "$rc"
check "(cap) the wake names the cap field" "WAKE tick changed=residual-cap usage=PROCEED" "$(head -n1 "$WORK/cap-field.out")"
if [ "$rc" = running ]; then stop_waiter "$WPID"; fi
timeout -k 5 3 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/cap-field-rearm.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit
check "(cap) an unchanged cap keeps waiting" "124" "$rc"
check "(cap) an unchanged cap does not re-wake" "" "$(cat "$WORK/cap-field-rearm.out")"
start "$I" "$WORK/cap-field-move.out" --workers "N1.md"
wait_hb "$I" || fail "(cap) no re-armed heartbeat"
sed -i 's/ residual-cap=v1.1.3:16/ residual-cap=v1.1.3:17/' "$STUB/tick.line"  # gnu-ok: Linux-only kit
wait_exit "$WPID"
check "(cap) a moved cap count ends the wait" "0" "$rc"
check "(cap) the moved count wakes as cap" "WAKE tick changed=residual-cap usage=PROCEED" "$(head -n1 "$WORK/cap-field-move.out")"
if [ "$rc" = running ]; then stop_waiter "$WPID"; fi
start "$I" "$WORK/cap-field-gone.out" --workers "N1.md"
wait_hb "$I" || fail "(cap) no cleared heartbeat"
sed -i 's/ residual-cap=v1.1.3:17//' "$STUB/tick.line"  # gnu-ok: Linux-only kit
wait_exit "$WPID"
check "(cap) a cap that goes away keeps waiting" "running" "$rc"
if [ "$rc" = running ]; then stop_waiter "$WPID"; fi
reset_stub
sed -i 's/ denials=none/ residual-cap=v1.1.3:16 denials=none/' "$STUB/tick.line"  # gnu-ok: Linux-only kit
I="$(new_inbox cap-cut)"
start "$I" "$WORK/cap-cut.out" --workers "N1.md"
wait_hb "$I" || fail "(cap) no saved-cap heartbeat"
sed -i 's/ residual-cap=v1.1.3:16/ residual-cap=?/' "$STUB/tick.line"  # gnu-ok: Linux-only kit
wait_exit "$WPID"
check "(cap) residual-cap=? (a cut read) keeps the saved cap and wakes nothing" "running" "$rc"
sed -i 's/ residual-cap=?/ residual-cap=v1.1.3:17/' "$STUB/tick.line"  # gnu-ok: Linux-only kit
wait_exit "$WPID"
check "(cap) a moved cap after residual-cap=? wakes as cap" "WAKE tick changed=residual-cap usage=PROCEED" "$(head -n1 "$WORK/cap-cut.out")"
if [ "$rc" = running ]; then stop_waiter "$WPID"; fi
# a wake key carrying both residual-cap= and open=: each is in the key whole, a
# moved open count wakes as open, open=? keeps the saved value, and a key saved under the old
# cap= name reads as residual-cap=, so the rename is no wake. RED control (chief-wait.sh before the rename):
# the new names are not in the key, so no change is seen.
reset_stub
sed -i 's/ denials=none/ residual-cap=v1.1.3:16 open=v1.1.3:40 denials=none/' "$STUB/tick.line"  # gnu-ok: Linux-only kit
I="$(new_inbox cap-open)"
start "$I" "$WORK/cap-open.out" --workers "N1.md"
wait_hb "$I" || fail "(open) no baseline heartbeat"
sed -i 's/ open=v1.1.3:40/ open=v1.1.3:41/' "$STUB/tick.line"  # gnu-ok: Linux-only kit
wait_exit "$WPID"
check "(open) a moved open count alone wakes as open" "WAKE tick changed=open usage=PROCEED" "$(head -n1 "$WORK/cap-open.out")"
if [ "$rc" = running ]; then stop_waiter "$WPID"; fi
sed -i 's/ residual-cap=v1.1.3:16 open=v1.1.3:41/ residual-cap=v1.1.3:17 open=v1.1.3:42/' "$STUB/tick.line"  # gnu-ok: Linux-only kit
start "$I" "$WORK/cap-open-both.out" --workers "N1.md"
wait_exit "$WPID"
check "(open) both fields moving at once wake as both" "WAKE tick changed=residual-cap,open usage=PROCEED" "$(head -n1 "$WORK/cap-open-both.out")"
if [ "$rc" = running ]; then stop_waiter "$WPID"; fi
sed -i 's/ open=v1.1.3:42/ open=?/' "$STUB/tick.line"  # gnu-ok: Linux-only kit
start "$I" "$WORK/cap-open-cut.out" --workers "N1.md"
wait_exit "$WPID"
check "(open) open=? (a cut read) keeps the saved count and wakes nothing" "running" "$rc"
if [ "$rc" = running ]; then stop_waiter "$WPID"; fi
sed -i 's/ residual-cap=v1.1.3:17 open=?/ residual-cap=v1.1.3:17 open=v1.1.3:42/' "$STUB/tick.line"  # gnu-ok: Linux-only kit
timeout -k 5 3 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/cap-open-same.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit
check "(open) the saved count returning is no change" "124" "$rc"
sed -i 's/residual-cap=/cap=/' "$I.wait.state"  # gnu-ok: Linux-only kit
timeout -k 5 3 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/cap-open-migrate.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit
check "(open) a key saved under the old cap= name is no change under residual-cap=" "124" "$rc"
check "(open) and prints no wake" "" "$(cat "$WORK/cap-open-migrate.out")"
# hreg=<live-no-rows>/<stale>/<asks> is in the key whole: a moved value wakes once, an unchanged one
# stays silent, hreg=? keeps the saved value and its going away is no wake. RED control (chief-wait.sh before this change):
# the waiter has no hreg key, so none of these wakes.
reset_stub
I="$(new_inbox hreg)"
start "$I" "$WORK/hreg.out" --workers "N1.md"
wait_hb "$I" || fail "(hreg) no baseline heartbeat"
sed -i 's/ denials=none/ hreg=1\/0\/0 denials=none/' "$STUB/tick.line"  # gnu-ok: Linux-only kit
wait_exit "$WPID"
check "(hreg) a new hreg value ends the wait" "0" "$rc"
check "(hreg) the wake names hreg" "WAKE tick changed=hreg usage=PROCEED" "$(head -n1 "$WORK/hreg.out")"
if [ "$rc" = running ]; then stop_waiter "$WPID"; fi
timeout -k 5 3 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/hreg-rearm.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit
check "(hreg) two identical ticks (the same value on a re-arm) keep waiting" "124" "$rc"
check "(hreg) ... and wake nothing" "" "$(cat "$WORK/hreg-rearm.out")"
start "$I" "$WORK/hreg-move.out" --workers "N1.md"
wait_hb "$I" || fail "(hreg) no re-armed heartbeat"
sed -i 's/ hreg=1\/0\/0/ hreg=?/' "$STUB/tick.line"  # gnu-ok: Linux-only kit
wait_exit "$WPID"
check "(hreg) hreg=? (a failed read) keeps the saved value and wakes nothing" "running" "$rc"
sed -i 's/ hreg=?/ hreg=1\/2\/0/' "$STUB/tick.line"  # gnu-ok: Linux-only kit
wait_exit "$WPID"
check "(hreg) a moved value wakes as hreg" "WAKE tick changed=hreg usage=PROCEED" "$(head -n1 "$WORK/hreg-move.out")"
if [ "$rc" = running ]; then stop_waiter "$WPID"; fi

cat > "$STUB/ql.sh" <<'EOF'
#!/usr/bin/env bash
if [ -s "$STUB/ql.out" ]; then cat "$STUB/ql.out"; else echo 'sweep: no held locks'; fi
EOF
export HOLDS_QUEUE_LOCK="$STUB/ql.sh"
ql_live() { local k; : > "$STUB/ql.out"; for k in "$@"; do printf 'slug=u__himmel__%s-F1-case-2026-11-22 session=s host=h age=5s status=OK\n' "$k" >> "$STUB/ql.out"; done; }
ql_live HIMMEL-9942 PROJ-9942 PROJ-9012
ha_pages() { if [ -f "$STUB/pages" ]; then wc -l < "$STUB/pages" | tr -d ' '; else echo 0; fi; }
HA_HOME="$WORK/hreg-home"; HA_PRIMARY="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir)"; HA_PRIMARY="${HA_PRIMARY%/.git}"
HA_ESC="${HA_PRIMARY//%/%25}"; HA_ESC="${HA_ESC//\//%2F}"
HA_DIR="$HA_HOME/.himmel/state/holds/$HA_ESC"; mkdir -p "$HA_DIR"
printf 'HIMMEL-9941\tlab\t/nowhere/HIMMEL-9941-x.md\tbrief\t\n' > "$HA_DIR/scripts%2Fcheck-ci.sh"
printf '%s\tdeny\tscripts/check-ci.sh\tHIMMEL-9942\tHIMMEL-9941\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$HA_HOME/.himmel/state/holds/events.log"
reset_stub
sed -i 's/ denials=none/ hreg=0\/0\/1 denials=none/' "$STUB/tick.line"  # gnu-ok: Linux-only kit
rm -f "$STUB/pages"
I="$(new_inbox hask)"
HOME="$HA_HOME" start "$I" "$WORK/hask.out" --workers "N1.md"
wait_exit "$WPID"
check "(hask) a chief-grantable ask wakes the chief" "0" "$rc"
check "(hask) one WAKE hold-ask line with the key, path, holder and the full paste-ready grant command" "WAKE hold-ask $KP-9942 wants scripts/check-ci.sh (held by $KP-9941). Grant: python3 -I $HA_PRIMARY/scripts/handover/chief-kit/holds.py grant --key $KP-9942 --repo $HA_PRIMARY scripts/check-ci.sh" "$(grep '^WAKE ' "$WORK/hask.out")"
check "(hask) the tick line follows" "1" "$(grep -c '^TICK ' "$WORK/hask.out")"
check "(hask) the wake pages nobody" "0" "$(ha_pages)"
check "(hask) the exit reason is logged" "yes" "$(grep -q 'exit=wake-hold-ask' "$I.wait" && echo yes)"
if [ "$rc" = running ]; then stop_waiter "$WPID"; fi
HOME="$HA_HOME" start "$I" "$WORK/hask2.out" --workers "N1.md"
wait_hb "$I" || fail "(hask) no re-armed heartbeat"
sleep 3
check "(hask) a re-armed waiter neither wakes nor pages again for the same ask" "running|0" "$(kill -0 "$WPID" 2>/dev/null && echo running)|$(ha_pages)"
stop_waiter "$WPID"
rm -f "$STUB/pages"

cat > "$STUB/pagek.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s\n' "${2-}" "$1" >> "$STUB/pagek"
exit 0
EOF
chmod +x "$STUB/pagek.sh"
pk_kinds() { cut -d'|' -f1 "$STUB/pagek" 2>/dev/null | paste -sd, -; }
pk_n() { if [ -f "$STUB/pagek" ]; then grep -c . "$STUB/pagek" || true; else echo 0; fi; }
stuck_run() {
    local c="$1"; shift
    rm -f "$STUB/pagek"
    I="${I_SEED:-$(new_inbox "$c")}"
    bash "$WAIT" "$I" "$@" > "$WORK/$c.out" 2>"$WORK/$c.err" &
    WPID=$!
    if ! wait_hb "$I" && kill -0 "$WPID" 2>/dev/null; then fail "($c) no baseline heartbeat"; fi
    n=0; while [ ! -s "$STUB/pagek" ] && [ "$n" -lt 40 ]; do sleep 0.1; n=$((n + 1)); done
    sleep 1.5
    stop_waiter "$WPID"
}
hask_wake() { grep '^WAKE ' "$WORK/$1.out" 2>/dev/null | cut -d' ' -f1-3 | paste -sd, -; }
hask_home() {
    local h="$WORK/home-$1" esc d
    esc="${HA_PRIMARY//%/%25}"; esc="${esc//\//%2F}"
    d="$h/.himmel/state/holds/$esc"; mkdir -p "$d"
    local p="${3//\//%2F}"
    printf '%s\tlab\t/nowhere/%s-x.md\tbrief\t\n' "$4" "$4" > "$d/$p"
    printf '%s\tdeny\t%s\t%s\t%s\n' "${5:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" "$3" "$2" "$4" > "$h/.himmel/state/holds/events.log"
    printf '%s' "$h"
}
hask_pr_row() { printf '%s\tlab\t/nowhere/%s-x.md\tpr\t%s\n' "$2" "$2" "$3" > "$1/.himmel/state/holds/$HA_ESC/scripts%2Fown-$3.sh"; }
hask_tick() { reset_stub; sed -i 's/ denials=none/ hreg=0\/0\/1 denials=none/' "$STUB/tick.line"; }  # gnu-ok: Linux-only kit

H_CHIEF="$(hask_home chief PROJ-9942 scripts/check-ci.sh PROJ-9941)"
H_OPER="$(hask_home oper PROJ-9942 .github/workflows/ci.yml PROJ-9941)"
hask_tick; I_SEED=""
HOME="$H_CHIEF" CHIEF_WAIT_PAGE_CMD="$STUB/pagek.sh" stuck_run k1 --workers "N1.md"
check "(10632a) a chief-grantable ask pages nobody" "" "$(pk_kinds)"
check "(10632a) ... and wakes the chief as WAKE hold-ask" "WAKE hold-ask PROJ-9942" "$(hask_wake k1)"
hask_tick
HOME="$H_OPER" CHIEF_WAIT_PAGE_CMD="$STUB/pagek.sh" stuck_run k2 --workers "N1.md"
check "(10632c) control: a CI-workflow ask still pages the operator as hold-ask-operator" "hold-ask-operator" "$(pk_kinds)"
check "(10632c) ... and wakes no chief" "" "$(hask_wake k2)"
PY_REAL_PATH="$PATH"; PY4_PATH="$WORK/py4:$PATH"
mkdir -p "$WORK/py4"
cat > "$WORK/py4/python3" <<'EOF'
#!/usr/bin/env bash
if [ "${3:-}" = asks ]; then printf '%b\n' "$ASKS_STUB"; exit 0; fi
PATH="$REAL_PATH" exec python3 "$@"
EOF
chmod +x "$WORK/py4/python3"
hask_tick
HOME="$H_CHIEF" REAL_PATH="$PY_REAL_PATH" PATH="$PY4_PATH" ASKS_STUB='PROJ-9942\tscripts/check-ci.sh\tPROJ-9941\tgrant-cmd' CHIEF_WAIT_PAGE_CMD="$STUB/pagek.sh" stuck_run k3 --workers "N1.md"
check "(R3.2) a 4-field asks line pages as hold-ask-operator" "hold-ask-operator" "$(pk_kinds)"
hask_tick
HOME="$H_CHIEF" REAL_PATH="$PY_REAL_PATH" PATH="$PY4_PATH" ASKS_STUB='PROJ-9942\tscripts/check-ci.sh\tPROJ-9941\tgrant-cmd\tchief' CHIEF_WAIT_PAGE_CMD="$STUB/pagek.sh" stuck_run k4 --workers "N1.md"
check "(R3.2) an unknown field 5 pages as hold-ask-operator" "hold-ask-operator" "$(pk_kinds)"

NOW_R="$(date +%s)"
hask_tick
HOME="$H_CHIEF" HIMMEL_TEST_FIXTURE=1 CHIEF_WAIT_NOW=$((NOW_R + 31 * 60)) CHIEF_WAIT_PAGE_CMD="$STUB/pagek.sh" stuck_run s1 --workers "N1.md"
check "(10632a) a chief-grantable ask pending 31 minutes pages no hold-ask-stuck" "" "$(pk_kinds)"
check "(10632a) ... it wakes the chief once" "WAKE hold-ask PROJ-9942" "$(hask_wake s1)"
HOME="$H_CHIEF" HIMMEL_TEST_FIXTURE=1 CHIEF_WAIT_NOW=$((NOW_R + 40 * 60)) CHIEF_WAIT_PAGE_CMD="$STUB/pagek.sh" I_SEED="$I" stuck_run s1b --workers "N1.md"
check "(R4.1) a re-armed waiter pages nothing more for the same ask" "" "$(pk_kinds)"
check "(R4.1) ... and wakes nothing more" "" "$(hask_wake s1b)"
H_GR="$(hask_home granted PROJ-9942 scripts/check-ci.sh PROJ-9941)"
: > "$H_GR/.himmel/state/holds/${HA_ESC}/scripts%2Fcheck-ci.sh.grant.PROJ-9942"
hask_tick
I_SEED="$(new_inbox s2)"; printf 'PROJ-9942\tscripts/check-ci.sh\t%s\n' "$NOW_R" > "$I_SEED.wait.holdasks"
HOME="$H_GR" HIMMEL_TEST_FIXTURE=1 CHIEF_WAIT_NOW=$((NOW_R + 31 * 60)) CHIEF_WAIT_PAGE_CMD="$STUB/pagek.sh" stuck_run s2 --workers "N1.md"
check "(R4.1) an ask granted before the 30 minutes pages nothing" "0" "$(pk_n)"

H_T="$(hask_home t0354 PROJ-9012 scripts/check-ci.sh PROJ-8992)"
hask_tick
I_SEED="$(new_inbox s3)"; printf 'PROJ-9012\tscripts/check-ci.sh\t%s\n' "$NOW_R" > "$I_SEED.wait.holdasks"
HOME="$H_T" HIMMEL_TEST_FIXTURE=1 CHIEF_WAIT_NOW=$((NOW_R + 30 * 60)) CHIEF_WAIT_PAGE_CMD="$STUB/pagek.sh" stuck_run s3 --workers "N1.md"
check "(10632a) the 03:54 chief-grantable ask, ungranted at 04:24, pages the operator nothing" "0" "$(pk_n)"
check "(10632a) ... an ask an older waiter recorded still wakes the chief once" "WAKE hold-ask PROJ-9012" "$(hask_wake s3)"
H_TO="$(hask_home t0354o PROJ-9012 .github/workflows/ci.yml PROJ-8992)"
hask_tick
I_SEED="$(new_inbox s3o)"; printf 'PROJ-9012\t.github/workflows/ci.yml\t%s\n' "$NOW_R" > "$I_SEED.wait.holdasks"
HOME="$H_TO" HIMMEL_TEST_FIXTURE=1 CHIEF_WAIT_NOW=$((NOW_R + 30 * 60)) CHIEF_WAIT_PAGE_CMD="$STUB/pagek.sh" stuck_run s3o --workers "N1.md"
check "(R4.3) an operator ask ungranted at 30 minutes pages exactly one hold-ask-stuck" "hold-ask-stuck" "$(pk_kinds)"
cp "$STUB/pagek" "$WORK/s3.pagek"
H_T2="$(hask_home t0354g PROJ-9012 .github/workflows/ci.yml PROJ-8992)"
: > "$H_T2/.himmel/state/holds/${HA_ESC}/.github%2Fworkflows%2Fci.yml.grant.PROJ-9012"
hask_tick
I_SEED="$(new_inbox s3g)"; printf 'PROJ-9012\t.github/workflows/ci.yml\t%s\n' "$NOW_R" > "$I_SEED.wait.holdasks"
HOME="$H_T2" HIMMEL_TEST_FIXTURE=1 CHIEF_WAIT_NOW=$((NOW_R + 30 * 60)) CHIEF_WAIT_PAGE_CMD="$STUB/pagek.sh" stuck_run s3g --workers "N1.md"
check "(R4.3) the same ask granted before then pages none" "0" "$(pk_n)"

check "(R4.4) the hold-ask-stuck text" "hold-ask-stuck|A file ask waited 30 min: PROJ-9012 wants .github/workflows/ci.yml, held by PROJ-8992. Blocks: that worker. Do: in a real terminal, run: python3 -I $HA_PRIMARY/scripts/handover/chief-kit/holds.py grant --key PROJ-9012 --repo $HA_PRIMARY .github/workflows/ci.yml" "$(grep '^hold-ask-stuck|' "$WORK/s3.pagek" 2>/dev/null || true)"

I_SEED=""
H_GONE="$(hask_home gone PROJ-9950 scripts/check-ci.sh PROJ-9941)"; hask_pr_row "$H_GONE" PROJ-9950 4701
hask_tick
HOME="$H_GONE" CHIEF_WAIT_PAGE_CMD="$STUB/pagek.sh" stuck_run g1 --workers "N1.md"
check "(10632b) an ask with no worker and a merged PR pages nothing" "0" "$(pk_n)"
check "(10632b) ... and wakes nothing" "" "$(hask_wake g1)"
H_GOP="$(hask_home gonepr PROJ-9950 scripts/check-ci.sh PROJ-9941)"; hask_pr_row "$H_GOP" PROJ-9950 10
hask_tick
HOME="$H_GOP" CHIEF_WAIT_PAGE_CMD="$STUB/pagek.sh" stuck_run g2 --workers "N1.md"
check "(10632b) control: the same ask with its PR open (in prs=) wakes the chief" "WAKE hold-ask PROJ-9950" "$(hask_wake g2)"
hask_tick; sed -i 's/ prs=[^ ]*/ prs=?/' "$STUB/tick.line"  # gnu-ok: Linux-only kit
HOME="$H_GONE" CHIEF_WAIT_PAGE_CMD="$STUB/pagek.sh" stuck_run g3 --workers "N1.md"
check "(10632b) control: with prs=? (an unread PR list) the ask is kept and wakes the chief" "WAKE hold-ask PROJ-9950" "$(hask_wake g3)"

R_AT=$(( $(date +%s) - 40 * 60 ))
H_R="$(hask_home r10536 HIMMEL-10536 scripts/eval/review-panel/test-review-panel.sh HIMMEL-10342 "$(date -u -d "@$R_AT" +%Y-%m-%dT%H:%M:%SZ)")"  # gnu-ok: Linux-only kit
hask_tick
I_SEED="$(new_inbox r10536)"; printf 'HIMMEL-10536\tscripts/eval/review-panel/test-review-panel.sh\t%s\n' "$R_AT" > "$I_SEED.wait.holdasks"
HOME="$H_R" CHIEF_WAIT_PAGE_CMD="$STUB/pagek.sh" stuck_run r10536 --workers "N1.md"
check "(10632d) the HIMMEL-10536 replay pages the operator nothing" "0" "$(pk_n)"
check "(10632d) ... and wakes nothing" "" "$(hask_wake r10536)"
I_SEED=""

T31=$(( $(date +%s) - 31 * 60 ))
hask_tick
I_SEED="$(new_inbox s6)"; printf 'PROJ-9942\t.github/workflows/ci.yml\t%s\n' "$T31" > "$I_SEED.wait.holdasks"
HOME="$H_OPER" HIMMEL_TEST_FIXTURE=0 CHIEF_WAIT_NOW="$T31" CHIEF_WAIT_PAGE_CMD="$STUB/pagek.sh" stuck_run s6 --workers "N1.md"
check "(R4.6) CHIEF_WAIT_NOW without HIMMEL_TEST_FIXTURE=1 is ignored: the 31-minute ask still pages hold-ask-stuck" "hold-ask-stuck" "$(pk_kinds)"
hask_tick
I_SEED="$(new_inbox s6c)"; printf 'PROJ-9942\t.github/workflows/ci.yml\t%s\n' "$T31" > "$I_SEED.wait.holdasks"
HOME="$H_OPER" HIMMEL_TEST_FIXTURE=1 CHIEF_WAIT_NOW="$T31" CHIEF_WAIT_PAGE_CMD="$STUB/pagek.sh" stuck_run s6c --workers "N1.md"
check "(R4.6) control: with HIMMEL_TEST_FIXTURE=1 the same value is honoured and the ask pages nothing" "0" "$(pk_n)"
unset I_SEED

den_case() {
    local c="$1" label="$2" dm="$3" ak="$4" noff="$5" poff="${6:-0}" B P dir key
    B="$(date +%s)"; P=$((B + poff)); dir="$WORK/den-$c"; mkdir -p "$dir/acks" "$dir/w"
    key="$(printf '%s' "$label" | tr -c 'A-Za-z0-9._#+-' '_')"
    printf 'leg=%s\ncount=1\nclass=PAUSE-RISK\nts=%s\n' "$label" "$P" > "$dir/acks/$key.page"
    [ "$ak" = none ] || printf 'leg=%s\ncount=1\nclass=PAUSE-RISK\nts=%s\n' "$label" $((P + ak)) > "$dir/acks/$key.ack"
    if [ "${DEN_CUTOVER:-seed}" = seed ]; then printf '%s\n' $((B - 172800)) > "$dir/acks/.stuck-cutover"; fi
    if [ "${DEN_CUTOVER:-seed}" = empty ]; then : > "$dir/acks/.stuck-cutover"; fi
    printf '# chief\n\n## Results\n' > "$dir/chief.md"
    printf '# worker\n\n## Results\n' > "$dir/w/PROJ-9503-N1-a.md"
    if [ "$dm" = none ]; then touch -d "@$((P - 3600))" "$dir/w/PROJ-9503-N1-a.md"; else touch -d "@$((P + dm))" "$dir/w/PROJ-9503-N1-a.md"; fi  # gnu-ok: Linux-only kit
    printf '{"schema":1,"workers":[{"doc":"%s","label":"N1"}]}\n' "$dir/w/PROJ-9503-N1-a.md" > "$dir/chief.fleet.json"
    reset_stub
    I_SEED="$(new_inbox "$c")"
    DEN_NOW=$((P + noff))
    HIMMEL_DENIAL_ACK_DIR="$dir/acks" CHIEF_WAIT_PAGE_CMD="$STUB/pagek.sh" HIMMEL_TEST_FIXTURE="${DEN_FIXTURE:-1}" CHIEF_WAIT_NOW="$DEN_NOW" stuck_run "$c" --doc "$dir/chief.md" --workers-from "$dir/chief.fleet.json"
    unset I_SEED
}
den_case dn1 N1 none none 1860
check "(R4.2) a manifest denial unacked at minute 31 with no doc write pages denial-stuck once" "denial-stuck" "$(pk_kinds)"
check "(R4.4) the denial-stuck text names the worker, the ticket, the class and the ack command" "denial-stuck|Worker N1 on PROJ-9503 has been parked 30 min by a classifier denial (PAUSE-RISK). Blocks: PROJ-9503. Do: run ack-denial.sh N1" "$(cat "$STUB/pagek" 2>/dev/null)"
den_case dn2 N1 600 none 1860
check "(R4.2) the same denial with a doc write at minute 10 pages nothing" "0" "$(pk_n)"
den_case dn3 himmel#81843b5d none none 1860
check "(R4.2) the 04:41 label himmel#81843b5d (no manifest row) unacked at minute 31 pages exactly one denial-stuck" "denial-stuck" "$(pk_kinds)"
den_case dn4 himmel#81843b5d none 600 1860
check "(R4.2) the same label acked at minute 10 pages nothing" "0" "$(pk_n)"
den_case dn5 N1 none none 600
check "(R4.2) a denial 10 minutes old pages nothing" "0" "$(pk_n)"
DEN_FIXTURE=0 den_case dn6 N1 none none 0 -1860
check "(R4.6) a denial: CHIEF_WAIT_NOW without HIMMEL_TEST_FIXTURE=1 is ignored, the 31-minute denial pages denial-stuck" "denial-stuck" "$(pk_kinds)"
den_case dn6c N1 none none 0 -1860
check "(R4.6) control: with HIMMEL_TEST_FIXTURE=1 the same value is honoured and nothing pages" "0" "$(pk_n)"

den_case dn7 N9 none none 108000
check "(R4.2) a stale record (30 hours) whose worker is in no fleet manifest does not page" "0" "$(pk_n)"
den_case dn8 N9 none none 1860
check "(R4.2) control: the same unresolved worker at 31 minutes pages denial-stuck" "denial-stuck" "$(pk_kinds)"
DEN_CUTOVER=none den_case dn9 N1 none none 1860
check "(R4.2) a page record that exists before the first stuck scan never pages" "0" "$(pk_n)"
check "(R4.2) the first scan records its cutover beside the page records" "yes" "$([ -s "$WORK/den-dn9/acks/.stuck-cutover" ] && echo yes)"
DEN_CUTOVER=empty den_case dn11 N1 none none 1860
check "(R4.2) an interrupted writer's empty cutover file is repaired, so a record from before it still does not page" "0:yes" "$(pk_n):$(grep -qE '^[0-9]+$' "$WORK/den-dn11/acks/.stuck-cutover" && echo yes)"
den_case dn10 N1 none none 1860
check "(R4.2) the first waiter pages the denial once" "denial-stuck" "$(pk_kinds)"
I_SEED="$(new_inbox dn10b)" HIMMEL_DENIAL_ACK_DIR="$WORK/den-dn10/acks" CHIEF_WAIT_PAGE_CMD="$STUB/pagek.sh" HIMMEL_TEST_FIXTURE=1 CHIEF_WAIT_NOW="$DEN_NOW" stuck_run dn10b --doc "$WORK/den-dn10/chief.md" --workers-from "$WORK/den-dn10/chief.fleet.json"
check "(R4.2) a second inbox on the same station does not page the same record again" "0" "$(pk_n)"

# vmismatch= wakes only as a positive count; 0 and ? stay out of the key.
reset_stub
I="$(new_inbox vmismatch-quiet)"
start "$I" "$WORK/vmismatch-quiet.out" --workers "N1.md"
wait_hb "$I" || fail "(vmismatch) no baseline heartbeat"
sed -i 's/ denials=none/ vmismatch=? denials=none/' "$STUB/tick.line"  # gnu-ok: Linux-only kit
wait_exit "$WPID"
check "(vmismatch) a failed audit read (?) keeps waiting" "running" "$rc"
sed -i 's/ vmismatch=?/ vmismatch=0/' "$STUB/tick.line"  # gnu-ok: Linux-only kit
wait_exit "$WPID"
check "(vmismatch) a clean count (0) keeps waiting" "running" "$rc"
sed -i 's/ vmismatch=0/ vmismatch=2/' "$STUB/tick.line"  # gnu-ok: Linux-only kit
wait_exit "$WPID"
check "(vmismatch) a positive count ends the wait" "0" "$rc"
check "(vmismatch) the wake names vmismatch" "WAKE tick changed=vmismatch usage=PROCEED" "$(head -n1 "$WORK/vmismatch-quiet.out")"
if [ "$rc" = running ]; then stop_waiter "$WPID"; fi
start "$I" "$WORK/vmismatch-blip.out" --workers "N1.md"
wait_hb "$I" || fail "(vmismatch) no re-armed heartbeat"
sed -i 's/ vmismatch=2/ vmismatch=?/' "$STUB/tick.line"  # gnu-ok: Linux-only kit
wait_exit "$WPID"
check "(vmismatch) a failed read after a positive count keeps waiting" "running" "$rc"
if [ "$rc" = running ]; then stop_waiter "$WPID"; fi
if [ "${1:-}" = --worktree-ceiling-only ]; then
    printf '\n%d failure(s)\n' "$fails"
    [ "$fails" -eq 0 ]; exit $?
fi

mw_tick() {
    local tails="$1" extra="${2:-}"
    tick_line "N1:FRESH" "ok"
    sed -i "s/ tails=N1:LIVE/ tails=$tails/; s/\$/${extra:+ $extra}/" "$STUB/tick.line"  # gnu-ok: Linux-only kit
}
cat > "$STUB/mw-dispatch.sh" <<'EOF'
#!/usr/bin/env bash
case " $* " in
    *" --priority-pool-only "*)
        printf '# pool=0/7,LOW\nPOOL-EMPTY\n'
        case " $* " in *" --dispositions "*) [ ! -f "$STUB/mw-dispositions" ] || cat "$STUB/mw-dispositions" ;; esac ;;
esac
EOF
printf '#!/usr/bin/env bash\ncat > /dev/null\nexit 0\n' > "$STUB/mw-we.sh"
export CHIEF_WAIT_WORKER_EVENT="$STUB/mw-we.sh"
reset_stub
mkdir -p "$WORK/mw"
MB="$WORK/mw/HIMMEL-10747-BN3a-t3-lanes-2026-11-23.md"
printf '# worker\n\n## Results\n- 19:00 FINDING — merge message shape\n- 19:05 RESOLVED — ruling received\n' > "$MB"
MLB=HIMMEL-10747-BN3a-t3-lanes-2026-11-23
MM="$WORK/mw/chief.fleet.json"; printf '{"schema":1,"workers":[{"doc":"%s","label":"%s"}]}\n' "$MB" "$MLB" > "$MM"
I="$(new_inbox mw)"
rm -f "$STUB/mw-dispositions"
mw_tick "$MLB:RESOLVED"
CHIEF_WAIT_DISPATCH="$STUB/mw-dispatch.sh" CHIEF_WAIT_UNDERFILL_REPOOL_SEC=0 start "$I" "$WORK/mw1.out" --workers-from "$MM"
wait_hb "$I" || fail "(10901-1) no baseline heartbeat"
printf -- '- 19:16 BLOCKED merge-message-shape — the gate refuses the merge message\n' >> "$MB"
printf '# disposition HIMMEL-16 classification BLOCKED: needs slicing\n' > "$STUB/mw-dispositions"
mw_tick "$MLB:BLOCKED"
wait_exit "$WPID"
check "(10901-1) a BLOCKED on the same sample as a pool-unresolved change: the block names both" \
    "0|1|1" "$rc|$(grep -c '^WAKE pool-unresolved' "$WORK/mw1.out")|$(grep -cx "WAKE worker-blocked $MLB" "$WORK/mw1.out")"
check "(10901-1) and records the BLOCKED as named" "1" "$(grep -c "^$MLB BLOCKED " "$I.wait.markerwoke" 2>/dev/null)"
[ "$rc" = running ] && stop_waiter "$WPID"
rm -f "$STUB/mw-dispositions"
I="$(new_inbox mw2)"
mw_tick "$MLB:BLOCKED"
start "$I" "$WORK/mw2.out" --workers-from "$MM"
wait_exit "$WPID"
check "(10901-2) setup: a baseline arm names the BLOCKED and saves it in the key" "0|1" "$rc|$(grep -cx "WAKE worker-blocked $MLB" "$WORK/mw2.out")"
[ "$rc" = running ] && stop_waiter "$WPID"
rm -f "$I.wait.markerwoke"
mw_tick "$MLB:BLOCKED" "doctor=C53"
start "$I" "$WORK/mw3.out" --workers-from "$MM"
wait_exit "$WPID"
check "(10901-2) a re-arm with the BLOCKED in the saved key and never named: the doctor wake names it" \
    "0|1|1" "$rc|$(grep -c '^WAKE doctor' "$WORK/mw3.out")|$(grep -cx "WAKE worker-blocked $MLB" "$WORK/mw3.out")"
[ "$rc" = running ] && stop_waiter "$WPID"
mw_tick "$MLB:BLOCKED" "doctor=C53,C54"
start "$I" "$WORK/mw4.out" --workers-from "$MM"
wait_exit "$WPID"
check "(10901-2) once named, the next wake carries no worker-blocked line" \
    "0|1|0" "$rc|$(grep -c '^WAKE doctor' "$WORK/mw4.out")|$(grep -c '^WAKE worker-blocked' "$WORK/mw4.out")"
[ "$rc" = running ] && stop_waiter "$WPID"
start "$I" "$WORK/mw5.out" --workers-from "$MM"
wait_exit "$WPID"
check "(10901-2) and a quiet re-arm wakes nothing" "running|" "$rc|$(cat "$WORK/mw5.out")"
[ "$rc" = running ] && stop_waiter "$WPID"
MO="$WORK/mw/HIMMEL-10257-BL1a-owed-2026-11-23.md"; MR="${MO%.md}-RESUME.md"
MX="$WORK/mw/HIMMEL-10464-BH4a-gone-2026-11-23-RESUME.md"
printf '# RESUME brief\n' > "$MR"; touch -d '1 hour ago' "$MR"  # gnu-ok: Linux-only kit
printf '# worker\n\n## Results\n- 18:40 LIVE — judge round\n- 19:31 READY 5793 %s GREEN\n' "$(printf 'b%.0s' $(seq 40))" > "$MO"
MRL=HIMMEL-10257-BL1a-owed-2026-11-23-RESUME; MXL=HIMMEL-10464-BH4a-gone-2026-11-23-RESUME
printf '{"schema":1,"workers":[{"doc":"%s","label":"%s"},{"doc":"%s","label":"%s"},{"doc":"%s","label":"%s"}]}\n' \
    "$MB" "$MLB" "$MR" "$MRL" "$MX" "$MXL" > "$MM"
mw_tick "$MLB:BLOCKED,$MRL:?,$MXL:?"
start "$I" "$WORK/mw6.out" --workers-from "$MM"
wait_exit "$WPID"
check "(10901-3) a row naming a missing doc wakes worker-doc-missing" "0|1" "$rc|$(grep -cx "WAKE worker-doc-missing $MXL $MX" "$WORK/mw6.out")"
check "(10901-3) a markerless RESUME row whose original holds a newer marker names the doc it writes" \
    "1" "$(grep -cx "WAKE worker-doc-missing $MRL $MR writes=$MO" "$WORK/mw6.out")"
[ "$rc" = running ] && stop_waiter "$WPID"
start "$I" "$WORK/mw7.out" --workers-from "$MM"
wait_exit "$WPID"
check "(10901-3) each path wakes once" "running|" "$rc|$(cat "$WORK/mw7.out")"
[ "$rc" = running ] && stop_waiter "$WPID"
MQ="$WORK/mw/HIMMEL-10747-BN3b-t3-lanes-2026-11-23.md"; MQL=HIMMEL-10747-BN3b-t3-lanes-2026-11-23
printf '# worker\n\n## Results\n- 19:30 LIVE — merge forward done\n' > "$MQ"
printf '{"schema":1,"workers":[{"doc":"%s","label":"%s"}]}\n' "$MQ" "$MQL" > "$MM"
I="$(new_inbox mwq)"
mw_tick "$MQL:LIVE"
start "$I" "$WORK/mw8.out" --workers-from "$MM"
wait_hb "$I" || fail "(10901-4) no baseline heartbeat"
printf -- '- 19:40 LIVE PUSH-REQUEST BP :: push the lanes branch\n' >> "$MQ"
wait_exit "$WPID"
check "(10901-4) a LIVE bullet carrying PUSH-REQUEST wakes worker-request" "0|WAKE worker-request $MQL" "$rc|$(grep '^WAKE ' "$WORK/mw8.out")"
[ "$rc" = running ] && stop_waiter "$WPID"
start "$I" "$WORK/mw9.out" --workers-from "$MM"
wait_exit "$WPID"
check "(10901-4) once per bullet" "running|" "$rc|$(cat "$WORK/mw9.out")"
[ "$rc" = running ] && stop_waiter "$WPID"
printf '# worker\n\n## Results\n- 19:30 FINDING — lanes question\n- 19:35 RESOLVED — ruling received\n' > "$MQ"
I="$(new_inbox mwq2)"
mw_tick "$MQL:RESOLVED"
HOUSEKEEPING_DIGEST_SECS=0 start "$I" "$WORK/mw10.out" --workers-from "$MM"
wait_hb "$I" || fail "(10901-5) no baseline heartbeat"
sed "s/ tails=$MQL:RESOLVED/ tails=$MQL:LIVE/" "$STUB/tick.line" > "$STUB/tick.next"
printf -- '- 19:40 LIVE PUSH-REQUEST BP :: push the lanes branch\n' > "$STUB/tick.add"
printf 'cat "%s" >> "%s"\nmv "%s" "%s"\n' "$STUB/tick.add" "$MQ" "$STUB/tick.next" "$STUB/tick.line" > "$STUB/tick.hook.new"
mv "$STUB/tick.hook.new" "$STUB/tick.hook"
wait_exit "$WPID"
check "(10901-5) a request that arrives with a tails move wakes the tick change and worker-request" \
    "0|1|1" "$rc|$(grep -c '^WAKE tick changed=tails' "$WORK/mw10.out")|$(grep -cx "WAKE worker-request $MQL" "$WORK/mw10.out")"
[ "$rc" = running ] && stop_waiter "$WPID"
unset CHIEF_WAIT_WORKER_EVENT

dr_tick() {
    tick_line "N1:FRESH" "ok"
    sed -i "s/ denials=none/ drift=$1 denials=none/" "$STUB/tick.line"  # gnu-ok: Linux-only kit
}
dr_alive() { sleep 3; if kill -0 "$WPID" 2>/dev/null; then echo running; else echo exited; fi; }
export TICK_STATE_DIR="$WORK/dr-state"; mkdir -p "$TICK_STATE_DIR"
cat > "$STUB/gh-heads.sh" <<'EOF'
#!/usr/bin/env bash
[ ! -f "$STUB/gh.hang" ] || exec sleep 60
cat "$STUB/gh.heads" 2>/dev/null
[ ! -f "$STUB/gh.fail" ] || exit 1
exit 0
EOF
chmod +x "$STUB/gh-heads.sh"
export CHIEF_WAIT_GH="$STUB/gh-heads.sh"
reset_stub
dr_tick '?'
I="$(new_inbox dr1)"
start "$I" "$WORK/dr1.out"
wait_hb "$I" || fail "(dr1) no baseline heartbeat"
check "(dr1) drift=? wakes nothing" "running" "$(dr_alive)"
dr_tick 0
check "(dr2) drift=0 wakes nothing" "running" "$(dr_alive)"
dr_tick 2
wait_exit "$WPID"
check "(dr3) an actionable count wakes with the count" "0|WAKE drift-actionable 2" "$rc|$(head -n1 "$WORK/dr1.out")"
check "(dr3) the tick line follows" "1" "$(grep -c '^TICK ' "$WORK/dr1.out")"
start "$I" "$WORK/dr4.out"
wait_hb "$I" || fail "(dr4) no baseline heartbeat"
check "(dr4) a same-day repeat wakes nothing" "running" "$(dr_alive)"
dr_tick 5
check "(dr4) a larger count the same day still wakes nothing" "running" "$(dr_alive)"
stop_waiter "$WPID"
dr_tick 3
I="$(new_inbox dr5)"
rm -rf "$TICK_STATE_DIR"; mkdir -p "$TICK_STATE_DIR"
dr_bslug() { local b; b="$(realpath -m -- "$1")"; b="${b%/consoles/*}"; printf '%s-%s' "${b//[!A-Za-z0-9._-]/_}" "$(printf '%s' "$b" | cksum | cut -d' ' -f1)"; }
mkdir "$TICK_STATE_DIR/drift-wake-$(dr_bslug "$I").$(date -u +%F)"
start "$I" "$WORK/dr5.out"
wait_hb "$I" || fail "(dr5) no baseline heartbeat"
check "(dr5) a day marker that cannot be claimed wakes nothing" "running" "$(dr_alive)"
stop_waiter "$WPID"

rm -rf "$TICK_STATE_DIR"; mkdir -p "$TICK_STATE_DIR" "$WORK/dr6/consoles"
: > "$WORK/dr6/consoles/chief-a.md"; : > "$WORK/dr6/consoles/chief-b.md"
dr_tick 2
start "$WORK/dr6/consoles/chief-a.md" "$WORK/dr6a.out"
wait_exit "$WPID"
check "(dr6) the first chief's waiter wakes" "0|WAKE drift-actionable 2" "$rc|$(head -n1 "$WORK/dr6a.out")"
start "$WORK/dr6/consoles/chief-b.md" "$WORK/dr6b.out"
wait_hb "$WORK/dr6/consoles/chief-b.md" || fail "(dr6) no baseline heartbeat"
check "(dr6) a second chief inbox in the bucket wakes nothing the same day" "running" "$(dr_alive)"
stop_waiter "$WPID"
check "(dr6) one claim file for the bucket and day" "1" "$(find "$TICK_STATE_DIR" -maxdepth 1 -name 'drift-wake-*' | grep -c .)"
mkdir -p "$WORK/dr6x/consoles"; : > "$WORK/dr6x/consoles/chief-c.md"
start "$WORK/dr6x/consoles/chief-c.md" "$WORK/dr6c.out"
wait_exit "$WPID"
check "(dr6) another bucket claims its own day" "0|WAKE drift-actionable 2" "$rc|$(head -n1 "$WORK/dr6c.out")"
mkdir -p "$WORK/dr8/a/b/consoles" "$WORK/dr8/a_b/consoles"; : > "$WORK/dr8/a/b/consoles/c.md"; : > "$WORK/dr8/a_b/consoles/c.md"
rm -rf "$TICK_STATE_DIR"; mkdir -p "$TICK_STATE_DIR"
start "$WORK/dr8/a/b/consoles/c.md" "$WORK/dr8a.out"
wait_exit "$WPID"
check "(dr8) the first of two look-alike buckets wakes" "0|WAKE drift-actionable 2" "$rc|$(head -n1 "$WORK/dr8a.out")"
start "$WORK/dr8/a_b/consoles/c.md" "$WORK/dr8b.out"
wait_exit "$WPID"
check "(dr8) a bucket whose path differs only in punctuation claims its own day" "0|WAKE drift-actionable 2" "$rc|$(head -n1 "$WORK/dr8b.out")"

dr_today="$(date -u +%F)"
dr_set_I_WM_for_fleet() {
    rm -rf "$TICK_STATE_DIR"; mkdir -p "$TICK_STATE_DIR" "$WORK/$1/consoles"; I="$WORK/$1/consoles/c.md"; : > "$I"
    printf '# worker\n\n## Results\n- 09:00 LIVE — started\n' > "$WORK/$1/$2"
    WM="$WORK/$1/chief.fleet.json"; printf '{"schema":1,"workers":[{"doc":"%s/%s","label":"N10995"}]}\n' "$WORK/$1" "$2" > "$WM"
}
reset_stub; dr_tick 2
dr_set_I_WM_for_fleet dr7 "HIMMEL-10995-N10995-drift-4470-$dr_today.md"
start "$I" "$WORK/dr7.out" --workers-from "$WM"
wait_hb "$I" || fail "(dr7) no baseline heartbeat"
check "(dr7) an open drift worker in the manifest holds the wake" "running" "$(dr_alive)"
check "(dr7) the hold says held-by the worker" "drift-actionable 2 held-by N10995" "$(cat "$I.wait.drift.held" 2>/dev/null)"
check "(dr7) a held day is not claimed" "0" "$(find "$TICK_STATE_DIR" -maxdepth 1 -name 'drift-wake-*' | grep -c .)"
stop_waiter "$WPID"
dr_set_I_WM_for_fleet dr7b "HIMMEL-11034-N11034-drift-wake-once-a-day-$dr_today.md"
start "$I" "$WORK/dr7b.out" --workers-from "$WM"
wait_exit "$WPID"
check "(dr7) a worker whose doc only has drift in its slug does not hold the wake" "0|WAKE drift-actionable 2" "$rc|$(head -n1 "$WORK/dr7b.out")"
dr_set_I_WM_for_fleet dr7c "HIMMEL-10995-N10995-drift-4470-2026-01-01.md"
start "$I" "$WORK/dr7c.out" --workers-from "$WM"
wait_exit "$WPID"
check "(dr7) a drift worker of another day does not hold the wake" "0|WAKE drift-actionable 2" "$rc|$(head -n1 "$WORK/dr7c.out")"
rm -rf "$TICK_STATE_DIR"; mkdir -p "$TICK_STATE_DIR"; rm -f "$WORK/dr7/consoles/c.md.wait.drift.held"
printf '#5901 chore/himmel-10995-drift-%s\n' "$dr_today" > "$STUB/gh.heads"
start "$I" "$WORK/dr7d.out"
wait_hb "$I" || fail "(dr7) no baseline heartbeat for the PR hold"
check "(dr7) an open drift PR for today holds the wake" "running" "$(dr_alive)"
check "(dr7) the hold says held-by the PR" "drift-actionable 2 held-by #5901" "$(cat "$I.wait.drift.held" 2>/dev/null)"
stop_waiter "$WPID"
printf '#5902 fix/himmel-11034-drift-wake-once-a-day\n' > "$STUB/gh.heads"
start "$I" "$WORK/dr7e.out"
wait_exit "$WPID"
check "(dr7) an open PR whose branch only has drift in its slug does not hold the wake" "0|WAKE drift-actionable 2" "$rc|$(head -n1 "$WORK/dr7e.out")"
rm -rf "$TICK_STATE_DIR"; mkdir -p "$TICK_STATE_DIR"
I="$(new_inbox dr9)"
printf '#5903 chore/himmel-10995-drift-%s\n' "$dr_today" > "$STUB/gh.heads"; : > "$STUB/gh.fail"
start "$I" "$WORK/dr9.out"
wait_exit "$WPID"
check "(dr9) an open-PR read that fails after printing a drift head still wakes" "0|WAKE drift-actionable 2" "$rc|$(head -n1 "$WORK/dr9.out")"
rm -f "$STUB/gh.fail"
rm -rf "$TICK_STATE_DIR"; mkdir -p "$TICK_STATE_DIR"
I="$(new_inbox dr10)"
: > "$STUB/gh.hang"
start "$I" "$WORK/dr10.out"
wait_exit_for "$WPID" 400
check "(dr10) an open-PR read that hangs past its 20 s bound still wakes" "0|WAKE drift-actionable 2" "$rc|$(head -n1 "$WORK/dr10.out")"
[ "$rc" = running ] && stop_waiter "$WPID"
rm -f "$STUB/gh.hang" "$STUB/gh.heads"
unset TICK_STATE_DIR CHIEF_WAIT_GH

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
