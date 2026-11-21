#!/usr/bin/env bash
# Offline regressions; helpers use fixture state and no remote transport.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
exec python3 -I "$HERE/test-t4-event-fixes.py" "$@"
