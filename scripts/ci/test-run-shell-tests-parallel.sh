#!/usr/bin/env bash
# scripts/ci/test-run-shell-tests-parallel.sh — run-shell-tests.sh runs up to
# SUITE_JOBS suites at once, and a suite on the parallel deny-list alone.
#
#   P1. Two isolated suites overlap in time under SUITE_JOBS=2.
#   P2. A deny-listed suite starts only after every running suite finished,
#       and nothing starts beside it.
#   P3. A real shard's duration profile (copied from a CI log, scaled down)
#       runs four suites at once under SUITE_JOBS=4.
#   P4. With no SUITE_JOBS outside CI the runner stays serial.
#   P5. A failing suite's rc, [FAIL] line and log tail survive a parallel run.
#   P6. Under SUITE_STOP_ON_FAIL, a failure collected while draining the lanes
#       for a deny-listed suite stops that suite from running.
#   P7. A run budget that expires while the runner waits for a free lane keeps
#       the waiting suite from starting.
#   P8. The deny-list matches a suite however the scan root is spelled (a
#       symlink to the suites' directory).
#   P9. A runner terminated mid-run leaves no parallel suite running.
#  P10. A lane that dies without a result stops the run with rc 2.
#  P11. A hard-listed suite that writes a live-state sentinel in one lane
#       fails with [LIVE-STATE]; the clean suite in the other lane passes.
#  P12. An unreadable deny-list runs a parallel run one suite at a time.
#  P13. With no SUITE_JOBS, GitHub Actions uses the CPU count (2 or 4)
#       capped at 4, and a runner inside a suite (HIMMEL_TEST_FIXTURE=1)
#       stays serial.
#
# Each fixture suite records how many fixture suites were running when it
# started, so overlap is read from the suites themselves, not from timing.
#
# Usage: bash scripts/ci/test-run-shell-tests-parallel.sh
#
# Exit codes: 0 — all cases passed; 1 — at least one failed.
set -uo pipefail

# shellcheck source=run-shell-tests-fixture.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/run-shell-tests-fixture.sh"

# mk_suite <dir> <name> <tenths of a second> [rc] — a fixture suite that marks
# itself running, appends "<name> <suites running at its start>" to peak.log,
# sleeps, then unmarks itself.
mk_suite() {
  local _d="$1" _n="$2" _t="$3" _rc="${4:-0}"
  cat > "$_d/scripts/$_n" <<SHEOF
#!/usr/bin/env bash
: > "$_d/run.$_n"
_c=0; for _f in "$_d"/run.*; do [ -e "\$_f" ] && _c=\$((_c + 1)); done
printf '%s %s\n' "$_n" "\$_c" >> "$_d/peak.log"
sleep $((_t / 10)).$((_t % 10))
rm -f "$_d/run.$_n"
echo "fixture $_n done"
exit $_rc
SHEOF
  chmod +x "$_d/scripts/$_n"
}

# peak_of <dir> <name> — the running count <name> saw at its start.
peak_of() { sed -n "s/^$2 //p" "$1/peak.log" 2>/dev/null; }

# pair_peaks <dir> <name> <name> — "<lower> <higher>" running counts the two
# saw, so a check does not depend on which of two launched suites ran first.
pair_peaks() { printf '%s\n%s\n' "$(peak_of "$1" "$2")" "$(peak_of "$1" "$3")" | sort -n | paste -sd' ' -; }

# max_peak <dir> — the highest running count any suite saw.
max_peak() { sort -n -k2 "$1/peak.log" 2>/dev/null | tail -n 1 | cut -d' ' -f2; }

mk_sandbox() {
  local _d
  _d=$(mktemp -d "$SUITE_LOCK_SANDBOX/rst-par.XXXXXX") || return 1
  mkdir -p "$_d/scripts" || { rm -rf "$_d"; return 1; }
  : > "$_d/peak.log"
  printf '%s' "$_d"
}

echo "== P1: two isolated suites overlap under SUITE_JOBS=2 =="
if sb=$(mk_sandbox); then
  mk_suite "$sb" test-a.sh 20
  mk_suite "$sb" test-b.sh 20
  out=$(SUITE_JOBS=2 env -u SUITE_TIER_MODE bash "$RUNNER" "$sb/scripts" 2>&1); rc=$?
  if [ "$rc" -eq 0 ] && [ "$(max_peak "$sb")" = 2 ]; then
    pass "P1: test-a.sh and test-b.sh ran at the same time"
  else
    fail "P1: expected rc 0 and a running count of 2, got rc=$rc peak.log=$(tr '\n' ' ' < "$sb/peak.log"); out: $out"
  fi
  if grepq "$out" -F '[PASS] '"$sb"'/scripts/test-a.sh (' && grepq "$out" -F '[PASS] '"$sb"'/scripts/test-b.sh ('; then
    pass "P1: both suites keep their [PASS] line"
  else
    fail "P1: a [PASS] line is missing; out: $out"
  fi
  rm -rf "$sb"
else
  fail "P1: mktemp failed"
fi

echo "== P2: a deny-listed suite runs alone =="
if sb=$(mk_sandbox); then
  mk_suite "$sb" test-a.sh 15
  mk_suite "$sb" test-b.sh 15
  mk_suite "$sb" test-c-alone.sh 10
  mk_suite "$sb" test-d.sh 15
  mk_suite "$sb" test-e.sh 15
  printf '# fixture deny-list\n*/scripts/test-c-alone.sh  fixture: must run alone\n' > "$sb/deny.txt"
  out=$(SUITE_JOBS=3 SUITE_PARALLEL_DENY="$sb/deny.txt" env -u SUITE_TIER_MODE bash "$RUNNER" "$sb/scripts" 2>&1); rc=$?
  pc=$(peak_of "$sb" test-c-alone.sh); pde=$(pair_peaks "$sb" test-d.sh test-e.sh)
  if [ "$rc" -eq 0 ] && [ "$pc" = 1 ] && [ "$pde" = "1 2" ]; then
    pass "P2: test-c-alone.sh started with nothing else running, and the next suite only after it ended"
  else
    fail "P2: expected rc 0, running count 1 for test-c-alone.sh and 1 2 for test-d.sh/test-e.sh, got rc=$rc peak.log=$(tr '\n' ' ' < "$sb/peak.log"); out: $out"
  fi
  if [ "$(pair_peaks "$sb" test-a.sh test-b.sh)" = "1 2" ] && [ "$pde" = "1 2" ]; then
    pass "P2: the suites around it still ran in parallel"
  else
    fail "P2: expected test-a.sh/test-b.sh and test-d.sh/test-e.sh to overlap; peak.log=$(tr '\n' ' ' < "$sb/peak.log")"
  fi
  rm -rf "$sb"
else
  fail "P2: mktemp failed"
fi

echo "== P3: a real shard's duration profile runs four suites at once =="
# Copied verbatim from the job log of run 40074059569, job 120813532475
# (shell-unit-shard (ubuntu-latest, 4), main 6fa549bc5, 2026-10-24): fifteen
# consecutive suites of that shard. Each fixture sleeps its CI seconds / 10.
P3_CI_LINES='[PASS] scripts/hooks/test-block-bare-qmd-query.sh (92s)
[PASS] scripts/hooks/test-block-destructive-commands-d.sh (63s)
[PASS] scripts/hooks/test-block-docker-privesc.sh (7s)
[PASS] scripts/hooks/test-block-graphify-egress.sh (8s)
[PASS] scripts/hooks/test-block-mcp-when-plugin-exists.sh (2s)
[PASS] scripts/hooks/test-block-write-into-main-checkout-ast.sh (4s)
[PASS] scripts/hooks/test-block-write-into-main-checkout-matrix1.sh (117s)
[PASS] scripts/hooks/test-check-cr-before-push.sh (9s)
[PASS] scripts/hooks/test-check-gh-json-fields.sh (0s)
[PASS] scripts/hooks/test-check-no-headless-gemini.sh (0s)
[PASS] scripts/hooks/test-check-pr-lane-isolation.sh (0s)
[PASS] scripts/hooks/test-check-security-reviewed.sh (4s)
[PASS] scripts/hooks/test-codex-run-hook.sh (0s)
[PASS] scripts/hooks/test-gitattributes-no-driver.sh (0s)
[PASS] scripts/hooks/test-guard-leg-context-handoff.sh (15s)'
if sb=$(mk_sandbox); then
  serial10=0
  while IFS= read -r l; do
    n=${l#\[PASS\] scripts/hooks/}; n=${n%% *}
    s=${l##*(}; s=${s%s)}
    mk_suite "$sb" "$n" "$s"
    serial10=$((serial10 + s))
  done <<< "$P3_CI_LINES"
  out=$(SUITE_JOBS=4 env -u SUITE_TIER_MODE bash "$RUNNER" "$sb/scripts" 2>&1); rc=$?
  if [ "$rc" -eq 0 ] && [ "$(max_peak "$sb")" = 4 ]; then
    pass "P3: four of the shard's suites ran at once ($((serial10 / 10))s of serial suite time)"
  else
    fail "P3: expected rc 0 and a running count of 4, got rc=$rc peak.log=$(tr '\n' ' ' < "$sb/peak.log"); out: $out"
  fi
  rm -rf "$sb"
else
  fail "P3: mktemp failed"
fi

echo "== P4: no SUITE_JOBS outside CI keeps the runner serial =="
if sb=$(mk_sandbox); then
  mk_suite "$sb" test-a.sh 10
  mk_suite "$sb" test-b.sh 10
  # A getconf reporting 4 CPUs, so only the GITHUB_ACTIONS check keeps this serial.
  mkdir -p "$sb/bin"
  printf '#!/usr/bin/env bash\necho 4\n' > "$sb/bin/getconf"
  chmod +x "$sb/bin/getconf"
  out=$(PATH="$sb/bin:$PATH" env -u SUITE_JOBS -u GITHUB_ACTIONS -u HIMMEL_TEST_FIXTURE -u SUITE_TIER_MODE bash "$RUNNER" "$sb/scripts" 2>&1); rc=$?
  if [ "$rc" -eq 0 ] && [ "$(max_peak "$sb")" = 1 ]; then
    pass "P4: the default ran one suite at a time"
  else
    fail "P4: expected rc 0 and a running count of 1, got rc=$rc peak.log=$(tr '\n' ' ' < "$sb/peak.log"); out: $out"
  fi
  rm -rf "$sb"
else
  fail "P4: mktemp failed"
fi

echo "== P5: a failing suite keeps its rc, [FAIL] line and log tail in a parallel run =="
if sb=$(mk_sandbox); then
  mk_suite "$sb" test-a.sh 10
  mk_suite "$sb" test-b-red.sh 10 3
  out=$(SUITE_JOBS=2 env -u SUITE_TIER_MODE bash "$RUNNER" "$sb/scripts" 2>&1); rc=$?
  if [ "$rc" -eq 1 ] && grepq "$out" -E '\[FAIL\] .*/test-b-red\.sh \(rc=3, [0-9]+s\)' \
     && grepq "$out" -F '    fixture test-b-red.sh done' && grepq "$out" -E '\[RETRY\] .*/test-b-red\.sh failed \(rc=3\)' \
     && [ "$(max_peak "$sb")" = 2 ]; then
    pass "P5: rc 1, [RETRY] and [FAIL] (rc=3) with the suite's own output, run in parallel"
  else
    fail "P5: expected rc 1, a retried [FAIL] rc=3 with the log tail and a running count of 2, got rc=$rc peak.log=$(tr '\n' ' ' < "$sb/peak.log"); out: $out"
  fi
  rm -rf "$sb"
else
  fail "P5: mktemp failed"
fi

echo "== P6: a failure found while draining stops the deny-listed suite =="
if sb=$(mk_sandbox); then
  mk_suite "$sb" test-a-red.sh 5 3
  mk_suite "$sb" test-b.sh 20
  mk_suite "$sb" test-c-alone.sh 5
  printf '*/scripts/test-c-alone.sh  fixture: must run alone\n' > "$sb/deny.txt"
  out=$(SUITE_JOBS=2 SUITE_STOP_ON_FAIL=1 SUITE_PARALLEL_DENY="$sb/deny.txt" env -u SUITE_TIER_MODE bash "$RUNNER" "$sb/scripts" 2>&1); rc=$?
  if [ "$rc" -ne 0 ] && [ -z "$(peak_of "$sb" test-c-alone.sh)" ] \
     && printf '%s\n' "$out" | sed -n '/^STOPPED:/,$p' | grep -qF "$sb/scripts/test-c-alone.sh"; then
    pass "P6: test-c-alone.sh never started and is named under STOPPED"
  else
    fail "P6: expected a non-zero rc and test-c-alone.sh unrun under STOPPED, got rc=$rc peak.log=$(tr '\n' ' ' < "$sb/peak.log"); out: $out"
  fi
  rm -rf "$sb"
else
  fail "P6: mktemp failed"
fi

echo "== P7: a budget that expires while waiting for a lane keeps the suite from starting =="
if sb=$(mk_sandbox); then
  mk_suite "$sb" test-a.sh 40
  mk_suite "$sb" test-b.sh 40
  mk_suite "$sb" test-c.sh 5
  out=$(SUITE_JOBS=2 SUITE_RUN_BUDGET=2 env -u SUITE_TIER_MODE bash "$RUNNER" "$sb/scripts" 2>&1); rc=$?
  if [ "$rc" -ne 0 ] && [ -z "$(peak_of "$sb" test-c.sh)" ] \
     && printf '%s\n' "$out" | sed -n '/run budget of 2s expired/,$p' | grep -qF "$sb/scripts/test-c.sh"; then
    pass "P7: test-c.sh never started and is named as unrun by the budget"
  else
    fail "P7: expected a non-zero rc and test-c.sh unrun by the budget, got rc=$rc peak.log=$(tr '\n' ' ' < "$sb/peak.log"); out: $out"
  fi
  rm -rf "$sb"
else
  fail "P7: mktemp failed"
fi

echo "== P8: a deny-listed suite runs alone when the scan root is a symlink =="
if sb=$(mk_sandbox); then
  mk_suite "$sb" test-a.sh 15
  mk_suite "$sb" test-c-alone.sh 10
  mk_suite "$sb" test-d.sh 15
  printf '*/scripts/test-c-alone.sh  fixture: must run alone\n' > "$sb/deny.txt"
  ln -s "$sb/scripts" "$sb/link"
  out=$(SUITE_JOBS=3 SUITE_PARALLEL_DENY="$sb/deny.txt" env -u SUITE_TIER_MODE bash "$RUNNER" "$sb/link" 2>&1); rc=$?
  if [ "$rc" -eq 0 ] && [ "$(peak_of "$sb" test-c-alone.sh)" = 1 ] && [ "$(peak_of "$sb" test-d.sh)" = 1 ]; then
    pass "P8: the deny-list matched link/test-c-alone.sh through its resolved path"
  else
    fail "P8: expected rc 0 and running counts 1/1 for test-c-alone.sh/test-d.sh, got rc=$rc peak.log=$(tr '\n' ' ' < "$sb/peak.log"); out: $out"
  fi
  rm -rf "$sb"
else
  fail "P8: mktemp failed"
fi

echo "== P9: a runner terminated mid-run leaves no parallel suite running =="
if sb=$(mk_sandbox); then
  printf '#!/usr/bin/env bash\necho $$ > "%s/long.pid"\nexec sleep 30\n' "$sb" > "$sb/scripts/test-long.sh"
  chmod +x "$sb/scripts/test-long.sh"
  mk_suite "$sb" test-b.sh 300
  SUITE_JOBS=2 env -u SUITE_TIER_MODE bash "$RUNNER" "$sb/scripts" > "$sb/out" 2>&1 &
  rpid=$!
  for _w in $(seq 1 100); do [ -s "$sb/long.pid" ] && break; sleep 0.1; done
  lpid=$(cat "$sb/long.pid" 2>/dev/null)
  kill -TERM "$rpid" 2>/dev/null
  wait "$rpid" 2>/dev/null
  sleep 1
  if [ -n "$lpid" ] && ! kill -0 "$lpid" 2>/dev/null; then
    pass "P9: the suite a lane was running ended with the runner"
  else
    fail "P9: expected the lane's suite (pid ${lpid:-none}) to end with the runner; out: $(cat "$sb/out")"
    [ -z "$lpid" ] || kill "$lpid" 2>/dev/null
  fi
  rm -rf "$sb"
else
  fail "P9: mktemp failed"
fi

echo "== P10: a lane that dies without a result stops the run with rc 2 =="
if sb=$(mk_sandbox); then
  # The suite's parent is its attempt subshell; the grandparent is the lane.
  cat > "$sb/scripts/test-a-kill-lane.sh" <<'SHEOF'
#!/usr/bin/env bash
gp=$(ps -o ppid= -p "$PPID" 2>/dev/null); gp=${gp//[[:space:]]/}
case "$(ps -o args= -p "$gp" 2>/dev/null)" in *run-shell-tests.sh*) kill -KILL "$gp" ;; esac
exit 0
SHEOF
  chmod +x "$sb/scripts/test-a-kill-lane.sh"
  mk_suite "$sb" test-b.sh 10
  mk_suite "$sb" test-c.sh 10
  mk_suite "$sb" test-d.sh 10
  out=$(SUITE_JOBS=2 SUITE_TIMEOUT=5 env -u SUITE_TIER_MODE bash "$RUNNER" "$sb/scripts" 2>&1); rc=$?
  if [ "$rc" -eq 2 ] && grepq "$out" -F 'a parallel suite worker ended without a result — refusing to run more suites' \
     && [ -z "$(peak_of "$sb" test-d.sh)" ]; then
    pass "P10: rc 2, the refusal named, and no later suite started"
  else
    fail "P10: expected rc 2, the without-a-result refusal and test-d.sh unrun, got rc=$rc peak.log=$(tr '\n' ' ' < "$sb/peak.log"); out: $out"
  fi
  rm -rf "$sb"
else
  fail "P10: mktemp failed"
fi

echo "== P11: a live-state write in one lane fails that suite only =="
if sb=$(mk_sandbox); then
  mk_suite "$sb" test-a-clean.sh 10
  # The bullet test-run-shell-tests-live-state.sh replays into the console doc.
  # The writer stays running past the clean suite's end, so a sentinel shared
  # between the lanes would still be dirty when the clean suite is checked.
  cat > "$sb/scripts/test-b-writer.sh" <<SHEOF
#!/usr/bin/env bash
: > "$sb/run.test-b-writer.sh"
_c=0; for _f in "$sb"/run.*; do [ -e "\$_f" ] && _c=\$((_c + 1)); done
printf '%s %s\n' test-b-writer.sh "\$_c" >> "$sb/peak.log"
printf -- '- 22:03 PARTIAL HIMMEL-374: next slice not dispatched\n' >> "\$HIMMEL_CONSOLE_DOC"
sleep 2.5
rm -f "$sb/run.test-b-writer.sh"
exit 0
SHEOF
  chmod +x "$sb/scripts/test-b-writer.sh"
  out=$(SUITE_JOBS=2 SUITE_LIVE_HARD='*/test-b-writer.sh' env -u SUITE_TIER_MODE bash "$RUNNER" "$sb/scripts" 2>&1); rc=$?
  if [ "$rc" -eq 1 ] && [ "$(pair_peaks "$sb" test-a-clean.sh test-b-writer.sh)" = "1 2" ] \
     && grepq "$out" -E '^\[LIVE-STATE\] .*/test-b-writer\.sh — .*HIMMEL_CONSOLE_DOC' \
     && grepq "$out" -E '^\[FAIL\] .*/test-b-writer\.sh ' \
     && grepq "$out" -F '[PASS] '"$sb"'/scripts/test-a-clean.sh (' \
     && ! grepq "$out" -E '^\[LIVE-STATE\] .*/test-a-clean\.sh'; then
    pass "P11: test-b-writer.sh failed with [LIVE-STATE] while test-a-clean.sh ran beside it and passed"
  else
    fail "P11: expected rc 1, an overlap, [LIVE-STATE] and [FAIL] for test-b-writer.sh only, got rc=$rc peak.log=$(tr '\n' ' ' < "$sb/peak.log"); out: $out"
  fi
  rm -rf "$sb"
else
  fail "P11: mktemp failed"
fi

echo "== P12: an unreadable deny-list runs one suite at a time =="
if sb=$(mk_sandbox); then
  mk_suite "$sb" test-a.sh 10
  mk_suite "$sb" test-b.sh 10
  out=$(SUITE_JOBS=2 SUITE_PARALLEL_DENY="$sb/no-such-deny.txt" env -u SUITE_TIER_MODE bash "$RUNNER" "$sb/scripts" 2>&1); rc=$?
  if [ "$rc" -eq 0 ] && [ "$(max_peak "$sb")" = 1 ] \
     && grepq "$out" -F "WARN: parallel deny-list $sb/no-such-deny.txt is unreadable — running suites one at a time"; then
    pass "P12: the WARN named the list and the suites ran one at a time"
  else
    fail "P12: expected rc 0, the unreadable WARN and a running count of 1, got rc=$rc peak.log=$(tr '\n' ' ' < "$sb/peak.log"); out: $out"
  fi
  rm -rf "$sb"
else
  fail "P12: mktemp failed"
fi

echo "== P13: the default lane count on GitHub Actions =="
# p13_run <cpus> <fixture flag or -> — 5 suites under GITHUB_ACTIONS=true with
# no SUITE_JOBS and a getconf that reports <cpus>; '-' leaves
# HIMMEL_TEST_FIXTURE unset.
p13_run() {
  mkdir -p "$sb/bin"
  printf '#!/usr/bin/env bash\necho %s\n' "$1" > "$sb/bin/getconf"
  chmod +x "$sb/bin/getconf"
  : > "$sb/peak.log"
  if [ "$2" = - ]; then
    out=$(PATH="$sb/bin:$PATH" GITHUB_ACTIONS=true env -u SUITE_JOBS -u HIMMEL_TEST_FIXTURE -u GITHUB_STEP_SUMMARY -u SUITE_TIER_MODE bash "$RUNNER" "$sb/scripts" 2>&1); rc=$?
  else
    out=$(PATH="$sb/bin:$PATH" GITHUB_ACTIONS=true HIMMEL_TEST_FIXTURE="$2" env -u SUITE_JOBS -u GITHUB_STEP_SUMMARY -u SUITE_TIER_MODE bash "$RUNNER" "$sb/scripts" 2>&1); rc=$?
  fi
}
if sb=$(mk_sandbox); then
  for _n in a b c d e; do mk_suite "$sb" "test-$_n.sh" 15; done
  p13_run 4 -
  if [ "$rc" -eq 0 ] && [ "$(max_peak "$sb")" = 4 ] && grepq "$out" -F 'parallel: up to 4 suites at once'; then
    pass "P13: 4 CPUs ran 4 suites at once"
  else
    fail "P13: 4 CPUs: expected rc 0, 4 lanes and a running count of 4, got rc=$rc peak.log=$(tr '\n' ' ' < "$sb/peak.log"); out: $out"
  fi
  p13_run 2 -
  if [ "$rc" -eq 0 ] && [ "$(max_peak "$sb")" = 2 ] && grepq "$out" -F 'parallel: up to 2 suites at once'; then
    pass "P13: 2 CPUs ran 2 suites at once"
  else
    fail "P13: 2 CPUs: expected rc 0, 2 lanes and a running count of 2, got rc=$rc peak.log=$(tr '\n' ' ' < "$sb/peak.log"); out: $out"
  fi
  p13_run 16 -
  if [ "$rc" -eq 0 ] && [ "$(max_peak "$sb")" = 4 ] && grepq "$out" -F 'parallel: up to 4 suites at once'; then
    pass "P13: 16 CPUs are capped at 4 lanes"
  else
    fail "P13: 16 CPUs: expected rc 0, 4 lanes and a running count of 4, got rc=$rc peak.log=$(tr '\n' ' ' < "$sb/peak.log"); out: $out"
  fi
  p13_run 16 1
  if [ "$rc" -eq 0 ] && [ "$(max_peak "$sb")" = 1 ] && ! grepq "$out" -F 'parallel: up to'; then
    pass "P13: HIMMEL_TEST_FIXTURE=1 keeps a runner inside a suite serial"
  else
    fail "P13: HIMMEL_TEST_FIXTURE=1: expected rc 0, no parallel line and a running count of 1, got rc=$rc peak.log=$(tr '\n' ' ' < "$sb/peak.log"); out: $out"
  fi
  rm -rf "$sb"
else
  fail "P13: mktemp failed"
fi

rst_tally
