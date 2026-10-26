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
#  P14. A deny-list whose last line has no final newline still keeps that
#       entry's suite alone.
#  P15. A TERM that reaches a lane before its first suite signals no
#       process group id the lane inherited.
#  P16. A lane result file without its completion marker reads as no result
#       (rc 2), however much of it was written.
#  P17. A lane worker killed with SIGKILL leaves no running suite or
#       watchdog group and no per-suite temp root or attempt log.
#  P18. The bash 3.2 polling fallback (SUITE_LANE_WAIT=poll) still reaps
#       finished lanes and drains for a deny-listed suite.
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
# itself running, appends "<name> <suites running at its start>" to peak.log
# (and its name to beside-alone.log when a *-alone.sh suite is running), sleeps,
# then unmarks itself.
mk_suite() {
  local _d="$1" _n="$2" _t="$3" _rc="${4:-0}"
  cat > "$_d/scripts/$_n" <<SHEOF
#!/usr/bin/env bash
: > "$_d/run.$_n"
_c=0; for _f in "$_d"/run.*; do [ -e "\$_f" ] && _c=\$((_c + 1)); done
for _f in "$_d"/run.*-alone.sh; do [ -e "\$_f" ] && [ "\$_f" != "$_d/run.$_n" ] && printf '%s\n' "$_n" >> "$_d/beside-alone.log"; done
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

# overlapped <dir> <name> <name> — the two ran at once: one saw the other, or
# both marked themselves running before either counted.
overlapped() { case "$(pair_peaks "$@")" in "1 2"|"2 2") return 0 ;; esac; return 1; }

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
  pc=$(peak_of "$sb" test-c-alone.sh)
  if [ "$rc" -eq 0 ] && [ "$pc" = 1 ] && [ ! -s "$sb/beside-alone.log" ]; then
    pass "P2: test-c-alone.sh started with nothing else running, and the next suite only after it ended"
  else
    fail "P2: expected rc 0, running count 1 for test-c-alone.sh and no suite started beside it, got rc=$rc peak.log=$(tr '\n' ' ' < "$sb/peak.log") beside-alone.log=$(tr '\n' ' ' < "$sb/beside-alone.log" 2>/dev/null); out: $out"
  fi
  if overlapped "$sb" test-a.sh test-b.sh && overlapped "$sb" test-d.sh test-e.sh; then
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
[PASS] scripts/hooks/test-guard-worker-context-handoff.sh (15s)'
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
  out=$(SUITE_JOBS=2 SUITE_RUN_BUDGET=2 SUITE_ROTATE_STATE="$sb/rotate.cursor" env -u SUITE_TIER_MODE bash "$RUNNER" "$sb/scripts" 2>&1); rc=$?
  if [ "$rc" -ne 0 ] && [ -z "$(peak_of "$sb" test-c.sh)" ] && [ -s "$sb/rotate.cursor" ] \
     && printf '%s\n' "$out" | sed -n '/run budget of 2s expired/,$p' | grep -qF "$sb/scripts/test-c.sh"; then
    pass "P7: test-c.sh never started and is named as unrun by the budget, and the cursor went to P7's own path"
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
  printf '#!/usr/bin/env bash\necho $$ > "%s/b.pid"\nexec sleep 30\n' "$sb" > "$sb/scripts/test-b.sh"
  chmod +x "$sb/scripts/test-b.sh"
  SUITE_JOBS=2 env -u SUITE_TIER_MODE bash "$RUNNER" "$sb/scripts" > "$sb/out" 2>&1 &
  rpid=$!
  for _w in $(seq 1 100); do [ -s "$sb/long.pid" ] && [ -s "$sb/b.pid" ] && break; sleep 0.1; done
  lpid=$(cat "$sb/long.pid" 2>/dev/null); bpid=$(cat "$sb/b.pid" 2>/dev/null)
  kill -TERM "$rpid" 2>/dev/null
  wait "$rpid" 2>/dev/null
  sleep 1
  if [ -n "$lpid" ] && [ -n "$bpid" ] && ! kill -0 "$lpid" 2>/dev/null && ! kill -0 "$bpid" 2>/dev/null; then
    pass "P9: the suites both lanes were running ended with the runner"
  else
    fail "P9: expected both lanes' suites (pids ${bpid:-none} ${lpid:-none}) to end with the runner; out: $(cat "$sb/out")"
    [ -z "$lpid" ] || kill "$lpid" 2>/dev/null
    [ -z "$bpid" ] || kill "$bpid" 2>/dev/null
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
  # The bullet test-run-shell-tests-live-state.sh replays into the chief doc.
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
  if [ "$rc" -eq 1 ] && overlapped "$sb" test-a-clean.sh test-b-writer.sh \
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

echo "== P14: a deny-list whose last line has no final newline still keeps its suite alone =="
if sb=$(mk_sandbox); then
  # The committed deny-list with its final newline removed.
  printf '%s' "$(cat "$RST_FIXTURE_DIR/parallel-deny.txt")" > "$sb/deny.txt"
  last=$(tail -n 1 "$sb/deny.txt"); glob=${last%%[[:space:]]*}; rel=${glob#\*/}
  case "$glob" in
    \*/scripts/*)
      mkdir -p "$sb/$(dirname "$rel")"
      sed "s|@SB@|$sb|g" <<'SHEOF' > "$sb/$rel"
#!/usr/bin/env bash
: > "@SB@/run.last-entry-alone.sh"
_c=0; for _f in "@SB@"/run.*; do [ -e "$_f" ] && _c=$((_c + 1)); done
printf '%s %s\n' last-entry-alone.sh "$_c" >> "@SB@/peak.log"
sleep 1.5
rm -f "@SB@/run.last-entry-alone.sh"
exit 0
SHEOF
      chmod +x "$sb/$rel"
      mk_suite "$sb" test-a.sh 15
      mk_suite "$sb" test-b.sh 15
      mk_suite "$sb" test-c.sh 15
      out=$(SUITE_JOBS=3 SUITE_PARALLEL_DENY="$sb/deny.txt" env -u SUITE_TIER_MODE bash "$RUNNER" "$sb/scripts" 2>&1); rc=$?
      if [ "$rc" -eq 0 ] && [ "$(peak_of "$sb" last-entry-alone.sh)" = 1 ] && [ ! -s "$sb/beside-alone.log" ]; then
        pass "P14: the suite on the list's unterminated last line ($glob) ran with nothing beside it"
      else
        fail "P14: expected rc 0 and nothing started beside $glob, got rc=$rc peak.log=$(tr '\n' ' ' < "$sb/peak.log") beside-alone.log=$(tr '\n' ' ' < "$sb/beside-alone.log" 2>/dev/null); out: $out"
      fi ;;
    *) fail "P14: the deny-list's last line is not a */scripts/ entry ('$last'); point this row at an entry it can run" ;;
  esac
  rm -rf "$sb"
else
  fail "P14: mktemp failed"
fi

echo "== P15: a TERM before a lane's first suite signals no inherited group id =="
if sb=$(mk_sandbox); then
  mk_suite "$sb" test-a.sh 10
  mk_suite "$sb" test-b.sh 10
  # A group the runner must leave alone: its id arrives in the lane's environment.
  set -m; sleep 60 & sentinel=$!; set +m
  # A mktemp that sends the first lane asking for one a TERM, then makes the file:
  # the lane's first command is its attempt log, so the TERM lands before any suite.
  mkdir -p "$sb/bin"
  cat > "$sb/bin/mktemp" <<'SHEOF'
#!/usr/bin/env bash
args=("$@")
# Only the lane's own attempt-log call: no arguments, and a lane's stderr is a
# file where the main shell's is a pipe.
if [ ! -e "$P15_FIRED" ] && [ "${#args[@]}" -eq 0 ] && [ -f /dev/stderr ]; then
  p=$PPID; chain=""
  while [ -n "$p" ] && [ "$p" -gt 1 ]; do
    case "$(ps -o args= -p "$p" 2>/dev/null)" in
      *run-shell-tests.sh*) chain="$chain $p" ;;
      *) break ;;
    esac
    p=$(ps -o ppid= -p "$p" 2>/dev/null); p=${p//[[:space:]]/}
  done
  # chain: the runner's processes, nearest first; the last is the main shell, the one before it a lane.
  set -- $chain
  if [ "$#" -ge 2 ]; then
    : > "$P15_FIRED"
    eval "lane=\${$(($# - 1))}"
    kill -TERM "$lane"
  fi
fi
PATH=${PATH#"$P15_STUB_DIR":}
exec mktemp "${args[@]}"
SHEOF
  chmod +x "$sb/bin/mktemp"
  out=$(P15_FIRED="$sb/fired" P15_STUB_DIR="$sb/bin" PATH="$sb/bin:$PATH" suite_pid="$sentinel" watch_pid="$sentinel" SUITE_JOBS=2 env -u SUITE_TIER_MODE bash "$RUNNER" "$sb/scripts" 2>&1); rc=$?
  if [ -e "$sb/fired" ] && [ "$rc" -eq 2 ] && kill -0 "$sentinel" 2>/dev/null; then
    pass "P15: the TERMed lane left the group id it inherited alone"
  else
    fail "P15: expected the lane TERMed (fired=$([ -e "$sb/fired" ] && echo yes || echo no)), rc 2 and the inherited group (pid $sentinel) still running, got rc=$rc alive=$(kill -0 "$sentinel" 2>/dev/null && echo yes || echo no); out: $out"
  fi
  kill "$sentinel" 2>/dev/null
  rm -rf "$sb"
else
  fail "P15: mktemp failed"
fi

echo "== P16: a lane result file without its completion marker reads as no result =="
if sb=$(mk_sandbox); then
  # _lane_reap on its own, with the account and stop steps stubbed: a lane killed
  # between two writes leaves the first fields of its result file and no more.
  cat > "$sb/reap-harness.sh" <<'SHEOF'
#!/usr/bin/env bash
lane_out=() lane_pid=()
suite=s relpath=r suite_key=k mf_rel=m
_suite_account() { echo ACCOUNTED; }
_lanes_stop() { echo STOPPED; }
eval "$(sed -n '/^_lane_reap() {/,/^}/p' "$1")"
d=$(mktemp -d "$2/lane.XXXXXX")
printf 'rc=0\ncapped=0\n' > "$d/res"
: > "$d/out"; : > "$d/err"
lane_out[0]=$d
sleep 0 & lane_pid[0]=$!
_lane_reap 0
echo "REAPED-AS-RESULT"
SHEOF
  out=$(bash "$sb/reap-harness.sh" "$RUNNER" "$sb" 2>&1); rc=$?
  if [ "$rc" -eq 2 ] && grepq "$out" -F 'a parallel suite worker ended without a result — refusing to run more suites' \
     && grepq "$out" -F STOPPED && ! grepq "$out" -F ACCOUNTED; then
    pass "P16: a partial result file stopped the run with rc 2 and was not accounted"
  else
    fail "P16: expected rc 2, the without-a-result refusal, STOPPED and no ACCOUNTED for a result file with no completion marker, got rc=$rc; out: $out"
  fi
  rm -rf "$sb"
else
  fail "P16: mktemp failed"
fi

echo "== P17: a SIGKILLed lane worker leaves no suite, watchdog or temp path behind =="
if sb=$(mk_sandbox); then
  mkdir -p "$sb/tmp"
  # The suite leaves a child in its own group, records its temp root, then kills
  # the lane (its grandparent) the way P10 does.
  sed "s|@SB@|$sb|g" <<'SHEOF' > "$sb/scripts/test-a-orphan.sh"
#!/usr/bin/env bash
printf '%s\n' "$TMPDIR" > "@SB@/suite-tmp.path"
sleep 4301 &
printf '%s\n' "$!" > "@SB@/orphan.pid"
sleep 1
gp=$(ps -o ppid= -p "$PPID" 2>/dev/null); gp=${gp//[[:space:]]/}
case "$(ps -o args= -p "$gp" 2>/dev/null)" in *run-shell-tests.sh*) kill -KILL "$gp" ;; esac
exit 0
SHEOF
  chmod +x "$sb/scripts/test-a-orphan.sh"
  # The watchdog's sleep carries the cap, so a per-run SUITE_TIMEOUT names only this run's watchdog.
  cap=$((40000 + RANDOM % 20000))
  out=$(TMPDIR="$sb/tmp" SUITE_JOBS=2 SUITE_TIMEOUT=$cap env -u SUITE_TIER_MODE bash "$RUNNER" "$sb/scripts" 2>&1); rc=$?
  sleep 1
  orphan=$(cat "$sb/orphan.pid" 2>/dev/null); stmp=$(cat "$sb/suite-tmp.path" 2>/dev/null)
  leaks=""
  [ -n "$orphan" ] && ! kill -0 "$orphan" 2>/dev/null || leaks="$leaks suite-group-child(${orphan:-none})"
  ! pgrep -f "sleep $cap\$" >/dev/null 2>&1 || leaks="$leaks watchdog-sleep"
  [ -n "$stmp" ] && [ ! -e "$stmp" ] || leaks="$leaks suite-tmp(${stmp:-none})"
  # The attempt log is the bare mktemp's tmp.XXXXXXXXXX and its .rc.
  for _f in "$sb"/tmp/tmp.*; do [ ! -e "$_f" ] || leaks="$leaks attempt-log(${_f##*/})"; done
  if [ "$rc" -eq 2 ] && [ -z "$leaks" ]; then
    pass "P17: rc 2 and the dead lane's suite group, watchdog group, temp root and attempt log are gone"
  else
    fail "P17: expected rc 2 and nothing left behind, got rc=$rc leaks:${leaks:- none}; out: $out"
  fi
  [ -z "$orphan" ] || kill "$orphan" 2>/dev/null
  pkill -f "sleep $cap\$" 2>/dev/null
  rm -rf "$sb" "${stmp:-/nonexistent}"
else
  fail "P17: mktemp failed"
fi

echo "== P18: the bash 3.2 polling fallback still reaps and drains =="
if sb=$(mk_sandbox); then
  mk_suite "$sb" test-a.sh 15
  mk_suite "$sb" test-b.sh 15
  mk_suite "$sb" test-c-alone.sh 10
  mk_suite "$sb" test-d.sh 15
  mk_suite "$sb" test-e.sh 15
  printf '*/scripts/test-c-alone.sh  fixture: must run alone\n' > "$sb/deny.txt"
  # Polling is the only mode that sleeps 0.2s between lane checks, so a logged
  # 0.2 sleep proves the knob took effect; wait -n gives the same outcomes.
  mkdir -p "$sb/bin"
  # The runner rebuilds PATH, so the stub names the real sleep by path.
  sed -e "s|@SB@|$sb|g" -e "s|@REAL@|$(command -v sleep)|g" <<'SHEOF' > "$sb/bin/sleep"
#!/usr/bin/env bash
[ "$1" != 0.2 ] || echo poll >> "@SB@/poll.log"
exec @REAL@ "$@"
SHEOF
  chmod +x "$sb/bin/sleep"
  out=$(PATH="$sb/bin:$PATH" SUITE_JOBS=3 SUITE_LANE_WAIT=poll SUITE_PARALLEL_DENY="$sb/deny.txt" env -u SUITE_TIER_MODE bash "$RUNNER" "$sb/scripts" 2>&1); rc=$?
  if [ "$rc" -eq 0 ] && [ -s "$sb/poll.log" ] && [ "$(peak_of "$sb" test-c-alone.sh)" = 1 ] && [ ! -s "$sb/beside-alone.log" ] \
     && [ "$(wc -l < "$sb/peak.log" | tr -d ' ')" = 5 ] && [ "$(max_peak "$sb")" -ge 2 ]; then
    pass "P18: the lanes were polled, all five suites ran, two or more at once, and test-c-alone.sh ran alone"
  else
    fail "P18: expected rc 0, a polling sleep, five suites, an overlap and test-c-alone.sh alone, got rc=$rc poll.log=$(wc -l < "$sb/poll.log" 2>/dev/null | tr -d ' ') peak.log=$(tr '\n' ' ' < "$sb/peak.log") beside-alone.log=$(tr '\n' ' ' < "$sb/beside-alone.log" 2>/dev/null); out: $out"
  fi
  rm -rf "$sb"
else
  fail "P18: mktemp failed"
fi

rst_tally
