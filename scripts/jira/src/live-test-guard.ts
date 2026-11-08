// The live-test guard: the Jira test project setting, the HIMMEL_JIRA_LIVE_TEST marker and its own-key
// grammar, the route table, the loopback / unreachable URL tests, and the test-run-guard Jira door.
// Imports env-file.ts only, never client.ts, so client.ts can call the guard without an import cycle:
// requestAt and uploadMultipart pass liveTestGuard the request's base URL and a GET-only getter that
// never re-enters the guard (the station URL comes from env-file.ts's stationJiraBaseUrl).
import { spawnSync } from 'node:child_process';
import { readFileSync, readlinkSync } from 'node:fs';
import { homedir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { readEnvFile, sameJiraBase, stationJiraBaseUrl, underTest } from './env-file.js';

const PROJECT_KEY = /^[A-Z][A-Z0-9]+$/;
const OWN_KEYS = /^([A-Z][A-Z0-9]+-[0-9]+)(,[A-Z][A-Z0-9]+-[0-9]+)*$/;

/** The marker value's grammar: `none`, or a comma list of ticket keys. null = malformed. */
export function parseOwnKeys(value: string): string[] | null {
  if (value === 'none') return [];
  return OWN_KEYS.test(value) ? value.split(',') : null;
}

/** Keys read from the two station files only: himmel.conf.local, then himmel.conf. */
function stationFiles(configDir: string, keys: string[]): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = {};
  for (const file of ['himmel.conf.local', 'himmel.conf']) readEnvFile(join(configDir, file), new Set(keys), env);
  return env;
}

/** JIRA_TEST_PROJECT (or `candidate`), valid only when it is a project key and not a work project. */
export function resolveTestProject(configDir: string, candidate?: string): { testProject: string | null; problem: string | null } {
  const station = stationFiles(configDir, ['JIRA_TEST_PROJECT', 'JIRA_PROJECTS', 'JIRA_PROJECT_KEY']);
  const key = candidate ?? station.JIRA_TEST_PROJECT;
  if (!key) return { testProject: null, problem: 'no JIRA_TEST_PROJECT is set in himmel.conf or himmel.conf.local' };
  if (!PROJECT_KEY.test(key)) return { testProject: null, problem: `${key} is not a Jira project key (^[A-Z][A-Z0-9]+$)` };
  const work = (station.JIRA_PROJECTS ?? '').split(',').map((k) => k.trim());
  if (work.includes(key)) return { testProject: null, problem: `${key} is a work project (JIRA_PROJECTS)` };
  if (station.JIRA_PROJECT_KEY === key) return { testProject: null, problem: `${key} is a work project (the station JIRA_PROJECT_KEY)` };
  return { testProject: key, problem: null };
}

/** `_csg_is_claude`'s three rules (scripts/lib/chokepoint-seam-guard.sh): plain, native versioned, npm. */
export function isClaudeProc(procRoot: string, pid: number): boolean {
  let exe = '';
  try {
    exe = readlinkSync(join(procRoot, String(pid), 'exe'));
  } catch {
    // no exe link: argv decides
  }
  if (basename(exe) === 'claude' || exe.includes('/claude/versions/')) return true;
  let argv: string[] = [];
  try {
    argv = readFileSync(join(procRoot, String(pid), 'cmdline'), 'utf8').split('\0');
  } catch {
    return false;
  }
  const [a0 = '', a1 = ''] = argv;
  if (a0 && basename(a0) === 'claude') return true;
  return basename(a0) === 'node' && /\/@anthropic-ai\/claude-code\/cli\.m?js$/.test(a1);
}

const dirOf = (env: NodeJS.ProcessEnv): string | null =>
  env.HIMMEL_CONFIG_DIR || (env.HOME ? join(env.HOME, '.himmel') : null);

function parentOf(procRoot: string, pid: number): number | 'gone' | 'malformed' {
  let status: string;
  try {
    status = readFileSync(join(procRoot, String(pid), 'status'), 'utf8');
  } catch {
    return 'gone';
  }
  const m = /^PPid:\s*(\d+)\s*$/m.exec(status);
  return m ? Number(m[1]) : 'malformed';
}

function environOf(procRoot: string, pid: number): NodeJS.ProcessEnv | null {
  try {
    const env: NodeJS.ProcessEnv = {};
    for (const kv of readFileSync(join(procRoot, String(pid), 'environ'), 'utf8').split('\0')) {
      const i = kv.indexOf('=');
      if (i > 0) env[kv.slice(0, i)] = kv.slice(i + 1);
    }
    return env;
  } catch {
    return null;
  }
}

/**
 * Is this process a live test? The marker is the union of the own env and every claude ancestor's
 * exec-time environ; the own keys are the intersection of every value present (`none` or a malformed
 * value adds the empty set). The config dir is the outermost marked ancestor's, else the own env's.
 * A malformed status or an unreadable claude environ is marked with no keys and no config dir; a
 * vanished ancestor ends the walk. Under the vitest harness (underTest(env)) the walk is skipped.
 */
export function liveTestContext(opts: { procRoot?: string; env?: NodeJS.ProcessEnv; pid?: number } = {}): {
  set: boolean; ownKeys: string[]; configDir: string | null;
} {
  const env = opts.env ?? process.env;
  const procRoot = opts.procRoot ?? '/proc';
  const values: string[] = [];
  let configDir: string | null = null;
  let failed = false;
  if (env.HIMMEL_JIRA_LIVE_TEST) {
    values.push(env.HIMMEL_JIRA_LIVE_TEST);
    configDir = dirOf(env);
  }
  if (!underTest(env)) {
    let next = parentOf(procRoot, opts.pid ?? process.pid);
    while (typeof next === 'number' && next > 0) {
      const pid = next;
      next = parentOf(procRoot, pid);
      if (next === 'gone') break;
      if (!isClaudeProc(procRoot, pid)) continue;
      const theirs = environOf(procRoot, pid);
      if (!theirs) { failed = true; continue; }
      if (!theirs.HIMMEL_JIRA_LIVE_TEST) continue;
      values.push(theirs.HIMMEL_JIRA_LIVE_TEST);
      configDir = dirOf(theirs);
    }
    if (next === 'malformed') failed = true;
  }
  if (failed) return { set: true, ownKeys: [], configDir: null };
  if (values.length === 0) return { set: false, ownKeys: [], configDir: null };
  const sets = values.map((v) => parseOwnKeys(v) ?? []);
  return { set: true, ownKeys: sets[0].filter((k) => sets.every((s) => s.includes(k))), configDir };
}

/** The one config dir every test-project question reads: marked, the context's; else the loadEnvFile rule. */
export function testProjectConfigDir(env: NodeJS.ProcessEnv = process.env): string | null {
  const ctx = liveTestContext({ env });
  if (ctx.set) return ctx.configDir;
  return env.HIMMEL_CONFIG_DIR || join(env.HOME || homedir(), '.himmel');
}

/** Is `project` the configured test project (read from testProjectConfigDir())? */
export function isTestProject(project: string): boolean {
  const dir = testProjectConfigDir();
  return dir !== null && resolveTestProject(dir).testProject === project;
}

export type WriteTargets =
  | { kind: 'read' }
  | { kind: 'targets'; project?: { key?: string; id?: string }; issues: string[]; links?: string[]; versions?: string[] }
  | { kind: 'unknown' };

const ID_OR_KEY = '(?:[A-Z][A-Z0-9]+-[0-9]+|[0-9]+)';
const ISSUE_REF = new RegExp(`^${ID_OR_KEY}$`);
const ISSUE_ROUTE = new RegExp(`^/issue/(${ID_OR_KEY})(?:/(?:comment|transitions|assignee|watchers|worklog|attachments)(?:/[0-9]+)?)?$`);
const UNWATCH = new RegExp(`^/issue/(${ID_OR_KEY})/watchers\\?accountId=[A-Za-z0-9:%-]+$`);
const UNKNOWN: WriteTargets = { kind: 'unknown' };

const obj = (v: unknown): Record<string, unknown> => (v && typeof v === 'object' ? v as Record<string, unknown> : {});
const refOf = (v: unknown): unknown => obj(v).key ?? obj(v).id;

/** Issue refs a body names: fields.parent, fields.issuelinks and update.issuelinks[].add, each side. */
function bodyLinks(body: unknown): unknown[] {
  const fields = obj(obj(body).fields);
  const sides = (link: unknown): unknown[] =>
    [obj(link).inwardIssue, obj(link).outwardIssue].filter((s) => s !== undefined).map(refOf);
  const refs: unknown[] = fields.parent !== undefined ? [refOf(fields.parent)] : [];
  for (const l of Array.isArray(fields.issuelinks) ? fields.issuelinks : []) refs.push(...sides(l));
  const update = obj(obj(body).update).issuelinks;
  for (const op of Array.isArray(update) ? update : []) refs.push(...sides(obj(op).add));
  return refs;
}

/** Every ref must be an issue key or numeric id; anything else makes the write unknown. */
function issueRefs(refs: unknown[]): string[] | null {
  const out = refs.map((r) => (typeof r === 'number' ? String(r) : r));
  return out.every((r): r is string => typeof r === 'string' && ISSUE_REF.test(r)) ? out : null;
}

function targets(issues: unknown[], extra: Omit<Extract<WriteTargets, { kind: 'targets' }>, 'kind' | 'issues'> = {}): WriteTargets {
  const refs = issueRefs(issues);
  return refs ? { kind: 'targets', ...extra, issues: refs } : UNKNOWN;
}

function restWrite(method: string, path: string, body: unknown): WriteTargets {
  if (method === 'DELETE') {
    const unwatch = UNWATCH.exec(path);
    if (unwatch) return targets([unwatch[1]]);
  }
  if (path.includes('?')) return UNKNOWN;
  const issue = ISSUE_ROUTE.exec(path);
  if (issue && ['PUT', 'POST', 'DELETE'].includes(method)) return targets([issue[1], ...bodyLinks(body)]);
  if (method === 'POST' && path === '/issue') {
    const project = obj(obj(obj(body).fields).project);
    if (typeof project.key === 'string') return targets(bodyLinks(body), { project: { key: project.key } });
    if (typeof project.id === 'string' || typeof project.id === 'number') return targets(bodyLinks(body), { project: { id: String(project.id) } });
    return UNKNOWN;
  }
  if (method === 'POST' && path === '/issueLink') {
    const b = obj(body);
    return targets([refOf(b.inwardIssue), refOf(b.outwardIssue)]);
  }
  const link = /^\/issueLink\/([0-9]+)$/.exec(path);
  if (method === 'DELETE' && link) return { kind: 'targets', issues: [], links: [link[1]] };
  if (method === 'POST' && path === '/version') {
    const b = obj(body);
    if (typeof b.project === 'string') return { kind: 'targets', project: { key: b.project }, issues: [] };
    if (typeof b.projectId === 'string' || typeof b.projectId === 'number') return { kind: 'targets', project: { id: String(b.projectId) }, issues: [] };
    return UNKNOWN;
  }
  const version = /^\/version\/([0-9]+)(\/move)?$/.exec(path);
  if (version && (version[2] ? method === 'POST' : method === 'PUT')) return { kind: 'targets', issues: [], versions: [version[1]] };
  return UNKNOWN;
}

function agileWrite(method: string, path: string, body: unknown): WriteTargets {
  const b = obj(body);
  const named = Array.isArray(b.issues) && b.issues.length > 0 ? b.issues as unknown[] : null;
  if (!named || path.includes('?')) return UNKNOWN;
  if (method === 'PUT' && path === '/issue/rank') {
    return targets([...named, ...[b.rankBeforeIssue, b.rankAfterIssue].filter((r) => r !== undefined)]);
  }
  if (method === 'POST' && (path === '/backlog/issue' || /^\/sprint\/[0-9]+\/issue$/.test(path))) return targets(named);
  return UNKNOWN;
}

/** A GET, or the one POST that reads (`/search/approximate-count`). */
export function isJiraRead(apiBase: string, method: string, path: string): boolean {
  return method === 'GET' || (method === 'POST' && apiBase === '/rest/api/3' && path === '/search/approximate-count');
}

/**
 * Every issue or project a request writes, by the spec's route table: one anchored pattern per row, the
 * query string refused except the one unwatch shape. A route the table does not hold is `unknown`.
 */
export function writeTargets(apiBase: string, method: string, path: string, body: unknown): WriteTargets {
  if (isJiraRead(apiBase, method, path)) return { kind: 'read' };
  if (apiBase === '/rest/api/3') return restWrite(method, path, body);
  if (apiBase === '/rest/agile/1.0') return agileWrite(method, path, body);
  return UNKNOWN;
}

/** An upload URL as (apiBase, path) under `baseUrl`; null when it is not under the base (another instance). */
export function splitUploadUrl(url: string, baseUrl: string): { apiBase: string; path: string } | null {
  const base = `${baseUrl.replace(/\/+$/, '')}/`;
  if (!url.startsWith(base)) return null;
  const rest = url.slice(base.length - 1);
  for (const apiBase of ['/rest/api/3', '/wiki']) {
    if (rest.startsWith(`${apiBase}/`)) return { apiBase, path: rest.slice(apiBase.length) };
  }
  return { apiBase: '', path: rest };
}

const hostOf = (url: string): string | null => {
  try {
    return new URL(url).hostname;
  } catch {
    return null;
  }
};

/** A loopback Jira is a local stub: it cannot reach the real one. */
export function jiraIsLoopback(url: string): boolean {
  const host = hostOf(url);
  return host === 'localhost' || host === '127.0.0.1' || host === '[::1]' || host === '::1';
}

/** Loopback or a `.invalid` host: no real Jira answers there. Only liveTestGuard asks this. */
export function jiraIsUnreachable(url: string): boolean {
  return jiraIsLoopback(url) || (hostOf(url) ?? '').endsWith('.invalid');
}

const TEST_RUN_GUARD = join(dirname(fileURLToPath(import.meta.url)), '../../lib/test-run-guard');

/** Would a post to `url` be a test on the station writing the real Jira? Loopback never asks; only exit 77 refuses. */
export function testJiraPostRefused(what: string, url: string = process.env.JIRA_BASE_URL ?? ''): boolean {
  if (jiraIsLoopback(url)) return false;
  const r = spawnSync('bash', [TEST_RUN_GUARD, 'check', '--real', `jira-${what.replace(/ /g, '-')}-comment`], { stdio: ['ignore', 'inherit', 'inherit'] });
  return r.status === 77;
}

/**
 * A test on the station never posts to the real Jira, whatever its release root. `what` names the
 * command in the refusal ("release leaks", "create"). Only exit 77 refuses.
 */
export function refuseTestJiraPost(what: string): void {
  if (testJiraPostRefused(what)) throw new Error(`${what}: refused, nothing was posted`);
}

type Get = <T>(path: string) => Promise<T>;
const REFUSED = 'jira: live-test write refused:';
const NO_DIR = 'the live-test config dir could not be read from the marked claude ancestor';

/** The issue refs, issueLink sides and version projects a write names, read fresh; the projects that are not the test project. */
async function offendingProjects(
  write: Extract<WriteTargets, { kind: 'targets' }>, test: string, ownKeys: string[], read: Get, unreadable: (what: string) => Error,
): Promise<string[]> {
  const out: string[] = [];
  let testId: string | undefined;
  const testProjectId = async (): Promise<string> => (testId ??= String((await read<{ id?: unknown }>(`/project/${test}`)).id));
  if (write.project?.key !== undefined && write.project.key !== test) out.push(write.project.key);
  if (write.project?.id !== undefined && write.project.id !== await testProjectId()) out.push(`id ${write.project.id}`);
  const issues = [...write.issues];
  for (const id of write.links ?? []) {
    const link = obj(await read<unknown>(`/issueLink/${id}`));
    const sides = issueRefs([refOf(link.inwardIssue), refOf(link.outwardIssue)]);
    if (!sides) throw unreadable(`/issueLink/${id}`);
    issues.push(...sides);
  }
  // Own keys stand only on an issue-scoped route, never on a create.
  const ownOk = write.project === undefined;
  for (const ref of issues) {
    if (ownOk && ownKeys.includes(ref)) continue;
    const key = obj(obj(obj(await read<unknown>(`/issue/${ref}?fields=project`)).fields).project).key;
    if (typeof key !== 'string') throw unreadable(`/issue/${ref}?fields=project`);
    if (key !== test) out.push(key);
  }
  for (const id of write.versions ?? []) {
    const projectId = obj(await read<unknown>(`/version/${id}`)).projectId;
    if (projectId === undefined) throw unreadable(`/version/${id}`);
    if (String(projectId) !== await testProjectId()) out.push(`id ${String(projectId)}`);
  }
  return [...new Set(out)];
}

/**
 * Under the live-test marker, a write reaches the network only when every target is in the test project
 * or is an own key on an issue-scoped route. Unmarked it returns at once (no read). `baseUrl` is the
 * request's base; `get` reads `/rest/api/3<path>` without re-entering the guard. Throws the refusal.
 */
export async function liveTestGuard(apiBase: string, method: string, path: string, body: unknown, baseUrl: string, get: Get): Promise<void> {
  const ctx = liveTestContext();
  if (!ctx.set) return;
  const write = writeTargets(apiBase, method, path, body);
  if (write.kind === 'read' || jiraIsUnreachable(baseUrl)) return;
  const { testProject: test, problem } = ctx.configDir ? resolveTestProject(ctx.configDir) : { testProject: null, problem: NO_DIR };
  if (!test || !ctx.configDir) {
    throw new Error(`${REFUSED} this is a live test (HIMMEL_JIRA_LIVE_TEST) but no valid Jira test project is configured: ${problem}. ` +
      'Ask the operator to run: himmelctl config set jira.testProject <KEY>.');
  }
  const raw = stationJiraBaseUrl(ctx.configDir, { profileFromEnv: false });
  const station = raw && hostOf(raw) ? raw : null;
  if (!station || !sameJiraBase(baseUrl, station)) {
    throw new Error(`${REFUSED} this request goes to ${baseUrl}, not the station's Jira (${station ?? 'no station Jira URL is configured'}); ` +
      `a live test writes only to ${test} on the station's own instance.`);
  }
  const route = `${method} ${apiBase}${path}`;
  const routeRefusal = (why = ''): Error =>
    new Error(`${REFUSED} ${route} is not a write the live-test guard can tie to one project${why}, so it never runs under a live test (test project ${test}).`);
  if (write.kind === 'unknown') throw routeRefusal();
  const read: Get = async <T>(p: string): Promise<T> => {
    try {
      return await get<T>(p);
    } catch (e) {
      throw routeRefusal(` (the read GET /rest/api/3${p} failed: ${(e as Error).message})`);
    }
  };
  const unreadable = (p: string): Error => routeRefusal(` (the read GET /rest/api/3${p} named no project)`);
  const off = await offendingProjects(write, test, ctx.ownKeys, read, unreadable);
  if (off.length > 0) {
    throw new Error(`${REFUSED} ${route} targets project ${off.join(', ')}; a live test writes only to the test project ${test} ` +
      `(JIRA_TEST_PROJECT) or to this brief's own tickets. Use --project ${test}, or an issue in ${test}.`);
  }
}

/** The guard for a full upload URL: split under the base (not under it is R-instance), then liveTestGuard. */
export async function liveTestUploadGuard(url: string, baseUrl: () => string, get: Get): Promise<void> {
  if (!liveTestContext().set) return;
  const base = baseUrl();
  const split = splitUploadUrl(url, base);
  await liveTestGuard(split?.apiBase ?? '', 'POST', split?.path ?? '', undefined, split ? base : url, get);
}
