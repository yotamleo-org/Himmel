#!/usr/bin/env bash
# scripts/eval/worker-digest/test-graph-use-report.sh - hermetic suite for graph-use-report.sh.
# fixtures/graph-use/p holds 7 sessions: s1 explain+path+git grep, s2 three queries (bash -c, rtk, cd), s3 one mcp call,
# s4 rg only, s5 Read only, s6 a git grep that merely names "graphify query", s7 a bad line + the worker-graph.sh wrapper.
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

OUT="$(bash "$RPT" --days 36500 --root "$FX" 2>&1)"
row() { printf '%s\n' "$OUT" | awk -F'\t' -v f="$1" '$1 == f { print $2 "/" $3 }'; }

check "7 sessions are read, the bad journal line does not stop the scan" 'printf "%s\n" "$OUT" | grep -q "7 sessions"'
check "query: 3 calls in 1 session (bash -c, rtk and cd shapes lead the command)" '[ "$(row query)" = 3/1 ]'
check "explain: 2 calls in 2 sessions (plain graphify and the worker-graph.sh wrapper)" '[ "$(row explain)" = 2/2 ]'
check "path: 1 call in 1 session" '[ "$(row path)" = 1/1 ]'
check "mcp: 1 call in 1 session" '[ "$(row mcp)" = 1/1 ]'
check "any: 7 calls in 4 sessions, a git grep naming graphify query is not a call" '[ "$(row any)" = 7/4 ]'
check "3 sessions searched code, 2 of them never called the graph (67%)" 'printf "%s\n" "$OUT" | grep -q "searched code: 3, of which never called the graph: 2 (67%)"'
check "1.75 graph calls per graph-using session" 'printf "%s\n" "$OUT" | grep -q "per graph-using session: 1.75"'
check "a window that excludes the fixture reads 0 sessions and no divide error" '[ -z "$(bash "$RPT" --days 0 --root "$FX" 2>&1 | grep -i "error\|nan\|inf")" ]'
check "a bad argument exits 2" 'bash "$RPT" --days x >/dev/null 2>&1; [ $? = 2 ]'

echo "test-graph-use-report: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
