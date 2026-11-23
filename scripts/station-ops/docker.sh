#!/bin/bash
# docker v1: start or stop Docker on the station for the current boot only.
# Run by the afk-sudo helper as root after a Telegram approval, from the root-owned copy in
# /usr/local/libexec/himmel/ops/.
#
#   docker.sh [--check] --id ID --operator-user U --action start|stop
#
# Acts on three fixed units and nothing else: containerd.service, docker.socket, docker.service. Start order is
# containerd, socket, service; stop order is the reverse (service first, so the socket cannot start it again). It runs
# only `systemctl start`, `stop` and `is-active`: it never enables or disables a unit, so a Docker that is off at boot
# stays off at boot and the operator's boot configuration is untouched.
# Idempotent: with every unit already in the target state the run reports result=unchanged. --check reports
# result=would-change naming the units it would start or stop, and changes nothing.
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
    stop) units="docker.service docker.socket containerd.service"; want=inactive ;;
    *) bad action "must be start or stop" ;;
esac

todo=''
for u in $units; do
    if systemctl is-active --quiet "$u" 2>/dev/null; then now=active; else now=inactive; fi
    [ "$now" = "$want" ] || todo="$todo $u"
done
todo=${todo# }

if [ -z "$todo" ]; then say unchanged "docker units are already $want ($units)"; exit 0; fi
if [ $check -eq 1 ]; then say would-change "will $action: $todo"; exit 0; fi

for u in $todo; do
    err=$(systemctl "$action" "$u" 2>&1) || die "systemctl $action $u failed: $(printf '%s' "${err%%$'\n'*}" | cut -c1-120)"
done
[ "$action" = start ] && past=started || past=stopped
say changed "$past: $todo; not enabled or disabled at boot, lasts until the next reboot"
