#!/usr/bin/env bash
# Hermetic tests for bump-codex-sessionend-timeout.sh.
# A temp CLAUDE_CONFIG_DIR holds fixture openai-codex plugin hooks.json files.
# Asserts: the SessionEnd lifecycle-hook timeout is raised, other hooks and
# keys are untouched, --dry-run mutates nothing, a rerun is idempotent, an
# already-larger timeout is kept, a malformed file is skipped, and a missing
# cache exits 0.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUMPER="$SCRIPT_DIR/bump-codex-sessionend-timeout.sh"

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }

fails=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; fails=$((fails + 1)); }
chk() { # chk <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT

CFG="$TMP/.claude"
BASE="$CFG/plugins/cache/openai-codex/codex"
mkdir -p "$BASE/1.0.5/hooks" "$BASE/1.0.6/hooks" "$BASE/1.0.7/hooks" "$BASE/bad/hooks"

mk() { # mk <dir> <sessionend-timeout>
  cat > "$BASE/$1/hooks/hooks.json" <<JSON
{
  "description": "Optional stop-time review gate for Codex Companion.",
  "hooks": {
    "SessionStart": [{ "hooks": [{ "type": "command", "command": "node \"\${CLAUDE_PLUGIN_ROOT}/scripts/session-lifecycle-hook.mjs\" SessionStart", "timeout": 5 }] }],
    "SessionEnd": [{ "hooks": [{ "type": "command", "command": "node \"\${CLAUDE_PLUGIN_ROOT}/scripts/session-lifecycle-hook.mjs\" SessionEnd", "timeout": $2 }] }],
    "Stop": [{ "hooks": [{ "type": "command", "command": "node \"\${CLAUDE_PLUGIN_ROOT}/scripts/stop-review-gate-hook.mjs\"", "timeout": 900 }] }]
  }
}
JSON
}
mk 1.0.5 5
mk 1.0.6 5
mk 1.0.7 120
printf '{ not json' > "$BASE/bad/hooks/hooks.json"

end_t() { jq -r '.hooks.SessionEnd[0].hooks[0].timeout' "$BASE/$1/hooks/hooks.json"; }
start_t() { jq -r '.hooks.SessionStart[0].hooks[0].timeout' "$BASE/$1/hooks/hooks.json"; }

# --- dry-run mutates nothing -------------------------------------------------
out=$(CLAUDE_CONFIG_DIR="$CFG" bash "$BUMPER" --dry-run 2>&1)
chk "dry-run leaves timeout 5" "5" "$(end_t 1.0.6)"
chk "dry-run reports WOULD BUMP" "yes" "$(grep -q "WOULD BUMP" <<< "$out" && echo yes || echo no)"

# --- real run ----------------------------------------------------------------
run_rc=0
CLAUDE_CONFIG_DIR="$CFG" bash "$BUMPER" > "$TMP/run.out" 2>&1 || run_rc=$?
chk "bumper exits 0" "0" "$run_rc"
chk "1.0.5 SessionEnd raised to 30" "30" "$(end_t 1.0.5)"
chk "1.0.6 SessionEnd raised to 30" "30" "$(end_t 1.0.6)"
chk "larger timeout kept" "120" "$(end_t 1.0.7)"
chk "SessionStart untouched" "5" "$(start_t 1.0.6)"
chk "Stop untouched" "900" "$(jq -r '.hooks.Stop[0].hooks[0].timeout' "$BASE/1.0.6/hooks/hooks.json")"
chk "top-level description preserved" "Optional stop-time review gate for Codex Companion." "$(jq -r '.description' "$BASE/1.0.6/hooks/hooks.json")"
chk "malformed file untouched" "{ not json" "$(cat "$BASE/bad/hooks/hooks.json")"

# --- idempotent --------------------------------------------------------------
before=$(cat "$BASE/1.0.6/hooks/hooks.json")
out2=$(CLAUDE_CONFIG_DIR="$CFG" bash "$BUMPER" 2>&1)
chk "rerun is a no-op" "$before" "$(cat "$BASE/1.0.6/hooks/hooks.json")"
chk "rerun reports nothing to bump" "yes" "$(grep -q "nothing to bump" <<< "$out2" && echo yes || echo no)"

# --- no cache ----------------------------------------------------------------
empty_rc=0
CLAUDE_CONFIG_DIR="$TMP/empty" bash "$BUMPER" >/dev/null 2>&1 || empty_rc=$?
chk "missing cache exits 0" "0" "$empty_rc"

if [ "$fails" -eq 0 ]; then echo "PASS"; exit 0; fi
echo "$fails failure(s)" >&2
exit 1
