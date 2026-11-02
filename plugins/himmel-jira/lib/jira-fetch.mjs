import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

// The credentials a station secrets move takes out of .env (the Jira CLI's RESOLVED_KEYS).
// JIRA_BASE_URL stays a .env / himmel.conf setting: it is not a secret.
export const SECRET_KEYS = ['JIRA_EMAIL', 'JIRA_API_TOKEN'];

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
export function resolveFromKeyring(names) {
  return resolver ? resolver.mod.resolveSecrets(resolver.root, names) : {};
}

/** Set any credential still missing from the process environment from the keyring path. */
export function fillFromKeyring() {
  const missing = SECRET_KEYS.filter((k) => !process.env[k]);
  for (const [k, v] of Object.entries(resolveFromKeyring(missing))) process.env[k] ||= v;
}

/** Store each credential in kvs in the keyring when it is unlocked; returns the names stored. */
export function storeInKeyring(kvs) {
  const stored = [];
  if (!resolver || !resolver.mod.keyringUnlocked(resolver.root)) return stored;
  for (const [k, v] of Object.entries(kvs)) {
    if (SECRET_KEYS.includes(k) && resolver.mod.putSecret(resolver.root, k, v)) stored.push(k);
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
