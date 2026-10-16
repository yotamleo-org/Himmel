#!/usr/bin/env bash
# test-himmel-guard.sh — installs ONLY himmel-guard into an empty HOME (no himmel
# clone on the path) and proves the destructive-command guard denies from the
# installed copy. The suite is the spec.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MARKET="$(cd "$HERE/../.." && pwd)"
fail=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
want() { if [ "$2" = "$1" ]; then ok "$3"; else bad "$3 (rc $2)"; fi; }

command -v claude >/dev/null 2>&1 || { echo "SKIP: claude CLI not installed"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required"; exit 1; }

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
mkdir -p "$HOME"
unset CLAUDE_PROJECT_DIR

claude plugin marketplace add "$MARKET" >"$tmp/add.log" 2>&1 || { cat "$tmp/add.log"; bad "marketplace add"; }
claude plugin install himmel-guard@himmel >"$tmp/inst.log" 2>&1 || { cat "$tmp/inst.log"; bad "plugin install himmel-guard@himmel"; exit 1; }

hook=$(find "$HOME/.claude/plugins" -type f -name block-destructive-commands.sh -path '*himmel-guard*' 2>/dev/null | head -1)
[ -n "$hook" ] || { bad "hook not present in the installed plugin"; exit 1; }
root=$(cd "$(dirname "$hook")/.." && pwd)
export CLAUDE_PLUGIN_ROOT="$root"

cmd=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$root/hooks/hooks.json")
case "$cmd" in *CLAUDE_PROJECT_DIR*) bad "hooks.json reaches into CLAUDE_PROJECT_DIR";; *) ok "no CLAUDE_PROJECT_DIR reach";; esac
ver=$(jq -r '.version // empty' "$root/.claude-plugin/plugin.json")
if [ -n "$ver" ]; then ok "own version $ver"; else bad "no own version"; fi

run() { printf '%s' "$1" | sh -c "$cmd" >/dev/null 2>"$tmp/err"; echo $?; }

rc=$(run '{"tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/himmel-guard-fixture"}}')
want 2 "$rc" "rm -rf denied (rc 2)"
rc=$(run '{"tool_name":"Bash","tool_input":{"command":"bash -c \"rm -rf /tmp/himmel-guard-fixture\""}}')
want 2 "$rc" "wrapped rm -rf denied (unwrap lib loads)"
rc=$(run '{"tool_name":"Bash","tool_input":{"command":"ls /tmp"}}')
want 0 "$rc" "benign command allowed"
rc=$(run '{"tool_name":"Bash"')
want 2 "$rc" "malformed input fails closed"

exit $fail
