#!/usr/bin/env bash
# shellcheck disable=SC2015
# test-adopt-plugins-vm.sh - VM proof for a project adopt that keeps plugin enablement out of
# the user file (given scopes slice S2b-1, spec A26).
#
# Takes the vm-lock on <vm>, restores it to the clean snapshot, stages THIS worktree's tracked
# tree onto it and, on the guest, adopts a sandbox repo with adopt.sh --scope project. It then
# checks the files (the floor ids in the shared file, the statusLine and marketplace entries in
# the local file, no user-scope enablement) and runs the one live-session probe in the sandbox:
# `claude -p --output-format stream-json --verbose --permission-mode default`, whose init
# message must list himmel-ops. The guest must be a VM that never had a user-scope plugin
# enablement. The VM is restored and powered off afterwards, and the lock released, on every
# exit path.
#
# Usage: bash scripts/vm/test-adopt-plugins-vm.sh <vm>
#   <vm>  a himmel-ar-N / himmel-ci-N clone (never the golden image)
#
# Env (test seams): HIMMEL_ADOPT_PLUGINS_VMSDK, HIMMEL_ADOPT_PLUGINS_GUEST_EXEC,
#   HIMMEL_ADOPT_PLUGINS_STAGE_TMP, HIMMEL_VM_LOCK_DIR, HIMMEL_ADOPT_PLUGINS_SNAPSHOT
#   (default suite-ready-v4).
#
# Exit: 0 passed; 1 a check failed (the init message lacks himmel-ops: apply the spec's A26
# fallback, per-worktree `claude plugin install --scope local`, before merging); 2 bad inputs;
# 3 lock or VM lifecycle failed; 4 the guest cannot run a live session (claude missing or not
# signed in).
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "$HERE/../.." && pwd)"
REMOTE_DIR="/tmp/himmel-adopt-plugins-vm"

if [ "${HIMMEL_ADOPT_PLUGINS_GUEST:-}" = 1 ]; then
  clone="${1:?guest mode needs the staged clone dir}"
  fails=0
  pass() { echo "ok - $1"; }
  fail() { echo "FAIL - $1${2:+: $2}"; fails=$((fails + 1)); }
  command -v jq >/dev/null 2>&1 || { echo "FAIL: jq missing on the guest" >&2; exit 1; }
  user_file="$HOME/.claude/settings.json"
  floor_ids=$(jq -c '[.enabledPlugins | to_entries[] | select(.value == true) | .key]' "$clone/docs/setup/settings-template.json")

  if [ -s "$user_file" ] && jq -e '(.enabledPlugins // {}) | length > 0' "$user_file" >/dev/null 2>&1; then
    echo "FAIL: this guest already has a user-scope plugin enablement: $(jq -c .enabledPlugins "$user_file")" >&2
    exit 1
  fi

  sbx="$HOME/adopt-plugins-sbx"
  rm -rf "$sbx"; mkdir -p "$sbx"
  git -C "$sbx" init -q && git -C "$sbx" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init \
    || { echo "FAIL: cannot create the sandbox repo" >&2; exit 1; }
  ( cd "$sbx" && bash "$clone/scripts/adopt.sh" --profile core --scope project --target "$sbx" ) > "$HOME/adopt-plugins.log" 2>&1 \
    || { tail -30 "$HOME/adopt-plugins.log" >&2; echo "FAIL: adopt.sh --scope project failed" >&2; exit 1; }

  shared="$sbx/.claude/settings.json"; local_f="$sbx/.claude/settings.local.json"
  jq -e --argjson ids "$floor_ids" '. as $r | all($ids[]; $r.enabledPlugins[.] == true)' "$shared" >/dev/null 2>&1 \
    && pass "the shared file carries the floor ids" || fail "the shared file carries the floor ids"
  jq -e '(.statusLine // null) == null and ((.extraKnownMarketplaces.himmel // null) == null)' "$shared" >/dev/null 2>&1 \
    && pass "the shared file has no statusLine and no himmel marketplace entry" || fail "the shared file has no statusLine and no himmel marketplace entry"
  jq -e '.statusLine.command | test("claude-hud")' "$local_f" >/dev/null 2>&1 \
    && pass "the local file carries the statusLine" || fail "the local file carries the statusLine"
  jq -e '.extraKnownMarketplaces.himmel.source.source == "directory"' "$local_f" >/dev/null 2>&1 \
    && pass "the local file carries himmel's marketplace entry" || fail "the local file carries himmel's marketplace entry"
  jq -e '(.enabledPlugins // {}) | length == 0' "$local_f" >/dev/null 2>&1 \
    && pass "the local file enables nothing" || fail "the local file enables nothing"
  if [ -s "$user_file" ]; then
    jq -e '(.enabledPlugins // {}) | length == 0' "$user_file" >/dev/null 2>&1 \
      && pass "the user file gained no enabledPlugins entry" || fail "the user file gained no enabledPlugins entry" "$(jq -c .enabledPlugins "$user_file")"
  else
    pass "the user file was never created"
  fi

  if ! command -v claude >/dev/null 2>&1; then echo "BLOCKED: claude is not on the guest PATH" >&2; exit 4; fi
  probe_out="$HOME/adopt-plugins-probe.jsonl"
  ( cd "$sbx" && claude -p --output-format stream-json --verbose --permission-mode default "Reply with the single word ok." ) > "$probe_out" 2> "$HOME/adopt-plugins-probe.err" || true
  if ! jq -e 'select(.type == "system" and .subtype == "init")' "$probe_out" >/dev/null 2>&1; then
    echo "BLOCKED: the live session produced no init message: $(head -c 400 "$HOME/adopt-plugins-probe.err")" >&2
    exit 4
  fi
  init_plugins=$(jq -c 'select(.type == "system" and .subtype == "init") | [.plugins[]? | (.name // .)] ' "$probe_out" | head -1)
  echo "init plugins: $init_plugins"
  printf '%s' "$init_plugins" | jq -e 'any(.[]; test("himmel-ops"))' >/dev/null 2>&1 \
    && pass "the init message lists himmel-ops" || fail "the init message lists himmel-ops (apply the spec's A26 fallback)" "$init_plugins"
  [ "$fails" -eq 0 ] && { echo "RESULT: all ok"; exit 0; }
  echo "RESULT: $fails failure(s)"; exit 1
fi

VM="${1:-}"
case "$VM" in
  himmel-ar-[0-9]|himmel-ar-[0-9][0-9]|himmel-ci-[0-9]|himmel-ci-[0-9][0-9]) ;;
  *) echo "usage: test-adopt-plugins-vm.sh <vm>  (vm: himmel-ar-N or himmel-ci-N, never the golden image)" >&2; exit 2 ;;
esac

SNAPSHOT="${HIMMEL_ADOPT_PLUGINS_SNAPSHOT:-suite-ready-v4}"
STAGE_PATHS=(scripts .claude docs/setup marketplace .nvmrc templates/luna-second-brain)

vmsdk() {
  if [ -n "${HIMMEL_ADOPT_PLUGINS_VMSDK:-}" ]; then "$HIMMEL_ADOPT_PLUGINS_VMSDK" "$VM" "$@"
  elif command -v uv >/dev/null 2>&1; then uv run "$REPO/scripts/lib/vmsdk.py" "$VM" "$@"
  else python3 "$REPO/scripts/lib/vmsdk.py" "$VM" "$@"; fi
}
gx() {
  if [ -n "${HIMMEL_ADOPT_PLUGINS_GUEST_EXEC:-}" ]; then "$HIMMEL_ADOPT_PLUGINS_GUEST_EXEC" "$VM" "$@"
  else bash "$REPO/scripts/vm/guest-exec.sh" "$VM" "$@"; fi
}
# shellcheck disable=SC2329  # passed to vm_guest_assert_clean as its runner
gx_run() { gx -- "$1"; }

# shellcheck source=vm-lock.sh
. "$HERE/vm-lock.sh" || { echo "test-adopt-plugins-vm: cannot load vm-lock.sh" >&2; exit 3; }
# shellcheck source=../lib/vm-guest-excludes.sh
. "$REPO/scripts/lib/vm-guest-excludes.sh" || { echo "test-adopt-plugins-vm: cannot load vm-guest-excludes.sh; nothing was copied" >&2; exit 3; }

STAGE_TMP="${HIMMEL_ADOPT_PLUGINS_STAGE_TMP:-${TMPDIR:-/tmp}}"
TARBALL="" OUT="" LOCKED=0 BOOTED=0
# shellcheck disable=SC2329  # EXIT trap
cleanup() {
  local rc=$?
  trap - EXIT
  [ -z "$TARBALL" ] || rm -f "$TARBALL"
  [ -z "$OUT" ] || rm -f "$OUT"
  if [ "$BOOTED" = 1 ]; then
    vmsdk restore "$SNAPSHOT" >/dev/null 2>&1 || { echo "test-adopt-plugins-vm: restore $SNAPSHOT after the run failed; $VM may be dirty" >&2; rc=3; }
    vmsdk down >/dev/null 2>&1 || { echo "test-adopt-plugins-vm: could not power $VM off" >&2; rc=3; }
  fi
  [ "$LOCKED" != 1 ] || vm_lock_release "$VM"
  exit "$rc"
}
trap cleanup EXIT

vm_lock_acquire_waiting "$VM" || { echo "test-adopt-plugins-vm: vm-lock for $VM is held; refusing" >&2; exit 3; }
LOCKED=1

bash "$REPO/scripts/lib/usage-preflight.sh" || { echo "test-adopt-plugins-vm: usage preflight did not say PROCEED" >&2; exit 3; }

echo "==> adopt-plugins stage: $VM @ $SNAPSHOT (worktree: $REPO)"
BOOTED=1
vmsdk restore "$SNAPSHOT" >/dev/null || { echo "test-adopt-plugins-vm: restore $SNAPSHOT failed" >&2; exit 3; }
vmsdk up >/dev/null || { echo "test-adopt-plugins-vm: up failed" >&2; exit 3; }

TARBALL="$(mktemp "$STAGE_TMP/adopt-plugins-tree.XXXXXX")" || exit 3
tar_excl=(); while IFS= read -r _x; do tar_excl+=("$_x"); done < <(vm_guest_tar_excludes)
{ git -C "$REPO" ls-files -z --cached --others --exclude-standard -- "${STAGE_PATHS[@]}" \
    | while IFS= read -r -d '' _f; do [ -L "$REPO/$_f" ] || printf '%s\0' "$_f"; done; } \
  | tar -C "$REPO" "${tar_excl[@]}" -czf "$TARBALL" --null -T - \
  || { echo "test-adopt-plugins-vm: could not build the stage tarball" >&2; exit 3; }
vmsdk push "$TARBALL" /tmp/himmel-adopt-plugins-tree.tgz >/dev/null || { echo "test-adopt-plugins-vm: push failed" >&2; exit 3; }
gx -- "rm -rf $REMOTE_DIR && mkdir -p $REMOTE_DIR && tar -xzf /tmp/himmel-adopt-plugins-tree.tgz -C $REMOTE_DIR && rm -f /tmp/himmel-adopt-plugins-tree.tgz" >/dev/null \
  || { echo "test-adopt-plugins-vm: could not unpack the tree on $VM" >&2; exit 3; }
vm_guest_assert_clean gx_run "$REMOTE_DIR" full || exit 3

OUT="$(mktemp "$STAGE_TMP/adopt-plugins-out.XXXXXX")" || exit 3
gx --timeout 1800 -- "HIMMEL_ADOPT_PLUGINS_GUEST=1 bash $REMOTE_DIR/scripts/vm/test-adopt-plugins-vm.sh $REMOTE_DIR" 2>&1 | tee "$OUT"
rc="${PIPESTATUS[0]}"
if [ "$rc" -eq 0 ]; then echo "==> adopt-plugins stage PASSED"; else echo "==> adopt-plugins stage FAILED (rc=$rc)" >&2; fi
exit "$rc"
