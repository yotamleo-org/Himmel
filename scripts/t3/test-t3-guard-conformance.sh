#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

# shellcheck source=../lib/override-env.sh
# shellcheck disable=SC1091
. "$REPO/scripts/lib/override-env.sh"
scrub_override_env

TMP="$(mktemp -d "${TMPDIR:-/tmp}/t3-guard-conformance.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export RUN_HOOK_CHAIN_RUN_LOG="$TMP/hook-runs.jsonl"
export RUN_HOOK_CHAIN_SKIP_LOG="$TMP/hook-skips.jsonl"
export HIMMEL_ANTIGRAVITY_PROJECT_DIR="$REPO"
mkdir -p "$HOME/.himmel" "$TMP/bin"

cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '{"state":"OPEN","mergeStateStatus":"BLOCKED","reviewDecision":""}\n'
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

run_claude() {
    local guard="$1" tool="$2" args="$3" expect="$4" label="$5"
    local payload out rc
    payload="$(jq -cn --arg t "mcp__t3-code__$tool" --argjson a "$args" \
        '{hook_event_name:"PreToolUse",tool_name:$t,tool_input:$a,cwd:"/tmp"}')"
    out="$(printf '%s' "$payload" | bash "$REPO/scripts/hooks/$guard" 2>&1)"; rc=$?
    if [ "$expect" = "deny" ]; then
        if [ "$rc" -eq 2 ]; then ok "claude: $label"; else bad "claude: $label (rc=$rc out=$out)"; fi
    else
        if [ "$rc" -eq 0 ]; then ok "claude: $label"; else bad "claude: $label (rc=$rc out=$out)"; fi
    fi
}

run_antigravity() {
    local tool="$1" args="$2" expect="$3" label="$4"
    local payload out rc dec
    payload="$(jq -cn --arg t "mcp_t3-code_$tool" --argjson a "$args" '{
        hookEventName:"PreToolUse",
        conversationId:"conf-1",
        cwd:"/tmp",
        toolCall:{id:"call_conf",name:$t,args:$a}
    }')"
    out="$(printf '%s' "$payload" | bash "$REPO/scripts/hooks/antigravity-hook-adapter.sh" 2>"$TMP/agy.err")"; rc=$?
    if [ "$expect" = "deny" ]; then
        dec="$(printf '%s' "$out" | jq -r '.decision // empty' 2>/dev/null || true)"
        if [ "$rc" -eq 0 ] && [ "$dec" = "deny" ]; then ok "antigravity: $label"; else bad "antigravity: $label (rc=$rc out=$out err=$(cat "$TMP/agy.err"))"; fi
    else
        if [ "$rc" -eq 0 ] && [ -z "$out" ]; then ok "antigravity: $label"; else bad "antigravity: $label (rc=$rc out=$out err=$(cat "$TMP/agy.err"))"; fi
    fi
}

ARGS_OFF_ALLOW='{"title":"Work","message":"go","modelSelection":{"instanceId":"antigravity","model":"gemini-4-neon"}}'
ARGS_CHIEF_TITLE='{"action":"rename","title":"ops-chief"}'
ARGS_UNWATCH_OPEN='{"url":"https://github.com/o/r/pull/123"}'
ARGS_BENIGN='{"toolSummary":"Read env"}'

echo "== T3 guard conformance: claude =="
run_claude guard-t3-thread-tools.sh t3_thread_launch "$ARGS_OFF_ALLOW" deny "off-allowlist instance denied"
run_claude guard-t3-thread-tools.sh t3_thread_update "$ARGS_CHIEF_TITLE" deny "-chief title denied"
run_claude block-t3code-unwatch-open-pr.sh unwatch_pull_request "$ARGS_UNWATCH_OPEN" deny "unwatch OPEN PR denied"
run_claude guard-t3-thread-tools.sh t3_environment_read "$ARGS_BENIGN" allow "benign T3 read allowed"

echo "== T3 guard conformance: antigravity =="
run_antigravity t3_thread_launch "$ARGS_OFF_ALLOW" deny "off-allowlist instance denied"
run_antigravity t3_thread_update "$ARGS_CHIEF_TITLE" deny "-chief title denied"
run_antigravity unwatch_pull_request "$ARGS_UNWATCH_OPEN" deny "unwatch OPEN PR denied"
run_antigravity t3_environment_read "$ARGS_BENIGN" allow "benign T3 read allowed"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
