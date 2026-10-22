import { canonical, type Chain } from './ledger.js';
import type { Baseline, Declaration, EventRow, IssueSnap, OpKind, OperatorRow, RulingRow } from './types.js';

// The one reducer (design §5.3): every caller reads effective state from here,
// never from the ledger's history.

export type InputState = 'FRESH' | 'STALE' | 'UNKNOWN';
type Placement = 'in' | 'out' | 'pending' | 'unknown';

export interface KeyRecord {
  key: string;
  version: string;
  obligation: 'baseline' | 'admitted' | 'none';
  placement: Placement;
  ruling: string | null;
  op: RulingRow['op'] | null;
  expected_member: boolean | null;
  actual_member: boolean | 'unknown';
  bookkeeping: string | null;
  emergency: boolean;
  discharged: boolean;
  terminal: 'Done' | "Won't Do" | 'Duplicate' | null;
}

export interface Burndown {
  baseline: number;
  baseline_open: number;
  admitted_open: number;
  emergency_open: number;
  deferred_out: number;
}

export interface ReleaseState {
  status: 'OK' | 'UNKNOWN';
  release: string;
  mode: Declaration['mode'] | null;
  versions: string[];
  inputs: { mirror: InputState; ledger: InputState; operator: InputState; events: InputState };
  records: KeyRecord[];
  leaks: { unauthorized: string[]; ruled_in_non_member: string[] };
  integrity: string[];
  burndown: Record<string, Burndown>;
  trend: Record<string, Record<string, number>>;
}

export interface ReduceInput {
  decl: Declaration;
  baselines: Baseline[];
  rulings: Chain<RulingRow>;
  operator: Chain<OperatorRow>;
  events: Chain<EventRow>;
  issues: Map<string, IssueSnap> | null;
  mirrorSync: string | null;
}

export const baselineId = (b: Pick<Baseline, 'version' | 'gen'>): string => `baseline-${b.version}-g${b.gen}`;

// The placement a ruling gives (key, v), or null when it does not touch v.
export function effectOn(op: RulingRow['op'], v: string): 'in' | 'out' | null {
  switch (op.kind) {
    case 'add': return op.to_v === v ? 'in' : null;
    case 'remove': return op.from_v === v ? 'out' : null;
    case 'move': return op.to_v === v ? 'in' : op.from_v === v ? 'out' : null;
    case 'keep': return op.from_v === v ? 'in' : null;
    case 'discharge': return op.to_v === v ? 'in' : null;
    default: return null;
  }
}

export function terminalOf(i: IssueSnap | undefined): KeyRecord['terminal'] {
  if (!i) return null;
  const s = `${i.status} ${i.resolution ?? ''}`;
  if (/won'?t do/i.test(s)) return "Won't Do";
  if (/duplicate/i.test(s)) return 'Duplicate';
  return i.status === 'Done' ? 'Done' : null;
}

const core = (r: RulingRow) => canonical({ key: r.key, verb: r.verb, outcome: r.outcome, op: r.op, supersedes: r.supersedes, authority: r.authority });

export const unknownState = (release: string, why: string): ReleaseState => ({
  status: 'UNKNOWN', release, mode: null, versions: [],
  inputs: { mirror: 'UNKNOWN', ledger: 'UNKNOWN', operator: 'UNKNOWN', events: 'UNKNOWN' },
  records: [], leaks: { unauthorized: [], ruled_in_non_member: [] }, integrity: [why], burndown: {}, trend: {},
});

interface Partition {
  effective: Map<string, RulingRow>;
  pendingIntents: RulingRow[];
  superseded: Map<string, Set<string>>;
  unknownKeys: Set<string>;
}

// Authority scope (§4): an operator ruling must match its record exactly.
export function scopeOk(r: Pick<RulingRow, 'authority' | 'key' | 'op'>, ops: Map<string, OperatorRow>, current: string): boolean {
  if (r.authority.kind !== 'operator') return true;
  const o = r.authority.ref ? ops.get(r.authority.ref) : undefined;
  if (!o) return false;
  if (o.kind === 'emergency') return r.op.kind === 'add' && r.op.to_v === current;
  return o.kind === 'decision' && (o.keys ?? []).includes(r.key) && o.op === r.op.kind
    && (o.from_v ?? null) === r.op.from_v && (o.to_v ?? null) === r.op.to_v;
}

function partition(inp: ReduceInput, integrity: string[]): Partition {
  const unknownKeys = new Set(inp.rulings.badKeys);
  const ops = new Map(inp.operator.verified.map((o) => [o.id, o]));
  const intents = new Map<string, RulingRow>();
  const effective = new Map<string, RulingRow>();
  const voided = new Set<string>();
  for (const r of inp.rulings.verified) {
    if (!scopeOk(r, ops, inp.decl.current)) {
      unknownKeys.add(r.key);
      integrity.push(`${r.id}: authority ${r.authority.ref ?? '(none)'} does not cover ${r.key} ${r.op.kind} ${r.op.from_v}→${r.op.to_v}`);
      continue;
    }
    const first = intents.get(r.id) ?? effective.get(r.id);
    if (first && core(first) !== core(r)) {
      unknownKeys.add(r.key);
      integrity.push(`${r.id}: phase ${r.phase} disagrees with its intent`);
      continue;
    }
    if (r.phase === 'intent') intents.set(r.id, r);
    else if (r.phase === 'void') voided.add(r.id);
    else if (!effective.has(r.id)) effective.set(r.id, r);
  }
  // A ruling supersedes only for its own key: moving one baseline key out
  // leaves the rest of that baseline in. A ruling that changes nothing
  // supersedes nothing.
  const superseded = new Map<string, Set<string>>();
  for (const r of effective.values()) {
    if (r.op.kind === 'none') continue;
    const set = superseded.get(r.key) ?? new Set<string>();
    for (const id of r.supersedes) set.add(id);
    superseded.set(r.key, set);
  }
  return {
    effective,
    pendingIntents: [...intents.values()].filter((r) => !effective.has(r.id) && !voided.has(r.id)),
    superseded,
    unknownKeys,
  };
}

// The mirror is UNKNOWN without a sync, STALE when an event postdates it (those keys read unknown).
function mirrorOf(inp: ReduceInput): { mirror: InputState; staleKeys: Set<string> } {
  const staleKeys = new Set<string>();
  if (inp.issues === null || inp.mirrorSync === null) return { mirror: 'UNKNOWN', staleKeys };
  const sync = Date.parse(inp.mirrorSync);
  for (const e of inp.events.verified) if (Date.parse(e.ts) > sync) staleKeys.add(e.key);
  return { mirror: staleKeys.size ? 'STALE' : 'FRESH', staleKeys };
}

interface VersionCtx {
  inp: ReduceInput;
  p: Partition;
  v: string;
  baseKeys: Set<string>;
  bId: string | null;
  bTs: number;
  staleKeys: Set<string>;
  integrity: string[];
}

function universeOf(c: VersionCtx): string[] {
  const { inp, p, v } = c;
  const universe = new Set<string>(c.baseKeys);
  for (const r of [...p.effective.values(), ...p.pendingIntents]) if (effectOn(r.op, v)) universe.add(r.key);
  for (const r of inp.rulings.rows) if (p.unknownKeys.has(r.key) && effectOn(r.op, v)) universe.add(r.key);
  for (const i of inp.issues?.values() ?? []) if (i.fixVersions.includes(v)) universe.add(i.key);
  return [...universe].sort();
}

interface Live { id: string; effect: 'in' | 'out'; r: RulingRow | null }

function placementOf(c: VersionCtx, key: string, live: Live[]): Placement {
  if (c.p.unknownKeys.has(key)) return 'unknown';
  if (live.length > 1) {
    c.integrity.push(`${key}@${c.v}: two live rulings (${live.map((l) => l.id).join(', ')})`);
    return 'unknown';
  }
  if (c.p.pendingIntents.some((r) => r.key === key && effectOn(r.op, c.v))) return 'pending';
  return live[0]?.effect ?? 'out';
}

function bookkeepingOf(events: EventRow[], key: string, v: string, terminal: KeyRecord['terminal']): string | null {
  const fold = [...events].reverse().find((e) => e.key === key && (e.kind === 'fold' || e.kind === 'reopen'));
  return fold?.kind === 'fold' && fold.to === v && terminal === 'Done' ? `fold:${fold.pr}` : null;
}

function recordFor(c: VersionCtx, key: string): { rec: KeyRecord; isIn: boolean; everOut: boolean } {
  const { inp, p, v } = c;
  const issue = inp.issues?.get(key);
  const gone = p.superseded.get(key) ?? new Set<string>();
  // The newest baseline is the operator's latest word on the keys it lists: a
  // ruling on such a key that predates it no longer counts.
  const mine = [...p.effective.values()].filter((r) => r.key === key && effectOn(r.op, v)
    && !(c.baseKeys.has(key) && Date.parse(r.ts) < c.bTs));
  const live: Live[] = mine
    .filter((r) => !gone.has(r.id))
    .map((r) => ({ id: r.id, effect: effectOn(r.op, v) as 'in' | 'out', r }));
  if (c.bId && c.baseKeys.has(key) && !gone.has(c.bId)) live.push({ id: c.bId, effect: 'in', r: null });
  const everOut = mine.some((r) => effectOn(r.op, v) === 'out');
  const placement = placementOf(c, key, live);
  const settled = live.length === 1 ? live[0] : null;
  const known = placement !== 'unknown';
  const isIn = placement === 'in' || (placement === 'pending' && settled?.effect === 'in');
  const terminal = terminalOf(issue);
  const rec: KeyRecord = {
    key, version: v,
    obligation: isIn ? (c.baseKeys.has(key) && !everOut ? 'baseline' : 'admitted') : 'none',
    placement,
    ruling: known ? settled?.id ?? null : null,
    op: known ? settled?.r?.op ?? null : null,
    expected_member: placement === 'in' ? true : placement === 'out' ? false : null,
    actual_member: !issue || c.staleKeys.has(key) ? 'unknown' : issue.fixVersions.includes(v),
    bookkeeping: bookkeepingOf(inp.events.verified, key, v, terminal),
    emergency: settled?.r?.authority.ref === `O-${inp.decl.release}-emergency`,
    discharged: settled?.r?.op.kind === 'discharge',
    terminal,
  };
  return { rec, isIn, everOut };
}

type Leaks = ReleaseState['leaks'];

function tally(c: VersionCtx, out: { rec: KeyRecord; isIn: boolean; everOut: boolean }, bd: Burndown, leaks: Leaks): void {
  const { rec, isIn, everOut } = out;
  const at = `${rec.key}@${c.v}`;
  if (c.inp.issues && !c.inp.issues.has(rec.key) && rec.expected_member === true) c.integrity.push(`${at}: not in the Jira mirror`);
  if (rec.expected_member !== null && rec.actual_member !== 'unknown') {
    if (rec.actual_member && !rec.expected_member && !rec.bookkeeping) leaks.unauthorized.push(at);
    if (!rec.actual_member && rec.expected_member) leaks.ruled_in_non_member.push(at);
  }
  const open = isIn && rec.terminal === null;
  if (open && rec.obligation === 'baseline') bd.baseline_open++;
  if (open && rec.obligation === 'admitted') bd.admitted_open++;
  if (open && rec.emergency) bd.emergency_open++;
  if (c.baseKeys.has(rec.key) && everOut && !isIn) bd.deferred_out++;
}

function trendOf(decl: Declaration, events: EventRow[]): ReleaseState['trend'] {
  const trend: ReleaseState['trend'] = {};
  for (const e of events) {
    if (!decl.versions.some((v) => v === e.from || v === e.to) || e.readback === 'mismatch') continue;
    const day = e.ts.slice(0, 10);
    trend[day] ??= {};
    trend[day][e.kind] = (trend[day][e.kind] ?? 0) + 1;
  }
  return trend;
}

export function reduce(inp: ReduceInput): ReleaseState {
  const { decl } = inp;
  if (inp.rulings.unparseable || inp.operator.unparseable || inp.events.unparseable) {
    return unknownState(decl.release, 'a ledger file has an unparseable line');
  }
  const integrity = [...inp.rulings.bad, ...inp.operator.bad, ...inp.events.bad];
  const p = partition(inp, integrity);
  const { mirror, staleKeys } = mirrorOf(inp);
  const records: KeyRecord[] = [];
  const leaks: Leaks = { unauthorized: [], ruled_in_non_member: [] };
  const burndown: Record<string, Burndown> = {};
  for (const v of decl.versions) {
    const base = inp.baselines.find((b) => b.version === v);
    const c: VersionCtx = { inp, p, v, baseKeys: new Set(base?.keys ?? []), bId: base ? baselineId(base) : null, bTs: base ? Date.parse(base.ts) : 0, staleKeys, integrity };
    const bd: Burndown = { baseline: c.baseKeys.size, baseline_open: 0, admitted_open: 0, emergency_open: 0, deferred_out: 0 };
    for (const key of universeOf(c)) {
      const out = recordFor(c, key);
      records.push(out.rec);
      tally(c, out, bd, leaks);
    }
    burndown[v] = bd;
  }
  const fresh = (bad: string[]): InputState => (bad.length ? 'UNKNOWN' : 'FRESH');
  return {
    status: 'OK', release: decl.release, mode: decl.mode, versions: decl.versions,
    inputs: { mirror, ledger: fresh(inp.rulings.bad), operator: fresh(inp.operator.bad), events: fresh(inp.events.bad) },
    records, leaks, integrity, burndown, trend: trendOf(decl, inp.events.verified),
  };
}

export const recordOf = (s: ReleaseState, key: string, v: string): KeyRecord | undefined =>
  s.records.find((r) => r.key === key && r.version === v);

// Rule 7: yes only when the effective ruling for the target (or the source,
// on a removal) names exactly this kind and these versions.
export function authorizes(s: ReleaseState, key: string, from_v: string | null, to_v: string | null, kind: OpKind): boolean {
  if (s.status !== 'OK') return false;
  const v = to_v ?? from_v;
  if (!v) return false;
  const rec = recordOf(s, key, v);
  if (!rec?.op || (rec.placement !== 'in' && rec.placement !== 'out')) return false;
  return rec.op.kind === kind && rec.op.from_v === from_v && rec.op.to_v === to_v;
}
