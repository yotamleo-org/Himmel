// readiness-tools.mjs -- the readiness role's host-side adapter:
//   * the host-private credential channel (a mode-0600 file in a mode-0700 attempt directory) and the minimal REAL
//     Jira port (readIssue / addReadinessLabel / readback), through the ordinary primary Jira CLI as a fixed-argv child;
//   * the attempt-ownership checks every act runs first (checkAdopted / guardedLabel / finishAttempt);
//   * the thin C0 MCP STDIO envelope (`node readiness-tools.mjs --startup-config <startup.json>`): exactly two tools,
//     inspect and act, over a finite host-admitted catalog and one copied issue. It is NOT the later readiness
//     machinery: there are no collectors, requirement policy, ruling, route, follow-up or Jira writes here.
// The model is never handed a port, a method, a URL, a header, an executable, a path or a credential.
//
// Boundary rules this file keeps:
//   * The credentials come ONLY from the private file. The port's destination and Authorization are
//     the file's; ambient JIRA_* in the host environment are ignored and overwritten.
//   * The child runs `node <primary_cli> <fixed verb> <validated key> ...`: finite argv, no shell, no
//     model-chosen method/URL/header/option. The primary CLI keeps its own ticket-standard and
//     requestAt checks; there is no parallel HTTP stack here.
//   * Every string that leaves a port method is redacted of the credential's raw, encoded and
//     Authorization forms. A credential never appears in argv, an error, a result or enumerable state.
//   * A refusal says WHICH rule failed, never what the file held.
import {
  closeSync, constants as FS, fstatSync, lstatSync, openSync, readFileSync, readSync, realpathSync, statSync, writeSync,
} from 'node:fs';
import { execFile } from 'node:child_process';
import { createHash } from 'node:crypto';
import { basename, dirname, isAbsolute, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

export class ReadinessError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'ReadinessError';
    this.code = code;
  }
}

export const READINESS_LABEL = 'needs-readiness';

const CRED_KEYS = ['api_token', 'base_url', 'email', 'project'];
const CRED_MAX_BYTES = 4096;
const PROJECT_RE = /^[A-Z][A-Z0-9]+$/;
const EMAIL_RE = /^[^\s\x00-\x1f\x7f:]+$/;
const TOKEN_RE = /^[\x21-\x7e]+$/;

function validateBaseUrl(raw) {
  let url;
  try { url = new URL(raw); } catch { return null; }
  if (!['http:', 'https:'].includes(url.protocol) || !url.hostname || url.username || url.password || url.search || url.hash) return null;
  return `${url.protocol}//${url.host}${url.pathname.replace(/\/+$/, '')}`;
}

function validateCredentials(obj) {
  if (obj === null || typeof obj !== 'object' || Array.isArray(obj)) throw new ReadinessError('malformed', 'credential file is malformed: not an object');
  const keys = Object.keys(obj).sort();
  if (keys.length !== CRED_KEYS.length || keys.some((k, i) => k !== CRED_KEYS[i])) {
    throw new ReadinessError('malformed', `credential file is malformed: it must hold exactly ${CRED_KEYS.join(', ')}`);
  }
  for (const k of CRED_KEYS) {
    if (typeof obj[k] !== 'string' || obj[k] === '') throw new ReadinessError('malformed', `credential file is malformed: ${k} must be a non-empty string`);
  }
  const base = validateBaseUrl(obj.base_url);
  if (base === null) throw new ReadinessError('malformed', 'credential file is malformed: base_url must be a bare http(s) URL (no userinfo, query or fragment)');
  if (!PROJECT_RE.test(obj.project)) throw new ReadinessError('malformed', 'credential file is malformed: project is not a Jira project key');
  if (obj.email.length > 254 || !EMAIL_RE.test(obj.email)) throw new ReadinessError('malformed', 'credential file is malformed: email is not a plain address');
  if (obj.api_token.length > 512 || !TOKEN_RE.test(obj.api_token)) throw new ReadinessError('malformed', 'credential file is malformed: api_token is not a plain printable token');
  return Object.freeze({ base_url: base, project: obj.project, email: obj.email, api_token: obj.api_token });
}

const sameIdentity = (a, b) => a.dev === b.dev && a.ino === b.ino;

// Read and validate the private credential file. Every check is on an OPEN descriptor (nofollow), and the
// path is re-checked against that descriptor after the read, so a swap or rewrite in between is refused.
// opts.uid: the expected owner (default: the effective user). opts.hooks.afterRead: a race-injection seam.
export async function readCredentials(path, opts = {}) {
  const uid = opts.uid ?? process.getuid();
  if (typeof path !== 'string' || !isAbsolute(path) || path.includes('\0') || path.split('/').includes('..')) {
    throw new ReadinessError('bad-path', 'credential path must be an absolute path without traversal');
  }
  const dir = dirname(path);
  let dirLstat;
  try { dirLstat = lstatSync(dir); } catch { throw new ReadinessError('missing', 'the private attempt directory is missing'); }
  let real;
  try { real = realpathSync(dir); } catch { throw new ReadinessError('missing', 'the private attempt directory is missing'); }
  if (dirLstat.isSymbolicLink() || real !== dir) throw new ReadinessError('dir-symlink', 'the private attempt directory path must not pass through a symlink');
  let dfd = -1;
  let ffd = -1;
  try {
    try { dfd = openSync(dir, FS.O_RDONLY | FS.O_DIRECTORY | FS.O_NOFOLLOW); } catch { throw new ReadinessError('dir-symlink', 'the private attempt directory cannot be opened as a plain directory'); }
    const dst = fstatSync(dfd);
    if (dst.uid !== uid) throw new ReadinessError('owner', 'the private attempt directory is not owned by the expected user');
    if ((dst.mode & 0o777) !== 0o700) throw new ReadinessError('dir-mode', 'the private attempt directory must be mode 0700');
    try { ffd = openSync(path, FS.O_RDONLY | FS.O_NOFOLLOW | FS.O_NONBLOCK); } catch (e) {
      if (e?.code === 'ENOENT') throw new ReadinessError('missing', 'the credential file is missing');
      if (e?.code === 'ELOOP') throw new ReadinessError('file-symlink', 'the credential file must not be a symlink');
      throw new ReadinessError('unreadable', 'the credential file cannot be opened');
    }
    const st = fstatSync(ffd);
    if (!st.isFile()) throw new ReadinessError('file-type', 'the credential path is not a regular file');
    if (st.uid !== (opts.fileUid ?? uid)) throw new ReadinessError('owner', 'the credential file is not owned by the expected user');
    if ((st.mode & 0o777) !== 0o600) throw new ReadinessError('file-mode', 'the credential file must be mode 0600');
    if (st.nlink !== 1) throw new ReadinessError('file-links', 'the credential file must have exactly one link');
    if (st.size < 1 || st.size > CRED_MAX_BYTES) throw new ReadinessError('file-size', `the credential file must be 1 to ${CRED_MAX_BYTES} bytes`);
    const buf = Buffer.alloc(st.size + 1);
    let got = 0;
    for (;;) {
      const n = readSync(ffd, buf, got, buf.length - got, null);
      if (n === 0) break;
      got += n;
      if (got === buf.length) break;
    }
    opts.hooks?.afterRead?.();
    // The path must still name the descriptor we read, and the descriptor must be unchanged.
    let now;
    let dnow;
    try { now = lstatSync(path); dnow = lstatSync(dir); } catch { throw new ReadinessError('identity-changed', 'the credential file or directory changed while it was read'); }
    const again = fstatSync(ffd);
    if (got !== st.size || !now.isFile() || !sameIdentity(now, st) || !sameIdentity(dnow, dst)
      || again.size !== st.size || again.mtimeMs !== st.mtimeMs || again.ctimeMs !== st.ctimeMs) {
      throw new ReadinessError('identity-changed', 'the credential file or directory changed while it was read');
    }
    let parsed;
    try { parsed = JSON.parse(buf.subarray(0, got).toString('utf8')); } catch { throw new ReadinessError('malformed', 'credential file is malformed: not valid JSON'); }
    return validateCredentials(parsed);
  } finally {
    if (ffd >= 0) closeSync(ffd);
    if (dfd >= 0) closeSync(dfd);
  }
}

// ---- host-only credential initialization ----------------------------------------------------------
// The launcher resolves {base_url, project, email, api_token} through the primary checkout's OWN built Jira
// client (its baseUrl / projectKey / authHeader configuration and secrets flow) and publishes ONLY the private
// file: one exclusive, mode-0600 create inside the mode-0700 attempt directory. Nothing is printed, logged or
// handed to a model channel, and an error says which rule failed, never what a value was.
function assertPrivateDir(dir, uid) {
  let st;
  try { st = lstatSync(dir); } catch { throw new ReadinessError('missing', 'the private attempt directory is missing'); }
  if (!st.isDirectory() || st.isSymbolicLink()) throw new ReadinessError('dir-symlink', 'the private attempt directory must be a plain directory');
  if (st.uid !== uid) throw new ReadinessError('owner', 'the private attempt directory is not owned by the expected user');
  if ((st.mode & 0o777) !== 0o700) throw new ReadinessError('dir-mode', 'the private attempt directory must be mode 0700');
}

export async function initCredentials(primaryCli, outPath, deps = {}) {
  const uid = deps.uid ?? process.getuid();
  if (typeof primaryCli !== 'string' || !isAbsolute(primaryCli) || primaryCli.includes('\0') || primaryCli.split('/').includes('..') || basename(primaryCli) !== 'index.js') {
    throw new ReadinessError('bad-cli', 'primary_cli must be the absolute path of the primary Jira CLI (index.js)');
  }
  let cliStat;
  try { cliStat = statSync(primaryCli); } catch { throw new ReadinessError('bad-cli', 'primary_cli does not exist'); }
  if (!cliStat.isFile()) throw new ReadinessError('bad-cli', 'primary_cli is not a regular file');
  if (typeof outPath !== 'string' || !isAbsolute(outPath) || outPath.includes('\0') || outPath.split('/').includes('..')) {
    throw new ReadinessError('bad-path', 'the credential path must be an absolute path without traversal');
  }
  assertPrivateDir(dirname(outPath), uid);
  const clientUrl = pathToFileURL(join(dirname(primaryCli), 'client.js')).href;
  let client;
  try { client = await (deps.importClient ?? ((url) => import(url)))(clientUrl); } catch { throw new ReadinessError('client-unavailable', 'the primary Jira client could not be loaded'); }
  let base; let project; let auth;
  try { base = client.baseUrl(); project = client.projectKey(); auth = client.authHeader(); } catch { throw new ReadinessError('client-config', 'the primary Jira client has no complete configuration'); }
  const basic = /^Basic ([A-Za-z0-9+/]+={0,2})$/.exec(typeof auth === 'string' ? auth : '');
  const pair = basic ? Buffer.from(basic[1], 'base64').toString('utf8') : '';
  const at = pair.indexOf(':');
  if (at < 1) throw new ReadinessError('client-config', 'the primary Jira client gave no usable Basic authorization');
  const creds = validateCredentials({ base_url: base, project, email: pair.slice(0, at), api_token: pair.slice(at + 1) });
  const body = JSON.stringify({ api_token: creds.api_token, base_url: creds.base_url, email: creds.email, project: creds.project }) + '\n';
  let fd = -1;
  try {
    try { fd = openSync(outPath, FS.O_WRONLY | FS.O_CREAT | FS.O_EXCL | FS.O_NOFOLLOW, 0o600); } catch { throw new ReadinessError('exists', 'the credential file could not be created exclusively'); }
    writeSync(fd, body);
  } finally {
    if (fd >= 0) closeSync(fd);
  }
}

function secretForms(s) {
  const b64 = Buffer.from(s).toString('base64');
  const b64u = Buffer.from(s).toString('base64url');
  return [s, b64, b64.replace(/=+$/, ''), b64u, encodeURIComponent(s), Buffer.from(s).toString('hex'), JSON.stringify(s).slice(1, -1)];
}

// Replace every raw, base64, url-encoded, hex and JSON-escaped form of the token, the email and the
// `email:token` pair (the Basic Authorization payload) with [redacted], longest form first.
export function redact(text, creds) {
  const forms = new Set();
  for (const s of [creds.api_token, creds.email, `${creds.email}:${creds.api_token}`]) {
    for (const f of secretForms(s)) if (f.length > 0) forms.add(f);
  }
  let out = String(text);
  for (const f of [...forms].sort((a, b) => b.length - a.length)) out = out.split(f).join('[redacted]');
  return out;
}

// ---- child construction (one owner, shared by every port method) ----------------------------------
const KEY_RE = /^[A-Z][A-Z0-9]*-[0-9]+$/;
function assertKey(key) {
  if (typeof key !== 'string' || key.length > 40 || !KEY_RE.test(key)) throw new ReadinessError('bad-key', 'not a bare ticket key');
  return key;
}

// The finite set of CLI invocations the port makes. Only a validated key is ever interpolated.
export const jiraArgv = Object.freeze({
  get: (key) => ['get', assertKey(key), '--json'],
  label: (key, present) => ['edit', assertKey(key), present ? '--add-labels' : '--remove-labels', READINESS_LABEL],
});

const ENV_ALLOW = ['PATH', 'HOME', 'TMPDIR', 'LANG', 'LC_ALL', 'TZ', 'JIRA_REQUEST_TIMEOUT_MS', 'JIRA_ALLOW_HOST'];

// The child's whole environment: a finite allowlist from the host, then the private credentials. Ambient
// JIRA_* passes only as the JIRA_ALLOW_HOST opt-in; every other secret in the host environment never passes.
export function buildChildEnv(creds, base = process.env) {
  const env = {};
  for (const k of ENV_ALLOW) if (typeof base[k] === 'string') env[k] = base[k];
  env.JIRA_BASE_URL = creds.base_url;
  env.JIRA_PROJECT_KEY = creds.project;
  env.JIRA_EMAIL = creds.email;
  env.JIRA_API_TOKEN = creds.api_token;
  return env;
}

function runCli({ cli, argv, env, cwd, timeoutMs }) {
  return new Promise((done) => {
    execFile(process.execPath, [cli, ...argv], {
      env, cwd, timeout: timeoutMs, killSignal: 'SIGKILL', maxBuffer: 1 << 20, windowsHide: true,
    }, (err, stdout, stderr) => {
      const timedOut = Boolean(err && err.killed && err.signal === 'SIGKILL');
      done({ code: err ? (typeof err.code === 'number' ? err.code : 1) : 0, stdout: String(stdout ?? ''), stderr: String(stderr ?? ''), timedOut });
    });
  });
}

const MESSAGE_MAX = 400;
const UNSUPPORTED = Object.freeze({ outcome: 'unsupported', code: 'unsupported', effects: 0 });
const unsupported = async () => ({ ...UNSUPPORTED });

function typedIssue(raw, key, creds) {
  let j;
  try { j = JSON.parse(raw); } catch { return null; }
  const f = j && typeof j === 'object' ? j.fields : null;
  if (!j || j.key !== key || !f || typeof f !== 'object') return null;
  if (!Array.isArray(f.labels) || f.labels.some((l) => typeof l !== 'string')) return null;
  if (!Array.isArray(f.fixVersions) || f.fixVersions.some((v) => typeof v?.name !== 'string')) return null;
  if (!('description' in f)) return null;
  const str = (v) => (typeof v === 'string' ? v : '');
  const issue = {
    key,
    summary: str(f.summary),
    status: str(f.status?.name),
    type: str(f.issuetype?.name),
    labels: [...f.labels],
    fixVersions: f.fixVersions.map((v) => v.name).filter(Boolean),
    description_sha256: createHash('sha256').update(JSON.stringify(f.description ?? null)).digest('hex'),
  };
  issue.issue_sha256 = createHash('sha256').update(JSON.stringify([issue.key, issue.summary, issue.status, issue.type, issue.labels, issue.fixVersions, issue.description_sha256])).digest('hex');
  const redactValues = (value) => {
    if (typeof value === 'string') return redact(value, creds);
    if (Array.isArray(value)) return value.map(redactValues);
    if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, redactValues(v)]));
    return value;
  };
  const clean = redactValues(issue);
  const authoritative = ['key', 'status', 'type', 'labels', 'fixVersions', 'description_sha256', 'issue_sha256'];
  if (authoritative.some((field) => JSON.stringify(clean[field]) !== JSON.stringify(issue[field]))) return null;
  return clean;
}

// The real minimal Jira port. `config` is the startup `port` object; `deps.env`/`deps.cwd` are host-chosen.
export async function createJiraPort(config, deps = {}) {
  const cli = config?.primary_cli;
  if (typeof cli !== 'string' || !isAbsolute(cli) || basename(cli) !== 'index.js') {
    throw new ReadinessError('bad-cli', 'primary_cli must be the absolute path of the primary Jira CLI (index.js)');
  }
  let cliStat;
  try { cliStat = statSync(cli); } catch { throw new ReadinessError('bad-cli', 'primary_cli does not exist'); }
  if (!cliStat.isFile()) throw new ReadinessError('bad-cli', 'primary_cli is not a regular file');
  const creds = await (deps.readCredentials ?? readCredentials)(config.credentials_path);
  const env = buildChildEnv(creds, deps.env ?? process.env);
  const cwd = deps.cwd ?? dirname(config.credentials_path);

  const budget = (deadline) => {
    const ms = Number.isFinite(deadline) ? Math.floor(deadline - Date.now()) : 0;
    return ms > 0 ? Math.min(ms, 60_000) : 0;
  };
  const fail = (code, message) => ({ outcome: 'error', code, message: redact(String(message), creds).slice(0, MESSAGE_MAX) });
  const cliError = (r) => {
    const text = (r.stderr.trim() || r.stdout.trim() || `the Jira CLI exited ${r.code}`);
    return redact(text, creds).slice(-MESSAGE_MAX);
  };

  async function read(kind, key, deadline) {
    let argv;
    try { argv = jiraArgv.get(key); } catch (e) { return fail(e.code, e.message); }
    const timeoutMs = budget(deadline);
    if (timeoutMs === 0) return fail('deadline', 'the deadline had already passed; nothing was requested');
    const r = await runCli({ cli, argv, env, cwd, timeoutMs });
    if (r.timedOut) return fail('timeout', `the read of ${key} did not finish before the deadline`);
    if (r.code !== 0) return { outcome: 'error', code: 'cli-failed', message: cliError(r) };
    const issue = typedIssue(r.stdout, key, creds);
    if (!issue) return fail('unreadable', `the Jira CLI answered for ${key} with something that is not an issue`);
    return { outcome: 'ok', kind, issue };
  }

  const port = {
    kind: 'jira',
    readIssue: (key, deadline) => read('issue', key, deadline),
    readback: (key, deadline) => read('readback', key, deadline),
    async addReadinessLabel(key, present, deadline) {
      let argv;
      try { argv = jiraArgv.label(key, Boolean(present)); } catch (e) { return fail(e.code, e.message); }
      const timeoutMs = budget(deadline);
      if (timeoutMs === 0) return fail('deadline', 'the deadline had already passed; nothing was requested');
      const r = await runCli({ cli, argv, env, cwd, timeoutMs });
      // A killed write may or may not have landed: only a later readback can say.
      if (r.timedOut) return { outcome: 'ambiguous', code: 'timeout', message: `the label write on ${key} did not finish before the deadline; read it back before repeating it` };
      if (r.code !== 0) return { outcome: 'ambiguous', code: 'cli-failed', message: cliError(r) };
      return { outcome: 'ok', key, label: READINESS_LABEL, present: Boolean(present) };
    },
    findMarker: unsupported,
    postComment: unsupported,
    addBlocks: unsupported,
    findFollowup: unsupported,
    createBacklog: unsupported,
  };
  return Object.freeze(port);
}

// The host picks the port kind; the model never does. A copy port is built by the injected factory and
// never touches the credential file; the jira port reads it (and refuses if it is absent or malformed).
export async function selectPort(config, deps = {}) {
  const port = config?.port;
  if (port?.kind === 'copy') {
    if (typeof deps.makeCopyPort !== 'function') throw new ReadinessError('copy-port-unavailable', 'no copy port factory was supplied');
    return deps.makeCopyPort(port);
  }
  if (port?.kind === 'jira') return createJiraPort(port, deps);
  throw new ReadinessError('bad-kind', 'port.kind must be copy or jira');
}

// ---- attempt ownership ------------------------------------------------------------------------------
// The adapter never holds, receives or prints the lease token. Ownership is the trusted session script's to
// judge (scripts/hooks/readiness-session.sh): before EVERY act, finish included, the adapter asks it whether this
// attempt's private AttemptConfirmation is fresh and consistent with the startup config AND the adopted
// registration still names the current holder. Anything but a clean yes is `not-adopted`, with a fixed reason: the
// script's own output is never relayed. Nothing here widens what an act may do; it only gates the effect.
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const NOT_ADOPTED = Object.freeze({ ok: false, code: 'not-adopted', reason: 'this session has not adopted the readiness lease, or no longer holds it' });
const SESSION_TOOL = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'hooks', 'readiness-session.sh');
// The project root the session script binds its queue library to (CLAUDE_PROJECT_DIR): this checkout, derived from where this
// code lives. It is never read from the model, the startup config or the environment.
const SESSION_PROJECT_DIR = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

function privateFile(path, uid) {
  let st;
  try { st = lstatSync(path); } catch { return null; }
  if (!st.isFile() || st.isSymbolicLink() || st.uid !== uid || (st.mode & 0o777) !== 0o600 || st.nlink !== 1) return null;
  return st;
}

// ---- the host-admitted catalog (thin C0) -------------------------------------------------------------------------
// The trusted launcher copies a host-supplied {source_head, roots, catalog} document into the private startup config.
// This adapter is the one validator: a positive allowlist of finite ids, each naming ONE pinned git blob (a tracked
// regular file at the exact source commit, by object id) or ONE copied issue file (a plain name under the evidence
// root). Nothing here is a path, URL or pattern the model can supply; the model only ever names an id.
const HEX40 = /^[0-9a-f]{40}$/;
const HEX64 = /^[0-9a-f]{64}$/;
const ID_RE = /^[a-z][a-z0-9.-]{0,63}$/;
const BLOB_PATH_RE = /^[A-Za-z0-9._][A-Za-z0-9._/-]{0,199}$/;
const FILE_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/;
const RESOURCE_MAX = 65536;
const CATALOG_MAX_ENTRIES = 8;
const CATALOG_DOC_MAX = 16384;
const sameKeys = (o, want) => { const k = Object.keys(o).sort(); return k.length === want.length && k.every((x, i) => x === want[i]); };
const absClean = (p) => typeof p === 'string' && p.length <= 1024 && isAbsolute(p) && !p.includes('\0') && !p.split('/').includes('..') && !p.split('/').includes('.');
const badCatalog = (why) => new ReadinessError('malformed', `the startup config catalog is invalid: ${why}`);

function validateCatalog(cfg) {
  const present = ['source_head', 'roots', 'catalog'].filter((k) => k in cfg);
  if (present.length === 0) return null;
  if (present.length !== 3) throw badCatalog('source_head, roots and catalog come together');
  if (typeof cfg.source_head !== 'string' || !HEX40.test(cfg.source_head)) throw badCatalog('source_head is not a 40-hex commit');
  const r = cfg.roots;
  if (r === null || typeof r !== 'object' || Array.isArray(r) || !sameKeys(r, ['evidence', 'repo']) || !absClean(r.repo) || !absClean(r.evidence)) throw badCatalog('roots must be exactly {repo, evidence}, absolute paths');
  if (!Array.isArray(cfg.catalog) || cfg.catalog.length > CATALOG_MAX_ENTRIES) throw badCatalog(`catalog must be a list of at most ${CATALOG_MAX_ENTRIES} entries`);
  const ids = new Set();
  let issues = 0;
  const entries = cfg.catalog.map((e) => {
    if (e === null || typeof e !== 'object' || Array.isArray(e) || typeof e.id !== 'string' || !ID_RE.test(e.id) || ids.has(e.id)) throw badCatalog('an entry has a missing, malformed or duplicate id');
    ids.add(e.id);
    const common = Number.isInteger(e.size) && e.size >= 0 && e.size <= RESOURCE_MAX && typeof e.sha256 === 'string' && HEX64.test(e.sha256)
      && typeof e.purpose === 'string' && e.purpose.length >= 1 && e.purpose.length <= 200 && !/[\x00-\x1f\x7f]/.test(e.purpose);
    if (e.kind === 'blob') {
      const segs = typeof e.path === 'string' ? e.path.split('/') : [''];
      if (!sameKeys(e, ['id', 'kind', 'mode', 'oid', 'path', 'purpose', 'sha256', 'size']) || !common || typeof e.oid !== 'string' || !HEX40.test(e.oid)
        || !['100644', '100755'].includes(e.mode) || !BLOB_PATH_RE.test(e.path) || segs.some((x) => x === '' || x === '.' || x === '..')) throw badCatalog(`blob entry ${e.id} is malformed`);
    } else if (e.kind === 'issue') {
      if (!sameKeys(e, ['file', 'id', 'key', 'kind', 'purpose', 'sha256', 'size']) || !common || typeof e.key !== 'string' || !KEY_RE.test(e.key) || e.key.length > 40
        || typeof e.file !== 'string' || !FILE_RE.test(e.file)) throw badCatalog(`issue entry ${e.id} is malformed`);
      issues += 1;
    } else throw badCatalog(`entry ${e.id} has an unknown kind`);
    return Object.freeze({ ...e });
  });
  if (issues > 1) throw badCatalog('at most one copied issue is bound');
  return { source_head: cfg.source_head, roots: Object.freeze({ repo: r.repo, evidence: r.evidence }), catalog: Object.freeze(entries) };
}

// The private startup config the trusted launcher wrote: mode 0600 in a mode-0700 directory named for the minted
// session id, which the file must repeat as its immutable scope. Returns only what the adapter reads.
export function loadStartup(path, opts = {}) {
  const uid = opts.uid ?? process.getuid();
  if (typeof path !== 'string' || !isAbsolute(path) || path.includes('\0') || path.split('/').includes('..') || basename(path) !== 'startup.json') {
    throw new ReadinessError('bad-path', 'the startup config must be an absolute path to startup.json without traversal');
  }
  const dir = dirname(path);
  assertPrivateDir(dir, uid);
  const st = privateFile(path, uid);
  if (!st || st.size < 2 || st.size > 32768) throw new ReadinessError('startup-file', 'the startup config must be a private mode-0600 regular file');
  let cfg;
  try { cfg = JSON.parse(readFileSync(path, 'utf8')); } catch { throw new ReadinessError('malformed', 'the startup config is not valid JSON'); }
  if (cfg === null || typeof cfg !== 'object' || Array.isArray(cfg)) throw new ReadinessError('malformed', 'the startup config is not an object');
  const str = (k) => (typeof cfg[k] === 'string' && cfg[k] !== '' ? cfg[k] : null);
  if (cfg.schema !== 'readiness-startup-v1' || cfg.lane !== 'native') throw new ReadinessError('malformed', 'the startup config is not a native readiness startup config');
  const scope = str('session_scope');
  if (!scope || !UUID.test(scope) || basename(dir) !== scope) throw new ReadinessError('malformed', 'the startup config scope is not the minted id of its directory');
  for (const k of ['doc', 'queue_lock']) if (!str(k) || !isAbsolute(cfg[k])) throw new ReadinessError('malformed', `the startup config ${k} must be an absolute path`);
  if (basename(cfg.queue_lock) !== 'queue-lock.sh') throw new ReadinessError('malformed', 'the startup config queue_lock is not queue-lock.sh');
  for (const k of ['version', 'attempt_id']) if (!str(k)) throw new ReadinessError('malformed', `the startup config ${k} is missing`);
  if (cfg.port === null || typeof cfg.port !== 'object' || !['copy', 'jira'].includes(cfg.port.kind)) throw new ReadinessError('malformed', 'the startup config port.kind must be copy or jira');
  const catalog = validateCatalog(cfg);
  return Object.freeze({
    path, dir, session_scope: scope, doc: cfg.doc, version: cfg.version, attempt_id: cfg.attempt_id, port: Object.freeze({ ...cfg.port }), ...(catalog ?? {}),
  });
}

function runSession(verb, startup, deps) {
  const tool = deps.sessionTool ?? SESSION_TOOL;
  // The child's whole environment is a finite host allowlist (exactly one CLAUDE_PROJECT_DIR, this checkout's root); its queue
  // environment comes from the private startup config.
  const env = { PATH: (deps.env ?? process.env).PATH ?? '/usr/bin:/bin', HOME: (deps.env ?? process.env).HOME ?? '', CLAUDE_PROJECT_DIR: SESSION_PROJECT_DIR };
  return new Promise((done) => {
    execFile('bash', [tool, verb, startup.dir], { env, timeout: deps.timeoutMs ?? 8000, killSignal: 'SIGKILL', maxBuffer: 1 << 16, windowsHide: true }, (err) => {
      done(err ? (typeof err.code === 'number' ? err.code : 255) : 0);
    });
  });
}

// ok only on a clean yes: the confirmation is fresh and the adopted registration still names the current holder.
export async function checkAdopted(startup, deps = {}) {
  return (await runSession('verify', startup, deps)) === 0 ? { ok: true } : { ...NOT_ADOPTED };
}

// The one place an act's effect is allowed: every act is verified afresh first, and a refusal runs nothing.
export async function guardedAct(startup, effect, deps = {}) {
  const adopted = await checkAdopted(startup, deps);
  if (!adopted.ok) return adopted;
  return effect();
}

// The readiness label act: a successful write needs a freshly valid adoption; the port is never touched otherwise.
export async function guardedLabel(startup, port, key, present, deadline, deps = {}) {
  return guardedAct(startup, async () => {
    const r = await port.addReadinessLabel(key, present, deadline);
    return r.outcome === 'ok' ? { ok: true, type: 'label', key, outcome: 'updated', evidence_id: null } : { ok: false, code: 'conflict', reason: 'the label write was not confirmed; read the ticket back before repeating it' };
  }, deps);
}

// finish: verified afresh, then the session script releases exactly the token this session adopted (a successor's
// lock refuses it) and removes the attempt directory. The model supplies no key, token or force parameter.
export async function finishAttempt(startup, deps = {}) {
  return (await runSession('finish', startup, deps)) === 0
    ? { ok: true, type: 'finish', key: null, outcome: 'finished', evidence_id: null }
    : { ...NOT_ADOPTED };
}


// ---- catalog resources ------------------------------------------------------------------------------------------
// A refusal says which rule failed with a FIXED sentence: it never echoes the request, a path, a config value or a
// process's output.
const REASONS = Object.freeze({
  'bad-request': 'the request is malformed or carries a field this tool does not accept',
  unadmitted: 'that id is not an admitted catalog resource',
  'unsupported-action': 'that action is not supported by this envelope',
  'not-in-scope': 'that key is not the bound copied issue',
  'port-unavailable': 'this envelope serves only the copied issue; no other port is available',
  changed: 'the admitted resource is missing, changed or is not the pinned bytes',
  'too-large': 'the admitted resource exceeds the per-request size limit',
  'not-text': 'the admitted resource is not UTF-8 text',
});
const refuse = (code) => ({ ok: false, code, reason: REASONS[code] });

const GIT_TIMEOUT_MS = 10_000;
// A fixed-argv git child over a verified object id: no ref, path or option comes from the model, and the child gets a
// finite environment with no user or system git configuration.
function runGit(repo, args, maxBuffer) {
  return new Promise((done) => {
    execFile('git', ['-C', repo, '--no-pager', ...args], { // git-env-ok: the child env below is a finite allowlist; no GIT_* name is inherited and the GIT_* it sets only isolate config
      env: { PATH: process.env.PATH ?? '/usr/bin:/bin', GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null', GIT_TERMINAL_PROMPT: '0', GIT_OPTIONAL_LOCKS: '0', GIT_NO_LAZY_FETCH: '1', LC_ALL: 'C' },
      encoding: 'buffer', timeout: GIT_TIMEOUT_MS, killSignal: 'SIGKILL', maxBuffer, windowsHide: true,
    }, (err, stdout) => done(err ? { ok: false, overflow: err.code === 'ERR_CHILD_PROCESS_STDIO_MAXBUFFER' } : { ok: true, out: stdout }));
  });
}

// The bytes must be exactly what the catalog said (size and SHA-256) and valid UTF-8 text.
function checkBytes(entry, buf) {
  if (buf.length !== entry.size || createHash('sha256').update(buf).digest('hex') !== entry.sha256) return refuse('changed');
  let content;
  try { content = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(buf); } catch { return refuse('not-text'); }
  return { ok: true, content };
}

async function readBlob(startup, entry) {
  const repo = startup.roots.repo;
  const pinKind = await runGit(repo, ['cat-file', '-t', startup.source_head], 64);
  if (!pinKind.ok || pinKind.out.toString('latin1').trim() !== 'commit') return refuse('changed');
  // the object must be the tracked regular file at the pinned commit (not a symlink, submodule or other object)
  const tree = await runGit(repo, ['ls-tree', '-z', startup.source_head, '--', entry.path], 4096);
  if (!tree.ok) return refuse('changed');
  const m = /^(\d{6}) (blob|tree|commit) ([0-9a-f]{40})\t([^\0]*)\0$/.exec(tree.out.toString('latin1'));
  if (!m || m[1] !== entry.mode || m[2] !== 'blob' || m[3] !== entry.oid || m[4] !== entry.path) return refuse('changed');
  const body = await runGit(repo, ['cat-file', 'blob', entry.oid], RESOURCE_MAX + 1);
  if (!body.ok) return refuse(body.overflow ? 'too-large' : 'changed');
  const got = checkBytes(entry, body.out);
  return got.ok ? { ok: true, id: entry.id, kind: 'blob', path: entry.path, size: entry.size, sha256: entry.sha256, content: got.content } : got;
}

// The copied issue: a plain file name under the admitted evidence root, opened nofollow and checked on the open descriptor
// (regular, single link, ours, the catalog's size and hash) and again against the path after the read.
async function readIssueFile(startup, entry) {
  const dir = startup.roots.evidence;
  try {
    const dst = lstatSync(dir);
    if (!dst.isDirectory() || dst.isSymbolicLink() || realpathSync(dir) !== dir) return refuse('changed');
  } catch { return refuse('changed'); }
  const path = join(dir, entry.file);
  let fd = -1;
  try {
    try { fd = openSync(path, FS.O_RDONLY | FS.O_NOFOLLOW | FS.O_NONBLOCK); } catch { return refuse('changed'); }
    const st = fstatSync(fd);
    if (!st.isFile() || st.nlink !== 1 || st.uid !== process.getuid() || st.size !== entry.size || st.size > RESOURCE_MAX) return refuse('changed');
    const buf = Buffer.alloc(st.size);
    let got = 0;
    while (got < st.size) {
      const n = readSync(fd, buf, got, st.size - got, null);
      if (n === 0) break;
      got += n;
    }
    let now;
    try { now = lstatSync(path); } catch { return refuse('changed'); }
    const again = fstatSync(fd);
    if (got !== st.size || !now.isFile() || !sameIdentity(now, st) || again.size !== st.size || again.mtimeMs !== st.mtimeMs || again.ctimeMs !== st.ctimeMs) return refuse('changed');
    const checked = checkBytes(entry, buf);
    if (!checked.ok) return checked;
    let doc;
    try { doc = JSON.parse(checked.content); } catch { return refuse('changed'); }
    if (doc === null || typeof doc !== 'object' || doc.key !== entry.key || !Array.isArray(doc.labels) || doc.labels.some((l) => typeof l !== 'string')) return refuse('changed');
    return { ok: true, id: entry.id, kind: 'issue', key: entry.key, size: entry.size, sha256: entry.sha256, content: checked.content, labels: [...doc.labels] };
  } finally {
    if (fd >= 0) closeSync(fd);
  }
}

// inspect: an exact catalog id, nothing else. Every read re-verifies the resource against the catalog's bytes.
export async function readCatalogResource(startup, id) {
  const entry = typeof id === 'string' && Array.isArray(startup?.catalog) ? startup.catalog.find((e) => e.id === id) : undefined;
  if (!entry) return refuse('unadmitted');
  return entry.kind === 'blob' ? readBlob(startup, entry) : readIssueFile(startup, entry);
}

// ---- the copy port (thin C0) ------------------------------------------------------------------------------------
// The copied remote state is the admitted issue file's labels, held in memory: an act changes only this copy (never the
// admitted file, never Jira). One issue is bound; any other key is not in the copy.
export function createCopyPort(startup) {
  const entry = startup.catalog?.find((e) => e.kind === 'issue');
  let labels = null;
  const load = async () => {
    if (!entry) return null;
    if (labels === null) {
      const r = await readCatalogResource(startup, entry.id);
      if (!r.ok) return null;
      labels = [...r.labels];
    }
    return labels;
  };
  const view = async (kind, key) => {
    if (!entry || key !== entry.key) return { outcome: 'error', code: 'not-in-catalog', message: 'that key is not in the copied state' };
    const cur = await load();
    if (cur === null) return { outcome: 'error', code: 'unreadable', message: 'the copied issue could not be read' };
    return { outcome: 'ok', kind, issue: { key, labels: [...cur], issue_sha256: entry.sha256 } };
  };
  return Object.freeze({
    kind: 'copy',
    labelsNow: load,
    readIssue: (key) => view('issue', key),
    readback: (key) => view('readback', key),
    async addReadinessLabel(key, present) {
      if (!entry || key !== entry.key) return { outcome: 'error', code: 'not-in-catalog', message: 'that key is not in the copied state' };
      // the admitted file is re-verified (size, hash, identity, no-follow) before EVERY update; a file that changed or
      // cannot be read refuses and leaves the copy as it was
      const fresh = await readCatalogResource(startup, entry.id);
      if (!fresh.ok) return { outcome: 'error', code: 'unreadable', message: 'the copied issue could not be read' };
      const cur = await load();
      if (cur === null) return { outcome: 'error', code: 'unreadable', message: 'the copied issue could not be read' };
      const has = cur.includes(READINESS_LABEL);
      if (present && !has) cur.push(READINESS_LABEL);
      if (!present && has) labels = cur.filter((l) => l !== READINESS_LABEL);
      return { outcome: 'ok', key, label: READINESS_LABEL, present: Boolean(present) };
    },
    findMarker: unsupported,
    postComment: unsupported,
    addBlocks: unsupported,
    findFollowup: unsupported,
    createBacklog: unsupported,
  });
}

// ---- the MCP STDIO envelope --------------------------------------------------------------------------------------
// Newline-delimited JSON-RPC 2.0 on stdin/stdout, one request at a time. Exactly two tools; stdout carries protocol
// messages only (nothing is ever logged there) and a healthy session writes nothing to stderr.
const MCP_VERSIONS = Object.freeze(['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05']);
const SERVER_INFO = Object.freeze({ name: 'readiness', version: '0.1.0' });
const LINE_MAX = 262144;
const UNSUPPORTED_ACTS = new Set(['preparation-text', 'blocks', 'comment', 'backlog-followup', 'ruling', 'route']);
// The closed act schema carries no version or input-digest field: the bound version and scope are enforced by the
// adoption check, and the only effect is the in-memory copy. The full ActRequest version/input-digest contract is not
// implemented here (a P1/C3 obligation), which is why this envelope authorizes no live ticket mutation.
const TOOLS = Object.freeze([
  Object.freeze({
    name: 'inspect',
    description: 'Read one admitted catalog resource by its exact id. content, size and sha256 describe the admitted file bytes and never change; for the copied issue, labels is the copy\'s current state (labels_source "copy") and may differ from the labels inside content.',
    inputSchema: { type: 'object', properties: { id: { type: 'string', maxLength: 128 } }, required: ['id'], additionalProperties: false },
  }),
  Object.freeze({
    name: 'act',
    description: 'Perform one closed action: label (add or remove the readiness label on the bound copied issue) or finish (release this session\'s own lease and end).',
    inputSchema: {
      type: 'object',
      properties: { type: { type: 'string', enum: ['label', 'finish'] }, key: { type: 'string', maxLength: 40 }, present: { type: 'boolean' } },
      required: ['type'],
      additionalProperties: false,
    },
  }),
]);
const validId = (id) => (typeof id === 'string' ? id.length <= 256 : Number.isSafeInteger(id));

// serve: run until stdin ends; resolves 0 once every queued request has been answered and stdout is flushed.
export function serve(startup, io = {}, deps = {}) {
  const input = io.input ?? process.stdin;
  const output = io.output ?? process.stdout;
  // The copied issue is the only port this envelope serves. A jira-kind startup never reaches the credential file here.
  const port = startup.port.kind === 'copy' ? createCopyPort(startup) : null;
  const issueEntry = startup.catalog?.find((e) => e.kind === 'issue');
  let initialized = false;
  const send = (m) => { output.write(`${JSON.stringify({ jsonrpc: '2.0', ...m })}\n`); };
  const fail = (id, code, message) => send({ id, error: { code, message } });
  const toolResult = (id, data) => send({ id, result: { content: [{ type: 'text', text: JSON.stringify(data) }], isError: data.ok !== true } });

  async function inspectTool(args) {
    if (!sameKeys(args, ['id']) || typeof args.id !== 'string') return refuse('bad-request');
    // an inspect needs the same fresh adoption as an act: before adoption, after finish and after a lost lease it reads nothing
    if (!(await checkAdopted(startup, deps)).ok) return { ...NOT_ADOPTED };
    const r = await readCatalogResource(startup, args.id);
    if (r.ok && r.kind === 'issue') {
      // content, size and sha256 are the admitted file's bytes; labels is the copy's current state (labels_source says so)
      const now = port ? await port.labelsNow() : null;
      return { ...r, labels: now ?? r.labels, labels_source: now === null ? 'admitted-file' : 'copy' };
    }
    return r;
  }

  async function actTool(args) {
    if (typeof args.type !== 'string') return refuse('bad-request');
    if (UNSUPPORTED_ACTS.has(args.type)) return refuse('unsupported-action');
    if (args.type === 'finish') return sameKeys(args, ['type']) ? finishAttempt(startup, deps) : refuse('bad-request');
    if (args.type !== 'label') return refuse('bad-request');
    if (!sameKeys(args, ['key', 'present', 'type']) || typeof args.key !== 'string' || args.key.length > 40 || !KEY_RE.test(args.key) || typeof args.present !== 'boolean') return refuse('bad-request');
    if (!issueEntry || issueEntry.key !== args.key) return refuse('not-in-scope');
    if (!port) return refuse('port-unavailable');
    return guardedLabel(startup, port, args.key, args.present, Date.now() + 20_000, deps);
  }

  async function callTool(id, params) {
    if (params === null || typeof params !== 'object' || Array.isArray(params) || (params.name !== 'inspect' && params.name !== 'act')) return fail(id, -32602, 'unknown tool');
    const args = params.arguments;
    if (args === null || typeof args !== 'object' || Array.isArray(args)) return toolResult(id, refuse('bad-request'));
    return toolResult(id, params.name === 'inspect' ? await inspectTool(args) : await actTool(args));
  }

  async function handle(msg) {
    if (msg === null || typeof msg !== 'object' || Array.isArray(msg)) return fail(null, -32600, 'invalid request');
    const hasId = Object.prototype.hasOwnProperty.call(msg, 'id');
    if (hasId && !validId(msg.id)) return fail(null, -32600, 'invalid request');
    const id = hasId ? msg.id : null;
    if (msg.jsonrpc !== '2.0' || typeof msg.method !== 'string') return fail(id, -32600, 'invalid request');
    // a message with no id is a notification: it gets no answer and has no effect, whatever it names
    if (!hasId) return undefined;
    try {
      switch (msg.method) {
        case 'initialize': {
          const p = msg.params;
          if (initialized) return fail(id, -32600, 'already initialized');
          if (p === null || typeof p !== 'object' || Array.isArray(p) || typeof p.protocolVersion !== 'string') return fail(id, -32602, 'invalid params');
          initialized = true;
          return send({ id, result: { protocolVersion: MCP_VERSIONS.includes(p.protocolVersion) ? p.protocolVersion : MCP_VERSIONS[0], capabilities: { tools: {} }, serverInfo: SERVER_INFO } });
        }
        case 'ping': return send({ id, result: {} });
        case 'tools/list':
          if (!initialized) return fail(id, -32002, 'server not initialized');
          return send({ id, result: { tools: TOOLS } });
        case 'tools/call':
          if (!initialized) return fail(id, -32002, 'server not initialized');
          return await callTool(id, msg.params);
        default: return fail(id, -32601, 'method not found');
      }
    } catch {
      return fail(id, -32603, 'internal error');
    }
  }

  async function handleLine(line) {
    if (line.trim() === '') return undefined;
    let msg;
    try { msg = JSON.parse(line); } catch { return fail(null, -32700, 'parse error'); }
    return handle(msg);
  }

  return new Promise((resolve) => {
    let buf = '';
    let discarding = false;
    let chain = Promise.resolve();
    const enqueue = (fn) => { chain = chain.then(fn).catch(() => fail(null, -32603, 'internal error')); };
    input.setEncoding?.('utf8');
    input.on('data', (chunk) => {
      let text = String(chunk);
      while (text.length > 0) {
        const nl = text.indexOf('\n');
        const piece = nl === -1 ? text : text.slice(0, nl);
        if (!discarding) {
          buf += piece;
          // a line over the bound is refused once and its remainder discarded unread
          if (buf.length > LINE_MAX) { buf = ''; discarding = true; enqueue(() => fail(null, -32600, 'request too large')); }
        }
        if (nl === -1) return;
        if (!discarding) { const line = buf; enqueue(() => handleLine(line)); }
        buf = '';
        discarding = false;
        text = text.slice(nl + 1);
      }
    });
    input.on('end', () => { chain.then(() => output.write('', () => resolve(0))); });
    input.on('error', () => { chain.then(() => resolve(1)); });
  });
}

// ---- host CLI -------------------------------------------------------------------------------------------------
//   readiness-tools.mjs --startup-config <absolute startup.json>   the MCP STDIO envelope (what the generated MCP config runs)
//   readiness-tools.mjs init-credentials <primary index.js> <credentials file>   the launcher's private credential step
//   readiness-tools.mjs --check-catalog                                           the launcher's pre-acquire check: ONE catalog
//       document on stdin through the same validator the server runs; no file, path, credential or executable is read or named
async function main(argv) {
  if (argv.length === 1 && argv[0] === '--check-catalog') {
    try {
      const raw = readFileSync(0);
      if (raw.length > CATALOG_DOC_MAX) throw badCatalog('the document is too large');
      const doc = JSON.parse(raw.toString('utf8'));
      if (doc === null || typeof doc !== 'object' || Array.isArray(doc) || validateCatalog(doc) === null) throw badCatalog('not a catalog document');
      return 0;
    } catch (e) {
      process.stderr.write(`readiness-tools: check-catalog: ${e instanceof ReadinessError ? e.code : 'failed'}\n`);
      return 2;
    }
  }
  if (argv.length === 2 && argv[0] === '--startup-config') {
    let startup;
    try {
      startup = loadStartup(argv[1]);
    } catch (e) {
      process.stderr.write(`readiness-tools: serve: ${e instanceof ReadinessError ? e.code : 'failed'}\n`);
      return 2;
    }
    return serve(startup);
  }
  if (argv[0] === 'init-credentials' && argv.length === 3) {
    try {
      await initCredentials(argv[1], argv[2]);
      return 0;
    } catch (e) {
      const why = e instanceof ReadinessError ? e.code + ': ' + e.message : 'failed';
      process.stderr.write('readiness-tools: init-credentials: ' + why + '\n');
      return 2;
    }
  }
  process.stderr.write('usage: readiness-tools.mjs --startup-config <startup.json> | init-credentials <primary index.js> <credentials file> | --check-catalog (catalog document on stdin)\n');
  return 2;
}

const isMain = (() => {
  try { return Boolean(process.argv[1]) && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url)); } catch { return false; }
})();
if (isMain) main(process.argv.slice(2)).then((code) => process.exit(code));
