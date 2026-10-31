// One record per shift: what Claude, codex and API money or budget a window [since, until)
// used, from five sources. Every field carries its own source mark and unit and is never
// added into another (a bank percentage, tokens and dollars are different units). A source
// that cannot be read reads "not available", never zero.
//
// Usage: node shift-spend.mjs --since <iso Z> --until <iso Z> [--codex-sessions <dir>]
//          [--cadence-ledger <file>] [--api-launches <file>] [--openrouter-key-file <file>] [--live]
// The API lane dollars come from our own launch records (launches.jsonl), not the Admin API cost report:
// an individual Console org has no Admin key, so that report answers http-403. The record carries no output-token
// count, so the dollars are the launcher's settled cost_usd (the CLI prices the call's own usage locally at the
// published per-model price, cache_read at x0.1), not a re-pricing here. Without --live and without a response
// file the OpenRouter field reads "not available" and nothing is fetched. --live reads OPENROUTER_API_KEY; a key
// is used only as a request header and never printed; a missing key marks the column unavailable(no key).
//
// ponytail: the OpenRouter parser is pinned to the vendor docs' response shape and has not met a live
// response (no key on this station), upgrade path: one operator-approved live read (--live) compared with the service's own figure.
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const NA = 'not available';
const DAY = 86400000;
const FIELDS = {
  codex_tokens: { unit: 'tokens', source: 'codex rollouts: event_msg token_count, total_token_usage grown over the window, summed across sessions' },
  codex_bank: { unit: 'percentage points of the weekly window', source: 'codex rollouts: event_msg token_count, rate_limits primary or secondary used_percent, whichever carries the 10080-minute weekly window' },
  claude_bank: { unit: 'percent of the subscription window', source: 'cadence ledger: five_hour and seven_day utilization read at each launch' },
  api_cost: { unit: 'USD', source: 'local-priced: api lane launch records (launches.jsonl), cost_usd settled from each call\'s own usage at the published per-model price' },
  openrouter: { unit: 'USD', source: 'OpenRouter GET /api/v1/key, usage' },
};
const na = (name, reason, extra = {}) => ({ status: NA, source: FIELDS[name].source, unit: FIELDS[name].unit, reason, ...extra });
const ok = (name, body) => ({ status: 'ok', source: FIELDS[name].source, unit: FIELDS[name].unit, ...body });
const ms = (iso) => Date.parse(iso);
const num = (v) => typeof v === 'number' && Number.isFinite(v);

// ---- codex rollouts -------------------------------------------------------------------------
function rolloutFiles(dir, floorMs, out = []) {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) rolloutFiles(p, floorMs, out);
    else if (e.name.startsWith('rollout-') && e.name.endsWith('.jsonl') && statSync(p).mtimeMs >= floorMs) out.push(p);
  }
  return out;
}
export function scanCodex(dir, since) {
  // A session idle since before the shift can hold the last pre-shift weekly reading: look back one weekly window.
  const sessions = rolloutFiles(dir, ms(since) - 7 * DAY).map((file) => {
    const events = [];
    for (const line of readFileSync(file, 'utf8').split('\n')) {
      if (!line.includes('"token_count"')) continue;
      let row;
      try { row = JSON.parse(line); } catch { continue; }
      const p = row?.payload;
      if (row?.type !== 'event_msg' || p?.type !== 'token_count' || !Number.isFinite(ms(row.timestamp))) continue;
      const weekly = [p.rate_limits?.primary, p.rate_limits?.secondary].find((w) => w?.window_minutes === 10080) ?? null;
      events.push({ t: ms(row.timestamp), usage: p.info?.total_token_usage ?? null,
        pct: num(weekly?.used_percent) ? weekly.used_percent : null, resets: weekly?.resets_at ?? null });
    }
    return events;
  });
  return sessions;
}
const TOKEN_KEYS = ['input_tokens', 'cached_input_tokens', 'output_tokens', 'reasoning_output_tokens', 'total_tokens'];
function codexTokens(sessions, s, u) {
  const sum = Object.fromEntries(TOKEN_KEYS.map((k) => [k, 0]));
  for (const events of sessions) {
    const withUsage = events.filter((e) => e.usage);
    const base = withUsage.filter((e) => e.t < s).at(-1)?.usage;
    const last = withUsage.filter((e) => e.t >= s && e.t < u).at(-1)?.usage;
    if (!last) continue;
    for (const k of TOKEN_KEYS) sum[k] += Math.max(0, (last[k] ?? 0) - (base?.[k] ?? 0));
  }
  return sum;
}
function codexBank(sessions, s, u) {
  const all = sessions.flat().filter((e) => e.pct !== null).sort((a, b) => a.t - b.t);
  const inside = all.filter((e) => e.t >= s && e.t < u);
  if (inside.length === 0) return { reason: 'no codex rate-limit reading inside the shift' };
  const before = all.filter((e) => e.t < s).at(-1);
  const start = before ?? inside[0];
  const end = inside.at(-1);
  if (start.resets === null || end.resets === null || start.resets !== end.resets || end.pct < start.pct) {
    return { reason: 'the weekly window reset during the shift, or its reset time is unknown, so the change is not comparable' };
  }
  return { start: start.pct, end: end.pct, value: Math.round((end.pct - start.pct) * 1e6) / 1e6, samples: inside.length,
    start_from: before ? 'last reading before the shift' : 'first reading inside the shift' };
}
export function codexField(dir, since, until, mode = 'tokens', scanned = null) {
  const name = mode === 'bank' ? 'codex_bank' : 'codex_tokens';
  if (!existsSync(dir)) return na(name, 'codex sessions directory not found');
  const sessions = scanned ?? scanCodex(dir, since);
  if (mode === 'bank') {
    const r = codexBank(sessions, ms(since), ms(until));
    return r.reason ? na(name, r.reason) : ok(name, r);
  }
  // Sessions that never reported a token total say nothing: that is not a measured zero.
  if (!sessions.some((events) => events.some((e) => e.usage))) return na(name, 'no codex token total found in the scanned sessions');
  const t = codexTokens(sessions, ms(since), ms(until));
  return ok(name, { ...t, value: t.total_tokens });
}

// ---- Claude bank history (cadence ledger) -----------------------------------------------------
export function claudeBankField(file, since, until) {
  if (!existsSync(file)) return na('claude_bank', 'cadence ledger not found');
  const rows = [];
  for (const line of readFileSync(file, 'utf8').split('\n')) {
    if (!line) continue;
    let r;
    try { r = JSON.parse(line); } catch { continue; }
    // Number(null) and Number('') are 0: a missing reading must not become a measured zero.
    const pct = (v) => ((typeof v === 'string' && v.trim() !== '') || num(v) ? Number(v) : NaN);
    const five = pct(r.five_hour), seven = pct(r.seven_day);
    if (r.degraded === true || !Number.isFinite(ms(r.ts)) || !Number.isFinite(five) || !Number.isFinite(seven)) continue;
    rows.push({ t: ms(r.ts), five_hour: five, seven_day: seven });
  }
  rows.sort((a, b) => a.t - b.t);
  const s = ms(since), u = ms(until);
  const inside = rows.filter((r) => r.t >= s && r.t < u);
  if (inside.length === 0) return na('claude_bank', 'no ledger reading inside the shift');
  const start = rows.filter((r) => r.t < s).at(-1) ?? inside[0];
  // The ledger carries no reset time, so any fall between two consecutive readings is read as a reset (or an
  // account change) inside the shift. The burn is the sum of the rises, and the first reading after a reset
  // counts in full (the window restarted from zero): one weekly reset must not blank a whole shift's figure.
  const span = (k) => {
    const series = [start, ...inside].map((r) => r[k]);
    let burn = 0, resets = 0;
    for (let i = 1; i < series.length; i++) {
      if (series[i] >= series[i - 1]) burn += series[i] - series[i - 1];
      else { burn += series[i]; resets++; }
    }
    return { start: series[0], end: series.at(-1), peak: Math.max(...series),
      delta: Math.round(burn * 1e6) / 1e6, ...(resets ? { resets } : {}) };
  };
  const seven_day = span('seven_day');
  return ok('claude_bank', { five_hour: span('five_hour'), seven_day, samples: inside.length, value: seven_day.delta,
    note: 'readings exist only where a launch preflighted the bank; a fall between two readings is read as a window reset (or an account change), and the reading after it counts in full; use between the last reading before a reset and the reset is unobserved, and a fall caused by an account change adds a reading no one used, so a figure with resets is an estimate, not an exact burn' });
}

// ---- API lane dollars (our own launch records) ------------------------------------------------
const MICRO = 1000000n;
const dollars = (micro) => `${micro / MICRO}.${String(micro % MICRO).padStart(6, '0')}`;
// cost_usd is written as a decimal string with at most six places; anything else is an unpriced run, never a zero.
const toMicro = (s) => {
  const m = /^(\d{1,12})(?:\.(\d{1,6}))?$/.exec(typeof s === 'string' ? s : '');
  return m ? BigInt(m[1]) * MICRO + BigInt((m[2] ?? '').padEnd(6, '0')) : null;
};
export function costField(file, since, until) {
  if (!file || !existsSync(file)) return na('api_cost', 'api lane launch log not found');
  const s = ms(since), u = ms(until);
  const micro = {};
  const tokens = { input: 0, cache_creation: 0, cache_read: 0 };
  let runs = 0, unpriced = 0, unreadable = 0;
  for (const line of readFileSync(file, 'utf8').split('\n')) {
    if (line.trim() === '') continue;
    let r;
    try { r = JSON.parse(line); } catch { unreadable++; continue; }
    const t = ms(r?.ts);
    if (!Number.isFinite(t)) { unreadable++; continue; }
    if (!(t >= s && t < u)) continue;
    for (const [k, v] of [['input', r.input_tokens], ['cache_creation', r.cache_creation_tokens], ['cache_read', r.cache_read_tokens]]) {
      if (Number.isInteger(v) && v >= 0) tokens[k] += v;
    }
    const cost = toMicro(r.cost_usd);
    if (cost === null) { unpriced++; continue; }
    const account = typeof r.account === 'string' && r.account ? r.account : '?';
    micro[account] = (micro[account] ?? 0n) + cost;
    runs++;
  }
  // Runs that left no cost say nothing about the spend: that is not a measured zero.
  if (runs === 0 && unpriced > 0) return na('api_cost', 'the launches inside the shift carry no cost', { unpriced_runs: unpriced });
  const per_account = Object.fromEntries(Object.keys(micro).sort().map((a) => [a, dollars(micro[a])]));
  const total = Object.values(micro).reduce((a, b) => a + b, 0n);
  // A run that left no cost, or a line that cannot be read (it may be a run of this shift), is missing from the sum:
  // the figure is then a floor, and says so.
  const left = unpriced + unreadable;
  return ok('api_cost', { per_account, value: dollars(total), runs, unpriced_runs: unpriced, unreadable_lines: unreadable, tokens,
    ...(left > 0 ? { partial: true, note: `at least this much: ${unpriced} run(s) in the shift carry no cost and ${unreadable} log line(s) are unreadable, so they are not in the sum` } : {}) });
}

// An error carries the reason only: never the response body, the request or the original error text.
async function getJson(fetchImpl, url, headers, label) {
  let res;
  try { res = await fetchImpl(url, { headers, redirect: 'error', signal: AbortSignal.timeout(15000) }); } catch { throw new Error(`${label}: network`); }
  if (!res.ok) throw new Error(`${label}: http-${res.status}`);
  try { return await res.json(); } catch { throw new Error(`${label}: invalid-json`); }
}

// ---- OpenRouter key usage ---------------------------------------------------------------------
export async function fetchOpenRouterKey(key, fetchImpl = globalThis.fetch) {
  return getJson(fetchImpl, 'https://openrouter.ai/api/v1/key', { Authorization: `Bearer ${key}` }, 'openrouter-key-unavailable');
}
export function openrouterField(src) {
  // No key is its own mark: the column is unavailable, not zero and not a failed read.
  if (src?.error) return na('openrouter', src.error, src.error === 'openrouter-key-missing' ? { source: 'unavailable(no key)' } : {});
  const d = src?.body?.data;
  if (d === null || typeof d !== 'object' || !num(d.usage) || !num(d.usage_daily)) return na('openrouter', 'invalid-key-response');
  const maybe = (v) => (num(v) ? v : null);
  return ok('openrouter', { usage_total: d.usage, usage_daily: d.usage_daily, usage_weekly: maybe(d.usage_weekly), usage_monthly: maybe(d.usage_monthly),
    limit: maybe(d.limit), limit_remaining: maybe(d.limit_remaining), value: d.usage_daily,
    note: 'usage_total is lifetime and usage_daily is the UTC day of the read: neither is cut to the shift' });
}

// ---- the record -------------------------------------------------------------------------------
export function buildRecord({ since, until, codexDir, ledgerFile, launchesFile, openrouter }) {
  const field = (name, read) => { try { return read(); } catch (e) { return na(name, e.message || 'unreadable'); } };
  let scanned = null;
  const scan = () => { if (!existsSync(codexDir)) return null; scanned ??= scanCodex(codexDir, since); return scanned; };
  return {
    window: { since, until },
    fields: {
      codex_tokens: field('codex_tokens', () => codexField(codexDir, since, until, 'tokens', scan())),
      codex_bank: field('codex_bank', () => codexField(codexDir, since, until, 'bank', scan())),
      claude_bank: field('claude_bank', () => claudeBankField(ledgerFile, since, until)),
      api_cost: field('api_cost', () => costField(launchesFile, since, until)),
      openrouter: field('openrouter', () => openrouterField(openrouter)),
    },
  };
}

// ---- command line -----------------------------------------------------------------------------
const ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,3})?Z$/;
function usageExit(msg) { console.error(`shift-spend: ${msg}`); process.exit(2); }
function readJson(file) { return JSON.parse(readFileSync(file, 'utf8')); }
async function main(argv, env) {
  const opt = { live: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--live') { opt.live = true; continue; }
    const v = argv[++i];
    if (!v) usageExit(`${a} needs a value`);
    if (a === '--since') opt.since = v;
    else if (a === '--until') opt.until = v;
    else if (a === '--codex-sessions') opt.codex = v;
    else if (a === '--cadence-ledger') opt.ledger = v;
    else if (a === '--openrouter-key-file') opt.orFile = v;
    else if (a === '--api-launches') opt.launches = v;
    else usageExit(`unknown argument: ${a}`);
  }
  // V8 rolls 2026-02-30 and T24:00:00Z over to the next day: only a stamp that round-trips is a real instant.
  const real = (s) => ISO.test(s ?? '') && Number.isFinite(ms(s)) && new Date(ms(s)).toISOString().slice(0, 19) === s.slice(0, 19);
  if (!real(opt.since) || !real(opt.until)) usageExit('--since and --until are required real UTC timestamps (YYYY-MM-DDTHH:MM:SS[.fff]Z)');
  if (!(ms(opt.since) < ms(opt.until))) usageExit('--until must be later than --since');

  const home = env.HOME || homedir();
  let openrouter = { error: 'no OpenRouter source given' };
  if (opt.orFile) {
    try { openrouter = { body: readJson(opt.orFile) }; } catch { openrouter = { error: 'key response file unreadable' }; }
  } else if (opt.live) {
    if (!env.OPENROUTER_API_KEY) openrouter = { error: 'openrouter-key-missing' };
    else try { openrouter = { body: await fetchOpenRouterKey(env.OPENROUTER_API_KEY) }; } catch (e) { openrouter = { error: e.message }; }
  }
  const record = buildRecord({
    since: opt.since, until: opt.until,
    codexDir: opt.codex || join(env.CODEX_HOME || join(home, '.codex'), 'sessions'),
    ledgerFile: opt.ledger || env.CADENCE_USAGE_LEDGER || join(home, '.himmel', 'cadence-ledger.jsonl'),
    launchesFile: opt.launches || join(home, '.himmel', 'state', 'api-credit', 'launches.jsonl'),
    openrouter,
  });
  console.log(JSON.stringify(record, null, 2));
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) await main(process.argv.slice(2), process.env);
