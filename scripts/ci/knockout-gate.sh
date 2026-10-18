#!/usr/bin/env bash
# Revert the non-test half of a PR in a disposable worktree. At least one
# impacted suite must fail there; unchanged-green or untested changes fail.
# Usage: knockout-gate.sh <base>..<head>
#        knockout-gate.sh <base> <head>
# Exit: 0 detected / test-only not applicable, 1 failed gate, 2 usage.
# Platform: bash 3.2+, git; suite runtimes must already be installed.
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

# Copied from review-round.sh's test_path_p; basename patterns do not
# accidentally classify a production file just because a parent is test-*.sh.
test_path_p() {
    case "$1" in
        */tests/*|tests/*|*/test/*|test/*|*/__tests__/*) return 0 ;;
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
    exit 0
fi

# Selection is computed on the real diff BEFORE restoration, using the tool
# outside the scratch tree so restoring a changed selector cannot narrow it.
bash "$TOOLS/impacted-suites.sh" "$base..$head" > "$work/suites" || fail selector
[ -s "$work/suites" ] || fail no-suites
n=0
while IFS= read -r suite; do
    [ -n "$suite" ] || continue
    n=$((n + 1))
    case "${suite##*/}" in
        test-*.sh) printf 'bash %q\n' "$suite" > "$work/command-$n" || fail scratch-write ;;
        *) bash "$TOOLS/impacted-suites.sh" --runner "$suite" > "$work/command-$n" || fail "runner-unmapped $suite" ;;
    esac
done < "$work/suites"
[ "$n" -gt 0 ] || fail no-suites
git worktree add --detach "$tree" "$head" || fail worktree-add
# Restore handles additions (remove), deletions (recreate), modes and symlinks
# together, without following an old symlink or touching the real index.
git -C "$tree" --literal-pathspecs restore --source="$base" --staged --worktree \
    --pathspec-from-file="$work/non-test" --pathspec-file-nul || fail restore
red=0
n=0
while IFS= read -r suite; do
    [ -n "$suite" ] || continue
    n=$((n + 1))
    command=$(< "$work/command-$n")
    rc=0
    (cd "$tree" && bash -c "$command") || rc=$?
    printf 'knockout-gate: suite %s exit=%s\n' "$suite" "$rc"
    case "$rc" in
        0) ;;
        126|127) fail "runner-unavailable $suite" ;;
        *) red=$((red + 1)) ;;
    esac
done < "$work/suites"
[ "$red" -gt 0 ] || fail "all-green ($n suites; non-test change not detected)"
printf 'knockout-gate: detected (%s of %s suites failed)\n' "$red" "$n"
