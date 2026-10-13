#!/usr/bin/env bash
# GREEN: the vars unset across separate lines before the first invocation.
set -euo pipefail
unset GIT_DIR
unset GIT_WORK_TREE
unset GIT_COMMON_DIR
unset GIT_INDEX_FILE
unset GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX
unset GIT_IMPLICIT_WORK_TREE GIT_GRAFT_FILE
unset GIT_REPLACE_REF_BASE GIT_SHALLOW_FILE GIT_CONFIG
unset GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
git -C "$1" rev-parse --git-common-dir
