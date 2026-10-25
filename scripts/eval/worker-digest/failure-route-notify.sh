#!/usr/bin/env bash
# failure-route-notify.sh — the failure router's door to the running console and the release manager.
#
# WHY: a ticket the daily failure review files (or a class it comments on) must never die silently in
# Jira. failure_router.py calls this once per live run for the console line and once per filed ticket
# for its release-manager INTAKE; it files into the backlog, so the RM places it, never a fixVersion.
#
#   failure-route-notify.sh console <text>        one line into the live console's inbox
#   failure-route-notify.sh intake <key> <why>    `jira release request <R> --verb INTAKE`, backlog to <R>
#
# The live console is resolved at RUN time like cache-health-cadence.sh: the newest held `*-console`
# queue lock from `queue-lock.sh status --sweep`. No live console, or a failed send, alerts through
# cadence-alert.sh. <R> is the earliest unreleased Jira version (the declared release).
#
# Seams (tests): FAILURE_ROUTE_SWEEP_CMD, FAILURE_ROUTE_INBOX_SEND, FAILURE_ROUTE_JIRA, plus
# cadence-alert.sh's CADENCE_ALERT_*. Platform: Linux/macOS (cron), like the review it serves.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || COMMON=""
ROOT="$(dirname "${COMMON:-$HERE/../../../.git}")"
ALERT="$ROOT/scripts/luna/cadence-alert.sh"
LOG="${HOME:-}/.claude/failure-review-cadence/failure-review-cadence.log"

alert() { bash "$ALERT" fail failure-review-route "$1" "$LOG" "$2" "$3" >/dev/null 2>&1 || true; }

# live_console: newest held *-console queue lock's session name ("" if none).
live_console() {
    local line slug age st best="" best_age=-1
    while IFS= read -r line; do
        case "$line" in slug=*) ;; *) continue ;; esac
        slug="${line#slug=}"; slug="${slug%% *}"
        age="${line#*age=}"; age="${age%%s *}"
        st="${line##*status=}"
        case "$slug" in *-console) ;; *) continue ;; esac
        case "$st" in OK|'IDLE-HELD?') ;; *) continue ;; esac
        [[ "$age" =~ ^[0-9]+$ ]] || continue
        if [ "$best_age" -lt 0 ] || [ "$age" -lt "$best_age" ]; then best="${slug##*__}"; best_age="$age"; fi
    done < <(if [ -n "${FAILURE_ROUTE_SWEEP_CMD:-}" ]; then "$FAILURE_ROUTE_SWEEP_CMD" 2>/dev/null
             else bash "$ROOT/scripts/handover/queue-lock.sh" status --sweep 2>/dev/null; fi)
    printf '%s' "$best"
}

cmd_console() {
    local text="${1:-}" console
    [ -n "$text" ] || { echo "ERR failure-route-notify: console needs a text" >&2; return 64; }
    console="$(live_console)"
    if [ -z "$console" ]; then
        alert "no console is live to tell: $text" "no held *-console queue lock" "read the digest and the router log"
        return 1
    fi
    if ! bash "${FAILURE_ROUTE_INBOX_SEND:-$ROOT/scripts/handover/console-kit/inbox-send.sh}" "$console" "$text"; then
        alert "the console line to $console was not sent: $text" "inbox-send failed" "read the digest"
        return 1
    fi
}

cmd_intake() {
    local key="${1:-}" why="${2:-}" rel jira=() out
    [ -n "$key" ] && [ -n "$why" ] || { echo "ERR failure-route-notify: intake needs a key and a why" >&2; return 64; }
    cd "$ROOT" 2>/dev/null || return 1
    # shellcheck disable=SC1091
    if . "$ROOT/scripts/lib/load-dotenv.sh" 2>/dev/null; then load_dotenv HANDOVER_DIR USER_SLUG 2>/dev/null || true; fi
    if [ -n "${FAILURE_ROUTE_JIRA:-}" ]; then jira=("$FAILURE_ROUTE_JIRA"); else jira=(node "$ROOT/scripts/jira/dist/index.js"); fi
    rel="$("${jira[@]}" versions 2>/dev/null | awk -F'\t' '$2 == "false" && $4 == "false" { print $1; exit }')"
    if [ -z "$rel" ]; then
        alert "the failure review filed $key but found no unreleased version to request its INTAKE into" \
            "jira versions listed none" "request INTAKE for $key by hand"
        return 1
    fi
    if ! out="$("${jira[@]}" release request "$rel" --verb INTAKE --key "$key" --from backlog --to "$rel" --why "$why" 2>&1)"; then
        alert "the failure review filed $key but its INTAKE request into $rel failed" \
            "$(printf '%s' "$out" | head -n 1)" "request INTAKE for $key by hand"
        return 1
    fi
    printf '%s\n' "$out"
}

sub="${1:-}"; [ $# -gt 0 ] && shift
case "$sub" in
    console) cmd_console "$@" ;;
    intake) cmd_intake "$@" ;;
    *) echo "Usage: failure-route-notify.sh <console <text> | intake <key> <why>>" >&2; exit 64 ;;
esac
