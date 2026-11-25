#!/usr/bin/env bash
# Suite for scripts/docs/check-old-terms.sh.
#
# Each case builds a throwaway git repo with a small fixture registry and a
# baseline, commits it, makes one change and runs the lint over that change
# from inside the repo (the lint resolves its root with git rev-parse).
#
# Platform guard (posix-bash): pure POSIX bash 3.2+ plus git/mktemp.
#
# Usage: bash scripts/docs/test-check-old-terms.sh
# Exit:  0 = every case passed, 1 = at least one failed (all are reported).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/check-old-terms.sh"

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

OLD=ZZOLDNAME
NEW=ZZNEWNAME
OLDM=ZZOLDMARK
OLDP='zz old phrase'
KEEP=ZZKEPT-OLDNAME
BL=scripts/docs/old-terms-baseline.tsv
REG=scripts/lib/rename-aliases.tsv

row() { printf "%s\t%s\n" "$(printf "%s" "$1" | git hash-object --stdin)" "$2"; }

must() {
  "$@" || { echo "FAIL: setup step failed: $*" >&2; exit 1; }
}

write_registry() {
  {
    printf '# fixture registry\n'
    printf 'old\tnew\tkind\tdirection\tslice\tremove-at\n'
    printf '%s\t%s\tidentifier\told-to-new\tV1\tX\n' "$OLD" "$NEW"
    printf '%s\tZZNEWMARK\tmarker\told-to-new\tV1\tX\n' "$OLDM"
    printf '%s\tzz new phrase\tprose\t%s\tD\tnever\n' "$OLDP" "$1"
    printf 'ZZOLDKEEP\tZZOLDKEEP\tdo-not-rename\tkeep\tnone\tnever\n'
    printf '%s\t%s\tother-sense\tkeep\tnone\tnever\n' "$KEEP" "$KEEP"
    printf 'ZZPREFIX_\tZZPREFIX_\tdo-not-rename\tkeep\tnone\tnever\n'
  } >"$R/$REG"
}

setup_repo() {
  R=$(tracked_fixture_dir) || exit 1
  must git -C "$R" init -q
  must git -C "$R" config user.email t@t
  must git -C "$R" config user.name t
  must mkdir -p "$R/docs" "$R/scripts/docs" "$R/scripts/lib"
  write_registry "${1:-fail}"
  : >"$R/$BL"
  echo "seed" >"$R/docs/seed.md"
  must git -C "$R" add -A
  must git -C "$R" commit -q -m init
  BASE=$(git -C "$R" rev-parse HEAD)
}

commit_all() {
  must git -C "$R" add -A
  must git -C "$R" commit -q -m "${1:-change}"
}

run_lint() {
  RC=0
  OUT=$(cd "$R" && bash "$SCRIPT" "$@" 2>&1) || RC=$?
}

run_lint_with_failing_grep() {
  local stub real
  stub=$(tracked_fixture_dir) || exit 1
  real=$(command -v grep)
  printf "#!/bin/sh\ncase \"\$1\" in -Iq) exit 2 ;; esac\nexec %s \"\$@\"\n" "$real" >"$stub/grep"
  chmod +x "$stub/grep"
  RC=0
  OUT=$(cd "$R" && PATH="$stub:$PATH" bash "$SCRIPT" "$@" 2>&1) || RC=$?
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
expect_rc() {
  if [ "$RC" -eq "$2" ]; then ok; else bad "$1: want rc $2, got rc $RC: $OUT"; fi
}

setup_repo
printf 'intro\nuse the %s helper\n' "$OLD" >"$R/docs/a.md"
commit_all
run_lint --range "$BASE"
expect_fail "RED: a fixture adding an old name" "docs/a.md"

setup_repo
printf 'intro\nuse the %s helper\n' "$NEW" >"$R/docs/a.md"
commit_all
run_lint --range "$BASE"
expect_pass "control: the new name"

setup_repo
printf 'use the %s helper\n' "$OLDM" >"$R/docs/a.md"
commit_all
run_lint --range "$BASE"
expect_fail "a marker row (old-to-new) is refused" "docs/a.md"

setup_repo
printf 'a plain edit\n' >>"$R/docs/seed.md"
commit_all
run_lint --range "$BASE"
expect_pass "a change that touches no file with an old name"

setup_repo
printf 'the %sX name and X%s and %s_Y\n' "$OLD" "$OLD" "$OLD" >"$R/docs/a.md"
commit_all
run_lint --range "$BASE"
expect_pass "an identifier inside a longer word is not a hit"

setup_repo
printf 'the %s name\n' "$OLD" >"$R/docs/a.md"
row docs/a.md 1 >"$R/$BL"
commit_all "seed"
BASE=$(git -C "$R" rev-parse HEAD)
printf 'second line\n' >>"$R/docs/a.md"
commit_all
run_lint --range "$BASE"
expect_pass "a file that keeps its one old name and gains a clean line"

setup_repo
printf 'the %s name\n' "$OLD" >"$R/docs/a.md"
row docs/a.md 1 >"$R/$BL"
commit_all "seed"
BASE=$(git -C "$R" rev-parse HEAD)
printf 'another %s use\n' "$OLD" >>"$R/docs/a.md"
commit_all
run_lint --range "$BASE"
expect_fail "a second old name in a file that has one" "docs/a.md"

setup_repo
printf 'the %s name\n' "$OLD" >"$R/docs/a.md"
row docs/a.md 1 >"$R/$BL"
commit_all "seed"
BASE=$(git -C "$R" rev-parse HEAD)
printf 'the %s name\n' "$NEW" >"$R/docs/a.md"
: >"$R/$BL"
commit_all
run_lint --range "$BASE"
expect_pass "sweeping the old name and lowering the row"

setup_repo
printf 'the %s name\n' "$OLD" >"$R/docs/a.md"
row docs/a.md 1 >"$R/$BL"
commit_all "seed"
BASE=$(git -C "$R" rev-parse HEAD)
printf 'the %s name\n' "$NEW" >"$R/docs/a.md"
commit_all "delete, leave the row"
MID=$(git -C "$R" rev-parse HEAD)
run_lint --range "$BASE"
expect_pass "deleting an old name and leaving the row alone"
printf 'the %s name again\n' "$OLD" >"$R/docs/a.md"
commit_all "add it back"
run_lint --range "$MID"
expect_fail "adding one back to that file" "docs/a.md"

setup_repo
printf 'the %s name\n' "$OLD" >"$R/docs/a.md"
row docs/a.md 1 >"$R/$BL"
commit_all "seed"
BASE=$(git -C "$R" rev-parse HEAD)
row docs/a.md 2 >"$R/$BL"
commit_all
run_lint --range "$BASE"
expect_fail "a baseline row that rises" "$BL"

setup_repo
row docs/new.md 3 >"$R/$BL"
commit_all
run_lint --range "$BASE"
expect_fail "a new baseline row above zero" "$BL"

setup_repo
printf 'the %s name\n' "$OLD" >"$R/docs/a.md"
commit_all "seed with no row"
BASE=$(git -C "$R" rev-parse HEAD)
row docs/a.md 1 >"$R/$BL"
commit_all
run_lint --range "$BASE"
expect_pass "a row that only records the count the base file already has"

setup_repo
printf 'the %s name\n' "$OLD" >"$R/docs/a.md"
row docs/a.md 1 >"$R/$BL"
commit_all "seed"
BASE=$(git -C "$R" rev-parse HEAD)
must git -C "$R" mv docs/a.md docs/b.md
row docs/b.md 1 >"$R/$BL"
commit_all
run_lint --range "$BASE"
expect_pass "a renamed file carries its row"

setup_repo
printf 'the %s name\n' "$OLD" >"$R/docs/a.md"
row docs/a.md 1 >"$R/$BL"
commit_all "seed"
BASE=$(git -C "$R" rev-parse HEAD)
must git -C "$R" mv docs/a.md docs/b.md
row docs/b.md 1 >"$R/$BL"
printf 'plus %s again\n' "$OLD" >>"$R/docs/b.md"
commit_all
run_lint --range "$BASE"
expect_fail "a renamed file that gains an old name" "docs/b.md"

setup_repo
printf 'see %s and %s\n' "ZZOLDKEEP" "$KEEP" >"$R/docs/a.md"
printf 'ZZPREFIX_THING and ZZPREFIX_%s\n' "$OLD" >>"$R/docs/a.md"
commit_all
run_lint --range "$BASE"
expect_pass "a do-not-rename name and a retrieval alias are not flagged"

setup_repo
printf 'the %s name  old-term-ok: a quoted example\n' "$OLD" >"$R/docs/a.md"
commit_all
run_lint --range "$BASE"
expect_pass "a line carrying old-term-ok"

setup_repo
printf '%s\t%s\tidentifier\told-to-new\tV1\tX\n' "ZZOTHER" "ZZOTHERNEW" >>"$R/$REG"
printf 'ZZOLDNAME is listed here\n' >>"$R/$REG"
commit_all
run_lint --range "$BASE"
expect_pass "the registry file itself"

setup_repo
printf 'not a row\n' >"$R/$BL"
commit_all
run_lint --range "$BASE"
expect_rc "a baseline row with no count" 2

setup_repo warn
printf 'the %s phrase\n' "$OLDP" >"$R/docs/a.md"
commit_all
run_lint --range "$BASE"
expect_pass "a warn-tier prose row does not fail"
if has "WARN docs/a.md:1" ; then ok; else bad "warn tier prints the hit with WARN: $OUT"; fi
write_registry fail
commit_all "flip the row"
run_lint --range "$BASE"
expect_fail "the same row with direction fail" "docs/a.md"

setup_repo
printf '\200\000\001%s\n' "$OLD" >"$R/docs/blob.bin"
commit_all
run_lint --range "$BASE"
expect_pass "a binary file is skipped"

setup_repo
printf 'a %s here\nand %s there\n' "$OLD" "$OLDM" >"$R/docs/b.md"
printf 'one %s only\n' "$OLD" >"$R/docs/a.md"
printf 'nothing\n' >"$R/docs/c.md"
commit_all
run_lint --write-baseline
{ row docs/a.md 1; row docs/b.md 2; } | sort >"$R/expect.tsv"
if [ "$RC" -eq 0 ] && cmp -s "$R/expect.tsv" "$R/$BL"; then ok; else bad "--write-baseline: rc $RC: $OUT; row file: $(cat "$R/$BL")"; fi
commit_all "baseline"
BASE=$(git -C "$R" rev-parse HEAD)
printf 'edit\n' >>"$R/docs/a.md"
commit_all
run_lint --range "$BASE"
expect_pass "a baseline written by --write-baseline holds for the next change"

setup_repo
printf 'the %s name\n' "$OLD" >"$R/docs/a.md"
must git -C "$R" add -A
run_lint --staged
expect_fail "--staged names a staged old name" "docs/a.md"
setup_repo
printf 'the %s name\n' "$NEW" >"$R/docs/a.md"
must git -C "$R" add -A
run_lint --staged
expect_pass "--staged with the new name"

setup_repo
run_lint --range
expect_rc "--range with no base" 2
setup_repo
run_lint --range no-such-ref
expect_rc "--range with an unknown base" 2
setup_repo
run_lint
expect_rc "no mode" 2
setup_repo
must git -C "$R" rm -q "$BL"
commit_all "drop the baseline"
run_lint --range "$BASE"
expect_rc "no baseline at the tip" 2
setup_repo
must git -C "$R" rm -q "$REG"
commit_all "drop the registry"
run_lint --range "$BASE"
expect_rc "no registry at the tip" 2

setup_repo
printf 'the %s name\n' "$OLD" >"$R/docs/a.md"
commit_all
run_lint_with_failing_grep --range "$BASE"
expect_rc "a blob that cannot be read for its count is never a pass" 2

setup_repo
printf 'one line %s and %s\n' "$OLD" "$OLDM" >"$R/docs/a.md"
commit_all
run_lint --range "$BASE"
expect_fail "a line naming two retired names counts both" "2 retired-name hits"

setup_repo
trunk=$(git -C "$R" rev-parse --abbrev-ref HEAD)
must git -C "$R" branch -q side
printf 'main moved: the %s name\n' "$OLD" >"$R/docs/moved.md"
commit_all "moved"
must git -C "$R" checkout -q side
printf 'plain branch edit\n' >>"$R/docs/seed.md"
must git -C "$R" commit -q -am edit
run_lint --range "$trunk"
expect_pass "--range ignores what the base gained since the branch forked"

echo "check-old-terms suite: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
