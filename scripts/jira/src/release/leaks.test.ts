import { describe, it, expect, vi } from 'vitest';
import type { Admission } from '../commands/admissions-ledger.js';
import { commentLeaks, leakDiff, leakLine, leakMarker } from './leaks.js';
import type { IssueSnap } from './types.js';

const snap = (key: string, fixVersions: string[], status = 'In Progress', resolution: string | null = null): IssueSnap =>
  ({ key, status, type: 'Task', priority: 'Medium', fixVersions, resolution });
const mirror = (...issues: IssueSnap[]) => new Map(issues.map((i) => [i.key, i]));
const row = (key: string, kind?: Admission['kind'], version = 'v1.1.3'): Admission =>
  ({ ts: '2026-10-23T00:00:00.000Z', version, key, kind, actor: 'console' });

// The 24 tickets v1.1.3 leaked after its 10-20 freeze.
const LEAKED = [7146, 7145, 7135, 7121, 7120, 7119, 7118, 7117, 7116, 7104, 7030, 7009, 7006, 7004, 7003, 7002, 7001, 7000, 6998, 6995, 6991, 6874, 6836, 6833]
  .map((n) => `HIMMEL-${n}`);

describe('leakDiff (HIMMEL-7153)', () => {
  it('lists the open tickets that are in neither the frozen set nor the ledger', () => {
    const issues = mirror(snap('HIMMEL-1', ['v1.1.3']), ...LEAKED.map((k) => snap(k, ['v1.1.3'])));
    expect(leakDiff('v1.1.3', ['HIMMEL-1'], issues, [])).toEqual([...LEAKED].sort());
  });

  it('skips a ticket admitted by a gate, an override or an rm-admit row', () => {
    const issues = mirror(snap('K-1', ['v']), snap('K-2', ['v']), snap('K-3', ['v']), snap('K-4', ['v']));
    const ledger = [
      { ...row('K-1', undefined, 'v'), gate: 'critical' },
      row('K-2', 'override', 'v'),
      row('K-3', 'rm-admit', 'v'),
    ];
    expect(leakDiff('v', [], issues, ledger)).toEqual(['K-4']);
  });

  it('a deferral or removal after an admission withdraws it, and the key leaks again', () => {
    const issues = mirror(snap('K-1', ['v']), snap('K-2', ['v']));
    const ledger = [row('K-1', 'rm-admit', 'v'), row('K-1', 'rm-remove', 'v'), row('K-2', 'override', 'v'), row('K-2', 'deferral', 'v')];
    expect(leakDiff('v', [], issues, ledger)).toEqual(['K-1', 'K-2']);
  });

  it('ignores a ledger row of another version and a row keyed by a check id', () => {
    const issues = mirror(snap('K-1', ['v']), snap('K-2', ['v']));
    expect(leakDiff('v', [], issues, [row('K-1', 'override', 'other'), row('frozen-set', 'override', 'v')])).toEqual(['K-1', 'K-2']);
  });

  it('skips Done, Won\'t Do and Duplicate tickets and tickets of another version', () => {
    const issues = mirror(
      snap('K-1', ['v'], 'Done'),
      snap('K-2', ['v'], 'Closed', "Won't Do"),
      snap('K-3', ['v'], 'Closed', 'Duplicate'),
      snap('K-4', ['w']),
      snap('K-5', ['v', 'w']),
    );
    expect(leakDiff('v', [], issues, [])).toEqual(['K-5']);
  });
});

describe('commentLeaks (HIMMEL-7153)', () => {
  it('posts one comment per leak and none where the marker is already there', async () => {
    const jira = {
      findComment: vi.fn(async (key: string) => (key === 'K-2' ? 'c-9' : null)),
      addComment: vi.fn(async () => 'c-1'),
    };
    expect(await commentLeaks(jira, ['K-1', 'K-2', 'K-3'], 'v', '2026-10-20')).toEqual(['K-1', 'K-3']);
    expect(jira.findComment).toHaveBeenCalledWith('K-1', leakMarker('v'));
    expect(jira.addComment).toHaveBeenCalledTimes(2);
    expect(jira.addComment).toHaveBeenCalledWith('K-1', expect.stringContaining('[intake-leak v] K-1 carries v, frozen 2026-10-20'));
  });

  it('prints one console line per leak', () => {
    expect(leakLine('K-1', 'v', '2026-10-20')).toBe(
      'LEAK K-1@v — carries v (frozen 2026-10-20) with no frozen-set membership and no admissions-ledger row',
    );
  });
});
