#!/usr/bin/env bash
# claudex-guest-provision.sh — runs ON the claudex test-VM guest (pushed and run by
# scripts/vm/claudex-guest.sh provision). Idempotent: a re-run keeps the key.
#
# Leaves the guest with the cli-proxy lane installed and running on 127.0.0.1:8317 and a
# `claude-codex` command on every shell's PATH. It does NOT log in: the Codex device-code
# login is the operator's one-time act (docs/setup/vms.md "claudex guest"). The proxy key
# is a fresh random guest-local value in a 0600 file; the guest holds no .env and no
# station credential.
set -uo pipefail

# every step below must succeed: a failure ends the run with its own exit code
trap 'exit 1' ERR
cfg="$HOME/.config/himmel"
keyf="$cfg/cliproxy.key"
mkdir -p "$cfg" "$HOME/.claude"
[ -e "$keyf" ] || ( umask 077; head -c 24 /dev/urandom | base64 | tr -d '=+/\n' > "$keyf" )
# claude-codex refuses to launch without a settings.json (an empty one is enough)
[ -e "$HOME/.claude/settings.json" ] || echo '{}' > "$HOME/.claude/settings.json"

# A wrapper, not a symlink: scripts/claude-codex finds its lib/ next to itself, and a
# non-login ssh shell has neither ~/.local/bin on PATH nor the key in its environment.
tmp="$(mktemp /tmp/claude-codex-wrapper.XXXXXX)" || exit 1
cat > "$tmp" <<'WRAP'
#!/bin/sh
CLIPROXY_API_KEY="$(cat "$HOME/.config/himmel/cliproxy.key")" || exit 1
export CLIPROXY_API_KEY
exec bash "$HOME/himmel/scripts/claude-codex" "$@"
WRAP
sudo install -m 755 "$tmp" /usr/local/bin/claude-codex
rm -f "$tmp"

# the user unit needs a user manager: linger starts one without a login session
sudo loginctl enable-linger "$(id -un)"
XDG_RUNTIME_DIR="/run/user/$(id -u)"
export XDG_RUNTIME_DIR
CLIPROXY_API_KEY="$(cat "$keyf")"
export CLIPROXY_API_KEY
bash "$HOME/himmel/scripts/setup/cli-proxy-lane.sh" --install
bash "$HOME/himmel/scripts/setup/cli-proxy-lane.sh" --register
bash "$HOME/himmel/scripts/setup/cli-proxy-lane.sh" --status || true
