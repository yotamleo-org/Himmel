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
# shellcheck source=../lib/portable-timeout.sh
# shellcheck disable=SC1091
. "$HOOKS/../lib/portable-timeout.sh"

CT="$(cd "$TMP" && pwd)"
LP="$CT/lp"
export HIMMEL_PROFILE_SETTINGS_DIR="$LP"
sha12() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -c1-12; else shasum -a 256 | cut -c1-12; fi; }
resolved() {
    local h dir f
    h=$(printf '%s\n' "$2" | sha12)
    if [ "${3:-}" = mcp ]; then dir="$LP/mcp-$h" f="$LP/mcp-$h/$1.mcp.json"; else dir="$LP/$h" f="$LP/$h/$1.json"; fi
    mkdir -p "$dir" && printf '%s\n' "$2" > "$f" && printf '%s\n' "$f"
}
WI=$(resolved worker-impl '{"permissions":{"deny":["Artifact"]}}')
WM=$(resolved worker-impl '{"mcpServers":{}}' mcp)
MH=$(resolved maintainer-hooks '{}')
MC=$(resolved Maintainer-Hooks '{"x":1}')
ED=$(resolved edited '{"env":{"MARKERKEY":"1"}}'); printf 'x' >> "$ED"
EM=$(resolved edm '{"mcpServers":{"a":{}}}' mcp); printf 'x' >> "$EM"
mkdir -p "$LP/bbbbbbbbbbbb"
mkfifo "$LP/bbbbbbbbbbbb/fifo.json" 2>/dev/null
OH=$(printf '%s\n' '{}' | sha12)
mkdir -p "$CT/other/$OH" "$CT/Xlp/$OH" "$CT/.lp/$OH"
printf '%s\n' '{}' > "$CT/other/$OH/x.json"
printf '%s\n' '{}' > "$CT/Xlp/$OH/x.json"
printf '%s\n' '{}' > "$CT/.lp/$OH/x.json"

write_t3_settings() {
    cat > "$T3_SETTINGS" <<EOF
{"providerInstances":{
  "antigravity":{"driver":"antigravity","displayName":"Antigravity","enabled":true},
  "orchestratorNeon":{"driver":"antigravity","displayName":"Orchestrator (Neon)","enabled":true,"config":{}},
  "gemini":{"driver":"gemini","displayName":"Gemini","enabled":true},
  "claudeAgent_worker-impl":{"driver":"claudeAgent","enabled":true,"config":{"launchArgs":"--settings $WI"}},
  "claudeAgent_maintainer-hooks":{"driver":"claudeAgent","enabled":true,"config":{"launchArgs":"--settings $MH"}},
  "claudeMcp":{"driver":"claudeAgent","enabled":true,"config":{"launchArgs":"--settings $WI --mcp-config $WM --strict-mcp-config"}},
  "claudeEmpty":{"driver":"claudeAgent","enabled":true,"config":{"launchArgs":""}},
  "claudeNoArgs":{"driver":"claudeAgent","enabled":true},
  "inlineSettings":{"driver":"claudeAgent","enabled":true,"config":{"launchArgs":"--settings {\"permissions\":{\"allow\":[\"Bash\"]}}"}},
  "inlineEq":{"driver":"claudeAgent","enabled":true,"config":{"launchArgs":"--settings='{\"env\":{\"X\":\"1\"}}'"}},
  "inlineTwoSpace":{"driver":"claudeAgent","enabled":true,"config":{"launchArgs":"--settings  {\"env\":{\"X\":\"1\"}}"}},
  "inlineLeadSpace":{"driver":"claudeAgent","enabled":true,"config":{"launchArgs":"--settings ' {\"env\":{\"X\":\"1\"}}'"}},
  "inlineSecond":{"driver":"claudeAgent","enabled":true,"config":{"launchArgs":"--settings $WI --settings {\"env\":{\"X\":\"1\"}}"}},
  "topInline":{"driver":"claudeAgent","enabled":true,"launchArgs":"--settings {\"env\":{\"X\":\"1\"}}","config":{"launchArgs":"--settings $WI"}},
  "configInline":{"driver":"claudeAgent","enabled":true,"launchArgs":"--settings $WI","config":{"launchArgs":"--settings {\"env\":{\"X\":\"1\"}}"}},
  "claudeAgent_nodriver":{"enabled":true,"config":{"launchArgs":"--settings {\"env\":{\"X\":\"1\"}}"}},
  "nodriverOther":{"enabled":true,"config":{"launchArgs":"--foo {\"x\":1}"}},
  "handPointed":{"driver":"claudeAgent","enabled":true,"config":{"launchArgs":"--settings /x/design-full.json"}},
  "relativePath":{"driver":"claudeAgent","enabled":true,"config":{"launchArgs":"--settings .himmel/worker-settings.json"}},
  "secretValue":{"driver":"claudeAgent","enabled":true,"config":{"launchArgs":"--settings sk-SECRETMARKER-1"}},
  "secretFlag":{"driver":"claudeAgent","enabled":true,"config":{"launchArgs":"--settings $WI --token=SECRETMARKER2"}},
  "editedFile":{"driver":"claudeAgent","enabled":true,"config":{"launchArgs":"--settings $ED"}},
  "editedMcp":{"driver":"claudeAgent","enabled":true,"config":{"launchArgs":"--settings $WI --mcp-config $EM --strict-mcp-config"}},
  "missingFile":{"driver":"claudeAgent","enabled":true,"config":{"launchArgs":"--settings $LP/aaaaaaaaaaaa/missing.json"}},
  "fifoFile":{"driver":"claudeAgent","enabled":true,"config":{"launchArgs":"--settings $LP/bbbbbbbbbbbb/fifo.json"}},
  "maintainerRenamed":{"driver":"claudeAgent","enabled":true,"config":{"launchArgs":"--settings $MH"}},
  "maintainerCase":{"driver":"claudeAgent","enabled":true,"config":{"launchArgs":"--settings $MC"}},
  "extraFlag":{"driver":"claudeAgent","enabled":true,"config":{"launchArgs":"--settings $WI --allowedTools Bash"}},
  "mcpOutside":{"driver":"claudeAgent","enabled":true,"config":{"launchArgs":"--settings $WI --mcp-config /x/mcp-aaaaaaaaaaaa/a.mcp.json --strict-mcp-config"}},
  "otherDir":{"driver":"claudeAgent","enabled":true,"config":{"launchArgs":"--settings $CT/other/$OH/x.json"}},
  "dotDir":{"driver":"claudeAgent","enabled":true,"config":{"launchArgs":"--settings $CT/Xlp/$OH/x.json"}},
  "codexArgs":{"driver":"codex","enabled":true,"config":{"launchArgs":"--foo {\"x\":1}"}},
  "claudeAgent_maintainer-hooks-other":{"driver":"claudeAgent","enabled":true,"config":{}},
  "grokThread":{"driver":"grok","enabled":true},
  "cursorThread":{"driver":"cursor","enabled":true},
  "noDriver":{"enabled":true},
  "fakeInst":{"driver":"fake","enabled":true},
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
    local pre=()
    [ -z "${RUN_TIMEOUT:-}" ] || pre=(timeout "$RUN_TIMEOUT")
    out=$(printf '%s' "$payload" | env "$@" ${pre[@]+"${pre[@]}"} bash "$HOOK" 2>&1 >/dev/null); rc=$?
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
run "a Gemini thread launches a Claude profile thread: allowed, the source's driver is not judged" 0 - "$(from_to gemini claudeAgent_worker-impl)"
run "a grok thread launches a codex thread: allowed, the source's driver is not judged" 0 - "$(from_to grokThread codex)"
run "a launch onto a driver with no descriptor: refused" 2 '"gemini": its driver gemini has no harness descriptor' "$(from_to claudeAgent gemini)"
run "an Orchestrator thread launches a codex thread: allowed" 0 - "$(from_to orchestratorNeon codex)"
run "create_threads across providers: allowed" 0 - \
    '{"tool_name":"'$T'create_threads","tool_input":{"threads":[{"title":"a","target":{"providerInstanceId":"antigravity"}},{"title":"b","target":{"providerInstanceId":"claudeAgent"}},{"title":"c","target":{"providerInstanceId":"codex"}}]}}'
run "a launch onto the built-in antigravity instance: allowed" 0 - "$(from_to claudeAgent antigravity)"
run "a launch onto a grok instance: refused, its descriptor is incomplete" 2 \
    '"grokThread": its driver grok has an incomplete harness descriptor (grok.json)' "$(from_to codex grokThread)"
run "a launch onto the built-in grok instance: refused" 2 '"grok": its driver grok has an incomplete harness descriptor' "$(from_to codex grok)"
run "a launch onto a cursor instance: refused" 2 'its driver cursor has an incomplete harness descriptor (cursor.json)' "$(from_to codex cursorThread)"
run "an instance entry with no driver: refused" 2 '"noDriver": no T3 driver is known for it' "$(from_to codex noDriver)"
run "the deny names the descriptor rule" 2 'scripts/harnesses' "$(from_to codex grokThread)"
run "operator route: an incomplete driver is allowed, on stderr" 0 'override: allowed' "$(from_to codex grokThread)" T3_THREAD_TOOLS_OK=1

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

lacks() {
    local name="$1" absent="$2" payload="$3" out
    shift 3
    N=$((N+1))
    out=$(printf '%s' "$payload" | env "$@" bash "$HOOK" 2>&1 >/dev/null)
    if grep -qF -- "$absent" <<<"$out"; then echo "FAIL $name: stderr holds '$absent': $out"; FAIL=$((FAIL+1)); return; fi
    echo "ok   $name"
}
OWN='carries settings of its own in its launchArgs'
UNKNOWN_DIR='whether its settings files are resolved profile files is unknown (the profile settings directory is not a canonical absolute path)'
run "S0b: an emitter-shaped instance with an mcp file: allowed" 0 - "$(from_to codex claudeMcp)"
run "S0b: an empty launchArgs: allowed" 0 - "$(from_to codex claudeEmpty)"
run "S0b: no launchArgs: allowed" 0 - "$(from_to codex claudeNoArgs)"
run "S1: inline settings JSON: refused" 2 "\"inlineSettings\": $OWN (inline settings JSON)" "$(from_to codex inlineSettings)"
lacks "S1: the refusal never prints the inline JSON" '"allow"' "$(from_to codex inlineSettings)"
for id in inlineEq inlineTwoSpace inlineLeadSpace inlineSecond topInline configInline; do
    run "S1b/S1c: $id: refused as inline settings JSON" 2 "\"$id\": $OWN (inline settings JSON)" "$(from_to codex "$id")"
    lacks "S1b/S1c: $id: the refusal never prints the inline JSON" '"env"' "$(from_to codex "$id")"
done
run "S1d: a driverless claudeAgent_ id is a Claude instance: refused" 2 "\"claudeAgent_nodriver\": $OWN (inline settings JSON)" "$(from_to codex claudeAgent_nodriver)"
run "S1d: a driverless non-Claude id is not judged by the Claude rule: allowed as the source" 0 - "$(from_to nodriverOther codex)"
run "S2: a hand-pointed settings file: refused" 2 "\"handPointed\": $OWN (--settings /x/design-full.json: not a resolved profile file under $LP)" "$(from_to codex handPointed)"
run "S2b: a relative settings path: refused" 2 "\"relativePath\": $OWN (--settings .himmel/worker-settings.json: not a resolved profile file under $LP)" "$(from_to codex relativePath)"
S2C_ROWS="$TMP/s2c-rows.jsonl"
run "S2c: a bare-token settings value is never printed" 2 "\"secretValue\": $OWN (--settings a value that is not a path: not a resolved profile file under $LP)" \
    "$(from_to codex secretValue)" HIMMEL_GUARD_REFUSALS_LOG="$S2C_ROWS"
lacks "S2c: secretValue: no marker on stderr" SECRETMARKER "$(from_to codex secretValue)"
run "S2c: a flag value is never printed, only its name" 2 "\"secretFlag\": $OWN (launchArgs not in the resolved-profile shape: --token)" \
    "$(from_to codex secretFlag)" HIMMEL_GUARD_REFUSALS_LOG="$S2C_ROWS"
lacks "S2c: secretFlag: no marker on stderr" SECRETMARKER "$(from_to codex secretFlag)"
N=$((N+1))
if [ -s "$S2C_ROWS" ] && ! grep -q SECRETMARKER "$S2C_ROWS"; then echo "ok   S2c: the refusal rows hold no marker"
else echo "FAIL S2c: the refusal rows are missing or hold a marker"; FAIL=$((FAIL+1)); fi
run "S3: a settings file edited in place: refused" 2 "\"editedFile\": $OWN (--settings $ED: its content does not match its resolved hash)" "$(from_to codex editedFile)"
lacks "S3: the refusal never prints the file's content" MARKERKEY "$(from_to codex editedFile)"
run "S3: an mcp file edited in place: refused" 2 "\"editedMcp\": $OWN (--mcp-config $EM: its content does not match its resolved hash)" "$(from_to codex editedMcp)"
run "S3: a missing settings file: refused" 2 "\"missingFile\": $OWN (--settings $LP/aaaaaaaaaaaa/missing.json: the file cannot be read)" "$(from_to codex missingFile)"
N=$((N+1))
if [ -p "$LP/bbbbbbbbbbbb/fifo.json" ]; then echo "ok   S3b: the FIFO fixture exists"; else echo "FAIL S3b: the test could not create the FIFO"; FAIL=$((FAIL+1)); fi
RUN_TIMEOUT=5 run "S3b: a FIFO settings file is refused unread, without hanging" 2 "\"fifoFile\": $OWN (--settings $LP/bbbbbbbbbbbb/fifo.json: the file cannot be read)" "$(from_to codex fifoFile)"
run "S4: an instance of any id on the maintainer-hooks file: refused" 2 \
    '"maintainerRenamed": is a maintainer-profile instance (its launchArgs point at the maintainer-hooks resolved file)' "$(from_to codex maintainerRenamed)"
run "S4: the maintainer file name in another case: refused" 2 '"maintainerCase": is a maintainer-profile instance' "$(from_to codex maintainerCase)"
run "S5: an extra flag: refused" 2 "\"extraFlag\": $OWN (launchArgs not in the resolved-profile shape: --allowedTools)" "$(from_to codex extraFlag)"
run "S5: an mcp file outside the settings directory: refused" 2 "\"mcpOutside\": $OWN (launchArgs not in the resolved-profile shape" "$(from_to codex mcpOutside)"
run "S5: a hashed file outside the settings directory: refused" 2 "\"otherDir\": $OWN (--settings $CT/other/$OH/x.json: not a resolved profile file under $LP)" "$(from_to codex otherDir)"
run "S5b: the settings directory is a string prefix, never a pattern: refused" 2 "\"dotDir\": $OWN (--settings $CT/Xlp/$OH/x.json: not a resolved profile file under $CT/.lp)" \
    "$(from_to codex dotDir)" HIMMEL_PROFILE_SETTINGS_DIR="$CT/.lp"
run "S6: an own-settings instance as the source: refused" 2 "\"inlineSettings\": $OWN" "$(from_to inlineSettings codex)"
run "S7: a codex instance's launch args are not judged by the Claude rule: allowed" 0 - "$(from_to codex codexArgs)"
run "S8b: a settings directory with a trailing slash: refused" 2 "\"claudeAgent_worker-impl\": $UNKNOWN_DIR" \
    "$(from_to codex claudeAgent_worker-impl)" HIMMEL_PROFILE_SETTINGS_DIR="$LP/"
run "S8b: a settings directory holding //: refused" 2 "\"claudeAgent_worker-impl\": $UNKNOWN_DIR" \
    "$(from_to codex claudeAgent_worker-impl)" HIMMEL_PROFILE_SETTINGS_DIR="$CT//lp"
mkdir -p "$TMP/nosha"
for t in bash jq cat tr cut sort sed date hostname uname mkdir dirname head grep wc awk; do
    p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$TMP/nosha/$t"
done
run "S9: no sha256 tool: refused" 2 '"claudeAgent_worker-impl": whether its settings files are resolved profile files is unknown (no sha256 tool)' \
    "$(from_to codex claudeAgent_worker-impl)" PATH="$TMP/nosha"
lacks "S9: no sha256 tool is not reported as a bad path" 'not a resolved profile file under' \
    "$(from_to codex claudeAgent_worker-impl)" PATH="$TMP/nosha"
run "S11: the operator override allows an own-settings instance, on stderr" 0 'override: allowed' "$(from_to codex inlineSettings)" T3_THREAD_TOOLS_OK=1
run "S12: the refusal text names the own-settings rule" 2 'whose launch line carries settings that are not a resolved profile file' "$(from_to codex handPointed)"
run "S13: a relative settings directory: refused" 2 "\"claudeAgent_worker-impl\": $UNKNOWN_DIR" \
    "$(from_to codex claudeAgent_worker-impl)" HIMMEL_PROFILE_SETTINGS_DIR=lp
run "S13: a settings directory with a space: refused" 2 "\"claudeAgent_worker-impl\": $UNKNOWN_DIR" \
    "$(from_to codex claudeAgent_worker-impl)" HIMMEL_PROFILE_SETTINGS_DIR="$CT/l p"
run "S14: a call that names no Claude instance verifies no settings file" 0 - "$(from_to codex antigravity)" PATH="$TMP/nosha"
run "S15: HOME unset and no settings directory: refused" 2 "\"claudeAgent_worker-impl\": $UNKNOWN_DIR" \
    "$(from_to codex claudeAgent_worker-impl)" -u HOME -u HIMMEL_PROFILE_SETTINGS_DIR

PIH="$TMP/pihome" PIS="$TMP/pi/userdata/settings.json"
mkdir -p "$PIH" "$TMP/pi/userdata"
printf '{"providerInstances":{}}\n' > "$PIS"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/agy-none.sh"
N=$((N+1))
if ! command -v node >/dev/null 2>&1; then
    echo "FAIL S8: node is not on PATH, so the real emitter cannot run"; FAIL=$((FAIL+1))
elif ! env -u T3_PI_RESOLVER -u T3_PI_EMPTY_OK HOME="$PIH" T3_PI_PROFILES=worker-impl,worker-docs,operator T3_PI_AGY_PROFILES="$TMP/agy-none.sh" \
        bash "$HOOKS/../t3/provider-instances.sh" --apply --settings-file "$PIS" >"$TMP/pi.out" 2>&1; then
    echo "FAIL S8: the real emitter failed: $(tail -n 3 "$TMP/pi.out")"; FAIL=$((FAIL+1))
elif ! jq -e '[.providerInstances[] | select(.driver == "claudeAgent") | .config.launchArgs | select(test("--mcp-config"))] | length > 0' "$PIS" >/dev/null 2>&1; then
    echo "FAIL S8: no emitted instance carries an --mcp-config file"; FAIL=$((FAIL+1))
else
    echo "ok   S8: the real emitter wrote its instances"
    for id in $(jq -r '.providerInstances | to_entries[] | select(.value.driver == "claudeAgent") | .key' "$PIS"); do
        run "S8: the emitted $id: allowed" 0 - "$(from_to codex "$id")" T3CODE_HOME="$TMP/pi"
    done
fi

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

mkdir -p "$TMP/emptyread"
printf '#!/usr/bin/env bash\ncase "$*" in *"then .driver else null"*) exit 0 ;; esac\nexec %q "$@"\n' "$(command -v jq)" > "$TMP/emptyread/jq"
chmod +x "$TMP/emptyread/jq"
run "an empty second read of T3's settings: every instance id refused" 2 'the drivers in T3' "$LAUNCH_OK" PATH="$TMP/emptyread:$PATH"

mkdir -p "$TMP/regtree/hooks" "$TMP/regtree/himmelctl/lib"
cp "$HOOK" "$TMP/regtree/hooks/guard-t3-thread-tools.sh"
cp -R "$HOOKS/../harnesses" "$TMP/regtree/harnesses"
REAL_HOOK="$HOOK" HOOK="$TMP/regtree/hooks/guard-t3-thread-tools.sh"
printf '{"flags":[{"name":"SKIP_CR"}]}\n' > "$TMP/regtree/himmelctl/lib/bypass-flags.json"
run "a fixture registry flag: refused" 2 '"skipCr": carries a himmel bypass flag (SKIP_CR)' "$(from_to codex skipCr)"
printf '{"flags":[{"name":7},{"name":"SKIP_CR"}]}\n' > "$TMP/regtree/himmelctl/lib/bypass-flags.json"
run "a registry entry with a non-string name: refused" 2 'whether it carries a bypass flag is unknown' "$(from_to codex antigravity)"
printf '{"flags":[{"bypasses":"x"}]}\n' > "$TMP/regtree/himmelctl/lib/bypass-flags.json"
run "a registry entry with no name: refused" 2 'whether it carries a bypass flag is unknown' "$(from_to codex antigravity)"
printf '{"flags":{"a":{"name":"SKIP_CR"}}}\n' > "$TMP/regtree/himmelctl/lib/bypass-flags.json"
run "a registry whose flags is not an array: refused" 2 'whether it carries a bypass flag is unknown' "$(from_to codex antigravity)"

printf '{"flags":[{"name":"SKIP_CR"}]}\n' > "$TMP/regtree/himmelctl/lib/bypass-flags.json"
run "a copied tree with an intact harness registry: allowed" 0 - "$(from_to codex antigravity)"
cp "$HOOKS/../harnesses/fixtures/fake-harness-incomplete.json" "$TMP/regtree/harnesses/fake-harness.json"
run "an incomplete fake harness: an agent launch is refused" 2 \
    '"fakeInst": its driver fake has an incomplete harness descriptor (fake-harness.json)' "$(from_to codex fakeInst)"
cp "$HOOKS/../harnesses/fixtures/fake-harness-complete.json" "$TMP/regtree/harnesses/fake-harness.json"
run "a complete fake harness: the launch passes" 0 - "$(from_to codex fakeInst)"
rm -f "$TMP/regtree/harnesses/fake-harness.json"
printf '{"id":' > "$TMP/regtree/harnesses/codex.json"
run "a malformed descriptor: an instance id refused" 2 'codex.json is not one JSON document' "$(from_to codex antigravity)"
run "a malformed descriptor: the source instance is refused too" 2 'the harness registry cannot be read' \
    '{"tool_name":"'$T't3_thread_launch","tool_input":{"title":"w","delegatedFrom":{"instanceId":"codex"}}}'
cp "$HOOKS/../harnesses/codex.json" "$TMP/regtree/harnesses/codex.json"
rm -f "$TMP/regtree/harnesses/grok.json"
run "a missing listed descriptor: an instance id refused" 2 'no descriptor for the listed harness grok' "$(from_to codex antigravity)"
cp "$HOOKS/../harnesses/grok.json" "$TMP/regtree/harnesses/grok.json"
printf 'empty\n' > "$TMP/regtree/harnesses/registry.jq"
run "a loader that returns nothing: the source instance is refused" 2 'the harness registry cannot be read' \
    '{"tool_name":"'$T't3_thread_launch","tool_input":{"title":"w","delegatedFrom":{"instanceId":"codex"}}}'
rm -rf "$TMP/regtree/harnesses"
run "a missing harness registry: an instance id refused" 2 'the harness registry cannot be read' "$(from_to codex antigravity)"
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
row_count() { if [ -f "$1" ]; then wc -l <"$1" | tr -d ' '; else echo 0; fi; } # read-sink-ok: counts lines of this suite's own fixture row files

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
run "S10: an inline-settings launch still refuses" 2 '"inlineSettings"' "$(from_to codex inlineSettings)"
check "S10: it writes one row naming the own-settings rule and the instance, never the settings" \
    '[ "$(row_count "$ROWS")" = 6 ] && [ "$(tail -n1 "$ROWS" | jq -r "[.rule, .instance] | join(\"|\")")" = "own-settings-instance|inlineSettings" ] && ! grep -q "permissions\|allow" <<<"$(tail -n1 "$ROWS")"'

FIFO="$TMP/fifo.jsonl"
N=$((N+1))
if ! mkfifo "$FIFO" 2>/dev/null || [ ! -p "$FIFO" ]; then
    echo "FAIL row: a log path that is a pipe with no reader never hangs the refusal: the test could not create the pipe"; FAIL=$((FAIL+1))
else
    printf '%s' "$LAUNCH_BAD" | timeout 5 env HIMMEL_GUARD_REFUSALS_LOG="$FIFO" bash "$HOOK" >/dev/null 2>&1; rc=$?
    if [ "$rc" = 2 ]; then echo "ok   row: a log path that is a pipe with no reader never hangs the refusal"
    else echo "FAIL row: a log path that is a pipe with no reader never hangs the refusal: rc=$rc (124 = the guard hung)"; FAIL=$((FAIL+1)); fi
fi

echo "$((N-FAIL))/$N cases; failures=$FAIL"
[ "$FAIL" = 0 ]
