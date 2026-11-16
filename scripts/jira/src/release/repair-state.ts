import { createHash } from 'node:crypto';
import { existsSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { operatorFence, state, type Ctx } from './engine.js';

// The version repair's one current-state record: release/<R>/repair-state.json, written only by this CLI (repair --apply
// at each transition, repair-state on a read that finds a crashed run or no record). The tick reads it and writes nothing.
// repair-status, repair-reviewed, repair-held.json, repair-launch and repair-signature stay as copies the repair still
// writes for this release; the record is the current state, not a history and not another release authority.

export type RepairStateName = 'off' | 'idle' | 'running' | 'held' | 'lost';

export interface RepairState {
  release: string;
  state: RepairStateName;
  /** Why it is off (unreviewed, mirror-unknown, bad-input, error) or lost; null otherwise. */
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
  /** Consecutive launches that ended without an end record. */
  lost_count: number;
  /** The exact command that clears off:unreviewed; null otherwise. */
  operator_command: string | null;
  /** 0 ok, 3 stopped, 2 error; null before any run ended. */
  last_exit: number | null;
  ts: string;
}

const STATES: RepairStateName[] = ['off', 'idle', 'running', 'held', 'lost'];
export const stateFile = (ctx: Ctx): string => join(ctx.dir, 'repair-state.json');

export function writeAtomic(path: string, text: string): void {
  const tmp = `${path}.tmp-${process.pid}`;
  writeFileSync(tmp, text);
  renameSync(tmp, path);
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
    return r as unknown as RepairState;
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

/** The record as it is before any run wrote one: built from the files the repair already keeps. */
function fromFiles(ctx: Ctx): RepairState {
  const held = readHeld(ctx);
  const status = firstLine(join(ctx.dir, 'repair-status'));
  const reviewed = firstLine(join(ctx.dir, 'repair-reviewed'));
  const sig = firstLine(join(ctx.dir, 'repair-signature')) ?? '';
  const stamp = /^(\d+) (\d+)$/.exec(firstLine(join(ctx.dir, 'repair-launch')) ?? '');
  const why = status === null ? null : (status.replace(/[^a-z-]/g, '') || 'error');
  const name: RepairStateName = why !== null || !reviewed ? 'off' : held.held_keys.length > 0 ? 'held' : 'idle';
  return {
    release: ctx.release, state: name, reason: why ?? (reviewed ? null : 'unreviewed'), reviewed_at: reviewed || null,
    signature: /^[0-9a-f]{64}$/.test(sig) ? sig : '', ...held, launched: stamp ? Number(stamp[1]) : null, pid: null, lost_count: stamp ? Number(stamp[2]) : 0,
    operator_command: null, last_exit: null, ts: ctx.now().toISOString(),
  };
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

function alive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return (e as NodeJS.ErrnoException).code === 'EPERM';
  }
}

// A launch older than the boot has no owner, whatever a recycled pid says.
function bootTime(): number | null {
  try {
    const m = /^btime (\d+)$/m.exec(readFileSync('/proc/stat', 'utf8'));
    return m ? Number(m[1]) : null;
  } catch {
    return null;
  }
}

const operatorCommand = (release: string, repo: string | null): string => `jira release repair ${release} --apply --repo ${repo ?? '<owner/name>'}`;

function derive(rec: RepairState, repo: string | null): RepairState {
  let out = rec;
  if (out.state === 'running') {
    const boot = bootTime();
    const owned = out.pid !== null && alive(out.pid) && !(boot !== null && out.launched !== null && out.launched < boot);
    if (!owned) out = { ...out, state: 'lost', reason: 'lost', pid: null };
  }
  const unreviewed = out.state === 'off' && out.reason === 'unreviewed';
  return { ...out, operator_command: unreviewed ? operatorCommand(out.release, repo) : null };
}

const same = (a: RepairState, b: RepairState): boolean => JSON.stringify({ ...a, ts: '' }) === JSON.stringify({ ...b, ts: '' });

/**
 * The current repair state. A missing record is built from the files the repair already keeps; a `running` record whose owner is
 * gone reads `lost`. A change is published atomically unless this process sits under a worker fence, which writes nothing.
 */
export function repairStateOf(ctx: Ctx, o: { repo: string | null }): RepairState {
  const stored = readRecord(ctx);
  const got = derive(stored ?? fromFiles(ctx), o.repo);
  if (stored === null || !same(stored, { ...got, operator_command: stored.operator_command })) {
    try {
      operatorFence(ctx);
      writeAtomic(stateFile(ctx), `${JSON.stringify({ ...got, operator_command: null, ts: ctx.now().toISOString() }, null, 2)}\n`);
    } catch {
      // fenced or unwritable: the read still answers, the record waits for the CLI that may write it
    }
  }
  return got;
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

/** The first transition of an --apply run, after it holds the lock: running, with this launch's signature and owner. Copies follow. */
export function beginRun(ctx: Ctx, o: { repo: string | null; signature: string }): void {
  const prior = repairStateOf(ctx, { repo: o.repo });
  const lost = prior.state === 'lost' ? prior.lost_count + 1 : 0;
  const rec: RepairState = { ...prior, state: 'running', reason: null, signature: o.signature, launched: epoch(ctx), pid: process.pid, lost_count: lost, operator_command: null, ts: ctx.now().toISOString() };
  writeAtomic(stateFile(ctx), `${JSON.stringify(rec, null, 2)}\n`);
  writeAtomic(join(ctx.dir, 'repair-launch'), `${rec.launched} ${lost}\n`);
  if (o.signature) writeAtomic(join(ctx.dir, 'repair-signature'), `${o.signature}\n`);
}

/** The last transition: off with its reason, or idle/held; the held fields are those the run just wrote, or the previous ones when it wrote none. */
export function endRun(ctx: Ctx, o: { repo: string | null; exit: 0 | 2 | 3; reason: string | null; clearSignature: boolean; reviewed: boolean }): void {
  const cur = readRecord(ctx) ?? derive(fromFiles(ctx), o.repo);
  const held = o.exit === 0 ? readHeld(ctx) : { held_keys: cur.held_keys, held_signature: cur.held_signature, unfiled: cur.unfiled };
  const reviewed = o.reviewed ? ctx.now().toISOString() : cur.reviewed_at;
  const name: RepairStateName = o.exit !== 0 ? 'off' : held.held_keys.length > 0 ? 'held' : 'idle';
  writeAtomic(stateFile(ctx), `${JSON.stringify({
    ...cur, ...held, state: name, reason: o.exit === 0 ? null : o.reason, reviewed_at: reviewed, signature: o.clearSignature ? '' : cur.signature,
    pid: null, lost_count: 0, operator_command: null, last_exit: o.exit, ts: ctx.now().toISOString(),
  } satisfies RepairState, null, 2)}\n`);
}

export const repairStateExists = (ctx: Ctx): boolean => existsSync(stateFile(ctx));
