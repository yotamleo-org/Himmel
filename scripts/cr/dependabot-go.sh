#!/usr/bin/env bash
# scripts/cr/dependabot-go.sh — record that a Dependabot dependency-only PR has the
# one review it can get: a signed judge GO at its exact head.
#
#   dependabot-go.sh <pr> <head-sha> --judge <qid>
#
# Nobody checks a Dependabot branch out, so review-round.sh judge-go (which needs
# the branch in the working tree and a spent round cap) cannot record it. This
# has ledger-append.sh append one `dependabot-go` row to the CR ledger; the
# merge gate (review-merge-gate.sh) and ready-check row 4 read it for that head
# and that branch only. Refused, with the ledger untouched, unless ALL hold:
#   1. the PR is open, its author is app/dependabot and its head is <head-sha>;
#   2. every file the PR changes (renames' old names included, every page, the
#      count matching changedFiles) has a manifest or lockfile NAME (allowlist
#      below; a directory never qualifies) and the list is not empty;
#   3. a judge verdict under verdicts/<qid>/ is a signed GO for <head-sha> naming
#      this PR (go_trust_verdict, the check go.sh makes for a trust-reviewed GO).
# Exit 0 recorded (or already there); 2 refused or unreadable.
#
# ponytail: the row is unsigned like a judge-go row (the ledger is same-uid
# writable, and the merge gate re-reads the PR author), upgrade: a go_msg_mac on
# the row, as cr-disposition.sh signs its rows.
#
# Platform guard (gitbash-only): POSIX bash 3.2+.
set -u

usage() { echo "usage: dependabot-go.sh <pr> <head-sha> --judge <qid>" >&2; exit 2; }

PR="${1:-}"; SHA="${2:-}"
[ "$#" -eq 4 ] && [ "${3:-}" = --judge ] || usage
QID="$4"
case "$PR" in ''|0*|*[!0123456789]*) usage ;; esac
case "$SHA" in *[!0123456789abcdef]*) usage ;; esac
[ "${#SHA}" -eq 40 ] || usage

HERE="$(cd "$(dirname "$0")" && pwd)"
ANCHOR="$(cd "$HERE/../.." && pwd)"
GH="${GH_CMD:-gh}"
refuse() { echo "dependabot-go: refused - $*" >&2; exit 2; }

# shellcheck source=scripts/lib/go-gate.sh
# shellcheck disable=SC1091
if ! . "$ANCHOR/scripts/lib/go-gate.sh" 2>/dev/null || ! declare -F go_trust_verdict >/dev/null 2>&1; then
    echo "dependabot-go: cannot load scripts/lib/go-gate.sh" >&2
    exit 2
fi
# shellcheck source=scripts/lib/git-clean.sh
# shellcheck disable=SC1091
. "$ANCHOR/scripts/lib/git-clean.sh" 2>/dev/null && git_env_scrub
common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common=""  # swallow-ok: empty fails closed on the next line
[ -n "$common" ] || { echo "dependabot-go: not in a git repo, so there is no CR ledger" >&2; exit 2; }

pr_json=$("$GH" pr view "$PR" --json author,headRefName,headRefOid,state,changedFiles 2>/dev/null) || refuse "cannot read PR #$PR"  # swallow-ok: rc is checked, an unreadable PR refuses
author=$(printf '%s' "$pr_json" | jq -r '.author.login // empty' 2>/dev/null) || author=""  # swallow-ok: empty fails the author check
[ "$author" = app/dependabot ] || refuse "PR #$PR is authored by '${author:-unknown}', not app/dependabot - a human PR goes through the review panel"
[ "$(printf '%s' "$pr_json" | jq -r '.state // empty' 2>/dev/null)" = OPEN ] || refuse "PR #$PR is not open"  # swallow-ok: an unreadable state fails the equality
[ "$(printf '%s' "$pr_json" | jq -r '.headRefOid // empty' 2>/dev/null)" = "$SHA" ] || refuse "PR #$PR's head is not $SHA (a GO is for one head)"  # swallow-ok: an unreadable head fails the equality
BRANCH=$(printf '%s' "$pr_json" | jq -r '.headRefName // empty' 2>/dev/null) || BRANCH=""  # swallow-ok: empty fails closed below
case "$BRANCH" in
    ''|*[\"\\]*|*[[:cntrl:]]*) refuse "the head branch '$BRANCH' cannot be written into a ledger row" ;;
esac
want=$(printf '%s' "$pr_json" | jq -r '.changedFiles // empty' 2>/dev/null) || want=""  # swallow-ok: empty fails the count check
nwo=$("$GH" repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || nwo=""  # swallow-ok: empty fails closed on the next line
[ -n "$nwo" ] || refuse "cannot resolve the repository"
# every changed name (counted against changedFiles) and each rename's old name; same name pattern as ready-check.sh dep_pr_generated
files=$("$GH" api --paginate "repos/$nwo/pulls/$PR/files" --jq '.[].filename' 2>/dev/null) || refuse "cannot read PR #$PR's files"  # swallow-ok: rc is checked, an unreadable list refuses
prev=$("$GH" api --paginate "repos/$nwo/pulls/$PR/files" --jq '.[].previous_filename // empty' 2>/dev/null) || refuse "cannot read PR #$PR's renamed paths"  # swallow-ok: rc is checked, an unreadable list refuses
[ -n "$files" ] || refuse "PR #$PR lists no changed files"
case "$want" in ''|*[!0-9]*) refuse "PR #$PR reports no changedFiles count" ;; esac
[ "$(printf '%s\n' "$files" | sort -u | wc -l | tr -d ' ')" -ge "$want" ] || refuse "the file list is shorter than the $want changed files (truncated)"
names="$files"
[ -z "$prev" ] || names="$files
$prev"
if bad=$(printf '%s\n' "$names" | grep -Ev '(^|/)(package\.json|package-lock\.json|bun\.lock|requirements[A-Za-z0-9._-]*\.txt)$'); then
    refuse "PR #$PR changes a file that is not a dependency manifest or lockfile: $(printf '%s' "$bad" | head -n 1)"
fi

ROOT=""
# shellcheck source=scripts/lib/handover-path.sh
# shellcheck disable=SC1091
if . "$ANCHOR/scripts/lib/handover-path.sh" 2>/dev/null; then
    ROOT=$(go_resolve_root "$ANCHOR" 2>/dev/null) || ROOT=""  # swallow-ok: empty ROOT fails closed on the next line
fi
[ -n "$ROOT" ] || refuse "cannot resolve the handover root to read judge $QID's verdict"
why=$(go_trust_verdict "$ROOT" "$QID" "$SHA" "$ANCHOR" "$PR") || refuse "judge $QID has no signed GO for this head: $why"

# the files were read after the head check; a head that moved since is not the head the GO signed
now=$("$GH" pr view "$PR" --json headRefOid 2>/dev/null | jq -r '.headRefOid // empty' 2>/dev/null) || now=""  # swallow-ok: empty fails the equality below
[ "$now" = "$SHA" ] || refuse "PR #$PR's head moved to '${now:-unknown}' while its files were read"

env -u CR_LEDGER bash "$HERE/ledger-append.sh" dependabot-go --branch "$BRANCH" --head "$SHA" --source "judge:$QID" --pr "$PR" >/dev/null || exit 2
echo "dependabot-go: recorded PR #$PR at $SHA (judge:$QID)"
