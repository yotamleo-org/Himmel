// readiness-tools.mjs -- the readiness role's host-side adapter library, cycle 1:
//   * the host-private credential channel (a mode-0600 file in a mode-0700 attempt directory), and
//   * the minimal REAL Jira port: readIssue / addReadinessLabel / readback, through the ordinary
//     primary Jira CLI as a fixed-argv child process.
//
// What this file is NOT (yet): there is no MCP STDIO server, no `inspect`/`act` tool surface, no
// guard and no launcher wiring here. Those are later cycles. Everything exported is a host function:
// the model is never handed a port, a method, a URL, a header, an executable or a credential.
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
  closeSync, constants as FS, fstatSync, lstatSync, openSync, readSync, realpathSync, statSync, writeSync,
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

// ---- private credential channel -------------------------------------------------------------------
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
    if (st.uid !== uid) throw new ReadinessError('owner', 'the credential file is not owned by the expected user');
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

// ---- redaction ------------------------------------------------------------------------------------
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

const ENV_ALLOW = ['PATH', 'HOME', 'TMPDIR', 'LANG', 'LC_ALL', 'TZ', 'JIRA_REQUEST_TIMEOUT_MS'];

// The child's whole environment: a finite allowlist from the host, then the private credentials. Ambient
// JIRA_* (and every other secret in the host environment) never passes.
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
  if (!j || j.key !== key || !f || typeof f !== 'object' || !Array.isArray(f.labels)) return null;
  const str = (v) => (typeof v === 'string' ? v : '');
  const issue = {
    key,
    summary: str(f.summary),
    status: str(f.status?.name),
    type: str(f.issuetype?.name),
    labels: f.labels.filter((l) => typeof l === 'string'),
    fixVersions: Array.isArray(f.fixVersions) ? f.fixVersions.map((v) => str(v?.name)).filter(Boolean) : [],
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

// ---- host CLI. Cycle 2 has only the launcher's private credential initialization; the STDIO server is a later cycle.
async function main(argv) {
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
  process.stderr.write('usage: readiness-tools.mjs init-credentials <primary index.js> <credentials file>\n');
  return 2;
}

const isMain = (() => {
  try { return Boolean(process.argv[1]) && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url)); } catch { return false; }
})();
if (isMain) main(process.argv.slice(2)).then((code) => process.exit(code));
