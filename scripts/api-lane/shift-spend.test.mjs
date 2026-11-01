// Shift spend record fixtures. Synthetic codex rollouts, ledgers and API launch records, plus an
// OpenRouter body pinned to the vendor docs' documented shape (unverified live):
// no provider call, no real credential.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, utimesSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  buildRecord, claudeBankField, codexField, costField, fetchOpenRouterKey, openrouterField,
} from './shift-spend.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const FIX = join(HERE, 'fixtures', 'shift-spend');
const CLI = join(HERE, 'shift-spend.mjs');
const T = mkdtempSync(join(tmpdir(), 'shift-spend-'));
process.on('exit', () => rmSync(T, { recursive: true, force: true }));
const json = (name) => JSON.parse(readFileSync(join(FIX, name), 'utf8'));

const SINCE = '2026-10-30T22:00:00Z';
const UNTIL = '2026-10-31T06:00:00Z';

function tokenEvent(ts, total, pct, resetsAt = 1793774616) {
  return JSON.stringify({
    timestamp: ts, type: 'event_msg',
    payload: {
      type: 'token_count',
      info: { total_token_usage: { input_tokens: total, cached_input_tokens: total / 2, output_tokens: total / 10, reasoning_output_tokens: 0, total_tokens: total + total / 10 } },
      rate_limits: { limit_id: 'codex', primary: { used_percent: pct, window_minutes: 10080, resets_at: resetsAt } },
    },
  });
}
function rollout(root, name, lines) {
  const dir = join(root, '2026', '10', '31');
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, `rollout-${name}.jsonl`), `${lines.join('\n')}\n`);
}
function codexRoot(label, files) {
  const root = join(T, label);
  for (const [name, lines] of Object.entries(files)) rollout(root, name, lines);
  return root;
}
const ledgerRow = (ts, five, seven, extra = {}) => JSON.stringify({ ts, leg: 'x', verdict: 'PROCEED', five_hour: five, seven_day: seven, age: '3', degraded: false, ...extra });

test('codex tokens: only growth inside [since, until) counts, per session, summed across sessions', () => {
  const root = codexRoot('codex-a', {
    // session one: 1000 before the shift, 4000 at the last in-window event, 9000 after
    one: [tokenEvent('2026-10-30T21:00:00Z', 1000, 40), tokenEvent('2026-10-30T23:00:00Z', 2500, 41), tokenEvent('2026-10-31T05:59:59Z', 4000, 42), tokenEvent('2026-10-31T06:00:00Z', 9000, 43)],
    // session two starts inside the shift: its whole growth counts
    two: [tokenEvent('2026-10-31T01:00:00Z', 500, 42), tokenEvent('2026-10-31T02:00:00Z', 800, 42)],
    // session three is entirely before the shift
    three: [tokenEvent('2026-10-30T10:00:00Z', 7777, 30)],
  });
  const f = codexField(root, SINCE, UNTIL);
  assert.equal(f.status, 'ok');
  assert.equal(f.unit, 'tokens');
  assert.equal(f.input_tokens, (4000 - 1000) + 800);
  assert.equal(f.total_tokens, (4400 - 1100) + 880);
  assert.equal(f.value, f.total_tokens);
});

test('codex bank: weekly percentage-point change across the shift, read from the same rollouts', () => {
  const root = codexRoot('codex-b', {
    one: [tokenEvent('2026-10-30T21:00:00Z', 1000, 40), tokenEvent('2026-10-31T05:00:00Z', 4000, 47.5)],
    two: [tokenEvent('2026-10-31T02:00:00Z', 800, 44)],
  });
  const f = codexField(root, SINCE, UNTIL, 'bank');
  assert.equal(f.status, 'ok');
  assert.equal(f.unit, 'percentage points of the weekly window');
  assert.equal(f.start, 40);
  assert.equal(f.end, 47.5);
  assert.equal(f.value, 7.5);
});

test('codex bank: a weekly reset inside the shift is not a change, it reads not available', () => {
  const root = codexRoot('codex-c', {
    one: [tokenEvent('2026-10-30T21:00:00Z', 1000, 90, 1793000000), tokenEvent('2026-10-31T05:00:00Z', 1200, 3, 1793600000)],
  });
  const f = codexField(root, SINCE, UNTIL, 'bank');
  assert.equal(f.status, 'not available');
  assert.match(f.reason, /reset/);
});

test('codex bank: the weekly window is read from secondary too, and an idle older session supplies the pre-shift reading', () => {
  const root = codexRoot('codex-e', { old: [tokenEvent('2026-10-29T12:00:00Z', 1000, 30)], now: [] });
  rollout(root, 'now', [JSON.stringify({ timestamp: '2026-10-31T01:00:00Z', type: 'event_msg', payload: { type: 'token_count', info: null,
    rate_limits: { primary: { used_percent: 5, window_minutes: 300, resets_at: 1 }, secondary: { used_percent: 33, window_minutes: 10080, resets_at: 1793774616 } } } })]);
  const idleSince = new Date('2026-10-29T13:00:00Z');
  utimesSync(join(root, '2026', '10', '31', 'rollout-old.jsonl'), idleSince, idleSince);
  const f = codexField(root, SINCE, UNTIL, 'bank');
  assert.equal(f.status, 'ok');
  assert.equal(f.start, 30);
  assert.equal(f.end, 33);
  assert.equal(f.start_from, 'last reading before the shift');
});

test('codex bank: an unknown reset time or a falling reading is not a comparable change', () => {
  const noReset = (ts, pct) => JSON.stringify({ timestamp: ts, type: 'event_msg', payload: { type: 'token_count', info: null, rate_limits: { primary: { used_percent: pct, window_minutes: 10080 } } } });
  const unknown = codexRoot('codex-h', { one: [noReset('2026-10-30T21:00:00Z', 40), noReset('2026-10-31T01:00:00Z', 41)] });
  assert.equal(codexField(unknown, SINCE, UNTIL, 'bank').status, 'not available');
  const falling = codexRoot('codex-i', { one: [tokenEvent('2026-10-30T21:00:00Z', 1000, 40), tokenEvent('2026-10-31T01:00:00Z', 1100, 35)] });
  assert.equal(codexField(falling, SINCE, UNTIL, 'bank').status, 'not available');
});

test('codex: a missing sessions dir, and a shift with no codex event, read not available for the bank and zero-free for tokens', () => {
  assert.equal(codexField(join(T, 'no-such-dir'), SINCE, UNTIL).status, 'not available');
  assert.equal(codexField(join(T, 'no-such-dir'), SINCE, UNTIL, 'bank').status, 'not available');
  const quiet = codexRoot('codex-d', { one: [tokenEvent('2026-10-30T10:00:00Z', 1000, 40)] });
  assert.equal(codexField(quiet, SINCE, UNTIL, 'bank').status, 'not available');
  assert.equal(codexField(quiet, SINCE, UNTIL).total_tokens, 0);
});

test('codex tokens: sessions that never reported a total read not available, and a grown file is re-read', () => {
  const blank = codexRoot('codex-f', { one: [JSON.stringify({ timestamp: '2026-10-31T01:00:00Z', type: 'event_msg', payload: { type: 'token_count', info: null, rate_limits: null } })] });
  assert.equal(codexField(blank, SINCE, UNTIL).status, 'not available');
  const grow = codexRoot('codex-g', { one: [tokenEvent('2026-10-31T01:00:00Z', 1000, 40)] });
  assert.equal(codexField(grow, SINCE, UNTIL).input_tokens, 1000);
  rollout(grow, 'one', [tokenEvent('2026-10-31T01:00:00Z', 1000, 40), tokenEvent('2026-10-31T02:00:00Z', 3000, 41)]);
  assert.equal(codexField(grow, SINCE, UNTIL).input_tokens, 3000);
});

test('claude bank: start, end and peak of both windows from the cadence ledger, degraded rows ignored', () => {
  const ledger = join(T, 'ledger.jsonl');
  writeFileSync(ledger, [
    ledgerRow('2026-10-30T20:00:00Z', '10.0', '50.0'),
    ledgerRow('2026-10-30T23:00:00Z', '20.0', '51.0'),
    ledgerRow('2026-10-31T01:00:00Z', '60.0', '53.0'),
    ledgerRow('2026-10-31T02:00:00Z', '99.0', '99.0', { degraded: true }),
    ledgerRow('2026-10-31T05:00:00Z', '30.0', '55.0'),
    ledgerRow('2026-10-31T07:00:00Z', '5.0', '56.0'),
  ].join('\n'));
  const f = claudeBankField(ledger, SINCE, UNTIL);
  assert.equal(f.status, 'ok');
  assert.equal(f.unit, 'percent of the subscription window');
  assert.deepEqual(f.seven_day, { start: 50, end: 55, peak: 55, delta: 5 });
  // 60 then 30 is a five-hour reset inside the shift: the burn is 10 + 40 up to the reset, then the 30 read after it
  assert.deepEqual(f.five_hour, { start: 10, end: 30, peak: 60, delta: 80, resets: 1 });
  assert.equal(f.samples, 3);
  // a reset followed by recovery above the start still burns: 40 to 5 is a reset (the 5 read after it was used), then 5 to 45
  writeFileSync(join(T, 'recover.jsonl'), [ledgerRow('2026-10-30T21:00:00Z', '1.0', '40.0'), ledgerRow('2026-10-31T01:00:00Z', '1.0', '5.0'), ledgerRow('2026-10-31T03:00:00Z', '1.0', '45.0')].join('\n'));
  const recover = claudeBankField(join(T, 'recover.jsonl'), SINCE, UNTIL);
  assert.deepEqual(recover.seven_day, { start: 40, end: 45, peak: 45, delta: 45, resets: 1 });
  assert.equal(recover.value, 45);
  assert.match(recover.note, /estimate/);
  assert.match(recover.note, /account change/);
  // a null or empty utilization is a missing reading, never a measured zero
  writeFileSync(join(T, 'nulls.jsonl'), [ledgerRow('2026-10-31T01:00:00Z', null, '5.0'), ledgerRow('2026-10-31T02:00:00Z', '', '6.0')].join('\n'));
  assert.equal(claudeBankField(join(T, 'nulls.jsonl'), SINCE, UNTIL).status, 'not available');
  // one weekly reset in a shift with hundreds of readings must not null the whole value
  const many = [ledgerRow('2026-10-30T21:00:00Z', '10.0', '90.0')];
  const minute = (i) => new Date(Date.parse('2026-10-30T22:00:00Z') + i * 60000).toISOString().replace('.000Z', 'Z');
  for (let i = 0; i < 100; i++) many.push(ledgerRow(minute(i), '11.0', '95.0'));
  for (let i = 100; i < 299; i++) many.push(ledgerRow(minute(i), '12.0', '2.0'));
  many.push(ledgerRow(minute(299), '13.0', '7.0'));
  writeFileSync(join(T, 'many.jsonl'), many.join('\n'));
  const big = claudeBankField(join(T, 'many.jsonl'), SINCE, UNTIL);
  assert.equal(big.samples, 300);
  assert.equal(big.seven_day.resets, 1);
  assert.equal(big.value, 5 + 2 + 5);
  // a fall inside the shift is read as a reset (the ledger has no account or reset time): the burn counts the reading after it
  writeFileSync(join(T, 'reset.jsonl'), [ledgerRow('2026-10-30T21:00:00Z', '40.0', '99.0'), ledgerRow('2026-10-31T01:00:00Z', '10.0', '13.0')].join('\n'));
  const reset = claudeBankField(join(T, 'reset.jsonl'), SINCE, UNTIL);
  assert.equal(reset.seven_day.delta, 13);
  assert.equal(reset.seven_day.resets, 1);
  assert.equal(reset.value, 13);
  assert.equal(claudeBankField(join(T, 'no-ledger.jsonl'), SINCE, UNTIL).status, 'not available');
  writeFileSync(join(T, 'sparse.jsonl'), `${ledgerRow('2026-10-29T00:00:00Z', '1.0', '2.0')}\n`);
  assert.equal(claudeBankField(join(T, 'sparse.jsonl'), SINCE, UNTIL).status, 'not available');
});

// API lane dollars come from our own launch records (an individual org has no Admin key for the cost report).
const launch = (ts, account, cost, tokens = [2, 1000, 500], extra = {}) => JSON.stringify({
  ts, job_id: `api-${ts}`, account, model: 'opus', outcome: 'settled', cost_usd: cost, rc: 0, kind: 'judge',
  input_tokens: tokens[0], cache_creation_tokens: tokens[1], cache_read_tokens: tokens[2], ...extra,
});

test('api cost: launch records inside [since, until) are summed per account in micro-dollars, marked local-priced', () => {
  const file = join(T, 'launches-a.jsonl');
  writeFileSync(file, [
    launch('2026-10-30T21:59:59Z', 'A', '9.000000'),
    launch('2026-10-30T22:00:00Z', 'A', '0.531823', [2, 79733, 649]),
    launch('2026-10-31T01:00:00Z', 'B', '0.100000', [3, 10, 20]),
    launch('2026-10-31T03:00:00Z', 'A', '0.396643', [2, 77141, 649]),
    launch('2026-10-31T06:00:00Z', 'A', '9.000000'),
  ].join('\n'));
  const f = costField(file, SINCE, UNTIL);
  assert.equal(f.status, 'ok');
  assert.equal(f.unit, 'USD');
  assert.match(f.source, /^local-priced/);
  assert.deepEqual(f.per_account, { A: '0.928466', B: '0.100000' });
  assert.equal(f.value, '1.028466');
  assert.equal(f.runs, 3);
  assert.equal(f.partial, undefined);
  assert.deepEqual(f.tokens, { input: 7, cache_creation: 156884, cache_read: 1318 });
});

test('api cost: a run with no cost is counted apart, never as zero; no launch log reads not available', () => {
  const file = join(T, 'launches-b.jsonl');
  writeFileSync(file, [launch('2026-10-31T01:00:00Z', 'A', '0.250000'), launch('2026-10-31T02:00:00Z', 'A', '', [null, null, null], { outcome: 'unknown' })].join('\n'));
  const f = costField(file, SINCE, UNTIL);
  assert.equal(f.status, 'ok');
  assert.equal(f.value, '0.250000');
  assert.equal(f.unpriced_runs, 1);
  // the sum leaves a run out, so it is a floor and says so; a complete sum carries no partial mark
  assert.equal(f.partial, true);
  assert.match(f.note, /at least/);
  assert.deepEqual(f.tokens, { input: 2, cache_creation: 1000, cache_read: 500 });
  writeFileSync(file, `${launch('2026-10-31T02:00:00Z', 'A', '', [null, null, null], { outcome: 'unknown' })}\n`);
  assert.equal(costField(file, SINCE, UNTIL).status, 'not available');
  assert.equal(costField(join(T, 'gone-launches.jsonl'), SINCE, UNTIL).status, 'not available');
  // the launcher writes 0.000000 for a failed run whose cost it never verified: that is unpriced, while a settled 0.000000 is a measured zero
  writeFileSync(file, [launch('2026-10-31T01:00:00Z', 'A', '0.250000'), launch('2026-10-31T02:00:00Z', 'A', '0.000000', [1, 2, 3], { outcome: 'failed', rc: 1 }),
    launch('2026-10-31T03:00:00Z', 'A', '0.000000'), launch('2026-10-31T04:00:00Z', 'A', '0.100000', [1, 2, 3], { outcome: 'failed', rc: 1 })].join('\n'));
  const failed = costField(file, SINCE, UNTIL);
  assert.equal(failed.value, '0.350000');
  assert.equal(failed.runs, 3);
  assert.equal(failed.unpriced_runs, 1);
  assert.equal(failed.partial, true);
  // a truncated or unreadable line may belong to the shift: the total is a floor, never an unqualified measurement
  writeFileSync(file, `${launch('2026-10-31T01:00:00Z', 'A', '0.250000')}\n{"ts":"2026-10-31T02:00:00Z","cost_us\n`);
  const torn = costField(file, SINCE, UNTIL);
  assert.equal(torn.status, 'ok');
  assert.equal(torn.partial, true);
  assert.equal(torn.unreadable_lines, 1);
  writeFileSync(file, `${launch('2026-10-31T01:00:00Z', 'A', '0.250000')}\n\n`);
  assert.equal(costField(file, SINCE, UNTIL).partial, undefined, 'blank lines are not unreadable');
  // a log that exists but holds no run in the shift is a measured zero
  writeFileSync(file, `${launch('2026-09-01T02:00:00Z', 'A', '5.000000')}\n`);
  const none = costField(file, SINCE, UNTIL);
  assert.equal(none.status, 'ok');
  assert.equal(none.value, '0.000000');
  assert.equal(none.runs, 0);
});

test('openrouter key: usage figures parsed from the documented shape, a malformed body reads not available', async () => {
  const f = openrouterField({ body: json('openrouter-key.json') });
  assert.equal(f.status, 'ok');
  assert.equal(f.unit, 'USD');
  assert.equal(f.usage_total, 25.5);
  assert.equal(f.usage_daily, 3.25);
  assert.equal(f.usage_weekly, 12.75);
  assert.equal(f.usage_monthly, 25.5);
  assert.equal(f.limit_remaining, 74.5);
  assert.equal(f.value, 3.25);
  assert.equal(openrouterField({ body: { data: { usage: 'a lot' } } }).status, 'not available');
  // no key: the column says so in its source mark and carries no figure, never a zero
  const nokey = openrouterField({ error: 'openrouter-key-missing' });
  assert.equal(nokey.status, 'not available');
  assert.equal(nokey.source, 'unavailable(no key)');
  assert.equal(nokey.value, undefined);
  assert.notEqual(openrouterField({ error: 'openrouter-key-unavailable: http-401' }).source, 'unavailable(no key)');
  let seen;
  const fetchImpl = async (url, init) => { seen = { url: String(url), headers: init.headers }; return { ok: true, status: 200, json: async () => json('openrouter-key.json') }; };
  await fetchOpenRouterKey('sk-or-dummy', fetchImpl);
  assert.equal(seen.url, 'https://openrouter.ai/api/v1/key');
  assert.equal(seen.headers.Authorization, 'Bearer sk-or-dummy');
});

function fullInputs(overrides = {}) {
  const codex = codexRoot('rec', {
    one: [tokenEvent('2026-10-30T21:00:00Z', 1000, 40), tokenEvent('2026-10-31T05:00:00Z', 4000, 47)],
  });
  const ledger = join(T, 'rec-ledger.jsonl');
  writeFileSync(ledger, [ledgerRow('2026-10-30T23:00:00Z', '20.0', '51.0'), ledgerRow('2026-10-31T05:00:00Z', '30.0', '55.0')].join('\n'));
  const launches = join(T, 'rec-launches.jsonl');
  writeFileSync(launches, [launch('2026-10-31T01:00:00Z', 'A', '1.352892')].join('\n'));
  return {
    since: SINCE, until: UNTIL, codexDir: codex, ledgerFile: ledger, launchesFile: launches,
    openrouter: { body: json('openrouter-key.json') },
    ...overrides,
  };
}

test('record: five source-marked fields, none equal to a sum of the others', () => {
  const r = buildRecord(fullInputs());
  const names = ['codex_tokens', 'codex_bank', 'claude_bank', 'api_cost', 'openrouter'];
  assert.deepEqual(Object.keys(r.fields), names);
  assert.deepEqual(r.window, { since: SINCE, until: UNTIL });
  for (const n of names) {
    assert.equal(r.fields[n].status, 'ok', n);
    assert.ok(r.fields[n].source && r.fields[n].unit, `${n} carries a source mark and a unit`);
  }
  // codex_tokens ~3300, codex_bank 7, claude_bank 4, api_cost 1.352892, openrouter 3.25
  const values = names.map((n) => Number(r.fields[n].value));
  values.forEach((v, i) => {
    const others = values.reduce((s, x, j) => (j === i ? s : s + x), 0);
    assert.notEqual(v, others);
  });
  assert.equal(r.total, undefined, 'the record states no grand total');
});

test('record: with one source missing that field reads not available and the others still show', () => {
  const r = buildRecord(fullInputs({ launchesFile: join(T, 'gone-launches.jsonl'), ledgerFile: join(T, 'gone.jsonl') }));
  assert.equal(r.fields.api_cost.status, 'not available');
  assert.equal(r.fields.claude_bank.status, 'not available');
  for (const n of ['api_cost', 'claude_bank']) assert.ok(r.fields[n].source, `${n} keeps its source mark`);
  assert.equal(r.fields.codex_tokens.status, 'ok');
  assert.equal(r.fields.codex_bank.status, 'ok');
  assert.equal(r.fields.openrouter.status, 'ok');
  assert.ok(!JSON.stringify(r).includes('"value":0,'), 'a missing source is never zero');
});

test('record: a reader that throws is caught per field, not for the record', () => {
  const r = buildRecord(fullInputs({ openrouter: { body: { data: null } }, launchesFile: null }));
  assert.equal(r.fields.openrouter.status, 'not available');
  assert.equal(r.fields.api_cost.status, 'not available');
  assert.equal(r.fields.codex_tokens.status, 'ok');
});

test('cli: file sources produce the record on stdout and the key is never printed', () => {
  const inputs = fullInputs();
  const env = { PATH: process.env.PATH, HOME: join(T, 'home'), HIMMEL_DOTENV_FILE: join(T, 'no-dotenv'), OPENROUTER_API_KEY: 'sk-or-dummy' };
  const r = spawnSync(process.execPath, [CLI, '--since', SINCE, '--until', UNTIL,
    '--codex-sessions', inputs.codexDir, '--cadence-ledger', inputs.ledgerFile, '--api-launches', inputs.launchesFile,
    '--openrouter-key-file', join(FIX, 'openrouter-key.json')], { encoding: 'utf8', env });
  assert.equal(r.status, 0, r.stderr);
  const rec = JSON.parse(r.stdout);
  assert.equal(rec.fields.api_cost.value, '1.352892');
  assert.equal(rec.fields.openrouter.usage_total, 25.5);
  assert.ok(!r.stdout.includes('sk-or-dummy') && !r.stderr.includes('sk-or-dummy'));
});

test('cli: with no OpenRouter source and no --live, openrouter reads not available and nothing is fetched', () => {
  const inputs = fullInputs();
  const r = spawnSync(process.execPath, [CLI, '--since', SINCE, '--until', UNTIL,
    '--codex-sessions', inputs.codexDir, '--cadence-ledger', inputs.ledgerFile, '--api-launches', inputs.launchesFile], { encoding: 'utf8', env: { PATH: process.env.PATH, HOME: join(T, 'home') } });
  assert.equal(r.status, 0, r.stderr);
  const rec = JSON.parse(r.stdout);
  assert.equal(rec.fields.api_cost.status, 'ok');
  assert.equal(rec.fields.openrouter.status, 'not available');
  assert.equal(rec.fields.codex_tokens.status, 'ok');
});

test('cli: --live with no OpenRouter key marks that column unavailable(no key) and fetches nothing; the API dollars need no key', () => {
  const inputs = fullInputs();
  const env = { PATH: process.env.PATH, HOME: join(T, 'home'), HIMMEL_DOTENV_FILE: join(T, 'no-dotenv') };
  const r = spawnSync(process.execPath, [CLI, '--since', SINCE, '--until', UNTIL, '--codex-sessions', inputs.codexDir, '--cadence-ledger', inputs.ledgerFile, '--api-launches', inputs.launchesFile, '--live'], { encoding: 'utf8', env });
  assert.equal(r.status, 0, r.stderr);
  const rec = JSON.parse(r.stdout);
  assert.equal(rec.fields.openrouter.status, 'not available');
  assert.equal(rec.fields.openrouter.source, 'unavailable(no key)');
  assert.equal(rec.fields.api_cost.value, '1.352892');
});

test('cli: the launch log defaults to the api-credit state dir under HOME', () => {
  const inputs = fullInputs();
  const home = join(T, 'home-with-launches');
  mkdirSync(join(home, '.himmel', 'state', 'api-credit'), { recursive: true });
  writeFileSync(join(home, '.himmel', 'state', 'api-credit', 'launches.jsonl'), `${launch('2026-10-31T02:00:00Z', 'B', '0.420000')}\n`);
  const r = spawnSync(process.execPath, [CLI, '--since', SINCE, '--until', UNTIL, '--codex-sessions', inputs.codexDir, '--cadence-ledger', inputs.ledgerFile], { encoding: 'utf8', env: { PATH: process.env.PATH, HOME: home } });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(JSON.parse(r.stdout).fields.api_cost.per_account.B, '0.420000');
});

test('cli: with HIMMEL_API_CREDIT_CONFIG set, the launch log is read beside its ledger_path, like the launcher writes it', () => {
  const inputs = fullInputs();
  const home = join(T, 'home-cfg');
  const state = join(T, 'elsewhere', 'api-credit');
  mkdirSync(state, { recursive: true });
  mkdirSync(join(home, '.himmel', 'state', 'api-credit'), { recursive: true });
  writeFileSync(join(home, '.himmel', 'state', 'api-credit', 'launches.jsonl'), `${launch('2026-10-31T02:00:00Z', 'A', '9.000000')}\n`);
  writeFileSync(join(state, 'launches.jsonl'), `${launch('2026-10-31T02:00:00Z', 'B', '0.330000')}\n`);
  writeFileSync(join(T, 'credit-config.json'), JSON.stringify({ ledger_path: join(state, 'ledger.json') }));
  const env = { PATH: process.env.PATH, HOME: home, HIMMEL_API_CREDIT_CONFIG: join(T, 'credit-config.json') };
  const run = (extra = []) => JSON.parse(spawnSync(process.execPath, [CLI, '--since', SINCE, '--until', UNTIL, '--codex-sessions', inputs.codexDir, '--cadence-ledger', inputs.ledgerFile, ...extra], { encoding: 'utf8', env }).stdout);
  assert.deepEqual(run().fields.api_cost.per_account, { B: '0.330000' });
  assert.equal(run(['--api-launches', inputs.launchesFile]).fields.api_cost.value, '1.352892', 'the explicit flag still wins');
  // a config that cannot be read falls back to the HOME state dir
  env.HIMMEL_API_CREDIT_CONFIG = join(T, 'no-such-config.json');
  assert.deepEqual(run().fields.api_cost.per_account, { A: '9.000000' });
});

test('cli: a bad window is refused', () => {
  for (const args of [['--since', '2026-02-30T00:00:00Z', '--until', UNTIL], ['--since', SINCE, '--until', '2026-10-31T24:00:00Z'], ['--since', 'yesterday', '--until', UNTIL], ['--since', UNTIL, '--until', SINCE], ['--until', UNTIL]]) {
    const r = spawnSync(process.execPath, [CLI, ...args], { encoding: 'utf8', env: { PATH: process.env.PATH, HOME: join(T, 'home') } });
    assert.equal(r.status, 2, args.join(' '));
  }
});
