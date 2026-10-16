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

unset MIN_TIMEOUT
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
out=$(CLAUDE_CONFIG_DIR="$CFG" bash "$BUMPER" --dry-run 2>&1 || true)
chk "dry-run leaves timeout 5" "5" "$(end_t 1.0.6)"
chk "dry-run reports WOULD BUMP" "yes" "$(grep -q "WOULD BUMP" <<< "$out" && echo yes || echo no)"

# --- real run ----------------------------------------------------------------
run_rc=0
CLAUDE_CONFIG_DIR="$CFG" bash "$BUMPER" > "$TMP/run.out" 2>&1 || run_rc=$?
chk "skipped (unparseable) file makes the run exit 1" "1" "$run_rc"
chk "skipped run does not end with OK" "no" "$(tail -n1 "$TMP/run.out" | grep -q '^OK' && echo yes || echo no)"
chk "skipped run reports the skip count" "yes" "$(grep -q 'skipped 1' "$TMP/run.out" && echo yes || echo no)"
chk "1.0.5 SessionEnd raised to 30" "30" "$(end_t 1.0.5)"
chk "1.0.6 SessionEnd raised to 30" "30" "$(end_t 1.0.6)"
chk "larger timeout kept" "120" "$(end_t 1.0.7)"
chk "SessionStart untouched" "5" "$(start_t 1.0.6)"
chk "Stop untouched" "900" "$(jq -r '.hooks.Stop[0].hooks[0].timeout' "$BASE/1.0.6/hooks/hooks.json")"
chk "top-level description preserved" "Optional stop-time review gate for Codex Companion." "$(jq -r '.description' "$BASE/1.0.6/hooks/hooks.json")"
chk "malformed file untouched" "{ not json" "$(cat "$BASE/bad/hooks/hooks.json")"

# --- file mode preserved, symlink kept, entry without .hooks -----------------
mkdir -p "$BASE/mode/hooks" "$BASE/sym/hooks" "$BASE/nokey/hooks" "$TMP/real"
mk mode 5
chmod 0644 "$BASE/mode/hooks/hooks.json"
mk sym 5
mv "$BASE/sym/hooks/hooks.json" "$TMP/real/hooks.json"
ln -s "$TMP/real/hooks.json" "$BASE/sym/hooks/hooks.json"
cat > "$BASE/nokey/hooks/hooks.json" <<'JSON'
{ "hooks": { "SessionEnd": [ { "matcher": "x" }, { "hooks": [ { "type": "command", "command": "node session-lifecycle-hook.mjs SessionEnd", "timeout": 5 } ] } ] } }
JSON
CLAUDE_CONFIG_DIR="$CFG" bash "$BUMPER" > "$TMP/run2.out" 2>&1 || true
chk "mode 0644 preserved" "644" "$(stat -c %a "$BASE/mode/hooks/hooks.json")"
chk "mode-fixture bumped" "30" "$(end_t mode)"
chk "symlink still a symlink" "yes" "$([ -L "$BASE/sym/hooks/hooks.json" ] && echo yes || echo no)"
chk "symlink target patched" "30" "$(jq -r '.hooks.SessionEnd[0].hooks[0].timeout' "$TMP/real/hooks.json")"
chk "entry without .hooks kept" "x" "$(jq -r '.hooks.SessionEnd[0].matcher' "$BASE/nokey/hooks/hooks.json")"
chk "entry without .hooks does not block bump" "30" "$(jq -r '.hooks.SessionEnd[1].hooks[0].timeout' "$BASE/nokey/hooks/hooks.json")"

# --- idempotent --------------------------------------------------------------
rm -rf "$BASE/bad"   # the unparseable fixture has done its job; a clean cache lets the rerun reach "nothing to bump"
before=$(cat "$BASE/1.0.6/hooks/hooks.json")
out2=$(CLAUDE_CONFIG_DIR="$CFG" bash "$BUMPER" 2>&1 || true)
chk "rerun is a no-op" "$before" "$(cat "$BASE/1.0.6/hooks/hooks.json")"
chk "rerun reports nothing to bump" "yes" "$(grep -q "nothing to bump" <<< "$out2" && echo yes || echo no)"

# --- no cache ----------------------------------------------------------------
empty_rc=0
CLAUDE_CONFIG_DIR="$TMP/empty" bash "$BUMPER" >/dev/null 2>&1 || empty_rc=$?
chk "missing cache exits 0" "0" "$empty_rc"

# --- MIN_TIMEOUT must be a positive integer ----------------------------------
for bad in '"30"' 'abc' '0' '-5' '1.5' ''; do
  bad_rc=0
  MIN_TIMEOUT="$bad" CLAUDE_CONFIG_DIR="$CFG" bash "$BUMPER" >/dev/null 2>&1 || bad_rc=$?
  chk "MIN_TIMEOUT='$bad' rejected with exit 2" "2" "$bad_rc"
done
chk "rejected MIN_TIMEOUT left hooks.json numeric" "number" "$(jq -r '.hooks.SessionEnd[0].hooks[0].timeout | type' "$BASE/1.0.6/hooks/hooks.json")"

if [ "$fails" -eq 0 ]; then echo "PASS"; exit 0; fi
echo "$fails failure(s)" >&2
exit 1
