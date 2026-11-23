#!/usr/bin/env bash
# worktrees-parallel.sh — create N worktrees in one call, at most --fan-out at once.
#
# Usage:
#   worktrees-parallel.sh [--fan-out N] [--no-prune] [--no-install] <branch>...
#
# Every branch name is checked first by `_new-worktree.sh --check-name` (the one
# place the accepted types live); one bad name refuses the whole call and no
# worktree is created. Then, unless --no-prune, `worktree.sh prune` runs once,
# origin's default branch is fetched once, and each item runs
# `worktree.sh new <branch> --no-prune --no-fetch` with at most N (default 4)
# running together. The per-item ceiling check and its creation lock still
# apply to every item.
#
# Output: one line per item, in input order:
#   OK <branch> <worktree path>
#   FAIL <branch> <reason>
# Exit 0 when every item was created, 1 when any failed or was refused, 2 on
# a usage error. One item's failure never stops the others.
#
# Bash 3.2-safe.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 2
SCRIPTS="$(cd "$SCRIPT_DIR/../.." && pwd)" || exit 2
# shellcheck source=../../lib/prim.sh
. "$SCRIPTS/lib/prim.sh" || exit 2
# shellcheck source=../../lib/git-clean.sh
. "$SCRIPTS/lib/git-clean.sh" || exit 2
git_env_scrub

if [ "${1:-}" = "__item" ]; then
    out_dir="$2"; idx="$3"; branch="$4"
    extra=()
    [ "${WTPAR_NO_INSTALL:-0}" = 1 ] && extra+=("--no-install")
    rc=0
    bash "$SCRIPTS/worktree.sh" new "$branch" --no-prune --no-fetch ${extra[@]+"${extra[@]}"} \
        >"$out_dir/$idx.out" 2>"$out_dir/$idx.err" || rc=$?
    echo "$rc" > "$out_dir/$idx.rc"
    exit 0
fi

usage() {
    echo "Usage: worktrees-parallel.sh [--fan-out N] [--no-prune] [--no-install] <branch>..." >&2
    exit 2
}

FAN_OUT=4
NO_PRUNE=0
WTPAR_NO_INSTALL=0
BRANCHES=()
while [ $# -gt 0 ]; do
    case "$1" in
        --fan-out)
            [ $# -ge 2 ] || usage
            FAN_OUT="$2"; shift 2 ;;
        --no-prune) NO_PRUNE=1; shift ;;
        --no-install) WTPAR_NO_INSTALL=1; shift ;;
        -h|--help) usage ;;
        -*) echo "ERR worktrees-parallel: unknown flag: $1" >&2; usage ;;
        *) BRANCHES+=("$1"); shift ;;
    esac
done
case "$FAN_OUT" in ''|*[!0-9]*|0*) echo "ERR worktrees-parallel: --fan-out needs a positive integer" >&2; usage ;; esac
[ "${#BRANCHES[@]}" -gt 0 ] || usage

bad=0
seen=" "
for b in "${BRANCHES[@]}"; do
    case "$seen" in
        *" $b "*) echo "FAIL $b listed twice"; bad=1; continue ;;
    esac
    seen="$seen$b "
    if ! err=$(bash "$SCRIPTS/_new-worktree.sh" --check-name "$b" 2>&1); then
        echo "FAIL $b ${err#ERR new-worktree: }"
        bad=1
    fi
done
if [ "$bad" -ne 0 ]; then
    echo "ERR worktrees-parallel: refused — no worktree created; fix the names above and re-run the whole list" >&2
    exit 1
fi

COMMON_DIR=$(git rev-parse --git-common-dir) || { echo "ERR worktrees-parallel: not in a git repo" >&2; exit 1; }
PRIMARY="$(cd "$(dirname "$COMMON_DIR")" && pwd)" || exit 1

if [ "$NO_PRUNE" -eq 0 ]; then
    bash "$SCRIPTS/worktree.sh" prune >&2 || echo "WARN worktrees-parallel: prune failed; creating anyway" >&2
fi

if git -C "$PRIMARY" remote get-url origin >/dev/null 2>&1; then
    # shellcheck source=../../guardrails/lib.sh
    # shellcheck disable=SC1091
    . "$SCRIPTS/guardrails/lib.sh" || exit 1
    DEFAULT_BRANCH=$(default_branch "$PRIMARY")
    if ! git -C "$PRIMARY" fetch origin "$DEFAULT_BRANCH" --quiet; then
        for b in "${BRANCHES[@]}"; do echo "FAIL $b git fetch origin $DEFAULT_BRANCH failed"; done
        exit 1
    fi
fi

WORK=$(tmpdir) || { echo "ERR worktrees-parallel: cannot make a temp dir" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

i=0
for b in "${BRANCHES[@]}"; do
    printf '%s\0%s\0' "$i" "$b"
    i=$(( i + 1 ))
done | WTPAR_NO_INSTALL=$WTPAR_NO_INSTALL xargs -0 -n 2 -P "$FAN_OUT" bash "$SCRIPT_DIR/worktrees-parallel.sh" __item "$WORK"

failed=0
i=0
for b in "${BRANCHES[@]}"; do
    rc=missing
    [ -r "$WORK/$i.rc" ] && rc=$(cat "$WORK/$i.rc")
    if [ "$rc" = 0 ]; then
        echo "OK $b $PRIMARY/.claude/worktrees/${b//\//+}"
    else
        reason=""
        [ -r "$WORK/$i.err" ] && reason=$(awk '/^ERR / { l = $0 } END { print l }' "$WORK/$i.err")
        [ -n "$reason" ] || reason="exit $rc"
        echo "FAIL $b ${reason#ERR }"
        failed=1
    fi
    i=$(( i + 1 ))
done
exit "$failed"
