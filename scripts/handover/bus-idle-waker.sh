#!/usr/bin/env bash
# bus-idle-waker.sh — wake an idle headed session that has unread himmel mail.
#
#   bus-idle-waker.sh --name <session> --service <konsole dbus service>
#       --session </Sessions/n> [--pid <konsole pid>] [--poll 2] [--grace 20] [--rewake 120] [--max-polls 0]
#
# Bus and inbox delivery ride hooks, so a session with no tool call and no prompt
# never sees a message. This watches the session's unread count (bus log via
# `bus unread`, inbox file vs its byte cursor) and, once mail has sat unread for
# --grace seconds (a busy session's hook consumes it first), types ONE fixed
# sentence plus Enter into its konsole through
# org.kde.konsole.Session.sendText. The sentence is a constant with no digit:
# message content never reaches the terminal, so a message cannot type commands.
# One wake per streak, again every --rewake seconds while mail stays unread.
# Before every wake the screen (getAllDisplayedText) must show the idle input
# box: a `❯` line between two `─` rules. A permission dialog or any menu
# replaces that box, and Enter there would confirm its highlighted option, so
# such a screen (or one that cannot be read) gets no keystroke. A running turn
# keeps the box but shows a spinner line (`✶ Smooshing… (16s · thinking)`) above
# it, and that screen gets no keystroke either; nor does a box holding a draft,
# which Enter would submit.
# The target must be the named session: at startup and again before every wake
# the konsole session's processId must run claude (argv0) with `-n <name>`, or
# the waker refuses with rc=4.
# A failed sendText ends the waker: rc=1 session gone, rc=3 AccessDenied (the
# EnableSecuritySensitiveDBusAPI setting is off, or konsole read it before it was
# enabled: konsole reads it only at startup, so an older window refuses). qdbus6
# prints that error on stdout, so both streams are matched.
# --pid ends it with rc=0 once that konsole process is gone, so an armed waker
# never outlives its window.
# An rc=3 or rc=4 end also leaves `rc3` / `rc4` in <state dir>/<name> (the tick
# reads it); a start clears the file. State dir: BUS_WAKER_STATE_DIR, default
# ${XDG_STATE_HOME:-~/.local/state}/himmel/bus-waker.
#
# Seams: BUS_WAKER_QDBUS (default qdbus6), BUS_WAKER_BUS (default the himmel-bus CLI),
# BUS_WAKER_PROC (default /proc).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
if . "$HERE/../lib/load-dotenv.sh" 2>/dev/null; then load_dotenv HANDOVER_DIR 2>/dev/null || true; fi
# shellcheck source=../lib/handover-path.sh
. "$HERE/../lib/handover-path.sh"

QDBUS="${BUS_WAKER_QDBUS:-qdbus6}"
BUS="${BUS_WAKER_BUS:-$HERE/../../marketplace/plugins/himmel-bus/bin/bus}"
PROC="${BUS_WAKER_PROC:-/proc}"
NAME="" SERVICE="" SESSION="" PID="" POLL=2 GRACE=20 REWAKE=120 MAX=0
while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || { echo "bus-idle-waker: $1 needs a value" >&2; exit 64; }
    case "$1" in
        --name) NAME="${2:-}"; shift 2 ;;
        --service) SERVICE="${2:-}"; shift 2 ;;
        --session) SESSION="${2:-}"; shift 2 ;;
        --pid) PID="${2:-}"; shift 2 ;;
        --poll) POLL="${2:-}"; shift 2 ;;
        --grace) GRACE="${2:-}"; shift 2 ;;
        --rewake) REWAKE="${2:-}"; shift 2 ;;
        --max-polls) MAX="${2:-}"; shift 2 ;;
        *) echo "bus-idle-waker: unknown argument: $1" >&2; exit 64 ;;
    esac
done
if [ -z "$NAME" ] || [ -z "$SERVICE" ] || [ -z "$SESSION" ]; then echo "bus-idle-waker: --name, --service and --session are required" >&2; exit 64; fi
case "$NAME" in *[!A-Za-z0-9._-]*|'') echo "bus-idle-waker: invalid --name" >&2; exit 64 ;; esac
for v in "$POLL" "$GRACE" "$REWAKE" "$MAX"; do
    case "$v" in ''|*[!0-9.]*|*.*.*|.) echo "bus-idle-waker: --poll, --grace, --rewake and --max-polls take a number" >&2; exit 64 ;; esac
done
case "$MAX" in *.*) echo "bus-idle-waker: --max-polls takes an integer" >&2; exit 64 ;; esac
[ "$(awk -v p="$POLL" 'BEGIN{print (p > 0)}')" = 1 ] || { echo "bus-idle-waker: --poll must be above 0" >&2; exit 64; }

STATE_DIR="${BUS_WAKER_STATE_DIR:-${XDG_STATE_HOME:-${HOME:-/nonexistent}/.local/state}/himmel/bus-waker}"
rm -f "$STATE_DIR/$NAME" 2>/dev/null # swallow-ok: a state file that cannot be cleared only leaves a stale tick flag
end_state() { # end_state <rc3|rc4>: leave the reason for the console tick; the waker's log is not read by it
    { mkdir -p "$STATE_DIR" && printf '%s\n' "$1" > "$STATE_DIR/$NAME"; } 2>/dev/null || true # swallow-ok: the state file is advisory, the exit code still ends the waker
}

num() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
[ -z "$PID" ] || { num "$PID" && [ "$PID" -gt 0 ]; } || { echo "bus-idle-waker: --pid takes a process id" >&2; exit 64; }

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
        [ "$size" -gt "$((10#$off))" ] && i="$(tail -c +"$((10#$off + 1))" "$root/inbox/$NAME.md" | wc -l | tr -d ' ')"
    fi
    echo $((b + i))
}

konsole() { # konsole <method> [args]: one Session call into $out; a failure ends the waker
    if ! out="$("$QDBUS" "$SERVICE" "$SESSION" "org.kde.konsole.Session.$1" "${@:2}" 2>&1)"; then
        case "$out" in *org.freedesktop.DBus.Error.AccessDenied*)
            echo "bus-idle-waker: sendText denied (konsole security-sensitive D-Bus API is disabled, or this window predates enabling it; enable it, then relaunch the window): $NAME" >&2
            end_state rc3
            exit 3 ;;
        esac
        echo "bus-idle-waker: konsole $1 failed, session gone: $NAME" >&2
        exit 1
    fi
}

named_target() { # the session's process must be claude launched as `-n <name>`; checked before every wake
    konsole processId
    if ! num "$out" || ! tr '\0' '\n' < "$PROC/$out/cmdline" 2>/dev/null | awk -v n="$NAME" '
        NR == 1 { sub(/.*\//, ""); claude = ($0 == "claude") }
        (prev == "-n" || prev == "--name") && $0 == n { named = 1 }
        { prev = $0 }
        END { exit !(claude && named) }'; then
        echo "bus-idle-waker: konsole session $SERVICE $SESSION does not run the claude named $NAME, refusing" >&2
        end_state rc4
        exit 4
    fi
}
named_target

at_prompt() { # the screen shows the idle, empty input box (a bare ❯ line between two ─ rules) and no running turn's spinner above it
    # The top rule carries the session name; a name wider than the window truncates it to ` <name>… ─`.
    konsole getAllDisplayedText true
    printf '%s\n' "$out" | awk '
        { line[NR] = $0 }
        /^❯/ { at = NR }
        END {
            if (!(at > 1 && line[at - 1] ~ /─[ \t]*$/ && line[at + 1] ~ /^─/)) exit 1
            draft = line[at]; sub(/^❯/, "", draft); gsub(/\302\240|[ \t]/, "", draft)
            if (draft != "") exit 1
            for (i = at - 2; i > 0 && i >= at - 9; i--) if (line[i] ~ /^[^ ]+ [A-Z][a-z]+…/) exit 1
        }'
}

since=0 last=0 polls=0
while :; do
    polls=$((polls + 1))
    if [ -n "$PID" ] && ! kill -0 "$PID" 2>/dev/null; then
        echo "bus-idle-waker: konsole pid $PID gone, stopping: $NAME" >&2
        exit 0
    fi
    n="$(unread)"
    now="$(date +%s.%N)"
    if [ "${n:-0}" -gt 0 ]; then
        [ "$since" = 0 ] && since="$now"
        waited="$(awk -v a="$now" -v b="$since" 'BEGIN{printf "%d", (a-b)*1000}')"
        gap="$(awk -v a="$now" -v b="$last" 'BEGIN{printf "%d", (a-b)*1000}')"
        if [ "$waited" -ge "$(awk -v g="$GRACE" 'BEGIN{printf "%d", g*1000}')" ] \
            && { [ "$last" = 0 ] || [ "$gap" -ge "$(awk -v g="$REWAKE" 'BEGIN{printf "%d", g*1000}')" ]; } \
            && at_prompt; then
            named_target
            konsole sendText "You have unread himmel messages: read them now."$'\r'
            last="$now"
        fi
    else
        since=0 last=0
    fi
    [ "$MAX" -gt 0 ] && [ "$polls" -ge "$MAX" ] && exit 0
    sleep "$POLL"
done
