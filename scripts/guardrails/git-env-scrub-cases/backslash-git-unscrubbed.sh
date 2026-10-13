#!/usr/bin/env bash
# RED: `\git` (alias-bypass spelling) is a git invocation.
set -euo pipefail
\git -C "$1" rev-parse --git-common-dir
