#!/usr/bin/env bash
# approval-grant-request.sh — PermissionDenied hook: file one grant request with the root
# afk-sudo helper for a Bash call the permission classifier refused.
#
# It pipes the refused command's exact bytes (jq -j of tool_input.command) to
#
#   sudo -n /usr/local/libexec/himmel/afk-sudo grant-request --session=S --cwd=D --why=R --desc=T
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
MBA="$HERE/../lib/merge-block-alert.sh"
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
name_ok() { [ -n "$1" ] && [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && [[ $1 != *..* ]]; }
current_chief() {
    local c=$1 next seen=" $1 "
    while :; do
        [ -f "$CONSOLES/$c.md.handover" ] && [ -r "$CONSOLES/$c.md.handover" ] || break
        next=$(sed -n 1p "$CONSOLES/$c.md.handover" | tr -d '[:space:]')
        name_ok "$next" && [ -f "$CONSOLES/$next.md" ] || break
        case "$seen" in *" $next "*) break ;; esac
        seen="$seen$next "; c=$next
    done
    printf '%s' "$c"
}
command_head() {
    local w h='' n=0 words=()
    read -r -a words <<<"${1#"${1%%[![:space:]]*}"}"
    for w in ${words[@]+"${words[@]}"}; do
        case "$w" in *=*) continue ;; esac
        case "$w" in *[\"\'\`\$\(\)\;\&\|\<\>]*) break ;; esac
        [ -z "$h" ] || case "$w" in -*) break ;; esac
        w=$(printf '%s' "${w##*/}" | tr -cd 'A-Za-z0-9._@+-' | cut -c1-40)
        [ -n "$w" ] || break
        h=${h:+$h }$w; n=$((n + 1))
        [ "$n" -lt 2 ] || break
        case "$w" in bash | sh | zsh | dash | env | sudo | python | python3 | node | bun | npx | perl | ruby) ;; *) break ;; esac
    done
    printf '%s' "${h:-unknown}"
}
notify() {
    local op inbox=''
    op=$(jq -r '.operator_id // empty' "$CONFIG" 2>/dev/null | grep -E '^-?[0-9]{1,20}$' | head -1)  # swallow-ok: no readable operator id means no send
    name_ok "${2:-}" && inbox="$CONSOLES/$2.md"
    [ -n "$op" ] || [ -n "$inbox" ] || return 0
    # shellcheck disable=SC2016
    detach_run bash -c '. "$1" || exit 0
        [ -z "$2" ] || _mba_send "$2" "$3" afk-grant-refused
        [ -z "$4" ] || _mba_append_if_exists "$4" "- $(date +%H:%M) [afk-grant-refused] $3"' \
        afk-grant-refused "$MBA" "$op" "$1" "$inbox"
}

sname=''
lib="$HERE/../lib/session-name.sh"
# shellcheck source=scripts/lib/session-name.sh
if { [ -r "$lib" ] && . "$lib"; } 2>/dev/null; then
    sname=$(current_session_name 2>/dev/null) || sname=''  # swallow-ok: an unresolvable name is not a chief
fi
who=${sname:-$session}
head=$(command_head "$(jq -r '.tool_input.command' <<<"$input")")
chief=${HIMMEL_CONSOLE_NAME:-}
name_ok "$chief" || chief=''
if [ -n "$chief" ]; then
    chief=$(current_chief "$chief")
elif [ -n "$sname" ] && [ -f "$CONSOLES/$sname.md" ]; then
    chief=$(current_chief "$sname")
else
    grants_on && notify "AFK grant from session $who refused, no ask was sent: the session has no chief to route the ask to, so the denied call \`$head\` [$category] was not filed"
    exit 0
fi
export HIMMEL_CONSOLE_NAME="$chief"

drop_invisible='s/[\p{Cc}\p{Cf}\x{2028}\x{2029}]//g'
desc=$(jq -r '.tool_input.description // "" | tostring' <<<"$input" 2>/dev/null | head -n 1 | perl -CSD -pe "$drop_invisible" 2>/dev/null | cut -c1-200 | iconv -c -f UTF-8 -t UTF-8 2>/dev/null)  # swallow-ok: a missing description reads as empty and the card omits the line
cmd1=$(jq -r '.tool_input.command' <<<"$input" 2>/dev/null | head -n 1 | perl -CSD -pe "$drop_invisible" 2>/dev/null | cut -c1-300 | iconv -c -f UTF-8 -t UTF-8 2>/dev/null)  # swallow-ok: a missing command line reads as empty and the card omits the line

reply=$(jq -j '.tool_input.command' <<<"$input" 2>/dev/null |
    sudo -n "$HELPER" grant-request --session="$session" --cwd="$cwd" --why="$reason" --desc="$desc" 2>/dev/null)
result=$(printf '%s\n' "$reply" | sed -n 's/^result=\([a-z0-9:-]*\).*/\1/p' | head -1)
if [ -z "$result" ]; then
    reply=$(jq -j '.tool_input.command' <<<"$input" 2>/dev/null |
        sudo -n "$HELPER" grant-request --session="$session" --cwd="$cwd" --why="$reason" 2>/dev/null)
    result=$(printf '%s\n' "$reply" | sed -n 's/^result=\([a-z0-9:-]*\).*/\1/p' | head -1)
fi
field() { printf '%s\n' "$reply" | sed -n "s/^result=pending.* $1=\([^ ]*\).*/\1/p" | head -1; }
case "$result" in
    pending)
        id=$(field id) expires=$(field expires) op=$(field operator)
        detach_run bash "$REQ" --card "$id" --operator "$op" --session "$who" --desc "$desc" --cmd "$cmd1"
        detach_run bash "$REQ" --watch "$id" --expires "$expires" --operator "$op" --session "$who"
        ;;
    grant-disabled | disabled) ;;
    *)
        rule=$(printf '%s\n' "$reply" | sed -n 's/^result=never-remote.* rule=\([a-z0-9-]*\).*/\1/p' | head -1)
        told="its chief is told"
        [ -f "$CONSOLES/$chief.md" ] || told="its chief has no bridge inbox, so it is not told"
        case "$result" in
            never-remote) why="the station's never-remote rule ${rule:-unknown} covers it, so it can never be approved from the phone: the worker must take another route; $told" ;;
            notice-failed) why="the approval helper could not send the ask to the phone (notice-failed)" ;;
            '') why="the approval helper did not answer" ;;
            *) why="the approval helper refused it ($result)" ;;
        esac
        notify "AFK grant refused, no ask was sent and nothing ran: session $who (chief $chief) had \`$head\` refused by the classifier as [$category]; $why" "$chief"
        ;;
esac
exit 0
