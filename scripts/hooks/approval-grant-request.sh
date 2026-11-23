#!/usr/bin/env bash
# approval-grant-request.sh — PermissionDenied hook: file one grant request with the root
# afk-sudo helper for a Bash call the permission classifier refused.
#
# It pipes the refused command's exact bytes (jq -j of tool_input.command) to
#
#   sudo -n /usr/local/libexec/himmel/afk-sudo grant-request --session=S --cwd=D --why=R --desc=T
#
# T is the Bash call's own description, its first line only (the agent's claim; empty when the
# call has none). The bridge card gets T and the command's first line as --desc / --cmd.
#
# Root then binds every file the command names, runs the never-remote floor (a secret read
# is refused before any notice), freezes the record and sends the operator the full command
# through the root-only notice bot. Nothing here reads or forwards the classifier-denial log
# (the command head and reason fields log-classifier-denial.sh writes never leave the host); the notice is
# built from root's frozen record. The operator's `NONCE CODE` reply is the only way a grant
# is written; approval-grant-check.sh then lets the byte-identical retry through once.
#
# What files: only a real refusal, whose reason carries a bracketed classifier category
# (`[Unauthorized Persistence]`), the same rule as afk-denied-to-request.sh. A no-verdict
# denial, "Classifier unavailable" and a credential or exfiltration category file nothing.
#
# Off unless the station opted in: no marker directory (helper not installed) means no sudo
# call at all, and the helper refuses every request while grant.enabled is false.
#
# This is an OBSERVABILITY-STYLE TAP, same contract as log-classifier-denial.sh on the same
# event: it never blocks, delays or asks on a tool call,
# prints nothing, and exits 0 on every path. The helper caps requests (one pending at a time, max_per_hour).
#
# Test seam: AFK_GRANT_DIR names the marker directory.
#
# bash 3.2-compatible.
set -uo pipefail
trap 'exit 0' EXIT

HELPER=/usr/local/libexec/himmel/afk-sudo
MARKS="${AFK_GRANT_DIR:-/var/lib/himmel/afk-grants}"
HERE="$(cd "$(dirname "$0")" && pwd)" || exit 0
REQ="$HERE/../lib/afk-sudo-request"
CONSOLES="${BRIDGE_ROOT:-$HOME/.claude/handover/bridge}/consoles"
CONFIG="${AFK_SUDO_CONFIG:-/etc/himmel/afk-sudo.json}"

[ -d "$MARKS" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

input=''
IFS= read -r -d '' input 2>/dev/null || true  # swallow-ok: read -d '' ends at EOF with rc 1
[ -n "$input" ] || exit 0

tool=$(jq -r '.tool_name // ""' <<<"$input" 2>/dev/null) || exit 0  # swallow-ok: fail-open tap, no request on error
[ "$tool" = Bash ] || exit 0
has=$(jq -r '.tool_input.command | type == "string" and length > 0' <<<"$input" 2>/dev/null) || exit 0  # swallow-ok: fail-open tap
[ "$has" = true ] || exit 0
session=$(jq -r '.session_id // ""' <<<"$input" 2>/dev/null) || exit 0  # swallow-ok: fail-open tap
cwd=$(jq -r '.cwd // ""' <<<"$input" 2>/dev/null) || exit 0  # swallow-ok: fail-open tap
reason=$(jq -r '.reason // ""' <<<"$input" 2>/dev/null) || exit 0  # swallow-ok: fail-open tap
[ -n "$session" ] && [ -n "$cwd" ] || exit 0
category="$(printf '%s' "$reason" | grep -oE '\[[A-Za-z][A-Za-z -]*\]' | sed -n '1s/^\[\(.*\)\]$/\1/p')"
[ -n "$category" ] || exit 0
case "$(printf '%s' "$category" | tr '[:upper:]' '[:lower:]')" in
    *credential* | *exfiltrat* | *secret* | *token*) exit 0 ;;
esac

detach_lib="$HERE/../lib/detach.sh"
# shellcheck source=scripts/lib/detach.sh
{ [ -r "$detach_lib" ] && . "$detach_lib"; } 2>/dev/null || exit 0
grants_on() {
    local mode
    mode=" $(sudo -n "$HELPER" mode 2>/dev/null) "  # swallow-ok: no answer reads as grants off, so nothing is sent
    case "$mode" in *" enabled=true "*) ;; *) return 1 ;; esac
    case "$mode" in *" grant_enabled=true "*) return 0 ;; *) return 1 ;; esac
}
notify() {
    local op
    op=$(jq -r '.operator_id // empty' "$CONFIG" 2>/dev/null | grep -E '^-?[0-9]{1,20}$' | head -1)  # swallow-ok: no readable operator id means no send
    [ -n "$op" ] && detach_run bash "$REQ" --notify "$1" --operator "$op"
}

sname=''
lib="$HERE/../lib/session-name.sh"
# shellcheck source=scripts/lib/session-name.sh
if { [ -r "$lib" ] && . "$lib"; } 2>/dev/null; then
    sname=$(current_session_name 2>/dev/null) || sname=''  # swallow-ok: an unresolvable name is not a chief
fi
who=${sname:-$session}
chief=${HIMMEL_CONSOLE_NAME:-}
if [ -z "$chief" ]; then
    if [ -n "$sname" ] && [ -f "$CONSOLES/$sname.md" ]; then
        chief=$sname
    else
        grants_on && notify "AFK grant from session $who refused: no chief to route the ask; the denied Bash call [$category] was not filed"
        exit 0
    fi
fi
export HIMMEL_CONSOLE_NAME="$chief"

desc=$(jq -r '.tool_input.description // "" | tostring' <<<"$input" 2>/dev/null | head -n 1 | tr -d '\000-\037' | cut -c1-200 | iconv -c -f UTF-8 -t UTF-8 2>/dev/null)  # swallow-ok: a missing description reads as empty and the card omits the line
cmd1=$(jq -r '.tool_input.command' <<<"$input" 2>/dev/null | head -n 1 | tr -d '\000-\037' | cut -c1-300 | iconv -c -f UTF-8 -t UTF-8 2>/dev/null)  # swallow-ok: a missing command line reads as empty and the card omits the line

reply=$(jq -j '.tool_input.command' <<<"$input" 2>/dev/null |
    sudo -n "$HELPER" grant-request --session="$session" --cwd="$cwd" --why="$reason" --desc="$desc" 2>/dev/null)
result=$(printf '%s\n' "$reply" | sed -n 's/^result=\([a-z0-9:-]*\).*/\1/p' | head -1)
field() { printf '%s\n' "$reply" | sed -n "s/^result=pending.* $1=\([^ ]*\).*/\1/p" | head -1; }
case "$result" in
    pending)
        id=$(field id) expires=$(field expires) op=$(field operator)
        detach_run bash "$REQ" --card "$id" --operator "$op" --session "$who" --desc "$desc" --cmd "$cmd1"
        detach_run bash "$REQ" --watch "$id" --expires "$expires" --operator "$op" --session "$who"
        ;;
    grant-disabled | disabled) ;;
    *) notify "AFK grant from session $who (chief $chief) refused: ${result:-no reply from the helper}, nothing ran" ;;
esac
exit 0
