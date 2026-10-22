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

# Registry B differs from the shipped one in what `user` resolves to.
python3 - "$HERE/plugin-profiles.json" "$TMP/registry-b.json" <<'E'
import json, sys
d = json.load(open(sys.argv[1]))
d["profiles"]["user"]["drop"] = ["lean-skills@himmel"]
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

# --mcp-config resolves the profile's mcpServers allowlist to a
# content-addressed --mcp-config file; a profile with no allowlist prints nothing.
M=$(bash "$PS" console --mcp-config); rc=$?
[ "$rc" = 0 ] && ok "T6 console --mcp-config rc=0" || bad "T6 rc=$rc"
case "$M" in */console.mcp.json) ok "T6 basename is <profile>.mcp.json" ;; *) bad "T6 basename: $M" ;; esac
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

# T9: the settings resolve but the allowlist names an undefined server, so only
# the --mcp-config step fails: the fail-closed branch itself (a `|| true` on it
# must turn this red, which T8's earlier unknown-profile refusal cannot).
python3 - "$HERE/plugin-profiles.json" "$TMP/registry-c.json" <<'E'
import json, sys
d = json.load(open(sys.argv[1]))
d["profiles"]["console"]["mcpServers"] = ["qmd", "no-such-server-5310"]
json.dump(d, open(sys.argv[2], "w"))
E
PLUGIN_PROFILES_REGISTRY="$TMP/registry-c.json" bash "$PS" console >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok "T9 undefined mcp server: settings still resolve (rc=0)" || bad "T9 settings rc=$rc"
O=$(PLUGIN_PROFILES_REGISTRY="$TMP/registry-c.json" bash "$PS" console --mcp-config 2>/dev/null); rc=$?
[ "$rc" = 2 ] && [ -z "$O" ] && ok "T9 undefined mcp server: --mcp-config fails closed (rc=2, no path)" || bad "T9 mcp rc=$rc out=[$O]"

if [ "$FAILED" -gt 0 ]; then echo "---"; echo "FAIL $FAILED case(s)"; exit 1; fi
echo "---"; echo "ALL PASS"
