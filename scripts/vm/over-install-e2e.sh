#!/usr/bin/env bash
# over-install-e2e.sh -- host-driven over-install stage of the VM e2e.
#
# Stages two git-archive trees onto a VM (the BASE release tag and the CANDIDATE ref)
# and runs scripts/vm/over-install-guest.sh there: install the base with its own
# installer, configure a project + secret + commit rule, install the candidate over it,
# and assert the install converged. Opt-in: scripts/test-install-symmetry-vm.sh runs it
# after a green symmetry pass only when HIMMEL_VM_E2E_OVERINSTALL=1; it can also be run
# on its own.
#
# Refs (env, default in brackets):
#   OVERINSTALL_BASE_REF  the installed release [v1.1.2]
#   OVERINSTALL_CAND_REF  the version installed over it [HEAD]
#
# Usage: bash scripts/vm/over-install-e2e.sh [--expect-red] [user@host] [port] [identity]
#   --expect-red  RED control: the guest duplicates one settings hook entry after the
#                 over-install and the run exits 0 only when the stage FAILS on the
#                 "hooks appear once each" assertion (proves the stage can fail).
#                 Never run it as the real stage.
#
# The stage installs into the guest HOME: run it on a disposable clone restored to a
# clean snapshot (the himmel-ar-N clones at suite-ready-v4), never the golden image,
# and restore + power off afterwards.
#
# Exit: 0 passed (or, with --expect-red, failed as expected); 1 an assertion failed
# (or --expect-red did not fail); 2 bad inputs; 3 VM unreachable / vm.mode none.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "$HERE/../.." && pwd)"

EXPECT_RED=0
if [ "${1:-}" = "--expect-red" ]; then EXPECT_RED=1; shift; fi

# shellcheck source=../lib/vm-mode.sh
. "$REPO/scripts/lib/vm-mode.sh"
vm_mode_e2e_guard "$(basename -- "$0")" || { vm_guard_rc=$?; [ "$vm_guard_rc" = 1 ] && exit 3; exit "$vm_guard_rc"; }
HOSTSPEC="${1:-$VM_MODE_HOST}"
PORT="${2:-$VM_MODE_PORT}"
IDENT="${3:-$VM_MODE_IDENT}"
SSH_OPTS=(-p "$PORT" -i "$IDENT" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
REMOTE_DIR="/tmp/himmel-over-install-vm"
BASE_REF="${OVERINSTALL_BASE_REF:-v1.1.2}"
CAND_REF="${OVERINSTALL_CAND_REF:-HEAD}"

for ref in "$BASE_REF" "$CAND_REF"; do
  if ! git -C "$REPO" rev-parse --verify --quiet "$ref^{commit}" >/dev/null; then
    echo "over-install-e2e: ref '$ref' does not resolve to a commit in $REPO" >&2; exit 2
  fi
done

# shellcheck disable=SC2029  # vars expand host-side on purpose
ssh_vm() { ssh "${SSH_OPTS[@]}" "$HOSTSPEC" "$@"; }

echo "==> over-install stage: $HOSTSPEC:$PORT (base $BASE_REF, candidate $CAND_REF)$([ "$EXPECT_RED" -eq 1 ] && echo ' [RED control: duplicated hook entry]')"
if ! ssh_vm 'echo connected' >/dev/null 2>&1; then
  echo "ERROR: cannot ssh to $HOSTSPEC:$PORT with key $IDENT (publickey rejected)." >&2
  exit 3
fi

ssh_vm "rm -rf $REMOTE_DIR && mkdir -p $REMOTE_DIR" || exit 1
git -C "$REPO" archive --format=tar.gz "$BASE_REF" | ssh_vm "cat > $REMOTE_DIR/base.tgz" || { echo "==> REFUSING: could not stage $BASE_REF" >&2; exit 1; }
git -C "$REPO" archive --format=tar.gz "$CAND_REF" | ssh_vm "cat > $REMOTE_DIR/cand.tgz" || { echo "==> REFUSING: could not stage $CAND_REF" >&2; exit 1; }
ssh_vm "cat > $REMOTE_DIR/over-install-guest.sh" < "$HERE/over-install-guest.sh" || exit 1

RED=""
[ "$EXPECT_RED" -eq 1 ] && RED="dup-hook"

OUT="$(mktemp "${TMPDIR:-/tmp}/over-install-e2e.XXXXXX")" || exit 1
trap 'rm -f "$OUT"' EXIT
ssh_vm "OVERINSTALL_DUMP_SETTINGS='${OVERINSTALL_DUMP_SETTINGS:-0}' OVERINSTALL_RED='$RED' OVERINSTALL_BASE_TGZ=$REMOTE_DIR/base.tgz OVERINSTALL_CAND_TGZ=$REMOTE_DIR/cand.tgz bash $REMOTE_DIR/over-install-guest.sh" 2>&1 | tee "$OUT"
rc="${PIPESTATUS[0]}"

if [ "$EXPECT_RED" -eq 1 ]; then
  if [ "$rc" -ne 0 ] && grep -q '^FAIL settings hooks appear once each' "$OUT"; then
    echo "==> RED control PASSED: the stage failed on the duplicated hook (rc=$rc)"
    exit 0
  fi
  echo "==> RED control FAILED: the duplicated hook did not fail the stage on 'hooks appear once each' (rc=$rc)" >&2
  exit 1
fi
if [ "$rc" -eq 0 ]; then echo "==> over-install stage PASSED"; else echo "==> over-install stage FAILED (rc=$rc)" >&2; fi
exit "$rc"
