// The ticket shape. The body rules are ONE policy, ticket-policy.mjs in the
// himmel-ops plugin, shared with the offline draft checker: seven
// sections (Impact, What, Why, Plan, DoD, Proof, Agent detail), Plan and DoD each
// needing a real list item, a Metric line for a ci/guard/stability label and an
// Edges line for a Plan naming two or more tickets. This file keeps the CLI's
// wrappers around it plus the title and home helpers.

import { SECTORS } from './commands/sector.js';
import {
  SECTIONS,
  isWarnOnlyType,
  renderTicketSkeleton,
  validateTicketBody,
  type BodyInput,
  type Diagnostic,
} from '../../../marketplace/plugins/himmel-ops/scripts/ticket-policy.mjs';

export type { BodyInput, Diagnostic };

export const PLAIN_SECTIONS = SECTIONS;

export const PLAIN_BLOCK_TEMPLATE = renderTicketSkeleton();

export type PlainVerdict = { action: 'ok' | 'warn' | 'refuse'; message: string };

/** Every body finding for a ticket of `type` carrying `labels` (the labels actually written). */
export function bodyDiagnostics(input: BodyInput, type: string, labels: readonly string[] = []): Diagnostic[] {
  return validateTicketBody(input, { issueType: type, labels }).diagnostics;
}

/** The body findings of a markdown body, as messages (empty when it meets the standard). */
export function lintPlainBlock(md: string | undefined, labels: readonly string[] = []): string[] {
  return bodyDiagnostics({ format: 'markdown', body: md ?? '' }, 'Task', labels).map((d) => d.message);
}

/** ADF twin of lintPlainBlock: the same policy on the same normalized blocks. */
export function lintPlainBlockAdf(doc: unknown, labels: readonly string[] = []): string[] {
  return bodyDiagnostics({ format: 'adf', body: doc }, 'Task', labels).map((d) => d.message);
}

export function plainBlockVerdict(type: string, found: string[]): PlainVerdict {
  if (found.length === 0) return { action: 'ok', message: '' };
  const why = `ticket body lacks the ticket shape (${SECTIONS.join(', ')}): ${found.join('; ')}`;
  if (isWarnOnlyType(type)) {
    return { action: 'warn', message: `jira: warning: ${why} (${type} is exempt, filing anyway)` };
  }
  return {
    action: 'refuse',
    message:
      `jira: refused: ${why}.\n` +
      `Start the body with this shape (docs/internals/jira-plugin.md, "Ticket shape"):\n\n` +
      PLAIN_BLOCK_TEMPLATE,
  };
}

export const STANDALONE_LABEL = 'standalone';

/**
 * The home rule: a ticket carries a Sector and either a parent epic or the
 * `standalone` label. Epic and Subtask only warn, as in plainBlockVerdict.
 * `sectors` is the configured field's option list; undefined means sectors are
 * not in use (JIRA_SECTOR_FIELD unset), so only the epic-or-standalone check runs.
 */
export function homeVerdict(
  type: string,
  home: { sector?: string; parent?: string; labels?: string[] },
  sectors?: readonly string[],
): PlainVerdict {
  const missing: string[] = [];
  if (sectors && !home.sector)
    missing.push(
      `no Sector (pass --sector "<${sectors.join(' | ')}>", or run \`jira sector setup --opt-out\` to stop using sectors)`,
    );
  const standalone = (home.labels ?? []).includes(STANDALONE_LABEL);
  if (!home.parent && !standalone)
    missing.push(
      `neither a parent epic nor the ${STANDALONE_LABEL} label (pass --parent <EPIC-KEY> or --labels ${STANDALONE_LABEL})`,
    );
  if (missing.length === 0) return { action: 'ok', message: '' };
  const why = `ticket has no home: ${missing.join('; ')}`;
  if (isWarnOnlyType(type)) {
    return { action: 'warn', message: `jira: warning: ${why} (${type} is exempt, filing anyway)` };
  }
  return { action: 'refuse', message: `jira: refused: ${why}.` };
}

/**
 * The Sector a create takes from its title when --sector is absent:
 * a leading "<Sector>:" naming a live option gives that option's canonical label.
 * A Task, Story or Bug whose "<Word>:" prefix names no live option is refused with
 * the valid list. A title with no prefix, a commit prefix (lowercase), an Epic or
 * Subtask, or an unreadable option list (`sectors` empty) derives nothing.
 */
export function titleSector(
  type: string,
  title: string,
  sectors: readonly string[],
): { sector?: string; refuse?: string } {
  if (sectors.length === 0 || isWarnOnlyType(type)) return {};
  const t = title.trim();
  const hit = sectors.find((s) => t.toLowerCase().startsWith(s.toLowerCase() + ':'));
  if (hit !== undefined) return { sector: hit };
  if (!SECTOR_SHAPED.test(t)) return {};
  return {
    refuse:
      `jira: refused: the title opens with "${t.slice(0, t.indexOf(':'))}:", which is not a Sector. ` +
      `Valid sectors: ${sectors.join(', ')}. Pass --sector, or retitle.`,
  };
}

export function titleTemplate(sectors: readonly string[] = SECTORS): string {
  return `Ticket title (system or user-facing):
  system:       <Sector>: <the result>   e.g. "Ship loop: merge waits for the signed GO"
  user-facing:  a short plain sentence of what the user can now do   e.g. "See which tickets are system work"
  Sectors: ${sectors.join(", ")}
  Leave out commit prefixes (feat(x):), ticket ids, and internal names (--flags, field_names, file paths).`;
}

export const TITLE_TEMPLATE = titleTemplate();

const TITLE_MAX = 90;
const COMMIT_PREFIX = /^[a-z]+(\([^)]*\))?!?:/;
const SECTOR_SHAPED = /^[A-Z][A-Za-z &-]*:/;
const TICKET_ID = /\b[A-Z][A-Z0-9]+-\d+\b/;
const INTERNAL_NAME = /`|(?:^|\s)--[a-z]|\b[a-z]+_[a-z_]+\b|\b(?:scripts|docs|src)\/|\S\.(?:ts|sh|md|json|tsv|ya?ml|js|py)\b/;

/**
 * Warn-only title check for a Task, Story or Bug: a system title opens with its
 * Sector, a user-facing one is a plain sentence. Epic and Subtask are exempt.
 * `sectors` is the live option list when the project uses sectors, else the defaults.
 */
export function titleVerdict(type: string, title: string, sectors: readonly string[] = SECTORS): PlainVerdict {
  if (isWarnOnlyType(type)) return { action: 'ok', message: '' };
  const t = title.trim();
  const found: string[] = [];
  if (!t) found.push('the title is empty');
  const sector = sectors.find((s) => t.toLowerCase().startsWith(s.toLowerCase() + ':'));
  if (sector !== undefined) {
    if (!t.slice(sector.length + 1).trim()) found.push('the sector has no result after it');
  } else if (COMMIT_PREFIX.test(t)) {
    found.push('it opens with a commit prefix');
  } else if (SECTOR_SHAPED.test(t)) {
    found.push(`it opens with "${t.slice(0, t.indexOf(':'))}:", which is not a Sector`);
  }
  if (TICKET_ID.test(t)) found.push('it names a ticket id');
  if (INTERNAL_NAME.test(t)) found.push('it uses an internal name (flag, field, path or code)');
  if (t.length > TITLE_MAX) found.push(`it is too long (${t.length} characters, keep it at most ${TITLE_MAX})`);
  if (found.length === 0) return { action: 'ok', message: '' };
  return {
    action: 'warn',
    message: `jira: warning: title does not fit the template: ${found.join('; ')} (filing anyway)\n${titleTemplate(sectors)}`,
  };
}
