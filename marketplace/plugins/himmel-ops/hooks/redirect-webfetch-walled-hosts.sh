#!/usr/bin/env bash
# redirect-webfetch-walled-hosts.sh — PreToolUse hook (matcher "WebFetch"):
# denies WebFetch on a login-walled host (x.com, instagram.com, ...), where
# WebFetch gets HTTP 402 and a session would otherwise ask the operator for a
# paste. Second drift on prose -> structural (root CLAUDE.md "Adding a rule").
#
# Delivered by the himmel-ops PLUGIN lane so it fires in every repo, not only a
# himmel checkout. This file is the only copy of the rule;
# scripts/hooks/redirect-webfetch-walled-hosts.sh in the himmel checkout is a
# shim that points WALLED_TOOLING_DIR at scripts/web and runs this file.
#
# Two modes, by whether the himmel fetcher is reachable:
#  - himmel: scripts/web/fetch-url.sh and walled-hosts.conf exist under
#    WALLED_TOOLING_DIR (default $CLAUDE_PROJECT_DIR/scripts/web). The host list
#    is the one line of that conf and the deny names the paste-ready, quoted
#    `bash <fetcher> '<url>'`.
#  - adopter: no such files. The host list is the embedded WALLED_HOSTS below
#    (kept equal to the conf line by this plugin's suite) and the deny names no
#    himmel script, only the bypass.
#
# Each deny appends one JSONL row (ts, session_id, decision, host) to
# WEBFETCH_WALLED_LOG (default ~/.claude/webfetch-walled/denials.jsonl),
# best-effort; the URL is never logged (it can carry a token). Setting
# WEBFETCH_WALLED_LOG=/dev/null turns the row off (the himmel shim does, so one
# deny is one row).
#
# Workflow convenience, not a security fence (scripts/hooks/CLAUDE.md
# "Fail-open vs fail-closed"): fails OPEN on anything it cannot parse (missing
# jq, malformed input, a non-string or control-char URL). No network.
#
# Bypass: HIMMEL_WEBFETCH_WALLED_OK=1 in the LAUNCHING shell (session-sticky; a
# per-call prefix does not reach this hook process).
#
# Hook I/O: JSON on stdin. exit 0 = allow, exit 2 = deny (stderr plus a
# structured hookSpecificOutput.permissionDecision on stdout). bash 3.2-safe.
set -uo pipefail

[ "${HIMMEL_WEBFETCH_WALLED_OK:-0}" = "1" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

WALLED_HOSTS="x.com twitter.com mobile.twitter.com instagram.com reddit.com redd.it"

input=$(cat 2>/dev/null) || exit 0
fields=$(printf '%s' "$input" | jq -r '(.tool_name // "") + "\n" + (.session_id // "") + "\n" + (.tool_input.url // empty | strings)' 2>/dev/null) || exit 0
tool=${fields%%$'\n'*}
rest=${fields#*$'\n'}
session=${rest%%$'\n'*}
url=${rest#*$'\n'}
[ "$tool" = "WebFetch" ] || exit 0
[ -n "$url" ] || exit 0
case "$url$session" in *[[:cntrl:]]*) exit 0 ;; esac

tooling=${WALLED_TOOLING_DIR:-${CLAUDE_PROJECT_DIR:+$CLAUDE_PROJECT_DIR/scripts/web}}
fetcher=""
hosts=$WALLED_HOSTS
if [ -n "$tooling" ] && [ -f "$tooling/fetch-url.sh" ] && [ -r "$tooling/walled-hosts.conf" ]; then
    fetcher="$tooling/fetch-url.sh"
    hosts=$(head -n 1 "$tooling/walled-hosts.conf")
fi

# authority = between "://" and the first / ? #; drop userinfo and port.
rest="${url#*://}"
[ "$rest" != "$url" ] || exit 0
auth="${rest%%[/?#]*}"
auth="${auth##*@}"
host="${auth%%:*}"
host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')
[ -n "$host" ] || exit 0

hit=0
for h in $hosts; do
    case "$host" in "$h" | *".$h") hit=1; break ;; esac
done
[ "$hit" = 1 ] || exit 0

if [ -n "$fetcher" ]; then
    quoted="'$(printf '%s' "$url" | sed "s/'/'\\\\''/g")'"
    qfetcher="'$(printf '%s' "$fetcher" | sed "s/'/'\\\\''/g")'"
    deny_msg="WebFetch is walled on this host (HTTP 402/login wall). Fetch it with the stealth fetcher instead, then work from its output: bash $qfetcher $quoted (bypass: HIMMEL_WEBFETCH_WALLED_OK=1 in the launching shell)"
else
    deny_msg="WebFetch is walled on $host (HTTP 402/login wall) and will not return the page. Use a browser-capable tool if one is configured, or ask the operator to paste the text (bypass: HIMMEL_WEBFETCH_WALLED_OK=1 in the launching shell)"
fi

log=${WEBFETCH_WALLED_LOG:-${HOME:-}/.claude/webfetch-walled/denials.jsonl}
if [ "$log" != /dev/null ] && mkdir -p "$(dirname "$log")" 2>/dev/null; then
    jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg session_id "$session" --arg host "$host" \
        '{ts: $ts, session_id: $session_id, decision: "deny", host: $host}' \
        >>"$log" 2>/dev/null || true
fi

reason=$(printf '%s' "$deny_msg" | jq -Rs . 2>/dev/null) \
    || reason='"redirect-webfetch-walled-hosts: this host is walled; paste the text instead"'
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$reason"
printf '%s\n' "$deny_msg" >&2
exit 2
