import { describe, it, expect, beforeEach } from 'vitest';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir, platform } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { writeThreadCache } from '../lib/thread-cache.mjs';
import { expandPrefix } from '../lib/thread-prefix.mjs';

const IS_WIN = platform() === 'win32';
const REPLY_CLI = join(import.meta.dirname, '..', 'lib', 'thread-reply-cli.mjs');
const RESOLVE_CLI = join(import.meta.dirname, '..', 'lib', 'thread-resolve-action-cli.mjs');

let dir; // env root
let cacheRoot; // <dir>/himmel-cli

// Pre-populate a thread cache the spawned CLI will read, and return the
// generated 6-char prefix for the given thread id.
function seedCache(owner, repo, number, nodes) {
  const data = writeThreadCache(cacheRoot, owner, repo, number, nodes);
  return Object.keys(data.threads);
}

function cacheEnv(extra = {}) {
  const base = IS_WIN ? { LOCALAPPDATA: dir } : { XDG_CACHE_HOME: dir, HOME: dir };
  return { ...process.env, ...base, ...extra };
}

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'himmel-gh-mutate-'));
  cacheRoot = join(dir, 'himmel-cli');
  mkdirSync(cacheRoot, { recursive: true });
});

describe('expandPrefix (shared helper)', () => {
  it('returns ok + id for a unique prefix', () => {
    const [prefix] = seedCache('o', 'r', 1, [{ id: 'PRRT_a', path: 'a', line: 1, isResolved: false }]);
    // writeThreadCache wrote under cacheRoot; readThreadCache (inside expandPrefix)
    // uses osCacheRoot, so point the env at the same root for this in-process call.
    const saved = IS_WIN ? process.env.LOCALAPPDATA : process.env.XDG_CACHE_HOME;
    if (IS_WIN) process.env.LOCALAPPDATA = dir;
    else process.env.XDG_CACHE_HOME = dir;
    try {
      const res = expandPrefix({ owner: 'o', repo: 'r', number: 1, prefix });
      expect(res).toEqual({ ok: true, id: 'PRRT_a' });
    } finally {
      if (IS_WIN) process.env.LOCALAPPDATA = saved;
      else process.env.XDG_CACHE_HOME = saved;
    }
  });

  it('returns no-match for an unknown prefix', () => {
    seedCache('o', 'r', 1, [{ id: 'PRRT_a', path: 'a', line: 1, isResolved: false }]);
    const saved = IS_WIN ? process.env.LOCALAPPDATA : process.env.XDG_CACHE_HOME;
    if (IS_WIN) process.env.LOCALAPPDATA = dir;
    else process.env.XDG_CACHE_HOME = dir;
    try {
      const res = expandPrefix({ owner: 'o', repo: 'r', number: 1, prefix: 'ffffff' });
      expect(res.ok).toBe(false);
      expect(res.message).toMatch(/no-match/);
    } finally {
      if (IS_WIN) process.env.LOCALAPPDATA = saved;
      else process.env.XDG_CACHE_HOME = saved;
    }
  });

  it('returns ambiguous when a short prefix matches multiple threads', () => {
    // 40 threads > 16 hex digits → by pigeonhole, two 6-char prefixes share a
    // leading hex digit; querying that single digit is ambiguous.
    const nodes = Array.from({ length: 40 }, (_, i) => ({
      id: `T${i}`,
      path: 'a',
      line: 1,
      isResolved: false,
    }));
    const keys = seedCache('o', 'r', 2, nodes);
    const byFirst = {};
    for (const k of keys) (byFirst[k[0]] ??= []).push(k);
    const shared = Object.values(byFirst).find((g) => g.length >= 2);
    expect(shared).toBeDefined();
    const short = shared[0][0];
    const saved = IS_WIN ? process.env.LOCALAPPDATA : process.env.XDG_CACHE_HOME;
    if (IS_WIN) process.env.LOCALAPPDATA = dir;
    else process.env.XDG_CACHE_HOME = dir;
    try {
      const res = expandPrefix({ owner: 'o', repo: 'r', number: 2, prefix: short });
      expect(res.ok).toBe(false);
      expect(res.message).toMatch(/ambiguous/);
    } finally {
      if (IS_WIN) process.env.LOCALAPPDATA = saved;
      else process.env.XDG_CACHE_HOME = saved;
    }
  });
});

// no-cache exit path runs everywhere (it returns before any forge mutate).
describe('thread-reply-cli / thread-resolve-action-cli — no-cache', () => {
  it('reply CLI exits 1 with no-cache when the prefix cache is absent', () => {
    const res = spawnSync(
      process.execPath,
      [REPLY_CLI, '--owner', 'o', '--repo', 'r', '--number', '9', '--prefix', 'abc123', '--body', 'hi'],
      { env: cacheEnv(), cwd: dir, encoding: 'utf8' },
    );
    expect(res.status).toBe(1);
    expect(res.stderr).toMatch(/no-cache/);
  });

  it('resolve CLI exits 1 with no-cache when the prefix cache is absent', () => {
    const res = spawnSync(
      process.execPath,
      [RESOLVE_CLI, '--owner', 'o', '--repo', 'r', '--number', '9', '--prefix', 'abc123', '--reason', 'fixed abc1234'],
      { env: cacheEnv(), cwd: dir, encoding: 'utf8' },
    );
    expect(res.status).toBe(1);
    expect(res.stderr).toMatch(/no-cache/);
  });
});

// Bitbucket forge route: stub bitbucket CLI via env. Runs on Windows too:
// the JSON-array BITBUCKET_CLI is parsed as exact argv, so the space in
// process.execPath never reaches the (space-splitting) legacy path.
describe('thread mutate CLIs — bitbucket forge route', () => {
  let stub;
  function writeBbStub(body) {
    stub = join(dir, 'bb-stub.mjs');
    writeFileSync(stub, body);
  }
  function envBb() {
    return cacheEnv({ FORGE: 'bitbucket', BITBUCKET_CLI: JSON.stringify([process.execPath, stub]) });
  }

  it('reply routes `pr reply <n> <id> --body` and prints reply: ok', () => {
    const [prefix] = seedCache('ws', 'repo', 4, [{ id: '10', path: 'a', line: 1, isResolved: false }]);
    writeBbStub(
      `const a = process.argv.slice(2);
       if (a[0]==='pr'&&a[1]==='reply'&&a[2]==='4'&&a[3]==='10'&&a[4]==='--body'&&a[5]==='fixed it') {
         process.stdout.write('{"id":99}'); process.exit(0);
       }
       process.stderr.write('bad args: '+a.join('|')); process.exit(9);`,
    );
    const res = spawnSync(
      process.execPath,
      [REPLY_CLI, '--owner', 'ws', '--repo', 'repo', '--number', '4', '--prefix', prefix, '--body', 'fixed it'],
      { env: envBb(), cwd: dir, encoding: 'utf8' },
    );
    expect(res.status).toBe(0);
    expect(res.stdout).toMatch(/reply: ok/);
  });

  it('resolve replies with the reason, then routes `pr resolve <n> <id>` and prints resolved: ok', () => {
    const [prefix] = seedCache('ws', 'repo', 4, [{ id: '20', path: 'a', line: 1, isResolved: false }]);
    writeBbStub(
      `const a = process.argv.slice(2);
       if (a[0]==='pr'&&a[1]==='reply'&&a[2]==='4'&&a[3]==='20'&&a[4]==='--body'&&a[5]==='Fixed at abc1234.') { process.stdout.write('{"id":1}'); process.exit(0); }
       if (a[0]==='pr'&&a[1]==='resolve'&&a[2]==='4'&&a[3]==='20') { process.stdout.write('{"resolved":true}'); process.exit(0); }
       process.stderr.write('bad args: '+a.join('|')); process.exit(9);`,
    );
    const res = spawnSync(
      process.execPath,
      [RESOLVE_CLI, '--owner', 'ws', '--repo', 'repo', '--number', '4', '--prefix', prefix, '--reason', 'fixed abc1234'],
      { env: envBb(), cwd: dir, encoding: 'utf8' },
    );
    expect(res.status).toBe(0);
    expect(res.stdout).toMatch(/resolved: ok/);
  });

  // A stub that appends each argv (joined by |) to a log, so a row can assert
  // the call order. failReply makes `pr reply` fail.
  function writeLoggingBbStub({ failReply = false } = {}) {
    const log = join(dir, 'bb.log');
    writeBbStub(
      `import { appendFileSync } from 'node:fs';
       const a = process.argv.slice(2);
       appendFileSync(${JSON.stringify(log)}, a.join('|') + '\\n');
       if (a[1]==='reply' && ${failReply}) { process.stderr.write('reply refused\\n'); process.exit(1); }
       process.stdout.write('{}'); process.exit(0);`,
    );
    return () => {
      try {
        return readFileSync(log, 'utf8').trim().split('\n').filter(Boolean);
      } catch {
        return [];
      }
    };
  }
  function runResolveBb(threadArgs) {
    return spawnSync(
      process.execPath,
      [RESOLVE_CLI, '--owner', 'ws', '--repo', 'repo', '--number', '4', ...threadArgs, '--reason', 'fixed abc1234'],
      { env: envBb(), cwd: dir, encoding: 'utf8' },
    );
  }

  it('resolve posts the reply before the resolve', () => {
    const [prefix] = seedCache('ws', 'repo', 4, [{ id: '30', path: 'a', line: 1, isResolved: false }]);
    const calls = writeLoggingBbStub();
    const res = runResolveBb(['--prefix', prefix]);
    expect(res.status).toBe(0);
    expect(calls()).toEqual(['pr|reply|4|30|--body|Fixed at abc1234.', 'pr|resolve|4|30']);
  });

  it('a failed reply leaves the thread unresolved: no resolve call', () => {
    const [prefix] = seedCache('ws', 'repo', 4, [{ id: '31', path: 'a', line: 1, isResolved: false }]);
    const calls = writeLoggingBbStub({ failReply: true });
    const res = runResolveBb(['--prefix', prefix]);
    expect(res.status).toBe(1);
    expect(res.stderr).toMatch(/reply refused/);
    expect(calls()).toEqual(['pr|reply|4|31|--body|Fixed at abc1234.']);
  });

  it('refuses --thread-id on the bitbucket route: exit 2, no CLI call', () => {
    const calls = writeLoggingBbStub();
    const res = runResolveBb(['--thread-id', '32']);
    expect(res.status).toBe(2);
    expect(res.stderr).toMatch(/--thread-id is not checked against the PR on Bitbucket/);
    expect(calls()).toEqual([]);
  });

  it('reply propagates a bitbucket CLI failure as exit 1', () => {
    const [prefix] = seedCache('ws', 'repo', 4, [{ id: '10', path: 'a', line: 1, isResolved: false }]);
    writeBbStub(`process.stderr.write('comment gone\\n'); process.exit(1);`);
    const res = spawnSync(
      process.execPath,
      [REPLY_CLI, '--owner', 'ws', '--repo', 'repo', '--number', '4', '--prefix', prefix, '--body', 'x'],
      { env: envBb(), cwd: dir, encoding: 'utf8' },
    );
    expect(res.status).toBe(1);
    expect(res.stderr).toMatch(/comment gone/);
  });
});

// GitHub route with a fake `gh` first on PATH that logs each argv. A resolve
// must carry a reason, post it as a thread reply, and resolve only after the
// reply lands. POSIX only: the fake is a shell script.
describe.skipIf(IS_WIN)('thread-resolve-action-cli — mandatory reason (github route)', () => {
  let log;
  function writeFakeGh({ failReply = false, prNumber = 9, prOwner = 'o', prRepo = 'r' } = {}) {
    const bin = join(dir, 'bin');
    mkdirSync(bin, { recursive: true });
    log = join(dir, 'gh.log');
    const onReply = failReply ? "echo 'reply refused' >&2; exit 1" : "echo '{}'";
    const pr = `{"data":{"node":{"pullRequest":{"number":${prNumber},"repository":{"name":"${prRepo}","owner":{"login":"${prOwner}"}}}}}}`;
    writeFileSync(
      join(bin, 'gh'),
      `#!/bin/sh\nprintf '%s\\n' "$*" >> '${log}'\ncase "$*" in *thread-pr.gql*) echo '${pr}' ;; *reply-thread.gql*) ${onReply} ;; *) echo '{}' ;; esac\n`,
      { mode: 0o755 },
    );
    return cacheEnv({ PATH: `${bin}:${process.env.PATH}`, FORGE: 'github' });
  }
  function calls() {
    try {
      return readFileSync(log, 'utf8').trim().split('\n').filter(Boolean);
    } catch {
      return [];
    }
  }
  function run(extra, env) {
    return spawnSync(
      process.execPath,
      [RESOLVE_CLI, '--owner', 'o', '--repo', 'r', '--number', '9', '--thread-id', 'PRRT_x', ...extra],
      { env, cwd: dir, encoding: 'utf8' },
    );
  }

  it('refuses a resolve with no --reason: exit 2, no gh call', () => {
    const res = run([], writeFakeGh());
    expect(res.status).toBe(2);
    expect(res.stderr).toMatch(/--reason/);
    expect(calls()).toEqual([]);
  });

  it.each(['fixed', 'fixed xyz', 'followup 123', 'followup', 'rejected', 'rejected  ', 'done'])(
    'refuses a malformed reason %j: exit 2, no gh call',
    (reason) => {
      const res = run(['--reason', reason], writeFakeGh());
      expect(res.status).toBe(2);
      expect(res.stderr).toMatch(/reason must be/);
      expect(calls()).toEqual([]);
    },
  );

  it.each([
    ['fixed 0d4ad5b8', 'Fixed at 0d4ad5b8.'],
    ['followup HIMMEL-6394', 'Follow-up: HIMMEL-6394.'],
    ['rejected the guard already covers it', 'Rejected: the guard already covers it.'],
  ])('reason %j posts reply %j, then resolves', (reason, body) => {
    const res = run(['--reason', reason], writeFakeGh());
    expect(res.status).toBe(0);
    expect(res.stdout).toMatch(/resolved: ok/);
    const c = calls();
    expect(c).toHaveLength(3);
    expect(c[0]).toMatch(/thread-pr\.gql/);
    expect(c[1]).toMatch(/reply-thread\.gql/);
    expect(c[1]).toContain(`body=${body}`);
    expect(c[1]).toContain('threadId=PRRT_x');
    expect(c[2]).toMatch(/resolve-thread\.gql/);
  });

  it('does not resolve when the reply fails', () => {
    const res = run(['--reason', 'fixed 0d4ad5b8'], writeFakeGh({ failReply: true }));
    expect(res.status).not.toBe(0);
    expect(res.stderr).toMatch(/reply refused/);
    const c = calls();
    expect(c).toHaveLength(2);
    expect(c[1]).toMatch(/reply-thread\.gql/);
  });

  it('refuses a thread id that sits on another PR: exit 2, no reply, no resolve', () => {
    const res = run(['--reason', 'fixed 0d4ad5b8'], writeFakeGh({ prNumber: 8 }));
    expect(res.status).toBe(2);
    expect(res.stderr).toMatch(/is not on o\/r#9/);
    const c = calls();
    expect(c).toHaveLength(1);
    expect(c[0]).toMatch(/thread-pr\.gql/);
  });

  it.each([
    ['owner', { prOwner: 'other' }],
    ['repo', { prRepo: 'other' }],
  ])('refuses a thread id on a PR with a foreign %s: exit 2, no reply, no resolve', (_what, pr) => {
    const res = run(['--reason', 'fixed 0d4ad5b8'], writeFakeGh(pr));
    expect(res.status).toBe(2);
    expect(res.stderr).toMatch(/is not on o\/r#9/);
    const c = calls();
    expect(c).toHaveLength(1);
    expect(c[0]).toMatch(/thread-pr\.gql/);
  });
});
