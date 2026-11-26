// launcher fixtures. Dummy key and a stub claude only: no provider
// call, no real credential. Breaks caught: native-bank coupling, A/B fallback,
// credential/selector mismatch, provider-flag precedence, key leakage to
// non-API children, lost source metadata, settling unverified cost.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, utimesSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const LAUNCH = join(HERE, 'claude-api.sh');
const STRIP = join(HERE, 'strip-env.sh');
const MEASURE = join(HERE, 'measure-credit.sh');
const STATE = join(HERE, '..', 'lib', 'api-credit-state.mjs');
const T = mkdtempSync(join(tmpdir(), 'claude-api-'));
process.on('exit', () => rmSync(T, { recursive: true, force: true }));
const DUMMY = 'sk-ant-dummy-not-a-real-key-0000';

// A run with no API key is the subscription fallback: it logs to the .fb files and answers STUB_FB_OUT / STUB_FB_RC.
const STUB = `#!/bin/bash
FB=""; [ -n "\${ANTHROPIC_API_KEY:-}" ] || FB=.fb
echo called >> "$STUB_LOG$FB"
[ -n "$FB" ] || echo "\${ANTHROPIC_API_KEY: -4}" >> "$STUB_LOG.keys"
if [ -n "\${STUB_STDIN:-}" ]; then
  cat > "$STUB_STDIN$FB"
  for p in "$TMPDIR"/claude-api-prompt.*; do [ -e "$p" ] && { stat -c %a "$p" 2>/dev/null || stat -f %Lp "$p"; } >> "$STUB_STDIN$FB.mode"; done
fi
if [ -n "$FB" ]; then env > "$STUB_ENV.fb.full"; printf '%s\\n' "$@" > "$STUB_ENV.fb.args"; fi
{ echo "key_present=$([ -n "\${ANTHROPIC_API_KEY:-}" ] && echo 1 || echo 0)"
  echo "base_url=\${ANTHROPIC_BASE_URL:-}"; echo "oauth=\${CLAUDE_CODE_OAUTH_TOKEN:-}"
  echo "use_bedrock=\${CLAUDE_CODE_USE_BEDROCK:-}"; echo "auth_token=\${ANTHROPIC_AUTH_TOKEN:-}"
  echo "lq_api=$(env | grep -c '^LQ_API_')"
  echo "key_tail=\${ANTHROPIC_API_KEY: -4}"; echo "lane_on=\${HIMMEL_API_LANE:-}"; echo "scrub=\${CLAUDE_CODE_SUBPROCESS_ENV_SCRUB:-}"; echo "cache_ttl=\${CLAUDE_CODE_PROMPT_CACHE_TTL:-}"
  echo "launch_markers=$(env | grep -c '^FLEET_LAUNCH_')"
  echo "session_markers=$(env | grep -E '^(CLAUDECODE|AI_AGENT|CLAUDE_PID|CLAUDE_EFFORT|CLAUDE_JOB_DIR|CLAUDE_CODE_[A-Z0-9_]*)=' | grep -vc '^CLAUDE_CODE_\\(SUBPROCESS_ENV_SCRUB\\|PROMPT_CACHE_TTL\\)=')"
  echo "org_keys=$(env | grep -c '^ANTHROPIC_ORG_[AB]_KEY=')"
  echo "stub_pid=$$"; echo "ppid=$PPID"; echo "resv_pid=$(cat "$HIMMEL_FLEET_SLOTS/claude-api:\${HIMMEL_API_JOB_ID:-}/pid" 2>/dev/null)"
  echo "args=$*"; } > "$STUB_ENV$FB"
while [ -n "$FB" ] && [ -n "\${STUB_FB_HOLD:-}" ] && [ -e "$STUB_FB_HOLD" ]; do sleep 0.05; done
if [ -n "$FB" ]; then printf '%s' "\${STUB_FB_OUT:-$STUB_OUT}"; exit "\${STUB_FB_RC:-0}"; fi
[ -z "\${STUB_IGNORE_TERM:-}" ] || trap '' TERM
[ -z "\${STUB_CHILD:-}" ] || { sleep 300 & echo "child_pid=$!" >> "$STUB_ENV"; }
while [ -n "\${STUB_HOLD:-}" ] && [ -e "$STUB_HOLD" ]; do sleep 0.05; done
case ",\${STUB_DEAD_TAILS:-}," in *",\${ANTHROPIC_API_KEY: -4},"*) printf '%s' "$STUB_DEAD_OUT"; exit 1 ;; esac
printf '%s' "$STUB_OUT"
[ -z "\${STUB_DIE:-}" ] || kill -9 $$
[ -z "\${STUB_TERM:-}" ] || { ( sleep 0.05; kill -TERM "$PPID" ) </dev/null >/dev/null 2>&1 & kill -TERM $$; }
exit "\${STUB_RC:-0}"
`;

// A call carrying Claude Code session markers runs under a parent whose argv[0] is `claude`, as it does
// inside a real session. Without one, bank-preflight's seam guard refuses the fixture's seams
// on a tree that is its own primary checkout, as CI's is.
const SESSION_ARGV0 = 'claude';

// the auto gate compares the caller's git common dir with the launcher's own: this checkout, and an unrelated repo
const HIMMEL_REPO = dirname(dirname(dirname(fileURLToPath(import.meta.url))));
const OTHER_REPO = join(T, 'luna');
mkdirSync(OTHER_REPO, { recursive: true });
spawnSync('git', ['init', '-q', OTHER_REPO]);

function fixture() {
  const dir = mkdtempSync(join(T, 'case-'));
  const now = Math.floor(Date.now() / 1000);
  const state = join(dir, 'ledger.json');
  const config = { version: 1, ledger_path: state, accounts: {
    A: { organization_id: 'org-a', cycle_id: 'cycle-a', cap_usd: '1.00', key_id: 'key-a', reset_at: '2099-01-01T00:00:00Z' },
    B: { organization_id: 'org-b', cycle_id: 'cycle-b', cap_usd: '2.00', key_id: 'key-b', reset_at: '2099-01-01T00:00:00Z' },
  } };
  const snapshot = { version: 1, accounts: Object.fromEntries(['A', 'B'].map((account) => [account, {
    organization_id: config.accounts[account].organization_id, cycle_id: config.accounts[account].cycle_id,
    grant_usd: '2.00', remaining_usd: '2.00', reconciled_spent_usd: '0',
    starts_at: now - 1000, expires_at: now + 3600, observed_at: now,
    source: 'operator-console-snapshot', exclusive_org: true, discrepancy: false,
  }])) };
  const paths = { config: join(dir, 'config.json'), snapshot: join(dir, 'snapshot.json'), state,
    stub: join(dir, 'claude-stub'), log: join(dir, 'stub.log'), env: join(dir, 'stub.env'), ps: join(dir, 'ps'),
    alert: join(dir, 'alert-stub'), alertLog: join(dir, 'alert.log') };
  const save = () => {
    writeFileSync(paths.config, JSON.stringify(config));
    writeFileSync(paths.snapshot, JSON.stringify(snapshot));
  };
  save();
  writeFileSync(paths.stub, STUB, { mode: 0o700 });
  // the alert sender is always this stub: no fixture can reach the real Telegram sender
  writeFileSync(paths.alert, `#!/bin/bash\n{ echo "type=$TG_NOTIFICATION_TYPE"; echo "msg=$TG_MESSAGE"; echo "repo=$TG_REPO_NAME"; echo "args=$*"; } >> '${paths.alertLog}'\nenv >> '${paths.alertLog}.env'\n[ -z "\${ALERT_TERM_PARENT:-}" ] || kill -TERM "$PPID"\nexit "\${ALERT_RC:-0}"\n`, { mode: 0o700 });
  writeFileSync(paths.ps, '#!/bin/bash\nexit 0\n', { mode: 0o700 });
  const ok = JSON.stringify({ type: 'result', is_error: false, total_cost_usd: 0.012345, result: 'hi' });
  const env = { PATH: process.env.PATH, HOME: dir, TMPDIR: dir,
    HIMMEL_API_CREDIT_CONFIG: paths.config, HIMMEL_API_CREDIT_SNAPSHOT: paths.snapshot,
    HIMMEL_API_CREDIT_STATE: state, HIMMEL_API_LANE: 'on', HIMMEL_API_ACCOUNT: 'A',
    HIMMEL_API_KEY_ID: 'key-a', ANTHROPIC_API_KEY: DUMMY, HIMMEL_API_CLAUDE_BIN: paths.stub,
    HIMMEL_API_JOB_ID: 'job-1', STUB_LOG: paths.log, STUB_ENV: paths.env, STUB_OUT: ok,
    HIMMEL_FLEET_CAP: '4', HIMMEL_POLICY_FOLLOWS_HOME: '1', HIMMEL_FLEET_SLOTS: join(dir, 'slots'), FLEET_PS_CMD: paths.ps, FLEET_PROC: dir,
    CADENCE_USAGE_LEDGER: join(dir, 'bank-ledger'), CADENCE_USAGE_SKIP_REFRESH: '1',
    CADENCE_USAGE_CACHE: join(dir, 'native-cache.json'),
    HIMMEL_API_FALLBACK: 'off', HIMMEL_API_ALERT_CMD: paths.alert, HIMMEL_API_ALERT_DIR: join(dir, 'alerts') };
  writeFileSync(env.CADENCE_USAGE_CACHE, JSON.stringify({ five_hour: { utilization: 100 }, seven_day: { utilization: 100 } }));
  const good = ['-p', 'say hi', '--model', 'claude-haiku-5-5', '--permission-mode', 'plan', '--max-budget-usd', '0.10'];
  const run = (args = good, extra = {}, opts = {}) => spawnSync('bash', [LAUNCH, ...args], {
    env: Object.fromEntries(Object.entries({ ...env, ...extra }).filter(([, v]) => v !== undefined)), encoding: 'utf8', cwd: HIMMEL_REPO, ...opts });
  const status = (account = 'A') => {
    const r = spawnSync(process.execPath, [STATE, 'status'], { env: { ...env, HIMMEL_API_ACCOUNT: account }, encoding: 'utf8' });
    return JSON.parse(r.stdout);
  };
  const called = () => existsSync(paths.log);
  const record = () => readFileSync(join(dir, 'launches.jsonl'), 'utf8');
  return { dir, now, config, snapshot, paths, save, env, good, run, status, called, record };
}

function managedFixture(f, active = false) {
  const doc = join(f.dir, 'TEST-1-N1-api.md');
  const manifest = join(f.dir, 'chief.fleet.json');
  writeFileSync(doc, '# API fixture\n');
  const writer = join(HIMMEL_REPO, 'scripts/handover/chief-kit/fleet-manifest.sh');
  for (const args of [['control', 'init', manifest, '--target', '2'],
    ['add', manifest, doc, '--lane', 'native', '--pending'],
    ...(active ? [['control', 'set', manifest, '--mode', 'active', '--expect-gen', '1']] : [])]) {
    const r = spawnSync('bash', [writer, ...args], { env: f.env, encoding: 'utf8' });
    assert.equal(r.status, 0, r.stderr);
  }
  return { WORKER_SESSION_DOC: doc, FLEET_LAUNCH_MANIFEST: manifest, CADENCE_USAGE_WORKER: 'TEST-1-N1-api' };
}

function managedEvidence(f, name, extra = {}) {
  if (!process.env.FLEET_RUNTIME_EVIDENCE) return;
  mkdirSync(process.env.FLEET_RUNTIME_EVIDENCE, { recursive: true });
  const receiptPath = join(f.dir, '.himmel/launch-refusals.jsonl');
  writeFileSync(join(process.env.FLEET_RUNTIME_EVIDENCE, `${name}.json`), JSON.stringify({
    control: JSON.parse(readFileSync(join(f.dir, 'fleet-control.json'))),
    manifest: JSON.parse(readFileSync(join(f.dir, 'chief.fleet.json'))),
    receipts: existsSync(receiptPath) ? readFileSync(receiptPath, 'utf8') : '', ...extra,
  }, null, 2));
}

test('managed API pause precedes credit, fallback and cap overrides', () => {
  const f = fixture();
  const managed = managedFixture(f);
  const r = f.run(f.good, { ...managed, FLEET_CAP_OK: '1', FLEET_CONTROL_HELD: 'true', HIMMEL_API_FALLBACK: 'on' });
  assert.equal(r.status, 10, r.stderr);
  assert.match(r.stderr, /fleet-paused/);
  assert.equal(f.called(), false);
  assert.equal(JSON.parse(readFileSync(managed.FLEET_LAUNCH_MANIFEST)).workers.length, 0);
  managedEvidence(f, 'api-paused');
});

test('managed funded API commits exact ownership and releases it on a terminal call', () => {
  const f = fixture();
  const managed = managedFixture(f, true);
  const r = f.run(f.good, managed);
  assert.equal(r.status, 0, r.stderr);
  assert.equal(JSON.parse(r.stdout).result, 'hi');
  assert.equal(f.called(), true);
  const control = JSON.parse(readFileSync(join(f.dir, 'fleet-control.json')));
  assert.match(readFileSync(f.paths.env, 'utf8'), /launch_markers=0/);
  assert.deepEqual(control.attempts, {});
  assert.equal(readdirSync(f.env.HIMMEL_FLEET_SLOTS).filter(n => !n.startsWith('.')).length, 0);
  const receipts = readFileSync(join(f.dir, '.himmel/launch-refusals.jsonl'), 'utf8').trim().split('\n').map(JSON.parse);
  assert.equal(new Set(receipts.map(r => r.attempt_id)).size, 1);
  assert.equal(receipts.at(-1).outcome, 'complete');
  assert.ok(receipts.at(-1).owner.boot);
  assert.ok(receipts.at(-1).owner.start);
  managedEvidence(f, 'api-complete');
});

test('managed API reservation racing pause in another chief refuses before the call', async () => {
  const f = fixture();
  const managed = managedFixture(f, true);
  const successor = join(f.dir, 'successor.fleet.json');
  writeFileSync(successor, readFileSync(managed.FLEET_LAUNCH_MANIFEST));
  const hold = join(f.dir, 'hold');
  const ready = join(f.dir, 'reserved');
  const hook = join(f.dir, 'admission-hook');
  writeFileSync(hold, '');
  writeFileSync(hook, `#!/bin/bash\n[ "$1" = admission-complete ] || exit 0\ntouch '${ready}'\nfor i in {1..400}; do [ -e '${hold}' ] || exit 0; sleep .02; done\nexit 1\n`, { mode: 0o700 });
  const child = spawn('bash', [LAUNCH, ...f.good], { env: { ...f.env, ...managed, FLEET_LAUNCH_MANIFEST: successor, FLEET_ADMIT_TEST_HOOK: hook }, stdio: 'ignore' });
  const done = new Promise(r => child.on('close', r));
  try {
    const until = Date.now() + 6000;
    while (!existsSync(ready) && Date.now() < until) await new Promise(r => setTimeout(r, 20));
    assert.ok(existsSync(ready), 'API preflight reached its real reservation barrier');
    const pause = spawnSync('bash', [join(HIMMEL_REPO, 'scripts/handover/chief-kit/fleet-manifest.sh'), 'control', 'set', managed.FLEET_LAUNCH_MANIFEST, '--mode', 'paused', '--expect-gen', '2'], { env: f.env, encoding: 'utf8' });
    assert.equal(pause.status, 0, pause.stderr);
    rmSync(hold);
    assert.equal(await done, 10);
    assert.equal(f.called(), false);
    assert.equal(readdirSync(f.env.HIMMEL_FLEET_SLOTS).filter(n => !n.startsWith('.')).length, 0);
    const owners = spawnSync('bash', [join(HIMMEL_REPO, 'scripts/handover/chief-kit/fleet-manifest.sh'), 'runtime', 'owners', '--manifest', managed.FLEET_LAUNCH_MANIFEST], { env: f.env, encoding: 'utf8' });
    assert.equal(owners.status, 0, owners.stderr);
    assert.deepEqual(JSON.parse(owners.stdout), []);
    managedEvidence(f, 'api-reservation-paused', { successor: JSON.parse(readFileSync(successor)) });
  } finally {
    rmSync(hold, { force: true });
    child.kill('SIGTERM');
    await done;
  }
});

test('managed API commitment is visible to pause until its terminal call is reaped', async () => {
  const f = fixture();
  const managed = managedFixture(f, true);
  const hold = join(f.dir, 'call-hold');
  writeFileSync(hold, '');
  const child = spawn('bash', [LAUNCH, ...f.good], { env: { ...f.env, ...managed, STUB_HOLD: hold }, stdio: 'ignore' });
  const done = new Promise(r => child.on('close', r));
  const writer = join(HIMMEL_REPO, 'scripts/handover/chief-kit/fleet-manifest.sh');
  try {
    const until = Date.now() + 6000;
    while (!f.called() && Date.now() < until) await new Promise(r => setTimeout(r, 20));
    assert.ok(f.called(), 'stub call started only after commitment');
    const pause = spawnSync('bash', [writer, 'control', 'set', managed.FLEET_LAUNCH_MANIFEST, '--mode', 'paused', '--expect-gen', '2'], { env: f.env, encoding: 'utf8' });
    assert.equal(pause.status, 0, pause.stderr);
    const ack = spawnSync('bash', [writer, 'control', 'ack', managed.FLEET_LAUNCH_MANIFEST], { env: f.env, encoding: 'utf8' });
    assert.equal(ack.status, 0, ack.stderr);
    assert.equal(JSON.parse(ack.stdout).quiescent, false);
    assert.equal(JSON.parse(ack.stdout).in_flight.length, 1);
    managedEvidence(f, 'api-in-flight-ack', { acknowledgement: JSON.parse(ack.stdout) });
    rmSync(hold);
    assert.equal(await done, 0);
  } finally {
    rmSync(hold, { force: true });
    child.kill('SIGTERM');
    await done;
  }
});

test('an API call from inside a live managed worker joins its attempt and leaves it live', () => {
  const f = fixture();
  const managed = managedFixture(f, true);
  const writer = join(HIMMEL_REPO, 'scripts/handover/chief-kit/fleet-manifest.sh');
  const runtime = (op) => spawnSync('bash', [writer, 'runtime', op, '--doc', managed.WORKER_SESSION_DOC, '--manifest', managed.FLEET_LAUNCH_MANIFEST,
    '--name', 'TEST-1-N1-api', '--attempt-id', 'worker', '--pid', String(process.pid)], { env: f.env, encoding: 'utf8' });
  assert.equal(runtime('begin').status, 0);
  const stamp = spawnSync('bash', [join(HIMMEL_REPO, 'scripts/lib/usage-preflight.sh')], { env: { ...f.env,
    FLEET_LAUNCH_DOC: managed.WORKER_SESSION_DOC, FLEET_LAUNCH_MANIFEST: managed.FLEET_LAUNCH_MANIFEST, FLEET_LAUNCH_ATTEMPT: 'worker',
    CADENCE_USAGE_LAUNCH: '1', CADENCE_USAGE_WORKER: 'TEST-1-N1-api', CADENCE_USAGE_CALLER_PID: String(process.pid),
    CADENCE_USAGE_LANE: 'native', CADENCE_USAGE_CACHE: join(f.dir, 'missing-cache') }, encoding: 'utf8' });
  assert.match(stamp.stdout, /PROCEED|BANK-STALE|BANK-UNKNOWN/, stamp.stderr);
  const commit = runtime('commit');
  assert.equal(commit.status, 0, commit.stderr);
  const before = JSON.parse(readFileSync(join(f.dir, 'fleet-control.json'))).attempts;
  const r = f.run(f.good, { ...managed, WORKER_SESSION_ATTEMPT_ID: 'worker' });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(f.called(), true);
  assert.deepEqual(JSON.parse(readFileSync(join(f.dir, 'fleet-control.json'))).attempts, before);
  assert.equal(before.worker.phase, 'committed');
});

// A managed call held open by the stub, then a TERM to its launcher. The hold file stays: only the launcher can end the call.
// Resolves once the launcher is gone, with its exit code and the pids of the stub and (STUB_CHILD) its subprocess.
async function termMidCall(f, managed, extra = {}) {
  const hold = join(f.dir, 'call-hold');
  writeFileSync(hold, '');
  const child = spawn('bash', [LAUNCH, ...f.good], { env: { ...f.env, ...managed, ...extra, STUB_HOLD: hold }, stdio: 'ignore' });
  const done = new Promise(r => child.on('close', r));
  try {
    const up = extra.STUB_CHILD ? /^child_pid=\d+$/m : /^args=/m;
    const ready = () => existsSync(f.paths.env) && up.test(readFileSync(f.paths.env, 'utf8'));
    const until = Date.now() + 15000;
    while (!ready() && Date.now() < until) await new Promise(r => setTimeout(r, 20));
    assert.ok(ready(), 'the call started after commitment');
    assert.deepEqual(Object.values(controlOf(f).attempts).map(a => a.phase), ['committed'], 'the attempt is committed while the call runs');
    const seen = readFileSync(f.paths.env, 'utf8');
    child.kill('SIGTERM');
    const code = await Promise.race([done, new Promise(r => setTimeout(() => r('hung'), 20000))]);
    return { code, stub: Number(/^stub_pid=(\d+)$/m.exec(seen)[1]), sub: Number(/^child_pid=(\d+)$/m.exec(seen)?.[1] ?? 0) };
  } finally {
    rmSync(hold, { force: true });
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
  }
}
const controlOf = (f) => JSON.parse(readFileSync(join(f.dir, 'fleet-control.json')));
const slotsOf = (f) => readdirSync(f.env.HIMMEL_FLEET_SLOTS).filter(n => !n.startsWith('.'));
const receiptsOf = (f) => readFileSync(join(f.dir, '.himmel/launch-refusals.jsonl'), 'utf8').trim().split('\n').map(JSON.parse);
function pausedAck(f, managed) {
  const writer = join(HIMMEL_REPO, 'scripts/handover/chief-kit/fleet-manifest.sh');
  const pause = spawnSync('bash', [writer, 'control', 'set', managed.FLEET_LAUNCH_MANIFEST, '--mode', 'paused', '--expect-gen', '2'], { env: f.env, encoding: 'utf8' });
  assert.equal(pause.status, 0, pause.stderr);
  const ack = spawnSync('bash', [writer, 'control', 'ack', managed.FLEET_LAUNCH_MANIFEST], { env: f.env, encoding: 'utf8' });
  assert.equal(ack.status, 0, ack.stderr);
  return JSON.parse(ack.stdout);
}

test('a managed API call stopped by TERM mid-call leaves no attempt, no slot and a quiescent pause', async () => {
  const f = fixture();
  const managed = managedFixture(f, true);
  const { code, stub } = await termMidCall(f, managed);
  try {
    assert.equal(code, 143);
    assert.equal(alive(stub), false, 'the call outlived its terminated launcher');
    assert.deepEqual(controlOf(f).attempts, {});
    assert.deepEqual(slotsOf(f), []);
    assert.equal(receiptsOf(f).at(-1).outcome, 'complete');
    const ack = pausedAck(f, managed);
    assert.equal(ack.quiescent, true);
    assert.deepEqual([ack.in_flight, ack.unknown], [[], []]);
  } finally { if (alive(stub)) process.kill(stub, 'SIGKILL'); }
});

test('a managed API call that ignores TERM and has a subprocess is ended by the KILL and leaves nothing behind', async () => {
  const f = fixture();
  const managed = managedFixture(f, true);
  const { code, stub, sub } = await termMidCall(f, managed, { STUB_IGNORE_TERM: '1', STUB_CHILD: '1' });
  try {
    assert.equal(code, 143);
    assert.equal(alive(stub), false, 'the call outlived its terminated launcher');
    assert.equal(alive(sub), false, 'a subprocess of the call outlived its terminated launcher');
    assert.deepEqual(controlOf(f).attempts, {});
    assert.deepEqual(slotsOf(f), []);
    assert.equal(pausedAck(f, managed).quiescent, true);
  } finally { for (const p of [stub, sub]) if (p && alive(p)) process.kill(p, 'SIGKILL'); }
});

test('a managed API call stopped by TERM with a process of its tree that stays in the table leaves the attempt unknown', async () => {
  const f = fixture();
  const managed = managedFixture(f, true);
  // The stop KILLs what TERM leaves, so no live process outlasts it. A dead child whose parent never reaps it stays in the
  // process table; a pgrep ahead of the real one lists that pid as a child of the call, so the stop cannot see its tree end.
  const holder = spawn('python3', ['-c', 'import os, time\npid = os.fork()\nif pid == 0:\n    os._exit(0)\nprint(pid, flush=True)\ntime.sleep(600)'], { stdio: ['ignore', 'pipe', 'ignore'] });
  let stub = 0;
  try {
    const zombie = await new Promise((resolve, reject) => { holder.once('error', reject); holder.stdout.once('data', d => resolve(Number(String(d).trim()))); });
    const bin = join(f.dir, 'bin');
    mkdirSync(bin);
    const real = spawnSync('bash', ['-c', 'command -v pgrep'], { env: f.env, encoding: 'utf8' }).stdout.trim();
    assert.ok(real, 'pgrep is on the PATH');
    writeFileSync(join(bin, 'pgrep'), '#!/bin/bash\n[ "$1" = -P ] && [ "$2" != "$ZOMBIE_PID" ] && { echo "$ZOMBIE_PID"; exit 0; }\nexec "$REAL_PGREP" "$@"\n', { mode: 0o700 });
    const run = await termMidCall(f, managed, { PATH: `${bin}:${f.env.PATH}`, ZOMBIE_PID: String(zombie), REAL_PGREP: real });
    stub = run.stub;
    assert.equal(run.code, 143);
    assert.equal(alive(stub), false, 'the call outlived its terminated launcher');
    assert.deepEqual(Object.values(controlOf(f).attempts).map(a => a.phase), ['unknown']);
    assert.equal(slotsOf(f).length, 1);
    assert.equal(receiptsOf(f).at(-1).outcome, 'indeterminate');
    const ack = pausedAck(f, managed);
    assert.equal(ack.quiescent, false);
    assert.equal(ack.unknown.length, 1);
  } finally {
    holder.kill('SIGKILL');
    if (stub && alive(stub)) process.kill(stub, 'SIGKILL');
  }
});

test('funded API account proceeds while the native bank is exhausted; child sees an isolated env', () => {
  const f = fixture();
  const r = f.run(f.good, { CLAUDE_CODE_OAUTH_TOKEN: 'oauth-dummy', ANTHROPIC_BASE_URL: 'https://evil.example' });
  assert.equal(r.status, 0, r.stderr);
  const seen = readFileSync(f.paths.env, 'utf8');
  assert.match(seen, /^key_present=1$/m);
  assert.match(seen, /^base_url=https:\/\/api\.anthropic\.com$/m);
  assert.match(seen, /^oauth=$/m);
  assert.match(seen, /^lane_on=$/m);
  assert.match(seen, /^scrub=1$/m);
  assert.match(seen, /--max-budget-usd 0\.10/);
  assert.match(seen, /--output-format json/);
  const row = f.status();
  assert.equal(row.reserved_usd, '0.000000');
  assert.equal(row.spent_est_usd, '0.012345');
});

test('the launch record carries branch, head and PR; absent keys are empty and null', () => {
  const f = fixture();
  assert.equal(f.run(f.good, { HIMMEL_API_BRANCH: 'feat/x"y', HIMMEL_API_HEAD: 'abc123def', HIMMEL_API_PR: '3300' }).status, 0);
  const rec = JSON.parse(f.record().trim());
  assert.equal(rec.branch, 'feat/x"y');
  assert.equal(rec.head, 'abc123def');
  assert.equal(rec.pr, 3300);
  assert.equal(rec.cost_usd, '0.012345');
  for (const bad of ['03300', 'abc3300', '12x']) {
    const h = fixture();
    assert.equal(h.run(h.good, { HIMMEL_API_PR: bad }).status, 0);
    assert.equal(JSON.parse(h.record().trim()).pr, null, bad);
  }
  const bh = fixture();
  assert.equal(bh.run(bh.good, { HIMMEL_API_HEAD: 'refs/heads/abc' }).status, 0);
  assert.equal(JSON.parse(bh.record().trim()).head, '');
  const g = fixture();
  assert.equal(g.run().status, 0);
  const bare = JSON.parse(g.record().trim());
  assert.equal(bare.branch, '');
  assert.equal(bare.pr, null);
});

test('judge j2229c: the harness hand-off names (LQ_API_*) never reach claude', () => {
  const f = fixture();
  const r = f.run(f.good, { LQ_API_KEY: DUMMY, LQ_API_ACCOUNT: 'B', LQ_API_KEY_ID: 'key-b', LQ_API_LANE: 'on' });
  assert.equal(r.status, 0, r.stderr);
  assert.match(readFileSync(f.paths.env, 'utf8'), /^lq_api=0$/m);
});

// --- a failed API-lane call alerts once and falls back to the subscription ---
const FB_ON = { HIMMEL_API_FALLBACK: 'on' };
const FB_OK = JSON.stringify({ type: 'result', is_error: false, total_cost_usd: 0.5, result: 'from-sub' });
const CREDIT_LOW = JSON.stringify({ type: 'result', is_error: true, result: 'Credit balance is too low to access the API' });
const CALL_FAIL = JSON.stringify({ type: 'result', is_error: true, subtype: 'error_during_execution', result: 'boom' });
const alerts = (f) => (existsSync(f.paths.alertLog) ? readFileSync(f.paths.alertLog, 'utf8') : '')
  .split('\n').filter((l) => l.startsWith('type='));
const alertText = (f) => (existsSync(f.paths.alertLog) ? readFileSync(f.paths.alertLog, 'utf8') : '');
const fbCalls = (f) => (existsSync(`${f.paths.log}.fb`) ? readFileSync(`${f.paths.log}.fb`, 'utf8').trim().split('\n').length : 0);
const fbArgs = (f) => readFileSync(`${f.paths.env}.fb.args`, 'utf8').trim().split('\n');
const rows = (f) => (existsSync(join(f.dir, 'launches.jsonl')) ? f.record().trim().split('\n').map((l) => JSON.parse(l)) : []);
// a native bank reading the subscription preflight trusts: the cache carries this home's account hash
function native(f, util) {
  writeFileSync(join(f.dir, '.claude.json'), JSON.stringify({ oauthAccount: { accountUuid: 'u-test' } }));
  writeFileSync(f.env.CADENCE_USAGE_CACHE, JSON.stringify({ account: createHash('sha256').update('u-test').digest('hex').slice(0, 16),
    primaries_refreshed_at: Math.floor(Date.now() / 1000), five_hour: { utilization: util }, seven_day: { utilization: util } }));
}
// the key appears in no output, no file the run left (alert, fallback env and argv, records, ledgers)
function keyNowhere(f, r) {
  assert.ok(!r.stdout.includes(DUMMY) && !r.stderr.includes(DUMMY), 'key in launcher output');
  const walk = (d) => readdirSync(d, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(join(d, e.name)) : [join(d, e.name)]));
  for (const p of walk(f.dir)) assert.ok(!readFileSync(p, 'utf8').includes(DUMMY), `key in ${p}`);
}

test('a refused call (an invalid account) sends one alert and re-runs the prompt once on the subscription, native auth, no key', () => {
  const f = fixture();
  const r = f.run(f.good, { ...FB_ON, HIMMEL_API_KIND: 'eval', HIMMEL_API_ACCOUNT: 'E', STUB_FB_OUT: FB_OK, CLAUDE_CODE_OAUTH_TOKEN: 'oauth-dummy',
    ANTHROPIC_BASE_URL: 'https://evil.example', ANTHROPIC_ORG_A_KEY: DUMMY, LQ_API_KEY: DUMMY, CLAUDECODE: '1' },
  { argv0: SESSION_ARGV0 }); // a marker needs a `claude` ancestor, or the subscription preflight's seam guard refuses on CI's primary checkout
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stderr, /HIMMEL_API_ACCOUNT must be/);
  assert.equal(r.stdout, FB_OK);
  assert.equal(f.called(), false, 'the API call must not run');
  assert.equal(fbCalls(f), 1);
  const seen = readFileSync(`${f.paths.env}.fb`, 'utf8');
  for (const want of [/^key_present=0$/m, /^base_url=$/m, /^oauth=oauth-dummy$/m, /^org_keys=0$/m, /^lq_api=0$/m])
    assert.match(seen, want);
  const full = readFileSync(`${f.paths.env}.fb.full`, 'utf8');
  assert.ok(!/^(ANTHROPIC_|HIMMEL_API_|LQ_API_|CLAUDECODE=)/m.test(full), 'an API, lane or session var reached the fallback');
  // native auth keeps only its own token; every other session marker is dropped
  assert.deepEqual(full.match(/^CLAUDE_CODE_[A-Z0-9_]+(?==)/gm).sort(), ['CLAUDE_CODE_OAUTH_TOKEN', 'CLAUDE_CODE_SUBPROCESS_ENV_SCRUB']);
  const args = fbArgs(f);
  assert.deepEqual(args.slice(0, 6), ['-p', 'say hi', '--model', 'claude-haiku-5-5', '--permission-mode', 'plan']);
  assert.ok(args.join(' ').includes('--max-budget-usd 0.10') && args.join(' ').includes('--output-format json'), args.join(' '));
  assert.ok(!args.includes('bypassPermissions'));
  const a = alerts(f);
  assert.equal(a.length, 1);
  assert.match(alertText(f), /refused/);
  assert.match(alertText(f), /HIMMEL_API_ACCOUNT must be/);
  assert.match(alertText(f), /fallback: running on the subscription/);
  const fb = rows(f).at(-1);
  assert.equal(fb.lane, 'sub-fallback');
  assert.equal(fb.outcome, 'sub-fallback');
  assert.equal(fb.api_class, 'refused');
  assert.equal(fb.api_rc, 2);
  assert.equal(fb.rc, 0);
  assert.equal(fb.cost_usd, '');
  assert.equal(fb.sub_cost_usd, '0.500000');
  keyNowhere(f, r);
});

test('a credit-low answer (exit 6) alerts once and falls back; the API row and the fallback row are both recorded', () => {
  const f = fixture();
  const r = f.run(f.good, { ...FB_ON, STUB_OUT: CREDIT_LOW, STUB_RC: '1', STUB_FB_OUT: FB_OK });
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stderr, /credit exhausted/);
  assert.equal(r.stdout, FB_OK);
  assert.equal(f.called(), true);
  assert.equal(fbCalls(f), 1);
  assert.match(readFileSync(`${f.paths.env}.fb`, 'utf8'), /^key_present=0$/m);
  assert.equal(alerts(f).length, 1);
  assert.match(alertText(f), /rejected/);
  assert.match(alertText(f), /account A/);
  const [api, fb] = rows(f);
  assert.equal(api.outcome, 'exhausted');
  assert.equal(fb.lane, 'sub-fallback');
  assert.equal(fb.api_rc, 6);
  assert.equal(fb.api_class, 'rejected');
  keyNowhere(f, r);
});

test('a failed call alerts once and falls back; a failing fallback returns its own code', () => {
  const f = fixture();
  const r = f.run(f.good, { ...FB_ON, STUB_OUT: CALL_FAIL, STUB_RC: '1', STUB_FB_OUT: FB_OK });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(fbCalls(f), 1);
  assert.equal(alerts(f).length, 1);
  assert.match(alertText(f), /call-failed/);
  assert.ok(!alertText(f).includes('boom'), 'the call result text reached the alert');
  assert.equal(rows(f).at(-1).api_class, 'call-failed');
  keyNowhere(f, r);
  const g = fixture();
  const bad = g.run(g.good, { ...FB_ON, STUB_OUT: CALL_FAIL, STUB_RC: '1', STUB_FB_OUT: CALL_FAIL, STUB_FB_RC: '3' });
  assert.equal(bad.status, 3);
  assert.equal(rows(g).at(-1).outcome, 'sub-fallback-failed');
});

const BUDGET_CAP = JSON.stringify({ type: 'result', is_error: true, subtype: 'error_max_budget_usd', result: 'budget' });
const chiefBridge = (f, names) => {
  const root = join(f.dir, 'bridge');
  mkdirSync(join(root, 'consoles'), { recursive: true });
  for (const n of names) writeFileSync(join(root, 'consoles', `${n}.md`), '');
  return root;
};
const inboxText = (root, name) => readFileSync(join(root, 'consoles', `${name}.md`), 'utf8');

test('a budget-capped judge call alerts the chief inbox and does not page the operator', () => {
  const f = fixture();
  const root = chiefBridge(f, ['test-chief']);
  const r = f.run(f.good, { ...FB_ON, HIMMEL_API_KIND: 'judge', BRIDGE_ROOT: root, HIMMEL_CONSOLE_NAME: 'test-chief', STUB_OUT: BUDGET_CAP, STUB_RC: '1', STUB_FB_OUT: FB_OK });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(alerts(f).length, 0, 'the operator was paged for a chief-actionable failure');
  const line = inboxText(root, 'test-chief');
  assert.match(line, /\[api-lane call-failed\]/);
  assert.match(line, /kind judge, account A, call-failed \(exit 1\): the call exited 1 \(error_max_budget_usd\)/);
  assert.match(line, /fallback: running on the subscription/);
  assert.equal(line.trim().split('\n').length, 1);
  keyNowhere(f, r);
});

test('with no HIMMEL_CONSOLE_NAME the newest armed chief gets the call-failed alert', () => {
  const f = fixture();
  const root = chiefBridge(f, ['old-chief', 'new-chief']);
  const stamp = (n, hb) => writeFileSync(join(root, 'consoles', `${n}.md.wait`), `hb=${hb} pid=1 key=k tick=ok state=waiting\n`);
  const now = Math.floor(Date.now() / 1000);
  stamp('old-chief', now - 100);
  stamp('new-chief', now - 5);
  const r = f.run(f.good, { BRIDGE_ROOT: root, STUB_OUT: CALL_FAIL, STUB_RC: '1' });
  assert.equal(r.status, 1, r.stderr);
  assert.equal(alerts(f).length, 0);
  assert.match(inboxText(root, 'new-chief'), /call-failed/);
  assert.equal(inboxText(root, 'old-chief'), '');
});

test('a call-failed alert with no chief inbox still pages the operator', () => {
  const f = fixture();
  const root = chiefBridge(f, []);
  const r = f.run(f.good, { BRIDGE_ROOT: root, HIMMEL_CONSOLE_NAME: 'gone-chief', STUB_OUT: BUDGET_CAP, STUB_RC: '1' });
  assert.equal(r.status, 1, r.stderr);
  assert.equal(alerts(f).length, 1);
  assert.match(alertText(f), /call-failed/);
  assert.equal(existsSync(join(root, 'consoles', 'gone-chief.md')), false, 'a missing chief inbox was created');
});

test('an operator-actionable failure (credit gone, key rejected) pages the operator even with a chief inbox', () => {
  for (const out of [CREDIT_LOW, JSON.stringify({ type: 'result', is_error: true, result: 'Invalid API key' })]) {
    const f = fixture();
    const root = chiefBridge(f, ['test-chief']);
    const r = f.run(f.good, { BRIDGE_ROOT: root, HIMMEL_CONSOLE_NAME: 'test-chief', STUB_OUT: out, STUB_RC: '1' });
    assert.equal(r.status, 6, r.stderr);
    assert.equal(alerts(f).length, 1, out);
    assert.match(alertText(f), /rejected/);
    assert.equal(inboxText(root, 'test-chief'), '', 'an operator-actionable alert reached the chief inbox');
  }
});

test('every account out of credit still pages the operator, chief inbox present', () => {
  const f = fixture();
  const root = chiefBridge(f, ['test-chief']);
  for (const a of ['A', 'B']) spawnSync(process.execPath, [STATE, 'exhausted'], { env: { ...f.env, HIMMEL_API_ACCOUNT: a }, encoding: 'utf8' });
  const r = f.run(f.good, { HIMMEL_API_ACCOUNT: 'auto', HIMMEL_API_KIND: 'eval', BRIDGE_ROOT: root, HIMMEL_CONSOLE_NAME: 'test-chief', STUB_OUT: CREDIT_LOW, STUB_RC: '1' });
  assert.notEqual(r.status, 0, r.stderr);
  assert.equal(inboxText(root, 'test-chief'), '', 'an all-accounts-exhausted alert reached the chief inbox');
  assert.ok(alerts(f).length >= 1 || /alert: none sent/.test(r.stderr), r.stderr);
});

test('a call granted Edit, Write or Bash re-runs only after a refusal before any request; a run that started is never replayed', () => {
  for (const tools of ['Read,Edit', 'Write', 'Read,Grep,Bash']) {
    const f = fixture();
    const r = f.run(f.good, { ...FB_ON, HIMMEL_API_TOOLS: tools, STUB_OUT: CALL_FAIL, STUB_RC: '1', STUB_FB_OUT: FB_OK });
    assert.equal(r.status, 1, tools);
    assert.equal(fbCalls(f), 0, `${tools}: a failed run that may have changed files was replayed`);
    assert.equal(alerts(f).length, 1, tools);
    assert.match(alertText(f), /fallback: not run: the call could change files/, tools);
    const g = fixture();
    assert.equal(g.run(g.good, { ...FB_ON, HIMMEL_API_TOOLS: tools, STUB_OUT: CREDIT_LOW, STUB_RC: '1', STUB_FB_OUT: FB_OK }).status, 6, tools);
    assert.equal(fbCalls(g), 0, `${tools}: a rejection on a later turn could follow an edit, so exit 6 is not replayed`);
    assert.match(alertText(g), /fallback: not run: the call could change files/, tools);
    const h = fixture();
    assert.equal(h.run(h.good, { ...FB_ON, HIMMEL_API_TOOLS: tools, HIMMEL_API_ACCOUNT: 'E', STUB_FB_OUT: FB_OK }).status, 0, tools);
    assert.equal(fbCalls(h), 1, `${tools}: a refusal (exit 2) re-runs`);
  }
  const k = fixture();
  assert.equal(k.run(k.good, { ...FB_ON, HIMMEL_API_TOOLS: 'Read,Glob,Grep', STUB_OUT: CALL_FAIL, STUB_RC: '1', STUB_FB_OUT: FB_OK }).status, 0);
  assert.equal(fbCalls(k), 1, 'a read-only grant keeps the fallback on a failed run');
});

// bulk-call --cancel TERMs the call and the launcher together; here the call ends first and the launcher's TERM
// lands after it, while the launcher is settling.
test('a TERM to the launcher after its call ended is a caller stop: no alert, no subscription replay, even read-only', () => {
  const f = fixture();
  const r = f.run(f.good, { ...FB_ON, HIMMEL_API_TOOLS: 'Read,Glob,Grep', STUB_TERM: '1', STUB_FB_OUT: FB_OK });
  assert.equal(r.status, 143, r.stderr);
  assert.equal(fbCalls(f), 0, 'a stopped call was replayed on the subscription');
  assert.deepEqual(alerts(f), [], 'a stop raised an alert');
  assert.equal(f.status().reserved_usd, '0.000000', 'the reservation is still held');
});

// the alert stub TERMs the launcher mid failure path: the alert was already sent, the fallback must not start
test('a stop that lands while the alert is sent ends the failure path before the fallback runs', () => {
  const f = fixture();
  const r = f.run(f.good, { ...FB_ON, HIMMEL_API_TOOLS: 'Read,Glob,Grep', STUB_OUT: CALL_FAIL, STUB_RC: '1', STUB_FB_OUT: FB_OK, ALERT_TERM_PARENT: '1' });
  assert.equal(r.status, 1, r.stderr);
  assert.match(r.stderr, /stopped by its caller; the fallback was not run/);
  assert.equal(fbCalls(f), 0, 'the fallback ran after a stop');
  assert.equal(alerts(f).length, 1);
});

test('the call watchdog ending a hung read-only call is a failed call: one alert, one subscription re-run', () => {
  const f = fixture();
  const hold = join(f.dir, 'hold'); writeFileSync(hold, '');
  try {
    const r = f.run(f.good, { ...FB_ON, HIMMEL_API_TOOLS: 'Read,Glob,Grep', STUB_HOLD: hold, HIMMEL_API_CALL_TIMEOUT_S: '1', STUB_FB_OUT: FB_OK });
    assert.equal(r.status, 0, r.stderr);
    assert.equal(r.stdout, FB_OK);
    assert.match(r.stderr, /the call hit the call timeout/);
    assert.equal(fbCalls(f), 1);
    assert.equal(alerts(f).length, 1);
    assert.match(alertText(f), /call timeout/);
    assert.equal(f.status().reserved_usd, '0.000000');
  } finally { rmSync(hold, { force: true }); }
});

test('a subscription preflight refusal runs no fallback, the alert names it and the original code stands', () => {
  const f = fixture();
  native(f, 100);
  const r = f.run(f.good, { ...FB_ON, HIMMEL_API_KIND: 'eval', HIMMEL_API_ACCOUNT: 'E' });
  assert.equal(r.status, 2);
  assert.equal(fbCalls(f), 0);
  assert.equal(alerts(f).length, 1);
  assert.match(alertText(f), /SKIPPED-BANK/);
  const g = fixture();
  native(g, 100);
  const six = g.run(g.good, { ...FB_ON, STUB_OUT: CREDIT_LOW, STUB_RC: '1' });
  assert.equal(six.status, 6);
  assert.equal(fbCalls(g), 0);
  const h = fixture();
  native(h, 10);
  assert.equal(h.run(h.good, { ...FB_ON, HIMMEL_API_ACCOUNT: 'E', STUB_FB_OUT: FB_OK }).status, 0);
  assert.equal(fbCalls(h), 1, 'PROCEED runs the fallback');
});

test('one alert per kind and class per hour; a new class or an hour later alerts again', () => {
  const f = fixture();
  for (let i = 0; i < 2; i++) assert.equal(f.run(f.good, { ...FB_ON, HIMMEL_API_KIND: 'eval', HIMMEL_API_ACCOUNT: 'E' }).status, 0);
  assert.equal(alerts(f).length, 1, 'the second refusal within the hour alerted again');
  assert.equal(fbCalls(f), 2, 'the rate limit holds the alert, never the fallback');
  assert.equal(f.run(f.good, { ...FB_ON, HIMMEL_API_KIND: 'eval', STUB_OUT: CREDIT_LOW, STUB_RC: '1' }).status, 0);
  assert.equal(alerts(f).length, 2);
  const old = (Date.now() - 2 * 3600 * 1000) / 1000;
  for (const s of readdirSync(join(f.dir, 'alerts'))) utimesSync(join(f.dir, 'alerts', s), old, old);
  assert.equal(f.run(f.good, { ...FB_ON, HIMMEL_API_KIND: 'eval', HIMMEL_API_ACCOUNT: 'E' }).status, 0);
  assert.equal(alerts(f).length, 3);
});

test('a failed alert send writes no stamp, so the next failure inside the hour alerts again', () => {
  const f = fixture();
  assert.equal(f.run(f.good, { ...FB_ON, HIMMEL_API_KIND: 'eval', HIMMEL_API_ACCOUNT: 'E', ALERT_RC: '1' }).status, 0);
  assert.equal(f.run(f.good, { ...FB_ON, HIMMEL_API_KIND: 'eval', HIMMEL_API_ACCOUNT: 'E' }).status, 0);
  assert.equal(alerts(f).length, 2, 'a failed send muted the next alert');
});

test('HIMMEL_API_FALLBACK=off still alerts but runs no fallback; a malformed request never falls back', () => {
  const f = fixture();
  const r = f.run(f.good, { HIMMEL_API_LANE: '', HIMMEL_API_KIND: 'eval' });
  assert.equal(r.status, 2);
  assert.equal(fbCalls(f), 0);
  assert.equal(alerts(f).length, 1);
  assert.match(alertText(f), /fallback: off/);
  const g = fixture();
  assert.equal(g.run([...g.good, '--bogus'], { ...FB_ON, HIMMEL_API_KIND: 'eval' }).status, 2);
  assert.equal(fbCalls(g), 0);
  assert.equal(alerts(g).length, 1);
  // the lane-off refusal comes first, yet a malformed request still never reaches the subscription
  const noPrint = ['--model', 'claude-haiku-5-5', '--permission-mode', 'plan', '--max-budget-usd', '0.10', 'hi'];
  for (const [args, env] of [[noPrint, {}], [null, { HIMMEL_API_KIND: 'bad kind' }], [null, { HIMMEL_API_CACHE_TTL: '9h' }],
    [null, { HIMMEL_API_JOB_ID: 'bad id' }], [null, { HIMMEL_API_TOOLS: 'Bash(*)' }]]) {
    const m = fixture();
    const run = m.run(args ?? m.good, { ...FB_ON, HIMMEL_API_LANE: '', ...env });
    assert.equal(run.status, 2);
    assert.equal(fbCalls(m), 0, JSON.stringify(env));
    assert.match(run.stderr, /fallback: not run: the request itself was refused/);
  }
});

test('HIMMEL_API_FALLBACK unset or any value but on is off: no fallback, no sub-fallback row; on still runs it', () => {
  for (const [value, want] of [[undefined, /fallback: off \(HIMMEL_API_FALLBACK unset: default off\)/],
    ['', /fallback: off \(HIMMEL_API_FALLBACK unset: default off\)/], ['On', /fallback: off \(HIMMEL_API_FALLBACK=On is not on\)/],
    ['yes', /fallback: off \(HIMMEL_API_FALLBACK=yes is not on\)/]]) {
    const f = fixture();
    native(f, 10);
    const r = f.run(f.good, { HIMMEL_API_FALLBACK: value, HIMMEL_API_KIND: 'eval', HIMMEL_API_ACCOUNT: 'E', STUB_FB_OUT: FB_OK });
    assert.equal(r.status, 2, `${value}: ${r.stderr}`);
    assert.equal(fbCalls(f), 0, `${value}: the subscription ran`);
    assert.ok(!rows(f).some((row) => row.lane === 'sub-fallback'), `${value}: a sub-fallback row was written`);
    assert.equal(alerts(f).length, 1, `${value}: no alert`);
    assert.match(alertText(f), want);
  }
  const g = fixture();
  native(g, 10);
  assert.equal(g.run(g.good, { ...FB_ON, HIMMEL_API_ACCOUNT: 'E', STUB_FB_OUT: FB_OK }).status, 0);
  assert.equal(fbCalls(g), 1, 'on no longer runs the fallback');
});

function routeFixture(dotenv) {
  const f = fixture();
  const bin = join(f.dir, 'bin');
  mkdirSync(bin);
  const sent = join(f.dir, 'sent.log');
  writeFileSync(join(bin, 'bun'), `#!/bin/bash\n{ echo "chat=$TELEGRAM_GROUP_CHAT_ID"; echo "args=$*"; echo "msg=$TG_MESSAGE"; } >> '${sent}'\nexit "\${BUN_RC:-0}"\n`, { mode: 0o700 });
  if (dotenv !== undefined) writeFileSync(join(f.dir, '.env'), dotenv);
  const go = (extra = {}) => f.run(f.good, { HIMMEL_API_KIND: 'eval', HIMMEL_API_ACCOUNT: 'E', HIMMEL_API_ALERT_CMD: undefined, HIMMEL_API_ALERT_ENV_ROOT: f.dir,
    PATH: `${bin}:${process.env.PATH}`, ...extra });
  const sends = () => (existsSync(sent) ? readFileSync(sent, 'utf8') : '');
  const stamps = () => readdirSync(join(f.dir, 'alerts')).filter((n) => !n.endsWith('.jsonl'));
  const undelivered = () => {
    const p = join(f.dir, 'alerts', 'undelivered.jsonl');
    return existsSync(p) ? readFileSync(p, 'utf8').trim().split('\n').map((l) => JSON.parse(l)) : [];
  };
  return { f, go, sends, stamps, undelivered };
}

test('an alert with no group chat id goes to the operator chat (TELEGRAM_CHAT_ID); a group id still wins', () => {
  const op = routeFixture('TELEGRAM_CHAT_ID=1234567\n');
  assert.equal(op.go().status, 2);
  assert.match(op.sends(), /^chat=1234567$/m);
  assert.match(op.sends(), /^args=run .*scripts\/telegram\/session-status\.ts notification$/m);
  assert.equal(op.stamps().length, 1, 'a delivered alert stamps the hour');
  assert.equal(op.undelivered().length, 0);
  const grp = routeFixture('TELEGRAM_CHAT_ID=1234567\nTELEGRAM_GROUP_CHAT_ID=-7654321\n');
  assert.equal(grp.go().status, 2);
  assert.match(grp.sends(), /^chat=-7654321$/m);
});

test('an alert with no chat id at all is never dropped silently: stderr, one undelivered row, no stamp, the next failure alerts again', () => {
  const none = routeFixture();
  const r = none.go();
  assert.equal(r.status, 2);
  assert.match(r.stderr, /claude-api: alert NOT delivered \(no TELEGRAM_GROUP_CHAT_ID or TELEGRAM_CHAT_ID\)/);
  assert.equal(none.sends(), '', 'a sender ran with no chat id');
  assert.deepEqual(none.stamps(), [], 'an undelivered alert stamped the hour');
  const [row] = none.undelivered();
  assert.equal(row.class, 'refused');
  assert.equal(row.rc, 2);
  assert.match(row.reason, /HIMMEL_API_ACCOUNT must be/);
  assert.equal(row.why, 'no TELEGRAM_GROUP_CHAT_ID or TELEGRAM_CHAT_ID');
  assert.match(none.go().stderr, /alert NOT delivered/);
  assert.equal(none.undelivered().length, 2, 'the second failure inside the hour was not recorded');
  keyNowhere(none.f, r);
  const quiet = routeFixture('TELEGRAM_CHAT_ID=1234567\n');
  const q = quiet.go({ TELEGRAM_GROUP_CHAT_ID: '' });
  assert.match(q.stderr, /alert NOT delivered \(TELEGRAM_GROUP_CHAT_ID is set empty: suppressed\)/);
  assert.equal(quiet.sends(), '');
  assert.deepEqual(quiet.stamps(), []);
  assert.equal(quiet.undelivered().length, 1);
  assert.ok(!readFileSync(join(quiet.f.dir, 'alerts', 'undelivered.jsonl'), 'utf8').includes('1234567'), 'a chat id reached the record');
  const dotQuiet = routeFixture('TELEGRAM_CHAT_ID=1234567\nTELEGRAM_GROUP_CHAT_ID=\n');
  assert.match(dotQuiet.go().stderr, /alert NOT delivered \(TELEGRAM_GROUP_CHAT_ID is set empty: suppressed\)/);
  assert.equal(dotQuiet.sends(), '', 'an empty group id in .env reached the operator chat');
  assert.deepEqual(dotQuiet.stamps(), []);
  assert.equal(dotQuiet.undelivered().length, 1);
  const failed = routeFixture('TELEGRAM_CHAT_ID=1234567\n');
  assert.match(failed.go({ BUN_RC: '124' }).stderr, /alert NOT delivered \(the sender exited 124\)/);
  assert.deepEqual(failed.stamps(), []);
  assert.equal(failed.undelivered()[0].why, 'the sender exited 124');
});

// a prompt on stdin is kept in a mode-600 scratch file, so the fallback can replay it
const STDIN_ONLY = ['-p', '--model', 'claude-haiku-5-5', '--permission-mode', 'plan', '--max-budget-usd', '0.10'];
const PROMPT = 'the-secret-prompt-bytes\nsecond line\n';
const promptFiles = (f) => readdirSync(f.dir).filter((n) => n.startsWith('claude-api-prompt.'));
const seenStdin = (f, fb = '') => readFileSync(join(f.dir, `stdin.seen${fb}`), 'utf8');
const seenModes = (f, fb = '') => readFileSync(join(f.dir, `stdin.seen${fb}.mode`), 'utf8').trim().split('\n');
const withStdin = (f) => ({ ...FB_ON, STUB_STDIN: join(f.dir, 'stdin.seen') });
// the prompt appears in no output and no file the run left, argv of the fallback included
function promptNowhere(f, r) {
  assert.ok(!r.stdout.includes('the-secret-prompt') && !r.stderr.includes('the-secret-prompt'), 'prompt in launcher output');
  const walk = (d) => readdirSync(d, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(join(d, e.name)) : [join(d, e.name)]));
  for (const p of walk(f.dir)) if (!p.includes('stdin.seen')) assert.ok(!readFileSync(p, 'utf8').includes('the-secret-prompt'), `prompt in ${p}`);
}

test('a stdin prompt whose API call failed is replayed byte for byte on the subscription fallback', () => {
  const f = fixture();
  const r = f.run(STDIN_ONLY, { ...withStdin(f), STUB_OUT: CREDIT_LOW, STUB_RC: '1', STUB_FB_OUT: FB_OK }, { input: PROMPT });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout, FB_OK);
  assert.equal(fbCalls(f), 1);
  assert.equal(seenStdin(f), PROMPT, 'the API call did not get the prompt');
  assert.equal(seenStdin(f, '.fb'), PROMPT, 'the fallback did not get the same prompt bytes');
  assert.deepEqual(seenModes(f), ['600']);
  assert.deepEqual(seenModes(f, '.fb'), ['600']);
  assert.deepEqual(promptFiles(f), []);
  assert.match(alertText(f), /fallback: running on the subscription/);
  assert.doesNotMatch(alertText(f), /not run: the prompt came on stdin/);
  promptNowhere(f, r);
  keyNowhere(f, r);
});

test('the scratch prompt file is gone after success, a refusal before and after the buffer, and an ordinary failure', () => {
  const ok = fixture();
  const a = ok.run(STDIN_ONLY, withStdin(ok), { input: PROMPT });
  assert.equal(a.status, 0, a.stderr);
  assert.equal(seenStdin(ok), PROMPT);
  assert.deepEqual(seenModes(ok), ['600']);
  assert.deepEqual(promptFiles(ok), [], 'left behind after success');
  assert.equal(fbCalls(ok), 0);

  // an invalid account: refused before stdin is read, the fallback still gets the unread prompt
  const early = fixture();
  const b = early.run(STDIN_ONLY, { ...withStdin(early), HIMMEL_API_ACCOUNT: 'E', STUB_FB_OUT: FB_OK }, { input: PROMPT });
  assert.equal(b.status, 0, b.stderr);
  assert.equal(early.called(), false, 'the API call must not run');
  assert.equal(seenStdin(early, '.fb'), PROMPT);
  assert.deepEqual(promptFiles(early), []);

  // a budget the account cannot cover, with enforce_budget on: refused at the reservation, after the prompt was buffered
  const late = fixture();
  late.config.enforce_budget = true;
  late.save();
  const big = [...STDIN_ONLY.slice(0, -1), '50'];
  const c = late.run(big, { ...withStdin(late), STUB_FB_OUT: FB_OK }, { input: PROMPT });
  assert.equal(c.status, 0, c.stderr);
  assert.match(c.stderr, /reservation refused/);
  assert.equal(late.called(), false, 'the API call must not run');
  assert.equal(seenStdin(late, '.fb'), PROMPT);
  assert.deepEqual(seenModes(late, '.fb'), ['600']);
  assert.deepEqual(promptFiles(late), []);

  // a failure that no fallback follows (switched off)
  const off = fixture();
  const d = off.run(STDIN_ONLY, { STUB_STDIN: join(off.dir, 'stdin.seen'), STUB_OUT: CALL_FAIL, STUB_RC: '1' }, { input: PROMPT });
  assert.equal(d.status, 1);
  assert.equal(fbCalls(off), 0);
  assert.deepEqual(promptFiles(off), []);
});

test('a stdin prompt on a Bash-granted call that ran is still never replayed; a prompt in argv is untouched', () => {
  const f = fixture();
  const r = f.run(STDIN_ONLY, { ...withStdin(f), HIMMEL_API_TOOLS: 'Bash', STUB_OUT: CALL_FAIL, STUB_RC: '1' }, { input: PROMPT });
  assert.equal(r.status, 1);
  assert.equal(fbCalls(f), 0);
  assert.match(alertText(f), /the call could change files/);
  assert.deepEqual(promptFiles(f), []);
  const g = fixture();
  const h = g.run(g.good, { ...FB_ON, STUB_STDIN: join(g.dir, 'stdin.seen'), STUB_OUT: CALL_FAIL, STUB_RC: '1', STUB_FB_OUT: FB_OK });
  assert.equal(h.status, 0, h.stderr);
  assert.equal(fbCalls(g), 1);
  assert.deepEqual(promptFiles(g), [], 'an argv prompt buffered a scratch file');
  assert.equal(existsSync(join(g.dir, 'stdin.seen.mode')), false);
});

test('an argv prompt with a closed stdin still starts the call', () => {
  const f = fixture();
  const r = spawnSync('sh', ['-c', 'exec bash "$0" "$@" <&-', LAUNCH, ...f.good], { env: f.env, encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(f.called(), true, 'the API call never started');
});

test('a terminal on stdin with no argv prompt is refused with no fallback and no scratch file', (t) => {
  if (spawnSync('python3', ['-I', '-c', 'import pty']).status !== 0) { t.skip('no python3 pty on this host'); return; }
  const f = fixture();
  const runner = join(f.dir, 'pty-run.py');
  writeFileSync(runner, [
    'import pty, subprocess, sys',
    'm, s = pty.openpty()',
    "r = subprocess.run(['bash', sys.argv[1]] + sys.argv[2:], stdin=s, capture_output=True, text=True, timeout=20)",
    'sys.stderr.write(r.stderr)',
    'sys.exit(r.returncode)',
  ].join('\n'));
  const r = spawnSync('python3', ['-I', runner, LAUNCH, ...STDIN_ONLY], { env: { ...f.env, ...withStdin(f) }, encoding: 'utf8' });
  assert.equal(r.status, 2, r.stderr);
  assert.match(r.stderr, /stdin is a terminal/);
  assert.equal(f.called(), false);
  assert.equal(fbCalls(f), 0);
  assert.deepEqual(promptFiles(f), []);
});

test('a stdin prompt over 8 MiB is refused with no call, no fallback and no scratch file; 8 MiB itself is kept', () => {
  const f = fixture();
  const big = f.run(STDIN_ONLY, { ...withStdin(f), STUB_FB_OUT: FB_OK }, { input: Buffer.alloc(8 * 1024 * 1024 + 1, 97), maxBuffer: 1 << 26 });
  assert.equal(big.status, 2, big.stderr);
  assert.match(big.stderr, /over 8 MiB/);
  assert.equal(f.called(), false);
  assert.equal(fbCalls(f), 0);
  assert.deepEqual(promptFiles(f), []);
  const g = fixture();
  const edge = g.run(STDIN_ONLY, withStdin(g), { input: Buffer.alloc(8 * 1024 * 1024, 97), maxBuffer: 1 << 26 });
  assert.equal(edge.status, 0, edge.stderr);
  assert.equal(readFileSync(join(g.dir, 'stdin.seen')).length, 8 * 1024 * 1024);
});

test('a stdin prompt whose scratch file vanishes after the size check still reaches the call', () => {
  const f = fixture();
  const shim = join(f.dir, 'shim');
  mkdirSync(shim);
  writeFileSync(join(shim, 'wc'), '#!/bin/bash\nreal="$(PATH="$REAL_PATH" command -v wc)"\n"$real" "$@"; rc=$?\n[ "$1" != -c ] || rm -f "$TMPDIR"/claude-api-prompt.*\nexit $rc\n', { mode: 0o700 });
  const r = f.run(STDIN_ONLY, { ...withStdin(f), PATH: `${shim}:${f.env.PATH}`, REAL_PATH: f.env.PATH }, { input: PROMPT });
  assert.doesNotMatch(r.stderr, /could not reopen the stdin prompt/);
  assert.equal(r.status, 0, r.stderr);
  assert.equal(seenStdin(f), PROMPT, 'the call did not get the prompt');
  assert.deepEqual(promptFiles(f), []);
});

test('a launcher stopped while it buffers a stdin prompt removes the scratch file', async () => {
  const f = fixture();
  const child = spawn('bash', [LAUNCH, ...STDIN_ONLY], { env: { ...f.env, ...withStdin(f) }, stdio: ['pipe', 'ignore', 'ignore'] });
  child.stdin.write('half a prompt');
  const done = new Promise((resolve) => child.on('close', resolve));
  const until = Date.now() + 15000;
  while (promptFiles(f).length === 0 && Date.now() < until) await new Promise((r) => setTimeout(r, 50));
  assert.equal(promptFiles(f).length, 1, 'the scratch file never appeared');
  child.kill('SIGTERM');
  const code = await Promise.race([done, new Promise((r) => setTimeout(() => r('hung'), 10000))]);
  if (code === 'hung') child.kill('SIGKILL');
  assert.notEqual(code, 'hung', 'the launcher outlived its TERM');
  assert.deepEqual(promptFiles(f), [], 'left behind after a stop while buffering');
  assert.equal(f.called(), false);
});

test('a launcher stopped during the subscription fallback still writes the fallback launch record', async () => {
  const f = fixture();
  const hold = join(f.dir, 'fb-hold'); writeFileSync(hold, '');
  const child = spawn('bash', [LAUNCH, ...f.good], { env: { ...f.env, ...FB_ON, HIMMEL_API_ACCOUNT: 'E', STUB_FB_HOLD: hold }, stdio: 'ignore' });
  const done = new Promise((resolve) => child.on('close', resolve));
  try {
    const until = Date.now() + 15000;
    while (!existsSync(`${f.paths.log}.fb`) && Date.now() < until) await new Promise((r) => setTimeout(r, 50));
    assert.equal(fbCalls(f), 1, 'the fallback never started');
    child.kill('SIGTERM');
    const code = await Promise.race([done, new Promise((r) => setTimeout(() => r('hung'), 10000))]);
    assert.equal(code, 143);
    const last = rows(f).at(-1);
    assert.equal(last.lane, 'sub-fallback');
    assert.equal(last.outcome, 'sub-fallback-failed');
    assert.equal(last.rc, 143);
  } finally { rmSync(hold, { force: true }); if (child.exitCode === null) child.kill('SIGKILL'); }
});

test('a stdin that never closes is cut at the call timeout, refused with no fallback, and leaves no scratch file', async () => {
  const f = fixture();
  const child = spawn('bash', [LAUNCH, ...STDIN_ONLY], { env: { ...f.env, ...withStdin(f), HIMMEL_API_CALL_TIMEOUT_S: '1', STUB_FB_OUT: FB_OK }, stdio: ['pipe', 'pipe', 'pipe'] });
  child.stdin.write('half a prompt');
  let err = '';
  child.stderr.on('data', (d) => { err += d; });
  let guard;
  const code = await Promise.race([new Promise((r) => child.on('close', r)), new Promise((r) => { guard = setTimeout(() => r('hung'), 10000); })]);
  clearTimeout(guard);
  if (code === 'hung') child.kill('SIGKILL');
  assert.equal(code, 2, `the launcher hung on an open stdin: ${err}`);
  assert.match(err, /could not buffer the stdin prompt/);
  assert.equal(f.called(), false);
  assert.equal(fbCalls(f), 0);
  assert.deepEqual(promptFiles(f), []);
});

test('the scratch prompt file is gone after the launcher is terminated mid-call', async () => {
  const f = fixture();
  const hold = join(f.dir, 'hold'); writeFileSync(hold, '');
  const first = spawn('bash', [LAUNCH, ...STDIN_ONLY], { env: { ...f.env, ...withStdin(f), STUB_HOLD: hold }, stdio: ['pipe', 'ignore', 'ignore'] });
  first.stdin.end(PROMPT);
  const done = new Promise((resolve) => first.on('close', resolve));
  let stub = 0;
  try {
    const until = Date.now() + 15000;
    const ready = () => existsSync(f.paths.env) && /^resv_pid=\d+$/m.test(readFileSync(f.paths.env, 'utf8'));
    while (!ready() && Date.now() < until) await new Promise((r) => setTimeout(r, 50));
    stub = Number(/^stub_pid=(\d+)$/m.exec(readFileSync(f.paths.env, 'utf8'))[1]);
    assert.equal(promptFiles(f).length, 1, 'no scratch file while the call runs');
    first.kill('SIGTERM');
    await Promise.race([done, new Promise((r) => setTimeout(r, 10000))]);
    assert.equal(alive(stub), false, 'the call outlived its terminated launcher');
    assert.deepEqual(promptFiles(f), [], 'left behind after a signal stop');
  } finally { rmSync(hold, { force: true }); if (stub && alive(stub)) process.kill(stub, 'SIGKILL'); }
});

test('a caller with no HIMMEL_API_TOOLS gets no tools (tool-free default, no --allowedTools, no MCP)', () => {
  const f = fixture();
  assert.equal(f.run().status, 0);
  const seen = readFileSync(f.paths.env, 'utf8');
  assert.doesNotMatch(seen, /allowedTools/);
  assert.match(seen, /--tools  --max-budget-usd/);
  assert.match(seen, /--strict-mcp-config/);
  assert.match(seen, /--permission-mode plan/);
});

test('an opted-in caller gets exactly the named set; the full set is reachable only by naming it', () => {
  const f = fixture();
  assert.equal(f.run(f.good, { HIMMEL_API_TOOLS: 'Read,Edit,Write,Glob,Grep,Bash' }).status, 0);
  const seen = readFileSync(f.paths.env, 'utf8');
  assert.match(seen, /--allowedTools Read,Edit,Write,Glob,Grep,Bash/);
  assert.match(seen, /--tools Read,Edit,Write,Glob,Grep,Bash/);
  assert.match(seen, /--strict-mcp-config/);
});

test('HIMMEL_API_TOOLS=<empty> runs the call tool-free (no --allowedTools, empty --tools)', () => {
  const f = fixture();
  const r = f.run(f.good, { HIMMEL_API_TOOLS: '' });
  assert.equal(r.status, 0, r.stderr);
  const seen = readFileSync(f.paths.env, 'utf8');
  assert.doesNotMatch(seen, /allowedTools/);
  assert.match(seen, /--tools  --max-budget-usd/);
  assert.match(seen, /--strict-mcp-config/);
});

test('HIMMEL_API_TOOLS narrows to a subset of the default grant', () => {
  const f = fixture();
  const r = f.run(f.good, { HIMMEL_API_TOOLS: 'Read,Grep' });
  assert.equal(r.status, 0, r.stderr);
  const seen = readFileSync(f.paths.env, 'utf8');
  assert.match(seen, /--allowedTools Read,Grep /);
  assert.match(seen, /--tools Read,Grep /);
});

test('HIMMEL_API_TOOLS can never widen the grant: an unknown, wider or blank entry is refused before any launch', () => {
  for (const v of ['Read,WebFetch', 'Bash,Task', 'mcp__x__y', '*', 'Bash(*)', 'Read,*', 'Read,,Grep', ' Read', 'Read,']) {
    const f = fixture();
    const r = f.run(f.good, { HIMMEL_API_TOOLS: v });
    assert.equal(r.status, 2, `${JSON.stringify(v)}: ${r.stderr}`);
    assert.match(r.stderr, /HIMMEL_API_TOOLS/);
    assert.equal(f.called(), false, `${JSON.stringify(v)} must not launch`);
  }
});

test('a lane call from inside a Claude Code session drops the session markers, so it bills as -p/Agent SDK usage', () => {
  const f = fixture();
  const env = { ...f.env, CLAUDECODE: '1', CLAUDE_CODE_ENTRYPOINT: 'cli', CLAUDE_CODE_SESSION_ID: 's-1',
    CLAUDE_CODE_CHILD_SESSION: '1', CLAUDE_CODE_MESSAGING_TOKEN: 'msg-dummy', CLAUDE_CODE_MESSAGING_SOCKET: '/x/s.sock',
    CLAUDE_JOB_DIR: '/x/jobs/launcher', CLAUDE_CODE_EFFORT_LEVEL: 'max',
    CLAUDE_EFFORT: 'max', CLAUDE_PID: '1', AI_AGENT: 'claude-code' };
  const r = spawnSync('bash', [LAUNCH, ...f.good], { env, encoding: 'utf8', argv0: SESSION_ARGV0 });
  assert.equal(r.status, 0, r.stderr);
  const seen = readFileSync(f.paths.env, 'utf8');
  assert.match(seen, /^session_markers=0$/m);
  assert.match(seen, /^scrub=1$/m);
});

test('source metadata is preserved in the secret-free launch record', () => {
  const f = fixture();
  assert.equal(f.run().status, 0);
  const rec = JSON.parse(f.record().trim());
  assert.equal(rec.source, 'operator-console-snapshot');
  assert.deepEqual([rec.account, rec.organization_id, rec.key_id, rec.cycle_id, rec.model, rec.outcome],
    ['A', 'org-a', 'key-a', 'cycle-a', 'claude-haiku-5-5', 'settled']);
  for (const text of [f.record(), readFileSync(f.paths.state, 'utf8')]) assert.ok(!text.includes(DUMMY));
});

test('a reading of zero left is our estimate, not a block: the named account runs and the API credit answer decides', () => {
  const f = fixture();
  f.snapshot.accounts.A.remaining_usd = '0';
  f.save();
  writeFileSync(f.env.CADENCE_USAGE_CACHE, JSON.stringify({ five_hour: { utilization: 1 }, seven_day: { utilization: 1 } }));
  const r = f.run();
  assert.equal(r.status, 0, r.stderr);
  assert.doesNotMatch(r.stderr, /refused/);
  assert.equal(f.called(), true);
  // with enforce_budget on, the gate's SKIPPED-BANK is still only a note for the named account; the reservation decides
  f.config.enforce_budget = true;
  f.save();
  const e = f.run(f.good, { HIMMEL_API_JOB_ID: 'job-enforce' });
  assert.match(e.stderr, /api bank gate said SKIPPED-BANK; an unknown, stale or estimated balance is not a block/);
});

test('no automatic A/B rotation: a named A with zero left runs on A and B stays untouched', () => {
  const f = fixture();
  f.snapshot.accounts.A.remaining_usd = '0';
  f.save();
  assert.equal(f.run().status, 0);
  assert.equal(f.called(), true);
  assert.equal(f.status('B').reserved_usd, '0.000000');
  assert.equal(f.status('B').spent_est_usd, '0.000000');
});

test('absent key and selector/credential mismatch refuse before any spawn', () => {
  const f = fixture();
  const absent = f.run(f.good, { ANTHROPIC_API_KEY: '' });
  assert.equal(absent.status, 2);
  assert.match(absent.stderr, /no ANTHROPIC_API_KEY and no key file for account A/);
  const mismatch = f.run(f.good, { HIMMEL_API_KEY_ID: 'key-b' });
  assert.equal(mismatch.status, 2);
  assert.match(mismatch.stderr, /key id does not match account A/);
  const noId = f.run(f.good, { HIMMEL_API_KEY_ID: '' });
  assert.equal(noId.status, 2);
  assert.equal(f.called(), false);
  assert.equal(f.status().reserved_usd, '0.000000');
});

for (const [name, extra, pattern] of [
  ['bedrock flag', { CLAUDE_CODE_USE_BEDROCK: '1' }, /conflicting provider flag CLAUDE_CODE_USE_BEDROCK/],
  ['vertex flag', { CLAUDE_CODE_USE_VERTEX: '1' }, /conflicting provider flag CLAUDE_CODE_USE_VERTEX/],
  ['auth token', { ANTHROPIC_AUTH_TOKEN: 'tok-dummy' }, /conflicting provider ANTHROPIC_AUTH_TOKEN/],
  ['openrouter lane', { HIMMEL_CLAUDE_LANE: 'openrouter' }, /conflicting lane/],
  ['claudex lane', { HIMMEL_CLAUDE_LANE: 'claudex' }, /conflicting lane/],
]) {
  test(`conflicting provider (${name}) refuses`, () => {
    const f = fixture();
    const r = f.run(f.good, extra);
    assert.equal(r.status, 2);
    assert.match(r.stderr, pattern);
    assert.equal(f.called(), false);
  });
}

test('lane is OFF without the opt-in and invalid accounts refuse', () => {
  const f = fixture();
  assert.match(f.run(f.good, { HIMMEL_API_LANE: '' }).stderr, /api lane is OFF/);
  assert.match(f.run(f.good, { HIMMEL_API_ACCOUNT: 'E' }).stderr, /must be A, B, C or D/);
  assert.match(f.run(f.good, { HIMMEL_API_ACCOUNT: '' }).stderr, /must be A, B, C or D/);
  assert.equal(f.called(), false);
});

test('argument policy: print only, no bg/cloud/bypass, explicit mode, model and budget', () => {
  const f = fixture();
  const cases = [
    [['say hi', '--model', 'm', '--permission-mode', 'plan', '--max-budget-usd', '1'], /only -p/],
    [[...f.good, '--bg'], /not allowed/],
    [[...f.good, '--cloud'], /not allowed/],
    [[...f.good, '--dangerously-skip-permissions'], /not allowed/],
    [['-p', 'x', '--model', 'm', '--permission-mode', 'bypassPermissions', '--max-budget-usd', '1'], /bypassPermissions/],
    [['-p', 'x', '--model', 'm', '--max-budget-usd', '1'], /--permission-mode is required/],
    [['-p', 'x', '--permission-mode', 'plan', '--max-budget-usd', '1'], /--model is required/],
    [['-p', 'x', '--model', 'm', '--permission-mode', 'plan'], /--max-budget-usd is required/],
    [[...f.good, '--output-format', 'text'], /must be json/],
  ];
  for (const [args, pattern] of cases) {
    const r = f.run(args);
    assert.equal(r.status, 2, args.join(' '));
    assert.match(r.stderr, pattern);
  }
  assert.equal(f.called(), false);
  assert.equal(f.status().reserved_usd, '0.000000');
});

test('unverified completion keeps the full reservation as unknown', () => {
  const f = fixture();
  const r = f.run(f.good, { STUB_OUT: 'not json' });
  assert.equal(r.status, 0);
  assert.equal(f.status().reserved_usd, '0.100000');
  assert.equal(JSON.parse(f.record().trim()).outcome, 'unknown');
  const error = fixture();
  error.run(error.good, { STUB_OUT: JSON.stringify({ type: 'result', is_error: true, total_cost_usd: 0.01 }) });
  assert.equal(error.status().reserved_usd, '0.100000');
});

test('judge: bypass flags in any spelling and caller-supplied tool/settings/mcp flags are refused', () => {
  const f = fixture();
  const flags = ['--dangerously-skip-permissions=true', '--dangerously-skip-permissions=anything', '--allow-dangerously-skip-permissions=false',
    '--allowedTools', '--allowedTools=Bash', '--allowed-tools', '--allowed-tools=Bash', '--settings', '--settings={}', '--mcp-config', '--mcp-config=x.json',
    '--Dangerously-Skip-Permissions=true', '--dangerously_skip_permissions', '--ALLOWEDTOOLS=Bash', '--allowed_tools', '--MCP_CONFIG',
    '--tools', '--tools=Bash', '--TOOLS=Bash',
    '--plugin-dir', '--plugin-dir=x', '--plugin_dir', '--add-dir', '--add-dir=x', '@args.txt',
    '--plugin-url', '--plugin-url=x', '--environment', '--environment=x', '--remote-control', '--remote_control',
    '--agent', '--agent=x', '--agents', '--agents={}'];
  for (const flag of flags) {
    const r = f.run([...f.good, flag, ...(flag.includes('=') ? [] : ['x'])]);
    assert.equal(r.status, 2, flag);
    assert.match(r.stderr, /not allowed/, flag);
  }
  assert.equal(f.called(), false);
  assert.equal(f.status().reserved_usd, '0.000000');
});

test('only allowlisted caller flags pass; an unknown, attached or clustered flag is refused with no spawn or reservation', () => {
  const f = fixture();
  const flags = ['--some-future-flag', '--some-future-flag=1', '--SOME_FUTURE_FLAG', '-x', '-pc', '-pp', '-c', '-r', '-', '--print=x',
    '--resume', '--continue', '--fork-session', '--system-prompt', '--append-system-prompt', '--disallowedTools', '--strict-mcp-config',
    '--setting-sources', '--betas', '--fallback-model', '--debug-file', '--ide', '--chrome', '--teleport', '--session-id', '--MODEL=x', '--Effort'];
  for (const flag of flags) {
    const r = f.run([...f.good, flag, ...(flag.includes('=') ? [] : ['x'])]);
    assert.equal(r.status, 2, flag);
    assert.match(r.stderr, /not allowed/, flag);
  }
  assert.equal(f.called(), false);
  assert.equal(f.status().reserved_usd, '0.000000');
});

test('--effort, in both spellings, and the positional prompt still pass', () => {
  for (const [spelled, seen] of [[['--effort', 'high'], /--effort high/], [['--effort=low'], /--effort low/]]) {
    const ok = fixture();
    assert.equal(ok.run([...ok.good, ...spelled]).status, 0);
    assert.match(readFileSync(ok.paths.env, 'utf8'), seen);
  }
  const f = fixture();
  for (const bad of [['--effort'], ['--effort', '--settings'], ['--effort=a b']]) {
    const r = f.run([...f.good, ...bad]);
    assert.equal(r.status, 2, bad.join(' '));
  }
});

test('--append-system-prompt-file, in both spellings, takes a readable regular file and reaches claude unchanged', () => {
  const FLAG = '--append-system-prompt-file';
  const probe = fixture();
  const file = join(probe.dir, 'system.txt');
  writeFileSync(file, 'fixed instructions\n');
  const link = join(probe.dir, 'system-link.txt');
  symlinkSync(file, link);
  const spaced = join(probe.dir, 'system prompt.txt');
  writeFileSync(spaced, 'fixed instructions\n');
  for (const [spelled, seen] of [[[FLAG, file], file], [[`${FLAG}=${file}`], file], [[FLAG, link], link], [[FLAG, spaced], spaced], [[`${FLAG}=${spaced}`], spaced]]) {
    const ok = fixture();
    const r = ok.run([...ok.good, ...spelled]);
    assert.equal(r.status, 0, r.stderr);
    assert.ok(readFileSync(ok.paths.env, 'utf8').includes(`${FLAG} ${seen} `), spelled.join(' '));
  }
  const fb = fixture();
  const r = fb.run([...fb.good, FLAG, file], { ...FB_ON, HIMMEL_API_ACCOUNT: 'E', STUB_FB_OUT: FB_OK, CLAUDE_CODE_OAUTH_TOKEN: 'oauth-dummy', CLAUDECODE: '1' }, { argv0: SESSION_ARGV0 });
  assert.equal(r.status, 0, r.stderr);
  assert.ok(fbArgs(fb).join(' ').includes(`${FLAG} ${file}`), 'the subscription fallback carries the same system prompt');
});

test('--append-system-prompt-file refuses anything but a readable regular file, with no spawn or reservation', () => {
  const FLAG = '--append-system-prompt-file';
  const f = fixture();
  const dir = join(f.dir, 'a-dir');
  mkdirSync(dir);
  const fifo = join(f.dir, 'a-fifo');
  assert.equal(spawnSync('mkfifo', [fifo]).status, 0);
  const dirLink = join(f.dir, 'dir-link');
  symlinkSync(dir, dirLink);
  const dangling = join(f.dir, 'dangling-link');
  symlinkSync(join(f.dir, 'gone'), dangling);
  const unreadable = join(f.dir, 'unreadable.txt');
  writeFileSync(unreadable, 'x', { mode: 0o000 });
  // a real file named as a flag: its value would read as an option, so a dash-led value is refused like --model and --effort
  writeFileSync(join(f.dir, '--dangerously-skip-permissions'), 'x');
  const bad = [[FLAG, join(f.dir, 'missing.txt')], [`${FLAG}=${join(f.dir, 'missing.txt')}`], [FLAG, dir], [`${FLAG}=${dir}`], [FLAG, fifo],
    [FLAG, '/dev/null'], [FLAG, dirLink], [FLAG, dangling], [FLAG, ''], [`${FLAG}=`], [FLAG],
    [FLAG, '--dangerously-skip-permissions'], [`${FLAG}=--dangerously-skip-permissions`]];
  if (process.getuid() !== 0) bad.push([FLAG, unreadable]); // root reads a mode-000 file
  for (const spelled of bad) {
    const r = f.run([...f.good, ...spelled], {}, { cwd: f.dir });
    assert.equal(r.status, 2, spelled.join(' '));
    assert.match(r.stderr, /--append-system-prompt-file/, spelled.join(' '));
  }
  // negative control: the neighbours stay closed even with a readable regular file behind them
  const file = join(f.dir, 'system.txt');
  writeFileSync(file, 'fixed instructions\n');
  for (const flag of ['--append-system-prompt', '--system-prompt-file', `${FLAG}-x`, '--APPEND-SYSTEM-PROMPT-FILE']) {
    for (const spelled of [[flag, file], [`${flag}=${file}`]]) {
      const r = f.run([...f.good, ...spelled]);
      assert.equal(r.status, 2, spelled.join(' '));
      assert.match(r.stderr, /not allowed/, spelled.join(' '));
    }
  }
  assert.equal(f.called(), false);
  assert.equal(f.status().reserved_usd, '0.000000');
});

test('--model and --permission-mode refuse dash-led values and the mode is an allowlist, in both spellings', () => {
  const f = fixture();
  const without = (flag) => f.good.filter((_, i, a) => a[i] !== flag && a[i - 1] !== flag);
  const cases = [
    [['--model', '--anything'], /--model/], [['--model=--anything'], /--model/], [['--model', '-x'], /--model/],
    [['--permission-mode', '--dangerously-skip-permissions'], /permission mode/], [['--permission-mode=-x'], /permission mode/],
    [['--permission-mode', 'BypassPermissions'], /permission mode/], [['--permission-mode=BYPASSPERMISSIONS'], /permission mode/],
    [['--permission-mode', 'bypass_permissions'], /permission mode/], [['--permission-mode', 'nonsense'], /permission mode/],
  ];
  for (const [flag, re] of cases) {
    const r = f.run([...without(flag[0].split('=')[0]), ...flag]);
    assert.equal(r.status, 2, flag.join(' '));
    assert.match(r.stderr, re, flag.join(' '));
  }
  assert.equal(f.called(), false);
  assert.equal(f.status().reserved_usd, '0.000000');
  for (const mode of ['default', 'plan', 'acceptEdits', 'dontAsk', 'auto']) {
    const ok = fixture();
    assert.equal(ok.run([...without('--permission-mode'), `--permission-mode=${mode}`]).status, 0, mode);
  }
});

test('the exact argv shape scripts/eval/lane-quality/run.sh sends still passes', () => {
  const f = fixture();
  const r = f.run(['-p', 'do the task', '--model', 'claude-haiku-5-5', '--permission-mode', 'auto', '--output-format', 'json',
    '--max-budget-usd', '0.10', '--effort', 'high']);
  assert.equal(r.status, 0, r.stderr);
  assert.match(readFileSync(f.paths.env, 'utf8'), /--permission-mode auto/);
});

test('an argument terminator is refused so the enforced options stay options', () => {
  const f = fixture();
  const r = f.run(['-p', '--', 'x', '--model', 'm', '--permission-mode', 'plan', '--max-budget-usd', '0.10']);
  assert.equal(r.status, 2);
  assert.match(r.stderr, /argument terminator/);
  assert.equal(f.called(), false);
});

test('a cost above the reservation is recorded as overrun, never as settled', () => {
  const f = fixture();
  const r = f.run(f.good, { STUB_OUT: JSON.stringify({ type: 'result', is_error: false, total_cost_usd: 0.5 }) });
  assert.equal(r.status, 0);
  assert.match(r.stderr, /exceeded the reservation/);
  assert.equal(JSON.parse(f.record().trim()).outcome, 'overrun');
});

test('model and job id with JSON-unsafe characters refuse before any spawn', () => {
  const f = fixture();
  const bad = f.run(['-p', 'x', '--model', 'm"x', '--permission-mode', 'plan', '--max-budget-usd', '0.10']);
  assert.equal(bad.status, 2);
  assert.match(bad.stderr, /--model has characters/);
  const job = f.run(f.good, { HIMMEL_API_JOB_ID: 'j"1' });
  assert.equal(job.status, 2);
  assert.match(job.stderr, /job id has characters/);
  assert.equal(f.called(), false);
  assert.equal(existsSync(join(f.dir, 'launches.jsonl')), false);
});

test('with enforce_budget on, a budget above the available credit refuses at reservation', () => {
  const f = fixture();
  f.config.enforce_budget = true;
  f.save();
  const r = f.run(['-p', 'x', '--model', 'm', '--permission-mode', 'plan', '--max-budget-usd', '5.00']);
  assert.equal(r.status, 2);
  assert.match(r.stderr, /reservation refused|bank gate/);
  assert.equal(f.called(), false);
});

test('by default a budget above the available credit and past our own cap still runs: only the provider refuses for credit', () => {
  const f = fixture();
  const r = f.run(['-p', 'x', '--model', 'm', '--permission-mode', 'plan', '--max-budget-usd', '5.00']);
  assert.equal(r.status, 0, r.stderr);
  assert.doesNotMatch(r.stderr, /refused/);
  assert.equal(f.called(), true);
});

test('a non-API child is stripped of the key and every lane selector', () => {
  const f = fixture();
  // the fallback switch and the alert seams are neither credentials nor lane selectors
  const { HIMMEL_API_FALLBACK, HIMMEL_API_ALERT_CMD, HIMMEL_API_ALERT_DIR, ...lane } = f.env;
  const r = spawnSync('bash', [STRIP, '--', 'env'], { env: { ...lane, HIMMEL_API_CREDIT_FORMAT: 'bank' }, encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr);
  assert.ok(!r.stdout.includes('ANTHROPIC_API_KEY'));
  assert.ok(!r.stdout.includes(DUMMY));
  assert.ok(!/^HIMMEL_API_/m.test(r.stdout));
  const lq = spawnSync('bash', [STRIP, '--', 'env'], { env: { ...f.env, LQ_API_KEY: DUMMY, LQ_API_ACCOUNT: 'B', LQ_API_KEY_ID: 'k', LQ_API_LANE: 'on' }, encoding: 'utf8' });
  assert.ok(!/^LQ_API_/m.test(lq.stdout), 'LQ_API_* survived strip-env');
  assert.match(r.stdout, /^PATH=/m);
});

test('measure-credit reads the key from a file, refreshes the snapshot and prints only outcome and cost', () => {
  const f = fixture();
  const keyFile = join(f.dir, 'key.env');
  writeFileSync(keyFile, `ANTHROPIC_API_KEY=${DUMMY}\n`, { mode: 0o600 });
  const env = { ...f.env, CLAUDECODE: '1', CLAUDE_CODE_ENTRYPOINT: 'cli' };
  delete env.ANTHROPIC_API_KEY; delete env.HIMMEL_API_LANE; delete env.HIMMEL_API_KEY_ID; delete env.HIMMEL_API_JOB_ID;
  const r = spawnSync('bash', [MEASURE, 'A', 'key-a', keyFile, '1.75'], { env, encoding: 'utf8', argv0: SESSION_ARGV0 });
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /^total_cost_usd=0\.012345$/m);
  assert.match(r.stdout, /^is_error=false$/m);
  for (const text of [r.stdout, r.stderr, f.record()]) assert.ok(!text.includes(DUMMY));
  const seen = readFileSync(f.paths.env, 'utf8');
  assert.match(seen, /^key_present=1$/m);
  assert.match(seen, /^session_markers=0$/m);
  assert.match(seen, /--model claude-haiku-5-5/);
  assert.match(seen, /--max-budget-usd 0\.05/);
  assert.equal(JSON.parse(readFileSync(f.paths.snapshot, 'utf8')).accounts.A.remaining_usd, '1.750000');
});

const KEY_A = 'sk-ant-dummy-account-a-key-AAAA';
const KEY_B = 'sk-ant-dummy-account-b-key-BBBB';
function keyFiles(f, mode = 0o600) {
  writeFileSync(join(f.dir, 'key-A.env'), `ANTHROPIC_API_KEY=${KEY_A}\n`, { mode });
  writeFileSync(join(f.dir, 'key-B.env'), `ANTHROPIC_API_KEY=${KEY_B}\n`, { mode });
  chmodSync(join(f.dir, 'key-A.env'), mode); chmodSync(join(f.dir, 'key-B.env'), mode);
  const env = { ...f.env };
  delete env.ANTHROPIC_API_KEY; delete env.HIMMEL_API_KEY_ID;
  return env;
}
const launch = (env, extra = {}) => spawnSync('bash', [LAUNCH, '-p', 'say hi', '--model', 'claude-haiku-5-5',
  '--permission-mode', 'plan', '--max-budget-usd', '0.10'], { env: { ...env, ...extra }, encoding: 'utf8', cwd: HIMMEL_REPO });

test('with no key in the caller env the launcher reads key-<account>.env beside the ledger, child env only', () => {
  const f = fixture();
  const r = launch(keyFiles(f), { HIMMEL_API_ACCOUNT: 'B' });
  assert.equal(r.status, 0, r.stderr);
  assert.match(readFileSync(f.paths.env, 'utf8'), /^key_tail=BBBB$/m);
  assert.equal(JSON.parse(f.record().trim()).key_id, 'key-b');
  for (const text of [r.stdout, r.stderr, f.record()]) assert.ok(!text.includes(KEY_B));
});

test('a key file readable by others, or none at all, refuses before any reservation or spawn', () => {
  const f = fixture();
  const loose = launch(keyFiles(f, 0o644), { HIMMEL_API_ACCOUNT: 'A' });
  assert.equal(loose.status, 2);
  assert.match(loose.stderr, /key file for account A must be mode 600/);
  const env = keyFiles(f);
  rmSync(join(f.dir, 'key-A.env'));
  const none = launch(env, { HIMMEL_API_ACCOUNT: 'A' });
  assert.equal(none.status, 2);
  assert.match(none.stderr, /no ANTHROPIC_API_KEY and no key file for account A/);
  assert.equal(f.called(), false);
  assert.equal(f.status().reserved_usd, '0.000000');
});

test('HIMMEL_API_ACCOUNT=auto spends the earliest-expiring grant first, never past its cap', () => {
  const f = fixture();
  f.snapshot.accounts.A.expires_at += 7200;  // A expires after B
  f.save();
  const env = keyFiles(f);
  const first = launch(env, { HIMMEL_API_ACCOUNT: 'auto', HIMMEL_API_KIND: 'graphify', HIMMEL_API_JOB_ID: 'job-auto-1' });
  assert.equal(first.status, 0, first.stderr);
  assert.match(readFileSync(f.paths.env, 'utf8'), /^key_tail=BBBB$/m);
  // B has 0.05 left: a 0.10 budget does not fit, so A takes the next call.
  f.snapshot.accounts.B.remaining_usd = '0.05';
  f.snapshot.accounts.B.reconciled_spent_usd = '0.012345';
  f.save();
  const second = launch(env, { HIMMEL_API_ACCOUNT: 'auto', HIMMEL_API_KIND: 'graphify', HIMMEL_API_JOB_ID: 'job-auto-2' });
  assert.equal(second.status, 0, second.stderr);
  assert.match(readFileSync(f.paths.env, 'utf8'), /^key_tail=AAAA$/m);
  assert.deepEqual(f.record().trim().split('\n').map((l) => JSON.parse(l).account), ['B', 'A']);
  // Neither fits, with enforce_budget on: refuse, no spawn.
  f.snapshot.accounts.A.remaining_usd = '0.05';
  f.snapshot.accounts.A.reconciled_spent_usd = '0.012345';
  f.config.enforce_budget = true;
  f.save();
  rmSync(f.paths.log);
  const third = launch(env, { HIMMEL_API_ACCOUNT: 'auto', HIMMEL_API_KIND: 'graphify', HIMMEL_API_JOB_ID: 'job-auto-3' });
  assert.equal(third.status, 2);
  assert.match(third.stderr, /no account has room/);
  assert.equal(f.called(), false);
});

test('auto routing launches on a snapshot older than 24 h and warns', () => {
  const f = fixture();
  for (const a of ['A', 'B']) { f.snapshot.accounts[a].starts_at = f.now - 400000; f.snapshot.accounts[a].observed_at = f.now - 90000; }
  f.save();
  const r = launch(keyFiles(f), { HIMMEL_API_ACCOUNT: 'auto', HIMMEL_API_KIND: 'graphify', HIMMEL_API_JOB_ID: 'job-stale-1' });
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stderr, /WARN.*credit reading/);
  assert.equal(f.called(), true);
});

test('auto routing launches with no snapshot file at all, inside the caps', () => {
  const f = fixture();
  rmSync(f.paths.snapshot);
  const r = launch(keyFiles(f), { HIMMEL_API_ACCOUNT: 'auto', HIMMEL_API_KIND: 'graphify', HIMMEL_API_JOB_ID: 'job-nosnap-1' });
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stderr, /WARN.*credit reading/);
  assert.equal(f.called(), true);
});

function ledgerAtCap(f) {
  const accounts = {};
  for (const [name, cap] of [['A', '1.00'], ['B', '2.00']]) {
    accounts[name] = { organization_id: f.config.accounts[name].organization_id, cycle_id: f.config.accounts[name].cycle_id,
      discrepancy: false, jobs: { 'spent-1': { status: 'settled', maximum_usd: cap, actual_usd: cap } } };
  }
  writeFileSync(f.paths.state, JSON.stringify({ version: 1, accounts }));
}

test('auto routing goes on past the bank gate when the old reading and the ledger leave no room', () => {
  const f = fixture();
  for (const a of ['A', 'B']) { f.snapshot.accounts[a].starts_at = f.now - 400000; f.snapshot.accounts[a].observed_at = f.now - 90000; }
  f.save();
  ledgerAtCap(f);
  const r = launch(keyFiles(f), { HIMMEL_API_ACCOUNT: 'auto', HIMMEL_API_KIND: 'graphify', HIMMEL_API_JOB_ID: 'job-over-1' });
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stderr, /spend estimate has no room/);
  assert.equal(f.called(), true);
});

test('with enforce_budget on, a caller-set optional flag does not widen the cap: an explicit account over our own cap still refuses', () => {
  const f = fixture();
  f.config.enforce_budget = true;
  f.save();
  writeFileSync(f.paths.state, JSON.stringify({ version: 1, accounts: { A: { organization_id: 'org-a', cycle_id: 'cycle-a', discrepancy: false,
    jobs: { spent: { status: 'settled', maximum_usd: '0.950000', actual_usd: '0.950000', reserved_at: f.now, timeout_s: 3600 } } } } }));
  const r = f.run(f.good, { HIMMEL_API_SNAPSHOT_OPTIONAL: '1' });
  assert.equal(r.status, 2);
  assert.match(r.stderr, /reservation refused/);
  assert.equal(f.called(), false);
});

test('a lane-off refusal never takes the subscription fallback, whatever the kind', () => {
  for (const kind of ['other', 'eval', 'judge', 'critic']) {
    const f = fixture();
    const r = f.run(f.good, { ...FB_ON, HIMMEL_API_LANE: '', HIMMEL_API_KIND: kind, STUB_FB_OUT: FB_OK });
    assert.equal(r.status, 2, `${kind}: ${r.stderr}`);
    assert.match(r.stderr, /api lane is OFF/);
    assert.match(r.stderr, /fallback: not run: /, kind);
    assert.equal(fbCalls(f), 0, kind);
    assert.equal(f.called(), false, kind);
  }
});

test('a refusal alerts for the eval kind only: a critic kind or a lane off by design sends none', () => {
  const critic = fixture();
  const a = critic.run(critic.good, { HIMMEL_API_LANE: '', HIMMEL_API_KIND: 'critic' });
  assert.equal(a.status, 2, a.stderr);
  assert.match(a.stderr, /api lane is OFF/);
  assert.deepEqual(alerts(critic), [], 'a critic refusal raised an alert');
  const evalKind = fixture();
  const b = evalKind.run(evalKind.good, { HIMMEL_API_LANE: '', HIMMEL_API_KIND: 'eval' });
  assert.equal(b.status, 2, b.stderr);
  assert.equal(alerts(evalKind).length, 1, 'an eval refusal raised no alert');
  assert.match(alertText(evalKind), /kind eval/);
});

test('a critic call never takes the subscription fallback, for a refusal or a failed call', () => {
  const refused = fixture();
  const a = refused.run(refused.good, { ...FB_ON, HIMMEL_API_KIND: 'critic', HIMMEL_API_ACCOUNT: 'E', STUB_FB_OUT: FB_OK });
  assert.equal(a.status, 2, a.stderr);
  assert.match(a.stderr, /fallback: not run: a critic call never runs on the subscription/);
  assert.equal(fbCalls(refused), 0);
  const failed = fixture();
  const b = failed.run(failed.good, { ...FB_ON, HIMMEL_API_KIND: 'critic', STUB_OUT: CALL_FAIL, STUB_RC: '1', STUB_FB_OUT: FB_OK });
  assert.equal(b.status, 1, b.stderr);
  assert.match(b.stderr, /fallback: not run: a critic call never runs on the subscription/);
  assert.equal(fbCalls(failed), 0);
  const dry = fixture();
  const c = dry.run(dry.good, { ...FB_ON, HIMMEL_API_KIND: 'critic', STUB_OUT: DEAD, STUB_RC: '1', STUB_FB_OUT: FB_OK });
  assert.equal(c.status, 6, c.stderr);
  assert.equal(fbCalls(dry), 0);
  const other = fixture();
  const d = other.run(other.good, { ...FB_ON, HIMMEL_API_KIND: 'judge', HIMMEL_API_ACCOUNT: 'E', STUB_FB_OUT: FB_OK });
  assert.equal(d.status, 0, d.stderr);
  assert.equal(fbCalls(other), 1);
});

const DEAD = JSON.stringify({ type: 'result', is_error: true, result: 'API Error: 400 Your credit balance is too low to access the Anthropic API.' });
const keysUsed = (f) => (existsSync(`${f.paths.log}.keys`) ? readFileSync(`${f.paths.log}.keys`, 'utf8').trim().split('\n') : []);
const exhaustedAt = (f, a) => JSON.parse(readFileSync(f.paths.state, 'utf8')).accounts[a]?.exhausted_at;

test('a credit-refused auto call marks the account and the same call runs again on the next account', () => {
  const f = fixture();
  const r = launch(keyFiles(f), { HIMMEL_API_ACCOUNT: 'auto', HIMMEL_API_KIND: 'graphify', HIMMEL_API_JOB_ID: 'job-dry-1',
    STUB_DEAD_TAILS: 'AAAA', STUB_DEAD_OUT: DEAD });
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual(keysUsed(f), ['AAAA', 'BBBB']);
  assert.match(r.stderr, /rotating this call to account B \(tried A\)/);
  assert.match(r.stdout, /"result":"hi"/);
  assert.equal(Number.isInteger(exhaustedAt(f, 'A')), true);
  assert.deepEqual(f.record().trim().split('\n').map((l) => [JSON.parse(l).account, JSON.parse(l).outcome]), [['A', 'exhausted'], ['B', 'settled']]);
  assert.equal(f.status('A').reserved_usd, '0.000000');
  assert.equal(f.status('B').reserved_usd, '0.000000');
  // the next auto call starts on the unmarked B
  rmSync(`${f.paths.log}.keys`);
  const next = launch(keyFiles(f), { HIMMEL_API_ACCOUNT: 'auto', HIMMEL_API_KIND: 'graphify', HIMMEL_API_JOB_ID: 'job-dry-2' });
  assert.equal(next.status, 0, next.stderr);
  assert.deepEqual(keysUsed(f), ['BBBB']);
});

test('a stdin prompt is replayed to the rotated call', () => {
  const f = fixture();
  const r = spawnSync('bash', [LAUNCH, ...STDIN_ONLY], { env: { ...keyFiles(f), HIMMEL_API_ACCOUNT: 'auto', HIMMEL_API_KIND: 'graphify',
    HIMMEL_API_JOB_ID: 'job-dry-in', STUB_STDIN: join(f.dir, 'stdin.seen'), STUB_DEAD_TAILS: 'AAAA', STUB_DEAD_OUT: DEAD },
  input: PROMPT, encoding: 'utf8', cwd: HIMMEL_REPO });
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual(keysUsed(f), ['AAAA', 'BBBB']);
  assert.equal(readFileSync(join(f.dir, 'stdin.seen'), 'utf8'), PROMPT);
});

test('rotation stops after one pass: every account credit-refused exits 6 with one alert and one fallback decision', () => {
  const f = fixture();
  const r = launch(keyFiles(f), { ...FB_ON, HIMMEL_API_ACCOUNT: 'auto', HIMMEL_API_KIND: 'graphify', HIMMEL_API_JOB_ID: 'job-dry-all',
    STUB_DEAD_TAILS: 'AAAA,BBBB', STUB_DEAD_OUT: DEAD });
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual(keysUsed(f), ['AAAA', 'BBBB']);
  assert.equal(fbCalls(f), 1);
  assert.equal(alerts(f).length, 1);
  assert.equal(Number.isInteger(exhaustedAt(f, 'A')), true);
  assert.equal(Number.isInteger(exhaustedAt(f, 'B')), true);
  const off = fixture();
  const o = launch(keyFiles(off), { HIMMEL_API_ACCOUNT: 'auto', HIMMEL_API_KIND: 'graphify', HIMMEL_API_JOB_ID: 'job-dry-off',
    STUB_DEAD_TAILS: 'AAAA,BBBB', STUB_DEAD_OUT: DEAD });
  assert.equal(o.status, 6, o.stderr);
  assert.deepEqual(keysUsed(off), ['AAAA', 'BBBB']);
});

test('rotation skips an account already marked exhausted: with the only other account marked, the fallback follows', () => {
  const f = fixture();
  const env = keyFiles(f);
  spawnSync(process.execPath, [STATE, 'exhausted'], { env: { ...f.env, HIMMEL_API_ACCOUNT: 'B' }, encoding: 'utf8' });
  const r = launch(env, { ...FB_ON, HIMMEL_API_ACCOUNT: 'auto', HIMMEL_API_KIND: 'graphify', HIMMEL_API_JOB_ID: 'job-dry-skip',
    STUB_DEAD_TAILS: 'AAAA', STUB_DEAD_OUT: DEAD });
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual(keysUsed(f), ['AAAA']);
  assert.doesNotMatch(r.stderr, /rotating this call/);
  assert.equal(fbCalls(f), 1);
});

test('rotation never fires for a named account or a call granted Edit, Write or Bash', () => {
  const named = fixture();
  const n = launch(keyFiles(named), { HIMMEL_API_ACCOUNT: 'A', HIMMEL_API_JOB_ID: 'job-dry-named', STUB_DEAD_TAILS: 'AAAA', STUB_DEAD_OUT: DEAD });
  assert.equal(n.status, 6, n.stderr);
  assert.deepEqual(keysUsed(named), ['AAAA']);
  for (const tool of ['Edit', 'Write', 'Bash']) {
    const w = fixture();
    const r = launch(keyFiles(w), { HIMMEL_API_ACCOUNT: 'auto', HIMMEL_API_KIND: 'graphify', HIMMEL_API_JOB_ID: `job-dry-${tool}`,
      HIMMEL_API_TOOLS: `Read,${tool}`, STUB_DEAD_TAILS: 'AAAA', STUB_DEAD_OUT: DEAD });
    assert.equal(r.status, 6, `${tool}: ${r.stderr}`);
    assert.deepEqual(keysUsed(w), ['AAAA'], tool);
    assert.doesNotMatch(r.stderr, /rotating this call/, tool);
  }
});

test('a caller cannot widen the route through the tried list: a malformed list is ignored, a full one refuses', () => {
  const f = fixture();
  const all = launch(keyFiles(f), { HIMMEL_API_ACCOUNT: 'auto', HIMMEL_API_KIND: 'graphify', HIMMEL_API_JOB_ID: 'job-tried-all', HIMMEL_API_ROTATE_TRIED: 'A,B' });
  assert.equal(all.status, 2, all.stderr);
  assert.match(all.stderr, /every account was already tried/);
  assert.equal(f.called(), false);
  const bad = launch(keyFiles(f), { HIMMEL_API_ACCOUNT: 'auto', HIMMEL_API_KIND: 'graphify', HIMMEL_API_JOB_ID: 'job-tried-bad', HIMMEL_API_ROTATE_TRIED: 'A;B' });
  assert.equal(bad.status, 0, bad.stderr);
});

test('a credit-too-low result exits 6, the non-retryable code, and the launch record names it exhausted', () => {
  const f = fixture();
  const dead = JSON.stringify({ type: 'result', is_error: true, result: 'API Error: 400 Your credit balance is too low to access the Anthropic API.' });
  const r = launch(keyFiles(f), { HIMMEL_API_ACCOUNT: 'B', HIMMEL_API_JOB_ID: 'job-dry-3', STUB_OUT: dead, STUB_RC: '1' });
  assert.equal(r.status, 6, r.stderr);
  assert.equal(JSON.parse(f.record().trim().split('\n').pop()).outcome, 'exhausted');
  assert.equal(Number.isInteger(JSON.parse(readFileSync(f.paths.state, 'utf8')).accounts.B.exhausted_at), true);
});

test('an invalid-key result flags the account, exits 6 and the next auto pick skips it', () => {
  const f = fixture();
  const env = keyFiles(f);
  const bad = JSON.stringify({ type: 'result', is_error: true, result: 'Invalid API key · Fix external API key' });
  const first = launch(env, { HIMMEL_API_ACCOUNT: 'auto', HIMMEL_API_KIND: 'graphify', HIMMEL_API_JOB_ID: 'job-key-1', STUB_OUT: bad, STUB_RC: '1' });
  assert.equal(first.status, 6, first.stderr);
  assert.match(readFileSync(f.paths.env, 'utf8'), /^key_tail=AAAA$/m);
  assert.match(first.stderr, /API key rejected/);
  assert.equal(JSON.parse(f.record().trim().split('\n').pop()).outcome, 'key_invalid');
  assert.equal(Number.isInteger(JSON.parse(readFileSync(f.paths.state, 'utf8')).accounts.A.exhausted_at), true);
  const second = launch(env, { HIMMEL_API_ACCOUNT: 'auto', HIMMEL_API_KIND: 'graphify', HIMMEL_API_JOB_ID: 'job-key-2' });
  assert.equal(second.status, 0, second.stderr);
  assert.match(readFileSync(f.paths.env, 'utf8'), /^key_tail=BBBB$/m);
});

test('a plain failure that is neither rejection keeps the call exit code', () => {
  const f = fixture();
  const r = launch(keyFiles(f), { HIMMEL_API_ACCOUNT: 'B', HIMMEL_API_JOB_ID: 'job-plain-1', STUB_OUT: JSON.stringify({ type: 'result', is_error: true, result: 'boom' }), STUB_RC: '1' });
  assert.equal(r.status, 1, r.stderr);
  assert.equal(JSON.parse(f.record().trim().split('\n').pop()).outcome, 'failed');
});

test('a failed call whose permission denials quote the phrase, but whose result does not, is not a rejection', () => {
  const f = fixture();
  const quoted = JSON.stringify({ type: 'result', is_error: true, result: 'boom', permission_denials: [{ tool_name: 'Bash', tool_input: { command: 'echo invalid api key; echo credit balance is too low' } }] });
  const r = launch(keyFiles(f), { HIMMEL_API_ACCOUNT: 'B', HIMMEL_API_JOB_ID: 'job-quote-1', STUB_OUT: quoted, STUB_RC: '1' });
  assert.equal(r.status, 1, r.stderr);
  assert.equal(JSON.parse(f.record().trim().split('\n').pop()).outcome, 'failed');
  assert.equal(existsSync(f.paths.state) && JSON.parse(readFileSync(f.paths.state, 'utf8')).accounts?.B?.exhausted_at !== undefined, false);
});

test('a successful call whose result text mentions an invalid API key is not a rejection', () => {
  const f = fixture();
  const ok = JSON.stringify({ type: 'result', is_error: false, result: 'The message was: Invalid API key', total_cost_usd: 0.01 });
  const r = launch(keyFiles(f), { HIMMEL_API_ACCOUNT: 'B', HIMMEL_API_JOB_ID: 'job-quote-2', STUB_OUT: ok, STUB_RC: '0' });
  assert.equal(r.status, 0, r.stderr);
  assert.notEqual(JSON.parse(f.record().trim().split('\n').pop()).outcome, 'key_invalid');
});

test('auto routing refuses a caller-supplied key, which cannot follow the pick', () => {
  const f = fixture();
  const r = f.run(f.good, { HIMMEL_API_ACCOUNT: 'auto', HIMMEL_API_KIND: 'graphify' });
  assert.equal(r.status, 2);
  assert.match(r.stderr, /auto routing reads the per-account key files/);
  assert.equal(f.called(), false);
});

test('a Console refresh does not count already-billed ledger spend twice', () => {
  const f = fixture();
  assert.equal(f.run().status, 0);  // settles 0.012345 on A
  const keyFile = join(f.dir, 'key.env');
  writeFileSync(keyFile, `ANTHROPIC_API_KEY=${DUMMY}\n`, { mode: 0o600 });
  const env = { ...f.env };
  delete env.ANTHROPIC_API_KEY; delete env.HIMMEL_API_LANE; delete env.HIMMEL_API_KEY_ID; delete env.HIMMEL_API_JOB_ID;
  // The Console now shows the first job billed: 2.00 - 0.012345.
  const r = spawnSync('bash', [MEASURE, 'A', 'key-a', keyFile, '1.987655'], { env, encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr);
  // The billed job once plus the measure call once, never the billed job twice.
  assert.equal(f.status().spent_est_usd, '0.024690');
});

test('the key reaches claude through the environment only, never through any argv', () => {
  const f = fixture();
  const bin = join(f.dir, 'bin');
  const argv = join(f.dir, 'env-argv');
  mkdirSync(bin);
  writeFileSync(join(bin, 'env'), `#!/bin/bash\nprintf '%s\\n' "$*" >> "${argv}"\nexec /usr/bin/env "$@"\n`, { mode: 0o700 });
  const r = launch(keyFiles(f), { HIMMEL_API_ACCOUNT: 'B', PATH: `${bin}:${process.env.PATH}` });
  assert.equal(r.status, 0, r.stderr);
  assert.match(readFileSync(f.paths.env, 'utf8'), /^key_tail=BBBB$/m);
  const seen = readFileSync(argv, 'utf8');
  assert.match(seen, /claude-stub/);
  assert.ok(!seen.includes(KEY_B), 'key appeared in an env argv');
  assert.ok(!readFileSync(f.paths.env, 'utf8').split('\n').find((l) => l.startsWith('args=')).includes(KEY_B));
});

test('a refresh while the Console lags a fresh settlement still counts that settlement', () => {
  const f = fixture();
  // 0.09 spent outside the ledger is already billed and reconciled.
  f.snapshot.accounts.A.remaining_usd = '1.91'; f.save();
  assert.equal(f.run().status, 0);  // settles 0.012345 on A, not yet on the Console
  const r = spawnSync(process.execPath, [join(HERE, 'grant-snapshot.mjs'), 'A', '1.91'], { env: f.env, encoding: 'utf8' });
  assert.equal(r.status, 0, r.stdout + r.stderr);
  assert.equal(f.status().spent_est_usd, '0.102345');
});

test('a refresh holds the ledger lock and refuses while another writer has it', () => {
  const f = fixture();
  mkdirSync(`${f.paths.state}.lock`);
  const r = spawnSync(process.execPath, [join(HERE, 'grant-snapshot.mjs'), 'A', '2.00'], { env: f.env, encoding: 'utf8' });
  assert.equal(r.status, 1);
  assert.match(r.stdout, /ledger-locked-or-unwritable/);
  assert.equal(JSON.parse(readFileSync(f.paths.snapshot, 'utf8')).accounts.A.observed_at, f.snapshot.accounts.A.observed_at);
});

test('a refresh takes the ledger lock before it reads the snapshot', () => {
  const f = fixture();
  mkdirSync(`${f.paths.state}.lock`);
  writeFileSync(f.paths.snapshot, '{ not json');
  const r = spawnSync(process.execPath, [join(HERE, 'grant-snapshot.mjs'), 'A', '2.00'], { env: f.env, encoding: 'utf8' });
  assert.match(r.stdout, /ledger-locked-or-unwritable/);
});

test('the child never sees the Admin API org keys', () => {
  const f = fixture();
  const r = f.run(f.good, { ANTHROPIC_ORG_A_KEY: 'admin-a-fixture', ANTHROPIC_ORG_B_KEY: 'admin-b-fixture' });
  assert.equal(r.status, 0, r.stderr);
  assert.match(readFileSync(f.paths.env, 'utf8'), /^org_keys=0$/m);
});

test('the reservation lives exactly as long as the call, so the api cap bounds real concurrency', async () => {
  const f = fixture();
  const hold = join(f.dir, 'hold'); writeFileSync(hold, '');
  const env = { ...f.env, HIMMEL_API_MAX_CONCURRENT: '1', STUB_HOLD: hold };
  const first = spawn('bash', [LAUNCH, ...f.good], { env, stdio: 'ignore' });
  const done = new Promise((resolve) => first.on('close', resolve));
  // Whatever fails below, the held stub is released and the child reaped, never left looping.
  const release = () => { rmSync(hold, { force: true }); first.kill(); };
  let second;
  try {
    const until = Date.now() + 15000;
    // The stub creates the env file before it writes ppid/resv_pid, so wait for both fields.
    const complete = () => existsSync(f.paths.env) && /^resv_pid=\d+$/m.test(readFileSync(f.paths.env, 'utf8'));
    while (!complete() && Date.now() < until) await new Promise((r) => setTimeout(r, 50));
    assert.equal(complete(), true, 'first call never reached the stub');
    // The reservation names the launcher shell that waits on claude, not a dead subshell.
    const seen = readFileSync(f.paths.env, 'utf8');
    const ppid = /^ppid=(\d+)$/m.exec(seen)[1];
    assert.equal(/^resv_pid=(\d+)$/m.exec(seen)[1], ppid);
    // A second launch, even one carrying an inherited non-api worker name, hits the api cap.
    second = spawnSync('bash', [LAUNCH, ...f.good], { env: { ...env, HIMMEL_API_JOB_ID: 'job-2', CADENCE_USAGE_WORKER: 'inherited-worker' }, encoding: 'utf8', timeout: 30000 });
  } finally { rmSync(hold, { force: true }); }
  assert.equal(second.status, 2);
  assert.match(second.stderr, /api bank gate said SKIPPED-FLEET/);
  assert.match(second.stderr, /api lane at\/over its own cap \(1\/1\)/);
  const timer = setTimeout(release, 20000);
  assert.equal(await done, 0);
  clearTimeout(timer);
  // Released at call end: the slot dir holds no reservation and the next call is admitted.
  assert.deepEqual(readdirSync(env.HIMMEL_FLEET_SLOTS).filter((n) => n.startsWith('claude-api:')), []);
  const third = spawnSync('bash', [LAUNCH, ...f.good], { env: { ...f.env, HIMMEL_API_MAX_CONCURRENT: '1', HIMMEL_API_JOB_ID: 'job-3' }, encoding: 'utf8' });
  assert.equal(third.status, 0, third.stderr);
});

test('a grant date that does not exist on the calendar is refused, not rolled over', () => {
  const f = fixture();
  const r = spawnSync(process.execPath, [join(HERE, 'grant-snapshot.mjs'), 'A', '2.00', '2.00', '2026-01-01', '2026-02-30'],
    { env: f.env, encoding: 'utf8' });
  assert.equal(r.status, 1);
  assert.match(r.stdout, /invalid-date/);
});

const USAGE_OUT = JSON.stringify({ type: 'result', is_error: false, total_cost_usd: 0.004, result: 'ok',
  usage: { input_tokens: 12, cache_creation_input_tokens: 3000, cache_read_input_tokens: 9000 } });

test('the launcher moves per-machine prompt sections out of the cached system prompt', () => {
  const f = fixture();
  assert.equal(f.run().status, 0);
  assert.match(readFileSync(f.paths.env, 'utf8'), /--exclude-dynamic-system-prompt-sections/);
});

test('the main-conversation cache TTL is 5m by default, 1h on request, and a caller CLAUDE_CODE_PROMPT_CACHE_TTL never wins', () => {
  const f = fixture();
  // A CLAUDE_CODE_* variable is a session marker, so the call runs under a `claude` argv0 as a real session does.
  const first = spawnSync('bash', [LAUNCH, ...f.good], { env: { ...f.env, CLAUDE_CODE_PROMPT_CACHE_TTL: '1h' }, encoding: 'utf8', argv0: SESSION_ARGV0 });
  assert.equal(first.status, 0, first.stderr);
  assert.match(readFileSync(f.paths.env, 'utf8'), /^cache_ttl=5m$/m);
  assert.equal(f.run(f.good, { HIMMEL_API_CACHE_TTL: '1h', HIMMEL_API_JOB_ID: 'job-2' }).status, 0);
  assert.match(readFileSync(f.paths.env, 'utf8'), /^cache_ttl=1h$/m);
});

test('a cache TTL or run kind outside the allowlist refuses before any spawn', () => {
  const f = fixture();
  for (const bad of [{ HIMMEL_API_CACHE_TTL: '2h' }, { HIMMEL_API_KIND: 'a b' }, { HIMMEL_API_KIND: '"x' }]) {
    const r = f.run(f.good, bad);
    assert.equal(r.status, 2, JSON.stringify(bad));
    assert.match(r.stderr, /refused/);
  }
  assert.equal(f.called(), false);
});

test('the launch record carries kind, TTL and the usage split so a hit rate can be read back', () => {
  const f = fixture();
  assert.equal(f.run(f.good, { STUB_OUT: USAGE_OUT, HIMMEL_API_KIND: 'eval', HIMMEL_API_CACHE_TTL: '1h' }).status, 0);
  const row = JSON.parse(f.record().trim().split('\n').pop());
  assert.equal(row.kind, 'eval');
  assert.equal(row.cache_ttl, '1h');
  assert.equal(row.input_tokens, 12);
  assert.equal(row.cache_creation_tokens, 3000);
  assert.equal(row.cache_read_tokens, 9000);
});

test('a result without a usage object records null token counts, never zeros', () => {
  const f = fixture();
  assert.equal(f.run().status, 0);
  const row = JSON.parse(f.record().trim().split('\n').pop());
  assert.equal(row.kind, 'other');
  assert.equal(row.cache_read_tokens, null);
});

const REPORT = join(HERE, 'cache-report.mjs');
const usageRow = (ts, kind, ttl, i, c, r, model = 'm', org = 'o') => JSON.stringify({ ts, kind, model, organization_id: org, cache_ttl: ttl, input_tokens: i, cache_creation_tokens: c, cache_read_tokens: r });

test('cache-report prints a per-kind hit rate and picks the TTL from the measured gaps', () => {
  const f = fixture();
  const log = join(f.dir, 'launches.jsonl');
  writeFileSync(log, [
    usageRow('2026-10-14T10:00:00Z', 'eval', '5m', 10, 4000, 0),
    usageRow('2026-10-14T10:02:00Z', 'eval', '5m', 10, 100, 4000),
    usageRow('2026-10-14T10:20:00Z', 'bulk', '5m', 10, 4000, 0),
    usageRow('2026-10-14T10:50:00Z', 'bulk', '5m', 10, 4000, 0),
    usageRow('2026-10-14T11:20:00Z', 'bulk', '5m', 10, 4000, 0),
    usageRow('2026-10-14T10:01:00Z', 'eval', '5m', 10, 4000, 0, 'm', 'other-org'),
    usageRow('2026-10-14T10:03:00Z', '__proto__', '5m', 10, 4000, 0),
    '{"ts":"2026-10-14T09:00:00Z","kind":"eval","cache_read_tokens":null}',
  ].join('\n') + '\n');
  const r = spawnSync(process.execPath, [REPORT, log], { encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr);
  const out = JSON.parse(r.stdout);
  assert.equal(out['eval | m | o'].runs, 2);
  assert.equal(out['eval | m | o'].hit_rate, 4000 / (4010 + 4110));
  assert.equal(out['eval | m | o'].recommended_ttl, '5m');
  assert.equal(out['bulk | m | o'].recommended_ttl, '1h');
  assert.equal(out['eval | m | other-org'].runs, 1, 'a run in another organization is its own group');
  assert.equal(out['__proto__ | m | o'].runs, 1, 'a kind named like an Object property still groups');
});

test('cache-report gives no group to a native release judge row', () => {
  const f = fixture();
  const log = join(f.dir, 'launches.jsonl');
  const native = JSON.stringify({ ts: '2026-11-20T10:01:00Z', kind: 'judge', model: 'opus', lane: 'native', cache_ttl: 'off', input_tokens: 336000, cache_creation_tokens: 0, cache_read_tokens: 649 });
  const api = [usageRow('2026-11-20T10:00:00Z', 'judge', '5m', 10, 4000, 0, 'opus'), usageRow('2026-11-20T10:02:00Z', 'judge', '5m', 10, 100, 4000, 'opus')];
  writeFileSync(log, api.join('\n') + '\n');
  const alone = spawnSync(process.execPath, [REPORT, log], { encoding: 'utf8' });
  writeFileSync(log, [api[0], native, api[1]].join('\n') + '\n');
  const mixed = spawnSync(process.execPath, [REPORT, log], { encoding: 'utf8' });
  assert.equal(mixed.status, 0, mixed.stderr);
  assert.deepEqual(Object.keys(JSON.parse(mixed.stdout)), ['judge | opus | o']);
  assert.equal(mixed.stdout, alone.stdout);
});

// a dead call must not hold its reservation (killed calls on account B kept 20.10 USD reserved).
test('a call that exits non-zero settles its reservation instead of leaving it open', () => {
  const f = fixture();
  const r = f.run(f.good, { STUB_RC: '3', STUB_OUT: 'boom' });
  assert.equal(r.status, 3);
  assert.equal(f.status().reserved_usd, '0.000000');
  const rec = JSON.parse(f.record().trim());
  assert.equal(rec.outcome, 'failed');
  assert.equal(rec.cost_usd, '0.000000');
});

test('a call killed by a signal settles its reservation too', () => {
  const f = fixture();
  const r = f.run(f.good, { STUB_DIE: '1' });
  assert.equal(r.status, 137);
  assert.equal(f.status().reserved_usd, '0.000000');
});

const alive = (pid) => { try { process.kill(pid, 0); return true; } catch { return false; } };

test('a launcher terminated mid-call stops the call and settles its reservation', async () => {
  const f = fixture();
  const hold = join(f.dir, 'hold'); writeFileSync(hold, '');
  const first = spawn('bash', [LAUNCH, ...f.good], { env: { ...f.env, STUB_HOLD: hold }, stdio: 'ignore' });
  const done = new Promise((resolve) => first.on('close', resolve));
  let stub = 0;
  try {
    const until = Date.now() + 15000;
    const ready = () => existsSync(f.paths.env) && /^resv_pid=\d+$/m.test(readFileSync(f.paths.env, 'utf8'));
    while (!ready() && Date.now() < until) await new Promise((r) => setTimeout(r, 50));
    assert.equal(f.status().reserved_usd, '0.100000');
    stub = Number(/^stub_pid=(\d+)$/m.exec(readFileSync(f.paths.env, 'utf8'))[1]);
    first.kill('SIGTERM');
    // The hold file stays: only the launcher forwarding the signal can end the call.
    await Promise.race([done, new Promise((r) => setTimeout(r, 10000))]);
    assert.equal(alive(stub), false, 'the call outlived its terminated launcher');
    assert.equal(f.status().reserved_usd, '0.000000');
  } finally { rmSync(hold, { force: true }); if (stub && alive(stub)) process.kill(stub, 'SIGKILL'); }
});

test('a call that outruns the call timeout is stopped, even one ignoring TERM, and settles', () => {
  const f = fixture();
  const hold = join(f.dir, 'hold'); writeFileSync(hold, '');
  try {
    const r = f.run(f.good, { STUB_HOLD: hold, STUB_IGNORE_TERM: '1', STUB_CHILD: '1', HIMMEL_API_CALL_TIMEOUT_S: '1' });
    assert.notEqual(r.status, 0);
    assert.equal(f.status().reserved_usd, '0.000000');
    const seen = readFileSync(f.paths.env, 'utf8');
    const stub = Number(/^stub_pid=(\d+)$/m.exec(seen)[1]);
    const child = Number(/^child_pid=(\d+)$/m.exec(seen)[1]);
    try {
      assert.equal(alive(stub), false, 'the call outlived the call timeout');
      assert.equal(alive(child), false, 'a subprocess of the call outlived the call timeout');
    } finally { if (alive(child)) process.kill(child, 'SIGKILL'); }
  } finally { rmSync(hold, { force: true }); }
});

// account C behaves like A and B, billed to its own 200.00 cap
const KEY_C = 'sk-ant-dummy-account-c-key-CCCC';
function withC(f, mode = 0o600) {
  f.config.accounts.C = { organization_id: 'org-c', cycle_id: 'cycle-c', cap_usd: '200.00', key_id: 'key-c', reset_at: '2099-01-01T00:00:00Z' };
  f.snapshot.accounts.C = { ...f.snapshot.accounts.A, organization_id: 'org-c', cycle_id: 'cycle-c', grant_usd: '200.00', remaining_usd: '200.00' };
  f.save();
  const env = keyFiles(f, mode);
  writeFileSync(join(f.dir, 'key-C.env'), `ANTHROPIC_API_KEY=${KEY_C}\n`, { mode });
  chmodSync(join(f.dir, 'key-C.env'), mode);
  return env;
}

test('HIMMEL_API_ACCOUNT=C with a graphify kind runs one stubbed call and bills the ledger row to C', () => {
  const f = fixture();
  const r = launch(withC(f), { HIMMEL_API_ACCOUNT: 'C', HIMMEL_API_KIND: 'graphify' });
  assert.equal(r.status, 0, r.stderr);
  assert.match(readFileSync(f.paths.env, 'utf8'), /^key_tail=CCCC$/m);
  const row = JSON.parse(f.record().trim());
  assert.equal(row.account, 'C');
  assert.equal(row.key_id, 'key-c');
  for (const text of [r.stdout, r.stderr, f.record()]) assert.ok(!text.includes(KEY_C));
});

test('an explicit account C call runs for any kind, like A and B', () => {
  for (const kind of ['judge', 'critic', 'bulk', 'cull', 'smoke']) {
    const f = fixture();
    const r = launch(withC(f), { HIMMEL_API_ACCOUNT: 'C', HIMMEL_API_KIND: kind });
    assert.equal(r.status, 0, `${kind}: ${r.stderr}`);
    assert.equal(JSON.parse(f.record().trim()).account, 'C');
  }
});

test('auto routes every kind of the himmel repo through the default order', () => {
  for (const kind of ['judge', 'critic', 'bulk', 'cull', 'other']) {
    const f = fixture();
    const r = launch(keyFiles(f), { HIMMEL_API_ACCOUNT: 'auto', HIMMEL_API_KIND: kind });
    assert.equal(r.status, 0, `${kind}: ${r.stderr}`);
    assert.equal(f.called(), true);
  }
  const f = fixture();
  const ok = launch(keyFiles(f), { HIMMEL_API_ACCOUNT: 'auto', HIMMEL_API_KIND: 'graphify' });
  assert.equal(ok.status, 0, ok.stderr);
});

test('auto with the graphify kind from another repo is refused before any spawn', () => {
  const f = fixture();
  const r = spawnSync('bash', [LAUNCH, '-p', 'say hi', '--model', 'claude-haiku-5-5', '--permission-mode', 'plan', '--max-budget-usd', '0.10'],
    { env: { ...keyFiles(f), HIMMEL_API_ACCOUNT: 'auto', HIMMEL_API_KIND: 'graphify' }, encoding: 'utf8', cwd: OTHER_REPO });
  assert.equal(r.status, 2, r.stderr);
  assert.match(r.stderr, /auto routing is for the himmel repo only/);
  assert.equal(f.called(), false);
});

test('the graph shim runs the lane from a scratch directory: the repo it judged rides in HIMMEL_API_AUTO_REPO_DIR', () => {
  const commonDir = (cwd) => spawnSync('git', ['-C', cwd, 'rev-parse', '--path-format=absolute', '--git-common-dir'], { encoding: 'utf8' }).stdout.trim();
  const args = ['-p', 'say hi', '--model', 'claude-haiku-5-5', '--permission-mode', 'plan', '--max-budget-usd', '0.10'];
  const shim = (f, repoDir) => spawnSync('bash', [LAUNCH, ...args], { env: { ...keyFiles(f), HIMMEL_API_ACCOUNT: 'auto', HIMMEL_API_KIND: 'graphify',
    ...(repoDir ? { HIMMEL_API_AUTO_REPO_DIR: repoDir } : {}) }, encoding: 'utf8', cwd: mkdtempSync(join(T, 'scratch-')) });
  let f = fixture();
  const noHandoff = shim(f);
  assert.equal(noHandoff.status, 2, noHandoff.stderr);
  assert.equal(f.called(), false);
  f = fixture();
  const own = shim(f, commonDir(HIMMEL_REPO));
  assert.equal(own.status, 0, own.stderr);
  f = fixture();
  const other = shim(f, commonDir(OTHER_REPO));
  assert.equal(other.status, 2, other.stderr);
  assert.match(other.stderr, /auto routing is for the himmel repo only/);
  assert.equal(f.called(), false);
});

test('a decision-525 policy refusal sends no alert, writes no stamp, runs no fallback and leaves one policy record', () => {
  const f = fixture();
  const r = spawnSync('bash', [LAUNCH, '-p', 'say hi', '--model', 'claude-haiku-5-5', '--permission-mode', 'plan', '--max-budget-usd', '0.10'],
    { env: { ...keyFiles(f), ...FB_ON, STUB_FB_OUT: FB_OK, HIMMEL_API_ACCOUNT: 'auto', HIMMEL_API_KIND: 'judge', HIMMEL_API_JOB_ID: 'job-p1',
      HIMMEL_API_BRANCH: 'fix/x', HIMMEL_API_HEAD: 'abc1234' }, encoding: 'utf8', cwd: mkdtempSync(join(T, 'scratch-')) });
  assert.equal(r.status, 2, r.stderr);
  assert.match(r.stderr, /refused: auto routing is for the himmel repo only \(kind judge, repo none\)/);
  const alertDir = f.env.HIMMEL_API_ALERT_DIR;
  assert.deepEqual(alerts(f), []);
  assert.deepEqual(readdirSync(alertDir), ['policy-refusals.jsonl']);
  assert.match(r.stderr, /^claude-api: policy refusal: this call was not sent, and no alert or fallback follows\. Name an account \(A, B, C or D\) instead of auto$/m);
  const lines = readFileSync(join(alertDir, 'policy-refusals.jsonl'), 'utf8').trim().split('\n');
  assert.equal(lines.length, 1);
  const rec = JSON.parse(lines[0]);
  assert.deepEqual(Object.keys(rec).sort(), ['branch', 'head', 'job_id', 'kind', 'repo', 'ts']);
  assert.ok(Number.isInteger(rec.ts) && Math.abs(rec.ts - Date.now() / 1000) < 60, `ts ${rec.ts}`);
  assert.deepEqual({ ...rec, ts: 0 }, { ts: 0, kind: 'judge', repo: 'none', job_id: 'job-p1', branch: 'fix/x', head: 'abc1234' });
  assert.deepEqual(rows(f), []);
  assert.equal(fbCalls(f), 0);
  assert.equal(f.called(), false);
});

test('an eval-kind refusal (not the policy one) still alerts, and a graph-pass call failure still alerts', () => {
  const f = fixture();
  const off = f.run(f.good, { HIMMEL_API_LANE: '', HIMMEL_API_KIND: 'eval' });
  assert.equal(off.status, 2, off.stderr);
  assert.ok(existsSync(join(f.env.HIMMEL_API_ALERT_DIR, 'eval.refused')));
  assert.equal(alerts(f).length, 1);
  assert.doesNotMatch(off.stderr, /policy refusal/);
  const g = fixture();
  const fail = launch(keyFiles(g), { HIMMEL_API_ACCOUNT: 'auto', HIMMEL_API_KIND: 'graphify', STUB_OUT: CALL_FAIL, STUB_RC: '1' });
  assert.notEqual(fail.status, 0, fail.stderr);
  assert.ok(existsSync(join(g.env.HIMMEL_API_ALERT_DIR, 'graphify.call-failed')));
  assert.equal(alerts(g).length, 1);
  assert.doesNotMatch(fail.stderr, /policy refusal/);
});

test('auto ranks account C like A and B', () => {
  const f = fixture();
  const env = withC(f);
  f.snapshot.accounts.C.expires_at = f.now + 60;
  f.save();
  const ok = launch(env, { HIMMEL_API_ACCOUNT: 'auto', HIMMEL_API_KIND: 'graphify', HIMMEL_API_JOB_ID: 'job-c-auto-1' });
  assert.equal(ok.status, 0, ok.stderr);
  assert.equal(JSON.parse(f.record().trim()).account, 'C');
});

test('account C refuses a wrong key id and a key file that is not mode 600', () => {
  const f = fixture();
  const env = withC(f);
  const wrong = launch(env, { HIMMEL_API_ACCOUNT: 'C', HIMMEL_API_KIND: 'graphify', HIMMEL_API_KEY_ID: 'key-a' });
  assert.equal(wrong.status, 2);
  assert.match(wrong.stderr, /key id does not match account C/);
  const g = fixture();
  const loose = launch(withC(g, 0o644), { HIMMEL_API_ACCOUNT: 'C', HIMMEL_API_KIND: 'graphify' });
  assert.equal(loose.status, 2);
  assert.match(loose.stderr, /key file for account C must be mode 600/);
  assert.equal(g.called(), false);
});

const KEY_D_FIFTH_FROM_END_NEVER_PRINTED = 'sk-ant-dummy-account-d-key-0000^Dk4w';
function withD(f, mode = 0o600) {
  f.config.accounts.D = { organization_id: 'org-d', cycle_id: 'cycle-d', cap_usd: '50.00', key_id: 'key-d', reset_at: '2099-01-01T00:00:00Z' };
  f.snapshot.accounts.D = { ...f.snapshot.accounts.A, organization_id: 'org-d', cycle_id: 'cycle-d', grant_usd: '50.00', remaining_usd: '50.00' };
  f.save();
  const env = keyFiles(f, mode);
  writeFileSync(join(f.dir, 'key-D.env'), `ANTHROPIC_API_KEY=${KEY_D_FIFTH_FROM_END_NEVER_PRINTED}\n`, { mode });
  chmodSync(join(f.dir, 'key-D.env'), mode);
  return env;
}
const noKeyLeak = (texts) => {
  for (const text of texts) {
    assert.ok(!text.includes('^'), 'the 5th character from the end of the key leaked');
    assert.ok(!text.includes(KEY_D_FIFTH_FROM_END_NEVER_PRINTED.slice(0, -4)), 'the head of the key leaked');
  }
};

test('HIMMEL_API_ACCOUNT=D runs one stubbed call on key-D.env and bills the ledger row to D', () => {
  const f = fixture();
  const r = launch(withD(f), { HIMMEL_API_ACCOUNT: 'D', HIMMEL_API_KIND: 'judge' });
  assert.equal(r.status, 0, r.stderr);
  assert.match(readFileSync(f.paths.env, 'utf8'), /^key_tail=Dk4w$/m);
  const row = JSON.parse(f.record().trim());
  assert.equal(row.account, 'D');
  assert.equal(row.key_id, 'key-d');
  noKeyLeak([r.stdout, r.stderr, f.record()]);
});

test('auto ranks account D like A, B and C', () => {
  const f = fixture();
  const env = withD(f);
  f.snapshot.accounts.D.expires_at = f.now + 60;
  f.save();
  const ok = launch(env, { HIMMEL_API_ACCOUNT: 'auto', HIMMEL_API_KIND: 'graphify', HIMMEL_API_JOB_ID: 'job-d-auto-1' });
  assert.equal(ok.status, 0, ok.stderr);
  assert.equal(JSON.parse(f.record().trim()).account, 'D');
});

test('a graph role map naming D walks D on auto', () => {
  const f = fixture();
  const env = withD(f);
  writeFileSync(join(f.dir, 'roles.json'), JSON.stringify({ version: 1, roles: { graphify: ['D'] } }));
  const ok = launch(env, { HIMMEL_API_ACCOUNT: 'auto', HIMMEL_API_KIND: 'graphify', HIMMEL_API_JOB_ID: 'job-d-walk-1' });
  assert.equal(ok.status, 0, ok.stderr);
  assert.equal(JSON.parse(f.record().trim()).account, 'D');
});

test('a refusal that names the key shows only its last 4 characters', () => {
  const f = fixture();
  const wrong = launch(withD(f), { HIMMEL_API_ACCOUNT: 'D', HIMMEL_API_KIND: 'graphify', HIMMEL_API_KEY_ID: 'key-a' });
  assert.equal(wrong.status, 2);
  assert.match(wrong.stderr, /key id does not match account D \(key \.\.\.Dk4w\)/);
  noKeyLeak([wrong.stdout, wrong.stderr]);
  assert.equal(f.called(), false);
});

test('a rejected key names the account and the key by its last 4 characters only', () => {
  const f = fixture();
  const bad = JSON.stringify({ type: 'result', is_error: true, result: 'Invalid API key · Fix external API key' });
  const r = launch(withD(f), { HIMMEL_API_ACCOUNT: 'D', HIMMEL_API_JOB_ID: 'job-d-key-1', STUB_OUT: bad, STUB_RC: '1' });
  assert.equal(r.status, 6, r.stderr);
  assert.match(r.stderr, /account D API key rejected \(key \.\.\.Dk4w\)/);
  noKeyLeak([r.stdout, r.stderr, f.record()]);
});

// --- the role map (roles.json beside config.json) widens or narrows auto routing ---
const putRoles = (f, roles) => writeFileSync(join(f.dir, 'roles.json'), typeof roles === 'string' ? roles : JSON.stringify({ version: 1, roles }));
const autoKind = (f, kind, extra = {}) => launch(keyFiles(f), { HIMMEL_API_ACCOUNT: 'auto', HIMMEL_API_KIND: kind, ...extra });
const usedKey = (f) => readFileSync(f.paths.env, 'utf8').match(/^key_tail=(.*)$/m)[1];
const policyLines = (f) => {
  const p = join(f.env.HIMMEL_API_ALERT_DIR, 'policy-refusals.jsonl');
  return existsSync(p) ? readFileSync(p, 'utf8').trim().split('\n') : [];
};
const commonDirOf = (cwd) => spawnSync('git', ['-C', cwd, 'rev-parse', '--path-format=absolute', '--git-common-dir'], { encoding: 'utf8' }).stdout.trim();

test('judge mapped to B picks B; with the map removed the same call uses the default order', () => {
  const f = fixture();
  putRoles(f, { judge: ['B'] });
  const ok = autoKind(f, 'judge');
  assert.equal(ok.status, 0, ok.stderr);
  assert.equal(usedKey(f), 'BBBB');
  assert.equal(JSON.parse(f.record().trim()).account, 'B');
  assert.deepEqual(policyLines(f), []);
  const g = fixture();
  const dflt = autoKind(g, 'judge');
  assert.equal(dflt.status, 0, dflt.stderr);
  assert.deepEqual(policyLines(g), []);
});

test('critic mapped to B picks B; with the map removed the same call uses the default order', () => {
  const f = fixture();
  putRoles(f, { critic: ['B'] });
  const ok = autoKind(f, 'critic');
  assert.equal(ok.status, 0, ok.stderr);
  assert.equal(usedKey(f), 'BBBB');
  assert.equal(JSON.parse(f.record().trim()).account, 'B');
  assert.deepEqual(policyLines(f), []);
  const g = fixture();
  const dflt = autoKind(g, 'critic');
  assert.equal(dflt.status, 0, dflt.stderr);
  assert.deepEqual(policyLines(g), []);
});

test('a critic call under auto from a temp directory with no role entry reaches the account chooser', () => {
  const f = fixture();
  f.snapshot.accounts.A.expires_at += 7200;
  f.save();
  const r = spawnSync('bash', [LAUNCH, '-p', 'say hi', '--model', 'claude-haiku-5-5', '--permission-mode', 'plan', '--max-budget-usd', '0.10'],
    { env: { ...keyFiles(f), HIMMEL_API_ACCOUNT: 'auto', HIMMEL_API_KIND: 'critic', HIMMEL_API_FALLBACK: 'off', HIMMEL_API_AUTO_REPO_DIR: commonDirOf(HIMMEL_REPO) },
      encoding: 'utf8', cwd: mkdtempSync(join(T, 'scratch-')) });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(usedKey(f), 'BBBB');
  assert.deepEqual(policyLines(f), []);
});

test('an unknown kind under auto uses the default account order', () => {
  for (const kind of ['eval', 'other', 'bulk']) {
    const f = fixture();
    f.snapshot.accounts.A.expires_at += 7200;
    f.save();
    const r = autoKind(f, kind);
    assert.equal(r.status, 0, `${kind}: ${r.stderr}`);
    assert.equal(usedKey(f), 'BBBB', kind);
    assert.deepEqual(policyLines(f), []);
  }
});

test('a critic call under auto with a broken role map is still refused and never falls back', () => {
  const f = fixture();
  putRoles(f, '{not json');
  const r = autoKind(f, 'critic', { HIMMEL_API_FALLBACK: 'on' });
  assert.equal(r.status, 2, r.stderr);
  assert.match(r.stderr, /role map broken \(invalid-role-map:not-json\)/);
  assert.doesNotMatch(r.stderr, /running on the subscription/);
  assert.equal(f.called(), false);
});

test('a role mapped to B whose fresh reading has no room runs on B by default, and A is never used', () => {
  const f = fixture();
  putRoles(f, { judge: ['B'] });
  f.snapshot.accounts.B.remaining_usd = '0.05';
  f.save();
  const r = autoKind(f, 'judge');
  assert.equal(r.status, 0, r.stderr);
  assert.equal(usedKey(f), 'BBBB');
});

test('with enforce_budget on, a role mapped to B whose fresh reading has no room is refused, and A is never used', () => {
  const f = fixture();
  putRoles(f, { judge: ['B'] });
  f.snapshot.accounts.B.remaining_usd = '0.05';
  f.config.enforce_budget = true;
  f.save();
  const r = autoKind(f, 'judge');
  assert.notEqual(r.status, 0, r.stderr);
  assert.match(r.stderr, /auto routing: no account has room for the budget/);
  assert.equal(f.called(), false);
  assert.deepEqual(policyLines(f), []);
});

test('a partial map narrows graphify by its live entry and ignores the broken judge entry; money commands still answer', () => {
  const f = fixture();
  f.snapshot.accounts.B.expires_at += 7200;  // without the map A expires first
  f.save();
  putRoles(f, { graphify: ['B'], judge: [] });
  const g = autoKind(f, 'graphify');
  assert.equal(g.status, 0, g.stderr);
  assert.equal(usedKey(f), 'BBBB');
  const j = fixture();
  putRoles(j, { graphify: ['B'], judge: [] });
  const r = autoKind(j, 'judge');
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stderr, /judge entry ignored \(empty-role:judge\)/);
  assert.deepEqual(policyLines(j), []);
});

test('judge:[B,E] routes to B and says the entry was kept as [B]', () => {
  const f = fixture();
  putRoles(f, { judge: ['B', 'E'] });
  const r = autoKind(f, 'judge');
  assert.equal(r.status, 0, r.stderr);
  assert.equal(usedKey(f), 'BBBB');
  assert.match(r.stderr, /judge entry kept as \[B\]/);
});

test('an invalid map: eval and graphify both refuse on the broken map', () => {
  const f = fixture();
  f.snapshot.accounts.B.expires_at += 7200;
  f.save();
  putRoles(f, '{not json');
  const e = autoKind(f, 'eval');
  assert.equal(e.status, 2, e.stderr);
  assert.match(e.stderr, /^claude-api: refused: eval role map broken \(invalid-role-map:not-json\); fix or remove roles\.json$/m);
  assert.equal(f.called(), false);
  const g = autoKind(f, 'graphify');
  assert.equal(g.status, 2, g.stderr);
  assert.match(g.stderr, /^claude-api: refused: graph role map broken \(invalid-role-map:not-json\); fix or remove roles\.json$/m);
  assert.equal(f.called(), false);
});

test('a mapped judge from another repo is refused-policy: the map never widens the repo', () => {
  const f = fixture();
  putRoles(f, { judge: ['B'] });
  const r = autoKind(f, 'judge', { HIMMEL_API_AUTO_REPO_DIR: commonDirOf(OTHER_REPO) });
  assert.equal(r.status, 2, r.stderr);
  assert.match(r.stderr, /auto routing is for the himmel repo only/);
  assert.equal(f.called(), false);
  assert.equal(policyLines(f).length, 1);
});

test('a named account never reads the role map', () => {
  const f = fixture();
  putRoles(f, '{not json');
  const r = launch(keyFiles(f), { HIMMEL_API_ACCOUNT: 'A', HIMMEL_API_KIND: 'judge' });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(usedKey(f), 'AAAA');
  assert.doesNotMatch(r.stderr, /role map/);
});

test('a kind that is not a role (constructor, probe, other) uses the default order although the map is valid', () => {
  for (const kind of ['constructor', 'probe', 'other']) {
    const f = fixture();
    putRoles(f, { judge: ['B'], graphify: ['A'] });
    const r = autoKind(f, kind);
    assert.equal(r.status, 0, `${kind}: ${r.stderr}`);
    assert.equal(f.called(), true);
  }
});

test('with no roles.json an auto graphify call still picks over all accounts and eval uses the default order', () => {
  const f = fixture();
  f.snapshot.accounts.A.expires_at += 7200;  // B expires first
  f.save();
  const g = autoKind(f, 'graphify');
  assert.equal(g.status, 0, g.stderr);
  assert.equal(usedKey(f), 'BBBB');
  assert.doesNotMatch(g.stderr, /role map/);
  const e = autoKind(fixture(), 'eval');
  assert.equal(e.status, 0, e.stderr);
});

function graphAlerts(f) {
  const dedupe = join(f.dir, 'dedupe'), sent = join(f.dir, 'graph-sent.log'), send = join(f.dir, 'graph-send');
  writeFileSync(send, `#!/bin/bash\nprintf '%s\\n' "$1" >> '${sent}'\n`, { mode: 0o700 });
  return {
    env: { CADENCE_ALERT_SEND_CMD: send, CADENCE_ALERT_DEDUPE_DIR: dedupe, CADENCE_ALERT_FILE: join(f.dir, 'cadence-alerts.log'),
      CADENCE_ALERT_SEND_FAILED_MARK: join(f.dir, 'send-failed') },
    sentinels: (l = 'A') => (existsSync(dedupe) ? readdirSync(dedupe).filter((n) => n.startsWith(`graph-key-${l}.`)) : []),
    plant: (l = 'A') => { mkdirSync(dedupe, { recursive: true }); writeFileSync(join(dedupe, `graph-key-${l}.planted`), ''); },
    messages: () => (existsSync(sent) ? readFileSync(sent, 'utf8').trim().split('\n') : []),
  };
}
const INVALID = JSON.stringify({ type: 'result', is_error: true, result: 'Invalid API key · Fix external API key' });
const TOO_LOW = JSON.stringify({ type: 'result', is_error: true, result: 'API Error: 400 Your credit balance is too low to access the Anthropic API.' });
const keyMark = (f, l = 'A') => (existsSync(f.paths.state) ? JSON.parse(readFileSync(f.paths.state, 'utf8')).accounts?.[l]?.key_rejected_at : undefined);

test('K4: a graphify invalid-key answer on A tags A and sends one graph-key-A alert; an accepted call clears the tag and the sentinel', () => {
  const f = fixture();
  const a = graphAlerts(f);
  const env = { ...keyFiles(f), ...a.env, HIMMEL_API_ACCOUNT: 'A', HIMMEL_API_KIND: 'graphify' };
  const r = launch(env, { HIMMEL_API_JOB_ID: 'job-k4-1', STUB_OUT: INVALID, STUB_RC: '1' });
  assert.equal(r.status, 6, r.stderr);
  assert.equal(Number.isInteger(keyMark(f)), true);
  assert.equal(a.messages().length, 1);
  assert.match(a.messages()[0], /^graph-key-A: account A API key rejected\. Cause: the provider answered invalid api key\. Do: rotate ~\/\.himmel\/state\/api-credit\/key-A\.env, or remove A from the route or the graphify role\./);
  assert.ok(!a.messages().join('\n').includes(KEY_A));
  assert.equal(a.sentinels().length, 1);
  const ok = launch(env, { HIMMEL_API_JOB_ID: 'job-k4-2' });
  assert.equal(ok.status, 0, ok.stderr);
  assert.equal(keyMark(f), undefined);
  assert.deepEqual(a.sentinels(), []);
});

test('K4 sub-row: a judge call accepted on A clears the sentinel a graphify rejection raised, so the next rejection sends again', () => {
  const f = fixture();
  const a = graphAlerts(f);
  const env = { ...keyFiles(f), ...a.env, HIMMEL_API_ACCOUNT: 'A' };
  assert.equal(launch(env, { HIMMEL_API_KIND: 'graphify', HIMMEL_API_JOB_ID: 'job-k4s-1', STUB_OUT: INVALID, STUB_RC: '1' }).status, 6);
  assert.equal(a.sentinels().length, 1);
  const judge = launch(env, { HIMMEL_API_KIND: 'judge', HIMMEL_API_JOB_ID: 'job-k4s-2' });
  assert.equal(judge.status, 0, judge.stderr);
  assert.deepEqual(a.sentinels(), []);
  assert.equal(launch(env, { HIMMEL_API_KIND: 'graphify', HIMMEL_API_JOB_ID: 'job-k4s-3', STUB_OUT: INVALID, STUB_RC: '1' }).status, 6);
  assert.equal(a.messages().length, 2);
});

test('K4b: a credit-too-low answer marks exhausted only: no key tag, no graph-key alert, and a planted sentinel survives the next accepted call', () => {
  const f = fixture();
  const a = graphAlerts(f);
  const env = { ...keyFiles(f), ...a.env, HIMMEL_API_ACCOUNT: 'A', HIMMEL_API_KIND: 'graphify' };
  const r = launch(env, { HIMMEL_API_JOB_ID: 'job-k4b-1', STUB_OUT: TOO_LOW, STUB_RC: '1' });
  assert.equal(r.status, 6, r.stderr);
  assert.equal(Number.isInteger(JSON.parse(readFileSync(f.paths.state, 'utf8')).accounts.A.exhausted_at), true);
  assert.equal(keyMark(f), undefined);
  assert.deepEqual(a.messages(), []);
  a.plant();
  assert.equal(launch(env, { HIMMEL_API_JOB_ID: 'job-k4b-2' }).status, 0);
  assert.deepEqual(a.sentinels(), ['graph-key-A.planted']);
});

test('K4c: a judge invalid-key answer tags A and sends no graph-key alert', () => {
  const f = fixture();
  const a = graphAlerts(f);
  const r = launch({ ...keyFiles(f), ...a.env }, { HIMMEL_API_ACCOUNT: 'A', HIMMEL_API_KIND: 'judge', HIMMEL_API_JOB_ID: 'job-k4c-1', STUB_OUT: INVALID, STUB_RC: '1' });
  assert.equal(r.status, 6, r.stderr);
  assert.equal(Number.isInteger(keyMark(f)), true);
  assert.deepEqual(a.messages(), []);
  assert.deepEqual(a.sentinels(), []);
});

test('K5 and K5b: a broken role map refuses an auto graphify call before any spawn, with no policy record, no fallback and no alert; C91 stays OK', () => {
  for (const [map, cause] of [['{not json', 'invalid-role-map:not-json'], [JSON.stringify({ version: 1, roles: { graphify: ['E'] } }), 'empty-role:graphify']]) {
    const f = fixture();
    const a = graphAlerts(f);
    putRoles(f, map);
    const env = { ...keyFiles(f), ...a.env };
    delete env.HIMMEL_API_FALLBACK;
    const r = launch(env, { HIMMEL_API_ACCOUNT: 'auto', HIMMEL_API_KIND: 'graphify' });
    assert.equal(r.status, 2, `${cause}: ${r.stderr}`);
    assert.match(r.stderr, new RegExp(`^claude-api: refused: graph role map broken \\(${cause}\\); fix or remove roles\\.json$`, 'm'));
    assert.equal(f.called(), false);
    assert.equal(existsSync(`${f.paths.log}.fb`), false);
    assert.deepEqual(policyLines(f), []);
    assert.equal(existsSync(f.paths.alertLog), false);
    assert.deepEqual(a.messages(), []);
    const doctor = spawnSync('bash', [join(HIMMEL_REPO, 'scripts', 'himmel-doctor.sh'), '--only', 'C91', '--no-color'],
      { env: { PATH: process.env.PATH, HOME: f.dir, CLAUDE_DIR: join(f.dir, 'claude'), HIMMEL_API_ALERT_DIR: f.env.HIMMEL_API_ALERT_DIR }, encoding: 'utf8' });
    assert.match(doctor.stdout, /OK\s+C91-api-policy-refusals/, doctor.stdout);
  }
  const g = fixture();
  putRoles(g, { graphify: ['B', 'E'] });
  const p = autoKind(g, 'graphify');
  assert.equal(p.status, 0, p.stderr);
  assert.equal(usedKey(g), 'BBBB');
});

const markAt = (f, at) => {
  spawnSync(process.execPath, [STATE, 'exhausted'], { env: f.env, encoding: 'utf8' });
  const ledger = JSON.parse(readFileSync(f.paths.state, 'utf8'));
  ledger.accounts.A.exhausted_at = at;
  writeFileSync(f.paths.state, JSON.stringify(ledger));
};

test('10425: an unknown balance (no snapshot, BANK-UNKNOWN) is not a block: the call runs on the named account', () => {
  const f = fixture();
  rmSync(f.paths.snapshot);
  const r = f.run(f.good, FB_ON);
  assert.equal(r.status, 0, r.stderr);
  assert.doesNotMatch(r.stderr, /refused/);
  assert.equal(f.called(), true);
  assert.match(readFileSync(f.paths.env, 'utf8'), /^key_present=1$/m);
  assert.equal(fbCalls(f), 0);
});

test('10425: a stale balance (BANK-STALE) is not a block: the call runs on the named account', () => {
  const f = fixture();
  Object.assign(f.snapshot.accounts.A, { source: 'automatic-snapshot', observed_at: f.now - 700 });
  f.save();
  const r = f.run(f.good, FB_ON);
  assert.equal(r.status, 0, r.stderr);
  assert.doesNotMatch(r.stderr, /refused/);
  assert.equal(f.called(), true);
  assert.equal(fbCalls(f), 0);
});

test('10425: a locked ledger refuses under its own name, and the alert says ledger-locked, never a bare BANK-UNKNOWN', () => {
  const f = fixture();
  mkdirSync(`${f.paths.state}.lock`);
  const r = f.run(f.good, { ...FB_ON, HIMMEL_API_KIND: 'eval', HIMMEL_API_LOCK_WAIT_MS: '100' });
  assert.equal(f.called(), false, r.stderr);
  assert.equal(fbCalls(f), 1);
  assert.match(r.stderr, /refused: .*ledger-locked/);
  assert.equal(alerts(f).length, 1);
  assert.match(alertText(f), /ledger-locked/);
  assert.doesNotMatch(alertText(f), /api bank gate said BANK-UNKNOWN/);
});

test('10425: a later successful call clears an older exhaustion mark', () => {
  const f = fixture();
  markAt(f, f.now - 4000);
  const r = f.run();
  assert.equal(r.status, 0, r.stderr);
  assert.equal(f.status().exhausted_at, null);
});

test('10425: our own cap never blocks by default; with enforce_budget on it refuses before any call and names it', () => {
  const f = fixture();
  const spent = () => writeFileSync(f.paths.state, JSON.stringify({ version: 1, accounts: { A: { organization_id: 'org-a', cycle_id: 'cycle-a', discrepancy: false,
    jobs: { spent: { status: 'settled', maximum_usd: '0.950000', actual_usd: '0.950000', reserved_at: f.now, timeout_s: 3600 } } } } }));
  spent();
  const free = f.run();
  assert.equal(free.status, 0, free.stderr);
  assert.equal(f.called(), true);
  rmSync(f.paths.log);
  spent();
  f.config.enforce_budget = true;
  f.save();
  const r = f.run(f.good, { HIMMEL_API_JOB_ID: 'job-enforce' });
  assert.equal(r.status, 2, r.stderr);
  assert.equal(f.called(), false);
  assert.match(r.stderr, /refused: .*(over-cap|insufficient-headroom)/);
});

function shadowPreflight(f, body) {
  const root = join(f.dir, 'shadow');
  mkdirSync(join(root, 'scripts', 'lib'), { recursive: true });
  for (const e of readdirSync(HIMMEL_REPO)) if (e !== 'scripts') symlinkSync(join(HIMMEL_REPO, e), join(root, e));
  for (const e of readdirSync(join(HIMMEL_REPO, 'scripts'))) if (e !== 'lib') symlinkSync(join(HIMMEL_REPO, 'scripts', e), join(root, 'scripts', e));
  for (const e of readdirSync(join(HIMMEL_REPO, 'scripts', 'lib'))) if (e !== 'usage-preflight.sh') symlinkSync(join(HIMMEL_REPO, 'scripts', 'lib', e), join(root, 'scripts', 'lib', e));
  writeFileSync(join(root, 'scripts', 'lib', 'usage-preflight.sh'), `#!/bin/bash\n${body}\n`, { mode: 0o700 });
  // a linked .mjs runs as main only when node keeps the link path it was started with
  const env = { ...f.env, NODE_OPTIONS: '--preserve-symlinks-main' };
  return () => spawnSync('bash', [join(root, 'scripts', 'api-lane', 'claude-api.sh'), ...f.good], { env, encoding: 'utf8', cwd: HIMMEL_REPO });
}

test('Uj5606a: a preflight that exits nonzero with no output (seam guard exit 96) refuses, and no claude runs', () => {
  const f = fixture();
  const r = shadowPreflight(f, 'exit 96')();
  assert.equal(r.status, 2, r.stderr);
  assert.equal(f.called(), false, 'the API call must not run');
  assert.match(r.stderr, /^claude-api: refused: api bank gate said BANK-UNKNOWN$/m);
});

test('Uj5606a: a preflight that prints no known verdict refuses; a printed BANK-STALE still proceeds', () => {
  const f = fixture();
  const r = shadowPreflight(f, 'echo MAYBE')();
  assert.equal(r.status, 2, r.stderr);
  assert.equal(f.called(), false, 'the API call must not run');
  assert.match(r.stderr, /^claude-api: refused: api bank gate said BANK-UNKNOWN$/m);
  const g = fixture();
  const ok = shadowPreflight(g, 'echo BANK-STALE')();
  assert.equal(ok.status, 0, ok.stderr);
  assert.equal(g.called(), true);
});
