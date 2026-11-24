#!/usr/bin/env bash
# vm-ssh-opts.sh — the ssh options and probe messages the host-driven VM suites share.
#
# After a snapshot restore the guest has a new host key. vmsdk and launch-guest.sh keep
# one known_hosts file per VM (~/.himmel/vm/known_hosts/<vm>) that a restore resets; the
# suites pin the same file so a restore never needs a hand edit of ~/.ssh/known_hosts,
# and their connectivity probe names the real ssh error instead of "publickey rejected".
#
# Source it and call:
#   vm_ssh_vm_for_port <port>   prints the vms.json VM whose ssh_port is <port> (rc 1: none)
#   vm_ssh_guest_user <vm>      prints that VM's guest user (rc 1: none)
#   vm_ssh_opts <port>          prints the host-key ssh options, ready to word-split into
#                               SSH_OPTS: -o UserKnownHostsFile=~/.himmel/vm/known_hosts/<vm>
#                               -o StrictHostKeyChecking=accept-new (accept-new alone when
#                               no VM owns the port); creates the file's directory
#   vm_ssh_probe_report <ssh stderr> <host> <port> <identity>
#                               prints one message naming the class (host key changed |
#                               key refused | no route or timeout) and ssh's own text
#
# Seam: HIMMEL_VMS_JSON overrides scripts/lib/vms.json. Bash 3.2-safe.

VM_SSH_OPTS_VMS_JSON_DEFAULT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/vms.json"

_vm_ssh_vms_lookup() {
    command -v python3 >/dev/null 2>&1 || return 1
    python3 -I -c '
import json, sys
try:
    vms = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
field, key, value = sys.argv[2:5]
for name, v in vms.items():
    if not isinstance(v, dict) or v.get("kind") == "station":
        continue
    cand = name if key == "name" else str(v.get(key, ""))
    if cand == value:
        out = name if field == "name" else v.get(field)
        if out:
            print(out); sys.exit(0)
sys.exit(1)
' "${HIMMEL_VMS_JSON:-$VM_SSH_OPTS_VMS_JSON_DEFAULT}" "$@"
}

vm_ssh_vm_for_port() { _vm_ssh_vms_lookup name ssh_port "$1"; }

vm_ssh_guest_user() { _vm_ssh_vms_lookup user name "$1"; }

vm_ssh_opts() {
    local vm
    if vm="$(vm_ssh_vm_for_port "$1")" && [ -n "$vm" ]; then
        mkdir -p "${HOME:-}/.himmel/vm/known_hosts" 2>/dev/null && chmod 700 "${HOME:-}/.himmel/vm/known_hosts" 2>/dev/null
        printf '%s' "-o UserKnownHostsFile=~/.himmel/vm/known_hosts/$vm -o StrictHostKeyChecking=accept-new"
    else
        printf '%s' "-o StrictHostKeyChecking=accept-new"
    fi
}

vm_ssh_probe_report() {
    local err="$1" host="$2" port="$3" ident="$4" vm kh=""
    # shellcheck disable=SC2088  # the literal ~ is for the operator's eyes, never expanded
    if vm="$(vm_ssh_vm_for_port "$port")" && [ -n "$vm" ]; then kh="~/.himmel/vm/known_hosts/$vm"; fi
    case "$err" in
        *"HOST IDENTIFICATION HAS CHANGED"*|*"Host key verification failed"*)
            echo "ERROR: cannot ssh to $host:$port: host key changed -- the guest was rebuilt or restored." >&2
            if [ -n "$kh" ]; then echo "  Delete $kh and re-run (a restore through vmsdk.py does that itself)." >&2
            else echo "  Remove the stale entry for it from known_hosts and re-run." >&2; fi ;;
        *"Permission denied"*)
            echo "ERROR: cannot ssh to $host:$port: key refused -- the guest rejected $ident (publickey)." >&2
            echo "  Its authorized_keys lacks this key, or the user in the target is wrong." >&2 ;;
        *"Connection refused"*|*"timed out"*|*"No route to host"*|*"Network is unreachable"*|*"Could not resolve"*)
            echo "ERROR: cannot ssh to $host:$port: no route or timeout -- the VM is not reachable." >&2
            echo "  It is powered off, still booting, or the port is wrong." >&2 ;;
        *)
            echo "ERROR: cannot ssh to $host:$port with key $ident." >&2 ;;
    esac
    printf '  ssh said: %s\n' "$err" | sed '2,$s/^/            /' >&2
}
