#!/usr/bin/env bash
# Smoke test for scripts/ci/check-actions-pinned.sh.
#
# Usage: bash scripts/ci/test-check-actions-pinned.sh
#
# Exit codes:
#   0 — all cases passed
#   1 — at least one case failed
set -uo pipefail

GUARD="$(cd "$(dirname "$0")" && pwd)/check-actions-pinned.sh"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/h6559.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT

sha=0123456789abcdef0123456789abcdef01234567

expect() { # <label> <want-rc> <file>
  bash "$GUARD" "$3" >"$tmp/out" 2>&1; rc=$?
  if [ "$rc" -eq "$2" ]; then pass "$1 -> exit $2"; else fail "$1 -> expected $2 got $rc"; fi
}

printf 'jobs:\n  a:\n    steps:\n      - uses: actions/checkout@v7\n' > "$tmp/tag.yml"
expect "tag-pinned" 1 "$tmp/tag.yml"
if grep -q 'tag.yml:4' "$tmp/out"; then pass "offender named with file:line"; else fail "offender not named"; fi

printf '    steps:\n      - uses: actions/checkout@main\n' > "$tmp/branch.yml"
expect "branch-pinned" 1 "$tmp/branch.yml"

printf '    steps:\n      - uses: actions/checkout@%s0\n' "$sha" > "$tmp/long.yml"
expect "41-hex ref" 1 "$tmp/long.yml"

printf '    steps:\n      - uses: actions/checkout@v7 # @%s\n' "$sha" > "$tmp/commented-sha.yml"
expect "tag pin with a sha-looking comment" 1 "$tmp/commented-sha.yml"

printf '    steps:\n      - uses: actions/checkout@%s # v7.0.1\n' "$sha" > "$tmp/sha.yml"
expect "sha-pinned with comment" 0 "$tmp/sha.yml"

printf '    steps:\n      - uses: "actions/checkout@%s"\n' "$sha" > "$tmp/quoted.yml"
expect "sha-pinned, quoted" 0 "$tmp/quoted.yml"

printf '    steps:\n      - uses: ./.github/actions/local\n      - uses: docker://alpine@sha256:%064d\n' 0 > "$tmp/exempt.yml"
expect "local + docker refs exempt" 0 "$tmp/exempt.yml"

printf '# uses: actions/checkout@v7 is only a comment\n' > "$tmp/comment.yml"
expect "commented-out uses" 0 "$tmp/comment.yml"

echo "== absent scan path =="
bash "$GUARD" "$tmp/does-not-exist" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ]; then pass "absent path -> exit 0"; else fail "absent path -> expected 0 got $rc"; fi

echo "== real repo .github clean =="
( cd "$REPO_ROOT" && bash scripts/ci/check-actions-pinned.sh ) >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ]; then pass "repo .github -> exit 0"; else fail "repo .github -> expected 0 got $rc"; fi

echo
if [ "$failures" -eq 0 ]; then
  echo "ALL PASS"
  exit 0
else
  echo "$failures FAILURE(S)"
  exit 1
fi
