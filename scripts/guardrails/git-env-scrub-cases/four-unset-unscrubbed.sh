#!/usr/bin/env bash
# RED: a hand scrub of only the ORIGINAL four variables; the other ten
# repository-redirecting variables are still inherited.
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
git -C "$1" rev-parse --git-common-dir
