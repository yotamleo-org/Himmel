import { readFile, readdir, readlink, link, rename, unlink } from 'node:fs/promises';
import { constants } from 'node:fs';
import { basename, join } from 'node:path';
import { randomBytes } from 'node:crypto';
import { openChainFile, withChainLock } from '../../../../scripts/telegram/bus.ts';
import * as store from './store.mjs';
import { canonRole } from './edges.mjs';
import { legacyNamesOn } from '../../../../scripts/lib/env-alias.mjs';

const NAME = store.SESSION_NAME;
const ROLES = ['worker', 'chief', 'judge', 'consult'];

// A role as stored or typed -> its current name, or a refusal. `console` is `chief`;
// the pre-rename `leg` maps to `worker` while the legacy-names switch is on.
function roleOf(value) {
  const role = canonRole(value);
  if (!ROLES.includes(role)) throw new Error(`invalid role: ${value} (one of ${ROLES.join('|')})`);
  return role;
}
// What a record stores for a role. A chief is still stored as `console` until the
// fleet that reads records has turned over; the reader above accepts both spellings.
const stored = role => (role === 'chief' ? 'console' : role);
const UNBOUND = { error: 'identity unbound' };

function checkName(name) {
  if (!NAME.test(name)) throw new Error(`invalid session name: ${name}`);
}

// {ppid, start, comm} of a pid under an injectable /proc root, or null.
// comm may contain spaces and parens, so split after the LAST ')'.
export async function procStat(proc, pid) {
  let text;
  try { text = await readFile(join(proc, String(pid), 'stat'), 'utf8'); }
  catch (error) { if (error.code === 'ENOENT' || error.code === 'ESRCH') return null; throw error; }
  const open = text.indexOf('('), close = text.lastIndexOf(')');
  if (open < 0 || close < open) return null;
  const rest = text.slice(close + 2).split(' ');
  return { comm: text.slice(open + 1, close), ppid: Number(rest[1]), start: rest[19] };
}

async function isClaude(proc, pid, comm) {
  if (comm === 'claude') return true;
  try { return basename(await readlink(join(proc, String(pid), 'exe'))) === 'claude'; } catch { return false; }
}

// Nearest claude ancestor (inclusive) of `pid`: {pid, start}, or null. Nearest,
// not outermost: the console is an ancestor of every worker it launches.
export async function nearestClaude(proc, pid) {
  for (let hops = 0; pid > 1 && hops < 128; hops++) {
    const st = await procStat(proc, pid);
    if (!st) return null;
    if (await isClaude(proc, pid, st.comm)) return { pid, start: st.start };
    pid = st.ppid;
  }
  return null;
}

const peersDir = root => join(root, 'peers');
const peerFile = (root, name) => join(peersDir(root), name + '.json');
const registryLock = root => join(root, 'lock', '.peers');

async function readPeer(root, name) {
  checkName(name);
  let handle;
  try { handle = await openChainFile(peerFile(root, name), constants.O_RDONLY); }
  catch (error) { if (error.code === 'ENOENT') return null; throw error; }
  try {
    const peer = JSON.parse(await handle.readFile('utf8'));
    return peer.role === undefined ? peer : { ...peer, role: roleOf(peer.role) };
  } finally { await handle.close(); }
}

// Writes `data` to a private temp file and returns its path.
async function temp(root, name, data) {
  const path = join(peersDir(root), `.${name}.${randomBytes(6).toString('hex')}.tmp`);
  const handle = await openChainFile(path, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL);
  try { await handle.writeFile(JSON.stringify(data) + '\n'); } finally { await handle.close(); }
  return path;
}

async function update(root, name, change) {
  return withChainLock(registryLock(root), async () => {
    const peer = await readPeer(root, name);
    if (!peer) throw new Error(`unknown session: ${name}`);
    const next = await change(peer);
    const path = await temp(root, name, { ...next, role: stored(next.role) });
    try { await rename(path, peerFile(root, name)); } catch (error) { await unlink(path).catch(() => {}); throw error; }
    return next;
  });
}

export async function loadPeers(root) {
  const peers = {};
  for (const file of await readdir(peersDir(root))) {
    const stem = file.endsWith('.json') ? file.slice(0, -'.json'.length) : '';
    if (!NAME.test(stem)) continue;
    try { const peer = await readPeer(root, stem); if (peer) peers[stem] = peer; } catch { /* unreadable peer: no edges */ }
  }
  return peers;
}

// Names are single-use once bound: the exclusive link() fails if the name ever
// existed. The one idempotent case is a re-arm after a refused launch
// an entry that was registered but never bound, with the same
// role, console, pair and predecessor, is adopted instead of refused - it has
// no pid, so nothing can resolve to it and re-registering grants nothing new.
// A bound non-chief entry whose pid is gone is reset to unbound the same way.
// The chief a session belongs to is stored under `console` (the stored field is not renamed here).
// `console` is the pre-rename spelling of `chief`: read while the legacy-names switch is on.
export async function register(root, name, { role: given, chief, console: old, pair, predecessor, proc = '/proc' } = {}) {
  checkName(name);
  if (old !== undefined && !legacyNamesOn()) throw new Error('--console was renamed to --chief');
  if (old !== undefined && chief !== undefined && chief !== old) throw new Error('--console and --chief name different chiefs');
  const owner = chief ?? old;
  const role = roleOf(given);
  if (role !== 'chief' && !owner) throw new Error(`role ${role} needs --chief`);
  for (const other of [owner, pair, predecessor]) if (other !== undefined) checkName(other);
  const peer = { n: name, role, launched: new Date().toISOString() };
  if (owner) peer.console = owner;
  if (pair) peer.pair = pair;
  if (predecessor) peer.predecessor = predecessor;
  const path = await temp(root, name, { ...peer, role: stored(peer.role) });
  try { await link(path, peerFile(root, name)); }
  catch (error) {
    if (error.code !== 'EEXIST') throw error;
    const held = await readPeer(root, name);
    const kept = held && ['role', 'pair', 'predecessor'].every(key => held[key] === peer[key]);
    const sameChief = held?.console === peer.console;
    if (kept && sameChief && held.pid === undefined) return held;
    // A relaunch of a non-chief name whose holder is gone takes the name back
    // unbound, as `rebind` would let any new pid take it. The relaunching chief
    // may be the stored one or one that succeeds it: a dead worker never adopts.
    if (kept && role !== 'chief' && (sameChief || await succeeds(root, peer.console, held.console))) {
      return reclaim(root, name, peer, proc);
    }
    throw new Error(await refusal(root, name, held, peer, proc));
  }
  finally { await unlink(path).catch(() => {}); }
  return peer;
}

// Under the registry lock: the holder must still be gone, else the name stays its.
async function reclaim(root, name, peer, proc) {
  return update(root, name, async held => {
    if (held.pid !== undefined && await status(root, name, { proc }) === 'live') {
      throw new Error(await refusal(root, name, held, peer, proc));
    }
    return peer;
  });
}

// ponytail: trusts the self-declared predecessor chain without adopt's hop
// checks. Ceiling: no more than an unauthenticated `register --chief` grants
// already, and the holder must be gone, re-checked under the lock in reclaim.
// Upgrade path: require each hop to be stamped (`succeed`) as adopt does.
async function succeeds(root, next, old) {
  if (!next || !old) return false;
  try { await chainTo(root, next, old); return true; } catch { return false; }
}

// Why a held name is refused, and the way out.
async function refusal(root, name, held, peer, proc) {
  const head = `name already registered: ${name}`;
  if (!held) return head;
  if (held.pid !== undefined && await status(root, name, { proc }).catch(() => 'gone') === 'live') {
    return `${head} (live holder pid ${held.pid}) - wait for pid ${held.pid} to exit, or launch under a new name`;
  }
  const dead = held.pid === undefined ? '' : `, dead holder pid ${held.pid}`;
  const differs = ['role', 'pair', 'predecessor'].filter(key => held[key] !== peer[key]);
  if (differs.length) {
    const show = p => differs.map(key => `${key} ${p[key] ?? 'none'}`).join(', ');
    return `${head} (held with ${show(held)}${dead}; this launch asks for ${show(peer)}) `
      + `- relaunch with the held ${differs.join(' and ')}, or launch under a new name`;
  }
  if (peer.role === 'chief') {
    return `${head} (a chief name${dead}) - a chief name is single-use: launch the chief under a new name`;
  }
  const as = p => `${p.role}${p.console ? ` under chief ${p.console}` : ''}`;
  return `${head} (held as ${as(held)}${dead}; this launch asks for ${as(peer)}, which does not succeed it) `
    + '- relaunch from the holding chief or a chief that succeeds it, or launch under a new name';
}

async function start(proc, pid) {
  const st = Number.isSafeInteger(pid) && pid > 1 ? await procStat(proc, pid) : null;
  if (!st) throw new Error(`no such process: ${pid}`);
  return st.start;
}

// One process identity, one name: refuse a bind that another session already holds.
async function unclaimed(root, name, pid, begun) {
  for (const [other, p] of Object.entries(await loadPeers(root))) {
    if (other !== name && p.pid === pid && p.start === begun) throw new Error(`process ${pid} is already bound to ${other}`);
  }
}

export async function status(root, name, { proc = '/proc' } = {}) {
  const peer = await readPeer(root, name);
  if (!peer) throw new Error(`unknown session: ${name}`);
  if (peer.pid === undefined) return 'unbound';
  const st = await procStat(proc, peer.pid);
  return st && st.start === peer.start ? 'live' : 'gone';
}

export async function bind(root, name, pid, { proc = '/proc' } = {}) {
  const begun = await start(proc, pid);
  return update(root, name, async peer => {
    if (peer.pid !== undefined) throw new Error(`already bound: ${name}`);
    await unclaimed(root, name, pid, begun);
    return { ...peer, pid, start: begun };
  });
}

// A resumed session gets a new claude pid; only when the old one is gone.
export async function rebind(root, name, pid, { proc = '/proc' } = {}) {
  const begun = await start(proc, pid);
  return update(root, name, async peer => {
    if (peer.role === 'chief') throw new Error(`a chief name cannot be rebound: ${name}`);
    if (peer.pid === undefined) throw new Error(`not bound yet (use bind): ${name}`);
    if (await status(root, name, { proc }) === 'live') throw new Error(`bound pid is still live: ${name}`);
    await unclaimed(root, name, pid, begun);
    return { ...peer, pid, start: begun };
  });
}

const MAX_HOPS = 64;

// The chief chain from `next` back to `old` through predecessor records, oldest hop first.
async function chainTo(root, next, old) {
  const target = await readPeer(root, next);
  if (!target) throw new Error(`unknown session: ${next}`);
  if (target.role !== 'chief') throw new Error(`${next} is not a chief`);
  const hops = [];
  for (let to = next, at = target; ; ) {
    const from = at.predecessor;
    if (!from || from === next || hops.length >= MAX_HOPS) throw new Error(`${next} does not succeed ${old}`);
    hops.unshift({ from, to });
    if (from === old) return hops;
    at = await readPeer(root, from);
    if (at?.role !== 'chief') throw new Error(`${next} does not succeed ${old}`);
    to = from;
  }
}

// Console X stamps its successor: `next` must be a registered
// console whose predecessor is X. Stamped once; the same stamp again is a no-op.
// The caller's identity (X) is proven by the CLI's process ancestry, not here.
export async function succeed(root, name, next) {
  checkName(next);
  const target = await readPeer(root, next);
  if (!target) throw new Error(`unknown session: ${next}`);
  if (target.role !== 'chief') throw new Error(`${next} is not a chief`);
  return update(root, name, peer => {
    if (peer.role !== 'chief') throw new Error(`${name} is not a chief`);
    if (target.predecessor !== name) throw new Error(`${next} does not succeed ${name}`);
    if (peer.successor === next) return peer;
    if (peer.successor) throw new Error(`${name} already stamped ${peer.successor}`);
    return { ...peer, successor: next };
  });
}

// Console succession (spec §8.6): `name` follows `next` only if its old console
// stamped `next` as its successor (`succeed`), is gone, or sent a record naming
// `next`. A worker that missed a succession walks `next`'s predecessor records back
// to its old console: every console on that chain must have stamped its own
// successor, or be gone or have sent the worker a record naming it; no unstamped
// console but `next` may be live.
export async function adopt(root, name, next, { proc = '/proc' } = {}) {
  checkName(next);
  return update(root, name, async peer => {
    const old = peer.console;
    if (!old) throw new Error(`${name} has no console to replace`);
    if (old === next) return peer;
    const hops = await chainTo(root, next, old);
    const records = await store.scan(root, name);
    const relayed = (from, to) => {
      const names = new RegExp(`(^|[^A-Za-z0-9._-])${to.replace(/[.]/g, '\\.')}($|[^A-Za-z0-9._-])`);
      return records.some(r => r.f === from && typeof r.b === 'string' && names.test(r.b));
    };
    for (const { from, to } of hops) {
      if ((await readPeer(root, from))?.successor === to) continue;
      const state = await status(root, from, { proc });
      if (hops.length > 1 && state === 'live') throw new Error(`chief ${from} on the chain to ${next} is still live`);
      if (state !== 'gone' && !relayed(from, to)) throw new Error(`${from === old ? 'old ' : ''}chief ${from} is not gone and sent no relay naming ${to}`);
    }
    return { ...peer, console: next };
  });
}

// Who is the session this process belongs to? {name} or {error}.
export async function resolveIdentity(root, { proc = '/proc', pid = process.pid } = {}) {
  const claude = await nearestClaude(proc, pid);
  if (!claude) return UNBOUND;
  const matches = Object.entries(await loadPeers(root)).filter(([, p]) => p.pid === claude.pid && p.start === claude.start);
  return matches.length === 1 ? { name: matches[0][0] } : UNBOUND;
}
