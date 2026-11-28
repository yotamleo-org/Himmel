#!/usr/bin/env bash
# test-profile-settings.sh -- profile-settings.sh names the generated
# settings file by a hash of the resolved JSON, so two checkouts whose
# plugin-profiles.json differ cannot rewrite a file an armed relaunch already
# points at. Scratch HOME/dir only; never touches ~/.himmel/launch-profiles.
# Usage: bash scripts/lanes/test-profile-settings.sh   (bash 3.2-safe)
# shellcheck disable=SC2015  # ok() cannot fail; A && ok || bad is the intended guard
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
PS="$HERE/profile-settings.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/profile-settings.XXXXXX") && [ -d "$TMP" ] || { echo "FAIL mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export HIMMEL_PROFILE_SETTINGS_DIR="$TMP/profiles"
FAILED=0
ok() { echo "PASS $1"; }
bad() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

python3 - "$HERE/plugin-profiles.json" "$TMP/registry-b.json" <<'E'
import json, sys
d = json.load(open(sys.argv[1]))
d["profiles"]["user"]["enable"] = d["profiles"]["user"]["enable"] + ["hallmark@himmel"]
json.dump(d, open(sys.argv[2], "w"))
E

A1=$(bash "$PS" user); rc=$?
[ "$rc" = 0 ] && ok "T1 resolves rc=0" || bad "T1 rc=$rc"
case "$A1" in */user.json) ok "T1 basename stays <profile>.json" ;; *) bad "T1 basename: $A1" ;; esac
A1_BEFORE=$(cat "$A1")

A2=$(bash "$PS" user)
[ "$A1" = "$A2" ] && ok "T2 same content -> same path (stable)" || bad "T2 path moved: $A1 vs $A2"

B=$(PLUGIN_PROFILES_REGISTRY="$TMP/registry-b.json" bash "$PS" user); rc=$?
[ "$rc" = 0 ] && ok "T3 registry B resolves" || bad "T3 rc=$rc"
[ "$B" != "$A1" ] && ok "T3 different content -> different path" || bad "T3 same path for different content: $B"
[ "$(cat "$A1")" = "$A1_BEFORE" ] && ok "T4 first file untouched by the second resolution" || bad "T4 first file was rewritten"
cmp -s "$A1" "$B"; cmp_rc=$?
[ -f "$B" ] && [ "$cmp_rc" = 1 ] && ok "T4 second file holds the second content" || bad "T4 second file missing, equal or cmp error (rc=$cmp_rc)"

bash "$PS" no-such-profile >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "T5 unknown profile fails closed (rc=2)" || bad "T5 rc=$rc"

M=$(bash "$PS" chief --mcp-config); rc=$?
[ "$rc" = 0 ] && ok "T6 chief --mcp-config rc=0" || bad "T6 rc=$rc"
case "$M" in */chief.mcp.json) ok "T6 basename is <profile>.mcp.json" ;; *) bad "T6 basename: $M" ;; esac
if [ -f "$M" ] && grep -q '"qmd"' "$M" && grep -q '"himmel-bus"' "$M" && ! grep -q '"graphify"' "$M"; then
    ok "T6 file holds exactly the profile's servers (qmd, himmel-bus; no graphify)"
else bad "T6 file content wrong: $M"; fi
if [ "$(stat -c %a "$M" 2>/dev/null || stat -f %Lp "$M")" = 600 ] && [ "$(stat -c %a "${M%/*}" 2>/dev/null || stat -f %Lp "${M%/*}")" = 700 ]; then
    ok "T6 mcp file is 0600 in a 0700 dir (inline credentials)"
else bad "T6 mcp file/dir permissions are not 600/700: $M"; fi
N=$(bash "$PS" user --mcp-config); rc=$?
[ "$rc" = 0 ] && [ -z "$N" ] && ok "T7 profile without mcpServers: empty output, rc=0" || bad "T7 rc=$rc out=[$N]"
bash "$PS" no-such-profile --mcp-config >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "T8 unknown profile --mcp-config fails closed (rc=2)" || bad "T8 rc=$rc"

python3 - "$HERE/plugin-profiles.json" "$TMP/registry-c.json" <<'E'
import json, sys
d = json.load(open(sys.argv[1]))
d["profiles"]["chief"]["mcpServers"] = ["qmd", "no-such-server-5310"]
json.dump(d, open(sys.argv[2], "w"))
E
PLUGIN_PROFILES_REGISTRY="$TMP/registry-c.json" bash "$PS" chief >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok "T9 undefined mcp server: settings still resolve (rc=0)" || bad "T9 settings rc=$rc"
O=$(PLUGIN_PROFILES_REGISTRY="$TMP/registry-c.json" bash "$PS" chief --mcp-config 2>/dev/null); rc=$?
[ "$rc" = 2 ] && [ -z "$O" ] && ok "T9 undefined mcp server: --mcp-config fails closed (rc=2, no path)" || bad "T9 mcp rc=$rc out=[$O]"

RH="$TMP/readiness-home"; mkdir -p "$RH/.claude"
rprof() { HOME="$RH" CLAUDE_CONFIG_DIR="$RH/.claude" bash "$PS" "$@"; }
R=$(rprof readiness); rc=$?
[ "$rc" = 0 ] && ok "T10 readiness resolves rc=0" || bad "T10 rc=$rc out=[$R]"
case "$R" in */readiness.json) ok "T10 basename is readiness.json" ;; *) bad "T10 basename: $R" ;; esac
if python3 - "$R" <<'E'
import json, sys
d = json.load(open(sys.argv[1]))
p = d["permissions"]
assert p["allow"] == ["mcp__readiness__inspect", "mcp__readiness__act"], p["allow"]
assert sorted(p["deny"]) == sorted(["Agent", "Artifact", "Bash", "Edit", "Glob", "Grep", "NotebookEdit", "Read", "WebFetch", "WebSearch", "Write"]), p["deny"]
assert not any(k in d for k in ("autoMode", "disableWorkflows")), list(d)
on = sorted(k for k, v in d["enabledPlugins"].items() if v)
assert on == ["handover@himmel", "himmel-ops@himmel", "qmd@himmel"], on
E
then ok "T10 settings: exactly the two grants, every native tool denied, floor plugins only"
else bad "T10 settings content wrong: $R"; fi
RM=$(rprof readiness --mcp-config); rc=$?
[ "$rc" = 0 ] && ok "T11 readiness --mcp-config rc=0" || bad "T11 rc=$rc out=[$RM]"
case "$RM" in */readiness.mcp.json) ok "T11 basename is readiness.mcp.json" ;; *) bad "T11 basename: $RM" ;; esac
[ "$(tr -d ' \n' < "$RM" 2>/dev/null)" = '{"mcpServers":{}}' ] && ok "T11 static config holds NO server (the adapter config is launcher-generated)" || bad "T11 config: $(cat "$RM" 2>/dev/null)"
python3 - "$HERE/plugin-profiles.json" "$TMP/registry-d.json" <<'E'
import json, sys
d = json.load(open(sys.argv[1]))
if "readiness" in d["profiles"]: d["profiles"]["readiness"]["gateAllow"] = True
json.dump(d, open(sys.argv[2], "w"))
E
E12=$(PLUGIN_PROFILES_REGISTRY="$TMP/registry-d.json" rprof readiness 2>&1 >/dev/null); rc=$?
case "$E12" in *'registry invalid'*readiness*gateAllow*) [ "$rc" = 2 ] && ok "T12 readiness widened with gateAllow fails closed (rc=2, names the registry error)" || bad "T12 rc=$rc" ;; *) bad "T12 wrong refusal reason (rc=$rc): $E12" ;; esac
python3 - "$HERE/plugin-profiles.json" "$TMP/registry-e.json" <<'E'
import json, sys
d = json.load(open(sys.argv[1]))
if "readiness" in d["profiles"]: d["profiles"]["readiness"]["mcpServers"] = ["qmd"]
json.dump(d, open(sys.argv[2], "w"))
E
E12=$(PLUGIN_PROFILES_REGISTRY="$TMP/registry-e.json" rprof readiness --mcp-config 2>&1 >/dev/null); rc=$?
case "$E12" in *'registry invalid'*readiness*mcpServers*) [ "$rc" = 2 ] && ok "T12 readiness with a named MCP server fails closed (rc=2, names the registry error)" || bad "T12 mcp rc=$rc" ;; *) bad "T12 mcp wrong refusal reason (rc=$rc): $E12" ;; esac
for list in readiness,worker-impl worker-impl,readiness; do
    E13=$(cd "$RH" && HOME="$RH" CLAUDE_CONFIG_DIR="$RH/.claude" node "$HERE/plugin-profiles.mjs" "$list" 2>&1 >/dev/null); rc=$?
    case "$E13" in *'cannot be composed'*) [ "$rc" = 2 ] && ok "T13 $list refuses to compose (rc=2)" || bad "T13 $list rc=$rc" ;; *) bad "T13 $list wrong refusal reason (rc=$rc): $E13" ;; esac
done

envof() { python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])).get("env"), sort_keys=True))' "$1"; }
for mode in '' --mcp-config; do
    E14=$(bash "$PS" maintainer-hooks ${mode:+"$mode"} 2>&1 >/dev/null); rc=$?
    case "$E14" in *'carries a maintainer grant'*) [ "$rc" = 4 ] && ok "T14 maintainer-hooks ${mode:-settings} refused rc=4" || bad "T14 ${mode:-settings} rc=$rc" ;;
        *) bad "T14 maintainer-hooks ${mode:-settings} not refused (rc=$rc): $E14" ;; esac
done
written=$(find "$HIMMEL_PROFILE_SETTINGS_DIR" -name 'maintainer-hooks.*' 2>/dev/null)
[ -z "$written" ] && ok "T14 no maintainer-hooks settings file written" || bad "T14 wrote $written"
WI=$(bash "$PS" worker-impl); rc=$?
[ "$rc" = 0 ] && [ "$(envof "$WI")" = null ] && ok "T14 worker-impl file carries no env block (control)" || bad "T14 worker-impl rc=$rc env=$(envof "$WI" 2>/dev/null)"

if [ "$FAILED" -gt 0 ]; then echo "---"; echo "FAIL $FAILED case(s)"; exit 1; fi
echo "---"; echo "ALL PASS"
