#!/usr/bin/env bash
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
mkdir -p "$TMP/home/.himmel" "$TMP/home/.t3/userdata" "$TMP/bin"
chmod 700 "$TMP/home/.himmel"
export HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config" GIT_CONFIG_NOSYSTEM=1 HIMMEL_POLICY_FOLLOWS_HOME=1
unset GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_DIR GIT_WORK_TREE 2>/dev/null || true
export T3CODE_HOME="$TMP/home/.t3"
printf '{"providerInstances":{"claudeBypass":{"driver":"claudeAgent","environment":[{"name":"AGENTS_MD_OK","value":"1"}]}}}\n' > "$T3CODE_HOME/userdata/settings.json"
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
out="$(HOME="$TMP/home" run guard-t3-thread-tools.sh '{"hook_event_name":"PreToolUse","tool_name":"mcp__t3-code__t3_thread_launch","tool_input":{"title":"Work","modelSelection":{"instanceId":"claudeBypass","model":"claude-opus-5-5"}}}')"; rc=$?
if [ "$rc" -eq 0 ]; then ok "bypass instance -> adapter exits 0"; else bad "bypass instance -> adapter exits 0 (got $rc)"; fi
case "$out" in
  *'"permissionDecision":"deny"'*'carries a himmel bypass flag'*) ok "bypass instance -> JSON deny";;
  *) bad "bypass instance -> JSON deny ($out)";;
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
out="$(HOME="$TMP/home" run "$MCP_CHAIN" '{"hook_event_name":"PreToolUse","tool_name":"mcp__t3-code__t3_thread_launch","tool_input":{"title":"Work","modelSelection":{"instanceId":"claudeBypass","model":"claude-opus-5-5"}}}')"; rc=$?
case "$out" in
  *'"permissionDecision":"deny"'*'carries a himmel bypass flag'*) ok "wired MCP chain denies a bypass instance";;
  *) bad "wired MCP chain denies a bypass instance (rc=$rc out=$out)";;
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

echo "== (g) lane grants through the adapter (HIMMEL-11204) =="
FIX="$(cd "$TMP" && pwd -P)/fix"; FIXWT="$FIX-wt"
mkdir -p "$FIX/scripts"
cp -R "$REPO/.codex" "$FIX/.codex"
cp -R "$REPO/scripts/hooks" "$REPO/scripts/guardrails" "$REPO/scripts/lib" "$REPO/scripts/harnesses" "$FIX/scripts/"
git init -q -b main "$FIX"
git -C "$FIX" add -A >/dev/null 2>&1
git -C "$FIX" -c user.name=t -c user.email=t@example.invalid commit -q --no-verify -m fixture
git -C "$FIX" remote add origin 'https://github.com/acme/fixture.git'
git -C "$FIX" worktree add -q -b feat/x "$FIXWT"
GRANT_CFG="$TMP/home/.himmel/config.json"
grant() {
    printf '{"lane_grants":{"%s":["%s"]},"lane_grants_origin":"github.com/acme/fixture"}\n' "$1" "$2" > "$GRANT_CFG"
    chmod 600 "$GRANT_CFG"
}
run_fix() {
    jq -cn --arg c "$2" --arg d "$FIXWT" \
        '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c},cwd:$d,session_id:"lane-grant-e2e"}' |
        jq -c "${3:-.}" |
        ( cd "$FIXWT" && PATH="$TMP/bin:$PATH" CLAUDE_PROJECT_DIR="$FIX" bash "$FIX/.codex/codex-hook-adapter.sh" "$1" 2>/dev/null )
}
allowed() {
    if [ "$3" != 0 ]; then bad "$1 (adapter exit $3)"; return; fi
    if [ -z "$2" ]; then ok "$1"; else bad "$1 ($2)"; fi
}
denied_by() { case "$2" in *'"permissionDecision":"deny"'*"$3"*) ok "$1";; *) bad "$1 ($2)";; esac; }

grant codex git-push-branch
out="$(run_fix block-terminal-write-fence.sh 'git push -u origin feat/x')"; rc=$?
allowed "T11a granted branch push -> allow" "$out" "$rc"
grant antigravity git-push-branch
out="$(run_fix block-terminal-write-fence.sh 'git push -u origin feat/x' '. + {himmel_lane:"antigravity"}')"
denied_by "T11b a payload's own himmel_lane is overwritten" "$out" 'git push is refused'
FIX_CHAIN="$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[0].command' "$FIX/.codex/hooks.json" | sed -n 's/.*run-hook\.sh --sandbox \([^ ]*\).*/\1/p')"
grant codex gh-pr-create
mkdir -p "$FIX/.git/cr-pending/feat"
git -C "$FIXWT" rev-parse HEAD > "$FIX/.git/cr-pending/feat/x"
out="$(run_fix "$FIX_CHAIN" 'gh pr create -H feat/x -t a -b b --base main')"
denied_by "T11c full chain: a review marker refuses a granted pr create" "$out" 'Automated review pending for feat/x'
rm -rf "$FIX/.git/cr-pending"
out="$(run_fix "$FIX_CHAIN" 'gh pr create -H feat/x -t a -b b --base main')"; rc=$?
allowed "T11d full chain: no marker -> granted pr create allowed" "$out" "$rc"
rm -f "$GRANT_CFG"
out="$(run_fix "$FIX_CHAIN" 'gh pr create -H feat/x -t a -b b --base main')"
denied_by "T11 no config: the full chain refuses pr create" "$out" 'external-write'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
