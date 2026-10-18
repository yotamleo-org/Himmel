#!/usr/bin/env bash
# test-worktree-verbs.sh: worktree.sh new|prune say what each call
# does; clean-garden.sh stays a deprecated forwarder with the same meaning.
# Real origin + scratch HOME, no network. Bash 3.2-safe.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WT="$SCRIPT_DIR/worktree.sh"
CG="$SCRIPT_DIR/clean-garden.sh"

PASS=0
FAIL=0
_pass() { printf 'PASS  %s\n' "$1"; PASS=$(( PASS + 1 )); }
_fail() { printf 'FAIL  %s\n  -> %s\n' "$1" "$2"; FAIL=$(( FAIL + 1 )); }

TMPBASE="${TMPDIR:-/tmp}/test-wtverbs-$$"
mkdir -p "$TMPBASE"
# shellcheck disable=SC2064
trap 'rm -rf "$TMPBASE"' EXIT

export HOME="$TMPBASE/home"
mkdir -p "$HOME"
export XDG_CONFIG_HOME="$HOME/.config"
export GIT_CONFIG_NOSYSTEM=1
unset GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR \
    GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES FORGE
GH_CMD="$TMPBASE/gh-tripwire.sh"
printf '#!/bin/sh\nexit 1\n' > "$GH_CMD"
chmod +x "$GH_CMD"
export GH_CMD

ORIGIN="$TMPBASE/origin.git"
git init -q --bare "$ORIGIN"
REPO="$TMPBASE/repo"
git clone -q "$ORIGIN" "$REPO" 2>/dev/null
git -C "$REPO" config user.email "test@test.local"
git -C "$REPO" config user.name "Test"
git -C "$REPO" checkout -q -b main
# worktree.sh runs _new-worktree.sh from the primary checkout, so it needs scripts/.
cp -R "$SCRIPT_DIR" "$REPO/scripts"
git -C "$REPO" add scripts
git -C "$REPO" commit -q -m "init"
git -C "$REPO" push -q origin HEAD:main
git -C "$REPO" remote set-head origin main

OUT="$TMPBASE/out"
ERR="$TMPBASE/err"
rc=0
# run <args...> — run from the fixture repo, record rc in $rc.
run() {
    rc=0
    ( cd "$REPO" && "$@" ) >"$OUT" 2>"$ERR" || rc=$?
}
wt_dir() { printf '%s/.claude/worktrees/%s' "$REPO" "${1//\//+}"; }

run bash "$WT" new fix/verb-new --no-install
if [ "$rc" -eq 0 ] && [ -d "$(wt_dir fix/verb-new)" ]; then _pass "worktree.sh new <branch> creates the worktree"
else _fail "worktree.sh new <branch> creates the worktree" "rc=$rc $(cat "$ERR")"; fi

run bash "$WT" prune --dry-run
if [ "$rc" -eq 0 ] && grep -q 'clean-garden' "$OUT" "$ERR" && [ -d "$(wt_dir fix/verb-new)" ]; then _pass "worktree.sh prune --dry-run runs the prune phase and removes nothing"
else _fail "worktree.sh prune --dry-run runs the prune phase and removes nothing" "rc=$rc $(cat "$OUT" "$ERR")"; fi

run bash "$WT" prune fix/verb-extra
if [ "$rc" -ne 0 ] && [ ! -d "$(wt_dir fix/verb-extra)" ]; then _pass "worktree.sh prune <branch> refuses and creates nothing"
else _fail "worktree.sh prune <branch> refuses and creates nothing" "rc=$rc"; fi

run bash "$WT" new --no-install
if [ "$rc" -ne 0 ]; then _pass "worktree.sh new without a branch fails"
else _fail "worktree.sh new without a branch fails" "rc=$rc"; fi

run bash "$WT" fix/verb-legacy --no-install
if [ "$rc" -eq 0 ] && [ -d "$(wt_dir fix/verb-legacy)" ]; then _pass "legacy worktree.sh <branch> still creates"
else _fail "legacy worktree.sh <branch> still creates" "rc=$rc $(cat "$ERR")"; fi

run bash "$CG" fix/verb-forward --no-install
if [ "$rc" -eq 0 ] && [ -d "$(wt_dir fix/verb-forward)" ] && grep -q 'deprecated' "$ERR" && grep -q 'worktree.sh new' "$ERR"; then _pass "clean-garden.sh <branch> still creates and names worktree.sh new on stderr"
else _fail "clean-garden.sh <branch> still creates and names worktree.sh new on stderr" "rc=$rc $(cat "$ERR")"; fi

run bash "$CG" --dry-run
if [ "$rc" -eq 0 ] && grep -q 'deprecated' "$ERR" && grep -q 'worktree.sh prune' "$ERR"; then _pass "clean-garden.sh --dry-run still prunes and names worktree.sh prune on stderr"
else _fail "clean-garden.sh --dry-run still prunes and names worktree.sh prune on stderr" "rc=$rc $(cat "$ERR")"; fi

# --health reaches the health path (read-only monitor), via the verb and the forwarder.
# Seed one stuck worktree in the sweep-health state file.
git -C "$REPO" worktree add -q "$TMPBASE/wt-stuck" -b feat/stuck >/dev/null 2>&1
mkdir -p "$REPO/.git/sweep-health"
printf '%s\t%s\t%s\t%s\n' "$TMPBASE/wt-stuck" "$(( $(date +%s) - 100 ))" 9 "uncommitted changes" > "$REPO/.git/sweep-health/stuck.tsv"

run bash "$WT" prune --health
if [ "$rc" -eq 1 ] && grep -q '^STUCK ' "$OUT" && ! grep -q 'takes no other flag' "$ERR"; then _pass "worktree.sh prune --health reaches the health path (STUCK alarm, rc 1)"
else _fail "worktree.sh prune --health reaches the health path (STUCK alarm, rc 1)" "rc=$rc $(cat "$OUT" "$ERR")"; fi

run bash "$CG" --health
if [ "$rc" -eq 1 ] && grep -q '^STUCK ' "$OUT" && grep -q 'worktree.sh prune' "$ERR"; then _pass "clean-garden.sh --health forwards to the health path"
else _fail "clean-garden.sh --health forwards to the health path" "rc=$rc $(cat "$OUT" "$ERR")"; fi

run bash "$WT" prune --health --dry-run
if [ "$rc" -eq 1 ] && grep -q 'takes no other flag' "$ERR"; then _pass "worktree.sh prune --health --dry-run still refuses"
else _fail "worktree.sh prune --health --dry-run still refuses" "rc=$rc $(cat "$OUT" "$ERR")"; fi

# No verb and no branch is a usage error (rc 2): prune only ever runs behind `prune`.
for noverb in --no-install --dry-run --verbose ''; do
    run bash "$WT" "$noverb"
    if [ "$rc" -eq 2 ] && ! grep -q 'clean-garden:' "$OUT" "$ERR"; then _pass "worktree.sh '$noverb' (no verb, no branch) exits 2 without pruning"
    else _fail "worktree.sh '$noverb' (no verb, no branch) exits 2 without pruning" "rc=$rc $(cat "$OUT" "$ERR")"; fi
done

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
