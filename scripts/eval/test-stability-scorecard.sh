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
printf '%s\n' '#!/usr/bin/env bash' 'case "$*" in *deferred-escape*) echo "HIMMEL-1 x" ;; *"resolution = Done"*) printf "HIMMEL-2 a\nHIMMEL-3 b\nHIMMEL-9 z\n" ;; *"resolved >="*) printf "HIMMEL-2 a\nHIMMEL-3 b\nHIMMEL-9 z\nHIMMEL-10 e\nHIMMEL-11 f\nHIMMEL-12 g\n" ;; *) printf "HIMMEL-2 a\nHIMMEL-3 b\nHIMMEL-4 c\n" ;; esac' >"$td/jira.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf "HIMMEL-2\nHIMMEL-3\nHIMMEL-77\n"' >"$td/mainkeys.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exit 3' >"$td/fail.sh"
now=$(date -u +%s)
iso_of() { date -u -d "@$1" +%FT%TZ 2>/dev/null || date -u -r "$1" +%FT%TZ; }
printf '{"ts":"%s"}\n{"ts":"%s"}\n{"ts":"2020-01-01T00:00:00Z"}\n' \
  "$(iso_of $((now-3600)))" "$(iso_of $((now-7200)))" >"$td/den.jsonl"

export SCORECARD_FIX="$td" SCORECARD_CI_METRICS_CMD="bash $td/ci.sh" SCORECARD_RED_MAIN_CMD="bash $td/redmain.sh" \
  SCORECARD_JIRA_CMD="bash $td/jira.sh" SCORECARD_MAIN_KEYS_CMD="bash $td/mainkeys.sh" SCORECARD_DENIALS_FILE="$td/den.jsonl" SCORECARD_TSV="$td/s.tsv"

bash "$tool" run --date 2026-10-18; rc=$?
check "run exits 0" "$rc" 0
check "header + one row" "$(wc -l <"$td/s.tsv" | tr -d ' ')" 2
row="$(sed -n 2p "$td/s.tsv")"
check "row cells" "$(printf '%s' "$row" | cut -f1,3-11)" "$(printf '2026-10-18\t978\t3240\t1.00\t2\t2\tn/a\t3\t1\t10.5')"

check "shipped_strict counts Done keys with a main squash subject (HIMMEL-9 has none)" "$(printf '%s' "$row" | cut -f12)" 2
check "admin_closes is resolved minus shipped" "$(printf '%s' "$row" | cut -f13)" 4

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

# cron starts in $HOME, not a repo: the jira CLI finds its .env through git from its cwd, so the script must run it from the primary checkout.
printf '%s\n' '#!/usr/bin/env bash' 'git rev-parse --git-common-dir >/dev/null 2>&1 || exit 7' 'echo "HIMMEL-9 z"' >"$td/jgit.sh"
mkdir "$td/nogit"
(cd "$td/nogit" && SCORECARD_JIRA_CMD="bash $td/jgit.sh" SCORECARD_TSV="$td/cwd.tsv" bash "$tool" run --date 2026-10-25 >/dev/null 2>&1); rc=$?
check "jira cells are numeric when run outside any repo" "$(sed -n 2p "$td/cwd.tsv" | cut -f9,10)" "$(printf '1\t1')"
check "run outside any repo exits 0" "$rc" 0

SCORECARD_MAIN_KEYS_CMD="bash $td/fail.sh" bash "$tool" run --date 2026-10-26 >/dev/null 2>&1; rc=$?
check "failed git source exits 1" "$rc" 1
check "failed git source reads unknown shipped, never 0" "$(sed -n 8p "$td/s.tsv" | cut -f12,13)" "$(printf 'unknown\tunknown')"

# a TSV written before the shipped columns existed is migrated in place, old rows padded with n/a
legacy="$(sed -n 1p "$td/s.tsv" | cut -f1-11,14)"
printf '%s\n%s\n' "$legacy" "$(printf '2026-10-01\tt\t1\t2\t3\t4\t5\tn/a\t6\t7\t8\told')" >"$td/legacy.tsv"
SCORECARD_TSV="$td/legacy.tsv" bash "$tool" run --date 2026-10-27 >/dev/null 2>&1; rc=$?
check "legacy header is migrated, run exits 0" "$rc" 0
check "migrated header carries the shipped columns" "$(sed -n 1p "$td/legacy.tsv" | cut -f12,13)" "$(printf 'shipped_strict\tadmin_closes')"
check "migrated old row is padded with n/a" "$(sed -n 2p "$td/legacy.tsv" | cut -f11-14)" "$(printf '8\tn/a\tn/a\told')"
check "migrated file gains the new row" "$(sed -n 3p "$td/legacy.tsv" | cut -f1,12)" "$(printf '2026-10-27\t2')"

# deferred escapes split per class-<id> label (unclassified when absent) and per priority, in the note cell
cat >"$td/jesc.sh" <<'E'
#!/usr/bin/env bash
case "$*" in
  *"priority = Highest"*) : ;;
  *"priority = High"*) echo "HIMMEL-1 x" ;;
  *"priority = Medium"*) printf 'HIMMEL-5 y\nHIMMEL-6 z\n' ;;
  *"priority ="*) : ;;
  *deferred-escape*--labels*) printf 'HIMMEL-1\tBug\tDone\tx\tdeferred-escape,class-fail-open\nHIMMEL-5\tBug\tDone\ty\tclass-fail-open,deferred-escape\nHIMMEL-6\tBug\tDone\tz\tdeferred-escape\nHIMMEL-7\tBug\tDone\tw\tdeferred-escape\n' ;;
  *deferred-escape*) : ;;
  *) echo "HIMMEL-2 a" ;;
esac
E
SCORECARD_JIRA_CMD="bash $td/jesc.sh" SCORECARD_TSV="$td/esc.tsv" bash "$tool" run --date 2026-10-28 >/dev/null 2>&1; rc=$?
check "escape split run exits 0" "$rc" 0
check "deferred_escapes still counts every escape" "$(sed -n 2p "$td/esc.tsv" | cut -f10)" 4
sed -n 2p "$td/esc.tsv" | cut -f14 | grep -qF 'escapes by class: class-fail-open=2 unclassified=2; by priority: High=1 Medium=2 unprioritized=1' \
  && ok "note carries the per-class and per-priority split" || bad "note carries the per-class and per-priority split: $(sed -n 2p "$td/esc.tsv" | cut -f14)"
sed -n 2p "$td/s.tsv" | cut -f14 | grep -q 'unclassified=1' && ok "an escape row with no labels column reads unclassified" || bad "an escape row with no labels column reads unclassified"

printf 'wrong\theader\n' >"$td/bad.tsv"
SCORECARD_TSV="$td/bad.tsv" bash "$tool" run --date 2026-10-21 >/dev/null 2>&1; rc=$?
check "foreign header is refused" "$rc" 1

printf '#!/usr/bin/env bash\ncase "$1" in -l) [ -f "%s/tab" ] && cat "%s/tab" || { echo "no crontab for x" >&2; exit 1; };; -) cat >"%s/tab";; esac\n' "$td" "$td" "$td" >"$td/crontab"
export SCORECARD_CRONTAB="bash $td/crontab" SCORECARD_RUNNER_DIR="$td/runner"
HANDOVER_DIR="$td/ho" USER_SLUG=tester bash "$tool" arm --dry-run | grep -q "HIMMEL-StabilityScorecard" && ok "arm --dry-run names the task" || bad "arm --dry-run names the task"
[ ! -f "$td/tab" ] && ok "dry-run installs nothing" || bad "dry-run installs nothing"

printf 'MAILTO=x\n\n0 1 * * * other-job\n' >"$td/tab"
HANDOVER_DIR="" USER_SLUG=tester bash "$tool" arm >/dev/null 2>&1; rc=$?
check "arm refuses an empty HANDOVER_DIR" "$rc" 1
HANDOVER_DIR="$td/ho" USER_SLUG="" USER="" bash "$tool" arm >/dev/null 2>&1; rc=$?
check "arm refuses an empty USER_SLUG" "$rc" 1
env -u USER_SLUG HANDOVER_DIR="$td/ho" USER=someone bash "$tool" arm >/dev/null 2>&1; rc=$?
check "arm refuses an unset USER_SLUG even when USER is set" "$rc" 1
check "refused arm leaves the crontab alone" "$(wc -l <"$td/tab" | tr -d ' ')" 3
[ ! -f "$td/runner/stability-scorecard.sh" ] && ok "refused arm writes no runner" || bad "refused arm writes no runner"

HANDOVER_DIR="$td/ho" USER_SLUG=tester bash "$tool" arm >/dev/null 2>&1; rc=$?
check "arm exits 0" "$rc" 0
grep -q '^USER_SLUG=tester$' "$td/runner/stability-scorecard.sh" && ok "runner freezes USER_SLUG" || bad "runner freezes USER_SLUG"
grep -q '^HANDOVER_DIR=' "$td/runner/stability-scorecard.sh" && ok "runner freezes HANDOVER_DIR" || bad "runner freezes HANDOVER_DIR"
check "arm installs one entry" "$(grep -c 'HIMMEL-StabilityScorecard' "$td/tab")" 1
check "arm keeps the other job and the blank line" "$(grep -c -e 'other-job' -e '^$' "$td/tab")" 2
bash "$tool" status | grep -q '^ARMED' && ok "status reads ARMED" || bad "status reads ARMED"
HANDOVER_DIR="$td/ho" USER_SLUG=tester bash "$tool" arm >/dev/null 2>&1; rc=$?
check "arm twice refuses" "$rc" 3
HANDOVER_DIR="$td/ho" USER_SLUG=tester bash "$tool" arm --force --hour 7 >/dev/null 2>&1; rc=$?
check "arm --force exits 0" "$rc" 0
check "arm --force replaces, never duplicates" "$(grep -c 'HIMMEL-StabilityScorecard' "$td/tab")" 1
grep -q '^20 7 ' "$td/tab" && ok "arm --force takes the new hour" || bad "arm --force takes the new hour"
check "arm --force keeps the blank line" "$(grep -c '^$' "$td/tab")" 1
bash "$tool" disarm >/dev/null 2>&1; rc=$?
check "disarm exits 0" "$rc" 0
check "disarm removes the entry" "$(grep -c 'HIMMEL-StabilityScorecard' "$td/tab")" 0
check "disarm keeps the other job" "$(grep -c 'other-job' "$td/tab")" 1
[ ! -f "$td/runner/stability-scorecard.sh" ] && ok "disarm removes the runner" || bad "disarm removes the runner"
bash "$tool" status | grep -q '^not armed' && ok "status reads not armed" || bad "status reads not armed"

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed"; exit 1
