import { describe, it, expect, beforeEach } from 'vitest';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const __dirname = fileURLToPath(new URL('.', import.meta.url));
const initCli = resolve(__dirname, '..', 'lib', 'init-cli.mjs');

let emptyEnv;

beforeEach(() => {
  // An env file with no JIRA_* keys, so loadEnvIntoProcess sets nothing.
  const dir = mkdtempSync(join(tmpdir(), 'himmel-initcli-'));
  emptyEnv = join(dir, '.env');
  writeFileSync(emptyEnv, '# no jira keys\n');
});

function discover(extraArgs, envOverrides) {
  // Clear inherited JIRA_PROJECT* so the test machine's real env can't leak in.
  const env = { ...process.env, JIRA_PROJECT_KEY: '', JIRA_PROJECTS: '', HIMMEL_CONFIG_DIR: join(emptyEnv, '..'), ...envOverrides };
  return spawnSync(process.execPath, [initCli, '--discover', '--env-path', emptyEnv, ...extraArgs], {
    encoding: 'utf8',
    env,
  });
}

describe('init-cli --discover project resolution (portability)', () => {
  it('exits 2 with a hint when no project is configured (no HIMMEL default)', () => {
    const r = discover([], {});
    expect(r.status).toBe(2);
    expect(r.stderr).toContain('no project configured');
    expect(r.stderr).toContain('JIRA_PROJECT_KEY');
    // Must NOT silently fall back to the himmel project.
    expect(r.stderr).not.toContain('HIMMEL');
  });
});

// The shared stub keyring (secret-tool + busctl first on PATH): no row here reaches a real keyring.
const KEYRING_STUB = resolve(__dirname, '..', '..', '..', 'scripts', 'lib', 'fixtures', 'keyring-stub.sh');
function stubbedRun(args, items = {}, locked = false, conf = '') {
  const dir = mkdtempSync(join(tmpdir(), 'himmel-initcli-kr-'));
  if (conf) { mkdirSync(join(dir, 'conf')); writeFileSync(join(dir, 'conf', 'himmel.conf'), conf); }
  expect(spawnSync('bash', ['-c', 'TMP="$1"; . "$2"', '_', dir, KEYRING_STUB], { encoding: 'utf8' }).status).toBe(0);
  const store = join(dir, 'keyring.tsv');
  writeFileSync(store, Object.entries(items).map(([k, v]) => `service=himmel key=${k} scope=user\t${v}\n`).join(''));
  const envFile = join(dir, '.env');
  const env = { ...process.env, PATH: `${join(dir, 'kbin')}:${process.env.PATH}`, KSTUB_STORE: store, KSTUB_LOG: join(dir, 'keyring.log'),
    KSTUB_LOCKED: String(locked), DBUS_SESSION_BUS_ADDRESS: `unix:path=${join(dir, 'stub-bus')}`, HIMMEL_CONFIG_DIR: join(dir, 'conf') };
  for (const k of ['JIRA_EMAIL', 'JIRA_API_TOKEN', 'JIRA_BASE_URL', 'JIRA_PROJECT_KEY', 'JIRA_PROJECTS', 'CREDENTIALS_DIRECTORY', 'HIMMEL_SECRETS_KEYRING']) delete env[k];
  const r = spawnSync(process.execPath, [initCli, ...args, '--env-path', envFile], { encoding: 'utf8', env });
  return { r, store, envFile };
}

describe('init-cli with credentials in the keyring', () => {
  it('--check passes with the token and email only in the keyring', () => {
    const { r, envFile } = stubbedRun(['--check'], { JIRA_EMAIL: 'kr@example.invalid', JIRA_API_TOKEN: 'keyring-fixture-token' });
    expect(r.status).toBe(0);
    expect(r.stdout).toContain('needs-prompt: JIRA_BASE_URL');
    expect(r.stdout).not.toContain('JIRA_API_TOKEN');
    expect(existsSync(envFile)).toBe(false);
  });

  it('--check passes on a migrated station: the email only in himmel.conf, the token only in the keyring, an empty .env', () => {
    const { r, envFile } = stubbedRun(['--check'], { JIRA_API_TOKEN: 'keyring-fixture-token' }, false,
      'JIRA_EMAIL=conf@example.invalid\nJIRA_BASE_URL=https://fixture.invalid\n');
    expect(r.status, r.stderr).toBe(0);
    expect(r.stdout.trim()).toBe('env-ok');
    expect(existsSync(envFile)).toBe(false);
  });

  it('--discover finds the project in himmel.conf on a migrated station (empty .env) instead of exiting 2', () => {
    const { r } = stubbedRun(['--discover'], { JIRA_API_TOKEN: 'keyring-fixture-token' }, false,
      'JIRA_PROJECT_KEY=FIXT\nJIRA_EMAIL=conf@example.invalid\nJIRA_BASE_URL=https://fixture.invalid\n');
    expect(r.stderr).not.toContain('no project configured');
    expect(r.status).not.toBe(2);
  });

  it('--discover names himmel.conf in its no-project hint', () => {
    const { r } = stubbedRun(['--discover']);
    expect(r.status).toBe(2);
    expect(r.stderr).toContain('himmel.conf');
  });

  it('--write-env with the keyring unlocked stores the token there, adds no token .env line, and keeps the email in .env', () => {
    const { r, store, envFile } = stubbedRun(['--write-env', '--email', 'new@example.invalid', '--token', 'new-fixture-token', '--base-url', 'https://fixture.invalid']);
    expect(r.status, r.stderr).toBe(0);
    expect(r.stdout).not.toContain('new-fixture-token');
    expect(readFileSync(envFile, 'utf8')).toBe('JIRA_EMAIL=new@example.invalid\nJIRA_BASE_URL=https://fixture.invalid\n');
    expect(readFileSync(store, 'utf8')).toContain('service=himmel key=JIRA_API_TOKEN scope=user\tnew-fixture-token');
  });

  it('--write-env with the keyring locked writes .env exactly as before', () => {
    const { r, store, envFile } = stubbedRun(['--write-env', '--email', 'new@example.invalid', '--token', 'new-fixture-token'], {}, true);
    expect(r.status, r.stderr).toBe(0);
    expect(r.stdout.trim()).toBe('env-written');
    expect(readFileSync(envFile, 'utf8')).toBe('JIRA_EMAIL=new@example.invalid\nJIRA_API_TOKEN=new-fixture-token\n');
    expect(readFileSync(store, 'utf8')).toBe('');
  });
});
