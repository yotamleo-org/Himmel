#!/usr/bin/env bash
# test-chief-wait-r0.sh — Exercises chief-wait.sh's script relay (R0): with
# --doc and --workers-from, a worker whose tails= turns WRAPPED (or whose acts= turns
# MERGED) is wrapped by the waiter itself through worker-event.sh, with no wake:
#
#   (r0a) a MERGED worker that worker-event HANDLES: no wake, one digest line naming the
#         worker and PR; the next WAKE block prints the digest and clears it
#   (r0b) worker-event ESCALATE (rc 10): WAKE worker-event <line> out=<file>, once; a
#         re-arm does not wake for the same bullet again
#   (r0c) a refusal that only means "not yet" (rc=3 lock held): no WAKE worker-event,
#         retried on the next sample; a standing one falls back to WAKE tick
#   (r0h) the same refusal text on another rc (a timeout) is a worker-event wake
#   (r0d) a RETASK token in the bullet never reaches worker-event, the WAKE line or
#         the out file
#   (r0e) without --workers-from the waiter never calls worker-event
#   (r0f) two workers: N2's BLOCKED wakes before the relay sees N1's wrap;
#         a re-arm absorbs the wrap and the next Telegram wake delivers its digest
#   (r0g) two workers: N1's wrap and N2's change in one sample, then the manifest
#         move N1's wrap made: N2's change still wakes
#   (r0i) a window turning closable on the sample N1's wrap is absorbed still wakes
#   (r0j) the heartbeat is refreshed before each worker-event call of a pass
#   (r0k) a WRAPPED worker with a merged PR finishes beyond the old relay bound
#         without waking the chief
#   (r0l) a silent relay timeout names its reason in the wake and a non-empty out file
#   (r0m/n) the bound stays below heartbeat consumers and the header names it
#   (r0o) silent failure/SIGKILL diagnostics and output-bearing failures retain rc
#   (r0p) Telegram is serviced between pending slow wraps
#   (r0q) a standing retry does not starve a later worker's wrap
#   (r0r) retry rotation survives a Telegram wake and waiter re-arm
#   (10901-r1a/r1h) a READY that is its worker's newest marker (READY, READY!stale) is offered before
#         any WRAPPED or MERGED candidate
#   (10901-r1b/r1e) controls: no READY, or auto_go off, keeps the wraps in their order
#   (10901-r1c/r1g) controls: a READY its own WRAPPED follows is not offered ahead of that wrap, is still
#         relayed after it, and is never called while that wrap's close retries
#   (10901-r1d/r1k/r1m) a retried candidate moves behind the others; none starves another
#   (10901-r1f) a retried READY's record is cleared once it is handled
#   (10901-r1j) a newest-marker READY goes before a READY its own wrap follows
#   (10901-r1p) a newest-marker READY goes before another label's MERGED that escalates (the DT inbox)
#   (10901-r1n) a retryable READY and its worker's retryable MERGED alternate
#   (10901-r2a/r2g) a refused READY (ESCALATE auto-go, auto-go-error) wakes with WAKE worker-ready first
#   (10901-r2b/r2c/r2e/r2f/r2i) controls: no WAKE worker-ready for a wrap, flag off, GO-WRITTEN, another
#         rc, the stream service, or another escalation
#   (10901-r2h) the READY the relay wake names is not named a second time by the marker carry
#   Run only the wrap-bound regressions with --wrap-relay.
#   (hd)  holds=: a worker entering the set wakes once; ageing, a worker leaving and the set
#         emptying do not wake
#   (sz)  a SIZE-ESCALATE ledger row (size-override.sh) wakes once as `WAKE size rows=<n>`
#         with the new rows; a re-arm does not wake for a row already shown
#
# tick.sh, the bank verdict and worker-event.sh are stubbed (CHIEF_WAIT_TICK,
# CHIEF_WAIT_USAGE, CHIEF_WAIT_WORKER_EVENT): nothing closes a window here.
#
# Linux-only: this suite uses GNU
# timeout, so run-shell-tests.sh skips it off-Linux.
#
# Run: bash scripts/handover/chief-kit/test-chief-wait-r0.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WAIT="${CHIEF_WAIT:-$HERE/chief-wait.sh}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi
}
contains() { # <name> <haystack> <needle>
    case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (no '$3' in '$2')" ;; esac
}
lacks() { # <name> <haystack> <needle>
    case "$2" in *"$3"*) fail "$1 ('$3' in '$2')" ;; *) pass "$1" ;; esac
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/chief-wait-r0-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$WORK"' EXIT

STUB="$WORK/stub"
mkdir -p "$STUB"
cat > "$STUB/tick.sh" <<'EOF'
#!/usr/bin/env bash
# tick.seq (see tick_seq): each sample pops its first line, the last one stands
if [ -s "$STUB/tick.seq" ]; then
    head -n 1 "$STUB/tick.seq"
    if [ "$(wc -l < "$STUB/tick.seq")" -gt 1 ]; then
        tail -n +2 "$STUB/tick.seq" > "$STUB/tick.seq.new" && mv "$STUB/tick.seq.new" "$STUB/tick.seq"
    fi
else
    cat "$STUB/tick.line"
fi
EOF
cat > "$STUB/bank.sh" <<'EOF'
#!/usr/bin/env bash
cat "$STUB/bank"
EOF
# worker-event stub: records its args and stdin per call, prints le.out, exits le.rc.
cat > "$STUB/worker-event.sh" <<'EOF'
#!/usr/bin/env bash
n=$(( $(cat "$STUB/le.calls" 2>/dev/null || echo 0) + 1 ))
# the waiter's heartbeat epoch as this call starts, then the call count
sed -n 's/^hb=\([0-9]*\) .*/\1/p' "$HB_FILE" > "$STUB/le.hb.$n" 2>/dev/null
echo "$n" > "$STUB/le.calls"
printf '%s\n' "$*" > "$STUB/le.args"
cat > "$STUB/le.stdin"
cp "$STUB/le.stdin" "$STUB/le.stdin.$n"
[ -f "$STUB/le.sleep" ] && sleep "$(cat "$STUB/le.sleep")"
if [ -f "$STUB/le.timeout-once" ]; then rm -f "$STUB/le.timeout-once"; exit 124; fi
if [ -f "$STUB/le.retry-first" ] && grep -q '^N1 ' "$STUB/le.stdin"; then
    printf 'ESCALATE wrap-merged-failed rc=3 close-wrapped-worker: refusing - queue lock held\n'
    exit 10
fi
# le.by-marker: a WRAPPED line answers le.wrap-out / le.wrap-rc (default: rc 10 ambiguous-label), any other line falls through
if [ -f "$STUB/le.by-marker" ] && grep -q ' WRAPPED' "$STUB/le.stdin"; then
    if [ -f "$STUB/le.wrap-out" ]; then cat "$STUB/le.wrap-out"; else printf 'ESCALATE ambiguous-label\n'; fi
    if [ -f "$STUB/le.wrap-rc" ]; then exit "$(cat "$STUB/le.wrap-rc")"; fi
    exit 10
fi
# le.merged-escalates: a MERGED line answers rc 10 ESCALATE ambiguous-label, any other line falls through
if [ -f "$STUB/le.merged-escalates" ] && grep -q ' MERGED' "$STUB/le.stdin"; then
    printf 'ESCALATE ambiguous-label\n'
    exit 10
fi
# le.out.<n> / le.rc.<n>: the n-th call answers from its own file instead of le.out / le.rc
if [ -f "$STUB/le.out.$n" ] && [ ! -f "$STUB/le.echo" ]; then
    cat "$STUB/le.out.$n"
    if [ -f "$STUB/le.rc.$n" ]; then exit "$(cat "$STUB/le.rc.$n")"; fi
    exit "$(cat "$STUB/le.rc")"
fi
# le.rm: act like wrap-merged, drop N1 from the manifest and from the tick line
if [ -f "$STUB/le.rm" ]; then
    jq -c '.workers |= map(select(.label != "N1"))' "$4" > "$4.tmp" && mv "$4.tmp" "$4"
    rm -f "$STUB/tick.seq"
    cp "$STUB/tick.after" "$STUB/tick.line.new" && mv "$STUB/tick.line.new" "$STUB/tick.line"
fi
if [ -f "$STUB/le.echo" ]; then printf 'ESCALATE unfiled-residual: %s\n' "$(cat "$STUB/le.stdin")"
else cat "$STUB/le.out"; fi
if [ -f "$STUB/le.rc.$n" ]; then exit "$(cat "$STUB/le.rc.$n")"; fi
exit "$(cat "$STUB/le.rc")"
EOF
cat > "$STUB/budget-off.sh" <<'EOF'
#!/usr/bin/env bash
exit 2
EOF
export STUB
export CHIEF_WAIT_TICK="$STUB/tick.sh" CHIEF_WAIT_USAGE="$STUB/bank.sh"
export CHIEF_WAIT_WORKER_EVENT="$STUB/worker-event.sh" CHIEF_WAIT_BUDGET="$STUB/budget-off.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/sweep-off.sh"
export WAIT_SWEEP_CMD="$STUB/sweep-off.sh" WAIT_FOCUS_CMD="$STUB/sweep-off.sh"
# No row here reads the pool (test-chief-wait-pool.sh does): an absent dispatcher makes the
# probe a no-op, never a next-dispatchable.sh run over the real mirror inside the first sample.
export CHIEF_WAIT_DISPATCH="$STUB/no-dispatch.sh"
export CHIEF_WAIT_INTERVAL=1 CHIEF_WAIT_POLL_SEC=0.2 CHIEF_WAIT_FAIL_WAKE=1000
export HIMMEL_DENIAL_ACK_DIR="$WORK/acks"

# tick_text <tails> [acts]: prints a tick line with that tails= (and acts=, when given).
# It touches no stub file, so a sample never sees a line the test only means to queue.
tick_text() {
    printf 'TICK 03:00 hb=1m workers=N1:FRESH livestate=ok procs=2 models=x ceiling=ok atq=0 suites=0alive/0dead prs=#10 bank=5h8/wk15/codex=? fill=40 tails=%s%s inbox=none tick=UNKNOWN fleet=3/15 capacity=ok gql=4000/04:00 orphans=none nonces=ok legset=ok board=ok denials=none\n' \
        "$1" "${2:+ acts=$2}"
}
# tick_line <tails> [acts]: the stub's standing line. Written to a side file and moved
# over tick.line: a sample never reads half a line.
tick_line() { tick_text "$@" > "$STUB/tick.line.new" && mv "$STUB/tick.line.new" "$STUB/tick.line"; }
# tick_seq <tick line>...: the next samples serve these lines in order (one per
# sample), the last one standing. The order is the test's, not a sleep's.
tick_seq() {
    : > "$STUB/tick.seq.new"
    for l in "$@"; do printf '%s\n' "$l" >> "$STUB/tick.seq.new"; done
    mv "$STUB/tick.seq.new" "$STUB/tick.seq"
}
reset_stub() { rm -f "$STUB"/le.* "$STUB/tick.seq"; tick_line "N1:LIVE"; printf 'PROCEED\n' > "$STUB/bank"; printf 'HANDLED wrap-merged N1\n' > "$STUB/le.out"; echo 0 > "$STUB/le.rc"; }
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
# fleet <case>: a chief doc, a worker doc and a one-worker manifest; sets I, D, L, M.
fleet() {
    mkdir -p "$WORK/$1/consoles"; I="$WORK/$1/consoles/c.md"; : > "$I"
    D="$WORK/$1/chief.md"; printf '# chief\n' > "$D"
    L="$WORK/$1/HIMMEL-1-N1-a.md"; printf '# worker\n\n## Results\n- 09:00 LIVE — started\n' > "$L"
    M="$WORK/$1/chief.fleet.json"
    printf '{"schema":1,"workers":[{"doc":"%s","label":"N1"}]}\n' "$L" > "$M"
    export HB_FILE="$I.wait"
}
start() { # <inbox> <outfile> [tick args...]
    local inbox="$1" out="$2"; shift 2
    bash "$WAIT" "$inbox" "$@" > "$out" 2>"$out.err" &
    WPID=$!
}
# stop_waiter: SIGTERM the waiter and reap it, bounded. A waiter that outlives its SIGTERM by
# 10 s fails a named row and is killed, never an unbounded `wait` that runs the suite into its
# 600 s cap (a CI retry once stopped printing after the (r0s5) rows, where this wait is the only unbounded step).
stop_waiter() {
    local n=0
    kill "$WPID" 2>/dev/null
    while [ "$n" -lt 100 ] && kill -0 "$WPID" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
    if kill -0 "$WPID" 2>/dev/null; then
        fail "(teardown) the waiter outlived its SIGTERM by 10 s"
        kill -9 "$WPID" 2>/dev/null
    fi
    wait "$WPID" 2>/dev/null
}

# fleet2 <case>: fleet plus a second worker N2 in the manifest; sets L2 too.
fleet2() {
    fleet "$1"
    L2="$WORK/$1/HIMMEL-2-N2-b.md"; printf '# worker\n\n## Results\n- 09:00 LIVE — started\n' > "$L2"
    printf '{"schema":1,"workers":[{"doc":"%s","label":"N1"},{"doc":"%s","label":"N2"}]}\n' "$L" "$L2" > "$M"
}
fleet3() {
    fleet2 "$1"
    L3="$WORK/$1/HIMMEL-3-N3-c.md"; printf '# worker\n\n## Results\n- 09:00 LIVE — started\n' > "$L3"
    printf '{"schema":1,"workers":[{"doc":"%s","label":"N1"},{"doc":"%s","label":"N2"},{"doc":"%s","label":"N3"}]}\n' "$L" "$L2" "$L3" > "$M"
    printf 'N1\t0\nN2\t0\nN3\t0\n' > "$I.wait.ready"
}
wait_call() {
    local k=0
    while [ "$k" -lt "${2:-80}" ] && [ ! -s "$STUB/le.stdin.$1" ] && kill -0 "$WPID" 2>/dev/null; do sleep 0.1; k=$((k + 1)); done
}

# --- (r0k/l) the wrap bound and silent timeout diagnostics -------------------
# Keep the real timeout/exit status, but scale only worker-event's bound by 100:
# a 1.2s stub outlasts the old 90s bound (0.90s), not the longer wrap allowance.
# Other waiter subprocesses keep their real bounds.
REAL_TIMEOUT="$(command -v timeout)"
export REAL_TIMEOUT
mkdir -p "$WORK/bin"
cat > "$WORK/bin/timeout" <<'EOF'
#!/usr/bin/env bash
if [ "$#" -ge 5 ] && [ "$4" = bash ] && [ "$5" = "$CHIEF_WAIT_WORKER_EVENT" ]; then
    bound="$(printf '%d.%02d' "$(($3 / 100))" "$(($3 % 100))")"
    [ ! -f "$STUB/le.timeout" ] || bound=0.1
    shift 3
    exec "$REAL_TIMEOUT" -k 1 "$bound" "$@"
fi
exec "$REAL_TIMEOUT" "$@"
EOF
chmod +x "$WORK/bin/timeout"
relay_path="$PATH"
export PATH="$WORK/bin:$PATH"
reset_stub
fleet r0k
echo 1.2 > "$STUB/le.sleep"
start "$I" "$WORK/r0k.out" --doc "$D" --workers-from "$M"
wait_hb "$I" || fail "(r0k) no baseline heartbeat"
printf -- '- 10:00 READY #2566 abcdef GREEN\n- 10:30 MERGED #2566 → abcdef01\n- 11:00 WRAPPED — done\n' >> "$L"
tick_line "N1:WRAPPED" "N1:MERGED#2566"
n=0
while [ "$n" -lt 80 ] && [ ! -s "$I.wait.digest" ] && kill -0 "$WPID" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
check "(r0k) the slow wrap finishes beyond the old bound" "HANDLED wrap-merged N1" "$(cat "$I.wait.le-N1" 2>/dev/null)"
check "(r0k) WRAPPED is parsed and labelled, not an empty bullet" "N1 WRAPPED — done" "$(cat "$STUB/le.stdin" 2>/dev/null)"
check "(r0k) the completed wrap is recorded in the digest" "N1 wrap-merged 2566" "$(cat "$I.wait.digest" 2>/dev/null)"
check "(r0k) no chief wake" "" "$(cat "$WORK/r0k.out")"
stop_waiter

reset_stub
fleet r0l
echo 10 > "$STUB/le.sleep"
: > "$STUB/le.timeout"
start "$I" "$WORK/r0l.out" --doc "$D" --workers-from "$M"
wait_hb "$I" || fail "(r0l) no baseline heartbeat"
printf -- '- 11:00 WRAPPED — done\n' >> "$L"
tick_line "N1:WRAPPED"
wait_exit "$WPID"
check "(r0l) a silent timeout wakes the chief" "0" "$rc"
contains "(r0l) the wake explains the timeout" "$(head -n 1 "$WORK/r0l.out")" "WAKE worker-event ESCALATE relay-timeout N1 rc=124"
contains "(r0l) the wake names the output artifact" "$(head -n 1 "$WORK/r0l.out")" "out=$I.wait.le-N1"
if test -s "$I.wait.le-N1"; then pass "(r0l) test -s on the out file"; else fail "(r0l) test -s on the out file"; fi
contains "(r0l) the out file explains the timeout" "$(cat "$I.wait.le-N1" 2>/dev/null)" "ESCALATE relay-timeout N1 rc=124"
stop_waiter

reset_stub
fleet r0t
: > "$STUB/le.timeout-once"
start "$I" "$WORK/r0t.out" --doc "$D" --workers-from "$M"
wait_hb "$I" || fail "(r0t) no baseline heartbeat"
printf -- '- 11:00 WRAPPED — done\n' >> "$L"
tick_line "N1:WRAPPED"
n=0
while [ "$n" -lt 80 ] && [ ! -s "$I.wait.digest" ] && kill -0 "$WPID" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
check "(r0t) the close is attempted again after the timeout" "2" "$(cat "$STUB/le.calls" 2>/dev/null)"
check "(r0t) the second attempt is recorded in the digest" "N1 wrap-merged -" "$(cat "$I.wait.digest" 2>/dev/null)"
sleep 2.5
check "(r0t) it is not repeated after rc 0" "2" "$(cat "$STUB/le.calls" 2>/dev/null)"
check "(r0t) the one timeout wakes nothing" "" "$(cat "$WORK/r0t.out")"
stop_waiter
# --- (r0m/n) keep the relay within the heartbeat consumers' contract --------
# Match the variable name literally in the source.
# shellcheck disable=SC2016
check "(r0m) bound under stop guard" 1 "$(grep -cE 'timeout -k 5 ([1-9][0-9]|1[0-9][0-9]|2[0-8][0-9]) bash "\$leg_event_cmd"' "$WAIT")"
check "(r0n) header names relay bound" 1 "$(sed -n '/^#.*The relay adds at most one$/,+1p' "$WAIT" | grep -c '240 s')"

# --- (r0o) silent failures, SIGKILL and output-bearing failures keep the rc ---
for event_rc in 7 137; do
    reset_stub
    fleet "r0o-$event_rc"
    echo "$event_rc" > "$STUB/le.rc"; : > "$STUB/le.out"
    start "$I" "$WORK/r0o-$event_rc.out" --doc "$D" --workers-from "$M"
    wait_hb "$I" || fail "(r0o) no baseline heartbeat"
    printf -- '- 11:00 WRAPPED — done\n' >> "$L"; tick_line "N1:WRAPPED"
    wait_exit "$WPID"
    check "(r0o) rc $event_rc wakes" 0 "$rc"
    if [ "$event_rc" -eq 7 ]; then
        contains "(r0o) rc named" "$(head -n 1 "$WORK/r0o-$event_rc.out")" "ESCALATE relay-failed N1 rc=7"
    else
        contains "(r0o) SIGKILL named" "$(head -n 1 "$WORK/r0o-$event_rc.out")" "ESCALATE relay-timeout N1 rc=137"
    fi
    if test -s "$I.wait.le-N1"; then pass "(r0o) rc $event_rc artifact has a reason"; else fail "(r0o) rc $event_rc artifact has a reason"; fi
    stop_waiter
done
reset_stub
fleet r0o-output
echo 7 > "$STUB/le.rc"; printf 'worker-event failed during close\n' > "$STUB/le.out"
start "$I" "$WORK/r0o-output.out" --doc "$D" --workers-from "$M"
wait_hb "$I" || fail "(r0o) no output-case heartbeat"
printf -- '- 11:00 WRAPPED — done\n' >> "$L"; tick_line "N1:WRAPPED"
wait_exit "$WPID"
contains "(r0o) an output-bearing failure still records its rc" "$(head -n 1 "$WORK/r0o-output.out")" "rc=7 out=$I.wait.le-N1"
stop_waiter

# --- (r0p) service Telegram between handled OR retryable slow wraps ---------
for relay_mode in handled retry; do
    reset_stub
    fleet2 "r0p-$relay_mode"
    echo 1.2 > "$STUB/le.sleep"
    if [ "$relay_mode" = retry ]; then
        printf 'ESCALATE wrap-merged-failed rc=3 close-wrapped-worker: refusing - queue lock held\n' > "$STUB/le.out"
        echo 10 > "$STUB/le.rc"
    fi
    tick_line "N1:LIVE,N2:LIVE"
    start "$I" "$WORK/r0p-$relay_mode.out" --doc "$D" --workers-from "$M"
    wait_hb "$I" || fail "(r0p) no baseline heartbeat"
    printf -- '- 11:00 WRAPPED — done\n' >> "$L"; printf -- '- 11:00 WRAPPED — done\n' >> "$L2"
    tick_line "N1:WRAPPED,N2:WRAPPED"
    n=0
    while [ "$n" -lt 50 ] && [ ! -s "$STUB/le.calls" ]; do sleep 0.1; n=$((n + 1)); done
    printf -- '- 03:45 [telegram from=1 chat=2] urgent\n' >> "$I"
    wait_exit "$WPID"
    check "(r0p) Telegram wakes after one $relay_mode call" 0 "$rc"
    check "(r0p) $relay_mode leaves the second wrap for the next sample" 1 "$(cat "$STUB/le.calls" 2>/dev/null)"
    check "(r0p) the $relay_mode wake is Telegram" "WAKE telegram" "$(head -n 1 "$WORK/r0p-$relay_mode.out")"
    stop_waiter
done

# --- (r0q) a standing retry must not starve the next worker ------------------
reset_stub
fleet2 r0q
: > "$STUB/le.retry-first"
printf 'HANDLED wrap-merged N2\n' > "$STUB/le.out"
printf -- '- 11:00 WRAPPED — done\n' >> "$L"
printf -- '- 11:00 WRAPPED — done\n' >> "$L2"
tick_line "N1:WRAPPED,N2:WRAPPED"
start "$I" "$WORK/r0q.out" --doc "$D" --workers-from "$M"
n=0
while [ "$n" -lt 80 ] && [ ! -s "$STUB/le.stdin.3" ] && kill -0 "$WPID" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
check "(r0q) first sample attempts N1" "N1 WRAPPED — done" "$(cat "$STUB/le.stdin.1" 2>/dev/null)"
check "(r0q) next sample reaches N2 despite N1 retry" "N2 WRAPPED — done" "$(cat "$STUB/le.stdin.2" 2>/dev/null)"
check "(r0q) later worker completes its wrap" "N2 wrap-merged -" "$(cat "$I.wait.digest" 2>/dev/null)"
check "(r0q) N1 stays retryable after N2 completes" "N1 WRAPPED — done" "$(cat "$STUB/le.stdin.3" 2>/dev/null)"
stop_waiter

# --- (r0r) retry rotation survives a Telegram wake and waiter re-arm --------
reset_stub
fleet2 r0r
: > "$STUB/le.retry-first"
echo 1.2 > "$STUB/le.sleep"
printf 'HANDLED wrap-merged N2\n' > "$STUB/le.out"
printf -- '- 11:00 WRAPPED — done\n' >> "$L"
printf -- '- 11:00 WRAPPED — done\n' >> "$L2"
printf 'N999\n' > "$I.wait.r0-next"
tick_line "N1:WRAPPED,N2:WRAPPED"
start "$I" "$WORK/r0r-first.out" --doc "$D" --workers-from "$M"
n=0
while [ "$n" -lt 50 ] && [ ! -s "$STUB/le.stdin.1" ]; do sleep 0.1; n=$((n + 1)); done
printf -- '- 03:45 [telegram from=1 chat=2] first\n' >> "$I"
wait_exit "$WPID"
check "(r0r) stale cursor starts in plain order" "N1 WRAPPED — done" "$(cat "$STUB/le.stdin.1" 2>/dev/null)"
check "(r0r) first waiter yields after one retry" 1 "$(cat "$STUB/le.calls" 2>/dev/null)"
stop_waiter
start "$I" "$WORK/r0r-rearm.out" --doc "$D" --workers-from "$M"
n=0
while [ "$n" -lt 50 ] && [ ! -s "$STUB/le.stdin.2" ]; do sleep 0.1; n=$((n + 1)); done
printf -- '- 03:46 [telegram from=1 chat=2] second\n' >> "$I"
wait_exit "$WPID"
check "(r0r) re-armed waiter starts with N2" "N2 WRAPPED — done" "$(cat "$STUB/le.stdin.2" 2>/dev/null)"
contains "(r0r) later worker wraps across re-arm" "$(cat "$WORK/r0r-rearm.out")" "absorbed since last wake: wraps=1 (N2)"
stop_waiter

# The flag reads a fixture registry with auto_go off for the rest of the suite, whatever the real flags.tsv says.
printf 'auto_go\toff\tfeature\tHIMMEL-8349\tHIMMEL-8404\t2099-01-01\tfixture\n' > "$WORK/flags.tsv"
export HIMMEL_FLAGS_TSV="$WORK/flags.tsv" HIMMEL_CONFIG_DIR="$WORK/no-conf"
unset HIMMEL_FLAG_AUTO_GO  # an override in the launching shell must not decide the flag-off row
READY_A='- 10:00 READY 2566 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa GREEN'
READY_B='- 10:30 READY 2567 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb GREEN'

# on: a READY then a LIVE inside one sample (tails= stays LIVE) still reaches worker-event, once
reset_stub
fleet r0s
printf 'ESCALATE auto-go 3 not-ready\n' > "$STUB/le.out"; echo 10 > "$STUB/le.rc"
HIMMEL_FLAG_AUTO_GO=1 start "$I" "$WORK/r0s.out" --doc "$D" --workers-from "$M"
wait_hb "$I" || fail "(r0s) no baseline heartbeat"
printf -- '%s\n- 10:01 LIVE — waiting on CI\n' "$READY_A" >> "$L"
wait_exit "$WPID"
check "(r0s) the READY wakes the chief" "0" "$rc"
check "(r0s) one worker-event call" "1" "$(cat "$STUB/le.calls" 2>/dev/null)"
check "(r0s) the call carries the READY bullet, labelled" "N1 READY 2566 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa GREEN" "$(cat "$STUB/le.stdin" 2>/dev/null)"
check "(r0s)(10901-r2a) line 1 names the READY, its worker, PR and head" "WAKE worker-ready N1 pr=2566 head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$(head -n 1 "$WORK/r0s.out")"
check "(r0s)(10901-r2a) the block holds one WAKE worker-ready N1" "1" "$(grep -c '^WAKE worker-ready N1 ' "$WORK/r0s.out")"
contains "(r0s)(10901-r2a) line 2 names the escalation" "$(sed -n 2p "$WORK/r0s.out")" "WAKE worker-event ESCALATE auto-go 3 not-ready rc=10 out=$I.wait.le-N1"
# a re-armed waiter does not relay the same bullet again
reset_stub
printf 'ESCALATE auto-go 3 not-ready\n' > "$STUB/le.out"; echo 10 > "$STUB/le.rc"
HIMMEL_FLAG_AUTO_GO=1 start "$I" "$WORK/r0s-rearm.out" --doc "$D" --workers-from "$M"
wait_hb "$I" || fail "(r0s) no re-arm heartbeat"
sleep 2.5
check "(r0s) the same READY is not relayed twice" "" "$(cat "$STUB/le.calls" 2>/dev/null)"
check "(r0s) no wake on a re-arm" "" "$(cat "$WORK/r0s-rearm.out")"
stop_waiter

# on: two READY bullets (a series) are relayed one per pass, oldest first
reset_stub
fleet r0s2
printf 'HANDLED auto-go N1\n' > "$STUB/le.out"; echo 0 > "$STUB/le.rc"
# worker-event returns 1 s after it reads its line: the digest line of a call is written after
# that return, so the second call is started (le.stdin.2) while its digest line is not written yet
echo 1 > "$STUB/le.sleep"
HIMMEL_FLAG_AUTO_GO=1 start "$I" "$WORK/r0s2.out" --doc "$D" --workers-from "$M"
wait_hb "$I" || fail "(r0s2) no baseline heartbeat"
printf -- '%s\n%s\n- 10:31 LIVE — next item\n' "$READY_A" "$READY_B" >> "$L"
n=0
while [ "$n" -lt 80 ] && [ ! -s "$STUB/le.stdin.2" ] && kill -0 "$WPID" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
n=0
while [ "$n" -lt 80 ] && [ "$(wc -l < "$I.wait.digest" 2>/dev/null || echo 0)" -lt 2 ] && kill -0 "$WPID" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
check "(r0s2) the first READY goes first" "N1 READY 2566 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa GREEN" "$(cat "$STUB/le.stdin.1" 2>/dev/null)"
check "(r0s2) the second READY follows" "N1 READY 2567 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb GREEN" "$(cat "$STUB/le.stdin.2" 2>/dev/null)"
check "(r0s2) a handled READY is a digest line, no wake" "N1 auto-go 2566
N1 auto-go 2567" "$(cat "$I.wait.digest" 2>/dev/null)"
check "(r0s2) no chief wake" "" "$(cat "$WORK/r0s2.out")"
printf -- '- 03:45 [telegram from=1 chat=2] hello\n' >> "$I"
wait_exit "$WPID"
check "(r0s2) the next wake counts the scripted GOs apart from the wraps" "absorbed since last wake: wraps=0 () merged=0 () auto-go=2 (#2566,#2567)" "$(tail -n 1 "$WORK/r0s2.out")"
stop_waiter

# on: a worker doc shorter than its cursor was replaced; the cursor starts over after its existing READY
reset_stub
fleet r0s4
printf -- '%s\n' "$READY_A" >> "$L"
printf 'N1\t99\n' > "$I.wait.ready"
printf 'ESCALATE auto-go 3 not-ready\n' > "$STUB/le.out"; echo 10 > "$STUB/le.rc"
HIMMEL_FLAG_AUTO_GO=1 start "$I" "$WORK/r0s4.out" --doc "$D" --workers-from "$M"
wait_hb "$I" || fail "(r0s4) no baseline heartbeat"
sleep 2.5
check "(r0s4) a stale cursor past the end does not replay the old READY" "" "$(cat "$STUB/le.calls" 2>/dev/null)"
printf -- '%s\n' "$READY_B" >> "$L"
wait_exit "$WPID"
check "(r0s4) a READY written after the reset is relayed" "N1 READY 2567 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb GREEN" "$(cat "$STUB/le.stdin" 2>/dev/null)"
stop_waiter

# on: a label that leaves the manifest and returns with a shorter document starts over as a new worker does:
# the one-shot relay never relays a READY it meets first, and relays the next one written
reset_stub
fleet r0s8
printf 'ESCALATE auto-go 3 not-ready\n' > "$STUB/le.out"; echo 10 > "$STUB/le.rc"
printf 'N1\t40\n' > "$I.wait.ready"
printf '{"schema":1,"workers":[]}\n' > "$M"
HIMMEL_FLAG_AUTO_GO=1 start "$I" "$WORK/r0s8.out" --doc "$D" --workers-from "$M"
wait_hb "$I" || fail "(r0s8) no baseline heartbeat"
sleep 1.5
printf '# worker\n- 10:30 LIVE — restarted\n%s\n' "$READY_A" > "$L"
printf '{"schema":1,"workers":[{"doc":"%s","label":"N1"}]}\n' "$L" > "$M.new" && mv "$M.new" "$M"
sleep 2.5
check "(r0s8) a returning label's stale cursor does not replay its READY" "" "$(cat "$STUB/le.calls" 2>/dev/null)"
check "(r0s8) its cursor starts over at the document's last READY" "3" "$(awk -F'\t' '$1 == "N1" { c = $2 } END { print c }' "$I.wait.ready" 2>/dev/null)"
printf -- '%s\n' "$READY_B" >> "$L"
wait_exit "$WPID"
check "(r0s8) a READY written after the restart is relayed" "N1 READY 2567 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb GREEN" "$(cat "$STUB/le.stdin" 2>/dev/null)"
stop_waiter

# on: a pending READY of N1 must not leave N2's cursor unset, or N2's later READY would count as history
reset_stub
fleet r0s5
printf 'HANDLED auto-go N1\n' > "$STUB/le.out"; echo 0 > "$STUB/le.rc"
HIMMEL_FLAG_AUTO_GO=1 start "$I" "$WORK/r0s5.out" --doc "$D" --workers-from "$M"
wait_hb "$I" || fail "(r0s5) no baseline heartbeat"
L2="$WORK/r0s5/HIMMEL-2-N2-b.md"; printf '# worker\n\n## Results\n- 09:00 LIVE — started\n' > "$L2"
printf '{"schema":1,"workers":[{"doc":"%s","label":"N1"},{"doc":"%s","label":"N2"}]}\n' "$L" "$L2" > "$M.new" && mv "$M.new" "$M"
printf -- '%s\n%s\n' "$READY_A" "$READY_B" >> "$L"
n=0
while [ "$n" -lt 80 ] && [ ! -s "$STUB/le.stdin.1" ] && kill -0 "$WPID" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
printf -- '- 10:40 READY 2568 cccccccccccccccccccccccccccccccccccccccc GREEN\n' >> "$L2"
n=0
while [ "$n" -lt 80 ] && [ ! -s "$STUB/le.stdin.3" ] && kill -0 "$WPID" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
check "(r0s5) N2's READY, written while N1's backlog drained, is relayed" "N2 READY 2568 cccccccccccccccccccccccccccccccccccccccc GREEN" "$(cat "$STUB/le.stdin.3" 2>/dev/null)"
stop_waiter

reset_stub
fleet r0s3
printf 'ESCALATE marker-READY\n' > "$STUB/le.out"; echo 10 > "$STUB/le.rc"
start "$I" "$WORK/r0s3.out" --doc "$D" --workers-from "$M"
wait_hb "$I" || fail "(r0s3) no baseline heartbeat"
printf -- '%s\n- 10:01 LIVE — waiting on CI\n' "$READY_A" >> "$L"
n=0
while [ "$n" -lt 50 ] && [ ! -s "$STUB/le.stdin" ]; do sleep 0.1; n=$((n + 1)); done
sleep 2.5
check "(r0s3) flag off: one worker-event call" "1" "$(cat "$STUB/le.calls" 2>/dev/null)"
check "(r0s3) flag off: the call carries the READY bullet, labelled" "N1 READY 2566 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa GREEN" "$(cat "$STUB/le.stdin" 2>/dev/null)"
check "(r0s3) flag off: ESCALATE marker-READY is no wake" "" "$(cat "$WORK/r0s3.out")"
check "(r0s3) flag off: no digest line" "" "$(cat "$I.wait.digest" 2>/dev/null)"
check "(r0s3) flag off: the cursor moves past the READY" "N1	5" "$(cat "$I.wait.ready" 2>/dev/null)"
stop_waiter
reset_stub
printf 'ESCALATE marker-READY\n' > "$STUB/le.out"; echo 10 > "$STUB/le.rc"
start "$I" "$WORK/r0s3-rearm.out" --doc "$D" --workers-from "$M"
wait_hb "$I" || fail "(r0s3) no re-arm heartbeat"
sleep 2.5
check "(r0s3) flag off: the same READY is not handed on twice" "" "$(cat "$STUB/le.calls" 2>/dev/null)"
check "(r0s3) flag off: no wake on a re-arm" "" "$(cat "$WORK/r0s3-rearm.out")"
stop_waiter

reset_stub
fleet r0s6
printf 'usage: worker-event.sh --doc <chief doc> --fleet <manifest> <message-file | ->\n' > "$STUB/le.out"; echo 2 > "$STUB/le.rc"
start "$I" "$WORK/r0s6.out" --doc "$D" --workers-from "$M"
wait_hb "$I" || fail "(r0s6) no baseline heartbeat"
printf -- '%s\n- 10:01 LIVE — waiting on CI\n' "$READY_A" >> "$L"
wait_exit "$WPID"
check "(r0s6) flag off: a failed hand-on wakes the chief" "0" "$rc"
contains "(r0s6) flag off: the wake names the failure" "$(head -n 1 "$WORK/r0s6.out")" "WAKE worker-event usage: worker-event.sh"
stop_waiter

reset_stub
fleet r0s7
printf 'ESCALATE auto-go-error rc=1 x\n' > "$STUB/le.out"; echo 10 > "$STUB/le.rc"
start "$I" "$WORK/r0s7.out" --doc "$D" --workers-from "$M"
wait_hb "$I" || fail "(r0s7) no baseline heartbeat"
printf -- '%s\n- 10:01 LIVE — waiting on CI\n' "$READY_A" >> "$L"
wait_exit "$WPID"
check "(r0s7) flag off: another rc 10 answer to a READY is one WAKE worker-event" "1" "$(grep -c '^WAKE worker-event ESCALATE auto-go-error rc=1 x rc=10 ' "$WORK/r0s7.out")"
check "(r0s7)(10901-r2c) flag off: no WAKE worker-ready line" "0" "$(grep -c '^WAKE worker-ready' "$WORK/r0s7.out")"
stop_waiter

H_C="$(printf '%040d' 0 | tr 0 c)"; H_D="$(printf '%040d' 0 | tr 0 d)"
H_E="$(printf '%040d' 0 | tr 0 e)"; H_F="$(printf '%040d' 0 | tr 0 f)"
READY_C="- 21:36 READY 6010 $H_C GREEN"
WRAP_P='- 21:30 WRAPPED — paused'
WRAP_C='- 21:40 WRAPPED — PR 6010 left open, READY written'
WRAP_OUT_RETRY='ESCALATE close-wrapped-failed rc=6 subtree alive'
RETRYABLE='ESCALATE series-find-failed rc=3 x'

reset_stub; fleet3 r1a
: > "$STUB/le.by-marker"; printf 'HANDLED auto-go N3\n' > "$STUB/le.out"
printf -- '%s\n' "$WRAP_P" >> "$L"; printf -- '%s\n' "$WRAP_P" >> "$L2"; printf -- '%s\n' "$READY_C" >> "$L3"
tick_line "N1:WRAPPED,N2:WRAPPED,N3:READY"
HIMMEL_FLAG_AUTO_GO=1 start "$I" "$WORK/r1a.out" --doc "$D" --workers-from "$M"
wait_call 1 80
check "(10901-r1a) the newest-marker READY is the first call" "N3 READY 6010 $H_C GREEN" "$(cat "$STUB/le.stdin.1" 2>/dev/null)"
stop_waiter

reset_stub; fleet3 r1h
: > "$STUB/le.by-marker"; printf 'HANDLED auto-go N3\n' > "$STUB/le.out"
printf -- '%s\n' "$WRAP_P" >> "$L"; printf -- '%s\n' "$WRAP_P" >> "$L2"; printf -- '%s\n' "$READY_C" >> "$L3"
tick_line "N1:WRAPPED,N2:WRAPPED,N3:READY!stale"
HIMMEL_FLAG_AUTO_GO=1 start "$I" "$WORK/r1h.out" --doc "$D" --workers-from "$M"
wait_call 1 80
check "(10901-r1h) a READY!stale is still the first call" "N3 READY 6010 $H_C GREEN" "$(cat "$STUB/le.stdin.1" 2>/dev/null)"
stop_waiter

reset_stub; fleet3 r1b
: > "$STUB/le.by-marker"; printf 'HANDLED auto-go N3\n' > "$STUB/le.out"
printf -- '%s\n' "$WRAP_P" >> "$L"; printf -- '%s\n' "$WRAP_P" >> "$L2"
tick_line "N1:WRAPPED,N2:WRAPPED,N3:LIVE"
HIMMEL_FLAG_AUTO_GO=1 start "$I" "$WORK/r1b.out" --doc "$D" --workers-from "$M"
wait_call 1 80
check "(10901-r1b) with no READY the first call is N1's wrap" "N1 WRAPPED — paused" "$(cat "$STUB/le.stdin.1" 2>/dev/null)"
wait_exit "$WPID"
stop_waiter
HIMMEL_FLAG_AUTO_GO=1 start "$I" "$WORK/r1b2.out" --doc "$D" --workers-from "$M"
wait_call 2 80
check "(10901-r1b) after a re-arm the second call is N2's wrap" "N2 WRAPPED — paused" "$(cat "$STUB/le.stdin.2" 2>/dev/null)"
stop_waiter

reset_stub; fleet3 r1c
: > "$STUB/le.by-marker"; printf 'HANDLED auto-go N3\n' > "$STUB/le.out"
printf -- '%s\n%s\n' "$READY_C" "$WRAP_C" >> "$L3"
tick_line "N1:LIVE,N2:LIVE,N3:WRAPPED"
HIMMEL_FLAG_AUTO_GO=1 start "$I" "$WORK/r1c.out" --doc "$D" --workers-from "$M"
wait_exit "$WPID"
check "(10901-r1c) the wrapped worker's wrap goes first" "N3 WRAPPED — PR 6010 left open, READY written" "$(cat "$STUB/le.stdin.1" 2>/dev/null)"
stop_waiter
HIMMEL_FLAG_AUTO_GO=1 start "$I" "$WORK/r1c2.out" --doc "$D" --workers-from "$M"
wait_call 2 80
check "(10901-r1c) its READY is still relayed after the wrap" "N3 READY 6010 $H_C GREEN" "$(cat "$STUB/le.stdin.2" 2>/dev/null)"
stop_waiter

reset_stub; fleet3 r1g
: > "$STUB/le.by-marker"; printf 'HANDLED auto-go N3\n' > "$STUB/le.out"
printf '%s\n' "$WRAP_OUT_RETRY" > "$STUB/le.wrap-out"; echo 10 > "$STUB/le.wrap-rc"
printf -- '%s\n%s\n' "$READY_C" "$WRAP_C" >> "$L3"
tick_line "N1:LIVE,N2:LIVE,N3:WRAPPED"
HIMMEL_FLAG_AUTO_GO=1 start "$I" "$WORK/r1g.out" --doc "$D" --workers-from "$M"
wait_call 2 80
check "(10901-r1g) the first call is the wrap" "N3 WRAPPED — PR 6010 left open, READY written" "$(cat "$STUB/le.stdin.1" 2>/dev/null)"
check "(10901-r1g) the second call is the wrap again" "N3 WRAPPED — PR 6010 left open, READY written" "$(cat "$STUB/le.stdin.2" 2>/dev/null)"
check "(10901-r1g) no call carries N3's READY while the wrap retries" "0" "$(cat "$STUB"/le.stdin.* 2>/dev/null | grep -c '^N3 READY ')"
stop_waiter

reset_stub; fleet3 r1d
: > "$STUB/le.retry-first"; printf '%s\n' "$RETRYABLE" > "$STUB/le.out"; echo 10 > "$STUB/le.rc"
printf -- '%s\n' "$WRAP_P" >> "$L"; printf -- '%s\n' "$WRAP_P" >> "$L2"; printf -- '%s\n' "$READY_C" >> "$L3"
tick_line "N1:WRAPPED,N2:WRAPPED,N3:READY"
HIMMEL_FLAG_AUTO_GO=1 start "$I" "$WORK/r1d.out" --doc "$D" --workers-from "$M"
wait_call 3 100
check "(10901-r1d) N2's wrap is one of the first three calls" "1" "$(cat "$STUB/le.stdin.1" "$STUB/le.stdin.2" "$STUB/le.stdin.3" 2>/dev/null | grep -c '^N2 WRAPPED — paused$')"
r1d_s1="$(cat "$STUB/le.stdin.1" 2>/dev/null)"; r1d_s2="$(cat "$STUB/le.stdin.2" 2>/dev/null)"; r1d_s3="$(cat "$STUB/le.stdin.3" 2>/dev/null)"
r1d_same=0
if [ "$r1d_s1" = "$r1d_s2" ] || [ "$r1d_s2" = "$r1d_s3" ]; then r1d_same=1; fi
check "(10901-r1d) no two consecutive calls are equal" "0" "$r1d_same"
stop_waiter

reset_stub; fleet3 r1e
printf 'ESCALATE marker-READY\n' > "$STUB/le.out"; echo 10 > "$STUB/le.rc"
printf -- '%s\n' "$WRAP_P" >> "$L"; printf -- '%s\n' "$WRAP_P" >> "$L2"; printf -- '%s\n' "$READY_C" >> "$L3"
tick_line "N1:WRAPPED,N2:WRAPPED,N3:READY"
start "$I" "$WORK/r1e.out" --doc "$D" --workers-from "$M"
wait_call 1 80
check "(10901-r1e) flag off: the first call is N1's wrap" "N1 WRAPPED — paused" "$(cat "$STUB/le.stdin.1" 2>/dev/null)"
stop_waiter

reset_stub; fleet3 r1f
: > "$STUB/le.by-marker"; printf '%s\n' "$RETRYABLE" > "$STUB/le.out"; echo 10 > "$STUB/le.rc"
printf -- '%s\n' "$WRAP_P" >> "$L"; printf -- '%s\n' "$READY_C" >> "$L3"
tick_line "N1:WRAPPED,N2:LIVE,N3:READY"
HIMMEL_FLAG_AUTO_GO=1 start "$I" "$WORK/r1f.out" --doc "$D" --workers-from "$M"
wait_exit "$WPID"
check "(10901-r1f) (a) call 1 is N3's retryable READY" "N3 READY 6010 $H_C GREEN" "$(cat "$STUB/le.stdin.1" 2>/dev/null)"
check "(10901-r1f) (a) call 2 is N1's wrap, which wakes" "N1 WRAPPED — paused" "$(cat "$STUB/le.stdin.2" 2>/dev/null)"
stop_waiter
printf 'HANDLED auto-go N3\n' > "$STUB/le.out"; echo 0 > "$STUB/le.rc"
HIMMEL_FLAG_AUTO_GO=1 start "$I" "$WORK/r1f2.out" --doc "$D" --workers-from "$M"
n=0
while [ "$n" -lt 80 ] && ! grep -qx 'N3 auto-go 6010' "$I.wait.digest" 2>/dev/null && kill -0 "$WPID" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
check "(10901-r1f) (b) call 3 is N3's READY, now handled" "N3 READY 6010 $H_C GREEN" "$(cat "$STUB/le.stdin.3" 2>/dev/null)"
check "(10901-r1f) (b) the digest names the GO" "1" "$(grep -cx 'N3 auto-go 6010' "$I.wait.digest" 2>/dev/null)"
printf -- '- 21:50 READY 6011 %s GREEN\n' "$H_D" >> "$L3"; printf -- '- 21:51 WRAPPED — paused\n' >> "$L2"
tick_line "N1:WRAPPED,N2:WRAPPED,N3:READY"
wait_call 4 80
check "(10901-r1f) (c) a newer READY of N3 goes before N2's wrap" "N3 READY 6011 $H_D GREEN" "$(cat "$STUB/le.stdin.4" 2>/dev/null)"
stop_waiter

reset_stub; fleet3 r1j
: > "$STUB/le.by-marker"; printf 'HANDLED auto-go\n' > "$STUB/le.out"; echo 0 > "$STUB/le.rc"
printf -- '%s\n' "$WRAP_P" >> "$L"
printf -- '- 21:32 READY 6020 %s GREEN\n- 21:33 WRAPPED — PR 6020 left open\n' "$H_E" >> "$L2"
printf -- '- 21:36 READY 6030 %s GREEN\n' "$H_F" >> "$L3"
tick_line "N1:WRAPPED,N2:WRAPPED,N3:READY"
HIMMEL_FLAG_AUTO_GO=1 start "$I" "$WORK/r1j.out" --doc "$D" --workers-from "$M"
wait_call 1 80
check "(10901-r1j) N3's newest-marker READY goes first" "N3 READY 6030 $H_F GREEN" "$(cat "$STUB/le.stdin.1" 2>/dev/null)"
stop_waiter

reset_stub; fleet3 r1k
: > "$STUB/le.by-marker"; printf '%s\n' "$RETRYABLE" > "$STUB/le.out"; echo 10 > "$STUB/le.rc"
printf -- '%s\n' "$WRAP_P" >> "$L"
printf -- '%s\n%s\n' "$READY_C" "$WRAP_C" >> "$L3"
printf 'N3 WRAPPED %s\n' "$(printf '%s\n' "$WRAP_C" | cksum | cut -d' ' -f1)" > "$I.wait.r0"
printf 'N3\n' > "$I.wait.r0-next"
tick_line "N1:WRAPPED,N2:LIVE,N3:WRAPPED"
HIMMEL_FLAG_AUTO_GO=1 start "$I" "$WORK/r1k.out" --doc "$D" --workers-from "$M"
wait_call 3 80
check "(10901-r1k) N1's wrap is one of the first two calls" "1" "$(cat "$STUB/le.stdin.1" "$STUB/le.stdin.2" 2>/dev/null | grep -c '^N1 WRAPPED')"
stop_waiter

reset_stub; fleet3 r1m
L4="$WORK/r1m/HIMMEL-4-N4-d.md"; printf '# worker\n\n## Results\n- 09:00 LIVE — started\n' > "$L4"
printf '{"schema":1,"workers":[{"doc":"%s","label":"N1"},{"doc":"%s","label":"N2"},{"doc":"%s","label":"N3"},{"doc":"%s","label":"N4"}]}\n' "$L" "$L2" "$L3" "$L4" > "$M"
printf 'N1\t0\nN2\t0\nN3\t0\nN4\t0\n' > "$I.wait.ready"
: > "$STUB/le.by-marker"
printf '%s\n' "$RETRYABLE" > "$STUB/le.out"; echo 10 > "$STUB/le.rc"
printf '%s\n' "$RETRYABLE" > "$STUB/le.out.1"; echo 10 > "$STUB/le.rc.1"
printf 'HANDLED auto-go N4\n' > "$STUB/le.out.2"; echo 0 > "$STUB/le.rc.2"
printf -- '%s\n' "$READY_C" >> "$L3"; printf -- '- 21:37 READY 6040 %s GREEN\n' "$H_D" >> "$L4"
tick_line "N1:LIVE,N2:LIVE,N3:READY,N4:READY"
HIMMEL_FLAG_AUTO_GO=1 start "$I" "$WORK/r1m.out" --doc "$D" --workers-from "$M"
wait_call 3 80
check "(10901-r1m) call 1 is N3's retryable READY" "N3 READY 6010 $H_C GREEN" "$(cat "$STUB/le.stdin.1" 2>/dev/null)"
check "(10901-r1m) call 2 is N4's READY, not N3's again" "N4 READY 6040 $H_D GREEN" "$(cat "$STUB/le.stdin.2" 2>/dev/null)"
stop_waiter

reset_stub; fleet3 r1n
printf '%s\n' "$RETRYABLE" > "$STUB/le.out"; echo 10 > "$STUB/le.rc"
printf -- '%s\n- 21:38 MERGED #6010 → abcdef01\n' "$READY_C" >> "$L3"
tick_line "N1:LIVE,N2:LIVE,N3:READY" "N3:MERGED#1"
HIMMEL_FLAG_AUTO_GO=1 start "$I" "$WORK/r1n.out" --doc "$D" --workers-from "$M"
wait_call 4 120
check "(10901-r1n) call 1 is N3's READY" "N3 READY 6010 $H_C GREEN" "$(cat "$STUB/le.stdin.1" 2>/dev/null)"
check "(10901-r1n) call 2 is N3's MERGED" "N3 MERGED #6010 → abcdef01" "$(cat "$STUB/le.stdin.2" 2>/dev/null)"
check "(10901-r1n) call 3 is N3's READY again" "N3 READY 6010 $H_C GREEN" "$(cat "$STUB/le.stdin.3" 2>/dev/null)"
check "(10901-r1n) call 4 is N3's MERGED again" "N3 MERGED #6010 → abcdef01" "$(cat "$STUB/le.stdin.4" 2>/dev/null)"
stop_waiter

reset_stub; fleet3 r1p
: > "$STUB/le.merged-escalates"; printf 'HANDLED auto-go N3\n' > "$STUB/le.out"
printf -- '- 20:09 MERGED #6001 → abcdef01\n' >> "$L"; printf -- '- 20:10 MERGED #6002 → abcdef02\n' >> "$L2"; printf -- '%s\n' "$READY_C" >> "$L3"
tick_line "N1:LIVE,N2:LIVE,N3:READY" "N1:MERGED#1,N2:MERGED#1"
HIMMEL_FLAG_AUTO_GO=1 start "$I" "$WORK/r1p.out" --doc "$D" --workers-from "$M"
wait_call 1 80
check "(10901-r1p) a READY goes before another label's escalating MERGED" "N3 READY 6010 $H_C GREEN" "$(cat "$STUB/le.stdin.1" 2>/dev/null)"
wait_exit "$WPID"
check "(10901-r1p) the MERGEDs are still relayed after the READY (N1)" "N1 MERGED #6001 → abcdef01" "$(cat "$STUB/le.stdin.2" 2>/dev/null)"
stop_waiter
HIMMEL_FLAG_AUTO_GO=1 start "$I" "$WORK/r1p2.out" --doc "$D" --workers-from "$M"
wait_call 3 80
check "(10901-r1p) and N2's MERGED after a re-arm" "N2 MERGED #6002 → abcdef02" "$(cat "$STUB/le.stdin.3" 2>/dev/null)"
stop_waiter

r0s_run() {
    reset_stub; fleet "$1"
    printf '%s\n' "$2" > "$STUB/le.out"; echo "$3" > "$STUB/le.rc"
    start "$I" "$WORK/$1.out" --doc "$D" --workers-from "$M"
    wait_hb "$I" || fail "($1) no baseline heartbeat"
    printf -- '%s\n- 10:01 LIVE — waiting on CI\n' "$READY_A" >> "$L"
    wait_exit "$WPID"
}

HIMMEL_FLAG_AUTO_GO=1 r0s_run r2e1 'GO-WRITTEN 2566 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa qid=q bus-failed: x' 11
contains "(10901-r2e) rc 11 GO-WRITTEN is a plain worker-event wake" "$(head -n 1 "$WORK/r2e1.out")" "WAKE worker-event GO-WRITTEN 2566"
check "(10901-r2e) rc 11 names no WAKE worker-ready" "0" "$(grep -c '^WAKE worker-ready' "$WORK/r2e1.out")"
stop_waiter
HIMMEL_FLAG_AUTO_GO=1 r0s_run r2e2 'ESCALATE auto-go 3 not-ready' 12
contains "(10901-r2e) an auto-go refusal at rc 12 is a plain worker-event wake" "$(head -n 1 "$WORK/r2e2.out")" "WAKE worker-event ESCALATE auto-go 3"
check "(10901-r2e) rc 12 names no WAKE worker-ready" "0" "$(grep -c '^WAKE worker-ready' "$WORK/r2e2.out")"
stop_waiter

HIMMEL_FLAG_AUTO_GO=1 CHIEF_WAIT_STREAM_SERVICE=1 r0s_run r2f 'ESCALATE auto-go 3 not-ready' 10
check "(10901-r2f) stream: one worker-event call" "1" "$(cat "$STUB/le.calls" 2>/dev/null)"
contains "(10901-r2f) stream: line 1 is the plain worker-event wake" "$(head -n 1 "$WORK/r2f.out")" "WAKE worker-event ESCALATE auto-go 3 not-ready"
check "(10901-r2f) stream: no WAKE worker-ready line" "0" "$(grep -c '^WAKE worker-ready' "$WORK/r2f.out")"
stop_waiter

HIMMEL_FLAG_AUTO_GO=1 r0s_run r2g 'ESCALATE auto-go-error rc=1 x' 10
check "(10901-r2g) line 1 names the READY" "WAKE worker-ready N1 pr=2566 head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$(head -n 1 "$WORK/r2g.out")"
stop_waiter

HIMMEL_FLAG_AUTO_GO=1 r0s_run r2i 'ESCALATE series-writer-unlisted x' 10
contains "(10901-r2i) line 1 is the plain worker-event wake" "$(head -n 1 "$WORK/r2i.out")" "WAKE worker-event ESCALATE series-writer-unlisted"
check "(10901-r2i) no WAKE worker-ready line" "0" "$(grep -c '^WAKE worker-ready' "$WORK/r2i.out")"
stop_waiter

reset_stub; fleet r2h
printf 'ESCALATE auto-go 3 not-ready\n' > "$STUB/le.out"; echo 10 > "$STUB/le.rc"
tick_line "N1:READY"
HIMMEL_FLAG_AUTO_GO=1 start "$I" "$WORK/r2h.out" --doc "$D" --workers-from "$M"
wait_hb "$I" || fail "(r2h) no baseline heartbeat"
printf -- '%s\n' "$READY_A" >> "$L"
wait_exit "$WPID"
check "(10901-r2h) the wake block holds exactly one WAKE worker-ready N1" "1" "$(grep -c '^WAKE worker-ready N1 ' "$WORK/r2h.out")"
check "(10901-r2h) the READY is recorded as named once" "1" "$(grep -cx 'READY 2566 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$I.wait.markerwoke" 2>/dev/null)"
stop_waiter

export PATH="$relay_path"
if [ "${1:-}" = --wrap-relay ]; then
    if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
    exit 0
fi

# --- (r0a) a MERGED worker the relay handles: no wake, a digest line ------------
reset_stub
fleet r0a
start "$I" "$WORK/r0a.out" --doc "$D" --workers-from "$M"
wait_hb "$I" || fail "(r0a) no baseline heartbeat"
printf -- '- 10:00 READY #2566 abcdef GREEN\n- 10:30 MERGED #2566 → abcdef01\n' >> "$L"
tick_line "N1:LIVE" "N1:MERGED#1"
wait_exit "$WPID"
check "(r0a) a handled MERGED does not wake the chief" "running" "$rc"
check "(r0a) and prints nothing" "" "$(cat "$WORK/r0a.out")"
check "(r0a) worker-event ran once" "1" "$(cat "$STUB/le.calls" 2>/dev/null)"
check "(r0a) on the bullet, labelled" "N1 MERGED #2566 → abcdef01" "$(cat "$STUB/le.stdin" 2>/dev/null)"
check "(r0a) with the chief doc and the manifest" "--doc $D --fleet $M -" "$(cat "$STUB/le.args" 2>/dev/null)"
check "(r0a) the digest names the worker and the PR" "N1 wrap-merged 2566" "$(cat "$I.wait.digest" 2>/dev/null)"
printf -- '- 03:45 [telegram from=1 chat=2] hello\n' >> "$I"
wait_exit "$WPID"
check "(r0a) the next wake prints the digest" "$(printf 'WAKE telegram\n- 03:45 [telegram from=1 chat=2] hello\nabsorbed since last wake: wraps=1 (N1) merged=1 (#2566)')" "$(cat "$WORK/r0a.out")"
check "(r0a) and clears it" "" "$(cat "$I.wait.digest" 2>/dev/null)"
stop_waiter

# --- (r0b) ESCALATE wakes once with the out file -----------------------------
reset_stub
fleet r0b
printf 'ESCALATE ambiguous-label\n' > "$STUB/le.out"; echo 10 > "$STUB/le.rc"
start "$I" "$WORK/r0b.out" --doc "$D" --workers-from "$M"
wait_hb "$I" || fail "(r0b) no baseline heartbeat"
printf -- '- 11:00 WRAPPED — N1 done, N2 next\n' >> "$L"
tick_line "N1:WRAPPED"
wait_exit "$WPID"
check "(r0b) an ESCALATE wakes (rc 0)" "0" "$rc"
check "(r0b) naming worker-event, the line and the out file" "WAKE worker-event ESCALATE ambiguous-label rc=10 out=$I.wait.le-N1" "$(head -n 1 "$WORK/r0b.out")"
check "(r0b)(10901-r2b) a wrap's escalation names no READY" "0" "$(head -n 1 "$WORK/r0b.out" | grep -c '^WAKE worker-ready')"
check "(r0b) then the tick line" "$(cat "$STUB/tick.line")" "$(sed -n 2p "$WORK/r0b.out")"
check "(r0b) the out file holds worker-event's output" "ESCALATE ambiguous-label" "$(cat "$I.wait.le-N1" 2>/dev/null)"
start "$I" "$WORK/r0b2.out" --doc "$D" --workers-from "$M"
wait_hb "$I" || fail "(r0b) no re-arm baseline heartbeat"
sleep 2.5
wait_exit "$WPID"
check "(r0b) a re-arm does not wake for the same bullet" "running" "$rc"
check "(r0b) nor runs worker-event again" "1" "$(cat "$STUB/le.calls" 2>/dev/null)"
stop_waiter

# --- (r0c) a lock-held refusal is retried, never a worker-event wake ------------
reset_stub
fleet r0c
printf 'ESCALATE wrap-merged-failed rc=3 close-wrapped-worker: refusing - queue lock held\n' > "$STUB/le.out"; echo 10 > "$STUB/le.rc"
HOUSEKEEPING_DIGEST_SECS=0 start "$I" "$WORK/r0c.out" --doc "$D" --workers-from "$M"
wait_hb "$I" || fail "(r0c) no baseline heartbeat"
printf -- '- 11:00 WRAPPED — done\n' >> "$L"
tick_line "N1:WRAPPED"
wait_exit "$WPID"
lacks "(r0c) a lock-held refusal is not a worker-event wake" "$(cat "$WORK/r0c.out")" "WAKE worker-event"
check "(r0c) it was asked again on the next sample" "2" "$(cat "$STUB/le.calls" 2>/dev/null)"
check "(r0c) the standing refusal falls back to the tick wake" "WAKE tick changed=tails usage=PROCEED" "$(head -n 1 "$WORK/r0c.out")"
stop_waiter

# --- (r0h) the same refusal text on a non-10 rc (a timeout) wakes at once -----
reset_stub
fleet r0h
printf 'ESCALATE wrap-merged-failed rc=3 close-wrapped-worker: refusing - queue lock held\n' > "$STUB/le.out"; echo 124 > "$STUB/le.rc"
start "$I" "$WORK/r0h.out" --doc "$D" --workers-from "$M"
wait_hb "$I" || fail "(r0h) no baseline heartbeat"
printf -- '- 11:00 WRAPPED — done\n' >> "$L"
tick_line "N1:WRAPPED"
wait_exit "$WPID"
check "(r0h) rc 124 is a worker-event wake, not a retry" "WAKE worker-event ESCALATE wrap-merged-failed rc=3 close-wrapped-worker: refusing - queue lock held rc=124 out=$I.wait.le-N1" "$(head -n 1 "$WORK/r0h.out")"
stop_waiter

# --- (r0w) a log or board failure after the close is reported, never retried --
# wrap-merged.sh exits 6 or 7 for them too, but only after the worker's entry was retired: the
# waiter would ask again for a worker the manifest no longer lists, and the failure would be lost.
for r0w in "6:log failed: append-results.sh" "7:board failed: board.mjs --doc x --changed"; do
    reset_stub
    fleet "r0w${r0w%%:*}"
    printf 'ESCALATE wrap-merged-failed rc=%s wrap-merged: step %s\n' "${r0w%%:*}" "${r0w#*:}" > "$STUB/le.out"; echo 10 > "$STUB/le.rc"
    start "$I" "$WORK/r0w.out" --doc "$D" --workers-from "$M"
    wait_hb "$I" || fail "(r0w) no baseline heartbeat"
    printf -- '- 11:00 MERGED #2566 → abcdef01 done\n' >> "$L"
    tick_line "N1:LIVE" "N1:MERGED#2566"
    wait_exit "$WPID"
    check "(r0w) rc ${r0w%%:*} step ${r0w#*:} wakes at once" "WAKE worker-event ESCALATE wrap-merged-failed rc=${r0w%%:*} wrap-merged: step ${r0w#*:} rc=10 out=$I.wait.le-N1" "$(head -n 1 "$WORK/r0w.out")"
    stop_waiter
done

# --- (r0d) no RETASK token reaches worker-event, the wake or the out file -------
reset_stub
fleet r0d
touch "$STUB/le.echo"; echo 10 > "$STUB/le.rc"
start "$I" "$WORK/r0d.out" --doc "$D" --workers-from "$M"
wait_hb "$I" || fail "(r0d) no baseline heartbeat"
printf -- '- 11:00 WRAPPED — quoted BD-N1-f14f9339 deferred\n' >> "$L"
tick_line "N1:WRAPPED"
wait_exit "$WPID"
check "(r0d) the escalate wakes (rc 0)" "0" "$rc"
lacks "(r0d) worker-event never sees the token" "$(cat "$STUB/le.stdin" 2>/dev/null)" "f14f9339"
lacks "(r0d) the wake carries no token" "$(cat "$WORK/r0d.out")" "f14f9339"
lacks "(r0d) the out file carries no token" "$(cat "$I.wait.le-N1" 2>/dev/null)" "f14f9339"
stop_waiter

# --- (r0e) without --workers-from worker-event never runs --------------------------
reset_stub
fleet r0e
HOUSEKEEPING_DIGEST_SECS=0 start "$I" "$WORK/r0e.out" --doc "$D" --workers "$L"
wait_hb "$I" || fail "(r0e) no baseline heartbeat"
printf -- '- 11:00 WRAPPED — done\n' >> "$L"
tick_line "N1:WRAPPED"
wait_exit "$WPID"
check "(r0e) the tick change wakes as before" "WAKE tick changed=tails usage=PROCEED" "$(head -n 1 "$WORK/r0e.out")"
check "(r0e) worker-event never ran" "" "$(cat "$STUB/le.calls" 2>/dev/null)"
stop_waiter

# --- (r0f) BLOCKED wakes first; the re-arm still absorbs the pending wrap ------
reset_stub
fleet2 r0f
tick_line "N1:LIVE,N2:LIVE"
start "$I" "$WORK/r0f.out" --doc "$D" --workers-from "$M"
wait_hb "$I" || fail "(r0f) no baseline heartbeat"
printf -- '- 11:00 WRAPPED — done\n' >> "$L"
tick_seq "$(tick_text "N1:LIVE,N2:BLOCKED")" "$(tick_text "N1:WRAPPED,N2:BLOCKED")"
wait_exit "$WPID"
check "(r0f) N2's change wakes (rc 0)" "0" "$rc"
check "(r0f) as a tick wake on tails" "WAKE tick changed=tails usage=PROCEED" "$(head -n 1 "$WORK/r0f.out")"
contains "(r0f) BLOCKED wakes before the wrap sample" "$(cat "$WORK/r0f.out")" "tails=N1:LIVE,N2:BLOCKED"
check "(r0f) the relay has not seen the wrap yet" "" "$(cat "$STUB/le.calls" 2>/dev/null)"
stop_waiter
start "$I" "$WORK/r0f2.out" --doc "$D" --workers-from "$M"
wait_hb "$I" || fail "(r0f) no re-arm heartbeat"
n=0
while [ "$n" -lt 100 ] && [ ! -s "$I.wait.digest" ]; do sleep 0.1; n=$((n + 1)); done
check "(r0f) the re-arm absorbs the wrap once" "1" "$(cat "$STUB/le.calls" 2>/dev/null)"
contains "(r0f) the pending wrap is recorded" "$(cat "$I.wait.digest" 2>/dev/null)" "N1 wrap-merged"
printf -- '- 03:45 [telegram from=1 chat=2] flush\n' >> "$I"
wait_exit "$WPID"
check "(r0f) the next Telegram wake exits (rc 0)" "0" "$rc"
check "(r0f) the wake is Telegram" "WAKE telegram" "$(head -n 1 "$WORK/r0f2.out")"
contains "(r0f) the absorbed N1 wrap is delivered after re-arm" "$(cat "$WORK/r0f2.out")" "absorbed since last wake: wraps=1 (N1)"
check "(r0f) the delivered digest is cleared" "" "$(cat "$I.wait.digest" 2>/dev/null)"
stop_waiter

# --- (r0g) a change beside the wrap survives the manifest move it makes -------
reset_stub
fleet2 r0g
tick_line "N1:LIVE,N2:LIVE"
start "$I" "$WORK/r0g.out" --doc "$D" --workers-from "$M"
wait_hb "$I" || fail "(r0g) no baseline heartbeat"
tick_text "N2:BLOCKED" > "$STUB/tick.after"; touch "$STUB/le.rm"
printf -- '- 11:00 WRAPPED — done\n' >> "$L"
tick_seq "$(tick_text "N1:WRAPPED,N2:BLOCKED")"
wait_exit "$WPID"
check "(r0g) N2's change wakes (rc 0)" "0" "$rc"
check "(r0g) as a tick wake on tails" "WAKE tick changed=tails usage=PROCEED" "$(head -n 1 "$WORK/r0g.out")"
check "(r0g) the relay dropped N1 from the manifest" "N2" "$(jq -r '.workers[].label' "$M")"
stop_waiter

# --- (r0i) a window turning closable beside the absorbed wrap still wakes -----
reset_stub
fleet2 r0i
tick_line "N1:LIVE,N2:LIVE"
start "$I" "$WORK/r0i.out" --doc "$D" --workers-from "$M"
wait_hb "$I" || fail "(r0i) no baseline heartbeat"
printf -- '- 11:00 WRAPPED — done\n' >> "$L"
tick_seq "$(tick_text "N1:WRAPPED,N2:LIVE") closable=1"
wait_exit "$WPID"
check "(r0i) the closable rise wakes (rc 0)" "0" "$rc"
check "(r0i) as a tick wake on closable" "WAKE tick changed=closable usage=PROCEED" "$(head -n 1 "$WORK/r0i.out")"
stop_waiter

# --- (r0j) the heartbeat is refreshed before each worker-event call -------------
# Two samples over two wraps: each worker-event call is up to 245 s, so the
# heartbeat the second call starts under must be newer than the first's.
reset_stub
fleet2 r0j
echo 1.2 > "$STUB/le.sleep"
tick_line "N1:LIVE,N2:LIVE"
start "$I" "$WORK/r0j.out" --doc "$D" --workers-from "$M"
wait_hb "$I" || fail "(r0j) no baseline heartbeat"
printf -- '- 11:00 WRAPPED — done\n' >> "$L"; printf -- '- 11:00 WRAPPED — done\n' >> "$L2"
tick_seq "$(tick_text "N1:WRAPPED,N2:WRAPPED")"
n=0
while [ "$n" -lt 80 ] && [ "$(cat "$STUB/le.calls" 2>/dev/null)" != 2 ]; do sleep 0.1; n=$((n + 1)); done
check "(r0j) worker-event ran for both wraps" "2" "$(cat "$STUB/le.calls" 2>/dev/null)"
hb1="$(cat "$STUB/le.hb.1" 2>/dev/null)"; hb2="$(cat "$STUB/le.hb.2" 2>/dev/null)"
if [ -n "$hb1" ] && [ -n "$hb2" ] && [ "$hb2" -gt "$hb1" ]; then pass "(r0j) the second call starts under a newer heartbeat"
else fail "(r0j) the second call starts under a newer heartbeat (want '$hb2' > '$hb1')"; fi
stop_waiter

# --- (hd) holds= wakes when a worker ENTERS the set, once per hold --------------
# The age grows every tick, a hold that is still there does not re-wake, and a
# worker leaving the set (or the field going away) wakes nothing.
holds_line() { # <holds value, empty = field absent>
    tick_line "N1:BLOCKED"
    if [ -n "$1" ]; then
        printf '%s holds=%s\n' "$(cat "$STUB/tick.line")" "$1" > "$STUB/tick.line.new" && mv "$STUB/tick.line.new" "$STUB/tick.line"
    fi
}
reset_stub
holds_line ""
fleet hd
start "$I" "$WORK/hd.out" --doc "$D" --workers-from "$M"
wait_hb "$I" || fail "(hd) no baseline heartbeat"
holds_line "N1:25m"
wait_exit "$WPID"
check "(hd) a worker entering the holds set ends the wait" "0" "$rc"
check "(hd) the wake names holds" "WAKE tick changed=holds usage=PROCEED" "$(head -n 1 "$WORK/hd.out")"

# a re-arm with the hold standing, the age growing: no second wake
start "$I" "$WORK/hd2.out" --doc "$D" --workers-from "$M"
wait_hb "$I" || fail "(hd2) no re-arm heartbeat"
holds_line "N1:31m"
wait_exit "$WPID"
check "(hd2) the same hold ageing does not wake again" "running" "$rc"
holds_line "N1:31m,N2:22m"
wait_exit "$WPID"
check "(hd3) a second worker entering wakes" "0" "$rc"
check "(hd3) the wake names holds" "WAKE tick changed=holds usage=PROCEED" "$(head -n 1 "$WORK/hd2.out")"

# a worker leaving the set (N2 stays) wakes nothing; neither does the set emptying
start "$I" "$WORK/hd4.out" --doc "$D" --workers-from "$M"
wait_hb "$I" || fail "(hd4) no re-arm heartbeat"
holds_line "N2:24m"
wait_exit "$WPID"
check "(hd4) a worker leaving the holds set does not wake" "running" "$rc"
holds_line ""
wait_exit "$WPID"
check "(hd5) the set emptying does not wake" "running" "$rc"
stop_waiter

# --- (rv) a worker whose newest marker is BLOCKED resolve wakes the chief -----
# The wake names the worker, the PR and the thread ids; any other newest marker
# (another BLOCKED, a later RESOLVED, FINDING, LIVE) wakes no resolve.
reset_stub
fleet rv
start "$I" "$WORK/rv.out" --doc "$D" --workers-from "$M"
wait_hb "$I" || fail "(rv) no baseline heartbeat"
printf -- '- 10:00 BLOCKED resolve 3628 PRRT_kwDOAb-1 PRRT_kwDOAb_2 — classifier denied the resolve\n' >> "$L"
tick_line "N1:BLOCKED" "N1:BLOCKED#1"
wait_exit "$WPID"
check "(rv) a BLOCKED resolve ends the wait" "0" "$rc"
check "(rv) the wake names worker, PR and thread ids" "WAKE resolve N1 pr=3628 threads=PRRT_kwDOAb-1,PRRT_kwDOAb_2" "$(head -n 1 "$WORK/rv.out")"
check "(rv) then the tick line" "$(cat "$STUB/tick.line")" "$(sed -n 2p "$WORK/rv.out")"
start "$I" "$WORK/rv2.out" --doc "$D" --workers-from "$M"
wait_hb "$I" || fail "(rv) no re-arm heartbeat"
sleep 2.5
wait_exit "$WPID"
check "(rv) a re-arm does not wake for the same bullet" "running" "$rc"
printf -- '- 10:20 BLOCKED resolve 3628 PRRT_kwDOAb-1 — denied again\n' >> "$L"
wait_exit "$WPID"
check "(rv) a later BLOCKED resolve bullet wakes again" "0" "$rc"
check "(rv) naming its own thread" "WAKE resolve N1 pr=3628 threads=PRRT_kwDOAb-1" "$(head -n 1 "$WORK/rv2.out")"
stop_waiter

# (rv-neg) none of these newest markers is a resolve wake
for neg in 'BLOCKED permission prompt on gh pr merge' 'BLOCKED resolve-later nothing' 'FINDING resolve 3628 PRRT_abc' 'LIVE — BLOCKED resolve 3628 PRRT_abc' 'WRAPPED'; do
    reset_stub
    fleet rvn
    start "$I" "$WORK/rvn.out" --doc "$D" --workers-from "$M"
    wait_hb "$I" || fail "(rv-neg) no baseline heartbeat"
    printf -- '- 10:00 %s\n' "$neg" >> "$L"
    tick_line "N1:LIVE"
    sleep 2.5
    wait_exit "$WPID"
    lacks "(rv-neg) '$neg' is no resolve wake" "$(cat "$WORK/rvn.out")" "WAKE resolve"
    stop_waiter
done

# a BLOCKED resolve the worker already retired with a later marker wakes no resolve
reset_stub
fleet rvr
printf -- '- 10:00 BLOCKED resolve 3628 PRRT_abc — denied\n- 10:10 RESOLVED — ruling received, see chief message\n' >> "$L"
start "$I" "$WORK/rvr.out" --doc "$D" --workers-from "$M"
wait_hb "$I" || fail "(rv-retired) no baseline heartbeat"
sleep 2.5
wait_exit "$WPID"
check "(rv-retired) a retired BLOCKED resolve does not wake" "running" "$rc"
stop_waiter

# a BLOCKED resolve followed by a MERGED bullet is retired too
reset_stub
fleet rvm
printf -- '- 10:00 BLOCKED resolve 3628 PRRT_abc — denied\n- 10:30 MERGED #3628 abc1234 — merged\n' >> "$L"
start "$I" "$WORK/rvm.out" --doc "$D" --workers-from "$M"
wait_hb "$I" || fail "(rv-merged) no baseline heartbeat"
sleep 2.5
wait_exit "$WPID"
check "(rv-merged) a BLOCKED resolve before a MERGED bullet does not wake" "running" "$rc"
stop_waiter

# a later PARKED-USAGE bullet retires a BLOCKED resolve
reset_stub
fleet rvp
printf -- '- 10:00 BLOCKED resolve 3628 PRRT_abc — denied\n- 10:40 PARKED-USAGE — weekly cap\n' >> "$L"
start "$I" "$WORK/rvp.out" --doc "$D" --workers-from "$M"
wait_hb "$I" || fail "(rv-parked) no baseline heartbeat"
sleep 2.5
wait_exit "$WPID"
check "(rv-parked) a BLOCKED resolve before a PARKED-USAGE bullet does not wake" "running" "$rc"
stop_waiter

# a later line that only starts like a marker (BLOCKED2) is no marker and hides nothing
reset_stub
fleet rvb
start "$I" "$WORK/rvb.out" --doc "$D" --workers-from "$M"
wait_hb "$I" || fail "(rv-boundary) no baseline heartbeat"
printf -- '- 10:00 BLOCKED resolve 3628 PRRT_abc — denied\n- 10:10 BLOCKED2 stray note\n' >> "$L"
tick_line "N1:BLOCKED" "N1:BLOCKED#1"
wait_exit "$WPID"
check "(rv-boundary) a BLOCKED2 line does not hide a BLOCKED resolve" "0" "$rc"
check "(rv-boundary) the wake names the resolve" "WAKE resolve N1 pr=3628 threads=PRRT_abc" "$(head -n 1 "$WORK/rvb.out")"
stop_waiter

# --- (sz) a SIZE-ESCALATE ledger row wakes the chief once ---
# gen-briefs writes the rows through size-override.sh; the waiter reads them through the same script.
SZ_NOTE="$HERE/size-override.sh"
reset_stub
fleet sz
export HANDOVER_DIR="$WORK/sz/hroot"; mkdir -p "$HANDOVER_DIR"
start "$I" "$WORK/sz.out"
wait_hb "$I" || fail "(sz) no baseline heartbeat"
sleep 1.5
check "(sz) an empty ledger wakes nothing" "" "$(cat "$WORK/sz.out")"
bash "$SZ_NOTE" note refuse HIMMEL-9201 N921 --files 41 --detail "41 files over the 40-file hard max" --root "$HANDOVER_DIR" >/dev/null 2>&1
wait_exit "$WPID"
check "(sz) a SIZE-ESCALATE row ends the wait" "0" "$rc"
check "(sz) the wake names the size event and the row count" "WAKE size rows=1" "$(head -n 1 "$WORK/sz.out")"
contains "(sz) the wake carries the row" "$(cat "$WORK/sz.out")" "refuse$(printf '\t')HIMMEL-9201$(printf '\t')N921$(printf '\t')41"
contains "(sz) the wake ends with the tick line" "$(cat "$WORK/sz.out")" "TICK 03:00"
start "$I" "$WORK/sz2.out"
wait_hb "$I" || fail "(sz) no re-arm heartbeat"
sleep 2.5
wait_exit "$WPID"
check "(sz) a re-arm does not wake for the same row" "running" "$rc"
bash "$SZ_NOTE" note bulk HIMMEL-9202 N922 --files 120 --detail "bulk: mechanical" --root "$HANDOVER_DIR" >/dev/null 2>&1
wait_exit "$WPID"
check "(sz) a later row wakes again" "0" "$rc"
check "(sz) the second wake counts two rows" "WAKE size rows=2" "$(head -n 1 "$WORK/sz2.out")"
contains "(sz) the second wake carries the new row" "$(cat "$WORK/sz2.out")" "bulk$(printf '\t')HIMMEL-9202"
lacks "(sz) the second wake does not repeat the first row" "$(cat "$WORK/sz2.out")" "HIMMEL-9201"
stop_waiter
unset HANDOVER_DIR

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
