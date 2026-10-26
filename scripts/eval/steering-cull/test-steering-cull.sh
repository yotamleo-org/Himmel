#!/usr/bin/env bash
# scripts/eval/steering-cull/test-steering-cull.sh - suite for the steering-cull eval: the
# frozen rows and probes, the arm builder, the installer-owned text, the cost arm, the
# probe scorer and verdicts, and run.sh driven by a stub claude and a stub bank-preflight.
# No model call.
set -u
export HIMMEL_BILLED_OK=1   # stub claude only; run.sh refuses a bare run

HERE="$(cd "$(dirname "$0")" && pwd)"
CULL="$HERE/cull.py"
RUN="$HERE/run.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/steering-cull-test.XXXXXX")" || { echo "test-steering-cull: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export HIMMEL_EVAL_RUNS_LEDGER="$TMP/eval-runs.jsonl"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) pass "$1";; *) fail "$1: '$3' not in '$2'";; esac; }
hasnt() { case "$2" in *"$3"*) fail "$1: '$3' found";; *) pass "$1";; esac; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP test-steering-cull: python3 not on PATH"; exit 0; }

# --- the frozen rows and probes ---
eq "rows: every old span occurs exactly once in its baseline file" "$(python3 "$CULL" check 2>&1)" "ok"
eq "probes: every probe names a known row" "$(python3 -c 'import json,sys
rows={r["id"] for r in json.load(open(sys.argv[1]))["rows"]}
print(",".join(p["id"] for p in json.load(open(sys.argv[2]))["probes"] if p["row"] not in rows) or "ok")' "$HERE/rows.json" "$HERE/probes.json")" "ok"

# --- the arm builder ---
python3 "$CULL" build --arm baseline --dest "$TMP/arm-baseline" >/dev/null 2>&1
python3 "$CULL" build --arm cut --dest "$TMP/arm-cut" >/dev/null 2>&1
python3 "$CULL" build --arm red-r2-trailers --dest "$TMP/arm-red" >/dev/null 2>&1
eq "build baseline: the repo file is the frozen fixture" "$(cmp -s "$TMP/arm-baseline/repo/CLAUDE.md" "$HERE/fixtures/baseline/repo-CLAUDE.md" && echo same)" "same"
eq "build baseline: the user file sits one level up" "$(cmp -s "$TMP/arm-baseline/CLAUDE.md" "$HERE/fixtures/baseline/user-CLAUDE.md" && echo same)" "same"
eq "build baseline: RTK.md sits beside the user file for its @import" "$(cmp -s "$TMP/arm-baseline/RTK.md" "$HERE/fixtures/baseline/RTK.md" && echo same)" "same"
cut_repo="$(cat "$TMP/arm-cut/repo/CLAUDE.md" 2>/dev/null)"
red_repo="$(cat "$TMP/arm-red/repo/CLAUDE.md" 2>/dev/null)"
hasnt "build cut: the r2 span is replaced" "$cut_repo" "Attestation trailers"
has "build cut: the r2 cut text is in" "$cut_repo" "go in the FIRST commit; never \`--amend\`"
hasnt "build red: the r2 rule is gone entirely" "$red_repo" "Platforms tested"
has "build red: other rows stay at baseline" "$red_repo" "Never reach for the Atlassian MCP first"
eq "build: an unknown arm is refused" "$(python3 "$CULL" build --arm red-nope --dest "$TMP/arm-x" >/dev/null 2>&1; echo $?)" "2"

# --- installer-owned text survives the cut ---
graph_section() { python3 -c 'import sys; t=open(sys.argv[1]).read(); print(t[t.index("\n## graphify\n"):])' "$1"; }
eq "installer text: the repo ## graphify section is byte-identical in CUT" \
    "$(graph_section "$TMP/arm-cut/repo/CLAUDE.md" | sha256sum)" "$(graph_section "$HERE/fixtures/baseline/repo-CLAUDE.md" | sha256sum)"
cut_user="$(cat "$TMP/arm-cut/CLAUDE.md" 2>/dev/null)"
has "installer text: the user # graphify registration stays" "$cut_user" "When the user types \`/graphify\`"
has "installer text: the @RTK.md import stays" "$cut_user" "@RTK.md"
has "installer text: the Simplicity first heading stays" "$cut_user" "## 2. Simplicity first"

# --- the cost arm ---
mkdir -p "$TMP/sessions"
python3 -c 'import json,sys
rows=[]
for i in range(4):
    rows.append({"type":"assistant","message":{"id":"m%d" % i,"usage":{"input_tokens":5,"cache_creation_input_tokens":100 if i == 0 else 0,"cache_read_input_tokens":20000,"output_tokens":50}}})
rows.append({"type":"assistant","message":{"id":"m3","usage":{"input_tokens":5,"cache_read_input_tokens":20000,"output_tokens":50}}})
rows.append({"type":"user","message":{"content":"hi"}})
open(sys.argv[1],"w").write("\n".join(json.dumps(r) for r in rows)+"\n")' "$TMP/sessions/s1.jsonl"
cost="$(python3 "$CULL" cost --sessions "$TMP/sessions" --no-agents --json 2>&1)"
row_bytes() { printf '%s' "$cost" | python3 -c 'import json,sys
d=json.load(sys.stdin); r=[x for x in d["rows"] if x["id"]==sys.argv[1]][0]; print(r[sys.argv[2]])' "$1" "$2" 2>&1; }
eq "cost: a row's byte saving is old minus cut, in UTF-8" "$(row_bytes l64-history-comments bytes_saved)" \
    "$(python3 -c 'import json,sys; r=[x for x in json.load(open(sys.argv[1]))["rows"] if x["id"]=="l64-history-comments"][0]; print(len(r["old"].encode()) - len(r["cut"].encode()))' "$HERE/rows.json")"
eq "cost: tokens are bytes over 4, rounded down per side" "$(row_bytes u9-simpler-approach tokens_saved)" "18"
eq "cost: a session's turns count distinct message ids" "$(printf '%s' "$cost" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sessions"]["median_turns"])')" "4"
eq "cost: per-session cost-eq is one cache write plus a read per later turn" "$(row_bytes u9-simpler-approach cost_eq_per_session)" "27.9"
eq "cost: the per-turn share is the saving over the median cache read" "$(row_bytes u9-simpler-approach per_turn_share)" "0.0009"
eq "cost: the repo total leaves the ## graphify section out" "$(printf '%s' "$cost" | python3 -c 'import json,sys
d=json.load(sys.stdin); f=[x for x in d["files"] if x["file"]=="repo"][0]; print(f["baseline_bytes"])')" \
    "$(python3 -c 'import sys; t=open(sys.argv[1]).read(); print(len(t[:t.index("\n## graphify\n")].encode()))' "$HERE/fixtures/baseline/repo-CLAUDE.md")"

# --- the scorer ---
mkraw() { python3 -c 'import json,sys; print(json.dumps({"type":"result","is_error":False,"result":sys.argv[1],"total_cost_usd":0.002,
  "usage":{"input_tokens":10,"cache_creation_input_tokens":1000,"cache_read_input_tokens":2000,"output_tokens":40}}))' "$1" >"$2"; }
mkraw $'**ONE-WRITER**\nOne agent edits it.' "$TMP/raw1.json"
s="$(python3 "$CULL" summarize "$TMP/raw1.json" --probe r5-one-writer 2>&1)"
has "score: a bold first-line answer passes" "$s" '"pass": true'
has "score: cost-eq is input + 1.25 write + 0.1 read + 5 out" "$s" '"cost_eq": 1660.0'
mkraw $'```\ngit commit --amend\n```' "$TMP/raw2.json"
has "score: a must_not hit fails" "$(python3 "$CULL" summarize "$TMP/raw2.json" --probe r2-no-amend 2>&1)" '"pass": false'
mkraw $'```\ngit status\n```\nI never run `git commit --amend` here.' "$TMP/raw4.json"
has "score: a code-scoped probe ignores a must_not hit in the prose" "$(python3 "$CULL" summarize "$TMP/raw4.json" --probe r2-no-amend 2>&1)" '"pass": true'
mkdir -p "$TMP/rs/r2-no-amend/baseline"; cp "$TMP/raw4.json" "$TMP/rs/r2-no-amend/baseline/1.raw.json"
printf '{"error": false, "pass": false, "cost_eq": 1}\n' >"$TMP/rs/r2-no-amend/baseline/1.summary.json"
python3 "$CULL" rescore --runs "$TMP/rs" >/dev/null 2>&1
has "rescore: summaries are re-derived from the saved replies" "$(cat "$TMP/rs/r2-no-amend/baseline/1.summary.json" 2>&1)" '"pass": true'
printf 'not json\n' >"$TMP/raw3.json"
has "score: an unreadable run is an error, not a fail" "$(python3 "$CULL" summarize "$TMP/raw3.json" --probe r2-no-amend 2>&1)" '"error": true'

# --- run.sh with a stub claude ---
mkdir -p "$TMP/bin"
cat >"$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
prompt="$2"
(shift 2; printf '%s\n' "$*") >>"$STUB_LOG"
ctx="$(cat CLAUDE.md ../CLAUDE.md 2>/dev/null)"
ans="x"
case "$prompt" in
  *"first commit on a new branch"*) case "$ctx" in *"Platforms tested"*) ans=$'feat: [HIMMEL-42] x\n\nPlatforms tested: linux\nSecurity reviewed: manual';; *) ans="feat: x";; esac ;;
  *"three subagents"*) case "$ctx" in *"ONE writer"*) ans="ONE-WRITER";; *) ans="PARALLEL";; esac ;;
  *"wc -l"*) ans="SAY-SO" ;;
  *"internal design spec"*) case "$ctx" in *"specs/<type>"*) ans="STATE-REPO";; *) ans="HIMMEL-DOCS";; esac ;;
esac
python3 -c 'import json,sys; print(json.dumps({"type":"result","is_error":False,"result":sys.argv[1],"total_cost_usd":0.001,
  "usage":{"input_tokens":10,"cache_creation_input_tokens":100,"cache_read_input_tokens":100,"output_tokens":10}}))' "$ans"
STUB
chmod +x "$TMP/bin/claude"
printf '#!/usr/bin/env bash\necho PROCEED\n' >"$TMP/bin/pf-ok"; chmod +x "$TMP/bin/pf-ok"
printf '#!/usr/bin/env bash\necho WAIT\n' >"$TMP/bin/pf-no"; chmod +x "$TMP/bin/pf-no"
export STUB_LOG="$TMP/stub.log"
P="r2-first-commit,r2-no-amend,r5-one-writer,r5-retask-nonce,u9-say-simpler,l65-spec-home"

eq "run: refuses without HIMMEL_BILLED_OK" "$(HIMMEL_BILLED_OK='' SC_CLAUDE="$TMP/bin/claude" SC_PREFLIGHT="$TMP/bin/pf-ok" bash "$RUN" --phase red --out "$TMP/o0" >/dev/null 2>&1; echo $?)" "2"
eq "run: a bank refusal stops the sweep (exit 3)" "$(SC_CLAUDE="$TMP/bin/claude" SC_PREFLIGHT="$TMP/bin/pf-no" bash "$RUN" --phase red --out "$TMP/o1" --probes "$P" >/dev/null 2>&1; echo $?)" "3"
eq "run: cut before red is refused" "$(SC_CLAUDE="$TMP/bin/claude" SC_PREFLIGHT="$TMP/bin/pf-ok" bash "$RUN" --phase cut --out "$TMP/o2" --probes "$P" >/dev/null 2>&1; echo $?)" "2"

: >"$STUB_LOG"
SC_CLAUDE="$TMP/bin/claude" SC_PREFLIGHT="$TMP/bin/pf-ok" bash "$RUN" --phase red --out "$TMP/out" --probes "$P" --reps 2 >"$TMP/red.log" 2>&1
eq "run red: exit 0" "$?" "0"
eq "run red: baseline and red arms, 2 reps, 6 probes" "$(wc -l <"$STUB_LOG" | tr -d ' ')" "24"
has "run red: the child has no tools" "$(head -1 "$STUB_LOG")" "--tools  --setting-sources project"
has "run red: the child is told the model" "$(head -1 "$STUB_LOG")" "--model sonnet"
eq "run red: no cut arm yet" "$(cd "$TMP/out/r2-first-commit" && printf '%s ' *)" "baseline red-r2-trailers "
eq "valid: RED-first keeps the probes that pass BASELINE and fail RED" "$(python3 "$CULL" valid --runs "$TMP/out" | tr '\n' ' ')" "l65-spec-home r2-first-commit r5-one-writer "

: >"$STUB_LOG"
SC_CLAUDE="$TMP/bin/claude" SC_PREFLIGHT="$TMP/bin/pf-ok" bash "$RUN" --phase cut --out "$TMP/out" --probes "$P" --reps 2 >"$TMP/cut.log" 2>&1
eq "run cut: exit 0" "$?" "0"
eq "run cut: only the 3 valid probes run, 2 reps" "$(wc -l <"$STUB_LOG" | tr -d ' ')" "6"
eq "run cut: an invalid probe gets no cut arm" "$([ -d "$TMP/out/u9-say-simpler/cut" ] && echo yes || echo no)" "no"
: >"$STUB_LOG"
SC_CLAUDE="$TMP/bin/claude" SC_PREFLIGHT="$TMP/bin/pf-ok" bash "$RUN" --phase red --out "$TMP/out" --probes "$P" --reps 2 >/dev/null 2>&1
eq "run: a rerun resumes and calls nothing" "$(wc -l <"$STUB_LOG" | tr -d ' ')" "0"

rep="$(python3 "$CULL" report --runs "$TMP/out" --sessions "$TMP/sessions" --no-agents --ledger 2>"$TMP/report.err")"
verdict() { printf '%s\n' "$rep" | python3 -c 'import sys
for l in sys.stdin:
    c=[x.strip() for x in l.split("|")]
    if len(c) > 3 and c[1] == sys.argv[1]: print(c[-2]); break' "$1"; }
eq "verdict: CUT keeps the rule -> SHIP" "$(verdict r2-trailers)" "SHIP"
eq "verdict: CUT keeps single-writer -> SHIP" "$(verdict r5-invariants)" "SHIP"
eq "verdict: RED passes, the probe measures nothing -> SHIP-UNMEASURED" "$(verdict u9-simpler-approach)" "SHIP-UNMEASURED"
eq "verdict: CUT loses the rule -> KEEP" "$(verdict l65-specs-location)" "KEEP"
eq "verdict: a row with no probe -> UNPROBED" "$(verdict l64-history-comments)" "UNPROBED"
eq "verdict: a probed row not yet run -> PENDING" "$(verdict r3-jira)" "PENDING"
has "report: the row-to-line map names the operator's number" "$rep" "| r5-invariants | 5 | CLAUDE.md:45-53 |"
eq "ledger: one steering-cull row" "$(python3 -c 'import json,sys
r=[json.loads(l) for l in open(sys.argv[1])]; print(len(r), r[0]["eval"], r[0]["status"], sorted(r[0]["cases"])[0])' "$HIMMEL_EVAL_RUNS_LEDGER" 2>&1)" "1 steering-cull partial l65-spec-home"
eq "ledger: the row validates" "$(python3 "$HERE/../lib/eval_runs.py" validate "$HIMMEL_EVAL_RUNS_LEDGER" >/dev/null 2>&1; echo $?)" "0"

cp -r "$TMP/out" "$TMP/part"
rm -f "$TMP/part/r2-first-commit/cut/2.summary.json" "$TMP/part/l65-spec-home/baseline/2.summary.json"
rep="$(python3 "$CULL" report --runs "$TMP/part" --sessions "$TMP/sessions" --no-agents 2>/dev/null)"
eq "verdict: a CUT arm short of its configured reps -> PENDING" "$(verdict r2-trailers)" "PENDING"
eq "valid: a BASELINE arm short of its configured reps is not valid yet" "$(python3 "$CULL" valid --runs "$TMP/part" | tr '\n' ' ')" "r2-first-commit r5-one-writer "

: >"$STUB_LOG"
eq "run: a resume with another model is refused" "$(SC_CLAUDE="$TMP/bin/claude" SC_PREFLIGHT="$TMP/bin/pf-ok" bash "$RUN" --phase red --out "$TMP/out" --probes "$P" --reps 2 --model opus >/dev/null 2>&1; echo $?)" "2"
has "run: the refused resume keeps the original config" "$(cat "$TMP/out/run-config.json" 2>&1)" '"model": "sonnet"'

cat >"$TMP/bin/claude-err" <<'STUB'
#!/usr/bin/env bash
echo call >>"$STUB_LOG"
echo '{"type":"result","is_error":true,"result":"boom","usage":{"input_tokens":1000}}'
STUB
chmod +x "$TMP/bin/claude-err"
: >"$STUB_LOG"
SC_CLAUDE="$TMP/bin/claude-err" SC_PREFLIGHT="$TMP/bin/pf-ok" bash "$RUN" --phase red --out "$TMP/o4" --probes r2-first-commit --reps 2 --ceiling 500 >/dev/null 2>&1
rc=$?
eq "run: an errored call's spend counts toward the ceiling (exit 3)" "$rc" "3"
eq "run: the ceiling stops after the first errored call" "$(wc -l <"$STUB_LOG" | tr -d ' ')" "1"
eq "run: a sweep that leaves errored runs exits 4" "$(SC_CLAUDE="$TMP/bin/claude-err" SC_PREFLIGHT="$TMP/bin/pf-ok" bash "$RUN" --phase red --out "$TMP/o5" --probes r2-first-commit --reps 2 >/dev/null 2>&1; echo $?)" "4"

cat >"$TMP/bin/claude-mute" <<'STUB'
#!/usr/bin/env bash
echo call >>"$STUB_LOG"
STUB
chmod +x "$TMP/bin/claude-mute"
: >"$STUB_LOG"
SC_CLAUDE="$TMP/bin/claude-mute" SC_PREFLIGHT="$TMP/bin/pf-ok" bash "$RUN" --phase red --out "$TMP/o6" --probes r2-first-commit --reps 2 --ceiling 100000 >/dev/null 2>&1
rc=$?
eq "run: under a ceiling, a call with no usage to bill stops the sweep (exit 3)" "$rc" "3"
eq "run: it stops after that call" "$(wc -l <"$STUB_LOG" | tr -d ' ')" "1"

python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["inputs_sha"]="0"; json.dump(c, open(sys.argv[1],"w"))' "$TMP/part/run-config.json"
before="$(wc -l <"$HIMMEL_EVAL_RUNS_LEDGER" | tr -d ' ')"
eq "ledger: a run under other probe or row text is refused" "$(python3 "$CULL" report --runs "$TMP/part" --sessions "$TMP/sessions" --no-agents --ledger >/dev/null 2>&1; echo $?)" "2"
eq "ledger: the refused run appends no row" "$(wc -l <"$HIMMEL_EVAL_RUNS_LEDGER" | tr -d ' ')" "$before"

: >"$STUB_LOG"
SC_CLAUDE="$TMP/bin/claude" SC_PREFLIGHT="$TMP/bin/pf-ok" bash "$RUN" --phase red --out "$TMP/o3" --probes "$P" --reps 2 --ceiling 1 >/dev/null 2>&1
rc=$?
eq "run: the ceiling stops the sweep (exit 3)" "$rc" "3"
eq "run: the ceiling stops after the first call" "$(wc -l <"$STUB_LOG" | tr -d ' ')" "1"

echo "test-steering-cull: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
