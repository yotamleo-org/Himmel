// semantic-batch.mjs and semantic-batch-shim.mjs against a stubbed Message Batches endpoint on loopback.
// Dummy key and fixture credit config only: no provider call, no real credential.
// Breaks caught: a resubmitted batch, a poll that never reaches results, a result merged under the wrong prompt,
// a cost not at the batch rate, a key sent off-loopback, a credit-exhausted error not told apart from a retry.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { execFile, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createServer } from 'node:http';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';

const run = promisify(execFile);
const HERE = dirname(fileURLToPath(import.meta.url));
const CLIENT = join(HERE, 'semantic-batch.mjs');
const SHIM = join(HERE, 'semantic-batch-shim.mjs');
const T = mkdtempSync(join(tmpdir(), 'semantic-batch-'));
const DUMMY = 'sk-ant-dummy-not-a-real-key-0000';
const sha = (s) => createHash('sha256').update(s).digest('hex');

// the stub: what the endpoint received, and what it answers next
const seen = { posts: [], gets: [], keys: new Set() };
const stub = { create: 'ok', status: 'in_progress', errored: new Set(), realLine: null };
let server, base;

before(async () => {
  server = createServer((req, res) => {
    let body = '';
    req.on('data', (c) => { body += c; });
    req.on('end', () => {
      seen.keys.add(req.headers['x-api-key']);
      const reply = (code, obj) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(typeof obj === 'string' ? obj : JSON.stringify(obj)); };
      if (req.method === 'POST' && req.url === '/v1/messages/batches') {
        seen.posts.push(JSON.parse(body));
        if (stub.create === 'credit') return reply(400, { type: 'error', error: { type: 'invalid_request_error', message: 'Your credit balance is too low to access the Anthropic API.' } });
        return reply(200, { id: 'msgbatch_stub1', type: 'message_batch', processing_status: 'in_progress', created_at: '2026-10-23T10:00:00Z', results_url: null });
      }
      seen.gets.push(req.url);
      if (req.method === 'GET' && req.url === '/v1/messages/batches/msgbatch_stub1') {
        const ended = stub.status === 'ended';
        return reply(200, { id: 'msgbatch_stub1', processing_status: stub.status, request_counts: { processing: ended ? 0 : 2, succeeded: ended ? 1 : 0, errored: 0, canceled: 0, expired: 0 },
          results_url: ended ? `${base}/v1/messages/batches/msgbatch_stub1/results` : null });
      }
      if (req.method === 'GET' && req.url === '/v1/messages/batches/msgbatch_stub1/results') {
        const ids = seen.posts.at(-1).requests.map((r) => r.custom_id);
        if (stub.realLine) return reply(200, JSON.stringify({ ...stub.realLine, custom_id: ids[0] }));
        return reply(200, ids.map((id) => JSON.stringify({ custom_id: id, result: stub.errored.has(id)
          ? { type: 'errored', error: { type: 'error', error: { type: 'api_error', message: 'boom' } } }
          : { type: 'succeeded', message: { id: 'msg_1', type: 'message', role: 'assistant', model: 'claude-sonnet-5-5', stop_reason: 'end_turn',
            content: [{ type: 'text', text: `{"nodes":[{"id":"n_${id.slice(0, 6)}","label":"x"}],"edges":[]}` }],
            usage: { input_tokens: 1000, output_tokens: 500 } } } })).join('\n'));
      }
      reply(404, { error: 'unknown route' });
    });
  });
  await new Promise((ok) => server.listen(0, '127.0.0.1', ok));
  base = `http://127.0.0.1:${server.address().port}`;
});
after(() => { server.close(); rmSync(T, { recursive: true, force: true }); });

function fixture() {
  const dir = mkdtempSync(join(T, 'case-'));
  const config = { version: 1, ledger_path: join(dir, 'ledger.json'), accounts: {
    A: { organization_id: 'org-a', cycle_id: 'cycle-a', cap_usd: '1.00', key_id: 'key-a', reset_at: '2099-01-01T00:00:00Z' },
    B: { organization_id: 'org-b', cycle_id: 'cycle-b', cap_usd: '2.00', key_id: 'key-b', reset_at: '2099-01-01T00:00:00Z' } } };
  writeFileSync(join(dir, 'config.json'), JSON.stringify(config));
  writeFileSync(join(dir, 'key-A.env'), `ANTHROPIC_API_KEY=${DUMMY}\n`, { mode: 0o600 });
  const env = { PATH: process.env.PATH, HOME: dir, HIMMEL_API_CREDIT_CONFIG: join(dir, 'config.json'), HIMMEL_BATCH_BASE_URL: base };
  const prompts = join(dir, 'prompts');
  const prompt = [`prompt one ${Math.random()}`, `prompt two ${Math.random()}`];
  mkdirSync(prompts);
  for (const p of prompt) writeFileSync(join(prompts, `${sha(p)}.txt`), p);
  const batch = join(dir, 'pending');
  const client = (...a) => run(process.execPath, [CLIENT, ...a], { env, encoding: 'utf8' }).then(
    (r) => ({ code: 0, ...r }), (e) => ({ code: e.code, stdout: e.stdout, stderr: e.stderr }));
  const submit = (extra = [], model = 'sonnet') => client('submit', '--dir', batch, '--prompts', prompts, '--account', 'A', '--model', model, '--effort', 'high', ...extra);
  return { dir, env, prompts, prompt, batch, client, submit };
}
const reset = () => { seen.posts.length = 0; seen.gets.length = 0; seen.keys.clear(); stub.create = 'ok'; stub.status = 'in_progress'; stub.errored.clear(); stub.realLine = null; };

test('submit, poll, results: one request per prompt at the batch rate, results keyed by prompt hash', async () => {
  reset();
  const f = fixture();
  const s = await f.submit();
  assert.equal(s.code, 0, s.stderr);
  assert.deepEqual(JSON.parse(s.stdout), { batch_id: 'msgbatch_stub1', request_count: 2, status: 'in_progress' });
  assert.equal(seen.posts.length, 1);
  const reqs = seen.posts[0].requests;
  assert.deepEqual(reqs.map((r) => r.custom_id).sort(), f.prompt.map(sha).sort());
  const one = reqs.find((r) => r.custom_id === sha(f.prompt[0]));
  assert.deepEqual(one.params, { model: 'claude-sonnet-5-5', max_tokens: 32000, output_config: { effort: 'high' }, messages: [{ role: 'user', content: f.prompt[0] }] });
  assert.deepEqual([...seen.keys], [DUMMY]);
  assert.equal(JSON.parse(readFileSync(join(f.batch, 'batch.json'), 'utf8')).batch_id, 'msgbatch_stub1');

  assert.equal(JSON.parse((await f.client('poll', '--dir', f.batch)).stdout).status, 'in_progress');
  const early = await f.client('results', '--dir', f.batch, '--out', join(f.dir, 'res'));
  assert.equal(early.code, 4, 'results before the batch ended must say so, not return nothing');

  stub.status = 'ended';
  assert.equal(JSON.parse((await f.client('poll', '--dir', f.batch)).stdout).status, 'ended');
  stub.errored.add(sha(f.prompt[1]));
  const r = await f.client('results', '--dir', f.batch, '--out', join(f.dir, 'res'));
  assert.equal(r.code, 0, r.stderr);
  // 1000 in x $1/M + 500 out x $5/M, the batch rate for one succeeded request
  assert.deepEqual(JSON.parse(r.stdout), { batch_id: 'msgbatch_stub1', succeeded: 1, missing: 1, cost_usd: '0.003500' });
  assert.deepEqual(readdirSync(join(f.dir, 'res')), [`${sha(f.prompt[0])}.json`]);
  const env = JSON.parse(readFileSync(join(f.dir, 'res', `${sha(f.prompt[0])}.json`), 'utf8'));
  assert.equal(env.type, 'result');
  assert.equal(env.is_error, false);
  assert.match(env.result, /"nodes"/);
  assert.equal(JSON.parse(readFileSync(join(f.batch, 'batch.json'), 'utf8')).cost_usd, '0.003500');
});

// fixtures/batch-result-line.json is the first line the live Batches API returned for a 5-request sample batch
// (msgbatch_01HoHw8Kj1H9NupjQ3v4PvqC, 2026-10-23), unedited except the answer text cut to 160 characters. Its custom_id
// is a hash of a prompt this suite does not have, so the stub re-keys it to the submitted prompt.
test('a real results line: the answer text is kept and the cost comes from its real usage at the batch rate', async () => {
  reset();
  const real = JSON.parse(readFileSync(join(HERE, 'fixtures', 'batch-result-line.json'), 'utf8'));
  assert.ok(real.result.message.content.some((c) => c.type === 'thinking'), 'the fixture must keep the thinking block the real API sends');
  stub.realLine = real;
  const f = fixture();
  assert.equal((await f.submit()).code, 0);
  stub.status = 'ended';
  assert.equal((await f.client('poll', '--dir', f.batch)).code, 0);
  const r = await f.client('results', '--dir', f.batch, '--out', join(f.dir, 'res'));
  assert.equal(r.code, 0, r.stderr);
  // 49263 in x $1/M + 20454 out x $5/M (thinking tokens are inside output_tokens)
  assert.deepEqual(JSON.parse(r.stdout), { batch_id: 'msgbatch_stub1', succeeded: 1, missing: 1, cost_usd: '0.151533' });
  const [file] = readdirSync(join(f.dir, 'res'));
  assert.equal(file, `${seen.posts[0].requests[0].custom_id}.json`);
  const env = JSON.parse(readFileSync(join(f.dir, 'res', file), 'utf8'));
  assert.equal(env.result, real.result.message.content.find((c) => c.type === 'text').text);
  assert.equal(env.is_error, false);
});

test('a pending batch is resumed, never resubmitted', async () => {
  reset();
  const f = fixture();
  assert.equal((await f.submit()).code, 0);
  const again = await f.submit();
  assert.equal(again.code, 2);
  assert.match(again.stderr, /resumed, never resubmitted/);
  assert.equal(seen.posts.length, 1, 'the endpoint saw a second create');
  stub.status = 'ended';
  assert.equal((await f.client('poll', '--dir', f.batch)).code, 0);
  assert.equal((await f.client('results', '--dir', f.batch, '--out', join(f.dir, 'res'))).code, 0);
  assert.equal(seen.posts.length, 1);
});

test('credit exhausted exits 5 and leaves no pending batch', async () => {
  reset();
  stub.create = 'credit';
  const f = fixture();
  const s = await f.submit();
  assert.equal(s.code, 5);
  assert.match(s.stderr, /credit exhausted/);
  assert.equal(existsSync(join(f.batch, 'batch.json')), false);
});

test('refusals send nothing: off-loopback endpoint, unhashed prompt, unpriced model, loose key file', async () => {
  reset();
  const f = fixture();
  f.env.HIMMEL_BATCH_BASE_URL = 'https://evil.example';
  const off = await f.submit();
  assert.equal(off.code, 2);
  assert.match(off.stderr, /loopback/);
  f.env.HIMMEL_BATCH_BASE_URL = base;
  writeFileSync(join(f.prompts, `${sha('other')}.txt`), 'not the hashed text');
  assert.match((await f.submit()).stderr, /does not hash to its name/);
  rmSync(join(f.prompts, `${sha('other')}.txt`));
  assert.match((await f.submit([], 'gpt-9')).stderr, /no batch price/);
  writeFileSync(join(f.dir, 'key-A.env'), `ANTHROPIC_API_KEY=${DUMMY}\n`, { mode: 0o644 });
  spawnSync('chmod', ['644', join(f.dir, 'key-A.env')]);
  assert.match((await f.submit()).stderr, /mode 600/);
  assert.equal(seen.posts.length, 0);
});

const shim = (env, input, ...args) => spawnSync(process.execPath, [SHIM, ...args], { env: { PATH: process.env.PATH, ...env }, input, encoding: 'utf8' });

test('shim: record writes the prompt under its hash, replay answers from the batch result and misses exit 1', async () => {
  reset();
  const f = fixture();
  const rec = join(f.dir, 'rec');
  const addendum = join(f.dir, 'addendum.txt');
  writeFileSync(addendum, 'ADDENDUM TEXT\n');
  const flags = ['-p', '--output-format', 'json', '--no-session-persistence', '--model', 'sonnet', '--json-schema', '{}'];
  const r = shim({ GRAPHIFY_BATCH_MODE: 'record', GRAPHIFY_BATCH_DIR: rec, GRAPHIFY_SEMANTIC_ADDENDUM: addendum }, 'chunk prompt', ...flags);
  assert.equal(r.status, 0, r.stderr);
  const full = 'chunk prompt\n\n---\nADDENDUM TEXT\n';
  assert.deepEqual(readdirSync(rec), [`${sha(full)}.txt`]);
  assert.equal(readFileSync(join(rec, `${sha(full)}.txt`), 'utf8'), full);
  const placeholder = JSON.parse(JSON.parse(r.stdout).result);
  assert.ok(placeholder.nodes.length > 0, 'a placeholder with no node would be retried by graphify as a hollow reply');

  // the recorded prompts go through submit and results, then replay returns the batch's own answer
  assert.equal((await f.client('submit', '--dir', f.batch, '--prompts', rec, '--account', 'A', '--model', 'sonnet')).code, 0);
  stub.status = 'ended';
  assert.equal((await f.client('poll', '--dir', f.batch)).code, 0);
  const res = join(f.dir, 'res');
  assert.equal((await f.client('results', '--dir', f.batch, '--out', res)).code, 0);
  const hit = shim({ GRAPHIFY_BATCH_MODE: 'replay', GRAPHIFY_BATCH_DIR: res, GRAPHIFY_SEMANTIC_ADDENDUM: addendum }, 'chunk prompt', ...flags);
  assert.equal(hit.status, 0, hit.stderr);
  assert.match(JSON.parse(hit.stdout).result, new RegExp(`n_${sha(full).slice(0, 6)}`));
  const miss = shim({ GRAPHIFY_BATCH_MODE: 'replay', GRAPHIFY_BATCH_DIR: res, GRAPHIFY_SEMANTIC_ADDENDUM: addendum }, 'a different chunk', ...flags);
  assert.equal(miss.status, 1);
  assert.match(miss.stderr, /no answer for prompt/);
});

test('shim: refuses an argument graphify does not send and a missing mode', () => {
  assert.equal(shim({ GRAPHIFY_BATCH_MODE: 'record', GRAPHIFY_BATCH_DIR: T }, '', '-p', '--dangerous').status, 2);
  assert.equal(shim({}, '', '-p').status, 2);
});
