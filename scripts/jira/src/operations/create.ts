import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { request, projectKey } from '../client.js';
import type { ADFDocument } from '../adf-render.js';
import { renderIssue, type MirrorIssue } from '../commands/mirror.js';
import { FILER_GATES, ownProject, readinessLabel, runReadiness } from '../readiness.js';
import { writeJiraBreadcrumb } from '../breadcrumb.js';
import { browseLine } from '../browse-line.js';
import { markdownToAdf } from '../adf.js';
import type { CreateIssueResponse } from '../types.js';
import { uploadAll } from '../commands/attach-helper.js';
import { readBodyFile } from '../commands/body-file.js';
import { parseLabels } from '../commands/labels.js';
import { bodyDiagnostics, homeVerdict, plainBlockVerdict, titleVerdict, type BodyInput } from '../plain-block.js';
import { sectorField, sectorOptions } from '../commands/sector.js';
import { createIssueLink } from '../commands/link.js';
import { appendAdmission, assertAdmissionsWritable } from '../commands/admissions-ledger.js';
import { checkIntakeGate } from '../commands/intake-gate.js';
import { refuseTestJiraPost } from '../commands/release.js';
import { isTestProject } from '../live-test-guard.js';
import {
  BACKLOG_LABEL,
  agentDetailOf,
  agentDetailOfAdf,
  appendFuOverride,
  applyVersions,
  assertProposalNotInherited,
  assertProposedVersion,
  checkExistingBlocker,
  checkPlacementFlags,
  createWriterOf,
  declaredFor,
  followUpIntake,
  closedParentPlacement,
  markCore,
  placeAtFiling,
  planResidual,
  preflightIntake,
  printCore,
  queueIntakeIfUnversioned,
  readFollowUpParent,
  recordWords,
  refuseOpenDuplicate,
  residualInheritedVersion,
  resolveTitle,
  rulesPlacement,
  sectorForCreate,
  verifyWords,
  type BridgePointer,
  type FollowUpParent,
  type ResidualPlan,
  type RulesPlacement,
  type VerifiedWords,
} from '../commands/create.js';

export interface CreateOptions {
  type: string;
  title?: string;
  summary?: string;
  desc?: string;
  descFile?: string;
  adfFile?: string;
  adf?: unknown;
  parent?: string;
  blocks: string[];
  splitFrom?: string;
  blockedBy?: string;
  labels?: string;
  sector?: string;
  fixVersion?: string;
  priority?: string;
  backlog?: boolean;
  proposedVersion?: string;
  why?: string;
  decision?: string;
  words?: string;
  gate?: string;
  chiefOverride?: string;
  affectsVersion?: string;
  residualOf?: string;
  followUpOf?: string;
  /** Why a new ticket is needed although an open one repeats it; skips the duplicate search. */
  newReason?: string;
  /** The `jira create` command sets this: only it searches for an open duplicate (move does not). */
  checkDuplicates?: boolean;
  remainder?: boolean;
  fuClass?: string;
  fuWhy?: string;
  fuOverride?: string;
  class?: string;
  area?: string;
  project?: string;
  changeClass?: string;
  pointer?: BridgePointer;
  attach: string[];
}

export type CreateResult =
  | { disposition: 'created'; key: string }
  | { disposition: 'duplicate'; key: string }
  | { disposition: 'checked' };

export class CreateRefused extends Error {}

/** Jira holds the ticket, but a later step failed: the key and the owed steps are in the message. */
export class CreatePartial extends Error {
  constructor(readonly key: string, step: string, cause: unknown, readonly pending: string[]) {
    super(
      `jira: PARTIAL: Created ${key} but ${step} failed: ${(cause as Error).message ?? String(cause)}; ` +
        `still owed: ${pending.length ? pending.join(', ') : 'nothing else'}. The ticket exists: finish these by hand, do not re-run create.`,
    );
  }
}

function bodyOf(o: CreateOptions): { input: BodyInput; adf?: unknown; detail: string } {
  if (o.adf !== undefined) return { input: { format: 'adf', body: o.adf }, adf: o.adf, detail: agentDetailOfAdf(o.adf) };
  if (o.adfFile) {
    let adf: unknown;
    try {
      adf = JSON.parse(readFileSync(o.adfFile, 'utf8'));
    } catch (e) {
      throw new CreateRefused(`jira: cannot read --adf-file "${o.adfFile}": ${(e as Error).message}`);
    }
    return { input: { format: 'adf', body: adf }, adf, detail: agentDetailOfAdf(adf) };
  }
  const md = o.descFile ? readBodyFile(o.descFile, '--desc-file') : o.desc;
  if (md) return { input: { format: 'markdown', body: md }, adf: markdownToAdf(md), detail: agentDetailOf(md) };
  return { input: { format: 'markdown', body: '' }, detail: '' };
}

function checkBody(type: string, input: BodyInput, labels: readonly string[], warn: boolean): void {
  const found = bodyDiagnostics(input, type, labels).map((d) => d.message);
  const verdict = plainBlockVerdict(type, found);
  if (verdict.action === 'refuse') throw new CreateRefused(verdict.message);
  if (verdict.action === 'warn' && warn) console.error(verdict.message);
}

async function postIssue(fields: Record<string, unknown>, writer: string | undefined): Promise<CreateIssueResponse> {
  try {
    return await request<CreateIssueResponse>('POST', '/issue', { fields }, writer);
  } catch (e) {
    const msg = (e as Error).message ?? String(e);
    if (/^HTTP 4\d\d\b/.test(msg) || /nothing was posted/.test(msg)) throw e;
    throw new Error(
      `jira: OUTCOME UNKNOWN: the create request failed after it was sent (${msg}); the ticket may exist. ` +
        `Search for "${fields['summary'] as string}" before filing again; create is not retried.`,
    );
  }
}

function checkFlagCombinations(options: CreateOptions): void {
  if (options.followUpOf !== undefined && options.residualOf !== undefined) {
    throw new Error('--follow-up-of cannot be combined with --residual-of (a residual is already linked to its parent)');
  }
  if (options.residualOf === undefined) {
    const stray = ([['fuClass', '--fu-class'], ['fuWhy', '--fu-why'], ['fuOverride', '--fu-override']] as const).find(([k]) => options[k] !== undefined);
    if (stray) throw new Error(`--fu-class/--fu-why/--fu-override apply only with --residual-of (got ${stray[1]})`);
  }
  if (options.newReason !== undefined && !options.newReason.trim()) {
    throw new Error('--new-reason needs the reason a new ticket is wanted although an open one repeats it');
  }
  if (options.remainder && options.followUpOf === undefined) {
    throw new Error('--remainder needs --follow-up-of <key>, the parent whose remainder this ticket holds');
  }
}

async function placement(
  options: CreateOptions,
  fields: Record<string, unknown>,
  residual: ResidualPlan | undefined,
  given: string[] | undefined,
  detail: string,
  testProject: boolean,
): Promise<{ labels: string[] | undefined; inherited?: string; bugDefault: boolean; coreVerdict: ReturnType<typeof markCore>['verdict'] }> {
  let labels = given;
  if (residual) appendFuOverride(fields, options.fuOverride);
  const inherited = await residualInheritedVersion(options, residual);
  assertProposalNotInherited(options, inherited);
  if (options.backlog) labels = [...new Set([...(labels ?? []), BACKLOG_LABEL])];
  const placed = placeAtFiling({ ...options, fixVersion: inherited ?? options.fixVersion }, labels, residual !== undefined, testProject);
  const core = markCore(detail, options.changeClass, placed.labels);
  return { labels: core.labels, inherited, bugDefault: placed.bugDefault, coreVerdict: core.verdict };
}

function applyResidual(fields: Record<string, unknown>, residual: ResidualPlan, inherited: string | undefined): void {
  if (residual.fixVersion) fields['fixVersions'] = [{ name: residual.fixVersion }];
  if (residual.affectsVersion) fields['versions'] = [{ name: residual.affectsVersion }];
  const routed = inherited ?? residual.fixVersion;
  if (routed) console.error(`jira: residual routed to ${routed}`);
}

interface Decided {
  parentFacts: FollowUpParent | undefined;
  closedParent: ReturnType<typeof closedParentPlacement>;
  explicitVersion: string | undefined;
  words: VerifiedWords | undefined;
  rules: RulesPlacement | undefined;
}

async function decidePlacement(
  project: string,
  options: CreateOptions,
  o: { testProject: boolean; inherited: string | undefined; residual: ResidualPlan | undefined; bugDefault: boolean; labels: string[] },
): Promise<Decided> {
  const { testProject, inherited, residual } = o;
  const typeFiled = /^(bug|task|story)$/i.test(options.type);
  const reads = !testProject && typeFiled && options.followUpOf !== undefined && inherited === undefined && options.fixVersion === undefined && !options.backlog;
  const parentFacts = reads ? await readFollowUpParent(options.followUpOf!) : undefined;
  const closedParent = inherited === undefined && residual === undefined ? closedParentPlacement(options, parentFacts) : undefined;
  const explicitVersion = inherited ?? closedParent?.fixVersion ?? options.fixVersion;
  const explicit = testProject || !typeFiled || options.backlog === true || explicitVersion !== undefined || residual?.fixVersion !== undefined || o.bugDefault;
  const wordsGiven = !testProject && (options.decision !== undefined || options.words !== undefined);
  const declared = !explicit || wordsGiven ? declaredFor(project) : null;
  const words = wordsGiven ? verifyWords(options, declared) : undefined;
  const rules = explicit
    ? undefined
    : await rulesPlacement({
      project, type: options.type, priority: options.priority, labels: o.labels, gate: options.gate,
      proposedVersion: options.proposedVersion, followUpOf: options.followUpOf, remainder: options.remainder,
      pointer: options.pointer, parent: parentFacts, words: words !== undefined,
    }, declared);
  if (options.pointer !== undefined && rules === undefined) {
    throw new CreateRefused('jira create: --operator-update refused, nothing was filed: the pointer rides on a rules placement, and this filing is placed by hand (--gate must|receipt, an inherited blocker version or a Done parent), where no filed row would carry it; drop --operator-update or the hand placement');
  }
  return { parentFacts, closedParent, explicitVersion, words, rules };
}

function proposalIntake(options: CreateOptions, rules: RulesPlacement | undefined, parentFacts: FollowUpParent | undefined): CreateOptions & { evidence?: Record<string, unknown>; proposal?: boolean } {
  const proposed = rules?.placement.propose;
  if (rules === undefined || proposed === undefined) return options;
  const base: CreateOptions & { evidence?: Record<string, unknown> } = followUpIntake(options, parentFacts);
  return { ...base, proposal: true, proposedVersion: proposed, evidence: { ...base.evidence, rule: rules.ground } };
}

type PlannedLinks = NonNullable<MirrorIssue['fields']['issuelinks']>;

function plannedLinks(options: CreateOptions): PlannedLinks {
  const out = (key: string, outward: string, inward: string) => ({ type: { outward, inward }, outwardIssue: { key } });
  const relates = (key: string) => out(key, 'relates to', 'relates to');
  const parentKey = options.residualOf ?? options.followUpOf;
  return [
    ...(parentKey ? [relates(parentKey)] : []),
    ...options.blocks.map((key) => out(key, 'blocks', 'is blocked by')),
    ...(options.splitFrom ? [relates(options.splitFrom)] : []),
    ...(options.blockedBy ? [{ type: { outward: 'blocks', inward: 'is blocked by' }, inwardIssue: { key: options.blockedBy } }] : []),
  ];
}

/** The ticket as the mirror will hold it right after the filing, under the placeholder key <project>-0. */
export function readinessIssue(type: string, adf: unknown, fields: Record<string, unknown>, links: PlannedLinks, project: string): MirrorIssue {
  return {
    key: `${project}-0`,
    fields: {
      ...fields,
      issuetype: { name: type },
      status: { name: 'To Do', statusCategory: { name: 'To Do' } },
      description: adf as ADFDocument | undefined,
      issuelinks: links,
    } as MirrorIssue['fields'],
  };
}

const SCOPELESS = 'jira: refused: the dispatcher reads no write scope, so this ticket would never reach a worker. '
  + 'In ## Agent detail add a line "Writes: <repo path>, <repo path>" or "Writes: none (no code)".';

function declaredCurrent(project: string): string | undefined {
  try {
    return declaredFor(project)?.current;
  } catch {
    return undefined;
  }
}

async function readinessGate(
  type: string, adf: unknown, fields: Record<string, unknown>, links: PlannedLinks, project: string,
  filing: { backlog: boolean; intakeTo: string | undefined },
): Promise<{ refuse?: string; label?: string; warning?: string }> {
  if (!/^(bug|task|story)$/i.test(type)) return {};
  let dir: string | undefined;
  try {
    if (project !== ownProject()) return {};
    const key = `${project}-0`;
    dir = mkdtempSync(join(tmpdir(), 'jira-readiness-'));
    const bodyFile = join(dir, `${key}.md`);
    writeFileSync(bodyFile, renderIssue(readinessIssue(type, adf, fields, links, project), []));
    const got = await runReadiness({ key, bodyFile }, project);
    if (got.warning !== undefined) return { warning: got.warning };
    const scopeless = got.gates.find((g) => g.name === 'no-scope');
    if (scopeless) return { refuse: `${SCOPELESS} (gate: ${scopeless.detail})` };
    for (const line of got.lines.filter((l) => l.startsWith(`GATE ${key} `))) console.error(line);
    if (filing.backlog || !got.gates.some((g) => FILER_GATES.has(g.name))) return {};
    const current = declaredCurrent(project);
    const versions = (fields['fixVersions'] as Array<{ name: string }> | undefined)?.map((v) => v.name) ?? [];
    return current !== undefined && (versions.includes(current) || filing.intakeTo === current) ? { label: await readinessLabel() } : {};
  } catch (e) {
    return { warning: (e as Error).message };
  } finally {
    if (dir) rmSync(dir, { recursive: true, force: true });
  }
}

/** Refuses a filing the dispatcher could never start; otherwise warns or adds the readiness label to `fields`. */
async function applyReadiness(
  options: CreateOptions, adf: unknown, fields: Record<string, unknown>, project: string,
  intake: { proposal?: boolean; proposedVersion?: string },
): Promise<void> {
  const ready = await readinessGate(options.type, adf, fields, plannedLinks(options), project,
    { backlog: options.backlog === true, intakeTo: intake.proposal ? intake.proposedVersion : undefined });
  if (ready.refuse !== undefined) throw new CreateRefused(ready.refuse);
  if (ready.warning !== undefined) console.error(`jira: warning: readiness check not run (${ready.warning}); filed without it`);
  if (ready.label !== undefined) fields['labels'] = [...new Set([...((fields['labels'] as string[] | undefined) ?? []), ready.label])];
}

export async function runCreate(options: CreateOptions, run: { check?: boolean } = {}): Promise<CreateResult> {
  if (!run.check) refuseTestJiraPost('create');
  checkFlagCombinations(options);
  const overrideReason = checkPlacementFlags(options);
  await assertProposedVersion(options);
  const project = options.project ?? projectKey();
  const testProject = isTestProject(project);
  const title = resolveTitle(options);
  const fields: Record<string, unknown> = { project: { key: project }, summary: title, issuetype: { name: options.type } };
  if (options.priority !== undefined) fields['priority'] = { name: options.priority };
  const body = bodyOf(options);
  if (body.adf !== undefined) fields['description'] = body.adf;
  const given = options.labels !== undefined ? parseLabels(options.labels) : undefined;
  checkBody(options.type, body.input, given ?? [], true);

  const sectorId = sectorField();
  const sectors = sectorId && !testProject ? await sectorOptions() : undefined;
  const titleCheck = titleVerdict(options.type, title, sectors);
  if (titleCheck.action === 'warn') console.error(titleCheck.message);
  if (options.sector !== undefined && !sectors) {
    console.error('jira: warning: --sector ignored, Sector is not configured (run `jira sector setup`)');
  }
  const sector = sectorForCreate(options.type, title, options.sector, sectors);

  let labels = given;
  let residual: ResidualPlan | undefined;
  if (options.residualOf !== undefined) {
    residual = await planResidual(project, { ...options, residualOf: options.residualOf });
    labels = [...new Set([...(labels ?? []), ...residual.labels])];
  }
  if (options.followUpOf !== undefined) labels = [...new Set([...(labels ?? []), 'residual'])];
  const duplicateOf = residual?.duplicateOf;
  const place = duplicateOf === undefined ? await placement(options, fields, residual, labels, body.detail, testProject) : undefined;
  if (place) labels = place.labels;
  const { inherited, bugDefault = false, coreVerdict } = place ?? {};
  checkBody(options.type, body.input, labels ?? [], false);
  const home = testProject ? { action: 'ok' as const, message: '' } : homeVerdict(options.type, { sector, parent: options.parent, labels }, sectors);
  if (home.action === 'refuse') throw new CreateRefused(home.message);
  if (home.action === 'warn') console.error(home.message);

  if (duplicateOf !== undefined) {
    if (run.check) return { disposition: 'checked' };
    const head = markdownToAdf(`Re-raised as a residual of ${options.residualOf}: ${title}`);
    const detail = (fields['description'] as { content?: unknown[] } | undefined)?.content ?? [];
    await request('POST', `/issue/${duplicateOf}/comment`, { body: { ...head, content: [...head.content, ...detail] } });
    await createIssueLink(duplicateOf, options.residualOf!, { name: 'Relates', inward: 'relates to' });
    console.log(`Duplicate ${duplicateOf}`);
    return { disposition: 'duplicate', key: duplicateOf };
  }

  if (options.parent) fields['parent'] = { key: options.parent };
  if (sector && sectorId) fields[sectorId] = { value: sector };
  if (residual) applyResidual(fields, residual, inherited);

  const { parentFacts, closedParent, explicitVersion, words, rules } = await decidePlacement(project, options, { testProject, inherited, residual, bugDefault, labels: labels ?? [] });
  if (closedParent?.priority !== undefined && options.priority === undefined) fields['priority'] = { name: closedParent.priority };
  labels = [...new Set([...(labels ?? []), ...(rules?.labels ?? [])])];
  if (labels.length > 0) fields['labels'] = labels;
  const versionOptions = { ...options, fixVersion: explicitVersion ?? rules?.target };
  await applyVersions(project, versionOptions, fields, { bugDefault });
  const admission = await versionGate(project, options, fields, { testProject, overrideReason, rules });
  await checkExistingBlocker(project, fields['fixVersions'], options);
  const intake = proposalIntake(options, rules, parentFacts);
  preflightIntake(intake, fields, title, testProject);
  if (options.checkDuplicates && !testProject) await refuseOpenDuplicate(project, title, options);
  await applyReadiness(options, body.adf, fields, project, intake);
  if (run.check) return { disposition: 'checked' };

  const writer = createWriterOf(options, { placed: fields['fixVersions'] !== undefined, inherited: inherited ?? closedParent?.fixVersion, residual, bugDefault, rules: rules?.target !== undefined });
  const result = await postIssue(fields, writer);
  const key = result.key;
  writeJiraBreadcrumb(key);
  console.log(`Created ${key}`);
  const browse = browseLine(key);
  if (browse) console.log(browse);
  printCore(coreVerdict);
  if (rules) console.error(placementLine(key, rules));
  queueIntakeIfUnversioned(key, fields, title, intake, testProject);

  const filedInto = (fields['fixVersions'] as Array<{ name: string }> | undefined)?.[0]?.name ?? null;
  await runSteps(key, afterCreateSteps(options, key, title, { overrideReason: testProject ? undefined : overrideReason, admission, words, wordsInto: filedInto, rules }));
  return { disposition: 'created', key };
}

type Step = [string, () => Promise<unknown> | unknown];

async function runSteps(key: string, steps: Step[]): Promise<void> {
  for (let i = 0; i < steps.length; i += 1) {
    const [name, step] = steps[i]!;
    try {
      await step();
    } catch (e) {
      throw new CreatePartial(key, name, e, steps.slice(i + 1).map(([n]) => n));
    }
  }
}

async function versionGate(
  project: string,
  options: CreateOptions,
  fields: Record<string, unknown>,
  o: { testProject: boolean; overrideReason: string | undefined; rules: RulesPlacement | undefined },
): Promise<Awaited<ReturnType<typeof checkIntakeGate>>> {
  const placed = o.rules?.target !== undefined;
  const admission = o.testProject ? undefined : await checkIntakeGate(project, fields['fixVersions'], { gate: options.gate, override: o.overrideReason !== undefined, rules: placed });
  if (placed && o.rules?.release !== undefined) assertAdmissionsWritable();
  return admission;
}

function placementLine(key: string, r: RulesPlacement): string {
  if (r.placement.propose !== undefined) {
    return `jira: ${r.placement.reason}; the chief places it (release request --chief-reason) or the operator's words do; INTAKE queued for ${key}`;
  }
  return `jira: placed ${key} in ${r.target ?? 'backlog'} by ${r.ground} (${r.placement.reason})`;
}

function afterCreateSteps(
  options: CreateOptions,
  key: string,
  title: string,
  o: {
    overrideReason?: string; admission?: Awaited<ReturnType<typeof checkIntakeGate>>;
    words?: VerifiedWords; wordsInto: string | null; rules?: RulesPlacement;
  },
): Step[] {
  const { overrideReason, admission, words, rules } = o;
  const parentKey = options.residualOf ?? options.followUpOf;
  const steps: Step[] = [];
  let record: string | undefined;
  if (words) steps.push(['writing the operator record', () => { record = recordWords(words, key, o.wordsInto); }]);
  if (rules?.target !== undefined && rules.release !== undefined) {
    const version = rules.target;
    steps.push(['writing the filed row', () => appendAdmission({
      version, key, kind: 'filed', ground: rules.ground, reason: rules.placement.reason,
      ...(record !== undefined ? { ruling: record } : {}),
      ...(options.pointer !== undefined ? { evidence: options.pointer } : {}),
    })]);
  }
  if (overrideReason !== undefined) {
    steps.push(['writing the admissions ledger row', () => appendAdmission({ version: options.fixVersion!, kind: 'override', reason: overrideReason, key })]);
  }
  if (admission) steps.push(['writing the admissions ledger row', () => appendAdmission({ ...admission, key })]);
  if (parentKey) steps.push([`linking to ${parentKey}`, () => createIssueLink(key, parentKey, { name: 'Relates', inward: 'relates to' })]);
  for (const other of options.blocks) {
    steps.push([`linking ${key} to ${other}`, () => createIssueLink(key, other, { name: 'Blocks', outward: 'blocks' })]);
  }
  if (options.splitFrom) {
    const from = options.splitFrom;
    steps.push([`linking ${key} to ${from}`, () => createIssueLink(key, from, { name: 'Relates', outward: 'relates to' })]);
  }
  if (options.blockedBy) {
    const by = options.blockedBy;
    steps.push([`linking ${by} to ${key}`, () => createIssueLink(by, key, { name: 'Blocks', outward: 'blocks' })]);
  }
  if (options.attach.length > 0) {
    steps.push(['attachment', async () => console.error(`  attachments: ${await uploadAll(key, options.attach)}`)]);
  }
  return steps;
}
