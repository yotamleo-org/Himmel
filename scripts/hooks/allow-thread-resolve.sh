#!/usr/bin/env bash
# PreToolUse Bash allow for the one audited review-thread resolve call.
#
# A leg that answered a review thread resolves it with
#
#   node <primary>/plugins/himmel-gh/lib/thread-resolve-action-cli.mjs \
#     --owner yotamleo-org --repo Himmel --number <digits> \
#     --thread-id PRRT_<base64url> --reason "<fixed <sha> | followup <KEY-n> | rejected <text>>"
#
# The auto-mode classifier sometimes denied that call as an external write, at
# random, and the denied resolve stalled the PR. This hook allows exactly that
# shape as ONE literal command so the classifier never sees it: no chaining, no
# redirect, no substitution, no extra flag, our owner and repo only, a PRRT_ thread id, and a CLI path that is the
# PRIMARY checkout's copy of the repo THIS HOOK lives in (git's answer about the
# hook's own directory, never the payload's cwd, which any repo can be), not a
# branch copy whose bytes a branch controls. Any other command gets no decision (silent exit 0),
# so the permission layer decides as before. The CLI posts its reason on GitHub
# before it resolves, so every resolve stays auditable.
#
# It sits in the Bash chain, where a deny from any other member still wins
# (the chain only merges allow decisions after every member has run).
#
# FAILURE DIRECTION: FAIL OPEN to "no decision" - this hook can only ADD an
# allow for the one shape, so a missing jq or git, an unreadable payload or a
# hook dir outside a git checkout leaves the call to the permission layer. The shape check is
# this file's text scan; the test table in test-allow-thread-resolve.sh holds
# the same rows.
set -uo pipefail
set -f

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 0
# shellcheck source=../lib/git-clean.sh
# shellcheck disable=SC1091
[ -r "$SCRIPT_DIR/../lib/git-clean.sh" ] && . "$SCRIPT_DIR/../lib/git-clean.sh" || exit 0
git_env_scrub

command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

input=$(cat 2>/dev/null) || exit 0  # swallow-ok: fail-open allow hook, no decision on error
[ -n "$input" ] || exit 0

tool=$(jq -r '.tool_name // "Bash"' <<<"$input" 2>/dev/null) || exit 0  # swallow-ok: fail-open allow hook, no decision on error
[ "$tool" = Bash ] || exit 0
cmd=$(jq -r '.tool_input.command // ""' <<<"$input" 2>/dev/null) || exit 0  # swallow-ok: fail-open allow hook, no decision on error
[ -n "$cmd" ] || exit 0

LC_ALL=C
case "$cmd" in *$'\n'*|*$'\r'*|*..*) exit 0 ;; esac

SHA='[0-9a-f]{7,40}'
KEY='[A-Z][A-Z0-9]*-[0-9]+'
WHY='[A-Za-z0-9.,:_/#-][A-Za-z0-9 .,:_/#-]{0,199}'
RE='^node (/[A-Za-z0-9._/+@-]+)/plugins/himmel-gh/lib/thread-resolve-action-cli\.mjs'
RE="$RE --owner yotamleo-org --repo Himmel --number [0-9]+ --thread-id PRRT_[A-Za-z0-9_-]+"
RE="$RE --reason \"(fixed $SHA|followup $KEY|rejected $WHY)\"\$"
[[ "$cmd" =~ $RE ]] || exit 0
root="${BASH_REMATCH[1]}"

common=$(git -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 0  # swallow-ok: fail-open allow hook, no decision on error
case "$common" in /*/.git) ;; *) exit 0 ;; esac
[ "$root" = "${common%/.git}" ] || exit 0

reason=$(jq -n --arg r "allow-thread-resolve: the audited thread-resolve call (one literal command, primary checkout CLI)" '$r' 2>/dev/null) || exit 0  # swallow-ok: fail-open allow hook, no decision on error
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":%s}}\n' "$reason"
exit 0
