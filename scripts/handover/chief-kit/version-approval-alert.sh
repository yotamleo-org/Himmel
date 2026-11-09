#!/usr/bin/env bash
# version-approval-alert.sh — the operator's phone line for an out-of-version
# approval. `jira release operator out-of-version` runs it before it signs the
# record, and writes no record unless this exits 0.
#
# usage: version-approval-alert.sh <key> <version> <decision> <open> <words-file>
#
# <words-file> holds only the operator's words (the Verbatim: block), so no
# shell quoting touches them. Over 500 characters they are cut, and the line
# says how many characters were left out. The line leads with the words.
#
# Exit 0 only on a send. 1: no operator chat id, an unreadable words file or a
# failing sender. 77: the sender refused the send (_MBA_REFUSED=1, a test
# fixture or a test on the station). 2: bad arguments. Unlike
# denied-launch-alert.sh, which always exits 0, this exit is the record's gate.
#
# Sender and operator lookup are merge-block-alert.sh's (MERGE_BLOCK_ALERT_CMD,
# TELEGRAM_ACCESS_PATH seams). A send means the line is queued in the bridge
# outbox, not that the phone received it.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
export LC_ALL=C.UTF-8

[ "$#" -eq 5 ] || { echo "usage: version-approval-alert.sh <key> <version> <decision> <open> <words-file>" >&2; exit 2; }
key="$1" version="$2" decision="$3" open="$4" words_file="$5"

words="$(cat -- "$words_file" 2>/dev/null)" || { echo "version-approval-alert: cannot read the words file $words_file; nothing sent" >&2; exit 1; }  # swallow-ok: a failed read exits 1 here and sends nothing
max=500
if [ "${#words}" -gt "$max" ]; then
    words="${words:0:$max} [${#words} characters, $(( ${#words} - max )) left out]"
fi

# shellcheck source=scripts/lib/merge-block-alert.sh
. "$REPO/scripts/lib/merge-block-alert.sh" || { echo "version-approval-alert: cannot load the sender library; nothing sent" >&2; exit 1; }

chat="$(_mba_operator_chat)" || chat=""
[ -n "$chat" ] || { echo "version-approval-alert: no operator chat id in ${TELEGRAM_ACCESS_PATH:-$HOME/.claude/channels/telegram/access.json}; nothing sent" >&2; exit 1; }

text="\"$words\" — out-of-version approval for $key (in $version), decision $decision, for 14 days; $open approvals open."
_mba_send "$chat" "$text" </dev/null || { echo "version-approval-alert: the sender failed; nothing sent" >&2; exit 1; }
[ "${_MBA_REFUSED:-0}" != 1 ] || { echo "version-approval-alert: the send was refused; nothing sent" >&2; exit 77; }
exit 0
