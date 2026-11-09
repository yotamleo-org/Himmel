import { SECTIONS } from '../../../marketplace/plugins/himmel-ops/scripts/ticket-policy.mjs';

export interface AdfDoc {
  type: 'doc';
  version: 1;
  content: AdfBlock[];
}

type InlineNode = { type: 'text'; text: string; marks?: Mark[] };
type Mark =
  | { type: 'strong' }
  | { type: 'em' }
  | { type: 'code' }
  | { type: 'link'; attrs: { href: string } };

type AdfBlock =
  | { type: 'paragraph'; content: InlineNode[] }
  | { type: 'heading'; attrs: { level: 1 | 2 | 3 | 4 | 5 | 6 }; content: InlineNode[] }
  | { type: 'codeBlock'; attrs: { language?: string }; content: [{ type: 'text'; text: string }] }
  | { type: 'bulletList'; content: ListItem[] }
  | { type: 'orderedList'; content: ListItem[] };

type ListItem = {
  type: 'listItem';
  content: [{ type: 'paragraph'; content: InlineNode[] }];
};

// CommonMark: an underscore between two word characters is a literal, never an
// emphasis mark (HIMMEL_API_LANE). `_` and `__` open only when not preceded by a
// word character or underscore, close only when not followed by one, and may hold
// intraword single underscores inside. Asterisk emphasis is unchanged.
const W = '\\p{L}\\p{N}';
const INLINE_RE = new RegExp(
  '(\\*\\*[^*]+\\*\\*' +
    `|(?<![${W}_])__(?:[^_]|(?<=[${W}])_(?=[${W}]))+__(?![${W}_])` +
    '|`[^`]+`|\\[[^\\]]+\\]\\([^)]+\\)|\\*[^*]+\\*' +
    `|(?<![${W}_])_(?:[^_]|(?<=[${W}])_(?=[${W}]))+_(?![${W}_]))`,
  'gu',
);

/**
 * Convert inline markdown markup (bold, italic, code, link) into ADF inline nodes.
 *
 * KNOWN LIMITATIONS:
 * - No recursion: `**bold *with italic* inside**` is parsed as a single strong run;
 *   the inner italic asterisks are consumed by the outer regex and not re-tokenized.
 * - No escaped delimiters: `\*literal\*` is treated like `*literal*` (parsed as italic).
 * - No multi-line marks: a mark must open and close on the same line. (The wider
 *   markdown parser flattens paragraphs first, so a line-broken mark in markdown
 *   source becomes a single line here and IS supported.)
 *
 * For documents that need full CommonMark fidelity, swap this for markdown-it's
 * inline tokenizer. Today's `jira-create` flow stays inside the supported subset.
 */
function parseInline(text: string): InlineNode[] {
  const out: InlineNode[] = [];
  let lastIdx = 0;
  for (const m of text.matchAll(INLINE_RE)) {
    if (m.index! > lastIdx) {
      out.push({ type: 'text', text: text.slice(lastIdx, m.index) });
    }
    const tok = m[0];
    if (tok.startsWith('**') || tok.startsWith('__')) {
      out.push({ type: 'text', text: tok.slice(2, -2), marks: [{ type: 'strong' }] });
    } else if (tok.startsWith('`')) {
      out.push({ type: 'text', text: tok.slice(1, -1), marks: [{ type: 'code' }] });
    } else if (tok.startsWith('[')) {
      const lm = tok.match(/^\[([^\]]+)\]\(([^)]+)\)$/);
      if (lm) {
        out.push({ type: 'text', text: lm[1], marks: [{ type: 'link', attrs: { href: lm[2] } }] });
      } else {
        out.push({ type: 'text', text: tok });
      }
    } else if (tok.startsWith('*') || tok.startsWith('_')) {
      out.push({ type: 'text', text: tok.slice(1, -1), marks: [{ type: 'em' }] });
    }
    lastIdx = m.index! + tok.length;
  }
  if (lastIdx < text.length) {
    out.push({ type: 'text', text: text.slice(lastIdx) });
  }
  return out.length ? out : [{ type: 'text', text }];
}

// Fence and heading rules mirror normalizeMarkdown in the himmel-ops ticket policy.
const FENCE_LINE = /^ {0,3}(`{3,}|~{3,})(.*)$/;
const HEADING_LINE = /^ {0,3}(#{1,6})[ \t]+(.+?)[ \t]*$/;

/** The fence a line opens, or undefined (a backtick fence with a backtick in its info string is none). */
function fenceOpen(line: string): { marker: string; info: string } | undefined {
  const fm = FENCE_LINE.exec(line);
  if (!fm || (fm[1][0] === '`' && fm[2].includes('`'))) return undefined;
  return { marker: fm[1], info: fm[2].trim() };
}

function closesFence(line: string, marker: string): boolean {
  const fm = FENCE_LINE.exec(line);
  return !!fm && fm[1][0] === marker[0] && fm[1].length >= marker.length && fm[2].trim() === '';
}

const isSectionLine = (line: string): boolean => {
  const w = line.trim().replace(/:\s*$/, '').toLowerCase();
  return SECTIONS.some((s) => s.toLowerCase() === w);
};

export function markdownToAdf(md: string): AdfDoc {
  const lines = md.split('\n');
  const blocks: AdfBlock[] = [];
  let i = 0;

  while (i < lines.length) {
    const line = lines[i];

    // skip blank lines
    if (!line.trim()) {
      i++;
      continue;
    }

    // code fence
    const open = fenceOpen(line);
    if (open) {
      const lang = open.info.split(/\s+/)[0] || undefined;
      const codeLines: string[] = [];
      i++;
      while (i < lines.length && !closesFence(lines[i], open.marker)) {
        codeLines.push(lines[i]);
        i++;
      }
      if (i >= lines.length) {
        process.stderr.write('jira: warning — unclosed code fence in markdown input (treating remainder as code)\n');
      } else {
        i++; // skip closing fence
      }
      blocks.push({
        type: 'codeBlock',
        attrs: lang ? { language: lang } : {},
        content: [{ type: 'text', text: codeLines.join('\n') }],
      });
      continue;
    }

    // heading
    const hMatch = HEADING_LINE.exec(line);
    if (hMatch) {
      // the regex bounds the count to 1-6, the ADF heading range
      const level = hMatch[1].length as 1 | 2 | 3 | 4 | 5 | 6;
      // closing hashes need a space before them (`## C#` keeps its `#`)
      const text = hMatch[2].replace(/(?:^|[ \t]+)#+$/, '');
      blocks.push({
        type: 'heading',
        attrs: { level },
        content: text ? parseInline(text) : [],
      });
      i++;
      continue;
    }

    // unordered list
    if (/^\s*[-*+]\s+/.test(line)) {
      const items: ListItem[] = [];
      while (i < lines.length && /^\s*[-*+]\s+/.test(lines[i])) {
        items.push({
          type: 'listItem',
          content: [
            { type: 'paragraph', content: parseInline(lines[i].replace(/^\s*[-*+]\s+/, '')) },
          ],
        });
        i++;
      }
      blocks.push({ type: 'bulletList', content: items });
      continue;
    }

    // ordered list
    if (/^\s*\d+[.)]\s+/.test(line)) {
      const items: ListItem[] = [];
      while (i < lines.length && /^\s*\d+[.)]\s+/.test(lines[i])) {
        items.push({
          type: 'listItem',
          content: [
            { type: 'paragraph', content: parseInline(lines[i].replace(/^\s*\d+[.)]\s+/, '')) },
          ],
        });
        i++;
      }
      blocks.push({ type: 'orderedList', content: items });
      continue;
    }

    // a bare line that is exactly a ticket section name ("Proof", "DoD:") is that section's
    // heading, as the ticket policy reads it (Jira renders a heading node back as such a line)
    if (isSectionLine(line)) {
      blocks.push({ type: 'heading', attrs: { level: 2 }, content: parseInline(line.trim().replace(/:\s*$/, '')) });
      i++;
      continue;
    }

    // paragraph. Accumulate consecutive non-blank, non-special lines
    const paraLines: string[] = [line];
    i++;
    while (
      i < lines.length &&
      lines[i].trim() &&
      !fenceOpen(lines[i]) &&
      !isSectionLine(lines[i]) &&
      !/^( {0,3}#{1,6}[ \t]|\s*[-*+]\s|\s*\d+[.)]\s)/.test(lines[i])
    ) {
      paraLines.push(lines[i]);
      i++;
    }
    blocks.push({ type: 'paragraph', content: parseInline(paraLines.join(' ')) });
  }

  return { type: 'doc', version: 1, content: blocks };
}
