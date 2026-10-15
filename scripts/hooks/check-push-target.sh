#!/usr/bin/env bash
# Pre-push hook: block direct push to main.
# Input from git: "local_ref local_sha remote_ref remote_sha" per line on stdin.
#
# Root cause note: this hook is wired as a pre-commit-configured
# `stages: [pre-push]` entry (.pre-commit-config.yaml, id: no-push-to-main).
# pre-commit's own hook-impl reads ALL of git's pre-push stdin itself, before
# invoking any configured hook (hook_impl.py: `sys.stdin.buffer.read()` —
# see check-cr-before-push.sh for the fuller writeup),
# and exposes the pushed ref to configured hooks only via PRE_COMMIT_* env
# vars. A `while read` loop here would always see an already-drained (EOF)
# stdin in that shape, run zero iterations, and fall through to `exit 0` —
# passing EVERY push, including a direct push to main, under the exact
# invocation shape pre-commit actually uses (confirmed against the installed
# pre-commit 4.6.0 source; not Windows-specific). No bypass env var or
# .single-writer marker is involved — this script never read either.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../guardrails/lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../guardrails/lib.sh"
# shellcheck source=../lib/git-clean.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/git-clean.sh"
git_env_scrub

block_main() {
    echo "ERROR: Direct push to 'main' is not allowed." >&2
    echo "       Open a PR from a worktree branch instead." >&2
    exit 1
}

# a NEW branch must be type/slug (feat|fix|chore|docs|refactor|
# test), handover/<TICKET>-<slug> or claude/*. Checked only when a branch is
# being created on the remote — never retroactively, never on a delete or a
# tag. Single-run bypass: BRANCH_NAME_OK=1 git push.
branch_name_ok() {
    case "$1" in
        claude/?*) return 0 ;;
    esac
    LC_ALL=C grep -Eq \
        '^((feat|fix|chore|docs|refactor|test)/[A-Za-z0-9][A-Za-z0-9._-]*|handover/[A-Z][A-Z0-9]*-[0-9]+-[A-Za-z0-9][A-Za-z0-9._-]*)$' <<<"$1"
}

is_zero_oid() {
    case "$1" in
        ''|*[!0]*) return 1 ;;
    esac
    return 0
}

check_new_branch_name() {
    local ref="$1" branch
    [ "${BRANCH_NAME_OK:-}" = "1" ] && return 0
    case "$ref" in refs/heads/*) ;; *) return 0 ;; esac
    branch="${ref#refs/heads/}"
    branch_name_ok "$branch" && return 0
    echo "ERROR: check-push-target: branch name '$branch' is not allowed for a new branch." >&2
    echo "       Use type/slug (feat|fix|chore|docs|refactor|test), handover/<TICKET>-<slug> or claude/<slug>." >&2
    echo "       Rename: git branch -m <new-name>. Single-run bypass: BRANCH_NAME_OK=1 git push." >&2
    exit 1
}

# Read the ref stream ONCE (mirrors check-cr-before-push.sh) — stdin cannot
# be rewound. `[ ! -t 0 ]` avoids blocking on a bare interactive terminal.
push_ref_lines=""
if [ ! -t 0 ]; then
    push_ref_lines=$(cat)
fi

if [ -n "$push_ref_lines" ]; then
    while IFS=' ' read -r _local_ref local_sha remote_ref remote_sha; do
        [ -z "$remote_ref" ] && continue
        is_main_ref "$remote_ref" && block_main
        # New branch = remote sha all zeros (any length: SHA-1 or SHA-256); a
        # delete push has a zero local sha.
        if is_zero_oid "$remote_sha" && ! is_zero_oid "$local_sha"; then
            check_new_branch_name "$remote_ref"
        fi
    done <<REF_LINES
$push_ref_lines
REF_LINES
    exit 0
fi

# Empty stdin. git's pre-push protocol reports a line only for a ref that is
# actually moving, so an empty-but-connected stdin from a REAL invocation
# (a genuine .git/hooks/pre-push, the pre-push.legacy migration hook, or a
# direct/manual/test invocation) trustworthily means nothing is being pushed
# — safe to allow. The one shape where empty stdin is NOT trustworthy is
# pre-commit's own configured-hook dispatch (commands/run.py), which drains
# stdin unconditionally before running ANY configured hook, whether or not a
# ref actually moved. `PRE_COMMIT=1` is the env var pre-commit sets ONLY
# around that dispatch (never around its legacy-hook subprocess call, and
# never present outside pre-commit) — it is the one reliable signal that
# distinguishes the two, so check it before trusting an empty stdin.
if [ "${PRE_COMMIT:-}" = "1" ]; then
    # PRE_COMMIT_REMOTE_BRANCH names the first pushed ref (set together with
    # PRE_COMMIT_REMOTE_NAME/URL whenever a ref actually moved — see
    # check-cr-before-push.sh). This branch alone only sees the FIRST ref of
    # a multi-ref push, so a main push ordered after a non-main ref in the
    # same `git push` would slip past it in isolation. That gap is closed by
    # install-cr-pre-push-legacy.sh, which now runs this same script against
    # git's complete, undrained ref stream ahead of the CR gate — the branch
    # below is defense-in-depth for a clone that has not (yet) run it.
    if [ -n "${PRE_COMMIT_REMOTE_BRANCH:-}" ]; then
        is_main_ref "$PRE_COMMIT_REMOTE_BRANCH" && block_main
        # pre-commit hides the remote sha and a local remote-tracking ref can
        # be missing or stale, so an invalid name is confirmed against the
        # remote itself: only "no such ref" (ls-remote rc 2) counts as new; an
        # unreachable remote fails open.
        case "$PRE_COMMIT_REMOTE_BRANCH" in
            refs/heads/*)
                _short="${PRE_COMMIT_REMOTE_BRANCH#refs/heads/}"
                if [ "${BRANCH_NAME_OK:-}" != "1" ] && ! branch_name_ok "$_short"; then
                    _lsrc=0
                    # Ask the address the push goes to: a remote's pushurl can
                    # differ from its fetch url, and a bare `ls-remote <name>`
                    # queries the fetch one. git hands pre-commit
                    # the destination it is pushing to (PRE_COMMIT_REMOTE_URL),
                    # which also covers several pushurls; without it `get-url
                    # --push` gives the first pushurl, or the fetch url itself;
                    # a name git cannot resolve (a bare path or URL) is used
                    # as given.
                    _lsremote="${PRE_COMMIT_REMOTE_NAME:-origin}"
                    if [ -n "${PRE_COMMIT_REMOTE_URL:-}" ]; then
                        _lsremote="$PRE_COMMIT_REMOTE_URL"
                    else
                        _pushaddr=$(git remote get-url --push -- "$_lsremote" 2>/dev/null) || _pushaddr=""
                        [ -n "$_pushaddr" ] && _lsremote="$_pushaddr"
                    fi
                    # `--` keeps a dash-led remote name from reading as an
                    # option; a hung remote is bounded (fails open on timeout,
                    # rc 124 is not 2) where `timeout` exists.
                    if command -v timeout >/dev/null 2>&1; then
                        timeout 20 git ls-remote --exit-code --heads -- "$_lsremote" "refs/heads/$_short" >/dev/null 2>&1 || _lsrc=$?
                    else
                        git ls-remote --exit-code --heads -- "$_lsremote" "refs/heads/$_short" >/dev/null 2>&1 || _lsrc=$?
                    fi
                    [ "$_lsrc" -eq 2 ] && check_new_branch_name "$PRE_COMMIT_REMOTE_BRANCH"
                fi
                ;;
        esac
        exit 0
    fi
    # PRE_COMMIT=1 but no PRE_COMMIT_REMOTE_BRANCH: pre-commit's documented
    # pre-push env contract did not hold as expected. Fail
    # CLOSED rather than assume a benign push — a silent exit 0 here is
    # exactly the bug this ticket exists to close.
    echo "ERROR: check-push-target: pre-commit reports a pre-push hook run (PRE_COMMIT=1) but never set PRE_COMMIT_REMOTE_BRANCH — refusing the push (cannot determine the pushed ref)." >&2
    exit 1
fi

exit 0
