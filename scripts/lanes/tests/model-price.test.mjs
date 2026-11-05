// scripts/lanes/tests/model-price.test.mjs - a per-model dollar price table and the
// pricer that costs a call from it. Fixtures live in a temp dir; nothing here reads the real HOME.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
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
