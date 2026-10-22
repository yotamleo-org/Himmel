import type { Command } from 'commander';
import { request, severityField } from '../client.js';
import { writeJiraBreadcrumb } from '../breadcrumb.js';
import { markdownToAdf } from '../adf.js';
import { appendAdmission } from './admissions-ledger.js';
import { readBodyFile } from './body-file.js';
import { assertIntakeGate, checkConsoleOverride, checkIntakeGate, INTAKE_GATES } from './intake-gate.js';
import { nextResidualDepth } from './create.js';
import { parseLabels } from './labels.js';
import { requireSectorField, resolveSector, sectorOf, sectorOptions } from './sector.js';
import { assertVersionExists, buildFixVersionBody, projectFromKey, resolveAffectsVersion } from './versions.js';

export interface EditOptions {
  priority?: string;
  severity?: string;
  title?: string;
  description?: string;
  parent?: string;
  labels?: string;
  addLabels?: string;
  removeLabels?: string;
  fixVersion?: string;
  addFixVersion?: string;
  affectsVersion?: string;
  sector?: string;
}

export function buildEditFields(opts: EditOptions, sectors: readonly string[] = []): Record<string, unknown> {
  if (opts.labels !== undefined && opts.addLabels !== undefined) {
    throw new Error(
      'Edit --labels and --add-labels are mutually exclusive: --labels replaces the full ' +
        'label set, --add-labels appends to it — pick one.',
    );
  }
  if (opts.removeLabels !== undefined && (opts.labels !== undefined || opts.addLabels !== undefined)) {
    throw new Error(
      'Edit --remove-labels is mutually exclusive with --labels and --add-labels: ' +
        '--remove-labels drops the named labels only — pick one.',
    );
  }
  if (opts.fixVersion !== undefined && opts.addFixVersion !== undefined) {
    throw new Error(
      'Edit --fix-version and --add-fix-version are mutually exclusive: --fix-version replaces ' +
        'the full fixVersion set, --add-fix-version appends to it — pick one.',
    );
  }
  const fields: Record<string, unknown> = {};
  if (opts.priority) fields['priority'] = { name: opts.priority };
  if (opts.severity) {
    const field = severityField();
    if (!field) {
      throw new Error(
        'Edit --severity requires the JIRA_SEVERITY_FIELD env var to name the ' +
          'custom field ID (e.g. customfield_10016). Set it in .env and retry.', // env-literal-ok: example id in user-facing help text
      );
    }
    fields[field] = { value: opts.severity };
  }
  // Jira's REST field name is `summary`; the CLI surfaces it as `--title`
  // because that's what every other ticket-system surface (GitHub PRs, gh CLI,
  // the create subcommand) calls it. Same string, different name.
  if (opts.title !== undefined) fields['summary'] = opts.title;
  // Description must be ADF (Atlassian Document Format). Pipe through the
  // shared markdownToAdf converter so `--desc` accepts plain markdown like
  // every other description-bearing subcommand.
  if (opts.description !== undefined) fields['description'] = markdownToAdf(opts.description);
  // Re-parent under an epic (or convert to/from a child). Mirrors
  // `create --parent`: Jira's field is `parent: { key }`. Closes the gap
  // that otherwise forced an MCP editJiraIssue fallback (blocked by the
  // plugin-first hook).
  if (opts.parent) fields['parent'] = { key: opts.parent };
  // --labels is FULL-REPLACE: the comma-separated set becomes
  // the issue's complete label list — any existing label not in the set is
  // removed. Use --add-labels for an incremental, non-destructive
  // append instead.
  if (opts.labels !== undefined) fields['labels'] = parseLabels(opts.labels);
  // --fix-version is FULL-REPLACE, same rationale as --labels: a single-valued
  // field the operator explicitly wants set. --add-fix-version
  // appends via Jira's atomic `update` operation instead.
  if (opts.fixVersion !== undefined) fields['fixVersions'] = [{ name: opts.fixVersion }];
  // --affects-version is FULL-REPLACE, like --fix-version; the `affects-version`
  // verb adds or removes one. The action resolves `current` before it gets here.
  if (opts.affectsVersion !== undefined) fields['versions'] = [{ name: opts.affectsVersion }];
  if (opts.sector !== undefined) fields[requireSectorField()] = { value: resolveSector(opts.sector, sectors) };
  if (
    Object.keys(fields).length === 0 &&
    opts.addLabels === undefined &&
    opts.removeLabels === undefined &&
    opts.addFixVersion === undefined
  ) {
    throw new Error(
      'Edit requires at least one of --priority, --severity, --title, --desc, --parent, ' +
        '--labels, --add-labels, --remove-labels, --fix-version, --add-fix-version, --affects-version, or --sector',
    );
  }
  return fields;
}

// Jira's atomic `update` operation for labels: unlike `fields.labels`
// (full-replace), `update.labels: [{ add: '<label>' }, ...]` appends without ever
// reading or replacing the issue's existing label set.
export function buildAddLabelsUpdate(addLabels: string): { labels: Array<{ add: string }> } {
  return { labels: parseLabels(addLabels).map((label) => ({ add: label })) };
}

// The atomic counterpart of buildAddLabelsUpdate: drops only the named labels.
export function buildRemoveLabelsUpdate(removeLabels: string): { labels: Array<{ remove: string }> } {
  return { labels: parseLabels(removeLabels).map((label) => ({ remove: label })) };
}

// Jira field names edit sends, in read-back order.
function readBackFieldNames(o: EditOptions): string[] {
  const names: string[] = [];
  if (o.priority) names.push('priority');
  if (o.severity) {
    const sev = severityField();
    if (sev) names.push(sev);
  }
  if (o.title !== undefined) names.push('summary');
  if (o.description !== undefined) names.push('description');
  if (o.parent) names.push('parent');
  if (o.sector !== undefined) names.push(requireSectorField());
  if (o.labels !== undefined || o.addLabels !== undefined || o.removeLabels !== undefined) {
    names.push('labels');
  }
  if (o.fixVersion !== undefined || o.addFixVersion !== undefined) names.push('fixVersions');
  if (o.affectsVersion !== undefined) names.push('versions');
  return [...new Set(names)];
}

// Plain text of an ADF node: every `text` leaf, whitespace collapsed. Jira
// normalises ADF on save, so descriptions are compared as text, not structure.
function adfText(node: unknown): string {
  const walk = (n: unknown): string => {
    if (!n || typeof n !== 'object') return '';
    const o = n as { text?: unknown; content?: unknown };
    const own = typeof o.text === 'string' ? o.text : '';
    const kids = Array.isArray(o.content) ? o.content.map(walk).join('') : '';
    return own + kids;
  };
  return walk(node).replace(/\s+/g, ' ').trim();
}

// Returns one message per sent field whose read-back value differs.
function verifyReadBack(
  key: string,
  o: EditOptions,
  sent: Record<string, unknown>,
  got: Record<string, unknown>,
): string[] {
  const out: string[] = [];
  const bad = (label: string, requested: string, actual: string | undefined): void => {
    out.push(
      `Edit ${key}: ${label} was not changed — requested '${requested}' but the issue ` +
        `still reads '${actual || 'none'}' after the PUT.`,
    );
  };
  const same = (a: string | undefined, b: string): boolean => a?.toLowerCase() === b.toLowerCase();
  const labels = Array.isArray(got['labels']) ? (got['labels'] as string[]) : [];
  const versions = Array.isArray(got['fixVersions'])
    ? (got['fixVersions'] as Array<{ name?: string }>).map((v) => v.name ?? '')
    : [];

  if (o.priority) {
    const actual = (got['priority'] as { name?: string } | null | undefined)?.name;
    if (!same(actual, o.priority)) bad('priority', o.priority, actual);
  }
  const sev = severityField();
  if (o.severity && sev) {
    const actual = (got[sev] as { value?: string } | null | undefined)?.value;
    if (!same(actual, o.severity)) bad('severity', o.severity, actual);
  }
  if (o.sector !== undefined) {
    const want = (sent[requireSectorField()] as { value: string }).value;
    const actual = sectorOf(got);
    if (actual !== want) bad('sector', want, actual);
  }
  if (o.title !== undefined) {
    const actual = got['summary'] as string | undefined;
    if (actual?.trim() !== o.title.trim()) bad('title', o.title, actual);
  }
  if (o.description !== undefined) {
    const want = adfText(sent['description']);
    const actual = adfText(got['description']);
    if (actual !== want) bad('description', want, actual);
  }
  if (o.parent) {
    const actual = (got['parent'] as { key?: string } | null | undefined)?.key;
    if (!same(actual, o.parent)) bad('parent', o.parent, actual);
  }
  if (o.labels !== undefined) {
    const want = parseLabels(o.labels);
    if (new Set(want).size !== new Set(labels).size || !want.every((l) => labels.includes(l))) {
      bad('labels', want.join(', '), labels.join(', '));
    }
  }
  if (o.addLabels !== undefined) {
    const want = parseLabels(o.addLabels);
    if (!want.every((l) => labels.includes(l))) bad('add-labels', want.join(', '), labels.join(', '));
  }
  if (o.removeLabels !== undefined) {
    const want = parseLabels(o.removeLabels);
    if (!Array.isArray(got['labels'])) bad('remove-labels', `without ${want.join(', ')}`, 'labels not returned');
    else if (want.some((l) => labels.includes(l))) bad('remove-labels', `without ${want.join(', ')}`, labels.join(', '));
  }
  if (o.fixVersion !== undefined) {
    if (versions.length !== 1 || versions[0] !== o.fixVersion) {
      bad('fix-version', o.fixVersion, versions.join(', '));
    }
  }
  if (o.addFixVersion !== undefined && !versions.includes(o.addFixVersion)) {
    bad('add-fix-version', o.addFixVersion, versions.join(', '));
  }
  if (o.affectsVersion !== undefined) {
    const affects = Array.isArray(got['versions'])
      ? (got['versions'] as Array<{ name?: string }>).map((v) => v.name ?? '')
      : [];
    if (affects.length !== 1 || affects[0] !== o.affectsVersion) {
      bad('affects-version', o.affectsVersion, affects.join(', '));
    }
  }
  return out;
}

// `--residual-of <parent>`: turns the flag into the label and affects-version edits that
// stamp the ticket as a residual one level below its parent, and returns the fixVersions to
// drop (all of them at depth 2 or more, none below). The verb is the only place that depth is decided.
async function stampResidual(key: string, options: EditOptions & { residualOf?: string }): Promise<string[]> {
  const parent = options.residualOf as string;
  if (!/^[A-Z][A-Z0-9]*-[0-9]+$/.test(parent)) {
    throw new Error(`--residual-of must be a ticket key like PROJ-123 (got '${parent}')`);
  }
  const clashing = (
    [
      ['--labels', options.labels],
      ['--add-labels', options.addLabels],
      ['--remove-labels', options.removeLabels],
      ['--fix-version', options.fixVersion],
      ['--add-fix-version', options.addFixVersion],
      ['--affects-version', options.affectsVersion],
    ] as const
  ).filter(([, v]) => v !== undefined);
  if (clashing.length > 0) {
    throw new Error(`Edit --residual-of cannot be combined with ${clashing.map(([f]) => f).join(', ')}: it sets the labels and versions itself.`);
  }
  const parentIssue = await request<{ fields?: { labels?: string[] } }>('GET', `/issue/${parent}?fields=labels`);
  const parentLabels = parentIssue.fields?.labels;
  if (!Array.isArray(parentLabels)) {
    throw new Error(`Edit ${key}: the read of ${parent} carried no labels list; refusing to guess the residual depth.`);
  }
  const depth = nextResidualDepth(parentLabels);
  options.addLabels = `residual-depth-${depth}`;
  options.affectsVersion = 'current';
  if (depth < 2) return [];
  const own = await request<{ fields?: { fixVersions?: Array<{ name?: string }> } }>('GET', `/issue/${key}?fields=fixVersions`);
  const ownVersions = own.fields?.fixVersions;
  if (!Array.isArray(ownVersions)) {
    throw new Error(`Edit ${key}: the read of ${key} carried no fixVersions list; refusing to skip the fix-version drop.`);
  }
  return ownVersions.map((v) => v.name ?? '').filter((name) => name !== '');
}

export function registerEdit(program: Command): void {
  program
    .command('edit <key>')
    .description(
      'Edit a Jira issue (priority, severity, title, description, parent, labels, and/or fix version)',
    )
    .option('--priority <p>', 'Priority: Highest|High|Medium|Low|Lowest')
    .option('--severity <s>', 'Severity (custom field): free text')
    .option('--sector <s>', 'Sector (single-select custom field; unknown option refused)')
    .option('--title <t>', 'New summary/title (plain text)')
    .option(
      '--desc <d>',
      'New description (markdown; converted to ADF). Alias of --description.',
    )
    .option('--description <d>', 'New description (markdown; converted to ADF)')
    .option(
      '--desc-file <path>',
      'Read the markdown description from a file (overrides --desc/--description; ' +
        'keeps the shell command single-line for multi-line descriptions)',
    )
    .option('--parent <key>', 'Parent issue key (e.g. epic) — re-parents the issue')
    .option(
      '--labels <labels>',
      'REPLACE the issue labels with this comma-separated set (full-replace: ' +
        'existing labels not listed are removed)',
    )
    .option(
      '--add-labels <labels>',
      'APPEND these comma-separated labels without touching existing ones ' +
        '(mutually exclusive with --labels)',
    )
    .option(
      '--remove-labels <labels>',
      'DROP these comma-separated labels without touching the others ' +
        '(mutually exclusive with --labels and --add-labels)',
    )
    .option(
      '--fix-version <name>',
      'REPLACE the issue fixVersions with this single version (validated against the ' +
        "project's versions; full-replace)",
    )
    .option(
      '--add-fix-version <name>',
      'APPEND this version to fixVersions without touching existing ones ' +
        '(validated against the project\'s versions; mutually exclusive with --fix-version)',
    )
    .option(
      '--affects-version <name>',
      'REPLACE the issue affectsVersions with this single version (validated against the ' +
        "project's versions; `current` = the earliest unreleased version)",
    )
    .option(
      '--residual-of <key>',
      'Stamp this ticket as a review residual of <key>: adds residual-depth-<parent depth + 1>, ' +
        'sets affectsVersion to the current version, and at depth 2 or more drops its fixVersions ' +
        '(cannot be combined with the label or version flags)',
    )
    .option(
      '--gate <reason>',
      `Required to move a ticket into a frozen version (${INTAKE_GATES}); recorded in the admissions ledger`,
    )
    .option(
      '--console-override <reason>',
      'Console session only (HIMMEL_CONSOLE=1): admit into a frozen version without a gate; the reason is recorded in the admissions ledger',
    )
    .action(async (key: string, options: EditOptions & { desc?: string; descFile?: string; gate?: string; consoleOverride?: string; residualOf?: string }) => {
      // `--desc` and `--description` are aliases; whichever the operator
      // passed wins (and if both, --description wins because it's parsed
      // last by commander's option-order). `--desc-file` overrides both — it
      // is the escape hatch for multi-line bodies that can't go inline.
      if (options.descFile !== undefined) {
        options.description = readBodyFile(options.descFile, '--desc-file');
      } else if (options.desc !== undefined && options.description === undefined) {
        options.description = options.desc;
      }
      const dropFixVersions = options.residualOf === undefined ? [] : await stampResidual(key, options);
      if (options.affectsVersion !== undefined) {
        options.affectsVersion = await resolveAffectsVersion(projectFromKey(key), options.affectsVersion);
      }
      const fields = buildEditFields(options, options.sector !== undefined ? await sectorOptions() : []);
      if (options.fixVersion !== undefined) {
        await assertVersionExists(projectFromKey(key), options.fixVersion);
      }
      if (options.addFixVersion !== undefined) {
        await assertVersionExists(projectFromKey(key), options.addFixVersion);
      }
      const target = options.fixVersion ?? options.addFixVersion;
      if (options.gate !== undefined) assertIntakeGate(options.gate);
      let overrideReason: string | undefined;
      if (options.consoleOverride !== undefined) {
        overrideReason = checkConsoleOverride(options.consoleOverride);
        if (target === undefined) throw new Error('--console-override needs the --fix-version or --add-fix-version to admit into');
      }
      const admission =
        target === undefined
          ? undefined
          : await checkIntakeGate(projectFromKey(key), [{ name: target }], {
              gate: options.gate,
              override: overrideReason !== undefined,
            });
      const body: { fields?: Record<string, unknown>; update?: Record<string, unknown> } = {};
      if (Object.keys(fields).length > 0) body.fields = fields;
      const update: Record<string, unknown> = {};
      if (options.addLabels !== undefined) {
        Object.assign(update, buildAddLabelsUpdate(options.addLabels));
      }
      if (options.removeLabels !== undefined) {
        Object.assign(update, buildRemoveLabelsUpdate(options.removeLabels));
      }
      if (options.addFixVersion !== undefined) {
        Object.assign(update, buildFixVersionBody('add', options.addFixVersion).update);
      }
      if (dropFixVersions.length > 0) {
        update['fixVersions'] = dropFixVersions.map((name) => ({ remove: { name } }));
      }
      if (Object.keys(update).length > 0) body.update = update;
      await request('PUT', `/issue/${key}`, body);
      // A 2xx PUT does not prove the field changed (Jira can drop a
      // field its edit screen or scheme does not take), so read the priority
      // back and fail loud instead of reporting a silent no-op as "edited".
      // Same for every other field edit sends — one GET covers all.
      const names = [...new Set([...readBackFieldNames(options), ...(dropFixVersions.length > 0 ? ['fixVersions'] : [])])];
      if (names.length > 0) {
        const got = await request<{ fields?: Record<string, unknown> }>(
          'GET',
          `/issue/${key}?fields=${names.join(',')}`,
        );
        const mismatches = verifyReadBack(key, options, fields, got.fields ?? {});
        const readBackVersions = got.fields?.['fixVersions'];
        const stillThere = Array.isArray(readBackVersions)
          ? dropFixVersions.filter((name) => (readBackVersions as Array<{ name?: string }>).some((v) => v.name === name))
          : dropFixVersions;
        if (dropFixVersions.length > 0 && !Array.isArray(readBackVersions)) {
          mismatches.push(
            `Edit ${key}: fix-version was not changed — requested removal of '${dropFixVersions.join(', ')}' but the read-back carried no fixVersions list, so the removal is unproven.`,
          );
        } else if (stillThere.length > 0) {
          mismatches.push(
            `Edit ${key}: fix-version was not changed — requested removal of '${stillThere.join(', ')}' but the issue still carries it after the PUT.`,
          );
        }
        // The admission row is written once the target version reads back, so a dropped fixVersions
        // field leaves no row and another field failing its read-back cannot leave the admission unrecorded.
        const landed = Array.isArray(got.fields?.['fixVersions']) &&
          (got.fields['fixVersions'] as Array<{ name?: string }>).some((v) => v.name === target);
        if (target !== undefined && landed) {
          try {
            if (overrideReason !== undefined) appendAdmission({ version: target, key, kind: 'override', reason: overrideReason });
            if (admission) appendAdmission({ ...admission, key });
          } catch (e) {
            console.error(`Edited ${key} but writing the admissions ledger row failed: ${(e as Error).message}`);
            process.exit(1);
          }
        }
        if (mismatches.length > 0) throw new Error(mismatches.join('\n'));
      }
      writeJiraBreadcrumb(key);
      console.log(`${key} edited`);
    });
}
