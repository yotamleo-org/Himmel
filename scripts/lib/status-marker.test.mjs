// Tests for scripts/lib/status-marker.mjs. Walks the same rows as
// test-status-marker.sh (fixtures/status-marker-rows.tsv), so the shell, JS and
// Python parses cannot drift.
// Run: node --test scripts/lib/status-marker.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { statusMarkerParse, statusMarkerIsParked } from './status-marker.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const FIXTURE = readFileSync(join(HERE, 'fixtures', 'status-marker-rows.tsv'), 'utf8');
const WANT_ROWS = Number(/^# rows: (\d+)$/m.exec(FIXTURE)?.[1]);
const ROWS = FIXTURE
  .split('\n')
  .filter((l) => l && !l.startsWith('#'))
  .map((l) => l.split('\t'));

test('every declared row was read', () => {
  assert.ok(ROWS.length > 0);
  assert.equal(ROWS.length, WANT_ROWS);
});

for (const [line, want] of ROWS) {
  test(`parse: ${line} -> ${want}`, () => {
    assert.equal(statusMarkerParse(line), want === '-' ? null : want);
  });
  test(`cli: ${line} -> ${want}`, () => {
    const r = spawnSync(process.execPath, [join(HERE, 'status-marker.mjs'), 'parse', line], { encoding: 'utf8' });
    assert.equal(r.status, want === '-' ? 1 : 0, r.stderr);
    assert.equal(r.stdout, want === '-' ? '' : `${want}\n`);
  });
}

test('a trailing CR or an embedded newline after the word still parses', () => {
  for (const line of ['- 23:47 LIVE \u2014 note\r', '- LIVE \u2014 a\nb', '- LIVE\r']) {
    assert.equal(statusMarkerParse(line), 'LIVE', JSON.stringify(line));
    const r = spawnSync(process.execPath, [join(HERE, 'status-marker.mjs'), 'parse', line], { encoding: 'utf8' });
    assert.equal(r.stdout, 'LIVE\n', JSON.stringify(line));
  }
});

test('isParked accepts both spellings and nothing else', () => {
  assert.equal(statusMarkerIsParked('PARKED-BANK'), true);
  assert.equal(statusMarkerIsParked('PARKED-USAGE'), true);
  for (const m of ['LIVE', 'WRAPPED', 'PARKED', 'PARKED-BANKX', 'parked-bank', '']) {
    assert.equal(statusMarkerIsParked(m), false, m);
  }
});

test('cli: is-parked exit codes and bad usage', () => {
  const run = (...a) => spawnSync(process.execPath, [join(HERE, 'status-marker.mjs'), ...a], { encoding: 'utf8' }).status;
  assert.equal(run('is-parked', 'PARKED-BANK'), 0);
  assert.equal(run('is-parked', 'PARKED-USAGE'), 0);
  assert.equal(run('is-parked', 'LIVE'), 1);
  assert.equal(run('bogus', 'x'), 2);
  assert.equal(run('parse'), 2);
});
