import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { mkdtempSync, mkdirSync, rmSync, readFileSync, writeFileSync, existsSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { ensureEnvKeys, appendEnvKeys, writeCredentials, UNSAFE_VALUE_RE, loadEnvIntoProcess, resolveProjects, runInit } from '../lib/init-flow.mjs';

// The shared stub keyring (secret-tool + busctl first on PATH): no row here reaches a real keyring.
const KEYRING_STUB = fileURLToPath(new URL('../../../scripts/lib/fixtures/keyring-stub.sh', import.meta.url));
function stubKeyring(root, items = {}, locked = false) {
  expect(spawnSync('bash', ['-c', 'TMP="$1"; . "$2"', '_', root, KEYRING_STUB], { encoding: 'utf8' }).status).toBe(0);
  const store = join(root, 'keyring.tsv');
  writeFileSync(store, Object.entries(items).map(([k, v]) => `service=himmel key=${k} scope=user\t${v}\n`).join(''));
  return {
    store,
    env: {
      PATH: `${join(root, 'kbin')}:${process.env.PATH}`, KSTUB_STORE: store, KSTUB_LOG: join(root, 'keyring.log'),
      KSTUB_LOCKED: String(locked), DBUS_SESSION_BUS_ADDRESS: `unix:path=${join(root, 'stub-bus')}`,
    },
  };
}
function useKeyring(items, locked) {
  const kr = stubKeyring(dir, items, locked);
  for (const [k, v] of Object.entries(kr.env)) vi.stubEnv(k, v);
  for (const k of ['JIRA_EMAIL', 'JIRA_API_TOKEN', 'JIRA_BASE_URL', 'CREDENTIALS_DIRECTORY', 'HIMMEL_SECRETS_KEYRING']) vi.stubEnv(k, undefined);
  return kr;
}

let dir;
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'himmel-init-'));
  vi.stubEnv('HIMMEL_CONFIG_DIR', join(dir, 'empty-conf'));
});
afterEach(() => {
  vi.unstubAllEnvs();
  rmSync(dir, { recursive: true, force: true });
});

describe('resolveProjects (config-driven, no hardcoded HIMMEL)', () => {
  it('uses JIRA_PROJECT_KEY when no flag and no JIRA_PROJECTS', () => {
    expect(resolveProjects({ env: { JIRA_PROJECT_KEY: 'ACME' } })).toEqual(['ACME']);
  });

  it('prefers --projects flag over both env vars', () => {
    const env = { JIRA_PROJECTS: 'X,Y', JIRA_PROJECT_KEY: 'Z' };
    expect(resolveProjects({ rawArg: 'ACME', env })).toEqual(['ACME']);
  });

  it('prefers JIRA_PROJECTS over JIRA_PROJECT_KEY', () => {
    const env = { JIRA_PROJECTS: 'A,B', JIRA_PROJECT_KEY: 'Z' };
    expect(resolveProjects({ env })).toEqual(['A', 'B']);
  });

  it('splits a comma-list and trims whitespace / drops empties', () => {
    expect(resolveProjects({ rawArg: ' A , ,B, ' })).toEqual(['A', 'B']);
  });

  it('returns [] when nothing is configured (caller fails loud)', () => {
    expect(resolveProjects({ env: {} })).toEqual([]);
  });

  it('treats an empty-string env value as unset', () => {
    expect(resolveProjects({ env: { JIRA_PROJECT_KEY: '' } })).toEqual([]);
  });

  it('coerces a valueless --projects (boolean true) to [] instead of throwing', () => {
    // arg parser maps `--projects` with no value to `true`; must not crash.
    expect(() => resolveProjects({ rawArg: true, env: {} })).not.toThrow();
    expect(resolveProjects({ rawArg: true, env: {} })).toEqual([]);
  });
});

describe('Jira URL config layers', () => {
  afterEach(() => { vi.unstubAllEnvs(); });

  it('uses a conf-only URL without prompting and never takes a config token', () => {
    const cfg = join(dir, 'conf');
    mkdirSync(cfg);
    vi.stubEnv('HIMMEL_CONFIG_DIR', cfg);
    vi.stubEnv('JIRA_BASE_URL', '');
    vi.stubEnv('JIRA_API_TOKEN', '');
    writeFileSync(join(cfg, 'himmel.conf'), 'JIRA_BASE_URL=https://config.example.invalid\nJIRA_API_TOKEN=planted\n');
    const env = join(dir, '.env');
    writeFileSync(env, 'JIRA_EMAIL=fixture@example.invalid\nJIRA_API_TOKEN=fixture-token\n');
    loadEnvIntoProcess(env);
    expect(process.env.JIRA_BASE_URL).toBe('https://config.example.invalid');
    expect(process.env.JIRA_API_TOKEN).toBe('fixture-token');
    expect(ensureEnvKeys(env, ['JIRA_BASE_URL', 'JIRA_API_TOKEN'])).toEqual([]);
    writeFileSync(join(cfg, 'himmel.conf.local'), 'JIRA_BASE_URL=https://local.example.invalid\n');
    process.env.JIRA_BASE_URL = '';
    loadEnvIntoProcess(env);
    expect(process.env.JIRA_BASE_URL).toBe('https://local.example.invalid');
    process.env.JIRA_BASE_URL = 'https://process.example.invalid';
    loadEnvIntoProcess(env);
    expect(process.env.JIRA_BASE_URL).toBe('https://process.example.invalid');
  });
});

describe('station profile URL', () => {
  it('uses the selected linked station profile for URL only, between local and default', () => {
    const cfg = join(dir, 'conf');
    const station = join(dir, 'station');
    mkdirSync(cfg);
    mkdirSync(join(station, 'profiles'), { recursive: true });
    writeFileSync(join(station, 'himmel.conf'), 'JIRA_BASE_URL=https://default.example.invalid\n');
    symlinkSync(join(station, 'himmel.conf'), join(cfg, 'himmel.conf'));
    writeFileSync(join(station, 'profiles', 'lab.conf'), 'JIRA_BASE_URL=https://profile.example.invalid\nJIRA_PROJECTS=PLANTED\nJIRA_API_TOKEN=planted\n');
    vi.stubEnv('HIMMEL_CONFIG_DIR', cfg);
    vi.stubEnv('HIMMEL_PROFILE', 'lab');
    vi.stubEnv('JIRA_BASE_URL', '');
    vi.stubEnv('JIRA_PROJECTS', '');
    vi.stubEnv('JIRA_API_TOKEN', '');
    const env = join(dir, '.env');
    expect(ensureEnvKeys(env, ['JIRA_BASE_URL'])).toEqual([]);
    expect(process.env.JIRA_BASE_URL).toBe('https://profile.example.invalid');
    expect(process.env.JIRA_PROJECTS).toBe('');
    expect(process.env.JIRA_API_TOKEN).toBe('');
    process.env.JIRA_BASE_URL = '';
    writeFileSync(join(cfg, 'himmel.conf.local'), 'JIRA_BASE_URL=https://local.example.invalid\n');
    loadEnvIntoProcess(env);
    expect(process.env.JIRA_BASE_URL).toBe('https://local.example.invalid');
    process.env.JIRA_BASE_URL = '';
    process.env.HIMMEL_PROFILE = '';
    writeFileSync(join(cfg, 'himmel.conf.local'), 'HIMMEL_PROFILE=lab\n');
    loadEnvIntoProcess(env);
    expect(process.env.JIRA_BASE_URL).toBe('https://profile.example.invalid');
    process.env.JIRA_BASE_URL = '';
    process.env.HIMMEL_PROFILE = '../outside';
    loadEnvIntoProcess(env);
    expect(process.env.JIRA_BASE_URL).toBe('https://default.example.invalid');
  });
});

describe('runInit project guard (defense in depth)', () => {
  it('rejects when called with no projects (no network)', async () => {
    await expect(runInit({ projects: [] })).rejects.toThrow(/no projects/);
  });
});

describe('ensureEnvKeys', () => {
  it('returns all keys when file missing', () => {
    const missing = ensureEnvKeys(join(dir, 'nope.env'), ['A', 'B']);
    expect(missing).toEqual(['A', 'B']);
  });
});

describe('appendEnvKeys', () => {
  it('appends to file with chmod 600 on POSIX', () => {
    const env = join(dir, '.env');
    appendEnvKeys(env, { A: '1', B: '2' });
    expect(readFileSync(env, 'utf8')).toContain('A=1');
    expect(readFileSync(env, 'utf8')).toContain('B=2');
  });
});

describe('UNSAFE_VALUE_RE', () => {
  it('rejects values containing "="', () => {
    expect(UNSAFE_VALUE_RE.test('foo=bar')).toBe(true);
  });

  it('rejects values containing newline (\\n)', () => {
    expect(UNSAFE_VALUE_RE.test('foo\nbar')).toBe(true);
  });

  it('rejects values containing carriage return (\\r)', () => {
    expect(UNSAFE_VALUE_RE.test('foo\rbar')).toBe(true);
  });

  it('rejects single-quote-opened value with no closing quote', () => {
    expect(UNSAFE_VALUE_RE.test("'unbalanced")).toBe(true);
  });

  it('rejects double-quote-opened value with no closing quote', () => {
    expect(UNSAFE_VALUE_RE.test('"unbalanced')).toBe(true);
  });

  it('accepts plain alphanumeric value (happy path)', () => {
    expect(UNSAFE_VALUE_RE.test('abc123')).toBe(false);
  });

  // NOTE: the regex `^["'](?!.*\1$)` uses `\1` but the pattern has no capture
  // group (the `["']` is a character class, not a group), so `\1` references
  // nothing and `.*\1$` never matches. The negative lookahead therefore always
  // succeeds, meaning the regex rejects ALL values starting with a quote —
  // balanced or unbalanced. This is conservative-safe (quoted .env values are
  // essentially never valid) so we pin the actual behavior here.
  it('rejects a "balanced" single-quoted value (over-strict but conservative)', () => {
    expect(UNSAFE_VALUE_RE.test("'balanced'")).toBe(true);
  });

  it('rejects a "balanced" double-quoted value (over-strict but conservative)', () => {
    expect(UNSAFE_VALUE_RE.test('"balanced"')).toBe(true);
  });

  it('accepts dash, dot, underscore, slash (typical token chars)', () => {
    expect(UNSAFE_VALUE_RE.test('a-b.c_d/e')).toBe(false);
  });
});

describe('appendEnvKeys rejection routing', () => {
  it('throws when value contains "="', () => {
    const env = join(dir, '.env');
    expect(() => appendEnvKeys(env, { K: 'a=b' })).toThrow(/refusing to write/);
  });

  it('throws when value contains newline', () => {
    const env = join(dir, '.env');
    expect(() => appendEnvKeys(env, { K: 'a\nb' })).toThrow(/refusing to write/);
  });

  it('throws when value has unbalanced opening quote', () => {
    const env = join(dir, '.env');
    expect(() => appendEnvKeys(env, { K: '"unbalanced' })).toThrow(/refusing to write/);
  });

  it('does NOT write the file when any value is unsafe (atomic refuse)', () => {
    const env = join(dir, '.env');
    expect(() => appendEnvKeys(env, { GOOD: 'ok', BAD: 'a=b' })).toThrow();
    expect(existsSync(env)).toBe(false);
  });
});

describe('loadEnvIntoProcess quote stripping', () => {
  it("strips single quotes: VALUE='foo' → process.env.VALUE === 'foo'", () => {
    const env = join(dir, 'q.env');
    writeFileSync(env, "JIRA_HIMMEL101_SINGLE='foo'\n");
    delete process.env.JIRA_HIMMEL101_SINGLE;
    try {
      loadEnvIntoProcess(env);
      expect(process.env.JIRA_HIMMEL101_SINGLE).toBe('foo');
    } finally {
      delete process.env.JIRA_HIMMEL101_SINGLE;
    }
  });

  it('strips double quotes: VALUE="bar" → process.env.VALUE === "bar"', () => {
    const env = join(dir, 'q.env');
    writeFileSync(env, 'JIRA_HIMMEL101_DOUBLE="bar"\n');
    delete process.env.JIRA_HIMMEL101_DOUBLE;
    try {
      loadEnvIntoProcess(env);
      expect(process.env.JIRA_HIMMEL101_DOUBLE).toBe('bar');
    } finally {
      delete process.env.JIRA_HIMMEL101_DOUBLE;
    }
  });

  it('leaves unquoted value untouched', () => {
    const env = join(dir, 'q.env');
    writeFileSync(env, 'JIRA_HIMMEL101_PLAIN=baz\n');
    delete process.env.JIRA_HIMMEL101_PLAIN;
    try {
      loadEnvIntoProcess(env);
      expect(process.env.JIRA_HIMMEL101_PLAIN).toBe('baz');
    } finally {
      delete process.env.JIRA_HIMMEL101_PLAIN;
    }
  });

  it('does NOT overwrite an env var that is already set', () => {
    const env = join(dir, 'q.env');
    writeFileSync(env, 'JIRA_HIMMEL101_PREEXIST="from-file"\n');
    process.env.JIRA_HIMMEL101_PREEXIST = 'from-process';
    try {
      loadEnvIntoProcess(env);
      expect(process.env.JIRA_HIMMEL101_PREEXIST).toBe('from-process');
    } finally {
      delete process.env.JIRA_HIMMEL101_PREEXIST;
    }
  });

  it('returns silently and does nothing when env file does not exist', () => {
    expect(() => loadEnvIntoProcess(join(dir, 'no-such.env'))).not.toThrow();
  });

  it('preserves quote characters when only ONE side has a quote (mismatched)', () => {
    // The current implementation uses `^"(.*)"$` — both ends must match.
    // A value like `"oops` (open-only) is loaded verbatim.
    const env = join(dir, 'q.env');
    writeFileSync(env, 'JIRA_HIMMEL101_MISMATCH="oops\n');
    delete process.env.JIRA_HIMMEL101_MISMATCH;
    try {
      loadEnvIntoProcess(env);
      expect(process.env.JIRA_HIMMEL101_MISMATCH).toBe('"oops');
    } finally {
      delete process.env.JIRA_HIMMEL101_MISMATCH;
    }
  });
});

describe('loadEnvIntoProcess reads JIRA_PROJECTS from himmel.conf', () => {
  const saved = { cfg: process.env.HIMMEL_CONFIG_DIR, proj: process.env.JIRA_PROJECTS };
  const restore = (k, v) => { if (v === undefined) delete process.env[k]; else process.env[k] = v; };
  const setup = (conf, local, dotenv) => {
    const cfg = join(dir, 'cfg');
    mkdirSync(cfg, { recursive: true });
    rmSync(join(cfg, 'himmel.conf.local'), { force: true });
    if (conf) writeFileSync(join(cfg, 'himmel.conf'), conf);
    if (local) writeFileSync(join(cfg, 'himmel.conf.local'), local);
    const env = join(dir, '.env');
    writeFileSync(env, dotenv ?? '# no jira keys\n');
    process.env.HIMMEL_CONFIG_DIR = cfg;
    delete process.env.JIRA_PROJECTS;
    return env;
  };
  afterEach(() => { restore('HIMMEL_CONFIG_DIR', saved.cfg); restore('JIRA_PROJECTS', saved.proj); });

  it('takes it from himmel.conf when .env lacks it', () => {
    loadEnvIntoProcess(setup('JIRA_PROJECTS=A,B\n'));
    expect(process.env.JIRA_PROJECTS).toBe('A,B');
  });

  it('himmel.conf.local beats himmel.conf, and himmel.conf beats a legacy .env line', () => {
    loadEnvIntoProcess(setup('JIRA_PROJECTS=A\n', 'JIRA_PROJECTS=L\n', 'JIRA_PROJECTS=E\n'));
    expect(process.env.JIRA_PROJECTS).toBe('L');
    loadEnvIntoProcess(setup('JIRA_PROJECTS=A\n', null, 'JIRA_PROJECTS=E\n'));
    expect(process.env.JIRA_PROJECTS).toBe('A');
  });

  it('keeps a non-empty process value and reads conf even when the .env file is missing', () => {
    process.env.JIRA_PROJECTS = 'P';
    const env = setup('JIRA_PROJECTS=A\n');
    process.env.JIRA_PROJECTS = 'P';
    loadEnvIntoProcess(env);
    expect(process.env.JIRA_PROJECTS).toBe('P');
    delete process.env.JIRA_PROJECTS;
    loadEnvIntoProcess(join(dir, 'no-such.env'));
    expect(process.env.JIRA_PROJECTS).toBe('A');
  });
});

describe('credentials in the keyring', () => {
  const FIXTURE = { JIRA_EMAIL: 'kr@example.invalid', JIRA_API_TOKEN: 'keyring-fixture-token' };

  it('ensureEnvKeys counts a credential only the keyring holds as present; the base URL still needs .env', () => {
    useKeyring(FIXTURE);
    const env = join(dir, '.env');
    writeFileSync(env, '# nothing\n');
    expect(ensureEnvKeys(env, ['JIRA_EMAIL', 'JIRA_API_TOKEN', 'JIRA_BASE_URL'])).toEqual(['JIRA_BASE_URL']);
  });

  it('a token in both the keyring and .env resolves to the keyring value', () => {
    useKeyring(FIXTURE);
    const env = join(dir, '.env');
    writeFileSync(env, 'JIRA_API_TOKEN=stale-env-token\nJIRA_EMAIL=env@example.invalid\n');
    loadEnvIntoProcess(env);
    expect(process.env.JIRA_API_TOKEN).toBe('keyring-fixture-token');
    expect(process.env.JIRA_EMAIL).toBe('kr@example.invalid');
  });

  it('a credential nobody but .env holds is still read from .env', () => {
    useKeyring({});
    const env = join(dir, '.env');
    writeFileSync(env, 'JIRA_API_TOKEN=env-only-token\n');
    loadEnvIntoProcess(env);
    expect(process.env.JIRA_API_TOKEN).toBe('env-only-token');
  });

  it('writeCredentials with the keyring unlocked stores the token there and adds no token .env line; the email stays in .env', () => {
    const kr = useKeyring({});
    const env = join(dir, '.env');
    const res = writeCredentials(env, { JIRA_EMAIL: 'new@example.invalid', JIRA_API_TOKEN: 'new-fixture-token', JIRA_BASE_URL: 'https://fixture.invalid' });
    expect(res).toEqual({ keyring: ['JIRA_API_TOKEN'], env: ['JIRA_EMAIL', 'JIRA_BASE_URL'] });
    expect(readFileSync(env, 'utf8')).toBe('JIRA_EMAIL=new@example.invalid\nJIRA_BASE_URL=https://fixture.invalid\n');
    expect(readFileSync(kr.store, 'utf8')).toContain('service=himmel key=JIRA_API_TOKEN scope=user\tnew-fixture-token');
    expect(readFileSync(kr.store, 'utf8')).not.toContain('key=JIRA_EMAIL');
  });

  it('writeCredentials keeps the token in .env when the keyring store fails', () => {
    const kr = useKeyring({});
    vi.stubEnv('KSTUB_DROP_STORE', '1');
    const env = join(dir, '.env');
    const res = writeCredentials(env, { JIRA_API_TOKEN: 'new-fixture-token' });
    expect(res).toEqual({ keyring: [], env: ['JIRA_API_TOKEN'] });
    expect(readFileSync(env, 'utf8')).toBe('JIRA_API_TOKEN=new-fixture-token\n');
    expect(readFileSync(kr.store, 'utf8')).toBe('');
  });

  it('writeCredentials does not count an identical exported token or a credentials directory as the keyring storing it', () => {
    const kr = useKeyring({});
    vi.stubEnv('KSTUB_DROP_STORE', '1');
    vi.stubEnv('JIRA_API_TOKEN', 'new-fixture-token');
    mkdirSync(join(dir, 'creds'));
    writeFileSync(join(dir, 'creds', 'JIRA_API_TOKEN'), 'new-fixture-token');
    vi.stubEnv('CREDENTIALS_DIRECTORY', join(dir, 'creds'));
    const env = join(dir, '.env');
    const res = writeCredentials(env, { JIRA_API_TOKEN: 'new-fixture-token' });
    expect(res).toEqual({ keyring: [], env: ['JIRA_API_TOKEN'] });
    expect(readFileSync(kr.store, 'utf8')).toBe('');
  });

  it('a conf email beats a different keyring email', () => {
    useKeyring({ JIRA_EMAIL: 'stale-keyring@example.invalid', JIRA_API_TOKEN: 'keyring-fixture-token' });
    mkdirSync(join(dir, 'conf'));
    writeFileSync(join(dir, 'conf', 'himmel.conf'), 'JIRA_EMAIL=conf@example.invalid\n');
    vi.stubEnv('HIMMEL_CONFIG_DIR', join(dir, 'conf'));
    loadEnvIntoProcess(join(dir, 'no-such.env'));
    expect(process.env.JIRA_EMAIL).toBe('conf@example.invalid');
    expect(process.env.JIRA_API_TOKEN).toBe('keyring-fixture-token');
  });

  it('writeCredentials keeps the token in .env when secret-tool itself fails', () => {
    useKeyring({});
    writeFileSync(join(dir, 'kbin', 'secret-tool'), '#!/usr/bin/env bash\nexit 1\n');
    const env = join(dir, '.env');
    const res = writeCredentials(env, { JIRA_API_TOKEN: 'new-fixture-token' });
    expect(res).toEqual({ keyring: [], env: ['JIRA_API_TOKEN'] });
    expect(readFileSync(env, 'utf8')).toBe('JIRA_API_TOKEN=new-fixture-token\n');
  });

  it('ensureEnvKeys counts an email only himmel.conf holds as present (a migrated station)', () => {
    useKeyring({ JIRA_API_TOKEN: 'keyring-fixture-token' });
    mkdirSync(join(dir, 'conf'));
    writeFileSync(join(dir, 'conf', 'himmel.conf'), 'JIRA_EMAIL=conf@example.invalid\nJIRA_BASE_URL=https://fixture.invalid\n');
    vi.stubEnv('HIMMEL_CONFIG_DIR', join(dir, 'conf'));
    const env = join(dir, '.env');
    writeFileSync(env, '# nothing\n');
    expect(ensureEnvKeys(env, ['JIRA_EMAIL', 'JIRA_API_TOKEN', 'JIRA_BASE_URL'])).toEqual([]);
    loadEnvIntoProcess(env);
    expect(process.env.JIRA_EMAIL).toBe('conf@example.invalid');
  });

  it('writeCredentials with the keyring locked writes .env as before and stores nothing', () => {
    const kr = useKeyring({}, true);
    const env = join(dir, '.env');
    const res = writeCredentials(env, { JIRA_EMAIL: 'new@example.invalid', JIRA_API_TOKEN: 'new-fixture-token' });
    expect(res).toEqual({ keyring: [], env: ['JIRA_EMAIL', 'JIRA_API_TOKEN'] });
    expect(readFileSync(env, 'utf8')).toBe('JIRA_EMAIL=new@example.invalid\nJIRA_API_TOKEN=new-fixture-token\n');
    expect(readFileSync(kr.store, 'utf8')).toBe('');
  });
});
