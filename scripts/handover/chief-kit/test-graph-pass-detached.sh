#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # A && B || C is intentional in the row checks; $$ and $1 expand in the child, not here
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/graph-pass-detached.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/graph-pass-detached-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
tmp="$(cd "$tmp" && pwd)"
fails=0

stop_stubs() {
    [ -f "$tmp/starts.ever" ] || return 0
    while IFS= read -r p; do
        case "$(ps -p "$p" -o args= 2>/dev/null)" in  # swallow-ok: ps failing means the pid is gone
            *"$tmp/stub-pass"*) kill -- "-$p" 2>/dev/null || kill "$p" 2>/dev/null ;;
        esac
    done < "$tmp/starts.ever"
    return 0
}
cleanup() {
    stop_stubs
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

stub="$tmp/stub-pass.sh"
cat > "$stub" <<'EOF'
#!/bin/sh
echo "$$" >> "$STUB_EVER"
echo "$$" >> "$STUB_STARTS"
echo "stub pass started"
dir="${0%/*}"
i=0
# A suite killed with SIGKILL cannot run its trap: the stub ends when its dir is
# gone or after STUB_MAX seconds, so none outlives the run by more than that.
while [ -d "$dir" ] && [ "$i" -lt "${STUB_MAX:-120}" ]; do sleep 1; i=$((i+1)); done
EOF
chmod +x "$stub"
export STUB_STARTS="$tmp/starts"
export STUB_EVER="$tmp/starts.ever"
export GRAPH_PASS_SCRIPT="$stub"
export GRAPH_PASS_STATE_DIR="$tmp/state"
export GRAPH_PASS_LOG="$tmp/pass-own.log"
STATE="$GRAPH_PASS_STATE_DIR/graph-pass.state"

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
contains "1: start output names the pass's own log" "$out1" "pass_log=$GRAPH_PASS_LOG"
sid_of() { python3 -c 'import os,sys; print(os.getsid(int(sys.argv[1])))' "$1" 2>/dev/null; }  # swallow-ok: a gone pid reads empty and fails the row
sid1="$(sid_of "${pid1:-0}")"
check "1: the pass leads its own session" "$sid1" "$pid1"
n=0; while [ ! -s "$tmp/starts" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n+1)); done
check "1: the stub ran once" "$(wc -l < "$tmp/starts" | tr -d ' ')" 1
contains "1: the log records the launcher choice" "$(cat "${log1:-/dev/null}" 2>/dev/null)" "launcher"

if [ -n "$pid1" ]; then kill "$pid1" 2>/dev/null; wait_dead "$pid1"; fi
rm -f "$STATE" "$tmp/starts"
if command -v setsid >/dev/null 2>&1; then
    setsid bash -c 'bash "$1" start; sleep 300' _ "$SCRIPT" > "$tmp/launch.out" 2>&1 < /dev/null &
else
    python3 -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' bash -c 'bash "$1" start; sleep 300' _ "$SCRIPT" > "$tmp/launch.out" 2>&1 < /dev/null &
fi
lp=$!
n=0; while [ ! -s "$STATE" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n+1)); done
pid2="$(state_val "$STATE" pid)"
pg="$(ps -o pgid= -p "$lp" 2>/dev/null | tr -d ' ')"
[ -n "$pg" ] && kill -TERM -- "-$pg" 2>/dev/null
wait "$lp" 2>/dev/null
alive "$lp" && { echo "FAIL - 2: the launching shell survived its group kill"; fails=$((fails+1)); } || echo "ok - 2: the launching subtree is gone"
[ -n "$pid2" ] && alive "$pid2" && echo "ok - 2: the pass is alive after the launching subtree is gone" || { echo "FAIL - 2: the pass [$pid2] died with its launcher"; fails=$((fails+1)); }

out3="$(bash "$SCRIPT" start 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && echo "ok - 3: second start refused (rc $rc)" || { echo "FAIL - 3: second start rc 0"; fails=$((fails+1)); }
contains "3: the refusal names the running pid" "$out3" "$pid2"
sleep 0.5
check "3: no second process started" "$(wc -l < "$tmp/starts" | tr -d ' ')" 1
check "3: the state pid is unchanged" "$(state_val "$STATE" pid)" "$pid2"

out6="$(bash "$SCRIPT" status 2>&1)"; rc=$?
check "6: status running rc 0" "$rc" 0
contains "6: status says running" "$out6" "running"
contains "6: status names the pid" "$out6" "pid=$pid2"
contains "6: status names the log" "$out6" "log=$(state_val "$STATE" log)"
contains "6: status names the pass's own log" "$out6" "pass_log=$GRAPH_PASS_LOG"

kill "$pid2" 2>/dev/null; wait_dead "$pid2"
out6b="$(bash "$SCRIPT" status 2>&1)"
contains "6: status says finished once the pass is gone" "$out6b" "finished"
contains "6: status still names the log" "$out6b" "log="
bash "$SCRIPT" start >/dev/null 2>&1; rc=$?
check "4: start after a dead pid rc 0" "$rc" 0
pid4="$(state_val "$STATE" pid)"
[ -n "$pid4" ] && [ "$pid4" != "$pid2" ] && alive "$pid4" && echo "ok - 4: a new pass is running" || { echo "FAIL - 4: no new pass (pid [$pid4], old [$pid2])"; fails=$((fails+1)); }

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

CLAIM="$GRAPH_PASS_STATE_DIR/graph-pass.claim"
rm -f "$STATE" "$tmp/starts"
sleep 0 & dead9=$!
wait "$dead9"
printf '%s\n' "$dead9" > "$CLAIM"
bash "$SCRIPT" start > "$tmp/d1.out" 2>&1 &
d1=$!
bash "$SCRIPT" start > "$tmp/d2.out" 2>&1 &
d2=$!
bash "$SCRIPT" start > "$tmp/d3.out" 2>&1 &
d3=$!
rd1=0; wait "$d1" || rd1=$?
rd2=0; wait "$d2" || rd2=$?
rd3=0; wait "$d3" || rd3=$?
sleep 0.5
check "9: three starts over a stale claim launched exactly one pass" "$(wc -l < "$tmp/starts" | tr -d ' ')" 1
check "9: one start succeeded and the others were refused with rc 3" "$(printf '%s\n' "$rd1" "$rd2" "$rd3" | sort | tr '\n' ,)" "0,3,3,"
[ ! -e "$CLAIM" ] && [ ! -e "$CLAIM.takeover" ] && echo "ok - 9: the claim and the takeover lock are released once the start is over" || { echo "FAIL - 9: a claim file or takeover lock is left behind"; fails=$((fails+1)); }
pid9="$(state_val "$STATE" pid)"
[ -n "$pid9" ] && { kill "$pid9" 2>/dev/null; wait_dead "$pid9"; }

rm -f "$STATE" "$tmp/starts"
pbin="$tmp/pybin"; mkdir "$pbin"
for t in bash sh mkdir date sed head ps sleep ln rm cat mv nohup python3; do
    p="$(command -v "$t")" && ln -s "$p" "$pbin/$t"
done
PATH="$pbin" bash "$SCRIPT" start >/dev/null 2>&1; rc=$?
check "16: start with no setsid and no systemd-run rc 0" "$rc" 0
pid16="$(state_val "$STATE" pid)"
check "16: the state records the python-setsid launcher" "$(state_val "$STATE" launcher)" "python-setsid"
check "16: the pass leads its own session without setsid" "$(sid_of "${pid16:-0}")" "$pid16"
[ -n "$pid16" ] && { kill "$pid16" 2>/dev/null; wait_dead "$pid16"; }

bin="$tmp/bin"; mkdir "$bin"
for t in bash sh mkdir date sed head ps sleep ln rm cat mv; do
    p="$(command -v "$t")" && ln -s "$p" "$bin/$t"
done
printf '#!/bin/sh\nexit 0\n' > "$bin/systemd-run"
printf '#!/bin/sh\ncat "%s/mainpid"\n' "$tmp" > "$bin/systemctl"
chmod +x "$bin/systemd-run" "$bin/systemctl"
rm -f "$STATE"
echo 0 > "$tmp/mainpid"
out10="$(PATH="$bin" bash "$SCRIPT" start 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && echo "ok - 10: a unit whose MainPID reads 0 is not reported as started (rc $rc)" || { echo "FAIL - 10: start rc 0 for MainPID 0"; fails=$((fails+1)); }
contains "10: the failure says the pass exited" "$out10" "exited"
[ ! -f "$STATE" ] && echo "ok - 10: no state recorded for the failed start" || { echo "FAIL - 10: state written for MainPID 0"; fails=$((fails+1)); }
sleep 300 &
live10=$!
echo "$live10" > "$tmp/mainpid"
PATH="$bin" bash "$SCRIPT" start >/dev/null 2>&1; rc=$?
check "10: start through systemd-run rc 0" "$rc" 0
check "10: the state names the unit's MainPID" "$(state_val "$STATE" pid)" "$live10"
check "10: the state records the launcher" "$(state_val "$STATE" launcher)" "systemd-run"
contains "10: the log records the launcher choice" "$(cat "$(state_val "$STATE" log)" 2>/dev/null)" "launcher=systemd-run"
kill "$live10" 2>/dev/null

rm -f "$STATE" "$tmp/starts" "$CLAIM"
shim="$tmp/shim"; mkdir "$shim"
printf '#!/bin/sh\nn=$("$REAL_CAT" "$SHIM_N" 2>/dev/null)\nn=$((n+1))\necho "$n" > "$SHIM_N"\ncase "$n" in\n    1) rm -f "$CLAIM_FILE" ;;\n    2) echo 424242 > "$CLAIM_FILE" ;;\n    *) exec "$REAL_CAT" "$@" ;;\nesac\n' > "$shim/cat"
chmod +x "$shim/cat"
printf '777777\n' > "$CLAIM"
REAL_CAT="$(command -v cat)" SHIM_N="$shim/n" CLAIM_FILE="$CLAIM" PATH="$shim:$PATH" bash "$SCRIPT" start >/dev/null 2>&1; rc=$?
check "11: a start whose holder read comes back empty gives way to a fresh claim (rc 3)" "$rc" 3
check "11: the fresh claim is left in place" "$(cat "$CLAIM" 2>/dev/null)" "424242"
[ ! -s "$tmp/starts" ] && echo "ok - 11: no pass was started" || { echo "FAIL - 11: a pass was started over a fresh claim"; fails=$((fails+1)); }
[ ! -e "$CLAIM.takeover" ] && echo "ok - 11: the takeover lock is released" || { echo "FAIL - 11: the takeover lock is left behind"; fails=$((fails+1)); }

rm -f "$STATE" "$tmp/starts" "$CLAIM"
bash "$SCRIPT" start > "$tmp/e1.out" 2>&1 &
e1=$!
bash "$SCRIPT" start > "$tmp/e2.out" 2>&1 &
e2=$!
bash "$SCRIPT" start > "$tmp/e3.out" 2>&1 &
e3=$!
re1=0; wait "$e1" || re1=$?
re2=0; wait "$e2" || re2=$?
re3=0; wait "$e3" || re3=$?
sleep 0.5
check "12: three overlapping starts with no claim launched exactly one pass" "$(wc -l < "$tmp/starts" | tr -d ' ')" 1
check "12: one start succeeded and the others were refused with rc 3" "$(printf '%s\n' "$re1" "$re2" "$re3" | sort | tr '\n' ,)" "0,3,3,"
pid12="$(state_val "$STATE" pid)"
[ -n "$pid12" ] && { kill "$pid12" 2>/dev/null; wait_dead "$pid12"; }

rm -f "$STATE"
out6c="$(bash "$SCRIPT" status 2>&1)"; rc=$?
check "6: status none rc 0" "$rc" 0
check "6: status none" "$out6c" "none"

rm -f "$STATE" "$tmp/starts" "$CLAIM"
bash "$SCRIPT" start >/dev/null 2>&1
pid13="$(state_val "$STATE" pid)"
n=0; while [ ! -s "$tmp/starts" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n+1)); done
rm -f "$tmp/starts"
stop_stubs
[ -n "$pid13" ] && wait_dead "$pid13"
[ -n "$pid13" ] && ! alive "$pid13" && echo "ok - 13: stop_stubs stops a stub whose start was dropped from the per-row file" || { echo "FAIL - 13: stub [$pid13] outlived stop_stubs"; fails=$((fails+1)); }

stubs_alive=0
if [ -f "$tmp/starts.ever" ]; then
    while IFS= read -r p; do alive "$p" && stubs_alive=$((stubs_alive+1)); done < "$tmp/starts.ever"
fi
check "14: no stub this suite started is still alive" "$stubs_alive" 0

STUB_MAX=2 bash "$SCRIPT" start >/dev/null 2>&1
pid15="$(state_val "$STATE" pid)"
[ -n "$pid15" ] && { n=0; while alive "$pid15" && [ "$n" -lt 60 ]; do sleep 0.1; n=$((n+1)); done; }
[ -n "$pid15" ] && ! alive "$pid15" && echo "ok - 15: a stub exits by itself once its lifetime cap passes" || { echo "FAIL - 15: stub [$pid15] outlived its cap"; fails=$((fails+1)); }

seqstub="$tmp/stub-pass-seq.sh"
cat > "$seqstub" <<'EOF'
#!/bin/sh
n=$(cat "$SEQ_DIR/n" 2>/dev/null || echo 0)
n=$((n+1))
echo "$n" > "$SEQ_DIR/n"
echo "$$" >> "$STUB_EVER"
code=$(sed -n "${n}p" "$SEQ_DIR/codes")
[ -n "$code" ] || code=$(tail -n 1 "$SEQ_DIR/codes")
if [ "$code" = hold ]; then
    i=0
    while [ -d "$SEQ_DIR" ] && [ "$i" -lt 60 ]; do sleep 1; i=$((i+1)); done
    exit 0
fi
[ ! -f "$SEQ_DIR/delay" ] || sleep "$(cat "$SEQ_DIR/delay")"
exit "$code"
EOF
chmod +x "$seqstub"
sstart() {
    sd="$tmp/s-$1"; mkdir -p "$sd"; printf '%s\n' "$2" | tr ' ' '\n' > "$sd/codes"; rm -f "$sd/n"; [ -z "${3:-}" ] || echo "$3" > "$sd/delay"
    SEQ_DIR="$sd" GRAPH_PASS_STATE_DIR="$sd/state" GRAPH_PASS_SCRIPT="${STUB:-$seqstub}" bash "$SCRIPT" start >/dev/null 2>&1
}
sstatus() { GRAPH_PASS_STATE_DIR="$tmp/s-$1/state" bash "$SCRIPT" status 2>&1; }
swait() {
    n=0; while [ "$n" -lt 100 ]; do case "$(sstatus "$1")" in *"$2"*) return 0 ;; esac; sleep 0.1; n=$((n+1)); done
}

sstart 17 "4 4 0"; check "17: series start rc 0" "$?" 0
swait 17 "finished"; out17="$(sstatus 17)"
contains "17: a series that ends 0 reports finished promoted" "$out17" "finished promoted"
contains "17: status names pass 3" "$out17" "pass=3"
contains "17: status names last_exit 0" "$out17" "last_exit=0"
check "17: three passes ran" "$(cat "$tmp/s-17/n")" 3
check "17: the series file records pass 3" "$(state_val "$tmp/s-17/state/graph-pass.series" pass)" 3
check "17: the series file records last_exit 0" "$(state_val "$tmp/s-17/state/graph-pass.series" last_exit)" 0
check "17: the series file records promoted" "$(state_val "$tmp/s-17/state/graph-pass.series" series)" promoted
contains "17: the launcher log records each pass" "$(cat "$tmp/s-17/state"/graph-pass-*.log)" "pass 3 exit rc=0"

sstart 18 "4 5" 0.5; swait 18 "finished"; out18="$(sstatus 18)"
contains "18: a non-4 exit stops the series as finished failed rc=5" "$out18" "finished failed rc=5"
check "18: the series stopped after two passes" "$(cat "$tmp/s-18/n")" 2

sstart 19 "4"; swait 19 "finished"; out19="$(sstatus 19)"
contains "19: a pass that always exits 4 ends exhausted" "$out19" "finished exhausted"
check "19: the series stopped at the bound" "$(cat "$tmp/s-19/n")" 5

sstart 20 "4 hold"; swait 20 "pass=2"; out20="$(sstatus 20)"
contains "20: mid-series status says running" "$out20" "running"
contains "20: mid-series status says resumable, continuing" "$out20" "resumable, continuing"
contains "20: mid-series status names last_exit 4" "$out20" "last_exit=4"
case "$out20" in *failed*) echo "FAIL - 20: mid-series status says failed"; fails=$((fails+1)) ;; *) echo "ok - 20: mid-series status never says failed" ;; esac
GRAPH_PASS_STATE_DIR="$tmp/s-20/state" bash "$SCRIPT" start >/dev/null 2>&1; rc=$?
check "21: a second start mid-series is refused rc 3" "$rc" 3
pid20="$(state_val "$tmp/s-20/state/graph-pass.state" pid)"
[ -n "$pid20" ] && { kill "$pid20" 2>/dev/null; wait_dead "$pid20"; }

sstart 22 "5"; check "22: a pass that fails at once makes start exit 1" "$?" 1

runstub="$tmp/stub-runner.sh"
cat > "$runstub" <<EOF
#!/bin/sh
{
    _rc=0; "$seqstub" || _rc=\$?
    echo "[exit rc=\$_rc]"
} >> "\$SEQ_DIR/pass.log" 2>&1
exit "\$_rc"
EOF
chmod +x "$runstub"
STUB="$runstub" sstart 23 "4 4 0"; swait 23 "finished"; out23="$(sstatus 23)"
contains "23: a runner-shaped pass resumes on exit 4 and promotes" "$out23" "finished promoted"
check "23: the runner-shaped series ran three passes" "$(cat "$tmp/s-23/n")" 3
STUB="$runstub" sstart 24 "4 5" 0.5; swait 24 "finished"; out24="$(sstatus 24)"
contains "24: a runner-shaped pass that exits 5 ends failed rc=5" "$out24" "finished failed rc=5"
STUB="$runstub" sstart 25 "2" 0.5; swait 25 "finished"; out25="$(sstatus 25)"
contains "25: a runner-shaped pass that exits 2 ends failed rc=2" "$out25" "finished failed rc=2"
v28stub="$tmp/stub-runner-v28.sh"
cat > "$v28stub" <<EOF
#!/bin/sh
{
    _rc=0; "$seqstub" || _rc=\$?
    echo "[exit rc=\$_rc]"
} >> "\$SEQ_DIR/pass.log" 2>&1
EOF
chmod +x "$v28stub"
STUB="$v28stub" sstart 26 "4 0"; swait 26 "finished"; out26="$(sstatus 26)"
contains "26: a v28-shaped runner hides the cap exit, so the series reads promoted after one pass" "$out26" "finished promoted"
check "26: the v28-shaped series ran one pass" "$(cat "$tmp/s-26/n")" 1

echo
[ "$fails" -eq 0 ] && { echo "PASS: all rows ok"; exit 0; } || { echo "FAIL: $fails row(s)"; exit 1; }
