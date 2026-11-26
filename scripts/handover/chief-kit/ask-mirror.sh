#!/usr/bin/env bash
# Usage: ask-mirror.sh < <Stop hook payload JSON>
# Test seams: ASK_MIRROR_ROUTE replaces `bun <repo>/scripts/telegram/chief-route.ts`;
# ASK_MIRROR_OWE replaces owe.sh. ASK_MIRROR_BUDGET_SEC (default 80) bounds the whole run.
set -u
SECONDS=0

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
# shellcheck source=../../lib/timeout-bin.sh
. "$REPO/scripts/lib/timeout-bin.sh"
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
printf '%s\n' "$reply" | grep -Eq '^[[:space:]]*((([0-9]+[.)])|-|\*|•)[[:space:]]*)?Needs you:' || exit 0

blocks="$(printf '%s' "$reply" | python3 -c '
import hashlib, json, re, sys
chief = sys.argv[1]
lines = sys.stdin.read().split("\n")
blocks, i, n = [], 0, len(lines)
def fence(i):
    code = []
    i += 1
    while i < n and not lines[i].lstrip().startswith("```"):
        code.append(lines[i]); i += 1
    return "\n".join(code), i + 1
def squeeze(t):
    return re.sub(r"[ \t]+", " ", t).rstrip()
def digest(*parts):
    return hashlib.sha256("\0".join(parts).encode()).hexdigest()
mark = re.compile(r"^\s*(?:(?:\d+[.)]|[-*•])\s*)?Needs you:")
while i < n:
    m = mark.match(lines[i])
    if not m:
        i += 1; continue
    first = lines[i]
    cut = m.end() - len("Needs you:")
    num = re.search(r"(?:^|\s)(\d+[.)])\s*$", first[:cut])
    first_n = squeeze(first[cut:])
    first_p = num.group(1) + " " + first_n if num else first_n
    more, codes = [], []
    i += 1
    while i < n and lines[i].strip() and not mark.match(lines[i]):
        if lines[i].lstrip().startswith("```"):
            c, i = fence(i); codes.append(c)
        else:
            more.append(squeeze(lines[i])); i += 1
    j = i
    while j < n and not lines[j].strip():
        j += 1
    if j < n and lines[j].lstrip().startswith("```"):
        c, i = fence(j); codes.append(c)
    p = "\n".join([first_p] + more).strip()
    nf = "\n".join([first_n] + more).strip()
    nc = " ".join(nf.split())
    c = "\n".join(codes).strip()
    blocks.append({"key": digest(chief, nc, c), "askkey": digest(chief, nc),
                   "okey": "ask-" + digest(chief, nf, c)[:16], "ask": p, "code": c})
for b in blocks:
    print(json.dumps(b))
' "$chief" 2>/dev/null)" || exit 0
[ -n "$blocks" ] || exit 0

state_dir="$root/.ask-mirror"
sent="$state_dir/$chief.sent"
posted_dir="$state_dir/$chief.posted"
mkdir -p "$state_dir" 2>/dev/null || exit 0

budget="${ASK_MIRROR_BUDGET_SEC:-80}"
case "$budget" in ''|*[!0-9]*) budget=80 ;; esac
budget=$((10#$budget))

post() {
    local t=$((budget - SECONDS))
    [ "$t" -gt 90 ] && t=90
    [ "$t" -lt 1 ] && t=1
    if [ -n "${ASK_MIRROR_ROUTE:-}" ]; then
        ${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" "$t"} "$ASK_MIRROR_ROUTE" reply --chief "$chief" --owed "$1" --doc "$chief_doc" --kind chief-reply operator "$2" >/dev/null </dev/null
    else
        ${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" "$t"} bun "$REPO/scripts/telegram/chief-route.ts" reply --chief "$chief" --owed "$1" --doc "$chief_doc" --kind chief-reply operator "$2" >/dev/null </dev/null
    fi
}

owe() {
    bash "$OWE_SH" add --bucket "${chief_doc%/*}" --chief "$chief" --kind step \
        --text "$1: $line" --identity "$key" >/dev/null 2>&1 </dev/null \
        || echo "ask-mirror: owed row not written for key $key" >&2
}

while IFS= read -r row; do
    [ -n "$row" ] || continue
    key="$(printf '%s' "$row" | jq -r '.key')"
    askkey="$(printf '%s' "$row" | jq -r '.askkey')"
    okey="$(printf '%s' "$row" | jq -r '.okey')"
    ask="$(printf '%s' "$row" | jq -r '.ask')"
    code="$(printf '%s' "$row" | jq -r '.code')"
    [ -n "$key" ] && [ -n "$ask" ] && [ -n "$okey" ] || continue
    grep -qxF "$key" "$sent" 2>/dev/null && continue
    [ -z "$code" ] && grep -qxF "$askkey" "$sent" 2>/dev/null && continue
    line="$(printf '%s' "$ask" | tr '\n\t' '  ')"
    if [ "$SECONDS" -ge "$budget" ]; then
        owe "Telegram ask not posted, check the bridge"
        continue
    fi
    stored="$posted_dir/$okey"
    if [ -s "$stored" ]; then
        ask="$(cat "$stored")"
    elif mkdir -p "$posted_dir" 2>/dev/null; then
        printf '%s' "$ask" > "$stored.$$" 2>/dev/null && mv -f "$stored.$$" "$stored" 2>/dev/null
    fi
    if post "$okey" "$ask" && { [ -z "$code" ] || post "$okey-code" "$code"; }; then
        printf '%s\n%s\n' "$key" "$askkey" >> "$sent"
    else
        export CHIEF_ROUTE_RECEIPT_WAIT_SEC=0
        owe "Telegram ask not delivered, check the bridge"
    fi
done <<EOF
$blocks
EOF
exit 0
