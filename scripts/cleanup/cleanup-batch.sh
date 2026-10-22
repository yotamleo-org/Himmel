#!/usr/bin/env bash
# cleanup-batch.sh — batch a cleanup into PRs of one directory family, at most 20 files.
#
# Usage: cleanup-batch.sh plan [<paths-file>]   queue the paths (stdin without a file)
#        cleanup-batch.sh check [<base>]        refuse a branch diff over the cap
#
# A directory family is the first two path components (scripts/hooks), or the
# first one for a shallower path (docs/a.md -> docs, README.md -> .).
# plan queues the largest family first and prints one
# "batch <n> family=<f> files=<k>" header per batch with its
# paths indented under it, then "next: batch 1 ..." and "batches: <n>".
# check diffs <base>...HEAD (default origin/main) and exits 1 when the diff has
# more than 20 files or spans more than one family.
set -uo pipefail

CAP=20

usage() { sed -n '4,5p' "$0" | sed 's/^# //'; }

family_of() { awk -F/ '{ if (NF >= 3) print $1 "/" $2; else if (NF == 2) print $1; else print "." }'; }

case "${1:-}" in
  plan)
    src="${2:--}"
    grep -v '^[[:space:]]*$' "$src" | sort -u | while IFS= read -r p; do
      printf '%s\t%s\n' "$(printf '%s\n' "$p" | family_of)" "$p"
    done | awk -F'\t' '{ n[$1]++; row[NR] = $0; fam[NR] = $1 } END { for (i = 1; i <= NR; i++) printf "%d\t%s\n", n[fam[i]], row[i] }' |
      sort -t "$(printf '\t')" -k1,1nr -k2,2 -k3,3 | cut -f2- |
      awk -F'\t' -v cap="$CAP" '
        { fam[NR] = $1; path[NR] = $2 }
        END {
          b = 0; i = 1
          while (i <= NR) {
            f = fam[i]; j = i; k = 0
            while (j <= NR && fam[j] == f && k < cap) { j++; k++ }
            b++
            printf "batch %d family=%s files=%d\n", b, f, k
            if (b == 1) first = sprintf("next: batch 1 family=%s files=%d", f, k)
            for (x = i; x < j; x++) printf "  %s\n", path[x]
            i = j
          }
          if (b) print first; else print "next: none"
          printf "batches: %d\n", b
        }'
    ;;
  check)
    base="${2:-origin/main}"
    files="$(git diff --name-only "$base...HEAD")" || exit 1
    n="$(printf '%s\n' "$files" | grep -c . || true)"
    fams="$(printf '%s\n' "$files" | grep . | family_of | sort -u)"
    nf="$(printf '%s\n' "$fams" | grep -c . || true)"
    if [ "$n" -gt "$CAP" ]; then
      echo "cleanup-batch: REFUSED — $n files over the cap of $CAP; split it with: cleanup-batch.sh plan" >&2
      exit 1
    fi
    if [ "$nf" -gt 1 ]; then
      echo "cleanup-batch: REFUSED — the diff spans $nf directory families ($(printf '%s' "$fams" | tr '\n' ' ')); one PR per family" >&2
      exit 1
    fi
    echo "cleanup-batch: OK files=$n family=${fams:-none}"
    ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
