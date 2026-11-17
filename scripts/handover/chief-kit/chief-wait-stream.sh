#!/usr/bin/env bash
# Linux Monitor adapter; the Python process owns the flock and its bounded tree.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
exec python3 -I "$HERE/chief-wait-stream.py" "$@"
