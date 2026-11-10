#!/usr/bin/env bash
# scripts/eval/cr-ledger/test-cr-ledger.sh - suite for the CR-ledger eval
# covers the amend fold, the cutoff, the critic join, re-raise and
# deferral-class counts, the seeded sample and the coded-sample check, all on
# a fixture ledger. No model call, never the live ledger.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
EVAL="$HERE/cr_ledger_eval.py"
FIX="$HERE/fixtures/ledger.jsonl"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cr-ledger-test.XXXXXX")" || { echo "test-cr-ledger: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
# Never the live ledger, whatever a case forgets to pass.
export CR_LEDGER="$TMP/never.jsonl"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) pass "$1";; *) fail "$1: '$3' not in '$2'";; esac; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP test-cr-ledger: python3 not on PATH"; exit 0; }

CUT=2026-09-10T00:00:00Z
# jget <json-file> <a/b/c> - one value from the --json output.
jget() { python3 -c 'import json,sys
v=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("/"): v=v.get(k) if isinstance(v,dict) else None
print(json.dumps(v) if isinstance(v,(dict,list,bool)) or v is None else v)' "$1" "$2"; }

python3 "$EVAL" --ledger "$FIX" --until "$CUT" --json > "$TMP/out.json" 2> "$TMP/err"; rc=$?
eq "json: exit 0" "$rc" "0"
eq "json: findings up to the cutoff" "$(jget "$TMP/out.json" findings)" "6"
eq "json: a malformed line is counted, not fatal" "$(jget "$TMP/out.json" malformed)" "1"
eq "fold: gpt-x total" "$(jget "$TMP/out.json" critics/codex:gpt-x/n)" "4"
eq "fold: fixed counts as agreed" "$(jget "$TMP/out.json" critics/codex:gpt-x/agreed)" "1"
eq "fold: gpt-x disproved" "$(jget "$TMP/out.json" critics/codex:gpt-x/disproved)" "2"
eq "fold: gpt-x deferred" "$(jget "$TMP/out.json" critics/codex:gpt-x/deferred)" "1"
eq "fold: precision = agreed / (agreed + disproved)" "$(jget "$TMP/out.json" critics/codex:gpt-x/precision)" "0.3333"
eq "join: a different responding model is a different critic" "$(jget "$TMP/out.json" critics/codex:gpt-y/agreed)" "1"
eq "cutoff: an amend after the cutoff is ignored" "$(jget "$TMP/out.json" critics/codex:gpt-y/disproved)" "0"
eq "join: no avail row leaves the slug alone" "$(jget "$TMP/out.json" critics/claude/unadjudicated)" "1"
eq "ci: one PR cannot vary, so no interval" "$(jget "$TMP/out.json" critics/codex:gpt-x/precision_ci)" "null"
eq "reraise: a fingerprint raised at two heads of a branch" "$(jget "$TMP/out.json" reraise/reraised)" "1"
eq "reraise: fingerprinted findings" "$(jget "$TMP/out.json" reraise/fingerprinted)" "3"
eq "deferred: fu_class tally" "$(jget "$TMP/out.json" deferred_class/polish)" "1"
eq "severity: crit row folded" "$(jget "$TMP/out.json" severity/critical/deferred)" "1"
eq "critic x severity: gpt-x suggestions" "$(jget "$TMP/out.json" critic_severity/codex:gpt-x/suggestion/n)" "2"

python3 "$EVAL" --ledger "$FIX" > "$TMP/all.json" --json 2>/dev/null
eq "cutoff: without --until the late finding counts" "$(jget "$TMP/all.json" findings)" "7"

out="$(python3 "$EVAL" --ledger "$FIX" --until "$CUT" 2>&1)"
has "table: a row per critic" "$out" "codex:gpt-x"
has "table: the cutoff is printed" "$out" "$CUT"

python3 "$EVAL" --ledger "$FIX" --until "$CUT" --sample 5 --seed 7 > "$TMP/s1" 2>/dev/null
python3 "$EVAL" --ledger "$FIX" --until "$CUT" --sample 5 --seed 7 > "$TMP/s2" 2>/dev/null
eq "sample: only disproved findings" "$(wc -l < "$TMP/s1" | tr -d ' ')" "2"
eq "sample: seeded, so repeatable" "$(cmp -s "$TMP/s1" "$TMP/s2" && echo same)" "same"
has "sample: carries the reason for the coder" "$(cat "$TMP/s1")" "by design"

ids="$(python3 -c 'import json,sys; print(" ".join(json.loads(l)["id"] for l in open(sys.argv[1])))' "$TMP/s1")"
read -r id1 id2 <<< "$ids"
{ printf 'id\tcritic\tclass\tnote\n'; printf '%s\tcodex:gpt-x\tintent-blind\tx\n' "$id1"; printf '%s\tcodex:gpt-x\tre-raise\ty\n' "$id2"; } > "$TMP/coded.tsv"
python3 "$EVAL" --ledger "$FIX" --until "$CUT" --coded "$TMP/coded.tsv" --json > "$TMP/c.json" 2>"$TMP/cerr"; rc=$?
eq "coded: a valid sample is accepted" "$rc" "0"
eq "coded: class counts" "$(jget "$TMP/c.json" taxonomy/counts/re-raise)" "1"
eq "coded: coded total" "$(jget "$TMP/c.json" taxonomy/n)" "2"

{ printf 'id\tcritic\tclass\tnote\n'; printf 'deadbeef0000\tcodex:gpt-x\tintent-blind\tx\n'; } > "$TMP/bad1.tsv"
python3 "$EVAL" --ledger "$FIX" --until "$CUT" --coded "$TMP/bad1.tsv" >/dev/null 2>&1; rc=$?
eq "coded: an id that is not a disproved finding is refused" "$rc" "2"
{ printf 'id\tcritic\tclass\tnote\n'; printf '%s\tcodex:gpt-x\tnot-a-class\tx\n' "$id1"; } > "$TMP/bad2.tsv"
python3 "$EVAL" --ledger "$FIX" --until "$CUT" --coded "$TMP/bad2.tsv" >/dev/null 2>&1; rc=$?
eq "coded: an undeclared class is refused" "$rc" "2"
{ printf 'id\tcritic\tclass\tnote\n'; printf '%s\tcodex:gpt-y\tintent-blind\tx\n' "$id1"; } > "$TMP/bad3.tsv"
python3 "$EVAL" --ledger "$FIX" --until "$CUT" --coded "$TMP/bad3.tsv" >/dev/null 2>&1; rc=$?
eq "coded: a critic that does not match the ledger is refused" "$rc" "2"

{ printf 'id\tcritic\tclass\tnote\n'; printf '%s\tcodex:gpt-x\tintent-blind\tx\n' "$id1" "$id1"; } > "$TMP/bad4.tsv"
python3 "$EVAL" --ledger "$FIX" --until "$CUT" --coded "$TMP/bad4.tsv" >/dev/null 2>"$TMP/err4"; rc=$?
eq "coded: a duplicate finding id is refused" "$rc" "2"
has "coded: the duplicate is named" "$(cat "$TMP/err4")" "duplicate"

python3 "$EVAL" --ledger "$FIX" --until "$CUT" --sample -1 >/dev/null 2>&1; rc=$?
eq "sample: a negative N is refused" "$rc" "2"

# A fractional-second ts sorts before the whole second as a string, not as a time.
printf '%s\n' '{"kind":"finding","ts":"2026-10-06T20:00:00.500Z","branch":"feat/c","head":"h5","model":"codex","finding_id":"codex-1","severity":"imp","verdict":"","text":"late"}' > "$TMP/frac.jsonl"
python3 "$EVAL" --ledger "$TMP/frac.jsonl" --until 2026-10-06T20:00:00Z --json > "$TMP/frac.json" 2>/dev/null
eq "cutoff: a fractional second after the cut is a time, not a string" "$(jget "$TMP/frac.json" findings)" "0"
python3 "$EVAL" --ledger "$TMP/frac.jsonl" --until 2026-10-06T20:00:01Z --json > "$TMP/frac.json" 2>/dev/null
eq "cutoff: the same finding before a later cut counts" "$(jget "$TMP/frac.json" findings)" "1"
python3 "$EVAL" --ledger "$FIX" --until not-a-time >/dev/null 2>&1; rc=$?
eq "cutoff: an unparseable --until is refused" "$rc" "2"

python3 "$EVAL" --ledger "$TMP/absent.jsonl" >/dev/null 2>&1; rc=$?
eq "usage: a missing ledger is an error" "$rc" "2"

summary_row_path() { python3 -I -c 'import json,sys
d=json.load(open(sys.argv[1])); key=tuple(sys.argv[2:6])
r=[x for x in d["rows"] if (x["slug"],x["responding_model"],x["scope"],x["verdict_source"])==key]
v=r[0] if r else "NO-ROW"
for k in sys.argv[6].split("/"): v=v.get(k) if isinstance(v,dict) else v
print(json.dumps(v) if isinstance(v,(dict,list,bool)) or v is None else v)' "$@"; }
S="$TMP/summary.jsonl"
{
  echo '{"kind":"attempt","ts":"2026-10-01T10:00:00Z","branch":"feat/s1","head":"s1","model":"codex","status":"ok","artifact":"diff","responding_model":"gpt-x"}'
  echo '{"kind":"finding","ts":"2026-10-01T10:00:00Z","branch":"feat/s1","head":"s1","model":"codex","finding_id":"s1-1","severity":"imp","verdict":"","artifact":"diff","perspective":"off"}'
  echo '{"kind":"amend","ts":"2026-10-01T11:00:00Z","branch":"feat/s1","target_head":"s1","finding_id":"s1-1","artifact":"diff","perspective":"off","set":{"verdict":"fixed"},"reason":"fixed","src":"ledger-append"}'
  echo '{"kind":"finding","ts":"2026-10-01T10:00:00Z","branch":"feat/s1","head":"s1","model":"codex","finding_id":"s1-2","severity":"imp","verdict":"agreed","artifact":"diff","perspective":"off"}'
  echo '{"kind":"finding","ts":"2026-10-01T10:00:00Z","branch":"feat/s1","head":"s1","model":"codex","finding_id":"s1-3","severity":"sug","verdict":"","artifact":"diff","perspective":"off"}'
  echo '{"kind":"amend","ts":"2026-10-01T11:00:00Z","branch":"feat/s1","target_head":"s1","finding_id":"s1-3","artifact":"diff","perspective":"off","set":{"verdict":"deferred","fu_class":"polish"},"reason":"later"}'
  echo '{"kind":"finding","ts":"2026-10-01T10:00:00Z","branch":"feat/s1","head":"s1","model":"codex","finding_id":"s1-4","severity":"sug","verdict":"deferred","artifact":"diff","perspective":"off"}'
  echo '{"kind":"finding","ts":"2026-10-01T10:00:00Z","branch":"feat/s1","head":"s1","model":"codex","finding_id":"s1-5","severity":"imp","verdict":"agreed","artifact":"diff","perspective":"off","source":"mystery-import"}'
  echo '{"kind":"attempt","ts":"2026-10-02T10:00:00Z","branch":"feat/s2","head":"s2","model":"codex","status":"ok","artifact":"diff","responding_model":"gpt-y"}'
  echo '{"kind":"finding","ts":"2026-10-02T10:00:00Z","branch":"feat/s2","head":"s2","model":"codex","finding_id":"s2-1","severity":"imp","verdict":"disproved","artifact":"diff","perspective":"off"}'
  echo '{"kind":"finding","ts":"2026-10-03T10:00:00Z","branch":"feat/s3","head":"s3","model":"codex","finding_id":"s3-1","severity":"imp","verdict":"agreed","artifact":"diff","perspective":"off"}'
  echo '{"kind":"finding","ts":"2026-10-04T10:00:00Z","branch":"feat/s4","head":"s4","model":"coderabbit","finding_id":"cr-thread-a","severity":"imp","verdict":"fixed","artifact":"diff","perspective":"off","pr":41,"thread_id":"Ta","source":"cr-thread-recorder"}'
  echo '{"kind":"finding","ts":"2026-10-04T10:00:00Z","branch":"feat/s4","head":"s4","model":"coderabbit","finding_id":"cr-thread-b","severity":"imp","verdict":"fixed","artifact":"diff","perspective":"off","pr":41,"thread_id":"Tb","source":"cr-thread-recorder"}'
  echo '{"kind":"finding","ts":"2026-10-04T10:00:00Z","branch":"feat/s4","head":"s4","model":"coderabbit","finding_id":"cr-thread-c","severity":"imp","verdict":"disproved","artifact":"diff","perspective":"off","pr":41,"thread_id":"Tc","source":"cr-thread-recorder"}'
  echo '{"kind":"finding","ts":"2026-10-04T10:00:00Z","branch":"feat/s4","head":"s4","model":"coderabbit","finding_id":"cr-thread-d","severity":"imp","verdict":"unaddressed","artifact":"diff","perspective":"off","pr":41,"thread_id":"Td","source":"cr-thread-recorder"}'
  echo '{"kind":"finding","ts":"2026-10-04T10:00:00Z","branch":"feat/s4","head":"s4","model":"coderabbit","finding_id":"cr-thread-e","severity":"imp","verdict":"disproved","artifact":"diff","perspective":"off","pr":41,"thread_id":"Te","source":"cr-thread-recorder"}'
  echo '{"kind":"amend","ts":"2026-10-04T12:00:00Z","branch":"feat/s4","target_head":"s4","finding_id":"cr-thread-e","artifact":"diff","perspective":"off","set":{"verdict":"agreed"},"reason":"real; fixed in the next commit","src":"ledger-append"}'
  echo '{"kind":"finding","ts":"2026-10-04T10:00:00Z","branch":"feat/s4","head":"s4","model":"coderabbit-outside","finding_id":"cr-od-1","severity":"imp","verdict":"unaddressed","artifact":"diff","perspective":"off","pr":41,"source":"cr-thread-recorder"}'
  echo '{"kind":"finding","ts":"2026-10-04T10:00:00Z","branch":"feat/s4","head":"s4","model":"coderabbit-outside","finding_id":"cr-od-2","severity":"imp","verdict":"unaddressed","artifact":"diff","perspective":"off"}'
  echo '{"kind":"finding","ts":"2026-10-04T10:00:00Z","branch":"feat/s4","head":"s4","model":"coderabbit-outside","finding_id":"cr-od-3","severity":"imp","verdict":"","artifact":"diff","perspective":"off","pr":41,"source":"cr-thread-recorder"}'
  echo '{"kind":"amend","ts":"2026-10-04T12:00:00Z","branch":"feat/s4","target_head":"s4","finding_id":"cr-od-3","artifact":"diff","perspective":"off","set":{"verdict":"disproved"},"reason":"pre-existing code"}'
  echo '{"kind":"finding","ts":"not-a-time","branch":"feat/s5","head":"s5","model":"codex","finding_id":"s5-1","severity":"imp","verdict":"agreed","artifact":"diff","perspective":"off"}'
} > "$S"
python3 "$EVAL" --ledger "$S" --summary --since 2026-09-01T00:00:00Z --json > "$TMP/sum.json" 2> "$TMP/sum.err"; rc=$?
eq "summary: exit 0" "$rc" "0"
REC=recorded-disposition INF=thread-state-inferred
eq "explicit_fixed_counts_as_agreed: amend fixed + row agreed" "$(summary_row_path "$TMP/sum.json" codex gpt-x diff $REC agreed)" "2"
eq "accept_yield_not_precision: author_agreement over decided" "$(summary_row_path "$TMP/sum.json" codex gpt-x diff $REC author_agreement)" "1.0"
eq "accept_yield_not_precision: acceptance_yield over every finding" "$(summary_row_path "$TMP/sum.json" codex gpt-x diff $REC acceptance_yield)" "0.5"
eq "accept_yield_not_precision: no row field is called precision" "$(python3 -I -c 'import json,sys
print(sorted({k for r in json.load(open(sys.argv[1]))["rows"] for k in r if "precision" in k}))' "$TMP/sum.json")" "[]"
eq "deferred: outside decided, inside coverage" "$(summary_row_path "$TMP/sum.json" codex gpt-x diff $REC adjudication_coverage)" "0.5"
eq "deferred: counted" "$(summary_row_path "$TMP/sum.json" codex gpt-x diff $REC deferred)" "2"
eq "unknown_verdict_source_separate: an unknown writer is its own row" "$(summary_row_path "$TMP/sum.json" codex gpt-x diff unknown total)" "1"
eq "unknown_verdict_source_separate: never author_agreement" "$(summary_row_path "$TMP/sum.json" codex gpt-x diff unknown author_agreement)" "null"
eq "unknown_verdict_source_separate: kept out of the recorded total" "$(summary_row_path "$TMP/sum.json" codex gpt-x diff $REC total)" "4"
eq "model_repin_separate: gpt-y is its own row" "$(summary_row_path "$TMP/sum.json" codex gpt-y diff $REC disproved)" "1"
eq "model_repin_separate: gpt-y agreement" "$(summary_row_path "$TMP/sum.json" codex gpt-y diff $REC author_agreement)" "0.0"
eq "unknown_model_separate: no responding model is its own row" "$(summary_row_path "$TMP/sum.json" codex unknown diff $REC agreed)" "1"
eq "inferred_thread_verdict_separate: recorder rows are a thread-state row" "$(summary_row_path "$TMP/sum.json" coderabbit unknown diff $INF total)" "4"
eq "inferred_thread_verdict_separate: nothing counts as decided" "$(summary_row_path "$TMP/sum.json" coderabbit unknown diff $INF decided)" "null"
eq "inferred_thread_verdict_separate: never author_agreement" "$(summary_row_path "$TMP/sum.json" coderabbit unknown diff $INF author_agreement)" "null"
eq "inferred_thread_verdict_separate: resolved after a change" "$(summary_row_path "$TMP/sum.json" coderabbit unknown diff $INF thread_state/resolved_after_change)" "2"
eq "inferred_thread_verdict_separate: resolved without a change" "$(summary_row_path "$TMP/sum.json" coderabbit unknown diff $INF thread_state/resolved_without_change)" "1"
eq "inferred_thread_verdict_separate: open at merge" "$(summary_row_path "$TMP/sum.json" coderabbit unknown diff $INF thread_state/open)" "1"
eq "explicit_amend_supersedes_inference: the amended thread is a recorded agreement" "$(summary_row_path "$TMP/sum.json" coderabbit unknown diff $REC agreed)" "1"
eq "explicit_amend_supersedes_inference: and only that one" "$(summary_row_path "$TMP/sum.json" coderabbit unknown diff $REC total)" "1"
eq "unaddressed_and_outside_coverage: outside is its own scope, recorder row inferred" "$(summary_row_path "$TMP/sum.json" coderabbit-outside unknown outside-diff $INF thread_state/open)" "1"
eq "unaddressed_and_outside_coverage: unaddressed is unresolved, not decided" "$(summary_row_path "$TMP/sum.json" coderabbit-outside unknown outside-diff $REC unresolved)" "1"
eq "unaddressed_and_outside_coverage: an amended outside finding is decided" "$(summary_row_path "$TMP/sum.json" coderabbit-outside unknown outside-diff $REC disproved)" "1"
eq "unaddressed_and_outside_coverage: coverage is decided over all" "$(summary_row_path "$TMP/sum.json" coderabbit-outside unknown outside-diff $REC adjudication_coverage)" "0.5"
eq "exclusions: thread-state findings named" "$(jget "$TMP/sum.json" exclusions/thread_state_inferred)" "5"
eq "exclusions: unknown-source findings named" "$(jget "$TMP/sum.json" exclusions/unknown_source)" "1"
eq "exclusions: an undated finding is counted, not silently dropped" "$(jget "$TMP/sum.json" exclusions/undated)" "1"
eq "explicit_amend_supersedes_inference: fold keeps the raw source and the amend" "$(python3 -I -c 'import sys
sys.path.insert(0, sys.argv[1]); import cr_ledger_eval as m
rows, _ = m.load(sys.argv[2], None)
f = [x for x in m.fold(rows) if x["text"] == "" and x["branch"] == "feat/s4" and x["verdict_source"] == "recorded-disposition" and x["slug"] == "coderabbit"][0]
print(f["raw_source"], f["raw_verdict"], f["amend_source"])' "$HERE" "$S")" "cr-thread-recorder disproved ledger-append"
eq "summary: gating_only drops suggestions" "$(python3 -I -c 'import sys
sys.path.insert(0, sys.argv[1]); import cr_ledger_eval as m
rows, _ = m.load(sys.argv[2], None)
r = [x for x in m.reviewer_summary(rows, "2026-09-01T00:00:00Z", None, True) if (x["slug"], x["responding_model"], x["verdict_source"]) == ("codex", "gpt-x", "recorded-disposition")][0]
print(r["total"], r["deferred"])' "$HERE" "$S")" "2 0"
python3 "$EVAL" --ledger "$S" --summary --since 2026-10-03T00:00:00Z --json > "$TMP/since.json" 2>/dev/null
eq "summary: --since drops older findings" "$(summary_row_path "$TMP/since.json" codex gpt-x diff $REC total)" "NO-ROW"
python3 "$EVAL" --ledger "$S" --summary --since yesterday >/dev/null 2>&1; rc=$?
eq "summary: an unparseable --since is refused" "$rc" "2"

echo
echo "test-cr-ledger: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
