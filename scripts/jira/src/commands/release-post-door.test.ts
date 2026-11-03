import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

// The guard's exit code is the only thing the post door reads: stub the one spawn it makes.
const guard = vi.hoisted(() => ({ status: 0 as number | null, calls: [] as string[][] }));
vi.mock('node:child_process', async (orig) => {
  const m = await orig<typeof import('node:child_process')>();
  const spawnSync = ((cmd: string, args: string[]) => {
    guard.calls.push([cmd, ...args]);
    return { status: guard.status, signal: null, output: [], pid: 0, stdout: null, stderr: null };
  }) as unknown as typeof m.spawnSync;
  return { ...m, spawnSync };
});

import { refuseTestJiraPost, refuseTestKeyMint } from './release.js';

describe('refuseTestKeyMint reads only exit 77 from the guard', () => {
  beforeEach(() => {
    guard.calls.length = 0;
  });
  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it('asks about the default key as real: homedir() follows a fixture HOME', () => {
    vi.stubEnv('HIMMEL_RELEASE_KEY_DIR', undefined as unknown as string);
    guard.status = 0;
    refuseTestKeyMint('R1');
    const args = guard.calls[0] as string[];
    expect(args).toContain('--real');
    expect(args[args.length - 1]).toMatch(/\.config\/himmel\/release\/R1\.key$/);
  });

  it('lets the path decide when a key dir is named', () => {
    vi.stubEnv('HIMMEL_RELEASE_KEY_DIR', '/tmp/named-keys');
    guard.status = 0;
    refuseTestKeyMint('R1');
    const args = guard.calls[0] as string[];
    expect(args).not.toContain('--real');
    expect(args[args.length - 1]).toBe('/tmp/named-keys/R1.key');
  });

  it.each([0, 1, 127, null])('lets a guard that exits %s through (a guard fault never stops a real mint)', (status) => {
    guard.status = status;
    expect(() => refuseTestKeyMint('R1')).not.toThrow();
  });

  it('refuses on exit 77', () => {
    guard.status = 77;
    expect(() => refuseTestKeyMint('R1')).toThrow(/release operator declare: refused, nothing was written/);
  });
});

describe('refuseTestJiraPost reads only exit 77 from the guard', () => {
  beforeEach(() => {
    guard.calls.length = 0;
    vi.stubEnv('JIRA_BASE_URL', 'http://jira.invalid');
  });
  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it.each([1, 127, null])('lets a guard that exits %s through (a guard fault never stops a real post)', (status) => {
    guard.status = status;
    expect(() => refuseTestJiraPost('create')).not.toThrow();
    expect(guard.calls.length).toBe(1);
  });

  it('lets exit 0 through', () => {
    guard.status = 0;
    expect(() => refuseTestJiraPost('create')).not.toThrow();
    expect(guard.calls.length).toBe(1);
  });

  it('refuses on exit 77', () => {
    guard.status = 77;
    expect(() => refuseTestJiraPost('create')).toThrow(/create: refused, nothing was posted/);
  });

  it('never asks the guard for a loopback Jira', () => {
    vi.stubEnv('JIRA_BASE_URL', 'http://127.0.0.1:9');
    guard.status = 77;
    expect(() => refuseTestJiraPost('create')).not.toThrow();
    expect(guard.calls.length).toBe(0);
  });
});
