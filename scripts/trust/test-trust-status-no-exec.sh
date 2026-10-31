#!/usr/bin/env bash
# The installed CLI inspects project recorders as data, never code.
set -uo pipefail
root="$(git rev-parse --show-toplevel)" || exit 1
if command -v cygpath >/dev/null 2>&1; then root="$(cygpath -m "$root")" || exit 1; fi
node - "$root" <<'NODE'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const root = process.argv[2];
const cli = path.join(root, 'scripts', 'himmelctl', 'bin.js');
const trustedRecorder = path.join(root, 'scripts', 'trust', 'shadow-ledger.mjs');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'trust-status-no-exec-'));
const baseline = JSON.stringify({ permissions: { allow: ['Bash(git status)'] } }, null, 2) + '\n';
const verbs = ['pre', 'post', 'postfail', 'denied', 'permreq', 'notify', 'heartbeat'];
const reply = `process.stdout.write(${JSON.stringify(JSON.stringify({ recorder: 'himmel-shadow-ledger', verbs }))});\n`;
const home = path.join(tmp, 'home');
fs.mkdirSync(home);
const env = {
  ...process.env,
  HOME: home,
  USERPROFILE: home,
  HIMMELCTL_REPO_ROOT: root,
  HIMMELCTL_CACHE_DIR: path.join(home, 'cache'),
  HIMMEL_LUNA_CONFIG_PATH: path.join(home, 'luna-config.json'),
  HIMMEL_PROVENANCE_DIR: path.join(home, 'provenance'),
  HIMMEL_TRUST_LEDGER_DIR: path.join(home, 'ledger'),
};
function fixture(name, body) {
  const project = path.join(tmp, name);
  fs.mkdirSync(path.join(project, '.claude'), { recursive: true });
  fs.writeFileSync(path.join(project, '.claude', 'settings.json'), baseline);
  if (body !== undefined) {
    fs.mkdirSync(path.join(project, 'scripts', 'trust'), { recursive: true });
    fs.writeFileSync(path.join(project, 'scripts', 'trust', 'shadow-ledger.mjs'), body);
  }
  return project;
}
function snapshot(dir) {
  return fs.readdirSync(dir).sort().map((name) => {
    const file = path.join(dir, name);
    return [name, fs.statSync(file).isDirectory() ? snapshot(file) : fs.readFileSync(file)];
  });
}
// A different cwd proves an installed CLI inspects the explicitly selected project.
const cwd = fixture('not-the-target');
function run(project, verb) {
  const result = spawnSync(process.execPath, [cli, 'trust', verb], {
    cwd, env: { ...env, CLAUDE_PROJECT_DIR: project }, encoding: 'utf8', timeout: 15000,
  });
  assert.equal(result.error, undefined);
  assert.ok(result.stdout.includes(path.join(project, '.claude', 'settings.json')), result.stdout);
  return result;
}
function status(project) {
  const before = snapshot(project);
  const result = run(project, 'status');
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(snapshot(project), before, 'status must not change project data or leave its lock');
  return result.stdout;
}
function unverified(output) {
  assert.match(output, /UNVERIFIED/);
  assert.doesNotMatch(output, /Missing:|trust on.*REFUSE|is missing verbs/);
}
try {
  // Reintroducing status-time execution must fail even if the recorder claims all verbs.
  const project = fixture('sentinel', '// filled below\n');
  const sentinel = path.join(tmp, 'recorder-ran');
  const recorder = path.join(project, 'scripts', 'trust', 'shadow-ledger.mjs');
  const markedReply = `import fs from 'node:fs';\nfs.writeFileSync(${JSON.stringify(sentinel)}, 'ran');\n${reply}`;
  fs.writeFileSync(recorder, markedReply);
  const output = status(project);
  assert.equal(fs.existsSync(sentinel), false, 'trust status must never launch the project recorder');
  unverified(output);
  console.log('ok 1 - status never launches a sentinel recorder claiming every capability');

  const valid = fixture('valid', fs.readFileSync(trustedRecorder));
  const validOutput = status(valid);
  assert.match(validOutput, /0\/7 entries wired/);
  assert.doesNotMatch(validOutput, /UNVERIFIED|no recorder|Missing:|REFUSE/);
  assert.equal(run(valid, 'on').status, 0);
  assert.match(status(valid), /7\/7 entries wired/);
  assert.equal(run(valid, 'off').status, 0);
  assert.equal(fs.readFileSync(path.join(valid, '.claude', 'settings.json'), 'utf8'), baseline);
  console.log('ok 2 - trusted recorder status and on/off byte-reversible round trip');

  const missing = fixture('missing');
  assert.match(status(missing), /no recorder.*trust on.*REFUSE/);
  const refusedMissing = run(missing, 'on');
  assert.equal(refusedMissing.status, 1);
  assert.match(refusedMissing.stderr, /no recorder/);
  assert.equal(run(missing, 'off').status, 0);
  assert.equal(fs.readFileSync(path.join(missing, '.claude', 'settings.json'), 'utf8'), baseline);
  console.log('ok 3 - missing recorder is reported; on refuses and off remains available');

  const incompatible = fixture('incompatible', '// old recorder: no capabilities or verbs\n');
  unverified(status(incompatible));
  const refusedOld = run(incompatible, 'on');
  assert.equal(refusedOld.status, 1);
  assert.match(refusedOld.stderr, /did not prove it can record every verb/);
  assert.equal(fs.readFileSync(path.join(incompatible, '.claude', 'settings.json'), 'utf8'), baseline);
  console.log('ok 4 - incompatible recorder is unverified on status and refused by on handshake');

  // Unknown is not necessarily incompatible: only explicit on may ask it to run.
  assert.equal(run(project, 'on').status, 0);
  assert.equal(fs.readFileSync(sentinel, 'utf8'), 'ran', 'on retains its executable handshake');
  fs.unlinkSync(sentinel);
  unverified(status(project));
  assert.equal(fs.existsSync(sentinel), false);
  assert.equal(run(project, 'off').status, 0);
  assert.equal(fs.existsSync(sentinel), false, 'off must never handshake');
  assert.equal(fs.readFileSync(path.join(project, '.claude', 'settings.json'), 'utf8'), baseline);
  console.log('ok 5 - different capable recorder is unverified, on handshakes, off never runs it');

  // Dead wiring must remain removable after the recorder disappears or regresses.
  for (const body of [undefined, '// incapable\n']) {
    assert.equal(run(valid, 'on').status, 0);
    const file = path.join(valid, 'scripts', 'trust', 'shadow-ledger.mjs');
    if (body === undefined) fs.unlinkSync(file);
    else fs.writeFileSync(file, body);
    assert.equal(run(valid, 'off').status, 0);
    assert.equal(fs.readFileSync(path.join(valid, '.claude', 'settings.json'), 'utf8'), baseline);
    fs.writeFileSync(file, fs.readFileSync(trustedRecorder));
  }
  console.log('ok 6 - off removes dead wiring with missing or incompatible recorder');
  assert.equal(fs.readFileSync(path.join(cwd, '.claude', 'settings.json'), 'utf8'), baseline);
} finally {
  fs.rmSync(tmp, { recursive: true, force: true });
}
NODE
