#!/usr/bin/env bash
# test-vocab-expand.sh -- a retrieval question asked in one fleet vocabulary also asks it in the
# other. Docs use both console and chief, leg and worker, so "how does a worker report a blocker to
# the chief" missed every doc written as "leg" and "console". vocab-expand.py turns the question into
# a qmd query document with one lex: line per registry swap; a question naming no registry word, or
# one that already is a document, passes through unchanged. Reads the real registry; no qmd needed.
#
# Platform guard: python3 and bash 3.2-safe.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VX="$HERE/vocab-expand.py"
FAILS=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS+1)); }
nl='
'
doc() { python3 -I "$VX" doc "$1" "$2"; }
argv() { python3 -I "$VX" argv "$@" | tr '\0' '|'; }

# V1: a new-vocabulary question also asks it in the old one; query keeps the question as vec.
got="$(doc query "how does the chief start a worker")"
want="lex: chief start worker${nl}lex: console start leg${nl}vec: how does the chief start a worker"
if [ "$got" = "$want" ]; then pass "V1 new terms gain an old-vocabulary lex line"
else fail "V1 got='$got'"; fi

# V2: search is lex-only: no vec line.
got="$(doc search "how does a leg report a blocker to the console")"
want="lex: leg report blocker console${nl}lex: worker report blocker chief"
if [ "$got" = "$want" ]; then pass "V2 search document has lex lines only"
else fail "V2 got='$got'"; fi

# V3: a question mixing both vocabularies is asked wholly in each, plurals and capitals kept.
got="$(doc search "Legs and chiefs")"
want="lex: Legs chiefs${nl}lex: Workers chiefs${nl}lex: Legs consoles"
if [ "$got" = "$want" ]; then pass "V3 mixed question gives one line per direction"
else fail "V3 got='$got'"; fi

# V4: a question naming no registry word passes through unchanged.
got="$(doc query "how long does the prompt cache keep a prefix warm")"
if [ "$got" = "how long does the prompt cache keep a prefix warm" ]; then pass "V4 no registry word, unchanged"
else fail "V4 got='$got'"; fi

# V5: a question that already is a query document, or a lex line would reject, passes through.
got="$(doc query "lex: console worker")|$(doc search 'the "chief worker')|$(doc query "chief -worker")"
if [ "$got" = 'lex: console worker|the "chief worker|chief -worker' ]; then pass "V5 document, odd quote and negation unchanged"
else fail "V5 got='$got'"; fi

# V6: a phrase already in the new vocabulary is not grown ("parallel wave" never "parallel parallel wave").
got="$(doc search "who starts a parallel wave")"
want="lex: starts parallel wave${nl}lex: starts wave"
if [ "$got" = "$want" ]; then pass "V6 new phrase kept, old phrase added"
else fail "V6 got='$got'"; fi

# V7: an expanded search runs as query with --no-rerank, its flags and their values kept in order.
got="$(argv search -c himmel --files -n 5 "how does a worker report a blocker")"
want="query|-c|himmel|--files|-n|5|--no-rerank|--|lex: worker report blocker${nl}lex: leg report blocker|"
if [ "$got" = "$want" ]; then pass "V7 expanded search becomes a lex-only query without rerank"
else fail "V7 got='$got'"; fi

# V8: a question with no registry word, a flag value naming one, and any other verb keep their argv.
got="$(argv search -n5 --min-score 0.3 "the prompt cache")$(argv get -c console leg.md)$(argv query --intent "the chief" "prompt cache")"
want="search|-n5|--min-score|0.3|the prompt cache|get|-c|console|leg.md|query|--intent|the chief|prompt cache|"
if [ "$got" = "$want" ]; then pass "V8 unexpanded argv unchanged"
else fail "V8 got='$got'"; fi

# V9: the registry's other-sense rows are the lane-worker names graphify must not alias.
got="$(python3 -I -c 'import importlib.util as u, sys; s = u.spec_from_file_location("vx", sys.argv[1]); m = u.module_from_spec(s); s.loader.exec_module(m); print(" ".join(sorted(m.other_sense())))' "$VX")"
if [ "$got" = "await-glm-worker reconcile-workers stop-worker" ]; then pass "V9 other-sense names read from the registry"
else fail "V9 got='$got'"; fi

# V10: the six old/new question pairs for the qmd-quality eval are a valid golden set whose
# expected docs exist (scripts/eval/qmd-quality/run-eval.ts --golden <this file>).
GV="$HERE/../eval/qmd-quality/fixtures/golden-vocabulary.jsonl"
if command -v bun >/dev/null 2>&1; then
  got="$(bun -e 'const { readJsonl, validateGolden } = await import(process.argv[1]); const g = readJsonl(process.argv[2]); console.log(g.length, validateGolden(g) ?? "valid", g.flatMap((r) => r.expect).filter((p) => !require("node:fs").existsSync(process.argv[3] + "/" + p.replace(/^himmel\//, ""))).join(" ") || "all-present")' \
    "$HERE/../eval/qmd-quality/score.ts" "$GV" "$HERE/../.." 2>&1)"
  if [ "$got" = "12 valid all-present" ]; then pass "V10 vocabulary golden set: 12 rows, validateGolden-clean, expected docs present"
  else fail "V10 got='$got'"; fi
else
  echo "  skip: V10 vocabulary golden set (bun not on PATH)"
fi

got="$(doc search "how does the waiter wake the chief")"
want="lex: waiter wake chief${nl}lex: waiter wake console"
if [ "$got" = "$want" ]; then pass "V11 lex line drops filler words"
else fail "V11 got='$got'"; fi

got="$(doc query "claude -p mode")|$(doc query "how does the waiter wake")"
if [ "$got" = 'claude -p mode|how does the waiter wake' ]; then pass "V12 a query naming no registry word keeps qmd's own expansion, filler or dash word or not"
else fail "V12 got='$got'"; fi

vxpy() { python3 -I -c 'import importlib.util, sys; s = importlib.util.spec_from_file_location("vx", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m); print(eval(sys.argv[2], {"m": m}))' "$VX" "$1"; }
got="$(vxpy 'm.shape_vec("claude -p --bg mode")')|$(vxpy 'm.shape_lex("claude -p --bg mode", quote_flags=True)')|$(vxpy 'm.shape_lex("claude -p mode")')"
if [ "$got" = 'claude --bg mode|claude "-p" "--bg" mode|claude -p mode' ]; then pass "V15 vec drops a single-dash word, lex quotes dash words only when asked"
else fail "V15 got='$got'"; fi

got="$(doc search "how does the waiter wake -p")|$(doc search "how does the waiter wake")"
if [ "$got" = 'how does the waiter wake -p|how does the waiter wake' ]; then pass "V16 a search naming no registry word runs as given, so qmd search keeps its own limits and scores"
else fail "V16 got='$got'"; fi

got="$(vxpy 'm.shape_lex("what is \"the end\" mode")')|$(vxpy 'm.shape_lex("how does the")')"
if [ "$got" = '"the end" mode|how does the' ]; then pass "V13 quoted phrase kept, all-filler question whole"
else fail "V13 got='$got'"; fi

got="$(vxpy 'm.shape_lex("what is (\"state of the art\") mode")')"
if [ "$got" = '("state of the art") mode' ]; then pass "V14 quoted phrase inside punctuation keeps its filler words"
else fail "V14 got='$got'"; fi

if [ "$FAILS" -ne 0 ]; then echo "$FAILS FAILURES"; exit 1; fi
echo "ALL PASS"
