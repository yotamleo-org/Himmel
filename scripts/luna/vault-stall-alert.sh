#!/usr/bin/env bash
#   vault-stall-alert.sh <message...>
set -uo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/merge-block-alert.sh
. "$_here/../lib/merge-block-alert.sh"

msg="$*"
if [ -z "$msg" ]; then
    echo "vault-stall-alert: no message given" >&2
    exit 2
fi

chat="$(_mba_operator_chat)" || chat=""
if [ -z "$chat" ]; then
    echo "vault-stall-alert: no operator chat id readable - not delivered" >&2
    exit 1
fi
_mba_send "$chat" "$msg" || {
    echo "vault-stall-alert: delivery failed" >&2
    exit 1
}
