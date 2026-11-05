#!/usr/bin/env bash
# scripts/one-shot/check-ticket-refs.sh — hand-run check for ticket keys left in tracked text.
# Lists every tracked line that still carries a key outside the rule list. A removal
# helper, never a suite: no CI or pre-commit wiring (scripts/ci/check-removal-ratchets.sh
# keeps that shape); the forever-gate is the diff gate scripts/lint/check-history-comments.sh,
# which reads the same classifier and rule list.
#
# Usage: check-ticket-refs.sh [--root DIR] [--paths FILE]
#   --root DIR    repo to scan (default: this repo); tracked files only
#   --paths FILE  scan only the paths listed in FILE, one per line (a batch's file set)
# Output: one `HIT path:line: text` per line not covered by scripts/lint/ticket-ref-allow.tsv.
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

lint="$here/../lint"
allow="$lint/ticket-ref-allow.tsv"
classifier="$lint/ticket-refs.awk"
for f in "$allow" "$classifier"; do
  [ -r "$f" ] || { echo "check-ticket-refs: cannot read $f" >&2; exit 2; }
done
# the key pattern is the list's `key` row, never a second copy here
keyre="$(awk -F'\t' '$1 == "key" { print $3; exit }' "$allow")"
[ -n "$keyre" ] || { echo "check-ticket-refs: $allow has no key row" >&2; exit 2; }
# a subdirectory root would scan only that subtree and read clean
top="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" \
  || { echo "check-ticket-refs: not a git work tree: $root" >&2; exit 2; }
root="$top"

specs=()
if [ -n "$paths_file" ]; then
  [ -r "$paths_file" ] || { echo "check-ticket-refs: cannot read $paths_file" >&2; exit 2; }
  while IFS= read -r p || [ -n "$p" ]; do
    [ -n "$p" ] || continue
    specs+=(":(literal)$p")
  done < "$paths_file"
  # an empty list would widen to the whole tree
  [ "${#specs[@]}" -gt 0 ] || { echo "check-ticket-refs: $paths_file lists no paths" >&2; exit 2; }
fi

out="$(git -C "$root" -c core.quotePath=false grep -n -I -E "$keyre" -- "${specs[@]+"${specs[@]}"}")"
rc=$?
if [ "$rc" -gt 1 ]; then
  echo "check-ticket-refs: git grep failed in $root (rc=$rc)" >&2; exit 2
fi
[ "$rc" -eq 1 ] && exit 0

hits="$(printf '%s\n' "$out" | LC_ALL=C awk -f "$classifier" -v allow="$allow" -v mode=tree)"
# a bad rule list kills awk with empty output, which must not read as clean
awk_rc=$?
case "$awk_rc" in
  0|1) ;;
  *) echo "check-ticket-refs: awk failed on $allow (rc=$awk_rc)" >&2; exit 2 ;;
esac

[ -n "$hits" ] || exit 0
printf '%s\n' "$hits"
exit 1
