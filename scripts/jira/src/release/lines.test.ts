import { describe, it, expect, vi, afterEach } from 'vitest';
import { chainLine, parseChain, sha256, GENESIS } from './ledger.js';
import { reduce, type ReduceInput, type ReleaseState } from './reducer.js';
import { isSerious } from './operator-work.js';
import type { VersionLines } from './lines.js';
import type { Admission } from '../commands/admissions-ledger.js';
import type { Baseline, Declaration, EventRow, IssueSnap, OperatorRow, RulingRow } from './types.js';

const KEY = Buffer.alloc(32, 7);
const day = (n: number, time = '10:00:00.000Z') => `2026-10-${String(n).padStart(2, '0')}T${time}`;
const d = (n: number) => day(n).slice(0, 10);

function chainText(rows: object[]): string {
  let head = GENESIS;
  let text = '';
  for (const r of rows) {
    const line = chainLine(head, KEY, r as Record<string, unknown>);
    text += `${line}\n`;
    head = sha256(line);
  }
  return text;
}
const chain = <T>(rows: object[]) => parseChain<T>(chainText(rows), KEY);

const decl: Declaration = {
  project: 'HIMMEL', release: 'R1', versions: ['v1', 'v2'], current: 'v1', mode: 'observe', decision: '106', ts: day(1),
};
const base: Baseline = { release: 'R1', version: 'v1', gen: 1, keys: ['K-1'], decision: '104', ts: day(1) };

function rule(id: string, key: string, kind: RulingRow['op']['kind'], from_v: string | null, to_v: string | null,
  extra: Partial<RulingRow> = {}): RulingRow {
  return {
    id, epoch: 1, req: `Q-${id}`, ts: day(2), verb: 'INTAKE', key, op: { kind, from_v, to_v }, outcome: 'ADMIT',
    class: 'current', sector: 'Planning & tracking', ground: 'regression', reason: 'r', supersedes: [],
    authority: { kind: 'rm', ref: null }, phase: 'applied', ...extra,
  };
}
const issue = (key: string, fixVersions: string[], status = 'To Do', extra: Partial<IssueSnap> = {}): IssueSnap =>
  ({ key, status, type: 'Task', priority: 'Medium', fixVersions, resolution: null, ...extra });
const closed = (key: string, fixVersions: string[], resolution: string | null = 'Done', extra: Partial<IssueSnap> = {}): IssueSnap =>
  issue(key, fixVersions, 'Closed', { statusCategory: 'Done', resolution, ...extra });
const fold = (key: string, to: string, ts: string): EventRow => ({ ts, kind: 'fold', key, from: null, to, pr: 1 });
const opRow = (id: string, kind: OperatorRow['kind'], extra: Partial<OperatorRow> = {}): OperatorRow =>
  ({ id, kind, ts: day(1), decision: '1', ...extra });

function input(over: Partial<ReduceInput> & { rulingRows?: RulingRow[]; opRows?: OperatorRow[]; eventRows?: EventRow[];
  issueList?: IssueSnap[] }): ReduceInput {
  return {
    decl,
    baselines: [base],
    rulings: chain<RulingRow>(over.rulingRows ?? []),
    operator: chain<OperatorRow>(over.opRows ?? []),
    events: chain<EventRow>(over.eventRows ?? []),
    issues: over.issueList === undefined ? new Map([['K-1', issue('K-1', ['v1'])]])
      : new Map(over.issueList.map((i) => [i.key, i])),
    mirrorSync: day(2),
    ...over,
  };
}

function assertIdentity(s: ReleaseState): void {
  for (const l of Object.values(s.version_lines)) {
    if (l.status !== 'OK') continue;
    for (const x of l.days) {
      expect(x.came_in).toBe(x.done + x.left + x.open);
      for (const n of [x.came_in, x.done, x.left, x.open, x.closed_undelivered]) expect(n).toBeGreaterThanOrEqual(0);
    }
  }
}
function run(inp: ReduceInput): ReleaseState {
  const s = reduce(inp);
  assertIdentity(s);
  return s;
}
type Ok = Extract<VersionLines, { status: 'OK' }>;
function ok(s: ReleaseState, v = 'v1'): Ok {
  const l = s.version_lines[v];
  if (l?.status !== 'OK') throw new Error(`${v} lines are not OK: ${JSON.stringify(l)}`);
  return l;
}
const at = (l: Ok, dayStr: string) => l.days.find((x) => x.day === dayStr);
const series = (l: Ok, field: 'came_in' | 'done' | 'left' | 'open') => l.days.map((x) => [x.day, x[field]]);

afterEach(() => { vi.useRealTimers(); });

describe('version lines: came in', () => {
  it('an added ticket raises came in and leaves done', () => {
    const s = run(input({
      rulingRows: [rule('R-1', 'K-2', 'add', null, 'v1')],
      issueList: [issue('K-1', ['v1']), issue('K-2', ['v1'])],
    }));
    const l = ok(s);
    expect(l.days.map((x) => [x.day, x.came_in, x.done])).toEqual([[d(1), 1, 0], [d(2), 2, 0]]);
  });

  it('isSerious holds High and Highest serious, and nothing else', () => {
    expect(['Highest', 'High', 'Medium', 'Low', ''].map(isSerious)).toEqual([true, true, false, false, false]);
  });

  it('gives each arrival-table row its reason, and a day\'s arrived sums to its rise', () => {
    const ops = [
      opRow('O-R1-delivered-follows-merge', 'delivered-follows-merge'),
      opRow('O-R1-blocker-pull', 'blocker-pull'),
      opRow('O-R1-emergency', 'emergency'),
      opRow('O-R1-0001', 'decision', { keys: ['K-6'], op: 'add', from_v: null, to_v: 'v1' }),
    ];
    const opr = (ref: string, extra: Partial<RulingRow['authority']> = {}) => ({ authority: { kind: 'operator' as const, ref, ...extra } });
    const rows = [
      rule('R-3', 'K-3', 'add', null, 'v1', opr('O-R1-delivered-follows-merge', { delivered: 'PR 1' })),
      rule('R-4', 'K-4', 'add', null, 'v1', opr('O-R1-blocker-pull', { blocks: ['K-1'] })),
      rule('R-5', 'K-5', 'add', null, 'v1', opr('O-R1-emergency')),
      rule('R-6', 'K-6', 'add', null, 'v1', opr('O-R1-0001')),
      rule('R-7', 'K-7', 'add', null, 'v1', { ground: 'door:serious:High' }),
      rule('R-8', 'K-8', 'add', null, 'v1', { ground: 'door:repair-keeps' }),
      rule('R-9', 'K-9', 'add', null, 'v1', { ground: 'door:repair' }),
      rule('R-10', 'K-10', 'add', null, 'v1', { ground: 'chain:HIMMEL-1' }),
      rule('R-11', 'K-11', 'add', null, 'v1', { ground: '' }),
      rule('R-12', 'K-12', 'add', null, 'v1', { authority: { kind: 'import', ref: null } }),
    ];
    const keys = ['K-1', ...rows.map((r) => r.key), 'K-2'];
    const s = run(input({
      rulingRows: rows, opRows: ops, eventRows: [fold('K-2', 'v1', day(2))],
      issueList: keys.map((k) => issue(k, ['v1'])),
    }));
    const l = ok(s);
    expect(at(l, d(1))?.arrived).toEqual({ baseline: 1 });
    expect(at(l, d(2))?.arrived).toEqual({
      fold: 1, delivered: 1, blocker: 1, emergency: 1, operator: 1, 'door:serious': 1, 'door:repair-keeps': 1,
      'door:repair': 1, chain: 1, judged: 1, import: 1,
    });
    for (let n = 1; n < l.days.length; n++) {
      const sum = Object.values(l.days[n].arrived).reduce((a, b) => a + b, 0);
      expect(sum).toBe(l.days[n].came_in - l.days[n - 1].came_in);
    }
  });

  it('a tie at the same ts takes the base, then the ruling, then the fold', () => {
    const s = run(input({
      rulingRows: [rule('R-1', 'K-1', 'add', null, 'v1', { ts: day(1) }), rule('R-2', 'K-2', 'add', null, 'v1')],
      eventRows: [fold('K-2', 'v1', day(2))],
      issueList: [issue('K-1', ['v1']), issue('K-2', ['v1'])],
    }));
    const l = ok(s);
    expect(at(l, d(1))?.arrived).toEqual({ baseline: 1 });
    expect(at(l, d(2))?.arrived).toEqual({ regression: 1 });
  });

  it('a superseded ruling still counts, and a ruling scopeOk refuses does not', () => {
    const s = run(input({
      rulingRows: [
        rule('R-1', 'K-2', 'add', null, 'v1'),
        rule('R-2', 'K-2', 'move', 'v1', 'v2', { ts: day(3), verb: 'REVERSION', outcome: 'MOVE', supersedes: ['R-1'] }),
        rule('R-3', 'K-3', 'add', null, 'v1', { authority: { kind: 'operator', ref: 'O-R1-0009' } }),
      ],
      issueList: [issue('K-1', ['v1']), issue('K-2', ['v2']), issue('K-3', ['v1'])],
      mirrorSync: day(3),
    }));
    const l = ok(s);
    expect(series(l, 'came_in')).toEqual([[d(1), 1], [d(2), 2], [d(3), 2]]);
    expect(l.left).toEqual([{ key: 'K-2', day: d(3), authority: 'rm' }]);
    expect(l.unrecorded.open).toEqual(['K-3']);
  });

  it('a pending intent does not count until it is applied', () => {
    const intent = rule('R-1', 'K-2', 'add', null, 'v1', { phase: 'intent' });
    const issues = [issue('K-1', ['v1']), issue('K-2', ['v1'])];
    expect(series(ok(run(input({ rulingRows: [intent], issueList: issues }))), 'came_in')).toEqual([[d(1), 1], [d(2), 1]]);
    expect(series(ok(run(input({ rulingRows: [intent, { ...intent, phase: 'applied' }], issueList: issues }))), 'came_in'))
      .toEqual([[d(1), 1], [d(2), 2]]);
  });

  it('arrived_serious counts the arrivals isSerious holds serious', () => {
    const s = run(input({
      rulingRows: [rule('R-1', 'K-2', 'add', null, 'v1'), rule('R-2', 'K-3', 'add', null, 'v1'), rule('R-3', 'K-4', 'add', null, 'v1')],
      issueList: [issue('K-1', ['v1'], 'To Do', { priority: 'Highest' }), issue('K-2', ['v1'], 'To Do', { priority: 'High' }),
        issue('K-3', ['v1']), issue('K-4', ['v1'], 'To Do', { priority: '' })],
    }));
    const l = ok(s);
    expect(at(l, d(1))?.arrived_serious).toBe(1);
    expect(at(l, d(2))?.arrived_serious).toBe(1);
  });
});

describe('version lines: the came-in line never falls (I1)', () => {
  it('no day\'s came_in is lower on prefix n+1 than on prefix n of a 12-row fixture', () => {
    const g1: Baseline = { ...base, keys: ['K-1', 'K-2'] };
    const g2: Baseline = { ...base, gen: 2, keys: ['K-1'], ts: day(6) };
    type Step = { r?: RulingRow; e?: EventRow; b?: Baseline };
    const steps: Step[] = [
      { b: g1 },
      { r: rule('R-1', 'K-3', 'add', null, 'v1') },
      { e: fold('K-4', 'v1', day(2)) },
      { r: rule('R-2', 'K-3', 'move', 'v1', 'v2', { ts: day(3), verb: 'REVERSION', outcome: 'MOVE', supersedes: ['R-1'] }) },
      { r: rule('R-3', 'K-5', 'add', null, 'v1', { ts: day(3), phase: 'intent' }) },
      { r: rule('R-3', 'K-5', 'add', null, 'v1', { ts: day(3), phase: 'void' }) },
      { r: rule('R-4', 'K-6', 'add', null, 'v1', { ts: day(3), authority: { kind: 'operator', ref: 'O-R1-0001' } }) },
      { e: { ts: day(4), kind: 'reopen', key: 'K-4', from: null, to: 'v1' } },
      { r: rule('R-5', 'K-2', 'remove', 'v1', null, { ts: day(4), verb: 'REVERSION', outcome: 'MOVE', supersedes: ['baseline-v1-g1'] }) },
      { r: rule('R-6', 'K-7', 'add', null, 'v1', { ts: day(5) }) },
      { r: rule('R-7', 'K-7', 'add', null, 'v1', { ts: day(5), supersedes: ['R-6'] }) },
      { b: g2 },
    ];
    expect(steps).toHaveLength(12);
    const issues = ['K-1', 'K-2', 'K-3', 'K-5', 'K-6', 'K-7'].map((k) => issue(k, ['v1'])).concat([closed('K-4', ['v1'])]);
    const at6 = (n: number) => {
      const pre = steps.slice(0, n);
      const bases = pre.flatMap((x) => (x.b ? [x.b] : []));
      const s = run(input({
        baselines: bases.slice(-1), base_history: bases,
        rulingRows: pre.flatMap((x) => (x.r ? [x.r] : [])), eventRows: pre.flatMap((x) => (x.e ? [x.e] : [])),
        issueList: issues, mirrorSync: day(6),
      }));
      return new Map(ok(s).days.map((x) => [x.day, x.came_in]));
    };
    for (let n = 0; n < steps.length; n++) {
      const before = at6(n);
      const after = at6(n + 1);
      for (const [dd, c] of before) expect(after.get(dd) ?? -1).toBeGreaterThanOrEqual(c);
    }
  });

  it('an operator move out of v1 leaves came in at 2 and lists the key as left by the operator', () => {
    const s = run(input({
      rulingRows: [
        rule('R-1', 'K-2', 'add', null, 'v1'),
        rule('R-2', 'K-2', 'move', 'v1', 'v2', { ts: day(3), verb: 'REVERSION', outcome: 'MOVE', supersedes: ['R-1'],
          authority: { kind: 'operator', ref: 'O-R1-0001' } }),
      ],
      opRows: [opRow('O-R1-0001', 'decision', { keys: ['K-2'], op: 'move', from_v: 'v1', to_v: 'v2' })],
      issueList: [issue('K-1', ['v1']), issue('K-2', ['v2'])], mirrorSync: day(3),
    }));
    const v1 = ok(s);
    expect(at(v1, d(3))).toMatchObject({ came_in: 2, left: 1, open: 1 });
    expect(v1.left).toEqual([{ key: 'K-2', day: d(3), authority: 'operator' }]);
    expect(at(ok(s, 'v2'), d(3))?.came_in).toBe(1);
  });

  it('a re-freeze that drops K-1 keeps its came-in day and lists it as left; the newest base alone lets the line fall', () => {
    const g2: Baseline = { ...base, gen: 2, keys: ['K-2'], ts: day(4) };
    const fixture = { rulingRows: [rule('R-1', 'K-2', 'add', null, 'v1')], issueList: [issue('K-1', ['v1']), issue('K-2', ['v1'])], mirrorSync: day(4) };
    const l = ok(run(input({ ...fixture, baselines: [g2], base_history: [base, g2] })));
    expect(series(l, 'came_in')).toEqual([[d(1), 1], [d(2), 2], [d(3), 2], [d(4), 2]]);
    expect(at(l, d(1))?.arrived).toEqual({ baseline: 1 });
    expect(l.left).toEqual([{ key: 'K-1', day: d(4), authority: 'operator' }]);
    expect(at(l, d(4))).toMatchObject({ left: 1, open: 1 });
    const control = ok(run(input({ ...fixture, baselines: [g2] })));
    expect(control.days[0]).toMatchObject({ day: d(2), came_in: 1 });
  });
});

describe('version lines: done, left and open', () => {
  it('a close counts on its resolved day; a Won\'t Do counts in closed_undelivered and a Done does not', () => {
    const s = run(input({
      rulingRows: [rule('R-1', 'K-2', 'add', null, 'v1')],
      issueList: [closed('K-1', ['v1'], 'Done', { resolved: day(2) }), closed('K-2', ['v1'], "Won't Do", { status: "Won't Do", resolved: day(3) })],
      mirrorSync: day(3),
    }));
    const l = ok(s);
    expect(l.days.map((x) => [x.day, x.done, x.closed_undelivered])).toEqual([[d(1), 0, 0], [d(2), 1, 0], [d(3), 2, 1]]);
  });

  it('a key resolved before it came in counts from its came-in day; a reopened key is not done', () => {
    const s = run(input({
      rulingRows: [rule('R-1', 'K-2', 'add', null, 'v1', { ts: day(3) })],
      issueList: [issue('K-1', ['v1'], 'In Progress', { resolved: day(1) }), closed('K-2', ['v1'], 'Done', { resolved: day(1) })],
      mirrorSync: day(3),
    }));
    expect(series(ok(s), 'done')).toEqual([[d(1), 0], [d(2), 0], [d(3), 1]]);
  });

  it('a close with no resolved date takes its fold, and with neither the last day and done_undated', () => {
    const s = run(input({
      rulingRows: [rule('R-1', 'K-2', 'add', null, 'v1')],
      eventRows: [fold('K-1', 'v1', day(3))],
      issueList: [closed('K-1', ['v1']), closed('K-2', ['v1'])], mirrorSync: day(4),
    }));
    const l = ok(s);
    expect(series(l, 'done')).toEqual([[d(1), 0], [d(2), 0], [d(3), 1], [d(4), 2]]);
    expect(l.done_undated).toBe(1);
  });

  it('a key closed after it left is left, not done', () => {
    const s = run(input({
      rulingRows: [rule('R-1', 'K-1', 'remove', 'v1', null, { verb: 'REVERSION', outcome: 'MOVE', supersedes: ['baseline-v1-g1'] })],
      issueList: [closed('K-1', [], 'Done', { resolved: day(2) })],
    }));
    expect(at(ok(s), d(2))).toMatchObject({ came_in: 1, done: 0, left: 1, open: 0 });
  });

  it('takes the UTC day of a resolved date with an offset', () => {
    const s = run(input({ issueList: [closed('K-1', ['v1'], 'Done', { resolved: '2026-10-03T00:30:00.000+0100' })], mirrorSync: day(3) }));
    expect(series(ok(s), 'done')).toEqual([[d(1), 0], [d(2), 1], [d(3), 1]]);
  });

  it('never reads a pending, unknown or fold-only key as left', () => {
    const s = run(input({
      rulingRows: [
        rule('R-1', 'K-2', 'add', null, 'v1'),
        rule('R-2', 'K-2', 'move', 'v1', 'v2', { ts: day(3), phase: 'intent', verb: 'REVERSION', outcome: 'MOVE', supersedes: ['R-1'] }),
        rule('R-3', 'K-3', 'add', null, 'v1'),
        rule('R-4', 'K-3', 'remove', 'v1', null, { ts: day(3), supersedes: ['R-3'], authority: { kind: 'operator', ref: 'O-R1-0009' } }),
      ],
      eventRows: [fold('K-4', 'v1', day(2))],
      issueList: [issue('K-1', ['v1']), issue('K-2', ['v1']), issue('K-3', ['v1']), issue('K-4', [])], mirrorSync: day(3),
    }));
    const l = ok(s);
    expect(l.left).toEqual([]);
    expect(at(l, d(3))).toMatchObject({ came_in: 4, left: 0, open: 4 });
  });
});

describe('version lines: the readings beside them', () => {
  it('counts the open keys by priority', () => {
    const s = run(input({
      rulingRows: ['K-2', 'K-3', 'K-4'].map((k, n) => rule(`R-${n}`, k, 'add', null, 'v1')),
      issueList: [issue('K-1', ['v1'], 'To Do', { priority: 'High' }), issue('K-2', ['v1']), issue('K-3', ['v1']),
        issue('K-4', ['v1'], 'To Do', { priority: '' })],
    }));
    expect(ok(s).open_by_priority).toEqual({ High: 1, Medium: 2, none: 1 });
  });

  it('names the earliest open To Do key as oldest untouched, past an older started one', () => {
    const s = run(input({
      rulingRows: [rule('R-1', 'K-2', 'add', null, 'v1'), rule('R-2', 'K-3', 'add', null, 'v1', { ts: day(3) })],
      issueList: [issue('K-1', ['v1'], 'In Progress', { statusCategory: 'In Progress' }), issue('K-2', ['v1'], 'To Do', { statusCategory: 'To Do' }),
        issue('K-3', ['v1'])],
      mirrorSync: day(5),
    }));
    expect(ok(s).oldest_untouched).toEqual({ key: 'K-2', since: d(2), days: 3 });
  });

  it('lists Jira members with no ledger record beside the lines, and none of them moves a line', () => {
    const adm: Admission = { ts: day(2), version: 'v1', key: 'K-10', kind: 'rm-admit', actor: 'rm' };
    const moved = rule('R-1', 'K-1', 'remove', 'v1', null, { verb: 'REVERSION', outcome: 'MOVE', supersedes: ['baseline-v1-g1'] });
    const plain = ok(run(input({ rulingRows: [moved], issueList: [issue('K-1', ['v1'])] })));
    const s = run(input({
      rulingRows: [moved], admissions: [adm],
      issueList: [issue('K-1', ['v1']), issue('K-8', ['v1']), closed('K-9', ['v1']), issue('K-10', ['v1'])],
    }));
    const l = ok(s);
    expect(l.unrecorded).toEqual({ open: ['K-10', 'K-8'], closed: ['K-9'] });
    expect(l.left.map((x) => x.key)).toEqual(['K-1']);
    expect(l.days).toEqual(plain.days);
  });
});

describe('version lines: unknown input (X1)', () => {
  const bad = (): ReturnType<typeof chain<RulingRow>> => {
    const text = chainText([rule('R-1', 'K-2', 'add', null, 'v1'), rule('R-2', 'K-3', 'add', null, 'v1')]);
    const lines = text.split('\n');
    lines[1] = lines[1].replace('"K-3"', '"K-4"');
    return parseChain<RulingRow>(lines.join('\n'), KEY);
  };

  it.each([
    ['no issues', { issues: null }],
    ['no mirror sync', { mirrorSync: null }],
    ['a bad rulings line', { rulings: bad() }],
  ] as Array<[string, Partial<ReduceInput>]>)('every version reads UNKNOWN with a reason and no number: %s', (_n, over) => {
    const s = run(input(over));
    for (const v of decl.versions) {
      expect(s.version_lines[v]).toMatchObject({ status: 'UNKNOWN', reason: expect.any(String) });
      expect(Object.keys(s.version_lines[v])).toEqual(['status', 'reason']);
    }
  });
});

describe('version lines: a reading only (I2, I3)', () => {
  const fixture = (resolved: string) => input({
    rulingRows: [rule('R-1', 'K-2', 'add', null, 'v1'), rule('R-2', 'K-3', 'add', null, 'v1', { ts: day(5) })],
    issueList: [closed('K-1', ['v1'], 'Done', { resolved }), issue('K-2', ['v1'], 'To Do', { statusCategory: 'To Do' }), issue('K-3', ['v1'])],
    mirrorSync: day(4),
  });

  it('two system times give equal version_lines', () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-11-01T00:00:00Z'));
    const a = run(fixture(day(2))).version_lines;
    vi.setSystemTime(new Date('2027-03-01T00:00:00Z'));
    const b = run(fixture(day(2))).version_lines;
    expect(b).toEqual(a);
    expect(ok({ version_lines: a } as ReleaseState).oldest_untouched).toEqual({ key: 'K-2', since: d(2), days: 3 });
  });

  it('two resolved dates change the lines and nothing else in the state', () => {
    const a = run(fixture(day(2)));
    const b = run(fixture(day(3)));
    expect(b.version_lines).not.toEqual(a.version_lines);
    const { version_lines: _a, ...restA } = a;
    const { version_lines: _b, ...restB } = b;
    expect(restB).toEqual(restA);
  });
});
