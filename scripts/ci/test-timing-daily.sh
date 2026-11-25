#!/usr/bin/env bash
# selector: tree-scan
# scripts/ci/test-timing-daily.sh -- scripts/ci/timing-daily.sh runs the daily-tier suites,
# reads CAP-ALERT lines and names the cap rows it would change.
#
#   TD1  CAP-ALERT lines from the daily run     -> rc 1, one WOULD-CHANGE line per suite, the cap doubled
#   TD2  a clean daily run                      -> rc 0, "no cap alerts"
#   TD3  a daily suite that failed              -> rc 1
#   TD4  --alerts on a CI log (prefixed lines)  -> WOULD-CHANGE from the largest cap seen
#   TD5  the runner is called in SUITE_TIER_MODE=daily
#   TD6  the real runner over a sandbox: only the daily suite runs, its cap hit is named
#   TD7  timing-daily.yml is a tracked workflow listed in workflow-red-list.txt and workflow-red.yml
#
# Platform guard: bash-only, like every suite in this family; Linux/macOS.
# Usage: bash scripts/ci/test-timing-daily.sh
# Exit codes: 0 -- all cases passed; 1 -- at least one failed.
# shellcheck disable=SC2016 # fixtures are literal shell text
set -uo pipefail

# shellcheck source=run-shell-tests-fixture.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/run-shell-tests-fixture.sh"

TD="$RST_FIXTURE_DIR/timing-daily.sh"
sb=$(mktemp -d "${TMPDIR:-/tmp}/timing-daily.XXXXXX") || { fail "TD: mktemp failed"; rst_tally; exit 1; }
: "${sb:?}"
trap 'rm -rf "$sb" "$SUITE_LOCK_SANDBOX"' EXIT

stub() {
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$sb/$1.sh"
  chmod +x "$sb/$1.sh"
}
td() { out=$(TIMING_DAILY_RUNNER="$sb/$1.sh" bash "$TD" "${@:2}" 2>&1); rc=$?; }

stub alert 'echo "CAP-ALERT scripts/a/test-slow.sh (ran 1200s, cap 600s, rc=124) — watchdog cap hit again on the retry, no FAIL row of its own; not failing the run"
echo "CAP-ALERT scripts/b/test-slower.sh (ran 2500s, cap 1250s, rc=124) — watchdog cap hit again on the retry, no FAIL row of its own; not failing the run"
exit 0'
td alert
if [ "$rc" -eq 1 ] && grepq "$out" -F 'WOULD-CHANGE scripts/a/test-slow.sh cap 600s -> 1200s' \
    && grepq "$out" -F 'WOULD-CHANGE scripts/b/test-slower.sh cap 1250s -> 2500s'; then
  pass "TD1: CAP-ALERT lines from the daily run exit 1 and name each cap row it would change"
else
  fail "TD1: rc=$rc (want 1 and two WOULD-CHANGE lines) out: $out"
fi

stub clean 'echo "OK: all 2 run suites passed (0 skipped) skipped=0"; exit 0'
td clean
if [ "$rc" -eq 0 ] && grepq "$out" -F 'no cap alerts' && grepq "$out" -F 'daily run: rc=0'; then
  pass "TD2: a clean daily run exits 0 and says no cap alerts"
else
  fail "TD2: rc=$rc out: $out"
fi

stub red 'echo "[FAIL] scripts/a/test-slow.sh (rc=1, 4s)"; exit 1'
td red
if [ "$rc" -eq 1 ] && grepq "$out" -F 'daily run: rc=1'; then
  pass "TD3: a failed daily suite exits 1"
else
  fail "TD3: rc=$rc out: $out"
fi

cat > "$sb/ci.log" <<'LOGEOF'
shell-unit-shard (ubuntu-latest, 6)	Run bash scripts/ci/home-canary.sh --shard 6/8 .	2026-11-25T03:11:56.7541447Z CAP-ALERT scripts/handover/chief-kit/test-chief-wait-pool.sh (ran 2500s, cap 1250s, rc=124) — watchdog cap hit again on the retry, no FAIL row of its own; not failing the run
shell-unit-shard (ubuntu-latest, 3)	Run bash scripts/ci/home-canary.sh --shard 3/8 .	2026-11-25T03:12:56.7541447Z CAP-ALERT scripts/handover/chief-kit/test-chief-wait-pool.sh (ran 1400s, cap 700s, rc=124) — watchdog cap hit again on the retry, no FAIL row of its own; not failing the run
shell-unit-shard (ubuntu-latest, 3)	Run bash scripts/ci/home-canary.sh --shard 3/8 .	2026-11-25T03:12:57.0Z [PASS] scripts/x/test-fine.sh (3s)
LOGEOF
td clean --no-run --alerts "$sb/ci.log"
if [ "$rc" -eq 1 ] && grepq "$out" -F 'WOULD-CHANGE scripts/handover/chief-kit/test-chief-wait-pool.sh cap 1250s -> 2500s (2 alert line(s))' \
    && grepq "$out" -F 'daily run: skipped' && ! grepq "$out" -F 'test-fine.sh'; then
  pass "TD4: --alerts reads CAP-ALERT lines from a CI log and keeps the largest cap per suite"
else
  fail "TD4: rc=$rc out: $out"
fi

td clean --no-run --alerts "$sb/missing.log"
if [ "$rc" -eq 1 ] && grepq "$out" -F 'cannot read' && grepq "$out" -F 'alert sources: not all read'; then
  pass "TD4b: an unreadable --alerts file exits 1 instead of being skipped"
else
  fail "TD4b: rc=$rc out: $out"
fi

if date -d '1 hour ago' +%s > /dev/null 2>&1; then # gnu-ok: the daily job runs on Linux; the rows skip where date has no -d
  mkdir -p "$sb/bin"
  printf '#!/usr/bin/env bash\ncase "$1 $2" in\n  "run list") echo 111 ;;\n  *) exit 1 ;;\nesac\n' > "$sb/bin/gh"
  chmod +x "$sb/bin/gh"
  out=$(PATH="$sb/bin:$PATH" TIMING_DAILY_RUNNER="$sb/clean.sh" bash "$TD" --no-run --ci-hours 1 2>&1); rc=$?
  if [ "$rc" -eq 1 ] && grepq "$out" -F 'gh run view 111 failed' && grepq "$out" -F 'alert sources: not all read'; then
    pass "TD4c: a main CI log that cannot be read exits 1 instead of reading as no alerts"
  else
    fail "TD4c: rc=$rc out: $out"
  fi
fi

stub mode 'echo "mode=$SUITE_TIER_MODE"; exit 0'
td mode
if grepq "$out" -F 'mode=daily'; then
  pass "TD5: the runner is called with SUITE_TIER_MODE=daily"
else
  fail "TD5: out: $out"
fi

mkdir -p "$sb/scan"
printf '#!/usr/bin/env bash\necho run >> "%s/daily.runs"\nsleep 30\n' "$sb" > "$sb/scan/test-timed.sh"
printf '#!/usr/bin/env bash\necho run >> "%s/plain.runs"\nexit 0\n' "$sb" > "$sb/scan/test-plain.sh"
chmod +x "$sb/scan/test-timed.sh" "$sb/scan/test-plain.sh"
printf '# fixture tiers\n%s/scan/test-timed.sh\tdaily\ttiming suite\n' "$sb" > "$sb/tiers.tsv"
out=$(SUITE_TIERS_TSV="$sb/tiers.tsv" SUITE_TIMEOUT=2 SUITE_FLAKE_LEDGER="$sb/flake.jsonl" TIMING_DAILY_SCAN="$sb/scan" bash "$TD" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && [ "$(wc -l < "$sb/daily.runs" 2>/dev/null | tr -d ' ')" = 2 ] && [ ! -e "$sb/plain.runs" ] \
    && grepq "$out" -E 'WOULD-CHANGE [^ ]*test-timed\.sh cap 2s -> 4s'; then
  pass "TD6: the real runner ran only the daily suite (twice, once per attempt) and the job names its cap row"
else
  fail "TD6: rc=$rc daily-runs=$(wc -l < "$sb/daily.runs" 2>/dev/null | tr -d ' ') plain-ran=$([ -e "$sb/plain.runs" ] && echo yes || echo no) out: $out"
fi

wf="$RST_FIXTURE_DIR/../../.github/workflows/timing-daily.yml"
if [ -f "$wf" ] && grep -qxF 'timing-daily' "$RST_FIXTURE_DIR/workflow-red-list.txt" \
    && grep -qE '^    workflows: \[.*\btiming-daily\b' "$RST_FIXTURE_DIR/../../.github/workflows/workflow-red.yml" \
    && grep -qE '^name: timing-daily$' "$wf" && grep -qF 'bash scripts/ci/timing-daily.sh' "$wf"; then
  pass "TD7: timing-daily.yml runs timing-daily.sh and is tracked by workflow-red (list and trigger)"
else
  fail "TD7: timing-daily.yml missing, or not in workflow-red-list.txt / workflow-red.yml, or not calling timing-daily.sh"
fi

rst_tally
