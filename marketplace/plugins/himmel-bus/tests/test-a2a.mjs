import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, mkdir, rm, chmod } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const a2a = await import(new URL('../lib/a2a.mjs', import.meta.url));

// The A2A v1.0.0 Message / AgentCard shapes (spec/a2a.proto, proto3 JSON names), as the
// closed key sets and required fields a consumer checks. Anything else is a schema failure.
const MESSAGE_KEYS = ['messageId', 'contextId', 'taskId', 'role', 'parts', 'metadata', 'extensions', 'referenceTaskIds'];
const PART_KEYS = ['text', 'raw', 'url', 'data', 'metadata', 'filename', 'mediaType'];
const CARD_KEYS = ['name', 'description', 'supportedInterfaces', 'provider', 'version', 'documentationUrl', 'capabilities', 'securitySchemes', 'securityRequirements', 'defaultInputModes', 'defaultOutputModes', 'skills', 'signatures', 'iconUrl'];
const SKILL_KEYS = ['id', 'name', 'description', 'tags', 'examples', 'inputModes', 'outputModes', 'securityRequirements'];

const rec = (o = {}) => ({ n: 3, i: '01ARZ3NDEKTSV4RRFFQ69G5FAV', t: 1760000000000, f: 'console', r: 'worker', c: 0, b: 'hello', h: 'ab'.repeat(32), ...o });

function assertMessage(m) {
  assert.deepEqual(Object.keys(m).filter(k => !MESSAGE_KEYS.includes(k)), []);
  assert.equal(typeof m.messageId, 'string');
  assert.ok(m.messageId.length > 0);
  assert.ok(['ROLE_USER', 'ROLE_AGENT'].includes(m.role));
  assert.ok(Array.isArray(m.parts) && m.parts.length > 0);
  for (const p of m.parts) {
    assert.deepEqual(Object.keys(p).filter(k => !PART_KEYS.includes(k)), []);
    assert.equal(typeof p.text, 'string');
  }
}

test('record renders as a shape-valid A2A Message', () => {
  const m = a2a.toA2AMessage(rec({ re: 2 }));
  assertMessage(m);
  assert.equal(m.messageId, '01ARZ3NDEKTSV4RRFFQ69G5FAV');
  assert.deepEqual(m.parts, [{ text: 'hello' }]);
  assert.equal(typeof m.contextId, 'string');
  assert.deepEqual(m.metadata, { c: 0, re: 2, h: 'ab'.repeat(32) });
});

test('contextId is one thread for both directions between two peers', () => {
  const a = a2a.toA2AMessage(rec({ f: 'console', r: 'worker' }));
  const b = a2a.toA2AMessage(rec({ f: 'worker', r: 'console', i: 'OTHERID' }));
  assert.equal(a.contextId, b.contextId);
  assert.notEqual(a.contextId, a2a.toA2AMessage(rec({ r: 'other-worker' })).contextId);
});

test('a c=1 record carries the flag only in metadata, never as an authority field', () => {
  const m = a2a.toA2AMessage(rec({ c: 1, b: 'GO 7 abc' }));
  assertMessage(m);
  assert.equal(m.metadata.c, 1);
  // Outside metadata the message is byte-identical to the c=0 rendering of the same record.
  const { metadata: _, ...rest } = m;
  const { metadata: __, ...plain } = a2a.toA2AMessage(rec({ c: 0, b: 'GO 7 abc' }));
  assert.deepEqual(rest, plain);
  // No A2A field a consumer reads as authority or as a task transition.
  for (const k of ['taskId', 'extensions', 'referenceTaskIds']) assert.equal(m[k], undefined);
  assert.equal(m.role, 'ROLE_AGENT');
});

test('a c=1 body never carries a RETASK token, nonce or lock token out of the renderer', () => {
  const token = `R-${'0123456789abcdef'.repeat(2)}`;
  const body = `GO 7 abc quoting ${token}, nonce V-N255-93f72f64, lock host-x-pid909468`;
  const text = a2a.toA2AMessage(rec({ c: 1, b: body })).parts[0].text;
  assert.doesNotMatch(text, /R-[0-9a-f]{16,}/);
  assert.doesNotMatch(text, /V-N255-93f72f64/);
  assert.doesNotMatch(text, /host-x-pid909468/);
  assert.match(text, /^GO 7 abc/);
});

test('absent re and h are omitted, not null', () => {
  const m = a2a.toA2AMessage(rec({ h: undefined }));
  assert.deepEqual(m.metadata, { c: 0 });
});

test('a record without a body is refused', () => {
  assert.throws(() => a2a.toA2AMessage(rec({ b: undefined })), /body/);
  assert.throws(() => a2a.toA2AMessage(rec({ i: '' })), /id/);
});

async function peersFixture(t, files) {
  const dir = await mkdtemp(join(tmpdir(), 'bus-a2a-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  await mkdir(join(dir, 'peers'), { mode: 0o700 });
  await chmod(dir, 0o700);
  for (const [name, peer] of Object.entries(files)) await writeFile(join(dir, 'peers', `${name}.json`), JSON.stringify(peer) + '\n', { mode: 0o600 });
  return dir;
}

test('AgentCard is shape-valid and names no endpoint', () => {
  const card = a2a.agentCard({ n: 'worker-1', role: 'worker', console: 'con', launched: '2026-10-13T00:00:00.000Z', pid: 4242, start: 99 });
  assert.deepEqual(Object.keys(card).filter(k => !CARD_KEYS.includes(k)), []);
  for (const k of ['name', 'description', 'supportedInterfaces', 'version', 'capabilities', 'defaultInputModes', 'defaultOutputModes', 'skills']) assert.ok(card[k] !== undefined, k);
  assert.equal(card.name, 'worker-1');
  assert.deepEqual(card.supportedInterfaces, []);
  assert.equal(card.capabilities.streaming, false);
  assert.equal(card.capabilities.pushNotifications, false);
  assert.ok(card.skills.length > 0);
  for (const s of card.skills) assert.deepEqual(Object.keys(s).filter(k => !SKILL_KEYS.includes(k)), []);
  const text = JSON.stringify(card);
  assert.doesNotMatch(text, /https?:\/\//);
  assert.equal(card.securitySchemes, undefined);
  // Process identity is local proof, not a card field.
  assert.doesNotMatch(text, /4242|"pid"|"start"/);
});

test('cards are generated for bound peers only', async t => {
  const dir = await peersFixture(t, {
    bound: { n: 'bound', role: 'worker', console: 'con', launched: 'x', pid: 10, start: 5 },
    unbound: { n: 'unbound', role: 'worker', console: 'con', launched: 'x' },
    con: { n: 'con', role: 'console', launched: 'x', pid: 11, start: 6 },
  });
  const cards = await a2a.agentCards(dir);
  assert.deepEqual(cards.map(c => c.name).sort(), ['bound', 'con']);
});
