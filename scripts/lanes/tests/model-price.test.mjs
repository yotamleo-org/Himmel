// scripts/lanes/tests/model-price.test.mjs - a per-model dollar price table and the
// pricer that costs a call from it. Fixtures live in a temp dir; nothing here reads the real HOME.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, cpSync, copyFileSync, readFileSync, symlinkSync, chmodSync,
  openSync, fstatSync, closeSync, statSync, realpathSync, lstatSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join, dirname, basename } from 'node:path';
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

const FIX = fileURLToPath(new URL('./fixtures/usage-calls/', import.meta.url));
const sha = (b) => createHash('sha256').update(b).digest('hex');
const jl = (rs) => rs.map((r) => JSON.stringify(r)).join('\n') + '\n';
const UU = { input_tokens: 1, output_tokens: 100 };
function tmp(fn) {
  const d = mkdtempSync(join(tmpdir(), 'model-price-calls-'));
  try { return fn(d); } finally { rmSync(d, { recursive: true, force: true }); }
}
const stageShard = (dir, name) => { cpSync(join(FIX, name), join(dir, name), { recursive: true }); return join(dir, name, 'projection-manifest.json'); };
function runCalls(manifestPath, extra = []) {
  const r = spawnSync('node', [CLI, 'calls', '--manifest', manifestPath, ...extra], { encoding: 'utf8' });
  const parsed = r.stdout.split('\n').filter((l) => l.trim()).map((l) => JSON.parse(l));
  return { status: r.status, stderr: r.stderr, stdout: r.stdout, calls: parsed.filter((x) => x.kind === 'usage-call'), footer: parsed.at(-1) };
}
function build(dir, files, over = {}) {
  const root = join(dir, 'root');
  const entries = files.map((f) => {
    const p = join(root, f.rel);
    mkdirSync(dirname(p), { recursive: true });
    const text = f.text ?? jl(f.records);
    writeFileSync(p, text);
    return { relative_path: f.rel, bytes: Buffer.byteLength(text), sha256: sha(text), provider: 'claude',
      session: f.session ?? basename(f.rel, '.jsonl'), parent: f.parent ?? null, ...(f.entry ?? {}) };
  });
  const manifest = { schema: 1, root, timezone: 'Europe/Berlin', since: '2026-11-01T00:00:00Z', until: '2026-12-01T00:00:00Z', files: entries, ...over };
  const path = join(dir, 'manifest.json');
  writeFileSync(path, JSON.stringify(manifest));
  return { manifest, path, root };
}
const errCodes = (footer) => footer.errors.map((e) => e.code);
const invalidRun = (r, code) => {
  assert.equal(r.status, 2, r.stdout + r.stderr);
  assert.equal(r.calls.length, 0, 'an invalid export carries no call rows');
  assert.equal(r.footer.state, 'invalid');
  assert.ok(errCodes(r.footer).includes(code), `${code} not in ${JSON.stringify(r.footer.errors)}`);
};

test('calls: stable final identity and original timestamp', () => tmp((d) => {
  const r = runCalls(stageShard(d, 'shard1'));
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.footer.state, 'complete');
  const a1 = r.calls.filter((c) => c.session === 'parentA' && c.first_model === OPUS && c.output === 1000);
  assert.equal(a1.length, 1, 'the 100 then 1000 output duplicate is one final 1000 row');
  assert.equal(a1[0].first_timestamp, '2026-11-09T22:59:00.000Z');
  assert.equal(a1[0].call_id, sha(JSON.stringify(['claude', null, 'parentA', 'm:msg-a1'])));
  assert.equal(r.calls.length, 3);
  const later = build(join(d), [{ rel: 'proj/parentA.jsonl', records: [rec('a1', OPUS, { input_tokens: 10, output_tokens: 100 }, '2026-11-09T22:59:00.000Z')] }]);
  assert.equal(runCalls(later.path).calls[0].call_id, a1[0].call_id, 'a later usage row does not change call_id');
}));

test('calls: row and footer carry exactly the schema-1 fields', () => tmp((d) => {
  const r = runCalls(stageShard(d, 'shard1'));
  assert.deepEqual(Object.keys(r.calls[0]), ['kind', 'schema', 'call_id', 'provider', 'session', 'parent', 'first_timestamp', 'first_model', 'model',
    'input', 'output', 'cacheRead', 'cacheWrite5m', 'cacheWrite1h', 'priced', 'usd', 'nano', 'price_row', 'price_sha256', 'source', 'usage_rule', 'basis']);
  assert.deepEqual(Object.keys(r.calls[0].source), ['manifest_sha256', 'relative_path', 'sha256', 'first_offset', 'last_offset']);
  assert.deepEqual(Object.keys(r.footer), ['kind', 'schema', 'state', 'manifest_sha256', 'price_sha256', 'source_scope', 'excluded_sources', 'timezone',
    'since', 'until', 'selected_files', 'read_files', 'source_bytes', 'selected_calls', 'priced_calls', 'unpriced_calls', 'excluded_calls',
    'usage_rule', 'exclusion_reasons', 'errors']);
  assert.deepEqual(r.footer.exclusion_reasons, { 'synthetic-zero': 1, 'outside-window': 0 });
  assert.equal(r.footer.usage_rule, 'final-v2');
  assert.equal(r.footer.selected_calls, 3);
  assert.equal(r.footer.excluded_calls, 1);
  assert.deepEqual(r.calls.map((c) => c.first_timestamp), r.calls.map((c) => c.first_timestamp).sort());
  assert.equal(typeof r.calls[0].nano, 'string');
  assert.equal(r.calls[0].basis, 'list-price-equivalent');
}));

test('calls: canonical pricing agrees', () => tmp((d) => {
  const r = runCalls(stageShard(d, 'shard1'));
  const res = priceTranscripts(join(d, 'shard1', 'snapshot'), rows, { since: '2026-11-01' });
  const total = r.calls.reduce((s, c) => s + BigInt(c.nano), 0n);
  const diff = total > res.totalNano ? total - res.totalNano : res.totalNano - total;
  assert.ok(diff <= 1n, `${total} vs ${res.totalNano}`);
  assert.equal(r.footer.priced_calls, 3);
  assert.equal(r.footer.unpriced_calls, 0);
}));

test('calls: reject duplicate source', () => tmp((d) => {
  const a = { rel: 'proj1/s.jsonl', records: [rec(1, OPUS, UU)] };
  const b = { rel: 'proj2/s.jsonl', records: [rec(2, OPUS, UU)] };
  invalidRun(runCalls(build(d, [a, b]).path), 'duplicate-source');
}));

test('calls: child parent mismatch', () => tmp((d) => {
  const base = { records: [rec(1, OPUS, UU)] };
  invalidRun(runCalls(build(d, [{ ...base, rel: 'proj/other/subagents/c.jsonl', parent: 'parentX' }]).path), 'parent-mismatch');
  invalidRun(runCalls(build(d, [{ ...base, rel: 'proj/p/subagents/c.jsonl', parent: null }]).path), 'parent-mismatch');
  invalidRun(runCalls(build(d, [{ ...base, rel: 'proj/c.jsonl', parent: 'p' }]).path), 'parent-mismatch');
  invalidRun(runCalls(build(d, [{ ...base, rel: 'proj/c.jsonl', session: 'other' }]).path), 'session-mismatch');
}));

test('calls: path escape', () => tmp((d) => {
  const outside = join(d, 'outside.jsonl');
  const text = jl([rec(1, OPUS, UU)]);
  writeFileSync(outside, text);
  const entry = (rel) => ({ rel: 'proj/ok.jsonl', records: [rec(1, OPUS, UU)], entry: { relative_path: rel, session: basename(rel, '.jsonl') } });
  for (const rel of ['../outside.jsonl', '/etc/passwd.jsonl', 'file:///x/y.jsonl', 'proj/../../outside.jsonl']) {
    invalidRun(runCalls(build(d, [entry(rel)]).path), 'path-escape');
  }
  const b = build(d, [{ rel: 'proj/ok.jsonl', records: [rec(1, OPUS, UU)] }]);
  symlinkSync(outside, join(b.root, 'proj', 'link.jsonl'));
  b.manifest.files.push({ relative_path: 'proj/link.jsonl', bytes: Buffer.byteLength(text), sha256: sha(text), provider: 'claude', session: 'link', parent: null });
  writeFileSync(b.path, JSON.stringify(b.manifest));
  invalidRun(runCalls(b.path), 'path-escape');
}));

test('calls: changed or missing source', () => tmp((d) => {
  const b = build(d, [{ rel: 'proj/s.jsonl', records: [rec(1, OPUS, UU)] }]);
  const p = join(b.root, 'proj', 's.jsonl');
  writeFileSync(p, jl([rec(1, OPUS, { input_tokens: 1, output_tokens: 101 })]));
  invalidRun(runCalls(b.path), 'source-changed');
  writeFileSync(p, jl([rec(1, OPUS, UU)]).replace('100', '999'));
  invalidRun(runCalls(b.path), 'source-changed');
  rmSync(p);
  invalidRun(runCalls(b.path), 'source-missing');
}));

test('calls: negative fractional nonfinite counter', () => tmp((d) => {
  const line = (out) => `{"type":"assistant","timestamp":"2026-11-05T10:00:00.000Z","message":{"id":"m1","model":"${OPUS}","usage":{"input_tokens":1,"output_tokens":${out}}}}\n`;
  for (const out of ['-1', '1.5', '"x"', '1e999']) {
    invalidRun(runCalls(build(d, [{ rel: 'proj/s.jsonl', text: line(out) }]).path), 'malformed-usage');
  }
  const mismatch = rec(1, OPUS, { cache_creation_input_tokens: 10, cache_creation: { ephemeral_5m_input_tokens: 4, ephemeral_1h_input_tokens: 5 } });
  invalidRun(runCalls(build(d, [{ rel: 'proj/s.jsonl', records: [mismatch] }]).path), 'cache-split-mismatch');
  invalidRun(runCalls(build(d, [{ rel: 'proj/s.jsonl', records: [rec(1, OPUS, UU, 'garbage')] }]).path), 'timestamp-invalid');
  invalidRun(runCalls(build(d, [{ rel: 'proj/s.jsonl', records: [rec(1, OPUS, UU, null)] }]).path), 'timestamp-invalid');
}));

test('calls: identity collision', () => tmp((d) => {
  const recs = [mkRec({ id: 'm1', req: 'q1', usage: U(5) }), mkRec({ id: 'm1', req: 'q2', usage: U(6) })];
  invalidRun(runCalls(build(d, [{ rel: 'proj/s.jsonl', records: recs }]).path), 'identity-conflict');
}));

test('calls: incomplete line footer', () => tmp((d) => {
  const text = jl([rec(1, OPUS, UU)]) + '{"type":"assistant","timestamp":"2026-11-05T10:00:0';
  const r = runCalls(build(d, [{ rel: 'proj/s.jsonl', text }]).path);
  assert.equal(r.status, 3, r.stdout + r.stderr);
  assert.equal(r.footer.state, 'partial');
  assert.deepEqual(errCodes(r.footer), ['torn-line']);
  assert.equal(r.footer.read_files, 0);
  assert.equal(r.footer.selected_files, 1);
}));

test('calls: unknown price', () => tmp((d) => {
  const r = runCalls(build(d, [{ rel: 'proj/s.jsonl', records: [rec(1, 'gpt-9-imaginary', UU), rec(2, OPUS, UU)] }]).path);
  assert.equal(r.status, 0, r.stderr);
  const unknown = r.calls.find((c) => c.model === 'gpt-9-imaginary');
  assert.deepEqual([unknown.priced, unknown.usd, unknown.nano, unknown.price_row], [false, null, null, null]);
  assert.equal(r.footer.unpriced_calls, 1);
  assert.equal(r.footer.priced_calls, 1);
  assert.equal(r.footer.state, 'complete');
}));

test('calls: empty selected window', () => tmp((d) => {
  const b = build(d, [{ rel: 'proj/s.jsonl', records: [rec(1, OPUS, UU)] }], { since: '2027-01-01T00:00:00Z', until: '2027-02-01T00:00:00Z' });
  const r = runCalls(b.path);
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.calls.length, 0);
  assert.equal(r.footer.state, 'complete');
  assert.equal(r.footer.selected_calls, 0);
  assert.equal(r.footer.usage_rule, 'final-v2');
  assert.deepEqual(r.footer.exclusion_reasons, { 'synthetic-zero': 0, 'outside-window': 1 });
}));

test('calls: budget before read', () => tmp((d) => {
  const entry = (i, bytes = 10) => ({ relative_path: `proj/s${i}.jsonl`, bytes, sha256: '0'.repeat(64), provider: 'claude', session: `s${i}`, parent: null });
  const base = { schema: 1, root: d, timezone: 'Europe/Berlin', since: '2026-11-01T00:00:00Z', until: '2026-12-01T00:00:00Z' };
  const touched = [];
  const spy = Object.fromEntries(Object.entries({ readFileSync, statSync, lstatSync, realpathSync, openSync }).map(([k, fn]) => [k, (...a) => { touched.push(k); return fn(...a); }]));
  const many = mp.projectCalls({ ...base, files: Array.from({ length: 129 }, (_, i) => entry(i)) }, rows, { io: spy });
  assert.equal(many.exitCode, 2);
  assert.equal(many.coverage.state, 'invalid');
  assert.deepEqual(errCodes(many.coverage), ['manifest-budget']);
  const big = mp.projectCalls({ ...base, files: [0, 1, 2].map((i) => entry(i, 200 * 1024 * 1024)) }, rows, { io: spy });
  assert.deepEqual(errCodes(big.coverage), ['manifest-budget']);
  assert.deepEqual(touched, [], 'a refused budget performs no source I/O');
  const limit = mp.projectCalls({ ...base, files: Array.from({ length: 128 }, (_, i) => entry(i)) }, rows, { io: spy });
  assert.ok(!errCodes(limit.coverage).includes('manifest-budget'), '128 files are within the budget');
  const b = build(d, [{ rel: 'proj/s.jsonl', records: [rec(1, OPUS, UU)] }]);
  b.manifest.files = Array.from({ length: 129 }, (_, i) => entry(i));
  writeFileSync(b.path, JSON.stringify(b.manifest));
  const cli = runCalls(b.path);
  assert.deepEqual(errCodes(cli.footer), ['manifest-budget'], 'files that do not exist are never opened');
  assert.equal(cli.status, 2);
}));

test('calls: mixed session namespaces', () => tmp((d) => {
  const records = [rec(1, OPUS, UU)];
  const b = build(d, [{ rel: 'proj/x.jsonl', records }, { rel: 'proj/p/subagents/x.jsonl', records, parent: 'p' }]);
  invalidRun(runCalls(b.path), 'session-namespace');
}));

test('calls: a malformed or unreadable manifest, a foreign provider and --price-as are refused', () => tmp((d) => {
  const missing = runCalls(join(d, 'nope.json'));
  assert.equal(missing.status, 2);
  assert.ok(errCodes(missing.footer).includes('manifest-unreadable'));
  writeFileSync(join(d, 'bad.json'), '{not json');
  assert.ok(errCodes(runCalls(join(d, 'bad.json')).footer).includes('manifest-malformed'));
  const b = build(d, [{ rel: 'proj/s.jsonl', records: [rec(1, OPUS, UU)] }], { timezone: 'UTC' });
  invalidRun(runCalls(b.path), 'manifest-shape');
  const c = build(d, [{ rel: 'proj/s.jsonl', records: [rec(1, OPUS, UU)], entry: { provider: 'codex' } }]);
  invalidRun(runCalls(c.path), 'provider-unsupported');
  const ok = build(d, [{ rel: 'proj/s.jsonl', records: [rec(1, OPUS, UU)] }]);
  const r = spawnSync('node', [CLI, 'calls', '--manifest', ok.path, '--price-as', OPUS], { encoding: 'utf8' });
  assert.equal(r.status, 64);
  assert.equal(r.stdout, '');
}));

test('first-attribution-late-correction: a correction after Berlin midnight keeps the first timestamp and the first day', () => tmp((d) => {
  const recs = [rec('m1', OPUS, { input_tokens: 1, output_tokens: 100 }, '2026-11-09T22:59:00.000Z'),
    rec('m1', OPUS, { input_tokens: 1, output_tokens: 1000 }, '2026-11-09T23:01:00.000Z')];
  const berlinDay = (iso) => new Intl.DateTimeFormat('en-CA', { timeZone: 'Europe/Berlin' }).format(new Date(iso));
  const day9 = runCalls(build(d, [{ rel: 'proj/s.jsonl', records: recs }], { since: '2026-11-08T23:00:00Z', until: '2026-11-09T23:00:00Z' }).path);
  assert.equal(day9.calls.length, 1);
  assert.equal(day9.calls[0].first_timestamp, '2026-11-09T22:59:00.000Z');
  assert.equal(berlinDay(day9.calls[0].first_timestamp), '2026-11-09');
  assert.equal(berlinDay('2026-11-09T23:01:00.000Z'), '2026-11-10');
  assert.equal(day9.calls[0].output, 1000);
  const day10 = runCalls(build(d, [{ rel: 'proj/s.jsonl', records: recs }], { since: '2026-11-09T23:00:00Z', until: '2026-11-10T23:00:00Z' }).path);
  assert.equal(day10.calls.length, 0, 'the correction day does not receive the call');
  assert.equal(day10.footer.exclusion_reasons['outside-window'], 1);
}));

const produce = (manifestPath) => {
  const r = spawnSync('node', [CLI, 'calls', '--manifest', manifestPath], { encoding: 'utf8' });
  return { manifestPath, stdout: r.stdout, status: r.status };
};
function carrier(dir, runs, { expected, price = mp.priceTableSha256(rows), set = {} } = {}) {
  const c = join(dir, 'carrier');
  mkdirSync(c, { recursive: true });
  const declared = runs.flatMap((r) => JSON.parse(readFileSync(r.manifestPath, 'utf8')).files.map((f) => ({ provider: 'claude', parent: f.parent, session: f.session })));
  const exports = runs.map((r, i) => {
    writeFileSync(join(c, `calls-${i}.jsonl`), r.stdout);
    copyFileSync(r.manifestPath, join(c, `projection-${i}.json`));
    return { path: `calls-${i}.jsonl`, producer_exit_code: r.status, projection_manifest: { path: `projection-${i}.json`, sha256: sha(readFileSync(r.manifestPath)) } };
  });
  const setPath = join(c, 'EXPORT_SET.json');
  writeFileSync(setPath, JSON.stringify({ schema: 1, price_sha256: price, usage_rule: 'final-v2', timezone: 'Europe/Berlin', exports, expected_sessions: expected ?? declared, ...set }));
  return setPath;
}
function runValidate(setPath) {
  const r = spawnSync('node', [CLI, 'validate-calls', '--manifest', setPath], { encoding: 'utf8' });
  return { status: r.status, stderr: r.stderr, v: r.stdout.trim() ? JSON.parse(r.stdout) : null, stdout: r.stdout };
}
const rewrite = (setPath, i, fn) => {
  const p = join(dirname(setPath), `calls-${i}.jsonl`);
  const lines = readFileSync(p, 'utf8').split('\n').filter((l) => l);
  writeFileSync(p, fn(lines.map((l) => JSON.parse(l))).map((o) => (typeof o === 'string' ? o : JSON.stringify(o))).join('\n') + '\n');
};
const twoShards = (d) => carrier(d, [produce(stageShard(d, 'shard1')), produce(stageShard(d, 'shard2'))]);
const refused = (r, state, status, ...reasons) => {
  assert.equal(r.status, status, r.stdout + r.stderr);
  assert.equal(r.v.state, state);
  assert.equal(r.v.ok, false);
  for (const reason of reasons) assert.ok(r.v.reasons.includes(reason), `${reason} not in ${r.v.reasons}`);
  assert.equal(r.v.call_ids_sha256, null);
  assert.deepEqual(r.v.complete_sessions, []);
};

test('validate: real calls stdout from two disjoint shards is complete and prints one receipt', () => tmp((d) => {
  const r = runValidate(twoShards(d));
  assert.equal(r.status, 0, r.stdout + r.stderr);
  assert.equal(r.stdout.trim().split('\n').length, 1);
  assert.deepEqual([r.v.schema, r.v.kind, r.v.ok, r.v.state, r.v.reasons], [1, 'usage-call-validation', true, 'complete', []]);
  assert.deepEqual([r.v.selected_calls, r.v.priced_calls, r.v.unpriced_calls], [4, 4, 0]);
  assert.equal(r.v.price_sha256, mp.priceTableSha256(rows));
  assert.equal(r.v.manifest_sha256.length, 2);
  assert.equal(r.v.complete_sessions.length, 3);
  assert.match(r.v.call_ids_sha256, /^[0-9a-f]{64}$/);
}));

test('validate: a torn stdout suffix is inconclusive, never complete', () => tmp((d) => {
  const set = twoShards(d);
  const p = join(dirname(set), 'calls-0.jsonl');
  const full = readFileSync(p, 'utf8');
  writeFileSync(p, full.slice(0, full.length - 40));
  refused(runValidate(set), 'inconclusive', 3, 'parse-incomplete');
  writeFileSync(p, full.trimEnd().split('\n').slice(0, -1).join('\n') + '\n');
  refused(runValidate(set), 'inconclusive', 3, 'footer-missing');
  writeFileSync(p, '');
  refused(runValidate(set), 'inconclusive', 3, 'footer-missing');
}));

test('validate: footer removed, nonterminal, duplicated, count-mutated and hash-mutated are refused by name', () => tmp((d) => {
  const set = twoShards(d);
  const p = join(dirname(set), 'calls-0.jsonl');
  const orig = readFileSync(p, 'utf8');
  const reset = () => writeFileSync(p, orig);
  rewrite(set, 0, (o) => [o.at(-1), ...o.slice(0, -1)]);
  refused(runValidate(set), 'invalid', 2, 'footer-shape');
  reset();
  rewrite(set, 0, (o) => [...o, o.at(-1)]);
  refused(runValidate(set), 'invalid', 2, 'footer-shape');
  reset();
  rewrite(set, 0, (o) => o.map((x) => (x.kind === 'usage-coverage' ? { ...x, selected_calls: x.selected_calls + 1 } : x)));
  refused(runValidate(set), 'invalid', 2, 'count-mismatch');
  reset();
  rewrite(set, 0, (o) => o.map((x) => (x.kind === 'usage-coverage' ? { ...x, manifest_sha256: '0'.repeat(64) } : x)));
  refused(runValidate(set), 'invalid', 2, 'manifest-mismatch');
  reset();
  rewrite(set, 0, (o) => o.map((x) => (x.kind === 'usage-call' ? { ...x, source: { ...x.source, sha256: '1'.repeat(64) } } : x)));
  refused(runValidate(set), 'invalid', 2, 'source-mismatch');
  reset();
  rewrite(set, 0, (o) => o.map((x) => (x.kind === 'usage-call' ? { ...x, nano: '7' } : x)));
  refused(runValidate(set), 'invalid', 2, 'row-shape');
  reset();
  assert.equal(runValidate(set).status, 0, 'the unmutated export is complete again');
}));

test('validate: a wrong producer exit, a partial footer and a missing expected session are inconclusive', () => tmp((d) => {
  const wrongExit = produce(stageShard(d, 'shard1'));
  refused(runValidate(carrier(d, [{ ...wrongExit, status: 3 }])), 'inconclusive', 3, 'producer-exit');
  const torn = build(join(d, 't'), [{ rel: 'proj/s.jsonl', text: jl([rec(1, OPUS, UU)]) + '{"type":"ass' }]);
  refused(runValidate(carrier(join(d, 't'), [produce(torn.path)])), 'inconclusive', 3, 'producer-exit', 'source-incomplete', 'missing-session');
  const set = carrier(join(d, 'm'), [produce(stageShard(join(d, 'm'), 'shard1'))], { expected: [{ provider: 'claude', parent: null, session: 'ghost' }] });
  refused(runValidate(set), 'inconclusive', 3, 'missing-session');
}));

test('validate: an unpriced call is inconclusive and a nonzero pseudo-model never reaches complete', () => tmp((d) => {
  const unpriced = build(join(d, 'u'), [{ rel: 'proj/s.jsonl', records: [rec(1, 'gpt-9-imaginary', UU)] }]);
  refused(runValidate(carrier(join(d, 'u'), [produce(unpriced.path)])), 'inconclusive', 3, 'unpriced');
  const nz = build(join(d, 'n'), [{ rel: 'proj/s.jsonl', records: [rec(1, '<synthetic>', UU)] }]);
  const run = produce(nz.path);
  assert.equal(run.status, 2);
  refused(runValidate(carrier(join(d, 'n'), [run])), 'inconclusive', 3, 'producer-exit');
  const set = carrier(join(d, 'r'), [produce(stageShard(join(d, 'r'), 'shard1'))]);
  rewrite(set, 0, (o) => o.map((x) => (x.kind === 'usage-call' ? { ...x, model: '<synthetic>' } : x)));
  refused(runValidate(set), 'invalid', 2, 'row-shape');
}));

test('validate: synthetic-zero only is complete with zero selected calls and its session still represented', () => tmp((d) => {
  const z = mkRec({ id: 'z', model: '<synthetic>', usage: { input_tokens: 0, output_tokens: 0 } });
  const b = build(d, [{ rel: 'proj/s.jsonl', records: [z, z] }]);
  const run = produce(b.path);
  assert.equal(run.status, 0);
  const r = runValidate(carrier(d, [run]));
  assert.equal(r.status, 0, r.stdout);
  assert.deepEqual([r.v.state, r.v.selected_calls], ['complete', 0]);
  assert.deepEqual(r.v.complete_sessions, [{ provider: 'claude', parent: null, session: 's' }]);
}));

test('validate: a call or source duplicated across shards is invalid', () => tmp((d) => {
  const a = produce(stageShard(d, 'shard1'));
  const expected = JSON.parse(readFileSync(a.manifestPath, 'utf8')).files.map((f) => ({ provider: 'claude', parent: f.parent, session: f.session }));
  refused(runValidate(carrier(d, [a, a], { expected })), 'invalid', 2, 'duplicate-call', 'duplicate-source');
}));

test('validate: mixed price revision across shards', () => tmp((d) => {
  const set = twoShards(d);
  rewrite(set, 1, (o) => o.map((x) => ({ ...x, price_sha256: '2'.repeat(64) })));
  const r = runValidate(set);
  refused(r, 'invalid', 2, 'price-mismatch');
  assert.equal(r.v.selected_calls, 4, 'counts are diagnostics only');
  rewrite(set, 1, (o) => o.map((x) => ({ ...x, price_sha256: mp.priceTableSha256(rows) })));
  assert.equal(runValidate(set).status, 0);
  const clock = JSON.parse(readFileSync(set, 'utf8'));
  writeFileSync(set, JSON.stringify({ ...clock, timezone: 'UTC' }));
  refused(runValidate(set), 'invalid', 2, 'clock-mismatch');
  writeFileSync(set, JSON.stringify(clock));
  const loaded = mp.loadExportSet(set);
  const wrongRule = mp.validateCallExport(loaded.exports, loaded.expectedSessions, { ...loaded.expectations, usage_rule: 'final-v1' });
  assert.deepEqual([wrongRule.state, wrongRule.reasons.includes('usage-rule-mismatch')], ['invalid', true]);
  writeFileSync(set, JSON.stringify({ ...clock, usage_rule: 'final-v1' }));
  assert.equal(runValidate(set).v.reasons[0], 'export-set-load', 'the carrier pins final-v2 before the validator runs');
}));

test('validate: a manifest the producer would refuse never earns a complete receipt', () => tmp((d) => {
  const z = mkRec({ id: 'z', model: '<synthetic>', usage: { input_tokens: 0, output_tokens: 0 } });
  const set = carrier(d, [produce(build(d, [{ rel: 'proj/z.jsonl', records: [z] }]).path)]);
  const pristine = mp.loadExportSet(set);
  assert.equal(mp.validateCallExport(pristine.exports, pristine.expectedSessions, pristine.expectations).state, 'complete');
  const forged = (mutate, expectedSessions = pristine.expectedSessions) => {
    const e = pristine.exports[0];
    const manifest = mutate(JSON.parse(e.manifestBytes));
    const manifestBytes = JSON.stringify(manifest);
    const hash = sha(manifestBytes);
    const lines = e.lines.map((l) => JSON.stringify({ ...JSON.parse(l), manifest_sha256: hash }));
    return mp.validateCallExport([{ ...e, manifestBytes, expectedManifestSha256: hash, lines }], expectedSessions, pristine.expectations);
  };
  const cases = {
    'session is not the filename': (m) => { m.files[0].session = 'q'; return m; },
    'path climbs out of the root': (m) => { m.files[0].relative_path = '../z.jsonl'; return m; },
    'child outside a subagents directory': (m) => { m.files[0].parent = 'p'; return m; },
    'unsupported timezone': (m) => { m.timezone = 'UTC'; return m; },
    'inverted window': (m) => { [m.since, m.until] = [m.until, m.since]; return m; },
    'more than 128 files': (m) => { m.files = Array.from({ length: 129 }, (_, i) => ({ ...m.files[0], relative_path: `proj/z${i}.jsonl`, session: `z${i}` })); return m; },
  };
  for (const [name, mutate] of Object.entries(cases)) {
    const m = mutate(JSON.parse(pristine.exports[0].manifestBytes));
    const sessions = m.files.slice(0, 1).map((f) => ({ provider: 'claude', parent: f.parent, session: f.session }));
    const v = forged(mutate, sessions);
    assert.notEqual(v.state, 'complete', name);
    assert.ok(v.reasons.includes('manifest-mismatch'), `${name}: ${v.reasons}`);
  }
}));

const spyIo = () => {
  const opened = [];
  const io = { readFileSync, statSync, realpathSync, lstatSync, closeSync, fstatSync, openSync: (p, ...a) => { opened.push(p); return openSync(p, ...a); } };
  return { io, opened };
};
const loadAndValidate = (setPath, io) => {
  const { exports, expectedSessions, expectations } = mp.loadExportSet(setPath, { io });
  return mp.validateCallExport(exports, expectedSessions, expectations);
};

test('load-export-set-real-parity: the CLI and the imported loader plus validator give equal receipts', () => tmp((d) => {
  const set = twoShards(d);
  const cli = runValidate(set);
  const loaded = mp.loadExportSet(set);
  assert.deepEqual(Object.keys(loaded), ['exports', 'expectedSessions', 'expectations']);
  assert.deepEqual(mp.validateCallExport(loaded.exports, loaded.expectedSessions, loaded.expectations), cli.v);
  const pure = mp.validateCallExport(loaded.exports, loaded.expectedSessions, loaded.expectations);
  assert.equal(pure.state, 'complete');
  rewrite(set, 0, (o) => o.slice(0, -1));
  const l2 = mp.loadExportSet(set);
  assert.deepEqual(mp.validateCallExport(l2.exports, l2.expectedSessions, l2.expectations), runValidate(set).v);
}));

test('load-export-set: a missing carrier, malformed JSON, an unreadable file, an outside symlink, a path alias and a bad declaration throw CallExportLoadError', () => tmp((d) => {
  const set = twoShards(d);
  const c = dirname(set);
  const pinned = { schema: 1, kind: 'usage-call-validation', ok: false, state: 'invalid', reasons: ['export-set-load'], price_sha256: null, usage_rule: null,
    timezone: null, manifest_sha256: [], selected_calls: 0, priced_calls: 0, unpriced_calls: 0, complete_sessions: [], call_ids_sha256: null };
  const expectLoad = (path, detail) => {
    assert.throws(() => mp.loadExportSet(path), (e) => {
      assert.ok(e instanceof mp.CallExportLoadError);
      assert.ok(e instanceof Error);
      assert.deepEqual([e.name, e.exitCode, e.detail], ['CallExportLoadError', 2, detail]);
      assert.deepEqual(e.validation, pinned);
      return true;
    });
    const cli = runValidate(path);
    assert.deepEqual([cli.status, cli.v], [2, pinned]);
  };
  const orig = JSON.parse(readFileSync(set, 'utf8'));
  const variant = (name, mutate) => { const p = join(c, name); writeFileSync(p, JSON.stringify(mutate(structuredClone(orig)))); return p; };
  expectLoad(join(c, 'absent.json'), 'missing');
  writeFileSync(join(c, 'broken.json'), '{nope');
  expectLoad(join(c, 'broken.json'), 'malformed');
  expectLoad(variant('v1.json', (o) => { o.exports[0].path = 'gone.jsonl'; return o; }), 'missing');
  const outside = join(d, 'outside.jsonl');
  writeFileSync(outside, '');
  symlinkSync(outside, join(c, 'esc.jsonl'));
  expectLoad(variant('v2.json', (o) => { o.exports[0].path = 'esc.jsonl'; return o; }), 'escape');
  expectLoad(variant('v3.json', (o) => { o.exports[0].path = '../outside.jsonl'; return o; }), 'escape');
  expectLoad(variant('v4.json', (o) => { o.exports[0].path = 'file:///etc/passwd'; return o; }), 'escape');
  symlinkSync(join(c, 'calls-1.jsonl'), join(c, 'alias.jsonl'));
  expectLoad(variant('v5.json', (o) => { o.exports[1].path = 'alias.jsonl'; o.exports[0].path = 'calls-1.jsonl'; return o; }), 'duplicate-path');
  expectLoad(variant('v6.json', (o) => { o.exports[1].path = './calls-0.jsonl'; return o; }), 'duplicate-path');
  expectLoad(variant('v7.json', (o) => { o.expected_sessions.push(o.expected_sessions[0]); return o; }), 'invalid-declaration');
  expectLoad(variant('v8.json', (o) => { o.expected_sessions[0].provider = 'codex'; return o; }), 'invalid-declaration');
  expectLoad(variant('v9.json', (o) => { delete o.exports[0].projection_manifest; return o; }), 'invalid-declaration');
  expectLoad(variant('v10.json', (o) => { o.schema = 2; return o; }), 'invalid-declaration');
  expectLoad(variant('v11.json', (o) => { o.exports[0].producer_exit_code = '0'; return o; }), 'invalid-declaration');
  if (process.getuid?.() !== 0) {
    chmodSync(join(c, 'calls-0.jsonl'), 0);
    try { expectLoad(set, 'unreadable'); } finally { chmodSync(join(c, 'calls-0.jsonl'), 0o644); }
  }
}));

test('load-export-set: a valid zero-call export loads and validates complete', () => tmp((d) => {
  const z = mkRec({ id: 'z', model: '<synthetic>', usage: { input_tokens: 0, output_tokens: 0 } });
  const set = carrier(d, [produce(build(d, [{ rel: 'proj/s.jsonl', records: [z] }]).path)]);
  const v = loadAndValidate(set, undefined);
  assert.deepEqual([v.state, v.selected_calls], ['complete', 0]);
}));

test('validate-no-source-reread: neither validation path touches the projection transcript root', () => tmp((d) => {
  const set = twoShards(d);
  const { io, opened } = spyIo();
  assert.equal(loadAndValidate(set, io).state, 'complete');
  assert.ok(opened.length >= 5, 'the spy sees the declared files');
  assert.ok(opened.every((p) => p.startsWith(dirname(set))), `reads outside the carrier: ${opened}`);
  assert.ok(!opened.some((p) => p.includes('snapshot')), 'no transcript source is opened');
  rmSync(join(d, 'shard1', 'snapshot'), { recursive: true });
  rmSync(join(d, 'shard2', 'snapshot'), { recursive: true });
  const cli = runValidate(set);
  assert.equal(cli.status, 0, 'the CLI validates with the transcript sources gone');
  assert.equal(cli.v.state, 'complete');
}));
