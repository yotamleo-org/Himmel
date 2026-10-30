#!/usr/bin/env bash
# Focused render and delegated DOM controls regressions; no server or real secrets.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
bun test "$ROOT/scripts/config-ui/tests/configure-controls.test.ts" "$ROOT/scripts/config-ui/tests/settings.test.ts"
