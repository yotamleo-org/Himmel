// launcher fixtures. Dummy key and a stub claude only: no provider
// call, no real credential. Breaks caught: native-bank coupling, A/B fallback,
// credential/selector mismatch, provider-flag precedence, key leakage to
// non-API children, lost source metadata, settling unverified cost.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
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

const STUB = `#!/bin/bash
echo called >> "$STUB_LOG"
{ echo "key_present=$([ -n "\${ANTHROPIC_API_KEY:-}" ] && echo 1 || echo 0)"
  echo "base_url=\${ANTHROPIC_BASE_URL:-}"; echo "oauth=\${CLAUDE_CODE_OAUTH_TOKEN:-}"
  echo "use_bedrock=\${CLAUDE_CODE_USE_BEDROCK:-}"; echo "auth_token=\${ANTHROPIC_AUTH_TOKEN:-}"
  echo "lq_api=$(env | grep -c '^LQ_API_')"
  echo "key_tail=\${ANTHROPIC_API_KEY: -4}"; echo "lane_on=\${HIMMEL_API_LANE:-}"; echo "scrub=\${CLAUDE_CODE_SUBPROCESS_ENV_SCRUB:-}"; echo "cache_ttl=\${CLAUDE_CODE_PROMPT_CACHE_TTL:-}"
  echo "session_markers=$(env | grep -E '^(CLAUDECODE|AI_AGENT|CLAUDE_PID|CLAUDE_EFFORT|CLAUDE_CODE_[A-Z0-9_]*)=' | grep -vc '^CLAUDE_CODE_\\(SUBPROCESS_ENV_SCRUB\\|PROMPT_CACHE_TTL\\)=')"
  echo "org_keys=$(env | grep -c '^ANTHROPIC_ORG_[AB]_KEY=')"
  echo "stub_pid=$$"; echo "ppid=$PPID"; echo "resv_pid=$(cat "$HIMMEL_FLEET_SLOTS/claude-api:\${HIMMEL_API_JOB_ID:-}/pid" 2>/dev/null)"
  echo "args=$*"; } > "$STUB_ENV"
while [ -n "\${STUB_HOLD:-}" ] && [ -e "$STUB_HOLD" ]; do sleep 0.05; done
printf '%s' "$STUB_OUT"
[ -z "\${STUB_DIE:-}" ] || kill -9 $$
exit "\${STUB_RC:-0}"
`;

// A call carrying Claude Code session markers runs under a parent whose argv[0] is `claude`, as it does
// inside a real session. Without one, bank-preflight's seam guard refuses the fixture's seams
// on a tree that is its own primary checkout, as CI's is.
const SESSION_ARGV0 = 'claude';

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
  const paths = { config: join(dir, 'config.json'), snapshot: join(dir, 'snapshot.json'), state,
    stub: join(dir, 'claude-stub'), log: join(dir, 'stub.log'), env: join(dir, 'stub.env'), ps: join(dir, 'ps') };
  const save = () => {
    writeFileSync(paths.config, JSON.stringify(config));
    writeFileSync(paths.snapshot, JSON.stringify(snapshot));
  };
  save();
  writeFileSync(paths.stub, STUB, { mode: 0o700 });
  writeFileSync(paths.ps, '#!/bin/bash\nexit 0\n', { mode: 0o700 });
  const ok = JSON.stringify({ type: 'result', is_error: false, total_cost_usd: 0.012345, result: 'hi' });
  const env = { PATH: process.env.PATH, HOME: dir, TMPDIR: dir,
    HIMMEL_API_CREDIT_CONFIG: paths.config, HIMMEL_API_CREDIT_SNAPSHOT: paths.snapshot,
    HIMMEL_API_CREDIT_STATE: state, HIMMEL_API_LANE: 'on', HIMMEL_API_ACCOUNT: 'A',
    HIMMEL_API_KEY_ID: 'key-a', ANTHROPIC_API_KEY: DUMMY, HIMMEL_API_CLAUDE_BIN: paths.stub,
    HIMMEL_API_JOB_ID: 'job-1', STUB_LOG: paths.log, STUB_ENV: paths.env, STUB_OUT: ok,
    HIMMEL_FLEET_CAP: '4', HIMMEL_FLEET_SLOTS: join(dir, 'slots'), FLEET_PS_CMD: paths.ps, FLEET_PROC: dir,
    CADENCE_BANK_LEDGER: join(dir, 'bank-ledger'), CADENCE_BANK_SKIP_REFRESH: '1',
    CADENCE_BANK_CACHE: join(dir, 'native-cache.json') };
  writeFileSync(env.CADENCE_BANK_CACHE, JSON.stringify({ five_hour: { utilization: 100 }, seven_day: { utilization: 100 } }));
  const good = ['-p', 'say hi', '--model', 'claude-haiku-5-5', '--permission-mode', 'plan', '--max-budget-usd', '0.10'];
  const run = (args = good, extra = {}) => spawnSync('bash', [LAUNCH, ...args], { env: { ...env, ...extra }, encoding: 'utf8' });
  const status = (account = 'A') => {
    const r = spawnSync(process.execPath, [STATE, 'status'], { env: { ...env, HIMMEL_API_ACCOUNT: account }, encoding: 'utf8' });
    return JSON.parse(r.stdout);
  };
  const called = () => existsSync(paths.log);
  const record = () => readFileSync(join(dir, 'launches.jsonl'), 'utf8');
  return { dir, config, snapshot, paths, save, env, good, run, status, called, record };
}

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

test('HIMMEL-6490: the launch record carries branch, head and PR; absent keys are empty and null', () => {
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

test('HIMMEL-5625: a caller with no HIMMEL_API_TOOLS gets no tools (tool-free default, no --allowedTools, no MCP)', () => {
  const f = fixture();
  assert.equal(f.run().status, 0);
  const seen = readFileSync(f.paths.env, 'utf8');
  assert.doesNotMatch(seen, /allowedTools/);
  assert.match(seen, /--tools  --max-budget-usd/);
  assert.match(seen, /--strict-mcp-config/);
  assert.match(seen, /--permission-mode plan/);
});

test('HIMMEL-5625: an opted-in caller gets exactly the named set; the full set is reachable only by naming it', () => {
  const f = fixture();
  assert.equal(f.run(f.good, { HIMMEL_API_TOOLS: 'Read,Edit,Write,Glob,Grep,Bash' }).status, 0);
  const seen = readFileSync(f.paths.env, 'utf8');
  assert.match(seen, /--allowedTools Read,Edit,Write,Glob,Grep,Bash/);
  assert.match(seen, /--tools Read,Edit,Write,Glob,Grep,Bash/);
  assert.match(seen, /--strict-mcp-config/);
});

test('HIMMEL-5544: HIMMEL_API_TOOLS=<empty> runs the call tool-free (no --allowedTools, empty --tools)', () => {
  const f = fixture();
  const r = f.run(f.good, { HIMMEL_API_TOOLS: '' });
  assert.equal(r.status, 0, r.stderr);
  const seen = readFileSync(f.paths.env, 'utf8');
  assert.doesNotMatch(seen, /allowedTools/);
  assert.match(seen, /--tools  --max-budget-usd/);
  assert.match(seen, /--strict-mcp-config/);
});

test('HIMMEL-5544: HIMMEL_API_TOOLS narrows to a subset of the default grant', () => {
  const f = fixture();
  const r = f.run(f.good, { HIMMEL_API_TOOLS: 'Read,Grep' });
  assert.equal(r.status, 0, r.stderr);
  const seen = readFileSync(f.paths.env, 'utf8');
  assert.match(seen, /--allowedTools Read,Grep /);
  assert.match(seen, /--tools Read,Grep /);
});

test('HIMMEL-5544: HIMMEL_API_TOOLS can never widen the grant: an unknown, wider or blank entry is refused before any launch', () => {
  for (const v of ['Read,WebFetch', 'Bash,Task', 'mcp__x__y', '*', 'Bash(*)', 'Read,*', 'Read,,Grep', ' Read', 'Read,']) {
    const f = fixture();
    const r = f.run(f.good, { HIMMEL_API_TOOLS: v });
    assert.equal(r.status, 2, `${JSON.stringify(v)}: ${r.stderr}`);
    assert.match(r.stderr, /HIMMEL_API_TOOLS/);
    assert.equal(f.called(), false, `${JSON.stringify(v)} must not launch`);
  }
});

test('HIMMEL-5433: a lane call from inside a Claude Code session drops the session markers, so it bills as -p/Agent SDK usage', () => {
  const f = fixture();
  const env = { ...f.env, CLAUDECODE: '1', CLAUDE_CODE_ENTRYPOINT: 'cli', CLAUDE_CODE_SESSION_ID: 's-1',
    CLAUDE_CODE_CHILD_SESSION: '1', CLAUDE_CODE_MESSAGING_TOKEN: 'msg-dummy', CLAUDE_CODE_EFFORT_LEVEL: 'max',
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

test('empty API account refuses even though native is funded, and never spawns claude', () => {
  const f = fixture();
  f.snapshot.accounts.A.remaining_usd = '0';
  f.save();
  writeFileSync(f.env.CADENCE_BANK_CACHE, JSON.stringify({ five_hour: { utilization: 1 }, seven_day: { utilization: 1 } }));
  const r = f.run();
  assert.equal(r.status, 2);
  assert.match(r.stderr, /api bank gate said SKIPPED-BANK/);
  assert.equal(f.called(), false);
});

test('no automatic A/B rotation: empty A refuses and B stays untouched', () => {
  const f = fixture();
  f.snapshot.accounts.A.remaining_usd = '0';
  f.save();
  assert.equal(f.run().status, 2);
  assert.equal(f.called(), false);
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
  assert.match(f.run(f.good, { HIMMEL_API_ACCOUNT: 'C' }).stderr, /must be A or B/);
  assert.match(f.run(f.good, { HIMMEL_API_ACCOUNT: '' }).stderr, /must be A or B/);
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

test('HIMMEL-5093: only allowlisted caller flags pass; an unknown, attached or clustered flag is refused with no spawn or reservation', () => {
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

test('HIMMEL-5093: --effort, in both spellings, and the positional prompt still pass', () => {
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

test('HIMMEL-5097: --model and --permission-mode refuse dash-led values and the mode is an allowlist, in both spellings', () => {
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

test('HIMMEL-5097: the exact argv shape scripts/eval/lane-quality/run.sh sends still passes', () => {
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

test('a budget above the available credit refuses at reservation', () => {
  const f = fixture();
  const r = f.run(['-p', 'x', '--model', 'm', '--permission-mode', 'plan', '--max-budget-usd', '5.00']);
  assert.equal(r.status, 2);
  assert.match(r.stderr, /reservation refused|bank gate/);
  assert.equal(f.called(), false);
});

test('a non-API child is stripped of the key and every lane selector', () => {
  const f = fixture();
  const r = spawnSync('bash', [STRIP, '--', 'env'], { env: { ...f.env, HIMMEL_API_CREDIT_FORMAT: 'bank' }, encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr);
  assert.ok(!r.stdout.includes('ANTHROPIC_API_KEY'));
  assert.ok(!r.stdout.includes(DUMMY));
  assert.ok(!/^HIMMEL_API_/m.test(r.stdout));
  const lq = spawnSync('bash', [STRIP, '--', 'env'], { env: { ...f.env, LQ_API_KEY: DUMMY, LQ_API_ACCOUNT: 'B', LQ_API_KEY_ID: 'k', LQ_API_LANE: 'on' }, encoding: 'utf8' });
  assert.ok(!/^LQ_API_/m.test(lq.stdout), 'LQ_API_* survived strip-env');
  assert.match(r.stdout, /^PATH=/m);
});

test('HIMMEL-5433: measure-credit reads the key from a file, refreshes the snapshot and prints only outcome and cost', () => {
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
  '--permission-mode', 'plan', '--max-budget-usd', '0.10'], { env: { ...env, ...extra }, encoding: 'utf8' });

test('HIMMEL-5433: with no key in the caller env the launcher reads key-<account>.env beside the ledger, child env only', () => {
  const f = fixture();
  const r = launch(keyFiles(f), { HIMMEL_API_ACCOUNT: 'B' });
  assert.equal(r.status, 0, r.stderr);
  assert.match(readFileSync(f.paths.env, 'utf8'), /^key_tail=BBBB$/m);
  assert.equal(JSON.parse(f.record().trim()).key_id, 'key-b');
  for (const text of [r.stdout, r.stderr, f.record()]) assert.ok(!text.includes(KEY_B));
});

test('HIMMEL-5433: a key file readable by others, or none at all, refuses before any reservation or spawn', () => {
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

test('HIMMEL-5433: HIMMEL_API_ACCOUNT=auto spends the earliest-expiring grant first, never past its cap', () => {
  const f = fixture();
  f.snapshot.accounts.A.expires_at += 7200;  // A expires after B
  f.save();
  const env = keyFiles(f);
  const first = launch(env, { HIMMEL_API_ACCOUNT: 'auto', HIMMEL_API_JOB_ID: 'job-auto-1' });
  assert.equal(first.status, 0, first.stderr);
  assert.match(readFileSync(f.paths.env, 'utf8'), /^key_tail=BBBB$/m);
  // B has 0.05 left: a 0.10 budget does not fit, so A takes the next call.
  f.snapshot.accounts.B.remaining_usd = '0.05';
  f.snapshot.accounts.B.reconciled_spent_usd = '0.012345';
  f.save();
  const second = launch(env, { HIMMEL_API_ACCOUNT: 'auto', HIMMEL_API_JOB_ID: 'job-auto-2' });
  assert.equal(second.status, 0, second.stderr);
  assert.match(readFileSync(f.paths.env, 'utf8'), /^key_tail=AAAA$/m);
  assert.deepEqual(f.record().trim().split('\n').map((l) => JSON.parse(l).account), ['B', 'A']);
  // Neither fits: refuse, no spawn.
  f.snapshot.accounts.A.remaining_usd = '0.05';
  f.snapshot.accounts.A.reconciled_spent_usd = '0.012345';
  f.save();
  rmSync(f.paths.log);
  const third = launch(env, { HIMMEL_API_ACCOUNT: 'auto', HIMMEL_API_JOB_ID: 'job-auto-3' });
  assert.equal(third.status, 2);
  assert.match(third.stderr, /no account has room/);
  assert.equal(f.called(), false);
});

test('HIMMEL-5433: auto routing refuses a caller-supplied key, which cannot follow the pick', () => {
  const f = fixture();
  const r = f.run(f.good, { HIMMEL_API_ACCOUNT: 'auto' });
  assert.equal(r.status, 2);
  assert.match(r.stderr, /auto routing reads the per-account key files/);
  assert.equal(f.called(), false);
});

test('HIMMEL-5433: a Console refresh does not count already-billed ledger spend twice', () => {
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

test('HIMMEL-5433: the key reaches claude through the environment only, never through any argv', () => {
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

test('HIMMEL-5433: a refresh while the Console lags a fresh settlement still counts that settlement', () => {
  const f = fixture();
  // 0.09 spent outside the ledger is already billed and reconciled.
  f.snapshot.accounts.A.remaining_usd = '1.91'; f.save();
  assert.equal(f.run().status, 0);  // settles 0.012345 on A, not yet on the Console
  const r = spawnSync(process.execPath, [join(HERE, 'grant-snapshot.mjs'), 'A', '1.91'], { env: f.env, encoding: 'utf8' });
  assert.equal(r.status, 0, r.stdout + r.stderr);
  assert.equal(f.status().spent_est_usd, '0.102345');
});

test('HIMMEL-5433: a refresh holds the ledger lock and refuses while another writer has it', () => {
  const f = fixture();
  mkdirSync(`${f.paths.state}.lock`);
  const r = spawnSync(process.execPath, [join(HERE, 'grant-snapshot.mjs'), 'A', '2.00'], { env: f.env, encoding: 'utf8' });
  assert.equal(r.status, 1);
  assert.match(r.stdout, /ledger-locked-or-unwritable/);
  assert.equal(JSON.parse(readFileSync(f.paths.snapshot, 'utf8')).accounts.A.observed_at, f.snapshot.accounts.A.observed_at);
});

test('HIMMEL-5433: a refresh takes the ledger lock before it reads the snapshot', () => {
  const f = fixture();
  mkdirSync(`${f.paths.state}.lock`);
  writeFileSync(f.paths.snapshot, '{ not json');
  const r = spawnSync(process.execPath, [join(HERE, 'grant-snapshot.mjs'), 'A', '2.00'], { env: f.env, encoding: 'utf8' });
  assert.match(r.stdout, /ledger-locked-or-unwritable/);
});

test('HIMMEL-5519: the child never sees the Admin API org keys', () => {
  const f = fixture();
  const r = f.run(f.good, { ANTHROPIC_ORG_A_KEY: 'admin-a-fixture', ANTHROPIC_ORG_B_KEY: 'admin-b-fixture' });
  assert.equal(r.status, 0, r.stderr);
  assert.match(readFileSync(f.paths.env, 'utf8'), /^org_keys=0$/m);
});

test('HIMMEL-5519: the reservation lives exactly as long as the call, so the api cap bounds real concurrency', async () => {
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
    // A second launch, even one carrying an inherited non-api leg name, hits the api cap.
    second = spawnSync('bash', [LAUNCH, ...f.good], { env: { ...env, HIMMEL_API_JOB_ID: 'job-2', CADENCE_BANK_LEG: 'inherited-leg' }, encoding: 'utf8', timeout: 30000 });
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

test('HIMMEL-5433: a grant date that does not exist on the calendar is refused, not rolled over', () => {
  const f = fixture();
  const r = spawnSync(process.execPath, [join(HERE, 'grant-snapshot.mjs'), 'A', '2.00', '2.00', '2026-01-01', '2026-02-30'],
    { env: f.env, encoding: 'utf8' });
  assert.equal(r.status, 1);
  assert.match(r.stdout, /invalid-date/);
});

const USAGE_OUT = JSON.stringify({ type: 'result', is_error: false, total_cost_usd: 0.004, result: 'ok',
  usage: { input_tokens: 12, cache_creation_input_tokens: 3000, cache_read_input_tokens: 9000 } });

test('HIMMEL-5570: the launcher moves per-machine prompt sections out of the cached system prompt', () => {
  const f = fixture();
  assert.equal(f.run().status, 0);
  assert.match(readFileSync(f.paths.env, 'utf8'), /--exclude-dynamic-system-prompt-sections/);
});

test('HIMMEL-5570: the main-conversation cache TTL is 5m by default, 1h on request, and a caller CLAUDE_CODE_PROMPT_CACHE_TTL never wins', () => {
  const f = fixture();
  // A CLAUDE_CODE_* variable is a session marker, so the call runs under a `claude` argv0 as a real session does.
  const first = spawnSync('bash', [LAUNCH, ...f.good], { env: { ...f.env, CLAUDE_CODE_PROMPT_CACHE_TTL: '1h' }, encoding: 'utf8', argv0: SESSION_ARGV0 });
  assert.equal(first.status, 0, first.stderr);
  assert.match(readFileSync(f.paths.env, 'utf8'), /^cache_ttl=5m$/m);
  assert.equal(f.run(f.good, { HIMMEL_API_CACHE_TTL: '1h', HIMMEL_API_JOB_ID: 'job-2' }).status, 0);
  assert.match(readFileSync(f.paths.env, 'utf8'), /^cache_ttl=1h$/m);
});

test('HIMMEL-5570: a cache TTL or run kind outside the allowlist refuses before any spawn', () => {
  const f = fixture();
  for (const bad of [{ HIMMEL_API_CACHE_TTL: '2h' }, { HIMMEL_API_KIND: 'a b' }, { HIMMEL_API_KIND: '"x' }]) {
    const r = f.run(f.good, bad);
    assert.equal(r.status, 2, JSON.stringify(bad));
    assert.match(r.stderr, /refused/);
  }
  assert.equal(f.called(), false);
});

test('HIMMEL-5570: the launch record carries kind, TTL and the usage split so a hit rate can be read back', () => {
  const f = fixture();
  assert.equal(f.run(f.good, { STUB_OUT: USAGE_OUT, HIMMEL_API_KIND: 'eval', HIMMEL_API_CACHE_TTL: '1h' }).status, 0);
  const row = JSON.parse(f.record().trim().split('\n').pop());
  assert.equal(row.kind, 'eval');
  assert.equal(row.cache_ttl, '1h');
  assert.equal(row.input_tokens, 12);
  assert.equal(row.cache_creation_tokens, 3000);
  assert.equal(row.cache_read_tokens, 9000);
});

test('HIMMEL-5570: a result without a usage object records null token counts, never zeros', () => {
  const f = fixture();
  assert.equal(f.run().status, 0);
  const row = JSON.parse(f.record().trim().split('\n').pop());
  assert.equal(row.kind, 'other');
  assert.equal(row.cache_read_tokens, null);
});

const REPORT = join(HERE, 'cache-report.mjs');
const usageRow = (ts, kind, ttl, i, c, r, model = 'm', org = 'o') => JSON.stringify({ ts, kind, model, organization_id: org, cache_ttl: ttl, input_tokens: i, cache_creation_tokens: c, cache_read_tokens: r });

test('HIMMEL-5570: cache-report prints a per-kind hit rate and picks the TTL from the measured gaps', () => {
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

// a dead call must not hold its reservation (killed calls on account B kept 20.10 USD reserved).
test('HIMMEL-7111: a call that exits non-zero settles its reservation instead of leaving it open', () => {
  const f = fixture();
  const r = f.run(f.good, { STUB_RC: '3', STUB_OUT: 'boom' });
  assert.equal(r.status, 3);
  assert.equal(f.status().reserved_usd, '0.000000');
  const rec = JSON.parse(f.record().trim());
  assert.equal(rec.outcome, 'failed');
  assert.equal(rec.cost_usd, '0.000000');
});

test('HIMMEL-7111: a call killed by a signal settles its reservation too', () => {
  const f = fixture();
  const r = f.run(f.good, { STUB_DIE: '1' });
  assert.equal(r.status, 137);
  assert.equal(f.status().reserved_usd, '0.000000');
});

const alive = (pid) => { try { process.kill(pid, 0); return true; } catch { return false; } };

test('HIMMEL-7111: a launcher terminated mid-call stops the call and settles its reservation', async () => {
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

test('HIMMEL-7111: a call that outruns the call timeout is stopped and settles, so the sweep never releases a live reservation', () => {
  const f = fixture();
  const hold = join(f.dir, 'hold'); writeFileSync(hold, '');
  try {
    const r = f.run(f.good, { STUB_HOLD: hold, HIMMEL_API_CALL_TIMEOUT_S: '1' });
    assert.notEqual(r.status, 0);
    assert.equal(f.status().reserved_usd, '0.000000');
    const stub = Number(/^stub_pid=(\d+)$/m.exec(readFileSync(f.paths.env, 'utf8'))[1]);
    assert.equal(alive(stub), false, 'the call outlived the call timeout');
  } finally { rmSync(hold, { force: true }); }
});
