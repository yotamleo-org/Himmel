#!/usr/bin/env bash
set -uo pipefail

repo_root=$(git rev-parse --show-toplevel) || exit 1
. "$repo_root/scripts/himmelctl/test/_hermetic-home.sh"
. "$repo_root/scripts/lib/hermetic-path.sh"
. "$repo_root/scripts/lib/canon-path.sh"
. "$repo_root/scripts/lib/sha256-bin.sh"
wizard="$repo_root/scripts/himmelctl/bin.js"
statejs="$repo_root/scripts/himmelctl/lib/state.js"
adopt="$repo_root/scripts/adopt.sh"
lgc="$repo_root/scripts/lib/launch-guard-check.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }
ok() { echo "ok: $1"; }
sha() { "$_SHA256_CMD" "$1" | cut -d' ' -f1; }

command -v node >/dev/null 2>&1 || fail "node required"
command -v jq >/dev/null 2>&1 || fail "jq required"
[ -n "$_SHA256_CMD" ] || fail "sha256sum or shasum required"
node_bin=$(command -v node)

work_raw=$(mktemp -d -t himmelctl-projects.XXXXXX) || fail "mktemp failed"
trap 'rm -rf "$work_raw"' EXIT
work=$(canon_path_native "$work_raw") || fail "cannot canonicalise $work_raw"

export HOME="$work/home"
mkdir -p "$HOME/.claude" || fail "cannot create $HOME"
export USERPROFILE="$HOME"
export CLAUDE_CONFIG_DIR="$HOME/.claude"
export HIMMELCTL_CACHE_DIR="$work/cache"
export HIMMEL_LUNA_CONFIG_PATH="$work/cache/luna-config.json"
export HIMMEL_PROVENANCE_DIR="$work/prov"
export HIMMELCTL_INTERACTIVE=0
export HIMMELCTL_UI_HANDOFF=0
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
unset HIMMEL_REPO HANDOVER_DIR HIMMELCTL_REPO_ROOT LUNA_VAULT_PATH
git config --global user.name t || fail "git config failed"
git config --global user.email t@example.invalid || fail "git config failed"
git config --global init.defaultBranch main || fail "git config failed"
printf '{"theme":"dark"}\n' > "$HOME/.claude/settings.json"
user_settings_sha=$(sha "$HOME/.claude/settings.json")

core_bin="$work/core-bin"; node_dir="$work/node-bin"
build_hermetic_bin "$core_bin" git jq python3 grep sed cat cp mv rm ln mkdir chmod diff wc tr head tail \
  basename dirname mktemp dd sort cut xargs date stat uname id awk cmp find env touch ls readlink realpath tee \
  "$(basename "$_SHA256_CMD")" || fail "build_hermetic_bin failed"
mkdir -p "$node_dir" || fail "cannot create $node_dir"
ln -s "$node_bin" "$node_dir/node" || fail "cannot link node"
cat > "$core_bin/claude" <<STUB || fail "cannot write the claude stub"
#!/usr/bin/env bash
if [ "\$1" = "plugin" ] && [ "\$2" = "list" ]; then
  jq -r '.enabledPlugins | keys[]' "$repo_root/docs/setup/settings-template.json"
fi
exit 0
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$core_bin/npm"
chmod +x "$core_bin/claude" "$core_bin/npm" || fail "chmod failed"
rest_path=$(scrub_path "$PATH" node npm bun qmd uv pipx pre-commit graphify claude)
export PATH="$node_dir:$core_bin:$rest_path"
hermetic_path_excludes "$core_bin:$rest_path" node bun qmd || fail "hermetic PATH leaks node, bun or qmd"

noclaude=(env -u CLAUDECODE)
for v in $(compgen -e); do
  case "$v" in CLAUDE_CODE_*) noclaude+=(-u "$v") ;; esac
done

new_repo() {
  mkdir -p "$1" || fail "cannot create $1"
  git -C "$1" init -q || fail "git init $1 failed"
  git -C "$1" commit -q --allow-empty -m init || fail "git commit in $1 failed"
}
projects_json() { ( cd "$1" && node "$wizard" projects --json ); }
state_file="$HIMMELCTL_CACHE_DIR/state.json"
given_items() { jq -c --arg k "$2" '.projects[] | select(.path == $k) | .items' <<< "$1"; }
has_item() { jq -e --arg id "$1" 'index($id) != null' <<< "$2" >/dev/null; }

s1="$work/s1"; new_repo "$s1"
( cd "$s1" && bash "$adopt" --profile core --scope project --target "$s1" ) > "$work/adopt-s1.log" 2>&1 \
  || { cat "$work/adopt-s1.log" >&2; fail "a: adopt.sh --scope project failed"; }
out=$(projects_json "$s1") || fail "a: himmelctl projects --json failed: $out"
items=$(given_items "$out" "$s1")
[ -n "$items" ] || fail "a: projects --json does not list $s1: $out"
for id in wiring-pretooluse wiring-statusline pre-commit-hooks; do
  has_item "$id" "$items" || fail "a: $s1 lacks item $id: $items"
done
has_item graphify-mcp "$items" && fail "a: $s1 lists graphify-mcp, which this adopt did not wire: $items"
[ "$(sha "$HOME/.claude/settings.json")" = "$user_settings_sha" ] || fail "a: the adopt changed the user settings file"
ok "a: adopt.sh --scope project lists $s1 with $items; user settings file unchanged"

fixture="$work/clone"
mkdir -p "$fixture/scripts/lanes" "$fixture/scripts/machine-setup" "$fixture/scripts/install" || fail "cannot create $fixture"
cp "$repo_root/scripts/lanes/lanes.json" "$fixture/scripts/lanes/lanes.json" || fail "cp lanes.json failed"
cp "$repo_root/scripts/install/manifest.json" "$fixture/scripts/install/manifest.json" || fail "cp manifest.json failed"
printf '{ "plugins": [] }\n' > "$fixture/scripts/machine-setup/full-plugin-enable.json"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture/scripts/setup.sh"
cat > "$fixture/scripts/adopt.sh" <<STUB || fail "cannot write the adopt wrapper"
#!/usr/bin/env bash
PATH="$core_bin:$rest_path" exec bash "$adopt" "\$@"
STUB
chmod +x "$fixture/scripts/adopt.sh" "$fixture/scripts/setup.sh" || fail "chmod failed"
s2="$work/s2"; new_repo "$s2"
( cd "$s2" && HIMMELCTL_REPO_ROOT="$fixture" node "$wizard" install --scope project </dev/null ) > "$work/install-s2.log" 2>&1 \
  || { cat "$work/install-s2.log" >&2; fail "b: himmelctl install --scope project failed"; }
grep -q 'given projects: skipping' "$work/install-s2.log" || fail "b: the adopt under install had node, so it does not isolate bin.js's add-target"
out=$(projects_json "$s2")
items=$(given_items "$out" "$s2")
[ -n "$items" ] || fail "b: projects --json does not list $s2 after install: $out"
has_item wiring-pretooluse "$items" || fail "b: $s2 lacks wiring-pretooluse: $items"
ok "b: himmelctl install --scope project lists $s2 with $items"

s3="$work/s3"; new_repo "$s3"; : > "$s3/.single-writer"; mkdir -p "$s3/.obsidian"
before=$(sha "$state_file")
node "$statejs" add-target "$s3" > "$work/c.log" 2>&1 && fail "c: add-target on a state repo exited 0"
[ "$(sha "$state_file")" = "$before" ] || fail "c: a refused add-target changed state.json"
grep -q 'state repo' "$work/c.log" || fail "c: refusal does not name the state repo: $(cat "$work/c.log")"
bash "$lgc" --state-repo "$s3"; rc_yes=$?
bash "$lgc" --state-repo "$s1"; rc_no=$?
[ "$rc_yes.$rc_no" = "0.1" ] || fail "c: launch-guard-check.sh --state-repo gave $rc_yes (state repo) and $rc_no (project), want 0 and 1"
node "$statejs" add-target "$s3" --state-repo-ok >/dev/null || fail "c: add-target --state-repo-ok refused"
ok "c: add-target refuses a state repo without --state-repo-ok; --state-repo answers 0 and 1"

wt="$work/s1-wt"
git -C "$s1" worktree add -q -b wt-branch "$wt" || fail "d: git worktree add failed"
node "$statejs" add-target "$wt" --items wiring-pretooluse >/dev/null || fail "d: add-target on a worktree failed"
n=$(jq --arg wt "$wt" --arg s1 "$s1" '[.given | keys[] | select(. == $wt or . == $s1)] | length' "$state_file")
if [ "$n" -ne 1 ] || ! jq -e --arg s1 "$s1" '.given | has($s1)' "$state_file" >/dev/null; then
  fail "d: worktree add-target left $n entries: $(jq -c '.given | keys' "$state_file")"
fi
ok "d: add-target on a worktree leaves one entry, $s1"

station_state="$HOME/.claude/himmel/state.json"
( unset HIMMELCTL_CACHE_DIR; node "$statejs" add-target "$s1" --items wiring-pretooluse >/dev/null ) || fail "e: station add-target failed"
[ -f "$station_state" ] || fail "e: add-target without HIMMELCTL_CACHE_DIR did not write $station_state"
link="$work/link-s1"; ln -s "$s1" "$link" || fail "e: ln -s failed"
other_cache="$work/other-cache"; mkdir -p "$other_cache"
printf '{"schemaVersion":1,"harness":"claude","targets":{},"given":{"/elsewhere":{"items":[],"adoptedAt":"x"}}}\n' > "$other_cache/state.json"
out=$( cd "$link" && PWD="$link" HIMMELCTL_CACHE_DIR="$other_cache" node "$statejs" list-targets --station --for "$link" --json )
jq -e --arg s1 "$s1" 'map(.path) == [$s1]' <<< "$out" >/dev/null || fail "e: list-targets --station --for $link gave $out"
out=$( HIMMELCTL_CACHE_DIR="$other_cache" node "$statejs" list-targets --station --json )
jq -e --arg s1 "$s1" 'map(.path) == [$s1]' <<< "$out" >/dev/null || fail "e: --station read HIMMELCTL_CACHE_DIR's file: $out"
ok "e: --station --for finds $s1 through a symlink and ignores HIMMELCTL_CACHE_DIR"

s4="$work/s4"; new_repo "$s4"
node "$statejs" add-target "$s4" >/dev/null || fail "f: add-target $s4 failed"
rm -rf "$s4"
"${noclaude[@]}" node "$statejs" remove-target "$s4" >/dev/null || fail "f: remove-target on a deleted path failed"
jq -e --arg k "$s4" '.given | has($k) | not' "$state_file" >/dev/null || fail "f: $s4 still listed"
ok "f: remove-target drops a deleted path's entry"

cp "$repo_root/docs/setup/profiles/adopter-project.install-profile.json" "$HIMMELCTL_CACHE_DIR/install-profile.json" || fail "g: cp profile failed"
s5="$work/s5"; new_repo "$s5"
tmp=$(mktemp "$work/state.XXXXXX") || fail "g: mktemp failed"
jq --arg k "$s5" '.targets[$k] = {profile:"core",scope:"project",items:{"wiring-pretooluse":{enabled:true,overrides:{}}},lastEnsured:null}' "$state_file" > "$tmp" \
  || fail "g: cannot seed targets[$s5]"
mv "$tmp" "$state_file" || fail "g: mv failed"
before_shape=$(jq -c --arg k "$s5" '.targets[$k] | keys' "$state_file")
( cd "$s5" && node "$wizard" ensure --items wiring-pretooluse --yes --no-network </dev/null ) > "$work/ensure-s5.log" 2>&1 \
  || { cat "$work/ensure-s5.log" >&2; fail "g: ensure in $s5 failed"; }
jq -e --arg k "$s5" '(.given // {}) | has($k) | not' "$state_file" >/dev/null || fail "g: ensure listed $s5"
[ "$(jq -c --arg k "$s5" '.targets[$k] | keys' "$state_file")" = "$before_shape" ] \
  || fail "g: the folder-keyed target changed shape: $(jq -c --arg k "$s5" '.targets[$k]' "$state_file")"
ok "g: ensure lists nothing in an unadopted sandbox; targets[$s5] keeps its key and shape"

h_items=wiring-pretooluse,wiring-statusline,pre-commit-hooks
( cd "$s1" && node "$wizard" ensure --profile core --items "$h_items" --yes --no-network </dev/null ) > "$work/ensure-s1.log" 2>&1 \
  || { cat "$work/ensure-s1.log" >&2; fail "h: ensure --profile core in $s1 failed"; }
jq -e --arg k "$s1" '.given | has($k)' "$state_file" >/dev/null || fail "h: ensure --profile core dropped $s1 from the list"
status_out=$( cd "$s1" && node "$wizard" status --items "$h_items" --json ) || fail "h: status in $s1 exited non-zero: $status_out"
jq -e '[.items[] | select(.desired and .actual == "present")] | length == 3' <<< "$status_out" >/dev/null \
  || fail "h: status in $s1 is not green: $status_out"
ok "h: ensure --profile core keeps $s1 listed and status is green there"

before=$(sha "$state_file")
CLAUDECODE=1 node "$statejs" remove-target "$s1" > "$work/i.log" 2>&1 && fail "i: remove-target with CLAUDECODE=1 exited 0"
[ "$(sha "$state_file")" = "$before" ] || fail "i: a refused remove-target changed state.json"
"${noclaude[@]}" node "$statejs" remove-target "$s1" >/dev/null || fail "i: remove-target outside a Claude session failed"
jq -e --arg k "$s1" '.given | has($k) | not' "$state_file" >/dev/null || fail "i: $s1 still listed after remove-target"
ok "i: remove-target refuses under CLAUDECODE=1 and drops the entry outside a session"

pids=()
for n in 1 2 3 4 5 6 7 8; do
  new_repo "$work/par$n"
  node "$statejs" add-target "$work/par$n" >/dev/null 2>&1 &
  pids+=("$!")
done
for p in "${pids[@]}"; do wait "$p" || fail "j: a parallel add-target failed"; done
for n in 1 2 3 4 5 6 7 8; do
  jq -e --arg k "$work/par$n" '.given | has($k)' "$state_file" >/dev/null || fail "j: parallel add-target lost $work/par$n"
done
ok "j: eight parallel add-targets all land"

s6="$work/s6"; new_repo "$s6"
node -e '
const { spawnSync } = require("child_process");
const s = require(process.argv[1]);
const stale = s.load();
const r = spawnSync(process.execPath, [process.argv[1], "add-target", process.argv[2]], { encoding: "utf8" });
if (r.status !== 0) { console.error(r.stderr); process.exit(1); }
s.save(stale);
' "$statejs" "$s6" || fail "k: stale-save fixture failed"
jq -e --arg k "$s6" '.given | has($k)' "$state_file" >/dev/null || fail "k: a save from a state loaded before add-target dropped $s6"
ok "k: a writer holding an older state does not drop a listed project"

mkdir "$HIMMELCTL_CACHE_DIR/state.json.lock" || fail "l: cannot plant a lock"
node -e 'const t = Date.now() / 1000 - 600; require("fs").utimesSync(process.argv[1], t, t);' "$HIMMELCTL_CACHE_DIR/state.json.lock" \
  || fail "l: cannot age the lock"
before=$(sha "$state_file")
s7="$work/s7"; new_repo "$s7"
node "$statejs" add-target "$s7" > "$work/l.log" 2>&1 && fail "l: add-target ran through a held lock"
[ "$(sha "$state_file")" = "$before" ] || fail "l: add-target wrote state.json through a held lock"
[ -d "$HIMMELCTL_CACHE_DIR/state.json.lock" ] || fail "l: add-target removed a lock it did not take"
grep -q 'state.json.lock' "$work/l.log" || fail "l: the refusal does not name the lock: $(cat "$work/l.log")"
ok "l: a held lock is never taken over; add-target refuses and names it"

echo "PASS: test-himmelctl-projects.sh"
