#!/usr/bin/env bash
# Revert the non-test half of a PR in a disposable worktree. At least one
# impacted suite must fail there; unchanged-green or untested changes fail.
# Usage: knockout-gate.sh <base>..<head>
#        knockout-gate.sh <base> <head>
# Exit: 0 detected, 1 failed gate, 2 usage, 3 not applicable (test-only diff).
# Env: SUITE_TIMEOUT per-suite cap in seconds (default 600).
#      SUITE_TIMEOUTS space-separated <suite path>=<seconds> overrides of it.
# Platform: bash 3.2+, git, timeout; suite runtimes must already be installed.
# JS suite deps are installed per scratch tree by the selector's --run
# (lockfile-pinned, --ignore-scripts), never fetched by a bare npx or bun.
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX GIT_IMPLICIT_WORK_TREE GIT_GRAFT_FILE GIT_REPLACE_REF_BASE GIT_SHALLOW_FILE GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
TOOLS="$(cd "$(dirname "$0")/../cr" && pwd)" || exit 1
usage() { echo 'usage: knockout-gate.sh <base>..<head> | <base> <head>' >&2; exit 2; }
fail() { printf 'knockout-gate: %s\n' "$*" >&2; exit 1; }
case $# in
    1)
        case "$1" in *...*|..*|*..) usage ;; *..*) ;; *) usage ;; esac
        base_arg="${1%%..*}"; head_arg="${1#*..}" ;;
    2) base_arg="$1"; head_arg="$2" ;;
    *) usage ;;
esac
base=$(git rev-parse --verify --quiet --end-of-options "${base_arg}^{commit}") || usage
head=$(git rev-parse --verify --quiet --end-of-options "${head_arg}^{commit}") || usage
root=$(git rev-parse --show-toplevel) || fail not-a-worktree
cd "$root" || fail worktree-unreadable
# The selector uses the PR merge-base, so both halves use that same diff.
base=$(git merge-base "$base" "$head") || fail no-merge-base
work=$(mktemp -d "${TMPDIR:-/tmp}/knockout-gate.XXXXXX") || fail scratch-create
work=$(cd "$work" && pwd) || fail scratch-unreadable
tree="$work/tree"
cleanup() {
    local rc=$?
    trap - EXIT HUP INT TERM
    if [ -e "$tree/.git" ]; then
        git -C "$root" worktree remove --force "$tree" || rc=1
    fi
    rm -rf -- "$work" || rc=1
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# review-round.sh's test_path_p rule, also covering a root __tests__ tree.
# Basename patterns never classify production by a test-*.sh parent name.
test_path_p() {
    case "$1" in
        */tests/*|tests/*|*/test/*|test/*|*/__tests__/*|__tests__/*) return 0 ;;
    esac
    case "${1##*/}" in
        test-*.sh|*.test.[a-z]*) return 0 ;;
    esac
    return 1
}
git diff -z --name-only --no-renames "$base" "$head" > "$work/changed" || fail diff
: > "$work/non-test" || fail scratch-write
while IFS= read -r -d '' path; do
    # The selector's public list is line-delimited; never split a path into
    # executable commands or mistake an unsupported name for zero suites.
    case "$path" in *$'\n'*) fail newline-path ;; esac
    printf 'knockout-gate: changed %s\n' "$path"
    if ! test_path_p "$path"; then
        printf '%s\0' "$path" >> "$work/non-test" || fail scratch-write
    fi
done < "$work/changed"
if [ ! -s "$work/non-test" ]; then
    echo 'knockout-gate: not-applicable (test-only diff)'
    exit 3
fi

# Selection is computed on the real diff BEFORE restoration, using the tool
# outside the scratch tree so restoring a changed selector cannot narrow it.
bash "$TOOLS/impacted-suites.sh" "$base..$head" > "$work/suites" || fail selector
[ -s "$work/suites" ] || fail no-suites
# The commands live in memory so a suite cannot rewrite them between phases.
cmds=()
n=0
while IFS= read -r suite; do
    [ -n "$suite" ] || continue
    n=$((n + 1))
    case "${suite##*/}" in
        test-*.sh) cmds[n]=$(printf 'bash %q' "$suite") ;;
        *)
            bash "$TOOLS/impacted-suites.sh" --runner "$suite" > /dev/null || fail "runner-unmapped $suite"
            cmds[n]=$(printf 'bash %q --run %q' "$TOOLS/impacted-suites.sh" "$suite") ;;
    esac
done < "$work/suites"
[ "$n" -gt 0 ] || fail no-suites
# Per-suite wall-clock cap, as in run-shell-tests.sh. timeout leads its own
# process group and signals all of it, so a hung suite's children die too; a
# knocked-out hang (124/137) is a failing suite, a baseline hang is baseline-red.
suite_timeout="${SUITE_TIMEOUT:-600}"
case "$suite_timeout" in ''|*[!0-9]*) fail "bad SUITE_TIMEOUT '$suite_timeout'" ;; esac
[ "$((10#$suite_timeout))" -ge 1 ] || fail "bad SUITE_TIMEOUT '$suite_timeout'"
command -v timeout >/dev/null 2>&1 || fail 'runner-unavailable timeout'
# A per-suite override must be a valid cap too; the global cap covers the rest.
for entry in ${SUITE_TIMEOUTS:-}; do
    case "$entry" in ?*=*) ;; *) fail "bad SUITE_TIMEOUTS '$entry'" ;; esac
    case "${entry#*=}" in ''|*[!0-9]*) fail "bad SUITE_TIMEOUTS '$entry'" ;; esac
    [ "$((10#${entry#*=}))" -ge 1 ] || fail "bad SUITE_TIMEOUTS '$entry'"
done
cap_for() {
    local entry
    for entry in ${SUITE_TIMEOUTS:-}; do
        [ "${entry%%=*}" = "$1" ] && { echo "$((10#${entry#*=}))"; return; }
    done
    echo "$suite_timeout"
}
run_suites() {
    local phase="$1" suite command rc cap
    n=0
    while IFS= read -r suite; do
        [ -n "$suite" ] || continue
        n=$((n + 1))
        command="${cmds[$n]}"
        rc=0
        cap=$(cap_for "$suite")
        # stdin is closed so a suite that reads it ends instead of waiting for the cap.
        (cd "$tree" && timeout -k 5 "$cap" bash -c "$command" < /dev/null) 2> "$work/stderr" || rc=$?
        cat "$work/stderr" >&2
        # A failed install is not a failing suite: never count it as detection.
        if grep -q 'impacted-suites: FAIL_INSTALL' "$work/stderr"; then
            fail "deps-install-failed $suite"
        fi
        printf 'knockout-gate: %s suite %s exit=%s\n' "$phase" "$suite" "$rc"
        # 125 is timeout itself failing, 126/127 a missing runner: never evidence.
        case "$rc" in 125|126|127) fail "runner-unavailable $suite (exit=$rc)" ;; esac
        if [ "$phase" = baseline ] && [ "$rc" -ne 0 ]; then
            fail "baseline-red $suite (exit=$rc, 124/137 = timed out after ${cap}s; not knockout evidence)"
        fi
        [ "$rc" -eq 0 ] || red=$((red + 1))
    done < "$work/suites"
}
git worktree add --detach "$tree" "$head" || fail worktree-add
red=0
run_suites baseline
# Recreate the tree so a baseline suite's tracked edits, generated files or
# dependency directories cannot leak into the knockout run.
git worktree remove --force "$tree" || fail baseline-cleanup
git worktree add --detach "$tree" "$head" || fail worktree-add
# Restore handles additions (remove), deletions (recreate), modes and symlinks
# together, without following an old symlink or touching the real index.
git -C "$tree" --literal-pathspecs restore --source="$base" --staged --worktree \
    --pathspec-from-file="$work/non-test" --pathspec-file-nul || fail restore
run_suites knockout
[ "$red" -gt 0 ] || fail "all-green ($n suites; non-test change not detected)"
printf 'knockout-gate: detected (%s of %s suites failed)\n' "$red" "$n"
