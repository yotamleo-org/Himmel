#!/usr/bin/env bash
# Tests for guard-subagent-model.sh: a missing model
# is a DENY for every subagent_type except fork, the SUBAGENT_MODEL_OK=1 escape
# hatch, and fail-open on malformed input.
#
# Usage: bash scripts/hooks/test-guard-subagent-model.sh
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
# Pure bash + jq over a temp sandbox; NOT ported to native PowerShell. A test
# harness needs no .ps1 twin (project convention: a documented platform guard
# suffices for a test fixture) — it exercises the bash hook above, so it runs
# wherever that hook runs.
set -uo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline; see test-guard-implementor-dispatch.sh's identical helper for the
# SIGPIPE-under-pipefail rationale.
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/guard-subagent-model.sh"
[ -x "$HOOK" ] || chmod +x "$HOOK" 2>/dev/null || true

# Resolve bash ONCE from the suite's own unmodified PATH, before the
# missing-jq case hands `env` a narrowed one — an env-relative "bash" would
# otherwise be resolved through the NARROWED PATH it is about to test with,
# which can make bash itself unfindable (127) rather than exercising the
# hook's own jq-missing fail-open path. Same lesson as
# test-guard-implementor-dispatch.sh's BASH_ABS.
BASH_ABS=$(command -v bash)
[ -n "$BASH_ABS" ] || { echo "FATAL: cannot resolve bash on PATH" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/himmel-subagent-model-guard.XXXXXX")"
[ -n "$TMP" ] || { echo "FATAL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "ok   $label (rc=$actual)"
        pass=$((pass + 1))
    else
        echo "FAIL $label — expected rc=$expected, got rc=$actual"
        fail=$((fail + 1))
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if grepq "$haystack" -F "$needle"; then
        echo "ok   $label"
        pass=$((pass + 1))
    else
        echo "FAIL $label — missing '$needle'"
        echo "  actual: $haystack"
        fail=$((fail + 1))
    fi
}

assert_empty() {
    local label="$1" actual="$2"
    if [ -z "$actual" ]; then
        echo "ok   $label"
        pass=$((pass + 1))
    else
        echo "FAIL $label — expected empty, got: $actual"
        fail=$((fail + 1))
    fi
}

payload() {
    # payload <subagent_type> <model>  (either may be empty string)
    jq -nc --arg st "$1" --arg m "$2" \
        '{tool_name:"Agent",session_id:"sess-test",tool_input:{subagent_type:$st,description:"d",prompt:"p",model:$m}}'
}

payload_no_model_field() {
    jq -nc --arg st "$1" \
        '{tool_name:"Agent",session_id:"sess-test",tool_input:{subagent_type:$st,description:"d",prompt:"p"}}'
}

payload_no_subagent_field() {
    jq -nc --arg m "$1" \
        '{tool_name:"Agent",session_id:"sess-test",tool_input:{description:"d",prompt:"p",model:$m}}'
}

payload_model_null() {
    # payload_model_null <subagent_type> — model is a genuine JSON null
    jq -nc --arg st "$1" \
        '{tool_name:"Agent",session_id:"sess-test",tool_input:{subagent_type:$st,description:"d",prompt:"p",model:null}}'
}

payload_subagent_null() {
    # payload_subagent_null <model> — subagent_type is a genuine JSON null
    jq -nc --arg m "$1" \
        '{tool_name:"Agent",session_id:"sess-test",tool_input:{subagent_type:null,description:"d",prompt:"p",model:$m}}'
}

run_hook() {
    local name="$1" json="$2"; shift 2
    # env without -i inherits the operator's ambient environment.
    # Pin the knob the hook reads to its off baseline BEFORE "$@" so an
    # operator's exported SUBAGENT_MODEL_OK=1 can never leak into a case that doesn't ask for it -- env applies
    # repeated assignments in order, so a call-site override in "$@" still wins.
    printf '%s' "$json" | env SUBAGENT_MODEL_OK=0 "$@" "$BASH_ABS" "$HOOK" >"$TMP/out-$name" 2>"$TMP/err-$name"
    echo "$?"
}

combined_output() {
    cat "$TMP/out-$1" "$TMP/err-$1" 2>/dev/null
}

echo "=== deny cases: any subagent_type but fork, no model ==="

RC1=$(run_hook gp-no-model "$(payload general-purpose '')")
assert_rc "general-purpose with empty model is DENIED (rc=2)" 2 "$RC1"
assert_contains "deny names general-purpose" "general-purpose" "$(cat "$TMP/err-gp-no-model")"
assert_contains "deny tells the operator to pass a model" "explicit model" "$(cat "$TMP/err-gp-no-model")"
assert_contains "deny points at /lanes" "/lanes" "$(cat "$TMP/err-gp-no-model")"
assert_contains "deny names the bypass" "SUBAGENT_MODEL_OK=1" "$(cat "$TMP/err-gp-no-model")"
assert_contains "deny emits a structured deny decision" '"permissionDecision":"deny"' "$(cat "$TMP/out-gp-no-model")"

RC1B=$(run_hook gp-no-model-field "$(payload_no_model_field general-purpose)")
assert_rc "general-purpose with model field entirely absent is DENIED (rc=2)" 2 "$RC1B"

RC1C=$(run_hook gp-whitespace-model "$(payload general-purpose '   ')")
assert_rc "general-purpose with whitespace-only model is DENIED (rc=2)" 2 "$RC1C"

RC1D=$(run_hook no-subagent-no-model "$(payload_no_subagent_field '')")
assert_rc "no subagent_type + no model is DENIED (rc=2)" 2 "$RC1D"

RC1E=$(run_hook explore-no-model "$(payload Explore '')")
assert_rc "typed agent (Explore) with no model is DENIED (rc=2)" 2 "$RC1E"
assert_contains "typed deny names the type" "Explore" "$(cat "$TMP/err-explore-no-model")"

RC1F=$(run_hook judge-ro-no-model "$(payload console-judge-ro '')")
assert_rc "typed agent (console-judge-ro) with no model is DENIED (rc=2)" 2 "$RC1F"

RC1G=$(run_hook plugin-agent-no-model "$(payload_no_model_field example-plugin:reviewer)")
assert_rc "plugin-namespaced agent with no model is DENIED (rc=2)" 2 "$RC1G"

# an explicit JSON null model is the same as an omitted one.
NULL_MODEL=$(jq -nc '{tool_name:"Agent",session_id:"s",tool_input:{subagent_type:"Explore",model:null}}')
RC1H=$(run_hook null-model "$NULL_MODEL")
assert_rc "explicit null model is DENIED like an omitted one (rc=2)" 2 "$RC1H"

echo ""
echo "=== explicit JSON null counts as no model (trips, not fail-open) ==="

RC1I=$(run_hook gp-model-null "$(payload_model_null general-purpose)")
assert_rc "general-purpose with model null is DENIED (rc=2)" 2 "$RC1I"
assert_contains "model-null deny names general-purpose" "general-purpose" "$(cat "$TMP/err-gp-model-null")"
assert_contains "model-null deny emits a structured deny decision" '"permissionDecision":"deny"' "$(cat "$TMP/out-gp-model-null")"

RC1J=$(run_hook subagent-null-no-model "$(payload_subagent_null '')")
assert_rc "subagent_type null + empty model is DENIED (rc=2)" 2 "$RC1J"
assert_contains "subagent_type-null deny names the no-type shape" "<no-subagent_type>" "$(cat "$TMP/err-subagent-null-no-model")"

SUBAGENT_NULL_NO_MODEL_FIELD=$(jq -nc '{tool_name:"Agent",session_id:"s",tool_input:{subagent_type:null,description:"d",prompt:"p"}}')
RC1K=$(run_hook subagent-null-model-absent "$SUBAGENT_NULL_NO_MODEL_FIELD")
assert_rc "subagent_type null + model absent is DENIED (rc=2)" 2 "$RC1K"

BOTH_NULL=$(jq -nc '{tool_name:"Agent",session_id:"s",tool_input:{subagent_type:null,model:null}}')
RC1L=$(run_hook both-null "$BOTH_NULL")
assert_rc "both subagent_type and model null is DENIED (rc=2)" 2 "$RC1L"

RC1M=$(run_hook fork-model-null "$(payload_model_null fork)")
assert_rc "fork with model null is allowed (rc=0)" 0 "$RC1M"
assert_empty "fork with model null: no output" "$(combined_output fork-model-null)"

RC1N=$(run_hook gp-model-null-override "$(payload_model_null general-purpose)" SUBAGENT_MODEL_OK=1)
assert_rc "SUBAGENT_MODEL_OK=1 lets a model-null dispatch through (rc=0)" 0 "$RC1N"

RC1O=$(run_hook subagent-null-with-model "$(payload_subagent_null sonnet)")
assert_rc "subagent_type null WITH a model is silent (rc=0)" 0 "$RC1O"
assert_empty "subagent_type null with model: no output" "$(combined_output subagent-null-with-model)"

echo ""
echo "=== no-deny cases ==="

RC3=$(run_hook gp-with-model "$(payload general-purpose sonnet)")
assert_rc "general-purpose WITH a model is silent (rc=0)" 0 "$RC3"
assert_empty "general-purpose with model: no output" "$(combined_output gp-with-model)"

RC4=$(run_hook specialist-with-model "$(payload Explore haiku)")
assert_rc "typed agent WITH a model is silent (rc=0)" 0 "$RC4"
assert_empty "typed agent with model: no output" "$(combined_output specialist-with-model)"

RC4B=$(run_hook fork-no-model "$(payload fork '')")
assert_rc "fork with no model is allowed (rc=0)" 0 "$RC4B"
assert_empty "fork with no model: no output" "$(combined_output fork-no-model)"

RC4C=$(run_hook fork-no-model-field "$(payload_no_model_field fork)")
assert_rc "fork with model field absent is allowed (rc=0)" 0 "$RC4C"

RC4D=$(run_hook fork-with-model "$(payload fork opus)")
assert_rc "fork with an explicit model is allowed (rc=0)" 0 "$RC4D"

echo "=== escape hatch ==="

RC5=$(run_hook override "$(payload general-purpose '')" SUBAGENT_MODEL_OK=1)
assert_rc "SUBAGENT_MODEL_OK=1 lets an unnamed-model dispatch through (rc=0)" 0 "$RC5"
assert_empty "override: no stdout" "$(cat "$TMP/out-override")"
assert_contains "override warns about the override itself" "SUBAGENT_MODEL_OK=1" "$(cat "$TMP/err-override")"

echo ""
echo "=== fail-open on malformed / non-Agent input ==="

RC7=$(run_hook malformed "not-json{{{")
assert_rc "malformed input allows (rc=0)" 0 "$RC7"
assert_empty "malformed input: silent" "$(combined_output malformed)"

RC8=$(run_hook empty-input "")
assert_rc "empty stdin allows (rc=0)" 0 "$RC8"
assert_empty "empty stdin: silent" "$(combined_output empty-input)"

NON_AGENT=$(jq -nc '{tool_name:"Bash",session_id:"s",tool_input:{command:"ls"}}')
RC9=$(run_hook non-agent "$NON_AGENT")
assert_rc "non-Agent tool_name allows (rc=0)" 0 "$RC9"
assert_empty "non-Agent tool_name: silent" "$(combined_output non-agent)"

NO_TOOL_INPUT=$(jq -nc '{tool_name:"Agent",session_id:"s"}')
RC10=$(run_hook no-tool-input "$NO_TOOL_INPUT")
assert_rc "missing tool_input allows (rc=0)" 0 "$RC10"
assert_empty "missing tool_input: silent" "$(combined_output no-tool-input)"

echo ""
echo "=== HIMMEL-2653: malformed tool_input fails open, not DENY ==="
# RED control: against the pre-fix hook, .tool_input.model on a payload with
# NO tool_input collapses (via `select(type == "string") // empty`) to the
# same empty string as a genuinely-omitted model — so the hook TRIPS and
# DENIES a payload its own header promises to fail open on. This is the
# headline regression check: it must exit 0 and stay silent.
TOOL_INPUT_NOT_OBJECT=$(jq -nc '{tool_name:"Agent",session_id:"s",tool_input:"nope"}')
RC10C=$(run_hook tool-input-not-object "$TOOL_INPUT_NOT_OBJECT")
assert_rc "non-object tool_input allows (rc=0)" 0 "$RC10C"
assert_empty "non-object tool_input: silent" "$(combined_output tool-input-not-object)"

MODEL_NOT_STRING=$(jq -nc '{tool_name:"Agent",session_id:"s",tool_input:{subagent_type:"general-purpose",model:123}}')
RC10E=$(run_hook model-not-string "$MODEL_NOT_STRING")
assert_rc "non-string model allows (rc=0)" 0 "$RC10E"
assert_empty "non-string model: silent" "$(combined_output model-not-string)"

GENUINE_TRIP=$(jq -nc '{tool_name:"Agent",session_id:"s",tool_input:{subagent_type:"general-purpose"}}')
RC10G=$(run_hook genuine-trip-deny "$GENUINE_TRIP")
assert_rc "genuine trip (real object, omitted model) is DENIED (rc=2)" 2 "$RC10G"

EMPTY_DIR="$TMP/empty-path"
mkdir -p "$EMPTY_DIR"
# Symlink in the real `cat` so the hook's `input=$(cat ...)` still reads the
# payload — an EMPTY_DIR with no `cat` either would make stdin read empty and
# trip the hook's earlier empty-input check instead, passing this assertion
# for the wrong reason without ever exercising the jq-missing fail-open path.
CAT_ABS=$(command -v cat)
[ -n "$CAT_ABS" ] || { echo "FATAL: cannot resolve cat on PATH" >&2; exit 1; }
ln -s "$CAT_ABS" "$EMPTY_DIR/cat"
RC11=$(run_hook no-jq "$(payload general-purpose '')" PATH="$EMPTY_DIR")
assert_rc "missing jq allows (rc=0)" 0 "$RC11"

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
