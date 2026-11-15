#!/usr/bin/env bash
# scripts/handover/chief-kit/test-owe.sh - owe.sh add|close|list over <bucket>/owed.jsonl:
# append-only rows, a close needs a key, nothing is ever rewritten.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
OWE="${OWE_SH:-$HERE/owe.sh}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }
contains() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (no '$3' in '$2')" ;; esac; }
lacks() { case "$2" in *"$3"*) fail "$1 ('$3' in '$2')" ;; *) pass "$1" ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/owe-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT
B="$WORK/bucket"; mkdir -p "$B"
F="$B/owed.jsonl"
NOW=1800000000
export OWE_NOW_EPOCH=$NOW

# add: a ticket row, no key
out="$(bash "$OWE" add --bucket "$B" --chief Z --kind ticket --text 'file the fold bug' 2>&1)"; rc=$?
check "add ticket exits 0" "$rc" "0"
check "add prints the new id" "$out" "o1"
check "one row written" "$(wc -l < "$F" | tr -d ' ')" "1"
check "row kind" "$(jq -r .kind "$F")" "ticket"
check "row chief" "$(jq -r .chief "$F")" "Z"
check "row text" "$(jq -r .text "$F")" "file the fold bug"
check "ticket row has no key" "$(jq -r '.key // "none"' "$F")" "none"
check "row ts is UTC ISO" "$(jq -r .ts "$F")" "2027-01-15T08:00:00Z"
check "row epoch" "$(jq -r .epoch "$F")" "$NOW"

# add refusals write nothing
bash "$OWE" add --bucket "$B" --chief Z --kind bogus --text x >/dev/null 2>&1; rc=$?
check "an unknown kind exits 2" "$rc" "2"
bash "$OWE" add --bucket "$B" --chief Z --kind ticket --text '' >/dev/null 2>&1; rc=$?
check "an empty text exits 2" "$rc" "2"
bash "$OWE" add --bucket "$B" --chief Z --kind ticket --text $'two\nlines' >/dev/null 2>&1; rc=$?
check "a multi-line text exits 2" "$rc" "2"
bash "$OWE" add --bucket "$WORK/absent" --chief Z --kind ticket --text x >/dev/null 2>&1; rc=$?
check "an absent bucket exits 3" "$rc" "3"
check "refusals append nothing" "$(wc -l < "$F" | tr -d ' ')" "1"

# a second row, quotes and a tab survive
bash "$OWE" add --bucket "$B" --chief Z --kind proof --text $'live "succession"\tproof' >/dev/null
check "second id" "$(jq -r .id < <(sed -n 2p "$F"))" "o2"
check "a quote and a tab survive in the row" "$(jq -r .text < <(sed -n 2p "$F"))" $'live "succession"\tproof'

# list: open rows, tab separated: id kind epoch key chief text
list="$(bash "$OWE" list --bucket "$B")"
check "list shows both open rows" "$(printf '%s\n' "$list" | wc -l | tr -d ' ')" "2"
check "list row one" "$(printf '%s\n' "$list" | sed -n 1p)" "$(printf 'o1\tticket\t%s\t\tZ\tfile the fold bug' "$NOW")"
lacks "a tab in the text is flattened in list" "$(printf '%s\n' "$list" | sed -n 2p | cut -f6)" $'\t'

# close needs a key, an id that exists, and an open row; append-only
before="$(cat "$F")"
bash "$OWE" close --bucket "$B" --id o1 >/dev/null 2>&1; rc=$?
check "close without a key exits 2" "$rc" "2"
bash "$OWE" close --bucket "$B" --id o1 --key '' >/dev/null 2>&1; rc=$?
check "close with an empty key exits 2" "$rc" "2"
bash "$OWE" close --bucket "$B" --id o9 --key HIMMEL-1 >/dev/null 2>&1; rc=$?
check "close of an unknown id exits 1" "$rc" "1"
check "refused closes append nothing" "$(cat "$F")" "$before"

bash "$OWE" close --bucket "$B" --id o1 --key HIMMEL-10099 >/dev/null; rc=$?
check "close with a key exits 0" "$rc" "0"
check "earlier rows are byte-identical after a close" "$(head -n 2 "$F")" "$before"
check "the close is a new last row" "$(wc -l < "$F" | tr -d ' ')" "3"
check "closing row key" "$(sed -n 3p "$F" | jq -r .key)" "HIMMEL-10099"
check "closing row names its target" "$(sed -n 3p "$F" | jq -r .ref)" "o1"
list="$(bash "$OWE" list --bucket "$B")"
check "list drops the closed row" "$(printf '%s\n' "$list" | cut -f1)" "o2"
all="$(bash "$OWE" list --bucket "$B" --all)"
contains "list --all keeps the closed row with its key" "$all" "$(printf 'o1\tticket\t%s\tHIMMEL-10099\tZ' "$NOW")"
bash "$OWE" close --bucket "$B" --id o1 --key HIMMEL-10099 >/dev/null 2>&1; rc=$?
check "closing a closed row exits 1" "$rc" "1"

# a proof closes on a sha
bash "$OWE" close --bucket "$B" --id o2 --key 0123abc >/dev/null; rc=$?
check "a proof closes on a sha" "$rc" "0"
check "nothing is open" "$(bash "$OWE" list --bucket "$B")" ""

# a tab or newline in --chief would shift the columns of list
bash "$OWE" add --bucket "$B" --chief $'Z\tX' --kind ticket --text x >/dev/null 2>&1; rc=$?
check "a tab in --chief exits 2" "$rc" "2"
bash "$OWE" add --bucket "$B" --chief $'Z\nX' --kind ticket --text x >/dev/null 2>&1; rc=$?
check "a newline in --chief exits 2" "$rc" "2"

# the unit separator is the delimiter chief.sh parses the rows with
bash "$OWE" add --bucket "$B" --chief $'Z\037X' --kind ticket --text x >/dev/null 2>&1; rc=$?
check "a unit separator in --chief exits 2" "$rc" "2"
bash "$OWE" add --bucket "$B" --chief Z --kind ticket --text $'a\037b' >/dev/null 2>&1; rc=$?
check "a unit separator in --text exits 2" "$rc" "2"

# no flock: the add stops, it never writes unlocked
NF="$WORK/noflock-bin"; mkdir -p "$NF"; ln -s "$(command -v jq)" "$NF/jq"; ln -s "$(command -v date)" "$NF/date"
NB="$WORK/noflock"; mkdir -p "$NB"
PATH="$NF" "$(command -v bash)" "$OWE" add --bucket "$NB" --chief Z --kind ticket --text x >/dev/null 2>&1; rc=$?
check "an add on a host with no flock exits 4" "$rc" "4"
check "and writes no row" "$(wc -l < "$NB/owed.jsonl" | tr -d ' ')" "0"

# concurrent adds each get their own id, so every one can be closed
C="$WORK/concurrent"; mkdir -p "$C"
for _n in 1 2 3 4 5 6 7 8; do bash "$OWE" add --bucket "$C" --chief Z --kind ticket --text "row $_n" >/dev/null & done
wait
check "eight concurrent adds write eight rows" "$(wc -l < "$C/owed.jsonl" | tr -d ' ')" "8"
check "eight concurrent adds get eight distinct ids" "$(jq -r .id "$C/owed.jsonl" | sort -u | wc -l | tr -d ' ')" "8"
bash "$OWE" close --bucket "$C" --id o3 --key HIMMEL-1 >/dev/null 2>&1; rc=$?
check "a row added concurrently can be closed" "$rc" "0"

# a missing file lists nothing
check "an empty bucket lists nothing" "$(mkdir -p "$WORK/empty" && bash "$OWE" list --bucket "$WORK/empty"; echo "rc=$?")" "rc=0"

[ "$fails" -eq 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "test-owe: all checks passed"
