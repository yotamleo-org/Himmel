import { readFileSync } from 'node:fs';
import type { Command } from 'commander';
import { request, projectKey } from '../client.js';
import { writeJiraBreadcrumb } from '../breadcrumb.js';
import { markdownToAdf } from '../adf.js';
import type { CreateIssueResponse } from '../types.js';
import { uploadAll } from './attach-helper.js';
import { readBodyFile } from './body-file.js';
import { parseLabels } from './labels.js';
import { homeVerdict, lintPlainBlock, lintPlainBlockAdf, plainBlockVerdict, PLAIN_BLOCK_TEMPLATE } from '../plain-block.js';
import { resolveSector, sectorField, sectorOptions } from './sector.js';
import { searchAllIssues } from './list.js';
import { createIssueLink } from './link.js';
import { appendAdmission, assertAdmissionsWritable, type AdmissionInput } from './admissions-ledger.js';
import { assertIntakeGate, checkIntakeGate, INTAKE_GATES } from './intake-gate.js';
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
// Open hardening residuals a version takes before the rest go to the backlog;
// a `residual-budget:N` line in the version description overrides it.
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
}

async function planResidual(
  project: string,
  o: { residualOf: string; fuClass?: string; class?: string; area?: string; fixVersion?: string },
): Promise<ResidualPlan> {
  if (!o.fuClass) throw new Error('--residual-of requires --fu-class <polish|escape|hardening>');
  if (o.class !== undefined && !o.class) throw new Error('--class needs an id');
  if (!FU_CLASSES.includes(o.fuClass)) {
    throw new Error(`--fu-class must be one of ${FU_CLASSES.join(', ')} (got "${o.fuClass}")`);
  }
  if (o.fixVersion !== undefined) throw new Error('--residual-of chooses the version itself; drop --fix-version');
  const classLabel = o.class !== undefined ? `class-${labelSlug(o.class)}` : undefined;
  const labels = ['residual'];
  if (classLabel) labels.push(classLabel);
  const area = o.area ? `area-${labelSlug(o.area)}` : undefined;
  if (area) labels.push(area);

  if (area && classLabel) {
    const jql =
      `project = ${project} AND labels = residual AND labels = ${jqlQuote(classLabel)} AND labels = ${jqlQuote(area)}` +
      ` AND key != ${jqlQuote(o.residualOf)} AND statusCategory != Done`;
    const [dup] = await searchAllIssues(jql, '1', request);
    if (dup) return { labels, duplicateOf: dup.key };
  }

  const parent = await request<{ fields: { labels?: string[] } }>('GET', `/issue/${o.residualOf}?fields=labels`);
  const depth = nextResidualDepth(parent.fields.labels ?? []);
  labels.push(`residual-depth-${depth}`);

  const versions = await fetchVersions(project);
  const current = earliestUnreleased(versions);
  let fixVersion: string | undefined;
  if (current && depth < 2 && o.fuClass !== 'polish') {
    fixVersion = current;
    if (o.fuClass === 'hardening') {
      const budget = residualBudget(versions.find((v) => v.name === current)?.description);
      const jql =
        `project = ${project} AND fixVersion = ${jqlQuote(current)} AND labels = residual` +
        ' AND labels != residual-overflow AND statusCategory != Done';
      const open = await searchAllIssues(jql, String(budget), request);
      if (open.length >= budget) {
        fixVersion = undefined;
        labels.push('residual-overflow');
      }
    }
  }
  return { labels, fixVersion, affectsVersion: current };
}

/**
 * Sets fixVersions and versions on a new ticket. Filing into the current
 * unreleased version is held to its residual cap; an operator-directed ticket
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
    overCapReason = `Filed over the ${st.current} cap (${st.open}/${st.cap} open residuals): ${options.overCap}`;
    fields['labels'] = [...new Set([...(o.labels ?? []), OVER_CAP_LABEL])];
  };
  if (options.fixVersion !== undefined) {
    await assertVersionExists(project, options.fixVersion);
    fields['fixVersions'] = [{ name: options.fixVersion }];
    const st = gated ? await capState(project, options.fixVersion) : undefined;
    if (st && st.open >= st.cap) {
      if (options.overCap === undefined) {
        console.error(
          `jira: ${st.current} is at its residual cap (${st.open}/${st.cap} open); ` +
            'pass --over-cap <reason> to file into it anyway, or file into a later version',
        );
        process.exit(1);
      }
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

/**
 * A console override needs a reason, the console marker and a ledger location.
 * Returns the trimmed reason; the ledger probe throws when no location is set
 * or the ledger cannot take an append, so no ticket is filed without its row.
 */
function checkConsoleOverride(reason: string): string {
  const trimmed = reason.trim();
  if (!trimmed) throw new Error('--console-override needs a reason');
  // ponytail: any same-uid caller can set HIMMEL_CONSOLE, upgrade path: the RM signed-row design (HIMMEL-6796)
  if (process.env['HIMMEL_CONSOLE'] !== '1') {
    throw new Error('--console-override is for the console session only (HIMMEL_CONSOLE=1 is not set)');
  }
  assertAdmissionsWritable();
  return trimmed;
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
    .option('--labels <labels>', 'Comma-separated labels to set (e.g. a,b); `standalone` marks a ticket with no parent epic')
    .option('--sector <s>', 'Sector (single-select custom field; required for a Task, Story or Bug once JIRA_SECTOR_FIELD is set)')
    .option(
      '--fix-version <name>',
      "Set the fixVersion (validated against the project's versions; an explicit value wins over the Bug default of the earliest unreleased version)",
    )
    .option('--priority <name>', 'Priority name (e.g. Highest); a Highest Bug is placed in the active version')
    .option('--backlog', 'File a Bug to the backlog: label backlog, no fixVersion (a Bug without --fix-version needs this, --gate or --priority Highest)')
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
    .option('--fu-class <class>', 'Residual routing class: polish (backlog), escape (current version), hardening (current version under budget)')
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
        if (options.sector !== undefined && !sectors) {
          console.error('jira: warning: --sector ignored, Sector is not configured (run `jira sector setup`)');
        }
        const sector =
          options.sector !== undefined && sectors ? resolveSector(options.sector, sectors) : undefined;
        let labels = options.labels !== undefined ? parseLabels(options.labels) : undefined;
        let residual: ResidualPlan | undefined;
        if (options.residualOf !== undefined) {
          residual = await planResidual(options.project ?? projectKey(), { ...options, residualOf: options.residualOf });
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
        const placed = placeBug(options, labels, residual !== undefined);
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
          console.error(`jira: residual routed to ${residual.fixVersion ?? 'the backlog'}`);
        }
        const overCapReason = await applyVersions(options.project ?? projectKey(), options, fields, {
          labels,
          residual: residual !== undefined,
          bugDefault: placed.bugDefault,
        });
        const admission = await checkIntakeGate(options.project ?? projectKey(), fields['fixVersions'], {
          gate: options.gate,
          override: overrideReason !== undefined,
        });

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
