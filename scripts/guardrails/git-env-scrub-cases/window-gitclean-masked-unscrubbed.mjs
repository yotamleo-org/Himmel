import { execFileSync } from 'node:child_process';
import { gitClean } from '../../lanes/git-clean.mjs';

// RED: the raw call below has no scrub of its own; the gitClean() call a few
// lines later is a DIFFERENT call and must not satisfy it.
export function both(repoRoot) {
  const a = execFileSync('git', ['-C', repoRoot, 'status'], { encoding: 'utf8' });
  const b = gitClean(['-C', repoRoot, 'status'], { encoding: 'utf8' });
  return a + b;
}
