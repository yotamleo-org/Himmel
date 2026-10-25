#!/usr/bin/env bash
# run-suite.sh — Run ONE scan root of the shell-suite tree per
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
# scripts/quiet-run.sh; --runner PATH swaps the scan runner (tests). `top` runs
# the runner over scripts with every nested suite --skip-extra'd, so only the
# scripts/test-*.sh files run, under the runner's lock, SKIP_LIST and budget.
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
# The kit's own repo, not the cwd's: tools resolve beside this script. Resolved
# BEFORE the cd below, so a relative $0 still finds the right directory.
SELF="$(cd "$(dirname "$0")/../../.." && pwd)"
TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "run-suite: not in a git work tree" >&2; exit 2; }
cd "$TOP" || exit 2
QUIET_RUN="$SELF/scripts/quiet-run.sh"
[ -n "$RUNNER" ] || RUNNER="$SELF/scripts/ci/run-shell-tests.sh"

plan() {
    git ls-files -co --exclude-standard -- 'scripts/*/**' \
        | grep -E '/test-[^/]*\.sh$' \
        | awk -F/ '{print $1 "/" $2}' | sort -u
    top_files="$(git ls-files -co --exclude-standard -- 'scripts/test-*.sh')"
    if [ -n "$top_files" ]; then echo top; fi
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
    # Through the runner, so its machine lock, SKIP_LIST (VM and network suites)
    # and per-suite budget all apply: scan root scripts with every nested suite
    # skipped (--skip-extra is scan-root-relative), leaving the top-level files.
    NESTED="$(git ls-files -co --exclude-standard -- 'scripts/*test-*.sh')"
    SKIPS=()
    while IFS= read -r f; do
        case "$f" in scripts/*/*) SKIPS+=(--skip-extra "${f#scripts/}") ;; esac
    done <<EOF
$NESTED
EOF
    bash "$QUIET_RUN" suite-root -- bash "$RUNNER" scripts ${SKIPS[@]+"${SKIPS[@]}"} || RC=$?
else
    bash "$QUIET_RUN" suite-root -- bash "$RUNNER" "$ROOT" || RC=$?
fi

echo "CHECKPOINT $IDX/$N $ROOT rc=$RC next=$NEXT"
exit "$RC"
