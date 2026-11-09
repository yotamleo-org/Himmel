import { describe, it, expect, vi, beforeAll, beforeEach, afterAll, afterEach } from 'vitest';
import { execFile } from 'node:child_process';
import { existsSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { createServer, type Server } from 'node:http';
import type { AddressInfo } from 'node:net';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execCli, flags, runCli, type CliResult, type CliRunner } from './mcp-cli.js';
import { createTools } from './mcp.js';
import { PLAIN_BLOCK_TEMPLATE } from './plain-block.js';

// Spy on the child spawn without changing it: the real execFile still runs.
vi.mock('node:child_process', async (orig) => {
  const m = await orig<typeof import('node:child_process')>();
  return { ...m, execFile: vi.fn(m.execFile) };
});

const scratch: string[] = [];
const tmp = (prefix: string): string => {
  const d = mkdtempSync(join(tmpdir(), prefix));
  scratch.push(d);
  return d;
};
afterAll(() => {
  for (const d of scratch) rmSync(d, { recursive: true, force: true });
});

describe('flags', () => {
  const spec = { a: '--a', b: '--b', c: '--c', d: '--d', e: '--e', f: '--f' };

  it('a string or number gives --flag value', () => {
    expect(flags({ a: 'x', b: 3, c: 0 }, spec)).toEqual(['--a', 'x', '--b', '3', '--c', '0']);
  });

  it('an empty string is still a value', () => {
    expect(flags({ a: '' }, spec)).toEqual(['--a', '']);
  });

  it('true gives the bare flag', () => {
    expect(flags({ a: true }, spec)).toEqual(['--a']);
  });

  it('false, undefined and null are skipped', () => {
    expect(flags({ a: false, b: undefined, c: null }, spec)).toEqual([]);
  });

  it('an array repeats the flag', () => {
    expect(flags({ a: ['x', 'y', 3] }, spec)).toEqual(['--a', 'x', '--a', 'y', '--a', '3']);
    expect(flags({ a: [] }, spec)).toEqual([]);
  });

  it('an object is passed as one JSON string', () => {
    expect(flags({ a: { k: [1, 'v'] } }, spec)).toEqual(['--a', '{"k":[1,"v"]}']);
  });

  it('follows spec order, not argument order, and ignores keys outside the spec', () => {
    expect(flags({ c: '3', a: '1', zzz: 'no' }, spec)).toEqual(['--a', '1', '--c', '3']);
  });
});

describe('execCli', () => {
  beforeEach(() => {
    vi.mocked(execFile).mockClear();
  });

  it('a missing entry rejects with "not built" and spawns nothing', async () => {
    const missing = join(tmp('mcp-cli-missing-'), 'index.js');
    await expect(execCli(missing)(['get', 'K-1'])).rejects.toThrow(/not built/);
    await expect(execCli(missing)(['get', 'K-1'])).rejects.toThrow(/Nothing was sent to Jira/);
    expect(execFile).not.toHaveBeenCalled();
  });

  it('runs node <entry> ...argv once with no shell and reports code, stdout and stderr', async () => {
    const dir = tmp('mcp-cli-entry-');
    const entry = join(dir, 'index.js');
    writeFileSync(entry, "process.stdout.write(JSON.stringify(process.argv.slice(2)));process.stderr.write('warn');process.exitCode=Number(process.argv[2]==='fail'?4:0);\n");
    const ok = await execCli(entry)(['a b', '$(x)', '--flag']);
    expect(ok).toEqual({ code: 0, stdout: '["a b","$(x)","--flag"]', stderr: 'warn' });
    expect(execFile).toHaveBeenCalledTimes(1);
    const [file, args, opts] = vi.mocked(execFile).mock.calls[0] as unknown as [string, string[], { shell: boolean }];
    expect(file).toBe(process.execPath);
    expect(args).toEqual([entry, 'a b', '$(x)', '--flag']);
    expect(opts.shell).toBe(false);
    expect(await execCli(entry)(['fail'])).toMatchObject({ code: 4, stderr: 'warn' });
  });
});

describe('runCli', () => {
  const runner = (r: Partial<CliResult>): CliRunner => async () => ({ code: 0, stdout: '', stderr: '', ...r });

  it('code 0 returns stdout, then stderr warnings, trimmed at the end', async () => {
    expect(await runCli(runner({ stdout: 'out\n\n', stderr: 'w\n' }), ['get'])).toBe('out\nw');
    expect(await runCli(runner({ stdout: 'out\n' }), ['get'])).toBe('out');
    expect(await runCli(runner({ stderr: 'only warning\n' }), ['get'])).toBe('only warning');
  });

  it('a nonzero code throws stderr then stdout', async () => {
    await expect(runCli(runner({ code: 1, stdout: 'o\n', stderr: 'e\n' }), ['create'])).rejects.toThrow(/^e\no$/);
    await expect(runCli(runner({ code: 2, stderr: 'e' }), ['create'])).rejects.toThrow(/^e$/);
    await expect(runCli(runner({ code: 2 }), ['create'])).rejects.toThrow('jira create exited 2');
  });

  it('calls the runner exactly once with the argv', async () => {
    const run = vi.fn(runner({ stdout: 'x' }));
    await runCli(run, ['list', '--limit', '5']);
    expect(run).toHaveBeenCalledTimes(1);
    expect(run).toHaveBeenCalledWith(['list', '--limit', '5']);
  });
});

// The real built CLI against a loopback Jira stub: the bridge's whole path, no mocks past the network.
const CLI = resolve(fileURLToPath(new URL('..', import.meta.url)), 'dist', 'index.js');
const FILLED = PLAIN_BLOCK_TEMPLATE.replace(/<[^>\n]*>/g, 'filled');

type Seen = { method: string; path: string; body: string };

describe('loopback: the real CLI through the bridge', () => {
  let server: Server;
  let port = 0;
  let seen: Seen[] = [];

  beforeAll(async () => {
    server = createServer((req, res) => {
      const chunks: Buffer[] = [];
      req.on('data', (c: Buffer) => chunks.push(c));
      req.on('end', () => {
        const path = (req.url ?? '').split('?')[0];
        seen.push({ method: req.method ?? '', path, body: Buffer.concat(chunks).toString('utf8') });
        let reply: unknown = {};
        if (req.method === 'POST' && path === '/rest/api/3/issue') reply = { key: 'HIMMEL-1', id: '1' };
        else if (path.endsWith('/versions')) reply = [{ id: '10', name: 'v1', released: false, archived: false }];
        else if (path.endsWith('/search/jql')) reply = { issues: [] };
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(reply));
      });
    });
    await new Promise<void>((ok) => server.listen(0, '127.0.0.1', ok));
    port = (server.address() as AddressInfo).port;
  });
  afterAll(async () => {
    await new Promise<void>((ok) => server.close(() => ok()));
  });

  beforeEach(() => {
    seen = [];
    const root = tmp('mcp-loopback-');
    vi.stubEnv('JIRA_BASE_URL', `http://127.0.0.1:${port}`);
    vi.stubEnv('JIRA_PROJECT_KEY', 'HIMMEL');
    vi.stubEnv('JIRA_EMAIL', 'loopback@example.invalid');
    vi.stubEnv('JIRA_API_TOKEN', 'loopback-token');
    vi.stubEnv('HOME', join(root, 'home'));
    vi.stubEnv('HIMMEL_CONFIG_DIR', join(root, 'home', '.himmel'));
    vi.stubEnv('HIMMEL_RELEASE_STATE_DIR', join(root, 'release'));
    vi.stubEnv('HIMMEL_RELEASE_KEY_DIR', join(root, 'keys'));
    vi.stubEnv('HIMMEL_ADMISSIONS_LEDGER', join(root, 'admissions.jsonl'));
    vi.stubEnv('HANDOVER_DIR', join(root, 'handover'));
    vi.stubEnv('HIMMEL_SECRETS_KEYRING', 'off');
    vi.stubEnv('HIMMEL_JIRA_LIVE_TEST', '');
    vi.stubEnv('JIRA_SECTOR_FIELD', '');
  });
  afterEach(() => {
    vi.unstubAllEnvs();
  });

  const tool = (name: string) => {
    const t = createTools().find((x) => x.name === name);
    if (!t) throw new Error(`tool ${name} not registered`);
    return t;
  };
  const deps = () => ({ runCli: execCli(CLI) });
  const issuePosts = () => seen.filter((r) => r.method === 'POST' && r.path === '/rest/api/3/issue');
  const posts = () => seen.filter((r) => r.method !== 'GET');

  it('the CLI is built', () => {
    if (!existsSync(CLI)) throw new Error(`the built CLI is missing: ${CLI}. Run "npm run build" in scripts/jira (pretest does it); this test never skips.`);
  });

  it('an Epic create with a seven-section body files once and resolves Created HIMMEL-1', async () => {
    const out = await tool('create').handler({ type: 'Epic', title: 'Loopback epic', desc: FILLED, labels: 'standalone' }, deps());
    expect(out).toContain('Created HIMMEL-1');
    expect(issuePosts()).toHaveLength(1);
    const sent = JSON.parse(issuePosts()[0].body) as { fields: { project: { key: string }; summary: string; issuetype: { name: string } } };
    expect(sent.fields.project.key).toBe('HIMMEL');
    expect(sent.fields.summary).toBe('Loopback epic');
    expect(sent.fields.issuetype.name).toBe('Epic');
  });

  it('a Task create with a valid body and a home but no placement is refused naming placement, with no POST at all', async () => {
    await expect(
      tool('create').handler({ type: 'Task', title: 'Loopback task', desc: FILLED, labels: 'standalone' }, deps()),
    ).rejects.toThrow(/placement/i);
    expect(posts()).toEqual([]);
  });

  it('control: the same Task with a placement files through the CLI', async () => {
    const out = await tool('create').handler(
      { type: 'Task', title: 'Loopback task', desc: FILLED, labels: 'standalone', fixVersion: 'v1' }, deps(),
    );
    expect(out).toContain('Created HIMMEL-1');
    expect(issuePosts()).toHaveLength(1);
  });
});
