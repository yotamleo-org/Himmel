#!/usr/bin/env bash
# test-answer-ab.sh -- the tokens-to-correct-answer A/B: the closed-book
# screen, the arms, the token accounting and the billing stops. No real claude, qmd or
# graphify call: all three are stub commands, and grep runs over a scratch git repo.
#
# Platform guard: Linux/macOS bash; the eval is operator-run on a station.
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
cat >> "$STUB_DIR/qmd.log"
printf '\n' >> "$STUB_DIR/qmd.log"
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
# A realistic session (--mcp-config given) is played by session.py, which calls the route tool for real.
case "$*" in
*--mcp-config*) printf '%s' "$prompt" | python3 -I "$STUB_DIR/session.py" "$@"; exit $? ;;
esac
if printf '%s' "$prompt" | grep -q 'RETRIEVED CONTEXT'; then
  ctx="$(printf '%s' "$prompt" | sed -n '/RETRIEVED CONTEXT/,$p')"
  f="$(printf '%s' "$ctx" | grep -oE '[A-Za-z0-9_./-]+\.(md|sh|py)' | head -1)"
else
  f="docs/zeta.md"
fi
printf '{"result":"I think so.\\nANSWER: [\\"%s\\"]","usage":{"input_tokens":%d,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":10},"total_cost_usd":%s}\n' "$f" "$n" "${STUB_COST:-0.01}"
EOF
# The realistic-session stub: reads the --mcp-config it was given, speaks MCP stdio to the route server in it
# (initialize, tools/list, tools/call), names the first path in the tool result, and reports a fixed usage split
# (vanilla: no tool, 3 turns; routed: one tool call, 4 turns). total_cost_usd is a flat trap figure.
cat > "$W/session.py" <<'EOF'
import json, os, re, subprocess, sys
d = os.environ["STUB_DIR"]
argv = sys.argv[1:]
prompt = sys.stdin.read()
cfg_path = argv[argv.index("--mcp-config") + 1]
cfg = json.load(open(cfg_path))
servers = cfg.get("mcpServers") or {}
kind = "routed" if servers else "vanilla"
norm = []
skip = 0
for i, x in enumerate(argv):
    if skip:
        skip -= 1
    elif x in ("--mcp-config", "--allowedTools", "--max-budget-usd"):
        skip = 1
    else:
        norm.append(x)
open(os.path.join(d, "sess-argv-%s.log" % kind), "a").write(" ".join(norm) + "\n")
open(os.path.join(d, "sess-allowed-%s.log" % kind), "a").write(argv[argv.index("--allowedTools") + 1] + "\n" if "--allowedTools" in argv else "none\n")
open(os.path.join(d, "sess-prompt.log"), "a").write(prompt + "\n=====\n")
text = ""
if servers:
    srv = next(iter(servers.values()))
    env = dict(os.environ, **(srv.get("env") or {}))
    p = subprocess.Popen([srv["command"]] + srv.get("args", []), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, text=True, env=env)
    q = re.search(r"Question about the himmel repository: (.*)", prompt).group(1)
    msgs = [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "stub", "version": "1"}}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
            {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "route", "arguments": {"query": q}}}]
    out, _ = p.communicate("".join(json.dumps(m) + "\n" for m in msgs), timeout=60)
    by = {}
    for line in out.splitlines():
        if line.strip():
            m = json.loads(line)
            by[m.get("id")] = m
    open(os.path.join(d, "sess-tools.log"), "a").write(json.dumps([t["name"] for t in by[2]["result"]["tools"]]) + "\n")
    text = "".join(c["text"] for c in by[3]["result"]["content"])
    open(os.path.join(d, "route.log"), "a").write(text + "\n=====\n")
m = re.search(r"[A-Za-z0-9_./-]+\.(md|sh|py)", text)
f = m.group(0) if m else "docs/zeta.md"
u = ({"input_tokens": 120, "output_tokens": 60, "cache_read_input_tokens": 9000, "cache_creation_input_tokens": 2000} if servers
     else {"input_tokens": 100, "output_tokens": 50, "cache_read_input_tokens": 9000, "cache_creation_input_tokens": 1000})
print(json.dumps({"type": "result", "is_error": False, "num_turns": 4 if servers else 3,
                  "result": "Looked around.\nANSWER: " + json.dumps([f]), "usage": u, "total_cost_usd": 9.99}))
EOF
printf '#!/usr/bin/env bash\necho PROCEED\n' > "$W/pf-ok"
printf '#!/usr/bin/env bash\necho REFUSE\n' > "$W/pf-no"
chmod +x "$W/graph" "$W/qmd" "$W/claude" "$W/pf-ok" "$W/pf-no"
export RETRIEVAL_EVAL_GRAPH_CMD="$W/graph" RETRIEVAL_EVAL_QMD_CMD="$W/qmd" CLAUDE_BIN="$W/claude" STUB_DIR="$W"
export BANK_PREFLIGHT="$W/pf-ok"
export HIMMEL_EVAL_RUNS_LEDGER="$W/ledger.jsonl"
# A stub rtk on PATH: `rtk rewrite "<cmd>"` answers `rtk <cmd>`, `rtk grep ...` runs grep; every call is logged.
mkdir -p "$W/bin"
cat > "$W/bin/rtk" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RTK_LOG"
case "$1" in
rewrite) printf 'rtk %s' "$2" ;;
grep) shift; exec grep "$@" ;;
esac
STUB
chmod +x "$W/bin/rtk"
export RTK_LOG="$W/rtk.log" PATH="$W/bin:$PATH"

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
eq "table lists every arm" "fused graphify grep grep-rtk none pathident" "$(awk -F'\t' 'NR>1{print $1}' "$W/out/table.tsv" | sort | tr '\n' ' ' | sed 's/ $//')"
eq "grep-rtk arm answers both" "2" "$(t grep-rtk correct)"
eq "grep-rtk retrieval went through rtk" "yes" "$(grep -q '^rewrite grep ' "$RTK_LOG" && grep -q '^grep -n -I -H -i -F' "$RTK_LOG" && echo yes || echo no)"
mkdir -p "$W/nortk"
for tool in git bash sh grep python3 env; do ln -sf "$(command -v "$tool")" "$W/nortk/$tool"; done
PATH="$W/nortk" python3 -I "$AB" run --repo "$R" --questions "$Q" --out "$W/out-nortk" --arms grep,grep-rtk > "$W/nortk.txt" 2>&1
eq "without rtk the grep-rtk arm is skipped with its reason" "1 grep" "$(grep -c 'skipping grep-rtk: rtk is not on PATH' "$W/nortk.txt") $(awk -F'\t' 'NR>1{print $1}' "$W/out-nortk/table.tsv" | tr '\n' ' ' | sed 's/ $//')"

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

# 10. the four realistic arms. A sonnet session; the stub reports a fixed usage split per session.
Q2="$W/q2.jsonl"
cat > "$Q2" <<'EOF'
{"id":"a1","kind":"where","q":"where is the queue lock described","gold":["docs/lock.md"],"reason":[],"split":"insample"}
{"id":"a2","kind":"where","q":"where is relay_batch defined","gold":["bin/run.sh"],"reason":[],"split":"insample"}
{"id":"a3","kind":"what","q":"what is the zeta rule","gold":["docs/zeta.md"],"reason":[],"split":"heldout"}
EOF
HOMEX="$W/home"; mkdir -p "$HOMEX"
REAL="vanilla,fused-cached,bm25-rerank,vec-rerank"
rm -f "$W"/sess-*.log "$W/route.log" "$W/qmd.log" "$W/ledger.jsonl"
HOME="$HOMEX" python3 -I "$AB" run --repo "$R" --questions "$Q2" --out "$W/out-real" --arms "$REAL" --model claude-sonnet-5-5 --pool 3 --n 3 > "$W/real.txt" 2>&1
eq "the four realistic arms are accepted and the run completes" "0" "$?"
rt() { awk -F'\t' -v a="$1" -v c="$2" 'NR==1{for(i=1;i<=NF;i++)h[$i]=i;next} $1==a{print $h[c]}' "$W/out-real/table.tsv"; }
eq "table lists the four realistic arms" "bm25-rerank fused-cached vanilla vec-rerank" "$(awk -F'\t' 'NR>1{print $1}' "$W/out-real/table.tsv" | sort | tr '\n' ' ' | sed 's/ $//')"
eq "results.jsonl holds one row per paid call (written as each call lands)" "12" "$(wc -l < "$W/out-real/results.jsonl" | tr -d ' ')"
eq "each realistic arm answers every question once, with no closed-book screen" "3 3 3 3" "$(rt vanilla n) $(rt fused-cached n) $(rt bm25-rerank n) $(rt vec-rerank n)"

# 11. cost is priced per call from the usage split by the price table, never the flat total_cost_usd.
read -r p_in p_out p_cr p_cw <<< "$(awk -F'\t' '$1=="claude-sonnet-5-5"{print $2, $3, $4, $5}' "$HERE/../../lanes/lib/model-prices.tsv")"
want_v="$(python3 -I -c 'import sys; i,o,r,w=map(float,sys.argv[1:5]); print("%.4f" % (3*(100*i+50*o+9000*r+1000*w)/1e6))' "$p_in" "$p_out" "$p_cr" "$p_cw")"
want_f="$(python3 -I -c 'import sys; i,o,r,w=map(float,sys.argv[1:5]); print("%.4f" % (3*(120*i+60*o+9000*r+2000*w)/1e6))' "$p_in" "$p_out" "$p_cr" "$p_cw")"
eq "vanilla priced_usd is the price-table figure for its usage" "$want_v" "$(rt vanilla priced_usd)"
eq "fused-cached priced_usd is the price-table figure for its usage" "$want_f" "$(rt fused-cached priced_usd)"
eq "the cost is not the flat total_cost_usd (9.99 a call)" "$want_v" "$(rt vanilla cost_usd)"

# 12. the cache read and cache creation split shows in the token mix and in cached_share.
eq "vanilla token mix" "300 150 27000 3000" "$(rt vanilla input) $(rt vanilla output) $(rt vanilla cache_read) $(rt vanilla cache_creation)"
eq "fused-cached token mix" "360 180 27000 6000" "$(rt fused-cached input) $(rt fused-cached output) $(rt fused-cached cache_read) $(rt fused-cached cache_creation)"
eq "vanilla cached_share is cache_read over input + cache_read + cache_creation" "0.891" "$(rt vanilla cached_share)"
eq "fused-cached cached_share" "0.809" "$(rt fused-cached cached_share)"
eq "turns_mean from num_turns" "3.0 4.0" "$(rt vanilla turns_mean) $(rt fused-cached turns_mean)"

# 13. the route output is a tool result inside the session, never in the prompt; the prefix is identical across arms.
if grep -q 'RETRIEVED CONTEXT' "$W/sess-prompt.log"; then fail "no route output pasted into the prompt"; else pass "no route output pasted into the prompt"; fi
if grep -q 'docs/lock.md' "$W/route.log" && ! grep -q 'docs/lock.md' "$W/sess-prompt.log"; then pass "the fused route text reaches the session as a tool result, not in the prompt"; else fail "the fused route text reaches the session as a tool result, not in the prompt"; fi
eq "each routed arm is offered exactly one route tool" "1" "$(sort -u "$W/sess-tools.log" | wc -l | tr -d ' ')"
eq "vanilla has tools Read, Grep, Glob only" "Read,Grep,Glob" "$(sort -u "$W/sess-allowed-vanilla.log")"
eq "routed arms add the one route tool to the same three" "Read,Grep,Glob,mcp__route__route" "$(sort -u "$W/sess-allowed-routed.log")"
eq "vanilla argv is the same on every call" "1" "$(sort -u "$W/sess-argv-vanilla.log" | wc -l | tr -d ' ')"
va="$(sort -u "$W/sess-argv-vanilla.log")"; ra="$(sort -u "$W/sess-argv-routed.log" | head -1)"
eq "the session flags (system prompt, tools, model, permission mode) are byte-identical in vanilla and routed arms" "$va" "$ra"
if grep -q -- '--permission-mode dontAsk' "$W/sess-argv-vanilla.log" && grep -q -- '--output-format json' "$W/sess-argv-vanilla.log" && ! grep -q bypassPermissions "$W/sess-argv-vanilla.log"; then pass "sessions run with dontAsk and json output, never bypassPermissions"; else fail "sessions run with dontAsk and json output, never bypassPermissions"; fi
if grep -q -- '--append-system-prompt-file .*worker-preface.md' "$W/sess-argv-vanilla.log"; then pass "the session carries the himmel worker preface"; else fail "the session carries the himmel worker preface"; fi
# the rerank arms: lex only + rerank, vec only + rerank (a qmd request each)
if grep -q '"type": "lex"' "$W/qmd.log" && grep -E '"type": "lex"' "$W/qmd.log" | grep -v '"type": "vec"' | grep -q '"rerank": true'; then pass "bm25-rerank sends a lex-only search with rerank true"; else fail "bm25-rerank sends a lex-only search with rerank true"; fi
if grep -E '"type": "vec"' "$W/qmd.log" | grep -v '"type": "lex"' | grep -q '"rerank": true'; then pass "vec-rerank sends a vec-only search with rerank true"; else fail "vec-rerank sends a vec-only search with rerank true"; fi

# 14. one eval-runs row, eval answer-ab, in the temp ledger; the real ledger is untouched.
eq "exactly one ledger row was written" "1" "$(wc -l < "$W/ledger.jsonl" | tr -d ' ')"
lg() { python3 -I -c 'import json,sys; r=json.loads(open(sys.argv[1]).readline()); print(eval(sys.argv[2]))' "$W/ledger.jsonl" "$1"; }
eq "the row is the answer-ab eval" "answer-ab" "$(lg 'r["eval"]')"
eq "row n is the question count" "3" "$(lg 'r["n"]')"
eq "row carries per-arm correct" "1" "$(lg 'r["metrics"]["vanilla.correct"]')"
eq "row carries cost_usd, cost_per_correct, cached_share, ms_median, turns_mean per arm" "yes" "$(lg '"yes" if all(("%s.%s" % (a, m)) in r["metrics"] for a in ("vanilla","fused-cached","bm25-rerank","vec-rerank") for m in ("cost_usd","cost_per_correct","tokens_per_correct","cached_share","ms_median","turns_mean","input","output","cache_read","cache_creation")) else "no"')"
eq "row cost_usd is the priced figure" "$want_v" "$(lg '"%.4f" % r["metrics"]["vanilla.cost_usd"]')"
eq "row carries the insample and heldout split" "2 1 1" "$(lg 'r["metrics"]["vanilla.insample.n"]') $(lg 'r["metrics"]["vanilla.heldout.n"]') $(lg 'r["metrics"]["vanilla.heldout.correct"]')"
eq "row cases are per question and mark the heldout one" "True" "$(lg 'r["cases"]["a3"]["heldout"]')"
if [ ! -e "$HOMEX/.himmel/eval-runs.jsonl" ]; then pass "the HOME ledger is not written when HIMMEL_EVAL_RUNS_LEDGER names one"; else fail "the HOME ledger is not written when HIMMEL_EVAL_RUNS_LEDGER names one"; fi
HOME="$HOMEX" python3 -I "$AB" run --repo "$R" --questions "$Q2" --out "$W/out-nol" --arms vanilla --model claude-sonnet-5-5 --pool 3 --n 3 --no-ledger > "$W/nol.txt" 2>&1
eq "--no-ledger writes no further row" "1" "$(wc -l < "$W/ledger.jsonl" | tr -d ' ')"
(unset HIMMEL_EVAL_RUNS_LEDGER; HOME="$HOMEX" python3 -I "$AB" run --repo "$R" --questions "$Q2" --out "$W/out-home" --arms vanilla --model claude-sonnet-5-5 --pool 3 --n 3 > "$W/home.txt" 2>&1)
eq "without the override the row lands under HOME, not the real home" "1" "$(wc -l < "$HOMEX/.himmel/eval-runs.jsonl" 2>/dev/null | tr -d ' ')"

# 15. the billing stops hold for the realistic arms: max-usd and bank refusal stop before another call.
rm -f "$W"/sess-argv-*.log
python3 -I "$AB" run --repo "$R" --questions "$Q2" --out "$W/out-rcap" --arms "$REAL" --model claude-sonnet-5-5 --pool 3 --n 3 --max-usd 0.001 > "$W/rcap.txt" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && grep -q 'max-usd' "$W/out-rcap/STOPPED" 2>/dev/null; then pass "max-usd stops a realistic run (rc $rc)"; else fail "max-usd stops a realistic run (rc $rc)"; fi
eq "only the first session was billed" "1" "$(cat "$W"/sess-argv-*.log | wc -l | tr -d ' ')"
rm -f "$W"/sess-argv-*.log
BANK_PREFLIGHT="$W/pf-no" python3 -I "$AB" run --repo "$R" --questions "$Q2" --out "$W/out-rbank" --arms "$REAL" --model claude-sonnet-5-5 --pool 3 --n 3 > "$W/rbank.txt" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && [ -f "$W/out-rbank/STOPPED" ] && ! ls "$W"/sess-argv-*.log > /dev/null 2>&1; then pass "a bank refusal bills no realistic session (rc $rc)"; else fail "a bank refusal bills no realistic session (rc $rc)"; fi

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
