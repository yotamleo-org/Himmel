#!/bin/bash
#
#   docker.sh [--check] --id ID --operator-user U --action start|stop
#
# Stop takes docker.socket first: systemd socket activation would otherwise restart docker.service while it stops.
# Last stdout line: op=docker id=ID result=changed|unchanged|would-change|bad-param|failed [name=action] detail=...
# Exit 0 ok, 3 bad-param, 1 failed.
# Test seam: HIMMEL_OPS_ROOT (a path prefix) and HIMMEL_OPS_BIN (a PATH prefix) are honoured only when euid != 0.
set -u
PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
if [ "$(id -u)" != 0 ]; then
    [ -z "${HIMMEL_OPS_BIN:-}" ] || PATH="$HIMMEL_OPS_BIN:$PATH"
fi

id=- check=0 action=''
say() {
    if [ $# -eq 3 ]; then printf 'op=docker id=%s result=%s name=%s detail=%s\n' "$id" "$1" "$2" "$3"
    else printf 'op=docker id=%s result=%s detail=%s\n' "$id" "$1" "$2"; fi
}
bad() { say bad-param "$1" "$2"; exit 3; }
die() { say failed "$1"; exit 1; }

while [ $# -gt 0 ]; do
    if [ "$1" = --check ]; then check=1; shift; continue; fi
    [ $# -ge 2 ] || die "missing value for $1"
    case $1 in
        --id) id=$2 ;;
        --operator-user) ;;
        --action) action=$2 ;;
        *) die "unknown argument $1" ;;
    esac
    shift 2
done

[[ $id =~ ^[A-Za-z0-9-]{1,40}$ ]] || id=-
case $action in
    start) units="containerd.service docker.socket docker.service"; want=active ;;
    stop) units="docker.socket docker.service containerd.service"; want=inactive ;;
    *) bad action "must be start or stop" ;;
esac

state_of() {
    local s
    s=$(systemctl is-active "$1" 2>/dev/null)
    case $s in
        active) now=active ;;
        inactive | failed) now=inactive ;;
        *) die "cannot read the state of $1: ${s:-no answer from systemctl}" ;;
    esac
}

todo=''
for u in $units; do
    state_of "$u"
    [ "$now" = "$want" ] || todo="$todo $u"
done
todo=${todo# }

if [ -z "$todo" ]; then say unchanged "docker units are already $want ($units)"; exit 0; fi
if [ $check -eq 1 ]; then say would-change "will $action: $todo"; exit 0; fi

for u in $todo; do
    err=$(systemctl "$action" "$u" 2>&1) || die "systemctl $action $u failed: $(printf '%s' "${err%%$'\n'*}" | cut -c1-120)"
done
for u in $units; do
    state_of "$u"
    [ "$now" = "$want" ] || die "$u is $now after the $action, not $want"
done
[ "$action" = start ] && past=started || past=stopped
say changed "$past: $todo; not enabled or disabled at boot, lasts until the next reboot"
