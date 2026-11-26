import type { Command } from 'commander';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, readdirSync, renameSync, unlinkSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import { request, projectKey } from '../client.js';
import { adfToPlainText } from '../adf-render.js';
import type { ADFDocument } from '../adf-render.js';
import { fetchAllComments } from './comments.js';
import type { JiraCommentEntry } from './comments.js';
import { sectorField, sectorOf } from './sector.js';
import { CURSOR_FILE, mirrorState, readCursor } from '../mirror-cursor.js';

// Jira -> markdown mirror: one <KEY>.md per issue under a root
// outside any repo/vault, plus a qmd collection over it. Read-only against Jira.

const PAGE_MAX = 100;
const OVERLAP_MINUTES = 10;
const COLLECTION = 'jira-himmel';
const DELETE_SAFETY_RATIO = 0.5;
const BASE_FIELDS =
  'summary,status,issuetype,priority,labels,fixVersions,parent,created,updated,resolution,resolutiondate,issuelinks,description,comment';
const fieldList = (): string => BASE_FIELDS + (sectorField() ? `,${sectorField()}` : '');

interface Named { name?: string; displayName?: string }
export interface MirrorIssue {
  key: string;
  fields: {
    summary?: string;
    status?: { name?: string; statusCategory?: { name?: string } };
    issuetype?: Named;
    priority?: Named | null;
    labels?: string[];
    fixVersions?: Named[];
    parent?: { key?: string } | null;
    created?: string;
    updated?: string;
    resolution?: Named | null;
    resolutiondate?: string | null;
    issuelinks?: Array<{
      type?: { inward?: string; outward?: string };
      inwardIssue?: { key: string };
      outwardIssue?: { key: string };
    }>;
    description?: ADFDocument | null;
    comment?: { comments?: JiraCommentEntry[]; total?: number };
  };
}

interface SearchPage { issues: MirrorIssue[]; nextPageToken?: string }
export type Req = typeof request;

export interface MirrorOptions {
  root: string;
  project: string;
  full?: boolean;
  incrementalOnly?: boolean;
  concurrency?: number;
  now?: () => Date;
  warn?: (msg: string) => void;
}

export interface MirrorResult {
  mode: 'full' | 'incremental';
  fetched: number;
  written: number;
  unchanged: number;
  deleted: number;
  deleteSkipped: string | null;
  mirrorCount: number;
  jiraTotal: number | null;
  refused?: string;
}

// Mirror files must never carry emails; ADF mentions/pasted text can.
const EMAIL_RE = /[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+/g;
export const scrubEmails = (s: string): string => s.replace(EMAIL_RE, '[email]');

const q = (v: string | null | undefined): string => JSON.stringify(v == null ? null : scrubEmails(v));
const list = (v: string[]): string => JSON.stringify(v.map(scrubEmails));

function linkGroups(issue: MirrorIssue): { blocks: string[]; blocked_by: string[]; relates: string[] } {
  const g = { blocks: [] as string[], blocked_by: [] as string[], relates: [] as string[] };
  for (const l of issue.fields.issuelinks ?? []) {
    const other = l.outwardIssue ?? l.inwardIssue;
    if (!other) continue;
    const phrase = (l.outwardIssue ? l.type?.outward : l.type?.inward) ?? '';
    if (l.outwardIssue && /^blocks$/i.test(phrase)) g.blocks.push(other.key);
    else if (l.inwardIssue && /^is blocked by$/i.test(phrase)) g.blocked_by.push(other.key);
    else g.relates.push(phrase ? `${phrase} ${other.key}` : other.key);
  }
  return g;
}

export function renderIssue(issue: MirrorIssue, comments: JiraCommentEntry[]): string {
  const f = issue.fields;
  const links = linkGroups(issue);
  const fm = [
    '---',
    `key: ${q(issue.key)}`,
    `type: ${q(f.issuetype?.name)}`,
    `status: ${q(f.status?.name)}`,
    `statusCategory: ${q(f.status?.statusCategory?.name)}`,
    `priority: ${q(f.priority?.name)}`,
    `labels: ${list(f.labels ?? [])}`,
    `fixVersions: ${list((f.fixVersions ?? []).map((v) => v.name ?? ''))}`,
    `parent: ${q(f.parent?.key)}`,
    `created: ${q(f.created)}`,
    `updated: ${q(f.updated)}`,
    `resolution: ${q(f.resolution?.name)}`,
    `resolved: ${q(f.resolutiondate)}`,
    ...(sectorField() ? [`sector: ${q(sectorOf(f as Record<string, unknown>))}`] : []),
    'links:',
    `  blocks: ${list(links.blocks)}`,
    `  blocked_by: ${list(links.blocked_by)}`,
    `  relates: ${list(links.relates)}`,
    '---',
    '',
  ];
  const body = [`# ${issue.key}: ${scrubEmails(f.summary ?? '')}`, '', '## Description', ''];
  body.push(scrubEmails(adfToPlainText(f.description)) || '_(none)_', '');
  const sorted = [...comments].sort((a, b) => a.created.localeCompare(b.created));
  body.push('## Comments', '');
  if (sorted.length === 0) body.push('_(none)_', '');
  for (const c of sorted) {
    body.push(`### ${scrubEmails(c.author?.displayName ?? 'unknown')} — ${c.created}`, '');
    body.push(scrubEmails(adfToPlainText(c.body)), '');
  }
  return [...fm, ...body].join('\n');
}

export const defaultRoot = (project: string): string => join(homedir(), '.himmel', 'state', 'jira-mirror', project);

function writeFileAtomic(path: string, content: string): void {
  const tmp = `${path}.${process.pid}.tmp`;
  writeFileSync(tmp, content);
  renameSync(tmp, path);
}

async function searchPages(
  jql: string,
  fields: string,
  req: Req,
  onPage: (issues: MirrorIssue[]) => Promise<void> | void,
): Promise<void> {
  let token: string | undefined;
  const seen = new Set<string>();
  do {
    if (token !== undefined) {
      if (seen.has(token)) throw new Error(`jira mirror: pagination loop detected — nextPageToken "${token}" repeated`);
      seen.add(token);
    }
    const cursor = token === undefined ? '' : `&nextPageToken=${encodeURIComponent(token)}`;
    const page = await req<SearchPage>(
      'GET',
      `/search/jql?jql=${encodeURIComponent(jql)}&fields=${fields}&maxResults=${PAGE_MAX}${cursor}`,
    );
    await onPage(page.issues);
    token = page.nextPageToken;
  } while (token !== undefined);
}

async function inChunks<T>(items: T[], size: number, fn: (t: T) => Promise<void>): Promise<void> {
  for (let i = 0; i < items.length; i += size) await Promise.all(items.slice(i, i + size).map(fn));
}

const localKeys = (root: string, project?: string): string[] =>
  existsSync(root)
    ? readdirSync(root)
        .filter((n) => /^[A-Z][A-Z0-9_]*-\d+\.md$/.test(n) && (!project || n.startsWith(`${project}-`)))
        .map((n) => n.slice(0, -3))
    : [];

// The approximate count can lag a little; a listing this far short of it is truncated, not current.
const COUNT_TOLERANCE = 0.98;
export const FILL_MAX = 50;

export async function runMirror(opts: MirrorOptions, req: Req): Promise<MirrorResult> {
  const { root, project } = opts;
  const now = opts.now ?? (() => new Date());
  const warn = opts.warn ?? ((m: string) => process.stderr.write(`jira mirror: ${m}\n`));
  const startedAt = now();

  const state = mirrorState(root, project);
  if (opts.incrementalOnly) {
    const why =
      state.complete === 'none' ? `no cursor at ${root}; a full backfill is needed`
      : state.project !== null && state.project !== project ? `the cursor is for ${state.project}`
      : state.complete === 'yes' ? 'not needed'
      : !state.repairable ? 'a full backfill is needed'
      : null;
    if (why) {
      return { mode: 'incremental', fetched: 0, written: 0, unchanged: 0, deleted: 0, deleteSkipped: null, mirrorCount: 0, jiraTotal: null, refused: why };
    }
  }
  mkdirSync(root, { recursive: true });

  const lastSync = (!opts.full || opts.incrementalOnly) && state.next === 'incremental' ? state.lastSync : null;
  const mode = lastSync ? 'incremental' : 'full';
  let jql = `project = ${project} ORDER BY key ASC`;
  if (lastSync) {
    // Relative JQL ("-Nm") is timezone-independent, unlike an absolute datetime.
    const mins = Math.max(1, Math.ceil((startedAt.getTime() - Date.parse(lastSync)) / 60000)) + OVERLAP_MINUTES;
    jql = `project = ${project} AND updated >= "-${mins}m" ORDER BY updated ASC`;
  }

  const res: MirrorResult = {
    mode, fetched: 0, written: 0, unchanged: 0, deleted: 0, deleteSkipped: null, mirrorCount: 0, jiraTotal: null,
  };
  const fullKeys = new Set<string>();
  const chunk = Math.max(1, Math.floor(opts.concurrency || 5));

  const writeIssue = async (issue: MirrorIssue): Promise<void> => {
    res.fetched++;
    const c = issue.fields.comment;
    const embedded = c?.comments ?? [];
    const comments =
      (c?.total ?? 0) === 0 ? [] : embedded.length >= (c?.total ?? 0) ? embedded : await fetchAllComments(issue.key, req);
    const md = renderIssue(issue, comments);
    const path = join(root, `${issue.key}.md`);
    if (existsSync(path) && readFileSync(path, 'utf8') === md) res.unchanged++;
    else {
      writeFileAtomic(path, md);
      res.written++;
    }
  };

  await searchPages(jql, fieldList(), req, async (issues) => {
    await inChunks(issues, chunk, async (issue) => {
      fullKeys.add(issue.key);
      await writeIssue(issue);
    });
  });

  // Delete/move detection: authoritative key list. Fails SAFE. An error or a
  // suspiciously short list deletes nothing.
  const local = localKeys(root, project);
  try {
    const { count } = await req<{ count: number }>('POST', '/search/approximate-count', { jql: `project = ${project}` });
    res.jiraTotal = typeof count === 'number' ? count : null;
  } catch {
    res.jiraTotal = null;
  }
  let live: Set<string> | null = null;
  let listing: Set<string> | null = null;
  if (mode === 'full') live = listing = fullKeys;
  else {
    try {
      const keys = new Set<string>();
      await searchPages(`project = ${project} ORDER BY key ASC`, 'key', req, (is) => {
        for (const i of is) keys.add(i.key);
      });
      live = listing = keys;
    } catch (err) {
      res.deleteSkipped = `key listing failed: ${err instanceof Error ? err.message : String(err)}`;
    }
  }
  if (live && local.length > 0 && live.size < local.length * DELETE_SAFETY_RATIO) {
    res.deleteSkipped = `key listing returned ${live.size} of ${local.length} local files (< ${DELETE_SAFETY_RATIO * 100}%)`;
    live = null;
  }
  if (live && (res.jiraTotal === null || live.size < res.jiraTotal * COUNT_TOLERANCE)) {
    res.deleteSkipped = res.jiraTotal === null ? 'Jira count unavailable' : `key listing returned ${live.size} but Jira counts ${res.jiraTotal}`;
    live = null;
  }
  if (res.deleteSkipped) warn(`delete pass skipped — ${res.deleteSkipped}`);
  if (live) {
    for (const k of local) {
      if (!live.has(k)) {
        unlinkSync(join(root, `${k}.md`));
        res.deleted++;
      }
    }
  }

  const localNow = new Set(localKeys(root, project));
  let residual = listing ? [...listing].filter((k) => !localNow.has(k)).sort() : [];
  if (residual.length > 0 && residual.length <= FILL_MAX) {
    const filled: string[] = [];
    await inChunks(residual, chunk, async (key) => {
      let got: MirrorIssue;
      try {
        got = await req<MirrorIssue>('GET', `/issue/${key}?fields=${fieldList()}`);
      } catch {
        return;
      }
      if (got.key !== key) {
        warn(`fill: ${key} answered as ${got.key}; left missing`);
        return;
      }
      await writeIssue(got);
      filled.push(key);
    });
    if (filled.length > 0) warn(`filled ${filled.length} live key(s) missing locally: ${filled.sort().join(', ')}`);
    residual = residual.filter((k) => !filled.includes(k));
  }
  res.mirrorCount = localKeys(root, project).length;
  // A live key with no local file (within the count tolerance) also forces a full run.
  if (!res.deleteSkipped && live && residual.length > 0) res.deleteSkipped = 'live keys missing locally';
  if (res.deleteSkipped || (res.jiraTotal !== null && res.mirrorCount < res.jiraTotal * COUNT_TOLERANCE)) {
    const total = res.jiraTotal;
    const gap = total === null ? 0 : total - res.mirrorCount;
    const repair: 'full' | 'incremental' =
      mode === 'full' && total !== null && fullKeys.size < total * COUNT_TOLERANCE ? 'full'
      : listing ? (residual.length > FILL_MAX ? 'full' : 'incremental')
      : gap > Math.max(FILL_MAX, Math.ceil((total ?? 0) * (1 - COUNT_TOLERANCE))) ? 'full' : 'incremental';
    warn(`mirror not verified complete (${res.deleteSkipped ?? `holds ${res.mirrorCount}, Jira counts ${res.jiraTotal}`}); next sync runs ${repair === 'full' ? 'full' : 'an incremental repair'}`);
    writeFileAtomic(
      join(root, CURSOR_FILE),
      JSON.stringify({ lastSync: startedAt.toISOString(), total: res.mirrorCount, project, complete: false, repair }) + '\n',
    );
    return res;
  }
  writeFileAtomic(
    join(root, CURSOR_FILE),
    JSON.stringify({ lastSync: startedAt.toISOString(), total: res.mirrorCount, project }) + '\n',
  );
  return res;
}

export function mirrorAgeMinutes(root: string, now: Date = new Date()): number | null {
  const c = readCursor(root);
  return c ? Math.floor((now.getTime() - Date.parse(c.lastSync)) / 60000) : null;
}

// qmd registration + re-embed. Never throws: the sync has already succeeded.
export function qmdRefresh(root: string, run: (args: string[]) => string = (a) => execFileSync('qmd', a, { encoding: 'utf8' })): string {
  try {
    if (!run(['collection', 'list']).includes(`${COLLECTION} (`)) {
      run(['collection', 'add', root, '--name', COLLECTION]);
    } else {
      const path = /^\s*Path:\s*(.+)$/m.exec(run(['collection', 'show', COLLECTION]))?.[1]?.trim();
      if (!path || resolve(path) !== resolve(root)) throw new Error(`collection ${COLLECTION} points at ${path ?? 'an unknown path'}, not ${root}`);
    }
    run(['update', '-c', COLLECTION]);
    run(['embed', '-c', COLLECTION]);
    return `qmd: collection ${COLLECTION} updated and embedded`;
  } catch (err) {
    return `qmd: refresh FAILED (${err instanceof Error ? err.message.split('\n')[0] : String(err)}); the mirror sync itself succeeded`;
  }
}

export function registerMirror(program: Command, req: Req = request): void {
  program
    .command('mirror')
    .description('Mirror Jira issues to markdown files (full backfill, then incremental) for qmd retrieval; read-only against Jira')
    .option('--root <dir>', 'Mirror root (default: ~/.himmel/state/jira-mirror/<PROJECT>)')
    .option('--full', 'Ignore the cursor and re-fetch everything')
    .option('--status', 'Print mirror age and file count, then exit (no network)')
    .option('--json', 'With --status: print one JSON object (the cursor state: complete, repair, lastSync, project, next, repairable)')
    .option('--repair', 'Run an incremental repair when the cursor says one is due; never a full backfill (exit 3 when it cannot)')
    .option('--qmd', `Register the ${COLLECTION} qmd collection if missing, then qmd update + embed (failure is reported, not fatal)`)
    .action(async (options: { root?: string; full?: boolean; status?: boolean; json?: boolean; repair?: boolean; qmd?: boolean }) => {
      const project = projectKey();
      const root = options.root ?? defaultRoot(project);
      if (options.status) {
        const age = mirrorAgeMinutes(root);
        if (options.json) {
          console.log(JSON.stringify({ root, files: localKeys(root).length, age_minutes: age, ...mirrorState(root, project) }));
        } else {
          console.log(`mirror root=${root} files=${localKeys(root).length} age_minutes=${age ?? 'never-synced'}`);
        }
        return;
      }
      const r = await runMirror({ root, project, full: options.full, incrementalOnly: options.repair }, req);
      if (r.refused !== undefined) {
        console.log(`repair: ${r.refused}`);
        if (r.refused !== 'not needed') process.exitCode = 3;
        return;
      }
      console.log(
        `mirror ${r.mode}: fetched=${r.fetched} written=${r.written} unchanged=${r.unchanged} deleted=${r.deleted}\n` +
          `mirror count=${r.mirrorCount} jira total=${r.jiraTotal ?? 'unknown'}`,
      );
      if (options.qmd) console.log(qmdRefresh(root));
    });
}
