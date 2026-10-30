#!/usr/bin/env bash
# scripts/eval/compaction-handoff/test-compaction-ab.sh - suite for the phase 2 A/B:
# the three generated tasks and their hidden checks (an untouched workspace fails, a solved one
# passes), and ab.py run / sweep / judge / score driven by a stub claude and a stub bank
# preflight. No model call, no live transcript.
set -u
export HIMMEL_BILLED_OK=1   # stub claude only; ab.py refuses a bare billed run

HERE="$(cd "$(dirname "$0")" && pwd)"
AB="$HERE/ab.py"
TASKS="$HERE/ab_tasks.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/compaction-ab-test.XXXXXX")" || { echo "test-compaction-ab: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) pass "$1";; *) fail "$1: '$3' not in '$2'";; esac; }
hasnt() { case "$2" in *"$3"*) fail "$1: '$3' found";; *) pass "$1";; esac; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP test-compaction-ab: python3 not on PATH"; exit 0; }

export AB_CLAUDE="$HERE/fixtures/stub-claude.py"
export AB_STUB_LOG="$TMP/stub.log"
export AB_STUB_SCALE=0.05
printf '#!/usr/bin/env bash\necho PROCEED\n' >"$TMP/pf-ok.sh"
printf '#!/usr/bin/env bash\necho HOLD\n' >"$TMP/pf-hold.sh"
export AB_PREFLIGHT="$TMP/pf-ok.sh"

jget() { python3 -c 'import json,sys
v=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("/"): v=v[int(k)] if isinstance(v,list) else v.get(k)
print(json.dumps(v) if isinstance(v,(dict,list,bool)) or v is None else v)' "$1" "$2"; }
tree_hash() { (cd "$1" && find . -type f | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -d' ' -f1); }

# --- the tasks: generated, deterministic, checked by a hidden rule ---
for t in docs impl audit; do
    export AB_STUB_TASK=$t
    python3 "$TASKS" gen "$t" "$TMP/g1-$t" --scale 0.05 >/dev/null 2>&1; python3 "$TASKS" gen "$t" "$TMP/g2-$t" --scale 0.05 >/dev/null 2>&1
    eq "$t: the same seed generates the same workspace" "$(tree_hash "$TMP/g1-$t")" "$(tree_hash "$TMP/g2-$t")"
    r0="$(python3 "$TASKS" check "$t" "$TMP/g1-$t" --scale 0.05 2>&1)"
    eq "$t: an untouched workspace does not pass its check" "$([ "$(echo "$r0" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["passed"] < d["total"])' 2>&1)" = True ] && echo fails || echo "$r0")" "fails"
    python3 "$TASKS" solve "$t" "$TMP/g1-$t" --scale 0.05 >/dev/null 2>&1
    r1="$(python3 "$TASKS" check "$t" "$TMP/g1-$t" --scale 0.05 2>&1)"
    eq "$t: the solved workspace passes every check" "$(echo "$r1" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["passed"] == d["total"] and d["total"] > 0)' 2>&1)" "True"
done
python3 "$TASKS" gen docs "$TMP/full-docs" >/dev/null 2>&1
if [ "$(du -sk "$TMP/full-docs" | cut -f1)" -ge 1200 ]; then pass "docs: a full-scale workspace is at least 1.2 MB, enough to pass a 200k window"; else fail "docs: full-scale workspace under 1.2 MB"; fi

# --- ab.py run: one cell, each arm ---
run() { python3 "$AB" run --task "$1" --arm "$2" --rep 1 --out "$3" --scale 0.05 2>&1; }
export AB_STUB_TASK=docs

# a: one message of 100000 context = 1000 x 1.25 + 99000 x 0.1 + 100 x 5 = 11650 cost-eq
O="$TMP/oa"; AB_STUB_MSGS=1 AB_STUB_STEP=100000 run docs a "$O" >/dev/null
S="$O/docs/a/1/summary.json"
eq "run a: cost-eq is the usage priced with the leg-burn weights" "$(jget "$S" cost_eq)" "11650"
eq "run a: a clean run has no error" "$(jget "$S" error)" "false"
eq "run a: the check ran and passed" "$(jget "$S" check/passed)/$(jget "$S" check/total)" "$(jget "$S" check/total)/$(jget "$S" check/total)"
eq "run a: no hand-off" "$(jget "$S" handoffs)" "0"
log="$(cat "$AB_STUB_LOG")"
has "run a: pinned at the 200k ceiling" "$log" '"--autocompact", "200000"'
has "run a: the Agent tool is denied so no child holds context" "$log" 'Agent'
has "run a: the workspace is not a git repo, or the edit-on-main hook refuses every Edit" "$log" '"in_git": false'
: >"$AB_STUB_LOG"

# a with compactions: 60k steps, a compaction past 170k, twice in 8 messages
O="$TMP/oa2"; AB_STUB_MSGS=8 AB_STUB_STEP=60000 run docs a "$O" >/dev/null
eq "run a: counts the compact_boundary events" "$(jget "$O/docs/a/1/summary.json" compactions)" "2"

# c: 450k, compaction only (the compaction past 382.5k)
O="$TMP/oc"; AB_STUB_MSGS=8 AB_STUB_STEP=60000 run docs c "$O" >/dev/null
S="$O/docs/c/1/summary.json"
eq "run c: one compaction in 8 messages" "$(jget "$S" compactions)" "1"
eq "run c: peak context is the 6th message" "$(jget "$S" peak_ctx)" "360000"
eq "run c: no hand-off" "$(jget "$S" handoffs)" "0"
has "run c: pinned at the 450k ceiling" "$(cat "$AB_STUB_LOG")" '"--autocompact", "450000"'
: >"$AB_STUB_LOG"

# b: 450k plus a hand-off at 75 % (337500); the stub hangs past it so the driver must stop it
O="$TMP/ob"; AB_STUB_HANG=1 AB_STUB_MSGS=8 AB_STUB_STEP=60000 timeout 60 python3 "$AB" run --task docs --arm b --rep 1 --out "$O" --scale 0.05 >"$TMP/b.out" 2>&1   # gnu-ok: local-tier suite, hang guard
S="$O/docs/b/1/summary.json"
eq "run b: one hand-off" "$(jget "$S" handoffs)" "1"
eq "run b: no compaction before the hand-off" "$(jget "$S" compactions)" "0"
eq "run b: the successor finished the task" "$(jget "$S" check/passed)/$(jget "$S" check/total)" "$(jget "$S" check/total)/$(jget "$S" check/total)"
eq "run b: three segment streams" "$(find "$O/docs/b/1" -name 'seg[0-9].stream.jsonl' | wc -l | tr -d ' ')" "3"
log="$(cat "$AB_STUB_LOG")"
has "run b: segment 2 resumes the stopped session" "$log" '"--resume"'
has "run b: the successor is told to load the hand-off" "$log" 'Load HANDOFF.md'
succ="$(python3 -c 'import json,sys
for l in open(sys.argv[1]):
    d=json.loads(l); p=d["args"][d["args"].index("-p")+1]
    if p.startswith("Load HANDOFF.md"): print(p)' "$AB_STUB_LOG")"
hasnt "run b: the successor prompt does not repeat the rulings" "$succ" "R1"
: >"$AB_STUB_LOG"

# an unsolved workspace is a quality result, not an error
O="$TMP/ou"; AB_STUB_SKIP_SOLVE=1 AB_STUB_MSGS=8 AB_STUB_STEP=60000 run docs a "$O" >/dev/null
S="$O/docs/a/1/summary.json"
eq "run: an unsolved task scores below full" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["check"]; print(d["passed"] < d["total"])' "$S")" "True"
eq "run: and is not an error" "$(jget "$S" error)" "false"

# a compaction that starts well below the setting is not the real trigger
O="$TMP/ot"; AB_STUB_PRE=100000 AB_STUB_MSGS=8 AB_STUB_STEP=60000 run docs a "$O" >/dev/null
eq "run a: a compaction at 100k of 200k is off-trigger" "$(jget "$O/docs/a/1/summary.json" valid)/$(jget "$O/docs/a/1/summary.json" invalid_reason)" "false/off-trigger"

# --- the billed opt-in ---
eq "run: refuses without HIMMEL_BILLED_OK" "$(env -u HIMMEL_BILLED_OK python3 "$AB" run --task docs --arm a --rep 1 --out "$TMP/ox" --scale 0.05 >/dev/null 2>&1; echo $?)" "2"

# --- validity: a run that never reached its trigger is INVALID, not scored ---
eq "run a: a clean run that compacted is valid" "$(jget "$TMP/oa2/docs/a/1/summary.json" valid)" "true"
eq "run c: valid" "$(jget "$TMP/oc/docs/c/1/summary.json" valid)" "true"
eq "run b: valid (hand-off fired, HANDOFF.md written, successor finished)" "$(jget "$TMP/ob/docs/b/1/summary.json" valid)" "true"
eq "run a: one message never reaches the 200k trigger" "$(jget "$TMP/oa/docs/a/1/summary.json" valid)/$(jget "$TMP/oa/docs/a/1/summary.json" invalid_reason)" "false/no-compaction"
eq "run: an unsolved task that compacted is still a valid run" "$(jget "$TMP/ou/docs/a/1/summary.json" valid)" "true"

# --- sweep: ceiling, preflight, resume ---
O="$TMP/os"
export AB_STUB_MSGS=8 AB_STUB_STEP=60000
python3 "$AB" sweep --out "$O" --tasks docs --arms a,c --reps 1 --ceiling 1 --scales docs=0.05 >"$TMP/sw.out" 2>&1; rc=$?
eq "sweep: stops once spent cost-eq reaches the ceiling" "$rc" "3"
eq "sweep: one cell ran before the ceiling" "$(find "$O" -name summary.json | wc -l | tr -d ' ')" "1"
python3 "$AB" sweep --out "$O" --tasks docs --arms a,c --reps 1 --ceiling 1000000000 --scales docs=0.05 >"$TMP/sw2.out" 2>&1; rc=$?
eq "sweep: a rerun resumes and finishes" "$rc" "0"
eq "sweep: two cells in all, none redone" "$(find "$O" -name summary.json | wc -l | tr -d ' ')" "2"
eq "sweep: a bad --scales is a usage error" "$(python3 "$AB" sweep --out "$TMP/ob2" --tasks docs --scales nope=1 >/dev/null 2>&1; echo $?)" "2"

# an invalid cell is priced, kept, reported and re-run on request
O3="$TMP/oi"
AB_STUB_MSGS=1 AB_STUB_STEP=100000 python3 "$AB" sweep --out "$O3" --tasks docs --arms a --reps 1 --scale 0.05 >/dev/null 2>&1
eq "sweep: a cell that never compacted is recorded invalid" "$(jget "$O3/docs/a/1/summary.json" invalid_reason)" "no-compaction"
python3 "$AB" score --out "$O3" >"$TMP/score3.out" 2>&1
has "score: names the invalid run and does not score it" "$(cat "$TMP/score3.out")" "INVALID docs a rep 1: no-compaction"
python3 "$AB" sweep --out "$O3" --tasks docs --arms a --reps 1 --scale 0.05 >/dev/null 2>&1
eq "sweep: without --rerun-invalid the invalid cell stays" "$(jget "$O3/docs/a/1/summary.json" valid)" "false"
python3 "$AB" sweep --out "$O3" --tasks docs --arms a --reps 1 --scale 0.05 --rerun-invalid >/dev/null 2>&1
eq "sweep --rerun-invalid: the cell is re-run to a valid result" "$(jget "$O3/docs/a/1/summary.json" valid)" "true"
eq "sweep --rerun-invalid: the invalid run is kept for the spend" "$(find "$O3/docs/a" -maxdepth 1 -name '1.invalid-1' | wc -l | tr -d ' ')" "1"
O2="$TMP/os2"
AB_PREFLIGHT="$TMP/pf-hold.sh" python3 "$AB" sweep --out "$O2" --tasks docs --arms a --reps 1 --scale 0.05 >/dev/null 2>&1; rc=$?
eq "sweep: a bank preflight that does not PROCEED stops it" "$rc" "3"
eq "sweep: and runs nothing" "$(find "$O2" -name summary.json 2>/dev/null | wc -l | tr -d ' ')" "0"

# --- judge: blind, one score per run ---
: >"$AB_STUB_LOG"
python3 "$AB" judge --out "$O" >/dev/null 2>&1
eq "judge: a score per run" "$(jget "$O/docs/a/1/judge.json" score)" "8"
eq "judge: both valid runs scored" "$(find "$O" -name judge.json | wc -l | tr -d ' ')" "2"
jp="$(python3 -c 'import json,sys
for l in open(sys.argv[1]):
    d=json.loads(l); print(d["args"][d["args"].index("-p")+1])' "$AB_STUB_LOG")"
hasnt "judge: the prompt does not name the arm or the ceiling" "$jp" "autocompact"
hasnt "judge: nor the hand-off" "$jp" "HANDOFF"
has "judge: it asks for a SCORE" "$jp" "SCORE:"

# --- score: the table and a recommendation per profile ---
python3 "$AB" score --out "$O" >"$TMP/score.out" 2>&1
sc="$(cat "$TMP/score.out")"
has "score: a row per arm" "$sc" "docs"
has "score: columns" "$sc" "cost_eq"
has "score: shows compactions per run" "$sc" "compactions"
has "score: shows hand-offs per run" "$sc" "handoffs"
has "score: shows peak context per run" "$sc" "peak_ctx"
has "score: one recommended default per profile" "$sc" "recommend docs"
has "score: and an empty profile says so" "$sc" "recommend impl: no runs"
eq "score --json: parses" "$(python3 "$AB" score --out "$O" --json 2>/dev/null | python3 -c 'import json,sys; print(sorted(json.load(sys.stdin))[:1])' 2>&1)" "['cells']"

echo "test-compaction-ab: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
