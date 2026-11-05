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

// Read-only walk of a transcripts dir. since: ISO date; a record older than it is skipped.
export function priceTranscripts(dir, rows, { since, priceAs } = {}) {
  const sinceMs = since === undefined ? null : Date.parse(since);
  if (Number.isNaN(sinceMs)) throw new Error(`--since is not a date: ${since}`);
  if (priceAs !== undefined && !priceFor(priceAs, rows)) throw new Error(`--price-as has no price row: ${priceAs}`);
  const perModel = {};
  const unpriced = {};
  let malformed = 0;
  let total = 0;
  let opusCalls = 0;
  for (const file of jsonlFiles(dir)) {
    // one entry per message: a streamed message repeats, and its last record carries the final usage
    const calls = new Map();
    let anon = 0;
    for (const line of readFileSync(file, 'utf8').split('\n')) {
      if (!line.trim()) continue;
      let r;
      try { r = JSON.parse(line); } catch { continue; }
      const m = r.message;
      if (r.type !== 'assistant' || !m || typeof m !== 'object' || !m.usage) continue;
      if (sinceMs !== null && !(Date.parse(r.timestamp) >= sinceMs)) continue;
      calls.set(m.id ? `${m.id}|${r.requestId ?? ''}` : `anon${anon++}`, m);
    }
    for (const m of calls.values()) {
      const res = priceCall({ model: m.model, usage: m.usage }, rows, priceAs);
      if (res.malformed) { malformed += 1; continue; }
      if (!res.priced) { unpriced[m.model] = (unpriced[m.model] ?? 0) + 1; continue; }
      const p = perModel[m.model] ??= { calls: 0, usd: 0 };
      p.calls += 1;
      p.usd += res.usd;
      total += res.usd;
      if (res.priceRow.startsWith('claude-opus')) opusCalls += 1;
    }
  }
  return { perModel, unpriced, malformed, total, opusCalls };
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
