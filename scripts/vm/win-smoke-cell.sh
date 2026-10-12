#!/usr/bin/env bash
# win-smoke-cell.sh — one adopt/uninstall smoke cell on the win11 test VM
# (HIMMEL-2860).
#
# Platform guard (linux-only): station-side orchestration over win-vm.sh and
# VBoxManage; the guest half is win-smoke-guest.ps1.
#
# Ships the tree by git bundle of <tag> (never by main, never a bare archive:
# the hook read-backs need .git), restores the `adopter-baseline` snapshot,
# runs the guest half under Windows PowerShell 5.1, prints its evidence
# (CELL | STEP | CMD | LAST | rc, CHECK PASS/FAIL, VERDICT) and ALWAYS powers
# the VM off, restores the baseline and releases the lock on the way out.
#
# Usage: win-smoke-cell.sh [<tag>]     (default: the highest v* tag)
# Env:   WIN_VM_BIN overrides the win-vm.sh path (test seam); the rest is
#        win-vm.sh's own (WIN_VM_NAME, WIN_VM_LIVE, VBOXMANAGE_PATH, ...).
# Exit:  0 cell PASS; 1 cell FAIL; 3 environment (VM or guest unreachable).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
WINVM="${WIN_VM_BIN:-$HERE/win-vm.sh}"
VM="${WIN_VM_NAME:-win11}"
BASELINE="adopter-baseline"
PS51='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'

die() { echo "win-smoke-cell: $*" >&2; exit "${2:-1}"; }

TAG="${1:-}"
if [ -z "$TAG" ]; then
    TAG=$(git -C "$REPO_ROOT" tag --list 'v*' --sort=-v:refname | head -1)
    [ -n "$TAG" ] || die "no v* tag in this clone" 3
fi
git -C "$REPO_ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null || die "no such tag: $TAG" 3

WORK=$(mktemp -d "${TMPDIR:-/tmp}/win-smoke-cell.XXXXXX") || exit 3
trap 'rm -rf "$WORK"' EXIT   # replaced by cleanup() once the lock is held
BUNDLE="$WORK/himmel-$TAG.bundle"
git -C "$REPO_ROOT" bundle create "$BUNDLE" "$TAG" >/dev/null 2>&1 || die "git bundle create failed for $TAG" 3
git -C "$REPO_ROOT" bundle verify "$BUNDLE" >/dev/null 2>&1 || die "git bundle verify failed" 3

# shellcheck source=scripts/vm/vm-lock.sh
. "$HERE/vm-lock.sh"
vm_lock_acquire_waiting "$VM" || die "vm-lock '$VM' not acquired" 3
export WIN_VM_LOCK_HELD=1

# shellcheck disable=SC2329  # invoked by the EXIT trap below
cleanup() {
    local rc=$? bad=0
    bash "$WINVM" down >/dev/null 2>&1 || bad=1
    bash "$WINVM" restore "$BASELINE" >/dev/null 2>&1 || bad=1
    vm_lock_release "$VM"
    rm -rf "$WORK"
    # A cell that left the VM running or the baseline unrestored is not a clean PASS.
    if [ "$bad" -ne 0 ]; then
        echo "win-smoke-cell: cleanup failed (VM may be running or baseline not restored)" >&2
        [ "$rc" -eq 0 ] && rc=3
    fi
    exit "$rc"
}
trap cleanup EXIT

echo "win-smoke-cell: tag=$TAG bundle=$(git -C "$REPO_ROOT" rev-parse "$TAG^{commit}")"
bash "$WINVM" restore "$BASELINE" || die "restore $BASELINE failed" 3
bash "$WINVM" up || die "guest did not come up" 3

home=$(bash "$WINVM" run -- 'echo %USERPROFILE%' | tr -d '\r' | tail -1)
[ -n "$home" ] || die "could not read the guest profile dir" 3
inbox="$home\\cell-in"
bash "$WINVM" run -- "if not exist $inbox mkdir $inbox" >/dev/null || die "mkdir $inbox failed" 3
bash "$WINVM" put "$BUNDLE" "$inbox\\" || die "put bundle failed" 3
bash "$WINVM" put "$HERE/win-smoke-guest.ps1" "$inbox\\" || die "put guest script failed" 3

bash "$WINVM" run --exe "$PS51" --timeout-ms 1500000 -- \
    -NoProfile -ExecutionPolicy Bypass -File "$inbox\\win-smoke-guest.ps1" \
    -Bundle "$inbox\\$(basename "$BUNDLE")" -Tag "$TAG"
rc=$?
# VBoxManage maps a non-zero guest exit code to 33; the VERDICT line is the verdict.
case "$rc" in 0) exit 0 ;; 1|33) exit 1 ;; *) echo "win-smoke-cell: guest run rc=$rc" >&2; exit 3 ;; esac
