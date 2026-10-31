// One record per shift: what Claude, codex and API money or budget a window [since, until)
// used, from five sources. Every field carries its own source mark and unit and is never
// added into another (a bank percentage, tokens and dollars are different units). A source
// that cannot be read reads "not available", never zero.
//
// Usage: node shift-spend.mjs --since <iso Z> --until <iso Z> [--codex-sessions <dir>]
//          [--cadence-ledger <file>] [--cost-report-file <A|B>=<file>]... [--openrouter-key-file <file>] [--live]
// Without --live and without a response file the two API fields read "not available" and nothing
// is fetched. --live reads ANTHROPIC_ORG_<A|B>_KEY and OPENROUTER_API_KEY; a key is used only as
// a request header and never printed.
//
// ponytail: the API parsers are pinned to the vendor docs' response shapes and have not met a live
// response, upgrade path: the one operator-approved live read (--live) compared with each service's own figure.
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { adminKey, centsToMicro } from '../lib/api-credit-state.mjs';

const NA = 'not available';
const DAY = 86400000;
const FIELDS = {
  codex_tokens: { unit: 'tokens', source: 'codex rollouts: event_msg token_count, total_token_usage grown over the window, summed across sessions' },
  codex_bank: { unit: 'percentage points of the weekly window', source: 'codex rollouts: event_msg token_count, rate_limits primary or secondary used_percent, whichever carries the 10080-minute weekly window' },
  claude_bank: { unit: 'percent of the subscription window', source: 'cadence ledger: five_hour and seven_day utilization read at each launch' },
  api_cost: { unit: 'USD', source: 'Anthropic Admin API GET /v1/organizations/cost_report, daily buckets' },
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
  if (start.resets !== end.resets) return { reason: 'the weekly window reset during the shift, so the change is not comparable' };
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
  // The ledger carries no reset time, so any fall between two consecutive readings is read as a reset (or
  // an account change) inside the shift: the readings stay, the change is not stated.
  const span = (k) => {
    const series = [start, ...inside].map((r) => r[k]);
    const end = series.at(-1);
    const reset = series.some((v, i) => i > 0 && v < series[i - 1]);
    return { start: series[0], end, peak: Math.max(...series),
      delta: reset ? null : Math.round((end - series[0]) * 1e6) / 1e6, ...(reset ? { reset_in_window: true } : {}) };
  };
  const seven_day = span('seven_day');
  return ok('claude_bank', { five_hour: span('five_hour'), seven_day, samples: inside.length, value: seven_day.delta,
    note: 'readings exist only where a launch preflighted the bank; a five-hour window can reset inside a shift' });
}

// ---- Admin API cost report --------------------------------------------------------------------
const MICRO = 1000000n;
const dollars = (micro) => `${micro / MICRO}.${String(micro % MICRO).padStart(6, '0')}`;
function costMicro(bodies, from, to) {
  let total = 0n, complete = false;
  for (const body of bodies) {
    if (body === null || typeof body !== 'object' || !Array.isArray(body.data) || typeof body.has_more !== 'boolean') throw new Error('invalid-cost-report');
    for (const bucket of body.data) {
      if (bucket === null || typeof bucket !== 'object' || !Array.isArray(bucket.results)) throw new Error('invalid-cost-report');
      // A response for another window must not read as this shift's spend.
      if (!(ms(bucket.starting_at) >= ms(from) && ms(bucket.ending_at) <= ms(to))) throw new Error('cost-report-outside-window');
      for (const r of bucket.results) {
        if (r === null || typeof r !== 'object' || r.currency !== 'USD') throw new Error('invalid-cost-report');
        total += centsToMicro(r.amount);
      }
    }
    complete = !body.has_more;
  }
  if (!complete) throw new Error('incomplete-cost-report');
  return total;
}
const floorDay = (iso) => new Date(Math.floor(ms(iso) / DAY) * DAY).toISOString().replace('.000Z', 'Z');
const ceilDay = (iso) => new Date(Math.ceil(ms(iso) / DAY) * DAY).toISOString().replace('.000Z', 'Z');
export function costField(perAccount, since, until) {
  const accounts = Object.entries(perAccount ?? {});
  if (accounts.length === 0) return na('api_cost', 'no cost report source given');
  const per_account = {};
  let total = 0n, failed = false;
  const reasons = [];
  for (const [account, src] of accounts) {
    try {
      if (src.error) throw new Error(src.error);
      const micro = costMicro(src.bodies, floorDay(since), ceilDay(until));
      per_account[account] = dollars(micro);
      total += micro;
    } catch (e) { per_account[account] = NA; failed = true; reasons.push(`${account}: ${e.message}`); }
  }
  const covered = { granularity: '1d', note: 'the report cannot split a UTC day: the whole days overlapping the shift', from: floorDay(since), to: ceilDay(until) };
  if (failed) return na('api_cost', reasons.join('; '), { per_account, covered });
  return ok('api_cost', { per_account, value: dollars(total), covered });
}
export async function fetchCostPages(key, since, until, fetchImpl = globalThis.fetch) {
  const bodies = [];
  let page = null;
  for (let i = 0; i < 20; i++) {
    const url = new URL('https://api.anthropic.com/v1/organizations/cost_report');
    url.searchParams.set('starting_at', floorDay(since));
    url.searchParams.set('ending_at', ceilDay(until));
    url.searchParams.set('bucket_width', '1d');
    url.searchParams.set('limit', '31');
    if (page) url.searchParams.set('page', page);
    const body = await getJson(fetchImpl, url, { 'x-api-key': key, 'anthropic-version': '2023-06-01' }, 'cost-report-unavailable');
    bodies.push(body);
    if (!body.has_more) return bodies;
    if (typeof body.next_page !== 'string' || !body.next_page) throw new Error('invalid-cost-report');
    page = body.next_page;
  }
  throw new Error('cost-report-too-long');
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
  if (src?.error) return na('openrouter', src.error);
  const d = src?.body?.data;
  if (d === null || typeof d !== 'object' || !num(d.usage) || !num(d.usage_daily)) return na('openrouter', 'invalid-key-response');
  const maybe = (v) => (num(v) ? v : null);
  return ok('openrouter', { usage_total: d.usage, usage_daily: d.usage_daily, usage_weekly: maybe(d.usage_weekly), usage_monthly: maybe(d.usage_monthly),
    limit: maybe(d.limit), limit_remaining: maybe(d.limit_remaining), value: d.usage_daily,
    note: 'usage_total is lifetime and usage_daily is the UTC day of the read: neither is cut to the shift' });
}

// ---- the record -------------------------------------------------------------------------------
export function buildRecord({ since, until, codexDir, ledgerFile, cost, openrouter }) {
  const field = (name, read) => { try { return read(); } catch (e) { return na(name, e.message || 'unreadable'); } };
  let scanned = null;
  const scan = () => { if (!existsSync(codexDir)) return null; scanned ??= scanCodex(codexDir, since); return scanned; };
  return {
    window: { since, until },
    fields: {
      codex_tokens: field('codex_tokens', () => codexField(codexDir, since, until, 'tokens', scan())),
      codex_bank: field('codex_bank', () => codexField(codexDir, since, until, 'bank', scan())),
      claude_bank: field('claude_bank', () => claudeBankField(ledgerFile, since, until)),
      api_cost: field('api_cost', () => costField(cost, since, until)),
      openrouter: field('openrouter', () => openrouterField(openrouter)),
    },
  };
}

// ---- command line -----------------------------------------------------------------------------
const ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,3})?Z$/;
function usageExit(msg) { console.error(`shift-spend: ${msg}`); process.exit(2); }
function readJson(file) { return JSON.parse(readFileSync(file, 'utf8')); }
async function main(argv, env) {
  const opt = { costFiles: {}, live: false };
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
    else if (a === '--cost-report-file') {
      const m = /^([AB])=(.+)$/.exec(v);
      if (!m) usageExit('--cost-report-file wants A=<file> or B=<file>');
      (opt.costFiles[m[1]] ??= []).push(m[2]);
    } else usageExit(`unknown argument: ${a}`);
  }
  if (!ISO.test(opt.since ?? '') || !ISO.test(opt.until ?? '')) usageExit('--since and --until are required UTC timestamps (YYYY-MM-DDTHH:MM:SS[.fff]Z)');
  if (!(ms(opt.since) < ms(opt.until))) usageExit('--until must be later than --since');

  const home = env.HOME || homedir();
  let cost = null, openrouter = { error: 'no OpenRouter source given' };
  if (Object.keys(opt.costFiles).length) {
    cost = {};
    for (const [account, files] of Object.entries(opt.costFiles)) {
      try { cost[account] = { bodies: files.map(readJson) }; } catch { cost[account] = { error: 'cost report file unreadable' }; }
    }
  } else if (opt.live) {
    const keys = ['A', 'B'].map((account) => [account, adminKey(env, account)]).filter(([, k]) => k);
    cost = {};
    for (const [account, key] of keys) {
      try { cost[account] = { bodies: await fetchCostPages(key, opt.since, opt.until) }; } catch (e) { cost[account] = { error: e.message }; }
    }
    if (keys.length === 0) cost = { A: { error: 'admin-key-missing' } };
  }
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
    cost, openrouter,
  });
  console.log(JSON.stringify(record, null, 2));
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) await main(process.argv.slice(2), process.env);
