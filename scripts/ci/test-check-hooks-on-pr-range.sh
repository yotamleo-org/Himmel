#!/usr/bin/env bash
# Hermetic test for scripts/ci/check-hooks-on-pr-range.sh (HIMMEL-5423). Builds
# throw-away repos shaped like a CI PR checkout (a detached merge commit whose
# first parent is the base tip and second parent the PR head) and asserts the
# verdict of the real hooks run through the wrapper.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
W="$REPO_ROOT/scripts/ci/check-hooks-on-pr-range.sh"
PLAT=scripts/hooks/check-platforms-tested.sh
SEC=scripts/hooks/check-security-reviewed.sh
DOC=scripts/hooks/check-doc-guard.sh
# shellcheck source=scripts/lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/fixture-tempdir.sh"
[ -f "$W" ] || { echo "FAIL: $W not found"; exit 1; }
failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }
expect() { # <label> <want-rc> <got-rc> <output>
  if [ "$3" -eq "$2" ]; then pass "$1"; else fail "$1: want rc$2, got rc$3: $4"; fi
}

# mkpr <dir> <first-msg> [<second-msg>] — base repo (docs catalog present, one
# unattested script already on main), a main commit after the fork, a PR branch
# with one or two commits, then a detached merge commit (the CI checkout).
# PR_FILES: space-separated paths the FIRST commit adds; PR_SECOND: path the
# second commit adds (default: a docs file).
mkpr() {
  local d="$1" m1="$2" m2="${3:-}" f
  (
    set -e   # a failed fixture step aborts the subshell, never a misleading verdict
    fixture_enter_git_init_dir "$d" || exit 1
    git init -q -b main
    git config user.email t@e; git config user.name t
    mkdir -p docs scripts .claude/commands
    echo cat > docs/commands-catalog.md
    git add -A; git commit -q -m "chore: base"
    git checkout -q -b pr
    for f in ${PR_FILES:-scripts/new.sh}; do
      mkdir -p "$(dirname "$f")"; echo "$f" > "$f"; git add "$f"
    done
    git commit -q -m "$m1"
    if [ -n "$m2" ]; then
      echo two > "${PR_SECOND:-docs/note.md}"; git add -A; git commit -q -m "$m2"
    fi
    git checkout -q main
    mkdir -p scripts; echo main > scripts/main-only.sh; git add -A; git commit -q -m "chore: main moved on"
    git merge -q --no-ff --no-edit pr
    git checkout -q --detach HEAD
  ) || { echo "FAIL: fixture setup for $d"; exit 1; }
}
run() { ( cd "$1" && shift && bash "$W" "$@" 2>&1 ); }
mk() { local t; t="$(fixture_mktemp_dir)" || exit 1; echo "$t"; }

TRAIL=$'\n\nPlatforms tested: linux\nSecurity reviewed: manual — read the diff'

# --- the defect: today's hook, run bare on the detached merge ref, passes ---
t="$(mk)"; mkpr "$t" "feat: HIMMEL-1 no trailers"
out="$( cd "$t" && PLATFORMS_TESTED_NO_FETCH=1 bash "$REPO_ROOT/$PLAT" 2>&1 )"; rc=$?
expect "RED control: bare hook on a detached merge ref passes vacuously" 0 "$rc" "$out"
rm -rf "$t"

# --- missing trailers in the first commit: both attestation hooks fail ---
t="$(mk)"; mkpr "$t" "feat: HIMMEL-1 no trailers"
out="$(run "$t" --first-commit -- $PLAT)"; rc=$?
expect "no Platforms tested -> rc1" 1 "$rc" "$out"
out="$(run "$t" --first-commit -- $SEC)"; rc=$?
expect "no Security reviewed -> rc1" 1 "$rc" "$out"
rm -rf "$t"

# --- trailers in the first commit: both pass ---
t="$(mk)"; mkpr "$t" "feat: HIMMEL-1 attested$TRAIL"
out="$(run "$t" --first-commit -- $PLAT)"; rc=$?
expect "first commit attested -> platforms rc0" 0 "$rc" "$out"
out="$(run "$t" --first-commit -- $SEC)"; rc=$?
expect "first commit attested -> security rc0" 0 "$rc" "$out"
rm -rf "$t"

# --- trailers only in a LATER commit: the first-commit rule fails it ---
t="$(mk)"; mkpr "$t" "feat: HIMMEL-1 first" "fix: HIMMEL-1 second$TRAIL"
out="$(run "$t" --first-commit -- $PLAT)"; rc=$?
expect "trailer only in second commit -> rc1" 1 "$rc" "$out"
rm -rf "$t"

# --- a PR-body attestation (the hooks' gh fallback) does not count ---
t="$(mk)"; mkpr "$t" "feat: HIMMEL-1 no trailers"
b="$(mk)"
printf '#!/bin/sh\necho "Platforms tested: linux"\necho "Security reviewed: manual"\n' > "$b/gh"; chmod +x "$b/gh"
out="$( cd "$t" && PATH="$b:$PATH" bash "$W" --first-commit -- $PLAT 2>&1 )"; rc=$?
expect "PR-body attestation ignored -> rc1" 1 "$rc" "$out"
rm -rf "$t" "$b"

# --- a docs-only PR needs no trailer, and main's own unattested script is
# not the PR's (merge-ref first parent, not the stale fork point) ---
t="$(mk)"; PR_FILES=docs/readme.md mkpr "$t" "docs: HIMMEL-1 words"
out="$(run "$t" --first-commit -- $PLAT)"; rc=$?
expect "docs-only PR -> platforms rc0" 0 "$rc" "$out"
out="$(run "$t" --first-commit -- $SEC)"; rc=$?
expect "docs-only PR -> security rc0" 0 "$rc" "$out"
rm -rf "$t"

# --- a bot PR author is exempt ---
t="$(mk)"; mkpr "$t" "chore(deps): bump x"
out="$( cd "$t" && TICKET_ID_TRUSTED_AUTHOR='dependabot[bot]' bash "$W" --first-commit -- $SEC 2>&1 )"; rc=$?
expect "dependabot author exempt -> rc0" 0 "$rc" "$out"
out="$( cd "$t" && TICKET_ID_TRUSTED_AUTHOR='someone' bash "$W" --first-commit -- $SEC 2>&1 )"; rc=$?
expect "other author not exempt -> rc1" 1 "$rc" "$out"
rm -rf "$t"

# --- doc-guard: an added command without its catalog entry fails ---
t="$(mk)"; PR_FILES=".claude/commands/new.md" mkpr "$t" "feat: HIMMEL-1 add command"
out="$(run "$t" -- $DOC --pre-push)"; rc=$?
expect "command added, catalog untouched -> rc1" 1 "$rc" "$out"
rm -rf "$t"
t="$(mk)"; PR_FILES=".claude/commands/new.md docs/commands-catalog.md" mkpr "$t" "feat: HIMMEL-1 add command"
out="$(run "$t" -- $DOC --pre-push)"; rc=$?
expect "command added with catalog update -> rc0" 0 "$rc" "$out"
rm -rf "$t"

# --- no PR range (cron / dispatch): nothing to check, rc0 ---
t="$(mk)"; mkpr "$t" "feat: HIMMEL-1 no trailers"
git -C "$t" checkout -q --detach 'HEAD^1'
out="$(run "$t" --first-commit -- $PLAT)"; rc=$?
expect "no range -> rc0" 0 "$rc" "$out"
rm -rf "$t"

# --- an explicit --base on a plain (non-merge) HEAD ---
t="$(mk)"; mkpr "$t" "feat: HIMMEL-1 no trailers"
git -C "$t" checkout -q --detach 'HEAD^2'
out="$(run "$t" --first-commit --base 'HEAD^' -- $PLAT)"; rc=$?
expect "--base on a plain HEAD -> rc1" 1 "$rc" "$out"
rm -rf "$t"

# --- bad hook path is refused ---
out="$(run "$REPO_ROOT" -- scripts/ci/check-no-secrets.sh)"; rc=$?
expect "non-hook path refused -> rc2" 2 "$rc" "$out"

# --- --base with no value is a usage error, not an endless loop ---
out="$(timeout 10 bash "$W" --base 2>&1)"; rc=$?
expect "--base without a value -> rc2" 2 "$rc" "$out"

# --- a merge-only PR range is still checked (an evil merge adds a script) ---
t="$(mk)"; mkpr "$t" "feat: HIMMEL-1 x$TRAIL"
(
  set -e
  cd "$t"
  main="$(git rev-parse 'HEAD^1')"; old="$(git rev-parse 'HEAD^1~1')"
  git checkout -q --detach "$main"
  mkdir -p scripts; echo evil > scripts/evil.sh; git add scripts/evil.sh
  tree="$(git write-tree)"
  tip="$(git commit-tree "$tree" -p "$main" -p "$old" -m "merge only")"
  m="$(git commit-tree "$tree" -p "$main" -p "$tip" -m "merge")"
  git checkout -q --detach "$m"
) || fail "merge-only fixture setup"
out="$(run "$t" --first-commit -- $PLAT)"; rc=$?
expect "merge-only range, unattested script -> rc1" 1 "$rc" "$out"
rm -rf "$t"

echo
if [ "$failures" -gt 0 ]; then echo "$failures FAILED"; exit 1; fi
echo "all passed"
