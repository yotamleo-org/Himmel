import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import { cpSync, existsSync, mkdirSync, readFileSync, realpathSync, symlinkSync, writeFileSync, utimesSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { makeTmpDir } from '../../lib/test-tmpdir.mjs';
import { main, readPRBatch, readPRs, runCLI } from '../collect.mjs';
import { appendRecords } from '../lib/append.mjs';
import { prRecords } from '../lib/collect.mjs';
import { readRecords } from '../lib/ledger.mjs';
import { fold } from '../lib/fold.mjs';
import { main as dock } from '../dock.mjs';

const root = resolve(import.meta.dirname, '../../..');
const REPO = 'example/project';
const which = (name) => spawnSync('sh', ['-c', `command -v ${name}`], { encoding: 'utf8' }).stdout.trim();
const script = (path, body) => writeFileSync(path, `#!/bin/sh\n${body}\n`, { mode: 0o755 });

function scratchRepo(dir) {
  const repo = join(dir, 'repo');
  mkdirSync(join(repo, 'scripts/lib'), { recursive: true });
  cpSync(join(root, 'scripts/where-are-we'), join(repo, 'scripts/where-are-we'), { recursive: true });
  cpSync(join(root, 'scripts/lib/is-main.mjs'), join(repo, 'scripts/lib/is-main.mjs'));
  spawnSync('git', ['-C', repo, 'init', '-q', '-b', 'main']);
  spawnSync('git', ['-C', repo, 'remote', 'add', 'origin', `https://github.com/${REPO}.git`]);
  return repo;
}

test('a collector started in another repository folder never writes that repository\'s PR over this one\'s', () => {
  const dir = makeTmpDir('waw-cross-repo-'), repo = scratchRepo(dir), other = join(dir, 'other'), bin = join(dir, 'bin');
  const state = join(dir, 'state'), ledger = join(state, 'ledger.jsonl'), calls = join(dir, 'calls.log');
  mkdirSync(other); mkdirSync(bin); mkdirSync(state);
  spawnSync('git', ['-C', other, 'init', '-q', '-b', 'main']);
  const pr = (state, branch, extra = {}) => JSON.stringify([{ number: 42, state, headRefName: branch, title: 'this repo PR', mergeable: 'MERGEABLE', mergeStateStatus: 'CLEAN',
    statusCheckRollup: [{ status: 'COMPLETED', conclusion: 'SUCCESS' }], ...extra }]);
  script(join(bin, 'gh'), `echo "gh $*" >> '${calls}'\ncase "$*" in *'-R ${REPO}'*) echo '${pr('OPEN', 'himmel-real-branch')}';; *) echo '${pr('MERGED', 'other-project-branch')}';; esac`);
  script(join(bin, 'git'), `echo "git $*" >> '${calls}'\nexec ${which('git')} "$@"`);
  writeFileSync(ledger, JSON.stringify({ ts: '2026-11-18T00:00:00.000Z', source: 'pr', key: '#42', kind: 'pr', status: 'open', branch: 'himmel-real-branch', awaiting_operator: ['green + mergeable: this repo PR'] }) + '\n');
  const result = spawnSync(process.execPath, [join(repo, 'scripts/where-are-we/collect.mjs'), '--ledger', ledger], {
    cwd: other, env: { ...process.env, PATH: `${bin}:/usr/bin:/bin` }, encoding: 'utf8', timeout: 20000,
  });
  const item = fold(readRecords(ledger)).items['#42'];
  assert.equal(item.status, 'open', result.stderr);
  assert.equal(item.branch, 'himmel-real-branch');
  assert.deepEqual(item.awaiting_operator, ['green + mergeable: this repo PR']);
  const log = readFileSync(calls, 'utf8').trim().split('\n');
  const gh = log.filter((l) => l.startsWith('gh '));
  assert.ok(gh.length >= 2, 'the collector read PRs through gh');
  for (const line of gh.filter((l) => l.startsWith('gh pr '))) assert.match(line, /-R example\/project/, line);
  const worktree = log.find((l) => l.includes('worktree list'));
  assert.ok(worktree?.startsWith(`git -C ${realpathSync(repo)} worktree list`), `worktree list names the repository root: ${worktree}`);
});

test('readPRBatch names its repository and refuses to run without one', () => {
  const seen = [];
  readPRBatch([1], (_command, args) => { seen.push(args); return JSON.stringify({ data: { repository: { p1: { number: 1, state: 'MERGED', headRefName: 'x' } } } }); }, REPO);
  assert.equal(seen.length, 1);
  assert.ok(seen[0].includes('owner=example') && seen[0].includes('name=project'));
  assert.throws(() => readPRBatch([1], () => '{}'), /explicit owner\/name repository/);
});

const partial = (errors, rollup) => (_command, _args) => {
  const body = { data: { repository: { p7: { number: 7, state: 'OPEN', headRefName: 'b', title: 'T', mergeable: 'MERGEABLE', mergeStateStatus: 'CLEAN',
    commits: { nodes: [{ commit: { statusCheckRollup: rollup } }] } } } }, errors };
  if (!errors) return JSON.stringify(body);
  throw Object.assign(new Error('gh exit 1'), { status: 1, stdout: JSON.stringify(body) });
};

test('a partial answer with a null rollup loses mergeable state and writes no empty operator list', () => {
  const result = readPRBatch([7], partial([{ message: 'Resource limit on statusCheckRollup', path: ['repository', 'p7', 'commits', 'nodes', 0, 'commit', 'statusCheckRollup'] }], null), REPO);
  assert.equal(result.rows[0].mergeable, undefined);
  assert.ok(result.error_count > 0);
  assert.ok(!('awaiting_operator' in prRecords(result.rows, '2026-11-19T00:00:00Z')[0]), 'the prior obligation is preserved, not emptied');
  const unlocated = readPRBatch([7], partial([{ message: 'upstream hiccup' }], null), REPO);
  assert.equal(unlocated.rows[0].mergeable, undefined, 'an error with no path makes every PR in the answer unknown');
});

test('a clean answer still reads its checks (control)', () => {
  const green = { contexts: { nodes: [{ status: 'COMPLETED', conclusion: 'SUCCESS' }], pageInfo: { hasNextPage: false } } };
  const result = readPRBatch([7], partial(undefined, green), REPO);
  assert.equal(result.error_count, 0);
  assert.deepEqual(prRecords(result.rows, '2026-11-19T00:00:00Z')[0].awaiting_operator, ['green + mergeable: T']);
});

function ghListStub(dir, openCount) {
  const bin = join(dir, 'bin'); mkdirSync(bin);
  const pr = (number, state) => ({ number, state, headRefName: `b${number}`, title: `t${number}` });
  const merged = JSON.stringify(Array.from({ length: 100 }, (_, i) => pr(500 + i, 'MERGED')));
  const open = JSON.stringify(Array.from({ length: openCount }, (_, i) => pr(3 + i, 'OPEN')));
  writeFileSync(join(dir, 'merged.json'), merged); writeFileSync(join(dir, 'open.json'), open);
  script(join(bin, 'gh'), `case "$*" in *'--state open'*) cat '${join(dir, 'open.json')}';; *) cat '${join(dir, 'merged.json')}';; esac`);
  return bin;
}
const withPath = (path, fn) => { const saved = process.env.PATH; process.env.PATH = path; try { return fn(); } finally { process.env.PATH = saved; } };

test('an open PR older than the newest hundred is read by the open-only query', () => {
  const dir = makeTmpDir('waw-open-pr-'), bin = ghListStub(dir, 1);
  const result = withPath(`${bin}:/usr/bin:/bin`, () => readPRs([], { repo: REPO }));
  assert.equal(result.error_count, 0, result.errors.join('; '));
  assert.equal(result.rows.find((r) => r.number === 3)?.state, 'OPEN');
  assert.equal(result.rows.filter((r) => r.state === 'MERGED').length, 100);
});

test('an open read that reaches its limit marks the source incomplete and the marker does not advance', () => {
  const dir = makeTmpDir('waw-open-pr-'), bin = ghListStub(dir, 1000), ledger = join(dir, 'ledger.jsonl'), marker = join(dir, '.refreshed-at');
  writeFileSync(ledger, '');
  const readers = { readJira: () => [], readWorktrees: () => '', readPRs: (active) => readPRs(active, { repo: REPO }) };
  assert.throws(() => withPath(`${bin}:/usr/bin:/bin`, () => main(['--ledger', ledger, '--marker', marker], { readers, strict: true })), /collection incomplete/);
  assert.equal(existsSync(marker), false);
  assert.match(fold(readRecords(ledger)).sources.pr.errors.join(' '), /reached its limit/);
});

test('a writer killed inside the append leaves no lock and the next append succeeds at once', async () => {
  const dir = makeTmpDir('waw-killed-writer-'), ledger = join(dir, 'ledger.jsonl'), code = join(dir, 'kill.mjs');
  writeFileSync(code, `import { acquireLock } from ${JSON.stringify(join(root, 'scripts/where-are-we/lib/append.mjs'))};
    acquireLock(process.argv[2]); process.kill(process.pid, 'SIGKILL');`);
  const child = spawn(process.execPath, [code, ledger], { stdio: 'ignore' });
  const [, signal] = await once(child, 'close');
  assert.equal(signal, 'SIGKILL');
  assert.equal(existsSync(ledger + '.lock'), false, 'no directory lock');
  const began = Date.now();
  const rec = { ts: '2026-11-24T00:00:00Z', source: 'jira', key: 'HIMMEL-1', kind: 'ticket' };
  assert.equal(appendRecords(ledger, [rec], { timeoutMs: 1000 }).appended, 1);
  assert.ok(Date.now() - began < 1000);
  assert.equal(existsSync(ledger + '.lock'), false);
});

for (const fallback of ['perl', 'python3']) {
  const timeout = which('timeout'), helper = which(fallback);
  test(`a PATH holding only gtimeout and ${fallback} (no flock) still runs the collector`, { skip: timeout && helper ? false : `needs timeout and ${fallback} installed` }, () => {
    const dir = makeTmpDir('waw-gtimeout-'), bin = join(dir, 'bin'), ledger = join(dir, 'ledger.jsonl');
    mkdirSync(bin); writeFileSync(ledger, '');
    symlinkSync(timeout, join(bin, 'gtimeout')); symlinkSync(helper, join(bin, fallback));
    script(join(bin, 'gh'), 'echo "[]"');
    script(join(bin, 'git'), 'case "$*" in *"remote get-url"*) echo https://github.com/example/project.git;; esac');
    const saved = process.env.PATH;
    let result;
    try { process.env.PATH = bin; result = runCLI(['--ledger', ledger]); } finally { process.env.PATH = saved; }
    assert.doesNotMatch(result.stderr, /lock unavailable|ENOENT/);
    const sources = fold(readRecords(ledger)).sources;
    assert.ok(sources.pr.observed_at, `pr source read: ${result.stderr}`);
    assert.ok(sources.git.observed_at, 'git source read');
  });
}

test('a refresh marker with no ledger reads freshness unknown and stale; no marker reads as before', () => {
  const dir = makeTmpDir('waw-no-ledger-'), ledger = join(dir, 'ledger.jsonl'), marker = join(dir, '.refreshed-at');
  const none = dock(['--ledger', ledger, '--marker', marker]);
  assert.equal(none.stale, true);
  assert.match(none.text, /never refreshed/);
  writeFileSync(marker, 'x');
  const lost = dock(['--ledger', ledger, '--marker', marker]);
  assert.equal(lost.stale, true);
  assert.match(lost.text, /freshness unknown/);
  assert.doesNotMatch(lost.text, /refreshed \d+h ago/);
  writeFileSync(ledger, '');
  utimesSync(marker, new Date(), new Date());
  const fresh = dock(['--ledger', ledger, '--marker', marker]);
  assert.equal(fresh.stale, false);
  assert.match(fresh.text, /refreshed 0h ago/);
});
