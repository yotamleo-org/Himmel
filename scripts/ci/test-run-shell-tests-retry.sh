#!/usr/bin/env bash
# selector: tree-scan
# scripts/ci/test-run-shell-tests-retry.sh -- Cases 26-34: stop-on-fail, leaked env, cap-overrun retry and keyring isolation.
#
# Split from scripts/ci/test-run-shell-tests.sh so no CI shard is bounded by one
# runner self-test file: the sharder parallelises across FILES. Siblings: test-run-shell-tests.sh (Cases 1-25) and test-run-shell-tests-ledger-fresh.sh (Case 22-fresh).
# Shared fixtures (grepq, pass/fail, the sandboxed lock) are in run-shell-tests-fixture.sh.
#
# Usage: bash scripts/ci/test-run-shell-tests-retry.sh
# Exit codes: 0 -- all cases passed; 1 -- at least one failed.
set -uo pipefail

# shellcheck source=run-shell-tests-fixture.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/run-shell-tests-fixture.sh"

# --------------------------------------------------------------------------
# Case 26 — SUITE_STOP_ON_FAIL=1 ends the shard at its first
# failing suite; unset, every suite still runs. ci.yml passes it on
# pull_request only.
# --------------------------------------------------------------------------
echo "== Case 26: SUITE_STOP_ON_FAIL stops a shard at its first failing suite =="
sb26=$(mktemp -d "${TMPDIR:-/tmp}/rst-case26.XXXXXX") || { fail "26: mktemp failed"; sb26=""; }
if [ -n "$sb26" ]; then
cat > "$sb26/test-a-fail.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 1
SHEOF
cat > "$sb26/test-b-after.sh" <<'SHEOF'
#!/usr/bin/env bash
touch "$(dirname "$0")/after.sentinel"
exit 0
SHEOF
chmod +x "$sb26/test-a-fail.sh" "$sb26/test-b-after.sh"

out26=$(SUITE_STOP_ON_FAIL=1 bash "$RUNNER" "$sb26" 2>&1)
rc26=$?
if [ "$rc26" -eq 1 ] && [ ! -e "$sb26/after.sentinel" ] && grepq "$out26" 'STOPPED:' && grepq "$out26" 'test-b-after.sh'; then
  pass "26a: SUITE_STOP_ON_FAIL=1 -> exit 1, the suite after the failure never ran, and is named"
else
  fail "26a: expected exit 1, no after.sentinel, test-b-after.sh named; rc=$rc26 sentinel=$([ -e "$sb26/after.sentinel" ] && echo present || echo absent) output: $out26"
fi
rm -f "$sb26/after.sentinel"

out26=$(env -u SUITE_STOP_ON_FAIL bash "$RUNNER" "$sb26" 2>&1)
rc26=$?
if [ "$rc26" -eq 1 ] && [ -e "$sb26/after.sentinel" ]; then
  pass "26b: SUITE_STOP_ON_FAIL unset -> every suite still runs after a failure"
else
  fail "26b: expected exit 1 with after.sentinel present; rc=$rc26 output: $out26"
fi
rm -rf "$sb26"
fi

ci_yml26="$RST_FIXTURE_DIR/../../.github/workflows/ci.yml"
stop_line26="          SUITE_STOP_ON_FAIL: \${{ github.event_name == 'pull_request' && '1' || '' }}"
shard_step26() {
  awk '/^      - run: bash scripts\/ci\/home-canary\.sh --shard / {in_step=1; next} in_step && /^      - / {exit} in_step' "$1"
}
stop_on_fail_set26() { shard_step26 "$1" | grep -qxF "$stop_line26"; }
if stop_on_fail_set26 "$ci_yml26"; then
  pass "26c: ci.yml passes SUITE_STOP_ON_FAIL on pull_request only"
else
  fail "26c: ci.yml does not set SUITE_STOP_ON_FAIL to '1' on pull_request only"
fi

sb26c=$(mktemp -d "${TMPDIR:-/tmp}/rst-case26c.XXXXXX") || { fail "26c: mktemp failed"; sb26c=""; }
if [ -n "$sb26c" ]; then
# Fixtures are the real ci.yml with one mutation each.
awk -v l="$stop_line26" '$0 == l {next} {print} /- name: Upload shard manifest/ {print "        env:"; print l}' "$ci_yml26" > "$sb26c/moved.yml"
awk '{print} /^          FAIL_LOG_DIR: failed-suite-logs$/ {print "          UNRELATED_26C: x"}' "$ci_yml26" > "$sb26c/unrelated.yml"
if ! grep -qxF "$stop_line26" "$sb26c/moved.yml"; then
  fail "26c-moved: the fixture mutation did not move the line (it is gone from moved.yml)"
elif stop_on_fail_set26 "$sb26c/moved.yml"; then
  fail "26c-moved: SUITE_STOP_ON_FAIL moved out of the shard run step still passes 26c"
else
  pass "26c-moved: SUITE_STOP_ON_FAIL moved to another step fails 26c"
fi
if shard_step26 "$sb26c/unrelated.yml" | grep -qxF "          UNRELATED_26C: x" && stop_on_fail_set26 "$sb26c/unrelated.yml"; then
  pass "26c-unrelated: an unrelated env change in the shard step still passes 26c"
else
  fail "26c-unrelated: an unrelated env change broke 26c or did not apply"
fi
rm -rf "$sb26c"
fi

# shellcheck disable=SC2016
left26=$(env SUITE_STOP_ON_FAIL=1 bash -c '. "$1"; printf "[%s]" "${SUITE_STOP_ON_FAIL-}"' _ "$RST_FIXTURE_DIR/run-shell-tests-fixture.sh" 2>&1)
if [ "$left26" = "[]" ]; then
  pass "26d: the fixture clears an inherited SUITE_STOP_ON_FAIL for the family's nested runs"
else
  fail "26d: sourcing the fixture left SUITE_STOP_ON_FAIL set: $left26"
fi

sb26e=$(mktemp -d "${TMPDIR:-/tmp}/rst-case26e.XXXXXX") || { fail "26e: mktemp failed"; sb26e=""; }
if [ -n "$sb26e" ]; then
cat > "$sb26e/test-env.sh" <<'SHEOF'
#!/usr/bin/env bash
printf '[%s]' "${SUITE_STOP_ON_FAIL-}" > "$(dirname "$0")/seen.txt"
exit 0
SHEOF
chmod +x "$sb26e/test-env.sh"
SUITE_STOP_ON_FAIL=1 bash "$RUNNER" "$sb26e" > /dev/null 2>&1
rc26e=$?
seen26=$(cat "$sb26e/seen.txt" 2>/dev/null || echo missing)
if [ "$rc26e" -eq 0 ] && [ "$seen26" = "[]" ]; then
  pass "26e: a suite the runner launches does not inherit SUITE_STOP_ON_FAIL"
else
  fail "26e: expected exit 0 and SUITE_STOP_ON_FAIL=[]; rc=$rc26e seen=$seen26"
fi
rm -rf "$sb26e"
fi

# --- 27. SUITE_TIER_MODE=pr: tier in {pr, flow} + impacted + unlisted -------
# A copy of the runner in a throwaway repo reads that repo's suite-tiers.tsv.
# thing.sh changes; test-local-hit.sh references it, test-local-miss.sh does not.
# shellcheck source=../lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$RST_FIXTURE_DIR/../lib/fixture-tempdir.sh"
src27="$(cd "$RST_FIXTURE_DIR/../.." && pwd)"
sb27="$(fixture_mktemp_dir)" || { fail "27: mktemp failed"; sb27=""; }
if [ -n "$sb27" ]; then
(
  fixture_enter_git_init_dir "$sb27" || exit 1
  git init -q
  git config user.email t@e
  git config user.name t
) || fail "27: sandbox git init failed"
mkdir -p "$sb27/scripts/ci" "$sb27/scripts/lib" "$sb27/scripts/cr" "$sb27/docs"
cp "$RUNNER" "$sb27/scripts/ci/run-shell-tests.sh"
cp "$src27/scripts/cr/impacted-suites.sh" "$src27/scripts/cr/anchor-handoff.sh" "$sb27/scripts/cr/"
for lib27 in chokepoint-seam-guard.sh proc-tree.sh git-test-env.sh override-env.sh runtime-preflight.sh suite-semaphore.sh; do
  cp "$src27/scripts/lib/$lib27" "$sb27/scripts/lib/$lib27"
done
T27_LOG="$sb27/ran.log"
export T27_LOG
mk27() {
  # shellcheck disable=SC2016  # $T27_LOG must expand in the generated suite, not here
  printf '#!/usr/bin/env bash\n%s\necho %s >> "$T27_LOG"\nexit %s\n' "$3" "$2" "${4:-0}" > "$sb27/scripts/$1"
}
printf '# thing\n' > "$sb27/scripts/lib/thing.sh"
mk27 test-local-hit.sh local-hit '# drives scripts/lib/thing.sh'
mk27 test-local-miss.sh local-miss '# drives nothing that changed'
mk27 test-unlisted.sh unlisted '# has no suite-tiers.tsv row'
mk27 test-pr.sh pr '# a pr-tier suite'
mk27 test-quar.sh quar '# a quarantined flake' 1
printf '# fixture tiers\nscripts/test-local-hit.sh\tlocal\tx\nscripts/test-local-miss.sh\tlocal\tx\nscripts/test-pr.sh\tpr\tguard\nscripts/test-quar.sh\tquarantine\tflakes\n' \
  > "$sb27/scripts/ci/suite-tiers.tsv"
printf '# doc\n' > "$sb27/docs/note.md"
git -C "$sb27" add -A
git -C "$sb27" commit -q -m "chore: base"
base27=$(git -C "$sb27" rev-parse HEAD)
printf 'echo changed\n' >> "$sb27/scripts/lib/thing.sh"
git -C "$sb27" commit -q -am "fix: thing"
range27="$base27..$(git -C "$sb27" rev-parse HEAD)"
printf '# changed\n' >> "$sb27/docs/note.md"
git -C "$sb27" commit -q -am "docs: note"
docs27="$(git -C "$sb27" rev-parse HEAD~1)..$(git -C "$sb27" rev-parse HEAD)"
run27="$sb27/scripts/ci/run-shell-tests.sh"

: > "$T27_LOG"
out27=$(SUITE_TIER_MODE="pr" bash "$run27" --scan-repo-of-script --impacted "$range27" 2>&1); rc27=$?
ran27=$(sort -u "$T27_LOG" | tr '\n' ' ')
if [ "$ran27" = "local-hit pr quar unlisted " ]; then
  pass "27a: pr mode runs the impacted local suite and skips the other local one"
else
  fail "27a: ran='$ran27' (want local-hit pr quar unlisted) output: $out27"
fi
if grepq "$out27" '\[SKIP\].*test-local-miss\.sh — tier: local'; then
  pass "27a: the unimpacted local suite is [SKIP]ped with a 'tier: local' reason"
else
  fail "27a: no 'tier: local' skip for test-local-miss.sh: $out27"
fi
case "$ran27" in
  *unlisted*) pass "27b: a suite with no suite-tiers.tsv row runs in pr mode" ;;
  *) fail "27b: the unlisted suite did not run: $out27" ;;
esac
if [ "$rc27" -eq 0 ] && grepq "$out27" '\[QUARANTINE\].*test-quar\.sh'; then
  pass "27c: a failing quarantine suite runs, is marked [QUARANTINE] and the run is rc 0"
else
  fail "27c: rc=$rc27 (want 0 with a [QUARANTINE] line): $out27"
fi
out27=$(SUITE_TIER_MODE=all bash "$run27" --scan-repo-of-script 2>&1); rc27=$?
if [ "$rc27" -eq 0 ] && grepq "$out27" '\[QUARANTINE\].*test-quar\.sh' && grepq "$out27" 'QUARANTINE: 1 '; then
  pass "27c-all: a failing quarantine suite is [QUARANTINE]d and counted, rc 0, under SUITE_TIER_MODE=all"
else
  fail "27c-all: rc=$rc27 (want 0 with a [QUARANTINE] line and a quarantined count): $out27"
fi
out27=$(SUITE_TIER_MODE=fast bash "$run27" --scan-repo-of-script 2>&1); rc27=$?
if [ "$rc27" -eq 0 ] && grepq "$out27" '\[QUARANTINE\].*test-quar\.sh'; then
  pass "27c-fast: a failing quarantine suite is [QUARANTINE]d, rc 0, under SUITE_TIER_MODE=fast"
else
  fail "27c-fast: rc=$rc27 (want 0 with a [QUARANTINE] line): $out27"
fi
: > "$T27_LOG"
out27=$(SUITE_TIERS_TSV="$sb27/missing.tsv" SUITE_TIER_MODE=all bash "$run27" --scan-repo-of-script 2>&1); rc27=$?
if [ "$rc27" -eq 1 ] && grep -qx 'quar' "$T27_LOG" && ! grepq "$out27" '\[QUARANTINE\].*test-quar\.sh'; then
  pass "27c-unreadable: an unreadable non-pr tiers override quarantines nothing, so the failing suite fails the run"
else
  fail "27c-unreadable: rc=$rc27 (want 1 without a [QUARANTINE] line): $out27"
fi
out27=$(env -u SUITE_TIER_MODE bash "$run27" --scan-repo-of-script 2>&1); rc27=$?
if [ "$rc27" -eq 0 ] && grepq "$out27" '\[QUARANTINE\].*test-quar\.sh'; then
  pass "27c-unset: a failing quarantine suite is [QUARANTINE]d, rc 0, with SUITE_TIER_MODE unset"
else
  fail "27c-unset: rc=$rc27 (want 0 with a [QUARANTINE] line): $out27"
fi

: > "$T27_LOG"
out27=$(SUITE_TIER_MODE="pr" bash "$run27" --scan-repo-of-script --list 2>&1); rc27=$?
if [ "$rc27" -eq 0 ] && [ ! -s "$T27_LOG" ] \
   && grepq "$out27" '\[SKIP\].*test-local-hit\.sh — tier: local' \
   && grepq "$out27" '\[SKIP\].*test-local-miss\.sh — tier: local' \
   && grepq "$out27" '\[RUN \].*test-pr\.sh' \
   && grepq "$out27" '\[RUN \].*test-quar\.sh' \
   && grepq "$out27" '\[RUN \].*test-unlisted\.sh'; then
  pass "27d: pr --list with no range plans pr, quarantine and unlisted suites and skips every local one"
else
  fail "27d: rc=$rc27 output: $out27"
fi

: > "$T27_LOG"
out27=$(SUITE_TIER_MODE="pr" bash "$run27" --scan-repo-of-script --impacted "$docs27" 2>&1); rc27=$?
ran27=$(sort -u "$T27_LOG" | tr '\n' ' ')
if [ "$rc27" -eq 0 ] && [ "$ran27" = "pr quar unlisted " ]; then
  pass "27e: a docs-only range in pr mode still runs the pr-tier and unlisted suites"
else
  fail "27e: rc=$rc27 ran='$ran27' (want pr quar unlisted) output: $out27"
fi

SUITE_TIERS_TSV="$sb27/missing.tsv" SUITE_TIER_MODE=pr bash "$run27" --scan-repo-of-script --list > /dev/null 2>&1; rc27=$?
if [ "$rc27" -eq 2 ]; then
  pass "27f: pr mode with no readable suite-tiers.tsv is refused rc 2"
else
  fail "27f: a missing suite-tiers.tsv gave rc=$rc27, want 2"
fi

: > "$T27_LOG"
printf 'ran.log\n' >> "$sb27/.git/info/exclude"
out27=$(cd "$sb27" && SUITE_TIER_MODE="pr" bash "$run27" --scan-repo-of-script --changed-since HEAD~1 2>&1); rc27=$?
ran27=$(sort -u "$T27_LOG" | tr '\n' ' ')
if [ "$rc27" -eq 0 ] && [ "$ran27" = "pr quar unlisted " ]; then
  pass "27g: a docs-only --changed-since diff in pr mode still runs the pr-tier and unlisted suites"
else
  fail "27g: rc=$rc27 ran='$ran27' (want pr quar unlisted) output: $out27"
fi

# The sandbox has no impacted-selection.sh, so a base-sourced run takes the
# selector's fail-open `mode full` header.
: > "$T27_LOG"
out27=$(cd "$sb27" && SUITE_TIER_MODE="pr" SUITE_IMPACTED_FROM_BASE="$base27" bash "$run27" --scan-repo-of-script 2>&1); rc27=$?
ran27=$(sort -u "$T27_LOG" | tr '\n' ' ')
if [ "$rc27" -eq 0 ] && [ "$ran27" = "local-hit local-miss pr quar unlisted " ]; then
  pass "27h: pr mode under a base-sourced 'mode full' header runs every tier, local included"
else
  fail "27h: rc=$rc27 ran='$ran27' (want local-hit local-miss pr quar unlisted) output: $out27"
fi

mk27 test-prfail.sh prfail '# a failing pr-tier suite' 1
printf 'scripts/test-prfail.sh\tpr\tguard\n' >> "$sb27/scripts/ci/suite-tiers.tsv"
: > "$T27_LOG"
out27=$(SUITE_TIER_MODE="pr" bash "$run27" --scan-repo-of-script 2>&1); rc27=$?
if [ "$rc27" -eq 1 ] && grepq "$out27" '\[QUARANTINE\].*test-quar\.sh' \
   && ! grepq "$out27" '\[QUARANTINE\].*test-prfail\.sh'; then
  pass "27i: a failing pr-tier suite fails a pr-mode run; only the quarantine row is forgiven"
else
  fail "27i: rc=$rc27 (want 1, test-prfail.sh not [QUARANTINE]) output: $out27"
fi
out27=$(SUITE_TIER_MODE=all bash "$run27" --scan-repo-of-script 2>&1); rc27=$?
if [ "$rc27" -eq 1 ] && grepq "$out27" '\[QUARANTINE\].*test-quar\.sh' \
   && ! grepq "$out27" '\[QUARANTINE\].*test-prfail\.sh'; then
  pass "27j: a failing pr-tier suite fails an all-mode run; only the quarantine row is forgiven"
else
  fail "27j: rc=$rc27 (want 1, test-prfail.sh not [QUARANTINE]) output: $out27"
fi
rm -rf "$sb27"
fi

echo "== Case 28: a leaked session env never reaches a suite =="
sb28=$(mktemp -d -t himmel-suite-envleak.XXXXXX) || { fail "28: mktemp failed"; sb28=""; }
if [ -n "$sb28" ]; then
mkdir -p "$sb28/scripts"
cat > "$sb28/scripts/test-envleak.sh" <<'SHEOF'
#!/usr/bin/env bash
printf 'worker=%s profile=%s fixture=%s\n' "${WORKER_SESSION_ID-unset}" \
  "${HIMMEL_WORKER_SESSION_PROFILE-unset}" "${HIMMEL_TEST_FIXTURE-unset}" > "$ENVLEAK_LOG"
exit 0
SHEOF
chmod +x "$sb28/scripts/test-envleak.sh"

# Control: the leak does reach the suite when the runner is not in the way.
WORKER_SESSION_ID=leaked-28 HIMMEL_WORKER_SESSION_PROFILE=leaked-28 ENVLEAK_LOG="$sb28/direct.log" \
  env -u HIMMEL_TEST_FIXTURE bash "$sb28/scripts/test-envleak.sh"
WORKER_SESSION_ID=leaked-28 HIMMEL_WORKER_SESSION_PROFILE=leaked-28 ENVLEAK_LOG="$sb28/runner.log" \
  env -u SUITE_TIER_MODE bash "$RUNNER" "$sb28/scripts" >/dev/null 2>&1
rc28=$?
direct28=$(cat "$sb28/direct.log" 2>/dev/null)
runner28=$(cat "$sb28/runner.log" 2>/dev/null)
if [ "$direct28" = "worker=leaked-28 profile=leaked-28 fixture=unset" ] \
   && [ "$rc28" -eq 0 ] && [ "$runner28" = "worker=unset profile=unset fixture=1" ]; then
  pass "28: the runner scrubs the leaked session env and keeps HIMMEL_TEST_FIXTURE"
else
  fail "28: rc=$rc28 direct=[$direct28] runner=[$runner28] (want 0, the leak in direct only, fixture=1 via the runner)"
fi
rm -rf "$sb28"
fi

echo "== Case 29: a suite that overran its cap is rerun exactly once before it counts =="
sb29=$(mktemp -d -t himmel-suite-caprerun.XXXXXX) || { fail "29: mktemp failed"; sb29=""; }
if [ -n "$sb29" ]; then
mkdir -p "$sb29/scripts"
# test-capslow.sh overruns the 2 s cap on its first attempt and finishes on the second.
cat > "$sb29/scripts/test-capslow.sh" <<'SHEOF'
#!/usr/bin/env bash
echo run >> "$CAP29_DIR/slow.runs"
[ "$(wc -l < "$CAP29_DIR/slow.runs")" -ge 2 ] && exit 0
sleep 30
SHEOF
# test-capstuck.sh overruns the cap on every attempt.
cat > "$sb29/scripts/test-capstuck.sh" <<'SHEOF'
#!/usr/bin/env bash
echo run >> "$CAP29_DIR/stuck.runs"
sleep 30
SHEOF
# test-capskip.sh overruns the cap on its first attempt and exits 0 through a SKIP line on the second.
cat > "$sb29/scripts/test-capskip.sh" <<'SHEOF'
#!/usr/bin/env bash
echo run >> "$CAP29_DIR/skip.runs"
[ "$(wc -l < "$CAP29_DIR/skip.runs")" -ge 2 ] && { echo "SKIP: nothing to run here"; exit 0; }
sleep 30
SHEOF
chmod +x "$sb29/scripts/test-capslow.sh" "$sb29/scripts/test-capstuck.sh" "$sb29/scripts/test-capskip.sh"
# Real run 40035630814 (shell-unit-shard 3, main, 2026-10-24) printed:
#   [CAP EXCEEDED] scripts/test-adopt.sh (ran 1203s, cap 1200s) — killed by the runner's watchdog at the cap, no exit status observed
real29='\[CAP EXCEEDED\] [^ ]*test-capstuck\.sh \(ran [0-9]+s, cap 2s\) — killed by the runner.s watchdog at the cap, no exit status observed'

mkdir -p "$sb29/slowdir" "$sb29/stuckdir" "$sb29/skipdir"
cp "$sb29/scripts/test-capslow.sh" "$sb29/slowdir/"
cp "$sb29/scripts/test-capstuck.sh" "$sb29/stuckdir/"
cp "$sb29/scripts/test-capskip.sh" "$sb29/skipdir/"
out29a=$(CAP29_DIR="$sb29" SUITE_FLAKE_LEDGER="$sb29/flake-ledger.jsonl" SUITE_TIMEOUT=2 SUITE_TIER_MODE=all bash "$RUNNER" "$sb29/slowdir" 2>&1); rc29a=$?
runs29a=$(wc -l < "$sb29/slow.runs" 2>/dev/null | tr -d ' ')
if [ "$rc29a" -eq 0 ] && [ "$runs29a" = 2 ] && grepq "$out29a" '\[FLAKE\] .*test-capslow\.sh'; then
  pass "29a: a suite that overran its cap and finished on the rerun is a FLAKE, rc 0, run twice"
else
  fail "29a: rc=$rc29a runs=$runs29a (want rc 0, 2 runs, a [FLAKE] line) output: $out29a"
fi

out29b=$(CAP29_DIR="$sb29" SUITE_TIMEOUT=2 SUITE_TIER_MODE=all bash "$RUNNER" "$sb29/stuckdir" 2>&1); rc29b=$?
runs29b=$(wc -l < "$sb29/stuck.runs" 2>/dev/null | tr -d ' ')
if [ "$rc29b" -eq 1 ] && [ "$runs29b" = 2 ]; then
  pass "29b: a suite that overruns its cap on both attempts runs exactly twice and fails the run"
else
  fail "29b: rc=$rc29b runs=$runs29b (want rc 1 and exactly 2 runs) output: $out29b"
fi
if grepq "$out29b" -E '\[CAP EXCEEDED\] [^ ]*test-capstuck\.sh \(ran [0-9]+s, cap 2s\).*the cap applies per attempt'; then
  pass "29b-note: a capped rerun's [CAP EXCEEDED] line says ran is the sum of attempts and the cap is per attempt"
else
  fail "29b-note: no per-attempt wording on the rerun's [CAP EXCEEDED] line: $out29b"
fi
if grepq "$out29b" -E "$real29"; then
  pass "29c: the final CAP EXCEEDED line keeps the shape CI printed for test-adopt.sh"
else
  fail "29c: no CAP EXCEEDED line in the real CI shape: $out29b"
fi

out29d=$(CAP29_DIR="$sb29" SUITE_FLAKE_LEDGER="$sb29/flake-ledger.jsonl" SUITE_TIMEOUT=2 SUITE_TIER_MODE=all bash "$RUNNER" "$sb29/skipdir" 2>&1); rc29d=$?
if [ "$rc29d" -eq 1 ] && grepq "$out29d" '\[CAP EXCEEDED\] [^ ]*test-capskip\.sh' && grepq "$out29d" 'TIMED OUT: 1'; then
  pass "29d: a rerun that only SKIPs keeps the first attempt's CAP EXCEEDED and TIMED OUT count"
else
  fail "29d: rc=$rc29d (want rc 1, a [CAP EXCEEDED] line and TIMED OUT: 1) output: $out29d"
fi
rm -rf "$sb29"
fi

echo "== Case 30: a suite never sees the operator's OS keyring (HIMMEL-7576) =="
sb30=$(mktemp -d -t himmel-suite-keyring.XXXXXX) || { fail "30: mktemp failed"; sb30=""; }
if [ -n "$sb30" ]; then
mkdir -p "$sb30/scripts"
cat > "$sb30/scripts/test-keyring.sh" <<'SHEOF'
#!/usr/bin/env bash
printf 'keyring=%s\n' "${HIMMEL_SECRETS_KEYRING-unset}" > "$KEYRING_LOG"
exit 0
SHEOF
chmod +x "$sb30/scripts/test-keyring.sh"

# Negative control: plain bash, no runner, leaves the variable unset.
KEYRING_LOG="$sb30/direct.log" env -u HIMMEL_SECRETS_KEYRING bash "$sb30/scripts/test-keyring.sh"
directrc30=$?
KEYRING_LOG="$sb30/runner.log" env -u HIMMEL_SECRETS_KEYRING -u SUITE_TIER_MODE bash "$RUNNER" "$sb30/scripts" >/dev/null 2>&1
rc30=$?
direct30=$(cat "$sb30/direct.log" 2>/dev/null)
runner30=$(cat "$sb30/runner.log" 2>/dev/null)
if [ "$directrc30" -eq 0 ] && [ "$direct30" = "keyring=unset" ] && [ "$rc30" -eq 0 ] && [ "$runner30" = "keyring=off" ]; then
  pass "30: the runner exports HIMMEL_SECRETS_KEYRING=off to a suite; plain bash leaves it unset"
else
  fail "30: directrc=$directrc30 rc=$rc30 direct=[$direct30] runner=[$runner30] (want 0, keyring=unset direct, keyring=off via the runner)"
fi
rm -rf "$sb30"
fi

# --------------------------------------------------------------------------
# Case 31 — listing forks no `tr` per skip-list line per suite.
# Over the runner's real SKIP_LIST that fork is tens of thousands of processes
# per `--list`, and Case 22-fresh makes 32 of them: the CI runner needs well
# over 1300s for this file when it is paid, against a 1500s cap. The fixture is
# the runner's own SKIP_LIST; a PATH shim counts every `tr` the runner starts.
# --------------------------------------------------------------------------
echo "== Case 31 (HIMMEL-8312): listing forks no tr per skip-list line per suite (129 before, a fixed few after) =="
sb31=$(mktemp -d "${TMPDIR:-/tmp}/rst-case31.XXXXXX") || { fail "31: mktemp failed"; sb31=""; }
if [ -n "$sb31" ]; then
mkdir -p "$sb31/scripts" "$sb31/fakebin"
for _n31 in a b c d e f; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$sb31/scripts/test-case31-$_n31.sh"
  chmod +x "$sb31/scripts/test-case31-$_n31.sh"
done
real_tr31=$(command -v tr)
printf '#!/usr/bin/env bash\necho x >> "%s/tr.calls"\nexec "%s" "$@"\n' "$sb31" "$real_tr31" > "$sb31/fakebin/tr"
chmod +x "$sb31/fakebin/tr"

# Negative control: the shim counts a direct call, so the bound below is real.
# shellcheck disable=SC2031
PATH="$sb31/fakebin:$PATH" tr -d x <<< "x" > /dev/null
ctl31=$(grep -c . "$sb31/tr.calls" 2>/dev/null || true)
rm -f "$sb31/tr.calls"

# shellcheck disable=SC2031
out31=$(PATH="$sb31/fakebin:$PATH" HIMMEL_RUNTIME_PREFLIGHT=0 bash "$RUNNER" --list "$sb31/scripts" 2>&1)
rc31=$?
calls31=$(grep -c . "$sb31/tr.calls" 2>/dev/null || true)
nsuites31=$(grep -c '^\[RUN \] .*test-case31-' <<< "$out31")
if [ "$ctl31" -eq 1 ] && [ "$rc31" -eq 0 ] && [ "$nsuites31" -eq 6 ] && [ "${calls31:-0}" -le "$nsuites31" ]; then
  pass "31: --list over 6 suites started ${calls31:-0} tr (at most one per suite; was 129 with the per-line fork)"
else
  fail "31: control=$ctl31 (want 1) rc=$rc31 listed=$nsuites31 (want 6) tr calls=${calls31:-0} (want at most $nsuites31): output: $out31"
fi
rm -rf "$sb31"
fi

# --------------------------------------------------------------------------
# Case 32 — a cap overrun is not rerun when the rerun cannot fit the run's
# outer budget. Real run 41154955844 (shell-unit-shard 1, 2026-10-31) printed:
#   [TIME] scripts/ci/test-run-shell-tests.sh — exceeded 1500s; suite and its descendants terminated
#   [RETRY] scripts/ci/test-run-shell-tests.sh exceeded its 1500s cap; re-running it once
#   home-canary: FAIL runner timed out after 3300s (rc=124)
# so the rerun of one overrun spent the shard's 3300s and no summary printed.
# --------------------------------------------------------------------------
echo "== Case 32 (HIMMEL-8341): a cap overrun is not rerun past the outer budget =="
sb32=$(mktemp -d "${TMPDIR:-/tmp}/rst-case32.XXXXXX") || { fail "32: mktemp failed"; sb32=""; }
if [ -n "$sb32" ]; then
mkdir -p "$sb32/scripts"
cat > "$sb32/scripts/test-stuck32.sh" <<'SHEOF'
#!/usr/bin/env bash
echo run >> "$CAP32_DIR/stuck.runs"
sleep 30
SHEOF
chmod +x "$sb32/scripts/test-stuck32.sh"
real32='\[TIME\] [^ ]*test-stuck32\.sh — exceeded 2s; suite and its descendants terminated'

out32=$(CAP32_DIR="$sb32" HOME_CANARY_TIMEOUT=3 SUITE_RUN_BUDGET=7200 SUITE_TIMEOUT=2 SUITE_TIER_MODE=all bash "$RUNNER" "$sb32/scripts" 2>&1); rc32=$?
runs32=$(wc -l < "$sb32/stuck.runs" 2>/dev/null | tr -d ' ')
if [ "$rc32" -eq 1 ] && [ "$runs32" = 1 ] && grepq "$out32" -E "$real32" \
   && grepq "$out32" '\[NO-RETRY\] [^ ]*test-stuck32\.sh' && ! grepq "$out32" '\[RETRY\]' && grepq "$out32" 'TIMED OUT: 1'; then
  pass "32a: an overrun whose rerun cannot fit HOME_CANARY_TIMEOUT runs once, is named [NO-RETRY] and TIMED OUT, rc 1"
else
  fail "32a: rc=$rc32 runs=$runs32 (want rc 1, 1 run, [TIME] and [NO-RETRY] lines, no [RETRY], TIMED OUT: 1) output: $out32"
fi

rm -f "$sb32/stuck.runs"
out32=$(CAP32_DIR="$sb32" HOME_CANARY_TIMEOUT='' SUITE_RUN_BUDGET=3 SUITE_TIMEOUT=2 SUITE_TIER_MODE=all bash "$RUNNER" "$sb32/scripts" 2>&1); rc32=$?
runs32=$(wc -l < "$sb32/stuck.runs" 2>/dev/null | tr -d ' ')
if [ "$rc32" -eq 1 ] && [ "$runs32" = 1 ] && grepq "$out32" '\[NO-RETRY\] [^ ]*test-stuck32\.sh'; then
  pass "32b: SUITE_RUN_BUDGET bounds the rerun the same way"
else
  fail "32b: rc=$rc32 runs=$runs32 (want rc 1, 1 run, a [NO-RETRY] line) output: $out32"
fi

rm -f "$sb32/stuck.runs"
out32=$(CAP32_DIR="$sb32" HOME_CANARY_TIMEOUT=60 SUITE_RUN_BUDGET=7200 SUITE_TIMEOUT=2 SUITE_TIER_MODE=all bash "$RUNNER" "$sb32/scripts" 2>&1); rc32=$?
runs32=$(wc -l < "$sb32/stuck.runs" 2>/dev/null | tr -d ' ')
if [ "$rc32" -eq 1 ] && [ "$runs32" = 2 ] && ! grepq "$out32" '\[NO-RETRY\]'; then
  pass "32c: control — a rerun that fits the budget still happens"
else
  fail "32c: rc=$rc32 runs=$runs32 (want rc 1, 2 runs, no [NO-RETRY]) output: $out32"
fi
rm -rf "$sb32"
fi

step32=$(shard_step26 "$ci_yml26")
if grepq "$step32" -E '^          HOME_CANARY_TIMEOUT: "[0-9]+"$'; then
  pass "32d: ci.yml's shard run step sets the HOME_CANARY_TIMEOUT the runner budgets its reruns against"
else
  fail "32d: ci.yml's shard run step no longer sets HOME_CANARY_TIMEOUT"
fi

echo "== Case 33 (HIMMEL-8378): a retried suite's seconds are the sum of every attempt =="
sb33=$(mktemp -d -t himmel-suite-retrysum.XXXXXX) || { fail "33: mktemp failed"; sb33=""; }
# the runner keys the tier row by the physical path (/private/var on macOS); a failed resolve stops the case
[ -z "$sb33" ] || sb33_phys=$(cd "$sb33" && pwd -P) || { fail "33: cannot resolve the sandbox path $sb33"; sb33_phys=""; }
[ -z "$sb33" ] || sb33="$sb33_phys"
if [ -n "$sb33" ]; then
mkdir -p "$sb33/scripts" "$sb33/flakedir" "$sb33/home"
# Both suites spend 3 s per attempt, so a runner that times only the last attempt reports 3-4 s and the sum is 6-7 s.
cat > "$sb33/scripts/test-quar33.sh" <<'SHEOF'
#!/usr/bin/env bash
sleep 3
exit 1
SHEOF
cat > "$sb33/flakedir/test-flake33.sh" <<'SHEOF'
#!/usr/bin/env bash
echo run >> "$SUM33_DIR/flake.runs"
sleep 3
[ "$(wc -l < "$SUM33_DIR/flake.runs")" -ge 2 ] && exit 0
exit 1
SHEOF
chmod +x "$sb33/scripts/test-quar33.sh" "$sb33/flakedir/test-flake33.sh"
printf '# fixture tiers\n%s\tquarantine\tflakes\n' "$sb33/scripts/test-quar33.sh" > "$sb33/tiers.tsv"  # a suite outside the repo root keeps its absolute path as the tier key
# Real run 41185890791 (shell-unit-shard 5, main, 2026-10-31) printed, for a suite that failed both attempts:
#   [QUARANTINE] scripts/handover/chief-kit/test-chief-wait-b.sh (rc=1, 509s) — tier quarantine, not failing the run
out33=$(HOME="$sb33/home" HIMMEL_SUITE_LEDGER="$sb33/suite-runs.jsonl" SUM33_DIR="$sb33" SUITE_TIERS_TSV="$sb33/tiers.tsv" SUITE_FLAKE_LEDGER="$sb33/flake-ledger.jsonl" SUITE_TIER_MODE=all bash "$RUNNER" "$sb33/scripts" 2>&1); rc33=$?
dur33=$(printf '%s\n' "$out33" | sed -n 's/^\[QUARANTINE\] .*test-quar33\.sh (rc=1, \([0-9][0-9]*\)s) — tier quarantine, not failing the run$/\1/p')
if [ "$rc33" -eq 0 ] && [ -n "$dur33" ] && [ "$dur33" -ge 6 ]; then
  pass "33a: a quarantined suite that failed both attempts reports both attempts' seconds (${dur33}s)"
else
  fail "33a: rc=$rc33 dur='$dur33' (want rc 0 and a [QUARANTINE] line of at least 6s) output: $out33"
fi
out33=$(HOME="$sb33/home" HIMMEL_SUITE_LEDGER="$sb33/suite-runs.jsonl" SUM33_DIR="$sb33" SUITE_FLAKE_LEDGER="$sb33/flake-ledger.jsonl" SUITE_TIER_MODE=all bash "$RUNNER" "$sb33/flakedir" 2>&1); rc33=$?
dur33=$(printf '%s\n' "$out33" | sed -n 's/^\[FLAKE\] .*test-flake33\.sh (first run rc=1, passed on retry, \([0-9][0-9]*\)s)$/\1/p')
if [ "$rc33" -eq 0 ] && [ -n "$dur33" ] && [ "$dur33" -ge 6 ]; then
  pass "33b: a flaked suite reports both attempts' seconds (${dur33}s)"
else
  fail "33b: rc=$rc33 dur='$dur33' (want rc 0 and a [FLAKE] line of at least 6s) output: $out33"
fi
rm -rf "$sb33"
fi

# --------------------------------------------------------------------------
# Case 34: a retry that exits 0 through a SKIP line the FIRST attempt also
# printed is evidence of a flake; one whose SKIP is new on the retry is not.
# The stop-guard suite prints a constant RED-control SKIP on every run.
# --------------------------------------------------------------------------
echo "== Case 34: a SKIP that also fired on the first attempt does not defeat the retry =="
sb34=$(mktemp -d "${TMPDIR:-/tmp}/rst-case34.XXXXXX") || { fail "34: mktemp failed"; sb34=""; }
if [ -n "$sb34" ]; then
mkdir -p "$sb34/constdir" "$sb34/newdir"
# Fails on its first attempt after printing the same SKIP the retry prints, then exits 0.
cat > "$sb34/constdir/test-constskip.sh" <<'SHEOF'
#!/usr/bin/env bash
echo run >> "$C34_DIR/const.runs"
echo "  SKIP could not extract the pre-fix hook - RED control skipped"
[ "$(wc -l < "$C34_DIR/const.runs")" -ge 2 ] && exit 0
exit 1
SHEOF
# Fails quietly on its first attempt and exits 0 through a SKIP on the second.
cat > "$sb34/newdir/test-newskip.sh" <<'SHEOF'
#!/usr/bin/env bash
echo run >> "$C34_DIR/new.runs"
[ "$(wc -l < "$C34_DIR/new.runs")" -ge 2 ] && { echo "  SKIP nothing to run here"; exit 0; }
exit 1
SHEOF
chmod +x "$sb34/constdir/test-constskip.sh" "$sb34/newdir/test-newskip.sh"
out34a=$(C34_DIR="$sb34" SUITE_FLAKE_LEDGER="$sb34/flake-ledger.jsonl" SUITE_TIER_MODE=all bash "$RUNNER" "$sb34/constdir" 2>&1); rc34a=$?
if [ "$rc34a" -eq 0 ] && grepq "$out34a" '\[FLAKE\] .*test-constskip\.sh' && ! grepq "$out34a" -F '[RETRY-SKIP]'; then
  pass "34a: a retry whose only SKIP also fired on the first attempt counts as a FLAKE, rc 0"
else
  fail "34a: rc=$rc34a (want rc 0, a [FLAKE] line, no [RETRY-SKIP]) output: $out34a"
fi
out34b=$(C34_DIR="$sb34" SUITE_FLAKE_LEDGER="$sb34/flake-ledger.jsonl" SUITE_TIER_MODE=all bash "$RUNNER" "$sb34/newdir" 2>&1); rc34b=$?
if [ "$rc34b" -eq 1 ] && grepq "$out34b" '\[RETRY-SKIP\] .*test-newskip\.sh'; then
  pass "34b: a retry that SKIPs only the second time keeps the first failure"
else
  fail "34b: rc=$rc34b (want rc 1 and a [RETRY-SKIP] line) output: $out34b"
fi
mkdir -p "$sb34/moredir"
# Prints the same SKIP once on its first attempt and twice on the retry: the retry skipped more than the first.
cat > "$sb34/moredir/test-moreskip.sh" <<'SHEOF'
#!/usr/bin/env bash
echo run >> "$C34_DIR/more.runs"
echo "  SKIP case one needs a tool"
if [ "$(wc -l < "$C34_DIR/more.runs")" -ge 2 ]; then echo "  SKIP case one needs a tool"; exit 0; fi
exit 1
SHEOF
chmod +x "$sb34/moredir/test-moreskip.sh"
out34c=$(C34_DIR="$sb34" SUITE_FLAKE_LEDGER="$sb34/flake-ledger.jsonl" SUITE_TIER_MODE=all bash "$RUNNER" "$sb34/moredir" 2>&1); rc34c=$?
if [ "$rc34c" -eq 1 ] && grepq "$out34c" '\[RETRY-SKIP\] .*test-moreskip\.sh'; then
  pass "34c: a retry that prints the same SKIP more often than the first attempt keeps the first failure"
else
  fail "34c: rc=$rc34c (want rc 1 and a [RETRY-SKIP] line) output: $out34c"
fi
rm -rf "$sb34"
fi


rst_tally
