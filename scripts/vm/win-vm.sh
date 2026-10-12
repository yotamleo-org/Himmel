#!/usr/bin/env bash
# win-vm.sh — lifecycle + guest control for the Windows 11 test VM (HIMMEL-2860).
#
# Platform guard (linux-only): drives the station's VirtualBox with
# `VBoxManage guestcontrol` (Guest Additions), so no sshd or key setup is
# needed in the guest. This is the Windows sibling of the vmsdk/ssh path used
# for the ubuntu VMs; the older `win11_base_himmel` ssh path is unchanged.
#
# Usage: win-vm.sh <verb> [args]
#   status                     print VMState
#   up                         start headless, wait until the guest answers
#   down                       ACPI shutdown, hard poweroff after the wait
#   snapshot NAME              powered-off VM only; refuses an existing NAME
#   restore NAME               power off, then restore NAME (cold-boot cells)
#   run [--exe PATH] [--timeout-ms N] -- ARGS...
#                              default: cmd.exe /c ARGS...; --exe runs PATH
#                              with ARGS verbatim (pwsh, powershell, ...)
#   put HOSTFILE GUESTDIR      copy one host file into the guest
#
# Env:
#   VBOXMANAGE_PATH   the VBoxManage to use (test seam). Unset needs
#                     WIN_VM_LIVE=1, or the call refuses (HIMMEL-2623 rail:
#                     never fall through to the station's real VBoxManage
#                     by accident).
#   WIN_VM_NAME       VM name (default win11)
#   WIN_VM_USER       guest user (default: the host's user name, which the
#                     VirtualBox unattended install reuses)
#   WIN_VM_PASSFILE   0600 file holding the guest password (default
#                     ~/VirtualBox VMs/<vm>/<vm>-password.txt). Passed with
#                     --passwordfile; the password is never put on argv.
#   WIN_VM_BOOT_WAIT  seconds `up` waits for the guest (default 300)
#   WIN_VM_POLL       seconds between polls (default 5; tests use 0)
#   WIN_VM_LOCK_HELD  1 when the caller already holds vm-lock for the VM
#                     (the smoke cell does); skips the per-verb lock.
#   HIMMEL_VM_LOCK_DIR / HIMMEL_VM_LOCK_WAIT: see vm-lock.sh.
#
# Exit: 0 ok; 1 failed; 2 usage; 3 environment (VM or guest unreachable).
#       `run` also forwards VBoxManage's own status: 33 = the guest process
#       exited non-zero (guestcontrol maps every guest exit code to 33).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VM="${WIN_VM_NAME:-win11}"
GUEST_USER="${WIN_VM_USER:-$(id -un)}"
PASSFILE="${WIN_VM_PASSFILE:-$HOME/VirtualBox VMs/$VM/$VM-password.txt}"
POLL="${WIN_VM_POLL:-5}"
BOOT_WAIT="${WIN_VM_BOOT_WAIT:-300}"
CMD_EXE='C:\Windows\System32\cmd.exe'

die() { echo "win-vm: $*" >&2; exit "${2:-1}"; }

VBOX="${VBOXMANAGE_PATH:-}"
if [ -z "$VBOX" ]; then
    [ "${WIN_VM_LIVE:-0}" = "1" ] || die "VBOXMANAGE_PATH is unset and WIN_VM_LIVE is not '1' — refusing to fall through to the station's real VBoxManage" 3
    VBOX=VBoxManage
fi

vm_state() { "$VBOX" showvminfo "$VM" --machinereadable 2>/dev/null | sed -n 's/^VMState="\(.*\)"$/\1/p'; }

guest() { # guest <verb> <args...> — guestcontrol with file-based auth
    local verb="$1"; shift
    [ -r "$PASSFILE" ] || die "password file '$PASSFILE' unreadable (set WIN_VM_PASSFILE)" 3
    "$VBOX" guestcontrol "$VM" "$verb" --username "$GUEST_USER" --passwordfile "$PASSFILE" "$@"
}

lock_take() {
    [ "${WIN_VM_LOCK_HELD:-0}" = "1" ] && return 0
    # shellcheck source=scripts/vm/vm-lock.sh
    . "$HERE/vm-lock.sh"
    vm_lock_acquire_waiting "$VM" || die "vm-lock '$VM' not acquired" 3
    trap 'vm_lock_release "$VM"' EXIT
}

iters() { local p="$POLL"; [ "$p" -gt 0 ] || p=1; echo $(($1 / p)); }

wait_state() { # wait_state <state> <seconds>
    local want="$1" n i=0
    n=$(iters "$2")
    while [ "$i" -lt "$n" ]; do
        [ "$(vm_state)" = "$want" ] && return 0
        sleep "$POLL"; i=$((i + 1))
    done
    [ "$(vm_state)" = "$want" ]
}

verb="${1:-}"; [ $# -gt 0 ] && shift
case "$verb" in
    status)
        s=$(vm_state); [ -n "$s" ] || die "VM '$VM' not found" 3
        echo "$s" ;;
    up)
        lock_take
        [ "$(vm_state)" = "running" ] || "$VBOX" startvm "$VM" --type headless >/dev/null || die "startvm failed" 3
        n=$(iters "$BOOT_WAIT"); i=0
        while [ "$i" -lt "$n" ]; do
            guest run --exe "$CMD_EXE" --timeout 15000 --wait-stdout -- cmd.exe /c ver >/dev/null 2>&1 && { echo "win-vm: guest up"; exit 0; }
            sleep "$POLL"; i=$((i + 1))
        done
        die "guest did not answer within ${BOOT_WAIT}s" 3 ;;
    down)
        lock_take
        [ "$(vm_state)" = "poweroff" ] && exit 0
        "$VBOX" controlvm "$VM" acpipowerbutton >/dev/null 2>&1
        wait_state poweroff 120 && exit 0
        "$VBOX" controlvm "$VM" poweroff >/dev/null 2>&1
        wait_state poweroff 30 || die "VM did not power off" 1 ;;
    snapshot)
        [ $# -eq 1 ] || die "usage: snapshot NAME" 2
        lock_take
        [ "$(vm_state)" = "poweroff" ] || die "VM must be powered off to snapshot a cold baseline (run: down)" 1
        # literal compare (awk), so a name with regex metacharacters cannot mis-match
        snaps=$("$VBOX" snapshot "$VM" list --machinereadable 2>/dev/null)
        if printf '%s\n' "$snaps" | awk -v n="$1" 'index($0, "SnapshotName") == 1 { v = substr($0, index($0, "=") + 1); if (v == "\"" n "\"") f = 1 } END { exit !f }'; then
            die "snapshot '$1' already exists" 1
        fi
        "$VBOX" snapshot "$VM" take "$1" >/dev/null || die "snapshot take failed" 1 ;;
    restore)
        [ $# -eq 1 ] || die "usage: restore NAME" 2
        lock_take
        if [ "$(vm_state)" != "poweroff" ]; then
            "$VBOX" controlvm "$VM" poweroff >/dev/null 2>&1
            wait_state poweroff 30 || die "VM did not power off before restore" 1
        fi
        "$VBOX" snapshot "$VM" restore "$1" >/dev/null || die "snapshot restore '$1' failed" 1 ;;
    run)
        exe="$CMD_EXE"; timeout_ms=600000; custom=0
        while [ $# -gt 0 ]; do
            case "$1" in
                --exe) exe="$2"; custom=1; shift 2 ;;
                --timeout-ms) timeout_ms="$2"; shift 2 ;;
                --) shift; break ;;
                *) die "usage: run [--exe PATH] [--timeout-ms N] -- ARGS..." 2 ;;
            esac
        done
        [ $# -gt 0 ] || die "run: no command" 2
        if [ "$custom" = 1 ]; then argv0="${exe##*\\}"; set -- "$argv0" "$@"; else set -- cmd.exe /c "$@"; fi
        guest run --exe "$exe" --timeout "$timeout_ms" --wait-stdout --wait-stderr -- "$@" ;;
    put)
        [ $# -eq 2 ] || die "usage: put HOSTFILE GUESTDIR" 2
        [ -f "$1" ] || die "no such file: $1" 2
        guest copyto --target-directory "$2" "$1" ;;
    *) die "usage: win-vm.sh status|up|down|snapshot NAME|restore NAME|run [--exe PATH] -- ARGS|put FILE DIR" 2 ;;
esac
