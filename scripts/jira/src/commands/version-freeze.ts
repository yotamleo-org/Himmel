import type { Command } from 'commander';
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { request, projectKey } from '../client.js';
import { searchAllIssues } from './list.js';
import { fetchVersions, checkDate, setFixVersion, addFixVersionGated } from './versions.js';
import { appendAdmission, readAdmissions, type Admission } from './admissions-ledger.js';
import { chiefOverrideOf } from './intake-gate.js';
import { releaseRoot } from '../release/paths.js';
import { PLACEHOLDER } from '../release/operator-acts.js';
import type { JiraIssue } from '../types.js';

// A version's scope is frozen by two description lines, `frozen: <date>` and
// `frozen-keys: A,B`; the open set also carries label `scope-<v>`. version-ready
// prints the checks before a cut as PASS/FAIL rows and exits 1 on a FAIL row after
// overrides (a chief overrule needs a reason, which lands in the admissions ledger).
// A key not in the frozen list was admitted after the freeze and needs a ledger row.
// `--out` also writes the file READY row 3 reads.

type Issue = JiraIssue & {
  fields: JiraIssue['fields'] & { labels?: string[]; status: { name: string; statusCategory?: { key?: string } } };
};

const FROZEN_LINE = /^[ \t]*frozen:[ \t]*(\d{4}-\d{2}-\d{2})[ \t]*$/m;
const KEYS_LINE = /^[ \t]*frozen-keys:[ \t]*(.*?)[ \t]*$/m;
const CI_RUN_LIMIT = 200;
const SEARCH_LIMIT = '5000';
const KEY = /^[A-Z][A-Z0-9]*-\d+$/;

export function parseFrozen(description: string | undefined): { date: string; keys: string[] } | undefined {
  const date = FROZEN_LINE.exec(description ?? '')?.[1];
  const raw = KEYS_LINE.exec(description ?? '')?.[1];
  if (date === undefined || raw === undefined) return undefined;
  return { date, keys: raw.split(',').map((k) => k.trim()).filter((k) => k.length > 0) };
}

// Same marker as `create --chief-override`.
export function hasConsoleMarker(): boolean {
  return process.env.HIMMEL_CONSOLE === '1';
}

export interface CiResult {
  ok: boolean;
  detail: string;
}

export function mainCiGreen(sha?: string): CiResult {
  try {
    const head =
      sha ?? execFileSync('gh', ['api', 'repos/{owner}/{repo}/commits/main', '--jq', '.sha'], { encoding: 'utf8' }).trim();
    const runs = JSON.parse(
      execFileSync(
        'gh',
        ['run', 'list', '--branch', 'main', '--commit', head, '--limit', String(CI_RUN_LIMIT), '--json', 'conclusion,headSha,workflowName,number,event'],
        { encoding: 'utf8' },
      ),
    ) as Array<{ conclusion: string; headSha: string; workflowName: string; number?: number; event?: string }>;
    if (runs.length >= CI_RUN_LIMIT) return { ok: false, detail: `${runs.length}+ runs at ${head.slice(0, 9)}: list may be truncated` };
    const mine = runs.filter((r) => r.headSha.startsWith(head));
    if (mine.length === 0) return { ok: false, detail: `no CI run found for ${head}` };
    const newest = new Map<string, (typeof mine)[number]>();
    mine.forEach((r, i) => {
      const group = typeof r.number === 'number' ? `${r.workflowName}\u0000${r.event ?? ''}` : `#${i}`;
      const seen = newest.get(group);
      if (seen === undefined || (r.number ?? 0) > (seen.number ?? 0)) newest.set(group, r);
    });
    const judged = [...newest.values()];
    const bad = judged.filter((r) => r.conclusion !== 'success' && r.conclusion !== 'skipped');
    return bad.length === 0
      ? { ok: true, detail: `${judged.length} workflow(s) green at ${head?.slice(0, 9)}` }
      : { ok: false, detail: `not green at ${head?.slice(0, 9)}: ${bad.map((r) => `${r.workflowName}=${r.conclusion || 'pending'}`).join(', ')}` };
  } catch (e) {
    return { ok: false, detail: `could not read main CI: ${(e as Error).message.split('\n')[0]}` };
  }
}

export interface OwedRow {
  id: string;
  kind: string;
  key?: string;
  actor?: string;
  action?: string;
  text?: string;
}

const OWE_SH = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..', 'handover', 'chief-kit', 'owe.sh');
const OWE_MAX_BUFFER = 256 * 1024 * 1024;

export function owedOpenDefault(bucket: string): OwedRow[] {
  const raw = execFileSync('bash', [OWE_SH, 'list', '--bucket', bucket, '--json'], { encoding: 'utf8', maxBuffer: OWE_MAX_BUFFER });
  const rows: unknown = JSON.parse(raw);
  if (!Array.isArray(rows)) throw new Error('owe.sh list --json: output is not a JSON array');
  return rows as OwedRow[];
}

export function bucketDefault(): string {
  const root = releaseRoot();
  if (basename(root) !== 'release') throw new Error(root);
  return dirname(root);
}

// Swapped by tests; the CLI never touches it.
export const probes = { mainCi: mainCiGreen, owedOpen: owedOpenDefault, bucket: bucketDefault };

async function findVersion(project: string, name: string) {
  const found = (await fetchVersions(project)).find((v) => v.name === name);
  if (!found) throw new Error(`no version named "${name}" in project ${project}`);
  return found;
}

const addLabel = (key: string, label: string) =>
  request('PUT', `/issue/${key}`, { update: { labels: [{ add: label }] } });

const openMembers = (project: string, name: string) =>
  `project=${project} AND fixVersion="${name}" AND statusCategory != Done ORDER BY key`;

const inKeys = (keys: string[]) => `key in (${keys.join(',')})`;

// Jira rejects the whole `key in (...)` query with HTTP 400 when one key no longer
// exists; retry key by key so a deleted key is absent from the result (read as open).
async function searchKeys(keys: string[], tail = '', labels = false): ReturnType<typeof searchAllIssues> {
  try {
    return await searchAllIssues(`${inKeys(keys)}${tail}`, SEARCH_LIMIT, request, labels);
  } catch (e) {
    if (!/^HTTP 400\b/.test(e instanceof Error ? e.message : '')) throw e;
  }
  const found: Awaited<ReturnType<typeof searchAllIssues>> = [];
  for (const k of keys) {
    try {
      found.push(...(await searchAllIssues(`key = ${k}${tail}`, SEARCH_LIMIT, request, labels)));
    } catch (e) {
      if (!/^HTTP 400\b/.test(e instanceof Error ? e.message : '')) throw e;
    }
  }
  return found;
}

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
          (await searchAllIssues(openMembers(project, name), SEARCH_LIMIT, request, true)) as Issue[]
        ).map((i) => i.key);
  const block = `frozen: ${date}\nfrozen-keys: ${keys.join(',')}`;
  const base = (version.description ?? '').trimEnd();
  const description = base === '' ? block : `${base}\n${block}`;
  if (opts.dryRun) return `Would freeze ${name} on ${date}: ${keys.length} ticket(s) labelled scope-${name}\n${keys.join(',')}`;
  // Label first: a failed label leaves the version unfrozen, so the freeze can be retried.
  for (const key of keys) await addLabel(key, `scope-${name}`);
  await request('PUT', `/version/${version.id}`, { description });
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
// freeze: a ledger row (a gate or chief-override filing, or an rm-admit)
// gives it a reason, none makes it a leak; the key's latest row decides, so a
// removal or deferral after an admission withdraws it. A Done key without a row is a
// Done-fold, not a leak. A row keyed by a check id (a version-ready override)
// is not an admission.
const isAdmission = (l: Admission) => l.kind !== 'deferral' && l.kind !== 'rm-remove' && KEY.test(l.key);

async function readinessRows(
  project: string,
  name: string,
  description: string | undefined,
  ledger: Admission[],
  sha?: string,
): Promise<Readiness> {
  const frozen = parseFrozen(description);
  const rows: Row[] = [];
  const done = (i: Issue) => i.fields.status.statusCategory?.key === 'done';
  let openCount = 0;
  const admitted: Readiness['admitted'] = [];
  const leaks: string[] = [];
  let folded = 0;
  if (!frozen) {
    const open = (await searchAllIssues(openMembers(project, name), SEARCH_LIMIT, request)).map((i) => i.key);
    rows.push({
      id: 'frozen-set',
      ok: open.length === 0,
      detail: open.length === 0 ? 'not frozen; every member Done' : `not frozen; open: ${list(open)}`,
    });
  } else {
    const issues = frozen.keys.length === 0 ? [] : ((await searchKeys(frozen.keys, '', true)) as Issue[]);
    const deferred = (i: Issue) =>
      (i.fields.labels ?? []).includes('deferred') &&
      ledger.some((l) => l.kind === 'deferral' && l.key === i.key && l.version === name);
    const seen = new Set(issues.map((i) => i.key));
    const open = [
      ...issues.filter((i) => !done(i) && !deferred(i)).map((i) => i.key),
      ...frozen.keys.filter((k) => !seen.has(k)),
    ];
    openCount = open.length;
    const inVersion = (await searchAllIssues(
      `project=${project} AND fixVersion="${name}"`,
      SEARCH_LIMIT,
      request,
      true,
    )) as Issue[];
    const frozenKeys = new Set(frozen.keys);
    for (const i of inVersion.filter((x) => !frozenKeys.has(x.key))) {
      const latest = ledger.filter((l) => l.key === i.key).pop();
      const record = latest && isAdmission(latest) ? latest : undefined;
      if (record) admitted.push({ key: i.key, reason: record.reason ?? record.gate ?? '', by: record.by });
      else if (done(i) && !latest) folded += 1;
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
    `project=${project} AND fixVersion="${name}" AND issuetype=Bug AND statusCategory != Done AND (priority in (Highest, High) OR labels in (critical, blocker, v1-blocker))`,
    SEARCH_LIMIT,
    request,
  );
  rows.push({
    id: 'no-blocker-bug',
    ok: blockers.length === 0,
    detail:
      blockers.length === 0
        ? 'no open Highest or High priority bug, none labelled critical, blocker or v1-blocker'
        : `open: ${list(blockers.map((i) => i.key))}`,
  });
  const stationAdhoc = await searchAllIssues(
    `project=${project} AND fixVersion="${name}" AND labels = station-adhoc AND statusCategory != Done`,
    SEARCH_LIMIT,
    request,
  );
  rows.push({
    id: 'station-adhoc',
    ok: stationAdhoc.length === 0,
    detail: stationAdhoc.length === 0 ? 'no open station-adhoc ticket' : `open: ${list(stationAdhoc.map((i) => i.key))}`,
  });
  const ci = probes.mainCi(sha);
  rows.push({ id: 'main-ci', ok: ci.ok, detail: ci.detail });
  // The Done-fold stamps each Done ticket with the version; a Done frozen key
  // that lacks it means the fold has not run for the range.
  const unfolded =
    frozen && frozen.keys.length > 0
      ? await searchKeys(frozen.keys, ` AND statusCategory = Done AND (fixVersion != "${name}" OR fixVersion is EMPTY)`)
      : [];
  rows.push({
    id: 'done-fold',
    ok: unfolded.length === 0,
    detail: !frozen
      ? 'not frozen: this row checks nothing here; READY row 6 reads the fold'
      : unfolded.length === 0
        ? 'every Done frozen key carries the version'
        : `not folded: ${list(unfolded.map((i) => i.key))}`,
  });
  const placed = placeBucket();
  rows.push(
    'error' in placed
      ? { id: 'promise-proof', ok: false, detail: placed.error }
      : promiseProofRow(name, placed.bucket),
    'error' in placed ? { id: 'owed-steps', ok: false, detail: placed.error } : await owedStepsRow(name, placed.bucket),
  );
  return { rows, openCount, admitted, leaks, folded };
}

const clip = (text: string) => text.replace(/\s+/g, ' ').trim().slice(0, 60);

function placeBucket(): { bucket: string } | { error: string } {
  try {
    return { bucket: probes.bucket() };
  } catch (e) {
    return { error: `cannot place the bucket: ${(e as Error).message}` };
  }
}

const PROMISE_HEADER = 'n\tpart\ttext\tstate\tproof';

function promiseProofRow(name: string, bucket: string): Row {
  const id = 'promise-proof';
  const path = join(bucket, 'specs', 'versions', `${name}-promise.tsv`);
  const fail = (detail: string): Row => ({ id, ok: false, detail });
  if (!existsSync(path)) return fail(`no promise record at ${path}`);
  let text: string;
  try {
    text = readFileSync(path, 'utf8');
  } catch (e) {
    return fail(`cannot read ${path}: ${(e as Error).message.split('\n')[0]}`);
  }
  const lines = text.split('\n').map((l) => l.replace(/\r$/, ''));
  if (lines[0] !== PROMISE_HEADER) return fail(`bad header in ${path}`);
  const bad: string[] = [];
  let sentences = 0;
  for (let at = 1; at < lines.length; at += 1) {
    if (lines[at].trim() === '') continue;
    const fields = lines[at].split('\t');
    if (fields.length < 4 || fields.length > 5) return fail(`bad row ${at + 1} in ${path}: ${fields.length} fields`);
    sentences += 1;
    const proof = (fields[4] ?? '').trim();
    if (fields[3].trim() !== 'shown_true' || proof === '' || PLACEHOLDER.test(proof)) bad.push(`${fields[0]} "${clip(fields[2])}"`);
  }
  if (sentences === 0) return fail(`no sentences in ${path}`);
  return bad.length === 0
    ? { id, ok: true, detail: `${sentences} sentences shown true, each with its proof` }
    : fail(`no proof: ${bad.join('; ')}`);
}

async function owedStepsRow(name: string, bucket: string): Promise<Row> {
  const id = 'owed-steps';
  const ledger = join(bucket, 'owed.jsonl');
  if (!existsSync(ledger)) return { id, ok: false, detail: `no owed ledger at ${ledger}` };
  try {
    const keyed = probes.owedOpen(bucket).filter((r) => r.action !== 'notify' && typeof r.key === 'string' && KEY.test(r.key));
    const members =
      keyed.length === 0
        ? new Set<string>()
        : new Set((await searchKeys([...new Set(keyed.map((r) => r.key as string))], ` AND fixVersion="${name}"`)).map((i) => i.key));
    const open = keyed.filter((r) => members.has(r.key as string));
    return open.length === 0
      ? { id, ok: true, detail: 'no open owed step on a member' }
      : {
          id,
          ok: false,
          detail: `open: ${open.map((r) => `${r.key} ${r.id} (${r.actor ?? r.kind}) "${clip(r.text ?? '')}"`).join('; ')}`,
        };
  } catch (e) {
    return { id, ok: false, detail: `owed ledger unreadable: ${(e as Error).message.split('\n')[0]}` };
  }
}

export async function versionReady(
  project: string,
  name: string,
  opts: { chiefOverride?: Override[]; sha?: string; out?: string },
): Promise<string[]> {
  const version = await findVersion(project, name);
  const frozen = parseFrozen(version.description);
  const ledger = readAdmissions(name);
  const checked = await readinessRows(project, name, version.description, ledger, opts.sha);
  let rows = checked.rows;
  const lines: string[] = [];
  const overrides = opts.chiefOverride ?? [];
  if (overrides.length > 0) {
    if (!hasConsoleMarker()) lines.push('chief-override ignored: no chief marker (HIMMEL_CONSOLE=1 is not set)');
    else {
      for (const o of overrides) {
        if (!o.reason.trim()) lines.push(`chief-override ${o.id} ignored: a reason is mandatory`);
        else if (!rows.some((r) => r.id === o.id)) lines.push(`chief-override ${o.id} ignored: no such row`);
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
  const code = rows.some((r) => !r.ok) ? 1 : 0;
  if (code === 1) process.exitCode = 1;
  if (opts.out !== undefined) {
    const tmp = `${opts.out}.tmp-${process.pid}`;
    writeFileSync(tmp, `${out.join('\n')}\nsha=${opts.sha}\nat=${new Date().toISOString()}\nexit=${code}\n`);
    renameSync(tmp, opts.out);
  }
  return out;
}

// The fixVersion moves first, each change read back, so a failed move throws
// before the label or the ledger row claims a deferral that did not happen.
// The target goes on before the source comes off, so a refused target leaves
// the ticket where it was. A source that stays on takes the target off again;
// a source that cannot be read back leaves both and says so.
export async function deferTicket(key: string, version: string, reason: string | undefined, to?: string, by?: string): Promise<string> {
  if (!hasConsoleMarker()) throw new Error('version-defer needs the chief marker: only the chief defers a frozen ticket');
  if (!reason?.trim()) throw new Error('version-defer: --reason is mandatory');
  if (to === version) throw new Error(`version-defer: --to ${to} is the version the ticket is deferred from`);
  if (to) await addFixVersionGated(key, to, {});
  try {
    await setFixVersion(key, 'remove', version, undefined, by === undefined ? undefined : { by });
  } catch (e) {
    if (!to) throw e;
    const msg = (e as Error).message;
    const got = await request<{ fields?: { fixVersions?: unknown } }>('GET', `/issue/${key}?fields=fixVersions`).catch(() => undefined);
    const raw = got?.fields?.fixVersions;
    if (!Array.isArray(raw)) throw new Error(`${msg} The ticket may hold both ${version} and ${to}: check it by hand.`);
    if ((raw as Array<{ name?: string }>).some((v) => v.name === version)) {
      await setFixVersion(key, 'remove', to);
      throw new Error(`${msg} ${to} was taken off again, so the ticket stays in ${version}.`);
    }
  }
  await addLabel(key, 'deferred');
  appendAdmission({ version, key, kind: 'deferral', reason: reason.trim() });
  return `${key} deferred from ${version}${to ? ` to ${to}` : ''}: ${reason.trim()}`;
}

export function admitTicket(key: string, version: string, reason: string | undefined, by: string | undefined): string {
  if (!hasConsoleMarker()) throw new Error('version-admit needs the chief marker: only the chief records an admission');
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
    .description('Print the checks before a cut as PASS/FAIL rows and exit 1 when a row FAILs; --out writes the file READY row 3 reads')
    .option('--project <key>', 'Project key (default: JIRA_PROJECT_KEY env var)')
    .option('--sha <sha>', 'The candidate commit, 40 lowercase hex: main-ci reads the runs at this sha (default: main\'s head)')
    .option('--out <path>', 'Also write the rows to this file, then sha=, at= and exit=; needs --sha, refuses --chief-override')
    .option(
      '--chief-override <values...>',
      'Chief only (HIMMEL_CONSOLE=1), repeatable, as <row-id> "<reason>": turn one FAIL row into an overridden PASS, recording the reason in the admissions ledger',
    )
    .action(async (name: string, options: { project?: string; sha?: string; out?: string; chiefOverride?: string[] }) => {
      const flat = chiefOverrideOf(options) ?? [];
      if (flat.length % 2 !== 0) throw new Error('--chief-override takes <row-id> "<reason>" pairs');
      if (options.sha !== undefined && !/^[0-9a-f]{40}$/.test(options.sha)) {
        throw new Error(`--sha must be 40 hex characters (lowercase), got "${options.sha}"`);
      }
      if (options.out !== undefined && options.sha === undefined) throw new Error('--out needs --sha');
      if (options.out !== undefined && flat.length > 0) throw new Error('--out refuses --chief-override');
      const chiefOverride: Override[] = [];
      for (let i = 0; i < flat.length; i += 2) chiefOverride.push({ id: flat[i], reason: flat[i + 1] });
      const lines = await versionReady(options.project ?? projectKey(), name, { chiefOverride, sha: options.sha, out: options.out });
      for (const line of lines) console.log(line);
    });

  program
    .command('version-admit <key>')
    .description('Chief only: record that the release manager admitted a ticket into a frozen version, with a reason, in the admissions ledger')
    .requiredOption('--version <name>', 'The frozen version the ticket was admitted into')
    .option('--reason <text>', 'Why (mandatory)')
    .option('--by <rm-session>', 'The release-manager session that ruled it (mandatory)')
    .action(async (key: string, options: { version: string; reason?: string; by?: string }) => {
      console.log(admitTicket(key, options.version, options.reason, options.by));
    });

  program
    .command('version-defer <key>')
    .description('Chief only: defer a frozen ticket (remove the fixVersion, label deferred) and record the reason in the admissions ledger')
    .requiredOption('--version <name>', 'The frozen version the ticket is deferred from')
    .option('--to <name>', 'Also add this fixVersion (a frozen target is refused)')
    .option('--reason <text>', 'Why (mandatory)')
    .option('--by <O-id>', 'The operator record that takes the ticket out of the version (a move to --to, or a remove)')
    .action(async (key: string, options: { version: string; to?: string; reason?: string; by?: string }) => {
      console.log(await deferTicket(key, options.version, options.reason, options.to, options.by));
    });
}
