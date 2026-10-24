#!/usr/bin/env bash
# API launcher fixtures, dummy secrets and a stub claude only.
# Platform guard: bash + node on local files; Linux verified, no .ps1 twin.
set -uo pipefail
if [ "$(uname -s)" = Darwin ]; then
  echo "SKIP - macOS lacks flock and /proc, which bulk-call.sh needs; tracked by HIMMEL-7252"
  exit 0
fi
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
exec node --test "$REPO/scripts/api-lane/claude-api.test.mjs" "$REPO/scripts/api-lane/judge-call.test.mjs" "$REPO/scripts/api-lane/bulk-call.test.mjs"
