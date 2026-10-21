#!/usr/bin/env bash
# run.sh -- graphify leg A/B sweep.
#
#   run.sh run [--reps N] [--out DIR] [--max-usd USD] [--tasks id,id] [--model M]
#   run.sh plan [--reps N] [--tasks id,id]     print the run matrix, call nothing
#
# Arm A: graphify allowed and prompted (scripts/graphify/leg-graph.sh).
# Arm B: no graphify (grep/read only), graphify tools denied and the prompt says so.
# Same model, same task prompt, same tool set (Bash,Read), no MCP servers in either
# arm so qmd is not a confound. Each run happens in a detached checkout of the
# pinned base sha under the OUT dir, so the task set and truth files (which sit in
# the branch under test) are not visible to the agent.
#
# Billing rule: bank-preflight before EVERY run and STOP on a refusal (the partial
# result is still ingested), --output-format json, explicit --permission-mode.
# Orders alternate by (rep + task index) parity so drift in load is not an arm effect.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
TASKS_JSON="$HERE/tasks.json"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
BANK_PREFLIGHT="${BANK_PREFLIGHT:-$REPO/scripts/lib/usage-preflight.sh}"
MODEL="claude-sonnet-5-5"
REPS=3
MAX_USD=8
PER_RUN_USD=1.5
TIMEOUT=600
OUT=""
ONLY=""

ARM_A_TEXT='Graphify is available for structure questions. Before broad greps, try: bash scripts/graphify/leg-graph.sh query "<question>" or bash scripts/graphify/leg-graph.sh explain "<concept>" (it reads a pre-built knowledge graph of this repo and may be a few commits behind; verify what it returns against the source). Use grep and Read as needed.'
ARM_B_TEXT='Do not use graphify and do not read any graphify-out directory. Use grep, git grep, find and Read only.'

sub="${1:-}"
[ -n "$sub" ] && shift
while [ $# -gt 0 ]; do
  case "$1" in
    --reps) REPS="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --max-usd) MAX_USD="$2"; shift 2 ;;
    --tasks) ONLY="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    *) echo "run.sh: unknown arg $1" >&2; exit 2 ;;
  esac
done

task_ids() {
  python3 -I -c '
import json, sys
only = [x for x in sys.argv[2].split(",") if x]
for t in json.load(open(sys.argv[1]))["tasks"]:
    if not only or t["id"] in only:
        print(t["id"])
' "$TASKS_JSON" "$ONLY"
}

task_prompt() {
  python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
t = next(t for t in d["tasks"] if t["id"] == sys.argv[2])
print(t["prompt"] + "\n\n" + d["answer_format"])
' "$TASKS_JSON" "$1"
}

case "$REPS" in ''|*[!0-9]*|0) echo "run.sh: --reps must be a positive integer" >&2; exit 2 ;; esac
[ -n "$(task_ids)" ] || { echo "run.sh: --tasks matches no task id" >&2; exit 2; }

case "$sub" in
  plan)
    for rep in $(seq 1 "$REPS"); do
      i=0
      for t in $(task_ids); do
        if [ $(((rep + i) % 2)) -eq 0 ]; then order="A B"; else order="B A"; fi
        i=$((i + 1))
        printf 'rep=%s task=%s order=%s\n' "$rep" "$t" "$order"
      done
    done
    exit 0
    ;;
  run) ;;
  *) echo "usage: run.sh run|plan [--reps N] [--out DIR] [--max-usd USD] [--tasks a,b] [--model M]" >&2; exit 2 ;;
esac

TIMEOUT_BIN="$(command -v timeout || command -v gtimeout)" || { echo "run.sh: needs timeout (coreutils; gtimeout on macOS)" >&2; exit 2; }
BASE="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["base_sha"])' "$TASKS_JSON")"
[ -n "$OUT" ] || OUT="${HOME}/.himmel/eval/graphify-ab/$(date +%Y%m%dT%H%M%S)"
mkdir -p "$OUT/raw" || exit 1
OUT="$(cd "$OUT" && pwd)" || exit 1
CHECKOUT="$OUT/checkout"
git -C "$REPO" worktree add --detach "$CHECKOUT" "$BASE" >/dev/null || { echo "run.sh: cannot create checkout at $BASE" >&2; exit 1; }
# shellcheck disable=SC2317,SC2329  # invoked by the EXIT trap
cleanup() { git -C "$REPO" worktree remove --force "$CHECKOUT" >/dev/null 2>&1; }
trap cleanup EXIT

spent() {
  python3 -I -c '
import glob, json, sys
s = 0.0
for f in glob.glob(sys.argv[1] + "/raw/*.json"):
    try:
        c = json.load(open(f)).get("total_cost_usd")
        s += float(c) if c is not None else float(sys.argv[2])  # no cost reported: assume the per-run cap
    except (ValueError, OSError, AttributeError, TypeError):
        s += float(sys.argv[2])  # unparseable output of a billed run: assume the full per-run cap
print("%.4f" % s)
' "$OUT" "$PER_RUN_USD"
}

stopped=""
failed=0
for rep in $(seq 1 "$REPS"); do
  i=0
  for t in $(task_ids); do
    if [ $(((rep + i) % 2)) -eq 0 ]; then order="A B"; else order="B A"; fi
    i=$((i + 1))
    for arm in $order; do
      if ! pf="$(bash "$BANK_PREFLIGHT" 2>&1)" || ! printf '%s\n' "$pf" | grep -qx 'PROCEED'; then
        stopped="bank-preflight refused before $t/$arm/rep$rep"
        break 3
      fi
      # per-run cap = min(PER_RUN_USD, what is left of MAX_USD): the sweep can never overshoot
      run_cap="$(python3 -I -c 'import sys; print("%.4f" % min(float(sys.argv[3]), float(sys.argv[2]) - float(sys.argv[1])))' "$(spent)" "$MAX_USD" "$PER_RUN_USD")"
      if python3 -I -c 'import sys; sys.exit(0 if float(sys.argv[1]) > 0 else 1)' "$run_cap"; then :; else
        stopped="max-usd $MAX_USD reached before $t/$arm/rep$rep"
        break 3
      fi
      tag="$t.$arm.r$rep"
      [ -f "$OUT/raw/$tag.json" ] && continue
      if [ "$arm" = A ]; then sys_text="$ARM_A_TEXT"; deny=""; else sys_text="$ARM_B_TEXT"; deny='Bash(graphify:*),Bash(bash scripts/graphify/leg-graph.sh:*)'; fi
      prompt="$(task_prompt "$t")"
      start="$(date +%s)"
      # graphify A/B agent run, bank-preflighted per run, explicit permission mode, budget-capped
      # launch-profile-ok: eval arm pins its own --tools/--allowedTools and --strict-mcp-config; a leg profile would change the measured condition
      ( cd "$CHECKOUT" && "$TIMEOUT_BIN" "$TIMEOUT" "$CLAUDE_BIN" -p "$prompt" --model "$MODEL" \
          --permission-mode dontAsk --output-format json --max-budget-usd "$run_cap" \
          --tools Bash,Read --allowedTools Bash,Read ${deny:+--disallowedTools "$deny"} \
          --strict-mcp-config --append-system-prompt "$sys_text" ) > "$OUT/raw/$tag.json" 2> "$OUT/raw/$tag.err"
      rc=$?
      [ "$rc" -eq 0 ] || failed=$((failed + 1))
      printf '%s %s\n' "$rc" "$(( $(date +%s) - start ))" > "$OUT/raw/$tag.meta"
      printf 'run %s rc=%s wall=%ss\n' "$tag" "$rc" "$(( $(date +%s) - start ))"
    done
  done
done

[ -n "$stopped" ] && { printf 'STOPPED: %s\n' "$stopped" | tee "$OUT/STOPPED"; }
printf 'out=%s spent_usd=%s\n' "$OUT" "$(spent)"
ingest_rc=0
python3 -I "$HERE/summarize.py" ingest "$OUT" >/dev/null && printf 'runs=%s/runs.jsonl\n' "$OUT" || ingest_rc=1
[ "$failed" -eq 0 ] || printf 'FAILED: %s run(s) exited non-zero\n' "$failed" >&2
[ "$ingest_rc" -eq 0 ] && [ -z "$stopped" ] && [ "$failed" -eq 0 ]
