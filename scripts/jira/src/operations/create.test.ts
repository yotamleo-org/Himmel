import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { Command } from 'commander';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

vi.mock('../client.js', async (orig) => ({
  ...(await orig<typeof import('../client.js')>()),
  request: vi.fn(),
  projectKey: () => 'HIMMEL',
}));
vi.mock('../breadcrumb.js', () => ({ writeJiraBreadcrumb: vi.fn() }));

import { request } from '../client.js';
import { registerRelease } from '../commands/release.js';
import { PLAIN_BLOCK_TEMPLATE } from '../plain-block.js';
import { CreatePartial, CreateRefused, runCreate, type CreateOptions } from './create.js';

const mockRequest = request as unknown as ReturnType<typeof vi.fn>;
const BODY = PLAIN_BLOCK_TEMPLATE.replace(/<[^>\n]*>/g, 'filled');
const task = (o: Partial<CreateOptions> = {}): CreateOptions => ({
  type: 'Task', title: 'Planning & tracking: a ticket', desc: BODY, labels: 'standalone', attach: [], blocks: [],
  backlog: true, proposedVersion: 'backlog', why: 'waits for the test', ...o,
});
const mutations = () => mockRequest.mock.calls.filter((c) => c[0] !== 'GET');

let root: string;
beforeEach(async () => {
  vi.clearAllMocks();
  vi.spyOn(console, 'log').mockImplementation(() => {});
  vi.spyOn(console, 'error').mockImplementation(() => {});
  root = mkdtempSync(join(tmpdir(), 'op-create-'));
  vi.stubEnv('HIMMEL_RELEASE_STATE_DIR', join(root, 'state'));
  vi.stubEnv('HIMMEL_RELEASE_KEY_DIR', join(root, 'keys'));
  vi.stubEnv('HIMMEL_RELEASE_MANAGER', '');
  vi.stubEnv('HIMMEL_CONSOLE_LEG', '');
  vi.stubEnv('JIRA_BASE_URL', 'http://127.0.0.1:9');
  writeFileSync(join(root, 'verbatim.txt'), 'R1 = v1.1.3\n');
  const p = new Command();
  p.exitOverride();
  registerRelease(p);
  await p.parseAsync(['node', 'jira', 'release', 'operator', 'declare', 'R1', '--versions', 'v1.1.3', '--decision', '214', '--verbatim-file', join(root, 'verbatim.txt')]);
  mockRequest.mockReset();
  mockRequest.mockResolvedValue({ key: 'HIMMEL-1' });
});
afterEach(() => {
  vi.unstubAllEnvs();
  process.exitCode = undefined;
  rmSync(root, { recursive: true, force: true });
});

describe('runCreate', () => {
  it('prints the browse: link on the line right after Created KEY when a site URL is set', async () => {
    await runCreate(task());
    const printed = vi.mocked(console.log).mock.calls.map((c) => String(c[0]));
    const at = printed.indexOf('Created HIMMEL-1');
    expect(at).toBeGreaterThanOrEqual(0);
    expect(printed[at + 1]).toBe('browse: http://127.0.0.1:9/browse/HIMMEL-1');
  });

  it('control: no site URL set prints Created KEY alone, with no browse: line', async () => {
    mockRequest.mockImplementation(async () => {
      vi.stubEnv('JIRA_BASE_URL', undefined as unknown as string);
      return { key: 'HIMMEL-1' };
    });
    await runCreate(task());
    const printed = vi.mocked(console.log).mock.calls.map((c) => String(c[0]));
    expect(printed).toContain('Created HIMMEL-1');
    expect(printed.some((l) => l.startsWith('browse:'))).toBe(false);
  });

  it('check mode runs every check and writes nothing', async () => {
    await expect(runCreate(task(), { check: true })).resolves.toEqual({ disposition: 'checked' });
    expect(mutations()).toEqual([]);
  });

  it('check mode still refuses a body that fails the standard', async () => {
    await expect(runCreate(task({ desc: BODY.replace(/## Proof\nfilled\n\n/, '') }), { check: true })).rejects.toBeInstanceOf(CreateRefused);
  });

  it('a create whose answer is lost is OUTCOME UNKNOWN, sent once and never retried', async () => {
    mockRequest.mockImplementation(async (m: string, p: string) => {
      if (m === 'POST' && p === '/issue') throw new Error('fetch failed: socket hang up');
      return {};
    });
    await expect(runCreate(task())).rejects.toThrow(/OUTCOME UNKNOWN.*may exist/s);
    expect(mockRequest.mock.calls.filter((c) => c[0] === 'POST' && c[1] === '/issue')).toHaveLength(1);
  });

  it('a 4xx answer is a plain refusal from Jira, not an unknown outcome', async () => {
    mockRequest.mockImplementation(async (m: string, p: string) => {
      if (m === 'POST' && p === '/issue') throw new Error('HTTP 400: bad field');
      return {};
    });
    await expect(runCreate(task())).rejects.toThrow(/^HTTP 400/);
  });

  it('a link that fails after the create is PARTIAL with the key and the steps still owed', async () => {
    mockRequest.mockImplementation(async (m: string, p: string) => {
      if (m === 'POST' && p === '/issue') return { key: 'HIMMEL-7' };
      if (m === 'POST' && p === '/issueLink') throw new Error('HTTP 500');
      return {};
    });
    const run = runCreate(task({ blocks: ['HIMMEL-2', 'HIMMEL-3'] }));
    await expect(run).rejects.toBeInstanceOf(CreatePartial);
    await expect(run).rejects.toThrow(/PARTIAL: Created HIMMEL-7 but linking HIMMEL-7 to HIMMEL-2 failed.*still owed: linking HIMMEL-7 to HIMMEL-3/s);
  });
});
