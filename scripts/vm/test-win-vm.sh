#!/usr/bin/env bash
# test-win-vm.sh — hermetic coverage for scripts/vm/win-vm.sh.
# No real VM: a fake VBoxManage on VBOXMANAGE_PATH keeps a state file and a
# call log, and a throwaway lock dir stands in for /tmp.
#
# Platform guard (linux-only): a station-side harness around VBoxManage; no
# .ps1 twin needed (project convention: a documented guard suffices).
#
# Usage: bash scripts/vm/test-win-vm.sh
# shellcheck disable=SC2016  # bash -c bodies are single-quoted on purpose
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TOOL="$REPO_ROOT/scripts/vm/win-vm.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/test-win-vm.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

FAILED=0
pass() { echo "PASS $1"; }
fail_case() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

BIN="$WORK/bin"; mkdir -p "$BIN"
export FAKE_VBOX_CALLS="$WORK/calls"
export FAKE_VBOX_STATE="$WORK/state"
export FAKE_VBOX_SNAPS="$WORK/snaps"
cat > "$BIN/VBoxManage" <<'EOS'
#!/usr/bin/env bash
echo "$*" >> "${FAKE_VBOX_CALLS:?}"
case "$1" in
  showvminfo) echo "VMState=\"$(cat "$FAKE_VBOX_STATE")\"" ;;
  startvm) echo running > "$FAKE_VBOX_STATE" ;;
  controlvm) case "$3" in poweroff|acpipowerbutton) echo poweroff > "$FAKE_VBOX_STATE" ;; esac ;;
  snapshot)
    case "$3" in
      list) while read -r s; do echo "SnapshotName=\"$s\""; done < "$FAKE_VBOX_SNAPS" ;;
      take) echo "$4" >> "$FAKE_VBOX_SNAPS" ;;
    esac ;;
  guestcontrol) echo "guest-says-hello" ;;
esac
exit 0
EOS
chmod +x "$BIN/VBoxManage"

PASSFILE="$WORK/pw.txt"
printf 'S3cretValue\n' > "$PASSFILE"
chmod 600 "$PASSFILE"

reset() { : > "$FAKE_VBOX_CALLS"; echo poweroff > "$FAKE_VBOX_STATE"; printf 'clean-install\n' > "$FAKE_VBOX_SNAPS"; rm -rf "$WORK/locks"; mkdir -p "$WORK/locks"; }
tool() {
    VBOXMANAGE_PATH="$BIN/VBoxManage" WIN_VM_PASSFILE="$PASSFILE" WIN_VM_USER=tester WIN_VM_POLL=0 \
        HIMMEL_VM_LOCK_DIR="$WORK/locks" bash "$TOOL" "$@"
}

# T1: no VBOXMANAGE_PATH and no WIN_VM_LIVE -> refuse before any VBoxManage call
reset
out=$(env -u VBOXMANAGE_PATH -u WIN_VM_LIVE PATH="$BIN:$PATH" WIN_VM_PASSFILE="$PASSFILE" bash "$TOOL" status 2>&1); rc=$?
if [ "$rc" -ne 0 ] && [ ! -s "$FAKE_VBOX_CALLS" ] && echo "$out" | grep -q 'WIN_VM_LIVE'; then pass "T1 refuses without VBOXMANAGE_PATH or WIN_VM_LIVE"; else fail_case "T1 rc=$rc out=$out"; fi

# T2: status prints the state
reset
out=$(tool status 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "poweroff" ]; then pass "T2 status prints VMState"; else fail_case "T2 rc=$rc out=$out"; fi

# T3: restore on a running VM powers off first, then restores the named snapshot
reset; echo running > "$FAKE_VBOX_STATE"
tool restore adopter-baseline >/dev/null 2>&1; rc=$?
off=$(grep -n 'controlvm win11 poweroff' "$FAKE_VBOX_CALLS" | head -1 | cut -d: -f1)
rest=$(grep -n 'snapshot win11 restore adopter-baseline' "$FAKE_VBOX_CALLS" | head -1 | cut -d: -f1)
if [ "$rc" -eq 0 ] && [ -n "$off" ] && [ -n "$rest" ] && [ "$off" -lt "$rest" ]; then pass "T3 restore powers off before snapshot restore"; else fail_case "T3 rc=$rc off=$off rest=$rest"; fi

# T4: snapshot refuses an existing name and takes a new one
reset
tool snapshot clean-install >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ] && [ "$rc" -ne 127 ] && ! grep -q 'snapshot win11 take' "$FAKE_VBOX_CALLS"; then pass "T4a snapshot refuses an existing name"; else fail_case "T4a rc=$rc"; fi
reset
tool snapshot adopter-baseline >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'snapshot win11 take adopter-baseline' "$FAKE_VBOX_CALLS"; then pass "T4b snapshot takes a new name"; else fail_case "T4b rc=$rc"; fi
# a regex metacharacter in the name must not match another snapshot ('.' vs '-')
reset
tool snapshot clean.install >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'snapshot win11 take clean.install' "$FAKE_VBOX_CALLS"; then pass "T4c snapshot name compares literally"; else fail_case "T4c rc=$rc"; fi

# T5: run wraps in cmd.exe /c, authenticates by password FILE, never the password on argv or in output
reset
out=$(tool run -- ver 2>&1); rc=$?
call=$(grep '^guestcontrol' "$FAKE_VBOX_CALLS" | tail -1)
if [ "$rc" -eq 0 ] && echo "$out" | grep -q guest-says-hello \
   && echo "$call" | grep -q -- "--passwordfile $PASSFILE" \
   && echo "$call" | grep -q -- '-- cmd.exe /c ver' \
   && ! grep -rq S3cretValue "$FAKE_VBOX_CALLS" && ! echo "$out" | grep -q S3cretValue; then
    pass "T5 run uses cmd.exe /c and a password file"
else fail_case "T5 rc=$rc call=$call"; fi

# T6: up starts headless then probes the guest
reset
tool up >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'startvm win11 --type headless' "$FAKE_VBOX_CALLS" && grep -q '^guestcontrol' "$FAKE_VBOX_CALLS"; then pass "T6 up starts headless and probes the guest"; else fail_case "T6 rc=$rc"; fi

# T7: down uses the ACPI button and ends powered off
reset; echo running > "$FAKE_VBOX_STATE"
tool down >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'controlvm win11 acpipowerbutton' "$FAKE_VBOX_CALLS" && [ "$(cat "$FAKE_VBOX_STATE")" = poweroff ]; then pass "T7 down via ACPI"; else fail_case "T7 rc=$rc"; fi

# T8: a held lock refuses a lifecycle verb without touching VBoxManage
reset
HIMMEL_VM_LOCK_DIR="$WORK/locks" bash -c '. "$1"; vm_lock_acquire_waiting win11 && sleep 20' _ "$REPO_ROOT/scripts/vm/vm-lock.sh" &
holder=$!
sleep 1
out=$(tool restore adopter-baseline 2>&1); rc=$?
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
if [ "$rc" -ne 0 ] && [ "$rc" -ne 127 ] && ! grep -q 'snapshot win11 restore' "$FAKE_VBOX_CALLS"; then pass "T8 held lock refuses restore"; else fail_case "T8 rc=$rc out=$out"; fi

# T9: unknown verb is a usage error
reset
tool frobnicate >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then pass "T9 unknown verb exits 2"; else fail_case "T9 rc=$rc"; fi
reset
tool run --exe >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then pass "T9b run --exe without an operand exits 2"; else fail_case "T9b rc=$rc"; fi

# T10: the smoke cell restores, ships a bundle + the guest script, runs it under
# PowerShell 5.1 with the tag, maps a guest failure (33) to 1, and always cleans up.
reset
cat > "$BIN/fake-win-vm.sh" <<'EOS'
#!/usr/bin/env bash
echo "$*" >> "${FAKE_VBOX_CALLS:?}"
case "$1" in
  run) case "$*" in *USERPROFILE*) echo 'D:\guest\home' ;; *powershell.exe*) exit "${FAKE_GUEST_RC:-0}" ;; esac ;;
  down) exit "${FAKE_DOWN_RC:-0}" ;;
esac
exit 0
EOS
chmod +x "$BIN/fake-win-vm.sh"
tag=$(git -C "$REPO_ROOT" tag --list 'v*' --sort=-v:refname | head -1)
if [ -z "$tag" ]; then
    echo "SKIP T10 (no v* tag in this clone)"
else
    WIN_VM_BIN="$BIN/fake-win-vm.sh" HIMMEL_VM_LOCK_DIR="$WORK/locks" bash "$REPO_ROOT/scripts/vm/win-smoke-cell.sh" "$tag" >/dev/null 2>&1; rc=$?
    calls=$(tr '\n' ';' < "$FAKE_VBOX_CALLS")
    want_order=$(printf '%s' "$calls" | grep -c '^restore adopter-baseline;up;')
    if [ "$rc" -eq 0 ] && [ "$want_order" -eq 1 ] \
       && echo "$calls" | grep -q 'put [^;]*himmel-'"$tag"'.bundle ' \
       && echo "$calls" | grep -q 'put [^;]*win-smoke-guest.ps1 ' \
       && echo "$calls" | grep -q 'run --exe C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe .*-Tag '"$tag" \
       && echo "$calls" | grep -q ';down;restore adopter-baseline;$'; then
        pass "T10a smoke cell order, bundle of the tag, PS 5.1, cleanup"
    else fail_case "T10a rc=$rc calls=$calls"; fi
    reset
    FAKE_GUEST_RC=33 WIN_VM_BIN="$BIN/fake-win-vm.sh" HIMMEL_VM_LOCK_DIR="$WORK/locks" bash "$REPO_ROOT/scripts/vm/win-smoke-cell.sh" "$tag" >/dev/null 2>&1; rc=$?
    if [ "$rc" -eq 1 ] && grep -q '^down$' "$FAKE_VBOX_CALLS"; then pass "T10b guest rc 33 maps to FAIL and still powers off"; else fail_case "T10b rc=$rc"; fi
    reset
    FAKE_DOWN_RC=1 WIN_VM_BIN="$BIN/fake-win-vm.sh" HIMMEL_VM_LOCK_DIR="$WORK/locks" bash "$REPO_ROOT/scripts/vm/win-smoke-cell.sh" "$tag" >/dev/null 2>&1; rc=$?
    if [ "$rc" -eq 3 ]; then pass "T10c a failed shutdown turns a PASS into exit 3"; else fail_case "T10c rc=$rc"; fi
    reset
    FAKE_GUEST_RC=7 WIN_VM_BIN="$BIN/fake-win-vm.sh" HIMMEL_VM_LOCK_DIR="$WORK/locks" bash "$REPO_ROOT/scripts/vm/win-smoke-cell.sh" "$tag" >/dev/null 2>&1; rc=$?
    if [ "$rc" -eq 3 ]; then pass "T10d an infrastructure rc from the guest run exits 3"; else fail_case "T10d rc=$rc"; fi
fi

echo "---"
if [ "$FAILED" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$FAILED FAILED"; exit 1
