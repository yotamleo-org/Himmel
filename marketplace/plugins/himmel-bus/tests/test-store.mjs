import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, readFile, chmod, symlink, mkdir, rm, readdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import * as primitive from '../../../../scripts/telegram/bus.ts';
import fs from 'node:fs/promises';
import { syncBuiltinESMExports } from 'node:module';

const storeUrl = new URL('../lib/store.mjs', import.meta.url);
async function fixture(t) {
  const state = await mkdtemp(join(tmpdir(), 'bus-store-'));
  t.after(() => rm(state, { recursive: true, force: true }));
  const store = await import(storeUrl);
  const root = await store.busRoot({ stateHome: state });
  return { store, root, state };
}
const message = (b = 'hello') => ({ i: 'id', t: 1, f: 'console', r: 'worker', c: 1, b });

test('plain node exposes the new bridge primitives and loads store', async () => {
  assert.equal(typeof primitive.appendChained, 'function');
  assert.equal(typeof primitive.readPast, 'function');
  assert.equal(typeof primitive.commitCursor, 'function');
  const result = spawnSync(process.execPath, ['--input-type=module', '-e', `await import(${JSON.stringify(storeUrl.href)})`], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
});

test('readPast twice without commit returns identical records and byte cursors', async t => {
  const { store, root } = await fixture(t);
  await store.append(root, 'worker', message('héllo'));
  const file = join(root, 'log/worker.jsonl');
  const cur = { k: 0, off: 0, n: 0, h: '' };
  const a = await primitive.readPast(file, cur);
  assert.deepEqual(await primitive.readPast(file, cur), a);
  assert.equal(a.records[0].n, 1);
  assert.equal(a.next.off, Buffer.byteLength(await readFile(file)));
  await primitive.commitCursor(join(root, 'cur/worker'), a.next);
  assert.deepEqual((await primitive.readPast(file, a.next)).records, []);
});

test('T6.1 edited record halts at the break, emits notice once, and does not commit delivery', async t => {
  const { store, root } = await fixture(t);
  await store.append(root, 'worker', message());
  const file = join(root, 'log/worker.jsonl');
  await writeFile(file, (await readFile(file, 'utf8')).replace('hello', 'jello'));
  const first = await store.read(root, 'worker');
  assert.deepEqual(first.records, []);
  assert.equal(first.next.halted, 1);
  assert.match(first.notice, /chain broken at #1/);
  assert.equal((await store.read(root, 'worker')).notice, undefined);
  assert.equal((await store.read(root, 'worker')).next.n, 0);
});

test('T6.2 truncation below committed offset halts instead of replaying', async t => {
  const { store, root } = await fixture(t);
  await store.append(root, 'worker', message());
  const got = await store.read(root, 'worker');
  await store.commit(root, 'worker', got.next);
  await writeFile(join(root, 'log/worker.jsonl'), '');
  const broken = await store.read(root, 'worker');
  assert.deepEqual(broken.records, []);
  assert.equal(broken.next.halted, 2);
});

test('T6.3 root symlink and permissive root are refused', async t => {
  const { store, root, state } = await fixture(t);
  await chmod(root, 0o755);
  await assert.rejects(store.busRoot({ stateHome: state }), /permission/);
  await chmod(root, 0o700);
  const alias = join(state, 'alias');
  await symlink(join(state, 'himmel'), alias);
  await assert.rejects(store.busRoot({ stateHome: alias }), /symlink/);
});

test('T6.3 log symlink is refused without touching its target', async t => {
  const { store, root, state } = await fixture(t);
  const victim = join(state, 'victim');
  await writeFile(victim, 'untouched', { mode: 0o600 });
  await symlink(victim, join(root, 'log/worker.jsonl'));
  await assert.rejects(store.append(root, 'worker', message()));
  assert.equal(await readFile(victim, 'utf8'), 'untouched');
});

test('T6.4 chain crosses rotated compressed segments from a committed hash', async t => {
  const { store, root } = await fixture(t);
  await store.append(root, 'worker', message());
  const first = await store.read(root, 'worker');
  await store.commit(root, 'worker', first.next);
  for (let i = 0; i < 6; i++) await store.append(root, 'worker', message('x'.repeat(64000)));
  assert.ok((await readdir(join(root, 'log'))).some(n => /\.jsonl\.(zst|gz)$/.test(n)));
  const got = await store.read(root, 'worker');
  assert.deepEqual(got.records.map(r => r.n), [2, 3, 4, 5, 6]);
  assert.equal(got.next.halted, undefined);
  await store.commit(root, 'worker', got.next);
  const live = await store.read(root, 'worker');
  assert.deepEqual(live.records.map(r => r.n), [7]);
  assert.equal(live.next.n, 7);
  assert.equal(live.next.halted, undefined);
});

test('T6.5 halted log refuses new sends and exposes no pending wake', async t => {
  const { store, root } = await fixture(t);
  await store.append(root, 'worker', message());
  const file = join(root, 'log/worker.jsonl');
  await writeFile(file, (await readFile(file, 'utf8')).replace('hello', 'jello'));
  await store.read(root, 'worker');
  await assert.rejects(store.append(root, 'worker', message('again')), /halted/);
  assert.equal(await store.pending(root, 'worker'), false);
});

test('T7.1 state home inside a git work tree is refused', async t => {
  const state = await mkdtemp(join(tmpdir(), 'bus-git-'));
  t.after(() => rm(state, { recursive: true, force: true }));
  await mkdir(join(state, '.git'));
  const store = await import(storeUrl);
  await assert.rejects(store.busRoot({ stateHome: state }), /work tree/);
});

test('concurrent writers stamp unique consecutive sequence numbers', async t => {
  const { store, root } = await fixture(t);
  await Promise.all(Array.from({ length: 12 }, (_, i) => store.append(root, 'worker', message(String(i)))));
  const got = await store.read(root, 'worker');
  assert.deepEqual(got.records.map(r => r.n), Array.from({ length: 12 }, (_, i) => i + 1));
});

test('a later chain break never commits earlier un-emitted records', async t => {
  const { store, root } = await fixture(t);
  await store.append(root, 'worker', message('first'));
  await store.append(root, 'worker', message('second'));
  const file = join(root, 'log/worker.jsonl');
  await writeFile(file, (await readFile(file, 'utf8')).replace('second', 'tamper'));
  const got = await store.read(root, 'worker');
  const persisted = JSON.parse(await readFile(join(root, 'cur/worker'), 'utf8'));
  assert.equal(persisted.n, 0);
  assert.equal(persisted.off, 0);
  assert.equal(persisted.halted, 2);
  assert.deepEqual(got.records, []);
});

test('permissions are rechecked on the bus parent after startup', async t => {
  const { store, root, state } = await fixture(t);
  await chmod(join(state, 'himmel'), 0o777);
  await assert.rejects(store.append(root, 'worker', message()), /permission/);
});

// the XDG state home and himmel/ are shared; only himmel/bus and
// below must be private.
test('HIMMEL-5221 a 0755 state home and himmel parent are accepted, and himmel/bus is created 0700', async t => {
  const state = await mkdtemp(join(tmpdir(), 'bus-shared-'));
  t.after(() => rm(state, { recursive: true, force: true }));
  await chmod(state, 0o755);
  await mkdir(join(state, 'himmel'), { mode: 0o755 });
  const store = await import(storeUrl);
  const root = await store.busRoot({ stateHome: state });
  assert.equal((await fs.stat(root)).mode & 0o777, 0o700);
  await store.append(root, 'worker', message());
  assert.equal((await store.read(root, 'worker')).records.length, 1);
});

test('HIMMEL-5221 a group/other-writable parent and a 0755 himmel/bus are still refused', async t => {
  for (const [rel, mode] of [['.', 0o777], ['himmel', 0o775], ['himmel/bus', 0o755], ['.', 0o757], ['himmel', 0o757]]) {
    const { store, state } = await fixture(t);
    await chmod(join(state, rel), mode);
    await assert.rejects(store.busRoot({ stateHome: state }), /permission/, `${rel} ${mode.toString(8)}`);
  }
});

// The shared-parent owner rule: own uid or root, nothing else. lstat is mocked
// for the state home only (a test cannot chown); every other path is real.
async function busRootWithStateHomeUid(t, uid) {
  const { store, state } = await fixture(t);
  const original = fs.lstat;
  const mocked = t.mock.method(fs, 'lstat', async (path, ...args) => {
    const stat = await original(path, ...args);
    return path === state ? Object.create(stat, { uid: { value: uid } }) : stat;
  });
  syncBuiltinESMExports();
  try { return await store.busRoot({ stateHome: state }); } finally { mocked.mock.restore(); syncBuiltinESMExports(); }
}

test('HIMMEL-5221 a shared parent owned by another uid is refused', async t => {
  await assert.rejects(busRootWithStateHomeUid(t, process.getuid() + 1), /permission/);
});

test('HIMMEL-5221 a shared parent owned by root is accepted', async t => {
  assert.match(await busRootWithStateHomeUid(t, 0), /himmel\/bus$/);
});

test('cursor commit refuses a symlink and preserves its target', async t => {
  const { store, root, state } = await fixture(t);
  const target = join(state, 'cursor-target');
  await writeFile(target, 'untouched', { mode: 0o600 });
  await symlink(target, join(root, 'cur/worker'));
  await assert.rejects(store.commit(root, 'worker', { k: 0, off: 0, n: 0, h: '' }));
  assert.equal(await readFile(target, 'utf8'), 'untouched');
});

test('withChainLock owns the named lock inode, not a relative filename', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'bus-lock-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const lock = join(dir, 'lock');
  await primitive.withChainLock(lock, async () => {
    const contender = spawnSync('flock', ['-n', lock, 'true']);
    assert.equal(contender.status, 1);
  });
  assert.equal(spawnSync('flock', ['-n', lock, 'true']).status, 0);
});

test('CR codex-1 stale delivery commit cannot clear a persisted halt', async t => {
  const { store, root } = await fixture(t);
  await store.append(root, 'worker', message());
  const before = await store.read(root, 'worker');
  const file = join(root, 'log/worker.jsonl');
  await writeFile(file, (await readFile(file, 'utf8')).replace('hello', 'jello'));
  await store.read(root, 'worker');
  await assert.rejects(store.commit(root, 'worker', before.next), /halted|stale/);
  assert.equal(JSON.parse(await readFile(join(root, 'cur/worker'), 'utf8')).halted, 1);
  await assert.rejects(store.append(root, 'worker', message()), /halted/);
});

test('CR codex-1 delivery commits cannot move an already committed cursor backwards', async t => {
  const { store, root } = await fixture(t);
  await store.append(root, 'worker', message());
  const first = await store.read(root, 'worker');
  await store.append(root, 'worker', message('second'));
  const second = await store.read(root, 'worker');
  await store.commit(root, 'worker', second.next);
  await assert.rejects(store.commit(root, 'worker', first.next), /stale/);
  assert.equal(JSON.parse(await readFile(join(root, 'cur/worker'), 'utf8')).n, 2);
});

test('CR codex-2 pending serializes with a recipient writer lock', async t => {
  const { store, root } = await fixture(t);
  await store.append(root, 'worker', message());
  let waiting;
  await primitive.withChainLock(join(root, 'lock/worker'), async () => {
    let finished = false;
    waiting = store.pending(root, 'worker').then(value => { finished = true; return value; });
    await new Promise(resolve => setTimeout(resolve, 50));
    assert.equal(finished, false);
  });
  assert.equal(await waiting, true);
});

test('CR codex-3 pending wakes on a truncated or missing committed log', async t => {
  const { store, root } = await fixture(t);
  await store.append(root, 'worker', message());
  await store.commit(root, 'worker', (await store.read(root, 'worker')).next);
  const file = join(root, 'log/worker.jsonl');
  await writeFile(file, '');
  assert.equal(await store.pending(root, 'worker'), true);
  await rm(file);
  assert.equal(await store.pending(root, 'worker'), true);
});

test('CR codex-4 a malformed later record reports its actual sequence', async t => {
  const { store, root } = await fixture(t);
  await store.append(root, 'worker', message('first'));
  await store.append(root, 'worker', message('second'));
  const file = join(root, 'log/worker.jsonl');
  const lines = (await readFile(file, 'utf8')).trimEnd().split('\n');
  await writeFile(file, lines[0] + '\n{malformed}\n');
  const got = await store.read(root, 'worker');
  assert.equal(got.next.halted, 2);
  assert.deepEqual(got.records, []);
  assert.equal(got.next.n, 0);
});

test('a torn undelivered tail halts once rather than leaving a perpetual wake', async t => {
  const { store, root } = await fixture(t);
  await store.append(root, 'worker', message('first'));
  await store.append(root, 'worker', message('second'));
  const file = join(root, 'log/worker.jsonl');
  const lines = (await readFile(file, 'utf8')).trimEnd().split('\n');
  await writeFile(file, lines[0] + '\n' + lines[1].slice(0, -5));
  assert.equal(await store.pending(root, 'worker'), true);
  const got = await store.read(root, 'worker');
  assert.equal(got.next.halted, 2);
  assert.deepEqual(got.records, []);
  assert.equal(await store.pending(root, 'worker'), false);
});

test('CR round-2 codex-2 append refuses missing or truncated committed live bytes', async t => {
  for (const missing of [true, false]) {
    const { store, root } = await fixture(t);
    await store.append(root, 'worker', message());
    await store.commit(root, 'worker', (await store.read(root, 'worker')).next);
    const file = join(root, 'log/worker.jsonl');
    if (missing) await rm(file); else await writeFile(file, '');
    await assert.rejects(store.append(root, 'worker', message('again')), /committed.*missing|truncated/);
    if (missing) await assert.rejects(readFile(file), { code: 'ENOENT' });
    else assert.equal(await readFile(file, 'utf8'), '');
    const broken = await store.read(root, 'worker');
    assert.equal(broken.next.halted, 2);
    assert.deepEqual(broken.records, []);
  }
});

test('CR round-3 codex-2 corrupt compressed bytes wake the reader to persist a halt', async t => {
  const { store, root } = await fixture(t);
  for (let i = 0; i < 6; i++) await store.append(root, 'worker', message('x'.repeat(64000)));
  const file = (await readdir(join(root, 'log'))).find(n => /\.jsonl\.(zst|gz)$/.test(n));
  assert.ok(file);
  await writeFile(join(root, 'log', file), 'not compressed data');
  assert.equal(await store.pending(root, 'worker'), true);
  const broken = await store.read(root, 'worker');
  assert.equal(broken.next.halted, 1);
  assert.match(broken.notice, /chain broken at #1/);
  assert.equal(await store.pending(root, 'worker'), false);
  assert.equal((await store.read(root, 'worker')).notice, undefined);
});

test('HIMMEL-4880 malformed delivery cursors are refused before persistence', async t => {
  const { store, root } = await fixture(t);
  await store.append(root, 'worker', message());
  const { next } = await store.read(root, 'worker');
  for (const bad of [null, {}, { ...next, h: 'zz' }, { ...next, off: -1 }, { ...next, k: 0.5 }, { ...next, halted: 1 }]) {
    await assert.rejects(store.commit(root, 'worker', bad), /invalid bus cursor/);
    await assert.rejects(readFile(join(root, 'cur/worker')), { code: 'ENOENT' });
  }
  await store.commit(root, 'worker', next);
  assert.equal(await store.pending(root, 'worker'), false);
});

test('HIMMEL-4880 unreadable cursors halt once and explicit unhalt permits replay', async t => {
  for (const raw of ['', 'null', '{"k":0}', '{broken']) {
    const { store, root } = await fixture(t);
    await store.append(root, 'worker', message());
    await writeFile(join(root, 'cur/worker'), raw, { mode: 0o600 });
    assert.equal(await store.pending(root, 'worker'), true);
    const got = await store.read(root, 'worker');
    assert.deepEqual(got.records, []);
    assert.match(got.notice, /invalid bus cursor/);
    assert.equal(await store.pending(root, 'worker'), false);
    assert.equal((await store.read(root, 'worker')).notice, undefined);
    await store.unhalt(root, 'worker');
    assert.deepEqual((await store.read(root, 'worker')).records.map(r => r.n), [1]);
  }
});

test('HIMMEL-4880 native filesystem errors propagate without a sticky halt', async t => {
  const { store, root } = await fixture(t);
  for (let i = 0; i < 6; i++) await store.append(root, 'worker', message('x'.repeat(64000)));
  const archive = join(root, 'log', (await readdir(join(root, 'log'))).find(n => /\.jsonl\.(zst|gz)$/.test(n)));
  const original = fs.open;
  for (const code of ['EACCES', 'EPERM', 'EIO']) {
    const mocked = t.mock.method(fs, 'open', async (path, ...args) => {
      if (path === archive) throw Object.assign(new Error('native filesystem failure'), { code });
      return original(path, ...args);
    });
    syncBuiltinESMExports();
    try {
      await assert.rejects(store.read(root, 'worker'), { code });
      await assert.rejects(readFile(join(root, 'cur/worker')), { code: 'ENOENT' });
    } finally { mocked.mock.restore(); syncBuiltinESMExports(); }
  }
  assert.equal((await store.read(root, 'worker')).next.halted, undefined);
});

test('HIMMEL-4880 pending uses metadata and read loads only one undelivered segment', async t => {
  const { store, root } = await fixture(t);
  for (let i = 0; i < 12; i++) await store.append(root, 'worker', message('x'.repeat(64000)));
  const original = fs.open;
  let archiveOpens = 0;
  const mocked = t.mock.method(fs, 'open', async (path, ...args) => {
    if (/\.jsonl\.(zst|gz)$/.test(path)) archiveOpens++;
    return original(path, ...args);
  });
  syncBuiltinESMExports();
  try {
    assert.equal(await store.pending(root, 'worker'), true);
    assert.equal(archiveOpens, 0);
    const got = await store.read(root, 'worker');
    assert.equal(archiveOpens, 1);
    assert.deepEqual(got.records.map(r => r.n), [1, 2, 3, 4, 5]);
    await store.commit(root, 'worker', got.next);
    const second = await store.read(root, 'worker');
    assert.deepEqual(second.records.map(r => r.n), [6, 7, 8, 9, 10]);
    await store.commit(root, 'worker', second.next);
    assert.deepEqual((await store.read(root, 'worker')).records.map(r => r.n), [11, 12]);
  } finally { mocked.mock.restore(); syncBuiltinESMExports(); }
});

test('HIMMEL-4880 unhalt preserves the delivery position and rechecks repaired bytes', async t => {
  const { store, root } = await fixture(t);
  await store.append(root, 'worker', message('first'));
  await store.commit(root, 'worker', (await store.read(root, 'worker')).next);
  await store.append(root, 'worker', message('second'));
  const file = join(root, 'log/worker.jsonl');
  const original = await readFile(file, 'utf8');
  await writeFile(file, original.replace('second', 'tamper'));
  assert.equal((await store.read(root, 'worker')).next.halted, 2);
  assert.equal((await store.unhalt(root, 'worker')).n, 1);
  assert.equal((await store.read(root, 'worker')).next.halted, 2);
  await writeFile(file, original);
  await store.unhalt(root, 'worker');
  assert.deepEqual((await store.read(root, 'worker')).records.map(r => r.n), [2]);
});

test('HIMMEL-4880 pending propagates native metadata failures without a wake', async t => {
  const { store, root } = await fixture(t);
  for (let i = 0; i < 6; i++) await store.append(root, 'worker', message('x'.repeat(64000)));
  const original = fs.lstat;
  for (const code of ['EACCES', 'EPERM']) {
    const mocked = t.mock.method(fs, 'lstat', async (path, ...args) => {
      if (/\.jsonl\.(zst|gz)$/.test(path)) throw Object.assign(new Error('native metadata failure'), { code });
      return original(path, ...args);
    });
    syncBuiltinESMExports();
    try {
      await assert.rejects(store.pending(root, 'worker'), { code });
      await assert.rejects(readFile(join(root, 'cur/worker')), { code: 'ENOENT' });
    } finally { mocked.mock.restore(); syncBuiltinESMExports(); }
  }
});

test('HIMMEL-4880 invalid segment metadata wakes read to persist one halt', async t => {
  const { store, root } = await fixture(t);
  await store.append(root, 'worker', message());
  await writeFile(join(root, 'log/worker.9007199254740992.jsonl'), '', { mode: 0o600 });
  assert.equal(await store.pending(root, 'worker'), true);
  const got = await store.read(root, 'worker');
  assert.deepEqual(got.records, []);
  assert.equal(got.next.halted, 1);
  assert.match(got.notice, /chain broken/);
  assert.equal(await store.pending(root, 'worker'), false);
});

test('appendChained never recreates a missing log', async t => {
  assert.equal(typeof primitive.appendChained, 'function');
  const dir = await mkdtemp(join(tmpdir(), 'bus-missing-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  await assert.rejects(primitive.appendChained(join(dir, 'missing'), message(), join(dir, 'lock')), /ENOENT/);
  assert.deepEqual(await readdir(dir), ['lock']);
});
