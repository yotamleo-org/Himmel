// semantic-batch.mjs — Message Batches API client for the graphify claude-api extraction.
//
// WHY: nothing waits on the graph refresh in real time, so its extraction calls go through the Message Batches
// API at 50 % of the list price. One batch per run, one request per chunk prompt; the batch id is persisted in
// <dir>/batch.json so a later run resumes it and never resubmits.
//
//   submit  --dir D --prompts P --account A|B --model M --effort E [--max-tokens N]
//           P holds one file per chunk prompt, named <sha256 of the prompt>.txt (the custom_id). Refuses when
//           D/batch.json exists. Prints {batch_id, request_count, status}.
//   poll    --dir D
//           Prints {batch_id, status: in_progress|ended, counts}; exit 0 either way.
//   results --dir D --out R
//           Needs an ended batch (exit 4 otherwise). Writes R/<custom_id>.json, a `claude -p --output-format
//           json` envelope, for each succeeded request; errored, canceled and expired ones leave no file.
//           Prints {batch_id, succeeded, missing, cost_usd} and records the cost in D/batch.json.
//
// Exit: 0 ok; 2 usage or refusal; 3 API or network failure (retry next run); 4 batch not ended;
//       5 credit exhausted (the caller rotates account).
// Key: read here from <state_dir>/key-<account>.env (mode 600, the lane's own file), never printed or put on argv.
// Endpoint: https://api.anthropic.com, or HIMMEL_BATCH_BASE_URL when it is a loopback http(s) URL (test stub).
// Spend is not gated here (operator decision 229): the cost lands in the run row and the provider's cost report.
import { createHash } from 'node:crypto';
import { existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, renameSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const API = 'https://api.anthropic.com';
const ID = /^[a-f0-9]{64}$/;
// Batch price, USD per million tokens (input, output): half the list price. Cache reads bill at 0.1 x input,
// 5-minute cache writes at 1.25 x input.
// ponytail: a hand-kept table of the models graphify extraction uses, from the docs 2026-10-23; an unlisted model is
// refused rather than priced by guess. Upgrade path: read the price from the provider's cost report.
const PRICE = {
  'claude-sonnet-5-5': [1, 5], 'claude-sonnet-5': [1, 5], 'claude-sonnet-4-6': [1.5, 7.5],
  'claude-haiku-5-5': [0.05, 0.25], 'claude-opus-5-5': [2, 10],
};
const ALIAS = { sonnet: 'claude-sonnet-5-5', haiku: 'claude-haiku-5-5', opus: 'claude-opus-5-5' };
const EFFORT = ['low', 'medium', 'high', 'xhigh', 'max'];

class Refusal extends Error {
  constructor(code, message) { super(message); this.code = code; }
}
const refuse = (m, code = 2) => { throw new Refusal(code, m); };

function opts(args) {
  const o = {};
  for (let i = 0; i < args.length; i += 2) {
    if (!args[i]?.startsWith('--') || args[i + 1] === undefined || Object.hasOwn(o, args[i].slice(2))) refuse(`bad arguments near '${args[i] ?? ''}'`);
    o[args[i].slice(2)] = args[i + 1];
  }
  return o;
}

function baseUrl() {
  const raw = process.env.HIMMEL_BATCH_BASE_URL;
  if (!raw) return API;
  let u;
  try { u = new URL(raw); } catch { refuse('HIMMEL_BATCH_BASE_URL does not parse'); }
  if (!['localhost', '127.0.0.1', '[::1]'].includes(u.hostname) || !['http:', 'https:'].includes(u.protocol)) {
    refuse('HIMMEL_BATCH_BASE_URL must be a loopback URL; the key is never sent anywhere else');
  }
  return u.origin;
}

async function accountKey(account) {
  if (!['A', 'B'].includes(account)) refuse('--account must be A or B');
  const { configuredAccount } = await import(pathToFileURL(join(HERE, '../lib/api-credit-state.mjs')).href);
  const row = configuredAccount({ ...process.env, HIMMEL_API_ACCOUNT: account });
  if (row.verdict) refuse(`roster: ${row.reason}`);
  const file = join(dirname(row.ledger_path), `key-${account}.env`);
  let st;
  try { st = lstatSync(file); } catch { refuse(`no key file for account ${account}`); }
  if (!st.isFile() || (st.mode & 0o777) !== 0o600 || st.uid !== process.getuid()) refuse(`key file for account ${account} must be mode 600 and owned by you`);
  const line = readFileSync(file, 'utf8').split('\n').find((l) => l.startsWith('ANTHROPIC_API_KEY='));
  const key = line?.slice('ANTHROPIC_API_KEY='.length).trim().replace(/^(["'])(.*)\1$/, '$2');
  if (!key) refuse(`key file for account ${account} has no ANTHROPIC_API_KEY line`);
  return key;
}

async function call(key, method, path, body) {
  const url = path.startsWith('http') ? path : `${baseUrl()}${path}`;
  let res;
  try {
    res = await fetch(url, {
      method,
      headers: { 'x-api-key': key, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body),
      redirect: 'error', signal: AbortSignal.timeout(120000),
    });
  } catch (e) { refuse(`network failure: ${e.name}`, 3); }
  const text = await res.text();
  if (!res.ok) {
    if (/credit balance|insufficient.{0,20}credit|billing/i.test(text)) refuse(`credit exhausted (HTTP ${res.status})`, 5);
    refuse(`HTTP ${res.status}: ${text.slice(0, 300).replace(/\s+/g, ' ')}`, 3);
  }
  return text;
}

const statePath = (dir) => join(resolve(dir), 'batch.json');
function load(dir) {
  try { return JSON.parse(readFileSync(statePath(dir), 'utf8')); } catch { refuse(`no readable ${statePath(dir)}`); }
}
function save(dir, state) {
  const tmp = `${statePath(dir)}.tmp`;
  writeFileSync(tmp, `${JSON.stringify(state, null, 1)}\n`, { mode: 0o600 });
  renameSync(tmp, statePath(dir));
}
const out = (v) => console.log(JSON.stringify(v));

async function submit(o) {
  const dir = resolve(o.dir ?? refuse('--dir is required'));
  if (existsSync(statePath(dir))) refuse(`${statePath(dir)} exists: a pending batch is resumed, never resubmitted`);
  const model = ALIAS[o.model] ?? o.model;
  if (!PRICE[model]) refuse(`model '${o.model}' has no batch price in the table`);
  const effort = o.effort ?? 'high';
  if (!EFFORT.includes(effort)) refuse(`--effort must be one of ${EFFORT.join(', ')}`);
  const maxTokens = Number(o['max-tokens'] ?? 32000);
  if (!Number.isInteger(maxTokens) || maxTokens < 1) refuse('--max-tokens must be a positive integer');
  const files = readdirSync(o.prompts ?? refuse('--prompts is required')).filter((f) => f.endsWith('.txt')).sort();
  if (files.length === 0) refuse('no prompts to submit');
  const requests = files.map((f) => {
    const id = f.slice(0, -4);
    if (!ID.test(id)) refuse(`prompt file '${f}' is not named <sha256>.txt`);
    const text = readFileSync(join(o.prompts, f), 'utf8');
    if (createHash('sha256').update(text).digest('hex') !== id) refuse(`prompt file '${f}' does not hash to its name`);
    return { custom_id: id, params: { model, max_tokens: maxTokens, output_config: { effort }, messages: [{ role: 'user', content: text }] } };
  });
  const key = await accountKey(o.account);
  const made = JSON.parse(await call(key, 'POST', '/v1/messages/batches', { requests }));
  if (typeof made.id !== 'string' || !made.id) refuse('the create reply carries no batch id', 3);
  mkdirSync(dir, { recursive: true });
  const state = { version: 1, batch_id: made.id, account: o.account, model, effort, request_count: requests.length,
    custom_ids: requests.map((r) => r.custom_id), created_at: made.created_at ?? null, status: made.processing_status ?? 'in_progress' };
  save(dir, state);
  out({ batch_id: state.batch_id, request_count: state.request_count, status: state.status });
}

async function poll(o) {
  const dir = resolve(o.dir ?? refuse('--dir is required'));
  const state = load(dir);
  const b = JSON.parse(await call(await accountKey(state.account), 'GET', `/v1/messages/batches/${encodeURIComponent(state.batch_id)}`));
  state.status = b.processing_status === 'ended' ? 'ended' : 'in_progress';
  if (b.results_url) state.results_url = b.results_url;
  state.counts = b.request_counts ?? null;
  save(dir, state);
  out({ batch_id: state.batch_id, status: state.status, counts: state.counts });
}

function cost(model, u) {
  const [pin, pout] = PRICE[model];
  const inTok = (u.input_tokens ?? 0) + 1.25 * (u.cache_creation_input_tokens ?? 0) + 0.1 * (u.cache_read_input_tokens ?? 0);
  return (inTok * pin + (u.output_tokens ?? 0) * pout) / 1e6;
}

async function results(o) {
  const dir = resolve(o.dir ?? refuse('--dir is required'));
  const state = load(dir);
  if (state.status !== 'ended' || !state.results_url) refuse(`batch ${state.batch_id} has not ended`, 4);
  if (!state.results_url.startsWith(`${baseUrl()}/`)) refuse('results_url is not on the API origin; the key is not sent there');
  const lines = (await call(await accountKey(state.account), 'GET', state.results_url)).split('\n').filter(Boolean);
  mkdirSync(o.out ?? refuse('--out is required'), { recursive: true });
  let total = 0, succeeded = 0;
  for (const line of lines) {
    let r;
    try { r = JSON.parse(line); } catch { continue; }
    if (!ID.test(r?.custom_id ?? '') || !state.custom_ids.includes(r.custom_id) || r.result?.type !== 'succeeded') continue;
    const m = r.result.message;
    const usage = m?.usage ?? {};
    const usd = cost(state.model, usage);
    total += usd; succeeded += 1;
    const text = (m?.content ?? []).filter((c) => c.type === 'text').map((c) => c.text).join('');
    writeFileSync(join(o.out, `${r.custom_id}.json`), `${JSON.stringify({ type: 'result', subtype: 'success', is_error: false, result: text,
      stop_reason: m?.stop_reason ?? '', usage, modelUsage: { [m?.model ?? state.model]: {} }, total_cost_usd: Number(usd.toFixed(6)) })}\n`, { mode: 0o600 });
  }
  state.cost_usd = total.toFixed(6);
  state.succeeded = succeeded;
  save(dir, state);
  out({ batch_id: state.batch_id, succeeded, missing: state.request_count - succeeded, cost_usd: state.cost_usd });
}

const COMMANDS = { submit, poll, results };
const [cmd, ...rest] = process.argv.slice(2);
try {
  if (!COMMANDS[cmd]) refuse('usage: semantic-batch.mjs submit|poll|results --dir D ...');
  await COMMANDS[cmd](opts(rest));
} catch (e) {
  if (!(e instanceof Refusal)) throw e;
  console.error(`semantic-batch: ${e.message}`);
  process.exit(e.code);
}
