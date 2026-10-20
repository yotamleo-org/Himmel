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

printf '    steps:\n      - uses: actions/checkout@main # uses: actions/checkout@%s\n' "$sha" > "$tmp/commented-uses.yml"
expect "tag pin with a second uses: in the comment" 1 "$tmp/commented-uses.yml"

printf '    steps:\n      - uses: actions/checkout@%s # v7.0.1\n' "$sha" > "$tmp/sha.yml"
expect "sha-pinned with comment" 0 "$tmp/sha.yml"

printf '    steps:\n      - uses: "actions/checkout@%s"\n' "$sha" > "$tmp/quoted.yml"
expect "sha-pinned, quoted" 0 "$tmp/quoted.yml"

printf '    steps:\n      - uses: ./.github/actions/local\n      - uses: docker://alpine@sha256:%064d\n' 0 > "$tmp/exempt.yml"
expect "local + docker refs exempt" 0 "$tmp/exempt.yml"

printf '    steps:\n      - uses: docker://alpine@sha256:%064dXYZ\n' 0 > "$tmp/docker-trailing.yml"
expect "docker digest with trailing characters" 1 "$tmp/docker-trailing.yml"

printf '    steps:\n      - uses: docker://alpine:latest\n' > "$tmp/docker-tag.yml"
expect "docker:// ref without a digest" 1 "$tmp/docker-tag.yml"

printf '# uses: actions/checkout@v7 is only a comment\n' > "$tmp/comment.yml"
expect "commented-out uses" 0 "$tmp/comment.yml"

printf '    steps:\n      - uses: actions/checkout@v7\n' > "$tmp/a:b.yml"
expect "tag-pinned in a colon-containing filename" 1 "$tmp/a:b.yml"

printf '    steps:\n      - uses: actions/checkout@v7 # x:3: uses: a/b@%s\n' "$sha" > "$tmp/colon-comment.yml"
expect "tag pin with a :N: uses: sha tail in the comment" 1 "$tmp/colon-comment.yml"

echo "== container: and services: image refs =="
dig=$(printf '%064d' 0)
printf 'jobs:\n  a:\n    container: ghcr.io/o/img:v1\n' > "$tmp/ctr-tag.yml"
expect "tag-pinned container: string" 1 "$tmp/ctr-tag.yml"
printf 'jobs:\n  a:\n    container:\n      image: ghcr.io/o/img:latest\n' > "$tmp/ctr-image-tag.yml"
expect "tag-pinned container: image:" 1 "$tmp/ctr-image-tag.yml"
printf 'jobs:\n  a:\n    services:\n      db:\n        image: postgres:16\n' > "$tmp/svc-tag.yml"
expect "tag-pinned services: image:" 1 "$tmp/svc-tag.yml"
printf 'jobs:\n  a:\n    container:\n      image: ghcr.io/o/img:v1 # @sha256:%s\n' "$dig" > "$tmp/ctr-commented.yml"
expect "tag-pinned image with a digest-looking comment" 1 "$tmp/ctr-commented.yml"
printf "jobs:\n  a:\n    container:\n      image: \${{ vars.CI_IMAGE || 'ghcr.io/o/img:v1' }}\n" > "$tmp/ctr-expr-tag.yml"
expect "expression whose default is tag-pinned" 1 "$tmp/ctr-expr-tag.yml"
printf 'jobs:\n  a:\n    container: ghcr.io/o/img@sha256:%s\n    services:\n      db:\n        image: "postgres@sha256:%s"\n' "$dig" "$dig" > "$tmp/ctr-digest.yml"
expect "digest-pinned container: and services: image:" 0 "$tmp/ctr-digest.yml"
printf "jobs:\n  a:\n    container:\n      image: \${{ vars.CI_IMAGE || 'ghcr.io/o/img@sha256:%s' }}\n" "$dig" > "$tmp/ctr-expr-digest.yml"
expect "expression whose default is digest-pinned" 0 "$tmp/ctr-expr-digest.yml"
printf "jobs:\n  a:\n    container:\n      image: \${{ vars.X == 'on' && 'ubuntu' || 'ghcr.io/o/img@sha256:%s' }}\n" "$dig" > "$tmp/ctr-expr-bare.yml"
expect "expression with a bare-name image branch" 1 "$tmp/ctr-expr-bare.yml"
printf "jobs:\n  a:\n    container:\n      image: \"\${{ vars.X == 'on' && '' || 'ghcr.io/o/img@sha256:%s' }}\"\n" "$dig" > "$tmp/ctr-expr-quoted.yml"
expect "YAML-quoted expression with a digest default and an empty branch" 0 "$tmp/ctr-expr-quoted.yml"
printf "jobs:\n  a:\n    container:\n      image: '\${{ vars.CI_IMAGE || ''ghcr.io/o/img@sha256:%s'' }}'\n" "$dig" > "$tmp/ctr-expr-squoted.yml"
expect "single-quoted YAML expression with a digest default" 0 "$tmp/ctr-expr-squoted.yml"
printf "jobs:\n  a:\n    services:\n      db: {image: 'postgres:16'}\n" > "$tmp/svc-flow.yml"
expect "flow-mapping services image (not scanned, so refused)" 1 "$tmp/svc-flow.yml"
printf '    steps:\n      - {uses: actions/checkout@v7}\n' > "$tmp/uses-flow.yml"
expect "flow-mapping uses: (not scanned, so refused)" 1 "$tmp/uses-flow.yml"

echo "== unreadable file is a scan failure, not a clean pass =="
printf '    steps:\n      - uses: actions/checkout@v7\n' > "$tmp/locked.yml"
chmod 000 "$tmp/locked.yml"
if [ -r "$tmp/locked.yml" ]; then
  pass "skipped: running as a user that can read mode-000 files"
else
  bash "$GUARD" "$tmp/locked.yml" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 2 ]; then pass "unreadable file -> exit 2"; else fail "unreadable file -> expected 2 got $rc"; fi
fi

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
