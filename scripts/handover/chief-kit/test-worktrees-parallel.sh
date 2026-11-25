#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PAR="$SCRIPT_DIR/worktrees-parallel.sh"

PASS=0
FAIL=0
_pass() { printf 'PASS  %s\n' "$1"; PASS=$(( PASS + 1 )); }
_fail() { printf 'FAIL  %s\n  -> %s\n' "$1" "$2"; FAIL=$(( FAIL + 1 )); }

TMPBASE="${TMPDIR:-/tmp}/test-wtpar-$$"
mkdir -p "$TMPBASE"
TMPBASE="$(cd "$TMPBASE" && pwd -P)"
trap 'rm -rf "$TMPBASE"' EXIT

export HOME="$TMPBASE/home"
mkdir -p "$HOME"
export XDG_CONFIG_HOME="$HOME/.config"
export GIT_CONFIG_NOSYSTEM=1
unset GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
    GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
unset FORGE HIMMEL_WORKTREE_CEILING
GH_CMD="$TMPBASE/gh-tripwire.sh"
printf '#!/bin/sh\nexit 1\n' > "$GH_CMD"
chmod +x "$GH_CMD"
export GH_CMD

STUB="$TMPBASE/stub"
mkdir -p "$STUB"
printf '#!/bin/sh\nexit 0\n' > "$STUB/npm"
chmod +x "$STUB/npm"
export PATH="$STUB:$PATH"

ORIGIN="$TMPBASE/origin.git"
git init -q --bare "$ORIGIN"
REPO="$TMPBASE/repo"
git clone -q "$ORIGIN" "$REPO" 2>/dev/null
git -C "$REPO" config user.email "test@test.local"
git -C "$REPO" config user.name "Test"
git -C "$REPO" checkout -q -b main
mkdir -p "$REPO/scripts/jira" "$REPO/scripts/handover/chief-kit"
for f in worktree.sh _new-worktree.sh; do cp "$REPO_ROOT/scripts/$f" "$REPO/scripts/$f"; done
cp -R "$REPO_ROOT/scripts/lib" "$REPO/scripts/lib"
cp -R "$REPO_ROOT/scripts/guardrails" "$REPO/scripts/guardrails"
cp "$PAR" "$REPO/scripts/handover/chief-kit/worktrees-parallel.sh" 2>/dev/null || true
printf '{"name":"stub","version":"0.0.0"}\n' > "$REPO/scripts/jira/package.json"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "init"
git -C "$REPO" push -q origin HEAD:main 2>/dev/null
git -C "$REPO" remote set-head origin main

FIX_PAR="$REPO/scripts/handover/chief-kit/worktrees-parallel.sh"
run_par() { ( cd "$REPO" && bash "$FIX_PAR" "$@" ) >"$TMPBASE/out" 2>"$TMPBASE/err"; }
wt() { printf '%s/.claude/worktrees/%s' "$REPO" "$(printf '%s' "$1" | tr '/' '+')"; }

REPO2="$TMPBASE/repo2"
git clone -q -b main "$ORIGIN" "$REPO2" 2>/dev/null
git -C "$REPO2" remote set-head origin main
cat > "$REPO2/scripts/worktree.sh" <<'STUBWT'
#!/usr/bin/env bash
branch="$2"
echo "S $branch" >> "$WTSTUB_EVENTS"
: > "$WTSTUB_STARTED/${branch//\//+}"
if [ -n "${WTSTUB_BARRIER:-}" ]; then
    tries="${WTSTUB_BARRIER_TRIES:-600}"
    while [ "$(ls "$WTSTUB_STARTED" | wc -l | tr -d ' ')" -lt "$WTSTUB_BARRIER" ] && [ "$tries" -gt 0 ]; do
        sleep 0.1
        tries=$(( tries - 1 ))
    done
    hold="${WTSTUB_HOLD_TRIES:-0}"
    while [ "$hold" -gt 0 ]; do
        sleep 0.1
        hold=$(( hold - 1 ))
    done
fi
case "$branch" in
    *fail-stub*) echo "E $branch" >> "$WTSTUB_EVENTS"; echo "ERR new-worktree: injected failure" >&2; exit 1 ;;
esac
mkdir -p "$(dirname "$0")/../.claude/worktrees/${branch//\//+}"
echo "E $branch" >> "$WTSTUB_EVENTS"
exit 0
STUBWT
FIX_PAR2="$REPO2/scripts/handover/chief-kit/worktrees-parallel.sh"
run_par2() {
    rm -rf "$TMPBASE/started"; mkdir -p "$TMPBASE/started"
    : > "$TMPBASE/events"
    ( cd "$REPO2" && WTSTUB_EVENTS="$TMPBASE/events" WTSTUB_STARTED="$TMPBASE/started" \
        bash "$FIX_PAR2" "$@" ) >"$TMPBASE/out" 2>"$TMPBASE/err"
}

NAME="a list with design/x among three valid items creates none and names design/x"
rc=0; run_par --no-prune fix/bt-a design/x fix/bt-b fix/bt-c || rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$(wt fix/bt-a)" ] && [ ! -e "$(wt fix/bt-b)" ] && [ ! -e "$(wt fix/bt-c)" ] \
    && grep -Fq "design/x" "$TMPBASE/out" "$TMPBASE/err" \
    && grep -Fq "feat|fix|chore|docs|refactor|test" "$TMPBASE/out" "$TMPBASE/err"; then
    _pass "$NAME"
else
    _fail "$NAME" "rc=$rc out=[$(cat "$TMPBASE/out")] err=[$(cat "$TMPBASE/err")]"
fi

NAME="the same list with docs/x creates all four (positive control)"
rc=0; run_par --no-prune fix/bt-a docs/x fix/bt-b fix/bt-c || rc=$?
if [ "$rc" -eq 0 ] && [ -d "$(wt fix/bt-a)" ] && [ -d "$(wt docs/x)" ] && [ -d "$(wt fix/bt-b)" ] && [ -d "$(wt fix/bt-c)" ] \
    && [ "$(grep -c '^OK ' "$TMPBASE/out")" -eq 4 ]; then
    _pass "$NAME"
else
    _fail "$NAME" "rc=$rc out=[$(cat "$TMPBASE/out")] err=[$(cat "$TMPBASE/err")]"
fi

NAME="each OK line names the branch and its worktree path"
if grep -Fxq "OK docs/x $(wt docs/x)" "$TMPBASE/out"; then
    _pass "$NAME"
else
    _fail "$NAME" "out=[$(cat "$TMPBASE/out")]"
fi

max_live() { awk '/^S/ { l++; if (l > m) m = l } /^E/ { l-- } END { print m + 0 }' "$TMPBASE/events"; }
starts_before_first_end() { awk '/^E/ { exit } /^S/ { n++ } END { print n + 0 }' "$TMPBASE/events"; }

NAME="4 worktrees in one call overlap: all four start before any one ends"
export WTSTUB_BARRIER=4
rc=0; run_par2 --no-prune fix/par-a fix/par-b fix/par-c fix/par-d || rc=$?
unset WTSTUB_BARRIER
sb=$(starts_before_first_end)
if [ "$rc" -eq 0 ] && [ "$sb" -eq 4 ] && [ "$(max_live)" -eq 4 ] && [ "$(grep -c '^OK ' "$TMPBASE/out")" -eq 4 ]; then
    _pass "$NAME"
else
    _fail "$NAME" "rc=$rc starts-before-first-end=$sb events=[$(tr '\n' ' ' < "$TMPBASE/events")] out=[$(cat "$TMPBASE/out")] err=[$(cat "$TMPBASE/err")]"
fi

NAME="a failing item is reported while the other three are created"
rc=0; run_par2 --no-prune fix/ok-a fix/fail-stub fix/ok-b fix/ok-c || rc=$?
if [ "$rc" -ne 0 ] && [ -d "$REPO2/.claude/worktrees/fix+ok-a" ] && [ -d "$REPO2/.claude/worktrees/fix+ok-b" ] && [ -d "$REPO2/.claude/worktrees/fix+ok-c" ] \
    && grep -Fxq 'FAIL fix/fail-stub new-worktree: injected failure' "$TMPBASE/out" && [ "$(grep -c '^OK ' "$TMPBASE/out")" -eq 3 ]; then
    _pass "$NAME"
else
    _fail "$NAME" "rc=$rc out=[$(cat "$TMPBASE/out")] err=[$(cat "$TMPBASE/err")]"
fi

NAME="the fan-out cap is respected (--fan-out 2: at most 2 at once, and 2 reached)"
export WTSTUB_BARRIER=2 WTSTUB_HOLD_TRIES=10
rc=0; run_par2 --no-prune --fan-out 2 fix/cap-a fix/cap-b fix/cap-c fix/cap-d || rc=$?
unset WTSTUB_BARRIER WTSTUB_HOLD_TRIES
max=$(max_live)
if [ "$rc" -eq 0 ] && [ "$max" -eq 2 ] && [ "$(grep -c '^OK ' "$TMPBASE/out")" -eq 4 ]; then
    _pass "$NAME"
else
    _fail "$NAME" "rc=$rc max=$max events=[$(tr '\n' ' ' < "$TMPBASE/events")] out=[$(cat "$TMPBASE/out")] err=[$(cat "$TMPBASE/err")]"
fi

NAME="--fan-out 0 and 00 are refused (xargs -P 0 is unbounded), nothing created"
ok=1
for z in 0 00; do
    rc=0; run_par --no-prune --fan-out "$z" fix/zero-a || rc=$?
    { [ "$rc" -eq 2 ] && [ ! -e "$(wt fix/zero-a)" ]; } || ok=0
done
if [ "$ok" -eq 1 ]; then
    _pass "$NAME"
else
    _fail "$NAME" "rc=$rc err=[$(cat "$TMPBASE/err")]"
fi

NAME="the default fan-out is 4"
export WTSTUB_BARRIER=4 WTSTUB_HOLD_TRIES=10
rc=0; run_par2 --no-prune fix/def-a fix/def-b fix/def-c fix/def-d fix/def-e fix/def-f || rc=$?
unset WTSTUB_BARRIER WTSTUB_HOLD_TRIES
max=$(max_live)
if [ "$rc" -eq 0 ] && [ "$max" -eq 4 ] && [ "$(grep -c '^OK ' "$TMPBASE/out")" -eq 6 ]; then
    _pass "$NAME"
else
    _fail "$NAME" "rc=$rc max=$max events=[$(tr '\n' ' ' < "$TMPBASE/events")] out=[$(cat "$TMPBASE/out")] err=[$(cat "$TMPBASE/err")]"
fi

echo ""
printf 'Results: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
