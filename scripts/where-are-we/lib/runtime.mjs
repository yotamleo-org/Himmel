import { execFileSync, spawnSync } from 'node:child_process';
import { closeSync, constants, openSync, realpathSync } from 'node:fs';
import { dirname, join } from 'node:path';

// Use the same kernel flock primitive as scripts/lib/prim.sh. The permanent
// file is never unlinked: owner death releases the descriptor, not its pathname.
// No PID or age test can steal a live lock or mistake a reused PID for an owner.
export function collectionLock(ledger) {
  let canonical;
  try { canonical = realpathSync(ledger); } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    canonical = join(realpathSync(dirname(ledger)), ledger.split(/[\\/]/).pop());
  }
  const fd = openSync(canonical + '.collect.lock', constants.O_CREAT | constants.O_RDWR | (constants.O_NOFOLLOW ?? 0), 0o600);
  const result = spawnSync('flock', ['-n', '-E', '75', '3'], { stdio: ['ignore', 'pipe', 'pipe', fd], timeout: 1000 });
  if (result.status !== 0) {
    closeSync(fd);
    throw new Error(result.status === 75 ? 'collector already running; freshness unchanged' : 'collector lock unavailable; local flock support is required');
  }
  return { fd, release: () => closeSync(fd) };
}

export function createBudget({ deadlineMs = 180000, maxRequests = 80, clock = Date.now, lockFd } = {}) {
  const end = clock() + Math.max(1, Math.min(180000, deadlineMs));
  let requests = 0;
  const remaining = () => {
    const left = end - clock();
    if (left <= 0) throw Object.assign(new Error('collection deadline exhausted'), { code: 'DEADLINE' });
    return left;
  };
  return {
    remaining,
    take() {
      remaining();
      if (requests >= Math.min(80, maxRequests)) throw Object.assign(new Error('collection request budget exhausted'), { code: 'BUDGET' });
      requests++;
    },
    run(command, args, options = {}) {
      const ms = Math.min(30000, remaining());
      // The watchdog survives collector death, bounds the whole command tree,
      // and retains its lock descriptor until its bounded child has stopped.
      return execFileSync('timeout', ['-k', '0.2', `${ms / 1000}s`, command, ...args], {
        ...options, timeout: ms + 1000, maxBuffer: 1024 * 1024,
        stdio: lockFd === undefined ? ['ignore', 'pipe', 'pipe'] : ['ignore', 'pipe', 'pipe', lockFd],
      });
    },
  };
}
