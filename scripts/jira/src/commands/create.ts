import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { InvalidArgumentError, type Command } from 'commander';
import { coreMatch, loadCorePatterns, type ChangeClass } from '../release/core.js';
import { request, projectKey } from '../client.js';
import { writeJiraBreadcrumb } from '../breadcrumb.js';
import { markdownToAdf } from '../adf.js';
import type { CreateIssueResponse } from '../types.js';
import { uploadAll } from './attach-helper.js';
import { readBodyFile } from './body-file.js';
import { parseLabels } from './labels.js';
import { titleSector, PLAIN_BLOCK_TEMPLATE } from '../plain-block.js';
import { CreatePartial, CreateRefused, runCreate, type CreateOptions } from '../operations/create.js';
import { resolveSector, sectorField, sectorOptions } from './sector.js';
import { searchAllIssues } from './list.js';
import { createIssueLink, requireBlockerVersion, targetFixVersion } from './link.js';
import { admissionsLedgerExists, appendAdmission, readAdmissions, type Admission, type AdmissionInput } from './admissions-ledger.js';
import { assertIntakeGate, checkConsoleOverride, checkIntakeGate, chiefOverrideOf, frozenDate, INTAKE_GATES } from './intake-gate.js';
import { assertVersionExists, earliestUnreleased, fetchVersions, resolveAffectsVersion } from './versions.js';
import { ctxFor, refuseRequest, refuseTestJiraPost } from './release.js';
import { decisionWords, operatorFence, placementOf, readOperatorRecords, request as releaseRequest, requestWithWords } from '../release/engine.js';
import type { TicketFacts } from '../release/operator-work.js';
import { admits } from '../release/leaks.js';
import { loadKey } from '../release/ledger.js';
import { releaseKeyPath, releaseRoot } from '../release/paths.js';
import { ancestorValue } from '../release/fence-ancestry.js';
import { isTestProject } from '../live-test-guard.js';

function collect(value: string, prev: string[]): string[] {
  return [...prev, value];
}

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..', '..');

/** The text under the "Agent detail" heading of a markdown body, up to the next heading. */
export function agentDetailOf(md: string): string {
  const lines = md.split('\n');
  // a heading inside a fenced code block is not a heading (as in lintPlainBlock)
  let fenced = false;
  const heading = lines.map((l) => {
    if (/^\s{0,3}(```|~~~)/.test(l)) fenced = !fenced;
    return !fenced && /^\s{0,3}#{1,6}\s/.test(l);
  });
  const start = lines.findIndex((l, i) => heading[i] && /^\s{0,3}#{1,6}\s+agent detail\b/i.test(l));
  if (start < 0) return '';
  const end = heading.findIndex((h, i) => i > start && h);
  return lines.slice(start + 1, end < 0 ? undefined : end).join('\n');
}

/** The Agent detail of an ADF body: the text of every node after its "Agent detail" heading. */
export function agentDetailOfAdf(doc: unknown): string {
  const text = (n: unknown): string => {
    const x = n as { text?: string; content?: Array<{ text?: string }> };
    // block children (list items, paragraphs) are separated; inline text runs stay contiguous
    const inline = (x.content ?? []).every((c) => c.text !== undefined);
    return (x.text ?? '') + (x.content ?? []).map(text).join(inline ? '' : '\n');
  };
  const nodes = ((doc as { content?: Array<{ type?: string }> } | null)?.content ?? []);
  const start = nodes.findIndex((n) => n.type === 'heading' && /^agent detail\b/i.test(text(n).trim()));
  if (start < 0) return '';
  const rest = nodes.slice(start + 1);
  const end = rest.findIndex((n) => n.type === 'heading');
  return (end < 0 ? rest : rest.slice(0, end)).map(text).join('\n');
}

/** Slash-bearing path tokens in a text, trailing punctuation dropped. */
export function pathsIn(text: string): string[] {
  const found = text.match(/[\w.@+-]+(?:\/[\w.@+-]+)+/g) ?? [];
  return [...new Set(found.map((p) => p.replace(/[.]+$/, '')))];
}

/** CORE adds the label; REVIEW (a rename or bulk change) adds none and is left to the chief. */
export function coreVerdict(
  detail: string, changeClass: string | undefined,
): { kind: 'core' | 'core-review'; path: string } | undefined {
  const paths = pathsIn(detail);
  if (paths.length === 0) return undefined;
  const patterns = loadCorePatterns(join(repoRoot, 'scripts', 'ci', 'core-paths.txt'));
  const [line] = coreMatch(paths, ['K'], { patterns, changeClass: changeClass as ChangeClass | undefined });
  const [verdict, , path] = line!.split(' ');
  if (verdict === 'CORE') return { kind: 'core', path: path! };
  if (verdict === 'REVIEW') return { kind: 'core-review', path: path! };
  return undefined;
}

type CoreVerdict = ReturnType<typeof coreVerdict>;

/** The labels with core added on a CORE verdict, plus the verdict itself. */
export function markCore(
  detail: string, changeClass: string | undefined, labels: string[] | undefined,
): { labels: string[] | undefined; verdict: CoreVerdict } {
  if (changeClass !== undefined && changeClass !== 'rename' && changeClass !== 'bulk') {
    throw new Error('create: --change-class is rename or bulk');
  }
  const verdict = coreVerdict(detail, changeClass);
  return { labels: verdict?.kind === 'core' ? [...new Set([...(labels ?? []), 'core'])] : labels, verdict };
}

export function printCore(verdict: CoreVerdict): void {
  if (verdict) console.error(`${verdict.kind}: ${verdict.path}`);
}

/**
 * Jira's REST field is `summary`; the CLI's long-standing flag is `--title`
 * (matches `edit --title`). `--summary` is accepted as an alias since that's
 * the literal Jira field name and the natural reach for anyone who knows the
 * API. If both are given, `--title` wins. It's the documented flag, so this
 * is the least-surprising resolution (no error; --summary is a pure
 * alias, not a distinct value to reconcile).
 */
export function resolveTitle(opts: { title?: string; summary?: string }): string {
  const title = opts.title ?? opts.summary;
  if (title === undefined) {
    throw new Error('Create requires --title (or --summary)');
  }
  return title;
}

/** The Sector to file under: the typed --sector, else a live "<Sector>: " title prefix; an unknown prefix exits 1. */
export function sectorForCreate(
  type: string,
  title: string,
  given: string | undefined,
  sectors: readonly string[] | undefined,
): string | undefined {
  if (!sectors) return undefined;
  if (given !== undefined) return resolveSector(given, sectors);
  const derived = titleSector(type, title, sectors);
  if (derived.refuse) throw new CreateRefused(derived.refuse);
  return derived.sector;
}

const FU_CLASSES = ['polish', 'escape', 'hardening'];
export const FU_WHY_CODES = ['unseen-failure', 'no-check', 'vacuous-check', 'no-recovery', 'silent-rot'];
/**
 * Decisions 746, 762: a named override is a judge verdict id (two capitals, j, number, number) or a chief decision number.
 * ponytail: the id is an unverified audit label, only its shape is checked and nothing ties it to a real judge or chief
 * ruling, so a worker could invent one; upgrade path: look it up in the verdicts folder and the decision register.
 */
const FU_OVERRIDE_SHAPE = /^(decision-[0-9]+|[A-Z]{2}-j[0-9]+-[0-9]+)$/;
const POLISH_REFUSAL =
  'a polish residual is not filed (decisions 746, 762): note it in the PR body, or file it as a plain ticket (jira create without --residual-of) if someone will really work it, ' +
  'then link it from the PR ticket with `jira link <PR ticket> <plain ticket>` so it can be named as a deferral';
/** A hardening residual prints its named override into the ticket description. */
export function appendFuOverride(fields: Record<string, unknown>, override: string | undefined): void {
  if (override === undefined) return;
  const named = markdownToAdf(`fu-override: ${override}`);
  const body = fields['description'] as { content?: unknown[] } | undefined;
  if (body?.content) body.content.push(...named.content);
  else fields['description'] = named;
}
// Open residual slots per version; a `residual-budget:N` line in the
// version description overrides it.
export const RESIDUAL_BUDGET = 15;

export function residualBudget(description: string | undefined): number {
  const m = /^\s*residual-budget:\s*(\d+)\s*$/m.exec(description ?? '');
  return m ? Number(m[1]) : RESIDUAL_BUDGET;
}

const jqlQuote = (s: string): string => `"${s.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
const labelSlug = (s: string): string => s.trim().replace(/\s+/g, '-');

/** Residual depth of a new ticket: its parent's residual-depth-N label plus one (0 when the parent has none). */
export function nextResidualDepth(parentLabels: string[]): number {
  const depths = parentLabels.map((l) => /^residual-depth-(\d+)$/.exec(l)).filter((m) => m !== null).map((m) => Number(m![1]));
  return Math.max(0, ...depths) + 1;
}

export const BACKLOG_LABEL = 'backlog';

export const OVER_CAP_LABEL = 'over-cap';
const OPERATOR_DIRECTED = 'operator-directed';

interface CapState {
  current: string;
  next?: string;
  open: number;
  cap: number;
}

/**
 * The current unreleased version's open residuals against its cap. With a
 * target, any other version is not gated (undefined). An unreadable Jira
 * answer skips the check with a warning rather than blocking a filing.
 */
async function capState(project: string, target?: string): Promise<CapState | undefined> {
  try {
    const versions = await fetchVersions(project);
    const current = earliestUnreleased(versions);
    if (!current || (target !== undefined && target !== current)) return undefined;
    const cap = residualBudget(versions.find((v) => v.name === current)?.description);
    const jql =
      `project = ${project} AND fixVersion = ${jqlQuote(current)} AND labels = residual AND statusCategory != Done`;
    const open = (await searchAllIssues(jql, String(cap), request)).length;
    return { current, next: earliestUnreleased(versions.filter((v) => v.name !== current)), open, cap };
  } catch (e) {
    console.error(`jira: cap check skipped (${(e as Error).message})`);
    return undefined;
  }
}

export interface ResidualPlan {
  labels: string[];
  fixVersion?: string;
  affectsVersion?: string;
  duplicateOf?: string;
  frozen: string[];
  displaced?: { key: string; fixVersion?: string };
  ranks?: { newcomer: number[]; resident?: { key: string; tuple: number[] } };
}

interface ResidualOptions {
  residualOf: string;
  fuClass?: string;
  fuWhy?: string;
  fuOverride?: string;
  class?: string;
  area?: string;
  fixVersion?: string;
  gate?: string;
  priority?: string;
  blocks?: string[];
  sector?: string;
}

interface TicketState {
  status?: { statusCategory: { key: string } };
  fixVersions?: { name: string }[];
}

/** The unreleased version an open ticket sits in; a Done ticket, or one in no live version, is no chain. */
function openVersion(t: TicketState, unreleased: Set<string>): string | undefined {
  if (t.status?.statusCategory.key === 'done') return undefined;
  return t.fixVersions?.find((v) => unreleased.has(v.name))?.name;
}

interface RankedIssue {
  key: string;
  fields: TicketState & {
    status?: { name?: string; statusCategory: { key: string } };
    labels?: string[];
    priority?: { name: string };
    created?: string;
    parent?: { key: string };
    issuelinks?: { type: { name: string }; outwardIssue?: { key: string } }[];
    [field: string]: unknown;
  };
}

const GATE_RANK = ['receipt', 'must', 'regression', 'critical'];
const PRIORITY_RANK = ['Lowest', 'Low', 'Medium', 'High', 'Highest'];
const compareRank = (a: number[], b: number[]) => {
  for (let i = 0; i < a.length; i += 1) {
    if (a[i] !== b[i]) return a[i] - b[i];
  }
  return 0;
};

function residualGateRank(i: RankedIssue, ledger: Admission[]): number {
  const row = ledger.filter((r) => r.key === i.key).pop();
  const gate = row?.kind !== 'deferral' && row?.kind !== 'rm-remove' ? row?.gate?.split(':')[0] : undefined;
  return Math.max(0, ...GATE_RANK.map((g, index) =>
    (i.fields.labels ?? []).includes(`gate-${g}`) || gate === g ? index + 1 : 0));
}

/**
 * Says whether a key's place in `version` is ruled: its latest ledger row admits it
 * (an rm-admit or an override, as the release leak diff reads it), or the latest signed
 * operator decision naming it puts it there. A ruled key is moved only by the release
 * manager. Undefined when the rulings cannot be read, so the caller displaces nobody.
 */
function rulingsOf(version: string): ((key: string) => boolean) | undefined {
  try {
    if (!admissionsLedgerExists()) throw new Error('the admissions ledger does not exist');
    const rows = readAdmissions(version);
    // readOperatorRecords skips a declared release whose key cannot be loaded, so check every key first.
    const root = releaseRoot();
    for (const release of existsSync(root) ? readdirSync(root) : []) {
      if (existsSync(join(root, release, 'release.json'))) loadKey(releaseKeyPath(release));
    }
    const decisions = readOperatorRecords('decision')
      .filter((d) => d.keys !== undefined && placementOf(d) !== undefined)
      .sort((a, b) => a.ts.localeCompare(b.ts));
    return (key) => {
      if (admits(rows.filter((r) => r.key === key).pop())) return true;
      const latest = decisions.filter((d) => d.keys!.includes(key)).pop();
      return latest !== undefined && placementOf(latest) === version;
    };
  } catch (e) {
    console.error(`jira: warning: the rulings on ${version} cannot be read (${(e as Error).message}); no resident is displaced`);
    return undefined;
  }
}

/** Read all rank fields while retaining the shared search helper's pagination. */
async function rankIssues(jql: string): Promise<RankedIssue[]> {
  const fields = ['labels', 'status', 'priority', 'created', 'fixVersions', 'issuelinks', 'parent', sectorField()].filter(Boolean).join(',');
  const req: typeof request = (method, path, body) =>
    request(method, path.replace(/&fields=[^&]*/, `&fields=${fields}`), body);
  return await searchAllIssues(jql, String(Number.MAX_SAFE_INTEGER), req) as unknown as RankedIssue[];
}

async function competeForSlot(
  project: string,
  version: string,
  budget: number,
  stepDown: string | undefined,
  o: ResidualOptions,
  labels: string[],
  parent: RankedIssue,
): Promise<Pick<ResidualPlan, 'fixVersion' | 'displaced' | 'ranks'>> {
  const residents = await rankIssues(
    `project = ${project} AND fixVersion = ${jqlQuote(version)} AND labels = residual AND statusCategory != Done`,
  );
  if (residents.length < budget) return { fixVersion: version };

  const heads = await rankIssues(`project = ${project} AND fixVersion = ${jqlQuote(version)} AND statusCategory != Done`);
  const byKey = new Map(heads.map((i) => [i.key, i]));
  // The parent is already read for placement, including when it is no longer open.
  if (!byKey.has(o.residualOf)) byKey.set(o.residualOf, parent);
  for (const key of o.blocks ?? []) {
    if (!byKey.has(key)) byKey.set(key, await request<RankedIssue>('GET', `/issue/${key}?fields=status,fixVersions`));
  }
  const links = (i: RankedIssue): string[] => [
    ...(i.fields.parent ? [i.fields.parent.key] : []),
    ...(i.fields.issuelinks ?? []).filter((l) => ['Blocks', 'Relates'].includes(l.type.name))
      .flatMap((l) => l.outwardIssue ? [l.outwardIssue.key] : []),
  ];
  const openHead = (key: string) => {
    const issue = byKey.get(key);
    return issue && openVersion(issue.fields, new Set([version])) === version ? issue : undefined;
  };
  const newcomerLinks = [o.residualOf, ...(o.blocks ?? [])];
  const headKeys = [...new Set([...newcomerLinks, ...residents.flatMap(links)])];
  const sectorId = sectorField();
  const sectorOf = (i: RankedIssue) => sectorId ? (i.fields[sectorId] as { value?: string } | undefined)?.value : undefined;
  const sharedSectors = new Set(headKeys.map(openHead).filter((i) => i !== undefined).map(sectorOf).filter(Boolean));
  const rank = (i: RankedIssue, targets: string[], gate: number, sector: string | undefined): number[] => {
    const ls = i.fields.labels ?? [];
    const created = Date.parse(i.fields.created ?? '');
    return [gate, ls.includes('fu-escape') ? 2 : ls.includes('fu-hardening') ? 1 : 0,
      PRIORITY_RANK.findIndex((p) => p.toLowerCase() === (i.fields.priority?.name ?? 'Medium').toLowerCase()) + 1,
      Number(targets.some((key) => openHead(key) !== undefined)), Number(sector !== undefined && sharedSectors.has(sector)),
      Number.isFinite(created) ? -created : 0];
  };
  const newcomer = rank({ key: '', fields: { labels, priority: { name: o.priority ?? 'Medium' }, created: new Date().toISOString() } },
    newcomerLinks, GATE_RANK.indexOf(o.gate?.split(':')[0] ?? '') + 1, o.sector);
  // With the rulings unreadable nobody is displaced, and the ledger is not read again.
  const ruled = rulingsOf(version);
  const ledger = ruled === undefined ? [] : readAdmissions(version);
  const candidates = residents.filter((i) => ruled !== undefined && i.fields?.status?.name === 'To Do'
      && residualGateRank(i, ledger) === 0 && !ruled(i.key))
    .map((i) => ({ key: i.key, tuple: rank(i, links(i), 0, sectorOf(i)) }))
    .sort((a, b) => compareRank(a.tuple, b.tuple) || a.key.localeCompare(b.key));
  const lowest = candidates[0];
  const ranks = { newcomer, resident: lowest };
  if (lowest && compareRank(newcomer, lowest.tuple) > 0) {
    return { fixVersion: version, displaced: { key: lowest.key, fixVersion: stepDown }, ranks };
  }
  labels.push('residual-displaced');
  return { fixVersion: stepDown, ranks };
}

/**
 * Places a residual (plan 9.1 as corrected by 10.5); the first matching row wins:
 * a. depth >= 2, b. polish: backlog. c. --gate: current. d. escape: current if
 * unfrozen, else next. e. hardening with a chain: its version V if unfrozen,
 * else next. f. hardening, no chain, High or above: next. g. anything else: backlog.
 * Next is the earliest unreleased version after current. It never throws on a
 * frozen version; a frozen or missing next sends the residual to the backlog.
 */
export async function planResidual(project: string, o: ResidualOptions): Promise<ResidualPlan> {
  if (!o.fuClass) throw new Error('--residual-of requires --fu-class <polish|escape|hardening>');
  if (o.class !== undefined && !o.class) throw new Error('--class needs an id');
  if (!FU_CLASSES.includes(o.fuClass)) {
    throw new Error(`--fu-class must be one of ${FU_CLASSES.join(', ')} (got "${o.fuClass}")`);
  }
  if (o.fuClass === 'hardening') {
    if (!o.fuWhy) throw new Error(`--fu-class hardening requires --fu-why <${FU_WHY_CODES.join('|')}>`);
    if (!FU_WHY_CODES.includes(o.fuWhy)) {
      throw new Error(`--fu-why must be one of ${FU_WHY_CODES.join(', ')} (got "${o.fuWhy}")`);
    }
  } else if (o.fuWhy !== undefined) {
    throw new Error('--fu-why applies only to --fu-class hardening');
  }
  if (o.fuClass === 'polish') throw new Error(POLISH_REFUSAL);
  if (o.fuClass === 'hardening') {
    if (o.fuOverride === undefined || !FU_OVERRIDE_SHAPE.test(o.fuOverride)) {
      throw new Error(
        'a hardening residual is filed only with a named override (decisions 746, 762): pass --fu-override <judge verdict id of the form XX-jNNNN-N | decision-N>; the id is printed into the ticket and is not verified ' +
          `against the verdict or decision it names${o.fuOverride === undefined ? '' : `; got "${o.fuOverride}"`}; otherwise note it in the PR body`,
      );
    }
  } else if (o.fuOverride !== undefined) {
    throw new Error('--fu-override applies only to --fu-class hardening');
  }
  if (o.fixVersion !== undefined) throw new Error('--residual-of chooses the version itself; drop --fix-version');
  const classLabel = o.class !== undefined ? `class-${labelSlug(o.class)}` : undefined;
  const labels = ['residual', `fu-${o.fuClass}`];
  if (o.gate !== undefined) labels.push(`gate-${o.gate.split(':')[0]}`);
  if (o.fuClass === 'hardening') labels.push(`fu-why-${o.fuWhy}`, 'fu-override');
  if (classLabel) labels.push(classLabel);
  const area = o.area ? `area-${labelSlug(o.area)}` : undefined;
  if (area) labels.push(area);

  if (area && classLabel) {
    const jql =
      `project = ${project} AND labels = residual AND labels = ${jqlQuote(classLabel)} AND labels = ${jqlQuote(area)}` +
      ` AND key != ${jqlQuote(o.residualOf)} AND statusCategory != Done`;
    const [dup] = await searchAllIssues(jql, '1', request);
    if (dup) return { labels, duplicateOf: dup.key, frozen: [] };
  }

  const parent = await request<RankedIssue>(
    'GET',
    `/issue/${o.residualOf}?fields=labels,status,fixVersions`,
  );
  const depth = nextResidualDepth(parent.fields.labels ?? []);
  labels.push(`residual-depth-${depth}`);

  const versions = await fetchVersions(project);
  const current = earliestUnreleased(versions);
  const frozen = versions.filter((v) => frozenDate(v.description) !== undefined).map((v) => v.name);
  const next = current ? earliestUnreleased(versions.filter((v) => v.name !== current)) : undefined;
  const nextOpen = next !== undefined && !frozen.includes(next) ? next : undefined;
  const unfrozenOrNext = (v: string): string | undefined => (frozen.includes(v) ? nextOpen : v);

  let fixVersion: string | undefined;
  if (current && depth < 2 && o.fuClass !== 'polish') {
    if (o.gate !== undefined) {
      fixVersion = current;
    } else if (o.fuClass === 'escape') {
      fixVersion = unfrozenOrNext(current);
    } else {
      const unreleased = new Set(versions.filter((v) => !v.released && !v.archived).map((v) => v.name));
      let chain = openVersion(parent.fields, unreleased);
      for (const target of chain ? [] : (o.blocks ?? [])) {
        const t = await request<{ fields: TicketState }>('GET', `/issue/${target}?fields=status,fixVersions`);
        chain = openVersion(t.fields, unreleased);
        if (chain) break;
      }
      if (chain) fixVersion = unfrozenOrNext(chain);
      else if (/^(high|highest)$/i.test(o.priority ?? '')) fixVersion = nextOpen;
    }
  }
  const competition = fixVersion && !frozen.includes(fixVersion)
    ? await competeForSlot(project, fixVersion, residualBudget(versions.find((v) => v.name === fixVersion)?.description),
      fixVersion === current ? nextOpen : undefined, o, labels, parent)
    : { fixVersion };
  return { labels, affectsVersion: current, frozen, ...competition };
}

/**
 * Sets fixVersions and versions on a new ticket. Filing into the current
 * unreleased version warns at its residual cap; an operator-directed ticket
 * is exempt and a residual is routed by planResidual. Returns the over-cap
 * reason to comment on the ticket once it exists.
 */
export async function applyVersions(
  project: string,
  options: { type: string; fixVersion?: string; affectsVersion?: string; overCap?: string },
  fields: Record<string, unknown>,
  o: { labels?: string[]; residual: boolean; bugDefault: boolean },
): Promise<string | undefined> {
  const gated = !o.residual && !o.labels?.includes(OPERATOR_DIRECTED);
  let overCapReason: string | undefined;
  const markOverCap = (st: CapState): void => {
    overCapReason = `Filed over the ${st.current} cap (${st.open}/${st.cap} open residuals): ${options.overCap ?? 'raw create; cap is a warning'}`;
    fields['labels'] = [...new Set([...(o.labels ?? []), OVER_CAP_LABEL])];
  };
  if (options.fixVersion !== undefined) {
    await assertVersionExists(project, options.fixVersion);
    fields['fixVersions'] = [{ name: options.fixVersion }];
    const st = gated ? await capState(project, options.fixVersion) : undefined;
    if (st && st.open >= st.cap) {
      console.error(`jira: warning: ${st.current} is at its residual cap (${st.open}/${st.cap} open); filing with ${OVER_CAP_LABEL}`);
      markOverCap(st);
    }
  }
  if (options.affectsVersion !== undefined) {
    const version = await resolveAffectsVersion(project, options.affectsVersion);
    fields['versions'] = [{ name: version }];
  }
  // A Highest or gated Bug without an explicit --fix-version defaults to the
  // earliest unreleased version, or the next one when that is over its cap; an
  // unreadable/empty version list files with no fixVersion rather than
  // guess. Any other Bug was placed in the backlog before this point.
  if (o.bugDefault) {
    const st = gated ? await capState(project) : undefined;
    let defaultVersion: string | undefined;
    let redirected = false;
    if (st) {
      const full = st.open >= st.cap;
      const redirect = full && options.overCap === undefined;
      redirected = redirect;
      defaultVersion = redirect ? st.next : st.current;
      if (full && !redirect) markOverCap(st);
      if (redirect) {
        console.error(
          `jira: ${st.current} is over its cap (${st.open}/${st.cap} open); ` +
            (st.next ? `the ${options.type} goes to ${st.next}` : `no later version, filing the ${options.type} with no fixVersion`) +
            `; --over-cap <reason> files it into ${st.current}`,
        );
      }
    } else {
      try {
        defaultVersion = earliestUnreleased(await fetchVersions(project));
      } catch {
        defaultVersion = undefined;
      }
    }
    // stderr: stdout stays the bare `Created KEY` line scripted callers capture.
    if (defaultVersion) fields['fixVersions'] = [{ name: defaultVersion }];
    // A cap redirect already said where the Bug went.
    if (redirected) return overCapReason;
    if (defaultVersion) {
      console.error(`jira: ${options.type} defaults to fixVersion ${defaultVersion}; --fix-version overrides`);
    } else {
      console.error(`jira: no unreleased version found; filing the ${options.type} with no fixVersion`);
    }
  }
  return overCapReason;
}

interface PlacementOptions {
  type: string;
  fixVersion?: string;
  priority?: string;
  backlog?: boolean;
  gate?: string;
  chiefOverride?: string;
  sector?: string;
  followUpOf?: string;
  proposedVersion?: string;
  why?: string;
}

/** The label a proposed version leaves on the ticket until the release manager confirms or moves it. */
const proposedLabel = (v: string): string => `proposed-${labelSlug(v)}`;

/** Checks the gate, backlog and chief-override flags before anything is filed; returns the override reason. */
export function checkPlacementFlags(o: PlacementOptions): string | undefined {
  if (o.gate !== undefined) assertIntakeGate(o.gate);
  if (o.backlog && (o.gate !== undefined || o.fixVersion !== undefined)) {
    throw new Error('--backlog cannot be combined with --gate or --fix-version');
  }
  if (o.proposedVersion !== undefined) {
    if (!o.proposedVersion.trim()) throw new Error('--proposed-version needs a version name, or `backlog`');
    if (!/^(bug|task|story)$/i.test(o.type)) throw new Error(`--proposed-version applies to a Bug, Task or Story, not a ${o.type}`);
    if (o.gate !== undefined || o.fixVersion !== undefined) {
      throw new Error('--proposed-version cannot be combined with --gate or --fix-version (they already place the ticket in a version)');
    }
  }
  if (o.backlog || o.proposedVersion === 'backlog') {
    if (!o.backlog || o.proposedVersion !== 'backlog') {
      throw new Error('the backlog is filed with --backlog --proposed-version backlog and a one-line --why (--backlog alone is not a placement; pass --proposed-version <v> to propose a version instead)');
    }
    if (!o.why?.trim()) throw new Error('--backlog --proposed-version backlog needs --why <one line: why this waits in the backlog>');
  }
  const override = chiefOverrideOf(o);
  if (override === undefined) return undefined;
  const reason = checkConsoleOverride(override);
  if (o.fixVersion === undefined) throw new Error('--chief-override needs the --fix-version to admit into');
  return reason;
}

/** A proposed version other than `backlog` must be one the project has, and still open. */
export async function assertProposedVersion(o: { proposedVersion?: string; project?: string }): Promise<void> {
  if (o.proposedVersion === undefined || o.proposedVersion === 'backlog') return;
  const project = o.project ?? projectKey();
  const found = (await fetchVersions(project)).find((v) => v.name === o.proposedVersion);
  if (!found) throw new Error(`no version named "${o.proposedVersion}" in project ${project}`);
  if (found.released || found.archived) {
    throw new Error(`--proposed-version ${o.proposedVersion} is ${found.released ? 'released' : 'archived'}; propose an open version`);
  }
}

/** A version inherited from a --blocks or --split-from target places the ticket, so a proposal could not be honored. */
export function assertProposalNotInherited(o: { proposedVersion?: string }, inherited: string | undefined): void {
  if (o.proposedVersion !== undefined && inherited !== undefined) {
    throw new Error(`--proposed-version ${o.proposedVersion} cannot be honored: --blocks/--split-from places the ticket in ${inherited}; drop --proposed-version, or pass --backlog to opt out of the inherited version`);
  }
}

/**
 * A Bug, Task or Story is placed at filing. A gated one, or a Highest Bug,
 * takes the active version (bugDefault); --backlog, --fix-version, --gate,
 * --residual-of, --follow-up-of or a version inherited from a blocker place
 * any of them; with none of these it is refused rather than defaulted silently.
 */
export function placeAtFiling(
  o: PlacementOptions,
  labels: string[] | undefined,
  residual: boolean,
  testProject = false,
): { labels: string[] | undefined; bugDefault: boolean } {
  const type = o.type.toLowerCase();
  const isBug = type === 'bug';
  if ((!isBug && type !== 'task' && type !== 'story') || residual || testProject || o.fixVersion !== undefined) return { labels, bugDefault: false };
  if (o.backlog) return { labels: [...new Set([...(labels ?? []), BACKLOG_LABEL, proposedLabel('backlog')])], bugDefault: false };
  if (o.proposedVersion !== undefined) return { labels: [...new Set([...(labels ?? []), proposedLabel(o.proposedVersion)])], bugDefault: false };
  if (o.gate !== undefined || (isBug && o.priority?.toLowerCase() === 'highest')) return { labels, bugDefault: true };
  if (o.followUpOf !== undefined) return { labels, bugDefault: false };
  const sector = 'sector: ' + (o.sector ?? 'none given');
  if (isBug) {
    throw new Error(
      `A Bug needs a placement (${sector}): pass --proposed-version <v> to file it with a proposed version and its INTAKE request, ` +
        '--backlog --proposed-version backlog --why <why> if it blocks no open work, ' +
        'or --fix-version <v> / --gate critical|regression / --priority Highest to file it into a version; ' +
        'a Bug that blocks open work, such as a PR, goes into a version, then request INTAKE ' +
        '(jira release request <release> --verb INTAKE --key <key> --why <why>)',
    );
  }
  throw new Error(
    `A ${o.type} needs a placement (${sector}): pass --proposed-version <v> to file it with a proposed version and its INTAKE request, ` +
      '--backlog --proposed-version backlog --why <why> for the backlog, ' +
      'or --fix-version <v> / --gate critical|regression / --residual-of <key> / --follow-up-of <key> to place it',
  );
}

const intakeWhy = (o: { why?: string; proposedVersion?: string }, title: string): string => {
  const proposed = o.proposedVersion !== undefined && o.proposedVersion !== 'backlog' ? `proposed for ${o.proposedVersion}` : 'filed to the backlog';
  return o.why?.trim() || `${proposed}: ${title}`;
};
export const intakeOwed = (type: string, fields: Record<string, unknown>, testProject = false): boolean => !testProject && !fields['fixVersions'] && /^(bug|task|story)$/i.test(type);

/** The pointer a bridge-filed INTAKE carries: the operator's Telegram update and the chat the poller stamped. */
export interface BridgePointer { operator_update: number; filed_by: 'bridge'; bridge_chat: number }

interface IntakeOptions {
  type: string;
  proposedVersion?: string;
  why?: string;
  evidence?: Record<string, unknown>;
  decision?: string;
  words?: string;
  pointer?: BridgePointer;
}

type IntakeWords = { decision?: string; words?: string; ticket?: TicketFacts; pointer?: BridgePointer };

const toVersionOf = (o: { proposedVersion?: string }): string | null =>
  o.proposedVersion === undefined || o.proposedVersion === 'backlog' ? null : o.proposedVersion;

export function parseOperatorUpdate(v: string): number {
  if (!/^\d+$/.test(v) || !Number.isSafeInteger(Number(v))) throw new InvalidArgumentError('the Telegram update_id, digits only');
  return Number(v);
}

export type PointerCheck = 'marker' | 'worker' | 'intake' | 'version' | 'stamp';

/**
 * Who may set --operator-update: a Telegram bridge session filing an unversioned
 * Bug, Task or Story toward a version, whose poller-stamped chat is the operator's
 * DM. The stamp is read from the farthest marked ancestor, the bridge's own
 * claude, so a command's env prefix cannot supply it.
 */
export function bridgePointer(
  o: { operatorUpdate?: number; type: string; fixVersion?: string; proposedVersion?: string; project?: string },
  // Test-only: run once with a check removed to prove its row fails on that check.
  seams: { env?: NodeJS.ProcessEnv; disable?: PointerCheck[] } = {},
): BridgePointer | undefined {
  if (o.operatorUpdate === undefined) return undefined;
  const env = seams.env ?? process.env;
  const on = (c: PointerCheck) => !seams.disable?.includes(c);
  const refuse = (why: string) => new CreateRefused(`jira create: --operator-update refused, nothing was filed: ${why}`);
  if (on('marker') && env['HIMMEL_BRIDGE_SESSION'] !== '1') {
    throw refuse('only a Telegram bridge session (HIMMEL_BRIDGE_SESSION=1) names the operator\'s update');
  }
  if (on('worker') && (env['HIMMEL_CONSOLE_LEG'] === '1' || env['HIMMEL_RELEASE_MANAGER'] === '1')) {
    throw refuse('a chief-spawned worker or the release manager never names the operator\'s update');
  }
  const fields = o.fixVersion === undefined ? {} : { fixVersions: [{ name: o.fixVersion }] };
  if (on('intake') && !intakeOwed(o.type, fields, isTestProject(o.project ?? projectKey()))) {
    throw refuse('no INTAKE is owed (--fix-version, an Epic or Subtask, or a test project), so no request carries the pointer');
  }
  if (on('version') && toVersionOf(o) === null) {
    throw refuse('the INTAKE names no version; pass --proposed-version <v>, the version the operator\'s line states');
  }
  const stamp = ancestorValue('HIMMEL_BRIDGE_SESSION') === '1' ? ancestorValue('HIMMEL_BRIDGE_CHAT') : null;
  if (on('stamp') && !/^[1-9]\d*$/.test(stamp ?? '')) {
    throw refuse(`the poller's chat stamp in the process ancestry is ${stamp === null ? 'missing' : `${stamp}, not the operator's DM`}`);
  }
  return { operator_update: o.operatorUpdate, filed_by: 'bridge', bridge_chat: Number(stamp) };
}

const factsOf = (fields: Record<string, unknown>): TicketFacts => ({
  labels: Array.isArray(fields['labels']) ? (fields['labels'] as string[]) : [],
  priority: (fields['priority'] as { name?: string } | undefined)?.name ?? '',
  open: true,
});

class NoReleaseDeclared extends Error {
  constructor(root: string) {
    super(`no release is declared under ${root}, so an unversioned ticket has nowhere to queue its INTAKE; declare one (jira release operator declare) or file with --fix-version`);
  }
}

/** The one declared release an INTAKE goes to; throws when the state cannot be read or the choice is not unique. */
export function intakeRelease(): string {
  const root = releaseRoot();
  let entries: string[] = [];
  try {
    entries = readdirSync(root);
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code !== 'ENOENT') throw e;
  }
  const declared = entries.filter((d) => existsSync(join(root, d, 'release.json')));
  if (declared.length === 0) throw new NoReleaseDeclared(root);
  if (declared.length > 1) throw new Error(`${declared.length} releases are declared (${declared.join(', ')}); an INTAKE needs exactly one`);
  return declared[0]!;
}

/** Throws unless an INTAKE with this why could be queued now, so the filing is refused before anything is created. */
export function assertIntakeQueueable(why: string, o: IntakeWords & { toVersion?: string | null } = {}): void {
  const ctx = ctxFor(intakeRelease());
  refuseRequest(ctx, { verb: 'INTAKE', key: 'NEW', from_v: null, to_v: o.toVersion ?? null, why, origin: 'create', ticket: o.ticket, decision: o.decision });
  if (o.decision === undefined && o.words === undefined) return;
  if (o.decision === undefined) throw new Error('jira create: --words needs --decision <n>, the decision whose file holds them');
  if (o.words === undefined) throw new Error('jira create: --decision needs --words "<the operator\'s exact words>"');
  operatorFence(ctx);
  decisionWords(ctx, o.decision, o.words);
}

/** Refuses an unversioned Bug, Task or Story (a follow-up or residual too) whose INTAKE could not be queued; runs before the POST. */
export function preflightIntake(o: IntakeOptions, fields: Record<string, unknown>, title: string, testProject = false): void {
  if (intakeOwed(o.type, fields, testProject)) {
    assertIntakeQueueable(intakeWhy(o, title), { toVersion: toVersionOf(o), ticket: factsOf(fields), decision: o.decision, words: o.words });
  }
}

interface ParentState {
  fields: { project: { key: string }; status?: { name?: string; statusCategory?: { key?: string } }; fixVersions?: { name: string }[] };
}

/**
 * A follow-up of an open parent in the current version asks for that version;
 * the why states only facts (parent, status, version), plus the parent's
 * remainder when the caller declares it with --remainder. A Done or closed
 * parent asks for none and the why says so. The residual cap is
 * NOT checked: the request never writes the fixVersion, and the release
 * manager is not shown the cap. Parent, status and version go in the request's
 * evidence. Explicit wins: a version, --backlog, --proposed-version or --why
 * keeps its meaning. A parent with no current version, or one that cannot be
 * read, leaves the request as it was (the ticket is filed either way).
 */
export async function followUpIntake<T extends IntakeOptions & { followUpOf?: string; remainder?: boolean; backlog?: boolean; fixVersion?: string }>(o: T): Promise<T> {
  if (o.followUpOf === undefined || o.fixVersion !== undefined || o.backlog || o.proposedVersion !== undefined || o.why?.trim()) return o;
  const parentKey = o.followUpOf;
  let parent: ParentState['fields'];
  let versions: Awaited<ReturnType<typeof fetchVersions>>;
  try {
    parent = (await request<ParentState>('GET', `/issue/${parentKey}?fields=project,status,fixVersions`)).fields;
    versions = await fetchVersions(parent.project.key);
  } catch (e) {
    console.error(`jira: warning: could not read ${parentKey}'s status and version, so the follow-up's INTAKE names none: ${(e as Error).message}`);
    return o;
  }
  const status = parent.status?.name ?? 'unknown';
  const current = earliestUnreleased(versions);
  const inCurrent = current !== undefined && parent.fixVersions?.some((v) => v.name === current) === true;
  const evidence = {
    follow_up_of: parentKey, parent_status: status, parent_version: inCurrent ? current : null,
    ...(o.remainder ? { remainder: true } : {}),
  };
  if (parent.status?.statusCategory?.key === 'done') {
    return { ...o, why: `follow-up of ${parentKey}, which is closed (${status})`, evidence };
  }
  if (!inCurrent) return o;
  const isFrozen = frozenDate(versions.find((v) => v.name === current)?.description) !== undefined;
  const target = current;
  const facts = `follow-up of ${parentKey} (${status}), which is in ${current}${isFrozen ? ' (frozen)' : ''}`;
  const why = o.remainder ? `${facts}; ${parentKey} cannot close without this ticket, which holds its remainder` : facts;
  return { ...o, proposedVersion: target, why, evidence };
}

export function queueIntakeIfUnversioned(key: string, fields: Record<string, unknown>, title: string, o: IntakeOptions, testProject = false): void {
  if (!intakeOwed(o.type, fields, testProject)) return;
  try {
    queueBacklogIntake(key, intakeWhy(o, title), toVersionOf(o), true, o.evidence, { decision: o.decision, words: o.words, ticket: factsOf(fields), pointer: o.pointer });
  } catch (e) {
    console.error(
      `jira: PARTIAL: Created ${key} but INTAKE not queued: ${(e as Error).message}; still owed: the INTAKE request ` +
        `(jira release request <release> --verb INTAKE --key ${key} --why "<why>"). The ticket exists: do not re-run create.`,
    );
    process.exitCode = 1;
  }
}

/**
 * A ticket filed with no version waits in the backlog for the release
 * manager: queue an INTAKE request to the one declared release. Lenient
 * callers (edit's depth-2 drop) only warn, also when no release is declared;
 * strict ones rethrow so the caller can fail the run.
 */
export function queueBacklogIntake(
  key: string, why: string, toVersion: string | null = null, strict = false, evidence: Record<string, unknown> = {}, opts: IntakeWords = {},
): void {
  let release: string | undefined;
  try {
    release = intakeRelease();
    const ctx = ctxFor(release);
    refuseRequest(ctx, { verb: 'INTAKE', key, from_v: null, to_v: toVersion, why, origin: 'create', ticket: opts.ticket, decision: opts.decision });
    const row = { verb: 'INTAKE' as const, key, from_v: null, to_v: toVersion, why, evidence: { ...evidence, ...opts.pointer }, from: 'console' };
    if (opts.decision !== undefined && opts.words !== undefined) {
      const got = requestWithWords(ctx, row, { decision: opts.decision, words: opts.words });
      console.error(`jira: INTAKE queued for ${key} as REQ ${got.request.req} (release ${release}), citing the operator's words ${got.operator.id}`);
      return;
    }
    const r = releaseRequest(ctx, row);
    console.error(`jira: INTAKE queued for ${key} as REQ ${r.req} (release ${release})`);
  } catch (e) {
    if (strict) throw e;
    console.error(`jira: warning: INTAKE not queued for ${key} (release ${release ?? 'unknown'}): ${(e as Error).message}`);
  }
}


interface RelationshipOptions {
  blocks: string[];
  splitFrom?: string;
  blockedBy?: string;
  backlog?: boolean;
  fixVersion?: string;
}

async function inheritedFixVersion(o: RelationshipOptions): Promise<string | undefined> {
  if (o.backlog) return undefined;
  const targets = [...o.blocks, ...(o.splitFrom ? [o.splitFrom] : [])];
  let inherited: string | undefined;
  for (const target of targets) {
    const version = await targetFixVersion(target);
    if (version && ((inherited && inherited !== version) || (o.fixVersion && o.fixVersion !== version))) {
      throw new Error(`The blocker must carry fixVersion ${version} for ${target}; use --backlog to opt out`);
    }
    inherited = version ?? inherited;
  }
  return inherited;
}

export async function checkExistingBlocker(project: string, fixVersions: unknown, o: RelationshipOptions): Promise<void> {
  if (!o.blockedBy || o.backlog || !fixVersions) return;
  const current = earliestUnreleased(await fetchVersions(project));
  if (current && (fixVersions as { name: string }[]).some((v) => v.name === current)) {
    await requireBlockerVersion(o.blockedBy, current);
  }
}


/** Keep slot competition's decision; otherwise only ungated frozen inheritance is suppressed. */
export async function residualInheritedVersion(
  o: RelationshipOptions & { gate?: string },
  residual: ResidualPlan | undefined,
): Promise<string | undefined> {
  const inherited = await inheritedFixVersion(o);
  if (residual?.ranks !== undefined) return undefined;
  return residual && inherited && o.gate === undefined && residual.frozen.includes(inherited) ? undefined : inherited;
}

export async function displaceResidual(
  residual: ResidualPlan | undefined, newcomer: string, filed: { type: string; title: string },
): Promise<void> {
  if (!residual?.displaced) return;
  const displaced = residual.displaced;
  const resident = await request<RankedIssue>('GET', `/issue/${displaced.key}?fields=labels,status,fixVersions`);
  const source = residual.fixVersion!;
  const ruled = rulingsOf(source);
  if (ruled === undefined || ruled(displaced.key) || !resident.fields.fixVersions?.some((v) => v.name === source) ||
      resident.fields.status?.name !== 'To Do' || residualGateRank(resident, readAdmissions(source)) !== 0) {
    await request('PUT', `/issue/${newcomer}`, {
      fields: { fixVersions: displaced.fixVersion ? [{ name: displaced.fixVersion }] : [] },
      update: { labels: [{ add: 'residual-displaced' }] },
    }, 'create-stepdown');
    console.error(`jira: ${displaced.key} is no longer displaceable; ${newcomer} moved to ${displaced.fixVersion ?? 'the backlog'}`);
    // With no version to step down to the newcomer is versionless: it waits in the backlog for an INTAKE.
    if (!displaced.fixVersion) {
      queueIntakeIfUnversioned(newcomer, {}, filed.title, {
        type: filed.type, why: `lost its ${source} slot to a ruled ticket and has no version to step down to: ${filed.title}`,
      });
    }
    return;
  }
  const fixVersions = resident.fields.fixVersions.filter((v) => v.name !== source);
  if (displaced.fixVersion && !fixVersions.some((v) => v.name === displaced.fixVersion)) fixVersions.push({ name: displaced.fixVersion });
  await request('PUT', `/issue/${displaced.key}`, {
    fields: { fixVersions },
    update: { labels: [{ add: 'residual-displaced' }] },
  }, 'displace-residual');
  await request('POST', `/issue/${displaced.key}/comment`, {
    body: markdownToAdf(`Displaced by higher-ranked residual ${newcomer}; moved to ${displaced.fixVersion ?? 'the backlog'}.`),
  });
}

/** The journal name of the code path that chose a new ticket's Fix Version; undefined (hand) when the caller typed it or none was set. */
export function createWriterOf(
  options: { fixVersion?: string; residualOf?: string; followUpOf?: string },
  chose: { placed: boolean; inherited: string | undefined; residual: ResidualPlan | undefined; bugDefault: boolean },
): string | undefined {
  if (!chose.placed || options.fixVersion !== undefined) return undefined;
  if (chose.inherited !== undefined) {
    return options.residualOf !== undefined ? 'create-residual' : options.followUpOf !== undefined ? 'create-followup' : 'create-blocker-inherit';
  }
  if (chose.residual) return chose.residual.labels.includes('residual-displaced') ? 'create-stepdown' : 'create-residual';
  return chose.bugDefault ? 'create-bug-default' : undefined;
}

export function registerCreate(program: Command): void {
  program
    .command('create')
    .description('Create a Jira issue')
    .requiredOption('--type <type>', 'Issue type: Epic, Story, Task, Subtask')
    .option('--title <title>', 'Issue summary (required; alias: --summary)')
    .option(
      '--summary <summary>',
      "Issue summary — alias for --title (Jira's own field name). If both are given, --title wins.",
    )
    .option('--desc <desc>', 'Description (markdown supported)')
    .option(
      '--desc-file <path>',
      'Read the markdown description from a file (overrides --desc; keeps the ' +
        'shell command single-line for multi-line descriptions)',
    )
    .option('--adf-file <path>', 'Path to pre-built ADF JSON document (overrides --desc)')
    .option('--parent <key>', 'Parent issue key')
    .option('--blocks <key>', 'This new issue blocks <key>; inherit its active fixVersion (repeatable)', collect, [])
    .option('--split-from <key>', 'Split from <key>: inherit its active fixVersion and record a Relates link')
    .option('--blocked-by <key>', 'This new issue is blocked by <key>; check the existing blocker version before filing')
    .option('--labels <labels>', 'Comma-separated labels to set (e.g. a,b); `standalone` marks a ticket with no parent epic')
    .option('--sector <s>', 'Sector (single-select custom field; required for a Task, Story or Bug once JIRA_SECTOR_FIELD is set)')
    .option(
      '--fix-version <name>',
      "Set the fixVersion (validated against the project's versions; an explicit value wins over the Bug default of the earliest unreleased version)",
    )
    .option('--priority <name>', 'Priority name (e.g. Highest); a Highest Bug is placed in the active version')
    .option('--backlog', 'File to the backlog: label backlog, no inherited fixVersion; needs --proposed-version backlog and --why. Queues an INTAKE request when one release is declared')
    .option(
      '--proposed-version <v>',
      'A Bug, Task or Story without --fix-version is filed with a proposed version (label proposed-<v>) and its INTAKE request queued in the same call; `backlog` needs --backlog and --why',
    )
    .option('--why <why>', 'One line: why the ticket waits in the backlog (required with --backlog); the INTAKE request carries it')
    .option('--decision <n>', 'The operator decision that places an operator-directed or High ticket into a version (its specs/decisions verbatim file); needs --words')
    .option('--words <text>', 'The operator\'s exact words in that decision file; recorded as an O- record the INTAKE request cites')
    .option(
      '--operator-update <update_id>',
      "Telegram bridge only: the operator's update that asked for this filing, recorded in the INTAKE evidence; needs --proposed-version <v> and the poller's DM chat stamp",
      parseOperatorUpdate,
    )
    .option(
      '--gate <reason>',
      'Why this may enter a version (' + INTAKE_GATES + '): a Bug without --fix-version goes to the earliest unreleased version, and a frozen version takes nothing without it',
    )
    .option(
      '--chief-override <reason>',
      'Chief only (HIMMEL_CONSOLE=1): file into --fix-version with a reason, recorded in the admissions ledger',
    )
    .option(
      '--affects-version <name>',
      "Set the affectsVersion (validated against the project's versions; `current` = the earliest unreleased version)",
    )
    .option(
      '--residual-of <key>',
      'File this as a review residual of <key>: the writer picks the version, depth and labels (needs --fu-class; --class is optional)',
    )
    .option(
      '--follow-up-of <key>',
      "File this as a follow-up of <key>: stamps the residual label and links it to <key>. With no version of its own, its INTAKE asks for <key>'s current version (an open parent; a Done parent gets none) and states parent, status and version",
    )
    .option(
      '--remainder',
      "With --follow-up-of: this ticket holds the parent's remainder (a deferred DoD row), so the INTAKE says the parent cannot close without it",
    )
    .option(
      '--over-cap <reason>',
      'File into the current version although it is at its residual cap; the reason is recorded on the ticket',
    )
    .option('--fu-class <class>', 'Residual class: escape (current, else next when frozen), hardening (its chain version, else next at High or above, else backlog; needs --fu-override). polish is refused: note it in the PR body')
    .option('--fu-why <code>', 'Why a hardening residual is one (' + FU_WHY_CODES.join('|') + '); required with --fu-class hardening')
    .option('--fu-override <id>', 'The named override a hardening residual needs: a judge verdict id (XX-jNNNN-N) or decision-N; printed into the ticket as an unverified label')
    .option('--class <id>', 'Residual class id, stamped as the class-<id> label')
    .option('--area <name>', 'Residual area; an open residual with the same class and area is commented on instead of filing a new one')
    .option('--project <key>', 'Project key (default: JIRA_PROJECT_KEY env var)')
    .option('--change-class <class>', 'rename or bulk: a mechanical change touching a core path adds no core label and prints core-review for the chief')
    .option('--attach <path>', 'File to attach (repeatable)', collect, [])
    .option(
      '--skeleton',
      'Print the seven-section body (Impact, What, Why, Plan, DoD, Proof, Agent detail) to fill, then exit; creates nothing',
    )
    .action(
      async (options: CreateOptions & { skeleton?: boolean; operatorUpdate?: number }) => {
        if (options.skeleton) {
          console.log(PLAIN_BLOCK_TEMPLATE);
          return;
        }
        try {
          const withPointer: CreateOptions & { pointer?: BridgePointer } = { ...options, pointer: bridgePointer(options) };
          await runCreate(withPointer);
        } catch (e) {
          if (!(e instanceof CreateRefused || e instanceof CreatePartial)) throw e;
          console.error(e.message);
          process.exit(1);
        }
      },
    );
}
