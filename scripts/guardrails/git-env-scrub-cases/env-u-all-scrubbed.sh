#!/usr/bin/env bash
# GREEN: a per-call `env -u` of every variable on the call's own (continued)
# line is a scrub of that call.
set -euo pipefail
env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE \
    -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_PREFIX \
    -u GIT_IMPLICIT_WORK_TREE -u GIT_GRAFT_FILE \
    -u GIT_REPLACE_REF_BASE -u GIT_SHALLOW_FILE -u GIT_CONFIG \
    -u GIT_CONFIG_PARAMETERS -u GIT_CONFIG_COUNT \
    git -C "$1" rev-parse --git-common-dir
