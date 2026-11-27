#!/usr/bin/env bash
# Create a himmel-convention worktree + branch in one shot.
#
# INTERNAL HELPER — invoked only by scripts/worktree.sh. Do not call directly;
# use `/worktree <branch>` instead. (Renamed from `new-worktree.sh` in #39
# after `/clean_garden` superseded the standalone `/new-worktree` command.)
#
# Usage (internal):
#   ./scripts/_new-worktree.sh <branch-name> [--no-install] [--no-fetch] [--verbose]
#     --no-fetch: branch from the origin/<default> ref already fetched (a caller
#     creating many worktrees fetches once; concurrent fetches race on its lock)
#   ./scripts/_new-worktree.sh <branch-name> --resume [--check] [--no-install] [--verbose]
#     the branch already exists (a RESUME row): fetch it and attach a worktree at a
#     tip this script can account for. A worktree already registered for the
#     branch at the standard path is handed back untouched (no fast-forward).
#     Never branches from the default branch. --check writes nothing and prints
#     local|origin|both|none|unknown. Reached through `worktree.sh resume`.
#   ./scripts/_new-worktree.sh --check-name <branch-name>
#     validate the branch name only (the type list below and git's ref rules),
#     create nothing; exit 0 when worktree.sh would accept it.
#
# Branch naming: type/slug (feat/foo, chore/bar, fix/baz, docs/qux).
# Worktree path is derived by replacing `/` with `+`:
#   feat/foo  → .claude/worktrees/feat+foo
#
# Quiet-mode default: prints a single OK/ERR line with the worktree path and the
# log file. Pass --verbose to stream everything to the terminal too.
#
# Side effects (new):
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
    echo "Usage: $0 <branch-name> [--no-install] [--no-fetch] [--verbose]" >&2
    echo "  branch-name format: type/slug  (feat/foo, chore/bar, fix/baz, docs/qux)" >&2
    exit 2
}

[ $# -lt 1 ] && usage

BRANCH=""
NPM_INSTALL=1
VERBOSE=0
CHECK_NAME=0
NO_FETCH=0
RESUME=0
RESUME_CHECK=0
while [ $# -gt 0 ]; do
    case "$1" in
        --no-install) NPM_INSTALL=0; shift ;;
        --verbose|-v) VERBOSE=1; shift ;;
        --check-name) CHECK_NAME=1; shift ;;
        --no-fetch) NO_FETCH=1; shift ;;
        --resume) RESUME=1; shift ;;
        --check) RESUME_CHECK=1; shift ;;
        -h|--help) usage ;;
        -*) echo "Unknown flag: $1" >&2; usage ;;
        *) BRANCH="$1"; shift ;;
    esac
done

[ -z "$BRANCH" ] && usage
if [ "$RESUME_CHECK" -eq 1 ] && [ "$RESUME" -eq 0 ]; then
    echo "ERR new-worktree: --check belongs to --resume" >&2
    exit 2
fi
if [ "$RESUME" -eq 1 ] && [ "$NO_FETCH" -eq 1 ]; then
    echo "ERR new-worktree: --resume always fetches; --no-fetch does not apply" >&2
    exit 2
fi

BRANCH_RE='^(feat|fix|chore|docs|refactor|test)/[a-zA-Z0-9._+-]+$'
BRANCH_TYPES=${BRANCH_RE#^(}
BRANCH_TYPES=${BRANCH_TYPES%%)*}
if ! [[ "$BRANCH" =~ $BRANCH_RE ]]; then
    echo "ERR new-worktree: branch '$BRANCH' invalid — must be type/slug where type ∈ $BRANCH_TYPES; fix: rename it to one of those types (e.g. docs/${BRANCH#*/})" >&2
    exit 1
fi
# Authoritative validation: git's own rules (rejects e.g. .lock suffix, leading
# dot, consecutive dots — things our friendlier regex would otherwise let through
# and fail downstream with a generic "worktree add failed" error.)
if ! git check-ref-format "refs/heads/$BRANCH" 2>/dev/null; then
    echo "ERR new-worktree: branch '$BRANCH' rejected by git check-ref-format (reserved suffix, leading dot, consecutive dots, etc.)" >&2
    exit 1
fi
[ "$CHECK_NAME" -eq 1 ] && exit 0

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

post_create() {
    # Jira is CLI-first, so the atlassian MCP plugin should not load. A
    # session started here without a plugin profile inherits an ancestor's
    # `atlassian: true` (the primary's hand-kept local override) and Claude
    # records one local-scope install per worktree. This file is the nearest layer,
    # so it wins. An existing one is the worker's own; leave it.
    if [ ! -e "$WORKTREE_PATH/.claude/settings.local.json" ]; then
        mkdir -p "$WORKTREE_PATH/.claude" &&
            printf '{\n  "enabledPlugins": {\n    "atlassian@claude-plugins-official": false\n  }\n}\n' \
                > "$WORKTREE_PATH/.claude/settings.local.json"
    fi

    INSTALL_NOTE=""
    if [ $NPM_INSTALL -eq 1 ] && [ -f "$WORKTREE_PATH/scripts/jira/package.json" ]; then
        JIRA_PRIMARY="$PRIMARY_WORKTREE/scripts/jira"
        if [ -d "$JIRA_PRIMARY/node_modules" ] && [ ! -e "$WORKTREE_PATH/scripts/jira/node_modules" ] &&
            [ -f "$JIRA_PRIMARY/package-lock.json" ] &&
            cmp -s "$JIRA_PRIMARY/package-lock.json" "$WORKTREE_PATH/scripts/jira/package-lock.json" &&
            cmp -s "$JIRA_PRIMARY/package.json" "$WORKTREE_PATH/scripts/jira/package.json" &&
            cp -a --reflink=auto "$JIRA_PRIMARY/node_modules" "$WORKTREE_PATH/scripts/jira/node_modules" 2>>"$LOG"; then
            INSTALL_NOTE=" (jira deps reused from primary, no install)"
        elif (cd "$WORKTREE_PATH/scripts/jira" && run npm install --omit=dev --no-audit --no-fund --silent); then
            INSTALL_NOTE=" (jira deps installed)"
        else
            echo "ERR new-worktree: worktree created but npm install failed (log: $LOG)" >&2
            exit 1
        fi
    fi
}

if [ "$RESUME" -eq 1 ]; then
    # shellcheck source=lib/qmd-bounded.sh
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/lib/qmd-bounded.sh"
    export GIT_TERMINAL_PROMPT=0
    resume_refuse() { echo "ERR new-worktree: $1: $2" >&2; exit 1; }
    if git -C "$PRIMARY_WORKTREE" remote get-url origin >/dev/null 2>&1; then HAS_ORIGIN=1; else HAS_ORIGIN=0; fi
    PROBE=absent
    if [ "$HAS_ORIGIN" -eq 1 ]; then
        _rp_rc=0
        _rp_out=$(qmd_bounded 10 git -C "$PRIMARY_WORKTREE" ls-remote --heads origin "refs/heads/$BRANCH" 2>/dev/null) || _rp_rc=$?
        if [ "$_rp_rc" -ne 0 ]; then
            PROBE=failed
        elif [ -n "$(printf '%s\n' "$_rp_out" | awk -v r="refs/heads/$BRANCH" '$2 == r { print $1 }')" ]; then
            PROBE=listed
        fi
    fi
    L=$(git -C "$PRIMARY_WORKTREE" rev-parse --verify -q "refs/heads/$BRANCH" 2>/dev/null) || L=""
    if [ "$RESUME_CHECK" -eq 1 ]; then
        case "$PROBE" in
            failed) echo unknown ;;
            listed) if [ -n "$L" ]; then echo both; else echo origin; fi ;;
            *) if [ -n "$L" ]; then echo local; else echo none; fi ;;
        esac
        exit 0
    fi
fi

if [ "$RESUME" -eq 0 ] && [ -e "$WORKTREE_PATH" ]; then
    echo "ERR new-worktree: worktree path exists: $WORKTREE_PATH" >&2
    exit 1
fi
if [ "$RESUME" -eq 0 ] && git -C "$PRIMARY_WORKTREE" show-ref --verify --quiet "refs/heads/$BRANCH"; then
    echo "ERR new-worktree: local branch '$BRANCH' exists — delete with: git branch -D $BRANCH" >&2
    exit 1
fi

# Live-worktree ceiling: refuse rather than degrade. Counts registered worktrees
# under .claude/worktrees (the primary checkout is not counted).
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
if [ "$RESUME" -eq 0 ] || [ ! -e "$WORKTREE_PATH" ]; then wt_ceiling_check; fi

if [ "$RESUME" -eq 1 ]; then
    STALE=0
    HANDBACK=0
    _reg_cur=""
    _reg_path=""
    while IFS= read -r _reg_line; do
        case "$_reg_line" in
            "worktree "*) _reg_cur="${_reg_line#worktree }" ;;
            "branch refs/heads/$BRANCH") _reg_path="$_reg_cur" ;;
        esac
    done < <(git -C "$PRIMARY_WORKTREE" worktree list --porcelain)
    if [ -e "$WORKTREE_PATH" ]; then
        if [ -n "$_reg_path" ] && [ "$_reg_path" -ef "$WORKTREE_PATH" ] &&
            [ "$(git -C "$WORKTREE_PATH" rev-parse --show-toplevel 2>/dev/null)" -ef "$WORKTREE_PATH" ] &&
            [ "$(git -C "$WORKTREE_PATH" symbolic-ref -q HEAD)" = "refs/heads/$BRANCH" ] &&
            [ "$(cd "$WORKTREE_PATH" && cd "$(git rev-parse --git-common-dir)" && pwd)" -ef "$COMMON_DIR_ABS" ]; then
            HANDBACK=1
        else
            resume_refuse path-exists "worktree path exists: $WORKTREE_PATH"
        fi
    elif [ -n "$_reg_path" ]; then
        if [ -e "$_reg_path" ]; then
            resume_refuse checked-out "branch '$BRANCH' is already checked out at $_reg_path"
        fi
        STALE=1
    fi
    export FORGE GH_CMD 2>/dev/null || true
    _bs_rc=0
    branch_has_merged_pr "$BRANCH" "$PRIMARY_WORKTREE" || _bs_rc=$?
    if [ "${REUSE_MERGED_BRANCH_OK:-0}" != "1" ]; then
        case "$_bs_rc" in
            0) resume_refuse merged "branch '$BRANCH' maps to a merged PR - set REUSE_MERGED_BRANCH_OK=1 to resume it anyway" ;;
            2) resume_refuse forge-unknown "the forge could not say whether '$BRANCH' was merged - set REUSE_MERGED_BRANCH_OK=1 to resume it anyway" ;;
        esac
    fi
    echo "=== new-worktree --resume $BRANCH @ $(date -Iseconds) ===" >>"$LOG"
    O=""
    case "$PROBE" in
        failed) resume_refuse fetch-failed "could not ask origin about '$BRANCH' (ls-remote failed or timed out); nothing created, no ref moved" ;;
        listed)
            if ! run qmd_bounded "${HIMMEL_RESUME_FETCH_TIMEOUT:-120}" git -C "$PRIMARY_WORKTREE" fetch --quiet origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH"; then
                resume_refuse fetch-failed "origin lists '$BRANCH' but the fetch failed (log: $LOG); nothing created"
            fi
            O=$(git -C "$PRIMARY_WORKTREE" rev-parse --verify -q "refs/remotes/origin/$BRANCH") || resume_refuse fetch-failed "fetched '$BRANCH' but origin/$BRANCH did not appear"
            ;;
    esac
    RESUME_NOTE=""
    if [ -z "$L" ] && [ -z "$O" ]; then
        resume_refuse none "branch '$BRANCH' exists neither locally nor on origin - create it with: bash scripts/worktree.sh new $BRANCH"
    elif [ -z "$L" ]; then
        RESUME_STATE=only-origin
    elif [ -z "$O" ]; then
        RESUME_STATE=only-local
        RESUME_NOTE="no remote branch"
    elif [ "$L" = "$O" ]; then
        RESUME_STATE=equal
    elif git -C "$PRIMARY_WORKTREE" merge-base --is-ancestor "$L" "$O"; then
        RESUME_STATE=behind-ff
    elif git -C "$PRIMARY_WORKTREE" merge-base --is-ancestor "$O" "$L"; then
        RESUME_STATE=ahead
        RESUME_NOTE="local ahead of origin by $(git -C "$PRIMARY_WORKTREE" rev-list --count "$O..$L")"
    else
        resume_refuse diverged "local $L and origin $O have diverged; nothing created - reconcile by hand (git -C $PRIMARY_WORKTREE log --oneline --graph $L $O)"
    fi
    if [ "$HANDBACK" -eq 1 ]; then
        _wt_head=$(git -C "$WORKTREE_PATH" rev-parse --verify -q HEAD) || resume_refuse path-exists "worktree path exists but its HEAD cannot be read: $WORKTREE_PATH"
        if [ -n "$RESUME_NOTE" ]; then echo "NOTE new-worktree: $RESUME_NOTE"; fi
        echo "RESUMED $WORKTREE_PATH $BRANCH $_wt_head $RESUME_STATE"
        exit 0
    fi
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$COMMON_DIR_ABS/himmel-worktree-create.lock"
        # prim-ok: the wait is bounded (HIMMEL_WORKTREE_LOCK_TIMEOUT, default 120 s) and the lock spans the rest of the script; with_lock waits unbounded and scopes to one command
        if ! flock -w "${HIMMEL_WORKTREE_LOCK_TIMEOUT:-120}" 9; then
            resume_refuse lock "timed out waiting for the worktree creation lock - refusing"
        fi
    fi
    if [ "$STALE" -eq 1 ]; then
        [ -e "$_reg_path" ] && resume_refuse checked-out "branch '$BRANCH' is checked out at $_reg_path again; nothing removed"
        git -C "$PRIMARY_WORKTREE" worktree remove --force "$_reg_path" || resume_refuse stale-registration "could not remove the stale registration of '$BRANCH' at $_reg_path"
        echo "removed the stale registration of $BRANCH ($_reg_path)"
    fi
    wt_ceiling_check
    _add_ok=1
    if [ "$RESUME_STATE" = "only-origin" ]; then
        run git -C "$PRIMARY_WORKTREE" worktree add "$WORKTREE_RELATIVE" -b "$BRANCH" "$O" || _add_ok=0
    else
        run git -C "$PRIMARY_WORKTREE" worktree add "$WORKTREE_RELATIVE" "$BRANCH" || _add_ok=0
    fi
    [ "$_add_ok" -eq 1 ] || resume_refuse add-failed "worktree add failed (log: $LOG); nothing created"
    exec 9>&-
    if [ "$RESUME_STATE" = "behind-ff" ]; then
        if ! run git -C "$WORKTREE_PATH" merge --ff-only --quiet "$O"; then
            git -C "$PRIMARY_WORKTREE" worktree remove --force "$WORKTREE_PATH" >>"$LOG" 2>&1 || true
            resume_refuse ff-failed "could not fast-forward '$BRANCH' to origin $O (log: $LOG); worktree removed, local branch unchanged"
        fi
    fi
    if [ "$RESUME_STATE" = "only-origin" ] && [ "$HAS_ORIGIN" -eq 1 ]; then
        run git -C "$PRIMARY_WORKTREE" config "branch.${BRANCH}.remote" origin
        run git -C "$PRIMARY_WORKTREE" config "branch.${BRANCH}.merge" "refs/heads/${BRANCH}"
    fi
    post_create
    if [ -n "$RESUME_NOTE" ]; then echo "NOTE new-worktree: $RESUME_NOTE"; fi
    echo "RESUMED $WORKTREE_PATH $BRANCH $(git -C "$WORKTREE_PATH" rev-parse HEAD) $RESUME_STATE"
    exit 0
fi

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

if [ "$HAS_ORIGIN" -eq 1 ] && [ "$NO_FETCH" -eq 0 ] && ! run git -C "$PRIMARY_WORKTREE" fetch origin "$DEFAULT_BRANCH" --quiet; then
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
if command -v flock >/dev/null 2>&1; then
    exec 9>"$COMMON_DIR_ABS/himmel-worktree-create.lock"
    # prim-ok: the wait is bounded (HIMMEL_WORKTREE_LOCK_TIMEOUT, default 120 s) and the lock spans the rest of the script; with_lock waits unbounded and scopes to one command
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
# and a worker's first push needs an explicit `-u origin <branch>`. Point the
# branch's OWN tracking config at its own future remote ref instead (branch-scoped
# keys only — never a global/repo-wide default) so `git push` with no flags
# already knows where to go and creates that ref on the first push.
if [ "$HAS_ORIGIN" -eq 1 ]; then
    run git -C "$PRIMARY_WORKTREE" config "branch.${BRANCH}.remote" origin
    run git -C "$PRIMARY_WORKTREE" config "branch.${BRANCH}.merge" "refs/heads/${BRANCH}"
fi

post_create

echo "OK new-worktree: $BRANCH → $WORKTREE_PATH${INSTALL_NOTE} (log: $LOG)"
