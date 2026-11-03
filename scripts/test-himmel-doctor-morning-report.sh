#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is the pass/fail idiom
# test-himmel-doctor-morning-report.sh — doctor C86-morning-report:
# WARN when the newest morning-report-YYYY-MM-DD.md under the handover root is over 36 h old,
# OK when fresh, INFO when there is no root or a never-armed machine has no report.
# Every fixture lives under a temp dir; the real HOME, crontab and handover root are never read.
# Run: bash scripts/test-himmel-doctor-morning-report.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOC="$ROOT/scripts/himmel-doctor.sh"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3' in: $2)" ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/doctor-morning-report-test.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
PROJ="$WORK/root"
mkdir -p "$PROJ/.claude" "$WORK/home" "$WORK/claude" "$WORK/ho" "$WORK/runner"
ln -s "$ROOT/scripts" "$PROJ/scripts"
# shellcheck disable=SC2016  # the stub's own $TAB stays literal
printf '#!/usr/bin/env bash\ncat "$TAB"\n' > "$WORK/crontab"; chmod +x "$WORK/crontab"
TAB="$WORK/tab"; : > "$TAB"; export TAB

doctor() { # [HANDOVER_DIR value]
    HOME="$WORK/home" CLAUDE_DIR="$WORK/claude" HANDOVER_DIR="${1-$WORK/ho}" \
        MORNINGREPORT_CRONTAB="$WORK/crontab" MORNINGREPORT_RUNNER_DIR="$WORK/runner" \
        bash "$DOC" --root "$PROJ" --only C86 --no-color 2>&1
}

echo "== newest report is 2026-10-14 (old mtime) -> WARN =="
: > "$WORK/ho/morning-report-2026-10-14.md"; touch -d '2026-10-14 08:00' "$WORK/ho/morning-report-2026-10-14.md"
out="$(doctor)"
has "stale report -> WARN row" "$out" "WARN C86-morning-report"
has "names the newest report" "$out" "morning-report-2026-10-14.md"

echo "== a report of today -> OK =="
today="morning-report-$(date +%F).md"
: > "$WORK/ho/$today"
out="$(doctor)"
has "fresh report -> OK row" "$out" "OK   C86-morning-report"

echo "== no handover root -> INFO =="
rm -f "$WORK/ho"/morning-report-*.md
out="$(doctor "$WORK/missing")"
has "missing root -> INFO" "$out" "INFO C86-morning-report"

echo "== root, no report, cadence never armed -> INFO =="
out="$(doctor)"
has "never armed, no report -> INFO" "$out" "INFO C86-morning-report"

echo "== root, no report, cadence armed long ago -> WARN =="
printf '10 07 * * * /r # HIMMEL-MorningReport\n' > "$TAB"
: > "$WORK/runner/morning-report-cadence.sh"; touch -d '3 days ago' "$WORK/runner/morning-report-cadence.sh"
out="$(doctor)"
has "armed 3 days ago, no report -> WARN" "$out" "WARN C86-morning-report"

echo "== root, no report, cadence armed just now -> INFO =="
touch "$WORK/runner/morning-report-cadence.sh"
out="$(doctor)"
has "armed just now, no report -> INFO" "$out" "INFO C86-morning-report"

echo "== root, no report, cadence armed but the runner is missing -> WARN =="
rm -f "$WORK/runner/morning-report-cadence.sh"
out="$(doctor)"
has "armed, runner missing -> WARN" "$out" "WARN C86-morning-report"
has "names the missing runner" "$out" "runner is missing"

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
