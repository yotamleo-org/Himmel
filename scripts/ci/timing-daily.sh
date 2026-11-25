#!/usr/bin/env bash
# scripts/ci/timing-daily.sh -- the body of .github/workflows/timing-daily.yml.
#
# Timing tests leave PR and main CI: a suite tagged `daily` in scripts/ci/suite-tiers.tsv is
# skipped by every runner mode but SUITE_TIER_MODE=daily, and a suite that only hits its time
# cap (both attempts, no FAIL row of its own) is a CAP-ALERT line and exit 0 in CI. This script
# runs the daily suites, reads CAP-ALERT lines and prints `WOULD-CHANGE <suite> cap <old>s -> <new>s`
# (the cap doubled); a red run is the alert workflow-red.yml turns into an issue.
#
# Usage: timing-daily.sh [--no-run] [--alerts FILE]... [--ci-hours N]
# Env: TIMING_DAILY_RUNNER (default scripts/ci/run-shell-tests.sh), TIMING_DAILY_SCAN (default scripts/),
#      GH_TOKEN for --ci-hours, GITHUB_STEP_SUMMARY (the report is appended when set).
# Exit: 0 nothing to act on; 1 a daily suite failed, a cap alert was seen, or an alert source
#       (--alerts file, main CI run list or log) could not be read; 2 usage error.
#
# Platform guard: bash 3.2+; --ci-hours needs GNU date and gh (the job runs on Linux).
# shellcheck disable=SC2016 # the summary's backticks are literal markdown
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUNNER="${TIMING_DAILY_RUNNER:-$ROOT/scripts/ci/run-shell-tests.sh}"
SCAN="${TIMING_DAILY_SCAN:-$ROOT/scripts}"

no_run=0
ci_hours=""
alert_files=()
while [ $# -gt 0 ]; do
  case "$1" in
    --no-run) no_run=1; shift ;;
    --alerts) [ $# -ge 2 ] || { echo "timing-daily: --alerts needs a file" >&2; exit 2; }
              alert_files+=("$2"); shift 2 ;;
    --ci-hours) [ $# -ge 2 ] || { echo "timing-daily: --ci-hours needs a number" >&2; exit 2; }
                ci_hours="$2"; shift 2 ;;
    *) echo "usage: timing-daily.sh [--no-run] [--alerts FILE]... [--ci-hours N]" >&2; exit 2 ;;
  esac
done
case "$ci_hours" in ''|*[!0-9]*) [ -z "$ci_hours" ] || { echo "timing-daily: --ci-hours must be a whole number" >&2; exit 2; } ;; esac

out=""
run_rc=0
if [ "$no_run" -eq 0 ]; then
  out="$(SUITE_TIER_MODE=daily bash "$RUNNER" "$SCAN" 2>&1)"
  run_rc=$?
  printf '%s\n' "$out"
fi

src_rc=0
alerts=""
add_alerts() { [ -z "$1" ] || alerts="${alerts:+$alerts
}$1"; }
alert_lines() { grep -E 'CAP-ALERT [^ ]+ \(ran' || true; } # swallow-ok: a source with no alert line is the common case

add_alerts "$(printf '%s\n' "$out" | alert_lines)"
for f in ${alert_files[@]+"${alert_files[@]}"}; do
  if [ -f "$f" ] && [ -r "$f" ]; then
    add_alerts "$(alert_lines < "$f")"
  else
    echo "timing-daily: cannot read $f" >&2
    src_rc=1
  fi
done
if [ -n "$ci_hours" ]; then
  since="$(date -u -d "$ci_hours hours ago" +%Y-%m-%dT%H:%M:%SZ)"
  if ci_ids="$(gh run list --workflow ci.yml --branch main --status completed --created ">=$since" --limit 500 --json databaseId --jq '.[].databaseId')"; then
    for id in $ci_ids; do
      if run_log="$(gh run view "$id" --log)"; then
        add_alerts "$(printf '%s\n' "$run_log" | alert_lines)"
      else
        echo "timing-daily: gh run view $id failed; its log was not read" >&2
        src_rc=1
      fi
    done
  else
    echo "timing-daily: gh run list failed; the last ${ci_hours}h of main CI was not read" >&2
    src_rc=1
  fi
fi

would="$(printf '%s\n' "$alerts" | awk '
  { i = index($0, "CAP-ALERT "); if (!i) next
    rest = substr($0, i + 10); split(rest, a, " "); suite = a[1]
    if (!match(rest, /cap [0-9]+s/)) next
    cap = substr(rest, RSTART + 4, RLENGTH - 5) + 0
    seen[suite]++; if (cap > mx[suite]) mx[suite] = cap }
  END { for (s in seen) printf "WOULD-CHANGE %s cap %ds -> %ds (%d alert line(s))\n", s, mx[s], mx[s] * 2, seen[s] }' | sort)"

report="$(
  echo '== timing-daily =='
  if [ "$no_run" -eq 1 ]; then echo "daily run: skipped (--no-run)"; else echo "daily run: rc=$run_rc"; fi
  [ "$src_rc" -eq 0 ] || echo "alert sources: not all read"
  if [ -n "$would" ]; then printf '%s\n' "$would"; else echo "no cap alerts"; fi
)"
printf '%s\n' "$report"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  printf '### timing-daily\n\n```\n%s\n```\n' "$report" >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true # swallow-ok: an unwritable summary must not change the verdict
fi

[ "$run_rc" -eq 0 ] && [ "$src_rc" -eq 0 ] && [ -z "$would" ]
