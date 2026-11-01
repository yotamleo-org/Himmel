#!/bin/bash
# chief-restart v1: stop the operator's running chief session and re-arm it from its handover doc.
# Run by the afk-sudo helper as the OPERATOR USER (never root) after a Telegram approval, from the root-owned copy in
# /usr/local/libexec/himmel/ops/.
#
#   chief-restart.sh [--check] --id ID --operator-user U --session S --chief NAME --doc DOC --repo REPO
#
# A chief cannot restart itself: when --session equals --chief the op fails with "self-restart" and touches nothing
# (the helper refuses it first; this is the second guard). The running chief is the process of this user named claude whose argv
# holds -n NAME or --name NAME; it gets SIGTERM, and SIGKILL after 15 s. Its queue lock is then stale (owner dead), so
# the re-armed session takes it over when it acquires the lock. The re-arm is
# `bash REPO/scripts/handover/arm-resume.sh --handover DOC --force --time <now+2 min>`.
# Not idempotent by nature (a restart acts every time); --check reports result=would-change and acts on nothing.
# Last stdout line: op=chief-restart id=ID result=changed|would-change|bad-param|failed [name=P] detail=...
# Exit 0 ok, 3 bad-param, 1 failed.
# Test seam: HIMMEL_OPS_REARM_CMD (a program called as `CMD DOC REPO` instead of arm-resume.sh) is honoured only when
# HIMMEL_OPS_ROOT is set, which the helper passes to an op only under its own test seam.
set -u
PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

id=- check=0 user='' session='' chief='' doc='' repo=''
say() { # result [name] detail
    if [ $# -eq 3 ]; then printf 'op=chief-restart id=%s result=%s name=%s detail=%s\n' "$id" "$1" "$2" "$3"
    else printf 'op=chief-restart id=%s result=%s detail=%s\n' "$id" "$1" "$2"; fi
}
bad() { say bad-param "$1" "$2"; exit 3; }
die() { say failed "$1"; exit 1; }

while [ $# -gt 0 ]; do
    if [ "$1" = --check ]; then check=1; shift; continue; fi
    [ $# -ge 2 ] || die "missing value for $1"
    case $1 in
        --id) id=$2 ;;
        --operator-user) user=$2 ;;
        --session) session=$2 ;;
        --chief) chief=$2 ;;
        --doc) doc=$2 ;;
        --repo) repo=$2 ;;
        *) die "unknown argument $1" ;;
    esac
    shift 2
done

[[ $id =~ ^[A-Za-z0-9-]{1,40}$ ]] || id=-
[[ $user =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "no valid operator user"
[ "$(id -un)" = "$user" ] || die "must run as the operator user $user, not $(id -un)"
[[ $chief =~ ^[A-Za-z0-9][A-Za-z0-9._-]{2,119}$ ]] || bad chief "a session name"
[[ $doc =~ ^/[A-Za-z0-9._/-]{1,300}\.md$ ]] || bad doc "an absolute path to a .md handover doc"
[[ $repo =~ ^/[A-Za-z0-9._/-]{1,250}$ ]] || bad repo "an absolute path"
case "$doc" in *"/../"* | *"/./"* | *"//"*) bad doc "no .. . or // segments" ;; esac
case "$repo/" in *"/../"* | *"/./"* | *"//"*) bad repo "no .. . or // segments" ;; esac

if [ -n "$session" ] && [ "$session" = "$chief" ]; then
    die "self-restart refused: the session $chief cannot restart itself; ask another session or the operator"
fi
[ -f "$doc" ] || die "no handover doc at $doc"
if [ -z "${HIMMEL_OPS_ROOT:-}" ]; then
    [ -f "$repo/scripts/handover/arm-resume.sh" ] || die "no arm-resume.sh under $repo"
fi

# pids of this user's processes named claude (comm, as the census reads it) whose argv holds -n NAME or --name NAME
# (never this script or its parents): a coincidental -n NAME on another program is not a chief
find_pids() {
    local d pid prev arg
    for d in /proc/[0-9]*; do
        pid=${d#/proc/}
        [ "$pid" = "$$" ] || [ "$pid" = "$PPID" ] && continue
        [ -O "$d" ] || continue
        [ "$(cat "$d/comm" 2>/dev/null)" = claude ] || continue
        prev=''
        while IFS= read -r -d '' arg; do
            if { [ "$prev" = -n ] || [ "$prev" = --name ]; } && [ "$arg" = "$chief" ]; then echo "$pid"; break; fi
            prev=$arg
        done < "$d/cmdline" 2>/dev/null
    done
}
alive_pid() { # a zombie is a stopped session
    local st
    st=$(sed -n 's/^[0-9]* (.*) \(.\) .*/\1/p' "/proc/$1/stat" 2>/dev/null)
    [ -n "$st" ] && [ "$st" != Z ]
}
pids=$(find_pids)
n=$(printf '%s' "$pids" | grep -c .)

when=$(date -d '+2 minutes' +%H:%M) || die "cannot compute the re-arm time" # gnu-ok: Linux only
if [ $check -eq 1 ]; then
    say would-change "will stop $n running session(s) named $chief and re-arm from $doc at $when"
    exit 0
fi

for p in $pids; do kill -TERM "$p" 2>/dev/null; done
left=75
while [ $left -gt 0 ]; do
    alive=''
    for p in $pids; do alive_pid "$p" && alive="$alive $p"; done
    [ -n "$alive" ] || break
    sleep 0.2
    left=$((left - 1))
done
for p in $alive; do kill -KILL "$p" 2>/dev/null; done
sleep 0.2
for p in $pids; do alive_pid "$p" && die "session $chief (pid $p) did not stop"; done

if [ -n "${HIMMEL_OPS_ROOT:-}" ] && [ -n "${HIMMEL_OPS_REARM_CMD:-}" ]; then
    "$HIMMEL_OPS_REARM_CMD" "$doc" "$repo" >/dev/null 2>&1 || die "the re-arm failed"
else
    out=$(bash "$repo/scripts/handover/arm-resume.sh" --handover "$doc" --force --time "$when" 2>&1) \
        || die "arm-resume.sh failed: $(printf '%s' "$out" | tail -n 1 | cut -c1-200)"
fi
say changed "stopped $n session(s) named $chief and re-armed from $doc at $when; the stale queue lock passes to the re-armed session"
