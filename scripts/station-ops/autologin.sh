#!/bin/bash
# autologin v2: turn the display manager's automatic login for the operator user on or off.
# Run by the afk-sudo helper as root after a Telegram approval, from the root-owned copy in
# /usr/local/libexec/himmel/ops/.
#
#   autologin.sh [--check] --id ID --operator-user U --action enable|disable [--session S]
#
# enable needs --session S, a desktop session installed as /usr/share/{xsessions,wayland-sessions}/S.desktop
# (LightDM's own default is a distro session that may not be installed, and then it shows the greeter); disable
# takes none. GDM starts the user's own default session and ignores S.
#
# The display manager is the one /etc/systemd/system/display-manager.service points at. SDDM gets
# /etc/sddm.conf.d/himmel-autologin.conf, LightDM /etc/lightdm/lightdm.conf.d/50-himmel-autologin.conf (both
# files of our own, removed on disable); GDM's /etc/gdm3/custom.conf (or /etc/gdm/custom.conf) has its two
# [daemon] keys set or removed and nothing else touched. Any other display manager, or none, is refused.
# Idempotent: the same call twice reports result=unchanged. --check reports result=would-change, writes nothing.
# The detail always ends with keyring=<state>: an automatic login never types the login password, so a login
# keyring that exists stays locked until something asks for it (keyring=present-locked-at-autologin), else
# keyring=none.
# Last stdout line: op=autologin id=ID result=changed|unchanged|would-change|bad-param|failed [name=P] detail=...
# Exit 0 ok, 3 bad-param, 1 failed.
# Test seam: HIMMEL_OPS_ROOT (a path prefix) and HIMMEL_OPS_BIN (a PATH prefix) are honoured only when euid != 0.
set -u
PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
ROOT=""
if [ "$(id -u)" != 0 ]; then
    ROOT=${HIMMEL_OPS_ROOT:-}
    [ -z "${HIMMEL_OPS_BIN:-}" ] || PATH="$HIMMEL_OPS_BIN:$PATH"
fi

id=- check=0 user='' action='' session=''
say() { # result [name] detail
    if [ $# -eq 3 ]; then printf 'op=autologin id=%s result=%s name=%s detail=%s\n' "$id" "$1" "$2" "$3"
    else printf 'op=autologin id=%s result=%s detail=%s\n' "$id" "$1" "$2"; fi
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
        --session) session=$2 ;;
        *) die "unknown argument $1" ;;
    esac
    shift 2
done

[[ $id =~ ^[A-Za-z0-9-]{1,40}$ ]] || id=-
[[ $user =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "no valid operator user"
case $action in enable | disable) ;; *) bad action "must be enable or disable" ;; esac
if [ "$action" = enable ]; then
    [[ $session =~ ^[A-Za-z0-9._-]{1,60}$ ]] || bad session "enable needs the name of an installed desktop session"
    case $session in .* | *..*) bad session "no dots at the start or in a row" ;; esac
    [ -f "$ROOT/usr/share/xsessions/$session.desktop" ] || [ -f "$ROOT/usr/share/wayland-sessions/$session.desktop" ] \
        || bad session "no installed session $session (/usr/share/xsessions or wayland-sessions)"
else
    [ -z "$session" ] || bad session "not allowed with disable"
fi
home=$(getent passwd "$user" | cut -d: -f6)
[ -n "$home" ] || die "no such user $user"

keyring=none
[ -e "$ROOT$home/.local/share/keyrings/login.keyring" ] && keyring=present-locked-at-autologin

link=$(readlink "$ROOT/etc/systemd/system/display-manager.service") || die "no display manager is enabled (no /etc/systemd/system/display-manager.service)"
dm=$(basename "$link" .service)
case $dm in
    sddm) kind=sddm; file="$ROOT/etc/sddm.conf.d/himmel-autologin.conf"
        want="[Autologin]
User=$user
Session=$session.desktop" ;;
    lightdm) kind=lightdm; file="$ROOT/etc/lightdm/lightdm.conf.d/50-himmel-autologin.conf"
        want="[Seat:*]
autologin-user=$user
autologin-session=$session" ;;
    gdm | gdm3) kind=gdm
        file="$ROOT/etc/gdm3/custom.conf"
        [ -e "$ROOT/etc/gdm/custom.conf" ] && [ ! -e "$file" ] && file="$ROOT/etc/gdm/custom.conf" ;;
    *) die "unsupported display manager '$dm': only SDDM, GDM and LightDM (keyring=$keyring)" ;;
esac

write_file() { # path content: replace atomically, mode 0644, root-owned
    local dir tmp
    dir=$(dirname "$1")
    mkdir -p "$dir" || return 1
    tmp=$(mktemp "$dir/.himmel-autologin.XXXXXX") || return 1
    # prim-ok: self-contained root-owned op, sources no libs
    if printf '%s\n' "$2" > "$tmp" && chmod 0644 "$tmp" && mv "$tmp" "$1"; then return 0; fi
    rm -f "$tmp"
    return 1
}

old='' new=''
if [ "$kind" = gdm ]; then
    [ ! -e "$file" ] || old=$(cat "$file") || die "cannot read $file"
    new=$(printf '%s\n' "$old" | awk -v enable="$([ "$action" = enable ] && echo 1 || echo 0)" -v user="$user" '
        function emit() { if (enable == 1) { print "AutomaticLoginEnable=True"; print "AutomaticLogin=" user } }
        /^[ \t]*\[/ { in_daemon = ($0 ~ /^[ \t]*\[daemon\][ \t]*$/) }
        in_daemon && /^[ \t]*(AutomaticLoginEnable|AutomaticLogin)[ \t]*=/ { next }
        { print }
        /^[ \t]*\[daemon\][ \t]*$/ { seen = 1; emit() }
        END { if (!seen && enable == 1) { print "[daemon]"; emit() } }')
    new=${new#$'\n'}
    same=0; [ "$new" = "$old" ] && same=1
else
    [ ! -e "$file" ] || old=$(cat "$file") || die "cannot read $file"
    if [ "$action" = enable ]; then same=0; [ -e "$file" ] && [ "$old" = "$want" ] && same=1
    else same=0; [ -e "$file" ] || same=1; fi
    new=$want
fi

# Other files may configure auto-login too (our drop-in is not the only place); report them, never edit them.
auto_in() { # file section key: succeeds when the file sets key to a non-empty value (in [section] when one is given)
    awk -v sec="$2" -v key="$3" '
        BEGIN { in_s = (sec == "") }
        /^[ \t]*\[/ { in_s = (sec == "" || index($0, "[" sec "]") > 0); next }
        in_s && $0 ~ ("^[ \t]*" key "[ \t]*=[ \t]*[^ \t]") { found = 1 }
        END { exit(found ? 0 : 1) }' "$1" 2>/dev/null
}
others=''
case $kind in
    sddm) for f in "$ROOT/etc/sddm.conf" "$ROOT"/etc/sddm.conf.d/*.conf; do
            [ -f "$f" ] && [ "$f" != "$file" ] && auto_in "$f" Autologin User && others="$others $f"
        done ;;
    lightdm) for f in "$ROOT/etc/lightdm/lightdm.conf" "$ROOT"/etc/lightdm/lightdm.conf.d/*.conf; do
            [ -f "$f" ] && [ "$f" != "$file" ] && auto_in "$f" '' autologin-user && others="$others $f"
        done ;;
esac
others=${others# }
keyring="$keyring; other-autologin=${others:-none}"

where="$dm via $file"
if [ $same -eq 1 ]; then
    say unchanged "auto-login for $user is already ${action}d in $where; keyring=$keyring"
    exit 0
fi
if [ $check -eq 1 ]; then say would-change "will $action auto-login for $user in $where; keyring=$keyring"; exit 0; fi
if [ "$kind" = gdm ]; then
    write_file "$file" "$new" || die "cannot write $file"
elif [ "$action" = enable ]; then
    write_file "$file" "$new" || die "cannot write $file"
else
    rm -f "$file" || die "cannot remove $file"
fi
say changed "${action}d auto-login for $user in $where; takes effect at the next boot or display manager restart; keyring=$keyring"
