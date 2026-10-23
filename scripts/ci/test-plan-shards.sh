#!/usr/bin/env bash
# selector: tree-scan
# scripts/ci/test-plan-shards.sh — scripts/ci/plan-shards.sh: the
# plan job's list of shell-unit shards that have a suite to run. Each case runs
# a COPY of plan-shards.sh beside a stub shard-has-work.sh that answers per shard
# and a stub run-shell-tests.sh whose --list fails unless a case gives it a list.
#
#   PS1  every shard has work                  -> all n listed, nothing absent
#   PS2  no shard has work (docs-only)         -> shards=[] , every shard absent
#   PS3  some shards empty                     -> only those with work listed
#   PS4  a probe that fails or prints nothing  -> that shard is listed (fail closed)
#   PS5  a probe that prints garbage           -> that shard is listed (fail closed)
#   PS6  usage error (no / non-numeric n)      -> rc 2
#   PS7  the probe gets the shard spec and root it was asked about
#   PS8  ci.yml feeds the shard matrix and the shard total from the plan output
#   PS9  sizing off the real ledger: a few short suites take 1 shard, every
#        ledger suite keeps all n
#   PS10 sizing off a hand ledger: the smallest N whose longest shard fits 600 s
#        (or the longest shard at n) wins; a suite absent from it costs the median
#   PS11 a --list with nothing selected -> shards=[] , total 1
#   PS12 a --list that fails or lacks its footer -> the probes at n (fail closed)
#   PS13 the --list gets the runner args after -- and the root
#   PS14 ci.yml runs the shards through home-canary.sh; no home-canary matrix
#   PS15 an empty or missing ledger -> the probes at n
#   PS16 a root omitted before -- defaults to .
#   PS20 n above the 64 cap is clamped to 64 with a message naming CI_MAX_SHARDS,
#        at the planner and through ci.yml's own plan step
#   PS22 ci.yml's plan step with an empty CI_MAX_SHARDS plans a full real-ledger sweep at 20
#   PS23 ci.yml's plan step asks its --list under SUITE_TIER_MODE=pr, the shards' PR tier
#   PS21 n of 0 or a negative value is a usage error naming CI_MAX_SHARDS, and
#        ci.yml's plan step then falls back to its empty output (8 legs)
#
# Platform guard: bash-only, no .ps1 twin; Linux CI is the caller.
#
# Usage: bash scripts/ci/test-plan-shards.sh
# Exit codes: 0 — all cases passed; 1 — at least one failed.
set -uo pipefail

# shellcheck source=run-shell-tests-fixture.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/run-shell-tests-fixture.sh"

SRC_ROOT="$(cd "$RST_FIXTURE_DIR/../.." && pwd)"
PS="$SUITE_LOCK_SANDBOX/ps"
mkdir -p "$PS"
if [ ! -f "$SRC_ROOT/scripts/ci/plan-shards.sh" ]; then
  fail "missing scripts/ci/plan-shards.sh"
  rst_tally
fi
cp "$SRC_ROOT/scripts/ci/plan-shards.sh" "$PS/plan-shards.sh"
# The stub answers from $STUB_ANSWERS, a space list of <k>=<true|false|fail|junk>,
# and records every call to $STUB_LOG.
cat > "$PS/shard-has-work.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s|%s\n' "${1:-}" "${2:-}" >> "${STUB_LOG:-/dev/null}"
printf '%s\n' "$*" >> "${STUB_ARGS_LOG:-/dev/null}"
k="${1%%/*}"
for a in $STUB_ANSWERS; do
  [ "${a%%=*}" = "$k" ] || continue
  case "${a#*=}" in
    true|false) echo "has_work=${a#*=}" ;;
    fail) echo "boom" >&2; exit 3 ;;
    falsefail) echo "has_work=false"; exit 3 ;;
    junk) echo "has_work=maybe" ;;
  esac
  exit 0
done
exit 0
STUB
# The runner stub's --list prints $STUB_LIST as [RUN ] lines plus the summary
# footer; STUB_LIST_MODE=fail (the default) exits 1, nofooter drops the footer.
# Every call's args go to $RST_LOG.
cat > "$PS/run-shell-tests.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${RST_LOG:-/dev/null}"
printf '%s\n' "${SUITE_TIER_MODE:-}" >> "${RST_TIER_LOG:-/dev/null}"
[ "${1:-}" = --list ] || exit 1
case "${STUB_LIST_MODE:-fail}" in fail) exit 1 ;; esac
[ -n "${STUB_LIST:-}" ] && sed 's/^/[RUN ] /' "$STUB_LIST"
[ "$STUB_LIST_MODE" = nofooter ] || printf '\n== Summary ==\n(--list: nothing executed)\n'
exit 0
STUB

run_ps() { STUB_ANSWERS="$1" STUB_LOG="$PS/log" bash "$PS/plan-shards.sh" "${@:2}" 2>/dev/null; }
check() { # check <label> <answers> <n> <want-shards> <want-absent> [<want-total>]
  local out
  out=$(run_ps "$2" "$3" .)
  if [ "$out" = "$(printf 'shards=%s\nabsent_shards=%s\nshard_total=%s' "$4" "$5" "${6:-$3}")" ]; then pass "$1"; else fail "$1: got [$out]"; fi
}

check "PS1 every shard has work" "1=true 2=true 3=true" 3 "[1,2,3]" ""
check "PS2 docs-only: no shard has work" "1=false 2=false 3=false" 3 "[]" "1 2 3"
check "PS3 some shards empty" "1=true 2=false 3=true 4=false" 4 "[1,3]" "2 4"
check "PS4 a failing and a silent probe stay listed" "1=fail 2=false 3=" 3 "[1,3]" "2"
check "PS4 a probe that prints has_work=false then fails stays listed" "1=falsefail 2=false" 2 "[1]" "2"
check "PS5 a garbage probe answer stays listed" "1=junk 2=false" 2 "[1]" "2"

if STUB_ANSWERS="" bash "$PS/plan-shards.sh" >/dev/null 2>&1; then rc=0; else rc=$?; fi
if [ "$rc" -eq 2 ]; then pass "PS6 no shard count is a usage error"; else fail "PS6 no n: rc $rc"; fi
if STUB_ANSWERS="" bash "$PS/plan-shards.sh" x . >/dev/null 2>&1; then rc=0; else rc=$?; fi
if [ "$rc" -eq 2 ]; then pass "PS6 non-numeric n is a usage error"; else fail "PS6 bad n: rc $rc"; fi

: > "$PS/log"
run_ps "1=true 2=true" 2 /some/root >/dev/null
if [ "$(sort "$PS/log")" = "$(printf '1/2|/some/root\n2/2|/some/root')" ]; then pass "PS7 each probe gets <k>/<n> and the root"; else fail "PS7: $(cat "$PS/log")"; fi

CI="$SRC_ROOT/.github/workflows/ci.yml"
if grep -q 'plan-shards.sh' "$CI" \
   && grep -q "shard: \${{ fromJSON(" "$CI" \
   && grep -q "shards != '\[\]'" "$CI"; then
  pass "PS8 ci.yml builds the shard matrix from the plan and skips an empty list"
else
  fail "PS8 ci.yml does not wire plan-shards.sh into the shard matrix"
fi
total_expr="\${{ needs.plan.outputs.shard_total || 8 }}"
if grep -qF "home-canary.sh --shard \${{ matrix.shard }}/$total_expr ." "$CI" \
   && grep -qF "SHARD_TOTAL: $total_expr" "$CI" \
   && grep -qF -- "--shards \"\$SHARD_TOTAL\"" "$CI" \
   && grep -qF "shard_total: \${{ steps.shards.outputs.shard_total }}" "$CI"; then
  pass "PS8 the shards and the aggregator take N from the plan, 8 without one"
else
  fail "PS8 ci.yml does not feed shard_total to the shard run and the aggregator verify"
fi

# PS14: the honeytoken-HOME leak check runs inside the shell-unit shards, so it
# is sized by the one shard plan: the shard run goes through home-canary.sh with
# the plan's shard total, no second matrix, no canary plan step, and the shard
# does not downgrade suite failures.
if grep -qF -- "run: bash scripts/ci/home-canary.sh --shard \${{ matrix.shard }}/\${{ needs.plan.outputs.shard_total || 8 }} ." "$CI" \
   && ! grep -qE '^  (fail-fast-)?home-canary:' "$CI" \
   && ! grep -qF "canary_shards" "$CI" \
   && ! grep -qF "canary_total" "$CI" \
   && ! grep -qF "HOME_CANARY_RUNNER_FAIL_OK" "$CI"; then
  pass "PS14 the shell-unit shards run through home-canary.sh on the plan's shard total, no second matrix"
else
  fail "PS14 ci.yml does not run the shards through home-canary.sh (or still has the home-canary matrix)"
fi

# PS14b: the host-file read-sink scan moved to ci-quick, a step of the
# unchecked-mktemp-range group (both scan the PR range for added code).
quick_block="$(awk '/^  ci-quick:/ { j = 1; next } j && /^  [A-Za-z0-9_-]+:[ ]*(#.*)?$/ { exit } j { print }' "$CI")"
sink_step="$(printf '%s\n' "$quick_block" | awk '/^      - id: unchecked-mktemp-range__read-sinks[ ]*$/ { s = 1; print; next } s && /^      - / { exit } s { print }')"
group_out="$(printf '%s\n' "$quick_block" | grep -F "steps.unchecked-mktemp-range__read-sinks.outcome")"
ps14b_ok=0
case "$sink_step" in
  *"continue-on-error"*) ;;
  *"if: \${{ !cancelled() && github.event_name == 'pull_request' }}"*"check-host-file-read-sinks.sh --range --merge-ref"*)
    [ -n "$group_out" ] && ps14b_ok=1 ;;
esac
if [ "$ps14b_ok" = 1 ]; then
  pass "PS14b check-host-file-read-sinks.sh gates through the unchecked-mktemp-range group in ci-quick"
else
  fail "PS14b check-host-file-read-sinks.sh is not a gating ci-quick step of the unchecked-mktemp-range group"
fi

# PS9: the committed ledger is per-suite timings from real main CI runs.
cp "$SRC_ROOT/scripts/ci/suite-durations.tsv" "$PS/real-ledger.tsv"
size() { # size <list file> <ledger> <n> [<mode>]
  STUB_LIST="$1" STUB_LIST_MODE="${4:-ok}" SUITE_DURATIONS="$2" STUB_ANSWERS="${STUB_ANSWERS:-}" \
    bash "$PS/plan-shards.sh" "$3" . 2>/dev/null
}
grep -v '^#' "$PS/real-ledger.tsv" | awk -F'\t' '$2 ~ /^[0-9]+$/ && $2 <= 20 { print $1 }' | head -5 > "$PS/small.list"
grep -v '^#' "$PS/real-ledger.tsv" | awk -F'\t' '$2 ~ /^[0-9]+$/ { print $1 }' > "$PS/all.list"
want=$(printf 'shards=[1]\nabsent_shards=\nshard_total=1')
out=$(size "$PS/small.list" "$PS/real-ledger.tsv" 8)
if [ "$(wc -l < "$PS/small.list")" -eq 5 ] && [ "$out" = "$want" ]; then pass "PS9 five short real suites take one shard"; else fail "PS9 small: got [$out]"; fi
# A full sweep (~15000 s) needs nearly every shard; it may drop one or two only
# because its longest suite (~2300 s) bounds the run at any N.
out=$(size "$PS/all.list" "$PS/real-ledger.tsv" 8)
t=$(printf '%s\n' "$out" | sed -n 's/^shard_total=//p')
case "$t" in 6|7|8) want=$(printf 'shards=[%s]\nabsent_shards=\nshard_total=%s' "$(seq -s, 1 "$t")" "$t") ;; *) want=x ;; esac
if [ "$out" = "$want" ]; then pass "PS9 every real ledger suite keeps 6-8 of 8 shards"; else fail "PS9 all: got [$out]"; fi

# PS10: costs 500 400 300 200 100 (sum 1500). LPT spans: N=1 1500, N=2 800,
# N=3 500 -> N=3 is the first within 600 s.
printf 'a\t500\nb\t400\nc\t300\nd\t200\ne\t100\n' > "$PS/hand.tsv"
printf 'a\nb\nc\nd\ne\n' > "$PS/hand.list"
want=$(printf 'shards=[1,2,3]\nabsent_shards=\nshard_total=3')
out=$(size "$PS/hand.list" "$PS/hand.tsv" 8)
if [ "$out" = "$want" ]; then pass "PS10 the smallest N within 600 s wins"; else fail "PS10 600 s: got [$out]"; fi
# n=2: the span at n (800) is over 600, so N=2 is the floor.
want=$(printf 'shards=[1,2]\nabsent_shards=\nshard_total=2')
out=$(size "$PS/hand.list" "$PS/hand.tsv" 2)
if [ "$out" = "$want" ]; then pass "PS10 a span over 600 s at n keeps n"; else fail "PS10 n=2: got [$out]"; fi
# x and y are not in the ledger and cost its median (300): spans N=1 700, N=2 400.
printf 'a\t500\nb\t300\nc\t100\n' > "$PS/med.tsv"
printf 'x\ny\nc\n' > "$PS/med.list"
want=$(printf 'shards=[1,2]\nabsent_shards=\nshard_total=2')
out=$(size "$PS/med.list" "$PS/med.tsv" 8)
if [ "$out" = "$want" ]; then pass "PS10 a suite absent from the ledger costs the median"; else fail "PS10 median: got [$out]"; fi

: > "$PS/empty.list"
want=$(printf 'shards=[]\nabsent_shards=1\nshard_total=1')
out=$(size "$PS/empty.list" "$PS/hand.tsv" 8)
if [ "$out" = "$want" ]; then pass "PS11 nothing selected starts no shard"; else fail "PS11: got [$out]"; fi

want=$(printf 'shards=[1,2]\nabsent_shards=\nshard_total=2')
out=$(STUB_ANSWERS="1=true 2=true" size "$PS/hand.list" "$PS/hand.tsv" 2 fail)
if [ "$out" = "$want" ]; then pass "PS12 a failed --list falls back to the probes at n"; else fail "PS12 fail: got [$out]"; fi
want=$(printf 'shards=[1,2,3]\nabsent_shards=\nshard_total=3')
out=$(size "$PS/small.list" "$PS/real-ledger.tsv" 3 nofooter)
if [ "$out" = "$want" ]; then pass "PS12 a --list without its footer falls back to the probes at n"; else fail "PS12 nofooter: got [$out]"; fi

: > "$PS/rst.log"
STUB_LIST="$PS/hand.list" STUB_LIST_MODE=ok SUITE_DURATIONS="$PS/hand.tsv" RST_LOG="$PS/rst.log" \
  bash "$PS/plan-shards.sh" 8 /some/root -- --impacted a..b >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$PS/rst.log")" = "--list --impacted a..b /some/root" ]; then pass "PS13 the --list gets the runner args and the root"; else fail "PS13: rc=$rc $(cat "$PS/rst.log")"; fi

# PS15: an empty or missing ledger gives no cost to size by; the probes at n run.
: > "$PS/empty.tsv"
want=$(printf 'shards=[1,2,3,4,5,6,7,8]\nabsent_shards=\nshard_total=8')
out=$(size "$PS/hand.list" "$PS/empty.tsv" 8)
if [ "$out" = "$want" ]; then pass "PS15 an empty ledger still runs the selection"; else fail "PS15 empty: got [$out]"; fi
out=$(size "$PS/hand.list" "$PS/no-such-ledger.tsv" 8)
if [ "$out" = "$want" ]; then pass "PS15 a missing ledger still runs the selection"; else fail "PS15 missing: got [$out]"; fi

# PS16: the root may be omitted before --; it defaults to .
: > "$PS/rst.log"
STUB_LIST="$PS/hand.list" STUB_LIST_MODE=ok SUITE_DURATIONS="$PS/hand.tsv" RST_LOG="$PS/rst.log" \
  bash "$PS/plan-shards.sh" 8 -- --impacted a..b >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$PS/rst.log")" = "--list --impacted a..b ." ]; then pass "PS16 an omitted root defaults to ."; else fail "PS16: rc=$rc $(cat "$PS/rst.log")"; fi

# PS17: the probe fallback asks about the same selection as the --list it replaces,
# so the runner args reach every probe after the shard and the root.
: > "$PS/args.log"
STUB_ARGS_LOG="$PS/args.log" STUB_ANSWERS="1=true 2=true" \
  bash "$PS/plan-shards.sh" 2 /some/root -- --impacted a..b >/dev/null 2>&1
if [ "$(sort "$PS/args.log")" = "$(printf '1/2 /some/root -- --impacted a..b\n2/2 /some/root -- --impacted a..b')" ]; then pass "PS17 each probe gets the runner args"; else fail "PS17: $(cat "$PS/args.log")"; fi
: > "$PS/args.log"
STUB_ARGS_LOG="$PS/args.log" STUB_ANSWERS="1=true 2=true" \
  bash "$PS/plan-shards.sh" 2 /some/root >/dev/null 2>&1
if [ "$(sort "$PS/args.log")" = "$(printf '1/2 /some/root\n2/2 /some/root')" ]; then pass "PS17 no runner args, none passed to the probes"; else fail "PS17 none: $(cat "$PS/args.log")"; fi

# PS18: the plan job's two plan-shards.sh calls take the cap from vars.CI_MAX_SHARDS
# and plan at 20 without it. The run bodies are lifted from ci.yml itself and run against
# a stub planner that logs its args; an unset repository variable reaches the step as
# the empty string.
step_dir="$PS/step"
mkdir -p "$step_dir/scripts/ci"
cat > "$step_dir/scripts/ci/plan-shards.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STEP_ARGS_LOG"
printf 'shards=[1]\nabsent_shards=\nshard_total=1\n'
STUB
run_plan_step() { # run_plan_step <step id> <CI_MAX_SHARDS value> -> the planner's args
  python3 -I - "$CI" "$1" "$step_dir/$1.run" <<'PY' || return 1
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
step = next(s for s in doc["jobs"]["plan"]["steps"] if s.get("id") == sys.argv[2])
if step["env"].get("CI_MAX_SHARDS") != "${{ vars.CI_MAX_SHARDS }}":
    sys.exit(1)
open(sys.argv[3], "w").write(step["run"])
PY
  : > "$step_dir/args.log"
  step_rc=0
  (cd "$step_dir" && RUNNER_TEMP="$step_dir" GITHUB_OUTPUT="$step_dir/gho" STEP_ARGS_LOG="$step_dir/args.log" \
     PR_BASE_SHA=abc PR_BASE_REF=main DEFAULT_BRANCH=main CI_MAX_SHARDS="$2" bash "$step_dir/$1.run" >/dev/null 2>&1) || step_rc=$?
  cat "$step_dir/args.log"
  return "$step_rc"
}
if got=$(run_plan_step shards "") && [ "$got" = "20 ." ]; then pass "PS18 shards: variable empty plans at 20"; else fail "PS18 shards empty: got [$got]"; fi
if got=$(run_plan_step shards 8) && [ "$got" = "8 ." ]; then pass "PS18 shards: variable 8 plans at 8"; else fail "PS18 shards 8: got [$got]"; fi

# PS19: a plan at 16 lists at most 16 shards and shard_total is 16.
check "PS19 a 16-shard plan lists all 16" "1=true 2=true 3=true 4=true 5=true 6=true 7=true 8=true 9=true 10=true 11=true 12=true 13=true 14=true 15=true 16=true" 16 "[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16]" ""

# PS20: CI_MAX_SHARDS above 64 is clamped to 64 (a typo of 500 must not plan 500 jobs;
# 64 is a quarter of GitHub's 256-job limit for one matrix) and the message names the
# variable.
shard_total_of() { printf '%s\n' "$1" | sed -n 's/^shard_total=//p'; }
out=$(STUB_ANSWERS="" bash "$PS/plan-shards.sh" 500 . 2>"$PS/clamp.err")
if [ "$(shard_total_of "$out")" = 64 ]; then pass "PS20 n=500 plans 64 shards"; else fail "PS20 n=500: got [$(shard_total_of "$out")]"; fi
if grep -q 'CI_MAX_SHARDS' "$PS/clamp.err"; then pass "PS20 the clamp message names CI_MAX_SHARDS"; else fail "PS20 clamp message: [$(cat "$PS/clamp.err")]"; fi
out=$(STUB_ANSWERS="" bash "$PS/plan-shards.sh" 64 . 2>"$PS/clamp.err")
if [ "$(shard_total_of "$out")" = 64 ] && [ ! -s "$PS/clamp.err" ]; then pass "PS20 n=64 is the cap itself, not clamped"; else fail "PS20 n=64: [$(shard_total_of "$out")] [$(cat "$PS/clamp.err")]"; fi

# The same through ci.yml's own shards step body, lifted from the workflow and run
# against the real planner beside the stubs, as the plan job runs it.
real_dir="$PS/real"
mkdir -p "$real_dir/scripts/ci"
cp "$PS/plan-shards.sh" "$PS/shard-has-work.sh" "$PS/run-shell-tests.sh" "$real_dir/scripts/ci/"
run_real_step() { # run_real_step <CI_MAX_SHARDS value> -> the step's shard_total value ('' if none)
  python3 -I - "$CI" "$real_dir/shards.run" <<'PY' || return 1
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
step = next(s for s in doc["jobs"]["plan"]["steps"] if s.get("id") == "shards")
open(sys.argv[2], "w").write(step["run"])
PY
  : > "$real_dir/gho"
  step_rc=0
  (cd "$real_dir" && RUNNER_TEMP="$real_dir" GITHUB_OUTPUT="$real_dir/gho" STUB_ANSWERS="" \
     PR_BASE_SHA=abc PR_BASE_REF=main DEFAULT_BRANCH=main CI_MAX_SHARDS="$1" bash "$real_dir/shards.run" >/dev/null 2>&1) || step_rc=$?
  echo "$step_rc" > "$real_dir/step.rc"
  sed -n 's/^shard_total=//p' "$real_dir/gho"
  return "$step_rc"
}
if got=$(run_real_step 500) && [ "$got" = 64 ]; then pass "PS20 ci.yml's plan step with CI_MAX_SHARDS=500 plans 64"; else fail "PS20 plan step 500: got [$got]"; fi

# PS22: ci.yml's own plan step, empty variable, real planner and the real ledger (suites
# timed on green main CI runs): a full sweep plans 20 shards, the first N whose longest
# shard is the longest single suite.
if got=$(STUB_LIST="$PS/all.list" STUB_LIST_MODE=ok SUITE_DURATIONS="$PS/real-ledger.tsv" run_real_step "") && [ "$got" = 20 ]; then pass "PS22 an empty CI_MAX_SHARDS plans a full real-ledger sweep at 20"; else fail "PS22 empty full sweep: got [$got]"; fi

# PS23: the plan sizes the selection the shards run, so its --list carries their PR tier.
: > "$PS/tier.log"
STUB_LIST="$PS/small.list" STUB_LIST_MODE=ok SUITE_DURATIONS="$PS/real-ledger.tsv" RST_TIER_LOG="$PS/tier.log" run_real_step "" >/dev/null
if [ "$(sort -u "$PS/tier.log")" = pr ]; then pass "PS23 the plan step lists under SUITE_TIER_MODE=pr"; else fail "PS23 plan step tier: got [$(cat "$PS/tier.log")]"; fi

# PS21: 0 and a negative value are refused (rc 2, message names CI_MAX_SHARDS); the plan
# step swallows the refusal into an empty output, which the shard job reads as 8 legs.
for bad in 0 -3; do
  if STUB_ANSWERS="" bash "$PS/plan-shards.sh" "$bad" . >"$PS/bad.out" 2>"$PS/bad.err"; then rc=0; else rc=$?; fi
  if [ "$rc" -eq 2 ] && [ ! -s "$PS/bad.out" ]; then pass "PS21 n=$bad is a usage error with no plan"; else fail "PS21 n=$bad: rc $rc [$(cat "$PS/bad.out")]"; fi
  if grep -q 'CI_MAX_SHARDS' "$PS/bad.err"; then pass "PS21 n=$bad message names CI_MAX_SHARDS"; else fail "PS21 n=$bad message: [$(cat "$PS/bad.err")]"; fi
  got=$(run_real_step "$bad")
  if [ -z "$got" ] && [ "$(cat "$real_dir/step.rc")" = 0 ]; then pass "PS21 plan step with CI_MAX_SHARDS=$bad succeeds and leaves no shard_total (8 legs)"; else fail "PS21 plan step $bad: got [$got] rc $(cat "$real_dir/step.rc")"; fi
done

rst_tally
