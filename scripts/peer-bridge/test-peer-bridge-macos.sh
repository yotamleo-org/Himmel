#!/usr/bin/env bash
# test-peer-bridge-macos.sh - put the peer bridge's crash-order, admission and
# deadline suites on the macOS bed. Linux runs all peer-bridge suites in the
# ci.yml bun-suites job, so it only prints a SKIP here.
# Bash 3.2-compatible.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "SKIP: Linux runs these in ci.yml bun-suites"
    exit 0
fi
if ! command -v bun >/dev/null 2>&1; then
    echo "FAIL: bun is not on PATH" >&2
    exit 1
fi
cd "$root" || exit 1
exec bash scripts/ci/run-bun-tests.sh scripts/peer-bridge \
    scripts/peer-bridge/chain.test.ts scripts/peer-bridge/gate.test.ts scripts/peer-bridge/threads.test.ts \
    scripts/peer-bridge/envelope.test.ts scripts/peer-bridge/sign.test.ts scripts/peer-bridge/resolve.test.ts \
    scripts/peer-bridge/jobstate.test.ts
