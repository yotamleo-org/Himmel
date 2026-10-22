#!/usr/bin/env bash
set -euo pipefail

# ── Args ────────────────────────────────────────────────────────────────────
LUNA_REMOTE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --luna-remote) [[ $# -ge 2 ]] || { echo "ERROR: --luna-remote requires a value" >&2; exit 2; }; LUNA_REMOTE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# Fail CLOSED on --luna-remote BEFORE any provisioning.
# The old script cloned the remote vault itself; the delegated himmelctl flow
# does not support remote-vault restore yet, so accepting
# the flag and silently dropping it would let a machine rebuild complete
# WITHOUT the operator's vault.
if [[ -n "$LUNA_REMOTE" ]]; then
  echo "ERROR: --luna-remote is not supported by the delegated himmelctl flow yet (HIMMEL-755)." >&2
  echo "  Clone the vault manually first:  git clone $LUNA_REMOTE ~/Documents/luna" >&2
  echo "  then re-run this script WITHOUT --luna-remote." >&2
  exit 1
fi

# ── Paths ───────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC2034
HIMMEL_PATH="$HOME/github/himmel"

# Every tool below is an exact version checked against a pinned sha256
# (installer-pins.sh); nothing is fetched as a piped installer or as "latest".
# shellcheck source=installer-pins.sh
. "$REPO_ROOT/scripts/machine-setup/installer-pins.sh"

# The pinned artifacts below are linux-x64 builds; fail before any provisioning
# rather than install a binary that cannot run.
if [ "$(uname -m)" != "x86_64" ]; then
  echo "ERROR: this installer pins linux-x64 artifacts; $(uname -m) is not supported" >&2
  exit 1
fi

PIN_TMP="$(mktemp -d "${TMPDIR:-/tmp}/himmel-pins.XXXXXX")" || exit 1  # prim-ok: root-owned download dir, apt must read the .deb
chmod 0755 "$PIN_TMP"   # apt (sandbox user _apt) must be able to read the .deb
trap 'rm -rf "$PIN_TMP"' EXIT

# ── PATH hoist ──────────────────────────────────────────────────────────────
# uv and the native Claude Code installer both drop binaries into
# ~/.local/bin. Prepend once here so every step picks them up — avoids the
# per-step re-export duplication.
mkdir -p "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"

# ── Progress ────────────────────────────────────────────────────────────────
TOTAL_STEPS=9
STEP=0

step() {
  STEP=$((STEP + 1))
  echo ""
  echo "══════════════════════════════════════════════"
  echo "[$STEP/$TOTAL_STEPS] $1"
  echo "══════════════════════════════════════════════"
}

# ── Steps (1–8): set -e active throughout ───────────────────────────────────
step "Update package manager"
sudo apt update
sudo apt upgrade -y

step "Install core tools: git, Python, jq, curl, shellcheck, gitleaks"
# The shellcheck and gitleaks binaries are referenced by .pre-commit-config.yaml.
# pre-commit downloads its own copies inside the hook framework, but local
# direct invocation (manual lint runs, smoke tests) needs them on PATH.
sudo apt install -y git python3 python3-pip jq curl xz-utils shellcheck gitleaks

step "Install nvm + Node from .nvmrc"
export NVM_DIR="$HOME/.nvm"
nvm_head() { git -C "$NVM_DIR" rev-parse HEAD 2>/dev/null || true; }
if [ "$(nvm_head)" != "$NVM_COMMIT" ]; then
  pin_fetch "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_TAG}/install.sh" \
    "$NVM_INSTALL_SHA256" "$PIN_TMP/nvm-install.sh"
  # A commit id is content-addressed, so the nvm.sh install.sh sources at its end
  # is the pinned one even if the tag was moved.
  NVM_INSTALL_VERSION="$NVM_COMMIT" bash "$PIN_TMP/nvm-install.sh"
  if [ "$(nvm_head)" != "$NVM_COMMIT" ]; then
    echo "ERROR: nvm at $NVM_DIR is not the pinned ${NVM_TAG} commit ${NVM_COMMIT}" >&2
    exit 1
  fi
fi
# shellcheck disable=SC1091
. "$NVM_DIR/nvm.sh"
NVMRC_VERSION="$(cat "$REPO_ROOT/.nvmrc")"
# nvm runs the node it unpacks, so the verified tarball is unpacked into nvm's
# version directory first; nvm then finds the version installed and downloads nothing.
NODE_DIR="$NVM_DIR/versions/node/v${NODE_VERSION}"
if [ ! -x "$NODE_DIR/bin/node" ]; then
  pin_fetch "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
    "$NODE_TARBALL_SHA256" "$PIN_TMP/node.tar.xz"
  mkdir -p "$NODE_DIR"
  if ! tar -xf "$PIN_TMP/node.tar.xz" -C "$NODE_DIR" --strip-components=1; then
    rm -rf "$NODE_DIR"
    echo "ERROR: could not unpack the node tarball" >&2
    exit 1
  fi
fi
printf '%s  %s\n' "$NODE_BIN_SHA256" "$NODE_DIR/bin/node" | sha256sum -c - >/dev/null \
  || { echo "ERROR: node $NODE_VERSION binary does not match the pinned sha256" >&2; exit 1; }
nvm install "$NODE_VERSION"
nvm use "$NODE_VERSION"
nvm alias default "$NODE_VERSION"

ACTUAL_MAJOR="$(node --version | sed 's/^v\([0-9]*\).*/\1/')"
_nv="${NVMRC_VERSION#v}"
EXPECT_MAJOR="${_nv%%.*}"
if [ "$ACTUAL_MAJOR" != "$EXPECT_MAJOR" ]; then
  echo "ERROR: node major $ACTUAL_MAJOR != expected $EXPECT_MAJOR from .nvmrc"
  exit 1
fi
echo "Node $(node --version) active (.nvmrc=$NVMRC_VERSION, pinned $NODE_VERSION)"

step "Install uv + uvx"
# shellcheck disable=SC2153 # UV_* come from installer-pins.sh
pin_fetch "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-gnu.tar.gz" \
  "$UV_SHA256" "$PIN_TMP/uv.tar.gz"
tar -xzf "$PIN_TMP/uv.tar.gz" -C "$PIN_TMP"
install -m 0755 "$PIN_TMP/uv-x86_64-unknown-linux-gnu/uv" "$PIN_TMP/uv-x86_64-unknown-linux-gnu/uvx" "$HOME/.local/bin/"
uv --version

# Bun is a hard dependency of himmel-update.sh's qmd fork
# updater (update_qmd_fork) and the jira CLI dist rebuild's npm-absent
# fallback — no installer installed it before this, so on a bun-less machine
# qmd silently never updated (a clean-looking skip; see report_qmd_bun_missing
# in himmel-update.sh for the loud follow-up now added for that case). Same
# official installer docs/setup/new-machine.md already documents for Linux;
# it lands the binary in ~/.bun/bin, which is NOT on the default PATH.
# The version is .bun-version; installer-pins.sh refuses one it has no sha256 for.
step "Install bun (qmd fork updater + jira CLI hard dependency)"
BUN_VERSION="$(tr -d '[:space:]' < "$REPO_ROOT/.bun-version")"
BUN_SHA256="$(bun_sha256 "$BUN_VERSION")"
pin_fetch "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/bun-linux-x64.zip" \
  "$BUN_SHA256" "$PIN_TMP/bun.zip"
python3 -m zipfile -e "$PIN_TMP/bun.zip" "$PIN_TMP/bun-x"
mkdir -p "$HOME/.bun/bin"
install -m 0755 "$PIN_TMP/bun-x/bun-linux-x64/bun" "$HOME/.bun/bin/bun"
ln -sf bun "$HOME/.bun/bin/bunx"
export PATH="$HOME/.bun/bin:$PATH"
# shellcheck disable=SC2016 # the literal $HOME/$PATH belong in the rc file
bun_path_line='export PATH="$HOME/.bun/bin:$PATH"'
grep -qsF "$bun_path_line" "$HOME/.bashrc" || printf '\n# bun (himmel installer)\n%s\n' "$bun_path_line" >> "$HOME/.bashrc"
bun --version

step "Install Claude Code CLI (native installer — no npm dependency)"
pin_fetch "https://downloads.claude.ai/claude-code-releases/${CLAUDE_VERSION}/linux-x64/claude" \
  "$CLAUDE_LINUX_X64_SHA256" "$PIN_TMP/claude"
chmod +x "$PIN_TMP/claude"
"$PIN_TMP/claude" install "$CLAUDE_VERSION"
claude --version

step "Install RTK"
# The versioned `rtk_${VER}-1_amd64.deb` (note the `-1` debian revision),
# checksum-pinned — never the release's mutable unversioned alias or a
# latest-release lookup, either of which would install whatever was published last.
pin_fetch "https://github.com/rtk-ai/rtk/releases/download/v${RTK_VERSION}/rtk_${RTK_VERSION}-1_amd64.deb" \
  "$RTK_DEB_SHA256" "$PIN_TMP/rtk.deb"
sudo apt install -y "$PIN_TMP/rtk.deb"
rm -rf "$PIN_TMP"
# Hook wiring (`rtk init -g --auto-patch` + guard reconcile) happens in the
# clone step below — adjacent to the reconcile so a clone/hookspath failure
# can never strand a raw unguarded hook.
rtk --version

step "Clone himmel repo"
mkdir -p "$(dirname "$HIMMEL_PATH")"
if [ -d "$HIMMEL_PATH/.git" ]; then
  # Idempotent re-run: fetch AND fast-forward the checked-out branch to its
  # upstream — a bare fetch updates refs only, leaving the working tree (and the
  # bootstrap.sh this script exec's below) STALE, so the re-run would provision
  # from old code. --ff-only never clobbers a diverged/dirty/detached operator
  # clone: it fails, we note it, and reuse the existing checkout.
  git -C "$HIMMEL_PATH" fetch --all --prune
  git -C "$HIMMEL_PATH" merge --ff-only '@{u}' 2>/dev/null \
    || echo "  note: himmel clone not fast-forward-updatable (diverged/dirty/detached HEAD) — reusing the existing checkout; update it manually if a newer himmel is needed" >&2
else
  git clone https://github.com/yotamleo-org/Himmel.git "$HIMMEL_PATH" # env-literal-ok: the machine bootstrap clones the one himmel repo; leak-allow: hostname that repo
fi
cd "$HIMMEL_PATH"

# Gate the clone for core.hooksPath misconfiguration BEFORE any
# further tooling runs. If the operator's machine inherited a bad
# core.hooksPath from a sibling repo (or copied .gitconfig), a later hook
# install would silently install hooks into a dir git is ignoring, and every
# gate (no-push-to-main, npm-audit, code-review-before-push, platforms-tested,
# hookspath-misconfig itself) would be bypassed.
bash scripts/hooks/check-hookspath.sh

# Wire the rtk hook AND immediately swap the bare `rtk hook
# claude` entry for the himmel rtk-hook-guard wrapper + dedup
# (compound-find fix). Two deliberate properties:
#   - `--auto-patch`: without it the settings.json hook-patch prompt defaults
#     to N in non-interactive runs, leaving rtk installed but the rewrite hook
#     unwired — the drift found on the win2 station.
#   - Adjacency AFTER clone + hookspath validation: the old
#     monolith did the swap inline and the delegated himmelctl flow lost it;
#     wiring earlier (before the clone) could strand a RAW unguarded hook if
#     clone/validation failed — raw rtk breaks compound find rewrites.
# Transactional (mirrors win11.ps1): rtk init mutates settings.json before
# the reconcile can guard it — on any failure in between, restore the
# pre-init settings so no partial state leaves a raw unguarded hook behind.
rtk_settings="$HOME/.claude/settings.json"
rtk_settings_bak=""
if [ -f "$rtk_settings" ]; then
  rtk_settings_bak=$(mktemp)
  cp "$rtk_settings" "$rtk_settings_bak"
fi
if ! { rtk init -g --auto-patch \
       && bash "$HIMMEL_PATH/scripts/lib/reconcile-rtk-hook.sh" "$rtk_settings" "$HIMMEL_PATH"; }; then
  if [ -n "$rtk_settings_bak" ]; then
    cp "$rtk_settings_bak" "$rtk_settings"
  else
    rm -f "$rtk_settings"
  fi
  rm -f "$rtk_settings_bak"
  echo "ERROR: rtk hook wiring failed — settings.json restored to its pre-init state" >&2
  exit 1
fi
rm -f "$rtk_settings_bak"
cd -

step "Delegate himmel/luna wiring to himmelctl bootstrap (HIMMEL-887)"
# This script is soft-deprecated for himmel/luna WIRING — the
# provisioning above (steps 1-6, full toolchain) is unchanged and stays the
# source of truth (locked decision O4: zero capability loss). Wiring (Claude
# config, plugins, luna vault, settings.json patching, hooks registration, …)
# now runs via `himmelctl bootstrap`, which re-execs into `himmelctl install`
# once node is confirmed present (it always is here — step 3 just installed
# it) — one wiring implementation instead of two drifting copies. Hard-remove
# of this now-deprecated shim script itself (once its toolchain-provisioning
# role is also absorbed) is deferred.
# (--luna-remote fail-closes at arg parse above so no remote-vault
# handling is needed here.)
#
# Delegate FROM the himmel clone, not from wherever the operator
# launched this shim. The wizard's role inference reads the CWD's git origin;
# the explicit user-scope hint below fits this machine-restore flow while the
# interactive question + plan/confirm remain unchanged. cd (not a subshell) because
# the exec below replaces this process. The wizard is interactive by design:
# an unattended/non-TTY run fails loud with remediation (documented posture);
# this cd only guarantees that when it DOES run, its inference targets the
# himmel clone deterministically.
echo "NOTICE: himmel/luna wiring in this script is soft-deprecated (HIMMEL-887) -- delegating to himmelctl bootstrap. Hard-remove deferred to HIMMEL-755."
cd "$HIMMEL_PATH"
HIMMELCTL_REPO_ROOT="$HIMMEL_PATH" exec bash "$HIMMEL_PATH/scripts/himmelctl/bootstrap.sh" --default-scope user
