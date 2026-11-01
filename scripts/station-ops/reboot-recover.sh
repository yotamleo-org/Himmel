#!/bin/bash
# reboot-recover v1: arm or disarm the recovery that runs at the operator's next login after a reboot.
# Run by the afk-sudo helper as root after a Telegram approval, from the root-owned copy in
# /usr/local/libexec/himmel/ops/.
#
#   reboot-recover.sh [--check] --id ID --operator-user U --action arm|disarm [--doc DOC --repo REPO]
#
# arm: writes the root-owned marker /var/lib/himmel/reboot-recover.json ({user, doc, repo, armed_at}; the operator can
# read it but not write it) and the user unit /etc/systemd/user/himmel-recover.service, enabled for every user session
# through default.target.wants. The unit has ConditionPathExists on the marker and ConditionUser on the operator, so
# without the marker, or for any other user, it does not start. It runs <repo>/scripts/station-ops/recover.sh as the user, which acts once per arming. disarm: removes the
# marker (the unit stays; with no marker it does nothing).
# Idempotent: arming the same user, doc and repo again keeps the marker and reports result=unchanged.
# Last stdout line: op=reboot-recover id=ID result=changed|unchanged|would-change|bad-param|failed [name=P] detail=...
# Exit 0 ok, 3 bad-param, 1 failed.
# Test seam: HIMMEL_OPS_ROOT (a path prefix) and HIMMEL_OPS_BIN (a PATH prefix) are honoured only when euid != 0.
set -u
PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
ROOT=""
if [ "$(id -u)" != 0 ]; then
    ROOT=${HIMMEL_OPS_ROOT:-}
    [ -z "${HIMMEL_OPS_BIN:-}" ] || PATH="$HIMMEL_OPS_BIN:$PATH"
fi

id=- check=0 user='' action='' doc='' repo=''
say() { # result [name] detail
    if [ $# -eq 3 ]; then printf 'op=reboot-recover id=%s result=%s name=%s detail=%s\n' "$id" "$1" "$2" "$3"
    else printf 'op=reboot-recover id=%s result=%s detail=%s\n' "$id" "$1" "$2"; fi
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
        --doc) doc=$2 ;;
        --repo) repo=$2 ;;
        *) die "unknown argument $1" ;;
    esac
    shift 2
done

[[ $id =~ ^[A-Za-z0-9-]{1,40}$ ]] || id=-
[[ $user =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "no valid operator user"
case $action in arm | disarm) ;; *) bad action "must be arm or disarm" ;; esac

marker="$ROOT/var/lib/himmel/reboot-recover.json"
unit="$ROOT/etc/systemd/user/himmel-recover.service"
wants="$ROOT/etc/systemd/user/default.target.wants/himmel-recover.service"

if [ "$action" = disarm ]; then
    [ -z "$doc$repo" ] || bad "$([ -n "$doc" ] && echo doc || echo repo)" "not allowed with disarm"
    if [ ! -e "$marker" ]; then say unchanged "no marker, nothing is armed"; exit 0; fi
    if [ $check -eq 1 ]; then say would-change "will remove the marker $marker"; exit 0; fi
    rm -f "$marker" || die "cannot remove $marker"
    say changed "removed the marker $marker; a login now does nothing"
    exit 0
fi

[[ $doc =~ ^/[A-Za-z0-9._/-]{1,300}\.md$ ]] || bad doc "an absolute path to a .md handover doc"
[[ $repo =~ ^/[A-Za-z0-9._/-]{1,250}$ ]] || bad repo "an absolute path"
case "$doc" in *"/../"* | *"/./"* | *"//"*) bad doc "no .. . or // segments" ;; esac
case "$repo/" in *"/../"* | *"/./"* | *"//"*) bad repo "no .. . or // segments" ;; esac
[ -f "$repo/scripts/station-ops/recover.sh" ] || bad repo "no scripts/station-ops/recover.sh under it"
[ -f "$doc" ] || bad doc "no such file"

want_unit="[Unit]
Description=himmel reboot recovery (acts only when root armed a marker)
ConditionPathExists=/var/lib/himmel/reboot-recover.json
ConditionUser=$user
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/bash $repo/scripts/station-ops/recover.sh

[Install]
WantedBy=default.target"
want_marker_head="{\"v\": 1, \"user\": \"$user\", \"doc\": \"$doc\", \"repo\": \"$repo\""

same_marker=0
if [ -f "$marker" ] && [ "$(sed 's/, "armed_at": [0-9]*}$//' "$marker")" = "$want_marker_head" ]; then same_marker=1; fi
same_unit=0
{ [ -f "$unit" ] && [ "$(cat "$unit")" = "$want_unit" ]; } && same_unit=1
same_wants=0
{ [ -L "$wants" ] && [ "$(readlink "$wants")" = "../himmel-recover.service" ]; } && same_wants=1

if [ $same_marker -eq 1 ] && [ $same_unit -eq 1 ] && [ $same_wants -eq 1 ]; then
    say unchanged "already armed for $user: $marker, $unit"
    exit 0
fi
if [ $check -eq 1 ]; then say would-change "will arm reboot recovery for $user from $doc (marker $marker, unit $unit)"; exit 0; fi

install -d -m 0755 "$ROOT/var/lib/himmel" "$(dirname "$unit")" "$(dirname "$wants")" || die "cannot create the directories"
if [ $same_unit -eq 0 ]; then
    tmp=$(mktemp "$(dirname "$unit")/.himmel-recover.XXXXXX") || die "cannot create a temporary unit"
    # prim-ok: self-contained root-owned op, sources no libs
    if ! { printf '%s\n' "$want_unit" > "$tmp" && chmod 0644 "$tmp" && mv "$tmp" "$unit"; }; then rm -f "$tmp"; die "cannot write $unit"; fi
fi
if [ $same_wants -eq 0 ]; then
    ln -sfn ../himmel-recover.service "$wants" || die "cannot enable $unit"
fi
if [ $same_marker -eq 0 ]; then
    tmp=$(mktemp "$ROOT/var/lib/himmel/.reboot-recover.XXXXXX") || die "cannot create a temporary marker"
    # prim-ok: self-contained root-owned op, sources no libs
    if ! { printf '%s, "armed_at": %s}\n' "$want_marker_head" "$(date +%s)" > "$tmp" && chmod 0644 "$tmp" && mv "$tmp" "$marker"; }; then rm -f "$tmp"; die "cannot write $marker"; fi
fi
say changed "armed reboot recovery for $user from $doc: marker $marker, unit $unit enabled"
