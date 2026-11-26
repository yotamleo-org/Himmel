#!/usr/bin/env bash
# scripts/luna/vault-stall-chief.sh — the luna vault's alert sink that tells the
# live chief first and falls back to scripts/luna/vault-stall-alert.sh (Telegram).
#
#   vault-stall-chief.sh <message...>
#
# A vault stall (cadence:vault-stall) and a stall repair (cadence:vault-stall-repair)
# go to the live chief's inbox as the one line given: failure-route-notify.sh
# live-chief names the chief, inbox-send.sh sends the line, and a sent line is a
# delivered alert (exit 0). No live chief, a failed inbox send, a test-guard refusal
# or any other kind (HIMMEL_ALERT_KIND, default cadence:vault-stall) hands the same
# message to vault-stall-alert.sh, whose exit codes (0/1/2/77) and once-per-finding
# record apply. A chief-delivered line records no finding. An empty message exits 2.
#
# This sits outside scripts/cr's trust closure on purpose: vault-stall-alert.sh is
# inside it and must not reach the chief tools. A test on the station never reaches
# the live queue: with FAILURE_ROUTE_INBOX_SEND unset, the test guard's refusal
# skips the chief.
#
# Seams: FAILURE_ROUTE_SWEEP_CMD and FAILURE_ROUTE_INBOX_SEND (failure-route-notify.sh's
# own), plus vault-stall-alert.sh's: MERGE_BLOCK_ALERT_CMD, TELEGRAM_ACCESS_PATH,
# VAULT_STALL_ALERT_STATE.
set -uo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
msg="$*"
if [ -z "$msg" ]; then
    echo "vault-stall-chief: no message given" >&2
    exit 2
fi

tell_chief() {
    local chief guard_rc=0
    case "${HIMMEL_ALERT_KIND:-cadence:vault-stall}" in cadence:vault-stall | cadence:vault-stall-repair) ;; *) return 1 ;; esac
    if [ -z "${FAILURE_ROUTE_INBOX_SEND:-}" ]; then
        bash "$_here/../lib/test-run-guard" check --real vault-stall-chief || guard_rc=$?
        [ "$guard_rc" -ne 77 ] || return 1
    fi
    chief="$(bash "$_here/../eval/worker-digest/failure-route-notify.sh" live-chief 2>/dev/null)" || return 1
    [ -n "$chief" ] || return 1
    bash "${FAILURE_ROUTE_INBOX_SEND:-$_here/../handover/chief-kit/inbox-send.sh}" "$chief" "$msg" >/dev/null
}

if tell_chief; then
    exit 0
fi
exec bash "$_here/vault-stall-alert.sh" "$msg"
