'use strict';
// node --test scripts/himmelctl/test/remote-peer.test.js
// The remote-peer status item: "the peer bridge is set up and its poller runs".
// It reads ~/.himmel/remote-setup/peers-confirmed.json (written by remote-setup.sh peer) and the poller
// unit's state, and nothing under the peer-bridge state or key dirs. systemctl and launchctl here are
// stubs on PATH; nothing touches a real unit, the real HOME or the network. Strings are canaries.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const probes = require('../lib/probes.js');

const REPO = path.join(__dirname, '..', '..', '..');
const CANARY = 'CANARY-PEER-BYTES-9f3a';
const ITEM = { id: 'remote-peer', probe: { type: 'remote-peer' } };
const UNIT = 'himmel-peer-bridge.service';
const LABEL = 'com.himmel.peer-bridge';

function fixture() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'remote-peer-'));
  const f = { dir, home: path.join(dir, 'home'), bin: path.join(dir, 'bin'), active: path.join(dir, 'active'), loaded: path.join(dir, 'loaded') };
  fs.mkdirSync(path.join(f.home, '.himmel', 'remote-setup'), { recursive: true });
  fs.mkdirSync(f.bin, { recursive: true });
  const stub = (name, body) => fs.writeFileSync(path.join(f.bin, name), `#!/bin/sh\n${body}\n`, { mode: 0o755 });
  stub('systemctl', `[ "$1 $2 $3" = "--user is-active ${UNIT}" ] || exit 1\n[ -f "${f.active}" ] && { echo active; exit 0; }\necho inactive\nexit 3`);
  // launchctl print exits 0 for a loaded job; only a running one prints a pid
  stub('launchctl', `[ "$1" = print ] || exit 1\n[ -f "${f.active}" ] && { printf 'job = {\\n\\tstate = running\\n\\tpid = 4242\\n}\\n'; exit 0; }\n[ -f "${f.loaded}" ] && { printf 'job = {\\n\\tstate = not running\\n}\\n'; exit 0; }\nexit 113`);
  f.env = Object.assign({}, process.env, { HOME: f.home, PATH: `${f.bin}${path.delimiter}${process.env.PATH}` });
  delete f.env.CLAUDECODE;
  f.setPeers = (peers) => fs.writeFileSync(path.join(f.home, '.himmel', 'remote-setup', 'peers-confirmed.json'), JSON.stringify({ peers }));
  f.setUnitFile = (platform) => {
    const p = platform === 'darwin'
      ? path.join(f.home, 'Library', 'LaunchAgents', `${LABEL}.plist`)
      : path.join(f.home, '.config', 'systemd', 'user', UNIT);
    fs.mkdirSync(path.dirname(p), { recursive: true });
    fs.writeFileSync(p, 'unit\n');
  };
  f.setActive = (on) => { if (on) fs.writeFileSync(f.active, ''); else fs.rmSync(f.active, { force: true }); };
  f.setLoaded = (on) => { if (on) fs.writeFileSync(f.loaded, ''); else fs.rmSync(f.loaded, { force: true }); };
  return f;
}

const peer = (name, extra) => Object.assign({ name, peerBotId: '555000111', chatId: -1001234567890, confirmedAt: '2026-11-20T10:00:00Z' }, extra);
const run = (f, platform) => probes.runProbe(ITEM, { repoRoot: REPO, targetPath: REPO, scope: 'user', platform: platform || 'linux', env: f.env });

// The real status report over the real manifest, narrowed to this one item, with the fixture HOME in force.
function report(f) {
  const manifest = JSON.parse(fs.readFileSync(path.join(REPO, 'scripts', 'install', 'manifest.json'), 'utf8'));
  manifest.items = manifest.items.filter((i) => i.id === 'remote-peer');
  const answers = { role: 'adopter', tier: 'standard', scope: 'user', vault: { mode: 'default-template', path: '' }, handover: { mode: 'none', path: '' }, pluginSet: 'lean', lanes: [], alwaysOn: false };
  const prev = { HOME: process.env.HOME, PATH: process.env.PATH };
  process.env.HOME = f.env.HOME;
  process.env.PATH = f.env.PATH;
  try {
    return require('../lib/status-report.js').statusReport({ manifest, scope: 'user', targetPath: f.home, answers });
  } finally {
    process.env.HOME = prev.HOME;
    process.env.PATH = prev.PATH;
  }
}

test('remote_peer_na_when_never_started', () => {
  const f = fixture();
  const r = run(f);
  assert.equal(r.actual, 'absent');
  assert.equal(r.cleanAbsence, true, 'no record and no unit is a clean absence');
  // through the real status report it reads n/a, never red
  const row = report(f).items.find((i) => i.id === 'remote-peer');
  assert.ok(row, 'the item is reported');
  assert.equal(row.severity, 'n/a');
  assert.match(row.detail, /remote-setup\.sh peer/);
});

test('remote_peer_ok_when_poller_runs', () => {
  const f = fixture();
  f.setPeers([peer('goomal')]);
  f.setUnitFile('linux');
  f.setActive(true);
  const r = run(f);
  assert.equal(r.actual, 'present');
  assert.equal(r.detail, 'goomal: set up, poller running');
});

test('remote_peer_stopped_when_unit_inactive', () => {
  const f = fixture();
  f.setPeers([peer('goomal')]);
  f.setUnitFile('linux');
  f.setActive(false);
  const r = run(f);
  assert.equal(r.actual, 'degraded');
  assert.equal(r.detail, 'goomal: poller stopped');
  // a recorded peer with no unit at all is stopped too
  const g = fixture();
  g.setPeers([peer('goomal')]);
  assert.equal(run(g).detail, 'goomal: poller stopped');
});

test('remote_peer_darwin_reads_launchctl', () => {
  const f = fixture();
  f.setPeers([peer('goomal')]);
  f.setUnitFile('darwin');
  f.setActive(true);
  assert.equal(run(f, 'darwin').detail, 'goomal: set up, poller running');
  f.setActive(false);
  const r = run(f, 'darwin');
  assert.equal(r.actual, 'degraded');
  assert.equal(r.detail, 'goomal: poller stopped');
});

test('remote_peer_darwin_a_loaded_job_without_a_process_is_stopped', () => {
  const f = fixture();
  f.setPeers([peer('goomal')]);
  f.setUnitFile('darwin');
  f.setActive(false);
  f.setLoaded(true);
  const r = run(f, 'darwin');
  assert.equal(r.actual, 'degraded', 'launchctl print exits 0 for a loaded job, running or not');
  assert.equal(r.detail, 'goomal: poller stopped');
  // control: a job with a running process is present
  f.setActive(true);
  assert.equal(run(f, 'darwin').actual, 'present');
});

test('remote_peer_several_peers_list_each_and_the_worst_state_wins', () => {
  const f = fixture();
  f.setPeers([peer('goomal'), peer('yotam', { peerBotId: '555000222' })]);
  f.setUnitFile('linux');
  f.setActive(true);
  assert.equal(run(f).detail, 'goomal: set up, poller running; yotam: set up, poller running');
  f.setActive(false);
  const r = run(f);
  assert.equal(r.actual, 'degraded');
  assert.equal(r.detail, 'goomal: poller stopped; yotam: poller stopped');
});

test('remote_peer_unit_without_a_record_is_not_a_clean_absence', () => {
  const f = fixture();
  f.setUnitFile('linux');
  f.setActive(true);
  const r = run(f);
  assert.equal(r.actual, 'degraded');
  assert.ok(!r.cleanAbsence, 'an installed poller with no peer on record needs a look');
});

test('remote_peer_unreadable_record_is_degraded_with_no_bytes', () => {
  const f = fixture();
  fs.writeFileSync(path.join(f.home, '.himmel', 'remote-setup', 'peers-confirmed.json'), `{"peers": [ ${CANARY}`);
  const r = run(f);
  assert.equal(r.actual, 'degraded');
  assert.ok(!JSON.stringify(r).includes(CANARY));
});

test('remote_peer_query_failure_is_degraded_never_ok', () => {
  const f = fixture();
  f.setPeers([peer('goomal')]);
  f.setUnitFile('linux');
  fs.rmSync(path.join(f.bin, 'systemctl'));
  f.env.PATH = f.bin; // no systemctl anywhere
  const r = run(f);
  assert.equal(r.actual, 'degraded');
  assert.match(r.detail, /could not be read/);
});

test('remote_peer_no_peer_bytes', () => {
  const f = fixture();
  // a poller log and a chat title carrying a canary: neither may reach the item
  const stateDir = path.join(f.home, '.himmel', 'peer-bridge');
  fs.mkdirSync(stateDir, { recursive: true });
  fs.writeFileSync(path.join(stateDir, 'poller.log'), `${CANARY} chat title\n`);
  f.setPeers([peer('goomal', { chatTitle: CANARY, lastMessage: CANARY, peerUsername: CANARY })]);
  f.setUnitFile('linux');
  f.setActive(true);
  const r = run(f);
  assert.equal(r.actual, 'present');
  assert.ok(!JSON.stringify(r).includes(CANARY), 'no peer-derived byte in the result');
  assert.ok(!JSON.stringify(report(f)).includes(CANARY), 'nor in the status report');
});

test('remote_peer_hostile_username_rejected', () => {
  const hostile = [
    `${CANARY}\nINJECTED`, '../../etc/passwd', '<script>x</script>', 'UPPER', `a${'b'.repeat(40)}`, '-leading', '', 'x y',
  ];
  const control = fixture();
  control.setPeers([peer('goomal')]);
  control.setUnitFile('linux');
  control.setActive(true);
  assert.equal(run(control).actual, 'present', 'control: a valid name with the poller up reads ok');
  for (const name of hostile) {
    const f = fixture();
    f.setPeers([peer(name)]);
    f.setUnitFile('linux');
    f.setActive(true);
    const r = run(f);
    assert.notEqual(r.actual, 'present', `a record named ${JSON.stringify(name)} is never ok`);
    assert.ok(!JSON.stringify(r).includes(CANARY), 'the hostile name is never echoed');
    assert.ok(!JSON.stringify(r).includes('INJECTED'));
  }
  // a hostile id or chat id is refused the same way
  const f = fixture();
  f.setPeers([peer('goomal', { peerBotId: '55; rm -rf /' })]);
  f.setUnitFile('linux');
  f.setActive(true);
  assert.notEqual(run(f).actual, 'present');
});

test('remote_peer_reads_no_peer_bridge_dir', (t) => {
  const f = fixture();
  f.setPeers([peer('goomal')]);
  f.setUnitFile('linux');
  f.setActive(true);
  const fenced = [path.join(f.home, '.himmel', 'peer-bridge'), path.join(f.home, '.config', 'himmel', 'peer-bridge')];
  for (const d of fenced) {
    fs.mkdirSync(d, { recursive: true });
    fs.writeFileSync(path.join(d, 'peers.json'), '{}');
    fs.chmodSync(d, 0o000);
  }
  t.after(() => { for (const d of fenced) fs.chmodSync(d, 0o700); });
  // Mode 000 does not stop root, so also watch every fs call the probe makes.
  const touched = [];
  for (const m of ['readFileSync', 'readdirSync', 'statSync', 'existsSync', 'openSync', 'lstatSync', 'accessSync']) {
    const orig = fs[m];
    t.mock.method(fs, m, function (p, ...rest) { touched.push(String(p)); return orig.call(fs, p, ...rest); });
  }
  const r = run(f);
  assert.equal(r.actual, 'present');
  assert.deepEqual(touched.filter((p) => /[\\/](\.himmel|himmel)[\\/]peer-bridge([\\/]|$)/.test(p)), [], 'the probe never touches a peer-bridge state or key dir');
});

const STEPS = ['ourStationName', 'ourStationKey', 'groupChat', 'operatorChat', 'theirKey'];
const pairRow = (name, done, extra) => Object.assign({ name }, Object.fromEntries(STEPS.map((s, i) => [s, i < done])), extra);
const setPairing = (f, doc) => fs.writeFileSync(path.join(f.home, '.himmel', 'remote-setup', 'pairing.json'), typeof doc === 'string' ? doc : JSON.stringify(doc));
function running(peers, pairing) {
  const f = fixture();
  f.setPeers(peers);
  f.setUnitFile('linux');
  f.setActive(true);
  if (pairing !== undefined) setPairing(f, pairing);
  return f;
}

test('remote_peer_names_the_first_missing_pairing_step_per_peer', () => {
  const cases = [
    [0, 'our station name'],
    [1, 'our station key'],
    [2, 'the group chat'],
    [3, 'your chat with the peer bridge bot'],
    [4, 'their key'],
  ];
  for (const [done, label] of cases) {
    const r = run(running([peer('goomal')], { peers: [pairRow('goomal', done, undefined)] }));
    assert.equal(r.actual, 'present', 'a missing step is information, not a red row');
    assert.equal(r.detail, `goomal: set up, poller running, next pairing step: ${label}`);
  }
  const all = run(running([peer('goomal')], { peers: [pairRow('goomal', 5)] }));
  assert.equal(all.detail, 'goomal: set up, poller running, every pairing step done');
  const gap = run(running([peer('goomal')], { peers: [Object.assign(pairRow('goomal', 5), { ourStationKey: false })] }));
  assert.equal(gap.detail, 'goomal: set up, poller running, next pairing step: our station key');
});

test('remote_peer_pairing_step_is_named_for_each_peer_and_when_the_poller_is_stopped', () => {
  const f = running([peer('goomal'), peer('yotam', { peerBotId: '555000222' })], { peers: [pairRow('yotam', 2), pairRow('goomal', 5)] });
  assert.equal(run(f).detail, 'goomal: set up, poller running, every pairing step done; yotam: set up, poller running, next pairing step: the group chat');
  f.setActive(false);
  assert.equal(run(f).detail, 'goomal: poller stopped, every pairing step done; yotam: poller stopped, next pairing step: the group chat');
});

test('remote_peer_no_pairing_record_or_no_row_leaves_the_detail_as_it_was', () => {
  assert.equal(run(running([peer('goomal')])).detail, 'goomal: set up, poller running');
  assert.equal(run(running([peer('goomal')], { peers: [pairRow('other', 1)] })).detail, 'goomal: set up, poller running');
  assert.equal(run(running([peer('goomal')], { peers: [] })).detail, 'goomal: set up, poller running');
});

test('remote_peer_pairing_record_bad_shape_is_degraded_and_never_echoed', () => {
  const bad = [
    `{"peers": [ ${CANARY}`,
    { peers: [pairRow(`${CANARY}\nINJECTED`, 1)] },
    { peers: [pairRow('goomal', 1, { groupChat: CANARY })] },
    { peers: [pairRow('goomal', 1, { groupChat: 1 })] },
    { peers: [pairRow('goomal', 1, { token: CANARY })] },
    { peers: [pairRow('goomal', 1)], extra: CANARY },
    { peers: CANARY },
    [pairRow('goomal', 1)],
  ];
  for (const doc of bad) {
    const r = run(running([peer('goomal')], doc));
    assert.equal(r.actual, 'degraded', `${JSON.stringify(doc)} is refused`);
    assert.match(r.detail, /pairing/);
    assert.ok(!JSON.stringify(r).includes(CANARY), 'no byte of a bad record is echoed');
    assert.ok(!JSON.stringify(r).includes('INJECTED'));
  }
  assert.equal(run(running([peer('goomal')], { peers: [pairRow('goomal', 1)] })).actual, 'present');
});

test('remote_peer_pairing_status_item_reaches_the_status_report', () => {
  const f = running([peer('goomal')], { peers: [pairRow('goomal', 1)] });
  const row = report(f).items.find((i) => i.id === 'remote-peer');
  assert.match(row.detail, /next pairing step: our station key/);
});

test('remote_peer_reads_the_pairing_record_and_no_peer_bridge_dir', (t) => {
  const f = running([peer('goomal')], { peers: [pairRow('goomal', 1)] });
  const touched = [];
  for (const m of ['readFileSync', 'readdirSync', 'statSync', 'existsSync', 'openSync', 'lstatSync', 'accessSync']) {
    const orig = fs[m];
    t.mock.method(fs, m, function (p, ...rest) { touched.push(String(p)); return orig.call(fs, p, ...rest); });
  }
  const r = run(f);
  assert.match(r.detail, /next pairing step/);
  assert.ok(touched.some((p) => p.endsWith(path.join('remote-setup', 'pairing.json'))), 'the record is read');
  assert.deepEqual(touched.filter((p) => /[\\/](\.himmel|himmel)[\\/]peer-bridge([\\/]|$)/.test(p)), [], 'the probe never touches a peer-bridge state or key dir');
});

test('manifest_lint_accepts_remote_peer', () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(REPO, 'scripts', 'install', 'manifest.json'), 'utf8'));
  const item = manifest.items.find((i) => i.id === 'remote-peer');
  assert.ok(item, 'manifest.json has the remote-peer entry');
  assert.deepEqual(item.scopes, ['user']);
  assert.deepEqual(item.profiles, ['core', 'luna', 'all'], 'every profile');
  assert.deepEqual(item.probe, { type: 'remote-peer' });
  const lint = spawnSync(process.execPath, [path.join(REPO, 'scripts', 'install', 'manifest-lint.mjs')], { encoding: 'utf8', cwd: REPO });
  assert.equal(lint.status, 0, lint.stdout + lint.stderr);
});

test('remote_peer_is_in_exactly_one_feed_bundle', () => {
  const lint = spawnSync(process.execPath, [path.join(REPO, 'scripts', 'install', 'bundle-registry-lint.mjs')], { encoding: 'utf8', cwd: REPO });
  assert.equal(lint.status, 0, lint.stdout + lint.stderr);
  const bundles = JSON.parse(fs.readFileSync(path.join(REPO, 'scripts', 'himmelctl', 'lib', 'feed-bundles.json'), 'utf8')).bundles;
  assert.equal(bundles.filter((b) => b.rows.includes('remote-peer')).length, 1);
});
