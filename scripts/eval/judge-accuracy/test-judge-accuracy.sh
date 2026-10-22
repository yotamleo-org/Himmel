#!/usr/bin/env bash
# scripts/eval/judge-accuracy/test-judge-accuracy.sh - suite for the weekly judge-outcome job
# (judge_accuracy.py): the verdict-to-outcome join, the eval-runs row and the adjudication queue.
# Fixture bucket, PR snapshot, main-run snapshot and Jira mirror only: no gh, no model, no live ledger.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
JA="$HERE/judge_accuracy.py"
RUNS="$HERE/../lib/eval_runs.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/judge-accuracy-test.XXXXXX")" || { echo "test-judge-accuracy: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
# Never the live files, whatever a case forgets to pass.
export HIMMEL_EVAL_RUNS_LEDGER="$TMP/never-runs.jsonl"
export HIMMEL_JUDGE_ADJUDICATION="$TMP/never-queue.jsonl"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) pass "$1";; *) fail "$1: '$3' not in '$2'";; esac; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP test-judge-accuracy: python3 not on PATH"; exit 0; }

# field <ledger> <row index> <key>; the key is one metrics/ci/top-level name, looked up whole
field() { python3 -I -c 'import json,sys; r=[json.loads(l) for l in open(sys.argv[1]) if l.strip()][int(sys.argv[2])]
k=sys.argv[3]; v=r["metrics"].get(k, r.get(k)) if not k.startswith("ci:") else r["ci"].get(k[3:])
print(json.dumps(v) if isinstance(v,(dict,list,bool)) or v is None else v)' "$@"; }
rows() { if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi; }

# verdict <qid> <name> <GO|NO-GO> <head> <written-at> <header lines...> -- <evidence lines...>
verdict() {
  local qid="$1" name="$2" v="$3" head="$4" at="$5"; shift 5
  mkdir -p "$TMP/v/$qid"
  {
    printf "# VERDICT %s - %s\n\nwriter-session: s\nwritten-at: %s\n\n## Verdict\n\n**%s** for head \`%s\`.\n\n" \
      "$qid" "$name" "$at" "$v" "$head"
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do printf '%s\n' "$1"; shift; done
    [ $# -gt 0 ] && shift
    printf '\n'
    for l in "$@"; do printf '%s\n' "$l"; done
    printf 'mac: 00\n'
  } >"$TMP/v/$qid/$name.md"
}

verdict q1 judge GO aaa1 2026-10-10T10:00:00Z "pr: 101" "prior: GO" "flipped: n" "model: opus" "effort: high" -- "class: reader-allowlist"
verdict q1a judge GO aaa0 2026-10-10T10:30:00Z "pr: 101" "model: sonnet" "effort: high" -- "class: stale-class"
verdict q2 judge NO-GO bbb1 2026-10-11T10:00:00Z "pr: 102" "prior: GO" "flipped: y" "model: opus" "effort: high" -- "class: other" "class-reason: x"
verdict q2b judge GO bbb2 2026-10-12T10:00:00Z "pr: 102" "prior: GO" "flipped: n" "model: claude-opus-5-5" "effort: high" -- "class: none"
verdict q3 judge NO-GO ccc1 2026-10-12T10:00:00Z "pr: 103" "prior: GO" "flipped: y" "model: opus" "effort: high" -- "class: other" \
  "A console NO-GO on a really-red last reviewed head buys one delta round."
verdict q4 judge NO-GO ddd1 2026-10-13T10:00:00Z "pr: 104" -- "class: shell-parsing"
verdict q5 judge NO-GO eee1 2026-10-14T10:00:00Z "pr: 105" "model: opus" "effort: high" -- "class: option-parsing"
verdict q5b judge GO eee1 2026-10-14T12:00:00Z "pr: 105" "model: opus" "effort: high" -- "class: option-parsing"
verdict go-pr-106 console-go-fff1 GO fff1 2026-10-15T10:00:00Z "pr: 106" "model: unknown" "effort: unknown" -- "console GO"
verdict q7 judge GO abc7 2026-08-01T10:00:00Z "pr: 107" "model: opus" "effort: high" -- "class: none"
verdict q8 judge GO abc8 2026-10-16T10:00:00Z "pr: 108" "model: opus" "effort: high" -- "class: none"
verdict q9 judge GO abd1 2026-10-19T10:00:00Z "pr: 109" "model: opus" "effort: high" -- "class: none"
verdict q10 judge NO-GO abe1 2026-10-18T10:00:00Z "pr: 110" "model: opus" "effort: high" -- "class: other" "class-reason: x"
verdict q11 judge GO abf1 2026-10-18T12:00:00Z "pr: 111" "model: opus" "effort: high" -- "class: none"
verdict q10b judge GO abe1 2026-10-22T10:00:00Z "pr: 110" "model: opus" "effort: high" -- "class: none"
verdict q12 judge GO ab12 2026-09-20T10:00:00Z "pr: 112" "model: opus" "effort: high" -- "class: none"
verdict q12b judge NO-GO ab12 2026-10-16T10:00:00Z "pr: 112" "model: opus" "effort: high" -- "class: other" "class-reason: x"
mkdir -p "$TMP/v/notes"; printf 'a disposition note, no verdict line\n' >"$TMP/v/notes/judge.md"

cat >"$TMP/prs.json" <<'EOF'
[{"number":101,"state":"MERGED","mergedAt":"2026-10-10T11:00:00Z","headRefOid":"aaa1","mergeCommit":{"oid":"m101"}},
 {"number":102,"state":"MERGED","mergedAt":"2026-10-12T11:00:00Z","headRefOid":"bbb2","mergeCommit":{"oid":"m102"}},
 {"number":103,"state":"CLOSED","mergedAt":null,"headRefOid":"ccc1","mergeCommit":null},
 {"number":104,"state":"MERGED","mergedAt":"2026-10-13T11:00:00Z","headRefOid":"ddd1","mergeCommit":{"oid":"m104"}},
 {"number":105,"state":"MERGED","mergedAt":"2026-10-14T13:00:00Z","headRefOid":"eee1","mergeCommit":{"oid":"m105"}},
 {"number":106,"state":"MERGED","mergedAt":"2026-10-15T11:00:00Z","headRefOid":"fff1","mergeCommit":{"oid":"m106"}},
 {"number":107,"state":"MERGED","mergedAt":"2026-08-01T11:00:00Z","headRefOid":"abc7","mergeCommit":{"oid":"m107"}},
 {"number":108,"state":"MERGED","mergedAt":"2026-10-17T11:00:00Z","headRefOid":"abc9","mergeCommit":{"oid":"m108"}},
 {"number":109,"state":"MERGED","mergedAt":"2026-10-22T11:00:00Z","headRefOid":"abd1","mergeCommit":{"oid":"m109"}},
 {"number":110,"state":"MERGED","mergedAt":"2026-10-22T11:00:00Z","headRefOid":"abe1","mergeCommit":{"oid":"m110"}},
 {"number":111,"state":"MERGED","mergedAt":"2026-10-18T11:00:00Z","headRefOid":"abf1","mergeCommit":{"oid":"m111"}},
 {"number":112,"state":"MERGED","mergedAt":"2026-10-16T11:00:00Z","headRefOid":"ab12","mergeCommit":{"oid":"m112"}}]
EOF
cat >"$TMP/runs.json" <<'EOF'
[{"databaseId":501,"headSha":"m102","conclusion":"failure","createdAt":"2026-10-12T11:05:00Z"},
 {"databaseId":503,"headSha":"m105","conclusion":"failure","createdAt":"2026-10-21T05:00:00Z"},
 {"databaseId":502,"headSha":"m101","conclusion":"success","createdAt":"2026-10-10T11:05:00Z"},
 {"databaseId":504,"headSha":"m101","conclusion":"failure","createdAt":"2026-10-11T11:05:00Z"},
 {"databaseId":505,"headSha":"m102","conclusion":"failure","createdAt":""}]
EOF
mkdir -p "$TMP/mirror"
# mirror <key> <type> <labels json> <created> <description>
mirror() {
  printf -- '---\nkey: "%s"\ntype: "%s"\nlabels: %s\ncreated: "%s"\n---\n\n# %s: t\n\n## Description\n\n%s\n' \
    "$1" "$2" "$3" "$4" "$1" "$5" >"$TMP/mirror/$1.md"
}
mirror HIMMEL-9001 Bug '["bug"]' "2026-10-16T09:00:00.000+0200" "Regression after the merge.
caused-by: #101"
mirror HIMMEL-9002 Bug '["bug"]' "2026-10-16T09:00:00.000+0200" "Something broke, maybe since #106 merged."
mirror HIMMEL-9003 Task '[]' "2026-10-16T09:00:00.000+0200" "caused-by: #102"
mirror HIMMEL-9004 Bug '["bug"]' "2026-10-01T09:00:00.000+0200" "Filed before #106 existed."
mirror HIMMEL-9005 Bug '["bug"]' "2026-10-18T09:00:00.000+0200" "caused-by: #108"
mirror HIMMEL-9006 Bug '["bug"]' "2026-10-21T09:00:00.000+0200" "caused-by: #105"
mirror HIMMEL-9000 Bug '["bug"]' "2026-10-17T09:00:00.000+0200" "Seen again after #101 merged."
mirror HIMMEL-9007 Bug '["bug"]' "" "caused-by: #106"

L="$TMP/ledger.jsonl"; Q="$TMP/queue.jsonl"
ja() { python3 -I "$JA" run --verdicts "$TMP/v" --prs "$TMP/prs.json" --main-runs "$TMP/runs.json" --mirror "$TMP/mirror" \
  --queue "$Q" --until 2026-10-21T00:00:00Z --days 28 --ledger "$L"; }

# --- run 1: a GO'd PR with a caused-by bug is an escape in the ledger row --------------------------
out=$(ja 2>&1); rc=$?
eq "run 1: exit 0" "$rc" "0"
eq "run 1: one eval-runs row" "$(rows "$L")" "1"
eq "row: eval" "$(field "$L" 0 eval)" "judge-accuracy"
eq "caused-by bug: the GO'd PR is an escape" "$(field "$L" 0 escapes)" "1"
eq "merged GO'd PRs in the window (console GO counts, out-of-window and GO-less do not)" "$(field "$L" 0 go_merged)" "4"
eq "escape rate" "$(field "$L" 0 escape_rate)" "0.25"
has "escape rate has a Wilson interval" "$(field "$L" 0 ci:escape_rate)" '"lo": 0.0'
eq "flip rate: procedural and prior-less records excluded" "$(field "$L" 0 flip_n)" "3"
eq "flips" "$(field "$L" 0 flips)" "1"
eq "procedural NO-GOs counted apart" "$(field "$L" 0 procedural)" "1"
eq "a NO-GO merged at its own head is overridden, an older GO at that head notwithstanding" "$(field "$L" 0 overridden)" "2"
eq "per class: the escaped PR's class" "$(field "$L" 0 class.reader-allowlist.escapes)" "1"
eq "per model: the last GO's model" "$(field "$L" 0 model.opus.escapes)" "1"
eq "per class: a GO on a superseded head is not attributed" "$(field "$L" 0 class.stale-class.n)" "null"
eq "per model: a GO on a superseded head is not attributed" "$(field "$L" 0 model.sonnet.n)" "null"
eq "coverage: a judge record with no model" "$(field "$L" 0 coverage.no_model)" "1"
eq "coverage: a merged NO-GO'd PR with no GO" "$(field "$L" 0 coverage.merged_without_go)" "1"
eq "coverage: a file with no verdict line" "$(field "$L" 0 coverage.unparsed)" "1"
eq "coverage: a PR merged past its GO'd head or before its GO is not scored" "$(field "$L" 0 coverage.merged_past_go)" "2"
eq "four candidates wait for a ruling" "$(field "$L" 0 pending)" "4"
eq "a row with pending candidates is partial" "$(field "$L" 0 status)" "partial"
has "run 1: prints the escape rate" "$out" "escape_rate"
python3 -I "$RUNS" validate "$L" >/dev/null 2>&1
eq "row: a valid eval-runs row" "$?" "0"

# --- the queue: one row per candidate, shown until ruled ---------------------------------------------
eq "queue: four candidate rows" "$(rows "$Q")" "4"
q=$(python3 -I "$JA" queue --queue "$Q" 2>&1)
has "queue: the bug that cites the PR without caused-by" "$q" "esc:106:bug:HIMMEL-9002"
has "queue: the red main run on the merge commit" "$q" "esc:102:red-main:501"
has "queue: the NO-GO overturned at the same head" "$q" "nogo:q5/judge"
case "$q" in *HIMMEL-9004*|*HIMMEL-9003*) fail "queue: a bug filed before the merge or a non-bug is no candidate";;
  *) pass "queue: a bug filed before the merge or a non-bug is no candidate";; esac
case "$q" in *esc:101:bug:*) fail "queue: a cause a caused-by bug settles asks for no ruling";;
  *) pass "queue: a cause a caused-by bug settles asks for no ruling";; esac
has "queue: a settled PR's red main run still asks for its ci-selection cause" "$q" "esc:101:red-main:504"
case "$q" in *nogo:q10/*) fail "queue: a GO from until on overturns no NO-GO";;
  *) pass "queue: a GO from until on overturns no NO-GO";; esac
case "$q" in *red-main:505*) fail "queue: a main run with no creation time is no candidate";;
  *) pass "queue: a main run with no creation time is no candidate";; esac
ja >/dev/null 2>&1
eq "rerun: exit 0" "$?" "0"
eq "rerun: a queued candidate is not queued again" "$(rows "$Q")" "4"

# --- rulings: once each, and the next run counts them ------------------------------------------------
rule_ok() {
  python3 -I "$JA" rule "$1" "$2" --evidence "fixture ruling" --queue "$Q" >/dev/null 2>&1
  eq "rule $1: exit 0" "$?" "0"
}
rule_ok esc:102:red-main:501 S
rule_ok esc:106:bug:HIMMEL-9002 P
rule_ok nogo:q5/judge N
rule_ok esc:101:red-main:504 N
python3 -I "$JA" rule esc:102:red-main:501 N --evidence again --queue "$Q" >/dev/null 2>&1
eq "a ruled candidate is never re-asked" "$?" "1"
python3 -I "$JA" rule esc:999:bug:HIMMEL-1 S --evidence x --queue "$Q" >/dev/null 2>&1
eq "an unknown candidate cannot be ruled" "$?" "1"
python3 -I "$JA" rule nogo:q5/judge X --evidence x --queue "$Q" >/dev/null 2>&1
eq "a ruling is S, P or N" "$?" "2"
eq "queue: nothing pending" "$(python3 -I "$JA" queue --queue "$Q" 2>&1)" ""
ja >/dev/null 2>&1
eq "run 2: a third row (the rerun wrote the second)" "$(rows "$L")" "3"
eq "run 2: ruled, so ok" "$(field "$L" 2 status)" "ok"
eq "run 2: S ruling is a sure escape" "$(field "$L" 2 escapes)" "2"
eq "run 2: P ruling is plausible" "$(field "$L" 2 escapes_plausible)" "3"
eq "run 2: a red main run is a ci-selection escape" "$(field "$L" 2 cause.ci-selection.escapes)" "1"
eq "run 2: an N on an overturned NO-GO is no false NO-GO" "$(field "$L" 2 false_nogo)" "0"
eq "run 2: same series as run 1" "$(field "$L" 2 confighash)" "$(field "$L" 0 confighash)"

# --- refused input ---------------------------------------------------------------------------------
python3 -I "$JA" run --verdicts "$TMP/nope" --prs "$TMP/prs.json" --mirror "$TMP/mirror" --queue "$Q" --no-ledger >/dev/null 2>&1
eq "a missing verdict dir is refused" "$?" "2"
python3 -I "$JA" run --verdicts "$TMP/v" --prs "$TMP/prs.json" --mirror "$TMP/nope" --queue "$Q" --no-ledger >/dev/null 2>&1
eq "a missing Jira mirror is refused" "$?" "2"

echo "judge-accuracy: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
