import { execFileSync } from 'node:child_process';

// GREEN: every repository-redirecting variable is dropped from the env this
// call is given, as real code inside the call's own argument list.
export function status(repoRoot, fullEnv) {
  return execFileSync('git', ['-C', repoRoot, 'status'], {
    encoding: 'utf8',
    env: (() => {
      const {
        GIT_DIR, GIT_WORK_TREE, GIT_COMMON_DIR, GIT_INDEX_FILE,
        GIT_OBJECT_DIRECTORY, GIT_ALTERNATE_OBJECT_DIRECTORIES, GIT_PREFIX,
        GIT_IMPLICIT_WORK_TREE, GIT_GRAFT_FILE, GIT_REPLACE_REF_BASE,
        GIT_SHALLOW_FILE, GIT_CONFIG, GIT_CONFIG_PARAMETERS, GIT_CONFIG_COUNT,
        ...rest
      } = fullEnv;
      return rest;
    })(),
  });
}
