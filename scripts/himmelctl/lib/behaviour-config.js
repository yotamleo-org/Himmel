'use strict';
// scripts/himmelctl/lib/behaviour-config.js — behaviour-config keys
// (HIMMEL_INITIATIVE, HANDOVER_DIR, commit rules) live in the tracked config
// file ~/.himmel/himmel.conf, not the clone .env. Reads layer the same way
// scripts/lib/load-dotenv.sh does: himmel.conf.local, then himmel.conf, then the
// legacy clone .env (still honoured until scripts/setup/migrate-env-config.sh
// has moved the key). Writes go to himmel.conf only.

const fs = require('fs');
const os = require('os');
const path = require('path');
const probesLib = require('./probes.js');

function confPath() {
  return path.join(os.homedir(), '.himmel', 'himmel.conf');
}

function confLocalPath() {
  return `${confPath()}.local`;
}

// Absent file -> null. Any other read error rethrows: an unreadable file must
// not read as unset, or a toggle would derive its replacement from an empty
// value and drop every token already stored.
function readParsed(file) {
  let raw;
  try {
    raw = fs.readFileSync(file, 'utf8');
  } catch (e) {
    if (e && e.code === 'ENOENT') return null;
    throw e;
  }
  return probesLib.parseDotEnv(raw);
}

// { value, file } for KEY from the first layer that sets it non-empty;
// { value: '', file: confPath() } when none does (file = where a set lands).
function readConfigVar(key, legacyEnvFile) {
  for (const file of [confLocalPath(), confPath(), legacyEnvFile]) {
    if (!file) continue;
    const parsed = readParsed(file);
    if (parsed && parsed[key]) return { value: parsed[key], file };
  }
  return { value: '', file: confPath() };
}

// Every layer file that sets KEY non-empty, highest precedence first. An empty
// value reads as unset, so clearing a key means blanking it in each of these.
function layersSetting(key, legacyEnvFile) {
  const files = [];
  for (const file of [confLocalPath(), confPath(), legacyEnvFile]) {
    if (!file) continue;
    const parsed = readParsed(file);
    if (parsed && parsed[key]) files.push(file);
  }
  return files;
}

// The file a non-empty write of KEY must land in to take effect: the
// himmel.conf.local override when it sets KEY, else himmel.conf.
function writeTarget(key) {
  const local = confLocalPath();
  const parsed = readParsed(local);
  return parsed && parsed[key] ? local : confPath();
}

// Replace each key's line in place (first match; later duplicates dropped),
// append the missing ones, drop every dropKeys entry not in entries, leave every
// other line untouched. A line counts as the key's when the reader would read
// it as that key (leading whitespace allowed). Creates the file and its
// directory when absent; the write goes through a temp file and a rename. A
// linked file (the luna --vault layout) is written at its target, so the link
// survives.
function upsertConfEntries(link, entries, dropKeys) {
  const file = linkTarget(link);
  const isKey = (l, k) => l.trimStart().startsWith(`${k}=`);
  let lines = [];
  try { lines = fs.readFileSync(file, 'utf8').split('\n'); } catch (e) { if (e.code !== 'ENOENT') throw e; }
  if (lines.length > 0 && lines[lines.length - 1] === '') lines.pop();
  const kept = new Set(entries.map(([k]) => k));
  for (const k of dropKeys || []) {
    if (!kept.has(k)) lines = lines.filter((l) => !isKey(l, k));
  }
  for (const [k, v] of entries) {
    const idx = lines.findIndex((l) => isKey(l, k));
    if (idx === -1) { lines.push(`${k}=${v}`); continue; }
    lines[idx] = `${k}=${v}`;
    lines = lines.filter((l, i) => i <= idx || !isKey(l, k));
  }
  fs.mkdirSync(path.dirname(file), { recursive: true });
  let mode = 0o644;
  try { mode = fs.statSync(file).mode & 0o777; } catch (e) { if (e.code !== 'ENOENT') throw e; }
  const tmp = `${file}.${process.pid}.tmp`;
  try {
    fs.writeFileSync(tmp, `${lines.join('\n')}\n`, { mode });
    fs.renameSync(tmp, file);
  } catch (e) {
    try { fs.unlinkSync(tmp); } catch (_) { /* tmp never created */ }
    throw e;
  }
}

// The path a write to FILE must replace: FILE's resolved target when it is a
// link (dangling included), else FILE itself.
function linkTarget(file) {
  try { return fs.realpathSync(file); } catch (e) { if (e.code !== 'ENOENT') throw e; }
  try { return path.resolve(path.dirname(file), fs.readlinkSync(file)); } catch (e) { if (e.code !== 'ENOENT' && e.code !== 'EINVAL') throw e; }
  return file;
}

module.exports = { confPath, confLocalPath, readConfigVar, layersSetting, writeTarget, upsertConfEntries };
