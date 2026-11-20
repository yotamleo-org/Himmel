'use strict';
// node --test scripts/himmelctl/test/bot-roles.test.js
// The one role-disjointness rule (lib/bot-roles.js) and the distinct-tokens probe that uses it.
// Tokens here are made-up canaries, never a credential.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const roles = require('../lib/bot-roles.js');
const probes = require('../lib/probes.js');

const tok = (id) => `${id}:CNRY${'a'.repeat(31)}`;

function fixture() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'bot-roles-'));
  const home = path.join(dir, 'home');
  const repo = path.join(dir, 'repo');
  fs.mkdirSync(path.join(home, '.claude', 'channels', 'telegram'), { recursive: true });
  fs.mkdirSync(path.join(home, '.himmel', 'remote-setup'), { recursive: true });
  fs.mkdirSync(repo, { recursive: true });
  return {
    dir, home, repo,
    setMain: (t) => fs.writeFileSync(path.join(home, '.claude', 'channels', 'telegram', '.env'), `TELEGRAM_BOT_TOKEN=${t}\n`),
    setRelay: (t) => fs.writeFileSync(path.join(repo, '.env'), `TELEGRAM_BOT_TOKEN=${t}\n`),
    setBots: (o) => fs.writeFileSync(path.join(home, '.himmel', 'remote-setup', 'bots.json'), JSON.stringify(o)),
  };
}

const ITEM = {
  id: 'distinct-tokens',
  probe: { type: 'distinct-tokens', envFileA: '.claude/channels/telegram/.env', tokenKeyA: 'TELEGRAM_BOT_TOKEN', envFileB: '.env', tokenKeyB: 'TELEGRAM_BOT_TOKEN' },
};
const probeIn = (f) => probes.runProbe(ITEM, { repoRoot: f.repo, targetPath: f.repo, scope: 'user', env: Object.assign({}, process.env, { HOME: f.home }) });

test('roleConflict_bridge_equals_notice', () => {
  const ids = { main: '100', bridge: '200', notice: '300', relay: '400' };
  const c = roles.roleConflict('200', 'notice', ids);
  assert.equal(c.conflictsWith, 'bridge');
  assert.match(c.reason, /already your bridge bot/);
  assert.equal(roles.roleConflict('200', 'bridge', ids), null, 'a role keeps its own id');
  assert.equal(roles.roleConflict('999', 'notice', ids), null, 'a new id conflicts with nothing');
  assert.equal(roles.roleConflict('100', 'relay', ids).conflictsWith, 'main');
  assert.equal(roles.roleConflict('400', 'main', ids).conflictsWith, 'relay');
});

test('roleConflict_pending_counts_as_taken', () => {
  const ids = { main: '100', pending: ['333'] };
  const c = roles.roleConflict('333', 'notice', ids);
  assert.equal(c.conflictsWith, 'pending');
  assert.equal(roles.roleConflict('333', 'bridge', ids).conflictsWith, 'pending');
  assert.equal(roles.roleConflict('333', 'notice', { notice: '333', pending: ['333'] }), null);
  // the same pending id still blocks every other role
  assert.equal(roles.roleConflict('333', 'main', { notice: '333', pending: ['333'] }).conflictsWith, 'notice');
});

test('readRoleIds_reads_prefixes_and_bots_json_only', () => {
  const f = fixture();
  f.setMain(tok(111));
  f.setRelay(tok(444));
  f.setBots({ bridge: { id: '222', publishedAt: '2026-11-20T10:00:00Z' }, notice: { id: '333', username: 'n_bot', pending: true } });
  const ids = roles.readRoleIds({ home: f.home, repoRoot: f.repo });
  assert.deepEqual(
    { main: ids.main, relay: ids.relay, bridge: ids.bridge, notice: ids.notice, pending: ids.pending, at: ids.bridgePublishedAt },
    { main: '111', relay: '444', bridge: '222', notice: '333', pending: ['333'], at: '2026-11-20T10:00:00Z' },
  );
  const serialized = JSON.stringify(ids);
  assert.ok(!serialized.includes('CNRY'), 'only ids leave the module, never a token');
});

test('readRoleIds_ignores_bad_ids', () => {
  const f = fixture();
  f.setMain('not-a-token');
  f.setBots({ bridge: { id: 'abc' }, notice: { id: 7 } });
  const ids = roles.readRoleIds({ home: f.home, repoRoot: f.repo });
  assert.equal(ids.main, undefined);
  assert.equal(ids.bridge, undefined);
  assert.equal(ids.notice, '7');
});

test('distinct_tokens_reads_no_peer_bridge_dir', (t) => {
  const f = fixture();
  f.setMain(tok(111));
  f.setBots({ bridge: { id: '222', publishedAt: '2026-11-20T10:00:00Z' } });
  const fenced = [
    path.join(f.home, '.himmel', 'peer-bridge'),
    path.join(f.home, '.config', 'himmel', 'peer-bridge'),
  ];
  for (const d of fenced) {
    fs.mkdirSync(d, { recursive: true });
    fs.writeFileSync(path.join(d, 'env'), `PEER_BOT_TOKEN=${tok(222)}\n`);
    fs.chmodSync(d, 0o000);
  }
  t.after(() => { for (const d of fenced) fs.chmodSync(d, 0o700); });
  // Mode 000 does not stop root, so also watch every fs call the probe makes.
  const touched = [];
  for (const m of ['readFileSync', 'readdirSync', 'statSync', 'existsSync', 'openSync', 'lstatSync', 'accessSync']) {
    const orig = fs[m];
    t.mock.method(fs, m, function (p, ...rest) { touched.push(String(p)); return orig.call(fs, p, ...rest); });
  }
  const r = probeIn(f);
  assert.equal(r.actual, 'present');
  assert.deepEqual(touched.filter((p) => p.includes('peer-bridge')), [], 'the probe never touches a peer-bridge path');
});

test('distinct_tokens_bridge_as_published', () => {
  const f = fixture();
  f.setMain(tok(111));
  f.setBots({ bridge: { id: '222', publishedAt: '2026-11-20T10:00:00Z' } });
  const r = probeIn(f);
  assert.equal(r.actual, 'present');
  assert.match(r.detail, /bridge: as published 2026-11-20/);
});

test('distinct_tokens_flags_bridge_equal_main', () => {
  const f = fixture();
  f.setMain(tok(111));
  f.setBots({ bridge: { id: '111', publishedAt: '2026-11-20T10:00:00Z' } });
  const r = probeIn(f);
  assert.equal(r.actual, 'degraded');
  assert.match(r.detail, /the main bot and the bridge bot are the same bot/);
});

test('distinct_tokens_flags_notice_equal_relay', () => {
  const f = fixture();
  f.setMain(tok(111));
  f.setRelay(tok(555));
  f.setBots({ notice: { id: '555' } });
  const r = probeIn(f);
  assert.equal(r.actual, 'degraded');
  assert.match(r.detail, /the notice bot and the relay bot are the same bot/);
});

test('distinct_tokens_keeps_identical_token_check', () => {
  const f = fixture();
  f.setMain(tok(111));
  f.setRelay(tok(111));
  const r = probeIn(f);
  assert.equal(r.actual, 'degraded');
  assert.match(r.detail, /IDENTICAL/);
});

test('distinct_tokens_clean_absence_without_a_main_token', () => {
  const f = fixture();
  const r = probeIn(f);
  assert.equal(r.actual, 'present');
  assert.equal(r.cleanAbsence, true);
});
