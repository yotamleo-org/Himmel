#!/usr/bin/env bash
# scripts/eval/worker-digest/test-graph-use-report.sh - hermetic suite for graph-use-report.sh.
# fixtures/graph-use holds two journal roots, claude/projects and claude-codex/projects:
#   claude, project -x-himmel: s1 explain+path(fails)+git grep, s2 three bare queries + one worker-graph.sh explain, s2/subagents/a1 one
#     explain (a subagent journal), s3 one mcp call, s4 rg only;
#   claude, project -x-other: s5 Read only, s6 a git grep that merely names "graphify query", s7 a bad line + a wrapper explain;
#   claude-codex, project -x-himmel: c1 two leg-graph.sh calls (the second fails), c2 no tool at all.
# check() evals its condition, so the single quotes are deliberate.
# shellcheck disable=SC2016
set -u
# the report reads $HANDOVER_DIR by default; this suite names its handover fixtures explicitly
unset HANDOVER_DIR
HERE="$(cd "$(dirname "$0")" && pwd)"
RPT="$HERE/graph-use-report.sh"
FX="$HERE/fixtures/graph-use"
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

OUT="$(bash "$RPT" --days 36500 --root "$FX/claude/projects" --root "$FX/claude-codex/projects" 2>&1)"
# shellcheck disable=SC2034
OUTRC=$?
check "the report over the fixtures exits 0" '[ "$OUTRC" = 0 ]'
# cell <scope> <lane> <kind> <column name>: one cell of the table
# SEC picks the table (graph, the default, or qmd), ROLE narrows it to one role
cell() { printf '%s\n' "$OUT" | awk -F'\t' -v s="$1" -v l="$2" -v k="$3" -v c="$4" -v sec="${SEC:-graph}" -v r="${ROLE:-}" '
  /^== / { split($0, a, " "); cur = a[2]; next }
  cur == sec && $1 == "scope" { for (i = 1; i <= NF; i++) if ($i == c) col = i }
  cur == sec && $1 == s && $2 == l && $3 == k && (r == "" || $4 == r) { print $col }'; }
# cells <scope> <lane> <kind> <column>...: several cells joined by /
cells() { s="$1"; l="$2"; k="$3"; shift 3; out=""; for c in "$@"; do out="$out/$(cell "$s" "$l" "$k" "$c")"; done; echo "${out#/}"; }

check "the report reads 8 + 1 + 2 = 11 journals from two roots and says so" 'grep -q "^graph-use-report: window 36500d, 11 journals in 2 roots" <<<"$OUT"'
check "claude main, all projects: 8 journals, 8 with a tool, 5 with a graph call, 13 calls" '[ "$(cells all claude main journals with_tools with_graph calls)" = 8/8/5/13 ]'
check "claude main forms: 4 query, 6 explain, 2 path, 1 mcp" '[ "$(cells all claude main query explain path mcp)" = 4/6/2/1 ]'
check "claude main outcomes: 10 bare calls 1 failed, 2 wrapper calls 0 failed" '[ "$(cells all claude main bare bare_fail wrapper wrapper_fail)" = 10/1/2/0 ]'
check "claude main search: 3 searched code, 2 of them never called the graph" '[ "$(cells all claude main searched searched_no_graph)" = 3/2 ]'
check "a git grep that names graphify query is a search, not a graph call" '[ "$(cell all claude main query)" = 4 ]'
check "the subagent journal is its own row: 1 journal, 1 call, 1 explain" '[ "$(cells all claude sub journals with_graph calls explain)" = 1/1/1/1 ]'
check "the second root is its own lane: 2 journals, 1 with a tool, 2 wrapper calls, 1 failed" '[ "$(cells all codex main journals with_tools calls wrapper wrapper_fail)" = 2/1/2/2/1 ]'
check "himmel projects get their own rows: claude main 5 journals, 4 with a graph call, 12 calls" '[ "$(cells himmel claude main journals with_graph calls)" = 5/4/12 ]'
check "himmel projects leave out the other project: claude main query/explain/path/mcp = 4/5/2/1" '[ "$(cells himmel claude main query explain path mcp)" = 4/5/2/1 ]'
check "the share of tool-using himmel claude main journals that called the graph is 80%, and that got an answer 80% (the failed path call sits beside an answered explain)" '[ "$(cells himmel claude main graph_pct graph_ok_pct)" = "80%/80%" ]'
check "the report states what is counted and what is not" 'grep -q "^counted:" <<<"$OUT" && grep -q "^not counted:" <<<"$OUT"'

# qmd: fixtures/graph-use-qmd holds a console, a leg, two unnamed journals (one outside himmel), a judge and an Explore subagent.
# shellcheck disable=SC2034
QOUT="$(bash "$RPT" --days 36500 --root "$FX/../graph-use-qmd/claude/projects" 2>&1)"
# shellcheck disable=SC2034
QRC=$?
check "the qmd fixtures report exits 0 and prints a graph and a qmd table" '[ "$QRC" = 0 ] && grep -q "^== graph ==" <<<"$QOUT" && grep -q "^== qmd ==" <<<"$QOUT"'
# qcells <scope> <role> <kind> <column>...: columns of the qmd table's claude row for that role, joined by /
qcells() { s="$1"; r="$2"; k="$3"; shift 3; out=""; for c in "$@"; do out="$out/$(OUT="$QOUT" SEC=qmd ROLE="$r" cell "$s" claude "$k" "$c")"; done; echo "${out#/}"; }
check "the console journal (name ends in -chief): 4 calls, 1 shell search, 1 mcp search (plugin name), 1 shell status, 1 mcp get, 2 wrapper" '[ "$(qcells all console main calls search_shell search_mcp other_shell other_mcp wrapper)" = 4/1/1/1/1/2 ]'
check "the leg journal (HIMMEL-<key>-N<n>): a bare qmd query that failed and an env-prefixed sh qmd-bounded.sh search: 2 searches, 1 bare 1 failed, 1 wrapper" '[ "$(qcells all leg main search_shell bare bare_fail wrapper)" = 2/1/1/1 ]'
check "cat, git log and ls naming qmd-bounded.sh are not calls: the leg row holds 2 calls, not 4" '[ "$(qcells all leg main calls)" = 2 ]'
check "an unnamed journal is role other; an echo that quotes the wrapper is not a call, an update after cd is a call but not a search" '[ "$(qcells himmel other main journals calls other_shell with_search)" = 1/1/1/0 ]'
check "all projects add the journal outside himmel to role other: 2 journals, 1 with a search" '[ "$(qcells all other main journals with_search)" = 2/1 ]'
check "a judge-ro subagent is role judge, any other subagent is role sub" '[ "$(qcells all judge sub calls search_shell)" = 1/1 ] && [ "$(qcells all sub sub calls search_mcp)" = 1/1 ]'
check "search_pct is journals with a qmd search over journals that ran a tool" '[ "$(qcells all other main search_pct)" = 50% ]'

# bullets: fixtures/graph-use-qmd/handovers holds 5 leg docs, 1 chief doc and 1 doc without a Results heading.
# shellcheck disable=SC2034
BOUT="$(bash "$RPT" --days 36500 --root "$FX/../graph-use-qmd/claude/projects" --handovers "$FX/../graph-use-qmd/handovers" 2>&1)"
# brow <role> <column>: one cell of the bullets table
brow() { printf '%s\n' "$BOUT" | awk -F'\t' -v r="$1" -v c="$2" '
  /^== / { split($0, a, " "); cur = a[2]; next }
  cur == "bullets" && $1 == "role" { for (i = 1; i <= NF; i++) if ($i == c) col = i }
  cur == "bullets" && $1 == r { print $col }'; }
check "the bullets table counts 5 leg docs: 1 used or cited, 1 called only, 1 none found, 1 n/a shipping, 1 with no bullet" '[ "$(brow leg docs)/$(brow leg used_or_cited)/$(brow leg called_only)/$(brow leg none_found)/$(brow leg na_shipping)/$(brow leg no_data)" = 5/1/1/1/1/1 ]'
check "a doc with no bullet is no_data and not a zero: with_bullet is 4 of 5 for leg" '[ "$(brow leg with_bullet)" = 4 ]'
check "the chief doc is role console, its bullet cites the audit" '[ "$(brow console docs)/$(brow console used_or_cited)" = 1/1 ]'
check "a doc without a Results heading is not counted and has no role row" '[ -z "$(brow other docs)" ]'
check "a bullet before the Results heading is not read: the leg doc that has one stays no_data, used_or_cited stays 1" '[ "$(brow leg no_data)/$(brow leg used_or_cited)" = 1/1 ]'
check "--handovers with a missing directory exits 2" 'bash "$RPT" --handovers "$FX/no-such-dir" >/dev/null 2>&1; [ $? = 2 ]'
# shellcheck disable=SC2034
MOUT="$(bash "$RPT" --days 36500 --min-tools 5 --root "$FX/../graph-use-qmd/claude/projects" 2>&1)"
check "--min-tools 5 keeps the leg journal (5 tools) and drops the console journal (4 tools)" '[ "$(OUT="$MOUT" SEC=qmd ROLE=leg cell all claude main journals)" = 1 ] && [ -z "$(OUT="$MOUT" SEC=qmd ROLE=console cell all claude main journals)" ]'
check "--until-epoch in the past leaves out journals changed since: 0 journals, and says where the window ends" 'grep -q "window 36500d ending at epoch 1000000000, 0 journals" <<<"$(bash "$RPT" --days 36500 --until-epoch 1000000000 --root "$FX/claude/projects" 2>&1)"'
check "--until-epoch in the year 2100 keeps them: 8 + 1 journals under the claude fixture root" 'grep -q "ending at epoch 4102444800, 9 journals in 1 roots" <<<"$(bash "$RPT" --days 36500 --until-epoch 4102444800 --root "$FX/claude/projects" 2>&1)"'
check "--until-epoch needs a number" 'bash "$RPT" --until-epoch x >/dev/null 2>&1; [ $? = 2 ]'
check "--min-tools needs a number" 'bash "$RPT" --min-tools x >/dev/null 2>&1; [ $? = 2 ]'

# ZERO and ZRC are read inside check()'s eval.
# shellcheck disable=SC2034
ZERO="$(bash "$RPT" --days 0 --root "$FX/claude/projects" 2>&1)"
# shellcheck disable=SC2034
ZRC=$?
check "a window that excludes the fixture exits 0, reads 0 journals and prints no table row" '[ "$ZRC" = 0 ] && grep -q "0 journals" <<<"$ZERO" && ! grep -q "^all" <<<"$ZERO"'

UNREAD="$(mktemp -d "${TMPDIR:-/tmp}/graph-use-report-test.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
trap 'chmod -R u+rw "$UNREAD" 2>/dev/null; rm -rf "$UNREAD"' EXIT
mkdir -p "$UNREAD/claude/projects/-x-himmel" && cp "$FX/claude/projects/-x-himmel/s1.jsonl" "$UNREAD/claude/projects/-x-himmel/ok.jsonl" && cp "$FX/claude/projects/-x-himmel/s2.jsonl" "$UNREAD/claude/projects/-x-himmel/locked.jsonl" && chmod 000 "$UNREAD/claude/projects/-x-himmel/locked.jsonl"
# shellcheck disable=SC2034
URPT="$(bash "$RPT" --days 36500 --root "$UNREAD/claude/projects" 2>&1)"
# shellcheck disable=SC2034
URPTRC=$?
check "the report over a root with an unreadable journal still exits 0" '[ "$URPTRC" = 0 ]'
check "a journal jq cannot read is counted and reported, not dropped silently (skipped when the files stay readable, e.g. root)" '[ -r "$UNREAD/claude/projects/-x-himmel/locked.jsonl" ] || { grep -q "could not be read.*: 1" <<<"$URPT" && grep -q " 1 journals in 1 roots" <<<"$URPT"; }'

mkdir "$UNREAD/claude/projects/-x-himmel/walled" && chmod 000 "$UNREAD/claude/projects/-x-himmel/walled"
# shellcheck disable=SC2034
WRPT="$(bash "$RPT" --days 36500 --root "$UNREAD/claude/projects" 2>&1)"
# shellcheck disable=SC2034
WRPTRC=$?
check "the report over a root with an unwalkable directory still exits 0" '[ "$WRPTRC" = 0 ]'
check "a directory find cannot walk is counted and reported, not dropped silently (skipped when it stays readable, e.g. root)" '[ -r "$UNREAD/claude/projects/-x-himmel/walled" ] || grep -q "directories that could not be walked.*: 1" <<<"$WRPT"'

mkdir -p "$UNREAD/q/claude/projects/-x-himmel"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"bash -c \"rg foo\""}}]}}' >"$UNREAD/q/claude/projects/-x-himmel/q.jsonl"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"ls"}}]}}' >"$UNREAD/q/claude/projects/-x-himmel/l.jsonl"
# shellcheck disable=SC2034
QRPT="$(bash "$RPT" --days 36500 --root "$UNREAD/q/claude/projects" 2>&1)"
# shellcheck disable=SC2034
QRPTRC=$?
check "the report over the quoted-search journal exits 0" '[ "$QRPTRC" = 0 ]'
check "a search behind bash -c with a quote before it counts and a lone ls does not: 2 journals, 1 searched, 1 never called the graph" '[ "$(OUT="$QRPT" cells all claude main journals searched searched_no_graph)" = 2/1/1 ]'

# shellcheck disable=SC2034
MISS="$(bash "$RPT" --days 36500 --root "$HERE/fixtures/graph-use-miss/claude/projects" 2>&1)"
# shellcheck disable=SC2034
MISSRC=$?
check "the report over the miss fixture exits 0" '[ "$MISSRC" = 0 ]'
check "a wrapper call that exits 3 or 4 is a miss, exit 1 is a fail, a bare graphify exit 3 stays a bare fail: 4 wrapper, 1 fail, 2 miss, 1 bare, 1 bare fail" '[ "$(OUT="$MISS" cells all claude main wrapper wrapper_fail wrapper_miss bare bare_fail)" = 4/1/2/1/1 ]'

check "--until-epoch 08 is decimal too: exits 0" 'bash "$RPT" --days 3 --until-epoch 08 --root "$FX/claude/projects" >/dev/null 2>&1; [ $? = 0 ]'
check "--days 08 with --until-epoch is decimal, not octal: exits 0" 'bash "$RPT" --days 08 --until-epoch 1000000000 --root "$FX/claude/projects" >/dev/null 2>&1; [ $? = 0 ]'

# ok columns: fixtures/graph-use-ok holds r1 a refused graph call and a rg, r2 a graph wrapper miss only, r3 a refused qmd query only,
# r4 grep -c and git grep -c that merely quote graphify query and qmd query, r5 a refused mcp qmd query (array content), r6 a refused
# mcp graphify call (string content), r7 an answered mcp qmd query and graphify call, r8 a graph wrapper call and a qmd query with no tool_result.
# shellcheck disable=SC2034
OKOUT="$(bash "$RPT" --days 36500 --root "$HERE/fixtures/graph-use-ok/claude/projects" 2>&1)"
# shellcheck disable=SC2034
OKRC=$?
check "the report over the ok fixture exits 0" '[ "$OKRC" = 0 ]'
check "a refused graph call (shell or mcp) and a call with no result are calls but not answered ones; a wrapper miss and an answered mcp call are answered; grep -c is no call: 8 journals, 5 with a graph call, 2 with an answered one, 25%" '[ "$(OUT="$OKOUT" cells all claude main journals with_graph with_graph_ok graph_ok_pct)" = 8/5/2/25% ]'
check "searched_no_graph rests on answered calls: the refused-only journal and the grep -c journal both count" '[ "$(OUT="$OKOUT" cells all claude main searched searched_no_graph)" = 2/2 ]'
check "a refused qmd query (shell or mcp, array content) and one with no result are searches but not answered ones: 4 with a search, 1 answered" '[ "$(OUT="$OKOUT" SEC=qmd cells all claude main with_search with_search_ok)" = 4/1 ]'
check "the counted line states the ok rule and the no-result case" 'grep -q "^counted:.*answered" <<<"$OKOUT" && grep -q "^counted:.*no tool_result" <<<"$OKOUT"'

# shellcheck disable=SC2034
EOUT="$(bash "$RPT" --days 36500 --root "$HERE/fixtures/graph-use-echo/claude/projects" --root "$HERE/fixtures/graph-use-echo/claude-codex/projects" 2>&1)"
# shellcheck disable=SC2034
EORC=$?
check "the report over the echo fixture exits 0" '[ "$EORC" = 0 ]'
check "an echo that quotes a graph or qmd call, even after a multi-line single-quoted python -c body, is no call: the claude lane has 1 journal with a tool, 0 graph calls and 0 qmd calls" '[ "$(OUT="$EOUT" cells all claude main with_tools calls)" = 1/0 ] && [ "$(OUT="$EOUT" SEC=qmd cells all claude main with_tools calls)" = 1/0 ]'
check "a bash -c or sh -c body, a quoted argument and a command or backtick substitution inside double quotes still count as graph calls, as do a substitution with quoted arguments inside double quotes (graph and qmd) , a call after a multi-line single-quoted argument (jq) and a call after a here-doc body with an apostrophe (a control, it counted on base too): the codex lane has 9 graph calls, 7 query, 1 explain, 1 path, and 1 qmd call" '[ "$(OUT="$EOUT" cells all codex main calls query explain path)" = 9/7/1/1 ] && [ "$(OUT="$EOUT" SEC=qmd cells all codex main calls)" = 1 ]'

check "a bad argument exits 2" 'bash "$RPT" --days x >/dev/null 2>&1; [ $? = 2 ]'
check "a root that does not exist exits 2" 'bash "$RPT" --root "$FX/no-such-root" >/dev/null 2>&1; [ $? = 2 ]'

echo "test-graph-use-report: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
