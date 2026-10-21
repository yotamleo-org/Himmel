// The ticket shape. Every ticket body opens with a plain-language
// Impact / What / Why block (readable without knowing the code), then a Plan
// and a DoD (each needs a real bullet or numbered line, not the template hint),
// then an "Agent detail" section (files, contract, suites). `create` refuses a
// body without it; the roadmap tracker reads the Impact section.
//
// Headings are matched by their words, not their level, so the same check runs
// on markdown (`## Impact`) and on a pre-built ADF doc (heading nodes).

import { SECTORS } from './commands/sector.js';

export const PLAIN_SECTIONS = ['Impact', 'What', 'Why', 'Plan', 'DoD', 'Agent detail'] as const;

/** Sections that must hold at least one bullet or numbered line beyond the template hint. */
const LIST_SECTIONS = new Set<string>(['Plan', 'DoD']);

export const PLAIN_BLOCK_TEMPLATE = `## Impact
<who notices, and what they see today — plain words, no file paths>

## What
<what we change, in one or two sentences>

## Why
<why it is worth doing now>

## Plan
1. <one to five bounded steps, each naming the surface it touches>

## DoD
- <one to five checkable results: a test, a command and its output, a doc section, a Jira state>

## Agent detail
<files, contract, suites>`;

/** Types that only warn: an Epic is a container, a Subtask inherits its parent's framing. */
const WARN_ONLY_TYPES = new Set(['epic', 'subtask', 'sub-task']);

export type PlainVerdict = { action: 'ok' | 'warn' | 'refuse'; message: string };

type Part = { heading: string; body: string };

const HEADING = /^\s{0,3}#{1,6}(?:\s+(.*?))?\s*#*\s*$/;

function canonical(h: string): string | undefined {
  const w = h.replace(/[:*_`]/g, '').trim().toLowerCase();
  return PLAIN_SECTIONS.find((s) => s.toLowerCase() === w);
}

/** Split markdown into heading/body parts, ignoring fenced code. */
function parts(md: string): Part[] {
  const out: Part[] = [];
  let fence = '';
  let cur: Part | undefined;
  for (const line of md.split(/\r?\n/)) {
    const fm = fence
      ? /^\s{0,3}(`{3,}|~{3,})\s*$/.exec(line)
      : /^\s{0,3}(`{3,}|~{3,})/.exec(line);
    if (fm) {
      // A fence closes only on the same character, at least as long as the opener, with nothing after it.
      const f = fm[1]!;
      if (!fence) fence = f;
      else if (f[0] === fence[0] && f.length >= fence.length) fence = '';
    } else if (!fence) {
      const m = HEADING.exec(line);
      if (m && /^\s{0,3}#/.test(line)) {
        cur = { heading: m[1] ?? '', body: '' };
        out.push(cur);
        continue;
      }
    }
    if (cur) cur.body += line + '\n';
  }
  return out;
}

const LIST_LINE = /^\s*(?:[-*+]|\d+[.)])\s+(\S.*?)\s*$/;
const PLACEHOLDER = /^<[^>]*>$/;

/** A bullet or numbered line whose whole content is not an angle-bracket hint. */
function hasRealLine(body: string): boolean {
  return body.split(/\r?\n/).some((l) => {
    const m = LIST_LINE.exec(l);
    return m !== null && !PLACEHOLDER.test(m[1]!);
  });
}

function problems(ps: Part[]): string[] {
  const out: string[] = [];
  for (const want of PLAIN_SECTIONS) {
    const hit = ps.filter((p) => canonical(p.heading) === want);
    if (hit.length === 0) out.push(`missing "## ${want}"`);
    else if (!hit.some((p) => p.body.trim() !== '')) out.push(`"## ${want}" is empty`);
    else if (LIST_SECTIONS.has(want) && !hit.some((p) => hasRealLine(p.body)))
      out.push(`"## ${want}" has no bullet or numbered line beyond the placeholder`);
  }
  return out;
}

export function lintPlainBlock(md: string | undefined): string[] {
  return problems(parts(md ?? ''));
}

/** ADF twin: top-level heading nodes open sections; everything until the next heading is its body. */
export function lintPlainBlockAdf(doc: unknown): string[] {
  const nodes = ((doc as { content?: unknown[] } | null)?.content ?? []) as Array<{
    type?: string;
    content?: unknown[];
  }>;
  const text = (n: unknown): string => {
    const x = n as { text?: string; content?: unknown[] };
    return (x.text ?? '') + (x.content ?? []).map(text).join('');
  };
  const ps: Part[] = [];
  for (const n of nodes) {
    if (n.type === 'heading') ps.push({ heading: text(n), body: '' });
    else if (ps.length) {
      const cur = ps[ps.length - 1]!;
      // text() joins node text without newlines, so each list item becomes its own markdown-style line.
      if (n.type === 'bulletList' || n.type === 'orderedList')
        for (const item of n.content ?? []) cur.body += '- ' + text(item) + '\n';
      else
        // a quote marker keeps prose that reads "- x" from passing as a list item; blank lines stay blank
        cur.body += text(n).split('\n').map((l) => (l.trim() ? '> ' + l : l)).join('\n') + '\n';
    }
  }
  return problems(ps);
}

export function plainBlockVerdict(type: string, found: string[]): PlainVerdict {
  if (found.length === 0) return { action: 'ok', message: '' };
  const why = `ticket body lacks the ticket shape (Impact, What, Why, Plan, DoD, Agent detail): ${found.join('; ')}`;
  if (WARN_ONLY_TYPES.has(type.trim().toLowerCase())) {
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
  if (WARN_ONLY_TYPES.has(type.trim().toLowerCase())) {
    return { action: 'warn', message: `jira: warning: ${why} (${type} is exempt, filing anyway)` };
  }
  return { action: 'refuse', message: `jira: refused: ${why}.` };
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
  if (WARN_ONLY_TYPES.has(type.trim().toLowerCase())) return { action: 'ok', message: '' };
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
