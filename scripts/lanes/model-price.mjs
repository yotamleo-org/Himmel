#!/usr/bin/env node
// scripts/lanes/model-price.mjs - cost one call from lib/model-prices.tsv.
// A model with no row is UNPRICED (usd null); there is no fallback to another model's rate.
//   model-price.mjs call --model M --input N [--output N] [--cache-read N] [--cache-write-5m N] [--cache-write-1h N]
//       prints the dollars; exit 2 and `unpriced model=M` when M has no row.
//   model-price.mjs transcripts <dir> [--since ISO] [--price-as MODEL]
//       read-only: sums the assistant usage of every *.jsonl under <dir> per model (a message repeated by
//       streaming counts once); unpriced calls print on their own line. --price-as costs every call at one
//       model's row (the "what it was costed at before" figure).
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isMain } from '../lib/is-main.mjs';

const TABLE = join(dirname(fileURLToPath(import.meta.url)), 'lib', 'model-prices.tsv');
const M = 1_000_000;

export function loadPrices(path = TABLE) {
  const rows = [];
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    if (!line.trim() || line.startsWith('#')) continue;
    const [prefix, input, output, cacheRead, cacheWrite5m, cacheWrite1h] = line.split('\t');
    rows.push({ prefix, input: +input, output: +output, cacheRead: +cacheRead, cacheWrite5m: +cacheWrite5m, cacheWrite1h: +cacheWrite1h });
  }
  return rows;
}

// First row whose prefix the model id starts with, else null.
export function priceFor(model, rows) {
  if (!model) return null;
  return rows.find((r) => model.startsWith(r.prefix)) ?? null;
}

// call: { model, usage } with the transcript usage keys. `asModel` prices the call at that model's row.
export function priceCall(call, rows, asModel) {
  const row = priceFor(asModel ?? call.model, rows);
  if (!row) return { priced: false, model: call.model, usd: null };
  const u = call.usage ?? {};
  const split = u.cache_creation;
  const counts = [u.input_tokens, u.output_tokens, u.cache_read_input_tokens,
    split ? split.ephemeral_5m_input_tokens : u.cache_creation_input_tokens, split ? split.ephemeral_1h_input_tokens : 0];
  // a missing count is 0; a count that is not a finite non-negative number makes the call malformed, never NaN
  if (counts.some((n) => n != null && !(typeof n === 'number' && Number.isFinite(n) && n >= 0))) {
    return { priced: false, malformed: true, model: call.model, usd: null };
  }
  const [inp, out, read, w5, w1h] = counts.map((n) => n ?? 0);
  const usd = (inp * row.input + out * row.output + read * row.cacheRead + w5 * row.cacheWrite5m + w1h * row.cacheWrite1h) / M;
  return { priced: true, model: call.model, priceRow: row.prefix, usd };
}

function* jsonlFiles(dir) {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) yield* jsonlFiles(p);
    else if (e.name.endsWith('.jsonl')) yield p;
  }
}

const SYNTHETIC = /^<[^>]*>$/;
const COUNT_KEYS = ['input', 'output', 'cacheRead', 'cacheWrite5m', 'cacheWrite1h'];

export class UsageError extends Error {
  constructor(code, message, key) {
    super(message);
    this.code = code;
    this.key = key;
  }
}

function count(v, name) {
  if (v == null) return 0;
  if (!Number.isSafeInteger(v) || v < 0) throw new UsageError('malformed-usage', `${name} is not a non-negative safe integer`);
  return v;
}

// usage: the transcript usage object. Throws UsageError('malformed-usage' | 'cache-split-mismatch').
export function normalizeUsage(usage) {
  if (!usage || typeof usage !== 'object' || Array.isArray(usage)) throw new UsageError('malformed-usage', 'usage is not an object');
  const split = usage.cache_creation;
  if (split != null && (typeof split !== 'object' || Array.isArray(split))) throw new UsageError('malformed-usage', 'cache_creation is not an object');
  const total = usage.cache_creation_input_tokens;
  const out = {
    input: count(usage.input_tokens, 'input_tokens'),
    output: count(usage.output_tokens, 'output_tokens'),
    cacheRead: count(usage.cache_read_input_tokens, 'cache_read_input_tokens'),
    cacheWrite5m: 0,
    cacheWrite1h: 0,
  };
  const totalN = count(total, 'cache_creation_input_tokens');
  if (split && (split.ephemeral_5m_input_tokens != null || split.ephemeral_1h_input_tokens != null)) {
    out.cacheWrite5m = count(split.ephemeral_5m_input_tokens, 'ephemeral_5m_input_tokens');
    out.cacheWrite1h = count(split.ephemeral_1h_input_tokens, 'ephemeral_1h_input_tokens');
    if (total != null && totalN !== out.cacheWrite5m + out.cacheWrite1h) {
      throw new UsageError('cache-split-mismatch', 'cache_creation_input_tokens disagrees with the per-TTL split');
    }
  } else {
    out.cacheWrite5m = totalN;
  }
  return out;
}

function isSyntheticZero(model, usage) {
  return typeof model === 'string' && SYNTHETIC.test(model) && COUNT_KEYS.every((k) => usage[k] === 0);
}

function idOf(v) {
  return typeof v === 'string' && v !== '' ? v : null;
}

// One transcript record folded into one transcript's call state. Pure: `previous` is a Map of key to the stored
// entry {messageId, requestId, model, usage}; the caller stores `next` under `key`.
// record: the parsed transcript line; sourceOffset: the decimal byte offset of its line.
// Throws UsageError (code identity-conflict | synthetic-nonzero | malformed-usage | cache-split-mismatch, with .key).
export function foldUsageCall(previous, record, sourceOffset) {
  const message = record?.message ?? {};
  const messageId = idOf(message.id);
  const requestId = idOf(record?.requestId);
  const key = messageId ? `m:${messageId}` : requestId ? `r:${requestId}` : `o:${sourceOffset}`;
  const prior = previous?.get(key) ?? null;
  try {
    if (prior && messageId && prior.requestId && requestId && prior.requestId !== requestId) {
      throw new UsageError('identity-conflict', `message ${messageId} carries request ids ${prior.requestId} and ${requestId}`);
    }
    const usage = normalizeUsage(message.usage);
    const model = typeof message.model === 'string' ? message.model : null;
    const synthetic = model !== null && SYNTHETIC.test(model);
    if (synthetic && !isSyntheticZero(model, usage)) throw new UsageError('synthetic-nonzero', `${model} carries nonzero usage`);
    const next = { messageId, requestId: requestId ?? prior?.requestId ?? null, model, usage };
    const changed = !prior || prior.model !== model || COUNT_KEYS.some((k) => prior.usage[k] !== usage[k]);
    return { key, next, previousUsage: prior ? prior.usage : null, changed, first: !prior, excluded: synthetic ? 'synthetic-zero' : null };
  } catch (e) {
    if (e instanceof UsageError) e.key = key;
    throw e;
  }
}

const NANO_PER_USD = 1e9;
const TOKENS_PER_MTOK = 1e6;
const nanoRate = (usdPerMTok) => BigInt(Math.round((usdPerMTok * NANO_PER_USD) / TOKENS_PER_MTOK));
function priceNano(u, row) {
  return BigInt(u.input) * nanoRate(row.input) + BigInt(u.output) * nanoRate(row.output)
    + BigInt(u.cacheRead) * nanoRate(row.cacheRead) + BigInt(u.cacheWrite5m) * nanoRate(row.cacheWrite5m)
    + BigInt(u.cacheWrite1h) * nanoRate(row.cacheWrite1h);
}
const nanoToUsd = (n) => Number(n) / NANO_PER_USD;

function* linesWithOffsets(file) {
  const buf = readFileSync(file);
  let pos = 0;
  while (pos < buf.length) {
    let end = buf.indexOf(10, pos);
    if (end === -1) end = buf.length;
    yield [buf.toString('utf8', pos, end), pos];
    pos = end + 1;
  }
}

// Read-only walk of a transcripts dir. since: ISO date; a call whose FIRST record is older than it, or has no
// parseable timestamp, is skipped, whatever a later correction of the same call says.
export function priceTranscripts(dir, rows, { since, priceAs } = {}) {
  const sinceMs = since === undefined ? null : Date.parse(since);
  if (Number.isNaN(sinceMs)) throw new Error(`--since is not a date: ${since}`);
  if (priceAs !== undefined && !priceFor(priceAs, rows)) throw new Error(`--price-as has no price row: ${priceAs}`);
  const perModel = {};
  const unpriced = {};
  let malformed = 0;
  let syntheticZero = 0;
  let totalNano = 0n;
  let opusCalls = 0;
  for (const file of jsonlFiles(dir)) {
    const calls = new Map();
    const firstTs = new Map();
    const refused = [];
    const inWindow = (key) => sinceMs === null || firstTs.get(key) >= sinceMs;
    for (const [line, offset] of linesWithOffsets(file)) {
      if (!line.trim()) continue;
      let r;
      try { r = JSON.parse(line); } catch { continue; }
      const m = r.message;
      if (r.type !== 'assistant' || !m || typeof m !== 'object' || !m.usage) continue;
      let folded;
      try {
        folded = foldUsageCall(calls, r, offset);
      } catch (e) {
        if (!(e instanceof UsageError)) throw e;
        if (!firstTs.has(e.key)) firstTs.set(e.key, Date.parse(r.timestamp));
        refused.push(e.key);
        continue;
      }
      if (!firstTs.has(folded.key)) firstTs.set(folded.key, Date.parse(r.timestamp));
      calls.set(folded.key, folded.next);
    }
    malformed += refused.filter(inWindow).length;
    for (const [key, c] of calls) {
      if (!inWindow(key)) continue;
      if (isSyntheticZero(c.model, c.usage)) { syntheticZero += 1; continue; }
      const row = priceFor(priceAs ?? c.model, rows);
      if (!row) { unpriced[c.model] = (unpriced[c.model] ?? 0) + 1; continue; }
      const nano = priceNano(c.usage, row);
      const p = perModel[c.model] ??= { calls: 0, usd: 0, nano: 0n };
      p.calls += 1;
      p.nano += nano;
      p.usd = nanoToUsd(p.nano);
      totalNano += nano;
      if (row.prefix.startsWith('claude-opus')) opusCalls += 1;
    }
  }
  return { perModel, unpriced, malformed, syntheticZero, total: nanoToUsd(totalNano), totalNano, opusCalls };
}

function flags(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 2) {
    if (!argv[i].startsWith('--') || argv[i + 1] === undefined) throw new Error(`bad argument: ${argv[i]}`);
    out[argv[i].slice(2)] = argv[i + 1];
  }
  return out;
}

function main(argv) {
  const [cmd, ...rest] = argv;
  const rows = loadPrices();
  if (cmd === 'call') {
    const f = flags(rest);
    const count = (k) => {
      const n = Number(f[k] ?? 0);
      if (String(f[k] ?? 0).trim() === '' || !Number.isFinite(n) || n < 0) throw new Error(`--${k} must be a non-negative number: ${f[k]}`);
      return n;
    };
    const usage = {
      input_tokens: count('input'), output_tokens: count('output'), cache_read_input_tokens: count('cache-read'),
      cache_creation: { ephemeral_5m_input_tokens: count('cache-write-5m'), ephemeral_1h_input_tokens: count('cache-write-1h') },
    };
    const res = priceCall({ model: f.model, usage }, rows);
    if (!res.priced) { console.log(`unpriced model=${f.model}`); return 2; }
    console.log(res.usd.toFixed(2));
    return 0;
  }
  if (cmd === 'transcripts' && rest[0]) {
    const f = flags(rest.slice(1));
    const res = priceTranscripts(rest[0], rows, { since: f.since, priceAs: f['price-as'] });
    for (const [model, p] of Object.entries(res.perModel).sort()) console.log(`${model} calls=${p.calls} usd=${p.usd.toFixed(2)}`);
    for (const [model, n] of Object.entries(res.unpriced).sort()) console.log(`unpriced model=${model} calls=${n}`);
    if (res.malformed) console.log(`malformed calls=${res.malformed}`);
    if (res.syntheticZero) console.log(`excluded synthetic-zero calls=${res.syntheticZero}`);
    console.log(`opus-priced calls=${res.opusCalls}`);
    console.log(`total usd=${res.total.toFixed(2)} (priced calls only)`);
    return 0;
  }
  console.error('usage: model-price.mjs call --model M --input N [...] | transcripts <dir> [--since ISO] [--price-as MODEL]');
  return 64;
}

if (isMain(import.meta.url)) {
  try { process.exitCode = main(process.argv.slice(2)); } catch (e) { console.error(`model-price: ${e.message}`); process.exitCode = 64; }
}
