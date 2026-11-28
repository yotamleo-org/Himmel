#!/usr/bin/env bash
# scripts/handover/chief-kit/launch-confirm.sh - confirm a detached worker launch started a claude session.
#
# usage: launch-confirm.sh --since <epoch> [--chief <name>] [--secs <n>] <session-name> <log>
#
# Run by the chief after it launches a worker (headed-arm-worker.sh, detached), with
# --since the epoch it took just before that launch. Polls once a second, up to --secs (default 240, or
# LAUNCH_CONFIRM_SECS), on that launch attempt only: the lines <log> holds after its newest
# `LAUNCH-START <session> epoch=<s>` line with <s> at or after --since, so an earlier attempt's lines and an earlier
# session never decide it, and an attempt whose START has not been written yet is waited for.
#   the attempt wrote LAUNCH-OK and a claude process carries `-n <session-name>` (headed-arm.sh's pattern)
#                             -> prints `LAUNCH-CONFIRMED <session> pid=<pid>`, exit 0
#   the attempt wrote LAUNCH-REFUSED, or the window ends first
#                             -> `LAUNCH-UNCONFIRMED <session> <reason>` on stderr, appended to <log> and, when the
#                                chief's console inbox exists, to that inbox (the one the waiter drains); exit 1
# The chief is --chief, else HIMMEL_CONSOLE_NAME. Exit 2: usage.
# Seams: PGREP_CMD (the pgrep binary), BRIDGE_ROOT (the inbox root, default ~/.claude/handover/bridge).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { echo "usage: launch-confirm.sh --since <epoch> [--chief <name>] [--secs <n>] <session-name> <log>" >&2; exit 2; }
chief="${HIMMEL_CONSOLE_NAME:-}" secs="${LAUNCH_CONFIRM_SECS:-240}" since=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        --chief) [ "$#" -ge 2 ] || usage; chief="$2"; shift 2 ;;
        --secs) [ "$#" -ge 2 ] || usage; secs="$2"; shift 2 ;;
        --since) [ "$#" -ge 2 ] || usage; since="$2"; shift 2 ;;
        --*) usage ;;
        *) break ;;
    esac
done
[ "$#" -eq 2 ] || usage
name="$1" log="$2"
case "$name" in ''|.|..|*[!A-Za-z0-9._-]*) echo "launch-confirm: session name must be letters, digits, '.', '_' or '-' (got: $name)" >&2; exit 2 ;; esac
case "$secs" in ''|*[!0-9]*) usage ;; esac
case "$since" in ''|*[!0-9]*) usage ;; esac
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

attempt_state() {
    [ -r "$log" ] || { echo none; return 0; }
    awk -v n="$name" -v since="$since" '
        $2 == "LAUNCH-START" && $3 == n { e = $4; sub(/^epoch=/, "", e); if (e + 0 >= since) { s = 1; r = ""; ok = 0 } else { s = 0 }; next }
        s && $2 == "LAUNCH-REFUSED" && $3 == n { r = $0; sub(/^[^ ]+ [^ ]+ [^ ]+ /, "", r); if (r == "") r = "no reason given" }
        s && $2 == "LAUNCH-OK" && $3 == n { ok = 1 }
        END { if (!s) print "none"; else if (r != "") print "refused " r; else if (ok) print "ok"; else print "running" }
    ' "$log"
}

n=0
while :; do
    state="$(attempt_state)"
    case "$state" in
        refused\ *) unconfirmed "the launcher refused: ${state#refused }" ;;
        ok)
            pid="$("$pgrep_bin" -f "$pat" 2>/dev/null | head -n 1)"  # swallow-ok: a failed scan reads as no session yet; the window still ends in LAUNCH-UNCONFIRMED
            if [ -n "$pid" ]; then
                echo "LAUNCH-CONFIRMED $name pid=$pid"
                exit 0
            fi ;;
    esac
    if [ "$n" -ge "$secs" ]; then
        case "$state" in
            none) unconfirmed "no launch attempt started in $log within ${secs}s" ;;
            running) unconfirmed "the launcher had not finished within ${secs}s" ;;
            *) unconfirmed "the launcher exited 0 but no claude session within ${secs}s" ;;
        esac
    fi
    sleep 1
    n=$((n + 1))
done
