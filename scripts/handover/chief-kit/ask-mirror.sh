#!/usr/bin/env bash
# scripts/handover/chief-kit/ask-mirror.sh - post each `Needs you:` block of a chief's
# console reply to the operator's Telegram as well, once (docs/internals/operator-voice.md rule 6).
#
# Usage: ask-mirror.sh < <Stop hook payload JSON>
#   Reads session_id, last_assistant_message, or transcript_path when that field is absent.
#
# Only a chief session posts: one whose queue-lock token file (queue-lock.sh, keyed on
# sha256("<session_id>|<doc>")) exists for a held *-chief or *-console lock, the check
# stop-chief-idle-guard.sh makes. A worker, judge or any other session posts nothing.
#
# Each block is posted with `chief-route.ts reply --chief <name> --kind chief-reply operator`.
# A fenced code block inside the block, or right after it, is left out of the ask and posted
# alone as the next message (rule 5). A block is sent once: its key, sha256 of chief name,
# ask and code, goes to <handover root>/.ask-mirror/<chief>.sent after a successful post,
# so a repeated ask is skipped and a changed one is sent again. A failed post is an
# owe.sh step row in the chief's bucket, and the block is tried again on the next reply.
#
# Always exits 0 with no stdout: it never blocks the stop.
# Test seams: ASK_MIRROR_ROUTE replaces `bun <repo>/scripts/telegram/chief-route.ts`;
# ASK_MIRROR_OWE replaces owe.sh.
#
# Platform guard: bash, jq, python3.
set -u

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$KIT/../../.." && pwd)"
OWE_SH="${ASK_MIRROR_OWE:-$KIT/owe.sh}"
command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

payload=""
IFS= read -r -t 5 -d '' payload
[ -n "$payload" ] || exit 0
fields="$(printf '%s' "$payload" | jq -r '[(.session_id // ""), (.transcript_path // "")] | @tsv' 2>/dev/null)" || exit 0  # swallow-ok: junk payload posts nothing
IFS='	' read -r session_id transcript <<EOF
$fields
EOF
[ -n "$session_id" ] || exit 0

# shellcheck disable=SC1091
if . "$REPO/scripts/lib/load-dotenv.sh" 2>/dev/null; then load_dotenv HANDOVER_DIR 2>/dev/null || true; fi
# shellcheck source=../../lib/handover-path.sh
. "$REPO/scripts/lib/handover-path.sh" 2>/dev/null || exit 0
root="$(handover_root 2>/dev/null)" || exit 0  # swallow-ok: no handover root, no chief to mirror for
[ -n "$root" ] && [ -d "$root/.locks/queue" ] || exit 0

digest_of() {
    if command -v sha256sum >/dev/null 2>&1; then printf '%s' "$1" | sha256sum | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1; fi
}

token_dir="${XDG_RUNTIME_DIR:-/tmp}/himmel-queue-lock"
chief_doc=""
for lockdir in "$root"/.locks/queue/*-console.lock "$root"/.locks/queue/*-chief.lock; do
    [ -f "$lockdir/owner.json" ] || continue
    doc="$(jq -r '.handover // empty' "$lockdir/owner.json" 2>/dev/null)" || continue  # swallow-ok: an unreadable lock is not ours
    [ -n "$doc" ] || continue
    doc="${doc//\\//}"
    digest="$(digest_of "$session_id|$doc")"
    [ -n "$digest" ] || exit 0
    for tokfile in "$token_dir/$digest".*; do
        [ -f "$tokfile" ] && chief_doc="$doc"
    done
    [ -z "$chief_doc" ] || break
done
[ -n "$chief_doc" ] || exit 0
chief="${chief_doc##*/}"; chief="${chief%.md}"

reply="$(printf '%s' "$payload" | jq -r '.last_assistant_message // empty' 2>/dev/null)"  # swallow-ok: no reply field falls back to the transcript
if [ -z "$reply" ] && [ -n "$transcript" ] && [ -r "$transcript" ]; then
    reply="$(jq -R -s -r '
        [split("\n")[] | fromjson? // empty | select(.type == "user" or .type == "assistant")] as $e
        | ([range(0; $e | length) | select($e[.].type == "user")] | last // -1) as $u
        | [$e[($u + 1):][] | .message.content | arrays | .[] | select(.type == "text") | .text] | join("\n\n")
    ' "$transcript" 2>/dev/null)"
fi
[ -n "$reply" ] || exit 0
case "$reply" in *"Needs you:"*) ;; *) exit 0 ;; esac

blocks="$(printf '%s' "$reply" | python3 -c '
import hashlib, json, sys
chief = sys.argv[1]
lines = sys.stdin.read().split("\n")
blocks, i, n = [], 0, len(lines)
def fence(i):
    code = []
    i += 1
    while i < n and not lines[i].lstrip().startswith("```"):
        code.append(lines[i]); i += 1
    return "\n".join(code), i + 1
while i < n:
    if "Needs you:" not in lines[i]:
        i += 1; continue
    ask, codes = [lines[i]], []
    i += 1
    while i < n and lines[i].strip() and "Needs you:" not in lines[i]:
        if lines[i].lstrip().startswith("```"):
            c, i = fence(i); codes.append(c)
        else:
            ask.append(lines[i]); i += 1
    j = i
    while j < n and not lines[j].strip():
        j += 1
    if j < n and lines[j].lstrip().startswith("```"):
        c, i = fence(j); codes.append(c)
    a, c = "\n".join(ask).strip(), "\n".join(codes).strip()
    key = hashlib.sha256("\0".join([chief, a, c]).encode()).hexdigest()
    blocks.append({"key": key, "ask": a, "code": c})
for b in blocks:
    print(json.dumps(b))
' "$chief" 2>/dev/null)" || exit 0
[ -n "$blocks" ] || exit 0

state_dir="$root/.ask-mirror"
sent="$state_dir/$chief.sent"
mkdir -p "$state_dir" 2>/dev/null || exit 0

post() {
    if [ -n "${ASK_MIRROR_ROUTE:-}" ]; then
        "$ASK_MIRROR_ROUTE" reply --chief "$chief" --kind chief-reply operator "$1" >/dev/null
    elif command -v timeout >/dev/null 2>&1; then
        timeout 60 bun "$REPO/scripts/telegram/chief-route.ts" reply --chief "$chief" --kind chief-reply operator "$1" >/dev/null
    else
        bun "$REPO/scripts/telegram/chief-route.ts" reply --chief "$chief" --kind chief-reply operator "$1" >/dev/null
    fi
}

while IFS= read -r row; do
    [ -n "$row" ] || continue
    key="$(printf '%s' "$row" | jq -r '.key')"
    ask="$(printf '%s' "$row" | jq -r '.ask')"
    code="$(printf '%s' "$row" | jq -r '.code')"
    [ -n "$key" ] && [ -n "$ask" ] || continue
    grep -qxF "$key" "$sent" 2>/dev/null && continue
    if post "$ask" && { [ -z "$code" ] || post "$code"; }; then
        printf '%s\n' "$key" >> "$sent"
    else
        line="$(printf '%s' "$ask" | tr '\n\t' '  ')"
        bash "$OWE_SH" add --bucket "${chief_doc%/*}" --chief "$chief" --kind step \
            --text "Telegram ask not sent, post it by hand: $line" --identity "$key" >/dev/null 2>&1 \
            || echo "ask-mirror: post failed and the owed row was not written for: $line" >&2
    fi
done <<EOF
$blocks
EOF
exit 0
