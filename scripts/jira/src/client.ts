import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { resolveSecrets } from '../../lib/resolve-secrets.mjs';
import { envFilePath, readEnvFile, stationJiraBaseUrl, underTest } from './env-file.js';
import { isJiraRead, jiraIsLoopback, liveTestGuard, liveTestUploadGuard, testJiraPostRefused } from './live-test-guard.js';
import { preRead, recordVersionWrite, versionWriteScope, type Getter, type WriteRequest } from './release/version-writes.js';

const DOTENV_KEYS = new Set([
  'JIRA_BASE_URL', 'JIRA_EMAIL', 'JIRA_API_TOKEN', 'JIRA_PROJECT_KEY',
  'JIRA_SEVERITY_FIELD', 'JIRA_BOARD_ID', 'CONFLUENCE_EMAIL', 'CONFLUENCE_API_TOKEN',
]);

const CONFIG_KEYS = new Set(['JIRA_BASE_URL', 'JIRA_EMAIL', 'JIRA_PROJECT_KEY']);

// The credentials a station secrets move takes out of .env. The one resolver is asked before
// .env is read (environment, credentials directory, keyring, then .env), so a
// keyring value beats a stale .env line; a name already exported or set by himmel.conf is kept.
const RESOLVED_KEYS = ['JIRA_EMAIL', 'JIRA_API_TOKEN'];

function resolveFromKeyring(root: string): void {
  const missing = RESOLVED_KEYS.filter((k) => !process.env[k]);
  if (missing.length === 0) return;
  for (const [k, v] of Object.entries(resolveSecrets(root, missing))) process.env[k] ||= v;
}

export function loadEnvFile(envPath: string): void {
  const confDir = process.env.HIMMEL_CONFIG_DIR || join(process.env.HOME || homedir(), '.himmel');
  const station = stationJiraBaseUrl(confDir, { profileFromEnv: true, envPath });
  if (station) process.env.JIRA_BASE_URL ||= station;
  readEnvFile(join(confDir, 'himmel.conf.local'), CONFIG_KEYS);
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
  resolveFromKeyring(dirname(envPath));
  readEnvFile(envPath, DOTENV_KEYS);
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

let envLoaded = false;
function ensureEnvLoaded(): void {
  if (envLoaded) return;
  envLoaded = true;
  if (!underTest()) loadEnvFile(envFilePath());
  normalizeEnv();
}
if (!underTest()) ensureEnvLoaded();

export const baseUrl = (): string => {
  ensureEnvLoaded();
  // No hardcoded default. A stranger who sets a token but
  // not the base URL must fail loud here, never silently send requests
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
  ensureEnvLoaded();
  // No hardcoded default. Operators must set
  // JIRA_PROJECT_KEY explicitly so this plugin is portable across
  // repos/projects without code edits.
  const key = process.env.JIRA_PROJECT_KEY;
  if (!key) {
    throw new Error(
      'JIRA_PROJECT_KEY is not set. Add it to ~/.himmel/himmel.conf (or shell environment) ' +
        'and re-run; `jira config` shows what is set and where it came from. See docs/setup/new-machine.md.',
    );
  }
  return key;
};

export const severityField = (): string | undefined => {
  ensureEnvLoaded();
  return process.env.JIRA_SEVERITY_FIELD || undefined;
};

export const boardId = (): string | undefined => {
  ensureEnvLoaded();
  return process.env.JIRA_BOARD_ID || undefined;
};

export function authHeader(): string {
  ensureEnvLoaded();
  const email = process.env.JIRA_EMAIL ?? '';
  const token = process.env.JIRA_API_TOKEN ?? '';
  // Fail before a request: an empty Basic header only surfaces later as a 401 with no hint.
  for (const [name, value] of [['JIRA_EMAIL', email], ['JIRA_API_TOKEN', token]]) {
    if (!value) {
      throw new Error(
        `${name} is not set. The email goes in ~/.himmel/himmel.conf; the token goes in the keyring: ` +
          '`himmel-secrets put --stdin JIRA_API_TOKEN` (the value on stdin, never on argv). ' +
          '`jira config` shows whether each is set and where it came from, never the value.',
      );
    }
  }
  return `Basic ${Buffer.from(`${email}:${token}`).toString('base64')}`;
}

// Confluence often needs its OWN Atlassian token: a *scoped* Jira API token
// 401s against /wiki (Confluence), same as the bitbucket CLI needs a separate
// scoped token. Use CONFLUENCE_EMAIL/CONFLUENCE_API_TOKEN when BOTH are set;
// otherwise fall back to the Jira creds (works when JIRA_API_TOKEN is a
// scopeless/full-account token covering both products).
export function confluenceAuthHeader(): string {
  ensureEnvLoaded();
  const email = process.env.CONFLUENCE_EMAIL;
  const token = process.env.CONFLUENCE_API_TOKEN;
  if (email && token) {
    return `Basic ${Buffer.from(`${email}:${token}`).toString('base64')}`;
  }
  return authHeader();
}

// A bad, stale or revoked token gets HTTP 200 with an empty body from a Jira search, and the only sign is this header.
export function assertAuthenticated(res: { status: number; headers?: Headers }): void {
  const reason = res.headers?.get('x-seraph-loginreason');
  if (reason === null || reason === undefined || reason === 'OK') return;
  throw new Error(
    `Jira did not accept the API token (HTTP ${res.status}, x-seraph-loginreason: ${reason}). ` +
      'The token is stale, revoked or not the one for this site. It lives in the keyring: ' +
      '`himmel-secrets put --stdin JIRA_API_TOKEN` (the value on stdin, never on argv). ' +
      '`jira config` shows whether the token is set and where it came from, never the value.',
  );
}

export const DEFAULT_REQUEST_DEADLINE_MS = 30_000;
const MAX_REQUEST_DEADLINE_MS = 2_147_483_647;
export function requestDeadlineMs(): number {
  const n = Number(process.env.JIRA_REQUEST_TIMEOUT_MS);
  return Number.isInteger(n) && n > 0 && n <= MAX_REQUEST_DEADLINE_MS ? n : DEFAULT_REQUEST_DEADLINE_MS;
}

export const READ_RETRIES = 3;
export const RETRY_AFTER_CAP_MS = 10_000;
export const RETRY_TOTAL_CAP_MS = 20_000;
export const RETRY_BACKOFF_MS = 200;
const BUSY_STATUSES = new Set([429, 502, 503, 504]);

function retryAfterMs(res: { headers?: Headers }): number | undefined {
  const raw = res.headers?.get('retry-after')?.trim();
  if (!raw) return undefined;
  if (/^\d+(\.\d+)?$/.test(raw)) return Number(raw) * 1000;
  const at = Date.parse(raw);
  return Number.isNaN(at) ? undefined : Math.max(0, at - Date.now());
}

async function fetchWithDeadline(
  what: string,
  url: string,
  init: RequestInit,
  isRead: boolean,
  bytes = false,
  caller?: AbortSignal,
): Promise<{ res: Response; body: string | Buffer }> {
  const ms = requestDeadlineMs();
  const stopped = () => new Error(`Jira request aborted by its caller: ${what}`);
  let waited = 0;
  for (let attempt = 0; ; attempt++) {
    if (caller?.aborted) throw stopped();
    let res: Response;
    let body: string | Buffer;
    const deadline = AbortSignal.timeout(ms);
    const signal = caller ? AbortSignal.any([deadline, caller]) : deadline;
    try {
      res = await fetch(url, { ...init, signal });
      body = bytes ? Buffer.from(await res.arrayBuffer()) : await res.text();
    } catch (err) {
      if (caller?.aborted) throw stopped();
      if (!signal.aborted) throw err;
      throw new Error(
        `Jira request timed out after ${ms} ms: ${what}` +
          (isRead ? '' : '. The request may have been applied: check Jira before repeating it.'),
      );
    }
    if (!isRead || attempt >= READ_RETRIES || !BUSY_STATUSES.has(res.status)) return { res, body };
    const wait = retryAfterMs(res) ?? RETRY_BACKOFF_MS * 2 ** attempt;
    if (wait > RETRY_AFTER_CAP_MS || waited + wait > RETRY_TOTAL_CAP_MS) return { res, body };
    waited += wait;
    await new Promise<void>((ok) => {
      const timer = setTimeout(done, wait);
      function done() { clearTimeout(timer); caller?.removeEventListener('abort', done); ok(); }
      caller?.addEventListener('abort', done, { once: true });
    });
    if (caller?.aborted) throw stopped();
  }
}

// The version-write hook's reads carry their own deadline: the write's fetch has none, so a hung read
// must not hang a real write.
export const HOOK_DEADLINE_MS = 5000;

function hookGetter(auth: string): Getter {
  return async <T>(path: string): Promise<T> => {
    const abort = new AbortController();
    let timer: ReturnType<typeof setTimeout> | undefined;
    const deadline = new Promise<never>((_, reject) => {
      timer = setTimeout(() => { abort.abort(); reject(new Error('version-write hook read timed out')); }, HOOK_DEADLINE_MS);
    });
    try {
      const res = await Promise.race([
        fetch(`${baseUrl()}/rest/api/3${path}`, { method: 'GET', headers: { Authorization: auth, Accept: 'application/json' }, signal: abort.signal }),
        deadline,
      ]);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      return JSON.parse(await Promise.race([res.text(), deadline])) as T;
    } finally {
      clearTimeout(timer);
    }
  };
}

// Journals a Fix Version write for the repair. Best-effort: any failure leaves the Jira
// write intact and the change unbound, which is the safe direction. Reads here never re-enter requestAt.
async function beginVersionWrite(
  apiBase: string, method: string, path: string, body: unknown, auth: string, writer: string | undefined,
): Promise<((response: unknown) => Promise<void>) | null> {
  try {
    if (!versionWriteScope(apiBase, method, path, body)) return null;
    const req: WriteRequest = { apiBase, method, path, body, writer, get: hookGetter(auth) };
    const pre = await preRead(req);
    if (!pre) return null;
    return async (response) => {
      try {
        await recordVersionWrite(req, response, pre);
      } catch {
        // unbound
      }
    };
  } catch {
    return null;
  }
}

let testWriteRefused: boolean | undefined;
function refuseTestWrite(what: string, url: string): void {
  if (jiraIsLoopback(url)) return;
  testWriteRefused ??= testJiraPostRefused('write', url);
  if (testWriteRefused) throw new Error(`${what}: refused, nothing was posted`);
}

export async function requestAt<T>(
  apiBase: string,
  method: string,
  path: string,
  body?: unknown,
  auth: string = authHeader(),
  writer?: string,
  opts: { signal?: AbortSignal } = {},
): Promise<T> {
  const base = baseUrl();
  const url = `${base}${apiBase}${path}`;
  await liveTestGuard(apiBase, method, path, body, base, hookGetter(auth));
  if (!isJiraRead(apiBase, method, path)) refuseTestWrite(`${method} ${apiBase}${path}`, url);
  const record = await beginVersionWrite(apiBase, method, path, body, auth, writer);
  const { res, body: text } = await fetchWithDeadline(`${method} ${apiBase}${path}`, url, {
    method,
    headers: {
      Authorization: auth,
      'Content-Type': 'application/json',
      Accept: 'application/json',
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  }, isJiraRead(apiBase, method, path), false, opts.signal) as { res: Response; body: string };
  assertAuthenticated(res);
  if (!res.ok) throw new Error(`HTTP ${res.status}: ${text}`);
  const parsed = (text.trim() ? JSON.parse(text) : {}) as T;
  if (record) await record(parsed);
  return parsed;
}

// `writer` names the code path that chose a Fix Version, for the journal; a hand path passes nothing.
export const request = <T>(method: string, path: string, body?: unknown, writer?: string, opts?: { signal?: AbortSignal }) =>
  requestAt<T>('/rest/api/3', method, path, body, undefined, writer, opts);
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
  await liveTestUploadGuard(url, baseUrl, hookGetter(auth));
  refuseTestWrite(`POST ${url}`, url);
  const data = readFileSync(filePath);
  const fd = new FormData();
  fd.append(field, new Blob([data]), basename(filePath));

  const { res, body: text } = await fetchWithDeadline(`POST ${url}`, url, {
    method: 'POST',
    headers: {
      Authorization: auth,
      'X-Atlassian-Token': 'no-check',
      // intentionally NO Content-Type. Fetch must set multipart boundary
    },
    body: fd,
  }, false) as { res: Response; body: string };
  assertAuthenticated(res);
  if (!res.ok) throw new Error(`HTTP ${res.status}: ${text.slice(0, 500)}`);
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
  const { res, body } = await fetchWithDeadline(`GET ${fullUrl}`, fullUrl, { headers: { Authorization: auth } }, true, true);
  const buf = body as Buffer;
  assertAuthenticated(res);
  if (!res.ok) throw new Error(`HTTP ${res.status}: ${buf.toString('utf8', 0, 500)}`);
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
