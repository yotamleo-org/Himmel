'use strict';
// scripts/himmelctl/lib/bot-roles.js: the one place that says which Telegram bot plays which
// role on a station, and whether a candidate bot may take a role.
//
// Four roles, four different bots:
//   main    the bridge bot your chief talks to you through (token in the bridge .env)
//   bridge  the peer-bridge bot (token in the peer-bridge config dir, which sessions must not open)
//   notice  the afk-sudo notice bot (token root-only)
//   relay   the Jira-nudge relay bot (token in the repo-root .env)
// The distinct-tokens probe and scripts/remote-setup/ both ask this module, so the rule exists once.
//
// Only non-secret bot ids ever leave this module. An id is the digits before the colon of a token.
// readRoleIds reads the two .env files this station already keeps and ~/.himmel/remote-setup/bots.json,
// the file the helper publishes the bridge and notice ids to. It never opens the peer-bridge dirs.

const fs = require('fs');
const os = require('os');
const path = require('path');

const ROLES = ['main', 'bridge', 'notice', 'relay'];
const ID_RE = /^[0-9]{1,15}$/;

// The digits before the colon, or '' when the value does not look like a bot token.
function idFromToken(token) {
  const m = /^([0-9]{1,15}):/.exec(typeof token === 'string' ? token : '');
  return m ? m[1] : '';
}

// roleConflict(candidateId, role, ids) -> null | {conflictsWith, reason}
// A candidate may not be the bot of any OTHER role. An id listed in ids.pending is taken too: it
// was published by a setup that stopped before its token was stored, and the next run of that
// part resolves it. The one exception is the candidate's own role holding that same id, which is
// that part resuming.
function roleConflict(candidateId, role, ids) {
  const id = String(candidateId === undefined || candidateId === null ? '' : candidateId);
  const known = ids || {};
  if (!ID_RE.test(id)) return null;
  for (const r of ROLES) {
    if (r === role) continue;
    if (known[r] !== undefined && known[r] !== null && String(known[r]) === id) {
      return { conflictsWith: r, reason: `this bot is already your ${r} bot` };
    }
  }
  const pending = Array.isArray(known.pending) ? known.pending.map(String) : [];
  const own = known[role] === undefined || known[role] === null ? '' : String(known[role]);
  if (pending.includes(id) && own !== id) {
    return { conflictsWith: 'pending', reason: 'this bot is reserved by a setup step that was interrupted' };
  }
  return null;
}

function readEnvKey(file, key) {
  let raw;
  try { raw = fs.readFileSync(file, 'utf8'); } catch (_e) { return ''; }
  for (const line of raw.split(/\r?\n/)) {
    const m = /^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/.exec(line);
    if (m && m[1] === key) return m[2].replace(/^(["'])(.*)\1$/, '$2');
  }
  return '';
}

function homeOf(opts) {
  return opts.home || (opts.env && opts.env.HOME) || os.homedir();
}

// The bridge .env, the same file secret-store writes: TELEGRAM_ENV (a leading ~ means home), else
// ~/.claude/channels/telegram/.env.
function mainEnvFile(opts) {
  const home = homeOf(opts);
  const o = opts.env && opts.env.TELEGRAM_ENV;
  if (o) return /^~[\\/]/.test(o) ? path.join(home, o.slice(2)) : o;
  return path.join(home, '.claude', 'channels', 'telegram', '.env');
}

function botsFile(opts) {
  return path.join(homeOf(opts), '.himmel', 'remote-setup', 'bots.json');
}

// readPublished({home}) -> {bridge, bridgePublishedAt, notice, pending: string[]}
// The ids the helper published to bots.json. A missing or unreadable file publishes nothing.
function readPublished(opts) {
  const out = { bridge: undefined, bridgePublishedAt: undefined, notice: undefined, pending: [] };
  let doc;
  try { doc = JSON.parse(fs.readFileSync(botsFile(opts || {}), 'utf8')); } catch (_e) { return out; }
  if (!doc || typeof doc !== 'object') return out;
  for (const role of ['bridge', 'notice']) {
    const e = doc[role];
    if (!e || typeof e !== 'object' || !ID_RE.test(String(e.id))) continue;
    out[role] = String(e.id);
    if (e.pending === true) out.pending.push(String(e.id));
    if (role === 'bridge' && typeof e.publishedAt === 'string') out.bridgePublishedAt = e.publishedAt;
  }
  return out;
}

// readRoleIds({home, repoRoot, env}) -> {main, relay, bridge, bridgePublishedAt, notice, pending}
function readRoleIds(opts) {
  const o = opts || {};
  const published = readPublished(o);
  const main = idFromToken(readEnvKey(mainEnvFile(o), 'TELEGRAM_BOT_TOKEN'));
  const relay = o.repoRoot ? idFromToken(readEnvKey(path.join(o.repoRoot, '.env'), 'TELEGRAM_BOT_TOKEN')) : '';
  return {
    main: main || undefined,
    relay: relay || undefined,
    bridge: published.bridge,
    bridgePublishedAt: published.bridgePublishedAt,
    notice: published.notice,
    pending: published.pending,
  };
}

module.exports = { ROLES, idFromToken, roleConflict, readRoleIds, readPublished, mainEnvFile, botsFile };
