#!/usr/bin/env bash
# test-installer-pins.sh. What our own installers pull onto a
# machine must be an exact version whose bytes are checked against a pinned
# sha256: no `curl | sh`, no `releases/latest`, no mutable `rtk_amd64.deb`
# alias, no `npm@latest` / `bun upgrade` in the updater, certifi at a release
# that dropped the eMudhra (emSign) compromised intermediates.
#
# The FIXTURE_* rows below are copied verbatim from the upstream artifacts as
# fetched on a credential-free VM on 2026-10-22 (SHASUMS256.txt, .sha256,
# checksums.txt, the claude manifest, the node binary), not hand-written. The
# pin file must agree with them byte for byte.
set -uo pipefail

repo_root=$(git rev-parse --show-toplevel)
ms="$repo_root/scripts/machine-setup"
pins="$ms/installer-pins.sh"
ubuntu="$ms/ubuntu.sh"
update="$repo_root/scripts/himmel-update.sh"

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1"; }
check() { if "${@:2}"; then ok "$1"; else bad "$1"; fi; }

work=$(mktemp -d "${TMPDIR:-/tmp}/installer-pins.XXXXXX") || exit 1; trap 'rm -rf "$work"' EXIT

# ── Upstream fixtures (real) ────────────────────────────────────────────────
FIXTURE_BUN_SHASUMS='bf8ccbfb2b0b80159e0f9a6d15c55317add8077534dbc6130a3edb52fccb395c  bun-linux-x64.zip'
FIXTURE_UV_SHA256='f29c3e94ffabd7e6f3ba521dba169a9b7ec12100bf3257087f0f24f6123f3645  uv-x86_64-unknown-linux-gnu.tar.gz'
FIXTURE_RTK_CHECKSUMS='21c4a2e30879ce49ebd939fa338c99208871ba591da9feeb483f2ed266fe7163  rtk_1.1.0-1_amd64.deb'
FIXTURE_NODE_TARBALL='d28a96af6c38596f6d9d97c0ee531c13d238d757742387d1928de822d959e997  node-v26.13.0-linux-x64.tar.xz'
FIXTURE_NODE_BIN='0adde40d1b7dfa57c8bc83cbc319758c3ec6ebba21363bb2fa752ea6b267ad1b  node-v26.13.0-linux-x64/bin/node'
FIXTURE_CLAUDE_MANIFEST_LINUX_X64='fd13c70000fec3f2116dfbcbb6121210b4a29328bf0e46210a59dd594a67d824'
FIXTURE_NVM_INSTALL='48a0eee9a60e07422dce0eb5774754c83889570ca1ee2566c516acbe8af03a9e  install.sh'
FIXTURE_NVM_TAG_COMMIT='a885b885fef16fac4bc544188fb25e9e37ae83e8'
FIXTURE_CERTIFI_WHEEL='42d35340cc5b9ba78e818ddbff0c5b1c2b779de448a340fd1b989f5fa8670e1b'
FIXTURE_CERTIFI_SDIST='035c1e85572b141bf1c3a3eff0e33a8eb74917522f2559075ff8d2fea780a1ae'

echo "installers: no unpinned curl-pipe, no moving alias (HIMMEL-7092)"
no_match() { grep -Eq -- "$1" "$2"; [ $? -eq 1 ]; }
printf 'curl -fsSL https://example.invalid/i.sh | sh\n' > "$work/positive-control"
check "matcher flags a curl | sh line (positive control)" test "$(grep -Ec 'curl[^#|]*\|[[:space:]]*(ba)?sh' "$work/positive-control")" = 1
check "matcher errors are not a pass (unreadable file)"   test "$(no_match x "$work/does-not-exist" && echo pass || echo fail)" = fail
check "ubuntu.sh has no curl | sh / curl | bash"      no_match 'curl[^#|]*\|[[:space:]]*(ba)?sh' "$ubuntu"
check "ubuntu.sh has no releases/latest lookup"       no_match 'releases/latest' "$ubuntu"
check "ubuntu.sh has no mutable rtk_amd64.deb alias"  no_match 'rtk_amd64\.deb' "$ubuntu"
check "ubuntu.sh sources installer-pins.sh"           grep -q 'installer-pins\.sh' "$ubuntu"
fetches=$(grep -c '^[[:space:]]*pin_fetch ' "$ubuntu" 2>/dev/null || true)
check "ubuntu.sh pin_fetch's nvm, uv, bun, claude, rtk (>=5, got ${fetches:-0})" test "${fetches:-0}" -ge 5
check "ubuntu.sh checks the node binary sha256"       grep -q 'NODE_BIN_SHA256' "$ubuntu"
check "ubuntu.sh verifies node before nvm can run it" test "$(grep -n 'NODE_BIN_SHA256' "$ubuntu" | head -1 | cut -d: -f1)" -lt "$(grep -n '^nvm install ' "$ubuntu" | head -1 | cut -d: -f1)"
check "himmel-update.sh has no npm@latest"            no_match 'npm install -g npm@latest' "$update"
check "himmel-update.sh does not run bun upgrade"     no_match 'bun_out="\$\(bun upgrade' "$update"
check "himmel-update.sh hints have no curl | sh"      no_match 'curl[^#|"]*\|[[:space:]]*(ba)?sh' "$update"

echo "pins: values equal the upstream-published rows"
if [ -f "$pins" ]; then
  # shellcheck disable=SC1090
  . "$pins"
  check "uv sha256"            test "${UV_SHA256:-}  uv-x86_64-unknown-linux-gnu.tar.gz" = "$FIXTURE_UV_SHA256"
  check "uv version 0.13.6"    test "${UV_VERSION:-}" = "0.13.6"
  check "bun sha256 (1.4.4)"   test "$(bun_sha256 1.4.4 2>/dev/null):  bun-linux-x64.zip" = "${FIXTURE_BUN_SHASUMS%%  *}:  bun-linux-x64.zip"
  check "rtk deb sha256"       test "${RTK_DEB_SHA256:-}  rtk_${RTK_VERSION:-}-1_amd64.deb" = "$FIXTURE_RTK_CHECKSUMS"
  check "node tarball sha256"  test "${NODE_TARBALL_SHA256:-}  node-v${NODE_VERSION:-}-linux-x64.tar.xz" = "$FIXTURE_NODE_TARBALL"
  check "node binary sha256"   test "${NODE_BIN_SHA256:-}  node-v${NODE_VERSION:-}-linux-x64/bin/node" = "$FIXTURE_NODE_BIN"
  check "claude linux-x64 sha256" test "${CLAUDE_LINUX_X64_SHA256:-}" = "$FIXTURE_CLAUDE_MANIFEST_LINUX_X64"
  check "nvm install.sh sha256" test "${NVM_INSTALL_SHA256:-}  install.sh" = "$FIXTURE_NVM_INSTALL"
  check "nvm tag commit"       test "${NVM_COMMIT:-}" = "$FIXTURE_NVM_TAG_COMMIT"
  check "nvm tag v0.40.8"      test "${NVM_TAG:-}" = "v0.40.8"
  check "pinned node major == .nvmrc major" test "${NODE_VERSION%%.*}" = "$(tr -d '[:space:]v' < "$repo_root/.nvmrc" | cut -d. -f1)"
  check "bun sha table covers .bun-version" test -n "$(bun_sha256 "$(tr -d '[:space:]' < "$repo_root/.bun-version")" 2>/dev/null)"
  # shellcheck disable=SC2016 # the inner shell expands $1
  check "bun_sha256 refuses an unknown version" bash -c '. "$1"; ! bun_sha256 0.0.1 >/dev/null 2>&1' _ "$pins"
else
  bad "installer-pins.sh missing ($pins)"
fi

echo "pin_fetch: verifies the sha256 and removes a tampered download"
if [ -f "$pins" ]; then
  stubs="$work/stubs"; mkdir -p "$stubs"
  cat > "$stubs/curl" <<'EOF'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    --proto|--proto-redir) shift 2 ;;
    *) shift ;;
  esac
done
cp "$PIN_TEST_SRC" "$out"
EOF
  chmod +x "$stubs/curl"
  printf 'genuine bytes\n' > "$work/genuine"
  printf 'tampered bytes\n' > "$work/tampered"
  want=$( (sha256sum "$work/genuine" 2>/dev/null || shasum -a 256 "$work/genuine") | cut -d' ' -f1)
  run_fetch() { ( PATH="$stubs:$PATH" PIN_TEST_SRC="$1" bash -c '. "$1"; pin_fetch https://example.invalid/x "$2" "$3"' _ "$pins" "$want" "$work/dest" ) >/dev/null 2>&1; }
  rm -f "$work/dest"
  check "genuine bytes accepted"          run_fetch "$work/genuine"
  check "genuine bytes left at dest"      test -s "$work/dest"
  rm -f "$work/dest"
  if run_fetch "$work/tampered"; then bad "tampered bytes rejected (pin_fetch returned 0)"; else ok "tampered bytes rejected (non-zero)"; fi
  check "tampered bytes removed from dest" test ! -e "$work/dest"
fi

echo "certifi: pinned past the emSign-compromised release (HIMMEL-7092)"
for f in requirements-scrapling.txt requirements-whisper.txt; do
  p="$repo_root/marketplace/plugins/obsidian-triage/tools/$f"
  check "$f pins certifi==2026.10.19"      grep -q '^certifi==2026\.10\.19 ' "$p"
  check "$f no longer pins certifi 2026.7.22" no_match '^certifi==2026\.7\.22' "$p"
  check "$f carries the wheel hash"        grep -q "sha256:$FIXTURE_CERTIFI_WHEEL" "$p"
  check "$f carries the sdist hash"        grep -q "sha256:$FIXTURE_CERTIFI_SDIST" "$p"
done

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
