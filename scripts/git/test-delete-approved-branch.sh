#!/usr/bin/env bash
# Hermetic tests for delete-approved-branch.sh.
#
# WHY THIS EXISTS: settings.json denies raw `git push --delete`, so every
# operator-approved stale-branch delete waited for the operator at the station.
# delete-approved-branch.sh is the one sanctioned shape: it deletes a remote
# branch only when an operator approval record names it, and refuses main,
# release/*, and any branch with an open PR. Every refusal row asserts the
# MOCKED REMOTE (a local bare repo) still holds the branch.
#
# Platform guard: pure git + POSIX shell, bash 3.2+.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/delete-approved-branch.sh"
TMP="$(mktemp -d -t delete-approved-branch-test.XXXXXX)" || { echo "test-delete-approved-branch: mktemp failed" >&2; exit 2; }
if [ -z "$TMP" ] || [ ! -d "$TMP" ]; then
    echo "test-delete-approved-branch: mktemp produced no usable directory" >&2
    exit 2
fi
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

FAILED=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

REMOTE="$TMP/remote.git"
CLONE="$TMP/clone"
BIN="$TMP/bin"
APPROVALS="$TMP/approvals.tsv"
LOG="$TMP/deletes.log"
mkdir -p "$BIN"

git init -q --bare -b main "$REMOTE"
git clone -q "$REMOTE" "$CLONE" 2>/dev/null
(
    cd "$CLONE" || exit 2
    git config user.email t@t.t; git config user.name t; git config commit.gpgsign false
    printf 'base\n' > f.txt
    git add f.txt; git commit -q -m base
    git push -q origin main
    for b in stale-a has-pr unapproved release/1.0 other-stale gh-down; do
        git push -q origin "main:refs/heads/$b"
    done
)

# gh stub: `gh pr list --head <b> ...` reports one open PR for has-pr only,
# and fails outright for gh-down (the fail-closed row).
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
head=""
while [ $# -gt 0 ]; do
    if [ "$1" = "--head" ]; then head="$2"; shift; fi
    shift
done
[ "$head" = "gh-down" ] && exit 1
if [ "$head" = "has-pr" ]; then echo 1; else echo 0; fi
EOF
chmod +x "$BIN/gh"

# approval records: <ref><TAB><branch>
printf 'msg-5004\tstale-a\nmsg-5004\thas-pr\nmsg-5004\tmain\nmsg-5004\trelease/1.0\nmsg-5004\tgh-down\n# msg-9999\tother-stale\nmsg-6001\tother-stale\n' > "$APPROVALS"

remote_has() { git -C "$REMOTE" show-ref --verify --quiet "refs/heads/$1"; }

run() {
    # run <branch> <ref>; sets RC and OUT
    OUT="$(cd "$CLONE" && PATH="$BIN:$PATH" HIMMEL_BRANCH_APPROVALS="$APPROVALS" \
        HIMMEL_BRANCH_DELETE_LOG="$LOG" bash "$SUT" "$@" 2>&1)"
    RC=$?
}

expect_refused() {
    local label="$1" branch="$2" ref="$3"
    run "$branch" "$ref"
    if [ "$RC" -ne 0 ] && remote_has "$branch"; then
        pass "$label"
    else
        fail "$label (rc=$RC, remote still has branch: $(remote_has "$branch" && echo yes || echo no))"
    fi
}

[ -f "$SUT" ] || { fail "script exists: $SUT"; echo "FAILED=$FAILED"; exit 1; }

expect_refused "refuses main even when approved" main msg-5004
expect_refused "refuses release/* even when approved" release/1.0 msg-5004
expect_refused "refuses a branch with an open PR even when approved" has-pr msg-5004
expect_refused "refuses a branch the approval does not name" unapproved msg-5004
expect_refused "refuses a ref that names the branch only in a commented line" other-stale msg-9999
expect_refused "refuses when the PR lookup fails (fail closed)" gh-down msg-5004

run stale-a msg-5004
if [ "$RC" -eq 0 ] && ! remote_has stale-a; then
    pass "deletes an approved stale branch from the mocked remote"
else
    fail "deletes an approved stale branch (rc=$RC, out=$OUT)"
fi
if grep -q 'stale-a' "$LOG" 2>/dev/null && grep -q 'msg-5004' "$LOG" 2>/dev/null; then
    pass "logs the delete with its approval ref"
else
    fail "logs the delete with its approval ref (log: $(cat "$LOG" 2>/dev/null))"
fi
if remote_has other-stale && remote_has unapproved && remote_has main; then
    pass "the success row left every other remote branch alone"
else
    fail "the success row left every other remote branch alone"
fi

run
if [ "$RC" -ne 0 ]; then pass "usage error without arguments"; else fail "usage error without arguments"; fi

echo "FAILED=$FAILED"
[ "$FAILED" -eq 0 ]
