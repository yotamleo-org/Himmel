#!/usr/bin/env bash
# test-answer-ab.sh -- the tokens-to-correct-answer A/B: the closed-book
# screen, the arms, the token accounting and the billing stops. No real claude, qmd or
# graphify call: all three are stub commands, and grep runs over a scratch git repo.
#
# Platform guard: Linux/macOS bash; no .ps1 twin (the eval is operator-run on a
# station).
set -uo pipefail
export HIMMEL_BILLED_OK=1   # stubbed claude/codex only; the guarded script refuses a bare run

HERE="$(cd "$(dirname "$0")" && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/answer-ab-test.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }
AB="$HERE/answer-ab.py"

R="$W/repo"; mkdir -p "$R/docs" "$R/bin"
printf 'The queue lock keeps one session per handover doc.\n' > "$R/docs/lock.md"
printf '#!/bin/sh\nrelay_batch() { :; }\n' > "$R/bin/run.sh"
printf 'The zeta rule is a settled decision.\n' > "$R/docs/zeta.md"
printf 'unrelated words only\n' > "$R/docs/other.md"
git -C "$R" init -q && git -C "$R" add -A && git -C "$R" -c user.email=t@t -c user.name=t commit -q -m init

Q="$W/q.jsonl"
cat > "$Q" <<'EOF'
{"id":"a1","kind":"where","q":"where is the queue lock described","gold":["docs/lock.md"],"reason":[]}
{"id":"a2","kind":"where","q":"where is relay_batch defined","gold":["bin/run.sh"],"reason":[]}
{"id":"a3","kind":"what","q":"what is the zeta rule","gold":["docs/zeta.md"],"reason":[]}
EOF

# graphify names a wrong file for every question; qmd finds nothing.
cat > "$W/graph" <<'EOF'
#!/usr/bin/env bash
printf 'NODE nothing [src=docs/other.md loc=L1 community=x]\n'
EOF
cat > "$W/qmd" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
printf '[]\n'
EOF
# The answerer stub. Closed book (no RETRIEVED CONTEXT section) it can name only docs/zeta.md;
# with context it names the first repo path in the context. Usage tracks the prompt size.
cat > "$W/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DIR/argv.log"
prompt="$(cat)"
n=$((${#prompt} / 4))
case "${STUB_MODE:-}" in
garbage) echo 'not json'; exit 0 ;;
esac
if printf '%s' "$prompt" | grep -q 'RETRIEVED CONTEXT'; then
  ctx="$(printf '%s' "$prompt" | sed -n '/RETRIEVED CONTEXT/,$p')"
  f="$(printf '%s' "$ctx" | grep -oE '[A-Za-z0-9_./-]+\.(md|sh|py)' | head -1)"
else
  f="docs/zeta.md"
fi
printf '{"result":"I think so.\\nANSWER: [\\"%s\\"]","usage":{"input_tokens":%d,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":10},"total_cost_usd":%s}\n' "$f" "$n" "${STUB_COST:-0.01}"
EOF
printf '#!/usr/bin/env bash\necho PROCEED\n' > "$W/pf-ok"
printf '#!/usr/bin/env bash\necho REFUSE\n' > "$W/pf-no"
chmod +x "$W/graph" "$W/qmd" "$W/claude" "$W/pf-ok" "$W/pf-no"
export RETRIEVAL_EVAL_GRAPH_CMD="$W/graph" RETRIEVAL_EVAL_QMD_CMD="$W/qmd" CLAUDE_BIN="$W/claude" STUB_DIR="$W"
export BANK_PREFLIGHT="$W/pf-ok"
export HIMMEL_EVAL_RUNS_LEDGER="$W/ledger.jsonl"

# 1. the screen keeps only the questions the closed-book answerer fails.
python3 -I "$AB" run --repo "$R" --questions "$Q" --out "$W/out" > "$W/run.txt" 2>&1
eq "run exits 0" "0" "$?"
eq "screen keeps the closed-book failures, drops the one it answers" "a1 a2" "$(tr '\n' ' ' < "$W/out/screened.txt" | sed 's/ $//')"

t() { awk -F'\t' -v a="$1" -v c="$2" 'NR==1{for(i=1;i<=NF;i++)h[$i]=i;next} $1==a{print $h[c]}' "$W/out/table.tsv"; }

# 2. no ceiling: the no-retrieval baseline is below n/n, and a retrieval arm is told apart from it.
eq "baseline arm n" "2" "$(t none n)"
eq "baseline arm scores below n/n" "0" "$(t none correct)"
eq "grep arm answers both" "2" "$(t grep correct)"
eq "graphify (wrong file) arm answers none" "0" "$(t graphify correct)"
eq "an arm with no correct answer has no tokens-per-correct" "-" "$(t graphify tokens_per_correct)"

# 3. tokens to a correct answer: total session tokens of the arm over its correct answers.
tot="$(t grep tokens_total)"
eq "grep tokens_per_correct is tokens_total over correct" "$((tot / 2))" "$(t grep tokens_per_correct | cut -d. -f1)"
if [ "$(t grep tokens_total)" -gt "$(t none tokens_total)" ]; then pass "retrieval context adds session tokens over the baseline"; else fail "retrieval context adds session tokens over the baseline"; fi

# 4. the six arms are all in the table.
eq "table lists every arm" "fused graphify grep none pathident" "$(awk -F'\t' 'NR>1{print $1}' "$W/out/table.tsv" | sort | tr '\n' ' ' | sed 's/ $//')"

# 5. billing rules: explicit permission mode, json output, never bypassPermissions, no tools.
if grep -q -- '--permission-mode dontAsk' "$W/argv.log" && grep -q -- '--output-format json' "$W/argv.log"; then pass "claude runs with dontAsk and json output"; else fail "claude runs with dontAsk and json output"; fi
if grep -q bypassPermissions "$W/argv.log"; then fail "no bypassPermissions"; else pass "no bypassPermissions"; fi
if grep -q -- '--model claude-haiku' "$W/argv.log"; then pass "the answerer is haiku"; else fail "the answerer is haiku"; fi

# 6. a bank-preflight refusal stops the sweep and says so.
BANK_PREFLIGHT="$W/pf-no" python3 -I "$AB" run --repo "$R" --questions "$Q" --out "$W/out-bank" > "$W/bank.txt" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && [ -f "$W/out-bank/STOPPED" ]; then pass "bank refusal stops the run (rc $rc)"; else fail "bank refusal stops the run (rc $rc)"; fi

# 7. the dollar cap stops a sweep before it overshoots.
STUB_COST=0.5 python3 -I "$AB" run --repo "$R" --questions "$Q" --out "$W/out-cap" --max-usd 0.6 > "$W/cap.txt" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && grep -q 'max-usd' "$W/out-cap/STOPPED" 2>/dev/null; then pass "max-usd stops the run (rc $rc)"; else fail "max-usd stops the run (rc $rc)"; fi

# 8. an unparseable claude reply is an incorrect, errored row, never a crash.
STUB_MODE=garbage python3 -I "$AB" run --repo "$R" --questions "$Q" --out "$W/out-garbage" > "$W/garbage.txt" 2>&1
rc=$?
if grep -q 'Traceback' "$W/garbage.txt"; then fail "garbage reply does not crash"; else pass "garbage reply does not crash"; fi
if [ "$rc" -ne 0 ]; then pass "garbage reply exits nonzero (rc $rc)"; else fail "garbage reply exits nonzero (rc $rc)"; fi
eq "garbage replies are errored, incorrect rows" "0" "$(python3 -I -c 'import json,sys; print(sum(1 for l in open(sys.argv[1]) if not json.loads(l)["error"] or json.loads(l)["correct"]))' "$W/out-garbage/results.jsonl")"

# 9. an empty --arms is a usage error before any call is billed; a rerun clears the old STOPPED.
python3 -I "$AB" run --repo "$R" --questions "$Q" --out "$W/out-empty" --arms "" > "$W/empty.txt" 2>&1
eq "empty --arms is a usage error (rc 64)" "64" "$?"
python3 -I "$AB" run --repo "$R" --questions "$Q" --out "$W/out-bank" > "$W/rerun.txt" 2>&1
if [ ! -f "$W/out-bank/STOPPED" ]; then pass "a clean rerun clears the stale STOPPED marker"; else fail "a clean rerun clears the stale STOPPED marker"; fi

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
