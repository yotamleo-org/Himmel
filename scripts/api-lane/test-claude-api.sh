#!/usr/bin/env bash
# HIMMEL-4985: API launcher fixtures, dummy secrets and a stub claude only.
# Platform guard: bash + node on local files; Linux verified, no .ps1 twin.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
exec node --test "$REPO/scripts/api-lane/claude-api.test.mjs" "$REPO/scripts/api-lane/judge-call.test.mjs" "$REPO/scripts/api-lane/bulk-call.test.mjs"
