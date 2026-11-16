// scripts/where-are-we/collect.mjs
import { execFileSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { writeFileSync, utimesSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { isMain } from '../lib/is-main.mjs';
import { jiraRecords, prRecords, gitRecords } from './lib/collect.mjs';
import { branchToKey } from './lib/query.mjs';
import { appendRecords } from './lib/append.mjs';
import { readRecords } from './lib/ledger.mjs';
import { fold, inFlight } from './lib/fold.mjs';
import { UsageError } from './lib/errors.mjs';
import { validateRecord } from './lib/schema.mjs';

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
function readJiraPage(request) {
  const common = execFileSync('git', ['-C', _repoRoot, 'rev-parse', '--path-format=absolute', '--git-common-dir'], { encoding: 'utf8' }).trim();
  const client = pathToFileURL(join(dirname(common), 'scripts', 'jira', 'dist', 'client.js')).href;
  const code = `const { request, projectKey } = await import(process.argv[1]);
    const q = JSON.parse(process.argv[2]);
    const params = new URLSearchParams({ jql: q.jql ?? ('project=' + projectKey() + ' AND status="In Progress" ORDER BY key'), fields: 'status', maxResults: String(q.limit) });
    if (q.nextPageToken) params.set('nextPageToken', q.nextPageToken);
    console.log(JSON.stringify(await request('GET', '/search/jql?' + params)));`;
  return JSON.parse(execFileSync(process.execPath, ['--input-type=module', '-e', code, client, JSON.stringify(request)], { encoding: 'utf8', timeout: 150000 }));
}

export function readJira(activeKeys = [], { readPage = readJiraPage } = {}) {
  const rows = [];
  const errors = [];
  for (const args of jiraQueries(activeKeys)) {
    let nextPageToken;
    const seen = new Set();
    try {
      for (let pageNumber = 0; ; pageNumber++) {
        if (pageNumber >= MAX_JIRA_PAGES) throw new Error('Jira page budget exhausted');
        const jql = args.includes('--jql') ? args[args.indexOf('--jql') + 1] : undefined;
        const page = readPage({ jql, limit: JIRA_PAGE, nextPageToken });
        if (!Array.isArray(page.issues)) throw new Error('invalid Jira page');
        for (const issue of page.issues) {
          const status = issue.fields?.status;
          if (!TICKET_KEY_RE.test(issue.key) || !status?.name) {
            errors.push(`invalid Jira observation: ${issue.key ?? 'missing key'}`);
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
      errors.push(err.message);
    }
  }
  return { rows, errors };
}

function discoverPRs() {
  return JSON.parse(execFileSync('gh', ['pr', 'list', '--state', 'all', '--limit', '100', '--json', 'number,state,headRefName,title,mergeable,mergeStateStatus,statusCheckRollup'], { encoding: 'utf8', timeout: 60000 }));
}

export function readPRBatch(numbers, run = execFileSync) {
  const { nameWithOwner } = JSON.parse(run('gh', ['repo', 'view', '--json', 'nameWithOwner'], { encoding: 'utf8', timeout: 60000 }));
  const [owner, name] = nameWithOwner.split('/');
  const fields = `number state headRefName title mergeable mergeStateStatus
    commits(last:1) { nodes { commit { statusCheckRollup { contexts(first:100) {
      nodes { ... on CheckRun { status conclusion } ... on StatusContext { state } }
      pageInfo { hasNextPage }
    } } } } }`;
  const query = `query($owner:String!,$name:String!) { repository(owner:$owner,name:$name) {
    ${numbers.map((n) => `p${n}: pullRequest(number:${n}) { ${fields} }`).join('\n')}
  } }`;
  const response = JSON.parse(run('gh', ['api', 'graphql', '-f', `query=${query}`, '-f', `owner=${owner}`, '-f', `name=${name}`], { encoding: 'utf8', timeout: 60000 }));
  const rows = [];
  const errors = (response.errors ?? []).map((e) => e.message);
  for (const n of numbers) {
    const pr = response.data?.repository?.[`p${n}`];
    if (!pr) { errors.push(`missing PR #${n}`); continue; }
    const contexts = pr.commits?.nodes?.[0]?.commit?.statusCheckRollup?.contexts;
    if (contexts?.pageInfo?.hasNextPage) {
      errors.push(`PR #${n}: incomplete check rollup`);
      delete pr.mergeable; // preserve the last obligation when checks are unknown
    } else {
      pr.statusCheckRollup = contexts?.nodes ?? [];
    }
    rows.push(pr);
  }
  return { rows, errors };
}

export function readPRs(activeNumbers = [], { discover = discoverPRs, readBatch = readPRBatch } = {}) {
  const rows = [];
  const errors = [];
  try { rows.push(...discover()); } catch (err) { errors.push(err.message); }
  const found = new Set(rows.map((pr) => pr.number));
  const missing = [...new Set(activeNumbers)].filter((n) => Number.isSafeInteger(n) && n > 0 && !found.has(n));
  for (const batch of chunks(missing, PR_BATCH)) {
    try {
      const result = readBatch(batch);
      rows.push(...(Array.isArray(result) ? result : result.rows));
      errors.push(...(result.errors ?? []));
    } catch (err) { errors.push(err.message); }
  }
  return { rows, errors };
}

function readWorktrees() {
  return execFileSync('git', ['worktree', 'list', '--porcelain'], { encoding: 'utf8', timeout: 10000 });
}

// ---------------------------------------------------------------------------
// collectAll — wiring (exported for testing with injected readers)
// ---------------------------------------------------------------------------

function collectPass(now, readers, activeKeys = [], activePRs = []) {
  const health = {};
  const read = (source, fn, fallback) => {
    try {
      const value = fn();
      const result = Array.isArray(value) || typeof value === 'string' ? { rows: value, errors: [] } : value;
      health[source] = [...result.errors];
      return result.rows;
    } catch (err) {
      health[source] = [err.message];
      return fallback;
    }
  };
  const prList = read('pr', () => readers.readPRs(activePRs), [])
    .filter((pr) => {
      if (Number.isSafeInteger(pr?.number) && ['OPEN', 'CLOSED', 'MERGED'].includes(pr.state?.toUpperCase())) return true;
      health.pr.push(`invalid PR observation: ${pr?.number ?? 'missing number'}`);
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
    health.jira.push(`invalid Jira observation: ${row?.key ?? 'missing key'}`);
    return false;
  });
  const jira = jiraRecords(jiraRows, now);
  const prs = prRecords(prList, now);
  const observedKeys = new Set(jiraRows.map((row) => row.key));
  const observedPRs = new Set(prList.map((pr) => pr.number));
  for (const key of allKeys) if (!observedKeys.has(key)) health.jira.push(`missing ticket ${key}`);
  for (const n of activePRs) if (!observedPRs.has(n)) health.pr.push(`missing PR #${n}`);
  return { records: [...jira, ...prs, ...git], health };
}

export function collectAll(now, readers = { readJira, readPRs, readWorktrees }, activeKeys = []) {
  return collectPass(now, readers, activeKeys).records;
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

export function main(argv, { readers } = {}) {
  const a = parseArgs(argv);
  if (!a.ledger) throw new UsageError('--ledger <path> is required');
  const now = a.now ?? new Date().toISOString();
  const effectiveReaders = readers ?? { readJira, readPRs, readWorktrees };

  // An unreadable ledger cannot establish the identities needing reconciliation.
  // Refuse the refresh rather than silently certifying an empty active set.
  const active = inFlight(fold(readRecords(a.ledger)));
  const activeKeys = active.filter((it) => it.kind === 'ticket' && TICKET_KEY_RE.test(it.key)).map((it) => it.key);
  const activePRs = active.filter((it) => it.kind === 'pr' && /^#\d+$/.test(it.key)).map((it) => Number(it.key.slice(1)));
  const { records, health } = collectPass(now, effectiveReaders, activeKeys, activePRs);
  for (const record of records) {
    const validation = validateRecord(record);
    if (!validation.ok) health[record.source].push(validation.error);
  }
  const evidence = Object.entries(health).map(([source, errors]) => ({
    ts: now, source, key: `@collect:${source}`, kind: 'collection', errors,
    ...(!errors.length ? { observed_at: now } : {}),
  }));
  const r = appendRecords(a.ledger, [...records, ...evidence]);
  const summary = `appended=${r.appended - evidence.length} dropped=${r.dropped}`;
  if (r.dropped > 0) {
    console.error('[where-are-we] dropped records:', r.dropReasons);
  }
  if (a.marker && !r.dropped && Object.values(health).every((errors) => !errors.length)) {
    writeFileSync(a.marker, now + '\n');
    const time = new Date(now);
    utimesSync(a.marker, time, time);
  }
  return summary;
}

// ---------------------------------------------------------------------------
// CLI entry
// ---------------------------------------------------------------------------

if (isMain(import.meta.url)) {
  try {
    console.log(main(process.argv.slice(2)));
  } catch (e) {
    // Clean message for UsageError, full stack otherwise (rationale: lib/errors.mjs).
    console.error(e instanceof UsageError ? e.message : (e.stack || String(e)));
    process.exit(1);
  }
}
