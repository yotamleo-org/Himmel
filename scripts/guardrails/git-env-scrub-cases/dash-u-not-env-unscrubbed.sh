#!/usr/bin/env bash
# RED: `-u NAME` words that belong to no `env` wrapper are plain arguments to
# git, not a scrub. All 14 names appear, none is unset.
set -euo pipefail
git -C "$1" status -- -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_PREFIX -u GIT_IMPLICIT_WORK_TREE -u GIT_GRAFT_FILE -u GIT_REPLACE_REF_BASE -u GIT_SHALLOW_FILE -u GIT_CONFIG -u GIT_CONFIG_PARAMETERS -u GIT_CONFIG_COUNT
