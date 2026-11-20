#!/usr/bin/env bash
# scripts/t3/t3-send.sh - send a message to a T3 Code thread by title or threadId.
#
# Usage: t3-send.sh <title|threadId> <msg-file>   (msg-file "-" reads stdin)
# The title must match one thread exactly (after trimming). Sends with
# `t3 thread send <id> -`, which starts a turn (queued if busy) and unsettles the thread.
# rc 0 sent (prints "sent <id> (<title>)"); rc 1 the t3 CLI failed (its stderr passes
# through); rc 2 usage / unreadable msg file (not a regular file, or stdin cannot be read); rc 3 title matches more than one thread
# (every match is printed, nothing sent); rc 4 no thread has that title.
# Env seams: T3_SEND_BIN (default $HOME/.t3/bin/t3 - the running server's CLI; the one on
# ~/.local/bin points at a different instance), T3_SEND_PROJECT (default: this repo's root).
# Platform: POSIX bash 3.2+, jq.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
BIN="${T3_SEND_BIN:-$HOME/.t3/bin/t3}"
PROJECT="${T3_SEND_PROJECT:-$(cd "$HERE/../.." && pwd -P)}"
die() { echo "t3-send: $2" >&2; exit "$1"; }

[ $# -eq 2 ] || die 2 "usage: t3-send.sh <title|threadId> <msg-file|->"
KEY="$(printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
MSG="$2"
[ -n "$KEY" ] || die 2 "empty thread title"
if [ "$MSG" != "-" ] && { [ ! -f "$MSG" ] || [ ! -r "$MSG" ]; }; then die 2 "msg-file not readable: $MSG"; fi
command -v jq >/dev/null 2>&1 || die 2 "jq is required"

# shellcheck source=../lib/prim.sh
. "$HERE/../lib/prim.sh" || die 2 "cannot load scripts/lib/prim.sh"
TMP="$(tmpdir)" || die 1 "mktemp failed"
trap 'rm -rf "$TMP"' EXIT
if [ "$MSG" = "-" ]; then cat > "$TMP/msg" || die 2 "cannot read the message"; else cp "$MSG" "$TMP/msg" || die 2 "cannot read the message"; fi

"$BIN" thread list --json --project "$PROJECT" > "$TMP/list" 2> "$TMP/err" \
    || { cat "$TMP/err" >&2; die 1 "thread list failed"; }
jq -e 'type == "array"' "$TMP/list" >/dev/null 2>&1 || die 1 "thread list did not print a JSON array"

ID="$(jq -r --arg k "$KEY" '[.[] | select(.threadId == $k)] | first | .threadId // empty' "$TMP/list")"
if [ -n "$ID" ]; then
    TITLE="$(jq -r --arg k "$ID" '[.[] | select(.threadId == $k)] | first | .title // ""' "$TMP/list")"
else
    jq -r --arg k "$KEY" '.[] | select((.title // "") | gsub("^\\s+|\\s+$"; "") == $k)
        | [.threadId, .status, .title] | @tsv' "$TMP/list" > "$TMP/matches"
    N="$(grep -c . "$TMP/matches")"
    [ "$N" -gt 0 ] || die 4 "no thread titled '$KEY'"
    if [ "$N" -gt 1 ]; then
        echo "t3-send: $N threads are titled '$KEY'; refusing to guess:" >&2
        while IFS="$(printf '\t')" read -r i s t; do echo "  $i  [$s]  $t" >&2; done < "$TMP/matches"
        exit 3
    fi
    ID="$(cut -f1 "$TMP/matches")"
    TITLE="$(cut -f3 "$TMP/matches")"
fi

"$BIN" thread send "$ID" - < "$TMP/msg" 2> "$TMP/err" >/dev/null \
    || { cat "$TMP/err" >&2; die 1 "thread send failed for $ID"; }
echo "sent $ID ($TITLE)"
