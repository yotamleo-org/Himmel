'use strict';
// node --test scripts/himmelctl/test/bridge-persistence.test.js
// macOS persistence for the Telegram bridge (a LaunchAgent) and `himmelctl bridge enable`.
// Every launchctl, systemctl and loginctl here is a stub on PATH; nothing touches the real units,
// the real HOME or the network.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFileSync, spawnSync } = require('node:child_process');

const LIB = path.join(__dirname, '..', 'lib');
const BIN = path.join(__dirname, '..', 'bin.js');
const LABEL = 'com.himmel.telegram-bridge';

function sandbox() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'bridge-persist-'));
  const s = {
    dir,
    home: path.join(dir, 'home'),
    bin: path.join(dir, 'bin'),
    agents: path.join(dir, 'LaunchAgents'),
    units: path.join(dir, 'units'),
    log: path.join(dir, 'stub.log'),
    loaded: path.join(dir, 'loaded'),
    config: path.join(dir, 'config.json'),
  };
  for (const d of [s.home, s.bin, s.agents, s.units]) fs.mkdirSync(d, { recursive: true });
  const stub = (name, body) => {
    fs.writeFileSync(path.join(s.bin, name), `#!/bin/sh\necho "${name} $*" >> "$STUB_LOG"\n${body}\n`, { mode: 0o755 });
  };
  stub('launchctl', 'case "$1" in\n print) [ -f "$STUB_LOADED" ] && exit 0; exit 113;;\n bootstrap) : > "$STUB_LOADED"; exit 0;;\n bootout) [ -n "$STUB_BOOTOUT_FAIL" ] && exit 1; rm -f "$STUB_LOADED"; exit 0;;\nesac\nexit 0');
  stub('systemctl', 'case "$2" in\n is-enabled) [ -f "$STUB_LOADED" ] && exit 0; exit 1;;\n enable) : > "$STUB_LOADED"; exit 0;;\nesac\nexit 0');
  stub('loginctl', 'case "$1" in show-user) echo Linger=yes;; esac\nexit 0');
  s.env = Object.assign({}, process.env, {
    HOME: s.home,
    PATH: `${s.bin}${path.delimiter}${process.env.PATH}`,
    HIMMELCTL_LAUNCH_AGENTS_DIR: s.agents,
    HIMMELCTL_SYSTEMD_USER_UNIT_DIR: s.units,
    HIMMEL_LUNA_CONFIG_PATH: s.config,
    STUB_LOG: s.log,
    STUB_LOADED: s.loaded,
  });
  delete s.env.CLAUDECODE;
  s.logLines = () => (fs.existsSync(s.log) ? fs.readFileSync(s.log, 'utf8').split('\n').filter(Boolean) : []);
  return s;
}

const runNode = (s, code, extraEnv) => JSON.parse(execFileSync(process.execPath, ['-e', code], { env: Object.assign({}, s.env, extraEnv), encoding: 'utf8' }));
const sha = (f) => crypto.createHash('sha256').update(fs.readFileSync(f)).digest('hex');
const install = (s, repoRoot, dryRun) => runNode(s, `console.log(JSON.stringify(require(${JSON.stringify(path.join(LIB, 'bridge-persistence.js'))}).installLaunchAgent({repoRoot:${JSON.stringify(repoRoot)},dryRun:${dryRun ? 'true' : 'false'}})))`);

test('installLaunchAgent_renders_repo_and_home', () => {
  const s = sandbox();
  const repo = '/tmp/some repo & co';
  const r = install(s, repo, false);
  assert.equal(r.ok, true, r.detail);
  const plist = path.join(s.agents, `${LABEL}.plist`);
  const text = fs.readFileSync(plist, 'utf8');
  assert.ok(!text.includes('@'), 'no placeholder is left in the rendered plist');
  assert.ok(text.includes('/tmp/some repo &amp; co/scripts/telegram/restart-bridge.sh'), 'the repo path is XML-escaped into ProgramArguments');
  assert.ok(text.includes(`${s.home}/Library/Logs/himmel-telegram-bridge.log`), 'HOME is rendered');
  assert.ok(text.includes(`<string>${s.home}/.bun/bin:`), 'the bun installer directory leads the agent PATH');
  assert.match(text, /<key>SuccessfulExit<\/key>\s*<false\/>/);
  assert.match(text, /<key>RunAtLoad<\/key>\s*<true\/>/);
  const boot = s.logLines().filter((l) => l.startsWith('launchctl bootstrap '));
  assert.equal(boot.length, 1);
  assert.ok(boot[0].endsWith(plist), 'bootstrap names the installed plist');
});

test('installLaunchAgent_dry_run_writes_nothing', () => {
  const s = sandbox();
  const r = install(s, '/tmp/repo', true);
  assert.equal(r.ok, true);
  assert.ok(r.actions.some((a) => a.includes('launchctl bootstrap')));
  assert.equal(fs.existsSync(path.join(s.agents, `${LABEL}.plist`)), false);
  assert.deepEqual(s.logLines(), []);
});

test('installLaunchAgent_twice_changes_nothing', () => {
  const s = sandbox();
  install(s, '/tmp/repo', false);
  const plist = path.join(s.agents, `${LABEL}.plist`);
  const before = sha(plist);
  const r = install(s, '/tmp/repo', false);
  assert.equal(r.ok, true, r.detail);
  assert.equal(sha(plist), before);
  assert.equal(s.logLines().filter((l) => l.startsWith('launchctl bootstrap ')).length, 1, 'a loaded agent is not bootstrapped again');
});

test('installLaunchAgent_replaces_a_changed_plist_behind_a_loaded_job', () => {
  const s = sandbox();
  const plist = path.join(s.agents, `${LABEL}.plist`);
  install(s, '/tmp/repo-a', false);
  const r = install(s, '/tmp/repo-b', false);
  assert.equal(r.ok, true, r.detail);
  assert.ok(fs.readFileSync(plist, 'utf8').includes('/tmp/repo-b/scripts/telegram/restart-bridge.sh'));
  const verbs = s.logLines().map((l) => l.split(' ')[1]);
  assert.deepEqual(verbs.filter((v) => v === 'bootout' || v === 'bootstrap'), ['bootstrap', 'bootout', 'bootstrap'], 'the old job is booted out, then the new plist is bootstrapped');
});

test('installLaunchAgent_a_failed_bootout_leaves_the_plist_and_a_retry_reloads', () => {
  const s = sandbox();
  const plist = path.join(s.agents, `${LABEL}.plist`);
  install(s, '/tmp/repo-a', false);
  const before = sha(plist);
  const failed = runNode(s, `console.log(JSON.stringify(require(${JSON.stringify(path.join(LIB, 'bridge-persistence.js'))}).installLaunchAgent({repoRoot:'/tmp/repo-b'})))`, { STUB_BOOTOUT_FAIL: '1' });
  assert.equal(failed.ok, false);
  assert.match(failed.detail, /was NOT changed/);
  assert.equal(sha(plist), before, 'the old plist is still on disk');
  const retry = install(s, '/tmp/repo-b', false);
  assert.equal(retry.ok, true, retry.detail);
  assert.ok(fs.readFileSync(plist, 'utf8').includes('/tmp/repo-b/'), 'the retry installs the new bytes instead of reporting "already installed"');
  assert.notEqual(sha(plist), before);
});

test('installLaunchAgent_refuses_a_missing_launchctl', () => {
  const s = sandbox();
  fs.unlinkSync(path.join(s.bin, 'launchctl'));
  const r = runNode(s, `console.log(JSON.stringify(require(${JSON.stringify(path.join(LIB, 'bridge-persistence.js'))}).installLaunchAgent({repoRoot:'/tmp/repo'})))`, { PATH: s.bin });
  assert.equal(r.ok, false);
  assert.match(r.detail, /launchctl/);
});

const probe = (s) => runNode(s, `
const probes = require(${JSON.stringify(path.join(LIB, 'probes.js'))});
const r = probes.runProbe({ id: 'bridge-persistence', probe: { type: 'bridge-persistence' } },
  { repoRoot: ${JSON.stringify(path.join(__dirname, '..', '..', '..'))}, targetPath: ${JSON.stringify(s.home)}, scope: 'user', platform: 'darwin', env: process.env });
console.log(JSON.stringify(r));`);

test('darwin_persistence_ok_when_loaded', () => {
  const s = sandbox();
  fs.writeFileSync(s.config, JSON.stringify({ version: 1, bridge: { enabled: true } }));
  // not installed
  let r = probe(s);
  assert.equal(r.actual, 'degraded');
  assert.match(r.detail, /not installed/);
  // installed, not loaded
  fs.writeFileSync(path.join(s.agents, `${LABEL}.plist`), '<plist/>');
  r = probe(s);
  assert.equal(r.actual, 'degraded');
  assert.match(r.detail, /not loaded/);
  // installed and loaded
  fs.writeFileSync(s.loaded, '');
  r = probe(s);
  assert.equal(r.actual, 'present', r.detail);
  assert.match(r.detail, new RegExp(LABEL));
});

test('darwin_persistence_clean_absence_without_bridge_enabled', () => {
  const s = sandbox();
  const r = probe(s);
  assert.equal(r.actual, 'absent');
  assert.equal(r.cleanAbsence, true);
});

const bridgeEnable = (s, extra, platform) => {
  const r = spawnSync(process.execPath, [BIN, 'bridge', 'enable'].concat(extra || []), {
    env: Object.assign({}, s.env, platform ? { HIMMELCTL_PLATFORM: platform } : {}),
    encoding: 'utf8',
  });
  return { rc: r.status, out: r.stdout, err: r.stderr, json: (() => { try { return JSON.parse(r.stdout.trim().split('\n').pop()); } catch (_e) { return null; } })() };
};

test('bridge_enable_writes_flag_once', () => {
  const s = sandbox();
  const first = bridgeEnable(s);
  assert.equal(first.rc, 0, first.err + first.out);
  assert.equal(first.json.ok, true, first.out);
  assert.equal(JSON.parse(fs.readFileSync(s.config, 'utf8')).bridge.enabled, true);
  const before = sha(s.config);
  const second = bridgeEnable(s);
  assert.equal(second.rc, 0, second.err + second.out);
  assert.equal(second.json.ok, true);
  assert.equal(sha(s.config), before, 'the second run leaves the config byte-identical');
  assert.deepEqual(fs.readdirSync(s.dir).filter((f) => f.startsWith('config.json.')), [], 'and writes no backup');
});

test('bridge_enable_on_macos_installs_the_launch_agent', () => {
  const s = sandbox();
  const r = bridgeEnable(s, [], 'darwin');
  assert.equal(r.rc, 0, r.err + r.out);
  assert.equal(r.json.ok, true, r.out);
  assert.ok(fs.existsSync(path.join(s.agents, `${LABEL}.plist`)));
  assert.equal(JSON.parse(fs.readFileSync(s.config, 'utf8')).bridge.enabled, true);
});

test('bridge_enable_dry_run_changes_nothing', () => {
  const s = sandbox();
  const r = bridgeEnable(s, ['--dry-run'], 'darwin');
  assert.equal(r.rc, 0, r.err + r.out);
  assert.equal(r.json.ok, true);
  assert.ok(r.json.actions.length >= 2);
  assert.equal(fs.existsSync(s.config), false);
  assert.equal(fs.existsSync(path.join(s.agents, `${LABEL}.plist`)), false);
  assert.deepEqual(s.logLines(), []);
});

test('bridge_enable_rejects_another_verb', () => {
  const s = sandbox();
  const r = spawnSync(process.execPath, [BIN, 'bridge', 'bogus'], { env: s.env, encoding: 'utf8' });
  assert.equal(r.status, 2);
});
