#!/usr/bin/env bash
# API launcher fixtures, dummy secrets and a stub claude only. Also runs the
# shift-spend readers (shift-spend.test.mjs): vendor-doc response fixtures, no live call.
# Platform guard: bash + node on local files; Linux verified.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
if [ "$(uname -s)" = Darwin ]; then
  echo "SKIP - macOS lacks flock and /proc, which bulk-call.sh needs; tracked by HIMMEL-7252 (the shift-spend readers need neither and still run)"
  exec node --test "$REPO/scripts/api-lane/shift-spend.test.mjs"
fi
exec node --test "$REPO/scripts/api-lane/claude-api.test.mjs" "$REPO/scripts/api-lane/judge-call.test.mjs" "$REPO/scripts/api-lane/bulk-call.test.mjs" "$REPO/scripts/api-lane/shift-spend.test.mjs"
