#!/usr/bin/env bash
# Wrapper for the Instagram summary-rewrite tests (hermetic: no network, no
# ffmpeg, no whisper). Matches the repo's <name>.sh + <name>.py test-pair convention.
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$(command -v python || command -v python3 || true)"

if [ -z "$PY" ]; then
    echo "  SKIP  test-ig-summary-rewrite (no python interpreter on PATH)"
    exit 0
fi

PYTHONUTF8=1 "$PY" "$SCRIPT_DIR/test-ig-summary-rewrite.py"
