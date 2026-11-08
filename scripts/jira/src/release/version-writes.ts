import { appendFileSync, existsSync, mkdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { underTmp } from '../commands/admissions-ledger.js';
import { releaseRoot } from './paths.js';
import { isTestProject } from '../live-test-guard.js';

// The journal of machine Fix Version writes. The client hook records a row only
// for a write whose own PUT produced the exact newer changelog entry; anything else stays
// unbound, which is the safe direction. This file does not import history.ts (it imports
// client.ts); the client hands in a getter and the changelog is read here.

export interface VersionWriteRow { ts: string; key: string; from: string[]; to: string[]; mechanism: string; entry: string }

export interface WriterRow { site: string; mechanism: string; machine: boolean }

// Every file that writes a Fix Version, with the name each write carries. The classifier reads `machine`;
// a mechanism not on this list, or a write that names nothing, is `hand`. The enumerating test
// (version-writes.test.ts, I17) fails on a writing file missing here.
// ponytail: file grain, so a new write inside create.ts or edit.ts passes the test and reads as hand, the
// safe direction; upgrade path: make writer a required argument of setFixVersion and requestAt's write path.
const CREATE = 'scripts/jira/src/commands/create.ts';
export const WRITER_TABLE: readonly WriterRow[] = [
  { site: CREATE, mechanism: 'create-residual', machine: true },
  { site: CREATE, mechanism: 'create-followup', machine: true },
  { site: CREATE, mechanism: 'create-bug-default', machine: true },
  { site: CREATE, mechanism: 'create-blocker-inherit', machine: true },
  { site: CREATE, mechanism: 'create-stepdown', machine: true },
  { site: CREATE, mechanism: 'displace-residual', machine: true },
  { site: 'scripts/jira/src/commands/transition.ts', mechanism: 'transition-stamp', machine: true },
  { site: 'scripts/handover/merge-on-green.sh', mechanism: 'merge-stamp', machine: true },
  { site: 'scripts/cr/class-recurrence.sh', mechanism: 'class-recurrence', machine: true },
  { site: 'scripts/jira/sync-versions.mjs', mechanism: 'sync-versions', machine: true },
  // Its ruling already agrees, so an RM write is never a repair input.
  { site: 'scripts/jira/src/commands/release.ts', mechanism: 'rm-apply', machine: false },
  { site: CREATE, mechanism: 'hand', machine: false },
  { site: 'scripts/jira/src/commands/edit.ts', mechanism: 'hand', machine: false },
  { site: 'scripts/jira/src/commands/versions.ts', mechanism: 'hand', machine: false },
  { site: 'scripts/jira/src/commands/version-freeze.ts', mechanism: 'hand', machine: false },
  { site: 'scripts/handover/chief-kit/versionless-done.sh', mechanism: 'hand', machine: false },
];

// A GET against /rest/api/3, handed in by the client (with its own deadline).
export type Getter = <T>(path: string) => Promise<T>;

export interface WriteRequest {
  apiBase: string;
  method: string;
  path: string;
  body: unknown;
  writer?: string;
  get: Getter;
}

export interface PreRead {
  journal: string;
  mechanism: string;
  key: string | null;
  set: string[];
  // The newest Fix Version entry id before the write; null when the key has none (or is being created).
  entry: bigint | null;
}

interface ChangelogItem { field: string; fromString?: string | null; toString?: string | null }
interface ChangelogEntry { id: string | number; created?: string; items: ChangelogItem[] }
interface ChangelogPage { maxResults?: number; total?: number; values: ChangelogEntry[] }
interface FixEntry { id: bigint; ts: string; items: ChangelogItem[] }

const PAGE = 100;
const FIX_VERSION = 'Fix Version';
const ISSUE_PATH = /^\/issue(?:\/([A-Z][A-Z0-9]*-\d+))?$/;

const idOf = (raw: string | number): bigint | null => {
  try {
    return BigInt(String(raw));
  } catch {
    return null;
  }
};

const sorted = (names: Iterable<string>): string[] => [...new Set(names)].sort();

/** The hook's scope: POST or PUT on /rest/api/3 /issue or /issue/<key> whose body sets Fix Versions. Null otherwise. */
export function versionWriteScope(apiBase: string, method: string, path: string, body: unknown): { key: string | null } | null {
  if (apiBase !== '/rest/api/3' || (method !== 'POST' && method !== 'PUT')) return null;
  const m = ISSUE_PATH.exec(path.split('?')[0]);
  if (!m || (method === 'POST') !== (m[1] === undefined)) return null;
  const b = body as { fields?: { fixVersions?: unknown }; update?: { fixVersions?: unknown } } | null | undefined;
  if (b?.fields?.fixVersions === undefined && b?.update?.fixVersions === undefined) return null;
  // I13: the configured test project is not work, so its Fix Version writes enter no journal.
  const project = m[1] !== undefined ? m[1].slice(0, m[1].lastIndexOf('-')) : (body as { fields?: { project?: { key?: string } } }).fields?.project?.key;
  if (project !== undefined && isTestProject(project)) return null;
  return { key: m[1] ?? null };
}

/** The journal file, or null when the hook is off: under NODE_ENV=test only an explicit temp path turns it on. */
export function journalPath(env: Record<string, string | undefined> = process.env): string | null {
  const explicit = env.HIMMEL_VERSION_WRITES;
  if (env.NODE_ENV === 'test') return explicit && underTmp(explicit) ? explicit : null;
  return explicit || join(releaseRoot(env), 'version-writes.jsonl');
}

/** An explicit machine writer wins over the variable; a hand path reads the variable; unset is hand. */
export function mechanismOf(writer: string | undefined, env: Record<string, string | undefined> = process.env): string {
  if (writer && writer !== 'hand') return writer;
  return env.HIMMEL_VERSION_WRITER?.trim() || 'hand';
}

/** The Fix Version entries of a key, newest first. With `after`, only entries newer than it; without, the first page back that holds one. */
async function fixVersionEntries(get: Getter, key: string, after: bigint | null | undefined): Promise<FixEntry[]> {
  const first = await get<ChangelogPage>(`/issue/${key}/changelog?startAt=0&maxResults=${PAGE}`);
  const size = first.maxResults || PAGE;
  const total = first.total ?? first.values.length;
  let start = Math.max(0, Math.floor((total - 1) / size) * size);
  let page = start === 0 ? first : await get<ChangelogPage>(`/issue/${key}/changelog?startAt=${start}&maxResults=${PAGE}`);
  const out: FixEntry[] = [];
  for (;;) {
    const here: FixEntry[] = [];
    for (const e of page.values) {
      const id = idOf(e.id);
      if (id !== null && e.items.some((i) => i.field === FIX_VERSION)) here.push({ id, ts: e.created ?? '', items: e.items.filter((i) => i.field === FIX_VERSION) });
    }
    out.push(...here);
    const reachedOld = after === undefined ? here.length > 0 : after !== null && here.some((e) => e.id <= after);
    if (reachedOld || start === 0) break;
    start = Math.max(0, start - size);
    page = await get<ChangelogPage>(`/issue/${key}/changelog?startAt=${start}&maxResults=${PAGE}`);
  }
  return out.sort((a, b) => (a.id < b.id ? 1 : a.id > b.id ? -1 : 0));
}

/** The one parser of a key's newest Fix Version entry; `create` stands for a key with none. Entry ids compare as numbers. */
export async function newestFixVersionEntry(get: Getter, key: string): Promise<{ id: string; ts: string }> {
  const [newest] = await fixVersionEntries(get, key, undefined);
  return newest ? { id: String(newest.id), ts: newest.ts } : { id: 'create', ts: '' };
}

async function setOf(get: Getter, key: string): Promise<string[]> {
  const got = await get<{ fields?: { fixVersions?: Array<{ name?: string }> } }>(`/issue/${key}?fields=fixVersions`);
  const raw = got.fields?.fixVersions;
  if (!Array.isArray(raw)) throw new Error(`${key}: the read carried no fixVersions list`);
  return sorted(raw.map((v) => v.name ?? ''));
}

type VersionRef = { name?: string };

// The set a body asks for, or null when it names a version by id (or in a shape this does not read).
function requestedSet(before: string[], body: unknown): string[] | null {
  const b = body as { fields?: { fixVersions?: VersionRef[] }; update?: { fixVersions?: Array<{ add?: VersionRef; remove?: VersionRef; set?: VersionRef[] }> } };
  const names = (refs: VersionRef[]): string[] | null => (refs.every((r) => typeof r?.name === 'string') ? refs.map((r) => r.name as string) : null);
  if (b.fields?.fixVersions !== undefined) {
    const n = Array.isArray(b.fields.fixVersions) ? names(b.fields.fixVersions) : null;
    return n ? sorted(n) : null;
  }
  if (!Array.isArray(b.update?.fixVersions)) return null;
  let set = new Set(before);
  for (const op of b.update.fixVersions) {
    if (op.add) {
      if (typeof op.add.name !== 'string') return null;
      set.add(op.add.name);
    } else if (op.remove) {
      if (typeof op.remove.name !== 'string') return null;
      set.delete(op.remove.name);
    } else if (op.set) {
      const n = names(op.set);
      if (!n) return null;
      set = new Set(n);
    } else return null;
  }
  return sorted(set);
}

const same = (a: string[], b: string[]): boolean => a.length === b.length && a.every((x, i) => x === b[i]);

/** Reads the key's newest entry and set before the write. Null when the hook does not act or the path cannot be resolved. */
export async function preRead(request: WriteRequest, env: Record<string, string | undefined> = process.env): Promise<PreRead | null> {
  const scope = versionWriteScope(request.apiBase, request.method, request.path, request.body);
  if (!scope) return null;
  const journal = journalPath(env);
  if (!journal) return null;
  const mechanism = mechanismOf(request.writer, env);
  if (scope.key === null) return { journal, mechanism, key: null, set: [], entry: null };
  const set = await setOf(request.get, scope.key);
  const newest = await newestFixVersionEntry(request.get, scope.key);
  return { journal, mechanism, key: scope.key, set, entry: newest.id === 'create' ? null : BigInt(newest.id) };
}

function append(path: string, row: VersionWriteRow): void {
  mkdirSync(dirname(path), { recursive: true });
  appendFileSync(path, `${JSON.stringify(row)}\n`);
}

/** After a successful write: binds a row only to the newer entries its own write produced, with exactly the requested items. */
export async function recordVersionWrite(request: WriteRequest, response: unknown, pre: PreRead, now: () => Date = () => new Date()): Promise<void> {
  const ts = now().toISOString();
  const get = request.get;
  if (pre.key === null) {
    const key = (response as { key?: unknown } | null)?.key;
    if (typeof key !== 'string') return;
    const to = await setOf(get, key);
    const asked = requestedSet([], request.body);
    if (to.length === 0 || !asked || !same(asked, to)) return;
    append(pre.journal, { ts, key, from: [], to, mechanism: pre.mechanism, entry: 'create' });
    return;
  }
  const asked = requestedSet(pre.set, request.body);
  if (!asked || same(asked, pre.set)) return;
  const after = await setOf(get, pre.key);
  if (!same(after, asked)) return;
  const newer = await fixVersionEntries(get, pre.key, pre.entry);
  const fresh = newer.filter((e) => pre.entry === null || e.id > pre.entry);
  if (fresh.length === 0) return;
  // Combined items of every newer entry: one move lands as one entry with two items or as two entries.
  // The items must equal the requested change as listed, not as netted: a later add-then-remove by someone
  // else nets to nothing but is an entry this write did not produce.
  const added: string[] = [];
  const removed: string[] = [];
  for (const item of fresh.flatMap((e) => e.items)) {
    if (typeof item.toString === 'string' && item.toString) added.push(item.toString);
    if (typeof item.fromString === 'string' && item.fromString) removed.push(item.fromString);
  }
  const wantAdded = asked.filter((x) => !pre.set.includes(x));
  const wantRemoved = pre.set.filter((x) => !asked.includes(x));
  if (!same(added.sort(), wantAdded.sort()) || !same(removed.sort(), wantRemoved.sort())) return;
  append(pre.journal, { ts, key: pre.key, from: pre.set, to: after, mechanism: pre.mechanism, entry: String(fresh[0].id) });
}

/** Every well-formed row, oldest first; a bad line is skipped and reads as unbound. */
export function readVersionWrites(path: string): VersionWriteRow[] {
  if (!existsSync(path)) return [];
  const rows: VersionWriteRow[] = [];
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    if (!line.trim()) continue;
    try {
      const r = JSON.parse(line) as VersionWriteRow;
      const names = (v: unknown): boolean => Array.isArray(v) && v.every((x) => typeof x === 'string');
      if (typeof r.ts === 'string' && typeof r.key === 'string' && typeof r.entry === 'string' && typeof r.mechanism === 'string' && names(r.from) && names(r.to)) rows.push(r);
    } catch {
      // a bad line is skipped
    }
  }
  return rows;
}
