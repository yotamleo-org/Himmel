#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016
# test-stability-scorecard.sh — stability-scorecard.sh row writer: one row per UTC day,
# metrics parsed from fixtures, unknown on a failed source, cron arm/status/disarm.
# Hermetic: every source is a seam command; the real ledgers, gh and Jira are never touched.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
tool="$here/stability-scorecard.sh"
td="$(mktemp -d "${TMPDIR:-/tmp}/stability-scorecard.XXXXXX")" || { echo "FAIL - mktemp"; exit 1; }
trap 'rm -rf "$td"' EXIT
fails=0
ok(){ echo "ok - $1"; }
bad(){ echo "FAIL - $1"; fails=$((fails+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1: [$2]!=[$3]"; }

[ -f "$tool" ] || { bad "stability-scorecard.sh exists"; echo "1 failed"; exit 1; }

cat >"$td/ci.md" <<'E'
| job queue wait p50 / p90 / max (s) | 978 / 3240 / 9499 |
| cancelled share of runner-min | 10.5% |
| workflow | runs | jobs | ok | fail | cancelled |
| CI | 401 | 12000 | 9103 | 120 | 1799 |
| Pages | 53 | 53 | 53 | 0 | 0 |
E
printf '%s\n' '#!/usr/bin/env bash' 'cat "$SCORECARD_FIX/ci.md"' >"$td/ci.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo 2' >"$td/redmain.sh"
printf '%s\n' '#!/usr/bin/env bash' 'case "$*" in *deferred-escape*) echo "HIMMEL-1 x" ;; *) printf "HIMMEL-2 a\nHIMMEL-3 b\nHIMMEL-4 c\n" ;; esac' >"$td/jira.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exit 3' >"$td/fail.sh"
now=$(date -u +%s)
printf '{"ts":"%s"}\n{"ts":"%s"}\n{"ts":"2020-01-01T00:00:00Z"}\n' \
  "$(date -u -d "@$((now-3600))" +%FT%TZ)" "$(date -u -d "@$((now-7200))" +%FT%TZ)" >"$td/den.jsonl"

export SCORECARD_FIX="$td" SCORECARD_CI_METRICS_CMD="bash $td/ci.sh" SCORECARD_RED_MAIN_CMD="bash $td/redmain.sh" \
  SCORECARD_JIRA_CMD="bash $td/jira.sh" SCORECARD_DENIALS_FILE="$td/den.jsonl" SCORECARD_TSV="$td/s.tsv"

bash "$tool" run --date 2026-10-18; rc=$?
check "run exits 0" "$rc" 0
check "header + one row" "$(wc -l <"$td/s.tsv" | tr -d ' ')" 2
row="$(sed -n 2p "$td/s.tsv")"
check "row cells" "$(printf '%s' "$row" | cut -f1,3-11)" "$(printf '2026-10-18\t978\t3240\t1.00\t2\t2\tn/a\t3\t1\t10.5')"

bash "$tool" run --date 2026-10-18 >/dev/null; check "same date again appends nothing" "$(wc -l <"$td/s.tsv" | tr -d ' ')" 2
bash "$tool" run --date 2026-10-19 >/dev/null; check "next date appends a row" "$(wc -l <"$td/s.tsv" | tr -d ' ')" 3

SCORECARD_RED_MAIN_CMD="bash $td/fail.sh" bash "$tool" run --date 2026-10-20 >/dev/null 2>&1; rc=$?
check "failed source exits 1" "$rc" 1
check "failed source reads unknown, never 0" "$(sed -n 4p "$td/s.tsv" | cut -f6)" unknown

printf 'not json\n' >"$td/bad.jsonl"
SCORECARD_DENIALS_FILE="$td/bad.jsonl" bash "$tool" run --date 2026-10-22 >/dev/null 2>&1; rc=$?
check "malformed denial ledger exits 1" "$rc" 1
check "malformed denial ledger reads unknown" "$(sed -n 5p "$td/s.tsv" | cut -f7)" unknown

printf '%s\n' '#!/usr/bin/env bash' 'echo 100' >"$td/sat.sh"
SCORECARD_RED_MAIN_CMD="bash $td/sat.sh" bash "$tool" run --date 2026-10-23 >/dev/null 2>&1; rc=$?
check "red main at the 100-run cap exits 1" "$rc" 1
check "red main at the cap reads unknown, never 100" "$(sed -n 6p "$td/s.tsv" | cut -f6)" unknown
printf '%s\n' '#!/usr/bin/env bash' 'seq 1 500' >"$td/jsat.sh"
SCORECARD_JIRA_CMD="bash $td/jsat.sh" bash "$tool" run --date 2026-10-24 >/dev/null 2>&1; rc=$?
check "jira list at the 500-row cap exits 1" "$rc" 1
check "jira list at the cap reads unknown" "$(sed -n 7p "$td/s.tsv" | cut -f9)" unknown
[ ! -d "$td/s.tsv.lock" ] && ok "no lock left behind" || bad "no lock left behind"

printf 'wrong\theader\n' >"$td/bad.tsv"
SCORECARD_TSV="$td/bad.tsv" bash "$tool" run --date 2026-10-21 >/dev/null 2>&1; rc=$?
check "foreign header is refused" "$rc" 1

printf '#!/usr/bin/env bash\ncase "$1" in -l) [ -f "%s/tab" ] && cat "%s/tab" || { echo "no crontab for x" >&2; exit 1; };; -) cat >"%s/tab";; esac\n' "$td" "$td" "$td" >"$td/crontab"
export SCORECARD_CRONTAB="bash $td/crontab" SCORECARD_RUNNER_DIR="$td/runner"
bash "$tool" arm --dry-run | grep -q "HIMMEL-StabilityScorecard" && ok "arm --dry-run names the task" || bad "arm --dry-run names the task"
[ ! -f "$td/tab" ] && ok "dry-run installs nothing" || bad "dry-run installs nothing"

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed"; exit 1
