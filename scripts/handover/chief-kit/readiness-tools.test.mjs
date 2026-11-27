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
  chmodSync, existsSync, linkSync, mkdirSync, mkdtempSync, readdirSync, realpathSync, renameSync, rmSync,
  statSync, symlinkSync, writeFileSync, appendFileSync, copyFileSync, readFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, relative } from 'node:path';
import { execFile, execFileSync, spawn, spawnSync } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { inspect } from 'node:util';

const HERE = dirname(fileURLToPath(import.meta.url));
const load = () => import(pathToFileURL(join(HERE, 'readiness-tools.mjs')).href);
// the project root a session hook runs under (Claude Code exports it as CLAUDE_PROJECT_DIR; the adapter derives the same value)
const PROJECT_ROOT = join(HERE, '..', '..', '..');

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
    return { key: 'HIMMEL-1', fields: { summary: this.summary ?? 'a fixture ticket', status: { name: 'Open' }, issuetype: { name: 'Task' }, labels: [...this.labels], fixVersions: [], description: null, ...this.extraFields } };
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
// LAZY: only the groups that drive the real primary CLI call ensureCliCopy(), so a name-filtered run of any other
// group (the C0 envelope rows) neither copies the 67-module closure nor needs the untracked primary build.
let realRepo;
let cliRepo;
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
function ensureCliCopy() {
  if (PRIMARY_CLI) return;
  // the one named prerequisite of the credential and port groups: the real built primary Jira CLI, which a clean checkout does not have
  if (!existsSync(ORIGINAL_CLI)) {
    throw new Error(`PREREQUISITE-ABSENT: the built primary Jira CLI is required at ${ORIGINAL_CLI} (owner: the primary checkout's scripts/jira build, npm ci && npm run build; READINESS_PRIMARY_CLI names another build). This suite has no stand-in CLI and no skip.`);
  }
  const cliHome = scratch();
  realRepo = primaryCheckout();
  cliRepo = join(cliHome.root, 'cli-repo');
  mkdirSync(cliRepo);
  writeFileSync(join(cliRepo, 'package.json'), '{"type":"module"}\n');
  execFileSync('git', ['init', '-q', cliRepo], { env: { PATH: process.env.PATH, HOME: cliHome.root, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_SYSTEM: '/dev/null' } });
  copyModule(ORIGINAL_CLI);
  for (const rel of ['node_modules', 'scripts/jira/node_modules']) {
    if (!existsSync(join(realRepo, rel))) continue;
    const target = join(cliRepo, rel);
    mkdirSync(dirname(target), { recursive: true });
    symlinkSync(join(realRepo, rel), target, 'dir');
  }
  writeFileSync(join(cliRepo, '.env'), 'JIRA_PROJECT_KEY=FIXTURE\n');
  PRIMARY_CLI = join(cliRepo, relative(realRepo, ORIGINAL_CLI));
}

describe('C0 credentials and port', () => {
  let fx;
  before(async () => { ensureCliCopy(); fx = new JiraFixture(); await fx.listen(); });
  after(async () => { await fx.close(); });

  const baseEnv = (root) => ({
    PATH: process.env.PATH, HOME: root, TMPDIR: root, NODE_ENV: 'test', HIMMEL_CONFIG_DIR: '/not-a-real-config',
    // Ambient decoys: the port must take its destination and credentials from the private file only.
    JIRA_BASE_URL: 'http://127.0.0.1:9', JIRA_API_TOKEN: 'ambient-decoy-token', JIRA_EMAIL: 'decoy@example.invalid', JIRA_PROJECT_KEY: 'DECOY',
    JIRA_ALLOW_HOST: new URL(fx.baseUrl).host,
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
      await assert.rejects(readCredentials(s.cred, { uid: process.getuid() + 1 }), (e) => e.code === 'owner' && /directory/.test(e.message), 'with the folder foreign too, it is the folder rule that fires');
    });

    test('X14-7: a file owned by someone else in a folder that is ours is refused by the FILE owner rule alone', async () => {
      const { readCredentials } = await load();
      const s = scratch();
      writeCred(s.cred, goodCreds('http://127.0.0.1:1'));
      const me = process.getuid();
      await assert.rejects(readCredentials(s.cred, { uid: me, fileUid: me + 1 }), (e) => e.code === 'owner' && /credential file/.test(e.message) && !/directory/.test(e.message));
      assert.equal((await readCredentials(s.cred, { uid: me, fileUid: me })).api_token, TOKEN, 'control: the same file with the matching file owner is accepted');
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

    test('the child environment is the credentials plus a finite allowlist; ambient JIRA_* (except the timeout and JIRA_ALLOW_HOST settings) and secrets never pass', async () => {
      const { buildChildEnv } = await load();
      const env = buildChildEnv(goodCreds('http://127.0.0.1:5'), {
        PATH: '/usr/bin', HOME: '/h', NODE_ENV: 'test', HIMMEL_CONFIG_DIR: '/decoy', JIRA_BASE_URL: 'http://evil', JIRA_API_TOKEN: 'decoy', JIRA_ALLOW_HOST: '127.0.0.1:5', ANTHROPIC_API_KEY: 'x', GITHUB_TOKEN: 'y', CLAUDE_CODE_OAUTH_TOKEN: 'z', AWS_SECRET_ACCESS_KEY: 'w',
      });
      assert.equal(env.JIRA_BASE_URL, 'http://127.0.0.1:5');
      assert.equal(env.JIRA_ALLOW_HOST, '127.0.0.1:5', 'the operator opt-in names the one host the child may reach');
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

    test('X14-2: a ticket with a non-string label, missing or malformed fix versions or a missing description is unreadable, never ok', async () => {
      const { port } = await mkPort();
      const bad = {
        'a numeric label': { labels: [7] },
        'a numeric label beside a real one': { labels: ['needs-readiness', 7] },
        'fix versions missing': { fixVersions: undefined },
        'fix versions not a list': { fixVersions: 'junk' },
        'a fix version without a name': { fixVersions: [{}] },
        'a fix version that is a bare string': { fixVersions: ['v1.1.3'] },
        'a description missing': { description: undefined },
      };
      for (const [name, fields] of Object.entries(bad)) {
        reset();
        fx.extraFields = fields;
        for (const [verb, call] of [['readIssue', () => port.readIssue('HIMMEL-1', soon())], ['readback', () => port.readback('HIMMEL-1', soon())]]) {
          const r = await call();
          assert.equal(r.outcome, 'error', `${verb}: ${name}`);
          assert.equal(r.code, 'unreadable', `${verb}: ${name}`);
        }
      }
      reset();
      fx.extraFields = { fixVersions: [{ name: 'v1.1.3' }], description: 'text' };
      const ok = await port.readIssue('HIMMEL-1', soon());
      assert.equal(ok.outcome, 'ok', 'control: a well-formed ticket with a fix version and a description reads');
      assert.deepEqual(ok.issue.fixVersions, ['v1.1.3']);
      reset();
      const empty = await port.readIssue('HIMMEL-1', soon());
      assert.equal(empty.outcome, 'ok', 'control: no fix versions (an empty list) and a null description read');
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

// C0s cycle 2: the launcher's host-only credential initialization. A FAKE primary checkout (a client.js that
// answers like the real client's baseUrl / projectKey / authHeader) stands in for the configuration and secrets
// flow, so no real config, keyring or secret is read; the sentinel is hunted for in every channel but the private file.
describe('C0s2 credentials init', () => {
  const SENTINEL = 'fake-c0s2-init-token-5d1b7c9e';
  const fakePrimary = (client) => {
    const s = scratch();
    const dist = join(s.root, 'primary', 'scripts', 'jira', 'dist');
    mkdirSync(dist, { recursive: true });
    writeFileSync(join(dist, 'index.js'), '// fake primary CLI\n');
    writeFileSync(join(dist, 'client.js'), client);
    return { ...s, cli: join(dist, 'index.js'), out: join(s.attempt, 'credentials.json') };
  };
  const goodClient = (url = 'http://127.0.0.1:9') => `export const baseUrl = () => '${url}';
export const projectKey = () => 'FIXT';
export function authHeader() { return 'Basic ' + Buffer.from('fixture@example.invalid:${SENTINEL}').toString('base64'); }
`;
  const runCli = (args) => new Promise((done) => {
    execFile(process.execPath, [join(HERE, 'readiness-tools.mjs'), ...args], { env: { PATH: process.env.PATH, HOME: tmpdir() } }, (err, stdout, stderr) => {
      done({ code: err ? err.code : 0, stdout: String(stdout), stderr: String(stderr) });
    });
  });

  test('the client flow yields exactly the four fields in a private 0600 file; the CLI prints nothing', async () => {
    const f = fakePrimary(goodClient());
    const r = await runCli(['init-credentials', f.cli, f.out]);
    assert.equal(r.code, 0);
    assert.equal(r.stdout, '');
    assert.equal(r.stderr, '');
    assert.equal(statSync(f.out).mode & 0o777, 0o600);
    assert.deepEqual(JSON.parse(readFileSync(f.out, 'utf8')), { api_token: SENTINEL, base_url: 'http://127.0.0.1:9', email: 'fixture@example.invalid', project: 'FIXT' });
    // and the very reader the adapter uses accepts it
    const { readCredentials } = await load();
    assert.equal((await readCredentials(f.out)).api_token, SENTINEL);
  });

  test('every refusal says which rule failed and never prints a credential value', async () => {
    const cases = [
      ['a relative primary CLI', () => ['init-credentials', 'scripts/jira/dist/index.js', fakePrimary(goodClient()).out]],
      ['a primary CLI that is not index.js', () => { const f = fakePrimary(goodClient()); return ['init-credentials', join(f.root, 'primary', 'scripts', 'jira', 'dist', 'client.js'), f.out]; }],
      ['a primary CLI that does not exist', () => { const f = fakePrimary(goodClient()); return ['init-credentials', join(f.root, 'nope', 'index.js'), f.out]; }],
      ['a client with no complete configuration', () => { const f = fakePrimary(`export const baseUrl = () => { throw new Error('JIRA_BASE_URL is not set'); };\nexport const projectKey = () => 'FIXT';\nexport const authHeader = () => 'x';\n`); return ['init-credentials', f.cli, f.out]; }],
      ['a client whose authorization is not Basic', () => { const f = fakePrimary(goodClient().replace("'Basic '", "'Bearer '")); return ['init-credentials', f.cli, f.out]; }],
      ['a client module that cannot be loaded', () => { const f = fakePrimary('this is not javascript ((('); return ['init-credentials', f.cli, f.out]; }],
      ['a base URL with userinfo (the credential validator refuses it)', () => { const f = fakePrimary(goodClient('http://user:pw@127.0.0.1:9')); return ['init-credentials', f.cli, f.out]; }],
      ['an attempt directory that is not mode 0700', () => { const f = fakePrimary(goodClient()); chmodSync(f.attempt, 0o755); return ['init-credentials', f.cli, f.out]; }],
      ['a credential path that already exists (exclusive create)', () => { const f = fakePrimary(goodClient()); writeFileSync(f.out, 'old', { mode: 0o600 }); return ['init-credentials', f.cli, f.out]; }],
      ['a credential path in a missing directory', () => { const f = fakePrimary(goodClient()); return ['init-credentials', f.cli, join(f.root, 'no-dir', 'credentials.json')]; }],
      ['a wrong operand count', () => ['init-credentials', 'only-one']],
      ['an unknown verb', () => ['serve']],
    ];
    for (const [label, build] of cases) {
      const r = await runCli(build());
      assert.equal(r.code, 2, label);
      assert.equal(r.stdout, '', label);
      assert.ok(!r.stderr.includes(SENTINEL) && !r.stderr.includes('fixture@example.invalid'), `${label}: a credential value reached stderr`);
      assert.match(r.stderr, /readiness-tools|usage:/, label);
    }
  });

  test('a refused initialization leaves no credential file behind', async () => {
    const f = fakePrimary(goodClient().replace("'Basic '", "'Bearer '"));
    await runCli(['init-credentials', f.cli, f.out]);
    assert.equal(existsSync(f.out), false);
  });

  test('the library function accepts an injected client loader and still validates', async () => {
    const { initCredentials } = await load();
    const f = fakePrimary(goodClient());
    await initCredentials(f.cli, f.out, { importClient: async () => ({ baseUrl: () => 'http://127.0.0.1:7', projectKey: () => 'FIXT', authHeader: () => `Basic ${Buffer.from(`a@b.invalid:${SENTINEL}`).toString('base64')}` }) });
    assert.equal(JSON.parse(readFileSync(f.out, 'utf8')).base_url, 'http://127.0.0.1:7');
  });
});

// C0s cycle 2: the adapter's ownership gate. Every act, finish included, is verified afresh against the REAL
// readiness-session.sh and the REAL queue-lock.sh in a scratch handover root, runtime directory and HOME; the
// attempt below is exactly what the launcher leaves (a private startup config plus the on-behalf lease's transport).
// A recording stub stands in for the session script only where the child's argv and environment are the subject.
describe('C0s2 adopted ownership', () => {
  const QL = join(HERE, '..', 'queue-lock.sh');
  const SESSION = join(HERE, '..', '..', 'hooks', 'readiness-session.sh');
  const PLUGIN_SESSION = join(PROJECT_ROOT, 'marketplace', 'plugins', 'himmel-ops', 'scripts', 'readiness-session.sh');
  const TOKEN_SENTINEL_ENV = 'ambient-secret-must-not-reach-the-child';
  function world() {
    const root = realpathSync(mkdtempSync(join(tmpdir(), 'c0s2-own-')));
    roots.push(root);
    const xdg = join(root, 'xdg'); mkdirSync(xdg, { mode: 0o700 }); chmodSync(xdg, 0o700);
    const hd = join(root, 'hd'); mkdirSync(join(hd, 'u', 'r'), { recursive: true });
    const home = join(root, 'home'); mkdirSync(home);
    const env = { PATH: process.env.PATH, HOME: home, XDG_RUNTIME_DIR: xdg, HANDOVER_DIR: hd };
    let n = 0;
    const ql = (verb, args, extra = {}) => spawnSync('bash', [QL, verb, ...args], { env: { ...env, ...extra }, encoding: 'utf8' });
    const w = {
      root, env, xdg, hd,
      status: (doc) => ql('status', [doc]).stdout.trim().split('\n').pop(),
      owner: (doc) => {
        const m = /"session":"([^"]+)"/.exec(ql('status', [doc]).stdout);
        return m ? m[1] : null;
      },
      hold: (doc, token) => ql('acquire', [doc, token]),
      drop: (doc, token) => ql('release', [doc, token]),
      attempt() {
        n += 1;
        const doc = join(hd, 'u', 'r', `readiness-v1.${n}.0.md`);
        writeFileSync(doc, '---\ndescription: fixture\n---\n');
        const sid = randomUUID();
        const base = join(xdg, 'himmel-readiness');
        mkdirSync(base, { recursive: true, mode: 0o700 }); chmodSync(base, 0o700);
        const dir = join(base, sid); mkdirSync(dir, { mode: 0o700 }); chmodSync(dir, 0o700);
        const startupPath = join(dir, 'startup.json');
        writeFileSync(startupPath, JSON.stringify({
          schema: 'readiness-startup-v1', attempt_id: `a-${sid}`, session_scope: sid, version: `v1.${n}.0`, doc, lane: 'native', model: 'fixture-model', queue_lock: QL, runtime_dir: xdg, handover_dir: hd, port: { kind: 'copy' },
        }), { mode: 0o600 });
        chmodSync(startupPath, 0o600);
        const acquired = ql('acquire', [doc], { QUEUE_LOCK_ON_BEHALF: '1' });
        const token = /release-token: `([^`]+)`/.exec(acquired.stdout)[1];
        writeFileSync(join(dir, 'lease-token'), `${token}\n`, { mode: 0o600 });
        chmodSync(join(dir, 'lease-token'), 0o600);
        return { doc, sid, dir, startupPath, token };
      },
      // the SessionStart payload carries the session's own transcript (created here unless withTranscript is false)
      // projectDir is the CLAUDE_PROJECT_DIR the hook runs under: this checkout's root by default, null = not exported
      start: (a, { withTranscript = true, tool = SESSION, projectDir = PROJECT_ROOT, cwd } = {}) => {
        const transcript = join(home, 'projects', 'p', `${a.sid}.jsonl`);
        if (withTranscript) { mkdirSync(join(home, 'projects', 'p'), { recursive: true }); writeFileSync(transcript, ''); }
        return spawnSync('bash', [tool, 'startup'], {
          input: JSON.stringify({ session_id: a.sid, hook_event_name: 'SessionStart', source: 'startup', ...(withTranscript ? { transcript_path: transcript } : {}) }),
          env: { ...env, CLAUDE_CODE_SESSION_ID: a.sid, ...(projectDir === null ? {} : { CLAUDE_PROJECT_DIR: projectDir }) }, cwd, encoding: 'utf8',
        });
      },
    };
    return w;
  }
  const spyPort = () => {
    const calls = [];
    return { calls, port: { addReadinessLabel: async (...args) => { calls.push(args); return { outcome: 'ok' }; } } };
  };
  const SOON = () => Date.now() + 20000;
  const noToken = (value, token) => assert.ok(!JSON.stringify(value).includes(token), 'the lease token reached a returned value');

  test('loadStartup accepts the launcher-shaped private file and returns only what the adapter reads', async () => {
    const { loadStartup } = await load();
    const a = world().attempt();
    const s = loadStartup(a.startupPath);
    assert.deepEqual({ ...s, port: { ...s.port } }, { path: a.startupPath, dir: a.dir, session_scope: a.sid, doc: a.doc, version: 'v1.1.0', attempt_id: `a-${a.sid}`, port: { kind: 'copy' } });
    assert.ok(Object.isFrozen(s));
  });

  test('loadStartup refuses every shape that is not the private, bound startup file', async () => {
    const { loadStartup } = await load();
    const w = world();
    const cases = [
      ['a directory that is not mode 0700', 'dir-mode', (a) => chmodSync(a.dir, 0o755)],
      ['a file that is not mode 0600', 'startup-file', (a) => chmodSync(a.startupPath, 0o644)],
      ['a symlinked file', 'startup-file', (a) => { const real = join(a.dir, 'real.json'); renameSync(a.startupPath, real); symlinkSync(real, a.startupPath); }],
      ['a file with two links', 'startup-file', (a) => linkSync(a.startupPath, join(w.root, 'second-link'))],
      ['invalid JSON', 'malformed', (a) => writeFileSync(a.startupPath, 'not json', { mode: 0o600 })],
      ['another schema', 'malformed', (a) => rewrite(a, { schema: 'other' })],
      ['another lane', 'malformed', (a) => rewrite(a, { lane: 'claudex' })],
      ['a scope that is not the directory id', 'malformed', (a) => rewrite(a, { session_scope: randomUUID() })],
      ['a scope that is not a uuid', 'malformed', (a) => rewrite(a, { session_scope: 'not-a-uuid' })],
      ['a relative doc', 'malformed', (a) => rewrite(a, { doc: 'readiness-v1.md' })],
      ['a queue lock that is not queue-lock.sh', 'malformed', (a) => rewrite(a, { queue_lock: '/bin/true' })],
      ['a missing version', 'malformed', (a) => rewrite(a, { version: '' })],
      ['a port kind that is neither copy nor jira', 'malformed', (a) => rewrite(a, { port: { kind: 'raw-http' } })],
    ];
    function rewrite(a, patch) {
      const cur = JSON.parse(readFileSync(a.startupPath, 'utf8'));
      writeFileSync(a.startupPath, JSON.stringify({ ...cur, ...patch }), { mode: 0o600 });
    }
    for (const [label, code, mutate] of cases) {
      const a = w.attempt();
      mutate(a);
      assert.throws(() => loadStartup(a.startupPath), (e) => e.code === code, label);
    }
    assert.throws(() => loadStartup('relative/startup.json'), (e) => e.code === 'bad-path');
    assert.throws(() => loadStartup(join(w.root, 'xdg', 'himmel-readiness', 'other.json')), (e) => e.code === 'bad-path');
  });

  test('before adoption every act and finish is refused with not-adopted, nothing runs, and the lease is untouched', async () => {
    const { loadStartup, checkAdopted, guardedLabel, finishAttempt } = await load();
    const w = world();
    const a = w.attempt();
    const startup = loadStartup(a.startupPath);
    const spy = spyPort();
    assert.deepEqual(await checkAdopted(startup, { env: w.env }), { ok: false, code: 'not-adopted', reason: 'this session has not adopted the readiness lease, or no longer holds it' });
    const label = await guardedLabel(startup, spy.port, 'HIMMEL-1', true, SOON(), { env: w.env });
    assert.equal(label.code, 'not-adopted');
    assert.equal(spy.calls.length, 0, 'the port must not be touched before adoption');
    const fin = await finishAttempt(startup, { env: w.env });
    assert.equal(fin.code, 'not-adopted');
    assert.equal(w.owner(a.doc), a.token, 'finish before adoption must not release the on-behalf lease');
    assert.ok(existsSync(a.dir));
    noToken([label, fin], a.token);
  });

  test('after the session start adopts, an act reaches the port exactly once and is verified afresh each time', async () => {
    const { loadStartup, checkAdopted, guardedLabel } = await load();
    const w = world();
    const a = w.attempt();
    assert.equal(w.start(a).status, 0);
    const startup = loadStartup(a.startupPath);
    assert.deepEqual(await checkAdopted(startup, { env: w.env }), { ok: true });
    const spy = spyPort();
    const first = await guardedLabel(startup, spy.port, 'HIMMEL-1', true, SOON(), { env: w.env });
    assert.deepEqual(first, { ok: true, type: 'label', key: 'HIMMEL-1', outcome: 'updated', evidence_id: null });
    assert.equal(spy.calls.length, 1);
    assert.deepEqual(spy.calls[0].slice(0, 2), ['HIMMEL-1', true]);
    // the next act is checked again: the lease is lost between the two, so the second one never reaches the port
    w.drop(a.doc, a.token); w.hold(a.doc, 'successor-token-own1');
    const second = await guardedLabel(startup, spy.port, 'HIMMEL-1', false, SOON(), { env: w.env });
    assert.equal(second.code, 'not-adopted');
    assert.equal(spy.calls.length, 1, 'a lost lease must stop the very next act before its effect');
    noToken([first, second], a.token);
  });

  test('a port that does not confirm the write is a conflict, not a success', async () => {
    const { loadStartup, guardedLabel } = await load();
    const w = world();
    const a = w.attempt();
    w.start(a);
    const r = await guardedLabel(loadStartup(a.startupPath), { addReadinessLabel: async () => ({ outcome: 'ambiguous', code: 'timeout' }) }, 'HIMMEL-1', true, SOON(), { env: w.env });
    assert.equal(r.code, 'conflict');
  });

  test('finish releases exactly the adopted lease and removes the attempt; a repeated finish refuses', async () => {
    const { loadStartup, finishAttempt } = await load();
    const w = world();
    const a = w.attempt();
    w.start(a);
    const startup = loadStartup(a.startupPath);
    const done = await finishAttempt(startup, { env: w.env });
    assert.deepEqual(done, { ok: true, type: 'finish', key: null, outcome: 'finished', evidence_id: null });
    assert.equal(w.status(a.doc), 'free');
    assert.equal(existsSync(a.dir), false);
    assert.equal((await finishAttempt(startup, { env: w.env })).code, 'not-adopted');
    noToken(done, a.token);
  });

  test('finish never releases a successor\'s lock', async () => {
    const { loadStartup, finishAttempt } = await load();
    const w = world();
    const a = w.attempt();
    w.start(a);
    w.drop(a.doc, a.token); w.hold(a.doc, 'successor-token-own2');
    const r = await finishAttempt(loadStartup(a.startupPath), { env: w.env });
    assert.equal(r.code, 'not-adopted');
    assert.equal(w.owner(a.doc), 'successor-token-own2');
    assert.ok(existsSync(a.dir));
  });

  test('a session that started under another id adopts nothing: every act refuses and the on-behalf lease stays put', async () => {
    const { loadStartup, guardedLabel } = await load();
    const w = world();
    const a = w.attempt();
    const other = { ...a, sid: randomUUID() };
    assert.equal(w.start(other).status, 0);
    const spy = spyPort();
    assert.equal((await guardedLabel(loadStartup(a.startupPath), spy.port, 'HIMMEL-1', true, SOON(), { env: w.env })).code, 'not-adopted');
    assert.equal(spy.calls.length, 0);
    assert.equal(w.owner(a.doc), a.token);
  });

  test('a session start whose payload carries no transcript adopts nothing: every act refuses and the on-behalf lease stays put', async () => {
    const { loadStartup, guardedLabel } = await load();
    const w = world();
    const a = w.attempt();
    assert.equal(w.start(a, { withTranscript: false }).status, 0);
    const spy = spyPort();
    assert.equal((await guardedLabel(loadStartup(a.startupPath), spy.port, 'HIMMEL-1', true, SOON(), { env: w.env })).code, 'not-adopted');
    assert.equal(spy.calls.length, 0);
    assert.equal(w.owner(a.doc), a.token);
  });

  test('the verify child gets fixed argv and a finite environment, and its output is never relayed', async () => {
    const { loadStartup, checkAdopted, finishAttempt } = await load();
    const w = world();
    const a = w.attempt();
    const startup = loadStartup(a.startupPath);
    const log = join(w.root, 'child.log');
    const stub = join(w.root, 'stub-session.sh');
    writeFileSync(stub, `#!/usr/bin/env bash\nprintf 'argv:%s|' "$@" >> '${log}'\nenv | sort >> '${log}'\necho "stub-stdout-${TOKEN}"; echo "stub-stderr-${TOKEN}" >&2\nexit 0\n`, { mode: 0o755 });
    const ambient = { ...w.env, JIRA_API_TOKEN: TOKEN_SENTINEL_ENV, JIRA_EMAIL: EMAIL, ANTHROPIC_API_KEY: TOKEN_SENTINEL_ENV, WORKER_SESSION_ID: 'x' };
    const ok = await checkAdopted(startup, { env: ambient, sessionTool: stub });
    assert.deepEqual(ok, { ok: true });
    const fin = await finishAttempt(startup, { env: ambient, sessionTool: stub });
    assert.equal(fin.ok, true);
    const text = readFileSync(log, 'utf8');
    assert.match(text, new RegExp(`argv:verify\\|argv:${a.dir.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\|`));
    assert.match(text, new RegExp(`argv:finish\\|argv:${a.dir.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\|`));
    assert.ok(!text.includes(TOKEN_SENTINEL_ENV) && !text.includes(EMAIL), 'an ambient credential reached the session child');
    assert.ok(!/^JIRA_|^ANTHROPIC_|^WORKER_SESSION/m.test(text), 'a secret-bearing variable reached the session child');
    noToken([ok, fin], TOKEN);
    assert.ok(!JSON.stringify([ok, fin]).includes('stub-stdout'), 'child output was relayed');
  });

  test('R2-1: the verify child gets exactly one CLAUDE_PROJECT_DIR, this checkout\'s root from the adapter\'s own location, whatever the caller, the ambient environment or the startup config say', async () => {
    const { loadStartup, checkAdopted, finishAttempt } = await load();
    const w = world();
    const a = w.attempt();
    const cur = JSON.parse(readFileSync(a.startupPath, 'utf8'));
    writeFileSync(a.startupPath, JSON.stringify({ ...cur, project_dir: '/config/decoy', CLAUDE_PROJECT_DIR: '/config/decoy-too' }), { mode: 0o600 });
    const startup = loadStartup(a.startupPath);
    const log = join(w.root, 'child-env.log');
    const stub = join(w.root, 'stub-env.sh');
    writeFileSync(stub, `#!/usr/bin/env bash\nenv | sort > '${log}'\nexit 0\n`, { mode: 0o755 });
    for (const env of [{ ...w.env, CLAUDE_PROJECT_DIR: '/ambient/decoy', CLAUDE_CODE_SESSION_ID: 'x' }, { PATH: w.env.PATH, HOME: w.env.HOME }]) {
      for (const run of [(d) => checkAdopted(startup, d), (d) => finishAttempt(startup, d)]) {
        rmSync(log, { force: true });
        assert.equal((await run({ env, sessionTool: stub })).ok, true);
        const lines = readFileSync(log, 'utf8').split('\n').filter((l) => l !== '');
        assert.deepEqual(lines.filter((l) => /^CLAUDE_/.test(l)), [`CLAUDE_PROJECT_DIR=${realpathSync(PROJECT_ROOT)}`], 'exactly one project root, the checkout\'s own');
        assert.deepEqual(lines.map((l) => l.split('=')[0]).filter((k) => !['PWD', 'SHLVL', '_', 'OLDPWD'].includes(k)).sort(), ['CLAUDE_PROJECT_DIR', 'HOME', 'PATH'], 'nothing else reaches the child');
      }
    }
  });

  test('R2-1: the session script binds its queue library to the project root: the checkout root adopts in the project layout and in the plugin layout; a missing, empty, relative or decoy root adopts nothing and the decoy library is never sourced', async () => {
    const { loadStartup, checkAdopted, guardedLabel, finishAttempt } = await load();
    const w = world();
    const canary = join(w.root, 'decoy-sourced');
    const decoy = join(w.root, 'decoy-project');
    mkdirSync(join(decoy, 'scripts', 'handover'), { recursive: true });
    writeFileSync(join(decoy, 'scripts', 'handover', 'queue-lock.sh'), `touch '${canary}'\n`);
    for (const [label, opts] of [
      ['project layout, missing root', { projectDir: null }],
      ['project layout, empty root', { projectDir: '' }],
      ['project layout, relative root that names the checkout from the cwd', { projectDir: '.', cwd: PROJECT_ROOT }],
      ['project layout, decoy root', { projectDir: decoy }],
      ['plugin layout, missing root', { tool: PLUGIN_SESSION, projectDir: null }],
      ['plugin layout, decoy root', { tool: PLUGIN_SESSION, projectDir: decoy }],
    ]) {
      const a = w.attempt();
      const r = w.start(a, opts);
      assert.equal(r.status, 0, label);
      assert.equal(r.stderr.trim(), 'readiness-session: startup-queue-lock', label);
      assert.equal(existsSync(join(a.dir, 'confirmation.json')), false, `${label}: nothing is confirmed`);
      assert.equal(existsSync(join(a.dir, 'lease-token')), true, `${label}: the transport is kept`);
      assert.equal(w.owner(a.doc), a.token, `${label}: the lease is still the transported token's`);
      assert.equal(existsSync(canary), false, `${label}: the decoy library was never sourced`);
      assert.equal((await checkAdopted(loadStartup(a.startupPath), { env: w.env })).code, 'not-adopted', label);
    }
    for (const [label, tool] of [['project layout', SESSION], ['plugin layout', PLUGIN_SESSION]]) {
      const a = w.attempt();
      assert.equal(w.start(a, { tool }).stderr, '', `${label}: the checkout root adopts silently`);
      const startup = loadStartup(a.startupPath);
      const spy = spyPort();
      assert.deepEqual(await checkAdopted(startup, { env: w.env, sessionTool: tool }), { ok: true }, label);
      assert.equal((await guardedLabel(startup, spy.port, 'HIMMEL-1', true, SOON(), { env: w.env, sessionTool: tool })).ok, true, label);
      assert.equal(spy.calls.length, 1, `${label}: the act reached the port once`);
      assert.deepEqual(await finishAttempt(startup, { env: w.env, sessionTool: tool }), { ok: true, type: 'finish', key: null, outcome: 'finished', evidence_id: null }, label);
      assert.equal(w.status(a.doc), 'free', `${label}: finish released exactly the adopted lease`);
      assert.equal(existsSync(a.dir), false, `${label}: the attempt is removed`);
    }
    assert.equal(existsSync(canary), false);
  });

  test('a session script that hangs, crashes or is absent is not-adopted', async () => {
    const { loadStartup, checkAdopted, finishAttempt } = await load();
    const w = world();
    const startup = loadStartup(w.attempt().startupPath);
    const hang = join(w.root, 'hang.sh'); writeFileSync(hang, '#!/usr/bin/env bash\nsleep 30\n', { mode: 0o755 });
    const crash = join(w.root, 'crash.sh'); writeFileSync(crash, '#!/usr/bin/env bash\nkill -SEGV $$\n', { mode: 0o755 });
    assert.equal((await checkAdopted(startup, { env: w.env, sessionTool: hang, timeoutMs: 300 })).code, 'not-adopted');
    assert.equal((await checkAdopted(startup, { env: w.env, sessionTool: crash })).code, 'not-adopted');
    assert.equal((await finishAttempt(startup, { env: w.env, sessionTool: join(w.root, 'absent.sh') })).code, 'not-adopted');
  });
});

// ---------------------------------------------------------------------------------------------------
// C0 envelope (C0s cycle 5): the minimal MCP STDIO envelope, driven through the ACTUAL generated configuration.
//
// Every world below runs the REAL headed-arm-worker.sh --profile readiness in its contained fixture mode (a recording
// exec target stands in for konsole and claude: no native binary, provider, network, real queue or credential). The
// launcher mints the session id and writes the private startup config, the strict MCP config and the on-behalf lease; the
// real SessionStart hook adopts it. Every protocol row then spawns the adapter with exactly the command and argv that the
// GENERATED strict MCP config names. Nothing here hand-assembles that config. A setup failure throws SETUP-UNAVAILABLE and
// is never a causal RED: only a server that does not answer is.
// Every launch passes a Claude Code marker beside seams, which the seam guard refuses on a primary checkout with no claude ancestor
// (a CI checkout is one). The launcher runs from TREE, a copy of the scripts tree that is not one: its launcher, adapter and seam
// guard are COPIES of the real files (the same bytes), every other entry is a symlink, and scripts/lib is a real directory of
// symlinks, because the guard resolves its root from its own lib directory. The adapter derives the project root its session hook
// binds the queue library to from where it lives, and the launcher writes its own queue-lock path into the startup config, so both
// are the tree's: TREE is the project root the adoption rows give the hook.
const TREE = realpathSync(mkdtempSync(join(tmpdir(), 'c0env-tree-')));
roots.push(TREE);
{
  const kit = join(TREE, 'scripts', 'handover', 'chief-kit');
  const real = (...p) => join(PROJECT_ROOT, ...p);
  const entries = (dir) => readdirSync(real(...dir)).filter((name) => !name.startsWith('.'));
  mkdirSync(kit, { recursive: true });
  mkdirSync(join(TREE, 'scripts', 'lib'));
  const link = (dir, skip = []) => { for (const name of entries(dir).filter((n) => !skip.includes(n))) symlinkSync(real(...dir, name), join(TREE, ...dir, name)); };
  link([], ['scripts']);
  link(['scripts'], ['handover', 'lib']);
  link(['scripts', 'handover'], ['chief-kit']);
  link(['scripts', 'handover', 'chief-kit'], ['headed-arm-worker.sh', 'readiness-tools.mjs']);
  link(['scripts', 'lib'], ['chokepoint-seam-guard.sh']);
  for (const file of ['scripts/handover/chief-kit/headed-arm-worker.sh', 'scripts/handover/chief-kit/readiness-tools.mjs', 'scripts/lib/chokepoint-seam-guard.sh']) copyFileSync(real(file), join(TREE, file));
}
const LAUNCHER = join(TREE, 'scripts', 'handover', 'chief-kit', 'headed-arm-worker.sh');
// the adapter copy beside that launcher, for the rows that run an adoption check in this process
const loadLaunched = () => import(pathToFileURL(join(TREE, 'scripts', 'handover', 'chief-kit', 'readiness-tools.mjs')).href);
const SESSION_HOOK = join(HERE, '..', '..', 'hooks', 'readiness-session.sh');
const QL_SH = join(HERE, '..', 'queue-lock.sh');
const PROFILES_MJS = join(HERE, '..', '..', 'lanes', 'plugin-profiles.mjs');
const ADAPTERS_JSON = join(HERE, '..', '..', 'guardrails', 'himmel-adapters.json');
const sha256 = (buf) => createHash('sha256').update(buf).digest('hex');
const ENV_NAME = 'PROJ-9999-c0env';
const ENV_KEY = 'HIMMEL-1';

function gitIn(cwd, args) {
  return execFileSync('git', ['-C', cwd, '-c', 'user.name=fixture', '-c', 'user.email=fixture@example.invalid', '-c', 'commit.gpgsign=false', ...args], {
    env: { PATH: process.env.PATH, HOME: cwd, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_SYSTEM: '/dev/null' }, encoding: 'utf8',
  }).trim();
}

const PINNED_TEXT = 'pinned blob content, version 1\nline two\n';
const ISSUE_TEXT = `${JSON.stringify({ key: ENV_KEY, summary: 'a copied fixture ticket', status: 'Open', labels: [] })}\n`;

// generatedWorld: one real launch (copy port by default). { catalog: false } omits the host catalog seam;
// { port: 'jira' } selects the jira port against a fake primary client with fake credentials.
function generatedWorld({ catalog = true, port = 'copy', extraEnv = {}, allowRefusal = false } = {}) {
  const rs = realpathSync(mkdtempSync(join(tmpdir(), 'c0env-')));
  roots.push(rs);
  for (const d of ['hdir/u/r', 'home/.claude', 'repo', 'bin', 'state', 'evidence', 'srcrepo']) mkdirSync(join(rs, d), { recursive: true });
  const xdg = join(rs, 'xdg');
  mkdirSync(xdg, { mode: 0o700 });
  chmodSync(xdg, 0o700);
  const home = join(rs, 'home');
  writeFileSync(join(rs, '.himmel-readiness-fixture'), 'himmel-readiness-fixture-v1', { mode: 0o600 });
  const exe = (path, text) => { writeFileSync(path, text, { mode: 0o755 }); chmodSync(path, 0o755); };
  exe(join(rs, 'bin', 'claude'), '#!/usr/bin/env bash\nexit 0\n');
  exe(join(rs, 'preflight.sh'), '#!/usr/bin/env bash\necho PROCEED\n');
  exe(join(rs, 'waker.sh'), '#!/usr/bin/env bash\nexit 0\n');
  exe(join(rs, 'target.sh'), `#!/usr/bin/env bash\nprintf '%s\\n' "$*" >> '${rs}/target-record'\nenv | grep -E '^HEADED_ARM_LAUNCHER_ENV=' >> '${rs}/target-env' || true\nprintf 'launched\\n' > "\${HEADED_ARM_OUTCOME_FILE:-/dev/null}"\n`);
  writeFileSync(join(home, '.claude', 'settings.json'), '{"hooks":{"PostToolUse":[{"hooks":[{"type":"command","command":"bash scripts/handover/queue-lock.sh self-heartbeat"}]}]}}\n');
  const doc = join(rs, 'hdir', 'u', 'r', 'readiness-v1.1.0.md');
  writeFileSync(doc, ['---', 'description: fixture brief', '---', '> **Prior art:** none found (qmd -c jira-himmel "fixture")', '', '# readiness v1.1.0 fixture', ''].join('\n'));

  // the host-admitted pinned blob: one tracked file at a pinned commit, then a different worktree copy on disk
  const src = join(rs, 'srcrepo');
  gitIn(src, ['init', '-q']);
  mkdirSync(join(src, 'docs'));
  writeFileSync(join(src, 'docs', 'pinned.md'), PINNED_TEXT);
  symlinkSync('pinned.md', join(src, 'docs', 'link.md'));
  gitIn(src, ['add', '-A']);
  gitIn(src, ['commit', '-q', '-m', 'pin']);
  const head = gitIn(src, ['rev-parse', 'HEAD']);
  const oid = gitIn(src, ['rev-parse', 'HEAD:docs/pinned.md']);
  const linkOid = gitIn(src, ['rev-parse', 'HEAD:docs/link.md']);
  writeFileSync(join(src, 'docs', 'pinned.md'), 'WORKTREE-COPY-THAT-MUST-NEVER-BE-READ\n');
  writeFileSync(join(rs, 'evidence', 'issue-1.json'), ISSUE_TEXT);
  const catalogDoc = {
    source_head: head,
    roots: { repo: src, evidence: join(rs, 'evidence') },
    catalog: [
      { id: 'blob.pinned', kind: 'blob', path: 'docs/pinned.md', oid, mode: '100644', size: Buffer.byteLength(PINNED_TEXT), sha256: sha256(PINNED_TEXT), purpose: 'pinned source excerpt' },
      { id: 'issue.copied', kind: 'issue', key: ENV_KEY, file: 'issue-1.json', size: Buffer.byteLength(ISSUE_TEXT), sha256: sha256(ISSUE_TEXT), purpose: 'copied issue' },
    ],
  };
  const catalogPath = join(rs, 'catalog.json');
  writeFileSync(catalogPath, JSON.stringify(catalogDoc), { mode: 0o600 });
  chmodSync(catalogPath, 0o600);

  const CRED_SENTINEL = 'c0env-fake-credential-9e1d77a0';
  let fakeCli = '';
  if (port === 'jira') {
    const dist = join(rs, 'primary', 'scripts', 'jira', 'dist');
    mkdirSync(dist, { recursive: true });
    fakeCli = join(dist, 'index.js');
    writeFileSync(fakeCli, '// fake primary CLI: this suite must never run it\n');
    writeFileSync(join(dist, 'client.js'), `export const baseUrl = () => 'http://127.0.0.1:9';\nexport const projectKey = () => 'FIXT';\nexport function authHeader() { return 'Basic ' + Buffer.from('fixture@example.invalid:${CRED_SENTINEL}').toString('base64'); }\n`);
  }
  const state = (n) => join(rs, 'state', n);
  const launchEnv = {
    PATH: `${join(rs, 'bin')}:${process.env.PATH}`, HOME: home, CLAUDE_CONFIG_DIR: join(home, '.claude'), XDG_RUNTIME_DIR: xdg, HANDOVER_DIR: join(rs, 'hdir'),
    TMPDIR: state('tmp'), LANG: 'C.UTF-8', TERM: 'dumb', USER: 'nobody',
    HEADED_ARM_UNAME: 'Linux', UNGUARDED_LAUNCH_OK: '1', HIMMEL_FLEET_SLOTS: state('slots'), HIMMELCTL_CACHE_DIR: state('cache'), HIMMEL_CONFIG_DIR: state('config'),
    HIMMEL_POLICY_FOLLOWS_HOME: '1', HIMMEL_DENIAL_ACK_DIR: state('acks'), WORKER_SESSION_PRETRUST_HOME: state('pretrust'),
    HEADED_ARM_WORKER_PROFILES: PROFILES_MJS, PLUGIN_PROFILES_ADAPTERS: ADAPTERS_JSON,
    CLAUDE_CODE_SESSION_ID: 'launcher-scope-1', HEADED_ARM_WORKER_CLAUDE_BIN: join(rs, 'bin', 'claude'), HEADED_ARM_WORKER_TARGET: join(rs, 'target.sh'), HEADED_ARM_WORKER_PREFLIGHT: join(rs, 'preflight.sh'),
    KONSOLE_CMD: join(rs, 'konsole'), PGREP_CMD: join(rs, 'pgrep'), WORKER_SESSION_REPO: join(rs, 'repo'), HEADED_ARM_LOCK_DIR: state('locks'), HEADED_ARM_PROC: state('proc'),
    HEADED_ARM_WORKER_WAKER: join(rs, 'waker.sh'), WORKER_SESSION_READINESS_FIXTURE: rs,
    ...(catalog ? { WORKER_SESSION_READINESS_CATALOG: catalogPath } : {}),
    ...(port === 'jira' ? { WORKER_SESSION_READINESS_PORT: 'jira', WORKER_SESSION_READINESS_PRIMARY_CLI: fakeCli } : {}),
    ...extraEnv,
  };
  mkdirSync(state('tmp'), { recursive: true });
  const past = Math.floor(Date.now() / 1000) - 100;
  const run = spawnSync('bash', [LAUNCHER, '--profile', 'readiness', ENV_NAME, doc, join(rs, 'signal-never'), String(past), join(rs, 'log'), 'claude-sonnet-5-5'], { env: launchEnv, encoding: 'utf8', timeout: 120000 });
  if (run.status !== 0 && !allowRefusal) throw new Error(`SETUP-UNAVAILABLE: the real launcher refused the fixture launch (rc ${run.status}): ${String(run.stdout).slice(-600)} ${String(run.stderr).slice(-600)}`);
  const base = join(xdg, 'himmel-readiness');
  const sids = existsSync(base) ? readdirSync(base) : [];
  const sid = sids[0];
  const attempt = sid ? join(base, sid) : null;
  const qenv = { PATH: process.env.PATH, HOME: home, XDG_RUNTIME_DIR: xdg, HANDOVER_DIR: join(rs, 'hdir') };
  const ql = (verb, ...args) => spawnSync('bash', [QL_SH, verb, ...args], { env: qenv, encoding: 'utf8' });
  const w = {
    rs, home, sid, attempt, doc, head, oid, linkOid, catalogDoc, catalogPath, run, launchEnv, qenv, CRED_SENTINEL, src,
    startupPath: attempt ? join(attempt, 'startup.json') : null,
    mcpPath: attempt ? join(attempt, 'leg-mcp.json') : null,
    token: attempt && existsSync(join(attempt, 'lease-token')) ? readFileSync(join(attempt, 'lease-token'), 'utf8').trim() : null,
    status: () => ql('status', doc).stdout.trim().split('\n').pop(),
    owner: () => { const m = /"session":"([^"]+)"/.exec(ql('status', doc).stdout); return m ? m[1] : null; },
    drop: (token) => ql('release', doc, token),
    hold: (token) => ql('acquire', doc, token),
    adopt() {
      const transcript = join(home, 'projects', 'p', `${sid}.jsonl`);
      mkdirSync(dirname(transcript), { recursive: true });
      writeFileSync(transcript, '');
      return spawnSync('bash', [SESSION_HOOK, 'startup'], {
        input: JSON.stringify({ session_id: sid, hook_event_name: 'SessionStart', source: 'startup', transcript_path: transcript }),
        env: { ...qenv, CLAUDE_CODE_SESSION_ID: sid, CLAUDE_PROJECT_DIR: TREE }, encoding: 'utf8',
      });
    },
    // the server exactly as the GENERATED strict MCP config starts it
    generated: () => JSON.parse(readFileSync(w.mcpPath, 'utf8')).mcpServers.readiness,
    client: () => {
      const g = w.generated();
      return new McpClient(g.command, g.args, { PATH: process.env.PATH, HOME: home });
    },
  };
  return w;
}

// A minimal newline-delimited JSON-RPC 2.0 client over a child process's stdio: the harness for every protocol row.
class McpClient {
  constructor(command, args, env) {
    this.child = spawn(command, args, { env, stdio: ['pipe', 'pipe', 'pipe'] });
    this.msgs = [];
    this.lines = [];
    this.stderr = '';
    this.exit = null;
    this.n = 0;
    this.pending = [];
    let buf = '';
    this.child.stdout.setEncoding('utf8');
    this.child.stdout.on('data', (d) => {
      buf += d;
      for (let i = buf.indexOf('\n'); i >= 0; i = buf.indexOf('\n')) {
        const line = buf.slice(0, i);
        buf = buf.slice(i + 1);
        this.lines.push(line);
        try { this.msgs.push(JSON.parse(line)); } catch { this.msgs.push({ __notJson: line }); }
        this.#wake();
      }
    });
    this.child.stderr.setEncoding('utf8');
    this.child.stderr.on('data', (d) => { this.stderr += d; });
    this.child.on('exit', (code, signal) => { this.exit = { code, signal }; this.#wake(); });
    this.child.stdin.on('error', () => {});
  }

  #wake() { for (const p of this.pending.splice(0)) p(); }

  raw(text) { this.child.stdin.write(`${text}\n`); }

  send(obj) { this.raw(JSON.stringify(obj)); }

  async until(find, label, ms = 20000) {
    const deadline = Date.now() + ms;
    for (;;) {
      const hit = this.msgs.find(find);
      if (hit) return hit;
      if (this.exit) throw new Error(`server closed before answering ${label} (exit ${JSON.stringify(this.exit)}; stderr: ${this.stderr.slice(0, 300)})`);
      if (Date.now() > deadline) throw new Error(`no answer to ${label} within ${ms} ms`);
      await new Promise((ok) => { this.pending.push(ok); setTimeout(ok, 100); });
    }
  }

  async rpc(method, params) {
    this.n += 1;
    const id = this.n;
    this.send({ jsonrpc: '2.0', id, method, ...(params === undefined ? {} : { params }) });
    return this.until((m) => m.id === id, method);
  }

  async init() {
    const r = await this.rpc('initialize', { protocolVersion: '2025-11-25', capabilities: {}, clientInfo: { name: 'c0-envelope-test', version: '0' } });
    this.send({ jsonrpc: '2.0', method: 'notifications/initialized' });
    return r;
  }

  async call(name, args) {
    const r = await this.rpc('tools/call', { name, arguments: args });
    if (r.error) return { rpcError: r.error };
    return { isError: r.result.isError === true, data: JSON.parse(r.result.content[0].text), raw: r.result };
  }

  inspect(id) { return this.call('inspect', { id }); }

  act(args) { return this.call('act', args); }

  // sequential server: once this answers, every line sent before it has been fully processed
  async settle() { await this.rpc('ping'); }

  async close() {
    if (!this.exit) { this.child.stdin.end(); await this.until(() => false, 'exit', 5000).catch(() => {}); }
    if (!this.exit) this.child.kill('SIGKILL');
  }
}

// A compliant minimal server, to prove the HARNESS: if this passes and the adapter's rows fail, the failure is the adapter's
// missing protocol behavior, not the client, the config spawn or the parser.
const COMPLIANT_SERVER = `let b='';process.stdin.setEncoding('utf8');process.stdin.on('data',(d)=>{b+=d;for(let i=b.indexOf('\\n');i>=0;i=b.indexOf('\\n')){const l=b.slice(0,i);b=b.slice(i+1);const m=JSON.parse(l);if(m.id===undefined)continue;const r=m.method==='initialize'?{protocolVersion:'2025-11-25',capabilities:{tools:{}},serverInfo:{name:'control',version:'0'}}:m.method==='tools/list'?{tools:[{name:'inspect'},{name:'act'}]}:{};process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:m.id,result:r})+'\\n');}});`;

const UNSUPPORTED_ACTS = ['preparation-text', 'blocks', 'comment', 'backlog-followup', 'ruling', 'route'];

describe('C0 envelope', () => {
  const clients = [];
  const open = (w) => { const c = w.client(); clients.push(c); return c; };
  after(async () => { for (const c of clients) await c.close(); });
  const tree = (dir) => readdirSync(dir, { recursive: true }).sort();
  // everything an act could have changed besides the copied labels: the private attempt, the evidence dir, the source repo files
  const effects = (w) => JSON.stringify({
    attempt: existsSync(w.attempt) ? tree(w.attempt) : null,
    evidence: tree(join(w.rs, 'evidence')).map((f) => [f, readFileSync(join(w.rs, 'evidence', f), 'utf8')]),
    root: readdirSync(w.rs).sort(),
    lease: w.status(),
    owner: w.owner(),
  });
  const labelsOf = async (c) => (await c.inspect('issue.copied')).data.labels;
  const adapterRun = (args, input) => spawnSync(process.execPath, [join(HERE, 'readiness-tools.mjs'), ...args], { env: { PATH: process.env.PATH, HOME: tmpdir() }, input, encoding: 'utf8', timeout: 20000 });
  const catalogFields = (doc) => JSON.stringify(Object.fromEntries(['source_head', 'roots', 'catalog'].filter((k) => k in doc).map((k) => [k, doc[k]])));

  describe('harness positive control (a compliant server and the generated world)', () => {
    test('the harness completes initialize and tools/list against a compliant server, and says so when a server dies', async () => {
      const good = new McpClient(process.execPath, ['-e', COMPLIANT_SERVER], { PATH: process.env.PATH });
      clients.push(good);
      assert.equal((await good.init()).result.serverInfo.name, 'control');
      assert.deepEqual((await good.rpc('tools/list')).result.tools.map((t) => t.name), ['inspect', 'act']);
      const dead = new McpClient(process.execPath, ['-e', 'process.exit(3)'], { PATH: process.env.PATH });
      clients.push(dead);
      await assert.rejects(dead.rpc('initialize', {}), /server closed before answering initialize/);
    });

    describe('the real launcher\'s output', () => {
      let hw;
      before(() => { hw = generatedWorld(); });

      test('it generated a strict config that starts exactly the adapter on the private startup file, with the lease held on behalf', () => {
        assert.equal(hw.run.status, 0);
        assert.deepEqual(hw.generated(), { command: 'node', args: [join(TREE, 'scripts', 'handover', 'chief-kit', 'readiness-tools.mjs'), '--startup-config', hw.startupPath] });
        assert.equal(statSync(hw.startupPath).mode & 0o777, 0o600);
        assert.equal(hw.status(), 'status: FRESH');
        assert.equal(hw.owner(), hw.token);
        assert.equal(hw.adopt().status, 0);
        assert.equal(existsSync(join(hw.attempt, 'lease-token')), false, 'the transport is deleted at adoption');
      });

      test('the trusted launcher hands the worker the readiness marker, exactly 1', () => {
        const env = readFileSync(join(hw.rs, 'target-env'), 'utf8');
        assert.equal((env.match(/\bHIMMEL_READINESS=1(?=\s|$)/g) ?? []).length, 1, env);
      });
    });
  });

  describe('over the generated config, adopted session', () => {
    let w;
    let c;
    let leakProbe;
    before(() => {
      w = generatedWorld();
      assert.equal(w.adopt().status, 0);
      leakProbe = [w.token, w.attempt, w.startupPath, w.rs, join(w.rs, 'xdg')];
      c = open(w);
    });

    test('initialize answers with the server identity and tools only', async () => {
      const r = await c.init();
      assert.equal(r.result.protocolVersion, '2025-11-25');
      assert.deepEqual(r.result.capabilities, { tools: {} });
      assert.equal(r.result.serverInfo.name, 'readiness');
      assert.equal(typeof r.result.serverInfo.version, 'string');
    });

    test('tools/list advertises exactly inspect and act, closed schemas, and no finish tool', async () => {
      const { tools } = (await c.rpc('tools/list')).result;
      assert.deepEqual(tools.map((t) => t.name), ['inspect', 'act']);
      for (const t of tools) {
        assert.deepEqual(Object.keys(t).sort(), ['description', 'inputSchema', 'name']);
        assert.equal(t.inputSchema.type, 'object');
        assert.equal(t.inputSchema.additionalProperties, false);
      }
      const act = JSON.stringify(tools[1].inputSchema);
      for (const variant of ['label', 'finish']) assert.ok(act.includes(`"${variant}"`), `the act schema names ${variant}`);
    });

    test('inspect returns the one pinned blob from the git object, never the worktree copy', async () => {
      const r = await c.inspect('blob.pinned');
      assert.equal(r.isError, false);
      assert.deepEqual({ ...r.data }, { ok: true, id: 'blob.pinned', kind: 'blob', path: 'docs/pinned.md', size: Buffer.byteLength(PINNED_TEXT), sha256: sha256(PINNED_TEXT), content: PINNED_TEXT });
    });

    test('inspect returns the one copied issue with its current labels', async () => {
      const r = await c.inspect('issue.copied');
      assert.equal(r.isError, false);
      assert.deepEqual({ ...r.data }, { ok: true, id: 'issue.copied', kind: 'issue', key: ENV_KEY, size: Buffer.byteLength(ISSUE_TEXT), sha256: sha256(ISSUE_TEXT), content: ISSUE_TEXT, labels: [], labels_source: 'copy' });
    });

    test('inspect refuses every id that is not exactly an admitted catalog id: no path, URL, wildcard, config or credential resource', async () => {
      const canary = join(w.rs, 'canary.txt');
      writeFileSync(canary, 'CANARY-SECRET-CONTENT');
      const ids = ['nope', '', ' blob.pinned', 'BLOB.PINNED', 'blob.pinned ', 'blob.pinned\n', 'docs/pinned.md', canary, `file://${canary}`, 'http://127.0.0.1:9/x',
        '../evidence/issue-1.json', '*', 'blob.*', 'credentials', 'credentials.json', 'startup', 'startup.json', 'lease-token', 'config', w.startupPath, w.token, 'issue.copied/../blob.pinned', 'constructor', '__proto__', 'toString'];
      for (const id of ids) {
        const r = await c.inspect(id);
        assert.equal(r.isError, true, JSON.stringify(id));
        assert.equal(r.data.ok, false);
        assert.equal(r.data.code, 'unadmitted', JSON.stringify(id));
        assert.ok(!JSON.stringify(r).includes('CANARY') && !JSON.stringify(r).includes(canary), 'no input is echoed and no file is read');
      }
      for (const bad of [{}, { id: 7 }, { id: null }, { id: ['blob.pinned'] }, { id: { id: 'blob.pinned' } }, { id: 'blob.pinned', path: canary }, { id: 'blob.pinned', extra: 1 }, { path: canary }]) {
        const r = await c.call('inspect', bad);
        assert.equal(r.isError, true, JSON.stringify(bad));
        assert.equal(r.data.code, 'bad-request', JSON.stringify(bad));
      }
      for (const notObject of [null, 'blob.pinned', 7, ['blob.pinned']]) {
        const r = await c.call('inspect', notObject);
        assert.ok(r.rpcError || r.data?.code === 'bad-request', `arguments ${JSON.stringify(notObject)}`);
      }
    });

    test('the copied-label act changes only the copy, verified through inspect, and is idempotent', async () => {
      const on = await c.act({ type: 'label', key: ENV_KEY, present: true });
      assert.deepEqual({ ...on.data }, { ok: true, type: 'label', key: ENV_KEY, outcome: 'updated', evidence_id: null });
      assert.deepEqual(await labelsOf(c), [LABEL]);
      assert.equal((await c.act({ type: 'label', key: ENV_KEY, present: true })).isError, false);
      assert.deepEqual(await labelsOf(c), [LABEL], 'the label is present once');
      const off = await c.act({ type: 'label', key: ENV_KEY, present: false });
      assert.equal(off.isError, false);
      assert.deepEqual(await labelsOf(c), []);
      assert.equal(readFileSync(join(w.rs, 'evidence', 'issue-1.json'), 'utf8'), ISSUE_TEXT, 'the admitted copy file itself is never rewritten');
    });

    test('a label act for any key but the copied issue refuses with zero effects', async () => {
      const before = effects(w);
      for (const key of ['HIMMEL-2', 'OTHER-1', 'HIMMEL-10', 'HIMMEL-1 ']) {
        const r = await c.act({ type: 'label', key, present: true });
        assert.equal(r.isError, true, key);
        assert.ok(['not-in-scope', 'bad-request'].includes(r.data.code), `${key}: ${r.data.code}`);
      }
      assert.deepEqual(await labelsOf(c), []);
      assert.equal(effects(w), before);
    });

    test('malformed or over-broad label and finish requests refuse with zero effects: bad key, bad present, extra fields, forged authority', async () => {
      const before = effects(w);
      const bad = [
        { type: 'label' }, { type: 'label', key: ENV_KEY }, { type: 'label', present: true },
        { type: 'label', key: '', present: true }, { type: 'label', key: 'himmel-1', present: true }, { type: 'label', key: 'HIMMEL-1; rm -rf /', present: true }, { type: 'label', key: 7, present: true },
        { type: 'label', key: ENV_KEY, present: 'true' }, { type: 'label', key: ENV_KEY, present: 1 }, { type: 'label', key: ENV_KEY, present: null },
        { type: 'label', key: ENV_KEY, present: true, label: 'other-label' }, { type: 'label', key: ENV_KEY, present: true, token: w.token },
        { type: 'label', key: ENV_KEY, present: true, force: true }, { type: 'label', key: ENV_KEY, present: true, version: 'v9.9.9' },
        { type: 'label', key: ENV_KEY, present: true, digest: '0'.repeat(64) }, { type: 'label', key: ENV_KEY, present: true, path: '/etc/passwd' },
        { type: 'finish', key: ENV_KEY }, { type: 'finish', token: w.token }, { type: 'finish', force: true }, { type: 'finish', takeover: true },
        {}, { type: 'LABEL', key: ENV_KEY, present: true }, { type: 'label ', key: ENV_KEY, present: true }, { type: 7 }, { type: null }, { type: ['label'] }, { type: 'unknown-action' }, { type: '__proto__' },
      ];
      for (const args of bad) {
        const r = await c.act(args);
        assert.equal(r.isError, true, JSON.stringify(args));
        assert.equal(r.data.code, 'bad-request', JSON.stringify(args));
      }
      for (const notObject of [null, 'label', 7, [], [{ type: 'finish' }]]) {
        const r = await c.call('act', notObject);
        assert.ok(r.rpcError || r.data?.code === 'bad-request', `arguments ${JSON.stringify(notObject)}`);
      }
      assert.equal(effects(w), before, 'no refused request had an effect');
      assert.deepEqual(await labelsOf(c), []);
    });

    test('every unsupported act variant refuses with zero effects, whatever else the request carries', async () => {
      const before = effects(w);
      for (const type of UNSUPPORTED_ACTS) {
        for (const extra of [{}, { key: ENV_KEY, text: 'x' }, { key: ENV_KEY, present: true }]) {
          const r = await c.act({ type, ...extra });
          assert.equal(r.isError, true, type);
          assert.equal(r.data.code, 'unsupported-action', type);
        }
      }
      assert.deepEqual(await labelsOf(c), []);
      assert.equal(effects(w), before, 'no unsupported act touched the lease, the attempt, the evidence or the copy');
    });

    test('an unknown or differently spelled tool is a protocol error with zero effects: finish is an act variant, not a tool', async () => {
      const before = effects(w);
      for (const name of ['finish', 'mcp__readiness__act', 'mcp__readiness__inspect', 'Inspect', 'ACT', 'inspect ', ' act', '', 'read', 'bash', 'Bash', 'shell', 'jira', '__proto__', 'constructor']) {
        const r = await c.call(name, { type: 'finish' });
        assert.ok(r.rpcError, `tool ${JSON.stringify(name)}`);
        assert.equal(r.rpcError.code, -32602, `tool ${JSON.stringify(name)}`);
      }
      for (const name of [null, 7, ['act'], { a: 1 }, true]) {
        const r = await c.rpc('tools/call', { name, arguments: { type: 'finish' } });
        assert.equal(r.error?.code, -32602, `tool ${JSON.stringify(name)}`);
      }
      assert.equal((await c.rpc('tools/call', { arguments: {} })).error?.code, -32602);
      assert.equal(effects(w), before);
      assert.equal(w.status(), 'status: FRESH', 'the lease was not released by any unknown tool');
    });

    test('the protocol is bounded and strict: malformed JSON, batches, bad ids, wrong version, unknown methods, notifications that look like calls', async () => {
      c.raw('{this is not json');
      assert.equal((await c.until((m) => m.error?.code === -32700, 'a parse error')).id, null);
      c.raw('');
      c.raw('   ');
      c.raw(JSON.stringify([{ jsonrpc: '2.0', id: 'raw-91', method: 'ping' }]));
      assert.equal((await c.until((m) => m.error?.code === -32600 && m.id === null, 'a batch refusal')).error.code, -32600);
      const invalidIds = [null, true, { a: 1 }, [1], 1.5, 'x'.repeat(300)];
      for (const id of invalidIds) {
        c.send({ jsonrpc: '2.0', id, method: 'ping' });
      }
      c.send({ id: 'raw-92', method: 'ping' });
      c.send({ jsonrpc: '1.0', id: 'raw-93', method: 'ping' });
      c.send({ jsonrpc: '2.0', id: 'raw-94' });
      c.send({ jsonrpc: '2.0', id: 'raw-95', method: 7 });
      c.send({ jsonrpc: '2.0', id: 'raw-96', method: 'resources/list' });
      c.send({ jsonrpc: '2.0', id: 'raw-97', method: 'tools/call/extra' });
      // a call with no id is a notification: no answer, no effect
      c.send({ jsonrpc: '2.0', method: 'tools/call', params: { name: 'act', arguments: { type: 'label', key: ENV_KEY, present: true } } });
      c.send({ jsonrpc: '2.0', method: 'notifications/unknown', params: {} });
      await c.settle();
      const answered = (id) => c.msgs.find((m) => m.id === id);
      assert.equal(c.msgs.filter((m) => m.error?.code === -32600 && m.id === null).length >= 1 + invalidIds.length, true, 'every invalid id and the batch is refused with id null');
      for (const id of ['raw-92', 'raw-93', 'raw-94', 'raw-95']) assert.equal(answered(id)?.error?.code, -32600, `request ${id}`);
      for (const id of ['raw-96', 'raw-97']) assert.equal(answered(id)?.error?.code, -32601, `request ${id}`);
      assert.equal(answered('raw-91'), undefined, 'the batch ran nothing');
      assert.deepEqual(await labelsOf(c), [], 'a notification that names a tool call has no effect');
    });

    test('no tool runs before initialize, and a second initialize is refused', async () => {
      const early = open(w);
      const before = effects(w);
      for (const [name, args] of [['inspect', { id: 'blob.pinned' }], ['act', { type: 'label', key: ENV_KEY, present: true }], ['act', { type: 'finish' }]]) {
        const r = await early.rpc('tools/call', { name, arguments: args });
        assert.equal(r.error?.code, -32002, `${name} before initialize`);
      }
      assert.equal((await early.rpc('tools/list')).error?.code, -32002);
      assert.equal((await early.rpc('ping')).result !== undefined, true, 'ping is allowed before initialize');
      assert.equal(effects(w), before);
      await early.init();
      assert.equal((await early.rpc('initialize', { protocolVersion: '2025-11-25' })).error?.code, -32600, 'a second initialize');
      assert.equal((await early.rpc('initialize', { protocolVersion: 7 })).error?.code, -32600);
      const other = open(w);
      assert.equal((await other.rpc('initialize', { protocolVersion: 7 })).error?.code, -32602, 'an initialize with no usable version');
      assert.equal((await other.rpc('initialize', { protocolVersion: '1999-01-01' })).result.protocolVersion, '2025-11-25', 'an unknown version is answered with the server\'s own');
    });

    test('an oversize line is refused without being buffered or run, and the session continues', async () => {
      c.raw(JSON.stringify({ jsonrpc: '2.0', id: 'big', method: 'tools/call', params: { name: 'inspect', arguments: { id: 'x'.repeat(400000) } } }));
      await c.until((m) => m.error && /too large/i.test(m.error.message), 'an oversize refusal');
      const r = await c.inspect('blob.pinned');
      assert.equal(r.isError, false);
    });

    test('stdout carries only JSON-RPC, stderr stays empty, and no private value ever reaches the model channel', async () => {
      assert.ok(c.lines.length > 20);
      for (const line of c.lines) {
        const m = JSON.parse(line);
        assert.equal(m.jsonrpc, '2.0');
        assert.ok('result' in m !== 'error' in m, 'exactly one of result and error');
      }
      assert.equal(c.stderr, '', 'a healthy session writes nothing to stderr');
      const everything = c.lines.join('\n');
      for (const secret of leakProbe) assert.ok(!everything.includes(secret), `a private value reached the model channel: ${secret.slice(0, 12)}...`);
    });

    test('adoption is verified afresh by every act: a lost lease stops the very next label and finish, and never releases a successor', async () => {
      assert.equal((await c.act({ type: 'label', key: ENV_KEY, present: true })).isError, false, 'adopted: allowed');
      assert.equal(w.drop(w.owner()).status, 0);
      assert.equal(w.hold('successor-token-c0env1').status, 0);
      const before = effects(w);
      const refused = await c.act({ type: 'label', key: ENV_KEY, present: false });
      assert.equal(refused.isError, true);
      assert.equal(refused.data.code, 'not-adopted');
      const fin = await c.act({ type: 'finish' });
      assert.equal(fin.data.code, 'not-adopted');
      assert.equal(w.owner(), 'successor-token-c0env1', 'finish never releases a successor');
      assert.equal(effects(w), before);
      assert.ok(!JSON.stringify([refused, fin]).includes('successor-token'), 'the successor token is not relayed');
    });
  });

  // R2-6: once adoption is required before inspect, the lost-lease row can no longer read the copied labels back through the
  // server. The copy port itself is the in-memory state and is read directly (not through the adoption gate), so a refused
  // act's zero effect on the copy stays pinned by an oracle independent of the code under test; the adopted twin shows the
  // same oracle does see a real change.
  describe('R2-6: the refused act leaves the in-memory copy as it was (oracle independent of the adoption gate)', () => {
    const setup = async () => {
      const mod = await loadLaunched();
      const w = generatedWorld();
      assert.equal(w.adopt().status, 0);
      const startup = mod.loadStartup(w.startupPath);
      const port = mod.createCopyPort(startup);
      const deps = { env: { PATH: process.env.PATH, HOME: w.home } };
      const act = (present) => mod.guardedLabel(startup, port, ENV_KEY, present, Date.now() + 20000, deps);
      return { mod, w, port, act };
    };

    test('a lost lease: the removal is refused and the copy still holds the label it held before', async () => {
      const { w, port, act } = await setup();
      assert.deepEqual(await port.labelsNow(), []);
      assert.equal((await act(true)).ok, true);
      assert.deepEqual(await port.labelsNow(), [LABEL]);
      assert.equal(w.drop(w.owner()).status, 0);
      assert.equal(w.hold('successor-token-r26').status, 0);
      const before = effects(w);
      const refused = await act(false);
      assert.equal(refused.code, 'not-adopted');
      assert.deepEqual(await port.labelsNow(), [LABEL], 'the refused act did not remove the label from the copy');
      assert.equal(effects(w), before);
      assert.equal(w.owner(), 'successor-token-r26', 'the successor still holds the lease');
    });

    test('the adopted twin: the same removal takes effect, so the oracle does see a change', async () => {
      const { port, act } = await setup();
      assert.equal((await act(true)).ok, true);
      assert.deepEqual(await port.labelsNow(), [LABEL]);
      assert.equal((await act(false)).ok, true);
      assert.deepEqual(await port.labelsNow(), []);
    });
  });

  describe('finish over the generated config', () => {
    test('before adoption every act and finish refuses and the on-behalf lease is untouched; after adoption finish releases exactly it', async () => {
      const w = generatedWorld();
      const c = open(w);
      await c.init();
      const held = effects(w);
      assert.equal((await c.act({ type: 'finish' })).data.code, 'not-adopted');
      assert.equal((await c.act({ type: 'label', key: ENV_KEY, present: true })).data.code, 'not-adopted');
      assert.equal(effects(w), held, 'nothing changed before adoption');
      assert.equal(w.owner(), w.token);
      assert.equal(w.adopt().status, 0);
      const fin = await c.act({ type: 'finish' });
      assert.deepEqual({ ...fin.data }, { ok: true, type: 'finish', key: null, outcome: 'finished', evidence_id: null });
      assert.equal(w.status(), 'free');
      assert.equal(existsSync(w.attempt), false, 'the private attempt directory is removed');
      assert.equal((await c.act({ type: 'finish' })).data.code, 'not-adopted', 'a repeated finish refuses');
      assert.equal((await c.act({ type: 'label', key: ENV_KEY, present: true })).data.code, 'not-adopted', 'nothing is permitted after finish');
      assert.ok(!c.lines.join('\n').includes(w.token), 'the lease token never reached the model channel');
    });
  });

  describe('without a host catalog the generated config admits nothing', () => {
    test('the startup config carries no catalog fields, inspect refuses every id and the label act has no key in scope', async () => {
      const w = generatedWorld({ catalog: false });
      assert.deepEqual(Object.keys(JSON.parse(readFileSync(w.startupPath, 'utf8'))).sort(),
        ['attempt_id', 'doc', 'handover_dir', 'lane', 'model', 'port', 'queue_lock', 'runtime_dir', 'schema', 'session_scope', 'version']);
      assert.equal(w.adopt().status, 0);
      const c = open(w);
      await c.init();
      for (const id of ['blob.pinned', 'issue.copied', 'docs/pinned.md']) assert.equal((await c.inspect(id)).data.code, 'unadmitted', id);
      const r = await c.act({ type: 'label', key: ENV_KEY, present: true });
      assert.equal(r.isError, true);
      assert.equal(r.data.code, 'not-in-scope');
      assert.equal(w.status(), 'status: FRESH');
    });
  });

  describe('the host-admitted catalog binding', () => {
    let w;
    let mod;
    let startup;
    let issuePath;
    before(async () => {
      mod = await load();
      w = generatedWorld();
      startup = mod.loadStartup(w.startupPath);
      issuePath = join(w.rs, 'evidence', 'issue-1.json');
    });
    const restore = () => { rmSync(issuePath, { recursive: true, force: true }); writeFileSync(issuePath, ISSUE_TEXT); };
    const withEntry = (id, patch) => ({ ...startup, catalog: startup.catalog.map((e) => (e.id === id ? { ...e, ...patch } : e)) });
    const code = async (s, id) => { const r = await mod.readCatalogResource(s, id); assert.equal(r.ok, false); assert.ok(!JSON.stringify(r).includes(w.rs), 'a refusal never echoes a path'); return r.code; };

    test('the launcher copied the host catalog into the private startup config and the adapter returns it frozen', () => {
      assert.equal(startup.source_head, w.head);
      assert.deepEqual({ ...startup.roots }, w.catalogDoc.roots);
      assert.deepEqual(startup.catalog.map((e) => ({ ...e })), w.catalogDoc.catalog);
      assert.ok(Object.isFrozen(startup.catalog) && Object.isFrozen(startup.catalog[0]) && Object.isFrozen(startup.roots));
    });

    test('a blob must be exactly the tracked regular file at the pinned commit: wrong oid, mode, path, symlink, head or bytes all refuse', async () => {
      assert.equal((await mod.readCatalogResource(startup, 'blob.pinned')).ok, true);
      // each row carries the OTHER object's size and hash, so only the tree/oid/mode decision can refuse it
      const asLink = { size: Buffer.byteLength('pinned.md'), sha256: sha256('pinned.md') };
      assert.equal(await code(withEntry('blob.pinned', { oid: w.linkOid, ...asLink }), 'blob.pinned'), 'changed', 'an object id that is not the tree entry at the pin');
      assert.equal(await code(withEntry('blob.pinned', { mode: '100755' }), 'blob.pinned'), 'changed', 'a different mode');
      assert.equal(await code(withEntry('blob.pinned', { path: 'docs/absent.md' }), 'blob.pinned'), 'changed', 'a path that is not in the tree');
      assert.equal(await code(withEntry('blob.pinned', { path: 'docs/link.md', oid: w.linkOid, ...asLink }), 'blob.pinned'), 'changed', 'a symlink (mode 120000) is never a regular blob');
      assert.equal(await code({ ...startup, source_head: '0'.repeat(40) }, 'blob.pinned'), 'changed', 'a commit that does not exist');
      assert.equal(await code(withEntry('blob.pinned', { size: PINNED_TEXT.length + 1 }), 'blob.pinned'), 'changed', 'a size the catalog does not match');
      assert.equal(await code(withEntry('blob.pinned', { sha256: '0'.repeat(64) }), 'blob.pinned'), 'changed', 'a hash the catalog does not match');
      assert.equal(await code({ ...startup, roots: { ...startup.roots, repo: join(w.rs, 'not-a-repo') } }, 'blob.pinned'), 'changed', 'a repo root that is not a repository');
    });

    test('X14-4: a tree id (or an annotated tag) as source_head is refused, only a commit is accepted', async () => {
      const treeOid = gitIn(w.src, ['rev-parse', 'HEAD^{tree}']);
      assert.notEqual(treeOid, w.head);
      assert.equal(await code({ ...startup, source_head: treeOid }, 'blob.pinned'), 'changed', 'a tree id resolves the same path but is not a source commit');
      gitIn(w.src, ['tag', '-a', '-m', 'pin', 'x14-4-pin']);
      const tagOid = gitIn(w.src, ['rev-parse', 'x14-4-pin']);
      assert.equal(await code({ ...startup, source_head: tagOid }, 'blob.pinned'), 'changed', 'a tag object peels to the commit but is not one');
      assert.equal((await mod.readCatalogResource({ ...startup, source_head: w.head }, 'blob.pinned')).ok, true, 'control: the commit itself reads');
    });

    test('X14-6: a blob with a byte-order mark returns exactly the bytes it advertises', async () => {
      const repo = realpathSync(mkdtempSync(join(tmpdir(), 'c0bom-')));
      roots.push(repo);
      const bom = Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from('bom text\n')]);
      writeFileSync(join(repo, 'bom.txt'), bom);
      gitIn(repo, ['init', '-q']);
      gitIn(repo, ['add', '-A']);
      gitIn(repo, ['commit', '-q', '-m', 'bom']);
      const entry = { id: 'blob.bom', kind: 'blob', path: 'bom.txt', oid: gitIn(repo, ['rev-parse', 'HEAD:bom.txt']), mode: '100644', size: bom.length, sha256: sha256(bom), purpose: 'a bom file' };
      const r = await mod.readCatalogResource({ source_head: gitIn(repo, ['rev-parse', 'HEAD']), roots: { repo, evidence: join(w.rs, 'evidence') }, catalog: [entry] }, 'blob.bom');
      assert.equal(r.ok, true);
      assert.equal(r.size, bom.length);
      assert.equal(Buffer.byteLength(r.content), r.size, 'the returned text is as long as the advertised size');
      assert.equal(sha256(r.content), r.sha256, 'and hashes to the advertised digest');
      assert.equal(r.content.charCodeAt(0), 0xfeff, 'the byte-order mark is kept');
    });

    test('an id that is not exactly an admitted string is unadmitted, whatever its type', async () => {
      for (const id of [undefined, null, 7, true, {}, [], ['blob.pinned'], 'blob.pinned\0', 'BLOB.PINNED', 'blob', 'blob.pinned.', '__proto__', 'hasOwnProperty']) {
        assert.equal(await code(startup, id), 'unadmitted', JSON.stringify(id));
      }
      assert.equal(await code({ ...startup, catalog: undefined }, 'blob.pinned'), 'unadmitted');
    });

    test('the copied issue must be the plain admitted file: changed bytes, a symlink, a second link, a directory, a missing file or a moved root all refuse', async () => {
      assert.equal((await mod.readCatalogResource(startup, 'issue.copied')).ok, true);
      writeFileSync(issuePath, ISSUE_TEXT.replace('Open', 'Done')); // the same size, other bytes
      assert.equal(await code(startup, 'issue.copied'), 'changed', 'edited bytes');
      writeFileSync(issuePath, ISSUE_TEXT.slice(0, 20));
      assert.equal(await code(startup, 'issue.copied'), 'changed', 'truncated');
      restore();
      const real = join(w.rs, 'evidence', 'real.json');
      writeFileSync(real, ISSUE_TEXT);
      rmSync(issuePath);
      symlinkSync(real, issuePath);
      assert.equal(await code(startup, 'issue.copied'), 'changed', 'a symlink, even to identical bytes');
      restore();
      const second = join(w.rs, 'second-link.json');
      linkSync(issuePath, second);
      assert.equal(await code(startup, 'issue.copied'), 'changed', 'a hard-linked file');
      rmSync(second);
      restore();
      rmSync(issuePath);
      mkdirSync(issuePath);
      assert.equal(await code(startup, 'issue.copied'), 'changed', 'a directory');
      rmSync(issuePath, { recursive: true });
      assert.equal(await code(startup, 'issue.copied'), 'changed', 'a missing file');
      restore();
      const moved = join(w.rs, 'evidence-link');
      symlinkSync(join(w.rs, 'evidence'), moved);
      assert.equal(await code({ ...startup, roots: { ...startup.roots, evidence: moved } }, 'issue.copied'), 'changed', 'an evidence root that is a symlink');
      rmSync(moved);
      writeFileSync(issuePath, ISSUE_TEXT.replace(ENV_KEY, 'HIMMEL-2'));
      assert.equal(await code({ ...startup, catalog: startup.catalog.map((e) => (e.id === 'issue.copied' ? { ...e, sha256: sha256(readFileSync(issuePath)), size: readFileSync(issuePath).length } : e)) }, 'issue.copied'), 'changed', 'a copy whose key is not the catalog key');
      restore();
      writeFileSync(issuePath, `${JSON.stringify({ key: ENV_KEY, labels: [7] })}\n`);
      assert.equal(await code({ ...startup, catalog: startup.catalog.map((e) => (e.id === 'issue.copied' ? { ...e, sha256: sha256(readFileSync(issuePath)), size: readFileSync(issuePath).length } : e)) }, 'issue.copied'), 'changed', 'a copy whose labels are not strings');
      restore();
      assert.equal((await mod.readCatalogResource(startup, 'issue.copied')).ok, true, 'the restored copy reads again');
    });

    test('the running server notices a changed resource on the very next inspect', async () => {
      assert.equal(w.adopt().status, 0, 'inspect needs an adopted session');
      const c = open(w);
      await c.init();
      assert.equal((await c.inspect('issue.copied')).isError, false);
      writeFileSync(issuePath, ISSUE_TEXT.replace('Open', 'Done'));
      const changed = await c.inspect('issue.copied');
      assert.equal(changed.isError, true);
      assert.equal(changed.data.code, 'changed');
      restore();
      assert.equal((await c.inspect('issue.copied')).isError, false);
    });

    test('loadStartup refuses every malformed catalog: nothing partial is ever served', async () => {
      const w2 = generatedWorld();
      const good = JSON.parse(readFileSync(w2.startupPath, 'utf8'));
      const blob = good.catalog[0];
      const issue = good.catalog[1];
      const v = (patch) => ({ ...good, ...patch });
      const cases = {
        'only one of the three fields': (() => { const g = { ...good }; delete g.roots; return g; })(),
        'a short head': v({ source_head: w2.head.slice(0, 39) }),
        'an uppercase head': v({ source_head: w2.head.toUpperCase() }),
        'a head with a ref in it': v({ source_head: 'HEAD' }),
        'roots with a third key': v({ roots: { ...good.roots, home: '/home' } }),
        'a relative repo root': v({ roots: { ...good.roots, repo: 'srcrepo' } }),
        'a traversing evidence root': v({ roots: { ...good.roots, evidence: `${good.roots.evidence}/../x` } }),
        'roots that are a list': v({ roots: [good.roots.repo, good.roots.evidence] }),
        'a catalog that is not a list': v({ catalog: { a: 1 } }),
        'nine entries': v({ catalog: Array.from({ length: 9 }, (_, i) => ({ ...blob, id: `blob.n${i}` })) }),
        'a duplicate id': v({ catalog: [blob, { ...issue, id: blob.id }] }),
        'an uppercase id': v({ catalog: [{ ...blob, id: 'Blob.pinned' }, issue] }),
        'an id that starts with a digit': v({ catalog: [{ ...blob, id: '1blob' }, issue] }),
        'an id of 65 characters': v({ catalog: [{ ...blob, id: `a${'b'.repeat(64)}` }, issue] }),
        'an unknown kind': v({ catalog: [{ ...blob, kind: 'url' }, issue] }),
        'a blob with an extra field': v({ catalog: [{ ...blob, url: 'http://x' }, issue] }),
        'a blob with a symlink mode': v({ catalog: [{ ...blob, mode: '120000' }, issue] }),
        'a blob with a group-writable mode': v({ catalog: [{ ...blob, mode: '100664' }, issue] }),
        'a blob path that is absolute': v({ catalog: [{ ...blob, path: '/etc/passwd' }, issue] }),
        'a blob path with traversal': v({ catalog: [{ ...blob, path: 'docs/../../x' }, issue] }),
        'a blob path with an empty segment': v({ catalog: [{ ...blob, path: 'docs//pinned.md' }, issue] }),
        'a blob path with a trailing slash': v({ catalog: [{ ...blob, path: 'docs/' }, issue] }),
        'a blob path that looks like an option': v({ catalog: [{ ...blob, path: '-rf' }, issue] }),
        'a blob path of 201 characters': v({ catalog: [{ ...blob, path: 'a'.repeat(201) }, issue] }),
        'a short oid': v({ catalog: [{ ...blob, oid: blob.oid.slice(0, 39) }, issue] }),
        'a short digest': v({ catalog: [{ ...blob, sha256: 'ab' }, issue] }),
        'a negative size': v({ catalog: [{ ...blob, size: -1 }, issue] }),
        'a size over the per-request limit': v({ catalog: [{ ...blob, size: 65537 }, issue] }),
        'a fractional size': v({ catalog: [{ ...blob, size: 1.5 }, issue] }),
        'an empty purpose': v({ catalog: [{ ...blob, purpose: '' }, issue] }),
        'a purpose with a control character': v({ catalog: [{ ...blob, purpose: 'a\nb' }, issue] }),
        'an issue with an extra field': v({ catalog: [blob, { ...issue, path: '/etc/passwd' }] }),
        'an issue file with a slash': v({ catalog: [blob, { ...issue, file: 'sub/issue-1.json' }] }),
        'an issue file named ..': v({ catalog: [blob, { ...issue, file: '..' }] }),
        'a lowercase issue key': v({ catalog: [blob, { ...issue, key: 'himmel-1' }] }),
        'two copied issues': v({ catalog: [blob, issue, { ...issue, id: 'issue.second' }] }),
      };
      assert.equal(adapterRun(['--check-catalog'], catalogFields(good)).status, 0, 'the generated catalog passes the host pre-check too');
      for (const [label, doc] of Object.entries(cases)) {
        writeFileSync(w2.startupPath, JSON.stringify(doc), { mode: 0o600 });
        assert.throws(() => mod.loadStartup(w2.startupPath), (e) => e.code === 'malformed' && !e.message.includes(w2.rs), label);
        // the host pre-check is the SAME validator over the same three fields: it refuses everything the server would
        const viaCli = adapterRun(['--check-catalog'], catalogFields(doc));
        assert.equal(viaCli.status, 2, `${label}: the host pre-check refuses it too`);
        assert.equal(viaCli.stdout, '', label);
        assert.equal(viaCli.stderr, 'readiness-tools: check-catalog: malformed\n', label);
      }
      // the same file with the catalog removed is a valid, empty envelope
      const bare = { ...good };
      for (const k of ['source_head', 'roots', 'catalog']) delete bare[k];
      writeFileSync(w2.startupPath, JSON.stringify(bare), { mode: 0o600 });
      const s = mod.loadStartup(w2.startupPath);
      assert.equal('catalog' in s, false);
      assert.equal(adapterRun(['--check-catalog'], catalogFields(bare)).status, 2, 'a host catalog document must carry all three fields');
    });
  });

  describe('the adapter command line', () => {
    const run = (args) => spawnSync(process.execPath, [join(HERE, 'readiness-tools.mjs'), ...args], { env: { PATH: process.env.PATH, HOME: tmpdir() }, encoding: 'utf8', timeout: 20000 });

    test('only the exact generated shape serves; every other shape is a usage error that writes nothing to stdout', () => {
      const w = generatedWorld({ catalog: false });
      for (const args of [[], ['--startup-config'], ['--startup-config', w.startupPath, 'extra'], ['--serve', w.startupPath], ['--startup-config=' + w.startupPath], [w.startupPath], ['init-credentials']]) {
        const r = run(args);
        assert.equal(r.status, 2, JSON.stringify(args));
        assert.equal(r.stdout, '', JSON.stringify(args));
        assert.match(r.stderr, /usage: readiness-tools\.mjs/);
      }
    });

    test('a startup config that is not the private bound file refuses with a fixed code and no stdout, naming no path', () => {
      const w = generatedWorld();
      const cases = [['a relative path', 'attempt/startup.json'], ['a missing file', join(w.rs, 'nowhere', 'startup.json')], ['another file name', join(w.attempt, 'other.json')]];
      for (const [label, path] of cases) {
        const r = run(['--startup-config', path]);
        assert.equal(r.status, 2, label);
        assert.equal(r.stdout, '', label);
        assert.match(r.stderr, /^readiness-tools: serve: [a-z-]+\n$/, label);
        assert.ok(!r.stderr.includes(w.rs), label);
      }
      chmodSync(w.startupPath, 0o644);
      const loose = run(['--startup-config', w.startupPath]);
      assert.equal(loose.status, 2);
      assert.equal(loose.stdout, '');
      assert.ok(!loose.stderr.includes(w.rs));
    });

    test('a closed stdin ends the session cleanly with exit 0 and nothing on stdout', () => {
      const w = generatedWorld();
      const g = w.generated();
      const r = spawnSync(g.command, g.args, { env: { PATH: process.env.PATH, HOME: w.home }, input: '', encoding: 'utf8', timeout: 20000 });
      assert.equal(r.status, 0);
      assert.equal(r.stdout, '');
      assert.equal(r.stderr, '');
    });
  });

  describe('the jira port is not served by this envelope', () => {
    test('a generated jira-port config answers the protocol but a label act refuses before any credential is read, and nothing private reaches the model', async () => {
      const w = generatedWorld({ port: 'jira' });
      assert.equal(JSON.parse(readFileSync(w.startupPath, 'utf8')).port.kind, 'jira');
      const credPath = join(w.attempt, 'credentials.json');
      assert.ok(existsSync(credPath), 'the launcher published the private credential file');
      const credBefore = readFileSync(credPath, 'utf8');
      assert.ok(credBefore.includes(w.CRED_SENTINEL));
      assert.equal(w.adopt().status, 0);
      const c = open(w);
      await c.init();
      assert.equal((await c.rpc('tools/list')).result.tools.length, 2);
      const r = await c.act({ type: 'label', key: ENV_KEY, present: true });
      assert.equal(r.isError, true);
      assert.equal(r.data.code, 'port-unavailable');
      for (const id of ['credentials', 'credentials.json', credPath, 'jira']) assert.equal((await c.inspect(id)).data.code, 'unadmitted', id);
      assert.equal(readFileSync(credPath, 'utf8'), credBefore);
      const everything = `${c.lines.join('\n')}\n${c.stderr}`;
      for (const f of [...forms(w.CRED_SENTINEL), 'fixture@example.invalid', credPath, w.token]) assert.ok(!everything.includes(f), `private value reached the model channel: ${f.slice(0, 10)}`);
    });
  });

  // ---- the independent review's obligations (cycle 5 F2, F3, F4, F6 and the git child environment) -------------------
  describe('review obligations: copied-label freshness, fresh adoption for inspect, labelled copy state, host catalog pre-check', () => {
    const issueFile = (w) => join(w.rs, 'evidence', 'issue-1.json');
    const adoptedClient = async (w) => { assert.equal(w.adopt().status, 0); const c = open(w); await c.init(); return c; };

    test('F2: every copied-label update re-verifies the admitted issue file: a changed, truncated, missing or swapped file refuses with the copy untouched, and a restored file updates again', async () => {
      const w = generatedWorld();
      const c = await adoptedClient(w);
      assert.equal((await c.act({ type: 'label', key: ENV_KEY, present: true })).data.outcome, 'updated');
      assert.deepEqual(await labelsOf(c), [LABEL]);
      const real = join(w.rs, 'evidence', 'real.json');
      const tampers = {
        'the same size and other bytes': () => writeFileSync(issueFile(w), ISSUE_TEXT.replace('Open', 'Done')),
        truncated: () => writeFileSync(issueFile(w), ISSUE_TEXT.slice(0, 20)),
        missing: () => rmSync(issueFile(w)),
        'a symlink to identical bytes': () => { writeFileSync(real, ISSUE_TEXT); rmSync(issueFile(w)); symlinkSync(real, issueFile(w)); },
      };
      for (const [label, tamper] of Object.entries(tampers)) {
        tamper();
        const before = effects(w);
        const refused = await c.act({ type: 'label', key: ENV_KEY, present: false });
        assert.equal(refused.isError, true, `${label}: the update must refuse`);
        assert.equal(refused.data.code, 'conflict', label);
        assert.equal(effects(w), before, `${label}: a refused update has no effect`);
        rmSync(issueFile(w), { force: true });
        rmSync(real, { force: true });
        writeFileSync(issueFile(w), ISSUE_TEXT);
        assert.deepEqual(await labelsOf(c), [LABEL], `${label}: the refused removal left the copy as it was`);
      }
      assert.equal((await c.act({ type: 'label', key: ENV_KEY, present: false })).data.outcome, 'updated', 'with the admitted file unchanged the update works again');
      assert.deepEqual(await labelsOf(c), []);
    });

    test('F3: inspect needs a fresh adoption: before adoption, after a lost lease and after finish it refuses with zero effects; initialize and tools/list still answer; shape errors stay bad-request', async () => {
      const w = generatedWorld();
      const c = open(w);
      await c.init();
      assert.equal((await c.rpc('tools/list')).result.tools.length, 2, 'protocol negotiation needs no adoption');
      const held = effects(w);
      for (const id of ['blob.pinned', 'issue.copied', 'no-such-id']) {
        const r = await c.inspect(id);
        assert.equal(r.isError, true, id);
        assert.equal(r.data.code, 'not-adopted', `${id}: before adoption`);
      }
      assert.equal((await c.call('inspect', {})).data.code, 'bad-request', 'a malformed request is a bad-request whether or not the session is adopted');
      assert.equal(effects(w), held);
      assert.equal(w.adopt().status, 0);
      assert.equal((await c.inspect('blob.pinned')).isError, false, 'adopted: the very same server now reads');
      assert.equal((await c.inspect('issue.copied')).isError, false);
      assert.equal(w.drop(w.owner()).status, 0);
      assert.equal(w.hold('successor-token-c0f3').status, 0);
      const lost = effects(w);
      for (const id of ['blob.pinned', 'issue.copied']) {
        const r = await c.inspect(id);
        assert.equal(r.data.code, 'not-adopted', `${id}: after the lease was lost`);
        assert.ok(!JSON.stringify(r).includes('successor-token'), 'the successor token is not relayed');
      }
      assert.equal(effects(w), lost);
      assert.equal(w.owner(), 'successor-token-c0f3');
      const w2 = generatedWorld();
      const c2 = await adoptedClient(w2);
      assert.equal((await c2.inspect('blob.pinned')).isError, false);
      assert.equal((await c2.act({ type: 'finish' })).data.outcome, 'finished');
      for (const id of ['blob.pinned', 'issue.copied']) assert.equal((await c2.inspect(id)).data.code, 'not-adopted', `${id}: after finish`);
    });

    test('F4: an issue inspect labels the labels as the copy\'s current state while content, size and sha256 stay the admitted file\'s bytes, also after a label update', async () => {
      const w = generatedWorld();
      const c = await adoptedClient(w);
      const tools = (await c.rpc('tools/list')).result.tools;
      const desc = tools.find((t) => t.name === 'inspect').description;
      assert.match(desc, /labels_source/);
      assert.match(desc, /copy/);
      assert.match(desc, /admitted file bytes/);
      assert.equal((await c.inspect('issue.copied')).data.labels_source, 'copy');
      assert.equal((await c.act({ type: 'label', key: ENV_KEY, present: true })).data.outcome, 'updated');
      const after = (await c.inspect('issue.copied')).data;
      assert.deepEqual(
        { labels: after.labels, labels_source: after.labels_source, content: after.content, size: after.size, sha256: after.sha256 },
        { labels: [LABEL], labels_source: 'copy', content: ISSUE_TEXT, size: Buffer.byteLength(ISSUE_TEXT), sha256: sha256(ISSUE_TEXT) },
      );
      assert.deepEqual(JSON.parse(after.content).labels, [], 'the admitted bytes still hold no label: the digest describes the file, not the copy');
      const blob = (await c.inspect('blob.pinned')).data;
      assert.equal('labels' in blob || 'labels_source' in blob, false, 'a blob has no copy state');
    });

    test('F6: the host pre-check reads exactly one catalog document on stdin with the one validator, fixed diagnostics, and takes no path, executable or credential', () => {
      const w = generatedWorld();
      const good = catalogFields(w.catalogDoc);
      const ok = adapterRun(['--check-catalog'], good);
      assert.deepEqual([ok.status, ok.stdout, ok.stderr], [0, '', '']);
      const bad = [
        ['not JSON', 'not json'], ['empty input', ''], ['an array', '[]'], ['a string', '"x"'], ['an empty object', '{}'],
        ['a bad head', JSON.stringify({ ...w.catalogDoc, source_head: 'HEAD' })],
        ['a document over 16 KiB', JSON.stringify({ ...w.catalogDoc, catalog: [], source_head: 'a'.repeat(17000) })],
      ];
      for (const [label, input] of bad) {
        const r = adapterRun(['--check-catalog'], input);
        assert.equal(r.status, 2, label);
        assert.equal(r.stdout, '', label);
        assert.match(r.stderr, /^readiness-tools: check-catalog: (malformed|failed)\n$/, label);
        assert.ok(!r.stderr.includes(w.rs), label);
      }
      for (const args of [['--check-catalog', w.catalogPath], ['--check-catalog', '--startup-config', w.startupPath], ['--check-catalog=x']]) {
        const r = adapterRun(args, good);
        assert.equal(r.status, 2, JSON.stringify(args));
        assert.equal(r.stdout, '', JSON.stringify(args));
        assert.match(r.stderr, /usage: readiness-tools\.mjs/);
      }
      const credBefore = readdirSync(w.attempt).sort();
      adapterRun(['--check-catalog'], good);
      assert.deepEqual(readdirSync(w.attempt).sort(), credBefore, 'the pre-check touches no attempt file');
    });

    test('the fixed git child runs with GIT_NO_LAZY_FETCH=1 on all of its calls', async () => {
      const mod = await load();
      const w = generatedWorld();
      const startup = mod.loadStartup(w.startupPath);
      const bin = join(w.rs, 'gitbin');
      const log = join(w.rs, 'git-env.log');
      mkdirSync(bin);
      const realGit = execFileSync('sh', ['-c', 'command -v git'], { encoding: 'utf8' }).trim();
      writeFileSync(join(bin, 'git'), `#!/bin/sh\nprintf '%s\\n' "\${GIT_NO_LAZY_FETCH-unset}" >> '${log}'\nexec '${realGit}' "$@"\n`, { mode: 0o755 });
      const oldPath = process.env.PATH;
      process.env.PATH = `${bin}:${oldPath}`;
      let r;
      try { r = await mod.readCatalogResource(startup, 'blob.pinned'); } finally { process.env.PATH = oldPath; }
      assert.equal(r.ok, true);
      assert.deepEqual(readFileSync(log, 'utf8').trim().split('\n'), ['1', '1', '1'], 'the commit check, ls-tree and cat-file all ran with lazy fetch disabled');
    });
  });
});

// A harness self-check that is NOT part of the named group: the fixture itself must work, or a RED
// above could be a broken harness rather than a missing product. Separate so it can be run alone.
describe('C0 fixture sanity', () => {
  test('the built primary CLI exists and the scratch layout is mode 0700', () => {
    ensureCliCopy();
    assert.ok(existsSync(PRIMARY_CLI), `the built primary Jira CLI is required at ${PRIMARY_CLI} (npm run build in scripts/jira)`);
    const s = scratch();
    assert.equal(statSync(s.attempt).mode & 0o777, 0o700);
  });
});
