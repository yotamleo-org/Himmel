#!/usr/bin/env bash
# scripts/ci/test-workflow-red-workflow.sh -- shape guard for
# .github/workflows/workflow-red.yml: the reporter that runs
# scripts/ci/workflow-red-issue.sh after each completed run of a tracked
# workflow. Text assertions over the workflow with comments stripped; no network.
#
# It pins what makes the reporter safe and complete: the trigger names exactly
# the workflows in workflow-red-list.txt (each a real workflow `name:`, CI not
# among them), completed runs only, pull_request runs gated out, issues: write
# without any write to code, the default-branch checkout, serialised without
# cancelling, and the script run with the run id.
#
# ponytail: line-oriented text checks, not a YAML parse, upgrade to a real parser
# if the repo ever vendors one for workflows (as test-main-sweep-red-workflow.sh).
#
# Usage: bash scripts/ci/test-workflow-red-workflow.sh
# Env:   WORKFLOW_RED_YML  workflow under test (default: the tracked file).
# Exit codes: 0 -- all cases passed; 1 -- at least one failed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WF="${WORKFLOW_RED_YML:-$ROOT/.github/workflows/workflow-red.yml}"
LIST="$ROOT/scripts/ci/workflow-red-list.txt"
WFDIR="$ROOT/.github/workflows"
fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

if [ ! -f "$WF" ]; then
  bad "workflow file missing: $WF"
  echo "$fails check(s) failed." >&2
  exit 1
fi

s="$(sed -e '/^[[:space:]]*#/d' -e 's/[[:space:]][[:space:]]*#.*$//' "$WF")"
has() { grep -Eq -- "$1" <<< "$s"; }

# The trigger list == the data file, name for name.
trig="$(sed -n 's/^[[:space:]]*workflows: \[\(.*\)\][[:space:]]*$/\1/p' <<< "$s" | head -n 1 | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' | sort)"
listed="$(sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$LIST" | sort)"
if [ -n "$trig" ] && [ "$trig" = "$listed" ]; then
  ok "workflow_run trigger names exactly the workflows in workflow-red-list.txt"
else
  bad "trigger list differs from workflow-red-list.txt; trigger: $trig; list: $listed"
fi

# Every listed name is a real workflow, and CI is not one of them.
while IFS= read -r name; do
  [ -n "$name" ] || continue
  if grep -Eqx "name: \"?$(printf '%s' "$name" | sed 's/[][()\.*^$+?|{}]/\\&/g')\"?" "$WFDIR"/*.yml; then
    ok "'$name' is a real workflow name"
  else
    bad "'$name' matches no workflow's name:"
  fi
done <<< "$listed"
ci_name="$(sed -n 's/^name:[[:space:]]*//p' "$WFDIR/ci.yml" | head -n 1)"
if grep -Fxq "$ci_name" <<< "$listed"; then bad "CI must stay out of the list (main-sweep-red.yml owns it)"; else ok "CI is not tracked here (main-red keeps it)"; fi

if has '^[[:space:]]+types: \[completed\]'; then ok "fires on completed runs only"; else bad "types must be [completed]"; fi
if has "github.event.workflow_run.event != 'pull_request'"; then ok "job is gated off pull_request runs"; else bad "job must skip pull_request runs"; fi

perms="$(awk '/^permissions:/ {f=1; next} f && /^[a-z]/ {f=0} f' <<< "$s")"
if grep -Eq 'issues: write' <<< "$perms" && grep -Eq 'contents: read' <<< "$perms" \
   && ! grep -Eq 'contents: write|pull-requests: write|actions: write' <<< "$perms"; then
  ok "permissions: issues write, contents read, no code write"
else
  bad "permissions must be issues: write + contents: read only"
fi

if has 'uses: actions/checkout@' && ! has 'ref:' && ! has 'head_sha'; then
  ok "checks out the default branch, never the triggering sha"
else
  bad "checkout must take no ref / head_sha"
fi
if has 'group: workflow-red-.*workflow_run\.name.*workflow_run\.head_branch'; then ok "concurrency group is per workflow and branch (no cross-drop of pending reports)"; else bad "concurrency group must include workflow_run.name and head_branch"; fi
if has 'cancel-in-progress: false'; then ok "reports serialise without cancelling"; else bad "concurrency must not cancel in progress"; fi
if has 'scripts/ci/workflow-red-issue\.sh "\$\{\{ github\.event\.workflow_run\.id \}\}"'; then ok "runs the script with the run id"; else bad "must run workflow-red-issue.sh with the run id"; fi

echo
if [ "$fails" -ne 0 ]; then echo "$fails check(s) failed." >&2; exit 1; fi
echo "all passed."
