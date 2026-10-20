import type { Command } from 'commander';
import { execFileSync } from 'node:child_process';
import { request, projectKey } from '../client.js';
import { searchAllIssues } from './list.js';
import { fetchVersions, checkDate } from './versions.js';
import { appendAdmission, readAdmissions } from './admissions-ledger.js';
import type { JiraIssue } from '../types.js';

// A version's scope is frozen by two description lines, `frozen: <date>` and
// `frozen-keys: A,B`; the open set also carries label `scope-<v>`. version-ready
// prints the P1 tag criterion as PASS/FAIL rows and refuses nothing: the
// console reads the rows and decides, and may overrule a FAIL with a reason
// that lands in the admissions ledger.

type Issue = JiraIssue & {
  fields: JiraIssue['fields'] & { labels?: string[]; status: { name: string; statusCategory?: { key?: string } } };
};

const FROZEN_LINE = /^\s*frozen:\s*(\d{4}-\d{2}-\d{2})\s*$/m;
const KEYS_LINE = /^\s*frozen-keys:\s*(.*?)\s*$/m;
const SEARCH_LIMIT = '5000';
const TIME_BOX_DAYS = 3;

export function parseFrozen(description: string | undefined): { date: string; keys: string[] } | undefined {
  const date = FROZEN_LINE.exec(description ?? '')?.[1];
  if (date === undefined) return undefined;
  const raw = KEYS_LINE.exec(description ?? '')?.[1] ?? '';
  return { date, keys: raw.split(',').map((k) => k.trim()).filter((k) => k.length > 0) };
}

// A leg (and a relay) is console-spawned and carries these markers, as
// go.sh and bulk-call.sh refuse on; the console and operator sessions do not.
export function hasConsoleMarker(): boolean {
  return !process.env.HIMMEL_CONSOLE_LEG && !process.env.HIMMEL_CONSOLE_RELAY;
}

const actor = (): string => process.env.HIMMEL_CONSOLE_NAME || 'console';

export interface CiResult {
  ok: boolean;
  detail: string;
}

export function mainCiGreen(sha?: string): CiResult {
  try {
    const runs = JSON.parse(
      execFileSync('gh', ['run', 'list', '--branch', 'main', '--limit', '30', '--json', 'conclusion,headSha,workflowName'], {
        encoding: 'utf8',
      }),
    ) as Array<{ conclusion: string; headSha: string; workflowName: string }>;
    const head = sha ?? runs[0]?.headSha;
    const mine = runs.filter((r) => head !== undefined && r.headSha.startsWith(head));
    if (mine.length === 0) return { ok: false, detail: `no CI run found for ${head ?? 'main'}` };
    const bad = mine.filter((r) => r.conclusion !== 'success' && r.conclusion !== 'skipped');
    return bad.length === 0
      ? { ok: true, detail: `${mine.length} run(s) green at ${head?.slice(0, 9)}` }
      : { ok: false, detail: `not green at ${head?.slice(0, 9)}: ${bad.map((r) => `${r.workflowName}=${r.conclusion || 'pending'}`).join(', ')}` };
  } catch (e) {
    return { ok: false, detail: `could not read main CI: ${(e as Error).message.split('\n')[0]}` };
  }
}

// Swapped by tests; the CLI never touches it.
export const probes = { mainCi: mainCiGreen };

async function findVersion(project: string, name: string) {
  const found = (await fetchVersions(project)).find((v) => v.name === name);
  if (!found) throw new Error(`no version named "${name}" in project ${project}`);
  return found;
}

const addLabel = (key: string, label: string) =>
  request('PUT', `/issue/${key}`, { update: { labels: [{ add: label }] } });

const inKeys = (keys: string[]) => `key in (${keys.join(',')})`;

export async function freezeVersion(
  project: string,
  name: string,
  opts: { date?: string; dryRun?: boolean },
): Promise<string> {
  const version = await findVersion(project, name);
  const existing = parseFrozen(version.description);
  if (existing) throw new Error(`version "${name}" is already frozen (frozen: ${existing.date})`);
  const date = opts.date !== undefined ? checkDate(opts.date, '--date') : new Date().toISOString().slice(0, 10);
  const open = (await searchAllIssues(
    `project=${project} AND fixVersion="${name}" AND statusCategory != Done ORDER BY key`,
    SEARCH_LIMIT,
    request,
    true,
  )) as Issue[];
  const keys = open.map((i) => i.key);
  const block = `frozen: ${date}\nfrozen-keys: ${keys.join(',')}`;
  const base = (version.description ?? '').trimEnd();
  const description = base === '' ? block : `${base}\n${block}`;
  if (opts.dryRun) return `Would freeze ${name} on ${date}: ${keys.length} open ticket(s) labelled scope-${name}\n${keys.join(',')}`;
  await request('PUT', `/version/${version.id}`, { description });
  for (const key of keys) await addLabel(key, `scope-${name}`);
  return `Froze ${name} on ${date}: ${keys.length} open ticket(s) labelled scope-${name}`;
}

interface Row {
  id: string;
  ok: boolean;
  detail: string;
}

const list = (keys: string[]) => keys.join(',');

async function readinessRows(project: string, name: string, description: string | undefined): Promise<Row[]> {
  const frozen = parseFrozen(description);
  const rows: Row[] = [];
  if (!frozen) {
    rows.push({ id: 'frozen-set', ok: false, detail: `${name} is not frozen (no frozen: line in its description)` });
  } else {
    const issues = frozen.keys.length === 0 ? [] : ((await searchAllIssues(inKeys(frozen.keys), SEARCH_LIMIT, request, true)) as Issue[]);
    const deferred = (i: Issue) => (i.fields.labels ?? []).includes('deferred');
    const done = (i: Issue) => i.fields.status.statusCategory?.key === 'done';
    const open = issues.filter((i) => !done(i) && !deferred(i)).map((i) => i.key);
    rows.push({
      id: 'frozen-set',
      ok: open.length === 0,
      detail: open.length === 0 ? `${frozen.keys.length} frozen, all Done or deferred` : `open: ${list(open)}`,
    });
  }
  const blockers = await searchAllIssues(
    `project=${project} AND fixVersion="${name}" AND issuetype=Bug AND statusCategory != Done AND (priority = Highest OR labels in (critical, blocker))`,
    SEARCH_LIMIT,
    request,
  );
  rows.push({
    id: 'no-blocker-bug',
    ok: blockers.length === 0,
    detail: blockers.length === 0 ? 'no open Critical/Blocker/Highest bug' : `open: ${list(blockers.map((i) => i.key))}`,
  });
  const ci = probes.mainCi();
  rows.push({ id: 'main-ci', ok: ci.ok, detail: ci.detail });
  // The Done-fold stamps each Done ticket with the version; a Done frozen key
  // that lacks it means the fold has not run for the range.
  const unfolded =
    frozen && frozen.keys.length > 0
      ? await searchAllIssues(`${inKeys(frozen.keys)} AND statusCategory = Done AND fixVersion != "${name}"`, SEARCH_LIMIT, request)
      : [];
  rows.push({
    id: 'done-fold',
    ok: frozen !== undefined && unfolded.length === 0,
    detail: !frozen
      ? 'nothing to check: not frozen'
      : unfolded.length === 0
        ? 'every Done frozen key carries the version'
        : `not folded: ${list(unfolded.map((i) => i.key))}`,
  });
  return rows;
}

export async function versionReady(
  project: string,
  name: string,
  opts: { consoleOverride?: string },
): Promise<string[]> {
  const version = await findVersion(project, name);
  const frozen = parseFrozen(version.description);
  const checked = await readinessRows(project, name, version.description);
  let rows = checked;
  const lines: string[] = [];
  const reason = opts.consoleOverride?.trim();
  if (opts.consoleOverride !== undefined) {
    if (!hasConsoleMarker()) lines.push('console-override ignored: no console marker (a leg cannot overrule a check)');
    else if (!reason) lines.push('console-override ignored: a reason is mandatory');
    else {
      rows = rows.map((r) => {
        if (r.ok) return r;
        appendAdmission({ ts: new Date().toISOString(), version: name, key: r.id, kind: 'override', actor: actor(), reason });
        return { id: r.id, ok: true, detail: `overridden: ${reason} (was: ${r.detail})` };
      });
    }
  }
  const out = rows.map((r) => `${r.ok ? 'PASS' : 'FAIL'}\t${r.id}\t${r.detail}`);
  out.push(...lines);
  const ledger = readAdmissions(name);
  if (frozen) {
    const roll = new Date(Date.parse(frozen.date) + TIME_BOX_DAYS * 86_400_000).toISOString().slice(0, 10);
    const frozenRow = checked.find((r) => r.id === 'frozen-set');
    const openCount = frozenRow && !frozenRow.ok ? (/open: (.*)$/.exec(frozenRow.detail)?.[1] ?? '').split(',').filter(Boolean).length : 0;
    const admitted = ledger.filter((l) => l.kind === undefined && l.ts.slice(0, 10) >= frozen.date).length;
    out.push(`frozen-open: ${openCount}`, `admitted-after-freeze: ${admitted}`, `time-box: console rolls the remainder at ${roll} (freeze + 72 h)`);
  }
  for (const l of ledger.filter((x) => x.kind !== undefined)) {
    out.push(`${l.kind}\t${l.key}\t${l.reason ?? ''} (${l.actor}, ${l.ts})`);
  }
  return out;
}

export async function deferTicket(key: string, version: string, reason: string | undefined): Promise<string> {
  if (!hasConsoleMarker()) throw new Error('version-defer needs the console marker: only the console defers a frozen ticket');
  if (!reason?.trim()) throw new Error('version-defer: --reason is mandatory');
  await addLabel(key, 'deferred');
  appendAdmission({ ts: new Date().toISOString(), version, key, kind: 'deferral', actor: actor(), reason: reason.trim() });
  return `${key} deferred from ${version}: ${reason.trim()}`;
}

export function registerVersionFreeze(program: Command): void {
  program
    .command('version-freeze <name>')
    .description('Freeze a version: write frozen: <date> and the open key list into its description, label the set scope-<name>')
    .option('--project <key>', 'Project key (default: JIRA_PROJECT_KEY env var)')
    .option('--date <date>', 'Freeze date, YYYY-MM-DD (default: today)')
    .option('--dry-run', 'Print the plan, write nothing')
    .action(async (name: string, options: { project?: string; date?: string; dryRun?: boolean }) => {
      console.log(await freezeVersion(options.project ?? projectKey(), name, options));
    });

  program
    .command('version-ready <name>')
    .description('Print the P1 tag criterion for a frozen version as PASS/FAIL rows (informational; refuses nothing)')
    .option('--project <key>', 'Project key (default: JIRA_PROJECT_KEY env var)')
    .option('--console-override <reason>', 'Console only: turn every FAIL row into an overridden PASS, recording the reason in the admissions ledger')
    .action(async (name: string, options: { project?: string; consoleOverride?: string }) => {
      for (const line of await versionReady(options.project ?? projectKey(), name, options)) console.log(line);
    });

  program
    .command('version-defer <key>')
    .description('Console only: defer a frozen ticket (label deferred) and record the reason in the admissions ledger')
    .requiredOption('--version <name>', 'The frozen version the ticket is deferred from')
    .option('--reason <text>', 'Why (mandatory)')
    .action(async (key: string, options: { version: string; reason?: string }) => {
      console.log(await deferTicket(key, options.version, options.reason));
    });
}
