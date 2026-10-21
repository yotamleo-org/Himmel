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
*casefold*) printf '[{"file":"qmd://himmel/claude.md","snippet":"rules"}]\n' ;;
*) printf '[{"file":"qmd://himmel/bin/run.sh","snippet":"relay_batch"}]\n' ;;
esac
EOF
chmod +x "$W/graph" "$W/qmd"
export RETRIEVAL_EVAL_GRAPH_CMD="$W/graph" RETRIEVAL_EVAL_QMD_CMD="$W/qmd"

# 1. a full run over the seven arms writes scores.tsv with one row per arm.
py "$EV" run --repo "$R" --questions "$Q" --out "$W/out" --label t1 > "$W/run.txt" 2>&1
eq "run exits 0" "0" "$?"
eq "scores.tsv has a header and seven arm rows" "8" "$(wc -l < "$W/out/scores.tsv" | tr -d ' ')"
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
eq "results.jsonl has 14 rows" "14" "$(wc -l < "$W/out/results.jsonl" | tr -d ' ')"
eq "every row carries tokens and ms" "14" "$(py -c 'import json,sys; print(sum(1 for l in open(sys.argv[1]) if {"tokens","ms","files","hit","reason"} <= set(json.loads(l))))' "$W/out/results.jsonl")"

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
eq "norerank sends lex+vec with rerank false" "lex,vec False" "$(py -c 'import json,sys; a=json.loads(open(sys.argv[1]).readlines()[1]); print(",".join(s["type"] for s in a["searches"]), a.get("rerank", "absent"))' "$W/qmd-in.log")"
eq "qmd-hybrid sends lex+vec with rerank true" "lex,vec True" "$(py -c 'import json,sys; a=json.loads(open(sys.argv[1]).readlines()[0]); print(",".join(s["type"] for s in a["searches"]), a.get("rerank", "absent"))' "$W/qmd-in.log")"
eq "default arms are the seven" "8" "$(wc -l < "$W/out/scores.tsv" | tr -d ' ')"

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
eq "scores-by-slice.tsv has one row per arm and slice" "3" "$(wc -l < "$W/outh/scores-by-slice.tsv" | tr -d ' ')"
eq "the run prints both slices" "2" "$(grep -cE '^grep	(insample|heldout)	' "$W/outh.txt")"
eq "results.jsonl rows carry their split" "insample heldout heldout" "$(py -c 'import json,sys; print(" ".join(json.loads(l)["split"] for l in open(sys.argv[1])))' "$W/outh/results.jsonl")"
# A run over a set with no held-out question still carries the held-out keys: n 0, scores null.
HIMMEL_EVAL_RUNS_LEDGER="$W/ledger-9c.jsonl" py "$EV" run --repo "$R" --questions "$Q" --out "$W/outq" --arms grep > /dev/null 2>&1
eq "no held-out question: held-out n is 0" "0" "$(lm "$W/ledger-9c.jsonl" grep.heldout.n)"
eq "no held-out question: held-out hit is null" "None" "$(lm "$W/ledger-9c.jsonl" 'grep.heldout.hit@5')"
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
