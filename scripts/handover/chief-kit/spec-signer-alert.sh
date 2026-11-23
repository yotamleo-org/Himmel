#!/usr/bin/env bash
# usage: spec-signer-alert.sh <record|signature> <scope> <signer> <decision> <words-file> [<note>]
#
# A record line tells the operator who now signs the specs of <scope> (keys, or
# "the station default"); <note> carries a mark's bypass note and the rows it
# voids. A signature line tells him his own signature was recorded for <scope>;
# <note> names the keys the chief signed in the same row.
#
# <words-file> holds only the operator's words, so no shell quoting touches
# them. Over 500 characters they are cut, and the line says how many characters
# were left out. The line leads with the words.
#
# Exit 0 only on a send. 1: no operator chat id, an unreadable words file or a
# failing sender. 77: the sender refused the send (_MBA_REFUSED=1, a test
# fixture or a test on the station). 2: bad arguments.
#
# A send means the line is queued in the bridge outbox, not that the phone
# received it.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
export LC_ALL=C.UTF-8

usage="usage: spec-signer-alert.sh <record|signature> <scope> <signer> <decision> <words-file> [<note>]"
[ "$#" -eq 5 ] || [ "$#" -eq 6 ] || { echo "$usage" >&2; exit 2; }
kind="$1" scope="$2" signer="$3" decision="$4" words_file="$5" note="${6:-}"
case "$kind" in record|signature) ;; *) echo "$usage" >&2; exit 2 ;; esac

words="$(cat -- "$words_file" 2>/dev/null)" || { echo "spec-signer-alert: cannot read the words file $words_file; nothing sent" >&2; exit 1; }  # swallow-ok: a failed read exits 1 here and sends nothing
max=500
if [ "${#words}" -gt "$max" ]; then
    words="${words:0:$max} [${#words} characters, $(( ${#words} - max )) left out]"
fi

# shellcheck source=scripts/lib/merge-block-alert.sh
. "$REPO/scripts/lib/merge-block-alert.sh" || { echo "spec-signer-alert: cannot load the sender library; nothing sent" >&2; exit 1; }

chat="$(_mba_operator_chat)" || chat=""
[ -n "$chat" ] || { echo "spec-signer-alert: no operator chat id in ${TELEGRAM_ACCESS_PATH:-$HOME/.claude/channels/telegram/access.json}; nothing sent" >&2; exit 1; }

if [ "$kind" = record ]; then
    text="\"$words\" — spec signer: $scope now signed by $signer, decision $decision${note:+; $note}"
else
    text="\"$words\" — operator signature recorded for $scope, decision $decision${note:+; chief-signed in this row: $note}"
fi
_mba_send "$chat" "$text" spec-signer </dev/null || { echo "spec-signer-alert: the sender failed; nothing sent" >&2; exit 1; }
[ "${_MBA_REFUSED:-0}" != 1 ] || { echo "spec-signer-alert: the send was refused; nothing sent" >&2; exit 77; }
exit 0
