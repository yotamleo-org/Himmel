// readiness-tools.test.mjs -- C0s cycle 1: the host-private credential channel and the minimal real
// Jira port (readIssue / addReadinessLabel / readback) of readiness-tools.mjs.
//
// Everything here is fixture-only: a scratch HOME, FAKE credentials, and a loopback issue service
// the REAL built primary Jira CLI is pointed at. No real Jira, provider, user config or secret
// file is read, and the fake token is a sentinel the assertions hunt for in every model-facing
// channel (results, errors, argv, enumerable port state).
//
// Run: node --test --test-name-pattern 'C0 credentials and port' scripts/handover/chief-kit/readiness-tools.test.mjs
import { describe, test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import {
  chmodSync, existsSync, linkSync, mkdirSync, mkdtempSync, realpathSync, renameSync, rmSync,
  statSync, symlinkSync, writeFileSync, appendFileSync, copyFileSync, readFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, relative } from 'node:path';
import { execFile, execFileSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { inspect } from 'node:util';

const HERE = dirname(fileURLToPath(import.meta.url));
const load = () => import(pathToFileURL(join(HERE, 'readiness-tools.mjs')).href);

// The real built primary CLI (dist/ is untracked, so a worktree has none of its own). Absent => the
// tests fail loudly: there is no stand-in CLI, because a stand-in would not test the real port.
const primaryCheckout = () => {
  const env = { ...process.env };
  for (const k of ['GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE']) delete env[k];
  const common = execFileSync('git', ['-C', HERE, 'rev-parse', '--path-format=absolute', '--git-common-dir'], { encoding: 'utf8', env }).trim();
  return dirname(common);
};
const ORIGINAL_CLI = process.env.READINESS_PRIMARY_CLI || join(primaryCheckout(), 'scripts', 'jira', 'dist', 'index.js');
let PRIMARY_CLI;

const TOKEN = 'fake-c0s-token-7f3a91c2d4e85b60';
const EMAIL = 'c0s-fake-user@example.invalid';
const PROJECT = 'HIMMEL';
const LABEL = 'needs-readiness';
const forms = (s) => [
  s, Buffer.from(s).toString('base64'), Buffer.from(s).toString('base64url'),
  encodeURIComponent(s), Buffer.from(s).toString('hex'),
];
const credForms = () => [
  ...forms(TOKEN), ...forms(EMAIL), ...forms(`${EMAIL}:${TOKEN}`),
  Buffer.from(`${EMAIL}:${TOKEN}`).toString('base64').replace(/=+$/, ''),
];
const leaks = (value) => {
  const text = typeof value === 'string' ? value : JSON.stringify(value);
  return credForms().filter((f) => f.length > 6 && text.includes(f));
};

// ---- loopback issue service (the oracle) ---------------------------------------------------------
class JiraFixture {
  constructor() {
    this.labels = ['a'];
    this.mode = 'ok';
    this.requests = [];
    this.reflected = false;
    this.expectedAuth = `Basic ${Buffer.from(`${EMAIL}:${TOKEN}`).toString('base64')}`;
    this.server = http.createServer((req, res) => this.#handle(req, res));
    this.held = new Set();
  }

  async listen() {
    await new Promise((ok) => this.server.listen(0, '127.0.0.1', ok));
    this.baseUrl = `http://127.0.0.1:${this.server.address().port}`;
  }

  async close() {
    for (const res of this.held) res.destroy();
    await new Promise((ok) => this.server.close(ok));
  }

  #issue() {
    return { key: 'HIMMEL-1', fields: { summary: this.summary ?? 'a fixture ticket', status: { name: 'Open' }, issuetype: { name: 'Task' }, labels: [...this.labels], description: null, ...this.extraFields } };
  }

  #handle(req, res) {
    let body = '';
    req.on('data', (d) => { body += d; });
    req.on('end', () => {
      const authOk = req.headers.authorization === this.expectedAuth;
      this.requests.push({ method: req.method, url: req.url, authOk });
      const json = (code, obj) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(obj)); };
      if (!authOk) return json(401, { errorMessages: ['unauthorized'] });
      if (this.mode === 'reflect') {
        this.reflected = true;
        // A hostile or buggy service that echoes the request's credentials back in its error body.
        return json(500, { errorMessages: [`echo ${req.headers.authorization} user=${EMAIL} token=${TOKEN} tokenb64=${Buffer.from(TOKEN).toString('base64')} tokenurl=${encodeURIComponent(TOKEN)}`] });
      }
      if (!req.url.startsWith('/rest/api/3/issue/HIMMEL-1')) return json(404, { errorMessages: ['not found'] });
      if (req.method === 'PUT') {
        const apply = () => {
          for (const u of JSON.parse(body).update?.labels ?? []) {
            if (u.add && !this.labels.includes(u.add)) this.labels.push(u.add);
            if (u.remove) this.labels = this.labels.filter((l) => l !== u.remove);
          }
        };
        if (this.mode === 'put-500-no-apply') return json(500, { errorMessages: ['refused'] });
        apply();
        if (this.mode === 'hold-put') { this.held.add(res); return undefined; } // applied, answer never sent
        if (this.mode === 'put-500-after-apply') return json(500, { errorMessages: ['late failure'] });
        res.writeHead(204); return res.end();
      }
      return json(200, this.#issue());
    });
  }
}

// ---- scratch layout -------------------------------------------------------------------------------
const roots = [];
function scratch() {
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'c0s-port-')));
  roots.push(root);
  const attempt = join(root, 'attempt');
  mkdirSync(attempt, { mode: 0o700 });
  chmodSync(attempt, 0o700);
  return { root, attempt, cred: join(attempt, 'jira-credentials.json') };
}
function writeCred(path, obj, mode = 0o600) {
  writeFileSync(path, typeof obj === 'string' ? obj : JSON.stringify(obj), { mode });
  chmodSync(path, mode);
}
const goodCreds = (baseUrl) => ({ base_url: baseUrl, project: PROJECT, email: EMAIL, api_token: TOKEN });
after(() => { for (const r of roots) rmSync(r, { recursive: true, force: true }); });

// Byte-copy the actual compiled CLI and its relative module closure into an owned repo, so its
// ordinary (non-test) startup can read only fixture config. Package links contain code, not config.
const cliHome = scratch();
const realRepo = primaryCheckout();
const cliRepo = join(cliHome.root, 'cli-repo');
mkdirSync(cliRepo);
writeFileSync(join(cliRepo, 'package.json'), '{"type":"module"}\n');
execFileSync('git', ['init', '-q', cliRepo], { env: { PATH: process.env.PATH, HOME: cliHome.root, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_SYSTEM: '/dev/null' } });
const copied = new Set();
function copyModule(source) {
  if (copied.has(source)) return;
  copied.add(source);
  const rel = relative(realRepo, source);
  assert.ok(!rel.startsWith('..'), `CLI dependency escaped its repository: ${rel}`);
  const target = join(cliRepo, rel);
  mkdirSync(dirname(target), { recursive: true });
  copyFileSync(source, target);
  if (!/\.[cm]?js$/.test(source)) return;
  const text = readFileSync(source, 'utf8');
  for (const match of text.matchAll(/(?:from\s*|import\s*\(?\s*)['"](\.{1,2}\/[^'"]+)['"]/g)) {
    copyModule(fileURLToPath(new URL(match[1], pathToFileURL(source))));
  }
}
copyModule(ORIGINAL_CLI);
PRIMARY_CLI = join(cliRepo, relative(realRepo, ORIGINAL_CLI));
for (const rel of ['node_modules', 'scripts/jira/node_modules']) {
  if (!existsSync(join(realRepo, rel))) continue;
  const target = join(cliRepo, rel);
  mkdirSync(dirname(target), { recursive: true });
  symlinkSync(join(realRepo, rel), target, 'dir');
}
writeFileSync(join(cliRepo, '.env'), 'JIRA_PROJECT_KEY=FIXTURE\n');

describe('C0 credentials and port', () => {
  let fx;
  before(async () => { fx = new JiraFixture(); await fx.listen(); });
  after(async () => { await fx.close(); });

  const baseEnv = (root) => ({
    PATH: process.env.PATH, HOME: root, TMPDIR: root, NODE_ENV: 'test', HIMMEL_CONFIG_DIR: '/not-a-real-config',
    // Ambient decoys: the port must take its destination and credentials from the private file only.
    JIRA_BASE_URL: 'http://127.0.0.1:9', JIRA_API_TOKEN: 'ambient-decoy-token', JIRA_EMAIL: 'decoy@example.invalid', JIRA_PROJECT_KEY: 'DECOY',
  });
  async function mkPort(extra = {}) {
    const { createJiraPort } = await load();
    const s = scratch();
    writeCred(s.cred, goodCreds(fx.baseUrl));
    const port = await createJiraPort({ credentials_path: s.cred, primary_cli: PRIMARY_CLI }, { env: baseEnv(s.root), cwd: cliRepo, ...extra });
    return { port, ...s };
  }
  const soon = (ms = 20000) => Date.now() + ms;
  const reset = () => { fx.labels = ['a']; fx.mode = 'ok'; fx.requests.length = 0; fx.reflected = false; fx.summary = undefined; fx.extraFields = {}; fx.expectedAuth = `Basic ${Buffer.from(`${EMAIL}:${TOKEN}`).toString('base64')}`; };

  describe('private channel', () => {
    test('a mode 0600 file in a mode 0700 directory yields exactly the four fields', async () => {
      const { readCredentials } = await load();
      const s = scratch();
      writeCred(s.cred, goodCreds('http://127.0.0.1:4242/'));
      const got = await readCredentials(s.cred);
      assert.deepEqual({ ...got }, { base_url: 'http://127.0.0.1:4242', project: PROJECT, email: EMAIL, api_token: TOKEN });
    });

    const cases = [
      ['a missing file', 'missing', (s) => rmSync(s.cred, { force: true })],
      ['a directory that is not mode 0700 (0755)', 'dir-mode', (s) => { writeCred(s.cred, goodCreds('http://127.0.0.1:1')); chmodSync(s.attempt, 0o755); }],
      ['a directory that is not mode 0700 (0750)', 'dir-mode', (s) => { writeCred(s.cred, goodCreds('http://127.0.0.1:1')); chmodSync(s.attempt, 0o750); }],
      ['a file that is mode 0644', 'file-mode', (s) => writeCred(s.cred, goodCreds('http://127.0.0.1:1'), 0o644)],
      ['a file that is mode 0640', 'file-mode', (s) => writeCred(s.cred, goodCreds('http://127.0.0.1:1'), 0o640)],
      ['a file that is mode 0400 (not exactly 0600)', 'file-mode', (s) => writeCred(s.cred, goodCreds('http://127.0.0.1:1'), 0o400)],
      ['a symlinked credential file', 'file-symlink', (s) => {
        const real = join(s.root, 'real.json'); writeCred(real, goodCreds('http://127.0.0.1:1')); symlinkSync(real, s.cred);
      }],
      ['a hard-linked credential file', 'file-links', (s) => {
        writeCred(s.cred, goodCreds('http://127.0.0.1:1')); linkSync(s.cred, join(s.root, 'second-name.json'));
      }],
      ['a directory in the file position', 'file-type', (s) => mkdirSync(s.cred, { mode: 0o700 })],
      ['an empty file', 'file-size', (s) => writeCred(s.cred, '')],
      ['an oversize file', 'file-size', (s) => writeCred(s.cred, `{"pad":"${'x'.repeat(8192)}"}`)],
      ['invalid JSON that carries the sentinel', 'malformed', (s) => writeCred(s.cred, `{"api_token":"${TOKEN}", oops`)],
      ['a JSON array', 'malformed', (s) => writeCred(s.cred, '[]')],
      ['an unknown extra key', 'malformed', (s) => writeCred(s.cred, { ...goodCreds('http://127.0.0.1:1'), extra: TOKEN })],
      ['a missing field', 'malformed', (s) => { const g = goodCreds('http://127.0.0.1:1'); delete g.api_token; writeCred(s.cred, g); }],
      ['a non-string field', 'malformed', (s) => writeCred(s.cred, { ...goodCreds('http://127.0.0.1:1'), api_token: 7 })],
      ['a base_url with userinfo', 'malformed', (s) => writeCred(s.cred, goodCreds(`http://${EMAIL}:${TOKEN}@127.0.0.1:1`))],
      ['a base_url with a query', 'malformed', (s) => writeCred(s.cred, goodCreds('http://127.0.0.1:1/?x=1'))],
      ['a non-http base_url', 'malformed', (s) => writeCred(s.cred, goodCreds('ftp://127.0.0.1:1'))],
      ['a lower-case project', 'malformed', (s) => writeCred(s.cred, { ...goodCreds('http://127.0.0.1:1'), project: 'himmel' })],
      ['a token holding a newline (header injection)', 'malformed', (s) => writeCred(s.cred, { ...goodCreds('http://127.0.0.1:1'), api_token: `${TOKEN}\nX-Evil: 1` })],
    ];
    for (const [name, code, setup] of cases) {
      test(`refuses ${name} with code ${code} and never echoes a credential`, async () => {
        const { readCredentials } = await load();
        const s = scratch();
        setup(s);
        await assert.rejects(readCredentials(s.cred), (e) => {
          assert.equal(e.code, code, `got ${e.code}: ${e.message}`);
          assert.deepEqual(leaks(String(e.message)), [], 'the refusal text must not carry a credential form');
          assert.deepEqual(leaks(inspect(e, { depth: 5 })), [], 'nor may the error object');
          return true;
        });
      });
    }

    test('a symlinked attempt directory is refused', async () => {
      const { readCredentials } = await load();
      const s = scratch();
      writeCred(s.cred, goodCreds('http://127.0.0.1:1'));
      const link = join(s.root, 'attempt-link');
      symlinkSync(s.attempt, link);
      await assert.rejects(readCredentials(join(link, 'jira-credentials.json')), (e) => e.code === 'dir-symlink');
    });

    test('a path that reaches the attempt directory through a symlinked ANCESTOR is refused', async () => {
      const { readCredentials } = await load();
      const s = scratch();
      const real = join(s.root, 'real-parent');
      mkdirSync(join(real, 'attempt'), { recursive: true, mode: 0o700 });
      chmodSync(join(real, 'attempt'), 0o700);
      writeCred(join(real, 'attempt', 'jira-credentials.json'), goodCreds('http://127.0.0.1:1'));
      symlinkSync(real, join(s.root, 'linked-parent'));
      const viaLink = join(s.root, 'linked-parent', 'attempt', 'jira-credentials.json');
      await assert.rejects(readCredentials(viaLink), (e) => e.code === 'dir-symlink');
      const direct = await readCredentials(join(real, 'attempt', 'jira-credentials.json'));
      assert.equal(direct.api_token, TOKEN, 'positive control: the same file by its real path is accepted');
    });

    test('a relative or traversing path is refused before any filesystem access', async () => {
      const { readCredentials } = await load();
      for (const p of ['jira-credentials.json', '/tmp/../etc/x', '', undefined, 7]) {
        await assert.rejects(readCredentials(p), (e) => e.code === 'bad-path', `path ${String(p)}`);
      }
    });

    test('a file owned by someone else is refused', async () => {
      const { readCredentials } = await load();
      const s = scratch();
      writeCred(s.cred, goodCreds('http://127.0.0.1:1'));
      await assert.rejects(readCredentials(s.cred, { uid: process.getuid() + 1 }), (e) => e.code === 'owner');
    });

    test('a file replaced between the read and the identity check is refused (race)', async () => {
      const { readCredentials } = await load();
      const s = scratch();
      writeCred(s.cred, goodCreds('http://127.0.0.1:1'));
      const swapped = join(s.attempt, 'swapped.json');
      await assert.rejects(readCredentials(s.cred, {
        hooks: { afterRead: () => { writeCred(swapped, { ...goodCreds('http://127.0.0.1:2') }); renameSync(swapped, s.cred); } },
      }), (e) => e.code === 'identity-changed');
    });

    test('a file rewritten in place between the read and the identity check is refused (race)', async () => {
      const { readCredentials } = await load();
      const s = scratch();
      writeCred(s.cred, goodCreds('http://127.0.0.1:1'));
      await assert.rejects(readCredentials(s.cred, { hooks: { afterRead: () => appendFileSync(s.cred, ' ') } }), (e) => e.code === 'identity-changed');
    });

    test('positive control: the same file without the race is accepted (the refusals are not blanket)', async () => {
      const { readCredentials } = await load();
      const s = scratch();
      writeCred(s.cred, goodCreds('http://127.0.0.1:1'));
      const got = await readCredentials(s.cred, { hooks: { afterRead: () => {} } });
      assert.equal(got.api_token, TOKEN);
    });
  });

  describe('child process construction', () => {
    test('argv is fixed finite verbs, carries no credential and no model-chosen option', async () => {
      const { jiraArgv } = await load();
      assert.deepEqual(jiraArgv.get('HIMMEL-1'), ['get', 'HIMMEL-1', '--json']);
      assert.deepEqual(jiraArgv.label('HIMMEL-1', true), ['edit', 'HIMMEL-1', '--add-labels', LABEL]);
      assert.deepEqual(jiraArgv.label('HIMMEL-1', false), ['edit', 'HIMMEL-1', '--remove-labels', LABEL]);
      for (const argv of [jiraArgv.get('HIMMEL-1'), jiraArgv.label('HIMMEL-1', true)]) assert.deepEqual(leaks(argv), []);
    });

    test('a key that is not a bare ticket key never becomes argv', async () => {
      const { jiraArgv } = await load();
      for (const bad of ['', '-h', '--json', 'himmel-1', 'HIMMEL-1 --json', 'HIMMEL-1;id', '../../x', 'http://x/y', 'HIMMEL-', 'HIMMEL-1\n', null, 7, {}]) {
        assert.throws(() => jiraArgv.get(bad), (e) => e.code === 'bad-key', `key ${JSON.stringify(bad)}`);
      }
    });

    test('the child environment is the credentials plus a finite allowlist; ambient JIRA_* and secrets never pass', async () => {
      const { buildChildEnv } = await load();
      const env = buildChildEnv(goodCreds('http://127.0.0.1:5'), {
        PATH: '/usr/bin', HOME: '/h', NODE_ENV: 'test', HIMMEL_CONFIG_DIR: '/decoy', JIRA_BASE_URL: 'http://evil', JIRA_API_TOKEN: 'decoy', ANTHROPIC_API_KEY: 'x', GITHUB_TOKEN: 'y', CLAUDE_CODE_OAUTH_TOKEN: 'z', AWS_SECRET_ACCESS_KEY: 'w',
      });
      assert.equal(env.JIRA_BASE_URL, 'http://127.0.0.1:5');
      assert.equal(env.JIRA_API_TOKEN, TOKEN);
      assert.equal(env.JIRA_EMAIL, EMAIL);
      assert.equal(env.JIRA_PROJECT_KEY, PROJECT);
      assert.equal(env.PATH, '/usr/bin');
      for (const k of ['ANTHROPIC_API_KEY', 'GITHUB_TOKEN', 'CLAUDE_CODE_OAUTH_TOKEN', 'AWS_SECRET_ACCESS_KEY', 'NODE_ENV', 'HIMMEL_CONFIG_DIR']) assert.equal(env[k], undefined, k);
    });

    test('redact removes the raw, base64, url-encoded and hex forms of the credential and the Basic header', async () => {
      const { redact } = await load();
      const text = `HTTP 500: ${forms(TOKEN).join(' | ')} | Basic ${Buffer.from(`${EMAIL}:${TOKEN}`).toString('base64')} | ${EMAIL}`;
      const out = redact(text, goodCreds('http://127.0.0.1:5'));
      assert.deepEqual(leaks(out), []);
      assert.match(out, /\[redacted\]/);
      assert.equal(redact('nothing secret here', goodCreds('http://127.0.0.1:5')), 'nothing secret here');
    });

    test('accepted short tokens are redacted too', async () => {
      const { redact } = await load();
      assert.equal(redact('token=abc', { ...goodCreds('http://127.0.0.1:5'), api_token: 'abc' }), 'token=[redacted]');
    });
  });

  describe('real Jira port over loopback', () => {
    test('createJiraPort refuses a relative, missing or non-file primary_cli', async () => {
      const { createJiraPort } = await load();
      const s = scratch();
      writeCred(s.cred, goodCreds(fx.baseUrl));
      // `relative(cwd, PRIMARY_CLI)` names the REAL built CLI, so only the absolute-path rule can refuse it.
      for (const bad of [relative(process.cwd(), PRIMARY_CLI), join(s.root, 'no-such-cli.js'), s.attempt, s.cred, '', undefined]) {
        await assert.rejects(createJiraPort({ credentials_path: s.cred, primary_cli: bad }, { env: baseEnv(s.root), cwd: s.attempt }), (e) => e.code === 'bad-cli', `cli ${String(bad)}`);
      }
    });

    test('createJiraPort refuses missing or malformed credentials before any request', async () => {
      const { createJiraPort } = await load();
      reset();
      const s = scratch();
      await assert.rejects(createJiraPort({ credentials_path: s.cred, primary_cli: PRIMARY_CLI }, { env: baseEnv(s.root), cwd: s.attempt }), (e) => e.code === 'missing');
      writeCred(s.cred, '{not json', 0o600);
      await assert.rejects(createJiraPort({ credentials_path: s.cred, primary_cli: PRIMARY_CLI }, { env: baseEnv(s.root), cwd: s.attempt }), (e) => e.code === 'malformed');
      assert.equal(fx.requests.length, 0);
    });

    test('readIssue returns the typed issue; the destination and credentials came from the private file, not ambient env', async () => {
      reset();
      const { port } = await mkPort();
      const r = await port.readIssue('HIMMEL-1', soon());
      assert.equal(r.outcome, 'ok');
      assert.equal(r.issue.key, 'HIMMEL-1');
      assert.equal(r.issue.summary, 'a fixture ticket');
      assert.deepEqual(r.issue.labels, ['a']);
      assert.match(r.issue.issue_sha256, /^[0-9a-f]{64}$/);
      assert.ok(fx.requests.length >= 1 && fx.requests.every((q) => q.authOk), 'every request carried the file credentials, not the ambient decoy');
      assert.deepEqual(leaks(r), []);
    });

    test('addReadinessLabel adds, is idempotent and removes; readback agrees with the service', async () => {
      reset();
      const { port } = await mkPort();
      const add = await port.addReadinessLabel('HIMMEL-1', true, soon());
      assert.equal(add.outcome, 'ok');
      assert.deepEqual(fx.labels, ['a', LABEL]);
      const rb = await port.readback('HIMMEL-1', soon());
      assert.equal(rb.outcome, 'ok');
      assert.equal(rb.kind, 'readback');
      assert.deepEqual(rb.issue.labels, ['a', LABEL]);
      assert.equal((await port.addReadinessLabel('HIMMEL-1', true, soon())).outcome, 'ok');
      assert.deepEqual(fx.labels, ['a', LABEL], 'adding twice never duplicates');
      assert.equal((await port.addReadinessLabel('HIMMEL-1', false, soon())).outcome, 'ok');
      assert.deepEqual(fx.labels, ['a']);
      assert.deepEqual((await port.readback('HIMMEL-1', soon())).issue.labels, ['a']);
      assert.ok(fx.requests.every((q) => q.authOk));
    });

    test('a reflected-credential error is redacted before it reaches the caller (with a non-vacuity control)', async () => {
      reset();
      const { port, root, attempt } = await mkPort();
      fx.mode = 'reflect';
      // Control: the real CLI, run directly with the same environment, DOES print the reflected credential.
      const { buildChildEnv } = await load();
      // (async: the loopback service lives in this process, so a synchronous child would starve it)
      const raw = await new Promise((done) => {
        execFile(process.execPath, [PRIMARY_CLI, 'get', 'HIMMEL-1', '--json'], { env: buildChildEnv(goodCreds(fx.baseUrl), baseEnv(root)), cwd: attempt, encoding: 'utf8', timeout: 20000 },
          (err, so, se) => done(`${se}${so}`));
      });
      assert.ok(fx.reflected, 'the fixture reflected the credentials');
      assert.ok(leaks(raw).length > 0, 'control: unredacted CLI output carries the credential, so the redaction below is doing real work');
      reset(); fx.mode = 'reflect';
      for (const [expected, call] of [
        ['error', () => port.readIssue('HIMMEL-1', soon())],
        ['error', () => port.readback('HIMMEL-1', soon())],
        ['ambiguous', () => port.addReadinessLabel('HIMMEL-1', true, soon())],
      ]) {
        const r = await call();
        assert.equal(r.outcome, expected);
        assert.deepEqual(leaks(r), [], 'no credential form in the typed result');
        assert.match(r.message, /\[redacted\]/);
      }
    });

    test('a nonzero write exit is ambiguous, even when the fixture knows it did not land', async () => {
      reset();
      const { port } = await mkPort();
      fx.mode = 'put-500-no-apply';
      const failed = await port.addReadinessLabel('HIMMEL-1', true, soon());
      assert.equal(failed.outcome, 'ambiguous');
      assert.deepEqual(fx.labels, ['a']);
      reset(); fx.mode = 'hold-put';
      const lost = await port.addReadinessLabel('HIMMEL-1', true, Date.now() + 2500);
      assert.equal(lost.outcome, 'ambiguous');
      assert.deepEqual(fx.labels, ['a', LABEL], 'the write really did land');
      fx.mode = 'ok';
      const rb = await port.readback('HIMMEL-1', soon());
      assert.deepEqual(rb.issue.labels, ['a', LABEL], 'readback is how an ambiguous write is resolved');
    });

    test('the CLI request timeout after an applied write remains ambiguous', async () => {
      reset();
      const s = scratch();
      const { port } = await mkPort({ env: { ...baseEnv(s.root), JIRA_REQUEST_TIMEOUT_MS: '700' } });
      fx.mode = 'hold-put';
      const result = await port.addReadinessLabel('HIMMEL-1', true, soon());
      assert.deepEqual(fx.labels, ['a', LABEL]);
      assert.equal(result.outcome, 'ambiguous');
      assert.match(result.message, /may have been applied/);
    });

    test('redaction cannot corrupt a typed JSON response', async () => {
      reset();
      const token = '\":\"Op';
      const s = scratch();
      writeCred(s.cred, { ...goodCreds(fx.baseUrl), api_token: token });
      fx.expectedAuth = `Basic ${Buffer.from(`${EMAIL}:${token}`).toString('base64')}`;
      fx.summary = `prefix ${token} suffix`;
      const { createJiraPort } = await load();
      const port = await createJiraPort({ credentials_path: s.cred, primary_cli: PRIMARY_CLI }, { env: baseEnv(s.root), cwd: cliRepo });
      const result = await port.readIssue('HIMMEL-1', soon());
      assert.equal(result.outcome, 'ok');
      assert.equal(result.issue.key, 'HIMMEL-1');
      assert.equal(result.issue.summary, 'prefix [redacted] suffix');
    });

    test('a credential collision with issue identity refuses instead of returning a changed key', async () => {
      reset();
      const token = PROJECT;
      const s = scratch();
      writeCred(s.cred, { ...goodCreds(fx.baseUrl), api_token: token });
      fx.expectedAuth = `Basic ${Buffer.from(`${EMAIL}:${token}`).toString('base64')}`;
      const { createJiraPort } = await load();
      const port = await createJiraPort({ credentials_path: s.cred, primary_cli: PRIMARY_CLI }, { env: baseEnv(s.root), cwd: cliRepo });
      const result = await port.readIssue('HIMMEL-1', soon());
      assert.equal(result.outcome, 'error');
      assert.equal(result.code, 'unreadable');
      assert.equal(result.message.includes(token), false);
    });

    test('credential collisions cannot change authoritative issue fields', async () => {
      for (const [token, fields] of [
        ['needs', { labels: [LABEL] }],
        ['Open', { status: { name: 'Open' } }],
        ['Task', { issuetype: { name: 'Task' } }],
        ['version', { fixVersions: [{ name: 'version-one' }] }],
      ]) {
        reset();
        const s = scratch();
        writeCred(s.cred, { ...goodCreds(fx.baseUrl), api_token: token });
        fx.expectedAuth = `Basic ${Buffer.from(`${EMAIL}:${token}`).toString('base64')}`;
        fx.extraFields = fields;
        const { createJiraPort } = await load();
        const port = await createJiraPort({ credentials_path: s.cred, primary_cli: PRIMARY_CLI }, { env: baseEnv(s.root), cwd: cliRepo });
        const result = await port.readback('HIMMEL-1', soon());
        assert.equal(result.outcome, 'error', token);
        assert.equal(result.code, 'unreadable', token);
      }
    });

    test('an expired deadline makes no request', async () => {
      reset();
      const { port } = await mkPort();
      for (const call of [() => port.readIssue('HIMMEL-1', Date.now() - 1), () => port.addReadinessLabel('HIMMEL-1', true, Date.now() - 1), () => port.readback('HIMMEL-1', 0)]) {
        const r = await call();
        assert.equal(r.outcome, 'error');
        assert.equal(r.code, 'deadline');
      }
      assert.equal(fx.requests.length, 0);
    });

    test('a model-shaped key (url, option, shell text) is refused with zero requests', async () => {
      reset();
      const { port } = await mkPort();
      for (const bad of ['http://127.0.0.1:9/x', '--json', 'HIMMEL-1; id', '../../etc/passwd', '', null]) {
        for (const r of [await port.readIssue(bad, soon()), await port.readback(bad, soon()), await port.addReadinessLabel(bad, true, soon())]) {
          assert.equal(r.outcome, 'error');
          assert.equal(r.code, 'bad-key');
        }
      }
      assert.equal(fx.requests.length, 0);
    });

    test('the other port methods stay unsupported and cause zero effects', async () => {
      reset();
      const { port } = await mkPort();
      for (const [name, args] of [
        ['findMarker', ['HIMMEL-1', 'm', soon()]], ['postComment', ['HIMMEL-1', 'm', 'text', soon()]], ['addBlocks', ['HIMMEL-1', 'HIMMEL-2', soon()]],
        ['findFollowup', ['id', soon()]], ['createBacklog', [{}, 'id', soon()]],
      ]) {
        const r = await port[name](...args);
        assert.deepEqual({ outcome: r.outcome, effects: r.effects }, { outcome: 'unsupported', effects: 0 }, name);
      }
      assert.equal(fx.requests.length, 0);
      assert.deepEqual(fx.labels, ['a']);
    });

    test('the port exposes no raw request, method, url, header or executable capability', async () => {
      const { port } = await mkPort();
      const names = Object.keys(port).sort();
      assert.deepEqual(names, ['addBlocks', 'addReadinessLabel', 'createBacklog', 'findFollowup', 'findMarker', 'kind', 'postComment', 'readIssue', 'readback']);
      assert.equal(port.kind, 'jira');
      assert.deepEqual(leaks(inspect(port, { showHidden: true, depth: 6 })), [], 'no credential in enumerable or hidden port state');
      assert.deepEqual(leaks(JSON.stringify(port)), []);
    });
  });

  describe('port selection', () => {
    test('the host picks the kind: copy never reads the credential file, jira reads it', async () => {
      const { selectPort } = await load();
      const s = scratch();
      let read = 0; let made = 0;
      const deps = { readCredentials: async () => { read += 1; throw new Error('must not be called'); }, makeCopyPort: () => { made += 1; return { kind: 'copy' }; } };
      const copy = await selectPort({ port: { kind: 'copy', credentials_path: join(s.attempt, 'does-not-exist.json'), primary_cli: PRIMARY_CLI } }, deps);
      assert.equal(copy.kind, 'copy');
      assert.equal(read, 0);
      assert.equal(made, 1);
    });

    test('jira kind with absent credentials refuses; an unknown kind refuses; neither builds a copy port', async () => {
      const { selectPort } = await load();
      const s = scratch();
      const env = baseEnv(s.root);
      let made = 0;
      const deps = { makeCopyPort: () => { made += 1; return { kind: 'copy' }; }, env, cwd: s.attempt };
      await assert.rejects(selectPort({ port: { kind: 'jira', credentials_path: s.cred, primary_cli: PRIMARY_CLI } }, deps), (e) => e.code === 'missing');
      await assert.rejects(selectPort({ port: { kind: 'raw-http', credentials_path: s.cred, primary_cli: PRIMARY_CLI } }, deps), (e) => e.code === 'bad-kind');
      await assert.rejects(selectPort({ port: { credentials_path: s.cred } }, deps), (e) => e.code === 'bad-kind');
      assert.equal(made, 0);
    });

    test('jira kind with good credentials yields the real port', async () => {
      reset();
      const { selectPort } = await load();
      const s = scratch();
      writeCred(s.cred, goodCreds(fx.baseUrl));
      const port = await selectPort({ port: { kind: 'jira', credentials_path: s.cred, primary_cli: PRIMARY_CLI } }, { env: baseEnv(s.root), cwd: s.attempt });
      assert.equal(port.kind, 'jira');
      assert.equal((await port.readIssue('HIMMEL-1', soon())).outcome, 'ok');
    });
  });
});

// A harness self-check that is NOT part of the named group: the fixture itself must work, or a RED
// above could be a broken harness rather than a missing product. Separate so it can be run alone.
describe('C0 fixture sanity', () => {
  test('the built primary CLI exists and the scratch layout is mode 0700', () => {
    assert.ok(existsSync(PRIMARY_CLI), `the built primary Jira CLI is required at ${PRIMARY_CLI} (npm run build in scripts/jira)`);
    const s = scratch();
    assert.equal(statSync(s.attempt).mode & 0o777, 0o700);
  });
});
