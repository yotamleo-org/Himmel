// OpenAI API launcher fixtures: a local stub server, dummy keys and a temp roster. No live call.
// Breaks caught: a request without the roster, key-file or bound checks, a cost that is not the priced usage,
// a key in any output, an ambient OPENAI_API_KEY used, a rejected key or empty credit left unmarked.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const SUT = join(dirname(fileURLToPath(import.meta.url)), 'openai-api.mjs');
const KEY = 'sk-test-dummy-00000000000000000000';
const MODEL = 'gpt-5-mini';
const T = mkdtempSync(join(tmpdir(), 'openai-api-'));
process.on('exit', () => rmSync(T, { recursive: true, force: true }));

async function fixture({ cap = '1.000000', key = true, keyMode = 0o600, responder } = {}) {
  const dir = mkdtempSync(join(T, 'case-'));
  const ledger = join(dir, 'ledger.json');
  const config = join(dir, 'config.json');
  writeFileSync(config, JSON.stringify({ version: 1, ledger_path: ledger,
    accounts: { A: { organization_id: 'org-test', cycle_id: 'c1', cap_usd: cap } } }));
  if (key) {
    const keyFile = join(dir, 'key-A.env');
    writeFileSync(keyFile, `OPENAI_API_KEY=${KEY}\n`);
    chmodSync(keyFile, keyMode);
  }
  const requests = [];
  const server = createServer((req, res) => {
    let raw = '';
    req.on('data', (c) => { raw += c; });
    req.on('end', () => {
      requests.push({ url: req.url, headers: req.headers, body: JSON.parse(raw) });
      const [status, payload] = responder ? responder(requests.at(-1)) : [200, completed()];
      res.writeHead(status, { 'Content-Type': 'application/json' });
      res.end(typeof payload === 'string' ? payload : JSON.stringify(payload));
    });
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}/v1`;
  const env = { PATH: process.env.PATH, HOME: dir, TMPDIR: dir, HIMMEL_API_LANE: 'on', HIMMEL_OPENAI_ACCOUNT: 'A',
    HIMMEL_OPENAI_CREDIT_CONFIG: config, HIMMEL_OPENAI_BASE_URL: base };
  const run = (args, { stdin = '', extraEnv = {}, dropEnv = [] } = {}) => new Promise((resolve) => {
    const e = { ...env, ...extraEnv };
    for (const k of dropEnv) delete e[k];
    const child = spawn(process.execPath, [SUT, ...args], { env: e, stdio: ['pipe', 'pipe', 'pipe'] });
    let stdout = '', stderr = '';
    child.stdout.on('data', (c) => { stdout += c; });
    child.stderr.on('data', (c) => { stderr += c; });
    child.on('close', (code) => resolve({ code, stdout, stderr }));
    child.stdin.end(stdin);
  });
  const readLedger = () => JSON.parse(readFileSync(ledger, 'utf8'));
  return { dir, run, requests, readLedger, close: () => server.close() };
}

function completed(text = 'hello from the stub', usage) {
  return {
    id: 'resp_test_1', model: MODEL, status: 'completed',
    output: [{ type: 'reasoning', summary: [] },
      { type: 'message', content: [{ type: 'output_text', text }, { type: 'refusal', text: 'not output' }] }],
    usage: usage ?? { input_tokens: 1000, input_tokens_details: { cached_tokens: 200 }, output_tokens: 500,
      output_tokens_details: { reasoning_tokens: 120 } },
  };
}
const PRICES = JSON.parse(readFileSync(join(dirname(SUT), 'openai-prices.json'), 'utf8')).models[MODEL];
const NANO = { input: PRICES.input * 1000, cached: PRICES.cached_input * 1000, output: PRICES.output * 1000 };
const COST = `0.${String(Math.ceil((800 * NANO.input + 200 * NANO.cached + 500 * NANO.output) / 1000)).padStart(6, '0')}`;

const args = (extra = [], model = MODEL) => ['-p', 'say hello', '--model', model, '--max-budget-usd', '0.01', ...extra];

async function withFixture(opts, fn) {
  const f = await fixture(opts);
  try { await fn(f); } finally { f.close(); }
}
const onlyJob = (ledger) => Object.values(ledger.accounts.A.jobs).at(-1);

test('lane off refuses and sends nothing', () => withFixture({}, async (f) => {
  const r = await f.run(args(), { dropEnv: ['HIMMEL_API_LANE'] });
  assert.equal(r.code, 2);
  assert.match(r.stderr, /^openai-api: refused: api lane is OFF \(set HIMMEL_API_LANE=on\)/);
  assert.equal(f.requests.length, 0);
}));

test('a missing key file refuses', () => withFixture({ key: false }, async (f) => {
  const r = await f.run(args());
  assert.equal(r.code, 2);
  assert.match(r.stderr, /refused: no key file/);
  assert.equal(f.requests.length, 0);
}));

test('a key file with mode 644 refuses', () => withFixture({ keyMode: 0o644 }, async (f) => {
  const r = await f.run(args());
  assert.equal(r.code, 2);
  assert.match(r.stderr, /refused: .*mode 600/);
  assert.equal(f.requests.length, 0);
}));

test('an unpriced model refuses', () => withFixture({}, async (f) => {
  const r = await f.run(['-p', 'hi', '--model', 'gpt-nope', '--max-budget-usd', '0.01']);
  assert.equal(r.code, 2);
  assert.match(r.stderr, /refused: no price for model gpt-nope/);
  assert.equal(f.requests.length, 0);
}));

test('a model id with a bad shape refuses', () => withFixture({}, async (f) => {
  const r = await f.run(['-p', 'hi', '--model', 'gpt 5/x', '--max-budget-usd', '0.01']);
  assert.equal(r.code, 2);
  assert.equal(f.requests.length, 0);
}));

test('a budget too small for the prompt refuses', () => withFixture({}, async (f) => {
  const r = await f.run(['-p', 'hi', '--model', MODEL, '--max-budget-usd', '0.00001']);
  assert.equal(r.code, 2);
  assert.match(r.stderr, /refused: budget too small/);
  assert.equal(f.requests.length, 0);
}));

test('a budget over the account cap refuses and leaves nothing reserved', () => withFixture({ cap: '0.010000' }, async (f) => {
  const r = await f.run(['-p', 'hi', '--model', MODEL, '--max-budget-usd', '1']);
  assert.equal(r.code, 2);
  assert.match(r.stderr, /^openai-api: refused: /);
  assert.equal(f.requests.length, 0);
  const job = onlyJob(f.readLedger());
  assert.equal(job.status, 'settled');
  assert.equal(job.actual_usd, '0.000000');
}));

test('a stray flag refuses', () => withFixture({}, async (f) => {
  const r = await f.run(args(['--dangerously-skip-permissions']));
  assert.equal(r.code, 2);
  assert.match(r.stderr, /refused: unsupported flag/);
  assert.equal(f.requests.length, 0);
}));

test('auto is refused', () => withFixture({}, async (f) => {
  const r = await f.run(args(), { extraEnv: { HIMMEL_OPENAI_ACCOUNT: 'auto' } });
  assert.equal(r.code, 2);
  assert.equal(f.requests.length, 0);
}));

test('success prints the text, bounds the request and settles the exact cost', () => withFixture({}, async (f) => {
  const r = await f.run(args(['--effort', 'low']));
  assert.equal(r.code, 0, r.stderr);
  assert.equal(r.stdout.trim(), 'hello from the stub');
  assert.equal(f.requests.length, 1);
  const q = f.requests[0];
  assert.equal(q.url, '/v1/responses');
  assert.equal(q.headers.authorization, `Bearer ${KEY}`);
  assert.equal(q.body.store, false);
  assert.equal(q.body.model, MODEL);
  assert.equal(q.body.input, 'say hello');
  assert.deepEqual(q.body.reasoning, { effort: 'low' });
  assert.equal('instructions' in q.body, false);
  const budgetNano = 0.01 * 1e9, inputBound = Buffer.byteLength('say hello') + 256;
  assert.equal(q.body.max_output_tokens, Math.floor((budgetNano - inputBound * NANO.input) / NANO.output));
  const job = onlyJob(f.readLedger());
  assert.equal(job.status, 'settled');
  assert.equal(job.actual_usd, COST);
  assert.equal(job.maximum_usd, '0.010000');
  assert.ok(!r.stdout.includes(KEY) && !r.stderr.includes(KEY));
}));

test('legacy models keep top-level instructions and count them toward the bound', () => withFixture({}, async (f) => {
  const file = join(f.dir, 'sys.txt');
  writeFileSync(file, 'be brief');
  const r = await f.run(args(['--append-system-prompt-file', file]));
  assert.equal(r.code, 0, r.stderr);
  assert.equal(f.requests[0].body.instructions, 'be brief');
  assert.equal(f.requests[0].body.max_output_tokens, Math.floor((10000000 - (8 + 9 + 256) * 250) / 2000));
}));

for (const model of ['gpt-6.2-sol', 'gpt-6.2-astra']) {
  test(`${model} gets a developer prefix and maps none to low`, () => withFixture({}, async (f) => {
    const file = join(f.dir, 'sys.txt');
    writeFileSync(file, 'be brief');
    const r = await f.run(args(['--effort', 'none', '--append-system-prompt-file', file], model));
    assert.equal(r.code, 0, r.stderr);
    const { body } = f.requests[0];
    assert.equal(body.model, model);
    assert.deepEqual(body.input, [
      { role: 'developer', content: 'be brief' },
      { role: 'user', content: 'say hello' },
    ]);
    assert.equal('instructions' in body, false);
    assert.deepEqual(body.reasoning, { effort: 'low' });
  }));
}

for (const model of ['gpt-6.1-sol', 'gpt-6-astra']) {
  test(`${model} keeps the existing prompt shape`, () => withFixture({}, async (f) => {
    const file = join(f.dir, 'sys.txt');
    writeFileSync(file, 'be brief');
    const r = await f.run(args(['--effort', 'medium', '--append-system-prompt-file', file], model));
    assert.equal(r.code, 0, r.stderr);
    const { body } = f.requests[0];
    assert.equal(body.model, model);
    assert.equal(body.instructions, 'be brief');
    assert.equal(body.input, 'say hello');
    assert.deepEqual(body.reasoning, { effort: 'medium' });
  }));
}

test('json output carries the result, the cost and the usage', () => withFixture({}, async (f) => {
  const r = await f.run(args(['--output-format', 'json']));
  assert.equal(r.code, 0, r.stderr);
  assert.deepEqual(JSON.parse(r.stdout), {
    type: 'result', subtype: 'success', is_error: false, result: 'hello from the stub', model: MODEL,
    total_cost_usd: 0.001205,
    usage: { input_tokens: 1000, cached_input_tokens: 200, output_tokens: 500, reasoning_tokens: 120 },
    response_id: 'resp_test_1', account: 'A',
  });
}));

test('a prompt on stdin is sent', () => withFixture({}, async (f) => {
  const r = await f.run(['-p', '--model', MODEL, '--max-budget-usd', '0.01'], { stdin: 'from stdin' });
  assert.equal(r.code, 0, r.stderr);
  assert.equal(f.requests[0].body.input, 'from stdin');
}));

test('401 marks the key rejected and exits 6', () => withFixture({
  responder: () => [401, { error: { code: 'invalid_api_key', message: 'bad key' } }],
}, async (f) => {
  const r = await f.run(args());
  assert.equal(r.code, 6);
  assert.match(r.stderr, /openai-api: account A rejected the key/);
  const ledger = f.readLedger();
  assert.ok(Number.isInteger(ledger.accounts.A.key_rejected_at));
  assert.equal(onlyJob(ledger).actual_usd, '0.000000');
}));

test('429 insufficient_quota marks the account exhausted and exits 6', () => withFixture({
  responder: () => [429, { error: { code: 'insufficient_quota', message: 'quota' } }],
}, async (f) => {
  const r = await f.run(args());
  assert.equal(r.code, 6);
  assert.match(r.stderr, /openai-api: account A is out of credit/);
  const ledger = f.readLedger();
  assert.ok(Number.isInteger(ledger.accounts.A.exhausted_at));
  assert.equal(onlyJob(ledger).actual_usd, '0.000000');
}));

test('a 500 that echoes the key is redacted, one line, and leaves the reservation unknown', () => withFixture({
  responder: () => [500, { error: { message: `server broke\nfor key ${KEY} and sk-other-secret-1234567 ${'x'.repeat(400)}` } }],
}, async (f) => {
  const r = await f.run(args());
  assert.equal(r.code, 1);
  assert.match(r.stderr, /^openai-api: call failed \(HTTP 500\): server broke for key \[redacted\] and \[redacted\] x+; its cost is unknown and the reservation is marked unknown\n$/);
  assert.ok(!r.stderr.includes(KEY) && !r.stderr.includes('sk-other'));
  assert.ok(r.stderr.length < 400);
  assert.equal(onlyJob(f.readLedger()).status, 'unknown');
}));

test('a 400 is settled at zero', () => withFixture({
  responder: () => [400, { error: { message: 'bad request' } }],
}, async (f) => {
  const r = await f.run(args());
  assert.equal(r.code, 1);
  assert.match(r.stderr, /^openai-api: call failed \(HTTP 400\): bad request\n$/);
  assert.equal(onlyJob(f.readLedger()).actual_usd, '0.000000');
}));

test('an incomplete response settles its cost, prints what exists and exits 1', () => withFixture({
  responder: () => [200, { ...completed('partial'), status: 'incomplete', incomplete_details: { reason: 'max_output_tokens' } }],
}, async (f) => {
  const r = await f.run(args());
  assert.equal(r.code, 1);
  assert.equal(r.stdout.trim(), 'partial');
  assert.match(r.stderr, /openai-api: incomplete: max_output_tokens/);
  assert.equal(onlyJob(f.readLedger()).actual_usd, COST);
}));

test('an unreachable server leaves the reservation unknown', () => withFixture({}, async (f) => {
  const r = await f.run(args(), { extraEnv: { HIMMEL_OPENAI_BASE_URL: 'http://127.0.0.1:1/v1' } });
  assert.equal(r.code, 1);
  assert.match(r.stderr, /cost is unknown/);
  assert.equal(onlyJob(f.readLedger()).status, 'unknown');
}));

test('a timeout exits 124 and leaves the reservation unknown', () => withFixture({}, async (f) => {
  const hung = createServer(() => {});
  await new Promise((r) => hung.listen(0, '127.0.0.1', r));
  try {
    const r = await f.run(args(), { extraEnv: { HIMMEL_OPENAI_BASE_URL: `http://127.0.0.1:${hung.address().port}/v1`, HIMMEL_API_CALL_TIMEOUT_S: '1' } });
    assert.equal(r.code, 124);
    assert.equal(onlyJob(f.readLedger()).status, 'unknown');
  } finally { hung.closeAllConnections(); hung.close(); }
}));

test('an ambient OPENAI_API_KEY is not used', () => withFixture({}, async (f) => {
  const r = await f.run(args(), { extraEnv: { OPENAI_API_KEY: 'sk-ambient-0000000000000000' } });
  assert.equal(r.code, 0, r.stderr);
  assert.equal(f.requests[0].headers.authorization, `Bearer ${KEY}`);
}));
