#!/usr/bin/env bash
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$(command -v python || command -v python3 || true)"

if [ -z "$PY" ]; then
    echo "  SKIP  test-ig-summary-rewrite (no python interpreter on PATH)"
    exit 0
fi

PYTHONUTF8=1 "$PY" "$SCRIPT_DIR/test-ig-summary-rewrite.py"
