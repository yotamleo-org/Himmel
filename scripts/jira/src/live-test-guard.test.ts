import { describe, it, expect, afterEach } from 'vitest';
import { spawn } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, symlinkSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  isClaudeProc, jiraIsLoopback, jiraIsUnreachable, liveTestContext, parseOwnKeys, resolveTestProject,
  splitUploadUrl, testProjectConfigDir, writeTargets,
} from './live-test-guard.js';

const here = dirname(fileURLToPath(import.meta.url));
const temps: string[] = [];
const temp = (prefix: string): string => {
  const d = mkdtempSync(join(tmpdir(), prefix));
  temps.push(d);
  return d;
};
afterEach(() => {
  for (const d of temps.splice(0)) rmSync(d, { recursive: true, force: true });
});

function station(files: { local?: string; conf?: string }): string {
  const dir = temp('ltg-conf-');
  if (files.local !== undefined) writeFileSync(join(dir, 'himmel.conf.local'), files.local);
  if (files.conf !== undefined) writeFileSync(join(dir, 'himmel.conf'), files.conf);
  return dir;
}

// A fake /proc built the way scripts/lib/test-chokepoint-seam-guard.sh builds its tree: status with PPid,
// NUL-separated environ and cmdline, and an exe symlink.
interface FakeProc { pid: number; ppid: number; exe?: string; argv?: string[]; environ?: string[] | null; status?: string }
function fakeProc(procs: FakeProc[]): string {
  const root = temp('ltg-proc-');
  for (const p of procs) {
    const d = join(root, String(p.pid));
    mkdirSync(d);
    writeFileSync(join(d, 'status'), p.status ?? `Name:\tx\nPPid:\t${p.ppid}\n`);
    writeFileSync(join(d, 'cmdline'), (p.argv ?? ['x']).map((a) => `${a}\0`).join(''));
    if (p.environ !== null) writeFileSync(join(d, 'environ'), (p.environ ?? []).map((e) => `${e}\0`).join(''));
    if (p.exe) symlinkSync(p.exe, join(d, 'exe'));
  }
  return root;
}
const init: FakeProc = { pid: 1, ppid: 0, exe: '/usr/lib/systemd/systemd', argv: ['/sbin/init'] };
const claude = (pid: number, ppid: number, environ: string[] | null = []): FakeProc =>
  ({ pid, ppid, exe: '/x/bin/claude', argv: ['claude'], environ });
const bash = (pid: number, ppid: number, environ: string[] = []): FakeProc =>
  ({ pid, ppid, exe: '/usr/bin/bash', argv: ['bash'], environ });
const self = (pid: number, ppid: number): FakeProc => ({ pid, ppid, exe: '/usr/bin/node', argv: ['node', 'dist/index.js'] });

describe('resolveTestProject', () => {
  it('I6 reads JIRA_TEST_PROJECT from himmel.conf.local over himmel.conf, ignoring process env, project .env and profiles', () => {
    const dir = station({ local: 'JIRA_TEST_PROJECT=HTEST\n', conf: 'JIRA_TEST_PROJECT=OTHER\nHIMMEL_PROFILE=x\n' });
    mkdirSync(join(dir, 'profiles'));
    writeFileSync(join(dir, 'profiles', 'x.conf'), 'JIRA_TEST_PROJECT=X\n');
    writeFileSync(join(dir, '.env'), 'JIRA_TEST_PROJECT=X\n');
    const prev = process.env.JIRA_TEST_PROJECT;
    process.env.JIRA_TEST_PROJECT = 'HIMMEL';
    try {
      expect(resolveTestProject(dir)).toEqual({ testProject: 'HTEST', problem: null });
    } finally {
      if (prev === undefined) delete process.env.JIRA_TEST_PROJECT; else process.env.JIRA_TEST_PROJECT = prev;
    }
  });

  it('reads a value with an inline comment and CRLF', () => {
    expect(resolveTestProject(station({ conf: 'JIRA_TEST_PROJECT=HTEST # the test project\r\n' })).testProject).toBe('HTEST');
  });

  it('an empty .local value falls through', () => {
    expect(resolveTestProject(station({ local: 'JIRA_TEST_PROJECT=\n', conf: 'JIRA_TEST_PROJECT=HTEST\n' })).testProject).toBe('HTEST');
  });

  it('no JIRA_TEST_PROJECT is no test project, with the reason', () => {
    expect(resolveTestProject(station({ conf: 'JIRA_PROJECTS=HIMMEL\n' }))).toEqual({
      testProject: null, problem: 'no JIRA_TEST_PROJECT is set in himmel.conf or himmel.conf.local',
    });
  });

  it('I7 refuses a work project, the station JIRA_PROJECT_KEY and a malformed key', () => {
    const dir = station({ conf: 'JIRA_PROJECTS=HIMMEL,LUNA\nJIRA_PROJECT_KEY=LUNA\n' });
    expect(resolveTestProject(dir, 'HIMMEL')).toEqual({ testProject: null, problem: 'HIMMEL is a work project (JIRA_PROJECTS)' });
    const keyOnly = station({ conf: 'JIRA_PROJECT_KEY=LUNA\n' });
    expect(resolveTestProject(keyOnly, 'LUNA').problem).toContain('LUNA is a work project');
    for (const bad of ['h_test', 'HT_EST']) {
      expect(resolveTestProject(dir, bad).problem).toContain('is not a Jira project key');
    }
  });

  it('I7 the project-key format matches secret-store.js project-key', () => {
    const require = createRequire(import.meta.url);
    const { validate } = require('../../himmelctl/lib/secret-store.js') as { validate: (n: string, v: string) => { ok: boolean } };
    const dir = station({});
    for (const key of ['HTEST', 'H2', 'A1B2', 'h_test', 'HT_EST', 'H', '1H', 'HTEST-1', 'htest']) {
      const ours = !(resolveTestProject(dir, key).problem ?? '').includes('is not a Jira project key');
      expect([key, ours]).toEqual([key, validate('JIRA_PROJECT_KEY', key).ok]);
    }
  });

  it('I7 the work-project keys come from the station files only', () => {
    const dir = station({ conf: 'JIRA_TEST_PROJECT=HTEST\nJIRA_PROJECTS=HIMMEL\n' });
    const project = temp('ltg-project-');
    writeFileSync(join(project, '.env'), 'JIRA_PROJECT_KEY=HTEST\n');
    const prev = { key: process.env.JIRA_PROJECT_KEY, list: process.env.JIRA_PROJECTS, cwd: process.cwd() };
    process.env.JIRA_PROJECT_KEY = 'HTEST';
    process.env.JIRA_PROJECTS = 'HTEST';
    process.chdir(project);
    try {
      expect(resolveTestProject(dir)).toEqual({ testProject: 'HTEST', problem: null });
    } finally {
      process.chdir(prev.cwd);
      if (prev.key === undefined) delete process.env.JIRA_PROJECT_KEY; else process.env.JIRA_PROJECT_KEY = prev.key;
      if (prev.list === undefined) delete process.env.JIRA_PROJECTS; else process.env.JIRA_PROJECTS = prev.list;
    }
  });
});

describe('parseOwnKeys', () => {
  it('I16 parseOwnKeys accepts and refuses own-keys.tsv', () => {
    const rows = readFileSync(join(here, 'fixtures', 'own-keys.tsv'), 'utf8').split('\n').filter((l) => l.includes('\t'));
    expect(rows.length).toBe(10);
    for (const row of rows) {
      const [value, verdict] = row.split('\t');
      expect([value, parseOwnKeys(value) !== null]).toEqual([value, verdict === 'accept']);
    }
    expect(parseOwnKeys('none')).toEqual([]);
    expect(parseOwnKeys('HIMMEL-1,LUNA-22')).toEqual(['HIMMEL-1', 'LUNA-22']);
  });
});

describe('liveTestContext', () => {
  it('I4 marker is the union of own env and every claude ancestor', () => {
    const marked = [claude(10, 1, ['HIMMEL_JIRA_LIVE_TEST=HIMMEL-1', 'HOME=/h']), bash(20, 10), self(30, 20)];
    const root = fakeProc([init, ...marked]);
    expect(liveTestContext({ procRoot: root, pid: 30, env: {} })).toMatchObject({ set: true, ownKeys: ['HIMMEL-1'] });
    expect(liveTestContext({ procRoot: root, pid: 30, env: { HIMMEL_JIRA_LIVE_TEST: '' } }).set).toBe(true);
    expect(liveTestContext({ procRoot: root, pid: 30, env: { HIMMEL_JIRA_LIVE_TEST: 'HIMMEL-1,HIMMEL-2' } }).ownKeys).toEqual(['HIMMEL-1']);
    const nested = fakeProc([init, claude(10, 1, ['HIMMEL_JIRA_LIVE_TEST=HIMMEL-1']), claude(15, 10, []), bash(20, 15), self(30, 20)]);
    expect(liveTestContext({ procRoot: nested, pid: 30, env: {} })).toMatchObject({ set: true, ownKeys: ['HIMMEL-1'] });
  });

  it('I4 a native versioned claude is recognised', () => {
    const root = fakeProc([init,
      { pid: 10, ppid: 1, exe: '/x/claude/versions/2.1.5', argv: ['2.1.5'], environ: ['HIMMEL_JIRA_LIVE_TEST=none'] },
      self(30, 10)]);
    expect(isClaudeProc(root, 10)).toBe(true);
    expect(liveTestContext({ procRoot: root, pid: 30, env: {} }).set).toBe(true);
  });

  it('I4 an npm claude is recognised', () => {
    const root = fakeProc([init,
      { pid: 10, ppid: 1, exe: '/usr/bin/node', argv: ['node', '/x/@anthropic-ai/claude-code/cli.js'], environ: ['HIMMEL_JIRA_LIVE_TEST=none'] },
      self(30, 10)]);
    expect(isClaudeProc(root, 10)).toBe(true);
    expect(liveTestContext({ procRoot: root, pid: 30, env: {} }).set).toBe(true);
  });

  it('a bash ancestor whose environ carries the marker is not a claude', () => {
    const root = fakeProc([init, bash(20, 1, ['HIMMEL_JIRA_LIVE_TEST=HIMMEL-1']), self(30, 20)]);
    expect(isClaudeProc(root, 20)).toBe(false);
    expect(liveTestContext({ procRoot: root, pid: 30, env: {} }).set).toBe(false);
  });

  it('I4 an unreadable claude ancestor environ is marked with no own keys', () => {
    const root = fakeProc([init, claude(10, 1, null), self(30, 10)]);
    expect(liveTestContext({ procRoot: root, pid: 30, env: { HIMMEL_JIRA_LIVE_TEST: 'HIMMEL-1', HIMMEL_CONFIG_DIR: '/c' } }))
      .toEqual({ set: true, ownKeys: [], configDir: null });
  });

  it('a vanished ancestor ends the walk', () => {
    // pid 20 has no entry: the walk stops there, so the marked claude above it is never read.
    const root = fakeProc([init, claude(10, 1, ['HIMMEL_JIRA_LIVE_TEST=HIMMEL-1']), self(30, 20)]);
    expect(liveTestContext({ procRoot: root, pid: 30, env: {} })).toEqual({ set: false, ownKeys: [], configDir: null });
  });

  it('a malformed status is marked', () => {
    const root = fakeProc([init, { ...bash(20, 1), status: 'Name:\tbash\n' }, self(30, 20)]);
    expect(liveTestContext({ procRoot: root, pid: 30, env: {} })).toEqual({ set: true, ownKeys: [], configDir: null });
  });

  it('I4 a real exec -a claude child is walked on the real /proc', async () => {
    const env = { ...process.env, HIMMEL_JIRA_LIVE_TEST: 'HIMMEL-1' };
    delete env.VITEST;
    const child = spawn('bash', ['-c', 'exec -a claude bash -c \'sleep 30 & echo $!; wait\''], { env, stdio: ['ignore', 'pipe', 'ignore'] });
    try {
      const grandchild = await new Promise<number>((res, rej) => {
        child.stdout.once('data', (d: Buffer) => res(Number(String(d).trim())));
        child.once('error', rej);
      });
      expect(liveTestContext({ pid: grandchild, env: {} })).toMatchObject({ set: true, ownKeys: ['HIMMEL-1'] });
      process.kill(grandchild);
    } finally {
      child.kill();
    }
  });

  it('I6 config dir comes from the outermost marked ancestor', () => {
    const root = fakeProc([init,
      claude(10, 1, ['HIMMEL_JIRA_LIVE_TEST=none', 'HIMMEL_CONFIG_DIR=/a']),
      claude(15, 10, ['HIMMEL_JIRA_LIVE_TEST=none', 'HIMMEL_CONFIG_DIR=/b']),
      self(30, 15)]);
    expect(liveTestContext({ procRoot: root, pid: 30, env: { HIMMEL_JIRA_LIVE_TEST: 'none', HIMMEL_CONFIG_DIR: '/fake' } }).configDir).toBe('/a');
    const home = fakeProc([init, claude(10, 1, ['HIMMEL_JIRA_LIVE_TEST=none', 'HOME=/h']), self(30, 10)]);
    expect(liveTestContext({ procRoot: home, pid: 30, env: {} }).configDir).toBe('/h/.himmel');
    expect(liveTestContext({ procRoot: fakeProc([init, self(30, 1)]), pid: 30, env: { HIMMEL_JIRA_LIVE_TEST: 'none', HOME: '/o' } }).configDir)
      .toBe('/o/.himmel');
  });

  it('I6 testProjectConfigDir unmarked is HIMMEL_CONFIG_DIR or HOME/.himmel', () => {
    expect(testProjectConfigDir({ VITEST: 'true', HIMMEL_CONFIG_DIR: '/c', HOME: '/h' })).toBe('/c');
    expect(testProjectConfigDir({ VITEST: 'true', HOME: '/h' })).toBe('/h/.himmel');
    expect(testProjectConfigDir({ VITEST: 'true', HIMMEL_JIRA_LIVE_TEST: 'none', HIMMEL_CONFIG_DIR: '/m' })).toBe('/m');
  });

  it('empty value is unset', () => {
    const root = fakeProc([init, self(30, 1)]);
    expect(liveTestContext({ procRoot: root, pid: 30, env: { HIMMEL_JIRA_LIVE_TEST: '' } }).set).toBe(false);
  });

  it('malformed value is set with no own keys', () => {
    const root = fakeProc([init, self(30, 1)]);
    expect(liveTestContext({ procRoot: root, pid: 30, env: { HIMMEL_JIRA_LIVE_TEST: 'himmel-1' } })).toMatchObject({ set: true, ownKeys: [] });
  });

  it('under the vitest harness the ancestor walk is skipped', () => {
    const root = fakeProc([init, claude(10, 1, ['HIMMEL_JIRA_LIVE_TEST=HIMMEL-1']), self(30, 10)]);
    expect(liveTestContext({ procRoot: root, pid: 30, env: { VITEST: 'true' } }).set).toBe(false);
  });
});

describe('writeTargets: the route table as anchored patterns', () => {
  const API = '/rest/api/3';
  const AGILE = '/rest/agile/1.0';
  it.each([
    ['GET is a read', API, 'GET', '/issue/HIMMEL-1?fields=project', undefined],
    ['approximate-count is a read', API, 'POST', '/search/approximate-count', { jql: 'project = X' }],
  ])('%s', (_name, apiBase, method, path, body) => {
    expect(writeTargets(apiBase, method, path, body)).toEqual({ kind: 'read' });
  });

  it.each([
    ['create by key', API, 'POST', '/issue', { fields: { project: { key: 'HTEST' } } },
      { kind: 'targets', project: { key: 'HTEST' }, issues: [] }],
    ['create by id', API, 'POST', '/issue', { fields: { project: { id: '10132' } } },
      { kind: 'targets', project: { id: '10132' }, issues: [] }],
    ['create with a parent and body links', API, 'POST', '/issue',
      { fields: { project: { key: 'HTEST' }, parent: { key: 'HIMMEL-2' }, issuelinks: [{ outwardIssue: { key: 'LUNA-3' } }] } },
      { kind: 'targets', project: { key: 'HTEST' }, issues: ['HIMMEL-2', 'LUNA-3'] }],
    ['edit', API, 'PUT', '/issue/HTEST-6', { update: { issuelinks: [{ add: { outwardIssue: { key: 'HIMMEL-1' } } }] } },
      { kind: 'targets', issues: ['HTEST-6', 'HIMMEL-1'] }],
    ['edit by numeric id', API, 'PUT', '/issue/10001', { fields: { summary: 's' } }, { kind: 'targets', issues: ['10001'] }],
    ['comment', API, 'POST', '/issue/HTEST-1/comment', { body: {} }, { kind: 'targets', issues: ['HTEST-1'] }],
    ['comment edit', API, 'PUT', '/issue/HTEST-1/comment/10200', { body: {} }, { kind: 'targets', issues: ['HTEST-1'] }],
    ['transition', API, 'POST', '/issue/HTEST-1/transitions', { transition: { id: '31' } }, { kind: 'targets', issues: ['HTEST-1'] }],
    ['assignee', API, 'PUT', '/issue/HTEST-1/assignee', { accountId: 'a' }, { kind: 'targets', issues: ['HTEST-1'] }],
    ['watch (a JSON string body)', API, 'POST', '/issue/HTEST-1/watchers', 'abc:123', { kind: 'targets', issues: ['HTEST-1'] }],
    ['worklog', API, 'POST', '/issue/HTEST-1/worklog', { timeSpent: '1h' }, { kind: 'targets', issues: ['HTEST-1'] }],
    ['attachments', API, 'POST', '/issue/HTEST-1/attachments', undefined, { kind: 'targets', issues: ['HTEST-1'] }],
    ['unwatch, the one query-string shape', API, 'DELETE', '/issue/HTEST-1/watchers?accountId=557058%3Aabc-12', undefined,
      { kind: 'targets', issues: ['HTEST-1'] }],
    ['issueLink create', API, 'POST', '/issueLink', { type: { name: 'Blocks' }, inwardIssue: { key: 'HTEST-1' }, outwardIssue: { key: 'HIMMEL-2' } },
      { kind: 'targets', issues: ['HTEST-1', 'HIMMEL-2'] }],
    ['issueLink delete', API, 'DELETE', '/issueLink/10010', undefined, { kind: 'targets', issues: [], links: ['10010'] }],
    ['version create by key', API, 'POST', '/version', { project: 'HTEST', name: 'v1' }, { kind: 'targets', project: { key: 'HTEST' }, issues: [] }],
    ['version create by id', API, 'POST', '/version', { projectId: 10132, name: 'v1' }, { kind: 'targets', project: { id: '10132' }, issues: [] }],
    ['version edit', API, 'PUT', '/version/100', { archived: true }, { kind: 'targets', issues: [], versions: ['100'] }],
    ['version move', API, 'POST', '/version/100/move', { position: 'First' }, { kind: 'targets', issues: [], versions: ['100'] }],
    ['rank', AGILE, 'PUT', '/issue/rank', { issues: ['HTEST-1', 'HTEST-2'], rankBeforeIssue: 'HTEST-3' },
      { kind: 'targets', issues: ['HTEST-1', 'HTEST-2', 'HTEST-3'] }],
    ['backlog', AGILE, 'POST', '/backlog/issue', { issues: ['HTEST-1'] }, { kind: 'targets', issues: ['HTEST-1'] }],
    ['sprint issue move', AGILE, 'POST', '/sprint/7/issue', { issues: ['HTEST-1', 'HIMMEL-4'] }, { kind: 'targets', issues: ['HTEST-1', 'HIMMEL-4'] }],
  ])('maps %s', (_name, apiBase, method, path, body, want) => {
    expect(writeTargets(apiBase, method, path, body)).toEqual(want);
  });

  it.each([
    ['project create', API, 'POST', '/project', { key: 'X' }],
    ['sprint create', AGILE, 'POST', '/sprint', { name: 's' }],
    ['sprint update', AGILE, 'POST', '/sprint/7', { state: 'active' }],
    ['a Confluence page', '/wiki/api/v2', 'POST', '/pages', {}],
    ['field admin', API, 'POST', '/field', {}],
    ['a dot-dot segment', API, 'POST', '/issue/HTEST-1/../HIMMEL-1/comment', {}],
    ['a percent-escape', API, 'POST', '/issue/HTEST-1/%2e%2e/comment', {}],
    ['a doubled slash', API, 'POST', '/issue//HTEST-1/comment', {}],
    ['a trailing slash', API, 'POST', '/issue/HTEST-1/comment/', {}],
    ['a query string on a write', API, 'POST', '/issue/HTEST-1/comment?x=1', {}],
    ['a lower-case key', API, 'POST', '/issue/htest-1/comment', {}],
    ['a remote link (not an enumerated sub-path)', API, 'POST', '/issue/HTEST-1/remotelink', {}],
    ['unwatch with a second parameter', API, 'DELETE', '/issue/HTEST-1/watchers?accountId=abc&x=1', undefined],
    ['unwatch with a disallowed character', API, 'DELETE', '/issue/HTEST-1/watchers?accountId=a/b', undefined],
    ['a watcher query on a POST', API, 'POST', '/issue/HTEST-1/watchers?accountId=abc', 'abc'],
    ['a malformed body key', API, 'POST', '/issueLink', { inwardIssue: { key: 'htest-1' }, outwardIssue: { key: 'HTEST-2' } }],
    ['a create with no project', API, 'POST', '/issue', { fields: { summary: 's' } }],
    ['a rank with no issues', AGILE, 'PUT', '/issue/rank', {}],
  ])('refuses %s as unknown', (_name, apiBase, method, path, body) => {
    expect(writeTargets(apiBase, method, path, body)).toEqual({ kind: 'unknown' });
  });
});

describe('splitUploadUrl', () => {
  const base = 'https://station.atlassian.net';
  it('splits an issue attachment URL', () => {
    expect(splitUploadUrl(`${base}/rest/api/3/issue/HTEST-1/attachments`, base)).toEqual({ apiBase: '/rest/api/3', path: '/issue/HTEST-1/attachments' });
  });
  it('keeps a Confluence attachment URL under /wiki (the table maps none)', () => {
    expect(splitUploadUrl(`${base}/wiki/rest/api/content/1/child/attachment`, base)).toEqual({ apiBase: '/wiki', path: '/rest/api/content/1/child/attachment' });
  });
  it('a URL not under the base is null', () => {
    expect(splitUploadUrl('https://other.atlassian.net/rest/api/3/issue/HTEST-1/attachments', base)).toBeNull();
    expect(splitUploadUrl(`${base}.evil.example/rest/api/3/issue/HTEST-1/attachments`, base)).toBeNull();
  });
});

describe('Jira URL predicates', () => {
  it('I15 jiraIsUnreachable: localhost, 127.0.0.1, ::1, jira.invalid true; example.atlassian.net false', () => {
    for (const u of ['http://localhost:8080', 'http://127.0.0.1:9', 'http://[::1]:9', 'http://jira.invalid']) {
      expect([u, jiraIsUnreachable(u)]).toEqual([u, true]);
    }
    expect(jiraIsUnreachable('https://example.atlassian.net')).toBe(false);
    expect(jiraIsUnreachable('not a url')).toBe(false);
  });

  it('jiraIsLoopback: jira.invalid false', () => {
    expect(jiraIsLoopback('http://jira.invalid')).toBe(false);
    expect(jiraIsLoopback('http://127.0.0.1:9')).toBe(true);
    expect(jiraIsLoopback('http://[::1]:9')).toBe(true);
    expect(jiraIsLoopback('https://example.atlassian.net')).toBe(false);
  });
});
