// scripts/where-are-we/tests/slice-index.test.mjs — the incremental slice index
// (lib/slice-index.mjs) must print exactly what the full read prints
// (renderSlice(fold(readRecords(ledger)), key)) on every path: cold build,
// append, out-of-order ts, resume after a kill, and every fallback.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  writeFileSync, appendFileSync, readFileSync, renameSync, truncateSync, symlinkSync,
  statSync, existsSync, mkdirSync, chmodSync,
} from 'node:fs';
import { join } from 'node:path';
import { fold } from '../lib/fold.mjs';
import { readRecords } from '../lib/ledger.mjs';
import { renderSlice } from '../lib/provision.mjs';
import { sliceFromIndex } from '../lib/slice-index.mjs';
import { main } from '../provision.mjs';
import { makeTmpDir } from '../../lib/test-tmpdir.mjs';

const line = (r) => JSON.stringify(r) + '\n';
const T = (n) => `2026-01-01T00:00:${String(n).padStart(2, '0')}Z`;

function full(ledger, key) {
  let records;
  try { records = readRecords(ledger); } catch { return ''; }
  return renderSlice(fold(records), key);
}

function setup(lines) {
  const dir = makeTmpDir('wa-sidx-');
  const ledger = join(dir, 'ledger.jsonl');
  const idxDir = join(dir, 'cache');
  mkdirSync(idxDir, { mode: 0o700 });
  const index = join(idxDir, 'slice-index.ndjson');
  writeFileSync(ledger, lines.join(''));
  return { dir, ledger, index };
}

const BASE = [
  line({ ts: T(5), source: 'jira', key: 'A-1', kind: 'ticket', status: 'in-progress' }),
  line({ ts: T(6), source: 'handover', key: 'A-1', kind: 'ticket', next_action: 'write it' }),
  line({ ts: T(7), source: 'jira', key: 'B-2', kind: 'ticket', status: 'to-do' }),
  line({ ts: T(8), source: 'git', key: 'B-2', kind: 'ticket', lock: 'wt locked' }),
  line({ ts: T(9), source: 'handover', key: 'C-3', kind: 'ticket', awaiting_operator: ['x'] }),
  line({ ts: T(9), source: 'jira', kind: 'collection', key: 'jira', errors: [] }),
  line({ ts: T(10), source: 'jira', key: 'A-1', kind: 'ticket', status: 'in-review' }),
];
const KEYS = ['A-1', 'B-2', 'C-3', 'Z-404'];

function assertAllEqual(L, keys = KEYS) {
  for (const k of keys) {
    const r = sliceFromIndex(L.ledger, L.index, k);
    const got = r === null ? full(L.ledger, k) : r.out;
    assert.equal(got, full(L.ledger, k), `key ${k}`);
  }
}

test('cold start: no index → same text as the full read for a hit, a miss and a contentless hit', () => {
  const L = setup(BASE);
  for (const k of KEYS) {
    const r = sliceFromIndex(L.ledger, L.index, k);
    assert.notEqual(r, null);
    assert.equal(r.out, full(L.ledger, k), `key ${k}`);
  }
  assert.equal(sliceFromIndex(L.ledger, L.index, 'C-3').out, '');
  assert.equal(sliceFromIndex(L.ledger, L.index, 'Z-404').out, '');
  assert.ok(existsSync(L.index));
  assert.equal(statSync(L.index).mode & 0o777, 0o600);
});

test('append: after one appended record only the appended bytes are read', () => {
  const L = setup(BASE);
  sliceFromIndex(L.ledger, L.index, 'A-1');
  const add = line({ ts: T(20), source: 'jira', key: 'A-1', kind: 'ticket', status: 'done' });
  appendFileSync(L.ledger, add);
  const r = sliceFromIndex(L.ledger, L.index, 'A-1');
  assert.equal(r.bytesRead, Buffer.byteLength(add));
  assert.equal(r.out, full(L.ledger, 'A-1'));
  assert.match(r.out, /- status: done/);
  assert.equal(sliceFromIndex(L.ledger, L.index, 'A-1').bytesRead, 0);
});

test('out-of-order ts: an older record appended after newer ones gives fold\'s output', () => {
  const L = setup(BASE);
  sliceFromIndex(L.ledger, L.index, 'A-1');
  appendFileSync(L.ledger, line({ ts: T(1), source: 'jira', key: 'A-1', kind: 'ticket', status: 'stale-old' }));
  appendFileSync(L.ledger, line({ ts: T(10), source: 'jira', key: 'A-1', kind: 'ticket', status: 'tie-later' }));
  appendFileSync(L.ledger, line({ ts: T(2), source: 'handover', key: 'A-1', kind: 'ticket', next_action: null }));
  assertAllEqual(L);
  assert.match(sliceFromIndex(L.ledger, L.index, 'A-1').out, /- status: tie-later/);
});

test('fold equality: every key of an out-of-order fixture, with an append between runs', () => {
  const recs = [];
  const sources = ['jira', 'handover', 'git'];
  for (let i = 0; i < 300; i++) {
    const r = { ts: T((i * 37) % 60), source: sources[i % 3], key: `K-${i % 17}`, kind: i % 11 ? 'ticket' : 'pr' };
    if (i % 4 === 0) r.status = `s${i}`;
    if (i % 5 === 0) r.next_action = i % 10 ? `n${i}` : null;
    if (i % 7 === 0) r.blockers = i % 14 ? [`b${i}`] : [];
    if (i % 9 === 0) r.lock = i % 18 ? `l${i}` : null;
    if (i % 13 === 0) r.status_category = 'done';
    recs.push(line(r));
  }
  const L = setup(recs.slice(0, 200));
  const keys = [...Array(17).keys()].map((i) => `K-${i}`).concat(['K-99']);
  assertAllEqual(L, keys);
  appendFileSync(L.ledger, recs.slice(200).join(''));
  for (const k of keys) {
    const viaCli = main(['slice', '--ledger', L.ledger, '--for', k, '--index', L.index]);
    assert.equal(viaCli, full(L.ledger, k), `key ${k}`);
  }
});

test('timeout: a run killed after a checkpoint leaves progress the next run resumes', () => {
  const big = [];
  for (let i = 0; i < 400; i++) big.push(line({ ts: T(i % 60), source: 'jira', key: `K-${i % 5}`, kind: 'ticket', status: `s${i}` }));
  const L = setup(big);
  const size = statSync(L.ledger).size;
  let chunks = 0;
  assert.throws(() => sliceFromIndex(L.ledger, L.index, 'K-1', {
    chunkBytes: 1024, checkpointMs: 0, onChunk: () => { if (++chunks === 3) throw new Error('killed'); },
  }), /killed/);
  assert.ok(existsSync(L.index), 'a checkpoint was written before the kill');
  const r = sliceFromIndex(L.ledger, L.index, 'K-1');
  assert.ok(r.bytesRead > 0 && r.bytesRead < size, `resumed: read ${r.bytesRead} of ${size}`);
  assert.equal(r.out, full(L.ledger, 'K-1'));
});

test('fallback: a replaced ledger (new inode, the compaction shape) forces a rebuild', () => {
  const L = setup(BASE);
  sliceFromIndex(L.ledger, L.index, 'A-1');
  const tmp = L.ledger + '.new';
  writeFileSync(tmp, BASE.slice(0, 2).join(''));
  renameSync(tmp, L.ledger);
  const r = sliceFromIndex(L.ledger, L.index, 'A-1');
  assert.equal(r.bytesRead, statSync(L.ledger).size);
  assertAllEqual(L);
});

test('fallback: a shrunk ledger (same inode) forces a rebuild', () => {
  const L = setup(BASE);
  sliceFromIndex(L.ledger, L.index, 'A-1');
  truncateSync(L.ledger, Buffer.byteLength(BASE[0] + BASE[1]));
  const r = sliceFromIndex(L.ledger, L.index, 'A-1');
  assert.equal(r.bytesRead, statSync(L.ledger).size);
  assertAllEqual(L);
});

test('fallback: a rewritten prefix (same inode, grown) fails the prefix check and rebuilds', () => {
  const L = setup(BASE);
  sliceFromIndex(L.ledger, L.index, 'A-1');
  const txt = readFileSync(L.ledger, 'utf8').replace('in-review', 'in-REVIEW');
  writeFileSync(L.ledger, txt + line({ ts: T(30), source: 'jira', key: 'B-2', kind: 'ticket', status: 'x' }));
  const r = sliceFromIndex(L.ledger, L.index, 'A-1');
  assert.equal(r.bytesRead, statSync(L.ledger).size);
  assert.match(r.out, /in-REVIEW/);
  assertAllEqual(L);
});

test('fallback: a torn tail (no newline) prints today\'s empty answer; completed, it is read', () => {
  const L = setup(BASE);
  sliceFromIndex(L.ledger, L.index, 'A-1');
  appendFileSync(L.ledger, '{"ts":"2026-01-01T00:00:40Z","source":"jira","key":"A-1"');
  assert.equal(sliceFromIndex(L.ledger, L.index, 'A-1').out, '');
  assertAllEqual(L);
  appendFileSync(L.ledger, ',"kind":"ticket","status":"healed"}');
  assert.match(sliceFromIndex(L.ledger, L.index, 'A-1').out, /- status: healed/);
  assertAllEqual(L);
  appendFileSync(L.ledger, '\n');
  assertAllEqual(L);
});

test('fallback: a malformed complete line prints today\'s empty answer for every key', () => {
  const L = setup(BASE);
  sliceFromIndex(L.ledger, L.index, 'A-1');
  appendFileSync(L.ledger, 'not json {{{\n');
  assert.equal(sliceFromIndex(L.ledger, L.index, 'A-1').out, '');
  appendFileSync(L.ledger, line({ ts: T(50), source: 'jira', key: 'B-2', kind: 'ticket', status: 'y' }));
  assertAllEqual(L);
});

test('fallback: a record with a non-string ts hands the slice to the full read', () => {
  const L = setup(BASE);
  appendFileSync(L.ledger, line({ ts: 5, source: 'jira', key: 'A-1', kind: 'ticket', status: 'num' }));
  assert.equal(sliceFromIndex(L.ledger, L.index, 'A-1'), null);
  for (const k of KEYS) {
    assert.equal(main(['slice', '--ledger', L.ledger, '--for', k, '--index', L.index]), full(L.ledger, k));
  }
});

test('fallback: a symlinked index is never trusted and its target never written', () => {
  const L = setup(BASE);
  const forged = join(L.dir, 'forged');
  writeFileSync(forged, 'forged');
  symlinkSync(forged, L.index);
  const r = sliceFromIndex(L.ledger, L.index, 'A-1');
  assert.equal(r, null);
  assert.equal(readFileSync(forged, 'utf8'), 'forged');
  assert.equal(main(['slice', '--ledger', L.ledger, '--for', 'A-1', '--index', L.index]), full(L.ledger, 'A-1'));
});

test('fallback: a foreign-owned index is never trusted', () => {
  const L = setup(BASE);
  writeFileSync(L.index, 'whatever\n');
  const r = sliceFromIndex(L.ledger, L.index, 'A-1', { uid: process.getuid() + 1 });
  assert.equal(r, null);
});

test('fallback: an unreadable index or one with a garbage body falls back to the full read', () => {
  const L = setup(BASE);
  sliceFromIndex(L.ledger, L.index, 'A-1');
  writeFileSync(L.index, readFileSync(L.index, 'utf8') + '{garbage\n');
  for (const k of KEYS) {
    assert.equal(main(['slice', '--ledger', L.ledger, '--for', k, '--index', L.index]), full(L.ledger, k));
  }
  chmodSync(L.index, 0o000);
  for (const k of KEYS) {
    assert.equal(main(['slice', '--ledger', L.ledger, '--for', k, '--index', L.index]), full(L.ledger, k));
  }
});

test('missing ledger: empty answer, like the full read', () => {
  const L = setup([]);
  const gone = join(L.dir, 'nope.jsonl');
  assert.equal(main(['slice', '--ledger', gone, '--for', 'A-1', '--index', L.index]), '');
});
