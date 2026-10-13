#!/usr/bin/env python3
# GREEN: every repository-redirecting variable is dropped from the child env.
import os
import subprocess
import sys

SCRUB = ['GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE',
         'GIT_OBJECT_DIRECTORY', 'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_PREFIX',
         'GIT_IMPLICIT_WORK_TREE', 'GIT_GRAFT_FILE', 'GIT_REPLACE_REF_BASE',
         'GIT_SHALLOW_FILE', 'GIT_CONFIG', 'GIT_CONFIG_PARAMETERS', 'GIT_CONFIG_COUNT']
env = {k: v for k, v in os.environ.items() if k not in SCRUB}
print(subprocess.run(['git', '-C', sys.argv[1], 'status'], env=env, capture_output=True, text=True).stdout)
