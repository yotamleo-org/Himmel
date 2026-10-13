#!/usr/bin/env bash
# RED: `$#` is not a comment, so the git call after it on the same line is
# still a call.
set -euo pipefail
echo $#; git -C "$1" rev-parse --git-common-dir
