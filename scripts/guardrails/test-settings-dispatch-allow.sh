#!/usr/bin/env bash
# the console dispatch literals the auto-mode classifier denied (console-wait,
# write-verdict, gcp-runners down|status) must be pre-approved in the project
# allow list, spelled exactly as a console types them. gcp-runners `up` spawns
# billable VMs and stays un-approved.
#
# Usage: bash scripts/guardrails/test-settings-dispatch-allow.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SETTINGS="$ROOT/.claude/settings.json"
fail=0

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq not installed, cannot assert the allow list"; exit 1; }

for rule in \
  'Bash(bash scripts/handover/console-kit/console-wait.sh:*)' \
  'Bash(bash scripts/handover/console-kit/write-verdict.sh:*)' \
  'Bash(bash scripts/ci/gcp-runners.sh down)' \
  'Bash(bash scripts/ci/gcp-runners.sh status)'; do
  if jq -e --arg r "$rule" '.permissions.allow | index($r) != null' "$SETTINGS" >/dev/null 2>&1; then
    echo "PASS: allow list carries $rule"
  else
    echo "FAIL: allow list is missing $rule"
    fail=1
  fi
done

if jq -e '.permissions.allow | map(select(test("gcp-runners\\.sh( (up|watch)|:\\*)"))) | length > 0' "$SETTINGS" >/dev/null 2>&1; then
  echo "FAIL: allow list pre-approves a gcp-runners subcommand that spawns VMs"
  fail=1
fi

exit "$fail"
