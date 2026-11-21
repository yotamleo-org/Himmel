#!/usr/bin/env bash
# scripts/handover/chief-kit/launch-confirm.sh - confirm a detached worker launch started a claude session.
#
# usage: launch-confirm.sh [--chief <name>] [--secs <n>] <session-name> <log>
#
# Run by the chief right after it launches a worker (headed-arm-worker.sh, detached) and touches its signal file.
# Polls once a second, up to --secs (default 60, or LAUNCH_CONFIRM_SECS), for a claude process carrying
# `-n <session-name>`, the same pattern headed-arm.sh confirms a session with.
#   seen                      -> prints `LAUNCH-CONFIRMED <session> pid=<pid>`, exit 0
#   the log ends on the launcher's own LAUNCH-REFUSED line, or the window ends with no session
#                             -> `LAUNCH-UNCONFIRMED <session> <reason>` on stderr, appended to <log> and, when the
#                                chief's console inbox exists, to that inbox (the one the waiter drains); exit 1
# The chief is --chief, else HIMMEL_CONSOLE_NAME. Exit 2: usage.
# Seams: PGREP_CMD (the pgrep binary), BRIDGE_ROOT (the inbox root, default ~/.claude/handover/bridge).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { echo "usage: launch-confirm.sh [--chief <name>] [--secs <n>] <session-name> <log>" >&2; exit 2; }
chief="${HIMMEL_CONSOLE_NAME:-}" secs="${LAUNCH_CONFIRM_SECS:-60}"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --chief) [ "$#" -ge 2 ] || usage; chief="$2"; shift 2 ;;
        --secs) [ "$#" -ge 2 ] || usage; secs="$2"; shift 2 ;;
        --*) usage ;;
        *) break ;;
    esac
done
[ "$#" -eq 2 ] || usage
name="$1" log="$2"
case "$name" in ''|.|..|*[!A-Za-z0-9._-]*) echo "launch-confirm: session name must be letters, digits, '.', '_' or '-' (got: $name)" >&2; exit 2 ;; esac
case "$secs" in ''|*[!0-9]*) usage ;; esac
pgrep_bin="${PGREP_CMD:-pgrep}"
pat="[c]laude .*-n ${name//./\\.}( |\$)"

unconfirmed() {
    local reason="$1" root inbox
    echo "LAUNCH-UNCONFIRMED $name $reason" >&2
    printf '%s LAUNCH-UNCONFIRMED %s %s\n' "$(date +%F_%T)" "$name" "$reason" >> "$log" 2>/dev/null
    case "$chief" in ''|.|..|*[!A-Za-z0-9._-]*) exit 1 ;; esac
    root="${BRIDGE_ROOT:-$HOME/.claude/handover/bridge}"
    # shellcheck source=scripts/lib/merge-block-alert.sh
    . "$HERE/../../lib/merge-block-alert.sh" 2>/dev/null || exit 1
    inbox="$(_mba_chief_inbox_path "$root" "$chief")" || exit 1
    _mba_append_if_exists "$inbox" "- $(date +%H:%M) LAUNCH-UNCONFIRMED $name $reason (log $log)"
    exit 1
}

n=0
while :; do
    pid="$("$pgrep_bin" -f "$pat" 2>/dev/null | head -n 1)"  # swallow-ok: a failed scan reads as no session yet; the window still ends in LAUNCH-UNCONFIRMED
    if [ -n "$pid" ]; then
        echo "LAUNCH-CONFIRMED $name pid=$pid"
        exit 0
    fi
    last="$(grep -v '^[[:space:]]*$' "$log" 2>/dev/null | tail -n 1)"  # swallow-ok: an unreadable log reads as no refusal yet; the window still ends in LAUNCH-UNCONFIRMED
    case "$last" in
        *" LAUNCH-REFUSED $name "*) unconfirmed "the launcher refused: ${last#* LAUNCH-REFUSED "$name" }" ;;
    esac
    [ "$n" -lt "$secs" ] || unconfirmed "no claude session within ${secs}s"
    sleep 1
    n=$((n + 1))
done
