// local, secret-free API grant accounting. No auth or network.
// Amounts are decimal-string USD with at most six places; arithmetic is BigInt.
// One shared ledger/lock covers both accounts. Locks are never reclaimed by age
// or PID: a crashed holder requires operator recovery, not guessed free credit.
// ponytail: launcher-supplied cost/completion evidence is trusted; task 2 must
// bound requests and prove terminal outcomes before API dispatch is enabled.
import {
  closeSync, existsSync, fsyncSync, mkdirSync, openSync, readFileSync,
  lstatSync, realpathSync, renameSync, rmdirSync, unlinkSync, writeFileSync,
} from 'node:fs';
import { basename, dirname, isAbsolute, join, resolve } from 'node:path';
import { execFileSync } from 'node:child_process';
import { userInfo } from 'node:os';
import { fileURLToPath, pathToFileURL } from 'node:url';

const SCALE = 1000000n;
const MAX_AGE = 600;
// Operator decision 185: both grants reset on one date, whatever expiry a snapshot row carries.
// A config account may override it with reset_at for the next cycle.
export const GRANT_RESET_AT = { A: '2026-11-01T00:00:00Z', B: '2026-11-01T00:00:00Z' };
// Auto routing prefers a snapshot younger than this: the ledger cannot see spend billed outside it.
// An older operator snapshot still routes (flagged snapshot_stale) while its estimate has headroom.
const ROUTE_MAX_AGE = 86400;
// An account whose last call came back credit-exhausted is skipped by auto routing this long (a newer
// snapshot reading clears it sooner); it still serves when no other account has room.
const EXHAUSTED_TTL = 3600;
// A ledger-only row has no grant date: it sorts after every account with a real expiry.
const NO_EXPIRY = 4102444800;
// Reasons a snapshot gives no usable reading; with HIMMEL_API_SNAPSHOT_OPTIONAL=1 (auto routing) the ledger and
// the account cap decide instead. Identity mismatch and the discrepancy flag stay refusals.
const SNAPSHOT_UNUSABLE = new Set(['missing-snapshot', 'invalid-snapshot', 'unreconciled-amounts', 'invalid-timestamp',
  'invalid-grant-interval', 'expired-grant', 'stale-snapshot', 'invalid-money']);
// A call past this has died or been killed: its reservation is released, never held for good.
const CALL_TIMEOUT = 3600;
// The launcher stops a call at its timeout and kills what ignored TERM this many seconds later.
const KILL_GRACE = 5;
// ponytail: the cost report cannot separate promotional from card spend, so
// 'automatic-snapshot' treats all spend since the grant start as grant spend; upgrade
// path: a promotional-credit balance endpoint, if Anthropic exposes one.
const SOURCES = ['operator-console-snapshot', 'automatic-snapshot'];
// parallel admissions queue on the ledger lock instead of failing; the
// wait is bounded so a crashed holder still refuses, never admits.
const LOCK_WAIT_MS = 5000;
function takeLock(lock, env) {
  // An empty value is unset (Number('') is 0, which would disable the retry).
  const raw = env.HIMMEL_API_LOCK_WAIT_MS;
  const wait = raw !== undefined && raw !== '' && Number.isSafeInteger(Number(raw)) && Number(raw) >= 0
    ? Number(raw) : LOCK_WAIT_MS;
  const sleeper = new Int32Array(new SharedArrayBuffer(4));
  const deadline = Date.now() + wait;
  for (let pause = 5; ; pause = Math.min(pause * 2, 50)) {
    try { mkdirSync(lock, { mode: 0o700 }); return; } catch (e) {
      if (e.code !== 'EEXIST' || Date.now() >= deadline) refuse('ledger-locked-or-unwritable');
    }
    Atomics.wait(sleeper, 0, 0, pause + Math.floor(Math.random() * pause));
  }
}
function callTimeout(env) {
  const raw = env.HIMMEL_API_CALL_TIMEOUT_S;
  return /^[1-9][0-9]{0,8}$/.test(raw ?? '') ? Number(raw) : CALL_TIMEOUT;
}
function instant(text) {
  const t = Date.parse(text);
  // Date.parse rolls 2026-02-30 over to March: only a timestamp that round-trips is real.
  if (typeof text !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(text)
    || !Number.isFinite(t) || new Date(t).toISOString().replace('.000Z', 'Z') !== text) refuse('invalid-config');
  return Math.floor(t / 1000);
}
const resetAt = (c, account) => instant(c.reset_at ?? GRANT_RESET_AT[account]);
const ID = /^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$/;
const object = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const own = (v, k) => Object.hasOwn(v, k);

function refuse(reason, verdict = 'BANK-UNKNOWN', detail) {
  const e = new Error(reason); e.verdict = verdict; if (detail) e.detail = detail; throw e;
}
function money(value) {
  if (typeof value !== 'string' || !/^(0|[1-9][0-9]{0,12})(\.[0-9]{1,6})?$/.test(value)) refuse('invalid-money');
  const [whole, fraction = ''] = value.split('.');
  return BigInt(whole) * SCALE + BigInt(fraction.padEnd(6, '0'));
}
function usd(value) {
  return `${value / SCALE}.${String(value % SCALE).padStart(6, '0')}`;
}
function read(path) {
  try { return JSON.parse(readFileSync(path, 'utf8')); } catch { refuse('unreadable-state'); }
}
function id(value) {
  if (typeof value !== 'string' || !ID.test(value)) refuse('invalid-identity');
  return value;
}
function configs(config) {
  if (!object(config) || config.version !== 1 || !object(config.accounts)) refuse('invalid-config');
  if (typeof config.ledger_path !== 'string' || !isAbsolute(config.ledger_path)) refuse('ledger-path-required');
  const orgs = new Set();
  const names = Object.keys(config.accounts);
  if (names.length === 0) refuse('missing-account-config');
  for (const account of names) {
    if (!['A', 'B'].includes(account)) refuse('invalid-account-config');
    const c = config.accounts[account];
    if (!object(c)) refuse('invalid-account-config');
    id(c.organization_id); id(c.cycle_id); money(c.cap_usd);
    if (own(c, 'reset_at')) instant(c.reset_at);
    if (own(c, 'key_id')) id(c.key_id);  // non-secret provider key identifier, never the key
    if (orgs.has(c.organization_id)) refuse('duplicate-organization');
    orgs.add(c.organization_id);
  }
}
function identity(a, c) {
  if (a.organization_id !== c.organization_id || a.cycle_id !== c.cycle_id) refuse('identity-or-cycle-mismatch');
}
function ledgerCheck(state) {
  if (!object(state) || state.version !== 1 || !object(state.accounts)) refuse('invalid-ledger');
  for (const [name, a] of Object.entries(state.accounts)) {
    if (!['A', 'B'].includes(name) || !object(a) || !object(a.jobs) || typeof a.discrepancy !== 'boolean') refuse('invalid-ledger');
    id(a.organization_id); id(a.cycle_id);
    for (const [job, j] of Object.entries(a.jobs)) {
      id(job);
      if (!object(j) || !['reserved', 'unknown', 'settled'].includes(j.status) || money(j.maximum_usd) === 0n) refuse('invalid-ledger');
      if (j.status === 'settled') {
        const actual = money(j.actual_usd);
        if (actual > money(j.maximum_usd) && !a.discrepancy) refuse('unrecorded-discrepancy');
      } else if (own(j, 'actual_usd')) refuse('invalid-ledger');
    }
  }
}
function totals(a) {
  let spent = 0n, reserved = 0n;
  for (const j of Object.values(a?.jobs ?? {})) {
    if (j.status === 'settled') spent += money(j.actual_usd);
    else reserved += money(j.maximum_usd);
  }
  return { spent, reserved };
}
function snapshotRow(config, snapshot, a, account, now) {
  if (!object(snapshot) || snapshot.version !== 1 || !object(snapshot.accounts) || !own(snapshot.accounts, account)) refuse('missing-snapshot');
  const s = snapshot.accounts[account];
  if (!object(s)) refuse('invalid-snapshot');
  identity(s, config);
  const grant = money(s.grant_usd), remaining = money(s.remaining_usd), cap = money(config.cap_usd);
  const watermark = money(s.reconciled_spent_usd);
  const { spent, reserved } = totals(a);
  if (remaining > grant || cap > grant || watermark > spent || watermark > grant - remaining) refuse('unreconciled-amounts');
  if (s.exclusive_org !== true || s.discrepancy !== false || a?.discrepancy || !SOURCES.includes(s.source)) refuse('unverified-or-discrepant');
  for (const t of [s.starts_at, s.expires_at, s.observed_at]) {
    if (!Number.isSafeInteger(t) || t < 0) refuse('invalid-timestamp');
  }
  if (s.starts_at >= s.expires_at || s.starts_at > now || s.observed_at < s.starts_at) refuse('invalid-grant-interval');
  // A grant that began before the reset date ends there; one that begins on or after it is the next cycle.
  const reset = resetAt(config, account);
  const expires = s.starts_at < reset ? Math.min(s.expires_at, reset) : s.expires_at;
  if (expires <= now) refuse('expired-grant', 'SKIPPED-BANK');
  const age = now - s.observed_at;
  // an operator reading never goes stale; the remaining credit is derived
  // from it minus the ledger below, and the cap plus reserve accounting stay the hard
  // stop. Only an automatically pulled snapshot carries a freshness window.
  if (age < 0 || (s.source === 'automatic-snapshot' && age > MAX_AGE)) refuse('stale-snapshot', 'BANK-STALE');
  // Snapshot includes provider-observed spend. Subtract only local completions
  // after the explicit reconciliation watermark, plus every outstanding maximum.
  const consumed = grant - remaining + spent - watermark;
  const available = (cap < grant ? cap : grant) - consumed - reserved;
  return {
    verdict: available > 0n ? 'PROCEED' : 'SKIPPED-BANK', account,
    organization_id: s.organization_id, cycle_id: s.cycle_id,
    grant_usd: usd(grant), cap_usd: usd(cap), spent_est_usd: usd(consumed),
    reserved_usd: usd(reserved), available_est_usd: usd(available > 0n ? available : 0n),
    expires_at: expires, age_seconds: age, source: s.source, snapshot_stale: age > ROUTE_MAX_AGE,
    observed_at: s.observed_at, exhausted_at: a?.exhausted_at ?? null,
  };
}
// No usable credit reading: what the local ledger and the account cap still allow. Anthropic's own limits
// decide the rest (a credit-exhausted answer marks the account, see 'exhausted').
function ledgerRow(config, a, account) {
  const cap = money(config.cap_usd);
  const { spent, reserved } = totals(a);
  if (a?.discrepancy) refuse('unverified-or-discrepant');
  const available = cap - spent - reserved;
  return {
    verdict: available > 0n ? 'PROCEED' : 'SKIPPED-BANK', account,
    organization_id: config.organization_id, cycle_id: config.cycle_id,
    grant_usd: usd(cap), cap_usd: usd(cap), spent_est_usd: usd(spent),
    reserved_usd: usd(reserved), available_est_usd: usd(available > 0n ? available : 0n),
    expires_at: NO_EXPIRY, age_seconds: null, source: 'ledger-only', snapshot_stale: true, snapshot_unknown: true,
    observed_at: null, exhausted_at: a?.exhausted_at ?? null,
  };
}
function row(config, snapshot, a, account, now, optional = false, need = 0n) {
  try {
    const r = snapshotRow(config, snapshot, a, account, now);
    // an old reading with too little left is a guess, not a fact: under optional routing the cap decides
    if (optional && r.snapshot_stale && money(r.available_est_usd) < (need > 0n ? need : 1n)) return ledgerRow(config, a, account);
    return r;
  } catch (e) {
    if (optional && SNAPSHOT_UNUSABLE.has(e.message)) return ledgerRow(config, a, account);
    throw e;
  }
}
// Release every reservation past the call timeout (or without a timestamp, from before it was
// recorded): the call is dead, so it settles at zero rather than holding credit for good.
function sweep(a, now, timeout) {
  let released = false;
  for (const j of Object.values(a?.jobs ?? {})) {
    if (j.status === 'settled') continue;
    const limit = (Number.isSafeInteger(j.timeout_s) && j.timeout_s > 0 ? j.timeout_s : timeout) + KILL_GRACE;
    if (Number.isSafeInteger(j.reserved_at) && now - j.reserved_at <= limit) continue;
    j.status = 'settled'; j.actual_usd = usd(0n); j.released = true; released = true;
  }
  return released;
}
function durableFile(path, contents) {
  const fd = openSync(path, 'wx', 0o600);
  try { writeFileSync(fd, contents); fsyncSync(fd); } finally { closeSync(fd); }
}
function syncDirectory(path) {
  const fd = openSync(path, 'r');
  try { fsyncSync(fd); } finally { closeSync(fd); }
}
function save(statePath, state, lock, sentinels) {
  // Sentinels precede the first write: missing/corrupt ledger after a crash must
  // never look like an unused grant. Keep them through every cycle/settlement.
  // Two independent files (beside the ledger and beside the config) so deleting
  // the ledger and one sentinel still refuses.
  for (const sentinel of sentinels) {
    if (!existsSync(sentinel)) {
      durableFile(sentinel, 'api-credit-ledger-v1\n');
      syncDirectory(dirname(sentinel));
    }
  }
  const temporary = join(lock, 'ledger.json');
  durableFile(temporary, `${JSON.stringify(state)}\n`);
  renameSync(temporary, statePath);
  syncDirectory(dirname(statePath));
}

const stateRoot = () => join(userInfo().homedir, '.himmel/state/api-credit');
const configPathFor = (env) => resolve(env.HIMMEL_API_CREDIT_CONFIG || join(stateRoot(), 'config.json'));

// the secret-free roster entry for HIMMEL_API_ACCOUNT, or a refusal.
export function configuredAccount(env = process.env) {
  try {
    const account = env.HIMMEL_API_ACCOUNT;
    if (!['A', 'B'].includes(account)) refuse('account-required');
    const config = read(configPathFor(env));
    configs(config);
    if (!own(config.accounts, account)) refuse('account-not-configured');
    return { account, ledger_path: config.ledger_path, ...config.accounts[account] };
  } catch (e) {
    return { verdict: e.verdict || 'BANK-UNKNOWN', reason: e.verdict ? e.message : 'state-io-failure' };
  }
}

export function creditState(command, options = {}, env = process.env) {
  // Account home, not $HOME: a changed HOME must not select a different config.
  const root = stateRoot();
  let lock, held = false;
  try {
    const account = env.HIMMEL_API_ACCOUNT;
    if (!['A', 'B'].includes(account)) refuse('account-required');
    if (!['status', 'reserve', 'unknown', 'settle', 'exhausted'].includes(command)) refuse('invalid-command');
    const optional = env.HIMMEL_API_SNAPSHOT_OPTIONAL === '1';
    const configPath = configPathFor(env);
    const config = read(configPath);
    configs(config);
    if (!own(config.accounts, account)) refuse('account-not-configured');
    const c = config.accounts[account];
    // The config pins the one ledger; an env override may only restate it.
    let statePath = resolve(config.ledger_path);
    mkdirSync(dirname(statePath), { recursive: true, mode: 0o700 });
    const canonical = (p) => join(realpathSync(dirname(p)), basename(p));
    if (env.HIMMEL_API_CREDIT_STATE) {
      const requested = resolve(env.HIMMEL_API_CREDIT_STATE);
      mkdirSync(dirname(requested), { recursive: true, mode: 0o700 });
      if (canonical(requested) !== canonical(statePath)) refuse('ledger-path-mismatch');
    }
    // Canonicalise the parent so aliases through symlinked directories share
    // the same transaction lock. The operator must use one ledger for the fleet.
    statePath = canonical(statePath);
    lock = `${statePath}.lock`;
    takeLock(lock, env); held = true;
    // A file symlink/hardlink alias has another basename and therefore another
    // mutex. Reject it rather than read shared spend under an unrelated lock.
    try {
      const stat = lstatSync(statePath);
      if (!stat.isFile() || stat.nlink !== 1) refuse('aliased-or-invalid-ledger');
    } catch (e) { if (e.code !== 'ENOENT') throw e; }
    const sentinels = [`${statePath}.initialized`, join(realpathSync(dirname(configPath)), `${basename(statePath)}.config-initialized`)];
    for (const sentinel of sentinels) {
      if (existsSync(sentinel) && readFileSync(sentinel, 'utf8') !== 'api-credit-ledger-v1\n') refuse('invalid-ledger-sentinel');
    }
    if (!existsSync(statePath) && sentinels.some((sentinel) => existsSync(sentinel))) refuse('missing-initialized-ledger');
    const state = existsSync(statePath) ? read(statePath) : { version: 1, accounts: {} };
    ledgerCheck(state);
    // Changing a configured identity cannot hide a previous cycle's obligations.
    // Rollover is explicit operator reconciliation, never a calendar reset.
    for (const [name, a] of Object.entries(state.accounts)) {
      if (!own(config.accounts, name)) refuse('unconfigured-ledger-account');
      identity(a, config.accounts[name]);
    }
    let a = state.accounts[account];
    if (command === 'status' || command === 'reserve') {
      const now = Math.floor(Date.now() / 1000);
      if (sweep(a, now, callTimeout(env))) save(statePath, state, lock, sentinels);
      let snapshot = null;
      try { snapshot = read(env.HIMMEL_API_CREDIT_SNAPSHOT || join(root, 'snapshot.json')); } catch (e) { if (!optional) throw e; }
      const result = row(c, snapshot, a, account, now, optional, options.usd ? money(options.usd) : 0n);
      // under optional routing an old or absent reading with no room in our own estimate still proceeds
      // (the pick marks it over_estimate); a fresh reading with nothing left, or a discrepancy, still refuses
      if (command === 'status') {
        return optional && result.snapshot_stale && result.verdict === 'SKIPPED-BANK'
          ? { ...result, verdict: 'PROCEED', over_estimate: true } : result;
      }
      id(options.id);
      const maximum = money(options.usd);
      if (maximum === 0n) refuse('positive-maximum-required');
      if (a && own(a.jobs, options.id)) refuse('duplicate-job');
      // our own estimate (the cap and the ledger) never refuses a start while the credit reading is old or absent:
      // only a fresh reading with too little left does, and the API's own credit-too-low answer is the hard stop
      const overEstimate = maximum > money(result.available_est_usd);
      if (overEstimate && !(optional && result.snapshot_stale)) return { ...result, verdict: 'SKIPPED-BANK', reason: 'insufficient-headroom' };
      if (!a) {
        a = { organization_id: c.organization_id, cycle_id: c.cycle_id, discrepancy: false, jobs: {} };
        state.accounts[account] = a;
      }
      a.jobs[options.id] = { status: 'reserved', maximum_usd: usd(maximum), reserved_at: now, timeout_s: callTimeout(env) };
      save(statePath, state, lock, sentinels);
      // Report the committed admission, not a second clock-dependent verdict.
      return { ...result, verdict: 'PROCEED', job_id: options.id,
        ...(overEstimate ? { over_estimate: true } : {}),
        reserved_usd: usd(money(result.reserved_usd) + maximum),
        available_est_usd: usd(overEstimate ? 0n : money(result.available_est_usd) - maximum) };
    }
    if (command === 'exhausted') {
      if (!a) {
        a = { organization_id: c.organization_id, cycle_id: c.cycle_id, discrepancy: false, jobs: {} };
        state.accounts[account] = a;
      }
      a.exhausted_at = Math.floor(Date.now() / 1000);
      save(statePath, state, lock, sentinels);
      return { verdict: 'PROCEED', account, exhausted_at: a.exhausted_at };
    }
    id(options.id);
    if (!a || !own(a.jobs, options.id)) refuse('missing-job');
    const job = a.jobs[options.id];
    if (job.status === 'settled') refuse('already-settled');
    if (command === 'unknown') {
      job.status = 'unknown'; save(statePath, state, lock, sentinels);
      return { verdict: 'PROCEED', account, job_id: options.id, reserved_usd: usd(totals(a).reserved) };
    }
    if (options.completion !== 'verified') refuse('terminal-completion-required');
    const actual = money(options.usd);
    job.status = 'settled'; job.actual_usd = usd(actual);
    if (actual > money(job.maximum_usd)) a.discrepancy = true;
    save(statePath, state, lock, sentinels);
    return { verdict: a.discrepancy ? 'BANK-UNKNOWN' : 'PROCEED', account, job_id: options.id,
      reason: a.discrepancy ? 'reservation-overrun' : 'settled' };
  } catch (e) {
    return { verdict: e.verdict || 'BANK-UNKNOWN', reason: e.verdict ? e.message : 'state-io-failure' };
  } finally {
    if (held) {
      // Only our private lock is released; no stale-owner sweep anywhere.
      try { unlinkSync(join(lock, 'ledger.json')); } catch { /* no temporary file */ }
      try { rmdirSync(lock); } catch { /* orphan lock blocks future admissions */ }
    }
  }
}

// routing for HIMMEL_API_ACCOUNT=auto. Of the configured accounts whose row has room for the whole
// budget (each under its own cap), spend the grant that expires first; a tie goes to A. An absent, stale
// or unusable snapshot never refuses a route: the ledger estimate only orders the accounts, each call is
// bounded by its own budget, and Anthropic's credit answer decides the rest (the pick carries snapshot_stale / snapshot_unknown). A reading
// fresher than 24 h wins over an older one. An account marked exhausted within the last hour is skipped
// unless a newer reading exists; when every account with room is marked, the one marked longest ago
// serves, so a pick is never refused for that. An account with an old or no reading whose own estimate has no
// room still serves (over_estimate): the estimate never refuses a start, only the API's credit answer does.
// A fresh reading with too little left still refuses.
export function pickAccount(budget, env = process.env) {
  try {
    const need = money(budget);
    const config = read(configPathFor(env));
    configs(config);
    const pickEnv = { ...env, HIMMEL_API_SNAPSHOT_OPTIONAL: '1' };
    const now = Math.floor(Date.now() / 1000);
    const all = Object.keys(config.accounts).sort()
      .map((account) => creditState('status', { usd: budget }, { ...pickEnv, HIMMEL_API_ACCOUNT: account }));
    const roomy = all.filter((r) => r.verdict === 'PROCEED' && money(r.available_est_usd) >= need);
    const marked = (r) => Number.isInteger(r.exhausted_at) && now - r.exhausted_at < EXHAUSTED_TTL
      && !(Number.isInteger(r.observed_at) && r.observed_at > r.exhausted_at);
    const byExpiry = (x, y) => x.expires_at - y.expires_at;
    const open = roomy.filter((r) => !marked(r));
    const fresh = open.filter((r) => !r.snapshot_stale).sort(byExpiry);
    // a row with an old or no reading whose own estimate has no room still serves: only a real credit-exhausted
    // answer stops it, so it ranks after every row with room, an unmarked one before a marked one
    const over = all.filter((r) => r.snapshot_stale && !roomy.includes(r));
    const byRoom = (x, y) => Number(money(y.available_est_usd) - money(x.available_est_usd));
    const rows = fresh.length > 0 ? fresh
      : open.length > 0 ? open.sort(byExpiry)
        : [...over.filter((r) => !marked(r)).sort(byRoom), ...roomy.sort((x, y) => x.exhausted_at - y.exhausted_at),
          ...over.filter(marked).sort(byRoom)];
    if (rows.length === 0) return { verdict: 'SKIPPED-BANK', reason: 'no-account-with-headroom' };
    const r = rows[0];
    return { verdict: 'PROCEED', account: r.account, expires_at: r.expires_at,
      ...(over.includes(r) ? { over_estimate: true } : {}),
      ...(r.snapshot_unknown ? { snapshot_unknown: true } : {}),
      ...(r.snapshot_stale ? { snapshot_stale: true, age_seconds: r.age_seconds } : {}),
      ...(marked(r) ? { exhausted_at: r.exhausted_at } : {}) };
  } catch (e) {
    return { verdict: e.verdict || 'BANK-UNKNOWN', reason: e.verdict ? e.message : 'state-io-failure' };
  }
}

// operator snapshot refresh from a Console reading. The reading
// already includes every job the provider has billed, so the watermark moves up
// with it; without that the billed spend counts twice. It moves by the smaller
// of the local spend and the billed spend added since the previous reading, so
// spend billed earlier (outside the ledger) never hides a settlement the Console
// does not show yet. A new grant row starts the watermark at zero (conservative).
// ponytail: billed spend from outside the ledger that lands in the same window
// as an unbilled settlement is read as that settlement (exclusive_org attests
// there is none), upgrade path: the Admin cost_report collector (task 6 of the
// plan).
export function refreshSnapshot(env, account, { remaining, grant, starts, expires, source = 'operator-console-snapshot', expect, pulled = false }) {
  let lock = null;
  try {
    if (!['A', 'B'].includes(account)) refuse('account-required');
    const config = read(configPathFor(env));
    configs(config);
    if (!own(config.accounts, account)) refuse('account-not-configured');
    const c = config.accounts[account];
    // The ledger's own transaction lock, held across both reads and the write: no
    // reservation, settlement or second refresh changes either file underneath it.
    const ledgerPath = resolve(config.ledger_path);
    const held = `${join(realpathSync(dirname(ledgerPath)), basename(ledgerPath))}.lock`;
    takeLock(held, env); lock = held;
    const path = env.HIMMEL_API_CREDIT_SNAPSHOT || join(stateRoot(), 'snapshot.json');
    const snapshot = existsSync(path) ? read(path) : { version: 1, accounts: {} };
    if (!object(snapshot) || snapshot.version !== 1 || !object(snapshot.accounts)) refuse('invalid-snapshot');
    const prior = snapshot.accounts[account];
    const s = { ...(prior ?? {}) };
    // A pull computed its figure from one grant row before awaiting HTTP; if a grant
    // replacement landed meanwhile that figure belongs to the old grant.
    // It also pins the reading itself, so a pull cannot overwrite an operator reading or a
    // watermark that landed while the HTTP call was in flight.
    if (expect && (!object(prior) || Object.keys(expect).some((k) => prior[k] !== expect[k]))) refuse('grant-changed');
    if (grant !== undefined) {
      const day = (d) => {
        const t = Date.parse(`${d}T00:00:00Z`);
        // Date.parse rolls 2026-02-30 over to March: only a date that round-trips is real.
        if (!/^\d{4}-\d{2}-\d{2}$/.test(d ?? '') || !Number.isFinite(t) || new Date(t).toISOString().slice(0, 10) !== d) refuse('invalid-date');
        return Math.floor(t / 1000);
      };
      // A new grant row: exclusive use of the org is the operator's attestation.
      Object.assign(s, { grant_usd: usd(money(grant)), starts_at: day(starts), expires_at: day(expires),
        exclusive_org: true, discrepancy: false });
    } else if (!own(snapshot.accounts, account)) refuse('missing-snapshot');
    Object.assign(s, { organization_id: c.organization_id, cycle_id: c.cycle_id });
    let left = money(remaining);
    const granted = money(s.grant_usd);
    // Within one grant the remaining credit can only fall: a pulled figure above the row's
    // own (a lagging or partial report) keeps the smaller, so a pull never admits more.
    if (pulled && object(prior)) { const was = money(prior.remaining_usd); if (left > was) left = was; }
    if (left > granted) refuse('unreconciled-amounts');
    const ledger = existsSync(ledgerPath) ? read(ledgerPath) : { version: 1, accounts: {} };
    ledgerCheck(ledger);
    const { spent } = totals(ledger.accounts[account]);
    const billed = granted - left;
    const same = object(prior) && ['grant_usd', 'starts_at', 'expires_at'].every((k) => prior[k] === s[k]);
    let mark = 0n;
    if (same) {
      const was = money(prior.reconciled_spent_usd);
      const step = [spent - was, billed - (money(prior.grant_usd) - money(prior.remaining_usd))]
        .reduce((x, y) => (x < y ? x : y));
      mark = was + (step > 0n ? step : 0n);
    }
    s.reconciled_spent_usd = usd(mark);
    s.remaining_usd = usd(left);
    s.observed_at = Math.floor(Date.now() / 1000);
    s.source = source;
    if (pulled) s.pulled_at = s.observed_at;
    snapshot.accounts[account] = s;
    writeFileSync(`${path}.${process.pid}.tmp`, `${JSON.stringify(snapshot, null, 2)}\n`, { mode: 0o600 });
    renameSync(`${path}.${process.pid}.tmp`, path);
    return { verdict: 'PROCEED', account, remaining_usd: s.remaining_usd,
      reconciled_spent_usd: s.reconciled_spent_usd, expires_at: s.expires_at };
  } catch (e) {
    return { verdict: e.verdict || 'BANK-UNKNOWN', reason: e.verdict ? e.message : 'state-io-failure' };
  } finally {
    if (lock) try { rmdirSync(lock); } catch { /* an orphan lock blocks admissions, never frees them */ }
  }
}

// automatic snapshot. Remaining = the row's grant minus the Admin API cost
// report's spend since the grant start (GET /v1/organizations/cost_report, x-api-key,
// amounts in cents as decimal strings, daily buckets, paged). The report carries no
// promotional-vs-card field, so spend past the grant reads as zero remaining, never as
// credit; the write goes through refreshSnapshot so the watermark and lock are shared.
// The key is read here only (env, then a dotenv file), never printed or put on argv.
const COST_REPORT = 'https://api.anthropic.com/v1/organizations/cost_report';
function adminKey(env, account) {
  const name = `ANTHROPIC_ORG_${account}_KEY`;
  if (env[name]) return env[name];
  const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
  let files = [join(root, '.env')];
  if (env.HIMMEL_DOTENV_FILE) files = [env.HIMMEL_DOTENV_FILE];
  else {
    try {
      const common = execFileSync('git', ['-C', root, 'rev-parse', '--path-format=absolute', '--git-common-dir'],
        { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
      files.push(join(dirname(common), '.env'));
    } catch { /* not a checkout: the worktree-local file only */ }
  }
  for (const file of files) {
    let text;
    try { text = readFileSync(file, 'utf8'); } catch { continue; }
    for (const line of text.split('\n')) {
      if (!line.startsWith(`${name}=`)) continue;
      const value = line.slice(name.length + 1).trim().replace(/^(["'])(.*)\1$/, '$2');
      if (value) return value;
    }
  }
  return '';
}
function centsToMicro(amount) {
  if (typeof amount !== 'string' || !/^[0-9]{1,15}(\.[0-9]{1,12})?$/.test(amount)) refuse('invalid-cost-report');
  const [whole, fraction = ''] = amount.split('.');
  const padded = fraction.padEnd(4, '0');
  // One cent is 10000 micro-dollars; a finer remainder rounds up (spend is never understated).
  return BigInt(whole) * 10000n + BigInt(padded.slice(0, 4)) + (/[1-9]/.test(padded.slice(4)) ? 1n : 0n);
}
export async function pullSnapshot(env, account, { fetchImpl = globalThis.fetch } = {}) {
  try {
    if (!['A', 'B'].includes(account)) refuse('account-required');
    const config = read(configPathFor(env));
    configs(config);
    if (!own(config.accounts, account)) refuse('account-not-configured');
    const snapshot = read(env.HIMMEL_API_CREDIT_SNAPSHOT || join(stateRoot(), 'snapshot.json'));
    const row = object(snapshot) && object(snapshot.accounts) ? snapshot.accounts[account] : undefined;
    if (!object(row)) refuse('missing-snapshot');
    const grant = money(row.grant_usd);
    if (!Number.isSafeInteger(row.starts_at) || row.starts_at < 0) refuse('invalid-timestamp');
    const key = adminKey(env, account);
    if (!key) refuse('admin-key-missing');
    const startingAt = new Date(row.starts_at * 1000).toISOString().replace('.000Z', 'Z');
    let spent = 0n, page = null, complete = false;
    for (let i = 0; i < 20 && !complete; i++) {
      const url = new URL(COST_REPORT);
      url.searchParams.set('starting_at', startingAt);
      url.searchParams.set('bucket_width', '1d');
      url.searchParams.set('limit', '31');
      if (page) url.searchParams.set('page', page);
      let body, detail = 'network';
      try {
        const res = await fetchImpl(url, { headers: { 'x-api-key': key, 'anthropic-version': '2023-06-01' },
          redirect: 'error', signal: AbortSignal.timeout(15000) });
        if (!res.ok) {
          detail = res.status === 403
            ? 'http-403: the cost report needs an Admin API key, which individual Console accounts do not have'
            : `http-${res.status}`;
          throw new Error('http');
        }
        detail = 'invalid-json';
        body = await res.json();
      } catch { refuse('cost-report-unavailable', 'BANK-UNKNOWN', detail); }
      if (!object(body) || !Array.isArray(body.data)) refuse('invalid-cost-report');
      for (const b of body.data) {
        if (!object(b) || !Array.isArray(b.results)) refuse('invalid-cost-report');
        for (const r of b.results) {
          if (!object(r) || r.currency !== 'USD') refuse('invalid-cost-report');
          spent += centsToMicro(r.amount);
        }
      }
      if (typeof body.has_more !== 'boolean') refuse('invalid-cost-report');
      if (!body.has_more) complete = true;
      else if (typeof body.next_page === 'string' && body.next_page) page = body.next_page;
      else refuse('invalid-cost-report');
    }
    if (!complete) refuse('cost-report-too-long');
    // The row keeps its source: a pull never turns an operator reading into one that goes
    // stale in 600 s and refuses every launch with nothing scheduled to pull again.
    return refreshSnapshot(env, account, { remaining: usd(spent >= grant ? 0n : grant - spent), source: row.source, pulled: true,
      expect: { grant_usd: row.grant_usd, starts_at: row.starts_at, expires_at: row.expires_at, cycle_id: row.cycle_id,
        remaining_usd: row.remaining_usd, observed_at: row.observed_at, reconciled_spent_usd: row.reconciled_spent_usd } });
  } catch (e) {
    return { verdict: e.verdict || 'BANK-UNKNOWN', reason: e.verdict ? e.message : 'state-io-failure', ...(e.detail ? { detail: e.detail } : {}) };
  }
}

function main() {
  const [command, ...args] = process.argv.slice(2);
  if (command === 'pick') {
    const ok = args.length === 2 && args[0] === '--usd';
    console.log(JSON.stringify(ok ? pickAccount(args[1]) : { verdict: 'BANK-UNKNOWN', reason: 'invalid-arguments' }));
    return;
  }
  const options = {};
  for (let i = 0; i < args.length; i += 2) {
    const name = args[i]?.slice(2);
    if (!['--id', '--usd', '--completion'].includes(args[i]) || !args[i + 1] || own(options, name)) {
      console.log(JSON.stringify({ verdict: 'BANK-UNKNOWN', reason: 'invalid-arguments' })); return;
    }
    options[name] = args[i + 1];
  }
  const result = creditState(command, options);
  if (process.env.HIMMEL_API_CREDIT_FORMAT === 'bank') {
    if (result.account && result.grant_usd) {
      console.error(`api:${result.account} grant-cycle=${result.cycle_id} grant=${result.grant_usd} spent-est=${result.spent_est_usd} reserved=${result.reserved_usd} available-est=${result.available_est_usd} expires=${new Date(result.expires_at * 1000).toISOString()} age=${result.age_seconds} source=${result.source}${result.snapshot_stale ? ' stale-snapshot (older than 24 h: auto routing goes on our own estimate and the credit answer from the API is the hard stop)' : ''}`);
    } else console.error(`api credit-state: ${result.reason}`);
    console.log(result.verdict);
  } else console.log(JSON.stringify(result));
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) main();
