// scripts/where-are-we/tests/provision.test.mjs — unit tests for lib/provision.mjs (pure)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { writeFileSync, readFileSync, statSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { fold } from '../lib/fold.mjs';
import { readRecords } from '../lib/ledger.mjs';
import { main } from '../provision.mjs';
import { makeTmpDir } from '../../lib/test-tmpdir.mjs';
import { UsageError } from '../lib/errors.mjs';
import { renderSlice, buildEmitRecord } from '../lib/provision.mjs';

const NOW = '2026-06-22T12:00:00Z';
const rec = (over) => ({ ts: NOW, source: 'jira', key: 'HIMMEL-9', kind: 'ticket', ...over });

// --- renderSlice -------------------------------------------------------------

test('renderSlice: miss (no item for key) → empty string', () => {
  const state = fold([rec({ key: 'HIMMEL-9', status: 'in-progress' })]);
  assert.equal(renderSlice(state, 'HIMMEL-404'), '');
});

test('renderSlice: substantive hit (status) → item card', () => {
  const state = fold([rec({ key: 'HIMMEL-9', status: 'in-progress' })]);
  const out = renderSlice(state, 'HIMMEL-9');
  assert.match(out, /# HIMMEL-9/);
  assert.match(out, /- status: in-progress/);
});

test('renderSlice: hit with next_action (handover) → shows next', () => {
  const state = fold([
    rec({ key: 'HIMMEL-9', status: 'in-progress' }),
    { ts: NOW, source: 'handover', key: 'HIMMEL-9', kind: 'ticket', next_action: 'write the tests' },
  ]);
  const out = renderSlice(state, 'HIMMEL-9');
  assert.match(out, /- next: write the tests/);
});

test('renderSlice: hit with blockers (handover) → shows blockers', () => {
  const state = fold([
    rec({ key: 'HIMMEL-9', status: 'blocked' }),
    { ts: NOW, source: 'handover', key: 'HIMMEL-9', kind: 'ticket', blockers: ['waiting on VM', 'cred'] },
  ]);
  const out = renderSlice(state, 'HIMMEL-9');
  assert.match(out, /- blockers: waiting on VM; cred/);
});

test('renderSlice: hit with a lock (git) → shows lock', () => {
  const state = fold([
    rec({ key: 'HIMMEL-9', status: 'in-progress' }),
    { ts: NOW, source: 'git', key: 'HIMMEL-9', kind: 'ticket', lock: 'worktree locked' },
  ]);
  const out = renderSlice(state, 'HIMMEL-9');
  assert.match(out, /- lock: worktree locked/);
});

// Substantive WITHOUT status: the OR-chain's reason to exist — a key Jira has
// not seen yet but that carries a handover next_action / blockers, or a git lock.
// (Guards against a refactor collapsing the predicate to `it.status != null`.)
test('renderSlice: substantive via next_action only, status absent → card', () => {
  const state = fold([{ ts: NOW, source: 'handover', key: 'HIMMEL-9', kind: 'ticket', next_action: 'do the thing' }]);
  assert.equal(state.items['HIMMEL-9'].status, undefined); // precondition: no status
  assert.match(renderSlice(state, 'HIMMEL-9'), /- next: do the thing/);
});

test('renderSlice: substantive via blockers only, status absent → card', () => {
  const state = fold([{ ts: NOW, source: 'handover', key: 'HIMMEL-9', kind: 'ticket', blockers: ['stuck'] }]);
  assert.equal(state.items['HIMMEL-9'].status, undefined);
  assert.match(renderSlice(state, 'HIMMEL-9'), /- blockers: stuck/);
});

test('renderSlice: substantive via lock only, status absent → card', () => {
  const state = fold([{ ts: NOW, source: 'git', key: 'HIMMEL-9', kind: 'ticket', lock: 'worktree locked' }]);
  assert.equal(state.items['HIMMEL-9'].status, undefined);
  assert.match(renderSlice(state, 'HIMMEL-9'), /- lock: worktree locked/);
});

test('renderSlice: contentless hit (awaiting_operator only, no status/next/blockers/lock) → empty', () => {
  // An item seen only via a bare awaiting_operator emit folds to an item with no
  // status/next/blockers/locks — renderItem would emit "# KEY\n- status: —", a
  // contentless block. renderSlice must treat that as a miss (decision (b), #6).
  const state = fold([
    { ts: NOW, source: 'handover', key: 'HIMMEL-9', kind: 'ticket', awaiting_operator: ['decide X'] },
  ]);
  assert.equal(state.items['HIMMEL-9'].status, undefined); // precondition
  assert.equal(renderSlice(state, 'HIMMEL-9'), '');
});

// --- buildEmitRecord ---------------------------------------------------------

test('buildEmitRecord: next_action only → handover/ticket record with next_action', () => {
  const r = buildEmitRecord({ key: 'HIMMEL-1', next_action: 'ship it' }, NOW);
  assert.deepEqual(r, { ts: NOW, source: 'handover', key: 'HIMMEL-1', kind: 'ticket', next_action: 'ship it' });
});

test('buildEmitRecord: blockers (array) only', () => {
  const r = buildEmitRecord({ key: 'HIMMEL-1', blockers: ['a', 'b'] }, NOW);
  assert.deepEqual(r.blockers, ['a', 'b']);
  assert.equal(r.source, 'handover');
});

test('buildEmitRecord: awaiting only', () => {
  const r = buildEmitRecord({ key: 'HIMMEL-1', awaiting_operator: ['decide'] }, NOW);
  assert.deepEqual(r.awaiting_operator, ['decide']);
});

test('buildEmitRecord: clearBlockers → blockers []', () => {
  const r = buildEmitRecord({ key: 'HIMMEL-1', clearBlockers: true }, NOW);
  assert.deepEqual(r.blockers, []);
});

test('buildEmitRecord: clearNext → next_action null', () => {
  const r = buildEmitRecord({ key: 'HIMMEL-1', clearNext: true }, NOW);
  assert.equal(r.next_action, null);
});

test('buildEmitRecord: no key → UsageError', () => {
  assert.throws(() => buildEmitRecord({ next_action: 'x' }, NOW), UsageError);
});

test('buildEmitRecord: empty (no field) → UsageError', () => {
  assert.throws(() => buildEmitRecord({ key: 'HIMMEL-1' }, NOW), UsageError);
});

test('buildEmitRecord: set + clear conflict on same field → UsageError', () => {
  assert.throws(() => buildEmitRecord({ key: 'HIMMEL-1', blockers: ['a'], clearBlockers: true }, NOW), UsageError);
  assert.throws(() => buildEmitRecord({ key: 'HIMMEL-1', next_action: 'x', clearNext: true }, NOW), UsageError);
  assert.throws(() => buildEmitRecord({ key: 'HIMMEL-1', awaiting_operator: ['x'], clearAwaiting: true }, NOW), UsageError);
});

// --- fold round-trips (the write actually lands / is correctly scoped) --------

test('fold round-trip (positive): emitted blockers land in the folded item', () => {
  const r = buildEmitRecord({ key: 'HIMMEL-1', blockers: ['x'] }, NOW);
  const state = fold([r]);
  assert.deepEqual(state.items['HIMMEL-1'].blockers, ['x']);
});

test('fold round-trip (clear): a later-ts clear erases the field', () => {
  const set = buildEmitRecord({ key: 'HIMMEL-1', blockers: ['x'] }, '2026-06-22T10:00:00Z');
  const clr = buildEmitRecord({ key: 'HIMMEL-1', clearBlockers: true }, '2026-06-22T11:00:00Z');
  const state = fold([set, clr]);
  assert.equal(state.items['HIMMEL-1'].blockers, undefined);
});

test('authority guard: a status from source=handover does NOT win (emit is scoped)', () => {
  // Proves emit is correctly limited to the three handover-authoritative fields:
  // a hand-built handover record carrying status would vanish in fold (jira owns
  // status for kind:ticket). buildEmitRecord never emits status — this guards the
  // contract the scoping relies on.
  const stray = { ts: NOW, source: 'handover', key: 'HIMMEL-1', kind: 'ticket', status: 'in-progress' };
  const state = fold([stray]);
  assert.equal(state.items['HIMMEL-1'].status, undefined);
});

// --- compact: bound the ledger's growth, slice byte-identical ----------------
// Fixture ledgers only, in temp dirs; never the live ledger.

const jl = (recs) => recs.map((r) => JSON.stringify(r)).join('\n') + '\n';
const slices = (ledger, keys) => keys.map((k) => main(['slice', '--ledger', ledger, '--for', k]));

function churnedLedger() {
  const recs = [];
  for (let i = 0; i < 40; i++) {
    const ts = `2026-06-22T10:${String(i).padStart(2, '0')}:00Z`;
    recs.push({ ts, source: 'jira', key: 'HIMMEL-1', kind: 'ticket', status: i < 39 ? 'in-progress' : 'in-review' });
    recs.push({ ts, source: 'handover', key: 'HIMMEL-1', kind: 'ticket', next_action: `step ${i}` });
    recs.push({ ts, source: 'pr', key: '#42', kind: 'pr', status: i % 2 ? 'open' : 'draft', pr: 42 });
    recs.push({ ts, source: 'git', key: '#42', kind: 'pr', branch: `fix/b${i}` });
  }
  recs.push({ ts: '2026-06-22T11:00:00Z', source: 'handover', key: 'HIMMEL-1', kind: 'ticket', blockers: ['vm'] });
  recs.push({ ts: '2026-06-22T11:01:00Z', source: 'handover', key: 'HIMMEL-1', kind: 'ticket', blockers: [] });
  recs.push({ ts: '2026-06-22T11:02:00Z', source: 'handover', key: 'HIMMEL-1', kind: 'ticket', status: 'ignored' }); // not authoritative
  recs.push({ ts: '2026-06-22T11:03:00Z', source: 'handover', key: 'HIMMEL-2', kind: 'ticket', awaiting_operator: ['decide'] });
  recs.push({ ts: '2026-06-22T11:04:00Z', source: 'jira', key: 'HIMMEL-3', kind: 'ticket', status: 'blocked', lock: 'vm-1' });
  recs.push({ ts: '2026-06-22T11:05:00Z', source: 'jira', key: 'HIMMEL-4', kind: 'ticket' }); // contentless
  recs.push({ ts: '2026-06-22T11:07:00Z', source: 'jira', key: 'HIMMEL-5' }); // no kind: fold skips it
  return recs;
}

test('compact: every key slice is byte-identical before and after, and the ledger shrinks', () => {
  const dir = makeTmpDir('waw-compact-');
  const ledger = join(dir, 'ledger.jsonl');
  writeFileSync(ledger, jl(churnedLedger()));
  const keys = ['HIMMEL-1', '#42', 'HIMMEL-2', 'HIMMEL-3', 'HIMMEL-4', 'HIMMEL-5', 'HIMMEL-404'];
  const before = slices(ledger, keys);
  const stateBefore = fold(readRecords(ledger));
  const sizeBefore = statSync(ledger).size;
  assert.match(before[0], /- status: in-review/);

  const out = main(['compact', '--ledger', ledger]);
  assert.match(out, /^kept=\d+ dropped=\d+$/);

  assert.deepEqual(slices(ledger, keys), before);
  const stateAfter = fold(readRecords(ledger));
  assert.deepEqual(stateAfter, stateBefore);
  assert.deepEqual(Object.keys(stateAfter.items), Object.keys(stateBefore.items));
  assert.ok(statSync(ledger).size < sizeBefore / 4, 'the churned ledger shrinks to a fraction');
});

test('compact: a record appended after compaction folds as it would have on the full ledger', () => {
  const dir = makeTmpDir('waw-compact-');
  const full = join(dir, 'full.jsonl');
  const comp = join(dir, 'comp.jsonl');
  writeFileSync(full, jl(churnedLedger()));
  writeFileSync(comp, jl(churnedLedger()));
  main(['compact', '--ledger', comp]);
  // an older-than-latest ts: it must beat only what it beat before
  for (const l of [full, comp]) {
    main(['emit', '--ledger', l, '--key', 'HIMMEL-1', '--next-action', 'late write', '--now', '2026-06-22T10:20:30Z']);
  }
  assert.deepEqual(slices(comp, ['HIMMEL-1', '#42']), slices(full, ['HIMMEL-1', '#42']));
});

test('compact: random churn (ties, out-of-order ts, clears, kind changes) keeps the whole fold identical', () => {
  let seed = 12345;
  const rnd = (n) => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed % n; };
  const pick = (a) => a[rnd(a.length)];
  const recs = [];
  for (let i = 0; i < 600; i++) {
    const r = {
      ts: `2026-06-22T10:00:${String(rnd(30)).padStart(2, '0')}Z`,
      source: pick(['jira', 'handover', 'pr', 'git']),
      key: pick(['A-1', 'A-2', 'A-3', '#7']),
      kind: pick(['ticket', 'ticket', 'pr', 'handover-item']),
    };
    if (rnd(2)) r.status = pick(['todo', 'doing', 'done', null]);
    if (rnd(3) === 0) r.next_action = pick(['x', 'y', null]);
    if (rnd(3) === 0) r.blockers = pick([['b'], ['c', 'd'], []]);
    if (rnd(4) === 0) r.awaiting_operator = pick([['q'], []]);
    if (rnd(5) === 0) r.lock = pick(['l1', null]);
    if (rnd(5) === 0) r.branch = pick(['b1', 'b2', null]);
    recs.push(r);
  }
  const dir = makeTmpDir('waw-compact-');
  const ledger = join(dir, 'ledger.jsonl');
  writeFileSync(ledger, jl(recs));
  const keys = ['A-1', 'A-2', 'A-3', '#7'];
  const before = slices(ledger, keys);
  const stateBefore = fold(readRecords(ledger));
  main(['compact', '--ledger', ledger]);
  assert.deepEqual(slices(ledger, keys), before);
  const stateAfter = fold(readRecords(ledger));
  assert.deepEqual(stateAfter, stateBefore);
  assert.deepEqual(Object.keys(stateAfter.items), Object.keys(stateBefore.items));
  assert.ok(readRecords(ledger).length < recs.length);
});

test('compact: keeps the original beside it, and a second run changes nothing', () => {
  const dir = makeTmpDir('waw-compact-');
  const ledger = join(dir, 'ledger.jsonl');
  writeFileSync(ledger, jl(churnedLedger()));
  const original = readFileSync(ledger, 'utf8');
  main(['compact', '--ledger', ledger]);
  assert.equal(readFileSync(ledger + '.pre-compact', 'utf8'), original);
  const once = readFileSync(ledger, 'utf8');
  const mtime = statSync(ledger).mtimeMs;
  assert.match(main(['compact', '--ledger', ledger]), /dropped=0$/);
  assert.equal(readFileSync(ledger, 'utf8'), once);
  assert.equal(statSync(ledger).mtimeMs, mtime, 'a no-op compaction does not touch the ledger');
});

test('compact: a malformed ledger is left untouched, and a missing one is not created', () => {
  const dir = makeTmpDir('waw-compact-');
  const bad = join(dir, 'bad.jsonl');
  writeFileSync(bad, '{"ts":"2026-06-22T10:00:00Z","source":"jira","key":"A-1","kind":"ticket"}\nnot json\n');
  assert.throws(() => main(['compact', '--ledger', bad]), /malformed JSON/);
  assert.equal(readFileSync(bad, 'utf8').split('\n')[1], 'not json');
  assert.ok(!existsSync(bad + '.pre-compact'));
  assert.ok(!existsSync(bad + '.lock'), 'the lock is released on failure');
  const none = join(dir, 'none.jsonl');
  assert.match(main(['compact', '--ledger', none]), /kept=0 dropped=0/);
  assert.ok(!existsSync(none));
});

test('compact: --ledger is required', () => {
  assert.throws(() => main(['compact']), UsageError);
});
