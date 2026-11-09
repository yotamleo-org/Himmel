import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, readlinkSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// A test never loads the station's himmel.conf, project .env or keyring on its own: under vitest or
// bun (NODE_ENV=test) the automatic load is skipped, whatever the cwd or config, and a test that
// wants a file calls loadEnvFile(path) itself. A real CLI or MCP run still loads at import.
export const underTest = (env: NodeJS.ProcessEnv = process.env): boolean => !!env.VITEST || env.NODE_ENV === 'test';

// The .env is found from this file's own install path, never the cwd: a run
// from another repo must still reach the credentials. A worktree install has
// no .env of its own, so the primary checkout (git's common dir, asked from the
// script's directory) and then HIMMEL_REPO are tried in turn.
export function envFilePath(): string {
  const here = dirname(fileURLToPath(import.meta.url));
  const own = join(here, '..', '..', '..', '.env');
  if (existsSync(own)) return own;
  const candidates: string[] = [];
  try {
    const common = execFileSync(
      'git',
      ['rev-parse', '--path-format=absolute', '--git-common-dir'],
      { encoding: 'utf8', cwd: here, stdio: ['ignore', 'pipe', 'ignore'] },
    ).trim();
    candidates.push(join(dirname(common), '.env'));
  } catch {
    // not inside a git checkout: HIMMEL_REPO is the only other anchor
  }
  if (process.env.HIMMEL_REPO) candidates.push(join(process.env.HIMMEL_REPO, '.env'));
  return candidates.find((c) => existsSync(c)) ?? own;
}

export function stripInlineComment(value: string): string {
  let quote = '';
  let started = false;
  let escaped = false;
  for (let i = 0; i < value.length; i++) {
    const char = value[i];
    if (!started) {
      if (char === ' ' || char === '\t') continue;
      started = true;
      if (char === '"' || char === "'") { quote = char; continue; }
    }
    if (quote) {
      if (quote === '"' && escaped) { escaped = false; continue; }
      if (quote === '"' && char === '\\') { escaped = true; continue; }
      if (char === quote) quote = '';
      continue;
    }
    if (char === '#' && i > 0 && /[ \t]/.test(value[i - 1])) return value.slice(0, i);
  }
  return value;
}

export function readEnvFile(envPath: string, keys: ReadonlySet<string>, env: NodeJS.ProcessEnv = process.env): void {
  if (!existsSync(envPath)) return;
  for (const line of readFileSync(envPath, 'utf8').split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#') || !trimmed.includes('=')) continue;
    const [key, ...rest] = trimmed.split('=');
    if (!keys.has(key.trim())) continue;
    // An exported-but-empty value is not usable (baseUrl() rejects it), so it
    // must not shadow the file: `||=`, not `??=`.
    env[key.trim()] ||= stripInlineComment(rest.join('=')).trim();
  }
}

// Match the shell loader's station profile selection; project config cannot
// choose the Jira destination. A plain (unlinked) himmel.conf has no profiles.
// With profileFromEnv the process HIMMEL_PROFILE wins over himmel.conf.local's line.
function profileFilePath(confDir: string, profileFromEnv: boolean): string | undefined {
  const env = { HIMMEL_PROFILE: profileFromEnv ? process.env.HIMMEL_PROFILE : undefined };
  readEnvFile(join(confDir, 'himmel.conf.local'), new Set(['HIMMEL_PROFILE']), env);
  const name = env.HIMMEL_PROFILE;
  if (!name || name.startsWith('.') || !/^[A-Za-z0-9._-]+$/.test(name)) return;
  try {
    const target = resolve(confDir, readlinkSync(join(confDir, 'himmel.conf')));
    return join(dirname(target), 'profiles', `${name}.conf`);
  } catch {
    return; // Not a link: there is no station profile directory.
  }
}

/**
 * The station's Jira URL from its files: himmel.conf.local, the station profile, himmel.conf, then the
 * install .env (`envPath`, default envFilePath()). Never the process JIRA_BASE_URL. profileFromEnv false
 * reads the profile name from himmel.conf.local only, so one env var cannot switch instances.
 */
export function stationJiraBaseUrl(configDir: string, opts: { profileFromEnv: boolean; envPath?: string }): string | null {
  const keys = new Set(['JIRA_BASE_URL']);
  const env: NodeJS.ProcessEnv = {};
  readEnvFile(join(configDir, 'himmel.conf.local'), keys, env);
  const profile = profileFilePath(configDir, opts.profileFromEnv);
  if (profile) readEnvFile(profile, keys, env);
  readEnvFile(join(configDir, 'himmel.conf'), keys, env);
  readEnvFile(opts.envPath ?? envFilePath(), keys, env);
  return env.JIRA_BASE_URL || null;
}

/** One Jira instance: lower-cased scheme and host, default port dropped, trailing `/` stripped. */
export function sameJiraBase(a: string, b: string): boolean {
  const norm = (u: string): string | null => {
    try {
      const url = new URL(u);
      return `${url.protocol}//${url.host}${url.pathname.replace(/\/+$/, '')}`;
    } catch {
      return null;
    }
  };
  const na = norm(a);
  return na !== null && na === norm(b);
}
