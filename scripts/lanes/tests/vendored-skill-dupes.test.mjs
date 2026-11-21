// scripts/lanes/tests/vendored-skill-dupes.test.mjs
// lean-skills@himmel / upstream-plugin overlap detector.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { writeFileSync, mkdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { makeTmpDir } from '../../lib/test-tmpdir.mjs';
import { findOverlap } from '../vendored-skill-dupes.mjs';

const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const CLI = join(dirname(fileURLToPath(import.meta.url)), '..', 'vendored-skill-dupes.mjs');

function settingsHome(enabledPlugins) {
  const home = makeTmpDir('vsd-home-');
  mkdirSync(join(home, '.claude'), { recursive: true });
  writeFileSync(join(home, '.claude', 'settings.json'), JSON.stringify({ enabledPlugins }));
  return home;
}

test('no overlap when only lean-skills@himmel is on', () => {
  const home = settingsHome({ 'lean-skills@himmel': true });
  const out = findOverlap({ home, cwd: '', configDir: '', repoRoot: REPO_ROOT });
  assert.deepEqual(out, []);
});

test('no overlap when lean-skills@himmel is off, even with both upstreams on', () => {
  const home = settingsHome({
    'lean-skills@himmel': false,
    'superpowers@claude-plugins-official': true,
    'mattpocock-skills@claude-plugins-official': true,
  });
  const out = findOverlap({ home, cwd: '', configDir: '', repoRoot: REPO_ROOT });
  assert.deepEqual(out, []);
});

test('no overlap when lean-skills@himmel is simply absent from settings', () => {
  const home = settingsHome({
    'superpowers@claude-plugins-official': true,
    'mattpocock-skills@claude-plugins-official': true,
  });
  const out = findOverlap({ home, cwd: '', configDir: '', repoRoot: REPO_ROOT });
  assert.deepEqual(out, []);
});

test('both overlaps reported when lean-skills and both upstream plugins are on', () => {
  const home = settingsHome({
    'lean-skills@himmel': true,
    'superpowers@claude-plugins-official': true,
    'mattpocock-skills@claude-plugins-official': true,
  });
  const out = findOverlap({ home, cwd: '', configDir: '', repoRoot: REPO_ROOT });
  assert.equal(out.length, 2, 'expected one result per enabled upstream source');

  const superpowers = out.find((o) => o.plugin === 'superpowers@claude-plugins-official');
  assert.ok(superpowers, 'superpowers overlap missing');
  assert.equal(superpowers.repo, 'obra/superpowers');
  assert.deepEqual(superpowers.skills, [
    'brainstorming',
    'executing-plans',
    'finishing-a-development-branch',
    'receiving-code-review',
    'requesting-code-review',
    'subagent-driven-development',
    'systematic-debugging',
    'test-driven-development',
    'using-git-worktrees',
    'verification-before-completion',
    'writing-plans',
    'writing-skills',
  ], 'expected exactly the 12 vendored superpowers skills, in sorted order');

  const mattpocock = out.find((o) => o.plugin === 'mattpocock-skills@claude-plugins-official');
  assert.ok(mattpocock, 'mattpocock-skills overlap missing (Defect B regression)');
  assert.equal(mattpocock.repo, 'mattpocock/skills');
  assert.deepEqual(mattpocock.skills, ['grilling']);
});

test('context7-mcp (himmel-authored, no upstream) is never reported as an overlap', () => {
  const home = settingsHome({
    'lean-skills@himmel': true,
    'superpowers@claude-plugins-official': true,
    'mattpocock-skills@claude-plugins-official': true,
  });
  const out = findOverlap({ home, cwd: '', configDir: '', repoRoot: REPO_ROOT });
  for (const o of out) assert.ok(!o.skills.includes('context7-mcp'), `${o.plugin} must not claim context7-mcp`);
});

test('a nearer settings layer\'s false overrides an outer layer\'s true', () => {
  const home = settingsHome({
    'lean-skills@himmel': true,
    'superpowers@claude-plugins-official': true,
  });
  const cwd = makeTmpDir('vsd-cwd-');
  mkdirSync(join(cwd, '.claude'), { recursive: true });
  writeFileSync(join(cwd, '.claude', 'settings.local.json'), JSON.stringify({
    enabledPlugins: { 'superpowers@claude-plugins-official': false },
  }));
  const out = findOverlap({ home, cwd, configDir: '', repoRoot: REPO_ROOT });
  assert.deepEqual(out, [], 'nearer false must suppress the overlap the outer true would have reported');
});

test('settings.local.json beats settings.json in the SAME directory', () => {
  const home = settingsHome({ 'lean-skills@himmel': true });
  const cwd = makeTmpDir('vsd-cwd-pair-');
  mkdirSync(join(cwd, '.claude'), { recursive: true });
  writeFileSync(join(cwd, '.claude', 'settings.json'), JSON.stringify({
    enabledPlugins: { 'superpowers@claude-plugins-official': true },
  }));
  writeFileSync(join(cwd, '.claude', 'settings.local.json'), JSON.stringify({
    enabledPlugins: { 'superpowers@claude-plugins-official': false },
  }));
  const out = findOverlap({ home, cwd, configDir: '', repoRoot: REPO_ROOT });
  assert.deepEqual(out, [], 'the local override must win over its sibling settings.json');
});

test('CLI: an explicit empty VENDORED_DUPES_CWD is honoured as "no cwd layers", not the real cwd', () => {
  const home = settingsHome({
    'lean-skills@himmel': true,
    'superpowers@claude-plugins-official': true,
    'mattpocock-skills@claude-plugins-official': true,
  });
  const run = spawnSync(process.execPath, [CLI, '--json'], {
    encoding: 'utf8',
    cwd: REPO_ROOT,
    env: {
      ...process.env,
      VENDORED_DUPES_HOME: home,
      VENDORED_DUPES_CWD: '',
      VENDORED_DUPES_CONFIG_DIR: '',
    },
  });
  assert.equal(run.status, 10, run.stderr);
  const out = JSON.parse(run.stdout);
  assert.equal(out.length, 2);
  assert.ok(out.some((o) => o.plugin === 'mattpocock-skills@claude-plugins-official'), 'mattpocock-skills must survive an empty-string cwd seam');
});
