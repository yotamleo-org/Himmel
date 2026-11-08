import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { execFileSync, spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { envFilePath, jiraFetch } from '../lib/jira-fetch.mjs';

// The shared stub keyring (secret-tool + busctl first on PATH): no row here reaches a real keyring.
const KEYRING_STUB = fileURLToPath(new URL('../../../scripts/lib/fixtures/keyring-stub.sh', import.meta.url));
function stubKeyring(dir, items = {}) {
  expect(spawnSync('bash', ['-c', 'TMP="$1"; . "$2"', '_', dir, KEYRING_STUB], { encoding: 'utf8' }).status).toBe(0);
  const store = join(dir, 'keyring.tsv');
  writeFileSync(store, Object.entries(items).map(([k, v]) => `service=himmel key=${k} scope=user\t${v}\n`).join(''));
  return {
    store,
    env: {
      PATH: `${join(dir, 'kbin')}:${process.env.PATH}`, KSTUB_STORE: store, KSTUB_LOG: join(dir, 'keyring.log'),
      KSTUB_LOCKED: 'false', DBUS_SESSION_BUS_ADDRESS: `unix:path=${join(dir, 'stub-bus')}`,
    },
  };
}

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

describe('credentials held only in the keyring', () => {
  let origFetch;
  let tmp;

  beforeEach(() => {
    origFetch = globalThis.fetch;
    tmp = mkdtempSync(join(tmpdir(), 'himmel-jira-keyring-'));
    const kr = stubKeyring(tmp, { JIRA_EMAIL: 'kr@example.invalid', JIRA_API_TOKEN: 'keyring-fixture-token' });
    for (const [k, v] of Object.entries(kr.env)) vi.stubEnv(k, v);
    for (const k of ['JIRA_EMAIL', 'JIRA_API_TOKEN', 'CREDENTIALS_DIRECTORY', 'HIMMEL_SECRETS_KEYRING']) vi.stubEnv(k, undefined);
    vi.stubEnv('JIRA_BASE_URL', 'https://example.atlassian.net');
    vi.stubEnv('HIMMEL_CONFIG_DIR', join(tmp, 'conf'));
  });

  afterEach(() => {
    globalThis.fetch = origFetch;
    vi.unstubAllEnvs();
    rmSync(tmp, { recursive: true, force: true });
  });

  it('jiraFetch on a migrated station: the email from himmel.conf, the token from the keyring', async () => {
    mkdirSync(join(tmp, 'conf'));
    writeFileSync(join(tmp, 'conf', 'himmel.conf'), 'JIRA_EMAIL=conf@example.invalid\n');
    writeFileSync(process.env.KSTUB_STORE, 'service=himmel key=JIRA_API_TOKEN scope=user\tkeyring-fixture-token\n');
    let headers;
    globalThis.fetch = vi.fn(async (url, init) => { headers = init.headers; return { ok: true, text: async () => '{}' }; });
    await jiraFetch('GET', '/myself');
    expect(headers.Authorization).toBe('Basic ' + Buffer.from('conf@example.invalid:keyring-fixture-token').toString('base64'));
  });

  it('jiraFetch serves a token and email that only the keyring holds', async () => {
    let headers;
    globalThis.fetch = vi.fn(async (url, init) => { headers = init.headers; return { ok: true, text: async () => '{}' }; });
    await jiraFetch('GET', '/myself');
    expect(headers.Authorization).toBe('Basic ' + Buffer.from('kr@example.invalid:keyring-fixture-token').toString('base64'));
  });

  it('a plugin installed alone, without scripts/lib, serves nothing from the keyring and does not crash', () => {
    const root = mkdtempSync(join(tmpdir(), 'himmel-jira-alone-'));
    try {
      const lib = join(root, 'plugins', 'himmel-jira', 'lib');
      mkdirSync(lib, { recursive: true });
      copyFileSync(new URL('../lib/jira-fetch.mjs', import.meta.url), join(lib, 'jira-fetch.mjs'));
      const run = spawnSync(process.execPath, ['--input-type=module', '-e',
        `import { resolveFromKeyring, storeInKeyring } from ${JSON.stringify(pathToFileURL(join(lib, 'jira-fetch.mjs')).href)};
         process.stdout.write(JSON.stringify([resolveFromKeyring(['JIRA_API_TOKEN']), storeInKeyring({ JIRA_API_TOKEN: 'x' })]));`,
      ], { cwd: root, env: { PATH: process.env.PATH, HOME: root, NODE_ENV: 'test' }, encoding: 'utf8', timeout: 30000 });
      expect(run.status, run.stderr).toBe(0);
      expect(run.stdout).toBe('[{},[]]');
    } finally { rmSync(root, { recursive: true, force: true }); }
  });
});
