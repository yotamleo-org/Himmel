import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, symlink, rm, readFile, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn, spawnSync } from 'node:child_process';

const store = await import(new URL('../lib/store.mjs', import.meta.url));
const identity = await import(new URL('../lib/identity.mjs', import.meta.url));
const edges = await import(new URL('../lib/edges.mjs', import.meta.url));
const cli = new URL('../bin/bus', import.meta.url).pathname;

async function fixture(t) {
  const state = await mkdtemp(join(tmpdir(), 'bus-identity-'));
  t.after(() => rm(state, { recursive: true, force: true }));
  const root = await store.busRoot({ stateHome: state });
  return { root, state };
}

// A fake /proc: procs = [{ pid, ppid, comm, start }]. claude is the exe basename.
async function fakeProc(t, procs) {
  const proc = await mkdtemp(join(tmpdir(), 'bus-proc-'));
  t.after(() => rm(proc, { recursive: true, force: true }));
  for (const p of procs) {
    await mkdir(join(proc, String(p.pid)));
    const rest = Array(17).fill(0).join(' ');
    await writeFile(join(proc, String(p.pid), 'stat'), `${p.pid} (${p.comm}) S ${p.ppid} ${rest} ${p.start} 0 0\n`);
    await symlink(`/usr/bin/${p.comm}`, join(proc, String(p.pid), 'exe'));
  }
  return proc;
}
const P = (pid, ppid, comm, start) => ({ pid, ppid, comm, start });

// claude(console) -> bash -> konsole -> claude(worker) -> server
const chain = [P(1, 0, 'init', 1), P(100, 1, 'claude', 1000), P(101, 100, 'bash', 1001), P(102, 101, 'konsole', 1002),
  P(200, 102, 'claude', 2000), P(300, 200, 'node', 3000)];

async function bound(root, proc) {
  await identity.register(root, 'con', { role: 'chief' });
  await identity.register(root, 'worker', { role: 'worker', chief: 'con' });
  await identity.bind(root, 'con', 100, { proc });
  await identity.bind(root, 'worker', 200, { proc });
}

test('T1.1 nearest claude ancestor stamps the worker, not the console', async t => {
  const { root } = await fixture(t);
  const proc = await fakeProc(t, chain);
  await bound(root, proc);
  assert.deepEqual(await identity.resolveIdentity(root, { proc, pid: 300 }), { name: 'worker' });
  assert.deepEqual(await identity.resolveIdentity(root, { proc, pid: 101 }), { name: 'con' });
});

test('T1.2 nested unbound claude under a bound worker is unbound', async t => {
  const { root } = await fixture(t);
  const proc = await fakeProc(t, [...chain, P(400, 200, 'claude', 4000), P(500, 400, 'node', 5000)]);
  await bound(root, proc);
  assert.deepEqual(await identity.resolveIdentity(root, { proc, pid: 500 }), { error: 'identity unbound' });
});

test('T1.3 second bind and re-register are refused', async t => {
  const { root } = await fixture(t);
  const proc = await fakeProc(t, chain);
  await bound(root, proc);
  await assert.rejects(identity.bind(root, 'worker', 100, { proc }), /already bound/);
  await assert.rejects(identity.register(root, 'worker', { role: 'worker', chief: 'con' }), /already registered/);
  assert.deepEqual(await identity.resolveIdentity(root, { proc, pid: 300 }), { name: 'worker' });
});

test('T1.3b re-arm of a registered-but-unbound name is adopted, a changed or bound one is refused (HIMMEL-5207)', async t => {
  const { root } = await fixture(t);
  const proc = await fakeProc(t, chain);
  await identity.register(root, 'con', { role: 'chief' });
  const first = await identity.register(root, 'worker', { role: 'worker', chief: 'con' });
  const again = await identity.register(root, 'worker', { role: 'worker', chief: 'con' });
  assert.deepEqual(again, first);
  await assert.rejects(identity.register(root, 'worker', { role: 'worker', chief: 'other' }), /already registered/);
  await assert.rejects(identity.register(root, 'worker', { role: 'judge', chief: 'con' }), /already registered/);
  await identity.bind(root, 'worker', 200, { proc });
  await assert.rejects(identity.register(root, 'worker', { role: 'worker', chief: 'con' }), /already registered/);
});

test('T1.4 pid reuse (same pid, different start time) is unbound', async t => {
  const { root } = await fixture(t);
  const proc = await fakeProc(t, chain);
  await bound(root, proc);
  const reused = await fakeProc(t, chain.map(p => p.pid === 200 ? { ...p, start: 9999 } : p));
  assert.deepEqual(await identity.resolveIdentity(root, { proc: reused, pid: 300 }), { error: 'identity unbound' });
  assert.equal(await identity.status(root, 'worker', { proc: reused }), 'gone');
  assert.equal(await identity.status(root, 'worker', { proc }), 'live');
});

test('T5.2 refused send lists only the caller own edges, never another console', async t => {
  const { root } = await fixture(t);
  await identity.register(root, 'conA', { role: 'chief' });
  await identity.register(root, 'conB', { role: 'chief' });
  await identity.register(root, 'legA', { role: 'worker', chief: 'conA' });
  await identity.register(root, 'judgeA', { role: 'judge', chief: 'conA', pair: 'legA' });
  await identity.register(root, 'legB', { role: 'worker', chief: 'conB' });
  const peers = await identity.loadPeers(root);
  assert.deepEqual(edges.edgeList(peers, 'legA'), ['conA', 'judgeA']);
  const refusal = edges.check(peers, 'legA', 'nobody');
  assert.equal(refusal.ok, false);
  assert.match(refusal.error, /^no edge to nobody/);
  assert.doesNotMatch(refusal.error, /conB|legB/);
  assert.match(refusal.error, /conA/);
});

test('edges: worker to sibling refused, worker to console allowed, console to other console worker refused', async t => {
  const { root } = await fixture(t);
  await identity.register(root, 'conA', { role: 'chief' });
  await identity.register(root, 'conB', { role: 'chief' });
  await identity.register(root, 'leg1', { role: 'worker', chief: 'conA' });
  await identity.register(root, 'leg2', { role: 'worker', chief: 'conA' });
  await identity.register(root, 'legB', { role: 'worker', chief: 'conB' });
  const peers = await identity.loadPeers(root);
  assert.equal(edges.check(peers, 'leg1', 'leg2').ok, false);
  assert.equal(edges.check(peers, 'leg1', 'conA').ok, true);
  assert.equal(edges.check(peers, 'conA', 'leg1').ok, true);
  assert.equal(edges.check(peers, 'conA', 'legB').ok, false);
  assert.equal(edges.check(peers, 'conA', 'conB').ok, false);
  assert.equal(edges.check(peers, 'leg1', 'leg1').ok, false);
  assert.equal(edges.check(peers, 'ghost', 'conA').ok, false);
});

test('edges: predecessor link creates console to console edge both ways', async t => {
  const { root } = await fixture(t);
  await identity.register(root, 'old', { role: 'chief' });
  await identity.register(root, 'next', { role: 'chief', predecessor: 'old' });
  const peers = await identity.loadPeers(root);
  assert.equal(edges.check(peers, 'old', 'next').ok, true);
  assert.equal(edges.check(peers, 'next', 'old').ok, true);
});

test('edges: a declaration only counts when both endpoints hold the required role', async t => {
  const { root } = await fixture(t);
  await identity.register(root, 'con', { role: 'chief' });
  await identity.register(root, 'a', { role: 'worker', chief: 'con' });
  await identity.register(root, 'b', { role: 'worker', chief: 'a' });
  await identity.register(root, 'c', { role: 'worker', chief: 'con', predecessor: 'a' });
  await identity.register(root, 'j', { role: 'judge', chief: 'con', pair: 'con' });
  const peers = await identity.loadPeers(root);
  assert.equal(edges.check(peers, 'b', 'a').ok, false);
  assert.equal(edges.check(peers, 'a', 'b').ok, false);
  assert.equal(edges.check(peers, 'c', 'a').ok, false);
  assert.equal(edges.check(peers, 'j', 'a').ok, false);
  assert.equal(edges.check(peers, 'c', 'con').ok, true);
});

test('one process identity cannot be bound to two names', async t => {
  const { root } = await fixture(t);
  const proc = await fakeProc(t, chain);
  await bound(root, proc);
  await identity.register(root, 'twin', { role: 'worker', chief: 'con' });
  await assert.rejects(identity.bind(root, 'twin', 200, { proc }), /already bound to worker/);
  assert.deepEqual(await identity.resolveIdentity(root, { proc, pid: 300 }), { name: 'worker' });
});

test('rebind only when the bound pid is gone', async t => {
  const { root } = await fixture(t);
  const proc = await fakeProc(t, chain);
  await bound(root, proc);
  await assert.rejects(identity.rebind(root, 'worker', 300, { proc }), /still live/);
  const after = await fakeProc(t, [P(1, 0, 'init', 1), P(201, 1, 'claude', 2500)]);
  await identity.rebind(root, 'worker', 201, { proc: after });
  assert.deepEqual(await identity.resolveIdentity(root, { proc: after, pid: 201 }), { name: 'worker' });
});

test('adopt needs the old console gone or a relay record from it naming the new one', async t => {
  const { root } = await fixture(t);
  const live = await fakeProc(t, chain);
  await bound(root, live);
  await identity.register(root, 'new', { role: 'chief', predecessor: 'con' });
  await assert.rejects(identity.adopt(root, 'worker', 'new', { proc: live }), /not gone/);
  await store.append(root, 'worker', { i: 'x', t: 1, f: 'con', r: 'worker', c: 1, b: 'handing over to new' });
  await identity.adopt(root, 'worker', 'new', { proc: live });
  assert.equal((await identity.loadPeers(root)).worker.console, 'new');
});

test('adopt succeeds when the old console is gone', async t => {
  const { root } = await fixture(t);
  const live = await fakeProc(t, chain);
  await bound(root, live);
  await identity.register(root, 'new', { role: 'chief', predecessor: 'con' });
  const gone = await fakeProc(t, [P(1, 0, 'init', 1), P(200, 1, 'claude', 2000)]);
  await identity.adopt(root, 'worker', 'new', { proc: gone });
  assert.equal((await identity.loadPeers(root)).worker.console, 'new');
});

test('adopt refuses a record from someone else naming the new console', async t => {
  const { root } = await fixture(t);
  const live = await fakeProc(t, chain);
  await bound(root, live);
  await identity.register(root, 'new', { role: 'chief', predecessor: 'con' });
  await store.append(root, 'worker', { i: 'x', t: 1, f: 'rogue', r: 'worker', c: 1, b: 'adopt new' });
  await assert.rejects(identity.adopt(root, 'worker', 'new', { proc: live }), /not gone/);
});

test('adopt: a relay must name the new console as a whole word', async t => {
  const { root } = await fixture(t);
  const live = await fakeProc(t, chain);
  await bound(root, live);
  await identity.register(root, 'new', { role: 'chief', predecessor: 'con' });
  await store.append(root, 'worker', { i: 'x', t: 1, f: 'con', r: 'worker', c: 1, b: 'a newer console is coming' });
  await assert.rejects(identity.adopt(root, 'worker', 'new', { proc: live }), /not gone/);
});

test('adopt finds a relay the hook already delivered and committed', async t => {
  const { root } = await fixture(t);
  const live = await fakeProc(t, chain);
  await bound(root, live);
  await identity.register(root, 'new', { role: 'chief', predecessor: 'con' });
  await store.append(root, 'worker', { i: 'x', t: 1, f: 'con', r: 'worker', c: 1, b: 'handing over to new' });
  const delivered = await store.read(root, 'worker');
  assert.equal(delivered.records.length, 1);
  await store.commit(root, 'worker', delivered.next);
  await identity.adopt(root, 'worker', 'new', { proc: live });
  assert.equal((await identity.loadPeers(root)).worker.console, 'new');
});

test('adopt refuses a console that does not succeed the old one', async t => {
  const { root } = await fixture(t);
  const live = await fakeProc(t, chain);
  await bound(root, live);
  await identity.register(root, 'other', { role: 'chief' });
  const gone = await fakeProc(t, [P(1, 0, 'init', 1), P(200, 1, 'claude', 2000)]);
  await assert.rejects(identity.adopt(root, 'worker', 'other', { proc: gone }), /does not succeed con/);
  assert.equal((await identity.loadPeers(root)).worker.console, 'con');
});

// con -> mid -> new: a worker that missed the mid succession catches up in one adopt.
async function chained(t, root) {
  const all = await fakeProc(t, [...chain, P(150, 1, 'claude', 1500), P(160, 1, 'claude', 1600)]);
  await bound(root, all);
  await identity.register(root, 'mid', { role: 'chief', predecessor: 'con' });
  await identity.register(root, 'new', { role: 'chief', predecessor: 'mid' });
  await identity.bind(root, 'new', 160, { proc: all });
}

test('adopt walks the predecessor chain when every console but the target is gone', async t => {
  const { root } = await fixture(t);
  await chained(t, root);
  const all = await fakeProc(t, [P(1, 0, 'init', 1), P(150, 1, 'claude', 1500), P(160, 1, 'claude', 1600)]);
  await identity.bind(root, 'mid', 150, { proc: all });
  const after = await fakeProc(t, [P(1, 0, 'init', 1), P(200, 1, 'claude', 2000), P(160, 1, 'claude', 1600)]);
  await identity.adopt(root, 'worker', 'new', { proc: after });
  assert.equal((await identity.loadPeers(root)).worker.console, 'new');
});

test('adopt refuses a chain with an unproven hop', async t => {
  const { root } = await fixture(t);
  await chained(t, root);
  const after = await fakeProc(t, [P(1, 0, 'init', 1), P(200, 1, 'claude', 2000), P(160, 1, 'claude', 1600)]);
  await assert.rejects(identity.adopt(root, 'worker', 'new', { proc: after }), /chief mid is not gone and sent no relay naming new/);
  await store.append(root, 'worker', { i: 'x', t: 1, f: 'mid', r: 'worker', c: 1, b: 'your console is now new' });
  await identity.adopt(root, 'worker', 'new', { proc: after });
  assert.equal((await identity.loadPeers(root)).worker.console, 'new');
});

test('adopt refuses a chain whose intermediate console is still live, relay or not', async t => {
  const { root } = await fixture(t);
  await chained(t, root);
  const all = await fakeProc(t, [P(1, 0, 'init', 1), P(150, 1, 'claude', 1500), P(160, 1, 'claude', 1600)]);
  await identity.bind(root, 'mid', 150, { proc: all });
  await store.append(root, 'worker', { i: 'x', t: 1, f: 'con', r: 'worker', c: 1, b: 'your console is now mid' });
  await store.append(root, 'worker', { i: 'y', t: 2, f: 'mid', r: 'worker', c: 1, b: 'your console is now new' });
  const midLive = await fakeProc(t, [P(1, 0, 'init', 1), P(200, 1, 'claude', 2000), P(150, 1, 'claude', 1500), P(160, 1, 'claude', 1600)]);
  await assert.rejects(identity.adopt(root, 'worker', 'new', { proc: midLive }), /chief mid on the chain to new is still live/);
  assert.equal((await identity.loadPeers(root)).worker.console, 'con');
});

// A console stamps its successor at handover (`bus succeed`), so a
// hop passes on the stamp, live or not, with no per-worker relay record.
async function allLive(t, root) {
  await chained(t, root);
  const all = await fakeProc(t, [P(1, 0, 'init', 1), P(150, 1, 'claude', 1500), P(160, 1, 'claude', 1600)]);
  await identity.bind(root, 'mid', 150, { proc: all });
  return fakeProc(t, [P(1, 0, 'init', 1), P(100, 1, 'claude', 1000), P(200, 1, 'claude', 2000), P(150, 1, 'claude', 1500), P(160, 1, 'claude', 1600)]);
}

test('adopt passes a chain of live consoles that each stamped their successor', async t => {
  const { root } = await fixture(t);
  const live = await allLive(t, root);
  await identity.succeed(root, 'con', 'mid');
  await identity.succeed(root, 'mid', 'new');
  await identity.adopt(root, 'worker', 'new', { proc: live });
  assert.equal((await identity.loadPeers(root)).worker.console, 'new');
});

test('adopt still refuses a live intermediate console that never stamped', async t => {
  const { root } = await fixture(t);
  const live = await allLive(t, root);
  await identity.succeed(root, 'con', 'mid');
  await assert.rejects(identity.adopt(root, 'worker', 'new', { proc: live }), /chief mid on the chain to new is still live/);
  assert.equal((await identity.loadPeers(root)).worker.console, 'con');
});

test('adopt refuses a stamp that names a different successor', async t => {
  const { root } = await fixture(t);
  const live = await allLive(t, root);
  await identity.register(root, 'other', { role: 'chief', predecessor: 'mid' });
  await identity.succeed(root, 'con', 'mid');
  await identity.succeed(root, 'mid', 'other');
  await assert.rejects(identity.adopt(root, 'worker', 'new', { proc: live }), /chief mid on the chain to new is still live/);
  assert.equal((await identity.loadPeers(root)).worker.console, 'con');
});

test('adopt passes a single live-old-console hop on its stamp alone', async t => {
  const { root } = await fixture(t);
  const live = await fakeProc(t, chain);
  await bound(root, live);
  await identity.register(root, 'new', { role: 'chief', predecessor: 'con' });
  await assert.rejects(identity.adopt(root, 'worker', 'new', { proc: live }), /not gone/);
  await identity.succeed(root, 'con', 'new');
  await identity.adopt(root, 'worker', 'new', { proc: live });
  assert.equal((await identity.loadPeers(root)).worker.console, 'new');
});

test('succeed: only a console naming its own registered successor, once', async t => {
  const { root } = await fixture(t);
  const live = await fakeProc(t, chain);
  await bound(root, live);
  await identity.register(root, 'new', { role: 'chief', predecessor: 'con' });
  await identity.register(root, 'stranger', { role: 'chief' });
  await identity.register(root, 'rival', { role: 'chief', predecessor: 'con' });
  await assert.rejects(identity.succeed(root, 'worker', 'new'), /not a chief/);
  await assert.rejects(identity.succeed(root, 'con', 'stranger'), /does not succeed con/);
  await assert.rejects(identity.succeed(root, 'con', 'ghost'), /unknown session: ghost/);
  await assert.rejects(identity.succeed(root, 'con', 'worker'), /not a chief/);
  await identity.succeed(root, 'con', 'new');
  await identity.succeed(root, 'con', 'new');
  await assert.rejects(identity.succeed(root, 'con', 'rival'), /already stamped new/);
  assert.equal((await identity.loadPeers(root)).con.successor, 'new');
});

test('adopt onto the console already held is a no-op', async t => {
  const { root } = await fixture(t);
  const live = await fakeProc(t, chain);
  await bound(root, live);
  await identity.register(root, 'new', { role: 'chief', predecessor: 'con' });
  const gone = await fakeProc(t, [P(1, 0, 'init', 1), P(200, 1, 'claude', 2000)]);
  await identity.adopt(root, 'worker', 'new', { proc: gone });
  await identity.adopt(root, 'worker', 'new', { proc: gone });
  assert.equal((await identity.loadPeers(root)).worker.console, 'new');
});

test('rebind refuses a console name', async t => {
  const { root } = await fixture(t);
  const live = await fakeProc(t, chain);
  await bound(root, live);
  const after = await fakeProc(t, [P(1, 0, 'init', 1), P(201, 1, 'claude', 2500)]);
  await assert.rejects(identity.rebind(root, 'con', 201, { proc: after }), /a chief name cannot be rebound/);
});

test('adopt refuses a destination that is not a console', async t => {
  const { root } = await fixture(t);
  const live = await fakeProc(t, chain);
  await bound(root, live);
  await identity.register(root, 'other', { role: 'worker', chief: 'con' });
  const gone = await fakeProc(t, [P(1, 0, 'init', 1), P(200, 1, 'claude', 2000)]);
  await assert.rejects(identity.adopt(root, 'worker', 'other', { proc: gone }), /not a chief/);
  assert.equal((await identity.loadPeers(root)).worker.console, 'con');
});

test('CLI: register, bind, status, peers, rebind against real processes', async t => {
  const state = await mkdtemp(join(tmpdir(), 'bus-cli-'));
  t.after(() => rm(state, { recursive: true, force: true }));
  const env = { ...process.env, XDG_STATE_HOME: state };
  const run = (...args) => spawnSync(process.execPath, [cli, ...args], { env, encoding: 'utf8' });
  assert.equal(run('register', 'con', '--role', 'chief').status, 0);
  assert.equal(run('register', 'worker', '--role', 'worker', '--chief', 'con').status, 0);
  assert.equal(run('register', 'worker', '--role', 'worker', '--chief', 'con').status, 0);
  assert.notEqual(run('register', 'worker', '--role', 'worker', '--chief', 'other').status, 0);
  assert.notEqual(run('register', 'bad', '--role', 'wizard').status, 0);
  const child = spawn('sleep', ['30']);
  t.after(() => child.kill());
  assert.equal(run('bind', 'worker', String(child.pid)).status, 0);
  assert.notEqual(run('register', 'worker', '--role', 'worker', '--chief', 'con').status, 0);
  assert.notEqual(run('bind', 'worker', String(child.pid)).status, 0);
  assert.equal(run('status', 'worker').stdout.trim(), 'live');
  assert.notEqual(run('rebind', 'worker', String(process.pid)).status, 0);
  child.kill('SIGKILL');
  await new Promise(r => child.once('exit', r));
  assert.equal(run('status', 'worker').stdout.trim(), 'gone');
  const second = spawn('sleep', ['30']);
  t.after(() => second.kill());
  assert.equal(run('rebind', 'worker', String(second.pid)).status, 0);
  assert.equal(run('status', 'worker').stdout.trim(), 'live');
  // the CLI process itself has no bound claude ancestor
  const peers = run('peers');
  assert.notEqual(peers.status, 0);
  assert.match(peers.stderr, /identity unbound/);
  assert.equal((await stat(join(state, 'himmel/bus/peers/worker.json'))).mode & 0o777, 0o600);
});

// The old role name became `worker`. Old stored records must keep reading while
// the legacy-names switch is on, and be refused when it is off.
async function withSwitch(value, body) {
  const prior = process.env.HIMMEL_LEGACY_NAMES;
  if (value === undefined) delete process.env.HIMMEL_LEGACY_NAMES; else process.env.HIMMEL_LEGACY_NAMES = value;
  try { return await body(); } finally {
    if (prior === undefined) delete process.env.HIMMEL_LEGACY_NAMES; else process.env.HIMMEL_LEGACY_NAMES = prior;
  }
}

async function oldRecord(root, name, extra = {}) {
  await writeFile(join(root, 'peers', `${name}.json`),
    JSON.stringify({ n: name, role: 'leg', launched: '2026-10-19T00:00:00.000Z', console: 'con', ...extra }) + '\n', { mode: 0o600 });
}

test('M2: role worker registers and is stored as worker', async t => {
  const { root } = await fixture(t);
  await identity.register(root, 'con', { role: 'chief' });
  const peer = await identity.register(root, 'w1', { role: 'worker', chief: 'con' });
  assert.equal(peer.role, 'worker');
  assert.equal(JSON.parse(await readFile(join(root, 'peers/w1.json'), 'utf8')).role, 'worker');
});

test('M2: --role leg is an alias under the switch and is stored as worker', async t => {
  const { root } = await fixture(t);
  await identity.register(root, 'con', { role: 'chief' });
  const peer = await withSwitch(undefined, () => identity.register(root, 'w2', { role: 'leg', chief: 'con' }));
  assert.equal(peer.role, 'worker');
  assert.equal(JSON.parse(await readFile(join(root, 'peers/w2.json'), 'utf8')).role, 'worker');
});

test('M2: a stored role leg record still reads as worker and keeps its edges', async t => {
  const { root } = await fixture(t);
  await identity.register(root, 'con', { role: 'chief' });
  await oldRecord(root, 'old1');
  await withSwitch(undefined, async () => {
    const peers = await identity.loadPeers(root);
    assert.equal(peers.old1.role, 'worker');
    assert.equal(edges.check(peers, 'old1', 'con').ok, true);
    assert.equal(await identity.status(root, 'old1'), 'unbound');
    await identity.register(root, 'j', { role: 'judge', chief: 'con', pair: 'old1' });
    assert.equal(edges.check(await identity.loadPeers(root), 'j', 'old1').ok, true);
  });
});

test('M2: a re-arm of a stored role leg record is adopted as the same registration', async t => {
  const { root } = await fixture(t);
  await identity.register(root, 'con', { role: 'chief' });
  await oldRecord(root, 'old2');
  const again = await withSwitch(undefined, () => identity.register(root, 'old2', { role: 'worker', chief: 'con' }));
  assert.equal(again.role, 'worker');
});

test('M2: edges.check treats a raw role leg peer as worker under the switch only', async () => {
  const peers = {
    con: { n: 'con', role: 'chief' },
    a: { n: 'a', role: 'leg', console: 'con' },
    j: { n: 'j', role: 'judge', console: 'con', pair: 'a' },
  };
  await withSwitch(undefined, () => assert.equal(edges.check(peers, 'j', 'a').ok, true));
  await withSwitch('0', () => assert.equal(edges.check(peers, 'j', 'a').ok, false));
});

test('M2: with the switch off, a worker gets no pair edge to a raw role leg peer', async () => {
  const peers = {
    con: { n: 'con', role: 'chief' },
    a: { n: 'a', role: 'leg', console: 'con' },
    w: { n: 'w', role: 'worker', console: 'con', pair: 'a' },
  };
  await withSwitch(undefined, () => assert.equal(edges.check(peers, 'w', 'a').ok, true));
  await withSwitch('0', () => {
    assert.equal(edges.check(peers, 'w', 'a').ok, false);
    assert.equal(edges.check(peers, 'a', 'w').ok, false);
    assert.equal(edges.check(peers, 'a', 'con').ok, false);
    assert.equal(edges.check(peers, 'con', 'a').ok, false);
    assert.equal(edges.check(peers, 'w', 'con').ok, true);
  });
});

test('M2: a console that names a pair draws no pair edge (only worker, judge and consult pair)', async () => {
  const peers = {
    con: { n: 'con', role: 'chief', pair: 'w2' },
    con2: { n: 'con2', role: 'chief' },
    w2: { n: 'w2', role: 'worker', console: 'con2' },
  };
  await withSwitch(undefined, () => {
    assert.equal(edges.check(peers, 'con', 'w2').ok, false);
    assert.equal(edges.check(peers, 'w2', 'con').ok, false);
  });
});

test('M2: with the switch off, --role leg is refused and a stored leg record is not read', async t => {
  const { root } = await fixture(t);
  await identity.register(root, 'con', { role: 'chief' });
  await identity.register(root, 'ok', { role: 'worker', chief: 'con' });
  await oldRecord(root, 'old3');
  await withSwitch('0', async () => {
    await assert.rejects(identity.register(root, 'w3', { role: 'leg', chief: 'con' }), /invalid role: leg/);
    await assert.rejects(identity.status(root, 'old3'), /invalid role: leg/);
    const peers = await identity.loadPeers(root);
    assert.equal(peers.old3, undefined);
    assert.equal(peers.ok.role, 'worker');
  });
});

test('M2: CLI accepts --role leg under the switch and refuses it with the switch off', async t => {
  const state = await mkdtemp(join(tmpdir(), 'bus-cli-'));
  t.after(() => rm(state, { recursive: true, force: true }));
  const run = (switchValue, ...args) => spawnSync(process.execPath, [cli, ...args],
    { env: { ...process.env, XDG_STATE_HOME: state, HIMMEL_LEGACY_NAMES: switchValue }, encoding: 'utf8' });
  assert.equal(run('1', 'register', 'con', '--role', 'chief').status, 0);
  assert.equal(run('1', 'register', 'w1', '--role', 'leg', '--chief', 'con').status, 0);
  assert.equal(JSON.parse(await readFile(join(state, 'himmel/bus/peers/w1.json'), 'utf8')).role, 'worker');
  const off = run('0', 'register', 'w2', '--role', 'leg', '--chief', 'con');
  assert.notEqual(off.status, 0);
  assert.match(off.stderr, /invalid role: leg/);
  assert.equal(run('0', 'register', 'w3', '--role', 'worker', '--chief', 'con').status, 0);
});

// The chief half of the rename: `chief` / `--chief` are canonical, `console` /
// `--console` read as aliases while the legacy-names switch is on.
async function cliState(t) {
  const state = await mkdtemp(join(tmpdir(), 'bus-cli-'));
  t.after(() => rm(state, { recursive: true, force: true }));
  const run = (switchValue, ...args) => spawnSync(process.execPath, [cli, ...args],
    { env: { ...process.env, XDG_STATE_HOME: state, HIMMEL_LEGACY_NAMES: switchValue }, encoding: 'utf8' });
  return { state, run };
}

test('M3: CLI registers role chief, --chief and --pair <worker>, the documented command', async t => {
  const { state, run } = await cliState(t);
  assert.equal(run('0', 'register', 'con', '--role', 'chief').status, 0);
  assert.equal(run('0', 'register', 'w1', '--role', 'worker', '--chief', 'con').status, 0);
  const judge = run('0', 'register', 'j1', '--role', 'judge', '--chief', 'con', '--pair', 'w1');
  assert.equal(judge.status, 0, judge.stderr);
  assert.equal(run('0', 'register', 'con2', '--role', 'chief', '--predecessor', 'con').status, 0);
  assert.equal(JSON.parse(await readFile(join(state, 'himmel/bus/peers/con.json'), 'utf8')).role, 'chief');
  const root = await store.busRoot({ stateHome: state });
  const peers = await identity.loadPeers(root);
  assert.equal(edges.check(peers, 'w1', 'con').ok, true);
  assert.equal(edges.check(peers, 'j1', 'w1').ok, true);
  assert.equal(edges.check(peers, 'con2', 'con').ok, true);
  const missing = run('0', 'register', 'w2', '--role', 'worker');
  assert.notEqual(missing.status, 0);
  assert.match(missing.stderr, /needs --chief/);
});

test('M3: a stored role console record reads back as chief under the switch only', async t => {
  const { root } = await fixture(t);
  await identity.register(root, 'new', { role: 'chief' });
  await writeFile(join(root, 'peers', 'oldcon.json'),
    JSON.stringify({ n: 'oldcon', role: 'console', launched: '2026-10-19T00:00:00.000Z' }) + '\n', { mode: 0o600 });
  await oldRecord(root, 'oldw', { role: 'worker', console: 'oldcon' });
  await withSwitch(undefined, async () => {
    const peers = await identity.loadPeers(root);
    assert.equal(peers.oldcon.role, 'chief');
    assert.equal(edges.check(peers, 'oldw', 'oldcon').ok, true);
    await identity.register(root, 'succ', { role: 'chief', predecessor: 'oldcon' });
    assert.equal((await identity.succeed(root, 'oldcon', 'succ')).successor, 'succ');
  });
  await writeFile(join(root, 'peers', 'oldcon2.json'),
    JSON.stringify({ n: 'oldcon2', role: 'console', launched: '2026-10-19T00:00:00.000Z' }) + '\n', { mode: 0o600 });
  await withSwitch('0', async () => {
    assert.equal(edges.check({ c: { n: 'c', role: 'console' }, w: { n: 'w', role: 'worker', console: 'c' } }, 'w', 'c').ok, false);
    await assert.rejects(identity.status(root, 'oldcon2'), /invalid role: console/);
    await assert.rejects(identity.register(root, 'again', { role: 'console' }), /invalid role: console/);
  });
});

test('M3: CLI accepts --role console and --console under the switch and refuses them with it off', async t => {
  const { state, run } = await cliState(t);
  assert.equal(run('1', 'register', 'con', '--role', 'console').status, 0);
  assert.equal(JSON.parse(await readFile(join(state, 'himmel/bus/peers/con.json'), 'utf8')).role, 'chief');
  assert.equal(run('1', 'register', 'w1', '--role', 'worker', '--console', 'con').status, 0);
  const root = await store.busRoot({ stateHome: state });
  assert.equal(edges.check(await identity.loadPeers(root), 'w1', 'con').ok, true);
  assert.notEqual(run('1', 'register', 'w2', '--role', 'worker', '--console', 'con', '--chief', 'other').status, 0);
  const off = run('0', 'register', 'w3', '--role', 'worker', '--console', 'con');
  assert.notEqual(off.status, 0);
  assert.match(off.stderr, /--console was renamed to --chief/);
  const offRole = run('0', 'register', 'con3', '--role', 'console');
  assert.notEqual(offRole.status, 0);
  assert.match(offRole.stderr, /invalid role: console/);
});
