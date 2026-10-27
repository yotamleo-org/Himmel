#!/usr/bin/env bash
# scripts/eval/lane-quality/test-lane-quality-calibration.sh - hermetic suite for
# `run.sh calibration` with cross-vendor graders. No real model
# call: a fake claude grades each packet from a fixed table, and fake claudex
# and OpenRouter launchers log their lane and hand the call to it.
#  1. a grader that shares a vendor with a model under test, with the first
#     grader or (the tie-breaker) with either grader is refused, before any call;
#  2. Cohen's kappa on the per-run verdict equals the hand-computed value, and
#     two graders that always disagree get kappa <= 0;
#  3. the tie-breaker is called once per disagreeing run, never for an agreeing one;
#  4. the printed --judge-twice flip counts equal the flips the fixture records.
#
# check() evals its condition, so the single quotes are deliberate.
# shellcheck disable=SC2016
set -u
export HIMMEL_BILLED_OK=1   # stubbed graders only; the guarded script refuses a bare run
HERE="$(cd "$(dirname "$0")" && pwd)"
RUN="$HERE/run.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/lq-calibration-test.XXXXXX")" || { echo "test-lane-quality-calibration: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export HIMMEL_EVAL_RUNS_LEDGER="$TMP/eval-runs.jsonl"   # never the live ledger
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# Fake claude: a grader call reads "packet <stem>" from its packet, looks up
# how many correctness claims hold for that stem in $TMP/grades/<model>, and
# answers with claims (every S, T and H claim holds). It logs "<model> <stem>".
mkdir -p "$TMP/bin" "$TMP/grades"
cat >"$TMP/bin/claude" <<'FAKE'
#!/usr/bin/env bash
model=""; prev=""
for a in "$@"; do [ "$prev" != --model ] || model="$a"; prev="$a"; done
stem="$(sed -n 's/^packet //p' | head -1)"
echo "$model $stem" >>"$LQ_FAKE_LOG"
held="$(awk -v s="$stem" '$1 == s { print $2 }' "$LQ_FAKE_GRADES/$(printf '%s' "$model" | tr '/' '_')")"
jq -cn --argjson h "${held:-0}" '{type: "result", is_error: false, total_cost_usd: 0.01,
  structured_output: {claims: ([range(1; 5) | {key: "C\(.)", value: {holds: (. <= $h), evidence: "e"}}]
    + [("S", "T", "H") as $p | range(1; 5) | {key: "\($p)\(.)", value: {holds: true, evidence: "e"}}] | from_entries)}}'
FAKE
printf '#!/usr/bin/env bash\necho "claudex $*" >>"$LQ_FAKE_LOG.lane"\nexec "$LQ_CLAUDE_BIN" "$@"\n' >"$TMP/bin/claude-codex"
printf '#!/usr/bin/env bash\necho "openrouter $OPENROUTER_MODEL" >>"$LQ_FAKE_LOG.lane"\nprintf "%%s\\t%%s\\n" "$PWD" "$*" >>"$LQ_FAKE_LOG.or"\nexec "$LQ_CLAUDE_BIN" "$@"\n' >"$TMP/bin/claude-openrouter"
printf '#!/usr/bin/env bash\necho "balance=9.5:credit spend=?"\n' >"$TMP/bin/orcost"
printf '#!/usr/bin/env bash\necho PROCEED\n' >"$TMP/bin/preflight"
chmod +x "$TMP/bin/"*
export LQ_CLAUDE_BIN="$TMP/bin/claude" LQ_CLAUDEX_BIN="$TMP/bin/claude-codex" LQ_OPENROUTER_BIN="$TMP/bin/claude-openrouter" \
  LQ_METERED_PROBE="$TMP/bin/orcost" LQ_PREFLIGHT="$TMP/bin/preflight" LQ_REPO="$TMP" \
  LQ_FAKE_LOG="$TMP/fake.log" LQ_FAKE_GRADES="$TMP/grades"

# Six runs of one Anthropic arm, judged by the stored (Anthropic) judge, t1-t4 judged twice.
# Grader 1 passes t1-t4 and fails t5-t6; grader 2 passes t1-t3 and t6. They
# disagree on t4 and t6: po = 4/6, pe = (4/6)(4/6) + (2/6)(2/6) = 20/36, so
# kappa = (24/36 - 20/36) / (16/36) = 0.25. The tie-breaker passes both,
# siding with grader 1 on t4 and grader 2 on t6.
FX="$TMP/fx"; mkdir -p "$FX"
row() { # task correctness [correctness-b claim-flips]
  jq -nc --arg t "$1" --argjson c "$2" --argjson b "${3:-null}" --argjson f "${4:-null}" '{run_id: "fx", lane: "native",
    model: "claude-haiku-5-5", effort: "high", task: $t, rep: 1, accept_ok: ($c == 5), judge_model: "claude-opus-5-5",
    judge_effort: "high", judge: {correctness: $c, scope_discipline: 5, test_quality: 5, honesty: 5}}
    + (if $b == null then {} else {judge_b: {correctness: $b, scope_discipline: 5, test_quality: 5, honesty: 5},
       judge_flips: {claims: $f, criteria: $f}} end)'
}
{ row t1 5 5 0; row t2 5 5 1; row t3 5 3 2; row t4 3 3 0; row t5 3; row t6 5; } >"$FX/runs.jsonl"
for s in t1 t2 t3 t4 t5 t6; do echo "packet $s" >"$FX/$s.judge-packet.md"; done
printf 't1 4\nt2 4\nt3 4\nt4 4\nt5 3\nt6 2\n' >"$TMP/grades/gpt-x"
printf 't1 4\nt2 4\nt3 4\nt4 3\nt5 3\nt6 4\n' >"$TMP/grades/google_gemini-x"
printf 't1 3\nt2 3\nt3 3\nt4 3\nt5 4\nt6 4\n' >"$TMP/grades/google_gemini-neg"
printf 't1 4\nt2 4\nt3 4\nt4 4\nt5 4\nt6 4\n' >"$TMP/grades/deepseek_deepseek-x"
G1=(--judge1-model gpt-x --judge1-effort high --judge1-lane claudex)
G2=(--judge2-model google/gemini-x --judge2-effort high --judge2-lane openrouter)
TB=(--tiebreak-model deepseek/deepseek-x --tiebreak-effort high --tiebreak-lane openrouter)

echo "1. a grader from a vendor already in the comparison is refused before any call"
refused() { # name pattern args...
  # shellcheck disable=SC2034  # pat is read by check's eval
  local name="$1" pat="$2" rc; shift 2
  : >"$TMP/fake.log"
  bash "$RUN" calibration "$FX" "$@" --json --no-ledger >/dev/null 2>"$TMP/refuse.err"; rc=$?
  check "$name" '[ "$rc" -eq 64 ] && grep -qF -- "$pat" "$TMP/refuse.err" && [ ! -s "$TMP/fake.log" ]'
}
refused "a second grader from the vendor under test exits 64" "same vendor (anthropic) as the model under test" \
  "${G1[@]}" --judge2-model claude-sonnet-5-5 --judge2-effort high
refused "a second grader from the first grader's vendor exits 64" "same vendor (openai) as the first grader" \
  "${G1[@]}" --judge2-model gpt-y --judge2-effort high --judge2-lane claudex
refused "the stored judge cannot be the first grader of its own vendor's arm" "first grader 'claude-opus-5-5' is the same vendor (anthropic) as the model under test" \
  "${G2[@]}"
refused "a tie-breaker from either grader's vendor exits 64" "same vendor (google) as the second grader" \
  "${G1[@]}" "${G2[@]}" --tiebreak-model google/gemini-y --tiebreak-effort high --tiebreak-lane openrouter
refused "a tie-breaker needs a second grader" "--tiebreak-model needs --judge2-model" "${G1[@]}" "${TB[@]}"
check "vendor is the maker, not the model: opus, sonnet and haiku are one vendor" '[ "$(python3 "$HERE/lq_stats.py" vendor claude-opus-5-5 sonnet claude-haiku-5-5 gpt-6.1-sol google/gemini-3-pro deepseek/deepseek-v4 | tr "\n" " ")" = "anthropic anthropic anthropic openai google deepseek " ]'

echo "2. Cohen's kappa on the per-run verdict"
: >"$TMP/fake.log"; : >"$TMP/fake.log.lane"; : >"$TMP/fake.log.or"
bash "$RUN" calibration "$FX" "${G1[@]}" "${G2[@]}" "${TB[@]}" --max-usd 1 --json >"$TMP/cal.json" 2>"$TMP/cal.err"; rc=$?
cp "$TMP/fake.log" "$TMP/full.log"
check "the cross-vendor calibration exits 0" '[ "$rc" -eq 0 ]'
[ "$rc" -eq 0 ] || sed 's/^/    cal: /' "$TMP/cal.err"
check "kappa equals the hand-computed 0.25 over 6 runs, 4 agreeing" 'jq -e ".metrics.verdict_kappa == 0.25 and .metrics.n_verdict == 6 and .metrics.verdict_agree == 4" "$TMP/cal.json" >/dev/null'
check "each grader runs on its own lane at its effort" 'grep -qx "claudex .*--model gpt-x --effort high.*" "$TMP/fake.log.lane" && grep -qx "openrouter google/gemini-x" "$TMP/fake.log.lane" && grep -qx "openrouter deepseek/deepseek-x" "$TMP/fake.log.lane"'
# shellcheck disable=SC2034  # WT is read by check's eval
WT="$(git -C "$HERE" rev-parse --show-toplevel)"
check "an openrouter grader runs bare from a removed scratch dir inside this checkout" 'awk -F "\t" -v wt="$WT/.lq-judge." "index(\$1, wt) != 1 || \$2 !~ /^--bare -p / { bad = 1 } END { exit bad || NR == 0 }" "$TMP/fake.log.or" && ! compgen -G "$WT/.lq-judge.*" >/dev/null'
check "only the openrouter lane is bare" 'grep -q "^claudex " "$TMP/fake.log.lane" && ! grep -q -- "^claudex .*--bare" "$TMP/fake.log.lane"'
check "the row names every grader with its effort, lane and vendor" 'jq -e "[.config.graders[] | \"\(.role) \(.model) \(.effort) \(.lane) \(.vendor)\"] == [\"grader1 gpt-x high claudex openai\", \"grader2 google/gemini-x high openrouter google\", \"tiebreak deepseek/deepseek-x high openrouter deepseek\"] and .config.model_graded == true and .config.models == [\"claude-haiku-5-5\"]" "$TMP/cal.json" >/dev/null'
check "the calibration row is a valid eval-runs row" 'python3 "$HERE/../lib/eval_runs.py" validate "$HIMMEL_EVAL_RUNS_LEDGER" >/dev/null'
: >"$TMP/fake.log"
bash "$RUN" calibration "$FX" "${G1[@]}" --judge2-model google/gemini-neg --judge2-effort high --judge2-lane openrouter \
  --json --no-ledger >"$TMP/neg.json" 2>/dev/null
check "graders that always disagree get kappa at or below 0" 'jq -e ".metrics.verdict_agree == 0 and .metrics.verdict_kappa <= 0" "$TMP/neg.json" >/dev/null'
kap() { python3 -c 'import sys, json; sys.path.insert(0, sys.argv[1]); import lq_stats; print(lq_stats.cohen_kappa(json.loads(sys.argv[2]), json.loads(sys.argv[3])))' "$HERE" "$1" "$2"; }
check "cohen kappa: identical raters = 1, one constant rater = None" '[ "$(kap "[true,false]" "[true,false]")" = 1.0 ] && [ "$(kap "[true,true]" "[true,true]")" = None ]'

echo "3. the tie-breaker sees only the disagreements"
check "the tie-breaker is called once for t4 and once for t6, never for an agreeing run" '[ "$(grep "^deepseek/deepseek-x " "$TMP/full.log" | sort | tr "\n" ,)" = "deepseek/deepseek-x t4,deepseek/deepseek-x t6," ]'
check "the tie-breaker outcome is counted per side" 'jq -e ".metrics.tiebreak_sent == 2 and .metrics.tiebreak_grader1 == 1 and .metrics.tiebreak_grader2 == 1 and .metrics.tiebreak_missing == 0" "$TMP/cal.json" >/dev/null'
: >"$TMP/fake.log"
bash "$RUN" calibration "$FX" "${G1[@]}" "${G2[@]}" "${TB[@]}" --no-ledger >"$TMP/cal.md" 2>/dev/null
check "a rerun reuses every stored grade" '[ ! -s "$TMP/fake.log" ]'
check "the report states the tie-breaker count and outcome" 'grep -qF "Tie-breaker deepseek/deepseek-x: 2 disagreements sent; sided with grader 1 in 1, grader 2 in 1, 0 without a result" "$TMP/cal.md"'
printf '%s\n' "$FX/t1.judge-packet.md" "$FX/t2.judge-packet.md" "$FX/t3.judge-packet.md" "$FX/t5.judge-packet.md" >"$TMP/sample.txt"
: >"$TMP/fake.log"
bash "$RUN" calibration "$FX" --judge1-model gpt-z --judge1-lane claudex "${G2[@]}" --sample "$TMP/sample.txt" \
  --json --no-ledger >"$TMP/sample.json" 2>/dev/null
check "--sample grades and counts only the listed packets" 'jq -e ".metrics.n_verdict == 4 and .metrics.n_twice == 3" "$TMP/sample.json" >/dev/null && [ "$(grep -c "^gpt-z " "$TMP/fake.log")" = 4 ] && ! grep -q " t6$" "$TMP/fake.log"'

echo "4. the --judge-twice flip rate"
check "verdict flips: t3 only, 1 of the 4 runs judged twice" 'jq -e ".metrics.n_twice == 4 and .metrics.verdict_flips == 1 and .metrics.verdict_flip_rate == 0.25" "$TMP/cal.json" >/dev/null'
check "claim flips are the recorded judge_flips: 3 of 4 x 16 claims" 'jq -e ".metrics.claim_flips == 3 and .metrics.claim_flip_rate == (3 / 64)" "$TMP/cal.json" >/dev/null'
check "the report prints the flip rate" 'grep -qF "judge-twice flips (stored judge claude-opus-5-5): verdict 1 of 4 runs (0.250), claims 3 of 64 (0.047)" "$TMP/cal.md"'

echo "test-lane-quality-calibration: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
