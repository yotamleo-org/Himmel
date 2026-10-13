#!/usr/bin/env bash
# GREEN control for unset-in-uncalled-fn-unscrubbed.sh: the same function, but
# it is CALLED before the first git invocation.
set -euo pipefail
scrub_env() {
    unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
        GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX \
        GIT_IMPLICIT_WORK_TREE GIT_GRAFT_FILE \
        GIT_REPLACE_REF_BASE GIT_SHALLOW_FILE GIT_CONFIG \
        GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
}
scrub_env
git -C "$1" rev-parse --git-common-dir
