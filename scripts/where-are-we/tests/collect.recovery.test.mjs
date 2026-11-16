import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, statSync, mkdirSync, unlinkSync, existsSync, utimesSync } from 'node:fs';
import { join } from 'node:path';
import * as collector from '../collect.mjs';
import { jiraRecords } from '../lib/collect.mjs';
import { fold, inFlight } from '../lib/fold.mjs';
import { renderDock } from '../lib/dock.mjs';
import { readRecords } from '../lib/ledger.mjs';
import { makeTmpDir } from '../../lib/test-tmpdir.mjs';

const OLD = '2026-11-15T00:00:00.000Z';
const NOW = '2026-11-16T12:00:00.000Z';
const ticket = (key) => ({ ts: OLD, source: 'jira', kind: 'ticket', key, status: 'in-progress' });
const fixture = (records = []) => {
  const dir = makeTmpDir('waw-recovery-');
  const ledger = join(dir, 'ledger.jsonl');
  writeFileSync(ledger, records.map(JSON.stringify).join('\n') + '\n');
  return { dir, ledger, marker: join(dir, '.refreshed-at') };
};
const quietReaders = { readJira: () => [], readPRs: () => [], readWorktrees: () => '' };

// A default-25 or single-200 read leaves historical activity alive.
test('251 active keys converge through bounded all-status queries and paged discovery', () => {
  const keys = Array.from({ length: 251 }, (_, i) => `HIMMEL-${i + 1}`);
  const { ledger } = fixture(keys.map(ticket));
  const requests = [];
  collector.main(['--ledger', ledger, '--now', NOW], { readers: {
    ...quietReaders,
    readJira: (active) => collector.readJira(active, { readPage: (request) => {
      requests.push(request);
      assert.ok(request.limit <= 100);
      if (request.jql) {
        const chunk = request.jql.match(/HIMMEL-\d+/g);
        assert.ok(chunk.length <= request.limit);
        return { issues: chunk.map((key) => ({ key, fields: { status: { name: 'Closed', statusCategory: { key: 'done', name: 'Done' } } } })), isLast: true };
      }
      if (!request.nextPageToken) return { issues: [{ key: 'HIMMEL-900', fields: { status: { name: 'In Progress', statusCategory: { key: 'indeterminate' } } } }], nextPageToken: 'next' };
      return { issues: [{ key: 'HIMMEL-901', fields: { status: { name: 'In Progress', statusCategory: { key: 'indeterminate' } } } }], isLast: true };
    } }),
  } });
  const state = fold(readRecords(ledger));
  assert.deepEqual(inFlight(state).map((it) => it.key).sort(), ['HIMMEL-900', 'HIMMEL-901']);
  assert.equal(requests.filter((r) => r.jql).length, 3);
  assert.equal(requests.filter((r) => !r.jql).length, 2);
});

// Recent discovery alone cannot clear an old operator obligation.
test('old tracked PRs outside discovery are batch-refreshed and terminal reads clear awaiting', () => {
  const prior = Array.from({ length: 61 }, (_, i) => ({ ts: OLD, source: 'pr', kind: 'pr', key: `#${i + 1}`, status: 'open', branch: 'feat/x', awaiting_operator: ['merge'] }));
  const { ledger } = fixture(prior);
  const batches = [];
  collector.main(['--ledger', ledger, '--now', NOW], { readers: {
    ...quietReaders,
    readPRs: (active) => collector.readPRs(active, {
      discover: () => [{ number: 999, state: 'OPEN', headRefName: 'feat/x' }],
      readBatch: (numbers) => {
        batches.push(numbers);
        return numbers.map((number) => ({ number, state: number === 61 ? 'CLOSED' : 'MERGED', headRefName: 'feat/x' }));
      },
    }),
  } });
  const state = fold(readRecords(ledger));
  assert.equal(state.items['#1'].status, 'merged');
  assert.equal(state.items['#61'].status, 'closed');
  assert.equal(state.awaiting_operator.length, 0);
  assert.deepEqual(inFlight(state).map((it) => it.key), ['#999']);
  assert.equal(batches.length, 3);
  assert.ok(batches.every((b) => b.length <= 25));
});

test('terminal Jira categories handle new names while legacy and unknown statuses stay compatible', () => {
  const records = jiraRecords([
    { key: 'HIMMEL-1', status: 'Closed', statusCategory: 'Done' },
    { key: 'HIMMEL-2', status: 'In Public', statusCategory: 'done' },
    { key: 'HIMMEL-3', status: "Won't Do", statusCategory: 'Done' },
    { key: 'HIMMEL-4', status: 'Investigating', statusCategory: 'In Progress' },
    { key: 'HIMMEL-5', status: 'Unrecognized' },
    { key: 'HIMMEL-6', status: 'Done' },
  ], NOW);
  assert.deepEqual(inFlight(fold(records)).map((it) => it.key), ['HIMMEL-4', 'HIMMEL-5']);
  const out = renderDock(records, { mode: 'branch', name: 'fix/HIMMEL-2-x' }, Date.parse(NOW), null);
  assert.match(out, /# Where are we/);
  assert.doesNotMatch(out, /\*\*HIMMEL-2\*\*/);
  const reopened = fold([...records, ...jiraRecords([{ key: 'HIMMEL-1', status: 'Investigating' }], '2026-11-17T00:00:00Z')]);
  assert.ok(inFlight(reopened).some((it) => it.key === 'HIMMEL-1'));
});

test('locked worktree footprint participates in the current Jira status read', () => {
  const { ledger } = fixture();
  let keys;
  collector.main(['--ledger', ledger, '--now', NOW], { readers: {
    ...quietReaders,
    readWorktrees: () => 'worktree /scratch\nbranch refs/heads/fix/luna-44-work\nlocked active\n',
    readJira: (active) => { keys = active; return [{ key: 'LUNA-44', status: 'Closed', statusCategory: 'Done' }]; },
  } });
  assert.deepEqual(keys, ['LUNA-44']);
  assert.equal(inFlight(fold(readRecords(ledger))).length, 0);
});

test('partial/missing reads preserve prior states and expose errors with last good times', () => {
  const { ledger, marker } = fixture([ticket('HIMMEL-1'), ticket('HIMMEL-2'), { ts: OLD, source: 'pr', key: '#4', kind: 'pr', status: 'open', awaiting_operator: ['merge'] }]);
  const good = { ...quietReaders, readJira: () => [{ key: 'HIMMEL-1', status: 'In Progress' }, { key: 'HIMMEL-2', status: 'In Progress' }], readPRs: () => [{ number: 4, state: 'OPEN', headRefName: 'feat/x' }] };
  collector.main(['--ledger', ledger, '--now', OLD, '--marker', marker], { readers: good });
  const oldMarker = statSync(marker).mtimeMs;
  collector.main(['--ledger', ledger, '--now', NOW, '--marker', marker], { readers: {
    ...quietReaders,
    readJira: () => ({ rows: [{ key: 'HIMMEL-1', status: 'Closed', statusCategory: 'Done' }], errors: ['page failed: unavailable'] }),
    readPRs: () => [],
  } });
  const records = readRecords(ledger);
  const state = fold(records);
  assert.equal(state.items['HIMMEL-1'].status, 'closed');
  assert.equal(state.items['HIMMEL-2'].status, 'in-progress');
  assert.equal(state.items['#4'].status, 'open');
  assert.equal(statSync(marker).mtimeMs, oldMarker);
  assert.equal(state.sources.jira.observed_at, OLD);
  assert.equal(state.sources.pr.observed_at, OLD);
  assert.equal(state.sources.git.observed_at, NOW);
  const out = renderDock(records, { mode: 'global' }, Date.parse(NOW), oldMarker);
  assert.match(out.split('\n')[0], /stale sources:.*jira.*pr/);
  assert.match(out, /jira.*stale.*page failed/i);
  assert.match(out, /pr.*stale.*#4/i);
  assert.ok(inFlight(state).some((it) => it.key === 'HIMMEL-2'));
});

test('failed and missing PR batches keep unknown obligations while other batches converge', () => {
  const prior = Array.from({ length: 51 }, (_, i) => ({ ts: OLD, source: 'pr', kind: 'pr', key: `#${i + 1}`, status: 'open', awaiting_operator: ['merge'] }));
  const { ledger, marker } = fixture(prior);
  collector.main(['--ledger', ledger, '--marker', marker, '--now', NOW], { readers: {
    ...quietReaders,
    readPRs: (active) => collector.readPRs(active, {
      discover: () => { throw new Error('discovery unavailable'); },
      readBatch: (numbers) => {
        if (numbers[0] === 26) throw new Error('batch interrupted');
        return numbers.filter((n) => n !== 51).map((number) => ({ number, state: 'MERGED', headRefName: 'fix/x' }));
      },
    }),
  } });
  const state = fold(readRecords(ledger));
  assert.equal(state.items['#1'].status, 'merged');
  assert.equal(state.items['#26'].status, 'open');
  assert.equal(state.items['#51'].status, 'open');
  assert.equal(state.awaiting_operator.length, 26);
  assert.equal(state.sources.pr.observed_at, undefined);
  assert.match(state.sources.pr.errors.join(' '), /discovery unavailable.*batch interrupted.*26 identities unresolved/);
  assert.equal(state.sources.pr.error_count, 28);
  assert.throws(() => statSync(marker), /ENOENT/);
});

test('Jira cursor loop cannot hang or certify a complete source', () => {
  let pages = 0;
  const result = collector.readJira([], { readPage: () => {
    pages++;
    return { issues: [], nextPageToken: 'loop' };
  } });
  assert.equal(pages, 2);
  assert.match(result.errors.join(' '), /repeated Jira page token/);
});

test('Jira category is authoritative only from Jira and does not erase legacy fields', () => {
  const state = fold([
    { ...ticket('HIMMEL-1'), status_category: 'in-progress' },
    { ts: NOW, key: 'HIMMEL-1', kind: 'ticket', source: 'handover', status_category: 'done', next_action: 'investigate', blockers: ['waiting'] },
  ]);
  assert.equal(inFlight(state).length, 1);
  assert.equal(state.items['HIMMEL-1'].next_action, 'investigate');
  assert.deepEqual(state.items['HIMMEL-1'].blockers, ['waiting']);
});

test('failed page retains successful pages without claiming freshness', () => {
  let calls = 0;
  const result = collector.readJira(['HIMMEL-1', 'HIMMEL-2'], { readPage: (r) => {
    calls++;
    if (r.nextPageToken) throw new Error('page interrupted');
    if (r.jql) return { issues: [{ key: 'HIMMEL-1', fields: { status: { name: 'Closed', statusCategory: { key: 'done' } } } }], nextPageToken: 'failed' };
    return { issues: [], isLast: true };
  } });
  assert.equal(calls, 3);
  assert.equal(result.rows[0].key, 'HIMMEL-1');
  assert.match(result.errors.join(' '), /page interrupted/);
});

test('reader exception preserves other sources and prevents successful freshness', () => {
  const { ledger, marker } = fixture([ticket('HIMMEL-1')]);
  collector.main(['--ledger', ledger, '--now', NOW, '--marker', marker], { readers: { ...quietReaders, readJira: () => { throw new Error('interrupted'); }, readPRs: () => [{ number: 8, state: 'MERGED', headRefName: 'feat/x' }] } });
  const state = fold(readRecords(ledger));
  assert.equal(state.items['HIMMEL-1'].status, 'in-progress');
  assert.equal(state.items['#8'].status, 'merged');
  assert.equal(state.sources.jira.observed_at, undefined);
  assert.match(state.sources.jira.errors.join(' '), /interrupted/);
  assert.throws(() => statSync(marker), /ENOENT/);
});

test('persistence failure leaves successful marker untouched', () => {
  const { dir, ledger, marker } = fixture();
  writeFileSync(marker, 'last good');
  utimesSync(marker, new Date(OLD), new Date(OLD));
  const before = statSync(marker).mtimeMs;
  const directoryLedger = join(dir, 'not-a-file');
  assert.throws(() => collector.main(['--ledger', directoryLedger, '--marker', marker, '--now', NOW], { readers: {
    ...quietReaders, readJira: () => { if (existsSync(directoryLedger)) unlinkSync(directoryLedger); mkdirSync(directoryLedger); return []; },
  } }), /EISDIR/);
  assert.equal(statSync(marker).mtimeMs, before);
  assert.equal(readFileSync(marker, 'utf8'), 'last good');
  collector.main(['--ledger', ledger, '--marker', marker, '--now', NOW], { readers: quietReaders });
  assert.equal(statSync(marker).mtimeMs, Date.parse(NOW));
});

test('dropped source records cannot certify that source or the successful refresh', () => {
  const { ledger, marker } = fixture();
  collector.main(['--ledger', ledger, '--marker', marker, '--now', NOW], { readers: {
    ...quietReaders, readJira: () => [{ key: '', status: 'Done' }, { key: 'HIMMEL-1', status: 'In Progress' }],
  } });
  const state = fold(readRecords(ledger));
  assert.equal(state.items['HIMMEL-1'].status, 'in-progress');
  assert.equal(state.sources.jira.observed_at, undefined);
  assert.match(state.sources.jira.errors.join(' '), /missing required field: key/);
  assert.throws(() => statSync(marker), /ENOENT/);
});

test('partial GraphQL check pages preserve unknown prior obligation rather than declaring it cleared', () => {
  const { ledger } = fixture([{ ts: OLD, source: 'pr', kind: 'pr', key: '#4', status: 'open', awaiting_operator: ['last known green'] }]);
  const requests = [];
  const run = (_command, args) => {
    requests.push(args);
    if (args[0] === 'repo') return JSON.stringify({ nameWithOwner: 'example/project' });
    return JSON.stringify({ data: { repository: { p4: {
      number: 4, state: 'OPEN', headRefName: 'fix/x', title: 'old PR', mergeable: 'MERGEABLE', mergeStateStatus: 'CLEAN',
      commits: { nodes: [{ commit: { statusCheckRollup: { contexts: {
        nodes: [{ status: 'COMPLETED', conclusion: 'SUCCESS' }], pageInfo: { hasNextPage: true },
      } } } }] },
    } } } });
  };
  collector.main(['--ledger', ledger, '--now', NOW], { readers: {
    ...quietReaders,
    readPRs: (active) => collector.readPRs(active, { discover: () => [], readBatch: (numbers) => collector.readPRBatch(numbers, run) }),
  } });
  const state = fold(readRecords(ledger));
  assert.equal(state.items['#4'].status, 'open');
  assert.deepEqual(state.items['#4'].awaiting_operator, ['last known green']);
  assert.match(state.sources.pr.errors.join(' '), /incomplete check rollup/);
  assert.equal(requests.length, 2, 'one repository lookup and one batched API call');
  const query = requests[1].find((a) => a.startsWith('query='));
  assert.match(query, /pullRequest\(number:4\)/);
});
