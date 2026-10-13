import { execFileSync } from 'node:child_process';

// RED: the call's env drops only the ORIGINAL four variables.
export function status(repoRoot, fullEnv) {
  return execFileSync('git', ['-C', repoRoot, 'status'], {
    encoding: 'utf8',
    env: (() => {
      const { GIT_DIR, GIT_WORK_TREE, GIT_COMMON_DIR, GIT_INDEX_FILE, ...rest } = fullEnv;
      return rest;
    })(),
  });
}
