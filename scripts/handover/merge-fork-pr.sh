#!/usr/bin/env bash
# scripts/handover/merge-fork-pr.sh - the chief's one way to merge a PR on a
# himmel adapter (a fork we own, scripts/guardrails/himmel-adapters.json).
#
# Usage: merge-fork-pr.sh [--jira-transition] <owner/repo> <pr-number> <full-40-hex-head-sha>
#
# --jira-transition (the brief's completes-ticket: yes) moves the first [KEY] of the PR
# title to Done after the merge lands, as merge-on-green.sh --jira-transition does, and
# prints one `jira-transition=<result>` line; without it the ticket is left alone.
#
# Chief only: refuses (exit 3) from a chief-spawned worker or a chief relay,
# like go.sh. Merges only on the trust-reviewed GO that go.sh --repo wrote for
# THIS repo, PR and head (the mac signs all three, plus the judge's qid), then
# re-reads the live PR and runs
#     gh pr merge <pr> --repo <nwo> --squash --match-head-commit <head>
# The bare form stays refused by block-unresolved-cr-merge.sh (it merges only
# into the project repo), so this script is the single path to a fork.
#
# Exit codes:
#   0  merged
#   1  handover root unresolvable, or scripts/lib/go-gate.sh failed to load
#   2  usage
#   3  refused: run from a chief-spawned worker or a chief relay
#   6  refused: <owner/repo> is not an allowlisted himmel adapter (merge_allowed)
#   7  refused: the live PR is not OPEN at <head> on the adapter's himmel_branch,
#      is not CLEAN (checks green) with every review thread resolved, or the
#      merge itself failed
#   8  refused: no valid trust-reviewed GO for this repo, PR and head
#
# Platform guard (gitbash-only): POSIX bash 3.2+, same as go.sh.
set -u
# a relative-entry copy that is not the anchor's hands off to it
# (the same one-hop, fail-closed pattern go.sh uses).
case "${BASH_SOURCE[0]}" in */*) _ah_d="${BASH_SOURCE[0]%/*}" ;; *) _ah_d=. ;; esac
. "$_ah_d/../cr/anchor-handoff.sh" || exit 2
case "${BASH_SOURCE[0]}" in */*) _csg_dir="${BASH_SOURCE[0]%/*}" ;; *) _csg_dir=. ;; esac
# refuse a chokepoint seam that differs from the session's launch env.
_csg_lib="$_csg_dir/../lib/chokepoint-seam-guard.sh"
# shellcheck source=scripts/lib/chokepoint-seam-guard.sh
# shellcheck disable=SC1091
if ! { [ -r "$_csg_lib" ] && . "$_csg_lib"; }; then
    echo "merge-fork-pr.sh: cannot load $_csg_lib - refusing" >&2
    exit 96
fi
chokepoint_seam_guard scripts/handover/merge-fork-pr.sh || exit 96

usage() { echo "usage: merge-fork-pr.sh [--jira-transition] <owner/repo> <pr-number> <full-40-hex-head-sha>" >&2; }

JIRA_TRANSITION=0
if [ "${1:-}" = "--jira-transition" ]; then JIRA_TRANSITION=1; shift; fi
if [ "$#" -ne 3 ]; then usage; exit 2; fi
NWO="$1"; PR="$2"; SHA="$3"
case "$NWO" in
    */*/*|/*|*/|*[!A-Za-z0-9._/-]*|'') usage; echo "merge-fork-pr: '$NWO' is not an owner/name" >&2; exit 2 ;;
    */*) ;;
    *) usage; echo "merge-fork-pr: '$NWO' is not an owner/name" >&2; exit 2 ;;
esac
case "$PR" in
    ''|0*|*[!0123456789]*) usage; echo "merge-fork-pr: pr-number must be digits without a leading zero (got '$PR')" >&2; exit 2 ;;
esac
case "$SHA" in
    *[!0123456789abcdef]*) usage; echo "merge-fork-pr: head sha must be the full 40-char lowercase hex sha (got '$SHA')" >&2; exit 2 ;;
esac
[ "${#SHA}" -eq 40 ] || { usage; echo "merge-fork-pr: head sha must be the full 40-char lowercase hex sha (got '$SHA')" >&2; exit 2; }

HERE="$(cd "$(dirname "$0")" && pwd)"
# Fail closed: a broken shared lib must never read as "not a worker".
# shellcheck source=scripts/lib/go-gate.sh
# shellcheck disable=SC1091
if ! . "$HERE/../lib/go-gate.sh" 2>/dev/null || ! declare -F chief_worker >/dev/null 2>&1 \
        || ! declare -F go_trust_gate >/dev/null 2>&1 || ! declare -F go_adapter_entry >/dev/null 2>&1 \
        || ! declare -F go_resolve_root >/dev/null 2>&1 || ! declare -F go_fork_ready >/dev/null 2>&1; then
    echo "merge-fork-pr: cannot load scripts/lib/go-gate.sh - refusing" >&2
    exit 1
fi
if chief_worker; then
    echo "merge-fork-pr: refusing - this is a chief-spawned worker (HIMMEL_CONSOLE_LEG is set); only the chief merges a fork PR. Send READY to your chief." >&2
    exit 3
fi
case "$(printf '%s' "${HIMMEL_CONSOLE_RELAY:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
    ''|0|false|off|no) ;;
    *)
        echo "merge-fork-pr: refusing - this is a chief relay (HIMMEL_CONSOLE_RELAY is set); only the chief merges a fork PR." >&2
        exit 3 ;;
esac

# shellcheck source=scripts/lib/handover-path.sh
# shellcheck disable=SC1091
if ! . "$HERE/../lib/handover-path.sh"; then
    echo "merge-fork-pr: cannot load scripts/lib/handover-path.sh" >&2
    exit 1
fi
ANCHOR="$(cd "$HERE/../.." && pwd)"
if ! ROOT=$(go_resolve_root "$ANCHOR"); then
    echo "merge-fork-pr: cannot resolve the handover root the GO was written under - nothing merged" >&2
    exit 1
fi

if ! HBRANCH=$(go_adapter_entry "$ANCHOR" "$NWO"); then
    echo "merge-fork-pr: refusing $NWO PR #$PR - $HBRANCH" >&2
    exit 6
fi
if ! REASON=$(go_trust_gate "$PR" "$SHA" "$ROOT" "$NWO"); then
    echo "merge-fork-pr: refusing $NWO PR #$PR at $SHA - $REASON (the chief writes it with go.sh --repo $NWO --trust-reviewed <judge-qid> $PR $SHA)" >&2
    exit 8
fi

# The live PR must still be what the GO certified; --match-head-commit below
# pins the same head at merge time.
VIEW=$(gh pr view "$PR" --repo "$NWO" --json state,headRefOid,baseRefName 2>/dev/null) || VIEW=""
LIVE=$(printf '%s' "$VIEW" | jq -r '"\(.state)|\(.headRefOid)|\(.baseRefName)"' 2>/dev/null) || LIVE=""
if [ "$LIVE" != "OPEN|$SHA|$HBRANCH" ]; then
    echo "merge-fork-pr: refusing $NWO PR #$PR - it must be OPEN at $SHA on $HBRANCH (state|head|base read: '$LIVE'); a push after the GO needs a fresh GO. Nothing merged." >&2
    exit 7
fi
if ! REASON=$(go_fork_ready "$NWO" "$PR"); then
    echo "merge-fork-pr: refusing $NWO PR #$PR - $REASON Nothing merged." >&2
    exit 7
fi

if ! gh pr merge "$PR" --repo "$NWO" --squash --match-head-commit "$SHA"; then
    echo "merge-fork-pr: gh pr merge failed for $NWO PR #$PR at $SHA" >&2
    exit 7
fi
# gh can enqueue or arm auto-merge without merging, and a retarget between the
# read above and the merge is not constrained by --match-head-commit: report
# only what the fork now says happened.
VIEW=$(gh pr view "$PR" --repo "$NWO" --json state,baseRefName 2>/dev/null) || VIEW=""
DONE=$(printf '%s' "$VIEW" | jq -r '"\(.state)|\(.baseRefName)"' 2>/dev/null) || DONE=""
if [ "$DONE" != "MERGED|$HBRANCH" ]; then
    echo "merge-fork-pr: $NWO PR #$PR is not confirmed MERGED into $HBRANCH after gh pr merge (state|base read: '$DONE') - check the fork now" >&2
    exit 7
fi
echo "merge-fork-pr: merged $NWO PR #$PR at $SHA into $HBRANCH"

# --jira-transition: the chief's per-merge opt-in (the brief's completes-ticket: yes), as
# merge-on-green.sh's flag. Best-effort and last: the merge has landed, so no outcome here
# changes the exit code. Same steps and CLI as merge-on-green.sh's _jira_close_on_merge:
# an Epic is never touched, the comment goes first, the target status is reconcile-config's.
# ponytail: skips that function's per-key status flock and fixVersion fold, upgrade path =
# lift _jira_close_on_merge into scripts/lib/ so both merge paths call one copy.
[ "$JIRA_TRANSITION" -eq 1 ] || exit 0
jira_result() { echo "merge-fork-pr: jira-transition=$*"; exit 0; }
jira() { ( cd "$ANCHOR" && node scripts/jira/dist/index.js "$@" ); }
# shellcheck source=scripts/lib/ticket-status.sh
# shellcheck disable=SC1091
if ! . "$HERE/../lib/ticket-status.sh" 2>/dev/null || ! declare -F ticket_key_from_title >/dev/null 2>&1; then
    jira_result "skip=no-ticket-lib"
fi
TITLE=$(gh pr view "$PR" --repo "$NWO" --json title 2>/dev/null | jq -r '.title // empty' 2>/dev/null) || TITLE=""  # swallow-ok: an unread title is skip=no-title, after the merge landed
[ -n "$TITLE" ] || jira_result "skip=no-title"
KEY=$(ticket_key_from_title "$TITLE") || KEY=""
[ -n "$KEY" ] || jira_result "skip=no-ticket-tag"
TARGET=$(jq -r --arg p "${KEY%-*}" '.[$p].targetStatus // empty' "$ANCHOR/scripts/jira/reconcile-config.json" 2>/dev/null) || TARGET=""  # swallow-ok: an unread config is skip=no-project-config, after the merge landed
[ -n "$TARGET" ] || jira_result "skip=no-project-config key=$KEY project=${KEY%-*}"
[ -f "$ANCHOR/scripts/jira/dist/index.js" ] || jira_result "skip=no-jira-cli-build key=$KEY"
ITYPE=$(jira get "$KEY" --json 2>/dev/null | jq -r '.fields.issuetype.name // empty' 2>/dev/null) || ITYPE=""  # swallow-ok: an unread type is skip=cannot-verify-type, never a transition
case "$ITYPE" in
    Epic) jira_result "skip=never-touch-type key=$KEY type=$ITYPE" ;;
    "") jira_result "skip=cannot-verify-type key=$KEY" ;;
esac
CFILE=$(mktemp "${TMPDIR:-/tmp}/merge-fork-pr-jira-comment.XXXXXX") || jira_result "skip=no-tmpfile key=$KEY"
printf 'PR #%s (%s) merged @ %s. scripts/handover/merge-fork-pr.sh is attempting to auto-transition this ticket to '"'"'%s'"'"'.\n' \
    "$PR" "$NWO" "$SHA" "$TARGET" > "$CFILE"
CRC=0; jira comment "$KEY" --comment-file "$CFILE" >/dev/null 2>&1 || CRC=$?
rm -f "$CFILE"
# No breadcrumb on the ticket, no silent close.
[ "$CRC" -eq 0 ] || jira_result "skip=comment-failed key=$KEY rc=$CRC"
TRC=0; TOUT=$(jira transition "$KEY" "$TARGET" 2>&1) || TRC=$?
# Exit 3: the ticket closed, but the transition would not stamp a frozen version it was deferred out of.
if [ "$TRC" -eq 0 ] || [ "$TRC" -eq 3 ]; then
    jira_result "ok key=$KEY status=$TARGET"
fi
jira_result "failed key=$KEY status=$TARGET rc=$TRC out=${TOUT//$'\n'/ }"
