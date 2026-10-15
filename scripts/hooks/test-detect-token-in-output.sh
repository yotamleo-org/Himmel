#!/usr/bin/env bash
# Suite for scripts/hooks/detect-token-in-output.sh.
#
# Usage: bash scripts/hooks/test-detect-token-in-output.sh
#
# Fixture tokens are BUILT at run time (prefix + a repeated character), so this
# file holds no token-shaped literal: reading it trips neither gitleaks nor the
# detector itself. The DM sender is the merge-block-alert seam
# (MERGE_BLOCK_ALERT_CMD), a stub that records what it was asked to send.
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/detect-token-in-output.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/detect-token.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

FAILED=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

rep() { local s="" i; for ((i = 0; i < $2; i++)); do s="$s$1"; done; printf '%s' "$s"; }
TOK_GHP="ghp""_$(rep A 36)"
TOK_GHO="gho""_$(rep b 36)"
TOK_PAT="github""_pat_$(rep C 82)"
TOK_SHORT="ghp""_$(rep A 35)"

printf '{"allowFrom":["12345"]}' >"$TMP/access.json"
cat >"$TMP/send.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\t%s\n' "$1" "$2" >>"$SENT_LOG"
EOF
chmod +x "$TMP/send.sh"

# run_hook JSON -> stdout in $TMP/out, rc in $rc
run_hook() {
    printf '%s' "$1" | env HIMMEL_TEST_FIXTURE=1 TOKEN_ALERT_DIR="$TMP/alerts" \
        MERGE_BLOCK_ALERT_CMD="$TMP/send.sh" TELEGRAM_ACCESS_PATH="$TMP/access.json" \
        SENT_LOG="$TMP/sent.log" bash "$HOOK" >"$TMP/out" 2>"$TMP/err"
    rc=$?
}
j_post() { jq -cn --arg t "$1" --arg s "$2" --arg r "$3" \
    '{session_id: $s, tool_name: $t, tool_input: {command: "x"}, tool_response: {stdout: $r}}'; }
sent_count() { if [ -f "$TMP/sent.log" ]; then wc -l <"$TMP/sent.log" | tr -d ' '; else echo 0; fi; }
no_value() { ! grep -qF "$2" "$1"; }

# 1. A clean result: silent, no DM.
run_hook "$(j_post Bash s1 "PATH=/usr/bin HOME=/home/u")"
if [ "$rc" = 0 ] && [ ! -s "$TMP/out" ] && [ "$(sent_count)" = 0 ]; then pass "clean result is silent"; else fail "clean result is silent (rc=$rc)"; fi

# 2. NAME=token in a Bash result: alert names tool + variable, never the value.
run_hook "$(j_post Bash s1 "SUITE_X=1
GITHUB_PERSONAL_ACCESS_TOKEN=$TOK_GHO
HOME=/home/u")"
if [ "$rc" = 0 ] && grep -q 'TOKEN-IN-OUTPUT' "$TMP/out" && grep -q 'variable GITHUB_PERSONAL_ACCESS_TOKEN' "$TMP/out" \
    && grep -q 'Bash' "$TMP/out" && no_value "$TMP/out" "$TOK_GHO"; then
    pass "env line: alert names tool and variable, not the value"
else fail "env line alert (rc=$rc): $(cut -c1-200 "$TMP/out")"; fi
if jq -e '.systemMessage and .hookSpecificOutput.additionalContext and .hookSpecificOutput.hookEventName == "PostToolUse"' "$TMP/out" >/dev/null 2>&1; then
    pass "emits systemMessage + PostToolUse additionalContext"
else fail "hook output JSON shape"; fi
if [ "$(sent_count)" = 1 ] && grep -q '^12345	TOKEN-IN-OUTPUT' "$TMP/sent.log" && no_value "$TMP/sent.log" "$TOK_GHO"; then
    pass "one DM to the operator, without the value"
else fail "DM sent once without value (count=$(sent_count))"; fi

# 3. Same token, same session: no second DM (still shown on screen).
run_hook "$(j_post Read s1 "GITHUB_PERSONAL_ACCESS_TOKEN=$TOK_GHO")"
if [ "$(sent_count)" = 1 ] && grep -q 'TOKEN-IN-OUTPUT' "$TMP/out"; then pass "repeat in same session: shown, not re-paged"; else fail "dedupe (count=$(sent_count))"; fi

# 4. Fine-grained PAT in a python dict print: variable from the 'NAME': 'tok' form.
run_hook "$(j_post Bash s2 "{'HOME': '/home/u', 'CODEX_GITHUB_PERSONAL_ACCESS_TOKEN': '$TOK_PAT'}")"
if grep -q 'CODEX_GITHUB_PERSONAL_ACCESS_TOKEN' "$TMP/out" && grep -q 'github_pat_' "$TMP/out" \
    && no_value "$TMP/out" "$TOK_PAT" && [ "$(sent_count)" = 2 ]; then
    pass "github_pat_ in a dict print: variable named, value withheld"
else fail "github_pat_ dict: $(cut -c1-200 "$TMP/out")"; fi

# 5. A bare token in an array-shaped response: variable unknown.
run_hook "$(jq -cn --arg r "token: none here, raw $TOK_GHP end" '{session_id:"s3",tool_name:"mcp__x__y",tool_response:[{type:"text",text:$r}]}')"
if grep -q 'variable unknown' "$TMP/out" && grep -q 'mcp__x__y' "$TMP/out" && no_value "$TMP/out" "$TOK_GHP"; then
    pass "bare ghp_ token: variable unknown, tool named"
else fail "bare token: $(cut -c1-200 "$TMP/out")"; fi

# 6. A token in tool_input (a Write body) counts: it lands in the transcript too.
run_hook "$(jq -cn --arg c "X=$TOK_GHP" '{session_id:"s4",tool_name:"Write",tool_input:{file_path:"/tmp/f",content:$c},tool_response:{}}')"
if grep -q 'TOKEN-IN-OUTPUT' "$TMP/out"; then pass "token in tool_input detected"; else fail "token in tool_input"; fi

# 7. Near miss (35 chars after the prefix): silent.
run_hook "$(j_post Bash s5 "x=$TOK_SHORT")"
if [ "$rc" = 0 ] && [ ! -s "$TMP/out" ]; then pass "35-char near miss is silent"; else fail "near miss fired"; fi

# 8. Garbage / empty stdin: fail open.
run_hook 'not json'
if [ "$rc" = 0 ]; then pass "garbage stdin exits 0"; else fail "garbage stdin rc=$rc"; fi
run_hook ''
if [ "$rc" = 0 ]; then pass "empty stdin exits 0"; else fail "empty stdin rc=$rc"; fi

# 9. Two tokens in one result: both named, and a token already alerted on does
# not hide a NEW one behind it (codex-1).
run_hook "$(j_post Bash s1 "GITHUB_PERSONAL_ACCESS_TOKEN=$TOK_GHO
CODEX_TOKEN=$TOK_GHP")"
if grep -q 'GITHUB_PERSONAL_ACCESS_TOKEN' "$TMP/out" && grep -q 'CODEX_TOKEN' "$TMP/out" \
    && no_value "$TMP/out" "$TOK_GHP" && [ "$(sent_count)" = 5 ] && grep -q 'CODEX_TOKEN' "$TMP/sent.log"; then
    pass "second token behind an alerted one: named and paged"
else fail "second token (count=$(sent_count)): $(cut -c1-200 "$TMP/out")"; fi

# 9b. A token in the NAME position (token=token) is never echoed as the variable.
run_hook "$(j_post Bash s8 "$TOK_PAT=$TOK_GHO")"
if grep -q 'TOKEN-IN-OUTPUT' "$TMP/out" && no_value "$TMP/out" "$TOK_PAT" && no_value "$TMP/out" "$TOK_GHO" \
    && no_value "$TMP/sent.log" "$TOK_PAT"; then
    pass "token in the name position is not echoed"
else fail "token as variable name echoed"; fi

# 10. Sender failure: no sentinel left, so a later call may retry the DM.
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/send.sh"
run_hook "$(j_post Bash s6 "T=$TOK_GHP")"
s6=$(find "$TMP/alerts" -name 's6__*' 2>/dev/null)
if [ "$rc" = 0 ] && [ -z "$s6" ]; then pass "failed DM leaves no sentinel"; else fail "failed DM sentinel"; fi

# 11. Alert library missing: no sentinel left either (codex-3). Run a copy of the
# hook from a directory with no ../lib beside it.
mkdir -p "$TMP/nolib/hooks"
cp "$HOOK" "$TMP/nolib/hooks/detect-token-in-output.sh"
printf '%s' "$(j_post Bash s7 "T=$TOK_GHP")" | env TOKEN_ALERT_DIR="$TMP/alerts" \
    bash "$TMP/nolib/hooks/detect-token-in-output.sh" >/dev/null 2>&1
rc=$?
s7=$(find "$TMP/alerts" -name 's7__*' 2>/dev/null)
if [ "$rc" = 0 ] && [ -z "$s7" ]; then pass "missing alert lib leaves no sentinel"; else fail "missing lib sentinel (rc=$rc)"; fi

# 11b. A claim whose hook was killed before the send (empty sentinel older than
# 2 minutes) is reclaimed and paged; a confirmed one ("sent") is not.
# shellcheck disable=SC2016  # the stub body expands at its own run time
printf '#!/usr/bin/env bash\nprintf "%%s\\t%%s\\n" "$1" "$2" >>"$SENT_LOG"\n' >"$TMP/send.sh"
run_hook "$(j_post Bash s9 "T=$TOK_GHP")"
s9=$(find "$TMP/alerts" -name 's9__*' 2>/dev/null)
before=$(sent_count)
if [ -n "$s9" ] && [ "$(cat "$s9")" = sent ]; then pass "sent DM confirms its sentinel"; else fail "sentinel not confirmed"; fi
touch -t 200001010000 "$s9"
run_hook "$(j_post Bash s9 "T=$TOK_GHP")"
if [ "$(sent_count)" = "$before" ]; then pass "confirmed stale sentinel still suppresses"; else fail "confirmed sentinel re-paged"; fi
: >"$s9"; touch -t 200001010000 "$s9"
run_hook "$(j_post Bash s9 "T=$TOK_GHP")"
if [ "$(sent_count)" = "$((before + 1))" ] && [ "$(cat "$s9")" = sent ]; then
    pass "abandoned claim is reclaimed and paged"
else fail "abandoned claim (count=$(sent_count), before=$before)"; fi
: >"$s9"
run_hook "$(j_post Bash s9 "T=$TOK_GHP")"
if [ "$(sent_count)" = "$((before + 1))" ]; then pass "fresh in-flight claim suppresses"; else fail "fresh claim re-paged"; fi

# 11c. Fired as PostToolUseFailure: the output names that event.
run_hook "$(jq -cn --arg r "T=$TOK_GHP" '{hook_event_name:"PostToolUseFailure",tool_name:"Bash",session_id:"s10",tool_input:{command:"x"},error:$r}')"
if [ "$(jq -r '.hookSpecificOutput.hookEventName' "$TMP/out" 2>/dev/null)" = PostToolUseFailure ]; then
    pass "PostToolUseFailure answered with its own event name"
else fail "failure event name: $(cut -c1-200 "$TMP/out")"; fi
run_hook "$(jq -cn --arg r "T=$TOK_GHP" '{hook_event_name:"Bogus",tool_name:"Bash",session_id:"s11",tool_response:$r}')"
if [ "$(jq -r '.hookSpecificOutput.hookEventName' "$TMP/out" 2>/dev/null)" = PostToolUse ]; then
    pass "unknown event name falls back to PostToolUse"
else fail "bogus event name: $(cut -c1-200 "$TMP/out")"; fi

# 12. The sentinel never holds the token.
# grep exits 1 only on a clean "no match"; an error (2, a missing dir) fails.
grep -rqF -e "$TOK_GHO" -e "$TOK_PAT" -e "$TOK_GHP" "$TMP/alerts"
g=$?
if [ "$g" = 1 ] && [ -n "$(ls -A "$TMP/alerts")" ]; then pass "sentinels hold no token"; else fail "token in sentinel dir (grep rc=$g)"; fi

echo ""
if [ "$FAILED" -eq 0 ]; then echo "All cases passed."; exit 0; fi
echo "$FAILED case(s) failed."
exit 1
