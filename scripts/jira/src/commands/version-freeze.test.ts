import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { Command } from 'commander';

vi.mock('../client.js', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../client.js')>();
  return { ...actual, request: vi.fn() };
});
vi.mock('./admissions-ledger.js', () => ({ appendAdmission: vi.fn(), readAdmissions: vi.fn(() => []) }));

import { request } from '../client.js';
import { appendAdmission, readAdmissions } from './admissions-ledger.js';
import { registerVersionFreeze, probes } from './version-freeze.js';

const mockRequest = request as unknown as ReturnType<typeof vi.fn>;
const mockAppend = appendAdmission as unknown as ReturnType<typeof vi.fn>;
const mockRead = readAdmissions as unknown as ReturnType<typeof vi.fn>;

function run(args: string[]): Promise<Command> {
  const p = new Command();
  p.exitOverride();
  registerVersionFreeze(p);
  return p.parseAsync(['node', 'jira', ...args]);
}

const issue = (key: string, cat: 'done' | 'new', labels: string[] = []) => ({
  key,
  fields: {
    summary: key,
    status: { name: cat === 'done' ? 'Done' : 'To Do', statusCategory: { key: cat } },
    issuetype: { name: 'Task' },
    labels,
  },
});

interface World {
  description?: string;
  open?: ReturnType<typeof issue>[];
  frozen?: ReturnType<typeof issue>[];
  blockers?: ReturnType<typeof issue>[];
  unfolded?: ReturnType<typeof issue>[];
}

// Routes the mocked REST calls by URL/JQL so each command sees one coherent Jira.
function world(w: World): void {
  mockRequest.mockImplementation(async (method: string, path: string) => {
    if (method === 'GET' && path === '/project/HIM/versions') {
      return [{ id: '7', name: 'v1.1.3', description: w.description }];
    }
    if (method === 'GET' && path.startsWith('/search/jql')) {
      const jql = decodeURIComponent(path.split('jql=')[1].split('&')[0]);
      let issues: unknown[];
      if (jql.includes('priority = Highest')) issues = w.blockers ?? [];
      else if (jql.includes('fixVersion != ')) issues = w.unfolded ?? [];
      else if (jql.includes('key in (')) issues = w.frozen ?? [];
      else issues = w.open ?? [];
      return { issues, total: issues.length };
    }
    return {};
  });
}

const FROZEN_DESC = 'frozen: 2026-10-20\nfrozen-keys: HIM-1,HIM-2';

describe('version-freeze / version-ready / version-defer', () => {
  const saved = { ...process.env };
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    process.env.JIRA_PROJECT_KEY = 'HIM';
    delete process.env.HIMMEL_CONSOLE_LEG;
    delete process.env.HIMMEL_CONSOLE_RELAY;
    probes.mainCi = () => ({ ok: true, detail: 'green' });
    mockRead.mockReturnValue([]);
  });
  afterEach(() => {
    process.env = { ...saved };
  });

  const out = () =>
    (console.log as unknown as ReturnType<typeof vi.fn>).mock.calls.map((c) => String(c[0])).join('\n');

  it('version-freeze writes frozen: and the key list into the description and labels the open set', async () => {
    world({ description: 'Release notes', open: [issue('HIM-1', 'new'), issue('HIM-2', 'new')] });
    await run(['version-freeze', 'v1.1.3', '--date', '2026-10-20']);
    expect(mockRequest).toHaveBeenCalledWith('PUT', '/version/7', {
      description: 'Release notes\nfrozen: 2026-10-20\nfrozen-keys: HIM-1,HIM-2',
    });
    expect(mockRequest).toHaveBeenCalledWith('PUT', '/issue/HIM-1', { update: { labels: [{ add: 'scope-v1.1.3' }] } });
    expect(mockRequest).toHaveBeenCalledWith('PUT', '/issue/HIM-2', { update: { labels: [{ add: 'scope-v1.1.3' }] } });
  });

  it('version-freeze --dry-run prints the plan and writes nothing', async () => {
    world({ open: [issue('HIM-1', 'new')] });
    await run(['version-freeze', 'v1.1.3', '--date', '2026-10-20', '--dry-run']);
    expect(mockRequest.mock.calls.every((c) => c[0] === 'GET')).toBe(true);
    expect(out()).toContain('HIM-1');
  });

  it('version-freeze refuses a version that already carries frozen:', async () => {
    world({ description: FROZEN_DESC, open: [issue('HIM-1', 'new')] });
    await expect(run(['version-freeze', 'v1.1.3'])).rejects.toThrow(/already frozen/);
    expect(mockRequest.mock.calls.some((c) => c[0] === 'PUT')).toBe(false);
  });

  it('version-ready FAILs the frozen-set row with one open frozen key', async () => {
    world({ description: FROZEN_DESC, frozen: [issue('HIM-1', 'done'), issue('HIM-2', 'new')] });
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/FAIL\s+frozen-set.*HIM-2/);
  });

  it('version-ready PASSes the frozen-set row once the key is Done or labelled deferred', async () => {
    world({ description: FROZEN_DESC, frozen: [issue('HIM-1', 'done'), issue('HIM-2', 'new', ['deferred'])] });
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/PASS\s+frozen-set/);
    expect(out()).not.toMatch(/FAIL/);
  });

  it('version-ready FAILs on an open Highest bug, an unfolded Done key and a red main', async () => {
    probes.mainCi = () => ({ ok: false, detail: 'ci red' });
    world({
      description: FROZEN_DESC,
      frozen: [issue('HIM-1', 'done'), issue('HIM-2', 'done')],
      blockers: [issue('HIM-9', 'new')],
      unfolded: [issue('HIM-2', 'done')],
    });
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/FAIL\s+no-blocker-bug.*HIM-9/);
    expect(out()).toMatch(/FAIL\s+main-ci/);
    expect(out()).toMatch(/FAIL\s+done-fold.*HIM-2/);
  });

  it('version-ready on an unfrozen version FAILs the frozen-set row and does not throw', async () => {
    world({ description: 'no freeze here' });
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/FAIL\s+frozen-set.*not frozen/);
  });

  it('--console-override with a reason turns a FAIL row into an overridden PASS and writes a ledger row', async () => {
    world({ description: FROZEN_DESC, frozen: [issue('HIM-1', 'done'), issue('HIM-2', 'new')] });
    await run(['version-ready', 'v1.1.3', '--console-override', 'HIM-2 ships in v1.1.4']);
    expect(out()).toMatch(/PASS\s+frozen-set.*overridden.*HIM-2 ships in v1.1.4/);
    expect(mockAppend).toHaveBeenCalledWith(
      expect.objectContaining({ version: 'v1.1.3', key: 'frozen-set', kind: 'override', reason: 'HIM-2 ships in v1.1.4' }),
    );
  });

  it('--console-override from a leg (no console marker) stays FAIL and writes no ledger row', async () => {
    process.env.HIMMEL_CONSOLE_LEG = '1';
    world({ description: FROZEN_DESC, frozen: [issue('HIM-2', 'new')] });
    await run(['version-ready', 'v1.1.3', '--console-override', 'because']);
    expect(out()).toMatch(/FAIL\s+frozen-set/);
    expect(out()).toMatch(/console marker/);
    expect(mockAppend).not.toHaveBeenCalled();
  });

  it('--console-override with a blank reason stays FAIL and writes no ledger row', async () => {
    world({ description: FROZEN_DESC, frozen: [issue('HIM-2', 'new')] });
    await run(['version-ready', 'v1.1.3', '--console-override', '   ']);
    expect(out()).toMatch(/FAIL\s+frozen-set/);
    expect(mockAppend).not.toHaveBeenCalled();
  });

  it('version-ready lists recorded overrides and deferrals and prints the burn-down counts', async () => {
    mockRead.mockReturnValue([
      { ts: '2026-10-21T01:00:00Z', version: 'v1.1.3', key: 'HIM-5', gate: 'must:98', actor: 'f', reason: 'x' },
      { ts: '2026-10-21T02:00:00Z', version: 'v1.1.3', key: 'frozen-set', kind: 'override', actor: 'c', reason: 'because' },
      { ts: '2026-10-21T03:00:00Z', version: 'v1.1.3', key: 'HIM-2', kind: 'deferral', actor: 'c', reason: 'later' },
    ]);
    world({ description: FROZEN_DESC, frozen: [issue('HIM-1', 'done'), issue('HIM-2', 'new')] });
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/override.*frozen-set.*because/);
    expect(out()).toMatch(/deferral.*HIM-2.*later/);
    expect(out()).toMatch(/frozen-open: 1/);
    expect(out()).toMatch(/admitted-after-freeze: 1/);
  });

  it('version-defer labels the ticket deferred and writes a deferral ledger row', async () => {
    world({ description: FROZEN_DESC });
    await run(['version-defer', 'HIM-2', '--version', 'v1.1.3', '--reason', 'moves to v1.1.4']);
    expect(mockRequest).toHaveBeenCalledWith('PUT', '/issue/HIM-2', { update: { labels: [{ add: 'deferred' }] } });
    expect(mockAppend).toHaveBeenCalledWith(
      expect.objectContaining({ version: 'v1.1.3', key: 'HIM-2', kind: 'deferral', reason: 'moves to v1.1.4' }),
    );
  });

  it('version-defer from a leg is refused before any write', async () => {
    process.env.HIMMEL_CONSOLE_LEG = '1';
    await expect(
      run(['version-defer', 'HIM-2', '--version', 'v1.1.3', '--reason', 'x']),
    ).rejects.toThrow(/console marker/);
    expect(mockRequest).not.toHaveBeenCalled();
    expect(mockAppend).not.toHaveBeenCalled();
  });
});
