#!/usr/bin/env bash
# Test for scripts/ci/check-docs-decision-records.sh.
#
# Usage: bash scripts/ci/test-check-docs-decision-records.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GUARD="$HERE/check-docs-decision-records.sh"
FIX="$HERE/test-check-docs-decision-records-fixtures"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

expect() { # <want-rc> <label> <file>...
  local want="$1" label="$2"; shift 2
  bash "$GUARD" "$@" >/dev/null 2>&1; local rc=$?
  if [ "$rc" -eq "$want" ]; then pass "$label -> exit $want"; else fail "$label -> expected $want got $rc"; fi
}

echo "== flagged shapes =="
expect 1 "heading 'Why not'" "$FIX/by-heading.md"
expect 1 "research-comparison filename" "$FIX/foo-research-comparison.md"
expect 1 "verdict table with Rejected row" "$FIX/verdict-table.md"

echo "== clean reference doc =="
expect 0 "clean-reference.md" "$FIX/clean-reference.md"

echo "== no files =="
expect 0 "nonexistent path" "$FIX/does-not-exist.md"

echo "== output names the file =="
out=$(bash "$GUARD" "$FIX/by-heading.md" 2>&1)
case "$out" in *by-heading.md*) pass "output names by-heading.md" ;; *) fail "output does not name the file: $out" ;; esac

echo
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$failures FAILURE(S)"; exit 1; fi
