#!/usr/bin/env bash
# RED: git held in a variable and run through a quoted expansion.
set -euo pipefail
GITBIN="$(command -v git)"
"$GITBIN" -C "$1" rev-parse --git-common-dir
