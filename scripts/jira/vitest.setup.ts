import { vi } from 'vitest';
import { mkdirSync, mkdtempSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir, userInfo } from 'node:os';
import { join } from 'node:path';
import { recordLiveConfigDir } from './live/project-guard.js';
import { makePassingNdStub } from './src/operations/readiness-stub.test-helper.js';

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

process.env.JIRA_READINESS_CHECK = makePassingNdStub();
delete process.env.JIRA_READINESS_TIMEOUT_MS;
delete process.env.HIMMEL_JIRA_MIRROR;

// Keep every test off the real keyring; the resolver test turns it back on with a stub.
process.env.HIMMEL_SECRETS_KEYRING = "off";

if (!process.versions.bun) {
  const procRoot = mkdtempSync(join(tmpdir(), 'jira-test-proc-'));
  const uid = process.getuid?.() ?? 0;
  const status = (ppid: number, nspid: number, u: number) => `Name:\tx\nPPid:\t${ppid}\nUid:\t${u}\t${u}\t${u}\t${u}\nNSpid:\t${nspid}\n`;
  for (const [pid, ppid, u] of [[300, 200, uid], [200, 1, uid], [1, 0, 0]] as const) {
    mkdirSync(join(procRoot, String(pid), 'ns'), { recursive: true });
    writeFileSync(join(procRoot, String(pid), 'status'), status(ppid, pid, u));
    if (pid !== 1) writeFileSync(join(procRoot, String(pid), 'environ'), 'PATH=/usr/bin\0');
  }
  writeFileSync(join(procRoot, '300', 'cmdline'), 'node\0vitest\0');
  symlinkSync('pid:[4026531836]', join(procRoot, '300', 'ns', 'pid'));
  symlinkSync('user:[4026531837]', join(procRoot, '300', 'ns', 'user'));
  symlinkSync('300', join(procRoot, 'self'));
  const hostNsPath = join(procRoot, 'host-ns');
  writeFileSync(hostNsPath, 'pid:[4026531836] user:[4026531837]\n');
  vi.doMock('./src/release/fence-ancestry.js', async (orig) => {
    const m = await orig<typeof import('./src/release/fence-ancestry.js')>();
    const walk: typeof m.walk = (o = {}) => {
      const base: typeof o = o.procRoot === undefined && o.hostNsPath === undefined ? { ...o, procRoot, hostNsPath, platform: 'linux' } : o;
      return m.walk({ ...base, execArgv: base.execArgv ?? [], env: base.env ?? {} });
    };
    return { ...m, walk };
  });
}
