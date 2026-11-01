#!/usr/bin/env bash
# Tests for the OPS-1 station ops (cron-entry, cron-system, system-update) and the
# afk-sudo `op-request` verb that runs them. Usage: bash scripts/station-ops/test-station-ops.sh
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
trap 'rm -rf "$tmp"' EXIT

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
    -l) [ -f "$f" ] && cat "$f" || { echo "no crontab for $user" >&2; exit 1; } ;;
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
op() { local s="$1"; shift; HIMMEL_OPS_ROOT="$R" HIMMEL_OPS_BIN="$R/bin" bash "$R/usr/local/libexec/himmel/ops/$s.sh" --id testid00 --operator-user "$(id -un)" "$@" 2>&1; }
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
assert_contains "the pending op request reads denied" "result=denied" "$(h 2 status "$id")"
assert_contains "a locked-down station refuses a new op request" "result=disabled" "$(oreq 3 S2 cron-entry action=remove tag=ping)"

echo "== cron-system =="
new_root sys
f="$R/etc/cron.d/himmel-nightly"
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

echo "test summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
