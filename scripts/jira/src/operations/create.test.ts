import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { Command } from 'commander';
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

vi.mock('../client.js', async (orig) => ({
  ...(await orig<typeof import('../client.js')>()),
  request: vi.fn(),
  projectKey: vi.fn(() => 'HIMMEL'),
}));
vi.mock('../breadcrumb.js', () => ({ writeJiraBreadcrumb: vi.fn() }));

import { markdownToAdf } from '../adf.js';
import { projectKey, request } from '../client.js';
import { defaultRoot, renderIssue } from '../commands/mirror.js';
import { registerRelease } from '../commands/release.js';
import { PLAIN_BLOCK_TEMPLATE } from '../plain-block.js';
import { runReadiness } from '../readiness.js';
import { CreatePartial, CreateRefused, readinessIssue, runCreate, type CreateOptions } from './create.js';
import { DISPATCHER, makeNdFixture, makeNdStub } from './readiness-stub.test-helper.js';

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
  vi.stubEnv('JIRA_ALLOW_HOST', '127.0.0.1:9');
  writeFileSync(join(root, 'verbatim.txt'), 'R1 = v1.1.3\n');
  const p = new Command();
  p.exitOverride();
  registerRelease(p);
  await p.parseAsync(['node', 'jira', 'release', 'operator', 'declare', 'R1', '--versions', 'v1.1.3', '--decision', '214', '--verbatim-file', join(root, 'verbatim.txt')]);
  mockRequest.mockReset();
  mockRequest.mockResolvedValue({ key: 'HIMMEL-1' });
  vi.mocked(projectKey).mockReturnValue('HIMMEL');
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

const gateLine = (name: string, detail = 'x') => `GATE HIMMEL-0 ${name}: ${detail}`;
const agentBody = (detail: string) => BODY.replace(/## Agent detail\nfilled\s*$/, `## Agent detail\n${detail}`);

describe('10944 runCreate asks the dispatcher before it files', () => {
  const ownConfig = (project = 'HIMMEL') => {
    const dir = join(root, `conf-${project}`);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, 'himmel.conf'), `JIRA_PROJECT_KEY=${project}\n`);
    vi.stubEnv('HIMMEL_CONFIG_DIR', dir);
  };
  const stubNd = (o: Parameters<typeof makeNdStub>[0] = {}) => {
    const stub = makeNdStub(o);
    vi.stubEnv('JIRA_READINESS_CHECK', stub.path);
    return stub;
  };
  const gated = (...names: string[]) => stubNd({ lines: names.map((n) => gateLine(n)), exit: 1 });
  const current = (o: Partial<CreateOptions> = {}) =>
    task({ backlog: false, proposedVersion: undefined, why: undefined, fixVersion: 'v1.1.3', ...o });
  const posts = () => mockRequest.mock.calls.filter((c) => c[0] === 'POST' && c[1] === '/issue');
  const postedLabels = () => (posts()[0]![2] as { fields: { labels?: string[] } }).fields.labels ?? [];
  const errors = () => vi.mocked(console.error).mock.calls.map((c) => String(c[0])).join('\n');
  const argAfter = (argv: string[], flag: string) => argv[argv.indexOf(flag) + 1];

  beforeEach(() => {
    ownConfig();
    mockRequest.mockImplementation(async (method: string, path: string) => {
      if (method === 'GET' && path.startsWith('/project/') && path.endsWith('/versions')) return [{ name: 'v1.1.3', released: false }];
      if (method === 'GET' && path.startsWith('/project/')) return {};
      if (method === 'GET' && path.startsWith('/search/jql')) return { issues: [] };
      if (method === 'GET') return { fields: { status: { name: 'To Do', statusCategory: { key: 'new' } }, fixVersions: [{ name: 'v1.1.3' }] } };
      return { key: 'HIMMEL-1' };
    });
  });

  it('10944 R1 a ticket the dispatcher reads no scope from is refused with the fix, and nothing is posted', async () => {
    const stub = gated('no-scope');
    const run = runCreate(task());
    await expect(run).rejects.toBeInstanceOf(CreateRefused);
    await expect(run).rejects.toThrow('Writes: none (no code)');
    await expect(run).rejects.toThrow('(gate: x)');
    expect(posts()).toEqual([]);
    expect(stub.calls()).toHaveLength(1);
  });

  it('10944 R1.ctl the same ticket is posted when the dispatcher passes it', async () => {
    const stub = stubNd();
    await runCreate(task());
    expect(posts()).toHaveLength(1);
    expect(stub.calls()).toHaveLength(1);
  });

  it('10944 R2 the dispatcher judges the mirror text, where adjacent markdown lines are one line', async () => {
    const stub = stubNd();
    const desc = agentBody('Follow-up of X\nWrites: specs/audits/x.md');
    await runCreate(task({ desc }));
    const [call] = stub.calls();
    expect(call!.argv.slice(0, 2)).toEqual(['--why-ticket', 'HIMMEL-0']);
    expect(call!.body).toBe(renderIssue({
      key: 'HIMMEL-0',
      fields: {
        summary: 'Planning & tracking: a ticket', issuetype: { name: 'Task' }, status: { name: 'To Do', statusCategory: { name: 'To Do' } },
        labels: ['standalone', 'backlog'], description: markdownToAdf(desc),
      },
    }, []));
    expect(call!.body).toContain('Follow-up of X Writes: specs/audits/x.md');
    expect(existsSync(argAfter(call!.argv, '--body-file')!)).toBe(false);
  });

  it.each([
    ['R3a', 'the check exits 3', () => { stubNd({ lines: ['UNKNOWN HIMMEL-0: mirror down'], exit: 3 }); }],
    ['R3b', 'the check script is absent', () => { vi.stubEnv('JIRA_READINESS_CHECK', join(root, 'absent.sh')); }],
    ['R3d', 'the check exits 1 with no GATE line', () => { stubNd({ exit: 1 }); }],
  ])('10944 %s %s: the ticket is filed with a warning', async (_row, _what, arrange) => {
    arrange();
    await runCreate(task());
    expect(posts()).toHaveLength(1);
    expect(errors()).toMatch(/jira: warning: readiness check not run \(.+\); filed without it/);
  });

  it('10944 R3c a check that never answers is killed at the deadline and the ticket is filed with a warning', async () => {
    const stub = stubNd({ sleepMs: 20_000 });
    vi.stubEnv('JIRA_READINESS_TIMEOUT_MS', '200');
    await runCreate(task());
    expect(posts()).toHaveLength(1);
    expect(errors()).toMatch(/jira: warning: readiness check not run \(timed out.*\); filed without it/);
    await vi.waitFor(() => expect(stub.alive()).toBe(false));
  });

  it('10944 R4 a current-version filing the filer must act on is filed with needs-readiness and its gates shown', async () => {
    gated('no-proof');
    await runCreate(current());
    expect(postedLabels()).toContain('needs-readiness');
    expect(errors()).toContain(gateLine('no-proof'));
  });

  it.each([
    ['R4.core', 'a gate that is a new ticket\'s normal state', () => gated('core-no-spec'), current],
    ['R4.ctl', 'a ready ticket', () => stubNd(), current],
    ['R4.bl', 'a backlog filing', () => gated('no-proof'), task],
  ])('10944 %s %s gets no label', async (_row, _what, arrange, filing) => {
    arrange();
    await runCreate(filing());
    expect(posts()).toHaveLength(1);
    expect(postedLabels()).not.toContain('needs-readiness');
  });

  it.each([
    ['R4.bl-scope', 'a backlog filing', () => task()],
    ['R4.park', 'a parked filing', () => task({ labels: 'standalone,placeholder' })],
  ])('10944 %s %s with no scope is refused too', async (_row, _what, filing) => {
    gated('no-scope');
    await expect(runCreate(filing())).rejects.toBeInstanceOf(CreateRefused);
    expect(posts()).toEqual([]);
  });

  it('10944 R4.link the dispatcher sees the links the filing will create', async () => {
    const stub = stubNd();
    await runCreate(task({ blockedBy: 'HIMMEL-5', blocks: ['HIMMEL-6'], splitFrom: 'HIMMEL-7' }));
    const body = stub.calls()[0]!.body!;
    expect(body).toContain('  blocks: ["HIMMEL-6"]');
    expect(body).toContain('  blocked_by: ["HIMMEL-5"]');
    expect(body).toContain('  relates: ["relates to HIMMEL-7"]');
  });

  it.each([
    ['an Epic', () => runCreate(task({ type: 'Epic', labels: undefined, backlog: false, proposedVersion: undefined, why: undefined }))],
    ['another project named by --project', () => runCreate(task({ project: 'OTHER' }))],
    ['another project named by the environment', () => {
      vi.stubEnv('JIRA_PROJECT_KEY', 'OTHER');
      vi.mocked(projectKey).mockReturnValue('OTHER');
      return runCreate(task());
    }],
    ['a station whose files name no project', () => {
      vi.stubEnv('HIMMEL_CONFIG_DIR', mkdtempSync(join(root, 'empty-conf-')));
      return runCreate(task());
    }],
    ['the test project', () => {
      writeFileSync(join(process.env.HIMMEL_CONFIG_DIR!, 'himmel.conf.local'), 'JIRA_TEST_PROJECT=ZZTEST\n');
      return runCreate(task({ project: 'ZZTEST' }));
    }],
  ])('10944 R5 %s runs no check', async (_what, filing) => {
    const stub = gated('no-scope');
    await filing().catch((e: Error) => { throw new Error(`filing failed: ${e.message}`); });
    expect(stub.calls()).toEqual([]);
  });

  it('10944 R5.env the filer\'s shell cannot steer the check to another tree, mirror or gh', async () => {
    for (const name of ['NEXT_DISPATCH_MIRROR', 'NEXT_DISPATCH_GIT_DIR', 'NEXT_DISPATCH_GH_CMD']) vi.stubEnv(name, join(root, 'steered'));
    const stub = stubNd();
    await runCreate(task());
    const [call] = stub.calls();
    expect(Object.keys(call!.env).filter((k) => k.startsWith('NEXT_DISPATCH_'))).toEqual(['NEXT_DISPATCH_DEADLINE']);
    expect(call!.env).toMatchObject({ NEXT_DISPATCH_DEADLINE: '25', JIRA_PROJECT_KEY: 'HIMMEL' });
    expect(argAfter(call!.argv, '--mirror')).toBe(defaultRoot('HIMMEL'));
  });

  it('10944 R5.mirror a station that moved its mirror is checked against the moved one', async () => {
    vi.stubEnv('HIMMEL_JIRA_MIRROR', join(root, 'moved-mirror'));
    const stub = stubNd();
    await runCreate(task());
    expect(argAfter(stub.calls()[0]!.argv, '--mirror')).toBe(join(root, 'moved-mirror'));
  });

  it('10944 R6 a dry run is refused before it reports checked', async () => {
    gated('no-scope');
    await expect(runCreate(task(), { check: true })).rejects.toBeInstanceOf(CreateRefused);
  });
});

describe('10944 R8 the dispatcher of this checkout reads the filed text', () => {
  const hint = PLAIN_BLOCK_TEMPLATE.split('## Agent detail\n')[1]!.trim();
  const fixture = makeNdFixture();

  async function judge(detail: string) {
    vi.stubEnv('JIRA_READINESS_CHECK', DISPATCHER);
    const bodyFile = join(mkdtempSync(join(root, 'body-')), 'HIMMEL-0.md');
    const fields = { summary: 'Planning & tracking: a ticket', labels: ['standalone'] };
    writeFileSync(bodyFile, renderIssue(readinessIssue('Task', markdownToAdf(agentBody(detail)), fields, [], 'HIMMEL'), []));
    return runReadiness({ key: 'HIMMEL-0', bodyFile }, 'HIMMEL', undefined, fixture);
  }
  const names = (r: { gates: Array<{ name: string }> }) => r.gates.map((g) => g.name);

  it('10944 R8 a Writes line that markdown joined to the line above is read, and without it the ticket is scopeless', async () => {
    const [scoped, bare] = await Promise.all([judge('Follow-up of X\nWrites: specs/audits/x.md'), judge('Follow-up of X')]);
    expect(scoped).toMatchObject({ exit: 0, gates: [] });
    expect(scoped.warning).toBeUndefined();
    expect(names(bare)).toContain('no-scope');
  });

  it('10944 R8.hint the unedited hint is never read as a scope line', async () => {
    const [prose, mentioned, read] = await Promise.all(
      ['Some prose.', 'see specs/audits/x.md', 'scripts/lib/a.sh'].map((next) => judge(`${hint}\n${next}`)),
    );
    expect(names(prose!)).toContain('no-scope');
    expect(names(mentioned!)).toContain('no-scope');
    expect(read!.warning).toBeUndefined();
    expect(names(read!)).not.toContain('no-scope');
    const scope = read!.lines.filter((l) => l.startsWith('# scope '));
    expect(scope).toEqual([expect.stringMatching(/^# scope HIMMEL-0 description: scripts\/lib\/a\.sh /)]);
    expect(scope[0]).not.toMatch(/Writes:| nowrite/);
  });
});
