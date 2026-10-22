#!/usr/bin/env bash
# test-secret-store.sh — secret-store.js writes one secret to
# its documented 0600 store in-process (never on a child's argv), detects it
# without returning the value, and validates without echoing the input.
#
# WHY: the one .env writer (bin.js writeEnvVar -> set-env-var.sh KEY VALUE) puts
# the value on a child's argv, visible in `ps`. Every value here is generated at
# runtime; nothing token-shaped is committed. Everything lives under a temp dir.
set -uo pipefail

root="$(git rev-parse --show-toplevel)"
node_bin="${NODE:-node}"

SS_ROOT="$root" "$node_bin" - <<'NODE'
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { spawnSync } = require('child_process');

const root = process.env.SS_ROOT;
const lib = path.join(root, 'scripts/himmelctl/lib');
let fails = 0;
function pass(n) { console.log('PASS - ' + n); }
function fail(n, why) { fails++; console.log('FAIL - ' + n + (why ? ': ' + why : '')); }
function row(n, fn) { try { fn(); pass(n); } catch (e) { fail(n, e && e.message); } }
function eq(a, b, m) { if (a !== b) throw new Error((m || 'eq') + ': got ' + JSON.stringify(a) + ' want ' + JSON.stringify(b)); }
function ok(c, m) { if (!c) throw new Error(m || 'assertion failed'); }
const fake = () => crypto.randomBytes(18).toString('hex');

let store;
try { store = require(path.join(lib, 'secret-store.js')); } catch (e) { fail('secret-store.js loads', e.message); console.log('1 failure'); process.exit(1); }
const redact = require(path.join(lib, 'redact.js'));
const manifest = require(path.join(lib, 'secrets-manifest.json'));

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'ss-test.'));
process.on('exit', () => { try { fs.rmSync(tmp, { recursive: true, force: true }); } catch {} });
let n = 0;
function mk() {
  const base = path.join(tmp, 'c' + (n++));
  const home = path.join(base, 'home'), himmelRoot = path.join(base, 'himmel'), projectRoot = path.join(base, 'proj');
  for (const d of [home, himmelRoot, projectRoot]) { fs.mkdirSync(d, { recursive: true }); fs.chmodSync(d, 0o700); }
  return { home, himmelRoot, projectRoot, env: {} };
}
const modeOf = (f) => (fs.statSync(f).mode & 0o777).toString(8);

row('a manifest: every entry has collect/validate/store; Jira keys present with their stores', () => {
  for (const s of manifest.secrets) {
    ok(['file', 'card'].includes(s.collect), s.name + ' collect');
    ok(typeof s.validate === 'string' && s.validate, s.name + ' validate');
    ok(typeof s.store === 'string' && s.store, s.name + ' store');
  }
  const by = Object.fromEntries(manifest.secrets.map((s) => [s.name, s]));
  for (const k of ['JIRA_BASE_URL', 'JIRA_EMAIL', 'JIRA_API_TOKEN']) eq(by[k].store, 'himmel-env', k + ' store');
  eq(by.JIRA_PROJECT_KEY.store, 'project-env', 'JIRA_PROJECT_KEY store');
  eq(by.TELEGRAM_BOT_TOKEN.store, 'bridge-env', 'telegram store');
  eq(by.FIRECRAWL_API_KEY.collect, 'card');
});

row('b write: 0600 under a permissive umask, other lines byte-for-byte, no temp/.bak left', () => {
  const ctx = mk(); const v = fake();
  const f = path.join(ctx.himmelRoot, '.env');
  const before = '# keep\r\nOTHER=1\r\nJIRA_EMAIL=old@example.com\r\n\r\nTAIL=z';
  fs.writeFileSync(f, before);
  const prev = process.umask(0o022);
  try { store.write('JIRA_EMAIL', 'new@example.com', ctx); store.write('JIRA_API_TOKEN', v, ctx); } finally { process.umask(prev); }
  eq(modeOf(f), '600', 'mode');
  const raw = fs.readFileSync(f, 'utf8');
  ok(raw.startsWith('# keep\r\nOTHER=1\r\nJIRA_EMAIL=new@example.com\r\n\r\nTAIL=z'), 'lines preserved: ' + JSON.stringify(raw.replace(v, '<v>')));
  ok(raw.includes('JIRA_API_TOKEN=' + v), 'appended');
  eq((raw.match(/JIRA_EMAIL=/g) || []).length, 1, 'no duplicate key');
  eq(fs.readdirSync(ctx.himmelRoot).join(','), '.env', 'only .env remains');
});

row('b2 write creates a missing file at 0600 (and a missing bridge dir at 0700)', () => {
  const ctx = mk(); const v = '12345678:' + crypto.randomBytes(26).toString('base64url').slice(0, 35);
  const prev = process.umask(0o022);
  try { store.write('TELEGRAM_BOT_TOKEN', v, ctx); } finally { process.umask(prev); }
  const f = path.join(ctx.home, '.claude/channels/telegram/.env');
  eq(modeOf(f), '600', 'file mode'); eq(modeOf(path.dirname(f)), '700', 'dir mode');
});

row('c write tightens a looser mode and says so', () => {
  const ctx = mk(); const f = path.join(ctx.himmelRoot, '.env');
  fs.writeFileSync(f, 'A=1\n', { mode: 0o644 }); fs.chmodSync(f, 0o644);
  const r = store.write('JIRA_EMAIL', 'a@example.com', ctx);
  eq(modeOf(f), '600'); eq(r.tightened, true);
  eq(store.write('JIRA_EMAIL', 'b@example.com', ctx).tightened, false, 'already 0600');
});

row('d write refuses a symlinked target and leaves the link target untouched', () => {
  const ctx = mk(); const real = path.join(ctx.projectRoot, 'real'); fs.writeFileSync(real, 'X=1\n');
  fs.symlinkSync(real, path.join(ctx.himmelRoot, '.env'));
  const v = fake(); let msg = '';
  try { store.write('JIRA_API_TOKEN', v, ctx); } catch (e) { msg = e.message; }
  ok(/symlink/.test(msg), 'refused: ' + msg); ok(!msg.includes(v), 'no value in error');
  eq(fs.readFileSync(real, 'utf8'), 'X=1\n');
});

row('e write refuses a target owned by another user', () => {
  const ctx = mk(); fs.writeFileSync(path.join(ctx.himmelRoot, '.env'), 'X=1\n');
  ctx.uid = process.getuid() + 1;
  let msg = ''; try { store.write('JIRA_EMAIL', 'a@example.com', ctx); } catch (e) { msg = e.message; }
  ok(/owned by another user/.test(msg), 'refused: ' + msg);
});

row('f git guard: a work tree needs check-ignore true; no checker fails closed; outside a work tree no check', () => {
  const ctx = mk(); fs.mkdirSync(path.join(ctx.himmelRoot, '.git'));
  const v = fake();
  let msg = ''; try { store.write('JIRA_API_TOKEN', v, ctx); } catch (e) { msg = e.message; }
  ok(/gitignore|ignored/i.test(msg), 'no checker refuses: ' + msg);
  ctx.gitCheckIgnore = () => false; msg = '';
  try { store.write('JIRA_API_TOKEN', v, ctx); } catch (e) { msg = e.message; }
  ok(/ignored/i.test(msg) && !msg.includes(v), 'not ignored refuses: ' + msg);
  ok(!fs.existsSync(path.join(ctx.himmelRoot, '.env')), 'nothing written');
  ctx.gitCheckIgnore = () => true; store.write('JIRA_API_TOKEN', v, ctx);
  ok(fs.readFileSync(path.join(ctx.himmelRoot, '.env'), 'utf8').includes(v), 'ignored writes');
  const c2 = mk(); c2.gitCheckIgnore = () => { throw new Error('must not be asked'); };
  store.write('JIRA_API_TOKEN', fake(), c2);
});

row('f2 git guard end to end against real git check-ignore', () => {
  const ctx = mk(); const d = ctx.himmelRoot;
  spawnSync('git', ['init', '-q', d]);
  const chk = (file) => { const r = spawnSync('git', ['-C', path.dirname(file), 'check-ignore', '-q', file]); return r.status === 0; };
  ctx.gitCheckIgnore = chk;
  let msg = ''; try { store.write('JIRA_EMAIL', 'a@example.com', ctx); } catch (e) { msg = e.message; }
  ok(/ignored/i.test(msg), 'unignored refused: ' + msg);
  fs.writeFileSync(path.join(d, '.gitignore'), '.env\n');
  store.write('JIRA_EMAIL', 'a@example.com', ctx);
});

row('g detect: placeholder, unset, set, live env, mcp store; never returns the value', () => {
  const ctx = mk(); const f = path.join(ctx.himmelRoot, '.env'); const v = fake();
  eq(store.detect('JIRA_API_TOKEN', ctx).status, 'not-set');
  fs.writeFileSync(f, 'JIRA_API_TOKEN=your_api_token_here\n'); eq(store.detect('JIRA_API_TOKEN', ctx).status, 'placeholder');
  fs.writeFileSync(f, 'JIRA_API_TOKEN=<token>\n'); eq(store.detect('JIRA_API_TOKEN', ctx).status, 'placeholder');
  fs.writeFileSync(f, 'JIRA_API_TOKEN=\n'); eq(store.detect('JIRA_API_TOKEN', ctx).status, 'not-set');
  fs.writeFileSync(f, 'JIRA_API_TOKEN=' + v + '\n');
  const d = store.detect('JIRA_API_TOKEN', ctx);
  eq(d.status, 'set'); eq(d.source, 'store'); ok(!JSON.stringify(d).includes(v), 'value leaked');
  ctx.env = { JIRA_API_TOKEN: fake() };
  const dl = store.detect('JIRA_API_TOKEN', ctx); eq(dl.status, 'set'); eq(dl.source, 'live-env');
  ok(!JSON.stringify(dl).includes(ctx.env.JIRA_API_TOKEN), 'live value leaked');
  const c2 = mk(); const m = path.join(c2.home, '.config/himmel/mcp-secrets/srv'); fs.mkdirSync(m, { recursive: true });
  fs.writeFileSync(path.join(m, 'SOME_MCP_VAR'), fake(), { mode: 0o600 });
  const dm = store.detect('SOME_MCP_VAR', c2); eq(dm.status, 'set'); eq(dm.source, 'mcp-store');
});

row('h validate: rule names only, never the input', () => {
  const bad = {
    JIRA_BASE_URL: 'http://' + fake() + '.atlassian.net', JIRA_EMAIL: fake(), JIRA_API_TOKEN: 'has space ' + fake(),
    JIRA_PROJECT_KEY: 'lower' + fake(), TELEGRAM_BOT_TOKEN: fake(),
  };
  for (const [k, v] of Object.entries(bad)) {
    const r = store.validate(k, v);
    eq(r.ok, false, k); ok(typeof r.rule === 'string' && r.rule, k + ' rule');
    ok(!JSON.stringify(r).includes(v), k + ' echoed the input');
    let msg = ''; try { store.write(k, v, mk()); } catch (e) { msg = e.message; }
    ok(msg && !msg.includes(v), k + ' write error echoed the input: ' + msg);
  }
  eq(store.validate('JIRA_BASE_URL', 'https://example.atlassian.net').ok, true);
  eq(store.validate('JIRA_EMAIL', 'a@example.com').ok, true);
  eq(store.validate('JIRA_PROJECT_KEY', 'HIMMEL').ok, true);
  eq(store.validate('TELEGRAM_BOT_TOKEN', '123456789:' + 'A'.repeat(35)).ok, true);
  eq(store.validate('JIRA_API_TOKEN', fake()).ok, true);
  for (const v of ['a\nb', 'a\rb', '"quoted', 'abc#' + fake()]) eq(store.validate('JIRA_API_TOKEN', v).ok, false, JSON.stringify(v));
});

row('h3 detect: a model-file card entry defers to its probe, not the live env', () => {
  const ctx = mk(); ctx.env = { WHISPER_MODEL: '/nonexistent/model.bin' };
  const d = store.detect('WHISPER_MODEL', ctx);
  eq(d.status, 'probe'); eq(d.source, 'cmd:whisper_ready');
});

row('h4 redactor: a bad entry in the MCP dir does not drop later servers', () => {
  const ctx = mk(); const v = fake(); const m = path.join(ctx.home, '.config/himmel/mcp-secrets');
  fs.mkdirSync(m, { recursive: true }); fs.writeFileSync(path.join(m, 'a-not-a-dir'), 'x');
  fs.mkdirSync(path.join(m, 'z-srv')); fs.writeFileSync(path.join(m, 'z-srv', 'K'), v);
  const lits = redact.storeLiterals([], require(path.join(lib, 'probes.js')).parseDotEnv, store.mcpDir(ctx));
  ok(lits.includes(v), 'later server dropped');
});

row('h5 unwritable guard: a value new URL() or a lax rule would pass is refused as single-line, and never reaches the file', () => {
  const host = 'https://a.atlassian.net';
  const cases = [host + '\nEVIL=1', host + '\rEVIL=1', host + '\0', host + ' ', ' ' + host];
  for (const v of cases) {
    const r = store.validate('JIRA_BASE_URL', v);
    eq(r.ok, false, JSON.stringify(v)); eq(r.rule, 'single-line', JSON.stringify(v));
    const ctx = mk(); let msg = ''; try { store.write('JIRA_BASE_URL', v, ctx); } catch (e) { msg = e.message; }
    ok(/single-line/.test(msg), 'write refused: ' + msg);
    ok(!fs.existsSync(path.join(ctx.himmelRoot, '.env')), 'nothing written for ' + JSON.stringify(v));
  }
});

row('h6 write never rewrites bytes it cannot decode: refused, file untouched', () => {
  const ctx = mk(); const f = path.join(ctx.himmelRoot, '.env');
  const before = Buffer.concat([Buffer.from('# caf'), Buffer.from([0xe9]), Buffer.from('\nOTHER_KEY=ab'), Buffer.from([0xe9]), Buffer.from('cd\nJIRA_EMAIL=old@example.com\n')]);
  fs.writeFileSync(f, before);
  let msg = ''; try { store.write('JIRA_EMAIL', 'new@example.com', ctx); } catch (e) { msg = e.message; }
  ok(/utf-?8/i.test(msg), 'refused: ' + msg);
  ok(fs.readFileSync(f).equals(before), 'bytes changed');
});

row('h7 write refuses a store directory other users can write to', () => {
  const ctx = mk(); fs.chmodSync(ctx.himmelRoot, 0o777);
  let msg = ''; try { store.write('JIRA_EMAIL', 'a@example.com', ctx); } catch (e) { msg = e.message; }
  ok(/writable/.test(msg), 'refused: ' + msg);
  ok(!fs.existsSync(path.join(ctx.himmelRoot, '.env')), 'nothing written');
});

row('h8 shell-safe: a value a bash `source` would execute or expand is refused, never reaches the file', () => {
  for (const meta of ['$', '`', ';', '\\', '&', '|', '<', '>', '(', ')', "'", '"']) {
    const v = fake() + meta + fake();
    const r = store.validate('JIRA_API_TOKEN', v);
    eq(r.ok, false, JSON.stringify(meta)); eq(r.rule, 'shell-safe', JSON.stringify(meta));
    const ctx = mk(); let msg = ''; try { store.write('JIRA_API_TOKEN', v, ctx); } catch (e) { msg = e.message; }
    ok(/shell-safe/.test(msg) && !msg.includes(v), 'write refused: ' + msg);
    ok(!fs.existsSync(path.join(ctx.himmelRoot, '.env')), 'nothing written for ' + JSON.stringify(meta));
  }
  const spaced = store.validate('JIRA_BASE_URL', 'https://a.atlassian.net/p x');
  eq(spaced.ok, false, 'interior whitespace in a URL'); eq(spaced.rule, 'shell-safe', 'interior whitespace rule');
  eq(store.validate('JIRA_API_TOKEN', fake() + '=_-.+/:@%').ok, true, 'token alphabet stays writable');
  eq(store.validate('JIRA_BASE_URL', 'https://example.atlassian.net/x').ok, true);
});

row('h9 directory mode: group-write passes only for the user\'s private group; world-write never', () => {
  const me = os.userInfo().username;
  const acct = (ctx, members, primaries) => {
    const g = process.getgid();
    const gf = path.join(ctx.home, 'group'), pf = path.join(ctx.home, 'passwd');
    fs.writeFileSync(gf, me + ':x:' + g + ':' + members.join(',') + '\n');
    fs.writeFileSync(pf, primaries.map((u) => u + ':x:1:' + g + '::/:/bin/sh').join('\n') + '\n');
    ctx.accountFiles = { group: gf, passwd: pf };
  };
  const refused = (ctx, why) => {
    let msg = ''; try { store.write('JIRA_EMAIL', 'a@example.com', ctx); } catch (e) { msg = e.message; }
    ok(/writable/.test(msg), why + ': ' + msg);
  };
  const ctx = mk(); acct(ctx, [], [me]); fs.chmodSync(ctx.himmelRoot, 0o775);
  store.write('JIRA_EMAIL', 'a@example.com', ctx);
  ok(fs.existsSync(path.join(ctx.himmelRoot, '.env')), 'private group 0775 writes');
  const c2 = mk(); acct(c2, ['other'], [me]); fs.chmodSync(c2.himmelRoot, 0o775); refused(c2, 'shared group member');
  const c3 = mk(); acct(c3, [], [me, 'other']); fs.chmodSync(c3.himmelRoot, 0o775); refused(c3, 'shared primary group');
  const c4 = mk(); acct(c4, [], [me]); c4.gid = process.getgid() + 1; fs.chmodSync(c4.himmelRoot, 0o775); refused(c4, 'dir group is not the primary group');
  const c6 = mk(); acct(c6, [], [me]); fs.writeFileSync(c6.accountFiles.group, 'other:x:' + (process.getgid() + 1) + ':\n'); fs.chmodSync(c6.himmelRoot, 0o775); refused(c6, 'group not defined in the local group file');
  const c5 = mk(); acct(c5, [], [me]); fs.chmodSync(c5.himmelRoot, 0o777); refused(c5, 'world-writable');
});

row('h2 card entries are not writable', () => {
  let msg = ''; try { store.write('FIRECRAWL_API_KEY', fake(), mk()); } catch (e) { msg = e.message; }
  ok(/card/.test(msg), msg);
});

row('i probe host: only the provider host; a non-atlassian.net Jira host needs consent', () => {
  eq(store.probePlan('JIRA_API_TOKEN', { JIRA_BASE_URL: 'https://acme.atlassian.net' }).needsConsent, false);
  const p = store.probePlan('JIRA_API_TOKEN', { JIRA_BASE_URL: 'https://jira.corp.example' });
  eq(p.needsConsent, true); eq(p.host, 'jira.corp.example'); eq(p.via, 'jira-cli');
  eq(store.probePlan('JIRA_API_TOKEN', { JIRA_BASE_URL: 'https://evil.example/@acme.atlassian.net' }).host, 'evil.example');
  eq(store.probePlan('JIRA_API_TOKEN', { JIRA_BASE_URL: 'https://acme.atlassian.net.evil.example' }).needsConsent, true);
  eq(store.probePlan('TELEGRAM_BOT_TOKEN', {}).host, 'api.telegram.org');
});

row('j redactor: every wizard store feeds the literal set', () => {
  const ctx = mk(); const a = fake(), b = fake(), c = fake();
  fs.writeFileSync(path.join(ctx.himmelRoot, '.env'), 'JIRA_API_TOKEN=' + a + '\n');
  fs.mkdirSync(path.join(ctx.home, '.claude/channels/telegram'), { recursive: true });
  fs.writeFileSync(path.join(ctx.home, '.claude/channels/telegram/.env'), 'TELEGRAM_BOT_TOKEN=' + b + '\n');
  const m = path.join(ctx.home, '.config/himmel/mcp-secrets/srv'); fs.mkdirSync(m, { recursive: true });
  fs.writeFileSync(path.join(m, 'ANY_NAME'), c + '\n');
  const lits = redact.storeLiterals(store.storePaths(ctx), require(path.join(lib, 'probes.js')).parseDotEnv, store.mcpDir(ctx));
  const out = redact.redact('x ' + a + ' y ' + b + ' z ' + c, { literals: lits });
  for (const v of [a, b, c]) ok(!out.includes(v), 'unscrubbed value in: ' + out.replace(/[0-9a-f]{12,}/g, '<hex>'));
});

row('k no spawn/exec/child_process in secret-store.js', () => {
  const src = fs.readFileSync(path.join(lib, 'secret-store.js'), 'utf8');
  ok(!/child_process|\bspawn|\bexecFile|\bexecSync|(^|[^.\w])exec\(|set-env-var/.test(src.replace(/^\s*\/\/.*$/gm, '')), 'found a process-spawning construct');
});

row('l one store interface: a registered backend takes the write (vault seam)', () => {
  const seen = [];
  store.registerBackend('vault-test', { detect: () => ({ status: 'set', source: 'vault-test' }), write: (name) => { seen.push(name); return { ok: true }; } });
  const ctx = mk(); ctx.backend = 'vault-test';
  store.write('JIRA_EMAIL', 'a@example.com', ctx);
  eq(seen.join(','), 'JIRA_EMAIL'); eq(store.detect('JIRA_EMAIL', ctx).source, 'vault-test');
  ok(!fs.existsSync(path.join(ctx.himmelRoot, '.env')), 'file backend bypassed');
});

row('m himmel-env resolves to the primary checkout from a linked worktree, as the Jira CLI does', () => {
  const ctx = mk(); const primary = ctx.himmelRoot; const wt = path.join(path.dirname(primary), 'wt'); const v = fake();
  const git = (...a) => { const r = spawnSync('git', ['-C', primary, '-c', 'user.name=t', '-c', 'user.email=t@example.com', ...a], { encoding: 'utf8' }); ok(r.status === 0, 'git ' + a[0] + ': ' + r.stderr); };
  git('init', '-q'); git('commit', '-q', '--allow-empty', '-m', 'x'); git('worktree', 'add', '-q', wt);
  fs.writeFileSync(path.join(primary, '.env'), 'JIRA_API_TOKEN=' + v + '\n');
  fs.appendFileSync(path.join(primary, '.env'), 'JIRA_PROJECT_KEY=HIMMEL\n');
  const c2 = { ...ctx, himmelRoot: wt, projectRoot: wt };
  const d = store.detect('JIRA_API_TOKEN', c2); eq(d.status, 'set'); eq(d.source, 'store');
  eq(store.detect('JIRA_PROJECT_KEY', c2).status, 'set');
  eq(store.detect('JIRA_EMAIL', c2).status, 'not-set');
  c2.gitCheckIgnore = () => true; store.write('JIRA_EMAIL', 'a@example.com', c2);
  ok(fs.readFileSync(path.join(primary, '.env'), 'utf8').includes('JIRA_EMAIL=a@example.com'), 'write went to the primary .env');
  ok(!fs.existsSync(path.join(wt, '.env')), 'no .env created in the worktree');
  eq(store.detect('JIRA_API_TOKEN', { ...mk(), himmelRoot: path.join(tmp, 'nogit') }).status, 'not-set');
});

console.log(fails ? fails + ' failure(s)' : 'all rows passed');
process.exit(fails ? 1 : 0);
NODE
