#!/usr/bin/env bash
# test-chief-wait-pool.sh — The underfilled wake of chief-wait.sh re-wakes
# when the dispatchable pool changes during one idle streak:
# a pool that grows from empty, or whose key set changes, wakes once per change
# on a bounded re-probe cadence; an unchanged pool, an emptied pool or a failed probe never wakes.
# Also pins that the wake block carries next-dispatchable.sh's output verbatim,
# drop summary included. tick.sh, the bank verdict and the dispatch command are
# stubbed (CHIEF_WAIT_TICK / CHIEF_WAIT_USAGE / CHIEF_WAIT_DISPATCH). bash 3.2-safe.
#
# CHIEF_WAIT overrides the script under test (the RED
# control: the pre-change once-per-streak waiter fails the re-wake rows).
#
# Linux-only: this suite uses GNU
# timeout and stat -c.
#
# Run: bash scripts/handover/chief-kit/test-chief-wait-pool.sh
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

WORK="$(mktemp -d "${TMPDIR:-/tmp}/chief-wait-pool-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$WORK"' EXIT

STUB="$WORK/stub"
mkdir -p "$STUB"
cat > "$STUB/tick.sh" <<'EOF'
#!/usr/bin/env bash
trap 'echo x >> "$STUB/ticks"' EXIT
[ ! -f "$STUB/stall" ] || { read -r stall < "$STUB/stall"; sleep "$stall"; : > "$STUB/stalled"; }
[ ! -f "$STUB/tick.fail" ] || exit 1
cat "$STUB/tick.line"
EOF
cat > "$STUB/bank.sh" <<'EOF'
#!/usr/bin/env bash
cat "$STUB/bank"
EOF
printf 'TICK 03:00 hb=1m workers=N1:FRESH livestate=ok procs=2 models=x ceiling=ok atq=0 suites=0alive/0dead prs=#10 bank=5h8/wk15/codex=? fill=40 tails=N1:LIVE inbox=none tick=UNKNOWN fleet=3/15 capacity=UNDERFILLED:7 gql=4000/04:00 orphans=none nonces=ok legset=ok board=ok denials=none or=skip fails=none\n' > "$STUB/tick.line"
printf 'PROCEED\n' > "$STUB/bank"
export STUB
export HIMMEL_CORE_CHECK_BATCH=off
export CHIEF_WAIT_TICK="$STUB/tick.sh" CHIEF_WAIT_USAGE="$STUB/bank.sh"
export CHIEF_WAIT_INTERVAL=1 CHIEF_WAIT_POLL_SEC=0.2 CHIEF_WAIT_FAIL_WAKE=1000
# the re-probe cadence is seconds here; the default is 30 minutes
export CHIEF_WAIT_UNDERFILL_REPOOL_SEC=1 CHIEF_WAIT_PAUSED_REPROBE_SEC=0
# a re-probe is cut after a second here; the default is two minutes
export CHIEF_WAIT_REPOOL_TIMEOUT=1
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/off.sh"
printf '#!/usr/bin/env bash\nexit 2\n' > "$STUB/budget-off.sh"
# the underfilled orphan-pr check reads gh; a clean no-op keeps these cases off the real one
export CHIEF_WAIT_PAGE_CMD="$STUB/off.sh" CHIEF_WAIT_BUDGET="$STUB/budget-off.sh" CHIEF_WAIT_ORPHAN="$STUB/off.sh"
export WAIT_SWEEP_CMD="$STUB/off.sh" WAIT_FOCUS_CMD="$STUB/off.sh"
export HIMMEL_DENIAL_ACK_DIR="$WORK/acks"
export HIMMEL_RELEASE_STATE_DIR="$WORK/no-release-declared"
# the core gate always asks the jira CLI (scripts/jira/dist is untracked, absent in CI): a fixture stand-in calls every key NOT-CORE
mkdir -p "$WORK/stub-jira"
cat > "$WORK/stub-jira/index.js" <<'STUBEOF'
const a = process.argv.slice(2);
if (a[0] === 'release' && a[1] === 'core-check') for (const k of a.slice(a.indexOf('--key') + 1)) console.log('NOT-CORE ' + k);
else { console.error('stub jira: unknown command ' + a.join(' ')); process.exit(2); }
STUBEOF
export NEXT_DISPATCH_JIRA_CLI="$WORK/stub-jira/index.js"

# The pool stub: each priority-pool call is counted; pool.rows is the pool, absent means
# empty, pool.fail makes the call fail with no output.
cat > "$STUB/dispatch.sh" <<'EOF'
#!/usr/bin/env bash
case " $* " in
    *" --priority-pool-only "*)
        echo x >> "$STUB/calls"
        [ -f "$STUB/pool.fail" ] && exit 1
        [ -f "$STUB/pool.slow" ] && exec sleep 30
        [ -f "$STUB/pool.partial" ] && { printf 'LOCAL\tHIMMEL-9099\tMedium\tv1\tcut short\tfiles=z.sh\n'; exit 124; }
        [ -f "$STUB/pool.paused" ] && { cat "$STUB/pool.paused"; exit 0; }
        if [ -f "$STUB/pool.rows" ] && [ -f "$STUB/pool.intake" ]; then cat "$STUB/pool.rows"; printf '# pool=%s/7,INTAKE:3\n' "$(wc -l < "$STUB/pool.rows" | tr -d ' ')"; if [ -s "$STUB/pool.intake" ]; then cat "$STUB/pool.intake"; else echo '# intake 3 for v1: HIMMEL-901 HIMMEL-902 HIMMEL-905'; fi
        elif [ -f "$STUB/pool.rows" ]; then cat "$STUB/pool.rows"; printf '# pool=%s/7,LOW\n' "$(wc -l < "$STUB/pool.rows" | tr -d ' ')"
        else printf '# pool=0/7,LOW\nPOOL-EMPTY\n'; fi
        case " $* " in *" --dispositions "*) [ ! -f "$STUB/dispositions" ] || cat "$STUB/dispositions" ;; esac ;;
    *) [ ! -f "$STUB/pass2.fail" ] || exit 1  # a failed second pass
       [ ! -f "$STUB/pass2.rows" ] || cat "$STUB/pass2.rows" ;;  # the second pass, without --priority-pool-only
esac
EOF
export CHIEF_WAIT_DISPATCH="$STUB/dispatch.sh"
calls() { if [ -f "$STUB/calls" ]; then wc -l < "$STUB/calls" | tr -d ' '; else echo 0; fi; }
wakes() { grep -c '^WAKE underfilled' "$1" 2>/dev/null; }

new_inbox() { mkdir -p "$WORK/$1/consoles"; : > "$WORK/$1/consoles/c.md"; printf '%s' "$WORK/$1/consoles/c.md"; }
# arm <inbox> <outfile> <seconds>: one foreground arm that exits on a wake or after <seconds> (rc 124)
arm() { timeout "$3" bash "$WAIT" "$1" --workers "N1.md" > "$2" 2>/dev/null; rc=$?; }  # gnu-ok: Linux-only kit; pipefail-ok: none set
ticks() { if [ -f "$STUB/ticks" ]; then wc -l < "$STUB/ticks" | tr -d ' '; else echo 0; fi; }
arm_quiet() {
    local pid i=0 t0
    t0="$(ticks)"
    bash "$WAIT" "$1" --workers "N1.md" > "$2" 2>/dev/null &
    pid=$!
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt "$(( $3 * 10 ))" ] && [ "$(( $(ticks) - t0 ))" -lt 3 ]; do sleep 0.1; i=$((i + 1)); done
    if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; rc=124
    else wait "$pid"; rc=$?; fi
}

run_to_wake() {
    local out="$1" err="$2" pid i=0
    shift 2
    bash "$WAIT" "$@" > "$out" 2> "$err" &
    pid=$!
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 600 ]; do sleep 0.2; i=$((i + 1)); done
    if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; rc=124
    else wait "$pid"; rc=$?; fi
    digest_rc=$rc
}

printf '4' > "$STUB/stall"
tick_t0="$(ticks)"
bash "$STUB/tick.sh" > /dev/null &
tick_pid=$!
sleep 0.3
tick_mid=$(( $(ticks) - tick_t0 ))
wait "$tick_pid"
check "(10977) a tick still running is not counted, a finished one is" "0:1" "$tick_mid:$(( $(ticks) - tick_t0 ))"
rm -f "$STUB/stall" "$STUB/stalled"

# --- (8197) digest and urgent worker changes -------------------------------------------
# Removing the buffer splits three housekeeping events; putting BLOCKED in that
# buffer delays a worker who needs a ruling. Keep setup isolated from pool rows.
housekeeping_cases() (
    local digest_rc
    export HOUSEKEEPING_DIGEST_SECS=2 WAIT_SWEEP_SEC=1 CHIEF_WAIT_BOARD_STALE_MIN=0
    cat > "$STUB/digest-tick.sh" <<'EOF'
#!/usr/bin/env bash
[ ! -f "$STUB/stall" ] || { read -r stall < "$STUB/stall"; sleep "$stall"; : > "$STUB/stalled"; }
n=0; [ ! -f "$STUB/samples" ] || read -r n < "$STUB/samples"
n=$((n + 1)); printf '%s\n' "$n" > "$STUB/samples"
if [ -f "$STUB/urgent" ]; then
    [ "$n" -le 2 ] || exit 1
    if [ "$n" -eq 2 ]; then sed 's/tails=N1:ACK/tails=N1:BLOCKED/' "$STUB/digest.line"; exit 0; fi
elif [ "$n" -ge 2 ]; then
    sed 's/tails=N1:ACK/tails=N1:LIVE/' "$STUB/digest.line"; exit 0
fi
cat "$STUB/digest.line"
EOF
    cat > "$STUB/digest-sweep.sh" <<'EOF'
#!/usr/bin/env bash
[ ! -f "$STUB/swept" ] || exit 0
: > "$STUB/swept"
printf 'status-sweep moved=1 wake=1\n'
EOF
    sed 's/capacity=UNDERFILLED:7/capacity=ok/;s/board=ok/board=STALE:2h/;s/tails=N1:LIVE/tails=N1:ACK/' "$STUB/tick.line" > "$STUB/digest.line"
    export CHIEF_WAIT_TICK="$STUB/digest-tick.sh" WAIT_SWEEP_CMD="$STUB/digest-sweep.sh"
    printf '# chief\n\n## Results\n' > "$WORK/digest-chief.md"
    I="$(new_inbox digest)"
    timeout 9 bash "$WAIT" "$I" --doc "$WORK/digest-chief.md" --workers N1.md > "$WORK/digest.out" 2> "$WORK/digest.err"; digest_rc=$?
    check '(8197) three housekeeping events inside one window give one wake' '0:1:1' "$digest_rc:$(grep -c '^WAKE ' "$WORK/digest.out"):$(grep -c '^WAKE housekeeping .*board-stale.*status-sweep.*tick' "$WORK/digest.out")"
    check '(8197) the digest includes all three event payloads' '1:1:1' "$(grep -c '^board-stale board=STALE:2h' "$WORK/digest.out"):$(grep -c '^status-sweep status-sweep moved=1 wake=1' "$WORK/digest.out"):$(grep -c '^tick changed=tails ' "$WORK/digest.out")"

    export HOUSEKEEPING_DIGEST_SECS=30 WAIT_SWEEP_CMD="$STUB/off.sh"
    : > "$STUB/urgent"; rm -f "$STUB/samples"
    I="$(new_inbox urgent)"
    timeout 4 bash "$WAIT" "$I" --workers N1.md > "$WORK/urgent.out" 2> "$WORK/urgent.err"; digest_rc=$?
    check '(8197) a BLOCKED event wakes on its first changed sample, not after the housekeeping window' '0:1' "$digest_rc:$(grep -c '^WAKE tick .*tails' "$WORK/urgent.out")"
    check '(8197) an urgent exit retains the queued housekeeping' yes "$([ -s "$I.wait.housekeeping" ] && echo yes)"
    printf '%s\n' "$(( $(date +%s) - 31 ))" > "$I.wait.housekeeping.since"
    timeout 4 bash "$WAIT" "$I" --workers N1.md > "$WORK/resume.out" 2> "$WORK/resume.err"; digest_rc=$?
    check '(8197) a re-arm emits the due retained digest even when the tick fails' '0:1:1' "$digest_rc:$(grep -c '^WAKE housekeeping' "$WORK/resume.out"):$(grep -c '^board-stale board=STALE:2h' "$WORK/resume.out")"

    unset HOUSEKEEPING_DIGEST_SECS
    rm -f "$STUB/urgent" "$STUB/samples"
    I="$(new_inbox defaultwindow)"
    timeout 3 bash "$WAIT" "$I" --workers N1.md > "$WORK/default.out" 2> "$WORK/default.err"; digest_rc=$?
    check '(8197) the default window buffers housekeeping instead of waking at once' '124:0:yes' "$digest_rc:$(grep -c '^WAKE ' "$WORK/default.out"):$([ -s "$I.wait.housekeeping" ] && echo yes)"
    printf '%s\n' "$(( $(date +%s) - 901 ))" > "$I.wait.housekeeping.since"
    timeout 4 bash "$WAIT" "$I" --workers N1.md > "$WORK/defaultdue.out" 2> "$WORK/defaultdue.err"; digest_rc=$?
    check '(8197) the default window expires after 900 seconds' '0:1' "$digest_rc:$(grep -c '^WAKE housekeeping' "$WORK/defaultdue.out")"

    export HOUSEKEEPING_DIGEST_SECS=0
    rm -f "$STUB/urgent" "$STUB/samples"
    I="$(new_inbox unbatched)"
    timeout 4 bash "$WAIT" "$I" --workers N1.md > "$WORK/unbatched.out" 2> "$WORK/unbatched.err"; digest_rc=$?
    check '(8197) zero disables batching and preserves the original wake line' '0:WAKE board-stale board=STALE:2h' "$digest_rc:$(head -n1 "$WORK/unbatched.out")"

    local digest_case digest_kind
    export HOUSEKEEPING_DIGEST_SECS=30
    for digest_case in tick board-stale status-sweep deadline; do
        rm -f "$STUB/samples" "$STUB/swept"
        export WAIT_SWEEP_CMD="$STUB/off.sh"
        sed 's/capacity=UNDERFILLED:7/capacity=ok/;s/tails=N1:LIVE/tails=N1:ACK/' "$STUB/tick.line" > "$STUB/digest.line"
        I="$(new_inbox "write-$digest_case")"
        digest_kind="$digest_case"
        case "$digest_case" in
            board-stale) sed 's/board=ok/board=STALE:2h/' "$STUB/digest.line" > "$STUB/digest.new"; mv "$STUB/digest.new" "$STUB/digest.line" ;;
            status-sweep) export WAIT_SWEEP_CMD="$STUB/digest-sweep.sh" ;;
            deadline) digest_kind=tick ;;
        esac
        rm -f "$STUB/stall" "$STUB/stalled"
        if [ "$digest_case" = deadline ]; then mkdir "$I.wait.housekeeping.since"; printf '2\n' > "$STUB/stall"
        else mkdir "$I.wait.housekeeping"; fi
        run_to_wake "$WORK/write-$digest_case.out" "$WORK/write-$digest_case.err" "$I" --doc "$WORK/digest-chief.md" --workers N1.md
        rm -f "$STUB/stall"
        [ "$digest_case" != deadline ] || check "(8197) deadline fallback ran with the tick stall" yes "$([ -e "$STUB/stalled" ] && echo yes)"
        check "(8197) $digest_case buffer write failure wakes immediately once" '0:1:1' "$digest_rc:$(grep -c '^WAKE ' "$WORK/write-$digest_case.out"):$(grep -c "^WAKE $digest_kind " "$WORK/write-$digest_case.out")"
        case "$digest_case" in tick|deadline)
            check "(8197) $digest_case write failure does not advance the tick baseline" 1 "$(grep -c 'tails=N1:ACK' "$I.wait.state")"
            check "(8197) $digest_case fallback keeps the tick header and payload on separate lines" 'WAKE tick changed=tails usage=PROCEED:1' "$(head -n 1 "$WORK/write-$digest_case.out"):$(grep -c '^TICK .*tails=N1:LIVE' "$WORK/write-$digest_case.out")" ;;
        esac
    done

    cat > "$STUB/digest-focus.sh" <<'EOF'
#!/usr/bin/env bash
case " $* " in *" --status "*) cat "$STUB/focus.state" ;; *) echo run >> "$STUB/focus.runs" ;; esac
EOF
    export WAIT_FOCUS_CMD="$STUB/digest-focus.sh" WAIT_SWEEP_CMD="$STUB/digest-sweep.sh" WAIT_SWEEP_SEC=60
    local focus_state
    for focus_state in FAILED:example DIRTY:10m; do
        rm -f "$STUB/samples" "$STUB/swept"
        printf 'focus=%s\n' "$focus_state" > "$STUB/focus.state"
        I="$(new_inbox "focus-$focus_state")"
        printf '%s\n' "$(( $(date +%s) - 61 ))" > "$I.wait.sweep"
        timeout 4 bash "$WAIT" "$I" --doc "$WORK/digest-chief.md" --workers N1.md > "$WORK/focus-$focus_state.out" 2> "$WORK/focus-$focus_state.err"; digest_rc=$?
        check "(8197) $focus_state wakes immediately when a status sweep is buffered" "0:WAKE focus $focus_state" "$digest_rc:$(head -n 1 "$WORK/focus-$focus_state.out")"
        check "(8197) $focus_state leaves the simultaneous status sweep queued" 1 "$(grep -c '^status-sweep status-sweep moved=1 wake=1' "$I.wait.housekeeping")"
    done

    export WAIT_SWEEP_CMD="$STUB/off.sh"
    rm -f "$STUB/focus.runs"
    I="$(new_inbox focus-warn)"
    warn_poll() {
        printf 'focus=%s\n' "$1" > "$STUB/focus.state"
        printf '%s\n' "$(( $(date +%s) - 61 ))" > "$I.wait.sweep"
        timeout 3 bash "$WAIT" "$I" --doc "$WORK/digest-chief.md" --workers N1.md > "$WORK/$2.out" 2> "$WORK/$2.err"; digest_rc=$?
    }
    warn_poll 'WARN:cycle ZZ-1,ZZ-2' warn-cycle-first
    check '(9982) focus=WARN:cycle with two keys wakes once with the keys and the fix' '0:1:1' "$digest_rc:$(grep -c '^WAKE focus WARN:cycle ZZ-1,ZZ-2 ' "$WORK/warn-cycle-first.out"):$(grep -c 'cut or justify' "$WORK/warn-cycle-first.out")"
    warn_poll 'WARN:cycle ZZ-1,ZZ-2' warn-cycle-again
    check '(9982) the same key set polled again does not wake' '124:0' "$digest_rc:$(grep -c '^WAKE ' "$WORK/warn-cycle-again.out")"
    warn_poll 'WARN:cycle ZZ-1,ZZ-2, drift gh' warn-cycle-drift
    check '(9982) the same key set with a drift warning beside it does not wake again' '124:0' "$digest_rc:$(grep -c '^WAKE ' "$WORK/warn-cycle-drift.out")"
    warn_poll 'WARN:cycle ZZ-1,ZZ-3' warn-cycle-changed
    check '(9982) a changed key set wakes again' '0:1' "$digest_rc:$(grep -c '^WAKE focus WARN:cycle ZZ-1,ZZ-3 ' "$WORK/warn-cycle-changed.out")"
    warn_poll 'WARN:unknown ZZ-4' warn-unknown
    check '(9982) focus=WARN:unknown wakes with the key' '0:1' "$digest_rc:$(grep -c '^WAKE focus WARN:unknown ZZ-4 ' "$WORK/warn-unknown.out")"
    warn_poll 'WARN:chains render, cycle ZZ-5,ZZ-6' warn-joined
    check '(9982) a loop joined to another warning still wakes' '0:1' "$digest_rc:$(grep -c '^WAKE focus WARN:' "$WORK/warn-joined.out")"
    check '(9982) the refresh-start guard started no refresh for a WARN state' no "$([ -e "$STUB/focus.runs" ] && echo yes || echo no)"
    for focus_state in ok DIRTY:5m WARN:drift\ unknown WARN:chains\ render; do
        rm -f "$I.wait.focus"
        warn_poll "$focus_state" "warn-neg"
        check "(9982) negative control: focus=$focus_state does not wake" '124:0' "$digest_rc:$(grep -c '^WAKE ' "$WORK/warn-neg.out")"
    done
    export WAIT_FOCUS_CMD="$STUB/off.sh" WAIT_SWEEP_CMD="$STUB/off.sh" WAIT_SWEEP_SEC=1

    I="$(new_inbox readfailure)"
    printf 'tick changed=tails usage=PROCEED retained-payload\n' > "$I.wait.housekeeping"
    printf '%s\n' "$(( $(date +%s) - 31 ))" > "$I.wait.housekeeping.since"
    mkdir "$STUB/readfail"
    DIGEST_REAL_CAT="$(command -v cat)"
    export DIGEST_REAL_CAT DIGEST_READ_FAIL_PATH="$I.wait.housekeeping"
    cat > "$STUB/readfail/cat" <<'EOF'
#!/usr/bin/env bash
if [ "$#" -eq 1 ] && [ "$1" = "$DIGEST_READ_FAIL_PATH" ]; then exit 1; fi
exec "$DIGEST_REAL_CAT" "$@"
EOF
    chmod +x "$STUB/readfail/cat"
    export CHIEF_WAIT_TICK="$STUB/off.sh"
    PATH="$STUB/readfail:$PATH" timeout 2 bash "$WAIT" "$I" --workers N1.md > "$WORK/readfailure.out" 2> "$WORK/readfailure.err"; digest_rc=$?
    check '(8197) a failed payload read emits no wake and retains the queue' '124:0:yes' "$digest_rc:$(grep -c '^WAKE ' "$WORK/readfailure.out"):$([ -s "$I.wait.housekeeping" ] && echo yes)"
    timeout 4 bash "$WAIT" "$I" --workers N1.md > "$WORK/readrecover.out" 2> "$WORK/readrecover.err"; digest_rc=$?
    check '(8197) the next arm delivers the retained payload after reads recover' '0:1:1' "$digest_rc:$(grep -c '^WAKE housekeeping' "$WORK/readrecover.out"):$(grep -c '^tick .*retained-payload' "$WORK/readrecover.out")"

    # A pool-unresolved or unowned-prs wake is housekeeping unless its value changed since the last
    # digest: first sight and a changed set wake at once, an unchanged repeat joins the digest.
    sed 's/capacity=UNDERFILLED:7/capacity=ok/' "$STUB/tick.line" > "$STUB/okcap.line"
    cat > "$STUB/okcap-tick.sh" <<'EOF'
#!/usr/bin/env bash
cat "$STUB/okcap.line"
EOF
    export CHIEF_WAIT_TICK="$STUB/okcap-tick.sh" HOUSEKEEPING_DIGEST_SECS=30
    printf '# disposition HIMMEL-16 classification BLOCKED: needs slicing\n' > "$STUB/dispositions"
    I="$(new_inbox poolhk)"
    timeout 8 bash "$WAIT" "$I" --doc "$WORK/digest-chief.md" --workers N1.md > "$WORK/poolhk1.out" 2>/dev/null; digest_rc=$?
    check '(8197) the first sight of an unresolved pool wakes at once' '0:1' "$digest_rc:$(grep -c '^WAKE pool-unresolved' "$WORK/poolhk1.out")"
    timeout 6 bash "$WAIT" "$I" --doc "$WORK/digest-chief.md" --workers N1.md > "$WORK/poolhk2.out" 2>/dev/null; digest_rc=$?
    check '(8197) an unchanged unresolved pool does not wake again, it joins the digest' '124:0:1' "$digest_rc:$(grep -c '^WAKE ' "$WORK/poolhk2.out"):$(grep -c '^pool-unresolved ' "$I.wait.housekeeping")"
    printf '# disposition HIMMEL-16 classification BLOCKED: needs slicing\n# disposition HIMMEL-17 classification BLOCKED: needs slicing\n' > "$STUB/dispositions"
    timeout 8 bash "$WAIT" "$I" --doc "$WORK/digest-chief.md" --workers N1.md > "$WORK/poolhk3.out" 2>/dev/null; digest_rc=$?
    check '(8197) a changed unresolved set wakes at once' '0:1' "$digest_rc:$(grep -c '^WAKE pool-unresolved' "$WORK/poolhk3.out")"
    printf '%s\n' "$(( $(date +%s) - 31 ))" > "$I.wait.housekeeping.since"
    timeout 8 bash "$WAIT" "$I" --doc "$WORK/digest-chief.md" --workers N1.md > "$WORK/poolhk4.out" 2>/dev/null; digest_rc=$?
    check '(8197) the digest carries the buffered pool-unresolved line' '0:1' "$digest_rc:$(grep -c '^WAKE housekeeping kinds=pool-unresolved' "$WORK/poolhk4.out")"
    HOUSEKEEPING_DIGEST_SECS=0 timeout 6 bash "$WAIT" "$(new_inbox poolhk0)" --doc "$WORK/digest-chief.md" --workers N1.md > "$WORK/poolhk0.out" 2>/dev/null; digest_rc=$?
    check '(8197) zero keeps the unbatched pool-unresolved wake' '0:1' "$digest_rc:$(grep -c '^WAKE pool-unresolved' "$WORK/poolhk0.out")"
    rm -f "$STUB/dispositions"

    unowned_hk() { sed -e "s/ unowned-prs=[^ ]*//" -e "s/ bank=/ unowned-prs=$1 bank=/" "$STUB/okcap.line" > "$STUB/okcap.line.tmp" && mv "$STUB/okcap.line.tmp" "$STUB/okcap.line"; }
    export CHIEF_WAIT_UNOWNED_REWAKE_MIN=1
    unowned_hk '#2575:12m'
    I="$(new_inbox unownedhk)"
    timeout 6 bash "$WAIT" "$I" --workers N1.md > "$WORK/unhk1.out" 2>/dev/null; digest_rc=$?
    check '(8934) the first sight of an unowned PR joins the digest, no wake' '124:0:1' "$digest_rc:$(grep -c '^WAKE ' "$WORK/unhk1.out"):$(grep -c '^unowned-prs #2575:12m' "$I.wait.housekeeping")"
    touch -d '2 hours ago' "$I.wait.unowned"
    unowned_hk '#2575:13m'
    timeout 6 bash "$WAIT" "$I" --workers N1.md > "$WORK/unhk2.out" 2>/dev/null; digest_rc=$?
    check '(8197) the same unowned set past its re-wake window joins the digest, no wake' '124:0:1' "$digest_rc:$(grep -c '^WAKE ' "$WORK/unhk2.out"):$(grep -c '^unowned-prs #2575:13m' "$I.wait.housekeeping")"
    unowned_hk '#2575:14m,#2600:15m'
    timeout 6 bash "$WAIT" "$I" --workers N1.md > "$WORK/unhk3.out" 2>/dev/null; digest_rc=$?
    check '(8934) a PR joining the unowned set joins the digest, no wake' '124:0:1' "$digest_rc:$(grep -c '^WAKE ' "$WORK/unhk3.out"):$(grep -c '^unowned-prs #2575:14m,#2600:15m' "$I.wait.housekeeping")"
    unset CHIEF_WAIT_UNOWNED_REWAKE_MIN

    # The digest signature is the whole wake, not the unresolved lines alone: a capacity move to
    # UNDERFILLED, or a new dispatchable key, wakes at once even while the unresolved set is unchanged.
    sed 's/capacity=UNDERFILLED:7/capacity=ok/' "$STUB/tick.line" > "$STUB/okcap.line"
    printf '# disposition HIMMEL-16 classification BLOCKED: needs slicing\n' > "$STUB/dispositions"
    I="$(new_inbox poolcap)"
    timeout 8 bash "$WAIT" "$I" --doc "$WORK/digest-chief.md" --workers N1.md > "$WORK/poolcap1.out" 2>/dev/null
    timeout 5 bash "$WAIT" "$I" --doc "$WORK/digest-chief.md" --workers N1.md > "$WORK/poolcap2.out" 2>/dev/null; digest_rc=$?
    check '(8197) setup: the unchanged unresolved set at capacity=ok joins the digest' '124:0' "$digest_rc:$(grep -c '^WAKE ' "$WORK/poolcap2.out")"
    cp "$STUB/tick.line" "$STUB/okcap.line"
    timeout 8 bash "$WAIT" "$I" --doc "$WORK/digest-chief.md" --workers N1.md > "$WORK/poolcap3.out" 2>/dev/null; digest_rc=$?
    check '(8197) a move to capacity=UNDERFILLED with an unchanged unresolved set wakes at once' '0:1' "$digest_rc:$(grep -c '^WAKE pool-unresolved capacity=UNDERFILLED:7' "$WORK/poolcap3.out")"

    sed 's/capacity=UNDERFILLED:7/capacity=ok/' "$STUB/tick.line" > "$STUB/okcap.line"
    printf 'LOCAL\tHIMMEL-9001\tMedium\tv1\tfirst\tfiles=a.sh\n' > "$STUB/pool.rows"
    I="$(new_inbox poolkey)"
    timeout 8 bash "$WAIT" "$I" --doc "$WORK/digest-chief.md" --workers N1.md > "$WORK/poolkey1.out" 2>/dev/null
    timeout 5 bash "$WAIT" "$I" --doc "$WORK/digest-chief.md" --workers N1.md > "$WORK/poolkey2.out" 2>/dev/null; digest_rc=$?
    check '(8197) setup: the unchanged pool and unresolved set join the digest' '124:0' "$digest_rc:$(grep -c '^WAKE ' "$WORK/poolkey2.out")"
    printf 'LOCAL\tHIMMEL-9001\tMedium\tv1\tfirst\tfiles=a.sh\nLOCAL\tHIMMEL-9002\tMedium\tv1\tsecond\tfiles=b.sh\n' > "$STUB/pool.rows"
    timeout 8 bash "$WAIT" "$I" --doc "$WORK/digest-chief.md" --workers N1.md > "$WORK/poolkey3.out" 2>/dev/null; digest_rc=$?
    check '(8197) a new dispatchable key with stale unresolved lines wakes at once' '0:1' "$digest_rc:$(grep -c '^WAKE pool-unresolved' "$WORK/poolkey3.out")"
    rm -f "$STUB/pool.rows"

    I="$(new_inbox poolreturn)"
    timeout 8 bash "$WAIT" "$I" --doc "$WORK/digest-chief.md" --workers N1.md > "$WORK/poolret1.out" 2>/dev/null
    : > "$STUB/dispositions"
    timeout 5 bash "$WAIT" "$I" --doc "$WORK/digest-chief.md" --workers N1.md > "$WORK/poolret2.out" 2>/dev/null; digest_rc=$?
    check '(8197) a resolved pool clears the digest signature' '124:no' "$digest_rc:$([ -e "$I.wait.poolhk" ] && echo yes || echo no)"
    printf '# disposition HIMMEL-16 classification BLOCKED: needs slicing\n' > "$STUB/dispositions"
    timeout 8 bash "$WAIT" "$I" --doc "$WORK/digest-chief.md" --workers N1.md > "$WORK/poolret3.out" 2>/dev/null; digest_rc=$?
    check '(8197) a returning unresolved set wakes again at once' '0:1' "$digest_rc:$(grep -c '^WAKE pool-unresolved' "$WORK/poolret3.out")"
    rm -f "$STUB/dispositions"
    [ "$fails" -eq 0 ]
)
if ! housekeeping_cases; then fails=$((fails + 1)); fi
if [ "${1:-}" = housekeeping ]; then
    printf '\n%d failure(s)\n' "$fails"
    [ "$fails" -eq 0 ]
    exit "$?"
fi

# --- (rp) the pool grows from empty during one streak ------------------------------------
I="$(new_inbox rp)"
arm "$I" "$WORK/rp1.out" 6
check "(rp) the streak's first sample wakes with the empty pool" "0" "$rc"
check "(rp) the first wake prints POOL-EMPTY" "1" "$(grep -c '^POOL-EMPTY' "$WORK/rp1.out")"

c0="$(calls)"
arm "$I" "$WORK/rp2.out" 4
check "(rp) an unchanged empty pool does not wake again (rc 124)" "124" "$rc"
check "(rp) and the pool was re-probed while waiting" "yes" "$([ "$(calls)" -gt "$c0" ] && echo yes)"

printf 'LOCAL\tHIMMEL-9001\tMedium\tv1\tfirst\tfiles=a.sh\nLOCAL\tHIMMEL-9002\tMedium\tv1\tsecond\tfiles=b.sh\n' > "$STUB/pool.rows"
arm "$I" "$WORK/rp3.out" 6
check "(rp) a pool that grows from empty wakes (rc 0)" "0" "$rc"
check "(rp) the re-wake is an underfilled wake" "1" "$(wakes "$WORK/rp3.out")"
check "(rp) and it lists the new pool rows" "2" "$(grep -c "^LOCAL.$KP-900[12]" "$WORK/rp3.out")"

arm_quiet "$I" "$WORK/rp4.out" 4
check "(rp) the same pool on the next arm is one wake per change (rc 124)" "124" "$rc"

printf 'LOCAL\tHIMMEL-9001\tMedium\tv1\tfirst\tfiles=a.sh\nLOCAL\tHIMMEL-9003\tMedium\tv1\tthird\tfiles=c.sh\n' > "$STUB/pool.rows"
arm "$I" "$WORK/rp5.out" 6
check "(rp) a changed key set wakes (rc 0)" "0" "$rc"
check "(rp) the changed pool lists the new key" "1" "$(grep -c "^LOCAL.$KP-9003" "$WORK/rp5.out")"

: > "$STUB/pool.fail"
c0="$(calls)"
arm "$I" "$WORK/rp6.out" 4
check "(rp) a failed probe never wakes (rc 124)" "124" "$rc"
check "(rp) and the failed probe did run" "yes" "$([ "$(calls)" -gt "$c0" ] && echo yes)"
rm -f "$STUB/pool.fail"
: > "$STUB/pool.partial"
arm_quiet "$I" "$WORK/rp6b.out" 4
check "(rp) a timed-out probe's partial rows never wake (rc 124)" "124" "$rc"
rm -f "$STUB/pool.partial"
: > "$STUB/pool.slow"
c0="$(calls)"
arm "$I" "$WORK/rp6c.out" 10
check "(rp) a stalled probe never wakes (rc 124)" "124" "$rc"
check "(rp) a stalled probe is cut at CHIEF_WAIT_REPOOL_TIMEOUT, so the next probe still starts" "yes" "$([ "$(( $(calls) - c0 ))" -ge 2 ] && echo yes)"
rm -f "$STUB/pool.slow"
arm_quiet "$I" "$WORK/rp7.out" 4
check "(rp) a failed probe leaves the saved pool alone: the same pool stays quiet (rc 124)" "124" "$rc"

rm -f "$STUB/pool.rows"
arm_quiet "$I" "$WORK/rp8.out" 4
check "(rp) a pool that empties does not wake (rc 124)" "124" "$rc"
printf 'LOCAL\tHIMMEL-9001\tMedium\tv1\tfirst\tfiles=a.sh\n' > "$STUB/pool.rows"
arm "$I" "$WORK/rp9.out" 6
check "(rp) and regrowing from that empty pool wakes again (rc 0)" "0" "$rc"

# --- (rp-cad) the re-probe cadence: a young marker is not probed, a due probe restarts the clock ----
I="$(new_inbox rpcad)"
CHIEF_WAIT_UNDERFILL_REPOOL_SEC=3600 arm "$I" "$WORK/rpcad1.out" 6
check "(rp-cad) the streak's first sample wakes at once (rc 0)" "0" "$rc"
printf 'LOCAL\tHIMMEL-9004\tMedium\tv1\tfourth\tfiles=d.sh\n' > "$STUB/pool.rows"
c0="$(calls)"
CHIEF_WAIT_UNDERFILL_REPOOL_SEC=3600 arm "$I" "$WORK/rpcad2.out" 6
check "(rp-cad) a changed pool under a young marker does not wake (rc 124)" "124" "$rc"
check "(rp-cad) and the pool was not probed before the cadence is due" "0" "$(( $(calls) - c0 ))"
arm "$I" "$WORK/rpcad3.out" 6
check "(rp-cad) the same change wakes once the marker is due (rc 0)" "0" "$rc"

I="$(new_inbox rptouch)"
CHIEF_WAIT_UNDERFILL_REPOOL_SEC=4 arm "$I" "$WORK/rptouch1.out" 6
c0="$(calls)"
CHIEF_WAIT_UNDERFILL_REPOOL_SEC=4 arm "$I" "$WORK/rptouch2.out" 9
n="$(( $(calls) - c0 ))"
check "(rp-cad) an unchanged pool never wakes (rc 124)" "124" "$rc"
check "(rp-cad) a due probe with no change restarts the clock: probed at least once" "yes" "$([ "$n" -ge 1 ] && echo yes)"
check "(rp-cad) and not on every tick of the next 9 s (at most 3 probes, got $n)" "yes" "$([ "$n" -le 3 ] && echo yes)"

# --- (rp-ok) capacity back to ok ends the streak: the next streak wakes at once --------------
sed 's/ capacity=[^ ]*/ capacity=ok/' "$STUB/tick.line" > "$STUB/tick.line.tmp" && mv "$STUB/tick.line.tmp" "$STUB/tick.line"
arm "$I" "$WORK/rpok1.out" 3
sed 's/ capacity=[^ ]*/ capacity=UNDERFILLED:7/' "$STUB/tick.line" > "$STUB/tick.line.tmp" && mv "$STUB/tick.line.tmp" "$STUB/tick.line"
arm "$I" "$WORK/rpok2.out" 6
check "(rp-ok) a new streak after capacity=ok wakes at once (rc 0)" "0" "$rc"

# Replay 10-25: 52 To Do, 34 dropped (15 collision, 10 BLOCKED, 3 residual,
# 2 blocker, 2 label, 1 platform, 1 type), plus four in-flight tickets.
# A drop reason alone must not silence a ticket that needs the chief's decision.
rm -f "$STUB/pool.rows"  # the replay pool lists no row: a row left by (rp-cad) would keep an underfilled wake awake (9181)
: > "$STUB/dispositions"
for n in $(seq 1 56); do
    case "$n" in
        1[0-5]|[1-9]) reason="collision scripts/lib/held$n.sh held by worker N$n" ;;
        1[6-9]|2[0-5]) reason='classification BLOCKED: needs slicing' ;;
        2[6-8]) reason='residual-depth 1' ;;
        29|30) reason='blocker HIMMEL-999 (In Progress, live)' ;;
        31|32) reason='label operator-decision' ;;
        33) reason='platform (dropped-platform title)' ;;
        34) reason='type Epic' ;;
        5[3-6]) reason='in-flight owned by worker N99' ;;
        *) reason='listed LOCAL' ;;
    esac
    printf '# disposition HIMMEL-%s %s\n' "$n" "$reason" >> "$STUB/dispositions"
done
printf '# chief\n\n## Live state\n\n## Results\n' > "$WORK/replay-chief.md"
I="$(new_inbox replay)"
timeout 12 bash "$WAIT" "$I" --doc "$WORK/replay-chief.md" --workers N1.md > "$WORK/replay1.out" 2>/dev/null; rc=$?
check '(replay) undispositioned tickets wake pool-unresolved' 1 "$(grep -c '^WAKE pool-unresolved .*pool=56/4/21/35' "$WORK/replay1.out")"
check '(replay) BLOCKED keys are named by class' 1 "$(grep -c "^# pool-unresolved classification $KP-16 " "$WORK/replay1.out")"
check '(replay) listed but undispatched keys remain unresolved' 1 "$(grep -c "^# pool-unresolved listed $KP-35 " "$WORK/replay1.out")"
arm "$I" "$WORK/replay2.out" 4
check '(replay) an unchanged unresolved set joins the digest on the bounded cadence, no wake (8197)' 0:1 "$(grep -c '^WAKE ' "$WORK/replay2.out"):$(grep -c '^pool-unresolved ' "$I.wait.housekeeping")"
# Capacity is no excuse for silently dropping the open pool.
sed 's/ capacity=[^ ]*/ capacity=ok/' "$STUB/tick.line" > "$STUB/tick.line.tmp" && mv "$STUB/tick.line.tmp" "$STUB/tick.line"
I="$(new_inbox replayfull)"
timeout 12 bash "$WAIT" "$I" --doc "$WORK/replay-chief.md" --workers N1.md > "$WORK/replayfull.out" 2>/dev/null; rc=$?
check '(replay) a full fleet still wakes on an unresolved version pool' 1 "$(grep -c '^WAKE pool-unresolved' "$WORK/replayfull.out")"
# Explicit chief decisions clear only keys they actually name.
{
    printf '# chief\n\n## Live state\n'
    for n in $(seq 16 28) $(seq 31 52); do printf 'pool-disposition: HIMMEL-%s question operator decision 268\n' "$n"; done
    printf '\n## Results\n'
} > "$WORK/replay-chief.md"
timeout 4 bash "$WAIT" "$I" --doc "$WORK/replay-chief.md" --workers N1.md > "$WORK/replaydone.out" 2>/dev/null; rc=$?
check '(replay) when every key is dispositioned the pool wake stops' 124 "$rc"
sed 's/ capacity=[^ ]*/ capacity=UNDERFILLED:7/' "$STUB/tick.line" > "$STUB/tick.line.tmp" && mv "$STUB/tick.line.tmp" "$STUB/tick.line"
I="$(new_inbox replaydoneunderfill)"
timeout 4 bash "$WAIT" "$I" --doc "$WORK/replay-chief.md" --workers N1.md > "$WORK/replaydoneunderfill.out" 2>/dev/null; rc=$?
check '(replay) a fully dispositioned pool also stays quiet when underfilled' 124 "$rc"

# --- (tf) a failing tick never masks the pool: no sample, still a pool-unresolved wake ---
: > "$STUB/tick.fail"
printf '# chief\n\n## Live state\npool-disposition: HIMMEL-16 question operator decision 268\n\n## Results\n' > "$WORK/tf-chief.md"
printf '# disposition HIMMEL-16 classification BLOCKED: needs slicing\n# disposition HIMMEL-77 listed LOCAL\n' > "$STUB/dispositions"
I="$(new_inbox tickfail)"
timeout 8 bash "$WAIT" "$I" --doc "$WORK/tf-chief.md" --workers N1.md > "$WORK/tickfail.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check '(tf) a failing tick sample with an unresolved pool still wakes (rc 0)' 0 "$rc"
check '(tf) the wake is pool-unresolved and says the tick failed' 1 "$(grep -c '^WAKE pool-unresolved capacity=? ' "$WORK/tickfail.out")"
check '(tf) the failure stands in for the tick line' 'tick-fail samples=1 step=tick-exit:1' "$(sed -n 2p "$WORK/tickfail.out")"
check '(tf) the wake names the unresolved key' 1 "$(grep -c "^# pool-unresolved listed $KP-77 " "$WORK/tickfail.out")"
printf '# disposition HIMMEL-16 classification BLOCKED: needs slicing\n' > "$STUB/dispositions"
I="$(new_inbox tickfailquiet)"
timeout 4 bash "$WAIT" "$I" --doc "$WORK/tf-chief.md" --workers N1.md > "$WORK/tickfailquiet.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check '(tf) a failing tick with a dispositioned pool stays quiet' 124 "$rc"
rm -f "$STUB/tick.fail"
rm -f "$STUB/dispositions"

W1="$WORK/w1"; mkdir -p "$W1/mirror/HIMMEL" "$W1/rel/v1"
for k in HIMMEL-8001 HIMMEL-8102; do
    printf -- '---\nkey: "%s"\ntype: "Task"\nstatus: "To Do"\nstatusCategory: "To Do"\npriority: "High"\nlabels: ["standalone"]\nfixVersions: ["v1"]\nparent: null\ncreated: "x"\nupdated: "x"\nresolution: null\nresolved: null\nlinks:\n  blocks: []\n  blocked_by: []\n  relates: []\n---\n\n# %s: fixture\n\n## Description\n\nbody\n\n## Comments\n\n_(none)_\n' "$k" "$k" > "$W1/mirror/HIMMEL/$k.md"
done
READINESS_NOW_EPOCH=1800000000 HIMMEL_RELEASE_STATE_DIR="$W1/rel" bash "$HERE/readiness.sh" append v1 HIMMEL-8001 c --evidence x --blocker HIMMEL-8102 --by fixture --mirror "$W1/mirror/HIMMEL" > /dev/null 2>&1
printf '# chief\n\n## Live state\n\n## Results\n' > "$W1/chief.md"
printf '# dropped from v1: 2 of 2 To Do (listed 2)\n# disposition HIMMEL-8001 listed LOCAL\n# disposition HIMMEL-8005 listed LOCAL\n' > "$STUB/dispositions"
w1_wait() {
    NEXT_DISPATCH_MIRROR="$W1/mirror/HIMMEL" HIMMEL_RELEASE_STATE_DIR="$W1/rel" READINESS_NOW_EPOCH=1800007200 timeout 8 bash "$WAIT" "$(new_inbox "$1")" --doc "$W1/chief.md" --workers N1.md > "$WORK/$1.out" 2> /dev/null  # gnu-ok: Linux-only kit; pipefail-ok: none set
}
w1_wait w1-record
w1_n() { grep -c "^# pool-unresolved $2 HIMMEL-$3 " "$WORK/$1.out"; }
check '(W1) the unresolved key with no ruling is still named' 1 "$(w1_n w1-record listed 8005)"
check '(W1) a live c row removes its key from pool-unresolved' 0 "$(w1_n w1-record '.*' 8001)"
rm -f "$W1/rel/v1/readiness.jsonl"
w1_wait w1-norecord
check '(W1) with the record file removed the key is named again' 1 "$(w1_n w1-norecord listed 8001)"
rm -f "$STUB/dispositions"

printf -- '---\nkey: "HIMMEL-8002"\ntype: "Task"\nstatus: "To Do"\nstatusCategory: "To Do"\npriority: "High"\nlabels: ["standalone"]\nfixVersions: ["v1"]\nparent: null\ncreated: "x"\nupdated: "x"\nresolution: null\nresolved: null\nlinks:\n  blocks: []\n  blocked_by: []\n  relates: []\n---\n\n# HIMMEL-8002: fixture\n\n## Description\n\nbody\n\n## Comments\n\n_(none)_\n' > "$W1/mirror/HIMMEL/HIMMEL-8002.md"
HK=HIMMEL
w2_record() {
    READINESS_NOW_EPOCH=1800000000 HIMMEL_RELEASE_STATE_DIR="$W1/rel" bash "$HERE/readiness.sh" append v1 HIMMEL-8001 c --evidence x --blocker HIMMEL-8102 --by fixture --mirror "$W1/mirror/HIMMEL" > /dev/null 2>&1
    READINESS_NOW_EPOCH=1800000000 HIMMEL_RELEASE_STATE_DIR="$W1/rel" bash "$HERE/readiness.sh" append v1 HIMMEL-8002 d --evidence x --by fixture --mirror "$W1/mirror/HIMMEL" > /dev/null 2>&1
}
w2_wait() { # <inbox name> <seconds> [doc]
    NEXT_DISPATCH_MIRROR="$W1/mirror/HIMMEL" HIMMEL_RELEASE_STATE_DIR="$W1/rel" READINESS_NOW_EPOCH=1800007200 timeout "$2" bash "$WAIT" "$(new_inbox "$1")" --doc "${3:-$W1/chief.md}" --workers N1.md > "$WORK/$1.out" 2> /dev/null  # gnu-ok: Linux-only kit; pipefail-ok: none set
}
printf '# chief\n\n## Live state\npool-disposition: HIMMEL-9001 question operator decision 268\n\n## Results\n' > "$W1/chief-u.md"
w2_record
printf 'LOCAL\tHIMMEL-9001\tMedium\tv1\tfirst\tfiles=a.sh\n' > "$STUB/pool.rows"
# the underfilled form: both ruled keys leave the unresolved set, the pool still lists a row
printf '# dropped from v1: 3 of 3 To Do (listed 3)\n# disposition HIMMEL-8001 listed LOCAL\n# disposition HIMMEL-8002 listed LOCAL\n# disposition HIMMEL-9001 listed LOCAL\n' > "$STUB/dispositions"
w2_wait w2-under 8 "$W1/chief-u.md"
check '(W2) the underfilled wake carries the block heading' 1 "$(grep -c '^# readiness rows in v1' "$WORK/w2-under.out")"
check '(W2) the c row is listed with its blocker and age' 1 "$(grep -c "^# readiness-held c $HK-8001 blocker=$HK-8102 age=2h\$" "$WORK/w2-under.out")"
check '(W2) the d row is listed with no blocker' 1 "$(grep -c "^# readiness-held d $HK-8002 blocker=- age=2h\$" "$WORK/w2-under.out")"
check '(W2) it is the underfilled wake' 1 "$(grep -c '^WAKE underfilled ' "$WORK/w2-under.out")"
printf '# dropped from v1: 3 of 3 To Do (listed 3)\n# disposition HIMMEL-8001 listed LOCAL\n# disposition HIMMEL-8002 listed LOCAL\n# disposition HIMMEL-8005 listed LOCAL\n' > "$STUB/dispositions"
w2_wait w2-unres 8
check '(W2) the pool-unresolved wake carries the block heading' 1 "$(grep -c '^# readiness rows in v1' "$WORK/w2-unres.out")"
check '(W2) the pool-unresolved wake lists the c and d rows' 2 "$(grep -c "^# readiness-held [cd] $HK-800[12] " "$WORK/w2-unres.out")"
check '(W2) it is the pool-unresolved wake' 1 "$(grep -c '^WAKE pool-unresolved ' "$WORK/w2-unres.out")"
printf '# dropped from v1: 3 of 3 To Do (listed 3)\n# disposition HIMMEL-8001 listed LOCAL\n# disposition HIMMEL-8002 listed LOCAL\n# disposition HIMMEL-9001 listed LOCAL\n' > "$STUB/dispositions"
I="$(new_inbox w3-record)"
w3_arm() { NEXT_DISPATCH_MIRROR="$W1/mirror/HIMMEL" HIMMEL_RELEASE_STATE_DIR="$W1/rel" READINESS_NOW_EPOCH=1800007200 timeout "$2" bash "$WAIT" "$I" --doc "$W1/chief-u.md" --workers N1.md > "$WORK/$1.out" 2> /dev/null; rc=$?; }  # gnu-ok: Linux-only kit; pipefail-ok: none set
w3_arm w3-first 8
check '(W3) the first sample with the record wakes once' "0:1" "$rc:$(grep -c '^WAKE ' "$WORK/w3-first.out")"
w3_arm w3-second 5
check '(W3) the same pool sampled again with the record does not wake (rc 124)' "124:0" "$rc:$(grep -c '^WAKE ' "$WORK/w3-second.out")"
rm -f "$W1/rel/v1/readiness.jsonl"
I="$(new_inbox w3-norecord)"
w3_arm w3-norec 8
check '(W3) without the record the same pool wakes once as well, with no held line' "0:1:0" "$rc:$(grep -c '^WAKE ' "$WORK/w3-norec.out"):$(grep -c '^# readiness' "$WORK/w3-norec.out")"
rm -f "$STUB/dispositions" "$STUB/pool.rows"

# --- (rp-real) the waiter's pool output is the hand run's, drop summary included -----------
M="$WORK/mirror/HIMMEL"; mkdir -p "$M"
mk() { # <key> <labels json> <title> <body>
    printf -- '---\nkey: "%s"\ntype: "Task"\nstatus: "To Do"\nstatusCategory: "x"\npriority: "Medium"\nlabels: %s\nfixVersions: ["v1.0.1"]\nparent: null\nlinks:\n  blocks: []\n  blocked_by: []\n  relates: []\n---\n\n# %s: %s\n\n## Description\n\n%s\n\nDoD\n- the row is green\n\nProof\n- a RED row that fails before the change\n' \
        "$1" "$2" "$1" "$3" "$4" > "$M/$1.md"
}
mk HIMMEL-1 '["ps3-blocker"]' "pool head" "Edit scripts/lib/alpha.sh only."
mk HIMMEL-2 '[]' "plain current version" "Edit scripts/lib/beta.sh only."
printf 'v1.0.1\tfalse\t\n' > "$WORK/mirror/HIMMEL.versions.tsv"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/gh"
# shellcheck disable=SC2016  # the stub body is literal text, expanded when the stub runs
printf '#!/usr/bin/env bash\nfor k in "$@"; do printf "%%s\\tLOCAL-NATIVE\\tstub\\n" "$k"; done\n' > "$WORK/classify"
chmod +x "$WORK/gh" "$WORK/classify"
printf '{"schema":1,"legs":[]}\n' > "$WORK/fleet.json"
printf '# chief\n\n## Live state\n\n- priority: \n' > "$WORK/chief.md"
export NEXT_DISPATCH_MIRROR="$M" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify"
export TICKET_STATUS_STATE_DIR="$WORK/ts-none" HIMMEL_ADMISSIONS_LEDGER="$WORK/ledger-none.jsonl"
export CHIEF_WAIT_DISPATCH="$HERE/next-dispatchable.sh"
hand="$(bash "$HERE/next-dispatchable.sh" --priority-pool-only --top 7 --doc "$WORK/chief.md" --workers-from "$WORK/fleet.json" </dev/null 2>/dev/null)"
I="$(new_inbox rpreal)"
timeout 20 bash "$WAIT" "$I" --doc "$WORK/chief.md" --workers-from "$WORK/fleet.json" > "$WORK/rpreal.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(rp-real) the real dispatcher's pool wakes the waiter (rc 0)" "0" "$rc"
check "(rp-real) the pool in the wake block equals a hand run with the same flags" "$hand" "$(sed '1,2d;/^# version backlog/,$d;/^# rows left in /,$d;/^# disposition /d;/^# pool-unresolved /d;/^# dispatchable in /d' "$WORK/rpreal.out")"
check "(rp-real) the hand run lists the pool head" "1" "$(printf '%s\n' "$hand" | grep -c "$KP-1	")"
check "(rp-real) the wake block carries the drop summary once (a declared release runs no second pass)" "1" "$(grep -c '^# dropped from v1.0.1: 0 of 2 To Do (none)' "$WORK/rpreal.out")"

# --- (rp-workers) a live worker's ticket stays out of the pool: --workers-from reaches the dispatcher ---
mk HIMMEL-3 '["ps3-blocker"]' "second pool head" "Edit scripts/lib/gamma.sh only."
printf '# worker\n' > "$WORK/HIMMEL-1-held-worker.md"
printf '{"schema":1,"legs":[{"label":"held","doc":"%s"}]}\n' "$WORK/HIMMEL-1-held-worker.md" > "$WORK/fleet-held.json"
hand="$(bash "$HERE/next-dispatchable.sh" --priority-pool-only --top 7 --doc "$WORK/chief.md" --workers-from "$WORK/fleet-held.json" </dev/null 2>/dev/null)"
I="$(new_inbox rplegs)"
timeout 20 bash "$WAIT" "$I" --doc "$WORK/chief.md" --workers-from "$WORK/fleet-held.json" > "$WORK/rplegs.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(rp-workers) the hand run keeps the held worker's ticket out of the pool" "0" "$(printf '%s\n' "$hand" | grep -c "$KP-1	")"
check "(rp-workers) and lists the other pool head" "1" "$(printf '%s\n' "$hand" | grep -c "$KP-3	")"
check "(rp-workers) the pool in the wake block equals that hand run" "$hand" "$(sed '1,2d;/^# version backlog/,$d;/^# rows left in /,$d;/^# disposition /d;/^# pool-unresolved /d;/^# dispatchable in /d' "$WORK/rplegs.out")"

# --- 9335 WP1, WP2: the waiter's two passes while a sibling manifest cannot be read ---
# The fleet is readable (the stub tick succeeds and reads capacity=UNDERFILLED), one sibling manifest is not; a logging wrapper shows which passes ran.
TAB="$(printf '\t')"; WPD="$WORK/wp9335"; WPLOG="$WPD/dispatch.log"; mkdir -p "$WPD"; : > "$WPLOG"
cat > "$WPD/dispatch-log.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$WPLOG"
exec bash "$HERE/next-dispatchable.sh" "\$@"
EOF
wp_rows() { printf '%s\n' "$1" | grep -cE "^(LOCAL|LOCAL\\?|CLOUD|DESIGN|SERIES|RESUME|NEXT-TIER|STACKABLE)${TAB}" || true; }  # rows of a kind that lists work
WPOWN="$WPD/HIMMEL-nextleg-2026-11-18A-wp.fleet.json"
WPSIB="$WPD/HIMMEL-nextleg-2026-11-17A-wp.fleet.json"
printf '{"schema":1,"legs":[{"label":"held","doc":"%s"}]}\n' "$WORK/HIMMEL-1-held-worker.md" > "$WPOWN"
printf 'not json\n' > "$WPSIB"
WP_LINE="# owner unknown: the chief on HIMMEL-nextleg-2026-11-17A-wp (manifest HIMMEL-nextleg-2026-11-17A-wp.fleet.json unreadable)"
: > "$WPLOG"
hand="$(bash "$HERE/next-dispatchable.sh" --priority-pool-only --top 7 --doc "$WORK/chief.md" --workers-from "$WPOWN" </dev/null 2>/dev/null)"
I="$(new_inbox wp1a)"
CHIEF_WAIT_DISPATCH="$WPD/dispatch-log.sh" timeout 20 bash "$WAIT" "$I" --doc "$WORK/chief.md" --workers-from "$WPOWN" > "$WPD/wp1a.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
: > "$WPD/wp1a.log"; cp "$WPLOG" "$WPD/wp1a.log"
check "9335 WP1.a: the waiter exits 0 with a wake" "0" "$rc"
check "9335 WP1.a: the first line is the pool-unresolved wake" "WAKE pool-unresolved" "$(sed -n 1p "$WPD/wp1a.out" | cut -c1-20)"
check "9335 WP1.a: the wake block holds the owner-unknown line once" "1" "$(grep -cF -- "$WP_LINE" "$WPD/wp1a.out" || true)"
check "9335 WP1.a: the wake block lists no ticket row" "0" "$(wp_rows "$(cat "$WPD/wp1a.out")")"
check "9335 WP1.a: the dispatcher ran once" "1" "$(wc -l < "$WPD/wp1a.log" | tr -d ' ')"
check "9335 WP1.a: and that call is the priority-pool pass" "1" "$(grep -c -- '--priority-pool-only' "$WPD/wp1a.log" || true)"
check "9335 WP1.a: the pool in the wake block equals a hand run of pass 1's flags" "$hand" "$(sed '1,2d;/^# version backlog/,$d;/^# rows left in /,$d;/^# disposition /d;/^# pool-unresolved /d;/^# dispatchable in /d' "$WPD/wp1a.out")"
# WP1.b, WP1.c: a named manifest that is missing or not JSON gives the same withheld lists in both passes (hand runs)
for wp_kind in missing unreadable; do
    if [ "$wp_kind" = missing ]; then wp_man="$WPD/no-such-wp.fleet.json"; else wp_man="$WPD/bad-wp.fleet.json"; printf 'not json\n' > "$wp_man"; fi
    wp_id=WP1.b; [ "$wp_kind" = missing ] || wp_id=WP1.c
    wp_p1="$(bash "$HERE/next-dispatchable.sh" --priority-pool-only --top 7 --doc "$WORK/chief.md" --workers-from "$wp_man" </dev/null 2>/dev/null)"
    wp_p2="$(bash "$HERE/next-dispatchable.sh" --top 7 --doc "$WORK/chief.md" --workers-from "$wp_man" </dev/null 2>/dev/null)"
    check "9335 $wp_id: pass 1 lists no ticket row for a $wp_kind manifest" "0" "$(wp_rows "$wp_p1")"
    check "9335 $wp_id: pass 2 lists no ticket row for a $wp_kind manifest" "0" "$(wp_rows "$wp_p2")"
    check "9335 $wp_id: pass 1 holds one owner-unknown line naming the manifest as $wp_kind" "1" "$(printf '%s\n' "$wp_p1" | grep -cF -- "# owner unknown: the fleet (manifest $(basename "$wp_man") $wp_kind)" || true)"
    check "9335 $wp_id: pass 2 holds one owner-unknown line naming the manifest as $wp_kind" "1" "$(printf '%s\n' "$wp_p2" | grep -cF -- "# owner unknown: the fleet (manifest $(basename "$wp_man") $wp_kind)" || true)"
done
# WP2: pass 2 runs (a mirror whose version is released has no drop summary) and withholds the version backlog too
mkdir -p "$WPD/mirror2" && cp -R "$M" "$WPD/mirror2/HIMMEL"
printf 'v1.0.1\ttrue\t2026-01-01\n' > "$WPD/mirror2/HIMMEL.versions.tsv"
: > "$WPLOG"
I="$(new_inbox wp2)"
NEXT_DISPATCH_MIRROR="$WPD/mirror2/HIMMEL" CHIEF_WAIT_DISPATCH="$WPD/dispatch-log.sh" timeout 20 bash "$WAIT" "$I" --doc "$WORK/chief.md" --workers-from "$WPOWN" > "$WPD/wp2.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
cp "$WPLOG" "$WPD/wp2.log"
check "9335 WP2: the waiter exits 0 with a wake" "0" "$rc"
check "9335 WP2: the wake block holds no drop summary, so pass 2 runs" "0" "$(grep -c '^# dropped from' "$WPD/wp2.out" || true)"
check "9335 WP2: the dispatcher ran twice" "2" "$(wc -l < "$WPD/wp2.log" | tr -d ' ')"
check "9335 WP2: exactly one of the two calls is the priority-pool pass" "1" "$(grep -c -- '--priority-pool-only' "$WPD/wp2.log" || true)"
check "9335 WP2: both calls carry the fixture's manifest" "2" "$(grep -cF -- "--workers-from $WPOWN" "$WPD/wp2.log" || true)"
check "9335 WP2: the version backlog holds the owner-unknown line" "1" "$(sed -n '/^# version backlog/,$p' "$WPD/wp2.out" | grep -cF -- "$WP_LINE" || true)"
check "9335 WP2: the version backlog lists no ticket row" "0" "$(wp_rows "$(sed -n '/^# version backlog/,$p' "$WPD/wp2.out")")"
printf '{"schema":1,"workers":[]}\n' > "$WPSIB"
: > "$WPLOG"
I="$(new_inbox wp2c)"
NEXT_DISPATCH_MIRROR="$WPD/mirror2/HIMMEL" CHIEF_WAIT_DISPATCH="$WPD/dispatch-log.sh" timeout 20 bash "$WAIT" "$I" --doc "$WORK/chief.md" --workers-from "$WPOWN" > "$WPD/wp2c.out" 2>/dev/null
check "9335 WP2.ctl: with a valid sibling manifest the version backlog lists $KP-2" "1" "$(sed -n '/^# version backlog/,$p' "$WPD/wp2c.out" | grep -cF -- "LOCAL${TAB}${KP}-2" || true)"
check "9335 WP2.ctl: with a valid sibling manifest there is no owner-unknown line" "0" "$(grep -c '^# owner unknown' "$WPD/wp2c.out" || true)"

printf 'LOCAL\tHIMMEL-9001\tMedium\tv1\tfirst\tfiles=a.sh\n' > "$STUB/pool.rows"
for t7b_line in '# quota-pause QUOTA-PAUSE github graphql token=main remaining=0 floor=500 reset=unknown caller=next-dispatchable nothing-was-judged' \
    '# gh-stall GH-STALL github read timed out after 400s token=main caller=next-dispatchable nothing-was-judged'; do
    t7b_kind="${t7b_line#\# }"; t7b_kind="${t7b_kind%% *}"
    printf '%s\n' "$t7b_line" > "$STUB/pool.paused"
    I="$(new_inbox "t7b-$t7b_kind")"
    CHIEF_WAIT_DISPATCH="$STUB/dispatch.sh" CHIEF_WAIT_UNDERFILL_REPOOL_SEC=1800 CHIEF_WAIT_PAUSED_REPROBE_SEC=0 arm "$I" "$WORK/t7b-$t7b_kind-1.out" 4
    check "(T7b) a $t7b_kind pool does not wake (rc 124)" "124" "$rc"
    check "(T7b) a $t7b_kind pool writes no underfill marker" "no" "$([ -e "$I.wait.underfill" ] && echo yes || echo no)"
    check "(T7b) a $t7b_kind pool writes pool=paused to the pool-paused file" "pool=paused" "$(cat "$I.wait.poolpaused" 2>/dev/null)"
    check "(T7b) a $t7b_kind pool leaves the heartbeat line in the readers' format" "1" "$(grep -cE '^hb=[0-9]+ pid=[0-9]+ key=[^ ]+ tick=(ok|fail|-) state=(waiting|sampling|exited)( exit=[^ ]+)?$' "$I.wait")"
    rm -f "$STUB/pool.paused"
    CHIEF_WAIT_DISPATCH="$STUB/dispatch.sh" CHIEF_WAIT_UNDERFILL_REPOOL_SEC=1800 CHIEF_WAIT_PAUSED_REPROBE_SEC=0 run_to_wake "$WORK/t7b-$t7b_kind-2.out" /dev/null "$I" --workers N1.md
    check "(T7b) after a $t7b_kind pool the next good reading wakes (rc 0)" "0" "$rc"
    check "(T7b) after a $t7b_kind pool it is one underfill wake" "1" "$(wakes "$WORK/t7b-$t7b_kind-2.out")"
    check "(T7b) after a $t7b_kind pool the good reading removes the pool-paused file" "no" "$([ -e "$I.wait.poolpaused" ] && echo yes || echo no)"
done
: > "$STUB/pool.slow"
I="$(new_inbox t7b-killed)"
CHIEF_WAIT_DISPATCH="$STUB/dispatch.sh" CHIEF_WAIT_UNDERFILL_REPOOL_SEC=1800 CHIEF_WAIT_DISPATCH_TIMEOUT=1 arm "$I" "$WORK/t7b-killed.out" 6
check "(T7b) a probe its outer timeout killed does not wake (rc 124)" "124" "$rc"
check "(T7b) a probe its outer timeout killed writes no underfill marker" "no" "$([ -e "$I.wait.underfill" ] && echo yes || echo no)"
check "(T7b) a probe its outer timeout killed is read as paused" "pool=paused" "$(cat "$I.wait.poolpaused" 2>/dev/null)"
rm -f "$STUB/pool.slow" "$STUB/pool.rows"
printf '%s\n' '# quota-pause QUOTA-PAUSE github graphql token=main remaining=0 floor=500 reset=unknown caller=next-dispatchable nothing-was-judged' > "$STUB/pool.paused"
t7b_old=$(( $(date +%s) - 2000 ))
I="$(new_inbox t7b-repool)"
printf 'HIMMEL-9001\n' > "$I.wait.underfill"; touch -d "@$t7b_old" "$I.wait.underfill"  # gnu-ok: Linux-only kit
CHIEF_WAIT_DISPATCH="$STUB/dispatch.sh" CHIEF_WAIT_UNDERFILL_REPOOL_SEC=1800 arm "$I" "$WORK/t7b-repool.out" 4
check "(T7b) a paused repool probe does not wake (rc 124)" "124" "$rc"
check "(T7b) a paused repool probe leaves the underfill marker's age" "$t7b_old" "$(stat -c %Y "$I.wait.underfill" 2>/dev/null)"  # gnu-ok: Linux-only kit
check "(T7b) a paused repool probe leaves the underfill marker's key set" "HIMMEL-9001" "$(sed -n 1p "$I.wait.underfill" 2>/dev/null)"
I="$(new_inbox t7b-backoff)"
CHIEF_WAIT_DISPATCH="$STUB/dispatch.sh" CHIEF_WAIT_UNDERFILL_REPOOL_SEC=1800 CHIEF_WAIT_PAUSED_REPROBE_SEC=0 arm "$I" "$WORK/t7b-backoff1.out" 3
t7b_c0="$(calls)"
CHIEF_WAIT_DISPATCH="$STUB/dispatch.sh" CHIEF_WAIT_UNDERFILL_REPOOL_SEC=1800 CHIEF_WAIT_PAUSED_REPROBE_SEC=300 arm "$I" "$WORK/t7b-backoff2.out" 4
check "(T7b) a fresh pause is not probed again before CHIEF_WAIT_PAUSED_REPROBE_SEC" "$t7b_c0" "$(calls)"
check "(T7b) and it does not wake (rc 124)" "124" "$rc"
check "(T7b) and the held pause writes no underfill marker" "no" "$([ -e "$I.wait.underfill" ] && echo yes || echo no)"
sed 's/capacity=UNDERFILLED:7/capacity=ok/' "$STUB/tick.line" > "$STUB/tick.line.ok"
cp "$STUB/tick.line" "$STUB/tick.line.saved"; cp "$STUB/tick.line.ok" "$STUB/tick.line"
I="$(new_inbox t7b-watch)"
: > "$I.wait.pool"; touch -d "@$t7b_old" "$I.wait.pool"  # gnu-ok: Linux-only kit
CHIEF_WAIT_DISPATCH="$STUB/dispatch.sh" CHIEF_WAIT_UNDERFILL_REPOOL_SEC=1800 arm "$I" "$WORK/t7b-watch.out" 4
check "(T7b) a paused pool watch probe on a full fleet does not wake (rc 124)" "124" "$rc"
check "(T7b) a paused pool watch probe leaves its marker's age" "$t7b_old" "$(stat -c %Y "$I.wait.pool" 2>/dev/null)"  # gnu-ok: Linux-only kit
cp "$STUB/tick.line.saved" "$STUB/tick.line"
rm -f "$STUB/pool.paused" "$STUB/tick.line.ok" "$STUB/tick.line.saved"
I="$(new_inbox t7b-empty)"
rm -f "$STUB/stalled"
printf '7\n' > "$STUB/stall"
CHIEF_WAIT_DISPATCH="$STUB/dispatch.sh" CHIEF_WAIT_UNDERFILL_REPOOL_SEC=1800 run_to_wake "$WORK/t7b-empty.out" /dev/null "$I" --workers N1.md
rm -f "$STUB/stall"
check "(T7b) the empty-pool control ran with the tick stall" yes "$([ -e "$STUB/stalled" ] && echo yes)"
check "(T7b) RED control: a real empty pool still wakes (rc 0)" "0" "$rc"
check "(T7b) RED control: and says POOL-EMPTY" "1" "$(grep -c '^POOL-EMPTY' "$WORK/t7b-empty.out")"
mkdir -p "$WORK/t7b-quota"
printf '#!/usr/bin/env bash\ncase "$*" in *rateLimit* | "api -i user"*) printf "HTTP/2.0 403 Forbidden\\r\\nX-Ratelimit-Remaining: 0\\r\\n\\r\\n"; exit 1 ;; esac\nexit 0\n' > "$WORK/gh-out"
chmod +x "$WORK/gh-out"
I="$(new_inbox t7b-real)"
CHIEF_WAIT_DISPATCH="$HERE/next-dispatchable.sh" NEXT_DISPATCH_GH_CMD="$WORK/gh-out" HIMMEL_QUOTA_DIR="$WORK/t7b-quota" CHIEF_WAIT_UNDERFILL_REPOOL_SEC=1800 \
    timeout 10 bash "$WAIT" "$I" --doc "$WORK/chief.md" --workers-from "$WORK/fleet.json" > "$WORK/t7b-real.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(T7b) the real dispatcher paused on quota gives no underfill wake (rc 124)" "124" "$rc"
check "(T7b) and no underfill marker" "no" "$([ -e "$I.wait.underfill" ] && echo yes || echo no)"
check "(T7b) the real dispatcher's pause is read as paused" "pool=paused" "$(cat "$I.wait.poolpaused" 2>/dev/null)"

# --- (lp) the plain current-version rows are pool rows: 2 labelled heads and 5 plain tickets fill 7 of 7 ----
M="$WORK/mirror-lp/HIMMEL"; mkdir -p "$M"
mk HIMMEL-1 '["ps3-blocker"]' "pool head one" "Edit scripts/lib/alpha.sh only."
mk HIMMEL-3 '["ps3-blocker"]' "pool head two" "Edit scripts/lib/gamma.sh only."
for n in 10 11 12 13 14; do mk "HIMMEL-$n" '[]' "plain task $n" "Edit scripts/lib/plain$n.sh only."; done
printf 'v1.0.1\tfalse\t\n' > "$WORK/mirror-lp/HIMMEL.versions.tsv"
export NEXT_DISPATCH_MIRROR="$M"
I="$(new_inbox lp)"
timeout 20 bash "$WAIT" "$I" --doc "$WORK/chief.md" --workers-from "$WORK/fleet.json" > "$WORK/lp.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(lp) the LOW pool wakes the waiter (rc 0)" "0" "$rc"
check "(lp) the pool rows are listed" "2" "$(grep -c '^LOCAL.HIMMEL-[13]	' "$WORK/lp.out")"
check "(lp) every plain current-version To Do row is listed" "5" "$(grep -c "^LOCAL.$KP-1[0-4]	" "$WORK/lp.out")"
check "(lp) a pool row is not listed twice" "1" "$(grep -c "^LOCAL.$KP-1	" "$WORK/lp.out")"
check "(lp) a full pool runs no second pass, so the wake line carries no dispatchable count" "WAKE pool-unresolved capacity=UNDERFILLED:7 pool=7/0/0/7" "$(head -n1 "$WORK/lp.out")"

# --- (8134) the plain current-version rows are pool rows: one heading names the version, no
# dispatchable row is a disposition line, and no tier-4 drop line reaches the wake ----
check "(8134) the current-version rows sit under one '# dispatchable in <version>' heading" "1" "$(grep -c '^# dispatchable in v1.0.1' "$WORK/lp.out")"
check "(8134) the heading comes before the first ticket row" "yes" "$([ "$(grep -n '^# dispatchable in v1.0.1' "$WORK/lp.out" | head -n1 | cut -d: -f1)" -lt "$(grep -n '^LOCAL' "$WORK/lp.out" | head -n1 | cut -d: -f1)" ] && echo yes)"
check "(8134) no listed row is printed as a disposition line" "0" "$(grep -c '^# disposition .* listed ' "$WORK/lp.out")"
check "(8134) no ticket is dropped as outside the priority pool" "0" "$(grep -c 'outside the priority pool' "$WORK/lp.out")"
check "(8134) a full pool prints no version backlog" "0" "$(grep -c '^# version backlog' "$WORK/lp.out")"

# a labelled pool row of a later version comes after the current version's rows, under its own heading
M="$WORK/mirror-lp2/HIMMEL"; mkdir -p "$M"
for n in 10 11; do mk "HIMMEL-$n" '[]' "plain task $n" "Edit scripts/lib/plain$n.sh only."; done
mk HIMMEL-20 '["ps3-blocker"]' "labelled later version" "Edit scripts/lib/later20.sh only."
sed 's/\["v1.0.1"\]/["v1.0.2"]/' "$M/HIMMEL-20.md" > "$M/HIMMEL-20.md.tmp" && mv "$M/HIMMEL-20.md.tmp" "$M/HIMMEL-20.md"
printf 'v1.0.1\tfalse\t\nv1.0.2\tfalse\t\n' > "$WORK/mirror-lp2/HIMMEL.versions.tsv"
export NEXT_DISPATCH_MIRROR="$M"
I="$(new_inbox lp2)"
timeout 20 bash "$WAIT" "$I" --doc "$WORK/chief.md" --workers-from "$WORK/fleet.json" > "$WORK/lp2.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(8134) the current-version rows are listed before the later-version pool row" "HIMMEL-10,HIMMEL-11,HIMMEL-20" "$(grep '^LOCAL' "$WORK/lp2.out" | cut -f2 | paste -sd, -)"
check "(8134) the later-version pool row has its own heading after the current one" "yes" "$([ "$(grep -n '^# dispatchable in v1.0.1' "$WORK/lp2.out" | head -n1 | cut -d: -f1)" -lt "$(grep -n '^# dispatchable in other versions' "$WORK/lp2.out" | head -n1 | cut -d: -f1)" ] && echo yes)"

# --- (6604) a RESUME-HELD line is not a pool key: the pool signature ignores it ----------------
export CHIEF_WAIT_DISPATCH="$STUB/dispatch.sh"  # the sections above re-point it at the real dispatcher
rm -f "$STUB/dispositions"
printf 'LOCAL\tHIMMEL-9001\tMedium\tv1\tfirst\tfiles=a.sh\n' > "$STUB/pool.rows"
I="$(new_inbox rh)"
arm "$I" "$WORK/rh1.out" 6
check "(6604) the streak's first sample wakes with the pool (rc 0)" "0" "$rc"
printf 'LOCAL\tHIMMEL-9001\tMedium\tv1\tfirst\tfiles=a.sh\nRESUME-HELD HIMMEL-9005 by N4200\n' > "$STUB/pool.rows"
c0="$(calls)"
arm "$I" "$WORK/rh2.out" 5
check "(6604) the pool was re-probed with the RESUME-HELD line in it" "yes" "$([ "$(calls)" -gt "$c0" ] && echo yes)"
check "(6604) a RESUME-HELD line does not change the pool signature: no re-wake (rc 124)" "124" "$rc"
rm -f "$STUB/pool.rows"

# --- (6604) pool-stale= wakes once per newly stale disposition key ----------------------------
stale_line() { # <pool-stale value>
    sed "s/capacity=UNDERFILLED:7/capacity=ok pool-stale=$1/" "$STUB/tick.line.orig" > "$STUB/tick.line"
}
cp "$STUB/tick.line" "$STUB/tick.line.orig"
export CHIEF_WAIT_DISPATCH="$STUB/dispatch.sh"  # the sections above re-point it at the real dispatcher
rm -f "$STUB/pool.rows" "$STUB/dispositions" "$STUB/pool.fail" "$STUB/pool.slow" "$STUB/pool.partial"  # an empty, resolved pool: only pool-stale= can wake here
I="$(new_inbox st)"
stale_line '1:HIMMEL-7120'
arm "$I" "$WORK/st1.out" 15
check "(6604) a stale disposition key wakes the waiter (rc 0)" "0" "$rc"
check "(6604) the wake names the key" "WAKE pool-stale HIMMEL-7120" "$(head -n1 "$WORK/st1.out")"
arm_quiet "$I" "$WORK/st2.out" 4
check "(6604) the same stale key does not wake again on a re-arm" "124" "$rc"
stale_line '2:HIMMEL-7120,HIMMEL-6866'
arm "$I" "$WORK/st3.out" 15
check "(6604) a newly stale key wakes and names only the new key" "WAKE pool-stale HIMMEL-6866" "$(head -n1 "$WORK/st3.out")"
hs_dir="$WORK/hs-state"; mkdir -p "$hs_dir"
hs_doc="$WORK/hs-chief.md"
printf '# chief\n\n## Live state\npool-disposition: HIMMEL-9190 hold waits on PR 5002 upstream wake=pr:5002\n\n## Results\n' > "$hs_doc"
hs_line="$(python3 -I -c 'import hashlib, sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest()[:12])' "$(sed -n 's/^pool-disposition: //p' "$hs_doc")")"
printf '{"ts":"x","mode":"on","rows":[{"key":"HIMMEL-9190","verb":"hold","class":"wake","fired":false,"outside":true,"wake":"pr:5002","line":"%s"}],"prs":{"5002":"OPEN"}}\n' "$hs_line" > "$hs_dir/pool-holds-hs-chief.json"
mkdir -p "$WORK/hs-mirror/HIMMEL"
hs_val="$(TICK_STATE_DIR="$hs_dir" NEXT_DISPATCH_MIRROR="$WORK/hs-mirror/HIMMEL" bash "$HERE/tick.sh" --pool-stale --doc "$hs_doc" 2>/dev/null | sed -n 's/^pool-stale=//p')"
check "(9853) an outside-PR holds row makes the line stale through --pool-stale" "1:HIMMEL-9190" "$hs_val"
I2="$(new_inbox st-holds)"
stale_line "$hs_val"
arm "$I2" "$WORK/sh1.out" 15
check "(9853) one pool-stale wake per newly stale key: the outside-PR hold wakes" "WAKE pool-stale HIMMEL-9190" "$(head -n1 "$WORK/sh1.out")"
arm_quiet "$I2" "$WORK/sh2.out" 4
check "(9853) one pool-stale wake per newly stale key: the same stale set does not wake again" "124" "$rc"
stale_line '?'
arm_quiet "$I" "$WORK/st4.out" 4
check "(6604) an unreadable blocker (?) never wakes" "124" "$rc"
check "(6604) an unreadable blocker keeps the marker" "yes" "$([ -e "$I.wait.stale" ] && echo yes)"
stale_line '0'
arm_quiet "$I" "$WORK/st5.out" 4
check "(6604) pool-stale=0 never wakes" "124" "$rc"
check "(6604) pool-stale=0 clears the marker" "no" "$([ -e "$I.wait.stale" ] && echo yes || echo no)"
stale_line '1:HIMMEL-7120'
arm "$I" "$WORK/st6.out" 15
check "(6604) a key that left and rejoined wakes again" "WAKE pool-stale HIMMEL-7120" "$(head -n1 "$WORK/st6.out")"

# a tick that omits the field (a timeout or a failed gh read) or says skip keeps the marker
I="$(new_inbox st2)"
stale_line '1:HIMMEL-7120'
arm "$I" "$WORK/sm1.out" 15
check "(6604) the first stale key wakes (rc 0)" "0" "$rc"
sed 's/capacity=UNDERFILLED:7/capacity=ok/' "$STUB/tick.line.orig" > "$STUB/tick.line"  # no pool-stale field at all
arm_quiet "$I" "$WORK/sm2.out" 4
check "(6604) a tick without the field never wakes (rc 124)" "124" "$rc"
check "(6604) a tick without the field keeps the marker" "yes" "$([ -e "$I.wait.stale" ] && echo yes)"
stale_line 'skip'
arm "$I" "$WORK/sm3.out" 4
check "(6604) pool-stale=skip keeps the marker" "yes" "$([ -e "$I.wait.stale" ] && echo yes)"
stale_line '1:HIMMEL-7120'
arm_quiet "$I" "$WORK/sm4.out" 4
check "(6604) the key reported before the gap does not re-wake after it (rc 124)" "124" "$rc"

# a partial read (a key plus ?) merges into the marker and never shrinks it
I="$(new_inbox st3)"
stale_line '1:HIMMEL-7120,?'
arm "$I" "$WORK/sp1.out" 15
check "(6604) a partial read wakes for its readable key" "WAKE pool-stale HIMMEL-7120" "$(head -n1 "$WORK/sp1.out")"
stale_line '1:HIMMEL-6866,?'
arm "$I" "$WORK/sp2.out" 15
check "(6604) a later partial read wakes only for the key it adds" "WAKE pool-stale HIMMEL-6866" "$(head -n1 "$WORK/sp2.out")"
stale_line '1:HIMMEL-7120,?'
arm_quiet "$I" "$WORK/sp3.out" 4
check "(6604) a partial read never shrinks the marker: the first key stays quiet (rc 124)" "124" "$rc"
stale_line '2:HIMMEL-7120,HIMMEL-6866'
arm_quiet "$I" "$WORK/sp4.out" 4
check "(6604) the full read afterwards wakes nothing twice (rc 124)" "124" "$rc"
cp "$STUB/tick.line.orig" "$STUB/tick.line"

export TICK_STATE_DIR="$WORK/rf-state"
mkdir -p "$TICK_STATE_DIR" "$WORK/rf"
rf_doc="$WORK/rf/chief-rf.md"
printf '# chief\n' > "$rf_doc"
rf_tsv="$TICK_STATE_DIR/rm-refused-chief-rf.tsv"
rf_line() { sed "s/capacity=UNDERFILLED:7/capacity=ok${1:+ rm-refused=$1}/" "$STUB/tick.line.orig" > "$STUB/tick.line"; }
rf_arm() {
    local pid i=0 t0 cut=0
    [ "$3" -gt 4 ] || cut=3
    t0="$(ticks)"
    bash "$WAIT" "$1" --doc "$rf_doc" --workers N1.md > "$2" 2>/dev/null &
    pid=$!
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt "$(( $3 * 10 ))" ] && { [ "$cut" -eq 0 ] || [ "$(( $(ticks) - t0 ))" -lt "$cut" ]; }; do sleep 0.1; i=$((i + 1)); done
    if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; rc=124
    else wait "$pid"; rc=$?; fi
}
rf_wakes() { grep '^WAKE ' "$1" | paste -sd'|' -; }
printf 'ABC-2\tR-1\tname the operator words for ABC-2\t1\nABC-5\tR-2\tthe ask needs decision 9\t1\nABC-6\tR-4\tother\t0\n' > "$rf_tsv"
rf_line '3:ABC-2@R-1,ABC-5@R-2'
I="$(new_inbox rf)"
date -u +%Y-%m-%d > "$I.wait.refused.day"  # a digest already went out today: only the operator pairs wake here
rf_arm "$I" "$WORK/rf1.out" 15
check "(9853) one wake per new operator refused ask: one line per pair, naming key, ruling and fix" \
    "WAKE rm-refused ABC-2@R-1 — fix: name the operator words for ABC-2|WAKE rm-refused ABC-5@R-2 — fix: the ask needs decision 9" \
    "$(rf_wakes "$WORK/rf1.out")"
rf_arm "$I" "$WORK/rf2.out" 4
check "(9853) the same tsv again wakes nothing (rc 124)" 124 "$rc"
printf 'ABC-7\tR-3\tnew ask\t1\n' >> "$rf_tsv"
rf_line ''
rf_arm "$I" "$WORK/rf3.out" 4
check "(9853) a tick line without rm-refused= reads no tsv (rc 124)" 124 "$rc"
rf_line '4:ABC-2@R-1,ABC-5@R-2,ABC-7@R-3'
rf_arm "$I" "$WORK/rf4.out" 15
check "(9853) a new operator pair wakes once, naming only itself" "WAKE rm-refused ABC-7@R-3 — fix: new ask" "$(rf_wakes "$WORK/rf4.out")"
printf 'ABC-8\tR-5\tunknown key\t?\n' >> "$rf_tsv"
rm -f "$I.wait.refused.day"
rf_line '5:ABC-2@R-1,ABC-5@R-2,ABC-7@R-3'
rf_arm "$I" "$WORK/rf5.out" 15
check "(9853) a pair whose operator status is unknown is neither woken nor digested" "WAKE rm-refused-digest 1 new: ABC-6@R-4" "$(rf_wakes "$WORK/rf5.out")"
check "(9853) and stays out of the marker until its status is known" 0 "$(grep -c '^ABC-8@' "$I.wait.refused" 2>/dev/null)"

I="$(new_inbox rfd)"
: > "$rf_tsv"
for i in $(seq 101 125); do printf 'ABC-%s\tR-%s\tother\t0\n' "$i" "$i" >> "$rf_tsv"; done
rf_line '25:'
rf_arm "$I" "$WORK/rfd1.out" 15
check "(9853) 25 new non-operator refused asks give one digest line listing 20" \
    "WAKE rm-refused-digest 25 new: $(seq 101 120 | sed 's/.*/ABC-&@R-&/' | paste -sd, -)" "$(rf_wakes "$WORK/rfd1.out")"
printf 'ABC-126\tR-126\tother\t0\n' >> "$rf_tsv"
rf_line '26:'
rf_arm "$I" "$WORK/rfd2.out" 4
check "(9853) a second run the same day sends no digest (rc 124)" 124 "$rc"
check "(9853) the held-back pair stays out of the marker for the next day's digest" 0 "$(grep -c '^ABC-126@' "$I.wait.refused" 2>/dev/null)"
rl_tsv="$TICK_STATE_DIR/rm-lists-chief-rf.tsv"
rl_line() { sed "s/capacity=UNDERFILLED:7/capacity=ok $1/" "$STUB/tick.line.orig" > "$STUB/tick.line"; }
I="$(new_inbox rl)"
printf 'chief\tK-5\tR-5\tthe chief placed it for the demo\t\t\napart\tK-7\tR-7\tv2\tP-1\tv1\napart\tK-7\tR-9\tv2\tP-1\tv1\n' > "$rl_tsv"
rl_line 'chief-placed=1:K-5 ask-apart=2:K-7,K-7'
rf_arm "$I" "$WORK/rl1.out" 15
check "S1b: a new chief placement and a new apart tuple each wake once, the tuple once for its two rulings" \
    "WAKE chief-placed K-5 the chief placed it for the demo|WAKE ask-apart K-7 v2 parent P-1 v1" "$(rf_wakes "$WORK/rl1.out")"
rf_arm "$I" "$WORK/rl2.out" 4
check "S1b: the same lists again wake nothing (rc 124)" 124 "$rc"
printf 'apart\tK-7\tR-11\tv2\tP-1\tv3\n' >> "$rl_tsv"
rl_line 'chief-placed=1:K-5 ask-apart=3:K-7,K-7,K-7'
rf_arm "$I" "$WORK/rl3.out" 15
check "S1b: a parent that moved is a new tuple and wakes once" "WAKE ask-apart K-7 v2 parent P-1 v3" "$(rf_wakes "$WORK/rl3.out")"
printf 'chief\tK-6\tR-12\tanother\t\t\n' >> "$rl_tsv"
rl_line ''
rf_arm "$I" "$WORK/rl4.out" 4
check "S1b: a tick line without chief-placed= or ask-apart= reads no tsv (rc 124)" 124 "$rc"
unset TICK_STATE_DIR
cp "$STUB/tick.line.orig" "$STUB/tick.line"

# --- (8170) versionless operator work: the pool line reads INTAKE:<m>, and the wake names the
# candidates and the one command that files their INTAKE requests ----
export CHIEF_WAIT_DISPATCH="$STUB/dispatch.sh"
rm -f "$STUB/pool.fail" "$STUB/pool.slow" "$STUB/pool.partial" "$STUB/calls"
printf 'LOCAL\tHIMMEL-9001\tMedium\tv1\tfirst\tfiles=a.sh\n' > "$STUB/pool.rows"
: > "$STUB/pool.intake"
I="$(new_inbox intake)"
arm "$I" "$WORK/intake.out" 8
check "(8170) an INTAKE pool short of the slots wakes the waiter (rc 0)" "0" "$rc"
check "(8170) the wake carries the intake candidates line" "1" "$(grep -c "^# intake 3 for v1: $KP-901 $KP-902 $KP-905" "$WORK/intake.out")"
check "(8170) the wake names the INTAKE command and the rm-run" "1" "$(grep -c '^# INTAKE: .*release request.*--verb INTAKE --key <KEY> --to v1.*rm-run' "$WORK/intake.out")"
check "(8170) a short INTAKE pool still runs the second pass: the wake line carries dispatchable=" "1" "$(head -n1 "$WORK/intake.out" | grep -c 'dispatchable=')"
rm -f "$STUB/pool.intake" "$STUB/pool.rows"
I="$(new_inbox nointake)"
arm "$I" "$WORK/nointake.out" 8
check "(8170) a pool with no intake candidate prints no INTAKE command" "0" "$(grep -c '^# INTAKE: ' "$WORK/nointake.out")"

# --- (8336) no open version: the intake line names the keys, and the wake prints no --to command ----
for form in 'no-version-line:# intake 2: HIMMEL-901 HIMMEL-902' 'old-line:# intake 2 for no open version: HIMMEL-901 HIMMEL-902'; do
    printf 'LOCAL\tHIMMEL-9001\tMedium\tv1\tfirst\tfiles=a.sh\n' > "$STUB/pool.rows"
    printf '%s\n' "${form#*:}" > "$STUB/pool.intake"
    I="$(new_inbox "nov-${form%%:*}")"
    arm "$I" "$WORK/nov-${form%%:*}.out" 8
    check "(8336) $form: the wake names the intake keys" "1" "$(grep -c "^# intake 2.*$KP-901 $KP-902" "$WORK/nov-${form%%:*}.out")"
    check "(8336) $form: the wake prints no INTAKE command and no --to value" "0" "$(grep -c -e '^# INTAKE: ' -e '--to ' "$WORK/nov-${form%%:*}.out")"
done
# a version name with a space still gets its INTAKE command
printf 'LOCAL\tHIMMEL-9001\tMedium\tv1\tfirst\tfiles=a.sh\n' > "$STUB/pool.rows"
printf '%s\n' '# intake 2 for v1.2 beta: HIMMEL-901 HIMMEL-902' > "$STUB/pool.intake"
I="$(new_inbox spacever)"
arm "$I" "$WORK/spacever.out" 8
check "(8336) a version name with a space still gets the INTAKE command, shell-quoted as one --to argument" "1" "$(grep -c -F -e '--to v1.2\ beta ' "$WORK/spacever.out")"
rm -f "$STUB/pool.intake" "$STUB/pool.rows"

# --- (8349 P-A) stacked-series pool rows: a SERIES row names its tickets in field 3, tick.sh prints them as
# `# pool-keys`, and the waiter reads that line for the pool signature, the pool view and the second pass.
# RED control (pre-change waiter): the SERIES keys are missing from the signature (a changed series never re-wakes),
# from dispatchable=, and no row is classed SERIES.
export CHIEF_WAIT_DISPATCH="$STUB/dispatch.sh"
rm -f "$STUB/pool.fail" "$STUB/pool.slow" "$STUB/pool.partial" "$STUB/pool.intake" "$STUB/dispositions" "$STUB/pass2.rows"
printf 'LOCAL\tHIMMEL-9001\tMedium\tv1\tfirst\tfiles=a.sh\nSERIES\tLOCAL\tHIMMEL-9101,HIMMEL-9102\tHigh\tv1\tfiles=s.sh\n' > "$STUB/pool.rows"
I="$(new_inbox series)"
arm "$I" "$WORK/series1.out" 8
check "(8349) a pool with a SERIES row wakes (rc 0)" "0" "$rc"
check "(8349) the SERIES row is classed once, under its own heading" "1:1" "$(grep -c '^# dispatchable as one series worker' "$WORK/series1.out"):$(grep -c "^SERIES.LOCAL.$KP-9101,$KP-9102" "$WORK/series1.out")"
check "(8349) dispatchable= counts the series' tickets" "1" "$(head -n1 "$WORK/series1.out" | grep -c 'dispatchable=3')"
arm_quiet "$I" "$WORK/series2.out" 4
check "(8349) the same series pool does not wake again (rc 124)" "124" "$rc"
printf 'LOCAL\tHIMMEL-9001\tMedium\tv1\tfirst\tfiles=a.sh\nSERIES\tLOCAL\tHIMMEL-9101,HIMMEL-9103\tHigh\tv1\tfiles=s.sh\n' > "$STUB/pool.rows"
arm "$I" "$WORK/series3.out" 15
check "(8349) a series whose tickets changed wakes (rc 0)" "0" "$rc"

# a SERIES row only in the second pass is counted and listed once; one the pool already holds is not listed twice
printf 'LOCAL\tHIMMEL-9001\tMedium\tv1\tfirst\tfiles=a.sh\n' > "$STUB/pool.rows"
printf 'LOCAL\tHIMMEL-9001\tMedium\tv1\tfirst\tfiles=a.sh\nSERIES\tLOCAL\tHIMMEL-9201,HIMMEL-9202\tHigh\tv2\tfiles=t.sh\n' > "$STUB/pass2.rows"
I="$(new_inbox seriespass2)"
arm "$I" "$WORK/seriespass2.out" 8
check "(8349) a SERIES row only in the second pass is counted" "1" "$(head -n1 "$WORK/seriespass2.out" | grep -c 'dispatchable=3')"
check "(8349) and listed once in the version backlog" "1" "$(sed -n '/^# version backlog/,$p' "$WORK/seriespass2.out" | grep -c "^SERIES.LOCAL.$KP-9201,$KP-9202")"
printf 'SERIES\tLOCAL\tHIMMEL-9101,HIMMEL-9102\tHigh\tv1\tfiles=s.sh\n' > "$STUB/pool.rows"
cp "$STUB/pool.rows" "$STUB/pass2.rows"
I="$(new_inbox seriesboth)"
arm "$I" "$WORK/seriesboth.out" 8
check "(8349) a series row in both passes is not repeated in the version backlog" "0" "$(sed -n '/^# version backlog/,$p' "$WORK/seriesboth.out" | grep -c '^SERIES')"

# (spec I2) a pool with no series row prints byte for byte what the pre-change waiter printed (golden captured at base)
printf 'LOCAL\tHIMMEL-9001\tMedium\tv1\tfirst\tfiles=a.sh\nLOCAL\tHIMMEL-9002\tMedium\tv1\tsecond\tfiles=b.sh\n' > "$STUB/pool.rows"
printf 'LOCAL\tHIMMEL-9001\tMedium\tv1\tfirst\tfiles=a.sh\nLOCAL\tHIMMEL-9005\tLow\tv2\tlater\tfiles=e.sh\n' > "$STUB/pass2.rows"
I="$(new_inbox golden)"
arm "$I" "$WORK/golden.out" 8
check "(8349) a pool with no series row is byte-identical to the base golden" "same" "$(cmp -s "$WORK/golden.out" "$HERE/test-chief-wait-pool.golden" && echo same || echo differs)"
check "(9181) the underfilled wake line names the dispatchable keys its count is of" "WAKE underfilled capacity=UNDERFILLED:7 pool=? dispatchable=3 keys=HIMMEL-9001,HIMMEL-9002,HIMMEL-9005" "$(head -n1 "$WORK/golden.out")"
rm -f "$STUB/pool.rows" "$STUB/pass2.rows"

# --- (9181) keys= on every wake that lists work, a carried disposition never silences an underfilled fleet, a failed second pass is named
rm -f "$STUB/pass2.fail"
printf 'LOCAL\tHIMMEL-9001\tMedium\tv1\tfirst\tfiles=a.sh\n' > "$STUB/pool.rows"
printf '# disposition HIMMEL-9001 listed LOCAL\n# disposition HIMMEL-16 classification BLOCKED: needs slicing\n' > "$STUB/dispositions"
printf '# chief\n\n## Live state\n\n## Results\n' > "$WORK/k9181-open.md"
I="$(new_inbox keysunres)"
timeout 8 bash "$WAIT" "$I" --doc "$WORK/k9181-open.md" --workers N1.md > "$WORK/k9181a.out" 2>/dev/null
check "(9181) a pool-unresolved wake on numeric counts names the dispatchable keys" "WAKE pool-unresolved capacity=UNDERFILLED:7 pool=2/0/0/2 dispatchable=1 keys=HIMMEL-9001" "$(head -n1 "$WORK/k9181a.out")"
printf '# chief\n\n## Live state\npool-disposition: HIMMEL-9001 question operator decision 268\npool-disposition: HIMMEL-16 question operator decision 268\n\n## Results\n' > "$WORK/k9181-carried.md"
I="$(new_inbox keyscarried)"
timeout 8 bash "$WAIT" "$I" --doc "$WORK/k9181-carried.md" --workers N1.md > "$WORK/k9181b.out" 2>/dev/null
check "(9181) a carried disposition on every key still wakes an underfilled fleet that lists work" "WAKE underfilled capacity=UNDERFILLED:7 pool=2/0/2/0 dispatchable=1 keys=HIMMEL-9001" "$(head -n1 "$WORK/k9181b.out")"
rm -f "$STUB/pool.rows" "$STUB/dispositions"
: > "$STUB/pass2.fail"
I="$(new_inbox pass2fail)"
timeout 8 bash "$WAIT" "$I" --doc "$WORK/k9181-open.md" --workers N1.md > "$WORK/k9181c.out" 2>/dev/null
check "(9181) a failed second pass says backlog=unread and never prints dispatchable=0" "WAKE underfilled capacity=UNDERFILLED:7 pool=? backlog=unread" "$(head -n1 "$WORK/k9181c.out")"
rm -f "$STUB/pass2.fail"

rm -f "$STUB/pool.intake" "$STUB/dispositions" "$STUB/pass2.fail"
printf '# dropped from v1: 1 of 3 To Do (blocker 1)\nLOCAL\tHIMMEL-9001\tMedium\tv1\tfirst\tfiles=a.sh\n' > "$STUB/pool.rows"
printf 'LOCAL\tHIMMEL-9005\tLow\tv2\tlater\tfiles=e.sh\n' > "$STUB/pass2.rows"
printf '# disposition HIMMEL-9001 listed LOCAL\n# disposition HIMMEL-9010 blocker HIMMEL-1 (In Progress, live)\n' > "$STUB/dispositions"
I="$(new_inbox declared)"
timeout 8 bash "$WAIT" "$I" --doc "$WORK/k9181-open.md" --workers N1.md > "$WORK/declared.out" 2>/dev/null  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(declared) the wake counts only the version's own row" "WAKE pool-unresolved capacity=UNDERFILLED:7 pool=2/0/1/1 dispatchable=1 keys=HIMMEL-9001" "$(head -n1 "$WORK/declared.out")"
check "(declared) a later-version row is not offered" "0" "$(grep -c 'files=e.sh' "$WORK/declared.out")"
check "(declared) no version backlog block is printed" "0" "$(grep -c '^# version backlog' "$WORK/declared.out")"
check "(declared) the rows left in the version are named with their reason" "1:1" "$(grep -c '^# rows left in v1' "$WORK/declared.out"):$(grep -c '^# pool-left-out HIMMEL-9010 blocker HIMMEL-1 (In Progress, live)$' "$WORK/declared.out")"
rm -f "$STUB/pass2.rows" "$STUB/dispositions"

printf 'RESUME\tHIMMEL-9020\tMedium\tv1\tresume\tfiles=r.sh\tstatus=In Progress\tlast=-\n' > "$STUB/pool.rows"
I="$(new_inbox resume-short)"
timeout 8 bash "$WAIT" "$I" --doc "$WORK/k9181-open.md" --workers N1.md > "$WORK/resume-short.out" 2>/dev/null  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(resume) a short pool of RESUME rows reads above zero" "WAKE underfilled capacity=UNDERFILLED:7 pool=? dispatchable=1 keys=HIMMEL-9020" "$(head -n1 "$WORK/resume-short.out")"
: > "$STUB/pool.rows"; : > "$WORK/resume-full.md"
printf '# chief\n\n## Live state\n' > "$WORK/resume-full.md"
for n in 31 32 33 34 35 36 37; do
    printf 'RESUME\tHIMMEL-90%s\tMedium\tv1\tresume\tfiles=r%s.sh\tstatus=In Progress\tlast=-\n' "$n" "$n" >> "$STUB/pool.rows"
    printf '# disposition HIMMEL-90%s listed RESUME\n' "$n" >> "$STUB/dispositions"
    printf 'pool-disposition: HIMMEL-90%s question operator decision 268\n' "$n" >> "$WORK/resume-full.md"
done
printf '\n## Results\n' >> "$WORK/resume-full.md"
I="$(new_inbox resume-full)"
timeout 8 bash "$WAIT" "$I" --doc "$WORK/resume-full.md" --workers N1.md > "$WORK/resume-full.out" 2>/dev/null  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(resume) a full pool of dispositioned RESUME rows reads above zero" "WAKE underfilled capacity=UNDERFILLED:7 pool=7/0/7/0 dispatchable=7 keys=HIMMEL-9031,HIMMEL-9032,HIMMEL-9033,HIMMEL-9034,HIMMEL-9035,HIMMEL-9036,HIMMEL-9037" "$(head -n1 "$WORK/resume-full.out")"
rm -f "$STUB/pool.rows" "$STUB/dispositions"

mkdir -p "$STUB/nopy"
printf '#!/bin/sh\nexit 1\n' > "$STUB/nopy/python3"
chmod +x "$STUB/nopy/python3"
printf 'LOCAL\tHIMMEL-9040\tMedium\tv1\tfirst\tfiles=u.sh\n' > "$STUB/pool.rows"
I="$(new_inbox unread-summary)"
PATH="$STUB/nopy:$PATH" timeout 8 bash "$WAIT" "$I" --doc "$WORK/k9181-open.md" --workers N1.md > "$WORK/unread-summary.out" 2>/dev/null  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(unread) a pool the tick cannot read says backlog=unread and never prints dispatchable=0" "WAKE underfilled capacity=UNDERFILLED:7 backlog=unread" "$(head -n1 "$WORK/unread-summary.out")"
rm -f "$STUB/pool.rows"

S2="$WORK/s2"; S2M="$S2/mirror/HIMMEL"; mkdir -p "$S2M" "$S2/ho" "$S2/quota"
s2mk() {
    printf -- '---\nkey: "HIMMEL-%s"\ntype: "Task"\nstatus: "%s"\nstatusCategory: "%s"\npriority: "Medium"\nlabels: []\nfixVersions: ["v1.1.3"]\nparent: null\nlinks:\n  blocks: []\n  blocked_by: []\n  relates: []\n---\n\n# HIMMEL-%s: t\n\n## Description\n\nbody\n' \
        "$1" "$2" "$3" "$1" > "$S2M/HIMMEL-$1.md"
}
s2mk 901 Done Done
s2mk 902 "In Progress" "In Progress"
printf 'v1.1.3\tfalse\t\n' > "$S2/mirror/HIMMEL.versions.tsv"
cat > "$S2/ps-gh" <<'STUB'
#!/usr/bin/env bash
[ -z "${PS_GH_FAIL:-}" ] || exit 1
case "$*" in *"api graphql"*) ;; *) exit 1 ;; esac
out=""
for n in $(printf '%s\n' "$*" | grep -oE 'issueOrPullRequest\(number:[0-9]+\)' | grep -oE '[0-9]+'); do
    case "$n" in
        999001) v='{"__typename":"PullRequest","state":"CLOSED"}' ;;
        999002) v='{"__typename":"PullRequest","state":"MERGED"}' ;;
        *) v=null ;;
    esac
    out="${out:+$out,}\"p$n\":$v"
done
printf '{"data":{"repository":{%s}}}\n' "$out"
STUB
chmod +x "$S2/ps-gh"
export NEXT_DISPATCH_MIRROR="$S2M" HIMMEL_QUOTA_DIR="$S2/quota" TICK_GH_CMD="$S2/ps-gh" GH_READ_OFF=1
export CHIEF_WAIT_DISPATCH="$STUB/dispatch.sh"
printf 'LOCAL\tHIMMEL-%s\tMedium\tv1\trow\tfiles=a.sh\n' 141 142 143 145 > "$STUB/pool.rows"
printf '%s\n' '# disposition HIMMEL-141 listed LOCAL' '# disposition HIMMEL-142 listed LOCAL' '# disposition HIMMEL-143 listed LOCAL' \
    '# disposition HIMMEL-144 in-flight owned by worker N1' '# disposition HIMMEL-145 listed LOCAL' > "$STUB/dispositions"
cp "$STUB/dispositions" "$S2/rows"
s2w_doc() {
    local f="$1"; shift
    {
        printf '# chief\n\n## Live state\n'
        printf '%s\n' 'pool-disposition: HIMMEL-141 question after PR #999001 the doctor edit' \
            'pool-disposition: HIMMEL-142 question after HIMMEL-901 drafted in ZA-1' \
            'pool-disposition: HIMMEL-143 question after HIMMEL-902 the rest' \
            'pool-disposition: HIMMEL-144 question after PR #999002 shipped'
        [ "$#" -gt 0 ] || printf '%s\n' 'pool-disposition: HIMMEL-145 question operator decision 268'
        [ "$#" -eq 0 ] || printf '%s\n' "$@"
        printf '\n## Results\n'
    } > "$f"
}
s2w_produce() {
    local args out sf
    args=(--pool-stale --doc "$1" --prior "$TICK_STATE_DIR/none.out")
    [ -z "${3:-}" ] || args+=(--repo "$3")
    PS_GH_FAIL="$2" bash "$HERE/tick.sh" --pool-holds --doc "$1" ${3:+--repo "$3"} > /dev/null 2>&1
    out="$(PS_GH_FAIL="$2" bash "$HERE/tick.sh" "${args[@]}" 2>/dev/null)"
    sf="$(printf '%s\n' "$out" | sed -n 's/^# stale-file=//p')"
    [ -n "$sf" ] || return 1
    mkdir -p "$(dirname "$sf")"
    printf '%s\n' "$out" > "$sf"
    printf '%s' "$sf"
}
s2w_seq() {
    local name="$1" doc="$2" key="$3" repo="${4:-}" i fail sf inbox
    export TICK_STATE_DIR="$S2/st-$name"; rm -rf "$TICK_STATE_DIR"; mkdir -p "$TICK_STATE_DIR"
    inbox="$(new_inbox "s2-$name")"
    s2w_wakes=0; s2w_other=0; s2w_rcs=""
    for i in 1 2 3; do
        fail=""; [ "$i" -ne 2 ] || fail=1
        if [ "$i" -eq 3 ] && [ -n "$repo" ]; then git -C "$repo" -c user.name=t -c user.email=t@e.x -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q --allow-empty -m "c$i"; fi
        sf="$(s2w_produce "$doc" "$fail" "$repo")"
        s2w_line[i]="$(bash "$HERE/tick.sh" --pool-dispositions --doc "$doc" < "$S2/rows" 2>/dev/null | grep "^# pool-unresolved stale $key ")"
        s2w_det[i]="$(grep "^STALE-DISPOSITION $key " "$sf" 2>/dev/null)"
        timeout 6 bash "$WAIT" "$inbox" --doc "$doc" --workers N1.md > "$S2/$name-$i.out" 2>/dev/null  # gnu-ok: Linux-only kit; pipefail-ok: none set
        s2w_rcs="${s2w_rcs}${s2w_rcs:+:}$?"
        s2w_wakes=$((s2w_wakes + $(grep -c '^WAKE pool-unresolved' "$S2/$name-$i.out")))
        [ "$i" -eq 1 ] || s2w_other=$((s2w_other + $(grep -c '^WAKE ' "$S2/$name-$i.out")))
    done
}

s2w_doc "$S2/ho/r9.md"
export TICK_STATE_DIR="$S2/st-r9"; rm -rf "$TICK_STATE_DIR"; mkdir -p "$TICK_STATE_DIR"
s2w_produce "$S2/ho/r9.md" "" > /dev/null
I="$(new_inbox s2-r9)"
timeout 6 bash "$WAIT" "$I" --doc "$S2/ho/r9.md" --workers N1.md > "$S2/r9.out" 2>/dev/null  # gnu-ok: Linux-only kit; pipefail-ok: none set
p141='^# pool-unresolved stale HIMMEL-141 '
check "(R9) the waiter's pool pass lists a stale key as pool-unresolved" 1 "$(grep -c "$p141" "$S2/r9.out")"
check "(R9) the wake is pool-unresolved" 1 "$(grep -c '^WAKE pool-unresolved ' "$S2/r9.out")"

s2w_doc "$S2/ho/r9b.md"
s2w_seq r9b "$S2/ho/r9b.md" HIMMEL-141
check "(R9b) good, failed, good reads wake pool-unresolved once" "1:0" "$s2w_wakes:$s2w_other"
check "(R9b) the first sample ends on its wake and the others time out waiting" "0:124:124" "$s2w_rcs"
check "(R9b) the unresolved line names the key and its gone target" 1 "$(printf '%s\n' "${s2w_line[1]}" | grep -c 'its pool-disposition target is gone: PR#999001=CLOSED; re-decide or rewrite the line$')"
check "(R9b) the unresolved line is byte-identical for the good and the failed read" "${s2w_line[1]}" "${s2w_line[2]}"
check "(R9b) the failed read's detail line carries the prior verdict" "${s2w_det[1]} carried" "${s2w_det[2]}"

s2w_doc "$S2/ho/r9c-chief.md"
export TICK_STATE_DIR="$S2/st-r9c"; rm -rf "$TICK_STATE_DIR"; mkdir -p "$TICK_STATE_DIR"
s2w_produce "$S2/ho/r9c-chief.md" "" > /dev/null
I="$(new_inbox s2-r9c)"
HANDOVER_DIR="$S2/ho" timeout 6 bash "$WAIT" "$I" --doc r9c-chief.md --workers N1.md > "$S2/r9c.out" 2>/dev/null  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(R9c) a relative --doc under HANDOVER_DIR finds the same file" 1 "$(grep -c "$p141" "$S2/r9c.out")"

git init -q -b main "$S2/repo" && git -C "$S2/repo" -c user.name=t -c user.email=t@e.x -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q --allow-empty -m c0
s2_sha="$(git -C "$S2/repo" rev-parse --short=9 HEAD)"
s2w_doc "$S2/ho/r9d.md" "pool-disposition: HIMMEL-145 question after PR #999001 @$s2_sha"
s2w_seq r9d "$S2/ho/r9d.md" HIMMEL-145 "$S2/repo"
check "(R9d) an @sha stale line wakes once across a merge" "1:0" "$s2w_wakes:$s2w_other"
check "(R9d) the first sample ends on its wake and the others time out waiting" "0:124:124" "$s2w_rcs"
check "(R9d) its unresolved text carries @<sha>=within" 1 "$(printf '%s\n' "${s2w_line[1]}" | grep -c "PR#999001=CLOSED @$s2_sha=within; re-decide")"
check "(R9d) the unresolved line is byte-identical across the merge" "${s2w_line[1]}" "${s2w_line[3]}"
check "(R9d) the detail lines differ in their <n>-behind" "@$s2_sha=0-behind@$s2_sha=1-behind" "$(printf '%s' "${s2w_det[1]}" | grep -o "@$s2_sha=[0-9]*-behind")$(printf '%s' "${s2w_det[3]}" | grep -o "@$s2_sha=[0-9]*-behind")"
rm -f "$STUB/pool.rows" "$STUB/dispositions"

T11="$WORK/t11"; mkdir -p "$T11/bin" "$T11/root" "$T11/noroot" "$T11/quota"
printf 'himmel_github_token_vm2=ghp_CWREAD0123456789\n' > "$T11/root/.env"
: > "$T11/noroot/.env"
cat > "$T11/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in "pr checks") printf '%s %s %s %s\n' "${GH_TOKEN:-main}" "$1" "$2" "$3" >> "$T11_LOG"; printf 'pass\n'; exit 0 ;; esac
exit 1
EOF
printf '#!/usr/bin/env bash\nprintf "[PASS] 7. coverage\\n"\nexit 0\n' > "$T11/ready-check.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T11/disposition.sh"
sed 's/capacity=UNDERFILLED:7/capacity=ok/' "$STUB/tick.line" > "$T11/tick.line"
printf '#!/usr/bin/env bash\ncat "%s"\n' "$T11/tick.line" > "$T11/tick.sh"
chmod +x "$T11/bin/gh" "$T11/ready-check.sh" "$T11/disposition.sh" "$T11/tick.sh"
git init -q "$T11/repo"
T11_SHA=0123456789abcdef0123456789abcdef01234567
t11_wait() {
    local I d m
    I="$(new_inbox "t11-$1")"; : > "$I.announced"; : > "$T11/$1.log"
    d="$WORK/t11-$1/worker-N1-x.md"; printf '# worker on branch docs/x\n\n## Results\n- 11:00 READY 77 %s GREEN\n' "$T11_SHA" > "$d"
    m="$WORK/t11-$1/fleet.json"; printf '{"schema":1,"workers":[{"label":"N1","doc":"%s"}]}\n' "$d" > "$m"
    env -u GH_READ_OFF -u himmel_github_token_vm2 -u GH_TOKEN PATH="$T11/bin:$PATH" GH_READ_ENV_ROOT="$2" T11_LOG="$T11/$1.log" \
        HIMMEL_QUOTA_DIR="$T11/quota" HIMMEL_REPO="$T11/repo" HIMMEL_FLAG_AUTO_GO=off CHIEF_WAIT_TICK="$T11/tick.sh" \
        CHIEF_WAIT_READY_CHECK="$T11/ready-check.sh" CHIEF_WAIT_DISPOSITION="$T11/disposition.sh" \
        timeout 8 bash "$WAIT" "$I" --workers-from "$m" > "$T11/$1.out" 2>/dev/null  # gnu-ok: Linux-only kit; pipefail-ok: none set
    t11_out="$(grep '^WAKE ready ' "$T11/$1.out")"
}
t11_wait read "$T11/root"
check "T11: a READY wakes with its CI read" "ci=GREEN" "$(printf '%s\n' "$t11_out" | grep -oE 'ci=[A-Z]+')"
check "T11: the waiter's CI read goes out on the read token" "ghp_CWREAD0123456789 pr checks 77" "$(cat "$T11/read.log")"
t11_wait main "$T11/noroot"
check "T11 RED control: with no read token configured the READY still wakes" "ci=GREEN" "$(printf '%s\n' "$t11_out" | grep -oE 'ci=[A-Z]+')"
check "T11 RED control: its CI read goes out on main, as today" "main pr checks 77" "$(cat "$T11/main.log")"

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
