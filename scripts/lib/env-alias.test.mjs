// Tests for scripts/lib/env-alias.mjs. Walks the same rows as test-env-alias.sh
// (fixtures/env-alias-rows.tsv), so the shell, JS and Python twins cannot drift.
// Run: node --test scripts/lib/env-alias.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { envAliasRestrict, envAliasPermit } from './env-alias.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROWS = readFileSync(join(HERE, 'fixtures', 'env-alias-rows.tsv'), 'utf8')
  .split('\n')
  .filter((l) => l && !l.startsWith('#'))
  .map((l) => l.split('\t'));
const FN = { restrict: envAliasRestrict, permit: envAliasPermit };
const VALID = /^[A-Z_][A-Z0-9_]*$/;

function rowEnv(nn, on, nv, ov) {
  const env = {};
  if (VALID.test(nn) && nv !== '-') env[nn] = nv === '<empty>' ? '' : nv;
  if (VALID.test(on) && ov !== '-') env[on] = ov === '<empty>' ? '' : ov;
  return env;
}

test('the shared rows were read (not vacuous)', () => {
  assert.ok(ROWS.length >= 40);
});

for (const [fn, nnRaw, onRaw, nv, ov, want] of ROWS) {
  const nn = nnRaw === '<empty>' ? '' : nnRaw;
  const on = onRaw === '<empty>' ? '' : onRaw;
  const label = `${fn} '${nn}'=${nv} '${on}'=${ov} -> ${want}`;
  test(`function: ${label}`, () => {
    const env = rowEnv(nn, on, nv, ov);
    if (want === '2') {
      assert.throws(() => FN[fn](nn, on, env), (e) => e.code === 2);
    } else {
      assert.equal(FN[fn](nn, on, env), want === '0');
    }
  });
  test(`cli: ${label}`, () => {
    const r = spawnSync(process.execPath, [join(HERE, 'env-alias.mjs'), fn, nn, on], {
      env: { PATH: process.env.PATH, ...rowEnv(nn, on, nv, ov) },
      encoding: 'utf8',
    });
    assert.equal(r.status, Number(want), r.stderr);
  });
}

test('cli: an unknown function or wrong argument count exits 2', () => {
  for (const args of [['bogus', 'A', 'B'], ['restrict', 'A'], []]) {
    const r = spawnSync(process.execPath, [join(HERE, 'env-alias.mjs'), ...args], { encoding: 'utf8' });
    assert.equal(r.status, 2, args.join(' '));
  }
});
