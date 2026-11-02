// launcher fixtures. Dummy key and a stub claude only: no provider
// call, no real credential. Breaks caught: native-bank coupling, A/B fallback,
// credential/selector mismatch, provider-flag precedence, key leakage to
// non-API children, lost source metadata, settling unverified cost.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, utimesSync, writeFileSync } from 'node:fs';
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
  echo "session_markers=$(env | grep -E '^(CLAUDECODE|AI_AGENT|CLAUDE_PID|CLAUDE_EFFORT|CLAUDE_JOB_DIR|CLAUDE_CODE_[A-Z0-9_]*)=' | grep -vc '^CLAUDE_CODE_\\(SUBPROCESS_ENV_SCRUB\\|PROMPT_CACHE_TTL\\)=')"
  echo "org_keys=$(env | grep -c '^ANTHROPIC_ORG_[AB]_KEY=')"
  echo "stub_pid=$$"; echo "ppid=$PPID"; echo "resv_pid=$(cat "$HIMMEL_FLEET_SLOTS/claude-api:\${HIMMEL_API_JOB_ID:-}/pid" 2>/dev/null)"
  echo "args=$*"; } > "$STUB_ENV$FB"
if [ -n "$FB" ]; then printf '%s' "\${STUB_FB_OUT:-$STUB_OUT}"; exit "\${STUB_FB_RC:-0}"; fi
[ -z "\${STUB_IGNORE_TERM:-}" ] || trap '' TERM
[ -z "\${STUB_CHILD:-}" ] || { sleep 300 & echo "child_pid=$!" >> "$STUB_ENV"; }
while [ -n "\${STUB_HOLD:-}" ] && [ -e "$STUB_HOLD" ]; do sleep 0.05; done
printf '%s' "$STUB_OUT"
[ -z "\${STUB_DIE:-}" ] || kill -9 $$
[ -z "\${STUB_TERM:-}" ] || { ( sleep 0.05; kill -TERM "$PPID" ) </dev/null >/dev/null 2>&1 & kill -TERM $$; }
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
    HIMMEL_FLEET_CAP: '4', HIMMEL_FLEET_SLOTS: join(dir, 'slots'), FLEET_PS_CMD: paths.ps, FLEET_PROC: dir,
    CADENCE_USAGE_LEDGER: join(dir, 'bank-ledger'), CADENCE_USAGE_SKIP_REFRESH: '1',
    CADENCE_USAGE_CACHE: join(dir, 'native-cache.json'),
    HIMMEL_API_FALLBACK: 'off', HIMMEL_API_ALERT_CMD: paths.alert, HIMMEL_API_ALERT_DIR: join(dir, 'alerts') };
  writeFileSync(env.CADENCE_USAGE_CACHE, JSON.stringify({ five_hour: { utilization: 100 }, seven_day: { utilization: 100 } }));
  const good = ['-p', 'say hi', '--model', 'claude-haiku-5-5', '--permission-mode', 'plan', '--max-budget-usd', '0.10'];
  const run = (args = good, extra = {}, opts = {}) => spawnSync('bash', [LAUNCH, ...args], { env: { ...env, ...extra }, encoding: 'utf8', ...opts });
  const status = (account = 'A') => {
    const r = spawnSync(process.execPath, [STATE, 'status'], { env: { ...env, HIMMEL_API_ACCOUNT: account }, encoding: 'utf8' });
    return JSON.parse(r.stdout);
  };
  const called = () => existsSync(paths.log);
  const record = () => readFileSync(join(dir, 'launches.jsonl'), 'utf8');
  return { dir, now, config, snapshot, paths, save, env, good, run, status, called, record };
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

test('a refused call (lane off) sends one alert and re-runs the prompt once on the subscription, native auth, no key', () => {
  const f = fixture();
  const r = f.run(f.good, { ...FB_ON, HIMMEL_API_LANE: '', STUB_FB_OUT: FB_OK, CLAUDE_CODE_OAUTH_TOKEN: 'oauth-dummy',
    ANTHROPIC_BASE_URL: 'https://evil.example', ANTHROPIC_ORG_A_KEY: DUMMY, LQ_API_KEY: DUMMY, CLAUDECODE: '1' },
  { argv0: SESSION_ARGV0 }); // a marker needs a `claude` ancestor, or the subscription preflight's seam guard refuses on CI's primary checkout
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stderr, /api lane is OFF/);
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
  assert.match(alertText(f), /api lane is OFF/);
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
    assert.equal(h.run(h.good, { ...FB_ON, HIMMEL_API_TOOLS: tools, HIMMEL_API_LANE: '', STUB_FB_OUT: FB_OK }).status, 0, tools);
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
  const r = f.run(f.good, { ...FB_ON, HIMMEL_API_LANE: '' });
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
  assert.equal(h.run(h.good, { ...FB_ON, HIMMEL_API_LANE: '', STUB_FB_OUT: FB_OK }).status, 0);
  assert.equal(fbCalls(h), 1, 'PROCEED runs the fallback');
});

test('one alert per kind and class per hour; a new class or an hour later alerts again', () => {
  const f = fixture();
  for (let i = 0; i < 2; i++) assert.equal(f.run(f.good, { ...FB_ON, HIMMEL_API_LANE: '' }).status, 0);
  assert.equal(alerts(f).length, 1, 'the second refusal within the hour alerted again');
  assert.equal(fbCalls(f), 2, 'the rate limit holds the alert, never the fallback');
  assert.equal(f.run(f.good, { ...FB_ON, STUB_OUT: CREDIT_LOW, STUB_RC: '1' }).status, 0);
  assert.equal(alerts(f).length, 2);
  const old = (Date.now() - 2 * 3600 * 1000) / 1000;
  for (const s of readdirSync(join(f.dir, 'alerts'))) utimesSync(join(f.dir, 'alerts', s), old, old);
  assert.equal(f.run(f.good, { ...FB_ON, HIMMEL_API_LANE: '' }).status, 0);
  assert.equal(alerts(f).length, 3);
});

test('a failed alert send writes no stamp, so the next failure inside the hour alerts again', () => {
  const f = fixture();
  assert.equal(f.run(f.good, { ...FB_ON, HIMMEL_API_LANE: '', ALERT_RC: '1' }).status, 0);
  assert.equal(f.run(f.good, { ...FB_ON, HIMMEL_API_LANE: '' }).status, 0);
  assert.equal(alerts(f).length, 2, 'a failed send muted the next alert');
});

test('HIMMEL_API_FALLBACK=off still alerts but runs no fallback; a malformed request never falls back', () => {
  const f = fixture();
  const r = f.run(f.good, { HIMMEL_API_LANE: '' });
  assert.equal(r.status, 2);
  assert.equal(fbCalls(f), 0);
  assert.equal(alerts(f).length, 1);
  assert.match(alertText(f), /fallback: off/);
  const g = fixture();
  assert.equal(g.run([...g.good, '--bogus'], FB_ON).status, 2);
  assert.equal(fbCalls(g), 0);
  assert.equal(alerts(g).length, 1);
  // the lane-off refusal comes first, yet a malformed request still never reaches the subscription
  const noPrint = ['--model', 'claude-haiku-5-5', '--permission-mode', 'plan', '--max-budget-usd', '0.10', 'hi'];
  for (const [args, env] of [[noPrint, {}], [null, { HIMMEL_API_KIND: 'bad kind' }], [null, { HIMMEL_API_CACHE_TTL: '9h' }],
    [null, { HIMMEL_API_JOB_ID: 'bad id' }], [null, { HIMMEL_API_TOOLS: 'Bash(*)' }]]) {
    const m = fixture();
    assert.equal(m.run(args ?? m.good, { ...FB_ON, HIMMEL_API_LANE: '', ...env }).status, 2);
    assert.equal(fbCalls(m), 0, JSON.stringify(env));
    assert.match(alertText(m), /fallback: not run: the request itself was refused/);
  }
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

test('HIMMEL-8649: a stdin prompt whose API call failed is replayed byte for byte on the subscription fallback', () => {
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

test('HIMMEL-8649: the scratch prompt file is gone after success, a refusal before and after the buffer, and an ordinary failure', () => {
  const ok = fixture();
  const a = ok.run(STDIN_ONLY, withStdin(ok), { input: PROMPT });
  assert.equal(a.status, 0, a.stderr);
  assert.equal(seenStdin(ok), PROMPT);
  assert.deepEqual(seenModes(ok), ['600']);
  assert.deepEqual(promptFiles(ok), [], 'left behind after success');
  assert.equal(fbCalls(ok), 0);

  // lane off: refused before stdin is read, the fallback still gets the unread prompt
  const early = fixture();
  const b = early.run(STDIN_ONLY, { ...withStdin(early), HIMMEL_API_LANE: '', STUB_FB_OUT: FB_OK }, { input: PROMPT });
  assert.equal(b.status, 0, b.stderr);
  assert.equal(early.called(), false, 'the API call must not run');
  assert.equal(seenStdin(early, '.fb'), PROMPT);
  assert.deepEqual(promptFiles(early), []);

  // a budget the account cannot cover: refused at the reservation, after the prompt was buffered
  const late = fixture();
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

test('HIMMEL-8649: a stdin prompt on a Bash-granted call that ran is still never replayed; a prompt in argv is untouched', () => {
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

test('HIMMEL-8649: the scratch prompt file is gone after the launcher is terminated mid-call', async () => {
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

test('empty API account refuses even though native is funded, and never spawns claude', () => {
  const f = fixture();
  f.snapshot.accounts.A.remaining_usd = '0';
  f.save();
  writeFileSync(f.env.CADENCE_USAGE_CACHE, JSON.stringify({ five_hour: { utilization: 1 }, seven_day: { utilization: 1 } }));
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

test('HIMMEL-7264: auto routing launches on a snapshot older than 24 h and warns', () => {
  const f = fixture();
  for (const a of ['A', 'B']) { f.snapshot.accounts[a].starts_at = f.now - 400000; f.snapshot.accounts[a].observed_at = f.now - 90000; }
  f.save();
  const r = launch(keyFiles(f), { HIMMEL_API_ACCOUNT: 'auto', HIMMEL_API_JOB_ID: 'job-stale-1' });
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stderr, /WARN.*credit reading/);
  assert.equal(f.called(), true);
});

test('HIMMEL-7264: auto routing launches with no snapshot file at all, inside the caps', () => {
  const f = fixture();
  rmSync(f.paths.snapshot);
  const r = launch(keyFiles(f), { HIMMEL_API_ACCOUNT: 'auto', HIMMEL_API_JOB_ID: 'job-nosnap-1' });
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

test('HIMMEL-7264: auto routing goes on past the bank gate when the old reading and the ledger leave no room', () => {
  const f = fixture();
  for (const a of ['A', 'B']) { f.snapshot.accounts[a].starts_at = f.now - 400000; f.snapshot.accounts[a].observed_at = f.now - 90000; }
  f.save();
  ledgerAtCap(f);
  const r = launch(keyFiles(f), { HIMMEL_API_ACCOUNT: 'auto', HIMMEL_API_JOB_ID: 'job-over-1' });
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stderr, /spend estimate has no room/);
  assert.equal(f.called(), true);
});

test('HIMMEL-7264: a caller-set optional flag does not let an explicit account launch without a credit reading', () => {
  const f = fixture();
  rmSync(f.paths.snapshot);
  const r = f.run(f.good, { HIMMEL_API_SNAPSHOT_OPTIONAL: '1' });
  assert.equal(r.status, 2);
  assert.match(r.stderr, /api bank gate said/);
  assert.equal(f.called(), false);
});

test('HIMMEL-7264: a credit-exhausted result marks the account and the next auto call rotates to the other', () => {
  const f = fixture();
  const env = keyFiles(f);
  const dead = JSON.stringify({ type: 'result', is_error: true, result: 'API Error: 400 Your credit balance is too low to access the Anthropic API.' });
  const first = launch(env, { HIMMEL_API_ACCOUNT: 'auto', HIMMEL_API_JOB_ID: 'job-dry-1', STUB_OUT: dead, STUB_RC: '1' });
  assert.equal(first.status, 6);
  assert.match(readFileSync(f.paths.env, 'utf8'), /^key_tail=AAAA$/m);
  assert.match(first.stderr, /credit exhausted/);
  assert.equal(Number.isInteger(JSON.parse(readFileSync(f.paths.state, 'utf8')).accounts.A.exhausted_at), true);
  const second = launch(env, { HIMMEL_API_ACCOUNT: 'auto', HIMMEL_API_JOB_ID: 'job-dry-2' });
  assert.equal(second.status, 0, second.stderr);
  assert.match(readFileSync(f.paths.env, 'utf8'), /^key_tail=BBBB$/m);
});

test('HIMMEL-7161: a credit-too-low result exits 6, the non-retryable code, and the launch record names it exhausted', () => {
  const f = fixture();
  const dead = JSON.stringify({ type: 'result', is_error: true, result: 'API Error: 400 Your credit balance is too low to access the Anthropic API.' });
  const r = launch(keyFiles(f), { HIMMEL_API_ACCOUNT: 'B', HIMMEL_API_JOB_ID: 'job-dry-3', STUB_OUT: dead, STUB_RC: '1' });
  assert.equal(r.status, 6, r.stderr);
  assert.equal(JSON.parse(f.record().trim().split('\n').pop()).outcome, 'exhausted');
  assert.equal(Number.isInteger(JSON.parse(readFileSync(f.paths.state, 'utf8')).accounts.B.exhausted_at), true);
});

test('HIMMEL-7161: an invalid-key result flags the account, exits 6 and the next auto pick skips it', () => {
  const f = fixture();
  const env = keyFiles(f);
  const bad = JSON.stringify({ type: 'result', is_error: true, result: 'Invalid API key · Fix external API key' });
  const first = launch(env, { HIMMEL_API_ACCOUNT: 'auto', HIMMEL_API_JOB_ID: 'job-key-1', STUB_OUT: bad, STUB_RC: '1' });
  assert.equal(first.status, 6, first.stderr);
  assert.match(readFileSync(f.paths.env, 'utf8'), /^key_tail=AAAA$/m);
  assert.match(first.stderr, /API key rejected/);
  assert.equal(JSON.parse(f.record().trim().split('\n').pop()).outcome, 'key_invalid');
  assert.equal(Number.isInteger(JSON.parse(readFileSync(f.paths.state, 'utf8')).accounts.A.exhausted_at), true);
  const second = launch(env, { HIMMEL_API_ACCOUNT: 'auto', HIMMEL_API_JOB_ID: 'job-key-2' });
  assert.equal(second.status, 0, second.stderr);
  assert.match(readFileSync(f.paths.env, 'utf8'), /^key_tail=BBBB$/m);
});

test('HIMMEL-7161: a plain failure that is neither rejection keeps the call exit code', () => {
  const f = fixture();
  const r = launch(keyFiles(f), { HIMMEL_API_ACCOUNT: 'B', HIMMEL_API_JOB_ID: 'job-plain-1', STUB_OUT: JSON.stringify({ type: 'result', is_error: true, result: 'boom' }), STUB_RC: '1' });
  assert.equal(r.status, 1, r.stderr);
  assert.equal(JSON.parse(f.record().trim().split('\n').pop()).outcome, 'failed');
});

test('HIMMEL-7161: a failed call whose permission denials quote the phrase, but whose result does not, is not a rejection', () => {
  const f = fixture();
  const quoted = JSON.stringify({ type: 'result', is_error: true, result: 'boom', permission_denials: [{ tool_name: 'Bash', tool_input: { command: 'echo invalid api key; echo credit balance is too low' } }] });
  const r = launch(keyFiles(f), { HIMMEL_API_ACCOUNT: 'B', HIMMEL_API_JOB_ID: 'job-quote-1', STUB_OUT: quoted, STUB_RC: '1' });
  assert.equal(r.status, 1, r.stderr);
  assert.equal(JSON.parse(f.record().trim().split('\n').pop()).outcome, 'failed');
  assert.equal(existsSync(f.paths.state) && JSON.parse(readFileSync(f.paths.state, 'utf8')).accounts?.B?.exhausted_at !== undefined, false);
});

test('HIMMEL-7161: a successful call whose result text mentions an invalid API key is not a rejection', () => {
  const f = fixture();
  const ok = JSON.stringify({ type: 'result', is_error: false, result: 'The message was: Invalid API key', total_cost_usd: 0.01 });
  const r = launch(keyFiles(f), { HIMMEL_API_ACCOUNT: 'B', HIMMEL_API_JOB_ID: 'job-quote-2', STUB_OUT: ok, STUB_RC: '0' });
  assert.equal(r.status, 0, r.stderr);
  assert.notEqual(JSON.parse(f.record().trim().split('\n').pop()).outcome, 'key_invalid');
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

test('HIMMEL-7111: a call that outruns the call timeout is stopped, even one ignoring TERM, and settles', () => {
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
