#!/usr/bin/env bash
# push-wrapper.sh — POC. The only path by which a sandboxed worker's
# commits reach a remote. It runs OUTSIDE the sandbox (it is the holder of the
# push credential) and pushes ONE branch, the worker's own, as a plain
# fast-forward push.
#
#   push-wrapper.sh --worker-branch <branch> -- <git push args...>
#
# --worker-branch comes from the launcher that started the worker, never from the
# request, so a worker cannot name a different branch for itself. Refused, exit 20
# (nothing is pushed): any force flag, a +refspec, a delete (--delete, :ref),
# --mirror/--all/--prune/--tags, main/master, any branch but --worker-branch, and
# a URL or path as the remote (only a configured remote name).
#
# ponytail: argument-shape policy only; it does not see the remote's own
# protections, and the build phase routes it through the trust-path
# judge and installs it at the primary-checkout anchor path.
set -u
# the full repository-redirecting set, as scripts/lib/git-clean.sh git_env_scrub
# (inline: this script runs where the lib may not be reachable)
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
    GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX \
    GIT_IMPLICIT_WORK_TREE GIT_GRAFT_FILE \
    GIT_REPLACE_REF_BASE GIT_SHALLOW_FILE GIT_CONFIG \
    GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT

REFUSE_RC=20

refuse() {
    echo "push-wrapper: REFUSED $*" >&2
    exit "$REFUSE_RC"
}

worker_branch=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --worker-branch)
            [ "$#" -ge 2 ] || refuse "--worker-branch needs a value"
            worker_branch="$2"
            shift 2
            ;;
        --) shift; break ;;
        *) refuse "unexpected wrapper argument: $1" ;;
    esac
done

[ -n "$worker_branch" ] || refuse "no --worker-branch"
case "$worker_branch" in
    main|master|HEAD|"") refuse "worker branch is protected: $worker_branch" ;;
esac

remote=""
refspecs=""
flags=""
for a in "$@"; do
    case "$a" in
        -f|--force|--force-with-lease|--force-with-lease=*|--force-if-includes|--no-force-with-lease)
            refuse "force flag: $a" ;;
        --delete|-d) refuse "delete: $a" ;;
        --mirror|--all|--prune|--tags|--follow-tags) refuse "bulk push flag: $a" ;;
        --receive-pack=*|--exec=*|--repo=*) refuse "redirecting flag: $a" ;;
        -u|--set-upstream|-q|--quiet|-v|--verbose|--dry-run|-n) flags="$flags $a" ;;
        -*) refuse "unknown flag: $a" ;;
        *)
            if [ -z "$remote" ]; then
                remote="$a"
            else
                refspecs="$refspecs $a"
            fi
            ;;
    esac
done

[ -n "$remote" ] || refuse "no remote"
printf '%s' "$remote" | grep -Eq '^[A-Za-z0-9_.-]+$' || refuse "remote must be a configured remote name, got: $remote" # pipefail-ok: input is one short word
[ -n "$refspecs" ] || refuse "no refspec"

for spec in $refspecs; do
    case "$spec" in
        +*) refuse "+refspec (force): $spec" ;;
        :*) refuse "delete refspec: $spec" ;;
    esac
    dst="${spec#*:}"
    [ "$dst" = "$spec" ] && dst="$spec"
    dst="${dst#refs/heads/}"
    case "$dst" in
        main|master) refuse "push to protected branch: $dst" ;;
    esac
    [ "$dst" = "$worker_branch" ] || refuse "branch is not this worker's own ($worker_branch): $dst"
done

# shellcheck disable=SC2086 # flags and refspecs are validated words
# Hooks are disabled because this runs OUTSIDE the sandbox in a worker-writable
# worktree. Config-injected commands (core.sshCommand, credential helpers,
# includeIf) in the worker's .git/config are NOT closed here: the production
# broker must push from a launcher-owned clone instead.
exec git -c core.hooksPath=/dev/null push $flags "$remote" $refspecs
