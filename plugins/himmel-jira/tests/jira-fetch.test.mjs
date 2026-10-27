import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { execFileSync, spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { envFilePath, jiraFetch } from '../lib/jira-fetch.mjs';

describe('envFilePath', () => {
  let root;
  let cwd;
  let home;
  let modulePath;

  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), 'himmel-jira-own-path-'));
    cwd = join(root, 'unrelated');
    home = join(root, 'home');
    const installed = join(root, 'plugins', 'himmel-jira', 'lib');
    mkdirSync(installed, { recursive: true });
    mkdirSync(cwd);
    mkdirSync(home);
    modulePath = join(installed, 'jira-fetch.mjs');
    copyFileSync(new URL('../lib/jira-fetch.mjs', import.meta.url), modulePath);
  });

  afterEach(() => rmSync(root, { recursive: true, force: true }));

  function runEnvPath(read = false) {
    const run = spawnSync(process.execPath, ['--input-type=module', '-e',
      `import { envFilePath } from ${JSON.stringify(pathToFileURL(modulePath).href)};
       import { readFileSync } from 'node:fs';
       const path = envFilePath();
       process.stdout.write(${read ? "readFileSync(path, 'utf8')" : 'path'});`,
    ], { cwd, env: { PATH: process.env.PATH, HOME: home }, encoding: 'utf8', timeout: 30000 });
    expect(run.error).toBeUndefined();
    expect(run.status, run.stderr).toBe(0);
    return run;
  }

  it('returns the custom path when an explicit override is given', () => {
    expect(envFilePath('/custom/path/jira.env')).toBe('/custom/path/jira.env');
  });

  it('returns a non-null string for undefined override (no crash)', () => {
    const result = envFilePath(undefined);
    expect(typeof result).toBe('string');
    expect(result.length).toBeGreaterThan(0);
  });

  it('returns HOME-based fallback when the install has no .env and cwd is outside any git repo', () => {
    expect(runEnvPath().stdout).toBe(join(home, '.config', 'himmel-cli', 'jira.env'));
  });

  it('returns the primary checkout .env when the plugin is installed in a worktree', () => {
    const primary = join(root, 'primary');
    mkdirSync(primary);
    execFileSync('git', ['init', '-q', primary]);
    writeFileSync(join(primary, '.git', 'HEAD'), 'ref: refs/heads/main\n');
    execFileSync('git', ['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
      '-c', 'commit.gpgsign=false', 'commit', '--allow-empty', '-qm', 'fixture'], { cwd: primary });
    const worktree = join(root, 'worktree');
    execFileSync('git', ['worktree', 'add', '-qb', 'fixture', worktree], { cwd: primary });
    const installed = join(worktree, 'plugins', 'himmel-jira', 'lib');
    mkdirSync(installed, { recursive: true });
    copyFileSync(modulePath, join(installed, 'jira-fetch.mjs'));
    modulePath = join(installed, 'jira-fetch.mjs');
    writeFileSync(join(primary, '.env'), 'JIRA_BASE_URL=https://fixture.invalid\n');
    expect(runEnvPath().stdout).toBe(join(primary, '.env'));
  });

  it('finds the install .env from an unrelated cwd with no JIRA variables exported', () => {
    const fixture = 'JIRA_BASE_URL=https://fixture.invalid\nJIRA_EMAIL=fixture@example.invalid\nJIRA_API_TOKEN=dummy\n';
    writeFileSync(join(root, '.env'), fixture);
    writeFileSync(join(cwd, '.env'), 'JIRA_BASE_URL=https://wrong.invalid\n');
    const run = runEnvPath(true);
    expect(run.stdout).toBe(fixture);
    expect(run.stderr).toBe('');
  });
});

describe('jiraFetch error path', () => {
  let origFetch;
  let origBase;
  let origEmail;
  let origToken;

  beforeEach(() => {
    origFetch = globalThis.fetch;
    origBase = process.env.JIRA_BASE_URL;
    origEmail = process.env.JIRA_EMAIL;
    origToken = process.env.JIRA_API_TOKEN;
    process.env.JIRA_BASE_URL = 'https://example.atlassian.net';
    process.env.JIRA_EMAIL = 'a@b.com';
    process.env.JIRA_API_TOKEN = 'secret-token';
  });

  afterEach(() => {
    globalThis.fetch = origFetch;
    if (origBase === undefined) delete process.env.JIRA_BASE_URL; else process.env.JIRA_BASE_URL = origBase;
    if (origEmail === undefined) delete process.env.JIRA_EMAIL; else process.env.JIRA_EMAIL = origEmail;
    if (origToken === undefined) delete process.env.JIRA_API_TOKEN; else process.env.JIRA_API_TOKEN = origToken;
  });

  it('throws Error with HTTP status + truncated (300 chars + ellipsis) body on non-2xx', async () => {
    const longBody = 'x'.repeat(500);
    globalThis.fetch = vi.fn(async () => ({
      ok: false,
      status: 500,
      text: async () => longBody,
    }));
    await expect(jiraFetch('GET', '/myself')).rejects.toThrow(/HTTP 500/);
    globalThis.fetch = vi.fn(async () => ({
      ok: false,
      status: 500,
      text: async () => longBody,
    }));
    let caught;
    try { await jiraFetch('GET', '/myself'); } catch (e) { caught = e; }
    expect(caught).toBeDefined();
    expect(caught.message).toContain('x'.repeat(300) + '…');
    expect(caught.message).not.toContain('x'.repeat(301));
  });

  it('does NOT truncate body when it is exactly 300 chars or fewer', async () => {
    const shortBody = 'y'.repeat(300);
    globalThis.fetch = vi.fn(async () => ({
      ok: false,
      status: 400,
      text: async () => shortBody,
    }));
    let caught;
    try { await jiraFetch('GET', '/myself'); } catch (e) { caught = e; }
    expect(caught.message).toContain(shortBody);
    expect(caught.message).not.toContain('…');
  });

  it('builds Authorization header as Basic base64(email:token)', async () => {
    let capturedHeaders;
    globalThis.fetch = vi.fn(async (url, init) => {
      capturedHeaders = init.headers;
      return { ok: true, text: async () => '{}' };
    });
    await jiraFetch('GET', '/myself');
    const expected = 'Basic ' + Buffer.from('a@b.com:secret-token').toString('base64');
    expect(capturedHeaders.Authorization).toBe(expected);
    expect(capturedHeaders['Content-Type']).toBe('application/json');
    expect(capturedHeaders.Accept).toBe('application/json');
  });

  it('appends /rest/api/3 prefix to path', async () => {
    let capturedUrl;
    globalThis.fetch = vi.fn(async (url) => {
      capturedUrl = url;
      return { ok: true, text: async () => '{}' };
    });
    await jiraFetch('GET', '/myself');
    expect(capturedUrl).toBe('https://example.atlassian.net/rest/api/3/myself');
  });

  it('throws when JIRA_BASE_URL is unset', async () => {
    delete process.env.JIRA_BASE_URL;
    await expect(jiraFetch('GET', '/myself')).rejects.toThrow(/JIRA_BASE_URL not set/);
  });

  it('returns {} for 2xx with empty body', async () => {
    globalThis.fetch = vi.fn(async () => ({ ok: true, text: async () => '' }));
    const out = await jiraFetch('GET', '/myself');
    expect(out).toEqual({});
  });

  it('serializes body as JSON when provided', async () => {
    let capturedBody;
    globalThis.fetch = vi.fn(async (url, init) => {
      capturedBody = init.body;
      return { ok: true, text: async () => '{}' };
    });
    await jiraFetch('POST', '/issue', { fields: { summary: 'hi' } });
    expect(capturedBody).toBe(JSON.stringify({ fields: { summary: 'hi' } }));
  });
});
