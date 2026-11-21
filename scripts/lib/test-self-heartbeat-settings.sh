#!/usr/bin/env bash
# Offline node:test run of the C0p self-heartbeat settings reader; every fixture is a temp dir the test owns.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
command -v node >/dev/null 2>&1 || { echo "FAIL: node not found, the self-heartbeat settings test went unrun" >&2; exit 1; }
exec node --test "$HERE/test-self-heartbeat-settings.mjs"
