#!/usr/bin/env bash
# obsidian-triage carries the ported validate-ai-first PostToolUse hook, so a
# bridge vault write is still checked once obsidian-second-brain is gone.
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$PLUGIN_DIR/hooks/validate-ai-first.sh"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"

pass=0
fail=0
# check <desc> <command...>: PASS when the command succeeds.
check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  PASS  $desc"; pass=$((pass+1))
  else
    echo "  FAIL  $desc"; fail=$((fail+1))
  fi
}

check "hook script is present and executable" test -x "$HOOK"
check "hooks.json registers it as a PostToolUse hook" \
  jq -e '.hooks.PostToolUse[]?.hooks[]? | select(.command | contains("validate-ai-first.sh"))' "$HOOKS_JSON"
check "hooks.json matcher covers Write and Edit" \
  jq -e '.hooks.PostToolUse[]? | select(.matcher | test("Write")) | select(.matcher | test("Edit"))' "$HOOKS_JSON"
check "hook keeps its MIT licence header" grep -q "MIT License" "$HOOK"
check "hook credits obsidian-second-brain" grep -q "eugeniughelbur/obsidian-second-brain" "$HOOK"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/validate-ai-first.XXXXXX")" || exit 1
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/vault/20-Areas" "$tmp/home"
printf '# no frontmatter\n' > "$tmp/vault/20-Areas/bad.md"
printf -- '---\ndate: 2026-11-01\ntype: note\ntags: [a]\nai-first: true\n---\n\n## For future agent\n\nbody\n' > "$tmp/vault/20-Areas/good.md"
printf '# outside\n' > "$tmp/outside.md"

run() { # $1=file; the vault is the fixture vault
  printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$1" \
    | HOME="$tmp/home" OBSIDIAN_VAULT_PATH="$tmp/vault" AI_FIRST_SKIP_CHECKS='' OBSIDIAN_ENV_FILE="$tmp/none.env" bash "$HOOK" 2>/dev/null
}

out="$(run "$tmp/vault/20-Areas/bad.md")"
check "a vault write without frontmatter is flagged" \
  jq -e '.decision == "block" and (.reason | contains("no frontmatter"))' <<<"$out"

out="$(run "$tmp/vault/20-Areas/good.md")"
check "a conforming vault note passes silently" test -z "$out"

out="$(run "$tmp/outside.md")"
check "a file outside the vault is ignored" test -z "$out"

echo "validate-ai-first: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
