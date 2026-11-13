import { vi } from 'vitest';
import { mkdtempSync } from 'node:fs';
import { tmpdir, userInfo } from 'node:os';
import { join } from 'node:path';
import { recordLiveConfigDir } from './live/project-guard.js';

// The live suite reads the station's test project from the config dir the redirects below hide: record it first.
const liveConfigDir = recordLiveConfigDir(process.env, userInfo().homedir);
if (liveConfigDir) process.env.JIRA_LIVE_CONFIG_DIR = liveConfigDir;

// Point HOME at an empty dir so the operator's real ~/.himmel/config.json
// (jira.sectorField) never leaks into a test.
process.env.HOME = mkdtempSync(join(tmpdir(), 'jira-test-home-'));
delete process.env.JIRA_SECTOR_FIELD;

// A marked live-test worker still runs these unit suites, whose fetches are mocked; guard tests set the
// marker themselves.
delete process.env.HIMMEL_JIRA_LIVE_TEST;

// A --backlog filing queues an INTAKE under a declared release: keep every test
// off the operator's real release state.
process.env.HIMMEL_RELEASE_STATE_DIR = mkdtempSync(join(tmpdir(), 'jira-test-release-'));
process.env.HIMMEL_ADMISSIONS_LEDGER = join(mkdtempSync(join(tmpdir(), 'jira-test-admissions-')), 'admissions-ledger.jsonl');

// An inherited config or handover root would point a test at the station's own files:
// replace both with empty temp dirs.
process.env.HIMMEL_CONFIG_DIR = mkdtempSync(join(tmpdir(), 'jira-test-conf-'));
process.env.HANDOVER_DIR = mkdtempSync(join(tmpdir(), 'jira-test-handover-'));

// Keep every test off the real keyring; the resolver test turns it back on with a stub.
process.env.HIMMEL_SECRETS_KEYRING = "off";

if (!process.versions.bun) {
  const noProc = join(mkdtempSync(join(tmpdir(), 'jira-test-proc-')), 'absent');
  vi.doMock('./src/release/fence-ancestry.js', async (orig) => {
    const m = await orig<typeof import('./src/release/fence-ancestry.js')>();
    const walk: typeof m.walk = (o = {}) => m.walk(o.procRoot === undefined && o.hostNsPath === undefined ? { ...o, procRoot: noProc } : o);
    return { ...m, walk };
  });
}
