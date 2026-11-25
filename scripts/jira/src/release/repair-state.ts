import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, renameSync, statSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { operatorFence, state, type Ctx } from './engine.js';
import { withLock } from './ledger.js';

// The version repair's one current-state record: release/<R>/repair-state.json, written only by this CLI (repair --apply at
// each transition, repair-state on a read that finds a crashed run or no record, repair-state --attempt before a detached start).
// The tick reads it and writes nothing. repair-status, repair-reviewed, repair-held.json, repair-launch and repair-signature stay as
// copies the repair still writes for this release; the record is the current state, not a history and not another release authority.
//
// LOCK ORDER. Two locks, always in this order and never the other way:
//   1. release/<R>/repair.lock      the run's worker-lifetime exclusion (repair-run.ts takeLock); held for the whole --apply.
//   2. release/<R>/repair-state.lock.d/.lock   a short leaf lock around ONE read -> derive -> publish of repair-state.json.
// The state lock is taken by every writer (repairStateOf, attemptLaunch, beginRun, endRun) and held only for file reads and the
// atomic publish: nothing under it calls the engine, a child process other than `ps`, or takes repair.lock or the ledger lock, so no
// outer lock is ever held while a child re-acquires it. Each writer re-reads the record under the lock; a stale read never publishes.

export type RepairStateName = 'off' | 'idle' | 'running' | 'held' | 'lost';

export interface RepairState {
  release: string;
  state: RepairStateName;
  /** Why it is off (unreviewed, mirror-unknown, bad-input, error) or lost (lost: the owner is gone; unknown-owner: it cannot be bound); null otherwise. */
  reason: string | null;
  /** When the first clean --apply ended (the review marker); null before that. */
  reviewed_at: string | null;
  /** The run signature of the last launch; '' when the next tick must launch regardless. */
  signature: string;
  held_signature: string;
  held_keys: string[];
  unfiled: number;
  /** Epoch seconds of the last launch, and its owner while it runs. */
  launched: number | null;
  pid: number | null;
  /** The owner's process identity (`posix:<lstart> <command>`, as proc_tree_process_identity prints it); a pid without one is never read as live. */
  pid_identity: string | null;
  /** Epoch seconds of the newest launch attempt the CLI recorded before a detached start, and how many attempts since a run began. */
  attempted: number | null;
  attempts: number;
  /** Consecutive launches that ended without an end record. */
  lost_count: number;
  /** The permitted act that makes progress while the review is absent (the first apply, run by the operator after a dry run); null otherwise. */
  operator_command: string | null;
  /** 0 ok, 3 stopped, 2 error; null before any run ended. */
  last_exit: number | null;
  ts: string;
}

const STATES: RepairStateName[] = ['off', 'idle', 'running', 'held', 'lost'];
export const MAX_ATTEMPTS = 64;
export const stateFile = (ctx: Ctx): string => join(ctx.dir, 'repair-state.json');
const lockDir = (ctx: Ctx): string => join(ctx.dir, 'repair-state.lock.d');

export function writeAtomic(path: string, text: string): void {
  const tmp = `${path}.tmp-${process.pid}`;
  writeFileSync(tmp, text);
  renameSync(tmp, path);
}

function withStateLock<T>(ctx: Ctx, fn: () => T): T {
  mkdirSync(lockDir(ctx), { recursive: true });
  return withLock(lockDir(ctx), fn, 10_000, 60_000);
}

const isStr = (v: unknown): v is string => typeof v === 'string';
const isNum = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v);

function readRecord(ctx: Ctx): RepairState | null {
  try {
    const r = JSON.parse(readFileSync(stateFile(ctx), 'utf8')) as Record<string, unknown>;
    if (r === null || typeof r !== 'object' || r.release !== ctx.release || !STATES.includes(r.state as RepairStateName)) return null;
    if (!(r.reason === null || isStr(r.reason)) || !(r.reviewed_at === null || isStr(r.reviewed_at)) || !isStr(r.signature) || !isStr(r.held_signature)) return null;
    if (!Array.isArray(r.held_keys) || !r.held_keys.every(isStr) || !isNum(r.unfiled) || !isNum(r.lost_count)) return null;
    if (!(r.launched === null || isNum(r.launched)) || !(r.pid === null || isNum(r.pid)) || !(r.last_exit === null || isNum(r.last_exit)) || !isStr(r.ts)) return null;
    // A record written before the attempt clock and the identity binding has neither.
    const pidIdentity = r.pid_identity === undefined ? null : r.pid_identity;
    const attempted = r.attempted === undefined ? null : r.attempted;
    const attempts = r.attempts === undefined ? 0 : r.attempts;
    if (!(pidIdentity === null || isStr(pidIdentity)) || !(attempted === null || isNum(attempted)) || !isNum(attempts)) return null;
    return { ...(r as unknown as RepairState), pid_identity: pidIdentity, attempted, attempts, operator_command: isStr(r.operator_command) ? r.operator_command : null };
  } catch {
    return null;
  }
}

const firstLine = (path: string): string | null => {
  try {
    return readFileSync(path, 'utf8').split('\n')[0]!.trim();
  } catch {
    return null;
  }
};

const mtimeSecs = (path: string): number | null => {
  try {
    return Math.floor(statSync(path).mtimeMs / 1000);
  } catch {
    return null;
  }
};

// A launch older than the boot has no owner, whatever a recycled pid says.
function bootTime(): number | null {
  try {
    const m = /^btime (\d+)$/m.exec(readFileSync('/proc/stat', 'utf8'));
    return m ? Number(m[1]) : null;
  } catch {
    return null;
  }
}

/** The identity the tick's proc_tree_process_identity reads: `posix:` and ps's lstart and command, in UTC and the C locale. Null when ps cannot say. */
export function processIdentity(pid: number): string | null {
  const r = spawnSync('ps', ['-ww', '-p', String(pid), '-o', 'lstart=', '-o', 'command='], { encoding: 'utf8', env: { ...process.env, TZ: 'UTC', LC_ALL: 'C' }, timeout: 5_000 });
  const text = r.status === 0 ? r.stdout.replace(/\n+$/, '') : '';
  return text ? `posix:${text}` : null;
}

/** 0: the pid is not signalable (ESRCH) or no longer the process that was recorded. */
function pidExists(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return (e as NodeJS.ErrnoException).code === 'EPERM';
  }
}

type Owner = 'live' | 'dead' | 'unknown';

// Affirmative only when the recorded pid is still the recorded process; a pid with no recorded identity, or an identity ps cannot read, is unknown.
function ownerOf(rec: RepairState): Owner {
  if (rec.pid === null) return 'dead';
  const boot = bootTime();
  if (boot !== null && rec.launched !== null && rec.launched < boot) return 'dead';
  if (!pidExists(rec.pid)) return 'dead';
  if (!rec.pid_identity) return 'unknown';
  const now = processIdentity(rec.pid);
  if (now === null) return 'unknown';
  return now === rec.pid_identity ? 'live' : 'dead';
}

/** The held fields of the last run's repair-held.json copy; empty when it is missing or unreadable. */
export function readHeld(ctx: Ctx): Pick<RepairState, 'held_keys' | 'held_signature' | 'unfiled'> {
  try {
    const h = JSON.parse(readFileSync(join(ctx.dir, 'repair-held.json'), 'utf8')) as { unfiled?: unknown; held_signature?: unknown; classes?: Array<{ keys?: unknown }> };
    const keys = (h.classes ?? []).flatMap((c) => (Array.isArray(c.keys) ? c.keys.filter(isStr) : []));
    return { held_keys: [...new Set(keys)].sort(), held_signature: isStr(h.held_signature) ? h.held_signature : '', unfiled: isNum(h.unfiled) ? h.unfiled : 0 };
  } catch {
    return { held_keys: [], held_signature: '', unfiled: 0 };
  }
}

// The old tick read the lock's first line as the owner pid, live when that pid answers and the lock was written since the boot.
function oldLockOwnerAnswers(ctx: Ctx): boolean {
  const lock = join(ctx.dir, 'repair.lock');
  const pid = Number(firstLine(lock));
  if (!Number.isInteger(pid) || pid <= 0 || !pidExists(pid)) return false;
  const boot = bootTime();
  const m = mtimeSecs(lock);
  return !(boot !== null && m !== null && m < boot);
}

/**
 * The record as it is before any run wrote one: built from the files the repair and the old tick already keep, with their meaning.
 * A launch stamp `<epoch> <lost_count>` is ended by a repair-status or repair-reviewed file written at or after it; a stamp with no such
 * end is an unfinished launch whatever an older review marker and a matching signature say, and a lock owner that still answers cannot
 * be bound to the launch, so that reads unknown-owner rather than running.
 */
function fromFiles(ctx: Ctx): RepairState {
  const held = readHeld(ctx);
  const status = firstLine(join(ctx.dir, 'repair-status'));
  const reviewed = firstLine(join(ctx.dir, 'repair-reviewed'));
  const sig = firstLine(join(ctx.dir, 'repair-signature')) ?? '';
  const launchText = firstLine(join(ctx.dir, 'repair-launch'));
  const stamp = /^(\d+) (\d+)$/.exec(launchText ?? '');
  const launched = stamp ? Number(stamp[1]) : null;
  const k = stamp ? Number(stamp[2]) : 0;
  const ended = launched !== null && ['repair-status', 'repair-reviewed'].some((n) => {
    const m = mtimeSecs(join(ctx.dir, n));
    return m !== null && m >= launched;
  });
  const base = {
    release: ctx.release, reviewed_at: reviewed || null, signature: /^[0-9a-f]{64}$/.test(sig) ? sig : '', ...held, launched, pid: null, pid_identity: null,
    attempted: null, attempts: 0, lost_count: k, operator_command: null, last_exit: null, ts: ctx.now().toISOString(),
  };
  if (launchText !== null && (stamp === null || !ended)) {
    return { ...base, state: 'lost', reason: stamp !== null && oldLockOwnerAnswers(ctx) ? 'unknown-owner' : 'lost' };
  }
  const why = status === null ? null : (status.replace(/[^a-z-]/g, '') || 'error');
  const name: RepairStateName = why !== null || !reviewed ? 'off' : held.held_keys.length > 0 ? 'held' : 'idle';
  return { ...base, state: name, reason: why ?? (reviewed ? null : 'unreviewed') };
}

const operatorCommand = (release: string, repo: string | null): string => `jira release repair ${release} --apply --repo ${repo ?? '<owner/name>'}`;

// The review-needed act: while no review marker exists, a record that is not progressing names the first apply.
const needsReview = (rec: RepairState): boolean =>
  rec.reviewed_at === null && (rec.state === 'lost' || (rec.state === 'off' && (rec.reason === 'unreviewed' || rec.reason === 'error')));

function derive(rec: RepairState, repo: string | null): RepairState {
  let out = rec;
  if (out.state === 'running') {
    const owner = ownerOf(out);
    if (owner !== 'live') out = { ...out, state: 'lost', reason: owner === 'unknown' ? 'unknown-owner' : 'lost', pid: null, pid_identity: null };
  }
  // The command is part of the record: kept while it stays right, never rewritten by a later read that names another repo.
  const kept = out.operator_command !== null && !(repo !== null && out.operator_command.includes('<owner/name>')) ? out.operator_command : null;
  return { ...out, operator_command: needsReview(out) ? (kept ?? operatorCommand(out.release, repo)) : null };
}

const same = (a: RepairState, b: RepairState): boolean => JSON.stringify({ ...a, ts: '' }) === JSON.stringify({ ...b, ts: '' });

function publish(ctx: Ctx, rec: RepairState): void {
  writeAtomic(stateFile(ctx), `${JSON.stringify({ ...rec, ts: ctx.now().toISOString() }, null, 2)}\n`);
}

type Write = { ok: true } | { ok: false; why: string };

function canWrite(ctx: Ctx): Write {
  try {
    operatorFence(ctx);
    return { ok: true };
  } catch (e) {
    return { ok: false, why: (e as Error).message };
  }
}

const current = (ctx: Ctx, repo: string | null): { stored: RepairState | null; got: RepairState } => {
  const stored = readRecord(ctx);
  return { stored, got: derive(stored ?? fromFiles(ctx), repo) };
};

/**
 * The current repair state. A missing record is built from the files the repair already keeps; a `running` record whose owner is
 * gone, or cannot be bound to its process, reads `lost`. The read, the derivation and the publish are one step under the state lock,
 * re-reading the record under it; a process under a worker fence takes no lock and writes nothing.
 */
export function repairStateOf(ctx: Ctx, o: { repo: string | null }): RepairState {
  if (!canWrite(ctx).ok) return current(ctx, o.repo).got;
  return withStateLock(ctx, () => {
    const { stored, got } = current(ctx, o.repo);
    if (stored === null || !same(stored, got)) publish(ctx, got);
    return got;
  });
}

/** The sha256 the tick computes for a launch: the sorted leak set, the operator, requests and mirror heads, and the journal's bytes. */
export function runSignature(ctx: Ctx, journalFile: string | null): string {
  try {
    const s = state(ctx);
    const leaks = [...new Set([...s.leaks.unauthorized, ...s.leaks.ruled_in_non_member])].sort();
    let journal = '';
    try {
      journal = journalFile ? createHash('sha256').update(readFileSync(journalFile)).digest('hex') : '';
    } catch { /* no journal reads as empty, as the tick reads it */ }
    const rows = [...leaks.map((k) => `leak=${k}`), `operator=${s.heads.operator}`, `requests=${s.heads.requests}`, `journal=${journal}`, `mirror=${s.heads.mirror ?? 'None'}`];
    return createHash('sha256').update(rows.join('\n')).digest('hex');
  } catch {
    return '';
  }
}

const epoch = (ctx: Ctx): number => Math.floor(ctx.now().getTime() / 1000);

export type AttemptOut = { ok: true; record: RepairState } | { ok: false; why: 'busy'; record: RepairState } | { ok: false; why: 'fenced'; detail: string; record: RepairState };

/**
 * Records a launch attempt BEFORE the detached start: the time and a bounded count, so a start that never reaches the CLI (no node, a dead
 * launcher) still leaves a retry clock the tick reads; beginRun clears the count. A run whose owner is affirmatively alive refuses it.
 */
export function attemptLaunch(ctx: Ctx, o: { repo: string | null }): AttemptOut {
  const fence = canWrite(ctx);
  if (!fence.ok) return { ok: false, why: 'fenced', detail: fence.why, record: current(ctx, o.repo).got };
  return withStateLock(ctx, () => {
    const { got } = current(ctx, o.repo);
    if (got.state === 'running') return { ok: false, why: 'busy', record: got } as const;
    const rec = { ...got, attempted: epoch(ctx), attempts: Math.min(MAX_ATTEMPTS, got.attempts + 1) };
    publish(ctx, rec);
    return { ok: true, record: rec } as const;
  });
}

/** The first transition of an --apply run, after it holds repair.lock: running, with this launch's signature and its owner's identity. Copies follow. */
export function beginRun(ctx: Ctx, o: { repo: string | null; signature: string }): void {
  withStateLock(ctx, () => {
    const { got: prior } = current(ctx, o.repo);
    const lost = prior.state === 'lost' ? prior.lost_count + 1 : 0;
    const rec: RepairState = {
      ...prior, state: 'running', reason: null, signature: o.signature, launched: epoch(ctx), pid: process.pid, pid_identity: processIdentity(process.pid),
      attempts: 0, lost_count: lost, operator_command: null,
    };
    publish(ctx, rec);
    writeAtomic(join(ctx.dir, 'repair-launch'), `${rec.launched} ${lost}\n`);
    if (o.signature) writeAtomic(join(ctx.dir, 'repair-signature'), `${o.signature}\n`);
  });
}

/** The last transition: off with its reason, or idle/held; the held fields are those the run just wrote, or the previous ones when it wrote none. */
export function endRun(ctx: Ctx, o: { repo: string | null; exit: 0 | 2 | 3; reason: string | null; clearSignature: boolean; reviewed: boolean }): void {
  withStateLock(ctx, () => {
    const { got: cur } = current(ctx, o.repo);
    const held = o.exit === 0 ? readHeld(ctx) : { held_keys: cur.held_keys, held_signature: cur.held_signature, unfiled: cur.unfiled };
    const reviewed = o.reviewed ? ctx.now().toISOString() : cur.reviewed_at;
    const name: RepairStateName = o.exit !== 0 ? 'off' : held.held_keys.length > 0 ? 'held' : 'idle';
    publish(ctx, derive({
      ...cur, ...held, state: name, reason: o.exit === 0 ? null : o.reason, reviewed_at: reviewed, signature: o.clearSignature ? '' : cur.signature,
      pid: null, pid_identity: null, lost_count: 0, operator_command: null, last_exit: o.exit,
    }, o.repo));
  });
}

export const repairStateExists = (ctx: Ctx): boolean => existsSync(stateFile(ctx));
