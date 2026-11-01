#!/usr/bin/env bash
# claudex-guest.sh — create, provision and probe the himmel-claudex test VM: the one
# guest that carries the claudex lane (Claude Code on the Codex / cli-proxy lane), so a
# lane proof can run off-station.
#
# launch-profile-ok-file: this script runs `claude install` and `claude --version` inside a test-VM guest to pin and probe its binary; it launches no worker session, so a worker profile would change nothing it does
#
# Usage: bash scripts/vm/claudex-guest.sh create|provision|status himmel-claudex
#
#   create     linked clone of ubuntu_new@suite-ready-v4 on the fixed port 2229, first boot,
#              snapshot claudex-base (under the vm-lock on himmel-claudex)
#   provision  needs claudex-base. Guest secret scan, repo symlink + clone (the PAT is the
#              transient one vmsdk's clone verb uses), claude pinned to 2.1.314, a guest-local
#              0600 cliproxy key, cli-proxy-lane --install/--register, the worker-impl
#              settings file, then a --status check. Safe to run twice.
#   status     claude path + version, `cli-proxy-lane.sh --status` verbatim, and the exit
#              code of `claude-codex --preflight-only` (liveness, not a bank check).
#
# Every verb refuses any VM name but himmel-claudex (exit 2). Guest commands go through
# scripts/vm/guest-exec.sh only; nothing is copied from the station's own logins (a
# Codex / Claude login is made by the operator in the guest), and the guest gets no .env.
# Seams: HIMMEL_VMSDK (vmsdk.py path), VBOXMANAGE_PATH, HIMMEL_VM_PYTHON, HIMMEL_VM_LOCK_DIR.
#
# Platform guard (linux-only): VirtualBox on the station plus flock-based vm-lock.
# shellcheck disable=SC2016,SC2088  # the guest-command strings are single-quoted on purpose: the GUEST shell expands $HOME and ~
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
VM="himmel-claudex"
SOURCE_SNAPSHOT="suite-ready-v4"
BASE_SNAPSHOT="claudex-base"
PIN_PORT=2229
PIN_VERSION="2.1.314"

usage() { echo "usage: claudex-guest.sh create|provision|status $VM" >&2; exit 2; }
fail() { echo "ERROR: claudex-guest: $1" >&2; exit 1; }

[ "$#" -eq 2 ] || usage
verb="$1"
case "$verb" in create|provision|status) ;; *) usage ;; esac
[ "$2" = "$VM" ] || { echo "claudex-guest.sh: refusing '$2': only $VM (a different VM is not this script's to touch)" >&2; exit 2; }

# shellcheck source=scripts/vm/port-alloc.sh
. "$REPO_ROOT/scripts/vm/port-alloc.sh"
# shellcheck source=scripts/vm/lib/vm-clone.sh
. "$REPO_ROOT/scripts/vm/lib/vm-clone.sh"
# shellcheck source=scripts/vm/vm-lock.sh
. "$REPO_ROOT/scripts/vm/vm-lock.sh"
# shellcheck source=scripts/lib/vm-guest-excludes.sh
. "$REPO_ROOT/scripts/lib/vm-guest-excludes.sh"

# gx <timeout> <cmd...>: one guest command through guest-exec.sh (vmsdk refuses a station row).
gx() { local t="$1"; shift; bash "$HERE/guest-exec.sh" "$VM" --timeout "$t" -- "$@"; }
# gl <timeout> <script>: the same under a login shell on the guest.
gl() { gx "$1" "bash -lc $(printf '%q' "$2")"; }
# vmsdk <args...>: the sdk itself, for the verbs guest-exec does not cover (clone).
vmsdk() {
    local sdk="${HIMMEL_VMSDK:-$REPO_ROOT/scripts/lib/vmsdk.py}"
    if command -v uv >/dev/null 2>&1; then uv run "$sdk" "$@"; else python3 "$sdk" "$@"; fi
}

has_base_snapshot() {
    vbox_py 'sys.exit(0 if sys.argv[2] in vbox.list_snapshots(sys.argv[1]) else 1)' "$VM" "$BASE_SNAPSHOT"
}

# The lane scripts need claude on PATH and the guest-local key in the environment.
GUEST_ENV='export PATH="$HOME/.local/bin:$PATH"; export CLIPROXY_API_KEY="$(cat "$HOME/.config/himmel/cliproxy.key")"; cd "$HOME/himmel" || exit 97'
LANE_ENV="$GUEST_ENV && bash scripts/setup/cli-proxy-lane.sh"

# lane_status: run `cli-proxy-lane.sh --status` on the guest; sets LANE_OUT (its output, verbatim).
# The script exits 0 (lane up) or 1 (not ready, e.g. before the login), so those are both fine; a
# missing end marker (ssh drop, timeout) or any other exit code (not executable, killed) is a failure.
lane_status() {
    local raw code
    raw=$(gl 120 "$LANE_ENV --status; echo \"lane-status-exit: \$?\"" 2>&1)
    code=$(sed -n 's/^lane-status-exit: //p' <<< "$raw" | tail -n 1)
    case "$code" in
        0|1) ;;
        *) fail "cli-proxy-lane --status did not run to a normal end on $VM (exit '${code:-none}'): $raw" ;;
    esac
    LANE_OUT=$(grep -v '^lane-status-exit: ' <<< "$raw")
}

# take_vm_lock: hold the vm-lock on himmel-claudex until this process exits, so create and
# provision never interleave on the one guest.
take_vm_lock() {
    vm_lock_acquire_waiting "$VM"
    case "$?" in
        0) ;;
        5) fail "timed out waiting for the vm-lock on '$VM'" ;;
        *) fail "could not acquire the vm-lock on '$VM'" ;;
    esac
    trap 'vm_lock_release "$VM"' EXIT
}

cmd_create() {
    vm_env_init
    take_vm_lock
    # shellcheck disable=SC2034  # SOURCE_VM, CLONE_NAME and PORT are the globals vm-clone.sh reads
    SOURCE_VM=ubuntu_new
    # shellcheck disable=SC2034
    CLONE_NAME="$VM"
    vm_clone_ensure "$SOURCE_SNAPSHOT" "$PIN_PORT"
    # shellcheck disable=SC2034
    PORT="$PIN_PORT"
    vm_boot
    if has_base_snapshot; then
        echo "create: $VM already has $BASE_SNAPSHOT"
    else
        vbox_py 'vbox.take_snapshot(sys.argv[1], sys.argv[2])' "$VM" "$BASE_SNAPSHOT" \
            || fail "could not take the $BASE_SNAPSHOT snapshot on $VM"
        echo "create: $VM is up on port $PIN_PORT, snapshot $BASE_SNAPSHOT taken"
    fi
}

cmd_provision() {
    local out rc scan hits link_cmd install_cmd key_cmd settings_cmd
    vm_env_init
    take_vm_lock
    has_base_snapshot || fail "$VM has no $BASE_SNAPSHOT snapshot — run 'claudex-guest.sh create $VM' first"

    # (1) the guest must hold no secret file before anything is cloned or installed
    scan=$(vm_guest_scan_cmd '~' full) || fail "could not build the guest secret scan"
    out=$(gx 300 "$scan" 2>&1); rc=$?
    [ "$rc" -eq 0 ] || fail "the guest secret scan did not complete (exit $rc): $out"
    hits=$(vm_guest_scan_hits '~' "$out" 2>/dev/null)
    [ -z "$hits" ] || fail "the guest holds secret file(s), nothing was provisioned: $hits"

    # (2) ~/Documents/github/himmel -> ~/himmel (launch-guest.sh's GUEST_REPO), then the checkout
    link_cmd='d="$HOME/Documents/github/himmel"; if [ -L "$d" ]; then [ "$(readlink "$d")" = "$HOME/himmel" ] || { echo "$d is a symlink to something else" >&2; exit 3; }; elif [ -e "$d" ]; then echo "$d exists and is not the himmel symlink" >&2; exit 3; else mkdir -p "$HOME/Documents/github" && ln -s "$HOME/himmel" "$d"; fi'
    out=$(gx 60 "$link_cmd" 2>&1) || fail "repo path on the guest: $out"
    vmsdk "$VM" clone >/dev/null || fail "vmsdk clone on $VM failed"

    # (3) claude pinned to $PIN_VERSION, autoupdate off
    install_cmd='export PATH="$HOME/.local/bin:$PATH"; if [ "$("$HOME/.local/bin/claude" --version 2>/dev/null | cut -d" " -f1)" != '"$PIN_VERSION"' ]; then claude install '"$PIN_VERSION"' || exit 1; fi; [ "$("$HOME/.local/bin/claude" --version 2>/dev/null | cut -d" " -f1)" = '"$PIN_VERSION"' ] || { echo "installed claude version is not '"$PIN_VERSION"'" >&2; exit 1; }; grep -qxF "export DISABLE_AUTOUPDATER=1" "$HOME/.profile" 2>/dev/null || echo "export DISABLE_AUTOUPDATER=1" >> "$HOME/.profile"'
    out=$(gl 900 "$install_cmd" 2>&1) || fail "claude install $PIN_VERSION: $out"

    # (4) the guest-local cli-proxy key, created once (generated in the guest, never on a host command line)
    key_cmd='f="$HOME/.config/himmel/cliproxy.key"; mkdir -p "$HOME/.config/himmel" && chmod 700 "$HOME/.config/himmel" || exit 1; if [ "$(wc -c < "$f" 2>/dev/null)" != 64 ]; then rm -f "$f" "$f.tmp"; ( umask 077; head -c 32 /dev/urandom | od -An -tx1 | tr -d " \n" > "$f.tmp" ) || { rm -f "$f.tmp"; exit 1; }; [ "$(wc -c < "$f.tmp")" -eq 64 ] || { rm -f "$f.tmp"; exit 1; }; mv "$f.tmp" "$f" || exit 1; fi; chmod 600 "$f" || exit 1; grep -qF "cliproxy.key" "$HOME/.profile" 2>/dev/null || printf "%s\n" "export CLIPROXY_API_KEY=\"\$(cat \"\$HOME/.config/himmel/cliproxy.key\")\"" >> "$HOME/.profile"'
    out=$(gx 60 "$key_cmd" 2>&1) || fail "cliproxy key: $out"

    # (5) an empty user settings file, only when absent
    out=$(gx 60 '[ -e "$HOME/.claude/settings.json" ] || { mkdir -p "$HOME/.claude" && echo "{}" > "$HOME/.claude/settings.json"; }' 2>&1) \
        || fail "~/.claude/settings.json: $out"

    # (6) the proxy: install, then register
    out=$(gl 900 "$LANE_ENV --install" 2>&1) || fail "cli-proxy-lane --install: $out"
    out=$(gl 300 "$LANE_ENV --register" 2>&1) || fail "cli-proxy-lane --register: $out"

    # (7) the worker-impl --settings file (written whole, then moved into place)
    settings_cmd='export PATH="$HOME/.local/bin:$PATH"; cd "$HOME/himmel" && mkdir -p "$HOME/.config/himmel" && node scripts/lanes/plugin-profiles.mjs worker-impl > "$HOME/.config/himmel/worker-settings.json.tmp" && mv "$HOME/.config/himmel/worker-settings.json.tmp" "$HOME/.config/himmel/worker-settings.json"'
    out=$(gl 120 "$settings_cmd" 2>&1) || fail "worker-impl settings file: $out"

    # (8) only the 401 line is a provisioning failure (--status exits 1 until the operator has logged in)
    lane_status
    out="$LANE_OUT"
    if grep -q 'HTTP 401' <<< "$out"; then
        fail "cli-proxy key mismatch: the proxy answers HTTP 401 to the guest key (see $VM ~/.cli-proxy-api/config.yaml api-keys vs ~/.config/himmel/cliproxy.key)"
    fi
    echo "provision: $VM provisioned (run 'claudex-guest.sh status $VM' next)"
}

cmd_status() {
    local out rc claude_path version pf
    out=$(gl 60 'export PATH="$HOME/.local/bin:$PATH"; command -v claude; claude --version' 2>&1); rc=$?
    claude_path=$(sed -n 1p <<< "$out")
    version=$(sed -n 2p <<< "$out" | cut -d' ' -f1)
    echo "claude: ${claude_path:-none} ${version:-none}"
    echo "--- cli-proxy-lane.sh --status ---"
    lane_status
    printf '%s\n' "$LANE_OUT"
    # liveness only: the exit code, never the probe's output
    pf=$(gl 120 "$GUEST_ENV && { bash scripts/claude-codex --preflight-only >/dev/null 2>&1; echo \"preflight-exit: \$?\"; }" 2>&1)
    tail -n 1 <<< "$pf"
    grep -q '^preflight-exit: ' <<< "$pf" || fail "the claude-codex preflight on $VM did not run to the end: $pf"
    [ "$rc" -eq 0 ] && [ "$version" = "$PIN_VERSION" ] || fail "claude on $VM is '${version:-none}', expected $PIN_VERSION"
}

case "$verb" in
    create) cmd_create ;;
    provision) cmd_provision ;;
    status) cmd_status ;;
esac
