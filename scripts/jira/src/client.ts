import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, readlinkSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { basename, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// The .env is found from this file's own install path, never the cwd: a run
// from another repo must still reach the credentials. A worktree install has
// no .env of its own, so the primary checkout (git's common dir, asked from the
// script's directory) and then HIMMEL_REPO are tried in turn.
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
    // not inside a git checkout: HIMMEL_REPO is the only other anchor
  }
  if (process.env.HIMMEL_REPO) candidates.push(join(process.env.HIMMEL_REPO, '.env'));
  return candidates.find((c) => existsSync(c)) ?? own;
}

const DOTENV_KEYS = new Set([
  'JIRA_BASE_URL', 'JIRA_EMAIL', 'JIRA_API_TOKEN', 'JIRA_PROJECT_KEY',
  'JIRA_SEVERITY_FIELD', 'JIRA_BOARD_ID', 'CONFLUENCE_EMAIL', 'CONFLUENCE_API_TOKEN',
]);

const CONFIG_KEYS = new Set(['JIRA_BASE_URL', 'JIRA_EMAIL', 'JIRA_PROJECT_KEY']);

// The credentials a station secrets move takes out of .env: when
// neither the environment nor .env supplies one, the one resolver is asked.
const RESOLVED_KEYS = ['JIRA_EMAIL', 'JIRA_API_TOKEN'];

function resolveFromKeyring(root: string): void {
  const missing = RESOLVED_KEYS.filter((k) => !process.env[k]);
  if (missing.length === 0) return;
  const resolver = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'lib', 'himmel-secrets');
  if (!existsSync(resolver)) return;
  let out = '';
  try {
    out = execFileSync('bash', [resolver, 'get', '--root', root, '--no-dotenv', ...missing], {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 10000,
    });
  } catch (e) {
    // exit 1 = nothing served; stdout of a partial hit is still usable
    out = (e as { stdout?: string }).stdout ?? '';
  }
  for (const line of String(out ?? '').split('\n')) {
    const i = line.indexOf('=');
    if (i < 1) continue;
    const k = line.slice(0, i);
    if (missing.includes(k)) process.env[k] ||= line.slice(i + 1);
  }
}

// Match the shell loader's station profile selection; project config cannot
// choose the Jira destination. A plain (unlinked) himmel.conf has no profiles.
function profileFilePath(confDir: string): string | undefined {
  const env = { HIMMEL_PROFILE: process.env.HIMMEL_PROFILE };
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

export function loadEnvFile(envPath: string): void {
  const confDir = join(process.env.HOME || homedir(), '.himmel');
  readEnvFile(join(confDir, 'himmel.conf.local'), CONFIG_KEYS);
  const profile = profileFilePath(confDir);
  if (profile) readEnvFile(profile, new Set(['JIRA_BASE_URL']));
  readEnvFile(join(confDir, 'himmel.conf'), CONFIG_KEYS);
  let projectRoot: string | undefined;
  try {
    projectRoot = execFileSync('git', ['rev-parse', '--show-toplevel'], {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
  } catch {
    // The cwd need not be a git checkout; install credentials still apply.
  }
  if (projectRoot) readEnvFile(join(projectRoot, '.env'), new Set(['JIRA_PROJECT_KEY']));
  readEnvFile(envPath, DOTENV_KEYS);
  resolveFromKeyring(dirname(envPath));
}

function stripInlineComment(value: string): string {
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

function readEnvFile(envPath: string, keys: ReadonlySet<string>, env: NodeJS.ProcessEnv = process.env): void {
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

// Normalize JIRA_* env vars regardless of how they got into
// process.env. The loadEnv() path above already trims (CRLF-safe), but
// `bash source ~/.config/himmel-cli/jira.env` with a CRLF file (common
// after Windows->Linux scp) preserves the trailing \r in the value, and
// node inherits it via process.env. The malformed Basic auth header then
// returns HTTP 401 with no hint that line endings are the cause. Strip
// trailing whitespace (CR/LF/tab/space) and warn ONCE per affected var so
// the operator can dos2unix their source if this keeps firing.
export function normalizeEnv(): void {
  for (const key of [
    'JIRA_BASE_URL',
    'JIRA_EMAIL',
    'JIRA_API_TOKEN',
    'JIRA_PROJECT_KEY',
    'JIRA_SEVERITY_FIELD',
    'JIRA_BOARD_ID',
    'CONFLUENCE_EMAIL',
    'CONFLUENCE_API_TOKEN',
  ]) {
    const raw = process.env[key];
    if (raw === undefined) continue;
    const cleaned = raw.replace(/[\s]+$/, '');
    if (cleaned !== raw) {
      process.stderr.write(
        `jira: warning: stripped trailing whitespace from ${key} ` +
          '(probably from CRLF env file - run dos2unix on the source to silence)\n',
      );
      process.env[key] = cleaned;
    }
  }
}

loadEnvFile(envFilePath());
normalizeEnv();

export const baseUrl = (): string => {
  // No hardcoded default. A stranger who sets a token but
  // not the base URL must fail loud here — never silently send requests
  // to the author's instance.
  const url = process.env.JIRA_BASE_URL;
  if (!url) {
    throw new Error(
      'JIRA_BASE_URL is not set. Add it to ~/.himmel/himmel.conf (or shell environment; .env is a one-release fallback) ' +
        'and re-run. See .env.example + docs/setup/new-machine.md.',
    );
  }
  return url;
};

export const projectKey = (): string => {
  // No hardcoded default. Operators must set
  // JIRA_PROJECT_KEY explicitly so this plugin is portable across
  // repos/projects without code edits.
  const key = process.env.JIRA_PROJECT_KEY;
  if (!key) {
    throw new Error(
      'JIRA_PROJECT_KEY is not set. Add it to your .env (or shell environment) ' +
        'and re-run. See .env.example + docs/setup/new-machine.md.',
    );
  }
  return key;
};

export const severityField = (): string | undefined =>
  process.env.JIRA_SEVERITY_FIELD || undefined;

export const boardId = (): string | undefined =>
  process.env.JIRA_BOARD_ID || undefined;

export function authHeader(): string {
  const email = process.env.JIRA_EMAIL ?? '';
  const token = process.env.JIRA_API_TOKEN ?? '';
  return `Basic ${Buffer.from(`${email}:${token}`).toString('base64')}`;
}

// Confluence often needs its OWN Atlassian token: a *scoped* Jira API token
// 401s against /wiki (Confluence), same as the bitbucket CLI needs a separate
// scoped token. Use CONFLUENCE_EMAIL/CONFLUENCE_API_TOKEN when BOTH are set;
// otherwise fall back to the Jira creds (works when JIRA_API_TOKEN is a
// scopeless/full-account token covering both products).
export function confluenceAuthHeader(): string {
  const email = process.env.CONFLUENCE_EMAIL;
  const token = process.env.CONFLUENCE_API_TOKEN;
  if (email && token) {
    return `Basic ${Buffer.from(`${email}:${token}`).toString('base64')}`;
  }
  return authHeader();
}

export async function requestAt<T>(
  apiBase: string,
  method: string,
  path: string,
  body?: unknown,
  auth: string = authHeader(),
): Promise<T> {
  const url = `${baseUrl()}${apiBase}${path}`;
  const res = await fetch(url, {
    method,
    headers: {
      Authorization: auth,
      'Content-Type': 'application/json',
      Accept: 'application/json',
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`HTTP ${res.status}: ${text}`);
  }
  const text = await res.text();
  return (text.trim() ? JSON.parse(text) : {}) as T;
}

export const request = <T>(method: string, path: string, body?: unknown) =>
  requestAt<T>('/rest/api/3', method, path, body);
export const agileRequest = <T>(method: string, path: string, body?: unknown) =>
  requestAt<T>('/rest/agile/1.0', method, path, body);
export const confluenceV2 = <T>(method: string, path: string, body?: unknown) =>
  requestAt<T>('/wiki/api/v2', method, path, body, confluenceAuthHeader());
export const confluenceV1 = <T>(method: string, path: string, body?: unknown) =>
  requestAt<T>('/wiki/rest/api', method, path, body, confluenceAuthHeader());

export async function uploadMultipart(
  url: string,
  filePath: string,
  field = 'file',
  auth: string = authHeader(),
): Promise<unknown> {
  if (!existsSync(filePath)) {
    throw new Error(`attachment not found: ${filePath}`);
  }
  const data = readFileSync(filePath);
  const fd = new FormData();
  fd.append(field, new Blob([data]), basename(filePath));

  const res = await fetch(url, {
    method: 'POST',
    headers: {
      Authorization: auth,
      'X-Atlassian-Token': 'no-check',
      // intentionally NO Content-Type — fetch must set multipart boundary
    },
    body: fd,
  });
  if (!res.ok) {
    const text = (await res.text()).slice(0, 500);
    throw new Error(`HTTP ${res.status}: ${text}`);
  }
  const text = await res.text();
  return text.trim() ? JSON.parse(text) : {};
}

// Back-compat wrapper: Jira issue attachment upload composes its own URL.
export function uploadAttachment(issueKey: string, filePath: string): Promise<unknown> {
  return uploadMultipart(
    `${baseUrl()}/rest/api/3/issue/${issueKey}/attachments`,
    filePath,
  );
}

export async function downloadTo(fullUrl: string, outPath: string, auth: string = authHeader()): Promise<number> {
  const res = await fetch(fullUrl, { headers: { Authorization: auth } });
  if (!res.ok) {
    const text = (await res.text()).slice(0, 500);
    throw new Error(`HTTP ${res.status}: ${text}`);
  }
  const buf = Buffer.from(await res.arrayBuffer());
  writeFileSync(outPath, buf);
  return buf.length;
}

// Jira accountIds are 24-hex or "<provider>:<uuid>"; an '@' means it's an email.
export async function resolveAccountId(emailOrId: string): Promise<string> {
  if (!emailOrId.includes('@')) return emailOrId;
  const users = await request<Array<{ accountId: string }>>(
    'GET',
    `/user/search?query=${encodeURIComponent(emailOrId)}`,
  );
  if (!users.length) throw new Error(`no Jira user found for "${emailOrId}"`);
  return users[0].accountId;
}

export async function resolveSpaceId(spaceKey: string): Promise<string> {
  const r = await confluenceV2<{ results: Array<{ id: string }> }>(
    'GET',
    `/spaces?keys=${encodeURIComponent(spaceKey)}`,
  );
  if (!r.results?.length) throw new Error(`no Confluence space with key "${spaceKey}"`);
  return r.results[0].id;
}
