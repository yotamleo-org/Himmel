// scripts/where-are-we/collect.mjs
import { execFileSync, spawnSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { writeFileSync, utimesSync, statSync, renameSync, unlinkSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { isMain } from '../lib/is-main.mjs';
import { jiraRecords, prRecords, gitRecords } from './lib/collect.mjs';
import { branchToKey } from './lib/query.mjs';
import { appendRecords } from './lib/append.mjs';
import { readRecords } from './lib/ledger.mjs';
import { fold, inFlight } from './lib/fold.mjs';
import { UsageError } from './lib/errors.mjs';
import { validateRecord } from './lib/schema.mjs';
import { Diagnostics, diagnostic } from './lib/health.mjs';
import { collectionLock, createBudget, spawnBounded } from './lib/runtime.mjs';

// Well-formed Jira ticket key, e.g. PROJ-567. Used to filter the
// active-key set passed into the by-key status query (no JQL injection) and to
// keep PR keys (#7) out of it.
const TICKET_KEY_RE = /^[A-Z][A-Z0-9]+-\d+$/;

const JIRA_PAGE = 100;
const PR_BATCH = 25;
const MAX_JIRA_PAGES = 100;
const chunks = (values, size) => Array.from({ length: Math.ceil(values.length / size) }, (_, i) => values.slice(i * size, (i + 1) * size));

// ---------------------------------------------------------------------------
// Live readers (impure — partial observations carry their errors)
// ---------------------------------------------------------------------------

// Depth assumption: this file is scripts/where-are-we/collect.mjs, so the two
// '..' hops on the next line reach the repo root. If this file moves, recount
// those hops.
const _repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

// Keep the exported CLI query shapes compatible. Each all-status key query fits
// a page; the live reader follows cursors for both discovery and key reads.
// To-Do tickets enter only through a footprint, never the whole project backlog.
export function jiraQueries(activeKeys = []) {
  const queries = [
    ['list', '--status', 'In Progress', '--limit', String(JIRA_PAGE)],
  ];
  const safeKeys = [...new Set(activeKeys.filter((k) => TICKET_KEY_RE.test(k)))];
  for (const batch of chunks(safeKeys, JIRA_PAGE)) {
    queries.push(['list', '--jql', `key in (${batch.join(',')})`, '--limit', String(JIRA_PAGE)]);
  }
  return queries;
}

// Use the installed Jira client's credential loading, deadline and read guard.
// list's TSV drops statusCategory, so read status JSON through that same client.
function readJiraPage(request, budget) {
  const common = budget.run('git', ['-C', _repoRoot, 'rev-parse', '--path-format=absolute', '--git-common-dir'], { encoding: 'utf8' }).trim();
  const client = pathToFileURL(join(dirname(common), 'scripts', 'jira', 'dist', 'client.js')).href;
  const code = `const { request, projectKey } = await import(process.argv[1]);
    const q = JSON.parse(process.argv[2]);
    const params = new URLSearchParams({ jql: q.jql ?? ('project=' + projectKey() + ' AND status="In Progress" ORDER BY key'), fields: 'status', maxResults: String(q.limit) });
    if (q.nextPageToken) params.set('nextPageToken', q.nextPageToken);
    try { console.log(JSON.stringify({ data: await request('GET', '/search/jql?' + params) })); }
    catch (error) {
      const message = String(error.message), httpStatus = Number(message.match(/^HTTP (\\d{3}):/)?.[1]) || undefined;
      const identityFailure = [400,404].includes(httpStatus) && /(?:value|issue|key).{0,100}(?:not exist|not found|cannot be viewed|invalid)/i.test(message);
      console.log(JSON.stringify({ error: { httpStatus, identityFailure, code: error.code } }));
    }`;
  const result = JSON.parse(budget.run(process.execPath, ['--input-type=module', '-e', code, client, JSON.stringify(request)], { encoding: 'utf8' }));
  if (result.error) throw Object.assign(new Error('Jira read failed'), result.error);
  return result.data;
}

export function readJira(activeKeys = [], options = {}) {
  const budget = options.budget ?? createBudget(options);
  const readPage = options.readPage ?? ((request) => readJiraPage(request, budget));
  const rows = [];
  const diagnostics = new Diagnostics();
  const query = (args, keys) => {
    let nextPageToken;
    const seen = new Set();
    try {
      for (let pageNumber = 0; ; pageNumber++) {
        if (pageNumber >= MAX_JIRA_PAGES) throw new Error('Jira page budget exhausted');
        budget.take();
        const jql = args.includes('--jql') ? args[args.indexOf('--jql') + 1] : undefined;
        const page = readPage({ jql, limit: JIRA_PAGE, nextPageToken });
        if (!Array.isArray(page.issues)) throw new Error('invalid Jira page');
        for (const issue of page.issues) {
          const status = issue.fields?.status;
          if (!TICKET_KEY_RE.test(issue.key) || !status?.name) {
            diagnostics.add(`invalid Jira observation: ${issue.key ?? 'missing key'}`);
            continue;
          }
          rows.push({ key: issue.key, status: status.name, statusCategory: status.statusCategory?.key ?? status.statusCategory?.name });
        }
        nextPageToken = page.nextPageToken;
        if (!nextPageToken) {
          if (page.isLast === false) throw new Error('missing Jira next page token');
          break;
        }
        if (seen.has(nextPageToken)) throw new Error('repeated Jira page token');
        seen.add(nextPageToken);
      }
    } catch (err) {
      if (!nextPageToken && keys?.length > 1 && err.identityFailure === true && [400, 404].includes(err.httpStatus)) {
        const middle = Math.ceil(keys.length / 2);
        for (const half of [keys.slice(0, middle), keys.slice(middle)]) query(['list', '--jql', `key in (${half.join(',')})`], half);
      } else diagnostics.add(err);
    }
  };
  for (const args of jiraQueries(activeKeys)) query(args, args.includes('--jql') ? args[args.indexOf('--jql') + 1].match(/[A-Z][A-Z0-9]+-\d+/g) : undefined);
  return { rows, errors: diagnostics.errors, error_count: diagnostics.error_count };
}

export function repoSlug(run) {
  const url = String(run('git', ['-C', _repoRoot, 'remote', 'get-url', 'origin'], { encoding: 'utf8' })).trim();
  const match = url.match(/[:/]([^/:\s]+\/[^/\s]+?)(?:\.git)?\/?$/);
  if (!match) throw new Error('cannot resolve the GitHub repository from origin');
  return match[1];
}

const PR_FIELDS = 'number,state,headRefName,title,mergeable,mergeStateStatus,statusCheckRollup';
const RECENT_PR_FIELDS = 'number,state,headRefName,title';
const RECENT_PR_LIMIT = 100;
const OPEN_PR_LIMIT = 1000;

function discoverPRs(budget, repo) {
  const list = (state, limit, fields) => JSON.parse(budget.run('gh', ['pr', 'list', '-R', repo, '--state', state, '--limit', String(limit), '--json', fields], { encoding: 'utf8' }));
  const byNumber = new Map();
  const diagnostics = new Diagnostics();
  try {
    for (const pr of list('all', RECENT_PR_LIMIT, RECENT_PR_FIELDS)) byNumber.set(pr.number, pr);
  } catch (err) { diagnostics.add(err); }
  try {
    budget.take();
    const open = list('open', OPEN_PR_LIMIT, PR_FIELDS);
    for (const pr of open) byNumber.set(pr.number, pr);
    if (open.length >= OPEN_PR_LIMIT) diagnostics.add(`open PR read reached its limit of ${OPEN_PR_LIMIT}; older open PRs unread`);
  } catch (err) { diagnostics.add(err); }
  return { rows: [...byNumber.values()], errors: diagnostics.errors, error_count: diagnostics.error_count };
}

export function readPRBatch(numbers, run = execFileSync, repo) {
  const [owner, name] = String(repo ?? '').split('/');
  if (!owner || !name) throw new Error('readPRBatch needs an explicit owner/name repository');
  const fields = `number state headRefName title mergeable mergeStateStatus
    commits(last:1) { nodes { commit { statusCheckRollup { contexts(first:100) {
      nodes { ... on CheckRun { status conclusion } ... on StatusContext { state } }
      pageInfo { hasNextPage }
    } } } } }`;
  const query = `query($owner:String!,$name:String!) { repository(owner:$owner,name:$name) {
    ${numbers.map((n) => `p${n}: pullRequest(number:${n}) { ${fields} }`).join('\n')}
  } }`;
  let response;
  try {
    response = JSON.parse(run('gh', ['api', 'graphql', '-f', `query=${query}`, '-f', `owner=${owner}`, '-f', `name=${name}`], { encoding: 'utf8', timeout: 60000 }));
  } catch (error) {
    if (error.status !== 1 || !error.stdout) throw error;
    try { response = JSON.parse(String(error.stdout)); } catch { throw error; }
    if (!response.data?.repository || !Array.isArray(response.errors) || !response.errors.length) throw error;
  }
  const rows = [];
  const diagnostics = new Diagnostics();
  const errored = new Set();
  for (const error of response.errors ?? []) {
    diagnostics.add(error.message);
    const field = error.path?.[0] === 'repository' ? error.path[1] : undefined;
    errored.add(typeof field === 'string' ? field : '*');
  }
  for (const n of numbers) {
    const pr = response.data?.repository?.[`p${n}`];
    if (!pr) { diagnostics.add(`missing PR #${n}`); continue; }
    const contexts = pr.commits?.nodes?.[0]?.commit?.statusCheckRollup?.contexts;
    if (errored.has('*') || errored.has(`p${n}`)) {
      diagnostics.add(`PR #${n}: partial answer`);
      delete pr.mergeable;
    } else if (contexts?.pageInfo?.hasNextPage) {
      diagnostics.add(`PR #${n}: incomplete check rollup`);
      delete pr.mergeable; // preserve the last obligation when checks are unknown
    } else {
      pr.statusCheckRollup = contexts?.nodes ?? [];
    }
    rows.push(pr);
  }
  return { rows, errors: diagnostics.errors, error_count: diagnostics.error_count };
}

export function readPRs(activeNumbers = [], options = {}) {
  const budget = options.budget ?? createBudget(options);
  let repo = options.repo;
  const repoName = () => repo ??= repoSlug((command, args, opts) => budget.run(command, args, opts));
  const discover = options.discover ?? (() => discoverPRs(budget, repoName()));
  const readBatch = options.readBatch ?? ((numbers) => readPRBatch(numbers, (command, args, opts) => { budget.take(); return budget.run(command, args, opts); }, repoName()));
  const rows = [];
  const diagnostics = new Diagnostics();
  try {
    budget.take();
    const found = discover();
    rows.push(...(Array.isArray(found) ? found : found.rows));
    if (!Array.isArray(found)) diagnostics.merge(found);
  } catch (err) { diagnostics.add(err); }
  const found = new Set(rows.map((pr) => pr.number));
  const missing = [...new Set(activeNumbers)].filter((n) => Number.isSafeInteger(n) && n > 0 && !found.has(n));
  for (const batch of chunks(missing, PR_BATCH)) {
    try {
      budget.take();
      const result = readBatch(batch);
      rows.push(...(Array.isArray(result) ? result : result.rows));
      diagnostics.merge(result);
    } catch (err) { diagnostics.add(err); }
  }
  return { rows, errors: diagnostics.errors, error_count: diagnostics.error_count };
}

function readWorktrees(budget = createBudget()) {
  budget.take();
  return budget.run('git', ['-C', _repoRoot, 'worktree', 'list', '--porcelain'], { encoding: 'utf8' });
}

// ---------------------------------------------------------------------------
// collectAll — wiring (exported for testing with injected readers)
// ---------------------------------------------------------------------------

function collectPass(now, readers, activeKeys = [], activePRs = []) {
  const health = {};
  const read = (source, fn, fallback) => {
    health[source] = new Diagnostics();
    try {
      const value = fn();
      const result = Array.isArray(value) || typeof value === 'string' ? { rows: value, errors: [] } : value;
      health[source].merge(result);
      return result.rows;
    } catch (err) {
      health[source].add(err);
      return fallback;
    }
  };
  const prList = read('pr', () => readers.readPRs(activePRs), [])
    .filter((pr) => {
      if (Number.isSafeInteger(pr?.number) && ['OPEN', 'CLOSED', 'MERGED'].includes(pr.state?.toUpperCase())) return true;
      health.pr.add(`invalid PR observation: ${pr?.number ?? 'missing number'}`);
      return false;
    });
  const git = gitRecords(read('git', () => readers.readWorktrees(), ''), now);
  // Cross-project harness tickets: a LUNA ticket carrying an OPEN
  // himmel PR is harness work and must show its real Jira status, even though it
  // never appears in the HIMMEL-project status lists. Seed those branch keys into
  // the active set so jiraQueries reads them by key. OPEN only — merged/closed
  // history would re-query hundreds of terminal tickets every pass.
  const prKeys = prList
    .filter((p) => String(p.state).toUpperCase() === 'OPEN')
    .map((p) => branchToKey(p.headRefName))
    .filter((k) => k && TICKET_KEY_RE.test(k));
  const allKeys = [...new Set([...activeKeys, ...prKeys, ...git.map((r) => r.key)])];
  const jiraRows = read('jira', () => readers.readJira(allKeys), []).filter((row) => {
    if (typeof row?.status === 'string' && row.status.trim()) return true;
    health.jira.add(`invalid Jira observation: ${row?.key ?? 'missing key'}`);
    return false;
  });
  const jira = jiraRecords(jiraRows, now);
  const prs = prRecords(prList, now);
  const observedKeys = new Set(jiraRows.map((row) => row.key));
  const observedPRs = new Set(prList.map((pr) => pr.number));
  const missingKeys = allKeys.filter((key) => !observedKeys.has(key));
  const missingPRs = activePRs.filter((n) => !observedPRs.has(n));
  if (missingKeys.length) health.jira.add(`missing ticket ${missingKeys.slice(0, 4).join(', ')}; ${missingKeys.length} identities unresolved`, missingKeys.length);
  if (missingPRs.length) health.pr.add(`missing PR #${missingPRs.slice(0, 4).join(', #')}; ${missingPRs.length} identities unresolved`, missingPRs.length);
  return { records: [...jira, ...prs, ...git], health };
}

export function collectAll(now, readers, activeKeys = []) {
  const budget = createBudget();
  return collectPass(now, readers ?? liveReaders(budget), activeKeys).records;
}

function liveReaders(budget) {
  return { readJira: (keys) => readJira(keys, { budget }), readPRs: (numbers) => readPRs(numbers, { budget }), readWorktrees: () => readWorktrees(budget) };
}

// ---------------------------------------------------------------------------
// main — parse args, collect, append, return summary (exported for testing)
// ---------------------------------------------------------------------------

function parseArgs(argv) {
  const a = { ledger: null, now: null, marker: null };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--ledger') a.ledger = argv[++i];
    else if (argv[i] === '--now') a.now = argv[++i];
    else if (argv[i] === '--marker') a.marker = argv[++i];
  }
  return a;
}

export function main(argv, { readers, strict = false, ...limits } = {}) {
  const a = parseArgs(argv);
  if (!a.ledger) throw new UsageError('--ledger <path> is required');
  const lock = collectionLock(a.ledger, limits.outerDeadlineAt);
  try {
    const budget = createBudget({ ...limits, lockFd: lock.fd });
    return collectLocked(a, { readers, strict, budget });
  } finally { lock.release(); }
}

function collectLocked(a, { readers, strict, budget }) {
  const now = a.now ?? new Date().toISOString();
  const effectiveReaders = readers ?? liveReaders(budget);

  // An unreadable ledger cannot establish the identities needing reconciliation.
  // Refuse the refresh rather than silently certifying an empty active set.
  const prior = readRecords(a.ledger);
  if (prior.some((record) => !record || !validateRecord(record).ok)) throw new Error('ledger contains invalid records; repair before refreshing');
  const active = inFlight(fold(prior));
  const activeKeys = active.filter((it) => it.kind === 'ticket' && TICKET_KEY_RE.test(it.key)).map((it) => it.key);
  const activePRs = active.filter((it) => it.kind === 'pr' && /^#\d+$/.test(it.key)).map((it) => Number(it.key.slice(1)));
  appendRecords(a.ledger, ['jira', 'pr', 'git'].map((source) => ({
    ts: now, source, kind: 'collection', key: `@collect:${source}`, errors: ['refresh started; result pending or interrupted'], error_count: 1,
  })), { held: true });
  const { records, health } = collectPass(now, effectiveReaders, activeKeys, activePRs);
  try { budget.remaining(); } catch (error) { for (const h of Object.values(health)) h.add(error); }
  for (const record of records) {
    const validation = validateRecord(record);
    if (!validation.ok) health[record.source].add(validation.error);
  }
  const evidence = Object.entries(health).map(([source, health]) => ({
    ts: now, source, key: `@collect:${source}`, kind: 'collection', errors: health.errors, error_count: health.error_count,
    ...(!health.error_count ? { observed_at: now } : {}),
  }));
  const r = appendRecords(a.ledger, [...records, ...evidence], { held: true });
  const summary = `appended=${r.appended - evidence.length} dropped=${r.dropped}`;
  if (r.dropped > 0) {
    console.error(`[where-are-we] dropped ${r.dropped} records: ${diagnostic(r.dropReasons[0]?.error)}`);
  }
  if (a.marker && !r.dropped && Object.values(health).every((h) => !h.error_count)) {
    const completed = a.now ?? new Date().toISOString();
    let previous = 0;
    try { previous = statSync(a.marker).mtimeMs; } catch (error) { if (error.code !== 'ENOENT') throw error; }
    if (Date.parse(completed) >= previous) {
      const tmp = `${a.marker}.tmp-${randomUUID()}`;
      try {
        writeFileSync(tmp, completed + '\n', { flag: 'wx', mode: 0o600 });
        const time = new Date(completed);
        utimesSync(tmp, time, time);
        renameSync(tmp, a.marker);
      } finally { try { unlinkSync(tmp); } catch (error) { if (error.code !== 'ENOENT') throw error; } }
    }
  }
  if (strict && (r.dropped || Object.values(health).some((h) => h.error_count))) {
    throw new Error('collection incomplete; evidence persisted, freshness unchanged');
  }
  return summary;
}

// ---------------------------------------------------------------------------
// CLI entry
// ---------------------------------------------------------------------------

export function runCLI(argv, { deadlineMs = 90000 } = {}) {
  const ms = Math.max(1, Math.min(90000, deadlineMs));
  const outerDeadlineAt = Date.now() + ms;
  const deadlineAt = outerDeadlineAt - Math.min(15000, ms / 4);
  const code = `const {main} = await import(process.argv[1]);
    const {diagnostic} = await import(new URL('./lib/health.mjs', process.argv[1]));
    try { console.log(main(JSON.parse(process.argv[2]), {strict:true,deadlineAt:Number(process.argv[3]),outerDeadlineAt:Number(process.argv[4])})); }
    catch(error) { console.error(diagnostic(error)); process.exitCode=1; }`;
  // This outer watchdog also bounds local parsing/persistence and a stuck
  // append lock. An interrupted pass retains its pre-read pending evidence.
  const result = spawnBounded(spawnSync, '0.2', `${ms / 1000}s`, process.execPath, ['--input-type=module', '-e', code, import.meta.url, JSON.stringify(argv), String(deadlineAt), String(outerDeadlineAt)], {
    encoding: 'utf8', timeout: Math.ceil(ms + 1000), maxBuffer: 1024 * 1024,
  });
  if (result.status === 124 || result.status === 137) result.stderr = 'collector deadline exhausted; freshness unknown, refresh may be incomplete\n';
  if (result.error) result.stderr = diagnostic(result.error) + '\n';
  return { status: result.status === 0 ? 0 : 1, stdout: result.stdout ?? '', stderr: (result.stderr ?? '').slice(0, 1600) };
}

if (isMain(import.meta.url)) {
  const result = runCLI(process.argv.slice(2));
  process.stdout.write(result.stdout);
  process.stderr.write(result.stderr);
  process.exitCode = result.status;
}
