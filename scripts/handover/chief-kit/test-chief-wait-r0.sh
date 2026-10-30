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
#   Run only the wrap-bound regressions with --wrap-relay.
#   (hd)  holds=: a worker entering the set wakes once; ageing, a worker leaving and the set
#         emptying do not wake
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
if [ -f "$STUB/le.retry-first" ] && grep -q '^N1 ' "$STUB/le.stdin"; then
    printf 'ESCALATE wrap-merged-failed rc=3 close-wrapped-worker: refusing - queue lock held\n'
    exit 10
fi
# le.rm: act like wrap-merged, drop N1 from the manifest and from the tick line
if [ -f "$STUB/le.rm" ]; then
    jq -c '.legs |= map(select(.label != "N1"))' "$4" > "$4.tmp" && mv "$4.tmp" "$4"
    rm -f "$STUB/tick.seq"
    cp "$STUB/tick.after" "$STUB/tick.line.new" && mv "$STUB/tick.line.new" "$STUB/tick.line"
fi
if [ -f "$STUB/le.echo" ]; then printf 'ESCALATE unfiled-residual: %s\n' "$(cat "$STUB/le.stdin")"
else cat "$STUB/le.out"; fi
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
    printf '{"schema":1,"legs":[{"doc":"%s","label":"N1"}]}\n' "$L" > "$M"
    export HB_FILE="$I.wait"
}
start() { # <inbox> <outfile> [tick args...]
    local inbox="$1" out="$2"; shift 2
    bash "$WAIT" "$inbox" "$@" > "$out" 2>"$out.err" &
    WPID=$!
}

# fleet2 <case>: fleet plus a second worker N2 in the manifest; sets L2 too.
fleet2() {
    fleet "$1"
    L2="$WORK/$1/HIMMEL-2-N2-b.md"; printf '# worker\n\n## Results\n- 09:00 LIVE — started\n' > "$L2"
    printf '{"schema":1,"legs":[{"doc":"%s","label":"N1"},{"doc":"%s","label":"N2"}]}\n' "$L" "$L2" > "$M"
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
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

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
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
# --- (r0m/n) keep the relay within the heartbeat consumers' contract --------
# Match the variable name literally in the source.
# shellcheck disable=SC2016
check "(r0m) bound under stop guard" 1 "$(grep -cE 'timeout -k 5 ([1-9][0-9]|1[0-9][0-9]|2[0-8][0-9]) bash "\$leg_event_cmd"' "$WAIT")"
check "(r0n) header names relay bound" 1 "$(sed -n 214,219p "$WAIT" | grep -c 'relay')"

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
    kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
done
reset_stub
fleet r0o-output
echo 7 > "$STUB/le.rc"; printf 'worker-event failed during close\n' > "$STUB/le.out"
start "$I" "$WORK/r0o-output.out" --doc "$D" --workers-from "$M"
wait_hb "$I" || fail "(r0o) no output-case heartbeat"
printf -- '- 11:00 WRAPPED — done\n' >> "$L"; tick_line "N1:WRAPPED"
wait_exit "$WPID"
contains "(r0o) an output-bearing failure still records its rc" "$(head -n 1 "$WORK/r0o-output.out")" "rc=7 out=$I.wait.le-N1"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

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
    kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
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
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
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
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

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
check "(r0b) then the tick line" "$(cat "$STUB/tick.line")" "$(sed -n 2p "$WORK/r0b.out")"
check "(r0b) the out file holds worker-event's output" "ESCALATE ambiguous-label" "$(cat "$I.wait.le-N1" 2>/dev/null)"
start "$I" "$WORK/r0b2.out" --doc "$D" --workers-from "$M"
wait_hb "$I" || fail "(r0b) no re-arm baseline heartbeat"
sleep 2.5
wait_exit "$WPID"
check "(r0b) a re-arm does not wake for the same bullet" "running" "$rc"
check "(r0b) nor runs worker-event again" "1" "$(cat "$STUB/le.calls" 2>/dev/null)"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

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
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

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
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

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
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

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
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

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
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
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
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

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
check "(r0g) the relay dropped N1 from the manifest" "N2" "$(jq -r '.legs[].label' "$M")"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

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
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

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
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

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
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

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
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

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
    kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
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
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# a BLOCKED resolve followed by a MERGED bullet is retired too
reset_stub
fleet rvm
printf -- '- 10:00 BLOCKED resolve 3628 PRRT_abc — denied\n- 10:30 MERGED #3628 abc1234 — merged\n' >> "$L"
start "$I" "$WORK/rvm.out" --doc "$D" --workers-from "$M"
wait_hb "$I" || fail "(rv-merged) no baseline heartbeat"
sleep 2.5
wait_exit "$WPID"
check "(rv-merged) a BLOCKED resolve before a MERGED bullet does not wake" "running" "$rc"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# a later PARKED-USAGE bullet retires a BLOCKED resolve
reset_stub
fleet rvp
printf -- '- 10:00 BLOCKED resolve 3628 PRRT_abc — denied\n- 10:40 PARKED-USAGE — weekly cap\n' >> "$L"
start "$I" "$WORK/rvp.out" --doc "$D" --workers-from "$M"
wait_hb "$I" || fail "(rv-parked) no baseline heartbeat"
sleep 2.5
wait_exit "$WPID"
check "(rv-parked) a BLOCKED resolve before a PARKED-USAGE bullet does not wake" "running" "$rc"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

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
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
