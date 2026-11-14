#!/usr/bin/env bash
# Tests for the station ops (OPS-1: cron-entry, cron-system, system-update; OPS-2: autologin.sh,
# reboot-recover.sh with its recover.sh, chief-restart.sh) and the afk-sudo `op-request` verb that runs them.
# Usage: bash scripts/station-ops/test-station-ops.sh
# Hermetic: every case builds a sandbox root through the helper's AFK_SUDO_ROOT / AFK_SUDO_NOW seams
# (honoured only when euid != 0), a fake crontab / apt-get on HIMMEL_OPS_BIN and a fake notice-bot curl.
# Nothing privileged runs on the host.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LIB="$REPO_ROOT/scripts/lib/afk-sudo"
HELPER="$LIB/afk_sudo.py"
OPS="$REPO_ROOT/scripts/station-ops"
OPERATOR=4242
T0=1800000000

PASS=0
FAIL=0
pass() { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        got: %s\n' "$2"; FAIL=$((FAIL+1)); }
assert_contains() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "$3" ;; esac; }
assert_absent() { case "$3" in *"$2"*) fail "$1" "$3" ;; *) pass "$1" ;; esac; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$3"; fi; }

[ "$(uname -s)" = Linux ] || { echo "SKIP: afk-sudo requires Linux"; exit 0; }
[ "$(id -u)" -ne 0 ] || { echo "FAIL: run as a non-root user"; exit 1; }
umask 022

tmp="$(mktemp -d "${TMPDIR:-/tmp}/station-ops-test.XXXXXX")" || { echo "FAIL: mktemp"; exit 1; }
cleanup() { local p; for p in ${STUBS:-}; do kill -KILL "$p" 2>/dev/null; done; rm -rf "$tmp"; }
trap cleanup EXIT

# A fake notice-bot curl: records each call's stdin config to $TG/NNN.txt and answers ok.
TG="$tmp/tg"
mkdir -p "$tmp/fakecurl"
cat > "$tmp/fakecurl/curl" <<FAKETG
#!/usr/bin/env python3
import json, os, sys
d = "$TG"
FAKETG
cat >> "$tmp/fakecurl/curl" <<'FAKETG'
cfg = sys.stdin.read() if "-K" in sys.argv else ""
n = len(os.listdir(d))
open(os.path.join(d, "%03d.txt" % n), "w").write(cfg)
print(json.dumps({"ok": True, "result": {"message_id": 100 + n}}))
FAKETG
chmod +x "$tmp/fakecurl/curl"
export AFK_SUDO_CURL="$tmp/fakecurl/curl"
NTOK="$((7000000000 + RANDOM)):$(python3 -I -c 'import secrets; print(secrets.token_urlsafe(26)[:35])')"

# new_root <name>: a sandbox station with ops enabled, the repo's ops installed with a manifest.
new_root() {
    R="$tmp/$1"
    mkdir -p "$R/etc/himmel/afk-sudo" "$R/var/lib/himmel/afk-sudo" "$R/var/log/himmel" "$R/etc/cron.d" "$R/bin" \
        "$R/usr/local/libexec/himmel/ops" "$R/usr/local/bin" "$R/usr/sbin"
    python3 -I -c 'import base64, secrets; print(base64.b32encode(secrets.token_bytes(20)).decode())' > "$R/etc/himmel/afk-sudo/totp.seed"
    chmod 0600 "$R/etc/himmel/afk-sudo/totp.seed"
    printf '{"enabled": true, "operator_id": %s, "window_s": 120, "operator_user": "%s", "ops": {"enabled": %s}, "classes": {}}\n' \
        "$OPERATOR" "$(id -un)" "${2:-true}" > "$R/etc/himmel/afk-sudo.json"
    printf 'TELEGRAM_BOT_TOKEN=%s\n' "$NTOK" > "$R/etc/himmel/afk-sudo/notice-bot.env"
    chmod 0600 "$R/etc/himmel/afk-sudo/notice-bot.env"
    for f in "$OPS"/*.sh "$OPS"/*.json; do
        case "$f" in */test-*) continue ;; esac
        [ -e "$f" ] && cp "$f" "$R/usr/local/libexec/himmel/ops/"
    done
    chmod 0755 "$R"/usr/local/libexec/himmel/ops/*.sh 2>/dev/null
    python3 -I "$OPS/build-manifest.py" "$R/usr/local/libexec/himmel/ops" >/dev/null 2>&1
    # the message-session opener stand-in cron lines may name
    printf '#!/bin/sh\nexit 0\n' > "$R/usr/local/bin/open-session"
    chmod 0755 "$R/usr/local/bin/open-session"
    # fake crontab: the table of -u <user> lives in $R/cron.<user>
    cat > "$R/bin/crontab" <<'FAKECRON'
#!/bin/sh
# usage: crontab -u USER -l | -
user=$2
f="$HIMMEL_OPS_ROOT/cron.$user"
echo "$@" >> "$HIMMEL_OPS_ROOT/crontab.calls"
case "$3" in
    -l) [ -e "$HIMMEL_OPS_ROOT/cron.warn" ] && echo "crontab: warning from the lister" >&2
        [ -f "$f" ] && cat "$f" || { echo "no crontab for $user" >&2; exit 1; } ;;
    -) cat > "$f" ;;
esac
FAKECRON
    chmod +x "$R/bin/crontab"
    rm -rf "$TG"; mkdir -p "$TG"
}

h() { local off="$1"; shift; AFK_SUDO_ROOT="$R" AFK_SUDO_NOW=$((T0 + off)) HIMMEL_OPS_ROOT="$R" HIMMEL_OPS_BIN="$R/bin" python3 -I "$HELPER" "$@" 2>&1; }
code() { python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import approval_broker as b; print(b.totp(open(sys.argv[2]).read().strip(), int(sys.argv[3]) // 30))' "$LIB" "$R/etc/himmel/afk-sudo/totp.seed" $((T0 + $1)); }
state_nonce() { python3 -I -c 'import json, sys
slots = json.load(open(sys.argv[1] + "/var/lib/himmel/afk-sudo/state.json")).get("slots") or []
print("".join(p.get("nonce", "") for p in slots if p.get("id") == sys.argv[2]))' "$R" "$1"; }
approve() { printf '%s %s\n' "$(state_nonce "$2")" "$3" | AFK_SUDO_ROOT="$R" AFK_SUDO_NOW=$((T0 + $1)) HIMMEL_OPS_ROOT="$R" HIMMEL_OPS_BIN="$R/bin" python3 -I "$HELPER" approve "$2" --from "$OPERATOR" --chat "$OPERATOR" 2>&1; }
rid() { printf '%s\n' "$1" | sed -n 's/^result=[^ ]* id=\([a-z2-7]*\).*/\1/p' | head -1; }
ledger() { cat "$R/var/log/himmel/afk-sudo.jsonl" 2>/dev/null; }
table() { cat "$R/cron.$(id -un)" 2>/dev/null; }
# op <script> args...: run an installed op script directly (the helper's own call shape).
op() { local s="$1"; shift; HIMMEL_OPS_ROOT="$R" HIMMEL_OPS_BIN="${OPS_BIN:-$R/bin}" bash "$R/usr/local/libexec/himmel/ops/$s.sh" --id testid00 --operator-user "$(id -un)" "$@" 2>&1; }
# oreq <now-offset> <session> <op> key=value...
oreq() { local off="$1" sess="$2"; shift 2; h "$off" op-request --session "$sess" --ticket HIMMEL-8203 "$@"; }
CMD=/usr/local/bin/open-session

echo "== RED: an installed copy that differs from the manifest is changed, not run =="
new_root tamper
printf '\n# tampered\n' >> "$R/usr/local/libexec/himmel/ops/cron-entry.sh"
out=$(oreq 0 S1 cron-entry action=set tag=ping "schedule=0 5 * * *" "command=$R$CMD")
assert_contains "RED: a request for a tampered op reads changed" "result=changed" "$out"
assert_absent "a tampered op files no request" "id=" "$out"
assert_eq "a tampered op ran nothing" "" "$(table)"
assert_contains "the changed refusal is in the ledger" '"result": "changed"' "$(ledger)"

new_root tamper-after
out=$(oreq 0 S1 cron-entry action=set tag=ping "schedule=0 5 * * *" "command=$R$CMD"); id=$(rid "$out")
assert_contains "an untampered op is pending" "result=pending" "$out"
printf '\n# tampered\n' >> "$R/usr/local/libexec/himmel/ops/cron-entry.sh"
out=$(approve 3 "$id" "$(code 3)")
assert_contains "RED: an op tampered after the request reads changed on approve" "result=changed" "$out"
assert_eq "the tampered op did not run" "" "$(table)"

echo "== RED: cron-entry set twice reports unchanged the second time =="
new_root idem
out=$(op cron-entry --action set --tag ping --schedule "0 5 * * *" --command "$R$CMD")
assert_contains "the first set changes the table" "result=changed" "$out"
out=$(op cron-entry --action set --tag ping --schedule "0 5 * * *" --command "$R$CMD")
assert_contains "RED: the second set is unchanged" "result=unchanged" "$out"
assert_eq "the table holds the tagged line once" "1" "$(table | grep -c '# HIMMEL-ping$')"
out=$(op cron-entry --check --action set --tag ping --schedule "0 6 * * *" --command "$R$CMD")
assert_contains "--check reports a would-change" "result=would-change" "$out"
assert_contains "--check did not change the table" "0 5 * * *" "$(table)"
out=$(op cron-entry --action remove --tag ping)
assert_contains "remove drops the tagged line" "result=changed" "$out"
assert_eq "the table is empty after remove" "" "$(table)"
assert_contains "remove again is unchanged" "result=unchanged" "$(op cron-entry --action remove --tag ping)"

echo "== RED: crontab -l stderr never lands in the table =="
new_root warn
: > "$R/cron.warn"
printf '5 4 * * * /bin/true\n' > "$R/cron.$(id -un)"
out=$(op cron-entry --action set --tag ping --schedule "0 5 * * *" --command "$R$CMD")
assert_contains "set succeeds with a lister warning" "result=changed" "$out"
assert_absent "RED: the lister warning is not in the table" "warning from the lister" "$(table)"
out=$(op cron-entry --action set --tag bad --schedule "0 5 * * *" --command "/home/x/evil")
assert_contains "the script itself refuses a command outside the opener dirs" "result=bad-param name=command" "$out"

echo "== RED: cron-entry command is one root-owned executable path, no arguments =="
new_root cmd
O="$R/usr/local/bin"
chmod 0775 "$O/open-session"
assert_contains "RED: a group-writable opener is bad-param" "result=bad-param name=command" "$(op cron-entry --check --action set --tag t --schedule "0 5 * * *" --command "$O/open-session")"
chmod 0755 "$O/open-session"
ln -s /usr/bin/true "$O/foreign"
assert_contains "RED: an opener owned by someone else is bad-param" "result=bad-param name=command" "$(op cron-entry --check --action set --tag t --schedule "0 5 * * *" --command "$O/foreign")"
assert_contains "RED: a missing opener is bad-param" "result=bad-param name=command" "$(op cron-entry --check --action set --tag t --schedule "0 5 * * *" --command "$O/nope")"
mkdir -p "$R/elsewhere"; printf '#!/bin/sh\nexit 0\n' > "$R/elsewhere/tool"; chmod 0755 "$R/elsewhere/tool"; ln -s "$R/elsewhere/tool" "$O/linked"
assert_contains "RED: a symlink leaving the opener dir is bad-param" "result=bad-param name=command" "$(op cron-entry --check --action set --tag t --schedule "0 5 * * *" --command "$O/linked")"
printf 'x' > "$O/plain"; chmod 0644 "$O/plain"
assert_contains "a non-executable file is bad-param" "result=bad-param name=command" "$(op cron-entry --check --action set --tag t --schedule "0 5 * * *" --command "$O/plain")"
assert_contains "RED: a path in the wrong directory is bad-param" "result=bad-param name=command" "$(op cron-entry --check --action set --tag t --schedule "0 5 * * *" --command "$R/usr/bin/open-session")"
assert_contains "a .. segment is bad-param" "result=bad-param name=command" "$(op cron-entry --check --action set --tag t --schedule "0 5 * * *" --command "$O/../bin/open-session")"
assert_contains "RED: a relative path is bad-param through the helper" "result=bad-param name=command" "$(oreq 0 S1 cron-entry action=set tag=t "schedule=0 5 * * *" command=open-session)"
assert_contains "RED: a command with arguments is bad-param through the helper" "result=bad-param name=command" "$(oreq 1 S2 cron-entry action=set tag=t "schedule=0 5 * * *" "command=$O/open-session now")"
assert_contains "a root-owned-check failure at the helper is bad-param before any notice" "result=bad-param name=command" "$(oreq 2 S3 cron-entry action=set tag=t "schedule=0 5 * * *" "command=$O/foreign")"
assert_eq "no refusal changed the table" "" "$(table)"

echo "== RED: a param outside its enum or regex is bad-param =="
new_root params
out=$(oreq 0 S1 cron-entry action=drop tag=ping)
assert_contains "RED: an action outside the enum is bad-param" "result=bad-param name=action" "$out"
out=$(oreq 1 S1 cron-entry action=remove "tag=a b;rm")
assert_contains "RED: a tag outside its regex is bad-param" "result=bad-param name=tag" "$out"
out=$(oreq 2 S1 cron-entry action=set tag=ping)
assert_contains "a missing required-when param is bad-param" "result=bad-param name=schedule" "$out"
out=$(oreq 3 S1 cron-entry action=remove tag=ping "schedule=0 5 * * *")
assert_contains "a param whose when does not hold is bad-param" "result=bad-param name=schedule" "$out"
out=$(oreq 4 S1 cron-entry action=remove tag=ping color=red)
assert_contains "an unknown param is bad-param" "result=bad-param name=color" "$out"
out=$(oreq 5 S1 cron-entry action=set tag=ping "schedule=0 5 * * *" command=/home/x/evil)
assert_contains "a command outside the opener dirs is bad-param" "result=bad-param name=command" "$out"
out=$(oreq 6 S1 cron-entry action=remove tag=ping tag=other)
assert_contains "a repeated param is bad-param" "result=bad-param name=tag" "$out"
assert_contains "bad-param is in the ledger" '"result": "bad-param"' "$(ledger)"
assert_contains "an unknown op is refused" "result=unknown-op" "$(oreq 7 S1 no-such-op)"
new_root off false
assert_contains "ops are off by default" "result=ops-disabled" "$(oreq 0 S1 cron-entry action=remove tag=ping)"

echo "== the full chain: request, notice, approve, ledger =="
new_root chain
out=$(oreq 0 S1 cron-entry action=set tag=ping "schedule=0 5 * * *" "command=$R$CMD"); id=$(rid "$out")
assert_contains "the request is pending" "result=pending" "$out"
notice=$(cat "$TG"/*.txt)
assert_contains "the notice names the op" "cron-entry" "$notice"
assert_contains "the notice shows the version" "v1" "$notice"
assert_contains "the notice shows a param" "tag" "$notice"
assert_contains "the notice shows the effect" "crontab" "$notice"
assert_contains "the notice shows what will change" "will set in the crontab" "$notice"
assert_eq "nothing ran before the code" "" "$(table)"
out=$(approve 3 "$id" "$(code 3)")
assert_contains "the code runs the op" "result=ran" "$out"
assert_contains "the table holds the entry" "0 5 * * * $R$CMD # HIMMEL-ping" "$(table)"
assert_contains "the run row names the op" '"op": "cron-entry"' "$(ledger)"
assert_contains "the run row holds the op result" '"op_result": "changed"' "$(ledger)"
out=$(oreq 40 S1 cron-entry action=set tag=ping "schedule=0 5 * * *" "command=$R$CMD"); id=$(rid "$out")
out=$(approve 43 "$id" "$(code 43)")
assert_contains "a second approved set runs" "result=ran" "$out"
assert_contains "the second set is unchanged in the ledger" '"op_result": "unchanged"' "$(ledger)"
assert_eq "still one tagged line" "1" "$(table | grep -c '# HIMMEL-ping$')"
out=$(oreq 80 S1 cron-entry action=remove tag=ping); id=$(rid "$out")
approve 83 "$id" "$(code 83)" >/dev/null
assert_eq "remove through the chain clears the table" "" "$(table)"

echo "== the never-remote floor reads the parameters, not the installed script's path =="
new_root floor
printf '{"enabled": true, "operator_id": %s, "window_s": 120, "operator_user": "%s", "ops": {"enabled": true}, "never_remote_extra": ["*/usr/local/bin/open-session"], "classes": {}}\n' \
    "$OPERATOR" "$(id -un)" > "$R/etc/himmel/afk-sudo.json"
assert_contains "a parameter naming a floor pattern is never-remote" "result=never-remote" "$(oreq 0 S1 cron-entry action=set tag=ping "schedule=0 5 * * *" "command=$R$CMD")"
assert_contains "a request whose parameters are clear passes the floor" "result=pending" "$(oreq 1 S1 cron-entry action=remove tag=ping)"

echo "== lockdown denies a pending op request =="
new_root lock
out=$(oreq 0 S1 cron-entry action=remove tag=ping); id=$(rid "$out")
h 1 lockdown --from "$OPERATOR" --chat "$OPERATOR" >/dev/null
python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1] + "/var/lib/himmel/afk-sudo/state.json"))["lockdown"]["nonce"])' "$R" | h 1 lockdown --with-nonce --from "$OPERATOR" --chat "$OPERATOR" >/dev/null
assert_contains "the pending op request reads denied" "result=denied" "$(h 2 status "$id")"
assert_contains "a locked-down station refuses a new op request" "result=disabled" "$(oreq 3 S2 cron-entry action=remove tag=ping)"

echo "== cron-system =="
new_root sys
f="$R/etc/cron.d/himmel-nightly"
printf '#!/bin/sh\nexit 0\n' > "$R/usr/sbin/himmel-job"; chmod 0755 "$R/usr/sbin/himmel-job"
assert_contains "RED: an interpreter-style command with a file argument is bad-param" "result=bad-param name=command" "$(op cron-system --action set --tag evil --schedule "30 2 * * *" --user root --command "$R/usr/sbin/himmel-job /home/x/x.sh")"
chmod 0775 "$R/usr/sbin/himmel-job"
assert_contains "RED: a group-writable command is bad-param" "result=bad-param name=command" "$(op cron-system --action set --tag evil --schedule "30 2 * * *" --user root --command "$R/usr/sbin/himmel-job")"
chmod 0755 "$R/usr/sbin/himmel-job"
assert_contains "RED: a job for a user who is neither root nor the operator is bad-param" "result=bad-param name=user" "$(op cron-system --action set --tag evil --schedule "30 2 * * *" --user nobody --command "$R/usr/sbin/himmel-job")"
assert_contains "RED: the operator user is bad-param, cron-system is root only" "result=bad-param name=user" "$(op cron-system --action set --tag evil --schedule "30 2 * * *" --user "$(id -un)" --command "$R/usr/sbin/himmel-job")"
ln -s himmel-job "$R/usr/sbin/linked"
assert_contains "RED: a symlinked command is bad-param" "result=bad-param name=command" "$(op cron-system --action set --tag evil --schedule "30 2 * * *" --user root --command "$R/usr/sbin/linked")"
chmod 0775 "$R/usr/sbin"
assert_contains "RED: a group-writable directory holding the command is bad-param" "result=bad-param name=command" "$(op cron-system --action set --tag evil --schedule "30 2 * * *" --user root --command "$R/usr/sbin/himmel-job")"
chmod 0755 "$R/usr/sbin"; chmod 0775 "$R/usr"
assert_contains "RED: a group-writable ancestor directory is bad-param" "result=bad-param name=command" "$(op cron-system --action set --tag evil --schedule "30 2 * * *" --user root --command "$R/usr/sbin/himmel-job")"
chmod 0755 "$R/usr"
assert_eq "no refusal wrote a cron.d file" "no" "$([ -e "$R/etc/cron.d/himmel-evil" ] && echo yes || echo no)"
out=$(op cron-system --action set --tag nightly --schedule "30 2 * * *" --user root --command "$R/usr/sbin/himmel-job")
assert_contains "cron-system set writes the file" "result=changed" "$out"
assert_contains "the file holds the line" "30 2 * * * root $R/usr/sbin/himmel-job" "$(cat "$f" 2>/dev/null)"
assert_contains "set again is unchanged" "result=unchanged" "$(op cron-system --action set --tag nightly --schedule "30 2 * * *" --user root --command "$R/usr/sbin/himmel-job")"
assert_contains "root with a command under /usr/local/bin is refused" "result=bad-param name=command" "$(op cron-system --action set --tag evil --schedule "30 2 * * *" --user root --command "$R/usr/local/bin/open-session")"
assert_contains "root with a command outside the allowed dirs is refused" "result=bad-param name=command" "$(op cron-system --action set --tag evil --schedule "30 2 * * *" --user root --command /home/x/evil)"
assert_contains "remove deletes the file" "result=changed" "$(op cron-system --action remove --tag nightly)"
assert_eq "the cron.d file is gone" "no" "$([ -e "$f" ] && echo yes || echo no)"
assert_contains "remove again is unchanged" "result=unchanged" "$(op cron-system --action remove --tag nightly)"

echo "== system-update =="
new_root upd
mkdir -p "$R/etc"
printf 'ID=ubuntu\nID_LIKE=debian\n' > "$R/etc/os-release"
printf 'linux-image-6.8\ncurl\n' > "$R/pending"
cat > "$R/bin/apt-get" <<'FAKEAPT'
#!/bin/sh
case "$*" in
    *update*) exit 0 ;;
    *-s*) [ -e "$HIMMEL_OPS_ROOT/sim-fail" ] && exit 100
        while read -r p; do echo "Inst $p [1] (2 Ubuntu)"; done < "$HIMMEL_OPS_ROOT/pending"; exit 0 ;;
    *upgrade*) : > "$HIMMEL_OPS_ROOT/pending"; exit 0 ;;
esac
FAKEAPT
chmod +x "$R/bin/apt-get"
out=$(op system-update --check)
assert_contains "--check reports the pending upgrades" "result=would-change" "$out"
assert_eq "--check upgraded nothing" "2" "$(wc -l < "$R/pending" | tr -d ' ')"
out=$(op system-update)
assert_contains "system-update upgrades" "result=changed" "$out"
assert_contains "a kernel upgrade recommends a reboot" "reboot_recommended=yes" "$out"
assert_contains "the second run is unchanged" "result=unchanged" "$(op system-update)"
assert_eq "the log is under var/log/himmel/ops" "yes" "$([ -s "$R/var/log/himmel/ops/testid00.log" ] && echo yes || echo no)"
: > "$R/sim-fail"
out=$(op system-update --check)
assert_contains "a failed simulation is a failure, not nothing to upgrade (--check)" "result=failed" "$out"
out=$(op system-update)
assert_contains "a failed simulation is a failure, not nothing to upgrade (run)" "result=failed" "$out"

echo "== system-update on Arch: pacman -Qu status =="
new_root arch
mkdir -p "$R/etc"
printf 'ID=arch\n' > "$R/etc/os-release"
printf '#!/bin/sh\necho "error: failed to initialize alpm library" >&2\nexit 1\n' > "$R/bin/pacman"
chmod +x "$R/bin/pacman"
assert_contains "RED: a pacman error is a failure, not nothing to upgrade" "result=failed" "$(op system-update --check)"
printf '#!/bin/sh\nexit 1\n' > "$R/bin/pacman"
assert_contains "pacman exit 1 with no output is nothing to upgrade" "result=unchanged" "$(op system-update --check)"

echo "== autologin: detects the display manager, refuses an unknown one =="
new_root al
U=$(id -un)
HOMEDIR=$(getent passwd "$U" | cut -d: -f6)
dm() { mkdir -p "$R/etc/systemd/system"; ln -sf "/usr/lib/systemd/system/$1.service" "$R/etc/systemd/system/display-manager.service"; }
mkdir -p "$R/usr/share/xsessions" "$R/usr/share/wayland-sessions"; : > "$R/usr/share/xsessions/xfce.desktop"; : > "$R/usr/share/wayland-sessions/plasma.desktop"
assert_contains "RED: no display manager is refused" "result=failed" "$(op autologin --action enable --session xfce)"
dm lxdm
out=$(op autologin --action enable --session xfce)
assert_contains "RED: an unknown display manager is refused" "result=failed" "$out"
assert_contains "the refusal names the display manager" "unsupported display manager 'lxdm'" "$out"
dm sddm
assert_contains "a bad action is bad-param" "result=bad-param name=action" "$(op autologin --action toggle)"
out=$(op autologin --check --action enable --session xfce)
assert_contains "--check reports a would-change" "result=would-change" "$out"
assert_eq "--check wrote nothing" "no" "$([ -e "$R/etc/sddm.conf.d/himmel-autologin.conf" ] && echo yes || echo no)"
out=$(op autologin --action enable --session xfce)
assert_contains "RED: SDDM enable changes the config" "result=changed" "$out"
assert_contains "the SDDM file names the operator user" "User=$U" "$(cat "$R/etc/sddm.conf.d/himmel-autologin.conf" 2>/dev/null)"
out=$(op autologin --action enable --session xfce)
assert_contains "RED: enable on an already-enabled config is unchanged" "result=unchanged" "$out"
assert_eq "the SDDM file is untouched by the second enable" "[Autologin]
User=$U
Session=xfce.desktop" "$(cat "$R/etc/sddm.conf.d/himmel-autologin.conf")"
assert_contains "RED: enable without a session is bad-param" "result=bad-param name=session" "$(op autologin --action enable)"
assert_contains "RED: a session that is not installed is bad-param" "result=bad-param name=session" "$(op autologin --action enable --session nosuch)"
assert_contains "a session with a path in it is bad-param" "result=bad-param name=session" "$(op autologin --action enable --session ../xfce)"
assert_contains "a Wayland session is accepted" "result=changed" "$(op autologin --action enable --session plasma)"
assert_contains "disable with a session is bad-param" "result=bad-param name=session" "$(op autologin --action disable --session xfce)"
assert_contains "enable with another session changes the file" "result=changed" "$(op autologin --action enable --session xfce)"
assert_contains "disable removes the SDDM file" "result=changed" "$(op autologin --action disable)"
assert_eq "the SDDM file is gone" "no" "$([ -e "$R/etc/sddm.conf.d/himmel-autologin.conf" ] && echo yes || echo no)"
assert_contains "disable again is unchanged" "result=unchanged" "$(op autologin --action disable)"
assert_contains "no other auto-login config reads none" "other-autologin=none" "$(op autologin --check --action disable)"
printf '[Autologin]\nUser=someone\n' > "$R/etc/sddm.conf"
printf '[Autologin]\nUser=someone\n' > "$R/etc/sddm.conf.d/10-other.conf"
assert_contains "RED: SDDM auto-login set in another file is reported on enable" "other-autologin=$R/etc/sddm.conf" "$(op autologin --check --action enable --session xfce)"
assert_contains "RED: and in a conf.d drop-in" "10-other.conf" "$(op autologin --check --action disable)"
op autologin --action enable --session xfce >/dev/null
assert_contains "RED: disable says auto-login is still enabled by another file" "still enabled by $R/etc/sddm.conf" "$(op autologin --action disable)"
assert_contains "RED: and an unchanged disable says so too" "still enabled by" "$(op autologin --action disable)"
rm -f "$R/etc/sddm.conf" "$R/etc/sddm.conf.d/10-other.conf"
dm lightdm
assert_contains "LightDM enable changes the config" "result=changed" "$(op autologin --action enable --session xfce)"
assert_contains "the LightDM file names the operator user" "autologin-user=$U" "$(cat "$R/etc/lightdm/lightdm.conf.d/50-himmel-autologin.conf" 2>/dev/null)"
assert_contains "RED: the LightDM file names the session (lightdm defaults to one that may not be installed)" "autologin-session=xfce" "$(cat "$R/etc/lightdm/lightdm.conf.d/50-himmel-autologin.conf" 2>/dev/null)"
mkdir -p "$R/etc/lightdm/lightdm.conf.d"; printf '[Seat:*]\nautologin-user=bob\n' > "$R/etc/lightdm/lightdm.conf.d/10-other.conf"
assert_contains "RED: LightDM auto-login set in another file is reported" "other-autologin=$R/etc/lightdm/lightdm.conf.d/10-other.conf" "$(op autologin --check --action disable)"
rm -f "$R/etc/lightdm/lightdm.conf.d/10-other.conf"
assert_contains "LightDM enable again is unchanged" "result=unchanged" "$(op autologin --action enable --session xfce)"
dm gdm3
mkdir -p "$R/etc/gdm3"
printf '[daemon]\n#WaylandEnable=false\nAutomaticLoginEnable=False\n\n[security]\nFoo=bar\n' > "$R/etc/gdm3/custom.conf"
assert_contains "GDM enable changes the config" "result=changed" "$(op autologin --action enable --session xfce)"
gdm=$(cat "$R/etc/gdm3/custom.conf")
assert_contains "GDM sets AutomaticLoginEnable" "AutomaticLoginEnable=True" "$gdm"
assert_contains "GDM sets AutomaticLogin to the operator user" "AutomaticLogin=$U" "$gdm"
assert_absent "GDM drops the old AutomaticLoginEnable=False" "AutomaticLoginEnable=False" "$gdm"
assert_contains "GDM keeps the other sections" "Foo=bar" "$gdm"
assert_eq "GDM writes each key once" "2" "$(printf '%s\n' "$gdm" | grep -c '^AutomaticLogin')"
assert_contains "GDM enable again is unchanged" "result=unchanged" "$(op autologin --action enable --session xfce)"
assert_contains "GDM disable changes the config" "result=changed" "$(op autologin --action disable)"
assert_absent "GDM disable removes the keys" "AutomaticLogin" "$(cat "$R/etc/gdm3/custom.conf")"
assert_contains "GDM keeps the other sections after disable" "Foo=bar" "$(cat "$R/etc/gdm3/custom.conf")"
assert_contains "GDM disable again is unchanged" "result=unchanged" "$(op autologin --action disable)"
rm -f "$R/etc/gdm3/custom.conf"
assert_contains "GDM enable creates a missing custom.conf" "result=changed" "$(op autologin --action enable --session xfce)"
assert_contains "the new custom.conf holds a [daemon] section" "[daemon]" "$(cat "$R/etc/gdm3/custom.conf")"
printf '[daemon]\r\nAutomaticLoginEnable=True\r\nAutomaticLogin=%s\r\n' "$U" > "$R/etc/gdm3/custom.conf"
assert_contains "RED: GDM disable recognises a CRLF section" "result=changed" "$(op autologin --action disable)"
assert_absent "RED: and removes the keys from a CRLF file" "AutomaticLogin" "$(cat "$R/etc/gdm3/custom.conf")"
printf '[daemon]\nTimedLoginEnable=true\nTimedLogin=bob\n' > "$R/etc/gdm3/custom.conf"
assert_contains "RED: GDM timed login is reported as another way in" "$R/etc/gdm3/custom.conf(timed-login)" "$(op autologin --check --action disable)"
echo "== autologin: the keyring state is reported =="
dm sddm
assert_contains "no login keyring reads keyring=none" "keyring=none" "$(op autologin --check --action disable)"
mkdir -p "$R$HOMEDIR/.local/share/keyrings"; : > "$R$HOMEDIR/.local/share/keyrings/login.keyring"
assert_contains "a login keyring reads locked at autologin" "keyring=present-locked-at-autologin" "$(op autologin --action enable --session xfce)"
assert_contains "autologin goes through the chain" "result=pending" "$(oreq 0 S1 autologin action=disable)"

echo "== chief-restart: an operator-user op =="
new_root cr
cdoc="$R/chief-doc.md"; echo "# doc" > "$cdoc"
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "$1 $2" >> "$HIMMEL_OPS_ROOT/rearm.calls"\n' > "$R/bin/rearm"; chmod +x "$R/bin/rearm"
export HIMMEL_OPS_REARM_CMD="$R/bin/rearm"
printf '#!/bin/bash\ntrap "exit 0" TERM; while :; do sleep 0.2; done\n' > "$R/bin/claude"; chmod +x "$R/bin/claude"
stub() { "$R/bin/claude" -n "$1" & STUBPID=$!; STUBS="${STUBS:-} $STUBPID"; sleep 0.4; }
decoy() { bash -c 'trap "exit 0" TERM; while :; do sleep 0.2; done' decoy -n "$1" & DECOYPID=$!; STUBS="${STUBS:-} $DECOYPID"; sleep 0.4; }
running() { local st; st=$(sed -n 's/^[0-9]* (.*) \(.\) .*/\1/p' "/proc/$1/stat" 2>/dev/null); [ -n "$st" ] && [ "$st" != Z ]; }
gone() { local _; for _ in 1 2 3 4 5 6 7 8 9 10; do running "$1" || return 0; sleep 0.2; done; return 1; }
out=$(op chief-restart --session chief-x1 --chief chief-x1 --doc "$cdoc" --repo "$R")
assert_contains "RED: a chief restarting itself reads self-restart" "self-restart" "$out"
assert_contains "the self-restart is a failure" "result=failed" "$out"
assert_eq "a self-restart re-armed nothing" "no" "$([ -e "$R/rearm.calls" ] && echo yes || echo no)"
stub chief-x2
out=$(op chief-restart --check --session other --chief chief-x2 --doc "$cdoc" --repo "$R")
assert_contains "--check counts the running chief" "stop 1 running" "$out"
assert_eq "--check left the chief running" "yes" "$(running $STUBPID && echo yes || echo no)"
out=$(op chief-restart --session other --chief chief-x2 --doc "$cdoc" --repo "$R")
assert_contains "RED: a restart from another session changes" "result=changed" "$out"
assert_contains "the restart stopped one session" "stopped 1 session" "$out"
assert_eq "the running stub chief is gone" "yes" "$(gone $STUBPID && echo yes || echo no)"
assert_contains "the chief was re-armed from its doc" "$cdoc $R" "$(cat "$R/rearm.calls" 2>/dev/null)"
out=$(op chief-restart --session other --chief chief-x3 --doc "$cdoc" --repo "$R")
assert_contains "a chief that is not running is just re-armed" "stopped 0 session" "$out"
assert_contains "a bad chief name is bad-param" "result=bad-param name=chief" "$(op chief-restart --session other --chief 'a b' --doc "$cdoc" --repo "$R")"
assert_contains "a doc that is not a .md is bad-param" "result=bad-param name=doc" "$(op chief-restart --session other --chief chief-x4 --doc /etc/passwd --repo "$R")"
assert_contains "a missing doc fails" "no handover doc" "$(op chief-restart --session other --chief chief-x4 --doc "$R/none.md" --repo "$R")"
decoy chief-x9
out=$(op chief-restart --session other --chief chief-x9 --doc "$cdoc" --repo "$R")
assert_contains "RED: a process that is not named claude is not a chief" "stopped 0 session" "$out"
assert_eq "the decoy with -n NAME is left running" "yes" "$(running $DECOYPID && echo yes || echo no)"

echo "== chief-restart through the helper: operator-user ops, the session, self-restart =="
out=$(oreq 0 chief-x5 chief-restart chief=chief-x5 "doc=$cdoc" "repo=$R")
assert_contains "RED: the helper refuses a chief's own session before any notice" "result=self-restart" "$out"
assert_absent "the self-restart files no request" "id=" "$out"
assert_contains "the self-restart is in the ledger" '"result": "self-restart"' "$(ledger)"
stub chief-x6
out=$(oreq 10 other chief-restart chief=chief-x6 "doc=$cdoc" "repo=$R"); id=$(rid "$out")
assert_contains "RED: an operator-user op from another session is pending" "result=pending" "$out"
notice=$(cat "$TG"/*.txt)
assert_contains "the notice names the op" "chief-restart" "$notice"
assert_absent "the notice does not say ROOT for an operator-user op" "ROOT" "$notice"
assert_eq "nothing ran before the code" "yes" "$(running $STUBPID && echo yes || echo no)"
out=$(approve 13 "$id" "$(code 13)")
assert_contains "the code runs the operator-user op" "result=ran" "$out"
assert_eq "the stub chief was stopped by the approved op" "yes" "$(gone $STUBPID && echo yes || echo no)"
assert_contains "the run row holds the op result" '"op_result": "changed"' "$(ledger)"
echo "== operator-user ops: a root op still runs as root, an unknown run_as is refused =="
cp "$R/usr/local/libexec/himmel/ops/chief-restart.sh" "$R/usr/local/libexec/himmel/ops/weird.sh"
python3 -I -c 'import json, sys
d = json.load(open(sys.argv[1] + "/chief-restart.json")); d["name"] = "weird"; d["run_as"] = "nobody"
json.dump(d, open(sys.argv[1] + "/weird.json", "w"))' "$R/usr/local/libexec/himmel/ops"
python3 -I "$OPS/build-manifest.py" "$R/usr/local/libexec/himmel/ops" >/dev/null 2>&1
assert_contains "RED: an unknown run_as is unknown-op" "result=unknown-op" "$(oreq 50 other weird chief=chief-x8 "doc=$cdoc" "repo=$R")"
assert_contains "a root op (cron-entry) is still accepted" "result=pending" "$(oreq 51 other cron-entry action=remove tag=ping)"
unset HIMMEL_OPS_REARM_CMD
out=$(AFK_SUDO_ROOT="$R" python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import afk_sudo as a; r = a.run_op(["/bin/true"], {"run_as": "operator-user"}, None); print(len(r), r[0], r[1])' "$LIB" 2>&1)
assert_eq "RED: an operator-user op with no user to drop to returns the same four values, not a crash" "4 127 None" "$out"

echo "== reboot-recover: arm and disarm the root marker and the user unit =="
new_root rr
mkdir -p "$R/repo/scripts/station-ops" "$R/repo/scripts/telegram" "$R/repo/scripts/handover" "$R/state"
cp "$OPS/recover.sh" "$R/repo/scripts/station-ops/recover.sh"
printf '#!/bin/sh\nexit 0\n' > "$R/repo/scripts/telegram/restart-bridge.sh"
printf '#!/bin/sh\necho "$*" >> "%s/arm.log"\n' "$R" > "$R/repo/scripts/handover/arm-resume.sh"
rdoc="$R/doc.md"; echo "# doc" > "$rdoc"
M="$R/var/lib/himmel/reboot-recover.json"
arm() { op reboot-recover --action arm --doc "$rdoc" --repo "$R/repo"; }
out=$(op reboot-recover --check --action arm --doc "$rdoc" --repo "$R/repo")
assert_contains "--check reports a would-change" "result=would-change" "$out"
assert_eq "--check wrote no marker" "no" "$([ -e "$M" ] && echo yes || echo no)"
out=$(arm)
assert_contains "RED: arm writes the marker" "result=changed" "$out"
assert_contains "the marker names the user" "\"user\": \"$(id -un)\"" "$(cat "$M" 2>/dev/null)"
assert_contains "the marker names the handover doc" "\"doc\": \"$rdoc\"" "$(cat "$M" 2>/dev/null)"
assert_contains "the unit runs recover.sh from the repo" "ExecStart=/usr/bin/bash $R/repo/scripts/station-ops/recover.sh" "$(cat "$R/etc/systemd/user/himmel-recover.service" 2>/dev/null)"
assert_contains "RED: the unit starts for the operator user only" "ConditionUser=$(id -un)" "$(cat "$R/etc/systemd/user/himmel-recover.service" 2>/dev/null)"
assert_contains "the unit needs the marker" "ConditionPathExists=/var/lib/himmel/reboot-recover.json" "$(cat "$R/etc/systemd/user/himmel-recover.service" 2>/dev/null)"
assert_eq "the unit is enabled for every user session" "../himmel-recover.service" "$(readlink "$R/etc/systemd/user/default.target.wants/himmel-recover.service")"
armed_at=$(sed 's/.*"armed_at": \([0-9]*\)}/\1/' "$M")
sleep 1
assert_contains "RED: arming the same marker again is unchanged" "result=unchanged" "$(arm)"
assert_eq "the second arm kept armed_at" "$armed_at" "$(sed 's/.*"armed_at": \([0-9]*\)}/\1/' "$M")"
echo "# other" > "$R/other.md"
assert_contains "arming another doc changes the marker" "result=changed" "$(op reboot-recover --action arm --doc "$R/other.md" --repo "$R/repo")"
assert_contains "a doc outside the regex is bad-param" "result=bad-param name=doc" "$(op reboot-recover --action arm --doc /etc/passwd --repo "$R/repo")"
assert_contains "a repo without recover.sh is bad-param" "result=bad-param name=repo" "$(op reboot-recover --action arm --doc "$rdoc" --repo "$R")"
assert_contains "arm without a doc is bad-param" "result=bad-param name=doc" "$(op reboot-recover --action arm --repo "$R/repo")"
assert_contains "disarm with a doc is bad-param" "result=bad-param name=doc" "$(op reboot-recover --action disarm --doc "$rdoc")"
assert_contains "disarm removes the marker" "result=changed" "$(op reboot-recover --action disarm)"
assert_eq "the marker is gone" "no" "$([ -e "$M" ] && echo yes || echo no)"
assert_contains "disarm again is unchanged" "result=unchanged" "$(op reboot-recover --action disarm)"

echo "== recover.sh: acts only on a root marker, once per arming =="
mkdir -p "$R/ubin"
cat > "$R/ubin/systemctl" <<'FAKESYSTEMCTL'
#!/bin/sh
# systemctl --user is-active [--quiet] UNIT | start UNIT
case "$2" in
    is-active) for u in "$@"; do :; done; [ -e "$RECOVER_FAKE_DIR/down.$u" ] && exit 3; exit 0 ;;
    start) exit 0 ;;
esac
FAKESYSTEMCTL
chmod +x "$R/ubin/systemctl"
cp "$tmp/fakecurl/curl" "$R/ubin/curl"
printf 'TELEGRAM_BOT_TOKEN=%s\n' "$NTOK" > "$R/tg.env"
rec() { PATH="$R/ubin:$PATH" RECOVER_FAKE_DIR="$R" HIMMEL_RECOVER_ROOT="$R" HIMMEL_RECOVER_STATE="$R/state" HIMMEL_RECOVER_SERVICES="telegram-bridge.service" \
    TELEGRAM_ENV="$R/tg.env" bash "$OPS/recover.sh" 2>&1; echo "rc=$?"; }
out=$(rec)
assert_contains "RED: a reboot with no marker makes recover do nothing" "no marker, nothing to do" "$out"
assert_eq "no marker: nothing was re-armed" "no" "$([ -e "$R/arm.log" ] && echo yes || echo no)"
assert_eq "no marker: no Telegram status" "0" "$(find "$TG" -type f | wc -l | tr -d ' ')"
arm >/dev/null
out=$(rec)
assert_contains "an armed marker re-arms the chief from its doc" "re-armed from doc.md" "$out"
assert_contains "arm-resume got the handover doc" "--handover $rdoc --force --time" "$(cat "$R/arm.log" 2>/dev/null)"
assert_contains "the status reports the services" "telegram-bridge.service=up" "$out"
assert_contains "the status reports the bridge" "bridge up" "$out"
assert_contains "recover exits 0 when all is well" "rc=0" "$out"
assert_eq "one Telegram status was sent" "1" "$(find "$TG" -type f | wc -l | tr -d ' ')"
out=$(rec)
assert_contains "RED: the same arming is not recovered twice" "already recovered" "$out"
assert_eq "no second re-arm" "1" "$(wc -l < "$R/arm.log" | tr -d ' ')"
sleep 1
op reboot-recover --action arm --doc "$R/other.md" --repo "$R/repo" >/dev/null
: >"$R/down.telegram-bridge.service"
out=$(rec)
assert_contains "a new arming recovers again" "re-armed from other.md" "$out"
assert_contains "a service that stays down is reported DOWN" "telegram-bridge.service=DOWN" "$out"
assert_contains "a down service makes recover exit 1" "rc=1" "$out"
rm -f "$R/down.telegram-bridge.service"
python3 -I -c 'import json, sys
p = sys.argv[1]
m = json.load(open(p)); m["user"] = "someone-else"; json.dump(m, open(p, "w"))' "$M"
assert_contains "a marker for another user is ignored" "the marker is for someone-else" "$(rec)"
python3 -I -c 'import json, sys
p = sys.argv[1]
m = json.load(open(p)); m["user"] = sys.argv[2]; m["armed_at"] += 5; json.dump(m, open(p, "w"))' "$M" "$(id -un)"
mkdir -p "$R/state"
before=$(wc -l < "$R/arm.log" | tr -d ' ')
( flock 9; sleep 4 ) 9> "$R/state/recover.lock" &
LOCKPID=$!; STUBS="${STUBS:-} $LOCKPID"; sleep 0.5
assert_contains "RED: a second recover run while one holds the lock does nothing" "already running" "$(rec)"
assert_eq "the locked-out run re-armed nothing" "$before" "$(wc -l < "$R/arm.log" | tr -d ' ')"
wait $LOCKPID 2>/dev/null
mkdir -p "$R/ro"; chmod 0555 "$R/ro"
out=$(HIMMEL_RECOVER_STATE="$R/ro/state" PATH="$R/ubin:$PATH" RECOVER_FAKE_DIR="$R" HIMMEL_RECOVER_ROOT="$R" HIMMEL_RECOVER_SERVICES="telegram-bridge.service" TELEGRAM_ENV="$R/tg.env" bash "$OPS/recover.sh" 2>&1; echo "rc=$?")
assert_contains "RED: a completion stamp that cannot be written is a failure" "cannot record" "$out"
assert_contains "the failed stamp makes recover exit 1" "rc=1" "$out"
chmod 0755 "$R/ro"
mkdir -p "$R/stamp-state/recover-done" # a directory where the stamp file belongs: the state dir is fine, the stamp write fails
out=$(HIMMEL_RECOVER_STATE="$R/stamp-state" PATH="$R/ubin:$PATH" RECOVER_FAKE_DIR="$R" HIMMEL_RECOVER_ROOT="$R" HIMMEL_RECOVER_SERVICES="telegram-bridge.service" TELEGRAM_ENV="$R/tg.env" bash "$OPS/recover.sh" 2>&1; echo "rc=$?")
assert_contains "RED: a stamp write that fails after the recovery steps names the stamp path" "cannot record completion in $R/stamp-state/recover-done" "$out"
assert_contains "the failed stamp write makes recover exit 1" "rc=1" "$out"
assert_contains "RED: a failed stamp write still sends the status report" "recover: reboot recovery on" "$out"

echo "== size-approval (R5): --check writes nothing, a run writes the approval, a re-run renews it =="
new_root sa
SA_DIR="$R/var/lib/himmel/size-approvals"
SA_S=3f9a0c1d2e4b5a69788796a5b4c3d2e1
sa() { OPS_BIN="$R/bin-clock" op size-approval "$@"; }
mkdir -p "$R/bin-clock"
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "$FAKE_NOW"\n' > "$R/bin-clock/date"; chmod +x "$R/bin-clock/date"
export FAKE_NOW=$T0
out=$(sa --check --key HIMMEL-9228 --label N5216 --files 272 --scope "$SA_S" --reason keep-whole)
assert_contains "RED: size-approval --check reports a would-change" "result=would-change" "$out"
assert_eq "--check created no size-approvals directory" "no" "$([ -e "$SA_DIR" ] && echo yes || echo no)"
out=$(sa --key HIMMEL-9228 --label N5216 --files 272 --scope "$SA_S" --reason keep-whole)
assert_contains "RED: a size-approval run reports changed" "result=changed" "$out"
SA_F="$SA_DIR/HIMMEL-9228.N5216.272.$SA_S"
assert_eq "the approval file is mode 0644" "644" "$(stat -c %a "$SA_F" 2>/dev/null)"  # gnu-ok: the suite is Linux-only (guard above)
sa_field() { awk -F'\t' -v c="$1" 'NR == 1 { print $c }' "$SA_F" 2>/dev/null; }
assert_eq "the approval is one line" "1" "$(wc -l < "$SA_F" 2>/dev/null | tr -d ' ')"
assert_eq "the approval holds 8 tab-separated fields" "8" "$(awk -F'\t' 'NR == 1 { print NF }' "$SA_F" 2>/dev/null)"
assert_eq "the approval starts SIZE-APPROVAL" "SIZE-APPROVAL" "$(sa_field 1)"
assert_eq "RED: the clock pin takes: expires is the pinned now plus 7 days" "$((T0 + 604800))" "$(sa_field 2)"
assert_eq "the approval names key, label, files, scope, id and reason" "HIMMEL-9228 N5216 272 $SA_S testid00 keep-whole" "$(sa_field 3) $(sa_field 4) $(sa_field 5) $(sa_field 6) $(sa_field 7) $(sa_field 8)"
export FAKE_NOW=$((T0 + 60))
out=$(sa --key HIMMEL-9228 --label N5216 --files 272 --scope "$SA_S" --reason keep-whole)
assert_contains "a re-approval reports changed" "result=changed" "$out"
assert_eq "RED: a re-approval renews expires" "$((T0 + 60 + 604800))" "$(sa_field 2)"
sa_bad() {
    local -A v=([key]=HIMMEL-9228 [label]=N5216 [files]=272 [scope]="$SA_S" [reason]=keep-whole)
    v[$1]="$2"
    local a=() k
    for k in key label files scope reason; do [ "${v[$k]}" = "<none>" ] || a+=(--"$k" "${v[$k]}"); done
    out=$(sa "${a[@]}"); rc=$?
    case "$out" in *"result=bad-param name=$1"*) if [ "$rc" = 3 ]; then pass "$3"; else fail "$3 (exit $rc)" "$out"; fi ;; *) fail "$3" "$out" ;; esac
}
sa_bad key himmel-9228 "a lowercase key is bad-param, exit 3"
sa_bad files 27x "a non-number files value is bad-param, exit 3"
sa_bad scope "${SA_S%?}" "a scope of 31 hex is bad-param, exit 3"
sa_bad scope "$(printf '%s' "$SA_S" | tr 'a-f' 'A-F')" "an uppercase scope is bad-param, exit 3"
sa_bad reason "keep whole" "a reason holding a space is bad-param, exit 3"
sa_bad reason "keep/whole" "a reason holding / is bad-param, exit 3"
sa_bad reason 'keep"whole' "a reason holding a double quote is bad-param, exit 3"
sa_bad reason "keep;whole" "a reason holding ; is bad-param, exit 3"
sa_bad scope "<none>" "a call missing --scope is bad-param, exit 3"
unset FAKE_NOW

echo "== size-approval (R6): the Telegram line through the helper, then the reader =="
new_root sa6
SA_DIR="$R/var/lib/himmel/size-approvals"
line=$(head -n 1 "$REPO_ROOT/scripts/handover/chief-kit/fixtures/size-approval-op-line.txt")
read -ra words <<< "${line#/op }"
SA6_S=$(printf '%s\n' "${words[@]}" | sed -n 's/^scope=//p')
out=$(h 0 op-request --session telegram-op --ticket operator -- "${words[@]}"); id=$(rid "$out")
assert_contains "RED: the fixture line files a pending size-approval request" "result=pending" "$out"
assert_contains "the notice shows the --check line" "will approve HIMMEL-9228 N5216" "$(cat "$TG"/*.txt 2>/dev/null)"
assert_eq "a pending request wrote no approval" "no" "$([ -e "$SA_DIR" ] && echo yes || echo no)"
out=$(printf 'ZZZZ 000000\n' | AFK_SUDO_ROOT="$R" AFK_SUDO_NOW=$((T0 + 2)) HIMMEL_OPS_ROOT="$R" HIMMEL_OPS_BIN="$R/bin" python3 -I "$HELPER" approve "$id" --from "$OPERATOR" --chat "$OPERATOR" 2>&1)
assert_absent "a wrong nonce and code does not run the op" "result=ran" "$out"
assert_eq "a wrong code wrote no approval" "no" "$([ -e "$SA_DIR" ] && echo yes || echo no)"
out=$(approve 43 "$id" "$(code 43)")
assert_contains "RED: NONCE CODE runs the size-approval op" "op_result=changed" "$out"
SA6_F="$SA_DIR/HIMMEL-9228.N5216.272.$SA6_S"
assert_eq "the approved op wrote the approval file" "yes" "$([ -f "$SA6_F" ] && echo yes || echo no)"
RK="$tmp/rkit"; mkdir -p "$RK/scripts/handover/chief-kit" "$tmp/hroot"
ln -s "$REPO_ROOT/scripts/lib" "$RK/scripts/lib"; ln -s "$REPO_ROOT/scripts/ci" "$RK/scripts/ci"
sed -e "s|^SIZE_APPROVALS=/var/lib/himmel/size-approvals\$|SIZE_APPROVALS=$SA_DIR|" -e "s|^SIZE_APPROVAL_UID=0\$|SIZE_APPROVAL_UID=$(id -u)|" \
    "$REPO_ROOT/scripts/handover/chief-kit/size-override.sh" > "$RK/scripts/handover/chief-kit/size-override.sh"
assert_eq "the reader copy points at the sandbox approvals" "1" "$(grep -c "^SIZE_APPROVALS=$SA_DIR\$" "$RK/scripts/handover/chief-kit/size-override.sh")"
assert_eq "the reader copy owns the approvals as the test user" "1" "$(grep -c "^SIZE_APPROVAL_UID=$(id -u)\$" "$RK/scripts/handover/chief-kit/size-override.sh")"
out=$(bash "$RK/scripts/handover/chief-kit/size-override.sh" check HIMMEL-9228 N5216 --files 272 --trust yes --scope "$SA6_S" --root "$tmp/hroot" 2>&1); rc=$?
assert_eq "RED: the reader accepts the approval the Telegram line produced (exit 0)" "0" "$rc"
assert_contains "the reader says the operator kept it whole" "kept whole by the operator" "$out"

echo "== HIMMEL-9691: a delivered notice leaves a sent row with the Bot API receipt =="
station_ledger_row_sixqv7lo='{"cwd": "/", "event": "request", "hash": "15ad1b2b703e8795c8bee214cb609388e522b0996cc6a7da2d618beb12038d31", "id": "sixqv7lo", "kind": "op", "op": "size-approval", "params": {"files": "67", "key": "HIMMEL-9689", "label": "N5590", "reason": "keep-whole", "scope": "116f2c95737b91306c8a95d1c97c2e4d"}, "result": "pending", "script_sha256": "f307349ded689ecc803eef113a1ed0491407e408e1ecf276f04a34b38667246c", "session": "terminal-2446437", "ticket": "HIMMEL-9689", "ts": "2026-11-09T01:10:13Z", "version": 1}'
new_root n9691
read -ra words <<< "$(printf '%s' "$station_ledger_row_sixqv7lo" | python3 -I -c 'import json, sys; r = json.load(sys.stdin); print(r["op"], *(k + "=" + v for k, v in r["params"].items()))')"
out=$(h 0 op-request --session terminal-2446437 --ticket HIMMEL-9689 -- "${words[@]}"); id=$(rid "$out")
assert_contains "the station's sixqv7lo request files again here" "result=pending" "$out"
assert_eq "the refiled request row carries the station row's op, params, session and ticket" "yes" "$(ledger | python3 -I -c 'import json, sys
real = json.loads(sys.argv[1])
rows = [json.loads(l) for l in sys.stdin if l.strip()]
k = ("event", "kind", "op", "params", "result", "session", "ticket", "version", "cwd")
print("yes" if any(all(r.get(x) == real[x] for x in k) for r in rows) else "no")' "$station_ledger_row_sixqv7lo")"
sent_row=$(ledger | grep '"event": "notice"' | grep "\"id\": \"$id\"")
assert_contains "RED 9691: a delivered notice writes a notice row of result sent" '"result": "sent"' "$sent_row"
assert_contains "RED 9691: the sent row carries the Bot API message_id as its receipt" '"message_id": 100' "$sent_row"
assert_absent "the sent row holds no token" "$NTOK" "$(ledger)"

echo "== helper-update (HIMMEL-9732): the fixture, a fake GitHub on HIMMEL_OPS_BIN =="
HU_MAIN=cccccccccccccccccccccccccccccccccccccccc
HU_OLD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HU_OLDER=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
HU_NEWER=dddddddddddddddddddddddddddddddddddddddd
HU="$tmp/hu"; mkdir -p "$HU"
cat > "$HU/fake-gh-curl.py" <<'FAKEGH'
#!/usr/bin/env python3
import hashlib, json, os, sys, urllib.parse
R = os.environ["HIMMEL_OPS_ROOT"]
G = os.path.join(R, "gh")
args = sys.argv[1:]
with open(os.path.join(R, "curl.log"), "a") as f:
    f.write(" ".join(args) + "\n")
if not args or args[0] != "-q":
    sys.stderr.write("fake curl: the first argument must be -q\n")
    sys.exit(2)
fx = json.load(open(os.path.join(G, "fixture.json")))
repo = fx["repo"]
outs, urls, i = [], [], 1
while i < len(args):
    a = args[i]
    if a in ("--output", "-o"):
        outs.append(args[i + 1]); i += 2
    elif a in ("--proto", "--max-redirs", "--max-time", "-H", "-A", "--max-filesize"):
        i += 2
    elif a.startswith("-"):
        i += 1
    else:
        urls.append(a); i += 1
def blob(data):
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()
def entries(sha):
    base = os.path.join(G, sha)
    out = []
    for dp, dn, fn in os.walk(base):
        for n in sorted(fn):
            p = os.path.join(dp, n)
            data = open(p, "rb").read()
            out.append({"path": os.path.relpath(p, base), "mode": "100755" if os.stat(p).st_mode & 0o111 else "100644",
                        "type": "blob", "sha": blob(data), "size": len(data)})
    return out + fx.get("tree_extra", {}).get(sha, [])
def reply(obj):
    sys.stdout.write(json.dumps(obj))
    sys.exit(0)
def notfound():
    sys.stderr.write("curl: (22) The requested URL returned error: 404\n")
    sys.exit(22)
for n, url in enumerate(urls):
    u = urllib.parse.urlsplit(url)
    if u.scheme != "https":
        sys.exit(1)
    p, q = u.path, dict(urllib.parse.parse_qsl(u.query))
    if u.netloc == "raw.githubusercontent.com":
        _, r1, r2, sha, rel = p.split("/", 4)
        if r1 + "/" + r2 != repo or n >= len(outs):
            notfound()
        if rel in fx.get("raw_override", {}):
            data = fx["raw_override"][rel].encode()
        else:
            src = os.path.join(G, sha, rel)
            if not os.path.isfile(src):
                notfound()
            data = open(src, "rb").read()
        open(outs[n], "wb").write(data)
        continue
    pre = "/repos/" + repo
    if u.netloc != "api.github.com" or not p.startswith(pre):
        notfound()
    s = p[len(pre):]
    if s == "/branches/main":
        reply({"commit": {"sha": fx["main"]}})
    elif s.startswith("/compare/"):
        c = fx["compare"].get(s[len("/compare/"):])
        if c is None:
            notfound()
        reply({"status": c["status"], "ahead_by": c.get("ahead_by", 0), "total_commits": c.get("ahead_by", 0),
               "files": [{"filename": x} for x in c.get("files", [])],
               "base_commit": {"commit": {"message": c.get("message", "a subject")}}})
    elif s == "/actions/runs":
        reply({"workflow_runs": fx["runs"].get(q.get("head_sha"), [])})
    elif s == "/actions/workflows/ci.yml/runs":
        reply({"workflow_runs": fx["newest"]})
    elif s.startswith("/git/trees/"):
        reply({"sha": s.split("/")[-1], "truncated": fx.get("truncated", False), "tree": entries(s.split("/")[-1])})
    elif s.startswith("/commits/") and s.endswith("/pulls"):
        reply(fx["pulls"])
    elif s.startswith("/pulls/") and s.endswith("/reviews"):
        reply(fx["reviews"].get(s.split("/")[2], []))
    elif s.startswith("/pulls/"):
        reply(fx["pull"].get(s.split("/")[2], {}))
    else:
        notfound()
FAKEGH
cat > "$HU/mkfix.py" <<'MKFIX'
import json, sys
R, C, X, repo = sys.argv[1:5]
def run(sha):
    return {"path": ".github/workflows/ci.yml", "event": "schedule", "conclusion": "success", "head_sha": sha, "head_branch": "main",
            "head_repository": {"full_name": repo}, "run_started_at": "2026-11-13T02:00:00Z"}
fx = {"repo": repo, "main": C,
      "compare": {C + "..." + C: {"status": "identical", "message": "feat(x): the subject line"},
                  X + "..." + C: {"status": "ahead", "ahead_by": 2, "files": ["scripts/lib/afk-sudo/approval_broker.py", "scripts/station-ops/size-approval.sh"]}},
      "runs": {C: [run(C)]}, "newest": [run(C)],
      "pulls": [{"number": 77, "merge_commit_sha": C}],
      "pull": {"77": {"user": {"login": "author1"}, "merged_by": {"login": "merger1"}}},
      "reviews": {"77": [{"user": {"login": "approver1"}, "state": "APPROVED"}]}}
json.dump(fx, open(R + "/gh/fixture.json", "w"))
MKFIX
cat > "$HU/mkrec.py" <<'MKREC'
import hashlib, json, os, sys
R, sha, tree = sys.argv[1:4]
files = {}
for sub in ("scripts/lib/afk-sudo", "scripts/station-ops"):
    for n in sorted(os.listdir(os.path.join(tree, sub))):
        p = os.path.join(tree, sub, n)
        d = open(p, "rb").read()
        files[sub + "/" + n] = {"mode": "100755" if os.stat(p).st_mode & 0o111 else "100644",
                                "blob": hashlib.sha1(b"blob %d\0" % len(d) + d).hexdigest(), "sha256": hashlib.sha256(d).hexdigest()}
json.dump({"commit": sha, "run": "setup000", "time": 1.0, "files": files}, open(R + "/var/lib/himmel/afk-sudo/helper-commit", "w"))
MKREC
cat > "$HU/install-tree.sh" <<'INSTTREE'
#!/bin/bash
set -e
t=$1; lx=$2/usr/local/libexec/himmel
install -d -m 0755 "$lx"
install -m 0644 "$t/scripts/lib/afk-sudo/approval_broker.py" "$lx/approval_broker.py"
install -m 0644 "$t/scripts/lib/afk-sudo/never_remote.py" "$lx/never_remote.py"
install -m 0755 "$t/scripts/lib/afk-sudo/afk_sudo.py" "$lx/afk-sudo"
rm -rf "$lx/ops"
install -d -m 0755 "$lx/ops"
for f in "$t"/scripts/station-ops/*.json; do
    op=$(basename "$f" .json)
    install -m 0644 "$f" "$lx/ops/$op.json"
    install -m 0755 "$t/scripts/station-ops/$op.sh" "$lx/ops/$op.sh"
done
python3 -I "$t/scripts/station-ops/build-manifest.py" "$lx/ops" >/dev/null
INSTTREE
cat > "$HU/stub-install.sh" <<'STUBINST'
#!/bin/bash
R=${HIMMEL_OPS_ROOT:?}
: > "$R/sourced-marker"
src=$(cd "$(dirname "$0")" && pwd)
t=$(cd "$src/../../.." && pwd)
[ "${1:-}" = --user ] && u=${2:-}
variant=$(cat "$R/gh/variant" 2>/dev/null || echo base)
cfg=$R/etc/himmel/afk-sudo.json
setcfg() { python3 -I -c 'import json, sys
p = sys.argv[1]; d = json.load(open(p)); exec(sys.argv[2]); json.dump(d, open(p, "w"))' "$cfg" "$1"; }
bash "$R/install-tree.sh" "$t" "$R" || exit 1
printf '%s ALL=(root) NOPASSWD: /usr/local/libexec/himmel/afk-sudo\n' "$u" > "$R/etc/sudoers.d/.new"
chmod 0440 "$R/etc/sudoers.d/.new"; mv "$R/etc/sudoers.d/.new" "$R/etc/sudoers.d/himmel-afk-sudo"
setcfg 'd["added_by_installer"] = True'
echo INSTALLER-NOISE
case $variant in
    broken-afk-sudo) printf '#!/bin/sh\nexit 1\n' > "$R/usr/local/libexec/himmel/afk-sudo" ;;
    ops-removed) rm -rf "$R/usr/local/libexec/himmel/ops"; exit 1 ;;
    config-changed) setcfg 'd["window_s"] = 999' ;;
    sleep) exec sleep 30 ;;
    lockdown-fail) setcfg 'd["enabled"] = False'; exit 1 ;;
    lockdown-row) printf '{"event": "lockdown", "result": "locked", "ts": "%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$R/var/log/himmel/afk-sudo.jsonl" ;;
    wider-line) printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$u" > "$R/etc/sudoers.d/.new"; chmod 0440 "$R/etc/sudoers.d/.new"; mv "$R/etc/sudoers.d/.new" "$R/etc/sudoers.d/himmel-afk-sudo" ;;
    extra-file) printf 'x ALL=(ALL) ALL\n' > "$R/etc/sudoers.d/zz-extra"; chmod 0440 "$R/etc/sudoers.d/zz-extra" ;;
    sudoers-main) chmod u+w "$R/etc/sudoers"; echo '# appended' >> "$R/etc/sudoers"; chmod 0440 "$R/etc/sudoers" ;;
esac
exit 0
STUBINST
HU_USER=$(id -un)
gh_edit() { python3 -I -c 'import json, sys
p = sys.argv[1]; d = json.load(open(p)); exec(sys.argv[2]); json.dump(d, open(p, "w"))' "$R/gh/fixture.json" "$1"; }
hu_cfg() { python3 -I -c 'import json, sys
p = sys.argv[1]; d = json.load(open(p)); exec(sys.argv[2]); json.dump(d, open(p, "w"))' "$R/etc/himmel/afk-sudo.json" "$1"; }
hu_tree() {
    local d="$R/gh/$1/scripts"
    mkdir -p "$d/lib/afk-sudo" "$d/station-ops"
    cp -p "$LIB"/* "$d/lib/afk-sudo/" 2>/dev/null
    cp -p "$OPS"/* "$d/station-ops/" 2>/dev/null
    cp "$HU/stub-install.sh" "$d/lib/afk-sudo/install.sh"; chmod 0755 "$d/lib/afk-sudo/install.sh"
}
hu_fixture() { python3 -I "$HU/mkfix.py" "$R" "$HU_MAIN" "$HU_OLD" "${1:-t/h}"; }
hu_record() { python3 -I "$HU/mkrec.py" "$R" "$1" "$R/gh/$1"; }
hu_terminal() { bash "$R/install-tree.sh" "$R/gh/$1" "$R"; }
hu_root() {
    rm -rf "${tmp:?}/$1"
    new_root "$1"
    mkdir -p "$R/gh" "$R/etc/sudoers.d" "$R/var/log/himmel/ops"
    chmod 0700 "$R/var/lib/himmel/afk-sudo"
    cp "$HU/fake-gh-curl.py" "$R/bin/curl"; chmod +x "$R/bin/curl"
    printf '#!/bin/sh\nshift 3\nexec /usr/bin/timeout -k 1 4 "$@"\n' > "$R/bin/timeout"; chmod +x "$R/bin/timeout"
    cp "$HU/install-tree.sh" "$R/install-tree.sh"
    hu_tree "$HU_MAIN"; hu_tree "$HU_OLD"; hu_tree "$HU_OLDER"
    printf '# older\n' >> "$R/gh/$HU_OLD/scripts/lib/afk-sudo/approval_broker.py"
    printf '# older\n' >> "$R/gh/$HU_OLD/scripts/station-ops/size-approval.sh"
    printf '# older still\n' >> "$R/gh/$HU_OLDER/scripts/lib/afk-sudo/approval_broker.py"
    printf '# older still\n' >> "$R/gh/$HU_OLDER/scripts/station-ops/cron-entry.sh"
    mkdir -p "$R/checkout"; cp -rp "$R/gh/$HU_MAIN/scripts" "$R/checkout/scripts"
    mkdir -p "$R/checkout/scripts/lib/afk-sudo/__pycache__"; echo x > "$R/checkout/scripts/lib/afk-sudo/__pycache__/x.pyc"
    printf 'Defaults env_reset\n' > "$R/etc/sudoers"; chmod 0440 "$R/etc/sudoers"
    printf '# other\n' > "$R/etc/sudoers.d/90-other"; chmod 0440 "$R/etc/sudoers.d/90-other"
    printf '%s ALL=(root) NOPASSWD: /usr/local/libexec/himmel/afk-sudo\n' "$HU_USER" > "$R/etc/sudoers.d/himmel-afk-sudo"; chmod 0440 "$R/etc/sudoers.d/himmel-afk-sudo"
    printf '{"enabled": true, "operator_id": %s, "window_s": 120, "operator_user": "%s", "ops": {"enabled": true}, "helper_update": {"enabled": true, "checkout": "%s", "repo": "t/h"}, "classes": {}}\n' \
        "$OPERATOR" "$HU_USER" "$R/checkout" > "$R/etc/himmel/afk-sudo.json"
    hu_fixture
    if [ "${2:-fresh}" = stale ]; then hu_terminal "$HU_OLD"; hu_record "$HU_OLD"; else hu_terminal "$HU_MAIN"; fi
}
hu_chk() { op helper-update --check --commit "${1:-$HU_MAIN}"; }
hu_req() { oreq "$1" S1 helper-update "commit=${2:-$HU_MAIN}"; }
hu_approve_read() {
    approve "$1" "$2" "$(code "$1")"; printf '\n'
    cat "$(find "$TG" -name '*.txt' 2>/dev/null | sort | tail -1)" 2>/dev/null
}
hu_detail() { printf '%s\n' "$1" | sed -n 's/.*detail=//p' | tail -1; }
curl_n() { if [ -e "$R/curl.log" ]; then wc -l < "$R/curl.log" | tr -d ' '; else echo 0; fi; }
hu_state() {
    python3 -I -c 'import hashlib, os, stat, sys
R, parts = sys.argv[1], sys.argv[2:]
tops = {"libexec": ["usr/local/libexec/himmel"], "sudoers": ["etc/sudoers", "etc/sudoers.d"], "config": ["etc/himmel/afk-sudo.json"]}
def row(p):
    st = os.lstat(os.path.join(R, p))
    h = hashlib.sha256(open(os.path.join(R, p), "rb").read()).hexdigest() if stat.S_ISREG(st.st_mode) else ""
    print(p, oct(st.st_mode), st.st_uid, h)
for part in parts or tops:
    for top in tops[part]:
        row(top)
        if os.path.isdir(os.path.join(R, top)):
            for dp, dn, fn in os.walk(os.path.join(R, top)):
                for n in sorted(dn + fn):
                    row(os.path.relpath(os.path.join(dp, n), R))
' "$R" "$@" | LC_ALL=C sort
}
hu_stage_count() { find "$R/var/lib/himmel/afk-sudo/helper-update" -maxdepth 1 -name 'stage.*' 2>/dev/null | wc -l | tr -d ' '; }  # gnu-ok: the suite is Linux-only (guard at the top)
HU_PEND=var/lib/himmel/afk-sudo/helper-update.pending

echo "== helper-update R1: one commit parameter, in the sandbox manifest, off in the template =="
hu_root r1
assert_contains "RED R1: the op is in the sandbox manifest" '"helper-update"' "$(cat "$R/usr/local/libexec/himmel/ops/manifest.json" 2>/dev/null)"
assert_contains "RED R1: a commit of 40 hex is filed" "result=pending" "$(hu_req 0)"
assert_contains "the template ships helper_update off" '"helper_update": {"enabled": false' "$(cat "$LIB/afk-sudo.json.template")"
n0=$(curl_n)
for bad in "commit=$(printf '%s' "$HU_MAIN" | tr a-f A-F)" "commit=${HU_MAIN%?}" "commit=${HU_MAIN}0" "commit=zz"; do
    assert_contains "RED R1: '${bad:0:12}...' is bad-param" "result=bad-param name=commit" "$(oreq 1 S1 helper-update "$bad")"
done
assert_contains "RED R1: an extra path parameter is bad-param" "result=bad-param name=path" "$(oreq 2 S1 helper-update "commit=$HU_MAIN" path=/x)"
assert_contains "RED R1: a repo parameter is bad-param" "result=bad-param name=repo" "$(oreq 3 S1 helper-update "commit=$HU_MAIN" repo=a/b)"
assert_contains "the op itself refuses a bad commit with exit 3" "result=bad-param name=commit" "$(op helper-update --check --commit nothex)"
assert_eq "no bad-param made a curl call" "$n0" "$(curl_n)"

echo "== helper-update R2: off, a relative checkout, a slash in the repo: refused before any call =="
for edit in 'd["helper_update"]["enabled"] = False' 'd["helper_update"]["checkout"] = "rel/path"' 'd["helper_update"]["repo"] = "a/b/c"' 'd["helper_update"]["repo"] = ""' 'del d["helper_update"]'; do
    hu_root r2
    hu_cfg "$edit"
    assert_contains "RED R2: --check is failed ($edit)" "result=failed" "$(hu_chk)"
    assert_contains "RED R2: the helper answers check-failed ($edit)" "result=check-failed" "$(hu_req 0)"
    assert_eq "R2: no curl call ($edit)" "0" "$(curl_n)"
done

echo "== helper-update R3: a commit that is not on main =="
for st in behind diverged; do
    hu_root r3; gh_edit "d['compare']['$HU_MAIN...$HU_MAIN']['status'] = '$st'"
    out=$(hu_chk)
    assert_contains "RED R3: compare says $st: not-on-main" "not-on-main" "$out"
    assert_contains "R3: and it is failed" "result=failed" "$out"
done

echo "== helper-update R4: only a green ci.yml Actions run of this repo at this sha counts =="
for edit in "d['runs']['$HU_MAIN'] = []" "d['runs']['$HU_MAIN'][0]['conclusion'] = 'failure'" "d['runs']['$HU_MAIN'][0]['path'] = '.github/workflows/other.yml'" \
    "d['runs']['$HU_MAIN'][0]['head_repository']['full_name'] = 'fork/h'" "d['runs']['$HU_MAIN'][0]['event'] = 'pull_request'" "d['runs']['$HU_MAIN'][0]['event'] = 'push'"; do
    hu_root r4; gh_edit "$edit"
    out=$(hu_chk)
    assert_contains "RED R4: no passing ci.yml run is failed ($edit)" "result=failed" "$out"
done
hu_root r4; gh_edit "d['runs']['$HU_MAIN'][0]['event'] = 'workflow_dispatch'"
assert_contains "R4: a workflow_dispatch run counts" "result=would-change" "$(hu_chk)"

echo "== helper-update R5: only the newest green main commit at filing, not at the run =="
hu_root r5; gh_edit "d['newest'][0]['head_sha'] = '$HU_NEWER'"
assert_contains "RED R5: a newer green main commit refuses --check" "result=failed" "$(hu_chk)"
hu_root r5b
out=$(hu_req 0); id=$(rid "$out")
assert_contains "R5: the request is filed while it is the newest" "result=pending" "$out"
gh_edit "d['newest'][0]['head_sha'] = '$HU_NEWER'"
assert_contains "RED R5: a newer green commit after the request does not refuse the run" "op_result=changed" "$(hu_approve_read 3 "$id")"

echo "== helper-update R6: the tree listing and the fetched bytes are checked; a refusal changes nothing =="
for edit in \
    "d.setdefault('tree_extra', {}).setdefault('$HU_MAIN', []).append({'path': 'scripts/lib/afk-sudo/sub', 'mode': '040000', 'type': 'tree', 'sha': '0'*40})" \
    "d.setdefault('tree_extra', {}).setdefault('$HU_MAIN', []).append({'path': 'scripts/station-ops/lnk', 'mode': '120000', 'type': 'blob', 'sha': '1'*40, 'size': 3})" \
    "d.setdefault('tree_extra', {}).setdefault('$HU_MAIN', []).append({'path': 'scripts/station-ops/sm', 'mode': '160000', 'type': 'commit', 'sha': '2'*40})" \
    "d.setdefault('tree_extra', {}).setdefault('$HU_MAIN', []).append({'path': 'scripts/lib/afk-sudo/sub/x.py', 'mode': '100644', 'type': 'blob', 'sha': '3'*40, 'size': 3})" \
    "d.setdefault('tree_extra', {}).setdefault('$HU_MAIN', []).append({'path': 'scripts/station-ops/big.sh', 'mode': '100644', 'type': 'blob', 'sha': '4'*40, 'size': 1048577})" \
    "d['truncated'] = True"; do
    hu_root r6; before=$(hu_state)
    gh_edit "$edit"
    out=$(hu_chk)
    assert_contains "RED R6: a refused listing is failed (${edit:0:60})" "result=failed" "$out"
    assert_eq "R6: the approval system is unchanged (${edit:0:60})" "$before" "$(hu_state)"
done
hu_root r6b; before=$(hu_state)
gh_edit "d['raw_override'] = {'scripts/lib/afk-sudo/never_remote.py': 'evil'}"
out=$(hu_req 0); id=$(rid "$out")
out=$(hu_approve_read 3 "$id")
assert_contains "RED R6: raw bytes whose blob id differs from the listing are failed" "op_result=failed" "$out"
assert_eq "R6: the libexec, sudoers and config are unchanged after the bad bytes" "$before" "$(hu_state)"
assert_eq "R6: the stage is gone" "0" "$(hu_stage_count)"

echo "== helper-update R7: the checkout must hold the commit's files, before filing and at the run =="
for edit in "printf x >> \"\$R/checkout/scripts/lib/afk-sudo/afk_sudo.py\"" "echo {} > \"\$R/checkout/scripts/station-ops/x.json\"" \
    "rm \"\$R/checkout/scripts/lib/afk-sudo/never_remote.py\"" "ln -s /etc/passwd \"\$R/checkout/scripts/station-ops/y.sh\""; do
    hu_root r7; before=$(hu_state)
    eval "$edit"
    out=$(hu_chk)
    assert_contains "RED R7: a checkout that differs is failed ($edit)" "checkout differs" "$out"
    assert_eq "R7: the approval system is unchanged ($edit)" "$before" "$(hu_state)"
done
hu_root r7b
printf 'junk\n' > "$R/checkout/scripts/lib/afk-sudo/__pycache__/y.pyc"
assert_contains "R7: __pycache__ alone is not a difference" "result=would-change" "$(hu_chk)"
out=$(hu_req 0); id=$(rid "$out"); before=$(hu_state)
printf x >> "$R/checkout/scripts/lib/afk-sudo/afk_sudo.py"
out=$(hu_approve_read 3 "$id")
assert_contains "RED R7: a checkout changed after filing fails the run" "checkout differs" "$out"
assert_eq "R7: and the approval system is unchanged" "$before" "$(hu_state)"

echo "== helper-update R8: nothing differs files nothing; with no record the request is still offered =="
hu_root r8; hu_record "$HU_MAIN"
out=$(hu_chk)
assert_contains "RED R8: libexec equal to the commit, record naming it: nothing differs" "nothing differs" "$out"
assert_contains "R8: nothing differs is failed" "result=failed" "$out"
assert_contains "R8: the helper files no request for it" "result=check-failed" "$(hu_req 0)"
rm -f "$R/var/lib/himmel/afk-sudo/helper-commit"
out=$(hu_chk)
assert_contains "R8: with no record the request is offered" "result=would-change" "$out"
assert_contains "R8: and says the installed commit is unknown" "installed commit unknown" "$out"

echo "== helper-update R9/R13/R14: the positive run through the helper, and what the run touches =="
hu_root r9 stale; before=$(hu_state libexec)
out=$(hu_req 0); id=$(rid "$out")
assert_contains "RED R9: a stale station files a pending request" "result=pending" "$out"
notice=$(cat "$TG"/*.txt 2>/dev/null)
assert_contains "R9: the notice names the commit" "${HU_MAIN:0:12}" "$notice"
assert_contains "R9: the notice names the PR" "PR #77" "$notice"
assert_contains "R9: the notice names the merger" "merged by merger1" "$notice"
assert_contains "R9: the notice names an approver" "approved by approver1" "$notice"
assert_contains "R9: the notice carries the compare link" "github.com/t/h/compare/${HU_OLD:0:12}...${HU_MAIN:0:12}" "$notice"
assert_contains "R9: the notice names the changed broker" "approval_broker.py" "$notice"
assert_contains "R9: the notice names the changed op" "ops/size-approval.sh" "$notice"
assert_eq "R14: --check ran no fetched installer" "no" "$([ -e "$R/sourced-marker" ] && echo yes || echo no)"
assert_eq "R14: --check made no stage" "0" "$(hu_stage_count)"
assert_eq "R14: --check made no raw call" "0" "$(grep -c raw.githubusercontent "$R/curl.log")"
assert_eq "R9: nothing changed before the code" "$before" "$(hu_state libexec)"
out=$(hu_approve_read 3 "$id")
assert_contains "RED R9: NONCE CODE changes the station" "op_result=changed" "$out"
assert_contains "R9: the detail names the broker" "approval_broker.py" "$out"
assert_contains "R9: the detail names the op" "ops/size-approval.sh" "$out"
assert_absent "R9: the installer's noise is not on the op's stdout" "INSTALLER-NOISE" "$out"
assert_contains "R9: the installer's noise is in the root log" "INSTALLER-NOISE" "$(cat "$R/var/log/himmel/ops/$id.log" 2>/dev/null)"
assert_eq "R9: the broker equals the commit's" "yes" "$(cmp -s "$R/gh/$HU_MAIN/scripts/lib/afk-sudo/approval_broker.py" "$R/usr/local/libexec/himmel/approval_broker.py" && echo yes || echo no)"
assert_eq "R9: the op script equals the commit's" "yes" "$(cmp -s "$R/gh/$HU_MAIN/scripts/station-ops/size-approval.sh" "$R/usr/local/libexec/himmel/ops/size-approval.sh" && echo yes || echo no)"
assert_contains "R9: the record names the commit" "\"commit\": \"$HU_MAIN\"" "$(cat "$R/var/lib/himmel/afk-sudo/helper-commit" 2>/dev/null)"
assert_contains "R9: the record holds a row for a fixture file" 'scripts/station-ops/size-approval.sh' "$(cat "$R/var/lib/himmel/afk-sudo/helper-commit" 2>/dev/null)"
assert_eq "R9: the marker is gone" "no" "$([ -e "$R/$HU_PEND" ] && echo yes || echo no)"
assert_eq "R9: the stage is gone" "0" "$(hu_stage_count)"
assert_eq "R14: the approved run ran the installer" "yes" "$([ -e "$R/sourced-marker" ] && echo yes || echo no)"
bad=$(grep -vc '^-q ' "$R/curl.log")
assert_eq "RED R13: every call starts with -q" "0" "$bad"
assert_eq "R13: every call carries --proto =https" "$(curl_n)" "$(grep -c -e '--proto =https' "$R/curl.log")"
assert_eq "R13: every call carries --max-redirs 0" "$(curl_n)" "$(grep -c -e '--max-redirs 0' "$R/curl.log")"
assert_eq "RED C3: every call carries --globoff" "$(curl_n)" "$(grep -c -e '--globoff' "$R/curl.log")"
assert_eq "R13: every URL is one of the two hosts" "0" "$(grep -o 'https://[^ ]*' "$R/curl.log" | grep -vc -e '^https://api.github.com/' -e '^https://raw.githubusercontent.com/')"
assert_eq "R13: raw files are fetched only once, after the approval" "1" "$(grep -c raw.githubusercontent "$R/curl.log")"
assert_eq "R15: no call names the bare word main after ..." "0" "$(grep -c -e '\.\.\.main' "$R/curl.log")"
assert_contains "R15: the compares name main's sha" "compare/$HU_MAIN...$HU_MAIN" "$(cat "$R/curl.log")"

echo "== helper-update R10: no go code changes nothing =="
hu_root r10 stale; before=$(hu_state)
out=$(hu_req 0); id=$(rid "$out")
out=$(printf 'ZZZZ 000000\n' | AFK_SUDO_ROOT="$R" AFK_SUDO_NOW=$((T0 + 2)) HIMMEL_OPS_ROOT="$R" HIMMEL_OPS_BIN="$R/bin" python3 -I "$HELPER" approve "$id" --from "$OPERATOR" --chat "$OPERATOR" 2>&1)
assert_absent "RED R10: a wrong nonce and code runs nothing" "result=ran" "$out"
assert_eq "R10: a wrong code changes nothing" "$before" "$(hu_state)"
out=$(h 3 deny "$id" --from "$OPERATOR" --chat "$OPERATOR")
assert_eq "R10: a deny changes nothing" "$before" "$(hu_state)"
out=$(hu_req 10); id=$(rid "$out")
out=$(hu_approve_read 2000 "$id")
assert_absent "R10: an expired request runs nothing" "result=ran" "$out"
assert_eq "R10: an expiry changes nothing" "$before" "$(hu_state)"
assert_eq "R10: no stage and no marker" "0" "$(hu_stage_count)$([ -e "$R/$HU_PEND" ] && echo 1)"

echo "== helper-update R11: a failed installer is rolled back =="
for v in broken-afk-sudo ops-removed config-changed; do
    hu_root r11 stale; before=$(hu_state)
    printf '%s' "$v" > "$R/gh/variant"
    out=$(hu_req 0); id=$(rid "$out")
    out=$(hu_approve_read 3 "$id")
    assert_contains "RED R11: $v is failed" "op_result=failed" "$out"
    assert_contains "R11: $v says rolled back" "rolled back" "$out"
    assert_eq "R11: $v leaves libexec, sudoers and config as they were" "$before" "$(hu_state)"
    assert_eq "R11: $v leaves no marker and no stage" "0" "$(hu_stage_count)$([ -e "$R/$HU_PEND" ] && echo 1)"
    assert_eq "R11: $v leaves no temporary file" "0" "$(find "$R/usr" "$R/etc" -name '.helper-update.*.tmp' | wc -l | tr -d ' ')"
done

echo "== helper-update R12: re-install only: no seed, no notice-bot.env, no helper: refused before any call =="
for rmv in etc/himmel/afk-sudo/totp.seed etc/himmel/afk-sudo/notice-bot.env usr/local/libexec/himmel/afk-sudo; do
    hu_root r12 stale; rm -f "$R/$rmv"
    assert_contains "RED R12: without $rmv the op is failed" "result=failed" "$(hu_chk)"
    assert_eq "R12: and made no curl call ($rmv)" "0" "$(curl_n)"
done

echo "== helper-update R15/R16: a tag named main, a downgrade =="
hu_root r15; gh_edit "d['newest'].insert(0, dict(d['newest'][0], head_sha='$HU_NEWER'))"
assert_contains "RED R15: a newer run under a tag named main refuses, never passes" "result=failed" "$(hu_chk)"
hu_root r16 stale; gh_edit "d['compare']['$HU_OLD...$HU_MAIN']['status'] = 'behind'"
out=$(hu_chk)
assert_contains "RED R16: older than the installed commit is failed" "older than the installed commit" "$out"
assert_contains "R16: the helper files nothing" "result=check-failed" "$(hu_req 0)"

echo "== helper-update R17/R23: the hourly rate and the lock =="
hu_root r17; hu_record "$HU_MAIN"
for i in 1 2 3 4; do HIMMEL_OPS_NOW=$((T0 + i)) hu_chk >/dev/null; done
n0=$(curl_n)
out=$(HIMMEL_OPS_NOW=$((T0 + 10)) hu_chk)
assert_contains "RED R17: the fifth call in the hour is rate-refused" "rate" "$out"
assert_eq "R17: the refused call made no curl call" "$n0" "$(curl_n)"
out=$(HIMMEL_OPS_NOW=$((T0 + 3700)) hu_chk)
assert_contains "R17: an hour later it runs" "nothing differs" "$out"
hu_root r23
( flock 9; sleep 8 ) 9> "$R/var/lib/himmel/afk-sudo/helper-update.lock" &
LOCKPID=$!; STUBS="${STUBS:-} $LOCKPID"; sleep 0.5
s0=$(date +%s); out=$(hu_chk); s1=$(date +%s)
assert_contains "RED R23: a held lock is busy" "busy" "$out"
assert_eq "R23: busy within 6 s" "yes" "$([ $((s1 - s0)) -le 6 ] && echo yes || echo no)"
assert_eq "R23: busy made no curl call" "0" "$(curl_n)"
wait $LOCKPID 2>/dev/null

echo "== helper-update R18/C1: kill, restore, and a restore that is itself killed =="
hu_root r18a stale; before=$(hu_state); printf sleep > "$R/gh/variant"
out=$(hu_req 0); id=$(rid "$out"); out=$(hu_approve_read 3 "$id")
assert_contains "RED R18: an installer killed by the timeout is rolled back" "rolled back" "$out"
assert_eq "R18: the timeout kill leaves the station as it was" "$before" "$(hu_state)"
hu_root r18b stale; before=$(hu_state)
out=$(hu_req 0); id=$(rid "$out")
HIMMEL_OPS_KILL_AT=installed hu_approve_read 3 "$id" >/dev/null
assert_eq "RED R18: a killed run leaves its marker" "yes" "$([ -e "$R/$HU_PEND" ] && echo yes || echo no)"
assert_eq "R18: and the installed files changed" "no" "$([ "$before" = "$(hu_state)" ] && echo yes || echo no)"
out=$(hu_chk)
assert_contains "RED R18: the next call restores an interrupted run" "restored an interrupted run" "$out"
assert_eq "R18: the restore puts libexec, sudoers and config back" "$before" "$(hu_state)"
assert_eq "R18: the marker is gone" "no" "$([ -e "$R/$HU_PEND" ] && echo yes || echo no)"
for clock in real back; do
    hu_root r18c stale; before=$(hu_state); printf broken-afk-sudo > "$R/gh/variant"
    paths_before=$(hu_state libexec | cut -d' ' -f1)
    out=$(hu_req 0); id=$(rid "$out")
    if [ "$clock" = back ]; then
        HIMMEL_OPS_NOW=$(( $(date +%s) - 400 )) HIMMEL_OPS_KILL_AT=restore:1 hu_approve_read 3 "$id" >/dev/null
    else
        HIMMEL_OPS_KILL_AT=restore:1 hu_approve_read 3 "$id" >/dev/null
    fi
    assert_eq "RED R18 ($clock clock): a killed restore leaves the marker" "yes" "$([ -e "$R/$HU_PEND" ] && echo yes || echo no)"
    assert_contains "C1 ($clock clock): the marker says it is restoring" '"restoring": true' "$(cat "$R/$HU_PEND" 2>/dev/null)"
    assert_eq "R18 ($clock clock): no installed path went missing in the half restore" "" "$(comm -23 <(printf '%s\n' "$paths_before") <(hu_state libexec | cut -d' ' -f1))"
    out=$(hu_chk)
    assert_contains "RED C1 ($clock clock): the resumed restore finishes, it is not superseded" "restored an interrupted run" "$out"
    assert_eq "RED C1 ($clock clock): the tree and the sudoers line are back to the pre-update state" "$before" "$(hu_state)"
    assert_eq "C1 ($clock clock): the marker is gone" "no" "$([ -e "$R/$HU_PEND" ] && echo yes || echo no)"
done

echo "== helper-update R19: a lockdown during the run =="
hu_root r19a stale; before=$(hu_state libexec sudoers); printf lockdown-fail > "$R/gh/variant"
out=$(hu_req 0); id=$(rid "$out"); out=$(hu_approve_read 3 "$id")
assert_contains "R19: a failed installer after a lockdown is rolled back" "rolled back" "$out"
assert_eq "RED R19: the rollback never undoes the lockdown" "False" "$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["enabled"])' "$R/etc/himmel/afk-sudo.json")"
assert_eq "R19: libexec and sudoers are as they were" "$before" "$(hu_state libexec sudoers)"
hu_root r19b stale; printf lockdown-row > "$R/gh/variant"
out=$(hu_req 0); id=$(rid "$out"); out=$(hu_approve_read 3 "$id")
assert_contains "RED R19: a lockdown row during a run that left enabled true is flagged" "LOCKDOWN-DURING-RUN" "$out"

echo "== helper-update R20: a changed floor needs a terminal =="
hu_root r20 stale
printf '# older floor\n' >> "$R/gh/$HU_OLD/scripts/lib/afk-sudo/never_remote.py"
hu_terminal "$HU_OLD"; hu_record "$HU_OLD"
gh_edit "d['compare']['$HU_OLD...$HU_MAIN']['files'].append('scripts/lib/afk-sudo/never_remote.py')"
before=$(hu_state)
out=$(hu_req 0); id=$(rid "$out")
assert_contains "RED R20: the notice carries WARN never_remote.py" "WARN never_remote.py" "$(cat "$TG"/*.txt 2>/dev/null)"
out=$(hu_approve_read 3 "$id")
assert_contains "RED R20: the approved run is refused as a floor change" "floor-change" "$out"
assert_eq "R20: libexec, sudoers and config are unchanged" "$before" "$(hu_state)"

echo "== helper-update R21: a sudoers form other than the fixed one is rolled back =="
for v in wider-line extra-file sudoers-main; do
    hu_root r21 stale; before=$(hu_state); printf '%s' "$v" > "$R/gh/variant"
    out=$(hu_req 0); id=$(rid "$out"); out=$(hu_approve_read 3 "$id")
    assert_contains "RED R21: $v is rolled back" "rolled back" "$out"
    assert_eq "R21: $v leaves sudoers, libexec and config as they were" "$before" "$(hu_state)"
done

echo "== helper-update R22: the 400-character line =="
hu_root r22 stale; hu_record "$HU_OLD"
printf '# new installer\n' >> "$R/gh/$HU_MAIN/scripts/lib/afk-sudo/install.sh"; cp "$R/gh/$HU_MAIN/scripts/lib/afk-sudo/install.sh" "$R/checkout/scripts/lib/afk-sudo/install.sh"
gh_edit "d['compare']['$HU_OLD...$HU_MAIN']['files'].append('scripts/lib/afk-sudo/install.sh')"
out=$(hu_chk)
assert_contains "RED R22: a changed install.sh is a would-change" "result=would-change" "$out"
assert_contains "R22: the detail starts WARN install.sh" "detail=WARN install.sh" "$out"
assert_contains "R22: and names afk-sudo/install.sh" "afk-sudo/install.sh" "$out"
hu_root r22b stale
for i in $(seq 1 40); do
    printf 'x%s\n' "$i" > "$R/gh/$HU_MAIN/scripts/station-ops/extra-$i.txt"; cp "$R/gh/$HU_MAIN/scripts/station-ops/extra-$i.txt" "$R/checkout/scripts/station-ops/"
done
L39=$(printf 'a%.0s' $(seq 1 39))
gh_edit "d['repo'] = 'abcdefghijklmn/abcdefghijklmn'; [r['head_repository'].update(full_name=d['repo']) for r in d['runs']['$HU_MAIN'] + d['newest']]; d['compare']['$HU_OLD...$HU_MAIN']['ahead_by'] = 12345; d['compare']['$HU_OLD...$HU_MAIN']['files'] = ['scripts/station-ops/file-%03d.sh' % i for i in range(300)]; d['compare']['$HU_MAIN...$HU_MAIN']['message'] = 'a very long subject with \"quotes\" and | bars and more words to cut'; d['pull']['77'] = {'user': {'login': '$L39'}, 'merged_by': {'login': '$L39'}}; d['reviews']['77'] = [{'user': {'login': '$L39'}, 'state': 'APPROVED'}, {'user': {'login': 'b2'}, 'state': 'APPROVED'}, {'user': {'login': 'b3'}, 'state': 'APPROVED'}]"
hu_cfg 'd["helper_update"]["repo"] = "abcdefghijklmn/abcdefghijklmn"'
out=$(hu_chk); det=$(hu_detail "$out")
assert_eq "R22: the worst-case detail is at most 400 characters" "yes" "$([ "${#det}" -le 400 ] && [ "${#det}" -gt 100 ] && echo yes || echo no)"
assert_contains "R22: a long login shows 15 characters and ~" "aaaaaaaaaaaaaaa~" "$det"
assert_contains "R22: one approver and +2" "approved by aaaaaaaaaaaaaaa~+2" "$det"
assert_contains "R22: the count" "many commits" "$det"
assert_contains "R22: the file names end with +<j> more" " more |" "$det"
assert_contains "R22: the subject shows ' for a double quote" "with 'quot" "$det"
assert_absent "R22: no bar from the subject forges a field" "| bars" "$det"
assert_eq "R22: the detail is ASCII" "" "$(printf '%s' "$det" | LC_ALL=C tr -d ' -~')"
hu_root r22c stale; rm -f "$R/var/lib/himmel/afk-sudo/helper-commit"
out=$(hu_chk); det=$(hu_detail "$out")
assert_contains "RED R22: with no record the detail starts WARN no baseline" "WARN no baseline, install.sh unseen" "$det"
assert_contains "R22: with no record the link is the tree of the commit" "https://github.com/t/h/tree/${HU_MAIN:0:12}/scripts/lib/afk-sudo" "$det"
assert_contains "R22: with no record the count reads ? commits" "? commits" "$det"
assert_contains "R22: with no record the notice says installed commit unknown" "installed commit unknown" "$det"

echo "== helper-update R24: a record that no longer matches libexec reads as none =="
hu_root r24 stale
printf '# manual install since\n' >> "$R/usr/local/libexec/himmel/approval_broker.py"
out=$(hu_chk)
assert_contains "RED R24: a stale record is named" "record stale" "$out"
assert_contains "R24: and the installed commit is unknown" "installed commit unknown" "$out"
assert_contains "R24: and there is no baseline" "WARN no baseline, install.sh unseen" "$out"
assert_eq "R24: no compare against the recorded commit" "0" "$(grep -c "compare/$HU_OLD\\.\\.\\." "$R/curl.log")"

echo "== helper-update R26/C2: a later install wins over an interrupted run =="
kill_run() {
    printf '%s' "$1" > "$R/gh/variant"
    local out id; out=$(hu_req 0); id=$(rid "$out")
    HIMMEL_OPS_NOW=$(( $(date +%s) - 400 )) HIMMEL_OPS_KILL_AT=installed hu_approve_read 3 "$id" >/dev/null
}
for tree in "$HU_MAIN" "$HU_OLDER"; do
    hu_root r26 stale; kill_run base; hu_terminal "$tree"; after=$(hu_state)
    out=$(hu_chk)
    assert_contains "RED R26: a later install ($tree) makes the interrupted run superseded" "superseded by a later install; nothing restored" "$out"
    assert_eq "R26: nothing was restored over the later install" "$after" "$(hu_state)"
    assert_eq "R26: the marker is retired" "no" "$([ -e "$R/$HU_PEND" ] && echo yes || echo no)"
    assert_eq "R26: and kept as superseded" "1" "$(find "$R/var/lib/himmel/afk-sudo" -maxdepth 1 -name 'helper-update.superseded.*' | wc -l | tr -d ' ')"  # gnu-ok: Linux-only suite
    assert_absent "R26: a clean superseded verdict names no sudoers leftover" "sudoers NOT rolled back" "$out"
    assert_contains "R26: the next --check reads the record as stale" "record stale" "$(hu_chk)"
done
hu_root r26c stale; before=$(hu_state)
printf wider-line > "$R/gh/variant"; out=$(hu_req 0); id=$(rid "$out")
HIMMEL_OPS_KILL_AT=installed hu_approve_read 3 "$id" >/dev/null
out=$(hu_chk)
assert_contains "RED R26: a killed run whose installer wrote a wider line is restored" "restored an interrupted run" "$out"
assert_contains "R26: and the unexpected write is named" "unexpected:" "$out"
assert_contains "R26: with the sudoers file" "sudoers.d/himmel-afk-sudo" "$out"
assert_eq "R26: the wider line is gone" "$before" "$(hu_state)"
hu_root r26d stale; before=$(hu_state)
out=$(hu_req 0); id=$(rid "$out"); HIMMEL_OPS_KILL_AT=installed hu_approve_read 3 "$id" >/dev/null
assert_contains "R26 control: with no later install the same kill is restored" "restored an interrupted run" "$(hu_chk)"
hu_root r26e stale; kill_run extra-file; hu_terminal "$HU_MAIN"
out=$(hu_chk)
assert_contains "R26: a superseded run is still superseded" "superseded by a later install" "$out"
assert_contains "RED C2: a superseded verdict names the sudoers file it did not roll back" "sudoers NOT rolled back: /etc/sudoers.d/zz-extra" "$out"

echo "== helper-update R27: the restore comes before the rate =="
hu_root r27 stale
out=$(hu_req 0); id=$(rid "$out"); HIMMEL_OPS_KILL_AT=installed hu_approve_read 3 "$id" >/dev/null
now=$(date +%s); printf '%s\n%s\n%s\n%s\n' "$now" "$now" "$now" "$now" > "$R/var/lib/himmel/afk-sudo/helper-update.rate"
n0=$(curl_n)
out=$(hu_chk)
assert_contains "RED R27: a pending marker is restored with the rate spent" "restored an interrupted run" "$out"
assert_eq "R27: the restore made no curl call" "$n0" "$(curl_n)"
assert_contains "R27: the call after it is rate-refused" "rate" "$(hu_chk)"

echo "== helper-update judge fixes: a rewritten bytecode cache is not a later install =="
hu_root pyc stale
mkdir -p "$R/usr/local/libexec/himmel/__pycache__"; printf 'old-bytecode' > "$R/usr/local/libexec/himmel/__pycache__/approval_broker.cpython-3.pyc"
before=$(hu_state); base=$(date +%s)
out=$(hu_req 0); id=$(rid "$out")
HIMMEL_OPS_NOW=$((base - 292)) HIMMEL_OPS_KILL_AT=installed hu_approve_read 3 "$id" >/dev/null
while [ "$(date +%s)" -lt $((base + 16)) ]; do sleep 1; done
printf 'new-bytecode' > "$R/usr/local/libexec/himmel/__pycache__/approval_broker.cpython-3.pyc"
out=$(hu_chk)
assert_contains "RED: the helper rewriting its .pyc after the deadline is not a later install" "restored an interrupted run" "$out"
assert_eq "the restore puts everything back, the bytecode cache included" "$before" "$(hu_state)"

echo "== helper-update judge fixes: a snapshot copy that fails its hash is never renamed live =="
hu_root badcopy stale
out=$(hu_req 0); id=$(rid "$out")
HIMMEL_OPS_KILL_AT=installed hu_approve_read 3 "$id" >/dev/null
printf 'CORRUPT' >> "$R"/var/lib/himmel/afk-sudo/helper-update/stage.*/prev/root/usr/local/libexec/himmel/approval_broker.py
out=$(hu_chk)
assert_contains "RED: a corrupt snapshot copy is reported, not installed" "restore incomplete" "$out"
assert_eq "the live broker keeps the installed bytes, not the corrupt copy" "yes" "$(cmp -s "$R/gh/$HU_MAIN/scripts/lib/afk-sudo/approval_broker.py" "$R/usr/local/libexec/himmel/approval_broker.py" && echo yes || echo no)"

echo "== helper-update judge fixes: a special file in the snapshot is reported, not opened =="
hu_root fifo stale
mkfifo "$R/usr/local/libexec/himmel/ops/odd"
out=$(hu_req 0); id=$(rid "$out")
HIMMEL_OPS_KILL_AT=installed hu_approve_read 3 "$id" >/dev/null
out=$(hu_chk)
assert_contains "RED: a snapshot row of type o is reported as not restorable" "restore incomplete: ops/odd" "$out"
assert_absent "the restore does not crash on it" "internal error" "$out"

echo "== helper-update C3: names from the commit never reach the notice as a field =="
hu_root c3
gh_edit "d.setdefault('tree_extra', {}).setdefault('$HU_MAIN', []).append({'path': 'scripts/station-ops/x | PR #9 by evil', 'mode': '100644', 'type': 'blob', 'sha': '5'*40, 'size': 3})"
out=$(hu_chk)
assert_contains "RED C3: a file name with a bar is refused" "result=failed" "$out"
assert_absent "C3: the forged field never reaches the line" "| PR #9" "$out"
hu_root c3b; : > "$R/checkout/scripts/station-ops/a|b c"
out=$(hu_chk)
assert_contains "C3: a checkout name is sanitized in the refusal" "a?b?c" "$out"
assert_absent "C3: and its bar is not in the line" "a|b" "$out"

echo "== the station ops and the size-override signer are CI trust paths =="
TP_PATS="$tmp/trust-pats.txt"
grep -Ev '^[[:space:]]*(#|$)' "$REPO_ROOT/scripts/ci/ci-trust-paths.txt" > "$TP_PATS"
trust_hit() { printf '%s\n' "$1" | grep -E -f "$TP_PATS" >/dev/null 2>&1 && echo yes || echo no; }
for tp in scripts/station-ops/size-approval.sh scripts/station-ops/size-approval.json scripts/station-ops/helper-update.sh \
    scripts/station-ops/test-station-ops.sh scripts/handover/chief-kit/size-override.sh scripts/handover/chief-kit/test-size-override.sh; do
    assert_eq "RED: $tp matches a trust-path pattern" "yes" "$(trust_hit "$tp")"
done
for tp in scripts/handover/chief-kit/size-override.sh.bak scripts/handover/chief-kit/size-overrides.sh scripts/handover/chief-kit/gen-briefs.py \
    docs/station-ops/notes.md scripts/other/station-ops/x.sh; do
    assert_eq "negative control: $tp matches no trust-path pattern" "no" "$(trust_hit "$tp")"
done

echo "test summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
