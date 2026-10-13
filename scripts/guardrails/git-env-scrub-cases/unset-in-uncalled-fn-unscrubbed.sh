#!/usr/bin/env bash
# RED: the unset lives in a function nothing ever calls, so no variable is
# scrubbed when the bare git below runs.
set -euo pipefail
scrub_env() {
    unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
        GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX \
        GIT_IMPLICIT_WORK_TREE GIT_GRAFT_FILE \
        GIT_REPLACE_REF_BASE GIT_SHALLOW_FILE GIT_CONFIG \
        GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
}
git -C "$1" rev-parse --git-common-dir
