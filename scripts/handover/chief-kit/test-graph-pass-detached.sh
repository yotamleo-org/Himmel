#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # A && B || C is intentional in the row checks; $$ and $1 expand in the child, not here
# scripts/handover/chief-kit/test-graph-pass-detached.sh - suite for
# graph-pass-detached.sh, the wrapper that starts the graph pass detached from
# the chief that starts it, so a pass outlives its chief's window:
#   1. start returns at once, writes a state file holding the pid and log path,
#      and the pass runs in its own session
#   2. the pass is still alive after the launching shell's whole process group
#      is killed
#   3. a second start while one runs is refused, names the running pid, and
#      starts no second process
#   4. a state file whose pid is dead does not block a start
#   5. a state file whose pid is alive but is not the pass (a reused pid) does
#      not block a start
#   6. status prints running|finished|none with the pid and the log path
#
# Hermetic: the pass is a stub that loops; the real pass is never started.
# Platform guard: POSIX bash 3.2+, needs setsid and ps.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/graph-pass-detached.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/graph-pass-detached-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
tmp="$(cd "$tmp" && pwd)"
fails=0

# Every pid the stub ever logged, killed on the way out.
cleanup() {
    if [ -f "$tmp/starts" ]; then
        while IFS= read -r p; do kill "$p" 2>/dev/null || true; done < "$tmp/starts"
    fi
    [ -n "${decoy:-}" ] && kill "$decoy" 2>/dev/null
    rm -rf "$tmp"
}
trap cleanup EXIT

check()    { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains() {
    [ -n "$3" ] || { echo "FAIL - $1: empty needle"; fails=$((fails+1)); return; }
    case "$2" in *"$3"*) echo "ok - $1" ;; *) echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)) ;; esac
}
alive()    { kill -0 "$1" 2>/dev/null; }
state_val() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1; }
# Wait up to ~5 s for a pid to die (a killed orphan is reaped by init, not by us).
wait_dead() { n=0; while alive "$1" && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n+1)); done; }

# The stub pass: logs its pid, prints a line, then loops until killed.
stub="$tmp/stub-pass.sh"
printf '#!/bin/sh\necho "$$" >> "$STUB_STARTS"\necho "stub pass started"\nwhile :; do sleep 1; done\n' > "$stub"
chmod +x "$stub"
export STUB_STARTS="$tmp/starts"
export GRAPH_PASS_SCRIPT="$stub"
export GRAPH_PASS_STATE_DIR="$tmp/state"
STATE="$GRAPH_PASS_STATE_DIR/graph-pass.state"

# --- 1. start returns at once, writes the state file ---------------------
t0=$(date +%s)
out1="$(bash "$SCRIPT" start 2>&1)"; rc=$?
t1=$(date +%s)
check "1: start rc 0" "$rc" 0
[ $((t1 - t0)) -le 3 ] && echo "ok - 1: start returned at once" || { echo "FAIL - 1: start took $((t1 - t0))s"; fails=$((fails+1)); }
pid1="$(state_val "$STATE" pid)"
log1="$(state_val "$STATE" log)"
[ -n "$pid1" ] && alive "$pid1" && echo "ok - 1: state pid is alive" || { echo "FAIL - 1: state pid [$pid1] missing or dead"; fails=$((fails+1)); }
[ -n "$log1" ] && [ -f "$log1" ] && echo "ok - 1: state log path exists" || { echo "FAIL - 1: state log [$log1] missing"; fails=$((fails+1)); }
contains "1: start output names the pid" "$out1" "$pid1"
sid1="$(ps -o sid= -p "${pid1:-0}" 2>/dev/null | tr -d ' ')"
check "1: the pass leads its own session" "$sid1" "$pid1"
n=0; while [ ! -s "$tmp/starts" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n+1)); done
check "1: the stub ran once" "$(wc -l < "$tmp/starts" | tr -d ' ')" 1
contains "1: the log records the launcher choice" "$(cat "${log1:-/dev/null}" 2>/dev/null)" "launcher"

# --- 2. the pass outlives the launching shell's process group ------------
if [ -n "$pid1" ]; then kill "$pid1" 2>/dev/null; wait_dead "$pid1"; fi
rm -f "$STATE" "$tmp/starts"
setsid bash -c 'bash "$1" start; sleep 300' _ "$SCRIPT" > "$tmp/launch.out" 2>&1 < /dev/null &
lp=$!
n=0; while [ ! -s "$STATE" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n+1)); done
pid2="$(state_val "$STATE" pid)"
pg="$(ps -o pgid= -p "$lp" 2>/dev/null | tr -d ' ')"
[ -n "$pg" ] && kill -TERM -- "-$pg" 2>/dev/null
wait "$lp" 2>/dev/null
alive "$lp" && { echo "FAIL - 2: the launching shell survived its group kill"; fails=$((fails+1)); } || echo "ok - 2: the launching subtree is gone"
[ -n "$pid2" ] && alive "$pid2" && echo "ok - 2: the pass is alive after the launching subtree is gone" || { echo "FAIL - 2: the pass [$pid2] died with its launcher"; fails=$((fails+1)); }

# --- 3. a second start while one runs is refused -------------------------
out3="$(bash "$SCRIPT" start 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && echo "ok - 3: second start refused (rc $rc)" || { echo "FAIL - 3: second start rc 0"; fails=$((fails+1)); }
contains "3: the refusal names the running pid" "$out3" "$pid2"
sleep 0.5
check "3: no second process started" "$(wc -l < "$tmp/starts" | tr -d ' ')" 1
check "3: the state pid is unchanged" "$(state_val "$STATE" pid)" "$pid2"

# --- 6. status while it runs ---------------------------------------------
out6="$(bash "$SCRIPT" status 2>&1)"; rc=$?
check "6: status running rc 0" "$rc" 0
contains "6: status says running" "$out6" "running"
contains "6: status names the pid" "$out6" "pid=$pid2"
contains "6: status names the log" "$out6" "log=$(state_val "$STATE" log)"

# --- 4. a dead pid in the state file does not block a start --------------
kill "$pid2" 2>/dev/null; wait_dead "$pid2"
out6b="$(bash "$SCRIPT" status 2>&1)"
contains "6: status says finished once the pass is gone" "$out6b" "finished"
contains "6: status still names the log" "$out6b" "log="
bash "$SCRIPT" start >/dev/null 2>&1; rc=$?
check "4: start after a dead pid rc 0" "$rc" 0
pid4="$(state_val "$STATE" pid)"
[ -n "$pid4" ] && [ "$pid4" != "$pid2" ] && alive "$pid4" && echo "ok - 4: a new pass is running" || { echo "FAIL - 4: no new pass (pid [$pid4], old [$pid2])"; fails=$((fails+1)); }

# --- 5. a live pid that is not the pass does not block a start -----------
kill "$pid4" 2>/dev/null; wait_dead "$pid4"
sleep 300 &
decoy=$!
printf 'pid=%s\nlog=%s\nstarted=x\nlauncher=setsid\n' "$decoy" "$tmp/old.log" > "$STATE"
out5s="$(bash "$SCRIPT" status 2>&1)"
contains "5: status says finished for a reused pid" "$out5s" "finished"
bash "$SCRIPT" start >/dev/null 2>&1; rc=$?
check "5: start over a reused pid rc 0" "$rc" 0
pid5="$(state_val "$STATE" pid)"
[ -n "$pid5" ] && [ "$pid5" != "$decoy" ] && alive "$pid5" && echo "ok - 5: a new pass is running" || { echo "FAIL - 5: no new pass (pid [$pid5], decoy [$decoy])"; fails=$((fails+1)); }

# --- 7. two starts at once launch one pass --------------------------------
kill "$pid5" 2>/dev/null; wait_dead "$pid5"
rm -f "$STATE" "$tmp/starts"
bash "$SCRIPT" start > "$tmp/c1.out" 2>&1 &
c1=$!
bash "$SCRIPT" start > "$tmp/c2.out" 2>&1 &
c2=$!
rc1=0; wait "$c1" || rc1=$?
rc2=0; wait "$c2" || rc2=$?
sleep 0.5
check "7: exactly one of two simultaneous starts launched a pass" "$(wc -l < "$tmp/starts" | tr -d ' ')" 1
check "7: one start succeeded and the other was refused with rc 3" "$(printf '%s\n' "$rc1" "$rc2" | sort | tr '\n' ,)" "0,3,"

# --- 8. a state file that cannot be written stops the pass ----------------
pid7="$(state_val "$STATE" pid)"
[ -n "$pid7" ] && { kill "$pid7" 2>/dev/null; wait_dead "$pid7"; }
rm -f "$STATE" "$tmp/starts"
mkdir "$STATE.tmp"
out8="$(bash "$SCRIPT" start 2>&1)"; rc=$?
rmdir "$STATE.tmp"
[ "$rc" -ne 0 ] && echo "ok - 8: start failed when the state could not be written (rc $rc)" || { echo "FAIL - 8: start rc 0 with no state recorded"; fails=$((fails+1)); }
contains "8: the failure names the state directory" "$out8" "$GRAPH_PASS_STATE_DIR"
pid8="$(tail -n 1 "$tmp/starts" 2>/dev/null)"
[ -n "$pid8" ] && wait_dead "$pid8"
[ -n "$pid8" ] && ! alive "$pid8" && echo "ok - 8: the untracked pass was stopped" || { echo "FAIL - 8: a pass [$pid8] is left running with no state"; fails=$((fails+1)); }

# --- 6. status with no state file -----------------------------------------
rm -f "$STATE"
out6c="$(bash "$SCRIPT" status 2>&1)"; rc=$?
check "6: status none rc 0" "$rc" 0
check "6: status none" "$out6c" "none"

echo
[ "$fails" -eq 0 ] && { echo "PASS: all rows ok"; exit 0; } || { echo "FAIL: $fails row(s)"; exit 1; }
