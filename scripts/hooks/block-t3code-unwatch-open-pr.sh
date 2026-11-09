#!/usr/bin/env bash
# PreToolUse hook (mcp__t3-code__unwatch_pull_request): deny while the PR is OPEN.
# Fails OPEN with a stderr WARNING when the PR cannot be resolved or read: a
# nudge must never trap the agent in a watch it cannot leave.
# Override: T3CODE_UNWATCH_OK=1 in the launching shell (a per-call prefix does
# not reach the hook); the allow is printed to stderr.
set -uo pipefail

warn() { echo "block-t3code-unwatch-open-pr: WARNING: $* - allowing the unwatch (fail open)" >&2; }

command -v jq >/dev/null 2>&1 || { warn "jq missing"; exit 0; }

input=""
IFS= read -r -d '' input 2>/dev/null || true  # swallow-ok: read -d '' returns 1 at EOF by design

tool=$(jq -r '.tool_name // ""' <<<"$input") || { warn "hook input is not JSON"; exit 0; }
case "$tool" in
    *unwatch_pull_request) ;;
    *) exit 0 ;;
esac

strings=$(jq -r '[.tool_input | .. | strings] | join("\n")' <<<"$input") || strings=""
repo=""; num=""
url=$(printf '%s\n' "$strings" | grep -Eo 'github\.com/[^/[:space:]]+/[^/[:space:]]+/pull/[0-9]+' | head -n 1)
if [ -n "$url" ]; then
    repo=${url%%/pull/*}
    num=${url##*/}
else
    num=$(jq -r '.tool_input | (.number // .prNumber // .pullRequestNumber // .pr // .pullRequest // "") | tostring' <<<"$input")
    repo=$(jq -r '.tool_input | (.repo // .repository // "") | tostring' <<<"$input")
    owner=$(jq -r '.tool_input | (.owner // "") | tostring' <<<"$input")
    case "$repo" in
        */*) ;;
        '') ;;
        *) if [ -n "$owner" ]; then repo="$owner/$repo"; else repo=""; fi ;;
    esac
fi
case "$num" in
    ''|*[!0-9]*) warn "no PR number in tool_input"; exit 0 ;;
esac

if [ -n "$repo" ]; then
    view=$(gh pr view "$num" --repo "$repo" --json state,mergeStateStatus,reviewDecision 2>/dev/null)  # swallow-ok: rc is checked right below and warns
else
    view=$(gh pr view "$num" --json state,mergeStateStatus,reviewDecision 2>/dev/null)  # swallow-ok: rc is checked right below and warns
fi
rc=$?
if [ "$rc" != 0 ]; then warn "gh pr view $num failed (rc=$rc)"; exit 0; fi

state=$(jq -r '.state // ""' <<<"$view") || state=""
if [ -z "$state" ]; then warn "gh pr view $num gave no state"; exit 0; fi
merge_state=$(jq -r '.mergeStateStatus // ""' <<<"$view")
review=$(jq -r '.reviewDecision // ""' <<<"$view")
label="PR ${repo}#$num"

case "$state" in
    OPEN) ;;
    MERGED|CLOSED) exit 0 ;;
    *) warn "gh pr view $num gave an unexpected state '$state'"; exit 0 ;;
esac

if [ "${T3CODE_UNWATCH_OK:-0}" = "1" ]; then
    msg="$label unwatched while state=OPEN mergeStateStatus=$merge_state reviewDecision=${review:-none} (T3CODE_UNWATCH_OK=1)"
    echo "block-t3code-unwatch-open-pr: override: $msg" >&2
    exit 0
fi

cat >&2 <<EOF
BLOCKED: unwatch_pull_request refused - $label is still open (state=OPEN).
  state=OPEN mergeStateStatus=$merge_state reviewDecision=${review:-none}
"All required checks passed" is not "merged": nothing watches the PR once it is unwatched.
Keep the watch until the PR is MERGED or CLOSED.
Operator-directed stop only: relaunch the agent from a shell with T3CODE_UNWATCH_OK=1 (the allow is printed to stderr).
EOF
exit 2
