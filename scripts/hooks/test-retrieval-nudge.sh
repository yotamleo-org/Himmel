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
if [ "$nudges" = 1 ] && grep -q 'worker-graph.sh' "$TMP/out" && grep -q 'qmd-bounded.sh' "$TMP/out" \
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
call s3 Bash 'bash scripts/graphify/worker-graph.sh query "who calls foo"'
sweeps s3 4
if [ "$nudges" = 0 ]; then pass "graphify query before the 5th sweep gives no nudge"; else fail "graphify control (nudges=$nudges)"; fi
sweeps s3w 3
call s3w Bash 'bash scripts/graphify/worker-graph.sh query "who calls foo"'
sweeps s3w 4
if [ "$nudges" = 0 ]; then pass "worker-graph.sh query before the 5th sweep gives no nudge"; else fail "worker-graph control (nudges=$nudges)"; fi

# 5. A qmd MCP call or qmd-bounded.sh call also counts as retrieval.
sweeps s4 2
call s4 mcp__qmd__query
sweeps s4 5
if [ "$nudges" = 0 ]; then pass "qmd MCP call gives no nudge"; else fail "qmd mcp control (nudges=$nudges)"; fi
sweeps s4p 2
call s4p mcp__plugin_qmd_qmd__query
sweeps s4p 5
if [ "$nudges" = 0 ]; then pass "plugin-named qmd MCP call gives no nudge"; else fail "plugin qmd mcp control (nudges=$nudges)"; fi
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

# ---------------------------------------------------------------------------
# Vault sweep POC: marketplace/plugins/himmel-ops/hooks/block-vault-sweep.sh,
# the opt-in PreToolUse deny that refuses the first hand sweep of the notes
# once and names the qmd search. Hermetic: the vault paths below are strings
# the hook never opens, its state dir and log live under $TMP, and the cwd is a
# plain temp dir (no git, no salus). Unlike the rows above, a deny here is the
# expected result (exit 2).
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VHOOK="$ROOT/marketplace/plugins/himmel-ops/hooks/block-vault-sweep.sh"
VLOG="$TMP/vlog.jsonl"
VAULT=/home/u/Documents/luna
mkdir -p "$TMP/work"

# vcall SID TOOL COMMAND-OR-PATTERN [PATH] [CWD] -> rc in $rc, stderr in $TMP/err
# Overridable per call: VON, VBYP, VDIR, VREPO.
vcall() {
    local sid="$1" tool="$2" cmd="${3:-}" path="${4:-}" cwd="${5:-$TMP/work}" ti
    if [ "$tool" = Grep ]; then
        ti="$(jq -cn --arg p "$cmd" --arg d "$path" '{pattern: $p} + (if $d == "" then {} else {path: $d} end)')"
    elif [ -n "$cmd" ]; then
        ti="$(jq -cn --arg c "$cmd" '{command: $c}')"
    else
        ti='{}'
    fi
    local payload
    payload="$(jq -cn --arg s "$sid" --arg t "$tool" --arg d "$cwd" --argjson i "$ti" \
        '{session_id: $s, cwd: $d, hook_event_name: "PreToolUse", tool_name: $t, tool_input: $i}')"
    env HIMMEL_VAULT_SWEEP_DENY="${VON-1}" HIMMEL_VAULT_SWEEP_BYPASS="${VBYP-}" \
        HIMMEL_VAULT_SWEEP_DIR="${VDIR-$TMP/vstate}" HIMMEL_VAULT_SWEEP_LOG="$VLOG" \
        HIMMEL_REPO="${VREPO-$ROOT}" HOME="${VHOME-$HOME}" bash "$VHOOK" <<<"$payload" >"$TMP/out" 2>"$TMP/err"
    rc=$?
}
# vrows DESC-PREFIX WANT-RC SID-PREFIX CMD...: one fresh session per command
vrows() {
    local want="$1" label="$2" c n=0
    shift 2
    for c in "$@"; do
        n=$((n + 1))
        vcall "vr-$label-$n" Bash "$c"
        [ "$rc" = "$want" ] || fail "$label: want rc=$want got rc=$rc for: $c"
    done
}

# 10. A vault sweep is denied once, naming the absolute qmd command, then allowed.
S="grep -rl \"meeting notes\" $VAULT"
vcall v1 Bash "$S"
if [ "$rc" = 2 ] && grep -q "$ROOT/scripts/lib/qmd-bounded.sh query -c luna" "$TMP/err" \
    && grep -q 'one retry' "$TMP/err" && grep -q 'no chief message' "$TMP/err" \
    && grep -q 'HIMMEL_VAULT_SWEEP_BYPASS=1' "$TMP/err"; then pass "first vault sweep is denied with the absolute qmd command, one retry and the bypass named"; else fail "first vault sweep denied (rc=$rc)"; fi
vcall v1 Bash "$S"
if [ "$rc" = 0 ]; then pass "the retry of the same sweep is allowed"; else fail "retry allowed (rc=$rc)"; fi
vcall v1 Bash "rg -n other $VAULT/handovers"
if [ "$rc" = 0 ]; then pass "later sweeps in the same session stay allowed"; else fail "later sweep allowed (rc=$rc)"; fi
vcall v1b Bash "rg -n notes $VAULT/handovers"
if [ "$rc" = 2 ]; then pass "a second session is denied on its own"; else fail "second session denied (rc=$rc)"; fi

# 11. The other closed-list shapes: the Grep tool, rg, a recursive flag in any option token, a Clippings root.
vcall v2 Grep "meeting notes" "$VAULT/handovers"
if [ "$rc" = 2 ]; then pass "Grep tool over a vault path is denied"; else fail "Grep tool denied (rc=$rc)"; fi
vcall v2g Grep "meeting notes" "" "$VAULT"
if [ "$rc" = 2 ]; then pass "Grep tool with no path, cwd in the vault, is denied"; else fail "Grep tool cwd vault denied (rc=$rc)"; fi
vrows 2 shape \
    "rg -n notes $VAULT" \
    "grep -n -r notes $VAULT" \
    "grep -Rli notes /home/u/Clippings" \
    "cd /x && grep -rn \"plain words\" $VAULT/specs" \
    "grep --recursive notes $VAULT"

# 12. Never denied: a repo grep, a named file, find -name, a listing, a quoted mention.
vrows 0 allow \
    "grep -rn notes /home/u/Documents/github/himmel/scripts" \
    "grep -rn notes src" \
    "grep -n notes $VAULT/handovers/one.md" \
    "grep -rn notes" \
    "find $VAULT -name \"*.md\"" \
    "ls $VAULT" \
    "git status" \
    "echo \"grep -r notes $VAULT\"" \
    "git commit -m \"grep -r notes $VAULT\"" \
    "git grep -n notes" \
    "grep -e notes -r $VAULT" \
    "grep -rn matrix $VAULT/handovers/one.md" \
    "grep -rn matrix $VAULT/handovers/one.md $VAULT/handovers/two.md" \
    "cd $VAULT/handovers; grep -rl notes specs" \
    "cd /home/u/Documents/github/himmel && rg -n notes scripts" \
    "R=$VAULT; grep -rn notes \$R/specs" \
    "grep -rn notes \$(pwd)/specs"
vrows 2 shape2 \
    "grep -rli notes $VAULT/handovers/*.md" \
    "grep -rl notes \$HOME/Documents/luna"
vcall v18 Bash "grep -rl notes 2>/dev/null" "" "$VAULT"
a=$rc
vcall v18b Bash "grep -rn ssh \$(find $VAULT/specs -name x.md)" "" "$VAULT"
if [ "$a" = 0 ] && [ "$rc" = 0 ]; then pass "a redirection or a command substitution is never read as a vault root"; else fail "redirection/substitution roots (redir=$a subst=$rc)"; fi
vcall v17 Bash "grep -rl notes specs" "" "$VAULT"
a=$rc
vcall v17b Bash "cd /home/u/Documents/github/himmel; grep -rl notes specs" "" "$VAULT"
if [ "$a" = 2 ] && [ "$rc" = 0 ]; then pass "a relative root in a vault cwd is denied, but not after a cd in the command"; else fail "relative root vs cd (plain=$a cd=$rc)"; fi
vcall v3 Grep "meeting notes" "/home/u/Documents/github/himmel/scripts"
if [ "$rc" = 0 ]; then pass "Grep tool over a repo path is allowed"; else fail "Grep repo path allowed (rc=$rc)"; fi

# 13. A ticket key, a number, a session name or a marker in the pattern is never denied.
vrows 0 id \
    "grep -rl HIMMEL-8748 $VAULT" \
    "grep -rl \"HIMMEL 8748\" $VAULT" \
    "grep -rl 3972 $VAULT" \
    "grep -rl 2112300408550867318 $VAULT" \
    "grep -rl '\\b344\\b' $VAULT" \
    "grep -rl harvest-clips $VAULT" \
    "grep -rl KN-j4295-1 $VAULT" \
    "grep -rl '#3972' $VAULT" \
    "rg -l 'a|b' $VAULT"
vcall v4 Grep "HIMMEL-8748" "$VAULT"
if [ "$rc" = 0 ]; then pass "Grep tool with a ticket key is allowed"; else fail "Grep ticket key allowed (rc=$rc)"; fi

# 14. A qmd call clears the deny, whether it comes before or after the refusal.
vcall v5 Bash "bash $ROOT/scripts/lib/qmd-bounded.sh query -c luna \"meeting notes\""
vcall v5 Bash "$S"
if [ "$rc" = 0 ]; then pass "a qmd-bounded.sh call before the sweep clears the deny"; else fail "qmd-bounded clears (rc=$rc)"; fi
vcall v6 mcp__qmd__query
vcall v6 Bash "$S"
if [ "$rc" = 0 ]; then pass "a qmd MCP call before the sweep clears the deny"; else fail "qmd mcp clears (rc=$rc)"; fi
vcall v6p mcp__plugin_qmd_qmd__query
vcall v6p Bash "$S"
if [ "$rc" = 0 ]; then pass "a plugin-named qmd MCP call clears the deny"; else fail "plugin qmd clears (rc=$rc)"; fi
vcall v7 Bash "$S"
vcall v7 Bash 'qmd query -c luna "meeting notes"'
vcall v7 Bash "$S"
if [ "$rc" = 0 ]; then pass "a qmd call after the refusal keeps later sweeps allowed"; else fail "qmd after refusal (rc=$rc)"; fi

# 15. Off by default, the launching-shell bypass, and silence in a salus session.
VON='' vcall v8 Bash "$S"
if [ "$rc" = 0 ]; then pass "switch unset: the hook is a no-op"; else fail "switch unset (rc=$rc)"; fi
VBYP=1 vcall v9 Bash "$S"
if [ "$rc" = 0 ]; then pass "HIMMEL_VAULT_SWEEP_BYPASS=1 allows"; else fail "bypass allows (rc=$rc)"; fi
mkdir -p "$TMP/salus-app" "$TMP/marked/sub"
: >"$TMP/marked/.salus"
vcall v10 Bash "$S" "" "$TMP/salus-app"
a=$rc
vcall v10b Bash "$S" "" "$TMP/marked/sub"
if [ "$a" = 0 ] && [ "$rc" = 0 ]; then pass "salus cwd path and .salus marker: silent"; else fail "salus silent (path=$a marker=$rc)"; fi
vcall v10c Bash "grep -rl notes /home/u/salus-app/docs $VAULT"
if [ "$rc" = 0 ]; then pass "a command naming salus: silent"; else fail "salus in command silent (rc=$rc)"; fi

# 16. Fail open on its own problems.
printf 'not json' | HIMMEL_VAULT_SWEEP_DENY=1 bash "$VHOOK" >"$TMP/out" 2>"$TMP/err"; rc=$?
if [ "$rc" = 0 ] && [ ! -s "$TMP/out" ] && [ ! -s "$TMP/err" ]; then pass "vault hook: malformed JSON exits 0 silently"; else fail "vault hook malformed JSON (rc=$rc)"; fi
HIMMEL_VAULT_SWEEP_DENY=1 bash "$VHOOK" </dev/null >"$TMP/out" 2>"$TMP/err"; rc=$?
if [ "$rc" = 0 ] && [ ! -s "$TMP/err" ]; then pass "vault hook: empty stdin exits 0"; else fail "vault hook empty stdin (rc=$rc)"; fi
: >"$TMP/afile"
VDIR="$TMP/afile/state" vcall v11 Bash "$S"
if [ "$rc" = 0 ]; then pass "unwritable state dir allows"; else fail "unwritable state dir (rc=$rc)"; fi
VREPO="$TMP/no-such-checkout" vcall v12 Bash "$S"
if [ "$rc" = 0 ]; then pass "no resolvable checkout (cannot name the absolute path) allows"; else fail "no checkout allows (rc=$rc)"; fi
vcall v13 Bash $'grep -rl "unterminated notes\n'"$VAULT"
if [ "$rc" = 0 ]; then pass "unbalanced quote (unparseable) allows"; else fail "unbalanced quote allows (rc=$rc)"; fi

# 16b. The checkout falls back to the canonical install, a path with a space is quoted in the
# command the deny prints, and concurrent sweeps on one key give exactly one refusal.
mkdir -p "$TMP/fakehome/Documents/github/himmel/scripts/lib" "$TMP/my repo/scripts/lib"
: >"$TMP/fakehome/Documents/github/himmel/scripts/lib/qmd-bounded.sh"
: >"$TMP/my repo/scripts/lib/qmd-bounded.sh"
VREPO='' VHOME="$TMP/fakehome" vcall v19 Bash "$S"
if [ "$rc" = 2 ] && grep -qF "$TMP/fakehome/Documents/github/himmel/scripts/lib/qmd-bounded.sh query" "$TMP/err"; then pass "no HIMMEL_REPO and no checkout in the cwd: the canonical install names the command"; else fail "canonical fallback (rc=$rc)"; fi
VREPO="$TMP/my repo" vcall v20 Bash "$S"
if [ "$rc" = 2 ] && grep -qF "bash '$TMP/my repo/scripts/lib/qmd-bounded.sh' query" "$TMP/err"; then pass "a checkout path with a space is quoted in the printed command"; else fail "space path quoted (rc=$rc)"; fi
for i in 1 2 3 4 5 6; do
    ( vcall v21 Bash "$S"; echo "$rc" >"$TMP/par.$i" ) &
done
wait
if [ "$(cat "$TMP"/par.* | grep -c '^2$')" = 1 ] && [ "$(cat "$TMP"/par.* | grep -c '^0$')" = 5 ]; then pass "six concurrent sweeps on one key: exactly one refusal"; else fail "concurrent sweeps: $(cat "$TMP"/par.* | tr '\n' ' ')"; fi

# 16c. A qmd call in a salus session is never logged (its query text is PHI-path content); a quoted
# qmd helper path with a space still counts as a qmd call; an option value and a separated
# redirection target are not a pattern or a root.
vcall v22 Bash 'qmd query -c salus "Alice Smith diagnosis"'
vcall v22b Bash 'qmd query -c luna "Alice Smith diagnosis"' "" "$TMP/salus-app"
vcall v22c Bash 'qmd query -c luna "Alice Smith diagnosis"' "" "$TMP/marked/sub"
if ! grep -q 'Alice' "$VLOG" && ! grep -q '"session_id":"v22' "$VLOG"; then pass "salus session (command, cwd path, .salus marker): a qmd call writes no log row"; else fail "salus qmd call logged"; fi
vcall v23 Bash "bash '$TMP/my repo/scripts/lib/qmd-bounded.sh' query -c luna \"notes\""
vcall v23 Bash "$S"
a=$rc
vcall v23b Bash "bash \"$TMP/my repo/scripts/lib/qmd-bounded.sh\" query -c luna \"notes\""
vcall v23b Bash "$S"
if [ "$a" = 0 ] && [ "$rc" = 0 ]; then pass "a quoted qmd helper path with a space clears the deny"; else fail "quoted spaced qmd path (single=$a double=$rc)"; fi
vrows 0 operand \
    "rg --sort path HIMMEL-8847 $VAULT" \
    "rg --sortr modified HIMMEL-8847 $VAULT" \
    "rg notes . > $VAULT/output" \
    "grep -rl notes . 2> $VAULT/err"

# 17. Known residual: a heredoc line that is itself a vault sweep is refused (counted as a false refusal), once.
vcall v14 Bash $'cat > note.md <<EOF\ngrep -r notes '"$VAULT"$'\nEOF'
a=$rc
vcall v14 Bash $'cat > note.md <<EOF\ngrep -r notes '"$VAULT"$'\nEOF'
if [ "$a" = 2 ] && [ "$rc" = 0 ]; then pass "heredoc sweep line: refused once, then the retry passes (bounded false refusal)"; else fail "heredoc residual (first=$a retry=$rc)"; fi

# 18. The log carries enough to classify a refusal and to count conversions.
long="grep -rl notes $VAULT$(printf ' word%.0s' $(seq 1 60))"
vcall v15 Bash "$long"
vcall v16 Bash "grep -rl notes $VAULT --include=ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdef"
if jq -e -s '
    ([.[] | select(.event == "deny")] | length) as $d
    | ([.[] | select(.event == "retry_allowed")] | length) as $r
    | ([.[] | select(.event == "qmd_clear" and .had_deny == true)] | length) as $c
    | ([.[] | select(.event == "qmd_clear" and .had_deny == false)] | length) as $n
    | $d >= 5 and $r >= 2 and $c == 1 and $n >= 3
      and all(.[]; has("ts") and has("session_id") and has("event") and has("tool"))
      and all(.[] | select(.event == "deny"); (.cmd | length) <= 200 and has("root") and has("cwd"))
      and ([.[] | select(.session_id == "v15" and .event == "deny")][0].cmd | length) == 200
      and ([.[] | select(.session_id == "v16" and .event == "deny")][0].cmd | test("ABCDEFGHIJKLMNOPQRSTUVWXYZ") | not)' "$VLOG" >/dev/null 2>&1; then
    pass "log rows: deny/retry_allowed/qmd_clear with had_deny, cmd cut to 200, token-shaped runs masked"
else
    fail "log rows"
fi

if [ "$FAILED" -gt 0 ]; then echo "$FAILED failed"; exit 1; fi
echo "all passed"
