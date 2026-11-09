#!/usr/bin/env bash
# scripts/eval/test-rollup-cadence.sh - suite for the weekly roll-up cadence (rollup-cadence.sh): arm, status,
# disarm against a stub crontab, and `run` against a stub weekly-rollup.py. Never the real crontab, HOME or
# alert channel; no model call.
# shellcheck disable=SC2016,SC2034
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
CAD="$HERE/rollup-cadence.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/rollup-cadence-test.XXXXXX")" || { echo "test-rollup-cadence: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP test-rollup-cadence: python3 not on PATH"; exit 0; }
[ -f "$CAD" ] || { fail "rollup-cadence.sh is present"; echo "rollup-cadence: $PASS passed, $FAIL failed"; exit 1; }

STUB="$TMP/stub"; mkdir -p "$STUB" "$TMP/home"
export HOME="$TMP/home"
printf '#!/usr/bin/env bash\nexit 0\n' >"$STUB/notify"; chmod +x "$STUB/notify"
cat >"$STUB/crontab" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "-l" ]; then [ -s "$TMP/tab" ] && { cat "$TMP/tab"; exit 0; }; echo "no crontab for test" >&2; exit 1; fi
cat >"$TMP/tab"
EOF
chmod +x "$STUB/crontab"
cat >"$STUB/rollup.py" <<'EOF'
import os, sys
print("stub weekly-rollup:", " ".join(sys.argv[1:]))
sys.exit(int(os.environ.get("STUB_RC", "0")))
EOF
export ROLLUP_CRONTAB="$STUB/crontab" ROLLUP_RUNNER_DIR="$TMP/runner" ROLLUP_PY="$STUB/rollup.py"
export CADENCE_ALERT_FILE="$TMP/alerts.log" CADENCE_ALERT_DEDUPE_DIR="$TMP/alert-sent" CADENCE_ALERT_SEND_CMD="$STUB/notify" CADENCE_ALERT_SEND_FAILED_MARK="$TMP/alert-send-failed"

# --- the cadence verbs ---------------------------------------------------------------------------------
bash "$CAD" status >"$TMP/st0.out" 2>&1
check "status before arming reads not armed" 'grep -q "^not armed  HIMMEL-WeeklyRollup" "$TMP/st0.out"'
bash "$CAD" arm --dry-run >"$TMP/dry.out" 2>&1
check "arm --dry-run writes nothing" '[ ! -s "$TMP/tab" ] && [ ! -e "$TMP/runner" ] && grep -q "DRY rollup-cadence" "$TMP/dry.out"'
bash "$CAD" arm >"$TMP/arm0.out" 2>&1
check "arm defaults to Monday 06:00" '[ "$(grep -c "# HIMMEL-WeeklyRollup" "$TMP/tab")" = 1 ] && grep -q "^00 06 \* \* 1 " "$TMP/tab"'
check "arm writes an executable runner that runs the primary checkout" '[ -x "$TMP/runner/rollup-cadence.sh" ] && grep -q " run --repo " "$TMP/runner/rollup-cadence.sh" && grep -q "\[exit rc=" "$TMP/runner/rollup-cadence.sh"'
bash "$CAD" status >"$TMP/st1.out" 2>&1
check "status after arming reads ARMED with the cron fields" 'grep -q "^ARMED      HIMMEL-WeeklyRollup (00 06 \* \* 1)" "$TMP/st1.out"'
bash "$CAD" arm >"$TMP/arm1.out" 2>&1; rc=$?
check "a second arm exits 3 and leaves one entry" '[ "$rc" = 3 ] && [ "$(grep -c "# HIMMEL-WeeklyRollup" "$TMP/tab")" = 1 ]'
bash "$CAD" arm --force --day 3 --time 07:30 >"$TMP/arm2.out" 2>&1
check "arm --force replaces the entry on the chosen day and time" '[ "$(grep -c "# HIMMEL-WeeklyRollup" "$TMP/tab")" = 1 ] && grep -q "^30 07 \* \* 3 " "$TMP/tab"'
bash "$CAD" arm --day 9 >/dev/null 2>&1; rc=$?
check "arm --day 9 exits 1" '[ "$rc" = 1 ]'
bash "$CAD" arm --time 25:00 >/dev/null 2>&1; rc=$?
check "arm --time 25:00 exits 1" '[ "$rc" = 1 ]'
bash "$CAD" arm --bogus >/dev/null 2>&1; rc=$?
check "arm with an unknown argument exits 1" '[ "$rc" = 1 ]'

# --- run -----------------------------------------------------------------------------------------------
bash "$CAD" run --repo "$TMP" >"$TMP/run0.out" 2>&1; rc=$?
check "run passes the repo and --versions 2 to weekly-rollup.py and exits 0" '[ "$rc" = 0 ] && grep -q "write --repo $TMP --versions 2" "$TMP/run0.out"'
STUB_RC=2 bash "$CAD" run --repo "$TMP" >"$TMP/run1.out" 2>&1; rc=$?
check "a failing roll-up makes run exit with its code and raises an alert" '[ "$rc" = 2 ] && grep -q "the weekly roll-up run failed (exit 2)" "$CADENCE_ALERT_FILE"'
bash "$CAD" run --bogus >/dev/null 2>&1; rc=$?
check "run with an unknown argument exits 1" '[ "$rc" = 1 ]'

# --- status reads the shared run log shape --------------------------------------------------------------
mkdir -p "$TMP/runner"
printf '[fired 2026-11-09 06:00:00]\nstub\n[exit rc=0]\n' >"$TMP/runner/rollup-cadence.log"
bash "$CAD" status >"$TMP/st2.out" 2>&1
check "status prints the run log line the cadence-runs probe reads" 'grep -qE "^  run log    .*rollup-cadence.log \(last write: [0-9-]+ [0-9:]+\)$" "$TMP/st2.out" && grep -q "^             last line: \[exit rc=0\]$" "$TMP/st2.out"'

# --- disarm --------------------------------------------------------------------------------------------
bash "$CAD" disarm --dry-run >/dev/null 2>&1
check "disarm --dry-run keeps the entry" 'grep -q "# HIMMEL-WeeklyRollup" "$TMP/tab"'
bash "$CAD" disarm >"$TMP/dis0.out" 2>&1; rc=$?
check "disarm removes the entry and the runner" '[ "$rc" = 0 ] && ! grep -q "# HIMMEL-WeeklyRollup" "$TMP/tab" && [ ! -e "$TMP/runner/rollup-cadence.sh" ]'
bash "$CAD" disarm >"$TMP/dis1.out" 2>&1; rc=$?
check "disarm with nothing armed is a no-op that exits 0" '[ "$rc" = 0 ] && grep -q "nothing armed" "$TMP/dis1.out"'
bash "$CAD" bogus >/dev/null 2>&1; rc=$?
check "an unknown verb exits 1" '[ "$rc" = 1 ]'

echo "rollup-cadence: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
