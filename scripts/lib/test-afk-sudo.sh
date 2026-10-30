#!/usr/bin/env bash
# Tests for scripts/lib/afk-sudo/afk_sudo.py, the root helper that runs one
# allowlisted privileged command after a Telegram TOTP approval.
# Usage: bash scripts/lib/test-afk-sudo.sh
# Hermetic: every case builds its own sandbox root through the helper's
# AFK_SUDO_ROOT and AFK_SUDO_NOW seams (honoured only when euid != 0) and a fake
# systemctl that records its argv; nothing privileged runs.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LIB="$REPO_ROOT/scripts/lib/afk-sudo"
HELPER="$LIB/afk_sudo.py"
OP=4242
T0=1800000000

PASS=0
FAIL=0
pass() { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        got: %s\n' "$2"; FAIL=$((FAIL+1)); }
assert_contains() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "$3" ;; esac; }
assert_absent() { case "$3" in *"$2"*) fail "$1" "$3" ;; *) pass "$1" ;; esac; }

# The helper honours AFK_SUDO_ROOT only for a non-root euid, and refuses a
# group- or world-writable tree, so neither may come from the caller.
[ "$(id -u)" -ne 0 ] || { echo "FAIL: run as a non-root user (as root the helper reads the real /etc/himmel)"; exit 1; }
umask 022

tmp="$(mktemp -d "${TMPDIR:-/tmp}/afk-sudo-test.XXXXXX")" || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$tmp"' EXIT

# new_root <name> [enabled]: a sandbox station with one class, systemctl-restart
# of himmel-test.service, served by a fake systemctl (basename systemctl) that appends to ran.log.
new_root() {
    R="$tmp/$1"
    mkdir -p "$R/etc/himmel/afk-sudo" "$R/var/lib/himmel/afk-sudo" "$R/var/log/himmel" "$R/bin"
    printf '#!/bin/sh\necho "$@" >> "%s/ran.log"\nexit 7\n' "$R" > "$R/bin/systemctl"
    chmod 0755 "$R/bin/systemctl"
    python3 -I -c 'import base64, secrets; print(base64.b32encode(secrets.token_bytes(20)).decode())' > "$R/etc/himmel/afk-sudo/totp.seed"
    chmod 0600 "$R/etc/himmel/afk-sudo/totp.seed"
    printf '{"enabled": %s, "operator_id": %s, "window_s": 120, "classes": {"systemctl-restart": {"argv": ["%s/bin/systemctl", "restart", "{unit}"], "unit": ["himmel-test.service"]}}}\n' \
        "${2:-true}" "$OP" "$R" > "$R/etc/himmel/afk-sudo.json"
    chmod 0644 "$R/etc/himmel/afk-sudo.json"
    : > "$R/ran.log"
}

# h <now-offset> <verb> [args...]: run the helper in the current sandbox.
h() { local off="$1"; shift; AFK_SUDO_ROOT="$R" AFK_SUDO_NOW=$((T0 + off)) python3 -I "$HELPER" "$@" 2>&1; }
# approve <now-offset> <id> <code> [from]: the code goes on stdin, never argv.
approve() { printf '%s\n' "$3" | AFK_SUDO_ROOT="$R" AFK_SUDO_NOW=$((T0 + $1)) python3 -I "$HELPER" approve "$2" --from "${4:-$OP}" --chat "${4:-$OP}" 2>&1; }
# code <now-offset>: the TOTP the operator's authenticator shows at that time.
code() { python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import approval_broker as b; print(b.totp(open(sys.argv[2]).read().strip(), int(sys.argv[3]) // 30))' "$LIB" "$R/etc/himmel/afk-sudo/totp.seed" $((T0 + $1)); }
req() { h "$1" request --session S1 --ticket HIMMEL-8066 --cwd /work -- systemctl restart himmel-test.service; }
rid() { printf '%s\n' "$1" | sed -n 's/^result=[^ ]* id=\([a-z2-7]*\).*/\1/p' | head -1; }
ledger() { cat "$R/var/log/himmel/afk-sudo.jsonl" 2>/dev/null; }
runs() { wc -l < "$R/ran.log" | tr -d ' '; }

[ -f "$HELPER" ] || { echo "FAIL: $HELPER not found"; exit 1; }

echo "== off by default: enabled:false refuses every request =="
new_root disabled false
out=$(req 0)
assert_contains "a disabled station refuses the request" "result=disabled" "$out"
assert_absent "a disabled station issues no id" "id=" "$out"

echo "== a command off the allowlist is never approvable =="
new_root offlist
out=$(h 0 request --session S1 --ticket T --cwd /work -- systemctl restart sshd.service)
assert_contains "an unlisted unit is refused at request time" "result=off-allowlist" "$out"
out=$(h 0 request --session S1 --ticket T --cwd /work -- sh -c 'systemctl restart himmel-test.service')
assert_contains "a shell wrapper is refused at request time" "result=off-allowlist" "$out"
assert_contains "the refusal is in the ledger" '"result": "off-allowlist"' "$(ledger)"
out=$(req 1)
assert_contains "nothing was left pending by the refusals" "result=pending" "$out"

echo "== a valid code runs the command once and writes the ledger =="
new_root valid
out=$(req 0); id=$(rid "$out"); c=$(code 3)
assert_contains "the request is pending with an id" "result=pending" "$out"
assert_contains "the request text names the command" "himmel-test.service" "$out"
out=$(approve 3 "$id" "$c")
assert_contains "a valid code runs the command" "result=ran" "$out"
assert_contains "the command's own exit status is reported" "exit=7" "$out"
assert_contains "the fake systemctl got exactly the template argv" "restart himmel-test.service" "$(cat "$R/ran.log")"
assert_contains "the command ran once" "1" "$(runs)"
assert_contains "the ledger holds the request row" '"event": "request"' "$(ledger)"
assert_contains "the ledger holds the code-check row" '"result": "approved"' "$(ledger)"
assert_contains "the ledger holds the exit status" '"exit": 7' "$(ledger)"
assert_absent "the ledger never holds the code" "$c" "$(ledger)"
assert_contains "status reports the run" "result=ran:7" "$(h 4 status "$id")"
out=$(approve 4 "$id" "$c")
assert_contains "approving the same id again finds nothing" "result=no-pending" "$out"

echo "== a replayed code is refused =="
out=$(req 5); id2=$(rid "$out")
out=$(approve 6 "$id2" "$c")
assert_contains "the used code cannot approve a new request" "result=replay" "$out"
assert_contains "the command did not run again" "1" "$(runs)"

echo "== no code, a wrong code and an expired id all deny =="
new_root deny
out=$(req 0); id=$(rid "$out")
out=$(approve 1 "$id" "")
assert_contains "no code denies" "result=no-code" "$out"
out=$(approve 2 "$id" "$(code 2)")
assert_contains "the request is burned after no code" "result=no-pending" "$out"
out=$(req 40); id=$(rid "$out"); c=$(code 41)
wrong=$(printf '%06d' $(( (10#$c + 1) % 1000000 )))
out=$(approve 41 "$id" "$wrong")
assert_contains "a wrong code denies" "result=wrong-code" "$out"
out=$(approve 42 "$id" "$c")
assert_contains "the request is burned after a wrong code" "result=no-pending" "$out"
out=$(req 100); id=$(rid "$out")
out=$(approve 221 "$id" "$(code 221)")
assert_contains "an id past the 2-minute window denies" "result=expired" "$out"
assert_contains "no denied case ran the command" "0" "$(runs)"

echo "== a valid code refused before its check is spent =="
new_root spend
out=$(req 0); id=$(rid "$out")
out=$(approve 125 "$id" "$(code 125)")
assert_contains "a valid code on an expired id denies" "result=expired" "$out"
out=$(req 126); id=$(rid "$out")
out=$(approve 127 "$id" "$(code 125)")
assert_contains "the code sent to the expired id cannot approve the next request" "result=replay" "$out"
out=$(req 200); id=$(rid "$out")
out=$(approve 201 zzzzzzzz "$(code 201)")
assert_contains "a valid code on an unknown id denies" "result=no-pending" "$out"
out=$(req 202); id=$(rid "$out")
out=$(approve 203 "$id" "$(code 201)")
assert_contains "the code sent to the unknown id cannot approve the next request" "result=replay" "$out"
assert_contains "no spent code ran the command" "0" "$(runs)"
out=$(req 300); id=$(rid "$out")
out=$(approve 301 "$id" "١٢٣٤٥٦")
assert_contains "a code in non-ASCII digits is a wrong code, logged" "result=wrong-code" "$out"

echo "== only the operator can approve; deny works =="
new_root sender
out=$(req 0); id=$(rid "$out")
out=$(approve 1 "$id" "$(code 1)" 999)
assert_contains "another sender is refused" "result=not-operator" "$out"
out=$(h 2 deny "$id" --from "$OP" --chat "$OP")
assert_contains "the operator's deny is recorded" "result=denied" "$out"
assert_contains "status reports the deny" "result=denied" "$(h 3 status "$id")"
assert_contains "nothing ran" "0" "$(runs)"

echo "== one pending request at a time; rate and brute-force limits =="
new_root limits
out=$(req 0); id=$(rid "$out")
out=$(req 1)
assert_contains "a second request while one is pending is refused" "result=busy" "$out"
for n in 1 2 3; do
    approve $((n * 40)) "$id" 000000 >/dev/null
    out=$(req $((n * 40 + 1))); id=$(rid "$out")
done
assert_contains "three wrong codes lock the helper" "result=locked" "$out"
out=$(approve 200 "$id" "$(code 200)")
assert_contains "a locked helper refuses even a valid code" "result=locked" "$out"
new_root rate
for n in 1 2 3 4 5 6; do
    out=$(req "$n"); h "$n" deny "$(rid "$out")" --from "$OP" --chat "$OP" >/dev/null
done
out=$(req 10)
assert_contains "a seventh request inside an hour is rate-limited" "result=rate-limited" "$out"

echo "== the helper refuses an unsafe seed, config or ledger =="
new_root perms
chmod 0640 "$R/etc/himmel/afk-sudo/totp.seed"
assert_contains "a group-readable seed is refused" "result=unsafe-perms" "$(req 0)"
chmod 0600 "$R/etc/himmel/afk-sudo/totp.seed"
chmod 0666 "$R/etc/himmel/afk-sudo.json"
assert_contains "a world-writable config is refused" "result=unsafe-perms" "$(req 0)"
chmod 0644 "$R/etc/himmel/afk-sudo.json"
: > "$R/var/log/himmel/afk-sudo.jsonl"; chmod 0664 "$R/var/log/himmel/afk-sudo.jsonl"
assert_contains "a group-writable ledger is refused" "result=unsafe-perms" "$(req 0)"
chmod 0644 "$R/var/log/himmel/afk-sudo.jsonl"
mv "$R/etc/himmel/afk-sudo/totp.seed" "$R/seed.real"; ln -s "$R/seed.real" "$R/etc/himmel/afk-sudo/totp.seed"
assert_contains "a symlinked seed is refused" "result=unsafe-perms" "$(req 0)"
out=$(python3 -I "$HELPER" status abcdefgh 2>&1)
assert_contains "outside the sandbox seam a non-root run is refused" "result=not-root" "$out"

echo "== the request DM carries Approve and Deny buttons =="
FAKE="$tmp/fakebin"; mkdir -p "$FAKE"
cat > "$FAKE/sudo" <<'FAKESUDO'
#!/bin/sh
case "$3" in
    request) echo "result=pending id=abcdefgh expires=$(( $(date +%s) + 120 )) operator=4242"; echo "text=AFK sudo request abcdefgh" ;;
    status) echo "result=ran:0" ;;
esac
FAKESUDO
cat > "$FAKE/curl" <<'FAKECURL'
#!/bin/sh
printf '%s\n' "$@" > "$CURL_ARGS"
cat > "$CURL_STDIN"
FAKECURL
chmod +x "$FAKE/sudo" "$FAKE/curl"
printf 'TELEGRAM_BOT_TOKEN=123:SECRETTOKEN\n' > "$tmp/bridge.env"
req_out=$(PATH="$FAKE:$PATH" TELEGRAM_ENV="$tmp/bridge.env" CURL_ARGS="$tmp/curl.args" CURL_STDIN="$tmp/curl.stdin" \
    bash "$REPO_ROOT/scripts/lib/afk-sudo-request" --session s --ticket T -- /usr/bin/true 2>&1)
assert_contains "the request still waits and reports the run" "request abcdefgh ran, exit 0" "$req_out"
args=$(cat "$tmp/curl.args" 2>/dev/null)
assert_contains "the notice carries an inline keyboard" "reply_markup=" "$args"
assert_contains "the Approve button's callback data names the request" "afk:approve:abcdefgh" "$args"
assert_contains "the Deny button's callback data names the request" "afk:deny:abcdefgh" "$args"
assert_absent "the bot token never appears in curl's argv" "SECRETTOKEN" "$args"
assert_contains "the token reaches curl on stdin" "SECRETTOKEN" "$(cat "$tmp/curl.stdin" 2>/dev/null)"

echo "== slice 1a: a spent step stays spent for the next request (HIMMEL-8078 part 2) =="
for how in deny burn expire; do
    new_root "spent-$how"
    out=$(req 0); idA=$(rid "$out"); c=$(code 3)
    case "$how" in
        deny) h 3 deny "$idA" --from "$OP" --chat "$OP" >/dev/null; at=4 ;;
        burn) approve 3 zzzzzzzz "$c" >/dev/null; at=4 ;;
        expire) at=125; c=$(code 125) ;;
    esac
    out=$(req "$at"); idB=$(rid "$out")
    out=$(approve $((at + 1)) "$idB" "$c")
    assert_contains "a code valid for request A is refused for B after A is $how-ed in the same step" "result=replay" "$out"
    assert_contains "nothing ran after $how" "0" "$(runs)"
done

echo "== slice 1a: the run kind is compiled off; mode falls back to allowlist =="
me=$(id -un)
ALL='"mode": "all", '
# cfg <mode member or empty> <run.enabled> [extra members, leading comma]: rewrite the sandbox config.
cfg() {
    printf '{"enabled": true, "operator_id": %s, "window_s": 120, %s"operator_user": "%s", "run": {"enabled": %s, "ttl_s": 900, "timeout_s": 60}, "classes": {"systemctl-restart": {"argv": ["%s/bin/systemctl", "restart", "{unit}"], "unit": ["himmel-test.service"]}}%s}\n' \
        "$OP" "$1" "$me" "$2" "$R" "${3:-}" > "$R/etc/himmel/afk-sudo.json"
}
# The seam turns the run kind on with AFK_SUDO_RUN=1; the installed helper (euid 0) never reads it.
hr() { local off="$1"; shift; AFK_SUDO_RUN=1 h "$off" "$@"; }
rr() { local off="$1"; shift; hr "$off" run-request --session S1 --ticket HIMMEL-8067 --blocked-by classifier "$@" </dev/null; }
approve_r() { AFK_SUDO_RUN=1 approve "$@"; }
if grep -q '^RUN_KIND_SHIPPED = False$' "$HELPER"; then pass "the helper compiles RUN_KIND_SHIPPED as False"; else fail "RUN_KIND_SHIPPED is not the compiled False"; fi
new_root notshipped; cfg "$ALL" true
out=$(h 0 run-request --session S1 --ticket T --blocked-by classifier -- true </dev/null)
assert_contains "RED 10: mode all and run.enabled true still refuse the run kind on an installed helper" "result=run-not-shipped" "$out"
assert_contains "the mode verb reports the run kind as off" "run_enabled=false" "$(h 1 mode)"
out=$(rr 2 -- true)
assert_contains "the seam opt-in lets the run kind through" "result=pending" "$out"
new_root runoff; cfg "$ALL" false
assert_contains "run.enabled false refuses the run kind" "result=run-disabled" "$(rr 0 -- true)"
for m in '' '"mode": "ALL", ' '"mode": 1, ' '"mode": "allowlist", '; do
    new_root modefb; cfg "$m" true
    assert_contains "mode [$m] reads as allowlist" "mode=allowlist" "$(h 0 mode)"
    assert_contains "mode [$m] refuses an argv no class names" "result=not-in-class" "$(rr 1 -- true)"
done
new_root modeall; cfg "$ALL" true
assert_contains "mode all is read as all" "mode=all" "$(h 0 mode)"
new_root classrun; cfg '' true
out=$(rr 10 -- systemctl restart himmel-test.service); id=$(rid "$out")
out=$(approve_r 13 "$id" "$(code 13)")
assert_contains "allowlist mode still runs a class argv" "exit=7" "$out"
assert_contains "the class run used the class argv" "restart himmel-test.service" "$(cat "$R/ran.log")"

echo "== slice 1a: all mode runs one approved argv as the operator (RED 1, 2, 5) =="
new_root allmode; cfg "$ALL" true
out=$(rr 0 -- true); id=$(rid "$out")
assert_contains "all mode files a request for an argv no class names" "result=pending" "$out"
out=$(approve_r 3 "$id" "$(code 3)")
assert_contains "RED 1: the approved argv ran" "result=ran" "$out"
assert_contains "RED 1: it exited 0" "exit=0" "$out"
assert_contains "status reports the run" "result=ran:0" "$(h 4 run-status "$id")"
assert_contains "--as bob is refused" "result=bad-user" "$(rr 40 --as bob -- true)"
out=$(rr 41 --as root -- true)
assert_contains "--as root files a request" "result=pending" "$out"
assert_contains "the ledger names the root run" '"run_as": "root"' "$(ledger)"

new_root outp; cfg "$ALL" true
printf '#!/bin/sh\necho OUTBODY\necho ERRBODY >&2\nexit 4\n' > "$R/bin/mytool"; chmod 0755 "$R/bin/mytool"
printf 'STDINBODY\n' > "$R/in.txt"
out=$(hr 0 run-request --session S1 --ticket T --blocked-by hook:guard-x --why 'needs it' -- "$R/bin/mytool" < "$R/in.txt"); id=$(rid "$out")
out=$(approve_r 3 "$id" "$(code 3)")
assert_contains "the tool's own exit status is reported" "exit=4" "$out"
assert_contains "run-result gives the captured stdout" "OUTBODY" "$(h 4 run-result "$id" --stream stdout)"
assert_contains "run-result gives the captured stderr" "ERRBODY" "$(h 4 run-result "$id" --stream stderr)"
assert_contains "run-result gives the byte counts" "stdout_bytes=8" "$(h 4 run-result "$id")"
led=$(ledger)
assert_contains "the ledger names the kind" '"kind": "run"' "$led"
assert_contains "the ledger names what the classifier or hook blocked" '"blocked_by": "hook:guard-x"' "$led"
assert_contains "the ledger names the mode" '"mode": "all"' "$led"
assert_contains "the ledger holds the frozen hash" '"hash": "' "$led"
assert_contains "the ledger holds the argv0 sha256" '"argv0_sha256": "' "$led"
assert_contains "the ledger holds the stdin hash" '"stdin"' "$led"
assert_absent "the ledger never holds the output" "OUTBODY" "$led"
assert_absent "the ledger never holds the stdin body" "STDINBODY" "$led"
out=$(head -c 70000 /dev/zero | hr 100 run-request --session S1 --ticket T --blocked-by classifier -- cat)
assert_contains "a stdin over 64 KiB is refused" "result=stdin-too-large" "$out"

new_root edit; cfg "$ALL" true
cat > "$tmp/edit-record.py" <<'EDITREC'
import json, sys
path, marker = sys.argv[1], sys.argv[2]
rec = json.load(open(path))
rec["argv"] = ["touch", marker]
json.dump(rec, open(path, "w"))
EDITREC
out=$(rr 0 -- true); id=$(rid "$out")
python3 -I "$tmp/edit-record.py" "$R/var/lib/himmel/afk-sudo/records/$id.json" "$R/pwned"
out=$(approve_r 3 "$id" "$(code 3)")
assert_contains "RED 2: a record edited after the request is refused" "result=hash-mismatch" "$out"
if [ ! -e "$R/pwned" ]; then pass "RED 2: the edited argv did not run"; else fail "RED 2: the edited argv ran"; fi
assert_contains "the refusal is in the ledger" '"result": "hash-mismatch"' "$(ledger)"
assert_contains "status reports the refusal" "refused:hash-mismatch" "$(h 4 run-status "$id")"

new_root argv0; cfg "$ALL" true
printf '#!/bin/sh\nexit 0\n' > "$R/bin/mytool"; chmod 0755 "$R/bin/mytool"
out=$(rr 0 -- "$R/bin/mytool"); id=$(rid "$out")
printf '#!/bin/sh\nexit 9\n' > "$R/bin/mytool"
assert_contains "an argv0 changed after the request is refused" "result=changed" "$(approve_r 3 "$id" "$(code 3)")"
new_root filearg; cfg "$ALL" true
printf 'echo hi\n' > "$R/x.sh"
out=$(rr 0 --cwd "$R" -- sh x.sh); id=$(rid "$out")
printf 'echo changed\n' > "$R/x.sh"
assert_contains "a file argument changed after the request is refused" "result=changed" "$(approve_r 3 "$id" "$(code 3)")"

if [ "$(uname -s)" = Linux ] && command -v setpriv >/dev/null 2>&1; then
    new_root drop; cfg "$ALL" true
    out=$(rr 0 -- id -u); id=$(rid "$out")
    approve_r 3 "$id" "$(code 3)" >/dev/null
    u=$(h 4 run-result "$id" --stream stdout)
    if [ "$u" = "$(id -u)" ] && [ "$u" != 0 ]; then pass "RED 5: the run's uid is the operator's, not 0"; else fail "RED 5: the run's uid" "$u"; fi
    out=$(rr 31 -- sh -c 'grep NoNewPrivs /proc/self/status'); id=$(rid "$out")
    approve_r 33 "$id" "$(code 33)" >/dev/null
    assert_contains "RED 5: the run has NoNewPrivs set" "NoNewPrivs:1" "$(h 34 run-result "$id" --stream stdout | tr -d '[:space:]')"
else
    new_root drop; cfg "$ALL" true
    assert_contains "without setpriv a non-root run is refused" "result=no-setpriv" "$(rr 0 -- id -u)"
fi

echo "== slice 1a: the never-remote floor (RED 4) =="
new_root floor; cfg "$ALL" true
out=$(rr 0 -- bash -c 'mkfs.ext4 /dev/vdb')
assert_contains "RED 4: a mkfs inside bash -c is refused" "result=never-remote" "$out"
assert_contains "RED 4: the rule is disk-wipe" "rule=disk-wipe" "$out"
assert_absent "a refused run sends no notice text" "text=" "$out"
assert_contains "the refusal is ledgered" '"result": "never-remote"' "$(ledger)"
printf 'wipefs -a /dev/vdb\n' > "$R/x.sh"
out=$(rr 1 --cwd "$R" -- env sh x.sh)
assert_contains "RED 4: a wipefs held in a script file is refused" "rule=disk-wipe" "$out"
out=$(printf 'mkfs.ext4 /dev/vdb\n' | hr 2 run-request --session S1 --ticket T --blocked-by classifier -- sh)
assert_contains "a mkfs fed on stdin is refused" "rule=disk-wipe" "$out"
assert_contains "the refusals left nothing pending" "result=pending" "$(rr 3 -- true)"
new_root extra; cfg "$ALL" true ', "never_remote_extra": ["*secret-thing*", 5, null]'
assert_contains "never_remote_extra adds a rule" "rule=extra" "$(rr 0 -- echo secret-thing)"
assert_contains "a non-string never_remote_extra entry is ignored" "result=pending" "$(rr 1 -- echo fine)"
new_root execfloor; cfg "$ALL" true
out=$(rr 0 -- echo hello-extra); id=$(rid "$out")
cfg "$ALL" true ', "never_remote_extra": ["*hello-extra*"]'
out=$(approve_r 3 "$id" "$(code 3)")
assert_contains "the floor is checked again at exec with the current config" "rule=extra" "$out"
assert_contains "a refused exec is ledgered" '"result": "never-remote"' "$(ledger)"

# nr <argv...>: the rule the floor names for this argv in cwd /work as operator /home/op, else none.
nr() { python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import never_remote as n; print(n.check(sys.argv[3:], [], sys.argv[2], "/home/op") or "none")' "$LIB" /work "$@"; }
expect_rule() { local want=$1 got; shift; got=$(nr "$@"); if [ "$got" = "$want" ]; then pass "floor $want: $*"; else fail "floor $want: $*" "$got"; fi; }
expect_rule disk-wipe mkfs.ext4 /dev/vdb
expect_rule disk-wipe dd if=/dev/zero of=/dev/nvme0n1
expect_rule disk-wipe rm -rf /
expect_rule disk-wipe rm -rf '/*'
expect_rule disk-wipe rm -rf /usr
# shellcheck disable=SC2088,SC2016 # the fixtures are the literal ~ and $HOME words an agent would send
expect_rule disk-wipe rm -rf '~'
# shellcheck disable=SC2016 # the literal $HOME word
expect_rule disk-wipe rm -rf '$HOME'
expect_rule disk-wipe rm -rf /home/op
expect_rule disk-wipe btrfs subvolume delete '/@home'
expect_rule none rm -rf /tmp/build/x
expect_rule none ls /dev /dev/null
expect_rule none dd if=/dev/zero of=/tmp/img
expect_rule secret-read cat /etc/shadow
# shellcheck disable=SC2088,SC2016 # literal ~ and $HOME words, as above
expect_rule secret-read cat '~/.ssh/id_ed25519'
# shellcheck disable=SC2016 # the literal $HOME word
expect_rule secret-read sh -c 'cat $HOME/.claude/.credentials.json'
expect_rule secret-read cat /home/op/.claude/channels/telegram/.env
expect_rule secret-read secret-tool lookup service x
expect_rule secret-read gh auth token
expect_rule secret-read himmel-secrets get JIRA
expect_rule none cat /etc/hostname
# shellcheck disable=SC2088 # the literal ~ word
expect_rule none ls '~/.ssh'
expect_rule none gh pr list
# The force-push fixtures are the strings the hook's own test pins.
for s in refs/heads/main refs/heads/feat/x refs/heads/feat/y; do
    if grep -qF "$s" "$REPO_ROOT/scripts/hooks/test-check-no-force-push.sh"; then pass "the force-push fixture $s is in the hook's test"; else fail "the force-push fixture $s is gone from the hook's test"; fi
done
expect_rule main-history git push --force origin main
expect_rule main-history git push -f origin refs/heads/main
expect_rule main-history git push origin +main
expect_rule main-history git push origin :main
expect_rule main-history git push --delete origin main
expect_rule main-history gh api -X DELETE repos/o/r/git/refs/heads/main
expect_rule main-history gh repo delete o/r
expect_rule none git push origin main
expect_rule none git push --force origin refs/heads/feat/x:refs/heads/feat/y
expect_rule approval-system cat /etc/himmel/afk-sudo.json
expect_rule approval-system rm /usr/local/libexec/himmel/afk-sudo
expect_rule approval-system tee /etc/sudoers.d/x
expect_rule approval-system visudo
expect_rule approval-system bash scripts/lib/afk-sudo/install.sh
expect_rule none cat /etc/hosts
expect_rule none ls /var/lib/dpkg
expect_rule guards-off sed -i s/a/b/ /home/op/.claude/settings.local.json # gnu-ok: a fixture argv for the floor, never run
expect_rule guards-off cp x /repo/scripts/hooks/guard.sh
expect_rule guards-off claude --dangerously-skip-permissions
expect_rule guards-off env HIMMEL_EDIT_ON_MAIN_OK=1 true
expect_rule guards-off env FOO_BYPASS_X=1 true
expect_rule guards-off systemctl stop telegram-bridge
expect_rule none cat /repo/.claude/worktrees/w1/scripts/hooks/guard.sh
expect_rule none systemctl status telegram-bridge
expect_rule none ls /repo/scripts/lib

echo "== slice 1a: limits, the busy row and the retained files =="
new_root busyrow; cfg "$ALL" true
rr 0 -- true >/dev/null
assert_contains "a second run request while one is pending is busy" "result=busy" "$(rr 1 -- true)"
rr 2 -- true >/dev/null
assert_contains "two busy requests from one session leave one ledger row" "1" "$(ledger | grep -c '"result": "busy"')"
hr 3 run-request --session S2 --ticket T --blocked-by classifier -- true </dev/null >/dev/null
assert_contains "another session's busy request gets its own row" "2" "$(ledger | grep -c '"result": "busy"')"
new_root maxhr; cfg "$ALL" true ', "max_per_hour": 2'
for n in 1 2; do out=$(rr "$n" -- true); h "$n" deny "$(rid "$out")" --from "$OP" --chat "$OP" >/dev/null; done
assert_contains "max_per_hour lowers the hourly limit" "result=rate-limited" "$(rr 5 -- true)"
new_root ttl; cfg "$ALL" true
out=$(rr 0 -- true); id=$(rid "$out")
assert_contains "a run request outlives the 2-minute sudo window" "result=pending" "$(h 500 run-status "$id")"
assert_contains "a run request expires after run.ttl_s" "result=expired" "$(h 1000 run-status "$id")"
new_root prune; cfg "$ALL" true ', "max_per_hour": 30'
out=$(rr 0 -- true); first=$(rid "$out"); h 1 deny "$first" --from "$OP" --chat "$OP" >/dev/null
for n in $(seq 2 23); do out=$(rr "$n" -- true); h "$n" deny "$(rid "$out")" --from "$OP" --chat "$OP" >/dev/null; done
if [ ! -e "$R/var/lib/himmel/afk-sudo/records/$first.json" ]; then pass "the record of an id past the done window is pruned"; else fail "the record of an old id is still there"; fi
kept=$(find "$R/var/lib/himmel/afk-sudo/records" -type f | wc -l | tr -d ' ')
if [ "$kept" -le 21 ]; then pass "the records kept stay within the done window"; else fail "too many records kept" "$kept"; fi

echo "== slice 1a: afk-run waits for the operator and relays the result (RED 6) =="
FAKE2="$tmp/fakerun"; mkdir -p "$FAKE2"
cat > "$FAKE2/sudo" <<'FAKESUDO2'
#!/usr/bin/env bash
# fake sudo for afk-run ($1=-n $2=helper $3..=verb args): runs the real helper in the sandbox.
# At the first run-status poll of an id the "operator" acts: approve, deny or let it expire.
shift 2
run_helper() { local at=$1; shift; AFK_SUDO_ROOT="$FAKE_R" AFK_SUDO_NOW="$at" AFK_SUDO_RUN=1 python3 -I "$FAKE_HELPER" "$@"; }
now=$FAKE_NOW
if [ "$1" = run-status ] && [ ! -e "$FAKE_R/polled.$2" ]; then
    : > "$FAKE_R/polled.$2"
    case "${FAKE_ACTION:-approve}" in
        approve)
            python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import approval_broker as b; print(b.totp(open(sys.argv[2]).read().strip(), int(sys.argv[3]) // 30))' \
                "$FAKE_LIB" "$FAKE_R/etc/himmel/afk-sudo/totp.seed" "$now" | run_helper "$now" approve "$2" --from "$FAKE_OP" --chat "$FAKE_OP" >/dev/null ;;
        deny) run_helper "$now" deny "$2" --from "$FAKE_OP" --chat "$FAKE_OP" >/dev/null ;;
        expire) now=$((now + 1000)) ;;
    esac
fi
run_helper "$now" "$@"
FAKESUDO2
chmod +x "$FAKE2/sudo"
# ar <now-offset> <afk-run args>: sets ARRC, ARLAST (the last stderr line); FAKE_ACTION picks what the operator does.
ar() {
    local off=$1; shift
    PATH="$FAKE2:$PATH" FAKE_R="$R" FAKE_LIB="$LIB" FAKE_HELPER="$HELPER" FAKE_OP="$OP" FAKE_NOW=$((T0 + off)) \
        AFK_RUN_POLL_S=1 AFK_RUN_BUSY_EVERY_S=1 AFK_RUN_WAIT_S=2 \
        bash "$REPO_ROOT/scripts/lib/afk-run" "$@" > "$tmp/ar.out" 2> "$tmp/ar.err" < /dev/null
    ARRC=$?
    ARLAST=$(tail -n 1 "$tmp/ar.err")
}
AR=(--session S1 --ticket HIMMEL-8067 --blocked-by classifier)
new_root arun; cfg "$ALL" true
ar 3 "${AR[@]}" -- sh -c 'exit 3'
assert_contains "RED 6: afk-run exits with the command's status" "3" "$ARRC"
if [[ $ARLAST =~ ^afk-run:\ status=ran:3\ id=[a-z2-7]{8}$ ]]; then pass "RED 6: the last stderr line is status=ran:3 with the id"; else fail "RED 6: the last stderr line" "$ARLAST"; fi
ar 33 "${AR[@]}" -- sh -c 'echo relayed; echo errrelayed >&2'
assert_contains "afk-run exits 0 for a command that exits 0" "0" "$ARRC"
assert_contains "afk-run prints the captured stdout" "relayed" "$(cat "$tmp/ar.out")"
assert_contains "afk-run prints the captured stderr" "errrelayed" "$(cat "$tmp/ar.err")"
assert_contains "the last stderr line names the status" "status=ran:0" "$ARLAST"
new_root ardeny; cfg "$ALL" true
FAKE_ACTION=deny ar 3 "${AR[@]}" -- true
assert_contains "a denied run exits 3" "3" "$ARRC"
assert_contains "a denied run says so on the last line" "status=denied" "$ARLAST"
new_root arexp; cfg "$ALL" true
FAKE_ACTION=expire ar 3 "${AR[@]}" -- true
assert_contains "an expired run exits 4" "4" "$ARRC"
assert_contains "an expired run says so on the last line" "status=expired" "$ARLAST"
new_root arref; cfg "$ALL" true
ar 3 "${AR[@]}" -- bash -c 'mkfs.ext4 /dev/vdb'
assert_contains "a refused run exits 5" "5" "$ARRC"
assert_contains "a refused run names the result" "afk-run: status=refused:never-remote" "$ARLAST"
assert_absent "a refused run has no id" "id=" "$ARLAST"
new_root arpend; cfg "$ALL" true
FAKE_ACTION=none ar 3 "${AR[@]}" -- true
assert_contains "a run still pending at the end of the wait exits 75" "75" "$ARRC"
assert_contains "a pending run says so with its id" "status=pending id=" "$ARLAST"
FAKE_ACTION=none ar 4 "${AR[@]}" -- true
assert_contains "a busy helper exits 76" "76" "$ARRC"
assert_contains "a busy run says nothing was filed" "afk-run: status=busy, nothing filed" "$ARLAST"
if [ -x "$REPO_ROOT/scripts/lib/afk-run" ]; then pass "afk-run is executable"; else fail "afk-run is not executable"; fi

echo "== slice 1a: install.sh ships the floor and the new config keys =="
INSTALL="$LIB/install.sh"
# shellcheck disable=SC2016 # the install.sh text is matched literally, $LIBEXEC included
assert_contains "install.sh installs never_remote.py" 'never_remote.py" "$LIBEXEC/never_remote.py"' "$(cat "$INSTALL")"
# shellcheck disable=SC2016 # matched literally, as above
assert_contains "install.sh removes never_remote.py on uninstall" 'rm -f "$SUDOERS" "$LIBEXEC/afk-sudo" "$LIBEXEC/approval_broker.py" "$LIBEXEC/never_remote.py"' "$(cat "$INSTALL")"
assert_contains "the default config ships mode allowlist" '"mode": "allowlist"' "$(cat "$INSTALL")"
assert_contains "the default config ships the run block off" '"run": {"enabled": false' "$(cat "$INSTALL")"

echo "== install.sh prints hints that work on this platform =="
INSTALL="$LIB/install.sh"
STUBS="$tmp/stubs"; mkdir -p "$STUBS/linux" "$STUBS/mac" "$STUBS/linux-nano" "$STUBS/linux-micro" "$STUBS/linux-vi"
printf '#!/bin/sh\necho Linux\n' > "$STUBS/linux/uname"; printf '#!/bin/sh\necho Darwin\n' > "$STUBS/mac/uname"
for d in linux-nano linux-micro linux-vi; do cp "$STUBS/linux/uname" "$STUBS/$d/uname"; done
printf '#!/bin/sh\n' > "$STUBS/linux-nano/nano"; printf '#!/bin/sh\n' > "$STUBS/linux-micro/micro"; printf '#!/bin/sh\n' > "$STUBS/linux-vi/vi"
chmod +x "$STUBS"/*/*
printf 'NAME="CachyOS Linux"\nID=cachyos\nID_LIKE=arch\n' > "$tmp/os-arch"
printf 'NAME="Ubuntu"\nID=ubuntu\nID_LIKE=debian\n' > "$tmp/os-ubuntu"
printf 'NAME="Debian GNU/Linux"\nID=debian\n' > "$tmp/os-debian"
# hint <os-release> <stub dir> <fn...>: source install.sh with PATH holding only the stubs.
# PATH is narrowed to the stub dir on purpose, so a real vi/nano/qrencode cannot leak in.
# shellcheck disable=SC2123,SC2030,SC2031,SC1090
hint() { local osr=$1 stubs=$2; shift 2; ( PATH="$STUBS/$stubs"; export AFK_OS_RELEASE="$osr"; unset SUDO_EDITOR VISUAL EDITOR; source "$INSTALL" && "$@" ); }
assert_contains "arch (CachyOS) installs with pacman" "sudo pacman -S nano qrencode" "$(hint "$tmp/os-arch" linux pkg_hint nano qrencode)"
assert_contains "ubuntu installs with apt" "sudo apt install nano qrencode" "$(hint "$tmp/os-ubuntu" linux pkg_hint nano qrencode)"
assert_contains "debian installs with apt" "sudo apt install nano" "$(hint "$tmp/os-debian" linux pkg_hint nano)"
assert_contains "macOS installs with brew" "brew install nano qrencode" "$(hint "$tmp/os-arch" mac pkg_hint nano qrencode)"
assert_contains "with no editor and no nano/vim/micro the hint names SUDO_EDITOR and the package" "SUDO_EDITOR=nano sudoedit /etc/himmel/afk-sudo.json" "$(hint "$tmp/os-arch" linux enable_cmd)"
assert_contains "the no-editor hint says how to install one on arch" "sudo pacman -S nano" "$(hint "$tmp/os-arch" linux enable_cmd)"
assert_contains "with only micro installed SUDO_EDITOR picks micro" "SUDO_EDITOR=micro sudoedit" "$(hint "$tmp/os-arch" linux-micro enable_cmd)"
assert_contains "with nano installed SUDO_EDITOR picks nano" "SUDO_EDITOR=nano sudoedit" "$(hint "$tmp/os-arch" linux-nano enable_cmd)"
out=$(hint "$tmp/os-arch" linux-vi enable_cmd)
assert_absent "with vi present no SUDO_EDITOR override is printed" "SUDO_EDITOR" "$out"
assert_contains "with vi present plain sudoedit is printed" "sudoedit /etc/himmel/afk-sudo.json" "$out"
# shellcheck disable=SC2123,SC2030,SC2031,SC1090
out=$( ( PATH="$STUBS/linux"; export AFK_OS_RELEASE="$tmp/os-arch"; export EDITOR=nano; unset SUDO_EDITOR VISUAL; source "$INSTALL" && enable_cmd ) )
assert_absent "a set EDITOR keeps plain sudoedit" "SUDO_EDITOR" "$out"
assert_contains "a missing qrencode prints its install hint" "sudo pacman -S qrencode" "$(hint "$tmp/os-arch" linux qr_hint)"
printf '#!/bin/sh\n' > "$STUBS/linux-nano/qrencode"; chmod +x "$STUBS/linux-nano/qrencode"
assert_absent "a present qrencode prints nothing" "pacman" "$(hint "$tmp/os-arch" linux-nano qr_hint)"

echo
echo "test summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
