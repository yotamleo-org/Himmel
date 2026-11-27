#!/usr/bin/env bash
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

# shellcheck source=lib-fixture-root.sh
# shellcheck disable=SC1091
. "$HOOKS/lib-fixture-root.sh"
_FROOT="$(fixture_root)" || exit 1
# prim-ok: the fixture must sit outside every temp path or the main-checkout fence exempts it
TMP="$(mktemp -d "$_FROOT/.himmel-agy-adapter-e2e-XXXXXX")" || exit 1
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
printf '{"providerInstances":{"claudeBypass":{"driver":"claudeAgent","environment":[{"name":"AGENTS_MD_OK","value":"1"}]}}}\n' > "$T3CODE_HOME/userdata/settings.json"

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
mkdir -p "$WT_REPO/.agents/skills/x" "$MAIN_REPO/.agents"
printf '{}\n' > "$WT_REPO/.agents/hooks.json"
printf 'ok\n' > "$WT_REPO/.agents/skills/x/SKILL.md"
printf 'ok\n' > "$WT_REPO/work.txt"
printf 'ok\n' > "$MAIN_REPO/work.txt"
mkdir -p "$HOME/.agents/skills/sk" "$HOME/.claude/skills"
printf 'ok\n' > "$HOME/.agents/skills/sk/SKILL.md"
ln -s ../../.agents/skills/sk "$HOME/.claude/skills/sk"
ln -s "$WT_REPO/.agents/hooks.json" "$WT_REPO/lnk-hooks"
ln -s "$HOME/.gemini/config" "$WT_REPO/lnk-gemini"
ln -s "$T3CODE_HOME/userdata/providers/antigravity/hash1/config" "$WT_REPO/lnk-t3"

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
    local rc
    run_adapter "$json" "$@" >"$TMP/last.out"; rc=$?
    if [ "$rc" -eq 0 ] && [ ! -s "$TMP/last.out" ]; then
        ok "$label"
    else
        bad "$label (rc=$rc stdout=<$(cat "$TMP/last.out")> stderr=<$(cat "$TMP/last.err")>)"
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
assert_pass "exit_plan_mode allowed" "$(make_pre exit_plan_mode '{}')"
assert_pass "update_steps allowed" "$(make_pre update_steps '{"steps":[]}')"
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
assert_deny "block-rogue-codex-exec denies raw codex exec" "codex" \
    "$(make_pre run_command '{"CommandLine":"codex exec hi"}')"
assert_deny "require-quiet-run denies bare shell test suite" "quiet-run" \
    "$(make_pre run_command '{"CommandLine":"bash scripts/hooks/test-block-git-stash.sh"}')"
assert_deny "block-tail-pipe-on-gates denies piping gate to tail" "tail" \
    "$(make_pre run_command '{"CommandLine":"bash scripts/ci/run-shell-tests.sh | tail -n 5"}')"
assert_deny "block-write-into-main-checkout denies writing main from worktree" "main" \
    "$(make_pre run_command "$(jq -cn --arg c "echo x > $MAIN_REPO/work.txt" '{CommandLine:$c}')")"
assert_deny "block-chokepoint-env-prefix denies env-prefixed chokepoint" "chokepoint" \
    "$(make_pre run_command '{"CommandLine":"CODEX_BIN=/tmp/x bash scripts/codex/dispatch-codex-exec.sh"}')"
# shellcheck disable=SC2016
assert_deny "block-jira-compound-write denies compound jira create" "desc-file" \
    "$(make_pre run_command '{"CommandLine":"JIRA_PROJECT_KEY=HIMMEL node /tmp/himmel/scripts/jira/dist/index.js create --type Task --title a --desc \"$(cat /tmp/a.md)\" ; node /tmp/himmel/scripts/jira/dist/index.js create --type Task --title b --desc \"$(cat /tmp/b.md)\""}')"
assert_deny "guard-t3-thread-tools denies a bypass instance" "carries a himmel bypass flag" \
    "$(make_pre mcp_t3-code_t3_thread_launch '{"title":"Work","modelSelection":{"instanceId":"claudeBypass","model":"claude-opus-5-5"}}')"
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
assert_deny "made-up near-name exit_plan_mode_x still fails closed" "unrecognized" "$(make_pre exit_plan_mode_x '{}')"
assert_deny "made-up near-name update_steps_x still fails closed" "unrecognized" "$(make_pre update_steps_x '{}')"

TAINT_HOME="$TMP/taint-home"
mkdir -p "$TAINT_HOME/.himmel/peer-bridge/taint"
: > "$TAINT_HOME/.himmel/peer-bridge/taint/conv-1"
assert_deny "exit_plan_mode denied when the session is peer-tainted" "peer-taint-gate" \
    "$(make_pre exit_plan_mode '{}')" HOME="$TAINT_HOME"
assert_deny "update_steps denied when the session is peer-tainted" "peer-taint-gate" \
    "$(make_pre update_steps '{"steps":[]}')" HOME="$TAINT_HOME"
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
assert_deny "run_command git restore -s show .agents/hooks.json denied" "self-protect" \
    "$(make_pre run_command '{"CommandLine":"git restore -s show .agents/hooks.json"}')"
assert_deny "run_command git checkout log -- .agents/hooks.json denied" "self-protect" \
    "$(make_pre run_command '{"CommandLine":"git checkout log -- .agents/hooks.json"}')"
assert_deny "run_command git mv .agents/hooks.json denied" "self-protect" \
    "$(make_pre run_command '{"CommandLine":"git mv .agents/hooks.json /tmp/x"}')"
assert_deny "run_command git rm .agents/skills.json denied" "self-protect" \
    "$(make_pre run_command '{"CommandLine":"git rm .agents/skills.json"}')"
assert_deny "run_command git diff --output=.agents/hooks.json denied" "self-protect" \
    "$(make_pre run_command '{"CommandLine":"git diff --output=.agents/hooks.json"}')"
assert_deny "run_command git diff -- .agents/hooks.json denied (diff.external)" "self-protect" \
    "$(make_pre run_command '{"CommandLine":"git diff -- .agents/hooks.json"}')"
assert_deny "run_command git -c diff.external=sh diff .agents/hooks.json denied" "self-protect" \
    "$(make_pre run_command '{"CommandLine":"git -c diff.external=sh diff .agents/hooks.json"}')"
assert_deny "run_command git -p status .agents/hooks.json denied" "self-protect" \
    "$(make_pre run_command '{"CommandLine":"git -p status .agents/hooks.json"}')"
assert_deny "run_command git log --out=.agents/hooks.json denied" "self-protect" \
    "$(make_pre run_command '{"CommandLine":"git log --out=.agents/hooks.json"}')"
assert_deny "run_command rg --pre rm x .agents/hooks.json denied" "self-protect" \
    "$(make_pre run_command '{"CommandLine":"rg --pre rm x .agents/hooks.json"}')"
assert_deny "run_command rg --pre=rm x .agents/hooks.json denied" "self-protect" \
    "$(make_pre run_command '{"CommandLine":"rg --pre=rm x .agents/hooks.json"}')"
assert_deny "run_command rg quoted --pre rm x .agents/hooks.json denied" "self-protect" \
    "$(make_pre run_command '{"CommandLine":"rg '\''--pre'\'' rm x .agents/hooks.json"}')"
assert_deny "run_command rg backslash-split --pre=rm x .agents/hooks.json denied" "self-protect" \
    "$(make_pre run_command '{"CommandLine":"rg --p\\re=rm x .agents/hooks.json"}')"
assert_deny "run_command rg --pre-glob x .agents/hooks.json denied" "self-protect" \
    "$(make_pre run_command '{"CommandLine":"rg --pre-glob hooks.json x .agents/hooks.json"}')"
assert_deny "run_command rg --pre-glob=hooks.json x .agents/hooks.json denied" "self-protect" \
    "$(make_pre run_command '{"CommandLine":"rg --pre-glob=hooks.json x .agents/hooks.json"}')"
assert_deny "run_command rg --hostname-bin rm x .agents/hooks.json denied" "self-protect" \
    "$(make_pre run_command '{"CommandLine":"rg --hostname-bin rm x .agents/hooks.json"}')"
assert_deny "run_command rg --hostname-bin=rm x .agents/hooks.json denied" "self-protect" \
    "$(make_pre run_command '{"CommandLine":"rg --hostname-bin=rm x .agents/hooks.json"}')"
# shellcheck disable=SC2016
assert_deny "run_command rg ANSI-C --pre=rm x .agents/hooks.json denied" "self-protect" \
    "$(make_pre run_command '{"CommandLine":"rg $'\''--pre=rm'\'' x .agents/hooks.json"}')"
assert_deny "run_command rg brace-expanded --pre=rm x .agents/hooks.json denied" "self-protect" \
    "$(make_pre run_command '{"CommandLine":"rg --{pre,x}=rm x .agents/hooks.json"}')"
assert_deny "run_command rg PreToolUse .agents/hooks.json denied (default-deny)" "self-protect" \
    "$(make_pre run_command '{"CommandLine":"rg PreToolUse .agents/hooks.json"}')"
assert_deny "run_command git show HEAD:.agents/hooks.json denied (default-deny)" "self-protect" \
    "$(make_pre run_command '{"CommandLine":"git show HEAD:.agents/hooks.json"}')"
assert_deny "run_command git -C wt status .agents/hooks.json denied (default-deny)" "self-protect" \
    "$(make_pre run_command "$(jq -cn --arg c "git -C $WT_REPO status .agents/hooks.json" '{CommandLine:$c}')")"
assert_deny "run_command writing .agents/skills/x/SKILL.md denied" "self-protect" \
    "$(make_pre run_command '{"CommandLine":"echo x > .agents/skills/x/SKILL.md"}')"
assert_deny "run_command reading .agents/skills/x/SKILL.md denied (default-deny)" "self-protect" \
    "$(make_pre run_command '{"CommandLine":"cat .agents/skills/x/SKILL.md"}')"
assert_deny "run_command mv .agents x denied" "self-protect" \
    "$(make_pre run_command '{"CommandLine":"mv .agents x"}')"
assert_deny "run_command cd .agents && rm hooks.json denied" "self-protect" \
    "$(make_pre run_command '{"CommandLine":"cd .agents && rm hooks.json"}')"
assert_deny "run_command cp hooks.json .agents trailing space denied" "self-protect" \
    "$(make_pre run_command '{"CommandLine":"cp hooks.json .agents "}')"
assert_deny "run_command cd .agents; rm hooks.json denied" "self-protect" \
    "$(make_pre run_command '{"CommandLine":"cd .agents; rm hooks.json"}')"
assert_deny "run_command cd .agents&&rm hooks.json denied" "self-protect" \
    "$(make_pre run_command '{"CommandLine":"cd .agents&&rm hooks.json"}')"
assert_deny "run_command mv .agents<tab>x denied" "self-protect" \
    "$(make_pre run_command '{"CommandLine":"mv .agents\tx"}')"
assert_deny "run_command cd ~/.gemini && mv config c2 denied" "self-protect" \
    "$(make_pre run_command '{"CommandLine":"cd ~/.gemini && mv config c2"}')"
assert_deny "run_command ls ~/.gemini (no subpath) denied" "self-protect" \
    "$(make_pre run_command '{"CommandLine":"ls ~/.gemini"}')"
assert_deny "run_command write through ~/.claude/skills symlink into ~/.agents denied" "self-protect" \
    "$(make_pre run_command '{"CommandLine":"echo x > ~/.claude/skills/sk/SKILL.md"}')"
# shellcheck disable=SC2016
assert_deny "run_command write through \$HOME/.claude/skills symlink denied" "self-protect" \
    "$(make_pre run_command '{"CommandLine":"echo x > $HOME/.claude/skills/sk/SKILL.md"}')"
assert_deny "run_command write through absolute .claude/skills symlink denied" "self-protect" \
    "$(make_pre run_command "$(jq -cn --arg c "echo x > $HOME/.claude/skills/sk/SKILL.md" '{CommandLine:$c}')")"
assert_deny "run_command relative scratch symlink onto .agents/hooks.json denied" "self-protect" \
    "$(make_pre run_command '{"CommandLine":"echo {} > lnk-hooks"}')"
assert_deny "run_command no-space redirect through scratch symlink denied" "self-protect" \
    "$(make_pre run_command '{"CommandLine":"echo {} >lnk-hooks"}')"
assert_deny "run_command dd of= through scratch symlink denied" "self-protect" \
    "$(make_pre run_command '{"CommandLine":"dd if=/dev/null of=lnk-hooks"}')"
assert_deny "run_command write through symlink into ~/.gemini/config denied" "self-protect" \
    "$(make_pre run_command '{"CommandLine":"echo {} > lnk-gemini/hooks.json"}')"
assert_deny "run_command write through symlink into T3 antigravity home denied" "self-protect" \
    "$(make_pre run_command '{"CommandLine":"echo {} > lnk-t3/hooks.json"}')"
assert_deny "run_command direct write ~/.gemini/config/hooks.json denied" "self-protect" \
    "$(make_pre run_command '{"CommandLine":"echo {} > ~/.gemini/config/hooks.json"}')"
assert_deny "run_command direct write T3 antigravity config denied" "self-protect" \
    "$(make_pre run_command "$(jq -cn --arg c "echo {} > $T3CODE_HOME/userdata/providers/antigravity/hash1/config/hooks.json" '{CommandLine:$c}')")"
assert_pass "run_command ls -la ~/.claude/skills (the directory itself, no symlink into .agents) allowed" \
    "$(make_pre run_command '{"CommandLine":"ls -la ~/.claude/skills"}')"
assert_pass "run_command echo to ordinary worktree file allowed" \
    "$(make_pre run_command '{"CommandLine":"echo ok > work.txt"}')"
assert_pass "read_file on worktree .agents/hooks.json allowed" \
    "$(make_pre read_file "$(jq -cn --arg p "$WT_REPO/.agents/hooks.json" '{Path:$p}')")"
assert_pass "read_file on worktree .agents/skills/x/SKILL.md allowed" \
    "$(make_pre read_file "$(jq -cn --arg p "$WT_REPO/.agents/skills/x/SKILL.md" '{Path:$p}')")"
assert_deny "read_file with empty Path denied" "empty" \
    "$(make_pre read_file '{"Path":""}')"

echo "== 6. Child invoke_subagent payload and lifecycle events =="
assert_deny "child invoke_subagent reading .env denied" "secret" "$(cat "$FIX/child-pre-read-file-secret.json")"

run_adapter "$(jq --arg c "$WT_REPO" '.cwd = $c' "$FIX/session-start.json")" >"$TMP/last.out"; rc_ss=$?
if [ "$rc_ss" -eq 0 ] && [ ! -s "$TMP/last.out" ]; then ok "SessionStart exits 0 cleanly"; else bad "SessionStart (rc=$rc_ss out=<$(cat "$TMP/last.out")>)"; fi

out_post="$(run_adapter "$(jq --arg c "$WT_REPO" '.cwd = $c' "$FIX/post-run-command.json")")"; rc_post=$?
if [ "$rc_post" -eq 0 ] && [ "$out_post" = "{}" ]; then ok "PostToolUse exits 0 with {}"; else bad "PostToolUse (rc=$rc_post out=<$out_post>)"; fi

run_adapter "$(cat "$FIX/stop.json")" >"$TMP/last.out"; rc_stop=$?
if [ "$rc_stop" -eq 0 ] && [ ! -s "$TMP/last.out" ]; then ok "Stop exits 0 cleanly"; else bad "Stop (rc=$rc_stop out=<$(cat "$TMP/last.out")>)"; fi

echo "== 7. S2b read fence, graphify-fence, and T3 MCP parity with the Claude lane =="
assert_deny "read_file on T3 provider config/hooks.json denied by read fence" "provider home" \
    "$(make_pre read_file "$(jq -cn --arg p "$T3CODE_HOME/userdata/providers/antigravity/hash1/config/hooks.json" '{Path:$p}')")"
assert_deny "read_file on ~/.gemini/config/hooks.json denied by read fence" ".gemini" \
    "$(make_pre read_file "$(jq -cn --arg p "$HOME/.gemini/config/hooks.json" '{Path:$p}')")"
assert_deny "read_resource on antigravity-oauth-token denied by read fence" "oauth-token" \
    "$(make_pre read_resource "$(jq -cn --arg u "file://$T3CODE_HOME/userdata/providers/antigravity/hash1/antigravity-oauth-token" '{ServerName:"t3-code",Uri:$u}')")"
assert_pass "read_file inside session artifactDirectoryPath allowed" \
    "$(make_pre read_file "$(jq -cn --arg p "$ARTIFACT_DIR/plan.md" '{Path:$p}')")"

SALUS_FX="$TMP/salus-fx"
mkdir -p "$SALUS_FX"
touch "$SALUS_FX/.salus"
assert_deny "block-graphify-egress denies cloud graphify on salus" "salus" \
    "$(make_pre run_command "$(jq -cn --arg c "graphify update $SALUS_FX --backend deepseek" '{CommandLine:$c}')")" \
    CLAUDE_GLM_CONFIG_DIR="$TMP/empty-glm"

for t3_tool in preview_open preview_act preview_navigate preview_snapshot preview_evaluate preview_list schedule_task pull_request_merge pull_request_create \
               t3_thread_search t3_thread_list t3_thread_read t3_thread_send t3_thread_transfer \
               t3_thread_launch create_threads delegate_task ci_rerun create_issue \
               t3_environment_read pull_request_read ci_logs read_issue send_to_user html_preview html_render; do
    assert_pass "T3 tool mcp_t3-code_$t3_tool follows the shared chain, as on the Claude lane" \
        "$(make_pre "mcp_t3-code_$t3_tool" '{}')"
done
assert_pass "t3_thread_launch with an allowlisted instance passes the shared chain" \
    "$(make_pre mcp_t3-code_t3_thread_launch '{"title":"Work","modelSelection":{"instanceId":"claudeAgent","model":"claude-sonnet-5-5"}}')"

echo "== 8. Non-himmel cwd: luna and salus vaults =="
mk_vault() {
    local d="$1"
    mkdir -p "$d"
    git -C "$d" init -q -b main
    git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    printf 'ok\n' > "$d/note.md"
}
LUNA_FX="$TMP/luna-fx"; mk_vault "$LUNA_FX"; touch "$LUNA_FX/.single-writer"
LUNA_NOSW="$TMP/luna-nosw-fx"; mk_vault "$LUNA_NOSW"
SALUS_VAULT="$TMP/salus-vault-fx"; mk_vault "$SALUS_VAULT"; touch "$SALUS_VAULT/.single-writer" "$SALUS_VAULT/.salus"
assert_pass "luna cwd: benign run_command is not failed closed" \
    "$(make_pre run_command '{"CommandLine":"git status"}' "$LUNA_FX")"
assert_pass "luna cwd with .single-writer: edit_file on main allowed" \
    "$(make_pre edit_file "$(jq -cn --arg p "$LUNA_FX/note.md" '{Path:$p,Target:"ok",Replacement:"x"}')" "$LUNA_FX")"
assert_deny "luna cwd without .single-writer: edit_file on main denied" "main" \
    "$(make_pre edit_file "$(jq -cn --arg p "$LUNA_NOSW/note.md" '{Path:$p,Target:"ok",Replacement:"x"}')" "$LUNA_NOSW")"
assert_deny "luna cwd: read_file on .env still denied" "secret" \
    "$(make_pre read_file "$(jq -cn --arg p "$LUNA_FX/.env" '{Path:$p}')" "$LUNA_FX")"
assert_pass "salus cwd: read_file on a vault note allowed for agy" \
    "$(make_pre read_file "$(jq -cn --arg p "$SALUS_VAULT/note.md" '{Path:$p}')" "$SALUS_VAULT")"
assert_pass "salus cwd: edit_file in the vault allowed for agy" \
    "$(make_pre edit_file "$(jq -cn --arg p "$SALUS_VAULT/note.md" '{Path:$p,Target:"ok",Replacement:"x"}')" "$SALUS_VAULT")"
assert_deny "salus cwd: read_file on .env still denied" "secret" \
    "$(make_pre read_file "$(jq -cn --arg p "$SALUS_VAULT/.env" '{Path:$p}')" "$SALUS_VAULT")"
assert_deny "salus cwd: run_command cat .env still denied" "secret" \
    "$(make_pre run_command "$(jq -cn --arg c "cat $SALUS_VAULT/.env" '{CommandLine:$c}')" "$SALUS_VAULT")"
assert_deny "salus cwd: provider-home read still denied" "provider home" \
    "$(make_pre read_file "$(jq -cn --arg p "$T3CODE_HOME/userdata/providers/antigravity/hash1/config/hooks.json" '{Path:$p}')" "$SALUS_VAULT")"
assert_deny "salus cwd: ~/.gemini/config read still denied" ".gemini" \
    "$(make_pre read_file "$(jq -cn --arg p "$HOME/.gemini/config/hooks.json" '{Path:$p}')" "$SALUS_VAULT")"
assert_deny "salus cwd: git push still denied" "external-write" \
    "$(make_pre run_command '{"CommandLine":"git push origin main"}' "$SALUS_VAULT")"

echo "== 9. Design MCP servers: eager mcp_* and lazy call_mcp_tool =="
OTHER_ARTIFACT_DIR="$ARTIFACT_DIR"
if command -v sha256sum >/dev/null 2>&1; then
    DESIGN_HEX="$(printf '%s' antigravity_design | sha256sum)"
else
    DESIGN_HEX="$(printf '%s' antigravity_design | shasum -a 256)"
fi
ARTIFACT_DIR="$T3CODE_HOME/userdata/providers/antigravity/${DESIGN_HEX%% *}/antigravity-acp/brain/conv-1"
mkdir -p "$ARTIFACT_DIR"
make_lazy() {
    local srv="$1" tool="$2" args_json="${3:-}"
    [ -n "$args_json" ] || args_json='{}'
    make_pre call_mcp_tool "$(jq -cn --arg s "$srv" --arg t "$tool" --argjson a "$args_json" '{ServerName:$s,ToolName:$t,Arguments:$a}')"
}
for srv_tool in context7:query-docs context7:resolve-library-id shadcn:search_items_in_registries playwright:browser_snapshot; do
    srv="${srv_tool%%:*}"; tool="${srv_tool#*:}"
    assert_pass "eager mcp_${srv}_${tool} allowed" "$(make_pre "mcp_${srv}_${tool}" '{}')"
    assert_pass "lazy call_mcp_tool ${srv}/${tool} allowed" "$(make_lazy "$srv" "$tool" '{"q":"x"}')"
done
assert_pass "lazy call_mcp_tool without Arguments allowed" \
    "$(make_pre call_mcp_tool '{"ServerName":"shadcn","ToolName":"get_audit_checklist"}')"
assert_pass "lazy call_mcp_tool graphify keeps the mcp_* allowlist" "$(make_lazy graphify graph_stats)"
assert_pass "lazy call_mcp_tool with a string toolSummary allowed" \
    "$(make_pre call_mcp_tool '{"ServerName":"context7","ToolName":"query-docs","Arguments":{"q":"x"},"toolSummary":"Look up docs"}')"
SUMMARY_LOG="$TMP/mcp-policy-summary.jsonl"
run_adapter "$(make_pre call_mcp_tool '{"ServerName":"context7","ToolName":"query-docs","toolSummary":"evil"}')" MCP_POLICY_AUDIT_LOG="$SUMMARY_LOG" >/dev/null
if jq -e 'select(.server == "context7" and .tool == "query-docs")' "$SUMMARY_LOG" >/dev/null 2>&1; then
    ok "toolSummary is never read as a server or tool"
else
    bad "toolSummary changed the translated call (log=<$(cat "$SUMMARY_LOG" 2>/dev/null)>)"
fi
assert_deny "lazy call_mcp_tool t3-code runs the thread-tool guard" "carries a himmel bypass flag" \
    "$(make_lazy t3-code t3_thread_launch '{"title":"Work","modelSelection":{"instanceId":"claudeBypass","model":"claude-opus-5-5"}}')"
assert_deny "lazy call_mcp_tool t3-code unwatch on OPEN PR denied" "OPEN" \
    "$(make_lazy t3-code unwatch_pull_request '{"url":"https://github.com/o/r/pull/99"}')"
assert_deny "lazy call_mcp_tool runs block-backend-tier on the translated name" "block-backend-tier" \
    "$(make_lazy t3-code getJiraIssue)" BACKENDS_REGISTRY="$FAKE_BACKENDS"
assert_deny "lazy call_mcp_tool is peer-taint gated" "peer-taint-gate" \
    "$(make_lazy context7 query-docs)" HOME="$TAINT_HOME"

POLICY_LOG="$TMP/mcp-policy-audit.jsonl"
run_adapter "$(make_lazy context7 query-docs '{"libraryId":"x"}')" MCP_POLICY_AUDIT_LOG="$POLICY_LOG" >/dev/null
if jq -e 'select(.server == "context7" and .tool == "query-docs" and .verdict == "allow")' "$POLICY_LOG" >/dev/null 2>&1; then
    ok "lazy call_mcp_tool reaches mcp-policy.sh as mcp__context7__query-docs"
else
    bad "lazy call_mcp_tool did not reach mcp-policy.sh (log=<$(cat "$POLICY_LOG" 2>/dev/null)>)"
fi
ENFORCE_REG="$TMP/mcp-policy-enforce.json"
printf '{"mode":"enforce","servers":{}}\n' > "$ENFORCE_REG"
assert_deny "an enforce-mode mcp-policy deny stops a lazy design call" "mcp-policy" \
    "$(make_lazy shadcn get_audit_checklist)" MCP_POLICY_REGISTRY="$ENFORCE_REG"

assert_pass "lazy playwright write tool in the registry allowed" "$(make_lazy playwright browser_navigate '{"url":"https://example.com"}')"
for case_variant in '{"ServerName":"context7","ToolName":"query-docs","servername":"evil"}' \
                    '{"ServerName":"playwright","ToolName":"browser_snapshot","toolname":"browser_run_code_unsafe"}' \
                    '{"ServerName":"context7","ToolName":"query-docs","arguments":{}}' \
                    '{"ServerName":"context7\u0000","ToolName":"query-docs"}' \
                    '{"ServerName":"context7","ToolName":"browser_run_code_unsafe","ſerverName":"playwright"}' \
                    '{"ServerName":"context7","ToolName":"query-docs","Key":"playwright"}' \
                    '{"ServerName":"t3-code","ToolName":"t3_thread_launch","Arguments":{"title":"x"},"Argumentſ":{"title":"y"}}' \
                    '{"ServerName":"context7","ToolName":"query-docs","Extra":"z"}' \
                    '{"ServerName":"context7","ToolName":"query-docs","toolAction":"x"}' \
                    '{"ServerName":"context7","ToolName":"query-docs","ToolSummary":"x"}' \
                    '{"ServerName":"context7","ToolName":"query-docs","toolsummary":"x"}' \
                    '{"ServerName":"context7","ToolName":"query-docs","toolSummary":{"ServerName":"evil"}}' \
                    '{"ServerName":"context7","ToolName":"query-docs","toolSummary":null}'; do
    assert_deny "call_mcp_tool args $case_variant denied" "malformed call_mcp_tool" "$(make_pre call_mcp_tool "$case_variant")"
done
for pw_tool in browser_run_code_unsafe browser_evaluate browser_run_code browser_future_tool; do
    assert_deny "lazy playwright $pw_tool denied" "$pw_tool" "$(make_lazy playwright "$pw_tool")"
    assert_deny "eager playwright $pw_tool denied" "$pw_tool" "$(make_pre "mcp_playwright_$pw_tool" '{}')"
done

for bad_srv in evil context7x Context7 plugin_playwright_playwright 'playwright__x' 'shadcn context7' 't3-code|graphify'; do
    assert_deny "lazy call_mcp_tool server '$bad_srv' denied" "MCP server" "$(make_lazy "$bad_srv" run)"
done
assert_deny "lazy server name with a trailing newline denied" "call_mcp_tool" "$(make_lazy $'context7\n' query-docs)"
assert_deny "lazy tool name with a trailing newline denied" "call_mcp_tool" "$(make_lazy playwright $'browser_evaluate\n')"
assert_deny "lazy tool name with a space denied" "call_mcp_tool" "$(make_lazy playwright 'browser_snapshot x')"
assert_deny "lazy tool name carrying a second server segment denied" "call_mcp_tool" "$(make_lazy context7 'x__y')"
for bad_args in '{}' \
                '{"ToolName":"query-docs","Arguments":{}}' \
                '{"ServerName":"context7","Arguments":{}}' \
                '{"ServerName":"","ToolName":"query-docs"}' \
                '{"ServerName":"context7","ToolName":""}' \
                '{"ServerName":["context7"],"ToolName":"query-docs"}' \
                '{"ServerName":"context7","ToolName":7}' \
                '{"ServerName":"context7","ToolName":"query-docs","Arguments":"x"}' \
                '{"ServerName":"context7","ToolName":"query-docs","Arguments":[1]}' \
                '"context7"'; do
    assert_deny "malformed call_mcp_tool args $bad_args denied" "call_mcp_tool" "$(make_pre call_mcp_tool "$bad_args")"
done
assert_deny "eager unlisted MCP server still denied" "not allowlisted" "$(make_pre mcp_evil_query-docs '{}')"

DESIGN_ARTIFACT_DIR="$ARTIFACT_DIR"
HOME_T3_ART="$HOME/.t3/userdata/providers/antigravity/${DESIGN_HEX%% *}/antigravity-acp/brain/conv-1"
ARTIFACT_DIR="$HOME_T3_ART"
assert_pass "design profile under the default \$HOME/.t3 allowed" "$(make_lazy context7 query-docs)"
for other_art in "$OTHER_ARTIFACT_DIR" "" \
    "$TMP/elsewhere/userdata/providers/antigravity/${DESIGN_HEX%% *}/antigravity-acp/brain/conv-1" \
    "$OTHER_ARTIFACT_DIR/userdata/providers/antigravity/${DESIGN_HEX%% *}/antigravity-acp/brain/conv-1""$TMP/home/antigravity-acp/brain/conv-1" "$DESIGN_ARTIFACT_DIR/../../../../hash1/antigravity-acp/brain/conv-1"; do
    ARTIFACT_DIR="$other_art"
    for srv_tool in context7:query-docs shadcn:get_audit_checklist playwright:browser_snapshot; do
        srv="${srv_tool%%:*}"; tool="${srv_tool#*:}"
        assert_deny "outside the design profile, lazy $srv denied (artifact=<$other_art>)" "design profile" "$(make_lazy "$srv" "$tool")"
        assert_deny "outside the design profile, eager $srv denied (artifact=<$other_art>)" "design profile" "$(make_pre "mcp_${srv}_${tool}" '{}')"
    done
done
ARTIFACT_DIR="$OTHER_ARTIFACT_DIR"
assert_pass "outside the design profile, lazy graphify still allowed" "$(make_lazy graphify graph_stats)"
assert_pass "outside the design profile, eager t3-code still allowed" "$(make_pre mcp_t3-code_t3_environment_read '{}')"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
