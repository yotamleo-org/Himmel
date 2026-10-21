#!/usr/bin/env bash
# test-scan-duplicates.sh — rows for scripts/install/scan-duplicates.sh, the
# read-only post-install duplicate scan llms.txt tells an installing LLM to run.
#
# Every row builds a fixture HOME + project under a scratch dir and runs the
# scan against it. The himmel-guard row copies its two halves from the real
# repo: the plugin's shipped hooks.json and the harness's own block-destructive-
# commands hook stanza, so the fixture is the real shape, not a hand-written one.
# shellcheck disable=SC2016
set -uo pipefail

repo_root=$(git rev-parse --show-toplevel)
scan="$repo_root/scripts/install/scan-duplicates.sh"
guard_hooks="$repo_root/marketplace/plugins/himmel-guard/hooks/hooks.json"
harness_settings="$repo_root/.claude/settings.json"

command -v jq >/dev/null 2>&1 || { echo "$(basename "$0"): SKIPPED — 0 cases ran (jq not on PATH)"; exit 0; }

work=$(mktemp -d "${TMPDIR:-/tmp}/scan-dups.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
ok() { echo "ok: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail + 1)); }

# fixture <name> — fresh HOME + project, echoes nothing; sets FX_HOME / FX_PROJ.
fixture() {
  FX_HOME="$work/$1/home"
  FX_PROJ="$work/$1/proj"
  mkdir -p "$FX_HOME/.claude/plugins" "$FX_PROJ/.claude"
  echo '{"version":2,"plugins":{}}' > "$FX_HOME/.claude/plugins/installed_plugins.json"
}

# add_plugin <key> <hooks-json-file|-> — register an installed plugin under the fixture HOME.
add_plugin() {
  local key=$1 hooks=$2 name=${1%@*} dir
  dir="$FX_HOME/.claude/plugins/cache/${1#*@}/$name/1.0.0"
  mkdir -p "$dir/hooks"
  [ "$hooks" = "-" ] || cp "$hooks" "$dir/hooks/hooks.json"
  local tmp="$FX_HOME/.claude/plugins/installed_plugins.json"
  jq --arg k "$key" --arg p "$dir" \
    '.plugins[$k] = ((.plugins[$k] // []) + [{scope:"user",installPath:$p}])' "$tmp" > "$tmp.new" && mv "$tmp.new" "$tmp"
}

hook_settings() { # <event> <matcher> <command>
  jq -n --arg e "$1" --arg m "$2" --arg c "$3" \
    '{hooks:{($e):[{matcher:$m,hooks:[{type:"command",command:$c}]}]}}'
}

run_scan() { HOME="$FX_HOME" bash "$scan" "$FX_PROJ" 2>&1; }

# ── row 1: a clean fixture prints one clean line ─────────────────────────────
fixture clean
hook_settings PreToolUse Bash 'bash "$CLAUDE_PROJECT_DIR/scripts/hooks/one.sh"' > "$FX_HOME/.claude/settings.json"
out=$(run_scan)
if [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] && printf '%s' "$out" | grep -qi 'clean'; then
  ok "row 1: clean fixture prints one clean line"
else bad "row 1: expected one clean line, got: $out"; fi

# ── row 2: the same hook command in user and project settings is flagged ─────
fixture dup-hook
cmd='bash "$CLAUDE_PROJECT_DIR/scripts/hooks/dup-me.sh"'
hook_settings PreToolUse Bash "$cmd" > "$FX_HOME/.claude/settings.json"
hook_settings PreToolUse Bash "$cmd" > "$FX_PROJ/.claude/settings.json"
out=$(run_scan)
if printf '%s' "$out" | grep -q 'dup-me.sh' && printf '%s' "$out" | grep -q "$FX_HOME/.claude/settings.json" \
   && printf '%s' "$out" | grep -q "$FX_PROJ/.claude/settings.json" && printf '%s' "$out" | grep -qi 'fix'; then
  ok "row 2: duplicated hook names both copies and a fix"
else bad "row 2: duplicated hook not reported, got: $out"; fi

# ── row 3: real himmel-guard shape — harness stanza + enabled plugin hooks ───
fixture guard
if [ -f "$guard_hooks" ] && [ -f "$harness_settings" ]; then
  jq '{hooks:{PreToolUse:[.hooks.PreToolUse[] | select(any(.hooks[]?; .command | test("block-destructive-commands")))]}}' \
    "$harness_settings" > "$FX_PROJ/.claude/settings.json"
  add_plugin himmel-guard@himmel "$guard_hooks"
  echo '{"enabledPlugins":{"himmel-guard@himmel":true}}' > "$FX_HOME/.claude/settings.json"
  out=$(run_scan)
  if printf '%s' "$out" | grep -q 'block-destructive-commands.sh' && printf '%s' "$out" | grep -q 'himmel-guard@himmel' \
     && printf '%s' "$out" | grep -q "$FX_PROJ/.claude/settings.json"; then
    ok "row 3: himmel-guard wired by harness AND plugin is flagged"
  else bad "row 3: guard duplicate not reported, got: $out"; fi
else bad "row 3: real himmel-guard hooks.json or harness settings missing from the checkout"; fi

# ── row 4: the same plugin enabled at user and project scope ─────────────────
fixture two-scopes
echo '{"enabledPlugins":{"handover@himmel":true}}' > "$FX_HOME/.claude/settings.json"
echo '{"enabledPlugins":{"handover@himmel":true}}' > "$FX_PROJ/.claude/settings.json"
out=$(run_scan)
if printf '%s' "$out" | grep -q 'handover@himmel' && printf '%s' "$out" | grep -qi 'scope'; then
  ok "row 4: plugin enabled at two scopes is flagged"
else bad "row 4: two-scope plugin not reported, got: $out"; fi

# ── row 5: the same plugin enabled under two marketplaces ────────────────────
fixture two-markets
echo '{"enabledPlugins":{"claude-obsidian@himmel":true,"claude-obsidian@luna-brain":true}}' > "$FX_HOME/.claude/settings.json"
out=$(run_scan)
if printf '%s' "$out" | grep -q 'claude-obsidian@himmel' && printf '%s' "$out" | grep -q 'claude-obsidian@luna-brain' \
   && printf '%s' "$out" | grep -qi 'marketplace'; then
  ok "row 5: plugin under two marketplaces is flagged"
else bad "row 5: two-marketplace plugin not reported, got: $out"; fi

# ── row 6: leftover pre-1.1.3 keys ───────────────────────────────────────────
fixture leftover
echo '{"enabledPlugins":{"caveman@caveman":true},"hooks":{"SessionEnd":[{"hooks":[{"type":"command","command":"bash \"<himmel-path>/scripts/hooks/end-session-wiki.sh\""}]}]}}' > "$FX_HOME/.claude/settings.json"
out=$(run_scan)
if printf '%s' "$out" | grep -q 'caveman@caveman' && printf '%s' "$out" | grep -q '<himmel-path>'; then
  ok "row 6: retired plugin key and unsubstituted placeholder are flagged"
else bad "row 6: leftover keys not reported, got: $out"; fi

# ── row 7: disabled plugin, and two plugins sharing a script name, are clean ─
fixture not-dups
echo '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash \"${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh\""}]}]}}' > "$work/shared-hooks.json"
add_plugin alpha@mkt "$work/shared-hooks.json"
add_plugin beta@mkt "$work/shared-hooks.json"
add_plugin gamma@mkt "$work/shared-hooks.json"
echo '{"enabledPlugins":{"alpha@mkt":true,"beta@mkt":true,"gamma@mkt":false}}' > "$FX_HOME/.claude/settings.json"
out=$(run_scan)
if printf '%s' "$out" | grep -qi 'clean' && ! printf '%s' "$out" | grep -q 'session-start.sh'; then
  ok "row 7: disabled plugin and plugin-vs-plugin shared basename are not flagged"
else bad "row 7: false positive, got: $out"; fi

# ── row 8: the scan writes nothing (fixture checksum before == after) ────────
fixture ro
hook_settings PreToolUse Bash "$cmd" > "$FX_HOME/.claude/settings.json"
hook_settings PreToolUse Bash "$cmd" > "$FX_PROJ/.claude/settings.json"
snap() { (cd "$work/ro" && find . -type f -exec sha256sum {} + | sort; find . | sort); }
before=$(snap)
ro_out=$(run_scan); ro_rc=$?
after=$(snap)
if [ "$ro_rc" -eq 0 ] && [ -n "$ro_out" ] && [ "$before" = "$after" ]; then ok "row 8: scan left the fixture byte-identical"
else bad "row 8: scan changed the fixture"; fi

# ── row 9: plugin install path containing a space is still scanned ──────────
fixture "sp ace"
cp "$guard_hooks" "$work/guard-hooks.json"
add_plugin himmel-guard@himmel "$work/guard-hooks.json"
jq '{hooks:{PreToolUse:[.hooks.PreToolUse[0]]}}' "$work/guard-hooks.json" > "$FX_PROJ/.claude/settings.json"
echo '{"enabledPlugins":{"himmel-guard@himmel":true}}' > "$FX_HOME/.claude/settings.json"
out=$(run_scan)
if printf '%s' "$out" | grep -q 'block-destructive-commands.sh'; then ok "row 9: plugin under a path with a space is scanned"
else bad "row 9: spaced install path skipped, got: $out"; fi

# ── row 10: the same script twice inside ONE matcher group is flagged ────────
fixture same-group
jq -n '{hooks:{PreToolUse:[{matcher:"Bash",hooks:[{type:"command",command:"bash x/twice.sh"},{type:"command",command:"bash y/twice.sh"}]}]}}' > "$FX_HOME/.claude/settings.json"
out=$(run_scan)
if printf '%s' "$out" | grep -q 'twice.sh'; then ok "row 10: duplicate inside one matcher group is flagged"
else bad "row 10: same-group duplicate missed, got: $out"; fi

# ── row 11: the same script under disjoint matchers is not a duplicate ───────
fixture disjoint
hook_settings PreToolUse Bash 'bash "$CLAUDE_PROJECT_DIR/scripts/hooks/guard.sh"' > "$FX_HOME/.claude/settings.json"
hook_settings PreToolUse Read 'bash "$CLAUDE_PROJECT_DIR/scripts/hooks/guard.sh"' > "$FX_PROJ/.claude/settings.json"
out=$(run_scan)
if printf '%s' "$out" | grep -qi 'clean'; then ok "row 11: disjoint matchers are not flagged"
else bad "row 11: false positive on disjoint matchers, got: $out"; fi

# ── row 12: a regex matcher overlaps a literal one ───────────────────────────
fixture regex-matcher
hook_settings PreToolUse '.*' 'bash "$CLAUDE_PROJECT_DIR/scripts/hooks/rx.sh"' > "$FX_HOME/.claude/settings.json"
hook_settings PreToolUse Bash 'bash "$CLAUDE_PROJECT_DIR/scripts/hooks/rx.sh"' > "$FX_PROJ/.claude/settings.json"
out=$(run_scan)
if printf '%s' "$out" | grep -q 'rx.sh'; then ok "row 12: regex matcher overlapping a literal one is flagged"
else bad "row 12: regex-matcher overlap missed, got: $out"; fi

# ── row 13: a same-file duplicate is reported even when another source has a disjoint matcher
fixture intra-plus-disjoint
jq -n '{hooks:{PreToolUse:[{matcher:"Bash",hooks:[{type:"command",command:"bash x/same2.sh"}]},{matcher:"Bash",hooks:[{type:"command",command:"bash y/same2.sh"}]}]}}' > "$FX_HOME/.claude/settings.json"
hook_settings PreToolUse Read 'bash "$CLAUDE_PROJECT_DIR/scripts/hooks/same2.sh"' > "$FX_PROJ/.claude/settings.json"
out=$(run_scan)
if printf '%s' "$out" | grep -q 'same2.sh'; then ok "row 13: same-file duplicate is flagged beside a disjoint-matcher copy"
else bad "row 13: same-file duplicate suppressed, got: $out"; fi

# ── row 14: a relative project argument still matches a project-scoped plugin ─
fixture relproj
cp "$guard_hooks" "$work/guard-hooks-rel.json"
add_plugin himmel-guard@himmel "$work/guard-hooks-rel.json"
jq --arg p "$FX_PROJ" '.plugins["himmel-guard@himmel"][0].projectPath = $p' "$FX_HOME/.claude/plugins/installed_plugins.json" \
  > "$work/ip.new" && mv "$work/ip.new" "$FX_HOME/.claude/plugins/installed_plugins.json"
jq '{hooks:{PreToolUse:[.hooks.PreToolUse[0]]}}' "$work/guard-hooks-rel.json" > "$FX_PROJ/.claude/settings.json"
echo '{"enabledPlugins":{"himmel-guard@himmel":true}}' > "$FX_HOME/.claude/settings.json"
out=$(cd "$FX_PROJ" && HOME="$FX_HOME" bash "$scan" . 2>&1)
if printf '%s' "$out" | grep -q 'block-destructive-commands.sh'; then ok "row 14: relative project path still finds the project-scoped plugin"
else bad "row 14: relative project path missed the plugin, got: $out"; fi

# ── row 15: an unparsable settings file is never reported as clean ───────────
fixture corrupt
echo '{not json' > "$FX_HOME/.claude/settings.json"
out=$(run_scan)
if printf '%s' "$out" | grep -q 'incomplete' && ! printf '%s' "$out" | grep -q 'scan-duplicates: clean'; then ok "row 15: unparsable settings file reads incomplete, not clean"
else bad "row 15: corrupt settings reported clean, got: $out"; fi

# ── row 16: an unparsable enabled-plugin hooks.json is never reported as clean
fixture corrupt-plugin
echo '{not json' > "$work/bad-hooks.json"
add_plugin alpha@mkt "$work/bad-hooks.json"
echo '{"enabledPlugins":{"alpha@mkt":true}}' > "$FX_HOME/.claude/settings.json"
out=$(run_scan)
if printf '%s' "$out" | grep -q 'incomplete'; then ok "row 16: unparsable plugin hooks.json reads incomplete, not clean"
else bad "row 16: corrupt plugin hooks.json reported clean, got: $out"; fi

# ── row 17: valid JSON with the wrong structure is never reported as clean ───
fixture bad-shape
echo '{"hooks":[]}' > "$FX_HOME/.claude/settings.json"
out=$(run_scan)
if printf '%s' "$out" | grep -q 'incomplete' && ! printf '%s' "$out" | grep -q 'scan-duplicates: clean'; then ok "row 17: structurally invalid settings read incomplete, not clean"
else bad "row 17: bad-shape settings reported clean, got: $out"; fi

# ── row 18: one file wiring a script under overlapping but different matchers
fixture same-file-overlap
jq -n '{hooks:{PreToolUse:[{matcher:"Bash",hooks:[{type:"command",command:"bash x/ovl.sh"}]},{matcher:".*",hooks:[{type:"command",command:"bash x/ovl.sh"}]}]}}' > "$FX_HOME/.claude/settings.json"
out=$(run_scan)
if printf '%s' "$out" | grep -q 'ovl.sh'; then ok "row 18: same-file overlapping matchers are flagged"
else bad "row 18: same-file overlapping matchers missed, got: $out"; fi

# ── row 19: a grouped alternation matcher is one regex, not split on its pipe
fixture grouped-alt
hook_settings PreToolUse '(Bash|Read)' 'bash "$CLAUDE_PROJECT_DIR/scripts/hooks/alt.sh"' > "$FX_HOME/.claude/settings.json"
hook_settings PreToolUse Read 'bash "$CLAUDE_PROJECT_DIR/scripts/hooks/alt.sh"' > "$FX_PROJ/.claude/settings.json"
out=$(run_scan)
hook_settings PreToolUse Write 'bash "$CLAUDE_PROJECT_DIR/scripts/hooks/alt.sh"' > "$FX_PROJ/.claude/settings.json"
out2=$(run_scan)
if printf '%s' "$out" | grep -q 'alt.sh' && printf '%s' "$out2" | grep -q 'scan-duplicates: clean'; then ok "row 19: grouped alternation matcher overlaps Read, not Write"
else bad "row 19: grouped alternation mishandled, got: $out / $out2"; fi

echo "$(basename "$0"): $pass passed, $fail failed"
[ "$fail" -eq 0 ]
