#!/usr/bin/env bash
# Tests for scripts/lib/afk-sudo/afk_sudo.py, the root helper that runs one
# allowlisted privileged command after a Telegram TOTP approval.
# Usage: bash scripts/lib/test-afk-sudo.sh
# Hermetic: every case builds its own sandbox root through the helper's
# AFK_SUDO_ROOT and AFK_SUDO_NOW seams (honoured only when euid != 0) and a fake
# systemctl that records its argv; nothing privileged runs.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
# shellcheck source=scripts/lib/portable-timeout.sh
. "$REPO_ROOT/scripts/lib/portable-timeout.sh"
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
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$3"; fi; }

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
    printf '{"enabled": true, "operator_id": %s, "window_s": 120, %s"operator_user": "%s", "run": {"enabled": %s, "ttl_s": 900, "timeout_s": %s}, "classes": {"systemctl-restart": {"argv": ["%s/bin/systemctl", "restart", "{unit}"], "unit": ["himmel-test.service"]}}%s}\n' \
        "$OP" "$1" "$me" "$2" "${TMO:-60}" "$R" "${3:-}" > "$R/etc/himmel/afk-sudo.json"
}
# The seam turns the run kind on with AFK_SUDO_RUN=1; the installed helper (euid 0) never reads it.
hr() { local off="$1"; shift; AFK_SUDO_RUN=1 h "$off" "$@"; }
rr() { local off="$1"; shift; hr "$off" run-request --session S1 --ticket HIMMEL-8067 --blocked-by classifier "$@" </dev/null; }
approve_r() { AFK_SUDO_RUN=1 approve "$@"; }
# cfg_class_user <user>: make the one class run as <user> (the default is root).
cfg_class_user() { python3 -I -c 'import json, sys; c = json.load(open(sys.argv[1])); c["classes"]["systemctl-restart"]["run_as"] = sys.argv[2]; json.dump(c, open(sys.argv[1], "w"))' "$R/etc/himmel/afk-sudo.json" "$1"; }
# cfg_drop_operator: remove operator_user from the sandbox config (a partial config).
cfg_drop_operator() { python3 -I -c 'import json, sys; c = json.load(open(sys.argv[1])); del c["operator_user"]; json.dump(c, open(sys.argv[1], "w"))' "$R/etc/himmel/afk-sudo.json"; }
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
new_root argv0gone; cfg "$ALL" true
printf '#!/bin/sh\nexit 0\n' > "$R/bin/mytool"; chmod 0755 "$R/bin/mytool"
out=$(rr 0 -- "$R/bin/mytool"); id=$(rid "$out")
rm -f "$R/bin/mytool"
assert_contains "an argv0 removed after the request reports changed" "result=changed" "$(approve_r 3 "$id" "$(code 3)")"
new_root filegone; cfg "$ALL" true
printf 'echo hi\n' > "$R/x.sh"
out=$(rr 0 --cwd "$R" -- sh x.sh); id=$(rid "$out")
rm -f "$R/x.sh"
assert_contains "a file argument removed after the request reports changed" "result=changed" "$(approve_r 3 "$id" "$(code 3)")"
new_root cwdgone; cfg "$ALL" true
mkdir "$R/work"; printf 'echo hi\n' > "$R/work/x.sh"
out=$(rr 0 --cwd "$R/work" -- sh x.sh); id=$(rid "$out")
rm -rf "$R/work"
assert_contains "a cwd removed after the request reports changed" "result=changed" "$(approve_r 3 "$id" "$(code 3)")"
new_root cwdswap; cfg "$ALL" true
mkdir "$R/work"; printf 'echo hi\n' > "$R/work/x.sh"
out=$(rr 0 --cwd "$R/work" -- sh x.sh); id=$(rid "$out")
mv "$R/work" "$R/work.old"; mkdir "$R/work"; cp "$R/work.old/x.sh" "$R/work/x.sh"
assert_contains "a cwd replaced by another directory (same files) reports changed" "result=changed" "$(approve_r 3 "$id" "$(code 3)")"

echo "== slice 1a: the file binding fails closed =="
new_root bindfile; cfg "$ALL" true
mkfifo "$R/fifo.p"; ln -s /proc/self/stat "$R/lnk.p"
assert_contains "an argument under /dev is refused at request, not skipped" "result=bad-file" "$(rr 0 -- cat /dev/zero)"
assert_contains "an argument under /proc is refused" "result=bad-file" "$(rr 1 -- cat /proc/self/status)"
assert_contains "a link into /proc is refused" "result=bad-file" "$(rr 2 --cwd "$R" -- cat lnk.p)"
assert_contains "a FIFO, which cannot be hashed, is refused" "result=bad-file" "$(rr 3 --cwd "$R" -- cat fifo.p)"
out=$(rr 4 -- cat /dev/null); id=$(rid "$out")
assert_contains "/dev/null stays allowed" "result=pending" "$out"
h 5 deny "$id" --from "$OP" --chat "$OP" >/dev/null
out=$(rr 6 -- ls "$R"); id=$(rid "$out")
assert_contains "a directory argument is not bound" "result=pending" "$out"
assert_contains "and its run goes ahead" "result=ran" "$(approve_r 33 "$id" "$(code 33)")"
new_root bindreal; cfg "$ALL" true
mkdir -p "$R/real/sub"; printf 'echo REAL\n' > "$R/real/x.sh"; ln -s "$R/real/sub" "$R/lnk"
out=$(rr 0 --cwd "$R" -- sh lnk/../x.sh); id=$(rid "$out")
printf 'echo CHANGED\n' > "$R/real/x.sh"
assert_contains "link/../x binds the file the kernel opens, not the lexical path" "result=changed" "$(approve_r 3 "$id" "$(code 3)")"
new_root bindnew; cfg "$ALL" true
out=$(rr 0 --cwd "$R" -- sh later.sh); id=$(rid "$out")
printf 'echo hi\n' > "$R/later.sh"
assert_contains "an argument that named no file at request and names one at exec reports changed" "result=changed" "$(approve_r 3 "$id" "$(code 3)")"

echo "== slice 1a (judge KS-j4307-1): what is hashed is what runs, and every element keeps its target =="
new_root argv0lnk; cfg "$ALL" true
mkdir -p "$R/real/sub"
printf '#!/bin/sh\ntouch "%s/ran-real"\n' "$R" > "$R/real/x"; printf '#!/bin/sh\ntouch "%s/ran-lexical"\n' "$R" > "$R/x"
chmod 0755 "$R/real/x" "$R/x"; ln -s "$R/real/sub" "$R/lnk"
out=$(rr 0 --cwd "$R" -- "$R/lnk/../x"); id=$(rid "$out")
approve_r 3 "$id" "$(code 3)" >/dev/null
ran=""
if [ -e "$R/ran-real" ]; then ran="real"; fi
if [ -e "$R/ran-lexical" ]; then ran="$ran lexical"; fi
assert_eq "argv[0] link/../x runs the file the kernel opens (the one hashed), not the lexical path" "real" "$ran"
new_root tgtctl; cfg "$ALL" true
printf 'one\n' > "$R/one.txt"; ln -s "$R/one.txt" "$R/a"
out=$(rr 0 --cwd "$R" -- cat a); id=$(rid "$out")
assert_contains "control: a link left alone still runs" "result=ran" "$(approve_r 3 "$id" "$(code 3)")"
new_root tgtdir; cfg "$ALL" true
printf 'one\n' > "$R/one.txt"; mkdir "$R/evil"; ln -s "$R/one.txt" "$R/a"
out=$(rr 0 --cwd "$R" -- cat a); id=$(rid "$out")
ln -sfn "$R/evil" "$R/a"
assert_contains "a link to a file that now resolves to a directory reports changed" "result=changed" "$(approve_r 3 "$id" "$(code 3)")"
new_root tgtnone; cfg "$ALL" true
printf 'one\n' > "$R/one.txt"; ln -s "$R/one.txt" "$R/a"
out=$(rr 0 --cwd "$R" -- cat a); id=$(rid "$out")
ln -sfn "$R/nothing" "$R/a"
assert_contains "a link to a file that now resolves to nothing reports changed" "result=changed" "$(approve_r 3 "$id" "$(code 3)")"
new_root tgtswap; cfg "$ALL" true
printf 'one\n' > "$R/one.txt"; printf 'two\n' > "$R/two.txt"; ln -s "$R/one.txt" "$R/a"; ln -s "$R/two.txt" "$R/b"
out=$(rr 0 --cwd "$R" -- cat a b); id=$(rid "$out")
ln -sfn "$R/two.txt" "$R/a"; ln -sfn "$R/one.txt" "$R/b"
assert_contains "two links swapped between their files report changed" "result=changed" "$(approve_r 3 "$id" "$(code 3)")"
new_root tgtdirs; cfg "$ALL" true
mkdir "$R/d1" "$R/d2"; ln -s "$R/d1" "$R/d"
out=$(rr 0 --cwd "$R" -- ls d); id=$(rid "$out")
ln -sfn "$R/d2" "$R/d"
assert_contains "a link to a directory retargeted to another directory reports changed" "result=changed" "$(approve_r 3 "$id" "$(code 3)")"
new_root tgtabsctl; cfg "$ALL" true
mkdir "$R/safe"; printf 'job\n' > "$R/job"; ln -s "$R/safe" "$R/d"
out=$(rr 0 --cwd "$R" -- cp job d/out); id=$(rid "$out")
assert_contains "control: an absent output name that stays absent under an untouched link still runs" "result=ran" "$(approve_r 3 "$id" "$(code 3)")"
new_root tgtabs; cfg "$ALL" true
mkdir "$R/safe" "$R/elsewhere"; printf 'job\n' > "$R/job"; ln -s "$R/safe" "$R/d"
out=$(rr 0 --cwd "$R" -- cp job d/out); id=$(rid "$out")
ln -sfn "$R/elsewhere" "$R/d"
assert_contains "an absent name under a directory link that is retargeted reports changed" "result=changed" "$(approve_r 3 "$id" "$(code 3)")"
landed=no
if [ -e "$R/elsewhere/out" ]; then landed=yes; fi
assert_eq "nothing was written through the retargeted link" "no" "$landed"
new_root tgtdangle; cfg "$ALL" true
mkdir "$R/d" "$R/elsewhere"; printf 'job\n' > "$R/job"
out=$(rr 0 --cwd "$R" -- cp job d/out); id=$(rid "$out")
ln -s "$R/elsewhere/out" "$R/d/out"
assert_contains "an absent name that becomes a dangling link reports changed" "result=changed" "$(approve_r 3 "$id" "$(code 3)")"
new_root tgtdangle2; cfg "$ALL" true
mkdir "$R/d" "$R/e1" "$R/e2"; printf 'job\n' > "$R/job"; ln -s "$R/e1/out" "$R/d/out"
out=$(rr 0 --cwd "$R" -- cp job d/out); id=$(rid "$out")
ln -sfn "$R/e2/out" "$R/d/out"
assert_contains "a dangling link that is retargeted reports changed" "result=changed" "$(approve_r 3 "$id" "$(code 3)")"
# long_tree: under $R, L leads to a directory whose resolved path passes PATH_MAX, through two links whose
# targets each fit (L, then L/x). In it: safe, elsewhere, last -> safe, script.sh and sh -> /etc/shadow.
long_tree() {
    python3 -I -c '
import os, sys
r, n = sys.argv[1], "a" * 200
k = os.pathconf("/", "PC_PATH_MAX") // 2 // (len(n) + 1) + 1
os.chdir(r)
for _ in range(2 * k):
    os.mkdir(n)
    os.chdir(n)
os.mkdir("safe")
os.mkdir("elsewhere")
os.symlink("safe", "last")
os.symlink("/etc/shadow", "sh")
with open("script.sh", "w") as f:
    f.write("touch ran-long\n")
half = "/".join([n] * k)
os.symlink(half, os.path.join(r, "L"))
os.symlink(half, os.path.join(r, half, "x"))
' "$R"
}
# bt <element>: the target key the helper records for an element in cwd $R, or BadFile when it refuses to bind it.
bt() { python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import afk_sudo as a
try:
    print(a.target_key(a.bind_target(sys.argv[3], sys.argv[2])))
except a.BadFile:
    print("BadFile")' "$LIB" "$R" "$@"; }
new_root tgtlong; cfg "$ALL" true
long_tree
assert_eq "an absent name behind a path that passes PATH_MAX is refused, not keyed as the string realpath returned" "BadFile" "$(bt L/x/last/out)"
new_root tgtlongfile; cfg "$ALL" true
long_tree
assert_eq "a script behind a path that passes PATH_MAX is refused, not left unhashed" "BadFile" "$(bt L/x/script.sh)"
new_root tgtlongfloor; cfg "$ALL" true
long_tree
assert_contains "a floor target behind a path that passes PATH_MAX fails closed" "rule=oversize" "$(rr 0 --cwd "$R" -- cat L/x/sh)"
new_root tgtglued; cfg "$ALL" true
mkdir "$R/safe" "$R/elsewhere"; printf 'job\n' > "$R/job"; ln -s "$R/safe" "$R/d"
out=$(rr 0 --cwd "$R" -- dd if=job of="$R/d/out"); id=$(rid "$out")
ln -sfn "$R/elsewhere" "$R/d"
assert_contains "pin, documented: a glued of=path element is keyed by its lexical string, so a link above it moved after the request is not seen" "result=ran" "$(approve_r 3 "$id" "$(code 3)")"
new_root tgtlongtext; cfg "$ALL" true
prog=$(python3 -I -c 'print("x" * 4000 + "/" + "y" * 85)')
assert_contains "control: a word with a component over 255 characters (a python -c program) is filed, not refused" "result=pending" "$(rr 0 --cwd "$R" -- python3 -c "$prog")"

echo "== slice 1a (judge KS-j4307-1): a partial config never falls back to root's home =="
new_root opghost; me_real=$me; me=ghost-operator; cfg "$ALL" true; me=$me_real
assert_contains "operator_user that does not resolve: a root run is bad-user at request" "result=bad-user" "$(rr 0 --as root -- true)"
new_root opmissing; cfg "$ALL" true; cfg_drop_operator
assert_contains "operator_user missing: a root run is bad-user at request" "result=bad-user" "$(rr 0 --as root -- true)"
new_root opmissingcls; cfg '' true; cfg_drop_operator
assert_contains "operator_user missing, allowlist: a class that runs as root is bad-user at request" "result=bad-user" "$(rr 0 -- systemctl restart himmel-test.service)"
new_root opgone; cfg "$ALL" true
out=$(rr 0 --as root -- true); id=$(rid "$out")
cfg_drop_operator
assert_contains "operator_user removed after the request: the exec re-check is bad-user, not a root run" "result=bad-user" "$(approve_r 3 "$id" "$(code 3)")"

echo "== slice 1a (judge KS-j4307-1): a binary file argument is not an error =="
new_root elfarg; cfg "$ALL" true
printf '/usr/bin/x\0\177ELF\0/\0' > "$R/elf.bin"
out=$(rr 0 --cwd "$R" -- cat "$R/elf.bin")
assert_contains "a small binary file (a word with / and NUL) given as an absolute path is filed" "result=pending" "$out"

echo "== slice 1a: the executor re-checks what can move after the request =="
new_root exshipped; cfg "$ALL" true
out=$(rr 0 -- true); id=$(rid "$out")
assert_contains "exec time: a run filed in the seam is refused when the run kind is no longer shipped" "result=run-not-shipped" "$(approve 3 "$id" "$(code 3)")"
new_root exdisabled; cfg "$ALL" true
out=$(rr 0 -- true); id=$(rid "$out")
cfg "$ALL" false
assert_contains "exec time: run.enabled turned off after the request is refused" "result=run-disabled" "$(approve_r 3 "$id" "$(code 3)")"
new_root exmode; cfg "$ALL" true
out=$(rr 0 -- true); id=$(rid "$out")
cfg '' true
assert_contains "exec time: a station switched to allowlist refuses a free-form argv" "result=not-in-class" "$(approve_r 3 "$id" "$(code 3)")"
new_root exuser; cfg "$ALL" true
out=$(rr 0 -- true); id=$(rid "$out")
me_real=$me; me=ghost-operator; cfg "$ALL" true; me=$me_real
assert_contains "exec time: an operator_user changed after the request is bad-user" "result=bad-user" "$(approve_r 3 "$id" "$(code 3)")"
new_root exuser2; cfg "$ALL" true
out=$(rr 0 -- true); id=$(rid "$out")
me_real=$me; me=nobody; cfg "$ALL" true; me=$me_real
assert_contains "exec time: a run_as that is no longer the operator (another real user now is) is bad-user" "result=bad-user" "$(approve_r 3 "$id" "$(code 3)")"
new_root thirduser; cfg '' true
cfg_class_user nobody
assert_contains "allowlist: a class that names a third user is bad-user at request" "result=bad-user" "$(rr 0 -- systemctl restart himmel-test.service)"
new_root extimeout; TMO=1 cfg "$ALL" true
out=$(rr 0 -- sleep 30); id=$(rid "$out")
assert_contains "the run timeout kills the command with exit 124" "exit=124" "$(approve_r 3 "$id" "$(code 3)")"
out=$(rr 31 -- sh -c 'exec 1>&- 2>&-; sleep 30'); id=$(rid "$out")
assert_contains "a command that closed its pipes and kept running is killed too" "exit=124" "$(approve_r 33 "$id" "$(code 33)")"
new_root excap; cfg "$ALL" true
out=$(rr 0 -- sh -c 'head -c 300000 /dev/zero'); id=$(rid "$out")
approve_r 3 "$id" "$(code 3)" >/dev/null
assert_contains "output past the cap is still counted" "stdout_bytes=300000" "$(h 4 run-result "$id")"
assert_eq "output is kept up to 256 KiB" 262144 "$(h 4 run-result "$id" --stream stdout | wc -c | tr -d ' ')"
cat > "$tmp/exec-nosetpriv.py" <<'EXECNOSP'
import json, sys
sys.path.insert(0, sys.argv[1])
import afk_sudo as s
cfg = json.load(open(s.CONFIG))
s.SEAM = False  # act as the installed helper: outside the seam a missing setpriv is a refusal
s.RUN_KIND_SHIPPED = True
s.setpriv_path = lambda: None
print(s.execute_run({"id": sys.argv[2], "hash": s.rec_hash(s.load_record(sys.argv[2]))}, cfg)["result"])
EXECNOSP
new_root exnosetpriv; cfg "$ALL" true
out=$(rr 0 -- touch "$R/ranmark"); id=$(rid "$out")
assert_contains "exec time: a non-root run without setpriv is refused" "no-setpriv" "$(AFK_SUDO_ROOT="$R" python3 -I "$tmp/exec-nosetpriv.py" "$LIB" "$id")"
if [ ! -e "$R/ranmark" ]; then pass "exec time: the refused run did not run"; else fail "exec time: the refused run ran"; fi
new_root badcfg
printf '[]\n' > "$R/etc/himmel/afk-sudo.json"
out=$(h 0 mode)
assert_contains "a config that is JSON but not an object is a clean error" "result=error" "$out"
assert_absent "and not a traceback" "Traceback" "$out"

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
    # no-setpriv is refused only outside the seam (not SEAM); inside it the request is filed and the run keeps the caller's uid.
    assert_contains "in the seam a run is filed without setpriv" "result=pending" "$(rr 0 -- id -u)"
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
nr() { timeout 20 python3 -I -c'import sys; sys.path.insert(0, sys.argv[1]); import never_remote as n; print(n.check(sys.argv[3:], [], sys.argv[2], "/home/op") or "none")' "$LIB" /work "$@"; }
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
# the floor reads paths as the kernel does (realpath, so a link resolves before ..) and splits every argv element
expect_rule disk-wipe rm -rf '/etc/*'
expect_rule disk-wipe rm -rf '/home/op/*'
ln -s /usr/bin "$tmp/usrlnk"
expect_rule disk-wipe rm -rf "$tmp/usrlnk/.."
expect_rule disk-wipe awk 'BEGIN{system("wipefs -a /dev/vdb")}'
expect_rule disk-wipe env -S 'echo x; mkfs.ext4 /dev/vdb'
expect_rule none awk 'BEGIN{print 1}'
expect_rule none rm -rf /tmp/build/x/y
crafted=$(printf '"a=%.0s' $(seq 1 200))x
expect_rule oversize true "$crafted"

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
    # FAKE_LOSE=1: the stored result vanishes after the command ran.
    [ -z "${FAKE_LOSE:-}" ] || rm -f "$FAKE_R/var/lib/himmel/afk-sudo/results/$2.json"
fi
run_helper "$now" "$@"
FAKESUDO2
chmod +x "$FAKE2/sudo"
# ar <now-offset> <afk-run args>: sets ARRC, ARLAST (the last stderr line); FAKE_ACTION picks what the operator does.
ar() {
    local off=$1; shift
    PATH="$FAKE2:$PATH" FAKE_R="$R" FAKE_LIB="$LIB" FAKE_HELPER="$HELPER" FAKE_OP="$OP" FAKE_NOW=$((T0 + off)) \
        AFK_RUN_POLL_S=1 AFK_RUN_BUSY_EVERY_S=1 AFK_RUN_WAIT_S=2 \
        bash "$REPO_ROOT/scripts/lib/afk-run" "$@" > "${AR_OUT:-$tmp/ar.out}" 2> "$tmp/ar.err" < /dev/null
    ARRC=$?
    ARLAST=$(tail -n 1 "$tmp/ar.err")
}
AR=(--session S1 --ticket HIMMEL-8067 --blocked-by classifier)
new_root arun; cfg "$ALL" true
ar 3 "${AR[@]}" -- sh -c 'exit 3'
assert_eq "RED 6: afk-run exits with the command's status" 3 "$ARRC"
if [[ $ARLAST =~ ^afk-run:\ status=ran:3\ id=[a-z2-7]{8}$ ]]; then pass "RED 6: the last stderr line is status=ran:3 with the id"; else fail "RED 6: the last stderr line" "$ARLAST"; fi
ar 33 "${AR[@]}" -- sh -c 'echo relayed; echo errrelayed >&2'
assert_eq "afk-run exits 0 for a command that exits 0" 0 "$ARRC"
assert_contains "afk-run prints the captured stdout" "relayed" "$(cat "$tmp/ar.out")"
assert_contains "afk-run prints the captured stderr" "errrelayed" "$(cat "$tmp/ar.err")"
assert_contains "the last stderr line names the status" "status=ran:0" "$ARLAST"
new_root arlost; cfg "$ALL" true
FAKE_LOSE=1 ar 3 "${AR[@]}" -- sh -c 'echo lostout'
assert_contains "afk-run says so when the stored output cannot be read" "output could not be read" "$(cat "$tmp/ar.err")"
assert_absent "a lost result does not leak the helper's reply into stdout" "result=" "$(cat "$tmp/ar.out")"
assert_contains "a lost output keeps the command's own status" "status=ran:0" "$ARLAST"
new_root arfull; cfg "$ALL" true
AR_OUT=/dev/full ar 3 "${AR[@]}" -- sh -c 'echo fullout'
assert_contains "afk-run says so when it cannot relay the stored stdout" "stdout output could not be read or relayed" "$(cat "$tmp/ar.err")"
new_root ardeny; cfg "$ALL" true
FAKE_ACTION=deny ar 3 "${AR[@]}" -- true
assert_eq "a denied run exits 3" 3 "$ARRC"
assert_contains "a denied run says so on the last line" "status=denied" "$ARLAST"
new_root arexp; cfg "$ALL" true
FAKE_ACTION=expire ar 3 "${AR[@]}" -- true
assert_eq "an expired run exits 4" 4 "$ARRC"
assert_contains "an expired run says so on the last line" "status=expired" "$ARLAST"
new_root arref; cfg "$ALL" true
ar 3 "${AR[@]}" -- bash -c 'mkfs.ext4 /dev/vdb'
assert_eq "a refused run exits 5" 5 "$ARRC"
assert_contains "a refused run names the result" "afk-run: status=refused:never-remote" "$ARLAST"
assert_absent "a refused run has no id" "id=" "$ARLAST"
new_root arpend; cfg "$ALL" true
FAKE_ACTION=none ar 3 "${AR[@]}" -- true
assert_eq "a run still pending at the end of the wait exits 75" 75 "$ARRC"
assert_contains "a pending run says so with its id" "status=pending id=" "$ARLAST"
FAKE_ACTION=none ar 4 "${AR[@]}" -- true
assert_eq "a busy helper exits 76" 76 "$ARRC"
assert_contains "a busy run says nothing was filed" "afk-run: status=busy, nothing filed" "$ARLAST"
if [ -x "$REPO_ROOT/scripts/lib/afk-run" ]; then pass "afk-run is executable"; else fail "afk-run is not executable"; fi

echo "== slice 1a: root opens only a regular file outside /proc /sys /dev, links followed =="
mkfifo "$tmp/fifo.p"; printf x > "$tmp/reg.p"; ln -s /proc/self/stat "$tmp/lnk.p"; ln -s "$tmp/reg.p" "$tmp/okl.p"
# shellcheck disable=SC2016 # python source, not shell
OPENR='import sys; sys.path.insert(0, sys.argv[1]); import afk_sudo as s
for p in sys.argv[2:]:
    try:
        s.open_regular(p).close(); print("opened")
    except OSError:
        print("refused")'
OPENED=$(timeout 10 python3 -I -c "$OPENR" "$LIB" "$tmp/reg.p" "$tmp/okl.p" "$tmp/lnk.p" "$tmp/fifo.p" | tr '\n' ' ')
assert_contains "a regular file and a link to one open, a link into /proc and a FIFO are refused" "opened opened refused refused " "$OPENED"

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
