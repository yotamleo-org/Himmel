#!/usr/bin/env bash
# Offline tests for research_path.py (no network).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -I "$SCRIPT_DIR/test_research_path.py"
