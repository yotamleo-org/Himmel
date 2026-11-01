#!/bin/bash
# cron-entry v1: set or remove ONE line tagged "# HIMMEL-<tag>" in the operator's crontab.
# Run by the afk-sudo helper as root after a Telegram approval, from the root-owned copy in
# /usr/local/libexec/himmel/ops/; root writes the operator's table with `crontab -u` (a setuid crontab fails
# closed under --no-new-privs, so the operator never runs it).
#
#   cron-entry.sh [--check] --id ID --operator-user U --action set|remove --tag T [--schedule S --command C]
#
# Idempotent: the same call twice reports result=unchanged. --check reports result=would-change and writes nothing.
# Last stdout line: op=cron-entry id=ID result=changed|unchanged|would-change|bad-param|failed [name=P] detail=...
# Exit 0 ok, 3 bad-param, 1 failed.
# Test seam: HIMMEL_OPS_ROOT (a path prefix) and HIMMEL_OPS_BIN (a PATH prefix) are honoured only when euid != 0.
set -u
PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
ROOT=""
WANT_UID=0
if [ "$(id -u)" != 0 ]; then
    ROOT=${HIMMEL_OPS_ROOT:-}
    WANT_UID=$(id -u)
    [ -z "${HIMMEL_OPS_BIN:-}" ] || PATH="$HIMMEL_OPS_BIN:$PATH"
fi

id=- check=0
user='' action='' tag='' schedule='' command=''
say() { # result [name] detail
    if [ $# -eq 3 ]; then printf 'op=cron-entry id=%s result=%s name=%s detail=%s\n' "$id" "$1" "$2" "$3"
    else printf 'op=cron-entry id=%s result=%s detail=%s\n' "$id" "$1" "$2"; fi
}
bad() { say bad-param "$1" "$2"; exit 3; }
die() { say failed "$1"; exit 1; }

while [ $# -gt 0 ]; do
    if [ "$1" = --check ]; then check=1; shift; continue; fi
    [ $# -ge 2 ] || die "missing value for $1"
    case $1 in
        --id) id=$2 ;;
        --operator-user) user=$2 ;;
        --action) action=$2 ;;
        --tag) tag=$2 ;;
        --schedule) schedule=$2 ;;
        --command) command=$2 ;;
        *) die "unknown argument $1" ;;
    esac
    shift 2
done

re_tag='^[A-Za-z0-9-]{1,40}$'
re_sched='^[0-9*/,-]+( [0-9*/,-]+){4}$'
[[ $user =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "no valid operator user"
case $action in set | remove) ;; *) bad action "must be set or remove" ;; esac
[[ $tag =~ $re_tag ]] || bad tag "A-Za-z0-9- and at most 40 characters"

# ponytail: any root-owned executable in these two directories passes, not only the message-session opener
# (none is installed yet); upgrade path: pin command to the installed opener once one ships.
opener_ok() {
    local p=$1 rel owner mode
    [[ $p =~ ^/[A-Za-z0-9._/-]{1,250}$ ]] || return 1
    case "$p/" in *"/../"* | *"/./"* | *"//"*) return 1 ;; esac
    rel=${p#"$ROOT"}
    [ "$rel" != "$p" ] || [ -z "$ROOT" ] || return 1
    case $rel in /usr/local/libexec/himmel/* | /usr/local/bin/*) ;; *) return 1 ;; esac
    [ -f "$p" ] && [ -x "$p" ] || return 1
    read -r owner mode < <(stat -L -c "%u %a" "$p" 2>/dev/null) || return 1
    [ "$owner" = "$WANT_UID" ] || return 1
    [ $((8#$mode & 8#022)) -eq 0 ]
}

desired=''
if [ "$action" = set ]; then
    [[ $schedule =~ $re_sched ]] || bad schedule "five cron fields of digits and * / , -"
    opener_ok "$command" || bad command "one root-owned executable path, no arguments, under /usr/local/libexec/himmel or /usr/local/bin"
    desired="$schedule $command # HIMMEL-$tag"
else
    [ -z "$schedule$command" ] || bad "$([ -n "$schedule" ] && echo schedule || echo command)" "not allowed with remove"
fi

cur=$(crontab -u "$user" -l 2>&1)
status=$?
if [ "$status" -ne 0 ]; then
    case $cur in *"no crontab for"*) cur= ;; *) die "cannot read the crontab of $user: $cur" ;; esac
fi

orig='' new='' found=0
if [ -n "$cur" ]; then
    orig="$cur"$'\n'
    while IFS= read -r line; do
        if [[ $line == *" # HIMMEL-$tag" ]]; then
            if [ "$action" = set ] && [ $found -eq 0 ]; then new+="$desired"$'\n'; fi
            found=$((found + 1))
            continue
        fi
        new+="$line"$'\n'
    done <<< "$cur"
fi
if [ "$action" = set ] && [ $found -eq 0 ]; then new+="$desired"$'\n'; fi

if [ "$new" = "$orig" ]; then say unchanged "the crontab of $user already matches (HIMMEL-$tag $action)"; exit 0; fi
if [ "$action" = set ]; then what="will set in the crontab of $user: $desired"; else what="will remove the HIMMEL-$tag line from the crontab of $user"; fi
if [ $check -eq 1 ]; then say would-change "$what"; exit 0; fi
printf '%s' "$new" | crontab -u "$user" - || die "crontab -u $user - failed"
say changed "${what/will /}"
