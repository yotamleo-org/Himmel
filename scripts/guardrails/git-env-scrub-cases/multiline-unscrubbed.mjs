// fixture: an execFileSync( call whose 'git' argument is on the NEXT line,
// with no scrub anywhere — must be flagged (HIMMEL-3571 item 1).
import { execFileSync } from 'node:child_process';

export function head() {
  return execFileSync(
    'git',
    ['rev-parse', 'HEAD'],
    { encoding: 'utf8' },
  );
}
