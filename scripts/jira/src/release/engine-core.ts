import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { readCursor } from '../mirror-cursor.js';
import { releaseKeyPath, releaseRoot } from './paths.js';
import { appendChain, contentSha, loadKey, readChain, readSigned, withLock, type Chain } from './ledger.js';
import { FENCE_MARKERS, walk } from './fence-ancestry.js';
import { readAdmissions, type Admission } from '../commands/admissions-ledger.js';
import { reduce, type ReleaseState } from './reducer.js';
import type { SignerState } from './signer.js';
import type { Baseline, Declaration, EventRow, IssueSnap, Lease, Op, OperatorKind, OperatorRow, RequestRow, RulingRow } from './types.js';

export interface JiraPort {
  fixVersions(key: string): Promise<string[]>;
  newestFixVersionEntry(key: string): Promise<{ id: string; ts: string }>;
  setFixVersion(key: string, op: 'add' | 'remove', version: string, leave?: { by: string; op?: Op }): Promise<void>;
  findComment(key: string, marker: string): Promise<string | null>;
  addComment(key: string, markdown: string): Promise<string>;
  labels(key: string): Promise<string[]>;
  removeLabels(key: string, labels: string[]): Promise<void>;
  issue?(key: string): Promise<IssueSnap | null>;
}

export interface Ctx {
  release: string;
  dir: string;
  keyPath: string;
  env: Record<string, string | undefined>;
  now: () => Date;
  jira: JiraPort;
  mirrorRoot: string | null;
  deliveredPr?: (key: string) => number | undefined;
  /** The caller's stop: a child process the ctx's work runs ends with it. */
  signal?: AbortSignal;
  procRoot?: string;
  hostNsPath?: string;
}

const f = (ctx: Ctx, name: string) => join(ctx.dir, name);

const ts = (ctx: Ctx) => ctx.now().toISOString();

const seq = (prefix: string, ids: Iterable<string>) => {
  const re = new RegExp(`^${prefix}-(\\d+)$`);
  const n = Math.max(0, ...[...ids].map((id) => Number(re.exec(id)?.[1] ?? 0)));
  return `${prefix}-${String(n + 1).padStart(4, '0')}`;
};

const FENCE_HEAD = 'release operator: a chief act on an operator decision; refused';

const fenceWhere = (marker: string) => (marker === 'HIMMEL_BRIDGE_SESSION'
  ? `${FENCE_HEAD} inside a Telegram bridge session or a process it started (the bridge names the operator's update, the chief's tick records it)`
  : `${FENCE_HEAD} inside a chief-spawned worker`);

export function operatorFence(ctx: Ctx): void {
  const own = FENCE_MARKERS.find((m) => ctx.env[m] === '1');
  if (own) throw new Error(fenceWhere(own));
  const w = walk({ procRoot: ctx.procRoot, hostNsPath: ctx.hostNsPath });
  if (w.stop === 'allow') return;
  throw new Error(w.marker ? `${fenceWhere(w.marker)}: ${w.why}` : `${FENCE_HEAD}: ${w.why}`);
}

function key(ctx: Ctx): Buffer {
  return loadKey(ctx.keyPath);
}

interface Loaded {
  k: Buffer;
  decl: Declaration;
  baselines: Baseline[];
  base_history: Baseline[];
  rulings: Chain<RulingRow>;
  operator: Chain<OperatorRow>;
  events: Chain<EventRow>;
  requests: Chain<RequestRow>;
}

function load(ctx: Ctx): Loaded | { unknown: string } {
  let k: Buffer;
  try {
    k = key(ctx);
  } catch (e) {
    return { unknown: (e as Error).message };
  }
  const operator = readChain<OperatorRow>(f(ctx, 'operator.jsonl'), k);
  const decl = readSigned<Declaration>(f(ctx, 'release.json'), k);
  const declRow = operator.verified.find((o) => o.kind === 'declare');
  if (!decl.ok || !decl.value || !declRow || declRow.sha !== contentSha(decl.value) || decl.value.release !== ctx.release) {
    return { unknown: `release.json for ${ctx.release} is missing or does not verify` };
  }
  const baselines: Baseline[] = [];
  const base_history: Baseline[] = [];
  for (const o of operator.verified.filter((x) => x.kind === 'freeze')) {
    const b = readSigned<Baseline>(f(ctx, o.file ?? ''), k);
    if (!b.ok || !b.value || o.sha !== contentSha(b.value)) return { unknown: `${o.file} does not verify against ${o.id}` };
    base_history.push(b.value);
    const prior = baselines.findIndex((x) => x.version === b.value?.version);
    if (prior >= 0) baselines.splice(prior, 1);
    baselines.push(b.value);
  }
  return {
    k, decl: decl.value, baselines, base_history, operator,
    rulings: readChain<RulingRow>(f(ctx, 'rulings.jsonl'), k),
    events: readChain<EventRow>(f(ctx, 'events.jsonl'), k),
    requests: readChain<RequestRow>(f(ctx, 'requests.jsonl'), k),
  };
}

function loadOrThrow(ctx: Ctx): Loaded {
  const l = load(ctx);
  if ('unknown' in l) throw new Error(`release ${ctx.release} is UNKNOWN: ${l.unknown}`);
  return l;
}

function locked<T>(ctx: Ctx, fn: (l: Loaded) => T): T {
  loadOrThrow(ctx);
  return withLock(ctx.dir, () => fn(loadOrThrow(ctx)));
}

function lockedAcross<T>(ctx: Ctx, fn: (l: Loaded) => T): T {
  loadOrThrow(ctx);
  return withLock(releaseRoot(ctx.env), () => locked(ctx, fn));
}

function frontmatter(text: string): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  const lines = text.split('\n');
  if (lines[0] !== '---') return out;
  for (const line of lines.slice(1)) {
    if (line === '---') break;
    const m = /^(\w+): (.+)$/.exec(line);
    if (!m) continue;
    try {
      out[m[1]] = JSON.parse(m[2]);
    } catch { }
  }
  return out;
}

function blockedByOf(text: string): string[] {
  const head = text.split('\n---')[0];
  const m = /^[ \t]+blocked_by: (\[.*\])[ \t]*$/m.exec(head);
  try {
    const got: unknown = m ? JSON.parse(m[1]) : [];
    return Array.isArray(got) ? got.filter((k): k is string => typeof k === 'string') : [];
  } catch {
    return [];
  }
}

export function readMirrorFilesUnverified(root: string | null): { issues: Map<string, IssueSnap> | null; sync: string | null; complete: boolean } {
  if (!root || !existsSync(root)) return { issues: null, sync: null, complete: false };
  const cur = readCursor(root);
  const sync = cur ? cur.lastSync : null;
  const complete = cur ? cur.complete === undefined : false;
  const issues = new Map<string, IssueSnap>();
  for (const name of readdirSync(root)) {
    if (!name.endsWith('.md')) continue;
    const text = readFileSync(join(root, name), 'utf8');
    const fm = frontmatter(text);
    if (typeof fm.key !== 'string') continue;
    issues.set(fm.key, {
      blockedBy: blockedByOf(text),
      key: fm.key, status: String(fm.status ?? ''), statusCategory: typeof fm.statusCategory === 'string' ? fm.statusCategory : null,
      type: String(fm.type ?? ''), priority: String(fm.priority ?? ''),
      fixVersions: Array.isArray(fm.fixVersions) ? fm.fixVersions.map(String) : [],
      resolution: typeof fm.resolution === 'string' ? fm.resolution : null,
      sector: typeof fm.sector === 'string' && fm.sector ? fm.sector : null,
      ...(typeof fm.parent === 'string' && fm.parent ? { parent: fm.parent } : {}),
      ...(Array.isArray(fm.labels) && fm.labels.length ? { labels: fm.labels.map(String) } : {}),
      resolved: typeof fm.resolved === 'string' ? fm.resolved : null,
    });
  }
  if (issues.size === 0 && sync === null) return { issues: null, sync: null, complete: false };
  return { issues, sync, complete };
}

export function readMirror(root: string | null): { issues: Map<string, IssueSnap> | null; sync: string | null } {
  const m = readMirrorFilesUnverified(root);
  return m.complete ? { issues: m.issues, sync: m.sync } : { issues: null, sync: null };
}

function appendOperator<R extends OperatorRow = OperatorRow>(ctx: Ctx, k: Buffer, row: Omit<R, 'id' | 'ts'> & { id?: string }): R {
  const chain = readChain<OperatorRow>(f(ctx, 'operator.jsonl'), k);
  const id = row.id ?? seq(`O-${ctx.release}`, chain.rows.map((o) => o.id));
  return appendChain<R>(f(ctx, 'operator.jsonl'), k, { ...row, id, ts: ts(ctx) });
}

export type ReleaseRecord = OperatorRow & { release: string };

export function readOperatorRecords(kind: OperatorKind | OperatorKind[], env: Record<string, string | undefined> = process.env): ReleaseRecord[] {
  const kinds = new Set<OperatorKind>(Array.isArray(kind) ? kind : [kind]);
  const root = releaseRoot(env);
  if (!existsSync(root)) return [];
  const out: ReleaseRecord[] = [];
  for (const release of readdirSync(root).sort()) {
    if (!existsSync(join(root, release, 'release.json'))) continue;
    let k: Buffer;
    try {
      k = loadKey(releaseKeyPath(release, env));
    } catch {
      continue;
    }
    const chain = readChain<OperatorRow>(join(root, release, 'operator.jsonl'), k);
    out.push(...chain.verified.filter((o) => kinds.has(o.kind)).map((o) => ({ ...o, release })));
  }
  return out;
}

export function readSignerState(env: Record<string, string | undefined>, mirrorRoot: string | null): SignerState {
  const root = releaseRoot(env);
  const rows: Array<{ r: OperatorRow; release: string; i: number }> = [];
  let unreadable: string | null = null;
  for (const release of existsSync(root) ? readdirSync(root).sort() : []) {
    if (!existsSync(join(root, release, 'release.json'))) continue;
    let k: Buffer;
    try {
      k = loadKey(releaseKeyPath(release, env));
    } catch (e) {
      unreadable ??= `release ${release}: its key does not load (${(e as Error).message})`;
      continue;
    }
    const chain = readChain<OperatorRow>(join(root, release, 'operator.jsonl'), k);
    if (chain.bad.length) unreadable ??= `release ${release}: operator.jsonl does not verify (${chain.bad[0]})`;
    chain.verified.forEach((r, i) => { if (r.kind === 'spec-signer') rows.push({ r, release, i }); });
  }
  rows.sort((a, b) => a.r.ts.localeCompare(b.r.ts) || a.release.localeCompare(b.release) || a.i - b.i);
  const records = rows.map(({ r }) => r);
  const issues = records.some((r) => r.keys?.length) ? readMirrorFilesUnverified(mirrorRoot).issues : null;
  return { records, unreadable, issues };
}

export { f, ts, seq, key, load, loadOrThrow, locked, lockedAcross, appendOperator, type Loaded };

export function reduceLoaded(l: Loaded, mirror: ReturnType<typeof readMirror>): ReleaseState {
  return reduce({
    decl: l.decl, baselines: l.baselines, base_history: l.base_history, rulings: l.rulings, operator: l.operator, events: l.events,
    issues: mirror.issues, mirrorSync: mirror.sync, admissions: admissionsOrNull(),
  });
}

export function admissionsOrNull(): Admission[] | null {
  try {
    return readAdmissions();
  } catch {
    return null;
  }
}

export function readLease(ctx: Ctx, k: Buffer): Lease {
  const p = f(ctx, 'lease.json');
  if (!existsSync(p)) {
    return { release: ctx.release, epoch: 0, owner_session: null, owner_doc: null, acquired: null, released: true, prev_epoch: null };
  }
  const l = readSigned<Lease>(p, k);
  if (!l.ok || !l.value) throw new Error(`release ${ctx.release} is UNKNOWN: lease.json does not verify`);
  return l.value;
}

export function latestRequests(requests: Chain<RequestRow>): Map<string, RequestRow> {
  if (requests.bad.length) throw new Error(`release: requests.jsonl does not verify (${requests.bad[0]})`);
  const m = new Map<string, RequestRow>();
  for (const r of requests.verified) m.set(r.req, r);
  return m;
}

export const vName = (v: string | null) => v ?? 'backlog';
