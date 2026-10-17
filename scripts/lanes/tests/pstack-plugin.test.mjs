// scripts/lanes/tests/pstack-plugin.test.mjs
// pstack ships as ONE opt-in himmel marketplace plugin, vendored at a
// pinned upstream commit, enabled for interactive sessions only and absent from
// every lean leg/lane profile, so removing it is a single disable.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { resolveProfile } from '../plugin-profiles.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const REG = JSON.parse(readFileSync(join(ROOT, 'scripts', 'lanes', 'plugin-profiles.json'), 'utf8'));
const MP = JSON.parse(readFileSync(join(ROOT, 'marketplace', '.claude-plugin', 'marketplace.json'), 'utf8'));
const PLUGIN = join(ROOT, 'marketplace', 'plugins', 'pstack');
const ID = 'pstack@himmel';
const PIN = '99743e9c151c8537cbbf1f98bb38f34ef3368453';
const SKILLS = ['correct', 'blast-radius', 'create-verification-skill', 'maintain-verification-skill',
  'benchmark-checklist', 'principle-explain-the-number', 'in-your-own-words'];

test('pstack@himmel is in the catalog, so every profile that does not enable it denies it', () => {
  assert.ok(REG.catalog.includes(ID), `${ID} missing from catalog`);
});

test('pstack@himmel is on only in the interactive `user` profile and off in every other shipped profile', () => {
  const shipped = Object.keys(REG.profiles).filter((n) => REG.profiles[n] !== null);
  for (const name of shipped) {
    const { enabledPlugins: p } = resolveProfile(REG, name, { installed: [] });
    assert.equal(p[ID], name === 'user', `${name}: ${ID} must be ${name === 'user'}`);
  }
});

test('pstack@himmel is never in base or floor, which every lean leg profile inherits', () => {
  assert.ok(!REG.base.includes(ID), 'base would put it in every leg');
  assert.ok(!REG.floor.includes(ID), 'floor would put it in every leg');
  for (const leg of ['leg-impl', 'leg-bus', 'leg-e2e', 'lane-impl', 'lane-review', 'lane-content', 'console-relay', 'console-judge', 'console']) {
    assert.ok(!(REG.profiles[leg].enable ?? []).includes(ID), `${leg} must not enable ${ID}`);
  }
});

test('marketplace entry is a local plugin whose files name the pinned upstream commit', () => {
  const e = MP.plugins.find((x) => x.name === 'pstack');
  assert.ok(e, 'pstack missing from marketplace.json');
  assert.equal(e.source, './plugins/pstack');
  assert.equal(e.license, 'MIT');
  assert.ok(existsSync(PLUGIN), 'plugin dir missing');
  const vendored = readFileSync(join(PLUGIN, 'VENDORED.md'), 'utf8');
  assert.ok(vendored.includes(PIN), 'VENDORED.md must carry the pinned sha');
  assert.ok(vendored.includes('cursor/plugins'), 'VENDORED.md must name the upstream repo');
  assert.ok(!JSON.stringify(e).includes('pstack-claude'), 'never sourced from the michael-denyer fork');
});

test('the plugin carries exactly the seven chosen skills, each opt-in and headed with source, sha and deviations', () => {
  const have = readdirSync(join(PLUGIN, 'skills')).sort();
  assert.deepEqual(have, [...SKILLS].sort());
  for (const s of SKILLS) {
    const text = readFileSync(join(PLUGIN, 'skills', s, 'SKILL.md'), 'utf8');
    assert.match(text, /^---\n[\s\S]*?\ndisable-model-invocation: true\n[\s\S]*?---\n/, `${s}: disable-model-invocation: true`);
    assert.ok(text.includes(PIN), `${s}: header names the pin`);
    assert.match(text, /[Dd]eviations/, `${s}: header names deviations`);
  }
});

test('the plugin ships no hooks, agents, commands or MCP servers (nothing autonomous rides along)', () => {
  for (const d of ['hooks', 'agents', 'commands', '.mcp.json', 'scripts']) assert.ok(!existsSync(join(PLUGIN, d)), `${d} must not exist`);
});

test('the plugin carries upstream LICENSE and a README documenting one-step removal', () => {
  assert.match(readFileSync(join(PLUGIN, 'LICENSE'), 'utf8'), /Copyright \(c\) 2026 Lauren Tan/);
  const readme = readFileSync(join(PLUGIN, 'README.md'), 'utf8');
  assert.match(readme, /plugin disable pstack@himmel/);
  assert.match(readme, /plugin uninstall pstack@himmel/);
});

test('no SKILL.md names a backticked skill the plugin does not ship', () => {
  const unshipped = ['how', 'why', 'arena', 'unslop', 'poteto-mode'];
  for (const s of SKILLS) {
    const text = readFileSync(join(PLUGIN, 'skills', s, 'SKILL.md'), 'utf8');
    for (const name of unshipped) assert.ok(!text.includes(`\`${name}\``), `${s}: names unshipped \`${name}\``);
  }
});

test('search.md reruns the title-match query before the Proof bullet captures the result', () => {
  const lines = readFileSync(join(PLUGIN, 'skills', 'create-verification-skill', 'references', 'feature-map-example', 'search.md'), 'utf8').split('\n');
  const proof = lines.findIndex((l) => l.startsWith('- **Proof.**'));
  const lastCli = lines.findIndex((l) => l.startsWith('- **CLI miss.**'));
  assert.ok(proof > lastCli && lastCli > 0, 'Proof must follow CLI miss');
  const fill = 'control-notes browser fill --role searchbox --name "Search notes" --value "quarterly"';
  const p = lines[proof];
  assert.ok(p.includes(fill), 'Proof bullet reruns the title-match query');
  const snap = p.indexOf('browser snapshot --aria --path artifacts/search/results.aria.txt');
  const shot = p.indexOf('browser screenshot --path artifacts/search/results.png');
  assert.ok(snap !== -1 && shot !== -1, 'Proof keeps both capture commands');
  assert.ok(p.indexOf(fill) < snap, 'rerun precedes the snapshot');
});

test('both deviations are recorded in VENDORED.md and the blast-radius header', () => {
  const vendored = readFileSync(join(PLUGIN, 'VENDORED.md'), 'utf8');
  assert.ok(!/references\/\*\*`[^\n]*none \(verbatim\)/.test(vendored), 'references row must name the search.md deviation');
  assert.ok(!/skills\/blast-radius\/SKILL\.md`[^\n]*\| none \|/.test(vendored), 'blast-radius row must name its deviation');
  const br = readFileSync(join(PLUGIN, 'skills', 'blast-radius', 'SKILL.md'), 'utf8');
  assert.ok(!br.includes('Deviations: none'), 'blast-radius header must record deviations');
});

test('plugin.json is bumped to 0.1.2', () => {
  assert.equal(JSON.parse(readFileSync(join(PLUGIN, '.claude-plugin', 'plugin.json'), 'utf8')).version, '0.1.2');
});
