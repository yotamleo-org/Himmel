import { execFileSync } from 'node:child_process';

// RED: same shape as unscrubbed.mjs, in a .ts entry point.
export function status(repoRoot: string): string {
  return execFileSync('git', ['-C', repoRoot, 'status'], { encoding: 'utf8' });
}
