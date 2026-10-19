'use strict';
// scripts/himmelctl/lib/secret-store.js — wizard secret store: detect,
// validate and write ONE secret into its documented store, in-process.
//
// Why not set-env-var.sh: bin.js writeEnvVar hands `KEY VALUE` to a child, so the
// value sits in `ps`. This module never spawns anything: Node fs only, and the
// one git question (is the target ignored?) is asked through ctx.gitCheckIgnore,
// which the caller supplies (it is a path, never a secret).
//
// One store interface: a backend is { detect(name, ctx), write(name, value, ctx) }.
// The `file` backend below serves today's documented 0600 stores; a future
// vault registers a second one via registerBackend(), with no wizard change.
//
// ctx: { home, himmelRoot, projectRoot, env, uid?, gitCheckIgnore?, backend? }.
// Results and errors name a rule or a path, never an input value.
//
// ponytail: card entries and the MCP stores are detect-only, no vault backend yet, HIMMEL-4862.

const fs = require('fs');
const os = require('os');
const path = require('path');
const manifest = require('./secrets-manifest.json');

const PLACEHOLDER = /^(?:<.*>|your[_-].*|changeme|change[_-]me|xxx+|todo|replace[_-]?me)$/i;
const KEY_RE = /^[A-Za-z_][A-Za-z0-9_]*$/;
const MCP_REL = ['.config', 'himmel', 'mcp-secrets'];

class SecretStoreError extends Error {}
const refuse = (msg) => { throw new SecretStoreError(msg); };

const entryOf = (name) => manifest.secrets.find((s) => s.name === name);

// ── validation: a rule id per manifest `validate`, never echoing the input ──

const RULES = {
  'https-host': (v) => { try { const u = new URL(v); return u.protocol === 'https:' && u.hostname.length > 0; } catch { return false; } },
  email: (v) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v),
  'token-nonempty': (v) => v.length > 0 && !/\s/.test(v),
  'project-key': (v) => /^[A-Z][A-Z0-9]+$/.test(v),
  'telegram-token': (v) => /^\d+:[A-Za-z0-9_-]{35}$/.test(v),
};

// A value the .env line format cannot carry faithfully, whatever its rule.
function unwritable(v) {
  return /[\r\n\0#]/.test(v) || /^["']/.test(v) || v !== v.trim();
}

// bash `source` of the store (bitbucket live-smoke sources the himmel .env, and
// an operator may) would expand or execute these in an unquoted value. Quoting
// would break the dotenv readers that keep quotes, so refuse instead.
const SHELL_META = /[$`;\\&|<>()'"\s]/;

function validate(name, value) {
  const e = entryOf(name);
  if (!e) return { ok: false, rule: 'known-secret' };
  if (typeof value !== 'string') return { ok: false, rule: 'string' };
  if (unwritable(value)) return { ok: false, rule: 'single-line' };
  if (SHELL_META.test(value)) return { ok: false, rule: 'shell-safe' };
  const rule = RULES[e.validate];
  if (!rule) return { ok: false, rule: e.validate };
  return rule(value) ? { ok: true } : { ok: false, rule: e.validate };
}

// ── stores ──

function telegramEnv(ctx) {
  const o = (ctx.env || {}).TELEGRAM_ENV;
  if (o) return /^~[\\/]/.test(o) ? path.join(ctx.home, o.slice(2)) : o;
  return path.join(ctx.home, '.claude', 'channels', 'telegram', '.env');
}
function storeFile(storeId, ctx) {
  switch (storeId) {
    case 'himmel-env': return path.join(ctx.himmelRoot, '.env');
    case 'project-env': return path.join(ctx.projectRoot, '.env');
    case 'bridge-env': return telegramEnv(ctx);
    default: return null;
  }
}
const mcpDir = (ctx) => path.join(ctx.home, ...MCP_REL);
// Every file store the wizard can write; redact.storeLiterals() scrubs these.
const storePaths = (ctx) => ['himmel-env', 'project-env', 'bridge-env'].map((s) => storeFile(s, ctx));

function readEnvKey(file, key) {
  let raw;
  try { raw = fs.readFileSync(file, 'utf8'); } catch (e) { if (e.code === 'ENOENT') return ''; throw e; }
  for (const line of raw.split(/\r?\n/)) {
    const m = /^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/.exec(line);
    if (m && m[1] === key) return m[2].replace(/^(["'])(.*)\1$/, '$2');
  }
  return '';
}
const usable = (v) => typeof v === 'string' && v !== '' && !PLACEHOLDER.test(v);

function mcpHas(name, ctx) {
  let servers;
  try { servers = fs.readdirSync(mcpDir(ctx)); } catch { return false; }
  return servers.some((s) => { try { return fs.statSync(path.join(mcpDir(ctx), s, name)).size > 0; } catch { return false; } });
}

// Presence only; the value is never part of a result.
function fileDetect(name, ctx) {
  // A model file is not an env value: its presence is the cmd:whisper_ready probe's to judge.
  if ((entryOf(name) || {}).store === 'model-file') return { status: 'probe', source: 'cmd:whisper_ready' };
  const live = (ctx.env || {})[name];
  if (usable(live)) return { status: 'set', source: 'live-env' };
  const e = entryOf(name);
  const file = e && storeFile(e.store, ctx);
  if (file) {
    const v = readEnvKey(file, name);
    if (usable(v)) return { status: 'set', source: 'store' };
    if (v !== '') return { status: 'placeholder', source: 'store' };
  }
  if (mcpHas(name, ctx)) return { status: 'set', source: 'mcp-store' };
  return { status: 'not-set', source: null };
}

function ownedByMe(st, ctx) {
  const uid = ctx.uid !== undefined ? ctx.uid : (process.getuid ? process.getuid() : st.uid);
  return st.uid === uid;
}
// Group-write on the store directory is harmless when the directory's group is
// the user's own and nobody else belongs to it (umask 002 + user-private groups
// on stock Ubuntu/Fedora). Unreadable account files mean not private.
function privateGroup(st, ctx) {
  const gid = ctx.gid !== undefined ? ctx.gid : (process.getgid ? process.getgid() : st.gid);
  if (st.gid !== gid) return false;
  const files = ctx.accountFiles || { group: '/etc/group', passwd: '/etc/passwd' };
  const me = os.userInfo().username;
  try {
    let named = false;
    for (const l of fs.readFileSync(files.group, 'utf8').split('\n')) {
      const f = l.split(':');
      if (Number(f[2]) !== gid) continue;
      if (f[0] === me) named = true;
      if (f[3] && f[3].split(',').some((u) => u && u !== me)) return false;
    }
    // A group the local files do not define (NSS/LDAP) cannot be proven private.
    if (!named) return false;
    for (const l of fs.readFileSync(files.passwd, 'utf8').split('\n')) {
      const f = l.split(':');
      if (Number(f[3]) === gid && f[0] !== me) return false;
    }
  } catch { return false; }
  return true;
}
function inWorkTree(dir) {
  for (let d = dir; ; d = path.dirname(d)) {
    if (fs.existsSync(path.join(d, '.git'))) return true;
    if (path.dirname(d) === d) return false;
  }
}

function fileWrite(name, value, ctx) {
  const e = entryOf(name);
  const file = e && storeFile(e.store, ctx);
  if (!file) refuse('secret has no writable file store (card entry)');
  const dir = path.dirname(file);
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const dst = fs.statSync(dir);
  if (!ownedByMe(dst, ctx)) refuse('store directory is owned by another user');
  if ((dst.mode & 0o002) || ((dst.mode & 0o020) && !privateGroup(dst, ctx))) refuse('store directory is group or world writable');
  if (inWorkTree(dir)) {
    if (typeof ctx.gitCheckIgnore !== 'function') refuse('store sits in a git work tree and no gitignore check was supplied');
    if (ctx.gitCheckIgnore(file) !== true) refuse('store file is not ignored by git (add it to .gitignore first)');
  }
  let existing = '', tightened = false;
  let rfd = null;
  try { rfd = fs.openSync(file, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0)); } catch (err) {
    if (err.code === 'ELOOP') refuse('store file is a symlink');
    if (err.code !== 'ENOENT') throw err;
  }
  if (rfd !== null) {
    try {
      const st = fs.fstatSync(rfd);
      if (!st.isFile()) refuse('store file is not a regular file');
      if (!ownedByMe(st, ctx)) refuse('store file is owned by another user');
      tightened = (st.mode & 0o077) !== 0;
      existing = fs.readFileSync(rfd, 'utf8');
    } finally { fs.closeSync(rfd); }
    if (existing.includes('�')) refuse('store file is not valid UTF-8, refusing to rewrite it');
  }
  const eol = existing.includes('\r\n') ? '\r\n' : '\n';
  const lines = existing === '' ? [] : existing.split('\n');
  const keyLine = new RegExp('^\\s*(?:export\\s+)?' + name + '\\s*=');
  let placed = false;
  const out = [];
  for (const l of lines) {
    if (keyLine.test(l)) { if (!placed) { out.push(name + '=' + value + (l.endsWith('\r') ? '\r' : '')); placed = true; } continue; }
    out.push(l);
  }
  if (!placed) {
    if (out.length && out[out.length - 1] === '') out.pop();
    out.push(name + '=' + value + (eol === '\r\n' ? '\r' : ''), '');
  }
  const tmp = path.join(dir, '.' + path.basename(file) + '.' + process.pid + '.' + Math.random().toString(36).slice(2) + '.tmp');
  const flags = fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | (fs.constants.O_NOFOLLOW || 0);
  const fd = fs.openSync(tmp, flags, 0o600);
  try {
    fs.fchmodSync(fd, 0o600);
    fs.writeFileSync(fd, out.join('\n'));
    fs.fsyncSync(fd);
  } catch (err) {
    fs.closeSync(fd);
    try { fs.unlinkSync(tmp); } catch { /* best effort */ }
    throw err;
  }
  fs.closeSync(fd);
  try { fs.renameSync(tmp, file); } catch (err) { try { fs.unlinkSync(tmp); } catch { /* best effort */ } throw err; }
  return { ok: true, path: file, tightened };
}

const backends = { file: { detect: fileDetect, write: fileWrite } };
function registerBackend(id, b) {
  if (!b || typeof b.detect !== 'function' || typeof b.write !== 'function') throw new SecretStoreError('backend needs detect and write');
  backends[id] = b;
}
const backendOf = (ctx) => backends[ctx.backend || 'file'] || refuse('unknown backend');

function detect(name, ctx) { return backendOf(ctx).detect(name, ctx); }

function write(name, value, ctx) {
  if (!KEY_RE.test(name)) refuse('secret name is not a valid env key');
  const e = entryOf(name);
  if (!e) refuse('unknown secret');
  if (e.collect !== 'file') refuse('card entry: the wizard shows its status but never collects it');
  const v = validate(name, value);
  if (!v.ok) refuse('value failed rule "' + v.rule + '"');
  return backendOf(ctx).write(name, value, ctx);
}

// Where a live probe may send the credential: the provider's own host only.
// `values` carries the other secrets a probe needs (JIRA_BASE_URL).
function probePlan(name, values) {
  if (name === 'TELEGRAM_BOT_TOKEN') return { via: 'telegram-getme', host: 'api.telegram.org', needsConsent: false };
  if (/^JIRA_/.test(name)) {
    let host = '';
    try { host = new URL((values || {}).JIRA_BASE_URL).hostname; } catch { /* no usable host */ }
    return { via: 'jira-cli', host, needsConsent: !/(^|\.)atlassian\.net$/.test(host) };
  }
  return { via: null, host: '', needsConsent: false };
}

module.exports = { detect, write, validate, probePlan, registerBackend, storePaths, mcpDir, SecretStoreError, PLACEHOLDER };
