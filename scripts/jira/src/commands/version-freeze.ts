import type { Command } from 'commander';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { request, projectKey } from '../client.js';
import { searchAllIssues } from './list.js';
import { fetchVersions, checkDate } from './versions.js';
import { appendAdmission, readAdmissions, type Admission } from './admissions-ledger.js';
import type { JiraIssue } from '../types.js';

// A version's scope is frozen by two description lines, `frozen: <date>` and
// `frozen-keys: A,B`; the open set also carries label `scope-<v>`. version-ready
// prints the P1 tag criterion as PASS/FAIL rows and refuses nothing: the
// console reads the rows and decides, and may overrule a FAIL row with a
// reason that lands in the admissions ledger. A key in the version that is not
// in the frozen list was admitted after the freeze and needs a ledger row.

type Issue = JiraIssue & {
  fields: JiraIssue['fields'] & { labels?: string[]; status: { name: string; statusCategory?: { key?: string } } };
};

const FROZEN_LINE = /^\s*frozen:\s*(\d{4}-\d{2}-\d{2})\s*$/m;
const KEYS_LINE = /^\s*frozen-keys:\s*(.*?)\s*$/m;
const SEARCH_LIMIT = '5000';
const KEY = /^[A-Z][A-Z0-9]*-\d+$/;

export function parseFrozen(description: string | undefined): { date: string; keys: string[] } | undefined {
  const date = FROZEN_LINE.exec(description ?? '')?.[1];
  if (date === undefined) return undefined;
  const raw = KEYS_LINE.exec(description ?? '')?.[1] ?? '';
  return { date, keys: raw.split(',').map((k) => k.trim()).filter((k) => k.length > 0) };
}

// Same marker as `create --console-override`.
// ponytail: any same-uid caller can set HIMMEL_CONSOLE, upgrade path: the RM signed-row design (HIMMEL-6796)
export function hasConsoleMarker(): boolean {
  return process.env.HIMMEL_CONSOLE === '1';
}

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

function keysFromFile(path: string): string[] {
  const keys = readFileSync(path, 'utf8')
    .split('\n')
    .map((l) => l.trim())
    .filter((l) => l !== '' && !l.startsWith('#'));
  const bad = keys.filter((k) => !KEY.test(k));
  if (bad.length > 0) throw new Error(`--keys-file ${path}: not a ticket key: ${bad.slice(0, 5).join(', ')}`);
  return [...new Set(keys)];
}

export async function freezeVersion(
  project: string,
  name: string,
  opts: { at?: string; keysFile?: string; dryRun?: boolean },
): Promise<string> {
  const version = await findVersion(project, name);
  const existing = parseFrozen(version.description);
  if (existing) throw new Error(`version "${name}" is already frozen (frozen: ${existing.date})`);
  const date = opts.at !== undefined ? checkDate(opts.at, '--at') : new Date().toISOString().slice(0, 10);
  const keys =
    opts.keysFile !== undefined
      ? keysFromFile(opts.keysFile)
      : (
          (await searchAllIssues(
            `project=${project} AND fixVersion="${name}" AND statusCategory != Done ORDER BY key`,
            SEARCH_LIMIT,
            request,
            true,
          )) as Issue[]
        ).map((i) => i.key);
  const block = `frozen: ${date}\nfrozen-keys: ${keys.join(',')}`;
  const base = (version.description ?? '').trimEnd();
  const description = base === '' ? block : `${base}\n${block}`;
  if (opts.dryRun) return `Would freeze ${name} on ${date}: ${keys.length} ticket(s) labelled scope-${name}\n${keys.join(',')}`;
  await request('PUT', `/version/${version.id}`, { description });
  for (const key of keys) await addLabel(key, `scope-${name}`);
  return `Froze ${name} on ${date}: ${keys.length} ticket(s) labelled scope-${name}`;
}

interface Row {
  id: string;
  ok: boolean;
  detail: string;
}

export interface Override {
  id: string;
  reason: string;
}

interface Readiness {
  rows: Row[];
  openCount: number;
  admitted: Array<{ key: string; reason: string; by?: string }>;
  leaks: string[];
  folded: number;
}

const list = (keys: string[]) => keys.join(',');

// A key in the version that is not in the frozen list was admitted after the
// freeze: a ledger row (a gate or console-override filing, or an rm-admit)
// gives it a reason, none makes it a leak. A Done key without a row is a
// Done-fold, not a leak. A row keyed by a check id (a version-ready override)
// is not an admission.
const isAdmission = (l: Admission) => l.kind !== 'deferral' && KEY.test(l.key);

async function readinessRows(
  project: string,
  name: string,
  description: string | undefined,
  ledger: Admission[],
): Promise<Readiness> {
  const frozen = parseFrozen(description);
  const rows: Row[] = [];
  const done = (i: Issue) => i.fields.status.statusCategory?.key === 'done';
  let openCount = 0;
  const admitted: Readiness['admitted'] = [];
  const leaks: string[] = [];
  let folded = 0;
  if (!frozen) {
    rows.push({ id: 'frozen-set', ok: false, detail: `${name} is not frozen (no frozen: line in its description)` });
  } else {
    const issues = frozen.keys.length === 0 ? [] : ((await searchAllIssues(inKeys(frozen.keys), SEARCH_LIMIT, request, true)) as Issue[]);
    const deferred = (i: Issue) => (i.fields.labels ?? []).includes('deferred');
    const open = issues.filter((i) => !done(i) && !deferred(i)).map((i) => i.key);
    openCount = open.length;
    const inVersion = (await searchAllIssues(
      `project=${project} AND fixVersion="${name}"`,
      SEARCH_LIMIT,
      request,
      true,
    )) as Issue[];
    const frozenKeys = new Set(frozen.keys);
    for (const i of inVersion.filter((x) => !frozenKeys.has(x.key))) {
      const record = ledger.find((l) => l.key === i.key && isAdmission(l));
      if (record) admitted.push({ key: i.key, reason: record.reason ?? record.gate ?? '', by: record.by });
      else if (done(i)) folded += 1;
      else leaks.push(i.key);
    }
    const problems = [
      ...(open.length > 0 ? [`open: ${list(open)}`] : []),
      ...(leaks.length > 0 ? [`leak (admitted after freeze, no ledger row): ${list(leaks)}`] : []),
    ];
    rows.push({
      id: 'frozen-set',
      ok: problems.length === 0,
      detail: problems.length === 0 ? `${frozen.keys.length} frozen, all Done or deferred; none admitted without a ledger row` : problems.join('; '),
    });
  }
  const blockers = await searchAllIssues(
    `project=${project} AND fixVersion="${name}" AND issuetype=Bug AND statusCategory != Done AND (priority = Highest OR labels in (critical, blocker, v1-blocker))`,
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
  return { rows, openCount, admitted, leaks, folded };
}

export async function versionReady(
  project: string,
  name: string,
  opts: { consoleOverride?: Override[] },
): Promise<string[]> {
  const version = await findVersion(project, name);
  const frozen = parseFrozen(version.description);
  const ledger = readAdmissions(name);
  const checked = await readinessRows(project, name, version.description, ledger);
  let rows = checked.rows;
  const lines: string[] = [];
  const overrides = opts.consoleOverride ?? [];
  if (overrides.length > 0) {
    if (!hasConsoleMarker()) lines.push('console-override ignored: no console marker (HIMMEL_CONSOLE=1 is not set)');
    else {
      for (const o of overrides) {
        if (!o.reason.trim()) lines.push(`console-override ${o.id} ignored: a reason is mandatory`);
        else if (!rows.some((r) => r.id === o.id)) lines.push(`console-override ${o.id} ignored: no such row`);
      }
      rows = rows.map((r) => {
        const reason = overrides.find((o) => o.id === r.id)?.reason.trim();
        if (r.ok || !reason) return r;
        appendAdmission({ version: name, key: r.id, kind: 'override', reason });
        return { id: r.id, ok: true, detail: `overridden: ${reason} (was: ${r.detail})` };
      });
    }
  }
  const out = rows.map((r) => `${r.ok ? 'PASS' : 'FAIL'}\t${r.id}\t${r.detail}`);
  out.push(...lines);
  if (frozen) {
    out.push(
      `frozen-open: ${checked.openCount}`,
      `admitted-after-freeze: ${checked.admitted.length + checked.leaks.length}`,
      `done-folded: ${checked.folded}`,
    );
    for (const a of checked.admitted) out.push(`admitted\t${a.key}\t${a.reason}${a.by ? `\t${a.by}` : ''}`);
  }
  for (const l of ledger.filter((x) => !isAdmission(x))) {
    out.push(`${l.kind}\t${l.key}\t${l.reason ?? ''} (${l.actor}, ${l.ts})`);
  }
  return out;
}

export async function deferTicket(key: string, version: string, reason: string | undefined): Promise<string> {
  if (!hasConsoleMarker()) throw new Error('version-defer needs the console marker: only the console defers a frozen ticket');
  if (!reason?.trim()) throw new Error('version-defer: --reason is mandatory');
  await addLabel(key, 'deferred');
  appendAdmission({ version, key, kind: 'deferral', reason: reason.trim() });
  return `${key} deferred from ${version}: ${reason.trim()}`;
}

export function admitTicket(key: string, version: string, reason: string | undefined, by: string | undefined): string {
  if (!hasConsoleMarker()) throw new Error('version-admit needs the console marker: only the console records an admission');
  if (!KEY.test(key)) throw new Error(`version-admit: "${key}" is not a ticket key`);
  if (!reason?.trim()) throw new Error('version-admit: --reason is mandatory');
  if (!by?.trim()) throw new Error('version-admit: --by <rm-session> is mandatory');
  appendAdmission({ version, key, kind: 'rm-admit', reason: reason.trim(), by: by.trim() });
  return `${key} admitted to ${version} by ${by.trim()}: ${reason.trim()}`;
}

export function registerVersionFreeze(program: Command): void {
  program
    .command('version-freeze <name>')
    .description('Freeze a version: write frozen: <date> and the key list into its description, label the set scope-<name>')
    .option('--project <key>', 'Project key (default: JIRA_PROJECT_KEY env var)')
    .option('--at <date>', 'Freeze date stamped as frozen:, YYYY-MM-DD (default: today)')
    .option('--keys-file <path>', 'Freeze this list (one key per line) instead of the version\'s open tickets')
    .option('--dry-run', 'Print the plan, write nothing')
    .action(async (name: string, options: { project?: string; at?: string; keysFile?: string; dryRun?: boolean }) => {
      console.log(await freezeVersion(options.project ?? projectKey(), name, options));
    });

  program
    .command('version-ready <name>')
    .description('Print the P1 tag criterion for a frozen version as PASS/FAIL rows (informational; refuses nothing)')
    .option('--project <key>', 'Project key (default: JIRA_PROJECT_KEY env var)')
    .option(
      '--console-override <values...>',
      'Console only (HIMMEL_CONSOLE=1), repeatable, as <row-id> "<reason>": turn one FAIL row into an overridden PASS, recording the reason in the admissions ledger',
    )
    .action(async (name: string, options: { project?: string; consoleOverride?: string[] }) => {
      const flat = options.consoleOverride ?? [];
      if (flat.length % 2 !== 0) throw new Error('--console-override takes <row-id> "<reason>" pairs');
      const consoleOverride: Override[] = [];
      for (let i = 0; i < flat.length; i += 2) consoleOverride.push({ id: flat[i], reason: flat[i + 1] });
      for (const line of await versionReady(options.project ?? projectKey(), name, { consoleOverride })) console.log(line);
    });

  program
    .command('version-admit <key>')
    .description('Console only: record that the release manager admitted a ticket into a frozen version, with a reason, in the admissions ledger')
    .requiredOption('--version <name>', 'The frozen version the ticket was admitted into')
    .option('--reason <text>', 'Why (mandatory)')
    .option('--by <rm-session>', 'The release-manager session that ruled it (mandatory)')
    .action(async (key: string, options: { version: string; reason?: string; by?: string }) => {
      console.log(admitTicket(key, options.version, options.reason, options.by));
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
