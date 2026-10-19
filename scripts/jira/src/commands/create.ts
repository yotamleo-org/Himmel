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
  if (!o.class) throw new Error('--residual-of requires --class <id>');
  if (!FU_CLASSES.includes(o.fuClass)) {
    throw new Error(`--fu-class must be one of ${FU_CLASSES.join(', ')} (got "${o.fuClass}")`);
  }
  if (o.fixVersion !== undefined) throw new Error('--residual-of chooses the version itself; drop --fix-version');
  const labels = ['residual', `class-${labelSlug(o.class)}`];
  const area = o.area ? `area-${labelSlug(o.area)}` : undefined;
  if (area) labels.push(area);

  if (area) {
    const jql =
      `project = ${project} AND labels = residual AND labels = ${jqlQuote(labels[1])} AND labels = ${jqlQuote(area)}` +
      ' AND statusCategory != Done';
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
    .option(
      '--affects-version <name>',
      "Set the affectsVersion (validated against the project's versions; `current` = the earliest unreleased version)",
    )
    .option(
      '--residual-of <key>',
      'File this as a review residual of <key>: the writer picks the version, depth and labels (needs --fu-class and --class)',
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
        affectsVersion?: string;
        residualOf?: string;
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
        const fields: Record<string, unknown> = {
          project: { key: options.project ?? projectKey() },
          summary: resolveTitle(options),
          issuetype: { name: options.type },
        };
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
            await request('POST', `/issue/${dup}/comment`, {
              body: markdownToAdf(`Re-raised as a residual of ${options.residualOf}: ${resolveTitle(options)}`),
            });
            await createIssueLink(dup, options.residualOf, { name: 'Relates', inward: 'relates to' });
            console.log(`Duplicate ${dup}`);
            return;
          }
          labels = [...new Set([...(labels ?? []), ...residual.labels])];
        }
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
        if (options.fixVersion !== undefined) {
          await assertVersionExists(options.project ?? projectKey(), options.fixVersion);
          fields['fixVersions'] = [{ name: options.fixVersion }];
        }
        if (options.affectsVersion !== undefined) {
          const version = await resolveAffectsVersion(options.project ?? projectKey(), options.affectsVersion);
          fields['versions'] = [{ name: version }];
        }
        // A Bug without an explicit --fix-version defaults to the earliest
        // unreleased version; an unreadable/empty version list files with no
        // fixVersion rather than guess. The release gate is the
        // v1-blocker label and priority, not the version default.
        if (!residual && options.fixVersion === undefined && options.type.toLowerCase() === 'bug') {
          let defaultVersion: string | undefined;
          try {
            defaultVersion = earliestUnreleased(await fetchVersions(options.project ?? projectKey()));
          } catch {
            defaultVersion = undefined;
          }
          // stderr: stdout stays the bare `Created KEY` line scripted callers capture.
          if (defaultVersion) {
            fields['fixVersions'] = [{ name: defaultVersion }];
            console.error(`jira: Bug defaults to fixVersion ${defaultVersion} (earliest unreleased); --fix-version overrides`);
          } else {
            console.error('jira: no unreleased version found; filing the Bug with no fixVersion');
          }
        }

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
