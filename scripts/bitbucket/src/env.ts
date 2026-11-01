import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { resolveSecrets } from '../../lib/resolve-secrets.mjs';

// Match the Jira CLI: own install, primary checkout, then HIMMEL_REPO.
function envFilePath(): string {
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
    // An install outside git can still use HIMMEL_REPO.
  }
  if (process.env.HIMMEL_REPO) candidates.push(join(process.env.HIMMEL_REPO, '.env'));
  return candidates.find((c) => existsSync(c)) ?? own;
}

const DOTENV_KEYS = new Set([
  'BITBUCKET_EMAIL', 'BITBUCKET_API_TOKEN', 'BITBUCKET_WORKSPACE', 'BITBUCKET_REPO_SLUG',
]);

// Order: environment, credentials directory, keyring (the one resolver), then this file's own .env read.
function loadEnv(): void {
  const envPath = envFilePath();
  const missing = [...DOTENV_KEYS].filter((k) => !process.env[k]);
  for (const [key, value] of Object.entries(resolveSecrets(dirname(envPath), missing))) process.env[key] ||= value;
  if (!existsSync(envPath)) return;
  for (const line of readFileSync(envPath, 'utf8').split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#') || !trimmed.includes('=')) continue;
    const [key, ...rest] = trimmed.split('=');
    if (!DOTENV_KEYS.has(key.trim())) continue;
    process.env[key.trim()] ??= rest.join('=').trim();
  }
}

// CRLF-safe Basic auth (same defensive parsing as the Jira CLI):
// a CRLF-sourced env file leaves a trailing \r in the value, which corrupts
// the base64 Basic header and returns 401 with no hint. Strip + warn once.
export function normalizeEnv(): void {
  for (const key of ['BITBUCKET_EMAIL', 'BITBUCKET_API_TOKEN', 'BITBUCKET_WORKSPACE', 'BITBUCKET_REPO_SLUG']) {
    const raw = process.env[key];
    if (raw === undefined) continue;
    const cleaned = raw.replace(/[\s]+$/, '');
    if (cleaned !== raw) {
      process.stderr.write(
        `bitbucket: warning: stripped trailing whitespace from ${key} ` +
          '(probably from CRLF env file - run dos2unix on the source to silence)\n',
      );
      process.env[key] = cleaned;
    }
  }
}

loadEnv();
normalizeEnv();

export const BASE_URL = 'https://api.bitbucket.org/2.0';

export function authHeader(): string {
  const email = process.env.BITBUCKET_EMAIL ?? '';
  const token = process.env.BITBUCKET_API_TOKEN ?? '';
  if (!email || !token) {
    throw new Error(
      'BITBUCKET_EMAIL and BITBUCKET_API_TOKEN must be set (repo-root .env or environment). ' +
        'Create an Atlassian API token "with scopes" and select the Bitbucket app. ' +
        'See docs/setup/new-machine.md.',
    );
  }
  return `Basic ${Buffer.from(`${email}:${token}`).toString('base64')}`;
}
