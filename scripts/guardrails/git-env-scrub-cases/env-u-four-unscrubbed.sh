#!/usr/bin/env bash
# RED: a per-call `env -u` of only the original four variables.
set -euo pipefail
env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE git -C "$1" rev-parse --git-common-dir
