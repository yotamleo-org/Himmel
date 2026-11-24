// scripts/where-are-we/tests/append.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, existsSync, writeFileSync, readFileSync, chmodSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { readRecords } from '../lib/ledger.mjs';
import { acquireLock, appendRecords, compactRecords, compactLedger } from '../lib/append.mjs';
import { makeTmpDir } from '../../lib/test-tmpdir.mjs';

const VALID1 = { ts: '2026-06-21T00:00:00Z', source: 'jira', key: 'HIMMEL-1', kind: 'ticket' };
const VALID2 = { ts: '2026-06-21T00:01:00Z', source: 'pr', key: '#42', kind: 'pr' };
const INVALID_NO_KIND = { ts: '2026-06-21T00:02:00Z', source: 'jira', key: 'HIMMEL-2' };

// Test 1: writes valid records
test('appendRecords writes valid records and returns correct stats', () => {
  const dir = makeTmpDir('waw-append-');
  const ledger = join(dir, 'ledger.jsonl');
  const result = appendRecords(ledger, [VALID1, VALID2]);
  assert.equal(result.appended, 2);
  assert.equal(result.dropped, 0);
  assert.deepEqual(result.dropReasons, []);
  const recs = readRecords(ledger);
  assert.equal(recs.length, 2);
  assert.equal(recs[0].key, 'HIMMEL-1');
  assert.equal(recs[1].key, '#42');
});

// Test 2: validate-before-append drops invalid records
test('appendRecords drops invalid records and records drop reasons', () => {
  const dir = makeTmpDir('waw-append-');
  const ledger = join(dir, 'ledger.jsonl');
  const batch = [VALID1, INVALID_NO_KIND, VALID2];
  const result = appendRecords(ledger, batch);
  assert.equal(result.appended, 2);
  assert.equal(result.dropped, 1);
  assert.equal(result.dropReasons.length, 1);
  assert.equal(result.dropReasons[0].index, 1);
  assert.match(result.dropReasons[0].error, /kind/);
  const recs = readRecords(ledger);
  assert.equal(recs.length, 2);
  // Ensure the invalid record is NOT in the file
  assert.ok(!recs.some(r => r.key === INVALID_NO_KIND.key && !r.kind));
});

// Test 3: the lock is the collection's kernel lock; no directory lock exists
test('acquireLock takes the collection flock; release frees it; no directory lock is made', () => {
  const dir = makeTmpDir('waw-append-');
  const ledger = join(dir, 'ledger.jsonl');

  const lock = acquireLock(ledger);
  assert.ok(existsSync(ledger + '.collect.lock'), 'the permanent flock file exists');
  assert.ok(!existsSync(ledger + '.lock'), 'no directory lock');
  assert.throws(() => acquireLock(ledger, { timeoutMs: 100 }), /lock timeout/);
  lock.release();
  acquireLock(ledger, { timeoutMs: 100 }).release();
});

// Test 4: lock lifecycle (black-box via appendRecords)
test('appendRecords releases the lock on success', () => {
  const dir = makeTmpDir('waw-append-');
  const ledger = join(dir, 'ledger.jsonl');
  appendRecords(ledger, [VALID1]);
  assert.ok(!existsSync(ledger + '.lock'), 'no directory lock is left');
  acquireLock(ledger, { timeoutMs: 100 }).release();
});

// Test 5: mutual exclusion — appendRecords times out while another holder has the lock
test('appendRecords throws on timeout when the lock is held and appends nothing', () => {
  const dir = makeTmpDir('waw-append-');
  const ledger = join(dir, 'ledger.jsonl');
  const held = acquireLock(ledger);
  try {
    assert.throws(() => appendRecords(ledger, [VALID1], { timeoutMs: 200 }), /lock timeout/);
    assert.ok(!existsSync(ledger), 'nothing was appended');
    assert.equal(appendRecords(ledger, [VALID1], { held: true }).appended, 1, 'the holder appends under its own lock');
  } finally { held.release(); }
});

// Test 6.1: a missing directory surfaces its own error immediately
test('acquireLock re-throws a missing parent directory immediately (ENOENT branch)', () => {
  const dir = makeTmpDir('waw-append-');
  const ledger = join(dir, 'no-such-subdir', 'ledger.jsonl');
  const before = Date.now();
  assert.throws(() => acquireLock(ledger, { timeoutMs: 5000 }), { code: 'ENOENT' });
  assert.ok(Date.now() - before < 1000, 'must not wait out the timeout');
});

// Test 6: release-on-error — the lock is released even when the append throws
test('appendRecords releases the lock when append throws (finally path)', () => {
  const dir = makeTmpDir('waw-append-');
  // Make the ledger path itself a directory so appendFileSync throws EISDIR
  const ledger = join(dir, 'ledger.jsonl');
  mkdirSync(ledger);
  assert.throws(() => appendRecords(ledger, [VALID1]), { code: 'EISDIR' });
  acquireLock(ledger, { timeoutMs: 100 }).release();
});

// compactRecords: only a later write by the same key+source+kind supersedes an earlier one
test('compactRecords drops a superseded write, keeps other sources and each key first and last', () => {
  const r = (ts, source, over = {}) => ({ ts, source, key: 'K-1', kind: 'ticket', ...over });
  const recs = [
    r('2026-06-22T10:00:00Z', 'jira', { status: 'a' }),         // first of K-1: kept
    r('2026-06-22T10:01:00Z', 'jira', { status: 'b' }),         // superseded by the next jira status: dropped
    r('2026-06-22T10:02:00Z', 'handover', { next_action: 'x' }), // superseded by the later handover next_action: dropped
    r('2026-06-22T10:03:00Z', 'git', { branch: 'b' }),          // other source, no later branch write: kept
    r('2026-06-22T10:04:00Z', 'jira', { status: 'c' }),         // latest jira status: kept
    r('2026-06-22T10:05:00Z', 'handover', { next_action: 'y' }), // last of K-1 and latest next_action: kept
  ];
  const kept = compactRecords(recs);
  assert.deepEqual(kept.map((x) => x.ts), [recs[0].ts, recs[3].ts, recs[4].ts, recs[5].ts]);
  assert.deepEqual(compactRecords(kept), kept, 'compacting a compacted list drops nothing more');
});

test('compactLedger keeps the ledger file mode', () => {
  const dir = makeTmpDir('waw-append-');
  const ledger = join(dir, 'ledger.jsonl');
  const rec = { ts: '2026-06-22T10:00:00Z', source: 'jira', key: 'K-1', kind: 'ticket', status: 'a' };
  writeFileSync(ledger, [rec, { ...rec, ts: '2026-06-22T10:01:00Z', status: 'b' }, { ...rec, ts: '2026-06-22T10:02:00Z', status: 'c' }]
    .map((x) => JSON.stringify(x) + '\n').join(''));
  chmodSync(ledger, 0o600);
  assert.equal(compactLedger(ledger).dropped, 1);
  assert.equal(statSync(ledger).mode & 0o777, 0o600);
});

// compactLedger takes the writers' lock: a held lock blocks it and nothing is touched
test('compactLedger times out on a held lock and leaves the ledger and the foreign lock alone', () => {
  const dir = makeTmpDir('waw-append-');
  const ledger = join(dir, 'ledger.jsonl');
  const old = { ts: '2026-06-22T10:00:00Z', source: 'jira', key: 'K-1', kind: 'ticket', status: 'a' };
  writeFileSync(ledger, [old, { ...old, ts: '2026-06-22T10:01:00Z', status: 'b' }, { ...old, ts: '2026-06-22T10:02:00Z', status: 'c' }]
    .map((x) => JSON.stringify(x) + '\n').join(''));
  const before = readFileSync(ledger, 'utf8');
  const held = acquireLock(ledger);
  assert.throws(() => compactLedger(ledger, { timeoutMs: 100 }), /lock timeout/);
  assert.equal(readFileSync(ledger, 'utf8'), before);
  held.release();
  assert.deepEqual(compactLedger(ledger), { kept: 2, dropped: 1 });
});
