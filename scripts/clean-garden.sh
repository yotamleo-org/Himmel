#!/usr/bin/env bash
# DEPRECATED forwarder, kept so old callers keep working.
# The orchestrator is scripts/worktree.sh: `worktree.sh new <branch>` prunes
# then creates, `worktree.sh prune` prunes only. This script prints one stderr
# line naming the replacement, then runs it with the same meaning: any
# branch-name means `new`, none means `prune`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

has_branch=0
skip=0
for arg in "$@"; do
    if [ "$skip" -eq 1 ]; then skip=0; continue; fi
    case "$arg" in
        --only) skip=1 ;;
        -*) ;;
        *) has_branch=1 ;;
    esac
done

if [ "$has_branch" -eq 1 ]; then verb=new; else verb=prune; fi
echo "clean-garden.sh is deprecated: use 'bash scripts/worktree.sh $verb' instead" >&2
exec bash "$SCRIPT_DIR/worktree.sh" "$verb" "$@"
