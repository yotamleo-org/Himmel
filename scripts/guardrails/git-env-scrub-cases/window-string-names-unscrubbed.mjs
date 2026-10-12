import { execFileSync } from 'node:child_process';

// RED: every scrub name appears in the window, but only as string literals
// in a list nothing applies to the call's env.
export function status(repoRoot) {
  const out = execFileSync('git', ['-C', repoRoot, 'status'], { encoding: 'utf8' });
  const names = ['GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE',
    'GIT_OBJECT_DIRECTORY', 'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_PREFIX',
    'GIT_IMPLICIT_WORK_TREE', 'GIT_GRAFT_FILE', 'GIT_REPLACE_REF_BASE',
    'GIT_SHALLOW_FILE', 'GIT_CONFIG', 'GIT_CONFIG_PARAMETERS', 'GIT_CONFIG_COUNT'];
  return { out, names };
}
