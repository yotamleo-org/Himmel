#!/usr/bin/env bash
# Suite for scripts/docs/check-version-timing-words.sh.
#
# Each case builds a throwaway git repo and runs the lint from inside it (the
# lint resolves its root with git rev-parse). The planted lines are assembled
# from $V and a timing word at run time, so this file carries no literal hit
# and the lint's own tree scan stays clean on it.
#
# Platform guard (posix-bash): pure POSIX bash 3.2+ plus git/mktemp.
#
# Usage: bash scripts/docs/test-check-version-timing-words.sh
# Exit:  0 = every case passed, 1 = at least one failed (all are reported).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/check-version-timing-words.sh"

# shellcheck source=scripts/lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$HERE/../lib/fixture-tempdir.sh"

FIXTURE_LIST=$(mktemp "${TMPDIR:-/tmp}/himmel-fixture-list.XXXXXX") || exit 1
_d=''
trap 'while IFS= read -r _d; do [ -n "$_d" ] && rm -rf "$_d"; done <"$FIXTURE_LIST"; rm -f "$FIXTURE_LIST"' EXIT
tracked_fixture_dir() {
  local d
  d=$(fixture_mktemp_dir) || return 1
  printf '%s\n' "$d" >>"$FIXTURE_LIST"
  printf '%s\n' "$d"
}

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { echo "FAIL: $*" >&2; fail=$((fail + 1)); }

V=v1.1.3

setup_repo() {
  R=$(tracked_fixture_dir) || return 1
  git -C "$R" init -q
  git -C "$R" config user.email t@t
  git -C "$R" config user.name t
  mkdir -p "$R/docs" "$R/scripts" "$R/docs/release"
  echo "seed" >"$R/docs/seed.md"
  git -C "$R" add -A
  git -C "$R" commit -q -m init
}

run_lint() {
  RC=0
  OUT=$(cd "$R" && bash "$SCRIPT" "$@" 2>&1) || RC=$?
}

has() {
  case "$OUT" in *"$1"*) return 0 ;; esac
  return 1
}
expect_fail() {
  if [ "$RC" -eq 1 ] && has "$2"; then ok; else bad "$1: want rc 1 naming '$2', got rc $RC: $OUT"; fi
}
expect_pass() {
  if [ "$RC" -eq 0 ]; then ok; else bad "$1: want rc 0, got rc $RC: $OUT"; fi
}

setup_repo
printf 'intro\nwait %s %s closes\n' "until" "$V" >"$R/docs/a.md"
run_lint docs/a.md
expect_fail "planted until line" "docs/a.md:2:"

setup_repo
printf 'The %s release shipped the lint.\nPin to %s in the manifest.\n' "$V" "$V" >"$R/docs/a.md"
run_lint docs/a.md
expect_pass "name-only use"

for phrase in "after" "before" "till" "following" "by" "once" "at the close of" "by the end of" "until the" "After"; do
  setup_repo
  printf 'revisit %s %s lands\n' "$phrase" "$V" >"$R/docs/a.md"
  run_lint docs/a.md
  expect_fail "timing word '$phrase'" "docs/a.md:1:"
done
setup_repo
printf 'the %s%s line\n' "post-" "$V" >"$R/docs/a.md"
run_lint docs/a.md
expect_fail "post- prefix" "docs/a.md:1:"

setup_repo
printf 'recount at the %s close\nwhen %s ships\n' "$V" "$V" >"$R/docs/a.md"
run_lint docs/a.md
expect_fail "version then close" "docs/a.md:1:"
if has "docs/a.md:2:"; then ok; else bad "version then ships not reported: $OUT"; fi

setup_repo
printf 'the afterword of %s and a standby %s\n' "$V" "$V" >"$R/docs/a.md"
run_lint docs/a.md
expect_pass "timing word as a substring"

setup_repo
printf 'set fixVersion %s %s\n' "after" "$V" >"$R/docs/a.md"
run_lint docs/a.md
expect_pass "version field line"

setup_repo
printf 'git tag %s %s\n' "after" "$V" >"$R/docs/a.md"
run_lint docs/a.md
expect_pass "tag line"

setup_repo
printf 'sorts %s %s  # version-timing-ok\n' "before" "$V" >"$R/docs/a.md"
run_lint docs/a.md
expect_pass "order marker"

setup_repo
printf 'held %s %s\n' "until" "$V" >"$R/CHANGELOG.md"
printf 'held %s %s\n' "until" "$V" >"$R/docs/release/v9.9.9-notes.md"
run_lint CHANGELOG.md docs/release/v9.9.9-notes.md
expect_pass "release notes files"

setup_repo
printf 'held %s %s\n' "until" "$V" >"$R/docs/a.md"
printf '# held %s %s\n' "after" "$V" >"$R/scripts/x.sh"
mkdir -p "$R/src"
printf 'held %s %s\n' "until" "$V" >"$R/src/ignored.md"
git -C "$R" add -A
run_lint
if [ "$RC" -eq 1 ] && has "docs/a.md:1:" && has "scripts/x.sh:1:" && ! has "src/ignored.md"; then ok; else bad "census: rc $RC: $OUT"; fi

setup_repo
printf 'old: held %s %s\n' "until" "$V" >"$R/docs/old.md"
git -C "$R" add -A
git -C "$R" commit -q -m old
printf 'fine line\nnew: held %s %s\n' "until" "$V" >>"$R/docs/old.md"
run_lint --added HEAD
expect_fail "--added new line" "docs/old.md:3:"
if has "docs/old.md:1:"; then bad "--added reported the old line: $OUT"; else ok; fi

setup_repo
printf 'held %s %s\n' "until" "$V" >"$R/docs/old.md"
git -C "$R" add -A
git -C "$R" commit -q -m old
printf 'a plain edit\n' >>"$R/docs/old.md"
run_lint --added HEAD
expect_pass "--added with only an old hit"

setup_repo
printf 'held %s %s\n' "until" "$V" >"$R/CHANGELOG.md"
git -C "$R" add -A
run_lint --added HEAD
expect_pass "--added in release notes"

setup_repo
trunk=$(git -C "$R" rev-parse --abbrev-ref HEAD)
git -C "$R" branch -q side
printf 'main moved: held %s %s\n' "until" "$V" >"$R/docs/moved.md"
git -C "$R" add -A
git -C "$R" commit -q -m moved
git -C "$R" checkout -q side
printf 'plain branch edit\n' >>"$R/docs/seed.md"
git -C "$R" commit -q -am edit
run_lint --added "$trunk"
expect_pass "--added ignores what the base gained since the branch forked"

setup_repo
run_lint --added
if [ "$RC" -eq 2 ]; then ok; else bad "--added with no base: want rc 2, got $RC: $OUT"; fi

setup_repo
trunk=$(git -C "$R" rev-parse --abbrev-ref HEAD)
git -C "$R" checkout -q --orphan unrelated
git -C "$R" commit -q --allow-empty -m unrelated
git -C "$R" checkout -q "$trunk"
run_lint --added unrelated
if [ "$RC" -eq 2 ]; then ok; else bad "--added with a base sharing no history: want rc 2, got $RC: $OUT"; fi

setup_repo
run_lint --added no-such-ref
if [ "$RC" -eq 2 ]; then ok; else bad "--added with an unknown base: want rc 2, got $RC: $OUT"; fi

echo "check-version-timing-words suite: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
