#!/usr/bin/env bash
# console-bus-exec.sh <session> [--predecessor <old session>] -- <command...>
#
# The bus step of the console launch line an operator PASTES (console.sh new or
# next without --arm). That path has no launcher, so nothing registered or bound
# the console and its `bus send` failed with "identity unbound". This script is
# the launcher's half for it: register <session> as a console, bind THIS pid,
# then exec the command. exec keeps the pid and its start time, so the claude
# the command runs is the bound process, exactly what headed-arm.sh binds on
# the --arm path.
#
# Whatever HIMMEL_BUS_* the pasting shell carries (a console's own name is live
# in its shell) never reaches the command; HIMMEL_BUS_NAME is set only once the
# bind succeeded. Fail-open like do_arm: a failed register or bind warns and the
# console still starts, unbound. Each bus call is bounded by BUS_EXEC_SECS
# (default 15): the bus takes its chain lock with no wait limit, and a stuck
# lock must never hold the launch.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
session="$1"; shift
predecessor=""
if [ "${1:-}" = --predecessor ]; then predecessor="$2"; shift 2; fi
[ "${1:-}" = -- ] && shift

for bus_var in $(compgen -v HIMMEL_BUS_); do unset "$bus_var"; done
bus_cli="${CONSOLE_BUS_CLI:-$HERE/../../../marketplace/plugins/himmel-bus/bin/bus}"
bus_secs="${BUS_EXEC_SECS:-15}"
case "$bus_secs" in
    ''|*[!0-9]*) bus_secs=15 ;;
esac

# bus_bounded <args...> -- run the bus CLI with <args>, output into bus_out.
# Background + poll, as headed-arm.sh binds: past bus_secs the call gets TERM,
# one second of grace, then KILL, and returns 124.
bus_bounded() {
    local tmp pid n=0 rc=0
    tmp="$(mktemp "${TMPDIR:-/tmp}/console-bus-exec.XXXXXX" 2>/dev/null)" || tmp=/dev/null  # swallow-ok: the output only feeds the WARN text
    "$bus_cli" "$@" >"$tmp" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$n" -ge "$bus_secs" ]; then
            kill "$pid" 2>/dev/null
            sleep 1
            kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
            rc=124
            break
        fi
        sleep 1
        n=$((n + 1))
    done
    if [ "$rc" -eq 124 ]; then
        wait "$pid" 2>/dev/null
        bus_out="timed out after ${bus_secs}s: $(cat "$tmp" 2>/dev/null)"  # swallow-ok: WARN detail only
    else
        wait "$pid" 2>/dev/null || rc=$?
        bus_out="$(cat "$tmp" 2>/dev/null)"  # swallow-ok: WARN detail only
    fi
    [ "$tmp" = /dev/null ] || rm -f "$tmp"
    return "$rc"
}

bus_args=(register "$session" --role console)
[ -n "$predecessor" ] && bus_args+=(--predecessor "$predecessor")
if bus_bounded "${bus_args[@]}" && bus_bounded bind "$session" "$$"; then
    export HIMMEL_BUS_NAME="$session"
else
    echo "console-bus-exec: WARN bus registration failed for $session - launching unbound: $bus_out" >&2
fi
exec "$@"
