// Bulk-call bridge fixtures. Dummy key and a stub claude only: no provider call, no real
// credential. Breaks caught: a leg or relay launching the call on its own authority, a tool grant wider than
// Read/Glob/Grep (or one that can spawn), a non-Haiku model or an over-ceiling budget, a site outside the asked
// files kept, a tool denial hidden behind rc=0, a reply that is not the JSON object kept, a cancel that leaves
// the call running, a fallback to the subscription lane.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const BRIDGE = join(HERE, 'bulk-call.sh');
const T = mkdtempSync(join(tmpdir(), 'bulk-call-'));
const SCRATCH = `/tmp/claude-${process.getuid()}`;
const made = [];
mkdirSync(SCRATCH, { recursive: true, mode: 0o700 });
chmodSync(SCRATCH, 0o700);
process.on('exit', () => { rmSync(T, { recursive: true, force: true }); for (const d of made) rmSync(d, { recursive: true, force: true }); });
const DUMMY = 'sk-ant-dummy-not-a-real-key-0000';
let nextId = process.pid * 10;

const STUB = `#!/bin/bash
[ -z "\${STUB_IGNORE_TERM:-}" ] || trap '' TERM
echo called >> "$STUB_LOG"
echo "args=$*" > "$STUB_ENV"
echo "cwd=$PWD" >> "$STUB_ENV"
while [ -n "\${STUB_HOLD:-}" ] && [ -e "$STUB_HOLD" ]; do sleep 0.05; done
printf '%s' "$STUB_OUT"
exit "\${STUB_RC:-0}"
`;

const result = (text, extra = {}) => JSON.stringify({ type: 'result', subtype: 'success', is_error: false,
  total_cost_usd: 0.004242, result: text, permission_denials: [], ...extra });

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
    cls: join(dir, 'class.md'), paths: join(dir, 'paths.txt'), hold: join(dir, 'hold'),
    a: join(dir, 'a.sh'), b: join(dir, 'b.sh') };
  writeFileSync(p.config, JSON.stringify(config));
  writeFileSync(p.snapshot, JSON.stringify(snapshot));
  writeFileSync(p.stub, STUB, { mode: 0o700 });
  writeFileSync(p.ps, '#!/bin/bash\nexit 0\n', { mode: 0o700 });
  writeFileSync(p.cls, 'An unquoted variable expansion in a test: [ $x = y ].\n');
  writeFileSync(p.a, 'echo one\n[ $x = y ]\n');
  writeFileSync(p.b, 'echo two\n');
  writeFileSync(p.paths, `${p.a}\n${p.b}\n`);
  const id = `t${nextId++}`;
  const env = { PATH: process.env.PATH, HOME: dir, TMPDIR: dir, USER_SLUG: 'tuser',
    HIMMEL_API_CREDIT_CONFIG: p.config, HIMMEL_API_CREDIT_SNAPSHOT: p.snapshot,
    HIMMEL_API_CREDIT_STATE: state, HIMMEL_API_LANE: 'on', HIMMEL_API_ACCOUNT: 'A',
    HIMMEL_API_KEY_ID: 'key-a', ANTHROPIC_API_KEY: DUMMY, HIMMEL_API_CLAUDE_BIN: p.stub,
    STUB_LOG: p.log, STUB_ENV: p.env, STUB_OUT: result(JSON.stringify({ sites: [{ file: p.a, line: 2, why: 'unquoted $x' }] })),
    HIMMEL_FLEET_CAP: '4', HIMMEL_FLEET_SLOTS: join(dir, 'slots'), FLEET_PS_CMD: p.ps, FLEET_PROC: dir,
    CADENCE_BANK_LEDGER: join(dir, 'bank-ledger'), CADENCE_BANK_SKIP_REFRESH: '1',
    CADENCE_BANK_CACHE: join(dir, 'native-cache.json') };
  writeFileSync(env.CADENCE_BANK_CACHE, JSON.stringify({ five_hour: { utilization: 100 }, seven_day: { utilization: 100 } }));
  const args = ['--task-id', id, '--class-file', p.cls, '--paths-file', p.paths,
    '--model', 'claude-haiku-5-5', '--max-budget-usd', '0.05'];
  made.push(join(SCRATCH, `bulk-${id}`), join(SCRATCH, `bulk-${id}.lock`));
  const read = (out) => (out && existsSync(out) ? JSON.parse(readFileSync(out, 'utf8')) : null);
  const run = (over = args, extra = {}) => {
    const r = spawnSync('bash', [BRIDGE, ...over], { env: { ...env, ...extra }, encoding: 'utf8' });
    const out = r.stdout.trim();
    return { ...r, art: read(out), artPath: out };
  };
  const ledger = () => JSON.parse(readFileSync(state, 'utf8'));
  return { dir, id, p, env, args, run, read, ledger, called: () => existsSync(p.log) };
}

test('an OK call: sites kept, cost and model in the artifact, grant is Read,Glob,Grep only, bulk kind', () => {
  const f = fixture();
  const r = f.run(f.args, { HIMMEL_API_TOOLS: 'Bash,Write', HIMMEL_API_KIND: 'judge' });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.art.status, 'OK');
  assert.deepEqual(r.art.sites, [{ file: f.p.a, line: 2, why: 'unquoted $x' }]);
  assert.equal(r.art.site_count, 1);
  assert.equal(r.art.cost_usd, '0.004242');
  assert.equal(r.art.model, 'claude-haiku-5-5');
  const seen = readFileSync(f.p.env, 'utf8');
  assert.match(seen, /--tools Read,Glob,Grep /);
  assert.match(seen, /--allowedTools Read,Glob,Grep /);
  assert.match(seen, /--strict-mcp-config/);
  assert.doesNotMatch(seen.slice(seen.indexOf(' --model ')), /Bash|Write|Edit|Agent|Task/);
  assert.match(seen, /--permission-mode dontAsk/);
  assert.match(seen, /--model claude-haiku-5-5/);
  assert.match(seen, /--max-budget-usd 0\.05/);
  assert.doesNotMatch(seen, /^cwd=.*himmel/m);
  assert.match(readFileSync(join(f.dir, 'launches.jsonl'), 'utf8'), /"kind":"bulk"/);
});

test('trusted dispatch: a console leg or a relay is refused before any call', () => {
  for (const v of ['HIMMEL_CONSOLE_LEG', 'HIMMEL_CONSOLE_RELAY']) {
    const f = fixture();
    const r = f.run(f.args, { [v]: '1' });
    assert.equal(r.status, 4, `${v}: ${r.stderr}`);
    assert.match(r.stderr, /refusing/);
    assert.equal(f.called(), false);
    assert.equal(existsSync(join(f.dir, 'ledger.json')), false);
  }
});

test('argument policy: model tier, budget ceiling, paths and class file are refused before any call', () => {
  const f = fixture();
  const swap = (flag, val) => f.args.map((a, i) => (f.args[i - 1] === flag ? val : a));
  const cases = [
    swap('--model', 'claude-opus-5-5'), swap('--model', 'claude-sonnet-5-5'),
    swap('--max-budget-usd', '0.06'), swap('--max-budget-usd', '0'), swap('--max-budget-usd', '-1'),
    swap('--task-id', '../x'), [...f.args, '--timeout', '0'],
    [...f.args, '--bogus', 'x'],
  ];
  for (const a of cases) {
    const r = f.run(a);
    assert.equal(r.status, 2, `${a.join(' ')}: ${r.stderr}`);
  }
  const rel = join(f.dir, 'rel.txt');
  writeFileSync(rel, 'relative/path.sh\n');
  assert.equal(f.run(swap('--paths-file', rel)).status, 2);
  const dots = join(f.dir, 'dots.txt');
  writeFileSync(dots, `${f.dir}/../${f.dir.split('/').pop()}/a.sh\n`);
  assert.equal(f.run(swap('--paths-file', dots)).status, 2);
  const link = join(f.dir, 'link.sh');
  symlinkSync(f.p.a, link);
  writeFileSync(rel, `${link}\n`);
  assert.equal(f.run(swap('--paths-file', rel)).status, 2);
  writeFileSync(rel, `${join(f.dir, 'missing.sh')}\n`);
  assert.equal(f.run(swap('--paths-file', rel)).status, 2);
  writeFileSync(rel, '');
  assert.equal(f.run(swap('--paths-file', rel)).status, 2);
  writeFileSync(rel, Array.from({ length: 41 }, () => f.p.a).join('\n'));
  assert.equal(f.run(swap('--paths-file', rel)).status, 2);
  assert.equal(f.called(), false);
});

test('a site naming a file that was not asked about is INVALID and no site is kept', () => {
  const f = fixture();
  const out = result(JSON.stringify({ sites: [{ file: f.p.a, line: 2, why: 'ok' }, { file: '/etc/passwd', line: 1, why: 'x' }] }));
  const r = f.run(f.args, { STUB_OUT: out });
  assert.equal(r.status, 3);
  assert.equal(r.art.status, 'INVALID');
  assert.deepEqual(r.art.sites, []);
});

test('a reply that is not the JSON object, or has a bad line, is INVALID', () => {
  for (const text of ['I found a site in a.sh line 2.', JSON.stringify({ nope: 1 }),
    JSON.stringify({ sites: [{ file: '/x', line: 0, why: '' }] })]) {
    const f = fixture();
    const r = f.run(f.args, { STUB_OUT: result(text) });
    assert.equal(r.art.status, 'INVALID', text);
    assert.equal(r.status, 3);
  }
  const f = fixture();
  const bad = result(JSON.stringify({ sites: [{ file: f.p.a, line: 1.5, why: '' }] }));
  assert.equal(f.run(f.args, { STUB_OUT: bad }).art.status, 'INVALID');
});

test('a fenced JSON reply is accepted; an empty sites array is a valid answer', () => {
  const f = fixture();
  const fenced = result(`\`\`\`json\n${JSON.stringify({ sites: [{ file: f.p.b, line: 1, why: 'w' }] })}\n\`\`\``);
  const r = f.run(f.args, { STUB_OUT: fenced });
  assert.equal(r.art.status, 'OK');
  assert.equal(r.art.site_count, 1);
  const g = fixture();
  const e = g.run(g.args, { STUB_OUT: result('{"sites":[]}') });
  assert.equal(e.status, 0);
  assert.equal(e.art.site_count, 0);
});

test('a tool denial is DENIED whatever the exit code, and no site is kept', () => {
  const f = fixture();
  const out = result(JSON.stringify({ sites: [{ file: f.p.a, line: 2, why: 'x' }] }), { permission_denials: [{ tool_name: 'Bash' }] });
  const r = f.run(f.args, { STUB_OUT: out });
  assert.equal(r.status, 3);
  assert.equal(r.art.status, 'DENIED');
  assert.deepEqual(r.art.sites, []);
});

test('a claude error result keeps its cost but is ERROR with no sites', () => {
  const f = fixture();
  const r = f.run(f.args, { STUB_OUT: result('', { is_error: true, subtype: 'error_max_budget_usd' }), STUB_RC: '1' });
  assert.equal(r.status, 3);
  assert.equal(r.art.status, 'ERROR');
  assert.equal(r.art.cost_usd, '0.004242');
  assert.deepEqual(r.art.sites, []);
});

test('the lane OFF is REFUSED: the stub never runs and there is no subscription fallback', () => {
  const f = fixture();
  const r = f.run(f.args, { HIMMEL_API_LANE: 'off' });
  assert.equal(r.status, 3);
  assert.equal(r.art.status, 'REFUSED');
  assert.equal(f.called(), false);
});

test('a timed-out call is TIMEOUT and its reservation stays held in the ledger', () => {
  const f = fixture();
  writeFileSync(f.p.hold, '');
  const r = f.run([...f.args, '--timeout', '2'], { STUB_HOLD: f.p.hold, QMD_KILL_GRACE_SECS: '1' });
  assert.equal(r.status, 3, r.stderr);
  assert.equal(r.art.status, 'TIMEOUT');
  const jobs = Object.values(f.ledger().accounts.A.jobs);
  assert.equal(jobs.length, 1);
  assert.notEqual(jobs[0].status, 'settled');
});

test('--cancel stops a running call: CANCELLED, the stub is gone, the reservation stays held', async () => {
  const f = fixture();
  writeFileSync(f.p.hold, '');
  const child = spawn('bash', [BRIDGE, ...f.args, '--timeout', '60'], { env: { ...f.env, STUB_HOLD: f.p.hold }, stdio: ['ignore', 'pipe', 'pipe'] });
  let out = '';
  child.stdout.on('data', (d) => { out += d; });
  const closed = new Promise((res) => child.on('close', (code) => res(code)));
  for (let i = 0; i < 100 && !existsSync(f.p.log); i++) await new Promise((r) => setTimeout(r, 100));
  assert.ok(existsSync(f.p.log), 'the call never started');
  const c = spawnSync('bash', [BRIDGE, '--cancel', f.id], { env: f.env, encoding: 'utf8' });
  assert.equal(c.status, 0, c.stderr);
  const code = await closed;
  assert.equal(code, 3);
  assert.equal(f.read(out.trim()).status, 'CANCELLED');
  const jobs = Object.values(f.ledger().accounts.A.jobs);
  assert.notEqual(jobs[0].status, 'settled');
  const gone = spawnSync('pgrep', ['-f', f.p.stub]);
  assert.notEqual(gone.status, 0, 'the stub claude is still running');
  assert.equal(spawnSync('bash', [BRIDGE, '--cancel', f.id], { env: f.env, encoding: 'utf8' }).status, 3);
});

test('the same task id cannot run twice at once', async () => {
  const f = fixture();
  writeFileSync(f.p.hold, '');
  const child = spawn('bash', [BRIDGE, ...f.args, '--timeout', '60'], { env: { ...f.env, STUB_HOLD: f.p.hold }, stdio: 'ignore' });
  for (let i = 0; i < 100 && !existsSync(f.p.log); i++) await new Promise((r) => setTimeout(r, 100));
  const second = f.run(f.args);
  assert.equal(second.status, 2);
  assert.match(second.stderr, /already running/);
  spawnSync('bash', [BRIDGE, '--cancel', f.id], { env: f.env });
  await new Promise((res) => child.on('close', res));
});

test('--cancel reaches a claude that ignores TERM (KILL after the grace)', async () => {
  const f = fixture();
  writeFileSync(f.p.hold, '');
  const child = spawn('bash', [BRIDGE, ...f.args, '--timeout', '60'], { env: { ...f.env, STUB_HOLD: f.p.hold, STUB_IGNORE_TERM: '1' }, stdio: 'ignore' });
  for (let i = 0; i < 100 && !existsSync(f.p.log); i++) await new Promise((r) => setTimeout(r, 100));
  assert.ok(existsSync(f.p.log), 'the call never started');
  assert.equal(spawnSync('bash', [BRIDGE, '--cancel', f.id], { env: f.env }).status, 0);
  await new Promise((res) => child.on('close', res));
  assert.notEqual(spawnSync('pgrep', ['-f', f.p.stub]).status, 0, 'the TERM-ignoring stub survived the cancel');
});

test('--cancel never signals a reused pid: a stale pid file with a free lock is no running task', () => {
  const f = fixture();
  const bystander = spawn('sleep', ['30'], { stdio: 'ignore' });
  mkdirSync(join(SCRATCH, `bulk-${f.id}`), { recursive: true });
  writeFileSync(join(SCRATCH, `bulk-${f.id}`, 'pid'), `${bystander.pid}\n`);
  writeFileSync(join(SCRATCH, `bulk-${f.id}.lock`), '');
  const c = spawnSync('bash', [BRIDGE, '--cancel', f.id], { env: f.env, encoding: 'utf8' });
  const alive = spawnSync('kill', ['-0', String(bystander.pid)]).status === 0;
  bystander.kill('SIGKILL');
  assert.equal(c.status, 3);
  assert.ok(alive, 'the unrelated process was signalled');
});

test('--cancel signals only the process that holds the task lock, not a pid the pid file merely names', async () => {
  const f = fixture();
  const bystander = spawn('sleep', ['30'], { stdio: 'ignore' });
  // Its own process group, so the kill below also takes flock's sleep child.
  const holder = spawn('flock', [join(SCRATCH, `bulk-${f.id}.lock`), 'sleep', '30'], { stdio: 'ignore', detached: true });
  mkdirSync(join(SCRATCH, `bulk-${f.id}`), { recursive: true });
  writeFileSync(join(SCRATCH, `bulk-${f.id}`, 'pid'), `${bystander.pid}\n`);
  await new Promise((r) => setTimeout(r, 500));
  const c = spawnSync('bash', [BRIDGE, '--cancel', f.id], { env: f.env, encoding: 'utf8' });
  const alive = spawnSync('kill', ['-0', String(bystander.pid)]).status === 0;
  bystander.kill('SIGKILL');
  process.kill(-holder.pid, 'SIGKILL');
  assert.equal(c.status, 3, c.stderr);
  assert.match(c.stderr, /not the lock holder/);
  assert.ok(alive, 'the pid named by the pid file was signalled');
});

test('trusted dispatch: a console leg or relay cannot cancel a running call either', async () => {
  const f = fixture();
  writeFileSync(f.p.hold, '');
  const child = spawn('bash', [BRIDGE, ...f.args, '--timeout', '60'], { env: { ...f.env, STUB_HOLD: f.p.hold }, stdio: 'ignore' });
  for (let i = 0; i < 100 && !existsSync(f.p.log); i++) await new Promise((r) => setTimeout(r, 100));
  assert.ok(existsSync(f.p.log), 'the call never started');
  for (const v of ['HIMMEL_CONSOLE_LEG', 'HIMMEL_CONSOLE_RELAY']) {
    const c = spawnSync('bash', [BRIDGE, '--cancel', f.id], { env: { ...f.env, [v]: '1' }, encoding: 'utf8' });
    assert.equal(c.status, 4, `${v}: ${c.stderr}`);
  }
  assert.equal(spawnSync('pgrep', ['-f', f.p.stub]).status, 0, 'the call was stopped by a refused cancel');
  assert.equal(spawnSync('bash', [BRIDGE, '--cancel', f.id], { env: f.env }).status, 0);
  await new Promise((res) => child.on('close', res));
});

test('a sites file that cannot be read back is ERROR, never an empty OK', () => {
  const f = fixture();
  const out = join(f.dir, 'art.json');
  const r = spawnSync('node', [join(HERE, 'bulk-result.mjs'), 'artifact', out, 'status=OK', 'task_id=x', '--sites', join(f.dir, 'missing.json')], { encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr);
  const a = JSON.parse(readFileSync(out, 'utf8'));
  assert.equal(a.status, 'ERROR');
  assert.equal(a.site_count, 0);
});
