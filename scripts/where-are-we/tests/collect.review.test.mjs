import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import { cpSync, existsSync, mkdirSync, readFileSync, realpathSync, symlinkSync, writeFileSync, statSync, utimesSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { makeTmpDir } from '../../lib/test-tmpdir.mjs';
import { main, readJira, readPRBatch, runCLI } from '../collect.mjs';
import { readRecords } from '../lib/ledger.mjs';
import { fold, inFlight } from '../lib/fold.mjs';
import { renderDock } from '../lib/dock.mjs';
import { main as dock } from '../dock.mjs';
import { DEFAULT_JOB_TIMEOUT_MS } from '../../hooks/stop-queue.mjs';

const root = resolve(import.meta.dirname, '../../..');
const ORIGIN_GIT = '#!/bin/sh\ncase "$*" in *"remote get-url"*) echo https://github.com/example/project.git; exit 0;; esac\n';
const waitFor = async (fn) => {
  const deadline = Date.now() + 4000;
  while (!fn() && Date.now() < deadline) await new Promise((ok) => setTimeout(ok, 20));
  assert.ok(fn(), 'fixture child did not finish');
};

test('real Stop hook cannot certify a partial collector exit as successful freshness', async () => {
  const dir = makeTmpDir('waw-stop-review-'), repo = join(dir, 'repo'), state = join(dir, 'state'), bin = join(dir, 'bin');
  mkdirSync(join(repo, 'scripts/lib'), { recursive: true }); mkdirSync(state); mkdirSync(bin);
  cpSync(join(root, 'scripts/where-are-we'), join(repo, 'scripts/where-are-we'), { recursive: true });
  cpSync(join(root, 'scripts/lib/is-main.mjs'), join(repo, 'scripts/lib/is-main.mjs'));
  for (const command of ['git', 'gh']) writeFileSync(join(bin, command), '#!/bin/sh\nexit 1\n', { mode: 0o755 });
  const ledger = join(state, 'ledger.jsonl'), marker = join(state, '.refreshed-at');
  writeFileSync(ledger, JSON.stringify({ ts: '2026-01-01T00:00:00Z', source: 'jira', kind: 'ticket', key: 'HIMMEL-1', status: 'in-progress' }) + '\n');
  const result = spawnSync('bash', [join(root, 'scripts/hooks/refresh-where-are-we-on-end.sh'), '__himmel_detached'], {
    env: { ...process.env, HIMMEL_REPO: repo, WHERE_ARE_WE_STATE_DIR: state, HIMMEL_WHERE_ARE_WE: '1',
      HIMMEL_WHERE_ARE_WE_COLLECT_CMD: '', PATH: `${bin}:/usr/bin:/bin` }, encoding: 'utf8', timeout: 5000,
  });
  assert.equal(result.status, 1); // queued child reports collection failure after evidence
  await waitFor(() => readFileSync(ledger, 'utf8').includes('@collect:jira'));
  await new Promise((ok) => setTimeout(ok, 150));
  assert.equal(existsSync(marker), false, 'partial/error evidence must not advance the success marker');
  assert.match(readFileSync(ledger, 'utf8'), /in-progress/);
  const cli = spawnSync(process.execPath, [join(repo, 'scripts/where-are-we/collect.mjs'), '--ledger', ledger, '--marker', marker], {
    env: { ...process.env, PATH: `${bin}:/usr/bin:/bin` }, encoding: 'utf8', timeout: 3000,
  });
  assert.equal(cli.status, 1, 'production CLI must report incomplete collection after persisting evidence');
  assert.ok(cli.stderr.length < 1000);
});

test('outage diagnostics over 1700 identities are bounded, counted and retain last-good observations', () => {
  const dir = makeTmpDir('waw-error-review-'), ledger = join(dir, 'ledger.jsonl');
  const prior = Array.from({ length: 1701 }, (_, i) => ({ ts: '2026-01-01T00:00:00Z', source: 'jira', kind: 'ticket', key: `HIMMEL-${i + 1}`, status: 'in-progress' }));
  writeFileSync(ledger, prior.map(JSON.stringify).join('\n') + '\n');
  const error = Object.assign(new Error('Command failed: node -e SECRET_SCRIPT ' + 'huge stderr '.repeat(50000)), { status: 1, stderr: 'secret token=private' });
  main(['--ledger', ledger], { readers: { readJira: () => { throw error; }, readPRs: () => [], readWorktrees: () => '' } });
  const state = fold(readRecords(ledger)), health = state.sources.jira;
  assert.equal(inFlight(state).length, 1701);
  assert.ok(health.errors.length <= 8);
  assert.ok(JSON.stringify(health.errors).length <= 1600);
  assert.ok(health.error_count >= 1702);
  assert.doesNotMatch(JSON.stringify(health), /SECRET_SCRIPT|private/);
});

test('old oversized collection errors cannot make injected context unbounded', () => {
  const text = renderDock([{ ts: '2026-01-01T00:00:00Z', kind: 'collection', key: '@collect:jira', source: 'jira', errors: Array(2000).fill('bad '.repeat(1000)) }], { mode: 'global' }, Date.now(), null);
  assert.ok(text.length <= 16000, `context has ${text.length} characters`);
  assert.match(text, /2000|omitted|truncated/);
  const broken = dock(['--ledger', '/fixture'], { statMtime: () => null, readRecords: () => { throw new Error('broken'); }, now: Date.now() });
  assert.equal(broken.stale, true);
  assert.match(broken.text, /ledger.*unread|ledger.*malformed/i);
});

test('identity-specific Jira failure isolates one bad key and refreshes valid peers', () => {
  const keys = Array.from({ length: 6 }, (_, i) => `HIMMEL-${i + 1}`), calls = [];
  const result = readJira(keys, { readPage: (r) => {
    calls.push(r);
    if (!r.jql) return { issues: [] };
    const batch = r.jql.match(/HIMMEL-\d+/g);
    if (batch.includes(keys[2])) throw Object.assign(new Error('identity query rejected'), { httpStatus: 400, identityFailure: true });
    return { issues: batch.map((key) => ({ key, fields: { status: { name: 'Done', statusCategory: { key: 'done' } } } })) };
  } });
  assert.deepEqual(result.rows.map((r) => r.key).sort(), keys.filter((k) => k !== keys[2]));
  assert.ok(result.errors.length);
  assert.ok(calls.length <= 20);
});

test('network failures do not bisect key batches and the whole pass has a request/deadline bound', () => {
  let calls = 0;
  readJira(['HIMMEL-1', 'HIMMEL-2'], { readPage: () => { calls++; throw Object.assign(new Error('network timeout'), { code: 'ETIMEDOUT' }); } });
  assert.equal(calls, 2);
  calls = 0;
  readJira(Array.from({ length: 1701 }, (_, i) => `HIMMEL-${i + 1}`), { maxRequests: 6, readPage: () => {
    calls++;
    return { issues: [], nextPageToken: calls % 5 ? String(calls) : undefined };
  } });
  assert.ok(calls <= 6, `${calls} requests exceeded total bound`);
  let clock = 0; calls = 0;
  readJira(['HIMMEL-1'], { deadlineMs: 10, clock: () => clock, readPage: () => { calls++; clock += 6; return { issues: [], nextPageToken: String(calls) }; } });
  assert.ok(calls <= 2, `${calls} requests exceeded total deadline`);
});

test('all collector writers refuse concurrent reads and recover automatically after owner death', async () => {
  const dir = makeTmpDir('waw-flight-review-'), ledger = join(dir, 'ledger.jsonl'), starts = join(dir, 'starts'), script = join(dir, 'run.mjs');
  writeFileSync(ledger, '');
  writeFileSync(ledger + '.collect.lock', String(process.pid) + '\n');
  utimesSync(ledger + '.collect.lock', 1, 1); // stale bytes/age are not kernel ownership
  writeFileSync(script, `import { main } from ${JSON.stringify(join(root, 'scripts/where-are-we/collect.mjs'))};
    import { appendFileSync } from 'node:fs';
    main(['--ledger', process.argv[2]], { strict:true, readers: { readPRs: () => { appendFileSync(process.argv[3], 'start\\n'); Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,Number(process.argv[4])); return []; }, readJira:()=>[], readWorktrees:()=>'' } });`);
  const first = spawn(process.execPath, [script, ledger, starts, '1500'], { stdio: 'ignore' });
  const closed = once(first, 'close');
  try {
    await waitFor(() => existsSync(starts));
    const second = spawnSync(process.execPath, [script, ledger, starts, '0'], { encoding: 'utf8', timeout: 3000 });
    assert.notEqual(second.status, 0);
    assert.equal(readFileSync(starts, 'utf8').trim(), 'start', 'second collector launched source reads');
  } finally { first.kill('SIGKILL'); await closed; }
  assert.match(fold(readRecords(ledger)).sources.jira.errors.join(' '), /pending or interrupted/);
  const next = spawnSync(process.execPath, [script, ledger, starts, '0'], { encoding: 'utf8', timeout: 3000 });
  assert.equal(next.status, 0, next.stderr);
});

test('the CLI refuses while another process holds the collection flock', async () => {
  const dir = makeTmpDir('waw-flock-review-'), ledger = join(dir, 'ledger.jsonl');
  writeFileSync(ledger, '');
  const lock = join(realpathSync(dir), 'ledger.jsonl.collect.lock');
  // The holder keeps descriptor 9 (and so the flock) until it is killed; it waits, because the probe below also takes the lock for an instant.
  const holder = spawn('sh', ['-c', 'exec 9>"$0" && flock -w 5 9 && exec sleep 30', lock], { stdio: 'ignore' }), closed = once(holder, 'close');
  try {
    await waitFor(() => spawnSync('flock', ['-n', lock, 'true']).status === 1);
    const held = runCLI(['--ledger', ledger]);
    assert.equal(held.status, 1);
    assert.match(held.stderr, /collector already running; freshness unchanged/);
    assert.equal(readFileSync(ledger, 'utf8'), '', 'a refused collector appends nothing');
  } finally { holder.kill('SIGKILL'); await closed; }
});

const timeoutBin = spawnSync('sh', ['-c', 'command -v timeout'], { encoding: 'utf8' }).stdout.trim();
test('the CLI names a missing flock instead of collecting without the lock', { skip: timeoutBin ? false : 'timeout is not on PATH, so the CLI cannot start without flock either' }, () => {
  const dir = makeTmpDir('waw-noflock-review-'), ledger = join(dir, 'ledger.jsonl'), bin = join(dir, 'bin');
  writeFileSync(ledger, '');
  // A PATH with only `timeout` on it: the CLI starts, and flock cannot.
  mkdirSync(bin); symlinkSync(timeoutBin, join(bin, 'timeout'));
  const saved = process.env.PATH;
  try {
    process.env.PATH = bin;
    const missing = runCLI(['--ledger', ledger]);
    assert.equal(missing.status, 1);
    assert.match(missing.stderr, /collector lock unavailable; local flock support is required/);
    assert.equal(readFileSync(ledger, 'utf8'), '', 'a refused collector appends nothing');
  } finally { process.env.PATH = saved; }
});

test('real Jira client bridge only splits structured identity errors, not transport failures', () => {
  const dir = makeTmpDir('waw-bridge-review-'), bin = join(dir, 'bin'), repo = join(dir, 'repo');
  mkdirSync(bin); mkdirSync(join(repo, 'scripts/jira/dist'), { recursive: true });
  writeFileSync(join(bin, 'git'), `#!/bin/sh\nprintf '%s\\n' '${repo}/.git'\n`, { mode: 0o755 });
  writeFileSync(join(repo, 'scripts/jira/dist/client.js'), `export const projectKey=()=> 'HIMMEL'; export async function request(method,path) {
    const jql = new URL('https://fixture.invalid' + path).searchParams.get('jql');
    if (!jql.startsWith('key in')) return {issues:[]};
    const keys = jql.match(/HIMMEL-\\d+/g);
    if (keys.includes('HIMMEL-2')) throw new Error('HTTP 400: The value HIMMEL-2 does not exist for the field key');
    return {issues: keys.map(key=>({key,fields:{status:{name:'Done',statusCategory:{key:'done'}}}}))};
  }`);
  const saved = process.env.PATH;
  try {
    process.env.PATH = `${bin}:${saved}`;
    const result = readJira(['HIMMEL-1', 'HIMMEL-2', 'HIMMEL-3']);
    assert.deepEqual(result.rows.map((r) => r.key), ['HIMMEL-1', 'HIMMEL-3']);
    assert.equal(result.errors.length, 1);
    assert.match(result.errors[0], /HTTP 400/);
  } finally { process.env.PATH = saved; }
});

test('production subprocesses obey the total deadline and a dead owner cannot leave an unbounded reader', async () => {
  const dir = makeTmpDir('waw-deadline-review-'), bin = join(dir, 'bin'), ledger = join(dir, 'ledger.jsonl'), script = join(dir, 'run.mjs'), started = join(dir, 'started');
  mkdirSync(bin); writeFileSync(ledger, '');
  writeFileSync(join(bin, 'gh'), `#!/bin/sh\ntouch '${started}'\nsleep 5\nexit 1\n`, { mode: 0o755 });
  writeFileSync(join(bin, 'git'), ORIGIN_GIT + 'exit 1\n', { mode: 0o755 });
  writeFileSync(script, `import { main } from ${JSON.stringify(join(root, 'scripts/where-are-we/collect.mjs'))};
    main(['--ledger', process.argv[2]], {strict:true, deadlineMs: Number(process.argv[3])});`);
  const env = { ...process.env, PATH: `${bin}:/usr/bin:/bin` };
  const began = Date.now();
  const bounded = spawnSync(process.execPath, [script, ledger, '100'], { env, encoding: 'utf8', timeout: 2000 });
  assert.equal(bounded.status, 1);
  assert.ok(Date.now() - began < 1500);
  assert.ok(fold(readRecords(ledger)).sources.pr.error_count > 0);
  assert.match(fold(readRecords(ledger)).sources.pr.errors.join(' '), /deadline|timed out/);
  // A new source-read sentinel belongs to this acquisition.
  const mtime = statSync(started).mtimeMs;
  const owner = spawn(process.execPath, [script, ledger, '600'], { env, stdio: 'ignore' }), closed = once(owner, 'close');
  await waitFor(() => statSync(started).mtimeMs > mtime);
  owner.kill('SIGKILL'); await closed;
  const quiet = `import {main} from ${JSON.stringify(join(root, 'scripts/where-are-we/collect.mjs'))}; main(['--ledger',process.argv[1]],{readers:{readJira:()=>[],readPRs:()=>[],readWorktrees:()=>''}});`;
  const second = spawnSync(process.execPath, ['--input-type=module', '-e', quiet, ledger], { encoding: 'utf8' });
  assert.notEqual(second.status, 0, 'bounded orphan must retain exclusion until its watchdog stops it');
  await waitFor(() => {
    const next = spawnSync(process.execPath, ['--input-type=module', '-e', quiet, ledger], { encoding: 'utf8' });
    return next.status === 0;
  });
});

for (const hook of ['refresh-where-are-we-on-end.sh', 'inject-where-are-we.sh']) {
  for (const mode of ['success', 'partial', 'failure', 'drop', 'write-interrupted']) {
    test(`${hook}: real collector ${mode} preserves marker and last-good state correctly`, { skip: mode === 'write-interrupted' && process.getuid?.() === 0 ? 'root ignores file modes' : false }, async () => {
      const dir = makeTmpDir('waw-hook-matrix-'), repo = join(dir, 'repo'), state = join(dir, 'state'), script = join(dir, 'fixture.mjs'), done = join(dir, 'done');
      mkdirSync(join(repo, 'scripts/lib'), { recursive: true }); mkdirSync(state);
      cpSync(join(root, 'scripts/where-are-we'), join(repo, 'scripts/where-are-we'), { recursive: true });
      cpSync(join(root, 'scripts/lib/is-main.mjs'), join(repo, 'scripts/lib/is-main.mjs'));
      const ledger = join(state, 'ledger.jsonl'), marker = join(state, '.refreshed-at');
      writeFileSync(ledger, JSON.stringify({ ts: '2026-01-01T00:00:00Z', source: 'jira', kind: 'ticket', key: 'HIMMEL-1', status: 'in-progress' }) + '\n');
      writeFileSync(marker, 'old'); utimesSync(marker, 1000, 1000);
      writeFileSync(script, `import {main} from ${JSON.stringify(join(root, 'scripts/where-are-we/collect.mjs'))};
        import {chmodSync,writeFileSync} from 'node:fs';
        const ledger=${JSON.stringify(ledger)}, mode=${JSON.stringify(mode)};
        try { main(['--ledger',ledger,'--marker',${JSON.stringify(marker)}], {strict:true, readers:{readPRs:()=>[], readWorktrees:()=>'', readJira:()=>{
          if(mode==='failure') throw new Error('source unavailable');
          if(mode==='partial') return {rows:[],errors:['partial source']};
          if(mode==='write-interrupted') chmodSync(ledger, 0o400);
          return [{key: mode==='drop'?'':'HIMMEL-1',status:'Done',statusCategory:'Done'}];
        }}}); } catch { process.exitCode=1; } finally {writeFileSync(${JSON.stringify(done)}, 'done');}`);
      const result = spawnSync('bash', [join(root, 'scripts/hooks', hook), ...(hook.startsWith('refresh') ? ['__himmel_detached'] : [])], {
        env: { ...process.env, HIMMEL_REPO: repo, HIMMEL_WHERE_ARE_WE: '1', WHERE_ARE_WE_STATE_DIR: state, WHERE_ARE_WE_BRANCH_OVERRIDE: 'main',
          HIMMEL_WHERE_ARE_WE_COLLECT_CMD: `${JSON.stringify(process.execPath)} ${JSON.stringify(script)}` }, input: '', encoding: 'utf8', timeout: 4000,
      });
      assert.equal(result.status, hook.startsWith('refresh') && mode !== 'success' ? 1 : 0, result.stderr);
      await waitFor(() => existsSync(done));
      if (mode === 'success') assert.ok(statSync(marker).mtimeMs > 1000000);
      else {
        assert.equal(statSync(marker).mtimeMs, 1000000);
        assert.equal(fold(readRecords(ledger)).items['HIMMEL-1'].status, 'in-progress');
      }
    });
  }
}

test('a successful older attempt cannot regress the marker; corrupt ledgers start no source reads', () => {
  const dir = makeTmpDir('waw-marker-order-'), ledger = join(dir, 'ledger.jsonl'), marker = join(dir, '.refreshed-at');
  writeFileSync(ledger, '');
  const readers = { readJira: () => [], readPRs: () => [], readWorktrees: () => '' };
  main(['--ledger', ledger, '--marker', marker, '--now', '2026-11-17T00:00:00Z'], { readers, strict: true });
  const previous = statSync(marker).mtimeMs;
  main(['--ledger', ledger, '--marker', marker, '--now', '2026-11-16T00:00:00Z'], { readers, strict: true });
  assert.equal(statSync(marker).mtimeMs, previous);
  for (const text of ['{broken\n', '{}\n', 'null\n', JSON.stringify({ts:'2026-01-01T00:00:00Z',kind:'collection',key:'@collect:jira',source:'jira',errors:'broken'})+'\n']) {
    writeFileSync(ledger, text);
    let calls = 0;
    assert.throws(() => main(['--ledger', ledger, '--marker', marker], { strict: true, readers: { ...readers, readJira: () => { calls++; return []; } } }));
    assert.equal(calls, 0);
    assert.equal(statSync(marker).mtimeMs, previous);
    assert.match(dock(['--ledger', ledger]).text, /ledger unread or malformed/);
  }
});

test('GitHub partial GraphQL transport failure preserves valid peers and leaves missing PR unknown', () => {
  const result = readPRBatch([1, 2], (_command, args) => {
    throw Object.assign(new Error('gh GraphQL failed'), { status: 1, stdout: JSON.stringify({
      errors: [{ message: 'pull request could not be resolved' }],
      data: { repository: { p1: { number: 1, state: 'MERGED', headRefName: 'feat/x' }, p2: null } },
    }) });
  }, 'fixture/repo');
  assert.deepEqual(result.rows.map((r) => r.number), [1]);
  assert.equal(result.rows[0].state, 'MERGED');
  assert.match(result.errors.join(' '), /missing PR #2/);
});

test('normal collector outer deadline stays below the actual Stop queue timeout', () => {
  const dir = makeTmpDir('waw-default-deadline-'), bin = join(dir, 'bin'), recorded = join(dir, 'deadline');
  mkdirSync(bin);
  writeFileSync(join(bin, 'timeout'), `#!/bin/sh\nprintf '%s' "$3" > '${recorded}'\n`, { mode: 0o755 });
  const saved = process.env.PATH;
  try {
    process.env.PATH = `${bin}:${saved}`;
    runCLI(['--ledger', join(dir, 'ledger.jsonl')]);
  } finally { process.env.PATH = saved; }
  const ms = Number(readFileSync(recorded, 'utf8').replace(/s$/, '')) * 1000;
  assert.ok(ms < DEFAULT_JOB_TIMEOUT_MS, `${ms}ms collector outer exceeds ${DEFAULT_JOB_TIMEOUT_MS}ms queue budget`);
  assert.equal(ms, 90000);
});

for (const deadlineMs of [2400, 1200.5]) test(`earlier successful rows survive a hung later source before outer ${deadlineMs}ms`, () => {
  const dir = makeTmpDir('waw-persist-headroom-'), bin = join(dir, 'bin'), ledger = join(dir, 'ledger.jsonl'), marker = join(dir, '.refreshed-at');
  mkdirSync(bin);
  writeFileSync(ledger, [
    { ts: '2026-01-01T00:00:00Z', source: 'jira', kind: 'ticket', key: 'HIMMEL-1', status: 'in-progress' },
    { ts: '2026-01-01T00:00:00Z', source: 'pr', kind: 'pr', key: '#7', status: 'open', awaiting_operator: ['merge'] },
  ].map(JSON.stringify).join('\n') + '\n');
  writeFileSync(marker, 'last good'); utimesSync(marker, 1000, 1000);
  writeFileSync(join(bin, 'gh'), '#!/bin/sh\nprintf \'%s\\n\' \'[{"number":7,"state":"MERGED","headRefName":"feat/x"}]\'\n', { mode: 0o755 });
  writeFileSync(join(bin, 'git'), ORIGIN_GIT + 'trap "" TERM\nsleep 5\n', { mode: 0o755 });
  const saved = process.env.PATH, began = Date.now();
  let result;
  try {
    process.env.PATH = `${bin}:/usr/bin:/bin`;
    result = runCLI(['--ledger', ledger, '--marker', marker], { deadlineMs });
  } finally { process.env.PATH = saved; }
  const state = fold(readRecords(ledger));
  assert.equal(state.items['#7'].status, 'merged', 'outer watchdog discarded an earlier successful source');
  assert.equal(state.items['HIMMEL-1'].status, 'in-progress');
  assert.equal(state.awaiting_operator.length, 0);
  assert.match(state.sources.git.errors.join(' '), /deadline|timed out/);
  assert.doesNotMatch(state.sources.git.errors.join(' '), /pending or interrupted/);
  assert.equal(statSync(marker).mtimeMs, 1000000);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /evidence persisted/);
  assert.ok(Date.now() - began < deadlineMs, 'normal partial result should finish before its outer watchdog');
});
