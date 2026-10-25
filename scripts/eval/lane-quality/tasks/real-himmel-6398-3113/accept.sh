#!/usr/bin/env bash
# Hidden acceptance for a mined real task: the merged tests in hidden/ replace
# the agent's copies in a scratch copy of its tree, then run there.
# Usage: accept.sh <tree> [fixture-sha]
HERE="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$HERE/../../mine-tasks.py" accept "$HERE" "$@"
