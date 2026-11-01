#!/bin/bash
# system-update v1: upgrade every installed package.
# Run by the afk-sudo helper as root after a Telegram approval, from the root-owned copy in
# /usr/local/libexec/himmel/ops/. Arch/CachyOS: pacman -Syu --noconfirm. Debian/Ubuntu (the test VM): apt-get update
# and upgrade. The full log goes to /var/log/himmel/ops/<id>.log (root, 0640), never to Telegram.
#
#   system-update.sh [--check] --id ID
#
# Idempotent: with nothing to upgrade the run reports result=unchanged. --check lists what the LAST package-index sync
# says would upgrade (it syncs nothing) as result=would-change. A changed run reports upgraded=<n> and
# reboot_recommended=yes|no (a kernel, systemd, glibc or GPU-driver package changed, or /var/run/reboot-required exists).
# A package manager that holds its lock fails the run; the manager's own refusal is reported, nothing is forced.
# Last stdout line: op=system-update id=ID result=changed|unchanged|would-change|failed detail=...
# Exit 0 ok, 1 failed.
# Test seam: HIMMEL_OPS_ROOT (a path prefix) and HIMMEL_OPS_BIN (a PATH prefix) are honoured only when euid != 0.
set -u
PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
ROOT=""
if [ "$(id -u)" != 0 ]; then
    ROOT=${HIMMEL_OPS_ROOT:-}
    [ -z "${HIMMEL_OPS_BIN:-}" ] || PATH="$HIMMEL_OPS_BIN:$PATH"
fi
umask 027

id=- check=0
say() { printf 'op=system-update id=%s result=%s detail=%s\n' "$id" "$1" "$2"; }
die() { say failed "$1"; exit 1; }
while [ $# -gt 0 ]; do
    if [ "$1" = --check ]; then check=1; shift; continue; fi
    [ $# -ge 2 ] || die "missing value for $1"
    case $1 in
        --id) id=$2 ;;
        --operator-user) ;;
        *) die "unknown argument $1" ;;
    esac
    shift 2
done
[[ $id =~ ^[A-Za-z0-9-]{1,40}$ ]] || die "no valid request id"

osid='' like=''
if [ -r "$ROOT/etc/os-release" ]; then
    while IFS='=' read -r k v; do
        v=${v//\"/}
        case $k in ID) osid=$v ;; ID_LIKE) like=$v ;; esac
    done < "$ROOT/etc/os-release"
fi
case " $osid $like " in
    *" arch "*) family=arch ;;
    *" debian "* | *" ubuntu "*) family=debian ;;
    *) die "unsupported distribution ${osid:-unknown}: only Arch and Debian families" ;;
esac

reboot_re='^(linux|linux-image|linux-modules|linux-cachyos|systemd|libc6|glibc|nvidia|nvidia-utils|nvidia-dkms|nvidia-open|mesa)[-a-z0-9.]*$'
reboot_for() { # package names on stdin; yes if a reboot-class package is among them
    local n r=no
    while read -r n; do [[ $n =~ $reboot_re ]] && r=yes; done
    echo "$r"
}

if [ $check -eq 1 ]; then
    if [ "$family" = debian ]; then
        sim=$(apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null) || die "apt-get could not simulate the upgrade"
        names=$(printf '%s\n' "$sim" | sed -n 's/^Inst \([^ ]*\) .*/\1/p')
    else
        names=$(pacman -Qu 2>/dev/null | awk '{print $1}')
    fi
    n=$(printf '%s' "$names" | grep -c .)
    if [ "$n" -eq 0 ]; then say unchanged "nothing to upgrade by the last index sync"; exit 0; fi
    say would-change "will upgrade $n packages by the last index sync; reboot_recommended=$(printf '%s\n' "$names" | reboot_for)"
    exit 0
fi

logdir="$ROOT/var/log/himmel/ops"
mkdir -p "$logdir" || die "cannot create $logdir"
chmod 0750 "$logdir" || die "cannot protect $logdir"
log="$logdir/$id.log"
printf 'system-update %s family=%s start=%s\n' "$id" "$family" "$(date -u +%FT%TZ)" > "$log" || die "cannot create $log"

if [ "$family" = debian ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update >> "$log" 2>&1 || die "apt-get update failed, see $log"
    sim=$(apt-get -s -o Debug::NoLocking=1 upgrade 2>>"$log") || die "apt-get could not simulate the upgrade, see $log"
    names=$(printf '%s\n' "$sim" | sed -n 's/^Inst \([^ ]*\) .*/\1/p')
    n=$(printf '%s' "$names" | grep -c .)
    if [ "$n" -eq 0 ]; then say unchanged "nothing to upgrade"; exit 0; fi
    apt-get -y upgrade >> "$log" 2>&1 || die "apt-get upgrade failed, see $log"
    rr=$(printf '%s\n' "$names" | reboot_for)
    [ -e "$ROOT/var/run/reboot-required" ] && rr=yes
else
    if [ -e "$ROOT/var/lib/pacman/db.lck" ]; then die "pacman holds its lock ($ROOT/var/lib/pacman/db.lck)"; fi
    pacman -Syu --noconfirm >> "$log" 2>&1 || die "pacman -Syu failed, see $log"
    if grep -q "there is nothing to do" "$log"; then say unchanged "nothing to upgrade"; exit 0; fi
    names=$(sed -n 's/^Packages ([0-9]*) //p' "$log" | tr ' ' '\n' | sed 's/-[0-9][^-]*-[0-9][^-]*$//' | grep .)
    n=$(printf '%s\n' "$names" | grep -c .)
    rr=$(printf '%s\n' "$names" | reboot_for)
fi
say changed "upgraded=$n reboot_recommended=$rr log=$log"
