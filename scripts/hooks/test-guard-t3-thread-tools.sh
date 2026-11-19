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
mkdir -p "$HOME/.himmel"

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

run "launch with an instance off the list: refused" 2 '"claudeBypass"' "$LAUNCH_BAD"
run "deny names the allowlist" 2 '"claudeAgent", "codex"' "$LAUNCH_BAD"
# shellcheck disable=SC2016 # the deny text names $HOME literally
run "deny says where the allowlist lives" 2 '.t3.instance_allowlist in $HOME/.himmel/config.json' "$LAUNCH_BAD"
run "deny says only the operator moves instances" 2 'Only the operator starts or moves a thread onto another instance' "$LAUNCH_BAD"
run "deny names the bypass" 2 'T3_THREAD_TOOLS_OK=1' "$LAUNCH_BAD"
run "launch with an allowed instance: allowed" 0 - "$LAUNCH_OK"
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

printf '{"t3":{"instance_allowlist":["claudeAgent","codex","claudeBypass"]}}\n' > "$HOME/.himmel/config.json"
run "config allowlist adds an instance: allowed" 0 - "$LAUNCH_BAD"
run "config allowlist still refuses an unlisted instance" 2 '"otherInstance"' \
    '{"tool_name":"'$T'delegate_task","tool_input":{"task":"x","target":{"providerInstanceId":"otherInstance"}}}'
printf '{"t3":{"instance_allowlist":["claudeAgent"]}}\n' > "$HOME/.himmel/config.json"
run "config allowlist replaces the default (codex removed): refused" 2 'from .t3.instance_allowlist' "$LAUNCH_OK"
printf '{"t3":{"instance_allowlist":["claudeAgent","codex","claudeBypass"' > "$HOME/.himmel/config.json"
run "malformed config falls back to the default: bad instance refused" 2 'built-in default' "$LAUNCH_BAD"
run "malformed config falls back to the default: default instance allowed" 0 - "$LAUNCH_OK"
printf '{"t3":{"instance_allowlist":"claudeBypass"}}\n' > "$HOME/.himmel/config.json"
run "a non-array allowlist falls back to the default" 2 'built-in default' "$LAUNCH_BAD"
printf '{"t3":{"instance_allowlist":["claudeAgent","codex","claudeBypass"]}}\n' > "$TMP/elsewhere.json"
rm -f "$HOME/.himmel/config.json"
ln -s "$TMP/elsewhere.json" "$HOME/.himmel/config.json"
run "a symlinked config is ignored: bad instance refused" 2 'built-in default' "$LAUNCH_BAD"
rm -f "$HOME/.himmel/config.json"

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
