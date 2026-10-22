#!/usr/bin/env bash
# test-ubuntu-shim.sh — ubuntu.sh is soft-deprecated: it KEEPS
# its full-toolchain provisioning (locked O4 option (b) — zero capability
# loss) but stops doing himmel/luna WIRING itself and delegates that to
# `himmelctl bootstrap` (the correct entry for a node-less machine; `install`
# directly would fail pre-node).
#
# Covers:
#   A. capability-regression guard — every tool the OLD script's fatal
#      provisioning block installed is still installed by the shim. Parses
#      the provisioning block and compares against a committed expected list
#      ("banners gone" alone is NOT sufficient).
#   B. order assertion — runs the REAL ubuntu.sh (stubbed sudo/apt/curl/git/
#      node/nvm/uv/claude/rtk on PATH, HOME redirected to a temp dir) and
#      asserts provisioning happens BEFORE the deprecation notice, which
#      happens BEFORE the delegated bootstrap invocation — AND that
#      the bootstrap runs with cwd=$HIMMEL_PATH (the wizard's role/scope
#      inference reads the CWD, so delegating from the operator's launch
#      directory would target the wrong repo).
#   C. Fail-closed --luna-remote guard — the delegated flow can't
#      restore a remote vault yet, so passing the flag must
#      error out BEFORE any provisioning (no apt call, no bootstrap
#      invocation) instead of silently completing a rebuild without the
#      operator's vault.

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
target="$repo_root/scripts/machine-setup/ubuntu.sh"
[ -f "$target" ] || { echo "FAIL: $target not found" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

work=$(mktemp -d)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# ── Case A: capability-regression guard ─────────────────────────────────────
# The committed expected tool list — every tool the old
# ubuntu.sh's fatal provisioning block (steps 1-6) installed, before wiring
# was dropped. If this list shrinks, provisioning capability regressed.
expected_apt_tools="curl git gitleaks jq python3 python3-pip shellcheck xz-utils"

apt_line=$(grep -oE 'sudo apt install -y [a-z0-9. -]+' "$target" | head -1)
[ -n "$apt_line" ] || fail "caseA: could not find the core-tools 'sudo apt install -y ...' line"
actual_apt_tools=$(echo "$apt_line" | sed 's/^sudo apt install -y //' | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')
expected_sorted=$(echo "$expected_apt_tools" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')
[ "$actual_apt_tools" = "$expected_sorted" ] \
  || fail "caseA: core-tools apt-install list regressed -- expected [$expected_sorted], got [$actual_apt_tools]"

grep -q 'NVM_DIR' "$target" || fail "caseA: nvm provisioning missing"
grep -q 'nvm install' "$target" || fail "caseA: nvm install call missing"
grep -q 'astral-sh/uv/releases/download' "$target" || fail "caseA: uv provisioning missing"
grep -q 'oven-sh/bun/releases/download' "$target" || fail "caseA: bun provisioning missing (HIMMEL-3068)"
grep -q 'claude-code-releases' "$target" || fail "caseA: claude CLI provisioning missing"
grep -q 'rtk-ai/rtk/releases/download' "$target" || fail "caseA: rtk provisioning missing"
echo "ok: caseA every tool the old ubuntu.sh provisioned (${expected_sorted}, nvm, uv, bun, claude, rtk) is still provisioned"

# ── Case B: order assertion (provisioning < notice < delegated bootstrap) ──
tmp_home="$work/home"
mkdir -p "$tmp_home"
stub_bin="$work/stub-bin"
mkdir -p "$stub_bin"

cat > "$stub_bin/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF

cat > "$stub_bin/apt" <<'EOF'
#!/usr/bin/env bash
echo "PROVISION:apt $*"
exit 0
EOF

# Pinned artifacts: the curl stub serves a fixture per URL and logs it; the
# sha256sum stub logs the "<sha>  <file>" line ubuntu.sh asks it to verify and
# fails when STUB_SHA_RC says so (the real bytes-vs-pin check is covered by
# test-installer-pins.sh, which runs the real sha256sum).
# shellcheck source=installer-pins.sh disable=SC2153 # NVM_* come from the pins file
. "$repo_root/scripts/machine-setup/installer-pins.sh"
fix="$work/fix"
mkdir -p "$fix/uv/uv-x86_64-unknown-linux-gnu" "$fix/bun/bun-linux-x64"
for b in uv uvx; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fix/uv/uv-x86_64-unknown-linux-gnu/$b"
  chmod +x "$fix/uv/uv-x86_64-unknown-linux-gnu/$b"
done
tar -czf "$fix/uv.tar.gz" -C "$fix/uv" uv-x86_64-unknown-linux-gnu
mkdir -p "$fix/node/node-v${NODE_VERSION}-linux-x64/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fix/node/node-v${NODE_VERSION}-linux-x64/bin/node"
chmod +x "$fix/node/node-v${NODE_VERSION}-linux-x64/bin/node"
# gz bytes under the .xz name: ubuntu.sh's tar autodetects, and xz may be absent here
tar -czf "$fix/node.tar.xz" -C "$fix/node" "node-v${NODE_VERSION}-linux-x64"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fix/bun/bun-linux-x64/bun"
python3 -c 'import sys, zipfile
z = zipfile.ZipFile(sys.argv[1], "w"); z.write(sys.argv[2], "bun-linux-x64/bun"); z.close()' "$fix/bun.zip" "$fix/bun/bun-linux-x64/bun"
# shellcheck disable=SC2016 # the fixture's own $1/$* expand when it runs
printf '#!/usr/bin/env bash\ncase "$1" in install) echo "CLAUDE-INSTALL $*" ;; esac\nexit 0\n' > "$fix/claude"
export FIX="$fix" CURL_LOG="$work/curl.log" NVM_FLAG="$work/nvm-installed" NVM_PIN_COMMIT="$NVM_COMMIT"
: > "$CURL_LOG"

cat > "$stub_bin/curl" <<'EOF'
#!/usr/bin/env bash
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    --proto|--proto-redir) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
echo "CURL:$url" >> "$CURL_LOG"
case "$url" in
  https://raw.githubusercontent.com/nvm-sh/nvm/*/install.sh)
    printf '#!/usr/bin/env bash\ntouch "%s"\n' "$NVM_FLAG" > "$out" ;;
  https://nodejs.org/dist/*) cp "$FIX/node.tar.xz" "$out" ;;
  https://github.com/astral-sh/uv/releases/download/*) cp "$FIX/uv.tar.gz" "$out" ;;
  https://github.com/oven-sh/bun/releases/download/*) cp "$FIX/bun.zip" "$out" ;;
  https://downloads.claude.ai/claude-code-releases/*) cp "$FIX/claude" "$out" ;;
  https://github.com/rtk-ai/rtk/releases/download/*) echo deb > "$out" ;;
  *) echo "UNEXPECTED-URL $url" >&2; exit 22 ;;
esac
EOF

cat > "$stub_bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
sed 's/^/SHA256CHECK:/' >> "$CURL_LOG"
[ "${STUB_SHA_RC:-0}" = 0 ]
EOF

cat > "$stub_bin/uname" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "-m" ]; then echo x86_64; exit 0; fi
exec /usr/bin/uname "$@"
EOF

cat > "$stub_bin/git" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "-C" ] && [ "$3" = "rev-parse" ]; then
  if [ -e "$NVM_FLAG" ]; then echo "$NVM_PIN_COMMIT"; else echo "${STUB_NVM_HEAD:-$NVM_PIN_COMMIT}"; fi
  exit 0
fi
echo "GIT:$*"
if [ "$1" = "clone" ]; then
  target="$*"
  target="${target##* }"
  mkdir -p "$target/.git" "$target/scripts/hooks" "$target/scripts/himmelctl" "$target/scripts/lib"
  cat > "$target/scripts/hooks/check-hookspath.sh" <<'INNER'
#!/usr/bin/env bash
echo "STUB:check-hookspath"
exit 0
INNER
  cat > "$target/scripts/lib/reconcile-rtk-hook.sh" <<'INNER'
#!/usr/bin/env bash
echo "STUB:reconcile-rtk-hook $*"
exit 0
INNER
  cat > "$target/scripts/himmelctl/bootstrap.sh" <<'INNER'
#!/usr/bin/env bash
echo "BOOTSTRAP:invoked $*"
echo "BOOTSTRAP:pwd $PWD"
exit 0
INNER
  chmod +x "$target/scripts/hooks/check-hookspath.sh" "$target/scripts/lib/reconcile-rtk-hook.sh" "$target/scripts/himmelctl/bootstrap.sh"
fi
exit 0
EOF

node_stub_version="24.0.0"
cat > "$stub_bin/node" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "--version" ]; then echo "v${node_stub_version}"; exit 0; fi
exit 0
EOF

cat > "$stub_bin/uv" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then echo "uv-stub 1.0.0"; exit 0; fi
exit 0
EOF

# Bun's real install line pipes the stubbed curl (empty stdout,
# see stub_bin/curl's default `exit 0` arm) into bash — a no-op — so `bun`
# itself must be stubbed here the same way uv/claude/rtk already are, or the
# unguarded `bun --version` assertion right after it hard-exits the whole
# script under ubuntu.sh's `set -euo pipefail`.
cat > "$stub_bin/bun" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then echo "bun-stub 1.0.0"; exit 0; fi
exit 0
EOF

cat > "$stub_bin/claude" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then echo "claude-stub 1.0.0"; exit 0; fi
exit 0
EOF

cat > "$stub_bin/rtk" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  --version) echo "rtk-stub 1.0.0"; exit 0 ;;
  init) echo "STUB:rtk-init $*"; exit 0 ;;
  *) exit 0 ;;
esac
EOF

chmod +x "$stub_bin"/sudo "$stub_bin"/apt "$stub_bin"/curl "$stub_bin"/git \
  "$stub_bin"/sha256sum "$stub_bin"/uname "$stub_bin"/node "$stub_bin"/uv "$stub_bin"/bun "$stub_bin"/claude "$stub_bin"/rtk

# Pre-create $NVM_DIR/nvm.sh as a shell-function stub (nvm is sourced, not
# exec'd, so it can't be a PATH stub). The git stub reports the pinned nvm
# commit as its HEAD, so ubuntu.sh skips the nvm installer here (the
# fresh-install path is Case F).
mkdir -p "$tmp_home/.nvm"
cat > "$tmp_home/.nvm/nvm.sh" <<'EOF'
nvm() { case "$1" in which) echo "$HOME/.nvm/versions/node/v$2/bin/node" ;; *) echo "STUB:nvm $*" ;; esac; return 0; }
EOF

log="$work/run.log"
set +e
HOME="$tmp_home" PATH="$stub_bin:$PATH" bash "$target" >"$log" 2>&1
run_rc=$?
set -e
# The delegated bootstrap stub exits 0, so ubuntu.sh (via exec) should too.
[ "$run_rc" -eq 0 ] || { cat "$log" >&2; fail "caseB: ubuntu.sh exited $run_rc against the fully-stubbed environment (log above)"; }

provision_line=$(grep -n '^PROVISION:apt' "$log" | head -1 | cut -d: -f1)
notice_line=$(grep -n 'soft-deprecated' "$log" | head -1 | cut -d: -f1)
bootstrap_line=$(grep -n '^BOOTSTRAP:invoked' "$log" | head -1 | cut -d: -f1)

[ -n "$provision_line" ] || { cat "$log" >&2; fail "caseB: no PROVISION marker found (log above)"; }
[ -n "$notice_line" ] || { cat "$log" >&2; fail "caseB: no deprecation-notice marker found (log above)"; }
[ -n "$bootstrap_line" ] || { cat "$log" >&2; fail "caseB: no BOOTSTRAP marker found (log above)"; }

[ "$provision_line" -lt "$notice_line" ] \
  || fail "caseB: provisioning (line $provision_line) did not happen before the deprecation notice (line $notice_line)"
[ "$notice_line" -lt "$bootstrap_line" ] \
  || fail "caseB: deprecation notice (line $notice_line) did not happen before the delegated bootstrap invocation (line $bootstrap_line)"

# The delegation must run FROM the himmel clone (the wizard's
# role/scope inference reads the CWD's git origin; scope=project wires
# .claude into the CWD), never from the operator's launch directory. The
# bootstrap stub records its $PWD; it must be exactly $HIMMEL_PATH
# ($HOME/github/himmel under the redirected temp HOME).
expected_pwd="$tmp_home/github/himmel"
bootstrap_pwd=$(grep '^BOOTSTRAP:pwd ' "$log" | head -1 | sed 's/^BOOTSTRAP:pwd //')
[ -n "$bootstrap_pwd" ] || { cat "$log" >&2; fail "caseB: no BOOTSTRAP:pwd marker found (log above)"; }
[ "$bootstrap_pwd" = "$expected_pwd" ] \
  || fail "caseB: bootstrap must be invoked with cwd=\$HIMMEL_PATH ($expected_pwd), got: $bootstrap_pwd"
bootstrap_args=$(grep '^BOOTSTRAP:invoked ' "$log" | head -1 | sed 's/^BOOTSTRAP:invoked //')
[ "$bootstrap_args" = "--default-scope user" ] \
  || fail "caseB: machine-restore delegation must hint user scope, got: $bootstrap_args"
echo "ok: caseB provisioning ($provision_line) < notice ($notice_line) < delegated bootstrap ($bootstrap_line), cwd=\$HIMMEL_PATH, default scope=user"

# The shim must reconcile the rtk hook (bare `rtk hook claude`
# from `rtk init -g --auto-patch` → the rtk-hook-guard wrapper) AFTER the
# clone (the helper lives in the repo) and BEFORE the delegated bootstrap,
# passing the user settings.json and the himmel path. The old
# monolith did this swap inline; the shim owns it again.
reconcile_line=$(grep -n '^STUB:reconcile-rtk-hook' "$log" | head -1 | cut -d: -f1)
[ -n "$reconcile_line" ] || { cat "$log" >&2; fail "caseB: no reconcile-rtk-hook invocation found (log above)"; }
[ "$bootstrap_line" -gt "$reconcile_line" ] \
  || fail "caseB: reconcile-rtk-hook (line $reconcile_line) must run before the delegated bootstrap (line $bootstrap_line)"
# rtk init must be wired AFTER clone validation (adjacent to the reconcile) —
# wiring before the clone could strand a raw unguarded hook on clone failure.
rtk_init_line=$(grep -n -Fx 'STUB:rtk-init init -g --auto-patch' "$log" | head -1 | cut -d: -f1)
hookspath_line=$(grep -n '^STUB:check-hookspath' "$log" | head -1 | cut -d: -f1)
[ -n "$rtk_init_line" ] || { cat "$log" >&2; fail "caseB: no rtk init -g --auto-patch invocation found (log above)"; }
[ -n "$hookspath_line" ] || { cat "$log" >&2; fail "caseB: no check-hookspath invocation found (log above)"; }
[ "$rtk_init_line" -gt "$hookspath_line" ] \
  || fail "caseB: rtk init (line $rtk_init_line) must run after clone validation (check-hookspath, line $hookspath_line)"
[ "$reconcile_line" -gt "$rtk_init_line" ] \
  || fail "caseB: reconcile (line $reconcile_line) must run after rtk init (line $rtk_init_line)"
reconcile_args=$(grep '^STUB:reconcile-rtk-hook ' "$log" | head -1 | sed 's/^STUB:reconcile-rtk-hook //')
[ "$reconcile_args" = "$tmp_home/.claude/settings.json $expected_pwd" ] \
  || fail "caseB: reconcile-rtk-hook args must be '<settings.json> <himmel-path>', got: $reconcile_args"
echo "ok: caseB reconcile-rtk-hook ($reconcile_line) < bootstrap ($bootstrap_line), args OK"

# ── Case D: re-run reuses the existing clone and fetches it ─────────────────
logD="$work/run-rerun.log"
set +e
HOME="$tmp_home" PATH="$stub_bin:$PATH" bash "$target" >"$logD" 2>&1
run_rcD=$?
set -e
[ "$run_rcD" -eq 0 ] || { cat "$logD" >&2; fail "caseD: re-run should succeed against the existing clone (rc=$run_rcD)"; }
grep -q "^GIT:-C $expected_pwd fetch --all --prune$" "$logD" \
  || { cat "$logD" >&2; fail "caseD: re-run must fetch/reuse the existing clone"; }
grep -q '^GIT:clone ' "$logD" \
  && fail "caseD: re-run must not clone over the existing checkout"
echo "ok: caseD existing clone -> fetch --all --prune + reuse, no second clone"

# ── Case F: every pinned artifact is fetched at its exact version and checked ─
bun_pin=$(bun_sha256 "$(tr -d '[:space:]' < "$repo_root/.bun-version")")
for want in \
  "CURL:https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
  "SHA256CHECK:${NODE_TARBALL_SHA256}  " \
  "CURL:https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-gnu.tar.gz" \
  "CURL:https://github.com/oven-sh/bun/releases/download/bun-v$(tr -d '[:space:]' < "$repo_root/.bun-version")/bun-linux-x64.zip" \
  "CURL:https://downloads.claude.ai/claude-code-releases/${CLAUDE_VERSION}/linux-x64/claude" \
  "CURL:https://github.com/rtk-ai/rtk/releases/download/v${RTK_VERSION}/rtk_${RTK_VERSION}-1_amd64.deb" \
  "SHA256CHECK:${UV_SHA256}  " \
  "SHA256CHECK:${bun_pin}  " \
  "SHA256CHECK:${CLAUDE_LINUX_X64_SHA256}  " \
  "SHA256CHECK:${RTK_DEB_SHA256}  " \
  "SHA256CHECK:${NODE_BIN_SHA256}  "; do
  grep -qF -- "$want" "$CURL_LOG" || { cat "$CURL_LOG" >&2; fail "caseF: pinned fetch/check missing: $want"; }
done
grep -q "^CLAUDE-INSTALL install ${CLAUDE_VERSION}\$" "$log" \
  ||{ cat "$log" >&2; fail "caseF: claude must be installed at the pinned version ${CLAUDE_VERSION}"; }
echo "ok: caseF uv, bun, claude, rtk fetched at pinned versions; every sha256 pin (and node's) was checked"

# ── Case G: a sha256 mismatch aborts before the delegated bootstrap ─────────
logG="$work/run-badsha.log"
set +e
STUB_SHA_RC=1 HOME="$tmp_home" PATH="$stub_bin:$PATH" bash "$target" >"$logG" 2>&1
run_rcG=$?
set -e
[ "$run_rcG" -ne 0 ] || { cat "$logG" >&2; fail "caseG: a failing sha256 check must abort ubuntu.sh (rc=0)"; }
grep -q '^BOOTSTRAP:invoked' "$logG" && fail "caseG: bootstrap ran after a sha256 failure"
echo "ok: caseG sha256 failure aborts before the delegated bootstrap (rc=$run_rcG)"

# ── Case H: nvm not at the pinned commit -> the sha-pinned install.sh runs ──
rm -f "$NVM_FLAG"; : > "$CURL_LOG"
logH="$work/run-nvm.log"
set +e
STUB_NVM_HEAD="0000000000000000000000000000000000000000" HOME="$tmp_home" PATH="$stub_bin:$PATH" bash "$target" >"$logH" 2>&1
run_rcH=$?
set -e
[ "$run_rcH" -eq 0 ] || { cat "$logH" >&2; fail "caseH: fresh-nvm run failed (rc=$run_rcH)"; }
# shellcheck disable=SC2153 # NVM_TAG comes from installer-pins.sh
grep -qF "CURL:https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_TAG}/install.sh" "$CURL_LOG" \
  || { cat "$CURL_LOG" >&2; fail "caseH: nvm install.sh was not fetched at ${NVM_TAG}"; }
grep -qF "SHA256CHECK:${NVM_INSTALL_SHA256}  " "$CURL_LOG" || fail "caseH: nvm install.sh sha256 was not checked"
[ -e "$NVM_FLAG" ] || fail "caseH: the verified nvm install.sh was not executed"
echo "ok: caseH nvm install.sh fetched at ${NVM_TAG}, sha256 checked, then run"

# ── Case C: --luna-remote -> fail-closed BEFORE any provisioning ───────────
# Reuses the Case B stub environment (same stub PATH + temp HOME) so a
# regression that lets the run continue would be caught by the provisioning/
# bootstrap markers, not by a missing-tool crash.
logC="$work/run-luna-remote.log"
set +e
HOME="$tmp_home" PATH="$stub_bin:$PATH" \
  bash "$target" --luna-remote "git@example.invalid:op/luna.git" >"$logC" 2>&1
run_rcC=$?
set -e
[ "$run_rcC" -ne 0 ] || { cat "$logC" >&2; fail "caseC: --luna-remote must exit nonzero (fail-closed), got rc=0 (log above)"; }
grep -q 'not supported' "$logC" \
  || { cat "$logC" >&2; fail "caseC: expected the not-supported error message (log above)"; }
grep -q 'Clone the vault manually first' "$logC" \
  || { cat "$logC" >&2; fail "caseC: expected the manual-clone remediation line (log above)"; }
grep -q '^PROVISION:apt' "$logC" \
  && fail "caseC: --luna-remote must fail BEFORE any provisioning (apt ran: $(cat "$logC"))"
grep -q '^BOOTSTRAP:invoked' "$logC" \
  && fail "caseC: --luna-remote must never reach the delegated bootstrap (got: $(cat "$logC"))"
echo "ok: caseC --luna-remote -> fail-closed error before any provisioning, bootstrap never invoked"

# ── Case E: trailing --luna-remote with no value must reach the
#    script's own usage diagnostic and exit 2, never an unbound-variable death
#    from `set -u`. ────────────────────────────────────────────────────────
set +e
out=$(bash "$target" --luna-remote 2>&1); rcE=$?
set -e
[ "$rcE" -eq 2 ] || fail "caseE: trailing --luna-remote should exit 2, got $rcE (out: $out)"
grep -q -- "--luna-remote requires a value" <<< "$out" \
  || fail "caseE: trailing --luna-remote missing usage diagnostic (out: $out)"
grep -q "unbound variable" <<< "$out" \
  && fail "caseE: trailing --luna-remote leaked an unbound-variable death (out: $out)"
echo "ok: caseE trailing --luna-remote exits 2 with its own diagnostic"

echo "PASS"
