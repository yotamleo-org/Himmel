#!/usr/bin/env bash
# test-list-enforced-rules.sh — tests for scripts/lint/list-enforced-rules.sh.
#
# The expected table is built from a fixture hook config and a fixture
# pre-commit config, so the test pins the parse rather than today's hook set.
#
# Exit: 0 all passed, 1 any failed. bash 3.2-safe.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
GEN="$SELF_DIR/list-enforced-rules.sh"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

if [ ! -f "$GEN" ]; then
    echo "FAIL: $GEN does not exist yet (RED)"
    exit 1
fi

T="$(mktemp -d "${TMPDIR:-/tmp}/list-enforced.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT

cat > "$T/hooks.json" <<'EOF'
{"hooks": {
  "PreToolUse": [
    {"matcher": "Bash", "hooks": [{"type": "command",
      "command": "if [ -f x ]; then sh run-node.sh \"$P/scripts/hooks/run-hook-with-bash.js\" --chain \"$P/scripts/hooks/block-alpha.sh\" \"$P/scripts/hooks/block-beta.sh\"; else node \"$P/scripts/hooks/run-hook-with-bash.js\" --chain \"$P/scripts/hooks/block-alpha.sh\" \"$P/scripts/hooks/block-beta.sh\"; fi"}]},
    {"matcher": "Edit|Write", "hooks": [{"type": "command",
      "command": "node \"$P/scripts/hooks/run-hook-with-bash.js\" \"$P/scripts/hooks/block-alpha.sh\""}]}
  ],
  "PostToolUse": [
    {"matcher": "Agent", "hooks": [{"type": "command", "command": "bun \"$P/scripts/observability/session-run-hook.ts\" end"}]}
  ]
}}
EOF

cat > "$T/precommit.yaml" <<'EOF'
repos:
  - repo: local
    hooks:
      - id: gate-one
        name: Gate one
        entry: bash scripts/ci/gate-one.sh
        stages: [pre-commit]
      - id: gate-two
        name: Gate two
        stages: [pre-push, commit-msg]
      - id: gate-three
        name: Gate three
EOF

EXPECT='| name | event | matcher |
|---|---|---|
| block-alpha | PreToolUse | Bash |
| block-beta | PreToolUse | Bash |
| block-alpha | PreToolUse | Edit|Write |
| session-run-hook | PostToolUse | Agent |
| gate-one | pre-commit | - |
| gate-two | pre-push | - |
| gate-two | commit-msg | - |
| gate-three | pre-commit | - |'

OUT="$(bash "$GEN" --settings "$T/hooks.json" --precommit "$T/precommit.yaml" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then pass "fixture config exits 0"; else fail "fixture config exit $RC: $OUT"; fi
if [ "$OUT" = "$EXPECT" ]; then
    pass "fixture table matches expected"
else
    fail "fixture table differs"
    printf '%s\n%s\n%s\n%s\n' '--- expected' "$EXPECT" '--- got' "$OUT"
fi

OUT2="$(bash "$GEN" --settings "$T/hooks.json" --precommit "$T/precommit.yaml" 2>&1)"
if [ "$OUT" = "$OUT2" ]; then pass "output is deterministic"; else fail "output differs between runs"; fi

OUT="$(bash "$GEN" --settings "$T/missing.json" --precommit "$T/precommit.yaml" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ]; then pass "missing settings file fails closed (exit 2)"; else fail "missing settings exit $RC"; fi

echo '{ not json' > "$T/bad.json"
OUT="$(bash "$GEN" --settings "$T/bad.json" --precommit "$T/precommit.yaml" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ]; then pass "malformed settings fails closed (exit 2)"; else fail "malformed settings exit $RC"; fi

OUT="$(bash "$GEN" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then pass "real tree config parses"; else fail "real tree exit $RC: $OUT"; fi
case "$OUT" in
    *"| block-git-stash | PreToolUse | Bash |"*) pass "real table lists block-git-stash on Bash" ;;
    *) fail "real table lacks block-git-stash" ;;
esac

echo "list-enforced-rules: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
