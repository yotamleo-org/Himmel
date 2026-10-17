#!/usr/bin/env bash
# test-retrieval-eval.sh -- arms, scoring, ledger row and the census of the
# retrieval eval. No real qmd or graphify call: both are stub commands, and
# grep runs over a scratch git repo.
#
# Platform guard: Linux/macOS bash; no .ps1 twin (the eval is operator-run on a
# station).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/retrieval-eval-test.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }
py() { python3 -I "$@"; }
EV="$HERE/retrieval-eval.py"
export HIMMEL_EVAL_RUNS_LEDGER="$W/ledger.jsonl"

# A scratch repo: the reason for q1 is in docs/lock.md, q2's answer in bin/run.sh.
R="$W/repo"; mkdir -p "$R/docs" "$R/bin"
printf 'The queue lock keeps one session per handover doc.\nA halt needs no token: a mild DoS, not a compromise.\n' > "$R/docs/lock.md"
printf '#!/bin/sh\nrelay_batch() { :; }\n' > "$R/bin/run.sh"
printf 'unrelated words only\n' > "$R/docs/other.md"
# The question set itself is tracked; grep must never rank it.
mkdir -p "$R/scripts/eval/retrieval-eval"
printf 'why does a halt need no token mild DoS relay_batch defined\n' > "$R/scripts/eval/retrieval-eval/questions.jsonl"
git -C "$R" init -q && git -C "$R" add -A && git -C "$R" -c user.email=t@t -c user.name=t commit -q -m init

Q="$W/q.jsonl"
cat > "$Q" <<'EOF'
{"id":"q1","kind":"why","q":"why does a halt need no token","gold":["docs/lock.md"],"reason":["mild DoS"]}
{"id":"q2","kind":"where","q":"where is relay_batch defined","gold":["bin/run.sh"],"reason":[]}
EOF

# Stubs: graphify answers q1 with a NODE line for the gold file; qmd answers with
# an MCP result naming a wrong file for q1 and the gold file for q2.
cat > "$W/graph" <<'EOF'
#!/usr/bin/env bash
case "$*" in
*halt*) printf 'NODE Halt rule [src=docs/lock.md loc=L2 community=x]\n  RATIONALE: a mild DoS, not a compromise\nNODE other [src=docs/other.md loc=L1 community=x]\n' ;;
*) printf 'NODE nothing [src=docs/other.md loc=L1 community=x]\n' ;;
esac
EOF
cat > "$W/qmd" <<'EOF'
#!/usr/bin/env bash
in="$(cat)"
case "$in" in
*halt*) printf '[{"file":"qmd://himmel/docs/other.md","snippet":"unrelated"}]\n' ;;
*sleep*) sleep 5 ;;
*orphan*) sleep 30 & echo $! > "$(dirname "$0")/child.pid"; wait ;;
*broken*) echo 'backend down' >&2; exit 3 ;;
*) printf '[{"file":"qmd://himmel/bin/run.sh","snippet":"relay_batch"}]\n' ;;
esac
EOF
chmod +x "$W/graph" "$W/qmd"
export RETRIEVAL_EVAL_GRAPH_CMD="$W/graph" RETRIEVAL_EVAL_QMD_CMD="$W/qmd"

# 1. a full run over the five arms writes scores.tsv with one row per arm.
py "$EV" run --repo "$R" --questions "$Q" --out "$W/out" --label t1 > "$W/run.txt" 2>&1
eq "run exits 0" "0" "$?"
eq "scores.tsv has a header and five arm rows" "6" "$(wc -l < "$W/out/scores.tsv" | tr -d ' ')"
s() { awk -F'\t' -v a="$1" -v c="$2" 'NR==1{for(i=1;i<=NF;i++)h[$i]=i;next} $1==a{print $h[c]}' "$W/out/scores.tsv"; }

# 2. grep finds both gold files from the question words.
eq "grep recall@5 is 1.00" "1.00" "$(s grep recall@5)"
eq "grep carries the q1 reason" "1.00" "$(s grep reason_carried)"

# 3. graphify: q1 hit with its rationale, q2 miss (RED control: a wrong file is no hit).
eq "graphify recall@5 is 0.50" "0.50" "$(s graphify recall@5)"
eq "graphify carries the q1 reason" "1.00" "$(s graphify reason_carried)"

# 4. qmd: qmd:// paths map to repo paths; q1 names a wrong file.
eq "qmd-hybrid recall@5 is 0.50" "0.50" "$(s qmd-hybrid recall@5)"
eq "qmd-lex reason not carried" "0.00" "$(s qmd-lex reason_carried)"

# 5. combined fuses the three lists: every gold file is in its top 5.
eq "combined recall@5 is 1.00" "1.00" "$(s combined recall@5)"

# 6. per-case rows: one per question x arm, with tokens and ms.
eq "results.jsonl has 10 rows" "10" "$(wc -l < "$W/out/results.jsonl" | tr -d ' ')"
eq "every row carries tokens and ms" "10" "$(py -c 'import json,sys; print(sum(1 for l in open(sys.argv[1]) if {"tokens","ms","files","hit","reason"} <= set(json.loads(l))))' "$W/out/results.jsonl")"

# 7. the eval-runs ledger row validates and is labelled.
eq "ledger row validates" "0" "$(python3 -I "$HERE/../lib/eval_runs.py" validate "$HIMMEL_EVAL_RUNS_LEDGER" > /dev/null 2>&1; echo $?)"
eq "ledger row carries the label" "t1" "$(py -c 'import json,sys; print(json.loads(open(sys.argv[1]).readlines()[-1])["meta"]["label"])' "$HIMMEL_EVAL_RUNS_LEDGER")"

# 8. a timed-out arm is a miss with timeout set, not a crash.
printf '{"id":"q3","kind":"where","q":"sleep forever","gold":["bin/run.sh"],"reason":[]}\n' > "$W/q3.jsonl"
py "$EV" run --repo "$R" --questions "$W/q3.jsonl" --out "$W/out3" --arms qmd-lex --timeout 1 > /dev/null 2>&1
eq "timeout run exits 0" "0" "$?"
eq "timed-out row is flagged" "True False" "$(py -c 'import json,sys; r=json.loads(open(sys.argv[1]).readline()); print(r["timeout"], r["hit"])' "$W/out3/results.jsonl")"

# 8b. a timeout kills the arm's whole process group, not only its direct child.
printf '{"id":"q4","kind":"where","q":"orphan child","gold":["bin/run.sh"],"reason":[]}\n' > "$W/q4.jsonl"
py "$EV" run --repo "$R" --questions "$W/q4.jsonl" --out "$W/out4" --arms qmd-lex --timeout 1 > /dev/null 2>&1
if [ -s "$W/child.pid" ] && ! kill -0 "$(cat "$W/child.pid")" 2> /dev/null; then pass "timeout leaves no grandchild behind"
else fail "timeout leaves no grandchild behind"; kill "$(cat "$W/child.pid" 2> /dev/null)" 2> /dev/null; fi

# 8c. a backend that exits non-zero is an error row, not a plain miss.
printf '{"id":"q5","kind":"where","q":"broken backend","gold":["bin/run.sh"],"reason":[]}\n' > "$W/q5.jsonl"
py "$EV" run --repo "$R" --questions "$W/q5.jsonl" --out "$W/out5" --arms qmd-lex > /dev/null 2>&1
eq "failed backend row carries error" "True" "$(py -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline()).get("error"))' "$W/out5/results.jsonl")"

# 8d. grep never returns the tracked question set.
eq "grep skips the question set" "0" "$(grep -c 'retrieval-eval/questions' "$W/out/results.jsonl")"

# 9. usage errors.
py "$EV" run --repo "$R" --questions "$Q" --out "$W/o9" --arms nosuch > /dev/null 2>&1
eq "unknown arm exits 64" "64" "$?"
py "$EV" run --repo "$R" --questions "$W/missing.jsonl" --out "$W/o9" > /dev/null 2>&1
eq "missing question file exits 64" "64" "$?"

# 10. the shipped question set is well-formed: 50 rows, unique ids, gold files exist.
REPO_ROOT="$(git -C "$HERE" rev-parse --show-toplevel)"
n="$(py "$EV" check --repo "$REPO_ROOT" --questions "$HERE/questions.jsonl")"
eq "shipped question set checks clean" "50 rc=0" "$n rc=$?"

# 11. census: a qmd call that errors, then a grep, is a fallback; graphify via leg-graph counts.
P="$W/projects/-home-x-himmel"; mkdir -p "$P"
cat > "$P/s1.jsonl" <<'EOF'
{"type":"custom-title","customTitle":"HIMMEL-1-N1-x"}
{"type":"assistant","timestamp":"2026-10-17T10:00:00Z","message":{"content":[{"type":"tool_use","id":"a","name":"mcp__qmd__query","input":{"searches":[{"type":"lex","query":"x"}]}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"a","is_error":true,"content":"The operation timed out."}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"b","name":"Bash","input":{"command":"git grep -n foo"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"b","content":"docs/a.md:1:foo"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"c","name":"Bash","input":{"command":"bash scripts/graphify/leg-graph.sh query \"how\""}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"c","content":"NODE a [src=docs/a.md loc=L1]"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"d","name":"Read","input":{"file_path":"/r/docs/a.md"}}]}}
EOF
py "$EV" census --projects "$W/projects" --days 0 --out "$W/census.json" > "$W/census.txt" 2>&1
eq "census exits 0" "0" "$?"
cz() { py -c 'import json,sys; d=json.load(open(sys.argv[1]))["roles"]["leg"]; print(d[sys.argv[2]])' "$W/census.json" "$1"; }
eq "census: one qmd call" "1" "$(cz qmd_calls)"
eq "census: one qmd failure" "1" "$(cz qmd_failed)"
eq "census: grep fallback after the failed qmd call" "1" "$(cz fallback_after_miss)"
eq "census: one graphify call" "1" "$(cz graphify_calls)"
eq "census: graphify answer used (its file was read next)" "1" "$(cz graphify_used)"

# 12. the census window applies to each call's timestamp, not the file's mtime.
P2="$W/projects2/-home-x-himmel"; mkdir -p "$P2"
cat > "$P2/s2.jsonl" <<'EOF'
{"type":"custom-title","customTitle":"HIMMEL-2-N2-y"}
{"type":"assistant","timestamp":"2020-01-01T10:00:00Z","message":{"content":[{"type":"tool_use","id":"a","name":"mcp__qmd__query","input":{}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"a","content":"[]"}]}}
EOF
py "$EV" census --projects "$W/projects2" --days 7 --out "$W/census2.json" > /dev/null 2>&1
eq "census: a call older than the window is not counted" "0" "$(py -c 'import json,sys; print(json.load(open(sys.argv[1]))["roles"]["leg"]["qmd_calls"])' "$W/census2.json")"

[ "$fails" -eq 0 ] && echo "all passed" || echo "$fails failed"
exit "$fails"
