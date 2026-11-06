#!/usr/bin/env bash
# scripts/cr/test-suite-fail-ledger.sh — suite for suite-fail-ledger.sh, the reader
# of ready-check's CI failure ledger. Real jq, a fixture ledger.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/suite-fail-ledger.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/suite-fail-ledger-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails + 1)); fi; }

L="$tmp/ci-failures.jsonl"
{
    # head h1: two suites failed in run 1, one again in run 2 (a re-run), then a new push
    printf '{"kind":"fail","repo":"o/r","pr":1,"head":"h1","suite":"a","run":1,"rc":1}\n'
    printf '{"kind":"fail","repo":"o/r","pr":1,"head":"h1","suite":"b","run":1,"rc":1}\n'
    printf '{"kind":"fail","repo":"o/r","pr":1,"head":"h1","suite":"a","run":2,"rc":1}\n'
    printf '{"kind":"fail","repo":"o/r","pr":1,"head":"h1","suite":"a","run":2,"rc":1}\n'
    printf '{"kind":"round","repo":"o/r","pr":1,"head":"h1","next":"h2"}\n'
    printf '{"kind":"round","repo":"o/r","pr":1,"head":"h1","next":"h3"}\n'
    # head h2 of another PR: a failure that went green on a re-run, no new push
    printf '{"kind":"fail","repo":"o/r","pr":2,"head":"h2","suite":"a","run":3,"rc":2}\n'
    # the same head and PR number in another repo is another head
    printf '{"kind":"fail","repo":"x/y","pr":1,"head":"h1","suite":"a","run":4,"rc":1}\n'
    printf 'not json\n'
    printf '{"kind":"round","repo":"o/r","pr":9,"head":"h9","next":"h10"}\n'
} > "$L"
rc=0; out=$(bash "$SCRIPT" "$L") || rc=$?
check "a ledger: exit 0" "$rc" "0"
check "a ledger: failures, heads, extra rounds and the rate" "$out" \
    "suite-fail-ledger: 5 CI failure(s) of a suite left to CI, at 3 head(s); 1 head(s) cost an extra round (33%)"

rc=0; out=$(bash "$SCRIPT" "$tmp/none.jsonl") || rc=$?
check "no ledger: exit 0" "$rc" "0"
check "no ledger: zero, no rate" "$out" "suite-fail-ledger: 0 CI failure(s) of a suite left to CI, at 0 head(s); 0 head(s) cost an extra round (n/a)"

rc=0; out=$(HOME="$tmp/home" bash "$SCRIPT") || rc=$?
check "the default path is under HOME: exit 0" "$rc" "0"
mkdir -p "$tmp/home/.himmel/state/suite-evidence"; cp "$L" "$tmp/home/.himmel/state/suite-evidence/ci-failures.jsonl"
out=$(HOME="$tmp/home" bash "$SCRIPT")
check "the default path is the station ledger" "${out%%,*}" "suite-fail-ledger: 5 CI failure(s) of a suite left to CI"

rc=0; bash "$SCRIPT" a b > /dev/null 2>&1 || rc=$?
check "two arguments: usage, exit 2" "$rc" "2"

# an existing ledger that cannot be read is an error, never a zero count
if [ "$(id -u)" -ne 0 ]; then
    : > "$tmp/unreadable.jsonl"; chmod 000 "$tmp/unreadable.jsonl"
    rc=0; out=$(bash "$SCRIPT" "$tmp/unreadable.jsonl" 2>&1) || rc=$?
    check "an unreadable ledger: exit 1" "$rc" "1"
    check "an unreadable ledger: says so" "${out%%:*}" "suite-fail-ledger"
fi

echo "---"
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$fails FAILED"
exit 1
