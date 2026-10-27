#!/usr/bin/env bash
# scripts/luna/cadence-alert.sh — the one failure sink every generated cadence
# runner calls. A failed worker must never be silent: the 2026-10-03
# harvest did nothing and logged rc=0, and nobody found out until morning.
#
#   cadence-alert.sh fail <worker> <reason> <log-path> [<cause> [<do>]]
#   cadence-alert.sh clear <worker>
#
# <reason> is the plain result in words; <cause> one line on why; <do> the one
# step to take, or "nothing". The Telegram message is always
#   <worker>: <reason>. Cause: <cause>. Do: <do>. Log: <log-path>
# with `Cause: unknown, see log` and `Do: read the log` for a caller that gave none.
#
# `fail` ALWAYS appends one line `<UTC iso-ts> <worker> <reason> <log-path>` to the
# chief-readable alert file, then sends the plain message to the operator's
# Telegram ONCE through the existing sender (vault-stall-alert.sh, i.e. the
# merge-block-alert.sh -> chief-route.ts bridge path). A repeat of the same
# worker+reason appends again but does not re-send until `clear` — a completed
# run of that worker — re-arms it. The dedupe sentinel is written only after a
# delivered send, so a failed send means the next failure retries the DM. A
# failed send also writes CADENCE_ALERT_SEND_FAILED_MARK (default
# ~/.himmel/state/cadence-alert-send-failed), which himmel-doctor C33 reports
# as a WARN until a later send is delivered.
#
# Seams: CADENCE_ALERT_FILE (default ~/.himmel/state/cadence-alerts.log),
# CADENCE_ALERT_DEDUPE_DIR (default ~/.himmel/state/cadence-alert-sent),
# CADENCE_ALERT_SEND_CMD (default vault-stall-alert.sh; called with one
# argument, the message).
#
# Always exits 0: alerting must never change a runner's own exit status. The one
# opt-in is CADENCE_ALERT_EXIT_ON_SEND_FAIL=1, which makes `fail` exit 1 when
# the send was attempted and not delivered, for a caller that must retry it.
set -u

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
state="${HOME:-}/.himmel/state"
alert_file="${CADENCE_ALERT_FILE:-$state/cadence-alerts.log}"
dedupe_dir="${CADENCE_ALERT_DEDUPE_DIR:-$state/cadence-alert-sent}"
send_cmd="${CADENCE_ALERT_SEND_CMD:-$_here/vault-stall-alert.sh}"
send_failed_mark="${CADENCE_ALERT_SEND_FAILED_MARK:-$state/cadence-alert-send-failed}"

# The default sender needs bun (~/.bun/bin), which cron's minimal PATH lacks: without it
# every cadence alert from a runner that did not pin the arm-time PATH failed to send.
# shellcheck source=../lib/resolve-bun.sh
[ -n "${HOME:-}" ] && . "$_here/../lib/resolve-bun.sh" 2>/dev/null && prefer_bun_on_path

# A worker or reason becomes part of a sentinel filename: keep it to safe bytes.
# No `.` survives, so `<worker>.<reason>` splits unambiguously and `clear a`
# cannot match worker `a.b`'s sentinels.
_slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_'; }
# A reason can run to thousands of characters, past the 255-byte file-name limit:
# the sentinel carries a fixed-length hash of it instead.
_hash() { printf '%s' "$1" | { sha256sum 2>/dev/null || shasum -a 256 2>/dev/null || cksum; } | cut -d' ' -f1 | cut -c1-16; }

# Writes the sentinel only after a delivered send, so a failed send retries the
# DM on the next failure; an unwritable sentinel still counts as delivered.
send_then_mark() { # <sentinel> <message>
    "$send_cmd" "$2" || return 1
    : > "$1" 2>/dev/null \
        || echo "cadence-alert: could not record dedupe sentinel $1" >&2
}

case "${1:-}" in
    fail)
        worker="${2:-unknown}" reason="${3:-unknown}" log="${4:-}"
        send_rc=0
        cause="${5:-unknown, see log}" todo="${6:-read the log}"
        cause="${cause//$'\n'/ }" todo="${todo//$'\n'/ }"
        mkdir -p "$(dirname "$alert_file")" "$dedupe_dir" 2>/dev/null
        printf '%s %s %s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$worker" "$reason" "$log" >> "$alert_file" \
            || echo "cadence-alert: could not append to $alert_file" >&2
        sentinel="$dedupe_dir/$(_slug "$worker").$(_hash "$reason")"
        # The sentinel is written only AFTER a delivered send: an unwritable
        # dedupe dir, a failed send or an interrupted one never suppresses the
        # next alert. Two concurrent failures of one worker could both send; one
        # runner per worker per night makes that a harmless double DM at worst.
        if [ ! -e "$sentinel" ]; then
            if send_then_mark "$sentinel" "$worker: $reason. Cause: $cause. Do: $todo. Log: $log"; then
                rm -f "$send_failed_mark" 2>/dev/null
            else
                send_rc=1
                echo "cadence-alert: Telegram send failed for $worker $reason" >&2
                mkdir -p "$(dirname "$send_failed_mark")" 2>/dev/null
                printf '%s %s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$worker" "$reason" > "$send_failed_mark" 2>/dev/null \
                    || echo "cadence-alert: could not write the send-failed marker $send_failed_mark" >&2
            fi
        fi
        ;;
    clear)
        worker="${2:-}"
        [ -n "$worker" ] && rm -f "$dedupe_dir/$(_slug "$worker")".*
        ;;
    *)
        echo "usage: cadence-alert.sh fail <worker> <reason> <log> [<cause> [<do>]] | clear <worker>" >&2
        ;;
esac
[ "${CADENCE_ALERT_EXIT_ON_SEND_FAIL:-0}" = 1 ] && exit "${send_rc:-0}"
exit 0
