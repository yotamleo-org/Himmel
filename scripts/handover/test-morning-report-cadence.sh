#!/usr/bin/env bash
# test-morning-report-cadence.sh — scripts/handover/morning-report-cadence.sh.
# Hermetic: stub crontab, temp runner dir, stub generator, temp HANDOVER_DIR, temp HOME.
# Never touches the live crontab or a real handover root.
# shellcheck disable=SC2015  # `A && pass || fail`: pass always succeeds
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
CAD="$DIR/morning-report-cadence.sh"
FAILED=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2', got '$3')"; fi; }

W="$(mktemp -d "${TMPDIR:-/tmp}/mr-cadence-test.XXXXXX")" || exit 1
W="$(cd "$W" && pwd -P)" || exit 1
trap 'rm -rf "$W"' EXIT
export HOME="$W/home"; mkdir -p "$HOME"
export HANDOVER_DIR="$W/ho"; mkdir -p "$HANDOVER_DIR"
export MORNINGREPORT_RUNNER_DIR="$W/runner"
export MORNINGREPORT_CRONTAB="$W/crontab"
export MORNINGREPORT_GENERATOR="$W/gen.sh"
TAB="$W/tab"; : > "$TAB"
export TAB
# stub crontab: -l prints the table, - replaces it from stdin
cat > "$W/crontab" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "-l" ]; then cat "$TAB"; else cat > "$TAB"; fi
SH
chmod +x "$W/crontab"
# stub generator: writes the report into HANDOVER_DIR like the real one
cat > "$W/gen.sh" <<'SH'
#!/usr/bin/env bash
: > "$HANDOVER_DIR/morning-report-2026-11-04.md"
SH
printf '0 1 * * * /other/job # HIMMEL-Other\n' > "$TAB"

n_entries() { grep -c '# HIMMEL-MorningReport' "$TAB"; }

# arm
bash "$CAD" arm --dry-run >/dev/null; check "arm --dry-run writes nothing" 0 "$(n_entries)"
bash "$CAD" arm >/dev/null; check "arm writes one entry" 1 "$(n_entries)"
check "arm keeps the other cron line" 1 "$(grep -c 'HIMMEL-Other' "$TAB")"
grep -q '^10 07 \* \* \* ' "$TAB" && pass "default time 07:10" || fail "default time 07:10"
R="$W/runner/morning-report-cadence.sh"
grep -q "^HANDOVER_DIR=" "$R" && grep -q "^PATH=" "$R" && pass "runner carries HANDOVER_DIR and PATH" || fail "runner carries HANDOVER_DIR and PATH"
bash "$CAD" arm >/dev/null 2>&1; check "second arm refuses (rc 3)" 3 "$?"
check "second arm adds no entry" 1 "$(n_entries)"
bash "$CAD" arm --force --time 08:00 >/dev/null; check "arm --force replaces, not duplicates" 1 "$(n_entries)"
st="$(bash "$CAD" arm --auto)"; grep -q 'already armed' <<< "$st" && pass "arm --auto is a no-op when armed" || fail "arm --auto is a no-op when armed"
check "arm --auto adds no entry" 1 "$(n_entries)"

# status
st="$(bash "$CAD" status)"; grep -q '^ARMED' <<< "$st" && pass "status says ARMED" || fail "status says ARMED"

# run
bash "$CAD" run; check "run rc 0 with the stub generator" 0 "$?"
[ -f "$HANDOVER_DIR/morning-report-2026-11-04.md" ] && pass "run wrote the report into the temp root" || fail "run wrote the report into the temp root"
st="$(bash "$CAD" status)"; grep -q 'morning-report-2026-11-04.md' <<< "$st" && pass "status names the newest report" || fail "status names the newest report"
rm -f "$HANDOVER_DIR"/morning-report-*.md
(unset HANDOVER_DIR; bash "$CAD" run >/dev/null 2>&1); check "run with no root fails loud (rc 2)" 2 "$?"
ls "$HANDOVER_DIR"/morning-report-*.md >/dev/null 2>&1 && fail "run with no root wrote nothing" || pass "run with no root wrote nothing"

# disarm and the operator's choice
bash "$CAD" disarm --dry-run >/dev/null; check "disarm --dry-run keeps the entry" 1 "$(n_entries)"
bash "$CAD" disarm >/dev/null; check "disarm removes only its entry" 0 "$(n_entries)"
check "disarm leaves the other cron line" 1 "$(grep -c 'HIMMEL-Other' "$TAB")"
st="$(bash "$CAD" status)"; grep -q '^not armed' <<< "$st" && pass "status says not armed" || fail "status says not armed"
st="$(bash "$CAD" arm --auto)"; grep -q 'operator disarmed' <<< "$st" && pass "arm --auto respects a disarm" || fail "arm --auto respects a disarm"
check "arm --auto after disarm adds no entry" 0 "$(n_entries)"
bash "$CAD" arm >/dev/null; check "a plain arm re-arms after a disarm" 1 "$(n_entries)"
bash "$CAD" disarm >/dev/null; rm -f "$W/runner/.operator-disarmed"
bash "$CAD" arm --auto >/dev/null; check "arm --auto arms a never-armed machine" 1 "$(n_entries)"
bash "$CAD" arm --auto >/dev/null; check "second arm --auto adds no entry" 1 "$(n_entries)"

bash "$CAD" disarm >/dev/null; rm -f "$W/runner/.operator-disarmed"
bash "$CAD" disarm >/dev/null; st="$(bash "$CAD" arm --auto)"
grep -q 'operator disarmed' <<< "$st" && pass "a disarm before any arm keeps arm --auto off" || fail "a disarm before any arm keeps arm --auto off"
check "no entry after a disarm on a never-armed machine" 0 "$(n_entries)"

rm -f "$W/runner/.operator-disarmed"; chmod 500 "$W/runner"
bash "$CAD" disarm >/dev/null 2>&1; rc=$?
chmod 700 "$W/runner"
if [ "$(id -u)" -eq 0 ]; then pass "unwritable marker dir (skipped as root)"; else check "disarm fails loud (rc 4) when the marker cannot be written" 4 "$rc"; fi

# two cadences arming at the same moment both land, with the unrelated job
export W
cat > "$W/slowcron" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = "-l" ] && sleep 0.4
exec "$W/crontab" "$@"
SH
chmod +x "$W/slowcron"
printf '0 1 * * * /other/job # HIMMEL-Other\n' > "$TAB"
MORNINGREPORT_CRONTAB="$W/slowcron" bash "$CAD" arm >/dev/null 2>&1 & p1=$!
SECURITY_AUDIT_CRONTAB="$W/slowcron" SECURITY_AUDIT_RUNNER_DIR="$W/sa-runner" bash "$DIR/../security/security-audit-cadence.sh" arm >/dev/null 2>&1 & p2=$!
wait "$p1"; r1=$?; wait "$p2"; r2=$?
check "concurrent arms both exit 0" "0 0" "$r1 $r2"
check "concurrent arms keep the morning-report entry" 1 "$(grep -c '# HIMMEL-MorningReport' "$TAB")"
check "concurrent arms keep the security-audit entry" 1 "$(grep -c '# HIMMEL-SecurityAudit' "$TAB")"
check "concurrent arms keep the unrelated job" 1 "$(grep -c 'HIMMEL-Other' "$TAB")"

[ "$FAILED" -eq 0 ] && echo "ALL PASS" || { echo "$FAILED FAILED"; exit 1; }
