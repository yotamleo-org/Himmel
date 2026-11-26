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
import { resolveSector, sectorField, sectorOf } from './sector.js';
import { adfToPlainText, type ADFDocument } from '../adf-render.js';
import { searchAllIssues } from './list.js';
import { createIssueLink, requireBlockerVersion, targetFixVersion } from './link.js';
import { appendAdmission, type AdmissionInput } from './admissions-ledger.js';
import { assertIntakeGate, checkConsoleOverride, checkIntakeGate, chiefOverrideOf, frozenDate, INTAKE_GATES } from './intake-gate.js';
import { assertVersionExists, earliestUnreleased, fetchVersions, resolveAffectsVersion } from './versions.js';
import { ctxFor, refuseRequest, refuseTestJiraPost } from './release.js';
import { decisionWords, operatorDecision, operatorFence, releaseForProject, request as releaseRequest, requestWithWords } from '../release/engine.js';
import type { TicketFacts } from '../release/operator-work.js';
import { loadOrThrow } from '../release/engine-core.js';
import { currentFrozen, placeByRules, ticketFromCreate, type Placement, type ReleaseIn } from '../release/filing-rules.js';
import { releaseRoot } from '../release/paths.js';
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
 */
const FU_OVERRIDE_SHAPE = /^(decision-[0-9]+|[A-Z]{2}-j[0-9]+-[0-9]+)$/;
const POLISH_REFUSAL =
  'a polish residual is not filed (decisions 746, 762): it is noted with no ticket (on a Jira repo review-round.sh defer and file-deferred-issues.sh record it as a polish-noted comment on the PR ticket; ' +
  'on a local or none repo note it in the PR body), or file it as a plain ticket (jira create without --residual-of) if someone will really work it, ' +
  'then link it from the PR ticket with `jira link <PR ticket> <plain ticket>` so it can be named as a deferral';
/** A hardening residual prints its named override into the ticket description. */
export function appendFuOverride(fields: Record<string, unknown>, override: string | undefined): void {
  if (override === undefined) return;
  const named = markdownToAdf(`fu-override: ${override}`);
  const body = fields['description'] as { content?: unknown[] } | undefined;
  if (body?.content) body.content.push(...named.content);
  else fields['description'] = named;
}
const jqlQuote = (s: string): string => `"${s.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
const labelSlug = (s: string): string => s.trim().replace(/\s+/g, '-');

/** Residual depth of a new ticket: its parent's residual-depth-N label plus one (0 when the parent has none). */
export function nextResidualDepth(parentLabels: string[]): number {
  const depths = parentLabels.map((l) => /^residual-depth-(\d+)$/.exec(l)).filter((m) => m !== null).map((m) => Number(m![1]));
  return Math.max(0, ...depths) + 1;
}

export const BACKLOG_LABEL = 'backlog';

export interface ResidualPlan {
  labels: string[];
  fixVersion?: string;
  affectsVersion?: string;
  duplicateOf?: string;
  frozen: string[];
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

interface ParentIssue {
  fields: TicketState & { labels?: string[] };
}

/**
 * Places a residual. A residual of a project a declared release names is placed
 * by the rules at filing (placeByRules, from runCreate): this writes no version
 * for it, and keeps a filing-time version only under --gate must|receipt (the
 * current version); --gate critical|regression goes to the rules, which only
 * propose for a residual. For a project no declaration names, the first matching
 * row wins: a. depth >= 2, b. polish: backlog. c. --gate must|receipt: current. d. escape: current if unfrozen, else
 * next. e. hardening with a chain: its version V if unfrozen, else next.
 * f. hardening, no chain, High or above: next. g. anything else: backlog. Next
 * is the earliest unreleased version after current. It never throws on a
 * frozen version; a frozen or missing next sends the residual to the backlog.
 * When the declarations cannot be read it prints one line and uses those rows.
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

  const parent = await request<ParentIssue>(
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
  const declared = releaseForProject(process.env, project);
  if (declared === 'unreadable') {
    console.error(`jira: warning: the release declarations naming ${project} cannot be read, so the residual is routed by class, not placed by the door`);
  }
  const doorPlaces = declared !== 'unreadable' && declared.length > 0;

  let fixVersion: string | undefined;
  if (current && depth < 2 && o.fuClass !== 'polish') {
    if (o.gate === 'receipt' || o.gate?.startsWith('must:')) {
      fixVersion = current;
    } else if (doorPlaces || o.gate !== undefined) {
      fixVersion = undefined;
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
  return { labels, affectsVersion: current, frozen, fixVersion };
}

export async function applyVersions(
  project: string,
  options: { type: string; fixVersion?: string; affectsVersion?: string },
  fields: Record<string, unknown>,
  o: { bugDefault: boolean },
): Promise<void> {
  if (options.fixVersion !== undefined) {
    await assertVersionExists(project, options.fixVersion);
    fields['fixVersions'] = [{ name: options.fixVersion }];
  }
  if (options.affectsVersion !== undefined) {
    const version = await resolveAffectsVersion(project, options.affectsVersion);
    fields['versions'] = [{ name: version }];
  }
  if (o.bugDefault) {
    let defaultVersion: string | undefined;
    try {
      defaultVersion = earliestUnreleased(await fetchVersions(project));
    } catch {
      defaultVersion = undefined;
    }
    // stderr: stdout stays the bare `Created KEY` line scripted callers capture.
    if (defaultVersion) fields['fixVersions'] = [{ name: defaultVersion }];
    if (defaultVersion) {
      console.error(`jira: ${options.type} defaults to fixVersion ${defaultVersion}; --fix-version overrides`);
    } else {
      console.error(`jira: no unreleased version found; filing the ${options.type} with no fixVersion`);
    }
  }
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
  labels?: string;
  decision?: string;
  operatorUpdate?: number;
}

/** The label a proposed version leaves on the ticket until the release manager confirms or moves it. */
const proposedLabel = (v: string): string => `proposed-${labelSlug(v)}`;

function assertBacklogDecision(o: PlacementOptions): void {
  if (o.decision !== undefined || !/^(bug|task|story)$/i.test(o.type)) return;
  const highBug = /^bug$/i.test(o.type) && /^(high|highest|critical|blocker)$/i.test(o.priority ?? '');
  const labels = (o.labels === undefined ? [] : parseLabels(o.labels)).map((l) => l.toLowerCase());
  if (highBug || labels.includes('security')) {
    throw new Error(`a High or security ${o.type} enters the backlog only by an operator decision: pass --decision <n> --words "<the operator's words>", or place it in a version (--fix-version, --proposed-version <v>, --gate)`);
  }
  if (labels.includes('operator-directed') || o.operatorUpdate !== undefined) {
    throw new Error(`an operator ask enters the backlog only by the operator's words (rule 1, their explicit "later"): pass --decision <n> --words "<the operator's words>", or drop --backlog and let the rules place it`);
  }
}

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
    assertBacklogDecision(o);
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
 * A Bug, Task or Story with no explicit placement is placed by the rules (placeByRules, called from runCreate).
 * This places only --backlog (the label backlog, no INTAKE) and --gate must|receipt, which keep the version-writing
 * path (bugDefault). --fix-version, a residual's own version and a blocker's inherited version place the ticket before
 * the rules run.
 */
export function placeAtFiling(
  o: PlacementOptions,
  labels: string[] | undefined,
  residual: boolean,
  testProject = false,
): { labels: string[] | undefined; bugDefault: boolean } {
  const type = o.type.toLowerCase();
  if ((type !== 'bug' && type !== 'task' && type !== 'story') || residual || testProject || o.fixVersion !== undefined) return { labels, bugDefault: false };
  if (o.backlog) return { labels: [...new Set([...(labels ?? []), BACKLOG_LABEL])], bugDefault: false };
  return { labels, bugDefault: o.gate === 'receipt' || o.gate?.startsWith('must:') === true };
}

const intakeWhy = (o: { why?: string; proposedVersion?: string }, title: string): string => {
  const proposed = o.proposedVersion !== undefined && o.proposedVersion !== 'backlog' ? `proposed for ${o.proposedVersion}` : 'filed to the backlog';
  return o.why?.trim() || `${proposed}: ${title}`;
};
export const intakeOwed = (type: string, fields: Record<string, unknown>, testProject = false, proposal = false): boolean =>
  proposal && !testProject && !fields['fixVersions'] && /^(bug|task|story)$/i.test(type);

export interface BridgePointer { operator_update: number; filed_by: 'bridge'; bridge_chat: number }

interface IntakeOptions {
  type: string;
  proposedVersion?: string;
  why?: string;
  evidence?: Record<string, unknown>;
  decision?: string;
  words?: string;
  pointer?: BridgePointer;
  proposal?: boolean;
}

type IntakeWords = { decision?: string; words?: string; ticket?: TicketFacts; pointer?: BridgePointer };

const toVersionOf = (o: { proposedVersion?: string }): string | null =>
  o.proposedVersion === undefined || o.proposedVersion === 'backlog' ? null : o.proposedVersion;

export function parseOperatorUpdate(v: string): number {
  if (!/^\d+$/.test(v) || !Number.isSafeInteger(Number(v))) throw new InvalidArgumentError('the Telegram update_id, digits only');
  return Number(v);
}

export function bridgePointer(
  o: { operatorUpdate?: number; type: string; fixVersion?: string; backlog?: boolean; proposedVersion?: string; project?: string },
): BridgePointer | undefined {
  if (o.operatorUpdate === undefined) return undefined;
  const env = process.env;
  const refuse = (why: string) => new CreateRefused(`jira create: --operator-update refused, nothing was filed: ${why}`);
  if (env['HIMMEL_BRIDGE_SESSION'] !== '1') {
    throw refuse('only a Telegram bridge session (HIMMEL_BRIDGE_SESSION=1) names the operator\'s update');
  }
  if (env['HIMMEL_CONSOLE_LEG'] === '1' || env['HIMMEL_RELEASE_MANAGER'] === '1') {
    throw refuse('a chief-spawned worker or the release manager never names the operator\'s update');
  }
  if (o.fixVersion !== undefined) throw refuse('the pointer rides on a rules placement; drop --fix-version');
  if (o.backlog) throw refuse('the pointer rides on a rules placement; drop --backlog');
  if (!/^(bug|task|story)$/i.test(o.type) || isTestProject(o.project ?? projectKey())) {
    throw refuse('the pointer rides on a rules placement, and an Epic, a Subtask or a test project is placed by no rule');
  }
  const stamp = ancestorValue('HIMMEL_BRIDGE_SESSION') === '1' ? ancestorValue('HIMMEL_BRIDGE_CHAT') : null;
  if (!/^[1-9]\d*$/.test(stamp ?? '')) {
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
  loadOrThrow(ctx);
  refuseRequest(ctx, { verb: 'INTAKE', key: 'NEW', from_v: null, to_v: o.toVersion ?? null, why, origin: 'create', ticket: o.ticket, decision: o.decision });
  if (o.decision === undefined && o.words === undefined) return;
  if (o.decision === undefined) throw new Error('jira create: --words needs --decision <n>, the decision whose file holds them');
  if (o.words === undefined) throw new Error('jira create: --decision needs --words "<the operator\'s exact words>"');
  operatorFence(ctx);
  decisionWords(ctx, o.decision, o.words);
}

/** Refuses an unversioned Bug, Task or Story (a follow-up or residual too) whose INTAKE could not be queued; runs before the POST. */
export function preflightIntake(o: IntakeOptions, fields: Record<string, unknown>, title: string, testProject = false): void {
  if (intakeOwed(o.type, fields, testProject, o.proposal)) {
    assertIntakeQueueable(intakeWhy(o, title), { toVersion: toVersionOf(o), ticket: factsOf(fields), decision: o.decision, words: o.words });
  }
}

interface ParentState {
  fields: { project: { key: string }; status?: { name?: string; statusCategory?: { key?: string } }; fixVersions?: { name: string }[]; priority?: { name?: string } };
}

export interface FollowUpParent {
  key: string;
  status: string;
  done: boolean;
  versions: string[];
  priority?: string;
  current?: string;
  frozen: boolean;
}

export async function readFollowUpParent(key: string): Promise<FollowUpParent> {
  try {
    const parent = (await request<ParentState>('GET', `/issue/${key}?fields=project,status,fixVersions,priority`)).fields;
    const versions = await fetchVersions(parent.project.key);
    const current = earliestUnreleased(versions);
    return {
      key,
      status: parent.status?.name ?? 'unknown',
      done: parent.status?.statusCategory?.key === 'done',
      versions: (parent.fixVersions ?? []).map((v) => v.name),
      ...(parent.priority?.name ? { priority: parent.priority.name } : {}),
      ...(current !== undefined ? { current } : {}),
      frozen: frozenDate(versions.find((v) => v.name === current)?.description) !== undefined,
    };
  } catch (e) {
    throw new CreateRefused(`jira create: ${key} cannot be read, so its follow-up cannot be placed; retry, or pass --fix-version <v> (${(e as Error).message})`);
  }
}

/**
 * The INTAKE facts for a follow-up whose placement is a proposal: the why states only facts (parent, status,
 * version), plus the parent's remainder when the caller declares it with --remainder; a Done parent says so.
 * Parent, status and version go in the evidence. Which version it proposes is the rules' call (rule P), not this
 * function's. An explicit --why or --proposed-version keeps its meaning and the evidence carries only the parent
 * and its remainder.
 */
export function followUpIntake<T extends IntakeOptions & { followUpOf?: string; residualOf?: string; remainder?: boolean; backlog?: boolean; fixVersion?: string }>(o: T, p?: FollowUpParent): T {
  if (o.residualOf !== undefined && o.followUpOf === undefined && o.fixVersion === undefined && o.evidence === undefined) {
    return { ...o, evidence: { residual_of: o.residualOf } };
  }
  if (p === undefined || hasOwnPlacement(o)) {
    return o.followUpOf !== undefined && o.remainder ? { ...o, evidence: { ...o.evidence, follow_up_of: o.followUpOf, remainder: true } } : o;
  }
  const inCurrent = p.current !== undefined && p.versions.includes(p.current);
  const evidence = {
    follow_up_of: p.key, parent_status: p.status, parent_version: inCurrent ? p.current : null,
    ...(o.remainder ? { remainder: true } : {}),
  };
  if (p.done) return { ...o, why: `follow-up of ${p.key}, which is closed (${p.status})`, evidence };
  if (!inCurrent) return o.remainder ? { ...o, evidence } : o;
  return { ...o, why: `follow-up of ${p.key} (${p.status}), which is in ${p.current}${p.frozen ? ' (frozen)' : ''}`, evidence };
}

type PlacementChoice = { followUpOf?: string; fixVersion?: string; backlog?: boolean; proposedVersion?: string; why?: string };
const hasOwnPlacement = (o: PlacementChoice): boolean => o.followUpOf === undefined || o.fixVersion !== undefined || !!o.backlog || o.proposedVersion !== undefined || !!o.why?.trim();

export function closedParentPlacement(o: PlacementChoice & { type: string }, p: FollowUpParent | undefined): { fixVersion: string; priority?: string } | undefined {
  if (p === undefined || hasOwnPlacement(o) || !/^(bug|task|story)$/i.test(o.type)) return undefined;
  if (!p.done || p.current === undefined || !p.versions.includes(p.current) || p.frozen) return undefined;
  return { fixVersion: p.current, ...(p.priority ? { priority: p.priority } : {}) };
}

export function queueIntakeIfUnversioned(key: string, fields: Record<string, unknown>, title: string, o: IntakeOptions, testProject = false): void {
  if (!intakeOwed(o.type, fields, testProject, o.proposal)) return;
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

const TITLE_STOP = new Set(['the', 'and', 'for', 'with', 'that', 'this', 'from', 'into', 'are', 'not', 'its', 'has', 'was', 'but', 'can', 'all']);
const SIMILAR_TITLE = 0.7;
const MIN_TITLE_WORDS = 3;

/** The significant words of a title: lower-case, a leading "Sector:" prefix dropped, words of 3+ characters, stop words out. */
export function titleWords(title: string): string[] {
  const body = title.replace(/^[^:]{1,40}:\s+/, '').toLowerCase();
  const words = body.match(/[a-z0-9]+(?:[._-][a-z0-9]+)*/g) ?? [];
  return [...new Set(words.filter((w) => w.length >= 3 && !TITLE_STOP.has(w)))];
}

/** Share of the words two titles have in common (0 to 1), or 0 when either has too few words to compare. */
export function titleSimilarity(a: string, b: string): number {
  const wa = titleWords(a);
  const wb = new Set(titleWords(b));
  if (wa.length < MIN_TITLE_WORDS || wb.size < MIN_TITLE_WORDS) return 0;
  const shared = wa.filter((w) => wb.has(w)).length;
  return shared / (wa.length + wb.size - shared);
}

interface OpenHit { key: string; fields?: { summary?: string } }

async function openMatches(jql: string): Promise<OpenHit[]> {
  try {
    return (await searchAllIssues(jql, '200', request)) as OpenHit[];
  } catch (e) {
    console.error(`jira: warning: the duplicate search failed (${(e as Error).message}), so the ticket is filed unchecked`);
    return [];
  }
}

const keyNumber = (key: string): number => Number(/-(\d+)$/.exec(key)?.[1] ?? NaN);

const TOPIC_STOP = new Set([
  ...TITLE_STOP, 'ticket', 'tickets', 'work', 'file', 'files', 'filing', 'create', 'when', 'than', 'then', 'them', 'your', 'will', 'would', 'should',
  'could', 'about', 'after', 'before', 'every', 'each', 'other', 'more', 'most', 'only', 'same', 'such', 'some', 'any', 'plain', 'words', 'also', 'both',
  'being', 'been', 'were', 'have', 'does', 'done', 'make', 'made', 'still', 'what', 'which', 'while', 'where', 'there', 'their', 'these', 'those',
]);
const GENERIC_LABEL = /^(standalone|core|residual|operator-directed|backlog|proposed-.*|phase:.*|class-.*)$/;
const TOPIC_JQL_TERMS = 8;
const TOPIC_MIN_SHARED = 5;
const TOPIC_MIN_OVERLAP = 0.3;
const TOPIC_SHOWN = 3;
const TOPIC_TIMEOUT_MS = 8000;
const TOPIC_PAGES = 5;

const stem = (w: string): string => (w.length > 4 ? w.replace(/(?:ies|es|s)$/, '') : w);

export function whatSectionOf(text: string): string {
  const lines = text.split('\n');
  const head = (l: string, names: string): boolean => new RegExp(`^\\s{0,3}(?:#{1,6}\\s*)?(?:${names})\\s*:?\\s*$`, 'i').test(l);
  const start = lines.findIndex((l) => head(l, 'what'));
  if (start < 0) return text;
  const end = lines.findIndex((l, i) => i > start && head(l, 'impact|why|plan|dod|proof|agent detail'));
  return lines.slice(start + 1, end < 0 ? undefined : end).join('\n');
}

type TopicTerms = Map<string, string>;

export function topicTerms(title: string, what: string, labels: readonly string[] = [], sector?: string): TopicTerms {
  const terms: TopicTerms = new Map();
  const text = `${title.replace(/^[^:]{1,40}:\s+/, '')} ${what}`.toLowerCase();
  for (const w of text.match(/[a-z0-9]+(?:[._-][a-z0-9]+)*/g) ?? []) {
    if (w.length >= 4 && !TOPIC_STOP.has(w)) terms.set(stem(w), w);
  }
  for (const l of labels) if (!GENERIC_LABEL.test(l)) terms.set(`label:${l}`, l);
  if (sector) terms.set(`sector:${sector.toLowerCase()}`, sector);
  return terms;
}

export function topicOverlap(a: TopicTerms, b: TopicTerms): { shared: number; share: number } {
  const shared = [...a.keys()].filter((t) => b.has(t)).length;
  const smaller = Math.min(a.size, b.size);
  return { shared, share: smaller === 0 ? 0 : shared / smaller };
}

interface TopicHit extends OpenHit {
  fields?: { summary?: string; status?: { name?: string }; labels?: string[]; description?: unknown; [field: string]: unknown };
}

function bodyTextOf(o: { adf?: unknown; adfFile?: string; descFile?: string; desc?: string }): string {
  try {
    if (o.adf !== undefined) return adfToPlainText(o.adf as ADFDocument);
    if (o.adfFile) return adfToPlainText(JSON.parse(readFileSync(o.adfFile, 'utf8')) as ADFDocument);
    if (o.descFile) return readBodyFile(o.descFile, '--desc-file');
  } catch {
    return '';
  }
  return o.desc ?? '';
}

async function topicCandidates(jql: string): Promise<TopicHit[]> {
  const sector = sectorField();
  const fields = `summary,status,labels,description${sector ? `,${sector}` : ''}`;
  let timer: NodeJS.Timeout | undefined;
  let abandoned = false;
  const walk = async (): Promise<TopicHit[]> => {
    const found: TopicHit[] = [];
    let token: string | undefined;
    for (let page = 0; page < TOPIC_PAGES; page++) {
      if (abandoned) return found;
      const cursor = token === undefined ? '' : `&nextPageToken=${encodeURIComponent(token)}`;
      const r = await request<{ issues?: TopicHit[]; nextPageToken?: string }>('GET', `/search/jql?jql=${encodeURIComponent(jql)}&fields=${fields}&maxResults=100${cursor}`);
      found.push(...(r.issues ?? []));
      token = r.nextPageToken;
      if (token === undefined || !r.issues?.length) return found;
    }
    console.error(`jira: warning: the topic search read only the first ${found.length} open matches`);
    return found;
  };
  try {
    const slow = new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Error(`no answer in ${TOPIC_TIMEOUT_MS / 1000}s`)), TOPIC_TIMEOUT_MS);
    });
    return await Promise.race([walk(), slow]);
  } catch (e) {
    console.error(`jira: warning: the duplicate search failed (${(e as Error).message}), so the ticket is filed unchecked`);
    return [];
  } finally {
    abandoned = true;
    clearTimeout(timer);
  }
}

async function openTopicMatches(
  project: string,
  title: string,
  o: { adf?: unknown; adfFile?: string; descFile?: string; desc?: string; labels?: string; sector?: string; followUpOf?: string; residualOf?: string; parent?: string },
): Promise<TopicHit[]> {
  let labels: string[] = [];
  try {
    labels = o.labels !== undefined ? parseLabels(o.labels) : [];
  } catch {
    labels = [];
  }
  const mine = topicTerms(title, whatSectionOf(bodyTextOf(o)), labels, o.sector);
  const words = [...new Set([...mine].filter(([t, w]) => !t.includes(':') && /^[a-z0-9]+$/.test(w)).map(([, w]) => w))]
    .sort((a, b) => b.length - a.length)
    .slice(0, TOPIC_JQL_TERMS);
  if (mine.size < TOPIC_MIN_SHARED || words.length === 0) return [];
  const jql = `project = ${project} AND statusCategory != Done AND (${words.map((w) => `text ~ ${jqlQuote(w)}`).join(' OR ')})`;
  const sectorId = sectorField();
  const linked = new Set([o.followUpOf, o.residualOf, o.parent]);
  const scored: Array<{ hit: TopicHit; shared: number; share: number }> = [];
  for (const hit of await topicCandidates(jql)) {
    if (linked.has(hit.key)) continue;
    const f = hit.fields ?? {};
    const theirs = topicTerms(f.summary ?? '', whatSectionOf(adfToPlainText(f.description as ADFDocument | undefined)), f.labels ?? [], sectorId ? sectorOf(f) : undefined);
    const { shared, share } = topicOverlap(mine, theirs);
    if (shared >= TOPIC_MIN_SHARED && share >= TOPIC_MIN_OVERLAP) scored.push({ hit, shared, share });
  }
  return scored.sort((a, b) => b.shared - a.shared || b.share - a.share).slice(0, TOPIC_SHOWN).map((m) => m.hit);
}

/**
 * Refuses a new ticket that repeats an open one: an open follow-up already linked to the same parent (a residual
 * with both --class and --area is matched on those by planResidual instead), or an open ticket whose title is close.
 * --new-reason names why a new ticket is needed and skips the search. A failed search files unchecked.
 */
export async function refuseOpenDuplicate(
  project: string,
  title: string,
  o: {
    followUpOf?: string; residualOf?: string; class?: string; area?: string; newReason?: string;
    adf?: unknown; adfFile?: string; descFile?: string; desc?: string; labels?: string; sector?: string; parent?: string;
  },
): Promise<void> {
  if (o.newReason !== undefined) {
    console.error(`jira: --new-reason: ${o.newReason.trim()}`);
    return;
  }
  const refuse = (hit: OpenHit, why: string): never => {
    throw new CreateRefused(
      `jira create refused, nothing was filed: ${hit.key} ("${hit.fields?.summary ?? ''}") is open and ${why}; extend ${hit.key} with jira comment, or pass --new-reason <why>`,
    );
  };
  const parent = o.followUpOf ?? (o.residualOf !== undefined && !(o.class && o.area) ? o.residualOf : undefined);
  if (parent !== undefined) {
    const jql = `project = ${project} AND statusCategory != Done AND labels = residual AND issue in linkedIssues(${jqlQuote(parent)})`;
    const sibling = (await openMatches(jql)).find((h) => !(keyNumber(h.key) < keyNumber(parent)));
    if (sibling) refuse(sibling, `already follows up ${parent}`);
  }
  const all = titleWords(title);
  const words = all.filter((w) => /^[a-z0-9]+$/.test(w)).sort((a, b) => b.length - a.length).slice(0, 3);
  if (all.length >= MIN_TITLE_WORDS && words.length > 0) {
    const jql = `project = ${project} AND statusCategory != Done AND summary ~ ${jqlQuote(words.join(' '))}`;
    const close = (await openMatches(jql)).find((h) => titleSimilarity(title, h.fields?.summary ?? '') >= SIMILAR_TITLE);
    if (close) refuse(close, 'its title is close to this one');
  }
  const held = await openTopicMatches(project, title, o);
  if (held.length > 0) {
    const list = held.map((h) => `${h.key} ("${h.fields?.summary ?? ''}", ${h.fields?.status?.name ?? 'unknown status'})`).join('; ');
    throw new CreateRefused(
      `jira create refused, nothing was filed: ${held.length === 1 ? 'an open ticket already holds' : 'open tickets already hold'} this topic: ${list}; extend ${held[0]!.key} with jira comment, or pass --new-reason <why>`,
    );
  }
}


export async function residualInheritedVersion(
  o: RelationshipOptions & { gate?: string },
  residual: ResidualPlan | undefined,
): Promise<string | undefined> {
  const inherited = await inheritedFixVersion(o);
  return residual && inherited && o.gate === undefined && residual.frozen.includes(inherited) ? undefined : inherited;
}

type Declared = { release: string; current: string; versions: string[] };

export function declaredFor(project: string): Declared | null {
  const declared = releaseForProject(process.env, project);
  if (declared === 'unreadable') {
    throw new CreateRefused(`jira create: the release declaration for ${project} cannot be read, so the rules cannot place this ticket; pass --fix-version <v>, or --backlog --proposed-version backlog --why <why>`);
  }
  if (declared.length > 1) {
    throw new CreateRefused(`jira create: ${declared.length} releases name ${project} (${declared.map((d) => d.release).join(', ')}), so the rules cannot place this ticket; pass --fix-version <v>, or --backlog --proposed-version backlog --why <why>`);
  }
  return declared[0] ?? null;
}

export interface VerifiedWords { ctx: ReturnType<typeof ctxFor>; decision: string; words: string; record: ReturnType<typeof decisionWords> }

export function verifyWords(o: { decision?: string; words?: string }, declared: Declared | null): VerifiedWords | undefined {
  if (o.decision === undefined && o.words === undefined) return undefined;
  if (o.decision === undefined) throw new Error('jira create: --words needs --decision <n>, the decision whose file holds them');
  if (o.words === undefined) throw new Error('jira create: --decision needs --words "<the operator\'s exact words>"');
  if (declared === null) {
    throw new CreateRefused('jira create: --decision and --words need a declared release to verify them against, and none names this project');
  }
  const ctx = ctxFor(declared.release);
  operatorFence(ctx);
  return { ctx, decision: o.decision, words: o.words, record: decisionWords(ctx, o.decision, o.words) };
}

export function recordWords(w: VerifiedWords, key: string, to: string | null): string {
  return operatorDecision(w.ctx, { decision: w.decision, keys: [key], op: to ? 'add' : 'none', from_v: null, to_v: to, verbatim: w.words, ...w.record }).id;
}

export interface RulesInput {
  project: string;
  type: string;
  priority?: string;
  labels: string[];
  gate?: string;
  proposedVersion?: string;
  followUpOf?: string;
  remainder?: boolean;
  pointer?: BridgePointer;
  parent?: FollowUpParent;
  words: boolean;
}

export interface RulesPlacement {
  placement: Placement;
  ground: string;
  target: string | undefined;
  labels: string[];
  release: string | undefined;
}

function groundOf(p: Placement): string {
  switch (p.rule) {
    case 'A': return p.ask === 'named' ? `rules:operator-named:${p.arg}` : p.ask === 'undeclared' ? `rules:operator-undeclared:${p.arg}` : `rules:operator-ask:${p.arg}`;
    case 'S': return `rules:remainder-of:${p.arg}`;
    case 'W': return 'rules:started';
    case 'H': return `rules:serious:${p.arg}`;
    case 'L': return p.residual ? `rules:residual-label:${p.arg}` : `rules:label:${p.arg}`;
    case 'P': return `rules:follow-up-of:${p.arg}`;
    case 'M': return 'rules:mild';
    default: return `rules:${p.rule}`;
  }
}

async function filingRelease(project: string, declared: Declared | null): Promise<ReleaseIn> {
  const versions = await fetchVersions(project);
  const jiraCurrent = earliestUnreleased(versions);
  const jiraFrozen = jiraCurrent !== undefined && frozenDate(versions.find((v) => v.name === jiraCurrent)?.description) !== undefined;
  if (declared === null) {
    return { current: jiraCurrent ?? '', versions: versions.filter((v) => !v.released && !v.archived).map((v) => v.name), frozen: jiraFrozen };
  }
  if (declared.current !== jiraCurrent) {
    throw new CreateRefused(`jira create: the declared current ${declared.current} differs from Jira's earliest unreleased version ${jiraCurrent ?? 'none'}, so the rules cannot place this ticket; fix the declaration or Jira, or pass --fix-version <v>`);
  }
  let ledgerFrozen: boolean;
  try {
    ledgerFrozen = currentFrozen(loadOrThrow(ctxFor(declared.release)));
  } catch (e) {
    throw new CreateRefused(`jira create: ${(e as Error).message}, so the rules cannot place this ticket; pass --fix-version <v>, or --backlog --proposed-version backlog --why <why>`);
  }
  if (ledgerFrozen !== jiraFrozen) {
    throw new CreateRefused(`jira create: the ledger says ${declared.current} is ${ledgerFrozen ? 'frozen' : 'not frozen'}, but Jira's ${declared.current} ${jiraFrozen ? 'carries a frozen: line' : 'carries no frozen: line'}; the two must agree before the rules can place this ticket`);
  }
  return { current: declared.current, versions: declared.versions, frozen: ledgerFrozen };
}

export async function rulesPlacement(o: RulesInput, declared: Declared | null): Promise<RulesPlacement> {
  const rel = await filingRelease(o.project, declared);
  const gate = o.gate === 'critical' || o.gate === 'regression' ? o.gate : null;
  const parent = o.parent === undefined || o.followUpOf === undefined ? null : { key: o.followUpOf, versions: o.parent.versions, remainder: o.remainder === true };
  const t = ticketFromCreate({ priority: o.priority ?? '', labels: o.labels, type: o.type, gate, proposedVersion: o.proposedVersion, pointer: o.pointer !== undefined, words: o.words, parent });
  const placement = placeByRules(t, rel)!;
  const ground = groundOf(placement);
  if (placement.rule === 'A' && placement.ask === 'undeclared') {
    throw new CreateRefused(`jira create: the operator named ${placement.arg}, which is not declared by the release (${rel.versions.join(', ')}); name a declared version, or drop --proposed-version for ${rel.current}`);
  }
  if (rel.current === '' && (placement.target === '' || placement.propose === '')) {
    throw new CreateRefused(`jira create: ${placement.reason}, but ${o.project} has no unreleased version; create one, or file with --backlog --proposed-version backlog --why <why>`);
  }
  if (declared === null && placement.propose !== undefined) {
    throw new CreateRefused(`jira create: ${placement.reason}, and only the chief or the operator's words place it; no release names ${o.project} to take an INTAKE, so pass --fix-version --chief-override <reason> (the chief) or --gate must:<ref>`);
  }
  if (o.proposedVersion !== undefined && o.proposedVersion !== 'backlog' && placement.rule !== 'A') {
    console.error(`jira: --proposed-version ${o.proposedVersion} places nothing: only an operator ask names a version`);
  }
  const labels = placement.propose !== undefined ? [proposedLabel(placement.propose)] : placement.target === null ? [BACKLOG_LABEL] : [];
  return { placement, ground, target: placement.target ?? undefined, labels, release: declared?.release };
}

/** The journal name of the code path that chose a new ticket's Fix Version; undefined (hand) when the caller typed it or none was set. */
export function createWriterOf(
  options: { fixVersion?: string; residualOf?: string; followUpOf?: string },
  chose: { placed: boolean; inherited: string | undefined; residual: ResidualPlan | undefined; bugDefault: boolean; rules?: boolean },
): string | undefined {
  if (!chose.placed || options.fixVersion !== undefined) return undefined;
  if (chose.rules) return 'create-rules';
  if (chose.inherited !== undefined) {
    return options.residualOf !== undefined ? 'create-residual' : options.followUpOf !== undefined ? 'create-followup' : 'create-blocker-inherit';
  }
  if (chose.residual) return 'create-residual';
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
    .option('--backlog', 'File to the backlog: label backlog, no version, no INTAKE; needs --proposed-version backlog and --why (and --decision --words for an operator ask)')
    .option(
      '--proposed-version <v>',
      'The version an operator ask names (operator-directed, or verified --decision --words); on any other ticket it places nothing, the rules do. `backlog` needs --backlog and --why',
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
      'Why this may enter a version (' + INTAKE_GATES + '): must:<ref> and receipt file the ticket into the earliest unreleased version; critical and regression go to the rules (a frozen current only takes the proposal), and a frozen version takes nothing by --fix-version without it',
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
      "File this as a follow-up of <key>: stamps the residual label and links it to <key>. With no version of its own, its INTAKE asks for <key>'s current version (an open parent; a Done parent in the current unfrozen version is filed into it at its priority) and states parent, status and version",
    )
    .option(
      '--remainder',
      "With --follow-up-of: this ticket holds the parent's remainder (a deferred DoD row), so the INTAKE says the parent cannot close without it",
    )
    .option('--new-reason <why>', 'Why a new ticket is needed although an open one repeats it (same --follow-up-of / --residual-of parent, a close title, or the same topic worded differently in the title and What section): without it the filing is refused and names the open ticket to extend with jira comment')
    .option('--fu-class <class>', 'Residual class: escape or hardening (needs --fu-override); a residual of a declared project is placed by the door from its priority, and --gate means the current version; the class routes it only for a project no declared release names (docs/release/follow-up-triage.md). polish is refused: it is noted with no ticket. Applies only with --residual-of')
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
          const withPointer: CreateOptions & { pointer?: BridgePointer } = { ...options, pointer: bridgePointer(options), checkDuplicates: true };
          await runCreate(withPointer);
        } catch (e) {
          if (!(e instanceof CreateRefused || e instanceof CreatePartial)) throw e;
          console.error(e.message);
          process.exit(1);
        }
      },
    );
}
