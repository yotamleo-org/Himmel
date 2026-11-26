#!/usr/bin/env node
// one-shot OpenAI API launcher.
// Sends ONE tool-free prompt to the OpenAI Responses API, billed to the OpenAI account named by
// HIMMEL_OPENAI_ACCOUNT, under the same cap / reserve / settle ledger as the Anthropic API lane
// (scripts/lib/api-credit-state.mjs), kept on its own roster so the two never share an account.
//
// Usage: node openai-api.mjs -p [prompt] --model M --max-budget-usd N [--output-format text|json]
//                            [--effort none|low|medium|high|xhigh] [--append-system-prompt-file F]  (no other flags)
//        With no prompt after -p the prompt is read from stdin (a TTY and a prompt over 8 MiB are refused).
//        GPT-6.2 receives the system-prompt file as a developer message before the task.
//        Earlier models receive it as `instructions`.
// Env:   HIMMEL_API_LANE=on  HIMMEL_OPENAI_ACCOUNT=<A|B|C|D>   (auto is not supported)
//        [HIMMEL_OPENAI_CREDIT_CONFIG=<roster>] default ~/.himmel/state/api-credit-openai/config.json
//        [HIMMEL_OPENAI_BASE_URL=<url>] test seam, default https://api.openai.com/v1
//        [HIMMEL_API_CALL_TIMEOUT_S=<seconds>] the call is aborted at this age (default 3600)
//        The key is read only from key-<account>.env beside the roster's ledger (one line, OPENAI_API_KEY=<key>,
//        a regular file, mode 600, owned by the caller). OPENAI_API_KEY in the environment is never used.
//        The key is never printed, logged, passed on a command line or written to a file.
// The spend is bounded before the request: max_output_tokens is derived from the budget, the model's output
//        price and an upper bound of the input size, so a call cannot cost more than --max-budget-usd.
// Exit:  0 the response completed; 1 the call failed or the response was incomplete (cost settled where known);
//        2 a refusal before any request; 6 the account's key was rejected or its credit is out;
//        124 the call timed out (cost unknown, the reservation is marked unknown).
import { lstatSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { configuredAccount, creditState } from '../lib/api-credit-state.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const MAX_PROMPT = 8 * 1024 * 1024;
const MAX_OUT_CAP = 128000;
const MIN_OUT = 16;
const EFFORTS = ['none', 'low', 'medium', 'high', 'xhigh'];

class Refusal extends Error {}
const refuse = (reason) => { throw new Refusal(reason); };

function out(stream, text) {
  return new Promise((done) => stream.write(text, () => done()));
}
async function finish(code) {
  await Promise.all([out(process.stdout, ''), out(process.stderr, '')]);
  process.exit(code);
}

function parseArgs(argv) {
  const o = { prompt: undefined, model: '', budget: '', format: 'text', effort: '', sysFile: '', p: false };
  const value = (i, flag) => {
    const v = argv[i + 1];
    if (v === undefined || v.startsWith('--')) refuse(`${flag} needs a value`);
    return v;
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '-p') {
      o.p = true;
      if (argv[i + 1] !== undefined && !argv[i + 1].startsWith('--')) o.prompt = argv[++i];
    } else if (a === '--model') o.model = value(i++, a);
    else if (a === '--max-budget-usd') o.budget = value(i++, a);
    else if (a === '--output-format') o.format = value(i++, a);
    else if (a === '--effort') o.effort = value(i++, a);
    else if (a === '--append-system-prompt-file') o.sysFile = value(i++, a);
    else refuse(`unsupported flag ${a.slice(0, 40)}`);
  }
  if (!o.p) refuse('-p is required');
  if (!['text', 'json'].includes(o.format)) refuse('--output-format must be text or json');
  if (o.effort && !EFFORTS.includes(o.effort)) refuse(`--effort must be one of ${EFFORTS.join(', ')}`);
  if (!/^[A-Za-z0-9._-]{1,64}$/.test(o.model)) refuse('--model is missing or not a valid model id');
  if (!/^(0|[1-9][0-9]{0,6})(\.[0-9]{1,6})?$/.test(o.budget)) refuse('--max-budget-usd must be a decimal with at most 6 places');
  const [whole, frac = ''] = o.budget.split('.');
  o.budgetMicro = BigInt(whole) * 1000000n + BigInt(frac.padEnd(6, '0'));
  if (o.budgetMicro <= 0n) refuse('--max-budget-usd must be positive');
  return o;
}

async function readStdin() {
  if (process.stdin.isTTY) refuse('no prompt given and stdin is a terminal');
  const chunks = [];
  let size = 0;
  for await (const c of process.stdin) {
    size += c.length;
    if (size > MAX_PROMPT) refuse('prompt over 8 MiB');
    chunks.push(c);
  }
  return Buffer.concat(chunks).toString('utf8');
}

function readKey(dir, letter) {
  const path = join(dir, `key-${letter}.env`);
  let st;
  try { st = lstatSync(path); } catch { refuse(`no key file for account ${letter}`); }
  if (!st.isFile()) refuse(`key file for account ${letter} is not a regular file`);
  if ((st.mode & 0o777) !== 0o600) refuse(`key file for account ${letter} must be mode 600`);
  if (st.uid !== process.getuid()) refuse(`key file for account ${letter} is not owned by the caller`);
  let text;
  try { text = readFileSync(path, 'utf8'); } catch { refuse(`key file for account ${letter} is unreadable`); }
  const m = /^OPENAI_API_KEY=([\x21-\x7e]+)\n?$/.exec(text);
  if (!m) refuse(`key file for account ${letter} is not one OPENAI_API_KEY=<key> line`);
  return m[1];
}

function usdPerMillionToNanoPerToken(price) {
  const n = Math.round(price * 1000);
  if (!Number.isFinite(price) || price < 0 || Math.abs(n - price * 1000) > 1e-6) refuse('price table entry is malformed');
  return BigInt(n);
}
function priceOf(model) {
  let table;
  try { table = JSON.parse(readFileSync(join(HERE, 'openai-prices.json'), 'utf8')); } catch { refuse('price table is unreadable'); }
  if (!table?.models || !Object.hasOwn(table.models, model)) refuse(`no price for model ${model}`);
  const p = table.models[model];
  return { input: usdPerMillionToNanoPerToken(p.input), cached: usdPerMillionToNanoPerToken(p.cached_input), output: usdPerMillionToNanoPerToken(p.output) };
}

const microText = (m) => `${m / 1000000n}.${String(m % 1000000n).padStart(6, '0')}`;

function redact(text, key) {
  let t = String(text);
  if (key) t = t.split(key).join('[redacted]');
  return t.replace(/sk-[A-Za-z0-9_-]{8,}/g, '[redacted]');
}
const oneLine = (text, key) => redact(text, key).replace(/\s+/g, ' ').trim().slice(0, 200);

function warnSettle(r) {
  if (r.verdict !== 'PROCEED') process.stderr.write(`openai-api: warning: ledger settle returned ${r.verdict} (${r.reason ?? 'no reason'})\n`);
}

async function main() {
  const o = parseArgs(process.argv.slice(2));
  const env = process.env;
  if (env.HIMMEL_API_LANE !== 'on') refuse('api lane is OFF (set HIMMEL_API_LANE=on)');
  const letter = env.HIMMEL_OPENAI_ACCOUNT;
  if (letter === 'auto') refuse('HIMMEL_OPENAI_ACCOUNT=auto is not supported; name one account');
  if (!['A', 'B', 'C', 'D'].includes(letter)) refuse('HIMMEL_OPENAI_ACCOUNT must be A, B, C or D');
  const timeoutRaw = env.HIMMEL_API_CALL_TIMEOUT_S;
  const timeoutS = /^[1-9][0-9]{0,5}$/.test(timeoutRaw ?? '') ? Number(timeoutRaw) : 3600;

  let prompt = o.prompt ?? await readStdin();
  if (Buffer.byteLength(prompt) > MAX_PROMPT) refuse('prompt over 8 MiB');
  if (!prompt.trim()) refuse('the prompt is empty');
  let instructions = '';
  if (o.sysFile) {
    try { instructions = readFileSync(o.sysFile, 'utf8'); } catch { refuse('--append-system-prompt-file is unreadable'); }
  }

  const configPath = env.HIMMEL_OPENAI_CREDIT_CONFIG || join(homedir(), '.himmel/state/api-credit-openai/config.json');
  const base = { ...env, HIMMEL_API_ACCOUNT: letter, HIMMEL_API_CREDIT_CONFIG: configPath, HIMMEL_API_SNAPSHOT_OPTIONAL: '1' };
  delete base.HIMMEL_API_CREDIT_STATE;
  const roster = configuredAccount(base);
  if (roster.verdict) refuse(`roster: ${roster.reason}`);
  const stateDir = dirname(roster.ledger_path);
  const ledgerEnv = { ...base, HIMMEL_API_CREDIT_SNAPSHOT: join(stateDir, 'snapshot.json') };

  const key = readKey(stateDir, letter);
  const price = priceOf(o.model);

  const inputUpper = BigInt(Buffer.byteLength(instructions) + Buffer.byteLength(prompt) + 256);
  const budgetNano = o.budgetMicro * 1000n;
  const room = budgetNano - inputUpper * price.input;
  let maxOut = room > 0n && price.output > 0n ? room / price.output : 0n;
  if (maxOut > BigInt(MAX_OUT_CAP)) maxOut = BigInt(MAX_OUT_CAP);
  if (maxOut < BigInt(MIN_OUT)) refuse('budget too small for this prompt and model');

  const jobId = `openai-${Date.now()}-${process.pid}`;
  const reserved = creditState('reserve', { id: jobId, usd: microText(o.budgetMicro) }, ledgerEnv);
  if (reserved.verdict !== 'PROCEED') refuse(`ledger: ${reserved.reason ?? reserved.verdict}`);
  if (reserved.over_estimate) {
    creditState('settle', { id: jobId, usd: '0', completion: 'verified' }, ledgerEnv);
    refuse('ledger: insufficient-headroom');
  }

  const body = { model: o.model, input: prompt, max_output_tokens: Number(maxOut), store: false };
  const gpt62 = o.model.startsWith('gpt-6.2-');
  if (instructions && gpt62) {
    body.input = [
      { role: 'developer', content: instructions },
      { role: 'user', content: prompt },
    ];
  } else if (instructions) {
    body.instructions = instructions;
  }
  if (o.effort) body.reasoning = { effort: gpt62 && o.effort === 'none' ? 'low' : o.effort };

  const ctl = new AbortController();
  let timedOut = false;
  const timer = setTimeout(() => { timedOut = true; ctl.abort(); }, timeoutS * 1000);
  let status, text;
  try {
    const res = await fetch(`${(env.HIMMEL_OPENAI_BASE_URL || 'https://api.openai.com/v1').replace(/\/+$/, '')}/responses`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
      signal: ctl.signal,
    });
    status = res.status;
    text = await res.text();
  } catch (e) {
    creditState('unknown', { id: jobId }, ledgerEnv);
    if (timedOut) {
      process.stderr.write(`openai-api: call timed out after ${timeoutS}s; its cost is unknown and the reservation is marked unknown\n`);
      return 124;
    }
    process.stderr.write(`openai-api: call failed before a response (${oneLine(e?.cause?.code || e?.name || 'network error', key)}); its cost is unknown and the reservation is marked unknown\n`);
    return 1;
  } finally { clearTimeout(timer); }

  let data = null;
  try { data = JSON.parse(text); } catch { data = null; }

  if (status < 200 || status >= 300) {
    const code = data?.error?.code;
    if (status >= 500) {
      creditState('unknown', { id: jobId }, ledgerEnv);
      process.stderr.write(`openai-api: call failed (HTTP ${status}): ${oneLine(data?.error?.message ?? text, key)}; its cost is unknown and the reservation is marked unknown\n`);
      return 1;
    }
    warnSettle(creditState('settle', { id: jobId, usd: '0', completion: 'verified' }, ledgerEnv));
    if (status === 401 || code === 'invalid_api_key') {
      creditState('key-rejected', {}, ledgerEnv);
      process.stderr.write(`openai-api: account ${letter} rejected the key\n`);
      return 6;
    }
    if (status === 429 && code === 'insufficient_quota') {
      creditState('exhausted', {}, ledgerEnv);
      process.stderr.write(`openai-api: account ${letter} is out of credit\n`);
      return 6;
    }
    process.stderr.write(`openai-api: call failed (HTTP ${status}): ${oneLine(data?.error?.message ?? text, key)}\n`);
    return 1;
  }

  const u = data?.usage;
  const cached = u?.input_tokens_details?.cached_tokens || 0;
  const valid = [u?.input_tokens, u?.output_tokens, cached].every((n) => Number.isSafeInteger(n) && n >= 0) && cached <= u.input_tokens;
  if (!data || typeof data !== 'object' || !valid) {
    creditState('unknown', { id: jobId }, ledgerEnv);
    process.stderr.write('openai-api: the response carried no usable usage; its cost is unknown and the reservation is marked unknown\n');
    return 1;
  }
  const nanoCost = BigInt(u.input_tokens - cached) * price.input + BigInt(cached) * price.cached + BigInt(u.output_tokens) * price.output;
  const costMicro = (nanoCost + 999n) / 1000n;
  warnSettle(creditState('settle', { id: jobId, usd: microText(costMicro), completion: 'verified' }, ledgerEnv));
  creditState('key-ok', {}, ledgerEnv);

  const result = (Array.isArray(data.output) ? data.output : [])
    .flatMap((item) => (Array.isArray(item?.content) ? item.content : []))
    .filter((c) => c?.type === 'output_text' && typeof c.text === 'string')
    .map((c) => c.text).join('');
  const ok = data.status === 'completed';
  if (o.format === 'json') {
    await out(process.stdout, `${JSON.stringify({
      type: 'result', subtype: ok ? 'success' : 'error_incomplete', is_error: !ok, result, model: data.model ?? o.model,
      total_cost_usd: Number(microText(costMicro)),
      usage: { input_tokens: u.input_tokens, cached_input_tokens: cached, output_tokens: u.output_tokens,
        reasoning_tokens: u.output_tokens_details?.reasoning_tokens || 0 },
      response_id: data.id ?? null, account: letter,
    })}\n`);
  } else if (result) await out(process.stdout, result.endsWith('\n') ? result : `${result}\n`);
  if (ok) return 0;
  process.stderr.write(data.status === 'incomplete'
    ? `openai-api: incomplete: ${oneLine(data.incomplete_details?.reason ?? 'unknown', key)}\n`
    : `openai-api: response status ${oneLine(data.status ?? 'unknown', key)}\n`);
  return 1;
}

main().then(finish, async (e) => {
  if (e instanceof Refusal) {
    process.stderr.write(`openai-api: refused: ${e.message}\n`);
    return finish(2);
  }
  process.stderr.write(`openai-api: internal error: ${oneLine(e?.message ?? e, '')}\n`);
  return finish(1);
});
