#!/usr/bin/env bash
# scripts/eval/lane-quality/run.sh - lane-quality eval.
#
# Runs the same frozen task set against one lane and model, and records per
# task: the hidden acceptance result, a blind judge score, wall time, tool
# calls, compactions, cost, the bank reading before and after, and guardrail
# friction. A new model is one more `run`; `table` turns runs into rows.
#
# Usage:
#   run.sh list
#   run.sh run --lane native|openrouter|api --model <model> [--tasks a,b] [--effort <level>]
#              [--reps <n>] [--base <sha>] [--max-usd <usd>] [--timeout <sec>] [--judge-model <model>]
#              [--no-judge] [--keep] [--out <dir>] [--config <file>] [--dry-run]
#              [--set regression|capability|all] [--judge-effort <level>] [--judge-twice]
#   run.sh judge-pair <baseline-run-dir> <candidate-run-dir> [--judge-model <model>]
#              [--judge-effort <level>] [--max-usd <usd>] [--timeout <sec>] [--seed <n>] [--out <file>]
#   run.sh table <run-dir>...
#   run.sh pair <run-dir-a> <run-dir-b>   (one task set on two base commits: one paired row per task)
#   run.sh calibration <run-dir>... [--judge2-model <model>] [--judge2-effort <level>]
#              [--max-usd <usd>] [--timeout <sec>] [--json] [--no-ledger]
#   run.sh materialize <task> <dir> [--reference]   (used by the suite)
#   run.sh verdict <baseline-run-dir> <variant-run-dir>...
#
# Steering A/B: `run --steering-variant NAME=FILE` puts FILE in each
# task worktree as CLAUDE.md (inside the fixture commit, so not scope drift) and
# records NAME as the row's `variant`. `verdict` compares each variant run to the
# baseline run and prints `<variant> <apply|keep> <reason>` per variant.
#
# Repeats: --reps N runs the task set N times, repeat by repeat,
# into one run dir; a repeat's files carry a .r<n> suffix from the second on.
# `table` then adds the mean and a bootstrap 95% CI per task and criterion,
# and counts the rows with no judge score instead of dropping them.
# `calibration` (lq_stats.py) scores the judge against the hidden acceptance
# (AUC and point-biserial of each criterion against accept_ok) and, with
# --judge2-model, re-judges every stored judge packet once with a second
# model or effort and reports quadratic weighted kappa per criterion. Stored
# second-judge results are reused, so a rerun makes no call.
#
# Task sets: the synthetic tasks are the regression set (the default). A real
# task (a tasks/<id>/task.json, written by mine-tasks.py) is a merged himmel
# change: the agent gets the ticket text and a fresh repo holding the tree at
# the change's base sha as its only commit (git archive, then git init), outside
# the source repo, so no ref, object or worktree link reaches the fix. Its
# hidden tests are copied in only at acceptance. --set picks the default list.
#
# Judge: the rubric is checkable claims (judge-claims-rubric.md), each true or
# false with quoted evidence; the 1-5 score per criterion is 1 + the claims that
# hold. --judge-twice grades each output a second time and records the flips.
# The judge may not share a model family with the model under test. judge-pair
# shows two runs' outputs blind, in a recorded random order, judged once per
# order. A sweep with any unjudged row is ledgered partial, never ok.
# Plumbing failures (timeout, no JSON, truncation, API error) are a row field
# that `table` counts apart from model failures.
#
# Each synthetic task runs in a fresh detached worktree at the pinned BASE_SHA, plus
# the task's fixture/ committed on top (a fixed author and date, so the
# fixture commit is reproducible). The agent sees only tasks/<id>/prompt.md;
# accept.sh and reference/ stay outside its worktree. The judge sees the task,
# the diff and the agent's final report with every model and lane name
# redacted, and never the acceptance result: the two signals stay independent.
#
# Lanes: `native` and `openrouter` (phase 2, operator-approved). An openrouter
# agent runs through scripts/claude-openrouter (its egress, PHI and credit
# gates apply), and its metered balance is read before and after each task;
# the judge always runs native. deepseek and claudex exit 3 until the
# operator opts in (deepseek needs a station opt-in in the launching shell).
# ponytail: OpenRouter credit metadata lags, so a per-task balance delta can
# under-report; read the sweep's account delta again later for the total.
# Upgrade path: per-generation cost from OpenRouter's generation API.
#
# Budget: --max-usd (default 3) caps the sweep. The agent's reported
# total_cost_usd is summed after each task; no further task starts once the
# sum reaches the cap, and each agent call gets the remainder as
# --max-budget-usd. On a subscription lane that figure is the API-price
# equivalent, not money spent; the bank reading is the subscription cost.
# A sweep that stops because a task's cost is unknown exits 76 (the ledger row
# is still written, status partial); a budget-cap stop exits 0.
#
# The api lane: the agent runs through scripts/api-lane/claude-api.sh
# on the API credit of HIMMEL_API_ACCOUNT, never on subscription auth. It needs
# HIMMEL_API_LANE=on, HIMMEL_API_ACCOUNT, HIMMEL_API_KEY_ID and ANTHROPIC_API_KEY
# in the environment, --no-judge (the judge is native, so it would draw the
# subscription bank), and --max-usd of at most API_PILOT_CAP (default and ceiling
# $1, enforced here; the launcher also reserves each call's budget in its ledger).
# The native bank is read for the record but never gates an api run. --dry-run
# checks all of that and prints the plan and the command, spending nothing.
# Known limits:
#  R1 the $1 cap is per sweep; the ledger's cap_usd for the account is the bound across sweeps.
#  R2 --max-budget-usd is checked between turns, so one call can overshoot by up to one turn.
#  R5 a model name containing [ is refused by the launcher (fails closed); use the plain id.
# On the api lane LQ_LANE_BIN and LQ_REPO never pick the launcher (it is always the claude-api.sh beside
# this harness), and acceptance runs with the API key and lane selectors removed from its environment
# (strip-env outside timeout). This run.sh process itself still holds the key, so same-user /proc reads of it
# remain an OS-layer exposure that belongs to the sandbox half.
# The scrub in the launcher is the bwrap sandbox: where bwrap cannot mount, the agent has no Bash.
#
# Output: <out>/runs.jsonl (one JSON row per task) plus per-task logs, under
# ~/.himmel/eval/lane-quality/<run-id>/ by default.
#
# Test seams (env): LQ_CLAUDE_BIN, LQ_PREFLIGHT, LQ_REPO, LQ_BASE_SHA,
# LQ_WORK_ROOT, LQ_TRANSCRIPTS, LQ_LANE_BIN, LQ_METERED_PROBE.
#
# ponytail: the bank reading is the account-wide five-hour percent, so any
# other session running during a task lands in its delta; run a sweep on a
# quiet fleet, or read the delta as an upper bound. Upgrade path: per-session
# usage from the transcript once a lane exposes it.
# ponytail: a single headless run cannot hand off, so `handoffs` is not
# recorded; compactions are. Upgrade path: drive a lane through its leg
# launcher when phase 2 measures leg churn.
# ponytail: the hidden tests live in the repo, so an agent on a later checkout
# could read them; the runner flags a transcript that touches this directory
# (`peeked`) instead of preventing it. Upgrade path: move the tasks to the
# state repo if a run is ever flagged.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
TASKS="$HERE/tasks"
die() { echo "lane-quality: $*" >&2; exit 64; }
usage() { sed -n '2,86p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 64; }
# billed-opt-in: HIMMEL_BILLED_OK
need_billed() { [ "${HIMMEL_BILLED_OK:-}" = 1 ] || die "$1 makes real, billed model calls; set HIMMEL_BILLED_OK=1 (on-demand only)"; }
has_arg() { local w=$1 a; shift; for a in "$@"; do if [ "$a" = "$w" ]; then return 0; fi; done; return 1; }
command -v jq >/dev/null 2>&1 || die "jq is required"

all_tasks() { for d in "$TASKS"/*/; do [ -f "$d/prompt.md" ] || [ -f "$d/fixture/prompt.md" ] && basename "$d"; done; }
# prompt_of <task>: the prompt file; a mined task keeps its ticket text under fixture/
prompt_of() { if [ -f "$TASKS/$1/fixture/prompt.md" ]; then echo "$TASKS/$1/fixture/prompt.md"; else echo "$TASKS/$1/prompt.md"; fi; }

# materialize <task> <dir> [--reference]: copy the task's fixture (or its
# reference solution) into <dir>. The fixture is committed and its sha
# printed; a reference is copied only, with `.ref` suffixes dropped (stored
# that way so CI never discovers a reference test-*.sh as a suite).
materialize() {
  local task="$1" dir="$2" mode="${3:-}" src f
  [ -f "$(prompt_of "$task")" ] || die "unknown task '$task'"
  if [ "$mode" = --reference ]; then
    src="$TASKS/$task/reference"
    [ -d "$src" ] || return 0
    cp -R "$src/." "$dir/" || die "cannot copy the $task reference"
    while IFS= read -r f; do mv "$f" "${f%.ref}" || die "cannot rename $f"; done < <(find "$dir/lq-work" -name '*.ref' 2>/dev/null)
    return 0
  fi
  src="$TASKS/$task/fixture"
  if [ -d "$src" ]; then
    cp -R "$src/." "$dir/" || die "cannot copy the $task fixture"
    git -C "$dir" add -A || die "cannot stage the $task fixture"
    GIT_AUTHOR_DATE='2026-01-01T00:00:00Z' GIT_COMMITTER_DATE='2026-01-01T00:00:00Z' \
      git -C "$dir" -c user.name=lane-quality -c user.email=lane-quality@invalid \
      -c commit.gpgsign=false commit -q --no-verify -m "lane-quality fixture: $task" || die "cannot commit the $task fixture"
  fi
  git -C "$dir" rev-parse HEAD
}

# Redact every model and lane name before the judge sees a byte, and the literal
# --model / --judge-model values first (a 1-2 character value would mangle the packet).
redact() {
  local v esc="" x
  for v in "${MODEL:-}" "${JUDGE_MODEL:-}"; do
    [ "${#v}" -ge 3 ] || continue
    x="$(printf '%s' "$v" | sed 's/[][\.*^$/|(){}+?&]/\\&/g')"
    esc="${esc}s/$x/[redacted]/Ig;"
  done
  sed -E "${esc}"'s/(anthropic|claude|opus|sonnet|haiku|fable|gpt[-_.a-z0-9]*|codex|claudex|openai|deepseek|openrouter|gemini|glm|kimi|qwen|llama|mistral)/[redacted]/Ig; s/\bnative\b/[redacted]/Ig;s/\[redacted\]([-_.]*[0-9][-_.0-9]*)?/[redacted]/g'
}

bank_read() { # prints "<token> <five_hour>"
  local out tok five
  # the preflight path is env-selectable (LQ_PREFLIGHT, LQ_REPO): on the api lane it runs without the key
  if [ "${LANE:-}" = api ]; then
    out="$(bash "$HERE/../../api-lane/strip-env.sh" -- "$PREFLIGHT" 2>&1)"
  else
    out="$("$PREFLIGHT" 2>&1)"
  fi
  tok="$(printf '%s\n' "$out" | grep -Eo '^(PROCEED|SKIPPED-[A-Z]+|BANK-[A-Z]+)$' | tail -1)"
  five="$(printf '%s\n' "$out" | sed -n 's/.*five_hour=\([0-9.?]*\).*/\1/p' | tail -1)"
  echo "${tok:-BANK-UNKNOWN} ${five:-?}"
}

metered_read() { # prints the metered lane's balance in USD, "?" if unreadable, nothing on native
  [ -n "$METERED_PROBE" ] || return 0
  bash "$METERED_PROBE" --raw 2>/dev/null | sed -n 's/^balance=\([0-9.]*\):.*/\1/p' | grep . || echo '?'
}

# List prices in USD per million tokens: input, output, cache write, cache read.
# ponytail: Claude Code does not recognize the OpenRouter slug
# anthropic/claude-haiku-4.5 ([claude-code:unrecognized_model], costBasis
# unknown) and over-counts its total_cost_usd about 5x, so a metered lane is
# repriced here from modelUsage; an unpriced model leaves the cost unknown and
# stops the sweep. Upgrade path: drop this table once Claude Code prices the
# gateway slug (costBasis no longer "unknown"), or add a row per model adopted.
# The metered balance fell 12-16% more than list price in the first live
# sweeps, so the repriced cost carries a 1.2 markup to keep --max-usd a real cap.
# Claude Code's figure was exactly 5x list price on every live task, whatever
# the token mix. The per-call factor (BUDGET_FACTOR) relies on that ratio, so a
# run that reports any other ratio, no cost or no priced tokens leaves the cost
# unknown and stops the sweep.
# haiku-5.5 (the launcher default) lists 0.1/0.5/0.125/0.01,
# x5 above 100k prompt tokens; the row carries the high tier so --max-usd stays a cap.
PRICES='{"anthropic/claude-haiku-4.5":[1,5,1.25,0.1],"anthropic/claude-haiku-5.5":[0.5,2.5,0.625,0.05]}'
METERED_MARKUP=1.2
REPORTED_RATIO=5

agent_cost() { # $1 result json -> the agent's real cost in USD, or null
  if [ "$LANE" = native ] || [ "$LANE" = api ]; then jq -r '.total_cost_usd // null' "$1"; return; fi
  if [ "$LANE" = claudex ]; then jq -r '.total_cost_usd // 0' "$1"; return; fi
  jq -r --argjson p "$PRICES" --argjson mk "$METERED_MARKUP" --argjson rr "$REPORTED_RATIO" '
    .total_cost_usd as $rep
    | if (.modelUsage // {}) == {} then null
    else [.modelUsage | to_entries[] | $p[.key] as $r
          | if $r == null then null
            else ((.value.inputTokens // 0) * $r[0] + (.value.outputTokens // 0) * $r[1]
                  + (.value.cacheCreationInputTokens // 0) * $r[2] + (.value.cacheReadInputTokens // 0) * $r[3]) / 1000000
            end]
         | if any(. == null) then null
           else add as $list
             | if $list <= 0 or $rep == null or ($rep / $list - $rr | fabs) > 0.05 then null
               else $list * $mk end
           end
    end' "$1"
}

# transcript_metrics <transcript or empty> <final report file> [source repo]: a JSON object.
# `peeked` flags a tool input naming this harness directory, any qmd or graphify
# use, and (for a real task, given the source repo) a path inside the source checkout.
transcript_metrics() {
  if [ -z "$1" ] || [ ! -r "$1" ]; then
    echo '{"tool_calls":null,"dispatches":null,"dispatch_unnamed_model":null,"compactions":null,"hook_denials":null,"peeked":null,"red_before_green":null,"denial_recovery":null,"identical_denied_retries":null,"verify_before_claim":null}'; return
  fi
  local traj  # HIMMEL-4651 trajectory fields; a scorer failure leaves them null
  traj="$(python3 "$HERE/trajectory.py" score "$1" --report "$2" 2>/dev/null)" || traj=""
  jq -s -c --argjson traj "${traj:-null}" --arg rp "${3:+$3/}" '
    (if $traj == null then {red_before_green: null, denial_recovery: null, identical_denied_retries: null, verify_before_claim: null} else $traj end) as $traj
    |
    def text: if type == "string" then . elif type == "array" then map(.text? // "") | join(" ") else "" end;
    [ .[] | select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") ] as $tu
    | ([ $tu[] | select(.name == "Agent" or .name == "Task") ] | unique_by(.id)) as $dp
    | { tool_calls: ($tu | map(.id) | unique | length),
        dispatches: ($dp | length),
        dispatch_unnamed_model: ($dp | map(select((.input.model // "") == "")) | length),
        compactions: ([ .[] | select(.type == "system" and .subtype == "compact_boundary") ] | length),
        hook_denials: ([ .[] | select(.type == "user") | .message.content[]? | select(.type == "tool_result" and .is_error == true)
                         | select(.content | text | test("hook error|PreToolUse|refus|denied|blocked"; "i")) ] | length),
        peeked: (($tu | map(.input | tostring) | any(test("eval/lane-quality|\\b(qmd|graphify)\\b") or ($rp != "" and contains($rp))))
                 or ($tu | any(.name | test("qmd|graphify"; "i")))) } + $traj' "$1"
}

# judge_call <packet> <out json> <err file> <model> <budget> [effort] [single|pair]:
# one blind judge call on a stored packet; the result lands in <out json>.
judge_call() {
  local packet="$1" out="$2" err="$3" model="$4" budget="$5" effort="${6:-}" kind="${7:-single}" jdir rc schema
  schema="$(jq -c ".$kind" "$HERE/judge-claims-schema.json")" || return 1
  jdir="$(mktemp -d "${TMPDIR:-/tmp}/lq-judge.XXXXXX")" || return 1
  (
    cd "$jdir" || exit 1
    # the pin's rc is advisory; the keyword-only LAUNCH GATE re-checks.
    native_auth_pin_env
    if [[ -z "${!ANTHROPIC_*}${!anthropic_*}${!CLAUDE_CODE_USE_*}${!claude_code_use_*}" ]]; then
      # blind judge call, bank-preflighted by its caller, no tools, explicit permission mode, budget-capped
      # launch-profile-ok: the judge runs with --tools "", so no tool profile applies
      timeout "$TIMEOUT" "$CLAUDE_BIN" -p --model "$model" ${effort:+--effort "$effort"} --permission-mode dontAsk --output-format json \
        --max-budget-usd "$budget" --no-session-persistence --json-schema "$schema" --tools ""
    else
      exit 1
    fi
  ) <"$packet" >"$out" 2>"$err"  # opened before the cd, so a relative path still resolves
  rc=$?  # the judge's status, not the cleanup's (HIMMEL-4667)
  rm -rf "$jdir"
  return "$rc"
}

# judge_scores <judge result json>: the scores plus cost_usd, or null. A claims
# result also gets the integer score per criterion: 1 + the claims that hold.
judge_scores() {
  local s  # an empty file makes jq print nothing at rc 0: still null
  s="$(jq -c 'def held($c): [.claims | to_entries[] | select(.key | startswith($c)) | select(.value.holds == true)] | length;
         (.structured_output // (.result | fromjson? ) // null) as $s
         | if $s == null then null
           elif ($s | type) == "object" and ($s.claims | type) == "object" then
             $s + ($s | {correctness: (1 + held("C")), scope_discipline: (1 + held("S")), test_quality: (1 + held("T")), honesty: (1 + held("H"))})
               + {cost_usd: (.total_cost_usd // null)}
           else $s + {cost_usd: (.total_cost_usd // null)} end' \
    "$1" 2>/dev/null)"
  echo "${s:-null}"
}

rubric() { # rubric single|pair: that section of judge-claims-rubric.md
  awk -v want="$1" '/^<!-- pair -->$/ { part = "pair"; next } (part ? part : "single") == want' "$HERE/judge-claims-rubric.md"
}

# judge <stem> <task> <worktree> <fixture sha> <report file> <out dir> <budget> [suffix]:
# the judge JSON on stdout. The packet and the redacted candidate (<stem>.cand.md,
# which judge-pair reuses) are written on the first call; a suffix (-b) grades
# the stored packet again into <stem>.judge<suffix>.json.
judge() {
  local stem="$1" task="$2" wt="$3" fix="$4" report="$5" od="$6" budget="$7" sfx="${8:-}" packet
  packet="$od/$stem.judge-packet.md"
  if [ -z "$sfx" ]; then
    git -C "$wt" add -A
    {
      printf '## The diff it produced\n\n```diff\n'
      git -C "$wt" diff --cached "$fix" | head -c 60000
      [ "$(git -C "$wt" diff --cached "$fix" | wc -c)" -le 60000 ] || printf '\n[truncated at 60000 bytes]'
      printf '\n```\n\n## Its final report\n\n'
      cat "$report"
    } | redact >"$od/$stem.cand.md"
    { rubric single; printf '\n## Task given to the agent\n\n'; cat "$(prompt_of "$task")"; printf '\n'; cat "$od/$stem.cand.md"; } \
      | redact >"$packet"
  fi
  judge_call "$packet" "$od/$stem.judge$sfx.json" "$od/$stem.judge$sfx.err" "$JUDGE_MODEL" "$budget" "$JUDGE_EFFORT" || { echo null; return 0; }
  judge_scores "$od/$stem.judge$sfx.json"
}

# judge_family <model>: the vendor family a model name belongs to, else the name itself
judge_family() {
  local m; m="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  printf '%s\n' "$m" | grep -Eo 'opus|sonnet|haiku|fable|gpt|codex|gemini|glm|deepseek|kimi|qwen|llama|mistral' | head -1 | grep . || printf '%s\n' "$m"
}

# refuse_same_judge <judge> <model>...: exit 64 when the judge shares a family with any model
refuse_same_judge() {
  local j="$1" m; shift
  for m in "$@"; do
    [ -n "$m" ] || continue
    [ "$(judge_family "$j")" != "$(judge_family "$m")" ] \
      || die "judge '$j' is in the same model family as the model under test '$m'; pick a judge from another family"
  done
}

task_set() { # task_set <task>: its task set, regression for a synthetic task
  if [ -f "$TASKS/$1/task.json" ]; then jq -r '.set // "capability"' "$TASKS/$1/task.json"; else echo regression; fi
}

# materialize_real <task> <dir>: the task's base tree as the only commit of a new
# repo in <dir>.repo (no remote, no shared objects, no later refs), checked out in
# <dir> as a linked worktree on lq-task, the shape a leg works in, so the himmel
# hooks in the tree allow edits there; origin/main names the base so they can
# vouch its libs. Prints the base commit's sha.
materialize_real() {
  local task="$1" dir="$2" base src="$2.repo"
  base="$(jq -r .base_sha "$TASKS/$task/task.json")"
  git -C "$REPO" cat-file -e "$base^{commit}" 2>/dev/null || die "$task: base $base is not a commit in $REPO"
  mkdir -p "$src" || die "cannot create $src"
  git -C "$REPO" archive "$base" | tar -x -C "$src" || die "$task: cannot extract $base"
  git -C "$src" init -q -b main || die "$task: git init failed"
  git -C "$src" add -A || die "$task: cannot stage the base tree"
  GIT_AUTHOR_DATE='2026-01-01T00:00:00Z' GIT_COMMITTER_DATE='2026-01-01T00:00:00Z' \
    git -C "$src" -c user.name=lane-quality -c user.email=lane-quality@invalid \
    -c commit.gpgsign=false commit -q --no-verify -m "lane-quality task base" || die "$task: cannot commit the base tree"
  git -C "$src" update-ref refs/remotes/origin/main HEAD || die "$task: cannot name the default branch"
  git -C "$src" worktree add -q -b lq-task "$dir" main || die "$task: cannot add the task worktree"
  git -C "$dir" rev-parse HEAD
}

# The frozen pilot tasks whose accept.sh cannot change: the agent's own test
# must still fail on the untouched fixture, checked here.
FROZEN_OWN_TEST='{"doc-plus-code":"lq-work/test-log-tail.sh"}'

# own_test_catches <task> <worktree> <fixture sha>: true, false, or null when the task is not listed
own_test_catches() {
  local t mut rc
  t="$(jq -r --arg k "$1" '.[$k] // empty' <<<"$FROZEN_OWN_TEST")"
  [ -n "$t" ] || { echo null; return 0; }
  [ -f "$2/$t" ] || { echo false; return 0; }
  mut="$(mktemp -d "${TMPDIR:-/tmp}/lq-own.XXXXXX")" || { echo false; return 0; }  # prim-ok: the judge scratch dir idiom above; run.sh does not source prim.sh
  git -C "$2" archive "$3" lq-work | tar -x -C "$mut"
  cp "$2/$t" "$mut/$t"
  (cd "$mut" && bash "$HERE/../../api-lane/strip-env.sh" -- timeout "$TIMEOUT" bash "$t") >/dev/null 2>&1; rc=$?
  rm -rf "$mut"
  if [ "$rc" -ne 0 ]; then echo true; else echo false; fi
}

drop_wt() { # drop_wt <real 0|1> <dir>: remove a task's working copy
  if [ "$1" -eq 1 ]; then rm -rf "$2" "$2.repo"; else git -C "$REPO" worktree remove --force "$2" >/dev/null 2>&1; fi
}

stem_of() { # $1 task, $2 repeat -> the file stem (the task alone for repeat 1)
  if [ "${2:-1}" -gt 1 ]; then echo "$1.r$2"; else echo "$1"; fi
}

run_task() { # $1 task, $2 repeat -> appends a row to runs.jsonl, prints the task's cost
  local task="$1" rp="$2" stem wt fix start end bank0 bank1 met0 met1 acost outer res sid tr metrics acc_line acc_rc scope jres remaining tok judged=0
  local real=0 base="$BASE_SHA" arc nojson=0 cli own plumbing jres_b=null judged_b=0
  stem="$(stem_of "$task" "$rp")"
  [ ! -f "$TASKS/$task/task.json" ] || { real=1; base="$(jq -r .base_sha "$TASKS/$task/task.json")"; }
  if [ "$real" -eq 1 ]; then
    wt="$REAL_WORK_ROOT/lq-$RUN_ID-$stem"
    fix="$(materialize_real "$task" "$wt")" || die "task repo for $task failed"
  else
    wt="$WORK_ROOT/lq-$RUN_ID-$stem"
    mkdir -p "$WORK_ROOT"
    git -C "$REPO" worktree add -q --detach "$wt" "$BASE_SHA" || die "worktree add failed for $task"
    fix="$(materialize "$task" "$wt")" || die "fixture for $task failed"
  fi
  if [ -n "$VARIANT_FILE" ]; then
    # The variant steering file replaces the worktree's CLAUDE.md inside the fixture commit, so it is not scope drift.
    cp "$VARIANT_FILE" "$wt/CLAUDE.md" || die "cannot copy the steering variant into $task"
    git -C "$wt" add -A || die "cannot stage the steering variant"
    GIT_AUTHOR_DATE='2026-01-01T00:00:00Z' GIT_COMMITTER_DATE='2026-01-01T00:00:00Z' \
      git -C "$wt" -c user.name=lane-quality -c user.email=lane-quality@invalid \
      -c commit.gpgsign=false commit -q --allow-empty --no-verify -m "lane-quality steering variant: $VARIANT" || die "cannot commit the steering variant"
    fix="$(git -C "$wt" rev-parse HEAD)"
  fi
  bank0="$(bank_read)"
  if [ "${bank0%% *}" != PROCEED ] && [ "$LANE" != api ]; then
    drop_wt "$real" "$wt"
    echo "bank-refused ${bank0%% *}"; return 0
  fi
  bank0="${bank0#* }"; met0="$(metered_read)"
  remaining="$(awk -v m="$MAX_USD" -v s="$SPENT" 'BEGIN{printf "%.2f", m - s}')"
  outer="$(awk -v r="$remaining" -v f="$BUDGET_FACTOR" 'BEGIN{printf "%.2f", r * f}')"
  start="$(date +%s)"
  (
    cd "$wt" || exit 1
    # an eval session is not operator work: no end-session note in the vault
    export CLAUDE_END_SESSION_WIKI=0
    if [ "$LANE" = api ]; then
      # the launcher keeps the key and removes every other credential source; the
      # subscription token is dropped here too, so no layer between can hand it to the agent.
      unset CLAUDE_CODE_OAUTH_TOKEN
      export HIMMEL_API_JOB_ID="lq-$RUN_ID-$stem"
      # lane-quality api agent run, launcher bank check and ledger reservation, explicit permission mode, budget-capped
      # launch-profile-ok: the eval measures the lane's own default config, not a leg profile
      # the lane is tool-free unless named; the eval agent edits fixtures and runs their tests, so it opts in to the full set.
      ANTHROPIC_API_KEY="$LQ_API_KEY" HIMMEL_API_LANE="$LQ_API_LANE" HIMMEL_API_ACCOUNT="$LQ_API_ACCOUNT" HIMMEL_API_KEY_ID="$LQ_API_KEY_ID" \
        HIMMEL_API_TOOLS="Read,Edit,Write,Glob,Grep,Bash" \
        timeout "$TIMEOUT" "$AGENT_BIN" -p "$(cat "$(prompt_of "$task")")" --model "$MODEL" --permission-mode auto \
        --output-format json --max-budget-usd "$outer" ${EFFORT:+--effort "$EFFORT"}
      exit $?
    fi
    # the pin's rc is advisory; the keyword-only LAUNCH GATE re-checks.
    native_auth_pin_env
    if [[ -z "${!ANTHROPIC_*}${!anthropic_*}${!CLAUDE_CODE_USE_*}${!claude_code_use_*}" ]]; then
      # lane-quality agent run, bank-preflighted per sweep, explicit permission mode, budget-capped
      # launch-profile-ok: the eval measures the lane's own default config (claude or the lane launcher in $AGENT_BIN), not a leg profile
      timeout "$TIMEOUT" "$AGENT_BIN" -p "$(cat "$(prompt_of "$task")")" --model "$MODEL" --permission-mode auto \
        --output-format json --max-budget-usd "$outer" ${EFFORT:+--effort "$EFFORT"}
    else
      exit 1
    fi
  )>"$OUT/$stem.result.json" 2>"$OUT/$stem.stderr"
  arc=$?
  end="$(date +%s)"
  res="$OUT/$stem.result.json"
  jq -e . "$res" >/dev/null 2>&1 || { nojson=1; echo '{"is_error":true,"subtype":"harness-no-json"}' >"$res"; }
  jq -r '.result // ""' "$res" >"$OUT/$stem.report.md"
  acost="$(agent_cost "$res")"
  sid="$(jq -r '.session_id // ""' "$res")"
  tr=""
  [ -n "$sid" ] && tr="$(find "$TRANSCRIPTS" -name "$sid.jsonl" -print 2>/dev/null | head -1)"
  metrics="$(transcript_metrics "$tr" "$OUT/$stem.report.md" "$( [ "$real" -eq 1 ] && echo "$REPO" )")"
  cli=""
  [ -z "$tr" ] || cli="$(jq -r 'select(.version? | type == "string") | .version' "$tr" 2>/dev/null | head -1)"
  cli="${cli:-$CLI_VERSION}"
  # plumbing: a failure of the harness or the API, counted apart from the model's own failures
  plumbing="$(jq -r --argjson rc "$arc" --argjson nj "$nojson" '
    if $rc == 124 then "timeout" elif $nj == 1 then "no-json"
    elif (.subtype // "") | test("^error_max_(budget|turns)") then "truncated"
    elif .is_error == true then "api-error" else "" end' "$res")"
  # acceptance runs agent-written code, so the API key and lane selectors are removed first.
  # strip-env runs outside timeout, so the direct parent of accept.sh never carried the key either.
  bash "$HERE/../../api-lane/strip-env.sh" -- timeout "$TIMEOUT" bash "$TASKS/$task/accept.sh" "$wt" "$fix" >"$OUT/$stem.accept.log" 2>&1; acc_rc=$?
  acc_line="$(grep -E '^accept: [0-9]+/[0-9]+$' "$OUT/$stem.accept.log" | tail -1)"
  own="$(own_test_catches "$task" "$wt" "$fix")"
  if [ "$own" = false ]; then
    echo "FAIL own-test-catches-fixture (run.sh)" >>"$OUT/$stem.accept.log"; acc_rc=1
  fi
  # Staged against the fixture commit, so a file the agent committed counts too.
  git -C "$wt" add -A
  if [ "$real" -eq 1 ]; then
    scope="$(git -C "$wt" diff --cached --name-only "$fix" | jq -R . | jq -sc --slurpfile t "$TASKS/$task/task.json" \
      '[.[] | . as $f | select($t[0].scope | all(. as $d | $f | startswith($d) | not))]')"
  else
    scope="$(git -C "$wt" diff --cached --name-only "$fix" | grep -v '^lq-work/' | jq -R . | jq -sc .)"
  fi
  remaining="$(awk -v m="$MAX_USD" -v s="$SPENT" -v c="$( [ "$acost" = null ] && echo 0 || echo "$acost" )" 'BEGIN{printf "%.2f", m - s - c}')"
  jres=null
  if [ "$NO_JUDGE" -eq 0 ]; then
    read -r tok _ <<<"$(bank_read)"
    if [ "$tok" != PROCEED ]; then
      echo "lane-quality: bank preflight said $tok; judge skipped" >"$OUT/$stem.judge.err"
    elif [ "$acost" = null ]; then
      echo "lane-quality: agent cost unknown, budget cannot be bounded; judge skipped" >"$OUT/$stem.judge.err"
    elif awk -v r="$remaining" 'BEGIN{exit !(r >= 0.01)}'; then
      jres="$(judge "$stem" "$task" "$wt" "$fix" "$OUT/$stem.report.md" "$OUT" "$remaining")"
      judged=1
      if [ "$JUDGE_TWICE" -eq 1 ] && [ "${jres:-null}" != null ]; then
        remaining="$(awk -v r="$remaining" -v c="$(jq -r '.cost_usd // 0' <<<"$jres")" 'BEGIN{printf "%.2f", r - c}')"
        if awk -v r="$remaining" 'BEGIN{exit !(r >= 0.01)}'; then
          jres_b="$(judge "$stem" "$task" "$wt" "$fix" "$OUT/$stem.report.md" "$OUT" "$remaining" -b)"
          judged_b=1
        fi
      fi
    else
      echo "lane-quality: budget spent by the agent; judge skipped" >"$OUT/$stem.judge.err"
    fi
  fi
  [ -n "$jres" ] || jres=null
  [ -n "$jres_b" ] || jres_b=null
  # read after the judge, so the balance counts its spend
  bank1="$(bank_read)"; bank1="${bank1#* }"; met1="$(metered_read)"
  if [ "$KEEP" -eq 0 ]; then drop_wt "$real" "$wt"; fi
  jq -nc --arg run "$RUN_ID" --arg lane "$LANE" --arg model "$MODEL" --arg effort "$EFFORT" --arg task "$task" --argjson rep "$rp" \
    --arg set "$(task_set "$task")" --arg cli "$cli" --arg je "$JUDGE_EFFORT" --argjson own "$own" --arg pl "$plumbing" \
    --argjson jb "$jres_b" \
    --arg variant "$VARIANT" --arg base "$base" --arg fix "$fix" --argjson wall "$((end - start))" --arg b0 "$bank0" --arg b1 "$bank1" --arg m0 "$met0" --arg m1 "$met1" --argjson ac "$acost" \
    --arg acc "$acc_line" --argjson accrc "$acc_rc" --argjson scope "$scope" --argjson m "$metrics" \
    --argjson j "$jres" --argjson nojudge "$NO_JUDGE" --arg jm "$JUDGE_MODEL" --arg wt "$( [ "$KEEP" -eq 1 ] && echo "$wt" )" --slurpfile r "$res" '
    $r[0] as $r
    | def flips: if $j == null or $jb == null then null
        else { claims: (if ($j.claims | type) == "object" and ($jb.claims | type) == "object"
                        then [$j.claims | keys[] | select($j.claims[.].holds != $jb.claims[.].holds)] | length else null end),
               criteria: ([["correctness", "scope_discipline", "test_quality", "honesty"][] | select($j[.] != $jb[.])] | length) } end;
      { run_id: $run, lane: $lane, model: $model, effort: (if $effort == "" then null else $effort end), task: $task, rep: $rep,
        set: $set, cli_version: (if $cli == "" then null else $cli end), plumbing: (if $pl == "" then null else $pl end),
        own_test_catches_fixture: $own, variant: (if $variant == "" then null else $variant end), base_sha: $base, fixture_sha: $fix,
        wall_s: $wall, duration_ms: ($r.duration_ms // null), num_turns: ($r.num_turns // null),
        cost_usd: $ac, reported_cost_usd: ($r.total_cost_usd // null), bank_5h_before: $b0, bank_5h_after: $b1,
        metered_before: (if $m0 == "" then null else $m0 end), metered_after: (if $m1 == "" then null else $m1 end),
        permission_denials: (($r.permission_denials // []) | length),
        is_error: (if $r | has("is_error") then $r.is_error else null end),
        subtype: ($r.subtype // null),
        accept_passed: (($acc | capture("(?<p>[0-9]+)/").p? | tonumber?) // 0),
        accept_total: (($acc | capture("/(?<t>[0-9]+)").t? | tonumber?) // 0),
        tokens: ([($r.modelUsage // {}) | to_entries[] | .value] | {input: (map(.inputTokens // 0) | add // 0), output: (map(.outputTokens // 0) | add // 0), cache_read: (map(.cacheReadInputTokens // 0) | add // 0), cache_create: (map(.cacheCreationInputTokens // 0) | add // 0)}),
        accept_ok: ($accrc == 0), scope_ok: ($scope | length == 0), out_of_scope: $scope,
        judge: $j, judge_model: (if $nojudge == 1 then null else $jm end),
        judge_effort: (if $nojudge == 1 or $je == "" then null else $je end), judge_b: $jb, judge_flips: flips,
        kept_worktree: $wt } + $m' >>"$OUT/runs.jsonl" || die "$task: could not record its runs.jsonl row"
  # "unknown" when the agent, or a judge that was launched, left no cost
  # (killed by the timeout, or failed): the sweep stops.
  jq -nr --argjson ac "$acost" --argjson j "$jres" --argjson judged "$judged" --argjson jb "$jres_b" --argjson judgedb "$judged_b" '
    if $ac == null or ($judged == 1 and ($j.cost_usd? // null) == null) or ($judgedb == 1 and ($jb.cost_usd? // null) == null) then "unknown"
    else $ac + ($j.cost_usd? // 0) + ($jb.cost_usd? // 0) end'
}

API_PILOT_CAP=1  # HIMMEL-4986: the most one api sweep may be given, in USD

# api_dry_run <tasks>: every check an api sweep makes before it spends, plus the
# plan and the exact command. Spends nothing, starts nothing, prints no key.
api_dry_run() {
  [ "${LQ_API_LANE:-}" = on ] || die "api lane is OFF (set HIMMEL_API_LANE=on)"
  case "${LQ_API_ACCOUNT:-}" in A|B) ;; *) die "HIMMEL_API_ACCOUNT must be A or B" ;; esac
  [ -n "${LQ_API_KEY_ID:-}" ] || die "HIMMEL_API_KEY_ID is absent"
  [ -n "${LQ_API_KEY:-}" ] || die "ANTHROPIC_API_KEY is absent"
  [ -x "$AGENT_BIN" ] || die "launcher '$AGENT_BIN' is not executable"
  local n; n="$(printf '%s' "$1" | tr ',' '\n' | grep -c .)"
  echo "lane-quality: api dry-run (nothing launched, nothing spent)"
  echo "  account $LQ_API_ACCOUNT, key id $LQ_API_KEY_ID, model $MODEL${EFFORT:+, effort $EFFORT}"
  echo "  tasks ($n x $REPS reps): $1 from $TASKS at $BASE_SHA"
  echo "  cap $MAX_USD USD for the sweep (ceiling $API_PILOT_CAP); each call gets the remainder as --max-budget-usd"
  echo "  command: $AGENT_BIN -p <task prompt> --model $MODEL --permission-mode auto --output-format json --max-budget-usd <remainder>${EFFORT:+ --effort $EFFORT}"
}

init_env() { # the claude binary, the repo, the bank preflight and the native-auth pin
  CLAUDE_BIN="${LQ_CLAUDE_BIN:-claude}"
  REPO="${LQ_REPO:-$(dirname "$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir)")}"
  PREFLIGHT="${LQ_PREFLIGHT:-$REPO/scripts/lib/usage-preflight.sh}"
  # shellcheck source=../../lib/native-auth-pin.sh
  . "$HERE/../../lib/native-auth-pin.sh" || die "cannot source native-auth-pin.sh"
}

# run --config FILE. A JSON object with optional keys, so a second
# task set can share this driver without env-prefix knobs:
#   tasks_dir   task directory, relative to this dir, must stay under it
#   base_sha    40-hex commit the fixture worktrees are cut from
#   transcripts transcript root searched for the agent session
#   effort      the agent's --effort, unless --effort is given
#   judge_effort the judge's --effort, unless --judge-effort is given
apply_config() {
  local f="$1" td bs tr_ root ef jef
  [ -f "$f" ] || die "--config: no such file '$f'"
  jq -e 'type == "object"' "$f" >/dev/null 2>&1 || die "--config: '$f' is not a JSON object"
  td="$(jq -r '.tasks_dir // empty' "$f")"
  bs="$(jq -r '.base_sha // empty' "$f")"
  tr_="$(jq -r '.transcripts // empty' "$f")"
  ef="$(jq -r '.effort // empty' "$f")"
  jef="$(jq -r '.judge_effort // empty' "$f")"
  [ -n "$EFFORT" ] || EFFORT="$ef"
  [ -n "$JUDGE_EFFORT" ] || JUDGE_EFFORT="$jef"
  if [ -n "$td" ]; then
    root="$(realpath -m "$HERE")"
    td="$(realpath -m "$HERE/$td")"
    case "$td" in "$root"/*) ;; *) die "--config: tasks_dir must stay under $root" ;; esac
    [ -d "$td" ] || die "--config: tasks_dir '$td' is not a directory"
    TASKS="$td"
  fi
  if [ -n "$bs" ]; then
    printf '%s' "$bs" | grep -Eq '^[0-9a-f]{40}$' || die "--config: base_sha must be 40 hex characters"
    BASE_SHA="$bs"
  fi
  [ -z "$tr_" ] || TRANSCRIPTS="$tr_"
}

cmd_run() {
  LANE=""; MODEL=""; TASK_LIST=""; EFFORT=""; MAX_USD=""; TIMEOUT=1800; JUDGE_MODEL=opus
  NO_JUDGE=0; KEEP=0; OUT=""; REPS=1; CONFIG=""; DRY_RUN=0; BASE_ARG=""; VARIANT=""; VARIANT_FILE=""
  SET=regression; JUDGE_EFFORT=""; JUDGE_TWICE=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --lane|--model|--tasks|--effort|--max-usd|--timeout|--judge-model|--out|--reps|--config|--base|--steering-variant|--set|--judge-effort)
        [ $# -ge 2 ] || die "$1 needs a value"
        case "$1" in
          --steering-variant)
            case "$2" in *=*) ;; *) die "--steering-variant needs NAME=FILE" ;; esac
            VARIANT="${2%%=*}"; VARIANT_FILE="${2#*=}"
            printf '%s' "$VARIANT" | grep -Eq '^[A-Za-z0-9._-]+$' || die "--steering-variant name must match [A-Za-z0-9._-]+"
            [ -f "$VARIANT_FILE" ] || die "--steering-variant: no such file '$VARIANT_FILE'"
            VARIANT_FILE="$(cd "$(dirname "$VARIANT_FILE")" && pwd)/$(basename "$VARIANT_FILE")" ;;
          --config) CONFIG="$2" ;;
          --base) BASE_ARG="$2" ;;
          --lane) LANE="$2" ;; --model) MODEL="$2" ;; --tasks) TASK_LIST="$2" ;;
          --effort) EFFORT="$2" ;; --max-usd) MAX_USD="$2" ;; --timeout) TIMEOUT="$2" ;;
          --judge-model) JUDGE_MODEL="$2" ;; --out) OUT="$2" ;; --reps) REPS="$2" ;;
          --set) SET="$2" ;; --judge-effort) JUDGE_EFFORT="$2" ;;
        esac; shift 2 ;;
      --no-judge) NO_JUDGE=1; shift ;;
      --judge-twice) JUDGE_TWICE=1; shift ;;
      --keep) KEEP=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      *) die "unknown argument '$1'" ;;
    esac
  done
  [ -n "$MODEL" ] || die "--model is required"
  case "$SET" in regression|capability|all) ;; *) die "--set must be regression, capability or all" ;; esac
  [ "$NO_JUDGE" -eq 1 ] || refuse_same_judge "$JUDGE_MODEL" "$MODEL"
  [ "$DRY_RUN" -eq 1 ] || need_billed "run"
  case "$LANE" in
    native|openrouter) ;;
    api)
      # the key and lane selectors leave this process's environment before init_env and before any git
      # call on REPO: its hooks, a partial-clone lazy fetch (core.sshCommand), the preflight and agent-written git config
      # all run inside run.sh's own calls. They are held in unexported LQ_API_* variables (unset first, so an inherited
      # exported one does not stay exported) and handed only to the launcher invocation line.
      unset LQ_API_KEY LQ_API_ACCOUNT LQ_API_KEY_ID LQ_API_LANE
      LQ_API_KEY="${ANTHROPIC_API_KEY:-}"; LQ_API_ACCOUNT="${HIMMEL_API_ACCOUNT:-}"
      LQ_API_KEY_ID="${HIMMEL_API_KEY_ID:-}"; LQ_API_LANE="${HIMMEL_API_LANE:-}"
      unset ANTHROPIC_API_KEY HIMMEL_API_LANE HIMMEL_API_ACCOUNT HIMMEL_API_KEY_ID
      # the cap and the no-judge rule are code, not convention.
      [ "$NO_JUDGE" -eq 1 ] || die "--lane api needs --no-judge (the judge runs native and would draw the subscription bank)"
      MAX_USD="${MAX_USD:-$API_PILOT_CAP}"
      awk -v m="$MAX_USD" -v c="$API_PILOT_CAP" 'BEGIN{exit !(m+0 <= c+0)}' \
        || die "--lane api caps the sweep at $API_PILOT_CAP USD; --max-usd $MAX_USD is above the cap" ;;
    claudex)
      # the per-dispatch lane opt-in the dispatcher reads.
      if [ "${CLAUDEX_LANE_OK:-}" != 1 ]; then
        echo "lane-quality: lane claudex needs CLAUDEX_LANE_OK=1 on the command (HIMMEL-4906)" >&2
        exit 3
      fi ;;
    deepseek)
      echo "lane-quality: lane '$LANE' is not enabled (HIMMEL-4090): it needs the operator's go; see docs/internals/lane-calibration.md" >&2
      exit 3 ;;
    *) die "--lane must be native, openrouter, api or claudex; got '$LANE'" ;;
  esac
  MAX_USD="${MAX_USD:-3}"
  awk -v m="$MAX_USD" 'BEGIN{exit !(m+0 > 0)}' || die "--max-usd must be a positive number"
  [ "$DRY_RUN" -eq 0 ] || [ "$LANE" = api ] || die "--dry-run is for --lane api only"
  case "$TIMEOUT" in ''|*[!0-9]*) die "--timeout must be whole seconds" ;; esac
  [ "$TIMEOUT" -gt 0 ] || die "--timeout must be positive (0 disables timeout)"
  case "$REPS" in ''|*[!0-9]*) die "--reps must be a whole number" ;; esac
  [ "$REPS" -gt 0 ] || die "--reps must be positive"

  init_env
  BASE_SHA="${BASE_ARG:-${LQ_BASE_SHA:-$(tr -d '[:space:]' <"$HERE/BASE_SHA")}}"
  if [ -n "$BASE_ARG" ]; then
    BASE_SHA="$(git -C "$REPO" rev-parse --verify "$BASE_ARG^{commit}" 2>/dev/null)" || die "base '$BASE_ARG' is not a commit in $REPO"
  fi
  WORK_ROOT="${LQ_WORK_ROOT:-$REPO/.claude/worktrees}"
  # a real task's repo sits outside the source checkout, so no path inside it leads back
  REAL_WORK_ROOT="${LQ_WORK_ROOT:-$HOME/.himmel/eval/lane-quality/work}"
  # the transcript's version field is the record; this is the fallback, never asked of a test seam
  CLI_VERSION=""
  [ -n "${LQ_CLAUDE_BIN:-}" ] || CLI_VERSION="$("$CLAUDE_BIN" --version 2>/dev/null | awk 'NR == 1 {print $1}')"
  # The judge always runs native; a metered lane's agent goes through its launcher.
  AGENT_BIN="$CLAUDE_BIN"; METERED_PROBE=""; BUDGET_FACTOR=1; TRANSCRIPTS="${LQ_TRANSCRIPTS:-$HOME/.claude/projects}"
  if [ "$LANE" = openrouter ]; then
    # Only a priced model can be capped; refuse the rest before any spend.
    [ "$MODEL" = haiku ] || die "--lane openrouter supports --model haiku only (the one model with a PRICES row); got '$MODEL'"
    AGENT_BIN="${LQ_LANE_BIN:-$REPO/scripts/claude-openrouter}"
    METERED_PROBE="${LQ_METERED_PROBE:-$REPO/scripts/lanes/openrouter-cost.sh}"
    TRANSCRIPTS="${LQ_TRANSCRIPTS:-$HOME/.claude-openrouter/projects}"
    # The sweep cap counts real (repriced) spend. The per-call cap is in Claude
    # Code's own units, REPORTED_RATIO (5) times list price, and the real charge
    # is at most METERED_MARKUP (1.2) times list, so a factor of 4 stops a call
    # at 4/5 x 1.2 = 0.96 of the real remainder.
    BUDGET_FACTOR=4
    echo "lane-quality: openrouter agent budget factor $BUDGET_FACTOR (Claude Code over-counts the gateway slug; --max-usd counts real spend)" >&2
  fi
  if [ "$LANE" = api ]; then
    # the launcher comes from this script's own location, never from LQ_LANE_BIN or LQ_REPO
    # (REPO is only the git repo the worktrees are cut from). The key left this process's environment in the api arm
    # of the lane case above, before any git call on REPO, and is given only to the launcher invocation line.
    AGENT_BIN="$(cd "$HERE/../../api-lane" && pwd)/claude-api.sh"
  fi
  if [ "$LANE" = claudex ]; then
    # The claudex launcher wraps claude, so -p and --output-format json work
    # unchanged. Claude Code cannot price the gpt slug, so the sweep cap counts
    # its reported figure when present and 0 otherwise; read tokens and the
    # codex bank instead of dollars.
    AGENT_BIN="${LQ_LANE_BIN:-$REPO/scripts/claude-codex}"
    TRANSCRIPTS="${LQ_TRANSCRIPTS:-$HOME/.claude-codex/projects}"
  fi
  [ -z "$CONFIG" ] || apply_config "$CONFIG"
  # the pid keeps two runs started within one second apart (same lane and model)
  RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$-$LANE-$(printf '%s' "$MODEL" | tr -c 'A-Za-z0-9.-' '_')"
  OUT="${OUT:-$HOME/.himmel/eval/lane-quality/$RUN_ID}"
  mkdir -p "$OUT" || die "cannot create $OUT"
  OUT="$(cd "$OUT" && pwd)" || die "cannot resolve $OUT"

  local tasks t cost tok r
  tasks="$TASK_LIST"
  if [ -z "$tasks" ]; then
    for t in $(all_tasks); do
      [ "$SET" = all ] || [ "$(task_set "$t")" = "$SET" ] || continue
      tasks="$tasks$t,"
    done
    [ -n "$tasks" ] || die "no task in set '$SET'"
  fi
  for t in $(printf '%s' "$tasks" | tr ',' ' '); do
    [ -f "$(prompt_of "$t")" ] || die "unknown task '$t'"
    # a real task carries its own base, checked when its repo is made
    [ -f "$TASKS/$t/task.json" ] || git -C "$REPO" cat-file -e "$BASE_SHA^{commit}" 2>/dev/null || die "base sha $BASE_SHA not in $REPO"
  done
  if [ "$DRY_RUN" -eq 1 ]; then api_dry_run "$tasks"; return 0; fi
  SPENT=0; STATUS=ok; UNKNOWN_COST=0
  echo "lane-quality: run $RUN_ID → $OUT"
  # Repeat by repeat, so a sweep cut short still covers every task evenly.
  for r in $(seq 1 "$REPS"); do
  for t in $(printf '%s' "$tasks" | tr ',' ' '); do
    if awk -v m="$MAX_USD" -v s="$SPENT" 'BEGIN{exit !(s >= m)}'; then
      echo "lane-quality: budget cap reached (spent $SPENT of $MAX_USD USD); not starting '$t'" >&2
      STATUS=partial; break 2
    fi
    read -r tok _ <<<"$(bank_read)"
    if [ "$tok" != PROCEED ] && [ "$LANE" != api ]; then  # the api launcher gates its own credit
      echo "lane-quality: bank preflight said $tok; not starting '$t'" >&2
      exit 75
    fi
    echo "lane-quality: task $t (repeat $r of $REPS)"
    cost="$(run_task "$t" "$r")" || die "task '$t' failed; see $OUT"
    cost="$(printf '%s\n' "$cost" | tail -1)"
    case "$cost" in bank-refused*)
      echo "lane-quality: bank preflight said ${cost#bank-refused }; '$t' not launched" >&2
      exit 75 ;;
    esac
    if [ "$cost" = unknown ]; then
      echo "lane-quality: task '$t' left its cost unknown (agent or judge killed?); stopping the sweep, spend so far is a lower bound" >&2
      STATUS=partial; UNKNOWN_COST=1; break 2
    fi
    SPENT="$(awk -v s="$SPENT" -v c="${cost:-0}" 'BEGIN{printf "%.4f", s + c}')"
  done
  done
  echo "lane-quality: done, spent $SPENT USD (API-price equivalent); rows in $OUT/runs.jsonl"
  # a sweep with any row lacking one of the four judge scores is not a baseline
  if [ "$NO_JUDGE" -eq 1 ] || { [ -s "$OUT/runs.jsonl" ] && jq -se --arg r "$RUN_ID" '
      map(select(.run_id == $r)) | any(.judge == null
        or ([.judge.correctness, .judge.scope_discipline, .judge.test_quality, .judge.honesty] | any(type != "number")))' \
      "$OUT/runs.jsonl" >/dev/null; }; then
    STATUS=partial
  fi
  # one eval-runs ledger row per sweep (scripts/eval/lib/eval_runs.py);
  # a ledger failure warns and never changes the sweep's result.
  if [ -s "$OUT/runs.jsonl" ]; then
    python3 "$HERE/../lib/eval_runs.py" lane-quality "$OUT" --run-id "$RUN_ID" --status "$STATUS" \
      --judge-model "$( [ "$NO_JUDGE" -eq 1 ] && echo none || echo "$JUDGE_MODEL" )" \
      || echo "lane-quality: WARNING eval-runs row not written" >&2
  fi
  # a sweep cut short on unknown cost has an unbounded spend: not a success
  [ "$UNKNOWN_COST" -eq 0 ] || exit 76
}

cmd_table() {
  [ $# -ge 1 ] || die "table needs at least one run directory"
  local d files=()
  for d in "$@"; do [ -r "$d/runs.jsonl" ] || die "no runs.jsonl in $d"; files+=("$d/runs.jsonl"); done
  echo '| lane | model | task | accept | judge C/S/T/H | wall s | tool calls | compactions | cost USD | 5h bank | metered USD | denials perm/hook | peeked |'
  echo '|---|---|---|---|---|---|---|---|---|---|---|---|---|'
  jq -r '
    def n: if . == null then "?" else tostring end;
    "| \(.lane) | \(.model) | \(.task) | \(.accept_passed)/\(.accept_total)\(if .accept_ok then "" else " ✗" end) | "
    + (if .judge == null then "–" else "\(.judge.correctness)/\(.judge.scope_discipline)/\(.judge.test_quality)/\(.judge.honesty)" end)
    + " | \(.wall_s) | \(.tool_calls | n) | \(.compactions | n) | \(.cost_usd | n) | \(.bank_5h_before)→\(.bank_5h_after) | "
    + (if .metered_before == null then "–" else "\(.metered_before)→\(.metered_after)" end) + " | "
    + "\(.permission_denials)/\(.hook_denials | n) | \(.peeked | n) |"' "${files[@]}"
  echo
  # plumbing rows (timeout, no JSON, truncation, API error) leave the per-set acceptance
  jq -rs '
    (map(select(.plumbing != null)) | group_by(.plumbing) | map({(.[0].plumbing): length}) | add // {}) as $p
    | "plumbing: \(map(select(.plumbing != null)) | length) of \(length) rows (timeout \($p.timeout // 0), no-json \($p["no-json"] // 0), truncated \($p.truncated // 0), api-error \($p["api-error"] // 0))",
      (map(select(.plumbing == null)) | group_by(.set // "regression")[]
       | "set \(.[0].set // "regression"): accept \(map(select(.accept_ok)) | length)/\(length) (plumbing rows excluded)")' "${files[@]}"
  echo
  python3 "$HERE/lq_stats.py" summary "${files[@]}"
}

# pair <run-dir-a> <run-dir-b>: one row per (task, repeat) both runs
# have, arm A then arm B: acceptance, tool calls and cost. The two runs must sit
# on different base commits; a task only one arm ran is not paired.
cmd_pair() {
  [ $# -eq 2 ] || die "pair needs exactly two run directories"
  local d
  for d in "$1" "$2"; do
    [ -r "$d/runs.jsonl" ] || die "no runs.jsonl in $d"
    jq -e . "$d/runs.jsonl" >/dev/null 2>&1 || die "unreadable rows in $d/runs.jsonl"
  done
  jq -n -r '
    def n: if . == null then "?" else tostring end;
    def key: "\(.task)#\(.rep // 1)";
    [inputs] as $all
    | $all[0] as $A | $all[1] as $B
    | if ($A[0].base_sha // "") == ($B[0].base_sha // "") then error("both runs are on one base commit") else . end
    | ($B | map({(key): .}) | add) as $bk
    | "| task | rep | accept A → B | tool calls A → B | cost USD A → B | base A → B |",
      "|---|---|---|---|---|---|",
      ($A[] | select($bk[key] != null) | . as $x | $bk[key] as $y
       | "| \($x.task) | \($x.rep // 1) | \(if $x.accept_ok then 1 else 0 end) → \(if $y.accept_ok then 1 else 0 end) | \($x.tool_calls | n) → \($y.tool_calls | n) | \($x.cost_usd | n) → \($y.cost_usd | n) | \($x.base_sha[0:7]) → \($y.base_sha[0:7]) |")
  ' <(jq -s . "$1/runs.jsonl") <(jq -s . "$2/runs.jsonl") || die "pair failed (both runs on one base commit, or unreadable rows)"
}

# judge-pair <baseline-run-dir> <candidate-run-dir> [--judge-model M] [--judge-effort E]
# [--max-usd U] [--timeout S] [--seed N] [--out F]: for each task and repeat both
# runs judged, one blind packet shows the two stored candidates as A and B in a
# random order, judged once in that order and once swapped. A row per pair goes
# to F (default <candidate-run-dir>/pairs.jsonl); a flip is a pair whose two
# calls prefer different arms. The summary states flips and the position bias.
cmd_judge_pair() {
  local dirs=() seed="" out="" d spent=0 remaining cost tok key stem task first second call pref m1 m2 pa pb
  JUDGE_MODEL=opus; JUDGE_EFFORT=""; MAX_USD=1; TIMEOUT=600
  while [ $# -gt 0 ]; do
    case "$1" in
      --judge-model|--judge-effort|--max-usd|--timeout|--seed|--out)
        [ $# -ge 2 ] || die "$1 needs a value"
        case "$1" in
          --judge-model) JUDGE_MODEL="$2" ;; --judge-effort) JUDGE_EFFORT="$2" ;;
          --max-usd) MAX_USD="$2" ;; --timeout) TIMEOUT="$2" ;; --seed) seed="$2" ;; --out) out="$2" ;;
        esac; shift 2 ;;
      -*) die "unknown argument '$1'" ;;
      *) dirs+=("$1"); shift ;;
    esac
  done
  [ "${#dirs[@]}" -eq 2 ] || die "judge-pair needs a baseline and a candidate run directory"
  for d in "${dirs[@]}"; do [ -r "$d/runs.jsonl" ] || die "no runs.jsonl in $d"; done
  awk -v m="$MAX_USD" 'BEGIN{exit !(m+0 > 0)}' || die "--max-usd must be a positive number"
  case "$TIMEOUT" in ''|*[!0-9]*) die "--timeout must be positive whole seconds" ;; esac
  case "$seed" in ''|*[!0-9]*) [ -z "$seed" ] || die "--seed must be a whole number" ;; esac
  local mb mc
  mb="$(jq -r 'select(.model != null) | .model' "${dirs[0]}/runs.jsonl" | head -1)"
  mc="$(jq -r 'select(.model != null) | .model' "${dirs[1]}/runs.jsonl" | head -1)"
  refuse_same_judge "$JUDGE_MODEL" "$mb" "$mc"
  init_env
  out="${out:-${dirs[1]}/pairs.jsonl}"
  [ -z "$seed" ] || RANDOM="$seed"
  local pd; pd="$(dirname "$out")"
  while IFS=$'\t' read -r key stem task; do
    [ -s "${dirs[0]}/$stem.cand.md" ] && [ -s "${dirs[1]}/$stem.cand.md" ] || continue
    [ -f "$(prompt_of "$task")" ] || continue
    if [ $((RANDOM % 2)) -eq 0 ]; then first=baseline; second=candidate; else first=candidate; second=baseline; fi
    local prefs=()
    for call in 1 2; do
      remaining="$(awk -v m="$MAX_USD" -v s="$spent" 'BEGIN{printf "%.2f", m - s}')"
      awk -v r="$remaining" 'BEGIN{exit !(r >= 0.01)}' || { echo "lane-quality: judge-pair budget spent ($spent of $MAX_USD USD); stopping" >&2; break 2; }
      read -r tok _ <<<"$(bank_read)"
      [ "$tok" = PROCEED ] || { echo "lane-quality: bank preflight said $tok; judge-pair stopped before $stem" >&2; exit 75; }
      if [ "$call" -eq 1 ]; then pa="$first"; pb="$second"; else pa="$second"; pb="$first"; fi
      {
        rubric pair
        printf '\n## Task given to the agent\n\n'; cat "$(prompt_of "$task")"
        printf '\n## Candidate A\n\n'; cat "$(arm_dir "$pa" "${dirs[@]}")/$stem.cand.md"
        printf '\n## Candidate B\n\n'; cat "$(arm_dir "$pb" "${dirs[@]}")/$stem.cand.md"
      } | MODEL="$mb" JUDGE_MODEL="$mc" redact >"$pd/$stem.pair-packet.$call.md"
      judge_call "$pd/$stem.pair-packet.$call.md" "$pd/$stem.pair.$call.json" "$pd/$stem.pair.$call.err" \
        "$JUDGE_MODEL" "$remaining" "$JUDGE_EFFORT" pair || die "cannot run the pair judge on $stem"
      cost="$(jq -r '.total_cost_usd // empty' "$pd/$stem.pair.$call.json" 2>/dev/null)"
      [ -n "$cost" ] || { echo "lane-quality: pair judge on $stem left its cost unknown; stopping" >&2; break 2; }
      spent="$(awk -v s="$spent" -v c="$cost" 'BEGIN{printf "%.4f", s + c}')"
      pref="$(jq -r '.structured_output.preference // "none"' "$pd/$stem.pair.$call.json")"
      case "$pref" in A) prefs+=("A:$pa") ;; B) prefs+=("B:$pb") ;; *) prefs+=("$pref:$pref") ;; esac
    done
    m1="${prefs[0]#*:}"; m2="${prefs[1]#*:}"
    jq -nc --arg k "$key" --arg task "$task" --arg f "$first" --arg s "$second" --arg p1 "${prefs[0]%%:*}" --arg p2 "${prefs[1]%%:*}" \
      --arg m1 "$m1" --arg m2 "$m2" --arg jm "$JUDGE_MODEL" --arg je "$JUDGE_EFFORT" \
      '{key: $k, task: $task, order: [$f, $s], position_1: $p1, position_2: $p2, preferred_1: $m1, preferred_2: $m2,
        flip: ($m1 != $m2), preferred: (if $m1 == $m2 then $m1 else null end),
        judge_model: $jm, judge_effort: (if $je == "" then null else $je end)}' >>"$out"
  done < <(jq -r '"\(.task)#\(.rep // 1)\t\(if (.rep // 1) > 1 then "\(.task).r\(.rep)" else .task end)\t\(.task)"' "${dirs[0]}/runs.jsonl")
  [ -s "$out" ] || die "no pair judged (each run needs its stored <stem>.cand.md)"
  jq -rs --arg spent "$spent" '
    "judge-pair: \(length) pairs; agreeing: baseline \(map(select(.preferred == "baseline")) | length), candidate \(map(select(.preferred == "candidate")) | length), tie \(map(select(.preferred == "tie")) | length), both_bad \(map(select(.preferred == "both_bad")) | length)",
    "flips \(map(select(.flip)) | length) of \(length) pairs (the noise floor of a single pairwise call)",
    "position bias: A chosen \([.[] | .position_1, .position_2 | select(. == "A")] | length) of \([.[] | .position_1, .position_2 | select(. == "A" or . == "B")] | length) calls; spent \($spent) USD"' "$out"
}

arm_dir() { # arm_dir baseline|candidate <baseline dir> <candidate dir>
  if [ "$1" = baseline ]; then echo "$2"; else echo "$3"; fi
}

# calibration <run-dir>... [--judge2-model M] [--judge2-effort E] [--max-usd U]
# [--timeout S] [--json] [--no-ledger]: the second-judge calls happen here
# (bank-preflighted and budget-capped like the sweep); the maths is lq_stats.py.
cmd_calibration() {
  local dirs=() j2model="" j2effort="" json="" noledger="" label="" d stem packet out spent=0 remaining cost tok
  MAX_USD=1; TIMEOUT=600
  while [ $# -gt 0 ]; do
    case "$1" in
      --judge2-model|--judge2-effort|--max-usd|--timeout)
        [ $# -ge 2 ] || die "$1 needs a value"
        case "$1" in
          --judge2-model) j2model="$2" ;; --judge2-effort) j2effort="$2" ;;
          --max-usd) MAX_USD="$2" ;; --timeout) TIMEOUT="$2" ;;
        esac; shift 2 ;;
      --json) json=--json; shift ;;
      --no-ledger) noledger=--no-ledger; shift ;;
      -*) die "unknown argument '$1'" ;;
      *) dirs+=("$1"); shift ;;
    esac
  done
  [ "${#dirs[@]}" -ge 1 ] || die "calibration needs at least one run directory"
  for d in "${dirs[@]}"; do [ -r "$d/runs.jsonl" ] || die "no runs.jsonl in $d"; done
  [ -z "$j2effort" ] || [ -n "$j2model" ] || die "--judge2-effort needs --judge2-model"
  awk -v m="$MAX_USD" 'BEGIN{exit !(m+0 > 0)}' || die "--max-usd must be a positive number"
  case "$TIMEOUT" in ''|*[!0-9]*) die "--timeout must be positive whole seconds" ;; esac
  [ "$((10#$TIMEOUT))" -gt 0 ] || die "--timeout must be positive whole seconds"
  if [ -n "$j2model" ]; then
    # the stored-result label must be injective in (model, effort),
    # or one configuration reuses another's scores. Each byte outside
    # [A-Za-z0-9.-] becomes _<hex> (so a lone "_" is always an escape), and
    # "__", which no escaped part contains, joins model and effort.
    label="$(python3 -c 'import os, re, sys
enc = lambda s: re.sub(rb"[^A-Za-z0-9.-]", lambda m: b"_%02x" % m.group()[0], os.fsencode(s)).decode()
print("__".join(enc(a) for a in sys.argv[1:] if a))' "$j2model" "$j2effort")" || die "cannot build the second-judge label"
    init_env
    for d in "${dirs[@]}"; do
      while IFS= read -r stem; do
        packet="$d/$stem.judge-packet.md"; out="$d/$stem.judge2.$label.json"
        [ -s "$packet" ] || continue
        [ "$(judge_scores "$out")" = null ] || continue
        remaining="$(awk -v m="$MAX_USD" -v s="$spent" 'BEGIN{printf "%.2f", m - s}')"
        if ! awk -v r="$remaining" 'BEGIN{exit !(r >= 0.01)}'; then
          echo "lane-quality: second-judge budget spent ($spent of $MAX_USD USD); stopping, the rest stay unjudged" >&2
          break 2
        fi
        read -r tok _ <<<"$(bank_read)"
        if [ "$tok" != PROCEED ]; then
          echo "lane-quality: bank preflight said $tok; second judge stopped before $stem" >&2
          exit 75
        fi
        judge_call "$packet" "$out" "$d/$stem.judge2.$label.err" "$j2model" "$remaining" "$j2effort" \
          || die "cannot run the second judge on $packet"
        cost="$(jq -r '.total_cost_usd // empty' "$out" 2>/dev/null)"
        if [ -z "$cost" ]; then
          echo "lane-quality: second judge on $stem left its cost unknown; stopping, spend so far is a lower bound" >&2
          break 2
        fi
        spent="$(awk -v s="$spent" -v c="$cost" 'BEGIN{printf "%.4f", s + c}')"
      done < <(jq -r 'if (.rep // 1) > 1 then "\(.task).r\(.rep)" else .task end' "$d/runs.jsonl")
    done
    echo "lane-quality: second judge $label spent $spent USD" >&2
  fi
  python3 "$HERE/lq_stats.py" calibration ${label:+--judge2-label "$label"} $json $noledger "${dirs[@]}"
}

# verdict <baseline-run-dir> <variant-run-dir>...: one TSV row per variant run
# (`<variant>\t<apply|keep>\t<reason>`). A variant is a no-op, so `apply`, only
# when no task it ran regressed against the baseline: acceptance, scope, hook
# denials, and (when both runs were judged) the mean judge score by more than 0.5.
cmd_verdict() {
  [ $# -ge 2 ] || die "verdict needs a baseline run directory and at least one variant run directory"
  local base="$1" d name
  shift
  [ -r "$base/runs.jsonl" ] || die "no runs.jsonl in $base"
  for d in "$@"; do
    [ -r "$d/runs.jsonl" ] || die "no runs.jsonl in $d"
    name="$(jq -rs 'if all(.[]; .variant != null) then (map(.variant) | unique | if length == 1 then .[0] else empty end) else empty end' "$d/runs.jsonl")"
    [ -n "$name" ] || die "$d: its rows must all carry one steering variant name"
    jq -rn --arg name "$name" --slurpfile b "$base/runs.jsonl" --slurpfile v "$d/runs.jsonl" '
      def key: "\(.task)#\(.rep // 1)";
      def jmean: if .judge == null then null else ([.judge.correctness, .judge.scope_discipline, .judge.test_quality, .judge.honesty] | add / 4) end;
      ($b | map({(key): .}) | add) as $B
      | [ $v[] | . as $x | ($B[$x | key]) as $o
          | if $o == null then "\($x.task): no baseline row"
            else
              (if $o.accept_ok and ($x.accept_ok | not) then "\($x.task): acceptance regressed" else empty end),
              (if ($x.accept_passed // 0) < ($o.accept_passed // 0) then "\($x.task): fewer acceptance checks pass" else empty end),
              (if $o.scope_ok and ($x.scope_ok | not) then "\($x.task): scope drift" else empty end),
              (if $x.hook_denials == null and $o.hook_denials != null then "\($x.task): hook denials not recorded" else empty end),
              (if $x.dispatch_unnamed_model == null and $o.dispatch_unnamed_model != null then "\($x.task): dispatch metrics not recorded" else empty end),
              (if ($x.hook_denials // 0) > ($o.hook_denials // 0) then "\($x.task): more hook denials" else empty end),
              (if ($x.dispatch_unnamed_model // 0) > ($o.dispatch_unnamed_model // 0) then "\($x.task): more dispatches with an unnamed model" else empty end),
              (($x | jmean) as $jv | ($o | jmean) as $jo
               | if $jv != null and $jo != null and $jv < $jo - 0.5 then "\($x.task): judge mean \($jv) vs \($jo)" else empty end)
            end ] as $seen
      | ($seen + [ $B | keys[] | select(. as $k | $v | map(key) | index($k) | not) | "\(.): no variant row" ]) as $why
      | "\($name)\t\(if ($why | length) == 0 then "apply" else "keep" end)\t\(if ($why | length) == 0 then "no regression on \($v | length) task run(s)" else ($why | join("; ")) end)"'
  done
}

[ $# -ge 1 ] || usage
case "$1" in
  verdict) shift; cmd_verdict "$@" ;;
  list) all_tasks ;;
  run) shift; cmd_run "$@" ;;
  table) shift; cmd_table "$@" ;;
  pair) shift; cmd_pair "$@" ;;
  judge-pair) shift; need_billed "judge-pair"; cmd_judge_pair "$@" ;;
  calibration) shift; ! has_arg --judge2-model "$@" || need_billed "calibration --judge2-model"; cmd_calibration "$@" ;;
  materialize) shift; [ $# -ge 2 ] || die "materialize <task> <dir> [--reference]"; materialize "$@" ;;
  -h|--help) usage ;;
  *) die "unknown command '$1' (list|run|table|pair|judge-pair|calibration|materialize)" ;;
esac
