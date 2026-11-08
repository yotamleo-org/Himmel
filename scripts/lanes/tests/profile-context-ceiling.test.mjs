// profile ceilings must reach the launchers; malformed input refuses.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import * as PP from '../plugin-profiles.mjs';
import { BASH_BIN } from './lib/resolve-bash.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '../../..');
const registry = () => ({
  floor: ['qmd@himmel'], catalog: ['qmd@himmel'], profiles: {
    operator: null,
    'worker-impl': { enable: [], contextBudget: 35000, contextMode: 'standard', autocompact: 200000 },
    chief: { enable: [], contextBudget: 50000, contextMode: 'standard', autocompact: 200000 },
    design: { enable: [], contextBudget: 50000, contextMode: '1m', autocompact: 400000 },
  },
});
// the arming gate lints every brief (description + Prior art line).
const BRIEF_HEAD = '---\ndescription: hermetic fixture\n---\n> **Prior art:** none found (qmd -c jira-himmel "fixture")\n';
function fixture(t, reg = registry()) {
  const dir = mkdtempSync(join(tmpdir(), 'profile-ceiling-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  mkdirSync(join(dir, 'config'));
  mkdirSync(join(dir, 'handovers'));
  writeFileSync(join(dir, 'registry.json'), JSON.stringify(reg));
  writeFileSync(join(dir, 'brief.md'), BRIEF_HEAD + '# Hermetic fixture\n');
  return { dir, env: { PATH: process.env.PATH, HOME: dir, CLAUDE_CONFIG_DIR: join(dir, 'config'),
    PLUGIN_PROFILES_REGISTRY: join(dir, 'registry.json'), HANDOVER_DIR: join(dir, 'handovers'),
    WORKER_SESSION_REPO: dir, HEADED_ARM_REPO: dir, HIMMELCTL_CACHE_DIR: join(dir, 'cache'),
    HIMMEL_DENIAL_ACK_DIR: join(dir, 'acks'), XDG_RUNTIME_DIR: dir,
    // The fixture dir is no git work tree; the launch guard would refuse it.
    UNGUARDED_LAUNCH_OK: '1' } };
}
function launch(f, profile, extra = {}) {
  return spawnSync(BASH_BIN, [join(ROOT, 'scripts/handover/chief-kit/headed-arm-worker.sh'),
    '--dry-run', '--profile', profile, 'HIMMEL-4021-fixture', join(f.dir, 'brief.md'),
    join(f.dir, 'signal'), '99999999999', join(f.dir, 'launch.log'), 'claude-sonnet-5-5'],
  { cwd: f.dir, env: { ...f.env, ...extra }, encoding: 'utf8', timeout: 20000 });
}

test('context resolver keeps legacy defaults without widening settings JSON', () => {
  const r = registry();
  delete r.profiles['worker-impl'].autocompact;
  delete r.profiles['worker-impl'].contextMode;
  assert.equal(typeof PP.contextForProfile, 'function');
  assert.deepEqual(PP.contextForProfile(r, 'worker-impl'), { contextMode: 'standard', autocompact: 200000 });
  assert.deepEqual(PP.contextForProfile(r, 'operator'), { contextMode: 'standard', autocompact: 200000 });
  // No context field leaks into the settings; the only addition is the default Artifact deny.
  assert.deepEqual(PP.resolveProfile(r, 'worker-impl'), { enabledPlugins: { 'qmd@himmel': true }, permissions: { deny: ['Artifact'] } });
});
test('composed profile ceiling takes the explicitly declared 1m member', () => {
  assert.equal(typeof PP.contextForProfile, 'function');
  assert.deepEqual(PP.contextForProfile(registry(), 'worker-impl,design'), { contextMode: '1m', autocompact: 400000 });
  assert.throws(() => PP.contextForProfile(registry(), 'missing'));
  assert.throws(() => PP.contextForProfile(registry(), 'constructor'));
});
for (const [field, value] of [['autocompact', '400000'], ['autocompact', 200001],
  ['autocompact', 199999], ['autocompact', null], ['autocompact', 200000.5], ['contextMode', 'auto'], ['contextMode', null]]) {
  test(`validator refuses unsafe standard ${field}=${JSON.stringify(value)}`, () => {
    const r = registry(); r.profiles['worker-impl'][field] = value;
    assert.ok(PP.validateRegistry(r).some((e) => e.includes(field)), 'invalid context field was accepted');
  });
}
test('a standard profile may declare a Sonnet-only ceiling up to 850000 and a context guard', () => {
  const r = registry();
  Object.assign(r.profiles['worker-impl'], { sonnetAutocompact: 850000, sonnetContextGuard: 'handoff' });
  assert.deepEqual(PP.validateRegistry(r), []);
  assert.deepEqual(PP.contextForProfile(r, 'worker-impl'),
    { contextMode: 'standard', autocompact: 200000, sonnetAutocompact: 850000, sonnetContextGuard: 'handoff' });
  assert.deepEqual(PP.contextForProfile(registry(), 'worker-impl'), { contextMode: 'standard', autocompact: 200000 });
});
for (const [field, value] of [['sonnetAutocompact', 850001], ['sonnetAutocompact', 199999], ['sonnetAutocompact', '850000'],
  ['sonnetAutocompact', 300000.5], ['sonnetContextGuard', 'none'], ['sonnetContextGuard', 'bogus'], ['sonnetContextGuard', null],
  ['sonnetContextShare', 0], ['sonnetContextShare', 101], ['sonnetContextShare', 73.5], ['sonnetContextShare', '73']]) {
  test(`validator refuses ${field}=${JSON.stringify(value)}`, () => {
    const r = registry(); r.profiles['worker-impl'][field] = value;
    assert.ok(PP.validateRegistry(r).some((e) => e.includes(field)), 'invalid Sonnet field was accepted');
  });
}
test('a standard profile may declare an Opus-only ceiling up to 850000 and a context guard', () => {
  const r = registry();
  Object.assign(r.profiles['worker-impl'], { opusAutocompact: 850000, opusContextGuard: 'handoff', opusContextShare: 87 });
  assert.deepEqual(PP.validateRegistry(r), []);
  assert.deepEqual(PP.contextForProfile(r, 'worker-impl'),
    { contextMode: 'standard', autocompact: 200000, opusAutocompact: 850000, opusContextGuard: 'handoff', opusContextShare: 87 });
});
for (const [field, value] of [['opusAutocompact', 850001], ['opusAutocompact', 199999], ['opusAutocompact', '850000'],
  ['opusAutocompact', 300000.5], ['opusContextGuard', 'none'], ['opusContextGuard', 'bogus'], ['opusContextGuard', null],
  ['opusContextShare', 0], ['opusContextShare', 101], ['opusContextShare', 87.5], ['opusContextShare', '87']]) {
  test(`validator refuses ${field}=${JSON.stringify(value)}`, () => {
    const r = registry(); r.profiles['worker-impl'][field] = value;
    assert.ok(PP.validateRegistry(r).some((e) => e.includes(field)), 'invalid Opus field was accepted');
  });
}
const OPUS = (guard) => ({ opusAutocompact: 850000, opusContextGuard: guard, opusContextShare: 87 });
test('the shipped registry sets 850k per profile: impl hands off, eval compacts, docs stays at 200k', () => {
  const real = PP.loadRegistry();
  assert.deepEqual(PP.validateRegistry(real), []);
  const ctx = (name) => PP.contextForProfile(real, name);
  assert.deepEqual(ctx('worker-impl'), { contextMode: 'standard', autocompact: 200000, sonnetAutocompact: 850000, sonnetContextGuard: 'handoff', sonnetContextShare: 73, ...OPUS('handoff') });
  assert.deepEqual(ctx('worker-eval'), { contextMode: 'standard', autocompact: 200000, sonnetAutocompact: 850000, sonnetContextGuard: 'compact', sonnetContextShare: 73, ...OPUS('compact') });
  assert.deepEqual(ctx('worker-docs'), { contextMode: 'standard', autocompact: 200000, ...OPUS('handoff') });
});
test('decision 751: every worker profile carries the Opus numbers, and no other profile does', () => {
  const real = PP.loadRegistry();
  const carrying = Object.entries(real.profiles).filter(([, spec]) => spec?.opusAutocompact !== undefined).map(([name]) => name).sort();
  assert.deepEqual(carrying, ['worker-bus', 'worker-docs', 'worker-e2e', 'worker-eval', 'worker-impl', 'worker-vm']);
  for (const name of carrying) {
    assert.equal(real.profiles[name].opusAutocompact, 850000, name);
    assert.equal(real.profiles[name].opusContextShare, 87, name);
  }
});
test('share 87 of the 850000 ceiling is exactly 740000 on the 1M window, as the guard rounds it', () => {
  const window = 1000000;
  const thresholdPct = (share) => Math.floor((share * 850000 + window - 1) / window);
  assert.equal(thresholdPct(87) * window / 100, 740000);
  assert.equal(thresholdPct(88) * window / 100, 750000);
});
test('worker launcher reads standard ceiling from the profile', (t) => {
  const result = launch(fixture(t), 'worker-impl');
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /autocompact=200000/);
});
test('worker launcher reads a numeric design ceiling rather than hard-coding auto', (t) => {
  const result = launch(fixture(t), 'design');
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /autocompact=400000/);
  assert.match(result.stdout, /context=1m \(profile design contextMode 1m\)/);
  assert.doesNotMatch(result.stdout, /operator-ruling/);
});
test('brief explanation alone does not elevate a standard profile', (t) => {
  const f = fixture(t);
  writeFileSync(join(f.dir, 'brief.md'), BRIEF_HEAD + '> **Context:** 1m — operator-ruling: fixture authorization\n');
  const result = launch(f, 'worker-impl');
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /autocompact=200000/);
});
test('WORKER_SESSION_CONTEXT plus a brief explanation permits the sanctioned override', (t) => {
  const f = fixture(t);
  writeFileSync(join(f.dir, 'brief.md'), BRIEF_HEAD + '> **Context:** 1m — operator-ruling: fixture authorization\n');
  const result = launch(f, 'worker-impl', { WORKER_SESSION_CONTEXT: '1m' });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /autocompact=auto/);
});
test('a design profile still refuses WORKER_SESSION_CONTEXT without a brief explanation', (t) => {
  const result = launch(fixture(t), 'design', { WORKER_SESSION_CONTEXT: '1m' });
  assert.equal(result.status, 2, result.stdout + result.stderr);
});
test('bare WORKER_SESSION_CONTEXT=1m on a standard profile remains refused', (t) => {
  const result = launch(fixture(t), 'worker-impl', { WORKER_SESSION_CONTEXT: '1m' });
  assert.equal(result.status, 2, result.stdout + result.stderr);
});
test('worker launcher refuses malformed autocompact even on dry-run', (t) => {
  const r = registry(); r.profiles.design.autocompact = '400000';
  const result = launch(fixture(t, r), 'design');
  assert.equal(result.status, 2, result.stdout + result.stderr);
  assert.match(result.stderr, /autocompact/);
});
for (const extra of [
  { HEADED_ARM_CONTEXT_PROFILE: 'design' },
  { HEADED_ARM_CONTEXT_PROFILE: 'design', HEADED_ARM_WORKER_PROFILES: join(ROOT, 'scripts/lanes/plugin-profiles.mjs') },
]) {
  test(`direct console ignores ambient profile inputs ${JSON.stringify(extra)}`, (t) => {
    const f = fixture(t);
    // Dry-run validates these binaries but never executes them.
    f.env.KONSOLE_CMD = BASH_BIN;
    f.env.PGREP_CMD = BASH_BIN;
    const launchConsole = (env) => spawnSync(BASH_BIN,
      [join(ROOT, 'scripts/handover/headed-arm.sh'), '--dry-run',
        'HIMMEL-4094-chief-fixture', join(f.dir, 'brief.md'), join(f.dir, 'signal'),
        '99999999999', join(f.dir, 'launch.log'), 'claude-sonnet-5-5'],
      { cwd: f.dir, env, encoding: 'utf8', timeout: 20000 });
    const baseline = launchConsole(f.env);
    const result = launchConsole({ ...f.env, ...extra });
    assert.equal(baseline.status, 0, baseline.stdout + baseline.stderr);
    assert.match(baseline.stdout, /context=1m \(default\)/);
    assert.match(baseline.stdout, /--autocompact auto/);
    assert.equal(result.status, baseline.status, result.stdout + result.stderr);
    assert.equal(result.stdout, baseline.stdout);
    assert.equal(result.stderr, baseline.stderr);
  });
}

test('headed console launcher validates the profile before rendering argv', (t) => {
  const r = registry(); r.profiles.chief.autocompact = '200000';
  const f = fixture(t, r);
  const result = spawnSync(BASH_BIN, [join(ROOT, 'scripts/handover/headed-arm.sh'), '--dry-run',
    'HIMMEL-4021-chief-fixture', join(f.dir, 'brief.md'), join(f.dir, 'signal'),
    '99999999999', join(f.dir, 'launch.log')], { cwd: f.dir, env: f.env, encoding: 'utf8' });
  assert.equal(result.status, 2, result.stdout + result.stderr);
  assert.match(result.stderr, /autocompact/);
});
