#!/usr/bin/env bash
# shellcheck disable=SC2015
# test-launch-guard-p-adopted.sh - launch-guard-p.mjs adopted mode over the real
# output of `adopt.sh --scope project` in a sandbox repo. HOME, the Claude
# config dir and the station list live under mktemp -d; nothing touches a real
# project or a user-scope file.
set -uo pipefail

W=$(cd "$(dirname "$0")/../.." && pwd) || exit 1
. "$W/scripts/lib/hermetic-path.sh"
. "$W/scripts/lib/canon-path.sh"
LGP="$W/scripts/lib/launch-guard-p.mjs"
adopt="$W/scripts/adopt.sh"

fails=0
pass() { echo "ok - $1"; }
fail() { echo "FAIL - $1${2:+: $2}"; fails=$((fails+1)); }
die() { echo "FAIL: $1" >&2; exit 1; }

command -v node >/dev/null 2>&1 || die "node required"
command -v jq >/dev/null 2>&1 || die "jq required"
node_bin=$(command -v node)

work_raw=$(mktemp -d "${TMPDIR:-/tmp}/lgp-adopted.XXXXXX") || die "mktemp"
trap 'rm -rf "$work_raw"' EXIT
work=$(canon_path_native "$work_raw") || die "canon $work_raw"

export HOME="$work/home"
mkdir -p "$HOME/.claude" || die "mkdir $HOME"
export CLAUDE_CONFIG_DIR="$HOME/.claude"
export HIMMELCTL_CACHE_DIR="$HOME/.claude/himmel"
export HIMMEL_PROVENANCE_DIR="$work/prov"
export HIMMEL_LUNA_CONFIG_PATH="$work/luna-config.json"
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
unset HIMMEL_REPO HANDOVER_DIR HIMMELCTL_REPO_ROOT LUNA_VAULT_PATH CLAUDE_USER_SETTINGS
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
git config --global user.name t
git config --global user.email t@example.invalid
git config --global init.defaultBranch main
printf '{}\n' > "$CLAUDE_CONFIG_DIR/settings.json"

core_bin="$work/core-bin"; node_dir="$work/node-bin"
build_hermetic_bin "$core_bin" bash git jq python3 grep sed cat cp mv rm ln mkdir chmod diff wc tr head tail \
  basename dirname mktemp dd sort cut xargs date stat uname id awk cmp find env touch ls readlink realpath tee \
  "$(command -v sha256sum >/dev/null 2>&1 && echo sha256sum || echo shasum)" || die "build_hermetic_bin"
mkdir -p "$node_dir" && ln -s "$node_bin" "$node_dir/node" || die "link node"
cat > "$core_bin/claude" <<STUB || die "claude stub"
#!/usr/bin/env bash
if [ "\$1" = "plugin" ] && [ "\$2" = "list" ]; then
  jq -r '.enabledPlugins | keys[]' "$W/docs/setup/settings-template.json"
fi
exit 0
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$core_bin/npm"
chmod +x "$core_bin/claude" "$core_bin/npm"
rest_path=$(scrub_path "$PATH" node npm bun qmd uv pipx pre-commit graphify claude)
export PATH="$node_dir:$core_bin:$rest_path"

new_repo() {
  mkdir -p "$1" && git -C "$1" init -q && git -C "$1" commit -q --allow-empty -m init || die "repo $1"
}
adopt_into() {
  local d="$1"; shift
  ( cd "$d" && env "$@" bash "$adopt" --profile core --scope project --target "$d" ) > "$work/adopt.log" 2>&1 \
    || { cat "$work/adopt.log" >&2; die "adopt.sh --scope project into $d failed"; }
}
lgp() {
  local d="$1"; shift
  ERR=$(env "$@" node "$LGP" "$W" "$d/.claude/settings.json" --adopted "$d" 2>&1 >/dev/null)
  RC=$?
}
expect() {
  [ "$RC" = "$2" ] && [ "$ERR" = "$3" ] && pass "$1" || fail "$1" "rc=$RC err=[$ERR] want rc=$2 err=[$3]"
}
jset() { jq "$2" "$1" > "$1.tmp" && mv "$1.tmp" "$1"; }

S="$work/listed"; new_repo "$S"
adopt_into "$S"
SH="$S/.claude/settings.json"; LO="$S/.claude/settings.local.json"
cp "$SH" "$work/shared.orig"; cp "$LO" "$work/local.orig" 2>/dev/null || : > "$work/local.orig"
reset() { cp "$work/shared.orig" "$SH"; cp "$work/local.orig" "$LO"; printf '{}\n' > "$CLAUDE_CONFIG_DIR/settings.json"; }

lgp "$S"; expect "real_adopt_output_passes" 0 ""

jq -e '[.. | strings | select(contains("self-heartbeat"))] | length == 0' "$SH" "$LO" >/dev/null \
  && { lgp "$S"; expect "no_heartbeat_hook_passes" 0 ""; } || fail "no_heartbeat_hook_passes" "fixture carries a heartbeat hook"

U="$work/unlisted"; new_repo "$U"
adopt_into "$U" HIMMELCTL_CACHE_DIR="$work/decoy-cache"
UNLISTED="not a given scope: $U (run himmelctl migrate-scopes --adopt $U, or adopt it at project scope)"
lgp "$U"; expect "unlisted_refuses" 1 "$UNLISTED"
lgp "$U" HIMMELCTL_CACHE_DIR="$work/decoy-cache"; expect "inherited_cache_dir_ignored" 1 "$UNLISTED"

reset
mkdir -p "$work/node2" && ln -s "$node_bin" "$work/node2/node"
jq --arg n "$work/node2/node" '(.hooks.PreToolUse[].hooks[].command) |= sub("\" \"[^\"]*\" \"(?<w>[^\"]*guardrail-skip-in-himmel[.]js)\""; "\" \"" + $n + "\" \"\(.w)\"")' \
  "$LO" > "$LO.tmp" && mv "$LO.tmp" "$LO"
grep -q "$work/node2/node" "$LO" && { lgp "$S"; expect "node_path_change_passes" 0 ""; } \
  || fail "node_path_change_passes" "fixture edit did not land"

reset
TRIO_MISSING="anchor guard trio missing from the local file: re-run adopt"
jset "$LO" '(.hooks.PreToolUse[].hooks[].command) |= sub("\"[^\"]*guardrail-skip-in-himmel[.]js\""; "\"/elsewhere/guardrail-skip-in-himmel.js\"")'
lgp "$S"; expect "wrapper_path_change_refuses" 1 "$TRIO_MISSING"
rm -f "$LO"; lgp "$S"; expect "local_file_absent_refuses" 1 "$TRIO_MISSING"

reset; jset "$CLAUDE_CONFIG_DIR/settings.json" '.disableAllHooks = true'
lgp "$S"; expect "disable_all_hooks_user_refuses" 1 "hooks disabled in $CLAUDE_CONFIG_DIR/settings.json"
reset; jset "$SH" '.disableAllHooks = true'
lgp "$S"; expect "disable_all_hooks_shared_refuses" 1 "hooks disabled in $SH"
reset; jset "$LO" '.disableAllHooks = true'
lgp "$S"; expect "disable_all_hooks_local_refuses" 1 "hooks disabled in $LO"
reset; jset "$CLAUDE_CONFIG_DIR/settings.json" '.disableAllHooks = true'; jset "$SH" '.disableAllHooks = false'
lgp "$S"; expect "user_true_under_shared_false_passes" 0 ""

reset; printf '{"hooks":' > "$LO"
lgp "$S"; expect "malformed_local_refuses" 1 "settings layer unreadable: $LO"

reset
jset "$SH" '(.hooks.PreToolUse[].hooks[] | select(.command | contains("block-read-secrets.sh")) | .command) |= (. + " ")'
lgp "$S"; expect "stale_chain_command_refuses" 1 "adopted chain differs: re-run adopt"

reset; mv "$S/scripts/hooks/block-read-secrets.sh" "$work/brs.sh"
lgp "$S"; expect "missing_hook_script_refuses" 1 "guard script missing: re-run adopt"
mv "$work/brs.sh" "$S/scripts/hooks/block-read-secrets.sh"

reset
jset "$SH" '.hooks.PreToolUse += [{"matcher":"Edit","hooks":[{"type":"command","command":"echo adopter-edit","timeout":7}]}]
  | (.hooks.PreToolUse[] | select(any(.hooks[]; .command | contains("block-edit-on-main.sh"))) | .matcher) = "Edit"'
lgp "$S"; expect "short_matcher_refuses" 1 "matcher for block-edit-on-main does not cover Write: re-run adopt --repair-matchers"
cp "$SH" "$work/short.json"
( cd "$S" && bash "$adopt" --repair-matchers --dry-run --target "$S" ) > "$work/repair-dry.log" 2>&1
cmp -s "$SH" "$work/short.json" && pass "repair_matchers_dry_run_writes_nothing" \
  || fail "repair_matchers_dry_run_writes_nothing" "$(cat "$work/repair-dry.log")"
others() { jq -c '[.hooks.PreToolUse[] | .matcher as $m | .hooks[] | select(.command | test("scripts/hooks/") | not) | {m: $m, h: .}], del(.hooks.PreToolUse)' "$1"; }
before=$(others "$SH")
( cd "$S" && bash "$adopt" --repair-matchers --target "$S" ) > "$work/repair.log" 2>&1 \
  || fail "repair_matchers_runs" "$(cat "$work/repair.log")"
lgp "$S"; expect "short_matcher_passes_after_repair" 0 ""
[ "$(others "$SH")" = "$before" ] && pass "repair_keeps_adopter_entries" \
  || fail "repair_keeps_adopter_entries" "before=$before after=$(others "$SH")"

reset
case "$(git -C "$S" status --porcelain --ignored=no)" in
  *settings.local.json*) fail "local_file_gitignored" "$(git -C "$S" status --porcelain)" ;;
  *) pass "local_file_gitignored" ;;
esac
grep -qxF '.claude/settings.local.json' "$S/.worktreeinclude" 2>/dev/null && pass "worktreeinclude_holds_local_file" \
  || fail "worktreeinclude_holds_local_file" "$(cat "$S/.worktreeinclude" 2>&1)"

P="$work/prewt"; new_repo "$P"
printf 'keep-me\n' > "$P/.worktreeinclude"
adopt_into "$P"
bk=$(find "$HIMMEL_PROVENANCE_DIR/provenance-backups" -name '*-.worktreeinclude' -newer "$P/.git/HEAD" | head -n 1)
[ -n "$bk" ] && [ "$(cat "$bk")" = "keep-me" ] && pass "worktreeinclude_backup_is_preimage" \
  || fail "worktreeinclude_backup_is_preimage" "backup=[$bk] content=[$( [ -n "$bk" ] && cat "$bk")]"

echo "--- $fails failure(s)"
[ "$fails" -eq 0 ]
