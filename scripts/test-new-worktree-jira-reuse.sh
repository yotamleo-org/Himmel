#!/usr/bin/env bash
# test-new-worktree-jira-reuse.sh: a new worktree reuses the primary checkout's
# installed Jira deps when scripts/jira/package-lock.json is byte-identical, and
# still runs npm install when it differs.
#
# Self-contained: scratch HOME, scratch origin, stubbed npm, no network and no
# real install. Bash 3.2-safe.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NEW_WT="$SCRIPT_DIR/_new-worktree.sh"

PASS=0
FAIL=0
_pass() { printf 'PASS  %s\n' "$1"; PASS=$(( PASS + 1 )); }
_fail() { printf 'FAIL  %s\n  -> %s\n' "$1" "$2"; FAIL=$(( FAIL + 1 )); }

TMPBASE="${TMPDIR:-/tmp}/test-nwjr-$$"
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

STUBBIN="$TMPBASE/bin"
mkdir -p "$STUBBIN"
NPM_CALLS="$TMPBASE/npm-calls.txt"
printf '#!/bin/sh\necho "npm $*" >> "%s"\nexit 0\n' "$NPM_CALLS" > "$STUBBIN/npm"
chmod +x "$STUBBIN/npm"
export PATH="$STUBBIN:$PATH"

ORIGIN="$TMPBASE/origin.git"
git init -q --bare "$ORIGIN"
REPO="$TMPBASE/repo"
git clone -q "$ORIGIN" "$REPO"
git -C "$REPO" config user.email "test@test.local"
git -C "$REPO" config user.name "Test"
git -C "$REPO" checkout -q -b main
mkdir -p "$REPO/scripts/jira"
printf '{"name":"jira-fixture"}\n' > "$REPO/scripts/jira/package.json"
printf '{"lockfileVersion":3,"a":1}\n' > "$REPO/scripts/jira/package-lock.json"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "init"
git -C "$REPO" push -q origin HEAD:main
git -C "$REPO" remote set-head origin main

mkdir -p "$REPO/scripts/jira/node_modules/dep"
printf 'x\n' > "$REPO/scripts/jira/node_modules/dep/index.js"

new_wt() {
    ( cd "$REPO" && bash "$NEW_WT" "$1" ) >"$TMPBASE/out.txt" 2>"$TMPBASE/err.txt" \
        || { cat "$TMPBASE/out.txt" "$TMPBASE/err.txt" >&2; return 1; }
}

: > "$NPM_CALLS"
new_wt fix/nwjr-match
NAME="matching lockfile runs no npm install"
if [ ! -s "$NPM_CALLS" ]; then _pass "$NAME"; else _fail "$NAME" "calls=$(cat "$NPM_CALLS")"; fi
NAME="matching lockfile logs reused with no install"
if grep -q 'jira deps reused' "$TMPBASE/out.txt" "$TMPBASE/err.txt"; then _pass "$NAME"; else _fail "$NAME" "out=$(cat "$TMPBASE/out.txt")"; fi
NAME="matching lockfile makes the primary's node_modules reachable"
if [ -f "$REPO/.claude/worktrees/fix+nwjr-match/scripts/jira/node_modules/dep/index.js" ]; then _pass "$NAME"; else _fail "$NAME" "missing"; fi
NAME="the reused node_modules does not show as untracked"
if [ -z "$(git -C "$REPO/.claude/worktrees/fix+nwjr-match" status --porcelain -- scripts/jira)" ]; then _pass "$NAME"; else _fail "$NAME" "$(git -C "$REPO/.claude/worktrees/fix+nwjr-match" status --porcelain)"; fi

printf '{"lockfileVersion":3,"a":2}\n' > "$REPO/scripts/jira/package-lock.json"
: > "$NPM_CALLS"
new_wt fix/nwjr-differ
NAME="mismatching lockfile still runs npm install"
if grep -q '^npm install' "$NPM_CALLS"; then _pass "$NAME"; else _fail "$NAME" "calls=$(cat "$NPM_CALLS")"; fi
NAME="mismatching lockfile logs installed, not reused"
if grep -q 'jira deps installed' "$TMPBASE/out.txt" "$TMPBASE/err.txt" && ! grep -q 'reused' "$TMPBASE/out.txt" "$TMPBASE/err.txt"; then _pass "$NAME"; else _fail "$NAME" "out=$(cat "$TMPBASE/out.txt")"; fi

printf '{"lockfileVersion":3,"a":1}\n' > "$REPO/scripts/jira/package-lock.json"
printf '{"name":"jira-fixture","changed":true}\n' > "$REPO/scripts/jira/package.json"
: > "$NPM_CALLS"
new_wt fix/nwjr-pkgdiffer
NAME="matching lockfile but differing package.json still runs npm install"
if grep -q '^npm install' "$NPM_CALLS"; then _pass "$NAME"; else _fail "$NAME" "calls=$(cat "$NPM_CALLS")"; fi

echo ""
printf 'Results: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
