import { describe, it, expect, afterEach, beforeEach } from 'vitest';
import { spawnSync } from 'node:child_process';
import { chmodSync, copyFileSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { stubKeyring } from '../../config-ui/tests/keyring-stub';
import { authHeader, normalizeEnv } from './env.js';

it('loads the install .env from an unrelated cwd with no Bitbucket variables exported', () => {
  const root = mkdtempSync(join(tmpdir(), 'bitbucket-own-path-'));
  try {
    const installed = join(root, 'scripts', 'bitbucket', 'dist');
    const cwd = join(root, 'unrelated');
    const home = join(root, 'home');
    mkdirSync(installed, { recursive: true });
    mkdirSync(cwd);
    mkdirSync(home);
    const modulePath = join(installed, 'env.mjs');
    copyFileSync(new URL('../dist/env.js', import.meta.url), modulePath);
    // The built env.js imports the shared secrets helper from scripts/lib; the resolver itself is not
    // installed here, so this fixture never reaches a keyring.
    mkdirSync(join(root, 'scripts', 'lib'), { recursive: true });
    copyFileSync(new URL('../../lib/resolve-secrets.mjs', import.meta.url), join(root, 'scripts', 'lib', 'resolve-secrets.mjs'));
    writeFileSync(join(root, '.env'), 'BITBUCKET_EMAIL=fixture@example.invalid\nBITBUCKET_API_TOKEN=dummy\n');
    writeFileSync(join(cwd, '.env'), 'BITBUCKET_EMAIL=wrong@example.invalid\nBITBUCKET_API_TOKEN=wrong\n');
    const run = spawnSync(process.execPath, ['--input-type=module', '-e',
      `import { authHeader } from ${JSON.stringify(pathToFileURL(modulePath).href)}; process.stdout.write(authHeader());`,
    ], { cwd, env: { PATH: process.env.PATH, HOME: home }, encoding: 'utf8', timeout: 30000 });
    expect(run.error).toBeUndefined();
    expect(run.status, run.stderr).toBe(0);
    expect(run.stdout).toBe(`Basic ${Buffer.from('fixture@example.invalid:dummy').toString('base64')}`);
    expect(run.stderr).toBe('');
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

describe('normalizeEnv', () => {
  const keys = ['BITBUCKET_EMAIL', 'BITBUCKET_API_TOKEN', 'BITBUCKET_WORKSPACE', 'BITBUCKET_REPO_SLUG'];
  const saved = Object.fromEntries(keys.map((k) => [k, process.env[k]]));
  afterEach(() => {
    for (const k of keys) {
      if (saved[k] === undefined) delete process.env[k];
      else process.env[k] = saved[k];
    }
  });

  it('strips trailing CR/whitespace from CRLF-sourced env vars (CRLF-safe Basic auth)', () => {
    process.env.BITBUCKET_API_TOKEN = 'tok\r';
    process.env.BITBUCKET_EMAIL = 'u@example.com\r\n';
    normalizeEnv();
    expect(process.env.BITBUCKET_API_TOKEN).toBe('tok');
    expect(process.env.BITBUCKET_EMAIL).toBe('u@example.com');
  });

  it('is a no-op when values are already clean', () => {
    process.env.BITBUCKET_EMAIL = 'u@example.com';
    process.env.BITBUCKET_API_TOKEN = 'clean';
    normalizeEnv();
    expect(process.env.BITBUCKET_EMAIL).toBe('u@example.com');
    expect(process.env.BITBUCKET_API_TOKEN).toBe('clean');
  });
});

describe('authHeader', () => {
  const origEmail = process.env.BITBUCKET_EMAIL;
  const origToken = process.env.BITBUCKET_API_TOKEN;
  afterEach(() => {
    if (origEmail === undefined) delete process.env.BITBUCKET_EMAIL;
    else process.env.BITBUCKET_EMAIL = origEmail;
    if (origToken === undefined) delete process.env.BITBUCKET_API_TOKEN;
    else process.env.BITBUCKET_API_TOKEN = origToken;
  });

  it('builds a Basic header from email:token', () => {
    process.env.BITBUCKET_EMAIL = 'u@example.com';
    process.env.BITBUCKET_API_TOKEN = 'secret';
    const h = authHeader();
    expect(h).toBe(`Basic ${Buffer.from('u@example.com:secret').toString('base64')}`);
  });

  it('throws an actionable error when creds are missing', () => {
    delete process.env.BITBUCKET_EMAIL;
    delete process.env.BITBUCKET_API_TOKEN;
    expect(() => authHeader()).toThrow(/BITBUCKET_EMAIL and BITBUCKET_API_TOKEN/);
  });
});

// Rows S0-R2 and S0-R7 of the secrets-resolver slice. The built env.js runs from a fixture install whose
// scripts/lib holds the real resolver, over a stub keyring (secret-tool and busctl first on PATH).
// Every value is a dummy; no row reaches the station keyring.
describe('Bitbucket credentials through the secrets resolver', () => {
  let dir: string;
  let stub: ReturnType<typeof stubKeyring>;
  let log: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'bitbucket-resolver-'));
    stub = stubKeyring(dir);
    // Log every secret-tool argv (a value travels on stdin, never argv).
    const bin = join(dir, 'kbin');
    renameSync(join(bin, 'secret-tool'), join(bin, 'secret-tool.real'));
    writeFileSync(join(bin, 'secret-tool'),
      '#!/usr/bin/env bash\nprintf "secret-tool %s\\n" "$*" >>"$KSTUB_LOG"\nexec "$(dirname "$0")/secret-tool.real" "$@"\n');
    chmodSync(join(bin, 'secret-tool'), 0o755);
    log = join(dir, 'keyring.log');
    writeFileSync(log, '');
    // Suite guard: the resolver must find the stub, never a real secret-tool or busctl.
    for (const tool of ['secret-tool', 'busctl']) {
      const found = spawnSync('bash', ['-c', 'command -v ' + tool], { env: { PATH: stub.env.PATH }, encoding: 'utf8' }).stdout.trim();
      if (!found.startsWith(bin)) throw new Error(tool + ' resolves to ' + found + ', not the stub dir: aborting before any real keyring call');
    }
  });
  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  // A fixture install: <root>/scripts/bitbucket/dist/env.mjs beside <root>/scripts/lib/{resolver, loader}.
  function install(dotenv: string | null, withResolver = true): string {
    const root = join(dir, 'root');
    const dist = join(root, 'scripts', 'bitbucket', 'dist');
    const lib = join(root, 'scripts', 'lib');
    mkdirSync(dist, { recursive: true });
    mkdirSync(lib, { recursive: true });
    copyFileSync(new URL('../dist/env.js', import.meta.url), join(dist, 'env.mjs'));
    const libDir = new URL('../../lib/', import.meta.url);
    copyFileSync(new URL('resolve-secrets.mjs', libDir), join(lib, 'resolve-secrets.mjs'));
    if (withResolver) for (const f of ['himmel-secrets', 'load-dotenv.sh']) copyFileSync(new URL(f, libDir), join(lib, f));
    if (dotenv !== null) writeFileSync(join(root, '.env'), dotenv);
    return join(dist, 'env.mjs');
  }

  function header(modulePath: string, extra: Record<string, string> = {}): { status: number | null; stdout: string } {
    const run = spawnSync(process.execPath, ['--input-type=module', '-e',
      'import { authHeader } from ' + JSON.stringify(pathToFileURL(modulePath).href) + '; process.stdout.write(authHeader());',
    ], {
      cwd: dir,
      env: { ...stub.env, HOME: dir, KSTUB_LOG: log, KSTUB_LOCKED: 'false', ...extra },
      encoding: 'utf8', timeout: 30000,
    });
    return { status: run.status, stdout: run.stdout };
  }
  const basic = (email: string, token: string) => 'Basic ' + Buffer.from(email + ':' + token).toString('base64');
  const DOTENV = 'BITBUCKET_EMAIL=env@example.invalid\nBITBUCKET_API_TOKEN=dummy-dotenv-token\n';

  it('S0-R7 credentials held only in the keyring are served, and the stub log shows a lookup with no value', () => {
    stub.put('BITBUCKET_EMAIL', 'kr@example.invalid');
    stub.put('BITBUCKET_API_TOKEN', 'dummy-keyring-token');
    const run = header(install(null));
    expect(run.status).toBe(0);
    expect(run.stdout).toBe(basic('kr@example.invalid', 'dummy-keyring-token'));
    const calls = readFileSync(log, 'utf8');
    expect(calls).toMatch(/secret-tool lookup .*key BITBUCKET_API_TOKEN/);
    expect(calls).not.toContain('dummy-keyring-token');
  });

  it('S0-R2 a key in both the keyring and .env resolves to the keyring value', () => {
    stub.put('BITBUCKET_API_TOKEN', 'dummy-keyring-token');
    expect(header(install(DOTENV)).stdout).toBe(basic('env@example.invalid', 'dummy-keyring-token'));
  });

  it('a name the keyring does not hold still comes from .env', () => {
    expect(header(install(DOTENV)).stdout).toBe(basic('env@example.invalid', 'dummy-dotenv-token'));
  });

  it('a missing resolver falls back to .env', () => {
    expect(header(install(DOTENV, false)).stdout).toBe(basic('env@example.invalid', 'dummy-dotenv-token'));
  });

  it('a failing keyring lookup falls back to .env', () => {
    stub.put('BITBUCKET_API_TOKEN', 'dummy-keyring-token');
    expect(header(install(DOTENV), { KSTUB_LOOKUP_FAIL: '1' }).stdout).toBe(basic('env@example.invalid', 'dummy-dotenv-token'));
  });
});
