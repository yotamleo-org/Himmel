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
# console still starts, unbound.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
session="$1"; shift
predecessor=""
if [ "${1:-}" = --predecessor ]; then predecessor="$2"; shift 2; fi
[ "${1:-}" = -- ] && shift

for bus_var in $(compgen -v HIMMEL_BUS_); do unset "$bus_var"; done
bus_cli="${CONSOLE_BUS_CLI:-$HERE/../../../marketplace/plugins/himmel-bus/bin/bus}"
bus_args=(register "$session" --role console)
[ -n "$predecessor" ] && bus_args+=(--predecessor "$predecessor")
if bus_out="$("$bus_cli" "${bus_args[@]}" 2>&1)" && bus_out="$("$bus_cli" bind "$session" "$$" 2>&1)"; then
    export HIMMEL_BUS_NAME="$session"
else
    echo "console-bus-exec: WARN bus registration failed for $session - launching unbound: $bus_out" >&2
fi
exec "$@"
