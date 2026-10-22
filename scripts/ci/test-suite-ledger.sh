#!/usr/bin/env bash
# scripts/ci/test-suite-ledger.sh — the local suite-result ledger.
#
# quiet-run.sh (label `suite`) and run-shell-tests.sh append one JSON row per
# suite run to the ledger (default ~/.himmel/state/suite-runs.jsonl) with
# ts, suite, head, rc, sec, station; suite-runs-summary.sh --days N prints
# per-suite red counts. Every case points HIMMEL_SUITE_LEDGER at a temp file:
# the real ledger is never written.
#
#   L1  quiet-run: one row per suite run, all six fields, rc/ok output kept
#   L2  quiet-run: a failing suite keeps its exit code and logs rc != 0
#   L3  quiet-run: a missing ledger directory is created
#   L4  quiet-run: an unwritable ledger never changes the suite's exit code
#   L5  quiet-run: a fixture-marked run without an override writes no row
#   L6  run-shell-tests: one row per suite, rc of a failing suite recorded
#   L7  suite-runs-summary.sh: per-suite red counts inside --days, old rows out
#
# Platform guard: bash-only, no .ps1 twin; runs under Git Bash and Linux.
#
# Usage: bash scripts/ci/test-suite-ledger.sh
#
# Exit codes: 0 — all cases passed; 1 — at least one failed.
set -uo pipefail

# shellcheck source=run-shell-tests-fixture.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/run-shell-tests-fixture.sh"

SRC_ROOT="$(cd "$RST_FIXTURE_DIR/../.." && pwd)"
QUIET_RUN="$SRC_ROOT/scripts/quiet-run.sh"
SUMMARY="$SRC_ROOT/scripts/ci/suite-runs-summary.sh"

WORK="$(mktemp -d "$SRC_ROOT/.suite-ledger-fixture.XXXXXX")" || exit 1
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/himmel-suite-ledger.XXXXXX")" || exit 1
trap 'rm -rf "$WORK" "$SANDBOX" "$SUITE_LOCK_SANDBOX"' EXIT

printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/test-green.sh"
printf '#!/usr/bin/env bash\nexit 7\n' > "$WORK/test-red.sh"
REL="${WORK#"$SRC_ROOT"/}"

# --- L1. one row per suite run, six fields ------------------------------------
LEDGER="$SANDBOX/l1/suite-runs.jsonl"
out=$(cd "$SRC_ROOT" && env -u HIMMEL_TEST_FIXTURE HIMMEL_SUITE_LEDGER="$LEDGER" bash "$QUIET_RUN" suite -- bash "$REL/test-green.sh" 2>&1); rc=$?
rows=0; [ -f "$LEDGER" ] && rows=$(grep -c '' "$LEDGER")
row=""; [ -f "$LEDGER" ] && row=$(head -n 1 "$LEDGER")
want_head=$(git -C "$SRC_ROOT" rev-parse HEAD)
if [ "$rc" -eq 0 ] && [ "$rows" -eq 1 ] \
  && grepq "$row" '"ts":"[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]T' \
  && grepq "$row" "\"suite\":\"$REL/test-green.sh\"" \
  && grepq "$row" "\"head\":\"$want_head\"" \
  && grepq "$row" '"rc":0' \
  && grepq "$row" '"sec":[0-9]' \
  && grepq "$row" '"station":"[^"]'; then
  pass "L1: one suite run -> one row with ts, suite, head, rc, sec, station (rc 0)"
else
  fail "L1: rc=$rc rows=$rows row=$row out=$out"
fi

# --- L2. a red suite keeps its exit code and logs it --------------------------
LEDGER="$SANDBOX/l2/suite-runs.jsonl"
out=$(cd "$SRC_ROOT" && env -u HIMMEL_TEST_FIXTURE HIMMEL_SUITE_LEDGER="$LEDGER" bash "$QUIET_RUN" suite -- bash "$REL/test-red.sh" 2>&1); rc=$?
row=""; [ -f "$LEDGER" ] && row=$(head -n 1 "$LEDGER")
if [ "$rc" -eq 7 ] && grepq "$row" '"rc":7' && grepq "$row" "test-red.sh"; then
  pass "L2: red suite -> exit 7 unchanged, row records rc 7"
else
  fail "L2: rc=$rc row=$row out=$out"
fi

# --- L3. a missing ledger directory is created --------------------------------
LEDGER="$SANDBOX/does/not/exist/yet/suite-runs.jsonl"
(cd "$SRC_ROOT" && env -u HIMMEL_TEST_FIXTURE HIMMEL_SUITE_LEDGER="$LEDGER" bash "$QUIET_RUN" suite -- bash "$REL/test-green.sh" >/dev/null 2>&1)
if [ -s "$LEDGER" ]; then
  pass "L3: missing ledger directory created"
else
  fail "L3: no ledger at $LEDGER"
fi

# --- L4. an unwritable ledger never changes the exit code ----------------------
: > "$SANDBOX/a-file"
out=$(cd "$SRC_ROOT" && env -u HIMMEL_TEST_FIXTURE HIMMEL_SUITE_LEDGER="$SANDBOX/a-file/sub/suite-runs.jsonl" bash "$QUIET_RUN" suite -- bash "$REL/test-green.sh" 2>&1); rc=$?
outr=$(cd "$SRC_ROOT" && env -u HIMMEL_TEST_FIXTURE HIMMEL_SUITE_LEDGER="$SANDBOX/a-file/sub/suite-runs.jsonl" bash "$QUIET_RUN" suite -- bash "$REL/test-red.sh" 2>&1); rcr=$?
if [ "$rc" -eq 0 ] && [ "$rcr" -eq 7 ]; then
  pass "L4: unwritable ledger -> green stays 0, red stays 7"
else
  fail "L4: rc=$rc rcr=$rcr out=$out $outr"
fi

# --- L5. a fixture-marked run with no override writes nothing ------------------
FAKEHOME="$SANDBOX/home5"; mkdir -p "$FAKEHOME"
(cd "$SRC_ROOT" && env -u HIMMEL_SUITE_LEDGER HOME="$FAKEHOME" HIMMEL_TEST_FIXTURE=1 bash "$QUIET_RUN" suite -- bash "$REL/test-green.sh" >/dev/null 2>&1)
if [ ! -e "$FAKEHOME/.himmel/state/suite-runs.jsonl" ]; then
  pass "L5: HIMMEL_TEST_FIXTURE=1 without an override writes no row"
else
  fail "L5: a fixture-marked run wrote $FAKEHOME/.himmel/state/suite-runs.jsonl"
fi
# the default path is HOME-relative and created on demand
(cd "$SRC_ROOT" && env -u HIMMEL_SUITE_LEDGER -u HIMMEL_TEST_FIXTURE HOME="$FAKEHOME" bash "$QUIET_RUN" suite -- bash "$REL/test-green.sh" >/dev/null 2>&1)
if [ -s "$FAKEHOME/.himmel/state/suite-runs.jsonl" ]; then
  pass "L5: default path \$HOME/.himmel/state/suite-runs.jsonl created on demand"
else
  fail "L5: default ledger missing under $FAKEHOME"
fi

# --- L6. run-shell-tests: one row per suite -----------------------------------
LEDGER="$SANDBOX/l6/suite-runs.jsonl"
SCANDIR="$SANDBOX/scan6"; mkdir -p "$SCANDIR"
cp "$WORK/test-green.sh" "$SCANDIR/test-a-green.sh"
cp "$WORK/test-red.sh" "$SCANDIR/test-b-red.sh"
out=$(cd "$SRC_ROOT" && env -u SUITE_TIER_MODE -u HIMMEL_TEST_FIXTURE HIMMEL_SUITE_LEDGER="$LEDGER" bash "$RUNNER" "$SCANDIR" 2>&1); rc=$?
rows=0; [ -f "$LEDGER" ] && rows=$(grep -c '' "$LEDGER")
content=""; [ -f "$LEDGER" ] && content=$(cat "$LEDGER")
if [ "$rc" -eq 1 ] && [ "$rows" -eq 2 ] \
  && grepq "$content" 'test-a-green\.sh.*"rc":0' \
  && grepq "$content" 'test-b-red\.sh.*"rc":7' \
  && grepq "$content" '"head":"'"$want_head"'"'; then
  pass "L6: run-shell-tests -> one row per suite (green rc 0, red rc 7), run rc 1 unchanged"
else
  fail "L6: rc=$rc rows=$rows content=$content out=$out"
fi

# --- L7. summary: per-suite red counts over --days -----------------------------
LEDGER="$SANDBOX/l7.jsonl"
today=$(date -u +%Y-%m-%dT%H:%M:%SZ)
old=$(date -u -d '30 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-30d +%Y-%m-%dT%H:%M:%SZ)
{
  printf '{"ts":"%s","suite":"s/test-flaky.sh","head":"h","rc":1,"sec":3,"station":"x"}\n' "$today"
  printf '{"ts":"%s","suite":"s/test-flaky.sh","head":"h","rc":0,"sec":3,"station":"x"}\n' "$today"
  printf '{"ts":"%s","suite":"s/test-flaky.sh","head":"h","rc":2,"sec":3,"station":"x"}\n' "$today"
  printf '{"ts":"%s","suite":"s/test-old.sh","head":"h","rc":1,"sec":3,"station":"x"}\n' "$old"
  printf '{"ts":"%s","suite":"s/test-clean.sh","head":"h","rc":0,"sec":3,"station":"x"}\n' "$today"
} > "$LEDGER"
out=$(HIMMEL_SUITE_LEDGER="$LEDGER" bash "$SUMMARY" --days 7 2>&1); rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" 'test-flaky\.sh' && grepq "$out" '2.*test-flaky\.sh\|test-flaky\.sh.*2' \
  && ! grepq "$out" 'test-old\.sh' && ! grepq "$out" 'test-clean\.sh'; then
  pass "L7: --days 7 -> flaky suite red 2 of 3 runs; old and all-green suites absent"
else
  fail "L7: rc=$rc out=$out"
fi
out=$(HIMMEL_SUITE_LEDGER="$LEDGER" bash "$SUMMARY" --days 90 2>&1)
if grepq "$out" 'test-old\.sh'; then
  pass "L7: --days 90 includes the 30-day-old red row"
else
  fail "L7: --days 90 out=$out"
fi
out=$(HIMMEL_SUITE_LEDGER="$SANDBOX/absent.jsonl" bash "$SUMMARY" --days 7 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
  pass "L7: an absent ledger is an empty report, rc 0"
else
  fail "L7: absent ledger rc=$rc out=$out"
fi

rst_tally
