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
printf '#!/usr/bin/env bash\nexit 11\n' > "$STUB/ws-lock.sh"  # the worker's doc lock is held: a live session
CHIEF_WAIT_LOCK_STATUS="$STUB/ws-lock.sh" CHIEF_WAIT_TRACKER="$STUB/ws-tracker.sh" CHIEF_WAIT_SUCCESSION_SEC=1 start "$I" "$WORK/ws6.out" --doc "$WD" --succession S2 --silent-min 0 --workers-from "$WM"
wait_exit "$WPID"
check "(ws6) the partial wake still comes first" "WAKE succession partial 0/1 silent 0 min" "$(head -n1 "$WORK/ws6.out")"
check "(ws6) the worker it names gets one worker-silent line" "1" "$(grep -c '^WAKE worker-silent N1 signal=succession-partial' "$WORK/ws6.out")"
check "(ws6) and one operator alert" "1" "$(ws_pages)"
if [ "$rc" = running ]; then kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; fi
rm -f "$STUB/pages"

# --- (sp) a succession partial pages only a worker that is live ---
# The tally names every worker still short of a quote-back, but a worker whose manifest rows all
# have a free queue lock (closed by the chief without a WRAPPED bullet, never launched, or alive on
# another row's doc) is not silent: no WAKE worker-silent line, no bullet, no page. A worker whose
# row holds a lock is live, so it still pages once. The tally and the lock status are stubbed; the
# waiting list copies the shape of the UC takeover tally (11 of 18): five closed rows, one brief
# written with its launch held, and N5017c alive on the N5017 doc. RED control (chief-wait.sh before
# this change): every waiting label pages.
# sp_run <case> <waiting labels, space separated> <labels whose doc holds a lock>...: runs one tally
sp_run() {
    local c="$1" labels="$2" l first=1 h; shift 2
    mkdir -p "$WORK/$c/consoles"; I="$WORK/$c/consoles/c.md"; : > "$I"
    WD="$WORK/$c/chief.md"; printf '# chief\n\n## Results\n' > "$WD"
    WM="$WORK/$c/chief.fleet.json"
    : > "$STUB/sp-held"
    printf '{"schema":1,"workers":[' > "$WM"
    for l in $labels; do
        printf '# worker\n\n## Results\n- 09:00 LIVE — started\n' > "$WORK/$c/$l.md"
        [ "$first" -eq 1 ] || printf ',' >> "$WM"
        first=0
        printf '{"doc":"%s/%s.md","label":"%s"}' "$WORK/$c" "$l" "$l" >> "$WM"
    done
    # SP_ROW2=<label>: a second manifest row for that label, its doc <label>-b.md (a relaunch)
    [ -z "${SP_ROW2:-}" ] || printf ',{"doc":"%s/%s-b.md","label":"%s"}' "$WORK/$c" "$SP_ROW2" "$SP_ROW2" >> "$WM"
    printf ']}\n' >> "$WM"
    for h in "$@"; do printf '%s\n' "$WORK/$c/$h.md" >> "$STUB/sp-held"; done
    # shellcheck disable=SC2016  # the stub bodies expand when the stubs run
    printf '#!/usr/bin/env bash\ngrep -qxF -- "$2" "$STUB/sp-held" && exit 11\nexit 0\n' > "$STUB/sp-lock.sh"
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
sp_run sp1 "N5004b" # closed by the chief: the row's doc has no WRAPPED bullet and no lock
check "(sp1) the partial wake still comes first" "WAKE succession partial 11/18 silent 0 min" "$(head -n1 "$WORK/sp1.out")"
check "(sp1) a closed worker with no lock prints no worker-silent line" "0" "$(sp_silent_lines sp1)"
check "(sp1) and writes no WORKER-SILENT bullet" "0" "$(sp_bullets)"
check "(sp1) and sends no page" "0" "$(ws_pages)"
sp_run sp2 "N5054" # never launched: the brief is written, nothing holds its lock
check "(sp2) a never-launched worker prints no worker-silent line" "0" "$(sp_silent_lines sp2)"
check "(sp2) and writes no WORKER-SILENT bullet" "0" "$(sp_bullets)"
check "(sp2) and sends no page" "0" "$(ws_pages)"
sp_run sp3 "N5017 N5017c" N5017 # N5017c is alive on the N5017 doc, whose lock is held; its own row's doc is free
check "(sp3) a worker answered on another row's doc prints no worker-silent line for itself" "0" "$(grep -c '^WAKE worker-silent N5017c' "$WORK/sp3.out" || true)"  # pipefail-ok: none set
check "(sp3) and is not paged" "0" "$(grep -c 'WORKER-SILENT N5017c' "$STUB/pages" 2>/dev/null || true)"  # pipefail-ok: none set
check "(sp3) and gets no bullet" "0" "$(grep -c 'WORKER-SILENT N5017c' "$WD" || true)"  # pipefail-ok: none set
# control: a live worker (its row's lock held) with no quote-back still pages once; it goes red if the fix silences every page
sp_run sp4 "N7001" N7001
check "(sp4) a live worker with no quote-back prints one worker-silent line" "1" "$(grep -c '^WAKE worker-silent N7001 signal=succession-partial' "$WORK/sp4.out" || true)"  # pipefail-ok: none set
check "(sp4) writes one WORKER-SILENT bullet" "1" "$(sp_bullets)"
check "(sp4) and sends one page" "1" "$(ws_pages)"
# the UC takeover tally: seven false labels and one live silent worker; only the live one pages
sp_run sp5 "N5004b N4992c N5017b N4992d N5046b N5054 N5017c N7001" N7001
check "(sp5) a mixed tally prints worker-silent for the live worker only" "WAKE worker-silent N7001 signal=succession-partial" "$(grep '^WAKE worker-silent' "$WORK/sp5.out" | head -n1)"
check "(sp5) exactly one worker-silent line" "1" "$(sp_silent_lines sp5)"
check "(sp5) and exactly one page" "1" "$(ws_pages)"
# a label on two rows is closed only when both rows are lock-free
SP_ROW2=N5017 sp_run sp6 "N5017" N5017-b
check "(sp6) a worker whose relaunch row holds a lock still pages" "1" "$(sp_silent_lines sp6)"
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
# cap=<version>:<n> (a version past the residual soft cap) is in the key whole: it appearing
# or its value moving wakes once, an unchanged value stays silent on a re-arm, and its going away is no wake.
reset_stub
I="$(new_inbox cap-field)"
start "$I" "$WORK/cap-field.out" --workers "N1.md"
wait_hb "$I" || fail "(cap) no baseline heartbeat"
sed -i 's/ denials=none/ cap=v1.1.3:16 denials=none/' "$STUB/tick.line"  # gnu-ok: Linux-only kit
wait_exit "$WPID"
check "(cap) a version crossing the soft cap ends the wait" "0" "$rc"
check "(cap) the wake names the cap field" "WAKE tick changed=cap usage=PROCEED" "$(head -n1 "$WORK/cap-field.out")"
if [ "$rc" = running ]; then kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; fi
timeout 3 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/cap-field-rearm.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit
check "(cap) an unchanged cap keeps waiting" "124" "$rc"
check "(cap) an unchanged cap does not re-wake" "" "$(cat "$WORK/cap-field-rearm.out")"
start "$I" "$WORK/cap-field-move.out" --workers "N1.md"
wait_hb "$I" || fail "(cap) no re-armed heartbeat"
sed -i 's/ cap=v1.1.3:16/ cap=v1.1.3:17/' "$STUB/tick.line"  # gnu-ok: Linux-only kit
wait_exit "$WPID"
check "(cap) a moved cap count ends the wait" "0" "$rc"
check "(cap) the moved count wakes as cap" "WAKE tick changed=cap usage=PROCEED" "$(head -n1 "$WORK/cap-field-move.out")"
if [ "$rc" = running ]; then kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; fi
start "$I" "$WORK/cap-field-gone.out" --workers "N1.md"
wait_hb "$I" || fail "(cap) no cleared heartbeat"
sed -i 's/ cap=v1.1.3:17//' "$STUB/tick.line"  # gnu-ok: Linux-only kit
wait_exit "$WPID"
check "(cap) a cap that goes away keeps waiting" "running" "$rc"
if [ "$rc" = running ]; then kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; fi
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

# a pending trust-path HOLD-ASK is paged to the operator ONCE, with the paste-ready grant command. The suite owns
# HOME (the register and events.log are fixtures under $WORK) and the sender stub; the record is <inbox>.wait.holdasks.
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
wait_hb "$I" || fail "(hask) no baseline heartbeat"
n=0; while [ ! -s "$STUB/pages" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
sleep 1
check "(hask) one trust-path ask records exactly one page line" "1" "$(grep -c . "$STUB/pages" 2>/dev/null)"
check "(hask) the line carries the full paste-ready grant command" "1" "$(grep -cF -- "python3 -I $HA_PRIMARY/scripts/handover/chief-kit/holds.py grant --key HIMMEL-9942 --repo $HA_PRIMARY scripts/check-ci.sh" "$STUB/pages")"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
HOME="$HA_HOME" start "$I" "$WORK/hask2.out" --workers "N1.md"
wait_hb "$I" || fail "(hask) no re-armed heartbeat"
sleep 3
check "(hask) a repeat of the same ask (a re-armed waiter) records nothing" "1" "$(grep -c . "$STUB/pages" 2>/dev/null)"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
rm -f "$STUB/pages"

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
check "(c4670) a fails= change does not wake (HIMMEL-4670)" "running" "$rc"
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
sed -i 's/ bank=/ unowned-prs=#2575:120m bank=/' "$STUB/tick.line"  # gnu-ok: Linux-only kit
I="$(new_inbox d2)"
timeout 4 bash "$WAIT" "$I" --workers "N1.md" > "$WORK/d2.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit
check "(8934) the first sight of an unowned PR does not wake, it joins the digest" "124:0:1" "$rc:$(grep -c '^WAKE ' "$WORK/d2.out"):$(grep -c '^unowned-prs #2575:120m' "$I.wait.housekeeping" 2>/dev/null)"

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
unset CHIEF_WAIT_PROC

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
# ponytail: as root chmod does not bind, so this case only proves the wake there; run it as a normal user for the real control, no ticket (test-audit finding, root CI has no upgrade path worth a fixture).
mkdir -p "$WORK/ro" && chmod 500 "$WORK/ro"
HIMMEL_DENIAL_ACK_DIR="$WORK/ro/sub" denials_rise p6c none 'N1:1:SHIP-STEP'
check "(p6) an unwritable record dir still wakes with rc 0" "0" "$rc"
chmod 700 "$WORK/ro"

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
cat "$STUB/rc.out"; exit "$(cat "$STUB/rc.rc")"
EOF
cat > "$STUB/ci.sh" <<'EOF'
#!/usr/bin/env bash
cat "$STUB/ci.out"
EOF
cat > "$STUB/disposition.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB/disp.calls"
cat "$STUB/disp.out"; exit "$(cat "$STUB/disp.rc")"
EOF
export CHIEF_WAIT_READY_CHECK="$STUB/ready-check.sh" CHIEF_WAIT_CI="$STUB/ci.sh" CHIEF_WAIT_DISPOSITION="$STUB/disposition.sh"
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
check "(rdy) ready-check ran once on the PR and head" "2566 $HA" "$(cat "$STUB/rc.calls" 2>/dev/null)"
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
unset CHIEF_WAIT_READY_CHECK CHIEF_WAIT_CI CHIEF_WAIT_DISPOSITION
export PATH="$SAVED_PATH"

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
# review=<date>:<age>:<failures>:<new>:<new 5+>:<filed>[:CAPPED][:STALE]. It wakes on a filed key, a new class
# with 5+ failures or the create cap; STALE wakes once per last-review date; a 1-count class never wakes.
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
rv_tick '2026-11-05:5h:100:2:1:HIMMEL-9256+HIMMEL-9257:CAPPED'
check "(rv3) the same day with more reasons still wakes nothing" "running" "$(cd_alive)"
rv_tick '2026-11-06:2h:80:0:0:HIMMEL-9300'
wait_exit "$WPID"
check "(rv4) the next review day wakes on a filed ticket" "WAKE review 2026-11-06 filed=HIMMEL-9300" "$(head -n1 "$WORK/rv3.out")"
reset_stub
rv_tick '2026-11-06:2h:80:0:0:-:CAPPED'
I="$(new_inbox rv5)"
start "$I" "$WORK/rv5.out"
wait_exit "$WPID"
check "(rv5) the create cap wakes" "WAKE review 2026-11-06 create-cap-hit" "$(head -n1 "$WORK/rv5.out")"
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


printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
