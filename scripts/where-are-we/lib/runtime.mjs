import { execFileSync, spawnSync } from 'node:child_process';
import { accessSync, closeSync, constants, openSync, realpathSync, statSync } from 'node:fs';
import { delimiter, dirname, join, resolve } from 'node:path';

const binCache = new Map();
export function findBin(names, probe = false) {
  const path = process.env.PATH ?? '';
  const cacheKey = `${path}\0${names.join(',')}\0${probe}`;
  if (binCache.has(cacheKey)) return binCache.get(cacheKey);
  let found = null;
  search: for (const name of names) {
    for (const dir of path.split(delimiter)) {
      const candidate = join(resolve(dir || '.'), name);
      try {
        if (!statSync(candidate).isFile()) continue;
        accessSync(candidate, constants.X_OK);
      } catch { continue; }
      if (probe && spawnSync(candidate, ['--version'], { stdio: 'ignore', timeout: 2000 }).status !== 0) continue;
      found = candidate;
      break search;
    }
  }
  binCache.set(cacheKey, found);
  return found;
}

export const timeoutBin = () => findBin(['timeout', 'gtimeout'], true);

export function spawnBounded(spawn, killAfter, limitSeconds, command, args, options) {
  const bin = timeoutBin();
  return bin
    ? spawn(bin, ['-k', killAfter, limitSeconds, command, ...args], options)
    : spawn(command, args, { ...options, killSignal: 'SIGKILL' });
}

const PERL_FLOCK = 'open(my $f,"<&=",3) or exit 2; my $end=time()+$ARGV[0];'
  + ' for(;;){ flock($f,LOCK_EX|LOCK_NB) and exit 0; ($!{EWOULDBLOCK}||$!{EAGAIN}) or exit 2; exit 75 if time()>=$end; sleep 0.02 }';
const PYTHON_FLOCK = 'import fcntl,sys,time,errno\nend=time.time()+float(sys.argv[1])\n'
  + 'while True:\n try:\n  fcntl.flock(3,fcntl.LOCK_EX|fcntl.LOCK_NB); sys.exit(0)\n'
  + ' except OSError as e:\n  if e.errno not in (errno.EAGAIN,errno.EACCES): sys.exit(2)\n'
  + ' if time.time()>=end: sys.exit(75)\n time.sleep(0.02)\n';

function flockInvocation(waitMs) {
  const seconds = String(waitMs / 1000);
  const flock = findBin(['flock']);
  if (flock) return [flock, waitMs > 0 ? ['-w', String(Math.ceil(waitMs / 1000)), '-E', '75', '3'] : ['-n', '-E', '75', '3']];
  const perl = findBin(['perl']);
  if (perl) return [perl, ['-MTime::HiRes=time,sleep', '-MFcntl=:flock', '-e', PERL_FLOCK, seconds]];
  const python = findBin(['python3']);
  if (python) return [python, ['-I', '-c', PYTHON_FLOCK, seconds]];
  return null;
}

// Use the same kernel flock primitive as scripts/lib/prim.sh. The permanent
// file is never unlinked: owner death releases the descriptor, not its pathname.
// No PID or age test can steal a live lock or mistake a reused PID for an owner.
export function collectionLock(ledger, outerDeadlineAt, { waitMs = 0, busy = 'collector already running; freshness unchanged' } = {}) {
  let canonical;
  try { canonical = realpathSync(ledger); } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    canonical = join(realpathSync(dirname(ledger)), ledger.split(/[\\/]/).pop());
  }
  const left = (outerDeadlineAt ?? Infinity) - Date.now();
  if (left <= 0) throw Object.assign(new Error('collection deadline exhausted'), { code: 'DEADLINE' });
  const wait = Math.min(waitMs, left);
  const timeoutMs = Math.min(wait > 0 ? wait + 200 : 1000, left);
  const invocation = flockInvocation(wait);
  if (!invocation) throw new Error('collector lock unavailable; local flock support is required');
  const fd = openSync(canonical + '.collect.lock', constants.O_CREAT | constants.O_RDWR | (constants.O_NOFOLLOW ?? 0), 0o600);
  const result = spawnSync(invocation[0], invocation[1], { stdio: ['ignore', 'pipe', 'pipe', fd], timeout: Math.ceil(timeoutMs) });
  if (result.status !== 0) {
    closeSync(fd);
    throw new Error(result.status === 75 || (wait > 0 && result.error?.code === 'ETIMEDOUT') ? busy : 'collector lock unavailable; local flock support is required');
  }
  return { fd, release: () => closeSync(fd) };
}

export function createBudget({ deadlineMs = 75000, deadlineAt, outerDeadlineAt, maxRequests = 80, clock = Date.now, lockFd } = {}) {
  const end = deadlineAt ?? clock() + Math.max(1, Math.min(90000, deadlineMs));
  let requests = 0;
  const remaining = () => {
    const left = end - clock();
    if (left <= 0) throw Object.assign(new Error('collection deadline exhausted'), { code: 'DEADLINE' });
    return left;
  };
  return {
    remaining,
    persistenceTimeout() {
      const left = (outerDeadlineAt ?? Infinity) - clock();
      if (left <= 0) throw Object.assign(new Error('collection persistence deadline exhausted'), { code: 'DEADLINE' });
      return Math.min(1000, left);
    },
    take() {
      remaining();
      if (requests >= Math.min(80, maxRequests)) throw Object.assign(new Error('collection request budget exhausted'), { code: 'BUDGET' });
      requests++;
    },
    run(command, args, options = {}) {
      const ms = Math.min(30000, remaining());
      const graceMs = outerDeadlineAt === undefined ? 200 : Math.min(200, Math.max(1, (outerDeadlineAt - end) / 2));
      // The watchdog survives collector death, bounds the whole command tree,
      // and retains its lock descriptor until its bounded child has stopped.
      return spawnBounded(execFileSync, `${graceMs / 1000}s`, `${ms / 1000}s`, command, args, {
        ...options, timeout: Math.ceil(ms + 1000), maxBuffer: 1024 * 1024,
        stdio: lockFd === undefined ? ['ignore', 'pipe', 'pipe'] : ['ignore', 'pipe', 'pipe', lockFd],
      });
    },
  };
}
