import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { Command } from 'commander';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

vi.mock('../client.js', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../client.js')>();
  return { ...actual, request: vi.fn() };
});
vi.mock('node:child_process', () => ({ execFileSync: vi.fn() }));
vi.mock('./admissions-ledger.js', () => ({ appendAdmission: vi.fn(), readAdmissions: vi.fn(() => []) }));

import { request } from '../client.js';
import { appendAdmission, readAdmissions } from './admissions-ledger.js';
import { execFileSync } from 'node:child_process';
import { registerVersionFreeze, probes, mainCiGreen } from './version-freeze.js';

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
  inVersion?: ReturnType<typeof issue>[];
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
      if (jql === 'project=HIM AND fixVersion="v1.1.3"') issues = w.inVersion ?? w.frozen ?? [];
      else if (jql.includes('priority = Highest')) issues = w.blockers ?? [];
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
    process.env.HIMMEL_CONSOLE = '1';
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
    await run(['version-freeze', 'v1.1.3', '--at', '2026-10-20']);
    expect(mockRequest).toHaveBeenCalledWith('PUT', '/version/7', {
      description: 'Release notes\nfrozen: 2026-10-20\nfrozen-keys: HIM-1,HIM-2',
    });
    expect(mockRequest).toHaveBeenCalledWith('PUT', '/issue/HIM-1', { update: { labels: [{ add: 'scope-v1.1.3' }] } });
    expect(mockRequest).toHaveBeenCalledWith('PUT', '/issue/HIM-2', { update: { labels: [{ add: 'scope-v1.1.3' }] } });
  });

  it('version-freeze --dry-run prints the plan and writes nothing', async () => {
    world({ open: [issue('HIM-1', 'new')] });
    await run(['version-freeze', 'v1.1.3', '--at', '2026-10-20', '--dry-run']);
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

  it('version-ready FAILs the frozen-set row for a frozen key the search no longer returns', async () => {
    world({ description: FROZEN_DESC, frozen: [issue('HIM-1', 'done')] });
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/FAIL\s+frozen-set.*open: HIM-2/);
  });

  it('the done-fold query also catches a Done frozen key whose fixVersion is empty', async () => {
    world({ description: FROZEN_DESC, frozen: [issue('HIM-1', 'done'), issue('HIM-2', 'done')] });
    await run(['version-ready', 'v1.1.3']);
    const jqls = mockRequest.mock.calls.map((c) => decodeURIComponent(String(c[1])));
    expect(jqls.some((j) => j.includes('fixVersion != "v1.1.3" OR fixVersion is EMPTY'))).toBe(true);
  });

  it('main-ci checks the CI runs of main\'s actual head, not of the newest run', () => {
    const exec = execFileSync as unknown as ReturnType<typeof vi.fn>;
    exec.mockImplementation((_cmd: string, args: string[]) =>
      args[0] === 'api'
        ? 'newhead111\n'
        : JSON.stringify([{ conclusion: 'success', headSha: 'oldhead000', workflowName: 'ci' }]),
    );
    expect(mainCiGreen()).toEqual({ ok: false, detail: 'no CI run found for newhead111' });
  });

  it('version-freeze labels the set before it writes frozen:, so a failed label leaves the version retryable', async () => {
    world({ description: 'notes', open: [issue('HIM-1', 'new')] });
    await run(['version-freeze', 'v1.1.3', '--at', '2026-10-20']);
    const puts = mockRequest.mock.calls.filter((c) => c[0] === 'PUT').map((c) => String(c[1]));
    expect(puts).toEqual(['/issue/HIM-1', '/version/7']);
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
    await run(['version-ready', 'v1.1.3', '--console-override', 'frozen-set', 'HIM-2 ships in v1.1.4']);
    expect(out()).toMatch(/PASS\s+frozen-set.*overridden.*HIM-2 ships in v1.1.4/);
    expect(mockAppend).toHaveBeenCalledWith(
      expect.objectContaining({ version: 'v1.1.3', key: 'frozen-set', kind: 'override', reason: 'HIM-2 ships in v1.1.4' }),
    );
  });

  it('--console-override overrules only the named row; it is repeatable, one ledger row each', async () => {
    probes.mainCi = () => ({ ok: false, detail: 'ci red' });
    world({ description: FROZEN_DESC, frozen: [issue('HIM-1', 'done'), issue('HIM-2', 'new')], blockers: [issue('HIM-9', 'new')] });
    await run(['version-ready', 'v1.1.3', '--console-override', 'main-ci', 'flaky', '--console-override', 'frozen-set', 'moves']);
    expect(out()).toMatch(/PASS\s+main-ci.*flaky/);
    expect(out()).toMatch(/PASS\s+frozen-set.*moves/);
    expect(out()).toMatch(/FAIL\s+no-blocker-bug/);
    expect(mockAppend).toHaveBeenCalledTimes(2);
  });

  it('--console-override without the console marker stays FAIL and writes no ledger row', async () => {
    delete process.env.HIMMEL_CONSOLE;
    world({ description: FROZEN_DESC, frozen: [issue('HIM-2', 'new')] });
    await run(['version-ready', 'v1.1.3', '--console-override', 'frozen-set', 'because']);
    expect(out()).toMatch(/FAIL\s+frozen-set/);
    expect(out()).toMatch(/console marker/);
    expect(mockAppend).not.toHaveBeenCalled();
  });

  it('--console-override with a blank reason stays FAIL and writes no ledger row', async () => {
    world({ description: FROZEN_DESC, frozen: [issue('HIM-2', 'new')] });
    await run(['version-ready', 'v1.1.3', '--console-override', 'frozen-set', '   ']);
    expect(out()).toMatch(/FAIL\s+frozen-set/);
    expect(mockAppend).not.toHaveBeenCalled();
  });

  it('--console-override with an odd number of values is refused', async () => {
    world({ description: FROZEN_DESC, frozen: [issue('HIM-2', 'new')] });
    await expect(run(['version-ready', 'v1.1.3', '--console-override', 'frozen-set'])).rejects.toThrow(/pairs/);
  });

  it('version-ready prints no time-box roll date', async () => {
    world({ description: FROZEN_DESC, frozen: [issue('HIM-1', 'done'), issue('HIM-2', 'done')] });
    await run(['version-ready', 'v1.1.3']);
    expect(out()).not.toMatch(/time-box|72 h/);
  });

  it('a key in the version but not in the frozen list with no ledger row is a leak: the frozen-set row FAILs', async () => {
    world({
      description: FROZEN_DESC,
      frozen: [issue('HIM-1', 'done'), issue('HIM-2', 'done')],
      inVersion: [issue('HIM-1', 'done'), issue('HIM-2', 'done'), issue('HIM-7', 'new')],
    });
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/FAIL\s+frozen-set.*leak.*HIM-7/);
    expect(out()).toMatch(/admitted-after-freeze: 1/);
  });

  it('an rm-admit ledger row clears the leak and the key is printed with its reason and the ruling session', async () => {
    mockRead.mockReturnValue([
      { ts: '2026-10-21T01:00:00Z', version: 'v1.1.3', key: 'HIM-7', kind: 'rm-admit', actor: 'c', reason: 'found work, P1', by: 'rm-N3063' },
    ]);
    world({
      description: FROZEN_DESC,
      frozen: [issue('HIM-1', 'done'), issue('HIM-2', 'done')],
      inVersion: [issue('HIM-1', 'done'), issue('HIM-2', 'done'), issue('HIM-7', 'new')],
    });
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/PASS\s+frozen-set/);
    expect(out()).toMatch(/admitted\tHIM-7\tfound work, P1\trm-N3063/);
    expect(out()).toMatch(/admitted-after-freeze: 1/);
  });

  it('a gate-filed ledger row also counts as an admission, and an unrecorded Done key is a Done-fold, not a leak', async () => {
    mockRead.mockReturnValue([{ ts: '2026-10-21T01:00:00Z', version: 'v1.1.3', key: 'HIM-5', gate: 'critical', actor: 'f' }]);
    world({
      description: FROZEN_DESC,
      frozen: [issue('HIM-1', 'done'), issue('HIM-2', 'done')],
      inVersion: [issue('HIM-1', 'done'), issue('HIM-2', 'done'), issue('HIM-5', 'new'), issue('HIM-8', 'done')],
    });
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/PASS\s+frozen-set/);
    expect(out()).toMatch(/admitted\tHIM-5\tcritical/);
    expect(out()).toMatch(/done-folded: 1/);
  });

  it('version-ready lists recorded overrides and deferrals and prints the frozen-open count', async () => {
    mockRead.mockReturnValue([
      { ts: '2026-10-21T02:00:00Z', version: 'v1.1.3', key: 'frozen-set', kind: 'override', actor: 'c', reason: 'because' },
      { ts: '2026-10-21T03:00:00Z', version: 'v1.1.3', key: 'HIM-2', kind: 'deferral', actor: 'c', reason: 'later' },
    ]);
    world({ description: FROZEN_DESC, frozen: [issue('HIM-1', 'done'), issue('HIM-2', 'new')] });
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/override.*frozen-set.*because/);
    expect(out()).toMatch(/deferral.*HIM-2.*later/);
    expect(out()).toMatch(/frozen-open: 1/);
    expect(out()).toMatch(/admitted-after-freeze: 0/);
  });

  it('version-admit writes an rm-admit ledger row with the ruling session', () => {
    return run(['version-admit', 'HIM-7', '--version', 'v1.1.3', '--reason', 'found work', '--by', 'rm-N3063']).then(() => {
      expect(mockAppend).toHaveBeenCalledWith(
        expect.objectContaining({ version: 'v1.1.3', key: 'HIM-7', kind: 'rm-admit', reason: 'found work', by: 'rm-N3063' }),
      );
    });
  });

  it('version-admit without the console marker, a reason or --by is refused before any write', async () => {
    const argv = ['version-admit', 'HIM-7', '--version', 'v1.1.3'];
    await expect(run([...argv, '--reason', 'r'])).rejects.toThrow(/--by/);
    await expect(run([...argv, '--by', 'rm'])).rejects.toThrow(/--reason/);
    delete process.env.HIMMEL_CONSOLE;
    await expect(run([...argv, '--reason', 'r', '--by', 'rm'])).rejects.toThrow(/console marker/);
    expect(mockAppend).not.toHaveBeenCalled();
  });

  it('version-freeze --keys-file freezes the listed keys at --at and labels each', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'vf-'));
    const file = join(dir, 'keys.txt');
    writeFileSync(file, 'HIM-1\n\n# a comment\nHIM-2\nHIM-1\n');
    world({ description: 'notes', open: [issue('HIM-99', 'new')] });
    await run(['version-freeze', 'v1.1.3', '--keys-file', file, '--at', '2026-10-20']);
    expect(mockRequest).toHaveBeenCalledWith('PUT', '/version/7', { description: 'notes\nfrozen: 2026-10-20\nfrozen-keys: HIM-1,HIM-2' });
    expect(mockRequest).toHaveBeenCalledWith('PUT', '/issue/HIM-2', { update: { labels: [{ add: 'scope-v1.1.3' }] } });
    expect(mockRequest).not.toHaveBeenCalledWith('PUT', '/issue/HIM-99', expect.anything());
    rmSync(dir, { recursive: true });
  });

  it('version-freeze --keys-file refuses a line that is not a ticket key', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'vf-'));
    const file = join(dir, 'keys.txt');
    writeFileSync(file, 'HIM-1\nnot a key\n');
    world({});
    await expect(run(['version-freeze', 'v1.1.3', '--keys-file', file])).rejects.toThrow(/not a ticket key/);
    expect(mockRequest.mock.calls.some((c) => c[0] === 'PUT')).toBe(false);
    rmSync(dir, { recursive: true });
  });

  it('version-defer labels the ticket deferred and writes a deferral ledger row', async () => {
    world({ description: FROZEN_DESC });
    await run(['version-defer', 'HIM-2', '--version', 'v1.1.3', '--reason', 'moves to v1.1.4']);
    expect(mockRequest).toHaveBeenCalledWith('PUT', '/issue/HIM-2', { update: { labels: [{ add: 'deferred' }] } });
    expect(mockAppend).toHaveBeenCalledWith(
      expect.objectContaining({ version: 'v1.1.3', key: 'HIM-2', kind: 'deferral', reason: 'moves to v1.1.4' }),
    );
  });

  it('version-defer without the console marker is refused before any write', async () => {
    delete process.env.HIMMEL_CONSOLE;
    await expect(
      run(['version-defer', 'HIM-2', '--version', 'v1.1.3', '--reason', 'x']),
    ).rejects.toThrow(/console marker/);
    expect(mockRequest).not.toHaveBeenCalled();
    expect(mockAppend).not.toHaveBeenCalled();
  });
});
