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
[ "$held" != noscore ] || { echo '{"type": "result", "is_error": false, "total_cost_usd": 0.01}'; exit 0; }
jq -cn --argjson h "${held:-0}" --arg cost "${LQ_FAKE_COST:-0.01}" '{type: "result", is_error: false}
  + (if $cost == "none" then {} else {total_cost_usd: ($cost | tonumber)} end)
  + {structured_output: {claims: ([range(1; 5) | {key: "C\(.)", value: {holds: (. <= $h), evidence: "e"}}]
    + [("S", "T", "H") as $p | range(1; 5) | {key: "\($p)\(.)", value: {holds: true, evidence: "e"}}] | from_entries)}}'
FAKE
printf '#!/usr/bin/env bash\necho "claudex $*" >>"$LQ_FAKE_LOG.lane"\nexec "$LQ_CLAUDE_BIN" "$@"\n' >"$TMP/bin/claude-codex"
printf '#!/usr/bin/env bash\necho "openrouter $OPENROUTER_MODEL" >>"$LQ_FAKE_LOG.lane"\nprintf "%%s\\t%%s\\n" "$PWD" "$*" >>"$LQ_FAKE_LOG.or"\nexec "$LQ_CLAUDE_BIN" "$@"\n' >"$TMP/bin/claude-openrouter"
printf '#!/usr/bin/env bash\necho "balance=9.5:credit spend=?"\n' >"$TMP/bin/orcost"
printf '#!/usr/bin/env bash\necho PROCEED\n' >"$TMP/bin/preflight"
chmod +x "$TMP/bin/"*
export LQ_CLAUDE_BIN="$TMP/bin/claude" LQ_CLAUDEX_BIN="$TMP/bin/claude-codex" LQ_OPENROUTER_BIN="$TMP/bin/claude-openrouter" \
  LQ_METERED_PROBE="$TMP/bin/orcost" LQ_PREFLIGHT="$TMP/bin/preflight" LQ_REPO="$TMP" \
  LQ_FAKE_LOG="$TMP/fake.log" LQ_FAKE_GRADES="$TMP/grades" CLAUDEX_LANE_OK=1

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
G2=(--judge2-model google/gemini-x --judge2-effort high --judge2-lane openrouter --cap-factor 1)
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
check "an unmapped openrouter slug's vendor is its maker prefix" '[ "$(python3 "$HERE/lq_stats.py" vendor nvidia/nemotron-a NVIDIA/nemotron-b | tr "\n" " ")" = "nvidia nvidia " ]'
mkdir -p "$TMP/fxempty"; : >"$TMP/fxempty/runs.jsonl"; cp "$FX"/*.judge-packet.md "$TMP/fxempty/"
: >"$TMP/fake.log"
bash "$RUN" calibration "$TMP/fxempty" "${G1[@]}" "${G2[@]}" --json --no-ledger >/dev/null 2>"$TMP/empty.err"; rc=$?
check "an empty runs.jsonl is refused before any call" '[ "$(find "$TMP/fxempty" -name "*.judge-packet.md" | wc -l)" -eq 6 ] && [ "$rc" -eq 64 ] && grep -qF "no model under test" "$TMP/empty.err" && [ ! -s "$TMP/fake.log" ]'
# each fixture has one bad run beside five named ones: a missing model, then an empty one
for kind in missing empty; do
  if [ "$kind" = missing ]; then f='if .task == "t1" then del(.model) else . end'; else f='if .task == "t1" then .model = "" else . end'; fi
  mkdir -p "$TMP/fx$kind-model"; cp "$FX"/*.judge-packet.md "$TMP/fx$kind-model/"
  jq -c "$f" "$FX/runs.jsonl" >"$TMP/fx$kind-model/runs.jsonl"
  # shellcheck disable=SC2034  # jqrc is read by check's eval
  jqrc=$?
  : >"$TMP/fake.log"
  bash "$RUN" calibration "$TMP/fx$kind-model" "${G1[@]}" "${G2[@]}" --json --no-ledger >/dev/null 2>"$TMP/$kind-model.err"; rc=$?
  check "a run whose model under test is $kind is refused before any call" '[ "$jqrc" -eq 0 ] && [ "$(find "$TMP/fx$kind-model" -name "*.judge-packet.md" | wc -l)" -eq 6 ] && [ "$(jq -s "[.[] | select((.model // \"\") == \"\")] | length" "$TMP/fx$kind-model/runs.jsonl")" -eq 1 ] && [ "$(wc -l <"$TMP/fx$kind-model/runs.jsonl")" -eq 6 ] && [ "$rc" -eq 64 ] && grep -qF "no model under test" "$TMP/$kind-model.err" && [ ! -s "$TMP/fake.log" ]'
done

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
bash "$RUN" calibration "$FX" "${G1[@]}" --judge2-model google/gemini-neg --judge2-effort high --judge2-lane openrouter --cap-factor 1 \
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

echo "5. the grader spend cap fails closed"
fresh() { rm -rf "$TMP/fx2"; mkdir "$TMP/fx2"; cp "$FX/runs.jsonl" "$FX"/*.judge-packet.md "$TMP/fx2/"; : >"$TMP/fake.log"; : >"$TMP/fake.log.or"; }
fresh
bash "$RUN" calibration "$TMP/fx2" "${G1[@]}" --judge2-model google/gemini-x --judge2-lane openrouter --json --no-ledger >/dev/null 2>"$TMP/cf.err"; rc=$?
check "an unpriced openrouter grader without --cap-factor is refused before any call" '[ "$rc" -eq 64 ] && grep -qF "no PRICES row" "$TMP/cf.err" && [ ! -s "$TMP/fake.log" ]'
fresh
bash "$RUN" calibration "$TMP/fx2" "${G1[@]}" --judge2-model google/gemini-x --judge2-lane openrouter --cap-factor 2 \
  --max-usd 1 --json --no-ledger >/dev/null 2>/dev/null
check "--cap-factor scales the openrouter call's budget from what is left" '[ "$(head -1 "$TMP/fake.log.or" | grep -o -- "--max-budget-usd [0-9.]*")" = "--max-budget-usd 1.88" ]'
fresh
env -u CLAUDEX_LANE_OK bash "$RUN" calibration "$TMP/fx2" "${G1[@]}" "${G2[@]}" --json --no-ledger >/dev/null 2>"$TMP/cx.err"; rc=$?
check "a claudex grader without CLAUDEX_LANE_OK=1 exits 3 before any call" '[ "$rc" -eq 3 ] && grep -qF "CLAUDEX_LANE_OK=1" "$TMP/cx.err" && [ ! -s "$TMP/fake.log" ]'
fresh
bash "$RUN" calibration "$TMP/fx2" "${G1[@]}" "${G2[@]}" --max-usd 0.02 --json --no-ledger >/dev/null 2>"$TMP/cap.err"
check "the grader budget stops the pass once --max-usd is spent" '[ "$(wc -l <"$TMP/fake.log")" -eq 2 ] && grep -qF "grader budget spent" "$TMP/cap.err"'
fresh
# shellcheck disable=SC2034  # rows0 is read by check's eval
rows0="$(wc -l <"$HIMMEL_EVAL_RUNS_LEDGER")"
bash "$RUN" calibration "$TMP/fx2" "${G1[@]}" "${G2[@]}" --max-usd 0.02 --json >/dev/null 2>"$TMP/part.err"; rc=$?
check "a stopped pass exits 75 and records no calibration row, so a partial result never heads the page" '[ "$rc" -eq 75 ] && [ "$(wc -l <"$TMP/fake.log")" -eq 2 ] && grep -qF "grader budget spent" "$TMP/part.err" && [ "$(wc -l <"$HIMMEL_EVAL_RUNS_LEDGER")" -eq "$rows0" ] && grep -qF "not recorded" "$TMP/part.err"'
fresh
LQ_FAKE_COST=none bash "$RUN" calibration "$TMP/fx2" "${G1[@]}" "${G2[@]}" --json --no-ledger >/dev/null 2>"$TMP/unk.err"
check "a claudex grader with no reported cost stops the pass, never counted as 0" '[ "$(wc -l <"$TMP/fake.log")" -eq 1 ] && grep -qF "left its cost unknown" "$TMP/unk.err"'
fresh
printf '#!/usr/bin/env bash\nn=$(cat "$LQ_FAKE_BAL" 2>/dev/null || echo 0); echo $((n + 1)) >"$LQ_FAKE_BAL"\nawk -v n="$n" '"'"'BEGIN{printf "balance=%%.2f:credit spend=?\\n", 10 - n * 0.05}'"'"'\n' >"$TMP/bin/orcost-drop"
chmod +x "$TMP/bin/orcost-drop"
LQ_FAKE_BAL="$TMP/bal" LQ_METERED_PROBE="$TMP/bin/orcost-drop" bash "$RUN" calibration "$TMP/fx2" "${G1[@]}" "${G2[@]}" \
  --max-usd 0.16 --json --no-ledger >/dev/null 2>"$TMP/delta.err"
check "an openrouter call counts the metered drop when it exceeds the reported cost" '[ "$(grep -c "^google/gemini-x " "$TMP/fake.log")" -eq 2 ] && grep -qF "graders spent 0.1600 USD" "$TMP/delta.err"'
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/bin/orcost-dead"
printf '#!/usr/bin/env bash\nn=$(cat "$LQ_FAKE_BAL" 2>/dev/null || echo 0); echo $((n + 1)) >"$LQ_FAKE_BAL"\n[ "$n" -eq 0 ] || exit 1\necho "balance=9.5:credit spend=?"\n' >"$TMP/bin/orcost-once"
chmod +x "$TMP/bin/orcost-dead" "$TMP/bin/orcost-once"
fresh
LQ_METERED_PROBE="$TMP/bin/orcost-dead" bash "$RUN" calibration "$TMP/fx2" "${G1[@]}" "${G2[@]}" --json --no-ledger >/dev/null 2>"$TMP/dead.err"
check "an unpriced openrouter grader with an unreadable meter stops before its call" '[ "$(grep -c "^google/gemini-x " "$TMP/fake.log")" -eq 0 ] && grep -qF "meter is unreadable" "$TMP/dead.err"'
fresh; rm -f "$TMP/bal"
LQ_FAKE_BAL="$TMP/bal" LQ_METERED_PROBE="$TMP/bin/orcost-once" bash "$RUN" calibration "$TMP/fx2" "${G1[@]}" "${G2[@]}" --json --no-ledger >/dev/null 2>"$TMP/once.err"
check "an unpriced openrouter grader whose meter goes unreadable after a call stops the pass" '[ "$(grep -c "^google/gemini-x " "$TMP/fake.log")" -eq 1 ] && grep -qF "meter is unreadable after google/gemini-x" "$TMP/once.err" && ! grep -qF "stopping before" "$TMP/once.err"'
fresh
bash "$RUN" calibration "$TMP/fx2" "${G1[@]}" "${G2[@]}" --cap-factor 1.2.3 --json --no-ledger >/dev/null 2>"$TMP/cfx.err"; rc=$?
check "a malformed --cap-factor is refused before any call" '[ "$rc" -eq 64 ] && grep -qF -- "--cap-factor must be a positive number" "$TMP/cfx.err" && [ ! -s "$TMP/fake.log" ]'

echo "6. a selected run left ungraded stops the pass"
fresh; rm "$TMP/fx2/t3.judge-packet.md"
# shellcheck disable=SC2034  # rows0 is read by check's eval
rows0="$(wc -l <"$HIMMEL_EVAL_RUNS_LEDGER")"
bash "$RUN" calibration "$TMP/fx2" "${G1[@]}" "${G2[@]}" --json >/dev/null 2>"$TMP/nopk.err"; rc=$?
check "a selected run with no judge packet stops the pass: exit 75, no calibration row" '[ "$rc" -eq 75 ] && grep -qF "t3 has no judge packet" "$TMP/nopk.err" && [ "$(grep -c "^gpt-x " "$TMP/fake.log")" -eq 2 ] && [ "$(wc -l <"$HIMMEL_EVAL_RUNS_LEDGER")" -eq "$rows0" ]'
fresh
printf 't1 4\nt2 4\nt3 noscore\nt4 4\nt5 3\nt6 2\n' >"$TMP/grades/gpt-bad"
# shellcheck disable=SC2034  # rows0 is read by check's eval
rows0="$(wc -l <"$HIMMEL_EVAL_RUNS_LEDGER")"
bash "$RUN" calibration "$TMP/fx2" --judge1-model gpt-bad --judge1-effort high --judge1-lane claudex "${G2[@]}" --json >/dev/null 2>"$TMP/nosc.err"; rc=$?
check "a grader that exits 0 with no decodable score stops the pass: exit 75, no calibration row" '[ "$rc" -eq 75 ] && grep -qF "gpt-bad on t3 returned no decodable score" "$TMP/nosc.err" && [ "$(grep -c "^gpt-bad " "$TMP/fake.log")" -eq 3 ] && [ "$(wc -l <"$HIMMEL_EVAL_RUNS_LEDGER")" -eq "$rows0" ]'

echo "test-lane-quality-calibration: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
