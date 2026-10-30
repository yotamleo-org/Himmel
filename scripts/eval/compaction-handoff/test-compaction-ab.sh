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
tree_hash() { python3 -I -c 'import hashlib, os, sys
h = hashlib.sha256()
for d, _, fs in sorted(os.walk(sys.argv[1])):
    for f in sorted(fs):
        q = os.path.join(d, f)
        h.update(os.path.relpath(q, sys.argv[1]).encode())
        h.update(open(q, "rb").read())
print(h.hexdigest())' "$1"; }
sha() { python3 -I -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"; }
# tmo SECS CMD...: a portable hang guard (stock macOS has no timeout); exit 124 on expiry
tmo() { python3 -I -c 'import subprocess, sys
try:
    sys.exit(subprocess.run(sys.argv[2:], timeout=int(sys.argv[1])).returncode)
except subprocess.TimeoutExpired:
    sys.exit(124)' "$@"; }

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
printf 'tampered\n' >"$TMP/g1-impl/specs/spec_001.txt"
eq "impl: editing a spec fails the check even when every module is right" "$(python3 "$TASKS" check impl "$TMP/g1-impl" --scale 0.05 2>&1 | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["failed"])')" "['specs-config-untouched']"
printf 'raise SystemExit(0)\n' >"$TMP/g1-impl/pkg/mod_001.py"
printf 'while True:\n    pass\n' >"$TMP/g1-impl/pkg/mod_002.py"
eq "impl: a worker module that exits or never returns fails its check, not the driver" "$(tmo 60 python3 "$TASKS" check impl "$TMP/g1-impl" --scale 0.05 2>&1 | python3 -c 'import json,sys; d=json.load(sys.stdin); print("mod-001" in d["failed"] and "mod-002" in d["failed"])' 2>&1)" "True"
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
O="$TMP/ob"; AB_STUB_HANG=1 AB_STUB_MSGS=8 AB_STUB_STEP=60000 tmo 60 python3 "$AB" run --task docs --arm b --rep 1 --out "$O" --scale 0.05 >"$TMP/b.out" 2>&1
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

# run refuses a cell that already holds a priced run: replacing it would drop its spend from the ceiling total
sum_before="$(sha "$TMP/ot/docs/a/1/summary.json")"
eq "run: an existing priced cell is refused" "$(python3 "$AB" run --task docs --arm a --rep 1 --out "$TMP/ot" --scale 0.05 >/dev/null 2>&1; echo $?)" "2"
eq "run: and its summary is left as it was" "$(sha "$TMP/ot/docs/a/1/summary.json")" "$sum_before"

# a context drop with no compact_boundary is not a compaction
O="$TMP/od"; AB_STUB_NOBOUNDARY=1 AB_STUB_MSGS=8 AB_STUB_STEP=60000 run docs a "$O" >/dev/null
eq "run a: a context drop without a compact_boundary is invalid" "$(jget "$O/docs/a/1/summary.json" valid)/$(jget "$O/docs/a/1/summary.json" invalid_reason)" "false/no-compaction"

# arm b: every segment draws on one shared cap, and each segment must itself finish
hb() { AB_STUB_HANG=1 AB_STUB_MSGS=8 AB_STUB_STEP=60000 tmo 60 python3 "$AB" run --task docs --arm b --rep 1 --scale 0.05 "$@" >/dev/null 2>&1; }
: >"$AB_STUB_LOG"
hb --out "$TMP/obc"
caps="$(python3 -c 'import json,sys
print(" ".join(d["args"][d["args"].index("--max-budget-usd")+1] for d in map(json.loads, open(sys.argv[1]))))' "$AB_STUB_LOG")"
cap1="$(echo "$caps" | cut -d' ' -f1)"; cap2="$(echo "$caps" | cut -d' ' -f2)"; cap3="$(echo "$caps" | cut -d' ' -f3)"
eq "run b: the first segment gets the whole cap" "$cap1" "20"
eq "run b: each later segment gets less than the one before, never more than the cap" "$(python3 -I -c 'import sys; a, b, c = map(float, sys.argv[1:4]); print(0 < c < b < a)' "$cap1" "$cap2" "$cap3")" "True"
exp="$(python3 -I -c 'import importlib.util, sys
sp = importlib.util.spec_from_file_location("ab", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
d = sys.argv[2]
c1 = m.summarize_streams([d + "/seg1.stream.jsonl"], 450000)["cost_eq"]
c2 = m.summarize_streams([d + "/seg1.stream.jsonl", d + "/seg2.stream.jsonl"], 450000)["cost_eq"]
print(round(20 - c1 * m.USD_PER_EQ, 2), round(20 - c2 * m.USD_PER_EQ, 2))' "$AB" "$TMP/obc/docs/b/1")"
eq "run b: and each cap is the run cap less what the earlier segments cost" "$cap2 $cap3" "$exp"
hb --out "$TMP/obd" --max-usd 0.5
eq "run b: a spent cap stops the hand-off" "$(jget "$TMP/obd/docs/b/1/summary.json" valid)/$(jget "$TMP/obd/docs/b/1/summary.json" invalid_reason)" "false/budget"
AB_STUB_RESUME_FAIL=1 hb --out "$TMP/obe"
eq "run b: a hand-off segment that errors is invalid" "$(jget "$TMP/obe/docs/b/1/summary.json" valid)/$(jget "$TMP/obe/docs/b/1/summary.json" invalid_reason)" "false/handoff-error"
AB_STUB_STALE=1 AB_STUB_NOWRITE=1 hb --out "$TMP/obf"
eq "run b: a stale HANDOFF.md does not stand in for a written one" "$(jget "$TMP/obf/docs/b/1/summary.json" valid)/$(jget "$TMP/obf/docs/b/1/summary.json" invalid_reason)" "false/handoff-missing"
: >"$AB_STUB_LOG"

# the recommendation is defined when the best check and the best judge score belong to different arms
eq "score: recommend survives a best check and a best judge on different arms" "$(python3 -I -c '
import importlib.util, sys
sp = importlib.util.spec_from_file_location("ab", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
rows = [{"arm": "a", "check": 1.0, "judge": 5, "cost_eq": 3}, {"arm": "b", "check": 0.5, "judge": 9, "cost_eq": 1}]
print(m.recommend(rows)["arm"])' "$AB" 2>&1)" "a"
# an arm no judge scored cannot win; with no judged arm there is no recommendation
eq "score: recommend never lets an unjudged arm win" "$(python3 -I -c '
import importlib.util, sys
sp = importlib.util.spec_from_file_location("ab", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
rows = [{"arm": "a", "check": 0.5, "judge": 9, "cost_eq": 3}, {"arm": "b", "check": 1.0, "judge": None, "cost_eq": 1}]
print(m.recommend(rows)["arm"])' "$AB" 2>&1)" "a"
eq "score: recommend with no judged arm names none" "$(python3 -I -c '
import importlib.util, sys
sp = importlib.util.spec_from_file_location("ab", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
rows = [{"arm": "a", "check": 1.0, "judge": None, "cost_eq": 3}, {"arm": "b", "check": 1.0, "judge": None, "cost_eq": 1}]
print(m.recommend(rows))' "$AB" 2>&1)" "None"

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
eq "sweep: a bad --scales is a usage error" "$(python3 "$AB" sweep --out "$TMP/ob2" --tasks docs --ceiling 1000000000 --scales nope=1 >/dev/null 2>&1; echo $?)" "2"

# an invalid cell is priced, kept, reported and re-run on request
O3="$TMP/oi"
AB_STUB_MSGS=1 AB_STUB_STEP=100000 python3 "$AB" sweep --out "$O3" --tasks docs --arms a --reps 1 --ceiling 1000000000 --scale 0.05 >/dev/null 2>&1
eq "sweep: a cell that never compacted is recorded invalid" "$(jget "$O3/docs/a/1/summary.json" invalid_reason)" "no-compaction"
python3 "$AB" score --out "$O3" >"$TMP/score3.out" 2>&1
has "score: names the invalid run and does not score it" "$(cat "$TMP/score3.out")" "INVALID docs a rep 1: no-compaction"
python3 "$AB" sweep --out "$O3" --tasks docs --arms a --reps 1 --ceiling 1000000000 --scale 0.05 >/dev/null 2>&1
eq "sweep: without --rerun-invalid the invalid cell stays" "$(jget "$O3/docs/a/1/summary.json" valid)" "false"
python3 "$AB" sweep --out "$O3" --tasks docs --arms a --reps 1 --ceiling 1000000000 --scale 0.05 --rerun-invalid >/dev/null 2>&1
eq "sweep --rerun-invalid: the cell is re-run to a valid result" "$(jget "$O3/docs/a/1/summary.json" valid)" "true"
eq "sweep --rerun-invalid: the invalid run is kept for the spend" "$(find "$O3/docs/a" -maxdepth 1 -name '1.invalid-1' | wc -l | tr -d ' ')" "1"
O2="$TMP/os2"
AB_PREFLIGHT="$TMP/pf-hold.sh" python3 "$AB" sweep --out "$O2" --tasks docs --arms a --reps 1 --ceiling 1000000000 --scale 0.05 >/dev/null 2>&1; rc=$?
eq "sweep: a bank preflight that does not PROCEED stops it" "$rc" "3"
eq "sweep: and runs nothing" "$(find "$O2" -name summary.json 2>/dev/null | wc -l | tr -d ' ')" "0"

# --- judge: blind, one score per run ---
: >"$AB_STUB_LOG"
python3 "$AB" judge --out "$O" --ceiling 1 >/dev/null 2>&1; rc=$?
eq "judge: stops at the ceiling before any call" "$rc/$(find "$O" -name judge.json | wc -l | tr -d ' ')/$(wc -l <"$AB_STUB_LOG" | tr -d ' ')" "3/0/0"
AB_PREFLIGHT="$TMP/pf-hold.sh" python3 "$AB" judge --out "$O" --ceiling 1000000000 >/dev/null 2>&1; rc=$?
eq "judge: a bank preflight that does not PROCEED stops it before any call" "$rc/$(find "$O" -name judge.json | wc -l | tr -d ' ')/$(wc -l <"$AB_STUB_LOG" | tr -d ' ')" "3/0/0"
python3 "$AB" judge --out "$O" --ceiling 1000000000 >/dev/null 2>&1
eq "judge: a score per run" "$(jget "$O/docs/a/1/judge.json" score)" "8"
eq "judge: both valid runs scored" "$(find "$O" -name judge.json | wc -l | tr -d ' ')" "2"
jp="$(python3 -c 'import json,sys
for l in open(sys.argv[1]):
    d=json.loads(l); print(d["prompt"])' "$AB_STUB_LOG")"
ja="$(python3 -c 'import json,sys
for l in open(sys.argv[1]):
    print(" ".join(json.loads(l)["args"]))' "$AB_STUB_LOG")"
hasnt "judge: the prompt does not name the arm or the ceiling" "$jp" "autocompact"
hasnt "judge: nor the hand-off" "$jp" "HANDOFF"
has "judge: it asks for a SCORE" "$jp" "SCORE:"
hasnt "judge: the prompt goes on stdin, not in argv (a long diff would pass the per-argument limit)" "$ja" "Rate the work"
AB_STUB_NOSCORE=1 python3 "$AB" judge --out "$O3" --ceiling 1000000000 >/dev/null 2>&1
eq "judge: a reply with no SCORE leaves the run unscored" "$(jget "$O3/docs/a/1/judge.json" score)" "null"
c1="$(jget "$O3/docs/a/1/judge.json" cost_eq)"
eq "judge: and still counts the attempt's cost" "$([ "$c1" -gt 0 ] && echo yes)" "yes"
python3 "$AB" judge --out "$O3" --ceiling 1000000000 >/dev/null 2>&1
eq "judge: the next judge pass retries it" "$(jget "$O3/docs/a/1/judge.json" score)" "8"
eq "judge: and adds to the cost already spent" "$([ "$(jget "$O3/docs/a/1/judge.json" cost_eq)" -gt "$c1" ] && echo yes)" "yes"

# a SCORE counts only as a whole number from 1 to 10 on a clean result; anything else leaves the run unscored for a retry
OJ="$TMP/ojs"; run docs a "$OJ" >/dev/null
for sv in 42 0 8.5 8e-1 error "8
SCORE: 8.5"; do
    jout="$(AB_STUB_SCORE=$sv python3 "$AB" judge --out "$OJ" --ceiling 1000000000 2>&1)"
    has "judge: the attempt for SCORE '$sv' ran and refused it" "$jout" "no usable SCORE"
    eq "judge: SCORE '$sv' leaves the run unscored" "$(jget "$OJ/docs/a/1/judge.json" score)" "null"
done
python3 "$AB" judge --out "$OJ" --ceiling 1000000000 >/dev/null 2>&1
eq "judge: a clean in-range SCORE then scores it" "$(jget "$OJ/docs/a/1/judge.json" score)" "8"

# --- the whole diff reaches the judge; a failing diff is an invalid run ---
OB="$TMP/obig"; : >"$AB_STUB_LOG"
AB_STUB_BIGDIFF=250000 run docs a "$OB" >/dev/null
eq "run: final.diff is not cut at 200000 chars" "$([ "$(jget "$OB/docs/a/1/summary.json" diff_chars)" -gt 200000 ] && echo whole)" "whole"
eq "run: and diff_chars is the size of the file" "$(jget "$OB/docs/a/1/summary.json" diff_chars)" "$(python3 -c 'import sys; print(len(open(sys.argv[1]).read()))' "$OB/docs/a/1/final.diff")"
: >"$AB_STUB_LOG"
python3 "$AB" judge --out "$OB" --ceiling 1000000000 >/dev/null 2>&1
bp="$(python3 -c 'import json,sys
for l in open(sys.argv[1]):
    print(json.loads(l)["prompt"])' "$AB_STUB_LOG")"
has "judge: the end of a long diff reaches the judge" "$bp" "BIGDIFF-END-MARKER"
hasnt "judge: and it is not labelled truncated" "$bp" "truncated"
mkdir "$TMP/badbin"; printf '#!/usr/bin/env bash\nexit 2\n' >"$TMP/badbin/diff"; chmod +x "$TMP/badbin/diff"
PATH="$TMP/badbin:$PATH" run docs a "$TMP/odiff" >/dev/null
eq "run: a diff that fails is an invalid run, not an empty change" "$(jget "$TMP/odiff/docs/a/1/summary.json" valid)/$(jget "$TMP/odiff/docs/a/1/summary.json" invalid_reason)" "false/diff-error"

# --- the run timer stops a stuck session ---
AB_STUB_HANG=1 AB_STUB_MSGS=8 AB_STUB_STEP=60000 tmo 60 python3 "$AB" run --task docs --arm c --rep 1 --scale 0.05 --timeout 3 --out "$TMP/otm" >/dev/null 2>&1
eq "run: a session still going at --timeout is stopped and invalid" "$(jget "$TMP/otm/docs/c/1/summary.json" valid)/$(jget "$TMP/otm/docs/c/1/summary.json" invalid_reason)" "false/timeout"

# a child that stops reading stdin must not hang the driver on a big prompt: the timer starts before the write
eq "run_segment: a stalled stdin write is cut by the timer" "$(AB_STUB_NOREAD=1 tmo 60 python3 -I -c 'import importlib.util, sys
sp = importlib.util.spec_from_file_location("ab", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
r = m.run_segment([sys.argv[2], "-p", "--model", "x"], sys.argv[3], sys.argv[3] + "/s.stream.jsonl", 3, stdin_text="y" * 2000000)
print(r[1])' "$AB" "$HERE/fixtures/stub-claude.py" "$TMP" 2>&1 | tail -1)" "True"

# --- sweep and judge need the billed opt-in and a positive ceiling ---
eq "sweep: refuses without HIMMEL_BILLED_OK" "$(env -u HIMMEL_BILLED_OK python3 "$AB" sweep --out "$TMP/ox2" --ceiling 1000000000 >/dev/null 2>&1; echo $?)" "2"
eq "judge: refuses without HIMMEL_BILLED_OK" "$(env -u HIMMEL_BILLED_OK python3 "$AB" judge --out "$O" --ceiling 1000000000 >/dev/null 2>&1; echo $?)" "2"
eq "sweep: refuses without --ceiling" "$(python3 "$AB" sweep --out "$TMP/ox3" >/dev/null 2>&1; echo $?)" "2"
eq "sweep: refuses --ceiling 0 (no ceiling is not allowed)" "$(python3 "$AB" sweep --out "$TMP/ox3" --ceiling 0 >/dev/null 2>&1; echo $?)" "2"
eq "judge: refuses without --ceiling" "$(python3 "$AB" judge --out "$O" >/dev/null 2>&1; echo $?)" "2"
eq "judge: refuses --ceiling 0" "$(python3 "$AB" judge --out "$O" --ceiling 0 >/dev/null 2>&1; echo $?)" "2"
eq "sweep: and runs nothing" "$(find "$TMP/ox3" 2>/dev/null | wc -l | tr -d ' ')" "0"

# --- --out must be outside the checkout, also through a symlink to it ---
ROOT="$(cd "$HERE/../../.." && pwd -P)"
ln -s "$ROOT" "$TMP/rootlink"
for c in run sweep judge; do
    case $c in
        run) xa=(--task docs --arm a --rep 1 --scale 0.05) ;;
        sweep) xa=(--tasks docs --ceiling 1000000000) ;;
        judge) xa=(--ceiling 1000000000) ;;
    esac
    eq "$c: --out inside the checkout is refused" "$(python3 "$AB" "$c" "${xa[@]}" --out "$ROOT/ab-guard-test" >/dev/null 2>&1; echo $?)" "2"
    eq "$c: and so is the checkout root itself" "$(python3 "$AB" "$c" "${xa[@]}" --out "$ROOT" >/dev/null 2>&1; echo $?)" "2"
    eq "$c: and --out inside the checkout is refused when ab.py runs through a symlink to it" "$(python3 "$TMP/rootlink/scripts/eval/compaction-handoff/ab.py" "$c" "${xa[@]}" --out "$ROOT/ab-guard-test" >/dev/null 2>&1; echo $?)" "2"
done
eq "the guard created nothing in the checkout" "$([ -e "$ROOT/ab-guard-test" ] && echo created || echo clean)" "clean"

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
