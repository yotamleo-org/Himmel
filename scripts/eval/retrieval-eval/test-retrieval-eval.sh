#!/usr/bin/env bash
# test-retrieval-eval.sh -- arms, scoring, ledger row and the census of the
# retrieval eval. No real qmd or graphify call: both are stub commands, and
# grep runs over a scratch git repo.
#
# Platform guard: Linux/macOS bash; the eval is operator-run on a station.
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

# A stub rtk on PATH: `rtk rewrite "<cmd>"` answers `rtk <cmd>` the way the hook does for grep, and
# `rtk grep ...` runs grep. Every call is logged to $RTK_LOG so a row can assert the argv.
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

# A one-second subprocess floor must not extend a sub-second arm budget.
if py - "$EV" "$W" <<'PY'
import json, os, pathlib, shutil, subprocess, sys

ev, work = sys.argv[1], pathlib.Path(sys.argv[2])
slow = work / "slow"
slow.mkdir()
real_git = shutil.which("git")
stub = slow / "git"
stub.write_text('''#!/usr/bin/env bash
case " $* " in
*" grep "*)
    printf '%s\\0' "$@" >> "$BUDGET_CALLS"
    printf '\\0' >> "$BUDGET_CALLS"
    if [ "$BUDGET_PHASE" = snippet ] && [[ " $* " == *" -c "* ]]; then
        printf 'bin/run.sh:1\\n'
        exit 0
    fi
    exec sleep 5 ;;
esac
exec "$REAL_GIT" "$@"
''')
stub.chmod(0o755)
questions = work / "budget.jsonl"
questions.write_text(json.dumps(dict(id="budget", q="relay_batch", gold=["bin/run.sh"], reason=[])) + "\n")
failed = False
for phase, arm in (("count", "grep"), ("ident", "ident-grep"), ("snippet", "grep")):
    out = work / ("budget-" + phase)
    calls_log = work / (phase + ".calls")
    env = dict(os.environ, PATH=str(slow) + os.pathsep + os.environ["PATH"],
               REAL_GIT=real_git, BUDGET_PHASE=phase, BUDGET_CALLS=str(calls_log),
               HIMMEL_EVAL_RUNS_LEDGER=str(work / "budget-ledger.jsonl"))
    result = subprocess.run([sys.executable, "-I", ev, "run", "--repo", str(work),
                             "--questions", str(questions), "--out", str(out),
                             "--arms", arm, "--timeout", "0.3"], env=env,
                            capture_output=True, text=True, timeout=10)
    if result.returncode:
        print("FAIL - %s sub-second timeout: rc=%s %s" % (phase, result.returncode, result.stderr.strip()))
        failed = True
        continue
    calls = [c.split("\0") for c in calls_log.read_text().split("\0\0") if c]
    stages = ["count" if "-c" in c else "ident" if "-w" in c else "snippet" for c in calls]
    expected = ["count", "snippet"] if phase == "snippet" else [phase]
    if stages != expected:
        print("FAIL - %s expected stages %s, got %s: %s" % (phase, expected, stages, calls))
        failed = True
        continue
    row = json.loads((out / "results.jsonl").read_text().splitlines()[0])
    ok = row["timeout"] and not row["error"] and row["ms"] < 600
    print("%s - %s honours 0.3 s budget: timeout=%s error=%s ms=%s" %
          ("ok" if ok else "FAIL", phase, row["timeout"], row["error"], row["ms"]))
    failed = failed or not ok
sys.exit(int(failed))
PY
then pass "grep count, identifier and snippet subprocesses honour a sub-second budget"
else fail "grep count, identifier and snippet subprocesses honour a sub-second budget"; fi
if [ "${1:-}" = --budget-only ]; then exit "$fails"; fi

# A scratch repo: the reason for q1 is in docs/lock.md, q2's answer in bin/run.sh.
R="$W/repo"; mkdir -p "$R/docs" "$R/bin"
printf 'The queue lock keeps one session per handover doc.\nA halt needs no token: a mild DoS, not a compromise.\n' > "$R/docs/lock.md"
printf '#!/bin/sh\nrelay_batch() { :; }\n' > "$R/bin/run.sh"
printf 'unrelated words only\n' > "$R/docs/other.md"
# Vendored noise: a plugin bundle and a minified file both name relay_batch and the lock words.
mkdir -p "$R/templates/vault/.obsidian/plugins/p"
printf 'relay_batch queue lock halt token relay_batch\n' > "$R/templates/vault/.obsidian/plugins/p/main.js"
printf 'relay_batch queue lock halt token relay_batch\n' > "$R/docs/vendor.min.js"
# A Python variable definition must outrank a file that merely uses the name more often.
mkdir -p "$R/lib"
printf 'retry_limit: int = 3\n' > "$R/lib/conf.py"
printf 'retry_limit retry_limit retry_limit\n' > "$R/docs/a-use.md"
# The question set itself is tracked; grep must never rank it.
mkdir -p "$R/scripts/eval/retrieval-eval"
printf 'why does a halt need no token mild DoS relay_batch defined\n' > "$R/scripts/eval/retrieval-eval/questions.jsonl"
git -C "$R" init -q && git -C "$R" add -A && git -C "$R" -c user.email=t@t -c user.name=t commit -q -m init
mkdir -p "$R/graphify-out"
printf '{"built_at_commit": "abc123def"}\n' > "$R/graphify-out/graph.json"

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
*halt*) printf 'NODE Halt rule [src=docs/lock.md loc=L2 community=x] WHY a mild DoS, not a compromise\nNODE other [src=docs/other.md loc=L1 community=x]\n' ;;
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
*unreadable*) echo 'not JSON' ;;
*casefold*) printf '[{"file":"qmd://himmel/claude.md","snippet":"rules"}]\n' ;;
*) printf '[{"file":"qmd://himmel/bin/run.sh","snippet":"relay_batch"}]\n' ;;
esac
EOF
chmod +x "$W/graph" "$W/qmd"
export RETRIEVAL_EVAL_GRAPH_CMD="$W/graph" RETRIEVAL_EVAL_QMD_CMD="$W/qmd"

# 1. a full run over the nine arms writes scores.tsv with one row per arm.
py "$EV" run --repo "$R" --questions "$Q" --out "$W/out" --label t1 > "$W/run.txt" 2>&1
eq "run exits 0" "0" "$?"
eq "scores.tsv has a header and nine arm rows" "10" "$(wc -l < "$W/out/scores.tsv" | tr -d ' ')"
eq "scores.tsv lists the path and ident-grep arms" "ident-grep path" "$(awk -F'\t' 'NR>1 && ($1=="path" || $1=="ident-grep"){print $1}' "$W/out/scores.tsv" | sort | tr '\n' ' ' | sed 's/ $//')"
s() { awk -F'\t' -v a="$1" -v c="$2" 'NR==1{for(i=1;i<=NF;i++)h[$i]=i;next} $1==a{print $h[c]}' "$W/out/scores.tsv"; }

# 2. grep finds both gold files from the question words.
eq "grep hit@5 is 1.00" "1.00" "$(s grep hit@5)"
eq "grep carries the q1 reason" "1.00" "$(s grep reason_carried)"

# 2b. path ranks tracked file names by the question words; ident-grep ranks the defining file of an identifier first.
printf '{"id":"p1","kind":"where","q":"where does the lock doc live","gold":["docs/lock.md"],"reason":[]}\n{"id":"p2","kind":"where","q":"where is relay_batch defined","gold":["bin/run.sh"],"reason":[]}\n' > "$W/qp.jsonl"
HIMMEL_EVAL_RUNS_LEDGER="$W/ledger-2b.jsonl" py "$EV" run --repo "$R" --questions "$W/qp.jsonl" --out "$W/outp" --arms path,ident-grep > /dev/null 2>&1
hit() { py -c 'import json,sys
for l in open(sys.argv[1]):
    r = json.loads(l)
    if r["id"] == sys.argv[2] and r["arm"] == sys.argv[3]:
        print(int(r["hit"]), r["files"][0] if r["files"] else "-")' "$W/outp/results.jsonl" "$1" "$2"; }
eq "path hits the file whose name holds the question words" "1 docs/lock.md" "$(hit p1 path)"
eq "ident-grep ranks the defining file first and skips vendored bundles" "1 bin/run.sh" "$(hit p2 ident-grep)"
eq "ident-grep finds nothing in a question with no identifier" "0 -" "$(hit p1 ident-grep)"
printf '{"id":"p3","kind":"where","q":"where is retry_limit set","gold":["lib/conf.py"],"reason":[]}\n' > "$W/qp3.jsonl"
HIMMEL_EVAL_RUNS_LEDGER="$W/ledger-2b.jsonl" py "$EV" run --repo "$R" --questions "$W/qp3.jsonl" --out "$W/outp3" --arms ident-grep > /dev/null 2>&1
eq "ident-grep ranks a Python variable definition first" "1 lib/conf.py" "$(py -c 'import json,sys; r=json.loads(open(sys.argv[1]).readline()); print(int(r["hit"]), r["files"][0])' "$W/outp3/results.jsonl")"
HIMMEL_EVAL_RUNS_LEDGER="$W/ledger-2b.jsonl" py "$EV" run --repo "$R" --questions "$W/qp3.jsonl" --out "$W/outp4" --arms ident-grep --timeout 0 > /dev/null 2>&1
eq "ident-grep with an exhausted budget is a timeout row, not a late search" "True" "$(py -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["timeout"])' "$W/outp4/results.jsonl")"

# 3. graphify: q1 hit with its rationale, q2 miss (RED control: a wrong file is no hit).
eq "graphify hit@5 is 0.50" "0.50" "$(s graphify hit@5)"
eq "graphify carries the q1 reason" "1.00" "$(s graphify reason_carried)"

# 4. qmd: qmd:// paths map to repo paths; q1 names a wrong file.
eq "qmd-hybrid hit@5 is 0.50" "0.50" "$(s qmd-hybrid hit@5)"
eq "qmd-lex reason not carried" "0.00" "$(s qmd-lex reason_carried)"

# 5. combined fuses the three lists: every gold file is in its top 5.
eq "combined hit@5 is 1.00" "1.00" "$(s combined hit@5)"

# 5a. rank-aware metrics: hit@5 forgives noise, so precision@5, MRR, gold-share and tokens-per-hit are scored too.
# qmd-hybrid: q1 misses (other.md), q2 hits at rank 1; graphify: q1 hits at rank 1 beside one wrong file, q2 misses.
hdr() { head -1 "$W/out/scores.tsv" | tr '\t' '\n' | grep -cx "$1"; }
eq "scores.tsv names hit@5" "1" "$(hdr 'hit@5')"
eq "scores.tsv no longer names recall@5" "0" "$(hdr 'recall@5')"
eq "qmd-hybrid precision@5 is 0.10" "0.10" "$(s qmd-hybrid precision@5)"
eq "qmd-hybrid mrr is 0.50" "0.50" "$(s qmd-hybrid mrr)"
eq "qmd-hybrid gold_share is 0.50" "0.50" "$(s qmd-hybrid gold_share)"
eq "qmd-hybrid tokens_per_hit is its tokens over its one hit" "18.0" "$(s qmd-hybrid tokens_per_hit)"
eq "graphify precision@5 is 0.10" "0.10" "$(s graphify precision@5)"
eq "graphify gold_share pools returned files: 1 of 3" "0.33" "$(s graphify gold_share)"
eq "an arm with no hit has no tokens_per_hit" "-" "$(s path tokens_per_hit)"
eq "ledger row carries the four metrics" "0.10 0.50 0.50 18" "$(py -c 'import json,sys
m = json.loads(open(sys.argv[1]).readlines()[0])["metrics"]
print("%.2f %.2f %.2f %d" % (m["qmd-hybrid.precision@5"], m["qmd-hybrid.mrr"], m["qmd-hybrid.gold_share"], m["qmd-hybrid.tokens_per_hit"]))' "$HIMMEL_EVAL_RUNS_LEDGER")"
eq "precision counts a grade-1 file; mrr and gold_share count only gold" "0.2 0.0 0.5" "$(py -c 'import importlib.util,sys
s = importlib.util.spec_from_file_location("ev", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
q = {"gold": ["bin/run.sh"], "gold1": ["docs/lock.md"]}
print(m.precision(["Docs/Lock.md"], q, 5), m.reciprocal_rank(["Docs/Lock.md"], q, 5), m.gold_share(["docs/lock.md", "bin/run.sh"], q, 5))' "$EV")"
eq "a graded path is counted once however many returned files match it" "0.2 0.5" "$(py -c 'import importlib.util,sys
s = importlib.util.spec_from_file_location("ev", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
q = {"gold": ["docs/lock.md"], "gold1": []}
f = ["docs/lock.md", "archive/docs/lock.md"]
print(m.precision(f, q, 5), m.gold_share(f, q, 5))' "$EV")"
printf '{"id":"f1","kind":"where","q":"where is relay_batch defined","gold":["bin/run.sh"],"reason":[]}\n{"id":"f2","kind":"where","q":"where is relay_batch set","gold":["bin/run.sh"],"reason":[]}\n{"id":"f3","kind":"why","q":"why does a halt need no token","gold":["docs/lock.md"],"reason":[]}\n' > "$W/qf.jsonl"
HIMMEL_EVAL_RUNS_LEDGER="$W/ledger-5a.jsonl" py "$EV" run --repo "$R" --questions "$W/qf.jsonl" --out "$W/outf" --arms qmd-hybrid > /dev/null 2>&1
eq "tokens_per_hit keeps its fraction" "13.5" "$(awk -F'\t' 'NR==1{for(i=1;i<=NF;i++)h[$i]=i;next} {print $h["tokens_per_hit"]}' "$W/outf/scores.tsv")"
eq "mrr is the reciprocal of the first gold rank" "0.33" "$(py -c 'import importlib.util,sys
s = importlib.util.spec_from_file_location("ev", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
print("%.2f" % m.reciprocal_rank(["a.md", "b.md", "bin/run.sh"], {"gold": ["bin/run.sh"]}, 5))' "$EV")"

# 5b. the live qmd server names a file himmel/docs/lock.md (no qmd:// scheme); grep names docs/lock.md.
# The combined top 5 holds that file once, not twice.
cat > "$W/qmd-bare" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
printf '[{"file":"himmel/docs/lock.md","snippet":"queue lock"}]\n'
EOF
chmod +x "$W/qmd-bare"
printf '{"id":"q9","kind":"why","q":"queue lock one session per handover doc","gold":["docs/lock.md"],"reason":[]}\n' > "$W/q9.jsonl"
HIMMEL_EVAL_RUNS_LEDGER="$W/ledger-5b.jsonl" RETRIEVAL_EVAL_QMD_CMD="$W/qmd-bare" py "$EV" run --repo "$R" --questions "$W/q9.jsonl" --out "$W/out9" --arms combined > /dev/null 2>&1
eq "combined holds a file named by qmd and grep once" "1" "$(py -c 'import json,sys; r=[json.loads(l) for l in open(sys.argv[1])][0]; print(sum(1 for f in r["files"] if f.lower().endswith("docs/lock.md")))' "$W/out9/results.jsonl")"
eq "fuse merges paths that differ only in case" "1" "$(py -c 'import importlib.util,sys
s = importlib.util.spec_from_file_location("ev", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(len(m.fuse([["Docs/X.md"], ["docs/x.md"]], 5)))' "$EV")"

# 6. per-case rows: one per question x arm, with tokens and ms.
eq "results.jsonl has 18 rows" "18" "$(wc -l < "$W/out/results.jsonl" | tr -d ' ')"
eq "every row carries tokens and ms" "18" "$(py -c 'import json,sys; print(sum(1 for l in open(sys.argv[1]) if {"tokens","ms","files","hit","reason"} <= set(json.loads(l))))' "$W/out/results.jsonl")"

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
eq "failed backend keeps its error detail and the stable trace schema" "True" "$(py -c 'import json,sys
r = json.loads(open(sys.argv[1]).readline())
print(r.get("qmd_error") == "qmd failed (rc 3)" and isinstance(r.get("files_top20"), list)
      and r["files_top20"][:5] == r["files"] and r.get("skipped") is False)' "$W/out5/results.jsonl")"
eq "timeout evidence says timed out" "True" "$(py -c 'import json,sys
print("timed out" in json.loads(open(sys.argv[1]).readline()).get("qmd_error", ""))' "$W/out3/results.jsonl")"
HIMMEL_EVAL_RUNS_LEDGER="$W/ledger-error.jsonl" py "$EV" run --repo "$R" --questions "$W/q5.jsonl" --out "$W/out-error" --arms combined > /dev/null 2>&1
eq "combined carries its qmd failure detail" "qmd failed (rc 3)" "$(py -c 'import json,sys
print(json.loads(open(sys.argv[1]).readline()).get("qmd_error", ""))' "$W/out-error/results.jsonl")"

printf '{"id":"bad-json","q":"unreadable output","gold":["bin/run.sh"],"reason":[]}\n' > "$W/unreadable.jsonl"
HIMMEL_EVAL_RUNS_LEDGER="$W/ledger-unreadable.jsonl" py "$EV" run --repo "$R" --questions "$W/unreadable.jsonl" --out "$W/out-unreadable" --arms qmd-lex > /dev/null 2>&1
eq "unreadable qmd output keeps an error detail" "True" "$(py -c 'import json,sys
r = json.loads(open(sys.argv[1]).readline())
print(r["error"] and not r["timeout"] and r.get("qmd_error") == "qmd returned unreadable output")' "$W/out-unreadable/results.jsonl")"
eq "server errors keep bounded detail and their timeout classification" "True" "$(py -c 'import importlib.util,os,sys
s = importlib.util.spec_from_file_location("ev", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
os.environ.pop("RETRIEVAL_EVAL_QMD_CMD", None)
rows = []
for error in (RuntimeError("backend unavailable " * 10), TimeoutError("timed out")):
    def server(*args):
        raise error
    m.qmd_server = server
    rows.append(m.arm_qmd("fixture", True, 1, 5, "himmel"))
print(rows[0][2:] == (False, True, "backend unavailable " * 5) and rows[1][2:] == (True, False, "timed out"))' "$EV")"

cat > "$W/qmd-rec" <<'EOF'
#!/usr/bin/env bash
cat > "$(dirname "$0")/sent.json"
echo '[]'
EOF
chmod +x "$W/qmd-rec"
RETRIEVAL_EVAL_QMD_CMD="$W/qmd-rec" py -c 'import importlib.util,sys
s = importlib.util.spec_from_file_location("ev", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
m.arm_qmd("how does the waiter wake the chief -p --bg", True, 5, 5, "himmel")' "$EV"
sent() { py -c 'import json,sys
a = json.load(open(sys.argv[1]))
print(a["intent"] if sys.argv[2] == "intent" else [s["query"] for s in a["searches"] if s["type"] == sys.argv[2]][0])' "$W/sent.json" "$1"; }
eq "lex leg drops filler words and quotes the dash words, which qmd would read as a NOT" 'waiter wake chief "-p" "--bg"' "$(sent lex)"
eq "vec leg drops the single-dash word qmd rejects" "how does the waiter wake the chief --bg" "$(sent vec)"
eq "intent keeps the whole question" "how does the waiter wake the chief -p --bg" "$(sent intent)"

# 8d. grep never returns the tracked question set.
eq "grep skips the question set" "0" "$(grep -c 'retrieval-eval/questions' "$W/out/results.jsonl")"
eq "no arm returns a plugin bundle or a minified file" "0" "$(grep -cE '\.obsidian/plugins/|\.min\.js' "$W/out/results.jsonl")"

# 8e. an MCP error reply (JSON-RPC error or isError) raises, so the arm scores an error.
mcp() { py -c 'import importlib.util,json,sys
s = importlib.util.spec_from_file_location("ev", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
try:
    m.mcp_rows(json.loads(sys.argv[2])); print("ok")
except RuntimeError:
    print("raised")' "$EV" "$1"; }
eq "MCP isError result raises" "raised" "$(mcp '{"result":{"isError":true,"content":[{"type":"text","text":"boom"}]}}')"
eq "MCP JSON-RPC error raises" "raised" "$(mcp '{"error":{"code":-32603,"message":"boom"}}')"
eq "MCP results parse" "ok" "$(mcp '{"result":{"structuredContent":{"results":[]}}}')"

# 8f. the hit column names the --k cutoff.
py "$EV" run --repo "$R" --questions "$Q" --out "$W/out6" --arms grep --k 3 > /dev/null 2>&1
eq "hit column follows --k" "hit@3" "$(head -1 "$W/out6/scores.tsv" | cut -f3)"

# 8g. qmd lowercases paths: qmd://himmel/claude.md is a hit for gold CLAUDE.md; the row keeps the question's src.
printf '{"id":"q7","kind":"where","src":"selfq","q":"casefold rules","gold":["CLAUDE.md"],"reason":[]}\n' > "$W/q7.jsonl"
py "$EV" run --repo "$R" --questions "$W/q7.jsonl" --out "$W/out7" --arms qmd-lex > /dev/null 2>&1
eq "lowercased qmd path hits a mixed-case gold" "True selfq" "$(py -c 'import json,sys; r=json.loads(open(sys.argv[1]).readline()); print(r["hit"], r.get("src"))' "$W/out7/results.jsonl")"

# 8h. the qmd token helper runs once per run, not once per query.
eq "qmd token fetched once" "1" "$(py -c 'import importlib.util,sys
s = importlib.util.spec_from_file_location("ev", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
n = []
m.subprocess.run = lambda *a, **k: n.append(1) or type("R", (), {"stdout": "t"})()
m.qmd_token(); m.qmd_token(); print(len(n))' "$EV")"

# 8i. qmd-hybrid-norerank: --arms accepts it, it sends lex+vec with rerank false; qmd-hybrid sends rerank true explicitly.
cat > "$W/qmd-log" <<'EOF'
#!/usr/bin/env bash
cat >> "$(dirname "$0")/qmd-in.log"; echo >> "$(dirname "$0")/qmd-in.log"
printf '[{"file":"qmd://himmel/bin/run.sh","snippet":"relay_batch"}]\n'
EOF
chmod +x "$W/qmd-log"
printf '{"id":"q8","kind":"where","q":"where is relay_batch defined","gold":["bin/run.sh"],"reason":[]}\n' > "$W/q8.jsonl"
RETRIEVAL_EVAL_QMD_CMD="$W/qmd-log" py "$EV" run --repo "$R" --questions "$W/q8.jsonl" --out "$W/out8" --arms qmd-hybrid,qmd-hybrid-norerank > /dev/null 2>&1
eq "norerank arm is accepted by --arms" "0" "$?"
eq "norerank arm scores a hit" "1.00" "$(awk -F'\t' '$1=="qmd-hybrid-norerank"{print $3}' "$W/out8/scores.tsv")"
eq "norerank sends lex+vec with rerank false" "lex,vec False" "$(py -c 'import json,sys; a=json.loads(open(sys.argv[1]).readlines()[2]); print(",".join(s["type"] for s in a["searches"]), a.get("rerank", "absent"))' "$W/qmd-in.log")"
eq "qmd-hybrid sends lex+vec with rerank true" "lex,vec True" "$(py -c 'import json,sys; a=json.loads(open(sys.argv[1]).readlines()[0]); print(",".join(s["type"] for s in a["searches"]), a.get("rerank", "absent"))' "$W/qmd-in.log")"
eq "default arms are the nine" "10" "$(wc -l < "$W/out/scores.tsv" | tr -d ' ')"

# 9. usage errors.
py "$EV" run --repo "$R" --questions "$Q" --out "$W/o9" --arms nosuch > /dev/null 2>&1
eq "unknown arm exits 64" "64" "$?"
py "$EV" run --repo "$R" --questions "$W/missing.jsonl" --out "$W/o9" > /dev/null 2>&1
eq "missing question file exits 64" "64" "$?"

# 9b. every ledger row carries an in-sample and a held-out slice; a row with no split is in-sample.
cat > "$W/qh.jsonl" <<'EOF'
{"id":"s1","kind":"why","q":"why does a halt need no token","gold":["docs/lock.md"],"reason":[]}
{"id":"h1","kind":"where","split":"heldout","q":"where is relay_batch defined","gold":["bin/run.sh"],"reason":[]}
{"id":"h2","kind":"how","split":"heldout","q":"queue lock one session per handover doc","gold":["bin/run.sh"],"gold1":["docs/lock.md"],"reason":[]}
EOF
HIMMEL_EVAL_RUNS_LEDGER="$W/ledger-9b.jsonl" py "$EV" run --repo "$R" --questions "$W/qh.jsonl" --out "$W/outh" --arms grep --label slices > "$W/outh.txt" 2>&1
eq "slice run exits 0" "0" "$?"
lm() { py -c 'import json,sys
m = json.loads(open(sys.argv[1]).readlines()[-1])["metrics"]
v = m.get(sys.argv[2], "absent")
print("%.2f" % v if isinstance(v, float) else v)' "$1" "$2"; }
eq "ledger row: in-sample n" "1" "$(lm "$W/ledger-9b.jsonl" grep.insample.n)"
eq "ledger row: held-out n" "2" "$(lm "$W/ledger-9b.jsonl" grep.heldout.n)"
eq "ledger row: in-sample hit@5" "1.00" "$(lm "$W/ledger-9b.jsonl" 'grep.insample.hit@5')"
eq "ledger row: held-out hit@5" "0.50" "$(lm "$W/ledger-9b.jsonl" 'grep.heldout.hit@5')"
eq "ledger row: held-out hit_any@5 counts a grade-1 file" "1.00" "$(lm "$W/ledger-9b.jsonl" 'grep.heldout.hit_any@5')"
eq "ledger row: held-out ndcg@5 is graded" "0.69" "$(lm "$W/ledger-9b.jsonl" 'grep.heldout.ndcg@5')"
eq "ledger row validates" "0" "$(python3 -I "$HERE/../lib/eval_runs.py" validate "$W/ledger-9b.jsonl" > /dev/null 2>&1; echo $?)"
eq "ledger row names the frozen held-out set" "2" "$(py -c 'import json,sys; print(json.loads(open(sys.argv[1]).readlines()[-1])["meta"]["n_heldout"])' "$W/ledger-9b.jsonl")"
eq "scores-by-slice.tsv has one row per arm, split, stratum and split x stratum" "9" "$(wc -l < "$W/outh/scores-by-slice.tsv" | tr -d ' ')"
eq "the run prints both slices" "2" "$(grep -cE '^grep	(insample|heldout)	' "$W/outh.txt")"
eq "results.jsonl rows carry their split" "insample heldout heldout" "$(py -c 'import json,sys; print(" ".join(json.loads(l)["split"] for l in open(sys.argv[1])))' "$W/outh/results.jsonl")"
# A run over a set with no held-out question still carries the held-out keys: n 0, scores null.
HIMMEL_EVAL_RUNS_LEDGER="$W/ledger-9c.jsonl" py "$EV" run --repo "$R" --questions "$Q" --out "$W/outq" --arms grep > /dev/null 2>&1
eq "no held-out question: held-out n is 0" "0" "$(lm "$W/ledger-9c.jsonl" grep.heldout.n)"
eq "no held-out question: held-out hit is null" "None" "$(lm "$W/ledger-9c.jsonl" 'grep.heldout.hit@5')"

cat > "$W/qs.jsonl" <<'EOF'
{"id":"c1","kind":"where","q":"where is relay_batch defined","gold":["bin/run.sh"],"reason":[]}
{"id":"c2","kind":"where","q":"where does relay_batch run","gold":["bin/run.sh"],"reason":[]}
{"id":"d1","kind":"why","q":"why does a halt need no token","gold":["docs/lock.md"],"reason":[]}
{"id":"hc1","kind":"where","split":"heldout","q":"which script defines relay_batch","gold":["bin/run.sh"],"reason":[]}
{"id":"hd1","kind":"how","split":"heldout","q":"queue lock one session per handover doc","gold":["docs/lock.md"],"reason":[]}
{"id":"hd2","kind":"why","split":"heldout","q":"why is a halt a mild DoS","gold":["docs/lock.md","bin/run.sh"],"reason":[]}
EOF
cat > "$W/qmd-md" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
printf '[{"file":"qmd://himmel/docs/lock.md","snippet":"queue lock"}]\n'
EOF
chmod +x "$W/qmd-md"
RETRIEVAL_EVAL_QMD_CMD="$W/qmd-md" HIMMEL_EVAL_RUNS_LEDGER="$W/ledger-9d.jsonl" py "$EV" run --repo "$R" --questions "$W/qs.jsonl" --out "$W/outs" --arms qmd-hybrid --label strata > "$W/outs.txt" 2>&1
eq "stratum run exits 0" "0" "$?"
eq "ledger row: code-only n and hit beside the pooled number" "3 0.00" "$(lm "$W/ledger-9d.jsonl" qmd-hybrid.code.n) $(lm "$W/ledger-9d.jsonl" 'qmd-hybrid.code.hit@5')"
eq "ledger row: doc n and hit" "3 1.00" "$(lm "$W/ledger-9d.jsonl" qmd-hybrid.doc.n) $(lm "$W/ledger-9d.jsonl" 'qmd-hybrid.doc.hit@5')"
eq "ledger row: pooled hit is unchanged" "0.50" "$(lm "$W/ledger-9d.jsonl" 'qmd-hybrid.hit@5')"
eq "ledger row: split x stratum n" "2 1 1 2" "$(lm "$W/ledger-9d.jsonl" qmd-hybrid.insample.code.n) $(lm "$W/ledger-9d.jsonl" qmd-hybrid.insample.doc.n) $(lm "$W/ledger-9d.jsonl" qmd-hybrid.heldout.code.n) $(lm "$W/ledger-9d.jsonl" qmd-hybrid.heldout.doc.n)"
eq "ledger row: split x stratum hit" "0.00 1.00 0.00 1.00" "$(lm "$W/ledger-9d.jsonl" 'qmd-hybrid.insample.code.hit@5') $(lm "$W/ledger-9d.jsonl" 'qmd-hybrid.insample.doc.hit@5') $(lm "$W/ledger-9d.jsonl" 'qmd-hybrid.heldout.code.hit@5') $(lm "$W/ledger-9d.jsonl" 'qmd-hybrid.heldout.doc.hit@5')"
eq "ledger row: the split rows keep their numbers" "3 3 0.33 0.67" "$(lm "$W/ledger-9d.jsonl" qmd-hybrid.insample.n) $(lm "$W/ledger-9d.jsonl" qmd-hybrid.heldout.n) $(lm "$W/ledger-9d.jsonl" 'qmd-hybrid.insample.hit@5') $(lm "$W/ledger-9d.jsonl" 'qmd-hybrid.heldout.hit@5')"
eq "ledger row validates with strata" "0" "$(python3 -I "$HERE/../lib/eval_runs.py" validate "$W/ledger-9d.jsonl" > /dev/null 2>&1; echo $?)"
eq "scores-by-slice.tsv: one row per arm, split, stratum and split x stratum" "qmd-hybrid insample 3|qmd-hybrid heldout 3|qmd-hybrid code 3|qmd-hybrid doc 3|qmd-hybrid insample.code 2|qmd-hybrid insample.doc 1|qmd-hybrid heldout.code 1|qmd-hybrid heldout.doc 2" "$(awk -F'\t' 'NR>1{print $1, $2, $3}' "$W/outs/scores-by-slice.tsv" | tr '\n' '|' | sed 's/|$//')"
eq "scores-by-slice.tsv: the code row shows hit 0.00 over its real n" "3 0.00" "$(awk -F'\t' '$2=="code"{print $3, $4}' "$W/outs/scores-by-slice.tsv")"
eq "the run prints the stratum rows" "2" "$(grep -cE '^qmd-hybrid	(code|doc)	' "$W/outs.txt")"
eq "results.jsonl rows carry their stratum" "code code doc code doc doc" "$(py -c 'import json,sys; print(" ".join(json.loads(l)["stratum"] for l in open(sys.argv[1])))' "$W/outs/results.jsonl")"
eq "a split x stratum with no question: n 0, hit null" "0 None 0 None" "$(lm "$W/ledger-9c.jsonl" grep.heldout.code.n) $(lm "$W/ledger-9c.jsonl" 'grep.heldout.code.hit@5') $(lm "$W/ledger-9c.jsonl" grep.heldout.doc.n) $(lm "$W/ledger-9c.jsonl" 'grep.heldout.doc.hit@5')"
# check refuses a bad split, a missing grade-1 file and a file graded twice.
chk() { printf '%s\n' "$1" > "$W/qc.jsonl"; py "$EV" check --repo "$R" --questions "$W/qc.jsonl" > /dev/null 2>&1; echo $?; }
eq "check refuses an unknown split" "1" "$(chk '{"id":"c1","split":"dev","q":"x","gold":["docs/lock.md"],"reason":[]}')"
eq "check refuses a missing grade-1 file" "1" "$(chk '{"id":"c2","q":"x","gold":["docs/lock.md"],"gold1":["docs/nope.md"],"reason":[]}')"
eq "check refuses a file graded 2 and 1" "1" "$(chk '{"id":"c3","q":"x","gold":["docs/lock.md"],"gold1":["docs/lock.md"],"reason":[]}')"
eq "check accepts a held-out row with a grade-1 file" "0" "$(chk '{"id":"c4","split":"heldout","q":"x","gold":["docs/lock.md"],"gold1":["docs/other.md"],"reason":[]}')"
# run does not call check, so a path graded 2 and 1 (any case) must still count once in ndcg.
eq "ndcg counts a path graded 2 and 1 once" "1.0" "$(py -c 'import importlib.util,sys
s = importlib.util.spec_from_file_location("ev", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(round(m.ndcg(["docs/lock.md"], {"gold": ["docs/lock.md"], "gold1": ["Docs/Lock.md"]}, 5), 2))' "$EV")"

# 10. the shipped question set is well-formed: 75 rows, unique ids, gold and gold1 files exist.
REPO_ROOT="$(git -C "$HERE" rev-parse --show-toplevel)"
n="$(py "$EV" check --repo "$REPO_ROOT" --questions "$HERE/questions.jsonl")"
eq "shipped question set checks clean" "75 rc=0" "$n rc=$?"

# 10b. the frozen held-out slice: at least 20 questions, at least half with no path or identifier word,
# none quoted verbatim outside this directory (a quoted question could be tuned against).
eq "shipped held-out slice: at least 20, half with no path or identifier word, none quoted elsewhere" "ok" "$(py -c 'import importlib.util,json,re,subprocess,sys
s = importlib.util.spec_from_file_location("ev", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
rows = [json.loads(l) for l in open(sys.argv[2]) if l.strip()]
held = [r for r in rows if r.get("split") == "heldout"]
plain = [r for r in held if not m.idents(r["q"]) and not re.search(r"[/.]", r["q"])]
def grep_rc(text):
    return subprocess.run(["git", "-C", sys.argv[3], "grep", "-q", "-F", "-e", text, "--", ".", ":(exclude)scripts/eval/retrieval-eval/"]).returncode
rcs = {r["id"]: grep_rc(r["q"]) for r in held}
quoted = [i for i, rc in rcs.items() if rc != 1]
control = grep_rc("#!/usr/bin/env bash")
print("ok" if control == 0 and len(held) >= 20 and 2 * len(plain) >= len(held) and not quoted else "control=%d held=%d plain=%d quoted_or_error=%s" % (control, len(held), len(plain), quoted))' "$EV" "$HERE/questions.jsonl" "$REPO_ROOT")"
eq "shipped set widens golds: graded rows exist in both slices" "True True" "$(py -c 'import json,sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
g = lambda sp: any(r.get("gold1") for r in rows if r.get("split", "insample") == sp)
print(g("insample"), g("heldout"))' "$HERE/questions.jsonl")"

# 11. census: a qmd call that errors, then a grep, is a fallback; graphify via worker-graph counts.
P="$W/projects/-home-x-himmel"; mkdir -p "$P"
cat > "$P/s1.jsonl" <<'EOF'
{"type":"custom-title","customTitle":"HIMMEL-1-N1-x"}
{"type":"assistant","timestamp":"2026-10-17T10:00:00Z","message":{"content":[{"type":"tool_use","id":"a","name":"mcp__qmd__query","input":{"searches":[{"type":"lex","query":"x"}]}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"a","is_error":true,"content":"The operation timed out."}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"b","name":"Bash","input":{"command":"git grep -n foo"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"b","content":"docs/a.md:1:foo"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"c","name":"Bash","input":{"command":"bash scripts/graphify/worker-graph.sh query \"how\""}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"c","content":"NODE a [src=docs/a.md loc=L1]"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"d","name":"Read","input":{"file_path":"/r/docs/a.md"}}]}}
EOF
py "$EV" census --projects "$W/projects" --days 0 --out "$W/census.json" > "$W/census.txt" 2>&1
eq "census exits 0" "0" "$?"
cz() { py -c 'import json,sys; d=json.load(open(sys.argv[1]))["roles"]["worker"]; print(d[sys.argv[2]])' "$W/census.json" "$1"; }
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
eq "census: a call older than the window is not counted" "0" "$(py -c 'import json,sys; print(json.load(open(sys.argv[1]))["roles"]["worker"]["qmd_calls"])' "$W/census2.json")"

# 13. census used/failed heuristics: a full path decides used, the is_error flag decides failed,
# and qmd get / multi_get (either tool prefix) are counted.
P3="$W/projects3/-home-x-himmel"; mkdir -p "$P3"
cat > "$P3/s3.jsonl" <<'EOF'
{"type":"custom-title","customTitle":"HIMMEL-3-N3-z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"a","name":"mcp__qmd__query","input":{"searches":[{"type":"lex","query":"x"}]}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"a","content":"{\"results\":[{\"file\":\"himmel/docs/a/README.md\"}]}"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"b","name":"Read","input":{"file_path":"/r/docs/b/README.md"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"b","content":"x"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"c","name":"Bash","input":{"command":"bash scripts/graphify/worker-graph.sh query \"hooks\""}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"c","is_error":false,"content":"NODE h [src=docs/h.md loc=L1] error: handler not found, request denied"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"d","name":"Read","input":{"file_path":"/r/docs/h.md"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"d","content":"x"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"e","name":"mcp__qmd__get","input":{"file":"himmel/docs/g.md"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"e","content":"[Resource from qmd at qmd://himmel/docs/g.md] 1: see docs/unrelated/README.md"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"f","name":"Read","input":{"file_path":"/r/.claude/worktrees/w/docs/g.md"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"f","content":"x"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"g","name":"mcp__plugin_qmd_qmd__multi_get","input":{"pattern":"himmel/docs/m1.md,himmel/docs/m2.md"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"g","content":"[Resource from qmd at qmd://himmel/docs/m1.md] 1: x"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"h","name":"Read","input":{"file_path":"/r/docs/other.md"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"i","name":"mcp__qmd__query","input":{"searches":[{"type":"lex","query":"zzz"}]}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"i","content":"{\"results\":[]}"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"j","name":"mcp__qmd__multi_get","input":{"pattern":"himmel/docs/*.md"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"j","content":"[Resource from qmd at qmd://himmel/docs/glob.md] 1: x"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"k","name":"Read","input":{"file_path":"/r/docs/glob.md"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"l","name":"mcp__qmd__query","input":{"searches":[{"type":"lex","query":"yyy"}]}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"l","content":"{\"results\": []}"}]}}
EOF
py "$EV" census --projects "$W/projects3" --days 0 --out "$W/census3.json" > /dev/null 2>&1
c3() { py -c 'import json,sys; print(json.load(open(sys.argv[1]))["roles"]["worker"][sys.argv[2]])' "$W/census3.json" "$1"; }
eq "census: qmd get and multi_get (either prefix) are counted" "6" "$(c3 qmd_calls)"
eq "census: only an empty results envelope (any spacing) fails; a body with error: and is_error false does not" "2 0" "$(c3 qmd_failed) $(c3 graphify_failed)"
eq "census: a README.md in another directory is not used; get is used by its input path, a glob multi_get by its result headers" "2" "$(c3 qmd_used)"
eq "census: graphify answer with error: in the body is used when its file is read" "1" "$(c3 graphify_used)"

# 14. the RTK arms: the same query goes through rtk the way the hook rewrites it (grep -> rtk grep), and the
# row is scored on what rtk returns. Without rtk on PATH the arms are skipped with a recorded reason.
: > "$RTK_LOG"
printf '{"id":"r1","kind":"why","q":"why does a halt need no token","gold":["docs/lock.md"],"reason":["mild DoS"]}\n{"id":"r2","kind":"where","q":"where is relay_batch defined","gold":["bin/run.sh"],"reason":[]}\n' > "$W/qr.jsonl"
HIMMEL_EVAL_RUNS_LEDGER="$W/ledger-14.jsonl" py "$EV" run --repo "$R" --questions "$W/qr.jsonl" --out "$W/outr" --arms grep,grep-rtk,ident-grep,ident-grep-rtk > /dev/null 2>&1
eq "RTK arms are accepted by --arms" "0" "$?"
r() { awk -F'\t' -v a="$1" -v c="$2" 'NR==1{for(i=1;i<=NF;i++)h[$i]=i;next} $1==a{print $h[c]}' "$W/outr/scores.tsv"; }
eq "grep-rtk scores the same hit@5 as grep" "$(r grep hit@5)" "$(r grep-rtk hit@5)"
eq "ident-grep-rtk scores the same hit@5 as ident-grep" "$(r ident-grep hit@5)" "$(r ident-grep-rtk hit@5)"
eq "grep-rtk carries the q1 reason" "1.00" "$(r grep-rtk reason_carried)"
eq "the rtk argv rewrites a grep command" "grep -n -I" "$(grep -m1 '^rewrite ' "$RTK_LOG" | cut -d' ' -f2-4)"
eq "the rewritten command runs as rtk grep" "yes" "$(grep -q '^grep -n -I -H -i -F' "$RTK_LOG" && echo yes || echo no)"
eq "the ident arm runs rtk grep -w" "yes" "$(grep -q '^grep -n -I -H -w -F' "$RTK_LOG" && echo yes || echo no)"
: > "$RTK_LOG"
HIMMEL_EVAL_RUNS_LEDGER="$W/ledger-14b.jsonl" py "$EV" run --repo "$R" --questions "$W/qr.jsonl" --out "$W/outr2" --arms grep,ident-grep > /dev/null 2>&1
eq "the raw arms never call rtk" "0" "$(wc -c < "$RTK_LOG" | tr -d ' ')"
mkdir -p "$W/nortk"
for t in git bash sh grep python3 env; do ln -sf "$(command -v "$t")" "$W/nortk/$t"; done
HIMMEL_EVAL_RUNS_LEDGER="$W/ledger-14c.jsonl" PATH="$W/nortk" python3 -I "$EV" run --repo "$R" --questions "$W/qr.jsonl" --out "$W/outr3" --arms grep,grep-rtk > "$W/outr3.txt" 2> "$W/outr3.err"
eq "without rtk the run still exits 0" "0" "$?"
eq "without rtk only the raw arm is scored" "grep" "$(awk -F'\t' 'NR>1{print $1}' "$W/outr3/scores.tsv" | tr '\n' ' ' | sed 's/ $//')"
eq "without rtk the skip and its reason are printed" "1" "$(grep -c 'skipping grep-rtk: rtk is not on PATH' "$W/outr3.err")"
eq "without rtk the ledger row records the skip" "rtk is not on PATH" "$(py -c 'import json,sys; print(json.loads(open(sys.argv[1]).readlines()[-1])["config"]["skipped"]["grep-rtk"])' "$W/ledger-14c.jsonl")"

eq "graph_built streams past 5 MiB and keeps the first stamp across a chunk boundary" "abc123def" "$(py -c 'import importlib.util,pathlib,sys
s = importlib.util.spec_from_file_location("ev", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
p = pathlib.Path(sys.argv[2]) / "graphify-out/graph.json"
p.write_text(" " * (6 * 1024 * 1024 - 18) + "{\"built_at_commit\": \"abc123def\", \"built_at_commit\": \"deadbeef\"}")
print(m.graph_built(sys.argv[2]))' "$EV" "$R")"
eq "an unstamped graph and an unresolved common dir raise clear errors" "True" "$(py -c 'import importlib.util,pathlib,sys
s = importlib.util.spec_from_file_location("ev", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
(pathlib.Path(sys.argv[2]) / "graphify-out/graph.json").write_text("{}")
errors = []
for repo in sys.argv[2:]:
    try:
        m.graph_built(repo)
    except RuntimeError as e:
        errors.append(str(e))
print(len(errors) == 2 and "built_at_commit" in errors[0] and "common" in errors[1])' "$EV" "$R" "$W/not-a-repo")"
rm "$R/graphify-out/graph.json"
HIMMEL_EVAL_RUNS_LEDGER="$W/ledger-stamp.jsonl" py "$EV" run --repo "$R" --questions "$Q" --out "$W/out-stamp" --arms graphify,combined > "$W/stamp.txt" 2> "$W/stamp.err"
eq "graph arms exit 1 when their stamp is missing" "1" "$?"
eq "missing graph stamp is reported once" "1" "$(grep -c '^retrieval-eval: ERROR graph stamp:' "$W/stamp.err")"
eq "missing stamp still writes results, scores, slices and ledger metadata" "True" "$(py -c 'import json,pathlib,sys
m = json.loads(open(sys.argv[1]).readline())["meta"]
print(m.get("graph_built_at") is None and "graph.json" in m.get("graph_built_error", "")
      and all((pathlib.Path(sys.argv[2]) / f).is_file() for f in ("results.jsonl", "scores.tsv", "scores-by-slice.tsv")))' "$W/ledger-stamp.jsonl" "$W/out-stamp")"
HIMMEL_EVAL_RUNS_LEDGER="$W/ledger-nostamp.jsonl" py "$EV" run --repo "$R" --questions "$Q" --out "$W/out-nostamp" --arms grep > /dev/null 2> "$W/nostamp.err"
eq "no graph arm needs no stamp" "0" "$?"
eq "no graph arm prints no stamp error" "0" "$(grep -c 'ERROR graph stamp' "$W/nostamp.err")"
eq "no graph arm records null without an error" "True" "$(py -c 'import json,sys
m = json.loads(open(sys.argv[1]).readline())["meta"]
print(m.get("graph_built_at", "missing") is None and "graph_built_error" not in m)' "$W/ledger-nostamp.jsonl")"
printf '{"built_at_commit": "abc123def"}\n' > "$R/graphify-out/graph.json"

cat > "$W/qmd-deep" <<'EOF'
#!/usr/bin/env python3
import json, sys
a = json.load(sys.stdin)
files = ["docs/z%d.md" % i for i in range(5)] + ["docs/shared.md"] + ["docs/z%d.md" % i for i in range(6, 25)]
print(json.dumps([{"file": "qmd://himmel/" + f, "snippet": "deep reason" if f.endswith("shared.md") else "noise"}
                  for f in files[:a["limit"]]]))
EOF
cat > "$W/graph-deep" <<'EOF'
#!/usr/bin/env bash
printf 'NODE a [src=docs/a0.md]\nNODE b [src=docs/a1.md]\nNODE c [src=docs/a2.md]\nNODE d [src=docs/a3.md]\nNODE e [src=docs/a4.md]\nNODE shared [src=docs/shared.md]\n'
EOF
chmod +x "$W/qmd-deep" "$W/graph-deep"
printf '{"id":"depth","q":"depthprobe","gold":["docs/shared.md"],"reason":["deep reason"]}\n' > "$W/deep.jsonl"
RETRIEVAL_EVAL_QMD_CMD="$W/qmd-deep" RETRIEVAL_EVAL_GRAPH_CMD="$W/graph-deep" HIMMEL_EVAL_RUNS_LEDGER="$W/ledger-deep.jsonl" py "$EV" run --repo "$R" --questions "$W/deep.jsonl" --out "$W/out-deep" --arms grep,qmd-hybrid,graphify,combined > /dev/null 2>&1
eq "top20 evidence keeps deeper candidates while scoring and fusion use first k" "True" "$(py -c 'import json,sys
r = {x["arm"]: x for x in map(json.loads, open(sys.argv[1]))}
qm, co = r["qmd-hybrid"], r["combined"]
print(len(qm.get("files_top20", [])) == 20 and qm["files_top20"][:5] == qm["files"]
      and "docs/shared.md" in qm["files_top20"] and not qm["hit"] and qm["ndcg"] == 0
      and qm["reason"] is False and not co["hit"] and co["files"] == ["docs/a0.md", "docs/z0.md", "docs/a1.md", "docs/z1.md", "docs/a2.md"]
      and len(co.get("files_top20", [])) == 20 and co["files_top20"][0] == "docs/shared.md"
      and all(x.get("skipped") is False and x.get("qmd_error") == "" for x in r.values()))' "$W/out-deep/results.jsonl")"
eq "skipped arms still have no result rows" "True" "$(py -c 'import json,sys
print(all(r["arm"] == "grep" and r.get("skipped") is False for r in map(json.loads, open(sys.argv[1]))))' "$W/outr3/results.jsonl")"

cat > "$W/qmd-reorder" <<'EOF'
#!/usr/bin/env python3
import json, os, sys
a = json.load(sys.stdin)
open(os.environ["QMD_LIMITS"], "a").write("%d\n" % a["limit"])
files = ["docs/p%d.md" % i for i in range(5)] if a["limit"] <= 5 else ["docs/shared.md"] + ["docs/p%d.md" % i for i in range(24)]
print(json.dumps([{"file": "qmd://himmel/" + f, "snippet": "x"} for f in files[:a["limit"]]]))
EOF
chmod +x "$W/qmd-reorder"
QMD_LIMITS="$W/qmd-limits.log" RETRIEVAL_EVAL_QMD_CMD="$W/qmd-reorder" HIMMEL_EVAL_RUNS_LEDGER="$W/ledger-reorder.jsonl" py "$EV" run --repo "$R" --questions "$W/deep.jsonl" --out "$W/out-reorder" --arms qmd-hybrid > /dev/null 2>&1
eq "the scored qmd list comes from the limit-k query, the top 20 from a separate query" "True" "$(py -c 'import json,sys
r = json.loads(open(sys.argv[1]).readline())
print(r["files"] == ["docs/p%d.md" % i for i in range(5)] and not r["hit"]
      and len(r["files_top20"]) == 20 and r["files_top20"][0] == "docs/shared.md"
      and sorted(int(x) for x in open(sys.argv[2]).read().split()) == [5, 20])' "$W/out-reorder/results.jsonl" "$W/qmd-limits.log")"
eq "the ledger config records the evidence depth" "20" "$(py -c 'import json,sys
print(json.loads(open(sys.argv[1]).readline())["config"].get("evidence_depth"))' "$W/ledger-reorder.jsonl")"

py - "$W" <<'PY'
import json, pathlib, sys
w = pathlib.Path(sys.argv[1])
qs, rows = [], []
for qid, gold, split in (("dev-rescue", "z-gold.md", "insample"), ("dev-regress", "g.md", "insample"),
                          ("heldout-secret", "z-gold.md", "heldout")):
    qs.append(dict(id=qid, q="fixture", gold=[gold], split=split, reason=[]))
    for arm, names in (("grep", "abcde"), ("qmd-hybrid", "fghij"), ("graphify", "klmno")):
        rows.append(dict(id=qid, arm=arm, files=[c + ".md" for c in names]))
    rows.extend([dict(id=qid, arm="path", files=["z-gold.md"]), dict(id=qid, arm="ident-grep", files=[]),
                 dict(id=qid, arm="combined", files=[c + ".md" for c in "afkbg"], hit=gold == "g.md")])
for name, data in (("replay-q.jsonl", qs), ("replay.jsonl", rows),
                   ("replay-missing.jsonl", [r for r in rows if not (r["id"] == "dev-regress" and r["arm"] == "path")]),
                   ("replay-no-baseline.jsonl", [r for r in rows if r["arm"] != "combined"]),
                   ("replay-unknown.jsonl", rows + [dict(id="absent", arm="grep", files=[])])):
    (w / name).write_text("".join(json.dumps(x) + "\n" for x in data))
PY
mkdir -p "$W/python-only"
ln -s "$(command -v python3)" "$W/python-only/python3"
PATH="$W/python-only" python3 -I "$EV" replay --results "$W/replay.jsonl" --questions "$W/replay-q.jsonl" > "$W/replay.txt" 2>&1
eq "default replay works with only Python on PATH" "0" "$?"
eq "default replay reproduces the saved combined count" "1" "$(grep -c '^reproduces saved combined: yes$' "$W/replay.txt")"
eq "default replay reports the saved and replayed slices" "2" "$(grep -c 'combined: insample 1/2 heldout 0/1 all 1/3$' "$W/replay.txt")"
py "$EV" replay --results "$W/replay.jsonl" --questions "$W/replay-q.jsonl" --add path > "$W/replay-add.txt" 2>&1
eq "added path replay runs" "0" "$?"
eq "added path reports a dev rescue" "1" "$(grep -c '^rescued (dev): dev-rescue$' "$W/replay-add.txt")"
eq "added path reports a dev regression" "1" "$(grep -c '^regressed (dev): dev-regress$' "$W/replay-add.txt")"
eq "added path reports held-out counts only" "1" "$(grep -c '^replay combined: insample 1/2 heldout 1/1 all 2/3$' "$W/replay-add.txt")"
eq "a changed total does not reproduce saved combined" "1" "$(grep -c '^reproduces saved combined: no$' "$W/replay-add.txt")"
eq "held-out IDs never appear in replay output" "0" "$(cat "$W/replay.txt" "$W/replay-add.txt" | grep -c 'heldout-secret')"
py - "$W" <<'PY'
import json, pathlib, sys
w = pathlib.Path(sys.argv[1])
qs, rows = [], []
for qid, gold, split, saved_hit, found in (("c-in", "a.py", "insample", True, "a.py"), ("c-miss", "b.sh", "insample", False, None),
                                           ("c-held", "c.js", "heldout", True, "c.js"), ("d-in", "d.md", "insample", True, "d.md"),
                                           ("d-held", "e.md", "heldout", False, None)):
    qs.append(dict(id=qid, q="fixture", gold=[gold], split=split, reason=[]))
    files = [found] if found else []
    rows.extend([dict(id=qid, arm="grep", files=files), dict(id=qid, arm="qmd-hybrid", files=[]),
                 dict(id=qid, arm="graphify", files=[]), dict(id=qid, arm="path", files=[gold]),
                 dict(id=qid, arm="combined", files=files, hit=saved_hit)])
for name, data in (("replay-s-q.jsonl", qs), ("replay-s.jsonl", rows)):
    (w / name).write_text("".join(json.dumps(x) + "\n" for x in data))
PY
py "$EV" replay --results "$W/replay-s.jsonl" --questions "$W/replay-s-q.jsonl" > "$W/replay-s.txt" 2>&1
eq "strata replay runs" "0" "$?"
eq "replay keeps the split counts for the saved and replayed combined" "2" "$(grep -c 'combined: insample 2/3 heldout 1/2 all 3/5$' "$W/replay-s.txt")"
eq "replay prints the saved combined count per stratum" "1" "$(grep -c '^saved combined by stratum: code 2/3 doc 1/2$' "$W/replay-s.txt")"
eq "replay prints the replayed combined count per stratum" "1" "$(grep -c '^replay combined by stratum: code 2/3 doc 1/2$' "$W/replay-s.txt")"
py "$EV" replay --results "$W/replay-s.jsonl" --questions "$W/replay-s-q.jsonl" --add path > "$W/replay-s-add.txt" 2>&1
eq "added path moves the replayed stratum counts and not the saved ones" "1 1" "$(grep -c '^saved combined by stratum: code 2/3 doc 1/2$' "$W/replay-s-add.txt") $(grep -c '^replay combined by stratum: code 3/3 doc 2/2$' "$W/replay-s-add.txt")"
eq "the rescue list stays insample-only" "1 0" "$(grep -c '^rescued (dev): c-miss$' "$W/replay-s-add.txt") $(cat "$W/replay-s-add.txt" | grep -c -E 'c-held|d-held')"
py "$EV" replay --results "$W/replay-missing.jsonl" --questions "$W/replay-q.jsonl" --add path > "$W/replay-missing.txt" 2>&1
eq "an arm missing for one question is a Usage error" "64" "$?"
eq "the missing arm is named" "1" "$(grep -c "missing arm 'path'" "$W/replay-missing.txt")"
py "$EV" replay --results "$W/replay-no-baseline.jsonl" --questions "$W/replay-q.jsonl" > "$W/replay-baseline.txt" 2>&1
eq "a missing saved baseline is a Usage error" "64" "$?"
eq "the missing baseline arm is named" "1" "$(grep -c "missing arm 'combined'" "$W/replay-baseline.txt")"
py "$EV" replay --results "$W/replay-unknown.jsonl" --questions "$W/replay-q.jsonl" > /dev/null 2>&1
eq "a saved question missing from the question set is a Usage error" "64" "$?"
py "$EV" replay --results "$W/replay.jsonl" --questions "$W/replay-q.jsonl" --rrf-k 1 > "$W/replay-rrf.txt" 2>&1
eq "a different RRF constant still runs" "0" "$?"
eq "a changed RRF constant does not claim reproduction even with the same count" "1" "$(grep -c '^reproduces saved combined: no$' "$W/replay-rrf.txt")"
py "$EV" replay --results "$W/replay.jsonl" --questions "$W/replay-q.jsonl" --add ident-grep > "$W/replay-arms.txt" 2>&1
eq "a changed fused set does not claim reproduction even with the same count" "1" "$(grep -c '^reproduces saved combined: no$' "$W/replay-arms.txt")"
if py - "$EV" "$W" > "$W/replay-audit.txt" 2>&1 <<'PY'
import importlib.util, sys
s = importlib.util.spec_from_file_location("ev", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
def audit(event, args):
    if event in ("subprocess.Popen", "os.system", "socket.connect"):
        raise AssertionError("replay attempted " + event)
sys.addaudithook(audit)
sys.exit(m.main(["replay", "--results", sys.argv[2] + "/replay.jsonl", "--questions", sys.argv[2] + "/replay-q.jsonl"]))
PY
then pass "replay makes no subprocess or network calls"
else fail "replay makes no subprocess or network calls"; fi

cat > "$W/qmd-deepfail" <<'EOF'
#!/usr/bin/env python3
import json, sys
a = json.load(sys.stdin)
if a["limit"] > 5:
    sys.stderr.write("deep query failed\n")
    sys.exit(1)
print(json.dumps([{"file": "qmd://himmel/docs/lock.md", "snippet": "queue lock"}]))
EOF
chmod +x "$W/qmd-deepfail"
RETRIEVAL_EVAL_QMD_CMD="$W/qmd-deepfail" HIMMEL_EVAL_RUNS_LEDGER="$W/fwd/ledger.jsonl" py "$EV" run --repo "$R" --questions "$W/deep.jsonl" --out "$W/out-deepfail" --arms qmd-hybrid > /dev/null 2>&1
eq "a failed deep second call is recorded on the row, the k-list kept as the evidence list" "True True" "$(py -c 'import json,sys
r = json.loads(open(sys.argv[1]).readline())
print(r.get("deep_failed"), r["files_top20"] == r["files"])' "$W/out-deepfail/results.jsonl")"
eq "the ledger row counts the arm's deep second-call failures" "1" "$(lm "$W/fwd/ledger.jsonl" qmd-hybrid.deep_failures)"
eq "the row forwards a complete identity hash into its hashed config" "True" "$(py -c 'import json,sys
r = json.loads(open(sys.argv[1]).readline())
i = r["meta"].get("identity") or {}
print(bool(r["config"].get("identity_hash")) and all(i.get(k) for k in ("bank_sha256", "evaluator_sha256", "shaper_sha256", "harness_commit", "dirty_digest")))' "$W/fwd/ledger.jsonl")"
eq "the run's artifacts are retained, content-addressed, before the row is written" "True" "$(py -c 'import json,os,sys
r = json.loads(open(sys.argv[1]).readline())
m = json.load(open(os.path.join(sys.argv[2], "runs", r["run_id"] + ".json")))
print(m["manifest_sha256"] == r["meta"]["retained_manifest_sha256"] and "results" in m["artifacts"]
      and oct(os.stat(sys.argv[2]).st_mode & 0o777) == "0o700")' "$W/fwd/ledger.jsonl" "$W/fwd/eval-retained")"
mkdir -p "$W/fwd-bad"; : > "$W/fwd-bad/eval-retained"
RETRIEVAL_EVAL_QMD_CMD="$W/qmd-md" HIMMEL_EVAL_RUNS_LEDGER="$W/fwd-bad/ledger.jsonl" py "$EV" run --repo "$R" --questions "$W/deep.jsonl" --out "$W/out-fwdbad" --arms qmd-hybrid > /dev/null 2> "$W/fwdbad.err"
eq "a retention failure writes no ledger row" "absent" "$([ -s "$W/fwd-bad/ledger.jsonl" ] && echo present || echo absent)"
G="$W/idrepo"; mkdir -p "$G"; printf 'shaper v1\n' > "$G/shaper.py"
git -C "$G" init -q && git -C "$G" add -A && git -C "$G" -c user.email=t@t -c user.name=t commit -q -m s
eq "an uncommitted shaper edit changes the identity hash at the same commit" "True" "$(py - "$EV" "$G" "$W/deep.jsonl" <<'PY'
import importlib.util, sys
s = importlib.util.spec_from_file_location("ev", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
a = m.forward_identity(sys.argv[3], sys.argv[1], root=sys.argv[2], shapers=[sys.argv[2] + "/shaper.py"])
open(sys.argv[2] + "/shaper.py", "a").write("edited\n")
b = m.forward_identity(sys.argv[3], sys.argv[1], root=sys.argv[2], shapers=[sys.argv[2] + "/shaper.py"])
print(a["identity"]["harness_commit"] == b["identity"]["harness_commit"] and a["config_hash"] != b["config_hash"]
      and a["identity"]["dirty_digest"] == "clean" and b["identity"]["dirty_digest"] != "clean")
PY
)"

SU="http://127.0.0.1:47999/mcp"
PD="$W/pair"; mkdir -p "$PD/graph-s/graphify-out" "$PD/graph-l/graphify-out"
printf '{"built_at_commit": "5555555"}\n' > "$PD/graph-s/graphify-out/graph.json"
printf '{"built_at_commit": "6666666"}\n' > "$PD/graph-l/graphify-out/graph.json"
printf '{"first": "aaaa", "second": "bbbb", "state": "l", "doc_count": 5, "index": "%s/index.sqlite", "served_url": "%s", "graph_built_at": {"aaaa": "%s/graph-s", "bbbb": "%s/graph-l"}}\n' "$PD" "$SU" "$PD" "$PD" > "$PD/pair.json"
printf '{"id":"s1","kind":"what","q":"why does a halt need no token","gold":["docs/lock.md"],"reason":[],"stale_stratum":"added"}\n{"id":"s2","kind":"where","q":"where is relay_batch defined","gold":["bin/run.sh"],"reason":[],"stale_stratum":"kept"}\n' > "$W/qs.jsonl"
# shellcheck disable=SC2016  # the stubs' own $-expansions must stay literal
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${WORKER_GRAPH_OUT:-unset}" >> "%s/graph-env.log"\nprintf "NODE x [src=docs/lock.md loc=L1 community=x]\\n"\n' "$W" > "$W/graph-env"
# shellcheck disable=SC2016  # the stub's own $-expansion must stay literal
printf '#!/usr/bin/env bash\nprintf "{\\"totalDocuments\\": %%s}\\n" "${STUB_DOCS:-5}"\n' > "$W/status"
chmod +x "$W/graph-env" "$W/status"
pr() {
    local tag="$1"; shift
    local e=(); while [ "$1" != -- ]; do e+=("$1"); shift; done; shift
    env "${e[@]}" HIMMEL_EVAL_RUNS_LEDGER="$W/ledger-$tag.jsonl" RETRIEVAL_EVAL_QMD_STATUS_CMD="$W/status" \
        python3 -I "$EV" run --repo "$R" --questions "$W/qs.jsonl" --out "$W/out-$tag" --pair "$PD/pair.json" "$@" > "$W/pr-$tag.txt" 2>&1
}
for u in unset "http://127.0.0.1:8181/mcp" "http://[::1]:8181/mcp" "http://127.0.0.1:47998/mcp"; do
    if [ "$u" = unset ]; then pr "alias" -u QMD_URL -- --index-state l --arms qmd-lex; rc=$?
    else pr "alias" "QMD_URL=$u" -- --index-state l --arms qmd-lex; rc=$?; fi
    eq "refuses_live_url_alias: $u is refused with exit 2 and writes no row" "2 absent" "$rc $([ -s "$W/ledger-alias.jsonl" ] && echo present || echo absent)"
done
pr "good" "QMD_URL=$SU" -- --index-state l --arms qmd-lex
eq "the pair's own URL runs" "0" "$?"
pr "count" "QMD_URL=$SU" STUB_DOCS=7 -- --index-state l --arms qmd-lex
eq "refuses_count_mismatch: a served count that is not pair.json's is refused with exit 2" "2 absent" "$? $([ -s "$W/ledger-count.jsonl" ] && echo present || echo absent)"
eq "the served count is read from a real MCP status reply" "5" "$(py - "$EV" <<'PY'
import http.server, importlib.util, json, os, sys, threading
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        out = {"jsonrpc": "2.0", "id": body.get("id")}
        if body.get("method") == "tools/call":
            assert body["params"]["name"] == "status"
            out["result"] = {"structuredContent": {"totalDocuments": 5}}
        data = json.dumps(out).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("mcp-session-id", "s1")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *a):
        pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever).start()
os.environ["QMD_URL"] = "http://127.0.0.1:%d/mcp" % srv.server_address[1]
s = importlib.util.spec_from_file_location("ev", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(m.served_count(5))
srv.shutdown()
PY
)"
pr "label" "QMD_URL=$SU" -- --index-state s --arms qmd-lex
eq "a state label that is not the served index's state is refused with exit 2" "2 absent" "$? $([ -s "$W/ledger-label.jsonl" ] && echo present || echo absent)"
eq "row_records_served_index: config names state, both commits, the served path and its count" "l aaaa bbbb $PD/index.sqlite 5" "$(py -c 'import json,sys
c = json.loads(open(sys.argv[1]).readline())["config"]
print(c["index_state"], c["first"], c["second"], c["index"], c["doc_count"])' "$W/ledger-good.jsonl")"
eq "every result row carries its index state and stale stratum" "l added" "$(py -c 'import json,sys
r = json.loads(open(sys.argv[1]).readline()); print(r["index_state"], r["stale_stratum"])' "$W/out-good/results.jsonl")"
rm -f "$W/graph-env.log"
pr "g1" "RETRIEVAL_EVAL_GRAPH_CMD=$W/graph-env" "WORKER_GRAPH_OUT=$R/graphify-out" -- --index-state s --arms graphify
eq "a stale-state graph run reads the graph built at the first commit, not the caller's WORKER_GRAPH_OUT" "0 $PD/graph-s/graphify-out 5555555" "$? $(sort -u "$W/graph-env.log") $(py -c 'import json,sys
print(json.loads(open(sys.argv[1]).readline())["meta"]["graph_built_at"])' "$W/ledger-g1.jsonl")"
rm -rf "$PD/graph-s/graphify-out"; ln -s "$R/graphify-out" "$PD/graph-s/graphify-out"
pr "g2" "RETRIEVAL_EVAL_GRAPH_CMD=$W/graph-env" -- --index-state s --arms graphify
eq "refuses_primary_graph_by_symlink: a pair graph that links to the checkout's graphify-out is refused" "2 absent" "$? $([ -s "$W/ledger-g2.jsonl" ] && echo present || echo absent)"

cat > "$W/plant.py" <<'PY'
import json, os, sys
d, arm, stratum, s_only, l_only = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5])
states = sys.argv[6] if len(sys.argv) > 6 else "sl"
for st in states:
    os.makedirs(os.path.join(d, st), exist_ok=True)
    with open(os.path.join(d, st, "results.jsonl"), "a") as fh:
        for i in range(20):
            hit = i < 10 or (10 <= i < 10 + s_only and st == "s") or (20 - l_only <= i and st in "lc")
            fh.write(json.dumps(dict(id="%s-%s-%d" % (arm, stratum, i), arm=arm, index_state=st, stale_stratum=stratum, hit=hit)) + "\n")
PY
plant() { py "$W/plant.py" "$@"; }
SR="$W/sr"; rm -rf "$SR"
plant "$SR" qmd-lex added 0 6
plant "$SR" qmd-lex kept 8 2
LAGNONE="$W/lag-none"; printf '#!/usr/bin/env bash\necho "headline: 0/0 = n/a within 39 min (no exclusions); wilson95 n/a"\n' > "$LAGNONE"; chmod +x "$LAGNONE"
RETRIEVAL_EVAL_LAG_CMD="$LAGNONE" py "$EV" stale-report "$SR" > "$W/sr.txt" 2>&1; eq "stale-report exits 0" "0" "$?"
eq "stale_report_interval: Kept, L minus S: n, points, exact McNemar p and the seeded bootstrap interval in points" "20 -30.0 0.1094 $(py -c 'import sys
sys.path.insert(0, sys.argv[1])
import eval_runs
ci = eval_runs.bootstrap_ci(sorted([-1] * 8 + [1] * 2 + [0] * 10), b=10000, seed=9517)
print("%.1f %.1f" % (ci["lo"] * 100, ci["hi"] * 100))' "$HERE/../lib")" "$(awk -F'\t' '$1=="qmd-lex" && $2=="L-S" && $3=="kept"{print $4, $7, $8, $9, $10}' "$W/sr.txt")"
eq "the Added stratum is the headline: it is the arm's first row" "added" "$(awk -F'\t' '$1=="qmd-lex"{print $3; exit}' "$W/sr.txt")"
eq "no c-state rows: the matching row is C1 not run" "C1 not run" "$(sed -n 's/^decides: \(.*\) | .*/\1/p' "$W/sr.txt")"
decide() {
    local d="$W/dec-$1"; rm -rf "$d"
    plant "$d" qmd-hybrid kept "$2" "$3" "${5:-slc}"
    printf '#!/usr/bin/env bash\necho "headline: x within 39 min (no exclusions); wilson95 %s"\n' "$4" > "$W/lag-$1"; chmod +x "$W/lag-$1"
    RETRIEVAL_EVAL_LAG_CMD="$W/lag-$1" py "$EV" stale-report "$d" 2>&1
}
row() { sed -n 's/^decides: \(.*\) | .*/\1/p'; }
eq "decides_row_matches: C1 not run when no c-state hybrid rows exist" "C1 not run" "$(decide nc 0 0 '0.7000 to 0.9000' sl | row)"
eq "decides_row_matches: Kept L below S with p under .05 is Harm shown" "Harm shown" "$(decide harm 8 0 '0.7000 to 0.9000' | row)"
eq "decides_row_matches: no harm and the baseline's low end at 0.5 or above is L is already normal" "L is already normal" "$(decide norm 0 0 '0.5100 to 0.8000' | row)"
eq "decides_row_matches: no harm and the baseline's high end under 0.5 is The hole would be new" "The hole would be new" "$(decide hole 0 0 '0.2000 to 0.4900' | row)"
eq "decides_row_matches: no harm and an interval spanning 0.5 is Not shown" "Not shown" "$(decide span 0 0 '0.3000 to 0.7000' | row)"
eq "baseline_absent_prints_pending: baseline pending, and no decides line" "1 0" "$(decide none 0 0 'n/a' | awk '/^baseline pending/{p++} /^decides:/{d++} END{print p+0, d+0}')"
DUP="$W/dup"; rm -rf "$DUP"
plant "$DUP/a" qmd-lex kept 8 2; plant "$DUP/b" qmd-lex kept 8 2
RETRIEVAL_EVAL_LAG_CMD="$LAGNONE" py "$EV" stale-report "$DUP" > "$W/dup.txt" 2>&1
eq "stale_report_refuses_duplicate_rows: the same arm, question and state twice exits 64" "64" "$?"
INC="$W/inc"; rm -rf "$INC"
plant "$INC" qmd-hybrid kept 0 0 c
printf '#!/usr/bin/env bash\necho "headline: x within 39 min (no exclusions); wilson95 0.7000 to 0.9000"\n' > "$W/lag-inc"; chmod +x "$W/lag-inc"
RETRIEVAL_EVAL_LAG_CMD="$W/lag-inc" py "$EV" stale-report "$INC" > "$W/inc.txt" 2>&1
eq "stale_report_refuses_incomplete_comparison: c rows without a Kept L-S comparison exit 64 and print no decides line" "64 0" "$? $(grep -c '^decides:' "$W/inc.txt")"

G2="$W/xrepo"; mkdir -p "$G2"; git -C "$G2" init -q -b main
NOW="$(date +%s)"
gc() {
    printf '%s\n' "$2" >> "$G2/$1"; git -C "$G2" add -A
    local t; t="$(date -u -d "@$((NOW - $2))" +%Y-%m-%dT%H:%M:%S)"
    GIT_AUTHOR_DATE="$t +0000" GIT_COMMITTER_DATE="$t +0000" git -C "$G2" -c user.email=t@t -c user.name=t commit -q -m "$1"
}
gc c.sh 259200; gc b.sh 18000; gc a.sh 1800
mkdir -p "$W/proj/p1"
py - "$W/proj/p1/s.jsonl" "$G2" "$NOW" <<'PY'
import datetime, json, sys
out, repo, now = sys.argv[1], sys.argv[2], int(sys.argv[3])
ts = datetime.datetime.fromtimestamp(now - 120, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
with open(out, "w") as fh:
    for i, f in enumerate([repo + "/a.sh", repo + "/b.sh", repo + "/c.sh", "/elsewhere/other.sh",
                                 repo + "/.claude/worktrees/w1/a.sh"]):
        fh.write(json.dumps({"type": "assistant", "timestamp": ts, "message": {"content": [
            {"type": "tool_use", "id": "t%d" % i, "name": "Read", "input": {"file_path": f}}]}}) + "\n")
PY
py "$EV" exposure --days 14 --repo "$G2" --projects "$W/proj" > "$W/exp.txt" 2>&1
wl() { py -c 'import sys
sys.path.insert(0, sys.argv[1])
import wilson
w = wilson.wilson(int(sys.argv[2]), 4)
print("%.4f to %.4f" % (w["lo"], w["hi"]))' "$HERE/../lib" "$1"; }
eq "exposure_counts_planted_journal: 4 reads in the repo (one through a sibling worktree), 3 with a merge in the prior 24 h, 2 in the prior 1 h, each with its Wilson interval" \
    "prior 24 h: 3/4 = 0.7500; wilson95 $(wl 3)|prior 1 h: 2/4 = 0.5000; wilson95 $(wl 2)" \
    "$(grep '^prior ' "$W/exp.txt" | paste -sd'|' -)"

[ "$fails" -eq 0 ] && echo "all passed" || echo "$fails failed"
exit "$fails"
