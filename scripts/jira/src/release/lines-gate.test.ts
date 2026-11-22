import { describe, it, expect, vi } from 'vitest';
import { chainLine, parseChain, sha256, GENESIS } from './ledger.js';
import type * as LinesMod from './lines.js';
import type { Baseline, Declaration, IssueSnap, RulingRow } from './types.js';

const swap = vi.hoisted(() => ({ stub: false }));
vi.mock('./lines.js', async (orig) => {
  const real = await orig<typeof LinesMod>();
  return {
    ...real,
    linesOf: (i: LinesMod.LinesInput) => (swap.stub
      ? Object.fromEntries(i.decl.versions.map((v) => [v, { status: 'UNKNOWN', reason: 'stub' }]))
      : real.linesOf(i)),
  };
});
const { reduce } = await import('./reducer.js');

const KEY = Buffer.alloc(32, 7);
const TS = '2026-10-01T10:00:00.000Z';
function chain<T>(rows: object[]) {
  let head = GENESIS;
  let text = '';
  for (const r of rows) {
    const line = chainLine(head, KEY, r as Record<string, unknown>);
    text += `${line}\n`;
    head = sha256(line);
  }
  return parseChain<T>(text, KEY);
}

describe('version lines gate nothing', () => {
  it('reduce() with a different version_lines gives the same state outside that field', () => {
    const decl: Declaration = { project: 'HIMMEL', release: 'R1', versions: ['v1'], current: 'v1', mode: 'observe', decision: '1', ts: TS };
    const base: Baseline = { release: 'R1', version: 'v1', gen: 1, keys: ['K-1'], decision: '1', ts: TS };
    const ruling: RulingRow = {
      id: 'R-1', epoch: 1, req: 'Q-1', ts: TS, verb: 'INTAKE', key: 'K-2', op: { kind: 'add', from_v: null, to_v: 'v1' }, outcome: 'ADMIT',
      class: 'current', sector: 's', ground: 'regression', reason: 'r', supersedes: [], authority: { kind: 'rm', ref: null }, phase: 'applied',
    };
    const issue = (key: string): IssueSnap => ({ key, status: 'To Do', type: 'Task', priority: 'High', fixVersions: ['v1'], resolution: null });
    const inp = () => ({
      decl, baselines: [base], rulings: chain<RulingRow>([ruling]), operator: chain([]), events: chain([]),
      issues: new Map([['K-1', issue('K-1')], ['K-2', issue('K-2')], ['K-3', issue('K-3')]]), mirrorSync: TS,
    });
    swap.stub = false;
    const real = reduce(inp() as never);
    swap.stub = true;
    const stubbed = reduce(inp() as never);
    expect(stubbed.version_lines).not.toEqual(real.version_lines);
    const { version_lines: _r, ...restReal } = real;
    const { version_lines: _s, ...restStub } = stubbed;
    expect(restStub).toEqual(restReal);
  });
});
