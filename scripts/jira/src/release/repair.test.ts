import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { chainLine, parseChain, sha256, GENESIS } from './ledger.js';
import { reduce } from './reducer.js';
import type { Admission } from '../commands/admissions-ledger.js';
import type { EventRow, IssueSnap, OperatorRow, RequestRow, RulingRow } from './types.js';
import type { VersionWriteRow } from './version-writes.js';
import { classify, offerFor, type Classification, type RepairInput } from './repair.js';

// The classifier is pure; every world below goes through the real reduce() so the leak lines are the reducer's.

const MAC = Buffer.alloc(32, 7);
function chain<T>(rows: object[]) {
  let head = GENESIS;
  let text = '';
  for (const r of rows) {
    const line = chainLine(head, MAC, r as Record<string, unknown>);
    text += `${line}\n`;
    head = sha256(line);
  }
  return parseChain<T>(text, MAC);
}

const at = (min: number): string => new Date(Date.UTC(2026, 10, 2, 10, min)).toISOString();
const SYNC = '2026-11-02T12:00:00.000Z';
const V2 = ['v1.1.3', 'v1.1.4'];

const issue = (key: string, fixVersions: string[], extra: Partial<IssueSnap> = {}): IssueSnap =>
  ({ key, status: 'To Do', type: 'Task', priority: 'Medium', fixVersions, resolution: null, ...extra });
const done = (key: string, fixVersions: string[], resolution: string | null = 'Done'): IssueSnap =>
  issue(key, fixVersions, { status: 'Closed', statusCategory: 'Done', resolution });

const decision = (id: string, keys: string[], op: string, from_v: string | null, to_v: string | null, ts: string): OperatorRow =>
  ({ id, kind: 'decision', ts, decision: 'd', keys, op, from_v, to_v, verbatim: 'v' });
const spec = (id: string, keys: string[], ts: string): OperatorRow =>
  ({ id, kind: 'spec', ts, decision: 'd', keys, verbatim: 'v' });

// auth 'rm' = the release manager's ruling; an O- id = an operator ruling under that record.
function ruling(id: string, key: string, kind: 'add' | 'remove' | 'move' | 'keep', from_v: string | null, to_v: string | null,
  auth: string, ts = at(0)): RulingRow {
  return {
    id, epoch: 1, req: `Q-${id}`, ts, verb: 'INTAKE', key, op: { kind, from_v, to_v }, outcome: 'ADMIT', class: 'current',
    sector: 's', ground: 'g', reason: 'r', supersedes: [],
    authority: auth === 'rm' ? { kind: 'rm', ref: null } : { kind: 'operator', ref: auth }, phase: 'applied',
  };
}

const req = (id: string, key: string, state: string, extra: Partial<RequestRow> = {}): RequestRow => ({
  req: id, ts: at(10), from: 'repair', verb: 'INTAKE', key, from_v: null, to_v: 'v1.1.4', why: 'w',
  evidence: { rule: 'version-repair', entry: '100' }, state, ...extra,
});
const neverLanded = (id: string, key: string, entry = '100', extra: Partial<RequestRow> = {}): RequestRow =>
  req(id, key, 'withdrawn:repair', { reason: 'never-landed', evidence: { rule: 'version-repair', entry }, ...extra });

const jr = (key: string, mechanism: string, from: string[], to: string[], entry: string, ts = at(5)): VersionWriteRow =>
  ({ ts, key, from, to, mechanism, entry });

interface World {
  versions?: string[];
  issues?: IssueSnap[];
  rulings?: RulingRow[];
  operator?: OperatorRow[];
  events?: EventRow[];
  admissions?: Admission[];
  requests?: RequestRow[];
  journal?: VersionWriteRow[];
  entries?: Record<string, { id: string; ts: string }>;
  prs?: Record<string, number | null>;
  missing?: string[];
}

function build(w: World) {
  const versions = w.versions ?? V2;
  const decl = { project: 'HIMMEL', release: 'R1', versions, current: versions[0]!, mode: 'observe' as const, decision: '1', ts: at(0) };
  const operator = chain<OperatorRow>(w.operator ?? []);
  const rulings = chain<RulingRow>(w.rulings ?? []);
  const state = reduce({
    decl, baselines: [], rulings, operator, events: chain<EventRow>(w.events ?? []),
    issues: new Map((w.issues ?? []).map((i) => [i.key, i])), mirrorSync: SYNC, admissions: w.admissions ?? [],
  });
  const input: RepairInput = {
    records: state.records, leaks: state.leaks, current: decl.current, versions, operator: operator.verified, rulings: rulings.verified,
    admissions: w.admissions ?? [], requests: w.requests ?? [], journal: w.journal ?? [],
    newestEntry: new Map(Object.entries(w.entries ?? {})), mergedPr: new Map(Object.entries(w.prs ?? {})),
    missingKeys: new Set(w.missing ?? []),
  };
  return { state, input, out: classify(input) };
}

// ticket keys used as object keys below, named once so the map literals stay plain
const K3084 = 'HIMMEL-3084';
const K6691 = 'HIMMEL-6691';
const K7044 = 'HIMMEL-7044';
const K7804 = 'HIMMEL-7804';
const K8231 = 'HIMMEL-8231';

const FIX = fileURLToPath(new URL('./fixtures/repair/', import.meta.url));
interface Fixture { key: string; journal: VersionWriteRow[]; changelog: Array<{ id: string; created: string; items: Array<{ field: string }> }> }
function fixture(key: string): { newest: { id: string; ts: string }; journal: VersionWriteRow[] } {
  const f = JSON.parse(readFileSync(`${FIX}${key}.json`, 'utf8')) as Fixture;
  const fv = f.changelog.filter((e) => e.items.some((i) => i.field === 'Fix Version'));
  const last = fv.reduce((a, b) => (BigInt(b.id) > BigInt(a.id) ? b : a));
  return { newest: { id: last.id, ts: last.created }, journal: f.journal };
}

function one(out: Classification[], key: string): Classification {
  const m = out.filter((c) => c.key === key);
  expect(m, `${key} appears once`).toHaveLength(1);
  return m[0]!;
}
const requests = (out: Classification[]) => out.filter((c) => c.action.kind === 'request');

// A bound machine write: an open K-1 on v1.1.4 with no ruling, journalled as create-residual, entry 100 the newest.
const machineWrite = (over: World = {}): World => ({
  issues: [issue('K-1', ['v1.1.4'])], journal: [jr('K-1', 'create-residual', [], ['v1.1.4'], '100')],
  entries: { 'K-1': { id: '100', ts: at(5) } }, ...over,
});

// The Done-and-ruled-later shape: Done in v1.1.3, an operator ruled it into v1.1.4.
const O7804 = decision('O-R1-0001', ['HIMMEL-7804'], 'add', null, 'v1.1.4', '2026-10-27T05:00:00.000Z');
const doneRuledLater = (key: string, over: World = {}): World => ({
  issues: [done(key, ['v1.1.3'])], operator: [{ ...O7804, keys: [key] }],
  rulings: [ruling('R-1', key, 'add', null, 'v1.1.4', 'O-R1-0001', '2026-10-27T05:30:00.000Z')], ...over,
});

describe('test-version-repair', () => {
  it('operator edit files nothing', () => {
    const edit = build({ issues: [issue('K-1', ['v1.1.4'])], entries: { 'K-1': { id: '200', ts: at(5) } } });
    expect(requests(edit.out)).toEqual([]);
    expect(one(edit.out, 'K-1').action).toEqual({ kind: 'held', cls: 'unbound' });
    const signed = build({ issues: [issue('K-1', ['v1.1.4'])], operator: [decision('O-R1-0001', ['K-1'], 'keep', 'v1.1.4', null, at(1))] });
    expect(requests(signed.out)).toEqual([]);
    expect(one(signed.out, 'K-1')).toMatchObject({ lane: 'operator-record', action: { kind: 'unfiled' } });
  });

  it('hand row files nothing', () => {
    const w = build(machineWrite({ journal: [jr('K-1', 'hand', [], ['v1.1.4'], '100')] }));
    expect(requests(w.out)).toEqual([]);
    expect(one(w.out, 'K-1')).toMatchObject({ lane: 'held', action: { kind: 'held', cls: 'hand' } });
  });

  it('unbound edit classifies as held unbound', () => {
    const moved = build(machineWrite({ entries: { 'K-1': { id: '101', ts: at(8) } } }));
    expect(one(moved.out, 'K-1')).toMatchObject({ lane: 'held', action: { kind: 'held', cls: 'unbound' } });
    const none = build({ issues: [issue('K-1', ['v1.1.4'])] });
    expect(one(none.out, 'K-1')).toMatchObject({ lane: 'held', action: { kind: 'held', cls: 'unbound' } });
  });

  it('bound machine write files an INTAKE with its entry', () => {
    const w = build(machineWrite());
    expect(one(w.out, 'K-1')).toEqual({
      key: 'K-1', version: 'v1.1.4', lane: 'bound',
      action: { kind: 'request', verb: 'INTAKE', from: null, to: 'v1.1.4', entry: '100', why: expect.stringContaining('create-residual') },
    });
  });

  it('bound displacement with to none files an INTAKE', () => {
    const w = build({ issues: [issue('K-2', [])], journal: [jr('K-2', 'displace-residual', ['v1.1.4'], [], '300')], entries: { 'K-2': { id: '300', ts: at(5) } } });
    expect(one(w.out, 'K-2')).toMatchObject({ lane: 'bound', action: { kind: 'request', verb: 'INTAKE', from: null, to: 'v1.1.4', entry: '300' } });
    const unbound = build({ issues: [issue('K-2', [])], journal: [jr('K-2', 'displace-residual', ['v1.1.4'], [], '300')], entries: { 'K-2': { id: '301', ts: at(8) } } });
    expect(unbound.out).toEqual([]);
  });

  it('a displacement from a version outside the release is not its mismatch', () => {
    const w = build({ issues: [issue('K-2', [])], journal: [jr('K-2', 'displace-residual', ['v0.0.1'], [], '300')], entries: { 'K-2': { id: '300', ts: at(5) } } });
    expect(w.out).toEqual([]);
  });

  it('no duplicate for a (key, entry) in any request state', () => {
    const lanes: Record<string, string> = {
      open: 'in-flight', 'claimed:9': 'in-flight', held: 'rm-held', 'ruled:R-1': 'already-asked',
      'withdrawn:console': 'already-asked', refused: 'already-asked',
    };
    for (const [state, lane] of Object.entries(lanes)) {
      const w = build(machineWrite({ requests: [req('Q-1', 'K-1', state)] }));
      expect(requests(w.out), state).toEqual([]);
      expect(one(w.out, 'K-1').lane, state).toBe(lane);
    }
  });

  it('ruled with no effect goes to rm-unresolved', () => {
    const w = build(machineWrite({ requests: [req('Q-1', 'K-1', 'ruled:R-9')] }));
    expect(one(w.out, 'K-1')).toMatchObject({ lane: 'already-asked', action: { kind: 'held', cls: 'rm-unresolved' } });
  });

  it('a create-filed request newer than the row counts as asked', () => {
    const w = build(machineWrite({ requests: [req('Q-1', 'K-1', 'ruled:R-2', { evidence: {} })] }));
    expect(one(w.out, 'K-1')).toMatchObject({ lane: 'already-asked', action: { kind: 'held', cls: 'rm-unresolved' } });
    const older = build(machineWrite({ requests: [req('Q-1', 'K-1', 'ruled:R-2', { evidence: {}, ts: at(2) })] }));
    expect(one(older.out, 'K-1').lane).toBe('bound');
  });

  it('create-filed request newer than a displacement row counts as asked', () => {
    const w = build({
      issues: [issue('K-2', [])], journal: [jr('K-2', 'displace-residual', ['v1.1.4'], [], '300')], entries: { 'K-2': { id: '300', ts: at(5) } },
      requests: [req('Q-1', 'K-2', 'ruled:R-2', { evidence: {} })],
    });
    expect(one(w.out, 'K-2')).toMatchObject({ lane: 'already-asked', action: { kind: 'held', cls: 'rm-unresolved' } });
  });

  it('lanes count each key once', () => {
    const w = build(doneRuledLater('HIMMEL-7804', { entries: { [K7804]: fixture('HIMMEL-7804').newest } }));
    expect(w.state.leaks).toEqual({ unauthorized: ['HIMMEL-7804@v1.1.3'], ruled_in_non_member: ['HIMMEL-7804@v1.1.4'] });
    expect(w.out).toHaveLength(1);
    expect(one(w.out, 'HIMMEL-7804')).toMatchObject({ lane: 'held', action: { kind: 'held', cls: 'unbound' } });
  });

  it('every mismatch sits in one lane, anything else only in lane 2', () => {
    const w = build({
      issues: [issue('K-1', ['v1.1.4']), done('K-2', ['v1.1.3']), issue('K-3', ['v1.1.3']), issue('K-4', ['v1.1.3']), issue('K-5', ['v1.1.3'])],
      rulings: [
        ruling('R-3', 'K-3', 'add', null, 'v1.1.3', 'rm'), // agrees: no leak
        ruling('R-4', 'K-4', 'add', null, 'v1.1.3', 'rm', at(0)), // pending below
        { ...ruling('R-5', 'K-5', 'add', null, 'v1.1.3', 'rm'), phase: 'intent' as const },
      ],
      events: [{ ts: '2026-11-02T13:00:00.000Z', kind: 'ruled', key: 'K-4', from: null, to: 'v1.1.3' }],
      prs: { 'K-2': 55 },
    });
    const keys = w.out.map((c) => c.key);
    expect(new Set(keys).size).toBe(keys.length);
    const mismatch = new Set([...w.state.leaks.unauthorized, ...w.state.leaks.ruled_in_non_member].map((l) => l.split('@')[0]));
    expect(mismatch).toEqual(new Set(['K-1', 'K-2']));
    expect(one(w.out, 'K-1').lane).not.toBe('in-flight');
    expect(one(w.out, 'K-2')).toMatchObject({ lane: 'fold', action: { kind: 'fold', pr: 55 } });
    // K-4 reads stale (an event newer than the sync) and K-5 pending: lane 2 only, no output. K-3 agrees and is absent.
    expect(one(w.out, 'K-4')).toMatchObject({ lane: 'in-flight', action: { kind: 'none' } });
    expect(one(w.out, 'K-5')).toMatchObject({ lane: 'in-flight', action: { kind: 'none' } });
    expect(keys).not.toContain('K-3');
  });

  it('ruled key flagged on another version falls through lane 3', () => {
    const w = build({ issues: [issue('K-1', ['v1.1.3'])], rulings: [ruling('R-1', 'K-1', 'add', null, 'v1.1.4', 'rm')] });
    expect(w.state.leaks.unauthorized).toEqual(['K-1@v1.1.3']);
    expect(one(w.out, 'K-1').lane).not.toBe('nothing');
  });

  it('a key the mirror lacks goes in flight even when its ruling is clean', () => {
    const w = build({ issues: [issue('K-1', ['v1.1.3'])], rulings: [ruling('R-1', 'K-1', 'add', null, 'v1.1.3', 'rm')], missing: ['K-1'] });
    expect(one(w.out, 'K-1')).toMatchObject({ lane: 'in-flight', action: { kind: 'none' } });
  });

  it('missing mirror key goes in flight', () => {
    const w = build({ issues: [], rulings: [ruling('R-1', 'K-9', 'add', null, 'v1.1.3', 'rm')], missing: ['K-9'] });
    expect(one(w.out, 'K-9')).toMatchObject({ lane: 'in-flight', action: { kind: 'none' } });
  });

  it('multi-version stale key sits in lane 2 only', () => {
    const w = build({
      issues: [issue('K-1', ['v1.1.3'])],
      rulings: [{ ...ruling('R-1', 'K-1', 'add', null, 'v1.1.4', 'rm'), phase: 'intent' as const }],
    });
    expect(w.state.leaks.unauthorized).toEqual(['K-1@v1.1.3']);
    expect(w.out).toHaveLength(1);
    expect(one(w.out, 'K-1')).toMatchObject({ lane: 'in-flight', action: { kind: 'none' } });
  });

  // K-3 is ruled into v1.1.4, was on v1.1.4, then merge-stamp replaced its set with v1.1.3 and added a released v1.0.0 back.
  const stripped = (auth: string, over: World = {}): World => ({
    issues: [issue('K-3', ['v1.1.3', 'v1.0.0'])],
    operator: auth === 'rm' ? [] : [decision(auth, ['K-3'], 'add', null, 'v1.1.4', at(1))],
    rulings: [ruling('R-1', 'K-3', 'add', null, 'v1.1.4', auth, at(1))],
    journal: [jr('K-3', 'merge-stamp', ['v1.1.4'], ['v1.1.3'], '400', at(5)), jr('K-3', 'merge-stamp', ['v1.1.3'], ['v1.1.3', 'v1.0.0'], '401', at(6))],
    entries: { 'K-3': { id: '401', ts: at(6) } }, ...over,
  });

  it('lane 10 test reads the run of machine rows', () => {
    const w = build(stripped('rm'));
    expect(w.state.leaks).toEqual({ unauthorized: ['K-3@v1.1.3'], ruled_in_non_member: ['K-3@v1.1.4'] });
    expect(one(w.out, 'K-3')).toMatchObject({ lane: 'bound-ruled', action: { kind: 'request', verb: 'REVERSION', from: 'v1.1.3', to: 'v1.1.4', entry: '401' } });
  });

  it('machine row made ineligible by a newer ruling labels unbound', () => {
    const eligible = build(stripped('O-R1-0001', { operator: [decision('O-R1-0001', ['K-3'], 'add', null, 'v1.1.4', at(1))] }));
    expect(one(eligible.out, 'K-3')).toMatchObject({ lane: 'bound-ruled', action: { kind: 'held', cls: 'ruled-displaced' } });
    const newer = build(stripped('O-R1-0001', { operator: [decision('O-R1-0001', ['K-3'], 'add', null, 'v1.1.4', at(20))] }));
    expect(one(newer.out, 'K-3')).toMatchObject({ lane: 'held', action: { kind: 'held', cls: 'unbound' } });
  });

  it('newest rm-apply row labels unbound', () => {
    const w = build(machineWrite({ journal: [jr('K-1', 'create-residual', [], ['v1.1.4'], '99', at(4)), jr('K-1', 'rm-apply', [], ['v1.1.4'], '100')] }));
    expect(requests(w.out)).toEqual([]);
    expect(one(w.out, 'K-1')).toMatchObject({ lane: 'held', action: { kind: 'held', cls: 'unbound' } });
  });

  it('lane 7 reads terminal Done', () => {
    const w = build({ issues: [done('K-1', ['v1.1.3'], 'Obsolete')], prs: { 'K-1': 77 } });
    expect(one(w.out, 'K-1')).toMatchObject({ lane: 'closed-undelivered', action: { kind: 'held', cls: 'closed-undelivered' } });
  });

  it('lane 10 REVERSION carries from, to and why', () => {
    const w = build(stripped('rm'));
    const a = one(w.out, 'K-3').action;
    expect(a).toMatchObject({ kind: 'request', verb: 'REVERSION', from: 'v1.1.3', to: 'v1.1.4' });
    expect(a.kind === 'request' && a.why.length > 0 && !a.why.includes('\n')).toBe(true);
    const gone = build({
      issues: [issue('HIMMEL-8231', [])], rulings: [ruling('R-1', 'HIMMEL-8231', 'add', null, 'v1.1.4', 'rm', '2026-10-30T10:00:00.000Z')],
      journal: [jr('HIMMEL-8231', 'displace-residual', ['v1.1.4'], [], '85466', '2026-11-01T21:13:42.360Z')],
      entries: { [K8231]: fixture('HIMMEL-8231').newest },
    });
    expect(one(gone.out, 'HIMMEL-8231')).toMatchObject({ lane: 'bound-ruled', action: { kind: 'request', verb: 'REVERSION', from: null, to: 'v1.1.4', entry: '85466' } });
  });

  it('two declared versions in the row\'s to file no REVERSION', () => {
    const three = ['v1', 'v2', 'v3'];
    const ruled = build({
      versions: three, issues: [issue('K-1', ['v1', 'v2'])],
      rulings: [ruling('R-1', 'K-1', 'add', null, 'v2', 'rm'), ruling('R-2', 'K-1', 'add', null, 'v3', 'rm')],
      journal: [jr('K-1', 'merge-stamp', ['v3'], ['v1', 'v2'], '600')], entries: { 'K-1': { id: '600', ts: at(5) } },
    });
    expect(requests(ruled.out)).toEqual([]);
    expect(one(ruled.out, 'K-1')).toMatchObject({ lane: 'held', action: { kind: 'held', cls: 'unbound' } });
    const bare = build({
      versions: three, issues: [issue('K-1', ['v1', 'v2'])],
      journal: [jr('K-1', 'merge-stamp', ['v3'], ['v1', 'v2'], '600')], entries: { 'K-1': { id: '600', ts: at(5) } },
    });
    expect(one(bare.out, 'K-1')).toMatchObject({ lane: 'split', action: { kind: 'held', cls: 'split' } });
  });

  it('displacement key with a never-landed withdrawal refiles under the cap', () => {
    const disp = (n: number): World => ({
      issues: [issue('K-2', [])], journal: [jr('K-2', 'displace-residual', ['v1.1.4'], [], '300')], entries: { 'K-2': { id: '300', ts: at(5) } },
      requests: Array.from({ length: n }, (_, i) => neverLanded(`Q-${i}`, 'K-2', '300')),
    });
    for (const n of [1, 2, 3]) expect(one(build(disp(n)).out, 'K-2'), `n=${n}`).toMatchObject({ lane: 'bound', action: { kind: 'request', entry: '300' } });
    expect(one(build(disp(4)).out, 'K-2')).toMatchObject({ lane: 'already-asked', action: { kind: 'held', cls: 'rm-unresolved' } });
  });

  it('never-landed withdrawal refiles up to three times', () => {
    const w = (n: number, reason = 'never-landed'): World => machineWrite({
      requests: Array.from({ length: n }, (_, i) => neverLanded(`Q-${i}`, 'K-1', '100', { reason })),
    });
    for (const n of [1, 2, 3]) expect(one(build(w(n)).out, 'K-1'), `n=${n}`).toMatchObject({ lane: 'bound', action: { kind: 'request', entry: '100' } });
    expect(one(build(w(4)).out, 'K-1')).toMatchObject({ lane: 'already-asked', action: { kind: 'held', cls: 'rm-unresolved' } });
    expect(one(build(w(1, 'contradicts')).out, 'K-1')).toMatchObject({ lane: 'already-asked', action: { kind: 'held', cls: 'rm-unresolved' } });
  });

  it('a never-landed request does not count as a newer request', () => {
    const w = build(machineWrite({ requests: [neverLanded('Q-1', 'K-1', 'zzz')] }));
    expect(one(w.out, 'K-1').lane).toBe('bound');
  });

  it('spec row naming the key is not an operator record', () => {
    const w = build({ issues: [issue('K-1', ['v1.1.4'])], operator: [spec('O-R1-0002', ['K-1'], at(1))] });
    expect(one(w.out, 'K-1')).toMatchObject({ lane: 'held', action: { kind: 'held', cls: 'unbound' } });
  });

  it('no fold when version is not decl.current', () => {
    const w = build({ issues: [done('HIMMEL-6691', ['v1.1.4'])], entries: { [K6691]: fixture('HIMMEL-6691').newest }, prs: { [K6691]: 12 } });
    expect(one(w.out, 'HIMMEL-6691')).toMatchObject({ lane: 'held', action: { kind: 'held', cls: 'unbound' } });
  });

  it('unauthorized member offers keep', () => {
    const w = build({ issues: [issue('K-1', ['v1.1.4'])] });
    expect(offerFor(one(w.out, 'K-1'), w.input)).toEqual({ op: 'keep', from: 'v1.1.4', to: null });
  });

  it('open ruled-in non-member offers add', () => {
    const w = build({ issues: [issue('HIMMEL-8231', [])], rulings: [ruling('R-1', 'HIMMEL-8231', 'add', null, 'v1.1.4', 'O-R1-0003')], operator: [decision('O-R1-0003', ['HIMMEL-8231'], 'add', null, 'v1.1.4', at(1))] });
    const c = one(w.out, 'HIMMEL-8231');
    expect(c).toMatchObject({ lane: 'held', action: { kind: 'held', cls: 'unbound' } });
    expect(offerFor(c, w.input)).toEqual({ op: 'add', from: null, to: 'v1.1.4' });
  });

  it('Done key with both mismatches offers move and says it overrules', () => {
    const w = build(doneRuledLater('HIMMEL-7804', { entries: { [K7804]: fixture('HIMMEL-7804').newest } }));
    const o = offerFor(one(w.out, 'HIMMEL-7804'), w.input);
    expect(o).toMatchObject({ op: 'move', verb: 'INTAKE', from: 'v1.1.4', to: 'v1.1.3' });
    expect(o.note).toContain('overrules');
    expect(o.note).toContain('v1.1.4');
  });

  it('other shapes offer a new record', () => {
    // a Done ruled-in non-member on no other version
    const a = build({ issues: [done('K-1', [])], rulings: [ruling('R-1', 'K-1', 'add', null, 'v1.1.4', 'rm')] });
    expect(offerFor(one(a.out, 'K-1'), a.input).op).toBeNull();
    // an open key with both mismatches
    const b = build({ issues: [issue('K-2', ['v1.1.3'])], rulings: [ruling('R-2', 'K-2', 'add', null, 'v1.1.4', 'rm')] });
    expect(offerFor(one(b.out, 'K-2'), b.input).op).toBeNull();
    // a Done key whose Done version is later than its ruled one
    const c = build({ issues: [done('K-3', ['v1.1.4'])], rulings: [ruling('R-3', 'K-3', 'add', null, 'v1.1.3', 'rm')] });
    expect(offerFor(one(c.out, 'K-3'), c.input).op).toBeNull();
  });

  it('hand takes the same offers as unbound', () => {
    const w = build(machineWrite({ journal: [jr('K-1', 'hand', [], ['v1.1.4'], '100')] }));
    const c = one(w.out, 'K-1');
    expect(c.action).toEqual({ kind: 'held', cls: 'hand' });
    expect(offerFor(c, w.input)).toEqual({ op: 'keep', from: 'v1.1.4', to: null });
  });

  it('newer operator ruling makes bound ineligible', () => {
    const w = build(machineWrite({
      operator: [decision('O-R1-0001', ['K-1'], 'remove', 'v1.1.4', null, at(20))],
      rulings: [ruling('R-1', 'K-1', 'remove', 'v1.1.4', null, 'O-R1-0001', at(20))],
    }));
    expect(requests(w.out)).toEqual([]);
    expect(one(w.out, 'K-1')).toMatchObject({ lane: 'held', action: { kind: 'held', cls: 'unbound' } });
  });

  it('signed row with no ruling files no Bound request', () => {
    const w = build(machineWrite({ operator: [decision('O-R1-0001', ['K-1'], 'keep', 'v1.1.4', null, at(20))] }));
    expect(requests(w.out)).toEqual([]);
  });

  it('signed row with no ruling counts as unfiled', () => {
    const w = build({ issues: [issue('K-1', ['v1.1.4'])], operator: [decision('O-R1-0001', ['K-1'], 'keep', 'v1.1.4', null, at(20))], entries: { 'K-1': { id: '100', ts: at(5) } } });
    expect(one(w.out, 'K-1')).toMatchObject({ lane: 'operator-record', action: { kind: 'unfiled' } });
  });

  it('change newer than the row goes to conflict', () => {
    const w = build({ issues: [issue('K-1', ['v1.1.4'])], operator: [decision('O-R1-0001', ['K-1'], 'keep', 'v1.1.4', null, at(20))], entries: { 'K-1': { id: '100', ts: at(25) } } });
    expect(one(w.out, 'K-1')).toMatchObject({ lane: 'operator-record', action: { kind: 'held', cls: 'conflict' } });
  });

  it('pending, unknown and stale keys get no output', () => {
    const w = build({
      issues: [issue('K-1', ['v1.1.3']), issue('K-2', ['v1.1.4']), issue('K-3', ['v1.1.4'])],
      rulings: [
        { ...ruling('R-1', 'K-1', 'add', null, 'v1.1.4', 'rm'), phase: 'intent' as const },
        ruling('R-2', 'K-2', 'add', null, 'v1.1.4', 'rm'),
        { ...ruling('R-2b', 'K-2', 'remove', 'v1.1.4', null, 'rm'), supersedes: [] },
      ],
      events: [{ ts: '2026-11-02T13:00:00.000Z', kind: 'ruled', key: 'K-3', from: null, to: 'v1.1.4' }],
    });
    expect(w.state.records.find((r) => r.key === 'K-2' && r.version === 'v1.1.4')?.placement).toBe('unknown');
    for (const k of ['K-1', 'K-2', 'K-3']) expect(one(w.out, k)).toMatchObject({ lane: 'in-flight', action: { kind: 'none' } });
  });

  it('fold needs Done, current, a merged PR, no ruling elsewhere', () => {
    const w = build({ issues: [done('K-1', ['v1.1.3'])], prs: { 'K-1': 88 } });
    expect(one(w.out, 'K-1')).toEqual({ key: 'K-1', version: 'v1.1.3', lane: 'fold', action: { kind: 'fold', pr: 88 } });
  });

  it('no fold outside current for 6691', () => {
    const w = build({ issues: [done('HIMMEL-6691', ['v1.1.4'])], prs: { [K6691]: 5 } });
    expect(one(w.out, 'HIMMEL-6691').lane).not.toBe('fold');
  });

  it('no fold with a ruling elsewhere for 7804', () => {
    const w = build(doneRuledLater('HIMMEL-7804', { prs: { [K7804]: 4039 } }));
    expect(one(w.out, 'HIMMEL-7804').lane).not.toBe('fold');
  });

  it('no fold with an out ruling on current', () => {
    const w = build({
      issues: [done('K-1', ['v1.1.3'])], prs: { 'K-1': 9 },
      operator: [decision('O-R1-0001', ['K-1'], 'remove', 'v1.1.3', null, at(1))],
      rulings: [ruling('R-1', 'K-1', 'remove', 'v1.1.3', null, 'O-R1-0001', at(1))],
    });
    expect(w.state.leaks.unauthorized).toEqual(['K-1@v1.1.3']);
    const c = one(w.out, 'K-1');
    expect(c).toMatchObject({ lane: 'held', action: { kind: 'held', cls: 'unbound' } });
    expect(offerFor(c, w.input).op).toBeNull();
  });

  it('Done with no lookup yet is never done-no-pr', () => {
    const w = build({ issues: [done('K-1', ['v1.1.3'])] });
    expect(one(w.out, 'K-1')).toMatchObject({ lane: 'fold', action: { kind: 'none' } });
  });

  it('null PR goes to done-no-pr', () => {
    const w = build({ issues: [done('K-1', ['v1.1.3'])], prs: { 'K-1': null } });
    expect(one(w.out, 'K-1')).toMatchObject({ lane: 'fold', action: { kind: 'held', cls: 'done-no-pr' } });
    expect(offerFor(one(w.out, 'K-1'), w.input)).toEqual({ op: 'keep', from: 'v1.1.3', to: null });
  });

  const displaced8231 = (auth: string): World => ({
    issues: [issue('HIMMEL-8231', [])],
    operator: auth === 'rm' ? [] : [decision(auth, ['HIMMEL-8231'], 'add', null, 'v1.1.4', '2026-10-30T09:00:00.000Z')],
    rulings: [ruling('R-1', 'HIMMEL-8231', 'add', null, 'v1.1.4', auth, '2026-10-30T10:00:00.000Z')],
    journal: fixture('HIMMEL-8231').journal, entries: { [K8231]: fixture('HIMMEL-8231').newest },
  });

  it('ruled-displaced on 8231 with a synthesized row', () => {
    const w = build(displaced8231('O-R1-0004'));
    expect(one(w.out, 'HIMMEL-8231')).toMatchObject({ lane: 'bound-ruled', action: { kind: 'held', cls: 'ruled-displaced' } });
    expect(offerFor(one(w.out, 'HIMMEL-8231'), w.input)).toEqual({ op: 'add', from: null, to: 'v1.1.4' });
  });

  it('RM-ruled displacement files REVERSION', () => {
    const w = build(displaced8231('rm'));
    expect(one(w.out, 'HIMMEL-8231')).toMatchObject({ lane: 'bound-ruled', action: { kind: 'request', verb: 'REVERSION', from: null, to: 'v1.1.4', entry: '85466' } });
  });

  // The same shape with a merge-stamp row that stripped v1.1.4: the strip was right, a Done key is never in a future version.
  const stamped = (auth: string): World => {
    const f = fixture('HIMMEL-7804').newest;
    return doneRuledLater('HIMMEL-7804', {
      journal: [jr('HIMMEL-7804', 'merge-stamp', ['v1.1.4'], ['v1.1.3'], f.id, '2026-10-27T07:49:33.000Z')], entries: { [K7804]: f },
      rulings: [ruling('R-1', 'HIMMEL-7804', 'add', null, 'v1.1.4', auth, '2026-10-27T05:30:00.000Z')],
      operator: auth === 'rm' ? [] : [{ ...O7804, id: auth }],
    });
  };

  it('Done key stripped by merge-stamp takes the move offer', () => {
    const w = build(stamped('O-R1-0001'));
    const c = one(w.out, 'HIMMEL-7804');
    expect(requests(w.out)).toEqual([]);
    expect(c).toMatchObject({ lane: 'held', action: { kind: 'held', cls: 'unbound' } });
    expect(offerFor(c, w.input)).toMatchObject({ op: 'move', verb: 'INTAKE', from: 'v1.1.4', to: 'v1.1.3', note: expect.stringContaining('overrules') });
  });

  it('an RM-ruled Done key files no REVERSION', () => {
    const w = build(stamped('rm'));
    expect(requests(w.out)).toEqual([]);
    expect(one(w.out, 'HIMMEL-7804')).toMatchObject({ lane: 'held', action: { kind: 'held', cls: 'unbound' } });
  });

  it('Won\'t Do, Duplicate and Other on a version go to closed-undelivered', () => {
    const w = build({
      issues: [done('K-1', ['v1.1.3'], 'Won\'t Do'), done('K-2', ['v1.1.4'], 'Duplicate'), done('K-3', ['v1.1.3'], 'Obsolete')],
      prs: { 'K-1': 1, 'K-2': 2, 'K-3': 3 },
    });
    for (const [k, v] of [['K-1', 'v1.1.3'], ['K-2', 'v1.1.4'], ['K-3', 'v1.1.3']] as const) {
      const c = one(w.out, k);
      expect(c).toMatchObject({ lane: 'closed-undelivered', action: { kind: 'held', cls: 'closed-undelivered' } });
      expect(offerFor(c, w.input)).toEqual({ op: 'remove', from: v, to: null });
    }
  });

  it('signed answer newer than the request beats rm-hold', () => {
    const w = build(machineWrite({
      requests: [req('Q-1', 'K-1', 'held', { to_v: 'v1.1.4' })],
      operator: [decision('O-R1-0001', ['K-1'], 'keep', 'v1.1.4', null, at(20))],
    }));
    expect(one(w.out, 'K-1')).toMatchObject({ lane: 'operator-record', action: { kind: 'withdraw-held', requestId: 'Q-1' } });
  });

  it('signed answer newer than the request beats rm-unresolved', () => {
    const w = build(machineWrite({
      requests: [req('Q-1', 'K-1', 'ruled:R-9')],
      operator: [decision('O-R1-0001', ['K-1'], 'keep', 'v1.1.4', null, at(20))],
    }));
    expect(requests(w.out)).toEqual([]);
    expect(one(w.out, 'K-1')).toMatchObject({ lane: 'operator-record', action: { kind: 'unfiled' } });
  });

  it('gate row open goes to gate-row', () => {
    const gate: Admission = { ts: at(1), version: 'v1.1.4', key: 'K-1', gate: 'critical', actor: 'a' };
    const w = build({ issues: [issue('K-1', ['v1.1.4'])], admissions: [gate] });
    const c = one(w.out, 'K-1');
    expect(c).toMatchObject({ lane: 'gate-row', action: { kind: 'held', cls: 'gate-row' } });
    expect(offerFor(c, w.input)).toEqual({ op: 'keep', from: 'v1.1.4', to: null });
  });

  it.each([
    ['a counted override row', { ts: at(1), version: 'v1.1.4', key: 'K-1', kind: 'override', actor: 'a' } as Admission],
    ['a plain gate row', { ts: at(1), version: 'v1.1.4', key: 'K-1', gate: 'critical', actor: 'a' } as Admission],
  ])('an operator out ruling with %s lands in lane 12 with no op', (_name, row) => {
    const w = build({
      issues: [issue('K-1', ['v1.1.4'])], admissions: [row],
      operator: [decision('O-R1-0001', ['K-1'], 'remove', 'v1.1.4', null, at(0))],
      rulings: [ruling('R-1', 'K-1', 'remove', 'v1.1.4', null, 'O-R1-0001', at(0))],
    });
    const c = one(w.out, 'K-1');
    expect(c.lane).not.toBe('gate-row');
    expect(c.action.kind).toBe('held');
    expect(offerFor(c, w.input)).toEqual({ op: null, from: null, to: null });
  });

  it('a counted row under no out ruling is not a gate row', () => {
    const w = build({ issues: [issue('K-1', ['v1.1.4'])], admissions: [{ ts: at(1), version: 'v1.1.4', key: 'K-1', kind: 'override', actor: 'a' } as Admission] });
    expect(w.out.filter((c) => c.key === 'K-1' && c.lane === 'gate-row')).toEqual([]);
  });

  it('a ruled key that Jira agrees with, still in the loop as a displaced key, goes to nothing', () => {
    const w = build({
      issues: [issue('K-2', [])], journal: [jr('K-2', 'displace-residual', ['v1.1.4'], [], '300')], entries: { 'K-2': { id: '300', ts: at(5) } },
      rulings: [ruling('R-1', 'K-2', 'remove', 'v1.1.4', null, 'rm')],
    });
    expect(one(w.out, 'K-2')).toMatchObject({ lane: 'nothing', action: { kind: 'none' } });
  });

  it('an operator out ruling older than the bound machine row files no INTAKE', () => {
    const w = build(machineWrite({
      operator: [decision('O-R1-0001', ['K-1'], 'remove', 'v1.1.4', null, at(0))],
      rulings: [ruling('R-1', 'K-1', 'remove', 'v1.1.4', null, 'O-R1-0001', at(0))],
    }));
    expect(requests(w.out)).toEqual([]);
    expect(one(w.out, 'K-1').lane).toBe('held');
  });

  it('held request stays rm-hold until its entry moves', () => {
    const w = build(machineWrite({ requests: [req('Q-1', 'K-1', 'held')] }));
    expect(one(w.out, 'K-1')).toMatchObject({ lane: 'rm-held', action: { kind: 'held', cls: 'rm-hold' } });
  });

  it('entry moved gives withdraw-held', () => {
    const w = build(machineWrite({ requests: [req('Q-1', 'K-1', 'held')], entries: { 'K-1': { id: '101', ts: at(15) } } }));
    expect(one(w.out, 'K-1')).toMatchObject({ lane: 'rm-held', action: { kind: 'withdraw-held', requestId: 'Q-1' } });
  });

  it('two mismatches that disagree fall to held', () => {
    const w = build({
      issues: [issue('K-1', [])],
      rulings: [ruling('R-1', 'K-1', 'add', null, 'v1.1.3', 'rm'), ruling('R-2', 'K-1', 'add', null, 'v1.1.4', 'rm')],
      journal: [jr('K-1', 'merge-stamp', ['v1.1.3', 'v1.1.4'], [], '700')], entries: { 'K-1': { id: '700', ts: at(5) } },
    });
    expect(w.state.leaks.ruled_in_non_member).toEqual(['K-1@v1.1.3', 'K-1@v1.1.4']);
    expect(requests(w.out)).toEqual([]);
    expect(one(w.out, 'K-1')).toMatchObject({ lane: 'held', action: { kind: 'held', cls: 'unbound' } });
  });

  // Carry-forward from the S4 review: a request the engine withdrew for lack of an entry (reason entry-moved) names no
  // (key, entry), so it neither dedupes nor counts as a newer request; the refile names the entry.
  it('an entry-less withdrawal refiles with the entry named', () => {
    const entryLess = req('Q-1', 'K-1', 'withdrawn:repair', { reason: 'entry-moved', evidence: { rule: 'version-repair' } });
    const w = build(machineWrite({ requests: [entryLess] }));
    expect(one(w.out, 'K-1')).toMatchObject({ lane: 'bound', action: { kind: 'request', entry: '100' } });
    const nonString = req('Q-2', 'K-1', 'withdrawn:repair', { reason: 'entry-moved', evidence: { rule: 'version-repair', entry: 7 } });
    expect(one(build(machineWrite({ requests: [nonString] })).out, 'K-1').lane).toBe('bound');
  });

  // Carry-forward: hold() skips a request withdrawn between claim() and hold(); the classifier reads only the latest row per
  // request, so that request is an ordinary withdrawn one and needs no row of its own.
  it('a request withdrawn between claim and hold needs no row', () => {
    const w = build(machineWrite({ requests: [req('Q-1', 'K-1', 'withdrawn:console', { reason: 'chief withdrew it' })] }));
    expect(one(w.out, 'K-1')).toMatchObject({ lane: 'already-asked', action: { kind: 'held', cls: 'rm-unresolved' } });
  });

  // Each row of the spec's case table feeds its entry. Excluded: the two "Outside the repair" and "no version" rows (no
  // reducer verdict, so no lane) and the --chief-override row (S1 clears it before the repair sees it).
  describe('case table', () => {
    interface Row { name: string; world: World; key: string; lane: string | null; action?: string }
    const f7044 = fixture('HIMMEL-7044').newest;
    const rows: Row[] = [
      { name: 'HIMMEL-6499 moved and back, both signed', key: 'K-1', lane: null,
        world: { issues: [issue('K-1', ['v1.1.4'])], operator: [decision('O-R1-0007', ['K-1'], 'add', null, 'v1.1.4', at(1))], rulings: [ruling('R-1', 'K-1', 'add', null, 'v1.1.4', 'O-R1-0007')] } },
      { name: 'O-0071 member agrees', key: 'K-1', lane: null,
        world: { issues: [issue('K-1', ['v1.1.4'])], operator: [decision('O-R1-0071', ['K-1'], 'add', null, 'v1.1.4', at(1))], rulings: [ruling('R-1', 'K-1', 'add', null, 'v1.1.4', 'O-R1-0071')] } },
      { name: 'ruled in then displaced, today: unbound', key: 'HIMMEL-7535', lane: 'held', action: 'held:unbound',
        world: { issues: [issue('HIMMEL-7535', [])], operator: [decision('O-R1-0071', ['HIMMEL-7535'], 'add', null, 'v1.1.4', at(1))], rulings: [ruling('R-1', 'HIMMEL-7535', 'add', null, 'v1.1.4', 'O-R1-0071')] } },
      { name: 'ruled in then displaced, after the journal: ruled-displaced', key: 'HIMMEL-8231', lane: 'bound-ruled', action: 'held:ruled-displaced', world: displaced8231('O-R1-0004') },
      { name: 'HIMMEL-3084 hand edit outside the declared versions', key: 'HIMMEL-3084', lane: null,
        world: { issues: [issue('HIMMEL-3084', ['v1.1.1'])], journal: fixture('HIMMEL-3084').journal, entries: { [K3084]: fixture('HIMMEL-3084').newest } } },
      { name: 'gate row, Done: fold', key: 'K-1', lane: 'fold', action: 'fold',
        world: { issues: [done('K-1', ['v1.1.3'])], admissions: [{ ts: at(1), version: 'v1.1.3', key: 'K-1', gate: 'critical', actor: 'a' }], prs: { 'K-1': 3 } } },
      { name: 'gate row, Won\'t Do', key: 'K-1', lane: 'closed-undelivered', action: 'held:closed-undelivered',
        world: { issues: [done('K-1', ['v1.1.3'], 'Won\'t Do')], admissions: [{ ts: at(1), version: 'v1.1.3', key: 'K-1', gate: 'critical', actor: 'a' }] } },
      { name: 'gate row, open', key: 'K-1', lane: 'gate-row', action: 'held:gate-row',
        world: { issues: [issue('K-1', ['v1.1.3'])], admissions: [{ ts: at(1), version: 'v1.1.3', key: 'K-1', gate: 'critical', actor: 'a' }] } },
      { name: 'Done in the current version, no PR found', key: 'K-1', lane: 'fold', action: 'held:done-no-pr',
        world: { issues: [done('K-1', ['v1.1.3'])], prs: { 'K-1': null } } },
      { name: 'Won\'t Do on a version', key: 'K-1', lane: 'closed-undelivered', action: 'held:closed-undelivered',
        world: { issues: [done('K-1', ['v1.1.4'], 'Won\'t Do')] } },
      { name: '175 of 176 under O-0156: ruling agrees', key: 'K-1', lane: null,
        world: { issues: [issue('K-1', ['v1.1.4'])], operator: [decision('O-R1-0156', ['K-1'], 'add', null, 'v1.1.4', at(1))], rulings: [ruling('R-1', 'K-1', 'add', null, 'v1.1.4', 'O-R1-0156')] } },
      { name: 'HIMMEL-8398 signed, no ruling yet', key: 'HIMMEL-8398', lane: 'operator-record', action: 'unfiled',
        world: { issues: [issue('HIMMEL-8398', ['v1.1.4'])], operator: [decision('O-R1-0156', ['HIMMEL-8398'], 'add', null, 'v1.1.4', at(1))] } },
      { name: '13 v1.1.4 open outside that record', key: 'K-1', lane: 'held', action: 'held:unbound', world: { issues: [issue('K-1', ['v1.1.4'])] } },
      { name: 'new residual with a machine-chosen version', key: 'K-1', lane: 'bound', action: 'request', world: machineWrite() },
      { name: 'HIMMEL-6691 held in v1.1.4, closed by hand', key: 'HIMMEL-6691', lane: 'held', action: 'held:unbound',
        world: { issues: [done('HIMMEL-6691', ['v1.1.4'])], prs: { [K6691]: 1 } } },
      { name: 'HIMMEL-7804 Done in v1.1.3, ruled into v1.1.4', key: 'HIMMEL-7804', lane: 'held', action: 'held:unbound', world: doneRuledLater('HIMMEL-7804', { prs: { [K7804]: 4039 } }) },
      { name: 'HIMMEL-7044 same shape', key: 'HIMMEL-7044', lane: 'held', action: 'held:unbound',
        world: doneRuledLater('HIMMEL-7044', { entries: { [K7044]: f7044 } }) },
      { name: '10-14 sweep: no version, no ruling', key: 'K-1', lane: null, world: { issues: [issue('K-1', [])] } },
      { name: '1652 open with no version', key: 'K-1', lane: null, world: { issues: [issue('K-1', [])], entries: { 'K-1': { id: '9', ts: at(1) } } } },
      { name: '5 High signed, no ruling cites them', key: 'HIMMEL-8667', lane: 'operator-record', action: 'unfiled',
        world: { issues: [issue('HIMMEL-8667', ['v1.1.4'])], operator: [decision('O-R1-0150', ['HIMMEL-8667'], 'add', null, 'v1.1.4', at(1))] } },
      { name: 'UI move of a machine-placed ticket', key: 'K-1', lane: 'held', action: 'held:unbound', world: machineWrite({ entries: { 'K-1': { id: '101', ts: at(9) } } }) },
      { name: 'UI move with a request pending', key: 'K-1', lane: 'in-flight', action: 'none', world: machineWrite({ entries: { 'K-1': { id: '101', ts: at(9) } }, requests: [req('Q-1', 'K-1', 'open')] }) },
      { name: 'rm-hold answered by a record that agrees', key: 'K-1', lane: 'operator-record', action: 'withdraw-held',
        world: machineWrite({ requests: [req('Q-1', 'K-1', 'held')], operator: [decision('O-R1-0001', ['K-1'], 'add', null, 'v1.1.4', at(20))] }) },
      { name: 'a Jira outage: never-landed refiles', key: 'K-1', lane: 'bound', action: 'request',
        world: machineWrite({ requests: [neverLanded('Q-1', 'K-1'), neverLanded('Q-2', 'K-1')] }) },
      { name: 'ruled into v1.1.4, also unauthorized in v1.1.3', key: 'K-1', lane: 'held', action: 'held:unbound',
        world: { issues: [issue('K-1', ['v1.1.3'])], rulings: [ruling('R-1', 'K-1', 'add', null, 'v1.1.4', 'rm')] } },
      { name: 'Duplicate on a version', key: 'K-1', lane: 'closed-undelivered', action: 'held:closed-undelivered', world: { issues: [done('K-1', ['v1.1.3'], 'Duplicate')] } },
      { name: 'Other on a version', key: 'K-1', lane: 'closed-undelivered', action: 'held:closed-undelivered', world: { issues: [done('K-1', ['v1.1.3'], 'Cannot Reproduce')] } },
    ];
    const tag = (a: Classification['action']): string => (a.kind === 'held' ? `held:${a.cls}` : a.kind);

    it.each(rows)('$name', ({ world, key, lane, action }) => {
      const out = build(world).out.filter((c) => c.key === key);
      if (lane === null) {
        expect(out).toEqual([]);
        return;
      }
      expect(out).toHaveLength(1);
      expect(out[0]!.lane).toBe(lane);
      if (action !== undefined) expect(tag(out[0]!.action)).toBe(action);
    });
  });
});
