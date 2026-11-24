#!/usr/bin/env bash
# test-vm-ssh-opts.sh — hermetic tests for scripts/lib/vm-ssh-opts.sh and for the five
# host-driven VM suites that use it. A fake `ssh` on PATH stands in for
# the VM; no real VM, no real HOME, no real known_hosts is touched.
# shellcheck disable=SC2015  # `[ test ] && pass || fail`: pass never fails
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
LIB="$HERE/vm-ssh-opts.sh"
failures=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

T="$(mktemp -d "${TMPDIR:-/tmp}/test-vm-ssh-opts.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home/.himmel" "$T/bin"
unset HIMMEL_VM_MODE_CONFIG HIMMEL_VMS_JSON

cat > "$T/bin/ssh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_SSH_LOG"
case "${FAKE_SSH_MODE:-}" in
  changed) printf '@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@\nHost key verification failed.\n' >&2; exit 255 ;;
  refused) echo 'himmel@localhost: Permission denied (publickey).' >&2; exit 255 ;;
  noroute) echo 'ssh: connect to host localhost port 2222: Connection timed out' >&2; exit 255 ;;
esac
exit 0
FAKE
chmod +x "$T/bin/ssh"

echo "== the helper"
if [ -f "$LIB" ]; then
    # shellcheck source=vm-ssh-opts.sh
    . "$LIB"
else
    fail "scripts/lib/vm-ssh-opts.sh exists"
    echo "FAILURES: $failures"; exit 1
fi

opts="$(HOME="$T/home" vm_ssh_opts 2222)"
case "$opts" in
    *"-o UserKnownHostsFile=~/.himmel/vm/known_hosts/ubuntu_new"*) pass "port 2222 pins the per-VM known_hosts of ubuntu_new" ;;
    *) fail "port 2222 pin missing: '$opts'" ;;
esac
case "$opts" in *"StrictHostKeyChecking=accept-new"*) pass "keeps accept-new" ;; *) fail "accept-new missing: '$opts'" ;; esac
[ -d "$T/home/.himmel/vm/known_hosts" ] && pass "the per-VM known_hosts directory exists" || fail "known_hosts dir not created"

mkdir -p "$T/blocked" && : > "$T/blocked/.himmel"
warn="$(HOME="$T/blocked" vm_ssh_opts 2222 2>&1 >/dev/null)"
case "$warn" in *"cannot create"*) pass "an uncreatable known_hosts directory is reported" ;; *) fail "no warning when the directory cannot be created: '$warn'" ;; esac

warn="$(HIMMEL_VMS_JSON="$T/absent.json" HOME="$T/home" vm_ssh_opts 2222 2>&1 >/dev/null)"
case "$warn" in *"cannot read the VM registry"*) pass "an unreadable VM registry is reported" ;; *) fail "no warning for an unreadable registry: '$warn'" ;; esac

opts="$(HOME="$T/home" vm_ssh_opts 2230)"
case "$opts" in *"known_hosts/himmel-gui-1"*) pass "port 2230 maps to himmel-gui-1" ;; *) fail "port 2230: '$opts'" ;; esac

opts="$(HOME="$T/home" vm_ssh_opts 9999)"
case "$opts" in *UserKnownHostsFile*) fail "an unknown port must not pin a file: '$opts'" ;; *) pass "an unknown port pins nothing" ;; esac

echo "== the error classes"
for pair in "changed|host key changed" "refused|key refused" "noroute|no route or timeout"; do
    mode="${pair%%|*}" want="${pair#*|}"
    err="$(FAKE_SSH_MODE=$mode PATH="$T/bin:$PATH" ssh -p 2222 h true 2>&1 >/dev/null)"
    msg="$(HOME="$T/home" vm_ssh_probe_report "$err" himmel@localhost 2222 /id 2>&1)"
    case "$msg" in *"$want"*) pass "$mode names '$want'" ;; *) fail "$mode: no '$want' in: $msg" ;; esac
    for other in "host key changed" "key refused" "no route or timeout"; do
        [ "$other" = "$want" ] && continue
        case "$msg" in *"$other"*) fail "$mode also names '$other'" ;; esac
    done
    case "$msg" in *"$(printf '%s' "$err" | head -n 1)"*) pass "$mode keeps ssh's own stderr" ;; *) fail "$mode dropped ssh stderr: $msg" ;; esac
done
msg="$(HOME="$T/home" vm_ssh_probe_report "weird failure" himmel@localhost 2222 /id 2>&1)"
case "$msg" in *"weird failure"*) pass "an unclassified error still prints ssh's text" ;; *) fail "unclassified: $msg" ;; esac

echo "== the default target carries the guest user"
out="$(HOME="$T/home" bash "$HERE/vm-mode.sh" target 2>&1)"
host="${out%%$'\t'*}"
[ "$host" = "himmel@localhost" ] && pass "local default target is himmel@localhost" || fail "default target host: '$out'"
route="$(HOME="$T/home" bash "$HERE/vm-mode.sh" route 2>&1)"
[ "$route" = "local-vm localhost:2222" ] && pass "route label is unchanged" || fail "route: '$route'"
printf '%s\n' '{"vm":{"mode":"remote","remote":{"ssh":"ops@vm.example","port":2201}}}' > "$T/home/.himmel/config.json"
out="$(HOME="$T/home" bash "$HERE/vm-mode.sh" target 2>&1)"
[ "${out%%$'\t'*}" = "ops@vm.example" ] && pass "a remote target is untouched" || fail "remote target: '$out'"
rm -f "$T/home/.himmel/config.json"

echo "== the five suites: pin the per-VM known_hosts, name the class, exit 3"
run_suite() {
    local suite="$1" mode="$2"
    : > "$T/ssh.log"
    SUITE_OUT="$(cd "$REPO" && HOME="$T/home" PATH="$T/bin:$PATH" FAKE_SSH_LOG="$T/ssh.log" FAKE_SSH_MODE="$mode" \
        UPGRADE_AST_GREP_VERSION=1.0.0 UPGRADE_GRAPHIFY_VERSION=1.0.0 UPGRADE_CLIPROXY_VERSION=1.0.0 \
        UPGRADE_CLIPROXY_SHA256=0000000000000000000000000000000000000000000000000000000000000000 \
        OVERINSTALL_BASE_REF=HEAD OVERINSTALL_CAND_REF=HEAD \
        bash "$suite" himmel@localhost 2222 "$T/home/.ssh/id_ed25519" 2>&1)"
    SUITE_RC=$?
}
for suite in scripts/test-install-symmetry-vm.sh scripts/test-luna-upgrade-vm.sh scripts/test-tarball-install-vm.sh \
             scripts/vm/upgrade-path-e2e.sh scripts/vm/over-install-e2e.sh; do
    for pair in "changed|host key changed" "refused|key refused" "noroute|no route or timeout"; do
        mode="${pair%%|*}" want="${pair#*|}"
        run_suite "$suite" "$mode"
        [ "$SUITE_RC" = 3 ] && pass "$suite $mode: exit 3" || fail "$suite $mode: rc=$SUITE_RC, want 3: $SUITE_OUT"
        case "$SUITE_OUT" in *"$want"*) pass "$suite $mode: names '$want'" ;; *) fail "$suite $mode: no '$want' in: $SUITE_OUT" ;; esac
    done
    if grep -q -- "-o UserKnownHostsFile=~/.himmel/vm/known_hosts/ubuntu_new" "$T/ssh.log"; then
        pass "$suite: ssh is pinned to the per-VM known_hosts"
    else
        fail "$suite: ssh not pinned; log: $(cat "$T/ssh.log")"
    fi
done

echo
if [ "$failures" -eq 0 ]; then echo "ALL PASSED"; else echo "FAILURES: $failures"; exit 1; fi
