#!/usr/bin/env bash
# Through-adapter end-to-end suite for the Antigravity lane.
# Drives scripts/hooks/antigravity-hook-adapter.sh with frozen camelCase
# Antigravity payloads against real himmel guardrails and asserts:
#   - Clean pass emits exact 0-byte stdout + exit 0 (never {} or "allow")
#   - Policy denials emit {"decision":"deny","reason":...} + exit 0
#   - All *_OK bypass env vars are stripped before guard evaluation
#   - Both-home and .agents/** self-protect blocks writes while allowing
#     the session's own artifactDirectoryPath
#   - Child invoke_subagent payloads are fenced identically
#   - SessionStart, PostToolUse, and Stop lifecycle events exit 0 cleanly
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HOOKS/../.." && pwd)"
ADAPTER="$REPO/scripts/hooks/antigravity-hook-adapter.sh"
FIX="$REPO/scripts/hooks/fixtures/antigravity"
[ -f "$ADAPTER" ] || { echo "FAIL: adapter not found: $ADAPTER" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

# shellcheck source=../lib/override-env.sh
# shellcheck disable=SC1091
. "$HOOKS/../lib/override-env.sh"
scrub_override_env

TMP="$(mktemp -d "${TMPDIR:-/tmp}/agy-adapter-e2e.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export T3CODE_HOME="$TMP/t3home"
export RUN_HOOK_CHAIN_RUN_LOG="$TMP/hook-runs.jsonl"
export RUN_HOOK_CHAIN_SKIP_LOG="$TMP/hook-skips.jsonl"
export HIMMEL_HOOK_INTEGRITY_DIR="$TMP/integrity"
export HIMMEL_PRIMARY_BASELINE_DIR="$TMP/baseline"
export HIMMEL_ANTIGRAVITY_PROJECT_DIR="$REPO"
mkdir -p "$HOME/.himmel" "$HOME/.gemini/config" \
    "$T3CODE_HOME/userdata/providers/antigravity/hash1/config" \
    "$T3CODE_HOME/userdata/providers/antigravity/hash1/antigravity-acp/brain/conv-1" \
    "$TMP/bin"

cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"pr view"*) printf '{"state":"OPEN","mergeStateStatus":"BLOCKED","reviewDecision":""}\n' ;;
  *"pr list"*) printf '1\n' ;;
  *) printf '{}\n' ;;
esac
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export FORGE=github
export GH_CMD="$TMP/bin/gh"

MAIN_REPO="$TMP/main-repo"
WT_REPO="$TMP/wt-repo"
mkdir -p "$MAIN_REPO"
git -C "$MAIN_REPO" init -q -b main
git -C "$MAIN_REPO" remote add origin https://github.com/o/r.git
git -C "$MAIN_REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$MAIN_REPO" worktree add -q -b feat/test "$WT_REPO"
mkdir -p "$WT_REPO/.agents" "$MAIN_REPO/.agents"
printf 'ok\n' > "$WT_REPO/work.txt"
printf 'ok\n' > "$MAIN_REPO/work.txt"

ARTIFACT_DIR="$T3CODE_HOME/userdata/providers/antigravity/hash1/antigravity-acp/brain/conv-1"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

run_adapter() {
    local json="$1"
    shift
    printf '%s' "$json" | env "$@" bash "$ADAPTER" 2>"$TMP/last.err"
}

assert_pass() {
    local label="$1" json="$2"
    shift 2
    local out rc
    out="$(run_adapter "$json" "$@")"; rc=$?
    if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
        ok "$label"
    else
        bad "$label (rc=$rc stdout=<$out> stderr=<$(cat "$TMP/last.err")>)"
    fi
}

assert_deny() {
    local label="$1" needle="$2" json="$3"
    shift 3
    local out rc dec reason
    out="$(run_adapter "$json" "$@")"; rc=$?
    dec="$(printf '%s' "$out" | jq -r '.decision // empty' 2>/dev/null || true)"
    reason="$(printf '%s' "$out" | jq -r '.reason // empty' 2>/dev/null || true)"
    if [ "$rc" -eq 0 ] && [ "$dec" = "deny" ]; then
        if [ -z "$needle" ] || grep -qiF -- "$needle" <<<"$reason"; then
            ok "$label"
        else
            bad "$label (deny reason lacks '$needle': $reason)"
        fi
    else
        bad "$label (expected deny rc=0; got rc=$rc stdout=<$out> stderr=<$(cat "$TMP/last.err")>)"
    fi
}

make_pre() {
    local tool="$1" args_json="$2" cwd="${3:-$WT_REPO}"
    jq -cn --arg t "$tool" --argjson a "$args_json" --arg cwd "$cwd" --arg art "$ARTIFACT_DIR" '{
        hookEventName: "PreToolUse",
        conversationId: "conv-1",
        cwd: $cwd,
        artifactDirectoryPath: $art,
        transcriptPath: ($art + "/transcript_full.jsonl"),
        toolCall: { id: "call_1", name: $t, args: $a }
    }'
}

echo "== 1. Clean PreToolUse passes (0-byte stdout + exit 0) =="
assert_pass "benign run_command fixture" "$(jq --arg c "$WT_REPO" '.cwd = $c | .toolCall.args.CommandLine = "git status"' "$FIX/pre-run-command.json")"
assert_pass "benign read_file fixture" "$(jq --arg c "$WT_REPO" --arg p "$WT_REPO/work.txt" '.cwd = $c | .toolCall.args.Path = $p' "$FIX/pre-read-file.json")"
assert_pass "worktree edit_file fixture" "$(jq --arg c "$WT_REPO" --arg p "$WT_REPO/work.txt" '.cwd = $c | .toolCall.args.Path = $p' "$FIX/pre-edit-file.json")"
assert_pass "worktree write_file fixture" "$(jq --arg c "$WT_REPO" --arg p "$WT_REPO/new.txt" '.cwd = $c | .toolCall.args.Path = $p' "$FIX/pre-write-file.json")"
assert_pass "invoke_subagent allowed (decision 1246 1C)" "$(cat "$FIX/pre-invoke-subagent.json")"
assert_pass "send_message allowed" "$(cat "$FIX/pre-send-message.json")"
assert_pass "ask_question allowed" "$(make_pre ask_question '{"questions":[]}')"
assert_pass "search_web allowed" "$(make_pre search_web '{"query":"test"}')"
assert_pass "list_resources allowed" "$(make_pre list_resources '{"ServerName":"t3-code"}')"
assert_pass "read_resource allowed" "$(make_pre read_resource '{"ServerName":"t3-code","Uri":"x"}')"
assert_pass "benign mcp_t3-code_t3_environment_read fixture" "$(cat "$FIX/pre-mcp-t3-code.json")"
assert_pass "write_file inside session artifactDirectoryPath allowed" "$(make_pre write_file "$(jq -cn --arg p "$ARTIFACT_DIR/plan.md" '{Path:$p,Content:"ok"}')")"

echo "== 2. Core invariant deny-guards through adapter =="
assert_deny "block-edit-on-main denies edit_file in primary main" "main" \
    "$(make_pre edit_file "$(jq -cn --arg p "$MAIN_REPO/work.txt" '{Path:$p,Target:"ok",Replacement:"x"}')" "$MAIN_REPO")"
assert_deny "block-read-secrets denies read_file on .env" "secret" \
    "$(make_pre read_file '{"Path":"/tmp/project/.env"}')"
assert_deny "block-read-secrets denies run_command cat .env" "secret" \
    "$(make_pre run_command '{"CommandLine":"cat /tmp/project/.env"}')"
assert_deny "block-destructive-commands denies rm -rf" "destructive" \
    "$(make_pre run_command '{"CommandLine":"rm -rf /tmp/x"}')"
assert_deny "block-docker-privesc denies privileged docker" "privileged" \
    "$(make_pre run_command '{"CommandLine":"docker run --privileged alpine sh"}')"
assert_deny "block-rogue-claude-schedule denies crontab claude" "schedule" \
    "$(make_pre run_command '{"CommandLine":"echo \"0 4 * * * claude go\" | crontab -"}')"
assert_deny "block-merged-pr-commit denies commit on merged PR branch" "merged" \
    "$(make_pre run_command '{"CommandLine":"git commit -m test"}')"
assert_deny "block-terminal-write-fence denies git push" "external-write" \
    "$(make_pre run_command '{"CommandLine":"git push origin feat/test"}')"
assert_deny "block-git-stash denies git stash push" "stash" \
    "$(make_pre run_command '{"CommandLine":"git stash push -m x"}')"
assert_deny "guard-t3-thread-tools denies off-allowlist instance" "antigravity" \
    "$(make_pre mcp_t3-code_t3_thread_launch '{"title":"Work","modelSelection":{"instanceId":"antigravity","model":"gemini-4-neon"}}')"
assert_deny "guard-t3-thread-tools denies -chief title" "chief" \
    "$(make_pre mcp_t3-code_t3_thread_update '{"action":"rename","title":"ops-chief"}')"
assert_deny "block-t3code-unwatch-open-pr denies unwatch on OPEN PR" "OPEN" \
    "$(make_pre mcp_t3-code_unwatch_pull_request '{"url":"https://github.com/o/r/pull/99"}')"

FAKE_BACKENDS="$TMP/backends.json"
cat > "$FAKE_BACKENDS" <<'EOF'
{
  "jira": {
    "enabled": true,
    "mcp_prefixes": ["mcp__t3-code__"],
    "cli": "scripts/jira/dist/index.js",
    "chain": ["cli"]
  }
}
EOF
assert_deny "block-backend-tier wired on MCP chain" "block-backend-tier" \
    "$(make_pre mcp_t3-code_getJiraIssue '{}')" BACKENDS_REGISTRY="$FAKE_BACKENDS"

echo "== 3. Frozen tool inventory, unlisted MCP, and malformed input =="
for dt in schedule swarm run_workflow define_subagent manage_subagents manage_task; do
    assert_deny "denied built-in tool $dt" "denied" "$(make_pre "$dt" '{}')"
done
assert_deny "unknown tool fails closed" "unrecognized" "$(make_pre unknown_tool_xyz '{}')"
assert_deny "unlisted MCP server denied" "not allowlisted" "$(make_pre mcp_evil_run '{}')"
assert_deny "malformed JSON stdin fails closed" "malformed" "{not-json"

echo "== 4. Bypass *_OK stripping =="
assert_deny "CODEX_EXTERNAL_WRITES_OK=1 stripped" "external-write" \
    "$(make_pre run_command '{"CommandLine":"git push origin feat/test"}')" CODEX_EXTERNAL_WRITES_OK=1
assert_deny "READ_SECRETS_OK=1 stripped" "secret" \
    "$(make_pre read_file '{"Path":"/tmp/project/.env"}')" READ_SECRETS_OK=1
assert_deny "T3_THREAD_TOOLS_OK=1 stripped" "chief" \
    "$(make_pre mcp_t3-code_t3_thread_update '{"action":"rename","title":"ops-chief"}')" T3_THREAD_TOOLS_OK=1

echo "== 5. Both-home and .agents/** self-protect =="
assert_deny "edit_file on worktree .agents/hooks.json denied" "self-protect" \
    "$(make_pre edit_file "$(jq -cn --arg p "$WT_REPO/.agents/hooks.json" '{Path:$p,Target:"a",Replacement:"b"}')")"
assert_deny "write_file on worktree .agents/skills.json denied" "self-protect" \
    "$(make_pre write_file "$(jq -cn --arg p "$WT_REPO/.agents/skills.json" '{Path:$p,Content:"{}"}')" )"
assert_deny "write_file on ~/.gemini/config/hooks.json denied" "self-protect" \
    "$(make_pre write_file "$(jq -cn --arg p "$HOME/.gemini/config/hooks.json" '{Path:$p,Content:"{}"}')" )"
assert_deny "write_file on T3 antigravity config/hooks.json denied" "self-protect" \
    "$(make_pre write_file "$(jq -cn --arg p "$T3CODE_HOME/userdata/providers/antigravity/hash1/config/hooks.json" '{Path:$p,Content:"{}"}')" )"
assert_deny "read_file on antigravity-oauth-token denied" "oauth-token" \
    "$(make_pre read_file "$(jq -cn --arg p "$T3CODE_HOME/userdata/providers/antigravity/hash1/antigravity-oauth-token" '{Path:$p}')" )"
assert_deny "run_command writing .agents/hooks.json denied" "self-protect" \
    "$(make_pre run_command '{"CommandLine":"echo {} > .agents/hooks.json"}')"
assert_deny "run_command writing .agents/skills/x/SKILL.md denied" "self-protect" \
    "$(make_pre run_command '{"CommandLine":"echo x > .agents/skills/x/SKILL.md"}')"
assert_pass "run_command reading .agents/skills/x/SKILL.md allowed" \
    "$(make_pre run_command '{"CommandLine":"cat .agents/skills/x/SKILL.md"}')"

echo "== 6. Child invoke_subagent payload and lifecycle events =="
assert_deny "child invoke_subagent reading .env denied" "secret" "$(cat "$FIX/child-pre-read-file-secret.json")"

out_ss="$(run_adapter "$(jq --arg c "$WT_REPO" '.cwd = $c' "$FIX/session-start.json")")"; rc_ss=$?
if [ "$rc_ss" -eq 0 ] && [ -z "$out_ss" ]; then ok "SessionStart exits 0 cleanly"; else bad "SessionStart (rc=$rc_ss out=<$out_ss>)"; fi

out_post="$(run_adapter "$(jq --arg c "$WT_REPO" '.cwd = $c' "$FIX/post-run-command.json")")"; rc_post=$?
if [ "$rc_post" -eq 0 ] && [ "$out_post" = "{}" ]; then ok "PostToolUse exits 0 with {}"; else bad "PostToolUse (rc=$rc_post out=<$out_post>)"; fi

out_stop="$(run_adapter "$(cat "$FIX/stop.json")")"; rc_stop=$?
if [ "$rc_stop" -eq 0 ] && [ -z "$out_stop" ]; then ok "Stop exits 0 cleanly"; else bad "Stop (rc=$rc_stop out=<$out_stop>)"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
