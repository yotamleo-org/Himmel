#!/usr/bin/env bash
# critic-alert.sh — the loud Telegram alert for a Claude critic (decision 1084).
#
#   critic_loud_alert <class> <message...>
#
# Sent EVERY time, never deduplicated: a Claude critic that runs because codex is
# exhausted, and a critic that tried to use the subscription, are both events the
# operator must see each time they happen. Same sender as the api-lane alert
# (scripts/api-lane/claude-api.sh send_alert): TG_REPO_NAME, TG_NOTIFICATION_TYPE
# "critic <class>" and TG_MESSAGE through scripts/telegram/session-status.ts
# notification, with every API key variable removed from its environment.
# The line always goes to stderr as well, so a failed send is never silent, and
# one line goes to the chief's bridge inbox (_cra_route_chief below).
#
# Seam: CR_CRITIC_ALERT_CMD replaces the sender; it runs as `$CMD notification`
# with the TG_* variables in its environment (the HIMMEL_API_ALERT_CMD shape).
# An explicitly empty TELEGRAM_GROUP_CHAT_ID suppresses the send. A test on the
# station never sends: test-run-guard exit 77 stops the default sender.
#
# Sourceable: functions only, always returns 0. bash 3.2-safe.

_cra_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

critic_loud_alert() {
    local class="${1:-alert}" msg repo_name env_root repo
    shift || true
    msg="$(printf '%s' "$*" | tr '\000-\037' ' ' | sed -E 's/sk-ant-[A-Za-z0-9_-]+/[key]/g')"
    msg="${msg:0:400}"
    echo "CRITIC-ALERT ($class): $msg" >&2
    repo="$(cd "$_cra_dir/../.." && pwd)"
    repo_name="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")"  # swallow-ok: the repo name only labels the message
    env_root="$(cd "$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/.." 2>/dev/null && pwd)"  # swallow-ok: an empty root falls back to the repo below
    (
        for v in $(compgen -e); do
            case "$v" in ANTHROPIC_*|LQ_API_*|CLAUDE_CODE_OAUTH_TOKEN) unset "$v" ;; esac
        done
        export TG_REPO_NAME="$repo_name" TG_NOTIFICATION_TYPE="critic $class" TG_MESSAGE="CRITIC-ALERT: $msg"
        [ -z "${CR_CRITIC_ALERT_CMD:-}" ] || exec "$CR_CRITIC_ALERT_CMD" notification
        if [ "${TELEGRAM_GROUP_CHAT_ID+set}" = set ] && [ -z "$TELEGRAM_GROUP_CHAT_ID" ]; then exit 0; fi
        command -v bun >/dev/null 2>&1 || exit 0
        _cra_guard=0
        bash "$repo/scripts/lib/test-run-guard" check --quiet --tool bun critic-alert || _cra_guard=$?
        [ "$_cra_guard" != 77 ] || exit 0
        # shellcheck source=scripts/lib/load-dotenv.sh
        { [ -r "$repo/scripts/lib/load-dotenv.sh" ] && . "$repo/scripts/lib/load-dotenv.sh"; } 2>/dev/null &&
            load_dotenv --root "${env_root:-$repo}" TELEGRAM_GROUP_CHAT_ID 2>/dev/null
        [ -n "${TELEGRAM_GROUP_CHAT_ID:-}" ] || exit 0
        export TELEGRAM_GROUP_CHAT_ID
        # shellcheck source=scripts/lib/timeout-bin.sh
        { [ -r "$repo/scripts/lib/timeout-bin.sh" ] && . "$repo/scripts/lib/timeout-bin.sh"; } 2>/dev/null
        exec ${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" 30} bun run "$repo/scripts/telegram/session-status.ts" notification
    ) </dev/null >/dev/null 2>&1 || echo "critic-alert: the Telegram send failed (the CRITIC-ALERT line above stands)" >&2
    _cra_route_chief "$msg" || echo "critic-alert: no chief inbox reached (HIMMEL_CONSOLE_NAME unset or its inbox absent)" >&2
    return 0
}

# One line to the chief's bridge inbox (<bridge root>/consoles/<HIMMEL_CONSOLE_NAME>.md),
# the path merge-block-alert.sh routes a merge-watch red through; the inbox is
# appended to only when it already exists. BRIDGE_ROOT is the seam.
_cra_route_chief() {
    local root file guard_rc=0
    [ -r "$_cra_dir/../lib/merge-block-alert.sh" ] || return 1
    # shellcheck source=scripts/lib/merge-block-alert.sh
    . "$_cra_dir/../lib/merge-block-alert.sh"
    if [ "${HIMMEL_TEST_FIXTURE:-}" = "1" ] && [ -z "${BRIDGE_ROOT:-}" ]; then return 0; fi
    root="${BRIDGE_ROOT:-$HOME/.claude/handover/bridge}"
    bash "$_cra_dir/../lib/test-run-guard" check --quiet critic-alert-route "$root" || guard_rc=$?
    [ "$guard_rc" != 77 ] || return 0
    file=$(_mba_chief_inbox_path "$root" "${HIMMEL_CONSOLE_NAME:-}") || return 1
    _mba_append_if_exists "$file" "$(printf -- '- %s [critic-alert] CRITIC-ALERT: %s' "$(date +%H:%M)" "$1")"
}
