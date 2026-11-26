#!/usr/bin/env bash
# scripts/handover/chief-kit/test-chief-wait-heal.sh - suite for the waiter's station heal:
# chief-wait.sh starts `station-sync.sh --heal` once the tick's station= field has read BEHIND:<components>
# for three consecutive good samples. Hermetic: tick, bank, himmel-update and the template upgrader are stubs.
#
# Cases:
#   1. a station that reads BEHIND over three samples   -> one heal, started with --bucket/--chief of the chief doc
#   2. no station= field (an up-to-date station)        -> no heal (negative control)
#   3. BEHIND:pending (a sync in flight)                -> no heal
#   4. a failing heal                                   -> one owed row, and a later waiter starts no second heal
#
# Platform guard: Linux bash 3.2+.
# shellcheck disable=SC2016  # single-quoted stub bodies expand at run time
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WAIT="${CHIEF_WAIT:-$HERE/chief-wait.sh}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi; }
contains() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (no '$3' in '$2')" ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/chief-wait-heal-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$WORK"' EXIT
export HOME="$WORK/home"; mkdir -p "$HOME"

STUB="$WORK/stub"; mkdir -p "$STUB"
printf '#!/usr/bin/env bash\necho tick >> "$STUB/tick.calls"\ncat "$STUB/tick.line"\n' > "$STUB/tick.sh"
printf '#!/usr/bin/env bash\necho PROCEED\n' > "$STUB/bank.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/off.sh"
printf '#!/usr/bin/env bash\nexit 2\n' > "$STUB/budget-off.sh"
printf '#!/usr/bin/env bash\necho "heal $*" >> "$STUB/heal.calls"\nexit 0\n' > "$STUB/heal-ok.sh"
printf '#!/usr/bin/env bash\necho "heal $*" >> "$STUB/heal.calls"\nexec bash "$STATION_SYNC" "$@"\n' > "$STUB/heal-real.sh"
STATION_SYNC="$HERE/station-sync.sh"
export STUB STATION_SYNC CHIEF_WAIT_TICK="$STUB/tick.sh" CHIEF_WAIT_USAGE="$STUB/bank.sh" CHIEF_WAIT_BUDGET="$STUB/budget-off.sh"
export WAIT_SWEEP_CMD="$STUB/off.sh" WAIT_FOCUS_CMD="$STUB/off.sh" CHIEF_WAIT_DISPATCH="$STUB/off.sh"
export CHIEF_WAIT_INTERVAL=1 CHIEF_WAIT_POLL_SEC=0.2 CHIEF_WAIT_FAIL_WAKE=1000
export HIMMEL_DENIAL_ACK_DIR="$WORK/acks"

cat > "$STUB/versions" <<'EOF2'
==> himmel ecosystem versions
    component      state    installed   available   note
    himmel         current  v1          v1
    jira_cli       behind   built       source
    1 behind, 0 undetermined.
EOF2
cat > "$STUB/update.sh" <<'EOF2'
#!/usr/bin/env bash
case "$1" in
    --only) printf '%s\n' "error: build exploded" >&2; exit 1 ;;
    --versions) cat "$STUB/versions"; exit 1 ;;
esac
exit 0
EOF2
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/upgrade.sh"
chmod +x "$STUB"/*.sh
export SS_UPDATE="$STUB/update.sh" SS_UPGRADE="$STUB/upgrade.sh" SS_STATE="$WORK/station-sync.state" SS_PRIMARY="$WORK" \
       SS_VAULT="$WORK/vault" SS_QMD_CLONE="$WORK/no-such-clone"
mkdir -p "$WORK/vault"

tick_line() {
    printf 'TICK 03:00 hb=1m workers=N1:FREE livestate=ok procs=2 models=x ceiling=ok atq=0 suites=0alive/0dead prs=#10 bank=5h8/wk15/codex=? fill=40 tails=N1:? inbox=none tick=UNKNOWN fleet=3/15 capacity=ok gql=4000/04:00 orphans=none nonces=ok legset=ok board=ok denials=none or=skip%s\n' "$1" > "$STUB/tick.line"
}

mkdir -p "$WORK/in/consoles"
inbox="$WORK/in/consoles/c.md"; : > "$inbox"
chief="$WORK/chief.md"
reset() { rm -f "$inbox".wait* "$STUB/heal.calls" "$STUB/tick.calls" "$WORK/owed.jsonl" "$WORK/station-heal.ts" "$SS_STATE"; printf '%s\n' '# chief' > "$chief"; }
run_waiter() {
    bash "$WAIT" "$inbox" --doc "$chief" > "$1" 2>/dev/null &
    local wp=$! n=0
    while [ "$n" -lt "$2" ] && kill -0 "$wp" 2>/dev/null; do sleep 0.1; n=$((n+1)); done
    if kill -0 "$wp" 2>/dev/null; then kill "$wp" 2>/dev/null; wait "$wp" 2>/dev/null; return 1; fi
    wait "$wp" 2>/dev/null
}
count() { [ -f "$1" ] && grep -c . "$1" || echo 0; }
owed_rows() { bash "$HERE/owe.sh" list --bucket "$WORK" 2>/dev/null | grep -c . || true; }

reset
export CHIEF_WAIT_STATION="$STUB/heal-ok.sh"
tick_line ' station=BEHIND:plugins,jira_cli'
run_waiter "$WORK/o1a.out" 60 > /dev/null
contains '1 control: the first sight wakes the chief' "$(cat "$WORK/o1a.out")" 'WAKE station BEHIND:plugins,jira_cli'
run_waiter "$WORK/o1.out" 60 > /dev/null
if [ "$(count "$STUB/tick.calls")" -ge 4 ]; then pass '1 control: the re-armed waiter sampled at least three more times'; else fail "1 control: the waiters sampled $(count "$STUB/tick.calls") times: $(cat "$WORK/o1.out")"; fi
check '1 a station BEHIND over several samples is healed once' 1 "$(count "$STUB/heal.calls")"
contains '1 the heal is started for the chief doc directory and stem' "$(cat "$STUB/heal.calls" 2>/dev/null)" "heal --heal --bucket $WORK --chief chief"

reset
tick_line ''
run_waiter "$WORK/o2.out" 50 > /dev/null
if [ "$(count "$STUB/tick.calls")" -ge 4 ]; then pass '2 control: the waiter sampled at least four times'; else fail "2 control: the waiter sampled $(count "$STUB/tick.calls") times"; fi
check '2 an up-to-date station runs no heal' 0 "$(count "$STUB/heal.calls")"

reset
tick_line ' station=BEHIND:pending'
run_waiter "$WORK/o3a.out" 60 > /dev/null
run_waiter "$WORK/o3.out" 50 > /dev/null
if [ "$(count "$STUB/tick.calls")" -ge 4 ]; then pass '3 control: the waiter sampled at least four times'; else fail "3 control: the waiter sampled $(count "$STUB/tick.calls") times"; fi
check '3 a sync in flight is not healed' 0 "$(count "$STUB/heal.calls")"

reset
export CHIEF_WAIT_STATION="$STUB/heal-real.sh"
printf '%s\n' 'BEHIND:jira_cli' > "$SS_STATE"
tick_line ' station=BEHIND:jira_cli'
run_waiter "$WORK/o4a.out" 60 > /dev/null
run_waiter "$WORK/o4.out" 50 > /dev/null
n=0; while [ "$n" -lt 50 ] && [ "$(owed_rows)" -lt 1 ]; do sleep 0.1; n=$((n+1)); done
check '4 a failing heal leaves one owed row' 1 "$(owed_rows)"
check '4 the first waiter started one heal' 1 "$(count "$STUB/heal.calls")"
run_waiter "$WORK/o4b.out" 50 > /dev/null
sleep 1
check '4 a later waiter inside the back-off starts no second heal' 1 "$(count "$STUB/heal.calls")"
check '4 and the owed row is not repeated' 1 "$(owed_rows)"

reset
export CHIEF_WAIT_STATION="$STUB/heal-ok.sh"
tick_line ' station=BEHIND:plugins'
run_waiter "$WORK/o5.out" 60 > /dev/null
contains '5 control: the single sample wakes the chief' "$(cat "$WORK/o5.out")" 'WAKE station BEHIND:plugins'
check '5 one BEHIND sample counts one and records no heal start' '1 0' "$(sed -n 1p "$inbox.wait.station-heal") $(sed -n 2p "$inbox.wait.station-heal")"
check '5 one BEHIND sample runs no heal' 0 "$(count "$STUB/heal.calls")"

reset
printf '#!/usr/bin/env bash\necho tick >> "$STUB/tick.calls"\ncat "$STUB/tick.line"\nexit 1\n' > "$STUB/tick-fail.sh"
chmod +x "$STUB/tick-fail.sh"
tick_line ' station=BEHIND:plugins'
printf '2\n0\n' > "$inbox.wait.station-heal"
CHIEF_WAIT_TICK="$STUB/tick-fail.sh" run_waiter "$WORK/o6.out" 50 > /dev/null
if [ "$(count "$STUB/tick.calls")" -ge 4 ]; then pass '6 control: the waiter sampled at least four times'; else fail "6 control: the waiter sampled $(count "$STUB/tick.calls") times"; fi
check '6 a failing tick runs no heal' 0 "$(count "$STUB/heal.calls")"
check '6 and leaves the streak as it was' '2 0' "$(sed -n 1p "$inbox.wait.station-heal") $(sed -n 2p "$inbox.wait.station-heal")"

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed"; exit 1
