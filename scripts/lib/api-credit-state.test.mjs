// secret-free accounting fixtures. No provider calls or credentials.
// Breaks caught: fallback to another account/bank, duplicate spend, automatic
// rollover, stale evidence admission, rounding and concurrent over-reservation.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const SUT = join(HERE, 'api-credit-state.mjs');
const BANK = join(HERE, 'usage-preflight.sh');
const T = mkdtempSync(join(tmpdir(), 'api-credit-'));
process.on('exit', () => rmSync(T, { recursive: true, force: true }));
// a reset far in the future, so the fixtures' relative grant dates never meet the real reset date
const FAR_RESET = '2099-01-01T00:00:00Z';

function fixture() {
  const dir = mkdtempSync(join(T, 'case-'));
  const now = Math.floor(Date.now() / 1000);
  const config = { version: 1, accounts: {
    A: { organization_id: 'org-a', cycle_id: 'cycle-a', cap_usd: '1.00', reset_at: FAR_RESET },
    B: { organization_id: 'org-b', cycle_id: 'cycle-b', cap_usd: '2.00', reset_at: FAR_RESET },
  } };
  const snapshot = { version: 1, accounts: Object.fromEntries(['A', 'B'].map((account) => [account, {
    organization_id: config.accounts[account].organization_id,
    cycle_id: config.accounts[account].cycle_id,
    grant_usd: '2.00', remaining_usd: '2.00', reconciled_spent_usd: '0',
    starts_at: now - 1000, expires_at: now + 3600, observed_at: now,
    source: 'operator-console-snapshot', exclusive_org: true, discrepancy: false,
  }])) };
  const paths = { config: join(dir, 'config.json'), snapshot: join(dir, 'snapshot.json'), state: join(dir, 'ledger.json') };
  config.ledger_path = paths.state;
  const save = () => {
    writeFileSync(paths.config, JSON.stringify(config));
    writeFileSync(paths.snapshot, JSON.stringify(snapshot));
  };
  save();
  const env = { PATH: process.env.PATH, HOME: dir, TMPDIR: dir,
    HIMMEL_API_CREDIT_CONFIG: paths.config, HIMMEL_API_CREDIT_SNAPSHOT: paths.snapshot,
    HIMMEL_API_CREDIT_STATE: paths.state, HIMMEL_API_ACCOUNT: 'A' };
  const args = (command, extra = []) => [SUT, command, ...extra];
  const call = (command = 'status', extra = []) => {
    const r = spawnSync(process.execPath, args(command, extra), { env, encoding: 'utf8' });
    assert.equal(r.status, 0, r.stderr);
    return JSON.parse(r.stdout);
  };
  return { dir, now, config, snapshot, paths, save, env, args, call };
}

// First RED: current bank gate ignores api and falls through to native evidence.
test('API dispatch is OFF even when no native evidence exists', () => {
  const f = fixture();
  writeFileSync(join(f.dir, 'ps'), '#!/bin/bash\nexit 0\n', { mode: 0o700 });
  const r = spawnSync('bash', [BANK], { encoding: 'utf8', env: {
    ...f.env, HIMMEL_FLEET_CAP: '4', HIMMEL_FLEET_SLOTS: join(f.dir, 'slots'),
    FLEET_PS_CMD: join(f.dir, 'ps'), FLEET_PROC: f.dir, CADENCE_BANK_LANE: 'api',
    CADENCE_BANK_LEDGER: join(f.dir, 'bank-ledger'), CADENCE_BANK_LAUNCH: '1',
    CADENCE_BANK_LEG: 'HIMMEL-test-api', CADENCE_BANK_SKIP_REFRESH: '1',
    CADENCE_BANK_CACHE: join(f.dir, 'no-native-cache'),
  } });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout.trim(), 'SKIPPED-BANK');
  assert.match(r.stderr, /api.*dispatch.*OFF/);
});

function bankApi(f, extra = {}) {
  writeFileSync(join(f.dir, 'ps'), '#!/bin/bash\nexit 0\n', { mode: 0o700 });
  return spawnSync('bash', [BANK], { encoding: 'utf8', env: {
    ...f.env, HIMMEL_FLEET_CAP: '4', HIMMEL_FLEET_SLOTS: join(f.dir, 'slots'),
    FLEET_PS_CMD: join(f.dir, 'ps'), FLEET_PROC: f.dir, CADENCE_BANK_LANE: 'api',
    CADENCE_BANK_LEDGER: join(f.dir, 'bank-ledger'), CADENCE_BANK_LAUNCH: '1',
    CADENCE_BANK_LEG: 'HIMMEL-test-api', CADENCE_BANK_SKIP_REFRESH: '1',
    CADENCE_BANK_CACHE: join(f.dir, 'no-native-cache'), ...extra,
  } });
}

// the launcher opts in with HIMMEL_API_LANE=on; the native bank is irrelevant.
test('opted-in API launch with a funded account proceeds while the native bank is exhausted', () => {
  const f = fixture();
  writeFileSync(join(f.dir, 'native-cache.json'), JSON.stringify({ five_hour: { utilization: 100 }, seven_day: { utilization: 100 } }));
  const r = bankApi(f, { HIMMEL_API_LANE: 'on', CADENCE_BANK_CACHE: join(f.dir, 'native-cache.json') });
  assert.equal(r.stdout.trim(), 'PROCEED', r.stderr);
});

test('opted-in API launch with an empty account refuses although native is funded', () => {
  const f = fixture();
  f.snapshot.accounts.A.remaining_usd = '0';
  f.save();
  writeFileSync(join(f.dir, 'native-cache.json'), JSON.stringify({ five_hour: { utilization: 1 }, seven_day: { utilization: 1 } }));
  const r = bankApi(f, { HIMMEL_API_LANE: 'on', CADENCE_BANK_CACHE: join(f.dir, 'native-cache.json') });
  assert.equal(r.stdout.trim(), 'SKIPPED-BANK', r.stderr);
});

test('funded account reports precise estimated headroom without writing spend', () => {
  const f = fixture();
  const row = f.call();
  assert.equal(row.verdict, 'PROCEED');
  assert.equal(row.account, 'A');
  assert.equal(row.available_est_usd, '1.000000');
  assert.equal(row.grant_usd, '2.000000');
  assert.equal(row.reserved_usd, '0.000000');
  assert.equal(row.spent_est_usd, '0.000000');
  assert.equal(row.source, 'operator-console-snapshot');
});

const invalid = [
  ['missing account snapshot', (f) => delete f.snapshot.accounts.A, 'BANK-UNKNOWN'],
  ['stale automatic observation', (f) => { f.snapshot.accounts.A.source = 'automatic-snapshot'; f.snapshot.accounts.A.observed_at = f.now - 601; }, 'BANK-STALE'],
  ['expired grant', (f) => { f.snapshot.accounts.A.expires_at = f.now - 1; }, 'SKIPPED-BANK'],
  ['future observation', (f) => { f.snapshot.accounts.A.observed_at = f.now + 60; }, 'BANK-STALE'],
  ['future grant', (f) => { f.snapshot.accounts.A.starts_at = f.now + 60; }, 'BANK-UNKNOWN'],
  ['wrong cycle', (f) => { f.snapshot.accounts.A.cycle_id = 'other'; }, 'BANK-UNKNOWN'],
  ['wrong org', (f) => { f.snapshot.accounts.A.organization_id = 'other'; }, 'BANK-UNKNOWN'],
  ['shared org configured twice', (f) => { f.config.accounts.B.organization_id = 'org-a'; }, 'BANK-UNKNOWN'],
  ['uncontrolled outside consumers', (f) => { f.snapshot.accounts.A.exclusive_org = false; }, 'BANK-UNKNOWN'],
  ['snapshot discrepancy', (f) => { f.snapshot.accounts.A.discrepancy = true; }, 'BANK-UNKNOWN'],
  ['unknown provenance', (f) => { f.snapshot.accounts.A.source = 'guess'; }, 'BANK-UNKNOWN'],
  ['exhausted A does not borrow funded B', (f) => { f.snapshot.accounts.A.remaining_usd = '0'; }, 'SKIPPED-BANK'],
  ['cap does not exceed verified grant', (f) => { f.config.accounts.A.cap_usd = '3'; }, 'BANK-UNKNOWN'],
  ['invalid cap', (f) => { f.config.accounts.A.cap_usd = 'unlimited'; }, 'BANK-UNKNOWN'],
  ['numeric money rejected', (f) => { f.config.accounts.A.cap_usd = 1; }, 'BANK-UNKNOWN'],
  ['submicro precision rejected', (f) => { f.config.accounts.A.cap_usd = '0.0000001'; }, 'BANK-UNKNOWN'],
  ['negative balance rejected', (f) => { f.snapshot.accounts.A.remaining_usd = '-1'; }, 'BANK-UNKNOWN'],
  ['remaining greater than grant', (f) => { f.snapshot.accounts.A.remaining_usd = '3'; }, 'BANK-UNKNOWN'],
  ['fractional timestamp rejected', (f) => { f.snapshot.accounts.A.observed_at += 0.5; }, 'BANK-UNKNOWN'],
  ['timestamp string rejected', (f) => { f.snapshot.accounts.A.observed_at = String(f.now); }, 'BANK-UNKNOWN'],
  ['invalid interval rejected', (f) => { f.snapshot.accounts.A.starts_at = f.snapshot.accounts.A.expires_at; }, 'BANK-UNKNOWN'],
  ['unrecognized account refused', (f) => { f.env.HIMMEL_API_ACCOUNT = 'C'; }, 'BANK-UNKNOWN'],
  ['account must be explicit', (f) => { delete f.env.HIMMEL_API_ACCOUNT; }, 'BANK-UNKNOWN'],
];
for (const [name, change, verdict] of invalid) {
  test(name, () => {
    const f = fixture(); change(f); f.save();
    assert.equal(f.call().verdict, verdict);
    assert.equal(f.call('reserve', ['--id', 'job', '--usd', '0.01']).verdict, verdict);
  });
}

for (const name of ['config', 'snapshot']) {
  test(`missing ${name} refuses`, () => {
    const f = fixture(); rmSync(f.paths[name]);
    assert.equal(f.call().verdict, 'BANK-UNKNOWN');
  });
  test(`malformed ${name} refuses`, () => {
    const f = fixture(); writeFileSync(f.paths[name], '{');
    assert.equal(f.call().verdict, 'BANK-UNKNOWN');
  });
}

test('reservations isolated by A/B account and no subscription bank consulted', () => {
  const f = fixture();
  assert.equal(f.call('reserve', ['--id', 'job', '--usd', '0.70']).verdict, 'PROCEED');
  assert.equal(f.call().available_est_usd, '0.300000');
  f.env.HIMMEL_API_ACCOUNT = 'B';
  assert.equal(f.call().available_est_usd, '2.000000');
  assert.equal(f.call('reserve', ['--id', 'job', '--usd', '1.50']).verdict, 'PROCEED');
  assert.equal(f.call().available_est_usd, '0.500000');
  f.env.HIMMEL_API_ACCOUNT = 'A';
  assert.equal(f.call().available_est_usd, '0.300000');
});

test('committed reservation outcome survives snapshot freshness boundary during save', async (t) => {
  const f = fixture();
  const { creditState } = await import('./api-credit-state.mjs');
  let calls = 0;
  t.mock.method(Date, 'now', () => (calls++ === 0 ? f.now : f.now + 601) * 1000);
  const result = creditState('reserve', { id: 'job', usd: '0.40' }, f.env);
  assert.equal(result.verdict, 'PROCEED');
  assert.equal(result.job_id, 'job');
  assert.equal(result.reserved_usd, '0.400000');
  assert.equal(result.available_est_usd, '0.600000');
  assert.equal(JSON.parse(readFileSync(f.paths.state)).accounts.A.jobs.job.status, 'reserved');
});

test('duplicate reservation never overwrites or re-admits a job', () => {
  const f = fixture();
  f.call('reserve', ['--id', 'job', '--usd', '0.40']);
  assert.equal(f.call('reserve', ['--id', 'job', '--usd', '0.10']).verdict, 'BANK-UNKNOWN');
  assert.equal(f.call().reserved_usd, '0.400000');
});

test('reservation maximum rejects zero, unknown prices and unsafe job IDs', () => {
  const f = fixture();
  for (const amount of ['0', 'unknown', '1e-2', '0.0000001', '-1']) {
    assert.equal(f.call('reserve', ['--id', 'job', '--usd', amount]).verdict, 'BANK-UNKNOWN');
  }
  assert.equal(f.call('reserve', ['--id', '../job', '--usd', '0.01']).verdict, 'BANK-UNKNOWN');
  assert.equal(f.call().reserved_usd, '0.000000');
});

test('unknown completion retains full reservation across new processes', () => {
  const f = fixture();
  f.call('reserve', ['--id', 'job', '--usd', '1']);
  assert.equal(f.call('unknown', ['--id', 'job']).verdict, 'PROCEED');
  assert.equal(f.call().reserved_usd, '1.000000');
  assert.equal(f.call('reserve', ['--id', 'next', '--usd', '0.000001']).verdict, 'SKIPPED-BANK');
});

test('settlement requires verified terminal completion and reconciles only unused maximum', () => {
  const f = fixture();
  f.call('reserve', ['--id', 'job', '--usd', '0.80']);
  assert.equal(f.call('settle', ['--id', 'job', '--usd', '0.25']).verdict, 'BANK-UNKNOWN');
  assert.equal(f.call().reserved_usd, '0.800000');
  assert.equal(f.call('settle', ['--id', 'job', '--usd', '0.25', '--completion', 'verified']).verdict, 'PROCEED');
  assert.equal(f.call().spent_est_usd, '0.250000');
  assert.equal(f.call().available_est_usd, '0.750000');
  assert.equal(f.call('settle', ['--id', 'job', '--usd', '0', '--completion', 'verified']).verdict, 'BANK-UNKNOWN');
  assert.equal(f.call().spent_est_usd, '0.250000');
});

test('late completion can reconcile after snapshot expiry without admitting new work', () => {
  const f = fixture();
  f.call('reserve', ['--id', 'job', '--usd', '0.80']);
  f.snapshot.accounts.A.expires_at = f.now - 1; f.save();
  assert.equal(f.call('settle', ['--id', 'job', '--usd', '0.25', '--completion', 'verified']).verdict, 'PROCEED');
  assert.equal(f.call().verdict, 'SKIPPED-BANK');
});

test('overspent completion records discrepancy and blocks further admission', () => {
  const f = fixture();
  f.call('reserve', ['--id', 'job', '--usd', '0.10']);
  assert.equal(f.call('settle', ['--id', 'job', '--usd', '0.11', '--completion', 'verified']).verdict, 'BANK-UNKNOWN');
  assert.equal(f.call().verdict, 'BANK-UNKNOWN');
  assert.equal(JSON.parse(readFileSync(f.paths.state)).accounts.A.jobs.job.actual_usd, '0.110000');
});

test('outside consumption lowers headroom without double-counting reported local spend', () => {
  const f = fixture();
  f.call('reserve', ['--id', 'job', '--usd', '0.50']);
  f.call('settle', ['--id', 'job', '--usd', '0.20', '--completion', 'verified']);
  f.snapshot.accounts.A.remaining_usd = '1.50';
  f.snapshot.accounts.A.reconciled_spent_usd = '0.20'; f.save();
  assert.equal(f.call().spent_est_usd, '0.500000');
  assert.equal(f.call().available_est_usd, '0.500000');
  f.snapshot.accounts.A.reconciled_spent_usd = '0.21'; f.save();
  assert.equal(f.call().verdict, 'BANK-UNKNOWN');
});

test('microdollar arithmetic refuses a one-microdollar overrun without cent rounding', () => {
  const f = fixture(); f.config.accounts.A.cap_usd = '0.010001'; f.save();
  f.call('reserve', ['--id', 'one', '--usd', '0.01']);
  assert.equal(f.call('reserve', ['--id', 'two', '--usd', '0.000002']).verdict, 'SKIPPED-BANK');
  assert.equal(f.call('reserve', ['--id', 'three', '--usd', '0.000001']).verdict, 'PROCEED');
  assert.equal(f.call().available_est_usd, '0.000000');
});

test('calendar rollover does not refill a cycle or abandon unknown reservations', () => {
  const f = fixture(); f.call('reserve', ['--id', 'job', '--usd', '1']);
  assert.equal(f.call().available_est_usd, '0.000000');
  f.config.accounts.A.cycle_id = 'next-month'; f.snapshot.accounts.A.cycle_id = 'next-month'; f.save();
  assert.equal(f.call().verdict, 'BANK-UNKNOWN');
  assert.equal(f.call('reserve', ['--id', 'new', '--usd', '0.01']).verdict, 'BANK-UNKNOWN');
});

test('corrupt existing ledger is not replaced with fresh empty spend', () => {
  const f = fixture(); writeFileSync(f.paths.state, '{');
  assert.equal(f.call('reserve', ['--id', 'job', '--usd', '1']).verdict, 'BANK-UNKNOWN');
  assert.equal(readFileSync(f.paths.state, 'utf8'), '{');
});

test('symlinked ledger alias cannot use a different lock for the same spend', () => {
  const f = fixture(); f.call('reserve', ['--id', 'job', '--usd', '0.50']);
  const alias = join(f.dir, 'alias.json'); symlinkSync(f.paths.state, alias);
  f.env.HIMMEL_API_CREDIT_STATE = alias;
  assert.equal(f.call('reserve', ['--id', 'new', '--usd', '0.50']).verdict, 'BANK-UNKNOWN');
  f.env.HIMMEL_API_CREDIT_STATE = f.paths.state;
  assert.equal(f.call().reserved_usd, '0.500000');
});

test('deleted initialized ledger cannot erase already reserved credit', () => {
  const f = fixture(); f.call('reserve', ['--id', 'job', '--usd', '1']);
  rmSync(f.paths.state);
  assert.equal(f.call('reserve', ['--id', 'new', '--usd', '1']).verdict, 'BANK-UNKNOWN');
});

test('deleting both the ledger and its adjacent sentinel still refuses', () => {
  const f = fixture(); f.call('reserve', ['--id', 'job', '--usd', '1']);
  rmSync(f.paths.state); rmSync(`${f.paths.state}.initialized`);
  assert.equal(f.call('reserve', ['--id', 'new', '--usd', '1']).verdict, 'BANK-UNKNOWN');
  assert.equal(f.call().reason, 'missing-initialized-ledger');
});

test('ledger path is pinned by the config: env override or HOME cannot select another ledger', () => {
  const f = fixture(); f.call('reserve', ['--id', 'job', '--usd', '1']);
  f.env.HIMMEL_API_CREDIT_STATE = join(f.dir, 'other-ledger.json');
  assert.equal(f.call().reason, 'ledger-path-mismatch');
  delete f.env.HIMMEL_API_CREDIT_STATE; f.env.HOME = join(f.dir, 'elsewhere');
  assert.equal(f.call().reserved_usd, '1.000000');
  delete f.config.ledger_path; f.save();
  assert.equal(f.call().reason, 'ledger-path-required');
});

test('zero-cost verified completion releases unknown reservation without grant refill', () => {
  const f = fixture(); f.call('reserve', ['--id', 'job', '--usd', '1']);
  f.call('unknown', ['--id', 'job']);
  assert.equal(f.call('settle', ['--id', 'job', '--usd', '0', '--completion', 'verified']).verdict, 'PROCEED');
  assert.equal(f.call().available_est_usd, '1.000000');
  assert.equal(f.call('reserve', ['--id', 'job', '--usd', '1']).verdict, 'BANK-UNKNOWN');
});

test('corrupt job record cannot silently disappear from totals', () => {
  const f = fixture(); f.call('reserve', ['--id', 'job', '--usd', '1']);
  const state = JSON.parse(readFileSync(f.paths.state));
  state.accounts.A.jobs.job.status = 'lost';
  writeFileSync(f.paths.state, JSON.stringify(state));
  assert.equal(f.call().verdict, 'BANK-UNKNOWN');
});

test('orphan or busy transaction lock fails closed without reclamation', () => {
  const f = fixture(); mkdirSync(`${f.paths.state}.lock`); f.env.HIMMEL_API_LOCK_WAIT_MS = '100';
  assert.equal(f.call('reserve', ['--id', 'job', '--usd', '1']).verdict, 'BANK-UNKNOWN');
});

test('simultaneous last-dollar reservations can admit exactly one at most', async () => {
  const f = fixture();
  const run = (id) => new Promise((resolve, reject) => {
    const p = spawn(process.execPath, f.args('reserve', ['--id', id, '--usd', '1']), { env: f.env });
    let out = ''; p.stdout.on('data', (b) => { out += b; }); p.on('error', reject);
    p.on('close', (code) => { if (code !== 0) reject(new Error(`child ${code}`)); else resolve(JSON.parse(out)); });
  });
  const results = await Promise.all([run('one'), run('two')]);
  assert.equal(results.filter((r) => r.verdict === 'PROCEED').length, 1);
  assert.equal(f.call().reserved_usd, '1.000000');
  assert.equal(f.call().available_est_usd, '0.000000');
});

test('bank read prints API row and does not use native producer', () => {
  const f = fixture();
  writeFileSync(join(f.dir, 'ps'), '#!/bin/bash\nexit 0\n', { mode: 0o700 });
  const r = spawnSync('bash', [BANK], { encoding: 'utf8', env: {
    ...f.env, HIMMEL_FLEET_CAP: '4', HIMMEL_FLEET_SLOTS: join(f.dir, 'slots'),
    FLEET_PS_CMD: join(f.dir, 'ps'), FLEET_PROC: f.dir, CADENCE_BANK_LANE: 'api',
    CADENCE_BANK_LEDGER: join(f.dir, 'bank-ledger'), CADENCE_BANK_SKIP_REFRESH: '1',
    CADENCE_BANK_PRODUCER: join(f.dir, 'must-not-run'),
  } });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout.trim(), 'PROCEED');
  assert.match(r.stderr, /api:A.*grant-cycle=cycle-a.*available-est=1\.000000/);
});

// the operator's reading carries no freshness window; the cap and the
// reserve accounting are the overspend guard, so a two-hour-old reading still admits.
test('an operator snapshot two hours old still admits within the cap', () => {
  const f = fixture();
  f.snapshot.accounts.A.starts_at = f.now - 100000;
  f.snapshot.accounts.A.observed_at = f.now - 7200;
  f.save();
  assert.equal(f.call().verdict, 'PROCEED');
  assert.equal(f.call('reserve', ['--id', 'old', '--usd', '0.50']).verdict, 'PROCEED');
  assert.equal(f.call().available_est_usd, '0.500000');
});

test('a stale operator reading still derives remaining credit from the ledger and refuses at zero', () => {
  const f = fixture();
  f.snapshot.accounts.A.starts_at = f.now - 200000;
  f.snapshot.accounts.A.observed_at = f.now - 86400;
  f.save();
  assert.equal(f.call('reserve', ['--id', 'a', '--usd', '1.00']).verdict, 'PROCEED');
  const over = f.call('reserve', ['--id', 'b', '--usd', '0.01']);
  assert.equal(over.verdict, 'SKIPPED-BANK');
  assert.equal(over.reason, 'insufficient-headroom');
});

test('twenty parallel reserves all succeed under the cap and the next one over it refuses', async () => {
  const f = fixture();
  f.config.accounts.A.cap_usd = '0.20';
  f.save();
  const run = (id) => new Promise((resolve, reject) => {
    const p = spawn(process.execPath, f.args('reserve', ['--id', id, '--usd', '0.01']), { env: f.env });
    let out = ''; p.stdout.on('data', (b) => { out += b; }); p.on('error', reject);
    p.on('close', (code) => { if (code !== 0) reject(new Error(`child ${code}`)); else resolve(JSON.parse(out)); });
  });
  const results = await Promise.all(Array.from({ length: 20 }, (_, i) => run(`p${i}`)));
  assert.deepEqual(results.map((r) => r.verdict), Array(20).fill('PROCEED'), JSON.stringify(results));
  const over = f.call('reserve', ['--id', 'p20', '--usd', '0.01']);
  assert.equal(over.verdict, 'SKIPPED-BANK');
  assert.equal(over.reason, 'insufficient-headroom');
  assert.equal(f.call().reserved_usd, '0.200000');
});

// an API call is not a subscription session; it takes its own slots.
test('an API launch does not move the subscription FLEET count and has its own cap', () => {
  const f = fixture();
  const launch = (job) => bankApi(f, {
    HIMMEL_API_LANE: 'on', HIMMEL_FLEET_CAP: '1', HIMMEL_API_MAX_CONCURRENT: '2',
    CADENCE_BANK_LEG: `claude-api:${job}`, CADENCE_BANK_CALLER_PID: String(process.pid),
  });
  const one = launch('j1');
  assert.equal(one.stdout.trim(), 'PROCEED', one.stderr);
  assert.match(one.stderr, /FLEET native=0 claudex=0 openrouter=0 reserved=0 total=0\/1/);
  const two = launch('j2');
  assert.equal(two.stdout.trim(), 'PROCEED', two.stderr);
  assert.match(two.stderr, /FLEET native=0 claudex=0 openrouter=0 reserved=0 total=0\/1/);
  const three = launch('j3');
  assert.equal(three.stdout.trim(), 'SKIPPED-FLEET', three.stderr);
  assert.match(three.stderr, /api lane at\/over its own cap \(2\/2\)/);
});

// automatic snapshot from the Admin API cost report. HTTP is stubbed;
// the key is a fixture string. Endpoint and fields per the Admin API cost_report docs:
// GET /v1/organizations/cost_report, x-api-key, amounts in cents as decimal strings.
const FIXTURE_KEY = 'fixture-admin-key-not-real';
function costStub(pages, seen = []) {
  let i = 0;
  const fn = async (url, init) => {
    seen.push({ url: String(url), headers: init.headers });
    const body = pages[Math.min(i++, pages.length - 1)];
    return { ok: body !== null, status: body === null ? 401 : 200, json: async () => body };
  };
  return fn;
}
const bucket = (...cents) => ({ starting_at: '2026-10-01T00:00:00Z', ending_at: '2026-10-02T00:00:00Z',
  results: cents.map((amount) => ({ amount, currency: 'USD', description: null })) });

test('pull derives remaining from cost-report spend since the grant start, across pages', async () => {
  const f = fixture();
  const { pullSnapshot } = await import('./api-credit-state.mjs');
  const seen = [];
  const env = { ...f.env, ANTHROPIC_ORG_A_KEY: FIXTURE_KEY };
  const r = await pullSnapshot(env, 'A', { fetchImpl: costStub([
    { data: [bucket('50', '25.5')], has_more: true, next_page: 'page_2' },
    { data: [bucket('4.5')], has_more: false, next_page: null },
  ], seen) });
  assert.equal(r.verdict, 'PROCEED', JSON.stringify(r));
  assert.equal(r.remaining_usd, '1.200000');
  const row = JSON.parse(readFileSync(f.paths.snapshot)).accounts.A;
  // A pull keeps the row's source, so the operator reading stays the fallback past 600 s.
  assert.equal(row.source, 'operator-console-snapshot');
  assert.equal(row.pulled_at, row.observed_at);
  assert.equal(row.remaining_usd, '1.200000');
  assert.equal(seen.length, 2);
  const first = new URL(seen[0].url);
  assert.equal(first.origin + first.pathname, 'https://api.anthropic.com/v1/organizations/cost_report');
  assert.equal(first.searchParams.get('starting_at'), new Date((f.now - 1000) * 1000).toISOString().replace('.000Z', 'Z'));
  assert.equal(new URL(seen[1].url).searchParams.get('page'), 'page_2');
  assert.equal(seen[0].headers['x-api-key'], FIXTURE_KEY);
  assert.equal(JSON.stringify(r).includes(FIXTURE_KEY), false);
  assert.equal(f.call().verdict, 'PROCEED');
});

test('pull reads the key from a dotenv file, and spend over the grant leaves nothing', async () => {
  const f = fixture();
  const { pullSnapshot } = await import('./api-credit-state.mjs');
  const dotenv = join(f.dir, 'dotenv');
  writeFileSync(dotenv, `OTHER=1\nANTHROPIC_ORG_A_KEY="${FIXTURE_KEY}"\n`);
  const seen = [];
  const r = await pullSnapshot({ ...f.env, HIMMEL_DOTENV_FILE: dotenv }, 'A', {
    fetchImpl: costStub([{ data: [bucket('20000')], has_more: false, next_page: null }], seen) });
  assert.equal(r.verdict, 'PROCEED', JSON.stringify(r));
  assert.equal(seen[0].headers['x-api-key'], FIXTURE_KEY);
  assert.equal(r.remaining_usd, '0.000000');
  assert.equal(f.call().verdict, 'SKIPPED-BANK');
});

test('HIMMEL-7264: a failed pull names the HTTP status or the network failure, never the key', async () => {
  const f = fixture();
  const { pullSnapshot } = await import('./api-credit-state.mjs');
  const env = { ...f.env, ANTHROPIC_ORG_A_KEY: FIXTURE_KEY };
  const denied = await pullSnapshot(env, 'A', { fetchImpl: costStub([null]) });
  assert.equal(denied.reason, 'cost-report-unavailable');
  assert.equal(denied.detail, 'http-401');
  const forbidden = await pullSnapshot(env, 'A', { fetchImpl: async () => ({ ok: false, status: 403, json: async () => ({}) }) });
  assert.match(forbidden.detail, /^http-403: .*Admin API key.*individual Console accounts/);
  const down = await pullSnapshot(env, 'A', { fetchImpl: async () => { throw new Error(`boom ${FIXTURE_KEY}`); } });
  assert.equal(down.reason, 'cost-report-unavailable');
  assert.equal(down.detail, 'network');
  assert.equal(JSON.stringify([denied, forbidden, down]).includes(FIXTURE_KEY), false);
});

test('pull failures leave the snapshot untouched and never echo the key', async () => {
  const f = fixture();
  const { pullSnapshot } = await import('./api-credit-state.mjs');
  const before = readFileSync(f.paths.snapshot, 'utf8');
  const env = { ...f.env, ANTHROPIC_ORG_A_KEY: FIXTURE_KEY };
  const unauthorized = await pullSnapshot(env, 'A', { fetchImpl: costStub([null]) });
  assert.equal(unauthorized.verdict, 'BANK-UNKNOWN');
  assert.equal(unauthorized.reason, 'cost-report-unavailable');
  const thrown = await pullSnapshot(env, 'A', { fetchImpl: async () => { throw new Error(`boom ${FIXTURE_KEY}`); } });
  assert.equal(thrown.reason, 'cost-report-unavailable');
  assert.equal(JSON.stringify(thrown).includes(FIXTURE_KEY), false);
  const nokey = await pullSnapshot({ ...f.env, HIMMEL_DOTENV_FILE: join(f.dir, 'absent') }, 'A', { fetchImpl: costStub([]) });
  assert.equal(nokey.reason, 'admin-key-missing');
  const bad = await pullSnapshot(env, 'A', { fetchImpl: costStub([{ data: [{ results: [{ amount: 'x', currency: 'USD' }] }], has_more: false }]) });
  assert.equal(bad.verdict, 'BANK-UNKNOWN');
  const noFlag = await pullSnapshot(env, 'A', { fetchImpl: costStub([{ data: [bucket('10')] }]) });
  assert.equal(noFlag.reason, 'invalid-cost-report');
  assert.equal(readFileSync(f.paths.snapshot, 'utf8'), before);
  const seenInit = [];
  await pullSnapshot(env, 'A', { fetchImpl: async (u, init) => { seenInit.push(init); return { ok: true, json: async () => ({ data: [], has_more: false }) }; } });
  assert.equal(seenInit[0].redirect, 'error');
});

test('a pull that reports more credit than the row holds keeps the smaller figure', async () => {
  const f = fixture();
  f.snapshot.accounts.A.remaining_usd = '1.00'; f.save();
  const { pullSnapshot } = await import('./api-credit-state.mjs');
  const env = { ...f.env, ANTHROPIC_ORG_A_KEY: FIXTURE_KEY };
  // 2.00 grant less 0.50 reported spend would read 1.50, above the row's 1.00.
  const r = await pullSnapshot(env, 'A', { fetchImpl: costStub([{ data: [bucket('50')], has_more: false, next_page: null }]) });
  assert.equal(r.remaining_usd, '1.000000', JSON.stringify(r));
  assert.equal(JSON.parse(readFileSync(f.paths.snapshot)).accounts.A.remaining_usd, '1.000000');
});

test('a reading or watermark that lands while the pull is in flight refuses the pull', async () => {
  const f = fixture();
  const { pullSnapshot } = await import('./api-credit-state.mjs');
  const env = { ...f.env, ANTHROPIC_ORG_A_KEY: FIXTURE_KEY };
  const fetchImpl = async () => {
    f.snapshot.accounts.A.remaining_usd = '1.50'; f.save();
    return { ok: true, status: 200, json: async () => ({ data: [bucket('10')], has_more: false, next_page: null }) };
  };
  const r = await pullSnapshot(env, 'A', { fetchImpl });
  assert.equal(r.verdict, 'BANK-UNKNOWN');
  assert.equal(r.reason, 'grant-changed');
  assert.equal(JSON.parse(readFileSync(f.paths.snapshot)).accounts.A.remaining_usd, '1.50');
});

test('an empty HIMMEL_API_LOCK_WAIT_MS falls back to the default wait', () => {
  const f = fixture(); f.env.HIMMEL_API_LOCK_WAIT_MS = '';
  const lock = `${f.paths.state}.lock`; mkdirSync(lock);
  // Free the lock after 300 ms: a zero wait would refuse at once, the default retries past it.
  const releaser = spawn('sh', ['-c', `sleep 0.3; rmdir '${lock}'`]);
  const r = f.call('reserve', ['--id', 'job', '--usd', '1']);
  releaser.kill();
  assert.equal(r.verdict, 'PROCEED', JSON.stringify(r));
});

// operator decision 185 resets both grants on one date, whatever expiry a snapshot row carries.
const iso = (t) => new Date(t * 1000).toISOString().replace('.000Z', 'Z');

test('HIMMEL-7111: the default reset date of both grants is 2026-11-01T00:00:00Z', async () => {
  const { GRANT_RESET_AT } = await import(SUT);
  assert.deepEqual(GRANT_RESET_AT, { A: '2026-11-01T00:00:00Z', B: '2026-11-01T00:00:00Z' });
});

test('HIMMEL-7111: the reset date caps a later expiry on the snapshot row', () => {
  const f = fixture();
  f.snapshot.accounts.A.expires_at = f.now + 9 * 86400;
  f.config.accounts.A.reset_at = iso(f.now + 1800);
  f.save();
  assert.equal(f.call().expires_at, f.now + 1800);
});

test('HIMMEL-7111: auto routing ranks by the reset date, a tie going to A', () => {
  const f = fixture();
  f.snapshot.accounts.A.expires_at = f.now + 9 * 86400;
  f.snapshot.accounts.B.expires_at = f.now + 5 * 86400;
  f.config.accounts.A.reset_at = iso(f.now + 3600);
  f.config.accounts.B.reset_at = iso(f.now + 3600);
  f.save();
  const pick = JSON.parse(spawnSync(process.execPath, [SUT, 'pick', '--usd', '0.01'], { env: f.env, encoding: 'utf8' }).stdout);
  assert.equal(pick.account, 'A');
});

test('HIMMEL-7111: after the reset date the old grant refuses, and a grant starting on it is a fresh cycle', () => {
  const f = fixture();
  f.snapshot.accounts.A.starts_at = f.now - 7200;
  f.snapshot.accounts.A.expires_at = f.now + 9 * 86400;
  f.config.accounts.A.reset_at = iso(f.now - 3600);
  f.save();
  const old = f.call();
  assert.equal(old.verdict, 'SKIPPED-BANK');
  assert.equal(old.reason, 'expired-grant');
  f.snapshot.accounts.A.starts_at = f.now - 1800;
  f.save();
  assert.equal(f.call().verdict, 'PROCEED');
});

test('HIMMEL-7111: a malformed reset_at refuses', () => {
  const f = fixture();
  f.config.accounts.A.reset_at = '2026-11-01';
  f.save();
  assert.equal(f.call().verdict, 'BANK-UNKNOWN');
});

function ageJob(f, id, ageSeconds) {
  const ledger = JSON.parse(readFileSync(f.paths.state, 'utf8'));
  const job = ledger.accounts.A.jobs[id];
  if (ageSeconds === null) delete job.reserved_at; else job.reserved_at = f.now - ageSeconds;
  writeFileSync(f.paths.state, JSON.stringify(ledger));
}

test('HIMMEL-7111: a reservation older than the call timeout is released, a younger one is kept', () => {
  const f = fixture(); f.env.HIMMEL_API_CALL_TIMEOUT_S = '3600';
  f.call('reserve', ['--id', 'dead', '--usd', '0.30']);
  f.call('reserve', ['--id', 'live', '--usd', '0.20']);
  ageJob(f, 'dead', 7200); ageJob(f, 'live', 60);
  const row = f.call();
  assert.equal(row.reserved_usd, '0.200000');
  assert.equal(row.available_est_usd, '0.800000');
  assert.equal(f.call('reserve', ['--id', 'dead', '--usd', '0.01']).reason, 'duplicate-job');
});

test('HIMMEL-7111: a reservation is swept on the timeout it was made with, not the status caller\'s', () => {
  const f = fixture(); f.env.HIMMEL_API_CALL_TIMEOUT_S = '7200';
  f.call('reserve', ['--id', 'long', '--usd', '0.30']);
  ageJob(f, 'long', 5000);
  f.env.HIMMEL_API_CALL_TIMEOUT_S = '3600';
  assert.equal(f.call().reserved_usd, '0.300000');
  ageJob(f, 'long', 8000);
  assert.equal(f.call().reserved_usd, '0.000000');
});

test('HIMMEL-7111: a reservation is kept through the launcher\'s five-second kill grace after its timeout', () => {
  const f = fixture(); f.env.HIMMEL_API_CALL_TIMEOUT_S = '3600';
  f.call('reserve', ['--id', 'stopping', '--usd', '0.30']);
  ageJob(f, 'stopping', 3603);
  assert.equal(f.call().reserved_usd, '0.300000');
  ageJob(f, 'stopping', 3606);
  assert.equal(f.call().reserved_usd, '0.000000');
});

test('HIMMEL-7111: an unknown or pre-timestamp reservation is released once past the timeout', () => {
  const f = fixture(); f.env.HIMMEL_API_CALL_TIMEOUT_S = '3600';
  f.call('reserve', ['--id', 'lost', '--usd', '0.30']); f.call('unknown', ['--id', 'lost']);
  f.call('reserve', ['--id', 'legacy', '--usd', '0.20']);
  ageJob(f, 'lost', 7200); ageJob(f, 'legacy', null);
  assert.equal(f.call().reserved_usd, '0.000000');
  assert.equal(f.call('reserve', ['--id', 'next', '--usd', '1.00']).verdict, 'PROCEED');
});

test('HIMMEL-7264: auto routing proceeds on an operator snapshot older than 24 h while it shows headroom, and a fresh account still wins', () => {
  const f = fixture();
  for (const a of ['A', 'B']) { f.snapshot.accounts[a].starts_at = f.now - 400000; f.snapshot.accounts[a].observed_at = f.now - 90000; }
  f.save();
  const pick = () => JSON.parse(spawnSync(process.execPath, [SUT, 'pick', '--usd', '0.01'], { env: f.env, encoding: 'utf8' }).stdout);
  const stale = pick();
  assert.equal(stale.verdict, 'PROCEED');
  assert.equal(stale.snapshot_stale, true);
  assert.equal(stale.account, 'A');
  f.snapshot.accounts.B.observed_at = f.now - 3600;
  f.save();
  const fresh = pick();
  assert.equal(fresh.account, 'B');
  assert.notEqual(fresh.snapshot_stale, true);
});

const pickUsd = (f, usd, env = f.env) => JSON.parse(spawnSync(process.execPath, [SUT, 'pick', '--usd', usd], { env, encoding: 'utf8' }).stdout);

test('HIMMEL-7264: a stale reading never blocks the auto route; the caps and a fresh empty reading still do', () => {
  const f = fixture();
  for (const a of ['A', 'B']) {
    Object.assign(f.snapshot.accounts[a], { starts_at: f.now - 400000, observed_at: f.now - 90000, remaining_usd: '0.00' });
  }
  f.save();
  const stale = pickUsd(f, '0.01');
  assert.equal(stale.verdict, 'PROCEED');
  assert.equal(stale.snapshot_unknown, true);
  assert.equal(stale.account, 'A');
  assert.equal(pickUsd(f, '1.50').account, 'B');  // A's cap is 1.00 whatever the old reading says
  assert.equal(pickUsd(f, '2.50').verdict, 'SKIPPED-BANK');  // no cap has room
  for (const a of ['A', 'B']) f.snapshot.accounts[a].observed_at = f.now;
  f.save();
  assert.equal(pickUsd(f, '0.01').verdict, 'SKIPPED-BANK');  // a fresh reading with nothing left is a known fact
});

test('HIMMEL-7264: a missing snapshot, a missing row, an expired grant and an aged-out automatic snapshot all route on the ledger', () => {
  const cases = {
    'file missing': (f) => rmSync(f.paths.snapshot),
    'row missing': (f) => { f.snapshot.accounts = {}; f.save(); },
    'expired grant': (f) => { for (const a of ['A', 'B']) Object.assign(f.snapshot.accounts[a], { starts_at: f.now - 4000, expires_at: f.now - 10 }); f.save(); },
    'aged-out automatic': (f) => { for (const a of ['A', 'B']) Object.assign(f.snapshot.accounts[a], { source: 'automatic-snapshot', starts_at: f.now - 7200, observed_at: f.now - 3600 }); f.save(); },
  };
  for (const [name, mutate] of Object.entries(cases)) {
    const f = fixture();
    mutate(f);
    const r = pickUsd(f, '0.01');
    assert.equal(r.verdict, 'PROCEED', `${name}: ${JSON.stringify(r)}`);
    assert.equal(r.snapshot_unknown, true, name);
  }
});

test('HIMMEL-7264: the optional-snapshot flag lets reserve run with no snapshot; an explicit call still refuses', () => {
  const f = fixture();
  rmSync(f.paths.snapshot);
  const run = (env) => JSON.parse(spawnSync(process.execPath, [SUT, 'reserve', '--id', 'j1', '--usd', '0.50'], { env, encoding: 'utf8' }).stdout);
  assert.notEqual(run(f.env).verdict, 'PROCEED');
  const r = run({ ...f.env, HIMMEL_API_SNAPSHOT_OPTIONAL: '1' });
  assert.equal(r.verdict, 'PROCEED');
  assert.equal(r.source, 'ledger-only');
  assert.equal(r.reserved_usd, '0.500000');
});

test('HIMMEL-7264: an account marked exhausted is skipped, returns after an hour or a newer reading, and still serves when it is the only one', () => {
  const f = fixture();
  for (const a of ['A', 'B']) f.snapshot.accounts[a].observed_at = f.now - 200;
  f.save();
  const mark = (account) => JSON.parse(spawnSync(process.execPath, [SUT, 'exhausted'], { env: { ...f.env, HIMMEL_API_ACCOUNT: account }, encoding: 'utf8' }).stdout);
  const setAt = (account, at) => {
    const ledger = JSON.parse(readFileSync(f.paths.state, 'utf8'));
    ledger.accounts[account].exhausted_at = at;
    writeFileSync(f.paths.state, JSON.stringify(ledger));
  };
  assert.equal(pickUsd(f, '0.01').account, 'A');
  assert.equal(mark('A').verdict, 'PROCEED');
  assert.equal(pickUsd(f, '0.01').account, 'B');  // A is skipped
  assert.equal(mark('B').verdict, 'PROCEED');
  setAt('A', f.now - 100); setAt('B', f.now - 50);
  assert.equal(pickUsd(f, '0.01').account, 'A');  // both exhausted: the one exhausted longest ago serves, never a refusal
  setAt('A', f.now - 50); setAt('B', f.now - 100);
  assert.equal(pickUsd(f, '0.01').account, 'B');
  setAt('A', f.now - 4000); setAt('B', f.now - 50);
  assert.equal(pickUsd(f, '0.01').account, 'A');  // A's hour has passed
  f.snapshot.accounts.B.observed_at = f.now - 10;  // a reading newer than the exhaustion clears it
  f.save();
  setAt('A', f.now - 50);
  assert.equal(pickUsd(f, '0.01').account, 'B');
  assert.equal(JSON.parse(readFileSync(f.paths.state, 'utf8')).accounts.A.discrepancy, false);
});

test('HIMMEL-7111: the bank line shows the snapshot age and flags one past 24 h', () => {
  const f = fixture();
  f.snapshot.accounts.A.starts_at = f.now - 400000;
  f.snapshot.accounts.A.observed_at = f.now - 90000;
  f.save();
  const r = spawnSync(process.execPath, [SUT, 'status'], { env: { ...f.env, HIMMEL_API_CREDIT_FORMAT: 'bank' }, encoding: 'utf8' });
  assert.match(r.stderr, /age=9000\d .*stale-snapshot/);
  assert.equal(r.stdout.trim(), 'PROCEED');
});
