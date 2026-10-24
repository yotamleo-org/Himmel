#!/usr/bin/env bash
# selector: tree-scan
# scripts/eval/leg-digest/test-failure-review.sh - hermetic suite for the daily failure review.
# Scratch ledger, state, out dir, vault, a stub Jira, a stub notifier and a stub crontab only; never ~/.himmel,
# never a real Jira write, never a real Telegram send, never the real crontab. No model call.
#  1. a zero-failure day writes "no failures" and sends nothing;
#  2. the default run is the router's dry-run: no Jira call, no router state or log;
#  3. --live routes through the router: one ticket filed through the stub, one Telegram line;
#  4. a capped day says so (live and dry-run);
#  5. the two unreliable trajectory signals never reach the digest;
#  6. new vs recurring classes; a quiet day (no new class, nothing routed) sends nothing;
#  7. the daily-note section is upserted, never duplicated;
#  8. the cadence: arm/status/disarm against a stub crontab, dry-run by default, --live baked only on request,
#     and a SKIPPED-BANK preflight skips the run;
#  9. delivery is persisted: a failed line is retried by the next run, a delivered one is not repeated.
#
# check() evals its condition, so the single quotes are deliberate.
# shellcheck disable=SC2016,SC2034  # check() evals single-quoted asserts that read these vars
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/../../lib/portable-timeout.sh"
FRV="$HERE/failure_review.py"
CAD="$HERE/failure-review-cadence.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/failure-review-test.XXXXXX")" || { echo "test-failure-review: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export TZ=UTC
# Never the live files, whatever a case forgets to pass.
export HIMMEL_WORKER_SESSION_FAILURES_LEDGER="$TMP/never-ledger.jsonl"
export HIMMEL_FAILURE_ROUTES_LOG="$TMP/never-log.jsonl"
export HIMMEL_FAILURE_ROUTES_STATE="$TMP/never-state.json"
export HIMMEL_FAILURE_INBOX="$TMP/never-inbox.md"
export HIMMEL_FAILURE_REVIEW_DIR="$TMP/never-review"
export HIMMEL_EVAL_RUNS_LEDGER="$TMP/never-runs.jsonl"
export HIMMEL_EVAL_CHANGES_LEDGER="$TMP/never-changes.jsonl"
export FAILURE_REVIEW_NOTIFY_CMD="$TMP/stub/notify"
# The friction subsection reads the real session transcripts; off unless a case sets a stub.
export FAILURE_REVIEW_FRICTION_CMD=""
# The router fails closed without a project key; the suite names one, the no-key cases unset it.
export JIRA_PROJECT_KEY=HIMMEL
export CADENCE_ALERT_FILE="$TMP/cadence-alerts.log" CADENCE_ALERT_DEDUPE_DIR="$TMP/alert-sent" CADENCE_ALERT_SEND_CMD="$TMP/stub/notify" CADENCE_ALERT_SEND_FAILED_MARK="$TMP/alert-send-failed"
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
# Every call that takes the notify lock runs under this bound, so a lock regression (a self-deadlock)
# fails the suite with a message instead of hanging it. Measured: the whole suite runs in ~2 s, so no single call
# takes more than a second; 30 s is well above any loaded run.
BOUND=30
exec 3>&1
# fd 3 is the suite's own stdout: review() runs with its output redirected, and the message must still show.
hung() { if [ "$1" = 124 ]; then FAIL=$((FAIL + 1)); echo "  FAIL $2 hit the ${BOUND}s bound (rc 124): the notify lock is held or deadlocked" >&3; fi; }
NOW=2026-10-07T12:00:00Z
DAY=2026-10-07

STUB="$TMP/stub"; mkdir -p "$STUB"
cat >"$STUB/jira" <<'EOF'
#!/usr/bin/env bash
d="$(dirname "$0")"
printf '%s\n' "$*" >>"$d/calls.log"
op="$1"; shift
case "$op" in
  list) [ -f "$d/list.fail" ] && { cat "$d/list.fail" >&2; exit 1; }; cat "$d/list.out" 2>/dev/null; exit 0 ;;
  create) n=$(( $(cat "$d/n" 2>/dev/null || echo 9000) + 1 )); echo "$n" >"$d/n"; echo "Created HIMMEL-$n" ;;
  comment) echo "Comment added to $1" ;;
  *) exit 9 ;;
esac
EOF
cat >"$STUB/notify" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$(dirname "$0")/notify.log"
EOF
cat >"$STUB/route-notify" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$(dirname "$0")/route-notify.log"
EOF
chmod +x "$STUB/jira" "$STUB/notify" "$STUB/route-notify"
# The router's console line and INTAKE request: never the real notifier.
export FAILURE_ROUTER_NOTIFY_CMD="$STUB/route-notify"
calls() { if [ -f "$STUB/calls.log" ]; then grep -c "^$1 " "$STUB/calls.log"; else echo 0; fi; }
sends() { if [ -f "$STUB/notify.log" ]; then grep -c . "$STUB/notify.log"; else echo 0; fi; }

# row <ledger> <leg> <class> [identical_retry] [ts]
SEQ=0
row() {
  SEQ=$((SEQ + 1))
  jq -nc --arg leg "$2" --arg cls "$3" --argjson ir "${4:-0}" --arg ts "${5:-2026-10-07T08:00:00Z}" \
    --arg sid "$(printf '4713c1a5-0000-4000-8000-%012d' "$SEQ")" '
    {v:1, ts:$ts, host:"h", source:"scripts/eval/leg-digest/leg_ledger.py", kind:"leg-failure", session:$sid,
     leg:$leg, console:"c", ticket:"HIMMEL-4713", pr:2030, agent:{id:"main", role:"leg", kind:"k", model:"claude-opus-5-5"},
     class:$cls, failure:($cls | split("/")[0]), count:1, identical_retry:$ir, recovered:false,
     first_ts:1, last_ts:2, tool_call_ids:["t"]}' >>"$1"
}
# review <case dir> [args...]: one run with every path inside the case dir.
review() {
  local d="$1"; shift
  timeout "$BOUND" python3 "$FRV" --ledger "$d/ledger.jsonl" --state "$d/state.json" --log "$d/log.jsonl" --inbox "$d/inbox.md" \
    --out-dir "$d/out" --now "$NOW" --jira-bin "$STUB/jira" "$@"
  local rc=$?
  hung "$rc" "review $(basename "$d")"
  return "$rc"
}
digest() { cat "$1/out/failure-review-$DAY.md" 2>/dev/null; }

echo "0. RED guard: the review and its cadence exist"
check "failure_review.py is present" '[ -f "$FRV" ]'
check "failure-review-cadence.sh is present" '[ -f "$CAD" ]'

echo "1. a zero-failure day writes \"no failures\" and sends nothing"
C1="$TMP/c1"; mkdir -p "$C1"; : >"$C1/ledger.jsonl"
row "$C1/ledger.jsonl" N100 denied/guard-x 1 2026-10-01T08:00:00Z
review "$C1" >"$C1/run.out" 2>&1 || bad "review exits 0 on a zero-failure day: $(head -c 300 "$C1/run.out")"
check "the digest is written for the day" '[ -f "$C1/out/failure-review-$DAY.md" ]'
check "it says no failures" 'digest "$C1" | grep -q "no failures in the last 24 h"'
check "nothing is sent" '[ "$(sends)" = 0 ]'
check "no Jira call" '[ "$(calls list)" = 0 ] && [ "$(calls create)" = 0 ]'

echo "2. the default run is the router's dry-run"
C2="$TMP/c2"; mkdir -p "$C2"
row "$C2/ledger.jsonl" N100 denied/guard-pr-check-literal 1
row "$C2/ledger.jsonl" N200 denied/guard-pr-check-literal 2
review "$C2" >"$C2/run.out" 2>&1 || bad "dry-run review exits 0: $(head -c 300 "$C2/run.out")"
check "no Jira call at all, the search included" '[ ! -f "$STUB/calls.log" ]'
check "no router state, log or inbox written" '[ ! -e "$C2/state.json" ] && [ ! -e "$C2/log.jsonl" ] && [ ! -e "$C2/inbox.md" ]'
check "the digest names the mode dry-run" 'digest "$C2" | grep -q "mode: dry-run"'
check "the digest shows the would-be routing" 'digest "$C2" | grep -q "would-file denied/guard-pr-check-literal"'
check "the top classes list the class with its legs" 'digest "$C2" | grep -q "denied/guard-pr-check-literal: 2 rows, legs N100, N200"'
check "the header names the 24 h window and the routing names the 14 d one" 'digest "$C2" | grep -q "^- window: .* (24 h), mode: dry-run" && digest "$C2" | grep -q "would-file denied/guard-pr-check-literal (legs 2 in 14 d)"'

echo "HIMMEL-7354: a live search error is said with its cause in the digest"
C3e="$TMP/c3e"; mkdir -p "$C3e"; cp "$C2/ledger.jsonl" "$C3e/ledger.jsonl"
echo "JIRA_BASE_URL is not set" >"$STUB/list.fail"
review "$C3e" --live >"$C3e/run.out" 2>&1
rc3e=$?
rm -f "$STUB/list.fail"
dig3e="$(digest "$C3e")"
check "the digest names the search error and its cause once" '[ "$rc3e" -eq 0 ] && grep -q "^- skipped, search-error: JIRA_BASE_URL is not set: denied/guard-pr-check-literal$" <<<"$dig3e"'

echo "3. --live routes through the router and sends one line"
C3="$TMP/c3"; mkdir -p "$C3"; cp "$C2/ledger.jsonl" "$C3/ledger.jsonl"
s0="$(sends)"
review "$C3" --live >"$C3/run.out" 2>&1 || bad "live review exits 0: $(head -c 300 "$C3/run.out")"
check "exactly one create through the stub" '[ "$(calls create)" = 1 ]'
check "the digest says what was filed" 'digest "$C3" | grep -q "filed denied/guard-pr-check-literal HIMMEL-9001"'
check "the digest names the mode live" 'digest "$C3" | grep -q "mode: live"'
check "one Telegram line, naming the routing" '[ "$(sends)" = "$((s0 + 1))" ] && tail -n 1 "$STUB/notify.log" | grep -q "1 ticket filed"'
check "the line is one line" '[ "$(tail -n 1 "$STUB/notify.log" | wc -l)" = 1 ]'
check "a class the router just filed is triaged, not filed again" 'tail -n 1 "$STUB/notify.log" | grep -q "Do: open the digest and triage what the router filed" && ! tail -n 1 "$STUB/notify.log" | grep -q "file a ticket"'
review "$C3" --live >/dev/null 2>&1
check "a rerun routes nothing new: no second ticket, routed none" '[ "$(calls create)" = 1 ] && digest "$C3" | grep -q "routed: none"'

C3k="$TMP/c3k"; mkdir -p "$C3k"; cp "$C2/ledger.jsonl" "$C3k/ledger.jsonl"
n3="$(calls create)"
env -u JIRA_PROJECT_KEY timeout "$BOUND" python3 "$FRV" --ledger "$C3k/ledger.jsonl" --state "$C3k/state.json" --log "$C3k/log.jsonl" --inbox "$C3k/inbox.md" \
  --out-dir "$C3k/out" --now "$NOW" --jira-bin "$STUB/jira" --live >"$C3k/run.out" 2>&1; rc=$?
hung "$rc" "review c3k"
check "a live review with no JIRA_PROJECT_KEY fails closed and says the key is missing" '[ "$rc" = 1 ] && grep -q "JIRA_PROJECT_KEY is required" "$C3k/run.out" && digest "$C3k" | grep -q "router: failed" && [ "$(calls create)" = "$n3" ]'

echo "4. a capped day says so"
C4="$TMP/c4"; mkdir -p "$C4"; cp "$C2/ledger.jsonl" "$C4/ledger.jsonl"
printf '{"v":1,"classes":{},"created":{"day":"%s","n":3}}\n' "$DAY" >"$C4/state.json"
review "$C4" --live >"$C4/run.out" 2>&1 || bad "capped live review exits 0"
check "live: nothing filed, the digest says capped" '[ "$(calls create)" = 1 ] && digest "$C4" | grep -q "capped: the daily create cap was hit; waiting: denied/guard-pr-check-literal"'
C4b="$TMP/c4b"; mkdir -p "$C4b"; cp "$C2/ledger.jsonl" "$C4b/ledger.jsonl"
printf '{"v":1,"classes":{},"created":{"day":"%s","n":3}}\n' "$DAY" >"$C4b/state.json"
review "$C4b" >/dev/null 2>&1
check "dry-run: the digest says capped too" 'digest "$C4b" | grep -q "capped: the daily create cap was hit"'
check "an uncapped day says none capped" 'digest "$C2" | grep -q "capped: none"'
# a class that already has a ticket would be commented on, not filed: the "would be" count is tickets only.
C4c="$TMP/c4c"; mkdir -p "$C4c"; cp "$C2/ledger.jsonl" "$C4c/ledger.jsonl"
printf '{"v":1,"classes":{"denied/guard-pr-check-literal":{"ticket":"HIMMEL-9100"}},"created":{}}\n' >"$C4c/state.json"
review "$C4c" >/dev/null 2>&1
check "a would-comment decision is not counted as a ticket that would be filed" 'digest "$C4c" | grep -q "would-comment denied/guard-pr-check-literal" && tail -n 1 "$STUB/notify.log" | grep -q "dry run, nothing filed (0 would be)"'
# live, but the class already has a ticket: the router comments, files nothing, and the step is not "triage what it filed".
C4d="$TMP/c4d"; mkdir -p "$C4d"; cp "$C2/ledger.jsonl" "$C4d/ledger.jsonl"
cp "$C4c/state.json" "$C4d/state.json"
s4="$(sends)"
printf 'HIMMEL-9100\tTask\tOpen\tsome summary\n' >"$STUB/list.out"
review "$C4d" --live >"$C4d/run.out" 2>&1 || bad "live comment-only review exits 0: $(head -c 300 "$C4d/run.out")"
rm -f "$STUB/list.out"
check "a live run on a class that has a ticket comments on it" 'digest "$C4d" | grep -q "commented denied/guard-pr-check-literal"'
check "a live run that only commented does not tell the operator to triage what the router filed" '[ "$(sends)" = "$((s4 + 1))" ] && ! tail -n 1 "$STUB/notify.log" | grep -q "triage what the router filed"'

echo "5. the two unreliable trajectory signals never reach the digest"
C5="$TMP/c5"; mkdir -p "$C5"
row "$C5/ledger.jsonl" N100 traj/claim-unverified; row "$C5/ledger.jsonl" N200 traj/red-before-green
row "$C5/ledger.jsonl" N100 traj/identical-retry
review "$C5" >/dev/null 2>&1
check "claim-unverified and red-before-green are absent" '! digest "$C5" | grep -Eq "claim-unverified|red-before-green"'
check "the other trajectory signals are listed" 'digest "$C5" | grep -q "traj/identical-retry: 1"'
check "the exclusion is stated" 'digest "$C5" | grep -q "excluded until HIMMEL-4698"'
C5b="$TMP/c5b"; mkdir -p "$C5b"
row "$C5b/ledger.jsonl" N100 traj/claim-unverified
review "$C5b" >/dev/null 2>&1
check "a day with only the excluded signals is a no-failure day" 'digest "$C5b" | grep -q "no failures in the last 24 h"'

echo "6. new vs recurring; a quiet day sends nothing"
C6="$TMP/c6"; mkdir -p "$C6"
row "$C6/ledger.jsonl" N100 error/Edit 0 2026-10-03T08:00:00Z
row "$C6/ledger.jsonl" N200 error/Edit
s0="$(sends)"
review "$C6" >/dev/null 2>&1
check "a class seen before the window is recurring" 'digest "$C6" | grep -q "error/Edit: 1 rows, legs N200 (recurring)"'
check "a quiet day (no new class, nothing routed) sends nothing" '[ "$(sends)" = "$s0" ]'
row "$C6/ledger.jsonl" N300 blocked/merge-hold
review "$C6" >/dev/null 2>&1
check "a class first seen today is new" 'digest "$C6" | grep -q "blocked/merge-hold: 1 rows, legs N300 (new)"'
check "a new class sends one line naming it" '[ "$(sends)" = "$((s0 + 1))" ] && tail -n 1 "$STUB/notify.log" | grep -q "1 new class first seen today .*: blocked/merge-hold (1 failure)"'
# the line is the plain shape; four new classes show the top three with counts and "1 more".
C6p="$TMP/c6p"; mkdir -p "$C6p"
for i in 1 2 3 4 5; do row "$C6p/ledger.jsonl" "N5$i" error/Bash:usage:check-old-terms; done
for i in 1 2 3 4; do row "$C6p/ledger.jsonl" "N6$i" error/Edit; done
for i in 1 2 3; do row "$C6p/ledger.jsonl" "N7$i" blocked/merge-hold; done
row "$C6p/ledger.jsonl" N81 error/Read
review "$C6p" >/dev/null 2>&1
plain="$(tail -n 1 "$STUB/notify.log")"
check "the line is the plain shape" 'printf "%s\n" "$plain" | grep -qE "^failure review $DAY \(dry-run\): 13 failures in 4 classes over 24 h; dry run, nothing filed \([0-9]+ would be\)\. Cause: .* Do: .* Log: $C6p/out/failure-review-$DAY\.md$"'
check "the top three new classes carry their counts" 'printf "%s\n" "$plain" | grep -q "error/Bash:usage:check-old-terms (5 failures), error/Edit (4 failures), blocked/merge-hold (3 failures) and 1 more"'
check "the line gives a next step and drops the word routed" 'printf "%s\n" "$plain" | grep -q "Do: open the digest and file a ticket" && ! printf "%s\n" "$plain" | grep -qi "routed"'
# suite rows carry final_red: false = red inside the leg then green, true = left red at wrap.
C6d="$TMP/c6d"; mkdir -p "$C6d"
row "$C6d/ledger.jsonl" N400 suite/test-green-again.sh
row "$C6d/ledger.jsonl" N400 suite/test-left-red.sh
jq -c 'if .class == "suite/test-left-red.sh" then . + {final_red:true} else . + {final_red:false} end' "$C6d/ledger.jsonl" >"$C6d/l2" && mv "$C6d/l2" "$C6d/ledger.jsonl"
review "$C6d" >/dev/null 2>&1
rc=$?
check "the suite fixture review exits 0" '[ "$rc" -eq 0 ]'
check "a suite class that went red then green is not new" 'digest "$C6d" | grep -q "suite/test-green-again.sh: 1 rows, legs N400 (recurring)"'
check "a suite class left red at wrap is new" 'digest "$C6d" | grep -q "suite/test-left-red.sh: 1 rows, legs N400 (new)"'
check "only the ended-red class is named as new" 'tail -n 1 "$STUB/notify.log" | grep -q "1 new class first seen today .*: suite/test-left-red.sh (1 failure)\. Do: " && ! tail -n 1 "$STUB/notify.log" | grep -q test-green-again'
C6c="$TMP/c6c"; mkdir -p "$C6c"
row "$C6c/ledger.jsonl" N100 error/Read 0 2026-10-06T11:59:59.500000Z
row "$C6c/ledger.jsonl" N200 error/Read
review "$C6c" >/dev/null 2>&1
check "a row in the last second before the window still makes the class recurring" 'digest "$C6c" | grep -q "error/Read: 1 rows, legs N200 (recurring)"'
printf '#!/usr/bin/env bash\nexit 1\n' >"$STUB/notify-fail"; chmod +x "$STUB/notify-fail"
C6b="$TMP/c6b"; mkdir -p "$C6b"
row "$C6b/ledger.jsonl" N400 error/Bash
review "$C6b" --notify-cmd "$STUB/notify-fail" >"$C6b/run.out" 2>&1; rc=$?
check "an undelivered line fails the run (rc 3), the digest still written" '[ "$rc" = 3 ] && [ -f "$C6b/out/failure-review-$DAY.md" ] && grep -q "NOT delivered" "$C6b/run.out"'

echo "7. the daily-note section is upserted, never duplicated"
V="$TMP/vault"; mkdir -p "$V/50-Journal/Daily"
printf '# %s\n\n## Morning\n\nkeep me\n' "$DAY" >"$V/50-Journal/Daily/$DAY.md"
review "$C2" --vault "$V" >/dev/null 2>&1
review "$C2" --vault "$V" >/dev/null 2>&1
check "one Failure review section" '[ "$(grep -c "^## Failure review" "$V/50-Journal/Daily/$DAY.md")" = 1 ]'
check "the rest of the note is kept" 'grep -q "keep me" "$V/50-Journal/Daily/$DAY.md" && grep -q "^## Morning" "$V/50-Journal/Daily/$DAY.md"'
check "the section carries the digest" 'grep -q "would-file denied/guard-pr-check-literal" "$V/50-Journal/Daily/$DAY.md"'
V2="$TMP/vault2"; mkdir -p "$V2"
review "$C2" --vault "$V2" >/dev/null 2>&1
check "a missing daily note is created" 'grep -q "^## Failure review" "$V2/50-Journal/Daily/$DAY.md"'

echo "8. the cadence"
CR="$TMP/cron"; mkdir -p "$CR"
cat >"$STUB/crontab" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "-l" ]; then [ -f "$CR/tab" ] && { cat "$CR/tab"; exit 0; }; echo "no crontab for test" >&2; exit 1; fi
[ -f "$CR/fail" ] && exit 1
cat >"$CR/tab"
EOF
chmod +x "$STUB/crontab"
export FAILREV_CRONTAB="$STUB/crontab" FAILREV_RUNNER_DIR="$TMP/runner"
bash "$CAD" arm --vault "$V" --dry-run >"$TMP/arm-dry.out" 2>&1
check "arm --dry-run writes nothing" '[ ! -f "$CR/tab" ] && grep -q "DRY failure-review-cadence" "$TMP/arm-dry.out"'
bash "$CAD" arm --vault "$V" >"$TMP/arm.out" 2>&1 || bad "arm exits 0: $(cat "$TMP/arm.out")"
check "one tagged crontab entry" '[ "$(grep -c "# HIMMEL-FailureReview" "$CR/tab")" = 1 ]'
check "the runner routes dry-run by default" '[ -x "$TMP/runner/failure-review-cadence.sh" ] && ! grep -q -- "--live" "$TMP/runner/failure-review-cadence.sh"'
bash "$CAD" arm --vault "$V" >/dev/null 2>&1; rc=$?
check "a second arm without --force refuses (rc 3)" '[ "$rc" = 3 ]'
env -u JIRA_PROJECT_KEY bash "$CAD" arm --vault "$V" --live --force >"$TMP/arm-nokey.out" 2>&1; rc=$?
check "arm --live with no JIRA_PROJECT_KEY refuses (rc 2) and changes nothing" '[ "$rc" = 2 ] && grep -q JIRA_PROJECT_KEY "$TMP/arm-nokey.out" && ! grep -q -- "--live" "$TMP/runner/failure-review-cadence.sh"'
JIRA_PROJECT_KEY=bad-key bash "$CAD" arm --vault "$V" --live --force >/dev/null 2>&1; rc=$?
check "arm --live with a non-project key refuses (rc 2)" '[ "$rc" = 2 ]'
env -u JIRA_PROJECT_KEY bash "$CAD" arm --vault "$V" --force >/dev/null 2>&1; rc=$?
check "a dry-run arm needs no key and bakes none" '[ "$rc" = 0 ] && ! grep -q JIRA_PROJECT_KEY "$TMP/runner/failure-review-cadence.sh"'
bash "$CAD" arm --vault "$V" --live --force >/dev/null 2>&1
check "--live is baked only on request, with the key, still one entry" 'grep -q -- "--live" "$TMP/runner/failure-review-cadence.sh" && grep -q "JIRA_PROJECT_KEY=HIMMEL" "$TMP/runner/failure-review-cadence.sh" && [ "$(grep -c "# HIMMEL-FailureReview" "$CR/tab")" = 1 ]'
check "status shows it armed" 'bash "$CAD" status | grep -q "^ARMED .*HIMMEL-FailureReview"'
touch "$CR/fail"
bash "$CAD" arm --vault "$V" --force >/dev/null 2>&1; rc=$?
rm -f "$CR/fail"
check "a failed crontab install keeps the old runner (still --live), no temp left" '[ "$rc" = 4 ] && grep -q -- "--live" "$TMP/runner/failure-review-cadence.sh" && [ "$(ls "$TMP/runner" | grep -c "failure-review-cadence.sh")" = 1 ]'
(cd "$TMP" && bash "$CAD" arm --vault vault --force >/dev/null 2>&1)
check "a relative --vault is baked as an absolute path" 'grep -qF -- "--vault $V" "$TMP/runner/failure-review-cadence.sh"'
MVF="$TMP/mvfail"; mkdir -p "$MVF"; printf '#!/usr/bin/env bash\nexit 1\n' >"$MVF/mv"; chmod +x "$MVF/mv"
cp "$CR/tab" "$TMP/tab.before"
PATH="$MVF:$PATH" bash "$CAD" arm --vault "$V" --time 07:30 --live --force >/dev/null 2>&1; rc=$?
check "a failed runner swap restores the previous crontab (rc 4)" '[ "$rc" = 4 ] && cmp -s "$CR/tab" "$TMP/tab.before" && ! grep -q -- "--live" "$TMP/runner/failure-review-cadence.sh"'
bash "$CAD" disarm >/dev/null 2>&1
check "disarm removes the entry and the runner" '! grep -q "HIMMEL-FailureReview" "$CR/tab" && [ ! -f "$TMP/runner/failure-review-cadence.sh" ]'
printf '#!/usr/bin/env bash\necho SKIPPED-BANK\n' >"$STUB/preflight"; chmod +x "$STUB/preflight"
C8="$TMP/c8"; mkdir -p "$C8"
FAILURE_REVIEW_PREFLIGHT="$STUB/preflight" HIMMEL_FAILURE_REVIEW_DIR="$C8/out" HIMMEL_WORKER_SESSION_FAILURES_LEDGER="$C2/ledger.jsonl" \
  timeout "$BOUND" bash "$CAD" run >"$C8/run.out" 2>&1; rc=$?
hung "$rc" "cadence run (skipped-bank)"
check "a SKIPPED-BANK preflight skips the run, rc 0, no digest" '[ "$rc" = 0 ] && grep -q "SKIPPED-BANK" "$C8/run.out" && [ ! -d "$C8/out" ]'
printf '#!/usr/bin/env bash\necho PROCEED\n' >"$STUB/preflight"
FAILURE_REVIEW_PREFLIGHT="$STUB/preflight" HIMMEL_FAILURE_REVIEW_DIR="$C8/out" HIMMEL_WORKER_SESSION_FAILURES_LEDGER="$C2/ledger.jsonl" \
  HIMMEL_FAILURE_ROUTES_STATE="$C8/state.json" timeout "$BOUND" bash "$CAD" run >"$C8/run2.out" 2>&1; rc=$?
hung "$rc" "cadence run (proceed)"
check "a PROCEED preflight runs the review dry-run" '[ "$rc" = 0 ] && ls "$C8/out"/failure-review-*.md >/dev/null 2>&1 && [ ! -e "$C8/state.json" ]'
# a failed Telegram send (rc 3) leaves the digest written: the alert says only the send failed.
C8n="$TMP/c8n"; mkdir -p "$C8n"; row "$C8n/ledger.jsonl" N900 error/Notify 0 "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
FAILURE_REVIEW_PREFLIGHT="$STUB/preflight" FAILURE_REVIEW_NOTIFY_CMD="$STUB/notify-fail" HIMMEL_FAILURE_REVIEW_DIR="$C8n/out" HIMMEL_WORKER_SESSION_FAILURES_LEDGER="$C8n/ledger.jsonl" \
  HIMMEL_FAILURE_ROUTES_STATE="$C8n/state.json" timeout "$BOUND" bash "$CAD" run >"$C8n/run.out" 2>&1; rc=$?
hung "$rc" "cadence run (send fails)"
check "a failed Telegram send is its own alert: digest written, only the send failed" '[ "$rc" = 3 ] && ls "$C8n/out"/failure-review-*.md >/dev/null 2>&1 && tail -n 1 "$STUB/notify.log" | grep -q "Telegram message was not delivered (exit 3)\. Cause: the digest is written; only the send failed\. Do: nothing, the undelivered line is sent again at the next run"'

echo "9. delivery is persisted: a failed line is retried, a delivered one is not repeated (HIMMEL-4790)"
C9="$TMP/c9"; mkdir -p "$C9"
row "$C9/ledger.jsonl" N050 denied/guard-recur 1 2026-10-03T08:00:00Z
row "$C9/ledger.jsonl" N100 denied/guard-recur 1
row "$C9/ledger.jsonl" N200 denied/guard-recur 1
review "$C9" --live --notify-cmd "$STUB/notify-fail" >"$C9/run1.out" 2>&1; rc=$?
check "a recurring class routed live with a failed send: rc 3" '[ "$rc" = 3 ] && digest "$C9" | grep -q "filed denied/guard-recur"'
s0="$(sends)"
review "$C9" --live >"$C9/run2.out" 2>&1; rc=$?
check "the retry sends the undelivered routing although the router routes nothing new" '[ "$rc" = 0 ] && [ "$(sends)" = "$((s0 + 1))" ] && tail -n 1 "$STUB/notify.log" | grep -q "filed denied/guard-recur"'
review "$C9" --live >/dev/null 2>&1
check "once delivered it is not sent again" '[ "$(sends)" = "$((s0 + 1))" ]'
C9b="$TMP/c9b"; mkdir -p "$C9b"
row "$C9b/ledger.jsonl" N400 error/Glob
s0="$(sends)"
review "$C9b" >/dev/null 2>&1
review "$C9b" >/dev/null 2>&1
check "a new class delivered once is not repeated by a rerun in the window" '[ "$(sends)" = "$((s0 + 1))" ]'
row "$C9b/ledger.jsonl" N500 error/Grep
review "$C9b" >/dev/null 2>&1
check "a second new class still sends, naming only itself" '[ "$(sends)" = "$((s0 + 2))" ] && tail -n 1 "$STUB/notify.log" | grep -q "1 new class first seen today .*: error/Grep (1 failure)\. Do: "'
s0="$(sends)"
review "$C6b" >"$C6b/run2.out" 2>&1; rc=$?
check "a new class whose send failed is retried by the next run" '[ "$rc" = 0 ] && [ "$(sends)" = "$((s0 + 1))" ] && tail -n 1 "$STUB/notify.log" | grep -q "error/Bash (1 failure)"'
C9c="$TMP/c9c"; mkdir -p "$C9c"
row "$C9c/ledger.jsonl" N600 error/Edit
echo 'not json' >"$C9c/state.json.notify.json"
review "$C9c" --notify-cmd "$STUB/notify-fail" >"$C9c/run1.out" 2>&1; rc=$?
check "an unreadable notify state is kept aside, never overwritten" '[ "$rc" = 3 ] && [ "$(cat "$C9c"/state.json.notify.json.unreadable.*)" = "not json" ]'
s0="$(sends)"
review "$C9c" >/dev/null 2>&1; rc=$?
check "a failed send over an unreadable state is still retried" '[ "$rc" = 0 ] && [ "$(sends)" = "$((s0 + 1))" ] && tail -n 1 "$STUB/notify.log" | grep -q "error/Edit (1 failure)"'
C9d="$TMP/c9d"; mkdir -p "$C9d"
row "$C9d/ledger.jsonl" N700 error/Write
echo '{"v":1,"pending":[1],"sent":{}}' >"$C9d/state.json.notify.json"
review "$C9d" >"$C9d/run.out" 2>&1; rc=$?
check "a non-string pending entry is an unreadable state, not a crash" '[ "$rc" = 0 ] && ls "$C9d"/state.json.notify.json.unreadable.* >/dev/null 2>&1 && ! grep -q Traceback "$C9d/run.out"'
echo 'still not json' >"$C9c/state.json.notify.json"
review "$C9c" >/dev/null 2>&1
check "a second unreadable state does not overwrite the first one kept aside" '[ "$(ls "$C9c"/state.json.notify.json.unreadable.* | wc -l)" = 2 ]'
C9e="$TMP/c9e"; mkdir -p "$C9e"
row "$C9e/ledger.jsonl" N050 denied/guard-kill 1 2026-10-03T08:00:00Z
row "$C9e/ledger.jsonl" N100 denied/guard-kill 1
row "$C9e/ledger.jsonl" N200 denied/guard-kill 1
printf '#!/usr/bin/env bash\nkill -9 "$PPID"\n' >"$STUB/notify-kill"; chmod +x "$STUB/notify-kill"
review "$C9e" --live --notify-cmd "$STUB/notify-kill" >/dev/null 2>&1
s0="$(sends)"
review "$C9e" --live >/dev/null 2>&1; rc=$?
check "a review killed during the send still retries its routing on the next run" '[ "$rc" = 0 ] && [ "$(sends)" = "$((s0 + 1))" ] && tail -n 1 "$STUB/notify.log" | grep -q "undelivered earlier: filed denied/guard-kill"'
C9f="$TMP/c9f"; mkdir -p "$C9f"
row "$C9f/ledger.jsonl" N050 denied/guard-crash 1 2026-10-03T08:00:00Z
row "$C9f/ledger.jsonl" N100 denied/guard-crash 1
row "$C9f/ledger.jsonl" N200 denied/guard-crash 1
touch "$C9f/not-a-vault"
review "$C9f" --live --vault "$C9f/not-a-vault" >/dev/null 2>&1
s0="$(sends)"
review "$C9f" --live >/dev/null 2>&1; rc=$?
check "a review that dies after routing, before its send, still sends that routing next run" '[ "$rc" = 0 ] && [ "$(sends)" = "$((s0 + 1))" ] && tail -n 1 "$STUB/notify.log" | grep -q "undelivered earlier: filed denied/guard-crash"'
C9g="$TMP/c9g"; mkdir -p "$C9g"
row "$C9g/ledger.jsonl" N800 error/Read
: >"$C9g/other-ledger.jsonl"
review "$C9g" --notify-cmd "$STUB/notify-fail" >/dev/null 2>&1
s0="$(sends)"
review "$C9g" --ledger "$C9g/other-ledger.jsonl" --state "$C9g/other.json" >/dev/null 2>&1
check "a router state file in the same directory does not take another one's pending line" '[ "$(sends)" = "$s0" ] && [ -f "$C9g/state.json.notify.json" ]'
C9h="$TMP/c9h"; mkdir -p "$C9h"
row "$C9h/ledger.jsonl" N900 error/Task
: >"$C9h/other-ledger.jsonl"
review "$C9h" --state "$C9h/routes.json" --notify-cmd "$STUB/notify-fail" >/dev/null 2>&1
s0="$(sends)"
review "$C9h" --ledger "$C9h/other-ledger.jsonl" --state "$C9h/routes.state" >/dev/null 2>&1
check "two router states differing only in extension keep separate pending lines" '[ "$(sends)" = "$s0" ] && [ -f "$C9h/routes.json.notify.json" ] && [ ! -e "$C9h/routes.state.notify.json" ]'
C9i="$TMP/c9i"; mkdir -p "$C9i"
row "$C9i/ledger.jsonl" N910 error/Skill
printf '{"v":1,"pending":["filed denied/old-class"],"sent":{}}\n' >"$C9i/state.notify.json"
s0="$(sends)"
review "$C9i" >/dev/null 2>&1
check "a pending line in the pre-HIMMEL-4798 notify file is sent once and the file moves to the new name" '[ "$(sends)" = "$((s0 + 1))" ] && tail -n 1 "$STUB/notify.log" | grep -q "undelivered earlier: filed denied/old-class" && [ -f "$C9i/state.json.notify.json" ] && [ ! -e "$C9i/state.notify.json" ]'
C9j="$TMP/c9j"; mkdir -p "$C9j"
row "$C9j/ledger.jsonl" N920 error/Monitor
: >"$C9j/other-ledger.jsonl"
review "$C9j" --state "$C9j/routes.json" --notify-cmd "$STUB/notify-fail" >/dev/null 2>&1
s0="$(sends)"
review "$C9j" --ledger "$C9j/other-ledger.jsonl" --state "$C9j/routes.json.state" >/dev/null 2>&1
check "a state named like another's sidecar stem does not migrate that sidecar away" '[ "$(sends)" = "$s0" ] && [ -f "$C9j/routes.json.notify.json" ]'
C9k="$TMP/c9k"; mkdir -p "$C9k"
row "$C9k/ledger.jsonl" N930 error/Task
review "$C9k" --state "$C9k/routes" >/dev/null 2>&1
check "an extensionless router state finishes (its legacy and new sidecar names coincide)" '[ -f "$C9k/routes.notify.json" ]'

echo
echo "friction subsection (HIMMEL-4926)"
CF="$TMP/cf"; mkdir -p "$CF"; : >"$CF/ledger.jsonl"
printf '#!/usr/bin/env bash\nprintf "### Friction (last 7 days)\\n\\n- hook:x / y: 3 refusals\\n"\n' >"$STUB/friction-ok"
printf '#!/usr/bin/env bash\nexit 7\n' >"$STUB/friction-bad"
chmod +x "$STUB/friction-ok" "$STUB/friction-bad"
FAILURE_REVIEW_FRICTION_CMD="$STUB/friction-ok" review "$CF" >"$CF/run.out" 2>&1
check "the digest carries the friction subsection" 'digest "$CF" | grep -q "^- hook:x / y: 3 refusals"'
CG="$TMP/cg"; mkdir -p "$CG"; : >"$CG/ledger.jsonl"
cg_rc=0
FAILURE_REVIEW_FRICTION_CMD="$STUB/friction-bad" review "$CG" >"$CG/run.out" 2>&1 || cg_rc=$?
check "a failing friction command does not fail the review" '[ "$cg_rc" -eq 0 ]'
check "a failing friction command leaves one line and the review still exits 0" 'digest "$CG" | grep -q "unavailable: rc 7"'
CH="$TMP/ch"; mkdir -p "$CH"; : >"$CH/ledger.jsonl"
review "$CH" >"$CH/run.out" 2>&1
check "an empty command turns the subsection off" '! digest "$CH" | grep -q "Friction"'

echo "test-failure-review:$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
