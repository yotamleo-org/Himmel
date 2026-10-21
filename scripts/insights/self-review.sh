#!/usr/bin/env bash
# self-review.sh — print the five self-review numbers for a window of main.
#
# Usage: self-review.sh [--since <date>] [--until <date>] [--ref <rev>] [--repo <dir>]
#
# Reads first-parent merges of <rev> (default origin/main, else main) between
# --since (default 30 days ago) and --until (default now). A bare YYYY-MM-DD
# covers the whole day. Prints one line per number:
#   merges: <n>                                  subjects ending in (#<pr>)
#   fix-share: fix=<n> feat=<n> share=<pct>%     fix subjects / merges
#   guard-churn: <n>                             fix(hooks) or "guard" subjects
#   compaction-share: compacted=<n> runs=<n> share=<pct>%   leg-burn compactions=
#   sprawl: <KEY> merges=<n> | none              the ticket with the most merges
#   red-main: <n>                                merges whose body names a red main
set -uo pipefail

usage() { sed -n '4,5p' "$0" | sed 's/^# //'; }

since="30.days.ago"
until="now"
ref=""
repo="."
while [ $# -gt 0 ]; do
  case "$1" in
    --since) since="${2:?--since needs a date}"; shift 2 ;;
    --until) until="${2:?--until needs a date}"; shift 2 ;;
    --ref) ref="${2:?--ref needs a revision}"; shift 2 ;;
    --repo) repo="${2:?--repo needs a directory}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "self-review: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

day='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
if [[ "$since" =~ $day ]]; then since="$since 00:00:00"; fi
if [[ "$until" =~ $day ]]; then until="$until 23:59:59"; fi

if [ -z "$ref" ]; then
  if git -C "$repo" rev-parse -q --verify origin/main >/dev/null; then ref=origin/main; else ref=main; fi
fi

git -C "$repo" log "$ref" --first-parent --since="$since" --until="$until" --format='%x1e%s%n%b' |
  awk 'BEGIN { RS = "\036" }
    NF == 0 { next }
    {
      split($0, lines, "\n"); s = lines[1]
      if (s !~ /\(#[0-9]+\)$/) next
      merges++
      if (s ~ /^fix(\(|:)/) fix++
      if (s ~ /^feat(\(|:)/) feat++
      ls = tolower(s)
      if (ls ~ /^fix\(hooks\)/ || ls ~ /guard/) guard++
      lb = tolower($0)
      if (lb ~ /fixes-main-red|main is red|red main/) red++
      rest = $0
      while (match(rest, /compactions=[0-9]+/)) {
        runs++
        if (substr(rest, RSTART + 12, RLENGTH - 12) + 0 > 0) compacted++
        rest = substr(rest, RSTART + RLENGTH)
      }
      if (match(s, /\[[A-Z][A-Z0-9]*-[0-9]+\]/)) per[substr(s, RSTART + 1, RLENGTH - 2)]++
    }
    function pct(a, b) { return b ? int(100 * a / b) : 0 }
    END {
      top = ""; topn = 0
      for (k in per) if (per[k] > topn || (per[k] == topn && k < top)) { top = k; topn = per[k] }
      printf "merges: %d\n", merges
      printf "fix-share: fix=%d feat=%d share=%d%%\n", fix, feat, pct(fix, merges)
      printf "guard-churn: %d\n", guard
      printf "compaction-share: compacted=%d runs=%d share=%d%%\n", compacted, runs, pct(compacted, runs)
      if (topn) printf "sprawl: %s merges=%d\n", top, topn; else print "sprawl: none"
      printf "red-main: %d\n", red
    }'
