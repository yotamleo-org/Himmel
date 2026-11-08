import { describe, it, expect, afterEach, beforeEach, vi } from 'vitest';
import { Command } from 'commander';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { registerLiveTest } from './live-test.js';

const fixture = (name: string): string =>
  readFileSync(join(dirname(fileURLToPath(import.meta.url)), '..', 'fixtures', name), 'utf8');

let dir: string;
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'live-test-verb-'));
  vi.stubEnv('HIMMEL_CONFIG_DIR', dir);
  vi.stubEnv('HIMMEL_JIRA_LIVE_TEST', undefined as unknown as string);
});
afterEach(() => {
  vi.unstubAllEnvs();
  vi.restoreAllMocks();
  rmSync(dir, { recursive: true, force: true });
});

async function verb(conf: string, ...args: string[]): Promise<string> {
  writeFileSync(join(dir, 'himmel.conf'), conf);
  let out = '';
  vi.spyOn(process.stdout, 'write').mockImplementation((s: string | Uint8Array) => { out += String(s); return true; });
  const program = new Command();
  registerLiveTest(program);
  await program.parseAsync(['node', 'jira', 'live-test', '--json', ...args]);
  return out;
}

const STATION = 'JIRA_BASE_URL=https://station.atlassian.net\nJIRA_PROJECTS=HIMMEL,LUNA\n';

describe('jira live-test --json', () => {
  it('prints exactly fixtures/live-test-ok.json for a HTEST station', async () => {
    expect(await verb(`${STATION}JIRA_TEST_PROJECT=HTEST\n`)).toBe(fixture('live-test-ok.json'));
  });

  it('prints exactly fixtures/live-test-none.json with no JIRA_TEST_PROJECT', async () => {
    expect(await verb(STATION)).toBe(fixture('live-test-none.json'));
  });

  it('prints exactly fixtures/live-test-work.json for JIRA_TEST_PROJECT=HIMMEL', async () => {
    expect(await verb(`${STATION}JIRA_TEST_PROJECT=HIMMEL\n`)).toBe(fixture('live-test-work.json'));
  });

  it('prints exactly fixtures/live-test-marked.json under the own-env marker HIMMEL-9577', async () => {
    vi.stubEnv('HIMMEL_JIRA_LIVE_TEST', 'HIMMEL-9577');
    expect(await verb(`${STATION}JIRA_TEST_PROJECT=HTEST\n`)).toBe(fixture('live-test-marked.json'));
  });

  it('prints exactly fixtures/live-test-marked-none.json under the own-env marker none', async () => {
    vi.stubEnv('HIMMEL_JIRA_LIVE_TEST', 'none');
    expect(await verb(`${STATION}JIRA_TEST_PROJECT=HTEST\n`)).toBe(fixture('live-test-marked-none.json'));
  });

  it('--candidate HIMMEL reports the work-project problem', async () => {
    const out = JSON.parse(await verb(`${STATION}JIRA_TEST_PROJECT=HTEST\n`, '--candidate', 'HIMMEL'));
    expect(out).toMatchObject({ test_project: null, problem: 'HIMMEL is a work project (JIRA_PROJECTS)' });
  });

  it('--candidate HTEST on an unconfigured station gives test_project, the field the setter reads', async () => {
    const out = JSON.parse(await verb('', '--candidate', 'HTEST'));
    expect(out.test_project).toBe('HTEST');
    expect(out.problem).toBeNull();
  });
});
