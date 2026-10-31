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
NODE_VERSION="26.13.0"
NODE_TARBALL_SHA256="d28a96af6c38596f6d9d97c0ee531c13d238d757742387d1928de822d959e997"
NODE_BIN_SHA256="0adde40d1b7dfa57c8bc83cbc319758c3ec6ebba21363bb2fa752ea6b267ad1b"

# uv — GHSA-hq85-5cpj-mr62 is fixed from 0.13.4.
UV_VERSION="0.13.6"
UV_SHA256="f29c3e94ffabd7e6f3ba521dba169a9b7ec12100bf3257087f0f24f6123f3645"

# Claude Code — the native binary, checksum from the release manifest.
CLAUDE_VERSION="2.1.316"
CLAUDE_LINUX_X64_SHA256="fd13c70000fec3f2116dfbcbb6121210b4a29328bf0e46210a59dd594a67d824"

# RTK — the versioned .deb, never the mutable rtk_amd64.deb alias.
RTK_VERSION="1.1.0"
RTK_DEB_SHA256="21c4a2e30879ce49ebd939fa338c99208871ba591da9feeb483f2ed266fe7163"

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
