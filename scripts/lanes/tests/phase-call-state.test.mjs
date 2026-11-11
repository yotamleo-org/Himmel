// scripts/lanes/tests/phase-call-state.test.mjs - the schema-2 call-state adapter of the usage collector
// (scripts/usage/phase-call-state.mjs). Each case drives the CLI, the way usage-compute.sh does.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadPrices, priceTranscripts } from '../model-price.mjs';

const ADAPTER = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'usage', 'phase-call-state.mjs');
const OPUS = 'claude-opus-5-5';
const META = { session: 's1', parent: null, agent_type: '' };

const usage = (o) => ({ input_tokens: 10, output_tokens: o, cache_read_input_tokens: 100, cache_creation_input_tokens: 5,
  cache_creation: { ephemeral_5m_input_tokens: 5, ephemeral_1h_input_tokens: 0 } });
const call = (id, ts, out, { model = OPUS, tool, req = `req_${id}` } = {}) => ({
  type: 'assistant', timestamp: ts, requestId: req,
  message: { id, model, content: tool ? [{ type: 'tool_use', name: 'Bash', input: { command: tool } }] : [{ type: 'text', text: 'x' }], usage: usage(out) },
});

const serialize = (lines) => lines.map((l) => `${typeof l === 'string' ? l : JSON.stringify(l)}\n`).join('');

// One adapter run on `lines`, from `state` (a parsed state or null) at byte offset `start`.
function run(lines, { state = null, start = 0, meta = META, role, tz, env = {}, chunkText } = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'pcs-'));
  try {
    const text = chunkText ?? serialize(lines);
    const chunk = join(dir, 'chunk');
    writeFileSync(chunk, text);
    writeFileSync(join(dir, 'meta.json'), JSON.stringify(meta));
    const args = [ADAPTER, '--chunk', chunk, '--start-offset', String(start), '--end-offset', String(start + Buffer.byteLength(text)), '--meta', join(dir, 'meta.json')];
    if (state) { writeFileSync(join(dir, 'state.json'), JSON.stringify(state)); args.push('--state', join(dir, 'state.json')); }
    if (role) args.push('--role', role);
    if (tz) args.push('--timezone', tz);
    const r = spawnSync(process.execPath, args, { encoding: 'utf8', env: { ...process.env, TZ: 'UTC', ...env } });
    return { status: r.status, stderr: r.stderr, stdout: r.stdout, state: r.status === 0 ? JSON.parse(r.stdout) : null, end: start + Buffer.byteLength(text) };
  } finally { rmSync(dir, { recursive: true, force: true }); }
}

const only = (st) => Object.entries(st.agg);

test('a fresh chunk writes a schema 2 state: agg by day and last-tool phase, the saved offset, the class words', () => {
  const r = run([
    { type: 'custom-title', customTitle: 'HIMMEL-9001-N1-thing' },
    call('m1', '2026-11-04T10:00:00.000Z', 20),
    call('m1', '2026-11-04T10:00:01.000Z', 20, { tool: 'bash scripts/cr/pr-check-context.sh' }),
    call('m2', '2026-11-04T10:00:05.000Z', 30),
  ]);
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.state.schema, 2);
  assert.equal(r.state.off, r.end);
  assert.equal(r.state.tc_class, 'worker');
  assert.equal(r.state.ac_class, null);
  assert.deepEqual(r.state.meta, META);
  assert.deepEqual(Object.keys(r.state.agg).sort(), ['2026-11-04|boot', '2026-11-04|review']);
  assert.equal(r.state.agg['2026-11-04|boot'].calls, 1);
  assert.equal(r.state.agg['2026-11-04|review'].o, 30);
  assert.equal(r.state.last, 'review');
});

test('changed usage across runs replaces once, on the first call day and phase', () => {
  const first = run([call('m1', '2026-11-04T23:59:00.000Z', 100)]);
  assert.equal(first.state.agg['2026-11-04|boot'].o, 100);
  const later = run([call('m9', '2026-11-05T09:00:00.000Z', 5, { tool: 'git commit -m x' }), call('m1', '2026-11-05T09:00:01.000Z', 1000)], { state: first.state, start: first.end });
  assert.equal(later.status, 0, later.stderr);
  assert.equal(later.state.agg['2026-11-04|boot'].calls, 1);
  assert.equal(later.state.agg['2026-11-04|boot'].o, 1000);
  assert.deepEqual(Object.keys(later.state.agg).sort(), ['2026-11-04|boot', '2026-11-05|boot']);
  const down = run([call('m1', '2026-11-05T09:00:02.000Z', 400)], { state: later.state, start: later.end });
  assert.equal(down.state.agg['2026-11-04|boot'].o, 400, 'a legitimate decrease wins too');
  assert.equal(down.state.agg['2026-11-04|boot'].calls, 1);
  const same = run([call('m1', '2026-11-05T09:00:03.000Z', 400)], { state: down.state, start: down.end });
  assert.deepEqual(same.state.agg, down.state.agg, 'repeated identical data changes nothing');
});

test('a corrected model replaces the old contribution, models and dollars included', () => {
  const a = run([call('m1', '2026-11-04T10:00:00.000Z', 100, { model: 'claude-sonnet-5-5' })]);
  const b = run([call('m1', '2026-11-04T10:00:01.000Z', 100)], { state: a.state, start: a.end });
  const agg = b.state.agg['2026-11-04|boot'];
  assert.deepEqual(agg.models, { [OPUS]: 1 });
  assert.equal(agg.calls, 1);
  const fresh = run([call('m1', '2026-11-04T10:00:00.000Z', 100)]);
  assert.equal(agg.nano, fresh.state.agg['2026-11-04|boot'].nano);
});

test('first attribution midnight: a correction after local midnight keeps the first call day', () => {
  const env = { TZ: 'Europe/Berlin' };
  const r = run([call('m1', '2026-11-04T22:59:59.000Z', 100), call('m1', '2026-11-04T23:00:05.000Z', 900)], { env });
  assert.deepEqual(Object.keys(r.state.agg), ['2026-11-04|boot']);
  assert.equal(r.state.agg['2026-11-04|boot'].o, 900);
  const flag = run([call('m1', '2026-11-04T22:59:59.000Z', 100)], { tz: 'Europe/Berlin' });
  assert.deepEqual(Object.keys(flag.state.agg), ['2026-11-04|boot']);
  const flagUtc = run([call('m1', '2026-11-04T23:30:00.000Z', 100)], { tz: 'Europe/Berlin', env: { TZ: 'UTC' } });
  assert.deepEqual(Object.keys(flagUtc.state.agg), ['2026-11-05|boot'], '--timezone beats the process zone');
});

test('synthetic parity: a synthetic zero is not counted, a nonzero one is refused and counted, an unknown model stays unpriced', () => {
  const zero = { input_tokens: 0, output_tokens: 0, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 };
  const synth = (id, u) => ({ type: 'assistant', timestamp: '2026-11-04T10:00:00.000Z', message: { id, model: '<synthetic>', content: [], usage: u } });
  const r = run([
    synth('z1', zero), synth('z1', zero),
    synth('z2', { ...zero, output_tokens: 7 }),
    call('u1', '2026-11-04T10:00:01.000Z', 10, { model: 'mystery-model-9' }),
    call('m1', '2026-11-04T10:00:02.000Z', 10),
  ]);
  const agg = r.state.agg['2026-11-04|boot'];
  assert.equal(agg.calls, 2);
  assert.equal(agg.unp, 1);
  assert.deepEqual(agg.models, { 'mystery-model-9': 1, [OPUS]: 1 });
  assert.equal(r.state.refused, 1);
});

test('refused records never change the totals: an identity conflict and a malformed usage keep the first answer', () => {
  const r = run([
    call('m1', '2026-11-04T10:00:00.000Z', 100),
    call('m1', '2026-11-04T10:00:01.000Z', 999, { req: 'req_other' }),
    { type: 'assistant', timestamp: '2026-11-04T10:00:02.000Z', message: { id: 'm2', model: OPUS, content: [], usage: { input_tokens: -1 } } },
  ]);
  assert.equal(r.state.agg['2026-11-04|boot'].o, 100);
  assert.equal(r.state.agg['2026-11-04|boot'].calls, 1);
  assert.equal(r.state.refused, 2);
});

test('a model name from the transcript is only an own property of the models map, never a prototype write', () => {
  const r = run([call('m1', '2026-11-04T10:00:00.000Z', 10, { model: '__proto__' })]);
  assert.equal(r.status, 0, r.stderr);
  const models = r.state.agg['2026-11-04|boot'].models;
  assert.deepEqual(Object.keys(models), ['__proto__']);
  assert.equal(Object.hasOwn(models, '__proto__'), true);
  assert.equal(r.state.agg['2026-11-04|boot'].unp, 1);
  const again = run([call('m1', '2026-11-04T10:00:01.000Z', 20, { model: '__proto__' })], { state: r.state, start: r.end });
  assert.deepEqual(Object.keys(again.state.agg['2026-11-04|boot'].models), ['__proto__']);
  assert.equal(again.state.agg['2026-11-04|boot'].calls, 1);
});

test('the dollars equal priceTranscripts in integer nanodollars, split across two runs', () => {
  const lines = [
    call('m1', '2026-11-04T10:00:00.000Z', 100), call('m1', '2026-11-04T10:00:01.000Z', 1000),
    call('m2', '2026-11-04T10:00:02.000Z', 50, { model: 'claude-sonnet-5-5', tool: 'ls' }),
    call('m3', '2026-11-04T10:00:03.000Z', 70, { model: 'gpt-6.1-sol' }),
    call('m4', '2026-11-04T10:00:04.000Z', 5, { model: 'mystery-model-9' }),
    call('m3', '2026-11-04T10:00:05.000Z', 90, { model: 'gpt-6.1-sol' }),
  ];
  const a = run(lines.slice(0, 3));
  const b = run(lines.slice(3), { state: a.state, start: a.end });
  const dir = mkdtempSync(join(tmpdir(), 'pcs-parity-'));
  try {
    writeFileSync(join(dir, 'x.jsonl'), serialize(lines));
    const expected = priceTranscripts(dir, loadPrices());
    const nano = Object.values(b.state.agg).reduce((n, v) => n + BigInt(v.nano), 0n);
    assert.equal(nano, expected.totalNano);
    assert.equal(Object.values(b.state.agg).reduce((n, v) => n + v.unp, 0), Object.values(expected.unpriced).reduce((n, v) => n + v, 0));
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a schema 1 state exits 3 and prints nothing: its boolean seen map is never reused as contributions', () => {
  const legacy = { off: 10, last: 'boot', seen: { m1: 1 }, agg: { '2026-11-04|boot': { calls: 1, i: 1, o: 1, cr: 1, c5: 1, c1: 0, nano: 5, unp: 0, models: { [OPUS]: 1 } } }, tc: null, ac: null, fp: null, meta: META };
  const r = run([call('m1', '2026-11-04T10:00:00.000Z', 1000)], { state: legacy, start: 10 });
  assert.equal(r.status, 3);
  assert.match(r.stderr, /legacy-state-replay-required/);
  assert.equal(r.stdout, '');
});

test('an id-less call is keyed by its absolute byte offset', () => {
  const bare = { type: 'assistant', timestamp: '2026-11-04T10:00:00.000Z', message: { model: OPUS, content: [], usage: usage(10) } };
  const a = run([bare]);
  const b = run([bare], { state: a.state, start: a.end });
  assert.deepEqual(Object.keys(b.state.seen).sort(), ['o:0', `o:${a.end}`].sort());
  assert.equal(b.state.agg['2026-11-04|boot'].calls, 2);
});

test('tool blocks in a later streaming row advance the cursor, a compaction marker sets it', () => {
  const r = run([
    call('m1', '2026-11-04T10:00:00.000Z', 10),
    call('m1', '2026-11-04T10:00:01.000Z', 10, { tool: 'git commit -m x' }),
    call('m2', '2026-11-04T10:00:02.000Z', 10),
    { type: 'system', subtype: 'compact_boundary' },
    call('m3', '2026-11-04T10:00:03.000Z', 10),
  ]);
  assert.deepEqual(Object.keys(r.state.agg).sort(), ['2026-11-04|boot', '2026-11-04|compaction', '2026-11-04|ship']);
  assert.equal(r.state.last, 'compaction');
});

test('the state keeps the class words only: no title and no message text', () => {
  const r = run([
    { type: 'custom-title', customTitle: 'TITLE_SENTINEL-chief' },
    { type: 'ai-title', aiTitle: 'AI_TITLE_SENTINEL' },
    { ...call('m1', '2026-11-04T10:00:00.000Z', 10), message: { id: 'm1', model: OPUS, content: [{ type: 'text', text: 'BODY_SENTINEL' }], usage: usage(10) } },
  ], { role: 'worker' });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.state.tc_class, 'chief');
  assert.equal(r.state.ac_class, 'other');
  assert.equal(r.state.role, 'worker');
  assert.doesNotMatch(r.stdout, /SENTINEL/);
  assert.equal(only(r.state).length, 1);
});

test('the first-prompt class word is kept once', () => {
  const a = run([call('m1', '2026-11-04T10:00:00.000Z', 10)], { meta: { ...META, fp: 'critic' } });
  assert.equal(a.state.fp, 'critic');
  const b = run([call('m2', '2026-11-04T10:00:01.000Z', 10)], { state: a.state, start: a.end, meta: { ...META, fp: 'none' } });
  assert.equal(b.state.fp, 'critic');
  assert.deepEqual(b.state.meta, META);
});

test('unusable input exits 2 and prints nothing', () => {
  for (const bad of [
    { chunkText: 'x\n', start: 5 },
    { state: { schema: 2, off: 0 }, chunkText: serialize([call('m1', '2026-11-04T10:00:00.000Z', 1)]) },
  ]) {
    const r = run([], bad);
    assert.equal(r.status, 2, JSON.stringify(bad));
    assert.equal(r.stdout, '');
  }
  const missing = spawnSync(process.execPath, [ADAPTER, '--chunk', '/nonexistent/chunk', '--start-offset', '0', '--end-offset', '1', '--meta', '/nonexistent/meta'], { encoding: 'utf8' });
  assert.equal(missing.status, 2);
});
