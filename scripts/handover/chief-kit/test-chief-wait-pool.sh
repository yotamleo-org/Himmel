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
export CHIEF_WAIT_TICK="$STUB/tick.sh" CHIEF_WAIT_USAGE="$STUB/bank.sh"
export CHIEF_WAIT_INTERVAL=1 CHIEF_WAIT_POLL_SEC=0.2 CHIEF_WAIT_FAIL_WAKE=1000
# the re-probe cadence is seconds here; the default is 30 minutes
export CHIEF_WAIT_UNDERFILL_REPOOL_SEC=1
# a re-probe is cut after a second here; the default is two minutes
export CHIEF_WAIT_REPOOL_TIMEOUT=1
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/off.sh"
printf '#!/usr/bin/env bash\nexit 2\n' > "$STUB/budget-off.sh"
export CHIEF_WAIT_PAGE_CMD="$STUB/off.sh" CHIEF_WAIT_BUDGET="$STUB/budget-off.sh"
export WAIT_SWEEP_CMD="$STUB/off.sh" WAIT_FOCUS_CMD="$STUB/off.sh"
export HIMMEL_DENIAL_ACK_DIR="$WORK/acks"

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
        if [ -f "$STUB/pool.rows" ] && [ -f "$STUB/pool.intake" ]; then cat "$STUB/pool.rows"; printf '# pool=%s/7,INTAKE:3\n# intake 3 for v1: HIMMEL-901 HIMMEL-902 HIMMEL-905\n' "$(wc -l < "$STUB/pool.rows" | tr -d ' ')"
        elif [ -f "$STUB/pool.rows" ]; then cat "$STUB/pool.rows"; printf '# pool=%s/7,LOW\n' "$(wc -l < "$STUB/pool.rows" | tr -d ' ')"
        else printf '# pool=0/7,LOW\nPOOL-EMPTY\n'; fi
        case " $* " in *" --dispositions "*) [ ! -f "$STUB/dispositions" ] || cat "$STUB/dispositions" ;; esac ;;
esac
EOF
export CHIEF_WAIT_DISPATCH="$STUB/dispatch.sh"
calls() { if [ -f "$STUB/calls" ]; then wc -l < "$STUB/calls" | tr -d ' '; else echo 0; fi; }
wakes() { grep -c '^WAKE underfilled' "$1" 2>/dev/null; }

new_inbox() { mkdir -p "$WORK/$1/consoles"; : > "$WORK/$1/consoles/c.md"; printf '%s' "$WORK/$1/consoles/c.md"; }
# arm <inbox> <outfile> <seconds>: one foreground arm that exits on a wake or after <seconds> (rc 124)
arm() { timeout "$3" bash "$WAIT" "$1" --workers "N1.md" > "$2" 2>/dev/null; rc=$?; }  # gnu-ok: Linux-only kit; pipefail-ok: none set

# --- (8197) digest and urgent worker changes -------------------------------------------
# Removing the buffer splits three housekeeping events; putting BLOCKED in that
# buffer delays a worker who needs a ruling. Keep setup isolated from pool rows.
housekeeping_cases() (
    local digest_rc
    export HOUSEKEEPING_DIGEST_SECS=2 WAIT_SWEEP_SEC=1 CHIEF_WAIT_BOARD_STALE_MIN=0
    cat > "$STUB/digest-tick.sh" <<'EOF'
#!/usr/bin/env bash
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
        if [ "$digest_case" = deadline ]; then mkdir "$I.wait.housekeeping.since"
        else mkdir "$I.wait.housekeeping"; fi
        timeout 4 bash "$WAIT" "$I" --doc "$WORK/digest-chief.md" --workers N1.md > "$WORK/write-$digest_case.out" 2> "$WORK/write-$digest_case.err"; digest_rc=$?
        check "(8197) $digest_case buffer write failure wakes immediately once" '0:1:1' "$digest_rc:$(grep -c '^WAKE ' "$WORK/write-$digest_case.out"):$(grep -c "^WAKE $digest_kind " "$WORK/write-$digest_case.out")"
        case "$digest_case" in tick|deadline)
            check "(8197) $digest_case write failure does not advance the tick baseline" 1 "$(grep -c 'tails=N1:ACK' "$I.wait.state")"
            check "(8197) $digest_case fallback keeps the tick header and payload on separate lines" 'WAKE tick changed=tails usage=PROCEED:1' "$(head -n 1 "$WORK/write-$digest_case.out"):$(grep -c '^TICK .*tails=N1:LIVE' "$WORK/write-$digest_case.out")" ;;
        esac
    done

    cat > "$STUB/digest-focus.sh" <<'EOF'
#!/usr/bin/env bash
case " $* " in *" --status "*) cat "$STUB/focus.state" ;; esac
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
check "(rp) and it lists the new pool rows" "2" "$(grep -c '^LOCAL.HIMMEL-900[12]' "$WORK/rp3.out")"

arm "$I" "$WORK/rp4.out" 4
check "(rp) the same pool on the next arm is one wake per change (rc 124)" "124" "$rc"

printf 'LOCAL\tHIMMEL-9001\tMedium\tv1\tfirst\tfiles=a.sh\nLOCAL\tHIMMEL-9003\tMedium\tv1\tthird\tfiles=c.sh\n' > "$STUB/pool.rows"
arm "$I" "$WORK/rp5.out" 6
check "(rp) a changed key set wakes (rc 0)" "0" "$rc"
check "(rp) the changed pool lists the new key" "1" "$(grep -c '^LOCAL.HIMMEL-9003' "$WORK/rp5.out")"

: > "$STUB/pool.fail"
c0="$(calls)"
arm "$I" "$WORK/rp6.out" 4
check "(rp) a failed probe never wakes (rc 124)" "124" "$rc"
check "(rp) and the failed probe did run" "yes" "$([ "$(calls)" -gt "$c0" ] && echo yes)"
rm -f "$STUB/pool.fail"
: > "$STUB/pool.partial"
arm "$I" "$WORK/rp6b.out" 4
check "(rp) a timed-out probe's partial rows never wake (rc 124)" "124" "$rc"
rm -f "$STUB/pool.partial"
: > "$STUB/pool.slow"
c0="$(calls)"
arm "$I" "$WORK/rp6c.out" 10
check "(rp) a stalled probe never wakes (rc 124)" "124" "$rc"
check "(rp) a stalled probe is cut at CHIEF_WAIT_REPOOL_TIMEOUT, so the next probe still starts" "yes" "$([ "$(( $(calls) - c0 ))" -ge 2 ] && echo yes)"
rm -f "$STUB/pool.slow"
arm "$I" "$WORK/rp7.out" 4
check "(rp) a failed probe leaves the saved pool alone: the same pool stays quiet (rc 124)" "124" "$rc"

rm -f "$STUB/pool.rows"
arm "$I" "$WORK/rp8.out" 4
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
: > "$STUB/dispositions"
for n in $(seq 1 56); do
    case "$n" in
        1[0-5]|[1-9]) reason="collision scripts/lib/held$n.sh held by worker N$n" ;;
        1[6-9]|2[0-5]) reason='classification BLOCKED: needs slicing' ;;
        2[6-8]) reason='residual-depth 1' ;;
        29|30) reason='blocker HIMMEL-999 (In Progress, live)' ;;
        31|32) reason='label operator-decision' ;;
        33) reason='platform (windows/wsl title)' ;;
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
check '(replay) BLOCKED keys are named by class' 1 "$(grep -c '^# pool-unresolved classification HIMMEL-16 ' "$WORK/replay1.out")"
check '(replay) listed but undispatched keys remain unresolved' 1 "$(grep -c '^# pool-unresolved listed HIMMEL-35 ' "$WORK/replay1.out")"
arm "$I" "$WORK/replay2.out" 4
check '(replay) unresolved keys re-wake unchanged on the bounded cadence' 1 "$(grep -c '^WAKE pool-unresolved' "$WORK/replay2.out")"
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
check '(tf) the wake names the unresolved key' 1 "$(grep -c '^# pool-unresolved listed HIMMEL-77 ' "$WORK/tickfail.out")"
printf '# disposition HIMMEL-16 classification BLOCKED: needs slicing\n' > "$STUB/dispositions"
I="$(new_inbox tickfailquiet)"
timeout 4 bash "$WAIT" "$I" --doc "$WORK/tf-chief.md" --workers N1.md > "$WORK/tickfailquiet.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check '(tf) a failing tick with a dispositioned pool stays quiet' 124 "$rc"
rm -f "$STUB/tick.fail"
rm -f "$STUB/dispositions"

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
check "(rp-real) the pool in the wake block equals a hand run with the same flags" "$hand" "$(sed '1,2d;/^# version backlog/,$d;/^# disposition /d;/^# pool-unresolved /d;/^# dispatchable in /d' "$WORK/rpreal.out")"
check "(rp-real) the hand run lists the pool head" "1" "$(printf '%s\n' "$hand" | grep -c 'HIMMEL-1	')"
check "(rp-real) the wake block carries the drop summary (the LOW pool's second pass prints its own too)" "2" "$(grep -c '^# dropped from v1.0.1: 0 of 2 To Do (none)' "$WORK/rpreal.out")"

# --- (rp-workers) a live worker's ticket stays out of the pool: --workers-from reaches the dispatcher ---
mk HIMMEL-3 '["ps3-blocker"]' "second pool head" "Edit scripts/lib/gamma.sh only."
printf '# worker\n' > "$WORK/HIMMEL-1-held-worker.md"
printf '{"schema":1,"legs":[{"label":"held","doc":"%s"}]}\n' "$WORK/HIMMEL-1-held-worker.md" > "$WORK/fleet-held.json"
hand="$(bash "$HERE/next-dispatchable.sh" --priority-pool-only --top 7 --doc "$WORK/chief.md" --workers-from "$WORK/fleet-held.json" </dev/null 2>/dev/null)"
I="$(new_inbox rplegs)"
timeout 20 bash "$WAIT" "$I" --doc "$WORK/chief.md" --workers-from "$WORK/fleet-held.json" > "$WORK/rplegs.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(rp-workers) the hand run keeps the held worker's ticket out of the pool" "0" "$(printf '%s\n' "$hand" | grep -c 'HIMMEL-1	')"
check "(rp-workers) and lists the other pool head" "1" "$(printf '%s\n' "$hand" | grep -c 'HIMMEL-3	')"
check "(rp-workers) the pool in the wake block equals that hand run" "$hand" "$(sed '1,2d;/^# version backlog/,$d;/^# disposition /d;/^# pool-unresolved /d;/^# dispatchable in /d' "$WORK/rplegs.out")"

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
check "(lp) every plain current-version To Do row is listed" "5" "$(grep -c '^LOCAL.HIMMEL-1[0-4]	' "$WORK/lp.out")"
check "(lp) a pool row is not listed twice" "1" "$(grep -c '^LOCAL.HIMMEL-1	' "$WORK/lp.out")"
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
arm "$I" "$WORK/st2.out" 4
check "(6604) the same stale key does not wake again on a re-arm" "124" "$rc"
stale_line '2:HIMMEL-7120,HIMMEL-6866'
arm "$I" "$WORK/st3.out" 15
check "(6604) a newly stale key wakes and names only the new key" "WAKE pool-stale HIMMEL-6866" "$(head -n1 "$WORK/st3.out")"
stale_line '?'
arm "$I" "$WORK/st4.out" 4
check "(6604) an unreadable blocker (?) never wakes" "124" "$rc"
check "(6604) an unreadable blocker keeps the marker" "yes" "$([ -e "$I.wait.stale" ] && echo yes)"
stale_line '0'
arm "$I" "$WORK/st5.out" 4
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
arm "$I" "$WORK/sm2.out" 4
check "(6604) a tick without the field never wakes (rc 124)" "124" "$rc"
check "(6604) a tick without the field keeps the marker" "yes" "$([ -e "$I.wait.stale" ] && echo yes)"
stale_line 'skip'
arm "$I" "$WORK/sm3.out" 4
check "(6604) pool-stale=skip keeps the marker" "yes" "$([ -e "$I.wait.stale" ] && echo yes)"
stale_line '1:HIMMEL-7120'
arm "$I" "$WORK/sm4.out" 4
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
arm "$I" "$WORK/sp3.out" 4
check "(6604) a partial read never shrinks the marker: the first key stays quiet (rc 124)" "124" "$rc"
stale_line '2:HIMMEL-7120,HIMMEL-6866'
arm "$I" "$WORK/sp4.out" 4
check "(6604) the full read afterwards wakes nothing twice (rc 124)" "124" "$rc"
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
check "(8170) the wake carries the intake candidates line" "1" "$(grep -c '^# intake 3 for v1: HIMMEL-901 HIMMEL-902 HIMMEL-905' "$WORK/intake.out")"
check "(8170) the wake names the INTAKE command and the rm-run" "1" "$(grep -c '^# INTAKE: .*release request.*--verb INTAKE --key <KEY> --to v1.*rm-run' "$WORK/intake.out")"
check "(8170) a short INTAKE pool still runs the second pass: the wake line carries dispatchable=" "1" "$(head -n1 "$WORK/intake.out" | grep -c 'dispatchable=')"
rm -f "$STUB/pool.intake" "$STUB/pool.rows"
I="$(new_inbox nointake)"
arm "$I" "$WORK/nointake.out" 8
check "(8170) a pool with no intake candidate prints no INTAKE command" "0" "$(grep -c '^# INTAKE: ' "$WORK/nointake.out")"

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
