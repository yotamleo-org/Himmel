#!/usr/bin/env bash
# RED: git run through eval of a quoted string.
set -euo pipefail
eval "git -C $1 rev-parse --git-common-dir"
