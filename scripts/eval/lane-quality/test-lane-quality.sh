#!/usr/bin/env bash
# scripts/eval/lane-quality/test-lane-quality.sh - hermetic suite for the
# lane-quality eval harness. No real claude call: a fake binary
# stands in for the agent and the judge, and a fake bank preflight for the bank.
#  1. every hidden acceptance test FAILS on its untouched fixture and PASSES on
#     its reference solution (a test that cannot fail is not evidence);
#  2. `run` end to end: metrics, acceptance, blind-judge packet redaction,
#     worktree cleanup;
#  3. the budget cap, the bank refusal and the phase-2 lane refusal;
#  4. `table` renders the recorded rows.
#
# check() evals its condition, so the single quotes and $R are deliberate.
# shellcheck disable=SC2016,SC2034
set -u
export HIMMEL_BILLED_OK=1   # stubbed claude/codex only; the guarded script refuses a bare run
HERE="$(cd "$(dirname "$0")" && pwd)"
RUN="$HERE/run.sh"
REAL_REPO="$(cd "$HERE/../../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/lane-quality-test.XXXXXX")" || { echo "test-lane-quality: mktemp -d failed" >&2; exit 1; }
trap 'git -C "$TMP/repo" worktree prune >/dev/null 2>&1; rm -rf "$TMP"' EXIT
export HIMMEL_EVAL_RUNS_LEDGER="$TMP/eval-runs.jsonl"   # HIMMEL-4647: never the live ledger
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
# nogrep <grep args>: true only when grep ran and matched nothing (rc 1); a grep
# error (rc 2, e.g. a missing file) is not absence.
nogrep() { grep "$@"; [ $? -eq 1 ]; }

# A tiny stand-in for the pinned himmel tree: finding-verify cites the real
# cache-probe.sh, so it is copied in byte for byte.
mkdir -p "$TMP/repo/scripts/eval"
cp "$REAL_REPO/scripts/eval/cache-probe.sh" "$TMP/repo/scripts/eval/"
printf 'stand-in steering\n' >"$TMP/repo/CLAUDE.md"
git -C "$TMP/repo" init -q
git -C "$TMP/repo" -c user.name=t -c user.email=t@t add -A
git -C "$TMP/repo" -c user.name=t -c user.email=t@t commit -qm base
BASE="$(git -C "$TMP/repo" rev-parse HEAD)"

echo "1. acceptance tests discriminate (fixture RED, reference GREEN)"
for task in shell-red-green doc-plus-code hook-refusal finding-verify cr-fix class-sweep guard-cmd dispatch-chores; do
  wt="$TMP/acc-$task"
  git -C "$TMP/repo" worktree add -q --detach "$wt" "$BASE"
  fix="$(bash "$RUN" materialize "$task" "$wt")"
  if bash "$HERE/tasks/$task/accept.sh" "$wt" "$fix" >"$TMP/acc-$task.red" 2>&1; then
    bad "$task: accept passes on the untouched fixture"
  else ok "$task: accept fails on the untouched fixture"; fi
  bash "$RUN" materialize "$task" "$wt" --reference >/dev/null
  # guard-cmd asks for a commit, so its reference solution is one.
  [ "$task" != guard-cmd ] || { git -C "$wt" add -A && git -C "$wt" -c user.name=t -c user.email=t@t commit -qm 'docs: [HIMMEL-9999] changelog entry' --no-verify; }
  if bash "$HERE/tasks/$task/accept.sh" "$wt" "$fix" >"$TMP/acc-$task.green" 2>&1; then
    ok "$task: accept passes on the reference"
  else bad "$task: accept fails on the reference: $(grep FAIL "$TMP/acc-$task.green" | tr '\n' ';')"; fi
done

# Fake claude: the judge call (has --json-schema) records its stdin and scores
# 4s; an agent call copies the task's reference into its cwd and writes a
# transcript with 2 tool calls, 1 compaction and 1 hook denial.
mkdir -p "$TMP/bin" "$TMP/projects/p"
cat >"$TMP/bin/claude" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$LQ_FAKE_LOG"
case " $* " in *" --json-schema "*)
  cat >>"$LQ_FAKE_LOG.judge"
  [ -z "${LQ_FAKE_5HSEQ:-}" ] || wc -l <"$LQ_FAKE_5HSEQ" | tr -d ' ' >"$LQ_FAKE_5HSEQ.atjudge"
  [ -z "${LQ_FAKE_JUDGE_HANG:-}" ] || sleep 10
  echo '{"type":"result","is_error":false,"total_cost_usd":0.02,"structured_output":{"correctness":4,"scope_discipline":4,"test_quality":4,"honesty":4,"notes":"n"}}'
  exit 0 ;;
esac
prompt="$2"
case "$prompt" in
  *semver-cmp*) t=shell-red-green ;; *log-tail*) t=doc-plus-code ;;
  *block-curl-pipe*) t=hook-refusal ;; *cleanup-old*) t=cr-fix ;;
  *sweep/a.sh*) t=class-sweep ;; *CHANGELOG*) t=guard-cmd ;; *) t=finding-verify ;;
esac
# Record the steering file the agent started with; a BREAK variant makes the agent fail the task.
[ ! -f CLAUDE.md ] || cat CLAUDE.md >>"$LQ_FAKE_LOG.claudemd"
if ! grep -q BREAK CLAUDE.md 2>/dev/null; then bash "$LQ_FAKE_RUN" materialize "$t" "$PWD" --reference >/dev/null; fi
# the candidate script dumps its env when acceptance runs it.
if [ -n "${LQ_FAKE_ACCEPTENV:-}" ]; then
  { head -n 1 lq-work/cleanup-old.sh; echo "env >\"$LQ_FAKE_ACCEPTENV\""; tail -n +2 lq-work/cleanup-old.sh; } >lq-work/cleanup-old.new
  mv lq-work/cleanup-old.new lq-work/cleanup-old.sh
fi
# Misbehaviour knobs: a candidate that hangs, a commit outside lq-work/, and a
# bank that runs dry during the agent call.
[ -z "${LQ_FAKE_HANG:-}" ] || printf '#!/usr/bin/env bash\nsleep 10\n' >lq-work/semver-cmp.sh
if [ -n "${LQ_FAKE_COMMIT:-}" ]; then
  echo x >stray.txt
  git add stray.txt lq-work && git -c user.name=t -c user.email=t@t commit -qm stray --no-verify
fi
[ -z "${LQ_FAKE_BIG:-}" ] || head -c 70000 /dev/zero | tr '\0' x >lq-work/big.txt
[ -z "${LQ_FAKE_DRAIN:-}" ] || echo SKIPPED-BANK >"$LQ_FAKE_DRAIN"
[ -z "${LQ_FAKE_NOJSON:-}" ] || exit 124
sid="sess-$t"
{
  echo '{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"tu1","name":"Read","input":{"file_path":"lq-work/x"}}]}}'
  echo '{"type":"assistant","message":{"id":"m2","content":[{"type":"tool_use","id":"tu2","name":"Bash","input":{"command":"cat scripts/eval/lane-quality/tasks/x"}}]}}'
  echo '{"type":"assistant","message":{"id":"m2","content":[{"type":"tool_use","id":"tu2","name":"Bash","input":{"command":"cat scripts/eval/lane-quality/tasks/x"}}]}}'
  echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu2","is_error":true,"content":"PreToolUse:Bash hook error: refusing"}]}}'
  echo '{"type":"system","subtype":"compact_boundary"}'
  if [ -n "${LQ_FAKE_DISPATCH:-}" ]; then # one named and one unnamed subagent dispatch
    echo '{"type":"assistant","message":{"id":"m3","content":[{"type":"tool_use","id":"tu3","name":"Agent","input":{"prompt":"p","model":"haiku"}}]}}'
    echo '{"type":"assistant","message":{"id":"m4","content":[{"type":"tool_use","id":"tu4","name":"Agent","input":{"prompt":"p"}}]}}'
  fi
} >"$LQ_TRANSCRIPTS/p/$sid.jsonl"
jq -cn --arg s "$sid" --argjson mu "${LQ_FAKE_MU:-null}" '{type:"result",subtype:"success",is_error:false,session_id:$s,total_cost_usd:0.5,num_turns:3,duration_ms:1000,permission_denials:[{tool_name:"Bash"}],result:("Done by claude-haiku-4-5 via openrouter on the native lane; tests pass." + ($ENV.LQ_FAKE_SAY // ""))} + (if $mu == null then {} else {modelUsage: $mu} end) + (if $ENV.LQ_FAKE_NOCOST then {total_cost_usd: null} else {} end)'
FAKE
chmod +x "$TMP/bin/claude"
# LQ_FAKE_PROCEED_N=<n>: only the first n calls PROCEED (counted in LQ_FAKE_CALLS).
cat >"$TMP/bin/preflight" <<'FAKE'
#!/usr/bin/env bash
if [ -n "${LQ_FAKE_5HSEQ:-}" ]; then # LQ_FAKE_5HSEQ=<file>: five_hour is the 1-based call count
  echo x >>"$LQ_FAKE_5HSEQ"; LQ_FAKE_5H="$(wc -l <"$LQ_FAKE_5HSEQ" | tr -d ' ')"
fi
echo "bank-preflight: five_hour=${LQ_FAKE_5H:-10.0} seven_day=3.0" >&2
[ -z "${LQ_FAKE_PFENV:-}" ] || env >>"$LQ_FAKE_PFENV"
if [ -n "${LQ_FAKE_PROCEED_N:-}" ]; then
  echo x >>"$LQ_FAKE_CALLS"
  [ "$(wc -l <"$LQ_FAKE_CALLS")" -le "$LQ_FAKE_PROCEED_N" ] || { echo SKIPPED-BANK; exit 0; }
fi
cat "${LQ_FAKE_DRAIN:-/nonexistent}" 2>/dev/null || echo "${LQ_FAKE_TOKEN:-PROCEED}"
FAKE
chmod +x "$TMP/bin/preflight"

export LQ_CLAUDE_BIN="$TMP/bin/claude" LQ_PREFLIGHT="$TMP/bin/preflight" LQ_REPO="$TMP/repo" \
  LQ_BASE_SHA="$BASE" LQ_WORK_ROOT="$TMP/work" LQ_TRANSCRIPTS="$TMP/projects" \
  LQ_FAKE_LOG="$TMP/fake.log" LQ_FAKE_RUN="$RUN"

echo "2. run end to end (fake agent + fake judge)"
bash "$RUN" run --lane native --model claude-haiku-4-5 --tasks shell-red-green,finding-verify --out "$TMP/out1" >"$TMP/run1.log" 2>&1
rc=$?
R="$TMP/out1/runs.jsonl"
check "run exits 0" '[ "$rc" -eq 0 ]'
[ "$rc" -eq 0 ] || sed 's/^/    run1: /' "$TMP/run1.log"
check "two rows recorded" '[ "$(wc -l <"$R" | tr -d " ")" = 2 ]'
check "acceptance passed on both" '[ "$(jq -s "map(select(.accept_ok)) | length" "$R")" = 2 ]'
check "tool calls deduped by id" '[ "$(jq -s ".[0].tool_calls" "$R")" = 2 ]'
check "compactions counted" '[ "$(jq -s ".[0].compactions" "$R")" = 1 ]'
check "hook denials counted" '[ "$(jq -s ".[0].hook_denials" "$R")" = 1 ]'
check "trajectory fields recorded (HIMMEL-4651)" 'jq -s -e ".[0] | [.red_before_green, .denial_recovery, .identical_denied_retries, .verify_before_claim] == [null, 1, 0, false]" "$R" >/dev/null'
check "permission denials counted" '[ "$(jq -s ".[0].permission_denials" "$R")" = 1 ]'
check "cost recorded" '[ "$(jq -s ".[0].cost_usd" "$R")" = 0.5 ]'
check "bank reading recorded" '[ "$(jq -s -r ".[0].bank_5h_before" "$R")" = 10.0 ]'
check "peek at hidden tests flagged" '[ "$(jq -s ".[0].peeked" "$R")" = true ]'
check "scope ok" '[ "$(jq -s "map(select(.scope_ok)) | length" "$R")" = 2 ]'
check "judge scores recorded" '[ "$(jq -s ".[0].judge.correctness" "$R")" = 4 ]'
check "judge packet hides the model" '[ -s "$TMP/fake.log.judge" ] && nogrep -qi "haiku" "$TMP/fake.log.judge"'
check "judge packet hides the lane" '[ -s "$TMP/fake.log.judge" ] && nogrep -qi "openrouter" "$TMP/fake.log.judge"'
check "judge packet hides the native lane" '[ -s "$TMP/fake.log.judge" ] && nogrep -qiw "native" "$TMP/fake.log.judge"'
check "judge packet carries the diff" 'grep -q "semver-cmp" "$TMP/fake.log.judge"'
check "agent call declares a permission mode" 'grep -q -- "--permission-mode auto" "$TMP/fake.log"'
check "worktrees removed" '[ -z "$(ls -A "$TMP/work" 2>/dev/null)" ]'
check "judge cost counts toward the budget" 'grep -q "spent 1.0400 USD" "$TMP/run1.log"'
check "judge call is budget-capped" 'grep -- "--json-schema" "$TMP/fake.log" | grep -q -- "--max-budget-usd"'
check "judge packet hides the model version" 'nogrep -q "4-5" "$TMP/fake.log.judge"'
EL="$HIMMEL_EVAL_RUNS_LEDGER"
check "sweep appends one eval-runs row" '[ "$(jq -s "map(select(.artifact | contains(\"/out1/\"))) | length" "$EL")" = 1 ]'
check "eval-runs row is a valid lane-quality row (n=2, ok)" '[ "$(jq -s -r "map(select(.artifact | contains(\"/out1/\")))[0] | \"\(.eval) \(.n) \(.status) \(.metrics.accept_ok_rate == 1)\"" "$EL")" = "lane-quality 2 ok true" ] && python3 "$HERE/../lib/eval_runs.py" validate "$EL" >/dev/null'
check "a clean agent result keeps is_error false" '[ "$(jq -s ".[0].is_error" "$R")" = false ]'

echo "3. guards"
bash "$RUN" run --lane native --model m --max-usd 0.6 --no-judge --out "$TMP/out2" >"$TMP/run2.log" 2>&1
check "budget cap stops the sweep after the cap is reached" '[ "$(wc -l <"$TMP/out2/runs.jsonl" | tr -d " ")" = 2 ]'
check "budget stop is reported" 'grep -q "budget" "$TMP/run2.log"'
: >"$TMP/fake.log"
LQ_FAKE_TOKEN=SKIPPED-BANK bash "$RUN" run --lane native --model m --no-judge --out "$TMP/out3" >"$TMP/run3.log" 2>&1
rc=$?
check "bank refusal exits non-zero" '[ "$rc" -ne 0 ]'
check "bank refusal launches nothing" '[ ! -s "$TMP/fake.log" ]'
for lane in deepseek claudex; do
  bash "$RUN" run --lane "$lane" --model m --out "$TMP/out-$lane" >"$TMP/run-$lane.log" 2>&1
  rc=$?
  check "$lane lane refused (exit 3)" '[ "$rc" -eq 3 ]'
done
check "refused lanes launch nothing" '[ ! -s "$TMP/fake.log" ]'
# claudex runs with the per-dispatch opt-in, through its launcher,
# and an unpriced gpt slug does not stop the sweep.
cp "$TMP/bin/claude" "$TMP/bin/claude-codex"
CLAUDEX_LANE_OK=1 LQ_LANE_BIN="$TMP/bin/claude-codex" LQ_FAKE_MU='{"gpt-6.1-sol":{"inputTokens":1000,"outputTokens":200,"cacheReadInputTokens":3000,"cacheCreationInputTokens":0}}' \
  bash "$RUN" run --lane claudex --model gpt-6.1-sol --tasks cr-fix,class-sweep --no-judge --out "$TMP/out-cx" >"$TMP/run-cx.log" 2>&1
rc=$?
check "claudex lane runs with CLAUDEX_LANE_OK=1" '[ "$rc" -eq 0 ] && [ "$(wc -l <"$TMP/out-cx/runs.jsonl" | tr -d " ")" = 2 ]'
check "claudex rows record token counts" '[ "$(jq -s -r ".[0].tokens | \"\(.input) \(.output) \(.cache_read)\"" "$TMP/out-cx/runs.jsonl")" = "1000 200 3000" ]'
check "new tasks pass acceptance end to end" '[ "$(jq -s "map(.accept_ok) | all" "$TMP/out-cx/runs.jsonl")" = true ]'

# --lane api routes the agent through scripts/api-lane/claude-api.sh with a
# hard $1 cap in code, no judge, and no subscription OAuth token in the launcher's env.
# the api lane takes its launcher from the harness's own location ($HERE/../../api-lane),
# never from LQ_REPO or LQ_LANE_BIN. The harness is copied into $TMP/tree so a fake launcher can stand where
# run.sh looks, while LQ_REPO (the git repo) holds a poisoned launcher that must never run.
TREE="$TMP/tree"; mkdir -p "$TREE/scripts/eval" "$TREE/scripts/lib" "$TREE/scripts/api-lane"
cp -R "$(dirname "$RUN")" "$TREE/scripts/eval/lane-quality"
cp -R "$(dirname "$RUN")/../lib" "$TREE/scripts/eval/lib"
cp "$(dirname "$RUN")/../../lib/native-auth-pin.sh" "$TREE/scripts/lib/native-auth-pin.sh"
cp "$(dirname "$RUN")/../../api-lane/strip-env.sh" "$TREE/scripts/api-lane/strip-env.sh"
RUN_API="$TREE/scripts/eval/lane-quality/run.sh"
cat >"$TREE/scripts/api-lane/claude-api.sh" <<'FAKE'
#!/usr/bin/env bash
{ echo "key=${ANTHROPIC_API_KEY:-}"; echo "sel=${HIMMEL_API_LANE:-}/${HIMMEL_API_ACCOUNT:-}/${HIMMEL_API_KEY_ID:-}"; echo "oauth=${CLAUDE_CODE_OAUTH_TOKEN:-}"; echo "job=${HIMMEL_API_JOB_ID:-}"; echo "args=$*"; } >>"$LQ_FAKE_APIENV"
if [ -n "${LQ_FAKE_FSMON:-}" ]; then # an agent-written core.fsmonitor: git runs it on the harness's next index refresh
  printf '#!/usr/bin/env bash\nenv >>"%s"\n' "$LQ_FAKE_FSMON" >"$LQ_FAKE_FSMON.sh"; chmod +x "$LQ_FAKE_FSMON.sh"
  git config core.fsmonitor "$LQ_FAKE_FSMON.sh"
fi
[ -z "${LQ_FAKE_API_REFUSE:-}" ] || { echo "claude-api: refused: fake refusal" >&2; exit 2; }
exec "$LQ_CLAUDE_BIN" "$@"
FAKE
chmod +x "$TREE/scripts/api-lane/claude-api.sh"
mkdir -p "$TMP/repo/scripts/api-lane"
printf '#!/usr/bin/env bash\ntouch "%s/poison.ran"\nexit 0\n' "$TMP" >"$TMP/repo/scripts/api-lane/claude-api.sh"
chmod +x "$TMP/repo/scripts/api-lane/claude-api.sh"
APIENV="$TMP/api.env"; : >"$TMP/fake.log"
api_run() { # api_run <out> <args...>: the lane env the operator would set, plus a poisoned OAuth token
  local out="$1"; shift
  HIMMEL_API_LANE=on HIMMEL_API_ACCOUNT=B HIMMEL_API_KEY_ID=key-b ANTHROPIC_API_KEY=sk-ant-dummy-0000 \
    CLAUDE_CODE_OAUTH_TOKEN=oauth-dummy LQ_FAKE_APIENV="$APIENV" \
    bash "$RUN_API" run --lane api --model claude-sonnet-5-5 --out "$out" "$@"
}
api_run "$TMP/out-api0" --no-judge --max-usd 1.5 >"$TMP/api0.log" 2>&1
rc=$?
check "api lane refuses a cap above \$1" '[ "$rc" -eq 64 ] && grep -q "cap" "$TMP/api0.log" && [ ! -e "$APIENV" ]'
api_run "$TMP/out-api1" --tasks cr-fix >"$TMP/api1.log" 2>&1
rc=$?
check "api lane refuses a judged run (the judge is native)" '[ "$rc" -eq 64 ] && grep -q "no-judge" "$TMP/api1.log" && [ ! -e "$APIENV" ]'
api_run "$TMP/out-api2" --no-judge --dry-run --tasks cr-fix,class-sweep >"$TMP/api2.log" 2>&1
rc=$?
check "api dry-run exits 0, names the cap and the command, spends nothing" '[ "$rc" -eq 0 ] && grep -q "cap 1 USD" "$TMP/api2.log" && grep -q "claude-api.sh\|claude-api" "$TMP/api2.log" && [ ! -e "$APIENV" ] && [ ! -s "$TMP/fake.log" ] && [ ! -e "$TMP/out-api2/runs.jsonl" ]'
check "api dry-run never prints the key" 'nogrep -q "sk-ant-dummy" "$TMP/api2.log"'
HIMMEL_API_LANE='' bash "$RUN_API" run --lane api --model m --no-judge --dry-run --out "$TMP/out-api3" >"$TMP/api3.log" 2>&1
rc=$?
check "api dry-run refuses while the lane is OFF" '[ "$rc" -ne 0 ] && grep -q "OFF" "$TMP/api3.log"'
api_run "$TMP/out-api4" --no-judge --tasks cr-fix,class-sweep,shell-red-green >"$TMP/api4.log" 2>&1
rc=$?
check "api lane stops at the \$1 cap (two 0.5 tasks of three)" '[ "$rc" -eq 0 ] && [ "$(wc -l <"$TMP/out-api4/runs.jsonl" | tr -d " ")" = 2 ] && grep -q "budget cap reached" "$TMP/api4.log"'
check "api rows record the lane" '[ "$(jq -s -r "map(.lane) | unique | join(\",\")" "$TMP/out-api4/runs.jsonl")" = api ]'
check "the launcher gets the key and no OAuth token" 'grep -q "^key=sk-ant-dummy-0000$" "$APIENV" && nogrep -q "oauth-dummy" "$APIENV" && grep -q "^oauth=$" "$APIENV"'
check "each call has its own job id and a budget at most the cap" '[ "$(grep -c "^job=lq-" "$APIENV")" = 2 ] && [ "$(grep "^job=" "$APIENV" | sort -u | wc -l | tr -d " ")" = 2 ] && awk "{for(i=1;i<NF;i++) if(\$i==\"--max-budget-usd\"){n++; if(\$(i+1)+0>1) bad=1}} END{exit !(n==2 && !bad)}" "$APIENV"'
check "api rows ignore the native bank for gating" '[ -s "$TMP/out-api4/runs.jsonl" ]'
: >"$TMP/fake.log"; rm -f "$APIENV"
LQ_FAKE_TOKEN=SKIPPED-BANK api_run "$TMP/out-api5" --no-judge --tasks cr-fix >"$TMP/api5.log" 2>&1
rc=$?
check "a native bank refusal does not block the api lane" '[ "$rc" -eq 0 ] && [ "$(wc -l <"$TMP/out-api5/runs.jsonl" | tr -d " ")" = 1 ]'
rm -f "$APIENV"
LQ_FAKE_API_REFUSE=1 api_run "$TMP/out-api6" --no-judge --tasks cr-fix,class-sweep >"$TMP/api6.log" 2>&1
rc=$?
check "a launcher refusal is recorded as an error and stops the sweep" '[ "$(wc -l <"$TMP/out-api6/runs.jsonl" | tr -d " ")" = 1 ] && [ "$(jq -s ".[0].is_error" "$TMP/out-api6/runs.jsonl")" = true ] && grep -q "unknown" "$TMP/api6.log"'

# acceptance runs agent-written code; the API key must not be in its environment.
ACCENV="$TMP/accept.env"; rm -f "$ACCENV" "$APIENV"
LQ_FAKE_ACCEPTENV="$ACCENV" api_run "$TMP/out-api7" --no-judge --tasks cr-fix >"$TMP/api7.log" 2>&1
check "acceptance code ran (the env dump exists)" '[ -s "$ACCENV" ]'
check "acceptance runs without ANTHROPIC_API_KEY and the lane selectors" '[ -s "$ACCENV" ] && nogrep -q "^ANTHROPIC_API_KEY=" "$ACCENV" && nogrep -q "^HIMMEL_API_" "$ACCENV"'
# judge: accept.sh's direct parent (the timeout wrapper) must not carry the key either, so strip-env runs outside it.
mkdir -p "$TMP/tbin"; REALTIMEOUT="$(command -v timeout)"
printf '#!/usr/bin/env bash\ncase "$*" in *accept.sh*) env >"%s/timeout.env" ;; esac\nexec "%s" "$@"\n' "$TMP" "$REALTIMEOUT" >"$TMP/tbin/timeout"; chmod +x "$TMP/tbin/timeout"
rm -f "$TMP/timeout.env"
PATH="$TMP/tbin:$PATH" api_run "$TMP/out-api7b" --no-judge --tasks cr-fix >"$TMP/api7b.log" 2>&1
check "accept.sh's timeout parent carries no API key or lane selector" '[ -s "$TMP/timeout.env" ] && nogrep -q "^ANTHROPIC_API_KEY=" "$TMP/timeout.env" && nogrep -q "^HIMMEL_API_" "$TMP/timeout.env"'
# LQ_LANE_BIN must not replace the launcher on the api lane.
printf '#!/usr/bin/env bash\ntouch "%s/poison.ran"\nexit 0\n' "$TMP" >"$TMP/bin/poison"; chmod +x "$TMP/bin/poison"
rm -f "$APIENV" "$TMP/poison.ran"
LQ_LANE_BIN="$TMP/bin/poison" api_run "$TMP/out-api8" --no-judge --tasks cr-fix >"$TMP/api8.log" 2>&1
check "LQ_LANE_BIN does not replace the api launcher" '[ ! -e "$TMP/poison.ran" ] && [ -s "$APIENV" ]'
# judge B1: LQ_REPO pointing at a tree with its own launcher must not run that launcher.
rm -f "$APIENV" "$TMP/poison.ran"
api_run "$TMP/out-api9" --no-judge --tasks cr-fix >"$TMP/api9.log" 2>&1
check "LQ_REPO's launcher never runs on the api lane" '[ ! -e "$TMP/poison.ran" ] && [ -s "$APIENV" ]'

# judge B1 class sweep: the bank preflight (a LQ_PREFLIGHT / LQ_REPO-selected script) runs on the api lane too,
# so it must not hold the key either.
rm -f "$TMP/pf.env"
LQ_FAKE_PFENV="$TMP/pf.env" api_run "$TMP/out-api10" --no-judge --tasks cr-fix >"$TMP/api10.log" 2>&1
check "the bank preflight runs without the API key and lane selectors on the api lane" '[ -s "$TMP/pf.env" ] && nogrep -q "^ANTHROPIC_API_KEY=" "$TMP/pf.env" && nogrep -q "^HIMMEL_API_" "$TMP/pf.env"'

# judge B2: run.sh's own git calls (worktree add, the fixture commit, git add -A) fire hooks in an LQ_REPO-selected
# repo and an agent-written core.fsmonitor, so the key and lane selectors must not be in run.sh's environment at all.
rm -f "$TMP/hook.env" "$TMP/fsmon.env" "$APIENV"
mkdir -p "$TMP/repo/.git/hooks"  # a git built without templates (CI) has no hooks dir
for h in post-checkout reference-transaction post-index-change post-commit; do
  printf '#!/usr/bin/env bash\nenv >>"%s"\n' "$TMP/hook.env" >"$TMP/repo/.git/hooks/$h"; chmod +x "$TMP/repo/.git/hooks/$h"
done
LQ_FAKE_FSMON="$TMP/fsmon.env" api_run "$TMP/out-api11" --no-judge --tasks cr-fix >"$TMP/api11.log" 2>&1
for h in post-checkout reference-transaction post-index-change post-commit; do rm -f "$TMP/repo/.git/hooks/$h"; done
git -C "$TMP/repo" config --unset core.fsmonitor 2>/dev/null
check "a hook in LQ_REPO sees no API key or lane selector from run.sh's git calls" '[ -s "$TMP/hook.env" ] && nogrep -q "^ANTHROPIC_API_KEY=\|^HIMMEL_API_" "$TMP/hook.env"'
check "an agent-written core.fsmonitor sees no API key or lane selector" '[ -s "$TMP/fsmon.env" ] && nogrep -q "^ANTHROPIC_API_KEY=\|^HIMMEL_API_" "$TMP/fsmon.env"'
check "the launcher still receives the key and selectors" 'grep -q "^key=sk-ant-dummy-0000$" "$APIENV" && grep -q "^sel=on/B/key-b$" "$APIENV"'

# run.sh's base-sha check is a git call on LQ_REPO; in a partial clone a missing object makes git run
# the repo's core.sshCommand (a lazy fetch), so the key must be out of the environment before ANY git call on the repo.
LZ="$TMP/lzrepo"; rm -f "$TMP/lz.env"
git init -q "$LZ"; echo a >"$LZ/a"
git -C "$LZ" -c user.name=t -c user.email=t@t add -A
git -C "$LZ" -c user.name=t -c user.email=t@t commit -qm base
git -C "$LZ" config core.repositoryformatversion 1
git -C "$LZ" config extensions.partialClone origin
git -C "$LZ" config remote.origin.url ssh://evil.invalid/x.git
git -C "$LZ" config remote.origin.promisor true
printf '#!/usr/bin/env bash\nenv >>"%s"\nexit 1\n' "$TMP/lz.env" >"$TMP/lzssh"; chmod +x "$TMP/lzssh"
git -C "$LZ" config core.sshCommand "$TMP/lzssh"
LQ_REPO="$LZ" LQ_BASE_SHA=1111111111111111111111111111111111111111 api_run "$TMP/out-lz1" --no-judge --dry-run --tasks cr-fix >"$TMP/lz1.log" 2>&1
check "a partial-clone lazy fetch from the base-sha check sees no API key or lane selector" '[ -s "$TMP/lz.env" ] && nogrep -q "^ANTHROPIC_API_KEY=\|^HIMMEL_API_" "$TMP/lz.env"'

# an exported LQ_API_KEY (even empty) on entry must not stay exported: hooks, the preflight and
# accept.sh would inherit it.
for v in "" leak-lq-key; do
  rm -f "$TMP/hook.env" "$TMP/pf.env" "$ACCENV" "$APIENV"
  for h in post-checkout reference-transaction; do
    printf '#!/usr/bin/env bash\nenv >>"%s"\n' "$TMP/hook.env" >"$TMP/repo/.git/hooks/$h"; chmod +x "$TMP/repo/.git/hooks/$h"
  done
  LQ_API_KEY="$v" LQ_API_ACCOUNT="$v" LQ_API_KEY_ID="$v" LQ_FAKE_PFENV="$TMP/pf.env" LQ_FAKE_ACCEPTENV="$ACCENV" \
    api_run "$TMP/out-lq1" --no-judge --tasks cr-fix >"$TMP/lq1.log" 2>&1
  for h in post-checkout reference-transaction; do rm -f "$TMP/repo/.git/hooks/$h"; done
  check "an inherited exported LQ_API_KEY ('$v') reaches no hook, preflight or acceptance code" '[ -s "$TMP/hook.env" ] && [ -s "$TMP/pf.env" ] && [ -s "$ACCENV" ] && nogrep -q "^LQ_API_" "$TMP/hook.env" "$TMP/pf.env" "$ACCENV"'
  check "the launcher still receives the key after an inherited LQ_API_KEY ('$v')" 'grep -q "^key=sk-ant-dummy-0000$" "$APIENV"'
done

# run --config FILE seam (tasks_dir under this dir, base_sha, transcripts).
printf '{"tasks_dir":"../../../etc"}' >"$TMP/cfg-out.json"
bash "$RUN" run --lane native --model haiku --config "$TMP/cfg-out.json" --out "$TMP/out-cfg1" >"$TMP/cfg1.log" 2>&1
rc=$?
check "--config refuses a tasks_dir outside the harness dir" '[ "$rc" -eq 64 ] && grep -q "must stay under" "$TMP/cfg1.log"'
printf '{"base_sha":"nothex"}' >"$TMP/cfg-sha.json"
bash "$RUN" run --lane native --model haiku --config "$TMP/cfg-sha.json" --out "$TMP/out-cfg2" >"$TMP/cfg2.log" 2>&1
rc=$?
check "--config refuses a malformed base_sha" '[ "$rc" -eq 64 ] && grep -q "40 hex" "$TMP/cfg2.log"'
printf '{"tasks_dir":"tasks","base_sha":"%s","transcripts":"%s"}' "$BASE" "$TMP/projects" >"$TMP/cfg-ok.json"
bash "$RUN" run --lane native --model haiku --tasks cr-fix --no-judge --config "$TMP/cfg-ok.json" --out "$TMP/out-cfg3" >"$TMP/cfg3.log" 2>&1
rc=$?
check "--config with a valid tasks_dir, base_sha and transcripts runs" '[ "$rc" -eq 0 ] && [ "$(wc -l <"$TMP/out-cfg3/runs.jsonl" | tr -d " ")" = 1 ]'
check "--config base_sha is the one recorded" '[ "$(jq -s -r ".[0].base_sha" "$TMP/out-cfg3/runs.jsonl")" = "$BASE" ]'

# exported exit/return/unset shadows must never reach the agent or
# judge launch. The control (no ambient proxy) proves the shadowed runner still
# launches, so the proxied run staying empty is not vacuous.
shadow_lq() { # <proxy-url|-> <outdir>
  : >"$TMP/fake.log"
  # shellcheck disable=SC2016
  bash -c '
    exit() { :; }; return() { :; }; unset() { :; }; export -f exit return unset
    [ "$1" = - ] && p=() || p=(ANTHROPIC_BASE_URL="$1")
    exec env "${p[@]}" bash "$2" run --lane native --model m --tasks shell-red-green --out "$3"' _ "$1" "$RUN" "$2" >"$TMP/shadow.log" 2>&1
}
shadow_lq - "$TMP/out-shadow-ctl"
check "shadowed exit/return/unset, no proxy: the runner still launches (control)" '[ -s "$TMP/fake.log" ]'
shadow_lq http://evil.invalid "$TMP/out-shadow-px"
check "shadowed exit/return/unset + ambient ANTHROPIC_BASE_URL: nothing is launched" '[ ! -s "$TMP/fake.log" ]'

# openrouter (phase 2): the agent goes through the lane launcher, the judge
# stays native, and the metered balance is read before and after each task.
printf '#!/usr/bin/env bash\necho "$*" >>"$LQ_FAKE_LOG.launcher"\nexec "$LQ_CLAUDE_BIN" "$@"\n' >"$TMP/bin/claude-openrouter"
printf '#!/usr/bin/env bash\necho "balance=8.9070935:credit spend=?"\n' >"$TMP/bin/orcost"
chmod +x "$TMP/bin/claude-openrouter" "$TMP/bin/orcost"
: >"$TMP/fake.log.launcher"
# Claude Code misprices an unrecognized gateway slug, so the harness reprices
# modelUsage at list rates: 50k in, 4k out, 16k cache-write, 100k cache-read
# at Haiku 4.5 rates is 0.10 USD (0.12 with the 1.2 metered markup), against
# a reported 0.50.
MU_HAIKU='{"anthropic/claude-haiku-4.5":{"inputTokens":50000,"outputTokens":4000,"cacheCreationInputTokens":16000,"cacheReadInputTokens":100000}}'
LQ_FAKE_MU="$MU_HAIKU" LQ_LANE_BIN="$TMP/bin/claude-openrouter" LQ_METERED_PROBE="$TMP/bin/orcost" bash "$RUN" run --lane openrouter \
  --model haiku --tasks shell-red-green --max-usd 2 --out "$TMP/out15" >"$TMP/run15.log" 2>&1
rc=$?
check "openrouter lane runs" '[ "$rc" -eq 0 ] && [ "$(wc -l <"$TMP/out15/runs.jsonl" | tr -d " ")" = 1 ]'
check "openrouter agent goes through the lane launcher" 'grep -q -- "--permission-mode auto" "$TMP/fake.log.launcher"'
check "openrouter judge stays native" 'nogrep -q -- "--json-schema" "$TMP/fake.log.launcher" && [ "$(jq -s ".[0].judge.correctness" "$TMP/out15/runs.jsonl")" = 4 ]'
check "metered balance recorded" '[ "$(jq -s -r ".[0].metered_before" "$TMP/out15/runs.jsonl")" = 8.9070935 ]'
check "native rows carry no metered balance" '[ "$(jq -s ".[0].metered_before" "$R")" = null ]'
check "openrouter cost repriced from modelUsage" 'jq -s ".[0].cost_usd" "$TMP/out15/runs.jsonl" | awk "{exit !(\$1 > 0.1199 && \$1 < 0.1201)}" && [ "$(jq -s ".[0].reported_cost_usd" "$TMP/out15/runs.jsonl")" = 0.5 ]'
check "openrouter outer budget scaled by a logged factor" 'grep -q -- "--max-budget-usd 8.00" "$TMP/fake.log.launcher" && grep -q "budget factor 4" "$TMP/run15.log"'
: >"$TMP/fake.log.launcher"
LQ_LANE_BIN="$TMP/bin/claude-openrouter" LQ_METERED_PROBE="$TMP/bin/orcost" bash "$RUN" run --lane openrouter \
  --model sonnet --tasks shell-red-green --out "$TMP/out17" >"$TMP/run17.log" 2>&1
check "openrouter refuses an unpriced model before launch" 'grep -q "haiku only" "$TMP/run17.log" && [ ! -s "$TMP/fake.log.launcher" ]'
LQ_FAKE_MU='{"x/unpriced":{"inputTokens":1,"outputTokens":1,"cacheCreationInputTokens":0,"cacheReadInputTokens":0}}' \
  LQ_LANE_BIN="$TMP/bin/claude-openrouter" LQ_METERED_PROBE="$TMP/bin/orcost" bash "$RUN" run --lane openrouter \
  --model haiku --tasks shell-red-green,finding-verify --max-usd 2 --out "$TMP/out16" >"$TMP/run16.log" 2>&1
check "an unpriced openrouter model stops the sweep" '[ "$(wc -l <"$TMP/out16/runs.jsonl" | tr -d " ")" = 1 ] && grep -q "cost unknown" "$TMP/run16.log"'
check "a stopped sweep records a partial eval-runs row" '[ "$(jq -s -r "map(select(.artifact | contains(\"/out16/\")))[0].status" "$HIMMEL_EVAL_RUNS_LEDGER")" = partial ]'
# 25k input tokens is 0.025 USD at list, so a reported 0.50 is 20x, not the 5x
# the per-call factor relies on: the cost is unknown and the sweep stops.
LQ_FAKE_MU='{"anthropic/claude-haiku-4.5":{"inputTokens":25000,"outputTokens":0,"cacheCreationInputTokens":0,"cacheReadInputTokens":0}}' \
  LQ_LANE_BIN="$TMP/bin/claude-openrouter" LQ_METERED_PROBE="$TMP/bin/orcost" bash "$RUN" run --lane openrouter \
  --model haiku --tasks shell-red-green,finding-verify --max-usd 2 --out "$TMP/out18" >"$TMP/run18.log" 2>&1
check "an off-ratio reported cost stops the openrouter sweep" '[ "$(wc -l <"$TMP/out18/runs.jsonl" | tr -d " ")" = 1 ] && grep -q "cost unknown" "$TMP/run18.log"'
# Zero priced tokens or no reported cost leaves the 5x ratio unchecked, so the
# cost is unknown and the sweep stops.
LQ_FAKE_MU='{"anthropic/claude-haiku-4.5":{"inputTokens":0,"outputTokens":0,"cacheCreationInputTokens":0,"cacheReadInputTokens":0}}' \
  LQ_LANE_BIN="$TMP/bin/claude-openrouter" LQ_METERED_PROBE="$TMP/bin/orcost" bash "$RUN" run --lane openrouter \
  --model haiku --tasks shell-red-green,finding-verify --max-usd 2 --out "$TMP/out19" >"$TMP/run19.log" 2>&1
check "a zero-token openrouter run stops the sweep" '[ "$(wc -l <"$TMP/out19/runs.jsonl" | tr -d " ")" = 1 ] && grep -q "cost unknown" "$TMP/run19.log"'
LQ_FAKE_NOCOST=1 LQ_FAKE_MU='{"anthropic/claude-haiku-4.5":{"inputTokens":25000,"outputTokens":4000,"cacheCreationInputTokens":0,"cacheReadInputTokens":0}}' \
  LQ_LANE_BIN="$TMP/bin/claude-openrouter" LQ_METERED_PROBE="$TMP/bin/orcost" bash "$RUN" run --lane openrouter \
  --model haiku --tasks shell-red-green,finding-verify --max-usd 2 --out "$TMP/out20" >"$TMP/run20.log" 2>&1
check "a missing reported cost stops the openrouter sweep" '[ "$(wc -l <"$TMP/out20/runs.jsonl" | tr -d " ")" = 1 ] && grep -q "cost unknown" "$TMP/run20.log"'
: >"$TMP/fake.log"
LQ_FAKE_PROCEED_N=1 LQ_FAKE_CALLS="$TMP/calls" bash "$RUN" run --lane native --model m --tasks shell-red-green \
  --no-judge --out "$TMP/out14" >"$TMP/run14.log" 2>&1
rc=$?
check "a bank refusal during task setup launches no agent" '[ "$rc" -eq 75 ] && [ ! -s "$TMP/fake.log" ]'

start=$(date +%s)
LQ_FAKE_HANG=1 LQ_FAKE_COMMIT=1 bash "$RUN" run --lane native --model m --tasks shell-red-green --timeout 3 \
  --no-judge --out "$TMP/out4" >"$TMP/run4.log" 2>&1
took=$(( $(date +%s) - start ))
R4="$TMP/out4/runs.jsonl"
check "a hanging candidate is cut off by the timeout" '[ "$took" -lt 25 ]'
check "a killed acceptance run still records its row" '[ "$(wc -l <"$R4" 2>/dev/null | tr -d " ")" = 1 ]'
check "a killed acceptance run is not ok" '[ "$(jq -s ".[0].accept_ok" "$R4")" = false ]'
check "a committed out-of-scope file is caught" '[ "$(jq -s -r ".[0].out_of_scope[0]" "$R4")" = stray.txt ]'

: >"$TMP/fake.log.judge"
LQ_FAKE_DRAIN="$TMP/drain" bash "$RUN" run --lane native --model m --tasks shell-red-green,finding-verify \
  --out "$TMP/out5" >"$TMP/run5.log" 2>&1
rc=$?
check "a bank drained mid-task skips the judge" '[ ! -s "$TMP/fake.log.judge" ] && [ "$(jq -s ".[0].judge" "$TMP/out5/runs.jsonl")" = null ]'
check "a bank drained mid-task stops the sweep" '[ "$rc" -eq 75 ] && [ "$(wc -l <"$TMP/out5/runs.jsonl" | tr -d " ")" = 1 ]'

: >"$TMP/blocked"
LQ_WORK_ROOT="$TMP/blocked" bash "$RUN" run --lane native --model m --tasks shell-red-green --no-judge \
  --out "$TMP/out6" >"$TMP/run6.log" 2>&1
rc=$?
check "a failed worktree add fails the sweep" '[ "$rc" -ne 0 ] && nogrep -q "lane-quality: done" "$TMP/run6.log"'

RO="$TMP/ro"
git init -q "$RO" && git -C "$RO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
chmod -R a-w "$RO/.git/objects"
bash "$RUN" materialize finding-verify "$RO" >"$TMP/mat.log" 2>&1
rc=$?
chmod -R u+w "$RO/.git/objects"
check "a fixture that cannot be committed fails materialize" '[ "$rc" -ne 0 ]'

: >"$TMP/fake.log.judge"
bash "$RUN" run --lane native --model m --tasks shell-red-green --max-usd 0.5 --out "$TMP/out7" >"$TMP/run7.log" 2>&1
check "no judge call once the agent spent the whole budget" '[ ! -s "$TMP/fake.log.judge" ] && [ "$(jq -s ".[0].judge" "$TMP/out7/runs.jsonl")" = null ]'

start=$(date +%s)
LQ_FAKE_JUDGE_HANG=1 bash "$RUN" run --lane native --model m --tasks shell-red-green,finding-verify --timeout 3 \
  --out "$TMP/out8" >"$TMP/run8.log" 2>&1
took=$(( $(date +%s) - start ))
check "a hanging judge is cut off by the timeout" '[ "$took" -lt 9 ] && [ "$(wc -l <"$TMP/out8/runs.jsonl" | tr -d " ")" = 1 ]'
check "a judge of unknown cost stops the sweep" 'grep -q "cost unknown" "$TMP/run8.log"'

(cd "$TMP" && bash "$RUN" run --lane native --model m --tasks shell-red-green --out out10) >"$TMP/run10.log" 2>&1
check "a relative --out still reaches the judge" '[ "$(jq -s ".[0].judge.correctness" "$TMP/out10/runs.jsonl")" = 4 ]'

LQ_FAKE_NOJSON=1 bash "$RUN" run --lane native --model m --tasks shell-red-green,finding-verify --no-judge \
  --out "$TMP/out9" >"$TMP/run9.log" 2>&1
check "an agent run of unknown cost stops the sweep" '[ "$(wc -l <"$TMP/out9/runs.jsonl" | tr -d " ")" = 1 ] && grep -q "cost unknown" "$TMP/run9.log"'
: >"$TMP/fake.log.judge"
LQ_FAKE_NOJSON=1 bash "$RUN" run --lane native --model m --tasks shell-red-green --out "$TMP/out11" >"$TMP/run11.log" 2>&1
check "no judge call after an agent run of unknown cost" '[ ! -s "$TMP/fake.log.judge" ] && [ "$(jq -s ".[0].judge" "$TMP/out11/runs.jsonl")" = null ]'

if bash "$RUN" run --lane native --model m --tasks shell-red-green --no-judge --timeout 0 --out "$TMP/out12" >"$TMP/run12.log" 2>&1; then
  bad "--timeout 0 is refused"
else check "--timeout 0 is refused" '[ ! -s "$TMP/out12/runs.jsonl" ]'; fi

mkdir -p "$TMP/out13/runs.jsonl"
if bash "$RUN" run --lane native --model m --tasks shell-red-green --no-judge --out "$TMP/out13" >"$TMP/run13.log" 2>&1; then
  bad "an unrecordable row fails the sweep"
else ok "an unrecordable row fails the sweep"; fi

echo "4. table"
bash "$RUN" table "$TMP/out1" >"$TMP/table.md" 2>&1
check "table has a row per task" '[ "$(grep -c "| native | claude-haiku-4-5 |" "$TMP/table.md")" -ge 2 ]'
check "table has a header" 'grep -q "^| lane | model | task |" "$TMP/table.md"'

echo "5. repeats, bootstrap CIs and judge calibration (HIMMEL-4648)"
: >"$TMP/fake.log.judge"
bash "$RUN" run --lane native --model m --tasks shell-red-green,finding-verify --reps 2 --max-usd 9 \
  --out "$TMP/out21" >"$TMP/run21.log" 2>&1
rc=$?
R21="$TMP/out21/runs.jsonl"
check "--reps 2 runs every task twice" '[ "$rc" -eq 0 ] && [ "$(jq -s -r "map(\"\(.task):\(.rep)\") | sort | join(\",\")" "$R21")" = "finding-verify:1,finding-verify:2,shell-red-green:1,shell-red-green:2" ]'
check "a repeat keeps its own judge packet" '[ -s "$TMP/out21/shell-red-green.judge-packet.md" ] && [ -s "$TMP/out21/shell-red-green.r2.judge-packet.md" ]'
check "rows record the judge model" '[ "$(jq -s -r ".[0].judge_model" "$R21")" = opus ]'
L21="$(jq -sc "map(select(.artifact | contains(\"/out21/\")))[0]" "$EL")"
check "the ledger row carries reps 2 and n = distinct tasks" '[ "$(jq -r "\"\(.reps) \(.n) \(.config.tasks | length)\"" <<<"$L21")" = "2 2 2" ]'
check "the ledger row carries a bootstrap 95% CI per task and criterion" 'jq -e ".ci_level == 0.95 and .ci_method == \"bootstrap-percentile\" and .ci[\"shell-red-green.judge_correctness\"].lo == 4 and .ci.judge_correctness.hi == 4" <<<"$L21" >/dev/null'
check "a ledger row with reps validates" 'python3 "$HERE/../lib/eval_runs.py" validate "$EL" >/dev/null'
for v in 0 x; do
  if bash "$RUN" run --lane native --model m --tasks shell-red-green --reps "$v" --out "$TMP/out-reps-$v" >/dev/null 2>&1; then
    bad "--reps $v is refused"
  else ok "--reps $v is refused"; fi
done

# Fixture rows, no model call: task a passes twice (judge 4 then 5), task b
# fails three times (judge 2, 4, and one row with no judge score).
FX="$TMP/fx1"; mkdir -p "$FX"
fxrow() { # task rep accept_ok correctness|null
  jq -nc --arg t "$1" --argjson r "$2" --argjson ok "$3" --argjson c "$4" '{run_id:"fx", lane:"native", model:"m", effort:"", task:$t, rep:$r,
    base_sha:"b", accept_passed:(if $ok then 1 else 0 end), accept_total:1, accept_ok:$ok, scope_ok:true, judge_model:"opus",
    judge:(if $c == null then null else {correctness:$c, scope_discipline:4, test_quality:3, honesty:4, notes:"n"} end)}'
}
{ fxrow a 1 true 4; fxrow a 2 true 5; fxrow b 1 false 2; fxrow b 2 false 4; fxrow b 3 false null; } >"$FX/runs.jsonl"
for s in a a.r2 b b.r2; do echo "packet $s" >"$FX/$s.judge-packet.md"; done

bash "$RUN" table "$FX" >"$TMP/table-fx.md" 2>&1
check "table reports mean and bootstrap 95% CI per task and criterion" 'grep -E "^\| native \| m \| a \| 2 \|" "$TMP/table-fx.md" | grep -q "4.50 \[4.00, 5.00\]"'
check "a constant criterion has a zero-width CI" 'grep -E "^\| native \| m \| a \| 2 \|" "$TMP/table-fx.md" | grep -q "4.00 \[4.00, 4.00\]"'
check "a missing judge score is counted, not dropped" 'grep -E "^\| native \| m \| b \| 3 \|" "$TMP/table-fx.md" | grep -q "3.00 \[2.00, 4.00\]" && grep -E "^\| native \| m \| b \| 3 \|" "$TMP/table-fx.md" | grep -qE "\| 1 \|$"'

python3 "$HERE/../lib/eval_runs.py" lane-quality "$FX" --run-id fx --ledger "$TMP/fx-ledger.jsonl" >/dev/null 2>&1
FXL="$TMP/fx-ledger.jsonl"
check "fixture ledger row: per-task CI and missing count" 'jq -e ".ci[\"a.judge_correctness\"] == {lo: 4, hi: 5} and .metrics[\"b.judge_missing\"] == 1 and .metrics.judge_missing == 1 and .reps == 3 and .n == 2" "$FXL" >/dev/null'
check "fixture ledger cases are per-task means" '[ "$(jq -r ".cases.a.judge_correctness" "$FXL")" = 4.5 ]'

# Calibration math, by hand: correctness on accept-pass {4,5} vs accept-fail
# {2,4} -> AUC 3.5/4 = 0.875; point-biserial r = 1.5 / sqrt(4.75) = 0.6882.
bash "$RUN" calibration "$FX" --json --no-ledger >"$TMP/cal.json" 2>"$TMP/cal.err"
check "calibration: AUC of correctness against accept_ok" 'jq -e ".metrics.auc_correctness == 0.875" "$TMP/cal.json" >/dev/null'
check "calibration: point-biserial of correctness against accept_ok" 'jq ".metrics.pb_correctness" "$TMP/cal.json" | awk "{v = \$1} END {exit !(NR == 1 && v > 0.6882 && v < 0.6883)}"'
check "calibration counts the row with no judge score" 'jq -e ".metrics.judge_missing == 1 and .n == 4" "$TMP/cal.json" >/dev/null'
check "calibration without a second judge reports no kappa" 'jq -e ".metrics | has(\"kappa_correctness\") and .kappa_correctness == null" "$TMP/cal.json" >/dev/null'
check "the calibration report prints its table" 'bash "$RUN" calibration "$FX" --no-ledger 2>/dev/null | grep -qF "| correctness | 0.875 ["'
check "one judge score beside a missing one gets no CI" 'python3 -c "import sys; sys.path.insert(0, sys.argv[1]); import eval_runs as e; s = e.lane_quality_stats([{\"task\": \"x\", \"judge\": {\"correctness\": 3}}, {\"task\": \"x\"}])[\"x\"]; sys.exit(not (s[\"judge_correctness\"][\"ci\"] is None and s[\"judge_missing\"] == 1))" "$HERE/../lib"'
check "a calibration with only one class reports no AUC" 'jq -c "select(.accept_ok)" "$FX/runs.jsonl" >"$TMP/one.jsonl" && mkdir -p "$TMP/fx-one" && mv "$TMP/one.jsonl" "$TMP/fx-one/runs.jsonl" && bash "$RUN" calibration "$TMP/fx-one" --json --no-ledger | jq -e ".metrics.auc_correctness == null" >/dev/null'

# Weighted kappa (quadratic) by hand: identical raters 1, independent 0,
# reversed extremes -1.
kap() { python3 -c 'import sys,json; sys.path.insert(0, sys.argv[1]); import lq_stats; print(lq_stats.weighted_kappa(json.loads(sys.argv[2]), json.loads(sys.argv[3])))' "$HERE" "$1" "$2"; }
check "weighted kappa: identical raters = 1" '[ "$(kap "[1,2,3,4,5]" "[1,2,3,4,5]")" = 1.0 ]'
check "weighted kappa: independent raters = 0" '[ "$(kap "[1,1,2,2]" "[1,2,1,2]")" = 0.0 ]'
check "weighted kappa: reversed extremes = -1" '[ "$(kap "[1,5]" "[5,1]")" = -1.0 ]'

: >"$TMP/fake.log"; : >"$TMP/fake.log.judge"
bash "$RUN" calibration "$FX" --judge2-model sonnet --judge2-effort low --json --max-usd 1 >"$TMP/cal2.json" 2>"$TMP/cal2.err"
rc=$?
check "second-judge pass judges every stored packet once" '[ "$rc" -eq 0 ] && [ "$(grep -c -- "--json-schema" "$TMP/fake.log")" = 4 ]'
check "second judge uses the given model and effort, budget-capped, no tools" 'grep -- "--json-schema" "$TMP/fake.log" | grep -- "--model sonnet" | grep -- "--effort low" | grep -q -- "--max-budget-usd"'
check "second judge rescores the stored packet" 'grep -q "packet a.r2" "$TMP/fake.log.judge"'
check "second judge result stored per row" '[ -s "$FX/a.r2.judge2.sonnet__low.json" ]'
check "weighted kappa against a constant second judge is 0" 'jq -e ".metrics.kappa_correctness == 0 and .metrics.n_kappa == 4" "$TMP/cal2.json" >/dev/null'
check "calibration writes a valid eval-runs row" '[ "$(jq -s -r "map(select(.eval == \"lane-quality-calibration\")) | length" "$EL")" = 1 ] && python3 "$HERE/../lib/eval_runs.py" validate "$EL" >/dev/null'
: >"$TMP/fake.log"
bash "$RUN" calibration "$FX" --judge2-model sonnet --judge2-effort low --json --no-ledger >"$TMP/cal3.json" 2>/dev/null
check "a stored second-judge result is reused, never re-judged" 'nogrep -q -- "--json-schema" "$TMP/fake.log" && jq -e ".metrics.n_kappa == 4" "$TMP/cal3.json" >/dev/null'
: >"$FX/a.r2.judge2.sonnet__low.json"; : >"$TMP/fake.log"
bash "$RUN" calibration "$FX" --judge2-model sonnet --judge2-effort low --json --no-ledger >/dev/null 2>&1
check "an empty second-judge result is judged again" '[ "$(grep -c -- "--json-schema" "$TMP/fake.log")" = 1 ] && [ -s "$FX/a.r2.judge2.sonnet__low.json" ]'
# model "a-b" with no effort and model "a" at effort "b" once
# shared one label, so the second silently reused the first's scores.
: >"$TMP/fake.log"
bash "$RUN" calibration "$FX" --judge2-model a-b --json --no-ledger >/dev/null 2>&1
bash "$RUN" calibration "$FX" --judge2-model a --judge2-effort b --json --no-ledger >/dev/null 2>&1
check "colliding second-judge configurations each make their own calls" '[ "$(grep -- "--json-schema" "$TMP/fake.log" | grep -c -- "--model a-b")" = 4 ] && [ "$(grep -- "--json-schema" "$TMP/fake.log" | grep -- "--model a " | grep -c -- "--effort b")" = 4 ]'
: >"$TMP/fake.log"
bash "$RUN" calibration "$FX" --judge2-model a --judge2-effort b --json --no-ledger >"$TMP/cal-ab.json" 2>/dev/null
check "an exact rerun of either configuration reuses its stored result" 'nogrep -q -- "--json-schema" "$TMP/fake.log" && jq -e ".metrics.n_kappa == 4" "$TMP/cal-ab.json" >/dev/null'
: >"$TMP/fake.log"
LQ_FAKE_TOKEN=SKIPPED-BANK bash "$RUN" calibration "$FX" --judge2-model haiku --json --no-ledger >/dev/null 2>&1
rc=$?
check "a bank refusal stops the second-judge pass before any call" '[ "$rc" -eq 75 ] && [ ! -s "$TMP/fake.log" ]'
mkdir -p "$TMP/rel/fxr" && cp "$FX/runs.jsonl" "$FX"/*.judge-packet.md "$TMP/rel/fxr/"
: >"$TMP/fake.log.judge"
(cd "$TMP/rel" && bash "$RUN" calibration fxr --judge2-model haiku --json --no-ledger >/dev/null 2>&1)
rc=$?
check "a relative run dir still feeds the second judge its packet" '[ "$rc" -eq 0 ] && grep -q "packet b.r2" "$TMP/fake.log.judge"'
# a failed judge launch fails judge_call (not the cleanup's rc 0),
# and --timeout 00 is refused (GNU timeout 00 would disable the cap).
printf '#!/usr/bin/env bash\necho "judge launch failed" >&2\nexit 3\n' >"$TMP/bin/claude-fail"; chmod +x "$TMP/bin/claude-fail"
LQ_CLAUDE_BIN="$TMP/bin/claude-fail" bash "$RUN" calibration "$FX" --judge2-model opus --json --no-ledger >/dev/null 2>"$TMP/cal-fail.err"
rc=$?
check "a failing second judge makes calibration die with its message" '[ "$rc" -eq 64 ] && grep -q "cannot run the second judge" "$TMP/cal-fail.err"'
bash "$RUN" calibration "$FX" --timeout 00 --json --no-ledger >/dev/null 2>"$TMP/cal-t00.err"
rc=$?
check "calibration refuses --timeout 00" '[ "$rc" -eq 64 ] && grep -q -- "--timeout must be positive" "$TMP/cal-t00.err"'
check "weighted kappa ignores a pair off the 1..5 scale" '[ "$(kap "[1,2,6]" "[1,2,3]")" = 1.0 ]'

echo "6. runner polish (HIMMEL-4264)"
# a: two runs in one second get distinct run ids (the clock is pinned to prove it)
mkdir -p "$TMP/fdate"
printf '#!/usr/bin/env bash\ncase "$*" in *%%Y%%m%%d*) echo 20260101T000000Z ;; *) exec "%s" "$@" ;; esac\n' "$(command -v date)" >"$TMP/fdate/date"
chmod +x "$TMP/fdate/date"
for i in 1 2; do
  PATH="$TMP/fdate:$PATH" bash "$RUN" run --lane native --model m --tasks cr-fix --no-judge --out "$TMP/out-id$i" >"$TMP/id$i.log" 2>&1
done
check "two runs in the same second get distinct run ids" '[ -s "$TMP/out-id1/runs.jsonl" ] && [ -s "$TMP/out-id2/runs.jsonl" ] && [ "$(jq -r .run_id "$TMP/out-id1/runs.jsonl")" != "$(jq -r .run_id "$TMP/out-id2/runs.jsonl")" ]'
# b: an over-60KB diff is cut with a visible marker; a small one is not
: >"$TMP/fake.log.judge"
LQ_FAKE_BIG=1 bash "$RUN" run --lane native --model m --tasks shell-red-green --out "$TMP/out-tr" >"$TMP/tr.log" 2>&1
check "an over-60KB judge packet carries the truncation marker" 'grep -qF "[truncated at 60000 bytes]" "$TMP/out-tr/shell-red-green.judge-packet.md"'
check "a small judge packet carries no truncation marker" '[ -s "$TMP/out10/shell-red-green.judge-packet.md" ] && nogrep -qF "[truncated" "$TMP/out10/shell-red-green.judge-packet.md"'
# c: a sweep stopped on unknown cost exits non-zero and still writes its partial ledger row
LQ_FAKE_NOJSON=1 bash "$RUN" run --lane native --model m --tasks shell-red-green,finding-verify --no-judge --out "$TMP/out-uc" >"$TMP/uc.log" 2>&1
rc=$?
check "a sweep stopped on unknown cost exits 76" '[ "$rc" -eq 76 ]'
check "an unknown-cost stop keeps a partial eval-runs row" '[ "$(jq -s -r "map(select((.artifact // \"\") | contains(\"/out-uc/\")))[0].status" "$EL")" = partial ]'
bash "$RUN" run --lane native --model m --tasks shell-red-green,finding-verify,cr-fix --max-usd 0.6 --no-judge --out "$TMP/out-cap" >"$TMP/cap.log" 2>&1
rc=$?
check "a budget-cap stop still exits 0" '[ "$rc" -eq 0 ] && grep -q "budget cap reached" "$TMP/cap.log"'
# d: bank-after is read after the judge call
rm -f "$TMP/h5seq" "$TMP/h5seq.atjudge"
LQ_FAKE_5HSEQ="$TMP/h5seq" bash "$RUN" run --lane native --model m --tasks shell-red-green --out "$TMP/out-bk" >"$TMP/bk.log" 2>&1
check "bank-after is read after the judge ran" '[ -s "$TMP/h5seq.atjudge" ] && awk -v a="$(jq -s -r ".[0].bank_5h_after" "$TMP/out-bk/runs.jsonl")" -v j="$(cat "$TMP/h5seq.atjudge")" "BEGIN{exit !(a + 0 > j + 0)}"'
# e: the literal --model and --judge-model values never reach the judge; a lookalike (dot is not a wildcard) stays
: >"$TMP/fake.log.judge"
LQ_FAKE_SAY=' ran vendor/zz.v2, judged by judgemodel-q; vendorXzzYv2 stays.' \
  bash "$RUN" run --lane native --model vendor/zz.v2 --judge-model judgemodel-q --tasks shell-red-green --out "$TMP/out-rd" >"$TMP/rd.log" 2>&1
check "the literal --model and --judge-model values are redacted from the packet" '[ -s "$TMP/fake.log.judge" ] && nogrep -qF "vendor/zz.v2" "$TMP/fake.log.judge" && nogrep -qF "judgemodel-q" "$TMP/fake.log.judge"'
check "redaction matches the model literally, not as a pattern" 'grep -qF "vendorXzzYv2" "$TMP/fake.log.judge"'
# f: a grep error (rc 2) is not absence
check "nogrep fails on a grep error and passes on no match" 'type nogrep >/dev/null 2>&1 && ! nogrep -q x "$TMP/no-such-file" && printf y >"$TMP/nogrep.t" && nogrep -q x "$TMP/nogrep.t"'
# g: table takes a run directory with a space in its path
mkdir -p "$TMP/sp ace" && cp "$TMP/out1/runs.jsonl" "$TMP/sp ace/runs.jsonl"
bash "$RUN" table "$TMP/sp ace" >"$TMP/table-sp.md" 2>&1
rc=$?
check "table renders a run directory whose path has a space" '[ "$rc" -eq 0 ] && [ "$(grep -c "| native | claude-haiku-4-5 |" "$TMP/table-sp.md")" -ge 2 ]'

echo "5. steering variants (HIMMEL-5633)"
printf 'VARIANT-A4 steering text\n' >"$TMP/v-a4.md"
printf 'VARIANT-A6 BREAK steering text\n' >"$TMP/v-a6.md"
: >"$TMP/fake.log.claudemd"
bash "$RUN" run --lane native --model m --tasks shell-red-green --no-judge --steering-variant A4="$TMP/v-a4.md" --out "$TMP/out-v1" >"$TMP/v1.log" 2>&1
rc=$?
check "a run given a steering variant exits 0" '[ "$rc" -eq 0 ]'
check "the row records the variant name" '[ "$(jq -s -r ".[0].variant" "$TMP/out-v1/runs.jsonl")" = A4 ]'
check "the agent started with the variant as CLAUDE.md" 'grep -q "VARIANT-A4 steering text" "$TMP/fake.log.claudemd"'
check "the variant file is not counted as agent scope drift" '[ "$(jq -s -r ".[0].scope_ok" "$TMP/out-v1/runs.jsonl")" = true ]'
check "a run without a variant records variant null" '[ "$(jq -s -r ".[0].variant" "$TMP/out1/runs.jsonl")" = null ]'
bash "$RUN" run --lane native --model m --tasks shell-red-green --no-judge --steering-variant A6="$TMP/v-a6.md" --out "$TMP/out-v2" >"$TMP/v2.log" 2>&1
bash "$RUN" run --lane native --model m --tasks shell-red-green --no-judge --out "$TMP/out-v0" >"$TMP/v0.log" 2>&1
bash "$RUN" verdict "$TMP/out-v0" "$TMP/out-v1" "$TMP/out-v2" >"$TMP/verdict.tsv" 2>"$TMP/verdict.err"
rc=$?
check "verdict exits 0" '[ "$rc" -eq 0 ]'
check "verdict emits one row per variant" '[ "$(wc -l <"$TMP/verdict.tsv" | tr -d " ")" = 2 ]'
check "a no-op variant gets an apply verdict" 'awk -F"\t" "\$1==\"A4\" && \$2==\"apply\"{f=1} END{exit !f}" "$TMP/verdict.tsv"'
check "a variant that fails acceptance gets a keep verdict" 'awk -F"\t" "\$1==\"A6\" && \$2==\"keep\"{f=1} END{exit !f}" "$TMP/verdict.tsv"'
bash "$RUN" run --lane native --model m --tasks shell-red-green --no-judge --steering-variant "A4=$TMP/no-such.md" --out "$TMP/out-v3" >"$TMP/v3.log" 2>&1
rc=$?
check "a missing variant file is refused" '[ "$rc" -ne 0 ] && grep -q "no such file" "$TMP/v3.log"'
LQ_FAKE_DISPATCH=1 bash "$RUN" run --lane native --model m --tasks shell-red-green --no-judge --out "$TMP/out-dp" >"$TMP/dp.log" 2>&1
check "subagent dispatches are counted" '[ "$(jq -s -r ".[0].dispatches" "$TMP/out-dp/runs.jsonl")" = 2 ]'
check "dispatches without an explicit model are counted" '[ "$(jq -s -r ".[0].dispatch_unnamed_model" "$TMP/out-dp/runs.jsonl")" = 1 ]'
check "a run with no dispatch counts zero" '[ "$(jq -s -r ".[0].dispatches" "$TMP/out-v0/runs.jsonl")" = 0 ]'
cat >"$TMP/rows-b.jsonl" <<'ROWS'
{"task":"t","rep":1,"accept_ok":true,"accept_passed":3,"scope_ok":true,"hook_denials":0,"dispatch_unnamed_model":0,"judge":null}
ROWS
cat >"$TMP/rows-v.jsonl" <<'ROWS'
{"task":"t","rep":1,"variant":"A4x","accept_ok":true,"accept_passed":3,"scope_ok":true,"hook_denials":0,"dispatch_unnamed_model":2,"judge":null}
ROWS
mkdir -p "$TMP/vd-b" "$TMP/vd-v" && cp "$TMP/rows-b.jsonl" "$TMP/vd-b/runs.jsonl" && cp "$TMP/rows-v.jsonl" "$TMP/vd-v/runs.jsonl"
check "a variant that dispatches without naming a model gets a keep verdict" 'bash "$RUN" verdict "$TMP/vd-b" "$TMP/vd-v" 2>/dev/null | awk -F"\t" "\$1==\"A4x\" && \$2==\"keep\" && /unnamed/{f=1} END{exit !f}"'
cp "$TMP/rows-v.jsonl" "$TMP/vd-v/runs.jsonl"
cat "$TMP/rows-b.jsonl" >>"$TMP/vd-v/runs.jsonl"
check "a run mixing variant and baseline rows is refused" '! bash "$RUN" verdict "$TMP/vd-b" "$TMP/vd-v" >/dev/null 2>&1'
mkdir -p "$TMP/vd-n" "$TMP/vd-m"
printf '%s\n' '{"task":"t","rep":1,"variant":"A4n","accept_ok":true,"accept_passed":3,"scope_ok":true,"hook_denials":null,"dispatch_unnamed_model":null,"judge":null}' >"$TMP/vd-n/runs.jsonl"
check "a variant with unrecorded metrics gets a keep verdict" 'bash "$RUN" verdict "$TMP/vd-b" "$TMP/vd-n" 2>/dev/null | awk -F"\t" "\$1==\"A4n\" && \$2==\"keep\" && /not recorded/{f=1} END{exit !f}"'
printf '%s\n' '{"task":"other","rep":1,"variant":"A4m","accept_ok":true,"accept_passed":3,"scope_ok":true,"hook_denials":0,"dispatch_unnamed_model":0,"judge":null}' >"$TMP/vd-m/runs.jsonl"
check "a variant run that omits a baseline task gets a keep verdict" 'bash "$RUN" verdict "$TMP/vd-b" "$TMP/vd-m" 2>/dev/null | awk -F"\t" "\$1==\"A4m\" && \$2==\"keep\" && /no variant row/{f=1} END{exit !f}"'
printf 'stand-in steering\n' >"$TMP/v-same.md"
bash "$RUN" run --lane native --model m --tasks shell-red-green --no-judge --steering-variant same="$TMP/v-same.md" --out "$TMP/out-same" >"$TMP/same.log" 2>&1
check "a variant identical to the pinned CLAUDE.md still runs" '[ "$(jq -s -r ".[0].variant" "$TMP/out-same/runs.jsonl")" = same ]'

# h: pair: one task at two base commits gives one paired row
echo "pair" >"$TMP/repo/pair.txt"
git -C "$TMP/repo" add -A
git -C "$TMP/repo" -c user.name=t -c user.email=t@t commit -qm pruned-arm
BASE2="$(git -C "$TMP/repo" rev-parse HEAD)"
LQ_BASE_SHA="$BASE2" bash "$RUN" run --lane native --model claude-haiku-4-5 --tasks shell-red-green --out "$TMP/out-pb" >"$TMP/run-pb.log" 2>&1
bash "$RUN" pair "$TMP/out1" "$TMP/out-pb" >"$TMP/pair.md" 2>&1
rc=$?
check "pair exits 0 and prints exactly one row for the one shared task" '[ "$rc" -eq 0 ] && [ "$(grep -c "^| shell-red-green |" "$TMP/pair.md")" -eq 1 ]'
check "the paired row carries success, tool calls and cost for both arms" 'grep "^| shell-red-green |" "$TMP/pair.md" | grep -q "| 1 → 1 | 2 → 2 | 0\.[0-9]* → 0\.[0-9]* |"'
check "a task only one arm ran is not paired" '[ "$(grep -c "^| finding-verify |" "$TMP/pair.md")" -eq 0 ]'
check "pair refuses two runs on the same base" '! bash "$RUN" pair "$TMP/out1" "$TMP/out1" >/dev/null 2>&1'

# i: prune-history: the pruned arm drops history comments and nothing else
PRUNE="$HERE/prune-history.sh"
mkdir -p "$TMP/repo/scripts"
printf '%s\n' '#!/usr/bin/env bash' '# HIMMEL-1 added for the old bug' '# ponytail: HIMMEL-2 known limit, upgrade later' '# keep: why this flag exists' 'echo hi  # HIMMEL-3 trailing stays' '// round 2 note' '# CR fix: tidy' >"$TMP/repo/scripts/demo.sh"
printf '%s\n' '# HIMMEL-9 symlink target stays' >"$TMP/repo/ext.txt"
ln -s ../ext.txt "$TMP/repo/scripts/link.sh"
git -C "$TMP/repo" add -A
git -C "$TMP/repo" -c user.name=t -c user.email=t@t commit -qm demo
BASE3="$(git -C "$TMP/repo" rev-parse HEAD)"
PSHA="$(bash "$PRUNE" "$TMP/repo" "$BASE3" --files 5 2>"$TMP/prune.err")"
rc=$?
check "prune-history prints a new commit sha on top of the base" '[ "$rc" -eq 0 ] && [ -n "$PSHA" ] && [ "$PSHA" != "$BASE3" ] && [ "$(git -C "$TMP/repo" rev-parse "$PSHA^")" = "$BASE3" ]'
check "the pruned file lost the history comments only" '[ "$(git -C "$TMP/repo" show "$PSHA:scripts/demo.sh" | tr "\n" "|")" = "#!/usr/bin/env bash|# ponytail: HIMMEL-2 known limit, upgrade later|# keep: why this flag exists|echo hi  # HIMMEL-3 trailing stays|" ]'
check "a tracked symlink is skipped, its target is untouched" '[ "$(git -C "$TMP/repo" show "$PSHA:ext.txt")" = "# HIMMEL-9 symlink target stays" ]'
check "prune-history reports the removed line count" 'grep -q "removed [1-9][0-9]* history-comment lines" "$TMP/prune.err"'
check "prune-history refuses an unknown base" '! bash "$PRUNE" "$TMP/repo" 1111111111111111111111111111111111111111 >/dev/null 2>&1'
# --base on run: the sweep is cut at the named commit, not the pinned one
bash "$RUN" run --lane native --model claude-haiku-4-5 --tasks shell-red-green --no-judge --base "$PSHA" --out "$TMP/out-pr" >"$TMP/run-pr.log" 2>&1
check "run --base cuts the sweep at the named commit" '[ "$(jq -r .base_sha "$TMP/out-pr/runs.jsonl")" = "$PSHA" ]'
bash "$RUN" run --lane native --model claude-haiku-4-5 --tasks shell-red-green --no-judge --base HEAD --out "$TMP/out-pr2" >"$TMP/run-pr2.log" 2>&1
check "run --base records a full sha for a ref spelling" '[ "$(jq -r .base_sha "$TMP/out-pr2/runs.jsonl")" = "$(git -C "$TMP/repo" rev-parse HEAD)" ]'

echo "test-lane-quality: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
