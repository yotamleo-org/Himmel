#!/usr/bin/env bash
# scripts/eval/burst-cost.sh - process-creation burst cost, idle window vs a command.
#
# Samples the kernel's own counters in /proc before and after (a) an idle sleep and
# (b) the command, and prints a markdown table: fork rate (/proc/stat "processes"),
# context switches, CPU busy %, and CPU pressure stall time (PSI "some" total).
# Names the cost of a spawn-heavy burst (a shell suite, a pre-commit chain) with
# numbers instead of guesses.
#
# Usage: burst-cost.sh [--idle SECS] -- CMD [ARGS...]
#   --idle SECS   length of the idle baseline window (default 5)
# Env: BURST_PROC_ROOT overrides /proc (tests).
# Exit: 0 ok, 2 usage, 4 the command failed (table still printed).
#
# ponytail: Linux /proc only; Windows Defender / MsMpEng and conhost are not sampled,
# upgrade path = a separate sampler if a Windows station returns.
set -u

PROC="${BURST_PROC_ROOT:-/proc}"
IDLE=5

usage() { echo "usage: burst-cost.sh [--idle SECS] -- CMD [ARGS...]" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --idle) [ $# -ge 2 ] || usage; IDLE="$2"; shift 2 ;;
    --) shift; break ;;
    *) usage ;;
  esac
done
[ $# -gt 0 ] || usage
case "$IDLE" in ''|*[!0-9.]*) usage ;; esac

# One line: now_ns forks ctxt cpu_total cpu_busy psi_some_us
snap() {
  local psi=0
  if [ -r "$PROC/pressure/cpu" ]; then
    psi=$(awk '/^some/ { for (i = 2; i <= NF; i++) if ($i ~ /^total=/) { sub("total=", "", $i); print $i } }' "$PROC/pressure/cpu")
  fi
  awk -v now="$(date +%s%N)" -v psi="${psi:-0}" '
    /^cpu / { t = 0; for (i = 2; i <= NF; i++) t += $i; busy = t - $5 - $6 }
    /^processes / { f = $2 }
    /^ctxt / { c = $2 }
    END { print now, f, c, t, busy, psi }' "$PROC/stat"
}

row() { # label start-snap end-snap
  echo "$2 $3" | awk -v L="$1" '{
    s = ($7 - $1) / 1e9; if (s <= 0) s = 1e-9
    forks = $8 - $2; ctx = $9 - $3; dt = $10 - $4; db = $11 - $5; psi = $12 - $6
    printf "| %s | %.2f | %d | %.1f | %.0f | %.1f | %.1f |\n", L, s, forks, forks / s, ctx / s, (dt > 0 ? 100 * db / dt : 0), psi / 1000
  }'
}

A=$(snap); sleep "$IDLE"; B=$(snap)
"$@"; RC=$?
C=$(snap)

echo "| window | secs | forks | forks/s | ctx-switches/s | cpu busy % | cpu PSI stall ms |"
echo "|---|---|---|---|---|---|---|"
row idle "$A" "$B"
row burst "$B" "$C"
[ "$RC" -eq 0 ] || { echo "burst-cost: command exited $RC" >&2; exit 4; }
