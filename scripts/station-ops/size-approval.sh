#!/bin/bash
# size-approval v1: record that the operator keeps one oversized brief whole, for 7 days.
# Run by the afk-sudo helper as root after the operator's NONCE CODE, from the root-owned copy in
# /usr/local/libexec/himmel/ops/. It writes /var/lib/himmel/size-approvals/<key>.<label>.<files>.<scope>
# (root, 0644, in a root 0755 directory): one tab-separated line
#   SIZE-APPROVAL <expires> <key> <label> <files> <scope> <id> <reason>
# which scripts/handover/chief-kit/size-override.sh check reads for a trust-path brief of 21 to 300 files.
#
#   size-approval.sh [--check] --id ID --operator-user U --key K --label L --files N --scope HEX --reason WORD
#
# Every run writes a fresh <expires> (the run's epoch plus TTL_S) and reports result=changed: a re-approval renews.
# --check validates and reports result=would-change before any filesystem call.
# Last stdout line: op=size-approval id=ID result=changed|would-change|bad-param|failed [name=P] detail=...
# Exit 0 ok, 3 bad-param, 1 failed.
# Test seam: HIMMEL_OPS_ROOT (a path prefix) and HIMMEL_OPS_BIN (a PATH prefix) are honoured only when euid != 0.
set -u
PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
ROOT=""
if [ "$(id -u)" != 0 ]; then
    ROOT=${HIMMEL_OPS_ROOT:-}
    [ -z "${HIMMEL_OPS_BIN:-}" ] || PATH="$HIMMEL_OPS_BIN:$PATH"
fi
TTL_S=604800
DIR="$ROOT/var/lib/himmel/size-approvals"

id=- check=0
key='' label='' files='' scope='' reason=''
say() { # result [name] detail
    if [ $# -eq 3 ]; then printf 'op=size-approval id=%s result=%s name=%s detail=%s\n' "$id" "$1" "$2" "$3"
    else printf 'op=size-approval id=%s result=%s detail=%s\n' "$id" "$1" "$2"; fi
}
bad() { say bad-param "$1" "$2"; exit 3; }
die() { say failed "$1"; exit 1; }

while [ $# -gt 0 ]; do
    if [ "$1" = --check ]; then check=1; shift; continue; fi
    [ $# -ge 2 ] || die "missing value for $1"
    case $1 in
        --id) id=$2 ;;
        --operator-user) ;;
        --key) key=$2 ;;
        --label) label=$2 ;;
        --files) files=$2 ;;
        --scope) scope=$2 ;;
        --reason) reason=$2 ;;
        *) die "unknown argument $1" ;;
    esac
    shift 2
done

[[ $id =~ ^[A-Za-z0-9-]{1,32}$ ]] || die "no valid request id"
[[ $key =~ ^[A-Z][A-Z0-9]{0,9}-[0-9]{1,7}$ ]] || bad key "a Jira key like PROJ-1"
[[ $label =~ ^[A-Za-z0-9._-]{1,40}$ ]] || bad label "A-Za-z0-9._- and at most 40 characters"
[[ $files =~ ^[0-9]{1,3}$ ]] || bad files "a number of 1 to 3 digits"
[[ $scope =~ ^[0-9a-f]{32}$ ]] || bad scope "32 lowercase hex digits"
[[ $reason =~ ^[A-Za-z0-9,.:_-]{3,80}$ ]] || bad reason "one word of 3 to 80 characters from A-Za-z0-9,.:_-"

what="approve $key $label: $files files, scope $scope, for 7 days from the run; reason $reason"
if [ $check -eq 1 ]; then say would-change "will $what"; exit 0; fi

now=$(date +%s) || die "cannot read the clock"
[[ $now =~ ^[0-9]{1,12}$ ]] || die "the clock read '$now'"
expires=$((now + TTL_S))
install -d -m 0755 "$DIR" || die "cannot create $DIR"
tmpf=$(mktemp "$DIR/.size-approval.XXXXXX") || die "cannot create a temp file in $DIR"
if ! printf 'SIZE-APPROVAL\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$expires" "$key" "$label" "$files" "$scope" "$id" "$reason" > "$tmpf" \
        || ! chmod 0644 "$tmpf" \
        || ! mv -f "$tmpf" "$DIR/$key.$label.$files.$scope"; then  # prim-ok: self-contained root-owned op, sources no libs; the rename is the atomic write
    rm -f "$tmpf"
    die "cannot write $DIR/$key.$label.$files.$scope"
fi
say changed "approved $key $label: $files files, scope $scope, until epoch $expires; reason $reason"
