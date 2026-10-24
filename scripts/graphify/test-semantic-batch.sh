#!/usr/bin/env bash
# Batch client and record/replay shim against a stub endpoint on loopback; dummy key only.
# Platform guard: bash + node on local files; Linux verified, no .ps1 twin.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
exec node --test "$REPO/scripts/graphify/semantic-batch.test.mjs"
