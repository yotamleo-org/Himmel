#!/usr/bin/env bash
# selector: tree-scan
# scripts/ci/test-run-shell-tests-cap-alert.sh -- a suite that only
# hits its time cap (after the one retry) is a CAP-ALERT and exits 0; a FAIL row
# of its own still exits 1; a `daily` tier suite leaves every CI mode.
#
# Rows:
#   CA1  cap hit on both attempts, no FAIL row      -> rc 0, CAP-ALERT, alert file, TIMED OUT not counted
#   CA2  cap hit plus a FAIL row                    -> rc 1, CAP EXCEEDED
#   CA3  plain FAIL                                 -> rc 1
#   CA4  a row that got rc 124 where it wanted a wake (the real CI row of main
#        run 45534239589, shard 6/8) on both attempts -> rc 0, CAP-ALERT
#   CA5  a hang-guard row (want '124') that failed  -> rc 1
#   CA6  a real FAIL on the first attempt, cap hit on the retry -> rc 1
#   CA7  a `# no-retry` suite that hit its cap       -> rc 1 (no retry happened)
#   CA8  a `daily` row is skipped in all / pr / fast, and the only tier run by daily
#
# Platform guard: bash-only, like every suite in this family; Linux/macOS.
# Usage: bash scripts/ci/test-run-shell-tests-cap-alert.sh
# Exit codes: 0 -- all cases passed; 1 -- at least one failed.
# shellcheck disable=SC2016 # fixtures are literal shell text
set -uo pipefail

# shellcheck source=run-shell-tests-fixture.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/run-shell-tests-fixture.sh"

sb=$(mktemp -d "${TMPDIR:-/tmp}/rst-capalert.XXXXXX") || { fail "CA: mktemp failed"; rst_tally; exit 1; }
: "${sb:?}"
mkdir -p "$sb/scripts" "$sb/logs"
trap 'rm -rf "$sb" "$SUITE_LOCK_SANDBOX"' EXIT

mk() {
  mkdir -p "$sb/$1"
  printf '#!/usr/bin/env bash\nCA_DIR="%s"\necho run >> "$CA_DIR/%s.runs"\n%s\n' "$sb" "$1" "$2" > "$sb/$1/test-$1.sh"
  chmod +x "$sb/$1/test-$1.sh"
}
runs() { wc -l < "$sb/$1.runs" 2>/dev/null | tr -d ' '; }
run() {
  local d="$1"; shift
  out=$(env FAIL_LOG_DIR="$sb/logs/$d" SUITE_FLAKE_LEDGER="$sb/flake.jsonl" SUITE_TIMEOUT=2 SUITE_TIER_MODE=all "$@" bash "$RUNNER" "$sb/$d" 2>&1)
  rc=$?
}

mk capok 'sleep 30'
run capok
if [ "$rc" -eq 0 ] && [ "$(runs capok)" = 2 ] && grepq "$out" -E '^CAP-ALERT [^ ]*test-capok\.sh \(ran [0-9]+s, cap 2s' \
    && grepq "$out" -F ' CAP-ALERT: 1' && ! grepq "$out" -F '[FAIL]' && ! grepq "$out" -F 'TIMED OUT'; then
  pass "CA1: a suite that hit its cap on both attempts and printed no FAIL row is a CAP-ALERT, rc 0, run twice"
else
  fail "CA1: rc=$rc runs=$(runs capok) (want rc 0, 2 runs, a CAP-ALERT line and summary count, no FAIL, no TIMED OUT) out: $out"
fi
if grepq "$(cat "$sb/logs/capok/cap-alerts.txt" 2>/dev/null)" -E '^CAP-ALERT [^ ]*test-capok\.sh'; then
  pass "CA1b: the alert is written to FAIL_LOG_DIR/cap-alerts.txt"
else
  fail "CA1b: no CAP-ALERT line in $sb/logs/capok/cap-alerts.txt"
fi

mk capfail 'echo "FAIL: a row of its own (want '"'"'a'"'"' got '"'"'b'"'"')"; sleep 30'
run capfail
if [ "$rc" -eq 1 ] && grepq "$out" -F '[CAP EXCEEDED]' && ! grepq "$out" -E '^CAP-ALERT'; then
  pass "CA2: a cap hit that printed a FAIL row of its own is CAP EXCEEDED, rc 1, no alert"
else
  fail "CA2: rc=$rc (want rc 1, CAP EXCEEDED, no CAP-ALERT) out: $out"
fi

mk plainfail 'echo "FAIL: x"; exit 1'
run plainfail
if [ "$rc" -eq 1 ] && ! grepq "$out" -E '^CAP-ALERT'; then
  pass "CA3: a plain FAIL is rc 1"
else
  fail "CA3: rc=$rc out: $out"
fi

mk row124 'echo "FAIL: (8349) a series whose tickets changed wakes (rc 0) (want '"'"'0'"'"' got '"'"'124'"'"')"; exit 1'
run row124
if [ "$rc" -eq 0 ] && [ "$(runs row124)" = 2 ] && grepq "$out" -E '^CAP-ALERT [^ ]*test-row124\.sh'; then
  pass "CA4: a row that wanted a wake and got rc 124 on both attempts is a CAP-ALERT, rc 0"
else
  fail "CA4: rc=$rc runs=$(runs row124) (want rc 0, 2 runs, a CAP-ALERT line) out: $out"
fi

mk guard124 'echo "FAIL: (8349) the same series pool does not wake again (rc 124) (want '"'"'124'"'"' got '"'"'0'"'"')"; exit 1'
run guard124
if [ "$rc" -eq 1 ] && ! grepq "$out" -E '^CAP-ALERT'; then
  pass "CA5: a hang-guard row (want 124) that failed stays a FAIL, rc 1"
else
  fail "CA5: rc=$rc (want rc 1, no CAP-ALERT) out: $out"
fi

mk firstfail '[ "$(wc -l < "$CA_DIR/firstfail.runs")" -ge 2 ] || { echo "FAIL: a real row (want '"'"'a'"'"' got '"'"'b'"'"')"; exit 1; }
sleep 30'
run firstfail
if [ "$rc" -eq 1 ] && ! grepq "$out" -E '^CAP-ALERT'; then
  pass "CA6: a real FAIL on the first attempt then a cap hit on the retry stays rc 1"
else
  fail "CA6: rc=$rc (want rc 1, no CAP-ALERT) out: $out"
fi

mkdir -p "$sb/noretry"
printf '#!/usr/bin/env bash\n# no-retry\necho run >> "%s/noretry.runs"\nsleep 30\n' "$sb" > "$sb/noretry/test-noretry.sh"
chmod +x "$sb/noretry/test-noretry.sh"
run noretry
if [ "$rc" -eq 1 ] && [ "$(runs noretry)" = 1 ] && ! grepq "$out" -E '^CAP-ALERT'; then
  pass "CA7: a no-retry suite that hit its cap ran once and stays rc 1"
else
  fail "CA7: rc=$rc runs=$(runs noretry) (want rc 1, 1 run, no CAP-ALERT) out: $out"
fi

mkdir -p "$sb/tier"
printf '#!/usr/bin/env bash\necho run >> "%s/tier-daily.runs"\nexit 0\n' "$sb" > "$sb/tier/test-timed.sh"
printf '#!/usr/bin/env bash\necho run >> "%s/tier-plain.runs"\nexit 0\n' "$sb" > "$sb/tier/test-plain.sh"
chmod +x "$sb/tier/test-timed.sh" "$sb/tier/test-plain.sh"
printf '# fixture tiers\n%s/tier/test-timed.sh\tdaily\ttiming rows only\n' "$sb" > "$sb/tiers.tsv"
for mode in all pr fast; do
  rm -f "$sb/tier-daily.runs" "$sb/tier-plain.runs"
  out=$(SUITE_TIERS_TSV="$sb/tiers.tsv" SUITE_TIER_MODE="$mode" bash "$RUNNER" "$sb/tier" 2>&1); rc=$?
  if [ "$rc" -eq 0 ] && [ ! -e "$sb/tier-daily.runs" ] && [ -e "$sb/tier-plain.runs" ] && grepq "$out" -E '\[SKIP\] [^ ]*test-timed\.sh .*tier: daily'; then
    pass "CA8-$mode: SUITE_TIER_MODE=$mode skips a daily suite and runs the others"
  else
    fail "CA8-$mode: rc=$rc daily-ran=$([ -e "$sb/tier-daily.runs" ] && echo yes || echo no) plain-ran=$([ -e "$sb/tier-plain.runs" ] && echo yes || echo no) out: $out"
  fi
done
rm -f "$sb/tier-daily.runs" "$sb/tier-plain.runs"
out=$(SUITE_TIERS_TSV="$sb/tiers.tsv" SUITE_TIER_MODE=daily bash "$RUNNER" "$sb/tier" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ -e "$sb/tier-daily.runs" ] && [ ! -e "$sb/tier-plain.runs" ] && grepq "$out" -E '\[SKIP\] [^ ]*test-plain\.sh .*tier: not daily'; then
  pass "CA8-daily: SUITE_TIER_MODE=daily runs only the daily suite"
else
  fail "CA8-daily: rc=$rc daily-ran=$([ -e "$sb/tier-daily.runs" ] && echo yes || echo no) plain-ran=$([ -e "$sb/tier-plain.runs" ] && echo yes || echo no) out: $out"
fi

rst_tally
