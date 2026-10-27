import { describe, it, expect, afterEach } from 'vitest';
import { spawnSync } from 'node:child_process';
import { copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
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
