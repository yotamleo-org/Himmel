#!/usr/bin/env bash
# usage: spec-cc.sh <O-id> <keys> <spec> <spec sha256> <page|->
#
# After the chief signs a core spec, the operator gets a copy: the sealed page
# through chief-route.ts send-file, or, with no page or a page send-file
# refuses, one text line naming the spec path, its hash and why no page went.
#
# Exit 0 when the page or the text line was queued. 1: no operator chat id or
# both sends failed. 77: the send was refused (a test fixture with no
# BRIDGE_ROOT). 2: bad arguments. Queued means in the bridge outbox, not that
# the phone received it.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
export LC_ALL=C.UTF-8

usage="usage: spec-cc.sh <O-id> <keys> <spec> <spec sha256> <page|->"
[ "$#" -eq 5 ] || { echo "$usage" >&2; exit 2; }
oid="$1" keys="$2" spec="$3" sha="$4" page="$5"

# shellcheck source=scripts/lib/merge-block-alert.sh
. "$REPO/scripts/lib/merge-block-alert.sh" || { echo "spec-cc: cannot load the sender library; nothing sent" >&2; exit 1; }

chat="$(_mba_operator_chat)" || chat=""
[ -n "$chat" ] || { echo "spec-cc: no operator chat id in ${TELEGRAM_ACCESS_PATH:-$HOME/.claude/channels/telegram/access.json}; nothing sent" >&2; exit 1; }

why="no page sealed at its current bytes"
if [ "$page" != "-" ]; then
    if [ "${HIMMEL_TEST_FIXTURE:-}" = "1" ] && [ -z "${BRIDGE_ROOT:-}" ]; then
        echo "spec-cc: the send was refused (a test fixture with no BRIDGE_ROOT); nothing sent" >&2
        exit 77
    fi
    caption="Copy, no action needed: the chief signed $keys ($oid) under your standing approval. Review when you like; to take one over, mark it as yours."
    if out="$(bun "$REPO/scripts/telegram/chief-route.ts" send-file --sign "$chat" "$page" "$caption" </dev/null 2>&1)"; then
        exit 0
    fi
    why="$(printf '%s' "$out" | tail -n 1 | cut -c1-200)"
    [ -n "$why" ] || why="send-file refused the page"
fi

text="Copy, no action needed: the chief signed $keys ($oid) under your standing approval; spec $spec sha256 ${sha:0:12}; no page sent: $why."
_mba_send "$chat" "$text" spec-cc </dev/null || { echo "spec-cc: the sender failed; nothing sent" >&2; exit 1; }
[ "${_MBA_REFUSED:-0}" != 1 ] || { echo "spec-cc: the send was refused; nothing sent" >&2; exit 77; }
exit 0
