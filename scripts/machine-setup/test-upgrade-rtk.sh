#!/usr/bin/env bash
# test-upgrade-rtk.sh — hermetic suite for upgrade-rtk.sh.
#
# Fully offline: a fake `rtk` script (embedding its own version literal, same
# fixture shape as scripts/upstreams/test-apply-drift-bump.sh's widget-bin.sh)
# stands in for the real binary. RTK_UPGRADE_PLATFORM forces the Linux
# backup/smoke/rollback code path regardless of the host OS this suite
# actually runs on (Windows Git-Bash included) and lets the "unsupported
# platform" branch be exercised without a real Mac. RTK_DOWNLOAD_CMD replaces
# the real curl+apt install step with a fixture "installer" script, so no
# network call and no real rtk install are ever touched.
#
# bash 3.2-safe (macOS ships 3.2): no mapfile, no associative arrays.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPGRADE="$SCRIPT_DIR/upgrade-rtk.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; [ $# -ge 2 ] && printf '    %s\n' "$2"; FAIL=$((FAIL + 1)); }

assert_rc() {
  local label="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then
    pass "$label (rc=$got)"
  else
    fail "$label" "expected rc=$want, got rc=$got"
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*) pass "$label" ;;
    *) fail "$label" "missing: $needle" ;;
  esac
}

# Explicit template: BSD `mktemp -d` (stock macOS) requires one and exits
# non-zero without it, so the suite would die before its first case there.
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/upgrade-rtk-test.XXXXXX")"
cleanup() { rm -rf "$TMP_ROOT" 2>/dev/null || true; }
trap cleanup EXIT

BIN_DIR="$TMP_ROOT/bin"
mkdir -p "$BIN_DIR"
RTK_FIXTURE="$BIN_DIR/rtk"
INSTALL_DIR="$TMP_ROOT/install-scratch"
FIX_DIR="$TMP_ROOT/installers"
mkdir -p "$FIX_DIR"

# write_fake_rtk <version> <ls-ok:0|1> — a self-contained fixture: the
# version is a literal baked into the script text itself (not read from a
# side-channel state file), so "restore the backup" is provably byte-for-byte
# recoverable by a plain file copy.
write_fake_rtk() {
  local version="$1" ls_ok="$2"
  cat > "$RTK_FIXTURE" <<EOF
#!/usr/bin/env bash
case "\$1" in
  --version) echo "rtk $version"; exit 0 ;;
  ls)
    if [ "$ls_ok" = "1" ]; then command ls "\$2" >/dev/null 2>&1; exit 0; fi
    exit 1
    ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$RTK_FIXTURE"
}

# ---------------------------------------------------------------------------
# installer fixtures (used via RTK_DOWNLOAD_CMD — the download/install seam)
# ---------------------------------------------------------------------------

# Success: writes a newer working fixture (ls probe ok) and stamps a marker
# so a test can prove whether it was actually invoked.
cat > "$FIX_DIR/install-ok.sh" <<'EOF'
#!/usr/bin/env bash
touch "$(dirname "$0")/invoked-ok"
cat > "$RTK_BIN_PATH" <<'INNER'
#!/usr/bin/env bash
case "$1" in
  --version) echo "rtk 0.44.0"; exit 0 ;;
  ls) command ls "$2" >/dev/null 2>&1; exit 0 ;;
  *) exit 1 ;;
esac
INNER
chmod +x "$RTK_BIN_PATH"
EOF
chmod +x "$FIX_DIR/install-ok.sh"

# Simulated failed smoke test: --version correctly reports a newer build, but
# the functional probe (`rtk ls <tmpdir>`) always fails -- exercises the
# smoke-test-fails-not-install-fails branch specifically.
cat > "$FIX_DIR/install-smoke-fail-ls.sh" <<'EOF'
#!/usr/bin/env bash
cat > "$RTK_BIN_PATH" <<'INNER'
#!/usr/bin/env bash
case "$1" in
  --version) echo "rtk 0.44.0"; exit 0 ;;
  ls) exit 1 ;;
  *) exit 1 ;;
esac
INNER
chmod +x "$RTK_BIN_PATH"
EOF
chmod +x "$FIX_DIR/install-smoke-fail-ls.sh"

# The install step itself fails outright (e.g. apt/network failure) --
# $RTK_BIN_PATH is never touched.
cat > "$FIX_DIR/install-cmd-fail.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$FIX_DIR/install-cmd-fail.sh"

reset_fixture() {
  rm -rf "$INSTALL_DIR"
  rm -f "$FIX_DIR/invoked-ok"
  write_fake_rtk "0.43.0" "1"
}

echo "[test-upgrade-rtk] --dry-run changes nothing"
reset_fixture
before="$(cat "$RTK_FIXTURE")"
out=$(env PATH="$BIN_DIR:$PATH" RTK_UPGRADE_PLATFORM=linux RTK_INSTALL_DIR="$INSTALL_DIR" \
      RTK_LATEST_TAG=v0.44.0 bash "$UPGRADE" --dry-run 2>&1); rc=$?
assert_rc "dry-run exits 0" 0 "$rc"
assert_contains "dry-run reports current version" "0.43.0" "$out"
assert_contains "dry-run reports target version" "0.44.0" "$out"
after="$(cat "$RTK_FIXTURE")"
if [ "$before" = "$after" ]; then pass "dry-run left the fixture byte-identical"; else fail "dry-run modified the fixture"; fi
if [ -e "$INSTALL_DIR/rtk.pre-upgrade.bak" ]; then fail "dry-run created a backup file"; else pass "dry-run created no backup file"; fi

echo "[test-upgrade-rtk] unknown flag is a usage error (rc=2), nothing touched"
reset_fixture
before="$(cat "$RTK_FIXTURE")"
out=$(env PATH="$BIN_DIR:$PATH" RTK_UPGRADE_PLATFORM=linux bash "$UPGRADE" --bogus 2>&1); rc=$?
assert_rc "unknown flag -> rc 2" 2 "$rc"
after="$(cat "$RTK_FIXTURE")"
if [ "$before" = "$after" ]; then pass "unknown flag left the fixture untouched"; else fail "unknown flag modified the fixture"; fi

echo "[test-upgrade-rtk] missing rtk -> rc 2 (upgrader, not an installer)"
reset_fixture
out=$(env RTK_UPGRADE_PLATFORM=linux RTK_BIN=rtk-does-not-exist-xyz bash "$UPGRADE" 2>&1); rc=$?
assert_rc "no rtk installed -> rc 2" 2 "$rc"
assert_contains "message names 'not installed'" "is not installed" "$out"
assert_contains "message says upgrader-not-installer" "upgrader, not an installer" "$out"

echo "[test-upgrade-rtk] unsupported platform -> rc 2"
reset_fixture
out=$(env PATH="$BIN_DIR:$PATH" RTK_UPGRADE_PLATFORM=macos bash "$UPGRADE" 2>&1); rc=$?
assert_rc "macos -> rc 2" 2 "$rc"
assert_contains "macos message says unsupported" "unsupported" "$out"
out=$(env PATH="$BIN_DIR:$PATH" RTK_UPGRADE_PLATFORM=some-other-os bash "$UPGRADE" 2>&1); rc=$?
assert_rc "unrecognized platform -> rc 2" 2 "$rc"

echo "[test-upgrade-rtk] already current -- no download attempted, rc 0"
reset_fixture
out=$(env PATH="$BIN_DIR:$PATH" RTK_UPGRADE_PLATFORM=linux RTK_INSTALL_DIR="$INSTALL_DIR" \
      RTK_LATEST_TAG=v0.43.0 RTK_DOWNLOAD_CMD="bash '$FIX_DIR/install-ok.sh'" \
      bash "$UPGRADE" 2>&1); rc=$?
assert_rc "same version -> rc 0" 0 "$rc"
assert_contains "already-current message" "already current" "$out"
# The marker path must match what install-ok.sh actually writes:
# the fixture used to stamp "$(dirname $0)/../invoked-ok" — one level ABOVE
# $FIX_DIR — while this checked inside it, so the assertion could never fail and
# silently proved nothing. A negative assertion that cannot fail is worse than
# no assertion: it reads as coverage. Guard against the paths drifting apart
# again by proving the marker CAN appear before trusting its absence.
if [ -e "$FIX_DIR/invoked-ok" ]; then
  fail "install step ran despite already being current"
else
  pass "install step never invoked when already current"
fi
# Self-check the assertion above is live: run the same fixture directly and
# confirm it lands the marker where this test looks for it.
bash "$FIX_DIR/install-ok.sh" >/dev/null 2>&1 || true
if [ -e "$FIX_DIR/invoked-ok" ]; then
  pass "invoked-ok marker lands where the assertion looks (assertion is live)"
else
  fail "invoked-ok marker path mismatch — the 'never invoked' assertion is vacuous"
fi
rm -f "$FIX_DIR/invoked-ok"

echo "[test-upgrade-rtk] malformed release tag -> rc 2, no install attempted"
reset_fixture
out=$(env PATH="$BIN_DIR:$PATH" RTK_UPGRADE_PLATFORM=linux RTK_INSTALL_DIR="$INSTALL_DIR" \
      RTK_LATEST_TAG=latest RTK_DOWNLOAD_CMD="bash '$FIX_DIR/install-ok.sh'" \
      bash "$UPGRADE" 2>&1); rc=$?
assert_rc "malformed target tag -> rc 2" 2 "$rc"
assert_contains "malformed target tag is rejected explicitly" "invalid release tag" "$out"
if [ -e "$FIX_DIR/invoked-ok" ]; then
  fail "install step ran for a malformed target tag"
else
  pass "install step never invoked for a malformed target tag"
fi

echo "[test-upgrade-rtk] curl calls to GitHub carry a timeout (CR: an unattended cadence must fail fast, not hang)"
SRC="$(cat "$UPGRADE")"
case "$SRC" in
  *'curl -s --max-time '*'https://api.github.com/repos/rtk-ai/rtk/releases/latest'*) pass "release-tag lookup passes --max-time" ;;
  *) fail "release-tag lookup curl call is missing --max-time" ;;
esac
case "$SRC" in
  *'curl -fL --max-time '*'/releases/download/'*) pass "the .deb download passes --max-time" ;;
  *) fail "the .deb download curl call is missing --max-time" ;;
esac

echo "[test-upgrade-rtk] concurrency lock: a held lock refuses fast (rc=3), touches nothing (CR round 4)"
reset_fixture
LOCK_DIR="$INSTALL_DIR.lock"
mkdir -p "$LOCK_DIR"
printf 'pid=%s\nhost=held-by-this-test\nstarted=%s\n' "$$" "$(date +%s)" > "$LOCK_DIR/owner"
before="$(cat "$RTK_FIXTURE")"
out=$(env PATH="$BIN_DIR:$PATH" RTK_UPGRADE_PLATFORM=linux RTK_INSTALL_DIR="$INSTALL_DIR" \
      RTK_LATEST_TAG=v0.44.0 RTK_DOWNLOAD_CMD="bash '$FIX_DIR/install-ok.sh'" \
      bash "$UPGRADE" 2>&1); rc=$?
assert_rc "lock held -> rc 3" 3 "$rc"
assert_contains "lock-held message names the lock path" "$LOCK_DIR" "$out"
after="$(cat "$RTK_FIXTURE")"
if [ "$before" = "$after" ]; then pass "held lock left the live binary untouched"; else fail "held lock did NOT prevent the live binary from being overwritten"; fi
if [ -e "$INSTALL_DIR/rtk.pre-upgrade.bak" ]; then fail "held lock did NOT prevent a backup from being written"; else pass "held lock left no backup file"; fi
if [ -e "$FIX_DIR/invoked-ok" ]; then fail "held lock did NOT prevent the install step from running"; else pass "held lock never invoked the install step"; fi
rm -rf "$LOCK_DIR"

echo "[test-upgrade-rtk] is_newer ignores a suffix (CR: was sort -V, diverged from the .ps1 twin)"
reset_fixture
write_fake_rtk "0.44.0" "1"
out=$(env PATH="$BIN_DIR:$PATH" RTK_UPGRADE_PLATFORM=linux RTK_INSTALL_DIR="$INSTALL_DIR" \
      RTK_LATEST_TAG=v0.44.0-rc1 RTK_DOWNLOAD_CMD="bash '$FIX_DIR/install-ok.sh'" \
      bash "$UPGRADE" 2>&1); rc=$?
assert_rc "suffixed target vs same plain installed version -> rc 0 (no upgrade)" 0 "$rc"
assert_contains "treats 0.44.0-rc1 and 0.44.0 as the same leading version" "already current" "$out"
if [ -e "$FIX_DIR/invoked-ok" ]; then
  fail "install step ran even though the leading dotted-numeric run was unchanged"
else
  pass "install step never invoked for a suffix-only difference"
fi
rm -f "$FIX_DIR/invoked-ok"

echo "[test-upgrade-rtk] simulated failed smoke test -> rc 4, backup restored byte-identical"
reset_fixture
original="$(cat "$RTK_FIXTURE")"
out=$(env PATH="$BIN_DIR:$PATH" RTK_UPGRADE_PLATFORM=linux RTK_INSTALL_DIR="$INSTALL_DIR" \
      RTK_LATEST_TAG=v0.44.0 RTK_DOWNLOAD_CMD="bash '$FIX_DIR/install-smoke-fail-ls.sh'" \
      bash "$UPGRADE" 2>&1); rc=$?
assert_rc "failed functional probe -> rc 4" 4 "$rc"
assert_contains "output announces rollback" "ROLLED BACK" "$out"
restored="$(cat "$RTK_FIXTURE")"
if [ "$restored" = "$original" ]; then
  pass "fixture restored byte-identical to the pre-upgrade original"
else
  fail "fixture NOT byte-identical after rollback"
fi
if [ -e "$INSTALL_DIR/rtk.pre-upgrade.bak" ]; then
  pass "backup file left in the install scratch dir"
else
  fail "no backup file found in the install scratch dir"
fi
post_version=$("$RTK_FIXTURE" --version 2>&1)
assert_contains "restored fixture reports the original version again" "0.43.0" "$post_version"
if [ -e "$INSTALL_DIR.lock" ]; then
  fail "lock left behind after a failed (rolled-back) run"
else
  pass "lock released after a failed (rolled-back) run"
fi

echo "[test-upgrade-rtk] install step itself failing -> rc 4, fixture untouched (never replaced)"
reset_fixture
original="$(cat "$RTK_FIXTURE")"
out=$(env PATH="$BIN_DIR:$PATH" RTK_UPGRADE_PLATFORM=linux RTK_INSTALL_DIR="$INSTALL_DIR" \
      RTK_LATEST_TAG=v0.44.0 RTK_DOWNLOAD_CMD="bash '$FIX_DIR/install-cmd-fail.sh'" \
      bash "$UPGRADE" 2>&1); rc=$?
assert_rc "install command failure -> rc 4" 4 "$rc"
restored="$(cat "$RTK_FIXTURE")"
if [ "$restored" = "$original" ]; then
  pass "fixture unchanged when the install step itself failed"
else
  fail "fixture was modified despite the install step failing"
fi

echo "[test-upgrade-rtk] happy path -- rc 0, version bumped, backup left behind"
reset_fixture
out=$(env PATH="$BIN_DIR:$PATH" RTK_UPGRADE_PLATFORM=linux RTK_INSTALL_DIR="$INSTALL_DIR" \
      RTK_LATEST_TAG=v0.44.0 RTK_DOWNLOAD_CMD="bash '$FIX_DIR/install-ok.sh'" \
      bash "$UPGRADE" 2>&1); rc=$?
assert_rc "happy path -> rc 0" 0 "$rc"
assert_contains "success line reports the version bump" "0.43.0 -> 0.44.0" "$out"
new_version=$("$RTK_FIXTURE" --version 2>&1)
assert_contains "fixture now reports the new version" "0.44.0" "$new_version"

echo "[test-upgrade-rtk] HIMMEL-3049: dpkg-owned RTK_BIN_PATH still takes the deb+apt flow, unchanged"
reset_fixture
TARBALL_DIR="$TMP_ROOT/tarball-assets"
rm -rf "$TARBALL_DIR"; mkdir -p "$TARBALL_DIR"
cat > "$BIN_DIR/curl" <<'EOF'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
echo "fake deb payload" > "$out"
EOF
chmod +x "$BIN_DIR/curl"
cat > "$BIN_DIR/sudo" <<'EOF'
#!/usr/bin/env bash
touch "$(dirname "$0")/../sudo-invoked"
[ "$1" = "-n" ] && shift
[ "$1" = "apt" ] || exit 1
cat > "$RTK_APT_TARGET" <<'INNER'
#!/usr/bin/env bash
case "$1" in
  --version) echo "rtk 0.44.0"; exit 0 ;;
  ls) command ls "$2" >/dev/null 2>&1; exit 0 ;;
  *) exit 1 ;;
esac
INNER
chmod +x "$RTK_APT_TARGET"
EOF
chmod +x "$BIN_DIR/sudo"
rm -f "$TMP_ROOT/sudo-invoked"
out=$(env PATH="$BIN_DIR:$PATH" RTK_UPGRADE_PLATFORM=linux RTK_BIN_OWNER=dpkg RTK_APT_TARGET="$RTK_FIXTURE" \
      RTK_INSTALL_DIR="$INSTALL_DIR" RTK_LATEST_TAG=v0.44.0 \
      bash "$UPGRADE" 2>&1); rc=$?
assert_rc "dpkg-owned binary -> rc 0" 0 "$rc"
if [ -e "$INSTALL_DIR/rtk_amd64.deb" ]; then
  pass "dpkg branch downloaded rtk_amd64.deb (deb+apt flow taken)"
else
  fail "dpkg branch did not download rtk_amd64.deb -- deb+apt flow was NOT taken" "$out"
fi
if [ -e "$TMP_ROOT/sudo-invoked" ]; then
  pass "dpkg branch invoked sudo apt (unchanged behavior)"
else
  fail "dpkg branch never invoked sudo -- deb+apt flow was NOT taken" "$out"
fi
rm -f "$BIN_DIR/sudo" "$BIN_DIR/curl" "$TMP_ROOT/sudo-invoked"

echo "[test-upgrade-rtk] HIMMEL-3049: non-dpkg tarball happy path -- replaced, version bumped, no sudo"
reset_fixture
rm -rf "$TARBALL_DIR"; mkdir -p "$TARBALL_DIR"
TARBALL_STAGE="$TMP_ROOT/tarball-stage"
rm -rf "$TARBALL_STAGE"; mkdir -p "$TARBALL_STAGE"
cat > "$TARBALL_STAGE/rtk" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  --version) echo "rtk 0.44.0"; exit 0 ;;
  ls) command ls "$2" >/dev/null 2>&1; exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TARBALL_STAGE/rtk"
tar czf "$TARBALL_DIR/rtk-x86_64-unknown-linux-musl.tar.gz" -C "$TARBALL_STAGE" rtk
GOOD_SUM=$(sha256sum "$TARBALL_DIR/rtk-x86_64-unknown-linux-musl.tar.gz" | awk '{print $1}')
printf '%s  rtk-x86_64-unknown-linux-musl.tar.gz\n' "$GOOD_SUM" > "$TARBALL_DIR/checksums.txt"
cat > "$BIN_DIR/curl" <<EOF
#!/usr/bin/env bash
url=""; out=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    -f|-L|-s) shift ;;
    --max-time) shift 2 ;;
    http*) url="\$1"; shift ;;
    *) shift ;;
  esac
done
name="\${url##*/}"
src="$TARBALL_DIR/\$name"
if [ -f "\$src" ]; then cp "\$src" "\$out"; exit 0; fi
exit 22
EOF
chmod +x "$BIN_DIR/curl"
cat > "$BIN_DIR/sudo" <<'EOF'
#!/usr/bin/env bash
touch "$(dirname "$0")/../sudo-invoked"
exit 1
EOF
chmod +x "$BIN_DIR/sudo"
rm -f "$TMP_ROOT/sudo-invoked"
out=$(env PATH="$BIN_DIR:$PATH" RTK_UPGRADE_PLATFORM=linux RTK_BIN_OWNER=other RTK_UPGRADE_ARCH=x86_64 \
      RTK_INSTALL_DIR="$INSTALL_DIR" RTK_LATEST_TAG=v0.44.0 \
      bash "$UPGRADE" 2>&1); rc=$?
assert_rc "tarball happy path -> rc 0" 0 "$rc"
assert_contains "success line reports the version bump" "0.43.0 -> 0.44.0" "$out"
new_version=$("$RTK_FIXTURE" --version 2>&1)
assert_contains "fixture now reports the new version" "0.44.0" "$new_version"
if [ -e "$TMP_ROOT/sudo-invoked" ]; then
  fail "tarball branch invoked sudo -- must never sudo on an already-user-writable path"
else
  pass "tarball branch never invoked sudo"
fi
if ls "$BIN_DIR"/.rtk.upgrade.* >/dev/null 2>&1; then
  fail "tarball branch left a stray .rtk.upgrade.* staging file behind"
else
  pass "tarball branch left no stray staging file behind"
fi
rm -f "$BIN_DIR/curl" "$BIN_DIR/sudo" "$TMP_ROOT/sudo-invoked"

echo "[test-upgrade-rtk] HIMMEL-3049 RED->GREEN: checksum mismatch fails closed -- binary byte-identical, rc!=0, no partial write"
reset_fixture
rm -rf "$TARBALL_DIR"; mkdir -p "$TARBALL_DIR"
rm -rf "$TARBALL_STAGE"; mkdir -p "$TARBALL_STAGE"
cat > "$TARBALL_STAGE/rtk" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  --version) echo "rtk 0.44.0"; exit 0 ;;
  ls) command ls "$2" >/dev/null 2>&1; exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TARBALL_STAGE/rtk"
tar czf "$TARBALL_DIR/rtk-x86_64-unknown-linux-musl.tar.gz" -C "$TARBALL_STAGE" rtk
# Deliberately WRONG checksum -- simulates a tampered/attacker-controlled
# checksums.txt, or a corrupted download. This is the exact scenario the
# RED-first demo (paste in the PR/handover) proved the pre-fix script accepts
# unconditionally: a corrupted "new" binary that merely passes --version + ls.
printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef  rtk-x86_64-unknown-linux-musl.tar.gz\n' > "$TARBALL_DIR/checksums.txt"
cat > "$BIN_DIR/curl" <<EOF
#!/usr/bin/env bash
url=""; out=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    -f|-L|-s) shift ;;
    --max-time) shift 2 ;;
    http*) url="\$1"; shift ;;
    *) shift ;;
  esac
done
name="\${url##*/}"
src="$TARBALL_DIR/\$name"
if [ -f "\$src" ]; then cp "\$src" "\$out"; exit 0; fi
exit 22
EOF
chmod +x "$BIN_DIR/curl"
# Precondition check (avoid a vacuous control): confirm sha256sum is on PATH
# and the fixture curl actually serves the tarball+checksums, so a failure
# below is caused by the mismatch check, not a missing stub.
if ! command -v sha256sum >/dev/null 2>&1; then
  fail "checksum-mismatch precondition: sha256sum not on PATH -- this control cannot run"
elif [ ! -s "$TARBALL_DIR/rtk-x86_64-unknown-linux-musl.tar.gz" ] || [ ! -s "$TARBALL_DIR/checksums.txt" ]; then
  fail "checksum-mismatch precondition: fixture tarball/checksums.txt missing -- this control cannot run"
else
  pass "checksum-mismatch precondition: sha256sum available and fixture assets present"
fi
original="$(cat "$RTK_FIXTURE")"
out=$(env PATH="$BIN_DIR:$PATH" RTK_UPGRADE_PLATFORM=linux RTK_BIN_OWNER=other RTK_UPGRADE_ARCH=x86_64 \
      RTK_INSTALL_DIR="$INSTALL_DIR" RTK_LATEST_TAG=v0.44.0 \
      bash "$UPGRADE" 2>&1); rc=$?
if [ "$rc" != "0" ]; then pass "checksum mismatch -> non-zero exit (rc=$rc)"; else fail "checksum mismatch -> rc 0, should have refused"; fi
assert_contains "output names the checksum mismatch" "checksum mismatch" "$out"
restored="$(cat "$RTK_FIXTURE")"
if [ "$restored" = "$original" ]; then
  pass "binary is byte-identical to the pre-upgrade original after a checksum mismatch"
else
  fail "binary bytes CHANGED despite a checksum mismatch -- fail-closed guarantee broken"
fi
post_version=$("$RTK_FIXTURE" --version 2>&1)
assert_contains "fixture still reports the original version (never replaced)" "0.43.0" "$post_version"
if ls "$BIN_DIR"/.rtk.upgrade.* >/dev/null 2>&1; then
  fail "checksum mismatch left a partial-write staging file (.rtk.upgrade.*) behind"
else
  pass "checksum mismatch left no partial-write staging file behind"
fi
rm -f "$BIN_DIR/curl"

echo ""
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
