#!/usr/bin/env bash
# test-himmel-update-plugin-update.sh — hermetic tests for update_installed_plugins
# a plugin update may never leave a floor-`false` plugin
# enabled, so `claude plugin update <spec>` for every installed non-@himmel
# plugin must run, and must run BEFORE the lean-floor reconcile.
#
# Same mock-clone technique as test-himmel-update-chain.sh. The `claude` stub
# logs every invocation (with args) to a file so this can assert both WHICH
# specs were updated and, together with the reconcile section header's
# position in stdout, that the update runs before the reconcile. No real
# npm/bun/claude/network interaction — HIMMEL_UPDATE_CLAUDE_BIN always points
# at a local stub, never the real CLI.
#
# Bash 3.2 compatible.

set -euo pipefail

grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

# backdate <file> <epoch-seconds> - set a file's mtime to an exact epoch time.
# GNU touch takes `-d @<epoch>` directly; BSD/macOS touch has no epoch form,
# so fall back through BSD `date -r <epoch>` into touch's -t timestamp (same
# shape as backdate() in test-context-fill.sh) — a plain `touch -d '30 hours
# ago'` is not portable to macOS.
backdate() {
    local file="$1" epoch="$2" ts
    touch -d "@$epoch" "$file" 2>/dev/null && return 0
    ts="$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null)" && touch -t "$ts" "$file" 2>/dev/null && return 0
    echo "backdate: cannot set mtime on this platform" >&2
    exit 1
}

SCRIPT="$(cd "$(dirname "$0")" && pwd)/himmel-update.sh"

if [ ! -f "$SCRIPT" ]; then
    echo "FAIL: $SCRIPT not found" >&2
    exit 1
fi

TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
assert_pass() { pass=$((pass + 1)); echo "  PASS: $1"; }
assert_fail() { fail=$((fail + 1)); echo "  FAIL: $1"; }
assert_contains() {
    local desc="$1" pattern="$2" actual="$3"
    if grepq "$actual" "$pattern"; then
        assert_pass "$desc"
    else
        assert_fail "$desc — expected pattern '$pattern', got: $actual"
    fi
}
assert_not_contains() {
    local desc="$1" pattern="$2" actual="$3"
    if grepq "$actual" "$pattern"; then
        assert_fail "$desc — did NOT expect pattern '$pattern', got: $actual"
    else
        assert_pass "$desc"
    fi
}

_repo_counter=0

# Build a mock upstream bare repo + a clone with himmel-update.sh (+ the libs
# it sources) dropped in and COMMITTED, so the working tree starts clean.
# Sets CHECKOUT_DIR.
make_mock_clone() {
    _repo_counter=$((_repo_counter + 1))
    local base="$TMP/repo_${_repo_counter}"
    local bare="$base/upstream.git"
    local clone="$base/checkout"
    mkdir -p "$bare" "$clone"

    git init --bare --quiet "$bare"
    git init --quiet "$clone"
    git -C "$clone" config user.email "test@test.test"
    git -C "$clone" config user.name "Test"
    git -C "$clone" remote add origin "$bare"
    printf 'init\n' > "$clone/file.txt"
    git -C "$clone" add file.txt
    git -C "$clone" commit --quiet -m "init"

    local defbranch
    defbranch=$(git -C "$clone" rev-parse --abbrev-ref HEAD)
    git -C "$clone" push --quiet origin "HEAD:$defbranch" 2>/dev/null
    git -C "$clone" branch --quiet --set-upstream-to="origin/$defbranch" "$defbranch" 2>/dev/null || \
        git -C "$clone" branch --quiet -u "origin/$defbranch" "$defbranch" 2>/dev/null || true

    mkdir -p "$clone/scripts/guardrails" "$clone/scripts/lib"
    cp "$SCRIPT" "$clone/scripts/himmel-update.sh"
    local src_scripts; src_scripts="$(dirname "$SCRIPT")"
    cp "$src_scripts/guardrails/lib.sh"        "$clone/scripts/guardrails/lib.sh"
    cp "$src_scripts/lib/cadence-format.sh"    "$clone/scripts/lib/cadence-format.sh"
    cp "$src_scripts/lib/resolve-hermes-py.sh" "$clone/scripts/lib/resolve-hermes-py.sh"
    cp "$src_scripts/lib/load-dotenv.sh"       "$clone/scripts/lib/load-dotenv.sh"
    cp "$src_scripts/lib/resolve-bun.sh"        "$clone/scripts/lib/resolve-bun.sh"
    cp "$src_scripts/lib/claude-version.sh"        "$clone/scripts/lib/claude-version.sh"
    git -C "$clone" add -A
    git -C "$clone" commit --quiet -m "scaffold"
    CHECKOUT_DIR="$clone"
}

# A `claude` stub that logs every invocation ("$@") to $2 and always exits 0 —
# never the real CLI, never touches ~/.claude.
make_claude_logging_stub() {   # <path> <log-file>
    cat > "$1" <<EOF
#!/bin/sh
echo "\$@" >> "$2"
exit 0
EOF
    chmod +x "$1"
}

# Like make_claude_logging_stub, but `plugin install <n>@himmel` re-copies the
# checkout's hooks.json into the cache, as a real reinstall does. Reads
# $DRIFT_STUB_TREE (the checkout's marketplace/plugins) and $HOME at run time.
make_claude_reinstall_stub() {   # <path> <log-file>
    cat > "$1" <<EOF
#!/bin/sh
echo "\$@" >> "$2"
case "\$*" in
  "plugin install "*@himmel)
    n="\${3%@himmel}"
    cp "\$DRIFT_STUB_TREE/\$n/hooks/hooks.json" "\$HOME/.claude/plugins/cache/himmel/\$n/1.0.0/hooks/hooks.json" ;;
esac
exit 0
EOF
    chmod +x "$1"
}

# Like make_claude_logging_stub, but `plugin update <fail-spec>` exits 1.
make_claude_failing_stub() {   # <path> <log-file> <fail-spec>
    cat > "$1" <<EOF
#!/bin/sh
echo "\$@" >> "$2"
[ "\$*" = "plugin update $3" ] && exit 1
exit 0
EOF
    chmod +x "$1"
}

echo "Test: update_installed_plugins updates every non-@himmel installed plugin, before the reconcile"
make_mock_clone
fake_home="$TMP/fake-home"
mkdir -p "$fake_home/.claude"
# A settings.json with one @himmel plugin (must NOT be updated) and two
# third-party plugins, one enabled and one floor-disabled (both are
# INSTALLED — a `false` entry is still installed, just disabled — so both
# must be updated).
cat > "$fake_home/.claude/settings.json" <<'EOF'
{
  "enabledPlugins": {
    "qmd@himmel": true,
    "codex@openai-codex": false,
    "ponytail@ponytail": true
  }
}
EOF
log="$TMP/claude-invocations.log"
: > "$log"
claude_stub="$TMP/claude-logging-stub"
make_claude_logging_stub "$claude_stub" "$log"

rc=0
out=$(USERPROFILE='' HOME="$fake_home" HIMMEL_UPDATE_CLAUDE_BIN="$claude_stub" HERMES_HOME="$TMP/no-hermes" \
      CLAUDE_USER_SETTINGS="$fake_home/.claude/settings.json" \
      bash "$CHECKOUT_DIR/scripts/himmel-update.sh" 2>&1) || rc=$?
if [ "$rc" -eq 0 ]; then
    assert_pass "run completed (rc=$rc)"
else
    assert_fail "run completed (rc=$rc) — out: $out"
fi

log_content="$(cat "$log")"
assert_contains "updates codex@openai-codex (floor-disabled but installed)" "plugin update codex@openai-codex" "$log_content"
assert_contains "updates ponytail@ponytail (enabled)" "plugin update ponytail@ponytail" "$log_content"
assert_not_contains "never updates the @himmel plugin" "plugin update qmd@himmel" "$log_content"

# Ordering: the catch-up section must print before the reconcile section —
# this is what pins "reconcile runs AFTER every marketplace refresh and
# plugin update step".
catchup_pos="${out%%installed plugin version catch-up*}"
reconcile_pos="${out%%lean plugin-set reconcile*}"
if [ "${#catchup_pos}" -lt "${#reconcile_pos}" ] && [ "${#catchup_pos}" -lt "${#out}" ] && [ "${#reconcile_pos}" -lt "${#out}" ]; then
    assert_pass "plugin update catch-up runs before the lean-floor reconcile"
else
    assert_fail "plugin update catch-up runs before the lean-floor reconcile — out: $out"
fi

echo "Test: a plugin that is enabled in settings but NOT installed is never updated (HIMMEL-4380)"
make_mock_clone
fake_home_ni="$TMP/fake-home-notinstalled"
mkdir -p "$fake_home_ni/.claude/plugins"
cat > "$fake_home_ni/.claude/settings.json" <<'EOF'
{
  "enabledPlugins": {
    "ponytail@ponytail": true,
    "ghost@nowhere": true,
    "watch@claude-video": false
  }
}
EOF
cat > "$fake_home_ni/.claude/plugins/installed_plugins.json" <<'EOF'
{"version":2,"plugins":{"ponytail@ponytail":[{"scope":"user","version":"1.0.0"}]}}
EOF
log_ni="$TMP/claude-invocations-ni.log"
: > "$log_ni"
claude_stub_ni="$TMP/claude-logging-stub-ni"
make_claude_logging_stub "$claude_stub_ni" "$log_ni"
rc=0
out_ni=$(USERPROFILE='' HOME="$fake_home_ni" HIMMEL_UPDATE_CLAUDE_BIN="$claude_stub_ni" HERMES_HOME="$TMP/no-hermes" \
      CLAUDE_USER_SETTINGS="$fake_home_ni/.claude/settings.json" \
      bash "$CHECKOUT_DIR/scripts/himmel-update.sh" 2>&1) || rc=$?
log_ni_content="$(cat "$log_ni")"
assert_contains "installed plugin still updated" "plugin update ponytail@ponytail" "$log_ni_content"
assert_not_contains "uninstalled ghost@nowhere never updated" "plugin update ghost@nowhere" "$log_ni_content"
assert_not_contains "uninstalled watch@claude-video never updated" "plugin update watch@claude-video" "$log_ni_content"
assert_contains "skipped plugins are counted on one line" "2 enabled plugin(s) not installed, skipped" "$out_ni"

echo "Test: a registry with a malformed .plugins filters nothing (HIMMEL-4380)"
make_mock_clone
printf '%s\n' '{"version":2,"plugins":[]}' > "$fake_home_ni/.claude/plugins/installed_plugins.json"
: > "$log_ni"
rc=0
out_ni=$(USERPROFILE='' HOME="$fake_home_ni" HIMMEL_UPDATE_CLAUDE_BIN="$claude_stub_ni" HERMES_HOME="$TMP/no-hermes" \
      CLAUDE_USER_SETTINGS="$fake_home_ni/.claude/settings.json" \
      bash "$CHECKOUT_DIR/scripts/himmel-update.sh" 2>&1) || rc=$?
log_ni_content="$(cat "$log_ni")"
assert_contains "unreadable registry: ghost still attempted (old behaviour)" "plugin update ghost@nowhere" "$log_ni_content"
assert_not_contains "unreadable registry: no skip line" "not installed, skipped" "$out_ni"
printf '%s\n' '{"version":2}' > "$fake_home_ni/.claude/plugins/installed_plugins.json"
: > "$log_ni"
rc=0
out_ni=$(USERPROFILE='' HOME="$fake_home_ni" HIMMEL_UPDATE_CLAUDE_BIN="$claude_stub_ni" HERMES_HOME="$TMP/no-hermes" \
      CLAUDE_USER_SETTINGS="$fake_home_ni/.claude/settings.json" \
      bash "$CHECKOUT_DIR/scripts/himmel-update.sh" 2>&1) || rc=$?
log_ni_content="$(cat "$log_ni")"
assert_contains "registry without .plugins: ghost still attempted" "plugin update ghost@nowhere" "$log_ni_content"

echo "Test: --check mode reports what would update, invokes nothing"
make_mock_clone
fake_home_check="$TMP/fake-home-check"
mkdir -p "$fake_home_check/.claude"
cp "$fake_home/.claude/settings.json" "$fake_home_check/.claude/settings.json"
log_check="$TMP/claude-invocations-check.log"
: > "$log_check"
claude_stub_check="$TMP/claude-logging-stub-check"
make_claude_logging_stub "$claude_stub_check" "$log_check"

rc=0
out_check=$(USERPROFILE='' HOME="$fake_home_check" HIMMEL_UPDATE_CLAUDE_BIN="$claude_stub_check" HERMES_HOME="$TMP/no-hermes" \
      CLAUDE_USER_SETTINGS="$fake_home_check/.claude/settings.json" \
      bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --check 2>&1) || rc=$?
assert_contains "check mode: lists ponytail as would-update" "ponytail@ponytail" "$out_check"
check_log_content="$(cat "$log_check")"
if [ -z "$check_log_content" ]; then
    assert_pass "check mode: never invoked claude plugin update"
else
    assert_fail "check mode: never invoked claude plugin update — log: $check_log_content"
fi

echo "Test: apply mode sweeps stale (>24h) temp_git_* dirs from the plugin cache, spares fresh ones (HIMMEL-1846)"
make_mock_clone
fake_home_sweep="$TMP/fake-home-sweep"
mkdir -p "$fake_home_sweep/.claude"
cat > "$fake_home_sweep/.claude/settings.json" <<'EOF'
{
  "enabledPlugins": {
    "qmd@himmel": true
  }
}
EOF
cache_sweep="$fake_home_sweep/.claude/plugins/cache"
mkdir -p "$cache_sweep/temp_git_old" "$cache_sweep/temp_git_new" "$cache_sweep/temp_git_boundary"
touch -t 202001010000 "$cache_sweep/temp_git_old"
# 30h old: past the 24h cutoff but short of the ~48h a day-truncated -mtime
# +1 would actually require — pins the boundary -mtime +1 missed.
backdate "$cache_sweep/temp_git_boundary" "$(($(date +%s) - 30 * 3600))"
log_sweep="$TMP/claude-invocations-sweep.log"
: > "$log_sweep"
claude_stub_sweep="$TMP/claude-logging-stub-sweep"
make_claude_logging_stub "$claude_stub_sweep" "$log_sweep"

rc=0
out_sweep=$(USERPROFILE='' HOME="$fake_home_sweep" HIMMEL_UPDATE_CLAUDE_BIN="$claude_stub_sweep" HERMES_HOME="$TMP/no-hermes" \
      CLAUDE_USER_SETTINGS="$fake_home_sweep/.claude/settings.json" \
      bash "$CHECKOUT_DIR/scripts/himmel-update.sh" 2>&1) || rc=$?

if [ ! -d "$cache_sweep/temp_git_old" ]; then
    assert_pass "apply mode removes the >24h-old temp_git_* dir"
else
    assert_fail "apply mode removes the >24h-old temp_git_* dir — still present — out: $out_sweep"
fi
if [ -d "$cache_sweep/temp_git_new" ]; then
    assert_pass "apply mode spares the fresh temp_git_* dir"
else
    assert_fail "apply mode spares the fresh temp_git_* dir — was removed"
fi
if [ ! -d "$cache_sweep/temp_git_boundary" ]; then
    assert_pass "apply mode removes a 30h-old temp_git_* dir (24-48h boundary)"
else
    assert_fail "apply mode removes a 30h-old temp_git_* dir (24-48h boundary) — still present — out: $out_sweep"
fi

echo "Test: check mode never sweeps the plugin cache"
make_mock_clone
fake_home_sweep_check="$TMP/fake-home-sweep-check"
mkdir -p "$fake_home_sweep_check/.claude"
cat > "$fake_home_sweep_check/.claude/settings.json" <<'EOF'
{
  "enabledPlugins": {
    "qmd@himmel": true
  }
}
EOF
cache_sweep_check="$fake_home_sweep_check/.claude/plugins/cache"
mkdir -p "$cache_sweep_check/temp_git_old"
touch -t 202001010000 "$cache_sweep_check/temp_git_old"
log_sweep_check="$TMP/claude-invocations-sweep-check.log"
: > "$log_sweep_check"
claude_stub_sweep_check="$TMP/claude-logging-stub-sweep-check"
make_claude_logging_stub "$claude_stub_sweep_check" "$log_sweep_check"

rc=0
out_sweep_check=$(USERPROFILE='' HOME="$fake_home_sweep_check" HIMMEL_UPDATE_CLAUDE_BIN="$claude_stub_sweep_check" HERMES_HOME="$TMP/no-hermes" \
      CLAUDE_USER_SETTINGS="$fake_home_sweep_check/.claude/settings.json" \
      bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --check 2>&1) || rc=$?

if [ -d "$cache_sweep_check/temp_git_old" ]; then
    assert_pass "check mode never removes plugin-cache temp_git_* dirs"
else
    assert_fail "check mode never removes plugin-cache temp_git_* dirs — was removed — out: $out_sweep_check"
fi

echo "Test: url-sourced @himmel plugins update, checkout-sourced ones do not (HIMMEL-4127)"
make_mock_clone
mkdir -p "$CHECKOUT_DIR/marketplace/.claude-plugin"
cat > "$CHECKOUT_DIR/marketplace/.claude-plugin/marketplace.json" <<'EOF'
{
  "name": "himmel",
  "plugins": [
    { "name": "qmd", "source": "./plugins/qmd" },
    { "name": "obsidian-second-brain",
      "source": { "source": "url", "url": "https://example.invalid/osb.git", "ref": "v1" } },
    { "name": "mono-sub",
      "source": { "source": "git-subdir", "url": "https://example.invalid/m.git", "path": "p", "ref": "v1" } }
  ]
}
EOF
fake_home_url="$TMP/fake-home-url"
mkdir -p "$fake_home_url/.claude"
cat > "$fake_home_url/.claude/settings.json" <<'EOF'
{
  "enabledPlugins": {
    "qmd@himmel": true,
    "obsidian-second-brain@himmel": true,
    "mono-sub@himmel": false,
    "unlisted@himmel": true,
    "ponytail@ponytail": true
  }
}
EOF
log_url="$TMP/claude-invocations-url.log"
: > "$log_url"
claude_stub_url="$TMP/claude-logging-stub-url"
make_claude_logging_stub "$claude_stub_url" "$log_url"

rc=0
USERPROFILE='' HOME="$fake_home_url" HIMMEL_UPDATE_CLAUDE_BIN="$claude_stub_url" HERMES_HOME="$TMP/no-hermes" \
      CLAUDE_USER_SETTINGS="$fake_home_url/.claude/settings.json" \
      bash "$CHECKOUT_DIR/scripts/himmel-update.sh" >/dev/null 2>&1 || rc=$?
log_url_content="$(cat "$log_url")"
assert_contains "updates the url-sourced @himmel plugin" "plugin update obsidian-second-brain@himmel" "$log_url_content"
assert_contains "updates the git-subdir-sourced @himmel plugin" "plugin update mono-sub@himmel" "$log_url_content"
assert_contains "still updates the non-@himmel plugin" "plugin update ponytail@ponytail" "$log_url_content"
assert_not_contains "never updates the checkout-sourced @himmel plugin" "plugin update qmd@himmel" "$log_url_content"
assert_not_contains "never updates an @himmel plugin absent from the manifest" "plugin update unlisted@himmel" "$log_url_content"

: > "$log_url"
out_url_check=$(USERPROFILE='' HOME="$fake_home_url" HIMMEL_UPDATE_CLAUDE_BIN="$claude_stub_url" HERMES_HOME="$TMP/no-hermes" \
      CLAUDE_USER_SETTINGS="$fake_home_url/.claude/settings.json" \
      bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --check 2>&1) || true
assert_contains "check mode lists the url-sourced @himmel plugin" "obsidian-second-brain@himmel" "$out_url_check"
assert_not_contains "check mode does not list the checkout-sourced plugin as would-update" "      qmd@himmel" "$out_url_check"

echo "Test: a checkout-sourced @himmel plugin updates only when its installed version lags plugin.json (HIMMEL-4295)"
make_mock_clone
mkdir -p "$CHECKOUT_DIR/marketplace/.claude-plugin"
cat > "$CHECKOUT_DIR/marketplace/.claude-plugin/marketplace.json" <<'EOF'
{
  "name": "himmel",
  "plugins": [
    { "name": "qmd", "source": "./plugins/qmd" },
    { "name": "telegram-himmel", "source": "./plugins/telegram-himmel" },
    { "name": "no-manifest", "source": "./plugins/no-manifest" },
    { "name": "not-installed", "source": "./plugins/not-installed" }
  ]
}
EOF
for _p in qmd:1.0.0 telegram-himmel:0.0.11 not-installed:2.0.0; do
    mkdir -p "$CHECKOUT_DIR/marketplace/plugins/${_p%%:*}/.claude-plugin"
    printf '{"name":"%s","version":"%s"}\n' "${_p%%:*}" "${_p#*:}" \
        > "$CHECKOUT_DIR/marketplace/plugins/${_p%%:*}/.claude-plugin/plugin.json"
done
fake_home_ver="$TMP/fake-home-ver"
mkdir -p "$fake_home_ver/.claude/plugins"
cat > "$fake_home_ver/.claude/settings.json" <<'EOF'
{
  "enabledPlugins": {
    "qmd@himmel": true,
    "telegram-himmel@himmel": true,
    "no-manifest@himmel": true,
    "not-installed@himmel": true
  }
}
EOF
# telegram-himmel's USER-scope install lags plugin.json; a project-scope row
# already at the new version must not mask that. qmd is current.
cat > "$fake_home_ver/.claude/plugins/installed_plugins.json" <<'EOF'
{
  "version": 2,
  "plugins": {
    "qmd@himmel": [ { "scope": "user", "version": "1.0.0" } ],
    "telegram-himmel@himmel": [
      { "scope": "project", "projectPath": "/x", "version": "0.0.11" },
      { "scope": "user", "version": "0.0.10" }
    ],
    "no-manifest@himmel": [ { "scope": "user", "version": "0.1.0" } ]
  }
}
EOF
log_ver="$TMP/claude-invocations-ver.log"
: > "$log_ver"
claude_stub_ver="$TMP/claude-logging-stub-ver"
make_claude_logging_stub "$claude_stub_ver" "$log_ver"

rc=0
USERPROFILE='' HOME="$fake_home_ver" HIMMEL_UPDATE_CLAUDE_BIN="$claude_stub_ver" HERMES_HOME="$TMP/no-hermes" \
      CLAUDE_USER_SETTINGS="$fake_home_ver/.claude/settings.json" \
      bash "$CHECKOUT_DIR/scripts/himmel-update.sh" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then
    assert_pass "version-bump run completed (rc=$rc)"
else
    assert_fail "version-bump run completed (rc=$rc)"
fi
log_ver_content="$(cat "$log_ver")"
assert_contains "updates the version-bumped checkout plugin" "plugin update telegram-himmel@himmel" "$log_ver_content"
assert_not_contains "never updates a checkout plugin already at its plugin.json version" "plugin update qmd@himmel" "$log_ver_content"
assert_not_contains "never updates a checkout plugin with no plugin.json" "plugin update no-manifest@himmel" "$log_ver_content"
assert_not_contains "never updates a checkout plugin with no install record" "plugin update not-installed@himmel" "$log_ver_content"

: > "$log_ver"
out_ver_check=$(USERPROFILE='' HOME="$fake_home_ver" HIMMEL_UPDATE_CLAUDE_BIN="$claude_stub_ver" HERMES_HOME="$TMP/no-hermes" \
      CLAUDE_USER_SETTINGS="$fake_home_ver/.claude/settings.json" \
      bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --check 2>&1) || true
assert_contains "check mode lists the version-bumped checkout plugin" "      telegram-himmel@himmel" "$out_ver_check"
assert_not_contains "check mode does not list the current checkout plugin" "      qmd@himmel" "$out_ver_check"

echo "Test: an enabled @himmel plugin the marketplace declares but that is NOT installed gets installed (HIMMEL-5294)"
make_mock_clone
# The fixture mirrors the real shape: the marketplace manifest declares the
# vendored plugin (PR 2382 added i-have-adhd), the user settings enable it, and
# installed_plugins.json has no record of it (the station's degraded state).
mkdir -p "$CHECKOUT_DIR/marketplace/.claude-plugin"
cat > "$CHECKOUT_DIR/marketplace/.claude-plugin/marketplace.json" <<'EOF'
{
  "name": "himmel",
  "plugins": [
    {"name": "i-have-adhd", "source": "./plugins/i-have-adhd"},
    {"name": "off-by-choice", "source": "./plugins/off-by-choice"}
  ]
}
EOF
fake_home_inst="$TMP/fake-home-install"
mkdir -p "$fake_home_inst/.claude/plugins"
cat > "$fake_home_inst/.claude/settings.json" <<'EOF'
{
  "enabledPlugins": {
    "i-have-adhd@himmel": true,
    "off-by-choice@himmel": false,
    "ghost@nowhere": true
  }
}
EOF
printf '%s\n' '{"version":2,"plugins":{}}' > "$fake_home_inst/.claude/plugins/installed_plugins.json"
log_inst="$TMP/claude-invocations-inst.log"
: > "$log_inst"
claude_stub_inst="$TMP/claude-logging-stub-inst"
make_claude_logging_stub "$claude_stub_inst" "$log_inst"
out_inst=$(USERPROFILE='' HOME="$fake_home_inst" HIMMEL_UPDATE_CLAUDE_BIN="$claude_stub_inst" HERMES_HOME="$TMP/no-hermes" \
      CLAUDE_USER_SETTINGS="$fake_home_inst/.claude/settings.json" \
      bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --check 2>&1) || true
log_inst_content="$(cat "$log_inst")"
if [ -z "$log_inst_content" ]; then
    assert_pass "check mode: never invoked claude to install"
else
    assert_fail "check mode: never invoked claude to install — log: $log_inst_content"
fi
assert_contains "check mode lists the missing enabled @himmel plugin" "would install:.*i-have-adhd@himmel\|      i-have-adhd@himmel" "$out_inst"
out_inst=$(USERPROFILE='' HOME="$fake_home_inst" HIMMEL_UPDATE_CLAUDE_BIN="$claude_stub_inst" HERMES_HOME="$TMP/no-hermes" \
      CLAUDE_USER_SETTINGS="$fake_home_inst/.claude/settings.json" \
      bash "$CHECKOUT_DIR/scripts/himmel-update.sh" 2>&1) || true
log_inst_content="$(cat "$log_inst")"
assert_contains "installs the enabled @himmel plugin that is not installed" "plugin install i-have-adhd@himmel" "$log_inst_content"
assert_not_contains "never installs a plugin the user left disabled" "plugin install off-by-choice@himmel" "$log_inst_content"
assert_not_contains "never installs a non-@himmel plugin" "plugin install ghost@nowhere" "$log_inst_content"

echo "Test: an empty installed_plugins.json is unreadable state, not 'nothing installed' (HIMMEL-5294)"
: > "$fake_home_inst/.claude/plugins/installed_plugins.json"
: > "$log_inst"
out_inst=$(USERPROFILE='' HOME="$fake_home_inst" HIMMEL_UPDATE_CLAUDE_BIN="$claude_stub_inst" HERMES_HOME="$TMP/no-hermes" \
      CLAUDE_USER_SETTINGS="$fake_home_inst/.claude/settings.json" \
      bash "$CHECKOUT_DIR/scripts/himmel-update.sh" 2>&1) || true
log_inst_content="$(cat "$log_inst")"
assert_not_contains "empty installed state installs nothing" "plugin install i-have-adhd@himmel" "$log_inst_content"

echo "Test: a plugin only a shipped profile enables is installed too (HIMMEL-6707)"
make_mock_clone
# find-docs is enabled by the `user` profile (injected per launch via
# --settings), never by the user settings.json, so the settings-only gate left
# it uninstalled. base/floor/enable specs all count; a plugin no profile and no
# setting enables stays uninstalled.
mkdir -p "$CHECKOUT_DIR/marketplace/.claude-plugin" "$CHECKOUT_DIR/scripts/lanes"
cat > "$CHECKOUT_DIR/marketplace/.claude-plugin/marketplace.json" <<'EOF'
{
  "name": "himmel",
  "plugins": [
    {"name": "find-docs", "source": "./plugins/find-docs"},
    {"name": "from-base", "source": "./plugins/from-base"},
    {"name": "from-floor", "source": "./plugins/from-floor"},
    {"name": "in-no-profile", "source": "./plugins/in-no-profile"},
    {"name": "user-disabled", "source": "./plugins/user-disabled"}
  ]
}
EOF
cat > "$CHECKOUT_DIR/scripts/lanes/plugin-profiles.json" <<'EOF'
{
  "floor": ["from-floor@himmel"],
  "base": ["from-base@himmel"],
  "profiles": {
    "operator": null,
    "user": {"enable": ["find-docs@himmel", "ghost@nowhere", "user-disabled@himmel"]}
  }
}
EOF
fake_home_prof="$TMP/fake-home-profile"
mkdir -p "$fake_home_prof/.claude/plugins"
printf '%s\n' '{"enabledPlugins":{"user-disabled@himmel":false}}' > "$fake_home_prof/.claude/settings.json"
printf '%s\n' '{"version":2,"plugins":{}}' > "$fake_home_prof/.claude/plugins/installed_plugins.json"
log_prof="$TMP/claude-invocations-profile.log"
: > "$log_prof"
claude_stub_prof="$TMP/claude-logging-stub-profile"
make_claude_logging_stub "$claude_stub_prof" "$log_prof"
out_prof=$(USERPROFILE='' HOME="$fake_home_prof" HIMMEL_UPDATE_CLAUDE_BIN="$claude_stub_prof" HERMES_HOME="$TMP/no-hermes" \
      CLAUDE_USER_SETTINGS="$fake_home_prof/.claude/settings.json" \
      bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --check 2>&1) || true
assert_contains "check mode lists the profile-enabled plugin" "      find-docs@himmel" "$out_prof"
assert_not_contains "check mode installs nothing" "plugin install" "$(cat "$log_prof")"
: > "$log_prof"
rc_prof=0
out_prof=$(USERPROFILE='' HOME="$fake_home_prof" HIMMEL_UPDATE_CLAUDE_BIN="$claude_stub_prof" HERMES_HOME="$TMP/no-hermes" \
      CLAUDE_USER_SETTINGS="$fake_home_prof/.claude/settings.json" \
      bash "$CHECKOUT_DIR/scripts/himmel-update.sh" 2>&1) || rc_prof=$?
if [ "$rc_prof" -eq 0 ]; then
    assert_pass "profile apply run exits 0"
else
    assert_fail "profile apply run exited $rc_prof: $out_prof"
fi
log_prof_content="$(cat "$log_prof")"
assert_contains "installs the plugin only a profile enables" "plugin install find-docs@himmel" "$log_prof_content"
assert_contains "installs a base-enabled plugin" "plugin install from-base@himmel" "$log_prof_content"
assert_contains "installs a floor plugin" "plugin install from-floor@himmel" "$log_prof_content"
assert_not_contains "never installs a plugin no profile or setting enables" "plugin install in-no-profile@himmel" "$log_prof_content"
assert_not_contains "never installs a non-@himmel profile entry" "plugin install ghost@nowhere" "$log_prof_content"
assert_not_contains "a profile never overrides an explicit false in settings" "plugin install user-disabled@himmel" "$log_prof_content"

# A registry that does not parse adds nothing, and the settings-enabled specs
# still install.
printf '%s\n' '{not json' > "$CHECKOUT_DIR/scripts/lanes/plugin-profiles.json"
printf '%s\n' '{"enabledPlugins":{"in-no-profile@himmel":true}}' > "$fake_home_prof/.claude/settings.json"
: > "$log_prof"
rc_prof=0
out_prof=$(USERPROFILE='' HOME="$fake_home_prof" HIMMEL_UPDATE_CLAUDE_BIN="$claude_stub_prof" HERMES_HOME="$TMP/no-hermes" \
      CLAUDE_USER_SETTINGS="$fake_home_prof/.claude/settings.json" \
      bash "$CHECKOUT_DIR/scripts/himmel-update.sh" 2>&1) || rc_prof=$?
if [ "$rc_prof" -eq 0 ]; then
    assert_pass "corrupt-registry run exits 0"
else
    assert_fail "corrupt-registry run exited $rc_prof: $out_prof"
fi
log_prof_content="$(cat "$log_prof")"
assert_contains "a corrupt profile registry still installs the settings-enabled plugin" "plugin install in-no-profile@himmel" "$log_prof_content"
assert_not_contains "a corrupt profile registry adds no profile plugin" "plugin install find-docs@himmel" "$log_prof_content"

echo "Test: one failing plugin update is reported and does not stop the others (HIMMEL-3563)"
make_mock_clone
fake_home_fail="$TMP/fake-home-fail"
mkdir -p "$fake_home_fail/.claude"
cat > "$fake_home_fail/.claude/settings.json" <<'EOF'
{
  "enabledPlugins": {
    "codex@openai-codex": false,
    "ponytail@ponytail": true
  }
}
EOF
log_fail="$TMP/claude-invocations-fail.log"
: > "$log_fail"
claude_stub_fail="$TMP/claude-failing-stub"
make_claude_failing_stub "$claude_stub_fail" "$log_fail" "codex@openai-codex"
rc=0
out_fail=$(USERPROFILE='' HOME="$fake_home_fail" HIMMEL_UPDATE_CLAUDE_BIN="$claude_stub_fail" HERMES_HOME="$TMP/no-hermes" \
      CLAUDE_USER_SETTINGS="$fake_home_fail/.claude/settings.json" \
      bash "$CHECKOUT_DIR/scripts/himmel-update.sh" 2>&1) || rc=$?
log_fail_content="$(cat "$log_fail")"
assert_contains "failing spec was attempted" "plugin update codex@openai-codex" "$log_fail_content"
assert_contains "spec after the failure still updates" "plugin update ponytail@ponytail" "$log_fail_content"
assert_contains "failed spec is reported" "warn: failed to update: codex@openai-codex" "$out_fail"
assert_not_contains "succeeding spec is not reported as failed" "failed to update:.*ponytail@ponytail" "$out_fail"
if [ "$rc" -eq 0 ]; then
    assert_pass "a failed plugin update does not fail the run (rc=$rc)"
else
    assert_fail "a failed plugin update failed the run (rc=$rc) — out: $out_fail"
fi

echo "Test: a same-version @himmel plugin whose cache differs from the checkout is reinstalled (HIMMEL-8016)"
# The cache-side hooks.json line is copied from the real station cache
# (~/.claude/plugins/cache/himmel/himmel-ops/0.4.141/hooks/hooks.json): the
# egress matcher without the Bash alternative; main's has `Bash|` in front.
drift_main_matcher='"matcher": "Bash|mcp__.*[Aa][Gg][Ee][Nn][Tt][-_][Nn][Aa][Tt][Ii][Vv][Ee].*"'
drift_cache_matcher='"matcher": "mcp__.*[Aa][Gg][Ee][Nn][Tt][-_][Nn][Aa][Tt][Ii][Vv][Ee].*"'
# make_drift_scenario <name> -- sets CHECKOUT_DIR and DRIFT_HOME: p1 (cache differs),
# same (cache identical), remote (url-sourced, cache differs), nosrc (no marketplace
# source, cache differs), all installed at 1.0.0.
make_drift_scenario() {
    make_mock_clone
    mkdir -p "$CHECKOUT_DIR/marketplace/.claude-plugin"
    cat > "$CHECKOUT_DIR/marketplace/.claude-plugin/marketplace.json" <<'EOF'
{
  "name": "himmel",
  "plugins": [
    { "name": "p1", "source": "./plugins/p1" },
    { "name": "same", "source": "./plugins/same" },
    { "name": "remote", "source": { "source": "url", "url": "https://example.invalid/r.git" } },
    { "name": "nosrc" }
  ]
}
EOF
    DRIFT_HOME="$TMP/fake-home-drift-$1"
    export DRIFT_STUB_TREE="$CHECKOUT_DIR/marketplace/plugins"
    mkdir -p "$DRIFT_HOME/.claude/plugins"
    local n tree cache inst=""
    for n in p1 same remote nosrc; do
        cache="$DRIFT_HOME/.claude/plugins/cache/himmel/$n/1.0.0"
        mkdir -p "$cache/hooks"
        if [ "$n" = same ]; then
            printf '{ %s }\n' "$drift_main_matcher" > "$cache/hooks/hooks.json"
        else
            printf '{ %s }\n' "$drift_cache_matcher" > "$cache/hooks/hooks.json"
        fi
        tree="$CHECKOUT_DIR/marketplace/plugins/$n"
        mkdir -p "$tree/.claude-plugin" "$tree/hooks"
        printf '{"name":"%s","version":"1.0.0"}\n' "$n" > "$tree/.claude-plugin/plugin.json"
        printf '{ %s }\n' "$drift_main_matcher" > "$tree/hooks/hooks.json"
        inst="$inst\"$n@himmel\":[{\"scope\":\"user\",\"installPath\":\"$cache\",\"version\":\"1.0.0\"}],"
    done
    printf '{"version":2,"plugins":{%s}}\n' "${inst%,}" > "$DRIFT_HOME/.claude/plugins/installed_plugins.json"
    cat > "$DRIFT_HOME/.claude/settings.json" <<'EOF'
{ "enabledPlugins": { "p1@himmel": true, "same@himmel": true, "remote@himmel": true, "nosrc@himmel": true } }
EOF
}
make_drift_scenario apply
log_drift="$TMP/claude-invocations-drift.log"
: > "$log_drift"
claude_stub_drift="$TMP/claude-logging-stub-drift"
make_claude_reinstall_stub "$claude_stub_drift" "$log_drift"
rc=0
out_drift=$(USERPROFILE='' HOME="$DRIFT_HOME" HIMMEL_UPDATE_CLAUDE_BIN="$claude_stub_drift" HERMES_HOME="$TMP/no-hermes" \
      CLAUDE_USER_SETTINGS="$DRIFT_HOME/.claude/settings.json" \
      bash "$CHECKOUT_DIR/scripts/himmel-update.sh" 2>&1) || rc=$?
log_drift_content="$(cat "$log_drift")"
if [ "$rc" -eq 0 ]; then assert_pass "drift run completed (rc=$rc)"; else assert_fail "drift run completed (rc=$rc) — out: $out_drift"; fi
assert_contains "drifted p1 is uninstalled (data kept)" "plugin uninstall --keep-data p1@himmel" "$log_drift_content"
assert_contains "drifted p1 is installed again" "plugin install p1@himmel" "$log_drift_content"
un_pos="${log_drift_content%%plugin uninstall --keep-data p1@himmel*}"
in_pos="${log_drift_content%%plugin install p1@himmel*}"
if [ "${#un_pos}" -lt "${#in_pos}" ]; then assert_pass "uninstall runs before install"; else assert_fail "uninstall runs before install — log: $log_drift_content"; fi
assert_not_contains "an identical cache is left alone" "same@himmel" "$log_drift_content"
assert_not_contains "a url-sourced plugin is never uninstalled" "plugin uninstall --keep-data remote@himmel" "$log_drift_content"
assert_not_contains "a url-sourced plugin is never reinstalled" "plugin install remote@himmel" "$log_drift_content"
assert_not_contains "a plugin with no marketplace source is never reinstalled" "nosrc@himmel" "$log_drift_content"

echo "Test: check mode names the drifted cache and invokes nothing (HIMMEL-8016)"
make_drift_scenario check
: > "$log_drift"
out_drift_check=$(USERPROFILE='' HOME="$DRIFT_HOME" HIMMEL_UPDATE_CLAUDE_BIN="$claude_stub_drift" HERMES_HOME="$TMP/no-hermes" \
      CLAUDE_USER_SETTINGS="$DRIFT_HOME/.claude/settings.json" \
      bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --check 2>&1) || true
assert_contains "check mode lists the drifted plugin" "would reinstall p1@himmel" "$out_drift_check"
assert_not_contains "check mode does not list the identical plugin" "would reinstall same@himmel" "$out_drift_check"
if [ -z "$(cat "$log_drift")" ]; then assert_pass "check mode never invoked claude for the drift"; else assert_fail "check mode invoked claude: $(cat "$log_drift")"; fi

echo "Test: an install that fails after the uninstall is loud and fails the run (HIMMEL-8016)"
make_drift_scenario failinst
log_drift_fail="$TMP/claude-invocations-drift-fail.log"
: > "$log_drift_fail"
claude_stub_drift_fail="$TMP/claude-install-failing-stub"
cat > "$claude_stub_drift_fail" <<EOF
#!/bin/sh
echo "\$@" >> "$log_drift_fail"
[ "\$*" = "plugin install p1@himmel" ] && exit 1
exit 0
EOF
chmod +x "$claude_stub_drift_fail"
rc=0
out_drift_fail=$(USERPROFILE='' HOME="$DRIFT_HOME" HIMMEL_UPDATE_CLAUDE_BIN="$claude_stub_drift_fail" HERMES_HOME="$TMP/no-hermes" \
      CLAUDE_USER_SETTINGS="$DRIFT_HOME/.claude/settings.json" \
      bash "$CHECKOUT_DIR/scripts/himmel-update.sh" 2>&1) || rc=$?
if [ "$rc" -ne 0 ]; then assert_pass "a failed reinstall fails the run (rc=$rc)"; else assert_fail "a failed reinstall left rc=0 — out: $out_drift_fail"; fi
assert_contains "the failure names the plugin and says it is uninstalled" "ERROR: p1@himmel was uninstalled but the reinstall failed" "$out_drift_fail"
assert_contains "the failure prints the recovery command" "claude plugin install p1@himmel" "$out_drift_fail"

echo "Test: --only plugin-refresh runs just the cache repair and returns its outcome (HIMMEL-8016)"
make_drift_scenario only
: > "$log_drift"
rc=0
out_only=$(USERPROFILE='' HOME="$DRIFT_HOME" HIMMEL_UPDATE_CLAUDE_BIN="$claude_stub_drift" HERMES_HOME="$TMP/no-hermes" \
      CLAUDE_USER_SETTINGS="$DRIFT_HOME/.claude/settings.json" \
      bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --only plugin-refresh 2>&1) || rc=$?
log_only="$(cat "$log_drift")"
if [ "$rc" -eq 0 ]; then assert_pass "--only plugin-refresh succeeds (rc=$rc)"; else assert_fail "--only plugin-refresh rc=$rc — out: $out_only"; fi
assert_contains "--only plugin-refresh reinstalls the drifted plugin" "plugin uninstall --keep-data p1@himmel" "$log_only"
assert_contains "--only plugin-refresh installs it again" "plugin install p1@himmel" "$log_only"
assert_not_contains "--only plugin-refresh runs no marketplace refresh" "marketplace update" "$log_only"
assert_not_contains "--only plugin-refresh runs no plugin update" "plugin update" "$log_only"

make_drift_scenario onlyfail
: > "$log_drift_fail"
rc=0
out_only_fail=$(USERPROFILE='' HOME="$DRIFT_HOME" HIMMEL_UPDATE_CLAUDE_BIN="$claude_stub_drift_fail" HERMES_HOME="$TMP/no-hermes" \
      CLAUDE_USER_SETTINGS="$DRIFT_HOME/.claude/settings.json" \
      bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --only plugin-refresh 2>&1) || rc=$?
if [ "$rc" -ne 0 ]; then assert_pass "--only plugin-refresh exits nonzero when the reinstall fails (rc=$rc)"; else assert_fail "--only plugin-refresh rc=0 after a failed reinstall — out: $out_only_fail"; fi
assert_contains "--only plugin-refresh failure is loud" "ERROR: p1@himmel was uninstalled but the reinstall failed" "$out_only_fail"

echo "Test: an uninstall that fails leaves the stale cache and fails the run (HIMMEL-8016)"
make_drift_scenario failuninst
claude_stub_drift_un="$TMP/claude-uninstall-failing-stub"
log_drift_un="$TMP/claude-invocations-drift-un.log"
: > "$log_drift_un"
cat > "$claude_stub_drift_un" <<EOF
#!/bin/sh
echo "\$@" >> "$log_drift_un"
case "\$*" in "plugin uninstall --keep-data p1@himmel") exit 1 ;; esac
exit 0
EOF
chmod +x "$claude_stub_drift_un"
rc=0
out_drift_un=$(USERPROFILE='' HOME="$DRIFT_HOME" HIMMEL_UPDATE_CLAUDE_BIN="$claude_stub_drift_un" HERMES_HOME="$TMP/no-hermes" \
      CLAUDE_USER_SETTINGS="$DRIFT_HOME/.claude/settings.json" \
      bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --only plugin-refresh 2>&1) || rc=$?
if [ "$rc" -ne 0 ]; then assert_pass "a failed uninstall fails --only plugin-refresh (rc=$rc)"; else assert_fail "a failed uninstall left rc=0 — out: $out_drift_un"; fi
assert_contains "the failure names the plugin and says the stale cache stays" "ERROR: uninstall of p1@himmel failed" "$out_drift_un"
assert_contains "the uninstall was attempted" "plugin uninstall --keep-data p1@himmel" "$(cat "$log_drift_un")"
assert_not_contains "no install follows a failed uninstall" "plugin install p1@himmel" "$(cat "$log_drift_un")"

echo "Test: a reinstall that leaves the cache differing fails the run (HIMMEL-8016)"
make_drift_scenario stale
log_drift_stale="$TMP/claude-invocations-drift-stale.log"
claude_stub_drift_stale="$TMP/claude-logging-stub-stale"
make_claude_logging_stub "$claude_stub_drift_stale" "$log_drift_stale"
rc=0
out_drift_stale=$(USERPROFILE='' HOME="$DRIFT_HOME" HIMMEL_UPDATE_CLAUDE_BIN="$claude_stub_drift_stale" HERMES_HOME="$TMP/no-hermes" \
      CLAUDE_USER_SETTINGS="$DRIFT_HOME/.claude/settings.json" \
      bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --only plugin-refresh 2>&1) || rc=$?
if [ "$rc" -ne 0 ]; then assert_pass "a reinstall that leaves drift fails --only plugin-refresh (rc=$rc)"; else assert_fail "stale cache after reinstall left rc=0 — out: $out_drift_stale"; fi
assert_contains "the failure names the plugin and the recovery command" "p1@himmel still differs from the checkout after the reinstall" "$out_drift_stale"

echo "Test: a disabled plugin and a version-lagged cache are left alone (HIMMEL-8016)"
make_drift_scenario disabled
printf '%s\n' '{ "enabledPlugins": { "p1@himmel": false, "same@himmel": true } }' > "$DRIFT_HOME/.claude/settings.json"
: > "$log_drift"
rc=0
out_disabled=$(USERPROFILE='' HOME="$DRIFT_HOME" HIMMEL_UPDATE_CLAUDE_BIN="$claude_stub_drift" HERMES_HOME="$TMP/no-hermes" \
      CLAUDE_USER_SETTINGS="$DRIFT_HOME/.claude/settings.json" \
      bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --only plugin-refresh 2>&1) || rc=$?
log_disabled="$(cat "$log_drift")"
if [ "$rc" -eq 0 ]; then assert_pass "disabled-plugin run completed (rc=$rc)"; else assert_fail "disabled-plugin run rc=$rc — out: $out_disabled"; fi
assert_not_contains "a disabled plugin with a differing cache is never uninstalled" "p1@himmel" "$log_disabled"

make_drift_scenario lag
printf '{"name":"p1","version":"1.0.1"}\n' > "$CHECKOUT_DIR/marketplace/plugins/p1/.claude-plugin/plugin.json"
: > "$log_drift"
rc=0
out_lag=$(USERPROFILE='' HOME="$DRIFT_HOME" HIMMEL_UPDATE_CLAUDE_BIN="$claude_stub_drift" HERMES_HOME="$TMP/no-hermes" \
      CLAUDE_USER_SETTINGS="$DRIFT_HOME/.claude/settings.json" \
      bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --only plugin-refresh 2>&1) || rc=$?
log_lag="$(cat "$log_drift")"
if [ "$rc" -eq 0 ]; then assert_pass "version-lag run completed (rc=$rc)"; else assert_fail "version-lag run rc=$rc — out: $out_lag"; fi
assert_not_contains "a cache older than the checkout is left to the version update" "p1@himmel" "$log_lag"

echo ""
echo "=== $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
