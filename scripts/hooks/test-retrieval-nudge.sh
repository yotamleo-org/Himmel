#!/usr/bin/env bash
# Suite for scripts/hooks/retrieval-nudge.sh.
#
# Usage: bash scripts/hooks/test-retrieval-nudge.sh
#
# Every row feeds PostToolUse JSON on stdin with the counter dir pointed at a
# per-run temp dir, and asserts exit 0 and never a deny/block decision.
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/retrieval-nudge.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/retrieval-nudge.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
export RETRIEVAL_NUDGE_DIR="$TMP/state"

FAILED=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

# call SID TOOL [COMMAND] -> stdout in $TMP/out, rc in $rc
call() {
    local sid="$1" tool="$2" cmd="${3:-}"
    jq -cn --arg s "$sid" --arg t "$tool" --arg c "$cmd" \
        '{session_id: $s, hook_event_name: "PostToolUse", tool_name: $t, tool_input: (if $c == "" then {pattern: "foo"} else {command: $c} end)}' \
        | bash "$HOOK" >"$TMP/out" 2>"$TMP/err"
    rc=$?
}
nudges=0
# sweeps SID N [TOOL CMD]: N calls, tally how many produced a nudge into $nudges
sweeps() {
    local sid="$1" n="$2" tool="${3:-Bash}" cmd="${4:-git grep -n foo}" i
    nudges=0
    for ((i = 0; i < n; i++)); do
        call "$sid" "$tool" "$cmd"
        [ "$rc" = 0 ] || return 1
        [ -s "$TMP/out" ] && nudges=$((nudges + 1))
    done
    return 0
}
clean_output() { ! grep -q -E '"(permissionDecision|decision)"' "$TMP/out"; }

# 1. Five sweeps, no retrieval: exactly one nudge, naming both tools.
sweeps s1 5
if [ "$nudges" = 1 ] && grep -q 'leg-graph.sh' "$TMP/out" && grep -q 'qmd-bounded.sh' "$TMP/out" \
    && jq -e '.hookSpecificOutput.hookEventName == "PostToolUse" and (.hookSpecificOutput.additionalContext | length > 0)' "$TMP/out" >/dev/null 2>&1 \
    && clean_output; then pass "5 sweeps give exactly one nudge naming both tools"; else fail "5 sweeps give one nudge (nudges=$nudges rc=$rc)"; fi

# 2. A 6th and 7th sweep: silent.
sweeps s1 2
if [ "$nudges" = 0 ]; then pass "6th and 7th sweep give no second nudge"; else fail "6th sweep silent (nudges=$nudges)"; fi

# 3. Four sweeps: silent.
sweeps s2 4
if [ "$nudges" = 0 ]; then pass "4 sweeps give no nudge"; else fail "4 sweeps silent (nudges=$nudges)"; fi

# 4. GREEN control: one graphify query before the 5th sweep gives no nudge.
sweeps s3 3
call s3 Bash 'bash scripts/graphify/leg-graph.sh query "who calls foo"'
sweeps s3 4
if [ "$nudges" = 0 ]; then pass "graphify query before the 5th sweep gives no nudge"; else fail "graphify control (nudges=$nudges)"; fi

# 5. A qmd MCP call or qmd-bounded.sh call also counts as retrieval.
sweeps s4 2
call s4 mcp__qmd__query
sweeps s4 5
if [ "$nudges" = 0 ]; then pass "qmd MCP call gives no nudge"; else fail "qmd mcp control (nudges=$nudges)"; fi
sweeps s5 2
call s5 Bash 'bash scripts/lib/qmd-bounded.sh query -c himmel "retrieval"'
sweeps s5 5
if [ "$nudges" = 0 ]; then pass "qmd-bounded.sh call gives no nudge"; else fail "qmd-bounded control (nudges=$nudges)"; fi

# 6. Counters of two session ids are independent.
sweeps s6 4
sweeps s7 4
call s6 Bash 'rg -n foo src'
s6n=0; [ -s "$TMP/out" ] && s6n=1
call s7 Bash 'git grep -l bar'
s7n=0; [ -s "$TMP/out" ] && s7n=1
if [ "$s6n" = 1 ] && [ "$s7n" = 1 ]; then pass "two session ids count independently"; else fail "independent counters (s6=$s6n s7=$s7n)"; fi

# 7. Grep and Glob tool calls count as sweeps.
sweeps s8 3 Grep
a=$nudges
sweeps s8 2 Glob
if [ "$a" = 0 ] && [ "$nudges" = 1 ]; then pass "Grep and Glob tool calls count"; else fail "Grep/Glob count (a=$a nudges=$nudges)"; fi

# 8. Sweep classifier: each of these counts, plain listings and unrelated commands do not.
for c in 'grep -rn foo src' 'grep -R foo .' 'git grep -l foo' 'rg foo' 'find . -name "*.sh"' 'git log -S foo' 'cd x && git grep -n y'; do
    sweeps "c-$c" 5 Bash "$c"
    [ "$nudges" = 1 ] || fail "classifier counts: $c (nudges=$nudges)"
done
for c in 'find . -maxdepth 1' 'find docs -type d' 'ls -la' 'git status' 'grep foo file.txt' 'echo "git grep -n foo"' 'git commit -m "rg foo"'; do
    sweeps "n-$c" 8 Bash "$c"
    [ "$nudges" = 0 ] || fail "classifier ignores: $c (nudges=$nudges)"
done
pass "classifier rows done (see FAIL lines above if any)"

# 9. Malformed input and empty stdin fail open: exit 0, no output.
printf 'not json' | bash "$HOOK" >"$TMP/out" 2>/dev/null; rc=$?
if [ "$rc" = 0 ] && [ ! -s "$TMP/out" ]; then pass "malformed JSON exits 0 silently"; else fail "malformed JSON (rc=$rc)"; fi
bash "$HOOK" </dev/null >"$TMP/out" 2>/dev/null; rc=$?
if [ "$rc" = 0 ] && [ ! -s "$TMP/out" ]; then pass "empty stdin exits 0 silently"; else fail "empty stdin (rc=$rc)"; fi

if [ "$FAILED" -gt 0 ]; then echo "$FAILED failed"; exit 1; fi
echo "all passed"
