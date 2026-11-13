// The API account role map. roles.json sits beside the account roster config.json and says
// which accounts (A, B, C) auto routing may use for each routable kind. It holds no secret. No map is
// decision 525 exactly; a broken map only takes away widening, it never refuses more and never touches
// config.json. This module is the one owner of reading, validating and writing the file; it caches
// nothing, so a fixed file takes effect on the next call.
import { closeSync, fsyncSync, mkdirSync, openSync, readFileSync, renameSync, unlinkSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { ACCOUNTS, configPathFor, configuredLetters } from './api-credit-state.mjs';

// The only kinds with an auto caller. probe and other are never roles (a probe names its account; other
// is the unlabelled default). Plan P2 adds a kind in the same change as its caller.
export const ROLES = ['graphify', 'judge'];

export const rolesPathFor = (env = process.env) => join(dirname(configPathFor(env)), 'roles.json');

const object = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
// An error names the value it refused. String() throws for an object such as {"toString":null}, and one bad letter
// must never discard the valid entries beside it, so any non-string is named by its JSON text.
const show = (v) => (typeof v === 'string' ? v : JSON.stringify(v));

// Lenient read. state: absent | valid | partial | invalid.
export function roleMap(env = process.env) {
  const roles = Object.create(null);
  const invalid = (reason) => ({ state: 'invalid', roles: Object.create(null), errors: [`invalid-role-map:${reason}`] });
  let text;
  try { text = readFileSync(rolesPathFor(env), 'utf8'); } catch (e) {
    return e.code === 'ENOENT' ? { state: 'absent', roles, errors: [] } : invalid('unreadable');
  }
  let doc;
  try { doc = JSON.parse(text); } catch { return invalid('not-json'); }
  if (!object(doc) || doc.version !== 1) return invalid('version');
  if (!object(doc.roles)) return invalid('roles-shape');
  const errors = [];
  for (const [role, value] of Object.entries(doc.roles)) {
    if (!ROLES.includes(role)) { errors.push(`unknown-role:${role}`); continue; }
    const live = [];
    if (Array.isArray(value)) {
      for (const letter of value) {
        if (ACCOUNTS.includes(letter)) { if (!live.includes(letter)) live.push(letter); }
        else { const e = `unknown-account:${role}:${show(letter)}`; if (!errors.includes(e)) errors.push(e); }
      }
    }
    if (live.length === 0) { errors.push(`empty-role:${role}`); continue; }
    roles[role] = live;
  }
  return { state: errors.length ? 'partial' : 'valid', roles, errors };
}

// The live accounts for one kind. A kind outside ROLES (constructor, __proto__, probe) never matches.
export function accountsFor(map, kind) {
  return ROLES.includes(kind) && Object.hasOwn(map.roles, kind) ? map.roles[kind] : [];
}

// Strict check for a save: the full doc {"version":1,"roles":{...}}. Names errors, never coerces.
export function validateStrict(doc) {
  if (!object(doc)) return ['invalid-doc'];
  const errors = [];
  if (doc.version !== 1) errors.push('invalid-version');
  if (!object(doc.roles)) { errors.push('invalid-roles-shape'); return errors; }
  for (const [role, value] of Object.entries(doc.roles)) {
    if (!ROLES.includes(role)) { errors.push(`unknown-role:${role}`); continue; }
    if (!Array.isArray(value) || value.length === 0) { errors.push(`empty-role:${role}`); continue; }
    for (const letter of value) {
      const e = `unknown-account:${role}:${show(letter)}`;
      if (!ACCOUNTS.includes(letter) && !errors.includes(e)) errors.push(e);
    }
  }
  return errors;
}

// Validate, then write {"version":1,"roles":...} atomically with mode 600; an empty roles object removes the
// file. Only version and roles are ever written, so no other key (and no secret) reaches the file.
export function writeRoles(env, doc) {
  const errors = validateStrict(doc);
  if (errors.length) return { ok: false, errors };
  const path = rolesPathFor(env);
  const roles = {};
  for (const [role, letters] of Object.entries(doc.roles)) roles[role] = [...new Set(letters)];
  if (Object.keys(roles).length === 0) {
    try { unlinkSync(path); } catch (e) { if (e.code !== 'ENOENT') throw e; }
    return { ok: true, errors: [] };
  }
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const temporary = `${path}.${process.pid}.tmp`;
  try {
    const fd = openSync(temporary, 'wx', 0o600);
    try { writeFileSync(fd, `${JSON.stringify({ version: 1, roles }, null, 2)}\n`); fsyncSync(fd); } finally { closeSync(fd); }
    renameSync(temporary, path);
  } catch (e) {
    try { unlinkSync(temporary); } catch { /* nothing to clean */ }
    throw e;
  }
  return { ok: true, errors: [] };
}

// The one stderr line for the caller's own kind, or ''.
function noteFor(map, kind) {
  if (map.state === 'invalid') return ROLES.includes(kind) ? `claude-api: role map invalid (${map.errors[0]}); the map is ignored, so auto routing stays limited to the graph pass. Fix or remove roles.json` : '';
  if (!ROLES.includes(kind)) return '';
  const own = map.errors.filter((e) => e.split(':')[1] === kind);
  const empty = own.find((e) => e.startsWith('empty-role:'));
  if (empty) return `claude-api: role map: ${kind} entry ignored (${empty}); ${kind} gets no account from it. Add an account to it or remove it`;
  if (own.length) return `claude-api: role map: ${kind} entry kept as [${accountsFor(map, kind).join(',')}] (${own.join(', ')})`;
  return '';
}

// The station's graph walk, decided here once for every graph path. The two kinds of damage that would widen the
// walk to every configured account (an invalid map, a graphify entry with no letter) refuse; every other map walks
// as before: the live graphify letters, else every configured letter, else ACCOUNTS when the roster cannot be read
// (pick then refuses on the same roster).
export function walkGraphify(env = process.env) {
  const map = roleMap(env);
  if (map.state === 'invalid') return { refuse: map.errors[0] };
  if (map.errors.includes('empty-role:graphify')) return { refuse: 'empty-role:graphify' };
  const live = accountsFor(map, 'graphify');
  if (live.length) return { letters: live, note: noteFor(map, 'graphify') };
  try { return { letters: configuredLetters(env), note: noteFor(map, 'graphify') }; } catch { return { letters: ACCOUNTS, note: noteFor(map, 'graphify') }; }
}

function main() {
  const [command, ...args] = process.argv.slice(2);
  if (command === 'walk' && args[0] === 'graphify' && args.length === 1) {
    const walk = walkGraphify(process.env);
    if (walk.refuse) { console.log(`refuse ${walk.refuse}`); process.exitCode = 3; return; }
    if (walk.note) console.error(walk.note);
    console.log(walk.letters.join(','));
    return;
  }
  if (command === 'accounts') {
    // always exits 0: a failed read is "no map", which is decision 525
    try {
      const map = roleMap(process.env);
      const note = noteFor(map, args[0]);
      if (note) console.error(note);
      const live = accountsFor(map, args[0]);
      if (live.length) console.log(live.join(','));
    } catch { /* decision 525 */ }
    return;
  }
  if (command === 'check') {
    const map = roleMap(process.env);
    // a live entry none of whose letters has a roster row routes nothing; an unreadable roster gives no warnings
    let accounts = 'ok', warnings = [];
    try {
      const configured = configuredLetters(process.env);
      warnings = Object.entries(map.roles).filter(([, letters]) => !letters.some((l) => configured.includes(l)))
        .map(([role]) => `no-configured-account:${role}`);
    } catch { accounts = 'unreadable'; }
    console.log(JSON.stringify({ roleMap: { state: map.state, roles: map.roles, errors: map.errors }, warnings, ROLES, accounts }));
    return;
  }
  if (command === 'write') {
    let doc;
    try { doc = JSON.parse(readFileSync(0, 'utf8')); } catch { console.log(JSON.stringify({ ok: false, errors: ['invalid-json'] })); process.exitCode = 3; return; }
    const result = writeRoles(process.env, doc);
    console.log(JSON.stringify(result));
    if (!result.ok) process.exitCode = 3;
    return;
  }
  console.error('usage: api-roles.mjs accounts <kind> | walk graphify | check | write');
  process.exitCode = 2;
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) main();
