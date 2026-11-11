#!/usr/bin/env bash
# scripts/handover/chief-kit/graph-pass-detached.sh - start the graph pass so it
# outlives the chief that started it.
#
# A pass the chief starts with the Bash tool's run_in_background is a child of
# the chief's Claude process and dies when the chief's window closes. This
# wrapper launches it in its own session (setsid nohup; systemd-run --user only
# when setsid is absent), records the pid and log path in a state file, and
# refuses a second start while one runs, so the next chief reads the state
# instead of re-running the pass.
#
#   graph-pass-detached.sh start    launch the pass; rc 3 while one is running
#   graph-pass-detached.sh status   running|finished|none, with pid=, log= (the
#                                   launcher's log) and pass_log= (the log the
#                                   pass itself writes: read that one for the promote)
#
# Exit: 0 started (start) or any answer (status); 1 the pass exited at once, or
#       its state could not be recorded and it was stopped;
#       2 usage, a pass script that is not executable, or no launcher;
#       3 start refused because a pass is already running or another start is
#       in progress.
#
# Seams (the suite points both at a stub and a temp dir):
#   GRAPH_PASS_SCRIPT     the pass; default ~/.claude/graphmap-cadence/graphmap-himmel.sh
#   GRAPH_PASS_STATE_DIR  state file and logs; default ~/.claude/graphmap-cadence/detached
#   GRAPH_PASS_LOG        the log the pass writes itself; default ~/.claude/graphmap-cadence/graphmap-himmel.log
set -uo pipefail

PASS="${GRAPH_PASS_SCRIPT:-$HOME/.claude/graphmap-cadence/graphmap-himmel.sh}"
PASS_LOG="${GRAPH_PASS_LOG:-$HOME/.claude/graphmap-cadence/graphmap-himmel.log}"
STATE_DIR="${GRAPH_PASS_STATE_DIR:-$HOME/.claude/graphmap-cadence/detached}"
STATE="$STATE_DIR/graph-pass.state"

state_val() { sed -n "s/^$1=//p" "$STATE" 2>/dev/null | head -n 1; }

# A recorded pid names a process only while it is alive AND its command line
# still carries <needle>: a file that outlives a reboot can name a reused pid.
proc_has() {
    [ -n "$1" ] || return 1
    kill -0 "$1" 2>/dev/null || return 1
    case "$(ps -p "$1" -o args= 2>/dev/null)" in  # swallow-ok: ps failing means the pid is gone, which is the not-running answer
        *"$2"*) return 0 ;;
        *) return 1 ;;
    esac
}
pass_running() { proc_has "$1" "$PASS"; }

CLAIM="$STATE_DIR/graph-pass.claim"
# ln is atomic and refuses an existing name, and the claim never shows up empty.
claim_try() {
    printf '%s\n' "$$" > "$CLAIM.$$" || return 1
    ln "$CLAIM.$$" "$CLAIM" 2>/dev/null  # swallow-ok: ln refusing an existing claim is the not-claimed answer
    rc=$?
    rm -f "$CLAIM.$$"
    return "$rc"
}
claim_takeover() {
    stale_holder="$1"
    mkdir "$CLAIM.takeover" 2>/dev/null || return 1  # swallow-ok: mkdir refusing means another starter is taking the claim over
    now="$(cat "$CLAIM" 2>/dev/null)"  # swallow-ok: a vanished claim reads empty, which only matches an empty holder
    if [ -z "$now" ]; then
        claim_try
        rc=$?
    elif [ "$now" = "$stale_holder" ]; then
        rm -f "$CLAIM"
        claim_try
        rc=$?
    else
        rc=1
    fi
    rmdir "$CLAIM.takeover"
    return "$rc"
}
claim_start() {
    claim_try && return 0
    holder="$(cat "$CLAIM" 2>/dev/null)"  # swallow-ok: a vanished claim reads empty and is taken over below
    proc_has "$holder" graph-pass-detached && return 1
    claim_takeover "$holder"
}
claim_release() {
    [ "$(cat "$CLAIM" 2>/dev/null)" = "$$" ] && rm -f "$CLAIM"  # swallow-ok: no claim file means nothing to release
}

cmd_status() {
    if [ ! -f "$STATE" ]; then echo none; return 0; fi
    pid="$(state_val pid)"; log="$(state_val log)"
    if pass_running "$pid"; then verdict=running; else verdict=finished; fi
    echo "$verdict pid=$pid log=$log pass_log=$PASS_LOG"
}

cmd_start() {
    mkdir -p "$STATE_DIR" || return 2
    if ! claim_start; then
        echo "graph-pass-detached: refused, another start is in progress (a start killed mid-way leaves $CLAIM*: remove them if no start is running)" >&2
        return 3
    fi
    trap claim_release EXIT
    if [ -f "$STATE" ]; then
        pid="$(state_val pid)"
        if pass_running "$pid"; then
            echo "graph-pass-detached: refused, a pass is already running: pid=$pid log=$(state_val log) pass_log=$PASS_LOG" >&2
            return 3
        fi
    fi
    [ -x "$PASS" ] || { echo "graph-pass-detached: the pass script is not executable: $PASS" >&2; return 2; }
    stamp="$(date +%Y%m%dT%H%M%S)"
    log="$STATE_DIR/graph-pass-$stamp.log"

    if command -v setsid >/dev/null 2>&1; then
        launcher=setsid
        echo "[graph-pass-detached launcher=setsid $(date '+%Y-%m-%d %H:%M:%S')]" > "$log"
        setsid nohup "$PASS" >> "$log" 2>&1 < /dev/null &
        pid=$!
    elif command -v systemd-run >/dev/null 2>&1; then
        launcher=systemd-run
        unit="graph-pass-$stamp"
        echo "[graph-pass-detached launcher=systemd-run unit=$unit $(date '+%Y-%m-%d %H:%M:%S')]" > "$log"
        systemd-run --user --quiet --unit="$unit" --collect \
            --property="StandardOutput=append:$log" --property="StandardError=append:$log" \
            "$PASS" || return 2
        pid="$(systemctl --user show -p MainPID --value "$unit" 2>/dev/null)"  # swallow-ok: an empty pid is caught by the liveness check below
    else
        echo "graph-pass-detached: neither setsid nor systemd-run is available" >&2
        return 2
    fi

    sleep 0.2
    # pid 0 is the caller's own process group, which kill -0 reports alive.
    case "$pid" in ''|*[!0-9]*|0) pid=0 ;; esac
    if [ "$pid" -le 0 ] || ! kill -0 "$pid" 2>/dev/null; then
        echo "graph-pass-detached: the pass exited at once; see $log" >&2
        return 1
    fi
    if ! { printf 'pid=%s\nlog=%s\nstarted=%s\nlauncher=%s\n' "$pid" "$log" "$stamp" "$launcher" > "$STATE.tmp" \
        && mv -f "$STATE.tmp" "$STATE"; }; then
        kill "$pid" 2>/dev/null  # swallow-ok: the pass may already be gone, which is what this wants
        echo "graph-pass-detached: could not record the state in $STATE_DIR; the pass was stopped" >&2
        return 1
    fi
    echo "graph-pass-detached: started pid=$pid log=$log pass_log=$PASS_LOG launcher=$launcher"
}

case "${1:-}" in
    start) cmd_start ;;
    status) cmd_status ;;
    *) echo "usage: graph-pass-detached.sh start|status" >&2; exit 2 ;;
esac
