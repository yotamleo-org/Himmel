#!/usr/bin/env bash
# upgrade-path-e2e.sh -- host-driven upgrade-path stage of the VM e2e (HIMMEL-5267).
#
# Stages THIS worktree onto a VM and runs scripts/vm/upgrade-path-guest.sh there:
# baseline pins -> station targets -> himmel-doctor / graphify / qmd / cli-proxy /
# lane-canary --dry-run assertions. Opt-in: scripts/test-install-symmetry-vm.sh runs
# it after a green symmetry pass only when HIMMEL_VM_E2E_UPGRADE=1; it can also be
# run on its own.
#
# The upgrade TARGETS are stage inputs (env), not repo pins, so the stage stays
# independent of whichever dependency PR carries them:
#   UPGRADE_AST_GREP_VERSION  UPGRADE_GRAPHIFY_VERSION
#   UPGRADE_CLIPROXY_VERSION  UPGRADE_CLIPROXY_SHA256
#
# Usage: bash scripts/vm/upgrade-path-e2e.sh [--expect-red] [user@host] [port] [identity]
#   --expect-red  RED control: swaps in a deliberately bad cli-proxy-api sha256 and
#                 exits 0 only when the stage FAILS on the checksum (proves the
#                 stage can fail). Never run it as the real stage.
#
# The stage installs tools into the guest HOME and a baseline tree: run it on a
# disposable clone restored to a clean snapshot (the himmel-ar-N clones at
# suite-ready-v4), never the golden image, and restore + power off afterwards.
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
SSH_OPTS="-p $PORT -i $IDENT -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
REMOTE_DIR="/tmp/himmel-upgrade-vm"

for v in UPGRADE_AST_GREP_VERSION UPGRADE_GRAPHIFY_VERSION UPGRADE_CLIPROXY_VERSION UPGRADE_CLIPROXY_SHA256; do
  if [ -z "${!v:-}" ]; then echo "upgrade-path-e2e: $v is required (station targets are stage inputs)" >&2; exit 2; fi
done
for v in UPGRADE_AST_GREP_VERSION UPGRADE_GRAPHIFY_VERSION UPGRADE_CLIPROXY_VERSION; do
  if ! [[ "${!v}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "upgrade-path-e2e: $v '${!v}' is not a plain x.y.z version" >&2; exit 2
  fi
done
if ! [[ "$UPGRADE_CLIPROXY_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "upgrade-path-e2e: UPGRADE_CLIPROXY_SHA256 is not a lowercase 64-char hex sha256" >&2; exit 2
fi
SHA="$UPGRADE_CLIPROXY_SHA256"
[ "$EXPECT_RED" -eq 1 ] && SHA="0000000000000000000000000000000000000000000000000000000000000000"

# shellcheck disable=SC2086,SC2029  # $SSH_OPTS word-splits into flags; vars expand host-side on purpose
ssh_vm() { ssh $SSH_OPTS "$HOSTSPEC" "$@"; }

echo "==> upgrade-path stage: $HOSTSPEC:$PORT (worktree: $REPO)$([ "$EXPECT_RED" -eq 1 ] && echo ' [RED control: bad cli-proxy sha]')"
if ! ssh_vm 'echo connected' >/dev/null 2>&1; then
  echo "ERROR: cannot ssh to $HOSTSPEC:$PORT with key $IDENT (publickey rejected)." >&2
  exit 3
fi

# shellcheck source=../lib/vm-guest-excludes.sh
. "$REPO/scripts/lib/vm-guest-excludes.sh" \
  || { echo "==> REFUSING: cannot load scripts/lib/vm-guest-excludes.sh; nothing was copied" >&2; exit 1; }
# shellcheck source=lib/vm-clone.sh
. "$REPO/scripts/vm/lib/vm-clone.sh" \
  || { echo "==> REFUSING: cannot load scripts/vm/lib/vm-clone.sh; nothing was copied" >&2; exit 1; }
# The stage reads more of the tree than the symmetry run: the installers, the update
# script, doctor, the lane canary and the jira CLI sources it rebuilds.
STAGE_PATHS=(scripts docs/setup marketplace/plugins/claude-hud/config/himmel-config.json .nvmrc)
vm_stage_tree "$REPO" "$REMOTE_DIR" ssh_vm "ssh $SSH_OPTS" "$HOSTSPEC" "${STAGE_PATHS[@]}" || exit 1

OUT="$(mktemp "${TMPDIR:-/tmp}/upgrade-path-e2e.XXXXXX")" || exit 1
trap 'rm -f "$OUT"' EXIT
ssh_vm "UPGRADE_AST_GREP_VERSION='$UPGRADE_AST_GREP_VERSION' UPGRADE_GRAPHIFY_VERSION='$UPGRADE_GRAPHIFY_VERSION' UPGRADE_CLIPROXY_VERSION='$UPGRADE_CLIPROXY_VERSION' UPGRADE_CLIPROXY_SHA256='$SHA' bash $REMOTE_DIR/scripts/vm/upgrade-path-guest.sh $REMOTE_DIR" 2>&1 | tee "$OUT"
rc="${PIPESTATUS[0]}"

if [ "$EXPECT_RED" -eq 1 ]; then
  if [ "$rc" -ne 0 ] && grep -q 'checksum mismatch' "$OUT"; then
    echo "==> RED control PASSED: the stage failed on the bad pin (rc=$rc)"
    exit 0
  fi
  echo "==> RED control FAILED: the bad pin did not fail the stage on a checksum mismatch (rc=$rc)" >&2
  exit 1
fi
if [ "$rc" -eq 0 ]; then echo "==> upgrade-path stage PASSED"; else echo "==> upgrade-path stage FAILED (rc=$rc)" >&2; fi
exit "$rc"
