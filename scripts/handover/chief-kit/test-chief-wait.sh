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
# Split in two so each half runs well under the 600 s shard watchdog: this file
# holds the cases up to (y4); test-chief-wait-b.sh holds (vmrun) onward.
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

# tick_line <workers> <board> [hb] [prs] [or] [fails]: a tick line whose action fields are set.
tick_line() {
    printf 'TICK 03:00 hb=%s workers=%s livestate=ok procs=2 models=x ceiling=ok atq=0 suites=0alive/0dead prs=%s bank=5h8/wk15/codex=? fill=40 tails=N1:LIVE inbox=none tick=UNKNOWN fleet=3/15 capacity=ok gql=4000/04:00 orphans=none nonces=ok legset=ok board=%s denials=none or=%s fails=%s\n' \
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
reset_stub

tl_line() {
    local inbox="$1" n=0; shift
    start "$inbox" "$WORK/tl.out" "$@"
    while [ "$n" -lt 80 ] && ! grep -q . "$inbox.wait.ticklog" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
    kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
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
if [ "$rc" = running ]; then kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; fi
# the state is unchanged: a re-arm repeats neither the wake, the page nor the bullet
CHIEF_WAIT_WORKER_SILENT_MIN=30 timeout 3 bash "$WAIT" "$I" --doc "$WD" --workers-from "$WM" > "$WORK/ws2.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(ws2) a re-arm on an unchanged silent worker keeps waiting" "124" "$rc"
check "(ws2) and prints no worker-silent line" "0" "$(grep -c 'worker-silent' "$WORK/ws2.out")"
check "(ws2) and pages nothing more" "1" "$(ws_pages)"
check "(ws2) and writes no second bullet" "1" "$(ws_bullets)"
# the worker wrote, then went quiet again: the state moved, so it is a new silence
touch -d "90 minutes ago" "$WL"  # gnu-ok: Linux-only kit
CHIEF_WAIT_WORKER_SILENT_MIN=30 start "$I" "$WORK/ws2b.out" --doc "$WD" --workers-from "$WM"
wait_exit "$WPID"
check "(ws2b) a worker that wrote and went quiet again wakes again" "WAKE worker-silent N1 signal=capped-waker" "$(head -n1 "$WORK/ws2b.out" | cut -d' ' -f1-4)"
check "(ws2b) with a second alert" "2" "$(ws_pages)"
if [ "$rc" = running ]; then kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; fi

# negative: a Results bullet inside the bound keeps the worker out of the silent set
reset_stub
ws_fleet ws3 "1 minute ago"
ws_tick "N1:capped"
CHIEF_WAIT_WORKER_SILENT_MIN=30 timeout 3 bash "$WAIT" "$I" --doc "$WD" --workers-from "$WM" > "$WORK/ws3.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(ws3) a fresh bullet inside the bound keeps waiting" "124" "$rc"
check "(ws3) and prints no worker-silent wake" "0" "$(grep -c 'worker-silent' "$WORK/ws3.out")"
check "(ws3) and sends no alert" "0" "$(ws_pages)"
# negative: a quiet doc with a waker that is not capped is a worker waiting, not a silent one
reset_stub
ws_fleet ws4 "2 hours ago"
ws_tick
CHIEF_WAIT_WORKER_SILENT_MIN=30 timeout 3 bash "$WAIT" "$I" --doc "$WD" --workers-from "$WM" > "$WORK/ws4.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(ws4) a quiet doc with no capped waker keeps waiting" "124" "$rc"
check "(ws4) and prints no worker-silent wake" "0" "$(grep -c 'worker-silent' "$WORK/ws4.out")"
# the bound is a named, overridable value: 20 quiet minutes sit inside the default and outside a 10-minute bound
reset_stub
ws_fleet ws5 "20 minutes ago"
ws_tick "N1:capped"
timeout 3 bash "$WAIT" "$I" --doc "$WD" --workers-from "$WM" > "$WORK/ws5a.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(ws5) 20 quiet minutes are inside the default bound" "0" "$(grep -c 'worker-silent' "$WORK/ws5a.out")"
CHIEF_WAIT_WORKER_SILENT_MIN=10 start "$I" "$WORK/ws5b.out" --doc "$WD" --workers-from "$WM"
wait_exit "$WPID"
check "(ws5) CHIEF_WAIT_WORKER_SILENT_MIN=10 makes them a silent worker" "WAKE worker-silent N1 signal=capped-waker" "$(head -n1 "$WORK/ws5b.out" | cut -d' ' -f1-4)"
if [ "$rc" = running ]; then kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; fi
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
if [ "$rc" = running ]; then kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; fi
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
    if [ "$rc" = running ]; then kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; fi
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
if [ "$rc" = running ]; then kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; fi
timeout 3 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/wt-ceiling-rearm.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit
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
if [ "$rc" = running ]; then kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; fi
timeout 3 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/cap-field-rearm.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit
check "(cap) an unchanged cap keeps waiting" "124" "$rc"
check "(cap) an unchanged cap does not re-wake" "" "$(cat "$WORK/cap-field-rearm.out")"
start "$I" "$WORK/cap-field-move.out" --workers "N1.md"
wait_hb "$I" || fail "(cap) no re-armed heartbeat"
sed -i 's/ residual-cap=v1.1.3:16/ residual-cap=v1.1.3:17/' "$STUB/tick.line"  # gnu-ok: Linux-only kit
wait_exit "$WPID"
check "(cap) a moved cap count ends the wait" "0" "$rc"
check "(cap) the moved count wakes as cap" "WAKE tick changed=residual-cap usage=PROCEED" "$(head -n1 "$WORK/cap-field-move.out")"
if [ "$rc" = running ]; then kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; fi
start "$I" "$WORK/cap-field-gone.out" --workers "N1.md"
wait_hb "$I" || fail "(cap) no cleared heartbeat"
sed -i 's/ residual-cap=v1.1.3:17//' "$STUB/tick.line"  # gnu-ok: Linux-only kit
wait_exit "$WPID"
check "(cap) a cap that goes away keeps waiting" "running" "$rc"
if [ "$rc" = running ]; then kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; fi
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
if [ "$rc" = running ]; then kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; fi
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
if [ "$rc" = running ]; then kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; fi
sed -i 's/ residual-cap=v1.1.3:16 open=v1.1.3:41/ residual-cap=v1.1.3:17 open=v1.1.3:42/' "$STUB/tick.line"  # gnu-ok: Linux-only kit
start "$I" "$WORK/cap-open-both.out" --workers "N1.md"
wait_exit "$WPID"
check "(open) both fields moving at once wake as both" "WAKE tick changed=residual-cap,open usage=PROCEED" "$(head -n1 "$WORK/cap-open-both.out")"
if [ "$rc" = running ]; then kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; fi
sed -i 's/ open=v1.1.3:42/ open=?/' "$STUB/tick.line"  # gnu-ok: Linux-only kit
start "$I" "$WORK/cap-open-cut.out" --workers "N1.md"
wait_exit "$WPID"
check "(open) open=? (a cut read) keeps the saved count and wakes nothing" "running" "$rc"
if [ "$rc" = running ]; then kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; fi
sed -i 's/ residual-cap=v1.1.3:17 open=?/ residual-cap=v1.1.3:17 open=v1.1.3:42/' "$STUB/tick.line"  # gnu-ok: Linux-only kit
timeout 3 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/cap-open-same.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit
check "(open) the saved count returning is no change" "124" "$rc"
sed -i 's/residual-cap=/cap=/' "$I.wait.state"  # gnu-ok: Linux-only kit
timeout 3 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/cap-open-migrate.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit
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
if [ "$rc" = running ]; then kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; fi
timeout 3 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/hreg-rearm.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit
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
if [ "$rc" = running ]; then kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; fi

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
if [ "$rc" = running ]; then kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; fi
HOME="$HA_HOME" start "$I" "$WORK/hask2.out" --workers "N1.md"
wait_hb "$I" || fail "(hask) no re-armed heartbeat"
sleep 3
check "(hask) a re-armed waiter neither wakes nor pages again for the same ask" "running|0" "$(kill -0 "$WPID" 2>/dev/null && echo running)|$(ha_pages)"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
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
    kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
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
if [ "$rc" = running ]; then kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; fi
start "$I" "$WORK/vmismatch-blip.out" --workers "N1.md"
wait_hb "$I" || fail "(vmismatch) no re-armed heartbeat"
sed -i 's/ vmismatch=2/ vmismatch=?/' "$STUB/tick.line"  # gnu-ok: Linux-only kit
wait_exit "$WPID"
check "(vmismatch) a failed read after a positive count keeps waiting" "running" "$rc"
if [ "$rc" = running ]; then kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; fi
if [ "${1:-}" = --worktree-ceiling-only ]; then
    printf '\n%d failure(s)\n' "$fails"
    [ "$fails" -eq 0 ]; exit $?
fi

# --- (a) idle: no event, no change -> no output, still waiting -------------
reset_stub
I="$(new_inbox a)"
timeout 4 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/a.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(a) an idle window with no event emits nothing" "" "$(cat "$WORK/a.out")"
check "(a) an idle waiter is still waiting when the window closes (rc 124)" "124" "$rc"
check "(a) the idle waiter wrote a heartbeat" "yes" "$(grep -q '^hb=[0-9]* pid=[0-9]* ' "$I.wait" && echo yes)"

# --- (a2) a re-arm on an unchanged state emits nothing either --------------
timeout 3 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/a2.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(a2) a re-arm with nothing changed emits nothing" "" "$(cat "$WORK/a2.out")"
check "(a2) and is still waiting when the window closes (rc 124)" "124" "$rc"

# --- (b) a real change -> exactly one WAKE block, then exit 0 --------------
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
timeout 3 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/b2.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(b) the re-arm after the wake does not wake again for the same change" "" "$(cat "$WORK/b2.out")"
check "(b) the re-arm is still waiting when the window closes (rc 124)" "124" "$rc"

# --- (hm) handover mode: <inbox>.handover stops tick wakes ---
# chief.sh next writes the marker once the successor validated; the outgoing
# chief's waiter then takes no tick/bank/page work, but Telegram still wakes.
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

# --- (hs) a STALE handover marker is ignored (a failed or never-run launch must
# not leave the outgoing chief unmonitored for good) ---
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

# --- (hr) the outgoing chief's relay-on-live wake carries its whole tail ---
# Lock status and relay-batch are stubbed (lock rc 11 = the successor's lock is held fresh).
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

# --- (hr2) the one muted re-arm resumes once the marker is stale: a successor that died before LIVE
# must not leave the outgoing chief without a watcher ---
reset_stub
I="$(new_inbox hr2)"
printf 'S2\n' > "$I.handover"
touch -d '3 hours ago' "$I.handover"  # gnu-ok: Linux-only kit
start "$I" "$WORK/hr2.out" --workers "N1.md"
wait_hb "$I" || fail "(hr2) no baseline heartbeat"
tick_line "N1:FREE" "ok"
wait_exit "$WPID"
check "(hr2) a re-armed waiter whose handover marker is stale wakes on a tick change" "WAKE tick changed=workers usage=PROCEED" "$(head -n1 "$WORK/hr2.out")"

# --- (hso) the retired name CONSOLE_WAIT_TICK never names the tick command --- # old-term-ok
reset_stub
I="$(new_inbox hso)"
# shellcheck disable=SC2016  # $STUB is meant to expand in the generated stub, not here
printf '#!/usr/bin/env bash\ntouch "%s/hso.ticked"\ncat "$STUB/tick.line"\n' "$WORK" > "$STUB/tick-old.sh"
CONSOLE_WAIT_TICK="$STUB/tick-old.sh" bash "$WAIT" "$I" --workers "N1.md" > "$WORK/hso.out" 2>"$WORK/hso.out.err" & # old-term-ok
WPID=$!
wait_hb "$I" || fail "(hso) no baseline heartbeat"
check "(hso) the retired CONSOLE_WAIT_TICK is never run" "no" "$([ -e "$WORK/hso.ticked" ] && echo yes || echo no)" # old-term-ok
kill "$WPID" 2>/dev/null

# --- (b3724) a denials= class change wakes, naming denials ---
reset_stub
I="$(new_inbox b3724)"
start "$I" "$WORK/b3724.out" --workers "N1.md"
wait_hb "$I" || fail "(b3724) no baseline heartbeat"
sed -i 's/denials=none/denials=N1:1:SHIP-STEP/' "$STUB/tick.line"  # gnu-ok: Linux-only kit
wait_exit "$WPID"
check "(b3724) a denials= class change ends the wait with rc 0" "0" "$rc"
check "(b3724) the wake names denials" "WAKE tick changed=denials usage=PROCEED" "$(head -n1 "$WORK/b3724.out")"

# --- (b3724x) a denial EXPIRING out of tick.sh's window is not a wake ------
# One denial wakes the chief once (above); the same row aging out 30 min
# later moves denials= to none (or lowers a count) and must not wake it again.
denials_expiry() { # <case> <from> <to>
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
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
denials_expiry b3724x2 'N1:2:REPEAT' 'N1:1'
check "(b3724x) a count falling as one row expires does not wake" "running" "$rc"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
denials_expiry b3724x3 'N1:1' 'N1:2:REPEAT'
check "(b3724x) a count rising still wakes" "0" "$rc"
check "(b3724x) and names denials" "WAKE tick changed=denials usage=PROCEED" "$(head -n1 "$WORK/b3724x3.out")"
[ "$rc" = running ] && { kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; }
denials_expiry b3724x4 'N1:1' 'N1:1,N2:1'
check "(b3724x) a second worker's denial wakes" "0" "$rc"
[ "$rc" = running ] && { kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; }
# After an expiry the saved key follows it, so the NEXT denial wakes again.
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
[ "$rc" = running ] && { kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; }

# --- (c) noise fields do not wake: hb, board age, prs unchanged ------------
reset_stub
tick_line "N1:FRESH" "STALE:5m" "1m" '#10' '7.50:key-limit_remaining'
I="$(new_inbox c)"
start "$I" "$WORK/c.out" --workers "N1.md"
wait_hb "$I" || fail "(c) no baseline heartbeat"
tick_line "N1:FRESH" "STALE:9m" "7m" '#10' '0.00:key-limit_remaining'
wait_exit "$WPID"
check "(c) heartbeat, board age or exhausted OpenRouter credit does not wake" "running" "$rc"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
check "(c) a TERM is logged as the exit reason" "yes" "$(grep -q 'exit=signal-TERM' "$I.wait" && echo yes)"

# --- (c4670) fails= is advisory: a new failure class or recur wakes nothing -
reset_stub
I="$(new_inbox c4670)"
start "$I" "$WORK/c4670.out" --workers "N1.md"
wait_hb "$I" || fail "(c4670) no baseline heartbeat"
tick_line "N1:FRESH" "ok" "1m" '#10' 'skip' '3/2@denied/guard-a*2!1'
wait_exit "$WPID"
check "(c4670) a fails= change does not wake" "running" "$rc"
[ "$rc" = running ] && { kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; }

# --- (d) a one-sample blip (a failed gh read) does not wake -----------------
reset_stub
I="$(new_inbox d)"
start "$I" "$WORK/d.out" --workers "N1.md"
wait_hb "$I" || fail "(d) no baseline heartbeat"
sed 's/prs=#10/prs=none/' "$STUB/tick.line" > "$STUB/tick.blip"
wait_exit "$WPID"
check "(d) a change seen on one sample only does not wake" "running" "$rc"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# --- (d2) a key that changes on every sample still wakes -------------------
# Measured on the live repo: the open-PR set moved between every
# 180 s sample, so "the same new key twice" never held and the waiter stayed
# silent through real changes. Two consecutive samples off the saved key wake.
reset_stub
I="$(new_inbox d2)"
HOUSEKEEPING_DIGEST_SECS=0 start "$I" "$WORK/d2.out" --workers "N1.md"
wait_hb "$I" || fail "(d2) no baseline heartbeat"
printf '0\n' > "$STUB/tick.churn"
wait_exit "$WPID"
check "(d2) a key that differs from the saved one on every sample wakes" "0" "$rc"
check "(d2) the wake names prs" "WAKE tick changed=prs usage=PROCEED" "$(head -n1 "$WORK/d2.out")"
[ "$rc" = running ] && { kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; }

# --- (e) a bank verdict change wakes, naming bank --------------------------
reset_stub
I="$(new_inbox e)"
start "$I" "$WORK/e.out" --workers "N1.md"
wait_hb "$I" || fail "(e) no baseline heartbeat"
printf 'SKIPPED-BANK\n' > "$STUB/bank"
wait_exit "$WPID"
check "(e) a bank verdict change ends the wait" "0" "$rc"
check "(e) the wake names bank and carries the new verdict" "WAKE tick changed=usage usage=SKIPPED-BANK" "$(head -n1 "$WORK/e.out")"

# --- (f) a failing tick is never a change ----------------------------------
reset_stub
I="$(new_inbox f)"
start "$I" "$WORK/f.out" --workers "N1.md"
wait_hb "$I" || fail "(f) no baseline heartbeat"
printf '1\n' > "$STUB/tick.rc"
wait_exit "$WPID"
check "(f) a failing tick.sh does not wake" "running" "$rc"
check "(f) the heartbeat records the failed tick" "yes" "$(grep -q 'tick=fail' "$I.wait" && echo yes)"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# --- (f2) an empty bank read is a failed sample, never a change ------------
reset_stub
I="$(new_inbox f2)"
start "$I" "$WORK/f2.out" --workers "N1.md"
wait_hb "$I" || fail "(f2) no baseline heartbeat"
: > "$STUB/bank"
wait_exit "$WPID"
check "(f2) an empty bank read does not wake" "running" "$rc"
check "(f2) the heartbeat records the failed sample" "yes" "$(grep -q 'tick=fail' "$I.wait" && echo yes)"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# --- (f3) a bank read that is not a verdict token is a failed sample --------
reset_stub
I="$(new_inbox f3)"
start "$I" "$WORK/f3.out" --workers "N1.md"
wait_hb "$I" || fail "(f3) no baseline heartbeat"
printf 'Traceback: boom\n' > "$STUB/bank"
wait_exit "$WPID"
check "(f3) a non-token bank line does not wake" "running" "$rc"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# --- (f4) a failure streak wakes once; the re-arm stays quiet until a success -
reset_stub
I="$(new_inbox f4)"
HOUSEKEEPING_DIGEST_SECS=0 CHIEF_WAIT_FAIL_WAKE=3 start "$I" "$WORK/f4.out" --workers "N1.md"
wait_hb "$I" || fail "(f4) no baseline heartbeat"
printf '1\n' > "$STUB/tick.rc"
wait_exit "$WPID"
check "(f4) a streak of failed samples ends the wait" "0" "$rc"
[ "$rc" = running ] && { kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; }
check "(f4) the wake names the failure streak and the failing step" "WAKE tick-fail samples=3 step=tick-exit:1" "$(head -n1 "$WORK/f4.out")"
HOUSEKEEPING_DIGEST_SECS=0 CHIEF_WAIT_FAIL_WAKE=3 timeout 6 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/f4b.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(f4) the re-arm during the same streak runs silent" "124" "$rc"
check "(f4) the re-arm during the same streak prints nothing" "" "$(cat "$WORK/f4b.out")"
rm -f "$STUB/tick.rc"
HOUSEKEEPING_DIGEST_SECS=0 CHIEF_WAIT_FAIL_WAKE=3 timeout 3 bash "$WAIT" "$I" --workers "N1.md" >/dev/null 2>&1  # gnu-ok: Linux-only kit; pipefail-ok: none set
printf '1\n' > "$STUB/tick.rc"
HOUSEKEEPING_DIGEST_SECS=0 CHIEF_WAIT_FAIL_WAKE=3 timeout 8 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/f4c.out" 2>/dev/null  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(f4) a new streak after a success wakes again" "WAKE tick-fail samples=3 step=tick-exit:1" "$(head -n1 "$WORK/f4c.out")"

# --- (8934) look-only kinds (tick-fail, unowned-prs, a prs-only tick change) join the
# digest and ride the next real wake; READY, BLOCKED and Telegram still wake at once ---
reset_stub
I="$(new_inbox d1)"
CHIEF_WAIT_FAIL_WAKE=2 start "$I" "$WORK/d1.out" --workers "N1.md"
wait_hb "$I" || fail "(8934) no baseline heartbeat"
printf '1\n' > "$STUB/tick.rc"
sleep 4
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
check "(8934) a tick-fail streak does not wake, it joins the digest" "0:1" "$(grep -c '^WAKE ' "$WORK/d1.out"):$(grep -c '^tick-fail samples=2 step=tick-exit:1' "$I.wait.housekeeping" 2>/dev/null)"

reset_stub
sed -i 's/ bank=/ unowned-prs=#2575:12m bank=/' "$STUB/tick.line"  # gnu-ok: Linux-only kit
I="$(new_inbox d2)"
timeout 4 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/d2.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit
check "(8934) the first sight of a young unowned PR does not wake, it joins the digest" "124:0:1" "$rc:$(grep -c '^WAKE ' "$WORK/d2.out"):$(grep -c '^unowned-prs #2575:12m' "$I.wait.housekeeping" 2>/dev/null)"

reset_stub
sed -i 's/ bank=/ unowned-prs=#4946:70m,#4891:957m,#4999:5m bank=/' "$STUB/tick.line"  # gnu-ok: Linux-only kit
I="$(new_inbox u1)"
timeout 6 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/u1.out" 2>/dev/null; rc=$?
check "(9599) an unowned PR older than 30 m wakes, exit 0" "0" "$rc"
check "(9599) the wake names each aged PR and not the young one" "WAKE unowned-pr 4946,4891" "$(head -n1 "$WORK/u1.out")"
timeout 4 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/u2.out" 2>/dev/null; rc=$?
check "(9599) the same aged set does not re-wake inside the window" "124:0" "$rc:$(grep -c '^WAKE unowned-pr' "$WORK/u2.out")"
sed -i 's/unowned-prs=[^ ]* bank=/unowned-prs=#4999:5m bank=/' "$STUB/tick.line"  # gnu-ok: Linux-only kit
timeout 4 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/u3.out" 2>/dev/null
check "(9599) a sample with no aged PR clears the aged marker" "no" "$([ -e "$I.wait.unowned-aged" ] && echo yes || echo no)"

reset_stub
I="$(new_inbox d3)"
start "$I" "$WORK/d3.out" --workers "N1.md"
wait_hb "$I" || fail "(8934) no baseline heartbeat"
sed -i 's/prs=#10/prs=#10,#11/' "$STUB/tick.line"  # gnu-ok: Linux-only kit
sleep 4
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
check "(8934) a prs-only tick change does not wake, it joins the digest" "0:1" "$(grep -c '^WAKE ' "$WORK/d3.out"):$(grep -c '^tick changed=prs ' "$I.wait.housekeeping" 2>/dev/null)"

# The next real wake carries the buffered look-only lines and drops them from the buffer; other
# housekeeping (a board-stale line) stays queued for its own window.
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

# Controls: a BLOCKED or READY worker event and a Telegram line wake at once with the digest on.
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

# A wake whose stdout cannot be written keeps the look-only buffer and the digest queued: both
# flushes guard their write (`|| return 1`), so nothing is dropped that was never printed.
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

# --- (g) a Telegram line wakes at once; a re-arm replays nothing -----------
reset_stub
I="$(new_inbox g)"
start "$I" "$WORK/g.out" --workers "N1.md"
wait_hb "$I" || fail "(g) no baseline heartbeat"
printf -- '- 03:10 [telegram from=1 chat=2] hello\n' >> "$I"
wait_exit "$WPID"
check "(g) an inbox line ends the wait with rc 0" "0" "$rc"
check "(g) the wake is a telegram block with the line" "$(printf 'WAKE telegram\n- 03:10 [telegram from=1 chat=2] hello')" "$(cat "$WORK/g.out")"
timeout 3 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/g2.out" 2>/dev/null  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(g) a re-arm does not replay a delivered line" "" "$(cat "$WORK/g2.out")"

# --- (h) a line queued while no waiter ran is delivered on arm -------------
printf -- '- 03:20 [telegram from=1 chat=2] queued\n' >> "$I"
timeout 3 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/h.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(h) a line queued between arms is delivered by the next arm" "$(printf 'WAKE telegram\n- 03:20 [telegram from=1 chat=2] queued')" "$(cat "$WORK/h.out")"
check "(h) and the arm exits 0" "0" "$rc"

# --- (i) a second waiter on the same inbox is refused ----------------------
reset_stub
I="$(new_inbox i)"
start "$I" "$WORK/i.out" --workers "N1.md"
wait_hb "$I" || fail "(i) no baseline heartbeat"
bash "$WAIT" "$I" --workers "N1.md" > "$WORK/i2.out" 2>&1; rc=$?
check "(i) a second waiter on a live one is refused with rc 3" "3" "$rc"
check "(i) the refusal names the live pid" "yes" "$(grep -q "pid $WPID" "$WORK/i2.out" && echo yes)"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# --- (j) new tick args re-baseline silently --------------------------------
reset_stub
I="$(new_inbox j)"
timeout 2 bash "$WAIT" "$I" --workers "N1.md" >/dev/null 2>&1; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(j) the first arm ran until the timeout" "124" "$rc"
base1="$(cat "$I.wait.state" 2>/dev/null)"
tick_line "N1:FRESH,N2:FRESH" "ok"
timeout 3 bash "$WAIT" "$I" --workers "N1.md N2.md" > "$WORK/j.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(j) the re-arm ran until the timeout" "124" "$rc"
check "(j) a re-arm with a new worker set re-baselines instead of waking" "" "$(cat "$WORK/j.out")"
base2="$(cat "$I.wait.state" 2>/dev/null)"
if [ -n "$base1" ] && [ -n "$base2" ] && [ "$base1" != "$base2" ]; then pass "(j) the saved baseline moved to the new worker set"; else fail "(j) the saved baseline moved to the new worker set (was '$base1' now '$base2')"; fi

# --- (l) a tick that prints a line and then fails is never a change -------
reset_stub
I="$(new_inbox l)"
start "$I" "$WORK/l.out" --workers "N1.md"
wait_hb "$I" || fail "(l) no baseline heartbeat"
tick_line "N1:FREE" "ok"; : > "$STUB/tick.failafter"
sleep 3.5
check "(l) a failing tick's TICK line does not wake" "" "$(cat "$WORK/l.out")"
check "(l) the failing tick is recorded as tick=fail" "yes" "$(grep -q 'tick=fail' "$I.wait" && echo yes)"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# --- (m) the heartbeat exists before the first (slow) sample returns -------
reset_stub
printf '3\n' > "$STUB/tick.sleep"
I="$(new_inbox m)"
start "$I" "$WORK/m.out" --workers "N1.md"
sleep 1
check "(m) a waiter mid-sample already shows state=sampling" "yes" "$(grep -q 'state=sampling' "$I.wait" 2>/dev/null && echo yes)"
bash "$WAIT" "$I" --workers "N1.md" > "$WORK/m2.out" 2>&1; rc=$?
check "(m) a second waiter during the first sample is refused (rc 3)" "3" "$rc"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# --- (n) a partial inbox line (no newline yet) does not wake ---------------
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

# --- (o) a hung tick that ignores TERM still frees the Telegram path -------
reset_stub
: > "$STUB/tick.ignoreterm"
I="$(new_inbox o)"
CHIEF_WAIT_TICK_TIMEOUT=1 start "$I" "$WORK/o.out" --workers "N1.md"
# The line lands after the TERM (1 s), while the first sample is still hung.
sleep 2
printf -- '- 03:40 [telegram from=1 chat=2] hello\n' >> "$I"
n=0
while [ "$n" -lt 150 ] && kill -0 "$WPID" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
check "(o) the line is delivered within 15 s despite a TERM-ignoring tick" "WAKE telegram" "$(head -n1 "$WORK/o.out")"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# --- (p) two waiters started at the same instant: exactly one runs ---------
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
kill "$P1" "$P2" 2>/dev/null; wait "$P1" "$P2" 2>/dev/null

# --- (q) a first start with no consoles/ directory yet still arms -----------
reset_stub
I="$WORK/q/consoles/c.md"
start "$I" "$WORK/q.out" --workers "N1.md"
wait_hb "$I" || fail "(q) no baseline heartbeat when consoles/ was absent"
check "(q) the waiter created the inbox" "yes" "$([ -f "$I" ] && echo yes)"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# --- (r) a tick line missing an action field is a failed sample, never a
# key with an empty value baked in: it counts toward the fail streak, not a
# changed-key wake, even across two consecutive malformed samples -----------
reset_stub
I="$(new_inbox r)"
HOUSEKEEPING_DIGEST_SECS=0 CHIEF_WAIT_FAIL_WAKE=2 start "$I" "$WORK/r.out" --workers "N1.md"
wait_hb "$I" || fail "(r) no baseline heartbeat"
sed 's/ tails=N1:LIVE//' "$STUB/tick.line" > "$STUB/tick.line.tmp" && mv "$STUB/tick.line.tmp" "$STUB/tick.line"
wait_exit "$WPID"
check "(r) a streak of malformed samples ends the wait" "0" "$rc"
check "(r) the wake is tick-fail, never a changed key from an empty field, naming the field" "WAKE tick-fail samples=2 step=missing-field:tails" "$(head -n1 "$WORK/r.out")"
[ "$rc" = running ] && { kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; }

# --- (s) .wait.state is written atomically (temp file + rename), never with
# an in-place '>' redirect that could leave a torn key file on a kill -------
# shellcheck disable=SC2016 # literal grep pattern, not a shell expansion
check "(s) no in-place '> \"\$key_file\"' write remains (must go through .tmp + mv)" "0" \
    "$(grep -cF '> "$key_file"' "$HERE/chief-wait.sh")"

# --- (t) a board class move to ok never wakes on its own; the saved key
# still moves to board=ok, so a later move to STALE wakes again -
reset_stub
tick_line "N1:FRESH" "STALE:5m"
I="$(new_inbox t)"
start "$I" "$WORK/t.out" --workers "N1.md"
wait_hb "$I" || fail "(t) no baseline heartbeat"
tick_line "N1:FRESH" "ok"
wait_exit "$WPID"
check "(t) a board move to ok alone does not wake" "running" "$rc"
check "(t) the saved key still moved to board=ok" "yes" "$(grep -q 'board=ok' "$I.wait.state" && echo yes)"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# --- (u) a board class move to STALE wakes, naming board -------------------
reset_stub
I="$(new_inbox u)"
HOUSEKEEPING_DIGEST_SECS=0 start "$I" "$WORK/u.out" --workers "N1.md"
wait_hb "$I" || fail "(u) no baseline heartbeat"
tick_line "N1:FRESH" "STALE:3m"
wait_exit "$WPID"
check "(u) a board move to STALE ends the wait" "0" "$rc"
check "(u) the wake names board" "WAKE tick changed=board usage=PROCEED" "$(head -n1 "$WORK/u.out")"

# --- (v) board STALE-to-ok combined with a prs change still wakes, naming
# only the real field ---------------------------------------------------------
reset_stub
tick_line "N1:FRESH" "STALE:5m"
I="$(new_inbox v)"
HOUSEKEEPING_DIGEST_SECS=0 start "$I" "$WORK/v.out" --workers "N1.md"
wait_hb "$I" || fail "(v) no baseline heartbeat"
tick_line "N1:FRESH" "ok" "1m" "#99"
wait_exit "$WPID"
check "(v) board-to-ok combined with a prs change still wakes" "0" "$rc"
check "(v) the wake names only prs, not board" "WAKE tick changed=prs usage=PROCEED" "$(head -n1 "$WORK/v.out")"

# --- (p) a denials rise to SHIP-STEP / PAUSE-RISK pages ---------
# One page per rise (a new worker or a higher class), never per tick. The page
# text carries the worker label, count and class ONLY.
P_NOPROC="$WORK/p-noproc"; mkdir -p "$P_NOPROC"; export CHIEF_WAIT_PROC="$P_NOPROC"
denials_rise() { # <case> <from> <to>  -> runs the waiter to its wake (or 8 s)
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
[ "$rc" = running ] && { kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; }

denials_rise p5c 'N1:1' 'N1:1,N2:1:SHIP-STEP'
check "(p5c) a second worker's SHIP-STEP pages under its own label" "DENIAL-PAGE N2 SHIP-STEP x1 - a classifier denial parked this worker. Review it, then: ack-denial.sh N2" "$(head -n1 "$STUB/pages" 2>/dev/null)"

# A refused native worker with Remote Control on is named by its
# session, so the operator knows which session to open in the Claude app. The
# worker is found by cwd (the page label is the worktree slug) in a fake proc tree;
# a worker without --remote-control keeps the exact text asserted above.
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

# A re-arm after the wake must not page the same rise again.
denials_rise p5d none 'N1:1:SHIP-STEP'
timeout 3 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/p5d2.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(p5d) the re-arm keeps waiting until the timeout cuts it off (124)" "124" "$rc"
check "(p5d) the re-arm after a paged wake is silent" "" "$(cat "$WORK/p5d2.out")"
check "(p5d) and does not page the same rise again" "1" "$(pages_n)"

# Fail open: a sender that fails, or hangs, never breaks the wake.
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

# Two workers rise at once and the sender hangs: the page timeout is ONE budget for
# the batch, so the second worker is not sent (each send used to get a fresh 45 s),
# but its page record is still written for the refusal.
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

# An unwritable record dir never breaks the wake either.
mkdir -p "$WORK/ro" && chmod 500 "$WORK/ro"
HIMMEL_DENIAL_ACK_DIR="$WORK/ro/sub" denials_rise p6c none 'N1:1:SHIP-STEP'
check "(p6) an unwritable record dir still wakes with rc 0" "0" "$rc"
chmod 700 "$WORK/ro"
unset CHIEF_WAIT_PROC

# --- (w) tracker= wakes on a class change exactly as board= does:
# ok to STALE wakes naming tracker, a move to ok alone does not, and a tick
# line with no tracker= field (an older tick.sh) stays a valid sample ----------
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
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

reset_stub
I="$(new_inbox w3)"
start "$I" "$WORK/w3.out" --workers "N1.md"
wait_hb "$I" || fail "(w3) no baseline heartbeat"
wait_exit "$WPID"
check "(w3) a tick line with no tracker= field is still a valid sample" "running" "$rc"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# --- (w4) orphans-wip= wakes on any change of its value, and a tick
# line without it stays a valid sample (the (w3) case covers the absent field) ----
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

# --- (x) vault= wakes on a class change TO STALL or PUSH-LAG, never on
# age/count alone, never on a move back to ok/skip/unknown, and its absence
# (an older tick.sh) is still a valid sample. The wake names the reproduce
# command. RED control (chief-wait.sh before this change): the STALL move
# below never woke ("running"). ------------------------------------------------
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
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

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
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

reset_stub
I="$(new_inbox x5)"
start "$I" "$WORK/x5.out" --workers "N1.md"
wait_hb "$I" || fail "(x5) no baseline heartbeat"
wait_exit "$WPID"
check "(x5) a tick line with no vault= field is still a valid sample" "running" "$rc"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# --- (y) cloud= wakes on a class move TO STALL only -- never on a
# change of the ticket list, never on a move back to ok/skip, and its absence (an
# older tick.sh) is still a valid sample. RED control (chief-wait.sh before this
# change): the STALL move below never woke ("running"). -----------------------
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
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

reset_stub
cloud_line ok
I="$(new_inbox y3)"
start "$I" "$WORK/y3.out" --workers "N1.md"
wait_hb "$I" || fail "(y3) no baseline heartbeat"
tick_line "N1:FRESH" "ok"
cloud_line skip
wait_exit "$WPID"
check "(y3) a cloud move to skip does not wake" "running" "$rc"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

reset_stub
I="$(new_inbox y4)"
start "$I" "$WORK/y4.out" --workers "N1.md"
wait_hb "$I" || fail "(y4) no baseline heartbeat"
wait_exit "$WPID"
check "(y4) a tick line with no cloud= field is still a valid sample" "running" "$rc"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# --- (sec) an inbox outside the */consoles/<name>.md layout is refused before
# a byte of it is read: the waiter streams the inbox's lines to stdout, so a
# secret path would print the secret. A symlink into the layout is judged by
# where it lands. RED control (chief-wait.sh before this change): both
# print the secret line under WAKE telegram and exit 0.
reset_stub
mkdir -p "$WORK/sec/.himmel" "$WORK/sec/consoles"
printf 'SECRET-HMAC-KEY\n' > "$WORK/sec/.himmel/go-hmac.key"
timeout 5 bash "$WAIT" "$WORK/sec/.himmel/go-hmac.key" --workers "N1.md" > "$WORK/sec.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit
check "(sec) a secret-shaped inbox path is refused" "2" "$rc"
check "(sec) the refused secret is never printed" "0" "$(grep -c SECRET "$WORK/sec.out")"
ln -s "$WORK/sec/.himmel/go-hmac.key" "$WORK/sec/consoles/c.md"
timeout 5 bash "$WAIT" "$WORK/sec/consoles/c.md" --workers "N1.md" > "$WORK/sec-ln.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit
check "(sec) a consoles/ symlink onto a secret is refused" "2" "$rc"
check "(sec) the symlinked secret is never printed" "0" "$(grep -c SECRET "$WORK/sec-ln.out")"
# An inbox swapped for a link onto a secret after the start check is refused
# at the next drain, never printed.
I="$(new_inbox sec-swap)"
start "$I" "$WORK/sec-swap.out" --workers "N1.md"
wait_hb "$I" || fail "(sec) no baseline heartbeat"
rm -f "$I"; ln -s "$WORK/sec/.himmel/go-hmac.key" "$I"
wait_exit "$WPID"
check "(sec) an inbox swapped for a secret link mid-wait ends the wait" "1" "$rc"
check "(sec) the swapped-in secret is never printed" "0" "$(grep -c SECRET "$WORK/sec-swap.out")"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# --- (rdy) a READY bullet arrives as one pre-checked wake --------------------
# With --doc and --workers-from, a worker's new `READY <pr> <head40> GREEN` bullet makes
# the waiter run ready-check, a CI read and cr-disposition check (stubbed here) and wake
# once per (PR, head) with the verdicts. RED control (chief-wait.sh before this change):
# the READY is a `WAKE tick changed=tails,acts` with no payload.
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
# timeout seam: logs the bound a ready-check call runs under, then runs the real timeout.
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
# auto_go off (its own READY relay is test-chief-wait-r0.sh's): a fixture registry, no shell override
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
# ready_tick <tails> [acts]: the standing tick line with these worker fields.
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
# the same head written twice: a re-arm neither wakes nor re-checks
ready_stubs_pass
printf -- '- 10:05 READY 2566 %s GREEN\n' "$HA" >> "$RL"
ready_tick "N1:READY" "N1:READY#2"
start "$I" "$WORK/rdy-same.out" --doc "$RD" --workers-from "$RM"
wait_hb "$I" || fail "(rdy) no re-arm heartbeat"
sleep 3
check "(rdy) the same (PR, head) twice is one wake" "" "$(cat "$WORK/rdy-same.out")"
check "(rdy) and is not re-checked" "" "$(cat "$STUB/rc.calls" 2>/dev/null)"
# a new head re-checks, and the verdicts carry each failure
printf '[FAIL] 7. ticket coverage: no section\nTRUST-PATH: yes\nREADY-CHECK FAIL\n' > "$STUB/rc.out"; echo 1 > "$STUB/rc.rc"
printf 'RED\n' > "$STUB/ci.out"
printf '[OPEN] crit f1@x: deferred\n[OPEN] imp f2@x: deferred\nDISPOSITION FAIL (2 of 2 open Critical/Important finding(s) on b)\n' > "$STUB/disp.out"; echo 1 > "$STUB/disp.rc"
printf -- '- 10:20 READY 2566 %s GREEN\n' "$HB" >> "$RL"
ready_tick "N1:READY" "N1:READY#3"
wait_exit "$WPID"
check "(rdy) a new head wakes again" "0" "$rc"
check "(rdy) with each failed verdict" "WAKE ready 2566 $HB ready-check=FAIL ci=RED coverage=FAIL disposition=open:2 out=$I.wait.ready-2566" "$(head -n 1 "$WORK/rdy-same.out")"
check "(rdy) the trust path reaches cr-disposition" "check 2566 $HB --trust-path yes" "$(cat "$STUB/disp.calls" 2>/dev/null)"
# a READY with no GREEN is not a ready wake and does not consume its head
ready_stubs_pass
HC=cccccccccccccccccccccccccccccccccccccccc
printf -- '- 10:30 READY 2566 %s\n' "$HC" >> "$RL"
ready_tick "N1:READY" "N1:READY#4"
start "$I" "$WORK/rdy-nog.out" --doc "$RD" --workers-from "$RM"
wait_exit "$WPID"
check "(rdy) a READY without GREEN is no ready wake" "" "$(grep '^WAKE ready' "$WORK/rdy-nog.out")"
check "(rdy) and runs no check" "" "$(cat "$STUB/rc.calls" 2>/dev/null)"
# the out file shows the chief the READY bullet text (separate fixture: PR 2577)
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
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
# (rdy-cwd) the caller's cwd never decides the gated repo: started from another repo's
# checkout (origin other/luna), the waiter runs ready-check and cr-disposition in
# HIMMEL_REPO and its CI read names HIMMEL_REPO's origin (-R o/x). RED control
# (chief-wait.sh before this change): both run in the cwd and `gh pr checks` names no repo.
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
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
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
wr_stop() { kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; }
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
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
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
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
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

# --- (cd) a red or wrongly skipped scheduled CI run wakes the chief once ---
# The tick's cadence= field lists the last scheduled run of each workflow, a flagged one ending :RED,
# :SKIP or :MISSED. The first sample is a baseline (no wake for a run that already finished); after it a
# flagged run id the sentinel <inbox>.wait.cadence does not hold wakes once with the run link and the
# cause, which CHIEF_WAIT_CADENCE (a stub here) prints. RED control (chief-wait.sh before this change):
# no WAKE cadence line, the waiter keeps waiting.
cat > "$STUB/cadence-cause.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s run=%s %s https://github.com/x/y/actions/runs/%s cause: build / Run tests\n' "$1" "$2" "$3" "$2"
EOF
chmod +x "$STUB/cadence-cause.sh"  # the cause seam is exec'd directly, not run via bash
export CHIEF_WAIT_CADENCE="$STUB/cadence-cause.sh"
cd_tick() { # <cadence value>
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
# a re-armed waiter on the same inbox and the same standing red replays nothing
start "$I" "$WORK/cd3.out"
wait_hb "$I" || fail "(cd3) no baseline heartbeat"
check "(cd3) a re-armed waiter wakes nothing for the same run id" "running" "$(cd_alive)"
cd_tick 'ci:success:3h:101,macos-cadence:failure:4h:201:RED'
check "(cd3) the same run id a tick later still wakes nothing" "running" "$(cd_alive)"
# (c) a wrong skip wakes
cd_tick 'ci:success:3h:101,pages:skipped:4h:301:SKIP'
wait_exit "$WPID"
check "(cd4) a wrongly skipped run wakes" "WAKE cadence pages run=301 SKIP" "$(head -n1 "$WORK/cd3.out" | cut -d' ' -f1-5)"
# a gated run concludes success and is not flagged: a new run id with no flag wakes nothing
reset_stub
cd_tick 'ci:success:3h:101,snyk-weekly:success:3d:401'
I="$(new_inbox cd5)"
start "$I" "$WORK/cd5.out"
wait_hb "$I" || fail "(cd5) no baseline heartbeat"
cd_tick 'ci:success:3h:102,snyk-weekly:success:3d:402'
check "(cd5) a new unflagged run, a correct skip, wakes nothing" "running" "$(cd_alive)"
# (e) cadence=? neither wakes nor crashes the waiter
cd_tick '?'
check "(cd6) cadence=? wakes nothing and the waiter survives" "running" "$(cd_alive)"
# a missed schedule wakes once
cd_tick 'ci:success:3h:102,fork-drift:success:40h:501:MISSED'
wait_exit "$WPID"
check "(cd7) a missed schedule wakes" "WAKE cadence fork-drift run=501 MISSED" "$(head -n1 "$WORK/cd5.out" | cut -d' ' -f1-5)"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
# a run still in flight at the baseline is not finished: when it later concludes red it wakes
reset_stub
cd_tick 'ci:success:3h:101,pages:running:1m:601'
I="$(new_inbox cd8)"
start "$I" "$WORK/cd8.out"
wait_hb "$I" || fail "(cd8) no baseline heartbeat"
cd_tick 'ci:success:3h:101,pages:failure:5m:601:RED'
wait_exit "$WPID"
check "(cd8) a run in flight at the baseline that concludes red wakes" "WAKE cadence pages run=601 RED" "$(head -n1 "$WORK/cd8.out" | cut -d' ' -f1-5)"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
unset CHIEF_WAIT_CADENCE

# --- (rv) the daily failure review wakes once per review day (decision 593) ---
# review=<date>:<age>:<failures>:<new>:<new 5+>:<filed>[:STALE]. It wakes on a filed key or a new class
# with 5+ failures; STALE wakes once per last-review date; a 1-count class never wakes.
# RED control (chief-wait.sh before this change): no WAKE review line, the waiter keeps waiting.
rv_tick() { # <review value>
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
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

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
GRO=${GRO##*$'\n'}   # bash's own "No such file" line comes first; the refusal is the last line
check "(gr3) a kit with no resolver lib refuses rc 2 naming the lib" "2|chief-wait: cannot load scripts/lib/gate-repo-resolver.sh; nothing waited" "$GRC|$GRO"

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
