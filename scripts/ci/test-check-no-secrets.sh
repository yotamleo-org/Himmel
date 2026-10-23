#!/usr/bin/env bash
# Smoke test for scripts/ci/check-no-secrets.sh.
#
# Creates hermetic sandboxes (mktemp -d), exercises each case, asserts rc.
# The guard accepts an optional positional scan dir; tests pass the sandbox dir.
#
# Usage: bash scripts/ci/test-check-no-secrets.sh
#
# Exit codes:
#   0 — all cases passed
#   1 — at least one case failed
set -uo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone.
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

GUARD="$(cd "$(dirname "$0")" && pwd)/check-no-secrets.sh"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

# Case A: clean dir — no secret interpolation → guard exits 0
echo "== Case A: clean workflow =="
dir_a=$(mktemp -d)
cat > "$dir_a/clean.yml" <<'YAML'
name: CI
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
YAML
bash "$GUARD" "$dir_a"
rc=$?
if [ "$rc" -eq 0 ]; then pass "clean.yml -> exit 0"; else fail "clean.yml -> expected 0 got $rc"; fi
rm -rf "$dir_a"

# Case B: workflow containing a secrets interpolation → guard exits 1
#         and names the offending file
echo "== Case B: leaking workflow =="
dir_b=$(mktemp -d)
# We write the interpolation as two concatenated pieces so THIS test file
# itself does not contain a literal secrets-interpolation pattern.
# shellcheck disable=SC2016  # single-quotes intentional: prevent ${{ expansion
piece1='${{ '
piece2='secrets.FOO }}'
printf 'name: Release\non: [push]\njobs:\n  deploy:\n    runs-on: ubuntu-latest\n    env:\n      TOKEN: %s%s\n' \
  "$piece1" "$piece2" > "$dir_b/leak.yml"
out=$(bash "$GUARD" "$dir_b" 2>&1)
rc=$?
if [ "$rc" -eq 1 ]; then pass "leak.yml -> exit 1"; else fail "leak.yml -> expected 1 got $rc"; fi
if grepq "$out" -F "leak.yml"; then
  pass "leak.yml -> filename reported"
else
  fail "leak.yml -> expected filename in output, got: $out"
fi
rm -rf "$dir_b"

# Case C: file mentions the word "secrets" in a comment but NOT as
#         ${{ secrets.* }} interpolation → guard exits 0 (no false positive)
echo "== Case C: comment-only mention of secrets =="
dir_c=$(mktemp -d)
cat > "$dir_c/comment.yml" <<'YAML'
name: Docs
# This job does NOT use any secrets.
# See docs/secrets-policy.md for the secrets rotation schedule.
on: [push]
jobs:
  docs:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
YAML
bash "$GUARD" "$dir_c"
rc=$?
if [ "$rc" -eq 0 ]; then pass "comment-only secrets -> exit 0 (no FP)"; else fail "comment-only secrets -> expected 0 got $rc"; fi
rm -rf "$dir_c"

# Cases D-F: the one allowed interpolation. snyk-weekly.yml may carry exactly
# the SNYK_TOKEN line; any other secret there, or that line elsewhere, fails.
REAL_SNYK="$(cd "$(dirname "$0")/../.." && pwd)/.github/workflows/snyk-weekly.yml"
allowed_line="      SNYK_TOKEN: ${piece1}secrets.SNYK_TOKEN }}"

echo "== Case D: the real snyk-weekly.yml =="
dir_d=$(mktemp -d "${TMPDIR:-/tmp}/no-secrets.XXXXXX") || exit 1
cp "$REAL_SNYK" "$dir_d/snyk-weekly.yml"
bash "$GUARD" "$dir_d" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then pass "snyk-weekly.yml SNYK_TOKEN line -> exit 0"; else fail "snyk-weekly.yml SNYK_TOKEN line -> expected 0 got $rc"; fi
rm -rf "$dir_d"

echo "== Case E: a second secret in snyk-weekly.yml =="
dir_e=$(mktemp -d "${TMPDIR:-/tmp}/no-secrets.XXXXXX") || exit 1
cp "$REAL_SNYK" "$dir_e/snyk-weekly.yml"
printf '      OTHER: %ssecrets.OTHER }}\n' "$piece1" >> "$dir_e/snyk-weekly.yml"
bash "$GUARD" "$dir_e" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 1 ]; then pass "second secret in snyk-weekly.yml -> exit 1"; else fail "second secret in snyk-weekly.yml -> expected 1 got $rc"; fi
rm -rf "$dir_e"

echo "== Case F: the same line in another workflow =="
dir_f=$(mktemp -d "${TMPDIR:-/tmp}/no-secrets.XXXXXX") || exit 1
printf 'name: X\non: [push]\njobs:\n  j:\n    runs-on: ubuntu-latest\n    env:\n%s\n' "$allowed_line" > "$dir_f/other.yml"
bash "$GUARD" "$dir_f" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 1 ]; then pass "SNYK_TOKEN line in other.yml -> exit 1"; else fail "SNYK_TOKEN line in other.yml -> expected 1 got $rc"; fi
rm -rf "$dir_f"

# Final tally
if [ "$failures" -eq 0 ]; then
  echo "OK: all cases passed"
  exit 0
else
  echo "FAIL: $failures case(s) failed"
  exit 1
fi
