#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # SC2015: A && _pass || _fail is the row idiom (_pass always succeeds); SC2016: the hook body is literal text
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS=0
FAIL=0
_pass() { printf 'PASS  %s\n' "$1"; PASS=$(( PASS + 1 )); }
_fail() { printf 'FAIL  %s\n  -> %s\n' "$1" "$2"; FAIL=$(( FAIL + 1 )); }

TMPBASE="${TMPDIR:-/tmp}/test-wtresume-$$"
mkdir -p "$TMPBASE"
trap 'rm -rf "$TMPBASE"' EXIT

export HOME="$TMPBASE/home"
mkdir -p "$HOME"
export XDG_CONFIG_HOME="$HOME/.config"
export GIT_CONFIG_NOSYSTEM=1
unset GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR \
    GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES REUSE_MERGED_BRANCH_OK
export GIT_TERMINAL_PROMPT=0

GH_CMD="$TMPBASE/gh-fake.sh"
printf '#!/bin/sh\ncase "${FAKE_GH:-none}" in\n  merged) echo 1 ;;\n  none) echo 0 ;;\n  *) exit 1 ;;\nesac\n' > "$GH_CMD"
chmod +x "$GH_CMD"
export GH_CMD FORGE=github FAKE_GH=none

ORIGIN="$TMPBASE/origin.git"
git init -q --bare "$ORIGIN"
REPO="$TMPBASE/repo"
git clone -q "$ORIGIN" "$REPO" 2>/dev/null
git -C "$REPO" config user.email "test@test.local"
git -C "$REPO" config user.name "Test"
git -C "$REPO" checkout -q -b main
cp -R "$SCRIPT_DIR" "$REPO/scripts"
git -C "$REPO" add scripts
git -C "$REPO" commit -q -m "init"
git -C "$REPO" push -q origin HEAD:main
git -C "$REPO" remote set-head origin main
WT="$REPO/scripts/worktree.sh"

OUT="$TMPBASE/out"
ERR="$TMPBASE/err"
rc=0
run() { rc=0; ( cd "$REPO" && "$@" ) >"$OUT" 2>"$ERR" || rc=$?; }
wt_dir() { printf '%s/.claude/worktrees/%s' "$REPO" "${1//\//+}"; }
g() { git -C "$REPO" "$@"; }
snap() { { g for-each-ref refs/heads; g worktree list --porcelain; } 2>&1; }

mk_commit() {
    printf '%s\n' "$2" > "$1/$2"; git -C "$1" add "$2"; git -C "$1" commit -q -m "$2"
}
push_branch() {
    local b="$1" f="$2"
    g branch -q -f "$b" main
    git -C "$REPO" worktree add -q "$TMPBASE/seed" "$b" >/dev/null 2>&1
    mk_commit "$TMPBASE/seed" "$f"
    git -C "$TMPBASE/seed" push -q origin "$b"
    git -C "$REPO" worktree remove --force "$TMPBASE/seed"
    g branch -q -D "$b"
    g update-ref -d "refs/remotes/origin/$b" 2>/dev/null || true
}
origin_tip() { git -C "$ORIGIN" rev-parse "refs/heads/$1"; }

refused() {
    local name="$1" word="$2"
    if [ "$rc" -eq 1 ] && grep -Fq "$word" "$ERR"; then _pass "$name"
    else _fail "$name" "rc=$rc out=[$(cat "$OUT")] err=[$(cat "$ERR")]"; fi
}

B=fix/r-only-origin
push_branch "$B" f1
run bash "$WT" resume "$B" --no-install
tip="$(origin_tip "$B")"
if [ "$rc" -eq 0 ] && [ "$(git -C "$(wt_dir $B)" rev-parse HEAD 2>/dev/null)" = "$tip" ] \
    && grep -Fq "RESUMED $(wt_dir $B) $B $tip only-origin" "$OUT" \
    && [ "$(g config --get "branch.$B.merge")" = "refs/heads/$B" ]; then _pass "only-origin: attaches at the origin tip, tracking set"
else _fail "only-origin: attaches at the origin tip, tracking set" "rc=$rc out=[$(cat "$OUT")] err=[$(cat "$ERR")]"; fi

g worktree remove --force "$(wt_dir $B)"
run bash "$WT" resume "$B" --no-install
if [ "$rc" -eq 0 ] && grep -Fq " $tip equal" "$OUT"; then _pass "equal: attaches the local branch"
else _fail "equal: attaches the local branch" "rc=$rc out=[$(cat "$OUT")] err=[$(cat "$ERR")]"; fi

mk_commit "$(wt_dir $B)" ahead1
localtip="$(git -C "$(wt_dir $B)" rev-parse HEAD)"
g worktree remove --force "$(wt_dir $B)"
run bash "$WT" resume "$B" --no-install
if [ "$rc" -eq 0 ] && grep -Fq "local ahead of origin by 1" "$OUT" && grep -Fq " $localtip ahead" "$OUT" \
    && [ "$(git -C "$(wt_dir $B)" rev-parse HEAD)" = "$localtip" ]; then _pass "ahead: attaches local, says by how many"
else _fail "ahead: attaches local, says by how many" "rc=$rc out=[$(cat "$OUT")] err=[$(cat "$ERR")]"; fi

g worktree remove --force "$(wt_dir $B)"
git -C "$TMPBASE/seed2" status >/dev/null 2>&1 || git clone -q "$ORIGIN" "$TMPBASE/seed2" 2>/dev/null
git -C "$TMPBASE/seed2" config user.email t@t.local; git -C "$TMPBASE/seed2" config user.name T
git -C "$TMPBASE/seed2" checkout -q "$B"
mk_commit "$TMPBASE/seed2" origin-side
git -C "$TMPBASE/seed2" push -q origin "$B"
before="$(snap)"
run bash "$WT" resume "$B" --no-install
refused "diverged: refused naming the state" "diverged"
if [ "$before" = "$(snap)" ] && [ ! -e "$(wt_dir $B)" ]; then _pass "diverged: nothing created, no ref moved"
else _fail "diverged: nothing created, no ref moved" "snapshot changed"; fi
if grep -Fq "$localtip" "$ERR" && grep -Fq "$(origin_tip $B)" "$ERR"; then _pass "diverged: names both shas"
else _fail "diverged: names both shas" "err=[$(cat "$ERR")]"; fi

B2=fix/r-behind
push_branch "$B2" b1
run bash "$WT" resume "$B2" --no-install
g worktree remove --force "$(wt_dir $B2)"
git -C "$TMPBASE/seed2" fetch -q origin
git -C "$TMPBASE/seed2" checkout -q -B "$B2" "origin/$B2"
mk_commit "$TMPBASE/seed2" b2
git -C "$TMPBASE/seed2" push -q origin "$B2"
run bash "$WT" resume "$B2" --no-install
tip2="$(origin_tip "$B2")"
if [ "$rc" -eq 0 ] && grep -Fq " $tip2 behind-ff" "$OUT" && [ "$(g rev-parse "refs/heads/$B2")" = "$tip2" ] \
    && [ "$(git -C "$(wt_dir $B2)" rev-parse HEAD)" = "$tip2" ]; then _pass "behind: local fast-forwarded to the origin tip"
else _fail "behind: local fast-forwarded to the origin tip" "rc=$rc out=[$(cat "$OUT")] err=[$(cat "$ERR")]"; fi

B3=fix/r-only-local
g branch -q "$B3" main
run bash "$WT" resume "$B3" --no-install
if [ "$rc" -eq 0 ] && grep -Fq " only-local" "$OUT" && grep -Fq "no remote branch" "$OUT"; then _pass "only-local: attaches, says no remote branch"
else _fail "only-local: attaches, says no remote branch" "rc=$rc out=[$(cat "$OUT")] err=[$(cat "$ERR")]"; fi

B4=fix/r-ctl
g branch -q "$B4" main
run bash "$WT" new "$B4" --no-prune --no-install
if [ "$rc" -ne 0 ] && grep -Fq "local branch" "$ERR" && [ ! -e "$(wt_dir $B4)" ]; then _pass "new-vs-resume: new still refuses a surviving local branch"
else _fail "new-vs-resume: new still refuses a surviving local branch" "rc=$rc err=[$(cat "$ERR")]"; fi

before="$(snap)"
run bash "$WT" resume fix/r-nowhere --no-install
refused "missing: refused, names worktree.sh new" "worktree.sh new"
[ "$before" = "$(snap)" ] && _pass "missing: nothing changed" || _fail "missing: nothing changed" "snapshot changed"

mkdir -p "$(wt_dir fix/r-pathx)"
run bash "$WT" resume fix/r-pathx --no-install
refused "path-exists" "path-exists"
rmdir "$(wt_dir fix/r-pathx)"

run bash "$WT" resume "$B2" --no-install
if [ "$rc" -eq 0 ] && grep -Fxq "RESUMED $(wt_dir $B2) $B2 $tip2 equal" "$OUT"; then _pass "registered at the path: handed back"
else _fail "registered at the path: handed back" "rc=$rc out=[$(cat "$OUT")] err=[$(cat "$ERR")]"; fi

git -C "$TMPBASE/seed2" fetch -q origin
git -C "$TMPBASE/seed2" checkout -q -B "$B2" "origin/$B2"
mk_commit "$TMPBASE/seed2" b3
git -C "$TMPBASE/seed2" push -q origin "$B2"
printf 'dirty\n' > "$(wt_dir $B2)/b1"
printf 'new\n' > "$(wt_dir $B2)/untracked"
rm -f "$(wt_dir $B2)/.claude/settings.local.json"
before="$(snap; git -C "$(wt_dir $B2)" status --porcelain)"
HIMMEL_WORKTREE_CEILING=0 run bash "$WT" resume "$B2" --no-install
if [ "$rc" -eq 0 ] && grep -Fxq "RESUMED $(wt_dir $B2) $B2 $tip2 behind-ff" "$OUT"; then _pass "uncommitted: handed back at its own HEAD, behind-ff, ceiling not applied"
else _fail "uncommitted: handed back" "rc=$rc out=[$(cat "$OUT")] err=[$(cat "$ERR")]"; fi
if [ "$rc" -eq 0 ] && [ "$before" = "$(snap; git -C "$(wt_dir $B2)" status --porcelain)" ] && [ "$(cat "$(wt_dir $B2)/b1")" = dirty ] \
    && [ "$(cat "$(wt_dir $B2)/untracked")" = new ] && [ ! -e "$(wt_dir $B2)/.claude/settings.local.json" ]; then _pass "uncommitted: files, refs and worktree list untouched"
else _fail "uncommitted: untouched" "rc=$rc status=[$(git -C "$(wt_dir $B2)" status --porcelain)]"; fi

FAKE_GH=merged run bash "$WT" resume "$B2" --no-install
refused "registered at the path, merged PR: refused before the hand-back" "REUSE_MERGED_BRANCH_OK"

rm -rf "$(wt_dir $B2)"
mkdir -p "$(wt_dir $B2)"
run bash "$WT" resume "$B2" --no-install
refused "stale registration under a plain directory: path-exists" "path-exists"
git init -q -b "$B2" "$(wt_dir $B2)"
git -C "$(wt_dir $B2)" -c user.email=t@t.local -c user.name=T commit -q --allow-empty -m unrelated
run bash "$WT" resume "$B2" --no-install
refused "stale registration under another repo on the same branch name: path-exists" "path-exists"
rm -rf "$(wt_dir $B2)"
g worktree prune

B15=fix/r-unborn
push_branch "$B15" u1
run bash "$WT" resume "$B15" --no-install
g update-ref -d "refs/heads/$B15"
run bash "$WT" resume "$B15" --no-install
if [ "$rc" -ne 0 ] && ! grep -Fq "RESUMED " "$OUT"; then _pass "registered but no readable HEAD: no RESUMED line"
else _fail "registered but no readable HEAD" "rc=$rc out=[$(cat "$OUT")] err=[$(cat "$ERR")]"; fi
g worktree remove --force "$(wt_dir $B15)"

g branch -q fix/r-other main
git -C "$REPO" worktree add -q "$(wt_dir fix/r-wrong)" fix/r-other >/dev/null 2>&1
g branch -q fix/r-wrong main
run bash "$WT" resume fix/r-wrong --no-install
refused "path holds another branch's worktree: path-exists" "path-exists"
g worktree remove --force "$(wt_dir fix/r-wrong)"

B5=fix/r-co
g branch -q "$B5" main
git -C "$REPO" worktree add -q "$TMPBASE/elsewhere" "$B5" >/dev/null 2>&1
run bash "$WT" resume "$B5" --no-install
refused "checked-out: a live registration elsewhere" "checked-out"
g worktree remove --force "$TMPBASE/elsewhere"

B6=fix/r-merged
push_branch "$B6" m1
before="$(snap)"
FAKE_GH=merged run bash "$WT" resume "$B6" --no-install
refused "merged: refused, names the override" "REUSE_MERGED_BRANCH_OK"
FAKE_GH=err run bash "$WT" resume "$B6" --no-install
refused "forge-unknown: refused, names the override" "REUSE_MERGED_BRANCH_OK"
[ "$before" = "$(snap)" ] && _pass "merged/forge-unknown: nothing changed" || _fail "merged/forge-unknown: nothing changed" "snapshot changed"

B7=fix/r-fetchfail
push_branch "$B7" ff1
g branch -q "$B7" main
g remote set-url origin "$TMPBASE/no-such-origin.git"
before="$(snap)"
run bash "$WT" resume "$B7" --no-install
refused "fetch-failed: probe fails, refused" "fetch-failed"
[ "$before" = "$(snap)" ] && [ ! -e "$(wt_dir $B7)" ] && _pass "fetch-failed: nothing created, no ref moved" || _fail "fetch-failed: nothing created, no ref moved" "snapshot changed"

run bash "$WT" resume --check "$B7"
if [ "$rc" -eq 0 ] && [ "$(cat "$OUT")" = "unknown" ]; then _pass "check-unknown: origin unreachable prints unknown, rc 0"
else _fail "check-unknown" "rc=$rc out=[$(cat "$OUT")] err=[$(cat "$ERR")]"; fi
g remote set-url origin "$ORIGIN"

before="$(snap)"; fh="$(cksum < "$REPO/.git/FETCH_HEAD" 2>/dev/null || echo none)"
run bash "$WT" resume --check "$B6"
w1="$(cat "$OUT")"
run bash "$WT" resume --check "$B3"
w2="$(cat "$OUT")"
run bash "$WT" resume --check fix/r-nowhere
w3="$(cat "$OUT")"
run bash "$WT" resume --check "$B2"
w4="$(cat "$OUT")"
if [ "$w1" = "origin" ] && [ "$w2" = "local" ] && [ "$w3" = "none" ] && [ "$w4" = "both" ]; then _pass "check: origin/local/none/both words"
else _fail "check: words" "got $w1 $w2 $w3 $w4"; fi
if [ "$before" = "$(snap)" ] && [ "$fh" = "$(cksum < "$REPO/.git/FETCH_HEAD" 2>/dev/null || echo none)" ]; then _pass "check-only: refs, worktree list and FETCH_HEAD unchanged"
else _fail "check-only: nothing written" "snapshot or FETCH_HEAD changed"; fi

B8=fix/r-stale-track
push_branch "$B8" st1
g fetch -q origin "+refs/heads/$B8:refs/remotes/origin/$B8"
git -C "$ORIGIN" update-ref -d "refs/heads/$B8"
run bash "$WT" resume "$B8" --no-install
refused "stale-tracking-none: dead tracking ref never used, refused none" "worktree.sh new"
[ ! -e "$(wt_dir $B8)" ] && [ -z "$(g for-each-ref "refs/heads/$B8")" ] && _pass "stale-tracking-none: no branch created from the dead tip" || _fail "stale-tracking-none: no branch created" "branch or worktree exists"

B9=fix/r-stale-reg
B9o=fix/r-stale-other
push_branch "$B9" sr1
push_branch "$B9o" so1
run bash "$WT" resume "$B9" --no-install
run bash "$WT" resume "$B9o" --no-install
rm -rf "$(wt_dir $B9)" "$(wt_dir $B9o)"
run bash "$WT" resume "$B9" --no-install
if [ "$rc" -eq 0 ] && grep -Fq "removed the stale registration of $B9" "$OUT" && [ -d "$(wt_dir $B9)" ]; then _pass "stale-registration: removed, then attached"
else _fail "stale-registration" "rc=$rc out=[$(cat "$OUT")] err=[$(cat "$ERR")]"; fi
wl="$(g worktree list --porcelain)"
case "$wl" in
*"$(wt_dir $B9o)"*) _pass "stale-registration: another branch's stale registration is left alone" ;;
*) _fail "stale-registration-scoped" "another branch's registration was pruned" ;;
esac
g worktree prune

B10=fix/r-ceil
push_branch "$B10" c1
run bash "$WT" resume "$B10" --no-install
g worktree remove --force "$(wt_dir $B10)"
git -C "$TMPBASE/seed2" fetch -q origin
git -C "$TMPBASE/seed2" checkout -q -B "$B10" "origin/$B10"
mk_commit "$TMPBASE/seed2" c2
git -C "$TMPBASE/seed2" push -q origin "$B10"
l_before="$(g rev-parse "refs/heads/$B10")"
HIMMEL_WORKTREE_CEILING=0 run bash "$WT" resume "$B10" --no-install
if [ "$rc" -eq 1 ] && [ "$(g rev-parse "refs/heads/$B10")" = "$l_before" ] && [ ! -e "$(wt_dir $B10)" ]; then _pass "attach-fails-after-behind: refused, local unchanged"
else _fail "attach-fails-after-behind" "rc=$rc err=[$(cat "$ERR")]"; fi

B11=fix/r-stale-local
push_branch "$B11" sl1
g fetch -q origin "+refs/heads/$B11:refs/remotes/origin/$B11"
g branch -q "$B11" "refs/remotes/origin/$B11"
git -C "$ORIGIN" update-ref -d "refs/heads/$B11"
run bash "$WT" resume "$B11" --no-install
if [ "$rc" -eq 0 ] && grep -Fq " only-local" "$OUT" && grep -Fq "no remote branch" "$OUT"; then _pass "stale-tracking-local: only-local, the dead tracking ref is not used"
else _fail "stale-tracking-local" "rc=$rc out=[$(cat "$OUT")] err=[$(cat "$ERR")]"; fi

B12=fix/r-stale-ff
push_branch "$B12" sf1
run bash "$WT" resume "$B12" --no-install
rm -rf "$(wt_dir $B12)"
g remote set-url origin "$TMPBASE/no-such-origin.git"
run bash "$WT" resume "$B12" --no-install
refused "stale-plus-fetch-failed: refused" "fetch-failed"
wl="$(g worktree list --porcelain)"
case "$wl" in
*"$(wt_dir $B12)"*) _pass "stale-plus-fetch-failed: the stale registration is still listed" ;;
*) _fail "stale-plus-fetch-failed" "registration was pruned by a refused call" ;;
esac
g remote set-url origin "$ORIGIN"
g worktree prune

B14=fix/r-ffail
push_branch "$B14" ffl1
run bash "$WT" resume "$B14" --no-install
g worktree remove --force "$(wt_dir $B14)"
git -C "$TMPBASE/seed2" fetch -q origin
git -C "$TMPBASE/seed2" checkout -q -B "$B14" "origin/$B14"
mk_commit "$TMPBASE/seed2" ffl2
git -C "$TMPBASE/seed2" push -q origin "$B14"
l_before="$(g rev-parse "refs/heads/$B14")"
mkdir -p "$TMPBASE/hooks"
printf '#!/bin/sh\ntouch "$(git rev-parse --git-dir)/index.lock"\n' > "$TMPBASE/hooks/post-checkout"
chmod +x "$TMPBASE/hooks/post-checkout"
g config core.hooksPath "$TMPBASE/hooks"
run bash "$WT" resume "$B14" --no-install
g config --unset core.hooksPath
if [ "$rc" -eq 1 ] && grep -Fq "ff-failed" "$ERR" && [ ! -e "$(wt_dir $B14)" ] && [ "$(g rev-parse "refs/heads/$B14")" = "$l_before" ]; then _pass "ff-failed: refused, worktree removed, local unchanged"
else _fail "ff-failed" "rc=$rc err=[$(cat "$ERR")]"; fi

B13=fix/r-fetchonly
git -C "$TMPBASE/seed2" fetch -q origin
git -C "$TMPBASE/seed2" checkout -q -B "$B13" origin/main
mk_commit "$TMPBASE/seed2" fo1
git -C "$TMPBASE/seed2" push -q origin "$B13"
tipf="$(origin_tip "$B13")"
rm -f "$ORIGIN/objects/${tipf:0:2}/${tipf:2}"
rcl=0; git ls-remote --heads "$ORIGIN" "refs/heads/$B13" >/dev/null 2>&1 || rcl=$?
git init -q "$TMPBASE/trial"
rcf=0; git -C "$TMPBASE/trial" fetch -q "$ORIGIN" "refs/heads/$B13" >/dev/null 2>&1 || rcf=$?
if [ "$rcl" -eq 0 ] && [ "$rcf" -ne 0 ]; then
    before="$(snap)"
    run bash "$WT" resume "$B13" --no-install
    refused "fetch-only-failed: refused" "fetch-failed"
    [ "$before" = "$(snap)" ] && _pass "fetch-only-failed: nothing created, no ref moved" || _fail "fetch-only-failed" "snapshot changed"
else _fail "fetch-only-failed fixture" "ls-remote rc=$rcl, trial fetch rc=$rcf (fixture not proven)"; fi

echo ""
printf 'Results: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
