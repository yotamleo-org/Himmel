// fixture: a line comment between `(` and the 'git' argument must not hide
// the spawn (HIMMEL-5393 codex-3).
import { execFileSync } from 'node:child_process';

export function head(r) {
  return execFileSync( // repo head
    'git', ['-C', r, 'rev-parse', 'HEAD'], { encoding: 'utf8' });
}
