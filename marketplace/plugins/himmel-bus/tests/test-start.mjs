import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';

const PLUGIN = fileURLToPath(new URL('..', import.meta.url));
const ENSURE_URL = new URL('../ensure-deps.mjs', import.meta.url);
const START = JSON.parse(fs.readFileSync(join(PLUGIN, 'package.json'), 'utf8')).scripts.start;
const OPTS = { timeout: 20000 };

const PKG = {
  server: '@modelcontextprotocol/server',
  core: '@modelcontextprotocol/core',
  client: '@modelcontextprotocol/client',
  zod: 'zod',
};
const CURRENT = { server: '2.4.0', core: '2.4.0', client: '2.4.0', zod: '4.6.7' };
const STALE = { server: '2.3.1', core: '2.3.1', client: '2.3.1', zod: '4.6.6' };
const NPMRC = '# fixture-npmrc\n';

const LOCK = {
  name: 'himmel-bus',
  lockfileVersion: 3,
  requires: true,
  packages: {
    '': { name: 'himmel-bus' },
    [`node_modules/${PKG.server}`]: { version: CURRENT.server },
    [`node_modules/${PKG.core}`]: { version: CURRENT.core },
    [`node_modules/${PKG.client}`]: { version: CURRENT.client, dev: true },
    [`node_modules/${PKG.zod}`]: { version: CURRENT.zod },
  },
};

const STUB = [
  '#!/usr/bin/env node',
  "const fs = require('node:fs');",
  "const path = require('node:path');",
  "const crypto = require('node:crypto');",
  'const argv = process.argv.slice(2);',
  "const pi = argv.indexOf('--prefix');",
  'const target = pi >= 0 ? argv[pi + 1] : process.cwd();',
  "const ver = d => { try { return JSON.parse(fs.readFileSync(path.join(d, 'package.json'), 'utf8')).version; } catch { return 'missing'; } };",
  "const sha = f => { try { return crypto.createHash('sha256').update(fs.readFileSync(f)).digest('hex'); } catch { return 'missing'; } };",
  'const line = [',
  "  argv.join(' '),",
  '  `cwd=${process.cwd()}`,',
  '  `target=${target}`,',
  '  `envprefix=${process.env.npm_config_prefix || "unset"}`,',
  '  `live=${ver(path.join(process.env.FIXTURE_DIR, "node_modules/@modelcontextprotocol/server"))}`,',
  '  `npmrc=${sha(path.join(target, ".npmrc"))}`,',
  "].join(' ');",
  "fs.appendFileSync(process.env.NPM_LOG, line + '\\n');",
  "process.stdout.write('NPM-NOISE\\n');",
  'if (process.env.NPM_SLEEP) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, Number(process.env.NPM_SLEEP) * 1000);',
  "const lock = JSON.parse(fs.readFileSync(path.join(target, 'package-lock.json'), 'utf8'));",
  'const put = key => {',
  '  const dir = path.join(target, key);',
  '  fs.mkdirSync(dir, { recursive: true });',
  "  fs.writeFileSync(path.join(dir, 'package.json'), JSON.stringify({ name: key.replace(/^node_modules\\//, ''), version: lock.packages[key].version }));",
  '};',
  "const serverKey = 'node_modules/@modelcontextprotocol/server';",
  'if (process.env.NPM_FAIL) { put(serverKey); process.exit(1); }',
  'if (process.env.NPM_PARTIAL) { put(serverKey); process.exit(0); }',
  "if (argv[0] === 'ci') { for (const key of Object.keys(lock.packages)) if (key) put(key); }",
  '',
].join('\n');

function writeTree(nm, versions) {
  for (const [key, version] of Object.entries(versions)) {
    if (version === null) continue;
    const dir = join(nm, PKG[key]);
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(join(dir, 'package.json'), JSON.stringify({ name: PKG[key], version }));
  }
}

function tmpRoot(t, prefix) {
  const dir = fs.mkdtempSync(join(fs.realpathSync(tmpdir()), prefix));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return dir;
}

function makeFixture(t, { versions = STALE } = {}) {
  const dir = tmpRoot(t, 'bus-start-');
  fs.writeFileSync(join(dir, 'package.json'), JSON.stringify({ name: 'himmel-bus', private: true, scripts: { start: START } }));
  fs.writeFileSync(join(dir, 'package-lock.json'), JSON.stringify(LOCK));
  fs.writeFileSync(join(dir, '.npmrc'), NPMRC);
  if (fs.existsSync(join(PLUGIN, 'ensure-deps.mjs'))) fs.copyFileSync(join(PLUGIN, 'ensure-deps.mjs'), join(dir, 'ensure-deps.mjs'));
  fs.mkdirSync(join(dir, 'server'));
  fs.writeFileSync(join(dir, 'server/index.mjs'), "process.stdout.write('SERVER-UP\\n');\n");
  fs.mkdirSync(join(dir, 'bin'));
  fs.writeFileSync(join(dir, 'bin/npm'), STUB, { mode: 0o755 });
  writeTree(join(dir, 'node_modules'), versions);
  return dir;
}

function runStart(dir, env = {}) {
  const logFile = join(dir, 'npm-calls.log');
  const started = Date.now();
  return new Promise((resolve, reject) => {
    const child = spawn('sh', ['-c', START], {
      cwd: dir,
      env: { PATH: `${join(dir, 'bin')}:${process.env.PATH}`, FIXTURE_DIR: dir, NPM_LOG: logFile, ...env },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    const killer = setTimeout(() => child.kill('SIGKILL'), 18000);
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', d => { stdout += d; });
    child.stderr.on('data', d => { stderr += d; });
    child.on('error', reject);
    child.on('close', code => {
      clearTimeout(killer);
      const log = fs.existsSync(logFile) ? fs.readFileSync(logFile, 'utf8').split('\n').filter(Boolean) : null;
      resolve({ code, stdout, stderr, log, ms: Date.now() - started });
    });
  });
}

const importEnsure = () => import(ENSURE_URL);
const installed = (dir, key) => {
  try { return JSON.parse(fs.readFileSync(join(dir, 'node_modules', PKG[key], 'package.json'), 'utf8')).version; } catch { return null; }
};
const leftovers = dir => fs.readdirSync(dir).filter(n => n.startsWith('.ensure-deps.'));
const ciCalls = r => r.log.filter(l => l.startsWith('ci '));
const sha256 = s => createHash('sha256').update(s).digest('hex');

function assertCurrent(dir) {
  for (const key of ['server', 'core', 'zod']) assert.equal(installed(dir, key), CURRENT[key], `${key} is at its lock version`);
}

test('stale-sdk-reinstalls', OPTS, async t => {
  const dir = makeFixture(t);
  const r = await runStart(dir);
  assert.ok(r.log, 'the npm stub never ran: no ci call, 2.3.1 stays');
  assert.equal(ciCalls(r).length, 1);
  assertCurrent(dir);
  assert.equal(r.stdout, 'SERVER-UP\n');
});

test('transitive-entry-stale-reinstalls', OPTS, async t => {
  const dir = makeFixture(t, { versions: { ...CURRENT, core: '2.3.1' } });
  const r = await runStart(dir);
  assert.ok(r.log, 'the npm stub never ran');
  assert.equal(ciCalls(r).length, 1);
  assertCurrent(dir);
});

test('absent-sdk-installs', OPTS, async t => {
  const dir = makeFixture(t, { versions: { ...CURRENT, server: null } });
  const r = await runStart(dir);
  assert.ok(r.log, 'the npm stub never ran');
  assert.equal(ciCalls(r).length, 1);
  assertCurrent(dir);
});

test('current-tree-no-npm', OPTS, async t => {
  const dir = makeFixture(t, { versions: CURRENT });
  const r = await runStart(dir);
  assert.equal(r.log, null);
  assert.equal(r.stdout, 'SERVER-UP\n');
  assert.equal(r.code, 0);
});

test('dev-entry-stale-no-install', OPTS, async t => {
  const dir = makeFixture(t, { versions: { ...CURRENT, client: '2.3.1' } });
  const r = await runStart(dir);
  assert.equal(r.log, null);
  assert.equal(r.stdout, 'SERVER-UP\n');
});

test('npm-stdout-stays-off-stdout', OPTS, async t => {
  const dir = makeFixture(t);
  const r = await runStart(dir);
  assert.ok(r.log, 'the npm stub never ran');
  assert.equal(r.stdout, 'SERVER-UP\n');
  assert.match(r.stderr, /NPM-NOISE/);
});

test('install-runs-in-stage', OPTS, async t => {
  const dir = makeFixture(t);
  const r = await runStart(dir, { npm_config_prefix: dir });
  assert.ok(r.log, 'the npm stub never ran');
  const m = /^(.*) cwd=(\S+) target=(\S+) envprefix=(\S+) live=(\S+) npmrc=(\S+)$/.exec(ciCalls(r)[0]);
  assert.ok(m, `log line parses: ${r.log[0]}`);
  const [, argv, , target, envprefix, live, npmrc] = m;
  const stage = /--prefix (\S+)/.exec(argv);
  assert.ok(stage, 'argv has --prefix');
  assert.match(stage[1], /\.ensure-deps\.stage\.\d+$/);
  assert.equal(target, stage[1]);
  assert.equal(envprefix, dir);
  assert.equal(live, '2.3.1');
  assert.equal(npmrc, sha256(NPMRC));
});

test('install-failure-keeps-old-tree', OPTS, async t => {
  const dir = makeFixture(t);
  const r = await runStart(dir, { NPM_FAIL: '1' });
  assert.ok(r.log, 'the npm stub never ran');
  assert.equal(installed(dir, 'server'), '2.3.1');
  assert.deepEqual(leftovers(dir), []);
  assert.equal(r.stdout, 'SERVER-UP\n');
  assert.match(r.stderr, /^ensure-deps: install failed/m);
});

test('install-incomplete-keeps-old-tree', OPTS, async t => {
  const dir = makeFixture(t);
  const r = await runStart(dir, { NPM_PARTIAL: '1' });
  assert.ok(r.log, 'the npm stub never ran');
  assert.equal(installed(dir, 'server'), '2.3.1');
  assert.equal(installed(dir, 'zod'), '4.6.6');
  assert.deepEqual(leftovers(dir), []);
  assert.equal(r.stdout, 'SERVER-UP\n');
  assert.match(r.stderr, /^ensure-deps: install failed/m);
});

test('npm-hang-hits-deadline', OPTS, async t => {
  const dir = makeFixture(t);
  const r = await runStart(dir, { ENSURE_DEPS_NPM_TIMEOUT_MS: '1000', NPM_SLEEP: '30' });
  assert.ok(r.log, 'the npm stub never ran');
  assert.equal(r.stdout, 'SERVER-UP\n');
  assert.ok(r.ms < 10000, `server up in ${r.ms} ms`);
  assert.equal(installed(dir, 'server'), '2.3.1');
  assert.deepEqual(leftovers(dir), []);
});

test('concurrent-starts-both-run', OPTS, async t => {
  const dir = makeFixture(t);
  const [a, b] = await Promise.all([runStart(dir, { NPM_SLEEP: '1' }), runStart(dir, { NPM_SLEEP: '1' })]);
  assert.equal(a.stdout, 'SERVER-UP\n');
  assert.equal(b.stdout, 'SERVER-UP\n');
  assertCurrent(dir);
  assert.deepEqual(leftovers(dir), []);
});

test('sweep-dead-leftovers', OPTS, async t => {
  const dir = makeFixture(t);
  const dead = spawnSync(process.execPath, ['-e', '0']).pid;
  const mk = name => { fs.mkdirSync(join(dir, name)); fs.writeFileSync(join(dir, name, 'f'), 'x'); };
  mk(`.ensure-deps.stage.${dead}`);
  mk(`.ensure-deps.old.${dead}`);
  mk(`.ensure-deps.stage.${process.pid}`);
  const r = await runStart(dir);
  assert.ok(r.log, 'the npm stub never ran');
  assert.deepEqual(leftovers(dir), [`.ensure-deps.stage.${process.pid}`]);
});

function swapFixture(t, live) {
  const dir = tmpRoot(t, 'bus-swap-');
  fs.writeFileSync(join(dir, 'package-lock.json'), JSON.stringify(LOCK));
  writeTree(join(dir, 'node_modules'), live);
  const pid = 424242;
  const stage = join(dir, `.ensure-deps.stage.${pid}`);
  writeTree(join(stage, 'node_modules'), CURRENT);
  return { dir, stage, pid };
}

test('swap-skipped-when-live-current', OPTS, async t => {
  const { swap } = await importEnsure();
  const { dir, stage, pid } = swapFixture(t, CURRENT);
  const renames = [];
  const fsImpl = { ...fs, renameSync: (...a) => { renames.push(a); return fs.renameSync(...a); } };
  assert.equal(swap(dir, stage, pid, fsImpl), 'skipped');
  assert.deepEqual(renames, []);
  assert.deepEqual(leftovers(dir), []);
});

test('swap-loses-race-keeps-other-tree', OPTS, async t => {
  const { swap } = await importEnsure();
  const { dir, stage, pid } = swapFixture(t, STALE);
  let n = 0;
  const fsImpl = {
    ...fs,
    renameSync: (a, b) => {
      n += 1;
      fs.renameSync(a, b);
      if (n === 1) writeTree(join(dir, 'node_modules'), CURRENT);
    },
  };
  assert.equal(swap(dir, stage, pid, fsImpl), 'kept-other');
  assertCurrent(dir);
  assert.deepEqual(leftovers(dir), []);
});

test('swap-error-restores-old-tree', OPTS, async t => {
  const { swap } = await importEnsure();
  const { dir, stage, pid } = swapFixture(t, STALE);
  let n = 0;
  const fsImpl = {
    ...fs,
    renameSync: (a, b) => {
      n += 1;
      if (n === 2) throw Object.assign(new Error('denied'), { code: 'EACCES' });
      return fs.renameSync(a, b);
    },
  };
  assert.equal(swap(dir, stage, pid, fsImpl), 'restored');
  assert.equal(installed(dir, 'server'), '2.3.1');
  assert.deepEqual(leftovers(dir), []);
});

test('deadline-constant-and-override', OPTS, async () => {
  const { NPM_DEADLINE_MS, deadlineFrom } = await importEnsure();
  assert.ok(NPM_DEADLINE_MS < 30000);
  assert.equal(deadlineFrom({ ENSURE_DEPS_NPM_TIMEOUT_MS: '1000' }), 1000);
  for (const v of ['0', '', 'x', undefined]) assert.equal(deadlineFrom({ ENSURE_DEPS_NPM_TIMEOUT_MS: v }), NPM_DEADLINE_MS);
  assert.equal(deadlineFrom({}), NPM_DEADLINE_MS);
});

test('gitignore-covers-leftovers', OPTS, () => {
  for (const name of ['.ensure-deps.stage.1/f', '.ensure-deps.old.1/f']) {
    const r = spawnSync('git', ['-C', PLUGIN, 'check-ignore', '-q', name]);
    assert.equal(r.status, 0, `${name} is ignored`);
  }
});
