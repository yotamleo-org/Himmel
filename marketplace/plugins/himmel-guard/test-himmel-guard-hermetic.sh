#!/usr/bin/env bash
# test-himmel-guard-hermetic.sh — the himmel-guard suite must not write to an
# inherited CLAUDE_CONFIG_DIR: a claudex leg exports it, and a
# plugin install would land in the live lane config instead of the test HOME.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
fail=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

command -v claude >/dev/null 2>&1 || { echo "SKIP: claude CLI not installed"; exit 0; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/himmel-guard-hermetic.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
sentinel="$tmp/sentinel-config"
mkdir -p "$sentinel"

CLAUDE_CONFIG_DIR="$sentinel" bash "$HERE/test-himmel-guard.sh" >"$tmp/suite.log" 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then ok "suite passes with an inherited CLAUDE_CONFIG_DIR (rc 0)"; else sed 's/^/  | /' "$tmp/suite.log"; bad "suite rc $rc with an inherited CLAUDE_CONFIG_DIR"; fi

if [ -z "$(find "$sentinel" -mindepth 1 -print -quit)" ]; then ok "inherited CLAUDE_CONFIG_DIR untouched"; else find "$sentinel" | head; bad "suite wrote into the inherited CLAUDE_CONFIG_DIR"; fi

exit $fail
