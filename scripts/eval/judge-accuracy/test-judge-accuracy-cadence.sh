#!/usr/bin/env bash
# scripts/eval/judge-accuracy/test-judge-accuracy-cadence.sh - suite for the weekly judge-accuracy cadence
# (judge-accuracy-cadence.sh): arm/status/disarm against a stub crontab, and one pass against a stub gh,
# a fixture verdict bucket and a scratch ledger. Never the real crontab, gh, ledger or page; no model call.
# shellcheck disable=SC2016,SC2034
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
CAD="$HERE/judge-accuracy-cadence.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/judge-accuracy-cadence-test.XXXXXX")" || { echo "test-judge-accuracy-cadence: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export HIMMEL_EVAL_RUNS_LEDGER="$TMP/runs.jsonl"
export HIMMEL_EVAL_CHANGES_LEDGER="$TMP/changes.jsonl"
export HIMMEL_JUDGE_ADJUDICATION="$TMP/queue.jsonl"
export REVIEW_PAGE_FILE="$TMP/page/review-page.md"
export CADENCE_ALERT_FILE="$TMP/alerts.log" CADENCE_ALERT_DEDUPE_DIR="$TMP/alert-sent" CADENCE_ALERT_SEND_CMD="$TMP/stub/notify" CADENCE_ALERT_SEND_FAILED_MARK="$TMP/alert-send-failed"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP test-judge-accuracy-cadence: python3 not on PATH"; exit 0; }

STUB="$TMP/stub"; mkdir -p "$STUB"
printf '#!/usr/bin/env bash\nexit 0\n' >"$STUB/notify"; chmod +x "$STUB/notify"
CR="$TMP/cron"; mkdir -p "$CR"
cat >"$STUB/crontab" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "-l" ]; then [ -f "$CR/tab" ] && { cat "$CR/tab"; exit 0; }; echo "no crontab for test" >&2; exit 1; fi
cat >"$CR/tab"
EOF
chmod +x "$STUB/crontab"
export JUDGEACC_CRONTAB="$STUB/crontab" JUDGEACC_RUNNER_DIR="$TMP/runner"

# a verdict bucket with one judge GO on a PR that merged at its head, two days ago
AT="$(date -u -d '2 days ago' +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$TMP/v/q1" "$TMP/mirror"
printf '# VERDICT q1\n\nwritten-at: %s\npr: 201\nmodel: opus\neffort: high\n\n**GO** for head `aaa1`.\n\nclass: none\n' "$AT" >"$TMP/v/q1/judge.md"
cat >"$STUB/gh" <<EOF
#!/usr/bin/env bash
[ -f "$TMP/gh-fail" ] && exit 1
case "\$*" in
  *"pr list"*) echo '[{"number":201,"state":"MERGED","mergedAt":"$AT","headRefOid":"aaa1","mergeCommit":{"oid":"m201"}}]' ;;
  *"run list"*) echo '[]' ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$STUB/gh"
export JUDGEACC_GH="$STUB/gh"

[ -f "$CAD" ] || { fail "judge-accuracy-cadence.sh is present"; echo "judge-accuracy-cadence: $PASS passed, $FAIL failed"; exit 1; }

# --- the cadence verbs -------------------------------------------------------------------------------
bash "$CAD" arm --verdicts "$TMP/v" --dry-run >"$TMP/dry.out" 2>&1
check "arm --dry-run writes nothing" '[ ! -f "$CR/tab" ] && grep -q "DRY judge-accuracy-cadence" "$TMP/dry.out"'
bash "$CAD" arm --verdicts "$TMP/v" --day 2 --time 07:30 >"$TMP/arm.out" 2>&1
check "arm installs one weekly entry on the chosen day" '[ "$(grep -c "# HIMMEL-JudgeAccuracy" "$CR/tab")" = 1 ] && grep -q "^30 07 \* \* 2 " "$CR/tab"'
check "the runner bakes the verdict dir" 'grep -qF -- "--verdicts $TMP/v" "$TMP/runner/judge-accuracy-cadence.sh"'
bash "$CAD" arm --verdicts "$TMP/v" >/dev/null 2>&1; rc=$?
check "a second arm without --force refuses (rc 3)" '[ "$rc" = 3 ]'
bash "$CAD" arm --verdicts "$TMP/nope" --force >/dev/null 2>&1; rc=$?
check "arm refuses a missing verdict dir" '[ "$rc" = 1 ]'
bash "$CAD" arm --verdicts "$TMP/v" --day 9 --force >/dev/null 2>&1; rc=$?
check "arm refuses a day outside 0-6" '[ "$rc" = 1 ]'
check "status shows it armed" 'bash "$CAD" status | grep -q "^ARMED .*HIMMEL-JudgeAccuracy"'

# --- one pass ----------------------------------------------------------------------------------------
bash "$CAD" run --verdicts "$TMP/v" --mirror "$TMP/mirror" >"$TMP/run.out" 2>&1; rc=$?
check "run: exit 0" '[ "$rc" = 0 ]'
check "run: one judge-accuracy row in the ledger" '[ "$(grep -c "\"eval\":\"judge-accuracy\"" "$HIMMEL_EVAL_RUNS_LEDGER")" = 1 ]'
check "run: the page is written and names the judges" 'grep -q "^## The judges" "$REVIEW_PAGE_FILE" && grep -q "A bug got past a GO on 0 of 1 merged PRs" "$REVIEW_PAGE_FILE"'
touch "$TMP/gh-fail"
bash "$CAD" run --verdicts "$TMP/v" --mirror "$TMP/mirror" >"$TMP/run2.out" 2>&1; rc=$?
rm -f "$TMP/gh-fail"
check "run: a failing gh is a non-zero exit, no second row, an alert raised" '[ "$rc" != 0 ] && [ "$(grep -c "\"eval\":\"judge-accuracy\"" "$HIMMEL_EVAL_RUNS_LEDGER")" = 1 ] && grep -q "judge-accuracy" "$CADENCE_ALERT_FILE"'

bash "$CAD" disarm >/dev/null 2>&1
check "disarm removes the entry and the runner" '! grep -q "HIMMEL-JudgeAccuracy" "$CR/tab" && [ ! -f "$TMP/runner/judge-accuracy-cadence.sh" ]'

echo "judge-accuracy-cadence: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
