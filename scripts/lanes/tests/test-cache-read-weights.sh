#!/usr/bin/env bash
# scripts/lanes/tests/test-cache-read-weights.sh - cache reads are priced per model.
# One table (scripts/lanes/lib/cache-read-weights.tsv) feeds the bash, python and JS readers; the
# unknown-model default is the 0.1 row in lib/burn-weights.sh. Drift check: no listed copy
# may carry a flat 0.1 cache-read price of its own.
# Platform guard: bash 3.2+, jq, python3, node; drives worker-burn.sh and the readers.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
LANES="$HERE/.."
REPO="$(cd "$LANES/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cache-read-weights-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) pass "$1";; *) fail "$1: '$3' not in '$2'";; esac; }

unset WORKER_SESSION_BURN_W_CACHE_READ HIMMEL_WORKER_SESSION_PROFILE 2>/dev/null || true

# --- bash reader --------------------------------------------------------------
w() { ( . "$LANES/lib/burn-weights.sh"; burn_cache_read_weight "$1" ) 2>/dev/null; }
eq "opus 5.5 reads at 0.05" "$(w claude-opus-5-5-20261001)" "0.05"
eq "sonnet 5.5 reads at 0.05" "$(w claude-sonnet-5-5)" "0.05"
eq "fable 5.1 reads at 0.025" "$(w claude-fable-5-1)" "0.025"
eq "fable 5.2 reads at 0.025" "$(w claude-fable-5-2)" "0.025"
eq "haiku 5.5 reads at 0.1" "$(w claude-haiku-5-5)" "0.1"
eq "an unknown model reads at the 0.1 default" "$(w claude-zzz-9)" "0.1"
eq "an empty model reads at the 0.1 default" "$(w '')" "0.1"
eq "a flat env override wins for every model" "$( ( WORKER_SESSION_BURN_W_CACHE_READ=1; export WORKER_SESSION_BURN_W_CACHE_READ; . "$LANES/lib/burn-weights.sh"; burn_cache_read_weight claude-fable-5-1 ) 2>/dev/null)" "1"

# --- worker-burn prices a transcript per model --------------------------------
mk() { # <file> <model> - one assistant call: 1000 cache-read tokens, nothing else
    printf '{"type":"assistant","message":{"id":"m1","model":"%s","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":0,"cache_read_input_tokens":1000,"cache_creation_input_tokens":0,"output_tokens":0}}}\n' "$2" > "$1"
}
mk "$TMP/opus.jsonl" claude-opus-5-5-20261001
mk "$TMP/fable.jsonl" claude-fable-5-1
mk "$TMP/mystery.jsonl" claude-mystery-1
ob=$(bash "$LANES/worker-burn.sh" --raw "$TMP/opus.jsonl")
fb=$(bash "$LANES/worker-burn.sh" --raw "$TMP/fable.jsonl")
mb=$(bash "$LANES/worker-burn.sh" --raw "$TMP/mystery.jsonl")
has "opus fixture: cost-eq prices 1000 reads at 0.05" "$ob" "cost-eq=50 "
has "opus fixture: the line names the pricing model" "$ob" "price-model=claude-opus-5-5-20261001"
has "fable fixture: cost-eq prices 1000 reads at 0.025" "$fb" "cost-eq=25 "
has "unknown model: priced at 0.1" "$mb" "cost-eq=100 "
has "unknown model: counted" "$mb" "unknown-model-calls=1"
has "known model: zero unknown calls" "$ob" "unknown-model-calls=0"

# --- python reader --------------------------------------------------------------
cat > "$TMP/py-reader.py" <<EOF
import sys
sys.path.insert(0, "$REPO/scripts/lib")
import burn_weights as b
print(b.cache_read_weight("claude-opus-5-5-20261001"), b.cache_read_weight("claude-fable-5-1"), b.cache_read_weight("claude-zzz-9"), b.cache_read_weight(None))
EOF
eq "python reader matches the table" "$(python3 -I "$TMP/py-reader.py" 2>&1)" "0.05 0.025 0.1 0.1"

# --- JS reader ------------------------------------------------------------------
cat > "$TMP/js-reader.mjs" <<EOF
import { cacheReadWeight } from "$REPO/scripts/lib/burn-weights.mjs";
console.log([cacheReadWeight("claude-opus-5-5-20261001"), cacheReadWeight("claude-fable-5-1"), cacheReadWeight("claude-zzz-9"), cacheReadWeight(null)].join(" "));
EOF
eq "js reader matches the table" "$(node "$TMP/js-reader.mjs" 2>&1)" "0.05 0.025 0.1 0.1"

# --- drift check: no copy carries its own flat cache-read price -----------------
flat_re='0\.1 \* \(typeof|0\.1 \* p\b|0\.1 *\* *(u\.get|u\.cache|cache_read|t\.cacheRead|cr\b)|cache_read[a-z_]*"?\)? *\* *0\.1|W_CR *= *float|cacheRead: *0\.1|\* *0\.1 \* *cache'
COPIES="scripts/eval/chief-load-inventory.py scripts/eval/context-replay.py scripts/eval/autocompact-ab.py scripts/eval/handover-cost.py scripts/eval/graphify-ab/summarize.py scripts/eval/retrieval-eval/answer-ab.py scripts/eval/worker-digest/worker-digest.ts scripts/config-ui/agui/lane.ts scripts/api-lane/cache-report.mjs"
hits=""
for c in $COPIES; do
    if [ ! -f "$REPO/$c" ]; then hits="$hits missing:$c"; continue; fi
    if grep -Eq "$flat_re" "$REPO/$c"; then hits="$hits $c"; fi
done
eq "no listed copy carries a flat 0.1 cache-read price" "${hits# }" ""
printf 'x = inp * W_IN + cr * 0.1 + cc\ncost = u.get("input_tokens", 0) + 0.1 * u.get("cache_read_input_tokens", 0)\n' > "$TMP/flat-copy.py"
if grep -Eq "$flat_re" "$TMP/flat-copy.py"; then pass "negative control: a flat 0.1 fixture copy is caught"; else fail "negative control: a flat 0.1 fixture copy is NOT caught"; fi

echo "cache-read-weights: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
