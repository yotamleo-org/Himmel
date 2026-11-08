import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, chmodSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Command } from 'commander';
import { uploadAttachment, uploadMultipart, normalizeEnv, baseUrl, loadEnvFile, request, requestAt, agileRequest, confluenceV2 } from './client.js';
import { registerMove } from './commands/move.js';
import { readVersionWrites } from './release/version-writes.js';
import { sameJiraBase, stationJiraBaseUrl } from './env-file.js';

// Records every git call the path lookups make, passing each through. The test-run-guard door a write
// asks (scripts/lib/test-run-guard) answers `door.status`: 0, so these hermetic writes to a stubbed
// fetch pass it; every other spawn runs for real.
const door = vi.hoisted(() => ({ status: 0 as number | null, calls: 0 }));
vi.mock('node:child_process', async (orig) => {
  const m = await orig<typeof import('node:child_process')>();
  const spawnSync = ((cmd: string, args?: readonly string[], opts?: object) => {
    if (cmd === 'bash' && String(args?.[0] ?? '').endsWith('/test-run-guard')) {
      door.calls++;
      return { status: door.status, signal: null, output: [], pid: 0, stdout: null, stderr: null };
    }
    return m.spawnSync(cmd, args ?? [], opts ?? {});
  }) as unknown as typeof m.spawnSync;
  return { ...m, execFileSync: vi.fn(m.execFileSync), spawnSync };
});

describe('uploadAttachment', () => {
  let dir: string;
  const origEmail = process.env.JIRA_EMAIL;
  const origToken = process.env.JIRA_API_TOKEN;
  const origBase = process.env.JIRA_BASE_URL;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'jira-attach-'));
    process.env.JIRA_EMAIL = 'u@example.com';
    process.env.JIRA_API_TOKEN = 'secret';
    process.env.JIRA_BASE_URL = 'https://example.atlassian.net';
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
    if (origEmail === undefined) delete process.env.JIRA_EMAIL; else process.env.JIRA_EMAIL = origEmail;
    if (origToken === undefined) delete process.env.JIRA_API_TOKEN; else process.env.JIRA_API_TOKEN = origToken;
    if (origBase === undefined) delete process.env.JIRA_BASE_URL; else process.env.JIRA_BASE_URL = origBase;
    vi.restoreAllMocks();
  });

  it('POSTs multipart with correct URL, headers, and file field', async () => {
    const file = join(dir, 'screenshot.png');
    writeFileSync(file, Buffer.from([0x89, 0x50, 0x4e, 0x47]));

    const fetchMock = vi.fn(async () => ({
      ok: true,
      status: 200,
      text: async () => '[{"id":"10001","filename":"screenshot.png"}]',
    }));
    vi.stubGlobal('fetch', fetchMock);

    const out = await uploadAttachment('HIMMEL-1', file);

    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe('https://example.atlassian.net/rest/api/3/issue/HIMMEL-1/attachments');
    expect(init.method).toBe('POST');
    const headers = init.headers as Record<string, string>;
    expect(headers.Authorization).toMatch(/^Basic /);
    expect(headers['X-Atlassian-Token']).toBe('no-check');
    expect(headers['Content-Type']).toBeUndefined();
    expect(init.body).toBeInstanceOf(FormData);
    const fd = init.body as FormData;
    const fileField = fd.get('file');
    expect(fileField).toBeInstanceOf(Blob);
    expect((fileField as File).name ?? (fd as unknown as { _filename?: string })._filename).toMatch(/screenshot\.png$/);

    expect(Array.isArray(out)).toBe(true);
    expect((out as Array<{ filename: string }>)[0].filename).toBe('screenshot.png');
  });

  it('throws on missing file with clear message', async () => {
    await expect(uploadAttachment('HIMMEL-1', join(dir, 'nope.png'))).rejects.toThrow(
      /nope\.png/,
    );
  });

  it('normalizeEnv strips trailing CR from CRLF-source env vars', () => {
    const stderrCaptured: string[] = [];
    const origWrite = process.stderr.write.bind(process.stderr);
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (process.stderr as any).write = (chunk: string | Buffer): boolean => {
      stderrCaptured.push(String(chunk));
      return true;
    };
    try {
      process.env.JIRA_API_TOKEN = 'good-token-value\r';
      process.env.JIRA_EMAIL = 'u@example.com\r\n';
      process.env.JIRA_BASE_URL = 'https://example.atlassian.net\r';
      normalizeEnv();
      expect(process.env.JIRA_API_TOKEN).toBe('good-token-value');
      expect(process.env.JIRA_EMAIL).toBe('u@example.com');
      expect(process.env.JIRA_BASE_URL).toBe('https://example.atlassian.net');
      const stderrText = stderrCaptured.join('');
      expect(stderrText).toMatch(/stripped trailing whitespace from JIRA_API_TOKEN/);
      expect(stderrText).toMatch(/stripped trailing whitespace from JIRA_EMAIL/);
      expect(stderrText).toMatch(/stripped trailing whitespace from JIRA_BASE_URL/);
      expect(stderrText).toMatch(/dos2unix/);
    } finally {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      (process.stderr as any).write = origWrite;
    }
  });

  it('normalizeEnv is a no-op when values are already clean', () => {
    const stderrCaptured: string[] = [];
    const origWrite = process.stderr.write.bind(process.stderr);
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (process.stderr as any).write = (chunk: string | Buffer): boolean => {
      stderrCaptured.push(String(chunk));
      return true;
    };
    try {
      process.env.JIRA_API_TOKEN = 'clean-token';
      process.env.JIRA_EMAIL = 'u@example.com';
      process.env.JIRA_BASE_URL = 'https://example.atlassian.net';
      normalizeEnv();
      expect(stderrCaptured.join('')).toBe('');
    } finally {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      (process.stderr as any).write = origWrite;
    }
  });

  it('throws HTTP error including status and body', async () => {
    const file = join(dir, 'a.txt');
    writeFileSync(file, 'hi');
    const fetchMock = vi.fn(async () => ({
      ok: false,
      status: 413,
      text: async () => 'Payload Too Large',
    }));
    vi.stubGlobal('fetch', fetchMock);

    await expect(uploadAttachment('HIMMEL-1', file)).rejects.toThrow(/HTTP 413.*Payload Too Large/);
  });
});

describe('baseUrl', () => {
  const origBase = process.env.JIRA_BASE_URL;

  afterEach(() => {
    if (origBase === undefined) delete process.env.JIRA_BASE_URL; else process.env.JIRA_BASE_URL = origBase;
  });

  it('returns JIRA_BASE_URL when set', () => {
    process.env.JIRA_BASE_URL = 'https://example.atlassian.net';
    expect(baseUrl()).toBe('https://example.atlassian.net');
  });

  it('throws when JIRA_BASE_URL is unset — no personal-instance fallback', () => {
    delete process.env.JIRA_BASE_URL;
    expect(() => baseUrl()).toThrow(/JIRA_BASE_URL is not set/);
  });

  it('throws with actionable guidance when JIRA_BASE_URL is unset', () => {
    delete process.env.JIRA_BASE_URL;
    expect(() => baseUrl()).toThrow(/\.env\.example/);
  });

  it('never falls back to the author instance when unset', () => {
    delete process.env.JIRA_BASE_URL;
    let message = '';
    try {
      baseUrl();
    } catch (e) {
      message = (e as Error).message;
    }
    expect(message).not.toBe('');
    expect(message).not.toMatch(/yotamleo/);
  });
});

describe('requestAt base composition', () => {
  const origBase = process.env.JIRA_BASE_URL;
  afterEach(() => {
    if (origBase === undefined) delete process.env.JIRA_BASE_URL; else process.env.JIRA_BASE_URL = origBase;
    vi.restoreAllMocks();
  });

  it('prefixes the apiBase + path onto baseUrl for each named helper', async () => {
    process.env.JIRA_BASE_URL = 'https://x.example';
    const fetchMock = vi.fn(async () => ({ ok: true, status: 200, text: async () => '{}' }));
    vi.stubGlobal('fetch', fetchMock);
    const { agileRequest, confluenceV2, confluenceV1 } = await import('./client.js');
    await agileRequest('GET', '/board');
    await confluenceV2('GET', '/pages/1');
    await confluenceV1('GET', '/search');
    expect(fetchMock.mock.calls[0][0]).toBe('https://x.example/rest/agile/1.0/board');
    expect(fetchMock.mock.calls[1][0]).toBe('https://x.example/wiki/api/v2/pages/1');
    expect(fetchMock.mock.calls[2][0]).toBe('https://x.example/wiki/rest/api/search');
  });
});

describe('confluenceAuthHeader', () => {
  const keys = ['JIRA_EMAIL', 'JIRA_API_TOKEN', 'CONFLUENCE_EMAIL', 'CONFLUENCE_API_TOKEN'];
  const orig: Record<string, string | undefined> = {};
  for (const k of keys) orig[k] = process.env[k];
  afterEach(() => {
    for (const k of keys) {
      if (orig[k] === undefined) delete process.env[k]; else process.env[k] = orig[k];
    }
  });

  it('uses CONFLUENCE_* creds when both are set', async () => {
    process.env.JIRA_EMAIL = 'j@x'; process.env.JIRA_API_TOKEN = 'jtok';
    process.env.CONFLUENCE_EMAIL = 'c@x'; process.env.CONFLUENCE_API_TOKEN = 'ctok';
    const { confluenceAuthHeader } = await import('./client.js');
    expect(confluenceAuthHeader()).toBe(`Basic ${Buffer.from('c@x:ctok').toString('base64')}`);
  });

  it('falls back to JIRA_* creds when CONFLUENCE_* is not fully set', async () => {
    process.env.JIRA_EMAIL = 'j@x'; process.env.JIRA_API_TOKEN = 'jtok';
    delete process.env.CONFLUENCE_EMAIL; delete process.env.CONFLUENCE_API_TOKEN;
    const { confluenceAuthHeader, authHeader } = await import('./client.js');
    expect(confluenceAuthHeader()).toBe(authHeader());
  });
});

describe('resolveAccountId', () => {
  const origBase = process.env.JIRA_BASE_URL;
  afterEach(() => {
    if (origBase === undefined) delete process.env.JIRA_BASE_URL; else process.env.JIRA_BASE_URL = origBase;
    vi.restoreAllMocks();
  });

  it('returns the input unchanged when it has no @ (accountId passthrough)', async () => {
    const { resolveAccountId } = await import('./client.js');
    expect(await resolveAccountId('5b10ac8d82e05b22cc7d4ef5')).toBe('5b10ac8d82e05b22cc7d4ef5');
  });

  it('looks up an email and returns the first accountId', async () => {
    process.env.JIRA_BASE_URL = 'https://x.example';
    const fetchMock = vi.fn(async () => ({ ok: true, status: 200, text: async () => '[{"accountId":"abc"}]' }));
    vi.stubGlobal('fetch', fetchMock);
    const { resolveAccountId } = await import('./client.js');
    expect(await resolveAccountId('a@b.com')).toBe('abc');
    expect(decodeURIComponent(String(fetchMock.mock.calls[0][0]))).toContain('/user/search?query=a@b.com');
  });
});

describe('loadEnvFile', () => {
  const orig = process.env.JIRA_BASE_URL;
  let dir: string;
  let file: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'jira-dotenv-'));
    file = join(dir, '.env');
    vi.stubEnv('HOME', dir);
    vi.stubEnv('HIMMEL_CONFIG_DIR', '');
    vi.stubEnv('HIMMEL_PROFILE', '');
    mkdirSync(join(dir, '.himmel'));
    writeFileSync(file, 'JIRA_BASE_URL=https://from-dotenv.example\n');
  });

  afterEach(() => {
    vi.unstubAllEnvs();
    rmSync(dir, { recursive: true, force: true });
    if (orig === undefined) delete process.env.JIRA_BASE_URL; else process.env.JIRA_BASE_URL = orig;
  });

  it('reads Jira identifiers from himmel.conf before the legacy .env', () => {
    vi.stubEnv('JIRA_BASE_URL', '');
    vi.stubEnv('JIRA_EMAIL', '');
    vi.stubEnv('JIRA_PROJECT_KEY', '');
    writeFileSync(join(dir, '.himmel', 'himmel.conf'),
      'JIRA_BASE_URL=https://from-config.example\nJIRA_EMAIL=dummy@example.invalid\nJIRA_PROJECT_KEY=DUMMY\n');
    loadEnvFile(file);
    expect(process.env.JIRA_BASE_URL).toBe('https://from-config.example');
    expect(process.env.JIRA_EMAIL).toBe('dummy@example.invalid');
    expect(process.env.JIRA_PROJECT_KEY).toBe('DUMMY');
  });

  it.skipIf(process.platform === 'darwin')('with a stubbed keyring and no Jira keys in .env, takes the base URL from .env and the credentials from the keyring', () => {
    for (const k of ['JIRA_BASE_URL', 'JIRA_EMAIL', 'JIRA_API_TOKEN']) vi.stubEnv(k, '');
    const bin = join(dir, 'kbin');
    mkdirSync(bin);
    writeFileSync(join(bin, 'secret-tool'),
      '#!/usr/bin/env bash\ncase "$*" in\n *"key JIRA_API_TOKEN"*) printf stub-token ;;\n *"key JIRA_EMAIL"*) printf stub@example.invalid ;;\n *) exit 1 ;;\nesac\n');
    writeFileSync(join(bin, 'busctl'), '#!/usr/bin/env bash\necho "b false"\n');
    chmodSync(join(bin, 'secret-tool'), 0o755);
    chmodSync(join(bin, 'busctl'), 0o755);
    vi.stubEnv('PATH', `${bin}:${process.env.PATH}`);
    vi.stubEnv('HIMMEL_SECRETS_KEYRING', '');
    vi.stubEnv('KSTUB_STORE', join(dir, 'keyring.tsv')); // names the stub keyring: the resolver keeps it on under NODE_ENV=test
    writeFileSync(file, 'JIRA_BASE_URL=https://from-dotenv.example\n');
    loadEnvFile(file);
    expect(baseUrl()).toBe('https://from-dotenv.example');
    expect(process.env.JIRA_API_TOKEN).toBe('stub-token');
    expect(process.env.JIRA_EMAIL).toBe('stub@example.invalid');
  });

  it('prefers .local to himmel.conf but preserves a non-empty process value', () => {
    vi.stubEnv('JIRA_PROJECT_KEY', '');
    writeFileSync(join(dir, '.himmel', 'himmel.conf'), 'JIRA_PROJECT_KEY=CONFIG\n');
    writeFileSync(join(dir, '.himmel', 'himmel.conf.local'), 'JIRA_PROJECT_KEY=LOCAL\n');
    loadEnvFile(file);
    expect(process.env.JIRA_PROJECT_KEY).toBe('LOCAL');
    process.env.JIRA_PROJECT_KEY = 'PROCESS';
    loadEnvFile(file);
    expect(process.env.JIRA_PROJECT_KEY).toBe('PROCESS');
  });

  it('falls through empty config values and never reads credentials or unclassified keys from config', () => {
    vi.stubEnv('JIRA_BASE_URL', '');
    vi.stubEnv('JIRA_API_TOKEN', '');
    vi.stubEnv('CONFLUENCE_API_TOKEN', '');
    vi.stubEnv('JIRA_BOARD_ID', '');
    writeFileSync(join(dir, '.himmel', 'himmel.conf.local'), 'JIRA_BASE_URL=\nJIRA_API_TOKEN=planted\n');
    writeFileSync(join(dir, '.himmel', 'himmel.conf'),
      'JIRA_BASE_URL=\nJIRA_API_TOKEN=planted\nCONFLUENCE_API_TOKEN=planted\nJIRA_BOARD_ID=123\n');
    writeFileSync(file, 'JIRA_BASE_URL=https://from-dotenv.example\nJIRA_API_TOKEN=dummy-token\n');
    loadEnvFile(file);
    expect(process.env.JIRA_BASE_URL).toBe('https://from-dotenv.example');
    expect(process.env.JIRA_API_TOKEN).toBe('dummy-token');
    expect(process.env.CONFLUENCE_API_TOKEN).toBe('');
    expect(process.env.JIRA_BOARD_ID).toBe('');
  });

  it.each([
    ['DUMMY # default project', 'DUMMY'],
    ['DUMMY#literal', 'DUMMY#literal'],
    ['"DUMMY # quoted" # comment', '"DUMMY # quoted"'],
    ["'DUMMY # quoted' # comment", "'DUMMY # quoted'"],
    ["DUMMY's-project # comment", "DUMMY's-project"],
    ['"DUMMY\\\" # quoted" # comment', '"DUMMY\\\" # quoted"'],
  ])('strips only unquoted inline comments from config: %s', (input, expected) => {
    vi.stubEnv('JIRA_PROJECT_KEY', '');
    writeFileSync(join(dir, '.himmel', 'himmel.conf'), `JIRA_PROJECT_KEY=${input}\n`);
    loadEnvFile(file);
    expect(process.env.JIRA_PROJECT_KEY).toBe(expected);
  });

  it('reads identifiers from config even without a legacy .env', () => {
    vi.stubEnv('JIRA_PROJECT_KEY', '');
    rmSync(file);
    writeFileSync(join(dir, '.himmel', 'himmel.conf'), 'JIRA_PROJECT_KEY=CONFIG\n');
    loadEnvFile(file);
    expect(process.env.JIRA_PROJECT_KEY).toBe('CONFIG');
  });

  it('resolves the Jira site URL from himmel.conf alone', () => {
    vi.stubEnv('JIRA_BASE_URL', '');
    rmSync(file);
    writeFileSync(join(dir, '.himmel', 'himmel.conf'), 'JIRA_BASE_URL=https://from-config.example\n');
    loadEnvFile(file);
    expect(baseUrl()).toBe('https://from-config.example');
  });

  it('honours HIMMEL_CONFIG_DIR instead of the default HOME config directory', () => {
    vi.stubEnv('JIRA_BASE_URL', '');
    const conf = join(dir, 'custom-conf');
    mkdirSync(conf);
    vi.stubEnv('HIMMEL_CONFIG_DIR', conf);
    writeFileSync(join(dir, '.himmel', 'himmel.conf'), 'JIRA_BASE_URL=https://wrong-default.example\n');
    writeFileSync(join(conf, 'himmel.conf'), 'JIRA_BASE_URL=https://custom.example\n');
    loadEnvFile(file);
    expect(baseUrl()).toBe('https://custom.example');
  });

  it('ignores a planted cwd project URL while still reading its project key', () => {
    const project = join(dir, 'project');
    mkdirSync(project);
    execFileSync('git', ['init', '--quiet', project]);
    writeFileSync(join(project, '.env'), 'JIRA_BASE_URL=https://planted.example.invalid\nJIRA_PROJECT_KEY=PROJECT\n');
    vi.stubEnv('JIRA_BASE_URL', '');
    vi.stubEnv('JIRA_PROJECT_KEY', '');
    const cwd = process.cwd();
    try {
      process.chdir(project);
      loadEnvFile(file);
      expect(baseUrl()).toBe('https://from-dotenv.example');
      expect(process.env.JIRA_PROJECT_KEY).toBe('PROJECT');
    } finally {
      process.chdir(cwd);
    }
  });

  it('prefers the local Jira site URL to default config and preserves the process value', () => {
    vi.stubEnv('JIRA_BASE_URL', '');
    writeFileSync(join(dir, '.himmel', 'himmel.conf'), 'JIRA_BASE_URL=https://default.example\n');
    writeFileSync(join(dir, '.himmel', 'himmel.conf.local'), 'JIRA_BASE_URL=https://local.example\n');
    loadEnvFile(file);
    expect(baseUrl()).toBe('https://local.example');
    process.env.JIRA_BASE_URL = 'https://process.example';
    loadEnvFile(file);
    expect(baseUrl()).toBe('https://process.example');
  });

  it.each(['environment', 'local config'])('resolves a profile Jira site URL selected by %s before DEFAULT', (selection) => {
    vi.stubEnv('JIRA_BASE_URL', '');
    vi.stubEnv('HIMMEL_PROFILE', selection === 'environment' ? 'work' : '');
    const vault = join(dir, 'vault', '.himmel');
    mkdirSync(join(vault, 'profiles'), { recursive: true });
    writeFileSync(join(vault, 'himmel.conf'), 'JIRA_BASE_URL=https://default.example\n');
    symlinkSync('../vault/.himmel/himmel.conf', join(dir, '.himmel', 'himmel.conf'));
    writeFileSync(join(vault, 'profiles', 'work.conf'), 'JIRA_BASE_URL=https://profile.example\n');
    writeFileSync(join(dir, '.himmel', 'himmel.conf.local'),
      selection === 'local config' ? 'HIMMEL_PROFILE=work\n' : '');
    loadEnvFile(file);
    expect(baseUrl()).toBe('https://profile.example');
    process.env.JIRA_BASE_URL = '';
    writeFileSync(join(dir, '.himmel', 'himmel.conf.local'),
      'HIMMEL_PROFILE=work\nJIRA_BASE_URL=https://local.example\n');
    loadEnvFile(file);
    expect(baseUrl()).toBe('https://local.example');
  });

  it('ignores a profile name that traverses out of the profiles directory', () => {
    vi.stubEnv('JIRA_BASE_URL', '');
    vi.stubEnv('HIMMEL_PROFILE', '../outside');
    const vault = join(dir, 'vault', '.himmel');
    mkdirSync(join(vault, 'profiles'), { recursive: true });
    writeFileSync(join(vault, 'himmel.conf'), 'JIRA_BASE_URL=https://default.example\n');
    writeFileSync(join(vault, 'outside.conf'), 'JIRA_BASE_URL=https://outside.example\n');
    symlinkSync('../vault/.himmel/himmel.conf', join(dir, '.himmel', 'himmel.conf'));
    loadEnvFile(file);
    expect(baseUrl()).toBe('https://default.example');
  });

  it('fills a key that is exported but EMPTY (an empty value is not a usable one)', () => {
    process.env.JIRA_BASE_URL = '';
    loadEnvFile(file);
    expect(process.env.JIRA_BASE_URL).toBe('https://from-dotenv.example');
  });

  it('keeps a live non-empty value over the file', () => {
    process.env.JIRA_BASE_URL = 'https://live.example';
    loadEnvFile(file);
    expect(process.env.JIRA_BASE_URL).toBe('https://live.example');
  });

  it('loadEnvFile resolves JIRA_BASE_URL exactly as before for env, local, profile, conf and .env layers', () => {
    const vault = join(dir, 'vault', '.himmel');
    mkdirSync(join(vault, 'profiles'), { recursive: true });
    symlinkSync('../vault/.himmel/himmel.conf', join(dir, '.himmel', 'himmel.conf'));
    const layers = {
      local: () => writeFileSync(join(dir, '.himmel', 'himmel.conf.local'), 'HIMMEL_PROFILE=work\nJIRA_BASE_URL=https://local.example\n'),
      profile: () => writeFileSync(join(vault, 'profiles', 'work.conf'), 'JIRA_BASE_URL=https://profile.example\n'),
      conf: () => writeFileSync(join(vault, 'himmel.conf'), 'JIRA_BASE_URL=https://conf.example\n'),
    };
    const resolved = (): string => { process.env.JIRA_BASE_URL = ''; loadEnvFile(file); return process.env.JIRA_BASE_URL ?? ''; };
    writeFileSync(join(dir, '.himmel', 'himmel.conf.local'), 'HIMMEL_PROFILE=work\n');
    writeFileSync(join(vault, 'himmel.conf'), '');
    expect(resolved()).toBe('https://from-dotenv.example');
    layers.conf();
    expect(resolved()).toBe('https://conf.example');
    layers.profile();
    expect(resolved()).toBe('https://profile.example');
    layers.local();
    expect(resolved()).toBe('https://local.example');
    process.env.JIRA_BASE_URL = 'https://env.example';
    loadEnvFile(file);
    expect(process.env.JIRA_BASE_URL).toBe('https://env.example');
  });
});

describe('stationJiraBaseUrl', () => {
  let dir: string;
  let conf: string;
  let envPath: string;
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'jira-station-url-'));
    conf = join(dir, '.himmel');
    envPath = join(dir, 'install.env');
    mkdirSync(join(dir, 'vault', '.himmel', 'profiles'), { recursive: true });
    writeFileSync(join(dir, 'vault', '.himmel', 'himmel.conf'), 'JIRA_BASE_URL=https://conf.example\n');
    writeFileSync(join(dir, 'vault', '.himmel', 'profiles', 'work.conf'), 'JIRA_BASE_URL=https://work.example\n');
    writeFileSync(join(dir, 'vault', '.himmel', 'profiles', 'home.conf'), 'JIRA_BASE_URL=https://home.example\n');
    mkdirSync(conf);
    symlinkSync('../vault/.himmel/himmel.conf', join(conf, 'himmel.conf'));
  });
  afterEach(() => {
    vi.unstubAllEnvs();
    rmSync(dir, { recursive: true, force: true });
  });

  it('I14 stationJiraBaseUrl with profileFromEnv false ignores process JIRA_BASE_URL and HIMMEL_PROFILE', () => {
    vi.stubEnv('JIRA_BASE_URL', 'https://process.example');
    vi.stubEnv('HIMMEL_PROFILE', 'work');
    expect(stationJiraBaseUrl(conf, { profileFromEnv: false, envPath })).toBe('https://conf.example');
  });

  it('with profileFromEnv true takes the env HIMMEL_PROFILE first', () => {
    vi.stubEnv('HIMMEL_PROFILE', 'work');
    writeFileSync(join(conf, 'himmel.conf.local'), 'HIMMEL_PROFILE=home\n');
    expect(stationJiraBaseUrl(conf, { profileFromEnv: true, envPath })).toBe('https://work.example');
    expect(stationJiraBaseUrl(conf, { profileFromEnv: false, envPath })).toBe('https://home.example');
  });

  it('a profile named in himmel.conf.local supplies the URL', () => {
    vi.stubEnv('HIMMEL_PROFILE', '');
    writeFileSync(join(conf, 'himmel.conf.local'), 'HIMMEL_PROFILE=work\n');
    expect(stationJiraBaseUrl(conf, { profileFromEnv: false, envPath })).toBe('https://work.example');
  });

  it('no layer gives null; the install .env is the last layer', () => {
    const bare = join(dir, 'bare');
    mkdirSync(bare);
    expect(stationJiraBaseUrl(bare, { profileFromEnv: false, envPath })).toBeNull();
    writeFileSync(envPath, 'JIRA_BASE_URL=https://dotenv.example\n');
    expect(stationJiraBaseUrl(bare, { profileFromEnv: false, envPath })).toBe('https://dotenv.example');
  });

  it('sameJiraBase normalises scheme, host, default port and a trailing slash', () => {
    expect(sameJiraBase('https://Station.atlassian.net/', 'https://station.atlassian.net')).toBe(true);
    expect(sameJiraBase('https://station.atlassian.net:443', 'https://station.atlassian.net')).toBe(true);
    expect(sameJiraBase('http://station.atlassian.net', 'https://station.atlassian.net')).toBe(false);
    expect(sameJiraBase('https://other.atlassian.net', 'https://station.atlassian.net')).toBe(false);
    expect(sameJiraBase('not a url', 'not a url')).toBe(false);
  });
});

// --- the version-write journal hook ---------------------------------------------
// Every test points HIMMEL_VERSION_WRITES at a temp file (or leaves the hook off), stubs fetch, and
// stubs the Jira credentials, so none of them can reach the real journal or the real Jira token.

type Item = { field: string; fromString?: string | null; toString?: string | null };
type Entry = { id: string; created: string; items: Item[] };
interface FakeJira {
  key: string;
  set: string[];
  entries: Entry[];
  calls: Array<{ method: string; path: string; body?: unknown }>;
  onWrite?: (f: FakeJira, body: unknown) => void;
  getStatus?: number;
  hangGets?: boolean;
  failWrite?: boolean;
}

const FIXTURES = join(dirname(fileURLToPath(import.meta.url)), 'release', 'fixtures', 'repair');
const realEntries = (n: number): Entry[] => (JSON.parse(readFileSync(join(FIXTURES, `HIMMEL-${n}.json`), 'utf8')) as { changelog: Entry[] }).changelog;
const entryNo = (all: Entry[], id: string): Entry => all.find((e) => e.id === id) as Entry;
const fv = (id: string, from: string | null, to: string | null): Entry => ({ id, created: '2026-11-02T10:00:00.000+0100', items: [{ field: 'Fix Version', fromString: from, toString: to }] });

function fakeJira(over: Partial<FakeJira>): FakeJira {
  const f: FakeJira = { key: 'HIMMEL-9', set: [], entries: [], calls: [], ...over };
  const reply = (status: number, body: unknown) => ({ ok: status < 400, status, text: async () => (body === undefined ? '' : JSON.stringify(body)) });
  vi.stubGlobal('fetch', vi.fn(async (url: string, init: RequestInit = {}) => {
    const method = init.method ?? 'GET';
    const path = url.replace('https://example.atlassian.net', '').replace('/rest/api/3', '');
    f.calls.push({ method, path, ...(init.body ? { body: JSON.parse(String(init.body)) } : {}) });
    if (method === 'GET') {
      if (f.hangGets) return new Promise(() => undefined);
      if (f.getStatus) return reply(f.getStatus, { errorMessages: ['boom'] });
      const u = new URL(url);
      if (u.pathname.endsWith(`/issue/${f.key}/changelog`)) {
        const start = Number(u.searchParams.get('startAt'));
        return reply(200, { startAt: start, maxResults: 100, total: f.entries.length, values: f.entries.slice(start, start + 100) });
      }
      if (u.pathname.endsWith(`/issue/${f.key}`)) return reply(200, { fields: { fixVersions: f.set.map((name) => ({ name })) } });
      return reply(404, {});
    }
    if (f.failWrite) return reply(400, { errorMessages: ['refused'] });
    f.onWrite?.(f, init.body ? JSON.parse(String(init.body)) : undefined);
    return method === 'POST' ? reply(201, { id: '10', key: f.key }) : reply(204, undefined);
  }));
  return f;
}

describe('version-write journal hook', () => {
  let dir: string;
  let journal: string;
  const rows = () => readVersionWrites(journal);
  const puts = (f: FakeJira) => f.calls.filter((c) => c.method !== 'GET');

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'version-writes-'));
    journal = join(dir, 'version-writes.jsonl');
    vi.stubEnv('JIRA_BASE_URL', 'https://example.atlassian.net');
    vi.stubEnv('JIRA_EMAIL', 'u@example.com');
    vi.stubEnv('JIRA_API_TOKEN', 'not-a-real-token');
    vi.stubEnv('HIMMEL_VERSION_WRITES', journal);
    vi.stubEnv('HIMMEL_VERSION_WRITER', '');
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllEnvs();
    vi.unstubAllGlobals();
    rmSync(dir, { recursive: true, force: true });
  });

  // The displacement of one real ticket: v1.1.4 removed by entry 85466.
  const displacement = () => {
    const all = realEntries(8231);
    return fakeJira({
      key: 'HIMMEL-8231', set: ['v1.1.4'], entries: all.filter((e) => Number(e.id) < 85466),
      onWrite: (f) => { f.entries.push(entryNo(all, '85466')); f.set = []; },
    });
  };
  const removeBody = { update: { fixVersions: [{ remove: { name: 'v1.1.4' } }] } };

  it('machine PUT writes a bound row', async () => {
    const f = displacement();
    await request('PUT', '/issue/HIMMEL-8231', removeBody, 'displace-residual');
    expect(rows()).toMatchObject([{ key: 'HIMMEL-8231', from: ['v1.1.4'], to: [], mechanism: 'displace-residual', entry: '85466' }]);
    expect(puts(f)).toHaveLength(1);
  });

  it('a changelog item with no toString string still binds the removal', async () => {
    // A JSON item has no own toString, so the property reads as Object.prototype.toString, a function.
    fakeJira({
      key: 'HIMMEL-9', set: ['v1.1.4'], entries: [fv('500', null, 'v1.1.4')],
      onWrite: (f) => { f.entries.push({ id: '501', created: '2026-11-02T10:00:00.000+0100', items: [{ field: 'Fix Version', fromString: 'v1.1.4' }] }); f.set = []; },
    });
    await request('PUT', '/issue/HIMMEL-9', removeBody, 'transition-stamp');
    expect(rows()).toMatchObject([{ key: 'HIMMEL-9', from: ['v1.1.4'], to: [], entry: '501' }]);
  });

  it('no-op PUT writes no row (I11)', async () => {
    const f = fakeJira({ key: 'HIMMEL-8231', set: ['v1.1.4'], entries: [fv('85399', null, 'v1.1.4')] });
    await request('PUT', '/issue/HIMMEL-8231', { update: { fixVersions: [{ add: { name: 'v1.1.4' } }] } }, 'create-residual');
    expect(rows()).toEqual([]);
    expect(puts(f)).toHaveLength(1);
  });

  it('a change that adds no entry binds nothing, so an operator\'s earlier entry is never bound (I11)', async () => {
    fakeJira({ key: 'HIMMEL-9', set: ['v1.1.4'], entries: [fv('500', 'v1.1.3', 'v1.1.4')], onWrite: (f) => { f.set = []; } });
    await request('PUT', '/issue/HIMMEL-9', removeBody, 'transition-stamp');
    expect(rows()).toEqual([]);
  });

  it('UI edit between reads writes no row (I11)', async () => {
    fakeJira({
      key: 'HIMMEL-9', set: ['v1.1.4', 'v1.1.3'], entries: [fv('500', null, 'v1.1.4'), fv('501', null, 'v1.1.3')],
      onWrite: (f) => { f.entries.push(fv('502', 'v1.1.4', null), fv('503', 'v1.1.3', null)); f.set = []; },
    });
    await request('PUT', '/issue/HIMMEL-9', removeBody, 'transition-stamp');
    expect(rows()).toEqual([]);
  });

  it('a later add-then-remove by someone else is not bound as the machine write (I11)', async () => {
    fakeJira({
      key: 'HIMMEL-9', set: ['v1.1.3'], entries: [fv('500', null, 'v1.1.3')],
      onWrite: (f) => { f.entries.push(fv('501', null, 'v1.1.4'), fv('502', null, 'v1.1.5'), fv('503', 'v1.1.5', null)); f.set = ['v1.1.3', 'v1.1.4']; },
    });
    await request('PUT', '/issue/HIMMEL-9', { update: { fixVersions: [{ add: { name: 'v1.1.4' } }] } }, 'merge-stamp');
    expect(rows()).toEqual([]);
  });

  it('one entry with two items binds (54867)', async () => {
    const all = realEntries(3084);
    fakeJira({
      key: 'HIMMEL-3084', set: ['v1.1.1'], entries: all.filter((e) => Number(e.id) < 54867),
      onWrite: (f) => { f.entries.push(entryNo(all, '54867')); f.set = ['v1.1.2']; },
    });
    await request('PUT', '/issue/HIMMEL-3084', { fields: { fixVersions: [{ name: 'v1.1.2' }] } }, 'merge-stamp');
    expect(rows()).toMatchObject([{ key: 'HIMMEL-3084', from: ['v1.1.1'], to: ['v1.1.2'], mechanism: 'merge-stamp', entry: '54867' }]);
  });

  it('two entries for one move bind (57627, 57628)', async () => {
    const all = realEntries(3084);
    fakeJira({
      key: 'HIMMEL-3084', set: ['v1.1.2'], entries: all.filter((e) => Number(e.id) < 57627),
      onWrite: (f) => { f.entries.push(entryNo(all, '57627'), entryNo(all, '57628')); f.set = ['v1.1.1']; },
    });
    await request('PUT', '/issue/HIMMEL-3084', { update: { fixVersions: [{ add: { name: 'v1.1.1' } }, { remove: { name: 'v1.1.2' } }] } }, 'merge-stamp');
    expect(rows()).toMatchObject([{ from: ['v1.1.2'], to: ['v1.1.1'], entry: '57628' }]);
  });

  it('POST with fixVersions writes a create row', async () => {
    const f = fakeJira({ key: 'HIMMEL-12', onWrite: (g) => { g.set = ['v1.1.4']; } });
    await request('POST', '/issue', { fields: { summary: 's', fixVersions: [{ name: 'v1.1.4' }] } }, 'create-residual');
    expect(rows()).toMatchObject([{ key: 'HIMMEL-12', from: [], to: ['v1.1.4'], mechanism: 'create-residual', entry: 'create' }]);
    expect(puts(f)).toHaveLength(1);
  });

  it('POST without fixVersions writes none and makes no extra request', async () => {
    const f = fakeJira({ key: 'HIMMEL-12' });
    await request('POST', '/issue', { fields: { summary: 's' } });
    expect(rows()).toEqual([]);
    expect(f.calls.map((c) => c.method)).toEqual(['POST']);
  });

  it('journal failure leaves the write intact (I7)', async () => {
    writeFileSync(join(dir, 'blocker'), 'a file, not a directory');
    vi.stubEnv('HIMMEL_VERSION_WRITES', join(dir, 'blocker', 'version-writes.jsonl'));
    const f = displacement();
    await expect(request('PUT', '/issue/HIMMEL-8231', removeBody, 'displace-residual')).resolves.toEqual({});
    expect(puts(f)).toHaveLength(1);
  });

  it('pre-read 500 still PUTs, no row (I7)', async () => {
    const f = displacement();
    f.getStatus = 500;
    await expect(request('PUT', '/issue/HIMMEL-8231', removeBody, 'displace-residual')).resolves.toEqual({});
    expect(puts(f)).toHaveLength(1);
    expect(rows()).toEqual([]);
  });

  it('post-read 500 resolves, no row (I7)', async () => {
    const f = displacement();
    const write = f.onWrite;
    f.onWrite = (g, b) => { write?.(g, b); g.getStatus = 500; };
    await expect(request('PUT', '/issue/HIMMEL-8231', removeBody, 'displace-residual')).resolves.toEqual({});
    expect(rows()).toEqual([]);
  });

  it('failed PUT writes no row (I7)', async () => {
    const f = displacement();
    f.failWrite = true;
    await expect(request('PUT', '/issue/HIMMEL-8231', removeBody, 'displace-residual')).rejects.toThrow('HTTP 400');
    expect(rows()).toEqual([]);
  });

  it('bad journal line is skipped', async () => {
    writeFileSync(journal, 'not json\n{"key":1}\n');
    displacement();
    await request('PUT', '/issue/HIMMEL-8231', removeBody, 'displace-residual');
    expect(readFileSync(journal, 'utf8').split('\n').filter(Boolean)).toHaveLength(3);
    expect(rows()).toMatchObject([{ key: 'HIMMEL-8231', entry: '85466' }]);
  });

  it('unset writer is hand', async () => {
    displacement();
    await request('PUT', '/issue/HIMMEL-8231', removeBody);
    expect(rows()[0].mechanism).toBe('hand');
  });

  it('explicit machine writer wins over the variable', async () => {
    vi.stubEnv('HIMMEL_VERSION_WRITER', 'merge-stamp');
    displacement();
    await request('PUT', '/issue/HIMMEL-8231', removeBody, 'create-stepdown');
    expect(rows()[0].mechanism).toBe('create-stepdown');
  });

  it('hand path reads the variable', async () => {
    vi.stubEnv('HIMMEL_VERSION_WRITER', 'merge-stamp');
    displacement();
    await request('PUT', '/issue/HIMMEL-8231', removeBody);
    expect(rows()[0].mechanism).toBe('merge-stamp');
  });

  it('hook GET does not recurse', async () => {
    const f = displacement();
    await request('PUT', '/issue/HIMMEL-8231', removeBody, 'displace-residual');
    expect(f.calls.map((c) => `${c.method} ${c.path.split('?')[0]}`)).toEqual([
      'GET /issue/HIMMEL-8231', 'GET /issue/HIMMEL-8231/changelog', 'PUT /issue/HIMMEL-8231',
      'GET /issue/HIMMEL-8231', 'GET /issue/HIMMEL-8231/changelog',
    ]);
  });

  it('hook off when NODE_ENV is test makes no extra request', async () => {
    vi.stubEnv('HIMMEL_VERSION_WRITES', '');
    const f = displacement();
    await request('PUT', '/issue/HIMMEL-8231', removeBody, 'displace-residual');
    expect(f.calls.map((c) => c.method)).toEqual(['PUT']);
    vi.stubEnv('HIMMEL_VERSION_WRITES', '/var/lib/real-station/version-writes.jsonl');
    f.calls.length = 0;
    await request('PUT', '/issue/HIMMEL-8231', removeBody, 'displace-residual');
    expect(f.calls.map((c) => c.method)).toEqual(['PUT']);
  });

  it('hung hook GET does not hang the write (I7)', async () => {
    vi.useFakeTimers();
    const f = displacement();
    f.hangGets = true;
    const done = request('PUT', '/issue/HIMMEL-8231', removeBody, 'displace-residual');
    await vi.advanceTimersByTimeAsync(5000);
    await expect(done).resolves.toEqual({});
    expect(puts(f)).toHaveLength(1);
    expect(rows()).toEqual([]);
  });

  it('ids compare numerically', async () => {
    fakeJira({
      key: 'HIMMEL-9', set: ['v1.1.3'], entries: [fv('9999', null, 'v1.1.3')],
      onWrite: (f) => { f.entries.push(fv('10000', 'v1.1.3', 'v1.1.4')); f.set = ['v1.1.4']; },
    });
    await request('PUT', '/issue/HIMMEL-9', { fields: { fixVersions: [{ name: 'v1.1.4' }] } }, 'merge-stamp');
    expect(rows()).toMatchObject([{ entry: '10000', from: ['v1.1.3'], to: ['v1.1.4'] }]);
  });

  it('changelog over two pages binds the newest', async () => {
    const other = (n: number): Entry => ({ id: String(100 + n), created: '2026-10-01T00:00:00.000+0100', items: [{ field: 'other' }] });
    const old = Array.from({ length: 110 }, (_, n) => other(n));
    old[3] = fv('500', null, 'v1.1.3');
    fakeJira({
      key: 'HIMMEL-9', set: ['v1.1.3'], entries: old,
      onWrite: (f) => { f.entries.push(fv('501', 'v1.1.3', 'v1.1.4')); f.set = ['v1.1.4']; },
    });
    await request('PUT', '/issue/HIMMEL-9', { fields: { fixVersions: [{ name: 'v1.1.4' }] } }, 'merge-stamp');
    expect(rows()).toMatchObject([{ entry: '501' }]);
  });

  describe.each([
    ['update add', { update: { fixVersions: [{ add: { name: 'v1.1.4' } }] } }, ['v1.1.3'], ['v1.1.3', 'v1.1.4'], fv('601', null, 'v1.1.4')],
    ['update remove', { update: { fixVersions: [{ remove: { name: 'v1.1.3' } }] } }, ['v1.1.3', 'v1.1.4'], ['v1.1.4'], fv('601', 'v1.1.3', null)],
    ['fields replace', { fields: { fixVersions: [{ name: 'v1.1.4' }] } }, ['v1.1.3'], ['v1.1.4'], fv('601', 'v1.1.3', 'v1.1.4')],
    ['fields empty writes to []', { fields: { fixVersions: [] } }, ['v1.1.3'], [], fv('601', 'v1.1.3', null)],
  ] as const)('%s', (_name, body, before, after, entry) => {
    it('binds a row with the set read before and after', async () => {
      fakeJira({ key: 'HIMMEL-9', set: [...before], entries: [fv('600', null, 'v1.1.3')], onWrite: (f) => { f.entries.push(entry as Entry); f.set = [...after]; } });
      await request('PUT', '/issue/HIMMEL-9', body, 'transition-stamp');
      expect(rows()).toMatchObject([{ from: [...before], to: [...after], entry: '601' }]);
    });
  });

  it('agile and confluence paths are ignored', async () => {
    const f = fakeJira({ key: 'HIMMEL-9', set: ['v1.1.3'], entries: [fv('600', null, 'v1.1.3')] });
    const body = { fields: { fixVersions: [{ name: 'v1.1.4' }] } };
    await requestAt('/rest/agile/1.0', 'PUT', '/issue/HIMMEL-9', body);
    await requestAt('/wiki/api/v2', 'PUT', '/issue/HIMMEL-9', body);
    await request('PUT', '/issue/HIMMEL-9/properties/x', body);
    expect(f.calls.map((c) => c.method)).toEqual(['PUT', 'PUT', 'PUT']);
    expect(rows()).toEqual([]);
  });

  describe('journal path failure outside a repo is quiet, write intact (I7)', () => {
    const gitCalls = () => vi.mocked(execFileSync).mock.calls.filter((c) => c[0] === 'git');
    let away: string;
    let was: string;

    beforeEach(() => {
      away = mkdtempSync(join(tmpdir(), 'not-a-repo-'));
      was = process.cwd();
      process.chdir(away);
      vi.stubEnv('NODE_ENV', 'production');
      vi.stubEnv('HIMMEL_VERSION_WRITES', '');
      vi.stubEnv('HIMMEL_RELEASE_STATE_DIR', '');
      vi.stubEnv('HANDOVER_DIR', dir);
      vi.mocked(execFileSync).mockClear();
    });

    afterEach(() => {
      process.chdir(was);
      rmSync(away, { recursive: true, force: true });
    });

    it.each([['set', 'someone'], ['unset', '']])('with the state keys %s', async (_label, slug) => {
      vi.stubEnv('USER_SLUG', slug);
      const f = fakeJira({ key: 'HIMMEL-9', set: ['v1.1.3'], entries: [fv('600', null, 'v1.1.3')] });
      await expect(request('PUT', '/issue/HIMMEL-9', { fields: { fixVersions: [{ name: 'v1.1.4' }] } }, 'merge-stamp')).resolves.toEqual({});
      expect(f.calls.map((c) => c.method)).toEqual(['PUT']);
      const asked = gitCalls().filter((c) => (c[1] as string[]).includes('--git-common-dir'));
      expect(asked.length).toBeGreaterThan(0);
      for (const c of asked) expect((c[2] as { stdio: unknown[] }).stdio[2]).toBe('ignore');
    });
  });

  it('version-writes does not import history', () => {
    const src = readFileSync(join(dirname(fileURLToPath(import.meta.url)), 'release', 'version-writes.ts'), 'utf8');
    const imports = src.split('\n').filter((l) => /^import\b/.test(l)).join('\n');
    expect(imports).not.toMatch(/history/);
    expect(imports).not.toMatch(/client\.js/);
  });
});

// --- the live-test guard at both write exits ------------------------------------
// The marker is set in the own env (the vitest harness skips the ancestor walk), the station files say
// JIRA_TEST_PROJECT=HTEST, JIRA_PROJECTS=HIMMEL,LUNA and the station URL, and fetch is a fake Jira that
// answers each issue's project from its key prefix unless `moved` says otherwise.

const STATION = 'https://station.atlassian.net';
const LINKS: Record<string, unknown> = {
  '1': { inwardIssue: { key: 'HTEST-1' }, outwardIssue: { key: 'HTEST-2' } },
  '2': { inwardIssue: { key: 'HTEST-1' }, outwardIssue: { key: 'HIMMEL-1' } },
};
const VERSION_PROJECT: Record<string, number> = { '100': 10132, '200': 10000 };
const PROJECT_ID: Record<string, string> = { HTEST: '10132', HIMMEL: '10000' };

interface LiveCall { method: string; url: string; body?: unknown }
function liveJira(opts: { moved?: Record<string, string>; failGet?: number } = {}): { calls: LiveCall[]; writes: () => LiveCall[]; gets: () => LiveCall[] } {
  const calls: LiveCall[] = [];
  const reply = (status: number, body: unknown) => ({ ok: status < 400, status, text: async () => JSON.stringify(body ?? {}) });
  vi.stubGlobal('fetch', vi.fn(async (url: string, init: RequestInit = {}) => {
    const method = init.method ?? 'GET';
    calls.push({ method, url, ...(typeof init.body === 'string' ? { body: JSON.parse(init.body) } : {}) });
    if (method !== 'GET') return reply(200, { key: 'HTEST-99', id: '1' });
    if (opts.failGet) return reply(opts.failGet, { errorMessages: ['boom'] });
    const path = new URL(url).pathname.replace(/^\/rest\/api\/3/, '');
    let m = /^\/issue\/([^/]+)(\/.*)?$/.exec(path);
    if (m) {
      const ref = m[1];
      const project = opts.moved?.[ref] ?? (/^[0-9]+$/.test(ref) ? 'HTEST' : ref.split('-')[0]);
      if (m[2] === '/comment') return reply(200, { comments: [], total: 0, startAt: 0, maxResults: 50 });
      if (m[2] === '/transitions') return reply(200, { transitions: [{ id: '31', name: 'Done', to: { name: 'Done' } }] });
      return reply(200, { key: ref, fields: { project: { key: project }, summary: 's', issuetype: { name: 'Task' }, description: null } });
    }
    if ((m = /^\/issueLink\/([0-9]+)$/.exec(path))) return reply(200, LINKS[m[1]]);
    if ((m = /^\/version\/([0-9]+)$/.exec(path))) return reply(200, { id: m[1], projectId: VERSION_PROJECT[m[1]] });
    if ((m = /^\/project\/([A-Z0-9]+)$/.exec(path))) return reply(200, { id: PROJECT_ID[m[1]], key: m[1] });
    return reply(404, {});
  }));
  return { calls, writes: () => calls.filter((c) => c.method !== 'GET'), gets: () => calls.filter((c) => c.method === 'GET') };
}

const REFUSED = /^jira: live-test write refused: .*HTEST/s;
const REFUSED_ANYWHERE = /jira: live-test write refused: .*HTEST/s;

describe('the live-test guard at requestAt and uploadMultipart', () => {
  let dir: string;
  const conf = (extra = ''): void =>
    writeFileSync(join(dir, 'himmel.conf'), `JIRA_BASE_URL=${STATION}\nJIRA_PROJECTS=HIMMEL,LUNA\n${extra}`);
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'jira-live-guard-'));
    conf('JIRA_TEST_PROJECT=HTEST\n');
    vi.stubEnv('HIMMEL_CONFIG_DIR', dir);
    vi.stubEnv('HIMMEL_JIRA_LIVE_TEST', 'none');
    vi.stubEnv('HIMMEL_PROFILE', '');
    vi.stubEnv('JIRA_BASE_URL', STATION);
    vi.stubEnv('HIMMEL_VERSION_WRITES', join(dir, 'version-writes.jsonl'));
    door.status = 0;
  });
  afterEach(() => {
    vi.unstubAllEnvs();
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
    rmSync(dir, { recursive: true, force: true });
  });

  it('DoD 1 / I1 / I9 create in HIMMEL is refused under the marker and names HTEST', async () => {
    const j = liveJira();
    await expect(requestAt('/rest/api/3', 'POST', '/issue', { fields: { project: { key: 'HIMMEL' } } }))
      .rejects.toThrow(/^jira: live-test write refused: .*HIMMEL.*HTEST/s);
    expect(j.writes()).toEqual([]);
  });

  it('DoD 2 create in HTEST proceeds', async () => {
    const j = liveJira();
    await requestAt('/rest/api/3', 'POST', '/issue', { fields: { project: { key: 'HTEST' } } });
    expect(j.writes().map((c) => c.method)).toEqual(['POST']);
  });

  const API = '/rest/api/3';
  const AGILE = '/rest/agile/1.0';
  const withKey = (body: unknown, key: string): unknown =>
    body === undefined ? undefined : JSON.parse(JSON.stringify(body).replace(/"K"/g, `"${key}"`));
  it.each([
    ['edit', API, 'PUT', '/issue/K', { fields: { summary: 's' } }],
    ['comment', API, 'POST', '/issue/K/comment', { body: {} }],
    ['comment edit', API, 'PUT', '/issue/K/comment/10200', { body: {} }],
    ['transition', API, 'POST', '/issue/K/transitions', { transition: { id: '31' } }],
    ['assignee', API, 'PUT', '/issue/K/assignee', { accountId: 'a' }],
    ['watch', API, 'POST', '/issue/K/watchers', 'abc:123'],
    ['unwatch', API, 'DELETE', '/issue/K/watchers?accountId=557058%3Aabc', undefined],
    ['worklog', API, 'POST', '/issue/K/worklog', { timeSpent: '1h' }],
    ['rank', AGILE, 'PUT', '/issue/rank', { issues: ['HTEST-2', 'K'], rankBeforeIssue: 'HTEST-3' }],
    ['backlog', AGILE, 'POST', '/backlog/issue', { issues: ['K'] }],
    ['sprint issue move', AGILE, 'POST', '/sprint/7/issue', { issues: ['HTEST-2', 'K'] }],
  ])('route %s: allowed on an HTEST issue, refused on a HIMMEL one', async (_name, apiBase, method, path, body) => {
    const j = liveJira();
    await requestAt(apiBase, method, path.replace('/K', '/HTEST-1'), withKey(body, 'HTEST-1'));
    expect(j.writes().length).toBe(1);
    await expect(requestAt(apiBase, method, path.replace('/K', '/HIMMEL-1'), withKey(body, 'HIMMEL-1'))).rejects.toThrow(REFUSED);
    expect(j.writes().length).toBe(1);
  });

  it.each([
    ['link sides each checked', API, 'POST', ['/issueLink', '/issueLink'],
      { inwardIssue: { key: 'HTEST-1' }, outwardIssue: { key: 'HTEST-2' } }, { inwardIssue: { key: 'HTEST-1' }, outwardIssue: { key: 'HIMMEL-1' } }],
    ['issueLink delete', API, 'DELETE', ['/issueLink/1', '/issueLink/2'], undefined, undefined],
    ['version create by key', API, 'POST', ['/version', '/version'], { project: 'HTEST', name: 'v0.0.1' }, { project: 'HIMMEL', name: 'v0.0.1' }],
    ['version create by id', API, 'POST', ['/version', '/version'], { projectId: 10132, name: 'v0.0.1' }, { projectId: 10000, name: 'v0.0.1' }],
    ['version edit', API, 'PUT', ['/version/100', '/version/200'], { archived: true }, { archived: true }],
    ['version move', API, 'POST', ['/version/100/move', '/version/200/move'], { position: 'First' }, { position: 'First' }],
  ])('route %s: one allowed and one refused', async (_name, apiBase, method, [ok, bad], okBody, badBody) => {
    const j = liveJira();
    await requestAt(apiBase, method, ok, okBody);
    expect(j.writes().length).toBe(1);
    await expect(requestAt(apiBase, method, bad, badBody)).rejects.toThrow(REFUSED);
    expect(j.writes().length).toBe(1);
  });

  it.each([
    '/issue/HTEST-1/../HIMMEL-1/comment', '/issue/HTEST-1/%2e%2e/comment', '/issue//HTEST-1/comment',
    '/issue/HTEST-1/comment/', '/issue/HTEST-1/comment?x=1', '/issue/htest-1/comment',
  ])('I2 / P7 unanchored paths are R-route: %s', async (path) => {
    const j = liveJira();
    await expect(request('POST', path, { body: {} })).rejects.toThrow(/^jira: live-test write refused: .* is not a write the live-test guard can tie to one project.*HTEST/s);
    expect(j.calls).toEqual([]);
  });

  it('I1 body link keys are targets', async () => {
    const j = liveJira();
    await expect(request('PUT', '/issue/HTEST-6', { update: { issuelinks: [{ add: { outwardIssue: { key: 'HIMMEL-1' } } }] } })).rejects.toThrow(REFUSED);
    await expect(request('POST', '/issue', { fields: { project: { key: 'HTEST' }, parent: { key: 'HIMMEL-2' } } })).rejects.toThrow(REFUSED);
    await expect(request('PUT', '/issue/HTEST-6', { update: { parent: [{ set: { key: 'HIMMEL-2' } }] } })).rejects.toThrow(REFUSED);
    expect(j.writes()).toEqual([]);
    await request('PUT', '/issue/HTEST-6', { update: { parent: [{ set: { key: 'HTEST-2' } }] } });
    expect(j.writes().length).toBe(1);
  });

  it('I1 own keys: an issue-scoped write on the brief ticket proceeds, other work writes are refused', async () => {
    vi.stubEnv('HIMMEL_JIRA_LIVE_TEST', 'HIMMEL-9577');
    const j = liveJira();
    await request('POST', '/issue/HIMMEL-9577/transitions', { transition: { id: '31' } });
    expect(j.writes().length).toBe(1);
    await expect(request('POST', '/issue/HIMMEL-1/comment', { body: {} })).rejects.toThrow(REFUSED);
    await expect(request('POST', '/issue', { fields: { project: { key: 'HIMMEL' } } })).rejects.toThrow(REFUSED);
    expect(j.writes().length).toBe(1);
  });

  it('I3 issue routes resolve by a fresh read', async () => {
    const j = liveJira({ moved: { 'HTEST-5': 'HIMMEL' } });
    await expect(request('POST', '/issue/HTEST-5/comment', { body: {} })).rejects.toThrow(/targets project HIMMEL.*HTEST/s);
    await request('POST', '/issue/HTEST-6/comment', { body: {} });
    await request('POST', '/issue/HTEST-6/comment', { body: {} });
    expect(j.gets().filter((c) => c.url.includes('/issue/HTEST-6?fields=project')).length).toBe(2);
  });

  it('I3 resolves a numeric issue id by read', async () => {
    const j = liveJira({ moved: { '10002': 'HIMMEL' } });
    await request('POST', '/issue/10001/comment', { body: {} });
    await expect(request('POST', '/issue/10002/comment', { body: {} })).rejects.toThrow(REFUSED);
    expect(j.gets().map((c) => new URL(c.url).pathname)).toEqual(['/rest/api/3/issue/10001', '/rest/api/3/issue/10002']);
    expect(j.writes().length).toBe(1);
  });

  async function move(src: string, to: string): Promise<string> {
    vi.spyOn(process, 'exit').mockImplementation(((code: number) => { throw new Error(`exit ${code}`); }) as never);
    const err = vi.spyOn(console, 'error').mockImplementation(() => undefined);
    vi.spyOn(console, 'log').mockImplementation(() => undefined);
    const program = new Command();
    registerMove(program);
    await program.parseAsync(['node', 'jira', 'move', src, '--to-project', to]).catch(() => undefined);
    return err.mock.calls.map((c) => c.join(' ')).join('\n');
  }

  it('move into a work project is refused before any write', async () => {
    const j = liveJira();
    expect(await move('HTEST-3', 'HIMMEL')).toMatch(REFUSED_ANYWHERE);
    expect(j.writes()).toEqual([]);
  });

  it('a move into HTEST from a work-project source is refused at its first source write', async () => {
    const j = liveJira();
    expect(await move('HIMMEL-7', 'HTEST')).toMatch(REFUSED_ANYWHERE);
    expect(j.writes().map((c) => `${c.method} ${new URL(c.url).pathname}`)).toEqual(['POST /rest/api/3/issue']);
  });

  it.each([
    ['project create', () => request('POST', '/project', { key: 'X' })],
    ['a Confluence page', () => confluenceV2('POST', '/pages', {})],
    ['a sprint create', () => agileRequest('POST', '/sprint', { name: 's' })],
  ])('I2 %s is R-route', async (_name, write) => {
    const j = liveJira();
    await expect(write()).rejects.toThrow(/is not a write the live-test guard can tie to one project.*HTEST/s);
    expect(j.calls).toEqual([]);
  });

  it('I2 a resolution GET answering 500 is R-route naming the read', async () => {
    const j = liveJira({ failGet: 500 });
    await expect(request('POST', '/issue/HTEST-1/comment', { body: {} }))
      .rejects.toThrow(/GET \/rest\/api\/3\/issue\/HTEST-1\?fields=project failed.*HTEST/s);
    expect(j.writes()).toEqual([]);
  });

  it('I5 no JIRA_TEST_PROJECT is R-none naming the setter', async () => {
    conf();
    const j = liveJira();
    await expect(request('POST', '/issue/HTEST-1/comment', { body: {} }))
      .rejects.toThrow(/^jira: live-test write refused: this is a live test \(HIMMEL_JIRA_LIVE_TEST\) but no valid Jira test project is configured.*himmelctl config set jira\.testProject/s);
    expect(j.calls).toEqual([]);
  });

  it('I14 a request to another instance is R-instance', async () => {
    vi.stubEnv('JIRA_BASE_URL', 'https://other.atlassian.net');
    const j = liveJira();
    await expect(request('POST', '/issue/HTEST-1/comment', { body: {} }))
      .rejects.toThrow(/this request goes to https:\/\/other\.atlassian\.net, not the station's Jira \(https:\/\/station\.atlassian\.net\).*HTEST/s);
    expect(j.calls).toEqual([]);
  });

  // No layer may hold a URL, the install .env included: git is made to fail, so only the checkout's own
  // .env is looked for (absent in a worktree and in CI).
  const ownEnv = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..', '.env');
  it.skipIf(existsSync(ownEnv))('I14 no station URL in any layer is R-instance', async () => {
    writeFileSync(join(dir, 'himmel.conf'), 'JIRA_PROJECTS=HIMMEL,LUNA\nJIRA_TEST_PROJECT=HTEST\n');
    vi.stubEnv('HIMMEL_REPO', '');
    vi.mocked(execFileSync).mockImplementation(() => { throw new Error('no git here'); });
    const j = liveJira();
    await expect(request('POST', '/issue/HTEST-1/comment', { body: {} })).rejects.toThrow(/no station Jira URL is configured.*HTEST/s);
    expect(j.calls).toEqual([]);
  });

  it('I14 an env HIMMEL_PROFILE naming another instance is R-instance', async () => {
    const vault = join(dir, 'vault');
    mkdirSync(join(vault, 'profiles'), { recursive: true });
    writeFileSync(join(vault, 'himmel.conf'), `JIRA_BASE_URL=${STATION}\nJIRA_PROJECTS=HIMMEL,LUNA\nJIRA_TEST_PROJECT=HTEST\n`);
    writeFileSync(join(vault, 'profiles', 'work.conf'), 'JIRA_BASE_URL=https://work.atlassian.net\n');
    rmSync(join(dir, 'himmel.conf'));
    symlinkSync(join(vault, 'himmel.conf'), join(dir, 'himmel.conf'));
    vi.stubEnv('HIMMEL_PROFILE', 'work');
    vi.stubEnv('JIRA_BASE_URL', 'https://work.atlassian.net');
    const j = liveJira();
    await expect(request('POST', '/issue/HTEST-1/comment', { body: {} })).rejects.toThrow(/goes to https:\/\/work\.atlassian\.net, not the station's Jira.*HTEST/s);
    expect(j.calls).toEqual([]);
  });

  it.each(['http://127.0.0.1:9', 'http://jira.invalid'])('I15 a write to %s passes the guard', async (base) => {
    vi.stubEnv('JIRA_BASE_URL', base);
    const j = liveJira();
    await request('POST', '/issue', { fields: { project: { key: 'HIMMEL' } } });
    expect(j.calls.map((c) => c.method)).toEqual(['POST']);
  });

  it('I5 / I15 with no JIRA_TEST_PROJECT a loopback write still passes', async () => {
    conf();
    vi.stubEnv('JIRA_BASE_URL', 'http://127.0.0.1:9');
    const j = liveJira();
    await request('POST', '/issue/HIMMEL-1/comment', { body: {} });
    expect(j.calls.map((c) => c.method)).toEqual(['POST']);
  });

  describe('uploadMultipart', () => {
    let file: string;
    beforeEach(() => {
      file = join(dir, 'a.png');
      writeFileSync(file, Buffer.from([0x89, 0x50]));
    });

    it('to a HIMMEL issue is refused, to an HTEST issue proceeds', async () => {
      const j = liveJira();
      await expect(uploadMultipart(`${STATION}/rest/api/3/issue/HIMMEL-1/attachments`, file)).rejects.toThrow(REFUSED);
      expect(j.writes()).toEqual([]);
      await uploadMultipart(`${STATION}/rest/api/3/issue/HTEST-1/attachments`, file);
      expect(j.writes().map((c) => c.url)).toEqual([`${STATION}/rest/api/3/issue/HTEST-1/attachments`]);
    });

    it('a URL not under the base is R-instance', async () => {
      const j = liveJira();
      await expect(uploadMultipart('https://other.atlassian.net/rest/api/3/issue/HTEST-1/attachments', file))
        .rejects.toThrow(/this request goes to https:\/\/other\.atlassian\.net.*HTEST/s);
      expect(j.calls).toEqual([]);
    });

    it('a Confluence attachment is R-route', async () => {
      const j = liveJira();
      await expect(uploadMultipart(`${STATION}/wiki/rest/api/content/1/child/attachment`, file))
        .rejects.toThrow(/is not a write the live-test guard can tie to one project.*HTEST/s);
      expect(j.calls).toEqual([]);
    });
  });

  it('I8 control: marker unset, POST /issue in HIMMEL sends exactly one fetch and no GET', async () => {
    vi.stubEnv('HIMMEL_JIRA_LIVE_TEST', '');
    const j = liveJira();
    await request('POST', '/issue', { fields: { project: { key: 'HIMMEL' } } });
    expect(j.calls.map((c) => c.method)).toEqual(['POST']);
  });
});
