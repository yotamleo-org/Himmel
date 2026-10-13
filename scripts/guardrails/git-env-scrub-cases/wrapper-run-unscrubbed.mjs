import { spawnSync } from 'node:child_process';

// RED: a local helper that spawns whatever it is given, called with 'git'.
// The raw spawnSync(cmd, ...) inside it never names git.
function run(cmd, args) {
  return spawnSync(cmd, args, { encoding: 'utf8' });
}

export function status(repoRoot) {
  return run('git', ['-C', repoRoot, 'status']);
}
