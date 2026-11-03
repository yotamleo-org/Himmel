import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, readlinkSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

// The credentials a station secrets move takes out of .env (the Jira CLI's RESOLVED_KEYS), read from
// the keyring as the last layer before .env. Only the token is written there: the email is a
// config-class key that the migration moves to himmel.conf, never to the keyring.
// JIRA_BASE_URL stays a .env / himmel.conf setting: it is not a secret.
export const SECRET_KEYS = ['JIRA_EMAIL', 'JIRA_API_TOKEN'];
const KEYRING_WRITE_KEYS = ['JIRA_API_TOKEN'];

export function loadEnvFile(path) {
  if (!existsSync(path)) return {};
  const out = {};
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    const t = line.trim();
    if (!t || t.startsWith('#') || !t.includes('=')) continue;
    const [k, ...rest] = t.split('=');
    out[k.trim()] = rest.join('=').trim();
  }
  return out;
}

// Behaviour keys this reader takes from ~/.himmel/himmel.conf{,.local} (config
// class in scripts/lib/load-dotenv.sh): the conf files win over a legacy .env
// line, an empty value reads as unset, and the process env wins over both.
// The selected station profile supplies only the URL, below the local override.
// JIRA_EMAIL is config class: after a migration it lives here, not in .env.
// JIRA_PROJECT_KEY and JIRA_PROJECTS are config class too.
export const CONF_KEYS = ['JIRA_PROJECTS', 'JIRA_PROJECT_KEY', 'JIRA_BASE_URL', 'JIRA_EMAIL'];

// `only` narrows the keys read (jiraFetch asks for the email alone).
export function loadConfIntoProcess(only = CONF_KEYS) {
  const dir = process.env.HIMMEL_CONFIG_DIR || join(homedir(), '.himmel');
  const local = join(dir, 'himmel.conf.local');
  const name = (process.env.HIMMEL_PROFILE || loadEnvFile(local).HIMMEL_PROFILE || '')
    .replace(/^"(.*)"$/, '$1').replace(/^'(.*)'$/, '$1');
  const files = [[local, only]];
  if (name && !name.startsWith('.') && /^[A-Za-z0-9._-]+$/.test(name)) {
    try {
      const target = resolve(dir, readlinkSync(join(dir, 'himmel.conf')));
      files.push([join(dirname(target), 'profiles', `${name}.conf`), only.filter((k) => k === 'JIRA_BASE_URL')]);
    } catch (e) { if (e.code !== 'ENOENT' && e.code !== 'EINVAL') throw e; }
  }
  files.push([join(dir, 'himmel.conf'), only]);
  for (const [file, keys] of files) {
    const conf = loadEnvFile(file);
    for (const key of keys) {
      const value = (conf[key] ?? '').replace(/^"(.*)"$/, '$1').replace(/^'(.*)'$/, '$1');
      if (value && !process.env[key]) process.env[key] = value;
    }
  }
}

// The shared resolver (environment, credentials directory, keyring) lives in the himmel checkout's
// scripts/lib, which a plugin installed alone (a marketplace copy) does not have. Look in the plugin's
// own checkout, the primary checkout, then HIMMEL_REPO; with none, every keyring call below is a no-op
// and the plugin reads environment and .env exactly as before.
async function loadResolver() {
  const here = dirname(fileURLToPath(import.meta.url));
  const roots = [join(here, '..', '..', '..')];
  try {
    const common = execFileSync(
      'git',
      ['rev-parse', '--path-format=absolute', '--git-common-dir'],
      { encoding: 'utf8', cwd: here, stdio: ['ignore', 'pipe', 'ignore'] },
    ).trim();
    roots.push(dirname(common));
  } catch {
    // not inside a git checkout
  }
  if (process.env.HIMMEL_REPO) roots.push(process.env.HIMMEL_REPO);
  for (const root of roots) {
    const file = join(root, 'scripts', 'lib', 'resolve-secrets.mjs');
    if (!existsSync(file)) continue;
    try {
      return { root, mod: await import(pathToFileURL(file).href) };
    } catch {
      // an unreadable copy: try the next checkout
    }
  }
  return null;
}

const resolver = await loadResolver();

/** The names the keyring path serves (environment, credentials directory, keyring); {} without the resolver. */
export function resolveFromKeyring(names, env) {
  return resolver ? resolver.mod.resolveSecrets(resolver.root, names, env) : {};
}

/** Set any credential still missing from the process environment from the keyring path. */
export function fillFromKeyring() {
  const missing = SECRET_KEYS.filter((k) => !process.env[k]);
  for (const [k, v] of Object.entries(resolveFromKeyring(missing))) process.env[k] ||= v;
}

/**
 * Store the token in kvs in the keyring when it is unlocked; returns the names stored. A store counts
 * only when the keyring itself then serves that value back: the read-back blanks the exported name and
 * CREDENTIALS_DIRECTORY, so neither can make a put that exits 0 but keeps nothing look stored. Anything
 * not stored is left for the .env write instead of being lost.
 */
export function storeInKeyring(kvs) {
  const stored = [];
  if (!resolver || !resolver.mod.keyringUnlocked(resolver.root)) return stored;
  for (const [k, v] of Object.entries(kvs)) {
    if (!KEYRING_WRITE_KEYS.includes(k)) continue;
    const keyringOnly = { [k]: '', CREDENTIALS_DIRECTORY: '' };
    if (resolver.mod.putSecret(resolver.root, k, v) && resolveFromKeyring([k], keyringOnly)[k] === v) stored.push(k);
  }
  return stored;
}

// Match the Jira CLI: own install, primary checkout, then HIMMEL_REPO.
export function envFilePath(override) {
  if (override) return override;
  const here = dirname(fileURLToPath(import.meta.url));
  const own = join(here, '..', '..', '..', '.env');
  if (existsSync(own)) return own;
  const candidates = [];
  try {
    const common = execFileSync(
      'git',
      ['rev-parse', '--path-format=absolute', '--git-common-dir'],
      { encoding: 'utf8', cwd: here, stdio: ['ignore', 'pipe', 'ignore'] },
    ).trim();
    candidates.push(join(dirname(common), '.env'));
  } catch {
    // An install outside git can still use HIMMEL_REPO or the home fallback.
  }
  if (process.env.HIMMEL_REPO) candidates.push(join(process.env.HIMMEL_REPO, '.env'));
  return candidates.find((c) => existsSync(c)) ??
    join(process.env.HOME || process.env.USERPROFILE || '.', '.config', 'himmel-cli', 'jira.env');
}

export async function jiraFetch(method, path, body) {
  const base = process.env.JIRA_BASE_URL;
  if (!base) throw new Error('JIRA_BASE_URL not set — run /jira-init');
  // A migrated station keeps the email in himmel.conf; the token comes from the keyring.
  if (!process.env.JIRA_EMAIL) loadConfIntoProcess(['JIRA_EMAIL']);
  fillFromKeyring();
  const email = process.env.JIRA_EMAIL || '';
  const token = process.env.JIRA_API_TOKEN || '';
  const auth = `Basic ${Buffer.from(`${email}:${token}`).toString('base64')}`;
  const res = await fetch(`${base}/rest/api/3${path}`, {
    method,
    headers: { Authorization: auth, 'Content-Type': 'application/json', Accept: 'application/json' },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  if (!res.ok) {
    const body = await res.text();
    const snippet = body.length > 300 ? body.slice(0, 300) + '…' : body;
    throw new Error(`HTTP ${res.status}: ${snippet}`);
  }
  const t = await res.text();
  return t.trim() ? JSON.parse(t) : {};
}
