#!/usr/bin/env bash
# scripts/eval/design-review/test-design-review.sh - scorer self-check for the design-review eval.
# It does NOT measure the reviewer: the live run (run.sh, README) is the check of that. It guards the
# failure modes that would make a live result lie:
#   FM1 a Critical/Important finding on the right dimension but about another part of the spec counts as a hit
#   FM2 a Suggestion counts as a hit, or as a false alarm
#   FM3 a dims 1-8 finding on a GOOD spec counts in the dims 9-13 false-alarm rate
#   FM4 a review with no SUMMARY line (failed or cut call) counts as a hit or as a clean GOOD
#   FM5 an answer carrying the key canary does not stop the score (status inconclusive, exit 3)
#   FM6 a hit the GOOD twin also carries still counts as paired
#   FM7 lint passes a fixture that differs from the key, carries a hint word, or is missing
#   FM8 results.jsonl or the eval-runs row lacks what a re-run diff needs (model, effort, cost,
#       charter sha, fixture-set sha, per-case verdicts)
#   FM9 run.sh starts a batch whose worst case is past the $40 cap
# Synthetic set and canned answers only: no model call, no live ledger.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCORE="$HERE/score.py"
RUN="$HERE/run.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/design-review-test.XXXXXX")" || { echo "test-design-review: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export HIMMEL_EVAL_RUNS_LEDGER="$TMP/never.jsonl"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$3', got '$2'"; fi; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP test-design-review: python3 not on PATH"; exit 0; }

# jget <jsonl> <case|summary> <path> - one field of a results.jsonl row.
jget() { python3 -c 'import json,sys
rows=[json.loads(l) for l in open(sys.argv[1])]
r=[x for x in rows if (x["kind"]=="summary" if sys.argv[2]=="summary" else x.get("case")==sys.argv[2])][0]
for k in sys.argv[3].split("/"): r=r.get(k) if isinstance(r,dict) else None
print(json.dumps(r))' "$1" "$2" "$3"; }

# A synthetic set: two GOOD specs, each with one BAD twin.
SET="$TMP/set"
mkdir -p "$SET/fixtures" "$SET/key"
printf '# Spec A\n\n## Sandbox\nfailIfUnavailable: true\n' >"$SET/fixtures/case-01.md"
printf '# Spec A\n\n## Sandbox\nfailIfUnavailable: false\n' >"$SET/fixtures/case-02.md"
printf '# Plan B\n\n## A4\nDone-check: the header looks right on a phone.\n' >"$SET/fixtures/case-03.md"
printf '# Plan B\n\n## A4\nDone-check: scrollWidth <= 390 at viewport 390.\n' >"$SET/fixtures/case-04.md"
python3 -c 'import hashlib,json,sys
d=sys.argv[1]
sha=lambda c: hashlib.sha256(open(d+"/fixtures/"+c+".md","rb").read()).hexdigest()
cases={
 "case-01":{"verdict":"good","class":None,"dims":[],"anchors":[],"twin":None,"split":"open"},
 "case-02":{"verdict":"bad","class":"rollback","dims":[10],"anchors":["failifunavailable"],"twin":"case-01","split":"open"},
 "case-03":{"verdict":"bad","class":"dod","dims":[11,5],"anchors":["looks right"],"twin":"case-04","split":"sealed"},
 "case-04":{"verdict":"good","class":None,"dims":[],"anchors":[],"twin":None,"split":"sealed"}}
for c,v in cases.items(): v.update(sha256=sha(c),parent=False,ticket="HIMMEL-1",as_of="2026-10-01",source="x")
json.dump({"v":1,"canary":"dr-canary-test0000","set_sha256":"f"*64,"cases":cases},open(d+"/key/labels.json","w"))' "$SET"

# answer <out> <case> <body> - a canned review.md plus meta.json.
answer() { mkdir -p "$1/$2"; printf '%b' "$3" >"$1/$2/review.md"; printf '{"rc":0,"cost_usd":0.5,"turns":4}\n' >"$1/$2/meta.json"; }
runjson() { printf '{"run_id":"r1","model":"claude-opus-5-5","effort":"high","charter":"charter.md","charter_sha256":"%s","cap_usd":2}\n' "$(printf a | sha256sum | cut -d' ' -f1)" >"$1/run.json"; }
F() { printf 'FINDING [dr-%s] dim=%s sev=%s cite=[SPEC.md#x]\\n  claim: %s\\n  kind: defect\\n  fix: x\\n' "$1" "$2" "$3" "$4"; }
S='SUMMARY findings=1 crit=0 imp=1 sugg=0 not-checkable=none\n'

eq "lint: the synthetic set is clean" "$(python3 -I "$SCORE" lint --set "$SET" >/dev/null 2>&1; echo $?)" "0"

O="$TMP/o1"
answer "$O" case-01 "$(F 1 2 Important 'scope grows')$S"
answer "$O" case-02 "$(F 1 10 Important 'failIfUnavailable false runs Bash unsandboxed')$S"
answer "$O" case-03 "$(F 1 11 Important 'the RED step for A1 names no failure output')$S"
answer "$O" case-04 "$(F 1 13 Suggestion 'a minor overlap')$S"
runjson "$O"
python3 -I "$SCORE" score --set "$SET" --outputs "$O" --no-ledger >"$TMP/o1.txt" 2>&1; rc=$?
R="$O/results.jsonl"
eq "score: exit 0" "$rc" "0"
eq "hit: right dim and the anchor" "$(jget "$R" case-02 hit)" "true"
eq "FM1: right dim, other part of the spec is a miss" "$(jget "$R" case-03 hit)" "false"
eq "FM1: the dim-only rate still sees it" "$(jget "$R" case-03 hit_dim)" "true"
eq "FM3: a dim-2 Important on GOOD is not a 9-13 false alarm" "$(jget "$R" case-01 false_alarm)" "false"
eq "FM3: but it is a false_alarm_any" "$(jget "$R" case-01 false_alarm_any)" "true"
eq "FM2: a Suggestion on GOOD is no false alarm" "$(jget "$R" case-04 false_alarm_any)" "false"
eq "paired: the twin does not carry the hit" "$(jget "$R" case-02 paired)" "true"
eq "recall over BAD cases" "$(jget "$R" summary metrics/recall)" "0.5"
eq "per-split recall" "$(jget "$R" summary metrics/open.recall)/$(jget "$R" summary metrics/sealed.recall)" "1.0/0.0"
eq "FM8: case rows carry the model" "$(jget "$R" case-02 model)" '"claude-opus-5-5"'
eq "FM8: case rows carry the effort" "$(jget "$R" case-02 effort)" '"high"'
eq "FM8: case rows carry the cost" "$(jget "$R" case-02 cost_usd)" "0.5"
eq "FM8: case rows carry the charter sha" "$(jget "$R" case-02 charter_sha256 | wc -c)" "67"
eq "FM8: case rows carry the fixture sha" "$(jget "$R" case-02 fixture_sha256 | wc -c)" "67"
eq "FM8: the summary carries the set sha" "$(jget "$R" summary set_sha256)" "\"$(printf 'f%.0s' $(seq 64))\""
eq "FM8: the summary sums the cost" "$(jget "$R" summary metrics/cost_usd)" "2.0"

O="$TMP/o2"
answer "$O" case-01 "$(F 1 10 Important 'failIfUnavailable is set but nothing tests it')$S"
answer "$O" case-02 "$(F 1 10 Suggestion 'failIfUnavailable false')$(F 2 10 Important 'failIfUnavailable false fails open')$S"
answer "$O" case-03 "$(F 1 11 Suggestion 'looks right is not a check')$S"
answer "$O" case-04 "$(F 1 11 Important 'no command named')"
runjson "$O"
python3 -I "$SCORE" score --set "$SET" --outputs "$O" --ledger "$TMP/ledger.jsonl" >/dev/null 2>&1; rc=$?
R="$O/results.jsonl"
eq "score with a ledger: exit 0" "$rc" "0"
eq "FM2: a Suggestion with the anchor is no hit" "$(jget "$R" case-03 hit)" "false"
eq "FM6: a hit the twin also carries is not paired" "$(jget "$R" case-02 paired)" "false"
eq "FM6: but it is still a hit" "$(jget "$R" case-02 hit)" "true"
eq "FM4: no SUMMARY line is no-answer" "$(jget "$R" case-04 status)" '"no-answer"'
eq "FM4: a no-answer GOOD is left out of the false-alarm rate" "$(jget "$R" summary metrics/sealed.false_alarm)" "null"
eq "FM4: the run is partial" "$(jget "$R" summary status)" '"partial"'
eq "FM8: one eval-runs row" "$(wc -l <"$TMP/ledger.jsonl" | tr -d ' ')" "1"
eq "FM8: the row is a design-review row with per-case verdicts" "$(python3 -c 'import json,sys; r=json.loads(open(sys.argv[1]).readline()); print(r["eval"], r["cases"]["case-02"]["hit"], r["cases"]["case-01"]["false_alarm"], r["model"])' "$TMP/ledger.jsonl")" "design-review 1 1 claude-opus-5-5"
eq "the live ledger was never touched" "$([ -e "$TMP/never.jsonl" ] && echo touched || echo clean)" "clean"

O="$TMP/o3"
answer "$O" case-02 "$(F 1 10 Important 'saw dr-canary-test0000')$S"
runjson "$O"
python3 -I "$SCORE" score --set "$SET" --outputs "$O" --no-ledger >/dev/null 2>&1; rc=$?
eq "FM5: the canary in an answer exits 3" "$rc" "3"
eq "FM5: and marks the run inconclusive" "$(jget "$O/results.jsonl" summary status)" '"inconclusive"'
eq "a lone BAD case has no twin to pair" "$(jget "$O/results.jsonl" case-02 paired)" "null"

cp -R "$SET" "$TMP/s2"; printf 'changed\n' >>"$TMP/s2/fixtures/case-01.md"
eq "FM7: a fixture that differs from the key fails lint" "$(python3 -I "$SCORE" lint --set "$TMP/s2" >/dev/null 2>&1; echo $?)" "1"
cp -R "$SET" "$TMP/s3"; rm "$TMP/s3/fixtures/case-03.md"
eq "FM7: a missing fixture fails lint" "$(python3 -I "$SCORE" lint --set "$TMP/s3" >/dev/null 2>&1; echo $?)" "1"
cp -R "$SET" "$TMP/s4"; printf '# Spec A\n\nThe planted change.\n' >"$TMP/s4/fixtures/case-02.md"
python3 -c 'import hashlib,json,sys; p=sys.argv[1]; k=json.load(open(p+"/key/labels.json")); k["cases"]["case-02"]["sha256"]=hashlib.sha256(open(p+"/fixtures/case-02.md","rb").read()).hexdigest(); json.dump(k,open(p+"/key/labels.json","w"))' "$TMP/s4"
eq "FM7: a hint word fails lint" "$(python3 -I "$SCORE" lint --set "$TMP/s4" 2>&1 >/dev/null | grep -c 'hint word')" "1"

mkdir -p "$TMP/lk/mirror" "$TMP/lk/memory" "$TMP/lk/specs/decisions" "$TMP/lk/specs/research"
HIMMEL_BILLED_OK=1 bash "$RUN" --set "$SET" --out "$TMP/run1" --cap-usd 30 --canary-only \
    --mirror "$TMP/lk/mirror" --memory "$TMP/lk/memory" --specs "$TMP/lk/specs" >"$TMP/run1.txt" 2>&1; rc=$?
eq "FM9: 4 cases at \$30 refuse before any call" "$rc" "2"
eq "FM9: the refusal names the cap" "$(grep -c 'batch cap' "$TMP/run1.txt")" "1"
eq "FM9: nothing was built" "$([ -e "$TMP/run1" ] && echo built || echo none)" "none"

echo
echo "test-design-review: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
