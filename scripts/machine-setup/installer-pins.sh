#!/usr/bin/env bash
# installer-pins.sh — sourced by ubuntu.sh (and read by macos.sh). Every tool
# our installer pulls onto a machine is an exact version whose bytes are
# checked against a sha256 pinned here. No `curl | sh`, no `releases/latest`.
#
# Each value was taken from the upstream-published checksum on a credential-free
# VM and cross-checked against the git tag. To
# move a pin: fetch the new artifact on a VM, verify it against the upstream
# checksum file and the tag, then change the version and the sha256 together.
# Defining the pins has no side effects.
# shellcheck disable=SC2034 # the pins are consumed by the script that sources this

# nvm — install.sh at an exact tag; the clone it makes must land on NVM_COMMIT.
NVM_TAG="v0.40.8"
NVM_COMMIT="a885b885fef16fac4bc544188fb25e9e37ae83e8"
NVM_INSTALL_SHA256="48a0eee9a60e07422dce0eb5774754c83889570ca1ee2566c516acbe8af03a9e"

# node — exact patch release (its major must equal .nvmrc); sha256 of the
# linux-x64 .tar.xz and of the bin/node inside it. This release also drops the emSign
# ECC G3 root from node's bundled CA store.
NODE_VERSION="24.22.1"
NODE_TARBALL_SHA256="6c172a9ab6718f7b801fb5a7bd486af2ee5e32758086a04b84fcce2aa77095e6"
NODE_BIN_SHA256="e32e2d16081cf644f88392934288086e7662529d0d43277c34f7aad2207cfafb"

# uv — GHSA-hq85-5cpj-mr62 is fixed from 0.13.4.
UV_VERSION="0.13.4"
UV_SHA256="2b428396f12572d4429cf210ca234dd599a33b3af0958a4d5ed569d63e3f344f"

# Claude Code — the native binary, checksum from the release manifest.
CLAUDE_VERSION="2.1.296"
CLAUDE_LINUX_X64_SHA256="24972e3bc859fab2b46ed4c1e51f7d6130f06d3bd550811a114640de3370d0de"

# RTK — the versioned .deb, never the mutable rtk_amd64.deb alias.
RTK_VERSION="1.0.1"
RTK_DEB_SHA256="b7f7ed3ce136aa842f56599b5ca88b956bd788a111ec7bd085909f9aeb0d1bc4"

# bun — the version is .bun-version; a version without a row here is refused.
bun_sha256() {
  case "$1" in
    1.4.4) echo "bf8ccbfb2b0b80159e0f9a6d15c55317add8077534dbc6130a3edb52fccb395c" ;;
    *) echo "ERROR: no pinned sha256 for bun $1 — add it to installer-pins.sh after verifying the release on a VM" >&2; return 1 ;;
  esac
}

# _sha256_check — verifies "<sha>  <file>" lines on stdin: sha256sum where it
# exists (Linux, and the stub the ubuntu shim test puts on PATH), else macOS shasum.
_sha256_check() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum -c -; else shasum -a 256 -c -; fi
}

# pin_fetch <https-url> <sha256> <dest> — download, verify, or leave nothing.
pin_fetch() {
  local url="$1" sha="$2" dest="$3"
  rm -f "$dest"
  if ! curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 -o "$dest" "$url"; then
    rm -f "$dest"
    echo "ERROR: download failed: $url" >&2
    return 1
  fi
  if ! printf '%s  %s\n' "$sha" "$dest" | _sha256_check >/dev/null 2>&1; then
    rm -f "$dest"
    echo "ERROR: sha256 mismatch for $url (expected $sha) — refusing to install" >&2
    return 1
  fi
}
