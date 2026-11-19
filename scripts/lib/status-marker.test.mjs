// Tests for scripts/lib/status-marker.mjs. Walks the same rows as
// test-status-marker.sh (fixtures/status-marker-rows.tsv), so the shell, JS and
// Python parses cannot drift.
// Run: node --test scripts/lib/status-marker.test.mjs
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { chmodSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { statusMarkerParse, statusMarkerIsParked, statusMarkerNewest, statusMarkerActionable } from './status-marker.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const T = mkdtempSync(join(tmpdir(), 'himmel-status-marker-'));
after(() => rmSync(T, { recursive: true, force: true }));
const FNS = { statusMarkerNewest, statusMarkerActionable };
const MODULE = pathToFileURL(join(HERE, 'status-marker.mjs')).href;
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

test('row E1: an absent path, a directory and /dev/null are unreadable; a zero-byte file is none', () => {
  mkdirSync(join(T, 'adir'));
  writeFileSync(join(T, 'zero.md'), '');
  for (const [name, fn] of Object.entries(FNS)) {
    assert.throws(() => fn(join(T, 'absent')), { code: 'ENOENT' }, name);
    assert.throws(() => fn(join(T, 'adir')), { code: 'ENOTREG' }, name);
    assert.throws(() => fn('/dev/null'), { code: 'ENOTREG' }, name);
    assert.equal(fn(join(T, 'zero.md')), null, name);
  }
});

test('row E3: a FIFO is unreadable and never blocks', () => {
  const fifo = join(T, 'fifo');
  execFileSync('mkfifo', [fifo]);
  for (const name of Object.keys(FNS)) {
    const r = spawnSync(process.execPath, ['--input-type=module', '-e',
      `import * as m from ${JSON.stringify(MODULE)}; try { m.${name}(${JSON.stringify(fifo)}); console.log('NONE'); } catch (e) { console.log(e.code ?? e.name); }`],
    { encoding: 'utf8', timeout: 5000 });
    assert.equal(r.error, undefined, `${name} was killed after 5 s`);
    assert.equal(r.stdout.trim(), 'ENOTREG', name);
  }
});

const DOCS = readFileSync(join(HERE, 'fixtures', 'status-marker-docs.tsv'), 'utf8');
const DOCS_WANT = Number(/^# rows: (\d+)$/m.exec(DOCS)?.[1]);
const ESC = { n: '\n', r: '\r', t: '\t', f: '\f', '\\': '\\' };
const decodeDoc = (s) => s.replace(/\\([\s\S]?)/g, (_, c) => {
  if (!(c in ESC)) throw new Error(`unknown escape \\${c}`);
  return ESC[c];
});
const DOC_ROWS = [];
let rowId = '';
for (const l of DOCS.split('\n')) {
  const m = /^# ([A-Z][0-9]{2})$/.exec(l);
  if (m) rowId = m[1];
  else if (l && !/^#( |$)/.test(l)) DOC_ROWS.push([rowId, ...l.split('\t')]);
}
const none = (v) => (v === '-' ? null : v);
const D = join(T, 'd');
mkdirSync(D);

test('every declared doc row was read', () => {
  assert.ok(DOC_ROWS.length > 0);
  assert.equal(DOC_ROWS.length, DOCS_WANT);
});

for (const [id, doc, nw, ac] of DOC_ROWS) {
  test(`row ${id}`, () => {
    const p = join(D, 'doc.md');
    const bytes = Buffer.from(decodeDoc(doc), 'latin1');
    writeFileSync(p, bytes);
    assert.equal(statusMarkerNewest(p), none(nw), 'newest');
    assert.equal(statusMarkerActionable(p), none(ac), 'actionable');
    assert.equal(statusMarkerNewest(p), none(nw), 'a second call answers the same');
    assert.deepEqual(readFileSync(p), bytes, 'the doc bytes are unchanged');
    assert.deepEqual(readdirSync(D), ['doc.md'], 'nothing else is written');
  });
}

const bytesDoc = (...parts) => Buffer.concat(parts.map((x) => (typeof x === 'string' ? Buffer.from(x, 'latin1') : Buffer.from(x))));
const B = join(T, 'b');
mkdirSync(B);
for (const [id, data, nw] of [
  ['B1', bytesDoc('## Results\n- 10:00 LIVE ', [0xff], '\n'), 'LIVE'],
  ['B2', bytesDoc('## Results\n- 10:00 ', [0xff], 'LIVE\n'), null],
  ['B3', bytesDoc('## Results\n- 10:00 LIVE', [0x85], '- 10:05 WRAPPED\n'), 'LIVE'],
]) {
  test(`row ${id}`, () => {
    const p = join(B, `${id}.md`);
    writeFileSync(p, data);
    assert.equal(statusMarkerNewest(p), nw);
    assert.equal(statusMarkerActionable(p), null);
  });
}

test('row E4: a file the user cannot read is unreadable (readable to root)', (t) => {
  const p = join(T, 'm000.md');
  writeFileSync(p, '## Results\n- 10:00 LIVE\n');
  chmodSync(p, 0);
  const root = process.geteuid() === 0;
  t.diagnostic(`row E4 branch: ${root ? 'root' : 'non-root'} (the other branch is not exercised by this run)`);
  for (const [name, fn] of Object.entries(FNS)) {
    if (root) assert.equal(fn(p), name === 'statusMarkerNewest' ? 'LIVE' : null, name);
    else assert.throws(() => fn(p), { code: 'EACCES' }, name);
  }
});

const TEN = /WRAPPED|READY|RESOLVED|BLOCKED|HALTED|FINDING|LIVE|PARKED-BANK|PARKED-USAGE|RESUMED/; // old-term-ok
const P = join(T, 'p');
mkdirSync(P);
const putDoc = (line) => {
  const p = join(P, 'p.md');
  writeFileSync(p, `## Results\n${line}\n`);
  return p;
};
for (const [line] of ROWS) {
  const pm = statusMarkerParse(line);
  test(`row P1: ${line}`, () => {
    const p = putDoc(line);
    assert.equal(statusMarkerNewest(p), pm);
    assert.equal(statusMarkerActionable(p), ['READY', 'BLOCKED', 'FINDING'].includes(pm) ? `${pm}#1` : null);
  });
  for (const x of ['READY', 'BLOCKED', 'FINDING', 'MERGED']) {
    test(`row P2 (${x}): ${line}`, () => {
      assert.equal(statusMarkerActionable(putDoc(line.replace(TEN, x))), pm === null ? null : `${x}#1`);
    });
  }
}
