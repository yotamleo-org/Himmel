import { existsSync, readFileSync } from 'node:fs';
import { readMirror, repairInputs, state, type Ctx } from './engine.js';
import {
  classify, displacementCandidates, mismatchKeys, offerFor, type Classification, type HeldClass, type Lane, type RepairInput,
} from './repair.js';
import { journalPath, newestFixVersionEntry, readVersionWrites, type Getter } from './version-writes.js';

// The version repair's dry run: everything classify() must not do (read the ledgers, the mirror, Jira and gh). It
// writes nothing: no ledger row, no request, no Fix Version, no file.

export const CAP = 20;

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
  status: 'ok' | 'stopped' | 'error';
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

export async function repairRun(ctx: Ctx, o: RepairRunOptions): Promise<RepairReport> {
  if (o.apply) throw new Error('release repair: --apply is not built yet; this build prints the dry run only');
  const got = stopOf(ctx, o);
  if ('stop' in got) return got.stop;
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
  const readKeys = [...new Set([...leakKeys, ...displacementCandidates(journal)])].filter((k) => rowKeys.has(k) || named.has(k)).sort();
  const newestEntry = new Map<string, { id: string; ts: string }>();
  const notFound = new Set<string>();
  for (const key of readKeys) {
    try {
      newestEntry.set(key, await newestFixVersionEntry(o.get, key));
    } catch (e) {
      const msg = (e as Error).message;
      if (!/\b404\b/.test(msg)) return { status: 'error', error: `Jira read of ${key} failed: ${msg}` };
      notFound.add(key);
    }
  }

  const base: Omit<RepairInput, 'mergedPr'> = {
    records: s.records, leaks: s.leaks, current, operator: ri.operator, rulings: ri.rulings, admissions: ri.admissions,
    requests: ri.requests, journal, newestEntry, missingKeys: new Set([...missingKeys, ...notFound]),
  };

  // Pass one finds the keys lane 7 wants looked up; they are looked up within the cap; pass two classifies with the answers.
  const need = classify({ ...base, mergedPr: new Map() }).filter((c) => c.lane === 'fold' && c.action.kind === 'none').map((c) => c.key);
  const since = previousRelease(o.versionsFile === undefined ? (ctx.mirrorRoot ? `${ctx.mirrorRoot.replace(/\/+$/, '')}.versions.tsv` : null) : o.versionsFile, current);
  const mergedPr = new Map<string, number | null>();
  let lookups = 0;
  let resolved = 0;
  let ghError: string | null = null;
  for (const key of need) {
    if (since === null) {
      mergedPr.set(key, null);
      continue;
    }
    if (lookups >= CAP || ghError !== null) break;
    lookups++;
    try {
      const listing: unknown = JSON.parse(o.gh(['pr', 'list', '--repo', repo, '--state', 'merged', '--search', `${key} in:title`, '--json', 'number,title,mergedAt', '--limit', '50']));
      mergedPr.set(key, passingPr(listing, key, since));
      resolved++;
    } catch (e) {
      ghError = (e as Error).message;
    }
  }

  const input: RepairInput = { ...base, mergedPr };
  const out = classify(input);
  const { leak, displaced } = mismatchKeys(input);
  const mismatch = new Set([...leak, ...displaced]);

  const lanes = Object.fromEntries(LANE_NAMES.map((l) => [l, [] as string[]])) as Record<Lane, string[]>;
  for (const c of out) if (mismatch.has(c.key)) lanes[c.lane].push(c.key);
  const stale = [...new Set([...out.filter((c) => c.lane === 'in-flight' && !mismatch.has(c.key)).map((c) => c.key), ...notFound])].sort();
  const folds = out.filter((c) => c.action.kind === 'fold').length;
  const requests = out.filter((c) => c.action.kind === 'request').length;
  const capped = need.some((k) => !mergedPr.has(k)) && ghError === null || folds > CAP || requests > CAP;

  return {
    status: ghError === null ? 'ok' : 'error',
    ...(ghError === null ? {} : { error: `gh failed: ${ghError}` }),
    lanes, stale, classes: classesOf(ctx.release, out, input), capped, progress: Math.min(folds, CAP) + Math.min(requests, CAP) + resolved,
  };
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
