// The API account role map owner. Hermetic: every row points
// HIMMEL_API_CREDIT_CONFIG at a temp dir, so roles.json lives there and never under the real HOME.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const SUT = join(HERE, 'api-roles.mjs');
const T = mkdtempSync(join(tmpdir(), 'api-roles-'));
process.on('exit', () => rmSync(T, { recursive: true, force: true }));

function fixture(rolesText) {
  const dir = mkdtempSync(join(T, 'case-'));
  const config = join(dir, 'config.json');
  const roles = join(dir, 'roles.json');
  const env = { PATH: process.env.PATH, HOME: dir, HIMMEL_API_CREDIT_CONFIG: config };
  if (rolesText !== undefined) writeFileSync(roles, typeof rolesText === 'string' ? rolesText : JSON.stringify(rolesText));
  const cli = (args, input) => spawnSync(process.execPath, [SUT, ...args], { env, encoding: 'utf8', input });
  return { dir, config, roles, env, cli };
}
const doc = (roles) => ({ version: 1, roles });

test('no roles.json is the absent state and nothing is routed', async () => {
  const f = fixture();
  const { roleMap } = await import('./api-roles.mjs');
  const m = roleMap(f.env);
  assert.equal(m.state, 'absent');
  assert.deepEqual({ ...m.roles }, {});
  assert.deepEqual(m.errors, []);
});

test('rolesPathFor sits beside the credit config', async () => {
  const f = fixture();
  const { rolesPathFor, ROLES } = await import('./api-roles.mjs');
  assert.equal(rolesPathFor(f.env), f.roles);
  assert.deepEqual(ROLES, ['graphify', 'judge']);
});

test('a clean judge:[B] map is valid and accounts judge prints B', () => {
  const f = fixture(doc({ judge: ['B'] }));
  const r = f.cli(['accounts', 'judge']);
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout.trim(), 'B');
  assert.equal(r.stderr, '');
  assert.equal(JSON.parse(f.cli(['check']).stdout).roleMap.state, 'valid');
});

test('a dropped letter keeps the entry live: partial, unknown-account error, kept-as line, duplicates silent', () => {
  const f = fixture(doc({ judge: ['B', 'D', 'B'] }));
  const r = f.cli(['accounts', 'judge']);
  assert.equal(r.status, 0);
  assert.equal(r.stdout.trim(), 'B');
  assert.match(r.stderr, /judge entry kept as \[B\]/);
  const m = JSON.parse(f.cli(['check']).stdout).roleMap;
  assert.equal(m.state, 'partial');
  assert.deepEqual(m.roles, { judge: ['B'] });
  assert.deepEqual(m.errors, ['unknown-account:judge:D']);
});

test('a misspelt role is ignored as unknown-role and judge is unaffected', () => {
  const f = fixture(doc({ jduge: ['B'] }));
  const r = f.cli(['accounts', 'judge']);
  assert.equal(r.stdout, '');
  const m = JSON.parse(f.cli(['check']).stdout).roleMap;
  assert.equal(m.state, 'partial');
  assert.deepEqual(m.errors, ['unknown-role:jduge']);
  assert.deepEqual(m.roles, {});
});

test('an empty or non-array entry is ignored with empty-role and an ignored line', () => {
  for (const value of [[], 'B']) {
    const f = fixture(doc({ judge: value }));
    const r = f.cli(['accounts', 'judge']);
    assert.equal(r.status, 0);
    assert.equal(r.stdout, '');
    assert.match(r.stderr, /judge entry ignored \(empty-role:judge\); the default accounts are used for judge\. Add an account to it or remove it$/m);
    const m = JSON.parse(f.cli(['check']).stdout).roleMap;
    assert.equal(m.state, 'partial');
    assert.deepEqual(m.errors, ['empty-role:judge']);
  }
});

test('I8: probe, other and critic are never roles', () => {
  const f = fixture(doc({ probe: ['A'], other: ['B'], critic: ['C'] }));
  const m = JSON.parse(f.cli(['check']).stdout).roleMap;
  assert.equal(m.state, 'partial');
  assert.deepEqual(m.roles, {});
  assert.deepEqual(m.errors, ['unknown-role:probe', 'unknown-role:other', 'unknown-role:critic']);
  for (const kind of ['probe', 'other', 'critic']) assert.equal(f.cli(['accounts', kind]).stdout, '');
});

test('not JSON, version 2 and roles:[] are invalid: no roles and an invalid-role-map error', () => {
  const cases = [['{not json', 'invalid-role-map:not-json'], [JSON.stringify({ version: 2, roles: {} }), 'invalid-role-map:version'],
    [JSON.stringify({ version: 1, roles: [] }), 'invalid-role-map:roles-shape']];
  for (const [text, error] of cases) {
    const f = fixture(text);
    const m = JSON.parse(f.cli(['check']).stdout).roleMap;
    assert.equal(m.state, 'invalid');
    assert.deepEqual(m.roles, {});
    assert.deepEqual(m.errors, [error]);
    const r = f.cli(['accounts', 'graphify']);
    assert.equal(r.status, 0);
    assert.equal(r.stdout, '');
    assert.match(r.stderr, new RegExp(`role map invalid \\(${error}\\); the default accounts are used\\. Fix or remove roles\\.json$`, 'm'));
  }
});

test('a list entry that is a JSON object with a null toString never throws: the valid entries stay enforced', () => {
  const f = fixture('{"version":1,"roles":{"graphify":["C"],"judge":["B",{"toString":null},["A"],7,null]}}');
  assert.equal(f.cli(['accounts', 'graphify']).stdout.trim(), 'C');
  const r = f.cli(['accounts', 'judge']);
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout.trim(), 'B');
  const m = JSON.parse(f.cli(['check']).stdout).roleMap;
  assert.equal(m.state, 'partial');
  assert.deepEqual(m.roles, { graphify: ['C'], judge: ['B'] });
  assert.equal(m.errors.length, 4);
  const w = f.cli(['write'], '{"version":1,"roles":{"judge":["B",{"toString":null}]}}');
  assert.equal(w.status, 3, w.stderr);
  assert.equal(existsSync(f.roles) && readFileSync(f.roles, 'utf8').includes('toString'), true, 'the hand-written file is untouched');
});

test('accounts graphify with no file prints nothing, nothing on stderr', () => {
  const f = fixture();
  const r = f.cli(['accounts', 'graphify']);
  assert.equal(r.status, 0);
  assert.equal(r.stdout, '');
  assert.equal(r.stderr, '');
});

test('I8: accounts constructor, __proto__ and toString print nothing and exit 0 on a valid map', () => {
  const f = fixture(doc({ judge: ['B'], graphify: ['A', 'C'] }));
  for (const kind of ['constructor', '__proto__', 'toString', 'hasOwnProperty']) {
    const r = f.cli(['accounts', kind]);
    assert.equal(r.status, 0, kind);
    assert.equal(r.stdout, '', kind);
    assert.equal(r.stderr, '', kind);
  }
  assert.equal(f.cli(['accounts', 'graphify']).stdout.trim(), 'A,C');
});

test('write: mode 600, config.json untouched, no temp file left, round trip reads valid', () => {
  const f = fixture();
  writeFileSync(f.config, '{"keep":"me"}\n');
  const before = readFileSync(f.config);
  const r = f.cli(['write'], JSON.stringify(doc({ judge: ['B'] })));
  assert.equal(r.status, 0, r.stderr);
  assert.equal(statSync(f.roles).mode & 0o777, 0o600);
  assert.deepEqual(readFileSync(f.config), before);
  assert.deepEqual(readdirSync(f.dir).sort(), ['config.json', 'roles.json']);
  assert.equal(JSON.parse(f.cli(['check']).stdout).roleMap.state, 'valid');
});

test('write of an empty roles object removes the file', () => {
  const f = fixture(doc({ judge: ['B'] }));
  const r = f.cli(['write'], JSON.stringify(doc({})));
  assert.equal(r.status, 0, r.stderr);
  assert.equal(existsSync(f.roles), false);
});

test('write of an unknown account exits 3 naming it and leaves the file unchanged', () => {
  const f = fixture(doc({ graphify: ['A'] }));
  const before = readFileSync(f.roles);
  const r = f.cli(['write'], JSON.stringify(doc({ judge: ['D'] })));
  assert.equal(r.status, 3);
  assert.match(r.stdout, /unknown-account:judge:D/);
  assert.deepEqual(readFileSync(f.roles), before);
});

test('write of a doc with no version exits 3 naming the version', () => {
  const f = fixture();
  const r = f.cli(['write'], JSON.stringify({ roles: { judge: ['B'] } }));
  assert.equal(r.status, 3);
  assert.match(r.stdout, /version/);
  assert.equal(existsSync(f.roles), false);
});

test('write of malformed stdin exits 3 and writes nothing', () => {
  const f = fixture();
  const r = f.cli(['write'], '{nope');
  assert.equal(r.status, 3);
  assert.equal(existsSync(f.roles), false);
});

test('I7: an extra top-level key never reaches the file; it holds only version and roles', () => {
  const f = fixture();
  const r = f.cli(['write'], JSON.stringify({ version: 1, roles: { judge: ['B', 'B'] }, note: 'sk-ant-fake' }));
  assert.equal(r.status, 0, r.stderr);
  const text = readFileSync(f.roles, 'utf8');
  assert.deepEqual(Object.keys(JSON.parse(text)).sort(), ['roles', 'version']);
  assert.deepEqual(JSON.parse(text).roles, { judge: ['B'] });
  assert.ok(!text.includes('sk-ant'));
});

test('check with a valid map prints state, roles, errors [] and ROLES', () => {
  const f = fixture(doc({ judge: ['B'] }));
  const out = JSON.parse(f.cli(['check']).stdout);
  assert.deepEqual(out.roleMap, { state: 'valid', roles: { judge: ['B'] }, errors: [] });
  assert.deepEqual(out.ROLES, ['graphify', 'judge']);
});

test('the roles dir need not exist for an absent read', () => {
  const f = fixture();
  const env = { ...f.env, HIMMEL_API_CREDIT_CONFIG: join(f.dir, 'nope', 'deeper', 'config.json') };
  const r = spawnSync(process.execPath, [SUT, 'accounts', 'judge'], { env, encoding: 'utf8' });
  assert.equal(r.status, 0);
  assert.equal(r.stdout, '');
});

function withAccounts(f, letters) {
  const accounts = Object.fromEntries(letters.map((l) => [l, { organization_id: `org-${l}`, cycle_id: `cycle-${l}`, cap_usd: '1.00' }]));
  writeFileSync(f.config, JSON.stringify({ version: 1, ledger_path: join(f.dir, 'ledger.json'), accounts }));
}

test('check with a valid map and a config holding A and B reports accounts ok and no warnings', () => {
  const f = fixture(doc({ judge: ['B'], graphify: ['A', 'C'] }));
  withAccounts(f, ['A', 'B']);
  const out = JSON.parse(f.cli(['check']).stdout);
  assert.equal(out.accounts, 'ok');
  assert.deepEqual(out.warnings, []);
});

test('check warns no-configured-account for a role whose only letter has no roster row', () => {
  const f = fixture(doc({ graphify: ['C'], judge: ['B'] }));
  withAccounts(f, ['A', 'B']);
  const out = JSON.parse(f.cli(['check']).stdout);
  assert.equal(out.accounts, 'ok');
  assert.deepEqual(out.warnings, ['no-configured-account:graphify']);
});

test('check reports accounts unreadable and no warnings for a missing, non-JSON or invalid config', () => {
  const f = fixture(doc({ graphify: ['C'] }));
  for (const text of [undefined, '{not json', JSON.stringify({ version: 1, ledger_path: '/x', accounts: { D: {} } })]) {
    if (text !== undefined) writeFileSync(f.config, text);
    const out = JSON.parse(f.cli(['check']).stdout);
    assert.equal(out.accounts, 'unreadable');
    assert.deepEqual(out.warnings, []);
    assert.equal(out.roleMap.state, 'valid');
  }
});
