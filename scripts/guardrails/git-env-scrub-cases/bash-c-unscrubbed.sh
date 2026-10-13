#!/usr/bin/env bash
# RED: git run through `bash -c '...'` — the quoted payload is blanked by the
# string stripper, so the call was invisible.
set -euo pipefail
bash -c 'git -C "$0" rev-parse --git-common-dir' "$1"
