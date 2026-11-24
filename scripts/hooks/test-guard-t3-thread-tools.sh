#!/usr/bin/env bash
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HOOKS/guard-t3-thread-tools.sh"

# shellcheck source=../lib/override-env.sh
# shellcheck disable=SC1091
. "$HOOKS/../lib/override-env.sh"
scrub_override_env
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/t3threadtools.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT
# shellcheck source=../lib/testlib-config-isolation.sh
# shellcheck disable=SC1091
. "$HOOKS/../lib/testlib-config-isolation.sh"
isolate_himmel_config "$TMP" || exit 1
export HOME="$TMP/home"
export T3CODE_HOME="$TMP/t3home"
mkdir -p "$HOME/.himmel" "$T3CODE_HOME/userdata"
T3_SETTINGS="$T3CODE_HOME/userdata/settings.json"
write_t3_settings() {
    cat > "$T3_SETTINGS" <<'EOF'
{"providerInstances":{
  "antigravity":{"driver":"antigravity","displayName":"Antigravity","enabled":true},
  "orchestratorNeon":{"driver":"antigravity","displayName":"Orchestrator (Neon)","enabled":true,"config":{}},
  "gemini":{"driver":"gemini","displayName":"Gemini","enabled":true},
  "claudeAgent_worker-impl":{"driver":"claudeAgent","enabled":true,"config":{"launchArgs":"--settings /x/worker-impl.json"}},
  "claudeBypass":{"driver":"claudeAgent","enabled":true,"environment":[{"name":"AGENTS_MD_OK","value":"1"}],"config":{}},
  "skipArgs":{"driver":"claudeAgent","enabled":true,"config":{"launchArgs":"--settings /x/y.json --dangerously-skip-permissions"}},
  "skipCr":{"driver":"codex","enabled":true,"config":{"env":{"SKIP_CR":"1"}}},
  "lowerBypass":{"driver":"codex","enabled":true,"config":{"environment":[{"name":"guard_bypass_x","value":"1"}]}},
  "badEnv":{"driver":"claudeAgent","enabled":true,"config":{"environment":[7]}}
}}
EOF
}
write_t3_settings

FAIL=0; N=0
run() {
    local name="$1" want="$2" grep_for="$3" payload="$4" rc out
    shift 4
    N=$((N+1))
    out=$(printf '%s' "$payload" | env "$@" bash "$HOOK" 2>&1 >/dev/null); rc=$?
    if [ "$rc" != "$want" ]; then
        echo "FAIL $name: rc=$rc want=$want out=$out"; FAIL=$((FAIL+1)); return
    fi
    if [ "$grep_for" = "-" ]; then
        if [ "$want" = 0 ] && [ -n "$out" ]; then
            echo "FAIL $name: expected a silent allow, got: $out"; FAIL=$((FAIL+1)); return
        fi
    elif ! grep -qF -- "$grep_for" <<<"$out"; then
        echo "FAIL $name: stderr lacks '$grep_for': $out"; FAIL=$((FAIL+1)); return
    fi
    echo "ok   $name"
}

T=mcp__t3-code__
LAUNCH_BAD='{"tool_name":"'$T't3_thread_launch","tool_input":{"title":"Work","message":"go","modelSelection":{"instanceId":"claudeBypass","model":"claude-opus-5-5"}}}'
LAUNCH_OK='{"tool_name":"'$T't3_thread_launch","tool_input":{"title":"Work","message":"go","modelSelection":{"instanceId":"codex","model":"gpt-5"}}}'
LAUNCH_PLAIN='{"tool_name":"'$T't3_thread_launch","tool_input":{"title":"Work","message":"go","modelSelection":{"model":"claude-opus-5-5"}}}'
CREATE_MIXED='{"tool_name":"'$T'create_threads","tool_input":{"threads":[{"title":"a","target":{"providerInstanceId":"claudeAgent"}},{"title":"b","target":{"providerInstanceId":"claudeBypass"}}]}}'
DELEGATE_BAD='{"tool_name":"'$T'delegate_task","tool_input":{"task":"x","target":{"providerInstanceId":"claudeBypass"}}}'
CONFIGURE_BAD='{"tool_name":"'$T't3_thread_configure","tool_input":{"modelSelection":{"instanceId":"claudeBypass","model":"m"}}}'

from_to() {
    printf '{"tool_name":"%st3_thread_launch","tool_input":{"title":"Work","message":"go","delegatedFrom":{"environmentId":"e","threadId":"t","instanceId":"%s"},"modelSelection":{"instanceId":"%s","model":"m"}}}' "$T" "$1" "$2"
}

run "an Antigravity thread launches an Orchestrator thread: allowed" 0 - "$(from_to antigravity orchestratorNeon)"
run "a codex thread launches an Antigravity thread: allowed" 0 - "$(from_to codex antigravity)"
run "a Gemini thread launches a Claude profile thread: allowed" 0 - "$(from_to gemini claudeAgent_worker-impl)"
run "a Claude thread launches a Gemini thread: allowed" 0 - "$(from_to claudeAgent gemini)"
run "an Orchestrator thread launches a codex thread: allowed" 0 - "$(from_to orchestratorNeon codex)"
run "create_threads across providers: allowed" 0 - \
    '{"tool_name":"'$T'create_threads","tool_input":{"threads":[{"title":"a","target":{"providerInstanceId":"antigravity"}},{"title":"b","target":{"providerInstanceId":"gemini"}},{"title":"c","target":{"providerInstanceId":"codex"}}]}}'

run "launch on a bypass instance: refused" 2 '"claudeBypass": carries a himmel bypass flag (AGENTS_MD_OK)' "$LAUNCH_BAD"
run "deny names the bypass rule" 2 'a hook bypass is granted per session' "$LAUNCH_BAD"
run "deny says the operator picks a bypass instance" 2 'by the operator choosing that instance in the T3 UI' "$LAUNCH_BAD"
# shellcheck disable=SC2016 # the deny text names $HOME literally
run "deny says where the optional narrowing lives" 2 '.t3.instance_allowlist in $HOME/.himmel/config.json' "$LAUNCH_BAD"
run "deny names the operator override" 2 'T3_THREAD_TOOLS_OK=1' "$LAUNCH_BAD"
run "an Antigravity thread launching a bypass instance: refused" 2 '"claudeBypass"' "$(from_to antigravity claudeBypass)"
run "a bypass instance as the source is judged too: refused" 2 '"claudeBypass"' "$(from_to claudeBypass codex)"
run "launchArgs with a permission skip: refused" 2 '"skipArgs": carries a himmel bypass flag (launchArgs dangerously-skip-permissions)' \
    "$(from_to antigravity skipArgs)"
run "a registry flag without the _OK suffix: refused" 2 '"skipCr": carries a himmel bypass flag (SKIP_CR)' "$(from_to codex skipCr)"
run "a lower-case bypass name: refused" 2 '"lowerBypass": carries a himmel bypass flag (guard_bypass_x)' "$(from_to codex lowerBypass)"
run "a malformed environment entry: refused" 2 '"badEnv": carries a himmel bypass flag (a malformed environment entry)' \
    "$(from_to codex badEnv)"
run "launch with a built-in instance: allowed" 0 - "$LAUNCH_OK"
run "launch with no instance key: allowed" 0 - "$LAUNCH_PLAIN"
run "create_threads with one good and one bad providerInstanceId: refused" 2 '"claudeBypass"' "$CREATE_MIXED"
run "delegate_task with a bad providerInstanceId: refused" 2 '"claudeBypass"' "$DELEGATE_BAD"
run "t3_thread_configure with a bad instance: refused" 2 '"claudeBypass"' "$CONFIGURE_BAD"
run "an instance key in another spelling or depth: refused" 2 '"claudeBypass"' \
    '{"tool_name":"'$T'future_tool","tool_input":{"a":[{"b":{"provider_instance_id":"claudeBypass"}}]}}'
run "a non-string instance value: refused" 2 'non-string' \
    '{"tool_name":"'$T't3_thread_launch","tool_input":{"title":"w","modelSelection":{"instanceId":{"id":"claudeBypass"},"model":"m"}}}'
run "a null instance value counts as absent: allowed" 0 - \
    '{"tool_name":"'$T't3_thread_launch","tool_input":{"title":"w","modelSelection":{"instanceId":null,"model":"m"}}}'

printf '{"t3":{"relay_instances":[]}}\n' > "$HOME/.himmel/config.json"
run "a config with no allowlist key narrows nothing: allowed" 0 - "$(from_to antigravity orchestratorNeon)"
printf '{"t3":{"instance_allowlist":["claudeAgent","codex","claudeBypass"]}}\n' > "$HOME/.himmel/config.json"
run "a bypass instance on the allowlist: still refused" 2 '"claudeBypass": carries a himmel bypass flag' "$LAUNCH_BAD"
run "the allowlist narrows: an unlisted instance refused" 2 '"antigravity": off .t3.instance_allowlist' "$(from_to codex antigravity)"
run "the allowlist narrows: a listed instance allowed" 0 - "$LAUNCH_OK"
printf '{"t3":{"instance_allowlist":["claudeAgent"]}}\n' > "$HOME/.himmel/config.json"
run "the allowlist narrows: a built-in it leaves out refused" 2 'off .t3.instance_allowlist' "$LAUNCH_OK"
printf '{"t3":{"instance_allowlist":["claudeAgent","codex"' > "$HOME/.himmel/config.json"
run "a malformed config: refused" 2 'is not JSON' "$LAUNCH_OK"
printf '{"t3":{"instance_allowlist":"codex"}}\n' > "$HOME/.himmel/config.json"
run "a non-array allowlist: refused" 2 'not an array of strings' "$LAUNCH_OK"
printf '{"t3":{"instance_allowlist":["claudeAgent","codex"]}}\n' > "$TMP/elsewhere.json"
rm -f "$HOME/.himmel/config.json"
ln -s "$TMP/elsewhere.json" "$HOME/.himmel/config.json"
run "a symlinked config: refused" 2 'is a symlink' "$LAUNCH_OK"
rm -f "$HOME/.himmel/config.json"

rm -f "$T3_SETTINGS"
run "no T3 settings file: an instance id refused" 2 'whether it carries a bypass flag is unknown' "$LAUNCH_OK"
run "no T3 settings file: a launch with no instance allowed" 0 - "$LAUNCH_PLAIN"
run "no T3 settings file: a title-only call is still judged on its title alone" 0 - \
    '{"tool_name":"'$T't3_thread_update","tool_input":{"action":"rename","title":"Plain title"}}'
printf '{"providerInstances":{' > "$T3_SETTINGS"
run "malformed T3 settings: refused" 2 'whether it carries a bypass flag is unknown' "$LAUNCH_OK"
printf '{"providerInstances":["claudeBypass"]}\n' > "$T3_SETTINGS"
run "a non-object providerInstances: refused" 2 'whether it carries a bypass flag is unknown' "$LAUNCH_OK"
printf '{"theme":"dark"}\n' > "$T3_SETTINGS"
run "T3 settings with no providerInstances: a built-in allowed" 0 - "$LAUNCH_OK"
write_t3_settings

run "rename to X-chief: refused" 2 'only by the operator in the T3 UI' \
    '{"tool_name":"'$T't3_thread_update","tool_input":{"action":"rename","title":"X-chief"}}'
run "rename to a padded, upper-case chief title: refused" 2 'chief-shaped' \
    '{"tool_name":"'$T't3_thread_update","tool_input":{"action":"rename","title":"  Ops-CHIEF \n"}}'
run "rename to a plain title: allowed" 0 - \
    '{"tool_name":"'$T't3_thread_update","tool_input":{"action":"rename","title":"Plain title"}}'
run "a title that only contains chief: allowed" 0 - \
    '{"tool_name":"'$T't3_thread_update","tool_input":{"action":"rename","title":"chief review notes"}}'
run "launch titled x-console: refused" 2 '"x-console"' \
    '{"tool_name":"'$T't3_thread_launch","tool_input":{"title":"x-console","message":"go"}}'
run "create_threads with a chief title in one thread: refused" 2 '"b-chief"' \
    '{"tool_name":"'$T'create_threads","tool_input":{"threads":[{"title":"a"},{"title":"b-chief"}]}}'
run "launch whose delegatedFrom names a chief parent: allowed" 0 - \
    '{"tool_name":"'$T't3_thread_launch","tool_input":{"title":"child","delegatedFrom":{"environmentId":"e","threadId":"t","title":"X-chief"}}}'
run "an instance inside delegatedFrom is still judged: refused" 2 '"claudeBypass"' \
    '{"tool_name":"'$T't3_thread_launch","tool_input":{"title":"child","delegatedFrom":{"title":"X-chief","instanceId":"claudeBypass"}}}'

run "a non-T3 tool: silent allow" 0 - \
    '{"tool_name":"mcp__other__launch","tool_input":{"instanceId":"claudeBypass","title":"X-chief"}}'
run "a T3 tool with no instance or title: silent allow" 0 - \
    '{"tool_name":"'$T't3_thread_list","tool_input":{}}'
run "unparseable payload: refused" 2 'not JSON' \
    '{"tool_name":"'$T't3_thread_launch","tool_input":{"title":'
run "payload with no tool_name: refused" 2 'not JSON' '{"tool_input":{}}'

mkdir -p "$TMP/nojq"
for t in bash env cat; do ln -sf "$(command -v "$t")" "$TMP/nojq/$t"; done
run "jq missing: refused" 2 'jq is not on PATH' "$LAUNCH_PLAIN" PATH="$TMP/nojq"

run "bypass allows a bad instance, on stderr" 0 'override: allowed' "$LAUNCH_BAD" T3_THREAD_TOOLS_OK=1
run "bypass allows a chief title, on stderr" 0 'T3_THREAD_TOOLS_OK=1' \
    '{"tool_name":"'$T't3_thread_update","tool_input":{"action":"rename","title":"X-chief"}}' T3_THREAD_TOOLS_OK=1
run "a bypass value other than 1 keeps the guard on" 2 '"claudeBypass"' "$LAUNCH_BAD" T3_THREAD_TOOLS_OK=yes

echo "$((N-FAIL))/$N cases; failures=$FAIL"
[ "$FAIL" = 0 ]
