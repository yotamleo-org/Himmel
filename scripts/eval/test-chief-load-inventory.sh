#!/usr/bin/env bash
# scripts/eval/test-chief-load-inventory.sh - hermetic suite for chief-load-inventory.py.
# A synthetic project dir with one chief transcript and one non-chief transcript. No model call.
#  1. only transcripts whose custom-title ends in the suffix are read;
#  2. split assistant blocks with one message id count as ONE request;
#  3. a MERGED worker message is a worker-MERGED episode and its requests are costed;
#  4. close-wrapped-worker.sh without wrap-merged.sh counts as a hand wrap;
#  5. no matching session exits 2.
#
# check() evals its condition, so the single quotes are deliberate.
# shellcheck disable=SC2016,SC2034,SC2028
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
CLI="$HERE/chief-load-inventory.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/chief-load-test.XXXXXX")" || { echo "test-chief-load-inventory: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

P="$TMP/proj"; mkdir -p "$P"
{
    echo '{"type":"custom-title","customTitle":"X-2026-10-14Z-roadmap-chief"}'
    echo '{"type":"user","message":{"role":"user","content":"Another Claude session sent a message:\n<cross-session-message from=\"s\" from-name=\"worker\" from-mode=\"prompting\">\nMERGED #2566 N2088"}}'
    echo '{"type":"assistant","message":{"id":"m1","usage":{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":5},"content":[{"type":"text","text":"x"}]}}'
    echo '{"type":"assistant","message":{"id":"m1","usage":{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":5},"content":[{"type":"tool_use","name":"Bash","input":{"command":"bash scripts/handover/chief-kit/close-wrapped-worker.sh /h/worker.md"}}]}}'
    echo '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}'
    echo '{"type":"assistant","message":{"id":"m2","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5},"content":[{"type":"text","text":"done"}]}}'
} > "$P/console.jsonl"
{
    echo '{"type":"custom-title","customTitle":"HIMMEL-1-N1-worker-2026-10-14"}'
    echo '{"type":"assistant","message":{"id":"z1","usage":{"input_tokens":9},"content":[{"type":"text","text":"x"}]}}'
} > "$P/worker.jsonl"

python3 "$CLI" --projects "$P" >"$TMP/out" 2>"$TMP/err"; rc=$?
check "exits 0" '[ "$rc" = 0 ]'
check "reads only the chief transcript" 'grep -q "^sessions: 1 " "$TMP/out"'
check "split blocks dedupe to 2 requests in one MERGED episode" 'grep -qE "^worker-MERGED +1 episodes +2 requests +2.0 req/episode" "$TMP/out"'
check "the Bash request is a wrap-close, the other think-only" 'grep -qE "^wrap-close +1 " "$TMP/out" && grep -qE "^think-only +1 " "$TMP/out"'
check "close-wrapped-worker.sh alone is a hand wrap" 'grep -q "hand wraps.*: 1$" "$TMP/out"'
check "input-eq is input + creation + 0.1 x read (m1 = 202, m2 = 1)" 'python3 "$CLI" --projects "$P" --json | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if abs(sum(v[1] for v in d[\"by_trigger\"].values())-203)<1e-6 else 1)"'

{
    echo '{"type":"custom-title","customTitle":"Y-2026-10-14Z-roadmap-chief"}'
    echo '{"type":"assistant","message":{"id":"v1","usage":{"input_tokens":1},"content":[{"type":"tool_use","name":"Bash","input":{"command":"bash scripts/handover/chief-kit/verdict-go.sh q GO abc"}}]}}'
} > "$P/verdict.jsonl"
check "verdict-go.sh is not also counted as go.sh" 'python3 "$CLI" --projects "$P" --match "^Y-" --json | python3 -c "import json,sys; d=json.load(sys.stdin)[\"script_calls\"]; sys.exit(0 if d.get(\"verdict-go.sh\")==1 and not d.get(\"go.sh\") else 1)"'

python3 "$CLI" --projects "$P" --match 'no-such-session' >/dev/null 2>"$TMP/err2"; rc=$?
check "no matching session exits 2" '[ "$rc" = 2 ]'

echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
