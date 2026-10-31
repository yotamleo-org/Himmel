#!/usr/bin/env bash
# delete-approved-branch.sh <branch> <approval-ref> - delete ONE remote branch
# that an operator approval record names.
#
# WHY: settings.json denies raw `git push --delete`, so an approved stale-branch
# delete waited for the operator at the station. This script is the one
# sanctioned shape; the raw deny stays unchanged.
#
# REFUSES (exit 1, remote untouched):
#   - main, master, and release/* (protected, approved or not)
#   - a branch with an open PR, and any case where the PR lookup fails
#   - a branch the approval record does not name under <approval-ref>
#
# APPROVAL RECORD: a TSV, one `<ref><TAB><branch>` per line, `#` lines ignored.
#   HIMMEL_BRANCH_APPROVALS   file (default: $HOME/.himmel/branch-delete-approvals.tsv)
#   HIMMEL_BRANCH_DELETE_LOG  append-only delete log (default: $HOME/.himmel/branch-deletes.log)
#   HIMMEL_DELETE_REMOTE      remote to delete from (default: origin)
#   HIMMEL_DELETE_GH_REPO     owner/repo for the open-PR lookup (default: parsed from the remote URL)
# ponytail: the record is a plain file the bridge writes when the operator
# approves, so a session that can write it can approve itself; upgrade path is
# an operator-signed record the script verifies.
#
# EXIT: 0 deleted; 1 refused; 2 usage/environment error.
set -uo pipefail

APPROVALS="${HIMMEL_BRANCH_APPROVALS:-$HOME/.himmel/branch-delete-approvals.tsv}"
LOG="${HIMMEL_BRANCH_DELETE_LOG:-$HOME/.himmel/branch-deletes.log}"
REMOTE="${HIMMEL_DELETE_REMOTE:-origin}"

die() { echo "delete-approved-branch: $*" >&2; exit "${2:-1}"; }

[ "$#" -eq 2 ] || die "usage: delete-approved-branch.sh <branch> <approval-ref>" 2
branch="$1"
ref="$2"

case "$branch" in
    ''|-*) die "refusing: '$branch' is not a branch name" 2 ;;
esac
[ -n "$ref" ] || die "usage: empty approval ref" 2
git check-ref-format --branch "$branch" >/dev/null 2>&1 \
    || die "refusing: '$branch' is not a valid branch name" 2
case "$branch" in
    *[[:space:]]*|*'*'*|*'?'*|*'['*) die "refusing: '$branch' holds a glob or whitespace" 2 ;;
esac

case "$branch" in
    main|master|release/*) die "refusing: '$branch' is a protected branch" ;;
esac

[ -f "$APPROVALS" ] || die "refusing: approval record $APPROVALS not found"
if ! awk -F'\t' -v r="$ref" -v b="$branch" \
        '$0 !~ /^#/ && $1 == r && $2 == b { found = 1 } END { exit !found }' "$APPROVALS"; then
    die "refusing: approval '$ref' does not name branch '$branch'"
fi

# Bind the PR lookup to the repository the delete targets, never gh's inferred
# repo or an inherited GH_REPO.
gh_repo="${HIMMEL_DELETE_GH_REPO:-}"
if [ -z "$gh_repo" ]; then
    # the push URL is what the delete reaches; only github.com is looked up
    remote_url="$(git remote get-url --push "$REMOTE" 2>/dev/null)" \
        || die "refusing: remote '$REMOTE' has no URL"
    gh_repo="$(printf '%s' "$remote_url" | sed -E 's#^(git@github\.com:|ssh://git@github\.com/|https://github\.com/)##; s#\.git$##')"
    [ "$gh_repo" != "$remote_url" ] \
        || die "refusing: remote '$REMOTE' is not a github.com remote"
fi
case "$gh_repo" in
    */*/*|*[!A-Za-z0-9._/-]*|/*|*/|'') die "refusing: cannot resolve the GitHub repository of remote '$REMOTE'" ;;
    */*) ;;
    *) die "refusing: cannot resolve the GitHub repository of remote '$REMOTE'" ;;
esac

open_prs="$(GH_HOST=github.com gh pr list --repo "$gh_repo" --head "$branch" --state open --json number --jq length 2>/dev/null)" \
    || die "refusing: cannot check open PRs for '$branch' (gh failed)"
case "$open_prs" in
    ''|*[!0-9]*) die "refusing: unreadable open-PR count '$open_prs' for '$branch'" ;;
esac
[ "$open_prs" -eq 0 ] || die "refusing: '$branch' has $open_prs open PR(s)"

git push "$REMOTE" --delete "refs/heads/$branch" >&2 \
    || die "git push --delete failed for '$branch'" 2

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
printf '%s\tdeleted\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$REMOTE" "$branch" "$ref" >> "$LOG" \
    || echo "delete-approved-branch: warning: could not write log $LOG" >&2
echo "delete-approved-branch: deleted $REMOTE/$branch (approval $ref)"
