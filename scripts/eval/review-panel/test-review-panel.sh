#!/usr/bin/env bash
# scripts/eval/review-panel/test-review-panel.sh - suite for the review-panel
# recall eval: fixture/key integrity, the seed-leak lint, the
# finding parser + matcher on canned critic outputs, the eval-runs row, and
# run.sh driven by a stub panel. No model call, no codex, no live ledger.
set -u
export HIMMEL_BILLED_OK=1   # stub panel only; run.sh refuses a bare run

HERE="$(cd "$(dirname "$0")" && pwd)"
SCORE="$HERE/score.py"
RUN="$HERE/run.sh"
FIX="$HERE/fixtures"
KEY="$HERE/key/seeds.json"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/review-panel-test.XXXXXX")" || { echo "test-review-panel: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
# Never the live ledger, whatever a case forgets to pass.
export HIMMEL_EVAL_RUNS_LEDGER="$TMP/never.jsonl"

PASS=0; FAIL=0
# The integrity, split and sweep rows below drive the 24 synthetic case-* cases through a temp copy of the
# fixtures and the key; the shipped real-* corpus (RL3) has its own rows at the end, since each real case's lint
# applies its diff to its base commit.
FIX_ALL="$FIX"; KEY_ALL="$KEY"
pass() { PASS=$((PASS + 1)); echo "PASS $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) pass "$1";; *) fail "$1: '$3' not in '$2'";; esac; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP test-review-panel: python3 not on PATH"; exit 0; }
mkdir -p "$TMP/syn/fixtures"; cp "$FIX_ALL"/case-*.patch "$TMP/syn/fixtures/"
python3 -c 'import json,sys; k=json.load(open(sys.argv[1])); k["cases"]={c: v for c, v in k["cases"].items() if c.startswith("case-")}; json.dump(k, open(sys.argv[2], "w"))' "$KEY_ALL" "$TMP/syn/seeds.json"
FIX="$TMP/syn/fixtures"; KEY="$TMP/syn/seeds.json"

# metric <scores.json> <name> - one metric from score.py --json output.
metric() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1]))["metrics"].get(sys.argv[2]); print("null" if v is None else (round(v,4) if isinstance(v,float) else v))' "$1" "$2"; }
jget() { python3 -c 'import json,sys
v=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("/"): v=v.get(k) if isinstance(v,dict) else None
print(json.dumps(v) if isinstance(v,(dict,list,bool)) or v is None else v)' "$1" "$2"; }
# case_of <pair> <kind> - the opaque case id the key gives that twin.
case_of() { python3 -c 'import json,sys; k=json.load(open(sys.argv[1]))["cases"]; print([c for c,v in sorted(k.items()) if v["pair"]==sys.argv[2] and v["kind"]==sys.argv[3]][0])' "$KEY" "$1" "$2"; }
seed_line() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["cases"][sys.argv[2]]["defects"][0]["line"])' "$KEY" "$1"; }
seed_file() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["cases"][sys.argv[2]]["defects"][0]["file"])' "$KEY" "$1"; }

# review <out-file> <critic> <severity:file:line:text>... - a canned merged panel block.
review() {
  local out="$1" critic="$2"; shift 2
  python3 - "$out" "$critic" "$@" <<'PY'
import sys
out, critic, items = sys.argv[1], sys.argv[2], sys.argv[3:]
secs = {"crit": [], "imp": [], "sug": []}
for n, it in enumerate(items, 1):
    sev, f, line, text = it.split(":", 3)
    secs[sev].append("- [%s-%d]: %s [%s:%s]" % (critic, n, text, f, line))
with open(out, "w") as fh:
    fh.write("# Critic Panel Review (1/1 critics responded)\n\n")
    for head, k in (("Critical Issues", "crit"), ("Important Issues", "imp"), ("Suggestions", "sug")):
        fh.write("## %s (%d found)\n" % (head, len(secs[k])))
        fh.write("".join(l + "\n" for l in secs[k]))
        fh.write("\n")
PY
}

# --- fixture + key integrity ------------------------------------------------------
eq "fixtures: 24 frozen diffs" "$(find "$FIX" -name 'case-*.patch' | wc -l | tr -d ' ')" "24"
out=$(python3 "$SCORE" lint --fixtures "$FIX" --key "$KEY" 2>&1); rc=$?
eq "lint: the synthetic set is clean" "$rc" "0"
# The corpus-shape rows count the synthetic case-* subset: real-* escapes (RL3) join beside it.
eq "key: 12 seeded and 12 clean synthetic cases" "$(python3 -c 'import json,sys; c=[v for k,v in json.load(open(sys.argv[1]))["cases"].items() if k.startswith("case-")]; print("%d seeded, %d clean" % (sum(v["kind"]=="seeded" for v in c), sum(v["kind"]=="clean" for v in c)))' "$KEY")" "12 seeded, 12 clean"
classes=$(python3 -c 'import json,sys; print(" ".join(sorted({d["class"] for k,v in json.load(open(sys.argv[1]))["cases"].items() if k.startswith("case-") for d in v["defects"]})))' "$KEY")
eq "key: every ticket class is seeded" "$classes" "fail-open logic quoting scope-creep test-cannot-fail toctou"

# --- the seed-leak lint refuses a fixture that names its own seed -----------------
mkdir -p "$TMP/leak/fixtures"
cp "$FIX"/case-*.patch "$TMP/leak/fixtures/"
canary=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["canary"])' "$KEY")
printf '+# %s\n' "$canary" >> "$TMP/leak/fixtures/case-01.patch"
out=$(python3 "$SCORE" lint --fixtures "$TMP/leak/fixtures" --key "$KEY" 2>&1); rc=$?
eq "lint: a fixture carrying the key canary is refused" "$rc" "1"
has "lint: names the leaking fixture" "$out" "case-01"
cp "$FIX/case-01.patch" "$TMP/leak/fixtures/case-01.patch"
printf '+# planted bug: off by one here\n' >> "$TMP/leak/fixtures/case-02.patch"
out=$(python3 "$SCORE" lint --fixtures "$TMP/leak/fixtures" --key "$KEY" 2>&1); rc=$?
eq "lint: a fixture carrying a seed hint word is refused" "$rc" "1"
cp "$FIX/case-02.patch" "$TMP/leak/fixtures/case-02.patch"
printf '+see review-panel/key/seeds.json\n' >> "$TMP/leak/fixtures/case-03.patch"
out=$(python3 "$SCORE" lint --fixtures "$TMP/leak/fixtures" --key "$KEY" 2>&1); rc=$?
eq "lint: a fixture naming the key path is refused" "$rc" "1"
cp "$FIX/case-03.patch" "$TMP/leak/fixtures/case-03.patch"
# A key line that is not an added line of its own diff is a broken key.
python3 -c 'import json,sys; k=json.load(open(sys.argv[1])); c=[c for c,v in sorted(k["cases"].items()) if v["defects"]][0]; k["cases"][c]["defects"][0]["line"]=999; json.dump(k,open(sys.argv[2],"w"))' "$KEY" "$TMP/leak/badkey.json"
out=$(python3 "$SCORE" lint --fixtures "$TMP/leak/fixtures" --key "$TMP/leak/badkey.json" 2>&1); rc=$?
eq "lint: a seed line outside its diff's added lines is refused" "$rc" "1"

# --- delta cases: <id>.patch + <id>.delta.patch + a key entry with "delta": true ----
# RED at base: lint knows no delta case, so a key entry marked delta with no delta patch is accepted.
mkdir -p "$TMP/dl/fixtures"; cp "$FIX"/case-*.patch "$TMP/dl/fixtures/"
python3 -c 'import json,sys; k=json.load(open(sys.argv[1])); k["cases"]["case-01"]["delta"]=True; json.dump(k,open(sys.argv[2],"w"))' "$KEY" "$TMP/dl/nodelta.json"
out=$(python3 "$SCORE" lint --fixtures "$TMP/dl/fixtures" --key "$TMP/dl/nodelta.json" 2>&1); rc=$?
eq "delta lint: a delta case with no delta patch is refused" "$rc" "1"
has "delta lint: names the missing delta patch" "$out" "case-01.delta.patch"
# The shipped delta cases (delta-*), joined to the synthetic set so the split rules see every class in both halves.
FIXD="$TMP/dl/shipped"; KEYD="$TMP/dl/shipped.json"
mkdir -p "$FIXD"; cp "$FIX"/case-*.patch "$FIX_ALL"/delta-*.patch "$FIXD/"
python3 -c 'import json,sys; k=json.load(open(sys.argv[1])); k["cases"]={c: v for c, v in k["cases"].items() if c.startswith(("case-", "delta-"))}; json.dump(k, open(sys.argv[2], "w"))' "$KEY_ALL" "$KEYD"
out=$(python3 "$SCORE" lint --fixtures "$FIXD" --key "$KEYD" 2>&1); rc=$?
eq "delta corpus: the shipped delta cases lint with the synthetic set" "$rc:$out" "0:review-panel lint: 17 seeded, 17 clean, 0 problem(s)"
eq "delta corpus: 10 delta cases, each with a delta patch" \
  "$(python3 -c 'import json,os,sys; k=json.load(open(sys.argv[1]))["cases"]; d=sorted(c for c,v in k.items() if v.get("delta") is True); print(len(d), all(os.path.isfile(os.path.join(sys.argv[2], c + ".delta.patch")) for c in d))' "$KEY_ALL" "$FIX_ALL")" "10 True"
eq "delta corpus: 5 seeded and 5 clean, an open and a sealed half" \
  "$(python3 -c 'import json,sys
k=[v for v in json.load(open(sys.argv[1]))["cases"].values() if v.get("delta") is True]
print("seeded=%d clean=%d halves=%s" % (sum(v["kind"]=="seeded" for v in k), sum(v["kind"]=="clean" for v in k), "+".join(sorted({v["split"] for v in k}))))' "$KEY_ALL")" "seeded=5 clean=5 halves=open+sealed"
# Refusals: each mutation of a valid delta case breaks lint, and lint names it.
dl_lint() { python3 "$SCORE" lint --fixtures "$FIXD" --key "${1:-$KEYD}" 2>&1; }
cp "$FIXD/delta-01.delta.patch" "$FIXD/case-05.delta.patch"
out=$(dl_lint); rc=$?
eq "delta lint: a delta patch of a case the key does not mark delta is refused" "$rc" "1"
has "delta lint: names the orphan delta patch" "$out" "case-05.delta.patch"
rm -f "$FIXD/case-05.delta.patch"
python3 -c 'import json,sys; k=json.load(open(sys.argv[1])); k["cases"]["delta-07"]["defects"][0]["line"]=1; json.dump(k,open(sys.argv[2],"w"))' "$KEYD" "$TMP/dl/line1.json"
out=$(dl_lint "$TMP/dl/line1.json"); rc=$?
eq "delta lint: a seed line that is not an added line of the delta is refused" "$rc" "1"
cp "$FIXD/delta-07.delta.patch" "$TMP/dl/d07.keep"
cp "$FIXD/delta-04.delta.patch" "$FIXD/delta-07.delta.patch"
out=$(dl_lint); rc=$?
eq "delta lint: a delta that does not apply on its round-1 diff is refused" "$rc" "1"
has "delta lint: says so" "$out" "does not apply on the round-1 diff"
cp "$TMP/dl/d07.keep" "$FIXD/delta-07.delta.patch"
# A patch naming a path outside its scratch tree is refused, and nothing is written there.
probe="review-panel-escape-probe.$$"; rm -f "${TMPDIR:-/tmp}/$probe"
cp "$FIXD/delta-07.patch" "$TMP/dl/r07.keep"
printf 'diff --git a/../../%s b/../../%s\nnew file mode 100644\n--- /dev/null\n+++ b/../../%s\n@@ -0,0 +1 @@\n+x\n' "$probe" "$probe" "$probe" >> "$FIXD/delta-07.patch"
out=$(dl_lint); rc=$?
eq "delta lint: a patch path that leaves the scratch tree is refused" "$rc" "1"
eq "delta lint: and nothing is written outside the tree" "$([ -e "${TMPDIR:-/tmp}/$probe" ] && echo written || echo none)" "none"
rm -f "${TMPDIR:-/tmp}/$probe"; cp "$TMP/dl/r07.keep" "$FIXD/delta-07.patch"
printf '+# planted bug: off by one here\n' >> "$FIXD/delta-07.delta.patch"
out=$(dl_lint); rc=$?
eq "delta lint: a delta patch carrying a hint word is refused" "$rc" "1"
has "delta lint: names the delta patch" "$out" "delta-07.delta"
cp "$TMP/dl/d07.keep" "$FIXD/delta-07.delta.patch"
printf '+# %s\n' "$canary" >> "$FIXD/delta-07.delta.patch"
out=$(dl_lint); rc=$?
eq "delta lint: a delta patch carrying the key canary is refused" "$rc" "1"
cp "$TMP/dl/d07.keep" "$FIXD/delta-07.delta.patch"
eq "delta lint: restored, the set lints again" "$(dl_lint >/dev/null; echo $?)" "0"

# --- matcher on canned outputs --------------------------------------------------
LA=$(case_of logic-a seeded); LAc=$(case_of logic-a clean)
QA=$(case_of quoting-a seeded); QAc=$(case_of quoting-a clean)
TA=$(case_of toctou-a seeded)
la_line=$(seed_line "$LA"); la_file=$(seed_file "$LA")
qa_line=$(seed_line "$QA"); qa_file=$(seed_file "$QA")
ta_line=$(seed_line "$TA"); ta_file=$(seed_file "$TA")
O="$TMP/out1"; mkdir -p "$O"
# logic-a: hit at the exact line, Important, logic words.
review "$O/$LA.md" codex "imp:$la_file:$la_line:off-by-one: tail -n +keep keeps one fewer archive than asked"
# quoting-a: right place, wrong class (a style remark) - a location hit, not a class hit.
review "$O/$QA.md" codex "sug:$qa_file:$qa_line:prefer long option names for readability"
# toctou-a: a Suggestion 3 lines off (inside the window) plus an unrelated finding.
review "$O/$TA.md" codex "sug:$ta_file:$((ta_line + 3)):race between the existence check and the write; use mkdir for an atomic lock" "imp:$ta_file:1:shebang should be sh"
# clean twin of logic-a: one Important false positive; clean twin of quoting-a: none.
review "$O/$LAc.md" codex "imp:$la_file:3:retention default of 5 is undocumented"
review "$O/$QAc.md" codex
python3 "$SCORE" score --outputs "$O" --fixtures "$FIX" --key "$KEY" --critics codex --only "$LA,$QA,$TA,$LAc,$QAc" --no-ledger --json "$TMP/s1.json" >"$TMP/s1.txt" 2>&1; rc=$?
eq "score: exit 0" "$rc" "0"
eq "score: defects counted on the scored subset" "$(metric "$TMP/s1.json" defects)" "3"
eq "score: recall = location AND class hits" "$(metric "$TMP/s1.json" codex.recall)" "0.6667"
eq "score: recall_loc also counts a right-place wrong-class hit" "$(metric "$TMP/s1.json" codex.recall_loc)" "1.0"
eq "score: recall_gating counts only Critical/Important hits" "$(metric "$TMP/s1.json" codex.recall_gating)" "0.3333"
eq "score: precision = matching findings / all findings" "$(metric "$TMP/s1.json" codex.precision)" "0.4"
eq "score: fp_rate = clean twins with a gating finding" "$(metric "$TMP/s1.json" codex.fp_rate)" "0.5"
eq "score: per-class recall" "$(metric "$TMP/s1.json" codex.class.toctou.recall)" "1.0"
eq "score: per-class recall for a missed class" "$(metric "$TMP/s1.json" codex.class.quoting.recall)" "0.0"
eq "score: panel union equals the lone critic" "$(metric "$TMP/s1.json" panel.recall)" "0.6667"
eq "score: nothing leaked" "$(metric "$TMP/s1.json" leaked)" "0"
has "score: a Wilson interval on recall" "$(jget "$TMP/s1.json" ci/codex.recall)" '"lo"'
has "score: the table names n" "$(cat "$TMP/s1.txt")" "n="

# --- the open/sealed split: tuning reads the open half, the sealed half only grades -------
eq "split: 12 open and 12 sealed cases" "$(python3 -c 'import json,sys; c=[v for k,v in json.load(open(sys.argv[1]))["cases"].items() if k.startswith("case-")]; print("open=%d sealed=%d" % (sum(v.get("split")=="open" for v in c), sum(v.get("split")=="sealed" for v in c)))' "$KEY")" "open=12 sealed=12"
eq "split: the key records the seed it was drawn with" "$(jget "$KEY" split/seed)" "7519"
# setsplit <in> <out> <pair=split>... - a copy of the key with those pairs' splits set.
setsplit() { python3 -c 'import json,sys
k=json.load(open(sys.argv[1])); want=dict(a.split("=") for a in sys.argv[3:])
for v in k["cases"].values():
    if v["pair"] in want: v["split"]=want[v["pair"]]
json.dump(k,open(sys.argv[2],"w"))' "$@"; }
setsplit "$KEY" "$TMP/split.json" logic-a=open quoting-a=sealed toctou-a=sealed
python3 "$SCORE" score --outputs "$O" --fixtures "$FIX" --key "$TMP/split.json" --critics codex --only "$LA,$QA,$TA,$LAc,$QAc" --no-ledger --json "$TMP/s1s.json" >/dev/null 2>&1
eq "split: open-half recall scores the open cases only" "$(metric "$TMP/s1s.json" open.codex.recall)" "1.0"
eq "split: sealed-half recall scores the sealed cases only" "$(metric "$TMP/s1s.json" sealed.codex.recall)" "0.5"
eq "split: open-half fp_rate" "$(metric "$TMP/s1s.json" open.codex.fp_rate)" "1.0"
eq "split: sealed-half fp_rate" "$(metric "$TMP/s1s.json" sealed.codex.fp_rate)" "0.0"
eq "split: the whole-set recall is unchanged" "$(metric "$TMP/s1s.json" codex.recall)" "0.6667"
has "split: each half carries its own interval" "$(jget "$TMP/s1s.json" ci/sealed.codex.recall)" '"lo"'
python3 -c 'import json,sys; k=json.load(open(sys.argv[1])); c=sorted(k["cases"])[0]; v=k["cases"][c]; v["split"]="open" if v["split"]=="sealed" else "sealed"; json.dump(k,open(sys.argv[2],"w"))' "$KEY" "$TMP/split-twins.json"
out=$(python3 "$SCORE" lint --fixtures "$FIX" --key "$TMP/split-twins.json" 2>&1); rc=$?
eq "split lint: twins in different halves are refused" "$rc" "1"
has "split lint: names the pair" "$out" "split"
setsplit "$KEY" "$TMP/split-class.json" logic-a=open logic-b=open
out=$(python3 "$SCORE" lint --fixtures "$FIX" --key "$TMP/split-class.json" 2>&1); rc=$?
eq "split lint: a class with no sealed pair is refused" "$rc" "1"
has "split lint: names the class" "$out" "logic"

# Window edge: 4 lines off misses, 3 lines off hits (default window 3).
O2="$TMP/out2"; mkdir -p "$O2"
review "$O2/$LA.md" codex "imp:$la_file:$((la_line + 4)):off-by-one in the retention count"
python3 "$SCORE" score --outputs "$O2" --fixtures "$FIX" --key "$KEY" --critics codex --only "$LA" --no-ledger --json "$TMP/s2.json" >/dev/null 2>&1
eq "window: 4 lines off is a miss" "$(metric "$TMP/s2.json" codex.recall_loc)" "0.0"
review "$O2/$LA.md" codex "imp:$la_file:$((la_line - 3)):off-by-one in the retention count"
python3 "$SCORE" score --outputs "$O2" --fixtures "$FIX" --key "$KEY" --critics codex --only "$LA" --no-ledger --json "$TMP/s2.json" >/dev/null 2>&1
eq "window: 3 lines off is a hit" "$(metric "$TMP/s2.json" codex.recall)" "1.0"
# A different file at the right line is a miss.
review "$O2/$LA.md" codex "imp:scripts/other.sh:$la_line:off-by-one in the retention count"
python3 "$SCORE" score --outputs "$O2" --fixtures "$FIX" --key "$KEY" --critics codex --only "$LA" --no-ledger --json "$TMP/s2.json" >/dev/null 2>&1
eq "match: the wrong file is a miss" "$(metric "$TMP/s2.json" codex.recall_loc)" "0.0"

# Two critics: per-critic attribution by the finding id's slug; the panel is their union.
O3="$TMP/out3"; mkdir -p "$O3"
cat > "$O3/$LA.md" <<EOF
# Critic Panel Review (2/2 critics responded)

## Critical Issues (1 found)
- [glm-1]: tail -n +keep deletes one archive too many (off by one) [$la_file:$la_line]

## Important Issues (0 found)

## Suggestions (1 found)
- [codex-2]: consider logging the count [$la_file:2]
EOF
cat > "$O3/$QA.md" <<EOF
# Critic Panel Review (1/2 critics responded)

## Note: 1 of 2 critics did not respond (review proceeds on the rest)

- glm: unavailable reason=timeout

## Critical Issues (1 found)
- [codex-1]: unquoted \$cache_dir is word-split; a space in the workspace path deletes the wrong tree [$qa_file:$qa_line]

## Important Issues (0 found)

## Suggestions (0 found)
EOF
python3 "$SCORE" score --outputs "$O3" --fixtures "$FIX" --key "$KEY" --critics codex,glm --only "$LA,$QA" --no-ledger --json "$TMP/s3.json" >/dev/null 2>&1
eq "multi: codex found quoting only" "$(metric "$TMP/s3.json" codex.recall)" "0.5"
eq "multi: glm's unavailable case leaves its denominator" "$(metric "$TMP/s3.json" glm.recall)" "1.0"
eq "multi: glm scored on 1 seeded case" "$(metric "$TMP/s3.json" glm.seeded_scored)" "1"
eq "multi: the panel union found both" "$(metric "$TMP/s3.json" panel.recall)" "1.0"
eq "responded: a critic named unavailable by the stdout bullet only did not answer that case" "$(jget "$TMP/s3.json" responded/critics/glm)" "1"
# A real skipped case: header 1/2 and no unavailable bullet (the panel drops it on most skips); only stderr names the critic.
O3B="$TMP/out3b"; mkdir -p "$O3B"
cp "$O3/$LA.md" "$O3B/$LA.md"
cat > "$O3B/$QA.md" <<EOF
# Critic Panel Review (1/2 critics responded)

## Note: 1 of 2 critics did not respond (review proceeds on the rest)


## Critical Issues (1 found)
- [codex-1]: unquoted \$cache_dir is word-split; a space in the workspace path deletes the wrong tree [$qa_file:$qa_line]

## Important Issues (0 found)

## Suggestions (0 found)
EOF
printf 'panel-availability: codex ok responding-model(gpt-6.1-sol)\npanel-availability: glm unavailable (rc=5) reason=critic-skipped: api lane is OFF\n' > "$O3B/$QA.err"
python3 "$SCORE" score --outputs "$O3B" --fixtures "$FIX" --key "$KEY" --critics codex,glm --only "$LA,$QA" --no-ledger --json "$TMP/s3b.json" >/dev/null 2>&1
eq "responded: a critic named unavailable only on stderr did not answer that case" "$(jget "$TMP/s3b.json" responded/critics/glm)" "1"
eq "responded: the critic that answered both cases is counted on both" "$(jget "$TMP/s3b.json" responded/critics/codex)" "2"
eq "responded: scored counts the cases scored" "$(jget "$TMP/s3b.json" responded/scored)" "2"
# The roster is required: a responding critic with zero findings stays in the
# metrics only because the roster names it.
python3 "$SCORE" score --outputs "$O3" --fixtures "$FIX" --key "$KEY" --only "$LA,$QA" --no-ledger >/dev/null 2>&1; rc=$?
eq "roster: score without --critics is refused" "$rc" "2"
python3 "$SCORE" score --outputs "$O3" --fixtures "$FIX" --key "$KEY" --critics codex,glm,kimi --only "$LA,$QA" --no-ledger --json "$TMP/s3r.json" >/dev/null 2>&1
eq "header_total_differs_from_roster: a rostered critic the headers leave out is no phantom answer" "$(metric "$TMP/s3r.json" kimi.recall):$(jget "$TMP/s3r.json" responded/critics/kimi)" "null:0"

# --- participation: one case_participation record owns every per-critic denominator -----------
# pmd <out> <N/M> <note bullets ;-separated | -> [critic:sev:file:line:text]... - a merged panel block with that header.
pmd() {
  python3 - "$@" <<'PY'
import sys
out, header, notes, items = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
secs = {"crit": [], "imp": [], "sug": []}
for n, it in enumerate(items, 1):
    critic, sev, f, line, text = it.split(":", 4)
    secs[sev].append("- [%s-%d]: %s [%s:%s]" % (critic, n, text, f, line))
got, total = header.split("/")
with open(out, "w") as fh:
    fh.write("# Critic Panel Review (%s/%s critics responded)\n\n" % (got, total))
    if notes != "-":
        fh.write("## Note: %d of %s critics did not respond (review proceeds on the rest)\n\n" % (int(total) - int(got), total))
        fh.write("".join(b + "\n" for b in notes.split(";")) + "\n")
    for head, k in (("Critical Issues", "crit"), ("Important Issues", "imp"), ("Suggestions", "sug")):
        fh.write("## %s (%d found)\n" % (head, len(secs[k])))
        fh.write("".join(l + "\n" for l in secs[k]))
        fh.write("\n")
PY
}
# pscore <dir> <critics> <ids> <json> - score that dir; cev <json> <case> <critic> <field> - one participation field.
pscore() { python3 "$SCORE" score --outputs "$1" --fixtures "$FIX" --key "$KEY" --critics "$2" --only "$3" --no-ledger --json "$4" >"$4.txt" 2>&1; }
cev() { jget "$1" "case_evidence/$2/critics/$3/$4"; }
cevs() { local j="$1" c="$2" w="$3"; printf '%s:%s:%s:%s' "$(cev "$j" "$c" "$w" state)" "$(cev "$j" "$c" "$w" category)" "$(cev "$j" "$c" "$w" effective)" "$(cev "$j" "$c" "$w" header_included)"; }
PD="$TMP/part"; hit="off-by-one: keeps one fewer archive than asked"
p_ok() { printf 'panel-availability: %s ok responding-model(%s)\n' "$1" "$2"; }
mkdir -p "$PD/s1"; pmd "$PD/s1/$LA.md" 1/2 - "claude:imp:$la_file:$la_line:$hit"
{ p_ok claude claude-opus-5-5; printf 'panel-availability: codex unavailable (timeout 240s) reason=timeout\n'; } > "$PD/s1/$LA.err"
pscore "$PD/s1" codex,claude "$LA" "$TMP/p1.json"
eq "stderr_only_unavailable: the critic named unavailable only on stderr answered no case" "$(jget "$TMP/p1.json" responded/critics/codex)" "0"
eq "stderr_only_unavailable: and holds no seeded denominator" "$(metric "$TMP/p1.json" codex.seeded_scored)" "0"
eq "stderr_only_unavailable: its recall is null, not 0" "$(metric "$TMP/p1.json" codex.recall)" "null"
eq "stderr_only_unavailable: it is an effective, header-counted failure" "$(cevs "$TMP/p1.json" "$LA" codex)" "unavailable:failure:true:true"
eq "stderr_only_unavailable: the critic that answered is scored" "$(metric "$TMP/p1.json" claude.recall)" "1.0"
mkdir -p "$PD/s2"; pmd "$PD/s2/$LA.md" 1/2 -
pscore "$PD/s2" codex,claude "$LA" "$TMP/p2.json"
eq "missing_identity_partial_header: a 1/2 header with nothing naming who answered leaves both unknown" "$(cev "$TMP/p2.json" "$LA" codex state):$(cev "$TMP/p2.json" "$LA" claude state)" "unknown:unknown"
eq "missing_identity_partial_header: no individual denominator" "$(metric "$TMP/p2.json" codex.seeded_scored):$(metric "$TMP/p2.json" claude.seeded_scored)" "0:0"
eq "missing_identity_partial_header: the panel still scores the case" "$(metric "$TMP/p2.json" panel.seeded_scored)" "1"
mkdir -p "$PD/s3"; pmd "$PD/s3/$LA.md" 1/2 - "codex:imp:$la_file:$la_line:$hit"
printf 'panel-availability: codex unavailable (timeout 240s) reason=timeout\n' > "$PD/s3/$LA.err"
pscore "$PD/s3" codex,claude "$LA" "$TMP/p3.json"
eq "contradictory_participation: a finding plus an unavailable receipt is unknown/inconsistent" "$(cev "$TMP/p3.json" "$LA" codex state):$(cev "$TMP/p3.json" "$LA" codex category)" "unknown:inconsistent"
eq "contradictory_participation: it holds no denominator" "$(metric "$TMP/p3.json" codex.seeded_scored)" "0"
eq "contradictory_participation: the result is decision-ineligible, naming why" "$(jget "$TMP/p3.json" decision_eligible):$(jget "$TMP/p3.json" ineligibility_reasons | grep -c participation-inconsistent)" "false:1"
mkdir -p "$PD/s4"; pmd "$PD/s4/$LA.md" 2/2 -; pmd "$PD/s4/$LAc.md" 2/2 -
pscore "$PD/s4" codex,claude "$LA,$LAc" "$TMP/p4.json"
eq "all_responded_zero_findings: a reconciled 2/2 empty review is two answers" "$(cev "$TMP/p4.json" "$LA" codex state):$(cev "$TMP/p4.json" "$LAc" claude state)" "answered:answered"
eq "all_responded_zero_findings: seeded recall 0 and clean blocks 0" "$(metric "$TMP/p4.json" codex.recall):$(metric "$TMP/p4.json" claude.fp_rate)" "0.0:0.0"
eq "all_responded_zero_findings: both answered both cases" "$(jget "$TMP/p4.json" responded/critics)" '{"claude": 2, "codex": 2}'
mkdir -p "$PD/s5"; pmd "$PD/s5/$LA.md" 1/1 - "glm:imp:$la_file:$la_line:$hit"
pscore "$PD/s5" codex "$LA" "$TMP/p5.json"
eq "non_rostered_slug: no invented participant" "$(jget "$TMP/p5.json" critics):$(metric "$TMP/p5.json" glm.recall)" '["codex"]:null'
eq "non_rostered_slug: no successful completion" "$(metric "$TMP/p5.json" unscored)" "1"
printf '# Critic Panel Review (1/1 critics responded)\n\n## Critical Issues (0 found)\n\n## Important Issues (1 found)\n- [codex-1]: off-by-one with no citation\n\n## Suggestions (0 found)\n' > "$PD/s5/$LA.md"
pscore "$PD/s5" codex "$LA" "$TMP/p5m.json"
eq "malformed_review: unscored, and the critic is no answer" "$(metric "$TMP/p5m.json" unscored):$(cev "$TMP/p5m.json" "$LA" codex state)" "1:unknown"
mkdir -p "$PD/s6"; pmd "$PD/s6/$LA.md" 1/2 - "codex:imp:$la_file:$la_line:$hit"
{ p_ok codex gpt-6.1-sol; printf 'panel-availability: claude unavailable (rc=5) reason=critic-skipped: api lane is OFF\n'; } > "$PD/s6/$LA.err"
pscore "$PD/s6" codex,claude "$LA" "$TMP/p6.json"
eq "protocol_skip_not_failure: critic-skipped is a protocol skip that keeps its header slot" "$(cevs "$TMP/p6.json" "$LA" claude)" "unavailable:protocol-skip:false:true"
eq "protocol_skip_not_failure: outside the failure count" "$(jget "$TMP/p6.json" coverage/critics/claude/protocol-skip):$(jget "$TMP/p6.json" coverage/critics/claude/failure)" "1:0"
{ p_ok codex gpt-6.1-sol; printf 'panel-availability: claude unavailable (timeout 240s) reason=timeout\n'; } > "$PD/s6/$LA.err"
pscore "$PD/s6" codex,claude "$LA" "$TMP/p6t.json"
eq "protocol_skip_not_failure: a timeout stays an effective failure" "$(cevs "$TMP/p6t.json" "$LA" claude):$(jget "$TMP/p6t.json" coverage/critics/claude/failure)" "unavailable:failure:true:true:1"
mkdir -p "$PD/s7"; pmd "$PD/s7/$LA.md" 1/1 - "codex:imp:$la_file:$la_line:$hit"
pscore "$PD/s7" codex,claude "$LA" "$TMP/p7.json"
eq "header_total_differs_from_roster: a roster member outside a 1/1 header is unknown, never a phantom answer" "$(cev "$TMP/p7.json" "$LA" claude state):$(jget "$TMP/p7.json" responded/critics/claude)" "unknown:0"
mkdir -p "$PD/s8"; pmd "$PD/s8/$LA.md" 1/2 -
printf 'panel-availability: claude unavailable (rc=5) reason=critic-skipped: api lane is OFF\n' > "$PD/s8/$LA.err"
pscore "$PD/s8" codex,claude "$LA" "$TMP/p8.json"
eq "protocol_skip_header_retains_slot: 1/2 with the other critic skipped reconciles to a zero-finding answer" "$(cev "$TMP/p8.json" "$LA" codex state):$(cev "$TMP/p8.json" "$LA" claude header_included)" "answered:true"
eq "responding_model_from_receipt: no receipt leaves the model null" "$(cev "$TMP/p8.json" "$LA" codex responding_model)" "null"
pmd "$PD/s8/$LA.md" 1/1 -
printf 'panel-availability: claude unavailable (tier=api not in filter(paid)) reason=tier-excluded\n' > "$PD/s8/$LA.err"
pscore "$PD/s8" codex,claude "$LA" "$TMP/p8t.json"
eq "tier_excluded_header_omits_slot: 1/1 with the other critic tier-excluded reconciles" "$(cev "$TMP/p8t.json" "$LA" codex state):$(cevs "$TMP/p8t.json" "$LA" claude)" "answered:unavailable:protocol-skip:false:false"
mkdir -p "$PD/s9"; pmd "$PD/s9/$LA.md" 1/2 - "claude:imp:$la_file:$la_line:$hit"
pscore "$PD/s9" codex,claude "$LA" "$TMP/p9.json"
eq "elimination_is_unknown: a 1/2 header with only Claude findings leaves Codex unknown, no failure reason inferred" "$(cev "$TMP/p9.json" "$LA" codex state):$(cev "$TMP/p9.json" "$LA" codex category)" "unknown:unknown"
mkdir -p "$PD/s10"; pmd "$PD/s10/$LA.md" 1/1 -
{ p_ok codex gpt-6.1-sol; printf 'panel-availability: claude unavailable (panel-deadline) reason=panel-deadline\n'; } > "$PD/s10/$LA.err"
pscore "$PD/s10" codex,claude "$LA" "$TMP/p10.json"
eq "panel_deadline_header_omits_slot: a pre-launch deadline is an effective failure outside the header" "$(cevs "$TMP/p10.json" "$LA" claude):$(cev "$TMP/p10.json" "$LA" codex state)" "unavailable:failure:true:false:answered"
pmd "$PD/s10/$LA.md" 1/2 -
{ p_ok codex gpt-6.1-sol; printf 'panel-availability: claude fallback-chain stopped — total panel deadline reached reason=panel-deadline\npanel-availability: claude unavailable (rc=1) reason=quota-5h detail=fallback-chain exhausted\n'; } > "$PD/s10/$LA.err"
pscore "$PD/s10" codex,claude "$LA" "$TMP/p10f.json"
eq "panel_deadline_header_omits_slot: a deadline inside a counted fallback chain keeps its slot" "$(cevs "$TMP/p10f.json" "$LA" claude)" "unavailable:failure:true:true"
mkdir -p "$PD/s11"; pmd "$PD/s11/$LA.md" 2/2 -
{ p_ok codex gpt-6.1-sol; printf 'panel-availability: claude fallback(claude-sonnet-5-5)\n'; } > "$PD/s11/$LA.err"
pscore "$PD/s11" codex,claude "$LA" "$TMP/p11.json"
eq "responding_model_from_receipt: ok and fallback receipts name the responding model" "$(cev "$TMP/p11.json" "$LA" codex responding_model):$(cev "$TMP/p11.json" "$LA" claude responding_model)" "gpt-6.1-sol:claude-sonnet-5-5"
# A zero-finding critic the header does count is scored, not dropped.
mkdir -p "$PD/s12"; pmd "$PD/s12/$LA.md" 3/3 - "glm:crit:$la_file:$la_line:$hit" "codex:sug:$la_file:2:consider logging the count"
pscore "$PD/s12" codex,glm,kimi "$LA" "$TMP/p12.json"
eq "roster: a zero-finding critic a reconciled header counts is scored, not dropped" "$(metric "$TMP/p12.json" kimi.recall)" "0.0"
# Honest names: the old keys keep their formula and gain explicit diagnostic aliases; the report says what they are.
eq "proxy_names: each diagnostic alias equals its legacy key" "$(python3 -c 'import json,sys
m = json.load(open(sys.argv[1]))["metrics"]
pairs = {"key_match_recall": "recall", "key_match_recall_gating": "recall_gating", "location_match_recall": "recall_loc",
         "key_match_precision": "precision", "labelled_clean_block_rate": "fp_rate"}
print(all(("codex." + new) in m and m["codex." + new] == m["codex." + old] and m["panel." + new] == m["panel." + old]
          for new, old in pairs.items()))' "$TMP/s1.json" 2>&1)" "True"
has "proxy_names: the report says key match" "$(cat "$TMP/s1.txt")" "key-match"
has "proxy_names: the report says labelled-clean blocking" "$(cat "$TMP/s1.txt")" "labelled-clean blocking"
case "$(cat "$TMP/s1.txt")" in *"was right"*) fail "proxy_names: never 'was right'";; *) pass "proxy_names: never 'was right'";; esac

# Unscored fixtures: a missing output and a REVIEW NOT PERFORMED block.
O4="$TMP/out4"; mkdir -p "$O4"
printf '# Critic Panel Review (0/1 critics responded)\n\n## REVIEW NOT PERFORMED (0 of 1 critics responded)\n' > "$O4/$LA.md"
python3 "$SCORE" score --outputs "$O4" --fixtures "$FIX" --key "$KEY" --critics codex --only "$LA,$QA" --no-ledger --json "$TMP/s4.json" >/dev/null 2>&1; rc=$?
eq "unscored: exit 0 still" "$rc" "0"
eq "unscored: both counted" "$(metric "$TMP/s4.json" unscored)" "2"
eq "unscored: recall is null, not 0" "$(metric "$TMP/s4.json" codex.recall)" "null"
eq "unscored: status inconclusive" "$(jget "$TMP/s4.json" status)" "inconclusive"
# A transcript cut short (a missing severity heading) or a nonzero panel exit is
# not a zero-finding review.
O4b="$TMP/out4b"; mkdir -p "$O4b"
printf '# Critic Panel Review (1/1 critics responded)\n\n## Critical Issues (0 found)\n\n' > "$O4b/$LA.md"
review "$O4b/$QA.md" codex
echo 1 > "$O4b/$QA.rc"
python3 "$SCORE" score --outputs "$O4b" --fixtures "$FIX" --key "$KEY" --critics codex --only "$LA,$QA" --no-ledger --json "$TMP/s4b.json" >/dev/null 2>&1
eq "unscored: a truncated transcript and a nonzero rc are both unscored" "$(metric "$TMP/s4b.json" unscored)" "2"
printf '# Critic Panel Review (1/1 critics responded)\n\n## Critical Issues (0 found)\n\n## Important Issues (0 found)\n\n## Suggestions (2 found)\n- [codex-1]: off-by-one [%s:%s]\n' "$la_file" "$la_line" > "$O4b/$LA.md"
python3 "$SCORE" score --outputs "$O4b" --fixtures "$FIX" --key "$KEY" --critics codex --only "$LA" --no-ledger --json "$TMP/s4c.json" >/dev/null 2>&1
eq "unscored: fewer bullets than a heading declares is unscored" "$(metric "$TMP/s4c.json" unscored)" "1"
# A bullet BULLET rejects (no [file:line]) is not a parsed finding: the count
# check must not let it pass as one, or the finding is silently lost.
printf '# Critic Panel Review (1/1 critics responded)\n\n## Critical Issues (0 found)\n\n## Important Issues (1 found)\n- [codex-1]: off-by-one with no citation\n\n## Suggestions (0 found)\n' > "$O4b/$LA.md"
python3 "$SCORE" score --outputs "$O4b" --fixtures "$FIX" --key "$KEY" --critics codex --only "$LA" --no-ledger --json "$TMP/s4d.json" >/dev/null 2>&1
eq "unscored: a declared bullet without [file:line] is unscored" "$(metric "$TMP/s4d.json" unscored)" "1"
# A finding-shaped bullet BULLET rejects, under a heading whose count omits it
# ((0 found) + one malformed bullet), would still count 0 == 0: flag it apart
# from the declared count.
printf '# Critic Panel Review (1/1 critics responded)\n\n## Critical Issues (0 found)\n\n## Important Issues (0 found)\n- [codex-1]: off-by-one with no citation\n\n## Suggestions (0 found)\n' > "$O4b/$LA.md"
python3 "$SCORE" score --outputs "$O4b" --fixtures "$FIX" --key "$KEY" --critics codex --only "$LA" --no-ledger --json "$TMP/s4e.json" >/dev/null 2>&1
eq "unscored: a malformed bullet the heading count omits is unscored" "$(metric "$TMP/s4e.json" unscored)" "1"
# A citation-guard Critical (the critic cited a line that does not exist and the
# guard dropped it) is a finding lost, not a cut-short review: the case is
# scored (a miss on the seeded case) and the sweep stays ok.
O4g="$TMP/out4g"; mkdir -p "$O4g"
printf '# Critic Panel Review (1/1 critics responded)\n\n## Critical Issues (1 found)\n- [citation-guard-6bd86d6b048c3229]: Review is not clean: 1 blocking finding(s) were rejected because their citations were unverifiable. Inspect Dropped Citations below.\n\n## Important Issues (0 found)\n\n## Suggestions (0 found)\n\n## Dropped Citations (1 dropped)\n- [codex-1]: off-by-one [%s:%s]\n' "$la_file" "$((la_line + 1000))" > "$O4g/$LA.md"
python3 "$SCORE" score --outputs "$O4g" --fixtures "$FIX" --key "$KEY" --critics codex --only "$LA" --no-ledger --json "$TMP/s4g.json" >/dev/null 2>&1
eq "citation-guard: a dropped-citation Critical is scored, not unscored" "$(metric "$TMP/s4g.json" unscored)" "0"
eq "citation-guard: the sweep status is ok" "$(jget "$TMP/s4g.json" status)" "ok"
eq "citation-guard: the lost finding is a miss on the seeded case" "$(metric "$TMP/s4g.json" codex.recall)" "0.0"
# A nonzero panel exit still wins over the guard bullet.
echo 1 > "$O4g/$LA.rc"
python3 "$SCORE" score --outputs "$O4g" --fixtures "$FIX" --key "$KEY" --critics codex --only "$LA" --no-ledger --json "$TMP/s4h.json" >/dev/null 2>&1
eq "citation-guard: a nonzero rc is still unscored" "$(metric "$TMP/s4h.json" unscored)" "1"
# A guard-shaped bullet the panel never prints (no message) is malformed, not a guard.
O4m="$TMP/out4m"; mkdir -p "$O4m"
printf '# Critic Panel Review (1/1 critics responded)\n\n## Critical Issues (1 found)\n- [citation-guard-6bd86d6b048c3229]: \n\n## Important Issues (0 found)\n\n## Suggestions (0 found)\n' > "$O4m/$LA.md"
python3 "$SCORE" score --outputs "$O4m" --fixtures "$FIX" --key "$KEY" --critics codex --only "$LA" --no-ledger --json "$TMP/s4j.json" >/dev/null 2>&1
eq "citation-guard: a guard bullet with no message is unscored" "$(metric "$TMP/s4j.json" unscored)" "1"
# The guard's Critical blocks the CR gate, so on a clean twin it is a false
# block: it counts for fp_rate, not for findings or precision, and the guard is
# no roster member of its own.
cp "$O4g/$LA.md" "$O4g/$LAc.md"
python3 "$SCORE" score --outputs "$O4g" --fixtures "$FIX" --key "$KEY" --critics codex --only "$LAc" --no-ledger --json "$TMP/s4i.json" >/dev/null 2>&1
eq "citation-guard: a clean twin is scored" "$(metric "$TMP/s4i.json" unscored)" "0"
eq "citation-guard: a clean twin counts as a false block in the panel fp_rate" "$(metric "$TMP/s4i.json" panel.fp_rate)" "1.0"
eq "citation-guard: the false block is not a critic finding" "$(metric "$TMP/s4i.json" panel.findings)" "0"
eq "citation-guard: the guard is no roster member" "$(jget "$TMP/s4i.json" critics)" '["codex"]'
eq "citation_guard_outcome: the guard is no participant; the critic it cut answered" \
  "$(python3 -c 'import json,sys; print(sorted(json.load(open(sys.argv[1]))["case_evidence"][sys.argv[2]]["critics"]))' "$TMP/s4g.json" "$LA" 2>&1):$(cev "$TMP/s4g.json" "$LA" codex state)" "['codex']:answered"

# A transcript that touches the key is flagged and the run marked inconclusive.
O5="$TMP/out5"; mkdir -p "$O5"
review "$O5/$LA.md" codex "imp:$la_file:$la_line:off-by-one"
printf 'hermes: read /x/scripts/eval/review-panel/key/seeds.json\n' > "$O5/$LA.err"
python3 "$SCORE" score --outputs "$O5" --fixtures "$FIX" --key "$KEY" --critics codex --only "$LA" --no-ledger --json "$TMP/s5.json" >"$TMP/s5.txt" 2>&1
eq "leak: the transcript naming the key is counted" "$(metric "$TMP/s5.json" leaked)" "1"
eq "leak: the run is inconclusive" "$(jget "$TMP/s5.json" status)" "inconclusive"
has "leak: the report names the case" "$(cat "$TMP/s5.txt")" "LEAK $LA"
review "$O5/$LA.md" codex "imp:$la_file:$la_line:off-by-one $canary"
rm -f "$O5/$LA.err"
python3 "$SCORE" score --outputs "$O5" --fixtures "$FIX" --key "$KEY" --critics codex --only "$LA" --no-ledger --json "$TMP/s5.json" >/dev/null 2>&1
eq "leak: the canary in a finding is counted" "$(metric "$TMP/s5.json" leaked)" "1"

# --- the eval-runs row --------------------------------------------------------------
L="$TMP/ledger.jsonl"
python3 "$SCORE" score --outputs "$O" --fixtures "$FIX" --key "$KEY" --critics codex --only "$LA,$QA,$TA,$LAc,$QAc" --ledger "$L" --meta-json '{"codex_bank_delta_pct":3}' >/dev/null 2>&1; rc=$?
eq "ledger: exit 0" "$rc" "0"
eq "ledger: one row" "$(grep -c . "$L" 2>/dev/null)" "1"
python3 "$HERE/../lib/eval_runs.py" validate "$L" >/dev/null 2>&1; rc=$?
eq "ledger: the row is a valid eval-runs v1 row" "$rc" "0"
eq "ledger: eval id" "$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["eval"])' "$L")" "review-panel"
eq "ledger: the meta carries the bank cost" "$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["meta"]["codex_bank_delta_pct"])' "$L")" "3"
eq "ledger: per-case rows recorded" "$(python3 -c 'import json,sys; print(len(json.loads(open(sys.argv[1]).readline())["cases"]))' "$L")" "5"
eq "ledger: the config fingerprints the class patterns" "$(python3 -c 'import json,sys; print(len(json.loads(open(sys.argv[1]).readline())["config"].get("class_patterns", "")))' "$L")" "16"
python3 "$SCORE" score --outputs "$O" --fixtures "$FIX" --key "$KEY" --critics codex --only "$LA,$QA" --model gpt-6-astra --ledger "$TMP/model.jsonl" >/dev/null 2>&1
eq "ledger: --model names the critic model on the row" "$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["model"])' "$TMP/model.jsonl" 2>/dev/null)" "gpt-6-astra"
eq "ledger: the critic model is part of the series" "$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["config"]["critic_model"])' "$TMP/model.jsonl" 2>/dev/null)" "gpt-6-astra"
eq "ledger: the live ledger was never touched" "$([ -e "$TMP/never.jsonl" ] && echo yes || echo no)" "no"

# --- run.sh with a stub panel -----------------------------------------------------
# The stub proves what the critic sees: a cwd outside any git checkout that holds
# nothing but the diff, and a stdin with no canary. It answers like a panel.
cat > "$TMP/stub-panel.sh" <<'EOF'
#!/usr/bin/env bash
diff="$(cat)"
here="$(pwd)"
if git rev-parse --show-toplevel >/dev/null 2>&1; then echo "STUB: cwd is inside a git checkout: $here" >&2; exit 9; fi
held="$(ls -A "$here" | tr '\n' ' ')"
# A delta case also holds its context file (the round-1 diff then the delta); nothing else.
if [ "$held" != "diff.patch " ] && [ "$held" != "context.patch diff.patch " ]; then echo "STUB: cwd holds more than the diff: $held" >&2; exit 9; fi
case "$diff" in *rpk-canary*|*seeds.json*) echo "STUB: the canary reached stdin" >&2; exit 9 ;; esac
printf '%s\n' "$CRITIC_PANEL_TIERS" > "$STUB_LOG_DIR/tiers"
printf '%s %s\n' "${CR_TRIVIALITY_OVERRIDE:-}" "${CRITIC_KNOWN_FINDINGS:-}" > "$STUB_LOG_DIR/env"
printf '%s\n' "${CRITICS_JSON:-}" > "$STUB_LOG_DIR/critics_json"
printf '# Critic Panel Review (1/1 critics responded)\n\n## Critical Issues (0 found)\n\n## Important Issues (0 found)\n\n## Suggestions (0 found)\n'
EOF
mkdir -p "$TMP/stublog"
STUB_LOG_DIR="$TMP/stublog" REVIEW_PANEL_CMD="$TMP/stub-panel.sh" REVIEW_PANEL_SCRATCH="$TMP/scratch" \
  bash "$RUN" --out "$TMP/run1" --ledger "$TMP/run-ledger.jsonl" --critics codex --tiers paid --model stub-critic >"$TMP/run1.txt" 2>&1; rc=$?
eq "run: exit 0 on a stub panel" "$rc" "0"
eq "run: one output per fixture" "$(find "$TMP/run1" -name 'case-*.md' | wc -l | tr -d ' ')" "24"
eq "run: no stub refusal" "$(grep -c 'STUB:' "$TMP"/run1/*.err 2>/dev/null | awk -F: '{s+=$2} END {print s+0}')" "0"
eq "run: the tier set reaches the panel" "$(cat "$TMP/stublog/tiers" 2>/dev/null)" "paid"
eq "run: triviality override on, known-findings off" "$(cat "$TMP/stublog/env" 2>/dev/null)" "full 0"
cj="$(cat "$TMP/stublog/critics_json" 2>/dev/null)"
slugs() { python3 -c 'import json,sys; print(",".join(r["slug"] for r in json.load(open(sys.argv[1]))["panel"]))' "$1" 2>&1; }
codexrow() { python3 -c 'import json,sys; print([r for r in json.load(open(sys.argv[1]))["panel"] if r["slug"]=="codex"])' "$1" 2>&1; }
# --critics cuts the roster the panel runs, not just the report.
eq "run: --critics codex hands the panel a roster of codex only" "$(slugs "$cj")" "codex"
# A27 control: the roster is the swept tree's own critics.json row, not a local overlay.
eq "run: the roster row is the swept tree's critics.json row" "$(codexrow "$cj")" "$(codexrow "$HERE/../../cr/critics.json")"
# A sweep that would reach a claude-api critic with no opt-in refuses before any case.
: > "$TMP/stublog/tiers"
STUB_LOG_DIR="$TMP/stublog" REVIEW_PANEL_CMD="$TMP/stub-panel.sh" REVIEW_PANEL_SCRATCH="$TMP/scratch" \
  bash "$RUN" --out "$TMP/run-nopt" --no-ledger >"$TMP/run-nopt.txt" 2>&1; rc=$?
eq "run: a default sweep (claude-api in the tier) refuses" "$rc" "2"
has "run: the refusal names the claude critic and the flag" "$(cat "$TMP/run-nopt.txt")" "--allow-claude-api"
eq "run: no panel call on a refused claude sweep" "$(cat "$TMP/stublog/tiers")" ""
# Control: with the opt-in both critics run.
STUB_LOG_DIR="$TMP/stublog" REVIEW_PANEL_CMD="$TMP/stub-panel.sh" REVIEW_PANEL_SCRATCH="$TMP/scratch" \
  bash "$RUN" --out "$TMP/run-opt" --no-ledger --allow-claude-api --only case-01 >/dev/null 2>&1; rc=$?
eq "run: --allow-claude-api lets the sweep run" "$rc" "0"
eq "run: --allow-claude-api hands the panel codex and claude" "$(slugs "$TMP/run-opt/critics.run.json")" "codex,claude"
eq "run: one ledger row" "$(grep -c . "$TMP/run-ledger.jsonl" 2>/dev/null)" "1"
eq "run: --model reaches the row" "$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["model"])' "$TMP/run-ledger.jsonl")" "stub-critic"
eq "run: an empty review scores recall 0" "$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["metrics"]["codex.recall"])' "$TMP/run-ledger.jsonl")" "0.0"
eq "run: a sweep through a stub panel is stamped unclean" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["clean"])' "$TMP/run1/swept.json" 2>&1)" "False"
# run.sh refuses before any panel call when the lint fails.
mkdir -p "$TMP/badfix"; cp "$FIX"/case-*.patch "$TMP/badfix/"; printf '+# injected defect\n' >> "$TMP/badfix/case-05.patch"
: > "$TMP/stublog/tiers"
STUB_LOG_DIR="$TMP/stublog" REVIEW_PANEL_CMD="$TMP/stub-panel.sh" REVIEW_PANEL_SCRATCH="$TMP/scratch" \
  bash "$RUN" --out "$TMP/run2" --fixtures "$TMP/badfix" --no-ledger --critics codex >/dev/null 2>&1; rc=$?
eq "run: a failing lint refuses the sweep" "$rc" "2"
eq "run: no panel call on a refused sweep" "$(cat "$TMP/stublog/tiers")" ""
: > "$TMP/stublog/tiers"
STUB_LOG_DIR="$TMP/stublog" REVIEW_PANEL_CMD="$TMP/stub-panel.sh" REVIEW_PANEL_SCRATCH="$HERE/.scratch-probe" \
  bash "$RUN" --out "$TMP/run3" --no-ledger --critics codex >/dev/null 2>&1; rc=$?
rmdir "$HERE/.scratch-probe" 2>/dev/null
eq "run: a scratch inside a checkout refuses the sweep" "$rc" "2"
eq "run: no panel call from a scratch inside a checkout" "$(cat "$TMP/stublog/tiers")" ""
timeout 10 bash "$RUN" --out >/dev/null 2>&1; rc=$?
eq "run: an option missing its value is a usage error, not a hang" "$rc" "2"
: > "$TMP/stublog/tiers"
STUB_LOG_DIR="$TMP/stublog" REVIEW_PANEL_CMD="$TMP/stub-panel.sh" REVIEW_PANEL_SCRATCH="$TMP/scratch" \
  bash "$RUN" --out "$TMP/run4" --no-ledger --critics codex --only "case-01,case-99" >/dev/null 2>&1; rc=$?
eq "run: an --only id the key lacks refuses the sweep" "$rc" "2"
eq "run: no panel call for a mixed valid/unknown --only" "$(cat "$TMP/stublog/tiers")" ""
# run.sh --delta: a delta case reaches the panel as diff = the fix delta, context = the round-1 diff then the delta.
cat > "$TMP/stub-delta-panel.sh" <<'EOF'
#!/usr/bin/env bash
ctx=""
id="$(basename "$(pwd)")"
# Like the real panel, refuse an option it does not know; the suite counts the refusals.
while [ $# -gt 0 ]; do
  case "$1" in
    --context-file) ctx="$2"; shift 2 ;;
    *) echo "stub panel: unknown option $1" >&2; echo "$1" >> "$STUB_LOG_DIR/$id.argerr"; exit 2 ;;
  esac
done
cat > "$STUB_LOG_DIR/$id.stdin"
[ -z "$ctx" ] || cp "$ctx" "$STUB_LOG_DIR/$id.ctx"
printf '%s\n' "$(ls -A | tr '\n' ' ')" > "$STUB_LOG_DIR/$id.cwd"
printf '# Critic Panel Review (1/1 critics responded)\n\n## Critical Issues (0 found)\n\n## Important Issues (0 found)\n\n## Suggestions (0 found)\n'
EOF
DL="$TMP/dlog"; rm -rf "$DL"; mkdir -p "$DL"
STUB_LOG_DIR="$DL" REVIEW_PANEL_CMD="$TMP/stub-delta-panel.sh" REVIEW_PANEL_SCRATCH="$TMP/scratch-d" \
  bash "$RUN" --out "$TMP/rund" --fixtures "$FIXD" --key "$KEYD" --delta --no-ledger --critics codex >/dev/null 2>&1; rc=$?
eq "run --delta: exit 0 on a stub panel" "$rc" "0"
eq "run --delta: only the 10 delta cases are swept" \
  "$(find "$TMP/rund" -name 'delta-*.md' | wc -l | tr -d ' '):$(find "$TMP/rund" -name 'case-*.md' | wc -l | tr -d ' ')" "10:0"
eq "run --delta: the panel's stdin is the fix delta" "$(cmp -s "$DL/delta-07.stdin" "$FIXD/delta-07.delta.patch" && echo same)" "same"
eq "run --delta: the context is the round-1 diff then the delta" \
  "$(cat "$FIXD/delta-07.patch" "$FIXD/delta-07.delta.patch" | cmp -s - "$DL/delta-07.ctx" && echo same)" "same"
eq "run --delta: the critic's directory holds the diff and the context only" "$(cat "$DL/delta-07.cwd")" "context.patch diff.patch "
eq "run --delta: a clean delta twin is fed the same way" "$(cmp -s "$DL/delta-02.stdin" "$FIXD/delta-02.delta.patch" && echo same)" "same"
eq "run --delta: run.sh passes the panel no option it does not know" "$(find "$DL" -name '*.argerr' | wc -l | tr -d ' ')" "0"
eq "run --delta: the sweep is stamped a subset" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["clean"])' "$TMP/rund/swept.json" 2>&1)" "False"
# The bundle hash covers a delta transcript: editing one output changes it.
h_before="$(python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import score; print(score.outputs_sha256(sys.argv[2]))' "$HERE" "$TMP/rund")"
printf 'edited\n' >> "$TMP/rund/delta-07.md"
h_after="$(python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import score; print(score.outputs_sha256(sys.argv[2]))' "$HERE" "$TMP/rund")"
eq "outputs_sha256: a changed delta transcript changes the bundle hash" "$([ -n "$h_before" ] && [ "$h_before" != "$h_after" ] && echo differs || echo same)" "differs"
# A full sweep (no --delta) feeds delta cases the same way and every other case its plain diff.
rm -rf "$DL"; mkdir -p "$DL"
STUB_LOG_DIR="$DL" REVIEW_PANEL_CMD="$TMP/stub-delta-panel.sh" REVIEW_PANEL_SCRATCH="$TMP/scratch-f" \
  bash "$RUN" --out "$TMP/runf" --fixtures "$FIXD" --key "$KEYD" --no-ledger --critics codex >/dev/null 2>&1; rc=$?
eq "run (full): exit 0 with delta cases in the set" "$rc" "0"
eq "run (full): one output per case, delta cases included" "$(find "$TMP/runf" -name '*.md' | wc -l | tr -d ' ')" "34"
eq "run (full): a delta case is still fed its delta" "$(cmp -s "$DL/delta-07.stdin" "$FIXD/delta-07.delta.patch" && echo same)" "same"
eq "run (full): a plain case is fed its diff with no context" \
  "$(cmp -s "$DL/case-01.stdin" "$FIXD/case-01.patch" && echo same):$([ -e "$DL/case-01.ctx" ] && echo ctx || echo none)" "same:none"
eq "run (full): run.sh passes the panel no option it does not know" "$(find "$DL" -name '*.argerr' | wc -l | tr -d ' ')" "0"
# --delta refuses before any panel call when it cannot name delta cases.
rm -rf "$DL"; mkdir -p "$DL"
STUB_LOG_DIR="$DL" REVIEW_PANEL_CMD="$TMP/stub-delta-panel.sh" REVIEW_PANEL_SCRATCH="$TMP/scratch-d" \
  bash "$RUN" --out "$TMP/rund2" --fixtures "$FIXD" --key "$KEYD" --delta --only delta-07 --no-ledger --critics codex >/dev/null 2>&1; rc=$?
eq "run --delta: exclusive with --only" "$rc" "2"
STUB_LOG_DIR="$DL" REVIEW_PANEL_CMD="$TMP/stub-delta-panel.sh" REVIEW_PANEL_SCRATCH="$TMP/scratch-d" \
  bash "$RUN" --out "$TMP/rund3" --fixtures "$TMP/syn/fixtures" --key "$TMP/syn/seeds.json" --delta --no-ledger --critics codex >/dev/null 2>&1; rc=$?
eq "run --delta: a key with no delta case refuses the sweep" "$rc" "2"
eq "run --delta: no panel call on either refusal" "$(find "$DL" -type f | wc -l | tr -d ' ')" "0"
# A full sweep from a committed copy of this eval, whose own critic-panel.sh is the stub, stamps clean;
# the same sweep whose panel edits a CBS file mid-run is caught by run.sh's re-stamp after the loop.
RR="$TMP/run-repo"
mkdir -p "$RR/scripts/eval/review-panel/key" "$RR/scripts/eval/lib" "$RR/scripts/cr"
cp "$RUN" "$SCORE" "$HERE/cbs.txt" "$RR/scripts/eval/review-panel/"
cp -r "$FIX" "$RR/scripts/eval/review-panel/fixtures"; cp "$KEY" "$RR/scripts/eval/review-panel/key/seeds.json"
cp "$HERE/../lib/"*.py "$RR/scripts/eval/lib/"; cp "$HERE/../feedback-rules.json" "$RR/scripts/eval/"
cp "$HERE/../../cr/critics.json" "$RR/scripts/cr/critics.json"
printf '#!/bin/sh\n' > "$RR/scripts/cr/critic-x.sh"
cat > "$RR/scripts/cr/critic-panel.sh" <<'EOF'
#!/usr/bin/env bash
cmp -s - diff.patch || exit 9
[ -z "${STUB_DIRTY:-}" ] || printf '# mid-sweep\n' >> "$(dirname "$0")/critic-x.sh"
printf '# Critic Panel Review (1/1 critics responded)\n\n## Critical Issues (0 found)\n\n## Important Issues (0 found)\n\n## Suggestions (0 found)\n'
EOF
printf '__pycache__/\n' > "$RR/.gitignore"
rr() { git -C "$RR" -c user.name=t -c user.email=t@example.invalid -c core.hooksPath=/dev/null -c commit.gpgsign=false "$@"; }
git init -q "$RR" && rr add -A && rr commit -q -m base
REVIEW_PANEL_CMD='' REVIEW_PANEL_SCRATCH="$TMP/scratch-rr" bash "$RR/scripts/eval/review-panel/run.sh" --out "$TMP/run-rr1" --no-ledger --critics codex >/dev/null 2>&1; rc=$?
eq "run: a sweep of a clean tree through its own panel exits 0" "$rc" "0"
eq "run: every panel call read its case's diff on stdin and exited 0" "$(cat "$TMP/run-rr1/"case-*.rc | sort -u | tr '\n' ' ')" "0 "
eq "run: a sweep of a clean tree through its own panel is stamped clean" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["clean"])' "$TMP/run-rr1/swept.json" 2>&1)" "True"
STUB_DIRTY=1 REVIEW_PANEL_CMD='' REVIEW_PANEL_SCRATCH="$TMP/scratch-rr" bash "$RR/scripts/eval/review-panel/run.sh" --out "$TMP/run-rr2" --no-ledger --critics codex >/dev/null 2>&1
eq "run: a CBS file edited during the sweep leaves the stamp unclean" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["clean"])' "$TMP/run-rr2/swept.json" 2>&1)" "False"

# --- a committed copy of this working tree's scorer -------------------------------------------
# Rows name the scorer that ran by its clean committed identity, so the gate rows below run a temporary checkout
# holding the working tree's score.py and lib modules, committed: the rows pass while the development tree is dirty.
SC="$TMP/scorer"; mkdir -p "$SC/scripts/eval/review-panel" "$SC/scripts/eval/lib"
cp "$SCORE" "$SC/scripts/eval/review-panel/score.py"; cp "$HERE/../lib/"*.py "$SC/scripts/eval/lib/"; cp "$HERE/../feedback-rules.json" "$SC/scripts/eval/"
printf '__pycache__/\n' > "$SC/.gitignore"
sc() { git -C "$SC" -c user.name=t -c user.email=t@example.invalid -c core.hooksPath=/dev/null -c commit.gpgsign=false "$@"; }
git init -q "$SC" && sc add -A && sc commit -q -m scorer
GSCORE="$SC/scripts/eval/review-panel/score.py"
# sid <score.py> [field] - one field (default scorer_sha256) of that scorer's `scorer-identity --json`.
sid() { python3 "$1" scorer-identity --json 2>/dev/null | python3 -c 'import json,sys; v=json.load(sys.stdin).get(sys.argv[1]); print("null" if v is None else v)' "${2:-scorer_sha256}" 2>/dev/null; }
SID="$(sid "$GSCORE")"
eq "temporary_scorer_fixture: the committed copy has a clean 64-hex identity" "$(printf '%s' "$SID" | grep -cE '^[0-9a-f]{64}$')" "1"
eq "clean_fixture_uses_worktree_bytes: the copy runs this working tree's score.py" "$(cmp -s "$SCORE" "$GSCORE" && echo same)" "same"

# --- the merge gate: cbs.txt, cbs-hash, export-row, verify-row, gate -------------------------
G="$TMP/gate-repo"
gg() { git -C "$G" -c user.name=t -c user.email=t@example.invalid -c core.hooksPath=/dev/null -c commit.gpgsign=false "$@"; }
mkdir -p "$G/scripts/eval/review-panel/key" "$G/scripts/cr/perspectives"
cp -r "$FIX" "$G/scripts/eval/review-panel/fixtures"
cp "$KEY" "$G/scripts/eval/review-panel/key/seeds.json"
cp "$HERE/cbs.txt" "$G/scripts/eval/review-panel/cbs.txt"
cp "$HERE/../../cr/critics.json" "$G/scripts/cr/critics.json"
printf '#!/bin/sh\n' > "$G/scripts/cr/critic-panel.sh"
printf 'p\n' > "$G/scripts/cr/perspectives/skeptic.md"
printf 'not a critic\n' > "$G/scripts/cr/review-round.sh"
git init -q "$G" && gg add -A && gg commit -q -m base
GB=$(gg rev-parse HEAD)
h1=$(python3 "$SCORE" cbs-hash HEAD --repo "$G"); h2=$(python3 "$SCORE" cbs-hash HEAD --repo "$G")
eq "cbs-hash: stable across two calls" "$h1" "$h2"
eq "cbs-hash: 64 hex" "${#h1}" "64"
eq "cbs-paths: the listed critic files, never another scripts/cr file" "$(python3 "$SCORE" cbs-paths HEAD --repo "$G" | tr '\n' ' ')" \
  "scripts/cr/critic-panel.sh scripts/cr/critics.json scripts/cr/perspectives/skeptic.md "
printf ' ' >> "$G/scripts/cr/critic-panel.sh"; gg commit -qam byte
eq "cbs-hash: one byte changes it" "$([ "$(python3 "$SCORE" cbs-hash HEAD --repo "$G")" != "$h1" ] && echo moved)" "moved"
printf '#!/bin/sh\n' > "$G/scripts/cr/critic-x.sh"; gg add -A; gg commit -qm critic-x
has "cbs-paths: a new tracked critic-x.sh joins" "$(python3 "$SCORE" cbs-paths HEAD --repo "$G")" "scripts/cr/critic-x.sh"

gstamp() { local o="$1"; shift; python3 "$SCORE" stamp "$o" --repo "$G" --fixtures "$G/scripts/eval/review-panel/fixtures" \
    --key "$G/scripts/eval/review-panel/key/seeds.json" "$@" 2>&1; }
out=$(python3 "$GSCORE" export-row "$O" --repo "$G" --results "$TMP/results.jsonl" 2>&1); rc=$?
eq "export-row: outputs run.sh never stamped are refused" "$rc" "2"; has "export-row: names the missing stamp" "$out" "not a run.sh sweep"
gstamp "$O" >/dev/null
printf '# later\n' >> "$G/scripts/cr/critic-x.sh"; gg commit -qam later-critic
out=$(python3 "$GSCORE" export-row "$O" --repo "$G" --results "$TMP/results.jsonl" 2>&1); rc=$?
eq "export-row: a sweep stamped at an older critic tree is refused" "$rc" "2"; has "export-row: names the stale hash" "$out" "was swept at cbs_hash"
printf '# uncommitted\n' >> "$G/scripts/cr/critic-x.sh"
has "stamp: a dirty critic file warns" "$(gstamp "$O")" "export-row will refuse"
python3 "$GSCORE" export-row "$O" --repo "$G" --results "$TMP/results.jsonl" >/dev/null 2>&1; rc=$?
eq "export-row: a sweep of a dirty tree is refused" "$rc" "2"
gg checkout -q -- scripts/cr/critic-x.sh
has "stamp: other fixtures warn" "$(python3 "$SCORE" stamp "$O" --repo "$G" --fixtures "$FIX" --key "$KEY" 2>&1)" "export-row will refuse"
eq "stamp: other fixtures are unclean" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["clean"])' "$O/swept.json")" "False"
has "stamp: another tier set warns" "$(gstamp "$O" --tiers free)" "export-row will refuse"
has "stamp: another panel command warns" "$(gstamp "$O" --panel "$TMP/stub-panel.sh")" "export-row will refuse"
has "stamp: a subset sweep warns" "$(gstamp "$O" --only case-01)" "export-row will refuse"
printf '# local edit\n' > "$G/scripts/eval/review-panel/run.sh"
has "stamp: an uncommitted eval script warns" "$(gstamp "$O")" "export-row will refuse"
rm -f "$G/scripts/eval/review-panel/run.sh"
printf '{}\n' > "$G/scripts/eval/review-panel/results.jsonl"
eq "stamp: an exported results.jsonl does not dirty the next sweep" "$(gstamp "$O")" ""
rm -f "$G/scripts/eval/review-panel/results.jsonl"
gstamp "$O" >/dev/null; printf '# mid-sweep\n' >> "$G/scripts/cr/critic-x.sh"
has "stamp --recheck: a critic file dirtied during the sweep warns" "$(gstamp "$O" --recheck)" "export-row will refuse"
gg checkout -q -- scripts/cr/critic-x.sh
has "stamp --recheck: an unclean stamp stays unclean on a clean tree" "$(gstamp "$O" --recheck)" "export-row will refuse"
gstamp "$O" >/dev/null
eq "stamp --recheck: an unchanged clean tree stays clean" "$(gstamp "$O" --recheck)" ""
printf 'n\n' > "$G/notes.txt"; gg add notes.txt; gg commit -qm moved
has "stamp --recheck: a HEAD moved during the sweep warns" "$(gstamp "$O" --recheck)" "export-row will refuse"
gstamp "$O" >/dev/null
out=$(python3 "$GSCORE" export-row "$O" --repo "$G" --results "$TMP/results.jsonl" 2>&1); rc=$?
eq "export-row: a sweep interrupted before its re-stamp is refused" "$rc" "2"; has "export-row: names the missing re-stamp" "$out" "never re-stamped"
gstamp "$O" --recheck >/dev/null; gstamp "$O5" >/dev/null; gstamp "$O5" --recheck >/dev/null
python3 "$GSCORE" export-row "$O" --repo "$G" --results "$TMP/results.jsonl" >/dev/null 2>&1; rc=$?
eq "export-row: exit 0" "$rc" "0"
row="$(head -1 "$TMP/results.jsonl" 2>/dev/null)"
rget() { python3 -c 'import json,sys; v=json.loads(sys.argv[1])
for k in sys.argv[2].split("/"): v=v.get(k) if isinstance(v,dict) else None
print(round(v,4) if isinstance(v,float) else v)' "$row" "$1"; }
eq "export-row: writes every field" "$(python3 -c 'import json,sys; print(" ".join(sorted(json.loads(sys.argv[1]))))' "$row")" \
  "cbs_hash class_recall confighash metrics outputs_sha256 responded run_id scorer_gitsha scorer_reason scorer_sha256 status tree"
eq "export-row: the run_id is the outputs dir" "$(rget run_id)" "out1"
eq "export-row: cbs_hash is HEAD's" "$(rget cbs_hash)" "$(python3 "$SCORE" cbs-hash HEAD --repo "$G")"
eq "round trip: the confighash gate computes equals the row's" "$(python3 "$SCORE" confighash HEAD --repo "$G")" "$(rget confighash)"
eq "export-row: the panel's recall_gating" "$(rget metrics/panel.recall_gating)" "0.3333"
eq "export-row: the panel's class recall" "$(rget class_recall/toctou)" "1.0"
eq "export-row: a 64-hex outputs bundle hash" "$(rget outputs_sha256 | tr -d '\n' | wc -c | tr -d ' ')" "64"
out=$(python3 "$GSCORE" export-row "$O5" --repo "$G" --results "$TMP/results.jsonl" 2>&1); rc=$?
eq "export-row: an inconclusive sweep is refused" "$rc" "2"; has "export-row: names the inconclusive status" "$out" "is inconclusive"
eq "export-row: and writes no row" "$(grep -c . "$TMP/results.jsonl")" "1"
python3 "$GSCORE" verify-row "$row" "$O" --repo "$G" >/dev/null 2>&1; rc=$?
eq "verify-row: the exported row matches its outputs" "$rc" "0"
doctor() { python3 -c 'import json,sys; r=json.loads(sys.argv[1]); exec(sys.argv[2]); print(json.dumps(r))' "$row" "$1"; }
python3 "$GSCORE" verify-row "$(doctor 'r["metrics"]["panel.recall_gating"]=0.9')" "$O" --repo "$G" >/dev/null 2>&1; rc=$?
eq "verify-row: a doctored metric exits 1" "$rc" "1"
python3 "$GSCORE" verify-row "$(doctor 'r["outputs_sha256"]="0"*64')" "$O" --repo "$G" >/dev/null 2>&1; rc=$?
eq "verify-row: a doctored outputs_sha256 exits 1" "$rc" "1"
python3 "$GSCORE" verify-row "$(doctor 'r["status"]="inconclusive"')" "$O" --repo "$G" >/dev/null 2>&1; rc=$?
eq "verify-row: a doctored status exits 1" "$rc" "1"
python3 "$GSCORE" verify-row "$(doctor 'r["responded"]={"scored": 99, "critics": {"claude": 99}}')" "$O" --repo "$G" >/dev/null 2>&1; rc=$?
eq "verify-row: a doctored responded roster exits 1" "$rc" "1"
python3 "$GSCORE" verify-row "$(doctor 'del r["responded"]')" "$O" --repo "$G" >/dev/null 2>&1; rc=$?
eq "verify-row: a row without a responded key is not held to one" "$rc" "0"
# The responded roster is the sweep's own critics.run.json, not the tree's paid roster. The file is
# the shape run.sh writes (a real codex-only one from 2026-11-05-pr4690-base-r1, _compliance cut): the tree's
# critics.json cut to the --critics slugs.
rcrit() { python3 -c 'import json,sys
slugs=sys.argv[2].split(",")
reg=json.load(open(sys.argv[3])); reg["panel"]=[r for r in reg["panel"] if r["slug"] in slugs]; reg["_compliance"]="panel/router lanes default to per-token ..."
json.dump(reg, open(sys.argv[1], "w"))' "$1" "$2" "$G/scripts/cr/critics.json"; }
rresp() { python3 -c 'import json,sys; print(json.dumps(json.loads(open(sys.argv[1]).readlines()[-1])["responded"]["critics"], sort_keys=True))' "$1"; }
OC="$TMP/out-cx"; cp -r "$O" "$OC"; rcrit "$OC/critics.run.json" codex
gstamp "$OC" >/dev/null; gstamp "$OC" --recheck >/dev/null
python3 "$GSCORE" export-row "$OC" --repo "$G" --results "$TMP/results-cx.jsonl" >/dev/null 2>&1; rc=$?
eq "export-row: a codex-only sweep exports" "$rc" "0"
eq "responded: a codex-only sweep (critics.run.json lists codex) records codex only, no claude" "$(rresp "$TMP/results-cx.jsonl")" '{"codex": 5}'
python3 "$GSCORE" verify-row "$(tail -1 "$TMP/results-cx.jsonl")" "$OC" --repo "$G" >/dev/null 2>&1; rc=$?
eq "verify-row: the codex-only row matches its outputs" "$rc" "0"
eq "confighash: a codex-only sweep keeps the tree's confighash" "$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readlines()[-1])["confighash"])' "$TMP/results-cx.jsonl")" "$(python3 "$SCORE" confighash HEAD --repo "$G")"
OF="$TMP/out-full"; cp -r "$O" "$OF"; rcrit "$OF/critics.run.json" codex,claude
gstamp "$OF" >/dev/null; gstamp "$OF" --recheck >/dev/null
python3 "$GSCORE" export-row "$OF" --repo "$G" --results "$TMP/results-full.jsonl" >/dev/null 2>&1
# Those transcripts carry 1/1 headers and codex findings only: the second rostered critic is unknown on every case and
# codex answered the four cases its findings prove (the zero-finding one cannot say which critic answered).
eq "header_total_differs_from_roster: a full-roster sweep whose 1/1 headers carry codex findings records no phantom claude answer" "$(rresp "$TMP/results-full.jsonl")" '{"claude": 0, "codex": 4}'
eq "header_total_differs_from_roster: a sweep with no critics.run.json reads the tree's paid roster, no phantom answer either" "$(rresp "$TMP/results.jsonl")" '{"claude": 0, "codex": 4}'

# --- scorer identity: rows name the scorer that RAN, never a tree's scorer ---------------------
eq "scorer_identity_independent_of_gate_repo: the gate repo holds no scorer" "$([ -e "$G/scripts/eval/review-panel/score.py" ] && echo has || echo none)" "none"
eq "scorer_identity_independent_of_gate_repo: the exported row names the running scorer checkout's identity" "$(rget scorer_sha256)" "$SID"
eq "export-row: the row names the scorer commit" "$(rget scorer_gitsha)" "$(sc rev-parse HEAD)"
python3 "$GSCORE" verify-row "$(doctor 'r["scorer_sha256"]="b"*64')" "$O" --repo "$G" >/dev/null 2>&1; rc=$?
eq "verify-row: a row claiming another scorer exits 1" "$rc" "1"
out=$(python3 "$GSCORE" verify-row "$(doctor 'del r["scorer_sha256"]; del r["scorer_gitsha"]; del r["scorer_reason"]; [r["metrics"].pop(k) for k in list(r["metrics"]) if "key_match" in k or "location_match" in k or "labelled_clean" in k]')" "$O" --repo "$G" 2>&1); rc=$?
eq "verify-row: a legacy row without scorer_sha256 compares the fields it claimed" "$rc" "0"
has "verify-row: and says its scorer identity is unverified" "$out" "scorer identity unverified"
# --tree OLD selects the old execution evidence; the row still names the scorer actually run, not a scorer in OLD.
mkdir -p "$G/scripts/eval/lib"; printf '# decoy scorer\n' > "$G/scripts/eval/review-panel/score.py"; printf '# decoy\n' > "$G/scripts/eval/lib/wilson.py"
gg add -A; gg commit -qm decoy-scorer; DECOY=$(gg rev-parse HEAD)
eq "verify_row_old_tree_records_running_scorer: the row scored at --tree OLD names the running scorer" \
  "$(python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import score; r = score.gate_row(sys.argv[2], sys.argv[3], sys.argv[4]); print(r["scorer_sha256"] == sys.argv[5] != score.scorer_digest(sys.argv[2], sys.argv[3]))' "$SC/scripts/eval/review-panel" "$G" "$DECOY" "$O" "$SID" 2>&1)" "True"
python3 "$GSCORE" verify-row "$row" "$O" --repo "$G" --tree "$DECOY" >/dev/null 2>&1; rc=$?
eq "verify_row_old_tree_records_running_scorer: verify-row --tree OLD matches the running scorer's row" "$rc" "0"
gg rm -q -r scripts/eval/lib scripts/eval/review-panel/score.py; gg commit -qm drop-decoy
# A scorer edit after its commit, in score.py or in the wilson.py it loads, is no clean identity.
SCW="$TMP/scorer-dirty-wilson"; cp -r "$SC" "$SCW"; printf '# dirty\n' >> "$SCW/scripts/eval/lib/wilson.py"
SCX="$TMP/scorer-dirty-score"; cp -r "$SC" "$SCX"; printf '# dirty\n' >> "$SCX/scripts/eval/review-panel/score.py"
eq "dirty_scorer_export_diagnostic: an edited running score.py has a null identity" "$(sid "$SCX/scripts/eval/review-panel/score.py"):$(sid "$SCX/scripts/eval/review-panel/score.py" scorer_clean)" "null:False"
eq "dirty_scorer_export_diagnostic: an edited loaded wilson.py has a null identity" "$(sid "$SCW/scripts/eval/review-panel/score.py")" "null"
has "dirty_scorer_export_diagnostic: the reason names the edited file" "$(sid "$SCW/scripts/eval/review-panel/score.py" reason)" "wilson.py"
python3 "$SCX/scripts/eval/review-panel/score.py" export-row "$O" --repo "$G" --results "$TMP/results-dirty.jsonl" >/dev/null 2>&1; rc=$?
eq "dirty_scorer_export_diagnostic: a dirty scorer still exports, diagnostic-only" "$rc:$(python3 -c 'import json,sys; r=json.loads(open(sys.argv[1]).readline()); print(r["scorer_sha256"], bool(r["scorer_reason"]))' "$TMP/results-dirty.jsonl" 2>&1)" "0:None True"
eq "scorer_digest_reads_tree: the pure helper reads committed blobs, not the dirty work tree" \
  "$(python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import score; print(score.scorer_digest(sys.argv[2], "HEAD"))' "$SCX/scripts/eval/review-panel" "$SCX" 2>&1)" "$SID"
eq "scorer_digest_reads_tree: a dirty scorer edit leaves the confighash unchanged" "$(python3 "$SCX/scripts/eval/review-panel/score.py" confighash HEAD --repo "$G")" "$(python3 "$GSCORE" confighash HEAD --repo "$G")"
# An outputs dir stamped before M1 (a swept.json of the old shape, hand-written) still exports under the new scorer.
ORS="$TMP/out-retained"; cp -r "$O" "$ORS"
python3 -c 'import json,sys; json.dump({"cbs_hash": sys.argv[2], "clean": True, "confighash": sys.argv[3], "rechecked": True, "tree": sys.argv[4]}, open(sys.argv[1], "w"), sort_keys=True)' \
  "$ORS/swept.json" "$(python3 "$SCORE" cbs-hash HEAD --repo "$G")" "$(python3 "$SCORE" confighash HEAD --repo "$G")" "$(gg rev-parse HEAD)"
python3 "$GSCORE" export-row "$ORS" --repo "$G" --results "$TMP/results-retained.jsonl" >/dev/null 2>&1; rc=$?
eq "retained_stamp_still_exports: a pre-M1 stamp passes check_stamp and exports with the running scorer's identity" "$rc:$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline()).get("scorer_sha256"))' "$TMP/results-retained.jsonl" 2>&1)" "0:$SID"

# gate over GB..HEAD of the gate repo; grows <rid:recall:fp:logic[:status[:scorer]]>... writes rows at B (b*) or H (h*),
# each stamped with the running scorer's identity (scorer: none omits the key, null writes null, else that hash).
B=$(python3 "$SCORE" cbs-hash "$GB" --repo "$G"); H=$(python3 "$SCORE" cbs-hash HEAD --repo "$G"); C=$(python3 "$SCORE" confighash HEAD --repo "$G")
grows() { python3 -c 'import json,sys
f, b, h, c, sid = sys.argv[1:6]
with open(f, "w") as fh:
    for spec in sys.argv[6:]:
        p = spec.split(":")
        rid, rec, fp, lg = p[:4]
        st, sc = (p[4] if len(p) > 4 else "ok"), (p[5] if len(p) > 5 else "cur")
        row = {"run_id": rid, "cbs_hash": b if rid[0] == "b" else h, "confighash": c, "outputs_sha256": rid, "status": st,
               "metrics": {"panel.recall_gating": float(rec), "panel.fp_rate": float(fp)},
               "class_recall": {"logic": float(lg)}}
        if sc != "none":
            row["scorer_sha256"] = {"cur": sid, "null": None}.get(sc, sc)
        fh.write(json.dumps(row) + "\n")' "$G/scripts/eval/review-panel/results.jsonl" "$B" "$H" "$C" "$SID" "$@"
  gg add -A; gg commit -qm rows; }
ggate() { out=$(python3 "$GSCORE" gate "$GB" HEAD --repo "$G" "$@" 2>&1); rc=$?; }
grows b1:0.5:0.1:0.5 b2:0.6:0.1:0.5 h1:0.55:0.1:0.5 h2:0.5:0.1:0.5; ggate
eq "gate: two against two within noise exits 0" "$rc" "0"; has "gate: no-loss" "$out" "gate: no-loss"
grows b1:0.5:0.1:0.5 b2:0.6:0.1:0.5 h1:0.3:0.1:0.5 h2:0.3:0.1:0.5; ggate
eq "gate: a recall drop beyond noise exits 1" "$rc" "1"; has "gate: loss" "$out" "gate: loss"
grows b1:0.5:0.1:0.5 h1:0.5:0.1:0.5 h2:0.5:0.1:0.5; ggate
eq "gate: one baseline row exits 1" "$rc" "1"; has "gate: unmeasured" "$out" "gate: unmeasured"
grows b1:0.5:0.1:0.5 b2:0.6:0.1:0.5 h1:0.55:0.1:0.5 h2:0.5:0.1:0.5:inconclusive; ggate
eq "gate: an inconclusive head row does not count" "$rc" "1"; has "gate: inconclusive is unmeasured" "$out" "gate: unmeasured"
grows b1:0.5:0.1:0.5 b2:0.6:0.1:0.5 h1:0.55:0.1:0.5 h2:0.5:0.1:0.5:partial; ggate
eq "gate: a partial head row does not count" "$rc" "1"; has "gate: partial is unmeasured" "$out" "gate: unmeasured"
grows b1:0.5:0.1:0.5 b2:0.5:0.1:0.6 h1:0.5:0.1:0.8 h2:0.5:0.1:0.7; ggate --target-class logic
eq "gate: a target class above the baseline max is keep" "$rc" "0"; has "gate: keep" "$out" "gate: keep"
grows b1:0.5:0.1:0.5 b2:0.5:0.1:0.8 h1:0.5:0.1:0.8 h2:0.5:0.1:0.7; ggate --target-class logic
has "gate: a target class not above the baseline max is no-loss" "$out" "gate: no-loss"

# Rows record the cases each critic answered; a verdict never reads across unequal panels.
# groster <rid-prefix> <scored;critic:cases,...> - stamps `responded` on the rows whose run_id starts with the prefix.
groster() { python3 -c 'import json,sys
f, pre, spec = sys.argv[1:4]
scored, crit = spec.split(";")
rows = [json.loads(l) for l in open(f)]
for r in rows:
    if r["run_id"].startswith(pre):
        r["responded"] = {"scored": int(scored), "critics": {c.split(":")[0]: int(c.split(":")[1]) for c in crit.split(",")}}
open(f, "w").write("".join(json.dumps(r) + "\n" for r in rows))' "$G/scripts/eval/review-panel/results.jsonl" "$1" "$2"
  gg add -A; gg commit -qm roster; }
# base: the claude critic answered 12 of 24 cases (skipped, api lane off), head: both answered all; head worse on
# fp_rate, which the old gate called a loss
grows b1:0.5:0.1:0.5 b2:0.5:0.1:0.5 h1:0.5:0.6:0.5 h2:0.5:0.6:0.5; groster b "24;claude:12,codex:24"; groster h "24;claude:24,codex:24"; ggate
eq "gate: unequal panels exit 1" "$rc" "1"
has "gate: unequal panels name the mismatch" "$out" "panel mismatch"
has "gate: unequal panels name the critic that skipped cases" "$out" "claude 12/24"
case "$out" in *"gate: loss"*) fail "gate: unequal panels give no loss";; *) pass "gate: unequal panels give no loss";; esac
# a head that looks like a win across unequal panels is refused too
grows b1:0.5:0.1:0.5 b2:0.5:0.1:0.5 h1:0.5:0.1:0.9 h2:0.5:0.1:0.9; groster b "24;codex:24"; groster h "24;claude:24,codex:24"; ggate --target-class logic
has "gate: a win across unequal panels is a mismatch" "$out" "panel mismatch"
case "$out" in *"gate: keep"*) fail "gate: unequal panels give no keep";; *) pass "gate: unequal panels give no keep";; esac
# like-for-like keeps its normal verdicts
grows b1:0.5:0.1:0.5 b2:0.5:0.1:0.5 h1:0.5:0.6:0.5 h2:0.5:0.6:0.5; groster b "24;claude:24,codex:24"; groster h "24;claude:24,codex:24"; ggate
has "gate: equal panels still lose beyond noise" "$out" "gate: loss"
grows b1:0.5:0.1:0.5 b2:0.5:0.1:0.6 h1:0.5:0.1:0.8 h2:0.5:0.1:0.7; groster b "24;codex:24"; groster h "24;codex:24"; ggate --target-class logic
has "gate: equal panels still keep a target-class win" "$out" "gate: keep"
# a critic that answered none of a side's cases against one that answered some is a different panel
grows b1:0.5:0.1:0.5 b2:0.5:0.1:0.5 h1:0.5:0.1:0.5 h2:0.5:0.1:0.5; groster b "24;claude:0,codex:24"; groster h "24;claude:23,codex:24"; ggate
has "gate: a critic absent on one side and nearly complete on the other is a mismatch" "$out" "panel mismatch"
# a critic absent on both sides, or partial on both, is like-for-like
nroster() { grep -c '"responded"' "$G/scripts/eval/review-panel/results.jsonl"; }
grows b1:0.5:0.1:0.5 b2:0.5:0.1:0.5 h1:0.5:0.1:0.5 h2:0.5:0.1:0.5; groster b "24;claude:0,codex:24"; groster h "24;claude:0,codex:24"; ggate
eq "fixture: every row of the absent-on-both-sides pair carries a roster" "$(nroster)" "4"
has "gate: a critic that answered nothing on both sides is no mismatch" "$out" "gate: no-loss"
grows b1:0.5:0.1:0.5 b2:0.5:0.1:0.5 h1:0.5:0.1:0.5 h2:0.5:0.1:0.5; groster b "24;claude:12,codex:24"; groster h "24;claude:20,codex:24"; ggate
eq "fixture: every row of the partial-on-both-sides pair carries a roster" "$(nroster)" "4"
has "gate: a critic partial on both sides is no mismatch" "$out" "gate: no-loss"
# a row the verdict does not count (an inconclusive sweep) does not make a roster mismatch either
grows b1:0.5:0.1:0.5 b2:0.5:0.1:0.5 h1:0.5:0.1:0.5 h2:0.5:0.1:0.5 h3:0.5:0.1:0.5:inconclusive; groster b "24;claude:24,codex:24"; groster h1 "24;claude:24,codex:24"; groster h2 "24;claude:24,codex:24"; groster h3 "24;codex:24"; ggate
eq "fixture: all five rows carry a roster" "$(nroster)" "5"
has "gate: an uncounted inconclusive row with another roster is no mismatch" "$out" "gate: no-loss"
# rows with no roster beside rows with one are not like-for-like: named, no verdict
grows b1:0.5:0.1:0.5 b2:0.5:0.1:0.5 h1:0.5:0.6:0.5 h2:0.5:0.6:0.5; groster h "24;claude:24,codex:24"; ggate
has "gate: baseline rows with no roster against head rows with one are a mismatch" "$out" "panel mismatch"
has "gate: the rows with no roster are named" "$out" "without a roster: baseline b1; b2"
case "$out" in *"gate: loss"*) fail "gate: rows with no roster give no loss";; *) pass "gate: rows with no roster give no loss";; esac
grows b1:0.5:0.1:0.5 b2:0.5:0.1:0.5 h1:0.5:0.1:0.5 h2:0.5:0.1:0.5; groster b1 "24;codex:24"; groster b2 "24;codex:24"; groster h1 "24;codex:24"; ggate
has "gate: one counted row with no roster beside rows with one is a mismatch" "$out" "without a roster: baseline none | head h2"
# every counted row without a roster keeps the normal verdict
grows b1:0.5:0.1:0.5 b2:0.5:0.1:0.5 h1:0.5:0.6:0.5 h2:0.5:0.6:0.5; ggate
has "gate: no roster on any counted row keeps the normal verdict" "$out" "gate: loss"
# The roster check counts the rows the verdict counts: a row the verdict drops carries another roster (codex alone,
# against the claude+codex pair below) and must not make a mismatch. Each row is dropped by one clause only, with its
# own run_id and bundle, so deleting that clause alone turns its row into a mismatch.
# gextra <run_id> <b|h|x|c> <bundle> <fp_rate|null> - appends one codex-only row: at the base hash (b), the head hash
# (h), another cbs_hash (x) or another confighash (c).
gextra() { python3 -c 'import json,sys
f, b, h, c, rid, side, bundle, fp, sid = sys.argv[1:10]
row = {"run_id": rid, "cbs_hash": b if side == "b" else ("0" * 64 if side == "x" else h),
       "confighash": "other" if side == "c" else c, "outputs_sha256": bundle, "status": "ok",
       "metrics": {"panel.recall_gating": 0.5, "panel.fp_rate": None if fp == "null" else float(fp)},
       "class_recall": {"logic": 0.5}, "responded": {"scored": 24, "critics": {"codex": 24}}, "scorer_sha256": sid}
open(f, "a").write(json.dumps(row) + "\n")' "$G/scripts/eval/review-panel/results.jsonl" "$B" "$H" "$C" "$@" "$SID"
  gg add -A; gg commit -qm extra; }
# gdrop <label> <run_id> <side> <bundle> <fp_rate|null> - the extra row must leave the verdict a no-loss
gdrop() {
  grows b1:0.5:0.1:0.5 b2:0.5:0.1:0.5 h1:0.5:0.1:0.5 h2:0.5:0.1:0.5; groster b "24;claude:24,codex:24"; groster h "24;claude:24,codex:24"
  gextra "$2" "$3" "$4" "$5"; ggate
  has "gate: $1 is not counted by the roster check" "$out" "gate: no-loss"
}
gdrop "a repeated run_id" h1 h dup-of-h1-id 0.1
gdrop "a repeated outputs bundle" h3 h h1 0.1
gdrop "a head row repeating a baseline run_id" b1 h dup-of-b1-id 0.1
gdrop "a head row repeating a baseline outputs bundle" h4 h b1 0.1
gdrop "a counted-status row with a null gate metric" h5 h null-metric null
gdrop "a row at another cbs_hash" h6 x other-hash 0.1
gdrop "a row at another confighash" h7 c other-config 0.1

# The gate counts only rows the running scorer produced, filtered before any other selection.
OLDSID="$(printf 'a%.0s' $(seq 64))"
grows b1:0.5:0.1:0.5:ok:none b2:0.5:0.1:0.5:ok:none h1:0.5:0.1:0.5:ok:none h2:0.5:0.1:0.5:ok:none; ggate
eq "legacy_rows_without_scorer_unmeasured: rows with no scorer_sha256 exit 1" "$rc" "1"
has "legacy_rows_without_scorer_unmeasured: unmeasured" "$out" "gate: unmeasured"
has "legacy_rows_without_scorer_unmeasured: the excluded rows are named" "$out" "4 without scorer_sha256"
grows b1:0.5:0.1:0.5:ok:"$OLDSID" b2:0.5:0.1:0.5:ok:"$OLDSID" h1:0.5:0.1:0.5 h2:0.5:0.1:0.5; ggate
eq "mixed_scorer_rows_unmeasured: an original-scorer baseline against repaired-scorer head rows exits 1" "$rc" "1"
has "mixed_scorer_rows_unmeasured: unmeasured" "$out" "gate: unmeasured"
# rescore: the first b1 row (another scorer) would lose; its re-scored row by the running scorer must be the one read.
grows b1:0.5:0.0:0.5:ok:"$OLDSID" b1:0.5:0.5:0.5 b2:0.5:0.0:0.5 h1:0.5:0.5:0.5 h2:0.5:0.5:0.5; ggate
has "rescore_selected_before_dedup: the running scorer's re-score of a run replaces its older-scorer row" "$out" "gate: no-loss"
SCD="$TMP/scorer-dirty"; cp -r "$SC" "$SCD"; printf '# dirty\n' >> "$SCD/scripts/eval/review-panel/score.py"
grows b1:0.5:0.1:0.5:ok:null b2:0.5:0.1:0.5:ok:none h1:0.5:0.1:0.5:ok:null h2:0.5:0.1:0.5:ok:none
out=$(python3 "$SCD/scripts/eval/review-panel/score.py" gate "$GB" HEAD --repo "$G" 2>&1); rc=$?
eq "null_running_identity_matches_no_rows: a dirty scorer over null and absent row hashes exits 1" "$rc" "1"
has "null_running_identity_matches_no_rows: unmeasured, naming the missing identity" "$out" "no clean identity"

# --- real cases: multi-file, context_seed, base, fix ---------------------------------------
S="$TMP/src"; RL="$TMP/real"; RK="$TMP/real-key.json"
sg() { git -C "$S" -c user.name=t -c user.email=t@example.invalid -c core.hooksPath=/dev/null -c commit.gpgsign=false "$@"; }
mkdir -p "$S/lib" "$S/scripts/eval/review-panel/key" "$RL"
printf 'one\ntwo\nthree\nfour\nfive\n' > "$S/a.sh"; printf 'one\ntwo\nthree\nfour\nfive\n' > "$S/b.sh"
printf 'reader_one\nreader_two\nreader_three\n' > "$S/lib/x.sh"
printf '{"canary": "x"}\n' > "$S/scripts/eval/review-panel/key/seeds.json"; printf '{}\n' > "$S/scripts/eval/review-panel/results.jsonl"
git init -q "$S" && sg add -A && sg commit -qm base; SB=$(sg rev-parse HEAD)
# shellcheck disable=SC2016  # the inserted line is literal shell text
printf 'one\ncaller_count=$((caller_count + 1))\ntwo\nthree\nfour\nfive\n' > "$S/a.sh"; printf 'six_value=6\n' >> "$S/b.sh"
sg diff > "$RL/real-01.patch"; cp "$RL/real-01.patch" "$RL/real-03.patch"; sg checkout -q -- .
printf 'one\necho two_and_a_half\ntwo\nthree\nfour\nfive\n' > "$S/a.sh"; printf 'seven=7\n' >> "$S/b.sh"
sg diff > "$RL/real-02.patch"; cp "$RL/real-02.patch" "$RL/real-04.patch"; sg checkout -q -- .
sg apply "$RL/real-01.patch" && sg commit -qam merged; SM=$(sg rev-parse HEAD)
printf 'reader_sync_after_fix=1\n' >> "$S/lib/x.sh"; sg commit -qam fix; SF=$(sg rev-parse HEAD)
python3 -c 'import json,sys
base, fix, out = sys.argv[1:4]
seeded = lambda pair, split: {"kind": "seeded", "pair": pair, "split": split, "base": base, "fix": fix, "context_seed": "lib/x.sh",
    "defects": [{"id": pair + "1", "class": "cross-file", "file": "lib/x.sh", "line": 2},
                {"id": pair + "2", "class": "spec-miss", "file": "a.sh", "line": 2}]}
clean = lambda pair, split: {"kind": "clean", "pair": pair, "split": split, "base": base, "defects": []}
json.dump({"canary": "rpk-canary-real", "cases": {"real-01": seeded("r-a", "open"), "real-02": clean("r-a", "open"),
           "real-03": seeded("r-b", "sealed"), "real-04": clean("r-b", "sealed")}}, open(out, "w"))' "$SB" "$SF" "$RK"
rkey() { python3 -c 'import json,sys; k=json.load(open(sys.argv[1])); c=k["cases"]["real-01"]; exec(sys.argv[3]); json.dump(k,open(sys.argv[2],"w"))' "$RK" "$TMP/real-key2.json" "$1"; }
out=$(python3 "$SCORE" lint --fixtures "$RL" --key "$RK" --src "$S" --min-real 4 2>&1); rc=$?
eq "lint: multi-file real cases with a context_seed, base and fix lint clean" "$rc" "0"
[ "$rc" = 0 ] || echo "$out"
python3 "$SCORE" lint --fixtures "$RL" --key "$RK" --src "$S" --min-real 5 >/dev/null 2>&1; rc=$?
eq "lint: --min-real above the real-* count is refused" "$rc" "1"
printf 'The reader list needs reader_sync_after_fix=1 too.\n' > "$RL/real-01.intent.md"
out=$(python3 "$SCORE" lint --fixtures "$RL" --key "$RK" --src "$S" 2>&1); rc=$?
eq "lint: a seeded case whose intent carries its fix is refused" "$rc" "1"; has "lint: names the fix leak" "$out" "real-01: carries 1 line(s) of its fix"
rm -f "$RL/real-01.intent.md"
rkey "c['base'] = '$SM'"   # the merged tree: the diff is already in it
out=$(python3 "$SCORE" lint --fixtures "$RL" --key "$TMP/real-key2.json" --src "$S" 2>&1); rc=$?
eq "lint: a diff that does not apply to its base is refused" "$rc" "1"; has "lint: names the base" "$out" "real-01: the diff does not build on its base"
rkey 'del c["context_seed"]'
out=$(python3 "$SCORE" lint --fixtures "$RL" --key "$TMP/real-key2.json" --src "$S" 2>&1); rc=$?
eq "lint: a seed outside the diff with no context_seed is refused" "$rc" "1"; has "lint: names the seed file" "$out" "neither in the diff"
eq "fixture_set_hash: patch-only is unchanged, an intent file moves it" "$(python3 -c 'import hashlib,sys; sys.path.insert(0, sys.argv[1]); import score
s = lambda b: hashlib.sha256(b).hexdigest()
old = hashlib.sha256(b"real-01" + s(b"p").encode() + s(b"k").encode()).hexdigest()[:16]
a = score.fixture_digest(["real-01"], {"real-01.patch": b"p"}, b"k")
b = score.fixture_digest(["real-01"], {"real-01.patch": b"p", "real-01.intent.md": b"i"}, b"k")
print(a == old, a != b)' "$HERE")" "True True"
OR="$TMP/out-real"; mkdir -p "$OR"
review "$OR/real-01.md" codex "imp:lib/x.sh:2:the reader in the other file is not updated" "imp:a.sh:2:does not implement the ticket requirement"
python3 "$SCORE" score --outputs "$OR" --fixtures "$RL" --key "$RK" --critics codex --only real-01 --no-ledger --json "$TMP/sr.json" >/dev/null 2>&1
eq "score: a finding citing the context_seed file is a cross-file hit" "$(metric "$TMP/sr.json" panel.class.cross-file.recall)" "1.0"
eq "score: a spec-miss finding classifies by keyword" "$(metric "$TMP/sr.json" panel.class.spec-miss.recall)" "1.0"
STUB_LOG_DIR="$TMP/stublog" REVIEW_PANEL_CMD="$TMP/stub-panel.sh" REVIEW_PANEL_SCRATCH="$TMP/scratch-real" \
  bash "$RUN" --out "$TMP/run-real" --fixtures "$RL" --key "$RK" --src "$S" --no-ledger --critics codex >/dev/null 2>&1; rc=$?
eq "run: real-* cases are swept" "$rc:$(find "$TMP/run-real" -name 'real-*.md' | wc -l | tr -d ' ')" "0:4"

# I9: the case repo holds the base tree and the case diff only.
mkdir -p "$S/.git/cr-review-rounds"; : > "$S/.git/cr-review-rounds/x"
CR="$TMP/case-repo"
bash "$RUN" --case-repo real-01 --out "$CR" --fixtures "$RL" --key "$RK" --src "$S" >/dev/null 2>&1; rc=$?
eq "case-repo: built" "$rc" "0"
eq "case-repo: exactly 2 commits" "$(git -C "$CR" rev-list --count HEAD 2>/dev/null)" "2"
eq "case-repo: no key/ and no results.jsonl" "$(git -C "$CR" ls-files | grep -c 'review-panel')" "0"
eq "case-repo: no cr-* state under .git" "$(find "$CR/.git" -name 'cr-*' | wc -l | tr -d ' ')" "0"
eq "case-repo: the head commit is the case diff" "$(git -C "$CR" diff --name-only HEAD~1 HEAD | tr '\n' ' ')" "a.sh b.sh "

# harvest: one escapes.py signal and one NO-GO verdict file are both listed.
python3 -c 'import json,sys
m, f = sys.argv[1:3]
json.dump([{"number": 10, "title": "feat(x): [HIMMEL-1] add the counter", "body": "", "mergedAt": "2026-10-01T10:00:00Z",
            "headRefOid": "h10", "mergeCommit": {"oid": m}},
           {"number": 11, "title": "Revert \"feat(x): [HIMMEL-1] add the counter\" (#10)", "body": "", "mergedAt": "2026-10-02T10:00:00Z",
            "headRefOid": "h11", "mergeCommit": {"oid": f}},
           {"number": 12, "title": "feat(y): [HIMMEL-2] add y", "body": "", "mergedAt": "2026-10-03T10:00:00Z",
            "headRefOid": "h12", "mergeCommit": {"oid": "m12"}}], open(sys.argv[3], "w"))' "$SM" "$SF" "$TMP/prs.json"
mkdir -p "$TMP/verdicts/q1"
# shellcheck disable=SC2016  # the backticks are markdown, not a command
printf '# VERDICT q1 - judge\n\nwritten-at: 2026-10-02T12:00:00Z\npr: 12\n\n## Verdict\n\n**NO-GO** for head `abc12`.\n' > "$TMP/verdicts/q1/judge.md"
out=$(python3 "$HERE/harvest.py" --prs "$TMP/prs.json" --mirror "$TMP/no-mirror" --verdicts "$TMP/verdicts" --repo "$S" 2>/dev/null); rc=$?
eq "harvest: exit 0" "$rc" "0"
eq "harvest: the revert (with its fixer) and the NO-GO are both listed" \
  "$(printf '%s\n' "$out" | python3 -c 'import json,sys; print(" ".join("%s:%s:%s:%s" % (r["signal"], r["pr"], r["fix_pr"], r["ticket"]) for r in map(json.loads, filter(str.strip, sys.stdin))))')" \
  "revert:10:11:HIMMEL-1 judge-no-go:12:None:HIMMEL-2"
has "harvest: the escaped PR's base is its merge's first parent" "$out" "\"base\": \"$SB\""
has "harvest: the NO-GO head" "$out" '"head": "abc12"'

# --- the shipped real-escape corpus -----------------------------------------------------------
# Thirty review escapes frozen from merged history, each with a clean twin and an intent file.
n_seeded=$(find "$FIX_ALL" -name 'real-*.patch' ! -name 'real-*-clean.patch' | wc -l | tr -d ' ')
n_clean=$(find "$FIX_ALL" -name 'real-*-clean.patch' | wc -l | tr -d ' ')
eq "real corpus: 30 escapes and 30 clean twins" "$n_seeded:$n_clean" "30:30"
eq "real corpus: every case carries an intent file" "$(find "$FIX_ALL" -name 'real-*.intent.md' | wc -l | tr -d ' ')" "60"
# --min-real counts case files, so 30 pairs are 60 real-* cases.
out=$(python3 "$SCORE" lint --fixtures "$FIX_ALL" --key "$KEY_ALL" --min-real 60 2>&1); rc=$?
eq "real corpus: lint --min-real 60 (30 pairs) passes on the shipped set" "$rc" "0"
[ "$rc" = 0 ] || echo "$out"
eq "real corpus: classes of the escapes, at least 4 cross-file and 4 spec-miss" \
  "$(python3 -c 'import collections, json, sys
n = collections.Counter(d["class"] for k, v in json.load(open(sys.argv[1]))["cases"].items() if k.startswith("real-") for d in v["defects"])
print(" ".join("%s:%d" % kv for kv in sorted(n.items())))' "$KEY_ALL")" \
  "cross-file:4 fail-open:5 logic:8 quoting:2 spec-miss:4 test-cannot-fail:5 toctou:2"
eq "real corpus: an open and a sealed half of 15 pairs each" \
  "$(python3 -c 'import collections, json, sys
n = collections.Counter(v["split"] for k, v in json.load(open(sys.argv[1]))["cases"].items() if k.startswith("real-") and v["kind"] == "seeded")
print(" ".join("%s:%d" % kv for kv in sorted(n.items())))' "$KEY_ALL")" "open:15 sealed:15"
eq "real corpus: each class has an open and a sealed pair" \
  "$(python3 -c 'import collections, json, sys
h = collections.defaultdict(set)
for k, v in json.load(open(sys.argv[1]))["cases"].items():
    if k.startswith("real-") and v["kind"] == "seeded":
        h[v["defects"][0]["class"]].add(v["split"])
print(" ".join("%s:%s" % (c, "+".join(sorted(s))) for c, s in sorted(h.items())))' "$KEY_ALL")" \
  "cross-file:open+sealed fail-open:open+sealed logic:open+sealed quoting:open+sealed spec-miss:open+sealed test-cannot-fail:open+sealed toctou:open+sealed"
# real-007 is the LT-j4386-1 escape: a bus reader and its writers changed in one diff.
eq "real corpus: real-007 changes the bus reader and the chief writers together" \
  "$(grep -cE '^diff --git a/(marketplace/plugins/himmel-bus/lib/identity\.mjs|scripts/handover/chief/chief\.sh) ' "$FIX_ALL/real-007.patch")" "2"
# I9: a real case's scratch repo holds the base tree and the case diff only - no key, no results
# row, no review ledger - for every shipped case.
canary_all=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["canary"])' "$KEY_ALL")
for rp in "$FIX_ALL"/real-*.patch; do
  rid=$(basename "$rp" .patch); riso="$TMP/iso/$rid"
  bash "$RUN" --case-repo "$rid" --out "$riso" --fixtures "$FIX_ALL" --key "$KEY_ALL" >/dev/null 2>&1; rc=$?
  eq "case-repo $rid: built" "$rc" "0"
  eq "case-repo $rid: 2 commits, no key or results file, no review ledger, no canary" \
    "$(git -C "$riso" rev-list --count HEAD 2>/dev/null):$(git -C "$riso" ls-files -- scripts/eval/review-panel | wc -l | tr -d ' '):$(find "$riso/.git" -name 'cr-*' | wc -l | tr -d ' '):$(git -C "$riso" grep -c "$canary_all" | wc -l | tr -d ' ')" \
    "2:0:0:0"
  eq "case-repo $rid: the head commit is exactly the case diff" \
    "$(git -C "$riso" diff --name-only HEAD~1 HEAD | wc -l | tr -d ' ')" "$(grep -c '^diff --git ' "$rp")"
done

echo
echo "test-review-panel: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
