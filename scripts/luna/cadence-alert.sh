#!/usr/bin/env bash
#   cadence-alert.sh fail <leg> <reason> <log-path>
#   cadence-alert.sh clear <leg>
set -u

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
state="${HOME:-}/.himmel/state"
alert_file="${CADENCE_ALERT_FILE:-$state/cadence-alerts.log}"
dedupe_dir="${CADENCE_ALERT_DEDUPE_DIR:-$state/cadence-alert-sent}"
send_cmd="${CADENCE_ALERT_SEND_CMD:-$_here/vault-stall-alert.sh}"

_slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_'; }

case "${1:-}" in
    fail)
        leg="${2:-unknown}" reason="${3:-unknown}" log="${4:-}"
        mkdir -p "$(dirname "$alert_file")" "$dedupe_dir" 2>/dev/null
        printf '%s %s %s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$leg" "$reason" "$log" >> "$alert_file" \
            || echo "cadence-alert: could not append to $alert_file" >&2
        sentinel="$dedupe_dir/$(_slug "$leg").$(_slug "$reason")"
        if [ ! -e "$sentinel" ]; then
            if "$send_cmd" "cadence leg failed: $leg $reason (log: $log)"; then
                : > "$sentinel" 2>/dev/null \
                    || echo "cadence-alert: could not record dedupe sentinel $sentinel" >&2
            else
                echo "cadence-alert: Telegram send failed for $leg $reason" >&2
            fi
        fi
        ;;
    clear)
        leg="${2:-}"
        [ -n "$leg" ] && rm -f "$dedupe_dir/$(_slug "$leg")".*
        ;;
    *)
        echo "usage: cadence-alert.sh fail <leg> <reason> <log> | clear <leg>" >&2
        ;;
esac
exit 0
