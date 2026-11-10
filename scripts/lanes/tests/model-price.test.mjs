// scripts/lanes/tests/model-price.test.mjs - a per-model dollar price table and the
// pricer that costs a call from it. Fixtures live in a temp dir; nothing here reads the real HOME.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import * as mp from '../model-price.mjs';
import { loadPrices, priceFor, priceCall, priceTranscripts } from '../model-price.mjs';

const CLI = fileURLToPath(new URL('../model-price.mjs', import.meta.url));
const M = 1_000_000;
const rows = loadPrices();
const sol = priceFor('gpt-6.1-sol', rows);
const opus = priceFor('claude-opus-5-5', rows);

// The fixture call of the ticket Proof: 1,000,000 input and 100,000 output tokens.
const FIXTURE_USAGE = { input_tokens: M, output_tokens: 100_000 };

test('(a) the table has a gpt-6.1-sol row with input, output and cache read rates', () => {
  assert.ok(sol, 'no gpt-6.1-sol row');
  for (const k of ['input', 'output', 'cacheRead']) {
    assert.ok(Number.isFinite(sol[k]) && sol[k] > 0, `gpt-6.1-sol ${k} rate missing`);
  }
});

test('(b) a gpt-6.1-sol call costs exactly the rates in its row', () => {
  const expected = (M * sol.input + 100_000 * sol.output) / M;
  const r = priceCall({ model: 'gpt-6.1-sol', usage: FIXTURE_USAGE }, rows);
  assert.equal(r.priced, true);
  assert.ok(Math.abs(r.usd - expected) < 1e-9, `${r.usd} vs ${expected}`);
});

test('(c) a codex-lane sol call is not costed at the Opus figure; an unknown model is unpriced, never Opus', () => {
  const asSol = priceCall({ model: 'gpt-6.1-sol', usage: FIXTURE_USAGE }, rows);
  const asOpus = priceCall({ model: 'claude-opus-5-5', usage: FIXTURE_USAGE }, rows);
  assert.notEqual(asSol.usd, asOpus.usd);

  const unknown = priceCall({ model: 'gpt-9-imaginary', usage: FIXTURE_USAGE }, rows);
  assert.equal(unknown.priced, false);
  assert.equal(unknown.usd, null);
  assert.notEqual(unknown.usd, asOpus.usd);
});

test('(d) control: an Opus call still costs the Opus rate to the cent', () => {
  // Opus 5.5 is $4 in / $20 out per MTok (docs/internals/prompt-cache.md pricing): 1M in + 100k out = $6.00.
  const r = priceCall({ model: 'claude-opus-5-5', usage: FIXTURE_USAGE }, rows);
  assert.equal(r.usd.toFixed(2), '6.00');
  assert.equal(opus.input, 4);
  assert.equal(opus.output, 20);
});

test('first prefix match wins and cache reads and writes are priced from their own columns', () => {
  const t = [
    { prefix: 'm-a', input: 1, output: 2, cacheRead: 0.5, cacheWrite5m: 3, cacheWrite1h: 4 },
    { prefix: 'm', input: 9, output: 9, cacheRead: 9, cacheWrite5m: 9, cacheWrite1h: 9 },
  ];
  assert.equal(priceFor('m-abc', t).input, 1);
  assert.equal(priceFor('m-zzz', t).input, 9);
  assert.equal(priceFor('x', t), null);
  const usage = {
    input_tokens: M, output_tokens: M, cache_read_input_tokens: M,
    cache_creation_input_tokens: 2 * M,
    cache_creation: { ephemeral_5m_input_tokens: M, ephemeral_1h_input_tokens: M },
  };
  assert.equal(priceCall({ model: 'm-abc', usage }, t).usd, 1 + 2 + 0.5 + 3 + 4);
  // no per-TTL split: the whole cache write is a 5-minute write
  assert.equal(priceCall({ model: 'm-abc', usage: { cache_creation_input_tokens: M } }, t).usd, 3);
});

function writeTranscript(dir, name, records) {
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, name), records.map((r) => JSON.stringify(r)).join('\n') + '\n');
}
const rec = (id, model, usage, ts = '2026-11-05T10:00:00.000Z') =>
  ({ type: 'assistant', timestamp: ts, requestId: `req-${id}`, message: { id: `msg-${id}`, model, usage } });

test('transcripts mode sums per model, counts a repeated message once and reports unpriced calls on their own line', () => {
  const root = mkdtempSync(join(tmpdir(), 'model-price-'));
  try {
    writeTranscript(join(root, 'proj'), 's1.jsonl', [
      rec(1, 'gpt-6.1-sol', FIXTURE_USAGE),
      rec(1, 'gpt-6.1-sol', FIXTURE_USAGE), // streamed repeat of the same message
      rec(2, 'gpt-6.1-terra', FIXTURE_USAGE),
      rec(3, 'claude-opus-5-5', FIXTURE_USAGE),
      rec(4, 'gpt-6.1-sol', FIXTURE_USAGE, '2026-10-01T10:00:00.000Z'), // before --since
      { type: 'user', message: { content: 'hi' } },
    ]);
    const res = priceTranscripts(root, rows, { since: '2026-11-01' });
    assert.equal(res.perModel['gpt-6.1-sol'].calls, 1);
    assert.ok(Math.abs(res.perModel['gpt-6.1-sol'].usd - priceCall({ model: 'gpt-6.1-sol', usage: FIXTURE_USAGE }, rows).usd) < 1e-9);
    assert.equal(res.perModel['claude-opus-5-5'].usd.toFixed(2), '6.00');
    assert.deepEqual(res.unpriced, { 'gpt-6.1-terra': 1 });

    const cli = spawnSync('node', [CLI, 'transcripts', root, '--since', '2026-11-01'], { encoding: 'utf8' });
    assert.equal(cli.status, 0, cli.stderr);
    assert.match(cli.stdout, /^unpriced model=gpt-6\.1-terra calls=1$/m);
    assert.match(cli.stdout, /^gpt-6\.1-sol calls=1 /m);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('--price-as restates every call at one model row (the "before" figure), and the Opus row count is printed', () => {
  const root = mkdtempSync(join(tmpdir(), 'model-price-'));
  try {
    writeTranscript(join(root, 'proj'), 's1.jsonl', [rec(1, 'gpt-6.1-sol', FIXTURE_USAGE)]);
    const cli = spawnSync('node', [CLI, 'transcripts', root, '--price-as', 'claude-opus-5-5'], { encoding: 'utf8' });
    assert.equal(cli.status, 0, cli.stderr);
    assert.match(cli.stdout, /^total usd=6\.00 /m);
    const plain = spawnSync('node', [CLI, 'transcripts', root], { encoding: 'utf8' });
    assert.match(plain.stdout, /^opus-priced calls=0$/m);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('call CLI prices one call and exits 2 for an unpriced model', () => {
  const ok = spawnSync('node', [CLI, 'call', '--model', 'claude-opus-5-5', '--input', String(M), '--output', '100000'], { encoding: 'utf8' });
  assert.equal(ok.status, 0, ok.stderr);
  assert.equal(ok.stdout.trim(), '6.00');
  const bad = spawnSync('node', [CLI, 'call', '--model', 'gpt-9-imaginary', '--input', '1'], { encoding: 'utf8' });
  assert.equal(bad.status, 2);
  assert.match(bad.stdout, /^unpriced model=gpt-9-imaginary$/m);
});

test('a message repeated by streaming is priced at its last (final) usage', () => {
  const root = mkdtempSync(join(tmpdir(), 'model-price-'));
  try {
    writeTranscript(join(root, 'proj'), 's1.jsonl', [
      rec(1, 'gpt-6.1-sol', { input_tokens: M, output_tokens: 5 }),
      rec(1, 'gpt-6.1-sol', FIXTURE_USAGE),
    ]);
    const res = priceTranscripts(root, rows);
    assert.equal(res.perModel['gpt-6.1-sol'].calls, 1);
    assert.ok(Math.abs(res.perModel['gpt-6.1-sol'].usd - priceCall({ model: 'gpt-6.1-sol', usage: FIXTURE_USAGE }, rows).usd) < 1e-9);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('a malformed token count or --since date is an argument error, never a successful zero or NaN', () => {
  for (const args of [['call', '--model', 'gpt-6.1-sol', '--input', 'abc'], ['call', '--model', 'gpt-6.1-sol', '--input', '-1'],
    ['transcripts', tmpdir(), '--since', 'not-a-date']]) {
    const r = spawnSync('node', [CLI, ...args], { encoding: 'utf8' });
    assert.equal(r.status, 64, `${args.join(' ')}: ${r.stdout}${r.stderr}`);
  }
});

test('a transcript record with a malformed usage count is excluded and reported, never summed into the total as NaN', () => {
  const root = mkdtempSync(join(tmpdir(), 'model-price-'));
  try {
    writeTranscript(join(root, 'proj'), 's1.jsonl', [
      rec(1, 'gpt-6.1-sol', FIXTURE_USAGE),
      rec(2, 'gpt-6.1-sol', { input_tokens: 'bad', output_tokens: 5 }),
      rec(3, 'gpt-6.1-sol', { input_tokens: -1 }),
    ]);
    const res = priceTranscripts(root, rows);
    assert.equal(res.perModel['gpt-6.1-sol'].calls, 1);
    assert.ok(Number.isFinite(res.total));
    assert.equal(res.malformed, 2);
    const cli = spawnSync('node', [CLI, 'transcripts', root], { encoding: 'utf8' });
    assert.match(cli.stdout, /^malformed calls=2$/m);
    assert.doesNotMatch(cli.stdout, /NaN/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('--price-as with no price row and an empty token count are argument errors', () => {
  for (const args of [['transcripts', tmpdir(), '--price-as', 'gpt-9-imaginary'], ['call', '--model', 'gpt-6.1-sol', '--input', ''],
    ['call', '--model', 'gpt-6.1-sol', '--input', '1', '--output', ' ']]) {
    const r = spawnSync('node', [CLI, ...args], { encoding: 'utf8' });
    assert.equal(r.status, 64, `${JSON.stringify(args)}: ${r.stdout}${r.stderr}`);
  }
});

const mkRec = ({ id, req, model = 'claude-opus-5-5', usage, ts = '2026-11-05T10:00:00.000Z' }) => {
  const message = { model, usage };
  if (id !== undefined) message.id = id;
  const r = { type: 'assistant', timestamp: ts, message };
  if (req !== undefined) r.requestId = req;
  return r;
};
const U = (o) => ({ input_tokens: 1, output_tokens: o });
function foldAll(items) {
  let state = new Map();
  const outs = [];
  for (const [r, off] of items) {
    const o = mp.foldUsageCall(state, r, off);
    state = new Map(state).set(o.key, o.next);
    outs.push(o);
  }
  return { state, outs };
}
function withTranscripts(files, fn) {
  const root = mkdtempSync(join(tmpdir(), 'model-price-'));
  try {
    for (const [name, records] of Object.entries(files)) writeTranscript(join(root, 'proj'), name, records);
    return fn(root);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}
const nanoOf = (usage, prefix) => {
  const row = priceFor(prefix, rows);
  const n = (v) => BigInt(Math.round(v * 1000));
  return BigInt(usage.input_tokens ?? 0) * n(row.input) + BigInt(usage.output_tokens ?? 0) * n(row.output);
};
const OPUS = 'claude-opus-5-5';

test('normalizeUsage: finite non-negative safe integers; an explicit split wins; omitted counters are zero', () => {
  assert.deepEqual(mp.normalizeUsage({ input_tokens: 3, output_tokens: 4 }),
    { input: 3, output: 4, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0 });
  assert.deepEqual(mp.normalizeUsage({ cache_creation_input_tokens: 7 }),
    { input: 0, output: 0, cacheRead: 0, cacheWrite5m: 7, cacheWrite1h: 0 });
  assert.deepEqual(mp.normalizeUsage({ cache_read_input_tokens: 2, cache_creation_input_tokens: 9,
    cache_creation: { ephemeral_5m_input_tokens: 4, ephemeral_1h_input_tokens: 5 } }),
  { input: 0, output: 0, cacheRead: 2, cacheWrite5m: 4, cacheWrite1h: 5 });
  assert.deepEqual(mp.normalizeUsage({ cache_creation: { ephemeral_5m_input_tokens: 4, ephemeral_1h_input_tokens: 5 } }),
    { input: 0, output: 0, cacheRead: 0, cacheWrite5m: 4, cacheWrite1h: 5 });
});

test('normalizeUsage: a cache-split mismatch and a negative, fractional, nonfinite or unsafe count are refused by code', () => {
  const mismatch = { cache_creation_input_tokens: 10, cache_creation: { ephemeral_5m_input_tokens: 4, ephemeral_1h_input_tokens: 5 } };
  assert.throws(() => mp.normalizeUsage(mismatch), { code: 'cache-split-mismatch' });
  for (const bad of [-1, 1.5, NaN, Infinity, 'x', Number.MAX_SAFE_INTEGER + 2, {}]) {
    assert.throws(() => mp.normalizeUsage({ input_tokens: bad }), { code: 'malformed-usage' }, String(bad));
  }
  assert.throws(() => mp.normalizeUsage({ cache_creation: { ephemeral_1h_input_tokens: -2 } }), { code: 'malformed-usage' });
  assert.throws(() => mp.normalizeUsage(null), { code: 'malformed-usage' });
});

test('usage-final-replaces: the latest complete usage wins, including a decrease (100, 1000, 900)', () => {
  const items = [100, 1000, 900].map((o, i) => [mkRec({ id: 'm1', req: 'q1', usage: U(o) }), i * 10]);
  const { state, outs } = foldAll(items);
  assert.deepEqual(outs.map((o) => o.key), ['m:m1', 'm:m1', 'm:m1']);
  assert.deepEqual(outs.map((o) => [o.first, o.changed]), [[true, true], [false, true], [false, true]]);
  assert.equal(outs[0].previousUsage, null);
  assert.equal(outs[1].previousUsage.output, 100);
  assert.equal(outs[2].previousUsage.output, 1000);
  assert.equal(state.get('m:m1').usage.output, 900);
  withTranscripts({ 's.jsonl': items.map(([r]) => r) }, (root) => {
    const res = priceTranscripts(root, rows);
    assert.equal(res.perModel[OPUS].calls, 1);
    assert.equal(res.totalNano, nanoOf(U(900), OPUS));
  });
});

test('identical duplicate: nothing changes and the call is not first again', () => {
  const r = mkRec({ id: 'm1', req: 'q1', usage: U(5) });
  const { outs } = foldAll([[r, 0], [r, 40]]);
  assert.deepEqual([outs[1].first, outs[1].changed, outs[1].excluded], [false, false, null]);
});

test('missing-request-then-present: the same message id is one call and the request id is filled in', () => {
  const recs = [mkRec({ id: 'm1', usage: U(5) }), mkRec({ id: 'm1', req: 'q1', usage: U(8) })];
  const { state, outs } = foldAll([[recs[0], 0], [recs[1], 50]]);
  assert.equal(state.size, 1);
  assert.equal(outs[1].key, 'm:m1');
  assert.equal(state.get('m:m1').requestId, 'q1');
  withTranscripts({ 's.jsonl': recs }, (root) => {
    assert.equal(priceTranscripts(root, rows).perModel[OPUS].calls, 1);
  });
});

test('identity-conflict: one message id with two different request ids is refused, never merged or double-counted', () => {
  const recs = [mkRec({ id: 'm1', req: 'q1', usage: U(5) }), mkRec({ id: 'm1', req: 'q2', usage: U(6) })];
  const first = mp.foldUsageCall(new Map(), recs[0], 0);
  assert.throws(() => mp.foldUsageCall(new Map([[first.key, first.next]]), recs[1], 9), { code: 'identity-conflict' });
  withTranscripts({ 's.jsonl': recs }, (root) => {
    const res = priceTranscripts(root, rows);
    assert.equal(res.perModel[OPUS].calls, 1);
    assert.equal(res.totalNano, nanoOf(U(5), OPUS));
    assert.equal(res.malformed, 1);
  });
});

test('keys: m: for a message id, r: for a request id alone, o: plus the line byte offset for neither', () => {
  const key = (r, off) => mp.foldUsageCall(new Map(), r, off).key;
  assert.equal(key(mkRec({ id: 'a', req: 'b', usage: U(1) }), 0), 'm:a');
  assert.equal(key(mkRec({ req: 'b', usage: U(1) }), 0), 'r:b');
  assert.equal(key(mkRec({ usage: U(1) }), 123), 'o:123');
  assert.equal(key(mkRec({ id: '', req: '', usage: U(1) }), 7), 'o:7');
});

test('anonymous-offset: two anonymous records on different lines are two calls', () => {
  const a = mkRec({ usage: U(5) });
  const { state } = foldAll([[a, 0], [a, 100]]);
  assert.deepEqual([...state.keys()], ['o:0', 'o:100']);
  withTranscripts({ 's.jsonl': [a, a] }, (root) => {
    assert.equal(priceTranscripts(root, rows).perModel[OPUS].calls, 2);
  });
});

test('model-switch: a model change on one key replaces the call, it is not priced as both', () => {
  const recs = [mkRec({ id: 'm1', model: OPUS, usage: U(5) }), mkRec({ id: 'm1', model: 'claude-sonnet-5-5', usage: U(5) })];
  const { state } = foldAll(recs.map((r, i) => [r, i]));
  assert.equal(state.get('m:m1').model, 'claude-sonnet-5-5');
  withTranscripts({ 's.jsonl': recs }, (root) => {
    const res = priceTranscripts(root, rows);
    assert.deepEqual(Object.keys(res.perModel), ['claude-sonnet-5-5']);
    assert.equal(res.perModel['claude-sonnet-5-5'].calls, 1);
  });
});

test('cross-session-key: the same message id in two transcripts is two calls', () => {
  const r = mkRec({ id: 'm1', req: 'q1', usage: U(5) });
  withTranscripts({ 'a.jsonl': [r], 'b.jsonl': [r] }, (root) => {
    assert.equal(priceTranscripts(root, rows).perModel[OPUS].calls, 2);
  });
});

test('--since is applied to the first occurrence: a late correction neither pulls a call in nor pushes it out', () => {
  const early = '2026-10-31T23:00:00.000Z';
  const late = '2026-11-02T01:00:00.000Z';
  withTranscripts({
    'a.jsonl': [mkRec({ id: 'a', usage: U(5), ts: early }), mkRec({ id: 'a', usage: U(50), ts: late })],
    'b.jsonl': [mkRec({ id: 'b', usage: U(5), ts: late }), mkRec({ id: 'b', usage: U(60), ts: '2026-12-25T00:00:00.000Z' })],
  }, (root) => {
    const res = priceTranscripts(root, rows, { since: '2026-11-01' });
    assert.equal(res.perModel[OPUS].calls, 1);
    assert.equal(res.totalNano, nanoOf(U(60), OPUS));
  });
});

test('--since keys on the first record of a call even when that record is refused, and a refused record outside the window is not reported', () => {
  const early = '2026-10-31T23:00:00.000Z';
  const late = '2026-11-02T01:00:00.000Z';
  withTranscripts({
    'a.jsonl': [mkRec({ id: 'a', usage: { output_tokens: -1 }, ts: early }), mkRec({ id: 'a', usage: U(50), ts: late })],
    'b.jsonl': [mkRec({ id: 'b', usage: { output_tokens: -1 }, ts: early })],
    'c.jsonl': [mkRec({ id: 'c', usage: { output_tokens: -1 }, ts: late })],
  }, (root) => {
    const res = priceTranscripts(root, rows, { since: '2026-11-01' });
    assert.equal(res.perModel[OPUS], undefined);
    assert.equal(res.malformed, 1);
  });
});

test('a missing or unparseable first timestamp is out of any --since window and counted without one', () => {
  const recs = [mkRec({ id: 'a', usage: U(5), ts: null }), mkRec({ id: 'b', usage: U(5), ts: 'garbage' })];
  withTranscripts({ 's.jsonl': recs }, (root) => {
    assert.equal(priceTranscripts(root, rows, { since: '2026-11-01' }).perModel[OPUS], undefined);
    assert.equal(priceTranscripts(root, rows).perModel[OPUS].calls, 2);
  });
});

test('synthetic zero-usage is excluded and counted once per key; synthetic nonzero is invalid', () => {
  const z = mkRec({ id: 'm1', model: '<synthetic>', usage: { input_tokens: 0, output_tokens: 0 } });
  const nonzero = mkRec({ id: 'm3', model: '<synthetic>', usage: U(3) });
  const { outs } = foldAll([[z, 0], [z, 9]]);
  assert.deepEqual(outs.map((o) => o.excluded), ['synthetic-zero', 'synthetic-zero']);
  assert.equal(outs[0].next.messageId, 'm1');
  assert.throws(() => mp.foldUsageCall(new Map(), nonzero, 0), { code: 'synthetic-nonzero' });
  withTranscripts({ 's.jsonl': [z, z, nonzero] }, (root) => {
    const res = priceTranscripts(root, rows);
    assert.equal(res.syntheticZero, 1);
    assert.deepEqual(res.perModel, {});
    assert.deepEqual(res.unpriced, {});
    assert.equal(res.malformed, 1);
  });
});

test('an unknown real model stays unpriced even with zero usage', () => {
  const r = mkRec({ id: 'm1', model: 'gpt-9-imaginary', usage: { input_tokens: 0, output_tokens: 0 } });
  withTranscripts({ 's.jsonl': [r] }, (root) => {
    const res = priceTranscripts(root, rows);
    assert.deepEqual(res.unpriced, { 'gpt-9-imaginary': 1 });
    assert.equal(res.syntheticZero, 0);
  });
});

test('pricing sums in integer nanodollars: counts past 2^53 nanodollars stay exact', () => {
  const big = { input_tokens: 1, output_tokens: Number.MAX_SAFE_INTEGER };
  withTranscripts({ 's.jsonl': [mkRec({ id: 'm1', usage: big }), mkRec({ id: 'm2', usage: big })] }, (root) => {
    const res = priceTranscripts(root, rows);
    const each = nanoOf(big, OPUS);
    assert.equal(res.totalNano, 2n * each);
    assert.equal(res.perModel[OPUS].nano, 2n * each);
  });
});

test('the transcripts CLI keeps its lines and prints an excluded line only when something was excluded', () => {
  const z = mkRec({ id: 'z', model: '<synthetic>', usage: { input_tokens: 0, output_tokens: 0 } });
  withTranscripts({ 's.jsonl': [mkRec({ id: 'm1', usage: FIXTURE_USAGE })] }, (root) => {
    const cli = spawnSync('node', [CLI, 'transcripts', root], { encoding: 'utf8' });
    assert.match(cli.stdout, /^total usd=6\.00 /m);
    assert.doesNotMatch(cli.stdout, /excluded/);
  });
  withTranscripts({ 's.jsonl': [z, z] }, (root) => {
    const cli = spawnSync('node', [CLI, 'transcripts', root], { encoding: 'utf8' });
    assert.match(cli.stdout, /^excluded synthetic-zero calls=1$/m);
  });
});
