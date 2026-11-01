#!/usr/bin/env bash
# test-afk-approve.sh — `himmelctl approve <id>`, `himmelctl deny <id>` and `himmelctl approve status <id>`
# answer an AFK request from an SSH shell.
#
# WHY: after a classifier denial an operator working over SSH had no way to say "allow this one". The verb
# is a thin caller of the root afk-sudo helper: it must refuse a user who is not the config's operator_user
# before anything is sent, send only the config's own operator id plus --via ssh --approver, and hand the
# nonce and the TOTP code to the helper on stdin, never argv. The helper and broker (test-afk-sudo.sh) do
# every other check; this suite stubs the helper and reads what it was given.
#
# Hermetic: the config and the helper are stubs under a temp dir (HIMMELCTL_AFK_CONFIG and
# HIMMELCTL_AFK_SUDO); nothing runs sudo or reads /etc/himmel. Every nonce and code below is a fixture.
set -uo pipefail

root="$(git rev-parse --show-toplevel)"
# shellcheck source=scripts/himmelctl/test/_hermetic-home.sh
. "$root/scripts/himmelctl/test/_hermetic-home.sh"
node_bin="${NODE:-node}"
# HIMMELCTL_BIN lets the RED run point at a bin.js that predates the verbs.
bin="${HIMMELCTL_BIN:-$root/scripts/himmelctl/bin.js}"

PASS=0
FAIL=0
pass() { printf 'PASS - %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf 'FAIL - %s\n' "$1"; [ -n "${2:-}" ] && printf '       got: %s\n' "$2"; FAIL=$((FAIL+1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$3 (want $2)"; fi; }
assert_contains() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "$3" ;; esac; }
assert_absent() { case "$3" in *"$2"*) fail "$1" "$3" ;; *) pass "$1" ;; esac; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/test-afk-approve.XXXXXX")" || { echo "FAIL - mktemp"; exit 1; }
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home" "$tmp/cache"
me="$(id -un)"
OP=4242
NONCE=K7QF
CODE=482913

# The stub helper: records its argv (one element per line) and its stdin, answers STUB_OUT, exits STUB_RC.
cat > "$tmp/fake-helper" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FAKE_LOG.argv"
cat > "$FAKE_LOG.stdin"
printf '%s\n' "${STUB_OUT:-result=ran id=x exit=0}"
exit "${STUB_RC:-0}"
STUB
chmod 0755 "$tmp/fake-helper"
printf '{"operator_id": %s, "operator_user": "%s"}\n' "$OP" "$me" > "$tmp/config.json"
printf '{"operator_id": %s, "operator_user": "someone-else-%s"}\n' "$OP" "$$" > "$tmp/config-other.json"

# ctl <stdin-text> <config> args...: run himmelctl with the stubs; sets $out (stdout), $err (stderr), $rc.
ctl() {
  local input="$1" cfg="$2"; shift 2
  rm -f "$tmp/log.argv" "$tmp/log.stdin"
  printf '%s' "$input" | HOME="$(winpath "$tmp/home")" USERPROFILE="$(winpath "$tmp/home")" \
    HIMMELCTL_CACHE_DIR="$(winpath "$tmp/cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$tmp/cache/luna.json")" \
    HIMMELCTL_AFK_CONFIG="$cfg" HIMMELCTL_AFK_SUDO="$tmp/fake-helper" FAKE_LOG="$tmp/log" \
    "$node_bin" "$bin" "$@" > "$tmp/out" 2> "$tmp/err"
  rc=$?
  out="$(cat "$tmp/out")"; err="$(cat "$tmp/err")"
}
sent() { [ -e "$tmp/log.argv" ]; }
argv_line() { tr '\n' ' ' < "$tmp/log.argv"; }

ID1=abcdefgh
ID2=zyxwvu23

# --- approve ---
ctl "$NONCE $CODE
" "$tmp/config.json" approve "$ID1"
assert_eq "RED 1: himmelctl approve is a command and exits 0 when the helper does" "0" "$rc"
assert_eq "approve calls the helper with the config's operator id, via ssh and the user" \
  "approve $ID1 --from $OP --chat $OP --via ssh --approver $me " "$(argv_line)"
assert_eq "the nonce and the code reach the helper on stdin" "$NONCE $CODE" "$(cat "$tmp/log.stdin" | tr -d '\n')"
assert_absent "the code is not in the helper's argv" "$CODE" "$(argv_line)"
assert_absent "the nonce is not in the helper's argv" "$NONCE" "$(argv_line)"
assert_absent "the code is not printed" "$CODE" "$out$err"
assert_absent "the nonce is not printed" "$NONCE" "$out$err"
assert_contains "the helper's answer is shown" "result=ran" "$out"

ctl "k7qf 482 913
" "$tmp/config.json" approve "$ID1"
assert_eq "a spaced code is closed up for the helper and the nonce is passed as typed (root reads it any case)" "k7qf 482913" "$(tr -d '\n' < "$tmp/log.stdin")"

for bad in "" "482913" "K7QF" "K7QF 48291" "K7QF 4829133" "K7Q 482913" "K7QF 48291x"; do
  ctl "$bad
" "$tmp/config.json" approve "$ID1"
  if [ "$rc" = 2 ] && ! sent; then pass "RED 2: a reply of [$bad] is refused with rc 2 and nothing is sent"; else fail "RED 2: reply [$bad]" "rc=$rc sent=$(sent && echo yes || echo no)"; fi
done
for bad_id in "" short ABCDEFGH abcdefg1 abcdefghi; do
  ctl "$NONCE $CODE
" "$tmp/config.json" approve "$bad_id"
  if [ "$rc" = 2 ] && ! sent; then pass "an id of [$bad_id] is refused locally with rc 2"; else fail "id [$bad_id]" "rc=$rc"; fi
done

# --- who may use it ---
ctl "$NONCE $CODE
" "$tmp/config-other.json" approve "$ID1"
if [ "$rc" = 5 ] && ! sent; then pass "RED 3: a user who is not the operator_user is refused before anything is sent"; else fail "RED 3: non-operator approve" "rc=$rc"; fi
assert_contains "the refusal names the operator" "only the operator" "$err"
ctl "" "$tmp/config-other.json" deny "$ID1"
if [ "$rc" = 5 ] && ! sent; then pass "RED 3: a non-operator deny is refused before anything is sent"; else fail "RED 3: non-operator deny" "rc=$rc"; fi
ctl "$NONCE $CODE
" "$tmp/no-such-config.json" approve "$ID1"
if [ "$rc" = 5 ] && ! sent; then pass "a missing config means not installed, nothing sent"; else fail "missing config" "rc=$rc"; fi
printf '{"operator_id": "x", "operator_user": "%s"}\n' "$me" > "$tmp/config-badid.json"
ctl "$NONCE $CODE
" "$tmp/config-badid.json" approve "$ID1"
if [ "$rc" = 5 ] && ! sent; then pass "a config with no numeric operator id sends nothing"; else fail "bad operator id" "rc=$rc"; fi
printf '{"operator_id": %s}\n' "$OP" > "$tmp/config-nouser.json"
ctl "$NONCE $CODE
" "$tmp/config-nouser.json" approve "$ID1"
if [ "$rc" = 5 ] && ! sent; then pass "a config with no operator_user sends nothing"; else fail "no operator_user" "rc=$rc"; fi

# --- deny and status ---
ctl "" "$tmp/config.json" deny "$ID1"
assert_eq "RED 4: himmelctl deny exits 0 when the helper does" "0" "$rc"
assert_eq "deny calls the helper with the operator id, via ssh and the user" \
  "deny $ID1 --from $OP --chat $OP --via ssh --approver $me " "$(argv_line)"
assert_eq "deny sends nothing on stdin" "0" "$(wc -c < "$tmp/log.stdin" | tr -d ' ')"
ctl "" "$tmp/config-other.json" approve status "$ID1"
assert_eq "RED 5: approve status reads a request's state" "0" "$rc"
assert_eq "approve status passes only the verb and the id" "status $ID1 " "$(argv_line)"
ctl "" "$tmp/config.json" approve status
assert_eq "approve status with no id is a usage error" "2" "$rc"

# --- several pending ids, each its own call ---
ctl "$NONCE $CODE
" "$tmp/config.json" approve "$ID1"
first="$(argv_line)"
ctl "$NONCE $CODE
" "$tmp/config.json" approve "$ID2"
assert_contains "RED 6: two pending ids are answered one by one, the first" "approve $ID1 " "$first"
assert_contains "RED 6: two pending ids are answered one by one, the second" "approve $ID2 " "$(argv_line)"

# --- the helper's refusals come back as a failure ---
ctl "$NONCE $CODE
" "$tmp/config.json" approve "$ID1"
assert_eq "a helper that succeeds gives rc 0" "0" "$rc"
ctl_refused() { STUB_RC=5 STUB_OUT="$1" ctl "$NONCE $CODE
" "$tmp/config.json" approve "$ID1"; }
ctl_refused "result=bad-nonce id=$ID1"
assert_eq "RED 7: a helper refusal (bad-nonce) is rc 5" "5" "$rc"
assert_contains "the helper's reason is shown" "result=bad-nonce" "$out"
ctl_refused "result=disabled"
assert_eq "RED 8: a station with the feature off finds nothing to approve (rc 5)" "5" "$rc"
assert_contains "the disabled answer is shown" "result=disabled" "$out"
ctl_refused "result=hash-mismatch id=$ID1"
assert_eq "an approve of a changed command is refused (rc 5)" "5" "$rc"
assert_contains "the hash-mismatch reason is shown" "result=hash-mismatch" "$out"
mv "$tmp/fake-helper" "$tmp/fake-helper.gone"
ctl "$NONCE $CODE
" "$tmp/config.json" approve "$ID1"
assert_eq "a helper that cannot be run is rc 5" "5" "$rc"
mv "$tmp/fake-helper.gone" "$tmp/fake-helper"

# --- the masked prompt on a terminal ---
cat > "$tmp/tty-drive.py" <<'PYTTY'
import os, pty, select, sys, time
node, bin_, reply, envfile = sys.argv[1:5]
env = dict(l.rstrip("\n").split("=", 1) for l in open(envfile) if "=" in l)
pid, fd = pty.fork()
if pid == 0:
    os.execvpe(node, [node, bin_, "approve", "abcdefgh"], env)
buf = b""
sent = False
end = time.time() + 15
while time.time() < end:
    r, _, _ = select.select([fd], [], [], 0.2)
    if r:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        buf += chunk
    if not sent and b"Nonce Code:" in buf:
        os.write(fd, reply.encode() + b"\r")
        sent = True
bad = False
try:
    grace = time.time() + 5  # EOF on the pty can arrive just before the child is waitable
    done, status = os.waitpid(pid, os.WNOHANG)
    while not done and time.time() < grace:
        time.sleep(0.05)
        done, status = os.waitpid(pid, os.WNOHANG)
    if not done:
        os.kill(pid, 9)  # a verb that never exits after the reply must fail the row, not hang the suite
        os.waitpid(pid, 0)
        buf += b"\n[driver: the verb did not exit]"
        bad = True
    elif not (os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0):
        buf += b"\n[driver: the verb did not exit 0]"
        bad = True
except ChildProcessError:
    pass
sys.stdout.write(buf.decode("utf8", "replace"))
sys.exit(1 if bad else 0)
PYTTY
{
  printf 'HOME=%s\nUSERPROFILE=%s\nHIMMELCTL_CACHE_DIR=%s\nHIMMEL_LUNA_CONFIG_PATH=%s\n' \
    "$(winpath "$tmp/home")" "$(winpath "$tmp/home")" "$(winpath "$tmp/cache")" "$(winpath "$tmp/cache/luna.json")"
  printf 'HIMMELCTL_AFK_CONFIG=%s\nHIMMELCTL_AFK_SUDO=%s\nFAKE_LOG=%s\nPATH=%s\n' "$tmp/config.json" "$tmp/fake-helper" "$tmp/log" "$PATH"
} > "$tmp/tty.env"
rm -f "$tmp/log.argv" "$tmp/log.stdin"
tty_out="$(python3 -I "$tmp/tty-drive.py" "$node_bin" "$bin" "${NONCE}${CODE}" "$tmp/tty.env" 2>&1)"
assert_contains "RED 9: the terminal prompt asks for the nonce and the code" "Nonce Code:" "$tty_out"
assert_absent "the verb on a terminal exits on its own with status 0" "[driver: the verb did not exit" "$tty_out"
assert_absent "RED 9: the typed code is not echoed" "$CODE" "$tty_out"
assert_absent "RED 9: the typed nonce is not echoed" "$NONCE" "$tty_out"
assert_contains "RED 9: the prompt shows one bullet per key" "••••••••••" "$tty_out"
assert_eq "the masked reply reaches the helper on stdin" "$NONCE $CODE" "$(tr -d '\n' < "$tmp/log.stdin" 2>/dev/null)"
assert_absent "the masked reply is not in the helper's argv" "$CODE" "$(argv_line 2>/dev/null)"

# --- help ---
ctl "" "$tmp/config.json" --help
assert_contains "--help lists approve" "approve <id>" "$out"
assert_contains "--help lists deny" "deny <id>" "$out"

echo
echo "test summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
