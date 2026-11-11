import { createHash } from 'node:crypto';
import { existsSync, linkSync, readFileSync, renameSync, unlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fold, operatorFence, readMirror, repairInputs, request, state, withdrawHeldRepair, type Ctx } from './engine.js';
import {
  classify, displacementCandidates, mismatchKeys, offerFor, type Classification, type HeldClass, type Lane, type RepairInput,
} from './repair.js';
import { terminalOf } from './reducer.js';
import type { Verb } from './types.js';
import { journalPath, newestFixVersionEntry, readVersionWrites, type Getter } from './version-writes.js';

// The version repair. Without --apply it is a dry run: everything classify() must not do (read the ledgers, the mirror,
// Jira and gh), and it writes nothing. With --apply it also files requests, folds, writes the held file and keeps its
// own status, cache, lock and marker files in the release directory. It never writes a Fix Version.

export const CAP = 20;

/** What the injected request check throws when it refuses a request; any other error from it is a failed read. */
export class RequestRefused extends Error {}
const PR_LIST_LIMIT = 50;
const NO_PR_TTL_MS = 24 * 60 * 60 * 1000;

export interface RepairRunOptions {
  repo: string | null;
  apply?: boolean;
  /** One Jira GET, with its own deadline: the fetch has none. A deadline is a failed read. */
  get: Getter;
  /** `gh <args>`: stdout, or a throw. Every call carries --repo. */
  gh: (args: string[]) => string;
  /** The version-writes journal; default is the live one. */
  journal?: string | null;
  /** The versions file; default is <mirror>.versions.tsv. */
  versionsFile?: string | null;
  /** The request check of `jira release request`, handed in because release/ does not import commands/. A throw refuses the request. */
  refuse?: (ctx: Ctx, row: { verb: Verb; key: string; from_v: string | null; to_v: string | null; why: string; evidence: Record<string, unknown>; origin: 'repair' }) => void;
}

export type StopWhy = 'mirror-unknown' | 'bad-input';

export interface PasteRow {
  op: 'keep' | 'add' | 'move' | 'remove';
  from: string | null;
  to: string | null;
  verb?: 'INTAKE';
  note?: string;
  keys: string[];
  paste: string;
}

export interface HeldClassOut { class: HeldClass; question: string; keys: string[]; commands: PasteRow[] }

export interface RepairReport {
  status: 'ok' | 'stopped' | 'error' | 'busy';
  why?: StopWhy;
  error?: string;
  lanes?: Record<Lane, string[]>;
  stale?: string[];
  classes?: HeldClassOut[];
  capped?: boolean;
  progress?: number;
}

const LANE_NAMES: Lane[] = ['rm-held', 'in-flight', 'nothing', 'already-asked', 'operator-record', 'closed-undelivered', 'fold', 'gate-row', 'split', 'bound-ruled', 'bound', 'held'];

const QUESTIONS: Record<HeldClass, string> = {
  unbound: 'The Fix Version changed with no ruling and no machine record behind it: keep it, or rule it otherwise?',
  hand: 'A hand edit changed the Fix Version and no ruling records it: keep it, or rule it otherwise?',
  split: 'More than one declared version and no ruling explains it: which one is meant?',
  'closed-undelivered': "Closed without delivery (Won't Do, Duplicate or Other) and still on a version: remove it?",
  'done-no-pr': 'Done with no merged PR that passes the delivery proof: keep it on its version?',
  'gate-row': 'Open with only a gate row: does the gate row admit it?',
  'ruled-displaced': 'A machine write stripped an operator-ruled version: add it back?',
  conflict: 'A Fix Version change is newer than the signed record naming the key: record the new placement.',
  'rm-hold': 'The release manager held the request: record the placement.',
  'rm-unresolved': 'The release manager ruled or refused and the mismatch remains: record the placement.',
};

const stop = (why: StopWhy, error: string): RepairReport => ({ status: 'stopped', why, error });

/** The release date of the nearest earlier released version in the versions file; null when unreadable, never walking back. */
function previousRelease(file: string | null, current: string): number | null {
  if (!file || !existsSync(file)) return null;
  const rows = readFileSync(file, 'utf8').split('\n').filter((l) => l.trim()).map((l) => l.split('\t'));
  const at = rows.findIndex((r) => r[0] === current);
  if (at < 1) return null;
  for (let i = at - 1; i >= 0; i--) {
    if (rows[i]![1] !== 'true') continue;
    const t = Date.parse(rows[i]![2] ?? '');
    return Number.isNaN(t) ? null : t;
  }
  return null;
}

const FIRST_KEY = /[A-Z][A-Z0-9]*-\d+/;

/** The delivery proof: the newest merged PR that names the key first and merged after the previous release; null when none passes. */
export function passingPr(listing: unknown, key: string, since: number): number | null {
  if (!Array.isArray(listing)) throw new Error('gh pr list did not answer a list');
  let best: { number: number; at: number } | null = null;
  for (const p of listing as Array<{ number?: unknown; title?: unknown; mergedAt?: unknown }>) {
    if (typeof p.number !== 'number' || typeof p.title !== 'string' || typeof p.mergedAt !== 'string') continue;
    const at = Date.parse(p.mergedAt);
    if (FIRST_KEY.exec(p.title)?.[0] !== key || Number.isNaN(at) || at <= since) continue;
    if (best === null || at > best.at) best = { number: p.number, at };
  }
  return best?.number ?? null;
}

function stopOf(ctx: Ctx, o: RepairRunOptions): { stop: RepairReport } | { s: ReturnType<typeof state>; ri: ReturnType<typeof repairInputs> } {
  if (!o.repo) return { stop: stop('bad-input', '--repo <owner/name> is required: every gh call carries it') };
  const s = state(ctx);
  if (s.status !== 'OK') return { stop: stop('bad-input', `release ${ctx.release} is UNKNOWN: ${s.integrity[0] ?? 'no reason given'}`) };
  const ri = repairInputs(ctx);
  const bad = Object.entries(s.inputs).filter(([k, v]) => k !== 'mirror' && v === 'UNKNOWN').map(([k]) => k);
  if (bad.length) return { stop: stop('bad-input', `input ${bad.join(', ')} is UNKNOWN`) };
  if (ri.requestsBad) return { stop: stop('bad-input', 'requests.jsonl has a line that does not verify') };
  if (s.inputs.mirror === 'UNKNOWN') return { stop: stop('mirror-unknown', 'the Jira mirror is UNKNOWN: no sync, so no verdict') };
  return { s, ri };
}

// --- the PR cache: a PR is kept for good, "no PR" for 24 hours ---------------------------------

type PrCache = Record<string, { pr: number | null; at: string; repo: string }>;

const cacheFile = (ctx: Ctx): string => join(ctx.dir, 'repair-pr-cache.json');

function readPrCache(ctx: Ctx): PrCache {
  try {
    const raw: unknown = JSON.parse(readFileSync(cacheFile(ctx), 'utf8'));
    if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) return {};
    const out: PrCache = {};
    for (const [k, v] of Object.entries(raw as Record<string, unknown>)) {
      const e = v as { pr?: unknown; at?: unknown; repo?: unknown } | null;
      if (e && typeof e.at === 'string' && typeof e.repo === 'string' && (e.pr === null || (Number.isSafeInteger(e.pr) && (e.pr as number) > 0))) out[k] = { pr: e.pr as number | null, at: e.at, repo: e.repo };
    }
    return out;
  } catch {
    return {}; // derived data: a missing or bad file is looked up again
  }
}

// A PR is settled; a "no PR" is settled while it is fresh. An expired one is looked up again.
const settled = (e: PrCache[string], now: number): boolean => e.pr !== null || now - Date.parse(e.at) < NO_PR_TTL_MS;

function writeAtomic(path: string, text: string): void {
  const tmp = `${path}.tmp-${process.pid}`;
  writeFileSync(tmp, text);
  renameSync(tmp, path);
}

// --- the plan: the part both the dry run and --apply share -----------------------------------

interface Planned {
  s: ReturnType<typeof state>;
  current: string;
  input: RepairInput;
  out: Classification[];
  mismatch: Set<string>;
  mirror: ReturnType<typeof readMirror>;
  notFound: Set<string>;
  answers: Map<string, number | null>; // PR lookups answered in this run
  ghError: string | null;
  resolved: number;
  capped: boolean;
}

async function plan(ctx: Ctx, o: RepairRunOptions): Promise<{ done: RepairReport } | { p: Planned }> {
  const got = stopOf(ctx, o);
  if ('stop' in got) return { done: got.stop };
  const { s, ri } = got;
  const repo = o.repo!;
  const current = s.versions[0]!;
  const mirror = readMirror(ctx.mirrorRoot);
  const jf = o.journal === undefined ? journalPath(ctx.env) : o.journal;
  const journal = jf ? readVersionWrites(jf) : [];
  const missingKeys = new Set(s.records.filter((r) => r.expected_member === true && !mirror.issues?.has(r.key)).map((r) => r.key));

  // Changelog reads: only mismatching keys with a journal row or a naming O- row, one at a time.
  const leakKeys = new Set([...s.leaks.unauthorized, ...s.leaks.ruled_in_non_member].map((l) => l.slice(0, l.lastIndexOf('@'))));
  const rowKeys = new Set(journal.map((j) => j.key));
  const named = new Set(ri.operator.filter((r) => r.kind === 'decision').flatMap((r) => r.keys ?? []));
  const candidates = displacementCandidates(journal, s.versions);
  const readKeys = [...new Set([...leakKeys, ...candidates])].filter((k) => rowKeys.has(k) || named.has(k)).sort();
  const newestEntry = new Map<string, { id: string; ts: string }>();
  const notFound = new Set<string>();
  for (const key of readKeys) {
    try {
      newestEntry.set(key, await newestFixVersionEntry(o.get, key));
    } catch (e) {
      const msg = (e as Error).message;
      if (!/^HTTP 404$/.test(msg)) return { done: { status: 'error', error: `Jira read of ${key} failed: ${msg}` } };
      notFound.add(key);
    }
  }

  // A displaced key may carry no declared record, so its closed state comes from the mirror, the same way in a dry run and in --apply.
  const terminals = new Map([...candidates].map((k) => [k, terminalOf(mirror.issues?.get(k))] as const));
  const base: Omit<RepairInput, 'mergedPr'> = {
    records: s.records, leaks: s.leaks, current, versions: s.versions, operator: ri.operator, rulings: ri.rulings, admissions: ri.admissions,
    requests: ri.requests, journal, newestEntry, missingKeys: new Set([...missingKeys, ...notFound]), terminals,
  };

  // Pass one finds the keys lane 7 wants looked up; they are looked up within the cap; pass two classifies with the answers.
  const need = classify({ ...base, mergedPr: new Map() }).filter((c) => c.lane === 'fold' && c.action.kind === 'none').map((c) => c.key);
  const since = previousRelease(o.versionsFile === undefined ? (ctx.mirrorRoot ? `${ctx.mirrorRoot.replace(/\/+$/, '')}.versions.tsv` : null) : o.versionsFile, current);
  const cache = readPrCache(ctx);
  const now = ctx.now().getTime();
  const mergedPr = new Map<string, number | null>();
  const answers = new Map<string, number | null>();
  const unsettled: string[] = [];
  let lookups = 0;
  let resolved = 0;
  let ghError: string | null = null;
  for (const key of need) {
    const entry = cache[key];
    const hit = entry?.repo === repo ? entry : undefined; // a PR number found in another repo proves nothing here
    if (hit && settled(hit, now)) {
      mergedPr.set(key, hit.pr);
      continue;
    }
    // An expired "no PR" stays in done-no-pr until it is looked up again, so a key beyond the cap does not leave Held.
    if (hit) mergedPr.set(key, null);
    if (since === null) {
      mergedPr.set(key, null);
      continue;
    }
    unsettled.push(key);
    if (lookups >= CAP || ghError !== null) continue;
    lookups++;
    try {
      const listing: unknown = JSON.parse(o.gh(['pr', 'list', '--repo', repo, '--state', 'merged', '--search', `${key} in:title`, '--json', 'number,title,mergedAt', '--limit', String(PR_LIST_LIMIT)]));
      // A full page may have cut off the qualifying PR, so it proves nothing: the key stays unresolved.
      if (Array.isArray(listing) && listing.length >= PR_LIST_LIMIT) continue;
      const found = passingPr(listing, key, since);
      mergedPr.set(key, found);
      answers.set(key, found);
      unsettled.splice(unsettled.indexOf(key), 1);
      resolved++;
    } catch (e) {
      ghError = (e as Error).message;
    }
  }

  let input: RepairInput = { ...base, mergedPr };
  let out = classify(input);

  // A request the entry check would refuse is never filed: the key falls through to lane 12.
  if (o.refuse) {
    const refused = new Set<string>();
    for (const c of out) {
      if (c.action.kind !== 'request') continue;
      try {
        o.refuse(ctx, { verb: c.action.verb, key: c.key, from_v: c.action.from, to_v: c.action.to, why: c.action.why, evidence: { rule: 'version-repair', entry: c.action.entry }, origin: 'repair' });
      } catch (e) {
        if (!(e instanceof RequestRefused)) throw e; // a read error is not a refusal: the run ends as an error
        refused.add(c.key);
      }
    }
    if (refused.size) {
      input = { ...input, refused };
      out = classify(input);
    }
  }

  const { leak, displaced } = mismatchKeys(input);
  const mismatch = new Set([...leak, ...displaced]);
  const folds = out.filter((c) => c.action.kind === 'fold').length;
  const requests = out.filter((c) => c.action.kind === 'request').length;
  const capped = unsettled.length > 0 && ghError === null || folds > CAP || requests > CAP;
  return { p: { s, current, input, out, mismatch, mirror, notFound, answers, ghError, resolved, capped } };
}

function report(ctx: Ctx, p: Planned, progress: number, extraError: string | null): RepairReport {
  const lanes = Object.fromEntries(LANE_NAMES.map((l) => [l, [] as string[]])) as Record<Lane, string[]>;
  for (const c of p.out) if (p.mismatch.has(c.key)) lanes[c.lane].push(c.key);
  const stale = [...new Set([...p.out.filter((c) => c.lane === 'in-flight' && !p.mismatch.has(c.key)).map((c) => c.key), ...p.notFound])].sort();
  const error = extraError ?? (p.ghError === null ? null : `gh failed: ${p.ghError}`);
  return {
    status: error === null ? 'ok' : 'error',
    ...(error === null ? {} : { error }),
    lanes, stale, classes: classesOf(ctx.release, p.out, p.input), capped: p.capped, progress,
  };
}

/** The dry run's progress: what the same inputs would resolve, fold and file. */
const plannedProgress = (p: Planned): number =>
  Math.min(p.out.filter((c) => c.action.kind === 'fold').length, CAP) + Math.min(p.out.filter((c) => c.action.kind === 'request').length, CAP) + p.resolved;

// --- --apply -------------------------------------------------------------------------------------

/** The lock at release/<R>/repair.lock holds its owner's pid; it is stale when that pid is gone. A live owner returns null. */
function takeLock(dir: string): (() => void) | null {
  const path = join(dir, 'repair.lock');
  const alive = (pid: number): boolean => {
    try {
      process.kill(pid, 0);
      return true;
    } catch (e) {
      return (e as NodeJS.ErrnoException).code === 'EPERM';
    }
  };
  const mine = `${path}.new-${process.pid}`;
  const owner = (file: string): number => Number(readFileSync(file, 'utf8').trim());
  // The pid is in the file before the lock name exists (link is atomic), so no run ever reads an empty lock as stale.
  writeFileSync(mine, `${process.pid}\n`);
  try {
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        linkSync(mine, path);
        return () => {
          try {
            if (owner(path) === process.pid) unlinkSync(path);
          } catch { /* already gone */ }
        };
      } catch (e) {
        if ((e as NodeJS.ErrnoException).code !== 'EEXIST') throw e;
      }
      let pid: number;
      try {
        pid = owner(path);
      } catch {
        continue; // released between the link and the read
      }
      if (Number.isInteger(pid) && pid > 0 && alive(pid)) return null;
      // A stale lock is moved aside by one rename, which only one contender wins; a live lock that was grabbed by mistake goes back.
      // ponytail: a third contender between the rename and the put-back can still start beside the owner; upgrade path: a flock(2) holder if concurrent launches ever show up.
      const aside = `${path}.stale-${process.pid}`;
      try {
        renameSync(path, aside);
      } catch {
        continue;
      }
      const moved = owner(aside);
      if (moved !== pid) {
        try {
          linkSync(aside, path);
        } catch { /* another run already holds the name */ }
        unlinkSync(aside);
        return null;
      }
      unlinkSync(aside);
    }
    return null;
  } finally {
    unlinkSync(mine);
  }
}

const rm = (path: string): void => {
  try {
    unlinkSync(path);
  } catch { /* already gone */ }
};

interface LiveIssue {
  fields?: {
    fixVersions?: Array<{ name?: unknown }>;
    status?: { name?: unknown; statusCategory?: { key?: unknown } };
    resolution?: { name?: unknown } | null;
  };
}

/** The live read just before an action: Jira still holds what the mirror says (and the same newest entry for a request). A failed read throws. */
async function liveAgrees(o: RepairRunOptions, mirror: ReturnType<typeof readMirror>, key: string, entry: string | null): Promise<boolean> {
  const snap = mirror.issues?.get(key);
  if (!snap) return false;
  const notFound = (e: unknown): boolean => /^HTTP 404$/.test((e as Error).message);
  let issue: LiveIssue;
  try {
    issue = await o.get<LiveIssue>(`/issue/${key}?fields=fixVersions,status,resolution`);
  } catch (e) {
    if (notFound(e)) return false;
    throw e;
  }
  const live = (issue.fields?.fixVersions ?? []).flatMap((v) => (typeof v.name === 'string' ? [v.name] : [])).sort();
  if (live.join('\n') !== [...snap.fixVersions].sort().join('\n')) return false;
  const status = issue.fields?.status;
  if (status?.name !== snap.status) return false;
  if (entry === null) {
    // Done-category also covers Won't Do and Duplicate: the fold needs the same terminal the classifier folded on.
    const category = status?.statusCategory?.key === 'done' ? 'Done' : null;
    const resolution = typeof issue.fields?.resolution?.name === 'string' ? issue.fields.resolution.name : null;
    return terminalOf({ ...snap, statusCategory: category, resolution }) === 'Done';
  }
  try {
    return (await newestFixVersionEntry(o.get, key)).id === entry;
  } catch (e) {
    if (notFound(e)) return false;
    throw e;
  }
}

function heldFile(ctx: Ctx, p: Planned): { classes: HeldClassOut[]; json: string } {
  const classes = classesOf(ctx.release, p.out, p.input);
  const lines = classes.flatMap((c) => c.keys.map((k) => `${c.class}\t${k}`)).sort();
  const unfiled = p.out.filter((c) => c.action.kind === 'unfiled' || (c.action.kind === 'withdraw-held' && c.lane === 'operator-record')).length;
  const out = {
    release: ctx.release,
    held: new Set(classes.flatMap((c) => c.keys)).size,
    unfiled,
    held_signature: createHash('sha256').update(lines.join('\n')).digest('hex'),
    classes,
  };
  return { classes, json: `${JSON.stringify(out, null, 2)}\n` };
}

async function applyRun(ctx: Ctx, o: RepairRunOptions): Promise<RepairReport> {
  const planned = await plan(ctx, o);
  if ('done' in planned) return planned.done;
  const { p } = planned;
  const now = ctx.now().toISOString();

  // The lookups come first on disk, so a stop later in the run does not lose them.
  if (p.answers.size) {
    const cache = readPrCache(ctx);
    for (const [key, pr] of p.answers) cache[key] = { pr, at: now, repo: o.repo! };
    writeAtomic(cacheFile(ctx), `${JSON.stringify(cache, null, 2)}\n`);
  }

  let progress = p.resolved;
  let liveError: string | null = null;

  for (const c of p.out) {
    if (c.action.kind !== 'withdraw-held') continue;
    const reason = c.lane === 'operator-record' ? 'answered-by-operator-record' : 'held-entry-moved';
    if (withdrawHeldRepair(ctx, { req: c.action.requestId, reason })) progress++;
  }

  // Folds, one live read each. A failed read stops all further filing in this run.
  // The cap counts actions that passed the live read, so stale-mirror keys cannot starve later ones.
  let folds = 0;
  for (const c of p.out.filter((x) => x.action.kind === 'fold')) {
    if (liveError !== null || folds >= CAP) break;
    try {
      if (!(await liveAgrees(o, p.mirror, c.key, null))) continue;
    } catch (e) {
      liveError = `Jira live read of ${c.key} failed: ${(e as Error).message}`;
      break;
    }
    const res = fold(ctx, { to: p.current, items: [{ key: c.key, pr: (c.action as { pr: number }).pr }] });
    progress += res.folded.length;
    folds++;
  }

  let requests = 0;
  for (const c of p.out.filter((x) => x.action.kind === 'request')) {
    if (liveError !== null || requests >= CAP) break;
    const a = c.action as Extract<Classification['action'], { kind: 'request' }>;
    try {
      if (!(await liveAgrees(o, p.mirror, c.key, a.entry))) continue;
    } catch (e) {
      liveError = `Jira live read of ${c.key} failed: ${(e as Error).message}`;
      break;
    }
    request(ctx, { verb: a.verb, key: c.key, from_v: a.from, to_v: a.to, why: a.why, evidence: { rule: 'version-repair', entry: a.entry }, from: 'repair' });
    progress++;
    requests++;
  }

  writeAtomic(join(ctx.dir, 'repair-held.json'), heldFile(ctx, p).json);
  return report(ctx, p, progress, liveError);
}

export async function repairRun(ctx: Ctx, o: RepairRunOptions): Promise<RepairReport> {
  if (!o.apply) {
    const planned = await plan(ctx, o);
    return 'done' in planned ? planned.done : report(ctx, planned.p, plannedProgress(planned.p), null);
  }

  operatorFence(ctx); // the first statement of the apply path: before the lock, the marker and any append
  const jf = o.journal === undefined ? journalPath(ctx.env) : o.journal;
  if (jf === null) throw new Error('release repair: --apply needs the version-writes journal; it is off here (HIMMEL_VERSION_WRITES under NODE_ENV=test), and with no journal every key reads as unbound');
  const unlock = takeLock(ctx.dir); // a busy lock is no error: nothing below ran, nothing was touched
  if (unlock === null) return { status: 'busy' };
  try {
    let result: RepairReport;
    try {
      result = await applyRun(ctx, o);
    } catch (e) {
      result = { status: 'error', error: (e as Error).message };
    }
    const statusFile = join(ctx.dir, 'repair-status');
    const signature = join(ctx.dir, 'repair-signature');
    if (result.status === 'ok') {
      rm(statusFile);
      if (result.capped && (result.progress ?? 0) > 0) rm(signature);
      writeFileSync(join(ctx.dir, 'repair-reviewed'), `${ctx.now().toISOString()}\n`); // last, and only on a clean exit
    } else {
      writeFileSync(statusFile, `${result.status === 'stopped' ? result.why : 'error'}\n${result.error ?? ''}\n`);
      if (result.status === 'error') rm(signature);
    }
    return result;
  } finally {
    unlock();
  }
}

function classesOf(release: string, out: Classification[], input: RepairInput): HeldClassOut[] {
  const byClass = new Map<HeldClass, Classification[]>();
  for (const c of out) if (c.action.kind === 'held') byClass.set(c.action.cls, [...(byClass.get(c.action.cls) ?? []), c]);
  return [...byClass].map(([cls, items]) => {
    const rows = new Map<string, PasteRow>();
    for (const c of items) {
      const offer = offerFor(c, input);
      if (offer.op === null) continue;
      const id = JSON.stringify([offer.op, offer.from, offer.to, offer.verb ?? null]);
      const row = rows.get(id) ?? { op: offer.op, from: offer.from, to: offer.to, ...(offer.verb ? { verb: offer.verb } : {}), ...(offer.note ? { note: offer.note } : {}), keys: [], paste: '' };
      row.keys.push(c.key);
      rows.set(id, row);
    }
    const commands = [...rows.values()].map((r) => {
      const keys = r.keys.sort();
      return { ...r, keys, paste: `jira release operator decision ${release} --decision <n> --keys ${keys.join(',')} --op ${r.op} --from ${r.from ?? 'backlog'} --to ${r.to ?? 'backlog'} --verbatim-file <path>` };
    });
    return { class: cls, question: QUESTIONS[cls], keys: items.map((c) => c.key).sort(), commands };
  }).sort((a, b) => (a.class < b.class ? -1 : 1));
}
