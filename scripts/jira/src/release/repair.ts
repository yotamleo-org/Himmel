import type { Admission } from '../commands/admissions-ledger.js';
import { admits } from './admits.js';
import type { KeyRecord, ReleaseState } from './reducer.js';
import type { OperatorRow, RequestRow, RulingRow } from './types.js';
import { WRITER_TABLE, type VersionWriteRow } from './version-writes.js';

// The version-repair classifier (the version-drift repair spec, "The lanes"): which lane each mismatching key sits in and what that
// lane does. Pure: no Jira, no fs, no gh. It reads the reducer's leaks and never re-derives the verdict. It never writes.

export type Lane = 'rm-held' | 'in-flight' | 'nothing' | 'already-asked' | 'operator-record' | 'closed-undelivered'
  | 'fold' | 'gate-row' | 'split' | 'bound-ruled' | 'bound' | 'held';
export type HeldClass = 'unbound' | 'hand' | 'split' | 'closed-undelivered' | 'done-no-pr' | 'gate-row'
  | 'ruled-displaced' | 'conflict' | 'rm-hold' | 'rm-unresolved';

export interface RepairInput {
  records: KeyRecord[]; // the reducer's output, unchanged; stale = actual_member === 'unknown'
  leaks: ReleaseState['leaks']; // the reducer's verdict, never re-derived here
  current: string;
  versions?: string[]; // the release's declared versions; when given, a displacement from any other version is not this release's
  operator: OperatorRow[];
  rulings: RulingRow[];
  admissions: Admission[];
  requests: RequestRow[]; // latest row per request
  journal: VersionWriteRow[]; // oldest first
  newestEntry: Map<string, { id: string; ts: string }>; // `create` is the id of a key with no Fix Version entry
  mergedPr: Map<string, number | null>; // null = none passes; absent = not looked up yet
  missingKeys: Set<string>;
}

export type Action = { kind: 'none' } | { kind: 'held'; cls: HeldClass } | { kind: 'unfiled' }
  | { kind: 'fold'; pr: number }
  | { kind: 'request'; verb: 'INTAKE' | 'REVERSION'; from: string | null; to: string | null; entry: string; why: string }
  | { kind: 'withdraw-held'; requestId: string };

export interface Classification { key: string; version: string; lane: Lane; action: Action }

export interface Offer { op: 'keep' | 'add' | 'move' | 'remove' | null; verb?: 'INTAKE'; from: string | null; to: string | null; note?: string }

// A never-landed request is refiled at most this many times per (key, entry); the next one is rm-unresolved (D3).
const REFILE_CAP = 3;
const DISPLACEMENT = new Set(['displace-residual', 'create-stepdown']);
const MACHINE = new Set(WRITER_TABLE.filter((w) => w.machine).map((w) => w.mechanism));

const newer = (a: string, b: string): boolean => Date.parse(a) > Date.parse(b);
const last = <T>(xs: T[]): T | undefined => xs[xs.length - 1];

const evidenceOf = (r: RequestRow): { rule?: unknown; entry?: unknown } =>
  r.evidence !== null && typeof r.evidence === 'object' ? (r.evidence as { rule?: unknown; entry?: unknown }) : {};
const isRepair = (r: RequestRow): boolean => evidenceOf(r).rule === 'version-repair';
const entryOf = (r: RequestRow): string | null => {
  const e = evidenceOf(r).entry;
  return isRepair(r) && typeof e === 'string' ? e : null;
};
const isPending = (r: RequestRow): boolean => r.state === 'open' || r.state.startsWith('claimed:');
const neverLanded = (r: RequestRow): boolean => isRepair(r) && r.state === 'withdrawn:repair' && r.reason === 'never-landed';
// The engine withdraws a repair request with no entry to compare as entry-moved. It names no (key, entry), so it neither
// dedupes nor counts as a newer request: the refile names the entry (S4 carry-forward).
const entryLess = (r: RequestRow): boolean =>
  isRepair(r) && entryOf(r) === null && r.state === 'withdrawn:repair' && r.reason === 'entry-moved';

const keyOf = (line: string): { key: string; version: string } => {
  const at = line.lastIndexOf('@');
  return { key: line.slice(0, at), version: line.slice(at + 1) };
};

function leakVersions(leaks: ReleaseState['leaks'], key: string): { unauth: string[]; ruledIn: string[] } {
  const pick = (lines: string[]) => lines.map(keyOf).filter((l) => l.key === key).map((l) => l.version);
  return { unauth: pick(leaks.unauthorized), ruledIn: pick(leaks.ruled_in_non_member) };
}

// The authority behind a record's ruling. A baseline carries no ruling row; it is the operator's freeze.
function authorityOf(input: RepairInput, rec: KeyRecord | undefined): 'rm' | 'operator' | null {
  if (!rec || rec.ruling === null) return null;
  const row = input.rulings.find((r) => r.id === rec.ruling);
  return row?.authority.kind === 'rm' ? 'rm' : 'operator';
}

interface KeyCtx {
  key: string;
  recs: KeyRecord[];
  unauth: string[];
  ruledIn: string[];
  terminal: KeyRecord['terminal'];
  rows: VersionWriteRow[];
  row: VersionWriteRow | undefined;
  entry: { id: string; ts: string } | undefined;
  reqs: RequestRow[];
  decisions: OperatorRow[];
  stale: boolean;
  displaced: boolean;
}

interface Env { input: RepairInput; ctx: KeyCtx; declared: Set<string> }
type Verdict = Pick<Classification, 'lane' | 'action'> & { version?: string };
type LaneFn = (e: Env) => Verdict | undefined;

const held = (lane: Lane, cls: HeldClass, version?: string): Verdict => ({ lane, action: { kind: 'held', cls }, ...(version === undefined ? {} : { version }) });
const removedVersion = (ctx: KeyCtx): string => ctx.row?.from[0] ?? '';
const answered = (ctx: KeyCtx, r: RequestRow): boolean => ctx.decisions.some((d) => newer(d.ts, r.ts));
const byTs = (a: { ts: string }, b: { ts: string }): number => Date.parse(a.ts) - Date.parse(b.ts);
const isBound = (ctx: KeyCtx): boolean => ctx.row !== undefined && ctx.entry?.id === ctx.row.entry;

// The mismatch set: the keys of the reducer's leak lines, plus the one input that is not a reducer verdict, a key whose
// newest journal row is a machine displacement to none that is still the newest Fix Version entry in Jira.
export function mismatchKeys(input: RepairInput): { leak: Set<string>; displaced: Set<string> } {
  const leak = new Set([...input.leaks.unauthorized, ...input.leaks.ruled_in_non_member].map((l) => keyOf(l).key));
  const displaced = new Set<string>();
  for (const [key, row] of displacementRows(input.journal, input.versions)) if (input.newestEntry.get(key)?.id === row.entry) displaced.add(key);
  return { leak, displaced };
}

// The keys whose newest journal row is a machine displacement to none: candidates until Jira confirms the row is still the newest entry.
function displacementRows(journal: VersionWriteRow[], versions?: string[]): Map<string, VersionWriteRow> {
  const newest = new Map<string, VersionWriteRow>();
  for (const j of journal) newest.set(j.key, j);
  for (const [key, row] of newest) {
    if (!DISPLACEMENT.has(row.mechanism) || row.to.length > 0 || (versions && !versions.includes(row.from[0] ?? ''))) newest.delete(key);
  }
  return newest;
}

export const displacementCandidates = (journal: VersionWriteRow[], versions?: string[]): Set<string> => new Set(displacementRows(journal, versions).keys());

export function classify(input: RepairInput): Classification[] {
  const declared = new Set(input.records.map((r) => `${r.key}@${r.version}`));
  const rowsOf = new Map<string, VersionWriteRow[]>();
  for (const j of input.journal) rowsOf.set(j.key, [...(rowsOf.get(j.key) ?? []), j]);

  const stale = new Set<string>(input.missingKeys);
  for (const r of input.records) if (r.placement === 'pending' || r.placement === 'unknown' || r.actual_member === 'unknown') stale.add(r.key);

  const { leak: leakKeys, displaced } = mismatchKeys(input);

  const out: Classification[] = [];
  for (const key of new Set([...leakKeys, ...displaced, ...stale])) {
    const recs = input.records.filter((r) => r.key === key);
    const { unauth, ruledIn } = leakVersions(input.leaks, key);
    const rows = rowsOf.get(key) ?? [];
    const ctx: KeyCtx = {
      key, recs, unauth, ruledIn, terminal: recs[0]?.terminal ?? null, rows, row: last(rows), entry: input.newestEntry.get(key),
      reqs: input.requests.filter((r) => r.key === key),
      decisions: input.operator.filter((o) => o.kind === 'decision' && o.keys?.includes(key)).sort(byTs),
      stale: stale.has(key), displaced: displaced.has(key),
    };
    if (!leakKeys.has(key) && !displaced.has(key)) {
      out.push({ key, version: recs.find((r) => r.actual_member === 'unknown' || r.placement === 'pending' || r.placement === 'unknown')?.version ?? '', lane: 'in-flight', action: { kind: 'none' } });
      continue;
    }
    const v = firstLane({ input, ctx, declared });
    out.push({ key, version: v.version ?? unauth[0] ?? ruledIn[0] ?? (ctx.displaced ? removedVersion(ctx) : ''), lane: v.lane, action: v.action });
  }
  return out.sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0));
}

// Lane 1, and the signed answer that beats it (chief ruling D2): a decision newer than a held request retires it.
const rmHeldLane: LaneFn = ({ ctx }) => {
  const req = last(ctx.reqs.filter((r) => r.state === 'held' && isRepair(r)).sort(byTs));
  if (!req) return undefined;
  if (answered(ctx, req)) return { lane: 'operator-record', action: { kind: 'withdraw-held', requestId: req.req } };
  const filed = entryOf(req);
  if (filed === null || (ctx.entry !== undefined && ctx.entry.id !== filed)) return { lane: 'rm-held', action: { kind: 'withdraw-held', requestId: req.req } };
  return held('rm-held', 'rm-hold');
};

// Lane 2: in flight.
const inFlightLane: LaneFn = ({ ctx }) => (ctx.stale || ctx.reqs.some(isPending) ? { lane: 'in-flight', action: { kind: 'none' } } : undefined);

// Lane 3: an effective ruling agrees with Jira and no leak line remains.
const nothingLane: LaneFn = ({ ctx }) =>
  ctx.unauth.length === 0 && ctx.ruledIn.length === 0 && ctx.recs.some((r) => r.ruling !== null && (r.placement === 'in' || r.placement === 'out'))
    ? { lane: 'nothing', action: { kind: 'none' } }
    : undefined;

// Lane 4: already asked. The entry a request would carry is the newest one in Jira.
const askedLane: LaneFn = ({ ctx }) => {
  const entryId = ctx.entry?.id ?? ctx.row?.entry;
  const nlCount = entryId === undefined ? 0 : ctx.reqs.filter((r) => neverLanded(r) && entryOf(r) === entryId).length;
  const asked = ctx.reqs.some((r) => {
    if (answered(ctx, r) || entryLess(r)) return false;
    if (entryId !== undefined && entryOf(r) === entryId) return !neverLanded(r) || nlCount > REFILE_CAP;
    return !neverLanded(r) && ctx.row !== undefined && newer(r.ts, ctx.row.ts);
  });
  return asked ? held('already-asked', 'rm-unresolved') : undefined;
};

// Lane 5: a signed decision names the key and no ruling cites it. Counted for the chief, never a request.
const operatorRecordLane: LaneFn = ({ input, ctx }) => {
  const dec = last(ctx.decisions);
  if (!dec || input.rulings.some((r) => r.key === ctx.key && r.authority.ref === dec.id)) return undefined;
  if (ctx.entry !== undefined && newer(ctx.entry.ts, dec.ts)) return held('operator-record', 'conflict');
  return { lane: 'operator-record', action: { kind: 'unfiled' } };
};

// Lane 6: closed, not delivered.
const closedLane: LaneFn = ({ ctx }) =>
  ctx.terminal === "Won't Do" || ctx.terminal === 'Duplicate' || ctx.terminal === 'Other' ? held('closed-undelivered', 'closed-undelivered') : undefined;

// Lane 7: fold. A fold never answers an out ruling or a ruling elsewhere, and only the current version folds.
const foldLane: LaneFn = ({ input, ctx }) => {
  const { current } = input;
  if (ctx.terminal !== 'Done' || !ctx.unauth.includes(current)) return undefined;
  const onCurrent = ctx.recs.find((r) => r.version === current);
  const elsewhere = ctx.recs.some((r) => r.version !== current && r.ruling !== null && r.placement === 'in');
  if (elsewhere || (onCurrent?.placement === 'out' && onCurrent.ruling !== null)) return undefined;
  const pr = input.mergedPr.get(ctx.key);
  if (pr === undefined) return { lane: 'fold', action: { kind: 'none' }, version: current };
  if (pr === null) return held('fold', 'done-no-pr', current);
  return { lane: 'fold', action: { kind: 'fold', pr }, version: current };
};

// Lane 8: open, only a gate row (a row with no kind). A counted row (override, rm-admit) clears a leak, except under an
// operator out ruling, which the reducer keeps: such a key, and any key whose unauthorized version carries a ruling, goes on to lane 12.
const gateLane: LaneFn = ({ input, ctx }) => {
  if (ctx.terminal !== null || ctx.unauth.length === 0 || ctx.ruledIn.length > 0) return undefined;
  if (ctx.recs.some((r) => ctx.unauth.includes(r.version) && r.ruling !== null)) return undefined;
  const newestRow = (v: string): Admission | undefined => input.admissions.filter((a) => a !== null && typeof a === 'object' && a.version === v && a.key === ctx.key).pop();
  const gated = ctx.unauth.every((v) => {
    const row = newestRow(v);
    return row !== undefined && row.kind === undefined && admits(row);
  });
  return gated ? held('gate-row', 'gate-row') : undefined;
};

// Lane 9: more than one declared version and no ruling placing the key in any of them.
const splitLane: LaneFn = ({ ctx }) =>
  ctx.recs.filter((r) => r.actual_member === true).length > 1 && !ctx.recs.some((r) => r.ruling !== null && r.placement === 'in') ? held('split', 'split') : undefined;

// Lanes 10 and 11 need the newest change bound to a machine row nobody has answered since. Two mismatches that disagree
// (two unauthorized lines, or two ruled-in lines) skip them and land in lane 12.
function boundRun(ctx: KeyCtx): { row: VersionWriteRow; earliest: VersionWriteRow } | undefined {
  const { row } = ctx;
  if (row === undefined || !isBound(ctx) || !MACHINE.has(row.mechanism)) return undefined;
  if (ctx.decisions.some((d) => newer(d.ts, row.ts)) || ctx.unauth.length >= 2 || ctx.ruledIn.length >= 2) return undefined;
  // The run of consecutive machine rows ending at the newest: merge-on-green replaces the set, then adds a released version back.
  let start = ctx.rows.length - 1;
  while (start > 0 && MACHINE.has(ctx.rows[start - 1]!.mechanism)) start--;
  return { row, earliest: ctx.rows[start]! };
}

// Lane 10: a machine write stripped a ruled version from an open key. The RM's ruling is reverted by a REVERSION; the operator's by one record.
const boundRuledLane: LaneFn = ({ input, ctx, declared }) => {
  const run = boundRun(ctx);
  if (!run || ctx.terminal !== null || ctx.ruledIn.length !== 1) return undefined;
  const vr = ctx.ruledIn[0]!;
  const declaredTo = run.row.to.filter((v) => declared.has(`${ctx.key}@${v}`));
  if (!run.earliest.from.includes(vr) || declaredTo.length > 1) return undefined;
  const rec = ctx.recs.find((r) => r.version === vr);
  if (authorityOf(input, rec) !== 'rm') return held('bound-ruled', 'ruled-displaced', vr);
  return {
    lane: 'bound-ruled', version: vr,
    action: { kind: 'request', verb: 'REVERSION', from: declaredTo[0] ?? null, to: vr, entry: run.row.entry, why: `${run.row.mechanism} removed ${vr} from ${ctx.key}, which ruling ${rec?.ruling} places there` },
  };
};

// Lane 11: a machine write put the key on a version no ruling places it on.
const boundLane: LaneFn = ({ input, ctx }) => {
  const run = boundRun(ctx);
  if (!run) return undefined;
  const { row } = run;
  if (ctx.ruledIn.length === 0 && ctx.unauth.length === 1 && authorityOf(input, ctx.recs.find((r) => r.version === ctx.unauth[0])) !== 'operator') {
    const v = ctx.unauth[0]!;
    return { lane: 'bound', version: v, action: { kind: 'request', verb: 'INTAKE', from: null, to: v, entry: row.entry, why: `${row.mechanism} put ${ctx.key} in ${v} and no ruling places it there` } };
  }
  if (ctx.displaced && ctx.unauth.length === 0 && ctx.ruledIn.length === 0) {
    const v = removedVersion(ctx);
    return { lane: 'bound', version: v, action: { kind: 'request', verb: 'INTAKE', from: null, to: v, entry: row.entry, why: `${row.mechanism} removed ${v} from ${ctx.key} and no ruling places it` } };
  }
  return undefined;
};

// Lane 12: held. A hand row is a choice someone made; anything else (UI, bulk script, an ineligible machine row) is unbound.
const heldLane: LaneFn = ({ ctx }) => held('held', isBound(ctx) && ctx.row!.mechanism !== 'rm-apply' && !MACHINE.has(ctx.row!.mechanism) ? 'hand' : 'unbound');

const LANES: LaneFn[] = [
  rmHeldLane, inFlightLane, nothingLane, askedLane, operatorRecordLane, closedLane, foldLane, gateLane, splitLane, boundRuledLane, boundLane, heldLane,
];

function firstLane(e: Env): Verdict {
  for (const lane of LANES) {
    const v = lane(e);
    if (v) return v;
  }
  return held('held', 'unbound');
}

const orderOf = (input: RepairInput): string[] => [...new Set(input.records.map((r) => r.version))];

// What a held class offers the operator (spec "A real decision still reaches the operator"). Offers only: nothing applies until pasted.
export function offerFor(c: Classification, input: RepairInput): Offer {
  const none: Offer = { op: null, from: null, to: null };
  if (c.action.kind !== 'held') return none;
  const { unauth, ruledIn } = leakVersions(input.leaks, c.key);
  const recs = input.records.filter((r) => r.key === c.key);
  switch (c.action.cls) {
    case 'split':
    case 'closed-undelivered':
      return unauth.includes(c.version) ? { op: 'remove', from: c.version, to: null } : none;
    case 'done-no-pr':
    case 'gate-row':
      return { op: 'keep', from: c.version, to: null };
    case 'ruled-displaced':
      return { op: 'add', from: null, to: c.version };
    case 'unbound':
    case 'hand': {
      const terminal = recs[0]?.terminal ?? null;
      const order = orderOf(input);
      if (ruledIn.length === 0 && unauth.length === 1 && recs.find((r) => r.version === unauth[0])?.ruling === null) {
        return { op: 'keep', from: unauth[0]!, to: null };
      }
      if (terminal === null && unauth.length === 0 && ruledIn.length === 1 && !recs.some((r) => r.actual_member === true)) {
        return { op: 'add', from: null, to: ruledIn[0]! };
      }
      if (terminal === 'Done' && unauth.length === 1 && ruledIn.length === 1 && order.indexOf(unauth[0]!) < order.indexOf(ruledIn[0]!)) {
        return { op: 'move', verb: 'INTAKE', from: ruledIn[0]!, to: unauth[0]!, note: `This overrules the operator's earlier ruling-in to ${ruledIn[0]}.` };
      }
      return none;
    }
    default:
      return none;
  }
}
