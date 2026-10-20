#!/usr/bin/env bash
# the gcp-runners down and status literals the auto-mode classifier denied must
# be pre-approved in the project allow list, spelled exactly as a console types
# them. gcp-runners `up` spawns billable VMs and stays un-approved.
#
# Usage: bash scripts/guardrails/test-settings-dispatch-allow.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SETTINGS="$ROOT/.claude/settings.json"
fail=0

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq not installed, cannot assert the allow list"; exit 1; }

for rule in \
  'Bash(bash scripts/ci/gcp-runners.sh down)' \
  'Bash(bash scripts/ci/gcp-runners.sh status)'; do
  if jq -e --arg r "$rule" '.permissions.allow | index($r) != null' "$SETTINGS" >/dev/null 2>&1; then
    echo "PASS: allow list carries $rule"
  else
    echo "FAIL: allow list is missing $rule"
    fail=1
  fi
done

if jq -e '.permissions.allow | map(select(test("gcp-runners\\.sh") and . != "Bash(bash scripts/ci/gcp-runners.sh down)" and . != "Bash(bash scripts/ci/gcp-runners.sh status)")) | length > 0' "$SETTINGS" >/dev/null 2>&1; then
  echo "FAIL: allow list carries a gcp-runners rule beyond the exact down and status literals"
  fail=1
fi

exit "$fail"
