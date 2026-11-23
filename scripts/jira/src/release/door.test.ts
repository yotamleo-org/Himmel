import { describe, it, expect } from 'vitest';
import { doorDecide, doorJudge, earlierThan, type DoorResult } from './door.js';
import { requiredParentOf, type JudgeInput, type RuledDecision } from './engine.js';
import type { IssueSnap, OperatorRow, RequestRow, RulingRow } from './types.js';

const C = 'v1.1.3';
const N = 'v1.1.4';
const VERSIONS = [C, N];

const snap = (key: string, o: Partial<IssueSnap> = {}): IssueSnap => ({
  key, status: 'To Do', statusCategory: 'To Do', type: 'Task', priority: 'Medium', fixVersions: [], resolution: null, labels: [], sector: 's', ...o,
});
const req = (key: string, o: Partial<RequestRow> = {}): RequestRow => ({
  req: 'Q-R-0001', ts: '2026-11-22T10:00:00.000Z', from: 'console', verb: 'INTAKE', key, from_v: null, to_v: C, why: 'found work', evidence: {}, state: 'claimed', ...o,
});
const input = (o: Partial<JudgeInput> = {}): JudgeInput => ({
  release: 'R', current: C, versions: VERSIONS, requests: [], records: [], operator: [], rulings: [], issues: [], ...o,
});
const decisionRow = (id: string, ts: string, op: string, from_v: string | null, to_v: string | null, keys = ['K-2']): OperatorRow => ({
  id, kind: 'decision', ts, decision: '243', keys, op, from_v, to_v, verbatim: 'x',
});
const operatorRuling = (id: string, ts: string, version: string): RulingRow => ({
  id, epoch: 1, req: 'Q-R-0009', ts, verb: 'INTAKE', key: 'K-2', op: { kind: 'add', from_v: null, to_v: version }, outcome: 'ADMIT',
  class: 'current' as RulingRow['class'], sector: 's', ground: 'operator', reason: 'r', supersedes: [], authority: { kind: 'operator', ref: 'O-R-0001' }, phase: 'receipted',
});
const record = (key: string, version: string, ruling: string) => ({ key, version, ruling } as unknown as JudgeInput['records'][number]);

function decide(inp: JudgeInput, q: RequestRow): DoorResult {
  const first = doorDecide(inp, q);
  expect(doorDecide(inp, q)).toEqual(first);
  expect(first.outcome).not.toBe('HOLD');
  expect(first.ground).toMatch(/^door:/);
  return first;
}
const one = (s: Partial<IssueSnap>, q: Partial<RequestRow> = {}, inp: Partial<JudgeInput> = {}): DoorResult =>
  decide(input({ issues: [snap('K-2', s), ...(inp.issues ?? [])], ...inp, requests: [] }), req('K-2', q));
const placed = (d: DoorResult) => {
  const r = d as RuledDecision;
  return { outcome: r.outcome, op: r.op, from: r.from, to: r.to, ground: r.ground };
};

describe('the door: INTAKE, first match wins', () => {
  it('mild priorities go to the next version, and to the backlog when there is none (rule M; I9)', () => {
    for (const priority of ['Medium', 'Low', 'Lowest', '']) {
      expect(placed(one({ priority }))).toEqual({ outcome: 'ADMIT', op: 'add', from: null, to: N, ground: 'door:mild' });
      expect(placed(one({ priority }, {}, { versions: [C] }))).toEqual({ outcome: 'BACKLOG', op: 'none', from: null, to: null, ground: 'door:mild-no-next' });
    }
  });

  it('the same tickets go to current when labelled operator-directed or In Progress (rules A and W; I9)', () => {
    for (const priority of ['Medium', 'Low', 'Lowest', '']) {
      expect(placed(one({ priority, labels: ['operator-directed'] }))).toEqual({ outcome: 'ADMIT', op: 'add', from: null, to: C, ground: 'door:operator-ask' });
      expect(placed(one({ priority, status: 'In Progress', statusCategory: 'In Progress' }))).toEqual({ outcome: 'ADMIT', op: 'add', from: null, to: C, ground: 'door:started' });
    }
  });

  it('High and Highest go to current (rule H)', () => {
    for (const priority of ['High', 'Highest']) {
      expect(placed(one({ priority }, { to_v: N }))).toEqual({ outcome: 'ADMIT', op: 'add', from: null, to: C, ground: `door:serious:${priority}` });
    }
  });

  it('a version-repair mark forged from the CLI falls to rule M (I9)', () => {
    expect(placed(one({}, { from: 'console', evidence: { rule: 'version-repair' } }))).toEqual({ outcome: 'ADMIT', op: 'add', from: null, to: N, ground: 'door:mild' });
  });

  it('a closed ticket with a merged PR goes where it was asked (rule F)', () => {
    const d = one({ status: 'Done', statusCategory: 'Done', resolution: 'Done' }, { to_v: N, evidence: { pr: 12 } });
    expect(placed(d)).toEqual({ outcome: 'ADMIT', op: 'add', from: null, to: N, ground: 'door:done' });
  });

  it('the chief\'s placement wins over every rule but R and O, and its reason is the chief\'s (rule Ch; I5, I9)', () => {
    const d = one({}, { evidence: { chief_placement: { reason: 'the release needs it', ts: '2026-11-22T09:00:00.000Z' } } });
    expect(placed(d)).toEqual({ outcome: 'ADMIT', op: 'add', from: null, to: C, ground: 'door:chief' });
    expect((d as RuledDecision).reason).toBe('the release needs it');
  });

  it('an operator ask goes to the version it names, to current when it names none, and is not placed on an undeclared one (rule A; I7)', () => {
    const bridge = { filed_by: 'bridge', operator_update: 7 };
    expect(placed(one({}, { to_v: N, evidence: bridge }))).toEqual({ outcome: 'ADMIT', op: 'add', from: null, to: N, ground: `door:operator-ask:${N}` });
    expect(placed(one({}, { to_v: null, evidence: bridge }))).toEqual({ outcome: 'ADMIT', op: 'add', from: null, to: C, ground: 'door:operator-ask' });
    expect(placed(one({}, { to_v: 'v1.2.0', evidence: bridge }))).toEqual({ outcome: 'BACKLOG', op: 'none', from: null, to: 'v1.2.0', ground: 'door:operator-undeclared:v1.2.0' });
    expect(placed(one({ labels: ['operator-directed'] }, { to_v: N }))).toEqual({ outcome: 'ADMIT', op: 'add', from: null, to: N, ground: `door:operator-ask:${N}` });
    expect(placed(one({ labels: ['operator-directed'], fixVersions: [C] }, { to_v: N }))).toEqual({ outcome: 'ADMIT', op: 'add', from: null, to: C, ground: `door:stays:${C}` });
  });
});

describe('rule A above rule S, and the apart test (decision 1187)', () => {
  const asked = (labels: string[], to_v: string | null, held: string[], parent?: Partial<IssueSnap>) => {
    const issues = [snap('K-2', { labels, fixVersions: held }), ...(parent ? [snap('K-1', parent)] : [])];
    return decide(input({ issues, required_parent: { 'K-2': 'K-1' } }), req('K-2', { to_v }));
  };
  const directed = ['operator-directed'];

  it('a remainder ask naming current, or no version, of a parent in the next version goes to current with the apart ground', () => {
    for (const to of [C, null]) {
      const d = asked(directed, to, [], { fixVersions: [N] });
      expect(placed(d)).toEqual({ outcome: 'ADMIT', op: 'add', from: null, to: C, ground: `door:operator-ask-apart:K-1@${N}` });
      expect((d as RuledDecision).reason).toContain(C);
      expect((d as RuledDecision).reason).toContain(N);
    }
    expect(placed(asked(directed, N, [], { fixVersions: [N] }))).toEqual({ outcome: 'ADMIT', op: 'add', from: null, to: N, ground: `door:operator-ask:${N}` });
  });

  it('a parent with no declared version is @none, a parent with no snapshot @unknown', () => {
    expect(asked(directed, C, [], { fixVersions: [] }).ground).toBe('door:operator-ask-apart:K-1@none');
    expect(asked(directed, C, []).ground).toBe('door:operator-ask-apart:K-1@unknown');
  });

  it('the stays row is checked for apart by the version the key holds', () => {
    expect(placed(asked(directed, N, [C], { fixVersions: [N] }))).toEqual({ outcome: 'ADMIT', op: 'add', from: null, to: C, ground: `door:operator-ask-apart:K-1@${N}` });
    expect(placed(asked(directed, N, [C], { fixVersions: [C] }))).toEqual({ outcome: 'ADMIT', op: 'add', from: null, to: C, ground: `door:stays:${C}` });
  });

  it('a remainder with no operator mark is rule S\'s, and goes with its parent', () => {
    expect(placed(asked([], C, [], { fixVersions: [N] }))).toEqual({ outcome: 'ADMIT', op: 'add', from: null, to: N, ground: 'door:rest-of:K-1' });
  });

  it('a rule A decision the operator-authority check turned into no change keeps its standing ground and is never apart', () => {
    const issues = [snap('K-2', { labels: directed, fixVersions: [N] }), snap('K-1', { fixVersions: [C] })];
    const inp = input({
      issues, required_parent: { 'K-2': 'K-1' }, records: [record('K-2', N, 'R-R-0001')],
      rulings: [operatorRuling('R-R-0001', '2026-11-20T00:00:00.000Z', N)], operator: [decisionRow('O-R-0001', '2026-11-19T00:00:00.000Z', 'add', null, N)],
    });
    expect(placed(decide(inp, req('K-2', { to_v: C })))).toEqual({ outcome: 'AD-HOC', op: 'none', from: null, to: C, ground: 'door:operator-standing:R-R-0001' });
  });
});

describe('the narrow rule S (decision 1170)', () => {
  it('a plain follow-up with no remainder mark is placed by its own priority, not with its parent', () => {
    const follow = req('K-2', { evidence: { follow_up_of: 'K-1' } });
    const required_parent = requiredParentOf([follow]);
    expect(required_parent).toEqual({});
    const parent = snap('K-1', { fixVersions: [C] });
    expect(placed(decide(input({ issues: [snap('K-2'), parent], required_parent }), follow))).toEqual({ outcome: 'ADMIT', op: 'add', from: null, to: N, ground: 'door:mild' });
    expect(placed(decide(input({ issues: [snap('K-2', { priority: 'High' }), parent], required_parent }), follow)))
      .toEqual({ outcome: 'ADMIT', op: 'add', from: null, to: C, ground: 'door:serious:High' });
  });

  it('the remainder of a closed parent still goes with it', () => {
    const rest = req('K-2', { evidence: { follow_up_of: 'K-1', remainder: true } });
    const required_parent = requiredParentOf([rest]);
    expect(required_parent).toEqual({ 'K-2': 'K-1' });
    const parent = snap('K-1', { fixVersions: [N], status: 'Done', statusCategory: 'Done', resolution: 'Done' });
    expect(decide(input({ issues: [snap('K-2'), parent], required_parent }), rest).ground).toBe('door:rest-of:K-1');
  });

  it('a withdrawn remainder request no longer requires its parent', () => {
    const rest = req('K-2', { evidence: { follow_up_of: 'K-1', remainder: true } });
    expect(requiredParentOf([rest, { ...rest, state: 'withdrawn:console' }])).toEqual({});
  });
});

describe('the clamp, one case per row', () => {
  it('no W and a version target: add', () => {
    expect(placed(one({}))).toMatchObject({ outcome: 'ADMIT', op: 'add', to: N });
  });
  it('no W and a backlog target: BACKLOG op none', () => {
    expect(placed(one({}, {}, { versions: [C] }))).toMatchObject({ outcome: 'BACKLOG', op: 'none' });
  });
  it('a key in the next version under rule W moves to current', () => {
    expect(placed(one({ fixVersions: [N], status: 'In Progress', statusCategory: 'In Progress' }))).toEqual({ outcome: 'ADMIT', op: 'move', from: N, to: C, ground: 'door:started' });
  });
  it('a key in the next version under rule H stays', () => {
    expect(placed(one({ fixVersions: [N], priority: 'High' }))).toEqual({ outcome: 'ADMIT', op: 'add', from: null, to: N, ground: `door:stays:${N}` });
  });
  it('a key in current with a mild target stays', () => {
    expect(placed(one({ fixVersions: [C] }, { to_v: N }))).toEqual({ outcome: 'ADMIT', op: 'add', from: null, to: C, ground: `door:stays:${C}` });
  });
});

describe('every "no change" INTAKE for a key that holds a version is AD-HOC op none (I13)', () => {
  it('the undeclared ask, the queued rule O row and the standing operator ruling', () => {
    expect(placed(one({ fixVersions: [C], labels: ['operator-directed'] }, { to_v: 'v1.2.0' }))).toMatchObject({ outcome: 'AD-HOC', op: 'none' });
    const keep = decisionRow('O-R-0002', '2026-11-21T00:00:00.000Z', 'keep', C, C);
    expect(placed(one({ fixVersions: [C] }, {}, { operator: [keep] }))).toMatchObject({ outcome: 'AD-HOC', op: 'none', ground: 'door:operator:O-R-0002' });
    const inp = {
      records: [record('K-2', N, 'R-R-0001')], rulings: [operatorRuling('R-R-0001', '2026-11-20T00:00:00.000Z', N)],
      operator: [decisionRow('O-R-0001', '2026-11-19T00:00:00.000Z', 'add', null, N)],
    };
    expect(placed(one({ fixVersions: [N], priority: 'High', status: 'In Progress', statusCategory: 'In Progress' }, {}, inp)))
      .toMatchObject({ outcome: 'AD-HOC', op: 'none', ground: 'door:operator-standing:R-R-0001' });
  });
});

describe('rule O, read by the request\'s verb', () => {
  const ts = '2026-11-21T00:00:00.000Z';
  const by = (verb: RequestRow['verb'], op: string, from_v: string | null, to_v: string | null, held: string[] = [], q: Partial<RequestRow> = {}) =>
    one({ fixVersions: held }, { verb, from_v: verb === 'INTAKE' ? null : (held[0] ?? null), to_v: C, ...q }, { operator: [decisionRow('O-R-0001', ts, op, from_v, to_v)] }) as RuledDecision;

  it('INTAKE: add and move-to-a-version admit, remove and move-out send to the backlog, keep and discharge queue their verb', () => {
    expect(by('INTAKE', 'add', null, N)).toMatchObject({ outcome: 'ADMIT', op: 'add', to: N, ground: 'door:operator:O-R-0001', authority: 'operator', ref: 'O-R-0001' });
    expect(by('INTAKE', 'remove', C, null, [C])).toMatchObject({ outcome: 'BACKLOG', op: 'remove', from: C, to: null });
    expect(by('INTAKE', 'move', C, null, [C])).toMatchObject({ outcome: 'BACKLOG', op: 'move', from: C, to: null });
    expect(by('INTAKE', 'keep', C, C, [C])).toMatchObject({ outcome: 'AD-HOC', op: 'none', queue: { verb: 'REVERSION', operator_record: 'O-R-0001' } });
    expect(by('INTAKE', 'discharge', C, C, [C])).toMatchObject({ outcome: 'AD-HOC', op: 'none', queue: { verb: 'DISCHARGE', operator_record: 'O-R-0001' } });
  });

  it('REVERSION: add moves in from nothing, move and remove move, keep keeps, discharge refuses and queues a DISCHARGE', () => {
    expect(by('REVERSION', 'add', null, N, [], { from_v: null })).toMatchObject({ outcome: 'MOVE', op: 'move', from: null, to: N });
    expect(by('REVERSION', 'move', C, N, [C])).toMatchObject({ outcome: 'MOVE', op: 'move', from: C, to: N });
    expect(by('REVERSION', 'remove', C, null, [C])).toMatchObject({ outcome: 'MOVE', op: 'remove', from: C, to: null });
    expect(by('REVERSION', 'keep', C, C, [C])).toMatchObject({ outcome: 'KEEP', op: 'keep' });
    expect(by('REVERSION', 'discharge', C, C, [C])).toMatchObject({ outcome: 'REFUSE', queue: { verb: 'DISCHARGE' } });
  });

  it('DISCHARGE: discharge accepts; another op rejects and queues its verb', () => {
    expect(by('DISCHARGE', 'discharge', C, C, [C], { to_v: C })).toMatchObject({ outcome: 'ACCEPT', op: 'discharge' });
    expect(by('DISCHARGE', 'add', null, C, [C], { to_v: C })).toMatchObject({ outcome: 'REJECT', op: 'none', queue: { verb: 'INTAKE' } });
  });

  it('a record older than the key\'s newest ruling is not followed, unless the request points at it', () => {
    const inp = { operator: [decisionRow('O-R-0001', '2026-11-19T00:00:00.000Z', 'add', null, N)], rulings: [operatorRuling('R-R-0001', '2026-11-20T00:00:00.000Z', C)] };
    expect(one({}, {}, inp).ground).toBe('door:mild');
    expect(one({}, { evidence: { operator_record: 'O-R-0001' } }, inp).ground).toBe('door:operator:O-R-0001');
  });
});

describe('REVERSION and DISCHARGE (Design 3)', () => {
  it('toward current: MOVE under the chief, else KEEP at the clamped target (I9 chief half, D-h)', () => {
    const q = { verb: 'REVERSION' as const, from_v: N, to_v: C };
    expect(placed(one({ fixVersions: [N], priority: 'High' }, { ...q, evidence: { chief_placement: { reason: 'pull it in' } } })))
      .toEqual({ outcome: 'MOVE', op: 'move', from: N, to: C, ground: 'door:chief' });
    expect(placed(one({ fixVersions: [N], priority: 'High' }, q))).toEqual({ outcome: 'KEEP', op: 'keep', from: N, to: N, ground: `door:target:${N}` });
    expect(placed(one({ fixVersions: [N], status: 'In Progress', statusCategory: 'In Progress' }, q))).toEqual({ outcome: 'MOVE', op: 'move', from: N, to: C, ground: 'door:started' });
  });

  it('away from a version: KEEP, only the operator moves a key out', () => {
    for (const to_v of [N, null]) {
      expect(placed(one({ fixVersions: [C] }, { verb: 'REVERSION', from_v: C, to_v }))).toEqual({ outcome: 'KEEP', op: 'keep', from: C, to: C, ground: 'door:only-operator-moves-out' });
    }
  });

  it('DISCHARGE of a resolved ticket is accepted, of an open one rejected', () => {
    const q = { verb: 'DISCHARGE' as const, from_v: C, to_v: C };
    expect(placed(one({ fixVersions: [C], status: 'Done', statusCategory: 'Done', resolution: 'Done' }, q))).toEqual({ outcome: 'ACCEPT', op: 'discharge', from: C, to: C, ground: 'door:resolved:Done' });
    expect(placed(one({ fixVersions: [C] }, q))).toEqual({ outcome: 'REJECT', op: 'none', from: C, to: C, ground: 'door:not-resolved' });
  });
});

describe('the repair lanes (rule R)', () => {
  const repair = (verb: RequestRow['verb'], from_v: string | null, to_v: string | null, held: string[] = []) =>
    placed(one({ fixVersions: held }, { verb, from_v, to_v, from: 'repair', evidence: { rule: 'version-repair' } }));

  it('lane 10 restores from nothing and from a later version, and keeps a key nearer current', () => {
    expect(repair('REVERSION', null, C)).toEqual({ outcome: 'MOVE', op: 'move', from: null, to: C, ground: 'door:repair' });
    expect(repair('REVERSION', N, C, [N])).toEqual({ outcome: 'MOVE', op: 'move', from: N, to: C, ground: 'door:repair' });
    expect(repair('REVERSION', C, N, [C])).toEqual({ outcome: 'MOVE', op: 'move', from: N, to: C, ground: 'door:repair-keeps' });
  });

  it('lane 11 adds the version Jira shows', () => {
    expect(repair('INTAKE', null, N)).toEqual({ outcome: 'ADMIT', op: 'add', from: null, to: N, ground: 'door:repair' });
  });
});

describe('the door never moves a key later or to the backlog except under rule O (I2, D-h)', () => {
  const kinds: Array<Partial<IssueSnap> & { evidence?: Record<string, unknown> }> = [
    {}, { priority: 'High' }, { status: 'In Progress', statusCategory: 'In Progress' }, { labels: ['operator-directed'] },
    { status: 'Done', statusCategory: 'Done', resolution: 'Done', evidence: { pr: 3 } }, { evidence: { chief_placement: { reason: 'r' } } },
  ];

  it('for every source version, verb and target', () => {
    let moves = 0;
    for (const held of [[C], [N], []]) {
      for (const { evidence, ...s } of kinds) {
        const asks: Array<Partial<RequestRow>> = [
          ...[C, N, null, 'v1.2.0'].map((to_v) => ({ verb: 'INTAKE' as const, from_v: null, to_v })),
          ...(held.length ? [N, C, null].map((to_v) => ({ verb: 'REVERSION' as const, from_v: held[0], to_v })) : []),
        ];
        for (const q of asks) {
          const d = one({ ...s, fixVersions: held }, { ...q, evidence: evidence ?? {} });
          if (d.outcome === 'REFUSE') continue;
          const r = d as RuledDecision;
          if (r.op === 'move' || r.op === 'remove') {
            moves++;
            expect(r.to, JSON.stringify({ held, s, q, r })).not.toBeNull();
            expect(earlierThan({ versions: VERSIONS }, r.to, r.from), JSON.stringify({ held, s, q, r })).toBe(true);
          }
          if (r.op === 'add' && held.length) expect(r.to, JSON.stringify({ held, s, q, r })).toBe(held[0]);
        }
      }
    }
    expect(moves).toBeGreaterThan(0);
  });
});

describe('doorJudge', () => {
  it('rules every request it is given, in order, with what doorDecide gives each', async () => {
    const requests = [req('K-2'), req('K-3', { req: 'Q-R-0002' }), req('K-4', { req: 'Q-R-0003', verb: 'REVERSION', from_v: C, to_v: null })];
    const inp = input({ requests, issues: [snap('K-2'), snap('K-3', { priority: 'High' }), snap('K-4', { fixVersions: [C] })] });
    const got = await doorJudge(inp);
    expect(got).toEqual(requests.map((q) => doorDecide(inp, q)));
    expect(got.map((d) => d.ground)).toEqual(['door:mild', 'door:serious:High', 'door:only-operator-moves-out']);
  });
});
