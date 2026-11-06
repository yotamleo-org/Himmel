// scripts/where-are-we/tests/append.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, existsSync, writeFileSync, readFileSync, chmodSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { readRecords } from '../lib/ledger.mjs';
import { acquireLock, releaseLock, appendRecords, compactRecords, compactLedger } from '../lib/append.mjs';
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

// Test 3: lock lifecycle (direct)
test('acquireLock creates lock dir; releaseLock removes it; release on absent is no-op', () => {
  const dir = makeTmpDir('waw-append-');
  const ledger = join(dir, 'ledger.jsonl');
  const lockDir = ledger + '.lock';

  acquireLock(ledger);
  assert.ok(existsSync(lockDir), 'lock dir should exist after acquireLock');

  releaseLock(ledger);
  assert.ok(!existsSync(lockDir), 'lock dir should not exist after releaseLock');

  // releaseLock on absent lock is a no-op — must not throw
  assert.doesNotThrow(() => releaseLock(ledger));
});

// Test 4: lock lifecycle (black-box via appendRecords)
test('appendRecords releases lock on success', () => {
  const dir = makeTmpDir('waw-append-');
  const ledger = join(dir, 'ledger.jsonl');
  const lockDir = ledger + '.lock';
  appendRecords(ledger, [VALID1]);
  assert.ok(!existsSync(lockDir), 'lock dir should not exist after appendRecords returns');
});

// Test 5: mutual exclusion — acquireLock times out when lock is held
test('acquireLock throws on timeout when lock is already held', () => {
  const dir = makeTmpDir('waw-append-');
  const ledger = join(dir, 'ledger.jsonl');
  const lockDir = ledger + '.lock';

  // Pre-create the lock dir to simulate a held lock
  mkdirSync(lockDir);

  let thrown = null;
  try {
    acquireLock(ledger, { timeoutMs: 200, backoffMs: 20 });
  } catch (e) {
    thrown = e;
  }
  assert.ok(thrown !== null, 'expected acquireLock to throw on timeout');
  assert.match(thrown.message, /lock timeout/);
  // The held dir must NOT have been deleted
  assert.ok(existsSync(lockDir), 'held lock dir should still exist after timeout');
});

// Test 6.1: non-EEXIST mkdir error surfaces immediately (does NOT spin-wait/timeout)
test('acquireLock re-throws non-EEXIST mkdir errors immediately (ENOENT branch)', () => {
  const dir = makeTmpDir('waw-append-');
  // Place the ledger inside a sub-directory that does NOT exist.
  // mkdirSync(ledgerPath + '.lock') will fail with ENOENT because the parent
  // directory 'no-such-subdir' is missing — that is a non-EEXIST code and must
  // be re-thrown immediately without entering the retry/timeout loop.
  const ledger = join(dir, 'no-such-subdir', 'ledger.jsonl');

  let thrown = null;
  const before = Date.now();
  try {
    // Use a long timeout — if the test reaches the timeout the ENOENT branch
    // is broken (not re-throwing immediately).
    acquireLock(ledger, { timeoutMs: 5000, backoffMs: 20 });
  } catch (e) {
    thrown = e;
  }
  const elapsed = Date.now() - before;

  assert.ok(thrown !== null, 'acquireLock must throw when parent dir is missing');
  assert.equal(thrown.code, 'ENOENT', 'thrown error must be ENOENT, not a lock timeout');
  assert.ok(elapsed < 1000, `acquireLock must throw immediately, not after timeout (elapsed ${elapsed}ms)`);
});

// Test 6: release-on-error — finally block releases lock even when appendFileSync throws
test('appendRecords releases lock when append throws (finally path)', () => {
  const dir = makeTmpDir('waw-append-');
  // Make the ledger path itself a directory so appendFileSync throws EISDIR
  const ledger = join(dir, 'ledger.jsonl');
  mkdirSync(ledger);
  const lockDir = ledger + '.lock';

  let thrown = null;
  try {
    appendRecords(ledger, [VALID1]);
  } catch (e) {
    thrown = e;
  }
  assert.ok(thrown !== null, 'expected appendRecords to throw when ledger is a dir');
  // Lock must be released by the finally block
  assert.ok(!existsSync(lockDir), 'lock dir should be gone after error (finally released it)');
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
  mkdirSync(ledger + '.lock');
  assert.throws(() => compactLedger(ledger, { timeoutMs: 100, backoffMs: 20 }), /lock timeout/);
  assert.equal(readFileSync(ledger, 'utf8'), before);
  assert.ok(existsSync(ledger + '.lock'), 'the other holder keeps its lock');
  releaseLock(ledger);
  assert.deepEqual(compactLedger(ledger), { kept: 2, dropped: 1 });
});
