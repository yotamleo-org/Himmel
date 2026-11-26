#!/usr/bin/env bash
# scripts/luna-vitals/connectors/test-pull-cadence-arm.sh — hermetic suite for
# the daily Google Health connector pull cadence's arm/status/disarm
# subcommands. Distinct from pull-cadence.test.ts, which covers
# the connector-pull path itself (bun/Bun.spawn, no args) — this covers ONLY
# the scheduler management this ticket adds.
#
# Platform guard: POSIX bash 3.2+ on Linux/macOS. Scheduler access is stubbed;
# a dropped platform is refused before any scheduler command runs.
#
# HIMMEL_OBSERVABILITY_CONFIG is pinned to a per-test scratch file on EVERY
# invocation — never omit it, or a hand run registers a real task into
# ~/.himmel/observability.json (the leak this pattern
# exists to avoid).
#
# bash 3.2-safe: no mapfile, no associative arrays.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CADENCE="$SCRIPT_DIR/pull-cadence.sh"

fails=0
pass() { echo "  ok   — $1"; }
fail() { echo "  FAIL — $1"; fails=$((fails + 1)); }

assert_rc() {
  local want="$1" label="$2"; shift 2
  local out rc
  out=$("$@" 2>&1); rc=$?
  if [ "$rc" -eq "$want" ]; then pass "$label (rc=$rc)"
  else fail "$label — expected rc=$want got rc=$rc; output: $out"; fi
}

assert_has() {
  local hay="$1" needle="$2" label="$3"
  case "$hay" in
    *"$needle"*) pass "$label" ;;
    *) fail "$label — '$needle' not found in output" ;;
  esac
}

# Stub himmel root carrying exactly the payload file require_payload checks
# for on POSIX (the .sh path, invoked with no args by the armed cadence).
make_root() {
  local root
  root=$(mktemp -d "${TMPDIR:-/tmp}/pull-cadence-test-root.XXXXXX")
  mkdir -p "$root/scripts/luna-vitals/connectors"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$root/scripts/luna-vitals/connectors/pull-cadence.sh"
  chmod +x "$root/scripts/luna-vitals/connectors/pull-cadence.sh"
  printf '%s' "$root"
}

# Fake crontab — same shape as test-upstream-watch-cadence.sh's.
make_fake_crontab() {
  local state="$1" f="$1/crontab"
  cat > "$f" <<'FAKE'
#!/usr/bin/env bash
state="$(dirname "$0")"
echo "$*" >> "$state/calls"
case "${1:-}" in
  -l)
    if [ -f "$state/tab" ]; then cat "$state/tab"; exit 0; fi
    echo "no crontab for tester" >&2; exit 1 ;;
  -)
    cat > "$state/tab"; exit 0 ;;
esac
exit 0
FAKE
  chmod +x "$f"
  printf '%s' "$f"
}

new_scratch_posix() {
  local state
  state=$(mktemp -d "${TMPDIR:-/tmp}/pull-cadence-test-posix.XXXXXX")
  make_fake_crontab "$state" >/dev/null
  printf '%s' "$state"
}

# run_cadence <state> <args...> — pins PULLCADENCE_* + HIMMEL_OBSERVABILITY_CONFIG
# so nothing ever reaches a real crontab or the real observability registry.
run_cadence() {
  local state="$1"; shift
  PULLCADENCE_CRONTAB="$state/crontab" \
    PULLCADENCE_BAT_DIR="$state/bat" \
    PULLCADENCE_HIMMEL_ROOT="$state/root" \
    PULLCADENCE_PLATFORM=posix \
    HIMMEL_OBSERVABILITY_CONFIG="$state/observability.json" \
    HIMMEL_PROVENANCE_DIR="$state/provenance" \
    bash "$CADENCE" "$@"
}

registry_has_task() {
  local reg="$1"
  [ -f "$reg" ] && jq -e '.expected_tasks // [] | index("HIMMEL-LunaVitalsPull")' "$reg" >/dev/null 2>&1
}

echo "== test: a dropped platform never reaches the scheduler =="
state_win=$(new_scratch_posix)
out=$(PULLCADENCE_PLATFORM=windows PULLCADENCE_SCHTASKS="$state_win/crontab" \
  PULLCADENCE_CRONTAB="$state_win/crontab" \
  PULLCADENCE_BAT_DIR="$state_win/runner" PULLCADENCE_HIMMEL_ROOT="$state_win" \
  HIMMEL_OBSERVABILITY_CONFIG="$state_win/observability.json" \
  bash "$CADENCE" status 2>&1); rc=$?
if [ "$rc" -eq 2 ] && [[ "$out" == *"unsupported platform"* ]] && [ ! -e "$state_win/calls" ]; then
  pass "dropped platform: refused before scheduler access"
else
  fail "dropped platform: rc=$rc; output: $out; scheduler calls must be absent"
fi
rm -rf "$state_win"

echo "== test: dry-run arm makes no changes =="
state=$(new_scratch_posix); root=$(make_root); mv "$root" "$state/root"
out=$(run_cadence "$state" arm --dry-run --time 07:15 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "dry-run arm: rc=0"; else fail "dry-run arm: expected rc=0 got rc=$rc; output: $out"; fi
assert_has "$out" "dry-run complete" "dry-run arm: reports dry-run complete"
if [ -f "$state/bat/pull-cadence.sh" ]; then
  fail "dry-run arm: runner should not be published"
else
  pass "dry-run arm: no runner published"
fi
if registry_has_task "$state/observability.json"; then
  fail "dry-run arm: registry should be untouched"
else
  pass "dry-run arm: registry untouched"
fi

echo "== test: arm =="
out=$(run_cadence "$state" arm --time 07:15 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "arm: rc=0"; else fail "arm: expected rc=0 got rc=$rc; output: $out"; fi
assert_has "$out" "ARMED" "arm: reports ARMED"
if [ -x "$state/bat/pull-cadence.sh" ]; then pass "arm: runner published + executable"; else fail "arm: runner not published/executable"; fi
if grep -qF 'HIMMEL-LunaVitalsPull' "$state/tab" 2>/dev/null; then pass "arm: cron entry installed"; else fail "arm: no cron entry installed"; fi
if registry_has_task "$state/observability.json"; then pass "arm: registered in scratch registry"; else fail "arm: not registered in scratch registry"; fi
# The arm records a `job register` row so uninstall can remove this line.
jobs=$(HIMMEL_PROVENANCE_DIR="$state/provenance" bash -c '. "$1/lib/provenance.sh" && . "$1/lib/provenance-read.sh" && prov_read_load >/dev/null && prov_read_units --kind job | jq -r ".unit + \" ours=\" + (.ours|tostring) + \" scheduler=\" + .fields.scheduler"' _ "$SCRIPT_DIR/../..")
assert_has "$jobs" "HIMMEL-LunaVitalsPull ours=true scheduler=cron" "arm: recorded the cron job row (ours, cron)"

echo "== test: status (armed) =="
out=$(run_cadence "$state" status 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "status: rc=0"; else fail "status: expected rc=0 got rc=$rc"; fi
assert_has "$out" "ARMED" "status: reports ARMED"
case "$out" in *DUPLICATE*) fail "status: single entry flagged duplicate" ;; *) pass "status: single entry not flagged" ;; esac
cp "$state/tab" "$state/tab.single"
grep -F 'HIMMEL-LunaVitalsPull' "$state/tab.single" | head -1 >>"$state/tab"
out=$(run_cadence "$state" status 2>&1)
assert_has "$out" "[DUPLICATE: 2 cron entries]" "status: flags a doubled entry with its count"
cp "$state/tab.single" "$state/tab"

echo "== test: arm again — dedup =="
assert_rc 3 "dedup: re-arm without --force" run_cadence "$state" arm --time 08:00

echo "== test: arm --force replaces =="
out=$(run_cadence "$state" arm --time 09:00 --force 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "force re-arm: rc=0"; else fail "force re-arm: expected rc=0 got rc=$rc; output: $out"; fi
assert_has "$out" "--force set" "force re-arm: acknowledges force"
if [ "$(grep -cF 'HIMMEL-LunaVitalsPull' "$state/tab" 2>/dev/null)" = "1" ]; then
  pass "force re-arm: exactly one cron entry (no duplicate)"
else
  fail "force re-arm: expected exactly one cron entry"
fi

echo "== test: disarm removes task AND registry entry =="
out=$(run_cadence "$state" disarm 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "disarm: rc=0"; else fail "disarm: expected rc=0 got rc=$rc; output: $out"; fi
assert_has "$out" "cadence disarmed" "disarm: confirms disarmed"
if grep -qF 'HIMMEL-LunaVitalsPull' "$state/tab" 2>/dev/null; then fail "disarm: cron entry still present"; else pass "disarm: cron entry removed"; fi
if registry_has_task "$state/observability.json"; then fail "disarm: still registered"; else pass "disarm: registry entry removed"; fi

echo "== test: status (not armed) =="
out=$(run_cadence "$state" status 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "status after disarm: rc=0"; else fail "status after disarm: expected rc=0 got rc=$rc"; fi
assert_has "$out" "not armed" "status after disarm: reports not armed"

echo "== test: disarm is idempotent (no-op) =="
out=$(run_cadence "$state" disarm 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "second disarm: rc=0"; else fail "second disarm: expected rc=0 got rc=$rc"; fi
assert_has "$out" "disarm is a no-op" "second disarm: reports no-op"

echo "== test: bad --time rejected (rc=1, cross-platform contract) =="
state2=$(new_scratch_posix); root2=$(make_root); mv "$root2" "$state2/root"
out=$(run_cadence "$state2" arm --time nonsense 2>&1); rc=$?
if [ "$rc" -eq 1 ]; then pass "bad --time (rc=1)"; else fail "bad --time — expected rc=1 got rc=$rc; output: $out"; fi
assert_has "$out" "--time must be HH:MM" "bad --time: rejected for the right reason"

echo "== test: the existing bare (no-args) pull path is untouched =="
# The connector-pull path itself is covered by pull-cadence.test.ts; this
# only proves the arm/status/disarm addition did not change ITS dispatch —
# a bogus PULL_CMD should still reach the pull logic (rc from PULL_CMD, not
# a usage error), confirming "arm|status|disarm|-h|--help" is the ONLY
# intercepted $1 shape.
out=$(PULL_CMD='exit 75' bash "$CADENCE" 2>&1); rc=$?
if [ "$rc" -eq 75 ]; then pass "bare invocation: still reaches the pull path (rc=75 via PULL_CMD)"; else fail "bare invocation: expected rc=75 got rc=$rc; output: $out"; fi

echo "== test: the real pull path finds bun under cron's minimal PATH (HIMMEL-11187) =="
make_stub_sender() {
  cat > "$1/send.sh" <<'STUB'
#!/bin/sh
echo "$HIMMEL_ALERT_KIND $1" >> "$(dirname "$0")/sent"
exit 0
STUB
  chmod +x "$1/send.sh"
}
cron_home=$(mktemp -d "${TMPDIR:-/tmp}/pull-cadence-test-home.XXXXXX") || exit 1
mkdir -p "$cron_home/.bun/bin" "$cron_home/art"
cat > "$cron_home/.bun/bin/bun" <<'STUB'
#!/bin/sh
case "$1" in */google-health.ts) ;; *) exit 1 ;; esac
[ "$2" = pull ] && [ "$3" = --from ] && [ "$4" = 2026-06-28 ] && [ "$5" = --to ] && [ "$6" = 2026-06-29 ] && [ "$7" = --out ] || exit 1
case "$8" in */gh-2026-06-29.json) ;; *) exit 1 ;; esac
echo "bun-called $*" > "$(dirname "$0")/../../bun-args"
exit 0
STUB
chmod +x "$cron_home/.bun/bin/bun"
make_stub_sender "$cron_home"
run_cron_pull() {
  env -i PATH="${2:-/usr/bin:/bin}" HOME="$1" \
    LUNA_VITALS_ARTIFACT_DIR="$1/art" HIMMEL_FLOW_RUNS_LEDGER="$1/flow-runs.jsonl" \
    CADENCE_ALERT_FILE="$1/alerts.log" CADENCE_ALERT_DEDUPE_DIR="$1/alert-sent" \
    CADENCE_ALERT_SEND_CMD="$1/send.sh" CADENCE_ALERT_SEND_FAILED_MARK="$1/send-failed" \
    FROM=2026-06-28 TO=2026-06-29 bash "$CADENCE"
}
out=$(run_cron_pull "$cron_home" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "minimal PATH: pull exits 0"; else fail "minimal PATH: expected rc=0 got rc=$rc; output: $out"; fi
if grep -qF "bun-called" "$cron_home/bun-args" 2>/dev/null; then pass "minimal PATH: ~/.bun/bin/bun was called"; else fail "minimal PATH: bun was not called"; fi
if [ -e "$cron_home/alerts.log" ]; then fail "minimal PATH: a clean run wrote an alert"; else pass "minimal PATH: a clean run wrote no alert"; fi

echo "== test: exit 127 (bun missing) writes ONE alert line naming bun =="
empty_home=$(mktemp -d "${TMPDIR:-/tmp}/pull-cadence-test-nobun.XXXXXX") || exit 1
mkdir -p "$empty_home/art"
make_stub_sender "$empty_home"
nobun_bin="$empty_home/bin"
mkdir -p "$nobun_bin"
for tool in bash sh env date dirname mkdir cat rm sed grep head tr cut sha256sum shasum cksum hostname uname mktemp basename tail chmod; do
  tool_path=$(command -v "$tool" 2>/dev/null) && [ -x "$tool_path" ] && ln -s "$tool_path" "$nobun_bin/$tool"
done
out=$(run_cron_pull "$empty_home" "$nobun_bin" 2>&1); rc=$?
if [ "$rc" -eq 127 ]; then pass "no bun: pull exits 127"; else fail "no bun: expected rc=127 got rc=$rc; output: $out"; fi
n=$(grep -c . "$empty_home/alerts.log" 2>/dev/null || true)
if [ "${n:-0}" = "1" ]; then pass "no bun: exactly one alert line"; else fail "no bun: expected one alert line, got ${n:-0}"; fi
assert_has "$(cat "$empty_home/alerts.log" 2>/dev/null)" "luna-vitals-pull rc-127" "no bun: alert line names the job and rc-127"
assert_has "$(cat "$empty_home/sent" 2>/dev/null)" "bun: command not found" "no bun: the message names the missing command"
rm -rf "$cron_home" "$empty_home"

echo
if [ "$fails" -eq 0 ]; then echo "SUMMARY: all tests passed"; else echo "SUMMARY: $fails failed"; exit 1; fi
