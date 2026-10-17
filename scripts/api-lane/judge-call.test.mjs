// Judge-call bridge fixtures. Dummy key and a stub claude only: no provider call, no real
// credential. Breaks caught: a stale or missing verdict recorded as a ruling, a tool denial hidden behind
// rc=0, a verdict without evidence, a fallback to the subscription lane, an unbounded parent artifact,
// a tool grant wider than Read/Glob/Grep, a non-judgment-tier model.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const BRIDGE = join(HERE, 'judge-call.sh');
const T = mkdtempSync(join(tmpdir(), 'judge-call-'));
const SCRATCH = `/tmp/claude-${process.getuid()}`;
const made = [];
// write-verdict.sh wants the judge scratch root private; a runner that made it with umask 022 would refuse every record
mkdirSync(SCRATCH, { recursive: true, mode: 0o700 });
chmodSync(SCRATCH, 0o700);
process.on('exit', () => { rmSync(T, { recursive: true, force: true }); for (const d of made) rmSync(d, { recursive: true, force: true }); });
const DUMMY = 'sk-ant-dummy-not-a-real-key-0000';
const HEAD = 'a'.repeat(40);
const OLD = 'b'.repeat(40);
// each case gets its own PR number so the real judge-dir under /tmp/claude-<uid> never collides
let nextPr = 100000000 + process.pid * 10;

const STUB = `#!/bin/bash
echo called >> "$STUB_LOG"
echo "args=$*" > "$STUB_ENV"
echo "cwd=$PWD" >> "$STUB_ENV"
while [ -n "\${STUB_HOLD:-}" ] && [ -e "$STUB_HOLD" ]; do sleep 0.05; done
printf '%s' "$STUB_OUT"
exit "\${STUB_RC:-0}"
`;

const result = (text, extra = {}) => JSON.stringify({ type: 'result', subtype: 'success', is_error: false,
  total_cost_usd: 0.031415, result: text, permission_denials: [], ...extra });
const go = (head = HEAD, body = 'Checked scripts/x.sh:10.\nRuling: sound.') => `**GO** for head \`${head}\`.\n\n${body}\n`;

function fixture() {
  const dir = mkdtempSync(join(T, 'case-'));
  const now = Math.floor(Date.now() / 1000);
  const state = join(dir, 'ledger.json');
  const config = { version: 1, ledger_path: state, accounts: {
    A: { organization_id: 'org-a', cycle_id: 'cycle-a', cap_usd: '1.00', key_id: 'key-a' },
    B: { organization_id: 'org-b', cycle_id: 'cycle-b', cap_usd: '2.00', key_id: 'key-b' },
  } };
  const snapshot = { version: 1, accounts: Object.fromEntries(['A', 'B'].map((account) => [account, {
    organization_id: config.accounts[account].organization_id, cycle_id: config.accounts[account].cycle_id,
    grant_usd: '2.00', remaining_usd: '2.00', reconciled_spent_usd: '0',
    starts_at: now - 1000, expires_at: now + 3600, observed_at: now,
    source: 'operator-console-snapshot', exclusive_org: true, discrepancy: false,
  }])) };
  const p = { config: join(dir, 'config.json'), snapshot: join(dir, 'snapshot.json'), state,
    stub: join(dir, 'claude-stub'), log: join(dir, 'stub.log'), env: join(dir, 'stub.env'), ps: join(dir, 'ps'),
    q: join(dir, 'question.md'), hold: join(dir, 'hold') };
  writeFileSync(p.config, JSON.stringify(config));
  writeFileSync(p.snapshot, JSON.stringify(snapshot));
  writeFileSync(p.stub, STUB, { mode: 0o700 });
  writeFileSync(p.ps, '#!/bin/bash\nexit 0\n', { mode: 0o700 });
  writeFileSync(p.q, 'Is the change in scripts/x.sh sound? Read it and rule.\n');
  mkdirSync(join(dir, '.config', 'himmel'), { recursive: true });
  writeFileSync(join(dir, '.config', 'himmel', 'go-hmac.key'), `${'0123456789abcdef'.repeat(4)}\n`, { mode: 0o600 });
  const root = join(dir, 'root');
  mkdirSync(root);
  const pr = nextPr++;
  const env = { PATH: process.env.PATH, HOME: dir, TMPDIR: dir, USER_SLUG: 'tuser', HANDOVER_DIR: root,
    HIMMEL_API_CREDIT_CONFIG: p.config, HIMMEL_API_CREDIT_SNAPSHOT: p.snapshot,
    HIMMEL_API_CREDIT_STATE: state, HIMMEL_API_LANE: 'on', HIMMEL_API_ACCOUNT: 'A',
    HIMMEL_API_KEY_ID: 'key-a', ANTHROPIC_API_KEY: DUMMY, HIMMEL_API_CLAUDE_BIN: p.stub,
    STUB_LOG: p.log, STUB_ENV: p.env, STUB_OUT: result(go()),
    HIMMEL_FLEET_CAP: '4', HIMMEL_FLEET_SLOTS: join(dir, 'slots'), FLEET_PS_CMD: p.ps, FLEET_PROC: dir,
    CADENCE_BANK_LEDGER: join(dir, 'bank-ledger'), CADENCE_BANK_SKIP_REFRESH: '1',
    CADENCE_BANK_CACHE: join(dir, 'native-cache.json') };
  writeFileSync(env.CADENCE_BANK_CACHE, JSON.stringify({ five_hour: { utilization: 100 }, seven_day: { utilization: 100 } }));
  const args = ['--qid', `q${pr}`, '--pr', String(pr), '--head', HEAD, '--question-file', p.q,
    '--model', 'claude-opus-5-5', '--max-budget-usd', '0.10'];
  const run = (over = args, extra = {}) => {
    const r = spawnSync('bash', [BRIDGE, ...over], { env: { ...env, ...extra }, encoding: 'utf8' });
    made.push(join(SCRATCH, `j${pr}`));
    const out = r.stdout.trim();
    return { ...r, art: out && existsSync(out) ? JSON.parse(readFileSync(out, 'utf8')) : null, artPath: out };
  };
  const ledger = () => JSON.parse(readFileSync(state, 'utf8'));
  return { dir, root, pr, p, env, args, run, ledger, called: () => existsSync(p.log) };
}

test('a recorded GO: artifact names the verdict file, the cost and a bounded excerpt; the grant is Read,Glob,Grep only', () => {
  const f = fixture();
  const r = f.run(f.args, { HIMMEL_API_TOOLS: 'Bash,Write' });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.art.status, 'RECORDED');
  assert.equal(r.art.verdict, 'GO');
  assert.equal(r.art.head, HEAD);
  assert.equal(r.art.cost_usd, '0.031415');
  assert.equal(r.art.model, 'claude-opus-5-5');
  assert.match(r.art.excerpt, /Ruling: sound/);
  const rec = readFileSync(r.art.verdict_path, 'utf8');
  assert.match(rec, /^\*\*GO\*\* for head `a{40}`\.$/m);
  assert.match(rec, /^pr: \d+$/m);
  assert.match(rec, /^mac: [0-9a-f]{64}$/m);
  assert.match(rec, /Checked scripts\/x\.sh:10\./);
  const seen = readFileSync(f.p.env, 'utf8');
  assert.match(seen, /--tools Read,Glob,Grep /);
  assert.match(seen, /--allowedTools Read,Glob,Grep /);
  assert.match(seen, /--strict-mcp-config/);
  assert.doesNotMatch(seen, /Bash|Write|Edit/);
  assert.match(seen, /--permission-mode dontAsk/);
  assert.match(seen, /--model claude-opus-5-5/);
  assert.match(seen, /--max-budget-usd 0\.10/);
  assert.doesNotMatch(seen, /^cwd=.*himmel/m);
  assert.match(readFileSync(join(f.dir, 'launches.jsonl'), 'utf8'), /"kind":"judge"/);
});

test('a verdict naming another head is STALE: nothing is written to the verdict store', () => {
  const f = fixture();
  const r = f.run(f.args, { STUB_OUT: result(go(OLD)) });
  assert.equal(r.status, 3);
  assert.equal(r.art.status, 'STALE');
  assert.equal(r.art.verdict_head, OLD);
  assert.equal(r.art.verdict_path, null);
  assert.equal(existsSync(join(f.root, 'tuser')), false);
});

test('a reply with no verdict first line is MISSING; so is a verdict with no evidence', () => {
  const f = fixture();
  for (const text of ['I think this is fine.\n**GO** for head `' + HEAD + '`.', `**GO** for head \`${HEAD}\`.\n`, `**GO**\nsound`, '',
    `\n**GO** for head \`${HEAD}\`.\nevidence`]) {
    const r = f.run(f.args, { STUB_OUT: result(text) });
    assert.equal(r.status, 3, text);
    assert.equal(r.art.status, 'MISSING', text);
    assert.equal(r.art.verdict_path, null);
  }
});

test('a retry on the same qid never shows the previous call\'s evidence', () => {
  const f = fixture();
  const first = f.run(f.args, { STUB_OUT: result(`**NO-GO** for head \`${HEAD}\`.\n\nthe parser drops an option`) });
  assert.equal(first.art.status, 'UNRECORDED');
  assert.notEqual(first.art.excerpt, '');
  const retry = f.run(f.args, { STUB_OUT: result('no verdict here') });
  assert.equal(retry.art.status, 'MISSING');
  assert.equal(retry.art.excerpt, '');
});

test('a tool denial is DENIED even though the call returned rc=0 with a well-formed GO', () => {
  const f = fixture();
  const r = f.run(f.args, { STUB_OUT: result(go(), { permission_denials: [{ tool_name: 'Bash', tool_input: { command: 'ls' } }] }) });
  assert.equal(r.status, 3);
  assert.equal(r.art.status, 'DENIED');
  assert.match(r.art.reason, /Bash/);
  assert.equal(r.art.verdict_path, null);
});

test('a denial is DENIED even when the same result is an error', () => {
  const f = fixture();
  const r = f.run(f.args, { STUB_OUT: result('', { is_error: true, subtype: 'error_during_execution', permission_denials: [{ tool_name: 'Bash' }] }) });
  assert.equal(r.art.status, 'DENIED');
  assert.equal(r.art.cost_usd, '0.031415');
});

test('a denial is DENIED on a non-zero exit too, and records nothing', () => {
  const f = fixture();
  const r = f.run(f.args, { STUB_RC: '1', STUB_OUT: result(go(), { permission_denials: [{ tool_name: 'Bash' }] }) });
  assert.equal(r.status, 3);
  assert.equal(r.art.status, 'DENIED');
  assert.equal(r.art.verdict_path, null);
});

test('evidence over the cap is never recorded cut: ERROR, nothing written to the verdict dir', () => {
  const f = fixture();
  const r = f.run(f.args, { STUB_OUT: result(go(HEAD, 'x'.repeat(40000))) });
  assert.equal(r.status, 3);
  assert.equal(r.art.status, 'ERROR');
  assert.match(r.art.reason, /evidence/);
  assert.equal(r.art.verdict_path, null);
});

test('an error result is ERROR, and the cost still reaches the artifact', () => {
  const f = fixture();
  const r = f.run(f.args, { STUB_OUT: result('', { is_error: true, subtype: 'error_max_budget_usd' }) });
  assert.equal(r.status, 3);
  assert.equal(r.art.status, 'ERROR');
  assert.equal(r.art.cost_usd, '0.031415');
});

test('a non-zero exit with a JSON error result keeps the cost and the reason, and never records a verdict', () => {
  const f = fixture();
  const r = f.run(f.args, { STUB_RC: '1', STUB_OUT: result(go(), { is_error: true, subtype: 'error_max_budget_usd' }) });
  assert.equal(r.status, 3);
  assert.equal(r.art.status, 'ERROR');
  assert.equal(r.art.cost_usd, '0.031415');
  assert.match(r.art.reason, /error_max_budget_usd/);
  assert.equal(r.art.verdict_path, null);
  assert.equal(r.art.excerpt, '');
});

test('a NO-GO without the class field is UNRECORDED; one with it is recorded', () => {
  const f = fixture();
  const bad = f.run(f.args, { STUB_OUT: result(`**NO-GO** for head \`${HEAD}\`.\n\nthe parser drops an option`) });
  assert.equal(bad.status, 3);
  assert.equal(bad.art.status, 'UNRECORDED');
  assert.match(bad.art.reason, /class/);
  const g = fixture();
  const ok = g.run(g.args, { STUB_OUT: result(`**NO-GO** for head \`${HEAD}\`.\n\nclass: option-parsing\n\nthe parser drops an option`) });
  assert.equal(ok.status, 0, ok.stderr);
  assert.equal(ok.art.status, 'RECORDED');
  assert.equal(ok.art.verdict, 'NO-GO');
});

test('the prompt tells the judge a class other needs a class-reason line', () => {
  const f = fixture();
  f.run(f.args);
  assert.match(readFileSync(f.p.env, 'utf8'), /class-reason: <why>/);
});

test('a refused launch is final: REFUSED, claude never called, no subscription fallback', () => {
  const f = fixture();
  const r = f.run(f.args, { HIMMEL_API_LANE: 'off' });
  assert.equal(r.status, 3);
  assert.equal(r.art.status, 'REFUSED');
  assert.match(r.art.reason, /api lane is OFF/);
  assert.equal(f.called(), false);
  assert.equal(r.art.verdict_path, null);
});

test('a timed-out call is TIMEOUT and its reservation stays held in the ledger', () => {
  const f = fixture();
  writeFileSync(f.p.hold, '');
  const r = f.run([...f.args, '--timeout', '2'], { STUB_HOLD: f.p.hold, QMD_KILL_GRACE_SECS: '1' });
  assert.equal(r.status, 3, r.stderr);
  assert.equal(r.art.status, 'TIMEOUT');
  assert.equal(r.art.verdict_path, null);
  const jobs = Object.values(f.ledger().accounts.A.jobs);
  assert.equal(jobs.length, 1);
  assert.notEqual(jobs[0].status, 'settled');
});

test('the parent artifact excerpt is bounded however long the recorded evidence is', () => {
  const f = fixture();
  const r = f.run(f.args, { STUB_OUT: result(go(HEAD, 'x'.repeat(30000))) });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.art.excerpt_truncated, true);
  assert.ok(statSync(r.artPath).size < 12000, `artifact is ${statSync(r.artPath).size} bytes`);
});

test('argument policy: model tier, budget ceiling, question file and head are refused before any call', () => {
  const f = fixture();
  const swap = (flag, val) => f.args.map((a, i) => (f.args[i - 1] === flag ? val : a));
  const cases = [
    ['--model', 'claude-haiku-5-5'], ['--model', 'claude-fable-5-1'], ['--max-budget-usd', '5.00'],
    ['--max-budget-usd', '0'], ['--max-budget-usd', 'abc'], ['--head', 'abc123'], ['--question-file', join(f.dir, 'nope.md')],
    ['--pr', '07'], ['--qid', '../q'], ['--timeout', '00'], ['--timeout', '0'],
  ];
  for (const [flag, val] of cases) {
    const r = f.run(f.args.includes(flag) ? swap(flag, val) : [...f.args, flag, val]);
    assert.equal(r.status, 2, `${flag} ${val}: ${r.stderr}`);
  }
  assert.equal(f.called(), false);
  const noModel = f.run(f.args.filter((a, i) => !['--model', 'claude-opus-5-5'].includes(a) || (i > 100)));
  assert.equal(noModel.status, 2);
});
