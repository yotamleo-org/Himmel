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

bash "$SCRIPT" >/dev/null 2>&1; check "7: exit 0 even on bad usage" "$?" 0
out=$(cls "$J"); check "7: an empty delta -> none, one word" "$out" none

if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
echo "PASS: all delta-class checks"
