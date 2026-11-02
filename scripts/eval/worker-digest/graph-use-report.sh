#!/usr/bin/env bash
# scripts/eval/worker-digest/graph-use-report.sh - how much sessions actually use the code graph.
#
#   graph-use-report.sh [--days N] [--root PROJECTS_DIR]...
#
# Read-only. Scans the session journals modified in the last N days (default 7) under every PROJECTS_DIR (default: each
# ~/.claude*/projects that exists, one per lane: .claude is "claude", .claude-codex is "codex", ...). A journal is a session
# (kind "main", <project>/<session>.jsonl) or a subagent (kind "sub", <project>/<session>/subagents/*.jsonl). One table
# row per scope (all projects, then himmel projects only: the project directory name contains "himmel"), lane and kind:
# journals, journals that ran any tool, journals with a graph call, the calls per form and per kind (bare = graphify,
# wrapper = worker-graph.sh or leg-graph.sh) with the failed ones (a tool_result with is_error), journals that searched
# code and how many of those never called the graph. Nothing is written.
# ponytail: a regex lead-match, not scripts/hooks/lib/shell-tokenize.sh; the numbers are approximate (the "not counted"
# line says in which direction). Upgrade = run each command through the tokenizer.
set -u

DAYS=7
ROOTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --days) [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]] || { echo "graph-use-report: --days needs a number" >&2; exit 2; }; DAYS="$2"; shift 2 ;;
    --root) [ $# -ge 2 ] || { echo "graph-use-report: --root needs a directory" >&2; exit 2; }; ROOTS+=("$2"); shift 2 ;;
    *) echo "graph-use-report: unknown argument $1" >&2; exit 2 ;;
  esac
done
if [ ${#ROOTS[@]} -eq 0 ]; then
  for d in "$HOME"/.claude*/projects; do [ -d "$d" ] && ROOTS+=("$d"); done
fi
[ ${#ROOTS[@]} -gt 0 ] || { echo "graph-use-report: no ~/.claude*/projects directory and no --root" >&2; exit 2; }
for d in "${ROOTS[@]}"; do [ -d "$d" ] || { echo "graph-use-report: no such directory $d" >&2; exit 2; }; done
command -v jq >/dev/null || { echo "graph-use-report: jq is required" >&2; exit 2; }

# One row per journal: tools search query explain path mcp bare bare_fail wrapper wrapper_fail. A bad journal LINE is
# skipped by fromjson?; a journal jq cannot read at all fails the program and is counted by the caller.
# shellcheck disable=SC2016  # jq program, $x, $t, $g and $errs are jq variables
JQ='
  def rx(w): "(^|[;&|(\n]|-l?c\\s+[\"'"'"'])\\s*((do|then|else)\\s+)?(\\w+=\\S*\\s+)*(timeout\\s+\\d+\\s+)?(rtk\\s+(proxy\\s+)?)?(bash\\s+)?(\\S*/)?" + w + "\\s+(?<form>query|explain|path)\\b";
  def hit: . as $c
    | if ($c | test(rx("graphify"))) then {k: "bare", f: ($c | capture(rx("graphify")).form)}
      elif ($c | test(rx("(worker|leg)-graph\\.sh"))) then {k: "wrap", f: ($c | capture(rx("(worker|leg)-graph\\.sh")).form)}
      else empty end;
  [inputs | fromjson? | select(type == "object") | .message.content? | arrays | .[] | select(type == "object")
    | if .type == "tool_use" then {u: .id, n: (.name // ""), c: ((.input.command? // "") | if type == "string" then . else "" end)}
      elif .type == "tool_result" and .is_error == true then {e: .tool_use_id}
      else empty end] as $x
  | ($x | map(select(has("e")) | .e)) as $errs
  | ($x | map(select(has("u")))) as $t
  | ($t | map(select(.n == "Bash") | . as $b | ($b.c | hit) as $h | {id: $b.u, k: $h.k, f: $h.f})) as $g
  | def failed($k): $g | map(select(.k == $k and (.id as $i | any($errs[]; . == $i)))) | length;
    def n($k): $g | map(select(.k == $k)) | length;
    def form($f): $g | map(select(.f == $f)) | length;
    [ ($t | length),
      ($t | map(select(.n == "Grep" or .n == "Glob" or (.n == "Bash" and (.c | test("(^|[;&|([:space:]])(git[[:space:]]+grep|grep|egrep|fgrep|rg|ugrep)[[:space:]]")))) ) | length),
      form("query"), form("explain"), form("path"),
      ($t | map(select(.n | test("^mcp__graphify__"))) | length),
      n("bare"), failed("bare"), n("wrap"), failed("wrap") ]
  | @tsv'

TAB="$(printf '\t')"
rows=""; njournals=0; unread=0
for root in "${ROOTS[@]}"; do
  root="${root%/}"
  lane="$(basename "$(dirname "$root")")"; lane="${lane#.}"; lane="${lane#claude-}"
  while IFS= read -r -d '' f; do
    rel="${f#"$root"/}"
    case "$rel" in
      */*/subagents/*.jsonl) kind=sub ;;
      */*.jsonl) case "$rel" in */*/*) continue ;; esac; kind=main ;;
      *) continue ;;
    esac
    proj="${rel%%/*}"
    case "$proj" in *[Hh]immel*) hm=1 ;; *) hm=0 ;; esac
    # a bad journal LINE is skipped inside jq; a journal jq cannot read at all is counted and reported
    if one="$(jq -nrR "$JQ" "$f" 2>/dev/null)"; then
      njournals=$((njournals + 1))
      rows="$rows$lane$TAB$kind$TAB$hm$TAB$one"$'\n'
    else
      unread=$((unread + 1))
    fi
  done < <(find "$root" -type f -name '*.jsonl' -mtime "-$DAYS" -print0 2>/dev/null)
done

echo "graph-use-report: window ${DAYS}d, $njournals journals in ${#ROOTS[@]} roots"
echo "counted: a Bash call whose command leads with graphify, worker-graph.sh or leg-graph.sh then query, explain or path (also after cd, env, timeout N, rtk, rtk proxy, bash, bash -c or -lc, a newline, ; && |, \$( ), do or then), and every mcp__graphify__ tool call. A call failed when its tool_result has is_error. Main = a session journal, sub = a subagent journal. Scope himmel = a project directory whose name contains himmel; graph_pct = journals with a graph call over journals that ran any tool."
echo "not counted: a call behind any other wrapper (xargs, env -i, sudo, a function), a call whose command is not a string, and a call that only a pipe or a here-doc builds, so those are missed; a quoted mention such as echo \"x; graphify query y\" is counted by mistake, so the number is approximate, not a floor."
[ "$unread" -gt 0 ] && echo "journals that could not be read, left out of every number: $unread"
printf 'scope\tlane\tkind\tjournals\twith_tools\twith_graph\tgraph_pct\tcalls\tquery\texplain\tpath\tmcp\tbare\tbare_fail\twrapper\twrapper_fail\tsearched\tsearched_no_graph\n'
printf '%s' "$rows" | awk -F'\t' '
  NF == 13 {
    calls = $6 + $7 + $8 + $9
    for (s = 0; s < 2; s++) {
      if (s == 1 && $3 != 1) continue
      k = (s ? "himmel" : "all") "\t" $1 "\t" $2
      seen[k] = 1; j[k]++
      if ($4 > 0) wt[k]++
      if (calls > 0) wg[k]++
      c[k] += calls; q[k] += $6; e[k] += $7; p[k] += $8; m[k] += $9
      b[k] += $10; bf[k] += $11; w[k] += $12; wf[k] += $13
      if ($5 > 0) { se[k]++; if (calls == 0) sn[k]++ }
    }
  }
  END {
    for (k in seen)
      printf "%s\t%d\t%d\t%d\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", k, j[k], wt[k], wg[k],
        wt[k] ? sprintf("%.0f%%", 100 * wg[k] / wt[k]) : "n/a", c[k], q[k], e[k], p[k], m[k], b[k], bf[k], w[k], wf[k], se[k], sn[k]
  }' | sort -t "$TAB" -k1,1 -k2,2 -k3,3
