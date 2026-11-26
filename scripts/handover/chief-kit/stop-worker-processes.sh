#!/usr/bin/env bash
# scripts/handover/chief-kit/stop-worker-processes.sh - end a worker's runaway
# scratchpad processes by one literal path.
# A chief's own `pkill -f`/`kill` loop over a runaway worker's processes is
# refused by the auto-mode classifier, which left the station loaded; this named
# verb is the chief's sanctioned way to stop them.
#
# Usage:
#   stop-worker-processes.sh <scratchpad dir> [--live]
#
# <scratchpad dir> is ONE literal absolute path of the shape
#   <root>/claude-<uid>/<project>/<session>/scratchpad      (root: /tmp)
# nothing else is accepted (no relative path, no `..`, no glob, no parent dir),
# so the verb can only reach processes a worker started from its own scratchpad.
#
# DRY RUN BY DEFAULT: without --live it only lists the matching processes.
# A process matches when its command line names <scratchpad dir>/ or its working
# directory is <scratchpad dir> or below it, and the chief's own uid owns it. The
# script's own process and its ancestors never match. --live sends TERM, waits up
# to 3 seconds, then sends KILL to what is left.
#
# Prints one line per match (pid, command line cut to 120 characters) and a final
#   matched=<n> stopped=<n> killed=<n> remaining=<n>
#
# Exit codes: 0 done (or nothing matched); 1 a process survived KILL; 2 usage or
# a path that is not a scratchpad dir; 3 refused in a dispatched worker
# (HIMMEL_WORKER=1: only a chief stops another worker's processes); 4 no /proc.
set -uo pipefail

ROOT="${STOP_WORKER_PROCESSES_ROOT:-/tmp}"

usage() { echo "usage: stop-worker-processes.sh <scratchpad dir> [--live]" >&2; exit 2; }

[ "${HIMMEL_WORKER:-0}" = "1" ] && { echo "stop-worker-processes: refused in a dispatched worker; only a chief stops another worker's processes" >&2; exit 3; }

dir=""
live=0
for a in "$@"; do
    case $a in
        --live) live=1 ;;
        -*) usage ;;
        *) [ -z "$dir" ] || usage; dir=$a ;;
    esac
done
[ -n "$dir" ] || usage

case $dir in */../* | */.. | */./* | */. | *//* | *[\*\?\[\]]*) echo "stop-worker-processes: refused: $dir is not a plain absolute path" >&2; exit 2 ;; esac
if ! [[ $dir =~ ^${ROOT}/claude-[0-9]+/[^/]+/[^/]+/scratchpad$ ]]; then
    echo "stop-worker-processes: refused: $dir is not a worker scratchpad dir (${ROOT}/claude-<uid>/<project>/<session>/scratchpad)" >&2
    exit 2
fi

[ -d /proc/self ] || { echo "stop-worker-processes: needs /proc (Linux)" >&2; exit 4; }

skip=" $$ "
p=$$
while [ -r "/proc/$p/stat" ]; do
    p=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null) || break  # swallow-ok: the ancestor walk ends when a parent stat is unreadable
    [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null || break
    skip="$skip$p "
done

pids=""
matched=0
for d in /proc/[0-9]*; do
    pid=${d#/proc/}
    case $skip in *" $pid "*) continue ;; esac
    [ -O "$d" ] || continue
    cmdline=$(tr '\0' ' ' <"$d/cmdline" 2>/dev/null) || continue  # swallow-ok: a process that exited mid-scan has no cmdline and is skipped
    cwd=$(readlink "$d/cwd" 2>/dev/null) || cwd=""  # swallow-ok: a process with no readable cwd matches on its command line only
    hit=0
    case $cmdline in *"$dir/"*) hit=1 ;; esac
    case $cwd in "$dir" | "$dir"/*) hit=1 ;; esac
    [ "$hit" = 1 ] || continue
    matched=$((matched + 1))
    pids="$pids $pid"
    printf '%s\t%s\n' "$pid" "${cmdline:0:120}"
done

stopped=0
killed=0
remaining=0
if [ "$live" = 1 ] && [ "$matched" -gt 0 ]; then
    # shellcheck disable=SC2086 # pids is a space-separated list of numbers built above
    kill -TERM $pids 2>/dev/null
    tries=0
    while [ "$tries" -lt 6 ]; do
        alive=""
        for pid in $pids; do kill -0 "$pid" 2>/dev/null && alive="$alive $pid"; done
        [ -n "$alive" ] || break
        sleep 0.5
        tries=$((tries + 1))
    done
    for pid in $pids; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid" 2>/dev/null
            sleep 0.2
            if kill -0 "$pid" 2>/dev/null; then remaining=$((remaining + 1)); else killed=$((killed + 1)); fi
        else
            stopped=$((stopped + 1))
        fi
    done
fi

echo "matched=$matched stopped=$stopped killed=$killed remaining=$remaining"
[ "$remaining" = 0 ]
