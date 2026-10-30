#!/usr/bin/env bash
# adopted-features-e2e.sh -- host-driven adopted-features stage of the VM e2e.
#
# Takes the vm-lock on <vm>, restores it to the clean snapshot, stages THIS worktree's
# tracked scripts/.claude tree onto it, and runs scripts/vm/adopted-features-guest.sh
# there: himmel is adopted into scratch git projects (adopt.sh) and each of the ten
# clone-only features is checked from the project, never from the clone. The VM is
# restored and powered off afterwards, and the lock released, on every exit path.
#
# Usage: bash scripts/vm/adopted-features-e2e.sh [--expect-red] <vm>
#   <vm>          a himmel-ar-N / himmel-ci-N clone (never the golden image)
#   --expect-red  RED control: the guest deletes the adopted no-force-push gate before
#                 row 3, and the driver exits 0 only when the stage FAILS on row 3.
#
# Env (test seams): HIMMEL_ADOPTED_VMSDK, HIMMEL_ADOPTED_GUEST_EXEC, HIMMEL_ADOPTED_STAGE_TMP,
#   HIMMEL_VM_LOCK_DIR, HIMMEL_ADOPTED_E2E_SNAPSHOT (default suite-ready-v4).
#
# Exit: 0 passed (or, with --expect-red, failed on row 3 as expected); 1 a row failed
# (or --expect-red did not fail on row 3); 2 bad inputs; 3 lock or VM lifecycle failed.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "$HERE/../.." && pwd)"

EXPECT_RED=0
if [ "${1:-}" = "--expect-red" ]; then EXPECT_RED=1; shift; fi
VM="${1:-}"
case "$VM" in
  ''|*[!A-Za-z0-9_-]*) echo "usage: adopted-features-e2e.sh [--expect-red] <vm>  (vm name: letters, digits, _ -)" >&2; exit 2 ;;
esac

SNAPSHOT="${HIMMEL_ADOPTED_E2E_SNAPSHOT:-suite-ready-v4}"
REMOTE_DIR="/tmp/himmel-adopted-vm"
STAGE_PATHS=(scripts .claude docs/setup marketplace .nvmrc)

vmsdk() {
  if [ -n "${HIMMEL_ADOPTED_VMSDK:-}" ]; then "$HIMMEL_ADOPTED_VMSDK" "$VM" "$@"
  elif command -v uv >/dev/null 2>&1; then uv run "$REPO/scripts/lib/vmsdk.py" "$VM" "$@"
  else python3 "$REPO/scripts/lib/vmsdk.py" "$VM" "$@"; fi
}
gx() { # guest-exec has no stdin: one command string per call
  if [ -n "${HIMMEL_ADOPTED_GUEST_EXEC:-}" ]; then "$HIMMEL_ADOPTED_GUEST_EXEC" "$VM" "$@"
  else bash "$REPO/scripts/vm/guest-exec.sh" "$VM" "$@"; fi
}
# shellcheck disable=SC2329  # passed to vm_guest_assert_clean as its runner
gx_run() { gx -- "$1"; } # runner for vm_guest_assert_clean: <command string>

# shellcheck source=vm-lock.sh
. "$HERE/vm-lock.sh" || { echo "adopted-features-e2e: cannot load vm-lock.sh" >&2; exit 3; }
# shellcheck source=../lib/vm-guest-excludes.sh
. "$REPO/scripts/lib/vm-guest-excludes.sh" || { echo "adopted-features-e2e: cannot load vm-guest-excludes.sh; nothing was copied" >&2; exit 3; }

STAGE_TMP="${HIMMEL_ADOPTED_STAGE_TMP:-${TMPDIR:-/tmp}}"
TARBALL="" OUT="" LOCKED=0 BOOTED=0
# shellcheck disable=SC2329  # EXIT trap
cleanup() {
  local rc=$?
  trap - EXIT
  [ -z "$TARBALL" ] || rm -f "$TARBALL"
  [ -z "$OUT" ] || rm -f "$OUT"
  if [ "$BOOTED" = 1 ]; then
    vmsdk restore "$SNAPSHOT" >/dev/null 2>&1 || echo "adopted-features-e2e: WARNING restore $SNAPSHOT after the run failed; $VM may be dirty" >&2
    vmsdk down >/dev/null 2>&1 || echo "adopted-features-e2e: WARNING could not power $VM off" >&2
  fi
  [ "$LOCKED" != 1 ] || vm_lock_release "$VM"
  exit "$rc"
}
trap cleanup EXIT

vm_lock_acquire_waiting "$VM" || { echo "adopted-features-e2e: vm-lock for $VM is held; refusing" >&2; exit 3; }
LOCKED=1

echo "==> adopted-features stage: $VM @ $SNAPSHOT (worktree: $REPO)$([ "$EXPECT_RED" = 1 ] && echo ' [RED control: row 3 gate deleted]')"
BOOTED=1
vmsdk restore "$SNAPSHOT" >/dev/null || { echo "adopted-features-e2e: restore $SNAPSHOT failed" >&2; exit 3; }
vmsdk up >/dev/null || { echo "adopted-features-e2e: up failed" >&2; exit 3; }

# Stage: a host-built tarball of the tracked files (secret globs excluded), pushed over
# SFTP and unpacked by guest-exec (which cannot take stdin, so the tar-over-ssh path of
# vm_stage_tree does not apply).
TARBALL="$(mktemp "$STAGE_TMP/adopted-features-tree.XXXXXX")" || exit 3
tar_excl=(); while IFS= read -r _x; do tar_excl+=("$_x"); done < <(vm_guest_tar_excludes)
git -C "$REPO" ls-files -z --cached --others --exclude-standard -- "${STAGE_PATHS[@]}" | tar -C "$REPO" "${tar_excl[@]}" -czf "$TARBALL" --null -T - \
  || { echo "adopted-features-e2e: could not build the stage tarball" >&2; exit 3; }
vmsdk push "$TARBALL" /tmp/himmel-adopted-tree.tgz >/dev/null || { echo "adopted-features-e2e: push failed" >&2; exit 3; }
gx -- "rm -rf $REMOTE_DIR $REMOTE_DIR.away && mkdir -p $REMOTE_DIR && tar -xzf /tmp/himmel-adopted-tree.tgz -C $REMOTE_DIR && rm -f /tmp/himmel-adopted-tree.tgz" >/dev/null \
  || { echo "adopted-features-e2e: could not unpack the tree on $VM" >&2; exit 3; }
vm_guest_assert_clean gx_run "$REMOTE_DIR" full || exit 3

OUT="$(mktemp "$STAGE_TMP/adopted-features-out.XXXXXX")" || exit 3
red=""; [ "$EXPECT_RED" = 1 ] && red="ADOPTED_E2E_RED=1 "
gx --timeout 1800 -- "${red}HIMMEL_ADOPTED_E2E_GUEST=1 bash $REMOTE_DIR/scripts/vm/adopted-features-guest.sh $REMOTE_DIR" 2>&1 | tee "$OUT"
rc="${PIPESTATUS[0]}"

if grep -q ' FINDING ' "$OUT"; then
  echo "==> FINDINGS (rows that cannot run from an adopted project):"
  grep ' FINDING ' "$OUT" | sed 's/^/    /'
fi

if [ "$EXPECT_RED" = 1 ]; then
  other_fails=$(grep '^ROW [0-9]* FAIL' "$OUT" | grep -v '^ROW 3 ' || true)
  if [ "$rc" -ne 0 ] && grep -q '^ROW 3 FAIL' "$OUT" && [ -z "$other_fails" ]; then
    echo "==> RED control PASSED: the stage failed on row 3 only (rc=$rc)"
    exit 0
  fi
  echo "==> RED control FAILED: removing the adopted gate did not fail row 3 alone (rc=$rc)" >&2
  exit 1
fi
if [ "$rc" -eq 0 ]; then echo "==> adopted-features stage PASSED"; else echo "==> adopted-features stage FAILED (rc=$rc)" >&2; fi
exit "$rc"
