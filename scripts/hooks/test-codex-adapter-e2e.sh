#!/usr/bin/env bash
# Through-adapter e2e for the codex-direct lane. Drives
# .codex/codex-hook-adapter.sh END-TO-END: stdin = a codex-shaped PreToolUse
# JSON, CLAUDE_PROJECT_DIR pointed at THIS checkout so the adapter runs the REAL
# guardrails under scripts/hooks/. Asserts the exit-2 block is translated into
# Codex's JSON `permissionDecision:"deny"` for BOTH:
#   (a) a secret-read payload through block-read-secrets.sh, and
#   (b) an external-write payload through block-terminal-write-fence.sh
#       (the guard this ticket adds).
# Plus an ALLOW passthrough (a benign command through the new guard must NOT
# emit a deny). Companion to scripts/hooks/test-codex-run-hook.sh, which proves
# the wrapper+adapter mechanics on a synthetic guardrail; this proves the real
# guardrails deny through the adapter. Hermetic: no network, no fixtures needed
# (both deny cases classify by the payload alone).
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HOOKS/../.." && pwd)"
ADAPTER="$REPO/.codex/codex-hook-adapter.sh"
[ -f "$ADAPTER" ] || { echo "adapter not found: $ADAPTER" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# The adapter must never see the external-write opt-in from the suite env.
unset CODEX_EXTERNAL_WRITES_OK T3_THREAD_TOOLS_OK T3CODE_UNWATCH_OK 2>/dev/null || true

TMP="$(mktemp -d "${TMPDIR:-/tmp}/codex-adapter-e2e.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home/.himmel" "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '{"state":"%s","mergeStateStatus":"BLOCKED","reviewDecision":""}\n' "${GH_STUB_STATE:-OPEN}"
EOF
chmod +x "$TMP/bin/gh"

# run <guardrail.sh> <json> -> echoes adapter stdout; exit code in $rc
run() {
    local script="$1" json="$2"
    CLAUDE_PROJECT_DIR="$REPO" bash "$ADAPTER" "$script" <<EOF
$json
EOF
}

echo "== (a) secret-read through block-read-secrets.sh =="
out="$(run block-read-secrets.sh '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/x/.env"}}')"; rc=$?
if [ "$rc" -eq 0 ]; then ok "adapter exits 0 (decision is in the JSON)"; else bad "adapter exits 0 (got $rc)"; fi
case "$out" in
  *'"permissionDecision":"deny"'*) ok "secret read -> JSON deny";;
  *) bad "secret read -> JSON deny ($out)";;
esac
case "$out" in
  *'"hookEventName":"PreToolUse"'*) ok "secret read -> hookEventName PreToolUse";;
  *) bad "secret read -> hookEventName PreToolUse ($out)";;
esac

echo "== (b) external-write through block-terminal-write-fence.sh =="
out="$(run block-terminal-write-fence.sh '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git push origin main"}}')"; rc=$?
if [ "$rc" -eq 0 ]; then ok "adapter exits 0 (decision is in the JSON)"; else bad "adapter exits 0 (got $rc)"; fi
case "$out" in
  *'"permissionDecision":"deny"'*) ok "git push -> JSON deny";;
  *) bad "git push -> JSON deny ($out)";;
esac
case "$out" in
  *"external-write"*) ok "git push -> reason names the external-write class";;
  *) bad "git push -> reason names the external-write class ($out)";;
esac

echo "== (b') benign command through block-terminal-write-fence.sh -> ALLOW =="
out="$(run block-terminal-write-fence.sh '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git status"}}')"; rc=$?
if [ "$rc" -eq 0 ]; then ok "benign command -> adapter exits 0"; else bad "benign command -> adapter exits 0 (got $rc)"; fi
case "$out" in
  *permissionDecision*) bad "benign command -> must NOT emit a deny ($out)";;
  *) ok "benign command -> no permissionDecision (passthrough allow)";;
esac

echo "== (c) destructive command through block-destructive-commands.sh =="
out="$(run block-destructive-commands.sh '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/x"}}')"; rc=$?
if [ "$rc" -eq 0 ]; then ok "adapter exits 0 for destructive deny"; else bad "adapter exits 0 for destructive deny (got $rc)"; fi
case "$out" in
  *'"permissionDecision":"deny"'*) ok "rm -rf -> JSON deny";;
  *) bad "rm -rf -> JSON deny ($out)";;
esac
case "$out" in
  *"block-destructive-commands"*) ok "rm -rf -> reason names destructive guard";;
  *) bad "rm -rf -> reason names destructive guard ($out)";;
esac

echo "== (d) T3 thread tools guard through guard-t3-thread-tools.sh =="
out="$(HOME="$TMP/home" run guard-t3-thread-tools.sh '{"hook_event_name":"PreToolUse","tool_name":"mcp__t3-code__t3_thread_launch","tool_input":{"title":"Work","modelSelection":{"instanceId":"antigravity","model":"gemini-4-neon"}}}')"; rc=$?
if [ "$rc" -eq 0 ]; then ok "off-allowlist instance -> adapter exits 0"; else bad "off-allowlist instance -> adapter exits 0 (got $rc)"; fi
case "$out" in
  *'"permissionDecision":"deny"'*) ok "off-allowlist instance -> JSON deny";;
  *) bad "off-allowlist instance -> JSON deny ($out)";;
esac

out="$(HOME="$TMP/home" run guard-t3-thread-tools.sh '{"hook_event_name":"PreToolUse","tool_name":"mcp__t3-code__t3_thread_update","tool_input":{"action":"rename","title":"ops-chief"}}')"; rc=$?
if [ "$rc" -eq 0 ]; then ok "-chief title -> adapter exits 0"; else bad "-chief title -> adapter exits 0 (got $rc)"; fi
case "$out" in
  *'"permissionDecision":"deny"'*) ok "-chief title -> JSON deny";;
  *) bad "-chief title -> JSON deny ($out)";;
esac

out="$(HOME="$TMP/home" run guard-t3-thread-tools.sh '{"hook_event_name":"PreToolUse","tool_name":"mcp__t3-code__t3_environment_read","tool_input":{"toolSummary":"Read env"}}')"; rc=$?
if [ "$rc" -eq 0 ]; then ok "benign T3 read -> adapter exits 0"; else bad "benign T3 read -> adapter exits 0 (got $rc)"; fi
case "$out" in
  *permissionDecision*) bad "benign T3 read -> must NOT emit deny ($out)";;
  *) ok "benign T3 read -> passthrough allow";;
esac

echo "== (e) T3 unwatch open PR guard through block-t3code-unwatch-open-pr.sh =="
out="$(HOME="$TMP/home" PATH="$TMP/bin:$PATH" GH_STUB_STATE=OPEN run block-t3code-unwatch-open-pr.sh '{"hook_event_name":"PreToolUse","tool_name":"mcp__t3-code__unwatch_pull_request","tool_input":{"url":"https://github.com/o/r/pull/123"}}')"; rc=$?
if [ "$rc" -eq 0 ]; then ok "unwatch OPEN PR -> adapter exits 0"; else bad "unwatch OPEN PR -> adapter exits 0 (got $rc)"; fi
case "$out" in
  *'"permissionDecision":"deny"'*) ok "unwatch OPEN PR -> JSON deny";;
  *) bad "unwatch OPEN PR -> JSON deny ($out)";;
esac

out="$(HOME="$TMP/home" PATH="$TMP/bin:$PATH" GH_STUB_STATE=MERGED run block-t3code-unwatch-open-pr.sh '{"hook_event_name":"PreToolUse","tool_name":"mcp__t3-code__unwatch_pull_request","tool_input":{"url":"https://github.com/o/r/pull/123"}}')"; rc=$?
if [ "$rc" -eq 0 ]; then ok "unwatch MERGED PR -> adapter exits 0"; else bad "unwatch MERGED PR -> adapter exits 0 (got $rc)"; fi
case "$out" in
  *permissionDecision*) bad "unwatch MERGED PR -> must NOT emit deny ($out)";;
  *) ok "unwatch MERGED PR -> passthrough allow";;
esac

echo "== (f) wired .codex/hooks.json MCP chain denies both T3 guards =="
MCP_CHAIN="$(jq -r '.hooks.PreToolUse[] | select(.matcher == "mcp__.*") | .hooks[0].command' "$REPO/.codex/hooks.json" | sed -n 's/.*run-hook\.sh --sandbox \([^ ]*\).*/\1/p')"
out="$(HOME="$TMP/home" run "$MCP_CHAIN" '{"hook_event_name":"PreToolUse","tool_name":"mcp__t3-code__t3_thread_launch","tool_input":{"title":"Work","modelSelection":{"instanceId":"antigravity","model":"gemini-4-neon"}}}')"; rc=$?
case "$out" in
  *'"permissionDecision":"deny"'*) ok "wired MCP chain denies off-allowlist instance";;
  *) bad "wired MCP chain denies off-allowlist instance (rc=$rc out=$out)";;
esac
out="$(HOME="$TMP/home" run "$MCP_CHAIN" '{"hook_event_name":"PreToolUse","tool_name":"mcp__t3-code__t3_thread_update","tool_input":{"action":"rename","title":"ops-chief"}}')"; rc=$?
case "$out" in
  *'"permissionDecision":"deny"'*) ok "wired MCP chain denies -chief title";;
  *) bad "wired MCP chain denies -chief title (rc=$rc out=$out)";;
esac
out="$(HOME="$TMP/home" PATH="$TMP/bin:$PATH" GH_STUB_STATE=OPEN run "$MCP_CHAIN" '{"hook_event_name":"PreToolUse","tool_name":"mcp__t3-code__unwatch_pull_request","tool_input":{"url":"https://github.com/o/r/pull/123"}}')"; rc=$?
case "$out" in
  *'"permissionDecision":"deny"'*) ok "wired MCP chain denies unwatch on OPEN PR";;
  *) bad "wired MCP chain denies unwatch on OPEN PR (rc=$rc out=$out)";;
esac
out="$(HOME="$TMP/home" run "$MCP_CHAIN" '{"hook_event_name":"PreToolUse","tool_name":"mcp__t3-code__t3_environment_read","tool_input":{"toolSummary":"Read env"}}')"; rc=$?
case "$out" in
  *permissionDecision*) bad "wired MCP chain allows benign T3 read (rc=$rc out=$out)";;
  *) if [ "$rc" -eq 0 ]; then ok "wired MCP chain allows benign T3 read"; else bad "wired MCP chain allows benign T3 read (rc=$rc)"; fi;;
esac

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
