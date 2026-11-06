// scripts/where-are-we/lib/append.mjs
import { mkdirSync, rmdirSync, writeFileSync, renameSync, linkSync, unlinkSync, statSync, chmodSync } from 'node:fs';
import { isDeepStrictEqual } from 'node:util';
import { REQUIRED, validateRecord } from './schema.mjs';
import { appendRecord, readRecords } from './ledger.mjs';
import { fold } from './fold.mjs';

/**
 * Acquire an advisory lock by creating a directory at `ledgerPath + '.lock'`.
 * Uses a synchronous spin-sleep (Atomics.wait) so the lock is never leaked
 * across an await boundary.
 *
 * @param {string} ledgerPath
 * @param {{ timeoutMs?: number, backoffMs?: number }} opts
 */
export function acquireLock(ledgerPath, opts = {}) {
  const { timeoutMs = 10000, backoffMs = 20 } = opts;
  const lockPath = ledgerPath + '.lock';
  const deadline = Date.now() + timeoutMs;
  while (true) {
    try {
      mkdirSync(lockPath);
      return; // success
    } catch (err) {
      if (err.code !== 'EEXIST') throw err; // non-lock error — surface immediately
      if (Date.now() >= deadline) {
        throw new Error('append: lock timeout for ' + ledgerPath);
      }
      // Synchronous sleep — must not be async to prevent lock leaks
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, backoffMs);
    }
  }
}

/**
 * Release the advisory lock by removing the lock directory.
 * Silently ignores ENOENT (already released).
 *
 * @param {string} ledgerPath
 */
export function releaseLock(ledgerPath) {
  try {
    rmdirSync(ledgerPath + '.lock');
  } catch (err) {
    if (err.code !== 'ENOENT') throw err;
  }
}

/**
 * Validate each record, drop invalid ones, then append all valid records
 * under an advisory lock.
 *
 * @param {string} ledgerPath
 * @param {object[]} records
 * @param {object} opts  - forwarded to acquireLock (timeoutMs, backoffMs)
 * @returns {{ appended: number, dropped: number, dropReasons: Array<{index: number, error: string}> }}
 */
export function appendRecords(ledgerPath, records, opts = {}) {
  const valid = [];
  const dropReasons = [];
  for (let i = 0; i < records.length; i++) {
    const result = validateRecord(records[i]);
    if (result.ok) {
      valid.push(records[i]);
    } else {
      dropReasons.push({ index: i, error: result.error });
    }
  }
  acquireLock(ledgerPath, opts);
  try {
    for (const r of valid) {
      appendRecord(ledgerPath, r);
    }
  } finally {
    releaseLock(ledgerPath);
  }
  return { appended: valid.length, dropped: dropReasons.length, dropReasons };
}

/**
 * Which records can be dropped without changing what fold() builds.
 * A write is dead when a LATER record of the same key, source and kind carries the
 * same field: those two records have the same authority, so the later one lands
 * whenever the earlier did, and neither lands when the field is not theirs to set.
 * Kept besides the live writes: each key's first record (item insertion order, which
 * orders locks and awaiting_operator) and last record (the item's kind). Records are
 * kept verbatim and in order, so a record appended later folds exactly as it would
 * have on the full ledger, whatever its ts.
 *
 * @param {object[]} records  in file order
 * @returns {object[]} the records to keep, in file order
 */
export function compactRecords(records) {
  // fold()'s own order: stable by ts, so a tie keeps file order.
  const order = records.map((_, i) => i).filter((i) => validateRecord(records[i]).ok)
    .sort((a, b) => (records[a].ts < records[b].ts ? -1 : records[a].ts > records[b].ts ? 1 : 0));
  const keep = new Set();
  const seenFirst = new Set();
  for (const i of order) {
    if (!seenFirst.has(records[i].key)) { seenFirst.add(records[i].key); keep.add(i); }
  }
  const covered = new Map(); // [key, source, kind] -> fields a later record already writes
  const seenLast = new Set();
  for (let n = order.length - 1; n >= 0; n--) {
    const r = records[order[n]];
    const id = JSON.stringify([r.key, r.source, r.kind]);
    const cov = covered.get(id) ?? new Set();
    covered.set(id, cov);
    const fields = Object.keys(r).filter((f) => !REQUIRED.includes(f));
    if (!seenLast.has(r.key) || fields.some((f) => !cov.has(f))) keep.add(order[n]);
    seenLast.add(r.key);
    for (const f of fields) cov.add(f);
  }
  return records.filter((_, i) => keep.has(i));
}

/**
 * Rewrite the ledger without its dead records, under the writers' lock. Refuses
 * (leaving the ledger untouched) on a malformed ledger, or if the result would not
 * fold to the same state, key order included. The original stays beside it as
 * `<ledger>.pre-compact` (a hard link, replaced on the next compaction).
 *
 * @param {string} ledgerPath
 * @param {object} opts  - forwarded to acquireLock
 * @returns {{ kept: number, dropped: number }}
 */
export function compactLedger(ledgerPath, opts = {}) {
  acquireLock(ledgerPath, opts);
  const tmp = ledgerPath + '.compact.tmp';
  try {
    const records = readRecords(ledgerPath); // throws on a malformed line
    const kept = compactRecords(records);
    const dropped = records.length - kept.length;
    if (dropped === 0) return { kept: kept.length, dropped };
    const before = fold(records);
    const after = fold(kept);
    if (!isDeepStrictEqual(before, after)
        || !isDeepStrictEqual(Object.keys(before.items), Object.keys(after.items))) {
      throw new Error('compact: refused, the compacted ledger would fold differently');
    }
    writeFileSync(tmp, kept.map((r) => JSON.stringify(r) + '\n').join(''));
    chmodSync(tmp, statSync(ledgerPath).mode & 0o7777); // the new file keeps the ledger's own mode
    try { unlinkSync(ledgerPath + '.pre-compact'); } catch (e) { if (e.code !== 'ENOENT') throw e; }
    linkSync(ledgerPath, ledgerPath + '.pre-compact');
    renameSync(tmp, ledgerPath);
    return { kept: kept.length, dropped };
  } finally {
    try { unlinkSync(tmp); } catch { /* already renamed or never written */ }
    releaseLock(ledgerPath);
  }
}
