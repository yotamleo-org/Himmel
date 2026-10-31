'use strict';
// scripts/lib/config-audit.cjs — the JS writers' side of config-audit.sh
// Usage: `const id = pre(file, script)` before a config write,
// `post(id, file, action, script)` after it. config-audit.sh decides what is
// station config (a set member, or a file under ~/.claude) and skips the rest.
// An audit fault warns on stderr and never throws: it must not fail a write.

const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const SH = path.join(__dirname, 'config-audit.sh');

function run(args, script) {
  if (!fs.existsSync(SH)) return '';
  const r = spawnSync('bash', [SH, ...args, '--script', script, '--pid', String(process.pid)],
    { encoding: 'utf8', timeout: 30000, stdio: ['ignore', 'pipe', 'pipe'] });
  if (r.status !== 0) {
    process.stderr.write(`config-audit: WARN: ${args[0]} for ${args[args.length > 2 ? 2 : 1]} failed\n`);
    return '';
  }
  return (r.stdout || '').trim();
}

const pre = (file, script) => run(['pre', file], script);
const post = (id, file, action, script) => { run(['post', id || '', file, action], script); };

module.exports = { pre, post };
