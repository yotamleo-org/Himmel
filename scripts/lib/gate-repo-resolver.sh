#!/usr/bin/env bash
# scripts/lib/gate-repo-resolver.sh - sourced: the checkout a chief gate script gates.
#
# gate_repo_dir <name> <relative-tail> <notdir-tail>
#   Prints the gated checkout: HIMMEL_REPO when it is an absolute path, else the
#   primary checkout of the tree this file sits in (the sourcing script's own tree),
#   else that tree's root. Never the caller's cwd, and the one git read runs with
#   git-clean.sh's whole GIT_* list cleared.
#   A relative HIMMEL_REPO, or a result that is not a directory, prints one
#   "<name>: ..." line on stderr ending in <relative-tail> or <notdir-tail> and
#   returns 1; the caller exits with its own code.
# shellcheck source=scripts/lib/git-clean.sh
# shellcheck disable=SC1091
_GATE_REPO_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || return 1
. "$_GATE_REPO_LIB_DIR/git-clean.sh" || return 1

gate_repo_dir() {
    local dir
    case "${HIMMEL_REPO:-}" in
        /*) dir=$HIMMEL_REPO ;;
        '') dir=$(git_clean -C "$_GATE_REPO_LIB_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || dir=""  # swallow-ok: a tree outside git reads empty, which falls back to the tree root below
            dir=${dir%/.git} ;;
        *) echo "$1: HIMMEL_REPO ($HIMMEL_REPO) is not an absolute path - refusing to let it pick the gated checkout$2" >&2
           return 1 ;;
    esac
    [ -n "$dir" ] || dir=$(cd "$_GATE_REPO_LIB_DIR/../.." && pwd)
    if [ ! -d "$dir" ]; then
        echo "$1: the gated checkout HIMMEL_REPO ($dir) is not a directory$3" >&2
        return 1
    fi
    printf '%s\n' "$dir"
}
