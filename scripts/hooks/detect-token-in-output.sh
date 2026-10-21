#!/usr/bin/env bash
# PostToolUse hook: page the operator the moment a GitHub token
# shows up in a tool call or its result.
#
# WHY: block-read-secrets.sh denies the shapes we know print a credential, but
# the gh login token and the Codex fine-grained PAT still reached 33 and 29
# transcripts through shapes it did not know, and the leak was found days late,
# by accident. A transcript holds every tool result verbatim, so a token in one
# is one Read away from any later session. This is the DETECTION half: it
# cannot un-print anything, it makes the next leak an immediate rotation.
#
# What it matches (the gitleaks GitHub rules): ghp_ / gho_ / ghu_ / ghs_ / ghr_
# followed by 36 alphanumerics, and github_pat_ followed by 82 word chars. The
# whole hook input is scanned as text, so the tool_response shape (string,
# array, Codex or Claude) does not matter, and a token in tool_input (a Write
# body) counts too: it lands in the transcript all the same.
#
# On a hit it emits ONE JSON object on stdout: `systemMessage` for the
# operator's screen and `additionalContext` telling the agent to report it, and
# sends one Telegram DM to the operator through merge-block-alert.sh's bridge
# sender (the same path vault-stall-alert.sh uses). The alert names the tool,
# the token kind and the variable it was assigned to when the text shows one
# (`NAME=token`, `'NAME': 'token'`), NEVER the value. One DM per (session,
# token): the sentinel is a sha256 of the token, never the token.
#
# Fail-OPEN: a detector must never break a tool call on its own bug, and a
# PostToolUse hook cannot stop a call that already ran. Always exits 0.
# The clean path forks nothing: the scan is a bash regex on stdin.
#
# Seams (hermetic suites):
#   TOKEN_ALERT_DIR       sentinel directory (default ~/.himmel/state/token-in-output)
#   MERGE_BLOCK_ALERT_CMD replaces the DM sender, `$CMD <chat_id> <text>` (merge-block-alert.sh)
#   TELEGRAM_ACCESS_PATH  access.json with the operator chat id (merge-block-alert.sh)
#
# ponytail: the token kinds are GitHub's only (the leak that motivated this);
# other providers' key shapes are a one-line regex each, add on the first leak.

# `read`, a builtin, so the clean path forks nothing (rc 1 at EOF is expected).
IFS= read -r -d '' input 2>/dev/null || :

tok_re='(gh[opusr]_[0-9A-Za-z]{36}|github_pat_[0-9A-Za-z_]{82})'
[[ $input =~ $tok_re ]] || exit 0

# A test fixture is never a credential, and we call a value one only when two
# independent signals agree, so a wrong guess about either cannot hide a real
# token. (1) Low entropy: a random base62 body has far more than 7 distinct
# characters; a fixture is one or two characters repeated. (2) A real
# ghp_/gho_/ghu_/ghs_/ghr_ token ends in a 6-char base62 CRC32 of the 30 chars
# before it, so a fixture fails it. A fine-grained PAT carries no checksum, so
# low entropy alone decides it. Pure bash: the regex-hit path forks nothing.
b62="0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
is_real_token() {
    local t="$1" body seen="" ch c i j b n sum=""
    case "$t" in github_pat_*) body="${t#github_pat_}" ;; *) body="${t:4}" ;; esac
    n=${#body}
    for ((i = 0; i < n; i++)); do
        ch="${body:i:1}"
        case "$seen" in *"$ch"*) ;; *) seen="$seen$ch" ;; esac
    done
    [ "${#seen}" -ge 8 ] && return 0
    case "$t" in github_pat_*) return 1 ;; esac
    body="${t:4:30}"
    c=4294967295
    for ((i = 0; i < 30; i++)); do
        printf -v b '%d' "'${body:i:1}"
        c=$((c ^ b))
        for ((j = 0; j < 8; j++)); do
            if ((c & 1)); then c=$(((c >> 1) ^ 3988292384)); else c=$((c >> 1)); fi
        done
    done
    c=$((c ^ 4294967295))
    for ((i = 0; i < 6; i++)); do
        sum="${b62:c%62:1}$sum"
        c=$((c / 62))
    done
    [ "$sum" = "${t:34}" ]
}

# Every distinct token in the text, not just the first: a token already alerted
# on must not hide a new one printed after it. A fixture is skipped here, so a
# text holding only fixtures ends the hook below, silent.
tokens=()
rest=$input
while [[ $rest =~ $tok_re ]]; do
    t="${BASH_REMATCH[1]}"
    case " ${tokens[*]-} " in
        *" $t "*) ;;
        *) if is_real_token "$t"; then tokens+=("$t"); fi ;;
    esac
    rest="${rest#*"$t"}"
done
[ "${#tokens[@]}" -gt 0 ] || exit 0

# Per token: the kind and the variable it was assigned to, when the text shows
# one. Names are read from the DECODED string values (jq), so an escaped `\n`
# before `NAME=` does not become part of the name; without jq, the raw text.
# Quotes may still be JSON-escaped there (`\"`), hence the backslash in the
# bracket. A name that is itself a token is never used: it would echo it.
scan=""
if command -v jq >/dev/null 2>&1; then
    scan=$(jq -r '[.. | strings] | join("\n")' <<<"$input" 2>/dev/null) || scan=""
fi
[ -n "$scan" ] || scan=$input
desc=""
for token in "${tokens[@]}"; do
    kind="${token%%_*}_"
    case "$token" in github_pat_*) kind="github_pat_" ;; esac
    var="unknown"
    name_re="([A-Za-z_][A-Za-z0-9_]*)[\"'\\\\]*[=:][[:space:]]*[\"'\\\\]*${token}"
    if [[ $scan =~ $name_re ]]; then var="${BASH_REMATCH[1]}"; fi
    if [[ $var =~ $tok_re ]]; then var="unknown"; fi
    desc="${desc:+$desc; }${kind}…, variable ${var}"
done

tool="unknown"; session=""
if command -v jq >/dev/null 2>&1; then
    tool=$(jq -r '.tool_name // "unknown"' <<<"$input" 2>/dev/null) || tool="unknown"
    session=$(jq -r '.session_id // ""' <<<"$input" 2>/dev/null) || session=""
fi
case "$tool" in *[!A-Za-z0-9_.:-]*|'') tool="unknown" ;; esac
case "$session" in *[!A-Za-z0-9_.-]*) session="" ;; esac

what="a GitHub token"
if [ "${#tokens[@]}" -gt 1 ]; then what="${#tokens[@]} GitHub tokens"; fi
msg="TOKEN-IN-OUTPUT: ${what} (${desc}) appeared in a ${tool} tool call or result${session:+ in session ${session}}. It is now in the transcript: rotate it."
ctx="SECURITY: ${msg} Do not repeat, quote or re-read that output. Report it to your console or the operator now (tool ${tool}; ${desc}; never the value)."

if command -v jq >/dev/null 2>&1; then
    # Wired for PostToolUse and PostToolUseFailure: answer with the event it fired on.
    event=$(jq -r '.hook_event_name // "PostToolUse"' <<<"$input" 2>/dev/null) || event="PostToolUse"
    case "$event" in PostToolUse|PostToolUseFailure) ;; *) event="PostToolUse" ;; esac
    jq -cn --arg m "$msg" --arg c "$ctx" --arg e "$event" \
        '{systemMessage: $m, hookSpecificOutput: {hookEventName: $e, additionalContext: $c}}'
else
    echo "$msg" >&2
fi

# One DM per (session, token): page when any token is new in this session. A
# sentinel claimed here is released again if the DM cannot be sent (no alert
# library, no chat id, a failed send), so a later call retries it. A sent DM
# writes "sent" into its sentinel; an empty one older than 2 minutes is a claim
# whose hook was killed mid-send (the 60s hook timeout), so it is reclaimed.
dir="${TOKEN_ALERT_DIR:-$HOME/.himmel/state/token-in-output}"
mkdir -p "$dir" 2>/dev/null || exit 0
claimed=()
for token in "${tokens[@]}"; do
    hash=""
    if command -v sha256sum >/dev/null 2>&1; then
        hash=$(printf '%s' "$token" | sha256sum 2>/dev/null) || hash=""
    elif command -v shasum >/dev/null 2>&1; then
        hash=$(printf '%s' "$token" | shasum -a 256 2>/dev/null) || hash=""
    fi
    hash="${hash%% *}"
    [ -n "$hash" ] || continue
    key="${session:-nosession}__${hash:0:32}"
    if [ -f "$dir/$key" ] && [ ! -s "$dir/$key" ] && [ -n "$(find "$dir/$key" -mmin +2 2>/dev/null)" ]; then
        rm -f "$dir/$key" 2>/dev/null
    fi
    if ( set -o noclobber; : > "$dir/$key" ) 2>/dev/null; then claimed+=("$dir/$key"); fi
done
[ "${#claimed[@]}" -gt 0 ] || exit 0

lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/../lib/merge-block-alert.sh"
sent=0
# shellcheck source=../lib/merge-block-alert.sh
# shellcheck disable=SC1091
if { [ -r "$lib" ] && . "$lib"; } 2>/dev/null; then
    chat=$(_mba_operator_chat) || chat=""
    if [ -n "$chat" ] && _mba_send "$chat" "$msg" >/dev/null 2>&1; then sent=1; fi
fi
if [ "$sent" = 0 ]; then
    rm -f "${claimed[@]}" 2>/dev/null
else
    for f in "${claimed[@]}"; do printf 'sent\n' > "$f" 2>/dev/null; done
fi
exit 0
