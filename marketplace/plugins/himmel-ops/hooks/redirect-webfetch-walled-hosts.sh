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
#    WALLED_TOOLING_DIR (default: the checkout of the user-scope "himmel"
#    marketplace, installLocation in <config>/plugins/known_marketplaces.json,
#    minus its last path part). The host list is the one line of that conf and
#    the deny names the paste-ready, quoted `bash <fetcher> '<url>'`. An
#    installed plugin sits in the plugin cache, not the checkout, so the checkout
#    is found from that record. Files under the PROJECT ($CLAUDE_PROJECT_DIR) are
#    never read: a guard a project file can reroute or empty is a hole. An empty
#    conf line keeps the embedded list.
#  - adopter: no such files. The host list is the embedded WALLED_HOSTS below
#    (kept equal to the conf line by this plugin's suite) and the deny names no
#    himmel script, only the bypass.
#
# Each deny appends one JSONL row (ts, session_id, decision, host) to
# WEBFETCH_WALLED_LOG (default ~/.claude/webfetch-walled/denials.jsonl),
# best-effort; the URL is never logged (it can carry a token). Setting
# WEBFETCH_WALLED_LOG=/dev/null turns the row off. With HOME unset the log is
# ${TMPDIR:-/tmp}/himmel-webfetch-walled-<uid>/denials.jsonl instead of nowhere.
# The himmel shim runs this same file, so a session with the plugin disabled or
# cached at an older version still logs its deny; when both lanes fire, the first
# to claim the deny's tool_use_id (a file under <log dir>/.claims) writes the one row.
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
fields=$(printf '%s' "$input" | jq -r '(.tool_name // "") + "\n" + (.session_id // "") + "\n" + ((.tool_use_id // "") | if type == "string" and test("\\A[A-Za-z0-9_-]+\\z") then . else "" end) + "\n" + (.tool_input.url // empty | strings)' 2>/dev/null) || exit 0
tool=${fields%%$'\n'*}
rest=${fields#*$'\n'}
session=${rest%%$'\n'*}
rest=${rest#*$'\n'}
callid=${rest%%$'\n'*}
url=${rest#*$'\n'}
[ "$tool" = "WebFetch" ] || exit 0
[ -n "$url" ] || exit 0
case "$url$session" in *[[:cntrl:]]*) exit 0 ;; esac

tooling=${WALLED_TOOLING_DIR:-}
if [ -z "$tooling" ]; then
    cfg=${CLAUDE_CONFIG_DIR:-${HOME:+$HOME/.claude}}
    mk=""
    [ -n "$cfg" ] && mk=$(jq -r '.himmel.installLocation // empty | strings' "$cfg/plugins/known_marketplaces.json" 2>/dev/null)
    mk=${mk%/}
    [ -n "$mk" ] && tooling="${mk%/*}/scripts/web"
fi
fetcher=""
hosts=$WALLED_HOSTS
if [ -n "$tooling" ] && [ -f "$tooling/fetch-url.sh" ] && [ -r "$tooling/walled-hosts.conf" ]; then
    conf_hosts=$(head -n 1 "$tooling/walled-hosts.conf")
    # An empty conf line keeps the embedded list, so the guard never goes silent.
    if [ -n "${conf_hosts//[[:space:]]/}" ]; then
        fetcher="$tooling/fetch-url.sh"
        hosts=$conf_hosts
    fi
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

log=${WEBFETCH_WALLED_LOG:-}
logok=1
if [ -z "$log" ]; then
    if [ -n "${HOME:-}" ]; then
        log=$HOME/.claude/webfetch-walled/denials.jsonl
    else
        # No HOME: a per-user temp-dir log, so the deny is still counted.
        fbdir=${TMPDIR:-/tmp}/himmel-webfetch-walled-$(id -u)
        log=$fbdir/denials.jsonl
        mkdir -m 700 "$fbdir" 2>/dev/null
        { [ -d "$fbdir" ] && [ -O "$fbdir" ] && [ ! -L "$fbdir" ]; } || logok=0
    fi
fi
if [ "$log" != /dev/null ] && [ "$logok" = 1 ] && mkdir -p "$(dirname "$log")" 2>/dev/null; then
    # The project shim and the plugin lane both run this file for one deny; the
    # first to claim the deny's tool_use_id writes the row, so one deny is one row
    # whichever lanes fire. No id, or a claim that cannot be made for a reason
    # other than "already claimed": write (never lose a row). A failed append
    # releases the claim so the other lane can still write.
    claimed=1
    claimfile=""
    case "$callid" in
        "" | *[!A-Za-z0-9_-]*) ;;
        *)
            claims="$(dirname "$log")/.claims"
            if mkdir -p "$claims" 2>/dev/null; then
                find "$claims" -type f -mmin +60 -delete 2>/dev/null || true
                if (set -C; : >"$claims/$callid") 2>/dev/null; then
                    claimfile="$claims/$callid"
                elif [ -e "$claims/$callid" ]; then
                    claimed=0
                fi
            fi
            ;;
    esac
    if [ "$claimed" = 1 ]; then
        jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg session_id "$session" --arg host "$host" \
            '{ts: $ts, session_id: $session_id, decision: "deny", host: $host}' \
            >>"$log" 2>/dev/null || { [ -z "$claimfile" ] || rm -f "$claimfile" 2>/dev/null; }
    fi
fi

reason=$(printf '%s' "$deny_msg" | jq -Rs . 2>/dev/null) \
    || reason='"redirect-webfetch-walled-hosts: this host is walled; paste the text instead"'
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$reason"
printf '%s\n' "$deny_msg" >&2
exit 2
