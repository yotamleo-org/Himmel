const { execFileSync } = require('node:child_process');

// RED: same shape as unscrubbed.mjs, in a .cjs entry point.
exports.status = function status(repoRoot) {
  return execFileSync('git', ['-C', repoRoot, 'status'], { encoding: 'utf8' });
};
