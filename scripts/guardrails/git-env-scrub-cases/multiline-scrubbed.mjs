// fixture: control for multiline-unscrubbed.mjs — the same multi-line call
// shape, with every scrub key in the statement's env: object. Must pass.
import { execFileSync } from 'node:child_process';

export function head() {
  const env = { ...process.env };
  return execFileSync(
    'git',
    ['rev-parse', 'HEAD'],
    {
      encoding: 'utf8',
      env: {
        ...env,
        GIT_DIR: undefined, GIT_WORK_TREE: undefined, GIT_COMMON_DIR: undefined, GIT_INDEX_FILE: undefined,
        GIT_OBJECT_DIRECTORY: undefined, GIT_ALTERNATE_OBJECT_DIRECTORIES: undefined, GIT_PREFIX: undefined,
        GIT_IMPLICIT_WORK_TREE: undefined, GIT_GRAFT_FILE: undefined, GIT_REPLACE_REF_BASE: undefined,
        GIT_SHALLOW_FILE: undefined, GIT_CONFIG: undefined, GIT_CONFIG_PARAMETERS: undefined, GIT_CONFIG_COUNT: undefined,
      },
    },
  );
}
