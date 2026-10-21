#!/usr/bin/env bash
# test-console-wait-r0.sh — Exercises console-wait.sh's script relay (R0): with
# --doc and --legs-from, a leg whose tails= turns WRAPPED (or whose acts= turns
# MERGED) is wrapped by the waiter itself through leg-event.sh, with no wake:
#
#   (r0a) a MERGED leg that leg-event HANDLES: no wake, one digest line naming the
#         leg and PR; the next WAKE block prints the digest and clears it
#   (r0b) leg-event ESCALATE (rc 10): WAKE leg-event <line> out=<file>, once; a
#         re-arm does not wake for the same bullet again
#   (r0c) a refusal that only means "not yet" (rc=3 lock held): no WAKE leg-event,
#         retried on the next sample; a standing one falls back to WAKE tick
#   (r0h) the same refusal text on another rc (a timeout) is a leg-event wake
#   (r0d) a RETASK token in the bullet never reaches leg-event, the WAKE line or
#         the out file
#   (r0e) without --legs-from the waiter never calls leg-event
#   (r0f) two legs: N2 changed a sample before the relay absorbs N1's wrap, and
#         N2's change still wakes
#   (r0g) two legs: N1's wrap and N2's change in one sample, then the manifest
#         move N1's wrap made: N2's change still wakes
#   (r0i) a window turning closable on the sample N1's wrap is absorbed still wakes
#
# tick.sh, the bank verdict and leg-event.sh are stubbed (CONSOLE_WAIT_TICK,
# CONSOLE_WAIT_BANK, CONSOLE_WAIT_LEG_EVENT): nothing closes a window here.
#
# Linux-only: console-wait.sh has no .ps1 twin by design; this suite uses GNU
# timeout, so run-shell-tests.sh skips it off-Linux.
#
# Run: bash scripts/handover/console-kit/test-console-wait-r0.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WAIT="${CONSOLE_WAIT:-$HERE/console-wait.sh}"

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

WORK="$(mktemp -d "${TMPDIR:-/tmp}/console-wait-r0-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$WORK"' EXIT

STUB="$WORK/stub"
mkdir -p "$STUB"
cat > "$STUB/tick.sh" <<'EOF'
#!/usr/bin/env bash
cat "$STUB/tick.line"
EOF
cat > "$STUB/bank.sh" <<'EOF'
#!/usr/bin/env bash
cat "$STUB/bank"
EOF
# leg-event stub: records its args and stdin per call, prints le.out, exits le.rc.
cat > "$STUB/leg-event.sh" <<'EOF'
#!/usr/bin/env bash
n=$(( $(cat "$STUB/le.calls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB/le.calls"
printf '%s\n' "$*" > "$STUB/le.args"
cat > "$STUB/le.stdin"
# le.rm: act like wrap-merged, drop N1 from the manifest and from the tick line
if [ -f "$STUB/le.rm" ]; then
    jq -c '.legs |= map(select(.label != "N1"))' "$4" > "$4.tmp" && mv "$4.tmp" "$4"
    cp "$STUB/tick.after" "$STUB/tick.line"
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
export CONSOLE_WAIT_TICK="$STUB/tick.sh" CONSOLE_WAIT_BANK="$STUB/bank.sh"
export CONSOLE_WAIT_LEG_EVENT="$STUB/leg-event.sh" CONSOLE_WAIT_BUDGET="$STUB/budget-off.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/sweep-off.sh"
export WAIT_SWEEP_CMD="$STUB/sweep-off.sh" WAIT_FOCUS_CMD="$STUB/sweep-off.sh"
export CONSOLE_WAIT_INTERVAL=1 CONSOLE_WAIT_POLL_SEC=0.2 CONSOLE_WAIT_FAIL_WAKE=1000
export HIMMEL_DENIAL_ACK_DIR="$WORK/acks"

# tick_line <tails> [acts]: a tick line with that tails= (and acts=, when given).
tick_line() {
    printf 'TICK 03:00 hb=1m legs=N1:FRESH livestate=ok procs=2 models=x ceiling=ok atq=0 suites=0alive/0dead prs=#10 bank=5h8/wk15/codex=? fill=40 tails=%s%s inbox=none tick=UNKNOWN fleet=3/15 capacity=ok gql=4000/04:00 orphans=none nonces=ok legset=ok board=ok denials=none\n' \
        "$1" "${2:+ acts=$2}" > "$STUB/tick.line"
}
reset_stub() { rm -f "$STUB"/le.*; tick_line "N1:LIVE"; printf 'PROCEED\n' > "$STUB/bank"; printf 'HANDLED wrap-merged N1\n' > "$STUB/le.out"; echo 0 > "$STUB/le.rc"; }
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
# fleet <case>: a console doc, a leg doc and a one-leg manifest; sets I, D, L, M.
fleet() {
    mkdir -p "$WORK/$1/consoles"; I="$WORK/$1/consoles/c.md"; : > "$I"
    D="$WORK/$1/console.md"; printf '# console\n' > "$D"
    L="$WORK/$1/HIMMEL-1-N1-a.md"; printf '# leg\n\n## Results\n- 09:00 LIVE — started\n' > "$L"
    M="$WORK/$1/console.fleet.json"
    printf '{"schema":1,"legs":[{"doc":"%s","label":"N1"}]}\n' "$L" > "$M"
}
start() { # <inbox> <outfile> [tick args...]
    local inbox="$1" out="$2"; shift 2
    bash "$WAIT" "$inbox" "$@" > "$out" 2>"$out.err" &
    WPID=$!
}

# --- (r0a) a MERGED leg the relay handles: no wake, a digest line ------------
reset_stub
fleet r0a
start "$I" "$WORK/r0a.out" --doc "$D" --legs-from "$M"
wait_hb "$I" || fail "(r0a) no baseline heartbeat"
printf -- '- 10:00 READY #2566 abcdef GREEN\n- 10:30 MERGED #2566 → abcdef01\n' >> "$L"
tick_line "N1:LIVE" "N1:MERGED#1"
wait_exit "$WPID"
check "(r0a) a handled MERGED does not wake the console" "running" "$rc"
check "(r0a) and prints nothing" "" "$(cat "$WORK/r0a.out")"
check "(r0a) leg-event ran once" "1" "$(cat "$STUB/le.calls" 2>/dev/null)"
check "(r0a) on the bullet, labelled" "N1 MERGED #2566 → abcdef01" "$(cat "$STUB/le.stdin" 2>/dev/null)"
check "(r0a) with the console doc and the manifest" "--doc $D --fleet $M -" "$(cat "$STUB/le.args" 2>/dev/null)"
check "(r0a) the digest names the leg and the PR" "N1 wrap-merged 2566" "$(cat "$I.wait.digest" 2>/dev/null)"
printf -- '- 03:45 [telegram from=1 chat=2] hello\n' >> "$I"
wait_exit "$WPID"
check "(r0a) the next wake prints the digest" "$(printf 'WAKE telegram\n- 03:45 [telegram from=1 chat=2] hello\nabsorbed since last wake: wraps=1 (N1) merged=1 (#2566)')" "$(cat "$WORK/r0a.out")"
check "(r0a) and clears it" "" "$(cat "$I.wait.digest" 2>/dev/null)"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# --- (r0b) ESCALATE wakes once with the out file -----------------------------
reset_stub
fleet r0b
printf 'ESCALATE ambiguous-label\n' > "$STUB/le.out"; echo 10 > "$STUB/le.rc"
start "$I" "$WORK/r0b.out" --doc "$D" --legs-from "$M"
wait_hb "$I" || fail "(r0b) no baseline heartbeat"
printf -- '- 11:00 WRAPPED — N1 done, N2 next\n' >> "$L"
tick_line "N1:WRAPPED"
wait_exit "$WPID"
check "(r0b) an ESCALATE wakes (rc 0)" "0" "$rc"
check "(r0b) naming leg-event, the line and the out file" "WAKE leg-event ESCALATE ambiguous-label out=$I.wait.le-N1" "$(head -n 1 "$WORK/r0b.out")"
check "(r0b) then the tick line" "$(cat "$STUB/tick.line")" "$(sed -n 2p "$WORK/r0b.out")"
check "(r0b) the out file holds leg-event's output" "ESCALATE ambiguous-label" "$(cat "$I.wait.le-N1" 2>/dev/null)"
start "$I" "$WORK/r0b2.out" --doc "$D" --legs-from "$M"
wait_hb "$I" || fail "(r0b) no re-arm baseline heartbeat"
sleep 2.5
wait_exit "$WPID"
check "(r0b) a re-arm does not wake for the same bullet" "running" "$rc"
check "(r0b) nor runs leg-event again" "1" "$(cat "$STUB/le.calls" 2>/dev/null)"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# --- (r0c) a lock-held refusal is retried, never a leg-event wake ------------
reset_stub
fleet r0c
printf 'ESCALATE wrap-merged-failed rc=3 close-wrapped-leg: refusing - queue lock held\n' > "$STUB/le.out"; echo 10 > "$STUB/le.rc"
start "$I" "$WORK/r0c.out" --doc "$D" --legs-from "$M"
wait_hb "$I" || fail "(r0c) no baseline heartbeat"
printf -- '- 11:00 WRAPPED — done\n' >> "$L"
tick_line "N1:WRAPPED"
wait_exit "$WPID"
lacks "(r0c) a lock-held refusal is not a leg-event wake" "$(cat "$WORK/r0c.out")" "WAKE leg-event"
check "(r0c) it was asked again on the next sample" "2" "$(cat "$STUB/le.calls" 2>/dev/null)"
check "(r0c) the standing refusal falls back to the tick wake" "WAKE tick changed=tails bank=PROCEED" "$(head -n 1 "$WORK/r0c.out")"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# --- (r0h) the same refusal text on a non-10 rc (a timeout) wakes at once -----
reset_stub
fleet r0h
printf 'ESCALATE wrap-merged-failed rc=3 close-wrapped-leg: refusing - queue lock held\n' > "$STUB/le.out"; echo 124 > "$STUB/le.rc"
start "$I" "$WORK/r0h.out" --doc "$D" --legs-from "$M"
wait_hb "$I" || fail "(r0h) no baseline heartbeat"
printf -- '- 11:00 WRAPPED — done\n' >> "$L"
tick_line "N1:WRAPPED"
wait_exit "$WPID"
check "(r0h) rc 124 is a leg-event wake, not a retry" "WAKE leg-event ESCALATE wrap-merged-failed rc=3 close-wrapped-leg: refusing - queue lock held out=$I.wait.le-N1" "$(head -n 1 "$WORK/r0h.out")"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# --- (r0d) no RETASK token reaches leg-event, the wake or the out file -------
reset_stub
fleet r0d
touch "$STUB/le.echo"; echo 10 > "$STUB/le.rc"
start "$I" "$WORK/r0d.out" --doc "$D" --legs-from "$M"
wait_hb "$I" || fail "(r0d) no baseline heartbeat"
printf -- '- 11:00 WRAPPED — quoted BD-N1-f14f9339 deferred\n' >> "$L"
tick_line "N1:WRAPPED"
wait_exit "$WPID"
check "(r0d) the escalate wakes (rc 0)" "0" "$rc"
lacks "(r0d) leg-event never sees the token" "$(cat "$STUB/le.stdin" 2>/dev/null)" "f14f9339"
lacks "(r0d) the wake carries no token" "$(cat "$WORK/r0d.out")" "f14f9339"
lacks "(r0d) the out file carries no token" "$(cat "$I.wait.le-N1" 2>/dev/null)" "f14f9339"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# --- (r0e) without --legs-from leg-event never runs --------------------------
reset_stub
fleet r0e
start "$I" "$WORK/r0e.out" --doc "$D" --legs "$L"
wait_hb "$I" || fail "(r0e) no baseline heartbeat"
printf -- '- 11:00 WRAPPED — done\n' >> "$L"
tick_line "N1:WRAPPED"
wait_exit "$WPID"
check "(r0e) the tick change wakes as before" "WAKE tick changed=tails bank=PROCEED" "$(head -n 1 "$WORK/r0e.out")"
check "(r0e) leg-event never ran" "" "$(cat "$STUB/le.calls" 2>/dev/null)"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# fleet2 <case>: fleet plus a second leg N2 in the manifest; sets L2 too.
fleet2() {
    fleet "$1"
    L2="$WORK/$1/HIMMEL-2-N2-b.md"; printf '# leg\n\n## Results\n- 09:00 LIVE — started\n' > "$L2"
    printf '{"schema":1,"legs":[{"doc":"%s","label":"N1"},{"doc":"%s","label":"N2"}]}\n' "$L" "$L2" > "$M"
}

# --- (r0f) another leg's change a sample before the absorbed wrap still wakes -
reset_stub
fleet2 r0f
tick_line "N1:LIVE,N2:LIVE"
start "$I" "$WORK/r0f.out" --doc "$D" --legs-from "$M"
wait_hb "$I" || fail "(r0f) no baseline heartbeat"
tick_line "N1:LIVE,N2:BLOCKED"
sleep 1.3
printf -- '- 11:00 WRAPPED — done\n' >> "$L"
tick_line "N1:WRAPPED,N2:BLOCKED"
wait_exit "$WPID"
check "(r0f) N2's change wakes (rc 0)" "0" "$rc"
check "(r0f) as a tick wake on tails" "WAKE tick changed=tails bank=PROCEED" "$(head -n 1 "$WORK/r0f.out")"
contains "(r0f) the absorbed N1 wrap is in the digest" "$(cat "$WORK/r0f.out")" "absorbed since last wake: wraps=1 (N1)"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# --- (r0g) a change beside the wrap survives the manifest move it makes -------
reset_stub
fleet2 r0g
tick_line "N1:LIVE,N2:LIVE"
start "$I" "$WORK/r0g.out" --doc "$D" --legs-from "$M"
wait_hb "$I" || fail "(r0g) no baseline heartbeat"
tick_line "N2:BLOCKED"; cp "$STUB/tick.line" "$STUB/tick.after"; touch "$STUB/le.rm"
printf -- '- 11:00 WRAPPED — done\n' >> "$L"
tick_line "N1:WRAPPED,N2:BLOCKED"
wait_exit "$WPID"
check "(r0g) N2's change wakes (rc 0)" "0" "$rc"
check "(r0g) as a tick wake on tails" "WAKE tick changed=tails bank=PROCEED" "$(head -n 1 "$WORK/r0g.out")"
check "(r0g) the relay dropped N1 from the manifest" "N2" "$(jq -r '.legs[].label' "$M")"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# --- (r0i) a window turning closable beside the absorbed wrap still wakes -----
reset_stub
fleet2 r0i
tick_line "N1:LIVE,N2:LIVE"
start "$I" "$WORK/r0i.out" --doc "$D" --legs-from "$M"
wait_hb "$I" || fail "(r0i) no baseline heartbeat"
printf -- '- 11:00 WRAPPED — done\n' >> "$L"
tick_line "N1:WRAPPED,N2:LIVE"; printf '%s closable=1\n' "$(cat "$STUB/tick.line")" > "$STUB/tick.line.new"; mv "$STUB/tick.line.new" "$STUB/tick.line"
wait_exit "$WPID"
check "(r0i) the closable rise wakes (rc 0)" "0" "$rc"
check "(r0i) as a tick wake on closable" "WAKE tick changed=closable bank=PROCEED" "$(head -n 1 "$WORK/r0i.out")"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
