#!/usr/bin/env bash
# selector: tree-scan
# Missing inventory rows, stale pins and absent licence metadata must fail closed.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd) || exit 1
. "$HERE/../lib/fixture-tempdir.sh" || exit 1
TMP=$(fixture_mktemp_dir) || exit 1
trap 'rm -rf "$TMP"' EXIT
node --input-type=module - "$HERE/generate-credits.mjs" "$TMP" "$HERE/../.." <<'NODE'
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
const [script, tmp, repo] = process.argv.slice(2);
let passed = 0;
let failed = 0;
let root;
const manifestPath = 'marketplace/.claude-plugin/marketplace.json';
const registryPath = 'scripts/guardrails/himmel-adapters.json';
const metadataPath = 'docs/third-party-licenses.md';
const pagePath = 'docs/credits.md';
const put = (file, text) => {
  fs.mkdirSync(path.dirname(path.join(root, file)), { recursive: true });
  fs.writeFileSync(path.join(root, file), text);
};
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
const json = (file, value) => put(file, JSON.stringify(value));
const plugin = { name: 'alpha', source: { source: 'url', url: 'https://github.com/example/alpha.git', ref: 'v1.0.0' }, author: { name: 'Alpha author' }, license: 'MIT' };
const fork = { nwo: 'fixture-org/fork', upstream: 'example/original', himmel_branch: 'main', pin_site: null, role: 'dormant', merge_allowed: false };
const metadata = rows => put(metadataPath, '# Licences\n\n<!-- credits-metadata:start -->\n| Item | Source | Author | Licence | Pin |\n|---|---|---|---|---|\n' + rows + '\n<!-- credits-metadata:end -->\n');
const forkMetadata = '| fork:fixture-org/fork | — | Original author | Apache-2.0 | — |';
function fixture() {
  root = fs.mkdtempSync(path.join(tmp, 'case-'));
  json(manifestPath, { plugins: [plugin] });
  json(registryPath, [fork]);
  metadata(forkMetadata);
}
function run(...args) {
  return spawnSync(process.execPath, [script, '--root', root, ...args], { encoding: 'utf8' });
}
function green(result) {
  assert.equal(result.status, 0, result.stderr || result.stdout);
}
function red(result, reason) {
  assert.equal(result.status, 1, result.stderr || result.stdout);
  assert.match(result.stderr, reason);
}
function test(name, fn) {
  fixture();
  try { fn(); passed++; console.log('PASS ' + name); }
  catch (error) { failed++; console.error('FAIL ' + name + ': ' + error.message); }
}

test('generation writes source, author, licence and pin for every plugin and fork', () => {
  green(run());
  assert.match(read(pagePath), /\| alpha \| https:\/\/github.com\/example\/alpha \| Alpha author \| MIT \| v1\.0\.0 \|/);
  assert.match(read(pagePath), /\| fixture-org\/fork \| https:\/\/github.com\/example\/original \| Original author \| Apache-2\.0 \|/);
  assert.match(read(pagePath), /dormant/);
  green(run('--check'));
});

test('a missing plugin row fails the check; adding that row turns it green', () => {
  green(run());
  const complete = read(pagePath);
  const missing = complete.split('\n').filter(line => !line.startsWith('| alpha |')).join('\n');
  put(pagePath, missing);
  red(run('--check'), /stale|missing/i);
  assert.equal(read(pagePath), missing, 'check mode must not rewrite the page');
  put(pagePath, complete);
  green(run('--check'));
});

test('a missing fork row fails even for a dormant fork', () => {
  green(run());
  put(pagePath, read(pagePath).split('\n').filter(line => !line.startsWith('| fixture-org/fork |')).join('\n'));
  red(run('--check'), /stale|missing/i);
});

test('adding a shipped plugin makes the existing page stale', () => {
  green(run());
  json(manifestPath, { plugins: [plugin, { ...plugin, name: 'beta' }] });
  red(run('--check'), /stale/i);
  green(run());
  assert.match(read(pagePath), /\| beta \|/);
  green(run('--check'));
});

test('missing licence metadata fails before overwriting a good page', () => {
  green(run());
  const original = read(pagePath);
  json(manifestPath, { plugins: [{ ...plugin, license: undefined }] });
  red(run(), /alpha.*licen[cs]e/i);
  assert.equal(read(pagePath), original);
});

test('a new fork requires a licence attribution, then regenerates successfully', () => {
  green(run());
  json(registryPath, [fork, { ...fork, nwo: 'fixture-org/new-fork' }]);
  red(run('--check'), /new-fork.*licen[cs]e/i);
  metadata(forkMetadata + '\n| fork:fixture-org/new-fork | — | New author | MIT | — |');
  green(run());
  assert.match(read(pagePath), /\| fixture-org\/new-fork \|/);
});

test('local plugins and standalone skill families use audited attribution metadata', () => {
  json(manifestPath, { plugins: [{ name: 'local', source: './plugins/local', author: { name: 'Maintainer' } }] });
  metadata(forkMetadata + '\n| plugin:local | https://github.com/example/local | — | MIT | in-tree |\n| skill:solo | https://github.com/example/solo | Solo author | BSD-2-Clause | abc123 |');
  green(run());
  assert.match(read(pagePath), /\| local \| https:\/\/github.com\/example\/local \| Maintainer \| MIT \| in-tree \|/);
  assert.match(read(pagePath), /\| solo \| https:\/\/github.com\/example\/solo \| Solo author \| BSD-2-Clause \| abc123 \|/);
});

test('git-subdir source pins come from the manifest, not attribution overrides', () => {
  json(manifestPath, { plugins: [{ ...plugin, source: { source: 'git-subdir', url: 'https://github.com/example/alpha.git', path: 'plugin', sha: 'abc123' } }] });
  metadata(forkMetadata + '\n| plugin:alpha | https://github.com/wrong/source | — | — | obsolete |');
  green(run());
  assert.match(read(pagePath), /https:\/\/github.com\/example\/alpha.*abc123/);
  assert.doesNotMatch(read(pagePath), /wrong\/source|obsolete/);
});

test('changing a manifest pin invalidates the generated page', () => {
  green(run());
  json(manifestPath, { plugins: [{ ...plugin, source: { ...plugin.source, ref: 'v2.0.0' } }] });
  red(run('--check'), /stale/i);
  green(run());
  assert.match(read(pagePath), /v2\.0\.0/);
});

test('duplicate attribution keys are rejected instead of silently shadowed', () => {
  metadata(forkMetadata + '\n' + forkMetadata);
  red(run(), /duplicate/i);
});

test('unknown attribution keys cannot leave removed plugins on the page', () => {
  metadata(forkMetadata + '\n| plugin:removed | https://github.com/example/removed | Removed | MIT | old |');
  red(run(), /removed|unused/i);
});

test('an uncredited standalone skill directory fails even before the page becomes stale', () => {
  green(run());
  const original = read(pagePath);
  put('.claude/skills/new-vendored/SKILL.md', '# New vendored skill\n');
  red(run('--check'), /missing credits metadata.*skill:new-vendored/i);
  assert.equal(read(pagePath), original);
  metadata(forkMetadata + '\n| skill:new-vendored | https://github.com/example/new-vendored | New author | MIT | abc123 |');
  green(run());
  assert.match(read(pagePath), /\| new-vendored \|/);
  green(run('--check'));
});

test('grouped standalone families cover each directory, but non-skill directories are ignored', () => {
  put('.claude/skills/one/SKILL.md', '# One\n');
  put('.claude/skills/two/SKILL.md', '# Two\n');
  put('.claude/skills/notes/README.md', '# Notes\n');
  metadata(forkMetadata + '\n| skill:one + two | https://github.com/example/group | Group author | MIT | abc123 |');
  green(run());
  green(run('--check'));
});

test('explicit unknown licence is reported, never silently converted to MIT', () => {
  metadata('| fork:fixture-org/fork | — | Original author | Unknown (not declared upstream) | — |');
  green(run());
  assert.match(read(pagePath), /Unknown \(not declared upstream\)/);
});

test('missing output is a failing check, not an empty pass', () => {
  red(run('--check'), /missing|stale/i);
});

test('the checked-in credits page matches the real shipped inventories', () => {
  root = repo;
  green(run('--check'));
});
console.log(`test-generate-credits: ${passed} passed, ${failed} failed`);
process.exitCode = failed ? 1 : 0;
NODE
