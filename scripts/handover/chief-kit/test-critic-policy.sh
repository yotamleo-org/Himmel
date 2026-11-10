#!/usr/bin/env bash
# scripts/handover/chief-kit/test-critic-policy.sh — CI wrapper for the critic policy snapshot.
# Runs the explicit bun test list and returns its status. A missing bun fails; it never skips green.
# Never runs the scoped routing-diff CLI on the live checkout: the tests pass throwaway repos to it.
#
# Platform guard: POSIX bash 3.2+.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

if ! command -v bun >/dev/null 2>&1; then
  echo "FAIL: bun is not on PATH; the critic policy tests cannot run" >&2
  exit 1
fi

cd "$ROOT" || exit 1
bun test scripts/handover/chief-kit/critic-policy.test.ts
