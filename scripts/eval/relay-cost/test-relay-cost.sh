#!/usr/bin/env bash
# scripts/eval/relay-cost/test-relay-cost.sh - the relay-cost eval's checker, pricing and runner.
# No model call: `claude` is a stub (RELAY_COST_CLAUDE) and bank-preflight a stub (RELAY_COST_PREFLIGHT).
# Run: bash scripts/eval/relay-cost/test-relay-cost.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PY="$HERE/relay_cost.py"
RUN="$HERE/run.sh"
fails=0
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (want '$2' got '$3')"; fails=$((fails + 1)); fi
}
WORK="$(mktemp -d "${TMPDIR:-/tmp}/relay-cost-test.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
FX="$WORK/messages.json"

python3 -I "$PY" gen --out "$FX" >/dev/null
check "gen writes 9 synthetic fixtures, 3 per kind" "9 3 3 3 True" "$(python3 -I -c 'import json,sys,collections
d = json.load(open(sys.argv[1])); c = collections.Counter(f["kind"] for f in d["fixtures"])
print(len(d["fixtures"]), c["succession"], c["go"], c["ruling"], d["synthetic"])' "$FX")"

# --- the checker, and its negative control: a deliberately wrong delivery must FAIL
deliver() { # <id> <to> <message>: write a delivery file, print its path
    python3 -I -c 'import json,sys; json.dump({"to": sys.argv[2], "message": sys.argv[3]}, open(sys.argv[1], "w"))' "$WORK/d.json" "$2" "$3"
    echo "$WORK/d.json"
}
fget() { python3 -I -c 'import json,sys
for f in json.load(open(sys.argv[1]))["fixtures"]:
    if f["id"] == sys.argv[2]: sys.stdout.write(f[sys.argv[3]])' "$FX" "$1" "$2"; }
verdict() { python3 -I "$PY" check --fixtures "$FX" --id "$1" --delivery "$2" >/dev/null 2>&1 && echo PASS || echo FAIL; }
for id in succession-2 go-2 ruling-3; do
    to="$(fget "$id" to)"; exp="$(fget "$id" expected)"
    check "$id: the exact delivery passes" PASS "$(verdict "$id" "$(deliver x "$to" "$exp")")"
    check "$id: negative control, wrong target fails" FAIL "$(verdict "$id" "$(deliver x "${to}-other" "$exp")")"
    check "$id: negative control, one word changed fails" FAIL "$(verdict "$id" "$(deliver x "$to" "${exp/the/a}")")"
    check "$id: negative control, truncated message fails" FAIL "$(verdict "$id" "$(deliver x "$to" "${exp:0:40}")")"
    check "$id: negative control, extra text appended fails" FAIL "$(verdict "$id" "$(deliver x "$to" "$exp Please confirm.")")"
done
printf 'not json' >"$WORK/bad.json"
check "a malformed delivery fails" FAIL "$(verdict go-1 "$WORK/bad.json")"
# the wrong token: a succession delivery that quotes another worker's token
wrong="$(fget succession-1 expected)"; wrong="${wrong/AA-N9001-0a1b2c3d/BB-N9002-1b2c3d4e}"
check "succession: negative control, another worker's token fails" FAIL "$(verdict succession-1 "$(deliver x "$(fget succession-1 to)" "$wrong")")"

# --- price: a stream with known usage
printf '%s\n' '{"type":"system"}' '{"type":"result","is_error":false,"total_cost_usd":0.002,"result":"ok","usage":{"input_tokens":10,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"output_tokens":20}}' >"$WORK/s.jsonl"
check "price: cold cost-eq = 10 + 1000*0.1 + 200*1.25 + 20*5" "460.0" "$(python3 -I "$PY" price "$WORK/s.jsonl" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["cost_eq_cold"])')"
check "price: warm cost-eq prices the whole prefix as a cache read" "230.0" "$(python3 -I "$PY" price "$WORK/s.jsonl" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["cost_eq_warm"])')"
printf '%s\n' '{"type":"system"}' >"$WORK/cut.jsonl"
check "price: a stream with no result event is an error row" "True" "$(python3 -I "$PY" price "$WORK/cut.jsonl" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["error"])')"

# --- run.sh: the unbilled arms over every fixture
export RELAY_COST_PREFLIGHT="$WORK/preflight.sh"
printf '#!/usr/bin/env bash\necho PROCEED\n' >"$RELAY_COST_PREFLIGHT"
bash "$RUN" --out "$WORK/o1" --fixtures "$FX" --arms script,path >"$WORK/o1.log" 2>&1
check "run.sh script,path exits 0" "0" "$?"
check "script arm: the real relay-batch.sh and the verbatim send pass all 9 fixtures" "9" "$(grep -c '^script PASS' "$WORK/o1.log")"
check "path arm: all 9 fixtures pass" "9" "$(grep -c '^path PASS' "$WORK/o1.log")"
check "no model arm, no cost" "0" "$(python3 -I -c 'import json,glob,sys; print(sum(json.load(open(p))["cost_eq_cold"] for p in glob.glob(sys.argv[1] + "/*/*.result.json")))' "$WORK/o1")"
check "report names the options with percentages" "1" "$(python3 -I "$PY" report --runs "$WORK/o1" --fixtures "$FX" | grep -c '^| script | 9 | 100% |')"
check "a model arm without HIMMEL_BILLED_OK exits 2" "2" "$(bash "$RUN" --out "$WORK/o2" --fixtures "$FX" --arms haiku >/dev/null 2>&1; echo $?)"

# --- run.sh: the model arms against a stub claude
CL="$WORK/claude"; STUB="$WORK/stub.py"
printf '#!/usr/bin/env bash\nexec python3 -I "%s" "$@"\n' "$STUB" >"$CL"
cat >"$STUB" <<'EOF'
import json, os, sys
sys.path.insert(0, os.environ["RELAY_COST_DIR"])
import relay_cost
prompt = sys.argv[sys.argv.index("-p") + 1]
if prompt.startswith("SUCCESSION-RELAY"):
    f = dict(p.split("=", 1) for p in prompt.split()[1:])
    d = {"to": f["worker"], "message": relay_cost.succession_text(f["sender"], f["successor"], f["nonce"])}
else:
    head, body = prompt.split("\n", 1)
    d = {"to": head[len("DELIVER "):], "message": body}
if os.environ.get("STUB_MODE") == "paraphrase":
    d["message"] = d["message"].replace("the", "a", 1)
open(os.environ["STUB_LOG"], "a").write(sys.argv[sys.argv.index("--model") + 1] + "\n")
print(json.dumps({"type": "result", "is_error": False, "total_cost_usd": 0.001, "result": "```json\n" + json.dumps(d) + "\n```",
                  "usage": {"input_tokens": 10, "cache_read_input_tokens": 1000, "cache_creation_input_tokens": 200, "output_tokens": 20}}))
EOF
chmod +x "$CL"
export RELAY_COST_CLAUDE="$CL" RELAY_COST_DIR="$HERE" STUB_LOG="$WORK/stub.log" HIMMEL_BILLED_OK=1
: >"$STUB_LOG"
bash "$RUN" --out "$WORK/o3" --fixtures "$FX" --arms sonnet,haiku >"$WORK/o3.log" 2>&1
check "model arms exit 0" "0" "$?"
check "sonnet arm: 9 calls on claude-sonnet-5-5, all pass" "9 9" "$(grep -c '^claude-sonnet-5-5$' "$STUB_LOG") $(grep -c '^sonnet PASS' "$WORK/o3.log")"
check "haiku arm: 9 calls on claude-haiku-5-5, all pass" "9 9" "$(grep -c '^claude-haiku-5-5$' "$STUB_LOG") $(grep -c '^haiku PASS' "$WORK/o3.log")"
check "the result row carries the priced usage" "460.0" "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["cost_eq_cold"])' "$WORK/o3/sonnet/go-1.result.json")"
: >"$STUB_LOG"
bash "$RUN" --out "$WORK/o3" --fixtures "$FX" --arms sonnet,haiku >/dev/null 2>&1
check "a rerun skips every finished (arm, fixture): no new call" "0" "$(wc -l <"$STUB_LOG" | tr -d ' ')"
STUB_MODE=paraphrase bash "$RUN" --out "$WORK/o4" --fixtures "$FX" --arms haiku >"$WORK/o4.log" 2>&1
check "negative control through run.sh: a paraphrasing model fails every fixture" "9" "$(grep -c '^haiku FAIL' "$WORK/o4.log")"
: >"$STUB_LOG"
bash "$RUN" --out "$WORK/o5" --fixtures "$FX" --arms sonnet,haiku --max-calls 4 >/dev/null 2>&1
check "--max-calls 4 stops at 4 calls and exits 3" "3 4" "$? $(wc -l <"$STUB_LOG" | tr -d ' ')"
printf '#!/usr/bin/env bash\necho BANK-STALE\n' >"$RELAY_COST_PREFLIGHT"
: >"$STUB_LOG"
bash "$RUN" --out "$WORK/o6" --fixtures "$FX" --arms sonnet >/dev/null 2>&1; rc6=$?
check "a preflight that does not print PROCEED stops before any call (exit 3)" "3 0" "$rc6 $(wc -l <"$STUB_LOG" | tr -d ' ')"

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
