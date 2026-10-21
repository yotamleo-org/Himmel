import { createHash, createHmac, randomBytes, timingSafeEqual } from 'node:crypto';
import {
  appendFileSync, closeSync, existsSync, fstatSync, futimesSync, mkdirSync, openSync, readFileSync, renameSync, statSync, unlinkSync,
  writeFileSync,
} from 'node:fs';
import { dirname } from 'node:path';

// The signed, hash-chained store behind every authority file (design §5.2).
// ponytail: same-uid trust — a process that reads the key can mint a valid row
// (accepted by decision 109 for v1.1.3/v1.1.4); upgrade path is a broker
// running as a separate OS user that holds the key.

export const GENESIS = 'genesis';

export function canonical(v: unknown): string {
  if (Array.isArray(v)) return `[${v.map(canonical).join(',')}]`;
  if (v !== null && typeof v === 'object') {
    const o = v as Record<string, unknown>;
    return `{${Object.keys(o).sort().filter((k) => o[k] !== undefined)
      .map((k) => `${JSON.stringify(k)}:${canonical(o[k])}`).join(',')}}`;
  }
  return JSON.stringify(v);
}

export const sha256 = (s: string): string => createHash('sha256').update(s).digest('hex');

export function macOf(key: Buffer, row: Record<string, unknown>): string {
  const { mac: _mac, ...rest } = row;
  return createHmac('sha256', key).update(canonical(rest)).digest('hex');
}

export function sign<T extends object>(key: Buffer, row: T): T & { mac: string } {
  return { ...row, mac: macOf(key, row as Record<string, unknown>) };
}

export function verify(key: Buffer, row: Record<string, unknown>): boolean {
  if (typeof row.mac !== 'string' || !/^[0-9a-f]{64}$/.test(row.mac)) return false;
  return timingSafeEqual(Buffer.from(row.mac, 'hex'), Buffer.from(macOf(key, row), 'hex'));
}

export interface Chain<T> {
  rows: T[];
  verified: T[];
  bad: string[];
  badKeys: Set<string>;
  unparseable: boolean;
  head: string;
}

// From the first row that fails its signature or its prev link, every later
// row is unverified too: a broken chain is UNKNOWN from that row onward.
export function parseChain<T>(text: string, key: Buffer): Chain<T> {
  const out: Chain<T> = { rows: [], verified: [], bad: [], badKeys: new Set(), unparseable: false, head: GENESIS };
  let prev = GENESIS;
  let broken = false;
  const lines = text.split('\n').filter((l) => l.trim() !== '');
  lines.forEach((line, i) => {
    let row: Record<string, unknown>;
    try {
      row = JSON.parse(line) as Record<string, unknown>;
    } catch {
      out.unparseable = true;
      out.bad.push(`line ${i + 1}: unparseable`);
      broken = true;
      prev = sha256(line);
      return;
    }
    out.rows.push(row as T);
    const ok = !broken && row.prev === prev && verify(key, row);
    if (ok) {
      out.verified.push(row as T);
    } else {
      broken = true;
      out.bad.push(`line ${i + 1}${typeof row.id === 'string' ? ` (${row.id})` : ''}: ${row.prev === prev ? 'bad signature' : 'broken chain'}`);
      if (typeof row.key === 'string') out.badKeys.add(row.key);
    }
    prev = sha256(line);
  });
  out.head = lines.length ? sha256(lines[lines.length - 1]) : GENESIS;
  return out;
}

export function chainLine(prev: string, key: Buffer, fields: Record<string, unknown>): string {
  const { mac: _mac, ...rest } = fields;
  return JSON.stringify(sign(key, { ...rest, prev }));
}

export function readChain<T>(path: string, key: Buffer): Chain<T> {
  return parseChain<T>(existsSync(path) ? readFileSync(path, 'utf8') : '', key);
}

// The caller holds the file's lock (withLock). A chain that no longer verifies
// is never extended: the writer refuses rather than build on an unknown head.
export function appendChain<T>(path: string, key: Buffer, fields: object): T {
  const chain = readChain<T>(path, key);
  if (chain.bad.length) throw new Error(`release: ${path} does not verify (${chain.bad[0]}); refusing to append`);
  const line = chainLine(chain.head, key, fields as Record<string, unknown>);
  appendFileSync(path, `${line}\n`);
  return JSON.parse(line) as T;
}

export function writeSigned(path: string, key: Buffer, value: object): void {
  const tmp = `${path}.${process.pid}.tmp`;
  writeFileSync(tmp, `${JSON.stringify(sign(key, value), null, 2)}\n`);
  renameSync(tmp, path);
}

export function readSigned<T>(path: string, key: Buffer): { value: T | null; ok: boolean } {
  if (!existsSync(path)) return { value: null, ok: false };
  try {
    const value = JSON.parse(readFileSync(path, 'utf8')) as Record<string, unknown>;
    return { value: value as T, ok: verify(key, value) };
  } catch {
    return { value: null, ok: false };
  }
}

export const contentSha = (value: object): string => {
  const { mac: _mac, ...rest } = value as Record<string, unknown>;
  return sha256(canonical(rest));
};

export function mintKey(path: string): Buffer {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const key = randomBytes(32);
  writeFileSync(path, `${key.toString('hex')}\n`, { mode: 0o600, flag: 'wx' });
  return key;
}

export function loadKey(path: string): Buffer {
  if (!existsSync(path)) throw new Error(`release: no key at ${path} (the release is not declared on this machine)`);
  if (statSync(path).mode & 0o077) throw new Error(`release: ${path} must be mode 600`);
  const hex = readFileSync(path, 'utf8').trim();
  if (!/^[0-9a-f]{64}$/.test(hex)) throw new Error(`release: ${path} is not a 32-byte hex key`);
  return Buffer.from(hex, 'hex');
}

const sleep = (ms: number) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

// One O_EXCL lock file per release directory serializes every writer. A lock
// older than staleMs is a crashed writer's and is broken; a live async holder
// keeps its lock fresh, and a release unlinks only the lock it created.
interface LockHandle { lock: string; fd: number; ino: number }

function acquireLock(dir: string, waitMs: number, staleMs: number): LockHandle {
  const lock = `${dir}/.lock`;
  const deadline = Date.now() + waitMs;
  let fd: number | null = null;
  while (fd === null) {
    try {
      fd = openSync(lock, 'wx');
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code !== 'EEXIST') throw e;
      try {
        if (Date.now() - statSync(lock).mtimeMs > staleMs) unlinkSync(lock);
      } catch { /* raced with its owner's unlink */ }
      if (Date.now() > deadline) throw new Error(`release: ${lock} is held; retry`);
      sleep(50);
    }
  }
  return { lock, fd, ino: fstatSync(fd).ino };
}

function releaseLock(h: LockHandle): void {
  closeSync(h.fd);
  try {
    if (statSync(h.lock).ino === h.ino) unlinkSync(h.lock);
  } catch { /* already broken and gone */ }
}

export function withLock<T>(dir: string, fn: () => T, waitMs = 10_000, staleMs = 60_000): T {
  const h = acquireLock(dir, waitMs, staleMs);
  try {
    return fn();
  } finally {
    releaseLock(h);
  }
}

export async function withLockAsync<T>(dir: string, fn: () => Promise<T>, waitMs = 10_000, staleMs = 60_000): Promise<T> {
  const h = acquireLock(dir, waitMs, staleMs);
  const beat = setInterval(() => {
    const now = new Date();
    try {
      futimesSync(h.fd, now, now);
    } catch { /* the fd closes with the release */ }
  }, Math.max(10, Math.floor(staleMs / 3)));
  try {
    return await fn();
  } finally {
    clearInterval(beat);
    releaseLock(h);
  }
}
