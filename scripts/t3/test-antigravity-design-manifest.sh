#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REGISTRY="$HERE/antigravity-profiles.json"
PLUGIN_PROFILES="$HERE/../lanes/plugin-profiles.json"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
expect_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got: $2 want: $3)"; fi; }

command -v jq >/dev/null 2>&1 || { echo "jq missing"; exit 2; }

SKILLS_PER_PLUGIN_AT_2026_11_26='{
 "domain-modeling@himmel":1,"plannotator-effective-html@himmel":7,"frontend-design@claude-plugins-official":1,
 "ui-ux-pro-max@himmel":7,"impeccable@himmel":1,"taste-skill-core@himmel":1,"shadcn-mcp@himmel":1,
 "builder-visual@himmel":26,"unslop-ui@himmel":1,"context7@claude-plugins-official":0,
 "ai-image-prompts@himmel":1,"higgsfield-skills@himmel":8}'
CEILING_BELOW_THE_56_THAT_DROPPED_FOUR=32

PLUGINS="$(jq -r --slurpfile pp "$PLUGIN_PROFILES" '
    (.profiles.design.excludePlugins // []) as $ex
    | [.profiles.design.fromProfiles[] as $f | $pp[0].profiles[$f].enable[]]
    | reduce .[] as $x ([]; if index($x) then . else . + [$x] end)
    | map(select(. as $i | $ex | index($i) | not)) | .[]' "$REGISTRY")"
SKILLS="$(printf '%s\n' "$PLUGINS" | jq -R -s --argjson c "$SKILLS_PER_PLUGIN_AT_2026_11_26" 'split("\n") | map(select(length > 0) | $c[.] // error("no count for " + .)) | add // 0')" || SKILLS=""
case "$SKILLS" in ''|*[!0-9]*) bad "every design plugin has a skill count"; SKILLS=0 ;; esac
PINNED="$(jq '[.profiles.design.pinnedSkills[]?.include | length] | add // 0' "$REGISTRY")"
TOTAL=$((SKILLS + PINNED))

if [ "$TOTAL" -le "$CEILING_BELOW_THE_56_THAT_DROPPED_FOUR" ]; then ok "design resolves $TOTAL skills (<= $CEILING_BELOW_THE_56_THAT_DROPPED_FOUR)"; else bad "design resolves $TOTAL skills (> $CEILING_BELOW_THE_56_THAT_DROPPED_FOUR)"; fi
for id in taste-skill-core@himmel higgsfield-skills@himmel; do
    if printf '%s\n' "$PLUGINS" | grep -qx "$id"; then ok "design keeps $id"; else bad "design lost $id"; fi
done
if printf '%s\n' "$PLUGINS" | grep -qx "builder-visual@himmel"; then bad "design still resolves builder-visual@himmel"; else ok "design excludes builder-visual@himmel"; fi

expect_eq "design declares context7 over https" "$(jq -r '.profiles.design.mcpServers.context7.url // "" | split("?")[0]' "$REGISTRY")" "https://mcp.context7.com/mcp"
expect_eq "context7 is an http server" "$(jq -r '.profiles.design.mcpServers.context7.type // ""' "$REGISTRY")" "http"
expect_eq "shadcn runs through npx" "$(jq -r '.profiles.design.mcpServers.shadcn.command // ""' "$REGISTRY")" "npx"
expect_eq "design declares shadcn pinned and starts its mcp server" "$(jq -c '.profiles.design.mcpServers.shadcn.args // []' "$REGISTRY")" '["-y","shadcn@4.21.0","mcp"]'
expect_eq "design names playwright as optional" "$(jq -c '.profiles.design.optionalMcpServers // []' "$REGISTRY")" '["playwright"]'
expect_eq "playwright is in the plugin-profiles mcpCatalog" "$(jq -r '.mcpCatalog.playwright.args[1] // ""' "$PLUGIN_PROFILES")" "@playwright/mcp@0.0.83"
expect_eq "agent-native-dispatch is not wired" "$(jq -r '[.profiles.design.mcpServers // {} | keys[] | select(test("agent-native"))] | length' "$REGISTRY")" "0"
expect_eq "every npx mcp server pins an exact version" "$(jq -r '[.profiles.design.mcpServers // {} | .[] | select(.command == "npx") | .args[1] | select(test("@[0-9]+[.][0-9]+[.][0-9]+$") | not)] | length' "$REGISTRY")" "0"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
