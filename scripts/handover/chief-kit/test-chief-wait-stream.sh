#!/usr/bin/env bash
# Offline process tests: no provider, bridge or remote transport.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
exec python3 -I "$HERE/test-chief-wait-stream.py" "$@"
