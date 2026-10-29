#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in the pass/fail reporting lines
# test-doctor-status-drift.sh — Exercises the doctor's C80 status-drift check against a planted
# focus-drift.txt (HIMMEL_DOCTOR_FOCUS_DRIFT), a planted known-bug file (DRIFT_SUMMARY_KNOWN) and a
# planted mirror, all under a temp HOME. The check reads the saved file and never re-runs the
# drift pass. bash 3.2-safe.
#
# Run: bash scripts/test-doctor-status-drift.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOC="$ROOT/scripts/himmel-doctor.sh"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3' in: $2)" ;; esac; }
lacks() { case "$2" in *"$3"*) fail "$1 (found '$3')" ;; *) pass "$1" ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/doctor-status-drift-test.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" CLAUDE_DIR="$WORK/claude" HIMMEL_CONFIG_DIR="$WORK/conf"
export HIMMEL_DOCTOR_FOCUS_DRIFT="$WORK/focus-drift.txt" DRIFT_SUMMARY_KNOWN="$WORK/known.tsv"
mkdir -p "$HOME" "$CLAUDE_DIR" "$HIMMEL_CONFIG_DIR" "$HOME/.himmel/state/jira-mirror/HIMMEL"
unset JIRA_PROJECT_KEY
printf -- '---\nkey: "HIMMEL-7980"\nstatus: "To Do"\nstatusCategory: "To Do"\n---\n' > "$HOME/.himmel/state/jira-mirror/HIMMEL/HIMMEL-7980.md"
printf '# checker\tclass\tkey\tedited-at\nHIMMEL-7980\tUNOWNED\tHIMMEL-7588\t2026-10-28T22:00:00Z\n' > "$DRIFT_SUMMARY_KNOWN"

export TZ=UTC # the doctor prints the file's local HH:MM and stamp() computes it with date, so both read one zone
stamp() { # <seconds ago> -> "<touch -t stamp> <HH:MM>"
    python3 -I -c 'import sys,time; t=time.time()-int(sys.argv[1]); l=time.localtime(t); print(time.strftime("%Y%m%d%H%M.%S",l), time.strftime("%H:%M",l))' "$1"
}
plant() { # <seconds ago> <file body>; sets HM to the file's HH:MM
    local s
    s="$(stamp "$1")"
    printf '%s' "$2" > "$HIMMEL_DOCTOR_FOCUS_DRIFT"
    touch -t "${s% *}" "$HIMMEL_DOCTOR_FOCUS_DRIFT"
    HM="${s#* }"
}
doctor() { bash "$DOC" --only C80 --no-color 2>&1 | grep 'C80-status-drift'; }

THREE='VERSION-DRIFT HIMMEL-6691 a | writer=w | fix=f
VERSION-DRIFT HIMMEL-7891 a | writer=w | fix=f
VERSION-DRIFT HIMMEL-7944 a | writer=w | fix=f
UNOWNED HIMMEL-7588 b | writer=w | fix=f
WORKER-COMMENT HIMMEL-4862 c | writer=w | fix=f
sdrift=5:abcd1234
'

# E14 (RED first): a planted 3-real-row file with no mode key is WARN 3 with the file time
rm -f "$HIMMEL_CONFIG_DIR/himmel.conf"
plant 600 "$THREE"
out="$(doctor)"
has 'E14 a planted 3-real-row file with no mode key is WARN 3 with the file time' "$out" "WARN C80-status-drift: 3 real rows, single-user, file $HM (sdrift=5; 1 known-bug HIMMEL-7980, 1 transient) → #/board?tab=tidy"

# E21 doctor side: the key on turns the same file into INFO
printf 'HIMMEL_TRACKER_TEAM_MODE=on\n' > "$HIMMEL_CONFIG_DIR/himmel.conf"
out="$(doctor)"
has 'E21 team mode on makes the same file INFO' "$out" 'INFO C80-status-drift: team mode: 3 real rows → Tidy up'
lacks 'E21 and no WARN' "$out" 'WARN'
rm -f "$HIMMEL_CONFIG_DIR/himmel.conf"

# only known and transient rows: INFO, bug still open
plant 600 'UNOWNED HIMMEL-7588 b | writer=w | fix=f
sdrift=1:abcd1234
'
out="$(doctor)"
has 'known rows only is INFO and names the checker ticket' "$out" "INFO C80-status-drift: 0 real rows, file $HM (1 known-bug HIMMEL-7980)"

# no rows at all
plant 600 'sdrift=0:00000000
'
out="$(doctor)"
has 'zero rows is INFO' "$out" "INFO C80-status-drift: 0 rows, file $HM (sdrift=0)"

# unknown and stale are WARN, never a zero
plant 600 'HEALTH - jira: x | writer=- | fix=-
sdrift=unknown
'
out="$(doctor)"
has 'sdrift=unknown is WARN' "$out" 'WARN C80-status-drift: sdrift=unknown: the check could not read Jira or the PRs'
plant 40000 'sdrift=0:00000000
'
out="$(doctor)"
has 'a file older than one focus refresh is WARN stale' "$out" "WARN C80-status-drift: file $HM is stale: older than one focus refresh"

# no file
rm -f "$HIMMEL_DOCTOR_FOCUS_DRIFT"
out="$(doctor)"
has 'no focus-drift.txt is INFO' "$out" 'INFO C80-status-drift: no focus-drift.txt yet'

if [ "$fails" -gt 0 ]; then printf '%s failure(s)\n' "$fails"; exit 1; fi
echo "all passed"
