#!/usr/bin/env bash
# selector: tree-scan
# Windows is dropped: no tracked .ps1 or archive/windows/ file, and graphify's
# ignore list names both so a stray one never reaches the knowledge graph.
set -uo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel)"
failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

n=$(git -C "$REPO_ROOT" ls-files '*.ps1' | wc -l)
if [ "$n" -eq 0 ]; then pass "T1 no tracked .ps1"; else fail "T1 $n tracked .ps1 file(s)"; fi

n=$(git -C "$REPO_ROOT" ls-files archive/windows | wc -l)
if [ "$n" -eq 0 ]; then pass "T2 no tracked archive/windows file"; else fail "T2 $n tracked archive/windows file(s)"; fi

ign="$REPO_ROOT/.graphifyignore"
if [ -f "$ign" ] && grep -qx 'archive/windows/' "$ign" && grep -qx '\*\.ps1' "$ign"; then
  pass "T3 .graphifyignore names archive/windows/ and *.ps1"
else
  fail "T3 .graphifyignore missing archive/windows/ or *.ps1"
fi

# Graph nodes: only checkable when a built graph exists in this checkout.
g="$REPO_ROOT/graphify-out/graph.json"
if [ -f "$g" ]; then
  n=$(grep -cE '"source_file": *"[^"]*(\.ps1|archive/windows)' "$g" || true)
  if [ "$n" -eq 0 ]; then pass "T4 no graph node under .ps1/archive/windows"; else fail "T4 $n graph node(s) under .ps1/archive/windows"; fi
else
  pass "T4 skipped (no graphify-out/graph.json in this checkout)"
fi

if [ "$failures" -eq 0 ]; then echo "ALL PASS"; else echo "$failures FAILED"; exit 1; fi
