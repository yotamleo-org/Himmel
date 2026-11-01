#!/bin/bash
# cron-system v1: set or remove /etc/cron.d/himmel-<tag>, a system cron job.
# Run by the afk-sudo helper as root after a Telegram approval, from the root-owned copy in
# /usr/local/libexec/himmel/ops/. PERSISTENT: the job keeps running on its schedule as the named user. Prefer cron-entry.
#
#   cron-system.sh [--check] --id ID --action set|remove --tag T [--schedule S --user U --command C]
#
# Root jobs only (a job for the operator user goes through cron-entry). The command is one absolute path with no
# arguments under /usr/bin or /usr/sbin, reached through no symlink, an executable that root owns and that neither it
# nor any directory above it lets group or other write (the never-remote floor refuses a parameter that names
# /usr/local/libexec/himmel, so that directory is not offered).
# Idempotent: the same call twice reports result=unchanged. --check reports result=would-change and writes nothing.
# Last stdout line: op=cron-system id=ID result=changed|unchanged|would-change|bad-param|failed [name=P] detail=...
# Exit 0 ok, 3 bad-param, 1 failed.
# Test seam: HIMMEL_OPS_ROOT (a path prefix) is honoured only when euid != 0.
set -u
PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
ROOT=""
WANT_UID=0
if [ "$(id -u)" != 0 ]; then ROOT=${HIMMEL_OPS_ROOT:-}; WANT_UID=$(id -u); fi

id=- check=0
action='' tag='' schedule='' cuser='' command=''
say() {
    if [ $# -eq 3 ]; then printf 'op=cron-system id=%s result=%s name=%s detail=%s\n' "$id" "$1" "$2" "$3"
    else printf 'op=cron-system id=%s result=%s detail=%s\n' "$id" "$1" "$2"; fi
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
        --tag) tag=$2 ;;
        --schedule) schedule=$2 ;;
        --user) cuser=$2 ;;
        --command) command=$2 ;;
        *) die "unknown argument $1" ;;
    esac
    shift 2
done

re_tag='^[A-Za-z0-9-]{1,40}$'
re_sched='^[0-9*/,-]+( [0-9*/,-]+){4}$'
re_user='^[a-z_][a-z0-9_-]{0,31}$'
re_cmd='^/[A-Za-z0-9._/-]{1,250}$'

# One executable, no arguments, that only root can change: the path has no symlink in it (so the cron.d line is
# exactly what was checked), and the file and every directory above it are root-owned and neither group- nor
# other-writable, so an approved job cannot be turned into a different one afterwards.
exec_ok() {
    local p=$1 real d top=${ROOT:-/}
    [ -f "$p" ] && [ -x "$p" ] || return 1
    real=$(readlink -f -- "$p") || return 1 # prim-ok: self-contained root-owned op, sources no libs # gnu-ok: Linux only
    [ "$real" = "$p" ] || return 1
    d=$p
    while :; do
        own_ok "$d" || return 1
        [ "$d" = "$top" ] && break
        d=$(dirname -- "$d")
        [ "$d" = / ] && { own_ok / || return 1; break; }
    done
}
own_ok() {
    local owner mode
    read -r owner mode < <(stat -c "%u %a" "$1" 2>/dev/null) || return 1 # gnu-ok: Linux only
    [ "$owner" = "$WANT_UID" ] && [ $((8#$mode & 8#022)) -eq 0 ]
}
case $action in set | remove) ;; *) bad action "must be set or remove" ;; esac
[[ $tag =~ $re_tag ]] || bad tag "A-Za-z0-9- and at most 40 characters"
file="$ROOT/etc/cron.d/himmel-$tag"

desired=''
if [ "$action" = set ]; then
    [[ $schedule =~ $re_sched ]] || bad schedule "five cron fields of digits and * / , -"
    [[ $cuser =~ $re_user ]] || bad user "a login name"
    [ "$cuser" = root ] || bad user "root only; use cron-entry for the operator user"
    [[ $command =~ $re_cmd ]] || bad command "one absolute path, no arguments"
    path=$command
    case "$path/" in *"/../"* | *"/./"* | *"//"*) bad command "no . or .. segments" ;; esac
    exec_ok "$path" || bad command "one executable that root owns, reached through no symlink, with no group or other write on it or any directory above it"
    if [ "$cuser" = root ]; then
        rel=${path#"$ROOT"}
        # ponytail: root jobs get only /usr/bin and /usr/sbin, because the never-remote floor refuses a parameter naming
        # /usr/local/libexec/himmel; upgrade path: offer that directory once the floor exempts an op's own parameters.
        { [ "$rel" != "$path" ] || [ -z "$ROOT" ]; } || bad command "root jobs run only a command under /usr/bin or /usr/sbin"
        case $rel in /usr/bin/* | /usr/sbin/*) ;; *) bad command "root jobs run only a command under /usr/bin or /usr/sbin" ;; esac
    fi
    desired="# HIMMEL-$tag managed by himmel station-ops cron-system"$'\n'"$schedule $cuser $command"$'\n'
else
    if [ -n "$schedule" ]; then bad schedule "not allowed with remove"; fi
    if [ -n "$cuser" ]; then bad user "not allowed with remove"; fi
    if [ -n "$command" ]; then bad command "not allowed with remove"; fi
fi

if [ "$action" = set ]; then
    have=
    [ -f "$file" ] && have=$(cat "$file"; printf x) && have=${have%x}
    if [ "$have" = "$desired" ]; then say unchanged "$file already holds the line"; exit 0; fi
    if [ $check -eq 1 ]; then say would-change "will write $file: $schedule $cuser $command"; exit 0; fi
    mkdir -p "$ROOT/etc/cron.d" || die "cannot create /etc/cron.d"
    tmp="$ROOT/etc/cron.d/.himmel-$tag.$$"
    # prim-ok: installed standalone as root, so prim.sh is not there; same-directory temp then rename, and cron skips dot-files
    if ! { printf '%s' "$desired" > "$tmp" && chmod 0644 "$tmp" && mv -f "$tmp" "$file"; }; then rm -f "$tmp"; die "cannot write $file"; fi
    say changed "wrote $file: $schedule $cuser $command"
else
    if [ ! -e "$file" ]; then say unchanged "$file does not exist"; exit 0; fi
    if [ $check -eq 1 ]; then say would-change "will remove $file"; exit 0; fi
    rm -f "$file" || die "cannot remove $file"
    say changed "removed $file"
fi
