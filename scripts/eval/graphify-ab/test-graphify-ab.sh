#!/usr/bin/env bash
# test-graphify-ab.sh -- Truth rules, exact-match scorer, run matrix,
# ingest/report maths and the preflight stop of the graphify A/B harness. No model
# call: run.sh is driven by a stub claude and a stub bank-preflight.
#
# Platform guard: Linux/macOS bash; no .ps1 twin (the eval is operator-run on a
# station, like scripts/eval/harness-run.py).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/graphify-ab-test.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }
py() { python3 -I "$@"; }

# 1. truth sizes are the ones frozen when the task set was written (base sha).
sizes="$(py "$HERE/truth.py" compute | py -c 'import json,sys; d=json.load(sys.stdin); print(",".join(str(len(d[k])) for k in sorted(d)))')"
eq "truth sizes (go,graphify-bin,mustrun,qmd-profiles,trust)" "6,6,16,3,7" "$sizes"

# 2. scorer: exact, near-miss (RED control), unparsed.
printf 'blah\nANSWER: ["console-judge", "leg-impl", "telegram"]\n' > "$W/ok.txt"
printf 'ANSWER: ["leg-impl", "telegram"]\n' > "$W/miss.txt"
printf 'no answer line here\n' > "$W/none.txt"
c() { py "$HERE/truth.py" score --truth qmd-only-profiles --answer "$1" | py -c 'import json,sys; d=json.load(sys.stdin); print(d["correct"], d["parsed"], round(d["recall"],2))'; }
eq "scorer: exact set is correct" "True True 1.0" "$(c "$W/ok.txt")"
eq "scorer: missing item is incorrect (RED control)" "False True 0.67" "$(c "$W/miss.txt")"
eq "scorer: no ANSWER line is unparsed" "False False 0.0" "$(c "$W/none.txt")"

# 3. matrix: 5 tasks x 3 reps = 15 task-rep rows -> 30 runs.
eq "plan prints 15 rows" "15" "$(bash "$HERE/run.sh" plan | wc -l | tr -d ' ')"

# 4. sweep with a stub claude: arm B answers right, arm A answers wrong.
cat > "$W/claude" <<'STUB'
#!/usr/bin/env bash
# stub: ARM A = text mentions leg-graph.sh in --append-system-prompt
sp=""; while [ $# -gt 0 ]; do [ "$1" = "--append-system-prompt" ] && sp="$2"; shift; done
case "$sp" in
  *leg-graph*) ans='ANSWER: ["wrong"]' ;;
  *) ans='ANSWER: ["console-judge", "leg-impl", "telegram"]' ;;
esac
printf '{"result":"%s","is_error":false,"session_id":"s","num_turns":3,"total_cost_usd":0.1,"usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000}}\n' "$(printf '%s' "$ans" | sed 's/"/\\"/g')"
STUB
chmod +x "$W/claude"
printf '#!/usr/bin/env bash\necho PROCEED\n' > "$W/pf-ok"
printf '#!/usr/bin/env bash\necho REFUSE\nexit 1\n' > "$W/pf-no"
OUT="$W/out"
CLAUDE_BIN="$W/claude" BANK_PREFLIGHT="$W/pf-ok" bash "$HERE/run.sh" run --reps 2 --tasks t5-qmd-only-profiles --out "$OUT" > "$W/run.log" 2>&1
eq "stub sweep wrote 4 raw runs" "4" "$(find "$OUT/raw" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
eq "stub sweep: arm B correct, arm A wrong" "A:False,B:True" "$(py -c '
import json,sys
r=[json.loads(l) for l in open(sys.argv[1])]
print(",".join("%s:%s" % (a, all(x["correct"] for x in r if x["arm"]==a)) for a in "AB"))' "$OUT/runs.jsonl")"
eq "weighted tokens = 10 + 1.25*100 + 0.1*1000 + 5*20" "335.0" "$(py -c '
import json,sys
print(json.loads(open(sys.argv[1]).readline())["weighted_tokens"])' "$OUT/runs.jsonl")"
py "$HERE/summarize.py" report "$OUT" > "$W/report.md"
eq "report: runs without transcripts are INCONCLUSIVE, never DROP" "1" "$(grep -c '^VERDICT: INCONCLUSIVE' "$W/report.md")"

# 4b. order alternates even with one task; a relative --out is made absolute.
eq "plan alternates arm order with one task" "B A,A B,B A" "$(bash "$HERE/run.sh" plan --reps 3 --tasks t5-qmd-only-profiles | sed 's/.*order=//' | paste -sd, -)"
eq "plan alternates per task with an even task count" "t1-mustrun-members:A B,t1-mustrun-members:B A,t2-graphify-bin-suites:A B,t2-graphify-bin-suites:B A" \
  "$(bash "$HERE/run.sh" plan --reps 2 --tasks t1-mustrun-members,t2-graphify-bin-suites | sed 's/rep=[0-9]* task=\([^ ]*\) order=\(.*\)/\1:\2/' | sort | paste -sd, -)"
(cd "$W" && CLAUDE_BIN="$W/claude" BANK_PREFLIGHT="$W/pf-ok" bash "$HERE/run.sh" run --reps 1 --tasks t5-qmd-only-profiles --out rel-out > "$W/run3.log" 2>&1)
eq "relative --out: raw runs land under it" "2" "$(find "$W/rel-out/raw" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"

printf '#!/usr/bin/env bash\nexit 3\n' > "$W/claude-fail"
chmod +x "$W/claude-fail"
CLAUDE_BIN="$W/claude-fail" BANK_PREFLIGHT="$W/pf-ok" bash "$HERE/run.sh" run --reps 1 --tasks t5-qmd-only-profiles --out "$W/out-fail" > "$W/run4.log" 2>&1
eq "every claude call failing makes the sweep exit non-zero" "1" "$?"
eq "unparseable billed output counts as the full per-run cap" "3.0000" "$(grep -o 'spent_usd=[0-9.]*' "$W/run4.log" | cut -d= -f2)"

# 5. preflight refusal stops the sweep before any run and says so.
OUT2="$W/out2"
CLAUDE_BIN="$W/claude" BANK_PREFLIGHT="$W/pf-no" bash "$HERE/run.sh" run --reps 1 --tasks t5-qmd-only-profiles --out "$OUT2" > "$W/run2.log" 2>&1
eq "refused preflight: exit 1" "1" "$?"
eq "refused preflight: no run happened" "0" "$(find "$OUT2/raw" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
eq "refused preflight: STOPPED recorded" "1" "$(grep -c '^STOPPED: bank-preflight refused' "$W/run2.log")"

# 6. graph-use detector and the unused-treatment verdict rule.
pyt() { py -c "import sys; sys.path.insert(0, sys.argv[1]); import summarize as S; $1" "$HERE"; }
eq "detector: grepping graphify-bin.sh is not graph use" "False" "$(pyt 'print(bool(S.GRAPH_USE.search("grep -rn graphify-bin.sh scripts")))')"
eq "detector: leg-graph.sh query is graph use" "True" "$(pyt 'print(bool(S.GRAPH_USE.search("bash scripts/graphify/leg-graph.sh query x")))')"
eq "detector: graphify explain is graph use" "True" "$(pyt 'print(bool(S.GRAPH_USE.search("graphify explain foo")))')"
V='v={"weighted_tokens":(0,-1,1,0),"correct":(0,0,0,0)}'
eq "verdict: graph unused in most A runs is NEUTRAL, not DROP" "True" "$(pyt "$V; print(S.verdict(v,8,10).startswith('VERDICT: NEUTRAL (arm A never'))")"
eq "verdict: unverified runs are INCONCLUSIVE" "True" "$(pyt "$V; print(S.verdict(v,0,10,2).startswith('VERDICT: INCONCLUSIVE'))")"
eq "verdict: graph used and no benefit stays DROP" "True" "$(pyt "$V; print(S.verdict(v,0,10).startswith('VERDICT: DROP'))")"

# 7. empty matrix, malformed last ANSWER line, graph use counted only for Bash commands.
bash "$HERE/run.sh" plan --tasks no-such-task > /dev/null 2>&1
eq "unknown --tasks id is refused (exit 2)" "2" "$?"
bash "$HERE/run.sh" plan --reps 0 > /dev/null 2>&1
eq "--reps 0 is refused (exit 2)" "2" "$?"
printf 'ANSWER: ["console-judge", "leg-impl", "telegram"]\nANSWER: not-json\n' > "$W/late-bad.txt"
eq "malformed final ANSWER line is unparsed, not the earlier answer" "False False 0.0" "$(c "$W/late-bad.txt")"
T="$W/projects/-tmp-x"; mkdir -p "$T"
printf '%s\n%s\n' \
  '{"message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"file_path":"scripts/graphify/leg-graph.sh"}}]}}' \
  '{"message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"bash scripts/graphify/leg-graph.sh query x"}}]}}' > "$T/sid.jsonl"
eq "graph use counts Bash commands only, not a Read of leg-graph.sh" "2 1" "$(pyt "print(*S.transcript_calls('$W/projects', '/tmp/x', 'sid'))")"

[ "$fails" -eq 0 ] && echo "all passed" || echo "$fails failed"
exit "$fails"
