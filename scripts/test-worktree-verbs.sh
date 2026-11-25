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
# selector: names _new-worktree.sh
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

run bash "$REPO/scripts/_new-worktree.sh" --check-name design/x
if [ "$rc" -eq 1 ] && grep -Fq "design/x" "$ERR" && grep -Fq "feat|fix|chore|docs|refactor|test" "$ERR" && grep -Fq "fix: rename" "$ERR" \
    && [ ! -e "$(wt_dir design/x)" ]; then _pass "_new-worktree.sh --check-name refuses a bad type, naming the types and the fix"
else _fail "_new-worktree.sh --check-name refuses a bad type, naming the types and the fix" "rc=$rc $(cat "$ERR")"; fi

run bash "$REPO/scripts/_new-worktree.sh" --check-name docs/verb-check
if [ "$rc" -eq 0 ] && [ ! -e "$(wt_dir docs/verb-check)" ] \
    && ! git -C "$REPO" show-ref --verify --quiet refs/heads/docs/verb-check; then _pass "_new-worktree.sh --check-name accepts a good name and creates nothing"
else _fail "_new-worktree.sh --check-name accepts a good name and creates nothing" "rc=$rc $(cat "$ERR")"; fi

PUSHER="$TMPBASE/pusher"
git clone -q -b main "$ORIGIN" "$PUSHER" 2>/dev/null
git -C "$PUSHER" -c user.email=t@t -c user.name=T commit -q --allow-empty -m "moved on"
git -C "$PUSHER" push -q origin HEAD:main
OLD_TIP=$(git -C "$REPO" rev-parse origin/main)
NEW_TIP=$(git -C "$PUSHER" rev-parse HEAD)

run bash "$WT" new fix/verb-nofetch --no-prune --no-fetch --no-install
if [ "$rc" -eq 0 ] && [ "$(git -C "$(wt_dir fix/verb-nofetch)" rev-parse HEAD)" = "$OLD_TIP" ]; then _pass "worktree.sh new --no-fetch branches from the origin ref already fetched"
else _fail "worktree.sh new --no-fetch branches from the origin ref already fetched" "rc=$rc $(cat "$ERR")"; fi

run bash "$WT" new fix/verb-fetch --no-prune --no-install
if [ "$rc" -eq 0 ] && [ "$(git -C "$(wt_dir fix/verb-fetch)" rev-parse HEAD)" = "$NEW_TIP" ]; then _pass "worktree.sh new without --no-fetch still fetches origin first"
else _fail "worktree.sh new without --no-fetch still fetches origin first" "rc=$rc $(cat "$ERR")"; fi

GH_LOG="$TMPBASE/gh-calls"
GH_STUB="$TMPBASE/gh-stub.sh"
cat > "$GH_STUB" <<GHSTUB
#!/bin/sh
echo "\$*" >> "$GH_LOG"
case "\$1 \$2" in
    "auth status") exit 0 ;;
    "repo view") echo "test-owner/test-repo"; exit 0 ;;
    "api "*) exit 0 ;;
esac
exit 1
GHSTUB
chmod +x "$GH_STUB"
: > "$GH_LOG"
run env FORGE=github GH_CMD="$GH_STUB" bash "$WT" new fix/verb-nowalk --no-prune --no-fetch --no-install
if [ "$rc" -eq 0 ] && [ -d "$(wt_dir fix/verb-nowalk)" ] && ! grep -q 'pulls?state' "$GH_LOG"; then _pass "worktree.sh new --no-prune creates without walking the PR list"
else _fail "worktree.sh new --no-prune creates without walking the PR list" "rc=$rc gh=[$(cat "$GH_LOG")] $(cat "$ERR")"; fi
: > "$GH_LOG"
run env FORGE=github GH_CMD="$GH_STUB" bash "$WT" prune --dry-run
if grep -q 'pulls?state' "$GH_LOG"; then _pass "worktree.sh prune still walks the PR list"
else _fail "worktree.sh prune still walks the PR list" "rc=$rc gh=[$(cat "$GH_LOG")] $(cat "$ERR")"; fi

# No verb and no branch is a usage error (rc 2): prune only ever runs behind `prune`.
for noverb in --no-install --dry-run --verbose ''; do
    run bash "$WT" "$noverb"
    if [ "$rc" -eq 2 ] && ! grep -q 'clean-garden:' "$OUT" "$ERR"; then _pass "worktree.sh '$noverb' (no verb, no branch) exits 2 without pruning"
    else _fail "worktree.sh '$noverb' (no verb, no branch) exits 2 without pruning" "rc=$rc $(cat "$OUT" "$ERR")"; fi
done

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
