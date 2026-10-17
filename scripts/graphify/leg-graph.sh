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
#   A larger default --budget (graphify's own 2000 tokens truncates most
#   answers) is added unless you pass --budget; a TRUNCATED answer gets a
#   re-run line naming this wrapper on stderr.
#   A semantic node's stored `rationale` text (the WHY graphify keeps but never prints) is added
#   under its NODE line (query) or as a Rationale line (explain).
#   A why/how query lists doc and rationale nodes before code symbols (rank-why-how.py).
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
  echo "leg-graph: no graph at $out/graph.json (build it from the primary checkout: /graph-refresh); once built, run: bash scripts/graphify/leg-graph.sh query|explain \"<q>\"" >&2
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

has_budget=0
for a in "$@"; do case "$a" in --budget|--budget=*) has_budget=1 ;; esac; done
[ "$has_budget" = 1 ] || set -- "$@" --budget 8000

ans="$(GRAPHIFY_OUT="$out" graphify "$@")"; rc=$?
# graphify stores a semantic node's WHY as `rationale` but neither verb prints it, so a "why"
# question got a pointer to a doc section; append-rationale.py adds the stored text.
if command -v python3 >/dev/null 2>&1; then
  withwhy="$(printf '%s' "$ans" | python3 -I "$(dirname "${BASH_SOURCE[0]}")/append-rationale.py" "$out/graph.json")" && ans="$withwhy"
  # graphify ranks by name match, so a why/how answer led with code symbols; rank-why-how.py lists
  # doc and rationale nodes first for those questions and leaves any other question untouched.
  if [ "$sub" = query ]; then
    ranked="$(printf '%s' "$ans" | python3 -I "$(dirname "${BASH_SOURCE[0]}")/rank-why-how.py" "$out/graph.json" "${2:-}")" && ans="$ranked"
  fi
fi
printf '%s\n' "$ans"
need="$(printf '%s\n' "$ans" | grep -m1 'TRUNCATED: showing' | sed -n 's/.*--budget \([0-9][0-9]*\).*/\1/p')"
if [ -n "$need" ]; then
  shift
  rerun=""
  skip=0
  for a in "$@"; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    [ "$a" = "--budget" ] && { skip=1; continue; }
    case "$a" in --budget=*) continue ;; esac
    q="$(printf '%s' "$a" | sed "s/'/'\\\\''/g")"
    rerun="$rerun '$q'"
  done
  echo "leg-graph: TRUNCATED answer; re-run for the full set: bash scripts/graphify/leg-graph.sh $sub$rerun --budget $need" >&2
fi
exit "$rc"
