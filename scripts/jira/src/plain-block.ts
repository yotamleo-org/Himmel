// HIMMEL-5226: the ticket shape. Every ticket body opens with a plain-language
// Impact / What / Why block (readable without knowing the code), then an
// "Agent detail" section (files, contract, done-when, suites). `create` refuses
// a body without it; the roadmap tracker reads the Impact section.
//
// Headings are matched by their words, not their level, so the same check runs
// on markdown (`## Impact`) and on a pre-built ADF doc (heading nodes).

export const PLAIN_SECTIONS = ['Impact', 'What', 'Why', 'Agent detail'] as const;

export const PLAIN_BLOCK_TEMPLATE = `## Impact
<who notices, and what they see today — plain words, no file paths>

## What
<what we change, in one or two sentences>

## Why
<why it is worth doing now>

## Agent detail
<files, contract, done-when, suites>`;

/** Types that only warn: an Epic is a container, a Subtask inherits its parent's framing. */
const WARN_ONLY_TYPES = new Set(['epic', 'subtask', 'sub-task']);

export type PlainVerdict = { action: 'ok' | 'warn' | 'refuse'; message: string };

type Part = { heading: string; body: string };

const HEADING = /^\s{0,3}#{1,6}\s*(.*?)\s*#*\s*$/;

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
    const fm = /^\s{0,3}(`{3,}|~{3,})/.exec(line);
    if (fm) {
      // A fence closes only on the same character, at least as long as the opener.
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

function problems(ps: Part[]): string[] {
  const out: string[] = [];
  for (const want of PLAIN_SECTIONS) {
    const hit = ps.filter((p) => canonical(p.heading) === want);
    if (hit.length === 0) out.push(`missing "## ${want}"`);
    else if (!hit.some((p) => p.body.trim() !== '')) out.push(`"## ${want}" is empty`);
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
    else if (ps.length) ps[ps.length - 1]!.body += text(n) + '\n';
  }
  return problems(ps);
}

export function plainBlockVerdict(type: string, found: string[]): PlainVerdict {
  if (found.length === 0) return { action: 'ok', message: '' };
  const why = `ticket body lacks the plain Impact/What/Why block: ${found.join('; ')}`;
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
