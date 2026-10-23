import { describe, it, expect } from 'vitest';
import { chainLine, parseChain, sha256, GENESIS } from './ledger.js';
import { reduce, authorizes, recordOf, type ReduceInput } from './reducer.js';
import type { Baseline, Declaration, EventRow, IssueSnap, OperatorRow, RulingRow } from './types.js';

const KEY = Buffer.alloc(32, 7);
const TS = '2026-10-21T10:00:00.000Z';

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
  project: 'HIMMEL', release: 'R1', versions: ['v1', 'v2'], current: 'v1', mode: 'observe', decision: '106', ts: TS,
};
const base: Baseline = { release: 'R1', version: 'v1', gen: 1, keys: ['K-1'], decision: '104', ts: TS };

function rule(id: string, key: string, kind: RulingRow['op']['kind'], from_v: string | null, to_v: string | null,
  extra: Partial<RulingRow> = {}): RulingRow {
  return {
    id, epoch: 1, req: `Q-${id}`, ts: TS, verb: 'INTAKE', key, op: { kind, from_v, to_v }, outcome: 'ADMIT',
    class: 'current', sector: 'Planning & tracking', ground: 'regression', reason: 'r', supersedes: [],
    authority: { kind: 'rm', ref: null }, phase: 'applied', ...extra,
  };
}
const issue = (key: string, fixVersions: string[], status = 'To Do', extra: Partial<IssueSnap> = {}): IssueSnap =>
  ({ key, status, type: 'Task', priority: 'Medium', fixVersions, resolution: null, ...extra });
const closed = (key: string, fixVersions: string[], resolution: string | null = 'Done'): IssueSnap =>
  issue(key, fixVersions, 'Closed', { statusCategory: 'Done', resolution });

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
    mirrorSync: TS,
    ...over,
  };
}

describe('release reducer (HIMMEL-6796)', () => {
  it('a baseline key starts in with a baseline obligation', () => {
    const s = reduce(input({}));
    expect(recordOf(s, 'K-1', 'v1')).toMatchObject({ placement: 'in', obligation: 'baseline', ruling: 'baseline-v1-g1' });
    expect(s.leaks.unauthorized).toEqual([]);
  });

  it('an old ADMIT does not survive the MOVE that supersedes it', () => {
    const s = reduce(input({
      rulingRows: [
        rule('R-1', 'K-2', 'add', null, 'v1'),
        rule('R-2', 'K-2', 'move', 'v1', 'v2', { verb: 'REVERSION', outcome: 'MOVE', supersedes: ['R-1'] }),
      ],
      issueList: [issue('K-1', ['v1']), issue('K-2', ['v2'])],
    }));
    expect(recordOf(s, 'K-2', 'v1')).toMatchObject({ placement: 'out', ruling: 'R-2' });
    expect(recordOf(s, 'K-2', 'v2')).toMatchObject({ placement: 'in', ruling: 'R-2', obligation: 'admitted' });
    expect(authorizes(s, 'K-2', null, 'v1', 'add')).toBe(false);
    expect(authorizes(s, 'K-2', 'v1', 'v2', 'move')).toBe(true);
  });

  it('an intent is pending, never authority', () => {
    const s = reduce(input({ rulingRows: [rule('R-1', 'K-2', 'add', null, 'v1', { phase: 'intent' })] }));
    expect(recordOf(s, 'K-2', 'v1')?.placement).toBe('pending');
    expect(authorizes(s, 'K-2', null, 'v1', 'add')).toBe(false);
  });

  it('a baseline key moved out does not come back with the baseline; a re-add is a leak', () => {
    const moved = rule('R-1', 'K-1', 'move', 'v1', null, { verb: 'REVERSION', outcome: 'MOVE', supersedes: ['baseline-v1-g1'] });
    const s = reduce(input({ rulingRows: [moved] }));
    expect(recordOf(s, 'K-1', 'v1')).toMatchObject({ placement: 'out', obligation: 'none' });
    expect(s.leaks.unauthorized).toEqual(['K-1@v1']);
    expect(s.burndown.v1).toMatchObject({ baseline: 1, baseline_open: 0, deferred_out: 1 });

    const back = reduce(input({ rulingRows: [moved, rule('R-2', 'K-1', 'add', null, 'v1', { supersedes: ['R-1'] })] }));
    expect(recordOf(back, 'K-1', 'v1')).toMatchObject({ placement: 'in', obligation: 'admitted', ruling: 'R-2' });
    expect(back.leaks.unauthorized).toEqual([]);
  });

  it('a newer baseline generation is the latest word on the keys it lists', () => {
    const moved = rule('R-1', 'K-1', 'move', 'v1', null, { verb: 'REVERSION', outcome: 'MOVE', supersedes: ['baseline-v1-g1'] });
    const g2: Baseline = { ...base, gen: 2, keys: ['K-1', 'K-2'], ts: '2026-10-21T11:00:00.000Z' };
    const s = reduce(input({
      baselines: [g2], rulingRows: [moved, rule('R-2', 'K-2', 'add', null, 'v1')],
      issueList: [issue('K-1', ['v1']), issue('K-2', ['v1'])],
    }));
    expect(s.integrity).toEqual([]);
    expect(recordOf(s, 'K-1', 'v1')).toMatchObject({ placement: 'in', obligation: 'baseline', ruling: 'baseline-v1-g2' });
    expect(recordOf(s, 'K-2', 'v1')).toMatchObject({ placement: 'in', obligation: 'baseline', ruling: 'baseline-v1-g2' });
    expect(s.leaks.unauthorized).toEqual([]);
  });

  it('an unapplied intent stays pending under a newer baseline listing its key', () => {
    const moving = rule('R-1', 'K-1', 'move', 'v1', null, { verb: 'REVERSION', outcome: 'MOVE', phase: 'intent' });
    const g2: Baseline = { ...base, gen: 2, ts: '2026-10-21T11:00:00.000Z' };
    const s = reduce(input({ baselines: [g2], rulingRows: [moving] }));
    expect(recordOf(s, 'K-1', 'v1')?.placement).toBe('pending');
  });

  it('an intent applied after a newer baseline counts against it', () => {
    const extra = { verb: 'REVERSION' as const, outcome: 'MOVE', supersedes: ['baseline-v1-g1'] };
    const g2: Baseline = { ...base, gen: 2, ts: '2026-10-21T11:00:00.000Z' };
    const s = reduce(input({
      baselines: [g2],
      rulingRows: [rule('R-1', 'K-1', 'move', 'v1', null, { ...extra, phase: 'intent' }),
        rule('R-1', 'K-1', 'move', 'v1', null, { ...extra, ts: '2026-10-21T12:00:00.000Z' })],
    }));
    expect(s.integrity).toEqual(['K-1@v1: two live rulings (R-1, baseline-v1-g2)']);
  });

  it('a failed apply readback is not counted as a ruling in the trend', () => {
    const ev = (readback: 'ok' | 'mismatch'): EventRow =>
      ({ ts: TS, kind: 'ruled', key: 'K-1', from: null, to: 'v1', ruling: 'R-1', readback });
    const s = reduce(input({ eventRows: [ev('mismatch'), ev('mismatch'), ev('ok')] }));
    expect(s.trend['2026-10-21']).toEqual({ ruled: 1 });
  });

  it('moving one baseline key out leaves the rest of the baseline in', () => {
    const moved = rule('R-1', 'K-1', 'move', 'v1', null, { verb: 'REVERSION', outcome: 'MOVE', supersedes: ['baseline-v1-g1'] });
    const s = reduce(input({
      baselines: [{ ...base, keys: ['K-1', 'K-3'] }], rulingRows: [moved],
      issueList: [issue('K-1', []), issue('K-3', ['v1'])],
    }));
    expect(recordOf(s, 'K-3', 'v1')).toMatchObject({ placement: 'in', obligation: 'baseline', ruling: 'baseline-v1-g1' });
    expect(s.leaks.unauthorized).toEqual([]);
  });

  it('a placed key missing from a synced mirror is an integrity finding', () => {
    const s = reduce(input({ rulingRows: [rule('R-1', 'K-2', 'add', null, 'v1')] }));
    expect(s.integrity).toContain('K-2@v1: not in the Jira mirror');
  });

  it('authorizes only the exact key, versions and operation', () => {
    const s = reduce(input({ rulingRows: [rule('R-1', 'K-2', 'add', null, 'v2')], issueList: [issue('K-1', ['v1']), issue('K-2', ['v2'])] }));
    expect(authorizes(s, 'K-2', null, 'v2', 'add')).toBe(true);
    expect(authorizes(s, 'K-3', null, 'v2', 'add')).toBe(false);
    expect(authorizes(s, 'K-2', null, 'v1', 'add')).toBe(false);
    expect(authorizes(s, 'K-2', 'v1', 'v2', 'move')).toBe(false);
  });

  it('an operator ruling citing an unrelated decision record is UNKNOWN', () => {
    const oRow: OperatorRow = { id: 'O-R1-0002', kind: 'decision', ts: TS, decision: '101', keys: ['K-9'], op: 'add', from_v: null, to_v: 'v1' };
    const cited = rule('R-1', 'K-2', 'add', null, 'v1', { authority: { kind: 'operator', ref: 'O-R1-0002' } });
    const s = reduce(input({ opRows: [oRow], rulingRows: [cited] }));
    expect(recordOf(s, 'K-2', 'v1')?.placement).toBe('unknown');
    expect(s.integrity.join('\n')).toMatch(/O-R1-0002/);

    const scoped = reduce(input({ opRows: [{ ...oRow, keys: ['K-2'] }], rulingRows: [cited], issueList: [issue('K-1', ['v1']), issue('K-2', ['v1'])] }));
    expect(recordOf(scoped, 'K-2', 'v1')?.placement).toBe('in');
  });

  it('two live rulings for one key and version are UNKNOWN', () => {
    const s = reduce(input({ rulingRows: [rule('R-1', 'K-2', 'add', null, 'v1'), rule('R-2', 'K-2', 'add', null, 'v1')] }));
    expect(recordOf(s, 'K-2', 'v1')?.placement).toBe('unknown');
  });

  it('a broken chain makes every key from that row onward UNKNOWN', () => {
    const text = chainText([rule('R-1', 'K-2', 'add', null, 'v1'), rule('R-2', 'K-3', 'add', null, 'v1')]);
    const tampered = text.replace('"reason":"r"', '"reason":"x"');
    const s = reduce(input({ rulings: parseChain<RulingRow>(tampered, KEY) }));
    expect(recordOf(s, 'K-2', 'v1')?.placement).toBe('unknown');
    expect(recordOf(s, 'K-3', 'v1')?.placement).toBe('unknown');
    expect(s.integrity.length).toBeGreaterThan(0);
  });

  it('an unparseable ledger line makes the whole state UNKNOWN', () => {
    const text = `${chainText([rule('R-1', 'K-2', 'add', null, 'v1')])}{truncated\n`;
    expect(reduce(input({ rulings: parseChain<RulingRow>(text, KEY) })).status).toBe('UNKNOWN');
  });

  it('a Jira membership with no ledger row is a leak, whatever a comment claims', () => {
    const s = reduce(input({ issueList: [issue('K-1', ['v1']), issue('K-7', ['v1'])] }));
    expect(s.leaks.unauthorized).toEqual(['K-7@v1']);
    expect(authorizes(s, 'K-7', null, 'v1', 'add')).toBe(false);
  });

  it('a ruled-in key missing from Jira is a ruled-in non-member', () => {
    const s = reduce(input({ rulingRows: [rule('R-1', 'K-2', 'add', null, 'v1')], issueList: [issue('K-1', ['v1']), issue('K-2', [])] }));
    expect(s.leaks.ruled_in_non_member).toEqual(['K-2@v1']);
  });

  it('stale or missing inputs are UNKNOWN, never a clean result', () => {
    const none = reduce(input({ issues: null }));
    expect(none.inputs.mirror).toBe('UNKNOWN');
    expect(recordOf(none, 'K-1', 'v1')?.actual_member).toBe('unknown');
    expect(none.leaks.unauthorized).toEqual([]);

    const ev: EventRow = { ts: '2026-10-21T11:00:00.000Z', kind: 'ruled', key: 'K-7', from: null, to: 'v1', readback: 'ok' };
    const stale = reduce(input({ eventRows: [ev], issueList: [issue('K-1', ['v1']), issue('K-7', ['v1'])] }));
    expect(stale.inputs.mirror).toBe('STALE');
    expect(recordOf(stale, 'K-7', 'v1')?.actual_member).toBe('unknown');
    expect(stale.leaks.unauthorized).toEqual([]);
  });

  it('a fold event makes a Done key bookkeeping until a reopen', () => {
    const fold: EventRow = { ts: TS, kind: 'fold', key: 'K-5', from: null, to: 'v1', pr: 12, sha: 'abc' };
    const done = [issue('K-1', ['v1']), issue('K-5', ['v1'], 'Done')];
    const s = reduce(input({ eventRows: [fold], issueList: done, mirrorSync: '2026-10-21T12:00:00.000Z' }));
    expect(recordOf(s, 'K-5', 'v1')?.bookkeeping).toBe('fold:12');
    expect(s.leaks.unauthorized).toEqual([]);

    const reopen: EventRow = { ts: '2026-10-21T11:00:00.000Z', kind: 'reopen', key: 'K-5', from: null, to: null };
    const r = reduce(input({ eventRows: [fold, reopen], issueList: done, mirrorSync: '2026-10-21T12:00:00.000Z' }));
    expect(r.leaks.unauthorized).toEqual(['K-5@v1']);
  });

  it('a Closed key in the Done status category is terminal Done, and a fold makes it bookkeeping (HIMMEL-7158)', () => {
    const fold: EventRow = { ts: TS, kind: 'fold', key: 'K-5', from: null, to: 'v1', pr: 12 };
    const issueList = [closed('K-1', ['v1']), closed('K-5', ['v1'], null)];
    const s = reduce(input({ eventRows: [fold], issueList, mirrorSync: '2026-10-21T12:00:00.000Z' }));
    expect(recordOf(s, 'K-1', 'v1')?.terminal).toBe('Done');
    expect(s.burndown.v1.baseline_open).toBe(0);
    expect(recordOf(s, 'K-5', 'v1')).toMatchObject({ terminal: 'Done', bookkeeping: 'fold:12' });
    expect(s.leaks.unauthorized).toEqual([]);
  });

  it('a Closed key with a resolution outside empty, Done and Fixed is terminal but never folds (HIMMEL-7158)', () => {
    const fold: EventRow = { ts: TS, kind: 'fold', key: 'K-5', from: null, to: 'v1', pr: 12 };
    for (const resolution of ['Cannot Reproduce', 'Obsolete', 'Never Seen Before']) {
      const issueList = [issue('K-1', ['v1']), closed('K-5', ['v1'], resolution)];
      const s = reduce(input({ eventRows: [fold], issueList, mirrorSync: '2026-10-21T12:00:00.000Z' }));
      expect(recordOf(s, 'K-5', 'v1')).toMatchObject({ terminal: 'Other', bookkeeping: null });
      expect(s.leaks.unauthorized).toEqual(['K-5@v1']);
    }
  });

  it('a Done-status key resolved outside empty, Done and Fixed is terminal Other, never Done (HIMMEL-7158)', () => {
    const s = reduce(input({ issueList: [issue('K-1', ['v1']), issue('K-5', ['v1'], 'Done', { resolution: 'Cannot Reproduce' })] }));
    expect(recordOf(s, 'K-5', 'v1')?.terminal).toBe('Other');
  });

  it('a Closed key resolved Won\'t Do or Duplicate keeps its own terminal and never folds (HIMMEL-7158)', () => {
    const issueList = [issue('K-1', ['v1']), closed('K-5', ['v1'], "Won't Do"), closed('K-6', ['v1'], 'Duplicate')];
    const s = reduce(input({ issueList }));
    expect(recordOf(s, 'K-5', 'v1')?.terminal).toBe("Won't Do");
    expect(recordOf(s, 'K-6', 'v1')?.terminal).toBe('Duplicate');
  });

  it('burn-down counts baseline and admitted open keys per version', () => {
    const s = reduce(input({
      rulingRows: [rule('R-1', 'K-2', 'add', null, 'v1')],
      issueList: [issue('K-1', ['v1'], 'Done'), issue('K-2', ['v1'])],
    }));
    expect(s.burndown.v1).toEqual({ baseline: 1, baseline_open: 0, admitted_open: 1, emergency_open: 0, deferred_out: 0 });
  });
});
