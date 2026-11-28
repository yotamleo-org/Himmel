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
            t3_environment_read t3_project_list t3_project_read pull_request_read pull_request_create \
            pull_request_merge ci_logs ci_rerun read_issue create_issue preview_open schedule_task \
            send_to_user html_preview html_render; do
    for id in $HARNESS_IDS; do
        run_harness "$id" "$tool" "$ARGS_SEND" allow "$tool benign call allowed"
    done
done

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
