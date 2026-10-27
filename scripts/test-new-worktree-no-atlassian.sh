#!/usr/bin/env bash
# test-new-worktree-no-atlassian.sh: a worktree the harness creates
# must carry its own .claude/settings.local.json with the atlassian plugin set
# false, so a session started there without a plugin profile does not inherit an
# ancestor's `atlassian: true` and record a local-scope install per worktree.
#
# Self-contained: scratch HOME, scratch origin, no network. Bash 3.2-safe.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NEW_WT="$SCRIPT_DIR/_new-worktree.sh"
ATL='atlassian@claude-plugins-official'

PASS=0
FAIL=0
_pass() { printf 'PASS  %s\n' "$1"; PASS=$(( PASS + 1 )); }
_fail() { printf 'FAIL  %s\n  -> %s\n' "$1" "$2"; FAIL=$(( FAIL + 1 )); }

TMPBASE="${TMPDIR:-/tmp}/test-nwna-$$"
mkdir -p "$TMPBASE"
# shellcheck disable=SC2064
trap 'rm -rf "$TMPBASE"' EXIT

export HOME="$TMPBASE/home"
mkdir -p "$HOME"
export XDG_CONFIG_HOME="$HOME/.config"
export GIT_CONFIG_NOSYSTEM=1
unset GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
    GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
unset FORGE GH_CMD
GH_CMD="$TMPBASE/gh-tripwire.sh"
printf '#!/bin/sh\nexit 1\n' > "$GH_CMD"
chmod +x "$GH_CMD"
export GH_CMD

ORIGIN="$TMPBASE/origin.git"
git init -q --bare "$ORIGIN"
REPO="$TMPBASE/repo"
git clone -q "$ORIGIN" "$REPO"
git -C "$REPO" config user.email "test@test.local"
git -C "$REPO" config user.name "Test"
git -C "$REPO" checkout -q -b main
git -C "$REPO" commit -q --allow-empty -m "init"
git -C "$REPO" push -q origin HEAD:main
git -C "$REPO" remote set-head origin main

new_wt() { # $1 branch ; prints the worktree path
    ( cd "$REPO" && bash "$NEW_WT" "$1" --no-install ) >"$TMPBASE/out.txt" 2>"$TMPBASE/err.txt" \
        || { cat "$TMPBASE/out.txt" "$TMPBASE/err.txt" >&2; return 1; }
    printf '%s\n' "$REPO/.claude/worktrees/${1//\//+}"
}

# 1. A fresh worktree carries atlassian=false in its own settings.local.json.
WT1="$(new_wt fix/nwna-one)"
NAME="a new worktree's settings.local.json sets $ATL false"
got="$(jq -r --arg a "$ATL" '.enabledPlugins[$a] | tostring' "$WT1/.claude/settings.local.json" 2>/dev/null || echo '(missing)')"
if [ "$got" = "false" ]; then _pass "$NAME"; else _fail "$NAME" "got=[$got]"; fi

echo ""
printf 'Results: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
