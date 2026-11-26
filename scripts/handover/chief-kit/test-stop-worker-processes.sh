#!/usr/bin/env bash
# Tests for scripts/handover/chief-kit/stop-worker-processes.sh.
#
# Usage: bash scripts/handover/chief-kit/test-stop-worker-processes.sh
#
# The fixture processes sleep; none of them burns CPU. Each runs a script out of
# a fixture scratchpad dir.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STOP="$SCRIPT_DIR/stop-worker-processes.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/himmel-stop-worker.XXXXXX")" || exit 1
PIDS=()
cleanup() {
    [ "${#PIDS[@]}" -eq 0 ] || kill -KILL "${PIDS[@]}" 2>/dev/null
    rm -rf "$TMP"
}
trap cleanup EXIT

export STOP_WORKER_PROCESSES_ROOT="$TMP"
UID_N=$(id -u)
SP="$TMP/claude-$UID_N/proj-a/sess-a/scratchpad"
OTHER="$TMP/claude-$UID_N/proj-a/sess-b/scratchpad"
PREFIX="${SP}-x"
mkdir -p "$SP" "$OTHER" "$PREFIX"
for d in "$SP" "$OTHER" "$PREFIX"; do
    cat >"$d/hold.sh" <<'HOLD'
#!/usr/bin/env bash
while :; do sleep 1; done
HOLD
done

pass=0
fail=0
ok()  { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }
alive() { kill -0 "$1" 2>/dev/null; }
rc_is() {
    if [ "$rc" = "$1" ]; then ok "$2"; else bad "$2 (rc=$rc)"; fi
}
up() {
    if alive "$1"; then ok "$2"; else bad "$2"; fi
}
down() {
    if alive "$1"; then bad "$2"; else ok "$2"; fi
}

start() {
    bash "$1/hold.sh" >/dev/null 2>&1 &
    STARTED=$!
    PIDS+=("$STARTED")
}

run_stop() {
    out=$(env -u HIMMEL_WORKER bash "$STOP" "$@" 2>&1)
    rc=$?
}

start "$SP"; A1=$STARTED
start "$SP"; A2=$STARTED
start "$OTHER"; B1=$STARTED
start "$PREFIX"; C1=$STARTED
( cd "$SP" && exec sleep 300 ) &
CWD1=$!
PIDS+=("$CWD1")
sleep 1

echo "== dry run lists and stops nothing =="
run_stop "$SP"
rc_is 0 "dry run exits 0"
case $out in *"$A1"*"$A2"*"$CWD1"*"stopped=0 killed=0 remaining=0"*) ok "dry run lists both scripts and the cwd process" ;; *) bad "dry run lists them: $out" ;; esac
up "$A1" "dry run leaves the first script alive"
up "$A2" "dry run leaves the second script alive"
up "$CWD1" "dry run leaves the cwd process alive"

echo "== --live ends the named scratchpad's processes only =="
run_stop "$SP" --live
rc_is 0 "--live exits 0"
case $out in *"killed=0 remaining=0"*) ok "--live ends them all by TERM" ;; *) bad "--live report: $out" ;; esac
down "$A1" "the first named script is gone"
down "$A2" "the second named script is gone"
down "$CWD1" "the cwd process is gone"
up "$B1" "another scratchpad's process survives"
up "$C1" "a sibling dir sharing the path prefix survives"

echo "== a process that ignores TERM is killed =="
cat >"$SP/stubborn.sh" <<'STUBBORN'
#!/usr/bin/env bash
trap '' TERM
while :; do sleep 1; done
STUBBORN
bash "$SP/stubborn.sh" >/dev/null 2>&1 &
S1=$!
PIDS+=("$S1")
sleep 1
run_stop "$SP" --live
case $out in *" killed=0 "*) bad "KILL follows an ignored TERM: $out" ;; *"remaining=0"*) ok "KILL follows an ignored TERM" ;; *) bad "KILL follows an ignored TERM: $out" ;; esac
down "$S1" "the stubborn process is gone"

echo "== a descendant that names no scratchpad path is stopped with its parent =="
DESC="$TMP/claude-$UID_N/proj-a/sess-c/scratchpad"
mkdir -p "$DESC"
cat >"$DESC/spawn.sh" <<'SPAWN'
#!/usr/bin/env bash
(cd / && exec sleep 300) &
echo $! > "$(dirname "$0")/child.pid"
wait
SPAWN
bash "$DESC/spawn.sh" >/dev/null 2>&1 &
D1=$!
PIDS+=("$D1")
sleep 1
DCHILD=$(cat "$DESC/child.pid")
PIDS+=("$DCHILD")
run_stop "$DESC"
case $out in *"$DCHILD"*) ok "dry run lists the sleep child that names no scratchpad path" ;; *) bad "dry run lists the child: $out" ;; esac
run_stop "$DESC" --live
rc_is 0 "--live exits 0 with a descendant"
case $out in *"stopped=2 killed=0 remaining=0"*) ok "--live reports the parent and the child stopped" ;; *) bad "--live descendant report: $out" ;; esac
down "$DCHILD" "the sleep child is gone"
down "$D1" "the parent script is gone"
run_stop "$DESC"
case $out in *"matched=0 "*) ok "no process of that scratchpad is left" ;; *) bad "a process is left: $out" ;; esac

echo "== nothing matched =="
run_stop "$SP" --live
rc_is 0 "no match exits 0"
case $out in *"matched=0 stopped=0 killed=0 remaining=0"*) ok "no match reports matched=0" ;; *) bad "no match report: $out" ;; esac

echo "== refusals =="
run_stop
rc_is 2 "no path: usage, exit 2"
run_stop "claude-$UID_N/proj-a/sess-a/scratchpad"
rc_is 2 "a relative path is refused"
run_stop "$SP/../sess-b/scratchpad"
rc_is 2 "a .. path is refused"
run_stop "$TMP/claude-$UID_N/proj-a/sess-a"
rc_is 2 "a parent of the scratchpad is refused"
run_stop "$SP/sub"
rc_is 2 "a dir below the scratchpad is refused"
run_stop "$TMP"
rc_is 2 "the root is refused"
run_stop "$TMP/claude-$UID_N/proj-a/*/scratchpad"
rc_is 2 "a glob is refused"
run_stop "$SP" --bogus
rc_is 2 "an unknown flag is refused"
run_stop "$SP" "$OTHER"
rc_is 2 "two paths are refused"
up "$B1" "the refusals stopped nothing (other scratchpad)"
up "$C1" "the refusals stopped nothing (prefix sibling)"

out=$(HIMMEL_WORKER=1 bash "$STOP" "$OTHER" --live 2>&1); rc=$?
rc_is 3 "a dispatched worker is refused, exit 3"
up "$B1" "the refused worker call stopped nothing"

echo
echo "test-stop-worker-processes: $pass passed, $fail failed"
[ "$fail" = 0 ]
