import {
  openSync, closeSync, fstatSync, lstatSync, readSync, readFileSync, writeFileSync, renameSync, unlinkSync,
} from 'node:fs';
import { createHash, randomBytes } from 'node:crypto';
import { dirname } from 'node:path';
import { isDeepStrictEqual } from 'node:util';
import { fold } from './fold.mjs';
import { compactRecords } from './append.mjs';
import { validateRecord } from './schema.mjs';
import { renderSlice } from './provision.mjs';

const VERSION = 1;
const PREFIX_BYTES = 64;

function ownedRegular(st, uid, wantDir) {
  if (st.isSymbolicLink()) return false;
  if (wantDir ? !st.isDirectory() : !st.isFile()) return false;
  return uid == null || st.uid === uid;
}

function readRange(fd, start, end) {
  const buf = Buffer.alloc(end - start);
  let got = 0;
  while (got < buf.length) {
    const n = readSync(fd, buf, got, buf.length - got, start + got);
    if (n === 0) break;
    got += n;
  }
  return buf.subarray(0, got);
}

function prefixHash(fd, off) {
  return createHash('sha256').update(readRange(fd, Math.max(0, off - PREFIX_BYTES), off)).digest('hex');
}

function parseLine(buf) {
  const s = buf.toString('utf8').trim();
  if (!s) return { skip: true };
  let r;
  try { r = JSON.parse(s); } catch { return { malformed: true }; }
  if (!r || typeof r !== 'object' || Array.isArray(r) || typeof r.ts !== 'string') return { foreign: true };
  return { rec: r };
}

function loadIndex(indexPath, uid) {
  let st;
  try { st = lstatSync(indexPath); } catch (e) {
    if (e.code === 'ENOENT') return { entries: new Map() };
    throw e;
  }
  if (!ownedRegular(st, uid, false)) return null;
  let raw;
  try { raw = readFileSync(indexPath, 'utf8'); } catch { return { entries: new Map() }; }
  try {
    const lines = raw.split('\n');
    const header = JSON.parse(lines[0]);
    const entries = new Map();
    for (let i = 1; i < lines.length; i++) {
      const ln = lines[i];
      if (!ln) continue;
      const tab = ln.indexOf('\t');
      if (tab < 0) throw new Error('bad index line');
      const key = JSON.parse(ln.slice(0, tab));
      if (typeof key !== 'string') throw new Error('bad index key');
      entries.set(key, { line: ln, recs: null });
    }
    return { header, entries };
  } catch {
    return { entries: new Map() };
  }
}

function recsOf(entry) {
  if (!entry.recs) {
    const recs = JSON.parse(entry.line.slice(entry.line.indexOf('\t') + 1));
    if (!Array.isArray(recs)) throw new Error('bad index records');
    entry.recs = recs;
  }
  return entry.recs;
}

function writeIndex(indexPath, header, entries) {
  const parts = [JSON.stringify(header)];
  for (const [key, e] of entries) {
    if (e.line == null) e.line = JSON.stringify(key) + '\t' + JSON.stringify(e.recs);
    parts.push(e.line);
  }
  const tmp = `${indexPath}.${process.pid}.${randomBytes(6).toString('hex')}.tmp`;
  try {
    writeFileSync(tmp, parts.join('\n') + '\n', { flag: 'wx', mode: 0o600 });
    renameSync(tmp, indexPath);
  } finally {
    try { unlinkSync(tmp); } catch { }
  }
}

function merge(entries, pending) {
  for (const [key, add] of pending) {
    const e = entries.get(key) ?? { line: null, recs: [] };
    const all = recsOf(e).concat(add);
    let kept = compactRecords(all);
    if (kept.length !== all.length && !isDeepStrictEqual(fold(kept).items[key], fold(all).items[key])) kept = all;
    entries.set(key, { line: null, recs: kept });
  }
  pending.clear();
}

export function sliceFromIndex(ledgerPath, indexPath, key, opts = {}) {
  const {
    checkpointMs = 500, chunkBytes = 4 << 20, onChunk = null,
    uid = typeof process.getuid === 'function' ? process.getuid() : null,
  } = opts;
  if (!ownedRegular(lstatSync(dirname(indexPath)), uid, true)) return null;
  let fd;
  try { fd = openSync(ledgerPath, 'r'); } catch { return null; }
  try {
    const fst = fstatSync(fd);
    const size = fst.size;
    const loaded = loadIndex(indexPath, uid);
    if (!loaded) return null;
    let { header, entries } = loaded;
    const same = header && header.v === VERSION && header.ledger === ledgerPath
      && header.dev === fst.dev && header.ino === fst.ino
      && Number.isSafeInteger(header.off) && header.off >= 0 && header.off <= size
      && header.prefix === prefixHash(fd, header.off);
    if (!same) {
      header = { v: VERSION, ledger: ledgerPath, dev: fst.dev, ino: fst.ino, off: 0, prefix: prefixHash(fd, 0), state: 'ok' };
      entries = new Map();
    }
    if (header.state === 'foreign') return null;

    const start = header.off;
    let off = start;
    let pos = start;
    let carry = Buffer.alloc(0);
    let dirty = !same;
    const pending = new Map();
    let lastCheckpoint = Date.now();
    const checkpoint = () => {
      merge(entries, pending);
      header.off = off;
      header.prefix = prefixHash(fd, off);
      writeIndex(indexPath, header, entries);
      dirty = false;
      lastCheckpoint = Date.now();
    };

    while (header.state === 'ok' && pos < size) {
      const chunk = readRange(fd, pos, Math.min(size, pos + chunkBytes));
      if (chunk.length === 0) break;
      pos += chunk.length;
      const buf = carry.length ? Buffer.concat([carry, chunk]) : chunk;
      let ls = 0;
      let nl;
      while ((nl = buf.indexOf(0x0a, ls)) !== -1) {
        const p = parseLine(buf.subarray(ls, nl));
        ls = nl + 1;
        if (p.malformed) { header.state = 'malformed'; dirty = true; break; }
        if (p.foreign) { header.state = 'foreign'; dirty = true; break; }
        off = pos - buf.length + ls;
        dirty = true;
        if (p.skip) continue;
        const r = p.rec;
        if (!validateRecord(r).ok || r.kind === 'collection') continue;
        if (!pending.has(r.key)) pending.set(r.key, []);
        pending.get(r.key).push(r);
      }
      carry = header.state === 'ok' ? Buffer.from(buf.subarray(ls)) : Buffer.alloc(0);
      if (dirty && Date.now() - lastCheckpoint >= checkpointMs) checkpoint();
      if (onChunk) onChunk();
    }
    if (dirty) checkpoint();
    const bytesRead = pos - start;

    if (header.state === 'foreign') return null;
    if (header.state === 'malformed') return { out: '', bytesRead };
    const extra = [];
    if (carry.length) {
      const p = parseLine(carry);
      if (p.malformed) return { out: '', bytesRead };
      if (p.foreign) return null;
      if (p.rec && validateRecord(p.rec).ok && p.rec.kind !== 'collection' && p.rec.key === key) extra.push(p.rec);
    }
    const e = entries.get(key);
    const records = (e ? recsOf(e) : []).concat(extra);
    return { out: renderSlice(fold(records), key), bytesRead };
  } finally {
    closeSync(fd);
  }
}
