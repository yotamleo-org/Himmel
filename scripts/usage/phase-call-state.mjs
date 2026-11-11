#!/usr/bin/env node
// scripts/usage/phase-call-state.mjs - the schema 2 call-state adapter of the usage collector (usage-compute.sh).
//   phase-call-state.mjs [--state FILE] --chunk FILE --start-offset N --end-offset N --meta FILE [--role CLASS] [--timezone Z]
// Folds the transcript bytes [start, end) of one file, held in --chunk, into that file's call state and prints the replacement
// state JSON. Each call counts once, at its final usage (scripts/lanes/model-price.mjs foldUsageCall), on the day and phase
// of its first usage: a correction subtracts the old contribution from that first key and adds the new one. Dollars are
// integer nanodollars from lib/model-prices.tsv. The state keeps ids, counters and class words: no message text, no title.
//   exit 0 state printed; exit 2 invalid input (the stderr line starts with a code); exit 3 legacy-state-replay-required:
//   the state is a schema 1 state (no schema field, a boolean seen map), the caller rebuilds the unit from byte 0.
import { readFileSync, openSync, readSync, closeSync, statSync } from 'node:fs';
import { loadPrices, priceFor, foldUsageCall, UsageError } from '../lanes/model-price.mjs';
import { isMain } from '../lib/is-main.mjs';

class InputError extends Error {
  constructor(exit, code, detail) {
    super(`${code}: ${detail}`);
    this.exit = exit;
  }
}
const invalid = (code, detail) => new InputError(2, code, detail);

const FIELDS = ['calls', 'i', 'o', 'cr', 'c5', 'c1', 'nano', 'unp'];
const RELEVANT = /"type":"(assistant|custom-title|ai-title)"|"subtype":"compact_boundary"|"isCompactSummary":true/;
const TS = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?Z$/;
const NANO_PER_MTOK_TOKEN = 1000;

// the phase of the tool a call follows: the cost-page audit's last-tool rule (phase_rule v1)
const CMD_PHASES = [
  ['review', /pr-check|scripts\/cr\/|review-round|write-verdicts|ledger-append|ready-check|thread-resolve|judge-request|clear-review-marker/],
  ['ci', /check-ci|gh pr checks|gh run|suite-coverage/],
  ['ticket-filing', /jira[\s\S]*(create|comment|edit|transition|link|update|move)/],
  ['ticket-read', /jira/],
  ['ship', /git( -C [^ ]+)? (commit|push)|worker-pr-open|merge-on-green|merge-fork-pr|gh pr (create|edit|merge)/],
  ['tests', /quiet-run|impacted-suites|test-[^ ]*\.sh|bats|pytest|node --test|shellcheck/],
  ['comms', /append-results|queue-lock|wrap-subtree|close-wrapped|usage-preflight|(^|[^a-z])bus([^a-z]|$)/],
  ['retrieval', /qmd|graphify|worker-graph/],
  ['vm', /scripts\/vm\//],
];
function toolPhase(block) {
  const name = block.name ?? '';
  if (name === 'Bash') {
    const cmd = typeof block.input?.command === 'string' ? block.input.command : '';
    return (CMD_PHASES.find(([, re]) => re.test(cmd)) ?? ['build'])[0];
  }
  if (name === 'Skill') return /(^|:)pr-check$/.test(block.input?.skill ?? '') ? 'review' : 'skill';
  if (['SendMessage', 'ListAgents', 'ReadNotifications'].includes(name)) return 'comms';
  if (name === 'ToolSearch') return 'tool-load';
  if (name === 'Agent' || name === 'Task') return 'agent';
  return 'build';
}
function lastToolPhase(content) {
  if (!Array.isArray(content)) return null;
  const tools = content.filter((b) => b && b.type === 'tool_use');
  return tools.length ? toolPhase(tools.at(-1)) : null;
}

const titleClass = (t) => (/chief|console/i.test(t) ? 'chief' : /-N[0-9]+|^HIMMEL-[0-9]+/.test(t) ? 'worker' : 'other');

function dayFormatter(timezone) {
  try {
    return new Intl.DateTimeFormat('en-CA', { ...(timezone ? { timeZone: timezone } : {}), year: 'numeric', month: '2-digit', day: '2-digit' });
  } catch { throw invalid('timezone-invalid', timezone); }
}
// the day of a call's first usage in the station's zone (or --timezone); a timestamp that is not a UTC instant is "unknown"
function dayOf(fmt, ts) {
  const m = typeof ts === 'string' ? TS.exec(ts) : null;
  if (!m) return 'unknown';
  const [y, mo, d, h, mi, s] = m.slice(1).map(Number);
  const at = new Date(Date.UTC(y, mo - 1, d, h, mi, s));
  if (at.getUTCFullYear() !== y || at.getUTCMonth() !== mo - 1 || at.getUTCDate() !== d || h > 23 || mi > 59 || s > 59) return 'unknown';
  return fmt.format(at);
}

const nanoRate = (usdPerMTok) => BigInt(Math.round(usdPerMTok * NANO_PER_MTOK_TOKEN));
function priceNano(u, row) {
  return BigInt(u.input) * nanoRate(row.input) + BigInt(u.output) * nanoRate(row.output) + BigInt(u.cacheRead) * nanoRate(row.cacheRead)
    + BigInt(u.cacheWrite5m) * nanoRate(row.cacheWrite5m) + BigInt(u.cacheWrite1h) * nanoRate(row.cacheWrite1h);
}
function asCount(big) {
  const n = Number(big);
  if (!Number.isSafeInteger(n)) throw invalid('count-overflow', 'a counter left the safe integer range');
  return n;
}

// one call's contribution to an agg entry, rebuilt from what the state keeps for it
function contributionOf(entry) {
  const u = entry.usage;
  return { calls: 1, i: u.input, o: u.output, cr: u.cacheRead, c5: u.cacheWrite5m, c1: u.cacheWrite1h, nano: entry.nano, unp: entry.unpriced, model: entry.model ?? 'unknown' };
}
// A model name comes from the transcript: it is only ever an own property, never a prototype write.
function bump(agg, key, c, sign) {
  const a = (agg[key] ??= { calls: 0, i: 0, o: 0, cr: 0, c5: 0, c1: 0, nano: 0, unp: 0, models: {} });
  for (const f of FIELDS) a[f] = asCount(BigInt(a[f]) + BigInt(sign) * BigInt(c[f]));
  const n = (Object.hasOwn(a.models, c.model) ? a.models[c.model] : 0) + sign;
  if (n <= 0) delete a.models[c.model];
  else Object.defineProperty(a.models, c.model, { value: n, enumerable: true, writable: true, configurable: true });
}

function* chunkLines(path, length) {
  const fd = openSync(path, 'r');
  try {
    const buf = Buffer.allocUnsafe(8 * 1024 * 1024);
    let readPos = 0;
    let carry = Buffer.alloc(0);
    while (readPos < length) {
      const n = readSync(fd, buf, 0, Math.min(buf.length, length - readPos), readPos);
      if (n === 0) break;
      const data = carry.length ? Buffer.concat([carry, buf.subarray(0, n)]) : buf.subarray(0, n);
      const dataStart = readPos - carry.length;
      readPos += n;
      let s = 0;
      for (let i = data.indexOf(10, s); i !== -1; i = data.indexOf(10, s)) {
        yield [data.toString('utf8', s, i), dataStart + s];
        s = i + 1;
      }
      carry = Buffer.from(data.subarray(s));
    }
    if (carry.length) yield [carry.toString('utf8'), readPos - carry.length];
  } finally { closeSync(fd); }
}

function freshState() {
  return { schema: 2, off: 0, last: 'boot', agg: {}, seen: {}, meta: null, role: null, fp: null, tc_class: null, ac_class: null, refused: 0 };
}

function loadState(path) {
  if (!path) return freshState();
  let s;
  try { s = JSON.parse(readFileSync(path, 'utf8')); } catch (e) { throw invalid('state-unreadable', e.message); }
  if (s === null || typeof s !== 'object' || Array.isArray(s)) throw invalid('state-malformed', 'not an object');
  if (s.schema === undefined) throw new InputError(3, 'legacy-state-replay-required', 'a schema 1 state cannot continue under schema 2');
  if (s.schema !== 2) throw invalid('state-schema-unknown', String(s.schema));
  const obj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
  if (!Number.isSafeInteger(s.off) || s.off < 0 || !obj(s.agg) || !obj(s.seen) || typeof s.last !== 'string') throw invalid('state-malformed', 'off, last, agg or seen is missing');
  return { ...freshState(), ...s, refused: s.refused ?? 0 };
}

function applyChunk(state, { chunk, start, end, meta, role, prices, fmt }) {
  const previous = { get: (k) => (Object.hasOwn(state.seen, k) ? state.seen[k] : null) };
  const advance = (message) => { const p = lastToolPhase(message.content); if (p !== null) state.last = p; };
  for (const [line, rel] of chunkLines(chunk, end - start)) {
    if (!RELEVANT.test(line)) continue;
    let r;
    try { r = JSON.parse(line); } catch { continue; }
    if (r === null || typeof r !== 'object') continue;
    const message = r.message;
    if (r.type === 'assistant' && message !== null && typeof message === 'object' && message.usage) {
      let folded;
      try { folded = foldUsageCall(previous, r, start + rel); } catch (e) {
        if (!(e instanceof UsageError)) throw e;
        state.refused += 1;
        advance(message);
        continue;
      }
      const old = previous.get(folded.key);
      if (folded.excluded) {
        if (old?.attr) bump(state.agg, old.attr, contributionOf(old), -1);
        state.seen[folded.key] = { ...folded.next, attr: null, nano: 0, unpriced: 0 };
        continue;
      }
      const row = priceFor(folded.next.model, prices);
      const entry = { ...folded.next, nano: row ? asCount(priceNano(folded.next.usage, row)) : 0, unpriced: row ? 0 : 1, attr: old?.attr ?? `${dayOf(fmt, r.timestamp)}|${state.last}` };
      if (old?.attr && folded.changed) bump(state.agg, old.attr, contributionOf(old), -1);
      if (!old?.attr || folded.changed) bump(state.agg, entry.attr, contributionOf(entry), 1);
      else Object.assign(entry, { nano: old.nano, unpriced: old.unpriced });
      if (state.agg[entry.attr].calls === 0) delete state.agg[entry.attr];
      state.seen[folded.key] = entry;
      advance(message);
    } else if ((r.type === 'system' && r.subtype === 'compact_boundary') || r.isCompactSummary === true) {
      state.last = 'compaction';
    } else if (r.type === 'custom-title' && typeof r.customTitle === 'string') {
      state.tc_class = titleClass(r.customTitle);
    } else if (r.type === 'ai-title' && typeof r.aiTitle === 'string') {
      state.ac_class = titleClass(r.aiTitle);
    }
  }
  state.off = end;
  state.meta = { session: meta.session, parent: meta.parent ?? null, agent_type: meta.agent_type ?? '' };
  if (state.fp === null && typeof meta.fp === 'string' && meta.fp !== '') state.fp = meta.fp;
  if (role) state.role = role;
  return state;
}

function parseArgs(argv) {
  const a = {};
  const known = new Set(['state', 'chunk', 'start-offset', 'end-offset', 'meta', 'role', 'timezone']);
  for (let i = 0; i < argv.length; i += 2) {
    const k = argv[i]?.startsWith('--') ? argv[i].slice(2) : null;
    if (!k || !known.has(k) || argv[i + 1] === undefined) throw invalid('usage', `unusable argument ${argv[i]}`);
    a[k] = argv[i + 1];
  }
  for (const k of ['chunk', 'start-offset', 'end-offset', 'meta']) if (a[k] === undefined) throw invalid('usage', `--${k} is required`);
  return a;
}

function main(argv) {
  const a = parseArgs(argv);
  const num = (v, name) => { if (!/^[0-9]+$/.test(v) || !Number.isSafeInteger(+v)) throw invalid('offset-invalid', name); return +v; };
  const start = num(a['start-offset'], '--start-offset');
  const end = num(a['end-offset'], '--end-offset');
  if (end < start) throw invalid('offset-invalid', '--end-offset is before --start-offset');
  let meta;
  try { meta = JSON.parse(readFileSync(a.meta, 'utf8')); } catch (e) { throw invalid('meta-unreadable', e.message); }
  if (meta === null || typeof meta !== 'object' || typeof meta.session !== 'string') throw invalid('meta-malformed', 'session is missing');
  const state = loadState(a.state);
  if (state.off !== start) throw invalid('offset-mismatch', `the state ends at ${state.off}, the chunk starts at ${start}`);
  let size;
  try { size = statSync(a.chunk).size; } catch (e) { throw invalid('chunk-unreadable', e.message); }
  if (size < end - start) throw invalid('chunk-short', `${size} bytes for ${end - start}`);
  let prices;
  try { prices = loadPrices(); } catch (e) { throw invalid('prices-unreadable', e.message); }
  const next = applyChunk(state, { chunk: a.chunk, start, end, meta, role: a.role, prices, fmt: dayFormatter(a.timezone) });
  return `${JSON.stringify(next)}\n`;
}

if (isMain(import.meta.url)) {
  try {
    process.stdout.write(main(process.argv.slice(2)));
  } catch (e) {
    if (!(e instanceof InputError)) throw e;
    console.error(e.message);
    process.exitCode = e.exit;
  }
}
