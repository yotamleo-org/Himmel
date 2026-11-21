#!/usr/bin/env bash
# Offline real-entrypoint and ownership races; no provider calls or live state.
set -uo pipefail
exec python3 -B "$(cd "$(dirname "$0")" && pwd)/test-fleet-runtime.py"
