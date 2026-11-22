import type { Chain } from './ledger.js';
import { effectOn, terminalOf, type KeyRecord } from './reducer.js';
import { isSerious } from './operator-work.js';
import type { Authority, Baseline, Declaration, EventRow, IssueSnap, RulingRow } from './types.js';

export interface LinesDay {
  day: string;
  came_in: number;
  done: number;
  left: number;
  open: number;
  closed_undelivered: number;
  arrived: Record<string, number>;
  arrived_serious: number;
}

export type VersionLines =
  | { status: 'UNKNOWN'; reason: string }
  | {
    status: 'OK';
    as_of: string;
    days: LinesDay[];
    left: Array<{ key: string; day: string; authority: Authority['kind'] }>;
    done_undated: number;
    open_by_priority: Record<string, number>;
    oldest_untouched: { key: string; since: string; days: number } | null;
    unrecorded: { open: string[]; closed: string[] };
  };

export interface LinesInput {
  decl: Declaration;
  bases: Baseline[];
  effective: RulingRow[];
  events: Chain<EventRow>;
  rulingsBad: string[];
  operatorBad: string[];
  issues: Map<string, IssueSnap> | null;
  mirrorSync: string | null;
  records: KeyRecord[];
}

const DAY_MS = 86_400_000;

export const utcDay = (x: string): string => new Date(Date.parse(x)).toISOString().slice(0, 10);

const validDay = (x: string | null | undefined): string | null =>
  typeof x === 'string' && !Number.isNaN(Date.parse(x)) ? utcDay(x) : null;

const later = (a: string, b: string): string => (a > b ? a : b);

const RANK = { base: 0, ruling: 1, fold: 2 } as const;

interface Arrival { ts: number; rank: number; reason: string }
type Left = { day: string; authority: Authority['kind'] };
type Done = { day: string; delivered: boolean };

interface Arrivals {
  bases: Baseline[];
  first: Map<string, Arrival>;
  folds: Map<string, string>;
  ruledIn: Set<string>;
}

const OPERATOR_REASONS: Array<[string, string]> = [
  ['-delivered-follows-merge', 'delivered'], ['-blocker-pull', 'blocker'], ['-emergency', 'emergency'],
];

function rulingReason(r: RulingRow): string {
  const a = r.authority;
  if (a.kind === 'import') return 'import';
  if (a.kind === 'operator') return OPERATOR_REASONS.find(([end]) => (a.ref ?? '').endsWith(end))?.[1] ?? 'operator';
  if (r.ground.startsWith('door:')) return r.ground.split(':').slice(0, 2).join(':');
  return r.ground.split(':')[0] || 'judged';
}

function unknownReason(i: LinesInput): string | null {
  if (i.issues === null || i.mirrorSync === null) return 'the Jira mirror is unknown';
  const bad = i.rulingsBad[0] ?? i.events.bad[0] ?? i.operatorBad[0];
  return bad === undefined ? null : `a ledger chain has a bad line: ${bad}`;
}

function arrivalsOf(i: LinesInput, v: string): Arrivals {
  const first = new Map<string, Arrival>();
  const offer = (key: string, a: Arrival) => {
    const cur = first.get(key);
    if (!cur || a.ts < cur.ts || (a.ts === cur.ts && a.rank < cur.rank)) first.set(key, a);
  };
  const bases = i.bases.filter((b) => b.version === v);
  for (const b of bases) for (const key of b.keys) offer(key, { ts: Date.parse(b.ts), rank: RANK.base, reason: 'baseline' });
  const ruled = i.effective.filter((r) => effectOn(r.op, v) === 'in');
  for (const r of ruled) offer(r.key, { ts: Date.parse(r.ts), rank: RANK.ruling, reason: rulingReason(r) });
  const folds = new Map<string, string>();
  for (const e of i.events.verified) {
    if (e.kind !== 'fold' || e.to !== v) continue;
    offer(e.key, { ts: Date.parse(e.ts), rank: RANK.fold, reason: 'fold' });
    folds.set(e.key, e.ts);
  }
  return { bases, first, folds, ruledIn: new Set(ruled.map((r) => r.key)) };
}

function leftOf(i: LinesInput, v: string, a: Arrivals, cameDay: Map<string, string>, byId: Map<string, RulingRow>): Map<string, Left> {
  const recs = new Map(i.records.filter((r) => r.version === v).map((r) => [r.key, r]));
  const newest = a.bases.at(-1);
  const leftAt = new Map<string, Left>();
  for (const [key, came] of cameDay) {
    const rec = recs.get(key);
    const r = rec?.placement === 'out' && rec.ruling && rec.op && effectOn(rec.op, v) === 'out' ? byId.get(rec.ruling) : undefined;
    if (r) {
      leftAt.set(key, { day: later(came, utcDay(r.ts)), authority: r.authority.kind });
      continue;
    }
    if (!newest || newest.keys.includes(key) || a.ruledIn.has(key) || a.folds.has(key)) continue;
    const lastListed = a.bases.reduce((n, b, idx) => (b.keys.includes(key) ? idx : n), -1);
    const drop = a.bases[lastListed + 1];
    if (lastListed >= 0 && drop) leftAt.set(key, { day: later(came, utcDay(drop.ts)), authority: 'operator' });
  }
  return leftAt;
}

function doneOf(cameDay: Map<string, string>, leftAt: Map<string, Left>, issues: Map<string, IssueSnap>, folds: Map<string, string>,
  asOf: string): { doneAt: Map<string, Done>; undated: number } {
  let undated = 0;
  const doneAt = new Map<string, Done>();
  for (const [key, came] of cameDay) {
    const snap = issues.get(key);
    const terminal = terminalOf(snap);
    if (leftAt.has(key) || terminal === null) continue;
    const dated = validDay(snap?.resolved) ?? validDay(folds.get(key));
    if (dated === null) undated++;
    const d = dated === null ? asOf : later(came, dated);
    doneAt.set(key, { day: d > asOf ? asOf : d, delivered: terminal === 'Done' });
  }
  return { doneAt, undated };
}

function dayOf(d: string, a: Arrivals, cameDay: Map<string, string>, doneAt: Map<string, Done>, leftAt: Map<string, Left>,
  issues: Map<string, IssueSnap>): LinesDay {
  const arrived: Record<string, number> = {};
  let came = 0;
  let serious = 0;
  for (const [key, cd] of cameDay) {
    if (cd > d) continue;
    came++;
    if (cd !== d) continue;
    const why = a.first.get(key)?.reason ?? 'judged';
    arrived[why] = (arrived[why] ?? 0) + 1;
    if (isSerious(issues.get(key)?.priority ?? '')) serious++;
  }
  const done = [...doneAt.values()].filter((x) => x.day <= d);
  const left = [...leftAt.values()].filter((x) => x.day <= d).length;
  return {
    day: d, came_in: came, done: done.length, left, open: came - done.length - left,
    closed_undelivered: done.filter((x) => !x.delivered).length, arrived, arrived_serious: serious,
  };
}

function oldestOf(openKeys: string[], cameDay: Map<string, string>, issues: Map<string, IssueSnap>, asOf: string) {
  let oldest: { key: string; since: string; days: number } | null = null;
  for (const k of openKeys) {
    const i = issues.get(k);
    const since = cameDay.get(k) as string;
    if (!i || (i.statusCategory ?? i.status) !== 'To Do' || (oldest && oldest.since <= since)) continue;
    oldest = { key: k, since, days: Math.round((Date.parse(asOf) - Date.parse(since)) / DAY_MS) };
  }
  return oldest;
}

function versionLines(i: LinesInput, v: string, issues: Map<string, IssueSnap>, sync: string, byId: Map<string, RulingRow>): VersionLines {
  const a = arrivalsOf(i, v);
  const cameDay = new Map([...a.first].map(([key, x]) => [key, utcDay(new Date(x.ts).toISOString())]));
  const leftAt = leftOf(i, v, a, cameDay, byId);
  const asOf = [...cameDay.values(), ...[...leftAt.values()].map((l) => l.day)].reduce(later, utcDay(sync));
  const { doneAt, undated } = doneOf(cameDay, leftAt, issues, a.folds, asOf);

  const days: LinesDay[] = [];
  const start = [...cameDay.values()].sort()[0];
  if (start) {
    for (let t = Date.parse(start); t <= Date.parse(asOf); t += DAY_MS) {
      days.push(dayOf(new Date(t).toISOString().slice(0, 10), a, cameDay, doneAt, leftAt, issues));
    }
  }

  const openKeys = [...cameDay.keys()].filter((k) => !leftAt.has(k) && !doneAt.has(k)).sort();
  const open_by_priority: Record<string, number> = {};
  for (const k of openKeys) {
    const p = issues.get(k)?.priority || 'none';
    open_by_priority[p] = (open_by_priority[p] ?? 0) + 1;
  }
  const unrecorded = { open: [] as string[], closed: [] as string[] };
  for (const snap of [...issues.values()].sort((x, y) => x.key.localeCompare(y.key))) {
    if (!snap.fixVersions.includes(v) || cameDay.has(snap.key)) continue;
    (terminalOf(snap) === null ? unrecorded.open : unrecorded.closed).push(snap.key);
  }
  return {
    status: 'OK', as_of: asOf, days,
    left: [...leftAt].map(([key, l]) => ({ key, ...l })).sort((x, y) => x.day.localeCompare(y.day) || x.key.localeCompare(y.key)),
    done_undated: undated, open_by_priority, oldest_untouched: oldestOf(openKeys, cameDay, issues, asOf), unrecorded,
  };
}

export function linesOf(i: LinesInput): Record<string, VersionLines> {
  const out: Record<string, VersionLines> = {};
  const why = unknownReason(i);
  const byId = new Map(i.effective.map((r) => [r.id, r]));
  for (const v of i.decl.versions) {
    out[v] = why !== null || i.issues === null || i.mirrorSync === null
      ? { status: 'UNKNOWN', reason: why ?? 'the Jira mirror is unknown' }
      : versionLines(i, v, i.issues, i.mirrorSync, byId);
  }
  return out;
}
