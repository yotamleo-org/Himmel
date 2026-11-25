#!/usr/bin/env bash
# scripts/luna/vault-stall-alert.sh — the operator alert sink for the luna
# vault's auto-commit STALL.
#
# vault-autosync.sh (templates/luna-second-brain/scripts/) is generic and ships
# to the public luna-brain repo, so it carries no Telegram code: it calls the
# executable named by LUNA_VAULT_ALERT_CMD with one argument, the message. Point
# that at this script and the alert rides the SAME path every other operator DM
# uses (merge-block-alert.sh -> chief-route.ts reply -> the bridge outbox).
#
#   LUNA_VAULT_ALERT_CMD=<repo>/scripts/luna/vault-stall-alert.sh
#
#   vault-stall-alert.sh <message...>
#
# Exit 0 = delivered; 77 = refused by the test guard, nothing sent, neither
# delivered nor failed; any other non-zero = not delivered (autosync then retries
# next run instead of marking the stall episode alerted). Seams are merge-block-alert.sh's
# own: MERGE_BLOCK_ALERT_CMD (replaces the sender, `$CMD <chat_id> <text>`) and
# TELEGRAM_ACCESS_PATH (access.json holding the operator id).
#
# A vault stall is sent once: the finding of the last delivered cadence:vault-stall
# send (the message without its "for N min" part) is kept in VAULT_STALL_ALERT_STATE
# (default ~/.himmel/state/vault-stall-alert-last), and the same finding on a later
# pass exits 0 without a send, until the record is 7 days old (a stall that outlives
# a week is told again). A changed finding is sent. A send that failed or was
# refused records nothing. Another kind's lines are never held back here.
set -uo pipefail

kind="${HIMMEL_ALERT_KIND:-}"
case "$kind" in cadence:?*|failure-review|cache-health) ;; *) kind=cadence:vault-stall ;; esac

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/merge-block-alert.sh
. "$_here/../lib/merge-block-alert.sh"
# shellcheck source=../lib/prim.sh
. "$_here/../lib/prim.sh" || exit 1

msg="$*"
if [ -z "$msg" ]; then
    echo "vault-stall-alert: no message given" >&2
    exit 2
fi

deliver() {
    local sig="${1:-}" chat
    if [ -n "$sig" ] && [ "$(cat "$state" 2>/dev/null)" = "$sig" ] && [ -n "$(find "$state" -mmin -10080 2>/dev/null)" ]; then
        echo "vault-stall-alert: same finding as the last one sent - not sent again" >&2
        return 0
    fi
    chat="$(_mba_operator_chat)" || chat=""
    if [ -z "$chat" ]; then
        echo "vault-stall-alert: no operator chat id readable - not delivered" >&2
        return 1
    fi
    _mba_send "$chat" "$msg" "$kind" || {
        echo "vault-stall-alert: delivery failed" >&2
        return 1
    }
    [ "${_MBA_REFUSED:-0}" != 1 ] || {
        echo "vault-stall-alert: refused by the test guard, nothing sent" >&2
        return 77
    }
    if [ -n "$sig" ]; then
        printf '%s\n' "$sig" >"$state" 2>/dev/null || echo "vault-stall-alert: could not record the finding in $state" >&2
    fi
    return 0
}

state="${VAULT_STALL_ALERT_STATE:-${HOME:+$HOME/.himmel/state/vault-stall-alert-last}}"
if [ "$kind" = cadence:vault-stall ] && [ -n "$state" ] && mkdir -p "$(dirname "$state")" 2>/dev/null && [ -w "$(dirname "$state")" ]; then
    sig="$(printf '%s' "$msg" | sed 's/ for [0-9][0-9]* min / /' | { sha256sum 2>/dev/null || shasum -a 256 2>/dev/null || cksum; } | cut -d' ' -f1)"
    with_lock "$state.lock" deliver "$sig"
    exit $?
fi
deliver
exit $?
