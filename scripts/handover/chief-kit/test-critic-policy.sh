#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

if ! command -v bun >/dev/null 2>&1; then
  echo "FAIL: bun is not on PATH; the critic policy tests cannot run" >&2
  exit 1
fi

cd "$ROOT" || exit 1
bun test scripts/handover/chief-kit/critic-policy.test.ts
