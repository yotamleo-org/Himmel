#!/usr/bin/env bash
# test-new-worktree-ceiling.sh: _new-worktree.sh refuses to create a worktree
# once the live count under .claude/worktrees reaches HIMMEL_WORKTREE_CEILING
# (refuse, never degrade). Real scratch origin + scratch HOME; no network.
#
# Bash 3.2-safe; shellcheck-clean.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NEW_WT="$SCRIPT_DIR/_new-worktree.sh"

PASS=0
FAIL=0
_pass() { printf 'PASS  %s\n' "$1"; PASS=$(( PASS + 1 )); }
_fail() { printf 'FAIL  %s\n  -> %s\n' "$1" "$2"; FAIL=$(( FAIL + 1 )); }

TMPBASE="${TMPDIR:-/tmp}/test-nwc-$$"
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
unset FORGE GH_CMD HIMMEL_WORKTREE_CEILING
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

mk() { ( cd "$REPO" && bash "$NEW_WT" "$1" --no-install ) >"$TMPBASE/out" 2>"$TMPBASE/err"; }

NAME="under the ceiling: first worktree is created"
rc=0; HIMMEL_WORKTREE_CEILING=1 mk fix/nwc-one || rc=$?
if [ "$rc" -eq 0 ] && [ -d "$REPO/.claude/worktrees/fix+nwc-one" ]; then
    _pass "$NAME"
else
    _fail "$NAME" "rc=$rc err=[$(cat "$TMPBASE/err")]"
fi

NAME="at the ceiling: second worktree is refused, nothing created"
rc=0; HIMMEL_WORKTREE_CEILING=1 mk fix/nwc-two || rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$REPO/.claude/worktrees/fix+nwc-two" ] \
    && grep -Fq "worktree ceiling" "$TMPBASE/err"; then
    _pass "$NAME"
else
    _fail "$NAME" "rc=$rc err=[$(cat "$TMPBASE/err")]"
fi

NAME="raising the ceiling lets the same branch through"
rc=0; HIMMEL_WORKTREE_CEILING=2 mk fix/nwc-two || rc=$?
if [ "$rc" -eq 0 ] && [ -d "$REPO/.claude/worktrees/fix+nwc-two" ]; then
    _pass "$NAME"
else
    _fail "$NAME" "rc=$rc err=[$(cat "$TMPBASE/err")]"
fi

NAME="default ceiling (unset env) does not refuse a small fleet"
rc=0; mk fix/nwc-three || rc=$?
if [ "$rc" -eq 0 ]; then
    _pass "$NAME"
else
    _fail "$NAME" "rc=$rc err=[$(cat "$TMPBASE/err")]"
fi

echo ""
printf 'Results: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
