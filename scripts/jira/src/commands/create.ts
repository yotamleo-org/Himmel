import { readFileSync } from 'node:fs';
import type { Command } from 'commander';
import { request, projectKey } from '../client.js';
import { writeJiraBreadcrumb } from '../breadcrumb.js';
import { markdownToAdf } from '../adf.js';
import type { CreateIssueResponse } from '../types.js';
import { uploadAll } from './attach-helper.js';
import { readBodyFile } from './body-file.js';
import { parseLabels } from './labels.js';
import { homeVerdict, lintPlainBlock, lintPlainBlockAdf, plainBlockVerdict, titleVerdict, PLAIN_BLOCK_TEMPLATE } from '../plain-block.js';
import { resolveSector, sectorField, sectorOptions } from './sector.js';
import { searchAllIssues } from './list.js';
import { createIssueLink, requireBlockerVersion, targetFixVersion } from './link.js';
import { appendAdmission, readAdmissions, type Admission, type AdmissionInput } from './admissions-ledger.js';
import { assertIntakeGate, checkConsoleOverride, checkIntakeGate, frozenDate, INTAKE_GATES } from './intake-gate.js';
import { assertVersionExists, earliestUnreleased, fetchVersions, resolveAffectsVersion } from './versions.js';

function collect(value: string, prev: string[]): string[] {
  return [...prev, value];
}

/**
 * Jira's REST field is `summary`; the CLI's long-standing flag is `--title`
 * (matches `edit --title`). `--summary` is accepted as an alias since that's
 * the literal Jira field name and the natural reach for anyone who knows the
 * API. If both are given, `--title` wins — it's the documented flag, so this
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

const FU_CLASSES = ['polish', 'escape', 'hardening'];
export const FU_WHY_CODES = ['unseen-failure', 'no-check', 'vacuous-check', 'no-recovery', 'silent-rot'];
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

interface ResidualPlan {
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
  const ledger = readAdmissions(version);
  const rank = (i: RankedIssue, targets: string[], gate: number, sector: string | undefined): number[] => {
    const ls = i.fields.labels ?? [];
    const created = Date.parse(i.fields.created ?? '');
    return [gate, ls.includes('fu-escape') ? 2 : ls.includes('fu-hardening') ? 1 : 0,
      PRIORITY_RANK.indexOf(i.fields.priority?.name ?? 'Medium') + 1,
      Number(targets.some((key) => openHead(key) !== undefined)), Number(sector !== undefined && sharedSectors.has(sector)),
      Number.isFinite(created) ? -created : 0];
  };
  const newcomer = rank({ key: '', fields: { labels, priority: { name: o.priority ?? 'Medium' }, created: new Date().toISOString() } },
    newcomerLinks, GATE_RANK.indexOf(o.gate?.split(':')[0] ?? '') + 1, o.sector);
  const candidates = residents.filter((i) => i.fields?.status?.name === 'To Do' && residualGateRank(i, ledger) === 0)
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
  if (o.fixVersion !== undefined) throw new Error('--residual-of chooses the version itself; drop --fix-version');
  const classLabel = o.class !== undefined ? `class-${labelSlug(o.class)}` : undefined;
  const labels = ['residual', `fu-${o.fuClass}`];
  if (o.gate !== undefined) labels.push(`gate-${o.gate.split(':')[0]}`);
  if (o.fuClass === 'hardening') labels.push(`fu-why-${o.fuWhy}`);
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
async function applyVersions(
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
            (st.next ? `the Bug goes to ${st.next}` : 'no later version, filing the Bug with no fixVersion') +
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
      console.error(`jira: Bug defaults to fixVersion ${defaultVersion}; --fix-version overrides`);
    } else {
      console.error('jira: no unreleased version found; filing the Bug with no fixVersion');
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
  consoleOverride?: string;
  sector?: string;
}

/** Checks the gate, backlog and console-override flags before anything is filed; returns the override reason. */
function checkPlacementFlags(o: PlacementOptions): string | undefined {
  if (o.gate !== undefined) assertIntakeGate(o.gate);
  if (o.backlog && (o.gate !== undefined || o.fixVersion !== undefined)) {
    throw new Error('--backlog cannot be combined with --gate or --fix-version');
  }
  if (o.consoleOverride === undefined) return undefined;
  const reason = checkConsoleOverride(o.consoleOverride);
  if (o.fixVersion === undefined) throw new Error('--console-override needs the --fix-version to admit into');
  return reason;
}

/**
 * A Bug is placed at filing: Highest or gated takes the active version
 * (bugDefault), --backlog the backlog; with neither it is refused rather than
 * defaulted silently.
 */
function placeBug(
  o: PlacementOptions,
  labels: string[] | undefined,
  residual: boolean,
): { labels: string[] | undefined; bugDefault: boolean } {
  if (o.type.toLowerCase() !== 'bug' || residual || o.fixVersion !== undefined) return { labels, bugDefault: false };
  if (o.backlog) return { labels: [...new Set([...(labels ?? []), BACKLOG_LABEL])], bugDefault: false };
  if (o.gate !== undefined || o.priority?.toLowerCase() === 'highest') return { labels, bugDefault: true };
  throw new Error(
    'A Bug needs a placement (sector: ' + (o.sector ?? 'none given') + '): pass --backlog to file it to the backlog, ' +
      'or --fix-version <v> / --gate critical|regression / --priority Highest to file it into a version',
  );
}

function recordAdmission(key: string, row: Omit<AdmissionInput, 'key'>): void {
  try {
    appendAdmission({ ...row, key });
  } catch (e) {
    console.error(`Created ${key} but writing the admissions ledger row failed: ${(e as Error).message}`);
    process.exit(1);
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

async function checkExistingBlocker(project: string, fixVersions: unknown, o: RelationshipOptions): Promise<void> {
  if (!o.blockedBy || o.backlog || !fixVersions) return;
  const current = earliestUnreleased(await fetchVersions(project));
  if (current && (fixVersions as { name: string }[]).some((v) => v.name === current)) {
    await requireBlockerVersion(o.blockedBy, current);
  }
}

async function linkCreatedIssue(key: string, o: RelationshipOptions): Promise<void> {
  const relationships = o.blocks.map((other) => ({ inward: key, outward: other, type: { name: 'Blocks', outward: 'blocks' } }));
  if (o.splitFrom) relationships.push({ inward: key, outward: o.splitFrom, type: { name: 'Relates', outward: 'relates to' } });
  if (o.blockedBy) relationships.push({ inward: o.blockedBy, outward: key, type: { name: 'Blocks', outward: 'blocks' } });
  for (const { inward, outward, type } of relationships) {
    try {
      await createIssueLink(inward, outward, type);
    } catch (e) {
      console.error(`Created ${key} but linking ${inward} to ${outward} failed: ${(e as Error).message}`);
      process.exit(1);
    }
  }
}

async function residualInheritedVersion(o: RelationshipOptions, residual: ResidualPlan | undefined): Promise<string | undefined> {
  return residual ? undefined : inheritedFixVersion(o);
}

async function displaceResidual(residual: ResidualPlan | undefined, newcomer: string): Promise<void> {
  if (!residual?.displaced) return;
  const displaced = residual.displaced;
  const resident = await request<RankedIssue>('GET', `/issue/${displaced.key}?fields=labels,status,fixVersions`);
  const source = residual.fixVersion!;
  if (!resident.fields.fixVersions?.some((v) => v.name === source) ||
      resident.fields.status?.name !== 'To Do' || residualGateRank(resident, readAdmissions(source)) !== 0) {
    await request('PUT', `/issue/${newcomer}`, {
      fields: { fixVersions: displaced.fixVersion ? [{ name: displaced.fixVersion }] : [] },
      update: { labels: [{ add: 'residual-displaced' }] },
    });
    console.error(`jira: ${displaced.key} is no longer displaceable; ${newcomer} moved to ${displaced.fixVersion ?? 'the backlog'}`);
    return;
  }
  const fixVersions = resident.fields.fixVersions.filter((v) => v.name !== source);
  if (displaced.fixVersion && !fixVersions.some((v) => v.name === displaced.fixVersion)) fixVersions.push({ name: displaced.fixVersion });
  await request('PUT', `/issue/${displaced.key}`, {
    fields: { fixVersions },
    update: { labels: [{ add: 'residual-displaced' }] },
  });
  await request('POST', `/issue/${displaced.key}/comment`, {
    body: markdownToAdf(`Displaced by higher-ranked residual ${newcomer}; moved to ${displaced.fixVersion ?? 'the backlog'}.`),
  });
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
    .option('--backlog', 'File to the backlog: label backlog, no inherited fixVersion (also places a Bug without --fix-version)')
    .option(
      '--gate <reason>',
      'Why this may enter a version (' + INTAKE_GATES + '): a Bug without --fix-version goes to the earliest unreleased version, and a frozen version takes nothing without it',
    )
    .option(
      '--console-override <reason>',
      'Console only (HIMMEL_CONSOLE=1): file into --fix-version with a reason, recorded in the admissions ledger',
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
      'File this as a follow-up of <key>: stamps the residual label and links it to <key>',
    )
    .option(
      '--over-cap <reason>',
      'File into the current version although it is at its residual cap; the reason is recorded on the ticket',
    )
    .option('--fu-class <class>', 'Residual class: polish (backlog), escape (current, else next when frozen), hardening (its chain version, else next at High or above, else backlog)')
    .option('--fu-why <code>', 'Why a hardening residual is one (' + FU_WHY_CODES.join('|') + '); required with --fu-class hardening')
    .option('--class <id>', 'Residual class id, stamped as the class-<id> label')
    .option('--area <name>', 'Residual area; an open residual with the same class and area is commented on instead of filing a new one')
    .option('--project <key>', 'Project key (default: JIRA_PROJECT_KEY env var)')
    .option('--attach <path>', 'File to attach (repeatable)', collect, [])
    .option(
      '--skeleton',
      'Print the four-heading body (Impact, What, Why, Agent detail) to fill, then exit; creates nothing',
    )
    .action(
      async (options: {
        skeleton?: boolean;
        type: string;
        title?: string;
        summary?: string;
        desc?: string;
        descFile?: string;
        adfFile?: string;
        parent?: string;
        blocks: string[];
        splitFrom?: string;
        blockedBy?: string;
        labels?: string;
        sector?: string;
        fixVersion?: string;
        priority?: string;
        backlog?: boolean;
        gate?: string;
        consoleOverride?: string;
        affectsVersion?: string;
        residualOf?: string;
        followUpOf?: string;
        overCap?: string;
        fuClass?: string;
        fuWhy?: string;
        class?: string;
        area?: string;
        project?: string;
        attach: string[];
      }) => {
        if (options.skeleton) {
          console.log(PLAIN_BLOCK_TEMPLATE);
          return;
        }
        if (options.followUpOf !== undefined && options.residualOf !== undefined) {
          throw new Error('--follow-up-of cannot be combined with --residual-of (a residual is already linked to its parent)');
        }
        if (options.overCap !== undefined && !options.overCap.trim()) {
          throw new Error('--over-cap needs a reason');
        }
        const overrideReason = checkPlacementFlags(options);
        const fields: Record<string, unknown> = {
          project: { key: options.project ?? projectKey() },
          summary: resolveTitle(options),
          issuetype: { name: options.type },
        };
        if (options.priority !== undefined) fields['priority'] = { name: options.priority };
        let found: string[];
        if (options.adfFile) {
          let adfBody: unknown;
          try {
            adfBody = JSON.parse(readFileSync(options.adfFile, 'utf8'));
          } catch (e) {
            console.error(`jira: cannot read --adf-file "${options.adfFile}": ${(e as Error).message}`);
            process.exit(1);
          }
          fields['description'] = adfBody;
          found = lintPlainBlockAdf(adfBody);
        } else if (options.descFile) {
          const md = readBodyFile(options.descFile, '--desc-file');
          fields['description'] = markdownToAdf(md);
          found = lintPlainBlock(md);
        } else if (options.desc) {
          fields['description'] = markdownToAdf(options.desc);
          found = lintPlainBlock(options.desc);
        } else {
          found = lintPlainBlock('');
        }
        // The plain Impact/What/Why block is required; Epic and Subtask only warn.
        const verdict = plainBlockVerdict(options.type, found);
        if (verdict.action === 'refuse') {
          console.error(verdict.message);
          process.exit(1);
        }
        if (verdict.action === 'warn') console.error(verdict.message);
        // Sectors are opt-in: with JIRA_SECTOR_FIELD unset there is no Sector check and none is sent.
        const sectorId = sectorField();
        const sectors = sectorId ? await sectorOptions() : undefined;
        const titleCheck = titleVerdict(options.type, resolveTitle(options), sectors);
        if (titleCheck.action === 'warn') console.error(titleCheck.message);
        if (options.sector !== undefined && !sectors) {
          console.error('jira: warning: --sector ignored, Sector is not configured (run `jira sector setup`)');
        }
        const sector =
          options.sector !== undefined && sectors ? resolveSector(options.sector, sectors) : undefined;
        let labels = options.labels !== undefined ? parseLabels(options.labels) : undefined;
        let residual: ResidualPlan | undefined;
        if (options.residualOf !== undefined) {
          residual = await planResidual(options.project ?? projectKey(), { ...options, sector, residualOf: options.residualOf });
          if (residual.duplicateOf) {
            const dup = residual.duplicateOf;
            const head = markdownToAdf(`Re-raised as a residual of ${options.residualOf}: ${resolveTitle(options)}`);
            const detail = (fields['description'] as { content?: unknown[] } | undefined)?.content ?? [];
            await request('POST', `/issue/${dup}/comment`, { body: { ...head, content: [...head.content, ...detail] } });
            await createIssueLink(dup, options.residualOf, { name: 'Relates', inward: 'relates to' });
            console.log(`Duplicate ${dup}`);
            return;
          }
          labels = [...new Set([...(labels ?? []), ...residual.labels])];
        }
        if (options.followUpOf !== undefined) labels = [...new Set([...(labels ?? []), 'residual'])];
        const inherited = await residualInheritedVersion(options, residual);
        const versionOptions = { ...options, fixVersion: inherited ?? options.fixVersion };
        if (options.backlog) labels = [...new Set([...(labels ?? []), BACKLOG_LABEL])];
        const placed = placeBug(versionOptions, labels, residual !== undefined);
        labels = placed.labels;
        // A Sector (when configured) plus an epic or the standalone label; Epic and Subtask only warn.
        const home = homeVerdict(options.type, { sector, parent: options.parent, labels }, sectors);
        if (home.action === 'refuse') {
          console.error(home.message);
          process.exit(1);
        }
        if (home.action === 'warn') console.error(home.message);
        if (options.parent) fields['parent'] = { key: options.parent };
        if (labels) fields['labels'] = labels;
        if (sector && sectorId) fields[sectorId] = { value: sector };
        if (residual) {
          if (residual.fixVersion) fields['fixVersions'] = [{ name: residual.fixVersion }];
          if (residual.affectsVersion) fields['versions'] = [{ name: residual.affectsVersion }];
          console.error(`jira: residual routed to ${inherited ?? residual.fixVersion ?? 'the backlog'}`);
        }
        const overCapReason = await applyVersions(options.project ?? projectKey(), versionOptions, fields, {
          labels,
          residual: residual !== undefined && inherited === undefined,
          bugDefault: placed.bugDefault,
        });
        const admission = await checkIntakeGate(options.project ?? projectKey(), fields['fixVersions'], {
          gate: options.gate,
          override: overrideReason !== undefined,
        });

        await checkExistingBlocker(options.project ?? projectKey(), fields['fixVersions'], options);

        const result = await request<CreateIssueResponse>('POST', '/issue', { fields });
        // Breadcrumb BEFORE attachments (same rationale as comment): the issue
        // exists even if a later attachment upload fails.
        writeJiraBreadcrumb(result.key);

        // Print the issue key to STDOUT immediately on success, BEFORE
        // attempting attachments. Scripted callers like
        //   KEY=$(jira create ... --attach foo)
        // capture stdout — if attachments fail and we exit 1, the key
        // has already been emitted so the caller still has it. The
        // attachment-failure message goes to stderr.
        console.log(`Created ${result.key}`);
        if (overrideReason !== undefined) {
          recordAdmission(result.key, { version: options.fixVersion!, kind: 'override', reason: overrideReason });
        }
        if (admission) recordAdmission(result.key, admission);
        await displaceResidual(residual, result.key);
        // The reason is recorded first so a failed link cannot leave an over-cap ticket unexplained.
        if (overCapReason) {
          try {
            await request('POST', `/issue/${result.key}/comment`, { body: markdownToAdf(overCapReason) });
          } catch (e) {
            console.error(`Created ${result.key} but recording the over-cap reason failed: ${(e as Error).message}`);
            process.exit(1);
          }
        }
        const parentKey = options.residualOf ?? options.followUpOf;
        if (parentKey) {
          try {
            await createIssueLink(result.key, parentKey, { name: 'Relates', inward: 'relates to' });
          } catch (e) {
            console.error(`Created ${result.key} but linking to ${parentKey} failed: ${(e as Error).message}`);
            process.exit(1);
          }
        }

        await linkCreatedIssue(result.key, options);

        const attachments = options.attach ?? [];
        if (attachments.length === 0) return;
        try {
          const n = await uploadAll(result.key, attachments);
          console.error(`  attachments: ${n}`);
        } catch (e) {
          console.error(`Created ${result.key} but attachment failed: ${(e as Error).message}`);
          process.exit(1);
        }
      },
    );
}
