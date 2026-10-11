import { describe, it, expect } from 'vitest';
import { assertLiveProject } from './project-guard.js';

describe('assertLiveProject (HIMMEL-4642)', () => {
  it('accepts a dedicated test project key', () => {
    expect(() => assertLiveProject('HTEST')).not.toThrow();
    expect(() => assertLiveProject('H2_TEST')).not.toThrow();
  });

  it.each(['HIMMEL', 'himmel', 'hIMMEL', 'Himmel'])('refuses %s as the real backlog, any case', (p) => {
    expect(() => assertLiveProject(p)).toThrow(/never HIMMEL/);
  });

  it.each(['', 'htest', '1TEST', 'H', 'HT EST', 'HTEST-1', '-HTEST'])('refuses %j: not a valid project key', (p) => {
    expect(() => assertLiveProject(p)).toThrow();
  });
});
