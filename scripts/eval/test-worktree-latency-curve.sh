#!/usr/bin/env bash
# test-worktree-latency-curve.sh: worktree-latency-curve.sh prints one TSV row
# per step with numeric latencies, refuses a --max below the largest step, and
# leaves no scratch behind. Scratch repo + scratch HOME; no network.
#
# Bash 3.2-safe; shellcheck-clean.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/worktree-latency-curve.sh"

PASS=0
FAIL=0
_pass() { printf 'PASS  %s\n' "$1"; PASS=$(( PASS + 1 )); }
_fail() { printf 'FAIL  %s\n  -> %s\n' "$1" "$2"; FAIL=$(( FAIL + 1 )); }

TMPBASE="${TMPDIR:-/tmp}/test-wlc-$$"
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

# Scratch root the tool must create its repo under, and must clean up.
export TMPDIR="$TMPBASE/scratch"
mkdir -p "$TMPDIR"

NAME="--steps 2,4 --max 4: header plus 2 rows, numeric latencies"
rc=0; bash "$SUT" --steps 2,4 --max 4 >"$TMPBASE/out" 2>"$TMPBASE/err" || rc=$?
rows=$(grep -vc '^#' "$TMPBASE/out" || true)
bad=$(grep -v '^#' "$TMPBASE/out" | grep -vcE '^[0-9]+(	[0-9]+(\.[0-9]+)?){4}$' || true)
if [ "$rc" -eq 0 ] && [ "$rows" -eq 2 ] && [ "$bad" -eq 0 ] \
    && [ "$(grep -v '^#' "$TMPBASE/out" | cut -f1 | tr '\n' ,)" = "2,4," ]; then
    _pass "$NAME"
else
    _fail "$NAME" "rc=$rc rows=$rows bad=$bad out=[$(cat "$TMPBASE/out")] err=[$(cat "$TMPBASE/err")]"
fi

NAME="header line names the four operations"
if grep -q '^#.*list.*status.*add.*remove' "$TMPBASE/out"; then
    _pass "$NAME"
else
    _fail "$NAME" "out=[$(cat "$TMPBASE/out")]"
fi

NAME="scratch repo removed on exit"
left=$(find "$TMPDIR" -mindepth 1 -maxdepth 1 | wc -l)
if [ "$left" -eq 0 ]; then
    _pass "$NAME"
else
    _fail "$NAME" "left=$left: $(ls "$TMPDIR")"
fi

NAME="--max below the largest step refuses with rc 2, no rows"
rc=0; bash "$SUT" --steps 2,4 --max 3 >"$TMPBASE/out" 2>"$TMPBASE/err" || rc=$?
if [ "$rc" -eq 2 ] && [ "$(grep -vc '^#' "$TMPBASE/out" || true)" -eq 0 ]; then
    _pass "$NAME"
else
    _fail "$NAME" "rc=$rc out=[$(cat "$TMPBASE/out")]"
fi

NAME="non-numeric step refuses with rc 2"
rc=0; bash "$SUT" --steps 2,x --max 4 >"$TMPBASE/out" 2>"$TMPBASE/err" || rc=$?
if [ "$rc" -eq 2 ]; then
    _pass "$NAME"
else
    _fail "$NAME" "rc=$rc"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
