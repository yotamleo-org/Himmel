import { describe, it, expect } from 'vitest';
import { execFile } from 'node:child_process';
import { copyFileSync, mkdtempSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import type { AddressInfo } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  LIVE_BODY, assertLiveProject, liveChildEnv, liveVersionName, recordLiveConfigDir, resolveLiveProject,
} from './project-guard.js';
import { checkVersionName } from '../src/commands/versions.js';
import { lintPlainBlock } from '../src/plain-block.js';

const fixture = (name: string): string => fileURLToPath(new URL(`../src/fixtures/${name}`, import.meta.url));
const CLI = fileURLToPath(new URL('../dist/index.js', import.meta.url));

/** A stand-in CLI that prints one canned live-test file. */
function stubCli(canned: string): string {
  const dir = mkdtempSync(join(tmpdir(), 'live-stub-cli-'));
  const file = join(dir, 'cli.mjs');
  copyFileSync(fixture(canned), join(dir, 'out.json'));
  writeFileSync(file, "import { readFileSync } from 'node:fs';\nprocess.stdout.write(readFileSync(new URL('./out.json', import.meta.url), 'utf8'));\n");
  return file;
}

describe('assertLiveProject', () => {
  it('accepts the configured test project, refuses any other', () => {
    expect(() => assertLiveProject('HTEST', 'HTEST')).not.toThrow();
    expect(() => assertLiveProject('HIMTEST', 'HTEST')).toThrow(/configured test project HTEST/);
  });

  it.each(['', 'htest', '1TEST', 'H', 'HT EST', 'HTEST-1', '-HTEST'])('refuses %j: not a valid project key', (p) => {
    expect(() => assertLiveProject(p, p)).toThrow(/valid Jira project key/);
  });
});

describe('liveChildEnv', () => {
  it('sets the marker none, the config dir and the project; drops VITEST and NODE_ENV; keeps the credentials', () => {
    const base = { VITEST: 'true', NODE_ENV: 'test', JIRA_EMAIL: 'a@b.c', JIRA_API_TOKEN: 't', HIMMEL_CONFIG_DIR: '/tmp/redirected', JIRA_PROJECT_KEY: 'X' };
    const env = liveChildEnv(base, 'HTEST', '/station/.himmel');
    expect(env).toMatchObject({
      HIMMEL_JIRA_LIVE_TEST: 'none', HIMMEL_CONFIG_DIR: '/station/.himmel', JIRA_PROJECT_KEY: 'HTEST', JIRA_EMAIL: 'a@b.c', JIRA_API_TOKEN: 't',
    });
    expect('VITEST' in env).toBe(false);
    expect('NODE_ENV' in env).toBe(false);
    expect(base.VITEST).toBe('true');
  });
});

describe('live fixtures', () => {
  it('LIVE_BODY passes lintPlainBlock with no problems', () => {
    expect(lintPlainBlock(LIVE_BODY)).toEqual([]);
  });

  it('liveVersionName passes checkVersionName', () => {
    expect(checkVersionName(liveVersionName('abc12'))).toBe('v0.0.0-live.abc12');
  });
});

describe('resolveLiveProject', () => {
  const keep = process.env.JIRA_LIVE_PROJECT;
  const withOverride = <T>(value: string | undefined, fn: () => T): T => {
    if (value === undefined) delete process.env.JIRA_LIVE_PROJECT;
    else process.env.JIRA_LIVE_PROJECT = value;
    try {
      return fn();
    } finally {
      if (keep === undefined) delete process.env.JIRA_LIVE_PROJECT;
      else process.env.JIRA_LIVE_PROJECT = keep;
    }
  };

  it('takes test_project from the verb', () => {
    expect(withOverride(undefined, () => resolveLiveProject('/x', stubCli('live-test-ok.json')))).toBe('HTEST');
  });

  it('throws when the verb names no test project', () => {
    expect(() => withOverride(undefined, () => resolveLiveProject('/x', stubCli('live-test-none.json')))).toThrow(/himmelctl config set jira.testProject/);
  });

  it('throws when JIRA_LIVE_PROJECT differs from the configured project', () => {
    expect(() => withOverride('HIMTEST', () => resolveLiveProject('/x', stubCli('live-test-ok.json')))).toThrow(/configured test project HTEST/);
  });
});

describe('recordLiveConfigDir', () => {
  it('records HIMMEL_CONFIG_DIR, else HOME/.himmel, only when JIRA_LIVE_TEST=1', () => {
    const live: NodeJS.ProcessEnv = { JIRA_LIVE_TEST: '1', HOME: '/home/u', HIMMEL_CONFIG_DIR: '/conf' };
    recordLiveConfigDir(live);
    expect(live.JIRA_LIVE_CONFIG_DIR).toBe('/conf');
    const home: NodeJS.ProcessEnv = { JIRA_LIVE_TEST: '1', HOME: '/home/u' };
    recordLiveConfigDir(home);
    expect(home.JIRA_LIVE_CONFIG_DIR).toBe('/home/u/.himmel');
    const off: NodeJS.ProcessEnv = { HOME: '/home/u', HIMMEL_CONFIG_DIR: '/conf' };
    recordLiveConfigDir(off);
    expect('JIRA_LIVE_CONFIG_DIR' in off).toBe(false);
  });
});

describe('a live child', () => {
  it('sends one create POST through the guard, with a body that lints clean', async () => {
    const posts: Array<{ url: string; body: string }> = [];
    const server = createServer((req, res) => {
      let body = '';
      req.on('data', (c: Buffer) => (body += c));
      req.on('end', () => {
        res.setHeader('content-type', 'application/json');
        if (req.method === 'POST') {
          posts.push({ url: req.url ?? '', body });
          res.end(JSON.stringify({ id: '10001', key: 'HTEST-1' }));
        } else {
          res.end('{}');
        }
      });
    });
    await new Promise<void>((ok) => server.listen(0, '127.0.0.1', ok));
    const conf = mkdtempSync(join(tmpdir(), 'live-child-conf-'));
    writeFileSync(join(conf, 'himmel.conf'), 'JIRA_TEST_PROJECT=HTEST\n');
    const env = {
      ...liveChildEnv(process.env, 'HTEST', conf),
      JIRA_BASE_URL: `http://127.0.0.1:${(server.address() as AddressInfo).port}`,
      JIRA_EMAIL: 'live@example.invalid',
      JIRA_API_TOKEN: 'token',
    };
    try {
      const out = await new Promise<string>((ok, bad) =>
        execFile('node', [CLI, 'create', '--type', 'Task', '--title', 'live probe', '--desc', LIVE_BODY], { env, encoding: 'utf8' }, (e, stdout, stderr) =>
          e ? bad(new Error(`${e.message}\n${stderr}`)) : ok(stdout)),
      );
      expect(out).toContain('Created HTEST-1');
    } finally {
      server.close();
    }
    expect(posts.map((p) => p.url)).toEqual(['/rest/api/3/issue']);
    const description = JSON.stringify((JSON.parse(posts[0]!.body) as { fields: { description: unknown } }).fields.description);
    expect(description).toContain('Impact');
    expect(description).toContain('Agent detail');
  });
});
