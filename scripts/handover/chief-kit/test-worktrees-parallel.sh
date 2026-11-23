#!/usr/bin/env bash
# test-worktrees-parallel.sh: worktrees-parallel.sh creates N worktrees in one
# call with a bounded fan-out, one result line per item, and refuses the whole
# call before creating any when one branch has a type worktree.sh rejects.
# Scratch origin + scratch HOME; a stub npm sleeps so timing rows are
# deterministic, not load-sensitive.
#
# Bash 3.2-safe; shellcheck-clean.

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
# shellcheck disable=SC2064
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
mkdir -p "$STUB" "$TMPBASE/live"
cat > "$STUB/npm" <<STUBNPM
#!/bin/sh
mkdir -p "$TMPBASE/live"
: > "$TMPBASE/live/\$\$"
n=\$(ls "$TMPBASE/live" | wc -l | tr -d ' ')
echo "\$n" >> "$TMPBASE/concurrency"
sleep "\${NPM_STUB_SLEEP:-1}"
rm -f "$TMPBASE/live/\$\$"
case "\$PWD" in *fail-npm*) exit 1 ;; esac
exit 0
STUBNPM
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
now() { date +%s; }

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

NAME="4 worktrees in one call take less wall time than 4 serial calls"
export NPM_STUB_SLEEP=2
s=$(now)
for b in fix/ser-a fix/ser-b fix/ser-c fix/ser-d; do
    ( cd "$REPO" && bash scripts/worktree.sh new "$b" --no-prune ) >/dev/null 2>&1
done
serial=$(( $(now) - s ))
s=$(now)
rc=0; run_par --no-prune fix/par-a fix/par-b fix/par-c fix/par-d || rc=$?
par=$(( $(now) - s ))
if [ "$rc" -eq 0 ] && [ "$serial" -ge 8 ] && [ "$par" -lt "$serial" ] && [ "$par" -lt 8 ]; then
    _pass "$NAME (serial ${serial}s, parallel ${par}s)"
else
    _fail "$NAME" "rc=$rc serial=${serial}s parallel=${par}s out=[$(cat "$TMPBASE/out")] err=[$(cat "$TMPBASE/err")]"
fi

NAME="a failing item is reported while the other three are created"
export NPM_STUB_SLEEP=1
rc=0; run_par --no-prune fix/ok-a fix/fail-npm fix/ok-b fix/ok-c || rc=$?
if [ "$rc" -ne 0 ] && [ -d "$(wt fix/ok-a)" ] && [ -d "$(wt fix/ok-b)" ] && [ -d "$(wt fix/ok-c)" ] \
    && grep -q '^FAIL fix/fail-npm ' "$TMPBASE/out" && [ "$(grep -c '^OK ' "$TMPBASE/out")" -eq 3 ]; then
    _pass "$NAME"
else
    _fail "$NAME" "rc=$rc out=[$(cat "$TMPBASE/out")] err=[$(cat "$TMPBASE/err")]"
fi

NAME="the fan-out cap is respected (--fan-out 2: at most 2 at once, and 2 reached)"
rm -f "$TMPBASE/concurrency"
rc=0; run_par --no-prune --fan-out 2 fix/cap-a fix/cap-b fix/cap-c fix/cap-d || rc=$?
max=$(sort -n "$TMPBASE/concurrency" 2>/dev/null | tail -1 || true)
if [ "$rc" -eq 0 ] && [ "${max:-0}" -eq 2 ] && [ "$(grep -c '^OK ' "$TMPBASE/out")" -eq 4 ]; then
    _pass "$NAME"
else
    _fail "$NAME" "rc=$rc max=${max:-none} out=[$(cat "$TMPBASE/out")] err=[$(cat "$TMPBASE/err")]"
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
rm -f "$TMPBASE/concurrency"
rc=0; run_par --no-prune fix/def-a fix/def-b fix/def-c fix/def-d fix/def-e fix/def-f || rc=$?
max=$(sort -n "$TMPBASE/concurrency" 2>/dev/null | tail -1 || true)
if [ "$rc" -eq 0 ] && [ "${max:-0}" -eq 4 ]; then
    _pass "$NAME"
else
    _fail "$NAME" "rc=$rc max=${max:-none} out=[$(cat "$TMPBASE/out")]"
fi

echo ""
printf 'Results: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
