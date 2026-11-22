#!/usr/bin/env bash
# scripts/lib/launch-guard-check.sh - does a folder a claude session would launch in
# load himmel's guard hooks? Read-only: writes nothing, runs no code from <dir>.
#
# Usage: launch-guard-check.sh <dir>
#        launch-guard-check.sh --state-repo <dir>
#
# --state-repo is a query mode: is <dir>'s primary checkout (<dir> itself outside git)
# a state repo, by the Layer U test below? Exit 0 yes, 1 no, 2 unresolvable dir;
# prints nothing on stdout.
#
# Layer P (himmel tree: <toplevel>/scripts/hooks/wire-hook-bash.mjs exists): the
# folder's .claude/settings.json must carry the full chain (launch-guard-p.mjs), or be
# byte-equal to a blob on the anchor's origin/main since the folder's merge-base (a
# worktree cut before main added hooks). A subdirectory of the tree needs its own file.
# The full-chain check sets aside the wiring of a hook the folder's own branch adds
# (in its diff since the merge-base, executable in <dir>); see hooks_added_by_branch.
# Layer U (anything else): the user guard layer is complete, <dir> is in a git work
# tree whose primary checkout is registered, and that checkout is not a state repo: one
# carrying .single-writer AND any of a .vault-template.json stamp, an .obsidian/ directory,
# or a non-empty HANDOVER_DIR that is, or sits inside, the checkout (one that does not
# resolve refuses; an empty one skips this test). .single-writer alone is only the
# block-edit-on-main opt-out and passes.
#
# Env: HIMMEL_REPO (trust anchor; default the primary checkout of this script's tree),
#      CLAUDE_CONFIG_DIR, HANDOVER_REGISTRY. An inherited CLAUDE_USER_SETTINGS is ignored.
#
# Exit codes:
#   0  guarded - stdout "guarded: project <dir>" or "guarded: user-layer <dir>"
#   1  not guarded - stdout one reason string
#   2  usage / unresolvable dir
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=git-clean.sh
. "$HERE/git-clean.sh"
git_env_scrub
# shellcheck source=claude-config-dir.sh
. "$HERE/claude-config-dir.sh"

mode=check
if [ "${1:-}" = "--state-repo" ]; then mode=state-repo; shift; fi
[ "$#" -eq 1 ] && [ -n "$1" ] || { echo "usage: launch-guard-check.sh [--state-repo] <dir>" >&2; exit 2; }
dir="$(cd -P -- "$1" 2>/dev/null && pwd)" || { echo "launch-guard-check: cannot resolve: $1" >&2; exit 2; }

refuse() { printf '%s\n' "$1"; exit 1; }

is_state_repo() {
  local p="$1" hroot
  [ -e "$p/.single-writer" ] || return 1
  { [ -e "$p/.vault-template.json" ] || [ -d "$p/.obsidian" ]; } && return 0
  [ -n "${HANDOVER_DIR:-}" ] || return 1
  hroot="$(cd -P -- "$HANDOVER_DIR" 2>/dev/null && pwd)" || return 0
  case "$hroot/" in "$p"/*) return 0 ;; esac
  return 1
}

# Trust anchor (A20): HIMMEL_REPO, else the primary checkout of this script's tree.
anchor="${HIMMEL_REPO:-}"
if [ -z "$anchor" ]; then
  common="$(git -C "$HERE" rev-parse --git-common-dir 2>/dev/null)" || common=""
  [ -n "$common" ] && anchor="$(cd "$HERE" && cd "$common" 2>/dev/null && cd .. && pwd)"
  [ -n "$anchor" ] || anchor="$(cd "$HERE/../.." && pwd)"
fi
export HIMMEL_REPO="$anchor"

[ "$mode" = state-repo ] || command -v node >/dev/null 2>&1 || refuse "node not on PATH"

lib="$anchor/scripts/guardrails/lib.sh"
if [ ! -r "$lib" ]; then
  [ "$mode" = state-repo ] && { echo "launch-guard-check: anchor lib unreadable: $lib" >&2; exit 2; }
  refuse "anchor lib unreadable: $lib"
fi
# shellcheck disable=SC1090
. "$lib"

if [ "$mode" = state-repo ]; then
  primary="$(primary_checkout_root "$dir" 2>/dev/null)" || primary=""
  is_state_repo "${primary:-$dir}"
  exit $?
fi

top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || top=""

# settings_on_main_history <file>: is the file byte-equal to a .claude/settings.json blob on
# the anchor's origin/main (else main) at or after the folder's merge-base with it? Git
# plumbing against the ANCHOR repo only; the candidate file is hashed, never run or parsed.
settings_on_main_history() {
  local f="$1" ref="" r mb head want
  for r in refs/remotes/origin/main refs/heads/main; do
    if git -C "$anchor" rev-parse --verify -q "$r^{commit}" >/dev/null 2>&1; then ref="$r"; break; fi
  done
  [ -n "$ref" ] || return 1
  head="$(git -C "$top" rev-parse HEAD 2>/dev/null)" || return 1
  mb="$(git -C "$anchor" merge-base "$ref" "$head" 2>/dev/null)" || return 1
  [ -n "$mb" ] || return 1
  want="$(git -C "$anchor" hash-object --no-filters -- "$f" 2>/dev/null)" || return 1
  [ -n "$want" ] || return 1
  {
    git -C "$anchor" rev-parse --verify -q "$mb:.claude/settings.json" 2>/dev/null
    git -C "$anchor" log --format= --raw --no-abbrev "$mb..$ref" -- .claude/settings.json 2>/dev/null \
      | awk '/^:/ { print $4 }'
  } | grep -xF "$want" >/dev/null  # no -q: an early-exiting grep would SIGPIPE the writers under pipefail
}

hooks_added_by_branch() {
  local ref="" r head mb p name f
  for r in refs/remotes/origin/main refs/heads/main; do
    if git -C "$anchor" rev-parse --verify -q "$r^{commit}" >/dev/null 2>&1; then ref="$r"; break; fi
  done
  [ -n "$ref" ] || return 0
  head="$(git -C "$top" rev-parse HEAD 2>/dev/null)" || return 0
  mb="$(git -C "$anchor" merge-base "$ref" "$head" 2>/dev/null)" || return 0
  [ -n "$mb" ] || return 0
  git -C "$anchor" diff-tree -r --no-renames --name-only --diff-filter=A "$mb" "$head" -- scripts/hooks/ 2>/dev/null \
    | while IFS= read -r p; do
        name="${p#scripts/hooks/}"
        printf '%s\n' "$name" | grep -xE '[A-Za-z0-9._-]+\.sh' >/dev/null || continue
        f="$dir/scripts/hooks/$name"
        [ -f "$f" ] && [ ! -L "$f" ] && [ -x "$f" ] && printf '%s\n' "$name"
      done
}

# Layer P: a himmel tree must pass P, with no fallback to U. The file judged is the one the
# session loads, <dir>/.claude/settings.json (a subdirectory without one is refused). P passes
# when the anchor's own checker finds nothing to rewrite once the branch's added hooks are set
# aside, or when the file is byte-equal to a
# blob main carried since the folder's merge-base (a worktree cut before main added hooks).
if [ -n "$top" ] && [ -f "$top/scripts/hooks/wire-hook-bash.mjs" ]; then
  settings="$dir/.claude/settings.json"
  if [ "$dir" != "$top" ] && [ ! -f "$settings" ]; then
    refuse "not a git work tree root (launch from $top)"
  fi
  added=()
  while IFS= read -r name; do added+=("$name"); done < <(hooks_added_by_branch)
  if [ -f "$settings" ] \
     && { node "$HERE/launch-guard-p.mjs" "$anchor" "$settings" ${added[@]+"${added[@]}"} >/dev/null 2>&1 \
          || settings_on_main_history "$settings"; }; then
    echo "guarded: project $dir"
    exit 0
  fi
  refuse "himmel hook chain differs from main (rebase onto main, or launch with UNGUARDED_LAUNCH_OK=1)"
fi

# Layer U.
[ -n "$top" ] || refuse "not a git work tree"
primary="$(primary_checkout_root "$dir" 2>/dev/null)" || primary=""
[ -n "$primary" ] || refuse "not a git work tree"
_reg_rc=0
bash "$anchor/scripts/handover/register-state.sh" --check --repo-path "$primary" >/dev/null 2>&1 || _reg_rc=$?
case "$_reg_rc" in
  0) ;;
  2) refuse "handover registry unreadable" ;;
  *) refuse "repo not registered" ;;
esac
is_state_repo "$primary" && refuse "single-writer state repo"

status="$(HIMMEL_REPO="$anchor" CLAUDE_USER_SETTINGS="$(claude_config_dir)/settings.json" \
  node "$anchor/scripts/hooks/guardrail-block.mjs" status --json 2>/dev/null)" || status=""
complete="$(printf '%s' "$status" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(String(JSON.parse(s).complete===true))}catch(e){process.stdout.write("false")}})' 2>/dev/null)"
[ "$complete" = "true" ] || refuse "user guard layer incomplete (run himmelctl ensure)"
echo "guarded: user-layer $dir"
exit 0
