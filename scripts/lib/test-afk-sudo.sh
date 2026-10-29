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
rid() { printf '%s\n' "$1" | sed -n 's/.*\bid=\([a-z2-7]*\).*/\1/p' | head -1; }
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

echo
echo "test summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
