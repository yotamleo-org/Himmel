// scripts/lanes/tests/humanizer-plugin.test.mjs
// humanizer ships as ONE opt-in himmel marketplace plugin, vendored at a pinned
// upstream commit, enabled in no profile (the operator turns it on by hand).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const REG = JSON.parse(readFileSync(join(ROOT, 'scripts', 'lanes', 'plugin-profiles.json'), 'utf8'));
const MP = JSON.parse(readFileSync(join(ROOT, 'marketplace', '.claude-plugin', 'marketplace.json'), 'utf8'));
const PLUGIN = join(ROOT, 'marketplace', 'plugins', 'humanizer');
const ID = 'humanizer@himmel';
const PIN = '225a6f39ac85f76ee48dbad772ea4abe4ed6c9d8';

test('humanizer@himmel is enabled in no base, floor or profile list', () => {
  assert.ok(!REG.base.includes(ID), 'base would put it in every leg');
  assert.ok(!REG.floor.includes(ID), 'floor would put it in every leg');
  for (const [name, p] of Object.entries(REG.profiles)) {
    assert.ok(!(p?.enable ?? []).includes(ID), `${name} must not enable ${ID}`);
  }
});

test('marketplace entry is a local MIT plugin whose VENDORED.md names the pinned upstream commit', () => {
  const e = MP.plugins.find((x) => x.name === 'humanizer');
  assert.ok(e, 'humanizer missing from marketplace.json');
  assert.equal(e.source, './plugins/humanizer');
  assert.equal(e.license, 'MIT');
  assert.ok(existsSync(PLUGIN), 'plugin dir missing');
  const vendored = readFileSync(join(PLUGIN, 'VENDORED.md'), 'utf8');
  assert.ok(vendored.includes(PIN), 'VENDORED.md must carry the pinned sha');
  assert.ok(vendored.includes('blader/humanizer'), 'VENDORED.md must name the upstream repo');
});

test('the skill is opt-in and headed with source, sha and deviations', () => {
  const text = readFileSync(join(PLUGIN, 'skills', 'humanizer', 'SKILL.md'), 'utf8');
  assert.match(text, /^---\n[\s\S]*?\ndisable-model-invocation: true\n[\s\S]*?---\n/);
  assert.ok(text.includes(PIN), 'header names the pin');
  assert.match(text, /[Dd]eviations/);
});

test('the plugin ships no hooks, agents, commands, MCP servers or scripts', () => {
  for (const d of ['hooks', 'agents', 'commands', '.mcp.json', 'scripts']) assert.ok(!existsSync(join(PLUGIN, d)), `${d} must not exist`);
});

test('the plugin carries upstream LICENSE and a README documenting one-step removal', () => {
  assert.match(readFileSync(join(PLUGIN, 'LICENSE'), 'utf8'), /Copyright \(c\) 2025 Siqi Chen/);
  const readme = readFileSync(join(PLUGIN, 'README.md'), 'utf8');
  assert.match(readme, /plugin disable humanizer@himmel/);
  assert.match(readme, /plugin uninstall humanizer@himmel/);
});
