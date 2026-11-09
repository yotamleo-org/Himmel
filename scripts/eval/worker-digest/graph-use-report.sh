#!/usr/bin/env bash
# scripts/eval/worker-digest/graph-use-report.sh - how much sessions actually use the code graph.
#
#   graph-use-report.sh [--days N] [--min-tools N] [--root PROJECTS_DIR]... [--handovers DIR]
#
# Three tables: graph use and qmd use per scope, lane, kind and role, and the graph-qmd: Results bullets per role
# (docs under --handovers, default $HANDOVER_DIR, with no bullet are no data, not zero).
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
MINTOOLS=0
UNTIL=""
HDIR="${HANDOVER_DIR:-}"
HEXPLICIT=0
ROOTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --days) [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]] || { echo "graph-use-report: --days needs a number" >&2; exit 2; }; DAYS="$2"; shift 2 ;;
    --until-epoch) [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]] || { echo "graph-use-report: --until-epoch needs epoch seconds" >&2; exit 2; }; UNTIL="$2"; shift 2 ;;
    --min-tools) [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]] || { echo "graph-use-report: --min-tools needs a number" >&2; exit 2; }; MINTOOLS="$2"; shift 2 ;;
    --handovers) [ $# -ge 2 ] || { echo "graph-use-report: --handovers needs a directory" >&2; exit 2; }; HDIR="$2"; HEXPLICIT=1; shift 2 ;;
    --root) [ $# -ge 2 ] || { echo "graph-use-report: --root needs a directory" >&2; exit 2; }; ROOTS+=("$2"); shift 2 ;;
    *) echo "graph-use-report: unknown argument $1" >&2; exit 2 ;;
  esac
done
if [ ${#ROOTS[@]} -eq 0 ]; then
  for d in "$HOME"/.claude*/projects; do [ -d "$d" ] && ROOTS+=("$d"); done
fi
[ ${#ROOTS[@]} -gt 0 ] || { echo "graph-use-report: no ~/.claude*/projects directory and no --root" >&2; exit 2; }
for d in "${ROOTS[@]}"; do [ -d "$d" ] || { echo "graph-use-report: no such directory $d" >&2; exit 2; }; done
if [ -n "$HDIR" ] && [ ! -d "$HDIR" ]; then
  [ "$HEXPLICIT" = 1 ] && { echo "graph-use-report: no such directory $HDIR" >&2; exit 2; }
  HDIR=""
fi
command -v jq >/dev/null || { echo "graph-use-report: jq is required" >&2; exit 2; }
# The window: the last DAYS days by mtime, or with --until-epoch (GNU find) the DAYS days that end at that instant, to re-run a past window.
if [ -n "$UNTIL" ]; then WIN=(-newermt "@$((10#$UNTIL - 10#$DAYS * 86400))" ! -newermt "@$((10#$UNTIL))"); else WIN=(-mtime "-$((10#$DAYS))"); fi

# One row per journal: tools search query explain path mcp bare bare_fail wrapper wrapper_fail wrapper_miss. A bad journal LINE is
# skipped by fromjson?; a journal jq cannot read at all fails the program and is counted by the caller.
# shellcheck disable=SC2016  # jq program, $x, $t, $g and $errs are jq variables
JQ='
  def lead: "(^|[;&|(\n]|\\b(ba|z)?sh\\s+-l?c\\s+[\"'"'"'])\\s*((do|then|else)\\s+)?(\\w+=\\S*\\s+)*(timeout\\s+\\d+\\s+)?(rtk\\s+(proxy\\s+)?)?((ba)?sh\\s+)?(\\S*/)?";
  def unq: gsub("(?<p>\\b(ba|z)?sh\\s+-l?c\\s+)?(?<q>\"(\\\\.|\\$\\([^)]*\\)|`[^`]*`|[^\"\\\\])*\"|'"'"'[^'"'"'\\n]*'"'"')"; if .p != null then .p + .q elif (.q | startswith("\"")) then ([.q | scan("\\$\\(([^)]*)\\)|`([^`]*)`") | .[] | select(. != null) | "; " + .] | join("")) else "" end);
  def rx(w): lead + w + "\\s+(?<form>query|explain|path)\\b";
  def rxq(w): lead + w + "\\s+(?<form>[a-z][a-z_-]*)\\b";
  def qhit: unq as $c
    | if ($c | test(rxq("qmd"))) then {k: "bare", v: ($c | capture(rxq("qmd")).form)}
      elif ($c | test(rxq("qmd-bounded\\.sh"))) then {k: "wrap", v: ($c | capture(rxq("qmd-bounded\\.sh")).form)}
      else empty end;
  def qsearch: . == "query" or . == "search" or . == "vsearch" or . == "deep_search";
  def hit: unq as $c
    | if ($c | test(rx("graphify"))) then {k: "bare", f: ($c | capture(rx("graphify")).form)}
      elif ($c | test(rx("(worker|leg)-graph\\.sh"))) then {k: "wrap", f: ($c | capture(rx("(worker|leg)-graph\\.sh")).form)}
      else empty end;
  [inputs | fromjson? | select(type == "object") | .message.content? | arrays | .[] | select(type == "object")
    | if .type == "tool_use" then {u: .id, n: (.name // ""), c: ((.input.command? // "") | if type == "string" then . else "" end)}
      elif .type == "tool_result" and .is_error == true then {r: .tool_use_id, e: .tool_use_id, m: ((.content // "") | if type == "string" then . elif type == "array" then (map(.text? // "") | join("")) else "" end | test("^Exit code [34]([^0-9]|$)"))}
      elif .type == "tool_result" then {r: .tool_use_id}
      else empty end] as $x
  | ($x | map(select(has("e")) | .e)) as $errs
  | ($x | map(select(has("e") and .m) | .e)) as $misses
  | ($x | map(select(has("r")) | .r)) as $rids
  | ($x | map(select(has("u")))) as $t
  | ($t | map(select(.n == "Bash") | . as $b | ($b.c | hit) as $h | {id: $b.u, k: $h.k, f: $h.f})) as $g
  | ($t | map(select(.n == "Bash") | . as $b | ($b.c | qhit) as $h | {id: $b.u, k: $h.k, s: ($h.v | qsearch)})) as $q
  | ($t | map(select(.n | test("^mcp__(plugin_qmd_)?qmd__")) | {id: .u, s: (.n | sub("^mcp__(plugin_qmd_)?qmd__"; "") | qsearch)})) as $m
  | ($t | map(select(.n | test("^mcp__graphify__")) | {id: .u})) as $gm
  | def failed($k): $g | map(select(.k == $k and (.id as $i | any($errs[]; . == $i)) and (.k == "bare" or (.id as $i | all($misses[]; . != $i))))) | length;
    def missed($k): $g | map(select(.k == $k and (.id as $i | any($misses[]; . == $i)))) | length;
    def n($k): $g | map(select(.k == $k)) | length;
    def form($f): $g | map(select(.f == $f)) | length;
    def qfailed($k): $q | map(select(.k == $k and (.id as $i | any($errs[]; . == $i)))) | length;
    def qn($k): $q | map(select(.k == $k)) | length;
    def bad($i): any($errs[]; . == $i);
    def got($i): any($rids[]; . == $i);
    [ ($t | length),
      ($t | map(select(.n == "Grep" or .n == "Glob" or (.n == "Bash" and (.c | test("(^|[;&|([:space:]\"'"'"'])(git[[:space:]]+grep|grep|egrep|fgrep|rg|ugrep)[[:space:]]")))) ) | length),
      form("query"), form("explain"), form("path"),
      ($t | map(select(.n | test("^mcp__graphify__"))) | length),
      n("bare"), failed("bare"), n("wrap"), failed("wrap"), missed("wrap"),
      ($q | map(select(.s)) | length), ($q | map(select(.s | not)) | length),
      ($m | map(select(.s)) | length), ($m | map(select(.s | not)) | length),
      qn("bare"), qfailed("bare"), qn("wrap"), qfailed("wrap"),
      (($g | map(select(.id as $i | got($i) and ((bad($i) | not) or (.k == "wrap" and any($misses[]; . == $i))))) | length) + ($gm | map(select(.id as $i | got($i) and (bad($i) | not))) | length)),
      (($q | map(select(.s and (.id as $i | got($i) and (bad($i) | not)))) | length) + ($m | map(select(.s and (.id as $i | got($i) and (bad($i) | not)))) | length)) ]
  | @tsv'

TAB="$(printf '\t')"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/graph-use-report.XXXXXX")" || { echo "graph-use-report: mktemp failed" >&2; exit 2; } # prim-ok: a standalone read-only report, one scratch directory, no sourced lib
trap 'rm -rf "$WORK"' EXIT
rows=""; njournals=0; unread=0; unwalked=0
for root in "${ROOTS[@]}"; do
  root="${root%/}"
  lane="$(basename "$(dirname "$root")")"; lane="${lane#.}"; lane="${lane#claude-}"
  # find's own errors (a directory it cannot read) are kept, one line each, and reported below
  find "$root" -type f -name '*.jsonl' "${WIN[@]}" -print0 >"$WORK/list" 2>"$WORK/err"
  unwalked=$((unwalked + $(grep -c . "$WORK/err")))
  while IFS= read -r -d '' f; do
    rel="${f#"$root"/}"
    case "$rel" in
      */*/subagents/*.jsonl) kind=sub ;;
      */*.jsonl) case "$rel" in */*/*) continue ;; esac; kind=main ;;
      *) continue ;;
    esac
    proj="${rel%%/*}"
    case "$proj" in *[Hh]immel*) hm=1 ;; *) hm=0 ;; esac
    # role: a subagent by its .meta.json agentType, a session by the name its journal records
    if [ "$kind" = sub ]; then
      role=sub
      if [ -r "${f%.jsonl}.meta.json" ]; then
        case "$(jq -r '.agentType // ""' "${f%.jsonl}.meta.json" 2>/dev/null)" in judge | judge-ro) role=judge ;; esac
      fi
    else
      name="$(sed -n '/"type": *"agent-name"/{s/^.*"agentName": *"\([^"]*\)".*$/\1/p;q;}' "$f" 2>/dev/null)"
      case "$name" in
        *-chief) role=console ;;
        HIMMEL-[0-9]*-N[0-9]*) role=leg ;;
        *) role=other ;;
      esac
    fi
    # a bad journal LINE is skipped inside jq; a journal jq cannot read at all is counted and reported
    if one="$(jq -nrR "$JQ" "$f" 2>/dev/null)"; then
      njournals=$((njournals + 1))
      rows="$rows$lane$TAB$kind$TAB$hm$TAB$role$TAB$one"$'\n'
    else
      unread=$((unread + 1))
    fi
  done <"$WORK/list"
done

echo "graph-use-report: window ${DAYS}d${UNTIL:+ ending at epoch $UNTIL}, $njournals journals in ${#ROOTS[@]} roots"
echo "counted: a Bash call whose command leads with graphify, worker-graph.sh or leg-graph.sh then query, explain or path, and every mcp__graphify__ tool call (graph); a Bash call whose command leads with qmd or qmd-bounded.sh then a verb, and every mcp__qmd__ or mcp__plugin_qmd_qmd__ tool call (qmd), with the search verbs query, search, vsearch and deep_search apart from every other verb (status, update, embed, get, multi_get and the rest). A command leads when it starts or follows cd, env, timeout N, rtk, rtk proxy, bash, sh, bash -c or -lc, a newline, ; && |, \$( ), do or then. Text inside a quoted string is read only when the quote follows bash -c, bash -lc or sh -c (a shell body) or is a command substitution, \$( ) or a backtick pair, inside a double-quoted string, quotes inside the substitution included (that part runs, the text around it does not); a single-quoted string ends at the end of its line, so an apostrophe in a here-doc body hides no later call. So echo \"x; graphify query y\" is not a call. A path that only names a script (cat, ls or git log of scripts/lib/qmd-bounded.sh) is not a call. A call failed when its tool_result has is_error, except that an exit 3 or exit 4 of worker-graph.sh or leg-graph.sh (no match, ambiguous) is a miss, an honest no-answer, not a failure (wrapper_miss; a bare graphify keeps bare_fail, and a qmd call is unchanged). Main = a session journal, sub = a subagent journal. Role: a main journal whose recorded name ends in -chief is console, one named HIMMEL-<key>-N<n>... is leg, any other or no name is other; a subagent journal whose .meta.json agentType is judge or judge-ro is judge, any other subagent is sub. Scope himmel = a project directory whose name contains himmel. graph_pct and qmd_pct = journals with a call over journals that ran any tool; search_pct = journals with a qmd search call over the same. A refused or failed call still counts as a call there, so the decision numbers are the answered ones: with_graph_ok and graph_ok_pct = journals with at least one answered graph call (its tool_result exists and is not is_error; a wrapper exit 3 or 4 miss counts as answered; a call with no tool_result, such as a session that ended mid-call, is not answered), with_search_ok and search_ok_pct the same for qmd search calls, and searched_no_graph = journals that searched with no answered graph call. The fail columns are a floor: output piped to another command (| head) hides a failing exit status. searched = journals with a Grep or Glob call or a Bash command that has grep, rg or ugrep after a command boundary or a quote, so it counts mentions, not use (echo use grep here counts)."
echo "bullets: one row per role over the handover docs under --handovers (default \$HANDOVER_DIR) changed in the window that have a ## Results heading; role by file name: *-chief* is console, HIMMEL-<key>-N<n>... is leg, any other is other. A doc's graph-qmd: bullet is used_or_cited when it says used or cited (and not not used), called_only when it names results without that, none_found for none found, na_shipping for n/a; a doc with no bullet is no_data, not a zero. The words are the worker's own claim, not a check. --min-tools N keeps only journals that ran at least N tools (the audit's population is 5)."
echo "not counted: a call behind any other wrapper (xargs, env -i, sudo, a function), a call whose command is not a string, a call that only a pipe builds, and the second graph call (or second qmd call) of a command that holds two (one command counts once per tool, a bare call before a wrapper call), so those are missed; a line inside a here-doc that begins like a call, and a quoted mention inside a single-quoted string that spans lines, are counted by mistake; a substitution body with nested parentheses is missed, and a double quote or backtick inside a here-doc body can hide a later call, so the numbers are approximate, not a floor."
[ "$unread" -gt 0 ] && echo "journals that could not be read, left out of every number: $unread"
[ "$unwalked" -gt 0 ] && echo "directories that could not be walked, journals under them left out of every number: $unwalked"
# A journal row is: lane kind himmel role, then tools searched query explain path mcp bare bare_fail wrapper wrapper_fail wrapper_miss,
# then qmd shell_search shell_other mcp_search mcp_other bare bare_fail wrapper wrapper_fail, then graph_ok and search_ok (calls that were
# answered: not failed, a wrapper miss counts as answered).
echo "== graph =="
printf 'scope\tlane\tkind\trole\tjournals\twith_tools\twith_graph\tgraph_pct\twith_graph_ok\tgraph_ok_pct\tcalls\tquery\texplain\tpath\tmcp\tbare\tbare_fail\twrapper\twrapper_fail\twrapper_miss\tsearched\tsearched_no_graph\n'
printf '%s' "$rows" | awk -F'\t' -v mt="$MINTOOLS" '
  NF == 25 && $5 >= mt {
    calls = $7 + $8 + $9 + $10
    for (s = 0; s < 2; s++) {
      if (s == 1 && $3 != 1) continue
      k = (s ? "himmel" : "all") "\t" $1 "\t" $2 "\t" $4
      seen[k] = 1; j[k]++
      if ($5 > 0) wt[k]++
      if (calls > 0) wg[k]++
      if ($24 > 0) wgo[k]++
      c[k] += calls; q[k] += $7; e[k] += $8; p[k] += $9; m[k] += $10
      b[k] += $11; bf[k] += $12; w[k] += $13; wf[k] += $14; wm[k] += $15
      if ($6 > 0) { se[k]++; if ($24 == 0) sn[k]++ }
    }
  }
  END {
    for (k in seen)
      printf "%s\t%d\t%d\t%d\t%s\t%d\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", k, j[k], wt[k], wg[k],
        wt[k] ? sprintf("%.0f%%", 100 * wg[k] / wt[k]) : "n/a", wgo[k], wt[k] ? sprintf("%.0f%%", 100 * wgo[k] / wt[k]) : "n/a", c[k], q[k], e[k], p[k], m[k], b[k], bf[k], w[k], wf[k], wm[k], se[k], sn[k]
  }' | sort -t "$TAB" -k1,1 -k2,2 -k3,3 -k4,4
echo "== qmd =="
printf 'scope\tlane\tkind\trole\tjournals\twith_tools\twith_qmd\tqmd_pct\twith_search\tsearch_pct\twith_search_ok\tsearch_ok_pct\tcalls\tsearch_shell\tsearch_mcp\tother_shell\tother_mcp\tbare\tbare_fail\twrapper\twrapper_fail\n'
printf '%s' "$rows" | awk -F'\t' -v mt="$MINTOOLS" '
  NF == 25 && $5 >= mt {
    calls = $16 + $17 + $18 + $19
    srch = $16 + $18
    for (s = 0; s < 2; s++) {
      if (s == 1 && $3 != 1) continue
      k = (s ? "himmel" : "all") "\t" $1 "\t" $2 "\t" $4
      seen[k] = 1; j[k]++
      if ($5 > 0) wt[k]++
      if (calls > 0) wq[k]++
      if (srch > 0) ws[k]++
      if ($25 > 0) wso[k]++
      c[k] += calls; ss[k] += $16; so[k] += $17; ms[k] += $18; mo[k] += $19
      b[k] += $20; bf[k] += $21; w[k] += $22; wf[k] += $23
    }
  }
  END {
    for (k in seen)
      printf "%s\t%d\t%d\t%d\t%s\t%d\t%s\t%d\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", k, j[k], wt[k], wq[k],
        wt[k] ? sprintf("%.0f%%", 100 * wq[k] / wt[k]) : "n/a", ws[k], wt[k] ? sprintf("%.0f%%", 100 * ws[k] / wt[k]) : "n/a",
        wso[k], wt[k] ? sprintf("%.0f%%", 100 * wso[k] / wt[k]) : "n/a",
        c[k], ss[k], ms[k], so[k], mo[k], b[k], bf[k], w[k], wf[k]
  }' | sort -t "$TAB" -k1,1 -k2,2 -k3,3 -k4,4

# The graph-qmd: Results bullets: the only record of whether a worker cited or used what the notes search and the graph
# returned. One row per role over the handover docs (a doc with a ## Results heading) changed in the window. A doc with no
# bullet is no_data, never a zero; a bullet that is n/a (shipping) is na_shipping and carries no signal either.
if [ -n "$HDIR" ]; then
  hrows=""
  while IFS= read -r -d '' d; do
    grep -q '^## Results' "$d" 2>/dev/null || continue
    case "$(basename "$d")" in
      *-chief*) role=console ;;
      HIMMEL-[0-9]*-N[0-9]*) role=leg ;;
      *) role=other ;;
    esac
    st="$(awk '
      /^## Results/ { r = 1; next }
      /^## / { r = 0 }
      r && /^- .*graph-qmd:/ {
        t = $0; sub(/^.*graph-qmd:/, "", t); t = tolower(t)
        if (t ~ /^ *n\/a/) s = 1
        else if (t ~ /(used|cited)/ && t !~ /(not used|did not use|unused|never used|not cited|neither|none of)/) s = 4
        else if (t ~ /none found/) s = 2
        else s = 3
        if (s > best) best = s
      }
      END { print best + 0 }' "$d" 2>/dev/null)"
    hrows="$hrows$role$TAB${st:-0}"$'\n'
  done < <(find "$HDIR" -type f -name '*.md' "${WIN[@]}" -not -path '*/specs/*' -not -path '*/verdicts/*' -print0 2>"$WORK/herr")
  hunwalked=$(grep -c . "$WORK/herr")
  [ "$hunwalked" -gt 0 ] && echo "handover directories that could not be walked, docs under them left out of the bullets table: $hunwalked"
  echo "== bullets =="
  printf 'role\tdocs\twith_bullet\tused_or_cited\tcalled_only\tnone_found\tna_shipping\tno_data\n'
  printf '%s' "$hrows" | awk -F'\t' '
    NF == 2 {
      seen[$1] = 1; d[$1]++
      if ($2 > 0) wb[$1]++
      if ($2 == 4) u[$1]++; else if ($2 == 3) ca[$1]++; else if ($2 == 2) nf[$1]++; else if ($2 == 1) na[$1]++
    }
    END { for (r in seen) printf "%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", r, d[r], wb[r], u[r], ca[r], nf[r], na[r], d[r] - wb[r] }' | sort
fi
