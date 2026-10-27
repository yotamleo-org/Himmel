#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # A && B || C is intentional in check(); single-quoted awk programs and literal backticks
# scripts/handover/chief-kit/test-delta-class.sh - suite for delta-class.sh, the
# classifier a chief runs before re-judging a later push:
#   1. a changed file matching the trust list -> trust (also the old path of a rename)
#   2. a delta outside every judged finding's lines -> none
#   3. a delta on a finding's lines (verdict `finding:` line or CR-ledger row at
#      the judged head) -> finding; a ledger row for another head is ignored
#   4. trust beats finding
#   5. fail closed: unreadable trust list / verdict / ledger, unknown sha -> trust
#   6. a NO-GO verdict with no `finding:` line -> finding, never none
#   7. always exit 0 and print exactly one word
#
# Hermetic: temp git repo and files only.
# Platform guard: POSIX bash 3.2+.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/delta-class.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/delta-class-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; } # prim-ok: hermetic scratch dir, removed by the EXIT trap
trap 'rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd -P)"
fails=0
check() { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }

repo="$tmp/repo"
git init -q "$repo" || exit 1
cd "$repo" || exit 1
git config user.email t@t; git config user.name t; git config commit.gpgsign false
mkdir -p scripts/ci src docs
printf 'x\n' > scripts/ci/x.sh
seq 1 10 > src/a.txt
seq 1 10 > src/b.txt
printf 'c\n' > docs/c.md
git add -A && git commit -qm base
J=$(git rev-parse HEAD)

trustf="$tmp/trust.txt"
printf '# comment\n\n^scripts/ci/\n' > "$trustf"
vf="$tmp/judge.md"
mkv() {  # <word> <extra lines...>
    local w="$1"; shift
    { printf '# VERDICT q - judge\n\n## Verdict\n\n**%s** for head `%s`.\n\npr: 9\n\n' "$w" "$J"; printf '%s\n' "$@"; } > "$vf"
}
mkv GO 'finding: src/a.txt:3-4'
ledger="$tmp/ledger.jsonl"
: > "$ledger"

# edit <awk program> <file> - rewrite a file in place without sed -i (GNU and BSD differ)
edit() { awk "$1" "$2" > "$2.new" && mv "$2.new" "$2"; }
# step <msg> - commit the work tree, print the new head
step() { git add -A && git commit -qm "$1" && git rev-parse HEAD; }
back() { git reset -q --hard "$J"; }
cls() {  # <new> [extra args]
    local n="$1"; shift
    bash "$SCRIPT" --verdict-file "$vf" --ledger "$ledger" --trust-file "$trustf" "$@" "$J" "$n"
}

echo "x2" > scripts/ci/x.sh; N=$(step trust)
check "1: trust-path change -> trust" "$(cls "$N")" trust
back
git mv scripts/ci/x.sh docs/x.sh; N=$(step rename)
check "1: rename away from a trust path -> trust" "$(cls "$N")" trust
back

printf 'more\n' >> docs/c.md; N=$(step docs)
check "2: docs-only delta -> none" "$(cls "$N")" none
back
seq 1 9 > src/a.txt; printf '99\n' >> src/a.txt; N=$(step outside)
check "2: change outside the finding's lines -> none" "$(cls "$N")" none
back

edit '$0==4{print "four"; next} {print}' src/a.txt; N=$(step on-line)
check "3: change on a finding line -> finding" "$(cls "$N")" finding
back
edit '{print} $0==4{print "inserted"}' src/a.txt; N=$(step insert)
check "3: insertion right after a finding line -> finding" "$(cls "$N")" finding
back

printf '{"kind":"finding","head":"%s","file":"src/b.txt","line":2,"finding_id":"c-1"}\n' "$J" > "$ledger"
edit '$0==2{print "two"; next} {print}' src/b.txt; N=$(step ledger-hit)
check "3: ledger finding at the judged head -> finding" "$(cls "$N")" finding
back
printf '{"kind":"finding","head":"%s","file":"src/b.txt","line":2,"finding_id":"c-1"}\n' "0000000000000000000000000000000000000000" > "$ledger"
edit '$0==2{print "two"; next} {print}' src/b.txt; N=$(step ledger-other-head)
check "3: ledger finding for another head ignored -> none" "$(cls "$N")" none
back
: > "$ledger"

printf 'finding: src/b.txt\n' >> "$vf"
printf 'z\n' >> src/b.txt; N=$(step file-only)
check "3: file-only finding, any change to the file -> finding" "$(cls "$N")" finding
back
mkv GO 'finding: src/a.txt:3-4'

echo "x2" > scripts/ci/x.sh; edit '$0==4{print "four"; next} {print}' src/a.txt; N=$(step both)
check "4: trust beats finding" "$(cls "$N")" trust
back

printf 'more\n' >> docs/c.md; N=$(step docs2)
check "5: unreadable trust list -> trust" "$(bash "$SCRIPT" --verdict-file "$vf" --ledger "$ledger" --trust-file "$tmp/none.txt" "$J" "$N")" trust
printf '# only comments\n' > "$tmp/empty-trust.txt"
check "5: empty trust list -> trust" "$(bash "$SCRIPT" --verdict-file "$vf" --ledger "$ledger" --trust-file "$tmp/empty-trust.txt" "$J" "$N")" trust
check "5: unreadable verdict file -> trust" "$(bash "$SCRIPT" --verdict-file "$tmp/none.md" --ledger "$ledger" --trust-file "$trustf" "$J" "$N")" trust
check "5: missing ledger -> trust" "$(bash "$SCRIPT" --verdict-file "$vf" --ledger "$tmp/none.jsonl" --trust-file "$trustf" "$J" "$N")" trust
check "5: unknown new head -> trust" "$(cls 1111111111111111111111111111111111111111)" trust
check "5: malformed head -> trust" "$(cls nothex)" trust
check "5: no arguments -> trust" "$(bash "$SCRIPT")" trust
printf '(\n' > "$tmp/badre.txt"
check "5: invalid trust regex -> trust" "$(bash "$SCRIPT" --verdict-file "$vf" --ledger "$ledger" --trust-file "$tmp/badre.txt" "$J" "$N")" trust
printf 'garbage\n' > "$tmp/garbled.md"
check "5: verdict with no verdict line -> trust" "$(bash "$SCRIPT" --verdict-file "$tmp/garbled.md" --ledger "$ledger" --trust-file "$trustf" "$J" "$N")" trust
back

mkv NO-GO
printf 'more\n' >> docs/c.md; N=$(step docs3)
check "6: NO-GO with no finding lines -> finding" "$(cls "$N")" finding
mkv GO
check "6: GO with no finding lines and no ledger rows -> none" "$(cls "$N")" none
back

uni=$'caf\xc3\xa9.txt'
seq 1 10 > "$uni"; J0=$J; git add -A && git commit -qm uni; J=$(git rev-parse HEAD)
mkv GO "finding: $uni:3-4"
edit '$0==4{print "four"; next} {print}' "$uni"; N=$(step uni-edit)
check "3: finding on a non-ASCII path, edit on its line -> finding" "$(cls "$N")" finding
back
printf 'with space\n' > 'a b.txt'; printf 'q\n' > "$(printf 'tab\there.txt')"; git add -A; N=$(step odd-names)
mkv GO 'finding: src/a.txt:3-4'
check "5: a quoted (tab-bearing) path in the patch fails closed -> trust" "$(cls "$N")" trust
back
J=$J0

mkv GO 'finding: src/a.txt:3-4'
printf 'bin\0ary\n' > src/a.txt; N=$(step binary)
check "3: binary replacement of a finding's file -> finding" "$(cls "$N")" finding
back
printf 'bin\0ary\n' > src/b.txt; N=$(step binary-other)
check "2: binary change to a file with no finding -> none" "$(cls "$N")" none
back
mkv GO 'finding: src/a.txt:3-4'
printf '{"kind":"finding","head":"%s","finding_id":"c-9"}\n' "$J" > "$ledger"
printf 'more\n' >> docs/c.md; N=$(step nofile)
check "3: a ledger finding with no file -> finding" "$(cls "$N")" finding
: > "$ledger"
back
mkv GO
printf 'finding: src/a.txt:3-4' >> "$vf"
edit '$0==4{print "four"; next} {print}' src/a.txt; N=$(step no-newline)
check "3: a final finding line with no trailing newline is read -> finding" "$(cls "$N")" finding
back
mkv GO 'finding: a b.txt:3-4'
printf 'more\n' >> docs/c.md; N=$(step spaced)
check "5: a finding path holding a space fails closed -> trust" "$(cls "$N")" trust
mkv GO 'finding: src/a.txt:3-4 and some prose'
check "5: trailing text on a finding line fails closed -> trust" "$(cls "$N")" trust
back
mkv GO 'finding: src/a.txt:3-4'
printf 'more\n' >> docs/c.md; N=$(step wrong-head)
sed "s/$J/0000000000000000000000000000000000000000/" "$vf" > "$tmp/other.md"
check "5: an explicit verdict file for another head fails closed -> trust" "$(bash "$SCRIPT" --verdict-file "$tmp/other.md" --ledger "$ledger" --trust-file "$trustf" "$J" "$N")" trust
back

mkv GO 'finding: src/a.txt:3-4'
git config diff.srcPrefix x/
git config diff.dstPrefix y/
edit '$0==4{print "four"; next} {print}' src/a.txt; N=$(step prefix)
check "5: a src/dst prefix diff config does not hide a finding edit -> finding" "$(cls "$N")" finding
git config --unset diff.srcPrefix
git config --unset diff.dstPrefix
check "5: an external diff driver does not hide a finding edit -> finding" "$(GIT_EXTERNAL_DIFF=true cls "$N")" finding
back
printf 'more\n' >> docs/c.md; N=$(step badpaths)
for badpath in src/gone.txt ./src/a.txt src/./a.txt ../src/a.txt "$tmp/repo/src/a.txt" src; do
    mkv GO "finding: $badpath:3-4"
    check "5: finding path '$badpath' fails closed -> trust" "$(cls "$N")" trust
done
mkv GO 'finding: src'
check "5: a finding that names a directory fails closed -> trust" "$(cls "$N")" trust
back
mkv GO 'finding: src/a.txt:3-4'
git config diff.relative true
echo "x3" > scripts/ci/x.sh; N=$(step relative)
check "1: a trust-path change outside the cwd subtree is seen under diff.relative -> trust" "$(cd src && cls "$N")" trust
git config --unset diff.relative
back
repo_trust="$HERE/../../ci/ci-trust-paths.txt"
hit=no
while IFS= read -r pat; do
    case "$pat" in ''|'#'*) continue ;; esac
    printf '%s\n' scripts/handover/chief-kit/delta-class.sh | grep -Eq -e "$pat" && hit=yes
done < "$repo_trust"
check "1: delta-class.sh is itself under a ci-trust-paths pattern" "$hit" yes
mkv GO 'finding: src/a.txt:3-4'

# 8: a merge-forward of origin/main: paths only main changed are not the PR's delta
base_branch=$(git rev-parse --abbrev-ref HEAD)
J8=$J
git checkout -q -b main8a "$J8"; echo "m1" > scripts/ci/y.sh; M=$(step main-trust)
git checkout -q -b pr8a "$J8"; printf 'pr\n' >> docs/c.md; Jp=$(step pr-own)
git update-ref refs/remotes/origin/main "$M"
git merge -q --no-edit main8a >/dev/null; N=$(git rev-parse HEAD)
J=$Jp; mkv GO
check "8a: a pure merge-forward whose main side touches a trust path -> none" "$(cls "$N")" none
echo "pr2" > scripts/ci/z.sh; N2=$(step pr-trust-after-merge)
check "8c: a PR commit to a trust path after the merge-forward -> trust" "$(cls "$N2")" trust
git update-ref -d refs/remotes/origin/main
check "8d: a merge-forward with no origin/main to compare against -> trust" "$(cls "$N")" trust
J=$J8
git checkout -q "$base_branch"

git checkout -q -b main8b "$J8"; echo "mainx" > scripts/ci/x.sh; M=$(step main-conflict)
git checkout -q -b pr8b "$J8"; echo "prx" > scripts/ci/x.sh; Jp=$(step pr-conflict)
git update-ref refs/remotes/origin/main "$M"
git merge -q --no-edit main8b >/dev/null 2>&1
echo "resolved" > scripts/ci/x.sh; N=$(step resolved)
J=$Jp; mkv GO
check "8b: a merge-forward with a conflict resolved in a trust path -> trust" "$(cls "$N")" trust
git update-ref -d refs/remotes/origin/main
J=$J8
git checkout -q "$base_branch"

# 8e: the PR's own edit to a trust path (after the judged head) is dropped by resolving to main's exact side
git checkout -q -b main8e "$J8"; echo "mainx" > scripts/ci/x.sh; M=$(step main-x)
git checkout -q -b pr8e "$J8"; printf 'pr\n' >> docs/c.md; Jp=$(step pr-judged)
echo "prx" > scripts/ci/x.sh; step pr-x >/dev/null
git update-ref refs/remotes/origin/main "$M"
git merge -q --no-edit main8e >/dev/null 2>&1
echo "mainx" > scripts/ci/x.sh; N=$(step resolved-to-main)
J=$Jp; mkv GO
check "8e: a conflict resolved to main's exact side -> trust" "$(cls "$N")" trust
git update-ref -d refs/remotes/origin/main
J=$J8
git checkout -q "$base_branch"

# 8f: the PR changed a trust path by the judged head, then reverts it to main's content after the merge-forward
git checkout -q -b main8f "$J8"; echo "m" > scripts/ci/y.sh; M=$(step main-y)
git checkout -q -b pr8f "$J8"; echo "prx" > scripts/ci/x.sh; Jp=$(step pr-x)
git update-ref refs/remotes/origin/main "$M"
git merge -q --no-edit main8f >/dev/null 2>&1
echo "x" > scripts/ci/x.sh; N=$(step revert-to-main)
J=$Jp; mkv GO
check "8f: a trust-path edit reverted to main's content after the merge-forward -> trust" "$(cls "$N")" trust
git update-ref -d refs/remotes/origin/main
J=$J8
git checkout -q "$base_branch"

# 8g/8h: the PR deletes, then adds, a trust path after a pure merge-forward
git checkout -q -b main8g "$J8"; echo "m" > scripts/ci/y.sh; M=$(step main-y2)
git checkout -q -b pr8g "$J8"; printf 'pr\n' >> docs/c.md; Jp=$(step pr-judged2)
git update-ref refs/remotes/origin/main "$M"
git merge -q --no-edit main8g >/dev/null 2>&1
rm scripts/ci/x.sh; N=$(step delete-trust)
J=$Jp; mkv GO
check "8g: a trust path the PR deletes after the merge-forward -> trust" "$(cls "$N")" trust
git reset -q --hard "${N}~1"
echo "n" > scripts/ci/new.sh; N=$(step add-trust)
check "8h: a trust path the PR adds after the merge-forward -> trust" "$(cls "$N")" trust
git update-ref -d refs/remotes/origin/main
J=$J8
git checkout -q "$base_branch"
mkv GO 'finding: src/a.txt:3-4'

bash "$SCRIPT" >/dev/null 2>&1; check "7: exit 0 even on bad usage" "$?" 0
out=$(cls "$J"); check "7: an empty delta -> none, one word" "$out" none

if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
echo "PASS: all delta-class checks"
