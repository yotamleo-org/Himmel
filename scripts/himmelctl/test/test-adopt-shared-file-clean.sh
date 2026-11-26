#!/usr/bin/env bash
# shellcheck disable=SC2015
# test-adopt-shared-file-clean.sh - given scopes, slice S2b-1: a project adopt keeps
# station items out of the shared, committed .claude/settings.json and .mcp.json. The statusLine,
# the clone-path hooks, himmel's marketplace entry and the graphify server go to the gitignored
# local file or the on-demand registry; the shared file keeps the guard chain, the merge gate and
# the plugin floor ids. HOME, the Claude config dir, the station list and the registry live under
# mktemp -d; the claude CLI is a stub that writes the settings files the real one writes.
set -uo pipefail

W=$(cd "$(dirname "$0")/../../.." && pwd) || exit 1
. "$W/scripts/himmelctl/test/_hermetic-home.sh"
. "$W/scripts/lib/hermetic-path.sh"
. "$W/scripts/lib/canon-path.sh"
LGP="$W/scripts/lib/launch-guard-p.mjs"
adopt="$W/scripts/adopt.sh"
wizard="$W/scripts/himmelctl/bin.js"
fixture_dir="$W/scripts/himmelctl/test/fixtures/adopt-shared-file-clean"
template="$W/docs/setup/settings-template.json"

fails=0
pass() { echo "ok - $1"; }
fail() { echo "FAIL - $1${2:+: $2}"; fails=$((fails+1)); }
die() { echo "FAIL: $1" >&2; exit 1; }

command -v node >/dev/null 2>&1 || die "node required"
command -v jq >/dev/null 2>&1 || die "jq required"
node_bin=$(command -v node)

work_raw=$(mktemp -d "${TMPDIR:-/tmp}/adopt-shared-clean.XXXXXX") || die "mktemp"
trap 'rm -rf "$work_raw"' EXIT
work=$(canon_path_native "$work_raw") || die "canon $work_raw"

export HOME="$work/home"
mkdir -p "$HOME/.claude" || die "mkdir $HOME"
export USERPROFILE="$HOME"
export CLAUDE_CONFIG_DIR="$HOME/.claude"
export HIMMELCTL_CACHE_DIR="$HOME/.claude/himmel"
export HIMMEL_LUNA_CONFIG_PATH="$work/luna-config.json"
export HIMMEL_PROVENANCE_DIR="$work/prov"
export HIMMEL_MCP_ONDEMAND_FILE="$work/mcp-on-demand.json"
export HIMMELCTL_INTERACTIVE=0
export HIMMELCTL_UI_HANDOFF=0
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
unset HIMMEL_REPO HANDOVER_DIR HIMMELCTL_REPO_ROOT LUNA_VAULT_PATH CLAUDE_USER_SETTINGS
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
git config --global user.name t
git config --global user.email t@example.invalid
git config --global init.defaultBranch main
printf '{}\n' > "$CLAUDE_CONFIG_DIR/settings.json"

core_bin="$work/core-bin"; node_dir="$work/node-bin"; stub_bin="$work/graphify-bin"
build_hermetic_bin "$core_bin" bash git jq python3 grep sed cat cp mv rm ln mkdir chmod diff wc tr head tail \
  basename dirname mktemp dd sort cut xargs date stat uname id awk cmp find env touch ls readlink realpath tee \
  "$(command -v sha256sum >/dev/null 2>&1 && echo sha256sum || echo shasum)" || die "build_hermetic_bin"
mkdir -p "$node_dir" "$stub_bin" && ln -s "$node_bin" "$node_dir/node" || die "link node"
cat > "$core_bin/claude" <<'STUB' || die "claude stub"
#!/usr/bin/env bash
tpl="$STUB_TEMPLATE"
cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
file_for() { case "$1" in user) echo "$cfg/settings.json" ;; project) echo "$PWD/.claude/settings.json" ;; local) echo "$PWD/.claude/settings.local.json" ;; esac; }
upd() { local f="$1"; shift; mkdir -p "$(dirname "$f")"; [ -s "$f" ] || echo '{}' > "$f"; jq "$@" "$f" > "$f.stub.tmp" && mv "$f.stub.tmp" "$f"; }
scope=user
for ((i = 1; i <= $#; i++)); do [ "${!i}" = "--scope" ] && { j=$((i + 1)); scope="${!j}"; }; done
if [ "$1" = plugin ] && [ "$2" = list ]; then jq -r '.enabledPlugins | keys[]' "$tpl"; exit 0; fi
if [ "$1" = plugin ] && [ "$2" = install ]; then upd "$(file_for "$scope")" --arg s "$3" '.enabledPlugins[$s] = true'; exit 0; fi
if [ "$1" = plugin ] && [ "$2" = marketplace ] && [ "$3" = add ]; then
  entry=$(sed "s|<himmel-path>|$STUB_HIMMEL|g" "$tpl" | jq -c --arg src "$4" '.extraKnownMarketplaces | to_entries[] | select((.value.source.repo // .value.source.path // .value.source.url) == $src) | {(.key): {source: .value.source}}')
  [ -n "$entry" ] && upd "$(file_for "$scope")" --argjson e "$entry" '.extraKnownMarketplaces = ((.extraKnownMarketplaces // {}) + $e)'
  exit 0
fi
exit 0
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$core_bin/npm"
printf '#!/usr/bin/env bash\nexit 0\n' > "$stub_bin/graphify"
printf '#!/usr/bin/env bash\nexit 0\n' > "$stub_bin/graphify-mcp"
chmod +x "$core_bin/claude" "$core_bin/npm" "$stub_bin/graphify" "$stub_bin/graphify-mcp" || die "chmod"
rest_path=$(scrub_path "$PATH" node npm bun qmd uv pipx pre-commit graphify claude)
export PATH="$node_dir:$core_bin:$rest_path"
export STUB_TEMPLATE="$template" STUB_HIMMEL="$W"
hermetic_path_excludes "$core_bin:$rest_path" node bun qmd || die "hermetic PATH leaks node, bun or qmd"

noclaude=(env -u CLAUDECODE)
for v in $(compgen -e); do
  case "$v" in CLAUDE_CODE_*) noclaude+=(-u "$v") ;; esac
done

new_repo() {
  mkdir -p "$1" && git -C "$1" init -q && git -C "$1" commit -q --allow-empty -m init || die "repo $1"
}
adopt_into() {
  local d="$1"; shift
  ( cd "$d" && "${noclaude[@]}" bash "$adopt" --scope project --target "$d" "$@" ) > "$work/adopt.log" 2>&1 \
    || { cat "$work/adopt.log" >&2; die "adopt.sh --scope project into $d failed"; }
}
sha() { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1"; }
floor_ids=$(jq -c '[.enabledPlugins | to_entries[] | select(.value == true) | .key]' "$template")
chain_scripts='["auto-approve-safe-bash","block-edit-on-main","block-read-secrets","block-unresolved-cr-merge"]'

shared_clean() {
  local label="$1" f="$2" got
  jq -e '.statusLine == null' "$f" >/dev/null 2>&1 && pass "$label: no statusLine in the shared file" || fail "$label: no statusLine in the shared file" "$(jq -c .statusLine "$f")"
  jq -e '(.env.CLAUDE_HUD_ALLOW_EXTRA_CMD // null) == null' "$f" >/dev/null 2>&1 && pass "$label: no HUD key in the shared file" || fail "$label: no HUD key in the shared file" "$(jq -c .env "$f")"
  got=$(jq -c '[(.hooks.SessionStart // [])[], (.hooks.SessionEnd // [])[] | .hooks[].command | select(test("inject-initiative|end-session-wiki"))]' "$f")
  [ "$got" = "[]" ] && pass "$label: no clone-path SessionStart or SessionEnd hook in the shared file" || fail "$label: no clone-path SessionStart or SessionEnd hook in the shared file" "$got"
  jq -e '(.extraKnownMarketplaces.himmel // null) == null' "$f" >/dev/null 2>&1 && pass "$label: no himmel marketplace entry in the shared file" || fail "$label: no himmel marketplace entry in the shared file" "$(jq -c .extraKnownMarketplaces.himmel "$f")"
  got=$(jq -c --argjson want "$chain_scripts" '[.hooks.PreToolUse[]?.hooks[].command] as $c | [$want[] | select(. as $n | any($c[]; contains($n + ".sh")))] | length' "$f")
  [ "$got" = "4" ] && pass "$label: the guard chain and merge gate stay" || fail "$label: the guard chain and merge gate stay" "found $got of 4"
  jq -e --argjson ids "$floor_ids" '. as $r | all($ids[]; $r.enabledPlugins[.] == true)' "$f" >/dev/null 2>&1 && pass "$label: the floor ids stay" || fail "$label: the floor ids stay" "$(jq -c '.enabledPlugins | keys' "$f" 2>&1 | head -c 300)"
}
adopted_passes() {
  local err rc
  err=$(node "$LGP" "$W" "$2/.claude/settings.json" --adopted "$2" 2>&1 >/dev/null); rc=$?
  [ "$rc" = 0 ] && pass "$1: launch-guard-p --adopted passes" || fail "$1: launch-guard-p --adopted passes" "rc=$rc $err"
}

user_file="$CLAUDE_CONFIG_DIR/settings.json"

S1="$work/fresh"; new_repo "$S1"
user_before=$(sha "$user_file")
adopt_into "$S1" --profile core
SH="$S1/.claude/settings.json"; LO="$S1/.claude/settings.local.json"
shared_clean "one" "$SH"
jq -e '(.env.HIMMEL_REPO // null) == null' "$SH" >/dev/null 2>&1 && pass "one: no env.HIMMEL_REPO in the shared file" || fail "one: no env.HIMMEL_REPO in the shared file" "$(jq -c .env "$SH")"
adopted_passes "one" "$S1"
jq -e '.statusLine.command | test("claude-hud/dist/index.js")' "$LO" >/dev/null 2>&1 && pass "one: the local file has the statusLine" || fail "one: the local file has the statusLine" "$(jq -c .statusLine "$LO" 2>&1)"
jq -e '.env.CLAUDE_HUD_ALLOW_EXTRA_CMD == "1"' "$LO" >/dev/null 2>&1 && pass "one: the local file has the HUD key" || fail "one: the local file has the HUD key"
jq -e '.extraKnownMarketplaces.himmel.source.source == "directory"' "$LO" >/dev/null 2>&1 && pass "one: the local file has himmel's marketplace entry" || fail "one: the local file has himmel's marketplace entry" "$(jq -c .extraKnownMarketplaces "$LO" 2>&1)"
jq -e '[.hooks.SessionStart[]?.hooks[].command | select(test("inject-initiative"))] | length == 1' "$LO" >/dev/null 2>&1 && pass "one: the local file has the SessionStart hook" || fail "one: the local file has the SessionStart hook"
jq -e '(.enabledPlugins // null) == null' "$LO" >/dev/null 2>&1 && pass "one: the local file has no enabledPlugins" || fail "one: the local file has no enabledPlugins"
git -C "$S1" check-ignore -q .claude/settings.local.json && pass "one: the local file is gitignored" || fail "one: the local file is gitignored"
[ "$(sha "$user_file")" = "$user_before" ] && pass "one: the user file is byte-identical" || fail "one: the user file is byte-identical"

jq -e '(.enabledPlugins // null) == null' "$user_file" >/dev/null 2>&1 && pass "guard: the sandbox user file gained no enabledPlugins key" || fail "guard: the sandbox user file gained no enabledPlugins key" "$(jq -c .enabledPlugins "$user_file")"
cat > "$user_file" <<JSON
{
  "enabledPlugins": {
    "himmel-ops@himmel": true,
    "hand-enabled@thirdparty": true
  },
  "extraKnownMarketplaces": {
    "himmel": {
      "source": {
        "source": "directory",
        "path": "$W/marketplace"
      }
    }
  }
}
JSON
user_seeded=$(sha "$user_file")
S1b="$work/seeded"; new_repo "$S1b"
adopt_into "$S1b" --profile core
[ "$(sha "$user_file")" = "$user_seeded" ] && pass "guard: a seeded user file (himmel-ops, himmel's marketplace, a third-party plugin) is byte-identical after the adopt" || fail "guard: a seeded user file is byte-identical after the adopt" "$(jq -c . "$user_file")"
printf '{}\n' > "$user_file"

fx="$fixture_dir/main-adopt-all.settings.json"
[ -s "$fx" ] || die "case two fixture missing: $fx"
fxok=1
jq -e '.statusLine.command | test("claude-hud/dist/index.js")' "$fx" >/dev/null || { fxok=0; fail "two: the fixture carries the statusLine"; }
jq -e '.env.CLAUDE_HUD_ALLOW_EXTRA_CMD == "1"' "$fx" >/dev/null || { fxok=0; fail "two: the fixture carries the HUD key"; }
jq -e '[.hooks.SessionStart[]?.hooks[].command | select(test("inject-initiative"))] | length == 1' "$fx" >/dev/null || { fxok=0; fail "two: the fixture carries the SessionStart hook"; }
jq -e '[.hooks.SessionEnd[]?.hooks[].command | select(test("end-session-wiki"))] | length == 1' "$fx" >/dev/null || { fxok=0; fail "two: the fixture carries the SessionEnd hook"; }
jq -e '.extraKnownMarketplaces.himmel.source.source == "directory"' "$fx" >/dev/null || { fxok=0; fail "two: the fixture carries himmel's marketplace entry"; }
jq -e --argjson ids "$floor_ids" '. as $r | all($ids[]; $r.enabledPlugins[.] == true)' "$fx" >/dev/null || { fxok=0; fail "two: the fixture carries the floor ids"; }
jq -e --argjson want "$chain_scripts" '[.hooks.PreToolUse[]?.hooks[].command] as $c | all($want[]; . as $n | any($c[]; contains($n + ".sh")))' "$fx" >/dev/null || { fxok=0; fail "two: the fixture carries the guard chain and merge gate"; }
jq -e '(.env.HANDOVER_DIR // "") != ""' "$fx" >/dev/null || { fxok=0; fail "two: the fixture was written with HANDOVER_DIR wired"; }
[ "$fxok" = 1 ] && pass "two: the fixture carries the statusLine, the HUD key, both clone-path hooks, himmel's marketplace entry, the floor ids and the guard chain"
S2="$work/old"; new_repo "$S2"; mkdir -p "$S2/.claude"
sed "s|/opt/himmel|$W|g" "$fx" > "$S2/.claude/settings.json"
adopt_into "$S2" --profile all --luna-target "$work/vault"
shared_clean "two" "$S2/.claude/settings.json"
adopted_passes "two" "$S2"
jq -e '[.hooks.SessionEnd[]?.hooks[].command | select(test("end-session-wiki"))] | length == 1' "$S2/.claude/settings.local.json" >/dev/null 2>&1 && pass "two: the local file carries the SessionEnd hook" || fail "two: the local file carries the SessionEnd hook"

S3="$work/mcp"; new_repo "$S3"
printf '{\n  "mcpServers": {\n    "graphify": {\n      "type": "stdio",\n      "command": "graphify-mcp",\n      "args": [],\n      "env": {}\n    },\n    "other": {\n      "type": "stdio",\n      "command": "other-mcp"\n    }\n  }\n}\n' > "$S3/.mcp.json"
adopt_into "$S3" --profile core
jq -e '(.mcpServers.graphify // null) == null' "$S3/.mcp.json" >/dev/null 2>&1 && pass "three: no himmel graphify server in .mcp.json" || fail "three: no himmel graphify server in .mcp.json" "$(cat "$S3/.mcp.json" 2>&1)"
jq -e '.mcpServers.other.command == "other-mcp"' "$S3/.mcp.json" >/dev/null 2>&1 && pass "three: another server in .mcp.json stays" || fail "three: another server in .mcp.json stays"

S3b="$work/graph"; new_repo "$S3b"
rm -f "$HIMMEL_MCP_ONDEMAND_FILE"
( cd "$S3b" && "${noclaude[@]}" PATH="$stub_bin:$PATH" bash "$adopt" --scope project --target "$S3b" --profile all --luna-target "$work/vault3b" --with-graphify ) > "$work/adopt3b.log" 2>&1 \
  || { cat "$work/adopt3b.log" >&2; die "adopt.sh --with-graphify into $S3b failed"; }
[ ! -e "$S3b/.mcp.json" ] || jq -e '(.mcpServers.graphify // null) == null' "$S3b/.mcp.json" >/dev/null 2>&1 && pass "three b: .mcp.json has no graphify server" || fail "three b: .mcp.json has no graphify server" "$(cat "$S3b/.mcp.json" 2>&1)"
jq -e '.mcpServers.graphify.command | test("graphify-mcp$")' "$HIMMEL_MCP_ONDEMAND_FILE" >/dev/null 2>&1 && pass "three b: the on-demand file holds mcpServers.graphify" || fail "three b: the on-demand file holds mcpServers.graphify" "$(cat "$HIMMEL_MCP_ONDEMAND_FILE" 2>&1)"
listed=$(cd "$S3b" && node "$wizard" projects --json 2>&1 | jq -c --arg p "$S3b" '[.projects[] | select(.path == $p) | .items[]] | index("graphify-mcp") != null')
[ "$listed" = "true" ] && pass "three b: the list entry records graphify-mcp" || fail "three b: the list entry records graphify-mcp" "$listed"

cp "$W/docs/setup/profiles/adopter-project.install-profile.json" "$HIMMELCTL_CACHE_DIR/install-profile.json" || die "cp install profile"
state_file="$HIMMELCTL_CACHE_DIR/state.json"
jq --arg k "$S3b" '.targets[$k] = {profile:"all",scope:"project",items:{"wiring-statusline":{enabled:true,overrides:{}},"graphify-mcp":{enabled:true,overrides:{}}},lastEnsured:null}' "$state_file" > "$work/state.tmp" \
  && mv "$work/state.tmp" "$state_file" || die "cannot seed targets[$S3b]"
sh_before=$(sha "$S3b/.claude/settings.json"); mcp_before=$( [ -e "$S3b/.mcp.json" ] && sha "$S3b/.mcp.json" || echo none )
( cd "$S3b" && "${noclaude[@]}" PATH="$stub_bin:$PATH" node "$wizard" ensure --profile all --items wiring-statusline,graphify-mcp --yes --no-network </dev/null ) > "$work/ensure4.log" 2>&1
( cd "$S3b" && "${noclaude[@]}" PATH="$stub_bin:$PATH" node "$wizard" status --items wiring-statusline,graphify-mcp --json ) > "$work/status4.json" 2> "$work/status4.err"
[ "$(sha "$S3b/.claude/settings.json")" = "$sh_before" ] && pass "four: ensure and status leave the shared file byte-identical" || fail "four: ensure and status leave the shared file byte-identical"
[ "$( [ -e "$S3b/.mcp.json" ] && sha "$S3b/.mcp.json" || echo none )" = "$mcp_before" ] && pass "four: ensure and status leave .mcp.json as it was" || fail "four: ensure and status leave .mcp.json as it was"
for id in wiring-statusline graphify-mcp; do
  st=$(jq -r --arg id "$id" '[.items[]? | select(.id == $id) | .actual] | first // "missing"' "$work/status4.json" 2>/dev/null)
  [ "$st" = present ] && pass "four: $id reports green ($st)" || fail "four: $id reports green" "got $st; $(head -c 300 "$work/status4.err") $(head -c 300 "$work/ensure4.log") $(jq -c '[.items[] | {id, desired, actual}]' "$work/status4.json" 2>&1 | head -c 400)"
done

echo
[ "$fails" -eq 0 ] && echo "all ok" || { echo "$fails check(s) failed"; exit 1; }
