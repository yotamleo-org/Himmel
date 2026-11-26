#!/usr/bin/env bash
# scripts/t3/keepalive.sh - hold a T3 Code session open until something wakes it.
#
# RETIRED from the T3 relay contract: a relay is launched on demand by relay-launch.sh and holds no
# background task. This script stays only for a session an operator chooses to pin by hand.
# Usage: keepalive.sh [--wake-file <path>] [--max-seconds N]
# Run as ONE background task (run_in_background): T3 keeps a thread's process alive while
# background work runs (the pin lasts at most 4 h, so the default max is 12600 s).
# Exits 0 either way so the agent gets a turn and re-arms:
#   wake file appears  -> prints "WOKEN <utc>" and the file contents, removes the file;
#   max-seconds passes -> prints "KEEPALIVE-EXPIRED <utc> re-arm".
# Every T3_KEEPALIVE_CHECK_EVERY-th poll (default 15) also runs chief-threads-check.sh --wake
# and prints its findings.
# Default wake file: ${XDG_RUNTIME_DIR:-/tmp}/himmel-t3/cochief.wake.
# Env seams: T3_KEEPALIVE_POLL (seconds, default 20), T3_KEEPALIVE_CHECK_EVERY.
# Platform: POSIX bash 3.2+.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
WAKE_FILE="${XDG_RUNTIME_DIR:-/tmp}/himmel-t3/cochief.wake"
MAX=12600
POLL="${T3_KEEPALIVE_POLL-20}"
EVERY="${T3_KEEPALIVE_CHECK_EVERY-15}"
die() { echo "keepalive: $2" >&2; exit "$1"; }
utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

while [ $# -gt 0 ]; do
    case "$1" in
        --wake-file) [ $# -ge 2 ] || die 2 "--wake-file needs a path"; WAKE_FILE="$2"; shift 2 ;;
        --max-seconds) [ $# -ge 2 ] || die 2 "--max-seconds needs a number"; MAX="$2"; shift 2 ;;
        *) die 2 "usage: keepalive.sh [--wake-file <path>] [--max-seconds N] (got '$1')" ;;
    esac
done
for v in "$MAX" "$POLL" "$EVERY"; do
    case "$v" in ""|*[!0-9]*) die 2 "--max-seconds, T3_KEEPALIVE_POLL and T3_KEEPALIVE_CHECK_EVERY must be whole numbers" ;; esac
done
POLL=$((10#$POLL)); EVERY=$((10#$EVERY)); MAX=$((10#$MAX))
{ [ "$POLL" -gt 0 ] && [ "$EVERY" -gt 0 ]; } || die 2 "poll and check-every must be above 0"
mkdir -p "$(dirname "$WAKE_FILE")" || die 2 "cannot create the wake file directory"

START=$SECONDS
N=0
while :; do
    if [ -e "$WAKE_FILE" ]; then
        echo "WOKEN $(utc)"
        cat "$WAKE_FILE"
        rm -f "$WAKE_FILE"
        exit 0
    fi
    [ $((SECONDS - START)) -lt "$MAX" ] || { echo "KEEPALIVE-EXPIRED $(utc) re-arm"; exit 0; }
    sleep "$POLL"
    N=$((N + 1))
    if [ $((N % EVERY)) -eq 0 ]; then
        "$HERE/chief-threads-check.sh" --wake 2>&1
    fi
done
