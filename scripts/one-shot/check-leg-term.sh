#!/usr/bin/env bash
# scripts/one-shot/check-leg-term.sh — hand-run check for the retired term "leg".
# Lists every tracked line that still says leg/legs outside the allowlist. A
# removal helper, never a suite: no CI or pre-commit wiring
# (scripts/ci/check-removal-ratchets.sh keeps that shape).
#
# Usage: check-leg-term.sh [--root DIR] [--paths FILE]
#   --root DIR    repo to scan (default: this repo); tracked files only
#   --paths FILE  scan only the paths listed in FILE, one per line (a batch's file set)
# Output: one `HIT path:line: text` per line not covered by leg-term-allow.tsv.
# Exit codes: 0 clean, 1 hits, 2 usage or git error.
set -uo pipefail

usage() { echo "usage: $0 [--root DIR] [--paths FILE]" >&2; exit 2; }

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
paths_file=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root)  [ $# -ge 2 ] || usage; root="$2"; shift 2 ;;
    --paths) [ $# -ge 2 ] || usage; paths_file="$2"; shift 2 ;;
    *) usage ;;
  esac
done

allow="$here/leg-term-allow.tsv"
[ -r "$allow" ] || { echo "check-leg-term: cannot read $allow" >&2; exit 2; }
git -C "$root" rev-parse --git-dir >/dev/null 2>&1 \
  || { echo "check-leg-term: not a git repo: $root" >&2; exit 2; }

specs=()
if [ -n "$paths_file" ]; then
  [ -r "$paths_file" ] || { echo "check-leg-term: cannot read $paths_file" >&2; exit 2; }
  while IFS= read -r p || [ -n "$p" ]; do
    [ -n "$p" ] || continue
    specs+=(":(literal)$p")
  done < "$paths_file"
  # an empty list would widen to the whole tree
  [ "${#specs[@]}" -gt 0 ] || { echo "check-leg-term: $paths_file lists no paths" >&2; exit 2; }
fi

out="$(git -C "$root" -c core.quotePath=false grep -n -I -i -w -E 'legs?' -- "${specs[@]+"${specs[@]}"}")"
rc=$?
if [ "$rc" -gt 1 ]; then
  echo "check-leg-term: git grep failed in $root (rc=$rc)" >&2; exit 2
fi
[ "$rc" -eq 1 ] && exit 0

# allow rows: path-regex <TAB> line-regex (empty = whole file) <TAB> reason
hits="$(printf '%s\n' "$out" | awk -F'\t' '
  FNR == NR {
    if ($0 ~ /^#/ || $1 == "") next
    n++; pre[n] = $1; lre[n] = $2; next
  }
  {
    if (!match($0, /:[0-9]+:/)) next
    path = substr($0, 1, RSTART - 1)
    line = substr($0, RSTART + 1, RLENGTH - 2)
    text = substr($0, RSTART + RLENGTH)
    for (i = 1; i <= n; i++)
      if (path ~ pre[i] && (lre[i] == "" || text ~ lre[i])) next
    printf "HIT %s:%s: %s\n", path, line, text
  }' "$allow" -)"

[ -n "$hits" ] || exit 0
printf '%s\n' "$hits"
exit 1
