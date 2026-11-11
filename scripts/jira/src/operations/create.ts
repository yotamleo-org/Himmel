import { readFileSync } from 'node:fs';
import { request, projectKey } from '../client.js';
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
import { appendAdmission } from '../commands/admissions-ledger.js';
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
  displaceResidual,
  followUpIntake,
  intakeOwed,
  markCore,
  placeAtFiling,
  planResidual,
  preflightIntake,
  printCore,
  queueIntakeIfUnversioned,
  residualInheritedVersion,
  resolveTitle,
  sectorForCreate,
  type ResidualPlan,
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
  remainder?: boolean;
  overCap?: string;
  fuClass?: string;
  fuWhy?: string;
  fuOverride?: string;
  class?: string;
  area?: string;
  project?: string;
  changeClass?: string;
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
  if (options.remainder && options.followUpOf === undefined) {
    throw new Error('--remainder needs --follow-up-of <key>, the parent whose remainder this ticket holds');
  }
  if (options.overCap !== undefined && !options.overCap.trim()) throw new Error('--over-cap needs a reason');
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
    residual = await planResidual(project, { ...options, sector, residualOf: options.residualOf });
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
  if (labels) fields['labels'] = labels;
  if (sector && sectorId) fields[sectorId] = { value: sector };
  if (residual) {
    if (residual.fixVersion) fields['fixVersions'] = [{ name: residual.fixVersion }];
    if (residual.affectsVersion) fields['versions'] = [{ name: residual.affectsVersion }];
    console.error(`jira: residual routed to ${inherited ?? residual.fixVersion ?? 'the backlog'}`);
  }
  const versionOptions = { ...options, fixVersion: inherited ?? options.fixVersion };
  const overCapReason = await applyVersions(project, versionOptions, fields, {
    labels,
    residual: residual !== undefined && inherited === undefined,
    bugDefault,
  });
  const admission = testProject ? undefined : await checkIntakeGate(project, fields['fixVersions'], { gate: options.gate, override: overrideReason !== undefined });
  await checkExistingBlocker(project, fields['fixVersions'], options);
  const intake = intakeOwed(options.type, fields, testProject) ? await followUpIntake(versionOptions) : options;
  preflightIntake(intake, fields, title, testProject);
  if (run.check) return { disposition: 'checked' };

  const writer = createWriterOf(options, { placed: fields['fixVersions'] !== undefined, inherited, residual, bugDefault });
  const result = await postIssue(fields, writer);
  const key = result.key;
  writeJiraBreadcrumb(key);
  console.log(`Created ${key}`);
  const browse = browseLine(key);
  if (browse) console.log(browse);
  printCore(coreVerdict);
  queueIntakeIfUnversioned(key, fields, title, intake, testProject);

  const steps = afterCreateSteps(options, key, title, { overrideReason: testProject ? undefined : overrideReason, admission, residual, overCapReason });
  for (let i = 0; i < steps.length; i += 1) {
    const [name, step] = steps[i]!;
    try {
      await step();
    } catch (e) {
      throw new CreatePartial(key, name, e, steps.slice(i + 1).map(([n]) => n));
    }
  }
  return { disposition: 'created', key };
}

type Step = [string, () => Promise<unknown> | unknown];

function afterCreateSteps(
  options: CreateOptions,
  key: string,
  title: string,
  o: { overrideReason?: string; admission?: Awaited<ReturnType<typeof checkIntakeGate>>; residual?: ResidualPlan; overCapReason?: string },
): Step[] {
  const { overrideReason, admission, residual, overCapReason } = o;
  const parentKey = options.residualOf ?? options.followUpOf;
  const steps: Step[] = [];
  if (overrideReason !== undefined) {
    steps.push(['writing the admissions ledger row', () => appendAdmission({ version: options.fixVersion!, kind: 'override', reason: overrideReason, key })]);
  }
  if (admission) steps.push(['writing the admissions ledger row', () => appendAdmission({ ...admission, key })]);
  if (residual?.displaced) steps.push([`displacing ${residual.displaced.key}`, () => displaceResidual(residual, key, { type: options.type, title })]);
  if (overCapReason) steps.push(['recording the over-cap reason', () => request('POST', `/issue/${key}/comment`, { body: markdownToAdf(overCapReason) })]);
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
