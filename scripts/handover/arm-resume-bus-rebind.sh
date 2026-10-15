#!/usr/bin/env bash
# arm-resume-bus-rebind.sh <name> <bus-cli> <log> [wait-secs] [rebind-secs]
#
# An armed resume launches a NEW claude pid, so the session's name
# stays bound to the dead pid on the himmel-bus and `bus send` is refused.
# arm-resume.sh backgrounds this next to the launch (only when <name> already
# has a bus peer file). It waits for the child claude whose argv carries
# `-n <name>` (the exact-argv check headed-arm.sh uses), then runs
# `bus rebind <name> <pid>` ONCE, bounded like headed-arm.sh's bind:
# poll, TERM, one second of grace, KILL.
#
# Fail-open: a missing child, a refused rebind or a hung bus is a WARN line in
# <log> and exit 0 - it never touches the launch it runs beside.
#
# Seam: ARM_RESUME_PROC overrides /proc (tests).

NAME="${1:-}"; BUS_CLI="${2:-}"; LOG="${3:-/dev/null}"
WAIT_SECS="${4:-60}"; REBIND_SECS="${5:-15}"
case "$WAIT_SECS" in ''|*[!0-9]*) WAIT_SECS=60 ;; esac
case "$REBIND_SECS" in ''|*[!0-9]*) REBIND_SECS=15 ;; esac
PROC="${ARM_RESUME_PROC:-/proc}"
[ -n "$NAME" ] && [ -n "$BUS_CLI" ] || exit 0

# shellcheck source=argv-has-n-name.sh
. "$(cd "$(dirname "$0")" && pwd)/argv-has-n-name.sh"

[ "$LOG" = /dev/null ] || mkdir -p "$(dirname "$LOG")" 2>/dev/null

warn() { echo "$(date +%F_%T) WARN: bus rebind of $NAME $1" >> "$LOG" 2>/dev/null; }

matches() { # matches <pid-dir>: a claude whose argv has -n <name>
    [ "$(cat "$1/comm" 2>/dev/null)" = claude ] && _argv_has_n_name "${1##*/}"
}

start_of() { # start_of <pid-dir>: field 22 of stat (start time), empty if unreadable
    local s f
    s="$(cat "$1/stat" 2>/dev/null)" || return 0
    s="${s##*) }"
    read -ra f <<< "$s"
    printf '%s' "${f[19]:-}"
}

# The resumed child starts AFTER this helper (it is backgrounded just before
# the launch), so a matching claude that started before us is the OLD session.
# No ordering race: compares kernel start times, not a snapshot. An unreadable
# start time on either side fails open to "eligible".
self_start="$(start_of /proc/$$)"

find_child() { # prints the first NEW claude pid whose argv has -n <name>
    local d pid st
    for d in "$PROC"/[0-9]*; do
        pid="${d##*/}"
        matches "$d" || continue
        st="$(start_of "$d")"
        if [ -n "$st" ] && [ -n "$self_start" ] \
            && [ "$st" -eq "$st" ] 2>/dev/null && [ "$self_start" -eq "$self_start" ] 2>/dev/null \
            && [ "$st" -lt "$self_start" ]; then
            continue
        fi
        printf '%s\n' "$pid"; return 0
    done
    return 1
}

child=""
n=0
while :; do
    child="$(find_child)" && break
    [ "$n" -lt "$WAIT_SECS" ] || break
    sleep 1
    n=$((n + 1))
done
if [ -z "$child" ]; then
    warn "skipped - no claude with -n $NAME appeared within ${WAIT_SECS}s - session stays unbound"
    exit 0
fi

tmp="$(mktemp "${TMPDIR:-/tmp}/arm-resume-bus-rebind.XXXXXX" 2>/dev/null)" || tmp=/dev/null
"$BUS_CLI" rebind "$NAME" "$child" >"$tmp" 2>&1 &
bus_pid=$!
n=0
timed_out=0
while kill -0 "$bus_pid" 2>/dev/null; do
    if [ "$n" -ge "$REBIND_SECS" ]; then
        kill "$bus_pid" 2>/dev/null
        timed_out=1
        sleep 1
        kill -0 "$bus_pid" 2>/dev/null && kill -9 "$bus_pid" 2>/dev/null
        break
    fi
    sleep 1
    n=$((n + 1))
done
rc=0
wait "$bus_pid" 2>/dev/null || rc=$?
if [ "$timed_out" -eq 1 ] || [ "$rc" -ne 0 ]; then
    out="$(cat "$tmp" 2>/dev/null)"
    [ "$timed_out" -eq 1 ] && out="timed out after ${REBIND_SECS}s: $out"
    warn "to pid $child failed - session stays unbound: $out"
fi
[ "$tmp" = /dev/null ] || rm -f "$tmp"
exit 0
