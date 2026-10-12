// fixture: control for multiline-unscrubbed.mjs — the same multi-line call
// shape, with the four scrub keys in the statement's env: object. Must pass.
import { execFileSync } from 'node:child_process';

export function head() {
  const env = { ...process.env };
  return execFileSync(
    'git',
    ['rev-parse', 'HEAD'],
    { encoding: 'utf8', env: { ...env, GIT_DIR: undefined, GIT_WORK_TREE: undefined, GIT_COMMON_DIR: undefined, GIT_INDEX_FILE: undefined } },
  );
}
