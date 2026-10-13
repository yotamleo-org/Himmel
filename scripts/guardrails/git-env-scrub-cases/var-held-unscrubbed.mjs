import { execFileSync } from 'node:child_process';

// RED: 'git' held in a constant and passed to the spawn call by name.
const GIT = 'git';

export function status(repoRoot) {
  return execFileSync(GIT, ['-C', repoRoot, 'status'], { encoding: 'utf8' });
}
