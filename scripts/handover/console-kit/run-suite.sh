#!/usr/bin/env bash
# run-suite.sh — HIMMEL-3084. Run ONE scan root of the shell-suite tree per
# call, then return. A leg blocked in one long foreground command cannot read
# its inbox, so a console HALT queues until the command ends; calling this once
# per root turns every root boundary into a turn boundary, where the inbox is
# drained. The leg types each call as its own Bash command and follows `next=`.
#
# Usage:
#   bash scripts/handover/console-kit/run-suite.sh --plan   # print the roots, run nothing
#   bash scripts/handover/console-kit/run-suite.sh          # run the FIRST root
#   bash scripts/handover/console-kit/run-suite.sh <root>   # run exactly that root
#
# Roots are the first-level directories under scripts/ holding a test-*.sh,
# in sorted order, then the pseudo-root `top` (the scripts/test-*.sh files at
# the top level, which no directory root covers). Each root runs through
# scripts/ci/run-shell-tests.sh (its own lock, SKIP_LIST and budget apply) under
# scripts/quiet-run.sh; --runner PATH swaps the scan runner (tests).
#
# Output: the quiet-run OK/ERR line, then one line
#   CHECKPOINT <i>/<n> <root> rc=<rc> next=<root|none>
# and the exit code is the root's own (2 = bad usage, an unknown root).
#
# ponytail: the checkpoint is one scan root, so the unreachable window is the
# largest root (scripts/hooks, ~140 suites), not a single suite; shard the big
# roots with run-shell-tests.sh --shard if a window that size proves too long.
# Platform guard: console kit is Linux-only by design; bash 3.2-safe.
set -uo pipefail

RUNNER=""
ROOT=""
PLAN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --plan) PLAN=1 ;;
        --runner)
            [ $# -ge 2 ] || { echo "run-suite: --runner needs a path" >&2; exit 2; }
            RUNNER="$2"; shift ;;
        -*) echo "run-suite: unknown flag: $1" >&2; exit 2 ;;
        *)
            [ -z "$ROOT" ] || { echo "run-suite: one root per call (got '$ROOT' and '$1'); the call boundary is the checkpoint" >&2; exit 2; }
            ROOT="$1" ;;
    esac
    shift
done

unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "run-suite: not in a git work tree" >&2; exit 2; }
cd "$TOP" || exit 2
# The kit's own repo, not the cwd's: tools resolve beside this script.
SELF="$(cd "$(dirname "$0")/../../.." && pwd)"
QUIET_RUN="$SELF/scripts/quiet-run.sh"
[ -n "$RUNNER" ] || RUNNER="$SELF/scripts/ci/run-shell-tests.sh"

plan() {
    git ls-files -- 'scripts/*/**' \
        | grep -E '/test-[^/]*\.sh$' \
        | awk -F/ '{print $1 "/" $2}' | sort -u
    if git ls-files -- 'scripts/test-*.sh' | grep -q .; then echo top; fi
}
PLAN_LIST="$(plan)"
N=$(printf '%s\n' "$PLAN_LIST" | grep -c .)

if [ "$PLAN" -eq 1 ]; then
    printf '%s\n' "$PLAN_LIST"
    exit 0
fi

[ "$N" -gt 0 ] || { echo "run-suite: no scan roots found" >&2; exit 2; }
[ -n "$ROOT" ] || ROOT="$(printf '%s\n' "$PLAN_LIST" | head -1)"
ROOT="${ROOT%/}"
IDX="$(printf '%s\n' "$PLAN_LIST" | grep -nxF -- "$ROOT" | head -1 | cut -d: -f1)"
[ -n "$IDX" ] || { echo "run-suite: '$ROOT' is not a scan root (see --plan)" >&2; exit 2; }
NEXT="$(printf '%s\n' "$PLAN_LIST" | sed -n "$((IDX + 1))p")"
[ -n "$NEXT" ] || NEXT=none

RC=0
if [ "$ROOT" = top ]; then
    TOP_FILES="$(git ls-files -- 'scripts/test-*.sh')"
    # shellcheck disable=SC2086  # the file list is word-split on purpose
    bash "$QUIET_RUN" suite-root -- bash -c '
        rc=0
        for f in "$@"; do bash "$f" || rc=1; done
        exit $rc' _ $TOP_FILES || RC=$?
else
    bash "$QUIET_RUN" suite-root -- bash "$RUNNER" "$ROOT" || RC=$?
fi

echo "CHECKPOINT $IDX/$N $ROOT rc=$RC next=$NEXT"
exit "$RC"
