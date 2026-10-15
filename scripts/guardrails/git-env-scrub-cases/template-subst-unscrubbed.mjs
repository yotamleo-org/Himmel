// fixture: an unscrubbed git spawn inside a template literal's `${...}`
// substitution — the substitution is code, so it must be flagged (a
// whole-template opaque token would let this escape).
import { execFileSync } from 'node:child_process';

export function describe(repoRoot) {
  return `head is ${execFileSync('git', ['-C', repoRoot, 'rev-parse', 'HEAD'], { encoding: 'utf8' })}`;
}
