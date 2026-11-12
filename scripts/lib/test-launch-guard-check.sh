#!/usr/bin/env bash
# scripts/lib/test-launch-guard-check.sh - suite for scripts/lib/launch-guard-check.sh
# (and launch-guard-p.mjs). Fixtures live under mktemp -d with a fake HOME,
# HANDOVER_REGISTRY and CLAUDE_CONFIG_DIR; HIMMEL_REPO is the worktree under test.
# shellcheck disable=SC2015,SC2016  # `A && ok || fail` is the suite's check idiom; node -e bodies are literal
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
W="$(cd "$HERE/../.." && pwd)"
CHECK="$W/scripts/lib/launch-guard-check.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/launch-guard-test.XXXXXX")" || { echo "FAIL: mktemp" >&2; exit 1; }
tmp="$(cd "$tmp" && pwd -P)"  # the check prints physical paths (macOS /var -> /private/var)
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { echo "ok - $1"; }
fail() { echo "FAIL - $1${2:+: $2}"; fails=$((fails+1)); }

NODE="$(command -v node)"
BASH_BIN="$(command -v bash)"
export HOME="$tmp/home"; mkdir -p "$HOME"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset CLAUDE_USER_SETTINGS GIT_DIR UNGUARDED_LAUNCH_OK
REG="$tmp/registry.json"
CFG="$tmp/cfg-complete"; mkdir -p "$CFG"

# run <dir> [VAR=val ...] -> sets RC, OUT. Defaults: complete user layer, test registry.
run() {
  local d="$1"; shift
  OUT="$(/usr/bin/env HOME="$HOME" HANDOVER_REGISTRY="$REG" CLAUDE_CONFIG_DIR="$CFG" HIMMEL_REPO="$W" \
    "$@" "$BASH_BIN" "$CHECK" "$d" 2>/dev/null)"
  RC=$?
}
expect() { # <name> <rc> <stdout>
  [ "$RC" = "$2" ] && [ "$OUT" = "$3" ] && pass "$1" || fail "$1" "rc=$RC out=[$OUT] want rc=$2 out=[$3]"
}

mkrepo() { # <dir> : committed git repo
  mkdir -p "$1" && git -C "$1" init -q -b main && git -C "$1" commit -q --allow-empty -m init
}
register() { # <abs repo path>
  mkdir -p "$tmp/state"
  /usr/bin/env HANDOVER_REGISTRY="$REG" USER_SLUG=tester "$BASH_BIN" "$W/scripts/handover/register-state.sh" \
    --repo-path "$1" --state-host "$tmp/state" >/dev/null 2>"$tmp/reg.err" || fail "register $1" "$(cat "$tmp/reg.err")"
}
# mkhimmel <dir> <settings-src> : git repo carrying the wire-hook-bash.mjs marker + that settings, committed
mkhimmel() {
  mkdir -p "$1/scripts/hooks" "$1/.claude"
  printf '%s\n' 'process.exit(0)' > "$1/scripts/hooks/wire-hook-bash.mjs"
  cp "$2" "$1/.claude/settings.json"
  git -C "$1" init -q -b main && git -C "$1" add -A && git -C "$1" commit -q -m init
}
# History fixtures: an anchor primary that carries trusted copies of the checker code
# and a fake origin/main. mkanchor commits the OLD inventory (PARTIAL stands for a hook
# list main has since outgrown); newinv moves main on to the GOOD list and points
# refs/remotes/origin/main at it. A worktree cut between the two is "stale but untouched".
CHAIN_DIFF="himmel hook chain differs from main (rebase onto main, or launch with UNGUARDED_LAUNCH_OK=1)"
mkanchor() { # <dir> <wire-hook-bash.mjs to carry>
  mkdir -p "$1/scripts/hooks" "$1/scripts/lib" "$1/scripts/guardrails" "$1/.claude"
  cp "$2" "$1/scripts/hooks/wire-hook-bash.mjs"
  cp "$W/scripts/lib/settings-lock.mjs" "$W/scripts/lib/config-audit.cjs" "$1/scripts/lib/"
  cp "$W/scripts/guardrails/lib.sh" "$1/scripts/guardrails/"
  cp "$PARTIAL" "$1/.claude/settings.json"
  git -C "$1" init -q -b main && git -C "$1" add -A && git -C "$1" commit -q -m old-inventory
}
newinv() { # <anchor dir>
  cp "$GOOD" "$1/.claude/settings.json"
  git -C "$1" commit -q -am new-inventory
  git -C "$1" update-ref refs/remotes/origin/main "$(git -C "$1" rev-parse main)"
}

# Settings variants: complete (the worktree's own) and partial (first PreToolUse group dropped).
GOOD="$W/.claude/settings.json"
PARTIAL="$tmp/partial-settings.json"
"$NODE" -e '
const fs=require("fs");const s=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
s.hooks.PreToolUse.shift();fs.writeFileSync(process.argv[2],JSON.stringify(s,null,2)+"\n");' "$GOOD" "$PARTIAL"

# Complete user layer via the real installer.
/usr/bin/env HOME="$HOME" HIMMEL_REPO="$W" CLAUDE_USER_SETTINGS="$CFG/settings.json" \
  "$NODE" "$W/scripts/hooks/guardrail-block.mjs" install --node "$NODE" --bash "$BASH_BIN" >/dev/null 2>&1 \
  || fail "fixture: user layer install"

# --- usage ---------------------------------------------------------------------
OUT="$("$BASH_BIN" "$CHECK" 2>/dev/null)"; RC=$?; expect "usage_no_arg" 2 ""
run "$tmp/does-not-exist"; expect "usage_missing_dir" 2 ""

# --- layer U refusals ----------------------------------------------------------
mkdir -p "$tmp/scratch"
run "$tmp/scratch"; expect "scratch_non_git" 1 "not a git work tree"

mkrepo "$tmp/unreg"
run "$tmp/unreg"; expect "unregistered_repo_complete_user_layer" 1 "repo not registered"

mkrepo "$tmp/luna"; : > "$tmp/luna/.single-writer"; printf '{"template":"luna-second-brain"}\n' > "$tmp/luna/.vault-template.json"
register "$tmp/luna"
run "$tmp/luna" HANDOVER_DIR=; expect "luna_no_handover_dir" 1 "single-writer state repo"
git -C "$tmp/luna" worktree add -q "$tmp/luna-wt" -b wt >/dev/null 2>&1
run "$tmp/luna-wt"; expect "luna_linked_worktree" 1 "single-writer state repo"

mkrepo "$tmp/personal"; : > "$tmp/personal/.single-writer"; register "$tmp/personal"
run "$tmp/personal"; expect "personal_single_writer_repo_passes" 0 "guarded: user-layer $tmp/personal"
mkrepo "$tmp/stamp-only"; printf '{}\n' > "$tmp/stamp-only/.vault-template.json"; register "$tmp/stamp-only"
run "$tmp/stamp-only"; expect "vault_stamp_without_single_writer_passes" 0 "guarded: user-layer $tmp/stamp-only"

mkrepo "$tmp/adopter"; register "$tmp/adopter"
printf '%s' '{not json' > "$tmp/registry-bad.json"
run "$tmp/adopter" HANDOVER_REGISTRY="$tmp/registry-bad.json"; expect "registry_unreadable" 1 "handover registry unreadable"
BADCFG="$tmp/cfg-incomplete"; mkdir -p "$BADCFG"; echo '{}' > "$BADCFG/settings.json"
run "$tmp/adopter" CLAUDE_CONFIG_DIR="$BADCFG"
expect "lane_config_dir_incomplete" 1 "user guard layer incomplete (run himmelctl ensure)"
run "$tmp/adopter" CLAUDE_CONFIG_DIR="$BADCFG" CLAUDE_USER_SETTINGS="$CFG/settings.json"
expect "inherited_user_settings_ignored" 1 "user guard layer incomplete (run himmelctl ensure)"

RAWCFG="$tmp/cfg-raw"; mkdir -p "$RAWCFG"
"$NODE" -e '
const fs=require("fs");const W=process.argv[1];const hooks={PreToolUse:[]};
for (const b of ["auto-approve-safe-bash.sh","block-edit-on-main.sh","block-read-secrets.sh"]) {
  const p=W+"/scripts/hooks/"+b;
  hooks.PreToolUse.push({matcher:"Bash",hooks:[{type:"command",command:`if [ -f ${p} ]; then bash ${p}; fi`}]});
}
fs.writeFileSync(process.argv[2],JSON.stringify({hooks},null,2));' "$W" "$RAWCFG/settings.json"
run "$tmp/adopter" CLAUDE_CONFIG_DIR="$RAWCFG"
expect "adopt_sh_only" 1 "user guard layer incomplete (run himmelctl ensure)"

# node absent: a PATH holding only git/bash/dirname
NOBIN="$tmp/nobin"; mkdir -p "$NOBIN"
for c in git bash dirname; do ln -s "$(command -v "$c")" "$NOBIN/$c"; done
run "$tmp/adopter" PATH="$NOBIN"; expect "node_absent" 1 "node not on PATH"

# --- layer P -------------------------------------------------------------------
mkhimmel "$tmp/himmel-partial" "$PARTIAL"; register "$tmp/himmel-partial"
run "$tmp/himmel-partial"; expect "himmel_partial_chain_complete_user_layer" 1 "himmel hook chain differs from main (rebase onto main, or launch with UNGUARDED_LAUNCH_OK=1)"

mkhimmel "$tmp/stubbed" "$PARTIAL"
run "$tmp/stubbed"
[ "$RC" = 1 ] && [ "$OUT" = "himmel hook chain differs from main (rebase onto main, or launch with UNGUARDED_LAUNCH_OK=1)" ] && [ ! -e "$tmp/stubbed/.claude/settings.json.lock" ] \
  && pass "candidate_checker_stubbed" \
  ||fail "candidate_checker_stubbed" "rc=$RC out=[$OUT] lock=$(ls "$tmp/stubbed/.claude" 2>&1)"

run "$W"; expect "himmel_checkout_passes" 0 "guarded: project $W"
# default anchor (A20): HIMMEL_REPO absent, not merely empty
OUT="$(/usr/bin/env -u HIMMEL_REPO HOME="$HOME" HANDOVER_REGISTRY="$REG" CLAUDE_CONFIG_DIR="$CFG" \
  "$BASH_BIN" "$CHECK" "$W" 2>/dev/null)"; RC=$?
expect "default_anchor_without_himmel_repo" 0 "guarded: project $W"
mkdir -p "$tmp/emptyanchor"
run "$tmp/adopter" HIMMEL_REPO="$tmp/emptyanchor"
expect "anchor_lib_unreadable" 1 "anchor lib unreadable: $tmp/emptyanchor/scripts/guardrails/lib.sh"

# primary partial (uncommitted edit), linked worktree complete (committed) -> worktree passes
mkhimmel "$tmp/pmain" "$GOOD"
git -C "$tmp/pmain" worktree add -q "$tmp/pmain-wt" -b wt >/dev/null 2>&1
cp "$PARTIAL" "$tmp/pmain/.claude/settings.json"
run "$tmp/pmain-wt"; expect "worktree_of_main_passes" 0 "guarded: project $tmp/pmain-wt"
# reverse: primary complete, worktree partial
mkhimmel "$tmp/rmain" "$PARTIAL"
git -C "$tmp/rmain" worktree add -q "$tmp/rmain-wt" -b wt >/dev/null 2>&1
cp "$GOOD" "$tmp/rmain/.claude/settings.json"
run "$tmp/rmain-wt"; expect "primary_complete_worktree_partial" 1 "himmel hook chain differs from main (rebase onto main, or launch with UNGUARDED_LAUNCH_OK=1)"

# Settings history (spec A2b): a folder passes when its settings file is byte-equal to a
# blob main carried at or after the folder's merge-base with origin/main.
REAL_CHECKER="$W/scripts/hooks/wire-hook-bash.mjs"
mkanchor "$tmp/hm" "$REAL_CHECKER"
git -C "$tmp/hm" worktree add -q "$tmp/hm-wt" -b wt >/dev/null 2>&1      # cut at the old inventory
newinv "$tmp/hm"
git -C "$tmp/hm" worktree add -q "$tmp/hm-wt-new" -b wt-new >/dev/null 2>&1   # cut at the new one
run "$tmp/hm-wt" HIMMEL_REPO="$tmp/hm"
expect "worktree_before_inventory_change_passes" 0 "guarded: project $tmp/hm-wt"
run "$tmp/hm-wt-new" HIMMEL_REPO="$tmp/hm"
expect "worktree_after_inventory_change_passes" 0 "guarded: project $tmp/hm-wt-new"
# a branch that edits settings.json itself (blob not on origin/main) stays refused
git -C "$tmp/hm-wt-new" show HEAD:.claude/settings.json \
  | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);j.hooks.PreToolUse.pop();process.stdout.write(JSON.stringify(j,null,2)+"\n")})' \
  > "$tmp/hm-wt-new/.claude/settings.json"
git -C "$tmp/hm-wt-new" commit -q -am "branch edits settings"
run "$tmp/hm-wt-new" HIMMEL_REPO="$tmp/hm"; expect "branch_edits_settings_refused" 1 "$CHAIN_DIFF"
# the partial list sitting on a folder cut AFTER main moved on is not an old blob of that history
git -C "$tmp/hm" worktree add -q "$tmp/hm-wt-late" -b wt-late >/dev/null 2>&1
cp "$PARTIAL" "$tmp/hm-wt-late/.claude/settings.json"
run "$tmp/hm-wt-late" HIMMEL_REPO="$tmp/hm"; expect "old_blob_before_merge_base_refused" 1 "$CHAIN_DIFF"
# no origin/main ref and no main: nothing to match against -> refused (strict check only)
mkanchor "$tmp/hm-norefs" "$REAL_CHECKER"; git -C "$tmp/hm-norefs" branch -m trunk
run "$tmp/hm-norefs" HIMMEL_REPO="$tmp/hm-norefs"; expect "no_main_ref_refused" 1 "$CHAIN_DIFF"
# newer settings, older anchor: the anchor's checker predates the candidate's hooks and
# throws on it, but the candidate file equals a blob on origin/main after the merge-base
printf '%s\n' 'export function rewriteSettingsText(){ throw new Error("unknown hook entry"); }' > "$tmp/throwing-checker.mjs"
mkanchor "$tmp/oa" "$tmp/throwing-checker.mjs"
git -C "$tmp/oa" worktree add -q "$tmp/oa-wt" -b wt >/dev/null 2>&1
newinv "$tmp/oa"
cp "$GOOD" "$tmp/oa-wt/.claude/settings.json"
run "$tmp/oa-wt" HIMMEL_REPO="$tmp/oa"; expect "newer_settings_older_anchor" 0 "guarded: project $tmp/oa-wt"
# the throwing anchor alone does not pass a file that is on no origin/main blob
cp "$PARTIAL" "$tmp/oa-wt/.claude/settings.json"; printf ' ' >> "$tmp/oa-wt/.claude/settings.json"
run "$tmp/oa-wt" HIMMEL_REPO="$tmp/oa"; expect "unlisted_settings_older_anchor_refused" 1 "$CHAIN_DIFF"
# fallback to local main when origin/main does not resolve
git -C "$tmp/hm" update-ref -d refs/remotes/origin/main
run "$tmp/hm-wt" HIMMEL_REPO="$tmp/hm"; expect "main_fallback_when_no_origin_main" 0 "guarded: project $tmp/hm-wt"

# M-1: the folder the session loads is judged, not its toplevel
run "$W/scripts"; expect "subdir_launch_refused" 1 "not a git work tree root (launch from $W)"
mkhimmel "$tmp/subrepo" "$GOOD"; mkdir -p "$tmp/subrepo/pkg/.claude"; cp "$GOOD" "$tmp/subrepo/pkg/.claude/settings.json"
run "$tmp/subrepo/pkg"; expect "subdir_with_own_settings_passes" 0 "guarded: project $tmp/subrepo/pkg"
cp "$PARTIAL" "$tmp/subrepo/pkg/.claude/settings.json"
run "$tmp/subrepo/pkg"; expect "subdir_own_partial_settings_refused" 1 "$CHAIN_DIFF"

# --- layer U passes ------------------------------------------------------------
run "$tmp/adopter"; expect "registered_adopter_passes" 0 "guarded: user-layer $tmp/adopter"

mkdir -p "$tmp/a b"; mkrepo "$tmp/a b/repo"; register "$tmp/a b/repo"
ln -s "$tmp/a b/repo" "$tmp/link"
run "$tmp/link"; expect "spaces_and_symlink" 0 "guarded: user-layer $tmp/a b/repo"

# --- callers carry no layer logic: each names the shared check and none of the layer internals ---
callers_ok=1
for f in scripts/handover/headed-arm.sh scripts/handover/chief-kit/headed-arm-worker.sh \
         scripts/handover/arm-resume.sh scripts/handover/chief/chief.sh; do
  if grep -q -e 'guardrail-block' -e 'rewriteSettingsText' -e 'register-state.sh --check' "$W/$f"; then
    callers_ok=0; echo "  $f carries layer logic"
  fi
  grep -q 'launch-guard-check.sh' "$W/$f" || { callers_ok=0; echo "  $f does not name launch-guard-check.sh"; }
done
[ "$callers_ok" = 1 ] && pass "callers_carry_no_layer_logic" || fail "callers_carry_no_layer_logic"

# --- read-only: the check wrote nothing into the folder under test --------------
[ -z "$(git -C "$tmp/adopter" status --porcelain)" ] && pass "writes_nothing_in_folder" || fail "writes_nothing_in_folder"

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$fails FAILED"; exit 1
