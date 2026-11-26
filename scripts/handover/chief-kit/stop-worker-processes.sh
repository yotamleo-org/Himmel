#!/usr/bin/env bash
# scripts/handover/chief-kit/stop-worker-processes.sh - end a worker's runaway
# scratchpad processes by one literal path.
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
# directory is <scratchpad dir> or below it, or when it descends from such a process,
# and the chief's own uid owns it. A signal is sent only while the process still has
# the start time it had when listed, so a recycled pid is never signalled. The
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

stat_fields() { sed 's/.*) //' "/proc/$1/stat" 2>/dev/null; }  # swallow-ok: a process that exited has no stat and reads as empty

ppid_of() { stat_fields "$1" | awk '{print $2}'; }

starttime() { stat_fields "$1" | awk '$1 == "Z" {exit} {print $20}'; }

skip=" $$ "
p=$$
while [ -r "/proc/$p/stat" ]; do
    p=$(ppid_of "$p")
    [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null || break
    skip="$skip$p "
done

pids=""
idents=""
matched=0
pairs=""

enroll() {
    pids="$pids $1"
    idents="$idents $1:$2"
    matched=$((matched + 1))
    printf '%s\t%s\n' "$1" "$(tr '\0' ' ' <"/proc/$1/cmdline" 2>/dev/null | cut -c1-120)"  # swallow-ok: a process gone since the scan prints an empty command line
}

for d in /proc/[0-9]*; do
    pid=${d#/proc/}
    case $skip in *" $pid "*) continue ;; esac
    [ -O "$d" ] || continue
    fields=$(stat_fields "$pid")
    # shellcheck disable=SC2086 # the stat fields are plain words
    set -- $fields
    [ -n "${20:-}" ] && [ "$1" != Z ] || continue
    pairs="$pairs $pid:$2:${20}"
    cmdline=$(tr '\0' ' ' <"$d/cmdline" 2>/dev/null) || continue  # swallow-ok: a process that exited mid-scan has no cmdline and is skipped
    cwd=$(readlink "$d/cwd" 2>/dev/null) || cwd=""  # swallow-ok: a process with no readable cwd matches on its command line only
    hit=0
    case $cmdline in *"$dir/"*) hit=1 ;; esac
    case $cwd in "$dir" | "$dir"/*) hit=1 ;; esac
    [ "$hit" = 1 ] || continue
    enroll "$pid" "${20}"
done

grew=1
while [ "$grew" = 1 ]; do
    grew=0
    for pair in $pairs; do
        pid=${pair%%:*}
        rest=${pair#*:}
        parent=${rest%%:*}
        case " $pids " in *" $pid "*) continue ;; esac
        case " $pids " in *" $parent "*) enroll "$pid" "${rest#*:}"; grew=1 ;; esac
    done
done

ident_ok() {
    local want="" e
    for e in $idents; do
        [ "${e%%:*}" = "$1" ] && want=${e#*:}
    done
    [ -n "$want" ] && [ "$(starttime "$1")" = "$want" ]
}

send() {
    ident_ok "$2" && kill -"$1" "$2" 2>/dev/null
}

stopped=0
killed=0
remaining=0
if [ "$live" = 1 ] && [ "$matched" -gt 0 ]; then
    for e in $idents; do send TERM "${e%%:*}"; done
    tries=0
    while [ "$tries" -lt 6 ]; do
        alive=""
        for e in $idents; do ident_ok "${e%%:*}" && alive="$alive ${e%%:*}"; done
        [ -n "$alive" ] || break
        sleep 0.5
        tries=$((tries + 1))
    done
    for e in $idents; do
        pid=${e%%:*}
        if ident_ok "$pid"; then
            send KILL "$pid"
            sleep 0.2
            if ident_ok "$pid"; then remaining=$((remaining + 1)); else killed=$((killed + 1)); fi
        else
            stopped=$((stopped + 1))
        fi
    done
fi

echo "matched=$matched stopped=$stopped killed=$killed remaining=$remaining"
[ "$remaining" = 0 ]
