#!/usr/bin/env bash
# a chief launched with --strict-mcp-config registers qmd as
# mcp__qmd__* (not the plugin-scoped mcp__plugin_qmd_qmd__*), so the project
# allow list must pre-approve BOTH spellings of the read-only query/get tools.
#
# Usage: bash scripts/guardrails/test-settings-qmd-allow.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SETTINGS="$ROOT/.claude/settings.json"
fail=0

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq not installed, cannot assert the allow list"; exit 1; }

for tool in \
  mcp__plugin_qmd_qmd__query mcp__plugin_qmd_qmd__get \
  mcp__qmd__query mcp__qmd__get; do
  if jq -e --arg t "$tool" '.permissions.allow | index($t) != null' "$SETTINGS" >/dev/null 2>&1; then
    echo "PASS: allow list carries $tool"
  else
    echo "FAIL: allow list is missing $tool"
    fail=1
  fi
done

# status and multi_get are read-only but stay un-pre-approved: the allow list is
# scoped to query/get (least privilege). A bare server name or a wildcard
# pre-approves every tool on that server, so those are rejected too.
for tool in mcp__qmd__status mcp__qmd__multi_get 'mcp__qmd__*' \
  mcp__qmd mcp__plugin_qmd_qmd 'mcp__plugin_qmd_qmd__*'; do
  if jq -e --arg t "$tool" '.permissions.allow | index($t) != null' "$SETTINGS" >/dev/null 2>&1; then
    echo "FAIL: allow list unexpectedly carries $tool"
    fail=1
  fi
done

exit "$fail"
