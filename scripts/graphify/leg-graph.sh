#!/usr/bin/env bash
# leg-graph.sh — run `graphify query|explain|path` from a leg worktree against the
# PRIMARY checkout's graphify-out/.
#
# WHY: graphify-out/ is gitignored, so a fresh worktree has no graph and a bare
# `graphify query` fails with "graph file not found". graphify honours the
# GRAPHIFY_OUT env var, but a `VAR=` prefix typed in a leg drops to the
# classifier; this wrapper sets it itself. Read-only: it never builds a graph.
#
# Usage: bash scripts/graphify/leg-graph.sh query|explain|path <graphify args...>
#   A larger default --budget (graphify's own 2000 tokens truncates most
#   answers) is added unless you pass --budget; a TRUNCATED answer gets a
#   re-run line naming this wrapper on stderr.
#   query and explain run with graphify's --rationale: a semantic node's stored `rationale` text
#   follows its NODE line as ` WHY <text>` (query) or is printed as a Rationale line (explain).
#   A query naming a file or identifier also starts from that node (anchor-seeds.py); the files
#   whose content best matches its words are added after any anchors (semantic-seeds.py).
#   A query with no anchor whose best file match is weak (semantic-seeds.py scored) and no --budget
#   of yours is answered on WEAK_BUDGET tokens under a LOW CONFIDENCE header naming that file.
#   A why/how query lists doc and rationale nodes before code symbols (rank-why-how.py).
#   If the graph's built_at_commit is behind this worktree's HEAD, a NOTE goes
#   to stderr (the answer is still printed) so a stale graph is never silent.
set -u

sub="${1:-}"
case "$sub" in
  query|explain|path) ;;
  *) echo "usage: leg-graph.sh query|explain|path <graphify args...>" >&2; exit 2 ;;
esac

common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || {
  echo "leg-graph: not inside a git checkout" >&2; exit 2; }
primary="$(dirname "$common")"
out="$primary/graphify-out"
if [ ! -f "$out/graph.json" ]; then
  echo "leg-graph: no graph at $out/graph.json (build it from the primary checkout: /graph-refresh); once built, run: bash scripts/graphify/leg-graph.sh query|explain|path \"<q>\"" >&2
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

# The question is the first argument after the verb that is neither a flag nor a flag's value.
WEAK_BUDGET=2000
has_budget=0 budget=8000 has_seed=0 question="" want="" rest=() args=() graph="$out/graph.json" lowconf="" conf="" score="" file=""
for a in "${@:2}"; do
  args+=("$a")
  if [ -n "$want" ]; then
    if [ "$want" = budget ]; then budget="$a"; else rest+=("$a"); fi
    [ "$want" = graph ] && graph="$a"
    want=""; continue
  fi
  case "$a" in
    --budget) has_budget=1; want=budget; continue ;;
    --budget=*) has_budget=1; budget="${a#--budget=}"; continue ;;
    --seed) has_seed=1; want=value ;;
    --seed=*) has_seed=1 ;;
    --graph) want=graph ;;
    --graph=*) graph="${a#--graph=}" ;;
    --context) want=value ;;
    -*) ;;
    *) if [ -z "$question" ]; then
         question="$a"
         # graphify reads the question first, so --rationale goes right after it.
         [ "$sub" = path ] || { args+=(--rationale); rest+=("$a" --rationale); continue; }
       fi ;;
  esac
  rest+=("$a")
done
set -- "$sub" "${args[@]}"

# graphify seeds on the question's words and never on a file or identifier it names (go.sh,
# leg_tail_status), so anchor-seeds.py resolves those names; the named nodes and graphify's own
# seeds then answer on half the budget each, merged with the named nodes first.
seeds=()
if [ "$sub" = query ] && [ "$has_seed" = 0 ] && [ -n "$question" ] && command -v python3 >/dev/null 2>&1; then
  case "$budget" in
    ''|*[!0-9]*) ;;
    *) budget=$((10#$budget))
       while read -r sid; do [ -n "$sid" ] && seeds+=(--seed "$sid"); done \
         < <(python3 -I "$(dirname "${BASH_SOURCE[0]}")/anchor-seeds.py" seeds "$graph" "$question")
       # A question naming no file or identifier has no anchor; semantic-seeds.py adds the files
       # whose content matches its meaning after any anchors. Its first line says how well the
       # best file matches; with no anchor and no --budget of the caller's, a weak match gets
       # WEAK_BUDGET tokens, not the full budget, and a header naming the seed.
       anchored=${#seeds[@]}
       { read -r conf score file
         while read -r sid; do
           [ -n "$sid" ] || continue
           case " ${seeds[*]} " in *" $sid "*) ;; *) seeds+=(--seed "$sid") ;; esac
         done; } < <(python3 -I "$(dirname "${BASH_SOURCE[0]}")/semantic-seeds.py" scored "$graph" "$question")
       if [ "$conf" = weak ] && [ "$anchored" = 0 ] && [ "$has_budget" = 0 ]; then
         budget=$WEAK_BUDGET
         lowconf="leg-graph: LOW CONFIDENCE seed $file (match score $score is weak for this graph); answer scaled to $WEAK_BUDGET tokens. Name a file or identifier, or pass --budget N, for the full answer."
       fi ;;
  esac
fi
[ "$has_budget" = 1 ] || set -- "$@" --budget "$budget"
if [ "${#seeds[@]}" -gt 0 ]; then
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/leg-graph.XXXXXX")" || exit 1
  trap 'rm -rf "$tmp"' EXIT
  half=$((budget / 2))
  GRAPHIFY_OUT="$out" graphify query "${rest[@]}" "${seeds[@]}" --budget "$half" >"$tmp/given" 2>"$tmp/given.err" &
  pid=$!
  ans="$(GRAPHIFY_OUT="$out" graphify query "${rest[@]}" --budget "$((budget - half))")"; rc=$?
  wait "$pid"
  cat "$tmp/given.err" >&2
  printf '%s\n' "$ans" >"$tmp/keyword"
  if merged="$(python3 -I "$(dirname "${BASH_SOURCE[0]}")/anchor-seeds.py" merge "$tmp/given" "$tmp/keyword" "$budget")"; then ans="$merged"
  else ans="$(GRAPHIFY_OUT="$out" graphify "$@")"; rc=$?; fi
else
  ans="$(GRAPHIFY_OUT="$out" graphify "$@")"; rc=$?
fi
# graphify ranks by name match, so a why/how answer led with code symbols; rank-why-how.py lists
# doc and rationale nodes first for those questions and leaves any other question untouched.
if [ "$sub" = query ] && command -v python3 >/dev/null 2>&1; then
  ranked="$(printf '%s' "$ans" | python3 -I "$(dirname "${BASH_SOURCE[0]}")/rank-why-how.py" "$graph" "$question" "$budget")" && ans="$ranked"
fi
[ -z "$lowconf" ] || [ -z "$ans" ] || printf '%s\n' "$lowconf"
printf '%s\n' "$ans"
need="$(printf '%s\n' "$ans" | grep -m1 'TRUNCATED: showing' | sed -n 's/.*--budget \([0-9][0-9]*\).*/\1/p')"
if [ -n "$need" ]; then
  shift
  rerun=""
  skip=0
  for a in "$@"; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    [ "$a" = "--budget" ] && { skip=1; continue; }
    case "$a" in --budget=*|--rationale) continue ;; esac
    q="$(printf '%s' "$a" | sed "s/'/'\\\\''/g")"
    rerun="$rerun '$q'"
  done
  echo "leg-graph: TRUNCATED answer; re-run for the full set: bash scripts/graphify/leg-graph.sh $sub$rerun --budget $need" >&2
fi
exit "$rc"
