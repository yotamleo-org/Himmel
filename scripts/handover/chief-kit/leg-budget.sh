#!/usr/bin/env bash
# leg-budget.sh - a worker's live cost budget. Prints one line
#   leg-budget calls=<n> cost-eq=<k>k soft=<k>k hard=<k>k verdict=OK|SOFT|HARD
# cost-eq is the leg-burn.sh figure (the line leg-pr-open.sh puts in the PR body),
# read from the worker's own transcript while it runs. SOFT: send the chief a
# FINDING quoting the line. HARD: WRAP with a resume brief. The defaults are the
# p80 and about the p92 of the cost-eq of the last 50 merged worker PRs
# (p50 1485k, p80 2990k, p95 7545k); WORKER_COST_SOFT_K / WORKER_COST_HARD_K override
# them, in thousands of cost-eq.
#
# usage: leg-budget.sh [--title <worker session name> | --from-line "<leg-burn.sh output>"]
# --from-line judges a leg-burn line the caller already has (tick.sh --burn), with no transcript scan.
# Session: CONTEXT_FILL_TRANSCRIPT, else --title (leg-burn.sh matches the newest
# transcript whose customTitle is that name), else CLAUDE_CODE_SESSION_ID.
# Exit: 0 OK, 4 SOFT, 3 HARD, 2 the transcript cannot be read or holds no
# assistant call. Never prints verdict=OK for a transcript it could not measure.
#
# Run it in an ordinary Bash call, not inside a Monitor (same as context-fill.sh).
# Platform guard (gitbash-only): POSIX bash 3.2+, no mapfile.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SOFT_DEFAULT=3000
HARD_DEFAULT=7000

num_env() { # <name> <default> - a bad value warns and falls back, never disables the budget
  local v="${!1:-$2}"
  case "$v" in
    ''|*[!0-9]*|???????*) v="" ;;
    *) v="$((10#$v))" ;;  # 10#: a leading zero (08) is not octal
  esac
  if [ -z "$v" ] || [ "$v" -eq 0 ]; then
    printf 'leg-budget: ignoring %s=%s - using %s\n' "$1" "${!1:-$2}" "$2" >&2; v="$2"
  fi
  printf '%s\n' "$v"
}
SOFT="$(num_env WORKER_COST_SOFT_K "$SOFT_DEFAULT")"
HARD="$(num_env WORKER_COST_HARD_K "$HARD_DEFAULT")"
if [ "$HARD" -le "$SOFT" ]; then  # a hard ceiling at or under the soft one would skip the FINDING step
  printf 'leg-budget: ignoring WORKER_COST_HARD_K=%s - hard must exceed soft=%s; using the defaults %s/%s\n' "$HARD" "$SOFT" "$SOFT_DEFAULT" "$HARD_DEFAULT" >&2
  SOFT="$SOFT_DEFAULT"; HARD="$HARD_DEFAULT"
fi

title=""; from_line=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --title)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then echo "leg-budget: --title needs a non-empty value" >&2; exit 2; fi
      title="$2"; shift 2 ;;
    --from-line)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then echo "leg-budget: --from-line needs a non-empty value" >&2; exit 2; fi
      from_line="$2"; shift 2 ;;
    *) echo "usage: leg-budget.sh [--title <worker session name> | --from-line \"<leg-burn.sh output>\"]" >&2; exit 2 ;;
  esac
done

if [ -n "$from_line" ]; then
  burn="$from_line"
else
  target=""
  if [ -n "${CONTEXT_FILL_TRANSCRIPT:-}" ]; then
    target="$CONTEXT_FILL_TRANSCRIPT"
  elif [ -n "$title" ]; then
    target="$title"
  elif [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    for f in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/projects/*/"$CLAUDE_CODE_SESSION_ID".jsonl; do
      if [ -f "$f" ]; then target="$f"; break; fi
    done
  fi
  [ -n "$target" ] || { echo "leg-budget: cannot resolve the worker session (set CONTEXT_FILL_TRANSCRIPT, --title, or CLAUDE_CODE_SESSION_ID)" >&2; exit 2; }

  errf="$(mktemp "${TMPDIR:-/tmp}/leg-budget.XXXXXX")" || { echo "leg-budget: cannot create a scratch file" >&2; exit 2; }
  burn="$(bash "$HERE/../../lanes/leg-burn.sh" "$target" 2>"$errf")" || {
    echo "leg-budget: cannot measure $target: $(cat "$errf")" >&2
    rm -f "$errf"; exit 2
  }
  rm -f "$errf"
fi

calls="$(printf '%s\n' "$burn" | sed -n 's/.* calls=\([1-9][0-9]*\) .*/\1/p')"
raw="$(printf '%s\n' "$burn" | sed -n 's/.* cost-eq=\([0-9][0-9]*\(\.[0-9][0-9]*\)\{0,1\}k\{0,1\}\) .*/\1/p')"
if [ -z "$calls" ] || [ -z "$raw" ]; then echo "leg-budget: cannot parse leg-burn.sh output: $burn" >&2; exit 2; fi
# leg-burn prints cost-eq as "<n>k" from 1000 up and as a bare number below; work in k
cost_k="$(awk -v r="$raw" 'BEGIN { if (r ~ /k$/) { sub(/k$/, "", r); printf "%.1f", r } else printf "%.1f", r / 1000 }')"

verdict=OK; rc=0
if awk -v c="$cost_k" -v h="$HARD" 'BEGIN { exit !(c >= h) }'; then verdict=HARD; rc=3
elif awk -v c="$cost_k" -v s="$SOFT" 'BEGIN { exit !(c >= s) }'; then verdict=SOFT; rc=4
fi
printf 'leg-budget calls=%s cost-eq=%sk soft=%sk hard=%sk verdict=%s\n' "$calls" "$cost_k" "$SOFT" "$HARD" "$verdict"
exit "$rc"
