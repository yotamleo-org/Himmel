import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { Command } from 'commander';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

vi.mock('../client.js', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../client.js')>();
  return { ...actual, request: vi.fn() };
});
vi.mock('../breadcrumb.js', () => ({ writeJiraBreadcrumb: vi.fn() }));

import { request } from '../client.js';
import { writeJiraBreadcrumb } from '../breadcrumb.js';
import { registerVersions } from './versions.js';

const mockRequest = request as unknown as ReturnType<typeof vi.fn>;

function run(args: string[]): Promise<Command> {
  const p = new Command();
  p.exitOverride();
  registerVersions(p);
  return p.parseAsync(['node', 'jira', ...args]);
}

const VERSIONS = [
  { id: '100', name: 'v1', self: 'https://j/rest/api/3/version/100', released: true, releaseDate: '2026-01-01' },
  { id: '101', name: 'v2', self: 'https://j/rest/api/3/version/101', archived: true },
];

describe('version commands + fix-version', () => {
  const savedKey = process.env.JIRA_PROJECT_KEY;
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    process.env.JIRA_PROJECT_KEY = 'HIM';
  });
  afterEach(() => {
    if (savedKey === undefined) delete process.env.JIRA_PROJECT_KEY;
    else process.env.JIRA_PROJECT_KEY = savedKey;
  });

  it('versions: GET /project/<key>/versions, prints name/released/date/archived rows', async () => {
    mockRequest.mockResolvedValue(VERSIONS);
    await run(['versions']);
    expect(mockRequest).toHaveBeenCalledWith('GET', '/project/HIM/versions');
    expect(console.log).toHaveBeenNthCalledWith(1, 'v1\ttrue\t2026-01-01\tfalse');
    expect(console.log).toHaveBeenNthCalledWith(2, 'v2\tfalse\t\ttrue');
  });

  it('versions --project overrides the env key', async () => {
    mockRequest.mockResolvedValue([]);
    await run(['versions', '--project', 'OTH']);
    expect(mockRequest).toHaveBeenCalledWith('GET', '/project/OTH/versions');
  });

  it('version-create: POST /version with name/project/dates/released/description', async () => {
    mockRequest.mockResolvedValue({ id: '200', name: 'v3.0.0' });
    await run(['version-create', ' v3.0.0 ', '--start-date', '2026-02-01', '--release-date', '2026-03-01', '--released', '--description', 'd']);
    expect(mockRequest).toHaveBeenCalledWith('POST', '/version', {
      name: 'v3.0.0',
      project: 'HIM',
      description: 'd',
      startDate: '2026-02-01',
      releaseDate: '2026-03-01',
      released: true,
    });
    expect(console.log).toHaveBeenCalledWith('Created version v3.0.0 (id 200)');
  });

  it('version-create with a bad date rejects before any request', async () => {
    await expect(run(['version-create', 'v3.0.0', '--release-date', '2026-02-30'])).rejects.toThrow(/--release-date must be YYYY-MM-DD/);
    expect(mockRequest).not.toHaveBeenCalled();
  });

  it('version-edit: finds the id, PUTs only the given fields', async () => {
    mockRequest.mockImplementation(async (m: string) => (m === 'GET' ? VERSIONS : {}));
    await run(['version-edit', 'v2', '--start-date', '2026-04-01']);
    expect(mockRequest).toHaveBeenCalledWith('PUT', '/version/101', { startDate: '2026-04-01' });
    expect(console.log).toHaveBeenCalledWith('Edited version v2');
  });

  it('version-edit --name: PUTs the new name in place (HIMMEL-4872)', async () => {
    mockRequest.mockImplementation(async (m: string) => (m === 'GET' ? VERSIONS : {}));
    await run(['version-edit', 'v2', '--name', 'v1.1.0']);
    expect(mockRequest).toHaveBeenCalledWith('PUT', '/version/101', { name: 'v1.1.0' });
    expect(console.log).toHaveBeenCalledWith('Edited version v2');
  });

  it('version-edit --name refuses a non-semver name before any request (HIMMEL-4872)', async () => {
    await expect(run(['version-edit', 'v2', '--name', 'v1.0.2b'])).rejects.toThrow(/semver/);
    expect(mockRequest).not.toHaveBeenCalled();
  });

  it('version-create refuses a non-semver name before any request (HIMMEL-4872)', async () => {
    await expect(run(['version-create', 'v1.0.2i'])).rejects.toThrow(/semver/);
    expect(mockRequest).not.toHaveBeenCalled();
  });

  it('version-edit with nothing to edit rejects without a request', async () => {
    await expect(run(['version-edit', 'v2'])).rejects.toThrow(/nothing to edit/);
    expect(mockRequest).not.toHaveBeenCalled();
  });

  it('version-release --date: PUT released:true + releaseDate', async () => {
    mockRequest.mockImplementation(async (m: string) => (m === 'GET' ? VERSIONS : {}));
    await run(['version-release', 'v2', '--date', '2026-05-05']);
    expect(mockRequest).toHaveBeenCalledWith('PUT', '/version/101', { released: true, releaseDate: '2026-05-05' });
    expect(console.log).toHaveBeenCalledWith('Released version v2');
  });

  it('version-release of an unknown version rejects and never PUTs', async () => {
    mockRequest.mockResolvedValue(VERSIONS);
    await expect(run(['version-release', 'nope'])).rejects.toThrow('no version named "nope" in project HIM');
    expect(mockRequest.mock.calls.some((c) => c[0] === 'PUT')).toBe(false);
  });

  it('version-move --position First: POST /version/<id>/move {position}', async () => {
    mockRequest.mockImplementation(async (m: string) => (m === 'GET' ? VERSIONS : {}));
    await run(['version-move', 'v2', '--position', 'First']);
    expect(mockRequest).toHaveBeenCalledWith('POST', '/version/101/move', { position: 'First' });
    expect(console.log).toHaveBeenCalledWith('Moved version v2 to First');
  });

  it('version-move --after: sends the anchor self URL', async () => {
    mockRequest.mockImplementation(async (m: string) => (m === 'GET' ? VERSIONS : {}));
    await run(['version-move', 'v2', '--after', 'v1']);
    expect(mockRequest).toHaveBeenCalledWith('POST', '/version/101/move', { after: 'https://j/rest/api/3/version/100' });
    expect(console.log).toHaveBeenCalledWith('Moved version v2 after v1');
  });

  it('fix-version --add: PUT update.fixVersions add, breadcrumb, line', async () => {
    mockRequest.mockImplementation(async (_m: string, path: string) =>
      path.endsWith('/versions') ? VERSIONS : { fields: { fixVersions: [{ name: 'v2' }] } });
    await run(['fix-version', 'HIM-9', '--add', 'v2']);
    expect(mockRequest).toHaveBeenCalledWith('PUT', '/issue/HIM-9', { update: { fixVersions: [{ add: { name: 'v2' } }] } });
    expect(writeJiraBreadcrumb).toHaveBeenCalledWith('HIM-9');
    expect(console.log).toHaveBeenCalledWith('HIM-9 fixVersion +v2');
  });

  it('fix-version --remove: remove verb and - sign', async () => {
    mockRequest.mockResolvedValue({ fields: { fixVersions: [] } });
    await run(['fix-version', 'HIM-9', '--remove', 'v1']);
    expect(mockRequest).toHaveBeenCalledWith('PUT', '/issue/HIM-9', { update: { fixVersions: [{ remove: { name: 'v1' } }] } });
    expect(console.log).toHaveBeenCalledWith('HIM-9 fixVersion -v1');
  });

  it('fix-version needs exactly one of --add/--remove', async () => {
    await expect(run(['fix-version', 'HIM-9'])).rejects.toThrow(/exactly one of --add/);
    await expect(run(['fix-version', 'HIM-9', '--add', 'a', '--remove', 'b'])).rejects.toThrow(/exactly one of --add/);
    expect(mockRequest).not.toHaveBeenCalled();
  });
});

describe('fix-version --add into a frozen version (HIMMEL-7153)', () => {
  const FROZEN = [{ id: '300', name: 'v1.1.3', description: 'frozen: 2026-10-20\nfrozen-keys: HIM-1' }, ...VERSIONS];
  const saved = { key: process.env.JIRA_PROJECT_KEY, ledger: process.env.HIMMEL_ADMISSIONS_LEDGER, console: process.env.HIMMEL_CONSOLE };
  let dir: string;
  let ledger: string;
  const puts = () => mockRequest.mock.calls.filter((c) => c[0] === 'PUT');
  const rows = () => readFileSync(ledger, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l) as Record<string, string>);
  const readBack = (names: string[]) => async (_m: string, path: string) =>
    path.endsWith('/versions') ? FROZEN : { fields: { fixVersions: names.map((name) => ({ name })) } };

  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    dir = mkdtempSync(join(tmpdir(), 'fixver-gate-'));
    ledger = join(dir, 'admissions-ledger.jsonl');
    process.env.JIRA_PROJECT_KEY = 'HIM';
    process.env.HIMMEL_ADMISSIONS_LEDGER = ledger;
    delete process.env.HIMMEL_CONSOLE;
    mockRequest.mockImplementation(readBack(['v1.1.3']));
  });
  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
    for (const [k, v] of [['JIRA_PROJECT_KEY', saved.key], ['HIMMEL_ADMISSIONS_LEDGER', saved.ledger], ['HIMMEL_CONSOLE', saved.console]] as const) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  });

  it('refuses without a gate or override and writes nothing', async () => {
    await expect(run(['fix-version', 'HIM-9', '--add', 'v1.1.3'])).rejects.toThrow(/v1\.1\.3 is frozen \(2026-10-20\)/);
    expect(puts()).toHaveLength(0);
  });

  it('--gate critical adds the version and records the admission row', async () => {
    await run(['fix-version', 'HIM-9', '--add', 'v1.1.3', '--gate', 'critical']);
    expect(puts()).toHaveLength(1);
    expect(rows()).toEqual([expect.objectContaining({ version: 'v1.1.3', key: 'HIM-9', gate: 'critical' })]);
  });

  it('a bad --gate value refuses before any request', async () => {
    await expect(run(['fix-version', 'HIM-9', '--add', 'v1.1.3', '--gate', 'because'])).rejects.toThrow(/--gate must be one of/);
    expect(mockRequest).not.toHaveBeenCalled();
  });

  it('--console-override needs the console marker', async () => {
    await expect(run(['fix-version', 'HIM-9', '--add', 'v1.1.3', '--console-override', 'operator ruled'])).rejects.toThrow(/HIMMEL_CONSOLE=1 is not set/);
    expect(puts()).toHaveLength(0);
  });

  it('--console-override with the marker adds the version and records an override row', async () => {
    process.env.HIMMEL_CONSOLE = '1';
    await run(['fix-version', 'HIM-9', '--add', 'v1.1.3', '--console-override', 'operator ruled']);
    expect(puts()).toHaveLength(1);
    expect(rows()).toEqual([expect.objectContaining({ version: 'v1.1.3', key: 'HIM-9', kind: 'override', reason: 'operator ruled' })]);
  });

  it('writes no ledger row when the read-back shows the version did not land', async () => {
    mockRequest.mockImplementation(readBack([]));
    await expect(run(['fix-version', 'HIM-9', '--add', 'v1.1.3', '--gate', 'critical'])).rejects.toThrow(/was not changed/);
    expect(readFileSync(ledger, 'utf8')).toBe('');
  });

  it('an unfrozen version stays ungated', async () => {
    mockRequest.mockImplementation(readBack(['v2']));
    await run(['fix-version', 'HIM-9', '--add', 'v2']);
    expect(puts()).toHaveLength(1);
  });

  it('--remove stays ungated', async () => {
    mockRequest.mockImplementation(readBack([]));
    await run(['fix-version', 'HIM-9', '--remove', 'v1.1.3']);
    expect(puts()).toHaveLength(1);
  });

  it('--gate with --remove refuses before any request', async () => {
    await expect(run(['fix-version', 'HIM-9', '--remove', 'v1.1.3', '--gate', 'critical'])).rejects.toThrow(/--add/);
    expect(mockRequest).not.toHaveBeenCalled();
  });
});
