import { describe, it, expect, afterEach, vi } from 'vitest';
import { browseLine } from './browse-line.js';

describe('browseLine', () => {
  afterEach(() => vi.unstubAllEnvs());

  it('is the site URL, /browse/ and the key', () => {
    vi.stubEnv('JIRA_BASE_URL', 'https://station.atlassian.net');
    expect(browseLine('HIMMEL-1')).toBe('browse: https://station.atlassian.net/browse/HIMMEL-1');
  });

  it('control: no site URL gives no line and does not throw', () => {
    vi.stubEnv('JIRA_BASE_URL', undefined as unknown as string);
    expect(browseLine('HIMMEL-1')).toBeUndefined();
  });
});
