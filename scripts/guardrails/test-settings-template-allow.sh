#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEMPLATE="$ROOT/docs/setup/settings-template.json"
fail=0

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq not installed, cannot assert the template"; exit 1; }

for rule in \
  'Bash(bash <himmel-path>/scripts/handover/merge-on-green.sh:*)' \
  'Bash(bash <himmel-path>/scripts/handover/chief-kit/append-results.sh:*)' \
  'Bash(bash <himmel-path>/scripts/lib/qmd-bounded.sh:*)'; do
  if jq -e --arg r "$rule" '.permissions.allow | index($r) != null' "$TEMPLATE" >/dev/null 2>&1; then
    echo "PASS: template allow list carries $rule"
  else
    echo "FAIL: template allow list is missing $rule"
    fail=1
  fi
done

if jq -e '(.permissions.allow // []) | length == 3' "$TEMPLATE" >/dev/null 2>&1; then
  echo "PASS: template allow list carries exactly the three rules"
else
  echo "FAIL: template allow list is not exactly the three rules (go.sh, write-verdict.sh, merge-fork-pr.sh, send-file, kill, crontab and VBoxManage stay refused)"
  fail=1
fi

if jq -e '(.autoMode.environment // []) | length > 0 and all(.[]; type == "string")' "$TEMPLATE" >/dev/null 2>&1; then
  echo "PASS: template autoMode.environment carries string entries"
else
  echo "FAIL: template autoMode.environment is missing or not strings"
  fail=1
fi

if jq -e '(.autoMode.environment // []) | any(.[]; test("merge-on-green\\.sh") and test("append-results\\.sh") and test("qmd-bounded\\.sh") and test("never covers writing an approval \\(go\\.sh, write-verdict\\.sh\\), lifting a guard or a bypass flag, or launching a bypass session")) and all(.[]; (test("scripts, run from") | not))' "$TEMPLATE" >/dev/null 2>&1; then
  echo "PASS: template autoMode.environment names the three scripts and excludes approvals and bypasses"
else
  echo "FAIL: template autoMode.environment trusts scripts broadly or leaves approvals and bypasses unexcluded"
  fail=1
fi

if jq -e '(.autoMode.allow // []) | length == 1 and (.[0] | test("merge-on-green\\.sh"))' "$TEMPLATE" >/dev/null 2>&1; then
  echo "PASS: template autoMode.allow carries the one merge-on-green.sh entry"
else
  echo "FAIL: template autoMode.allow is not the one merge-on-green.sh entry"
  fail=1
fi

if jq -e '(.autoMode // {}) | has("soft_deny") or has("hard_deny")' "$TEMPLATE" >/dev/null 2>&1; then
  echo "FAIL: template autoMode overrides soft_deny or hard_deny"
  fail=1
else
  echo "PASS: template autoMode leaves soft_deny and hard_deny alone"
fi

exit "$fail"
