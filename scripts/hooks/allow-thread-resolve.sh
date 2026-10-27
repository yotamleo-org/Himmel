#!/usr/bin/env bash
# PreToolUse Bash allow for the one audited review-thread resolve call.
#
# A worker that answered a review thread resolves it with
#
#   node <primary>/plugins/himmel-gh/lib/thread-resolve-action-cli.mjs \
#     --owner yotamleo-org --repo Himmel --number <digits> \
#     --thread-id PRRT_<base64url> --reason "<fixed <sha> | followup <KEY-n> | rejected <text>>"
#
# --repo may also be any nwo in the primary checkout's
# scripts/guardrails/himmel-adapters.json (an adopter repo's worker resolves its
# own threads), read only for a command that already has the resolve shape.
#
# The auto-mode classifier sometimes denied that call as an external write, at
# random, and the denied resolve stalled the PR. This hook allows exactly that
# shape as ONE literal command so the classifier never sees it: no chaining, no
# redirect, no substitution, no extra flag, our owner and a registered repo only, a PRRT_
# thread id, a reason in double or single quotes, and a CLI path that is the
# PRIMARY checkout named by $HIMMEL_REPO (operator-set, resolved with cd -P,
# its own .git directory, on refs/heads/main), whose CLI is a regular file
# holding refs/heads/main's bytes. Nothing a branch controls - the payload's
# cwd, the hook's own directory, a worktree's .git pointer file - is the
# anchor. The CLI posts its reason on GitHub before it resolves, so every
# resolve stays auditable.
#
# Two near misses get a DENY that names the fix, so the worker retries once
# instead of reaching the classifier, and only when the anchor
# holds, so the corrected call is one this hook allows:
#   - the right call with the CLI spelled relative, by $CLAUDE_PROJECT_DIR, or
#     by a linked worktree root of $HIMMEL_REPO: the deny carries the exact
#     corrected one-line command;
#   - the right shape with a quoted reason outside the grammar (e.g.
#     "disproved: ..."), which the CLI refuses anyway: the deny names the
#     accepted forms.
# Any other command gets no decision (silent exit 0), so the permission layer
# decides as before.
#
# It sits in the Bash chain, where a deny from any other member still wins
# (the chain only merges allow decisions after every member has run).
#
# FAILURE DIRECTION: FAIL OPEN to "no decision" - this hook can only ADD an
# allow for the one shape (or a deny naming it), so a missing jq or git, an
# unreadable payload or an unanchored $HIMMEL_REPO leaves the call to the
# permission layer. The shape check is this file's text scan; the test table in
# test-allow-thread-resolve.sh holds the same rows.
set -uo pipefail
set -f

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/git-clean.sh
# shellcheck disable=SC1091
{ [ -r "$SCRIPT_DIR/../lib/git-clean.sh" ] && . "$SCRIPT_DIR/../lib/git-clean.sh"; } 2>/dev/null || exit 0  # swallow-ok: fail-open allow hook, no decision on error
git_env_scrub

command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

input=''
IFS= read -r -d '' input 2>/dev/null || true  # swallow-ok: read -d '' ends at EOF with rc 1, and fd 0 closed must not hang
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
GRAMMAR="^(fixed $SHA|followup $KEY|rejected $WHY)\$"
REL='plugins/himmel-gh/lib/thread-resolve-action-cli.mjs'
TAIL='--owner ([A-Za-z0-9._-]+) --repo ([A-Za-z0-9._-]+) --number [0-9]+ --thread-id PRRT_[A-Za-z0-9_-]+'
# CLI spelling: absolute | $CLAUDE_PROJECT_DIR | ${CLAUDE_PROJECT_DIR} | ./ | bare relative.
# Reason: one double-quoted literal (no " \ $ `) or one single-quoted literal (no ').
# shellcheck disable=SC2016  # literal $ and backtick are regex text
RE='^node (/[A-Za-z0-9._/+@-]+/|[$]CLAUDE_PROJECT_DIR/|[$][{]CLAUDE_PROJECT_DIR[}]/|[.]/)?plugins/himmel-gh/lib/thread-resolve-action-cli\.mjs ('"$TAIL"') --reason ("[^"\$`]+"|'"'[^']+'"')$'
[[ "$cmd" =~ $RE ]] || exit 0
spelled="${BASH_REMATCH[1]}"
tail="${BASH_REMATCH[2]}"
nwo="${BASH_REMATCH[3]}/${BASH_REMATCH[4]}"
quoted="${BASH_REMATCH[5]}"
reason="${quoted#?}"; reason="${reason%?}"

# our own repo, or an nwo row of the primary's adapter registry: an exact string
# compare (no regex built from registry text), and an unreadable or malformed
# registry (jq must parse all of it) leaves only himmel itself.
registered() {  # registered <owner/repo>
    [ "$1" = yotamleo-org/Himmel ] && return 0  # env-literal-ok: the one audited repo this hook always allowed
    local reg="${HIMMEL_REPO:-}" names line
    reg="${reg%/}/scripts/guardrails/himmel-adapters.json"
    case "$reg" in /*) ;; *) return 1 ;; esac
    [ -f "$reg" ] && [ ! -L "$reg" ] || return 1
    names=$(jq -r '.[].nwo | strings' "$reg" 2>/dev/null) || return 1  # swallow-ok: a failed read returns "not registered", no allow
    while IFS= read -r line; do [ "$line" = "$1" ] && return 0; done <<<"$names"
    return 1
}
registered "$nwo" || exit 0

g() { git --no-replace-objects -c core.fsmonitor=false -c core.untrackedCache=false "$@" 2>/dev/null; }
resolved() { (cd -P "$1" 2>/dev/null && pwd -P); }

# the anchor, as impacted_suites_is_anchored in auto-approve-safe-bash.sh
repo="${HIMMEL_REPO:-}"; repo="${repo%/}"
case "$repo" in /*) ;; *) exit 0 ;; esac
repo=$(resolved "$repo") || exit 0
anchor_git=$(resolved "$repo/.git") || exit 0
common=$(g -C "$repo" rev-parse --path-format=absolute --git-common-dir) || exit 0
[ "$(resolved "$common")" = "$anchor_git" ] || exit 0
[ "$(g -C "$repo" symbolic-ref -q HEAD)" = refs/heads/main ] || exit 0
[ -f "$repo/$REL" ] && [ ! -L "$repo/$REL" ] || exit 0
want=$(g -C "$repo" rev-parse --verify -q "refs/heads/main:$REL") || exit 0
[ -n "$want" ] && [ "$(g -C "$repo" hash-object --no-filters -- "$REL")" = "$want" ] || exit 0

# shellcheck disable=SC2016  # the variable names are the spelling matched, never expanded
case "$spelled" in
    ''|./|'$CLAUDE_PROJECT_DIR/'|'${CLAUDE_PROJECT_DIR}/') where=near ;;
    /*)
        root=$(resolved "${spelled%/}") || exit 0
        if [ "$root" = "$repo" ]; then
            where=primary
        else
            # a linked worktree's root of the same repo; a forged pointer here only earns a deny
            top=$(g -C "$root" rev-parse --show-toplevel) || exit 0
            [ "$(resolved "$top")" = "$root" ] || exit 0
            wcommon=$(g -C "$root" rev-parse --path-format=absolute --git-common-dir) || exit 0
            [ "$(resolved "$wcommon")" = "$anchor_git" ] || exit 0
            where=near
        fi ;;
    *) exit 0 ;;
esac

decide() {  # decide <allow|deny> <reason text>
    local why
    why=$(jq -n --arg r "$2" '$r' 2>/dev/null) || exit 0  # swallow-ok: fail-open allow hook, no decision on error
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":%s}}\n' "$1" "$why"
    exit 0
}

blocked='If that is denied too, send the chief BLOCKED resolve <pr> <thread ids> and do not retry.'
if [[ "$reason" =~ $GRAMMAR ]]; then
    [ "$where" = primary ] && decide allow "allow-thread-resolve: the audited thread-resolve call (one literal command, primary checkout CLI)"
    decide deny "allow-thread-resolve: name the resolve CLI by the primary checkout's absolute path (the value of \$HIMMEL_REPO written out), never a relative, worktree or \$CLAUDE_PROJECT_DIR path. Retry once with exactly: node $repo/$REL $tail --reason $quoted
$blocked"
fi
decide deny "allow-thread-resolve: the resolve CLI refuses this reason. --reason must be \"fixed <7-40 hex sha>\", \"followup <KEY-n>\" or \"rejected <why>\", <why> written in letters, digits, spaces and . , : _ / # - only; a disproved finding is rejected <why>. Retry once with: node $repo/$REL $tail --reason \"<one of those>\"
$blocked"
