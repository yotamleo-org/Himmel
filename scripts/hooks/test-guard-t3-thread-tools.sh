#!/usr/bin/env bash
# shellcheck disable=SC2016 # the row checks hand check() their conditions as single-quoted strings it evals
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HOOKS/guard-t3-thread-tools.sh"

# shellcheck source=../lib/override-env.sh
# shellcheck disable=SC1091
. "$HOOKS/../lib/override-env.sh"
scrub_override_env
unset HIMMEL_GUARD_REFUSALS_LOG
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
  "claudeAgent_maintainer-hooks":{"driver":"claudeAgent","enabled":true,"config":{"launchArgs":"--settings /x/maintainer-hooks.json"}},
  "claudeBypass":{"driver":"claudeAgent","enabled":true,"environment":[{"name":"AGENTS_MD_OK","value":"1"}],"config":{}},
  "skipArgs":{"driver":"claudeAgent","enabled":true,"config":{"launchArgs":"--settings /x/y.json --dangerously-skip-permissions"}},
  "skipCr":{"driver":"codex","enabled":true,"config":{"env":{"SKIP_CR":"1"}}},
  "lowerBypass":{"driver":"codex","enabled":true,"config":{"environment":[{"name":"guard_bypass_x","value":"1"}]}},
  "badEnv":{"driver":"claudeAgent","enabled":true,"config":{"environment":[7]}},
  "namelessEnv":{"driver":"claudeAgent","enabled":true,"environment":[{}]},
  "numberName":{"driver":"claudeAgent","enabled":true,"environment":[{"name":7,"value":"1"}]},
  "stringEntry":"claudeAgent",
  "stringConfig":{"driver":"claudeAgent","enabled":true,"config":"x"},
  "arrayArgs":{"driver":"claudeAgent","enabled":true,"config":{"launchArgs":["--dangerously-skip-permissions"]}}
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
run "deny says where the optional narrowing lives" 2 '.t3.instance_narrow in $HOME/.himmel/config.json' "$LAUNCH_BAD"
run "deny names the operator override" 2 'T3_THREAD_TOOLS_OK=1' "$LAUNCH_BAD"
run "an Antigravity thread launching a bypass instance: refused" 2 '"claudeBypass"' "$(from_to antigravity claudeBypass)"
run "a bypass instance as the source is judged too: refused" 2 '"claudeBypass"' "$(from_to claudeBypass codex)"
run "launchArgs with a permission skip: refused" 2 '"skipArgs": carries a himmel bypass flag (launchArgs dangerously-skip-permissions)' \
    "$(from_to antigravity skipArgs)"
run "a registry flag without the _OK suffix: refused" 2 '"skipCr": carries a himmel bypass flag (SKIP_CR)' "$(from_to codex skipCr)"
run "a lower-case bypass name: refused" 2 '"lowerBypass": carries a himmel bypass flag (guard_bypass_x)' "$(from_to codex lowerBypass)"
run "a malformed environment entry: refused" 2 '"badEnv": carries a himmel bypass flag (a malformed environment entry)' \
    "$(from_to codex badEnv)"
run "an environment entry with no name: refused" 2 '"namelessEnv": carries a himmel bypass flag (a malformed environment entry)' \
    "$(from_to codex namelessEnv)"
run "an environment entry with a non-string name: refused" 2 '"numberName": carries a himmel bypass flag (a malformed environment entry)' \
    "$(from_to codex numberName)"
run "a non-object instance entry: refused" 2 '"stringEntry": carries a himmel bypass flag (a malformed instance entry)' \
    "$(from_to codex stringEntry)"
run "a non-object instance config: refused" 2 '"stringConfig": carries a himmel bypass flag (a malformed instance config)' \
    "$(from_to codex stringConfig)"
run "non-string launchArgs: refused" 2 '"arrayArgs": carries a himmel bypass flag (malformed launchArgs)' \
    "$(from_to codex arrayArgs)"
run "launch on the maintainer-hooks instance: refused" 2 '"claudeAgent_maintainer-hooks": is a maintainer-profile instance' "$(from_to antigravity claudeAgent_maintainer-hooks)"
run "launch on the maintainer-billed instance, not yet in T3 settings: refused" 2 '"claudeAgent_maintainer-billed": is a maintainer-profile instance' "$(from_to codex claudeAgent_maintainer-billed)"
run "launch on a maintainer relay copy: refused" 2 '"claudeAgent_maintainer-hooks_relay": is a maintainer-profile instance' "$(from_to codex claudeAgent_maintainer-hooks_relay)"
run "launch on the billed relay copy: refused" 2 '"claudeAgent_maintainer-billed_relay": is a maintainer-profile instance' "$(from_to codex claudeAgent_maintainer-billed_relay)"
run "a maintainer instance as the source is judged too: refused" 2 '"claudeAgent_maintainer-hooks"' "$(from_to claudeAgent_maintainer-hooks codex)"
run "create_threads naming a maintainer instance: refused" 2 '"claudeAgent_maintainer-hooks"' \
    '{"tool_name":"'$T'create_threads","tool_input":{"threads":[{"title":"a","target":{"providerInstanceId":"claudeAgent_maintainer-hooks"}}]}}'
run "negative control, claudeAgent_worker-impl: allowed" 0 - "$(from_to codex claudeAgent_worker-impl)"
run "a name that only starts like a maintainer profile: allowed" 0 - "$(from_to codex claudeAgent_maintainer-hooks-other)"
run "operator route: a maintainer instance is allowed, on stderr" 0 'override: allowed' "$(from_to codex claudeAgent_maintainer-hooks)" T3_THREAD_TOOLS_OK=1
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
run "a config with no narrowing key narrows nothing: allowed" 0 - "$(from_to antigravity orchestratorNeon)"
printf '{"t3":{"instance_allowlist":["claudeAgent","codex","claudeAgent_worker-impl"]}}\n' > "$HOME/.himmel/config.json"
run "an old widening .t3.instance_allowlist is not read: antigravity allowed" 0 - "$(from_to codex antigravity)"
printf '{"t3":{"instance_allowlist":"codex"}}\n' > "$HOME/.himmel/config.json"
run "a malformed old .t3.instance_allowlist is not read: allowed" 0 - "$(from_to codex antigravity)"
printf '{"t3":{"instance_narrow":["claudeAgent","codex","claudeBypass"]}}\n' > "$HOME/.himmel/config.json"
run "a bypass instance on the narrowing list: still refused" 2 '"claudeBypass": carries a himmel bypass flag' "$LAUNCH_BAD"
run "the narrowing list: an unlisted instance refused" 2 '"antigravity": off .t3.instance_narrow' "$(from_to codex antigravity)"
run "the narrowing list: a listed instance allowed" 0 - "$LAUNCH_OK"
printf '{"t3":{"instance_narrow":["claudeAgent"]}}\n' > "$HOME/.himmel/config.json"
run "the narrowing list: a built-in it leaves out refused" 2 'off .t3.instance_narrow' "$LAUNCH_OK"
printf '{"t3":{"instance_narrow":["claudeAgent","codex"' > "$HOME/.himmel/config.json"
run "a malformed config: refused" 2 'is not JSON' "$LAUNCH_OK"
printf '{"t3":{"instance_narrow":"codex"}}\n' > "$HOME/.himmel/config.json"
run "a non-array allowlist: refused" 2 'not an array of strings' "$LAUNCH_OK"
printf '{"t3":{"instance_narrow":null}}\n' > "$HOME/.himmel/config.json"
run "an explicit null narrowing key: refused" 2 'not an array of strings' "$LAUNCH_OK"
printf '{"t3":{"instance_narrow":"absent"}}\n' > "$HOME/.himmel/config.json"
run "a narrowing key holding the string absent: refused" 2 'not an array of strings' "$LAUNCH_OK"
: > "$HOME/.himmel/config.json"
run "an empty config file: refused" 2 'is not JSON with an optional .t3.instance_narrow' "$LAUNCH_OK"
printf '{"t3":{}}\n{"t3":{}}\n' > "$HOME/.himmel/config.json"
run "a two-document config file: refused" 2 'is not JSON with an optional .t3.instance_narrow' "$LAUNCH_OK"
printf '{"t3":"codex"}\n' > "$HOME/.himmel/config.json"
run "a non-object .t3: refused" 2 'is not JSON with an optional .t3.instance_narrow' "$LAUNCH_OK"
printf '{"t3":null}\n' > "$HOME/.himmel/config.json"
run "a null .t3 narrows nothing: allowed" 0 - "$(from_to codex antigravity)"
printf '{"t3":{"instance_narrow":["claudeAgent","codex"]}}\n' > "$TMP/elsewhere.json"
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
printf '{"providerInstances":false}\n' > "$T3_SETTINGS"
run "a false providerInstances: refused" 2 'whether it carries a bypass flag is unknown' "$LAUNCH_OK"
printf '{"providerInstances":null}\n' > "$T3_SETTINGS"
run "a null providerInstances: refused" 2 'whether it carries a bypass flag is unknown' "$LAUNCH_OK"
printf '["providerInstances"]\n' > "$T3_SETTINGS"
run "a non-object settings document: refused" 2 'whether it carries a bypass flag is unknown' "$LAUNCH_OK"
: > "$T3_SETTINGS"
run "an empty T3 settings file: refused" 2 '"codex": whether it carries a bypass flag is unknown (the bypass lookup failed' "$LAUNCH_OK"
printf '{"providerInstances":{}}\n{"providerInstances":{}}\n' > "$T3_SETTINGS"
run "a two-document T3 settings file: refused" 2 '"codex": whether it carries a bypass flag is unknown (the bypass lookup failed' "$LAUNCH_OK"
printf '{"theme":"dark"}\n' > "$T3_SETTINGS"
run "T3 settings with no providerInstances: a built-in allowed" 0 - "$LAUNCH_OK"
write_t3_settings

mkdir -p "$TMP/regtree/hooks" "$TMP/regtree/himmelctl/lib"
cp "$HOOK" "$TMP/regtree/hooks/guard-t3-thread-tools.sh"
REAL_HOOK="$HOOK" HOOK="$TMP/regtree/hooks/guard-t3-thread-tools.sh"
printf '{"flags":[{"name":"SKIP_CR"}]}\n' > "$TMP/regtree/himmelctl/lib/bypass-flags.json"
run "a fixture registry flag: refused" 2 '"skipCr": carries a himmel bypass flag (SKIP_CR)' "$(from_to codex skipCr)"
printf '{"flags":[{"name":7},{"name":"SKIP_CR"}]}\n' > "$TMP/regtree/himmelctl/lib/bypass-flags.json"
run "a registry entry with a non-string name: refused" 2 'whether it carries a bypass flag is unknown' "$(from_to codex antigravity)"
printf '{"flags":[{"bypasses":"x"}]}\n' > "$TMP/regtree/himmelctl/lib/bypass-flags.json"
run "a registry entry with no name: refused" 2 'whether it carries a bypass flag is unknown' "$(from_to codex antigravity)"
printf '{"flags":{"a":{"name":"SKIP_CR"}}}\n' > "$TMP/regtree/himmelctl/lib/bypass-flags.json"
run "a registry whose flags is not an array: refused" 2 'whether it carries a bypass flag is unknown' "$(from_to codex antigravity)"
HOOK="$REAL_HOOK"

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

ROWS="$HOME/.himmel/state/guard-refusals.jsonl"
check() {
    local name="$1" cond="$2"
    N=$((N+1))
    if eval "$cond"; then echo "ok   $name"; else echo "FAIL $name: rows=$(tail -n 2 "$ROWS" 2>/dev/null | tr '\n' ' ')"; FAIL=$((FAIL+1)); fi
}
row_count() { if [ -f "$1" ]; then wc -l <"$1" | tr -d ' '; else echo 0; fi; }

rm -rf "$HOME/.himmel/state"
write_t3_settings
run "row: a refused bypass-instance launch still refuses" 2 '"claudeBypass"' "$LAUNCH_BAD"
check "row: a refused launch writes exactly one row" '[ "$(row_count "$ROWS")" = 1 ]'
check "row: it names the guard, the rule, the instance and the thread title" \
    'jq -e ".guard == \"guard-t3-thread-tools\" and .rule == \"bypass-instance\" and .instance == \"claudeBypass\" and .title == \"Work\" and (.ts | test(\"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$\"))" "$ROWS" >/dev/null'
check "row: it carries the ledgers.json envelope v, ts, host, source, kind" \
    'jq -e ".v == 1 and (.host | length > 0) and .source == .guard and .kind == \"refusal\"" "$ROWS" >/dev/null'
run "row: a chief-title rename still refuses" 2 'chief-shaped' \
    '{"tool_name":"'$T't3_thread_update","tool_input":{"action":"rename","title":"X-chief"}}'
check "row: a chief title writes a second row naming the title rule" \
    '[ "$(row_count "$ROWS")" = 2 ] && [ "$(tail -n1 "$ROWS" | jq -r "[.rule, .title, .instance] | join(\"|\")")" = "chief-title|X-chief|" ]'
run "row: a maintainer-profile launch still refuses" 2 'maintainer-profile instance' "$(from_to codex claudeAgent_maintainer-hooks)"
check "row: a maintainer-profile launch names the maintainer-instance rule" \
    '[ "$(tail -n1 "$ROWS" | jq -r "[.rule, .instance] | join(\"|\")")" = "maintainer-instance|claudeAgent_maintainer-hooks" ]'
run "row: an allowed call still allows" 0 - "$LAUNCH_OK"
run "row: the operator override still allows" 0 'override: allowed' "$LAUNCH_BAD" T3_THREAD_TOOLS_OK=1
check "row: an allow and an override write no row" '[ "$(row_count "$ROWS")" = 3 ]'
run "row: an unparseable payload refuses" 2 'not JSON' '{"tool_name":"'$T't3_thread_launch","tool_input":{"title":'
check "row: a fail-closed refusal also writes a row" '[ "$(tail -n1 "$ROWS" | jq -r .rule)" = "bad-payload" ]'
run "row: a non-T3 tool writes nothing" 0 - '{"tool_name":"mcp__other__launch","tool_input":{"instanceId":"claudeBypass"}}'
check "row: a non-T3 tool wrote no row" '[ "$(row_count "$ROWS")" = 4 ]'

SECRET='ghp''_abcdefghijklmnopqrstuvwxyz0123456789'
printf '{"providerInstances":{"secretEnv":{"driver":"claudeAgent","environment":[{"name":"AGENTS_MD_OK","value":"%s"}],"config":{"launchArgs":"--dangerously-skip-permissions --token %s"}}}}\n' "$SECRET" "$SECRET" > "$T3_SETTINGS"
run "row: a secret-bearing bypass instance still refuses" 2 '"secretEnv"' "$(from_to codex secretEnv)"
check "row: a secret-looking settings value never reaches the row file" '(grep -q "$SECRET" "$ROWS"; [ $? = 1 ]) && (grep -q "abcdefghijklmnop" "$ROWS"; [ $? = 1 ])'
check "row: that refusal did write a row for the instance" '[ "$(tail -n1 "$ROWS" | jq -r .instance)" = "secretEnv" ]'
write_t3_settings

ALT="$TMP/alt/refusals.jsonl"
run "row: a refusal with HIMMEL_GUARD_REFUSALS_LOG set still refuses" 2 '"claudeBypass"' "$LAUNCH_BAD" HIMMEL_GUARD_REFUSALS_LOG="$ALT"
check "row: HIMMEL_GUARD_REFUSALS_LOG moves the row" '[ "$(row_count "$ALT")" = 1 ] && [ "$(row_count "$ROWS")" = 5 ]'
mkdir -p "$TMP/ro"; : > "$TMP/ro/blocker"
run "row: an unwritable log path never changes the refusal" 2 '"claudeBypass"' "$LAUNCH_BAD" HIMMEL_GUARD_REFUSALS_LOG="$TMP/ro/blocker/x.jsonl"

# shellcheck source=../lib/portable-timeout.sh
# shellcheck disable=SC1091
. "$HOOKS/../lib/portable-timeout.sh"
FIFO="$TMP/fifo.jsonl"; mkfifo "$FIFO"
N=$((N+1))
printf '%s' "$LAUNCH_BAD" | timeout 5 env HIMMEL_GUARD_REFUSALS_LOG="$FIFO" bash "$HOOK" >/dev/null 2>&1; rc=$?
if [ "$rc" = 2 ]; then echo "ok   row: a log path that is a pipe with no reader never hangs the refusal"
else echo "FAIL row: a log path that is a pipe with no reader never hangs the refusal: rc=$rc (124 = the guard hung)"; FAIL=$((FAIL+1)); fi

echo "$((N-FAIL))/$N cases; failures=$FAIL"
[ "$FAIL" = 0 ]
