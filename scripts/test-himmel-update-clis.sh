#!/usr/bin/env bash
# test-himmel-update-clis.sh — himmel-update.sh reports and upgrades the agent
# CLIs and says so in the chain-status table (HIMMEL-5383):
#   --only clis       codex (upgraded through its install method) + claude (report only)
#   --only toolchain  a failing `bun upgrade` names its owner and the exact remedy
#   --only plugins    a missing @himmel plugin gets a table row + its install line
#
# Every binary is a STUB on a private PATH, and the npm stub is the only thing
# that "installs": no real upgrade, no network. Bash 3.2 compatible.

set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/himmel-update.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-himmel-update-clis.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

export USERPROFILE=''
export HOME="$TMP/home"
export CLAUDE_CONFIG_DIR="$TMP/no-claude-config"
export HERMES_HOME="$TMP/no-hermes"
export HIMMELCTL_CACHE_DIR="$TMP/himmelctl-cache"
mkdir -p "$HOME" "$HIMMELCTL_CACHE_DIR" || exit 1
unset HIMMEL_UPDATE_CHANNEL CODEX_BIN HIMMEL_UPDATE_VM_ACK

pass=0
fail=0
assert_pass() { pass=$((pass + 1)); echo "  PASS: $1"; }
assert_fail() { fail=$((fail + 1)); echo "  FAIL: $1"; }

CLONE="$TMP/clone"
mkdir -p "$CLONE/scripts/guardrails" "$CLONE/scripts/lib" || exit 1
src_scripts="$(dirname "$SCRIPT")"
if ! { cp "$SCRIPT" "$CLONE/scripts/himmel-update.sh" \
    && cp "$src_scripts/guardrails/lib.sh"        "$CLONE/scripts/guardrails/lib.sh" \
    && cp "$src_scripts/lib/cadence-format.sh"    "$CLONE/scripts/lib/cadence-format.sh" \
    && cp "$src_scripts/lib/resolve-hermes-py.sh" "$CLONE/scripts/lib/resolve-hermes-py.sh" \
    && cp "$src_scripts/lib/load-dotenv.sh"       "$CLONE/scripts/lib/load-dotenv.sh" \
    && cp "$src_scripts/lib/vm-mode.sh"           "$CLONE/scripts/lib/vm-mode.sh" \
    && git init --quiet "$CLONE"; }; then
    echo "FAIL: mock clone setup" >&2
    exit 1
fi
printf '20\n' > "$CLONE/.nvmrc"

# vm.mode=local so the VM-first gate lets a roll through; a separate case holds it.
export HIMMEL_VM_MODE_CONFIG="$TMP/config.json"
printf '{"vm":{"mode":"local"}}\n' > "$HIMMEL_VM_MODE_CONFIG"

STUBS="$TMP/stubs"
NPMROOT="$TMP/npmroot/lib/node_modules/@openai/codex/bin"
mkdir -p "$STUBS" "$NPMROOT" || exit 1
STATE="$TMP/state"
mkdir -p "$STATE" || exit 1

# codex lives under an npm node_modules tree, as on a real npm-global install.
cat > "$NPMROOT/codex.js" <<'EOF'
#!/bin/sh
printf 'codex-cli %s\n' "$(cat "$STUB_STATE/codex.ver")"
EOF
ln -s "$NPMROOT/codex.js" "$STUBS/codex"
cat > "$STUBS/claude" <<'EOF'
#!/bin/sh
printf '%s (Claude Code)\n' "$(cat "$STUB_STATE/claude.ver")"
EOF
cat > "$STUBS/npm" <<'EOF'
#!/bin/sh
case "$1 $2" in
    "view @openai/codex")           cat "$STUB_STATE/codex.latest" ;;
    "view @anthropic-ai/claude-code") cat "$STUB_STATE/claude.latest" ;;
    "install -g")
        echo "npm $*" >> "$STUB_STATE/npm.log"
        [ -f "$STUB_STATE/npm.fail" ] && { echo "npm ERR! EACCES" >&2; exit 243; }
        [ "$3" = "@openai/codex@latest" ] && cp "$STUB_STATE/codex.latest" "$STUB_STATE/codex.ver" ;;
    *) echo 1.0.0 ;;
esac
EOF
cat > "$STUBS/bun" <<'EOF'
#!/bin/sh
case "$1" in
    upgrade) echo "error: EACCES: permission denied, rename '/usr/bin/bun'" >&2; exit 1 ;;
    *) echo 1.2.3 ;;
esac
EOF
printf '#!/bin/sh\nprintf "v20.1.0\\n"\n' > "$STUBS/node"
chmod +x "$STUBS/claude" "$STUBS/npm" "$STUBS/bun" "$STUBS/node" "$NPMROOT/codex.js"
export STUB_STATE="$STATE"

# run_only <item> — output of `himmel-update.sh --only <item>`, rc in $RC
RC=0
run_only() {
    RC=0
    OUT="$(cd "$CLONE" && PATH="$STUBS:/usr/bin:/bin" bash scripts/himmel-update.sh --only "$1" 2>&1)" || RC=$?
}
has() { grep -qE -- "$1" <<< "$OUT"; }

reset_state() {
    printf '0.100.0\n' > "$STATE/codex.ver"
    printf '0.200.0\n' > "$STATE/codex.latest"
    printf '2.1.100\n' > "$STATE/claude.ver"
    printf '2.1.200\n' > "$STATE/claude.latest"
    rm -f "$STATE/npm.log" "$STATE/npm.fail"
}

echo "codex CLI: upgraded through its install method"
reset_state
run_only clis
if [ "$RC" -eq 0 ] && has '^    codex +updated +0\.100\.0 -> 0\.200\.0' \
    && grep -q 'install -g @openai/codex@latest' "$STATE/npm.log" 2>/dev/null; then
    assert_pass "older codex is upgraded through npm and the table says updated"
else
    assert_fail "older codex → npm upgrade + 'updated' row (rc=$RC): $OUT"
fi

reset_state
printf '0.200.0\n' > "$STATE/codex.ver"
run_only clis
if [ "$RC" -eq 0 ] && has '^    codex +up-to-date' && [ ! -f "$STATE/npm.log" ]; then
    assert_pass "already-current codex reads up-to-date and runs no install"
else
    assert_fail "current codex → up-to-date, no install (rc=$RC): $OUT"
fi

reset_state
touch "$STATE/npm.fail"
run_only clis
if has '^    codex +failed' && has 'npm install -g @openai/codex@latest'; then
    assert_pass "a failing npm install is a failed row naming the manual command"
else
    assert_fail "failed install → failed row + manual command: $OUT"
fi

reset_state
printf '{"vm":{"mode":"none"}}\n' > "$HIMMEL_VM_MODE_CONFIG"
run_only clis
if has 'HELD' && has '^    codex +skipped' && [ ! -f "$STATE/npm.log" ]; then
    assert_pass "vm.mode=none holds the codex upgrade (VM-first gate)"
else
    assert_fail "vm.mode=none → HELD, no install: $OUT"
fi
printf '{"vm":{"mode":"local"}}\n' > "$HIMMEL_VM_MODE_CONFIG"

echo "claude CLI: reported, never updated"
reset_state
run_only clis
if has '^    claude +skipped +2\.1\.100 -> 2\.1\.200' && has 'claude update' \
    && ! grep -q 'claude' "$STATE/npm.log" 2>/dev/null; then
    assert_pass "behind claude prints installed -> latest and the update command"
else
    assert_fail "behind claude → row + 'claude update', no npm install: $OUT"
fi

echo "bun: a failed self-upgrade names the remedy"
reset_state
run_only toolchain
if has 'bun 1\.2\.3 .*self-upgrade failed' && has 'EACCES' && has 'fix: .*bun upgrade' \
    && has '^    bun +failed'; then
    assert_pass "failing bun upgrade prints the captured reason, the remedy and a table row"
else
    assert_fail "bun failure → reason + remedy + row: $OUT"
fi

# bun owned by the system package manager: say who updates it, never the curl installer.
cat > "$STUBS/pacman" <<'EOF'
#!/bin/sh
[ "$1" = "-Qo" ] && { echo "$2 is owned by bun 1.2.3-1"; exit 0; }
exit 1
EOF
chmod +x "$STUBS/pacman"
run_only toolchain
if has 'updated by pacman' && has 'sudo pacman -Syu bun' && ! has 'bun\.sh/install'; then
    assert_pass "pacman-owned bun reports 'updated by pacman' with the exact command"
else
    assert_fail "pacman-owned bun → 'updated by pacman: sudo pacman -Syu bun': $OUT"
fi
rm -f "$STUBS/pacman"

echo "missing @himmel plugins: install line + table row"
cat > "$TMP/market.json" <<'EOF'
{"name":"himmel","plugins":[{"name":"alpha"},{"name":"himmel-bus"}]}
EOF
cat > "$TMP/installed.json" <<'EOF'
{"plugins":{"alpha@himmel":[{"version":"1.0.0"}]}}
EOF
RC=0
OUT="$(cd "$CLONE" && PATH="$STUBS:/usr/bin:/bin" HIMMEL_MARKETPLACE_JSON="$TMP/market.json" \
    HIMMEL_INSTALLED_PLUGINS_JSON="$TMP/installed.json" bash scripts/himmel-update.sh --only plugins 2>&1)" || RC=$?
if has '^    plugins +skipped .*claude plugin install himmel-bus@himmel'; then
    assert_pass "missing plugin gets a table row carrying its exact install command"
else
    assert_fail "missing plugin → table row with install line (rc=$RC): $OUT"
fi
printf '{"plugins":{"alpha@himmel":[{"version":"1.0.0"}],"himmel-bus@himmel":[{"version":"1.0.0"}]}}\n' > "$TMP/installed.json"
OUT="$(cd "$CLONE" && PATH="$STUBS:/usr/bin:/bin" HIMMEL_MARKETPLACE_JSON="$TMP/market.json" \
    HIMMEL_INSTALLED_PLUGINS_JSON="$TMP/installed.json" bash scripts/himmel-update.sh --only plugins 2>&1)" || RC=$?
if has '^    plugins +up-to-date'; then
    assert_pass "all plugins installed reads up-to-date"
else
    assert_fail "all installed → up-to-date row: $OUT"
fi

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
