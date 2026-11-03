#!/usr/bin/env bash
# scripts/lib/launch-guard-check.sh - does a folder a claude session would launch in
# load himmel's guard hooks? Read-only: writes nothing, runs no code from <dir>.
#
# Usage: launch-guard-check.sh <dir>
#
# Layer P (himmel tree: <toplevel>/scripts/hooks/wire-hook-bash.mjs exists): the
# toplevel's .claude/settings.json must carry the full chain (launch-guard-p.mjs).
# Layer U (anything else): the user guard layer is complete, <dir> is in a git work
# tree whose primary checkout is registered, and that checkout has no .single-writer.
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

[ "$#" -eq 1 ] && [ -n "$1" ] || { echo "usage: launch-guard-check.sh <dir>" >&2; exit 2; }
dir="$(cd -P -- "$1" 2>/dev/null && pwd)" || { echo "launch-guard-check: cannot resolve: $1" >&2; exit 2; }

refuse() { printf '%s\n' "$1"; exit 1; }

# Trust anchor (A20): HIMMEL_REPO, else the primary checkout of this script's tree.
anchor="${HIMMEL_REPO:-}"
if [ -z "$anchor" ]; then
  common="$(git -C "$HERE" rev-parse --git-common-dir 2>/dev/null)" || common=""
  [ -n "$common" ] && anchor="$(cd "$HERE" && cd "$common" 2>/dev/null && cd .. && pwd)"
  [ -n "$anchor" ] || anchor="$(cd "$HERE/../.." && pwd)"
fi
export HIMMEL_REPO="$anchor"

command -v node >/dev/null 2>&1 || refuse "node not on PATH"

lib="$anchor/scripts/guardrails/lib.sh"
[ -r "$lib" ] || refuse "anchor lib unreadable: $lib"
# shellcheck disable=SC1090
. "$lib"

top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || top=""

# Layer P: a himmel tree must pass P, with no fallback to U.
if [ -n "$top" ] && [ -f "$top/scripts/hooks/wire-hook-bash.mjs" ]; then
  if [ -f "$top/.claude/settings.json" ] \
     && node "$HERE/launch-guard-p.mjs" "$anchor" "$top/.claude/settings.json" >/dev/null 2>&1; then
    echo "guarded: project $dir"
    exit 0
  fi
  refuse "himmel hook chain incomplete"
fi

# Layer U.
[ -n "$top" ] || refuse "not a git work tree"
primary="$(primary_checkout_root "$dir" 2>/dev/null)" || primary=""
[ -n "$primary" ] || refuse "not a git work tree"
bash "$anchor/scripts/handover/register-state.sh" --check --repo-path "$primary" >/dev/null 2>&1 \
  || refuse "repo not registered"
[ ! -e "$primary/.single-writer" ] || refuse "single-writer state repo"

status="$(HIMMEL_REPO="$anchor" CLAUDE_USER_SETTINGS="$(claude_config_dir)/settings.json" \
  node "$anchor/scripts/hooks/guardrail-block.mjs" status --json 2>/dev/null)" || status=""
complete="$(printf '%s' "$status" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(String(JSON.parse(s).complete===true))}catch(e){process.stdout.write("false")}})' 2>/dev/null)"
[ "$complete" = "true" ] || refuse "user guard layer incomplete (run himmelctl ensure)"
echo "guarded: user-layer $dir"
exit 0
