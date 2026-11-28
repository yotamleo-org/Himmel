#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

# shellcheck source=../lib/override-env.sh
# shellcheck disable=SC1091
. "$REPO/scripts/lib/override-env.sh"
scrub_override_env
unset CLAUDE_GLM_CONFIG_DIR

TMP="$(mktemp -d "${TMPDIR:-/tmp}/t3-guard-conformance.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export RUN_HOOK_CHAIN_RUN_LOG="$TMP/hook-runs.jsonl"
export RUN_HOOK_CHAIN_SKIP_LOG="$TMP/hook-skips.jsonl"
export HIMMEL_ANTIGRAVITY_PROJECT_DIR="$REPO"
export T3CODE_HOME="$TMP/t3home"
mkdir -p "$HOME/.himmel" "$T3CODE_HOME/userdata" "$TMP/bin"
printf '{"providerInstances":{"claudeBypass":{"driver":"claudeAgent","environment":[{"name":"AGENTS_MD_OK","value":"1"}]}}}\n' > "$T3CODE_HOME/userdata/settings.json"

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
    local guard="$1" tool="$2" args="$3" expect="$4" label="$5" want="${6:-}"
    local payload out rc
    payload="$(jq -cn --arg t "mcp__t3-code__$tool" --argjson a "$args" \
        '{hook_event_name:"PreToolUse",tool_name:$t,tool_input:$a,cwd:"/tmp"}')"
    out="$(printf '%s' "$payload" | bash "$REPO/scripts/hooks/$guard" 2>&1)"; rc=$?
    if [ "$expect" = "deny" ]; then
        if [ "$rc" -eq 2 ] && grep -qF -- "$want" <<<"$out"; then ok "claude: $label"; else bad "claude: $label (rc=$rc out=$out)"; fi
    else
        if [ "$rc" -eq 0 ]; then ok "claude: $label"; else bad "claude: $label (rc=$rc out=$out)"; fi
    fi
}

run_codex() {
    local tool="$1" args="$2" expect="$3" label="$4" want="${5:-}"
    local full_tool="${6:-mcp__t3_code__}$tool"
    local cmds="" cmd="" payload="" out="" rc=0 dec="" denied=0
    local -a parts=()
    cmds="$(TOOL_NAME="$full_tool" HOOKS_FILE="$REPO/.codex/hooks.json" node -e '
const fs = require("fs");
const h = JSON.parse(fs.readFileSync(process.env.HOOKS_FILE, "utf8")).hooks || {};
const t = process.env.TOOL_NAME;
for (const b of h.PreToolUse || []) {
  const m = String(b.matcher || "");
  if (!m || m === ".*" || m === "*") continue;
  if (new RegExp("^(?:" + m + ")$").test(t)) {
    for (const e of b.hooks || []) if (e.command) console.log(e.command);
  }
}
')" || { bad "codex: $label (failed to parse .codex/hooks.json)"; return; }
    if [ -z "$cmds" ]; then
        if [ "$expect" = "deny" ]; then bad "codex: $label (no matching PreToolUse hook)"; else ok "codex: $label"; fi
        return
    fi
    payload="$(jq -cn --arg t "$full_tool" --argjson a "$args" \
        '{hook_event_name:"PreToolUse",tool_name:$t,tool_input:$a,cwd:"/tmp"}')"
    while IFS= read -r cmd; do
        [ -n "$cmd" ] || continue
        read -r -a parts <<< "$cmd"
        [ "${#parts[@]}" -gt 0 ] || continue
        out="$(printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$REPO" bash "$REPO/${parts[0]}" "${parts[@]:1}" 2>"$TMP/codex.err")"; rc=$?
        if [ "$rc" -ne 0 ]; then
            bad "codex: $label (rc=$rc out=$out err=$(cat "$TMP/codex.err"))"
            return
        fi
        if [ -n "$out" ]; then
            if ! dec="$(printf '%s' "$out" | jq -r 'if type == "object" then (.hookSpecificOutput.permissionDecision // "") else error("expected object") end' 2>/dev/null)"; then
                bad "codex: $label (malformed adapter JSON: out=$out err=$(cat "$TMP/codex.err"))"
                return
            fi
            if [ "$dec" = "deny" ]; then
                denied=1
                break
            fi
        fi
    done <<< "$cmds"
    if [ "$expect" = "deny" ]; then
        if [ "$denied" -eq 1 ] && grep -qF -- "$want" <<<"$out"; then ok "codex: $label"; else bad "codex: $label (expected deny; rc=$rc out=$out err=$(cat "$TMP/codex.err"))"; fi
    else
        if [ "$denied" -eq 0 ]; then ok "codex: $label"; else bad "codex: $label (unexpected deny; out=$out)"; fi
    fi
}

run_antigravity() {
    local tool="$1" args="$2" expect="$3" label="$4" want="${5:-}"
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
        if [ "$rc" -eq 0 ] && [ "$dec" = "deny" ] && grep -qF -- "$want" <<<"$out"; then ok "antigravity: $label"; else bad "antigravity: $label (rc=$rc out=$out err=$(cat "$TMP/agy.err"))"; fi
    else
        if [ "$rc" -eq 0 ] && [ -z "$out" ]; then ok "antigravity: $label"; else bad "antigravity: $label (rc=$rc out=$out err=$(cat "$TMP/agy.err"))"; fi
    fi
}

run_grok() {
    local tool="$1" args="$2" expect="$3" label="$4" want="${5:-}"
    local name payload out rc
    name="$(jq -r --arg t "$tool" '.tool_map.mcp_prefix | sub("<server>"; "t3-code") | sub("<tool>"; $t)' "$REPO/scripts/harnesses/grok.json")"
    payload="$(jq -cn --arg t "$name" --argjson a "$args" '{hook_event_name:"PreToolUse",tool_name:$t,tool_input:$a,cwd:"/tmp"}')"
    out="$(printf '%s' "$payload" | bash "$REPO/marketplace/plugins/himmel-guard/hooks/translate-tool-call.sh" "$REPO/scripts/hooks/guard-t3-thread-tools.sh" 2>&1)"; rc=$?
    if [ "$expect" = "deny" ]; then
        if [ "$rc" -eq 2 ] && grep -qF -- "$want" <<<"$out"; then ok "grok: $label"; else bad "grok: $label (rc=$rc out=$out)"; fi
    else
        if [ "$rc" -eq 0 ]; then ok "grok: $label"; else bad "grok: $label (rc=$rc out=$out)"; fi
    fi
}

run_cursor() {
    local tool="$1" args="$2" expect="$3" label="$4" want="${5:-}"
    local payload out rc
    payload="$(jq -cn --arg t "mcp__t3-code__$tool" --argjson a "$args" '{hook_event_name:"preToolUse",tool_name:$t,tool_input:$a,cwd:"/tmp"}')"
    out="$(printf '%s' "$payload" | bash "$REPO/scripts/hooks/guard-t3-thread-tools.sh" 2>&1)"; rc=$?
    if [ "$expect" = "deny" ]; then
        if [ "$rc" -eq 2 ] && grep -qF -- "$want" <<<"$out"; then ok "cursor: $label"; else bad "cursor: $label (rc=$rc out=$out)"; fi
    else
        if [ "$rc" -eq 0 ]; then ok "cursor: $label"; else bad "cursor: $label (rc=$rc out=$out)"; fi
    fi
}

run_harness() {
    local id="$1"; shift
    case "$id" in
        claude) run_claude guard-t3-thread-tools.sh "$@" ;;
        codex) run_codex "$@" ;;
        antigravity) run_antigravity "$@" ;;
        grok) run_grok "$@" ;;
        cursor) run_cursor "$@" ;;
        *) bad "$id: the registry names a harness this suite has no runner for" ;;
    esac
}

HARNESS_IDS=""
for f in "$REPO"/scripts/harnesses/*.json; do
    case "$f" in */harness.schema.json) continue ;; esac
    HARNESS_IDS="$HARNESS_IDS $(jq -r '.id' "$f")"
done
if [ "$HARNESS_IDS" = " antigravity claude codex cursor grok" ]; then ok "the registry names the five harnesses"; else bad "unexpected registry harnesses:$HARNESS_IDS"; fi

ARGS_BYPASS='{"title":"Work","message":"go","modelSelection":{"instanceId":"claudeBypass","model":"claude-opus-5-5"}}'
ARGS_CHIEF_TITLE='{"action":"rename","title":"ops-chief"}'
ARGS_UNWATCH_OPEN='{"url":"https://github.com/o/r/pull/123"}'
ARGS_BENIGN='{"toolSummary":"Read env"}'
ARGS_SEND='{"threadId":"thread-1","message":"hello"}'

echo "== T3 guard conformance: claude =="
run_claude guard-t3-thread-tools.sh t3_thread_launch "$ARGS_BYPASS" deny "bypass instance denied" "carries a himmel bypass flag"
run_claude guard-t3-thread-tools.sh t3_thread_update "$ARGS_CHIEF_TITLE" deny "-chief title denied"
run_claude block-t3code-unwatch-open-pr.sh unwatch_pull_request "$ARGS_UNWATCH_OPEN" deny "unwatch OPEN PR denied"
run_claude guard-t3-thread-tools.sh t3_environment_read "$ARGS_BENIGN" allow "benign T3 read allowed"

echo "== T3 guard conformance: codex =="
run_codex t3_thread_launch "$ARGS_BYPASS" deny "bypass instance denied" "carries a himmel bypass flag"
run_codex t3_thread_update "$ARGS_CHIEF_TITLE" deny "-chief title denied"
run_codex unwatch_pull_request "$ARGS_UNWATCH_OPEN" deny "unwatch OPEN PR denied"
run_codex t3_environment_read "$ARGS_BENIGN" allow "benign T3 read allowed"
run_codex delegate_task '{"task":"x","target":{"providerInstanceId":"claudeBypass"}}' deny "direct-server bypass instance denied" "carries a himmel bypass flag" mcp__t3_code_direct__

echo "== T3 guard conformance: antigravity =="
run_antigravity t3_thread_launch "$ARGS_BYPASS" deny "bypass instance denied" "carries a himmel bypass flag"
run_antigravity t3_thread_update "$ARGS_CHIEF_TITLE" deny "-chief title denied"
run_antigravity unwatch_pull_request "$ARGS_UNWATCH_OPEN" deny "unwatch OPEN PR denied"
run_antigravity t3_environment_read "$ARGS_BENIGN" allow "benign T3 read allowed"
run_antigravity t3_thread_send "$ARGS_SEND" allow "send to an existing thread allowed"

echo "== T3 launch verdicts: an agent launches only onto a harness with a complete descriptor =="
for id in $HARNESS_IDS; do
    d="$REPO/scripts/harnesses/$id.json"
    args="$(jq -c '{title:"Work",message:"go",modelSelection:{instanceId:.t3.instance_ids[0],model:"m"}}' "$d")"
    if jq -e '.complete' "$d" >/dev/null; then
        for from in $HARNESS_IDS; do
            run_harness "$from" t3_thread_launch "$args" allow "launch onto $id allowed"
        done
    else
        for from in $HARNESS_IDS; do
            run_harness "$from" t3_thread_launch "$args" deny "launch onto $id denied" "has an incomplete harness descriptor"
        done
    fi
done

echo "== T3 tool parity: every tool gets the same verdict on every registry harness =="
for tool in t3_thread_send t3_thread_launch t3_thread_transfer t3_thread_search t3_thread_list t3_thread_read \
            t3_environment_read t3_project_list t3_project_read pull_request_read \
            ci_logs ci_rerun read_issue create_issue preview_open schedule_task \
            send_to_user html_preview html_render; do
    for id in $HARNESS_IDS; do
        run_harness "$id" "$tool" "$ARGS_SEND" allow "$tool benign call allowed"
    done
done

echo "== T3 pull-request tools: create, review and merge are refused on every registry harness and name the gated route =="
POLICY="$REPO/scripts/guardrails/mcp-policy.json"
SHA40=0123456789abcdef0123456789abcdef01234567
PRM1='{"number":7,"expectedHeadSha":"'$SHA40'"}'
PRM2='{"number":7,"expectedHeadSha":"'$SHA40'","auto":true}'
PRM3='{"number":7,"expectedHeadSha":"'$SHA40'","stack":true}'
PRM4='{"expectedHeadSha":"'$SHA40'"}'
PRC1='{"title":"t","body":"b"}'
PRC2='{"title":"t","body":"b","private":true,"draft":true}'
PRV1='{"number":7,"verdict":"approve","expectedHeadSha":"'$SHA40'"}'
PR_URL='{"url":"https://github.com/o/r/pull/7"}'
for id in $HARNESS_IDS; do
    run_harness "$id" pull_request_merge "$PRM1" deny "PRM-1 pull_request_merge denied" t3-pr-route
    run_harness "$id" pull_request_merge "$PRM1" deny "PRM-1 pull_request_merge names merge-on-green.sh" merge-on-green.sh
    run_harness "$id" pull_request_merge "$PRM2" deny "PRM-2 pull_request_merge with auto denied" t3-pr-route
    run_harness "$id" pull_request_merge "$PRM3" deny "PRM-3 pull_request_merge with stack denied" t3-pr-route
    run_harness "$id" pull_request_merge "$PRM4" deny "PRM-4 pull_request_merge with no number denied" t3-pr-route
    run_harness "$id" pull_request_read '{"number":7}' allow "PRM-T pull_request_read twin allowed"
    run_harness "$id" pull_request_create "$PRC1" deny "PRC-1 pull_request_create denied" t3-pr-route
    run_harness "$id" pull_request_create "$PRC1" deny "PRC-1 pull_request_create names worker-pr-open.sh" worker-pr-open.sh
    run_harness "$id" pull_request_create "$PRC2" deny "PRC-2 pull_request_create private draft denied" t3-pr-route
    run_harness "$id" watch_pull_request "$PR_URL" allow "PRC-T watch_pull_request twin allowed"
    run_harness "$id" link_pull_request "$PR_URL" allow "PRC-T2 link_pull_request twin allowed"
    run_harness "$id" pull_request_review "$PRV1" deny "PRV-1 pull_request_review denied" t3-pr-route
    run_harness "$id" pull_request_review "$PRV1" deny "PRV-1 pull_request_review names gh pr review" "gh pr review"
done
for t in pull_request_merge pull_request_create pull_request_review; do echo "PRF ran: $t (refused rows)"; done
run_codex pull_request_merge "$PRM1" deny "PRD-1 direct-server pull_request_merge denied" t3-pr-route mcp__t3_code_direct__
run_codex pull_request_create "$PRC1" deny "PRD-2 direct-server pull_request_create denied" t3-pr-route mcp__t3_code_direct__

for tool in $(jq -r '.servers["t3-code"].tools | keys[]' "$POLICY"); do
    case "$tool" in pull_request_create | pull_request_review | pull_request_merge | unwatch_pull_request) continue ;; esac
    for id in $HARNESS_IDS; do
        run_harness "$id" "$tool" '{"number":7}' allow "PRF $tool allowed"
    done
    echo "PRF ran: $tool"
done
echo "PRF ran: unwatch_pull_request (its own rows)"
for id in $HARNESS_IDS; do
    run_harness "$id" pull_request_update '{"number":7,"title":"x"}' allow "PRW pull_request_update allowed"
    run_harness "$id" pull_request_respond '{"number":7,"reviewThreadId":"t1","resolved":true}' allow "PRW pull_request_respond resolved allowed"
    run_harness "$id" ci_rerun '{"number":7}' allow "PRW ci_rerun allowed"
done

pro2=$(for v in $HIMMEL_OVERRIDE_ENV_OK_VARS; do [ "$v" = T3_THREAD_TOOLS_OK ] || printf '%s=1 ' "$v"; done)
case " $pro2" in
    *" T3_THREAD_TOOLS_OK="*) bad "PRO-2 the override set holds T3_THREAD_TOOLS_OK" ;;
    *" HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1 "*) ok "PRO-2 the override set is every other override, HIMMEL_HOOK_INTEGRITY_BYPASS_OK included" ;;
    *) bad "PRO-2 the override set is empty or lacks HIMMEL_HOOK_INTEGRITY_BYPASS_OK: $pro2" ;;
esac
for id in claude codex grok cursor; do
    T3_THREAD_TOOLS_OK=1 run_harness "$id" pull_request_merge "$PRM1" allow "PRO-1 pull_request_merge allowed under T3_THREAD_TOOLS_OK=1"
    T3_THREAD_TOOLS_OK=1 run_harness "$id" pull_request_create "$PRC1" allow "PRO-1 pull_request_create allowed under T3_THREAD_TOOLS_OK=1"
    T3_THREAD_TOOLS_OK=1 run_harness "$id" pull_request_review "$PRV1" allow "PRO-1 pull_request_review allowed under T3_THREAD_TOOLS_OK=1"
    eval "$pro2 run_harness \"\$id\" pull_request_merge \"\$PRM1\" deny \"PRO-2 pull_request_merge denied under every other override\" t3-pr-route"
    eval "$pro2 run_harness \"\$id\" pull_request_create \"\$PRC1\" deny \"PRO-2 pull_request_create denied under every other override\" t3-pr-route"
    eval "$pro2 run_harness \"\$id\" pull_request_review \"\$PRV1\" deny \"PRO-2 pull_request_review denied under every other override\" t3-pr-route"
done
T3_THREAD_TOOLS_OK=1 run_antigravity pull_request_merge "$PRM1" deny "PRO-A pull_request_merge denied, the adapter scrubs T3_THREAD_TOOLS_OK" t3-pr-route

POL_LOG="$TMP/pol-audit.jsonl"
destr=$(jq -r '.servers["t3-code"].tools | to_entries[] | select(.value == "destructive") | .key' "$POLICY")
if grep -qx pull_request_merge <<<"$destr"; then ok "POL-1 the registry classes pull_request_merge destructive"
else bad "POL-1 pull_request_merge is not destructive in the registry: $destr"; fi
for key in t3-code t3_code t3_code_direct; do
    for tool in $destr; do
        : > "$POL_LOG"
        pol_out=$(jq -cn --arg t "mcp__${key}__$tool" '{hook_event_name:"PreToolUse",session_id:"pol",tool_name:$t,tool_input:{}}' \
            | MCP_POLICY_AUDIT_LOG="$POL_LOG" bash "$REPO/scripts/hooks/mcp-policy.sh" 2>&1); pol_rc=$?
        if [ "$pol_rc" -eq 0 ] && jq -se 'length == 1 and .[0].class == "destructive" and .[0].mode == "enforce" and .[0].verdict == "allow"' "$POL_LOG" >/dev/null 2>&1; then
            ok "POL-1 mcp__${key}__$tool: destructive, enforced, allowed"
        else
            bad "POL-1 mcp__${key}__$tool (rc=$pol_rc out=$pol_out audit=$(cat "$POL_LOG"))"
        fi
    done
done
if jq -e '.servers as $s | [$s["t3-code"], $s["t3_code"], $s["t3_code_direct"]] | map({tools, allow_destructive}) | (.[0] != null and .[0] == .[1] and .[1] == .[2])' "$POLICY" >/dev/null; then
    ok "POL-2 the three T3 keys carry the same tools and allow_destructive"
else
    bad "POL-2 the three T3 keys differ"
fi
guard_prefixes=$(sed -n 's/^T3_TOOL_PREFIXES="\(.*\)"$/\1/p' "$REPO/scripts/hooks/guard-t3-thread-tools.sh" | tr ' ' '\n' | sort | tr '\n' ' ')
policy_prefixes=$(jq -r '.servers | keys[] | select(startswith("t3"))' "$POLICY" | sed 's/^\(.*\)$/mcp__\1__/' | sort | tr '\n' ' ')
if [ -n "$guard_prefixes" ] && [ "$guard_prefixes" = "$policy_prefixes" ]; then ok "POL-3 the policy's T3 keys equal the guard's T3_TOOL_PREFIXES"
else bad "POL-3 policy keys ($policy_prefixes) differ from the guard's prefixes ($guard_prefixes)"; fi
# shellcheck disable=SC2016 # the adapter's literal guard join, matched as text
if grep -qF '[ "$srv" = "t3-code" ]' "$REPO/scripts/hooks/antigravity-hook-adapter.sh" \
    && jq -e '.laneMcpServers | index("t3-code") != null' "$REPO/scripts/t3/antigravity-profiles.json" >/dev/null; then
    ok "POL-3 the Antigravity adapter joins the guard on t3-code, and t3-code is a lane server"
else
    bad "POL-3 the Antigravity adapter's t3-code guard join or laneMcpServers entry is missing"
fi

echo "== T3 schedule_task: a bound interval without a fresh session is refused on every registry harness =="
SCHED_BOUND='{"prompt":"coordinate","schedule":{"type":"interval","everyMs":1800000},"bindToCurrentThread":true,"freshSession":false}'
SCHED_DEFAULT='{"prompt":"coordinate","schedule":{"type":"interval","everyMs":1800000}}'
SCHED_TEXT='{"prompt":"coordinate","schedule":"{\"type\":\"interval\",\"everyMs\":1800000}","bindToCurrentThread":true,"freshSession":false}'
SCHED_FRESH='{"prompt":"coordinate","schedule":{"type":"interval","everyMs":1800000},"bindToCurrentThread":true,"freshSession":true}'
SCHED_UNBOUND='{"prompt":"coordinate","schedule":{"type":"interval","everyMs":1800000},"bindToCurrentThread":false,"freshSession":false}'
for id in $HARNESS_IDS; do
    run_harness "$id" schedule_task "$SCHED_BOUND" deny "SCHED-BOUND denied" "non-fresh-bound-interval"
    run_harness "$id" schedule_task "$SCHED_DEFAULT" deny "SCHED-DEFAULT denied" "non-fresh-bound-interval"
    run_harness "$id" schedule_task "$SCHED_TEXT" deny "SCHED-TEXT denied" "non-fresh-bound-interval"
    run_harness "$id" schedule_task "$SCHED_FRESH" allow "fresh-session interval allowed"
    run_harness "$id" schedule_task "$SCHED_UNBOUND" allow "unbound interval allowed"
done

echo "== T3 preview tools (plugin-profiles previewBrowserTools): no lane guard denies one, so the profile option only adds an allow rule =="
PREVIEW_TOOLS="$(jq -r '.previewBrowserTools[]?' "$REPO/scripts/lanes/plugin-profiles.json")"
if [ -n "$PREVIEW_TOOLS" ]; then ok "the registry lists the preview tools"; else bad "the registry lists no preview tools"; fi
for tool in $PREVIEW_TOOLS; do
    run_claude guard-t3-thread-tools.sh "$tool" "$ARGS_SEND" allow "$tool allowed on claude"
    run_codex "$tool" "$ARGS_SEND" allow "$tool allowed on codex"
    run_antigravity "$tool" "$ARGS_SEND" allow "$tool allowed on antigravity"
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
