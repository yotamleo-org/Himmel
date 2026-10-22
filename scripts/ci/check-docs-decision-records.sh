#!/usr/bin/env bash
# scripts/ci/check-docs-decision-records.sh — flag a NEW docs/ file shaped like
# a research comparison or a rejection record.
#
# The public repo describes what himmel has, not what it chose not to have:
# research, comparisons and "we rejected X" records belong in the state repo
# (see CLAUDE.md "Where artifacts land"). Deterministic and diff-scoped: only
# files ADDED relative to the base are inspected; no LLM.
#
# A file is flagged when ANY of:
#   - its name contains research / comparison / rejected / rejection /
#     decision-record / -vs-
#   - a heading reads Rejected..., Why not..., Alternatives considered,
#     Decision record, Not adopted, or Comparison
#   - a markdown table row has a Rejected / Not adopted / Declined cell
#
# Usage:
#   check-docs-decision-records.sh [file ...]   # explicit files (tests, pre-commit)
#   check-docs-decision-records.sh              # docs/ files added vs merge-base with origin/main
#
# Exit codes:
#   0 — nothing flagged
#   1 — at least one file flagged
set -uo pipefail

files=()
if [ "$#" -gt 0 ]; then
  files=("$@")
else
  base=$(git merge-base origin/main HEAD 2>/dev/null || git rev-parse HEAD 2>/dev/null || true)
  [ -z "$base" ] && exit 0
  while IFS= read -r f; do
    case "$f" in docs/*.md|docs/*.html) files+=("$f") ;; esac
  done < <(git diff --name-only --diff-filter=A "$base" 2>/dev/null)
fi

name_re='(research|comparison|rejected|rejection|decision-record|-vs-)'
head_re='(^#{1,6}[[:space:]]+|<h[1-6][^>]*>[[:space:]]*).*(rejected|why not|alternatives considered|decision record|not adopted|comparison)'
row_re='^\|([^|]*\|)*[[:space:]]*(rejected|not adopted|declined)[[:space:]]*(\||$)'

flagged=0
for f in "${files[@]}"; do
  [ -f "$f" ] || continue
  reason=""
  base_name=$(basename "$f")
  if printf '%s\n' "$base_name" | grep -qiE "$name_re"; then
    reason="filename"
  elif grep -qiE "$head_re" "$f"; then
    reason="heading"
  elif grep -qiE "$row_re" "$f"; then
    reason="table row"
  fi
  if [ -n "$reason" ]; then
    printf 'ERROR: %s looks like a research comparison / rejection record (%s).\n' "$f" "$reason"
    flagged=1
  fi
done

if [ "$flagged" -eq 1 ]; then
  printf 'The public repo describes what himmel has, not what it chose not to have.\n'
  printf 'Put the record in the state repo under specs/research/ or specs/decisions/ instead.\n'
  exit 1
fi
exit 0
