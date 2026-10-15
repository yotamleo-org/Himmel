#!/usr/bin/env bash
# leg-graph.sh — run `graphify query|explain` from a leg worktree against the
# PRIMARY checkout's graphify-out/.
#
# WHY: graphify-out/ is gitignored, so a fresh worktree has no graph and a bare
# `graphify query` fails with "graph file not found". graphify honours the
# GRAPHIFY_OUT env var, but a `VAR=` prefix typed in a leg drops to the
# classifier; this wrapper sets it itself. Read-only: it never builds a graph.
#
# Usage: bash scripts/graphify/leg-graph.sh query|explain <graphify args...>
#   `path` is refused: node ids are file-scoped, so cross-file paths are wrong.
#   If the graph's built_at_commit is behind this worktree's HEAD, a NOTE goes
#   to stderr (the answer is still printed) so a stale graph is never silent.
set -u

sub="${1:-}"
case "$sub" in
  query|explain) ;;
  path) echo "leg-graph: refused: 'graphify path' is broken (file-scoped node ids); use query or explain" >&2; exit 2 ;;
  *) echo "usage: leg-graph.sh query|explain <graphify args...>" >&2; exit 2 ;;
esac

common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || {
  echo "leg-graph: not inside a git checkout" >&2; exit 2; }
primary="$(dirname "$common")"
out="$primary/graphify-out"
if [ ! -f "$out/graph.json" ]; then
  echo "leg-graph: no graph at $out/graph.json (build it from the primary checkout: /graph-refresh)" >&2
  exit 2
fi

built="$(grep -o '"built_at_commit": *"[0-9a-f]*"' "$out/graph.json" | head -1 | sed 's/.*: *"//;s/"$//')"
if [ -z "$built" ]; then
  echo "leg-graph: NOTE graph records no built_at_commit; freshness unknown" >&2
elif ! git cat-file -e "$built^{commit}" 2>/dev/null || ! git merge-base --is-ancestor "$built" HEAD 2>/dev/null; then
  echo "leg-graph: NOTE graph built at ${built:0:9} is not an ancestor of this worktree's HEAD; it may differ from your tree" >&2
else
  n="$(git rev-list --count "$built..HEAD")"
  [ "$n" -gt 0 ] && echo "leg-graph: NOTE graph built at ${built:0:9} is $n commits behind this worktree's HEAD; recent changes are missing" >&2
fi

GRAPHIFY_OUT="$out" exec graphify "$@"
