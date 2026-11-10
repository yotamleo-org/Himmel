#!/usr/bin/env bash
# block-subagent-release-operator.sh — PreToolUse Bash chain member: denies an
# in-process subagent any Bash command that names both the word `release` and
# the word `operator`, so a subagent never writes an operator-chain row with
# `jira release operator ...` (spec-review included: a critic subagent must not
# record its own verdict). operatorFence in the jira CLI reads only the
# environment, and a subagent inherits the chief's.
#
# A security fence, so it fails CLOSED: no jq denies every call, and stdin that
# is not a JSON object is denied. `agent_id` absent or null is the main session
# (the chief) and is allowed without reading the command; any other value is a
# subagent.
#
# The match: the command is normalised (backslash-newline pairs deleted, `$'`
# and `$"` turned into `'` and `"`, then every `'`, `"` and `\` deleted), split
# into words at every space, TAB, newline and shell metacharacter, and matches
# when both words appear, anywhere and in either order. There is no allow-list,
# no simple-command split and no order check; a subagent searching for the
# phrase uses the Grep tool. What it cannot see (text built at run time, a
# nested claude session, a chief in another repo, the Monitor tool) is the
# fence residual named in docs/internals/enforcement.md.
#
# Bypass (set in the shell that launched Claude Code; session-sticky, a per-call
# prefix does not reach the hook): SUBAGENT_RELEASE_OPERATOR_GUARD_DISABLE=1
set -uo pipefail
# shellcheck disable=SC2154 # rc is assigned inside the trap string.
trap 'rc=$?;if [ "$rc" != 0 ] && [ "$rc" != 2 ]; then exit 2; fi' EXIT

deny() {
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
    printf '%s\n' "$1" >&2
    exit 2
}

BYPASS='Bypass: SUBAGENT_RELEASE_OPERATOR_GUARD_DISABLE=1 in the shell that launched Claude Code.'

[ "${SUBAGENT_RELEASE_OPERATOR_GUARD_DISABLE:-0}" = "1" ] && exit 0

command -v jq >/dev/null 2>&1 \
    || deny "block-subagent-release-operator: cannot read the hook input without jq; every Bash call is denied until jq is on PATH. $BYPASS"

# stdin is read once by the builtin, so a closed fd 0 ends at once with empty input (a $(jq) reading
# fd 0 itself would read its own output pipe, which takes the free fd 0, and hang).
input=""
IFS= read -r -d '' input 2>/dev/null || true # swallow-ok: read -d '' returns 1 at EOF on every input; empty input is the parse deny below
verdict=$(jq -r '
  if type != "object" then "parse"
  elif .agent_id == null then "allow"
  else
    ((.tool_input.command // "") | if type == "string" then . else tostring end
      | gsub("\\\\\n"; "")
      | gsub("\\$\u0027"; "\u0027") | gsub("\\$\""; "\"")
      | gsub("[\u0027\"\\\\]"; "")
      | [splits("[ \t\n;&|()<>{}`]+")]) as $w
    | if any($w[]; . == "release") and any($w[]; . == "operator") then "deny" else "allow" end
  end' <<<"$input" 2>/dev/null) || verdict=parse

case "$verdict" in
    allow) exit 0 ;;
    deny)
        deny "block-subagent-release-operator: a subagent may not run a Bash command that names both release and operator; jira release operator writes an operator-chain row, and only the main session (the chief) records one. To search for the phrase, use the Grep tool. $BYPASS" ;;
    *)
        deny "block-subagent-release-operator: cannot parse the hook input as a JSON object; the call is denied. $BYPASS" ;;
esac
