// scripts/lanes/tests/pstack-plugin.test.mjs
// pstack ships as ONE opt-in himmel marketplace plugin, vendored at a
// pinned upstream commit, enabled for interactive sessions only and absent from
// every lean worker/lane profile, so removing it is a single disable.
import { test } from 'node:test';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import assert from 'node:assert/strict';
import { readFileSync, existsSync, readdirSync, lstatSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';
import { resolveProfile } from '../plugin-profiles.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const REG = JSON.parse(readFileSync(join(ROOT, 'scripts', 'lanes', 'plugin-profiles.json'), 'utf8'));
const MP = JSON.parse(readFileSync(join(ROOT, 'marketplace', '.claude-plugin', 'marketplace.json'), 'utf8'));
const PLUGIN = join(ROOT, 'marketplace', 'plugins', 'pstack');
const ID = 'pstack@himmel';
const PIN = '4dd1d05818d19792e7cd6e818f1667f95f7e1dbe';
const SKILLS = ['correct', 'blast-radius', 'create-verification-skill', 'maintain-verification-skill',
  'benchmark-checklist', 'principle-explain-the-number', 'in-your-own-words',
  'statechart', 'create-formal-verification-skill', 'maintain-formal-verification-skill'];

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

test('pstack@himmel is never in base or floor, which every lean worker profile inherits', () => {
  assert.ok(!REG.base.includes(ID), 'base would put it in every worker');
  assert.ok(!REG.floor.includes(ID), 'floor would put it in every worker');
  for (const worker of ['worker-impl', 'worker-bus', 'worker-e2e', 'lane-impl', 'lane-review', 'lane-content', 'chief-relay', 'console-judge', 'chief']) {
    assert.ok(!(REG.profiles[worker].enable ?? []).includes(ID), `${worker} must not enable ${ID}`);
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

test('the plugin carries exactly the ten chosen skills, each opt-in and headed with source, sha and deviations', () => {
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

test('every vendored file matches the byte-verified pinned inventory', () => {
  const manifest = JSON.parse(readFileSync(join(PLUGIN, 'vendor-hashes.json'), 'utf8'));
  assert.equal(manifest.pin, PIN);
  const files = ['LICENSE'];
  for (const folder of ['skills', 'docs']) {
    for (const name of readdirSync(join(PLUGIN, folder), { recursive: true })) {
      const path = join(folder, name);
      const stat = lstatSync(join(PLUGIN, path));
      assert.ok(!stat.isSymbolicLink(), `${path}: symlink not in pinned inventory`);
      if (stat.isFile()) files.push(path);
    }
  }
  assert.deepEqual(files.sort(), Object.keys(manifest.files).sort());
  for (const [path, hashes] of Object.entries(manifest.files)) {
    assert.match(hashes.upstream, /^[a-f0-9]{64}$/);
    if (process.platform !== 'win32')
      assert.equal(Boolean(lstatSync(join(PLUGIN, path)).mode & 0o111), hashes.executable,
        `${path}: executable mode drift`);
    assert.equal(createHash('sha256').update(readFileSync(join(PLUGIN, path))).digest('hex'),
      hashes.vendored, `${path}: drift from cursor/plugins@${PIN}`);
  }
});

test('the principle matches the new upstream pin after reversing recorded deviations', () => {
  const text = readFileSync(join(PLUGIN, 'skills/principle-explain-the-number/SKILL.md'), 'utf8')
    .replace(/^<!-- Vendored from[^\n]*-->\n\n/m, '')
    .replace('Prove It Works (not shipped here)', '[Prove It Works](../principle-prove-it-works/SKILL.md)');
  assert.equal(createHash('sha256').update(text).digest('hex'),
    '3c84fbf9a7d9842abcfcd134010782b32092ac3d3fb4aaf9ed5732dca83aa58c',
    'vendored file drifted from cursor/plugins@4dd1d058');
});

for (const [name, env, message] of [
  ['TLC absent', { TLA2TOOLS: '', JAVA: '' }, /Set TLA2TOOLS to an absolute path/],
  ['Java absent', { TLA2TOOLS: join(PLUGIN, 'skills/statechart/scripts/test/grid/Grid.cfg'), JAVA: '' }, /Set JAVA to an absolute path/],
  ['wrong jar', { TLA2TOOLS: join(PLUGIN, 'skills/statechart/scripts/test/grid/Grid.cfg'), JAVA: process.execPath }, /tla2tools.jar SHA-256 mismatch/],
]) {
  test(`statechart stops without installing when ${name}`, () => {
    const run = pathToFileURL(join(PLUGIN, 'skills/statechart/scripts/run.ts')).href;
    const grid = join(PLUGIN, 'skills/statechart/scripts/test/grid/Grid');
    const code = `import { check } from ${JSON.stringify(run)};\ntry { await check(${JSON.stringify(grid + '.tla')}, ${JSON.stringify(grid + '.cfg')}); } catch (e) { console.error(e.message); process.exit(2); }`;
    const result = spawnSync(process.execPath, ['--disable-warning=ExperimentalWarning', '--input-type=module', '-e', code], {
      encoding: 'utf8', timeout: 10000, env: { ...process.env, PATH: '', ...env },
    });
    assert.equal(result.error, undefined);
    assert.equal(result.status, 2);
    assert.match(result.stderr, message);
  });
}

test('plugin.json keeps the release-managed version 0.1.2', () => {
  assert.equal(JSON.parse(readFileSync(join(PLUGIN, '.claude-plugin', 'plugin.json'), 'utf8')).version, '0.1.2');
});
