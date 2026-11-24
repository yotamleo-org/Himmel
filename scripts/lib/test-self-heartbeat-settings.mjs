// Tests for the C0p self-heartbeat settings reader. Every fixture lives in a temp dir this file
// owns and removes; no live user, project or plugin settings are read.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtempSync, rmSync, symlinkSync, writeFileSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { readSelfHeartbeatEffectiveness } from './self-heartbeat-settings.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const SUT = join(HERE, 'self-heartbeat-settings.mjs');
const T = mkdtempSync(join(tmpdir(), 'self-heartbeat-settings-'));
process.on('exit', () => rmSync(T, { recursive: true, force: true }));

// Canonical entry shape, as scripts/observability/wire-session-telemetry-hooks.mjs writes it:
// PostToolUse, matcher null, a queue-lock.sh self-heartbeat command.
const HB = 'bash "/repo/scripts/handover/queue-lock.sh" self-heartbeat';
const wiredGroup = (extra = {}) => ({ ...extra, hooks: [{ type: 'command', command: HB }] });
const wired = (matcherField = {}) => ({ hooks: { PostToolUse: [wiredGroup(matcherField)] } });

let seq = 0;
function dir() {
  const d = join(T, `case-${seq++}`);
  mkdirSync(d);
  return d;
}
// Writes one layer file (body: object, string, or undefined for an absent file) and returns its descriptor.
function layer(name, body, d = dir()) {
  const path = join(d, `${name}.json`);
  if (body !== undefined) writeFileSync(path, typeof body === 'string' ? body : JSON.stringify(body));
  return { name, path };
}
const sha = (text) => createHash('sha256').update(text).digest('hex');

test('no layer files present: ineffective, no native hook', () => {
  const d = dir();
  const r = readSelfHeartbeatEffectiveness({ layers: [layer('user', undefined, d), layer('project', undefined, d)] });
  assert.equal(r.state, 'ineffective');
  assert.equal(r.reason, 'no-native-heartbeat-hook');
  assert.deepEqual(r.provenance.layers.map((l) => l.status), ['absent', 'absent']);
});

test('empty layers array: ineffective, not unknown', () => {
  assert.equal(readSelfHeartbeatEffectiveness({ layers: [] }).state, 'ineffective');
});

test('null API input is unknown rather than throwing', () => {
  assert.equal(readSelfHeartbeatEffectiveness(null).state, 'unknown');
});

test('the C85 canonical wired entry in each layer counts (user, project, local, generated)', () => {
  for (const name of ['user', 'project', 'local', 'generated']) {
    const d = dir();
    const r = readSelfHeartbeatEffectiveness({ layers: [layer(name, wired(), d)] });
    assert.equal(r.state, 'effective', name);
    assert.equal(r.reason, 'native-heartbeat-hook-wired', name);
  }
});

test('layers are read low to high; a wired lower layer survives an unrelated higher layer', () => {
  const d = dir();
  const r = readSelfHeartbeatEffectiveness({
    layers: [layer('user', wired(), d), layer('project', { theme: 'dark' }, d), layer('local', { other: 1 }, d)],
  });
  assert.equal(r.state, 'effective');
  assert.deepEqual(r.provenance.layers.map((l) => l.status), ['read', 'read', 'read']);
});

test('matcher absent, empty, null and "*" all count (matches the C85 bash scan)', () => {
  const groups = [{}, { matcher: '' }, { matcher: null }, { matcher: '*' }];
  for (const g of groups) {
    const r = readSelfHeartbeatEffectiveness({ layers: [layer('project', { hooks: { PostToolUse: [wiredGroup(g)] } })] });
    assert.equal(r.state, 'effective', JSON.stringify(g));
  }
});

test('a matched-only group does not count, nor does a command with only one of the two strings', () => {
  const cases = [
    { hooks: { PostToolUse: [wiredGroup({ matcher: 'Agent' })] } },
    { hooks: { PostToolUse: [wiredGroup({ matcher: 'Bash|Edit' })] } },
    { hooks: { PostToolUse: [{ hooks: [{ type: 'command', command: 'bash queue-lock.sh acquire' }] }] } },
    { hooks: { PostToolUse: [{ hooks: [{ type: 'command', command: 'bash self-heartbeat.sh' }] }] } },
  ];
  for (const body of cases) {
    const r = readSelfHeartbeatEffectiveness({ layers: [layer('project', body)] });
    assert.equal(r.state, 'ineffective', JSON.stringify(body));
    assert.equal(r.reason, 'no-native-heartbeat-hook');
  }
});

const ROUTED_HB = 'if [ -f "$CLAUDE_PROJECT_DIR/scripts/lib/run-node.sh" ]; then command -p sh "$CLAUDE_PROJECT_DIR/scripts/lib/run-node.sh" '
  + '"$CLAUDE_PROJECT_DIR/scripts/hooks/run-hook-with-bash.js" "$CLAUDE_PROJECT_DIR/scripts/handover/queue-lock.sh" self-heartbeat; '
  + 'else node "$CLAUDE_PROJECT_DIR/scripts/hooks/run-hook-with-bash.js" "$CLAUDE_PROJECT_DIR/scripts/handover/queue-lock.sh" self-heartbeat; fi';
const withCommand = (hook) => ({ hooks: { PostToolUse: [{ hooks: [hook] }] } });

test('X07-7: both emitted command shapes (plain and routed) are effective, as is the tracked project settings file', () => {
  const shapes = [
    HB,
    'bash scripts/handover/queue-lock.sh self-heartbeat',
    'bash /repo/scripts/handover/queue-lock.sh self-heartbeat',
    ROUTED_HB,
  ];
  for (const command of shapes) {
    const r = readSelfHeartbeatEffectiveness({ layers: [layer('project', withCommand({ type: 'command', command }))] });
    assert.equal(r.state, 'effective', command);
  }
  const tracked = readSelfHeartbeatEffectiveness({ layers: [{ name: 'project', path: join(HERE, '..', '..', '.claude', 'settings.json') }] });
  assert.equal(tracked.state, 'effective', 'the tracked .claude/settings.json heartbeat entry reads effective');
});

test('X07-7: a hook that only echoes both words, or has a non-command type, reads unknown, not effective', () => {
  const bad = [
    { type: 'command', command: "echo 'queue-lock.sh self-heartbeat is disabled' >> /tmp/log" },
    { type: 'command', command: 'true # queue-lock.sh self-heartbeat' },
    { type: 'command', command: `${HB} && rm -rf /tmp/x` },
    { type: 'command', command: `echo ${HB}` },
    { type: 'command', command: 'bash $(evil)/queue-lock.sh self-heartbeat' },
    { type: 'prompt', command: 'queue-lock.sh self-heartbeat' },
    { type: 'prompt', command: HB },
    { command: HB },
    { type: 'command', command: ROUTED_HB.replace('; fi', '; echo x; fi') },
  ];
  for (const hook of bad) {
    const r = readSelfHeartbeatEffectiveness({ layers: [layer('project', withCommand(hook))] });
    assert.equal(r.state, 'unknown', JSON.stringify(hook));
    assert.equal(r.reason, 'layer-invalid-field', JSON.stringify(hook));
  }
});

test('X07-7: a command naming only one of the two words stays ineffective, not unknown (the control for the rows above)', () => {
  for (const command of ['true', 'bash queue-lock.sh acquire', 'bash self-heartbeat.sh']) {
    const r = readSelfHeartbeatEffectiveness({ layers: [layer('project', withCommand({ type: 'prompt', command }))] });
    assert.equal(r.state, 'ineffective', command);
  }
});

test('disableAllHooks true in the highest defining layer is ineffective, even with a wired hook', () => {
  const d = dir();
  const r = readSelfHeartbeatEffectiveness({ layers: [layer('user', wired(), d), layer('local', { disableAllHooks: true }, d)] });
  assert.equal(r.state, 'ineffective');
  assert.equal(r.reason, 'disable-all-hooks');
});

test('a higher-layer disableAllHooks false overrides a user-layer true', () => {
  const d = dir();
  const r = readSelfHeartbeatEffectiveness({
    layers: [layer('user', { ...wired(), disableAllHooks: true }, d), layer('local', { disableAllHooks: false }, d)],
  });
  assert.equal(r.state, 'effective');
});

test('a higher-layer disableAllHooks true beats a lower false', () => {
  const d = dir();
  const r = readSelfHeartbeatEffectiveness({
    layers: [layer('user', { ...wired(), disableAllHooks: false }, d), layer('project', { disableAllHooks: true }, d)],
  });
  assert.equal(r.state, 'ineffective');
  assert.equal(r.reason, 'disable-all-hooks');
});

test('a user-layer disableAllHooks true with nothing higher setting it is ineffective', () => {
  const d = dir();
  const r = readSelfHeartbeatEffectiveness({ layers: [layer('user', { ...wired(), disableAllHooks: true }, d)] });
  assert.equal(r.state, 'ineffective');
  assert.equal(r.reason, 'disable-all-hooks');
});

test('unrelated valid settings properties are ignored', () => {
  const r = readSelfHeartbeatEffectiveness({
    layers: [layer('project', { ...wired(), permissions: { allow: ['Bash(ls)'] }, env: { A: 'b' }, model: 'x' })],
  });
  assert.equal(r.state, 'effective');
});

test('malformed JSON in a layer is unknown', () => {
  const r = readSelfHeartbeatEffectiveness({ layers: [layer('project', '{"hooks": ')] });
  assert.equal(r.state, 'unknown');
  assert.equal(r.reason, 'layer-malformed-json');
});

test('a malformed higher layer makes the result unknown even when a lower layer is wired', () => {
  const d = dir();
  const r = readSelfHeartbeatEffectiveness({ layers: [layer('user', wired(), d), layer('local', '[not json', d)] });
  assert.equal(r.state, 'unknown');
  assert.equal(r.reason, 'layer-malformed-json');
});

test('unreadable layers (a directory, a dangling symlink) are unknown, never absent', () => {
  const d = dir();
  const asDir = join(d, 'dir.json');
  mkdirSync(asDir);
  assert.equal(readSelfHeartbeatEffectiveness({ layers: [{ name: 'user', path: asDir }] }).reason, 'layer-not-regular-file');
  const dangling = join(d, 'dangling.json');
  symlinkSync(join(d, 'missing-target.json'), dangling);
  assert.equal(readSelfHeartbeatEffectiveness({ layers: [{ name: 'user', path: dangling }] }).state, 'unknown');
});

test('unsupported consumed field types are unknown', () => {
  const bad = [
    { disableAllHooks: 'true' },
    { hooks: [] },
    { hooks: { PostToolUse: {} } },
    { hooks: { PostToolUse: [{ matcher: 3, hooks: [] }] } },
    { hooks: { PostToolUse: [{ hooks: [{ type: 'command', command: 7 }] }] } },
    [],
  ];
  for (const body of bad) {
    const r = readSelfHeartbeatEffectiveness({ layers: [layer('project', body)] });
    assert.equal(r.state, 'unknown', JSON.stringify(body));
  }
});

test('invalid precedence input is unknown: unknown name, out of order, duplicate, relative path, no layers array', () => {
  const d = dir();
  const p = layer('project', wired(), d);
  assert.equal(readSelfHeartbeatEffectiveness({ layers: [{ name: 'home', path: p.path }] }).reason, 'unknown-precedence');
  assert.equal(readSelfHeartbeatEffectiveness({ layers: [layer('local', wired(), d), p] }).reason, 'unknown-precedence');
  assert.equal(readSelfHeartbeatEffectiveness({ layers: [p, p] }).reason, 'unknown-precedence');
  assert.equal(readSelfHeartbeatEffectiveness({ layers: [{ name: 'project', path: 'relative.json' }] }).reason, 'layer-path-not-absolute');
  assert.equal(readSelfHeartbeatEffectiveness({}).state, 'unknown');
});

test('a plugin-only hook file is ignored as non-native: ineffective, classified, never read', () => {
  const d = dir();
  const plugin = { name: 'plugin', path: layer('hooks', wired(), d).path };
  const r = readSelfHeartbeatEffectiveness({ layers: [plugin] });
  assert.equal(r.state, 'ineffective');
  assert.equal(r.reason, 'no-native-heartbeat-hook');
  assert.deepEqual(r.provenance.layers, [{ name: 'plugin', path: plugin.path, status: 'ignored-plugin' }]);
});

test('a plugin layer cannot override disableAllHooks or supply the native hook', () => {
  const d = dir();
  const plugin = { name: 'plugin', path: layer('hooks', { disableAllHooks: false, ...wired() }, d).path };
  const r = readSelfHeartbeatEffectiveness({ layers: [layer('user', { disableAllHooks: true }, d), plugin] });
  assert.equal(r.state, 'ineffective');
  assert.equal(r.reason, 'disable-all-hooks');
});

test('digest: a matching sha256 reads normally; a mismatch or an absent file with a digest is unknown', () => {
  const d = dir();
  const text = JSON.stringify(wired());
  const ok = layer('project', text, d);
  const good = readSelfHeartbeatEffectiveness({ layers: [{ ...ok, sha256: sha(text) }] });
  assert.equal(good.state, 'effective');
  assert.equal(good.provenance.layers[0].sha256, sha(text));
  assert.equal(readSelfHeartbeatEffectiveness({ layers: [{ ...ok, sha256: sha('other') }] }).reason, 'digest-mismatch');
  const absent = { name: 'user', path: join(d, 'nope.json'), sha256: sha(text) };
  assert.equal(readSelfHeartbeatEffectiveness({ layers: [absent] }).state, 'unknown');
  assert.equal(readSelfHeartbeatEffectiveness({ layers: [{ ...ok, sha256: 'XYZ' }] }).reason, 'digest-malformed');
});

test('importing the module has no effects: no output, no stdin read', () => {
  const url = pathToFileURL(SUT).href;
  const r = spawnSync(process.execPath, ['--input-type=module', '-e', `await import(${JSON.stringify(url)})`], {
    encoding: 'utf8',
    input: '',
  });
  assert.equal(r.status, 0);
  assert.equal(r.stdout, '');
  assert.equal(r.stderr, '');
});

test('CLI: one JSON object in, one JSON result out; exit 0 effective, 1 ineffective, 3 unknown', () => {
  const d = dir();
  const cli = (input) => spawnSync(process.execPath, [SUT], { encoding: 'utf8', input });
  const eff = cli(JSON.stringify({ layers: [layer('project', wired(), d)] }));
  assert.equal(eff.status, 0);
  assert.equal(JSON.parse(eff.stdout).state, 'effective');
  const ineff = cli(JSON.stringify({ layers: [layer('project', { theme: 1 }, d)] }));
  assert.equal(ineff.status, 1);
  assert.equal(JSON.parse(ineff.stdout).state, 'ineffective');
  const unk = cli('{"layers": [');
  assert.equal(unk.status, 3);
  assert.equal(JSON.parse(unk.stdout).state, 'unknown');
  assert.equal(unk.stdout.trim().split('\n').length, 1);
});

test('CLI never echoes settings content or raw parse errors', () => {
  const d = dir();
  const secret = 'SENTINEL-7f3a-do-not-print';
  const bad = layer('local', `{"disableAllHooks": "${secret}", "hooks": {"PostToolUse": [{"hooks":[{"command":"${secret}"}]}]}}`, d);
  const out = spawnSync(process.execPath, [SUT], { encoding: 'utf8', input: JSON.stringify({ layers: [bad] }) });
  assert.equal(out.status, 3);
  assert.equal(out.stdout.includes(secret), false);
  assert.equal(out.stderr.includes(secret), false);
  const garbled = spawnSync(process.execPath, [SUT], { encoding: 'utf8', input: `{"${secret}": ` });
  assert.equal(garbled.status, 3);
  assert.equal(garbled.stdout.includes(secret), false);
  assert.equal(JSON.parse(garbled.stdout).state, 'unknown');
});

test('CLI entry works through file and directory symlinks and a relative path', () => {
  const d = dir();
  const fileLink = join(d, 'reader.mjs');
  const dirLink = join(d, 'linked-lib');
  symlinkSync(SUT, fileLink);
  symlinkSync(HERE, dirLink, 'dir');
  const inputs = [
    { input: { layers: [layer('project', wired())] }, state: 'effective', rc: 0 },
    { input: { layers: [layer('project', undefined)] }, state: 'ineffective', rc: 1 },
    { input: { layers: [layer('project', '{')] }, state: 'unknown', rc: 3 },
  ];
  for (const entry of [fileLink, join(dirLink, 'self-heartbeat-settings.mjs'), './reader.mjs']) {
    for (const { input, state, rc } of inputs) {
      const out = spawnSync(process.execPath, [entry], { cwd: d, encoding: 'utf8', input: JSON.stringify(input) });
      assert.equal(out.status, rc, entry);
      assert.equal(out.stderr, '', entry);
      assert.equal(out.stdout.trim().split('\n').length, 1, entry);
      assert.equal(JSON.parse(out.stdout).state, state, entry);
    }
  }
});
