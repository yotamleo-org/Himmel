#!/usr/bin/env bash
# scripts/t3/test-provider-instances.sh - fixture suite for provider-instances.sh.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
GEN="$HERE/provider-instances.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/t3pi.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home/.himmel"
export HOME="$T/home"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
expect_ok()   { local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }
expect_fail() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$n"; else ok "$n"; fi; }
expect_rc()   { local n="$1" want="$2" rc; shift 2; "$@" >/dev/null 2>&1; rc=$?; if [ "$rc" = "$want" ]; then ok "$n"; else bad "$n (rc=$rc)"; fi; }
expect_eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got: $2)"; fi; }
launch_args() { jq -r --arg id "$2" '.providerInstances[$id].config.launchArgs' "$1"; }

cat > "$T/resolver.sh" <<'RES'
#!/usr/bin/env bash
case "$1" in
  ghost) exit 2 ;;
  broken) echo "boom" >&2; exit 3 ;;
esac
if [ "${2:-}" = --mcp-config ]; then
  [ "$1" = alpha ] && echo "/stable/mcp-aaa/alpha.mcp.json"
  exit 0
fi
echo "/stable/h1/$1.json"
RES
chmod +x "$T/resolver.sh"
export T3_PI_RESOLVER="$T/resolver.sh"
export T3_PI_PROFILES="alpha,beta,chief"
export T3_PI_EMPTY_OK="ghost"

CHIEF_ARGS="--settings /x/291b/chief.json --mcp-config /x/m/chief.mcp.json --strict-mcp-config"
S="$T/settings.json"
cat > "$S" <<'JSON'
{"idleCompaction":true,"providerInstances":{"claudeAgent_claude_chief":{"driver":"claudeAgent","displayName":"Claude (chief)","enabled":true,"config":{"launchArgs":"--settings /x/291b/chief.json --mcp-config /x/m/chief.mcp.json --strict-mcp-config"}},"mine":{"driver":"codex","enabled":true}}}
JSON
cp "$S" "$T/orig.json"

out="$(bash "$GEN" --settings-file "$S" 2>&1)"; rc=$?
expect_eq "dry-run exits 0" "$rc" 0
expect_ok "dry-run leaves file untouched" cmp -s "$S" "$T/orig.json"
expect_ok "dry-run diff names claudeAgent_alpha" grep -q 'claudeAgent_alpha' <<<"$out"
expect_ok "prints allowlist id claudeAgent_alpha" grep -q '^claudeAgent_alpha$' <<<"$out"
expect_fail "no allowlist id for a profile already covered" grep -q '^claudeAgent_chief$' <<<"$out"

expect_ok "apply exits 0" bash "$GEN" --apply --settings-file "$S"
expect_eq "alpha launchArgs has settings and mcp" "$(launch_args "$S" claudeAgent_alpha)" "--settings /stable/h1/alpha.json --mcp-config /stable/mcp-aaa/alpha.mcp.json --strict-mcp-config"
expect_eq "beta launchArgs has settings only" "$(launch_args "$S" claudeAgent_beta)" "--settings /stable/h1/beta.json"
expect_eq "instance driver is claudeAgent" "$(jq -r '.providerInstances.claudeAgent_alpha.driver' "$S")" claudeAgent

expect_eq "unrelated instance preserved" "$(jq -r '.providerInstances.mine.driver' "$S")" codex
expect_eq "existing chief instance untouched" "$(launch_args "$S" claudeAgent_claude_chief)" "$CHIEF_ARGS"
expect_eq "covered profile not duplicated" "$(jq -r '.providerInstances|has("claudeAgent_chief")' "$S")" false
expect_eq "unrelated top-level keys preserved" "$(jq -r '.idleCompaction' "$S")" true

cp "$S" "$T/after1.json"
expect_ok "second apply exits 0" bash "$GEN" --apply --settings-file "$S"
expect_ok "second apply leaves file byte-identical" cmp -s "$S" "$T/after1.json"
nbak=0; for f in "$T"/settings.json.bak.*; do [ -e "$f" ] && nbak=$((nbak+1)); done
expect_eq "apply wrote exactly one timestamped backup" "$nbak" 1

expect_ok "empty-resolving profile gets the deny-only instance, rc 0" env T3_PI_PROFILES="alpha,ghost" bash "$GEN" --settings-file "$S"
expect_fail "resolver failure refused" env T3_PI_PROFILES="alpha,broken" bash "$GEN" --settings-file "$S"

B="$T/bypass.json"
cat > "$B" <<'JSON'
{"providerInstances":{"evil":{"driver":"claudeAgent","config":{"environment":[{"name":"EDIT_ON_MAIN_OK","value":"1"}]}}}}
JSON
cp "$B" "$T/bypass.orig"
expect_rc "env entry *_OK refused with rc 3" 3 bash "$GEN" --apply --settings-file "$B"
expect_ok "bypass refusal leaves file untouched" cmp -s "$B" "$T/bypass.orig"
cat > "$B" <<'JSON'
{"providerInstances":{"evil":{"driver":"claudeAgent","config":{"env":{"GUARD_BYPASS_X":"1"}}}}}
JSON
expect_rc "env object *BYPASS* refused (dry-run too)" 3 bash "$GEN" --settings-file "$B"
cat > "$B" <<'JSON'
{"providerInstances":{"evil":{"driver":"claudeAgent","config":{"env":{},"environment":[{"name":"X_OK","value":"1"}]}}}}
JSON
expect_rc "empty env does not hide a bypass flag in environment" 3 bash "$GEN" --settings-file "$B"
cat > "$B" <<'JSON'
{"providerInstances":{"evil":{"driver":"claudeAgent","config":{"environment":[7]}}}}
JSON
expect_fail "a malformed environment entry fails closed" bash "$GEN" --apply --settings-file "$B"
cat > "$B" <<'JSON'
{"providerInstances":{"evil":{"driver":"claudeAgent","environment":[{"name":"EDIT_ON_MAIN_OK","value":"1"}],"config":{}}}}
JSON
expect_rc "instance-level environment *_OK refused" 3 bash "$GEN" --settings-file "$B"
cat > "$B" <<'JSON'
{"providerInstances":{"evil":{"driver":"claudeAgent","environment":[{"name":"SAFE","value":"1"}],"config":{"launchArgs":"--settings /x/y.json --dangerously-skip-permissions"}}}}
JSON
expect_rc "launchArgs with --dangerously-skip-permissions refused" 3 bash "$GEN" --settings-file "$B"
cat > "$B" <<'JSON'
{"providerInstances":{"evil":{"driver":"claudeAgent","config":{"launchArgs":"--permission-mode bypassPermissions"}}}}
JSON
expect_rc "launchArgs with --permission-mode bypassPermissions refused" 3 bash "$GEN" --settings-file "$B"

M="$T/bad.json"; printf '{"providerInstances": {' > "$M"; cp "$M" "$T/bad.orig"
expect_fail "malformed file refused" bash "$GEN" --apply --settings-file "$M"
expect_ok "malformed file untouched" cmp -s "$M" "$T/bad.orig"
nbad=0; for f in "$T"/bad.json.bak.*; do [ -e "$f" ] && nbad=$((nbad+1)); done
expect_eq "no backup made for malformed file" "$nbad" 0

expect_fail "missing settings file refused" bash "$GEN" --apply --settings-file "$T/nope.json"
expect_fail "missing --settings-file refused" bash "$GEN" --apply

CFG="$HOME/.himmel/config.json"
set_cfg() { printf '%s' "$1" > "$CFG"; }
cat > "$T/resolver2.sh" <<'RES'
#!/usr/bin/env bash
[ "${2:-}" = --mcp-config ] && exit 0
echo "/stable/h2/$1.json"
RES
chmod +x "$T/resolver2.sh"
rm -f "$CFG"

R1="$T/relay1.json"
cat > "$R1" <<'JSON'
{"providerInstances":{"claudeAgent_alpha":{"driver":"claudeAgent","displayName":"Claude (alpha)","enabled":true,"config":{"launchArgs":"--settings /old/alpha.json"}},"claudeAgent_alpha_relay":{"driver":"claudeAgent","displayName":"Claude (alpha) + chief relay","enabled":true,"config":{"launchArgs":"--settings /old/alpha.json"}}}}
JSON
expect_ok "relay copy does not mark base covered: apply" env T3_PI_RESOLVER="$T/resolver2.sh" T3_PI_PROFILES=alpha bash "$GEN" --apply --settings-file "$R1"
expect_eq "relay copy does not mark base covered: base refreshed" "$(launch_args "$R1" claudeAgent_alpha)" "--settings /stable/h2/alpha.json"

R2="$T/relay2.json"
cat > "$R2" <<'JSON'
{"providerInstances":{"claudeAgent_alpha":{"driver":"claudeAgent","displayName":"Claude (alpha)","enabled":true,"config":{"launchArgs":"--settings /old/alpha.json"}}}}
JSON
set_cfg '{"t3":{"relay_instances":["claudeAgent_alpha"]}}'
out="$(env T3_PI_RESOLVER="$T/resolver2.sh" T3_PI_PROFILES=alpha bash "$GEN" --settings-file "$R2" 2>&1)"; rc=$?
expect_eq "relay dry-run exits 0" "$rc" 0
expect_ok "relay dry-run proposes claudeAgent_alpha_relay" grep -q 'claudeAgent_alpha_relay' <<<"$out"
expect_ok "relay dry-run prints the _relay allowlist id" grep -q '^claudeAgent_alpha_relay$' <<<"$out"

R3="$T/relay3.json"
printf '{"providerInstances":{}}' > "$R3"
expect_ok "relay apply exits 0" env T3_PI_RESOLVER="$T/resolver2.sh" T3_PI_PROFILES=alpha bash "$GEN" --apply --settings-file "$R3"
expect_eq "copy has the base driver" "$(jq -r '.providerInstances.claudeAgent_alpha_relay.driver' "$R3")" claudeAgent
expect_eq "copy has the base's current launchArgs" "$(launch_args "$R3" claudeAgent_alpha_relay)" "$(launch_args "$R3" claudeAgent_alpha)"
expect_eq "copy is named '+ chief relay'" "$(jq -r '.providerInstances.claudeAgent_alpha_relay.displayName' "$R3")" "Claude (alpha) + chief relay"
expect_eq "copy is enabled" "$(jq -r '.providerInstances.claudeAgent_alpha_relay.enabled' "$R3")" true
cp "$R3" "$T/relay3.after1"
expect_ok "second relay apply exits 0" env T3_PI_RESOLVER="$T/resolver2.sh" T3_PI_PROFILES=alpha bash "$GEN" --apply --settings-file "$R3"
expect_ok "second relay apply is a no-op" cmp -s "$R3" "$T/relay3.after1"

jq '.providerInstances.claudeAgent_alpha_relay |= (.displayName="hand" | .config.launchArgs="--settings /bad.json")' "$R3" > "$T/relay3.edit" && cp "$T/relay3.edit" "$R3"
expect_ok "hand-edited copy: apply" env T3_PI_RESOLVER="$T/resolver2.sh" T3_PI_PROFILES=alpha bash "$GEN" --apply --settings-file "$R3"
expect_ok "hand-edited copy regenerated from its base" cmp -s "$R3" "$T/relay3.after1"

expect_ok "base moves: apply" env T3_PI_RESOLVER="$T/resolver.sh" T3_PI_PROFILES=alpha bash "$GEN" --apply --settings-file "$R3"
expect_eq "copy follows the base in the same run" "$(launch_args "$R3" claudeAgent_alpha_relay)" "$(launch_args "$R3" claudeAgent_alpha)"

for off in '{"t3":{}}' '{"t3":{"relay_instances":[]}}' '{}' ; do
    set_cfg "$off"
    R="$T/off.json"; printf '{"providerInstances":{}}' > "$R"
    env T3_PI_RESOLVER="$T/resolver2.sh" T3_PI_PROFILES=alpha bash "$GEN" --apply --settings-file "$R" >/dev/null 2>&1
    expect_eq "no _relay id when config is $off" "$(jq -r '.providerInstances|"\(has("claudeAgent_alpha")) \([keys[]|select(endswith("_relay"))]|length)"' "$R")" "true 0"
done
rm -f "$CFG"
R="$T/off.json"; printf '{"providerInstances":{}}' > "$R"
env T3_PI_RESOLVER="$T/resolver2.sh" T3_PI_PROFILES=alpha bash "$GEN" --apply --settings-file "$R" >/dev/null 2>&1
expect_eq "no _relay id with no config file" "$(jq -r '.providerInstances|"\(has("claudeAgent_alpha")) \([keys[]|select(endswith("_relay"))]|length)"' "$R")" "true 0"

printf '{"t3":{"relay_instances":["claudeAgent_alpha"]}}' > "$T/other.json"
R="$T/seam.json"; printf '{"providerInstances":{}}' > "$R"
env T3_PI_CONFIG="$T/other.json" T3_PI_RESOLVER="$T/resolver2.sh" T3_PI_PROFILES=alpha bash "$GEN" --apply --settings-file "$R" >/dev/null 2>&1
expect_eq "T3_PI_CONFIG is not read" "$(jq -r '.providerInstances|"\(has("claudeAgent_alpha")) \([keys[]|select(endswith("_relay"))]|length)"' "$R")" "true 0"

set_cfg '{"t3":{"relay_instances":["nope","claudeAgent_alpha"]}}'
R="$T/unk.json"; printf '{"providerInstances":{}}' > "$R"
out="$(env T3_PI_RESOLVER="$T/resolver2.sh" T3_PI_PROFILES=alpha bash "$GEN" --apply --settings-file "$R" 2>&1)"; rc=$?
expect_eq "unknown id: rc 0" "$rc" 0
expect_ok "unknown id: warns naming it" grep -q "nope" <<<"$out"
expect_eq "unknown id: no copy" "$(jq -r '.providerInstances|has("nope_relay")' "$R")" false
expect_eq "unknown id: known id still copied" "$(jq -r '.providerInstances|has("claudeAgent_alpha_relay")' "$R")" true

set_cfg '{"t3":{"relay_instances":["antigravity"]}}'
R="$T/anti.json"
cat > "$R" <<'JSON'
{"providerInstances":{"antigravity":{"driver":"antigravity","displayName":"Antigravity","enabled":false,"config":{"x":1}}}}
JSON
env T3_PI_RESOLVER="$T/resolver2.sh" T3_PI_PROFILES=alpha bash "$GEN" --apply --settings-file "$R" >/dev/null 2>&1
expect_eq "antigravity copy keeps its driver" "$(jq -r '.providerInstances.antigravity_relay.driver' "$R")" antigravity
expect_eq "antigravity copy keeps its config" "$(jq -c '.providerInstances.antigravity_relay.config' "$R")" '{"x":1}'
expect_eq "antigravity copy is enabled and named" "$(jq -r '.providerInstances.antigravity_relay|"\(.enabled) \(.displayName)"' "$R")" "true Antigravity + chief relay"

set_cfg '{"t3":{"relay_instances":["codex"]}}'
R="$T/codex.json"; printf '{"providerInstances":{}}' > "$R"
env T3_PI_BUILTIN_RELAY=1 T3_PI_RESOLVER="$T/resolver2.sh" T3_PI_PROFILES=alpha bash "$GEN" --apply --settings-file "$R" >/dev/null 2>&1
expect_eq "codex gate on: driver-only entry" "$(jq -c '.providerInstances.codex_relay' "$R")" '{"driver":"codex","enabled":true,"displayName":"codex + chief relay"}'
R="$T/codex2.json"; printf '{"providerInstances":{}}' > "$R"
out="$(env T3_PI_BUILTIN_RELAY=0 T3_PI_RESOLVER="$T/resolver2.sh" T3_PI_PROFILES=alpha bash "$GEN" --apply --settings-file "$R" 2>&1)"; rc=$?
expect_eq "codex gate off: rc 0" "$rc" 0
expect_eq "codex gate off: no entry" "$(jq -r '.providerInstances|has("codex_relay")' "$R")" false
expect_ok "codex gate off: warns naming the switch" grep -q 'T3_PI_BUILTIN_RELAY' <<<"$out"

set_cfg '{"t3":{"relay_instances":["evil"]}}'
R="$T/evil.json"
cat > "$R" <<'JSON'
{"providerInstances":{"evil":{"driver":"claudeAgent","enabled":true,"config":{"launchArgs":"--permission-mode bypassPermissions"}}}}
JSON
cp "$R" "$T/evil.orig"
out="$(env T3_PI_RESOLVER="$T/resolver2.sh" T3_PI_PROFILES=alpha bash "$GEN" --apply --settings-file "$R" 2>&1)"; rc=$?
expect_eq "bypass base with relay: rc 3" "$rc" 3
expect_ok "bypass refusal names the copy" grep -q 'evil_relay' <<<"$out"
expect_ok "bypass refusal leaves file untouched" cmp -s "$R" "$T/evil.orig"
rm -f "$CFG"

settings_of() { launch_args "$1" "$2" | sed -n 's/^--settings \([^ ]*\).*/\1/p'; }
artifact_of() { jq -r '(.permissions.deny // []) | index("Artifact") | tostring' "$1" 2>/dev/null || echo unreadable; }
A="$T/artifact.json"; printf '{"providerInstances":{"claudeAgent":{"driver":"claudeAgent","enabled":true,"config":{"binaryPath":"/opt/claude"}}}}' > "$A"
env T3_PI_RESOLVER= T3_PI_PROFILES="user,code,operator" T3_PI_EMPTY_OK=operator bash "$GEN" --apply --settings-file "$A" >/dev/null 2>&1
expect_eq "default instance denies Artifact" "$(artifact_of "$(settings_of "$A" claudeAgent)")" 0
expect_eq "default instance keeps its other config" "$(jq -r '.providerInstances.claudeAgent.config.binaryPath' "$A")" /opt/claude
expect_eq "no-settings profile instance denies Artifact" "$(artifact_of "$(settings_of "$A" claudeAgent_operator)")" 0
expect_eq "profile without artifact: true denies Artifact" "$(artifact_of "$(settings_of "$A" claudeAgent_code)")" 0
expect_eq "artifact: true profile (user) keeps Artifact" "$(artifact_of "$(settings_of "$A" claudeAgent_user)")" null
printf '{"providerInstances":{}}' > "$A"
env T3_PI_RESOLVER= T3_PI_PROFILES="user" bash "$GEN" --apply --settings-file "$A" >/dev/null 2>&1
expect_eq "default instance is created when absent" "$(jq -r '.providerInstances.claudeAgent|"\(.driver) \(.enabled)"' "$A")" "claudeAgent true"
cp "$A" "$T/artifact.after1"
env T3_PI_RESOLVER= T3_PI_PROFILES="user" bash "$GEN" --apply --settings-file "$A" >/dev/null 2>&1
expect_ok "default instance: second apply is a no-op" cmp -s "$A" "$T/artifact.after1"

U="$T/userargs.json"
printf '{"providerInstances":{"claudeAgent":{"driver":"claudeAgent","enabled":true,"config":{"launchArgs":"--model my-own"}}}}' > "$U"
out="$(env T3_PI_RESOLVER= T3_PI_PROFILES="user" bash "$GEN" --apply --settings-file "$U" 2>&1)"; rc=$?
expect_eq "user launchArgs on the default instance: rc 0" "$rc" 0
expect_eq "user launchArgs on the default instance are kept" "$(launch_args "$U" claudeAgent)" "--model my-own"
expect_ok "user launchArgs on the default instance: warns naming claudeAgent" grep -q 'claudeAgent.*own launchArgs' <<<"$out"

U2="$T/userargs2.json"
printf '{"providerInstances":{"claudeAgent":{"driver":"claudeAgent","enabled":true,"config":{"launchArgs":"--settings /stable/h1/alpha.json"}}}}' > "$U2"
env T3_PI_RESOLVER="$T/resolver.sh" T3_PI_PROFILES="alpha" bash "$GEN" --apply --settings-file "$U2" >/dev/null 2>&1
expect_eq "default instance naming a profile's --settings is kept" "$(launch_args "$U2" claudeAgent)" "--settings /stable/h1/alpha.json"
expect_eq "that profile still gets its own instance" "$(launch_args "$U2" claudeAgent_alpha)" "--settings /stable/h1/alpha.json --mcp-config /stable/mcp-aaa/alpha.mcp.json --strict-mcp-config"

U3="$T/userargs3.json"
printf '{"providerInstances":{"claudeAgent":{"driver":"claudeAgent","enabled":true,"config":{"launchArgs":"--settings /old/abc/artifact-deny.json"}}}}' > "$U3"
env T3_PI_RESOLVER= T3_PI_PROFILES="user" bash "$GEN" --apply --settings-file "$U3" >/dev/null 2>&1
expect_eq "launchArgs the script wrote earlier are refreshed" "$(artifact_of "$(settings_of "$U3" claudeAgent)")" 0

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
