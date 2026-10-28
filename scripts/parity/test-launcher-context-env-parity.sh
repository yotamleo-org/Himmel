#!/usr/bin/env bash
# test-launcher-context-env-parity.sh — the claude-codex launcher must feed
# the context-window env pair from the CODEX_CONTEXT_WINDOW variable
#, and the launcher defaults the per-dispatch effort to `xhigh` (decision 223),
# the value lanes.json declares.
#
# A launcher missing the CLAUDE_CODE_MAX_CONTEXT_TOKENS export would ship
# green without this guard. The export is load-bearing: Claude
# Code resolves the effective compact window as min(modelWindow, configured),
# and for an out-of-catalog model (gpt-5.6-sol) modelWindow falls back to a
# hardcoded 200000 — without the export, CODEX_CONTEXT_WINDOW is silently
# clamped and never takes effect.
#
# The variable-not-literal assertion is the load-bearing one: a hardcoded
# number reintroduces the clamp the moment a caller overrides
# CODEX_CONTEXT_WINDOW. End-of-line is deliberately unanchored (CRLF-safe);
# matching the VARIABLE reference is what excludes a numeric literal.
#
# bash 3.2-safe; grep + coreutils only.
# shellcheck disable=SC2016  # literal $VAR text IS the assertion — never expand
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"          # scripts/parity
SCRIPTS="$(cd "$HERE/.." && pwd)"              # scripts/
BASH_TWIN="$SCRIPTS/claude-codex"
LANES_JSON="$SCRIPTS/lanes/lanes.json"

fails=0
for f in "$BASH_TWIN" "$LANES_JSON"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: missing twin $f"
    fails=$((fails + 1))
  fi
done

check() {  # check <desc> <file> <ERE>
  if grep -qE "$3" "$2" 2>/dev/null; then
    echo "ok: $1"
  else
    echo "FAIL: $1 (no line matching /$3/ in $2)"
    fails=$((fails + 1))
  fi
}

# 1. bash: MAX_CONTEXT_TOKENS exported from the VARIABLE, not a literal.
check 'claude-codex exports CLAUDE_CODE_MAX_CONTEXT_TOKENS="$CODEX_CONTEXT_WINDOW"' \
  "$BASH_TWIN" '^export CLAUDE_CODE_MAX_CONTEXT_TOKENS="\$CODEX_CONTEXT_WINDOW"'
# 3. both twins still feed AUTO_COMPACT_WINDOW from the SAME variable.
check 'claude-codex exports CLAUDE_CODE_AUTO_COMPACT_WINDOW="$CODEX_CONTEXT_WINDOW"' \
  "$BASH_TWIN" '^export CLAUDE_CODE_AUTO_COMPACT_WINDOW="\$CODEX_CONTEXT_WINDOW"'

# 5. The per-dispatch effort default is `xhigh` (decision 223: gpt-6.1-sol at
#    xhigh; `low` stays the first lever for mechanical chunks), in the launcher
#    and in the lanes.json prose that documents it. Still overridable: the bash
#    default stays the `${VAR:-x}` form.
check 'claude-codex defaults CLAUDE_CODE_EFFORT_LEVEL to xhigh (overridable)' \
  "$BASH_TWIN" '^export CLAUDE_CODE_EFFORT_LEVEL="\$\{CLAUDE_CODE_EFFORT_LEVEL:-xhigh\}"'
last_effort_export=$(grep -E '^export CLAUDE_CODE_EFFORT_LEVEL=' "$BASH_TWIN" | tail -n 1)
if [ "$last_effort_export" = 'export CLAUDE_CODE_EFFORT_LEVEL="${CLAUDE_CODE_EFFORT_LEVEL:-xhigh}"' ]; then
  echo "ok: the last CLAUDE_CODE_EFFORT_LEVEL export in claude-codex is the xhigh default"
else
  echo "FAIL: the last CLAUDE_CODE_EFFORT_LEVEL export in claude-codex is not the xhigh default (got: $last_effort_export)"
  fails=$((fails + 1))
fi
check 'lanes.json claudex row says the launcher defaults effort to xhigh' \
  "$LANES_JSON" 'launcher defaults effort to xhigh'
for stale in high medium; do
  if grep -qE "launcher defaults effort to $stale" "$LANES_JSON" 2>/dev/null; then
    echo "FAIL: lanes.json still says the launcher defaults effort to $stale"
    fails=$((fails + 1))
  else
    echo "ok: lanes.json no longer claims a $stale launcher default"
  fi
done

echo
if [ "$fails" -eq 0 ]; then
  echo "ALL PASS"
  exit 0
fi
echo "context-env parity FAILED"
exit 1
