#!/usr/bin/env bash
# scripts/ci/suite-runs-summary.sh — per-suite red counts from the local ledger.
#
# Usage: bash scripts/ci/suite-runs-summary.sh [--days N]     (default 7)
#
# Reads $HIMMEL_SUITE_LEDGER (default ~/.himmel/state/suite-runs.jsonl, written
# by quiet-run.sh and run-shell-tests.sh via suite-ledger.sh) and prints, for
# every suite with at least one red run (rc != 0) in the last N days,
#   <red>/<runs>  <suite>
# most red first. An absent ledger is an empty report.
#
# Exit codes: 0 — report printed; 2 — bad usage.
set -uo pipefail

days=7
while [ $# -gt 0 ]; do
  case "$1" in
    --days)
      case "${2:-}" in ''|*[!0-9]*) echo "suite-runs-summary: --days needs a whole number" >&2; exit 2 ;; esac
      days="$2"; shift 2 ;;
    *) echo "Usage: $0 [--days N]" >&2; exit 2 ;;
  esac
done

ledger="${HIMMEL_SUITE_LEDGER:-${HOME:-}/.himmel/state/suite-runs.jsonl}"
if [ ! -r "$ledger" ]; then
  echo "suite-runs-summary: no ledger at $ledger (0 runs in the last $days days)"
  exit 0
fi

if ! cutoff=$(date -u -d "$days days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null); then # swallow-ok: GNU date probe, BSD date below
  cutoff=$(date -u -v-"$days"d +%Y-%m-%dT%H:%M:%SZ)
fi

awk -v cutoff="$cutoff" '
  function field(line, key,   m) {
    if (match(line, "\"" key "\":\"([^\"\\\\]|\\\\.)*\"")) {
      m = substr(line, RSTART + length(key) + 4, RLENGTH - length(key) - 5)
      gsub(/\\"/, "\"", m); gsub(/\\\\/, "\\", m)
      return m
    }
    if (match(line, "\"" key "\":-?[0-9]+")) return substr(line, RSTART + length(key) + 3, RLENGTH - length(key) - 3)
    return ""
  }
  {
    ts = field($0, "ts"); suite = field($0, "suite"); rc = field($0, "rc")
    if (ts == "" || suite == "" || rc == "" || ts < cutoff) next
    runs[suite]++; total++
    if (rc != 0) red[suite]++
  }
  END {
    for (s in red) printf "%d/%d\t%s\n", red[s], runs[s], s
    printf "# %d runs since %s\n", total, cutoff > "/dev/stderr"
  }
' "$ledger" | sort -t/ -k1,1nr -k2,2nr | sed 's/\t/  /'
