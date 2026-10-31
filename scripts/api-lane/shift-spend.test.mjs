// Shift spend record fixtures. Synthetic codex rollouts and ledgers, plus API
// response bodies pinned to the vendor docs' documented shapes (unverified live):
// no provider call, no real credential.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, utimesSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  buildRecord, claudeBankField, codexField, costField, fetchCostPages, fetchOpenRouterKey, openrouterField,
} from './shift-spend.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const FIX = join(HERE, 'fixtures', 'shift-spend');
const CLI = join(HERE, 'shift-spend.mjs');
const T = mkdtempSync(join(tmpdir(), 'shift-spend-'));
process.on('exit', () => rmSync(T, { recursive: true, force: true }));
const json = (name) => JSON.parse(readFileSync(join(FIX, name), 'utf8'));
const DUMMY = 'sk-ant-admin-dummy-not-a-real-key-0000';

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
  // 60 then 30 is a five-hour reset inside the shift: readings stay, the change is not stated
  assert.deepEqual(f.five_hour, { start: 10, end: 30, peak: 60, delta: null, reset_in_window: true });
  assert.equal(f.samples, 3);
  // a reset followed by recovery above the start is still a reset, not a +delta
  writeFileSync(join(T, 'recover.jsonl'), [ledgerRow('2026-10-30T21:00:00Z', '1.0', '40.0'), ledgerRow('2026-10-31T01:00:00Z', '1.0', '5.0'), ledgerRow('2026-10-31T03:00:00Z', '1.0', '45.0')].join('\n'));
  const recover = claudeBankField(join(T, 'recover.jsonl'), SINCE, UNTIL);
  assert.equal(recover.seven_day.delta, null);
  assert.equal(recover.seven_day.reset_in_window, true);
  assert.equal(recover.value, null);
  // a null or empty utilization is a missing reading, never a measured zero
  writeFileSync(join(T, 'nulls.jsonl'), [ledgerRow('2026-10-31T01:00:00Z', null, '5.0'), ledgerRow('2026-10-31T02:00:00Z', '', '6.0')].join('\n'));
  assert.equal(claudeBankField(join(T, 'nulls.jsonl'), SINCE, UNTIL).status, 'not available');
  // a fall inside the shift is a reset or an account change: readings stay, the change is not stated
  writeFileSync(join(T, 'reset.jsonl'), [ledgerRow('2026-10-30T21:00:00Z', '40.0', '99.0'), ledgerRow('2026-10-31T01:00:00Z', '10.0', '13.0')].join('\n'));
  const reset = claudeBankField(join(T, 'reset.jsonl'), SINCE, UNTIL);
  assert.equal(reset.seven_day.delta, null);
  assert.equal(reset.seven_day.reset_in_window, true);
  assert.equal(reset.value, null);
  assert.equal(claudeBankField(join(T, 'no-ledger.jsonl'), SINCE, UNTIL).status, 'not available');
  writeFileSync(join(T, 'sparse.jsonl'), `${ledgerRow('2026-10-29T00:00:00Z', '1.0', '2.0')}\n`);
  assert.equal(claudeBankField(join(T, 'sparse.jsonl'), SINCE, UNTIL).status, 'not available');
});

test('cost report: pages summed in micro-dollars, rounded up, USD only, pinned to the documented shape', () => {
  const pages = [json('cost-report-page1.json'), json('cost-report-page2.json')];
  const f = costField({ A: { bodies: pages } }, SINCE, UNTIL);
  assert.equal(f.status, 'ok');
  assert.equal(f.unit, 'USD');
  assert.equal(f.per_account.A, '1.352892');
  assert.equal(f.value, '1.352892');
  const eur = structuredClone(pages);
  eur[1].data[0].results[0].currency = 'EUR';
  assert.equal(costField({ A: { bodies: eur } }, SINCE, UNTIL).status, 'not available');
  const broken = structuredClone(pages);
  delete broken[0].has_more;
  assert.equal(costField({ A: { bodies: broken } }, SINCE, UNTIL).status, 'not available');
  // a missing first page is not a smaller total
  const tail = costField({ A: { bodies: [pages[1]] } }, SINCE, UNTIL);
  assert.equal(tail.status, 'not available');
  assert.match(tail.reason, /does-not-cover/);
  // a response for another window is not this shift's spend
  const other = costField({ A: { bodies: pages } }, '2026-09-01T00:00:00Z', '2026-09-02T00:00:00Z');
  assert.equal(other.status, 'not available');
  assert.match(other.reason, /outside-window/);
});

test('cost report: one account unreadable keeps the other visible and the total unstated', () => {
  const pages = [json('cost-report-page1.json'), json('cost-report-page2.json')];
  const f = costField({ A: { bodies: pages }, B: { error: 'admin-key-missing' } }, SINCE, UNTIL);
  assert.equal(f.status, 'not available');
  assert.equal(f.per_account.A, '1.352892');
  assert.equal(f.per_account.B, 'not available');
  assert.equal(f.value, undefined);
});

test('cost report fetch: day-snapped window, x-api-key header, paging, and the key never reaches an error', async () => {
  const calls = [];
  const bodies = [json('cost-report-page1.json'), json('cost-report-page2.json')];
  const fetchImpl = async (url, init) => {
    calls.push({ url: new URL(url), headers: init.headers });
    return { ok: true, status: 200, json: async () => bodies[calls.length - 1] };
  };
  const got = await fetchCostPages(DUMMY, SINCE, UNTIL, fetchImpl);
  assert.equal(got.length, 2);
  assert.equal(calls[0].url.searchParams.get('starting_at'), '2026-10-30T00:00:00Z');
  assert.equal(calls[0].url.searchParams.get('ending_at'), '2026-11-01T00:00:00Z');
  assert.equal(calls[0].url.searchParams.get('bucket_width'), '1d');
  assert.equal(calls[1].url.searchParams.get('page'), 'page_MjAyNS0wNS0xNFQwMDowMDowMFo=');
  assert.equal(calls[0].headers['x-api-key'], DUMMY);
  const failing = async () => ({ ok: false, status: 403, json: async () => ({ error: DUMMY }) });
  await assert.rejects(fetchCostPages(DUMMY, SINCE, UNTIL, failing), (e) => /http-403/.test(e.message) && !e.message.includes(DUMMY));
  const throwing = async () => { throw new Error(`connect failed for ${DUMMY}`); };
  await assert.rejects(fetchCostPages(DUMMY, SINCE, UNTIL, throwing), (e) => !e.message.includes(DUMMY));
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
  assert.equal(openrouterField({ error: 'openrouter-key-missing' }).status, 'not available');
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
  return {
    since: SINCE, until: UNTIL, codexDir: codex, ledgerFile: ledger,
    cost: { A: { bodies: [json('cost-report-page1.json'), json('cost-report-page2.json')] } },
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
  const r = buildRecord(fullInputs({ cost: { A: { error: 'admin-key-missing' } }, ledgerFile: join(T, 'gone.jsonl') }));
  assert.equal(r.fields.api_cost.status, 'not available');
  assert.equal(r.fields.claude_bank.status, 'not available');
  for (const n of ['api_cost', 'claude_bank']) assert.ok(r.fields[n].source, `${n} keeps its source mark`);
  assert.equal(r.fields.codex_tokens.status, 'ok');
  assert.equal(r.fields.codex_bank.status, 'ok');
  assert.equal(r.fields.openrouter.status, 'ok');
  assert.ok(!JSON.stringify(r).includes('"value":0,'), 'a missing source is never zero');
});

test('record: a reader that throws is caught per field, not for the record', () => {
  const r = buildRecord(fullInputs({ openrouter: { body: { data: null } }, cost: null }));
  assert.equal(r.fields.openrouter.status, 'not available');
  assert.equal(r.fields.api_cost.status, 'not available');
  assert.equal(r.fields.codex_tokens.status, 'ok');
});

test('cli: file sources produce the record on stdout and the key is never printed', () => {
  const inputs = fullInputs();
  const env = { PATH: process.env.PATH, HOME: join(T, 'home'), HIMMEL_DOTENV_FILE: join(T, 'no-dotenv'), ANTHROPIC_ORG_A_KEY: DUMMY, OPENROUTER_API_KEY: 'sk-or-dummy' };
  const r = spawnSync(process.execPath, [CLI, '--since', SINCE, '--until', UNTIL,
    '--codex-sessions', inputs.codexDir, '--cadence-ledger', inputs.ledgerFile,
    '--cost-report-file', `A=${join(FIX, 'cost-report-page1.json')}`, '--cost-report-file', `A=${join(FIX, 'cost-report-page2.json')}`,
    '--openrouter-key-file', join(FIX, 'openrouter-key.json')], { encoding: 'utf8', env });
  assert.equal(r.status, 0, r.stderr);
  const rec = JSON.parse(r.stdout);
  assert.equal(rec.fields.api_cost.value, '1.352892');
  assert.equal(rec.fields.openrouter.usage_total, 25.5);
  assert.ok(!r.stdout.includes(DUMMY) && !r.stderr.includes(DUMMY) && !r.stdout.includes('sk-or-dummy'));
});

test('cli: with no source given and no --live, the API fields read not available and nothing is fetched', () => {
  const inputs = fullInputs();
  const r = spawnSync(process.execPath, [CLI, '--since', SINCE, '--until', UNTIL,
    '--codex-sessions', inputs.codexDir, '--cadence-ledger', inputs.ledgerFile], { encoding: 'utf8', env: { PATH: process.env.PATH, HOME: join(T, 'home') } });
  assert.equal(r.status, 0, r.stderr);
  const rec = JSON.parse(r.stdout);
  assert.equal(rec.fields.api_cost.status, 'not available');
  assert.equal(rec.fields.openrouter.status, 'not available');
  assert.equal(rec.fields.codex_tokens.status, 'ok');
});

test('cli: --live with no keys keeps both accounts in the record as unavailable and fetches nothing', () => {
  const inputs = fullInputs();
  const env = { PATH: process.env.PATH, HOME: join(T, 'home'), HIMMEL_DOTENV_FILE: join(T, 'no-dotenv') };
  const r = spawnSync(process.execPath, [CLI, '--since', SINCE, '--until', UNTIL, '--codex-sessions', inputs.codexDir, '--cadence-ledger', inputs.ledgerFile, '--live'], { encoding: 'utf8', env });
  assert.equal(r.status, 0, r.stderr);
  const rec = JSON.parse(r.stdout);
  assert.deepEqual(rec.fields.api_cost.per_account, { A: 'not available', B: 'not available' });
  assert.equal(rec.fields.openrouter.status, 'not available');
});

test('cli: a bad window is refused', () => {
  for (const args of [['--since', 'yesterday', '--until', UNTIL], ['--since', UNTIL, '--until', SINCE], ['--until', UNTIL]]) {
    const r = spawnSync(process.execPath, [CLI, ...args], { encoding: 'utf8', env: { PATH: process.env.PATH, HOME: join(T, 'home') } });
    assert.equal(r.status, 2, args.join(' '));
  }
});
