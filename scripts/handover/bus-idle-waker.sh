#!/usr/bin/env bash
# bus-idle-waker.sh — wake an idle headed session that has unread himmel mail.
#
#   bus-idle-waker.sh --name <session> --service <konsole dbus service>
#       --session </Sessions/n> [--poll 2] [--grace 20] [--rewake 120] [--max-polls 0]
#
# Bus and inbox delivery ride hooks, so a session with no tool call and no prompt
# never sees a message. This watches the session's unread count (bus log via
# `bus unread`, inbox file vs its byte cursor) and, once mail has sat unread for
# --grace seconds (a busy session's hook consumes it first), types ONE fixed
# sentence plus Enter into its konsole through
# org.kde.konsole.Session.sendText. Only the integer count is ever interpolated:
# message content never reaches the terminal, so a message cannot type commands.
# One wake per streak, again every --rewake seconds while mail stays unread.
# A failed sendText (session gone) ends the waker.
#
# Seams: BUS_WAKER_QDBUS (default qdbus6), BUS_WAKER_BUS (default the himmel-bus CLI).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
if . "$HERE/../lib/load-dotenv.sh" 2>/dev/null; then load_dotenv HANDOVER_DIR 2>/dev/null || true; fi
# shellcheck source=../lib/handover-path.sh
. "$HERE/../lib/handover-path.sh"

QDBUS="${BUS_WAKER_QDBUS:-qdbus6}"
BUS="${BUS_WAKER_BUS:-$HERE/../../marketplace/plugins/himmel-bus/bin/bus}"
NAME="" SERVICE="" SESSION="" POLL=2 GRACE=20 REWAKE=120 MAX=0
while [ $# -gt 0 ]; do
    case "$1" in
        --name) NAME="${2:-}"; shift 2 ;;
        --service) SERVICE="${2:-}"; shift 2 ;;
        --session) SESSION="${2:-}"; shift 2 ;;
        --poll) POLL="${2:-}"; shift 2 ;;
        --grace) GRACE="${2:-}"; shift 2 ;;
        --rewake) REWAKE="${2:-}"; shift 2 ;;
        --max-polls) MAX="${2:-}"; shift 2 ;;
        *) echo "bus-idle-waker: unknown argument: $1" >&2; exit 64 ;;
    esac
done
[ -n "$NAME" ] && [ -n "$SERVICE" ] && [ -n "$SESSION" ] || { echo "bus-idle-waker: --name, --service and --session are required" >&2; exit 64; }
case "$NAME" in *[!A-Za-z0-9._-]*|'') echo "bus-idle-waker: invalid --name" >&2; exit 64 ;; esac

num() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }

unread() { # prints the unread total, or nothing when a count is unreadable
    local b i=0 root off size
    # An unreadable count means no wake: sending nothing is the safe side.
    b="$("$BUS" unread "$NAME" 2>/dev/null)" # swallow-ok: unreadable count = 0, never wake on a guess
    num "$b" || b=0
    root="$(handover_root 2>/dev/null)" || root="" # swallow-ok: no handover root = no inbox to count
    if [ -n "$root" ] && [ -f "$root/inbox/$NAME.md" ]; then
        off="$(cat "$root/inbox/.cursor/$NAME" 2>/dev/null)" # swallow-ok: no cursor yet = offset 0 (num below)
        num "$off" || off=0
        size="$(wc -c < "$root/inbox/$NAME.md" | tr -d ' ')"
        [ "$size" -gt "$off" ] && i="$(tail -c +"$((off + 1))" "$root/inbox/$NAME.md" | wc -l | tr -d ' ')"
    fi
    echo $((b + i))
}

since=0 last=0 polls=0
while :; do
    polls=$((polls + 1))
    n="$(unread)"
    now="$(date +%s.%N)"
    if [ "${n:-0}" -gt 0 ]; then
        [ "$since" = 0 ] && since="$now"
        waited="$(awk -v a="$now" -v b="$since" 'BEGIN{printf "%d", (a-b)*1000}')"
        gap="$(awk -v a="$now" -v b="$last" 'BEGIN{printf "%d", (a-b)*1000}')"
        if [ "$waited" -ge "$(awk -v g="$GRACE" 'BEGIN{printf "%d", g*1000}')" ] \
            && { [ "$last" = 0 ] || [ "$gap" -ge "$(awk -v g="$REWAKE" 'BEGIN{printf "%d", g*1000}')" ]; }; then
            if ! "$QDBUS" "$SERVICE" "$SESSION" org.kde.konsole.Session.sendText "You have $n unread himmel messages: read them now."$'\r' >/dev/null 2>&1; then
                echo "bus-idle-waker: sendText failed, session gone: $NAME" >&2
                exit 1
            fi
            last="$now"
        fi
    else
        since=0 last=0
    fi
    [ "$MAX" -gt 0 ] && [ "$polls" -ge "$MAX" ] && exit 0
    sleep "$POLL"
done
