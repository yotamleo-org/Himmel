import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { JUDGE_OPERATOR, judgeOperatorRows } from './judge-input.js';
import { scopeOk } from './reducer.js';
import type { IssueSnap, OperatorRow, RequestRow, RulingRow } from './types.js';

const R = 'v1.1.3';
const row = (n: number, o: Partial<OperatorRow> = {}): OperatorRow => ({
  id: `O-${R}-${String(n).padStart(4, '0')}`, kind: 'spec', decision: String(1000 + n), keys: [`OTHER-${n}`],
  verbatim: 'x', ts: new Date(Date.UTC(2026, 10, 1, 0, 0, n)).toISOString(), prev: 'p', mac: 'm', ...o,
} as OperatorRow);
const pad = row(9000, { keys: ['PAD-1'], verbatim: 'x'.repeat(160_000) });
const ask = (key: string, o: Partial<RequestRow> = {}): RequestRow => ({ req: `Q-${R}-${key}`, verb: 'INTAKE', key, from_v: null, to_v: 'v1', why: '', evidence: null, ...o } as RequestRow);
const ruling = (n: number, key: string, reason: string): RulingRow => ({ id: `R-${R}-${n}`, key, phase: 'receipted', reason, ground: '', ts: new Date(Date.UTC(2026, 10, 2, 0, 0, n)).toISOString() } as RulingRow);
const ids = (rows: OperatorRow[]) => rows.map((r) => r.id);
const pick = (operator: OperatorRow[], asked: RequestRow[], o: { issues?: IssueSnap[]; receipted?: RulingRow[]; settings?: typeof JUDGE_OPERATOR } = {}) =>
  ids(judgeOperatorRows(R, [pad, ...operator], asked, o.issues ?? [], o.receipted ?? [], o.settings));
const X = row(1);
const snap = (o: Partial<IssueSnap>): IssueSnap => ({ status: 'To Do', type: 'Task', priority: 'Medium', fixVersions: [], resolution: null, ...o } as IssueSnap);

describe('judgeOperatorRows', () => {
  it('over the floor, a row that names only another ticket is left out', () => {
    const got = pick([X], [ask('K-1')]);
    expect(got).not.toContain(X.id);
    expect(got).not.toContain(pad.id);
  });

  it('a row naming an asked ticket is returned whatever its kind', () => {
    const rows = (['decision', 'spec', 'core-bypass', 'out-of-version'] as const).map((kind, i) => row(11 + i, { kind, keys: ['K-1'] }));
    expect(pick(rows, [ask('K-1')])).toEqual(expect.arrayContaining(ids(rows)));
  });

  it('a row with no keys is returned', () => {
    const a = row(2, { keys: [] });
    const b = row(3, { keys: undefined });
    expect(pick([a, b], [ask('K-1')])).toEqual(expect.arrayContaining([a.id, b.id]));
  });

  it('a row the why names by id is returned', () => {
    expect(pick([X], [ask('K-1', { why: 'see ' + X.id })])).toContain(X.id);
  });

  it('a row the evidence names by id is returned', () => {
    expect(pick([X], [ask('K-1', { evidence: { operator: X.id } })])).toContain(X.id);
  });

  it('a record id of another release is not named', () => {
    const other = row(5, { id: 'O-v1x1y3-0001', keys: ['OTHER-9'] });
    expect(pick([other], [ask('K-1', { why: 'see O-v1x1y3-0001' })])).not.toContain(other.id);
  });

  it('decision lists name every number', () => {
    const d = (n: string, i: number) => row(20 + i, { decision: n });
    const rows = ['386', '365', '385', '5000', '0386', '77'].map(d);
    const has = (why: string) => new Set(judgeOperatorRows(R, [pad, ...rows], [ask('K-1', { why })], [], []).map((r) => r.decision));
    expect(has('decisions 383, 384 and 386').has('386')).toBe(true);
    expect(has('Decision 365').has('365')).toBe(true);
    for (const why of ['decisions 383 to 386', 'decisions 383 TO 386', 'decisions 383-386']) expect(has(why).has('385'), why).toBe(true);
    const wide = has('decisions 1 to 5000');
    expect(wide.has('5000')).toBe(true);
    expect(wide.has('365')).toBe(false);
    const zero = has('decision 0386');
    expect(zero.has('0386')).toBe(true);
    expect(zero.has('386')).toBe(false);
    for (const why of ['decisions 383, 384 and 386', 'Decision 365', 'decisions 383 to 386', 'decisions 383 TO 386', 'decisions 383-386', 'decisions 1 to 5000', 'decision 0386']) expect(has(why).has('77'), why).toBe(false);
  });

  it('a row naming a ticket the why names is returned', () => {
    const r = row(4, { keys: ['SALUS-12'] });
    expect(pick([r], [ask('K-1', { why: 'follows SALUS-12' })])).toContain(r.id);
  });

  it('a row naming a ticket the evidence names is returned', () => {
    const r = row(5, { keys: ['K-7'] });
    expect(pick([r], [ask('K-1', { evidence: { follow_up_of: 'K-7' } })])).toContain(r.id);
  });

  it("the asked ticket's parent and blockers bring their rows", () => {
    const parent = row(6, { keys: ['K-8'] });
    const blocker = row(7, { keys: ['K-9'] });
    const issues = [snap({ key: 'K-1', parent: 'K-8', blockedBy: ['K-9'] }), snap({ key: 'K-5', parent: 'OTHER-1' })];
    const got = pick([parent, blocker, X], [ask('K-1')], { issues });
    expect(got).toEqual(expect.arrayContaining([parent.id, blocker.id]));
    expect(got).not.toContain(X.id);
  });

  it('an earlier ruling of the asked ticket names rows', () => {
    const k7 = row(5, { keys: ['K-7'] });
    const got = pick([X, k7], [ask('K-1')], { receipted: [ruling(1, 'K-1', 'follows K-7, in v1 under ' + X.id)] });
    expect(got).toEqual(expect.arrayContaining([X.id, k7.id]));
    const other = pick([X, k7], [ask('K-1')], { receipted: [ruling(1, 'K-2', 'follows K-7, in v1 under ' + X.id)] });
    expect(other).not.toContain(X.id);
    expect(other).not.toContain(k7.id);
  });

  it('a row in use by 5 other tickets is returned and one by 4 is not', () => {
    const four = row(8);
    const receipted = [1, 2, 3, 4, 5].map((n) => ruling(n, `U-${n}`, 'under ' + X.id));
    for (const n of [1, 2, 3, 4]) receipted.push(ruling(10 + n, `U-${n}`, 'under ' + four.id));
    const got = pick([X, four], [ask('K-1')], { receipted });
    expect(got).toContain(X.id);
    expect(got).not.toContain(four.id);
  });

  it('use counts only the last 1,000 rulings', () => {
    const receipted = [1, 2, 3, 4, 5].map((n) => ruling(n, `U-${n}`, 'under ' + X.id));
    for (let n = 0; n < 1000; n++) receipted.push(ruling(100 + n, 'U-9', 'nothing'));
    expect(pick([X], [ask('K-1')], { receipted })).not.toContain(X.id);
  });

  it('use does not count a ticket the row names', () => {
    const r = row(6, { keys: ['U-1'] });
    const receipted = [1, 2, 3, 4, 5].map((n) => ruling(n, `U-${n}`, 'under ' + r.id));
    expect(pick([r], [ask('K-1')], { receipted })).not.toContain(r.id);
  });

  it('settings widen the use rule', () => {
    const four = row(8);
    const receipted = [1, 2, 3, 4].map((n) => ruling(n, `U-${n}`, 'under ' + four.id));
    expect(pick([four], [ask('K-1')], { receipted, settings: { ...JUDGE_OPERATOR, others: 1 } })).toContain(four.id);
  });

  it('the last 30 decision rows are recent', () => {
    const rows = Array.from({ length: 31 }, (_, n) => row(100 + n, { kind: 'decision', keys: [`OTHER-${100 + n}`] }));
    const got = pick(rows, [ask('K-1')]);
    expect(got).not.toContain(rows[0].id);
    for (const r of rows.slice(1)) expect(got).toContain(r.id);
  });

  it('a request with no why and null evidence selects by its key alone', () => {
    const r = row(7, { keys: ['K-1'] });
    expect(pick([r], [ask('K-1', { why: undefined as never, evidence: null })])).toContain(r.id);
  });

  it('two calls in a row give the same rows', () => {
    const a = row(31, { keys: ['K-7'] });
    const b = row(32, { keys: ['K-8'] });
    const asked = [ask('K-1', { why: 'K-7 and K-8' })];
    expect(pick([a, b], asked)).toEqual(pick([a, b], asked));
    expect(pick([a, b], asked)).toEqual(expect.arrayContaining([a.id, b.id]));
  });

  it('under the floor every row is returned', () => {
    const bytes = (rows: OperatorRow[]) => Buffer.byteLength(JSON.stringify(rows.map(({ mac: _m, prev: _p, ...r }) => r)));
    const k = 149_999 - bytes([row(1, { verbatim: '' })]);
    const under = [row(1, { verbatim: 'x'.repeat(k) })];
    const over = [row(1, { verbatim: 'x'.repeat(k + 1) })];
    expect(bytes(under)).toBe(149_999);
    expect(judgeOperatorRows(R, under, [ask('K-1')], [], [])).toEqual(under);
    expect(judgeOperatorRows(R, over, [ask('K-1')], [], [])).toEqual([]);
  });

  it('rows come back unchanged and in ledger order', () => {
    const five = [1, 2, 3, 4, 5].map((n) => row(n, { keys: ['K-1'] }));
    const got = judgeOperatorRows(R, [pad, ...five], [ask('K-1')], [], []);
    expect(got).toHaveLength(5);
    got.forEach((r, i) => { expect(r).toBe(five[i]); expect(r).toMatchObject({ mac: 'm', prev: 'p' }); });
  });

  it('no rows in, no rows out', () => {
    expect(judgeOperatorRows(R, [], [ask('K-1')], [], [])).toEqual([]);
  });

  it('judge-input.ts imports only types and names no clock, process, environment or random source', () => {
    const src = readFileSync(join(dirname(fileURLToPath(import.meta.url)), 'judge-input.ts'), 'utf8');
    const imports = src.split('\n').filter((l) => /^\s*import\b/.test(l));
    expect(imports.length).toBeGreaterThan(0);
    for (const l of imports) expect(l).toMatch(/^import type /);
    expect(src).not.toMatch(/\b(Date|process|globalThis|performance|require|crypto|fetch)\b|Math\.random|\bimport\(/);
  });

  it('every row scopeOk accepts as authority for an asked ticket is returned', () => {
    const types = readFileSync(join(dirname(fileURLToPath(import.meta.url)), 'types.ts'), 'utf8');
    const kinds = [...types.split('\n').find((l) => l.startsWith('export type OperatorKind'))!.matchAll(/'([a-z-]+)'/g)].map((m) => m[1]);
    expect(kinds.length).toBeGreaterThanOrEqual(12);
    const accepted: string[] = [];
    for (const kind of kinds) for (const keys of [undefined, ['K-1'], ['OTHER-1']]) {
      const o = row(1, { kind: kind as OperatorRow['kind'], keys, op: 'add', from_v: null, to_v: 'v1' });
      const r = { key: 'K-1', op: { kind: 'add' as const, from_v: null, to_v: 'v1' }, authority: { kind: 'operator' as const, ref: o.id, blocks: ['K-2'], delivered: { pr: 1 } } };
      if (!scopeOk(r as never, new Map([[o.id, o]]), 'v1')) continue;
      accepted.push(`${kind} ${JSON.stringify(keys)}`);
      expect(pick([o], [ask('K-1')]), `${kind} ${JSON.stringify(keys)}`).toContain(o.id);
    }
    expect(accepted).toHaveLength(10);
  });
});
