import { describe, it, expect } from 'vitest';
import { createTeardown } from './teardown.js';

describe('createTeardown (HIMMEL-4642)', () => {
  it('closes every tracked issue and archives every tracked version', () => {
    const closed: string[] = [];
    const archived: string[] = [];
    const t = createTeardown({ closeIssue: (k) => closed.push(k), archiveVersion: (n) => archived.push(n) });
    t.trackIssue('HTEST-1');
    t.trackIssue('HTEST-2');
    t.trackVersion('live-abc');
    expect(t.run()).toEqual([]);
    expect(closed).toEqual(['HTEST-1', 'HTEST-2']);
    expect(archived).toEqual(['live-abc']);
  });

  it('keeps going after one cleanup throws and reports each failure', () => {
    const closed: string[] = [];
    const t = createTeardown({
      closeIssue: (k) => {
        if (k === 'HTEST-1') throw new Error('boom');
        closed.push(k);
      },
      archiveVersion: () => {},
    });
    t.trackIssue('HTEST-1');
    t.trackIssue('HTEST-2');
    const failures = t.run();
    expect(closed).toEqual(['HTEST-2']);
    expect(failures).toHaveLength(1);
    expect(failures[0]).toMatch(/HTEST-1.*boom/);
  });

  it('is a no-op when nothing was created', () => {
    const t = createTeardown({
      closeIssue: () => {
        throw new Error('unexpected');
      },
      archiveVersion: () => {
        throw new Error('unexpected');
      },
    });
    expect(t.run()).toEqual([]);
  });
});
