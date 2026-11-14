#!/usr/bin/env node
//   role                      publisher | adopter | unreadable
//   route [--state]           the validated choices as JSON, or the state word alone
//   listed <abs>              exit 0 when the real path is a listed root, 1 when not
//   root-check <abs>          exit 0, or 1 with one reason per line
//   out <name>                the corpus's graph directory
//   pending <name>            the waiting batch's directory, or nothing
//   sentence [--state S | --fix preflight|credential|helper]
//   worst-case | remedy | first-question | check | lane-runners | alert-lines <cause>
//
// Seams: HIMMEL_CONFIG_DIR (the station dir, default ~/.himmel), HIMMEL_CONFIG_AUDIT_DIR (config-audit's state dir)
// and GRAPHMAP_BAT_DIR (the runner dir), each the one its writer uses.
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');

const HIMMEL_ROOT = path.resolve(__dirname, '..', '..', '..');

const NO_CHOICE_SENTENCE = 'Without a graph choice, graphify builds the code structure from a local parse for free, and a semantic pass that runs on a repo other than himmel describes its markdown on this machine\'s Claude subscription, only after a usage check and never on an API key; choose none to keep the structure only.';
const NONE_SENTENCE = 'With the graph choice none, graphify builds only the code structure from a local parse, with no model calls and no cost.';
const SET_SENTENCE = 'This station\'s graph choice runs through its daily graph job on the repos it lists; this run makes no semantic call.';
const INVALID_SENTENCE = 'The graph choice in ~/.himmel/config.json is not valid, so no semantic call runs; the doctor (C88) names the problem.';
const CHECK_DEFAULT_LINE = 'no graph choice: a semantic pass on a repo other than himmel uses this machine\'s Claude subscription after the usage check, never an API key';
const WORST_DEFAULT_LINE = 'With no graph choice: a semantic pass that runs uses this machine\'s Claude subscription; usage is checked once, before the run starts, and the run does not stop if the budget runs out while it works.';
const WORST_SUBSCRIPTION_LINE = 'The subscription step: up to 150 markdown files a fire; usage is checked once, before the run starts, and the run does not stop if the budget runs out while it works.';
const WORST_NONE_LINE = 'With the graph choice none: nothing is spent.';
const WORST_REFUSED_LINE = 'While the graph choice cannot be used, nothing is spent.';

const FIX_PREFLIGHT = 'sign the claude CLI in on this machine; or, to stop semantic passes here, set graphify.choices to {"version":1,"corpora":[],"primary":"none"} in ~/.himmel/config.json and run bash scripts/lib/config-audit.sh accept';
const FIX_CREDENTIAL = 'remove the variable from this job\'s environment (crontab or shell profile); or stop semantic passes here as FIX_PREFLIGHT says';
const FIX_HELPER = 'remove apiKeyHelper from ~/.claude/settings.json, or set GRAPHIFY_CLAUDE_SOURCE_CONFIG_DIR to a Claude config without it; or stop semantic passes here as FIX_PREFLIGHT says';
const FIX = { preflight: FIX_PREFLIGHT, credential: FIX_CREDENTIAL, helper: FIX_HELPER };

const SENTENCES = { default: NO_CHOICE_SENTENCE, none: NONE_SENTENCE, set: SET_SENTENCE, invalid: INVALID_SENTENCE };

const CAUSE_LINES = {
  symlink: '~/.himmel or ~/.himmel/config.json is a symlink; put the real file in its place, then run bash scripts/lib/config-audit.sh accept',
  'not-a-file': '~/.himmel/config.json is not a regular file; restore it from a config-audit backup (bash scripts/lib/config-audit.sh restore <id>) or rewrite it by hand',
  mode: '~/.himmel/config.json cannot be read by this user; fix its mode (chmod 600 ~/.himmel/config.json)',
  'not-json': '~/.himmel/config.json is not a JSON object; restore it from a config-audit backup (bash scripts/lib/config-audit.sh restore <id>) or fix it by hand',
  empty: '~/.himmel/config.json is empty; restore it from a config-audit backup (bash scripts/lib/config-audit.sh restore <id>)',
  'graphify-shape': 'the graphify key in ~/.himmel/config.json is not an object (or semantic_api_ok is neither true nor false); fix it by hand, then run bash scripts/lib/config-audit.sh accept',
  missing: '~/.himmel/config.json is missing while this station publishes the himmel graph (an armed publisher runner or the last healthy read says so)',
  'publisher-key-lost': 'graphify.semantic_api_ok is no longer true in ~/.himmel/config.json while this station publishes the himmel graph (an armed publisher runner or the last healthy read says so)',
};

const LEAVE_PUBLISHER = 'to stop publishing on purpose instead, run bash scripts/lib/config-audit.sh accept, then bash scripts/luna/graphmap-cadence.sh arm --rewrite-armed --leave-publisher';
const FIX_LINES = {
  symlink: 'replace the symlink with the real file: put the real directory at ~/.himmel and the real config.json in it, then run bash scripts/lib/config-audit.sh accept',
  'not-a-file': 'replace ~/.himmel/config.json with a regular JSON file by hand (something else is at that path), then run bash scripts/lib/config-audit.sh accept',
  mode: 'run chmod 600 ~/.himmel/config.json so this user can read it',
  'not-json': 'restore the config with one of the two restore lines below, or write the file by hand and run bash scripts/lib/config-audit.sh accept',
  empty: 'restore the config with one of the two restore lines below, or write the file by hand and run bash scripts/lib/config-audit.sh accept',
  'graphify-shape': 'restore the config with one of the two restore lines below, or fix the graphify key by hand and run bash scripts/lib/config-audit.sh accept',
  missing: `restore the config with one of the two restore lines below; ${LEAVE_PUBLISHER}`,
  'publisher-key-lost': `restore the config with one of the two restore lines below; ${LEAVE_PUBLISHER}`,
};
const RESTORE_TELEGRAM_LINE = 'restore from Telegram: /config restore <id> <code>';
const RESTORE_TERMINAL_LINE = 'restore in your own terminal: bash scripts/lib/config-audit.sh restore <id>';
const BY_HAND_CAUSES = ['symlink', 'not-a-file', 'mode'];
const CONSENT_KEYS = ['graphify.salus_ollama_cloud_ok', 'graphify.semantic_api_ok', 'graphify.choices.primary', 'graphify.choices.fallbacks', 'graphify.choices.corpora'];
const BACKUP_ID = /^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{4}$/;

const ROSTER_LINES = {
  'unreadable-state': 'no API account is set up here, or its roster cannot be read; none is offered',
  'missing-account-config': 'the API roster lists no account',
  'invalid-account-config': 'a row in the API roster names a letter outside <ACCOUNTS>, or is damaged; the whole roster is refused, so no account runs',
};

function accountLetters() {
  try { return require('../../lib/api-credit-state.mjs').ACCOUNTS.join(', '); } catch { return 'the supported letters'; }
}

function rosterLine(word) {
  if (word === 'invalid-account-config') return ROSTER_LINES[word].replace('<ACCOUNTS>', accountLetters());
  if (Object.prototype.hasOwnProperty.call(ROSTER_LINES, word)) return ROSTER_LINES[word];
  return `the API roster is refused (${String(word).replace(/[^A-Za-z0-9_-]/g, '?')}); no account runs`;
}

function homeDir() { return process.env.HOME || os.homedir(); }
function stationDir() { return process.env.HIMMEL_CONFIG_DIR || path.join(homeDir(), '.himmel'); }
function configFile() { return path.join(stationDir(), 'config.json'); }

const plainObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const own = (o, k) => Object.prototype.hasOwnProperty.call(o, k);

function linkedPublisher(file) {
  try {
    const doc = JSON.parse(fs.readFileSync(file, 'utf8'));
    return plainObject(doc) && plainObject(doc.graphify) && doc.graphify.semantic_api_ok === true;
  } catch { return false; }
}

const sha256 = (text) => crypto.createHash('sha256').update(text).digest('hex');
const TRUE_DIGEST = sha256('true');

function runnerDir() { return process.env.GRAPHMAP_BAT_DIR || path.join(homeDir(), '.claude', 'graphmap-cadence'); }
function auditDir() { return process.env.HIMMEL_CONFIG_AUDIT_DIR || path.join(stationDir(), 'state', 'config-audit'); }

function readRegular(file, max = 4 * 1024 * 1024) {
  try {
    const st = fs.lstatSync(file);
    if (!st.isFile() || st.size > max) return null;
    return fs.readFileSync(file, 'utf8');
  } catch { return null; }
}

function readJsonRegular(file) {
  const text = readRegular(file);
  if (text === null) return undefined;
  try { return JSON.parse(text); } catch { return undefined; }
}

const RUNNER_NAME = /^graphmap-[A-Za-z0-9._-]+\.sh$/;
const PUBLISH_RUNNER = 'graphmap-publish-himmel.sh';

function laneRunners() {
  let names;
  try { names = fs.readdirSync(runnerDir()); } catch { return []; }
  const out = [];
  for (const name of names.filter((n) => RUNNER_NAME.test(n)).sort()) {
    const text = readRegular(path.join(runnerDir(), name), 1024 * 1024);
    if (text === null || !text.includes('HIMMEL_API_LANE=on')) continue;
    const m = /HIMMEL_API_ACCOUNT=(\S+)/.exec(text);
    out.push({ name, pin: m && (m[1] === 'auto' || LETTER.test(m[1])) ? m[1] : '' });
  }
  return out;
}

function publisherFootprint() {
  const armedPublishRunner = laneRunners().some((r) => r.name === PUBLISH_RUNNER);
  const w = readJsonRegular(path.join(auditDir(), 'watch.json'));
  const d = plainObject(w) && plainObject(w['config.json']) ? w['config.json'].digests : null;
  const healthyReadHeldKey = plainObject(d) && d['graphify.semantic_api_ok'] === TRUE_DIGEST;
  return { armedPublishRunner, healthyReadHeldKey, any: armedPublishRunner || healthyReadHeldKey };
}

function missingStation() {
  return publisherFootprint().any ? { role: 'unreadable', cause: 'missing' } : { role: 'adopter', cause: '', doc: {} };
}

function readStation() {
  const dir = stationDir();
  const file = configFile();
  let st;
  try {
    if (fs.lstatSync(dir).isSymbolicLink()) return { role: 'unreadable', cause: 'symlink', linked: linkedPublisher(file) };
  } catch (e) {
    if (e && e.code === 'ENOENT') return missingStation();
    return { role: 'unreadable', cause: 'mode' };
  }
  try { st = fs.lstatSync(file); } catch (e) {
    if (e && e.code === 'ENOENT') return missingStation();
    return { role: 'unreadable', cause: 'mode' };
  }
  if (st.isSymbolicLink()) return { role: 'unreadable', cause: 'symlink', linked: linkedPublisher(file) };
  if (!st.isFile()) return { role: 'unreadable', cause: 'not-a-file' };
  let text;
  try { text = fs.readFileSync(file, 'utf8'); } catch { return { role: 'unreadable', cause: 'mode' }; }
  if (text.trim() === '') return { role: 'unreadable', cause: 'empty' };
  let doc;
  try { doc = JSON.parse(text); } catch { return { role: 'unreadable', cause: 'not-json' }; }
  if (!plainObject(doc)) return { role: 'unreadable', cause: 'not-json' };
  if (own(doc, 'graphify') && !plainObject(doc.graphify)) return { role: 'unreadable', cause: 'graphify-shape' };
  const g = doc.graphify || {};
  if (g.semantic_api_ok === true) return { role: 'publisher', cause: '', doc };
  if (publisherFootprint().any) {
    if (own(g, 'semantic_api_ok') && typeof g.semantic_api_ok !== 'boolean') return { role: 'unreadable', cause: 'graphify-shape' };
    return { role: 'unreadable', cause: 'publisher-key-lost' };
  }
  return { role: 'adopter', cause: '', doc };
}

const LETTER = /^[A-Z]$/;
const NAME = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const isRouteValue = (v) => v === 'subscription' || (typeof v === 'string' && LETTER.test(v));

function absoluteClean(p) {
  if (typeof p !== 'string' || !path.isAbsolute(p) || p.includes('\0')) return false;
  return !p.split(/[\\/]/).some((part) => part === '.' || part === '..');
}

function validateShape(choices) {
  const errors = [];
  if (!plainObject(choices)) return ['graphify.choices is not an object'];
  if (choices.version !== 1) errors.push('version is not 1');
  if (own(choices, 'corpora')) {
    if (!Array.isArray(choices.corpora)) errors.push('corpora is not a list');
    else {
      const seen = new Set();
      choices.corpora.forEach((c, i) => {
        if (!plainObject(c)) { errors.push(`corpus ${i + 1} is not an object`); return; }
        if (typeof c.name !== 'string' || !NAME.test(c.name)) errors.push(`corpus ${i + 1} has a name that is not letters, digits, dot, dash or underscore starting with a letter or digit`);
        else if (seen.has(c.name)) errors.push(`corpus ${i + 1} repeats a name`);
        else seen.add(c.name);
        if (!absoluteClean(c.root)) errors.push(`corpus ${i + 1} has a root that is not an absolute path without . or .. parts`);
      });
    }
  }
  const hasPrimary = own(choices, 'primary');
  const fallbacks = own(choices, 'fallbacks') ? choices.fallbacks : [];
  if (!Array.isArray(fallbacks)) errors.push('fallbacks is not a list');
  if (hasPrimary && choices.primary !== 'none' && !isRouteValue(choices.primary)) errors.push('primary is not none, subscription or one capital letter');
  const fb = Array.isArray(fallbacks) ? fallbacks : [];
  fb.forEach((v, i) => { if (!isRouteValue(v)) errors.push(`fallback ${i + 1} is not subscription or one capital letter`); });
  if (!hasPrimary && fb.length > 0) errors.push('fallbacks are set without a primary');
  if (choices.primary === 'none' && fb.length > 0) errors.push('primary none takes no fallbacks');
  const route = (hasPrimary && choices.primary !== 'none' ? [choices.primary] : []).concat(fb);
  if (new Set(route).size !== route.length) errors.push('a route value appears more than once');
  if (route.some((v) => typeof v === 'string' && LETTER.test(v))) {
    const cap = choices.max_usd_per_pass;
    if (typeof cap !== 'number' || !Number.isFinite(cap) || cap < 0.25) errors.push('max_usd_per_pass is missing or under 0.25 while an API account is in the route');
  } else if (own(choices, 'max_usd_per_pass')) {
    const cap = choices.max_usd_per_pass;
    if (typeof cap !== 'number' || !Number.isFinite(cap) || cap < 0.25) errors.push('max_usd_per_pass is under 0.25 or not a number');
  }
  return errors;
}

function rootCheck(root) {
  if (!absoluteClean(root)) return ['the root is not an absolute path without . or .. parts'];
  let real;
  try { real = fs.realpathSync(root); } catch { return ['the root does not exist']; }
  const errors = [];
  if (real !== root) errors.push('the root is not stored as its real path');
  try { if (!fs.statSync(real).isDirectory()) errors.push('the root is not a directory'); } catch { errors.push('the root cannot be read'); }
  if (!fs.existsSync(path.join(real, '.git'))) errors.push('the root holds no .git entry');
  return errors.concat(classifierErrors(real));
}

function resolveBash() { return process.env.HIMMELCTL_BASH || 'bash'; }

function classifierErrors(real) {
  const wrapper = path.join(HIMMEL_ROOT, 'scripts', 'guardrails', 'graphify-classify.sh');
  const r = require('child_process').spawnSync(resolveBash(), [wrapper, real], { encoding: 'utf8', timeout: 30000 });
  if (r.error || r.status !== 0) return ['the root cannot be classified (the egress classifier failed or refused), so it is refused'];
  const cls = r.stdout.split('\n')[0].trim();
  if (!cls) return [];
  return [`the root is in the ${cls.replace(/[^A-Za-z0-9-]/g, '?')} corpus class at, above or below it (a vault, a salus or PHI root, the handover state or the himmel checkout), so it is refused`];
}

function rosterCheck(choices, accounts) {
  const route = plainObject(choices)
    ? (choices.primary && choices.primary !== 'none' ? [choices.primary] : []).concat(Array.isArray(choices.fallbacks) ? choices.fallbacks : [])
    : [];
  const letters = route.filter((v) => typeof v === 'string' && LETTER.test(v));
  if (letters.length === 0) return [];
  if (plainObject(accounts) && accounts.accounts === 'unreadable') return [rosterLine(accounts.reason)];
  const rows = Array.isArray(accounts) ? accounts : [];
  return letters.filter((l) => !rows.some((r) => plainObject(r) && r.account === l && r.configured === true))
    .map((l) => `${l} is not a configured API account`);
}

function route(station = readStation()) {
  if (station.role === 'unreadable') return { state: 'unreadable', corpora: [], order: [], max_usd_per_pass: null, errors: [] };
  const g = station.doc.graphify || {};
  if (!own(g, 'choices')) return { state: 'default', corpora: [], order: ['subscription'], max_usd_per_pass: null, errors: [] };
  const c = g.choices;
  const errors = validateShape(c);
  if (errors.length) return { state: 'invalid', corpora: [], order: [], max_usd_per_pass: null, errors };
  const corpora = (c.corpora || []).map((x) => ({ name: x.name, root: x.root }));
  const cap = own(c, 'max_usd_per_pass') ? c.max_usd_per_pass : null;
  if (!own(c, 'primary')) return { state: 'default', corpora, order: ['subscription'], max_usd_per_pass: cap, errors: [] };
  if (c.primary === 'none') return { state: 'none', corpora, order: [], max_usd_per_pass: cap, errors: [] };
  return { state: 'set', corpora, order: [c.primary].concat(c.fallbacks || []), max_usd_per_pass: cap, errors: [] };
}

function isGitInstall() { return fs.existsSync(path.join(HIMMEL_ROOT, '.git')); }

function outDir(name) {
  const base = process.env.XDG_DATA_HOME || path.join(homeDir(), '.local', 'share');
  return path.join(base, 'himmel', 'graphify', 'choices', name, 'graphify-out');
}

function remedy(role) {
  if (role === 'publisher') return 'this station builds the himmel graph itself: the HIMMEL-GraphMap-Himmel cadence refreshes it (bash scripts/luna/graphmap-cadence.sh status)';
  if (!isGitInstall()) return 'this release install has no himmel graph; a git install pulls it from us with each update';
  return 'the himmel graph on this station comes from us: run bash scripts/himmel-update.sh to pull the latest published graph';
}

function firstQuestion() {
  if (!isGitInstall()) return 'This release install has no himmel graph; a git install pulls it from us.';
  return 'The himmel code graph comes from us with each update; you do not build it.';
}

function worstCase(r) {
  if (r.state === 'default') return [WORST_DEFAULT_LINE];
  if (r.state === 'none') return [WORST_NONE_LINE];
  if (r.state !== 'set') return [WORST_REFUSED_LINE];
  const lines = [];
  const letters = r.order.filter((v) => LETTER.test(v));
  if (letters.length) lines.push(`The API steps (${letters.join(', ')}): up to ${Number(r.max_usd_per_pass).toFixed(2)} USD a day, as an estimate; one new batch a fire at most, refused when its estimate is over the cap.`);
  if (r.order.includes('subscription')) lines.push(WORST_SUBSCRIPTION_LINE);
  return lines;
}

function passLines() {
  const log = path.join(homeDir(), '.claude', 'graph-choices-cadence', 'graph-choices.log');
  let text;
  try { text = fs.readFileSync(log, 'utf8'); } catch { return null; }
  const out = [];
  for (const raw of text.split('\n')) {
    const line = raw.trim();
    if (!line || line.startsWith('[')) continue;
    const parts = line.split(/\s+/);
    if (parts.length < 3 || !NAME.test(parts[1])) continue;
    const safe = (s) => s.replace(/[^A-Za-z0-9._:-]/g, '?');
    if (parts[2] === 'ALERT' && parts.length >= 4) out.push({ corpus: parts[1], alert: true, word: safe(parts[3]), reason: parts.slice(4).join(' ').replace(/[^ -~]/g, '?').slice(0, 200) });
    else out.push({ corpus: parts[1], alert: false, word: safe(parts[2]) });
  }
  return out;
}

function rosterAnswer() {
  try {
    const { execFileSync } = require('child_process');
    const out = execFileSync(process.execPath, [path.join(HIMMEL_ROOT, 'scripts', 'lib', 'api-credit-state.mjs'), 'accounts'],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 20000 });
    return JSON.parse(out);
  } catch { return { accounts: 'unreadable', reason: 'unreadable-state' }; }
}

function configUsable(doc) {
  if (!plainObject(doc)) return false;
  if (own(doc, 'graphify')) {
    if (!plainObject(doc.graphify)) return false;
    if (own(doc.graphify, 'semantic_api_ok') && typeof doc.graphify.semantic_api_ok !== 'boolean') return false;
    if (own(doc.graphify, 'choices') && validateShape(doc.graphify.choices).length) return false;
  }
  return true;
}

const holdsPublisherKey = (doc) => plainObject(doc.graphify) && doc.graphify.semantic_api_ok === true;

function chooseBackup(cause, footprint) {
  const base = path.join(auditDir(), 'backups');
  let ids;
  try { ids = fs.readdirSync(base).filter((d) => BACKUP_ID.test(d)); } catch { return null; }
  const all = [];
  for (const id of ids) {
    const dir = path.join(base, id);
    const man = readJsonRegular(path.join(dir, 'manifest.json'));
    if (plainObject(man)) all.push({ id, dir, man });
  }
  all.sort((x, y) => ((Number(y.man.ms) || 0) - (Number(x.man.ms) || 0)) || (x.id < y.id ? 1 : -1));
  const needsKey = cause === 'missing' || cause === 'publisher-key-lost';
  for (const watcher of [true, false]) {
    for (const b of all) {
      if ((b.man.script === 'watch') !== watcher) continue;
      const doc = readJsonRegular(path.join(b.dir, 'config.json'));
      if (!configUsable(doc)) continue;
      const holds = holdsPublisherKey(doc);
      if ((needsKey || footprint) ? !holds : holds) continue;
      return { id: b.id, kind: watcher ? 'watch' : 'audited', doc, man: b.man };
    }
  }
  return null;
}

function leafAt(doc, dotted) {
  const parts = dotted.split('.');
  let cur = doc;
  for (let i = 0; i < parts.length; i++) {
    if (!plainObject(cur) || !own(cur, parts[i])) return { found: false };
    cur = cur[parts[i]];
    if (i < parts.length - 1 && !(plainObject(cur) && Object.keys(cur).length)) return { found: false };
  }
  if (plainObject(cur) && Object.keys(cur).length) return { found: false };
  return { found: true, value: cur };
}

const printable = (s) => String(s).replace(/[^ -~]/g, '?');

function consentText(key, v) {
  if (key === 'graphify.choices.primary') return typeof v === 'string' && (v === 'none' || v === 'subscription' || LETTER.test(v)) ? v : '?';
  if (key === 'graphify.choices.fallbacks') return Array.isArray(v) && v.every(isRouteValue) ? (v.length ? v.join(',') : '(none)') : '?';
  if (key === 'graphify.choices.corpora') {
    return Array.isArray(v) && v.every((c) => plainObject(c) && absoluteClean(c.root)) ? (v.length ? v.map((c) => printable(c.root)).join(' ') : '(none)') : '?';
  }
  return typeof v === 'boolean' ? String(v) : '?';
}

function liveSha(file) {
  try { return sha256(fs.readFileSync(file)); } catch { return null; }
}

function unreadableLines(station) {
  const cause = station.cause;
  const lines = [];
  const fp = publisherFootprint();
  lines.push(`cause=${cause}`);
  if (cause === 'symlink') {
    lines.push(`linked=${station.linked ? 'publisher' : 'not-publisher'}`);
    lines.push(`footprint=${fp.any ? 'publisher' : 'none'}`);
  }
  lines.push(`graph config unreadable (cause=${cause}): ${CAUSE_LINES[cause]}`);
  const chosen = BY_HAND_CAUSES.includes(cause) ? null : chooseBackup(cause, fp.any);
  lines.push(`fix=${chosen ? 'restore' : 'by-hand'}`);
  if (chosen) {
    lines.push(`backup=${chosen.id} kind=${chosen.kind}`);
    const w = readJsonRegular(path.join(auditDir(), 'watch.json'));
    const digests = plainObject(w) && plainObject(w['config.json']) && plainObject(w['config.json'].digests) ? w['config.json'].digests : {};
    for (const key of CONSENT_KEYS) {
      const leaf = leafAt(chosen.doc, key);
      if (!leaf.found) continue;
      const marked = digests[key] !== sha256(JSON.stringify(leaf.value));
      lines.push(`consent ${key} restores=${consentText(key, leaf.value)}${marked ? ' [differs from the last healthy copy]' : ''}`);
    }
    const files = plainObject(chosen.man.files) ? chosen.man.files : {};
    for (const member of ['himmel.conf', 'himmel.conf.local', '.env']) {
      const f = files[member];
      if (!plainObject(f) || typeof f.sha256 !== 'string' || typeof f.path !== 'string' || !path.isAbsolute(f.path)) continue;
      if (liveSha(f.path) !== f.sha256) lines.push(`${member} will also be rolled back`);
    }
    lines.push(RESTORE_TELEGRAM_LINE.split('<id>').join(chosen.id));
    lines.push(RESTORE_TERMINAL_LINE.split('<id>').join(chosen.id));
  }
  if (!chosen && !BY_HAND_CAUSES.includes(cause)) lines.push('no usable config backup exists, so no restore line applies: write the file by hand');
  lines.push(`fix-line: ${FIX_LINES[cause]}`);
  return lines;
}

function check() {
  const station = readStation();
  const lines = [`role=${station.role}`];
  if (station.role === 'unreadable') return lines.concat(unreadableLines(station));
  const r = route(station);
  lines.push(`state=${r.state}`);
  if (station.role === 'adopter' && r.state === 'default') lines.push(CHECK_DEFAULT_LINE);
  if (r.state === 'invalid') r.errors.forEach((e) => lines.push(`invalid: ${e}`));
  const log = passLines();
  if (log === null || log.length === 0) lines.push('pass: no pass yet');
  else {
    const last = new Map();
    const open = new Map();
    for (const e of log) {
      if (e.alert) open.set(e.corpus, e);
      else { last.set(e.corpus, e.word); open.delete(e.corpus); }
    }
    for (const [corpus, word] of last) lines.push(`pass: ${corpus} ${word}`);
    let refused = 0;
    for (let i = log.length - 1; i >= 0; i--) {
      if (log[i].alert) continue;
      if (log[i].word !== 'bank-refused') break;
      refused += 1;
    }
    lines.push(`bank-refused in a row: ${refused}`);
    for (const e of open.values()) lines.push(`alert: ${e.corpus} ${e.word} ${e.reason}`.trimEnd());
  }
  const roster = rosterAnswer();
  if (plainObject(roster) && roster.accounts === 'unreadable') lines.push(`roster: ${rosterLine(roster.reason)}`);
  else if (Array.isArray(roster)) {
    const configured = roster.filter((x) => plainObject(x) && x.configured === true).map((x) => x.account);
    lines.push(`roster: ${configured.length ? `configured ${configured.join(', ')}` : 'no API account is configured'}`);
  }
  return lines;
}

function realOrSelf(p) { try { return fs.realpathSync(p); } catch { return p; } }

function main(argv) {
  const [verb, ...args] = argv;
  const say = (s) => process.stdout.write(`${s}\n`);
  switch (verb) {
    case 'role': say(readStation().role); return 0;
    case 'route': {
      const r = route();
      if (args[0] === '--state') say(r.state); else say(JSON.stringify(r));
      return 0;
    }
    case 'listed': {
      if (!args[0] || !path.isAbsolute(args[0])) return 1;
      const want = realOrSelf(args[0]);
      return route().corpora.some((c) => realOrSelf(c.root) === want) ? 0 : 1;
    }
    case 'root-check': {
      const errors = rootCheck(args[0]);
      errors.forEach(say);
      return errors.length ? 1 : 0;
    }
    case 'out':
      if (!args[0] || !NAME.test(args[0])) { process.stderr.write('graph-choices: out needs a corpus name\n'); return 1; }
      say(outDir(args[0])); return 0;
    case 'pending': {
      if (!args[0] || !NAME.test(args[0])) return 1;
      const dir = path.join(outDir(args[0]), 'semantic-batch');
      if (fs.existsSync(path.join(dir, 'batch.json'))) say(dir);
      return 0;
    }
    case 'sentence': {
      if (args[0] === '--fix') {
        if (!own(FIX, args[1] || '')) { process.stderr.write('graph-choices: sentence --fix preflight|credential|helper\n'); return 1; }
        say(FIX[args[1]]); return 0;
      }
      if (args[0] === '--state') {
        if (!own(SENTENCES, args[1] || '')) { process.stderr.write('graph-choices: sentence --state default|none|set|invalid\n'); return 1; }
        say(SENTENCES[args[1]]); return 0;
      }
      const state = route().state;
      if (own(SENTENCES, state)) say(SENTENCES[state]);
      return 0;
    }
    case 'worst-case': worstCase(route()).forEach(say); return 0;
    case 'remedy': say(remedy(readStation().role)); return 0;
    case 'first-question': say(firstQuestion()); return 0;
    case 'check': check().forEach(say); return 0;
    case 'lane-runners': laneRunners().forEach((r) => say(r.pin ? `${r.name} ${r.pin}` : r.name)); return 0;
    case 'alert-lines':
      if (!own(FIX_LINES, args[0] || '')) { process.stderr.write('graph-choices: alert-lines needs one of the eight cause words\n'); return 1; }
      say(`graph config unreadable (cause=${args[0]}): ${CAUSE_LINES[args[0]]}`); say(FIX_LINES[args[0]]); return 0;
    default:
      process.stderr.write('usage: graph-choices.js role|route [--state]|listed <abs>|root-check <abs>|out <name>|pending <name>|sentence [--state S|--fix F]|worst-case|remedy|first-question|check|lane-runners|alert-lines <cause>\n');
      return 2;
  }
}

module.exports = {
  NO_CHOICE_SENTENCE, NONE_SENTENCE, SET_SENTENCE, INVALID_SENTENCE, CHECK_DEFAULT_LINE, WORST_DEFAULT_LINE,
  FIX_PREFLIGHT, FIX_CREDENTIAL, FIX_HELPER, ROSTER_LINES, CAUSE_LINES, FIX_LINES, RESTORE_TELEGRAM_LINE, RESTORE_TERMINAL_LINE,
  validateShape, rootCheck, rosterCheck, route, readStation, laneRunners,
};

if (require.main === module) process.exitCode = main(process.argv.slice(2));
