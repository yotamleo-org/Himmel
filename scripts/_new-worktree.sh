#!/usr/bin/env bash
# Create a himmel-convention worktree + branch in one shot.
#
# INTERNAL HELPER — invoked only by scripts/clean-garden.sh. Do not call directly;
# use `/clean_garden <branch>` instead. (Renamed from `new-worktree.sh` in #39
# after `/clean_garden` superseded the standalone `/new-worktree` command.)
#
# Usage (internal):
#   ./scripts/_new-worktree.sh <branch-name> [--no-install] [--verbose]
#
# Branch naming: type/slug (feat/foo, chore/bar, fix/baz, docs/qux).
# Worktree path is derived by replacing `/` with `+`:
#   feat/foo  → .claude/worktrees/feat+foo
#
# Quiet-mode default: prints a single OK/ERR line with the worktree path and the
# log file. Pass --verbose to stream everything to the terminal too.
#
# Side effects:
#   1. git fetch origin <default> (refresh refs only — does not modify local
#      default branch; <default> = main OR master, resolved)
#   2. git worktree add <path> -b <branch> origin/<default>
#   3. Unless --no-install: npm install --omit=dev in scripts/jira/ so the
#      pre-push license-check hook can validate without per-push setup.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# default_branch() resolves the repo's default integration branch (main OR
# master) so new worktrees branch off the real default.
# shellcheck source=guardrails/lib.sh
# shellcheck disable=SC1091
if ! . "$SCRIPT_DIR/guardrails/lib.sh" 2>/dev/null; then
    echo "ERR new-worktree: cannot source guardrails/lib.sh" >&2
    exit 1
fi
# forge_detect: the gh-auth-setup-git fetch self-heal below is
# GitHub-specific, so it only fires for a github origin.
# shellcheck source=lib/forge.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/forge.sh"
# branch_has_merged_pr: refuse creating a worktree for a branch
# that was already shipped via a merged PR.
# shellcheck source=lib/branch-shipped.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/branch-shipped.sh"

usage() {
    echo "Usage: $0 <branch-name> [--no-install] [--verbose]" >&2
    echo "  branch-name format: type/slug  (feat/foo, chore/bar, fix/baz, docs/qux)" >&2
    exit 2
}

[ $# -lt 1 ] && usage

BRANCH=""
NPM_INSTALL=1
VERBOSE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --no-install) NPM_INSTALL=0; shift ;;
        --verbose|-v) VERBOSE=1; shift ;;
        -h|--help) usage ;;
        -*) echo "Unknown flag: $1" >&2; usage ;;
        *) BRANCH="$1"; shift ;;
    esac
done

[ -z "$BRANCH" ] && usage

if ! [[ "$BRANCH" =~ ^(feat|fix|chore|docs|refactor|test)/[a-zA-Z0-9._+-]+$ ]]; then
    echo "ERR new-worktree: branch '$BRANCH' invalid — must be type/slug where type ∈ feat|fix|chore|docs|refactor|test" >&2
    exit 1
fi
# Authoritative validation: git's own rules (rejects e.g. .lock suffix, leading
# dot, consecutive dots — things our friendlier regex would otherwise let through
# and fail downstream with a generic "worktree add failed" error.)
if ! git check-ref-format "refs/heads/$BRANCH" 2>/dev/null; then
    echo "ERR new-worktree: branch '$BRANCH' rejected by git check-ref-format (reserved suffix, leading dot, consecutive dots, etc.)" >&2
    exit 1
fi

COMMON_DIR=$(git rev-parse --git-common-dir 2>/dev/null) || { echo "ERR new-worktree: not in a git repo" >&2; exit 1; }
# `git rev-parse --git-common-dir` may return relative path on Windows Git Bash;
# resolve to absolute via `cd`-and-`pwd` so PRIMARY_WORKTREE is reliable.
PRIMARY_WORKTREE=$(cd "$(dirname "$COMMON_DIR")" && pwd)
COMMON_DIR_ABS=$(cd "$COMMON_DIR" && pwd)

# Resolve the repo's default integration branch
# so the fetch + worktree-add below target the real default.
DEFAULT_BRANCH=$(default_branch "$PRIMARY_WORKTREE")

WORKTREE_RELATIVE=".claude/worktrees/${BRANCH//\//+}"
WORKTREE_PATH="$PRIMARY_WORKTREE/$WORKTREE_RELATIVE"
LOG="${TMPDIR:-/tmp}/new-worktree-$(date +%Y%m%d-%H%M%S)-$$.log"

run() {
    # Run, tee to log iff verbose, else log only.
    if [ $VERBOSE -eq 1 ]; then
        "$@" 2>&1 | tee -a "$LOG"
    else
        "$@" >>"$LOG" 2>&1
    fi
}

if [ -e "$WORKTREE_PATH" ]; then
    echo "ERR new-worktree: worktree path exists: $WORKTREE_PATH" >&2
    exit 1
fi
if git -C "$PRIMARY_WORKTREE" show-ref --verify --quiet "refs/heads/$BRANCH"; then
    echo "ERR new-worktree: local branch '$BRANCH' exists — delete with: git branch -D $BRANCH" >&2
    exit 1
fi

# Live-worktree ceiling: refuse rather than degrade. Counts registered worktrees
# under .claude/worktrees (the primary checkout is not counted).
# ponytail: static default, not yet derived from measured git latency vs count; HIMMEL-1860 slice 3.
WT_CEILING="${HIMMEL_WORKTREE_CEILING:-100}"
case "$WT_CEILING" in ''|*[!0-9]*) WT_CEILING=100 ;; esac
# Fails closed: an unreadable worktree list is a refusal, never a count of 0.
wt_live_count() {
    local list
    if ! list=$(git -C "$PRIMARY_WORKTREE" worktree list --porcelain -z | tr '\0' '\n'); then
        echo "ERR new-worktree: cannot read worktree list — refusing to create (cannot verify the ceiling)" >&2
        exit 1
    fi
    printf '%s\n' "$list" | grep -cF "worktree $PRIMARY_WORKTREE/.claude/worktrees/" || true
}
wt_ceiling_check() {
    WT_LIVE=$(wt_live_count) || exit 1
    if [ "$WT_LIVE" -ge "$WT_CEILING" ]; then
        echo "ERR new-worktree: worktree ceiling reached ($WT_LIVE live >= $WT_CEILING) — reclaim with /clean, or raise HIMMEL_WORKTREE_CEILING" >&2
        exit 1
    fi
}
# Early cheap refusal; re-checked under the creation lock before `worktree add`.
wt_ceiling_check

# refuse creating a worktree for a branch that maps to a merged PR.
# Run BEFORE the network fetch so the refusal is cheap and early.
# FORGE / GH_CMD must be exported to propagate into branch_has_merged_pr's
# timeout subprocess (they are test seams and may be set by the caller).
export FORGE GH_CMD 2>/dev/null || true
_bs_rc=0
branch_has_merged_pr "$BRANCH" "$PRIMARY_WORKTREE" || _bs_rc=$?
case "$_bs_rc" in
    0)
        if [ "${REUSE_MERGED_BRANCH_OK:-0}" = "1" ]; then
            : # override: continue
        else
            echo "ERR new-worktree: branch '$BRANCH' maps to a merged PR — pick a fresh name, or set REUSE_MERGED_BRANCH_OK=1 to override" >&2
            exit 1
        fi
        ;;
    2)
        echo "WARN new-worktree: uniqueness-vs-merged-PR check skipped (forge unreachable)" >&2
        ;;
    *) : ;; # rc 1 (not merged) — continue silently
esac

{
    echo "=== new-worktree $BRANCH @ $(date -Iseconds) ==="
} >>"$LOG"

# A project with no origin (a fresh adopter trial) has nothing to fetch: branch
# from the local default instead of dying on the fetch.
if git -C "$PRIMARY_WORKTREE" remote get-url origin >/dev/null 2>&1; then
    HAS_ORIGIN=1
    BASE_REF="origin/$DEFAULT_BRANCH"
else
    HAS_ORIGIN=0
    BASE_REF="$DEFAULT_BRANCH"
    echo "WARN new-worktree: no 'origin' remote - branching from local '$DEFAULT_BRANCH'" >&2
fi

if [ "$HAS_ORIGIN" -eq 1 ] && ! run git -C "$PRIMARY_WORKTREE" fetch origin "$DEFAULT_BRANCH" --quiet; then
    # Common unattended-run failure (e.g. arm-resume relaunch): git's stored
    # credential (Windows Git Credential Manager, or an expired PAT git uses) is
    # stale while `gh` holds a SEPARATE valid token. `gh auth setup-git` wires git
    # to use gh's credential helper; retry the fetch once before giving up. Gated
    # on gh being authenticated (default host github.com — himmel's remote): an
    # unauthenticated/absent gh falls straight through to the original error; when
    # gh IS authenticated, even a non-auth fetch failure (network/DNS) triggers the
    # setup-git retry, then surfaces a distinct 'auth may not be the cause' error
    # if it stays broken. Self-healing so an unattended worktree-create doesn't
    # hard-fail on a recoverable auth gap. GitHub-only: `gh auth setup-git` wires
    # github credentials, so a bitbucket origin falls straight through to the
    # plain error.
    forge_kind=$( ( cd "$PRIMARY_WORKTREE" && forge_detect 2>/dev/null ) || true )
    if [ "$forge_kind" = "github" ] && command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
        echo "WARN new-worktree: git fetch failed; gh is authenticated — running 'gh auth setup-git' and retrying" >&2
        run gh auth setup-git || true
        if ! run git -C "$PRIMARY_WORKTREE" fetch origin "$DEFAULT_BRANCH" --quiet; then
            echo "ERR new-worktree: git fetch still failing after gh auth setup-git retry — auth may not be the cause; see log: $LOG" >&2
            exit 1
        fi
    else
        echo "ERR new-worktree: git fetch failed (log: $LOG)" >&2
        exit 1
    fi
fi
# Count-then-create must be atomic: serialize concurrent creators on a lock in
# the git common dir so two of them cannot both pass at ceiling-1.
# ponytail: no flock (e.g. stock macOS) creates unlocked and the race stays open, install util-linux flock; HIMMEL-1860.
if command -v flock >/dev/null 2>&1; then
    exec 9>"$COMMON_DIR_ABS/himmel-worktree-create.lock"
    if ! flock -w "${HIMMEL_WORKTREE_LOCK_TIMEOUT:-120}" 9; then
        echo "ERR new-worktree: timed out waiting for the worktree creation lock — refusing" >&2
        exit 1
    fi
fi
wt_ceiling_check
if ! run git -C "$PRIMARY_WORKTREE" worktree add "$WORKTREE_RELATIVE" -b "$BRANCH" "$BASE_REF"; then
    echo "ERR new-worktree: worktree add failed (log: $LOG)" >&2
    exit 1
fi
exec 9>&-

# `-b <branch> origin/<default>` leaves the new branch tracking
# origin/<default> (branch.autoSetupMerge), not a same-named remote branch
# that doesn't exist yet — so a bare `git push` errors under push.default=simple
# and a leg's first push needs an explicit `-u origin <branch>`. Point the
# branch's OWN tracking config at its own future remote ref instead (branch-scoped
# keys only — never a global/repo-wide default) so `git push` with no flags
# already knows where to go and creates that ref on the first push.
if [ "$HAS_ORIGIN" -eq 1 ]; then
    run git -C "$PRIMARY_WORKTREE" config "branch.${BRANCH}.remote" origin
    run git -C "$PRIMARY_WORKTREE" config "branch.${BRANCH}.merge" "refs/heads/${BRANCH}"
fi

INSTALL_NOTE=""
if [ $NPM_INSTALL -eq 1 ] && [ -f "$WORKTREE_PATH/scripts/jira/package.json" ]; then
    if (cd "$WORKTREE_PATH/scripts/jira" && run npm install --omit=dev --no-audit --no-fund --silent); then
        INSTALL_NOTE=" (jira deps installed)"
    else
        echo "ERR new-worktree: worktree created but npm install failed (log: $LOG)" >&2
        exit 1
    fi
fi

echo "OK new-worktree: $BRANCH → $WORKTREE_PATH${INSTALL_NOTE} (log: $LOG)"
