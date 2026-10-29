#!/usr/bin/env bash
# test-himmel-doctor-mcp-sources.sh — doctor C82-mcp-sources lists every MCP server with its source layer.
#   user config (~/.claude.json mcpServers), project .mcp.json, an enabled plugin's .mcp.json,
#   the himmel lane catalog (scripts/lanes/plugin-profiles.json mcpCatalog) and the runtime
#   built-in plugins (easel). easel is never listed as unknown; no env or secret value is printed.
# Every fixture lives under a temp dir; the real HOME and settings are never read.
# Run: bash scripts/test-himmel-doctor-mcp-sources.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOC="$ROOT/scripts/himmel-doctor.sh"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
has() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1 (missing '$2' in: $3)" ;; esac; }
lacks() { case "$3" in *"$2"*) fail "$1 (found '$2' in: $3)" ;; *) pass "$1" ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/doctor-mcp-sources-test.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT

PROJ="$WORK/root"
mkdir -p "$PROJ" "$WORK/home" "$WORK/claude/plugins/cache/fixmkt/fixplug/1.0.0"
ln -s "$ROOT/scripts" "$PROJ/scripts"
printf '{"mcpServers":{"fixture-user":{"command":"x","env":{"TOKEN":"SECRET-ENV-VALUE-1"}}}}\n' > "$WORK/home/.claude.json"
printf '{"mcpServers":{"fixture-proj":{"command":"y","env":{"TOKEN":"SECRET-ENV-VALUE-2"}}}}\n' > "$PROJ/.mcp.json"
printf '{"enabledPlugins":{"fixplug@fixmkt":true}}\n' > "$WORK/claude/settings.json"
printf '{"mcpServers":{"fixture-plug":{"command":"z"}}}\n' > "$WORK/claude/plugins/cache/fixmkt/fixplug/1.0.0/.mcp.json"

out="$(HOME="$WORK/home" CLAUDE_DIR="$WORK/claude" bash "$DOC" --root "$PROJ" --only C82 --no-color 2>&1)"

echo "== C82: every source layer is listed with its server =="
has "C82 row present" "C82-mcp-sources" "$out"
has "C82 user config" "fixture-user [user config]" "$out"
has "C82 project .mcp.json" "fixture-proj [project .mcp.json]" "$out"
has "C82 enabled plugin" "fixture-plug [plugin fixplug]" "$out"
has "C82 lane catalog" "himmel-bus [himmel lane catalog]" "$out"

echo "== C82: easel has a named source, never unknown =="
has "C82 easel runtime source" "easel [runtime: built-in cc-plugin-easel plugin of the Claude Code binary]" "$out"
lacks "C82 no unknown source" "unknown" "$out"

echo "== C82: no env or secret value is printed =="
lacks "C82 first env value" "SECRET-ENV-VALUE-1" "$out"
lacks "C82 second env value" "SECRET-ENV-VALUE-2" "$out"

[ "$fails" -eq 0 ] && echo "all passed" && exit 0
echo "$fails failed"; exit 1
