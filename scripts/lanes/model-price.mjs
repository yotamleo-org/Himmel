#!/usr/bin/env node
// scripts/lanes/model-price.mjs - cost one call from lib/model-prices.tsv.
// A model with no row is UNPRICED (usd null); there is no fallback to another model's rate.
//   model-price.mjs call --model M --input N [--output N] [--cache-read N] [--cache-write-5m N] [--cache-write-1h N]
//       prints the dollars; exit 2 and `unpriced model=M` when M has no row.
//   model-price.mjs transcripts <dir> [--since ISO] [--price-as MODEL]
//       read-only: sums the assistant usage of every *.jsonl under <dir> per model (a message repeated by
//       streaming counts once); unpriced calls print on their own line. --price-as costs every call at one
//       model's row (the "what it was costed at before" figure).
//   model-price.mjs calls --manifest PROJECTION.json
//       read-only JSONL on stdout: one usage-call row per final call, then ONE terminal usage-coverage footer. Exit 0
//       complete, 3 partial (a torn last line), 2 invalid. No --price-as. See docs/internals/usage-records.md.
//   model-price.mjs validate-calls --manifest EXPORT_SET.json
//       prints one usage-call-validation JSON object; exit 0 complete, 3 inconclusive, 2 invalid.
import { readFileSync, readdirSync, lstatSync, statSync, realpathSync, openSync, fstatSync, closeSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join, dirname, resolve, sep, isAbsolute } from 'node:path';
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

function* bufferLines(buf) {
  let pos = 0;
  while (pos < buf.length) {
    let end = buf.indexOf(10, pos);
    const terminated = end !== -1;
    if (!terminated) end = buf.length;
    yield [buf.toString('utf8', pos, end), pos, terminated];
    pos = end + 1;
  }
}

function* linesWithOffsets(file) {
  for (const [text, pos] of bufferLines(readFileSync(file))) yield [text, pos];
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

const USAGE_RULE = 'final-v2';
const SOURCE_SCOPE = 'claude-transcripts';
const EXCLUDED_SOURCES = ['native-codex', 'other-provider-stores'];
const MAX_FILES = 128;
const MAX_BYTES = 512 * 1024 * 1024;
const RFC3339 = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$/;
const HEX64 = /^[0-9a-f]{64}$/;
const URI = /^[a-z][a-z0-9+.-]*:\/\//i;
const REAL_IO = { readFileSync, lstatSync, statSync, realpathSync, openSync, fstatSync, closeSync };
const sha256 = (data) => createHash('sha256').update(data).digest('hex');
const rfc3339Ms = (s) => (typeof s === 'string' && RFC3339.test(s) ? Date.parse(s) : NaN);
const isCount = (n) => Number.isSafeInteger(n) && n >= 0;
const isObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const sessionKey = (s) => JSON.stringify([s.provider, s.parent, s.session]);

export function priceTableSha256(rows) {
  return sha256(JSON.stringify(rows.map((r) => [r.prefix, r.input, r.output, r.cacheRead, r.cacheWrite5m, r.cacheWrite1h])));
}

function footerOf(f) {
  return {
    kind: 'usage-coverage', schema: 1, state: f.state, manifest_sha256: f.manifestSha256 ?? null, price_sha256: f.priceSha,
    source_scope: SOURCE_SCOPE, excluded_sources: EXCLUDED_SOURCES, timezone: f.timezone ?? null, since: f.since ?? null, until: f.until ?? null,
    selected_files: f.selectedFiles ?? 0, read_files: f.readFiles ?? 0, source_bytes: f.sourceBytes ?? 0,
    selected_calls: f.selected ?? 0, priced_calls: f.priced ?? 0, unpriced_calls: f.unpriced ?? 0,
    excluded_calls: (f.reasons?.['synthetic-zero'] ?? 0) + (f.reasons?.['outside-window'] ?? 0), usage_rule: USAGE_RULE,
    exclusion_reasons: { 'synthetic-zero': f.reasons?.['synthetic-zero'] ?? 0, 'outside-window': f.reasons?.['outside-window'] ?? 0 },
    errors: f.errors ?? [],
  };
}

const EXIT_OF_STATE = { complete: 0, partial: 3, invalid: 2 };

function checkEntry(f, seen, fail) {
  const rel = typeof f?.relative_path === 'string' ? f.relative_path : null;
  if (!isObject(f) || rel === null || !isCount(f.bytes) || !HEX64.test(f.sha256) || typeof f.session !== 'string' || f.session === ''
    || !(f.parent === null || (typeof f.parent === 'string' && f.parent !== ''))) return fail('manifest-shape', rel);
  if (f.provider !== 'claude') return fail('provider-unsupported', rel);
  const parts = rel.split('/');
  if (URI.test(rel) || isAbsolute(rel) || rel.includes('\\') || parts.some((s) => s === '' || s === '.' || s === '..')) return fail('path-escape', rel);
  const name = parts.at(-1);
  if (!name.endsWith('.jsonl') || name.slice(0, -'.jsonl'.length) !== f.session) return fail('session-mismatch', rel);
  const dir = parts.slice(0, -1);
  const inSubagents = dir.at(-1) === 'subagents';
  if (f.parent === null ? inSubagents : !(inSubagents && dir.at(-2) === f.parent)) return fail('parent-mismatch', rel);
  const tuple = sessionKey(f);
  if (seen.paths.has(rel) || seen.tuples.has(tuple)) fail('duplicate-source', rel);
  seen.paths.add(rel);
  seen.tuples.add(tuple);
  if (seen.parents.has(f.session) && seen.parents.get(f.session) !== f.parent) fail('session-namespace', rel);
  seen.parents.set(f.session, f.parent);
  return null;
}

function checkManifest(manifest, files, fail) {
  if (!isObject(manifest) || manifest.schema !== 1) fail('manifest-shape');
  else {
    if (typeof manifest.root !== 'string' || manifest.root === '' || URI.test(manifest.root)) fail('manifest-shape');
    if (manifest.timezone !== 'Europe/Berlin') fail('manifest-shape');
    const since = rfc3339Ms(manifest.since);
    const until = rfc3339Ms(manifest.until);
    if (Number.isNaN(since) || Number.isNaN(until) || since >= until) fail('manifest-window');
    if (files.length === 0) fail('manifest-shape');
  }
  if (files.length > MAX_FILES || files.reduce((n, f) => n + (isCount(f?.bytes) ? f.bytes : 0), 0) > MAX_BYTES) fail('manifest-budget');
  const seen = { paths: new Set(), tuples: new Set(), parents: new Map() };
  for (const f of files) checkEntry(f, seen, fail);
}

function readSource(f, realRoot, io, fail) {
  const rel = f.relative_path;
  let real;
  try { real = io.realpathSync(resolve(realRoot, rel)); } catch (e) { return fail(e.code === 'ENOENT' ? 'source-missing' : 'source-unreadable', rel); }
  if (real !== realRoot && !real.startsWith(realRoot + sep)) return fail('path-escape', rel);
  let buf;
  try {
    const st = io.statSync(real);
    if (!st.isFile()) return fail('source-unreadable', rel);
    if (st.size !== f.bytes) return fail('source-changed', rel);
    buf = io.readFileSync(real);
  } catch { return fail('source-unreadable', rel); }
  if (buf.length !== f.bytes || sha256(buf) !== f.sha256) return fail('source-changed', rel);
  return buf;
}

function foldFile(buf, rel, fail) {
  const state = new Map();
  const meta = new Map();
  let torn = false;
  for (const [line, offset, terminated] of bufferLines(buf)) {
    if (!line.trim()) continue;
    let r;
    try { r = JSON.parse(line); } catch { if (!terminated) torn = true; continue; }
    const m = r?.message;
    if (r?.type !== 'assistant' || !m || typeof m !== 'object' || !m.usage) continue;
    let folded;
    try { folded = foldUsageCall(state, r, offset); } catch (e) { if (!(e instanceof UsageError)) throw e; fail(e.code, rel); continue; }
    if (folded.first) {
      const ms = rfc3339Ms(r.timestamp);
      if (Number.isNaN(ms)) fail('timestamp-invalid', rel);
      meta.set(folded.key, { ms, firstModel: folded.next.model, firstOffset: offset, lastOffset: offset });
    } else meta.get(folded.key).lastOffset = offset;
    state.set(folded.key, folded.next);
  }
  return { state, meta, torn };
}

function callRows(f, { state, meta }, ctx) {
  const rows = [];
  for (const [key, c] of state) {
    const k = meta.get(key);
    if (!(k.ms >= ctx.sinceMs && k.ms < ctx.untilMs)) { ctx.reasons['outside-window'] += 1; continue; }
    if (isSyntheticZero(c.model, c.usage)) { ctx.reasons['synthetic-zero'] += 1; continue; }
    const price = priceFor(c.model, ctx.prices);
    const nano = price ? priceNano(c.usage, price) : null;
    rows.push({
      kind: 'usage-call', schema: 1, call_id: sha256(JSON.stringify(['claude', f.parent, f.session, key])), provider: 'claude',
      session: f.session, parent: f.parent, first_timestamp: new Date(k.ms).toISOString(), first_model: k.firstModel, model: c.model,
      ...c.usage, priced: price !== null, usd: nano === null ? null : nanoToUsd(nano), nano: nano === null ? null : nano.toString(),
      price_row: price ? price.prefix : null, price_sha256: ctx.priceSha,
      source: { manifest_sha256: ctx.manifestSha, relative_path: f.relative_path, sha256: f.sha256, first_offset: k.firstOffset, last_offset: k.lastOffset },
      usage_rule: USAGE_RULE, basis: 'list-price-equivalent',
    });
  }
  return rows;
}

const byTimeThenId = (a, b) => (a.first_timestamp < b.first_timestamp ? -1 : a.first_timestamp > b.first_timestamp ? 1 : a.call_id < b.call_id ? -1 : a.call_id > b.call_id ? 1 : 0);
const stringOrNull = (v) => (typeof v === 'string' ? v : null);

// manifest: the parsed projection manifest. opts.manifestSha256: SHA256 of its exact bytes. opts.baseDir resolves a
// relative root. opts.io swaps the filesystem calls (a read spy). Returns {calls, coverage, exitCode}; an invalid
// export carries no calls. Nothing is persisted and no title is read.
export function projectCalls(manifest, prices, { manifestSha256 = null, baseDir = null, io = REAL_IO } = {}) {
  const priceSha = priceTableSha256(prices);
  const errors = [];
  const fail = (code, relative_path = null) => {
    if (!errors.some((e) => e.code === code && e.relative_path === relative_path)) errors.push({ code, relative_path });
    return null;
  };
  const m = isObject(manifest) ? manifest : {};
  const files = Array.isArray(m.files) ? m.files : [];
  const head = {
    manifestSha256: manifestSha256 ?? (isObject(manifest) ? sha256(JSON.stringify(manifest)) : null), priceSha,
    timezone: stringOrNull(m.timezone), since: stringOrNull(m.since), until: stringOrNull(m.until), selectedFiles: files.length,
  };
  const refuse = (extra = {}) => ({ calls: [], coverage: footerOf({ ...head, state: 'invalid', errors, ...extra }), exitCode: 2 });

  checkManifest(manifest, files, fail);
  const root = typeof m.root === 'string' ? (isAbsolute(m.root) ? m.root : baseDir ? resolve(baseDir, m.root) : null) : null;
  if (errors.length === 0 && root === null) fail('manifest-shape');
  if (errors.length) return refuse();

  let realRoot;
  try { realRoot = io.realpathSync(root); } catch { fail('root-unreadable'); return refuse(); }
  const ctx = { prices, priceSha, manifestSha: head.manifestSha256, sinceMs: rfc3339Ms(m.since), untilMs: rfc3339Ms(m.until),
    reasons: { 'synthetic-zero': 0, 'outside-window': 0 } };
  const calls = [];
  let readFiles = 0;
  let sourceBytes = 0;
  let torn = 0;
  for (const f of files) {
    const buf = readSource(f, realRoot, io, fail);
    if (buf === null) continue;
    const folded = foldFile(buf, f.relative_path, fail);
    if (folded.torn) { torn += 1; fail('torn-line', f.relative_path); continue; }
    readFiles += 1;
    sourceBytes += f.bytes;
    calls.push(...callRows(f, folded, ctx));
  }
  if (errors.some((e) => e.code !== 'torn-line')) return refuse({ readFiles, sourceBytes });
  calls.sort(byTimeThenId);
  const priced = calls.filter((c) => c.priced).length;
  const state = torn ? 'partial' : 'complete';
  return {
    calls,
    coverage: footerOf({ ...head, state, readFiles, sourceBytes, selected: calls.length, priced, unpriced: calls.length - priced, reasons: ctx.reasons, errors }),
    exitCode: EXIT_OF_STATE[state],
  };
}

function emptyValidation(reason) {
  return { schema: 1, kind: 'usage-call-validation', ok: false, state: 'invalid', reasons: [reason], price_sha256: null, usage_rule: null, timezone: null,
    manifest_sha256: [], selected_calls: 0, priced_calls: 0, unpriced_calls: 0, complete_sessions: [], call_ids_sha256: null };
}

const validDeclared = (f) => isObject(f) && typeof f.relative_path === 'string' && isCount(f.bytes) && typeof f.sha256 === 'string'
  && f.provider === 'claude' && typeof f.session === 'string' && (f.parent === null || typeof f.parent === 'string');

function parseManifestBytes(e, v) {
  const mSha = sha256(e.manifestBytes);
  v.manifestShas.push(mSha);
  if (mSha !== e.expectedManifestSha256) v.bad('manifest-mismatch');
  let manifest;
  try { manifest = JSON.parse(e.manifestBytes); } catch { v.bad('manifest-mismatch'); return null; }
  if (!(isObject(manifest) && manifest.schema === 1 && Array.isArray(manifest.files) && manifest.files.every(validDeclared))) { v.bad('manifest-mismatch'); return null; }
  let structural = 0;
  checkManifest(manifest, manifest.files, () => { structural += 1; return null; });
  if (structural) { v.bad('manifest-mismatch'); return null; }
  const sources = new Map();
  for (const f of manifest.files) {
    const t = sessionKey(f);
    if (v.declared.has(t)) v.bad('duplicate-source');
    v.declared.add(t);
    sources.set(f.relative_path, f);
  }
  return { manifest, sources };
}

function splitExportLines(lines, v) {
  const nonblank = lines.map((l, i) => [l, i]).filter(([l]) => l.trim());
  const lastIdx = nonblank.length ? nonblank.at(-1)[1] : -1;
  const rows = [];
  const footers = [];
  let torn = false;
  for (const [line, idx] of nonblank) {
    let rec;
    try { rec = JSON.parse(line); } catch { if (idx === lastIdx) torn = true; else v.bad('row-shape'); continue; }
    if (!isObject(rec) || rec.schema !== 1) { v.bad('row-shape'); continue; }
    if (rec.kind === 'usage-call') rows.push(rec);
    else if (rec.kind === 'usage-coverage') footers.push([rec, idx]);
    else v.bad('row-shape');
  }
  if (torn) v.soft('parse-incomplete');
  if (footers.length === 0) { if (!torn) v.soft('footer-missing'); } else if (footers.length > 1 || footers[0][1] !== lastIdx) v.bad('footer-shape');
  return { rows, footer: footers.length === 1 && footers[0][1] === lastIdx ? footers[0][0] : null };
}

const isPseudoModel = (m) => typeof m === 'string' && SYNTHETIC.test(m);
const nameOrNull = (m) => m === null || typeof m === 'string';
const pricedFieldsOk = (r) => (r.priced === true
  ? typeof r.nano === 'string' && /^(0|[1-9]\d*)$/.test(r.nano) && r.usd === Number(r.nano) / NANO_PER_USD && typeof r.price_row === 'string'
  : r.priced === false && r.nano === null && r.usd === null && r.price_row === null);

function rowShapeOk(r) {
  return HEX64.test(r.call_id) && r.provider === 'claude' && typeof r.session === 'string' && (r.parent === null || typeof r.parent === 'string')
    && !Number.isNaN(rfc3339Ms(r.first_timestamp)) && nameOrNull(r.model) && nameOrNull(r.first_model) && !isPseudoModel(r.model) && !isPseudoModel(r.first_model)
    && COUNT_KEYS.every((k) => isCount(r[k])) && r.usage_rule === USAGE_RULE && r.basis === 'list-price-equivalent' && pricedFieldsOk(r) && isObject(r.source);
}

function checkRowSource(r, e, parsed, v) {
  const s = r.source;
  if (s.manifest_sha256 !== e.expectedManifestSha256) { v.bad('manifest-mismatch'); return; }
  if (!parsed) return;
  const file = parsed.sources.get(s.relative_path);
  if (!file || file.sha256 !== s.sha256 || file.session !== r.session || file.parent !== r.parent || !isCount(s.first_offset) || !isCount(s.last_offset)
    || s.first_offset > s.last_offset || s.last_offset >= file.bytes) v.bad('source-mismatch');
  const ms = Date.parse(r.first_timestamp);
  if (!(ms >= rfc3339Ms(parsed.manifest.since) && ms < rfc3339Ms(parsed.manifest.until))) v.bad('row-shape');
}

function checkRows(rows, e, parsed, footer, v) {
  let prev = null;
  for (const r of rows) {
    if (!rowShapeOk(r)) { v.bad('row-shape'); continue; }
    if (typeof r.price_sha256 !== 'string' || (footer && r.price_sha256 !== footer.price_sha256)) v.bad('price-mismatch');
    if (v.callIds.has(r.call_id)) v.bad('duplicate-call');
    v.callIds.add(r.call_id);
    if (prev && byTimeThenId(prev, r) > 0) v.bad('row-shape');
    prev = r;
    checkRowSource(r, e, parsed, v);
  }
}

const FOOTER_COUNTS = ['selected_files', 'read_files', 'source_bytes', 'selected_calls', 'priced_calls', 'unpriced_calls', 'excluded_calls'];
const footerShapeOk = (f) => FOOTER_COUNTS.every((k) => isCount(f[k])) && isObject(f.exclusion_reasons) && isCount(f.exclusion_reasons['synthetic-zero'])
  && isCount(f.exclusion_reasons['outside-window']) && Array.isArray(f.errors) && f.state in EXIT_OF_STATE && f.source_scope === SOURCE_SCOPE;

function checkFooter(footer, rows, e, parsed, v) {
  if (!footerShapeOk(footer)) { v.bad('row-shape'); return; }
  if (footer.manifest_sha256 !== e.expectedManifestSha256) v.bad('manifest-mismatch');
  if (footer.price_sha256 !== v.expectations.price_sha256) v.bad('price-mismatch');
  if (footer.usage_rule !== v.expectations.usage_rule) v.bad('usage-rule-mismatch');
  if (footer.timezone !== v.expectations.timezone) v.bad('clock-mismatch');
  const manifest = parsed?.manifest;
  if (manifest && (footer.timezone !== manifest.timezone || footer.since !== manifest.since || footer.until !== manifest.until)) v.bad('manifest-mismatch');
  if (!Number.isInteger(e.producerExitCode) || e.producerExitCode !== EXIT_OF_STATE[footer.state] || e.producerExitCode !== 0) v.soft('producer-exit');
  if (footer.state !== 'complete') { v.soft('source-incomplete'); return; }
  if (manifest && (footer.selected_files !== manifest.files.length || footer.source_bytes !== manifest.files.reduce((n, f) => n + f.bytes, 0))) v.bad('count-mismatch');
  const excluded = footer.exclusion_reasons['synthetic-zero'] + footer.exclusion_reasons['outside-window'];
  const priced = rows.filter((r) => r.priced === true).length;
  if (footer.read_files !== footer.selected_files || footer.selected_calls !== rows.length || footer.priced_calls !== priced
    || footer.unpriced_calls !== rows.filter((r) => r.priced === false).length || footer.excluded_calls !== excluded || footer.errors.length !== 0) v.bad('count-mismatch');
  if (manifest && e.producerExitCode === 0) for (const f of manifest.files) v.complete.set(sessionKey(f), { provider: 'claude', parent: f.parent, session: f.session });
}

function validateOne(e, v) {
  const parsed = parseManifestBytes(e, v);
  const { rows, footer } = splitExportLines(e.lines, v);
  checkRows(rows, e, parsed, footer, v);
  const priced = rows.filter((r) => r.priced === true).length;
  const unpriced = rows.filter((r) => r.priced === false).length;
  v.totals.selected += rows.length;
  v.totals.priced += priced;
  v.totals.unpriced += unpriced;
  if (unpriced) v.soft('unpriced');
  if (footer) checkFooter(footer, rows, e, parsed, v);
}

// Pure: no I/O, no transcript reread, no repricing. exports: [{lines, producerExitCode, manifestBytes, expectedManifestSha256}],
// expectedSessions: [{provider, parent, session}], expectations: {price_sha256, usage_rule, timezone}.
export function validateCallExport(exports, expectedSessions, expectations) {
  if (!Array.isArray(exports) || !Array.isArray(expectedSessions) || !isObject(expectations)
    || ['price_sha256', 'usage_rule', 'timezone'].some((k) => typeof expectations[k] !== 'string')) throw new TypeError('validateCallExport: bad arguments');
  const invalid = new Set();
  const inconclusive = new Set();
  const v = {
    expectations, bad: (r) => invalid.add(r), soft: (r) => inconclusive.add(r), manifestShas: [], callIds: new Set(), declared: new Set(),
    complete: new Map(), totals: { selected: 0, priced: 0, unpriced: 0 },
  };
  if (exports.length === 0) v.soft('footer-missing');
  for (const e of exports) validateOne(e, v);
  if (expectedSessions.some((s) => !v.complete.has(sessionKey(s)))) v.soft('missing-session');
  const state = invalid.size ? 'invalid' : inconclusive.size ? 'inconclusive' : 'complete';
  const ok = state === 'complete';
  return {
    schema: 1, kind: 'usage-call-validation', ok, state, reasons: [...invalid, ...inconclusive],
    price_sha256: ok ? expectations.price_sha256 : null, usage_rule: ok ? expectations.usage_rule : null, timezone: ok ? expectations.timezone : null,
    manifest_sha256: v.manifestShas, selected_calls: v.totals.selected, priced_calls: v.totals.priced, unpriced_calls: v.totals.unpriced,
    complete_sessions: ok ? [...v.complete.entries()].sort(([a], [b]) => (a < b ? -1 : 1)).map(([, s]) => s) : [],
    call_ids_sha256: ok ? sha256(JSON.stringify([...v.callIds].sort())) : null,
  };
}

export class CallExportLoadError extends Error {
  constructor(detail) {
    super(`export-set-load: ${detail}`);
    this.name = 'CallExportLoadError';
    this.exitCode = 2;
    this.detail = detail;
    this.validation = emptyValidation('export-set-load');
  }
}

const loadFail = (detail) => new CallExportLoadError(detail);
const ioDetail = (e) => (e?.code === 'ENOENT' || e?.code === 'ENOTDIR' ? 'missing' : 'unreadable');

function readCanonical(real, io) {
  let fd;
  try {
    fd = io.openSync(real, 'r');
    const opened = io.fstatSync(fd);
    if (!opened.isFile()) throw loadFail('invalid-declaration');
    const named = io.statSync(real);
    if (named.ino !== opened.ino || named.dev !== opened.dev) throw loadFail('unreadable');
    return io.readFileSync(fd, 'utf8');
  } catch (e) {
    throw e instanceof CallExportLoadError ? e : loadFail(ioDetail(e));
  } finally {
    if (fd !== undefined) { try { io.closeSync(fd); } catch { fd = undefined; } }
  }
}

function declaredPath(p, carrier, io) {
  if (typeof p !== 'string' || p === '') throw loadFail('invalid-declaration');
  if (URI.test(p)) throw loadFail('escape');
  let real;
  try { real = io.realpathSync(resolve(carrier, p)); } catch (e) { throw loadFail(ioDetail(e)); }
  if (real !== carrier && !real.startsWith(carrier + sep)) throw loadFail('escape');
  return real;
}

// Synchronous. Reads EXPORT_SET.json and only the export and projection-manifest files it declares, all confined to the
// carrier directory. Returns {exports, expectedSessions, expectations}; throws CallExportLoadError for a handled failure.
export function loadExportSet(path, { io = REAL_IO } = {}) {
  if (typeof path !== 'string') throw new TypeError('loadExportSet: path must be a string');
  let setReal;
  try { setReal = io.realpathSync(path); } catch (e) { throw loadFail(ioDetail(e)); }
  let carrier;
  try { carrier = io.realpathSync(dirname(setReal)); } catch (e) { throw loadFail(ioDetail(e)); }
  let set;
  try { set = JSON.parse(readCanonical(setReal, io)); } catch (e) { throw e instanceof CallExportLoadError ? e : loadFail('malformed'); }
  const okSession = (s) => isObject(s) && s.provider === 'claude' && typeof s.session === 'string' && s.session !== '' && (s.parent === null || (typeof s.parent === 'string' && s.parent !== ''));
  if (!isObject(set) || set.schema !== 1 || typeof set.price_sha256 !== 'string' || set.usage_rule !== USAGE_RULE || typeof set.timezone !== 'string'
    || !Array.isArray(set.exports) || !Array.isArray(set.expected_sessions) || !set.expected_sessions.every(okSession)
    || !set.exports.every((x) => isObject(x) && typeof x.path === 'string' && Number.isInteger(x.producer_exit_code)
      && isObject(x.projection_manifest) && typeof x.projection_manifest.path === 'string' && typeof x.projection_manifest.sha256 === 'string')
    || new Set(set.expected_sessions.map(sessionKey)).size !== set.expected_sessions.length) throw loadFail('invalid-declaration');
  const seen = new Set();
  const exports = set.exports.map((x) => {
    const exportReal = declaredPath(x.path, carrier, io);
    if (seen.has(exportReal)) throw loadFail('duplicate-path');
    seen.add(exportReal);
    const manifestReal = declaredPath(x.projection_manifest.path, carrier, io);
    const text = readCanonical(exportReal, io);
    const lines = text.split('\n');
    if (lines.at(-1) === '') lines.pop();
    return { lines, producerExitCode: x.producer_exit_code, manifestBytes: readCanonical(manifestReal, io), expectedManifestSha256: x.projection_manifest.sha256 };
  });
  return { exports, expectedSessions: set.expected_sessions.map((s) => ({ provider: s.provider, parent: s.parent, session: s.session })),
    expectations: { price_sha256: set.price_sha256, usage_rule: set.usage_rule, timezone: set.timezone } };
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
  if (cmd === 'calls') {
    const f = flags(rest);
    if (!f.manifest || Object.keys(f).some((k) => k !== 'manifest')) throw new Error('calls takes exactly --manifest FILE');
    const lines = (objs) => `${objs.map((o) => JSON.stringify(o)).join('\n')}\n`;
    const refusal = (code, manifestSha256) => ({
      stdout: lines([footerOf({ state: 'invalid', priceSha: priceTableSha256(rows), manifestSha256, errors: [{ code, relative_path: null }] })]), code: 2,
    });
    let bytes;
    try { bytes = readFileSync(f.manifest); } catch { return refusal('manifest-unreadable', null); }
    let manifest;
    try { manifest = JSON.parse(bytes.toString('utf8')); } catch { return refusal('manifest-malformed', sha256(bytes)); }
    const res = projectCalls(manifest, rows, { manifestSha256: sha256(bytes), baseDir: dirname(resolve(f.manifest)) });
    return { stdout: lines([...res.calls, res.coverage]), code: res.exitCode };
  }
  if (cmd === 'validate-calls') {
    const f = flags(rest);
    if (!f.manifest || Object.keys(f).some((k) => k !== 'manifest')) throw new Error('validate-calls takes exactly --manifest EXPORT_SET.json');
    let v;
    try {
      const { exports, expectedSessions, expectations } = loadExportSet(f.manifest);
      v = validateCallExport(exports, expectedSessions, expectations);
    } catch (e) {
      if (!(e instanceof CallExportLoadError)) throw e;
      v = e.validation;
    }
    return { stdout: `${JSON.stringify(v)}\n`, code: v.state === 'complete' ? 0 : v.state === 'inconclusive' ? 3 : 2 };
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
  console.error('usage: model-price.mjs call --model M --input N [...] | transcripts <dir> [--since ISO] [--price-as MODEL] | calls --manifest FILE | validate-calls --manifest FILE');
  return 64;
}

if (isMain(import.meta.url)) {
  try {
    const out = main(process.argv.slice(2));
    if (typeof out === 'number') process.exitCode = out;
    else {
      process.exitCode = 1;
      process.stdout.on('error', () => { process.exitCode = 1; });
      process.stdout.write(out.stdout, (err) => { if (!err) process.exitCode = out.code; });
    }
  } catch (e) { console.error(`model-price: ${e.message}`); process.exitCode = 64; }
}
