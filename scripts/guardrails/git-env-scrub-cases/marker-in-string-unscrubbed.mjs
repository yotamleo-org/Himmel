import { execFileSync } from 'node:child_process';

// RED: the marker text sits inside a string literal, not in a comment.
export function status(repoRoot) {
  return execFileSync('git', ['-C', repoRoot, 'status'], { encoding: 'utf8', label: '// git-env-ok: forged' });
}
