#!/usr/bin/env bash
# claudex-guest.sh — bring up and probe the claudex test-VM guest.
#
# A claudex proof (Claude Code on the Codex lane through cli-proxy) needs a test VM that
# holds a Codex login and the proxy. The guest is an after-report clone, himmel-ar-<N>;
# the golden ubuntu_new is never touched. A claudex proof restores the
# `claudex-login-<date>` snapshot taken after the operator's login, NOT suite-ready-v4
# (which has no login). Recipe: docs/setup/vms.md "claudex guest".
#
# Usage: bash scripts/vm/claudex-guest.sh <verb> <vm> [arg]
#   up <vm> [snapshot]   take the vm-lock, restore <snapshot> (default suite-ready-v4),
#                        boot, wait for ssh, release the lock; the guest stays running
#   down <vm>            take the vm-lock, power the guest off
#   provision <vm>       install the cli-proxy lane in the guest (idempotent)
#   status <vm>          claude-codex --version and the proxy status, through guest-exec
#   snapshot <vm> <name> snapshot the running guest (vmsdk's secret scan runs first)
# <vm> must be himmel-ar-<N>; any other name exits 2 and nothing is run.
#
# Env: VBOXMANAGE_PATH (or HIMMEL_VM_AR_LIVE=1), HIMMEL_VM_LOCK_WAIT, HIMMEL_VMSDK
# (test seam: a stub standing in for scripts/lib/vmsdk.py).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUEST_EXEC="$REPO_ROOT/scripts/vm/guest-exec.sh"

usage() {
    echo "usage: claudex-guest.sh up|down|provision|status|snapshot himmel-ar-<N> [arg]" >&2
    exit 2
}

[ "$#" -ge 2 ] || usage
verb="$1"; vm="$2"; arg="${3:-}"
case "$vm" in
    himmel-ar-[1-9]|himmel-ar-[1-9][0-9]) ;;
    *) echo "claudex-guest.sh: '$vm' is not an after-report clone (himmel-ar-<N>); refusing" >&2; usage ;;
esac
case "$verb" in
    up) [ -n "$arg" ] || arg="suite-ready-v4" ;;
    down|provision|status) ;;
    snapshot) [ -n "$arg" ] || usage ;;
    *) usage ;;
esac
case "$arg" in
    *[!A-Za-z0-9._-]*) echo "claudex-guest.sh: invalid snapshot name '$arg'" >&2; usage ;;
esac

# the guest side: one literal command per step, run through guest-exec only
gx() { bash "$GUEST_EXEC" "$vm" "$@"; }
# the other vmsdk verbs (clone, push): the same runner guest-exec.sh uses
sdk() {
    local sdk_py="${HIMMEL_VMSDK:-$REPO_ROOT/scripts/lib/vmsdk.py}"
    if command -v uv >/dev/null 2>&1; then uv run "$sdk_py" "$@"; else python3 "$sdk_py" "$@"; fi
}

lifecycle_env() {
    # shellcheck source=scripts/vm/port-alloc.sh
    . "$REPO_ROOT/scripts/vm/port-alloc.sh"
    # shellcheck source=scripts/vm/lib/vm-clone.sh
    . "$REPO_ROOT/scripts/vm/lib/vm-clone.sh"
    # shellcheck source=scripts/vm/vm-lock.sh
    . "$REPO_ROOT/scripts/vm/vm-lock.sh"
    fail() { echo "ERROR: claudex-guest.sh: $1" >&2; exit 1; }
    vm_env_init
    # shellcheck disable=SC2034 # read by vm_restore in the sourced vm-clone.sh
    CLONE_NAME="$vm"
    vm_lock_acquire_waiting "$vm" || fail "could not take the vm-lock on $vm (held by another run)"
    trap 'vm_lock_release "$vm"' EXIT
    trap 'exit 143' TERM
    trap 'exit 130' INT
}

case "$verb" in
    up)
        lifecycle_env
        vm_restore "$arg"
        vm_boot
        echo "claudex-guest.sh: $vm restored to '$arg' and answering ssh on 127.0.0.1:$PORT"
        ;;
    down)
        lifecycle_env
        vbox_py 'vbox.power_off(sys.argv[1], graceful=True)' "$vm" \
            || fail "could not power $vm off"
        echo "claudex-guest.sh: $vm powered off"
        ;;
    snapshot)
        exec "${HIMMEL_VM_PYTHON:-$HOME/.himmel/vm-venv/bin/python}" \
            "${HIMMEL_VMSDK:-$REPO_ROOT/scripts/lib/vmsdk.py}" "$vm" snapshot "$arg"
        ;;
    provision)
        # the guest's ~/himmel is brought to main (it carries claude-codex and
        # cli-proxy-lane.sh), then the guest-side script is pushed and run
        sdk "$vm" clone main || exit $?
        # shellcheck disable=SC2088 # a GUEST path: the guest expands the tilde, not this shell
        sdk "$vm" push "$REPO_ROOT/scripts/vm/claudex-guest-provision.sh" '~/claudex-guest-provision.sh' || exit $?
        # shellcheck disable=SC2088 # a GUEST path, expanded by the guest shell
        gx -- bash '~/claudex-guest-provision.sh' || exit $?
        ;;
    status)
        gx -- claude-codex --version || exit $?
        ;;
esac
