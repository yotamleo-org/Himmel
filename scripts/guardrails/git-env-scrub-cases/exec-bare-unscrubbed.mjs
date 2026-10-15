import { exec } from 'node:child_process';

// RED: bare `exec(` (no `Sync`, no `File`) — the call-name list used to
// cover only execFileSync/spawnSync/execSync/spawn and missed exec/execFile
// entirely. No scrub visible, no exemption.
export function status(cb) {
  exec('git status', { encoding: 'utf8' }, cb);
}
