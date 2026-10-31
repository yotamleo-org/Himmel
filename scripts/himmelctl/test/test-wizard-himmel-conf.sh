#!/usr/bin/env bash
# Config migration must write the reader's format, keep secrets/policy out,
# and preserve the legacy file until the destination is verified.
set -uo pipefail
repo_root=$(git rev-parse --show-toplevel)
. "$repo_root/scripts/himmelctl/test/_hermetic-home.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/wizard-himmel-conf.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT
HOME="$work" USERPROFILE="$(winpath "$work")" HIMMELCTL_CACHE_DIR="$(winpath "$work/cache")" \
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/.himmel/config.json")" \
  node - "$(winpath "$repo_root")" <<'NODE'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const root = process.argv[2];
const adopter = require(path.join(root, 'scripts/himmelctl/lib/adopter-profile.js'));
const home = process.env.HOME;
let passed = 0;
function test(name, run) {
  return Promise.resolve().then(run).then(() => { passed++; console.log(`ok: ${name}`); });
}
function fixture(name) {
  const dir = path.join(home, name);
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}
function read(file) { return fs.readFileSync(file, 'utf8'); }
function load(file, key) {
  const r = spawnSync('bash', ['-c', '. "$1"; _load_dotenv_extract "$2" "$3"', 'test',
    path.join(root, 'scripts/lib/load-dotenv.sh'), file, key], { encoding: 'utf8' });
  assert.equal(r.status, 0);
  return r.stdout.trim();
}
async function main() {
  await test('fresh install writes reader-valid config, never secret or policy', () => {
    assert.equal(typeof adopter.applyBehaviourConfig, 'function', 'wizard must provide the himmel.conf step');
    const dir = fixture('fresh');
    const conf = path.join(dir, 'himmel.conf');
    const notices = [];
    adopter.applyBehaviourConfig({ CR_PROFILE: 'claude,codex', JIRA_EMAIL: 'fixture@example.invalid' },
      { conf, envFile: path.join(dir, '.env'), log: s => notices.push(s) });
    assert.equal(load(conf, 'CR_PROFILE'), 'CR_PROFILE=claude,codex');
    assert.equal(load(conf, 'JIRA_EMAIL'), 'JIRA_EMAIL=fixture@example.invalid');
    assert(!/CR_REQUIRE_CROSS_MODEL|API_TOKEN/.test(read(conf)));
  });
  await test('legacy config migrates with key-only notice and private backup', () => {
    const dir = fixture('legacy');
    const envFile = path.join(dir, '.env');
    const conf = path.join(dir, 'himmel.conf');
    const original = '# keep\nCR_PROFILE = legacy-panel # old config\nCR_PROFILE=duplicate\nJIRA_API_TOKEN=fixture-secret-sentinel\nUNCLASSIFIED=fixture-unknown-sentinel\nCR_REQUIRE_CROSS_MODEL=1\n';
    fs.writeFileSync(envFile, original);
    const notices = [];
    adopter.applyBehaviourConfig({}, { conf, envFile, log: s => notices.push(s) });
    assert.equal(load(conf, 'CR_PROFILE'), 'CR_PROFILE=legacy-panel');
    assert.equal(read(envFile), '# keep\nJIRA_API_TOKEN=fixture-secret-sentinel\nUNCLASSIFIED=fixture-unknown-sentinel\nCR_REQUIRE_CROSS_MODEL=1\n');
    assert.match(notices.join('\n'), /migrat.*CR_PROFILE/i);
    for (const v of ['legacy-panel', 'fixture-secret-sentinel', 'fixture-unknown-sentinel']) assert(!notices.join('\n').includes(v));
    const backupDir = path.join(home, '.himmel/env-backups');
    assert(fs.existsSync(backupDir), 'migration must keep backups outside the checkout');
    const backup = path.join(backupDir, fs.readdirSync(backupDir)[0]);
    assert.equal(read(backup), original);
    assert.equal(fs.statSync(backupDir).mode & 0o777, 0o700);
    assert.equal(fs.statSync(backup).mode & 0o777, 0o600);
    assert(notices.some(s => s.includes(backup) && s.includes('holds your secrets; remove it')));
    assert(!fs.readdirSync(dir).some(f => f.startsWith('.env.wizard-backup-')));
  });
  await test('existing config wins, local override is respected, symlink survives', () => {
    const dir = fixture('linked');
    const target = path.join(dir, 'vault.conf');
    const conf = path.join(dir, 'himmel.conf');
    const envFile = path.join(dir, '.env');
    fs.writeFileSync(target, 'CR_PROFILE=reviewed\n');
    fs.symlinkSync(target, conf);
    fs.writeFileSync(conf + '.local', 'USER_SLUG=station\n');
    fs.writeFileSync(envFile, 'CR_PROFILE=old\nUSER_SLUG=old-station\n');
    adopter.applyBehaviourConfig({ USER_SLUG: 'new-station' }, { conf, envFile, log: () => {} });
    assert(fs.lstatSync(conf).isSymbolicLink());
    assert.equal(load(target, 'CR_PROFILE'), 'CR_PROFILE=reviewed');
    assert.equal(load(conf + '.local', 'USER_SLUG'), 'USER_SLUG=new-station');
    assert.equal(read(envFile), '');
  });
  await test('policy and unknown input are refused before any config write', () => {
    for (const key of ['CR_REQUIRE_CROSS_MODEL', 'JIRA_API_TOKEN', 'UNKNOWN']) {
      const dir = fixture('refused-' + key);
      const conf = path.join(dir, 'himmel.conf');
      assert.throws(() => adopter.applyBehaviourConfig({ [key]: 'sentinel' },
        { conf, envFile: path.join(dir, '.env'), log: () => {} }), /config/i);
      assert(!fs.existsSync(conf));
    }
  });
  await test('failed destination or malformed legacy value never removes .env lines', () => {
    const dir = fixture('failure');
    const envFile = path.join(dir, '.env');
    const conf = path.join(dir, 'himmel.conf');
    fs.mkdirSync(conf);
    fs.writeFileSync(envFile, 'CR_PROFILE=legacy\n');
    assert.throws(() => adopter.applyBehaviourConfig({}, { conf, envFile, log: () => {} }));
    assert.equal(read(envFile), 'CR_PROFILE=legacy\n');
    fs.writeFileSync(envFile, 'CR_PROFILE="unterminated\nJIRA_API_TOKEN=fixture-secret-sentinel\n');
    assert.throws(() => adopter.applyBehaviourConfig({}, { conf: path.join(dir, 'new.conf'), envFile, log: () => {} }));
    assert.equal(read(envFile), 'CR_PROFILE="unterminated\nJIRA_API_TOKEN=fixture-secret-sentinel\n');
  });
  await test('a multiline secret is never mistaken for migratable config', () => {
    const dir = fixture('multiline-secret');
    const envFile = path.join(dir, '.env');
    const original = 'JIRA_API_TOKEN="first-line\nCR_PROFILE=inside-secret\nlast-line"\n';
    fs.writeFileSync(envFile, original);
    const conf = path.join(dir, 'himmel.conf');
    assert.throws(() => adopter.applyBehaviourConfig({}, { conf, envFile, log: () => {} }));
    assert.equal(read(envFile), original);
    assert(!fs.existsSync(conf));
  });
  await test('every config key is asked with its explanation; policy is explained only', async () => {
    const prompts = [];
    const answers = await adopter.askBehaviourConfig(async prompt => { prompts.push(prompt); return ''; }, { log: s => prompts.push(s) });
    assert.deepEqual(answers, {});
    const rows = require(path.join(root, 'scripts/himmelctl/lib/config-keys.json')).keys;
    for (const row of rows) {
      assert(prompts.some(p => p.includes(row.name) && p.includes(row.explanation) && p.includes(row.effect)));
    }
    assert.equal(prompts.filter(p => p.includes('> ')).length, rows.filter(r => r.class === 'config' && !r.envOnly).length);
  });
  await test('metadata covers exactly reader keys and preserves existing secret-store compatibility', () => {
    const rows = require(path.join(root, 'scripts/himmelctl/lib/config-keys.json')).keys;
    const source = read(path.join(root, 'scripts/lib/load-dotenv.sh')).split('_himmel_key_class() {')[1].split('\n}')[0];
    const classified = [...source.matchAll(/\b[A-Z][A-Z0-9_]+\b/g)].map(m => m[0]);
    assert.deepEqual(rows.map(r => r.name).sort(), [...new Set(classified)].sort());
    const loader = path.join(root, 'scripts/lib/load-dotenv.sh');
    const probe = spawnSync('bash', ['-c', '. "$1"; shift; for k in "$@"; do printf "%s %s " "$k" "$(_himmel_key_class "$k")"; _himmel_env_only_key "$k" && echo 1 || echo 0; done', 'probe', loader, ...rows.map(r => r.name)], { encoding: 'utf8' });
    assert.equal(probe.status, 0, probe.stderr);
    assert.deepEqual(probe.stdout.trim().split('\n').sort(),
      rows.map(r => `${r.name} ${r.class} ${r.envOnly ? 1 : 0}`).sort());
    const manifest = require(path.join(root, 'scripts/himmelctl/lib/secrets-manifest.json'));
    assert.deepEqual(manifest.secrets.filter(s => rows.some(r => r.name === s.name)).map(s => s.name).sort(),
      ['FIRECRAWL_BASE_URL', 'JIRA_BASE_URL', 'JIRA_EMAIL', 'JIRA_PROJECT_KEY', 'WHISPER_MODEL']);
    const store = require(path.join(root, 'scripts/himmelctl/lib/secret-store.js'));
    assert.equal(store.validate('JIRA_EMAIL', 'fixture@example.invalid').ok, true);
    assert.equal(store.validate('JIRA_PROJECT_KEY', 'ABC').ok, true);
  });
  await test('Jira URL moves into config and a profile answer is accepted', () => {
    const dir = fixture('jira-url');
    const envFile = path.join(dir, '.env');
    const conf = path.join(dir, 'himmel.conf');
    fs.writeFileSync(envFile, 'JIRA_BASE_URL=https://legacy.example.invalid\nJIRA_API_TOKEN=fixture-token\n');
    adopter.applyBehaviourConfig({}, { conf, envFile, log: () => {} });
    assert.equal(load(conf, 'JIRA_BASE_URL'), 'JIRA_BASE_URL=https://legacy.example.invalid');
    assert.equal(read(envFile), 'JIRA_API_TOKEN=fixture-token\n');
    adopter.applyBehaviourConfig({ JIRA_BASE_URL: 'https://profile.example.invalid' }, { conf, envFile, log: () => {} });
    assert.equal(load(conf, 'JIRA_BASE_URL'), 'JIRA_BASE_URL=https://profile.example.invalid');
  });
  await test('env-only keys stay in .env across an install and are refused from a profile', () => {
    const dir = fixture('envonly');
    const envFile = path.join(dir, '.env');
    const conf = path.join(dir, 'himmel.conf');
    const original = 'WHISPER_MODEL=/fixture/model.bin\nFIRECRAWL_BASE_URL=https://fixture-fc.example.invalid\nCR_PROFILE=legacy-panel\n';
    fs.writeFileSync(envFile, original);
    adopter.applyBehaviourConfig({}, { conf, envFile, log: () => {} });
    assert.equal(read(envFile), original.replace('CR_PROFILE=legacy-panel\n', ''));
    for (const key of ['WHISPER_MODEL', 'FIRECRAWL_BASE_URL']) {
      assert.equal(load(conf, key), '');
      assert.throws(() => adopter.validateBehaviourConfig({ [key]: 'https://planted.example.invalid' }), /read from \.env only/);
      assert.throws(() => adopter.applyBehaviourConfig({ [key]: 'https://planted.example.invalid' },
        { conf, envFile, log: () => {} }), /read from \.env only/);
    }
  });
  await test('real wizard applies config, migrates legacy and leaves policy unchanged', () => {
    const dir = fixture('wizard');
    const repo = path.join(dir, 'repo');
    fs.mkdirSync(path.join(repo, 'scripts'), { recursive: true });
    fs.writeFileSync(path.join(repo, 'scripts/adopt.sh'), '#!/usr/bin/env bash\nexit 0\n');
    const envFile = path.join(repo, '.env');
    fs.writeFileSync(envFile, 'CR_PROFILE=legacy-integration\nJIRA_API_TOKEN=fixture-secret-sentinel\nCR_FLOOR_FALLBACK=claude-only\n');
    const policy = path.join(dir, '.himmel/config.json');
    fs.mkdirSync(path.dirname(policy), { recursive: true });
    const originalPolicy = '{"policy":{"ARMAUTOMERGE":"0","CR_REQUIRE_CROSS_MODEL":"1"}}\n';
    fs.writeFileSync(policy, originalPolicy);
    const profile = path.join(dir, 'profile.json');
    fs.writeFileSync(profile, JSON.stringify({ schemaVersion: 2, profile: 'starter', devOverlay: false,
      scope: 'user', vault: { mode: 'none', path: '' }, handover: { mode: 'inline', path: '' },
      pluginSet: 'lean', lanes: [], lanesMeaningful: true, alwaysOn: false, secretsWalk: 'run',
      behaviourConfig: { USER_SLUG: 'wizard-user' } }));
    const env = { ...process.env, HOME: dir, USERPROFILE: dir, HIMMELCTL_REPO_ROOT: repo,
      HIMMELCTL_INTERACTIVE: '0', HIMMELCTL_UI_HANDOFF: '0', HIMMELCTL_BIN_DIR: path.join(dir, 'bin'),
      HIMMELCTL_CACHE_DIR: path.join(dir, 'cache'), HIMMEL_LUNA_CONFIG_PATH: policy };
    const invoke = extra => spawnSync(process.execPath, [path.join(root, 'scripts/himmelctl/bin.js'),
      'install', '--from-profile', profile, ...extra], { cwd: dir, env, encoding: 'utf8' });
    const dry = invoke(['--dry-run']);
    assert.equal(dry.status, 0, dry.stderr);
    assert.match(dry.stdout, /instruction card \+ probe for \d+ secret\(s\)/);
    assert(!fs.existsSync(path.join(dir, '.himmel/himmel.conf')));
    assert.equal(read(envFile).includes('CR_PROFILE='), true);
    const applied = invoke([]);
    assert.equal(applied.status, 0, applied.stderr);
    const conf = path.join(dir, '.himmel/himmel.conf');
    assert.equal(load(conf, 'USER_SLUG'), 'USER_SLUG=wizard-user');
    assert.equal(load(conf, 'CR_PROFILE'), 'CR_PROFILE=legacy-integration');
    assert.deepEqual(JSON.parse(read(policy)).policy, JSON.parse(originalPolicy).policy);
    assert.equal(read(envFile), 'JIRA_API_TOKEN=fixture-secret-sentinel\nCR_FLOOR_FALLBACK=claude-only\n');
    for (const value of ['legacy-integration', 'fixture-secret-sentinel']) assert(!(applied.stdout + applied.stderr).includes(value));
  });
  console.log(`PASS: ${passed} himmel.conf wizard cases`);
}
main().catch(e => { console.error(e); process.exitCode = 1; });
NODE
