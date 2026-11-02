#!/usr/bin/env bash
# scripts/eval/worker-digest/graph-use-report.sh - how much sessions actually use the code graph.
#
#   graph-use-report.sh [--days N] [--root DIR]
#
# Read-only. Scans the session journals under DIR (default ~/.claude/projects/*/*.jsonl, top-level sessions only)
# modified in the last N days (default 7) and prints, per query form (query, explain, path, mcp) the call count and
# the number of sessions that used it, then the share of sessions that searched code (Grep/Glob or a grep, rg, ugrep,
# git grep command) and never called the graph. A form counts only when it leads a command (past cd, env, rtk,
# bash, bash -c), so `git grep "graphify query"` is a search, not a graph call. Nothing is written.
# ponytail: a regex lead-match, not scripts/hooks/lib/shell-tokenize.sh; a graph call after a pipe or inside $(...) is
# missed, so the numbers undercount. Upgrade = run each command through the tokenizer.
set -u

DAYS=7
ROOT="${HOME}/.claude/projects"
while [ $# -gt 0 ]; do
  case "$1" in
    --days) [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]] || { echo "graph-use-report: --days needs a number" >&2; exit 2; }; DAYS="$2"; shift 2 ;;
    --root) [ $# -ge 2 ] || { echo "graph-use-report: --root needs a directory" >&2; exit 2; }; ROOT="$2"; shift 2 ;;
    *) echo "graph-use-report: unknown argument $1" >&2; exit 2 ;;
  esac
done
[ -d "$ROOT" ] || { echo "graph-use-report: no such directory $ROOT" >&2; exit 2; }
command -v jq >/dev/null || { echo "graph-use-report: jq is required" >&2; exit 2; }

# One row per session: query explain path mcp search (counts). A bad journal line is skipped, never fatal.
# shellcheck disable=SC2016  # jq program, $b and $t are jq variables
JQ='
  def lead(v): "(^|[;&|(]|-c\\s+[\"'"'"'])\\s*(\\w+=\\S*\\s+)*(rtk\\s+)?(bash\\s+)?(\\S*/)?(graphify|worker-graph\\.sh|leg-graph\\.sh)\\s+" + v + "\\b";
  [inputs | fromjson? | select(type == "object" and .type == "assistant") | .message.content? | arrays | .[]
    | select(type == "object" and .type == "tool_use")] as $t
  | ([$t[] | select(.name == "Bash") | (.input.command? // "") | strings]) as $b
  | [ ($b | map(select(test(lead("query")))) | length),
      ($b | map(select(test(lead("explain")))) | length),
      ($b | map(select(test(lead("path")))) | length),
      ([$t[] | select((.name // "") | test("^mcp__graphify__"))] | length),
      (([$t[] | select(.name == "Grep" or .name == "Glob")] | length)
        + ($b | map(select(test("(^|[;&|([:space:]])(git[[:space:]]+grep|grep|egrep|fgrep|rg|ugrep)[[:space:]]"))) | length)) ]
  | @tsv'

rows=""
for f in "$ROOT"/*/*.jsonl; do
  [ -f "$f" ] || continue
  [ -n "$(find "$f" -mtime "-$DAYS" -print 2>/dev/null)" ] || continue
  rows="$rows$(jq -nrR "$JQ" "$f" 2>/dev/null)"$'\n'
done

printf '%s\n' "$rows" | awk -F'\t' -v days="$DAYS" '
  NF == 5 {
    n++
    split("query explain path mcp", name, " ")
    any = 0
    for (i = 1; i <= 4; i++) { calls[i] += $i; if ($i > 0) { sess[i]++; any = 1 } }
    if (any) { users++; total += $1 + $2 + $3 + $4 }
    if ($5 > 0) { searched++; if (!any) blind++ }
  }
  END {
    printf "graph-use-report: window %sd, %d sessions\n", days, n
    printf "form\tcalls\tsessions\n"
    for (i = 1; i <= 4; i++) printf "%s\t%d\t%d\n", name[i], calls[i], sess[i]
    printf "any\t%d\t%d\n", total, users
    printf "sessions that searched code: %d, of which never called the graph: %d (%s)\n", searched, blind, searched ? sprintf("%.0f%%", 100 * blind / searched) : "n/a"
    printf "graph calls per graph-using session: %s\n", users ? sprintf("%.2f", total / users) : "n/a"
  }'
