#!/usr/bin/env bash
# worktree-batch.sh — reclaim merged worktrees in batches of at most 10.
#
# Usage: worktree-batch.sh plan           list the next batch (read-only)
#        worktree-batch.sh apply <file>   prune each listed worktree
#
# plan reads `worktree.sh prune --dry-run`, prints the first 10 "would prune"
# paths, one per line, then "# candidates=<n> batch=<k> next-run=<m>".
# apply refuses a file listing more than 10 paths before touching any, then
# runs `worktree.sh prune --only <path>` per path, so every prune gate
# (dirty, locked, in use, open PR) still decides. A path still present after
# its prune counts as kept; a path already gone before its prune counts as absent.
# It ends with "worktree-batch: removed=<n> kept=<n> absent=<n>".
set -uo pipefail

CAP=10
WORKTREE_SH="$(cd "$(dirname "$0")/.." && pwd)/worktree.sh"

usage() { sed -n '4,5p' "$0" | sed 's/^# //'; }

case "${1:-}" in
  plan)
    cands="$(bash "$WORKTREE_SH" prune --dry-run 2>&1 | sed -n 's/^DRY clean-garden: would prune .* (\(.*\))$/\1/p')"
    n="$(printf '%s\n' "$cands" | grep -c . || true)"
    k=$(( n < CAP ? n : CAP ))
    printf '%s\n' "$cands" | grep . | head -n "$CAP" || true
    echo "# candidates=$n batch=$k next-run=$(( n - k ))"
    ;;
  apply)
    list="${2:?apply needs the file plan wrote}"
    paths="$(grep -v -e '^#' -e '^[[:space:]]*$' "$list" || true)"
    n="$(printf '%s\n' "$paths" | grep -c . || true)"
    if [ "$n" -gt "$CAP" ]; then
      echo "worktree-batch: REFUSED — $n worktrees over the cap of $CAP; nothing removed" >&2
      exit 1
    fi
    removed=0
    kept=0
    absent=0
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      if [ ! -e "$p" ]; then
        echo "ABSENT $p (already gone)"; absent=$((absent + 1)); continue
      fi
      rc=0
      bash "$WORKTREE_SH" prune --only "$p" >/dev/null 2>&1 || rc=$?
      if [ ! -e "$p" ]; then
        echo "REMOVED $p"; removed=$((removed + 1))
      else
        echo "KEPT $p (prune rc=$rc)"; kept=$((kept + 1))
      fi
    done <<< "$paths"
    echo "worktree-batch: removed=$removed kept=$kept absent=$absent"
    ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
