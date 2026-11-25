#!/usr/bin/env bash
# bypass-service.sh — turn the bypass launch daemon (bypass-launchd.sh) on and off as a service unit, and show its state.
# `himmelctl bypass on|off|restart|status` and himmel-update call it. Design: docs/internals/bypass-launch-route.md, "Run it as a service".
#
#   bypass-service.sh on [--bucket <dir>]     write the unit (systemd user unit; macOS LaunchAgent), enable and start it, enable lingering
#   bypass-service.sh off                     write the stop file, disable and stop the unit
#   bypass-service.sh restart                 clear a failed state and restart the unit now
#   bypass-service.sh status                  read only: enabled, active, pid, linger, unit and code freshness, heartbeat
#   bypass-service.sh restart-if-changed [--check]
#                                             himmel-update's hook: try-restart an enabled, running unit whose script changed
#   bypass-service.sh render [--bucket <dir>] print the unit (or plist) with its placeholders filled
#
# on, off and restart refuse inside a Claude session (CLAUDECODE). status and restart-if-changed do not.
# Exit: 0 ok; 1 not ok (on: a hand-started daemon holds the bucket; status: not running or stale; restart-if-changed: failed); 2 refused or bad use.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OPS=scripts/station-ops
UNIT=himmel-bypass-launchd.service
LABEL=com.himmel.bypass-launchd
PLIST=$LABEL.plist
OS="${BYPASSD_SERVICE_OS:-$(uname -s)}"
STATE="$HOME/.himmel/state/bypass-service"
CONFIG="$STATE/config"
UNIT_DIR="${HIMMELCTL_SYSTEMD_USER_UNIT_DIR:-$HOME/.config/systemd/user}"
AGENT_DIR="$HOME/Library/LaunchAgents"
CONFIRM="${BYPASSD_CONFIRM_SECS:-5}"
UID_N="$(id -u)"
PATH_RE='^/[A-Za-z0-9._/@+-]+$'

die() { echo "bypass-service: $*" >&2; exit 2; }
refuse_claude() { [ -z "${CLAUDECODE:-}" ] || die "refusing to $1 from inside a Claude session; the operator runs it from their own shell"; }
darwin() { [ "$OS" = Darwin ]; }
installed_path() { if darwin; then echo "$AGENT_DIR/$PLIST"; else echo "$UNIT_DIR/$UNIT"; fi; }
conf_get() { sed -n "s/^$1=//p" "$CONFIG" 2>/dev/null | head -n 1; }

render() {
    local bucket=$1 repo=$2 tpl line out="" home_x home_s
    home_x=$(printf '%s' "$HOME" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
    home_s=$(printf "%s" "$home_x" | sed 's/[\&|]/\\&/g')
    [[ "$bucket" =~ $PATH_RE ]] || die "the bucket path '$bucket' holds a character the unit cannot carry (use letters, digits and . _ / @ + -)"
    [[ "$repo" =~ $PATH_RE ]] || die "the checkout path '$repo' holds a character the unit cannot carry"
    if darwin; then tpl="$repo/$OPS/units/$PLIST"; else tpl="$repo/$OPS/units/$UNIT"; fi
    [ -f "$tpl" ] || die "no template at $tpl"
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line//@HIMMEL_ROOT@/${repo//%/%%}}
        line=${line//@BUCKET@/${bucket//%/%%}}
        line=$(printf "%s" "$line" | sed "s|@HOME@|$home_s|g")
        out+="$line"$'\n'
    done <"$tpl"
    case $out in *@[A-Z]*@*) die "the template left a placeholder unfilled" ;; esac
    printf '%s' "$out"
}

need_manager() {
    if darwin; then command -v launchctl >/dev/null 2>&1 || die "launchctl not found; this is not a macOS host"
    else command -v systemctl >/dev/null 2>&1 || die "systemctl not found; this is not a systemd host"; fi
}
sctl() { systemctl --user "$@"; }
m_enabled() {
    if darwin; then [ -f "$AGENT_DIR/$PLIST" ] && launchctl print "gui/$UID_N/$LABEL" >/dev/null 2>&1
    else sctl is-enabled "$UNIT" >/dev/null 2>&1; fi
}
m_pid() { launchctl print "gui/$UID_N/$LABEL" 2>/dev/null | sed -n 's/^[[:space:]]*pid = //p' | head -n 1; }
unit_pid() {
    if darwin; then m_pid; else sctl show "$UNIT" -p MainPID 2>/dev/null | sed -n 's/^MainPID=//p' | head -n 1; fi
}
m_active() {
    if darwin; then [ -n "$(m_pid)" ]; else sctl is-active --quiet "$UNIT" 2>/dev/null; fi
}

checkout_ids() {
    local repo=$1 s t r
    s=$(git -C "$repo" rev-parse --verify -q "HEAD:$OPS/bypass-launchd.sh" 2>/dev/null) \
        && t=$(git -C "$repo" rev-parse --verify -q "HEAD:$OPS/bypass-flag-tiers.tsv" 2>/dev/null) \
        && r=$(git -C "$repo" rev-parse --verify -q "HEAD:scripts/himmelctl/lib/bypass-flags.json" 2>/dev/null) || return 1
    printf '%s/%s/%s' "$s" "$t" "$r"
}

bucket_arg() {
    local b=""
    while [ $# -gt 0 ]; do
        case $1 in --bucket) [ $# -ge 2 ] || die "--bucket needs a directory"; b=$2; shift 2 ;; *) die "unknown argument $1" ;; esac
    done
    [ -n "$b" ] || b=$(conf_get bucket)
    [ -n "$b" ] || die "no bucket: pass --bucket <handover bucket> (the directory holding bypass-queue/)"
    [ -d "$b/bypass-queue" ] || die "$b holds no bypass-queue/ directory"
    (cd "$b" && pwd)
}

cmd_on() {
    refuse_claude "turn the bypass daemon on" # t13b-ok: the long-running bypass daemon is this ticket's deliverable; this line names or manages it
    need_manager
    local bucket repo pin_hd="" path q out live own was_active="" changed=1
    bucket=$(bucket_arg "$@") || exit $?
    repo=$REPO; q="$bucket/bypass-queue"
    m_active && was_active=1
    out=$(bash "$repo/$OPS/bypass-launchd.sh" --check --bucket "$bucket" 2>&1)
    live=$(printf '%s\n' "$out" | sed -n 's/^daemon: live pid=\([0-9][0-9]*\).*/\1/p' | head -n 1) # t13b-ok: the long-running bypass daemon is this ticket's deliverable; this line names or manages it
    if [ -n "$live" ]; then
        own=""; [ -z "$was_active" ] || own=$(unit_pid)
        if [ "$live" != "$own" ]; then
            echo "bypass-service: a daemon started by hand (pid $live) holds $bucket. Stop it with: touch $q/stop   then run: himmelctl bypass on" >&2 # t13b-ok: the long-running bypass daemon is this ticket's deliverable; this line names or manages it
            exit 1
        fi
    fi
    path=$(installed_path)
    mkdir -p "$STATE" "$(dirname "$path")" || die "cannot create the unit directory"
    render "$bucket" "$repo" >"$path.new" || { rm -f "$path.new"; exit 2; }
    if [ -f "$path" ] && cmp -s "$path" "$path.new"; then changed=""; fi
    [[ "${HANDOVER_DIR:-}" =~ $PATH_RE ]] && pin_hd=$HANDOVER_DIR
    { printf 'bucket=%s\nrepo=%s\n' "$bucket" "$repo"; [ -z "$pin_hd" ] || printf 'handover_dir=%s\n' "$pin_hd"; } >"$CONFIG.new" || { rm -f "$path.new"; die "cannot save the configuration in $STATE"; }
    if [ ! -f "$CONFIG" ] || ! cmp -s "$CONFIG" "$CONFIG.new"; then changed=1; fi
    mv "$path.new" "$path" || die "cannot install the unit"
    mv "$CONFIG.new" "$CONFIG" || die "cannot save the configuration in $STATE"
    rm -f "$q/stop"
    if darwin; then
        mkdir -p "$HOME/.himmel"
        launchctl bootout "gui/$UID_N/$LABEL" >/dev/null 2>&1
        launchctl bootstrap "gui/$UID_N" "$path" || die "launchctl bootstrap failed for $path" # t13b-ok: the long-running bypass daemon is this ticket's deliverable; this line names or manages it
        echo "bypass daemon: on ($LABEL loaded; it starts at your login)" # t13b-ok: the long-running bypass daemon is this ticket's deliverable; this line names or manages it
        return 0
    fi
    sctl daemon-reload || die "systemctl --user daemon-reload failed" # t13b-ok: the long-running bypass daemon is this ticket's deliverable; this line names or manages it
    sctl enable --now "$UNIT" || die "systemctl --user enable --now $UNIT failed" # t13b-ok: the long-running bypass daemon is this ticket's deliverable; this line names or manages it
    if [ -n "$was_active" ] && [ -n "$changed" ]; then sctl restart "$UNIT" || die "systemctl --user restart $UNIT failed"; fi
    if ! loginctl enable-linger "$(id -un)" 2>/dev/null; then
        echo "WARNING: lingering is not enabled, so the daemon starts at your next login, not at boot. Run once: loginctl enable-linger $(id -un)" # t13b-ok: the long-running bypass daemon is this ticket's deliverable; this line names or manages it
    fi
    echo "bypass daemon: on ($UNIT enabled and started)" # t13b-ok: the long-running bypass daemon is this ticket's deliverable; this line names or manages it
}

cmd_off() {
    refuse_claude "turn the bypass daemon off" # t13b-ok: the long-running bypass daemon is this ticket's deliverable; this line names or manages it
    need_manager
    local bucket
    bucket=$(conf_get bucket); [ -n "$bucket" ] || die "the bypass daemon was never turned on here (no record at $CONFIG)" # t13b-ok: the long-running bypass daemon is this ticket's deliverable; this line names or manages it
    touch "$bucket/bypass-queue/stop" || die "cannot write the stop file in $bucket/bypass-queue"
    if darwin; then launchctl bootout "gui/$UID_N/$LABEL" >/dev/null 2>&1
    else sctl disable --now "$UNIT" || die "systemctl --user disable --now $UNIT failed"; fi
    echo "bypass daemon: off (stop file written, $(if darwin; then echo "$LABEL"; else echo "$UNIT"; fi) disabled)" # t13b-ok: the long-running bypass daemon is this ticket's deliverable; this line names or manages it
}

confirm_up() {
    local repo=$1 bucket=$2 n=0 want
    while [ "$n" -lt "$CONFIRM" ]; do
        sleep 1
        m_active || { CONFIRM_WHY="the unit is not active after the restart"; return 1; }
        n=$((n + 1))
    done
    want=$(checkout_ids "$repo") || { CONFIRM_WHY="cannot read the checkout's code ids"; return 1; }
    [ "$(cat "$bucket/bypass-queue/.loaded" 2>/dev/null)" = "$want" ] || { CONFIRM_WHY="the daemon did not load the new code"; return 1; } # t13b-ok: the long-running bypass daemon is this ticket's deliverable; this line names or manages it
    return 0
}

cmd_restart() {
    refuse_claude "restart the bypass daemon" # t13b-ok: the long-running bypass daemon is this ticket's deliverable; this line names or manages it
    need_manager
    local bucket repo
    bucket=$(conf_get bucket); repo=$(conf_get repo); [ -n "$bucket" ] || die "the bypass daemon was never turned on here"; [ -n "$repo" ] || repo=$REPO # t13b-ok: the long-running bypass daemon is this ticket's deliverable; this line names or manages it
    [ ! -e "$bucket/bypass-queue/stop" ] || die "the daemon is off (a stop file is in $bucket/bypass-queue); turn it on with: himmelctl bypass on" # t13b-ok: the long-running bypass daemon is this ticket's deliverable; this line names or manages it
    m_enabled || die "the unit is not enabled; turn it on with: himmelctl bypass on"
    if darwin; then launchctl kickstart -k "gui/$UID_N/$LABEL" || die "launchctl kickstart failed"
    else sctl reset-failed "$UNIT" >/dev/null 2>&1; sctl restart "$UNIT" || die "systemctl --user restart $UNIT failed"; fi
    if confirm_up "$repo" "$bucket"; then echo "bypass daemon: restarted"; else echo "bypass daemon: restarted but $CONFIRM_WHY" >&2; exit 1; fi # t13b-ok: the long-running bypass daemon is this ticket's deliverable; this line names or manages it
}

cmd_restart_if_changed() {
    local check="" bucket repo want have
    case ${1:-} in --check) check=1 ;; "") ;; *) die "unknown argument $1" ;; esac
    bucket=$(conf_get bucket); repo=$(conf_get repo); [ -n "$repo" ] || repo=$REPO
    if [ -z "$bucket" ]; then
        echo "not-enabled: bypass daemon is off, turn it on from your shell: himmelctl bypass on"; return 0 # t13b-ok: the long-running bypass daemon is this ticket's deliverable; this line names or manages it
    fi
    need_manager
    if ! m_enabled; then
        echo "not-enabled: bypass daemon is off, turn it on from your shell: himmelctl bypass on"; return 0 # t13b-ok: the long-running bypass daemon is this ticket's deliverable; this line names or manages it
    fi
    if ! m_active; then
        echo "inactive: the unit is enabled but not running; start it from your shell: himmelctl bypass restart"; return 0
    fi
    want=$(checkout_ids "$repo") || { echo "failed: cannot read the checkout's code ids in $repo"; return 1; }
    have=$(cat "$bucket/bypass-queue/.loaded" 2>/dev/null)
    if [ "$have" = "$want" ]; then echo "current"; return 0; fi
    if [ -n "$check" ]; then echo "would restart"; return 0; fi
    if darwin; then launchctl kickstart -k "gui/$UID_N/$LABEL" >/dev/null 2>&1 || { echo "failed: launchctl kickstart did not run"; return 1; }
    else sctl try-restart "$UNIT" >/dev/null 2>&1 || { echo "failed: systemctl --user try-restart $UNIT did not run"; return 1; }; fi
    if confirm_up "$repo" "$bucket"; then echo "restarted"; return 0; fi
    echo "failed: $CONFIRM_WHY"; return 1
}

cmd_status() {
    local bucket repo path inst want have enabled=no active=no linger=no pid="" since="" unit="not installed" code="STALE" stop=no hb=none now mt rc=0
    bucket=$(conf_get bucket); repo=$(conf_get repo); [ -n "$repo" ] || repo=$REPO
    path=$(installed_path)
    m_enabled && enabled=yes
    m_active && active=yes
    if darwin; then pid=$(m_pid)
    else
        pid=$(sctl show "$UNIT" -p MainPID 2>/dev/null | sed -n 's/^MainPID=//p' | head -n 1)
        since=$(sctl show "$UNIT" -p ActiveEnterTimestamp 2>/dev/null | sed -n 's/^ActiveEnterTimestamp=//p' | head -n 1)
        [ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" = yes ] && linger=yes
    fi
    if [ -f "$path" ] && [ -n "$bucket" ]; then
        inst=$(cat "$path"; printf x); inst=${inst%x}
        if [ "$(render "$bucket" "$repo"; printf x)" = "${inst}x" ]; then unit=current; else unit="STALE (run: himmelctl bypass on)"; fi
    fi
    if [ -n "$bucket" ]; then
        [ -e "$bucket/bypass-queue/stop" ] && stop=yes
        want=$(checkout_ids "$repo" 2>/dev/null); have=$(cat "$bucket/bypass-queue/.loaded" 2>/dev/null)
        [ -n "$want" ] && [ "$have" = "$want" ] && code=current
        if [ -e "$bucket/bypass-queue/.heartbeat" ]; then
            mt=$(stat -c %Y "$bucket/bypass-queue/.heartbeat" 2>/dev/null || stat -f %m "$bucket/bypass-queue/.heartbeat" 2>/dev/null) && { now=$(date +%s); hb="$((now - mt))s ago"; }
        fi
    fi
    printf 'bucket: %s\nenabled: %s\nactive: %s\npid: %s\nsince: %s\nlinger: %s\nunit: %s\ncode: %s\nstop file: %s\nheartbeat: %s\n' \
        "${bucket:-none}" "$enabled" "$active" "${pid:-none}" "${since:-none}" "$linger" "$unit" "$code" "$stop" "$hb"
    [ "$active" = yes ] && [ "$unit" = current ] && [ "$code" = current ] || rc=1
    return "$rc"
}

cmd_render() {
    local bucket
    bucket=$(bucket_arg "$@") || exit $?
    render "$bucket" "$REPO"
}

verb=${1:-}; [ $# -eq 0 ] || shift
case $verb in on|off|restart) refuse_claude "run '$verb'" ;; esac
case $verb in
    on) cmd_on "$@" ;;
    off) [ $# -eq 0 ] || die "off takes no argument"; cmd_off ;;
    restart) [ $# -eq 0 ] || die "restart takes no argument"; cmd_restart ;;
    status) [ $# -eq 0 ] || die "status takes no argument"; cmd_status ;;
    restart-if-changed) cmd_restart_if_changed "$@" ;;
    render) cmd_render "$@" ;;
    *) die "usage: bypass-service.sh on [--bucket <dir>] | off | restart | status | restart-if-changed [--check] | render [--bucket <dir>]" ;;
esac
