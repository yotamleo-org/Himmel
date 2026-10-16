#!/usr/bin/env bash
# scripts/handover/console-kit/test-himmel-gate.sh - suite for himmel-gate.sh,
# the single exec path for the registered gate and ledger writers.
#   1. a registered name runs the ANCHOR's copy with argv, from the caller's
#      cwd, and its rc is the caller's rc.
#   2. an unknown name, or no name, refuses (exit 2) and runs nothing.
#   3. HIMMEL_REPO unset or relative refuses.
#   4. an anchor copy that is not main's committed bytes refuses.
#   5. a piped stdout refuses, except a lone --help.
#   6. a relative entry from a linked worktree runs the anchor's gate, not the
#      branch's.
#
# Platform guard (gitbash-only): POSIX bash 3.2+.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cd "$HERE/../../.." && pwd)"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY CR_ANCHOR_HANDED_OFF

tmp="$(mktemp -d "${TMPDIR:-/tmp}/himmel-gate-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd -P)"
FAILED=0

g() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main -c commit.gpgsign=false "$@"; }

check() { # check <label> <want-rc> <got-rc>
    if [ "$2" = "$3" ]; then echo "PASS $1 (rc=$3)"; else echo "FAIL $1 - expected rc=$2, got rc=$3"; FAILED=$((FAILED + 1)); fi
}
contains() { # contains <label> <haystack> <fixed-string>
    case "$2" in *"$3"*) echo "PASS $1" ;; *) echo "FAIL $1 - '$3' not in: $2"; FAILED=$((FAILED + 1)) ;; esac
}

ORIGIN="$tmp/origin"
ANCHOR="$tmp/anchor"
WT="$tmp/wt"
mkdir -p "$ORIGIN/scripts/cr" "$ORIGIN/scripts/lib" "$ORIGIN/scripts/hooks/lib" "$ORIGIN/scripts/handover/console-kit"
g init -q "$ORIGIN"
cp "$SRC/scripts/handover/console-kit/himmel-gate.sh" "$ORIGIN/scripts/handover/console-kit/"
cp "$SRC/scripts/cr/anchor-handoff.sh" "$ORIGIN/scripts/cr/"
cp "$SRC/scripts/lib/git-clean.sh" "$ORIGIN/scripts/lib/"
cp "$SRC/scripts/hooks/lib/anchor-bytes.sh" "$ORIGIN/scripts/hooks/lib/"
# A stand-in gate: says whose copy ran, with what argv, from which cwd.
# shellcheck disable=SC2016 # written verbatim into the fixture
printf '%s\n' '#!/usr/bin/env bash' 'echo "copy=anchor argv=$* cwd=$PWD"' 'exit "${GATE_RC:-0}"' >"$ORIGIN/scripts/cr/orphan-check.sh"
g -C "$ORIGIN" add -A
g -C "$ORIGIN" commit -qm base
g clone -q "$ORIGIN" "$ANCHOR"
g -C "$ANCHOR" worktree add -q -b feat/x "$WT" refs/remotes/origin/main
GATE="$ANCHOR/scripts/handover/console-kit/himmel-gate.sh"

# runf <cwd> <command...> - run with stdout on a FILE, as the Bash tool does:
# a $(...) capture is a pipe, which the dispatcher refuses. Sets out and rc.
runf() {
    local d=$1
    shift
    (cd "$d" && "$@") >"$tmp/out" 2>&1
    rc=$?
    out=$(cat "$tmp/out")
}

# 1. registered name: anchor copy, argv, cwd, honest rc.
runf "$WT" env HIMMEL_REPO="$ANCHOR" GATE_RC=7 bash "$GATE" orphan-check 12 'a b'
check "1. registered name passes the gate's rc through" 7 "$rc"
contains "1. argv reaches the gate" "$out" "argv=12 a b"
contains "1. the gate runs from the caller's cwd" "$out" "cwd=$WT"
contains "1. the anchor's copy runs" "$out" "copy=anchor"

# 2. unknown name, no name.
runf "$WT" env HIMMEL_REPO="$ANCHOR" bash "$GATE" rm-rf
check "2. unknown name refuses" 2 "$rc"
contains "2. the refusal names the name" "$out" "'rm-rf' is not a registered gate"
runf "$WT" env HIMMEL_REPO="$ANCHOR" bash "$GATE"
check "2. no name refuses" 2 "$rc"

# 3. HIMMEL_REPO unset or relative.
runf "$WT" env -u HIMMEL_REPO bash "$GATE" orphan-check
check "3. HIMMEL_REPO unset refuses" 2 "$rc"
case "$out" in *copy=anchor*) echo "FAIL 3. the gate ran with HIMMEL_REPO unset"; FAILED=$((FAILED + 1)) ;; esac
runf "$ANCHOR" env HIMMEL_REPO=. bash "$GATE" orphan-check
check "3. relative HIMMEL_REPO refuses" 2 "$rc"

# 4. anchor copy differs from main.
echo 'echo tampered' >>"$ANCHOR/scripts/cr/orphan-check.sh"
runf "$WT" env HIMMEL_REPO="$ANCHOR" bash "$GATE" orphan-check
check "4. a dirty anchor gate refuses" 2 "$rc"
case "$out" in *tampered*) echo "FAIL 4. the dirty gate ran"; FAILED=$((FAILED + 1)) ;; esac
g -C "$ANCHOR" checkout -q -- scripts/cr/orphan-check.sh
g -C "$ANCHOR" checkout -q -b side
runf "$WT" env HIMMEL_REPO="$ANCHOR" bash "$GATE" orphan-check
check "4. an anchor off main refuses" 2 "$rc"
g -C "$ANCHOR" checkout -q main

# 5. piped stdout.
out="$(cd "$WT" && HIMMEL_REPO="$ANCHOR" bash "$GATE" orphan-check 12 2>&1 | cat)"
contains "5. a piped run refuses" "$out" "stdout is a pipe"
case "$out" in *copy=anchor*) echo "FAIL 5. the piped gate ran"; FAILED=$((FAILED + 1)) ;; esac
out="$(cd "$WT" && HIMMEL_REPO="$ANCHOR" bash "$GATE" orphan-check --help 2>&1 | cat)"
contains "5. a piped lone --help runs" "$out" "argv=--help"

# 6. relative entry from a worktree whose gate copy differs.
# shellcheck disable=SC2016 # written verbatim into the fixture
printf '%s\n' '#!/usr/bin/env bash' 'echo copy=branch' >"$WT/scripts/cr/orphan-check.sh"
runf "$WT" env HIMMEL_REPO="$ANCHOR" bash scripts/handover/console-kit/himmel-gate.sh orphan-check 3
check "6. relative entry runs" 0 "$rc"
contains "6. relative entry runs the anchor's gate" "$out" "copy=anchor argv=3"
case "$out" in *copy=branch*) echo "FAIL 6. the branch's gate ran"; FAILED=$((FAILED + 1)) ;; esac

echo
if [ "$FAILED" -eq 0 ]; then
    echo "all himmel-gate cases passed"
    exit 0
fi
echo "$FAILED himmel-gate case(s) failed"
exit 1
