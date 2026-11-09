import { describe, it, expect, afterEach, beforeEach, vi } from 'vitest';
import { Command } from 'commander';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { configReport, registerConfig } from './config.js';

const EMAIL = 'sentinel-person@example.invalid';
const TOKEN = 'SENTINEL-TOKEN-0123456789';

let home: string;
let envFile: string;
beforeEach(() => {
  home = mkdtempSync(join(tmpdir(), 'jira-config-verb-'));
  mkdirSync(join(home, '.himmel'));
  envFile = join(home, 'install', '.env');
  mkdirSync(join(home, 'install'));
  vi.stubEnv('HOME', home);
  vi.stubEnv('HIMMEL_CONFIG_DIR', undefined as unknown as string);
  // The suite-wide dummy credentials are unset here: every row below that asserts "not set" owns that.
  for (const k of ['JIRA_BASE_URL', 'JIRA_PROJECT_KEY', 'JIRA_SEVERITY_FIELD', 'JIRA_BOARD_ID', 'JIRA_SECTOR_FIELD',
    'JIRA_EMAIL', 'JIRA_API_TOKEN', 'CREDENTIALS_DIRECTORY']) vi.stubEnv(k, undefined as unknown as string);
});
afterEach(() => {
  vi.unstubAllEnvs();
  vi.restoreAllMocks();
  rmSync(home, { recursive: true, force: true });
});

const conf = (name: string, text: string): string => {
  const path = join(home, '.himmel', name);
  writeFileSync(path, text);
  return path;
};
const report = () => configReport(join(home, '.himmel'), envFile);

describe('jira config', () => {
  it('prints the site URL, project key and the file each came from, and no secret', async () => {
    const path = conf(
      'himmel.conf',
      `JIRA_BASE_URL=https://station.atlassian.net\nJIRA_PROJECT_KEY=HIMMEL\nJIRA_EMAIL=${EMAIL}\nJIRA_API_TOKEN=${TOKEN}\n`,
    );
    vi.stubEnv('JIRA_API_TOKEN', TOKEN);
    let out = '';
    vi.spyOn(process.stdout, 'write').mockImplementation((s: string | Uint8Array) => { out += String(s); return true; });
    const program = new Command();
    registerConfig(program);
    await program.parseAsync(['node', 'jira', 'config']);
    expect(out).toContain('site URL: https://station.atlassian.net');
    expect(out).toContain(`source: ${path}`);
    expect(out).toContain('project key: HIMMEL');
    expect(out).toContain('himmel.conf');
    expect(out).toContain('jira config');
    expect(out).not.toContain(TOKEN);
    expect(out).not.toContain(EMAIL);
  });

  it('names himmel.conf.local when it holds the value, ahead of himmel.conf', () => {
    conf('himmel.conf', 'JIRA_BASE_URL=https://conf.atlassian.net\n');
    const local = conf('himmel.conf.local', 'JIRA_BASE_URL=https://local.atlassian.net\n');
    const r = report();
    expect(r.code).toBe(0);
    expect(r.out).toContain('site URL: https://local.atlassian.net');
    expect(r.out).toContain(`source: ${local}`);
  });

  it('prints the severity field, board id and sector field with their sources', () => {
    conf('himmel.conf', 'JIRA_BASE_URL=https://station.atlassian.net\n');
    writeFileSync(envFile, 'JIRA_SEVERITY_FIELD=customfield_10042\nJIRA_BOARD_ID=77\n');
    writeFileSync(join(home, '.himmel', 'config.json'), JSON.stringify({ jira: { sectorField: 'customfield_10099' } }));
    const r = report();
    expect(r.out).toContain('severity field: customfield_10042');
    expect(r.out).toContain('board id: 77');
    expect(r.out).toContain('sector field: customfield_10099');
    expect(r.out).toContain(`source: ${envFile}`);
    expect(r.out).toContain(`source: ${join(home, '.himmel', 'config.json')}`);
  });

  it('reports the optional settings as not set when nothing holds them', () => {
    conf('himmel.conf', 'JIRA_BASE_URL=https://station.atlassian.net\n');
    const r = report();
    expect(r.out).toContain('project key: (not set)');
    expect(r.out).toContain('severity field: (not set)');
    expect(r.out).toContain('board id: (not set)');
    expect(r.out).toContain('sector field: (not set)');
  });

  it('email and token: set or not set plus the source kind, never the value', () => {
    conf('himmel.conf', `JIRA_BASE_URL=https://station.atlassian.net\nJIRA_EMAIL=${EMAIL}\n`);
    const credDir = join(home, 'creds');
    mkdirSync(credDir);
    writeFileSync(join(credDir, 'JIRA_API_TOKEN'), TOKEN);
    vi.stubEnv('CREDENTIALS_DIRECTORY', credDir);
    const r = report();
    expect(r.out).toContain('JIRA_EMAIL: set');
    expect(r.out).toContain(`source: ${join(home, '.himmel', 'himmel.conf')}`);
    expect(r.out).toContain('JIRA_API_TOKEN: set');
    expect(r.out).toContain('source: credentials dir');
    expect(r.out).not.toContain(TOKEN);
    expect(r.out).not.toContain(EMAIL);
  });

  it('token source kinds: the install .env is env-file, an exported value is env', () => {
    conf('himmel.conf', 'JIRA_BASE_URL=https://station.atlassian.net\n');
    writeFileSync(envFile, `JIRA_API_TOKEN=${TOKEN}\n`);
    let r = report();
    expect(r.out).toContain('JIRA_API_TOKEN: set');
    expect(r.out).toContain('source: env-file');
    expect(r.out).not.toContain(TOKEN);
    rmSync(envFile);
    vi.stubEnv('JIRA_API_TOKEN', TOKEN);
    r = report();
    expect(r.out).toContain('JIRA_API_TOKEN: set');
    expect(r.out).toContain('source: env');
    expect(r.out).not.toContain(TOKEN);
  });

  it('control: nothing holds the email or token, so both print not set', () => {
    conf('himmel.conf', 'JIRA_BASE_URL=https://station.atlassian.net\n');
    const r = report();
    expect(r.out).toContain('JIRA_EMAIL: not set');
    expect(r.out).toContain('JIRA_API_TOKEN: not set');
  });

  it('control: no URL anywhere prints the JIRA_BASE_URL remedy on stderr and exits 2', () => {
    conf('himmel.conf', `JIRA_API_TOKEN=${TOKEN}\n`);
    const r = report();
    expect(r.code).toBe(2);
    expect(r.err).toContain('JIRA_BASE_URL is not set');
    expect(r.err).toContain('~/.himmel/himmel.conf');
    expect(r.out).toBe('');
    expect(r.err).not.toContain(TOKEN);
  });
});
