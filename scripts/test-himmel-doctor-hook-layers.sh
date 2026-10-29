#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # A && B || C is the pass/fail idiom; the planted hooks.json keeps a literal ${CLAUDE_PLUGIN_ROOT}
# test-himmel-doctor-hook-layers.sh — each guard hook runs once per call.
#   1. doctor C81-hook-layers WARNs when one hook script is wired from two layers
#      (user settings, project settings, an enabled plugin) and stays OK for a skip-aware
#      user entry (guardrail-skip-in-himmel.js) or a skip-aware plugin entry.
#   2. himmelctl still wires the trio at user scope when the user layer has no trio, even if
#      the project layer wires it; the probe reads a self-skipping user entry as present.
#   3. the himmel-guard plugin command exits 0 without running when the project layer wires
#      block-destructive-commands, and still runs it otherwise.
# Every fixture lives under a temp dir; the real HOME and settings are never read.
# Run: bash scripts/test-himmel-doctor-hook-layers.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOC="$ROOT/scripts/himmel-doctor.sh"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3' in: $2)" ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/doctor-hook-layers-test.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT

# A himmel-shaped project root: real scripts/ (symlink), fixture .claude/settings.json.
PROJ="$WORK/root"
mkdir -p "$PROJ/.claude" "$WORK/home" "$WORK/claude"
ln -s "$ROOT/scripts" "$PROJ/scripts"
cat > "$PROJ/.claude/settings.json" <<'JSON'
{"hooks":{
 "PreToolUse":[
  {"matcher":"Bash","hooks":[{"type":"command","command":"bash \"$CLAUDE_PROJECT_DIR/scripts/hooks/auto-approve-safe-bash.sh\" \"$CLAUDE_PROJECT_DIR/scripts/hooks/block-read-secrets.sh\" \"$CLAUDE_PROJECT_DIR/scripts/hooks/block-destructive-commands.sh\""}]},
  {"matcher":"Edit|Write","hooks":[{"type":"command","command":"bash \"$CLAUDE_PROJECT_DIR/scripts/hooks/block-edit-on-main.sh\""}]}],
 "SessionStart":[{"hooks":[{"type":"command","command":"bash \"$CLAUDE_PROJECT_DIR/scripts/hooks/inject-initiative.sh\""}]}]}}
JSON

# --- doctor C81 ---------------------------------------------------------------------------
raw_cmd() { printf 'if [ -f "/x/scripts/hooks/%s" ]; then bash "/x/scripts/hooks/%s"; else exit 0; fi' "$1" "$1"; }
user_settings() { # <body of the hooks object>; plugins stay as planted by the caller
    printf '{"hooks":%s%s}' "$1" "${2:-}" > "$WORK/claude/settings.json"
}
doctor() { HOME="$WORK/home" CLAUDE_DIR="$WORK/claude" bash "$DOC" --root "$PROJ" --only C81 --no-color 2>&1; }

echo "== C81: one script wired from user AND project -> WARN naming it =="
user_settings "$(jq -cn --arg c "$(raw_cmd auto-approve-safe-bash.sh)" '{PreToolUse:[{matcher:"Bash",hooks:[{type:"command",command:$c}]}]}')"
out="$(doctor)"; rc=$?
has "C81 two layers -> WARN row" "$out" "WARN C81-hook-layers"
has "C81 names the script" "$out" "auto-approve-safe-bash.sh"
has "C81 names both layers" "$out" "user"
has "C81 names the project layer" "$out" "project"

echo "== C81: SessionStart script wired from both layers -> WARN =="
user_settings "$(jq -cn --arg c "$(raw_cmd inject-initiative.sh)" '{SessionStart:[{hooks:[{type:"command",command:$c}]}]}')"
out="$(doctor)"
has "C81 inject-initiative doubled -> WARN" "$out" "WARN C81-hook-layers"
has "C81 names inject-initiative.sh" "$out" "inject-initiative.sh"

echo "== C81: user layer carries nothing the project wires -> OK =="
user_settings '{}'
out="$(doctor)"
has "C81 single layer -> OK" "$out" "OK   C81-hook-layers"

echo "== C81: skip-aware user entry (guardrail-skip-in-himmel.js) is not a duplicate =="
user_settings "$(jq -cn '{PreToolUse:[{matcher:"Bash",hooks:[{type:"command",command:"node \"/x/scripts/hooks/guardrail-skip-in-himmel.js\" \"/x/scripts/hooks/auto-approve-safe-bash.sh\""}]}]}')"
out="$(doctor)"
has "C81 wrapped user entry -> OK" "$out" "OK   C81-hook-layers"

echo "== C81: enabled plugin wiring a script the project wires -> WARN; guarded plugin -> OK =="
PLUG="$WORK/claude/plugins/cache/himmel/himmel-guard/0.1.5/hooks"
mkdir -p "$PLUG"
printf '{"hooks":{"PreToolUse":[{"matcher":"Bash|PowerShell","hooks":[{"type":"command","command":"bash \\"${CLAUDE_PLUGIN_ROOT}/hooks/block-destructive-commands.sh\\"","timeout":15}]}]}}\n' > "$PLUG/hooks.json"
user_settings '{}' ',"enabledPlugins":{"himmel-guard@himmel":true}'
out="$(doctor)"
has "C81 plugin doubles the project -> WARN" "$out" "WARN C81-hook-layers"
has "C81 names the script" "$out" "block-destructive-commands.sh"
has "C81 names the plugin layer" "$out" "plugin:himmel-guard"
cp "$ROOT/marketplace/plugins/himmel-guard/hooks/hooks.json" "$PLUG/hooks.json"
out="$(doctor)"
has "C81 shipped himmel-guard hooks.json -> OK" "$out" "OK   C81-hook-layers"
user_settings '{}' ',"enabledPlugins":{"himmel-guard@himmel":false}'
printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash \\"${CLAUDE_PLUGIN_ROOT}/hooks/block-destructive-commands.sh\\""}]}]}}\n' > "$PLUG/hooks.json"
out="$(doctor)"
has "C81 disabled plugin is not a layer -> OK" "$out" "OK   C81-hook-layers"
echo "== C81: the WARN prints the guardrail-block-global remedy =="
user_settings "$(jq -cn --arg c "$(raw_cmd block-edit-on-main.sh)" '{PreToolUse:[{matcher:"Edit",hooks:[{type:"command",command:$c}]}]}')"
out="$(doctor)"
has "C81 WARN names guardrail-block-global" "$out" "accept guardrail-block-global"

# --- himmelctl: user-scope install keeps the trio unless a self-skipping owner is there ------
export INSTALL_ENGINE_LIB="$ROOT/scripts/himmelctl/lib/install-engine.js"
export PROBES_LIB="$ROOT/scripts/himmelctl/lib/probes.js"
mkrepo() { # <dir> <with-project-settings 0|1>
    mkdir -p "$1/scripts/lib" "$1/.claude"
    printf '#!/usr/bin/env bash\necho wired > "%s"\nexit 0\n' "$WORK/marker-$(basename "$1")" > "$1/scripts/lib/wire-pretooluse-hooks.sh"
    if [ "$2" = 1 ]; then
        cat > "$1/.claude/settings.json" <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash \"$CLAUDE_PROJECT_DIR/scripts/hooks/auto-approve-safe-bash.sh\" \"$CLAUDE_PROJECT_DIR/scripts/hooks/block-read-secrets.sh\""}]},{"matcher":"Edit","hooks":[{"type":"command","command":"bash \"$CLAUDE_PROJECT_DIR/scripts/hooks/block-edit-on-main.sh\""}]}]}}
JSON
    fi
}
mkrepo "$WORK/repo-owned" 1
mkrepo "$WORK/repo-bare" 0
mkdir -p "$WORK/uhome/.claude"; echo '{}' > "$WORK/uhome/.claude/settings.json"
install_run() { # <repo>
    REPO="$1" UHOME="$WORK/uhome" node -e "
const { planInstall, runInstall } = require(process.env.INSTALL_ENGINE_LIB);
const items = [{ id: 'wiring-pretooluse', deps: [], install: { type: 'wire', target: 'pretooluse-hooks' } }];
const ctx = { repoRoot: process.env.REPO, scope: 'user', profile: 'core', targetPath: process.env.UHOME, env: { HOME: process.env.UHOME } };
const plan = planInstall(items, ctx);
console.log(JSON.stringify({ result: runInstall(plan, { dryRun: false }), plan: plan.map((p) => (p.args || []).join(' ')) }));
" 2>&1
}
echo "== install: user layer has no trio and no guardrail-block-global, project layer wires the trio -> the wire still runs =="
out="$(install_run "$WORK/repo-owned")"
[ -f "$WORK/marker-repo-owned" ] && pass "owned: wire-pretooluse-hooks.sh ran (no unguarded repo)" || fail "owned: the user-level wire was skipped ($out)"
echo "== install: no project entry -> user-scope wire runs =="
out="$(install_run "$WORK/repo-bare")"
[ -f "$WORK/marker-repo-bare" ] && pass "bare: wire-pretooluse-hooks.sh ran" || fail "bare: the wire did not run ($out)"

echo "== probe: a self-skipping user entry reads present, an empty user layer reads absent =="
probe_run() { # <repo>
    REPO="$1" UHOME="$WORK/uhome" node -e "
const { runProbe } = require(process.env.PROBES_LIB);
const item = { id: 'wiring-pretooluse', probe: { type: 'settings-hooks', file: '.claude/settings.json', key: 'hooks.PreToolUse' } };
const r = runProbe(item, { repoRoot: process.env.REPO, scope: 'user', targetPath: process.env.UHOME, env: { HOME: process.env.UHOME } });
console.log(r.actual + ' | ' + r.detail);
" 2>&1
}
out="$(probe_run "$WORK/repo-owned")"
has "probe empty user layer, project wires trio -> absent" "$out" "absent"
wrapped="$(jq -cn '{hooks:{PreToolUse:[
  {matcher:"Bash",hooks:[{type:"command",command:"node \"/x/scripts/hooks/guardrail-skip-in-himmel.js\" \"/x/scripts/hooks/auto-approve-safe-bash.sh\""}]},
  {matcher:"Edit",hooks:[{type:"command",command:"node \"/x/scripts/hooks/guardrail-skip-in-himmel.js\" \"/x/scripts/hooks/block-edit-on-main.sh\""}]},
  {matcher:"Read",hooks:[{type:"command",command:"node \"/x/scripts/hooks/guardrail-skip-in-himmel.js\" \"/x/scripts/hooks/block-read-secrets.sh\""}]}]}}')"
printf '%s\n' "$wrapped" > "$WORK/uhome/.claude/settings.json"
out="$(probe_run "$WORK/repo-owned")"
has "probe guardrail-block-global wrapper -> present" "$out" "present"

# --- himmel-guard plugin command ------------------------------------------------------------
echo "== himmel-guard: command skips when the project layer wires block-destructive-commands =="
PLUGIN_ROOT="$ROOT/marketplace/plugins/himmel-guard"
cmd="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$PLUGIN_ROOT/hooks/hooks.json")"
payload='{"tool_name":"Bash","tool_input":{"command":"rm -rf /"},"cwd":"/tmp"}'
out="$(printf '%s' "$payload" | CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLAUDE_PROJECT_DIR="$PROJ" bash -c "$cmd" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && pass "project owns it -> plugin hook is a no-op (rc 0, no output)" || fail "project owns it -> rc=$rc out=$out"
mkdir -p "$WORK/bare-proj/.claude"; echo '{}' > "$WORK/bare-proj/.claude/settings.json"
out="$(printf '%s' "$payload" | CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLAUDE_PROJECT_DIR="$WORK/bare-proj" bash -c "$cmd" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "no project entry -> plugin hook still refuses (rc 2)" || fail "no project entry -> rc=$rc out=$out"

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failure(s)"; exit 1
