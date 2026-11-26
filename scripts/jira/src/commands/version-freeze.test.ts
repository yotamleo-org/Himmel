import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { Command } from 'commander';
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

vi.mock('../client.js', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../client.js')>();
  return { ...actual, request: vi.fn() };
});
vi.mock('node:child_process', () => ({ execFileSync: vi.fn() }));
vi.mock('./admissions-ledger.js', () => ({ appendAdmission: vi.fn(), readAdmissions: vi.fn(() => []) }));

import { request } from '../client.js';
import { appendAdmission, readAdmissions } from './admissions-ledger.js';
import { execFileSync } from 'node:child_process';
import { registerVersionFreeze, probes, mainCiGreen, parseFrozen, owedOpenDefault, bucketDefault } from './version-freeze.js';
import { leaveCheck, type Leave } from '../release/leave.js';
import { mechanismOf, requestedSet } from '../release/version-writes.js';
import type { OperatorRow } from '../release/types.js';

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
  owedMembers?: ReturnType<typeof issue>[];
  inVersion?: ReturnType<typeof issue>[];
  fixVersions?: Record<string, string[]>;
}

// Routes the mocked REST calls by URL/JQL so each command sees one coherent Jira.
function world(w: World): void {
  mockRequest.mockImplementation(async (method: string, path: string, body?: { update?: { fixVersions?: Array<Record<string, { name: string }>> } }) => {
    if (method === 'GET' && path === '/project/HIM/versions') {
      return [{ id: '7', name: 'v1.1.3', description: w.description }, { id: '8', name: 'v1.1.4' }];
    }
    const fv = /^\/issue\/([A-Z]+-\d+)(\?fields=fixVersions)?$/.exec(path);
    if (fv && w.fixVersions) {
      const names = (w.fixVersions[fv[1]] ??= []);
      if (method === 'GET' && fv[2]) return { fields: { fixVersions: names.map((name) => ({ name })) } };
      for (const op of body?.update?.fixVersions ?? []) {
        if (op.add) names.push(op.add.name);
        const at = op.remove ? names.indexOf(op.remove.name) : -1;
        if (at >= 0) names.splice(at, 1);
      }
      return {};
    }
    if (method === 'GET' && path.startsWith('/search/jql')) {
      const jql = decodeURIComponent(path.split('jql=')[1].split('&')[0]);
      let issues: unknown[];
      if (jql === 'project=HIM AND fixVersion="v1.1.3"') issues = w.inVersion ?? w.frozen ?? [];
      else if (jql.includes('priority = Highest') || jql.includes('priority in (Highest, High)')) issues = w.blockers ?? [];
      else if (jql.includes('labels = station-adhoc')) issues = (w.open ?? []).filter((i) => i.fields.labels.includes('station-adhoc'));
      else if (jql.includes('fixVersion != ')) issues = w.unfolded ?? [];
      else if (jql.includes('key in (') && jql.includes(' AND fixVersion="')) issues = w.owedMembers ?? [];
      else if (jql.includes('key in (')) issues = w.frozen ?? [];
      else issues = w.open ?? [];
      return { issues, total: issues.length };
    }
    return {};
  });
}

const FROZEN_DESC = 'frozen: 2026-10-20\nfrozen-keys: HIM-1,HIM-2';
const SHA = 'a'.repeat(40);
const HEADER = 'n\tpart\ttext\tstate\tproof';
const PASSING_PROMISE = ['1\tA fleet\tEvery started ticket has a live owner.\tshown_true\tPR 6100 and PROOF o12', '2\tA fleet\tNo slot stays empty.\tshown_true\tPR 6101'];
const ROW_IDS = ['frozen-set', 'no-blocker-bug', 'station-adhoc', 'main-ci', 'done-fold', 'promise-proof', 'owed-steps'];
const exec = execFileSync as unknown as ReturnType<typeof vi.fn>;
const probe = probes as unknown as { mainCi: unknown; owedOpen: unknown; bucket: unknown };

describe('version-freeze / version-ready / version-defer', () => {
  const saved = { ...process.env };
  let tmp = '';
  let bucket = '';
  const promisePath = () => join(bucket, 'specs', 'versions', 'v1.1.3-promise.tsv');
  const promise = (lines: string[], header = HEADER) => {
    mkdirSync(join(bucket, 'specs', 'versions'), { recursive: true });
    writeFileSync(promisePath(), `${[header, ...lines].join('\n')}\n`);
  };
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    process.env.JIRA_PROJECT_KEY = 'HIM';
    process.env.HIMMEL_CONSOLE = '1';
    tmp = mkdtempSync(join(tmpdir(), 'vr-'));
    bucket = tmp;
    process.env.HIMMEL_RELEASE_STATE_DIR = join(tmp, 'release');
    writeFileSync(join(tmp, 'owed.jsonl'), '');
    promise(PASSING_PROMISE);
    exec.mockReset();
    probe.mainCi = vi.fn(() => ({ ok: true, detail: 'green' }));
    probe.owedOpen = vi.fn(() => []);
    probe.bucket = bucketDefault;
    mockRead.mockReturnValue([]);
  });
  afterEach(() => {
    process.env = { ...saved };
    process.exitCode = undefined;
    rmSync(tmp, { recursive: true, force: true });
  });

  const out = () =>
    (console.log as unknown as ReturnType<typeof vi.fn>).mock.calls.map((c) => String(c[0])).join('\n');
  const jqls = () => mockRequest.mock.calls.map((c) => decodeURIComponent(String(c[1])));
  const fails = () => out().match(/^FAIL\t/gm) ?? [];
  const mainCiMock = () => probe.mainCi as ReturnType<typeof vi.fn>;
  const owedMock = () => probe.owedOpen as ReturnType<typeof vi.fn>;
  const doneWorld = (extra: Partial<World> = {}) =>
    world({ description: FROZEN_DESC, frozen: [issue('HIM-1', 'done'), issue('HIM-2', 'done')], ...extra });

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

  it('a deleted frozen key (HTTP 400 on the bulk key query) reads as open, not as a crash', async () => {
    world({ description: FROZEN_DESC, frozen: [issue('HIM-1', 'done')] });
    const routed = mockRequest.getMockImplementation()!;
    mockRequest.mockImplementation(async (method: string, path: string) => {
      const jql = decodeURIComponent(path.split('jql=')[1]?.split('&')[0] ?? '');
      if (jql.includes('HIM-2') && jql.startsWith('key')) throw new Error("HTTP 400: An issue with key 'HIM-2' does not exist");
      if (jql === 'key = HIM-1') return { issues: [issue('HIM-1', 'done')], total: 1 };
      return routed(method, path);
    });
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

  it('main-ci asks gh for every run of main\'s head, not only the newest 30 of the branch', () => {
    const exec = execFileSync as unknown as ReturnType<typeof vi.fn>;
    exec.mockReset();
    exec.mockImplementation((_cmd: string, args: string[]) =>
      args[0] === 'api' ? 'abc123\n' : JSON.stringify([{ conclusion: 'success', headSha: 'abc123', workflowName: 'ci' }]),
    );
    expect(mainCiGreen().ok).toBe(true);
    const listArgs = exec.mock.calls.map((c) => c[1] as string[]).find((a) => a[0] === 'run') ?? [];
    expect(listArgs).toEqual(expect.arrayContaining(['--commit', 'abc123']));
    expect(Number(listArgs[listArgs.indexOf('--limit') + 1])).toBeGreaterThan(30);
  });

  it('a description with frozen: but no frozen-keys: line is not a freeze, an empty frozen-keys: line is', async () => {
    world({ description: 'frozen: 2026-10-20', open: [issue('HIM-5', 'new')] });
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/FAIL\s+frozen-set.*not frozen; open: HIM-5/);
    expect(parseFrozen('frozen: 2026-10-20\nfrozen-keys:')).toEqual({ date: '2026-10-20', keys: [] });
  });

  it('version-freeze labels the set before it writes frozen:, so a failed label leaves the version retryable', async () => {
    world({ description: 'notes', open: [issue('HIM-1', 'new')] });
    await run(['version-freeze', 'v1.1.3', '--at', '2026-10-20']);
    const puts = mockRequest.mock.calls.filter((c) => c[0] === 'PUT').map((c) => String(c[1]));
    expect(puts).toEqual(['/issue/HIM-1', '/version/7']);
  });

  it('version-ready PASSes the frozen-set row once the key is Done or deferred from this version', async () => {
    mockRead.mockReturnValue([
      { ts: '2026-10-21T03:00:00Z', version: 'v1.1.3', key: 'HIM-2', kind: 'deferral', actor: 'c', reason: 'later' },
    ]);
    world({ description: FROZEN_DESC, frozen: [issue('HIM-1', 'done'), issue('HIM-2', 'new', ['deferred'])] });
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/PASS\s+frozen-set/);
    expect(out()).not.toMatch(/FAIL/);
  });

  it('a deferred label without a deferral row for this version keeps the key open', async () => {
    mockRead.mockReturnValue([
      { ts: '2026-10-01T03:00:00Z', version: 'v1.1.2', key: 'HIM-2', kind: 'deferral', actor: 'c', reason: 'earlier release' },
    ]);
    world({ description: FROZEN_DESC, frozen: [issue('HIM-1', 'done'), issue('HIM-2', 'new', ['deferred'])] });
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/FAIL\s+frozen-set.*open: HIM-2/);
  });

  it('an empty frozen-keys: line followed by release notes parses as an empty freeze', () => {
    expect(parseFrozen('frozen: 2026-10-20\nfrozen-keys:\nRelease notes HIM-5')).toEqual({ date: '2026-10-20', keys: [] });
  });

  it('main-ci fails closed when the run list may be truncated', () => {
    const exec = execFileSync as unknown as ReturnType<typeof vi.fn>;
    exec.mockReset();
    exec.mockImplementation((_cmd: string, args: string[]) =>
      args[0] === 'api'
        ? 'abc123\n'
        : JSON.stringify(Array.from({ length: 200 }, () => ({ conclusion: 'success', headSha: 'abc123', workflowName: 'ci' }))),
    );
    expect(mainCiGreen().ok).toBe(false);
  });

  it('RED d: version-ready fails on an open station-adhoc ticket even when admitted and deferred', async () => {
    mockRead.mockReturnValue([
      { ts: '2026-10-21T01:00:00Z', version: 'v1.1.3', key: 'HIM-9', kind: 'rm-admit', actor: 'c', reason: 'station' },
      { ts: '2026-10-21T02:00:00Z', version: 'v1.1.3', key: 'HIM-2', kind: 'deferral', actor: 'c', reason: 'later' },
    ]);
    world({
      description: FROZEN_DESC,
      frozen: [issue('HIM-1', 'done'), issue('HIM-2', 'new', ['deferred'])],
      inVersion: [issue('HIM-1', 'done'), issue('HIM-2', 'new', ['deferred']), issue('HIM-9', 'new', ['station-adhoc'])],
      open: [issue('HIM-9', 'new', ['station-adhoc'])],
    });
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/PASS\s+frozen-set/);
    expect(out()).toMatch(/FAIL\s+station-adhoc.*HIM-9/);
    expect(mockRequest.mock.calls.every((c) => c[0] === 'GET')).toBe(true);
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

  it('version-ready on an unfrozen version FAILs the frozen-set row on an open member and does not throw', async () => {
    world({ description: 'no freeze here', open: [issue('HIM-5', 'new')] });
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/FAIL\s+frozen-set.*not frozen; open: HIM-5/);
  });

  it('--chief-override with a reason turns a FAIL row into an overridden PASS and writes a ledger row', async () => {
    world({ description: FROZEN_DESC, frozen: [issue('HIM-1', 'done'), issue('HIM-2', 'new')] });
    await run(['version-ready', 'v1.1.3', '--chief-override', 'frozen-set', 'HIM-2 ships in v1.1.4']);
    expect(out()).toMatch(/PASS\s+frozen-set.*overridden.*HIM-2 ships in v1.1.4/);
    expect(mockAppend).toHaveBeenCalledWith(
      expect.objectContaining({ version: 'v1.1.3', key: 'frozen-set', kind: 'override', reason: 'HIM-2 ships in v1.1.4' }),
    );
    expect(process.exitCode).toBeUndefined();
  });

  it('--chief-override overrules only the named row; it is repeatable, one ledger row each', async () => {
    probes.mainCi = () => ({ ok: false, detail: 'ci red' });
    world({ description: FROZEN_DESC, frozen: [issue('HIM-1', 'done'), issue('HIM-2', 'new')], blockers: [issue('HIM-9', 'new')] });
    await run(['version-ready', 'v1.1.3', '--chief-override', 'main-ci', 'flaky', '--chief-override', 'frozen-set', 'moves']);
    expect(out()).toMatch(/PASS\s+main-ci.*flaky/);
    expect(out()).toMatch(/PASS\s+frozen-set.*moves/);
    expect(out()).toMatch(/FAIL\s+no-blocker-bug/);
    expect(mockAppend).toHaveBeenCalledTimes(2);
  });

  it('--chief-override without the console marker stays FAIL and writes no ledger row', async () => {
    delete process.env.HIMMEL_CONSOLE;
    world({ description: FROZEN_DESC, frozen: [issue('HIM-2', 'new')] });
    await run(['version-ready', 'v1.1.3', '--chief-override', 'frozen-set', 'because']);
    expect(out()).toMatch(/FAIL\s+frozen-set/);
    expect(out()).toMatch(/chief marker/);
    expect(mockAppend).not.toHaveBeenCalled();
  });

  it('--chief-override with a blank reason stays FAIL and writes no ledger row', async () => {
    world({ description: FROZEN_DESC, frozen: [issue('HIM-2', 'new')] });
    await run(['version-ready', 'v1.1.3', '--chief-override', 'frozen-set', '   ']);
    expect(out()).toMatch(/FAIL\s+frozen-set/);
    expect(mockAppend).not.toHaveBeenCalled();
  });

  it('--chief-override with an odd number of values is refused', async () => {
    world({ description: FROZEN_DESC, frozen: [issue('HIM-2', 'new')] });
    await expect(run(['version-ready', 'v1.1.3', '--chief-override', 'frozen-set'])).rejects.toThrow(/pairs/);
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

  it('an rm-remove ledger row is not an admission, so a key back in the version without a new ruling is a leak', async () => {
    mockRead.mockReturnValue([
      { ts: '2026-10-21T01:00:00Z', version: 'v1.1.3', key: 'HIM-7', kind: 'rm-remove', actor: 'c', by: 'rm-N3063' },
    ]);
    world({
      description: FROZEN_DESC,
      frozen: [issue('HIM-1', 'done'), issue('HIM-2', 'done')],
      inVersion: [issue('HIM-1', 'done'), issue('HIM-2', 'done'), issue('HIM-7', 'new')],
    });
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/FAIL\s+frozen-set.*leak.*HIM-7/);
  });

  it('a key admitted, then removed, then back in the version without a new ruling is a leak: the latest row wins', async () => {
    mockRead.mockReturnValue([
      { ts: '2026-10-21T01:00:00Z', version: 'v1.1.3', key: 'HIM-7', kind: 'rm-admit', actor: 'c', reason: 'found work, P1', by: 'rm-N3063' },
      { ts: '2026-10-21T02:00:00Z', version: 'v1.1.3', key: 'HIM-7', kind: 'rm-remove', actor: 'c', by: 'rm-N3063' },
    ]);
    world({
      description: FROZEN_DESC,
      frozen: [issue('HIM-1', 'done'), issue('HIM-2', 'done')],
      inVersion: [issue('HIM-1', 'done'), issue('HIM-2', 'done'), issue('HIM-7', 'new')],
    });
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/FAIL\s+frozen-set.*leak.*HIM-7/);
  });

  it('a Done key whose latest row is a removal is a leak, not a Done-fold', async () => {
    mockRead.mockReturnValue([
      { ts: '2026-10-21T01:00:00Z', version: 'v1.1.3', key: 'HIM-7', kind: 'rm-admit', actor: 'c', reason: 'found work, P1', by: 'rm-N3063' },
      { ts: '2026-10-21T02:00:00Z', version: 'v1.1.3', key: 'HIM-7', kind: 'rm-remove', actor: 'c', by: 'rm-N3063' },
    ]);
    world({
      description: FROZEN_DESC,
      frozen: [issue('HIM-1', 'done'), issue('HIM-2', 'done')],
      inVersion: [issue('HIM-1', 'done'), issue('HIM-2', 'done'), issue('HIM-7', 'done')],
    });
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/FAIL\s+frozen-set.*leak.*HIM-7/);
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
    await expect(run([...argv, '--reason', 'r', '--by', 'rm'])).rejects.toThrow(/chief marker/);
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
    world({ description: FROZEN_DESC, fixVersions: { 'HIM-2': ['v1.1.3'] } });
    await run(['version-defer', 'HIM-2', '--version', 'v1.1.3', '--reason', 'moves to v1.1.4']);
    expect(mockRequest).toHaveBeenCalledWith('PUT', '/issue/HIM-2', { update: { labels: [{ add: 'deferred' }] } });
    expect(mockAppend).toHaveBeenCalledWith(
      expect.objectContaining({ version: 'v1.1.3', key: 'HIM-2', kind: 'deferral', reason: 'moves to v1.1.4' }),
    );
  });

  it('version-defer takes the version off the ticket and reads it back', async () => {
    const w = { description: FROZEN_DESC, fixVersions: { 'HIM-2': ['v1.1.3'] } };
    world(w);
    await run(['version-defer', 'HIM-2', '--version', 'v1.1.3', '--reason', 'moves to v1.1.4']);
    expect(w.fixVersions['HIM-2']).toEqual([]);
  });

  it('version-defer --to moves the ticket into the target version', async () => {
    const w = { description: FROZEN_DESC, fixVersions: { 'HIM-2': ['v1.1.3'] } };
    world(w);
    await run(['version-defer', 'HIM-2', '--version', 'v1.1.3', '--to', 'v1.1.4', '--reason', 'moves to v1.1.4']);
    expect(w.fixVersions['HIM-2']).toEqual(['v1.1.4']);
  });

  it('version-defer --to a refused target leaves the source version on the ticket and writes no ledger row', async () => {
    const w = { description: FROZEN_DESC, fixVersions: { 'HIM-2': ['v1.1.4'] } };
    world(w);
    await expect(
      run(['version-defer', 'HIM-2', '--version', 'v1.1.4', '--to', 'v1.1.3', '--reason', 'moves to v1.1.3']),
    ).rejects.toThrow(/is frozen/);
    expect(w.fixVersions['HIM-2']).toEqual(['v1.1.4']);
    expect(mockAppend).not.toHaveBeenCalled();
  });

  it('version-defer --to takes the target off again when the source stays on the ticket', async () => {
    const w = { description: FROZEN_DESC, fixVersions: { 'HIM-2': ['v1.1.3'] } };
    world(w);
    const routed = mockRequest.getMockImplementation()!;
    mockRequest.mockImplementation(async (method: string, path: string, body?: { update?: { fixVersions?: Array<{ remove?: { name: string } }> } }) =>
      method === 'PUT' && body?.update?.fixVersions?.[0]?.remove?.name === 'v1.1.3' ? {} : routed(method, path, body),
    );
    await expect(
      run(['version-defer', 'HIM-2', '--version', 'v1.1.3', '--to', 'v1.1.4', '--reason', 'moves to v1.1.4']),
    ).rejects.toThrow(/v1\.1\.4 was taken off again/);
    expect(w.fixVersions['HIM-2']).toEqual(['v1.1.3']);
    expect(mockAppend).not.toHaveBeenCalled();
  });

  it('version-defer --to keeps the target and says so when the source cannot be read back', async () => {
    const w = { description: FROZEN_DESC, fixVersions: { 'HIM-2': ['v1.1.3'] } };
    world(w);
    const routed = mockRequest.getMockImplementation()!;
    let removed = false;
    mockRequest.mockImplementation(async (method: string, path: string, body?: { update?: { fixVersions?: Array<{ remove?: { name: string } }> } }) => {
      if (method === 'PUT' && body?.update?.fixVersions?.[0]?.remove?.name === 'v1.1.3') removed = true;
      if (removed && method === 'GET' && path === '/issue/HIM-2?fields=fixVersions') return {};
      return routed(method, path, body);
    });
    await expect(
      run(['version-defer', 'HIM-2', '--version', 'v1.1.3', '--to', 'v1.1.4', '--reason', 'moves to v1.1.4']),
    ).rejects.toThrow(/may hold both v1\.1\.3 and v1\.1\.4/);
    expect(w.fixVersions['HIM-2']).toEqual(['v1.1.4']);
    expect(mockAppend).not.toHaveBeenCalled();
  });

  it('version-defer fails loudly and writes no ledger row when the version stays on the ticket', async () => {
    world({ description: FROZEN_DESC });
    mockRequest.mockImplementation(async (method: string, path: string) =>
      method === 'GET' && path === '/issue/HIM-2?fields=fixVersions' ? { fields: { fixVersions: [{ name: 'v1.1.3' }] } } : {},
    );
    await expect(run(['version-defer', 'HIM-2', '--version', 'v1.1.3', '--reason', 'moves to v1.1.4'])).rejects.toThrow(/was not changed/);
    expect(mockAppend).not.toHaveBeenCalled();
  });

  it('version-defer under the leave check: refused without --by, passes with the covering move record, and its rollback is an own-add undo', async () => {
    const O1: OperatorRow = { id: 'O-1', kind: 'decision', ts: '2026-11-01T00:00:00Z', decision: '1', keys: ['HIM-2'], op: 'move', from_v: 'v1.1.3', to_v: 'v1.1.4' };
    const w = { description: FROZEN_DESC, fixVersions: { 'HIM-2': ['v1.1.3'] } };
    world(w);
    const base = mockRequest.getMockImplementation()!;
    const own = new Set<string>();
    mockRequest.mockImplementation(async (method: string, path: string, body?: never, writer?: string, opts?: { leave?: Leave }) => {
      if (method === 'PUT' && path === '/issue/HIM-2' && (body as { update?: { fixVersions?: unknown } } | undefined)?.update?.fixVersions) {
        const before = [...w.fixVersions['HIM-2']];
        const after = requestedSet(before, body);
        const verdict = leaveCheck({ key: 'HIM-2', before, after, mechanism: mechanismOf(writer), leave: opts?.leave, ownAdds: own,
          decls: [{ release: 'R', project: 'HIM', current: 'v1.1.3', versions: ['v1.1.3', 'v1.1.4'] }], ops: new Map([['R', new Map([['O-1', O1]])]]), released: new Set() });
        if (!verdict.ok) throw new Error(verdict.reason);
        for (const v of after ?? []) if (!before.includes(v)) own.add(v);
      }
      return base(method, path, body);
    });
    await expect(run(['version-defer', 'HIM-2', '--version', 'v1.1.3', '--to', 'v1.1.4', '--reason', 'moves to v1.1.4'])).rejects.toThrow(/v1\.1\.4 was taken off again/);
    expect(w.fixVersions['HIM-2']).toEqual(['v1.1.3']);
    expect(mockAppend).not.toHaveBeenCalled();
    own.clear();
    await run(['version-defer', 'HIM-2', '--version', 'v1.1.3', '--to', 'v1.1.4', '--reason', 'moves to v1.1.4', '--by', 'O-1']);
    expect(w.fixVersions['HIM-2']).toEqual(['v1.1.4']);
  });

  it('version-defer without the console marker is refused before any write', async () => {
    delete process.env.HIMMEL_CONSOLE;
    await expect(
      run(['version-defer', 'HIM-2', '--version', 'v1.1.3', '--reason', 'x']),
    ).rejects.toThrow(/chief marker/);
    expect(mockRequest).not.toHaveBeenCalled();
    expect(mockAppend).not.toHaveBeenCalled();
  });

  it('R1: an open High bug fails no-blocker-bug by key and the command exits 1; no bug passes', async () => {
    doneWorld({ blockers: [issue('HIM-9', 'new')] });
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/FAIL\s+no-blocker-bug.*HIM-9/);
    expect(process.exitCode).toBe(1);
    const bugJql = jqls().find((j) => j.includes('issuetype=Bug')) ?? '';
    expect(bugJql).toContain('priority in (Highest, High)');
  });

  it('R1 control: with no bug, no-blocker-bug passes and says what it read', async () => {
    doneWorld({ blockers: [] });
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/PASS\s+no-blocker-bug\s+no open Highest or High priority bug, none labelled critical, blocker or v1-blocker/);
  });

  it('R2: a promise sentence with no proof fails promise-proof by number, on a 4-field row, and exits 1', async () => {
    promise([PASSING_PROMISE[0], '3\tA fleet\tEvery ticket closes with proof.\tnot_true']);
    doneWorld();
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/FAIL\s+promise-proof\s+no proof: 3 "Every ticket closes with proof\."/);
    expect(process.exitCode).toBe(1);
  });

  it('R2 control: the sentence shown true with a proof passes', async () => {
    promise([PASSING_PROMISE[0], '3\tA fleet\tEvery ticket closes with proof.\tshown_true\tPR 6100 and PROOF o12']);
    doneWorld();
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/PASS\s+promise-proof\s+2 sentences shown true, each with its proof/);
  });

  it('R2b: a placeholder proof fails promise-proof', async () => {
    promise([PASSING_PROMISE[0], '3\tA fleet\tEvery ticket closes with proof.\tshown_true\ttbd']);
    doneWorld();
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/FAIL\s+promise-proof\s+no proof: 3 /);
  });

  it('R2c: no promise record fails promise-proof and does not throw', async () => {
    rmSync(promisePath());
    doneWorld();
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/FAIL\s+promise-proof\s+no promise record at /);
    expect(process.exitCode).toBe(1);
  });

  it('R2d: a wrong header, a 3-field row, a 6-field row and a header-only file each fail with a reason, no throw', async () => {
    promise(PASSING_PROMISE, 'n\tpart\ttext\tstate');
    doneWorld();
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/FAIL\s+promise-proof\s+bad header in /);
    vi.mocked(console.log).mockClear();
    promise([PASSING_PROMISE[0], '2\tA fleet\tshort row']);
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/FAIL\s+promise-proof\s+bad row 3 in .*: 3 fields/);
    vi.mocked(console.log).mockClear();
    promise([PASSING_PROMISE[0], '2\tA\tB\tshown_true\tproof\textra']);
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/FAIL\s+promise-proof\s+bad row 3 in .*: 6 fields/);
    vi.mocked(console.log).mockClear();
    promise([]);
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/FAIL\s+promise-proof\s+no sentences in /);
    vi.mocked(console.log).mockClear();
    promise([PASSING_PROMISE[0], '1\tA\tSame number again.\tshown_true\tPR 6102']);
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/FAIL\s+promise-proof\s+bad row 3 in .*: duplicate sentence 1/);
    vi.mocked(console.log).mockClear();
    promise([PASSING_PROMISE[0], '2\tA\t \tshown_true\tPR 6102']);
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/FAIL\s+promise-proof\s+bad row 3 in .*: blank sentence number or text/);
    vi.mocked(console.log).mockClear();
    promise([PASSING_PROMISE[0], '\tA\tNo number.\tshown_true\tPR 6102']);
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/FAIL\s+promise-proof\s+bad row 3 in .*: blank sentence number or text/);
    vi.mocked(console.log).mockClear();
    promise(PASSING_PROMISE);
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/PASS\s+promise-proof/);
  });

  it('R2e: shown_true with a blank proof fails in the 4-field, trailing-tab and whitespace-with-CR forms', async () => {
    for (const row of ['3\tA\tText three.\tshown_true', '3\tA\tText three.\tshown_true\t', '3\tA\tText three.\tshown_true\t  \r']) {
      vi.mocked(console.log).mockClear();
      promise([PASSING_PROMISE[0], row]);
      doneWorld();
      await run(['version-ready', 'v1.1.3']);
      expect(out()).toMatch(/FAIL\s+promise-proof\s+no proof: 3 /);
    }
    vi.mocked(console.log).mockClear();
    promise(PASSING_PROMISE);
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/PASS\s+promise-proof/);
  });

  it('R3: an open owed step on a member fails owed-steps by key and row id and exits 1; a non-member passes', async () => {
    probe.owedOpen = vi.fn(() => [{ id: 'o1', kind: 'step', key: 'HIM-2', actor: 'operator', text: 'run the Mac proof' }]);
    doneWorld({ owedMembers: [issue('HIM-2', 'new')] });
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/FAIL\s+owed-steps\s+open: HIM-2 o1 \(operator\) "run the Mac proof"/);
    expect(process.exitCode).toBe(1);
    vi.mocked(console.log).mockClear();
    doneWorld({ owedMembers: [] });
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/PASS\s+owed-steps\s+no open owed step on a member/);
  });

  it('R3 control: a notify row, or a row whose key is not a ticket key, passes and sends no owed search', async () => {
    probe.owedOpen = vi.fn(() => [
      { id: 'o1', kind: 'step', key: 'HIM-2', action: 'notify', text: 'reminder' },
      { id: 'o2', kind: 'step', key: '5f3a9c1', text: 'keyless' },
    ]);
    doneWorld({ owedMembers: [issue('HIM-2', 'new')] });
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/PASS\s+owed-steps/);
    expect(jqls().some((j) => j.startsWith('key in (') && j.includes(' AND fixVersion="'))).toBe(false);
  });

  it('R3b: an owe.sh failure fails owed-steps as unreadable', async () => {
    probe.owedOpen = vi.fn(() => {
      throw new Error('owe.sh exit 4');
    });
    doneWorld();
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/FAIL\s+owed-steps\s+owed ledger unreadable: owe\.sh exit 4/);
  });

  it('R3c: a missing owed ledger fails owed-steps and owe.sh is not called', async () => {
    rmSync(join(bucket, 'owed.jsonl'));
    doneWorld();
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/FAIL\s+owed-steps\s+no owed ledger at /);
    expect(owedMock()).not.toHaveBeenCalled();
  });

  it('R3d: a state dir that is not <bucket>/release fails both new rows with cannot place the bucket', async () => {
    process.env.HIMMEL_RELEASE_STATE_DIR = join(tmp, 'state');
    doneWorld();
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/FAIL\s+promise-proof\s+cannot place the bucket/);
    expect(out()).toMatch(/FAIL\s+owed-steps\s+cannot place the bucket/);
    vi.mocked(console.log).mockClear();
    process.env.HIMMEL_RELEASE_STATE_DIR = join(tmp, 'release');
    await run(['version-ready', 'v1.1.3']);
    expect(out()).not.toMatch(/cannot place the bucket/);
  });

  it('R3e: probes.bucket throwing fails both new rows and the other five rows still print', async () => {
    probe.bucket = () => {
      throw new Error('release: set USER_SLUG');
    };
    doneWorld();
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/FAIL\s+promise-proof\s+cannot place the bucket: release: set USER_SLUG/);
    expect(out()).toMatch(/FAIL\s+owed-steps\s+cannot place the bucket: release: set USER_SLUG/);
    for (const id of ROW_IDS.slice(0, 5)) expect(out()).toMatch(new RegExp(`^PASS\\t${id}\\t`, 'm'));
  });

  it('R3f: the default owed reader runs owe.sh list --json with a large buffer and reads a JSON array only', () => {
    const owe = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..', 'handover', 'chief-kit', 'owe.sh');
    exec.mockReturnValue('[]');
    expect(owedOpenDefault(tmp)).toEqual([]);
    const call = exec.mock.calls[0];
    expect(call[0]).toBe('bash');
    expect(call[1]).toEqual([owe, 'list', '--bucket', tmp, '--json']);
    expect(existsSync(owe)).toBe(true);
    expect((call[2] as { maxBuffer: number }).maxBuffer).toBeGreaterThanOrEqual(64 * 1024 * 1024);
    exec.mockReturnValue('{}');
    expect(() => owedOpenDefault(tmp)).toThrow(/not a JSON array/);
    exec.mockImplementation(() => {
      throw new Error('owe.sh exit 4');
    });
    expect(() => owedOpenDefault(tmp)).toThrow(/exit 4/);
  });

  it('R3f through the row: a non-array answer and a throw both read as owed ledger unreadable', async () => {
    probe.owedOpen = owedOpenDefault;
    doneWorld();
    exec.mockReturnValue('{}');
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/FAIL\s+owed-steps\s+owed ledger unreadable: .*not a JSON array/);
    vi.mocked(console.log).mockClear();
    exec.mockImplementation(() => {
      throw new Error('owe.sh exit 4');
    });
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/FAIL\s+owed-steps\s+owed ledger unreadable: .*exit 4/);
    vi.mocked(console.log).mockClear();
    exec.mockReset();
    exec.mockReturnValue('[]');
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/PASS\s+owed-steps/);
  });

  it('R3g: a failing Jira search for the owed members fails owed-steps as unreadable, no throw', async () => {
    probe.owedOpen = vi.fn(() => [{ id: 'o1', kind: 'step', key: 'HIM-2', actor: 'operator', text: 'x' }]);
    doneWorld();
    const routed = mockRequest.getMockImplementation()!;
    mockRequest.mockImplementation(async (method: string, path: string, body?: unknown) => {
      const jql = decodeURIComponent(path.split('jql=')[1]?.split('&')[0] ?? '');
      if (jql.includes('key in (') && jql.includes(' AND fixVersion="')) throw new Error('HTTP 500');
      return routed(method, path, body);
    });
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/FAIL\s+owed-steps\s+owed ledger unreadable: HTTP 500/);
  });

  it('R4: one FAIL row makes the command exit 1', async () => {
    world({ description: FROZEN_DESC, frozen: [issue('HIM-1', 'done'), issue('HIM-2', 'new')] });
    await run(['version-ready', 'v1.1.3']);
    expect(fails()).toHaveLength(1);
    expect(out()).toMatch(/FAIL\s+frozen-set.*HIM-2/);
    expect(process.exitCode).toBe(1);
  });

  it('R10: a red main-ci, an unfolded done-fold and an open station-adhoc each alone exit 1', async () => {
    probe.mainCi = vi.fn(() => ({ ok: false, detail: 'ci red' }));
    doneWorld({ blockers: [], unfolded: [] });
    await run(['version-ready', 'v1.1.3']);
    expect(fails()).toHaveLength(1);
    expect(out()).toMatch(/FAIL\s+main-ci/);
    expect(process.exitCode).toBe(1);
    process.exitCode = undefined;
    vi.mocked(console.log).mockClear();
    probe.mainCi = vi.fn(() => ({ ok: true, detail: 'green' }));
    doneWorld({ unfolded: [issue('HIM-2', 'done')] });
    await run(['version-ready', 'v1.1.3']);
    expect(fails()).toHaveLength(1);
    expect(out()).toMatch(/FAIL\s+done-fold/);
    expect(process.exitCode).toBe(1);
    process.exitCode = undefined;
    vi.mocked(console.log).mockClear();
    doneWorld({ open: [issue('HIM-9', 'new', ['station-adhoc'])] });
    await run(['version-ready', 'v1.1.3']);
    expect(fails()).toHaveLength(1);
    expect(out()).toMatch(/FAIL\s+station-adhoc.*HIM-9/);
    expect(process.exitCode).toBe(1);
  });

  it('R5: --sha reaches main-ci; without it main-ci reads main; a short or uppercase sha is refused', async () => {
    doneWorld();
    await run(['version-ready', 'v1.1.3', '--sha', SHA]);
    expect(mainCiMock().mock.calls[0][0]).toBe(SHA);
    mainCiMock().mockClear();
    await run(['version-ready', 'v1.1.3']);
    expect(mainCiMock().mock.calls[0][0]).toBeUndefined();
    await expect(run(['version-ready', 'v1.1.3', '--sha', 'abc1234'])).rejects.toThrow(/40 hex/);
    await expect(run(['version-ready', 'v1.1.3', '--sha', 'A'.repeat(40)])).rejects.toThrow(/40 hex/);
  });

  it('R6: an unfrozen version fails frozen-set on an open member, and done-fold says it checks nothing', async () => {
    world({ description: 'no freeze here', open: [issue('HIM-5', 'new')] });
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/FAIL\s+frozen-set\s+not frozen; open: HIM-5/);
    expect(out()).toMatch(/PASS\s+done-fold\s+not frozen: this row checks nothing here; READY row 6 reads the fold/);
    vi.mocked(console.log).mockClear();
    world({ description: 'no freeze here', open: [] });
    await run(['version-ready', 'v1.1.3']);
    expect(out()).toMatch(/PASS\s+frozen-set\s+not frozen; every member Done/);
  });

  describe('R7: main-ci judges the newest run of each workflow and event', () => {
    const run1 = (workflowName: string, event: string, number: number, conclusion: string) => ({
      workflowName, event, number, conclusion, headSha: SHA,
    });
    const gh = (runs: unknown[]) => exec.mockImplementation(() => JSON.stringify(runs));

    it('a red dispatch run followed by a green one at the same sha passes', () => {
      gh([run1('CI', 'workflow_dispatch', 10, 'failure'), run1('CI', 'workflow_dispatch', 11, 'success')]);
      expect(mainCiGreen(SHA)).toEqual({ ok: true, detail: `1 workflow(s) green at ${SHA.slice(0, 9)}` });
      const listArgs = exec.mock.calls[0][1] as string[];
      expect(listArgs[listArgs.indexOf('--json') + 1]).toMatch(/number/);
      expect(listArgs[listArgs.indexOf('--json') + 1]).toMatch(/event/);
      expect(listArgs[listArgs.indexOf('--json') + 1]).toMatch(/workflowDatabaseId/);
    });

    it('two workflows that share a display name are judged apart by workflow id', () => {
      gh([
        { ...run1('CI', 'schedule', 10, 'failure'), workflowDatabaseId: 1 },
        { ...run1('CI', 'schedule', 11, 'success'), workflowDatabaseId: 2 },
      ]);
      expect(mainCiGreen(SHA).ok).toBe(false);
      gh([
        { ...run1('CI', 'schedule', 10, 'success'), workflowDatabaseId: 1 },
        { ...run1('CI', 'schedule', 11, 'success'), workflowDatabaseId: 2 },
      ]);
      expect(mainCiGreen(SHA).detail).toBe(`2 workflow(s) green at ${SHA.slice(0, 9)}`);
    });

    it('n counts the workflow and event pairs judged', () => {
      gh([
        run1('CI', 'workflow_dispatch', 10, 'failure'),
        run1('CI', 'workflow_dispatch', 11, 'success'),
        run1('CI', 'schedule', 5, 'success'),
      ]);
      expect(mainCiGreen(SHA).detail).toBe(`2 workflow(s) green at ${SHA.slice(0, 9)}`);
    });

    it('controls: the newest run red, or a red schedule run beside a green dispatch, fails', () => {
      gh([run1('CI', 'workflow_dispatch', 10, 'success'), run1('CI', 'workflow_dispatch', 11, 'failure')]);
      expect(mainCiGreen(SHA).ok).toBe(false);
      gh([run1('CI', 'schedule', 10, 'failure'), run1('CI', 'workflow_dispatch', 11, 'success')]);
      expect(mainCiGreen(SHA).ok).toBe(false);
    });
  });

  it('R8: --out writes the printed rows, sha=, at= and last exit=, overwrites in place, and needs --sha', async () => {
    const file = join(tmp, 'vr.txt');
    world({ description: FROZEN_DESC, frozen: [issue('HIM-1', 'done'), issue('HIM-2', 'new')] });
    await run(['version-ready', 'v1.1.3', '--sha', SHA, '--out', file]);
    const lines = readFileSync(file, 'utf8').trimEnd().split('\n');
    expect(`${lines.slice(0, -3).join('\n')}`).toBe(out());
    expect(lines.slice(-3)[0]).toBe(`sha=${SHA}`);
    expect(lines.slice(-3)[1]).toMatch(/^at=\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$/);
    expect(lines.at(-1)).toBe('exit=1');
    process.exitCode = undefined;
    vi.mocked(console.log).mockClear();
    doneWorld();
    await run(['version-ready', 'v1.1.3', '--sha', SHA, '--out', file]);
    expect(readFileSync(file, 'utf8').trimEnd().split('\n').at(-1)).toBe('exit=0');
    expect(readdirSync(tmp).filter((f) => f.startsWith('vr.txt'))).toEqual(['vr.txt']);
    mockRequest.mockClear();
    await expect(run(['version-ready', 'v1.1.3', '--out', file])).rejects.toThrow(/--out needs --sha/);
    expect(mockRequest).not.toHaveBeenCalled();
  });

  it('R8b: a run that fails before it can publish leaves no earlier --out file behind', async () => {
    const file = join(tmp, 'vr.txt');
    writeFileSync(file, 'PASS\tfrozen-set\told\nsha=old\nexit=0\n');
    world({ description: FROZEN_DESC });
    await expect(run(['version-ready', 'v9.9.9', '--sha', SHA, '--out', file])).rejects.toThrow(/no version named/);
    expect(existsSync(file)).toBe(false);
  });

  it('R9: --out refuses --chief-override before any request; --chief-override alone still works', async () => {
    const file = join(tmp, 'vr.txt');
    world({ description: FROZEN_DESC, frozen: [issue('HIM-1', 'done'), issue('HIM-2', 'new')] });
    await expect(
      run(['version-ready', 'v1.1.3', '--sha', SHA, '--out', file, '--chief-override', 'frozen-set', 'x']),
    ).rejects.toThrow(/--out refuses --chief-override/);
    expect(mockRequest).not.toHaveBeenCalled();
    expect(existsSync(file)).toBe(false);
    await run(['version-ready', 'v1.1.3', '--chief-override', 'frozen-set', 'moves']);
    expect(out()).toMatch(/PASS\s+frozen-set.*overridden/);
  });

  it('C1: with every row passing it prints one PASS line per row, exits 0 and reads only', async () => {
    doneWorld();
    await run(['version-ready', 'v1.1.3']);
    const ids = out().split('\n').filter((l) => /^(PASS|FAIL)\t/.test(l)).map((l) => l.split('\t')[1]);
    expect(ids).toEqual(ROW_IDS);
    expect(out()).not.toMatch(/^FAIL/m);
    expect(process.exitCode).toBeUndefined();
    expect(mockRequest.mock.calls.every((c) => c[0] === 'GET')).toBe(true);
    expect(jqls().some((j) => j.startsWith('key in (') && j.includes(' AND fixVersion="'))).toBe(false);
    expect(owedMock()).toHaveBeenCalledTimes(1);
  });
});
