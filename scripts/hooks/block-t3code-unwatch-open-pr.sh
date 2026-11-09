#!/usr/bin/env bash
# PreToolUse hook (mcp__t3-code__unwatch_pull_request).
# Refuse unwatching a PR while it is still OPEN.
#
# WHY: T3 Code's wake text pairs "all required checks passed" with "call
# unwatch_pull_request first". Seen 2026-11-09 (PR 5054): the agent unwatched an
# OPEN, mergeStateStatus=BLOCKED PR with no review decision, nothing watched it
# afterwards and the operator re-armed the watch by hand. Second drift goes to a
# hook, not stronger prose.
#
# Reads the live PR with `gh pr view` (state, mergeStateStatus, reviewDecision):
#   OPEN             -> deny (exit 2); the reason names the live state and the override
#   MERGED / CLOSED  -> allow (exit 0, prints nothing)
#
# Hook input: JSON on stdin. The PR comes from tool_input: a github.com/o/r/pull/N
# URL in any string field, else a number field plus an optional repo field.
#
# Fail OPEN (exit 0) with a loud stderr WARNING when the PR cannot be resolved
# or read (no jq, bad JSON, gh error, unparseable gh output): this is a workflow
# nudge, never a trap the agent cannot leave.
#
# Override for an operator-directed stop: T3CODE_UNWATCH_OK=1 in the shell that
# LAUNCHED the agent (a per-call prefix does not reach the hook). The allow is
# logged to stderr and appended to $HOME/.himmel/t3code-unwatch-override.log.
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

# Resolve repo + number: URL in any string field first, else number/repo fields.
strings=$(jq -r '[.tool_input | .. | strings] | join("\n")' <<<"$input") || strings=""
repo=""; num=""
url=$(printf '%s\n' "$strings" | grep -Eo 'github\.com/[^/[:space:]]+/[^/[:space:]]+/pull/[0-9]+' | head -n 1)
if [ -n "$url" ]; then
    repo=${url#github.com/}; repo=${repo%%/pull/*}
    num=${url##*/}
else
    num=$(jq -r '.tool_input | (.number // .prNumber // .pullRequestNumber // .pr // .pullRequest // "") | tostring' <<<"$input")
    repo=$(jq -r '.tool_input | (.repo // .repository // "") | tostring' <<<"$input")
    case "$repo" in */*) ;; *) repo="" ;; esac
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
    { mkdir -p "$HOME/.himmel" && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $msg" >> "$HOME/.himmel/t3code-unwatch-override.log"; } 2>/dev/null || true  # swallow-ok: the override log is best effort, the stderr line already recorded it
    exit 0
fi

cat >&2 <<EOF
BLOCKED: unwatch_pull_request refused - $label is still open (state=OPEN).
  state=OPEN mergeStateStatus=$merge_state reviewDecision=${review:-none}
"All required checks passed" is not "merged": nothing watches the PR once it is unwatched.
Keep the watch until the PR is MERGED or CLOSED.
Operator-directed stop only: relaunch the agent from a shell with T3CODE_UNWATCH_OK=1 (the allow is logged).
EOF
exit 2
