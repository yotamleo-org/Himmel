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
HERE="$(cd "$(dirname "$0")" && pwd)"
RPT="$HERE/graph-use-report.sh"
FX="$HERE/fixtures/graph-use"
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

OUT="$(bash "$RPT" --days 36500 --root "$FX/claude/projects" --root "$FX/claude-codex/projects" 2>&1)"
# cell <scope> <lane> <kind> <column name>: one cell of the table
cell() { printf '%s\n' "$OUT" | awk -F'\t' -v s="$1" -v l="$2" -v k="$3" -v c="$4" '
  $1 == "scope" { for (i = 1; i <= NF; i++) if ($i == c) col = i }
  $1 == s && $2 == l && $3 == k { print $col }'; }
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
check "the share of tool-using himmel claude main journals that called the graph is 80%" '[ "$(cell himmel claude main graph_pct)" = "80%" ]'
check "the report states what is counted and what is not" 'grep -q "^counted:" <<<"$OUT" && grep -q "^not counted:" <<<"$OUT"'

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
check "a journal jq cannot read is counted and reported, not dropped silently (skipped when the files stay readable, e.g. root)" '[ -r "$UNREAD/claude/projects/-x-himmel/locked.jsonl" ] || { grep -q "could not be read.*: 1" <<<"$URPT" && grep -q " 1 journals in 1 roots" <<<"$URPT"; }'

check "a bad argument exits 2" 'bash "$RPT" --days x >/dev/null 2>&1; [ $? = 2 ]'
check "a root that does not exist exits 2" 'bash "$RPT" --root "$FX/no-such-root" >/dev/null 2>&1; [ $? = 2 ]'

echo "test-graph-use-report: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
